module Compiler.MonoSolver.LssInfer exposing
    ( canTypeArrowDepth
    , canTypeIsArrow
    , canTypeMentionsArrow
    , declaredArityOf
    , flowArrowSetsPlain
    , injectLambdaMember
    , injectLambdaMemberQualified
    , injectPapSuccessors
    , injectPapSuccessorsFrom
    , injectSpineMemberId
    , instantiateWithSignature
    , joinArrowSetsPlain
    , kernelAliasOf
    , noteApplied
    , papMemberKey
    , sigSourceTypeFor
    , signatureFor
    )

{-| Lambda-set signature inference (LSS design §7).

A def's LSS signature summarizes what its _body_ contributes to the arrows of
its _annotation type_ — the facts a caller must apply without walking the
body. With id-only members this is small and flat: per annotation-arrow
ordinal, an `Engine.ArrowFact { rep, members, top }`.

Inference is SCC-granular and demand-lazy: `signatureFor` memoizes per global
(`S.lssSignatures`); a `TOpt.Cycle` node is one inference unit whose members
share their annotation Points through one scratch-store memo (the paper's
Σ/TIU-Self-Ref rule — recursive calls share the def's own set slots, which
forbids polymorphic recursion in set parameters and guarantees termination).

The body walk is a TYPES-ONLY fold over `TOpt.Expr` — not a shadow of
`Translate.translate`. Within one def the typechecker already connected
everything: sub-expression types share solver-rooted `MVarId`s, and the
scratch memo (`MVarId → Point`) makes every occurrence load to the same
Point. The walk only adds what the type checker never knew — set facts. It
performs no enqueues, allocates no SpecIds, emits no exprs, and touches no
multi-instance stacks.

Ordinal discipline (LSS\_006): a signature's `arrows` index is the minting
order of `Store.loadTypeWithArrows` over the def's SIGNATURE SOURCE type —
the stored annotation if present, else the node's `meta.tipe`.
`instantiateWithSignature` pairs facts by the same ordinal from
`Store.loadTypeIsolatedWithArrows` over the type its caller sourced the same
way (`Translate.translateCall`'s annotation-first order). On arrow-count
mismatch (an unannotated def whose use-site instantiation grew arrows), facts
cannot be paired positionally — the total, sound fallback is to poison every
slot of the instantiation (⊤ loses precision, never soundness).

-}

import Array exposing (Array)
import Compiler.AST.Canonical as Can
import Compiler.AST.Monomorphized as Mono
import Compiler.AST.TypeIds as TypeIds
import Compiler.AST.TypedOptimized as TOpt
import Compiler.Data.Name exposing (Name)
import Compiler.MonoSolver.Engine as Engine exposing (Failure(..), Step)
import Compiler.MonoSolver.KernelSetFacts as KernelSetFacts
import Compiler.MonoSolver.Store as Store
import Compiler.Reporting.Annotation as A
import Compiler.Type.UnionFind as UF
import Compiler.Type.Vars as Vars
import Data.HashMap as HashMap
import Data.Map as DMap
import Dict as CoreDict exposing (Dict)
import System.TypeCheck.IO as IO



-- ====== PUBLIC API ======


{-| The memoized per-definition signature. Computes (and memoizes) the whole
SCC unit on first demand. Crashes (EngineBug) on re-entry into an in-flight
unit — pre-resolution of callee signatures makes that impossible; the crash
keeps it that way.
-}
signatureFor : TOpt.Global -> Step Engine.LssSignature
signatureFor global s0 =
    let
        gkey =
            TOpt.toComparableGlobal global
    in
    case CoreDict.get gkey s0.lssSignatures of
        Just sig ->
            Ok ( sig, s0 )

        Nothing ->
            if not s0.env.lss.enabled then
                Ok ( Engine.trivialSignature 0, s0 )

            else if CoreDict.member gkey s0.lssInProgress then
                Err (EngineBug ("LssInfer.signatureFor re-entry on in-flight unit member: " ++ gkey))

            else
                case HashMap.get TOpt.globalHash (==) global s0.env.toptNodes of
                    Just (TOpt.Link target) ->
                        -- Chase links BEFORE unit resolution. A cycle member
                        -- maps as `member -> Link(_M$first group)`, and
                        -- inferring the group memoizes EVERY member's own
                        -- signature — so after the chase, prefer this gkey's
                        -- freshly memoized signature over the target handle's.
                        case signatureFor target s0 of
                            Err e ->
                                Err e

                            Ok ( sigTarget, s1 ) ->
                                case CoreDict.get gkey s1.lssSignatures of
                                    Just own ->
                                        Ok ( own, s1 )

                                    Nothing ->
                                        Ok ( sigTarget, { s1 | lssSignatures = CoreDict.insert gkey sigTarget s1.lssSignatures } )

                    _ ->
                        inferUnit global gkey s0


{-| Load the callee's signature-source type as a fresh per-call-site
instantiation (isolated memo) and apply the callee's signature facts to its
arrow slots. `funcCanType` must be sourced annotation-first exactly as
`Translate.translateCall` does — the signature side uses the same source, so
ordinals pair (LSS\_006).
-}
instantiateWithSignature : TOpt.Global -> Can.Type TypeIds.MVarId -> Step Vars.Variable
instantiateWithSignature global funcCanType s0 =
    case signatureFor global s0 of
        Err e ->
            Err e

        Ok ( sig, s1 ) ->
            case Store.loadTypeIsolatedWithArrows funcCanType s1 of
                Err e ->
                    Err e

                Ok ( ( funcVar, slots ), s2 ) ->
                    case applyFacts global sig slots funcVar s2 of
                        Err e ->
                            Err e

                        Ok ( _, s3 ) ->
                            Ok ( funcVar, s3 )


{-| Unify a source lambda's own member into the first `arity` arrows of its
loaded type's result spine (LSS\_013 spine injection), via 'injectSpineMemberId'.
`arity` is the lambda's parameter count — the exact number of arrows a partial
application of it can peel; the spine is bounded there so a function-returning
body never stamps its returned closure's arrows (see 'injectSpineMemberId').
No-op for untagged lambdas and for any spine arrow with no slot (an erased-var
head has no slot to constrain — sound: the arrow reads back whatever its other
constraints say, or LTop). The argument arrows are deliberately never touched.
-}
injectLambdaMember : Int -> Maybe TypeIds.SrcLambdaId -> Vars.Variable -> Step ()
injectLambdaMember arity srcLam funcVar s0 =
    case srcLam of
        Nothing ->
            Ok ( (), s0 )

        Just lamId ->
            injectSpineMemberId arity (Engine.srcLambdaKey lamId) funcVar s0


{-| Fix B (LSS\_017): `injectLambdaMember` for TRANSLATION-phase mints —
the member id is spec-qualified via `Engine.lambdaInstanceMemberId` when
the defining global routes keyed, so keyed clones of one source lambda
stay distinguishable. The inference-phase walk (`walkExpr`) keeps the raw
`injectLambdaMember`: signatures are per-unit and pre-spec by design.
-}
injectLambdaMemberQualified : Int -> Maybe TypeIds.SrcLambdaId -> Vars.Variable -> Step ()
injectLambdaMemberQualified arity srcLam funcVar s0 =
    case srcLam of
        Nothing ->
            Ok ( (), s0 )

        Just lamId ->
            case Engine.lambdaInstanceMemberId lamId s0 of
                Err e ->
                    Err e

                Ok ( mid, s1 ) ->
                    -- plans/lss-root-fold-depth-qualified-spine.md §3: a
                    -- root-FOLDED lambda's id is its global's GROUND
                    -- STANDALONE key — a STAMPABLE `g|` — and must not be
                    -- written past the head. `lss-root-member-fold.md` §1.5
                    -- AR-1: "the papMembers miscompile required a stampable
                    -- id on a PARTIAL application; depth>0 stays `p|`
                    -- (declining), so that door stays shut" — and the two
                    -- OTHER spine writers (`Translate.stampSelfSpine` via
                    -- `memberIdForDepth`, `injectPapSuccessors`) already
                    -- honour that. This one did not: `spineGoC` writes ONE
                    -- id at every depth, which is correct for `l|` lambdas
                    -- (LSS_013 — LSS_011's PAP-prefix stamp layout-checks
                    -- them) and wrong for a folded `g|`.
                    --
                    -- Non-folded lambdas keep the LSS_013 full-spine write.
                    if s1.env.lss.rootFold && s1.env.lss.stamp.rootFoldDepth then
                        case CoreDict.get (Engine.srcLambdaKey lamId) s1.lssMemberTable.rootLamOf of
                            Just g ->
                                case injectSpineMemberId 1 mid funcVar s1 of
                                    Err e ->
                                        Err e

                                    Ok ( _, s2 ) ->
                                        injectFoldedSuccessors g arity funcVar s2

                            Nothing ->
                                injectSpineMemberId arity mid funcVar s1

                    else
                        injectSpineMemberId arity mid funcVar s1



-- ====== SIGNATURE SOURCE ======


{-| The one place that decides which canonical type a def's signature is
enumerated over: the stored annotation if the global has one, else the given
fallback (the node's own type on the inference side; the use-site
`funcMeta.tipe` on the call side).
-}
sigSourceTypeFor : TOpt.Global -> Can.Type TypeIds.MVarId -> Engine.S -> Can.Type TypeIds.MVarId
sigSourceTypeFor global fallbackType s =
    case DMap.get TOpt.toComparableGlobal global s.env.annotations of
        Just (Can.Forall _ annoType) ->
            annoType

        Nothing ->
            fallbackType


{-| Apply per-ordinal facts to freshly minted slots. Count mismatch ⇒ poison
everything (sound fallback; see module doc).

LSS\_026 census (plan §2.6 row 6): the mismatch branch is REPORT-COUNTED per
callee. Note the guard order — `sig.trivial` short-circuits FIRST, so a
trivial-signature callee can never reach the poison no matter how far its
occurrence type diverges from its annotation. The population that CAN reach
it is exactly the non-trivial one, i.e. the callees whose facts the GAP-2
transport exists to deliver, which is why this counter is a direct read on
the transport's yield rather than a curiosity.

-}
applyFacts : TOpt.Global -> Engine.LssSignature -> Array Vars.Variable -> Vars.Variable -> Step ()
applyFacts global sig slots funcVar s0 =
    if sig.trivial then
        Ok ( (), s0 )

    else if Array.length sig.arrows /= Array.length slots then
        Store.poisonArrowSets funcVar (censusLenGuard global (Array.length sig.arrows) (Array.length slots) s0)

    else
        applyFactsGo sig.arrows slots 0 s0


{-| LSS\_026 census: an arrow-count mismatch poisoned a whole instantiation.
`shape=<sigN>-><slotsN>` records the direction (occurrence GREW arrows vs
shrank), which is what distinguishes "annotation is more general than the
use" from a genuine pairing bug. Report-gated.
-}
censusLenGuard : TOpt.Global -> Int -> Int -> Engine.S -> Engine.S
censusLenGuard global sigN slotsN s =
    s
        |> Engine.bumpArgFlowCensus "poison|lenGuard|all"
        |> Engine.bumpArgFlowCensus ("poison|lenGuard|" ++ TOpt.toComparableGlobal global)
        |> Engine.bumpArgFlowCensus ("poison|lenGuardShape|" ++ String.fromInt sigN ++ "->" ++ String.fromInt slotsN)


applyFactsGo : Array Engine.ArrowFact -> Array Vars.Variable -> Int -> Step ()
applyFactsGo facts slots i s0 =
    case ( Array.get i facts, Array.get i slots ) of
        ( Just fact, Just slot ) ->
            let
                afterRep =
                    if fact.rep /= i then
                        case Array.get fact.rep slots of
                            Just repSlot ->
                                Store.unifyStep repSlot slot s0

                            Nothing ->
                                Ok ( (), s0 )

                    else
                        Ok ( (), s0 )
            in
            case afterRep of
                Err e ->
                    Err e

                Ok ( _, s1 ) ->
                    let
                        afterSet =
                            if fact.top then
                                Store.unifySlotWithSet (Just fact.topKind) [] slot s1

                            else if not (List.isEmpty fact.members) then
                                Store.unifySlotWithSet Nothing fact.members slot s1

                            else
                                Ok ( (), s1 )
                    in
                    case afterSet of
                        Err e ->
                            Err e

                        Ok ( _, s2 ) ->
                            -- LSS_023: install the directed half — for each
                            -- source ordinal j, "slots[i] ⊇ slots[j]" as a
                            -- deferred edge. Pull-at-read makes the
                            -- eager-vs-late ordering irrelevant: this is
                            -- exactly the deferral that makes directed facts
                            -- sound where the snapshot read was not, even
                            -- though applyFacts still precedes arg
                            -- unification. Missing ordinal → skip (a count
                            -- mismatch is already poisoned by applyFacts'
                            -- length guard).
                            case installSources fact.sources slots slot s2 of
                                Err e ->
                                    Err e

                                Ok ( _, s3 ) ->
                                    applyFactsGo facts slots (i + 1) s3

        _ ->
            Ok ( (), s0 )


installSources : List Int -> Array Vars.Variable -> Vars.Variable -> Step ()
installSources ordinals slots dst s0 =
    case ordinals of
        [] ->
            Ok ( (), s0 )

        j :: rest ->
            case Array.get j slots of
                Nothing ->
                    installSources rest slots dst s0

                Just srcSlot ->
                    case Store.addSlotSource srcSlot dst s0 of
                        Err e ->
                            Err e

                        Ok ( _, s1 ) ->
                            installSources rest slots dst s1



-- ====== UNIT INFERENCE ======


type alias UnitMember =
    { gkey : String
    , sigType : Can.Type TypeIds.MVarId
    , body : Maybe (TOpt.Expr TypeIds.MVarId)

    -- LSS_020 (B.1): non-empty ONLY for Cycle `TailDef` members, whose body
    -- expr is ARG-STRIPPED (typed at the result) while `sigType` is the full
    -- function type — `walkMembers` peels this many arrows off the loaded
    -- root (binding the arg names) before joining the body's flow.
    , tailArgs : List Name
    }


inferUnit : TOpt.Global -> String -> Step Engine.LssSignature
inferUnit global gkey s0 =
    case resolveUnit global s0 of
        Err e ->
            Err e

        Ok ( members, s1 ) ->
            let
                s2 =
                    { s1 | lssInProgress = CoreDict.insert gkey () (List.foldl (\m acc -> CoreDict.insert m.gkey () acc) s1.lssInProgress members) }
            in
            -- Pre-resolve callee signatures OUTSIDE the scratch store so
            -- scratch stores never nest.
            case preResolveCallees members s2 of
                Err e ->
                    Err e

                Ok ( _, s3 ) ->
                    case Engine.withScratchStore (inferUnitInScratch members) s3 of
                        Err e ->
                            Err e

                        Ok ( sigs, s4 ) ->
                            let
                                s5 =
                                    { s4
                                        | lssSignatures = List.foldl (\( k, sg ) acc -> CoreDict.insert k sg acc) s4.lssSignatures sigs
                                        , lssInProgress = CoreDict.remove gkey (List.foldl (\m acc -> CoreDict.remove m.gkey acc) s4.lssInProgress members)
                                    }
                            in
                            case List.filter (\( k, _ ) -> k == gkey) sigs of
                                ( _, sig ) :: _ ->
                                    Ok ( sig, s5 )

                                [] ->
                                    -- gkey is a Cycle GROUP handle (`_M$first`),
                                    -- not itself a def: every member's real
                                    -- signature was memoized above, and callers
                                    -- always reach members via their Link chase
                                    -- (which prefers the member's own memo).
                                    -- The group handle itself gets a trivial
                                    -- placeholder.
                                    let
                                        placeholder =
                                            Engine.trivialSignature 0
                                    in
                                    Ok ( placeholder, { s5 | lssSignatures = CoreDict.insert gkey placeholder s5.lssSignatures } )


{-| Resolve the inference unit: a `TOpt.Cycle` node is one unit (all its
members); anything else is a singleton. Members without a walkable body
(Ctor/Enum/Box/Kernel/Manager) get trivial signatures via a body-less member.
Signature-source types are annotation-first (LSS\_006).
-}
resolveUnit : TOpt.Global -> Step (List UnitMember)
resolveUnit ((TOpt.Global home _) as global) s0 =
    case HashMap.get TOpt.globalHash (==) global s0.env.toptNodes of
        Nothing ->
            -- Unknown global (e.g. an accessor pseudo-global): trivial.
            Ok ( [ memberOf global Can.TUnit Nothing s0 ], s0 )

        Just node ->
            case node of
                TOpt.Define expr _ meta ->
                    Ok ( [ memberOf global meta.tipe (Just expr) s0 ], s0 )

                TOpt.TrackedDefine _ expr _ meta ->
                    Ok ( [ memberOf global meta.tipe (Just expr) s0 ], s0 )

                TOpt.Cycle _ valueDefs funcDefs _ ->
                    let
                        valueMembers =
                            List.map
                                (\( name, expr ) -> memberOf (TOpt.Global home name) (TOpt.typeOf expr) (Just expr) s0)
                                valueDefs

                        funcMembers =
                            List.map
                                (\def ->
                                    case def of
                                        TOpt.Def _ name bodyExpr defType ->
                                            memberOf (TOpt.Global home name) defType (Just bodyExpr) s0

                                        TOpt.TailDef _ name args bodyExpr defType _ ->
                                            let
                                                m =
                                                    memberOf (TOpt.Global home name) defType (Just bodyExpr) s0
                                            in
                                            { m | tailArgs = List.map (\( locName, _ ) -> A.toValue locName) args }
                                )
                                funcDefs
                    in
                    Ok ( valueMembers ++ funcMembers, s0 )

                TOpt.PortIncoming expr _ meta ->
                    Ok ( [ memberOf global meta.tipe (Just expr) s0 ], s0 )

                TOpt.PortOutgoing expr _ meta ->
                    Ok ( [ memberOf global meta.tipe (Just expr) s0 ], s0 )

                TOpt.Ctor _ _ canType ->
                    Ok ( [ memberOf global canType Nothing s0 ], s0 )

                TOpt.Enum _ canType ->
                    Ok ( [ memberOf global canType Nothing s0 ], s0 )

                TOpt.Box canType ->
                    Ok ( [ memberOf global canType Nothing s0 ], s0 )

                TOpt.Link target ->
                    resolveUnit target s0

                TOpt.Manager _ ->
                    Ok ( [ memberOf global Can.TUnit Nothing s0 ], s0 )

                TOpt.Kernel _ _ ->
                    Ok ( [ memberOf global Can.TUnit Nothing s0 ], s0 )


memberOf : TOpt.Global -> Can.Type TypeIds.MVarId -> Maybe (TOpt.Expr TypeIds.MVarId) -> Engine.S -> UnitMember
memberOf g fallbackType body s =
    { gkey = TOpt.toComparableGlobal g
    , sigType = sigSourceTypeFor g fallbackType s
    , body = body
    , tailArgs = []
    }


{-| Fold over unit bodies collecting referenced globals; `signatureFor` each
one outside the unit and not yet memoized. Cheap syntactic pass.
-}
preResolveCallees : List UnitMember -> Step ()
preResolveCallees members s0 =
    let
        unitKeys =
            List.foldl (\m acc -> CoreDict.insert m.gkey () acc) CoreDict.empty members

        referenced =
            List.foldl
                (\m acc ->
                    case m.body of
                        Just body ->
                            collectReferencedGlobals body acc

                        Nothing ->
                            acc
                )
                CoreDict.empty
                members
    in
    preResolveGo unitKeys (CoreDict.values referenced) s0


preResolveGo : Dict String () -> List TOpt.Global -> Step ()
preResolveGo unitKeys globals s0 =
    case globals of
        [] ->
            Ok ( (), s0 )

        g :: rest ->
            let
                k =
                    TOpt.toComparableGlobal g
            in
            if CoreDict.member k unitKeys || CoreDict.member k s0.lssSignatures then
                preResolveGo unitKeys rest s0

            else
                case signatureFor g s0 of
                    Err e ->
                        Err e

                    Ok ( _, s1 ) ->
                        preResolveGo unitKeys rest s1


collectReferencedGlobals : TOpt.Expr TypeIds.MVarId -> Dict String TOpt.Global -> Dict String TOpt.Global
collectReferencedGlobals expr acc =
    case expr of
        TOpt.VarGlobal _ g _ ->
            CoreDict.insert (TOpt.toComparableGlobal g) g acc

        TOpt.VarEnum _ g _ _ ->
            CoreDict.insert (TOpt.toComparableGlobal g) g acc

        TOpt.VarBox _ g _ ->
            CoreDict.insert (TOpt.toComparableGlobal g) g acc

        TOpt.VarCycle _ home name _ ->
            CoreDict.insert (TOpt.toComparableGlobal (TOpt.Global home name)) (TOpt.Global home name) acc

        _ ->
            List.foldl collectReferencedGlobals acc (directChildren expr)



-- ====== THE SCRATCH-STORE UNIT PASS ======


inferUnitInScratch : List UnitMember -> Step (List ( String, Engine.LssSignature ))
inferUnitInScratch members s0 =
    -- Load every member's signature type through the SHARED scratch memo,
    -- capturing per-member roots + arrow-slot arrays (self/sibling annotation
    -- vars share Points — the Σ rule).
    case loadMemberSlots members [] s0 of
        Err e ->
            Err e

        Ok ( loaded, s1 ) ->
            -- `loaded` is in member order by construction (one triple per
            -- member, body-less members included), so the zips align.
            case walkMembers (List.map2 Tuple.pair members loaded) s1 of
                Err e ->
                    Err e

                Ok ( _, s2 ) ->
                    -- LSS_026 §11.2(i) defaulted a WRAP-CLASS member's
                    -- head-arrow fact here. MEASURED NO-GO (plan §11.5): it
                    -- pushed 184 signatures into `trivial`, whose
                    -- short-circuits then cost 60 % of grounding, and bought
                    -- 0.000 pp of dispatch coverage.
                    case
                        zonkSignatures
                            (List.map2
                                (\m ( gkey, _, slots ) -> ( gkey, selfIdOf m, slots ))
                                members
                                loaded
                            )
                            []
                            s2
                    of
                        Err e ->
                            Err e

                        Ok ( sigs, s3 ) ->
                            -- §5.6 (plans/lss-paper-inclusion-constraints.md):
                            -- score `Q` HERE, while the scratch store is still
                            -- installed. This is the paper's inference boundary
                            -- — the unit's constraints are complete and its
                            -- signature roots are in hand — and it is the arm
                            -- the REPRODUCES gate is about. `finishNode`'s
                            -- census sees the SPECIALIZATION phase instead,
                            -- where a stored demand legitimately re-enters as
                            -- ground `σ̄`.
                            --
                            -- The log is cleared immediately after, so these
                            -- constraints are not counted a second time as
                            -- `scratchDropped` when the scratch store unwinds:
                            -- the two censuses must PARTITION the constraints,
                            -- not overlap.
                            let
                                s4 =
                                    Store.qInferenceCensus
                                        (List.map (\( _, root, _ ) -> root) loaded)
                                        s3

                                aux4 =
                                    s4.itemAux
                            in
                            Ok ( sigs, { s4 | itemAux = { aux4 | qLog = [] } } )


loadMemberSlots : List UnitMember -> List ( String, Vars.Variable, Array Vars.Variable ) -> Step (List ( String, Vars.Variable, Array Vars.Variable ))
loadMemberSlots members acc s0 =
    case members of
        [] ->
            Ok ( List.reverse acc, s0 )

        m :: rest ->
            case Store.loadTypeWithArrows m.sigType s0 of
                Err e ->
                    Err e

                Ok ( ( root, slots ), s1 ) ->
                    loadMemberSlots rest (( m.gkey, root, slots ) :: acc) s1


{-| LSS\_020 (B.1.f): the raw member id of the def's OWN body lambda. Filtered
at signature readback — transporting it through signatures is redundant
(callers already receive the def's identity via the `g|` standalone spine
injection, which grounds per LSS\_019, and via `injectArgLambdaMember`
translate-side) and harmful (raw `l|` ids decline at AbiCloning per LSS\_017,
and an unfiltered self-id would make EVERY ≥1-param def's signature
nontrivial, killing the `trivial` short-circuits). Inner-lambda ids are NOT
filtered — those are genuine body contributions.
-}
selfIdOf : UnitMember -> Maybe Int
selfIdOf m =
    case m.body of
        Just (TOpt.Function (Just lamId) _ _ _) ->
            Just (Engine.srcLambdaKey lamId)

        Just (TOpt.TrackedFunction (Just lamId) _ _ _) ->
            Just (Engine.srcLambdaKey lamId)

        _ ->
            Nothing


walkMembers : List ( UnitMember, ( String, Vars.Variable, Array Vars.Variable ) ) -> Step ()
walkMembers pairs s0 =
    case pairs of
        [] ->
            Ok ( (), s0 )

        ( m, ( _, root, _ ) ) :: rest ->
            case m.body of
                Nothing ->
                    -- LSS_026 census (plan §2.1 row 3): a BODY-LESS unit
                    -- member (Ctor/Enum/Box/Manager/Kernel/port). Its
                    -- signature is trivial HONESTLY — there is no body that
                    -- could have contributed — so it must not be counted
                    -- against the producer-side transport population.
                    walkMembers rest (Engine.bumpArgFlowCensus "sig|bodyless" s0)

                Just body ->
                    if s0.env.lss.sigFlow then
                        -- LSS_020 (B.1): connect the member's own signature
                        -- slots to the body's flow. TailDef bodies are
                        -- ARG-STRIPPED (result-typed) while the root is the
                        -- full function type, so peel |tailArgs| arrows off
                        -- the root — binding the args while there — and join
                        -- the spine end (single-source join: Honest|Opaque).
                        let
                            ( env0, maybeTarget, s1 ) =
                                bindParamsFromSpine m.tailArgs root CoreDict.empty CoreDict.empty s0
                        in
                        case walkExpr env0 body s1 of
                            Err e ->
                                Err e

                            Ok ( wp, s2 ) ->
                                case ( maybeTarget, wpPoint wp ) of
                                    ( Just target, Just p ) ->
                                        case joinArrowSetsSig target p s2 of
                                            Err e ->
                                                Err e

                                            Ok ( _, s3 ) ->
                                                walkMembers rest s3

                                    _ ->
                                        walkMembers rest s2

                    else
                        case walkExpr CoreDict.empty body s0 of
                            Err e ->
                                Err e

                            Ok ( _, s1 ) ->
                                walkMembers rest s1


zonkSignatures : List ( String, Maybe Int, Array Vars.Variable ) -> List ( String, Engine.LssSignature ) -> Step (List ( String, Engine.LssSignature ))
zonkSignatures pending acc s0 =
    case pending of
        [] ->
            Ok ( List.reverse acc, s0 )

        ( gkey, selfId, slots ) :: rest ->
            case zonkOneSignature selfId slots s0 of
                Err e ->
                    Err e

                Ok ( sig, s1 ) ->
                    zonkSignatures rest (( gkey, sig ) :: acc) (censusSigFacts gkey sig s1)


{-| LSS\_026 census (plan §2.6 "sigfacts"): dump every NON-default fact of a
non-trivial signature, one key per (def, ordinal). This is what turns "551
reachable sites" into "which POSITIONS carry what, per producer" — D1
connects the arg-callee's residual spine, so a producer whose members sit
only at its own param ordinals yields nothing at the position the consumer
reads. Report-gated; ~321 carrying signatures on the self-compile, a few
ordinals each.
-}
censusSigFacts : String -> Engine.LssSignature -> Engine.S -> Engine.S
censusSigFacts gkey sig s =
    if not s.env.lss.report || sig.trivial then
        s

    else
        List.foldl
            (\( i, f ) acc ->
                if f.rep == i && not f.top && List.isEmpty f.members && List.isEmpty f.sources then
                    acc

                else
                    Engine.bumpArgFlowCensus
                        ("sigfacts|"
                            ++ gkey
                            ++ "|"
                            ++ String.fromInt i
                            ++ "|m="
                            ++ String.fromInt (List.length f.members)
                            ++ ","
                            ++ Engine.membersClass f.members s.lssMemberTable
                            ++ "|s="
                            ++ String.fromInt (List.length f.sources)
                            ++ "|t="
                            ++ (if f.top then
                                    "1"

                                else
                                    "0"
                               )
                            ++ "|r="
                            ++ (if f.rep == i then
                                    "-"

                                else
                                    String.fromInt f.rep
                               )
                        )
                        acc
            )
            s
            (List.indexedMap Tuple.pair (Array.toList sig.arrows))


zonkOneSignature : Maybe Int -> Array Vars.Variable -> Step Engine.LssSignature
zonkOneSignature selfId slots s0 =
    zonkSigGo selfId slots (Array.length slots) 0 [] s0


zonkSigGo : Maybe Int -> Array Vars.Variable -> Int -> Int -> List Engine.ArrowFact -> Step Engine.LssSignature
zonkSigGo selfId slots n i factsRev s0 =
    if i >= n then
        let
            facts =
                List.reverse factsRev

            trivial =
                List.all identity
                    (List.indexedMap
                        (\j f -> f.rep == j && not f.top && List.isEmpty f.members && List.isEmpty f.sources)
                        facts
                    )
        in
        let
            -- §5.2: `Q` — `ℓ… ⋸ α`, keyed by the CANONICAL ordinal, so a use
            -- re-emits against the variable rather than against a position.
            -- Members of a non-canonical ordinal belong to its rep's variable;
            -- `applyFacts` unifies those slots first, so either key writes the
            -- same class, but keying canonically is what makes it a constraint
            -- ON A VARIABLE.
            residual =
                List.foldr
                    (\( j, f ) acc ->
                        if List.isEmpty f.members then
                            acc

                        else
                            let
                                key =
                                    if f.rep == j then
                                        j

                                    else
                                        f.rep
                            in
                            ( key, f.members ) :: acc
                    )
                    []
                    (List.indexedMap Tuple.pair facts)
        in
        Ok
            ( { arrows = Array.fromList facts, trivial = trivial, residual = residual }
            , censusSignature n facts trivial s0
            )

    else
        case Array.get i slots of
            Nothing ->
                Err (EngineBug "zonkOneSignature: slot index out of range")

            Just slot ->
                case repOrdinal slots slot i 0 s0 of
                    Err e ->
                        Err e

                    Ok ( rep, s1 ) ->
                        let
                            ( store1, desc ) =
                                UF.get slot s1.store

                            s2 =
                                { s1 | store = store1 }

                            ( fact, s3 ) =
                                case desc.content of
                                    Vars.Structure (Vars.LambdaSet1 (Vars.LsTop tpK)) ->
                                        -- Members are dead under ⊤ at every
                                        -- fact consumer; carry none. §4.9:
                                        -- the birth kind rides the fact.
                                        ( Ok { rep = rep, members = [], top = True, topKind = tpK, sources = [] }, s2 )

                                    Vars.Structure (Vars.LambdaSet1 (Vars.LsMembers ms0)) ->
                                        if s2.env.lss.sigFlow then
                                            let
                                                -- B.1.f self-id filter (see
                                                -- `selfIdOf`); preserves the
                                                -- ascending order the set-write
                                                -- contract requires.
                                                ms =
                                                    case selfId of
                                                        Just sid ->
                                                            List.filter (\mid -> mid /= sid) ms0

                                                        Nothing ->
                                                            ms0
                                            in
                                            -- B.4 rider: the maxSetSize policy
                                            -- applies to the signature channel
                                            -- too (mirrors Store.zonkSetSlot's
                                            -- cap; LSS_005 — widening only).
                                            -- 0 = UNLIMITED (2026-08-29).
                                            if s2.env.lss.maxSetSize > 0 && List.length ms > s2.env.lss.maxSetSize then
                                                ( Ok { rep = rep, members = [], top = True, topKind = Mono.tkWiden, sources = [] }
                                                , Engine.bumpWidenedBySigSize s2
                                                )

                                            else
                                                ( Ok { rep = rep, members = ms, top = False, topKind = Mono.tkLegacy, sources = [] }, s2 )

                                        else
                                            -- Phase 2: the store list by pointer
                                            -- (was CoreDict.keys).
                                            ( Ok { rep = rep, members = ms0, top = False, topKind = Mono.tkLegacy, sources = [] }, s2 )

                                    Vars.Structure (Vars.LambdaSet1 (Vars.LsFrom ms0 srcs)) ->
                                        -- LSS_023 promote-or-internalize (the
                                        -- paper's Fig. 7 split, at the id
                                        -- level): walk the edge graph; a node
                                        -- UF-equivalent to ANOTHER signature
                                        -- ordinal is PROMOTED (recorded in
                                        -- `sources`, not descended — the
                                        -- caller-side edge delivers its
                                        -- members); everything else is
                                        -- INTERNALIZED (members collected,
                                        -- its own srcs descended).
                                        if s2.env.lss.sigFlow then
                                            ( Err ( ms0, srcs ), s2 )

                                        else
                                            -- Defensive (unreachable while the
                                            -- §2.2 gating holds — no flag-off
                                            -- producer exists). MUST NOT read
                                            -- ms0 as complete: a set claiming
                                            -- completeness while dropping its
                                            -- sources' members is the
                                            -- false-singleton miscompile.
                                            ( Ok { rep = rep, members = [], top = True, topKind = Mono.tkEdge, sources = [] }, s2 )

                                    _ ->
                                        -- FlexVar: the body contributed nothing.
                                        ( Ok { rep = rep, members = [], top = False, topKind = Mono.tkLegacy, sources = [] }, s2 )
                        in
                        case fact of
                            Ok done ->
                                zonkSigGo selfId slots n (i + 1) (done :: factsRev) s3

                            Err ( ms0, srcs ) ->
                                case sigResolveEdges selfId slots i ms0 srcs s3 of
                                    Err e ->
                                        Err e

                                    Ok ( resolved, s4 ) ->
                                        let
                                            ( done, s5 ) =
                                                finishSigFact rep resolved s4
                                        in
                                        zonkSigGo selfId slots n (i + 1) (done :: factsRev) s5


{-| LSS\_026 census (plan §2.1 row 3): classify a finished signature so
Phase 0 can decompose the trivial mass instead of reporting one number.

  - `sig|arrowfree` — no arrow slots at all (a value def): trivial by
    construction, nothing a transport could ever add.
  - `sig|allflex` — has arrows, every fact default: the body contributed
    nothing to ANY slot. This is the bucket GAP-2's producer side is about.
  - `sig|hasTop` — carries at least one ⊤ fact (poisoned or widened).
  - `sig|carrying` — carries members and/or promoted sources: the
    non-trivial population whose facts the transport can deliver.

`sig|arrows=<n>` gives the arity distribution. Report-gated.

-}
censusSignature : Int -> List Engine.ArrowFact -> Bool -> Engine.S -> Engine.S
censusSignature n facts trivial s =
    if not s.env.lss.report then
        s

    else
        let
            klass =
                if n == 0 then
                    "arrowfree"

                else if trivial then
                    "allflex"

                else if List.any .top facts then
                    "hasTop"

                else
                    "carrying"
        in
        s
            |> Engine.bumpArgFlowCensus ("sig|" ++ klass)
            |> Engine.bumpArgFlowCensus ("sig|arrows=" ++ String.fromInt n)


{-| LSS\_023 §3.2: the edge-graph walk behind `zonkSigGo`'s `LsFrom` arm.
Same visited discipline as `Store.resolveSlotMembers` (raw pointKey, marked on
entry, fresh per call); classification per reached node:

  - UF-equivalent to `slots[j]` for some ordinal `j /= i`: PROMOTE — record
    `j`, do NOT descend (the caller-side edge delivers j's members);
  - otherwise: INTERNALIZE — collect its members, descend its sources.

A reachable ⊤ short-circuits to `{ top = True, members = [], sources = [] }`.
The self-id filter (B.1.f) applies to the COLLECTED members; ordinal self
(and rep-equal ordinals — their equality is already the rep link) are
dropped from sources.

-}
sigResolveEdges : Maybe Int -> Array Vars.Variable -> Int -> List Int -> List Vars.Variable -> Step { top : Bool, members : List Int, sources : List Int }
sigResolveEdges selfId slots i ms0 srcs s0 =
    case sigEdgesGo slots i srcs [] ms0 [] False s0 of
        Err e ->
            Err e

        Ok ( ( Nothing, _ ), s1 ) ->
            Ok ( { top = True, members = [], sources = [] }, s1 )

        Ok ( ( Just ( members, ordinals ), sawFlex ), s1 ) ->
            let
                filtered =
                    case selfId of
                        Just sid ->
                            List.filter (\mid -> mid /= sid) members

                        Nothing ->
                            members
            in
            if sawFlex && not (List.isEmpty filtered && List.isEmpty ordinals) then
                -- LSS_026(a), signature side: this internalization crossed a
                -- DANGLING (FlexVar) inflow — an untracked inhabitant
                -- channel — while carrying members or promoted ordinals. The
                -- fact would claim completeness it does not have (plan §0.5:
                -- `pick`/`d`), so it resolves ⊤.
                --
                -- UNCONDITIONAL since 2026-08-23. The plan shipped this
                -- flag-gated because the Phase-0 census found zero crossings
                -- on the self-compile; the escalation trigger was a runtime
                -- witness instead — `test/elm/src/LssMixedSigHonestyTest.elm`
                -- miscompiles at the shipping default without the rule (a
                -- false `{g|incr}` singleton that LSS_025's post-settle
                -- devirt trusts, turning `d ident` into `incr`). Plan §0.5's
                -- own escalation criterion: `gc` exposure ⇒ unconditional,
                -- ahead of D1/D2. Cost on the self-compile is nil BECAUSE the
                -- census is zero there — this is a pure soundness fix, not a
                -- precision trade.
                --
                -- A promoted-ordinals-only fact is NOT exempt: the
                -- caller-side edges deliver the ordinals' members, but the
                -- dangling inflow is in NEITHER channel.
                --
                -- The all-empty case keeps today's empty fact (consumers
                -- write nothing, the slot stays flex and reads ⊤ — sound,
                -- and it preserves the trivial-signature mass).
                Ok
                    ( { top = True, members = [], sources = [] }
                    , censusMixedSig filtered (Engine.bumpTopMixedFlexSig s1)
                    )

            else
                Ok ( { top = False, members = filtered, sources = List.sort ordinals }, s1 )


{-| LSS\_026 census (plan §2.1 row 2, signature side): count a mixed fact and
the coarsest class of member it carries. `gc` members ground (LSS\_019) and
are consumable by LSS\_025 post-settle devirt / E9.1 — a false one is the
representative-hijack miscompile class, so a nonzero `mixed|sig|gc` is the
plan's escalation gate. Report-gated.
-}
censusMixedSig : List Int -> Engine.S -> Engine.S
censusMixedSig members s =
    s
        |> Engine.bumpArgFlowCensus "mixed|sig"
        |> Engine.bumpArgFlowCensus ("mixed|sig|" ++ Engine.membersClass members s.lssMemberTable)


sigEdgesGo : Array Vars.Variable -> Int -> List Vars.Variable -> List Int -> List Int -> List Int -> Bool -> Step ( Maybe ( List Int, List Int ), Bool )
sigEdgesGo slots i pending visited accMembers accOrdinals sawFlex s0 =
    case pending of
        [] ->
            Ok ( ( Just ( accMembers, accOrdinals ), sawFlex ), s0 )

        src :: rest ->
            let
                key =
                    Engine.pointKey src
            in
            if List.member key visited then
                sigEdgesGo slots i rest visited accMembers accOrdinals sawFlex s0

            else
                case ordinalOf slots i src s0 of
                    Err e ->
                        Err e

                    Ok ( Just j, s1 ) ->
                        -- PROMOTE: record the ordinal, do not descend.
                        sigEdgesGo slots
                            i
                            rest
                            (key :: visited)
                            accMembers
                            (if List.member j accOrdinals then
                                accOrdinals

                             else
                                j :: accOrdinals
                            )
                            sawFlex
                            s1

                    Ok ( Nothing, s1 ) ->
                        -- INTERNALIZE.
                        let
                            ( store1, desc ) =
                                UF.get src s1.store

                            s2 =
                                { s1 | store = store1 }

                            visited1 =
                                key :: visited
                        in
                        case desc.content of
                            Vars.Structure (Vars.LambdaSet1 (Vars.LsTop _)) ->
                                Ok ( ( Nothing, sawFlex ), s2 )

                            Vars.Structure (Vars.LambdaSet1 (Vars.LsMembers ms)) ->
                                sigEdgesGo slots i rest visited1 (IO.unionSortedAsc accMembers ms) accOrdinals sawFlex s2

                            Vars.Structure (Vars.LambdaSet1 (Vars.LsFrom ms ss)) ->
                                sigEdgesGo slots i (ss ++ rest) visited1 (IO.unionSortedAsc accMembers ms) accOrdinals sawFlex s2

                            Vars.FlexVar _ ->
                                -- LSS_026(a): a dangling inflow. Contributes
                                -- no members, but the crossing is recorded —
                                -- `sigResolveEdges` applies the policy.
                                sigEdgesGo slots i rest visited1 accMembers accOrdinals True s2

                            _ ->
                                -- Defensive: fail toward ⊤ (§2.3's direction
                                -- rule).
                                Ok ( ( Nothing, sawFlex ), s2 )


{-| The signature ordinal a Point IS (UF-equivalent to `slots[j]`, `j /= i`),
scanning ALL ordinals — unlike `repOrdinal`, which scans only below `i`.
-}
ordinalOf : Array Vars.Variable -> Int -> Vars.Variable -> Step (Maybe Int)
ordinalOf slots i node s0 =
    ordinalOfGo slots i node 0 s0


ordinalOfGo : Array Vars.Variable -> Int -> Vars.Variable -> Int -> Step (Maybe Int)
ordinalOfGo slots i node j s0 =
    if j >= Array.length slots then
        Ok ( Nothing, s0 )

    else if j == i then
        ordinalOfGo slots i node (j + 1) s0

    else
        case Array.get j slots of
            Nothing ->
                Ok ( Nothing, s0 )

            Just other ->
                let
                    ( store1, eq ) =
                        UF.equivalent node other s0.store

                    s1 =
                        { s0 | store = store1 }
                in
                if eq then
                    Ok ( Just j, s1 )

                else
                    ordinalOfGo slots i node (j + 1) s1


{-| The B.4 cap and final shaping for a resolved `LsFrom` fact: over-cap
resolved members ⇒ ⊤ (sources DROPPED — ⊤ absorbs; `widenedBySigSize`
bumped), else the members-plus-sources fact.
-}
finishSigFact : Int -> { top : Bool, members : List Int, sources : List Int } -> Engine.S -> ( Engine.ArrowFact, Engine.S )
finishSigFact rep resolved s0 =
    if resolved.top then
        -- §4.9: an edge-resolved ⊤ (the DFS ⊤ marker drops the birth kind).
        ( { rep = rep, members = [], top = True, topKind = Mono.tkEdge, sources = [] }, s0 )

    else if s0.env.lss.maxSetSize > 0 && List.length resolved.members > s0.env.lss.maxSetSize then
        ( { rep = rep, members = [], top = True, topKind = Mono.tkWiden, sources = [] }
        , Engine.bumpWidenedBySigSize s0
        )

    else
        ( { rep = rep, members = resolved.members, top = False, topKind = Mono.tkLegacy, sources = resolved.sources }, s0 )


{-| The smallest ordinal j < i whose slot is UF-equivalent to this one (i if
none). Arrows-per-signature is small; the O(n²) is on n ≈ arity.
-}
repOrdinal : Array Vars.Variable -> Vars.Variable -> Int -> Int -> Step Int
repOrdinal slots slot i j s0 =
    if j >= i then
        Ok ( i, s0 )

    else
        case Array.get j slots of
            Nothing ->
                Ok ( i, s0 )

            Just other ->
                let
                    ( store1, eq ) =
                        UF.equivalent other slot s0.store
                in
                if eq then
                    Ok ( j, { s0 | store = store1 } )

                else
                    repOrdinal slots slot i (j + 1) { s0 | store = store1 }



-- ====== THE WALK ======


{-| letEnv: bound name — let-bound, or (under `lss.sigFlow`) lambda/tail-def
param — -> its loaded type Point (for the §7.4 set-slot-only join at use
sites).
-}
type alias LetEnv =
    Dict Name Vars.Variable


{-| LSS\_020 (plan B.0): what a walked expression hands its parent — the Point
the walk loaded for the expr's own type, tagged with an HONESTY class. The
class is the soundness core of the control-flow joins: a published (non-⊤)
set claims to list EVERY runtime inhabitant, so a hub may join member-bearing
branches only when every branch's contribution is complete.

  - `WpHonest p`: p's slot contents are COMPLETE-or-⊤ for this value —
    injected identities (lambda literals, standalone refs), letEnv-linked
    flow (the family's own invariant covers it), or an already-poisoned
    point (⊤ is honest).
  - `WpOpaque p`: a real point whose slots may be INCOMPLETE — call results
    (callee facts are honest lower bounds, but a blind callee yields EMPTY,
    not ⊤). Sound for SINGLE-SOURCE joins (root/result/let-rhs: empty facts
    are sound — consumers default to ⊤ on unconstrained reads) but must not
    be MIXED with member-bearing mates in a hub (a partial non-empty set
    claims completeness — the false-singleton devirt vector).
  - `WpSelf`: a tail call of the enclosing tail def. Its value IS the value
    under construction: in a hub it contributes no NEW inhabitants and is
    skipped — the μ-equation X = b₁ ∪ … ∪ X solves to the union of the other
    branches, and any hub containing it is itself joined into the def's
    result class by the enclosing walk, making the self edge redundant.
  - `WpNone`: no point — containers, literals, pattern-bound locals, the
    structural wildcard. The value's inhabitants are untracked; in a hub
    this forces ⊤.

-}
type WalkPoint
    = WpNone
    | WpSelf
    | WpHonest Vars.Variable
    | WpOpaque Vars.Variable


wpPoint : WalkPoint -> Maybe Vars.Variable
wpPoint wp =
    case wp of
        WpHonest p ->
            Just p

        WpOpaque p ->
            Just p

        WpNone ->
            Nothing

        WpSelf ->
            Nothing


walkExpr : LetEnv -> TOpt.Expr TypeIds.MVarId -> Step WalkPoint
walkExpr letEnv expr s0 =
    case expr of
        TOpt.Function srcLam params body meta ->
            walkFunction (List.map Tuple.first params) srcLam body meta letEnv s0

        TOpt.TrackedFunction srcLam params body meta ->
            walkFunction (List.map (\( locName, _ ) -> A.toValue locName) params) srcLam body meta letEnv s0

        TOpt.Call _ func args meta ->
            case walkCall letEnv func args meta s0 of
                Err e ->
                    Err e

                Ok ( wp, s1 ) ->
                    case walkChildren letEnv (func :: args) s1 of
                        Err e ->
                            Err e

                        Ok ( _, s2 ) ->
                            Ok ( wp, s2 )

        TOpt.VarGlobal _ g meta ->
            case kernelAliasOf g s0 of
                Just ( kernelPrefix, home, name ) ->
                    -- E9.2 (LSS_016) identity fold: a kernel-ALIAS global
                    -- (`cons = Elm.Kernel.List.cons`) IS the kernel value —
                    -- mint the kernel member so the alias body's own VarKernel
                    -- occurrence and every reference share ONE identity (a
                    -- split g|/k| identity would join to a 2-set and kill
                    -- every singleton consumer).
                    -- Kernels stay HEAD-ONLY at both mint sites: `kernelToSig`
                    -- misaligns at inner arrows (it takes the first n modes of
                    -- the full sig against a residual param row), so keeping
                    -- `k|` members off inner arrows makes that hazard
                    -- unreachable by construction.
                    -- refPapSpine: successors key by the ALIAS global —
                    -- the k| head is untouched (kernelToSig hazard is k|-only).
                    withPapSuccessors g
                        (standaloneMemberWith (Engine.kernelMemberIdFor ("k|" ++ home ++ "." ++ name) ( kernelPrefix, home, name )) meta)
                        s0

                Nothing ->
                    case
                        withPapSuccessors g
                            (standaloneMemberWith (Engine.standaloneMemberIdFor ("g|" ++ TOpt.toComparableGlobal g) g) meta)
                            s0
                    of
                        Err e ->
                            Err e

                        okOther ->
                            okOther

        TOpt.VarEnum _ g _ meta ->
            -- E9: ctor mints register the Global for devirt lookup.
            withPapSuccessors g
                (standaloneMemberWith (Engine.standaloneMemberIdFor ("c|" ++ TOpt.toComparableGlobal g) g) meta)
                s0

        TOpt.VarBox _ g meta ->
            withPapSuccessors g
                (standaloneMemberWith (Engine.standaloneMemberIdFor ("c|" ++ TOpt.toComparableGlobal g) g) meta)
                s0

        TOpt.VarCycle _ home name meta ->
            -- GAP-7 seam 1 (LSS_020 plan Phase E.1): a cycle member mints
            -- its `g|` head exactly as the VarGlobal arm does. Standalone
            -- members are HEAD-ONLY — the `lss.spineArity` flag that could
            -- deepen them to `declaredArity` was deleted 2026-09-17
            -- (plans/remove-default-off-lss-flags.md); depth beyond the head
            -- belongs to `papMembers`' `p|` successors, which is what keeps
            -- one runtime value from carrying two names.
            withPapSuccessors (TOpt.Global home name)
                (standaloneMemberWith (Engine.standaloneMemberIdFor ("g|" ++ TOpt.toComparableGlobal (TOpt.Global home name)) (TOpt.Global home name)) meta)
                s0

        TOpt.VarKernel _ kernelPrefix home name meta ->
            -- E9.2: kernel mints register (prefix, home, name) for devirt
            -- lookup — the "k|" key (and so the member id) is unchanged.
            -- Head-only: see the kernel-alias arm above.
            standaloneMemberWith (Engine.kernelMemberIdFor ("k|" ++ home ++ "." ++ name) ( kernelPrefix, home, name )) meta s0

        TOpt.Accessor _ field meta ->
            -- `.field` is itself a chomper shape; this arm stays 1 forever.
            standaloneMember ("a|" ++ field) meta s0

        TOpt.VarLocal name meta ->
            joinLetUse letEnv name meta s0

        TOpt.TrackedVarLocal _ name meta ->
            joinLetUse letEnv name meta s0

        TOpt.Let def body _ ->
            case def of
                TOpt.Def _ name rhs defType ->
                    case walkExpr letEnv rhs s0 of
                        Err e ->
                            Err e

                        Ok ( rhsWp, s1 ) ->
                            case Store.loadType defType s1 of
                                Err e ->
                                    Err e

                                Ok ( rhsVar, s2 ) ->
                                    -- LSS_020 (B.2): flag-on, connect the
                                    -- letEnv hub to the RHS's returned flow
                                    -- (single-source join; no-op flag-off).
                                    case sigFlowJoinInto rhsVar (wpPoint rhsWp) s2 of
                                        Err e ->
                                            Err e

                                        Ok ( _, s3 ) ->
                                            walkExpr (CoreDict.insert name rhsVar letEnv) body s3

                TOpt.TailDef _ name args rhs defType _ ->
                    if s0.env.lss.sigFlow then
                        -- LSS_020 (B.2): the rhs is the ARG-STRIPPED body at
                        -- the RESULT type while `defType` is the full
                        -- function type — peel |args| arrows off the loaded
                        -- hub (binding the args, closing leak 1 for local
                        -- loops), then single-source-join the spine end
                        -- against the rhs's returned flow.
                        case Store.loadType defType s0 of
                            Err e ->
                                Err e

                            Ok ( rhsVar, s1 ) ->
                                let
                                    ( env1, maybeRes, s2 ) =
                                        bindParamsFromSpine
                                            (List.map (\( locName, _ ) -> A.toValue locName) args)
                                            rhsVar
                                            CoreDict.empty
                                            letEnv
                                            s1
                                in
                                case walkExpr env1 rhs s2 of
                                    Err e ->
                                        Err e

                                    Ok ( rhsWp, s3 ) ->
                                        case ( maybeRes, wpPoint rhsWp ) of
                                            ( Just resVar, Just p ) ->
                                                case joinArrowSetsSig resVar p s3 of
                                                    Err e ->
                                                        Err e

                                                    Ok ( _, s4 ) ->
                                                        walkExpr (CoreDict.insert name rhsVar letEnv) body s4

                                            _ ->
                                                walkExpr (CoreDict.insert name rhsVar letEnv) body s3

                    else
                        case walkExpr letEnv rhs s0 of
                            Err e ->
                                Err e

                            Ok ( _, s1 ) ->
                                case Store.loadType defType s1 of
                                    Err e ->
                                        Err e

                                    Ok ( rhsVar, s2 ) ->
                                        walkExpr (CoreDict.insert name rhsVar letEnv) body s2

        TOpt.Destruct _ body _ ->
            -- Propagate: a Destruct's value is its body's. Identical store
            -- ops to the old structural arm (directChildren = [ body ]).
            walkExpr letEnv body s0

        TOpt.If branches finally meta ->
            -- Children in EXACTLY the structural arm's order (cond, branch
            -- per pair, then finally), collecting the branch VALUES' flow;
            -- then the hub join (LSS_020 B.2; no-op flag-off).
            case walkIfPairs letEnv branches [] s0 of
                Err e ->
                    Err e

                Ok ( branchWps, s1 ) ->
                    case walkExpr letEnv finally s1 of
                        Err e ->
                            Err e

                        Ok ( finalWp, s2 ) ->
                            joinCfHub (finalWp :: branchWps) meta s2

        TOpt.Case _ _ decider jumps meta ->
            -- All Case children are branch VALUES (decider Inline leaves +
            -- jump bodies); same order as the structural arm.
            case walkCollect letEnv (deciderExprs decider ++ List.map Tuple.second jumps) [] s0 of
                Err e ->
                    Err e

                Ok ( wps, s1 ) ->
                    joinCfHub wps meta s1

        TOpt.TailCall _ tcArgs _ ->
            -- Children exactly as the structural arm walked them; `WpSelf` —
            -- the self edge is redundant in hubs (see `WalkPoint`).
            case walkChildren letEnv (List.map Tuple.second tcArgs) s0 of
                Err e ->
                    Err e

                Ok ( _, s1 ) ->
                    Ok ( WpSelf, s1 )

        -- F4-sig (plans/lss-container-payload-transport.md §12.10.1): literals
        -- hand their parent a POINT — flag-off, exactly the structural arm.
        TOpt.Record fields meta ->
            walkLiteral letEnv "record" (CoreDict.toList fields) Nothing meta expr s0

        TOpt.TrackedRecord _ fields meta ->
            walkLiteral letEnv "record" (List.map (\( ln, e ) -> ( A.toValue ln, e )) (DMap.toList A.compareLocated fields)) Nothing meta expr s0

        TOpt.Tuple _ a b rest meta ->
            walkLiteral letEnv "tuple" (List.indexedMap (\i e -> ( String.fromInt i, e )) (a :: b :: rest)) Nothing meta expr s0

        TOpt.List _ items meta ->
            walkLiteral letEnv "list" (List.map (\e -> ( "l", e )) items) Nothing meta expr s0

        TOpt.Update _ record fields meta ->
            walkLiteral letEnv "update" (List.map (\( ln, e ) -> ( A.toValue ln, e )) (DMap.toList A.compareLocated fields)) (Just record) meta expr s0

        _ ->
            -- Everything else: structural recursion only. Shared MVarIds
            -- already carry the intra-def flow; re-implementing translate's
            -- demand-concretization corners here would be wrong-layer work.
            case walkChildren letEnv (directChildren expr) s0 of
                Err e ->
                    Err e

                Ok ( _, s1 ) ->
                    Ok ( WpNone, s1 )


{-| LSS\_020 (B.1.e): the `Function`/`TrackedFunction` arm body. Flag-on it
binds the params from the lambda's OWN loaded spine into letEnv (the root
join in `walkMembers` makes the annotation slots reachable through UF
transitivity — the existing `VarLocal` arms then join every param occurrence
for free) and joins the spine's result position against the body's returned
flow (single-source: Honest|Opaque). Flag-off: byte-for-byte today's
sequence.
-}
walkFunction : List Name -> Maybe TypeIds.SrcLambdaId -> TOpt.Expr TypeIds.MVarId -> TOpt.Meta TypeIds.MVarId -> LetEnv -> Step WalkPoint
walkFunction paramNames srcLam body meta letEnv s0 =
    case Store.loadType meta.tipe s0 of
        Err e ->
            Err e

        Ok ( funcVar, s1 ) ->
            case injectLambdaMember (List.length paramNames) srcLam funcVar s1 of
                Err e ->
                    Err e

                Ok ( _, s2 ) ->
                    if s2.env.lss.sigFlow then
                        let
                            ( letEnv1, maybeRes, s3 ) =
                                bindParamsFromSpine paramNames funcVar CoreDict.empty letEnv s2
                        in
                        case walkExpr letEnv1 body s3 of
                            Err e ->
                                Err e

                            Ok ( wp, s4 ) ->
                                case ( maybeRes, wpPoint wp ) of
                                    ( Just resVar, Just bodyPt ) ->
                                        case joinArrowSetsSig resVar bodyPt s4 of
                                            Err e ->
                                                Err e

                                            Ok ( _, s5 ) ->
                                                Ok ( WpHonest funcVar, s5 )

                                    _ ->
                                        Ok ( WpHonest funcVar, s4 )

                    else
                        case walkExpr letEnv body s2 of
                            Err e ->
                                Err e

                            Ok ( _, s3 ) ->
                                Ok ( WpHonest funcVar, s3 )


{-| F4-sig (plans/lss-container-payload-transport.md §12.10.1): a record /
tuple / list / update literal's WalkPoint. Flag-off: the structural arm
verbatim (`WpNone`). Flag-on: walk the elements (the same children the
structural arm walks, so member injection inside them is unchanged), load the
literal's own type, join every element's point into its slot of that type
(structurally — `joinArrowSetsSig`, as the result join already is), and hand
back the literal's var — HONEST only if every arrow-bearing element (and the
update's base) handed an honest point, else OPAQUE (the hub rule: a partially
visible container must not be mixed with member-bearing mates). An element
whose slot cannot be located leaves it unwritten (var — no claim).
-}
walkLiteral : LetEnv -> String -> List ( String, TOpt.Expr TypeIds.MVarId ) -> Maybe (TOpt.Expr TypeIds.MVarId) -> TOpt.Meta TypeIds.MVarId -> TOpt.Expr TypeIds.MVarId -> Step WalkPoint
walkLiteral letEnv form elems maybeBase meta expr s0 =
    if not (s0.env.lss.enabled && s0.env.lss.flow.litFacts) then
        case walkChildren letEnv (directChildren expr) s0 of
            Err e ->
                Err e

            Ok ( _, s1 ) ->
                Ok ( WpNone, s1 )

    else
        case walkMaybe letEnv maybeBase s0 of
            Err e ->
                Err e

            Ok ( baseWp, s1 ) ->
                case walkKeyed letEnv elems [] s1 of
                    Err e ->
                        Err e

                    Ok ( wps, s2 ) ->
                        case Store.loadType meta.tipe s2 of
                            Err e ->
                                Err e

                            Ok ( litVar, s3 ) ->
                                case joinLiteralBase litVar baseWp s3 of
                                    Err e ->
                                        Err e

                                    Ok ( _, s4 ) ->
                                        case joinLiteralElems form litVar wps s4 of
                                            Err e ->
                                                Err e

                                            Ok ( _, s5 ) ->
                                                let
                                                    elemHonest ( ( _, e ), wp ) =
                                                        not (canTypeMentionsArrow (TOpt.typeOf e)) || isHonest wp

                                                    baseHonest =
                                                        case ( maybeBase, baseWp ) of
                                                            ( Just _, Just wp ) ->
                                                                isHonest wp

                                                            ( Just _, Nothing ) ->
                                                                False

                                                            ( Nothing, _ ) ->
                                                                True

                                                    honest =
                                                        baseHonest && List.all elemHonest (List.map2 (\e ( _, wp ) -> ( e, wp )) elems wps)
                                                in
                                                Ok
                                                    ( if honest then
                                                        WpHonest litVar

                                                      else
                                                        WpOpaque litVar
                                                    , Engine.bumpArgFlowCensus
                                                        ("litFacts|"
                                                            ++ form
                                                            ++ (if honest then
                                                                    "|honest"

                                                                else
                                                                    "|opaque"
                                                               )
                                                        )
                                                        s5
                                                    )


isHonest : WalkPoint -> Bool
isHonest wp =
    case wp of
        WpHonest _ ->
            True

        _ ->
            False


walkMaybe : LetEnv -> Maybe (TOpt.Expr TypeIds.MVarId) -> Step (Maybe WalkPoint)
walkMaybe letEnv maybeExpr s0 =
    case maybeExpr of
        Nothing ->
            Ok ( Nothing, s0 )

        Just e ->
            case walkExpr letEnv e s0 of
                Err err ->
                    Err err

                Ok ( wp, s1 ) ->
                    Ok ( Just wp, s1 )


walkKeyed : LetEnv -> List ( String, TOpt.Expr TypeIds.MVarId ) -> List ( String, WalkPoint ) -> Step (List ( String, WalkPoint ))
walkKeyed letEnv elems acc s0 =
    case elems of
        [] ->
            Ok ( List.reverse acc, s0 )

        ( k, e ) :: rest ->
            case walkExpr letEnv e s0 of
                Err err ->
                    Err err

                Ok ( wp, s1 ) ->
                    walkKeyed letEnv rest (( k, wp ) :: acc) s1


joinLiteralBase : Vars.Variable -> Maybe WalkPoint -> Step ()
joinLiteralBase litVar baseWp s0 =
    case Maybe.andThen wpPoint baseWp of
        Just p ->
            joinArrowSetsSig litVar p s0

        Nothing ->
            Ok ( (), s0 )


{-| Locate each element's slot in the literal's loaded type and join the
element's point into it. Records by field name, tuples by position, lists all
into the one element slot. Aliases chased; any other shape leaves the slots
unwritten (counted).
-}
joinLiteralElems : String -> Vars.Variable -> List ( String, WalkPoint ) -> Step ()
joinLiteralElems form litVar wps s0 =
    case Engine.liftIO (UF.get litVar) s0 of
        Err e ->
            Err e

        Ok ( desc, s1 ) ->
            case desc.content of
                Vars.Alias _ _ _ real ->
                    joinLiteralElems form real wps s1

                Vars.Structure (Vars.Record1 fields _) ->
                    joinKeyedSlots (List.map (\( k, wp ) -> ( CoreDict.get k fields, wp )) wps) s1

                Vars.Structure (Vars.Tuple1 a b rest) ->
                    joinKeyedSlots (List.map2 (\slot ( _, wp ) -> ( Just slot, wp )) (a :: b :: rest) wps) s1

                Vars.Structure (Vars.App1 _ "List" [ elem ]) ->
                    joinKeyedSlots (List.map (\( _, wp ) -> ( Just elem, wp )) wps) s1

                _ ->
                    Ok ( (), Engine.bumpArgFlowCensus ("litFacts|shapeMiss|" ++ form) s1 )


joinKeyedSlots : List ( Maybe Vars.Variable, WalkPoint ) -> Step ()
joinKeyedSlots pairs s0 =
    case pairs of
        [] ->
            Ok ( (), s0 )

        ( maybeSlot, wp ) :: rest ->
            case ( maybeSlot, wpPoint wp ) of
                ( Just slot, Just p ) ->
                    case joinArrowSetsSig slot p s0 of
                        Err e ->
                            Err e

                        Ok ( _, s1 ) ->
                            joinKeyedSlots rest s1

                _ ->
                    joinKeyedSlots rest s0


{-| Call handling. Global callee: instantiate with signature facts and unify
params/result (best-effort). Kernel/Debug callee: every arrow crossing the
ABI is dynamic — poison arg and result arrows (LSS\_004). Local callee
(LSS\_020 B.3, under `lss.sigFlow`): slot-only call-shape join against the
letEnv family — NEVER whole-type unification of the shared family Point
(§7.4). Anything else: children only (the caller recurses via walkChildren).
-}
walkCall : LetEnv -> TOpt.Expr TypeIds.MVarId -> List (TOpt.Expr TypeIds.MVarId) -> TOpt.Meta TypeIds.MVarId -> Step WalkPoint
walkCall letEnv func args meta s0 =
    case func of
        TOpt.VarGlobal _ g funcMeta ->
            applyCalleeAt g funcMeta.tipe args meta s0

        TOpt.VarCycle _ home name funcMeta ->
            applyCalleeAt (TOpt.Global home name) funcMeta.tipe args meta s0

        TOpt.VarKernel _ _ home name funcMeta ->
            -- LSS_021/LSS_022: consult the audited set-flow table — licensed
            -- kernels behave like a plain callee, positional rows refine per
            -- param, no row / arity mismatch keeps LSS_004 full poison.
            kernelCallBoundary home name funcMeta args meta s0

        TOpt.VarDebug _ _ _ _ _ ->
            poisonCallBoundary args meta s0

        TOpt.VarLocal name _ ->
            localCalleeJoin letEnv name args meta s0

        TOpt.TrackedVarLocal _ name _ ->
            localCalleeJoin letEnv name args meta s0

        TOpt.VarEnum _ g _ funcMeta ->
            -- A ctor call carries no member of its own: the ctor's payload
            -- members reach the site through the argument walk, not through
            -- the callee.
            Ok ( WpNone, s0 )

        TOpt.VarBox _ _ _ ->
            Ok ( WpNone, s0 )

        _ ->
            Ok ( WpNone, s0 )


applyCalleeAt : TOpt.Global -> Can.Type TypeIds.MVarId -> List (TOpt.Expr TypeIds.MVarId) -> TOpt.Meta TypeIds.MVarId -> Step WalkPoint
applyCalleeAt g funcFallbackType args meta s0 =
    let
        gkey =
            TOpt.toComparableGlobal g

        srcType =
            sigSourceTypeFor g funcFallbackType s0
    in
    if CoreDict.member gkey s0.lssInProgress then
        -- Σ self/sibling reference within the in-flight unit: the annotation
        -- loads through the SHARED scratch memo, so its Points ARE the
        -- member's own signature slots — unifying against them is the
        -- paper's TIU-Self-Ref rule (which forbids polymorphic recursion in
        -- set parameters and guarantees termination).
        case Store.loadType srcType s0 of
            Err e ->
                Err e

            Ok ( funcVar, s1 ) ->
                case unifyCallShape funcVar args meta s1 of
                    Err e ->
                        Err e

                    Ok ( callVar, s2 ) ->
                        injectPapMemberInfer g (List.length args) callVar s2

    else
        case instantiateWithSignature g srcType s0 of
            Err e ->
                Err e

            Ok ( funcVar, s1 ) ->
                case unifyCallShape funcVar args meta s1 of
                    Err e ->
                        Err e

                    Ok ( callVar, s2 ) ->
                        injectPapMemberInfer g (List.length args) callVar s2


{-| INJECTION COMPLETENESS, inference side (the twin of
`Translate.injectPapMember`; plans/lss-injection-completeness.md §2.4).

`unifyCallShape` returns the call's OWN loaded Point — for a partial
application that Point IS the residual type, already unified with the
instantiation's remaining arrows by `unifyParamsBestEffort`. So unlike the
translate side there is no spine to descend: inject straight into `callVar`.

Without this twin the two sides fall out of lockstep: a def whose body RETURNS
a partial application would carry the member in its specialization demand but
not at its signature's residual ordinal, so callers of that def would not see
it.

**Identity and depth follow `Translate.injectPapMember` exactly** — a distinct
`p|<global>|<supplied>` element (NEVER the callee's `g|`/`k|` id, which
denotes the unapplied global and licenses a direct-call rewrite a PAP cannot
support), injected HEAD-ONLY because one arrow deeper is a different PAP and
therefore a different element. That function's docs carry the full argument
and the miscompile it was corrected from.

Returns the `WalkPoint` unchanged — this is a pure store write.

-}
injectPapMemberInfer : TOpt.Global -> Int -> Vars.Variable -> Step WalkPoint
injectPapMemberInfer g argCount callVar s0 =
    if not (s0.env.lss.enabled && s0.env.lss.papMembers) then
        Ok ( WpOpaque callVar, s0 )

    else if declaredArityOf g 8 s0 <= argCount then
        Ok ( WpOpaque callVar, s0 )

    else
        let
            injected =
                Engine.andThen
                    (\mid -> injectSpineMemberId 1 mid callVar)
                    (Engine.papMemberIdFor g argCount)
                    s0
        in
        case injected of
            Err e ->
                Err e

            Ok ( _, s1 ) ->
                -- L2 (lss.injTotal): finish the deep residual — twin of the
                -- Translate producer site, same keys, same walk.
                case injectPapSuccessorsFrom g (argCount + 1) callVar s1 of
                    Err e ->
                        Err e

                    Ok ( _, s2 ) ->
                        Ok ( WpOpaque callVar, s2 )


{-| Unify a callee instantiation's params against the args and its residual
against the call's own type, so returned arrows carry their sets into this
def's flow. Returns the call's own loaded Point (the value the parent may
propagate — `WpOpaque` class). ISOLATED-instantiation path only: the
whole-type best-effort unify here must never target a shared letEnv family
Point (§7.4; local callees go through `joinCallArgs` instead).
-}
unifyCallShape : Vars.Variable -> List (TOpt.Expr TypeIds.MVarId) -> TOpt.Meta TypeIds.MVarId -> Step Vars.Variable
unifyCallShape funcVar args meta s0 =
    case unifyParamsBestEffort funcVar args s0 of
        Err e ->
            Err e

        Ok ( restVar, s1 ) ->
            case Store.loadType meta.tipe s1 of
                Err e ->
                    Err e

                Ok ( callVar, s2 ) ->
                    case Store.unifyBestEffort restVar callVar s2 of
                        Err e ->
                            Err e

                        Ok ( _, s3 ) ->
                            Ok ( callVar, s3 )


{-| Liveness census (plans/lss-provenance-ratio-census.md §7): this arrow is
being peeled into (param, rest) because an argument is being passed to it — so
it is APPLIED. Not a proxy for application; this IS the application.

The `ArrowId` lookup goes through the union-find CLASS, not the raw Point, for
`noteMultiSet`'s reason: the slot that survives a unification is often not the
slot that was minted, and only the loaded side ever carries an ArrowId. Using
the raw Point would silently miss every arrow that unified with a
demand-encoded one — the same keyspace discipline the multi-set census uses,
which is what lets var/set/applied intersect exactly.

Report-gated twice over: `bumpAppliedArrow` checks `lss.report`, and
`arrowOfSlot` is empty without it anyway.

-}
noteApplied : Vars.Content -> Engine.S -> Engine.S
noteApplied content s =
    if not s.env.lss.arrowCensus then
        -- Gated on its OWN flag, not `report` (§7.7): this runs per
        -- APPLICATION — 512,757 times on one self-compile — and the benchmark
        -- protocol mandates `report`, so leaving it there bills every timed
        -- run. `qCensus` was split out for precisely this reason.
        s

    else
        -- POSITIVE CONTROL (§7.6). Every call of this function IS an
        -- application — we are peeling an arrow precisely because an argument
        -- is being passed — so `apply|attempt` is a ground-truth denominator
        -- that assumes NO relationship between resolution and application.
        -- That is what the first control got wrong: it presumed concrete
        -- arrows are concrete BECAUSE called, which is false for a function
        -- held in a record field or returned and never invoked.
        --
        -- The split then says exactly where applications are lost:
        --   noSlot     — the content was not a `FunL` (no set slot to name)
        --   noArrowId  — a slot, but `arrowOfSlot` cannot name it
        --   hit        — named, and counted in `appliedArrows`
        -- A high hit rate means `appliedArrows` is a FAIR sample of the
        -- applications on hooked paths, and a low set-overlap is then a real
        -- property rather than an instrument artefact.
        let
            sA =
                Engine.bumpArgFlowCensus "apply|attempt" s
        in
        case Store.arrowSetSlot content of
            Nothing ->
                Engine.bumpArgFlowCensus "apply|noSlot" sA

            Just pSet ->
                let
                    ( store1, reprVar ) =
                        UF.repr pSet sA.store

                    s1 =
                        { sA | store = store1 }
                in
                case CoreDict.get (Engine.pointKey reprVar) s1.itemAux.arrowOfSlot of
                    Nothing ->
                        Engine.bumpArgFlowCensus "apply|noArrowId" s1

                    Just aid ->
                        Engine.bumpArgFlowCensus "apply|hit" (Engine.bumpAppliedArrow aid s1)


{-| Unify each argument against the callee's corresponding parameter, one
arrow peeled per argument. Each argument's TYPE is loaded fresh — the known
A.1 leak: members the argument WALK minted sit in a class this load never
connects to the param, so signatures can read allflex at a position the
argument did feed. `lss.argPoints` carried a mechanism that handed the walked
point here instead; it measured negative and then inert, and was deleted
2026-09-17 (plans/remove-default-off-lss-flags.md §2).
-}
unifyParamsBestEffort : Vars.Variable -> List (TOpt.Expr TypeIds.MVarId) -> Step Vars.Variable
unifyParamsBestEffort funcVar args s0 =
    case args of
        [] ->
            Ok ( funcVar, s0 )

        arg :: rest ->
            let
                ( store1, desc ) =
                    UF.get funcVar s0.store

                s1 =
                    { s0 | store = store1 }
            in
            case Store.arrowParts desc.content of
                Just ( pParam, pRest ) ->
                    case Store.loadType (TOpt.typeOf arg) (noteApplied desc.content s1) of
                        Err e ->
                            Err e

                        Ok ( argVar, s2 ) ->
                            case Store.unifyBestEffort pParam argVar s2 of
                                Err e ->
                                    Err e

                                Ok ( _, s3 ) ->
                                    unifyParamsBestEffort pRest rest s3

                Nothing ->
                    -- Over-applied or opaque at this depth: stop.
                    Ok ( funcVar, s1 )


{-| LSS\_020 (B.3): a call whose callee is a letEnv-bound local. Slot-only
call-shape join against the family Point: one arrow peeled per arg (arg-type
loads guarded by `canTypeMentionsArrow`), the spine end joined against the
call's own type. The result-side join is the payload (the family's
result-arrow members reach the site); the arg-side joins are cheap structure
that becomes live if the arg-load residue (plan §A.1) is ever fixed.
-}
localCalleeJoin : LetEnv -> Name -> List (TOpt.Expr TypeIds.MVarId) -> TOpt.Meta TypeIds.MVarId -> Step WalkPoint
localCalleeJoin letEnv name args meta s0 =
    if not s0.env.lss.sigFlow then
        Ok ( WpNone, s0 )

    else
        case CoreDict.get name letEnv of
            Nothing ->
                Ok ( WpNone, s0 )

            Just fVar ->
                case joinCallArgs fVar args CoreDict.empty s0 of
                    Err e ->
                        Err e

                    Ok ( maybeRest, s1 ) ->
                        case maybeRest of
                            Nothing ->
                                -- Over-applied/opaque spine: stop (sound —
                                -- nothing joined, nothing claims
                                -- completeness).
                                Ok ( WpNone, s1 )

                            Just restVar ->
                                if canTypeMentionsArrow meta.tipe then
                                    case Store.loadType meta.tipe s1 of
                                        Err e ->
                                            Err e

                                        Ok ( callVar, s2 ) ->
                                            -- LSS_023 directed: the callee's
                                            -- residual flows INTO the call.
                                            case flowArrowSetsSig restVar callVar s2 of
                                                Err e ->
                                                    Err e

                                                Ok ( _, s3 ) ->
                                                    Ok ( WpOpaque callVar, s3 )

                                else
                                    Ok ( WpNone, s1 )


{-| Descend a family Point's arrow spine one arrow per argument, slot-joining
each (arrow-bearing) arg's loaded type against the param position. Returns
the spine position after the last arg (Nothing on early stop). The `seen`
set guards the transparent-alias chase, mirroring `spineGoC`.
-}
joinCallArgs : Vars.Variable -> List (TOpt.Expr TypeIds.MVarId) -> Dict Int () -> Step (Maybe Vars.Variable)
joinCallArgs v args seen s0 =
    case args of
        [] ->
            Ok ( Just v, s0 )

        arg :: rest ->
            let
                key =
                    Engine.pointKey v

                ( store1, desc ) =
                    UF.get v s0.store

                s1 =
                    { s0 | store = store1 }
            in
            if CoreDict.member key seen then
                Ok ( Nothing, s1 )

            else
                case desc.content of
                    Vars.Alias _ _ _ real ->
                        joinCallArgs real args (CoreDict.insert key () seen) s1

                    _ ->
                        case Store.arrowParts desc.content of
                            Just ( pParam, pRest ) ->
                                if canTypeMentionsArrow (TOpt.typeOf arg) then
                                    case Store.loadType (TOpt.typeOf arg) s1 of
                                        Err e ->
                                            Err e

                                        Ok ( argVar, s2 ) ->
                                            -- LSS_023 directed: the argument
                                            -- flows INTO the param family.
                                            case flowArrowSetsSig argVar pParam s2 of
                                                Err e ->
                                                    Err e

                                                Ok ( _, s3 ) ->
                                                    joinCallArgs pRest rest (CoreDict.insert key () seen) s3

                                else
                                    joinCallArgs pRest rest (CoreDict.insert key () seen) s1

                            Nothing ->
                                Ok ( Nothing, s1 )


{-| A kernel call boundary, resolved against the audited set-flow table.

`TypeFaithful` (LSS\_022) is the LICENSED tier. A `Transports` license behaves
exactly like a plain callee — instantiate the kernel's own occurrence type in
an isolated memo and unify the call shape, so the type's shared variables
transport sets with no poison and no bespoke machinery. This is
`applyCalleeAt`'s non-in-progress path minus the signature facts (a kernel
has no body and therefore no signature to consult). No arity rule is needed:
`unifyCallShape` peels one arrow per arg and unifies the residual with the
call's own type, which is shape-correct for partial and over-application
alike. An `Inert` license skips the boundary entirely — see the arm.

`Positional` (LSS\_021) is the per-param tier, and it IS arity-aligned — a
mismatch (partial/over application) falls back to full poison. Per param:
`PSFOpaque` → load + poison (exactly what `poisonArgList` would do — same op
order, so rowless behavior is unchanged); `PSFApplies` → NOTHING (no load;
the arg expr is still walked by the Call arm's `walkChildren`, so member
mints are unchanged — the kernel adds no inhabitants and the caller's
knowledge survives the boundary); `PSFTunnels` → load, then set-slot-join
against the result's loaded type. Result row per `plan.result`.

`widenedByKernel` bumps ONCE iff any position poisoned (the counter keeps
meaning "boundaries that poisoned", so licensed boundaries never bump it);
`kernelFactHits` records a positional application and `kernelLicensed` a
licensed one (both report-gated, disjoint).

Honesty class of the licensed result is `WpOpaque` — a call result is
empty-or-honest and must not mix into hubs, the same contract
`applyCalleeAt` ships. The known A.1 arg-position leak applies here as
everywhere on the inference side (arg loads are fresh), so the licensed
inference path mainly buys rep-linkage into signatures; the full per-site
member transport happens translation-side, where `deriveKernelAbiTypeCall`
already unifies the real item-memo arg Points before the (now skipped)
poison.

-}
kernelCallBoundary : Name -> Name -> TOpt.Meta TypeIds.MVarId -> List (TOpt.Expr TypeIds.MVarId) -> TOpt.Meta TypeIds.MVarId -> Step WalkPoint
kernelCallBoundary home name funcMeta args meta s0 =
    case KernelSetFacts.factFor home name of
        Nothing ->
            poisonCallBoundary args meta s0

        Just (KernelSetFacts.TypeFaithful license) ->
            if not (KernelSetFacts.licenseApplies (Engine.isScalarVar s0) license funcMeta.tipe) then
                -- LSS_022 occurrence verification: this kernel is used here at
                -- a type the audit never examined (an `Inert` row whose Elm
                -- annotation grew a function-capable position, or a declared
                -- shape the occurrence does not instantiate). Fail SAFE — treat
                -- it as unaudited and poison, exactly as if no row existed.
                poisonCallBoundary args meta s0

            else
                case license.scope of
                    KernelSetFacts.Inert ->
                        -- The `vacuous` class: no arrows and no unconstrained
                        -- variables anywhere in the kernel's type, so its loaded
                        -- scheme has ZERO set slots. Poison and transport are
                        -- both provable no-ops — the boundary is skipped
                        -- outright rather than instantiated, because ~5 in 6
                        -- licensed kernels are this class and an instantiation
                        -- here would be a fixed cost on a hot path buying
                        -- nothing. `WpNone` is the honest summary: the call
                        -- contributes no members. Hub mates cannot be harmed by
                        -- it — `joinCfHub` is `canTypeMentionsArrow`-guarded on
                        -- the hub type, and an inert call's type is the hub's.
                        Ok ( WpNone, Engine.bumpKernelLicensed s0 )

                    -- `TransportsAs` behaves identically once verified — the
                    -- declared shape's only job is to make the license
                    -- checkable for a kernel the typechecker does not bound.
                    _ ->
                        case Store.loadTypeIsolated funcMeta.tipe s0 of
                            Err e ->
                                Err e

                            Ok ( funcVar, s1 ) ->
                                case unifyCallShape funcVar args meta s1 of
                                    Err e ->
                                        Err e

                                    Ok ( callVar, s2 ) ->
                                        Ok ( WpOpaque callVar, Engine.bumpKernelLicensed s2 )

        Just (KernelSetFacts.Positional plan) ->
            if List.length plan.params /= List.length args then
                poisonCallBoundary args meta s0

            else
                case kernelArgsGo plan.params args False [] s0 of
                    Err e ->
                        Err e

                    Ok ( ( argPoisoned, tunnelsRev ), s1 ) ->
                        case Store.loadType meta.tipe s1 of
                            Err e ->
                                Err e

                            Ok ( resVar, s2 ) ->
                                let
                                    resultStep =
                                        case plan.result of
                                            KernelSetFacts.PSFOpaque ->
                                                case Store.poisonArrowSets resVar s2 of
                                                    Err e ->
                                                        Err e

                                                    Ok ( _, s3 ) ->
                                                        Ok ( True, s3 )

                                            _ ->
                                                Ok ( False, s2 )
                                in
                                case resultStep of
                                    Err e ->
                                        Err e

                                    Ok ( resPoisoned, s3 ) ->
                                        case joinTunnels resVar (List.reverse tunnelsRev) s3 of
                                            Err e ->
                                                Err e

                                            Ok ( _, s4 ) ->
                                                let
                                                    s5 =
                                                        Engine.bumpKernelFactHit
                                                            (if argPoisoned || resPoisoned then
                                                                Engine.bumpWidenedByKernel s4

                                                             else
                                                                s4
                                                            )
                                                in
                                                if resPoisoned then
                                                    -- ⊤ result: honest summary.
                                                    Ok ( WpHonest resVar, s5 )

                                                else
                                                    -- Unconstrained result: the
                                                    -- value's inhabitants are
                                                    -- untracked — WpNone (hub
                                                    -- mates must not mix with it).
                                                    Ok ( WpNone, s5 )


kernelArgsGo : List KernelSetFacts.ParamSetFlow -> List (TOpt.Expr TypeIds.MVarId) -> Bool -> List Vars.Variable -> Step ( Bool, List Vars.Variable )
kernelArgsGo flows args poisoned tunnelsRev s0 =
    case ( flows, args ) of
        ( flow :: fRest, arg :: aRest ) ->
            case flow of
                KernelSetFacts.PSFOpaque ->
                    case Store.loadType (TOpt.typeOf arg) s0 of
                        Err e ->
                            Err e

                        Ok ( argVar, s1 ) ->
                            case Store.poisonArrowSets argVar s1 of
                                Err e ->
                                    Err e

                                Ok ( _, s2 ) ->
                                    kernelArgsGo fRest aRest True tunnelsRev s2

                KernelSetFacts.PSFApplies ->
                    kernelArgsGo fRest aRest poisoned tunnelsRev s0

                KernelSetFacts.PSFTunnels ->
                    case Store.loadType (TOpt.typeOf arg) s0 of
                        Err e ->
                            Err e

                        Ok ( argVar, s1 ) ->
                            kernelArgsGo fRest aRest poisoned (argVar :: tunnelsRev) s1

        _ ->
            Ok ( ( poisoned, tunnelsRev ), s0 )


joinTunnels : Vars.Variable -> List Vars.Variable -> Step ()
joinTunnels resVar vars s0 =
    case vars of
        [] ->
            Ok ( (), s0 )

        v :: rest ->
            -- LSS_023 selector: the kernel boundary itself is NOT
            -- sigFlow-gated (LSS_021 runs flag-off), so the gate lives HERE —
            -- without it, the first PSFTunnels row would mint `LsFrom`
            -- flag-off and falsify the Phase-A inertness gate (§2.2). Zero
            -- tunnel rows ship in this plan; the selector is the enabling
            -- condition for the sortBy/sortWith refinement later.
            case
                if s0.env.lss.sigFlow then
                    flowArrowSetsPlain v resVar s0

                else
                    joinArrowSets identity v resVar s0
            of
                Err e ->
                    Err e

                Ok ( _, s1 ) ->
                    joinTunnels resVar rest s1


{-| Set-slot-only join with no poison attribution — the exported form for
translation-side consumers (LSS\_021 tunnels).
-}
joinArrowSetsPlain : Vars.Variable -> Vars.Variable -> Step ()
joinArrowSetsPlain =
    joinArrowSets identity


poisonCallBoundary : List (TOpt.Expr TypeIds.MVarId) -> TOpt.Meta TypeIds.MVarId -> Step WalkPoint
poisonCallBoundary args meta s0 =
    case poisonArgList args s0 of
        Err e ->
            Err e

        Ok ( _, s1 ) ->
            case Store.loadType meta.tipe s1 of
                Err e ->
                    Err e

                Ok ( resVar, s2 ) ->
                    case Store.poisonArrowSets resVar s2 of
                        Err e ->
                            Err e

                        Ok ( _, s3 ) ->
                            -- ⊤ is an honest summary (LSS_004 boundary).
                            Ok ( WpHonest resVar, Engine.bumpWidenedByKernel s3 )


poisonArgList : List (TOpt.Expr TypeIds.MVarId) -> Step ()
poisonArgList args s0 =
    case args of
        [] ->
            Ok ( (), s0 )

        arg :: rest ->
            case Store.loadType (TOpt.typeOf arg) s0 of
                Err e ->
                    Err e

                Ok ( argVar, s1 ) ->
                    case Store.poisonArrowSets argVar s1 of
                        Err e ->
                            Err e

                        Ok ( _, s2 ) ->
                            poisonArgList rest s2


{-| A standalone function value (a named global/ctor/kernel/accessor referenced
as a value) contributes its interned member to the HEAD arrow of its OWN type at
this occurrence (LSS\_013 spine injection with an arity bound of 1; nothing to do
for non-arrows).

Head-only, not the full spine: unlike a lambda literal, a name reference carries
no local parameter count, and a global's own return may itself be a function (a
chomper combinator `... -> (State -> ChomperResult)`). Bounding to arity 1 —
identical to the pre-spine baseline for these forms — keeps the injection sound
(the head arrow is always inhabited by `m`) without descending into a returned
closure's arrows. Standalone-value PAP spine (bounded by the global's declared
arity) is a follow-up once that arity is threaded here; the primary E2 target
(lambda literals flowing into HOFs) rides the arity-bounded 'injectLambdaMember'
path instead.

-}
standaloneMember : String -> TOpt.Meta TypeIds.MVarId -> Step WalkPoint
standaloneMember key =
    standaloneMemberWith (Engine.memberIdFor key)


declaredArityOf : TOpt.Global -> Int -> Engine.S -> Int
declaredArityOf ((TOpt.Global _ name) as g) fuel s =
    declaredArityGo name g fuel s


{-| GAP-7 seam 1 (LSS\_020 plan Phase E.1): the arity walk threads the
ORIGINAL sought name through `Link` hops, because a cycle member maps as
`member -> Link(_M$first group)` — recursing with the target alone loses the
name before the `TOpt.Cycle` node is reached. `sought` stays fixed across
hops: correct for the documented single-hop pattern; a multi-hop chain
through a differently-named intermediate floors at 1 (sound — today's
behavior). Callers are the saturation checks (`papMembers`, root-fold depth,
`Translate.stampSpineGo`), NOT standalone member injection: that is head-only
since `lss.spineArity` was deleted.
-}
declaredArityGo : Name -> TOpt.Global -> Int -> Engine.S -> Int
declaredArityGo sought g fuel s =
    if fuel <= 0 then
        1

    else
        case HashMap.get TOpt.globalHash (==) g s.env.toptNodes of
            Just (TOpt.Ctor _ arity _) ->
                arity

            Just (TOpt.Box _) ->
                1

            Just (TOpt.Link target) ->
                declaredArityGo sought target (fuel - 1) s

            Just (TOpt.Define (TOpt.Function _ params _ _) _ _) ->
                List.length params

            Just (TOpt.TrackedDefine _ (TOpt.Function _ params _ _) _ _) ->
                List.length params

            -- `TrackedFunction` bodies were MISSING here until 2026-08-23,
            -- and that is the shape `LocalOpt.Typed.Module.addDefNode` emits
            -- for a def with parameters — so this walk silently floored the
            -- DOMINANT def shape at 1. It went unnoticed because the only
            -- consumer then was the dormant `lss.spineArity` (since deleted);
            -- today the saturation checks read it on every compile. Found by
            -- the LSS_026 saturation census reading `Basics.composeL` (3
            -- source params) as arity 1.
            Just (TOpt.Define (TOpt.TrackedFunction _ params _ _) _ _) ->
                List.length params

            Just (TOpt.TrackedDefine _ (TOpt.TrackedFunction _ params _ _) _ _) ->
                List.length params

            Just (TOpt.Cycle _ valueDefs funcDefs _) ->
                cycleDefArity sought valueDefs funcDefs

            -- KERNEL-ALIAS defines (`(::)` → VarGlobal List.cons, node =
            -- Define (VarKernel …)) fell through the wildcard and floored at
            -- 1 — the SECOND missing-arm defect in this walk (TrackedFunction
            -- was the first, 2026-08-23). Consequence: `(::) x` read
            -- declared=1 = supplied → "saturated" → the papMembers injection
            -- never fired on the exact shape that motivated it, and the
            -- injection-totality census inherited the same blindness (it
            -- shares this walk), so `papInject == papKnown` held while both
            -- excluded every kernel-alias partial. A kernel's declared arity
            -- IS its type's arrow spine — kernels are uncurried at their
            -- declared C++ ABI arity, so the spine count is exact for them
            -- (unlike general defs, where a returned lambda would overcount;
            -- those keep the sound floor).
            Just (TOpt.Define (TOpt.VarKernel _ _ _ _ kernelMeta) _ _) ->
                canTypeArrowSpine kernelMeta.tipe

            Just (TOpt.TrackedDefine _ (TOpt.VarKernel _ _ _ _ kernelMeta) _ _) ->
                canTypeArrowSpine kernelMeta.tipe

            _ ->
                1


{-| The length of a canonical type's outer arrow spine (aliases followed).
`a -> b -> c` = 2. Used for kernel-alias arity, where the spine IS the
declared arity.
-}
canTypeArrowSpine : Can.Type TypeIds.MVarId -> Int
canTypeArrowSpine t =
    case t of
        Can.TLambda _ _ to ->
            1 + canTypeArrowSpine to

        Can.TAlias _ _ _ (Can.Filled real) ->
            canTypeArrowSpine real

        Can.TAlias _ _ _ (Can.Holey real) ->
            canTypeArrowSpine real

        _ ->
            0


{-| Dig a cycle unit's def list for the sought member's declared param
count: `Def` bodies carry their params on the `Function` node; `TailDef`
carries an explicit typed-args list; a valueDefs hit (or no hit) floors at 1.
-}
cycleDefArity : Name -> List ( Name, TOpt.Expr TypeIds.MVarId ) -> List (TOpt.Def TypeIds.MVarId) -> Int
cycleDefArity sought valueDefs funcDefs =
    let
        fromFunc =
            List.foldl
                (\def acc ->
                    case acc of
                        Just _ ->
                            acc

                        Nothing ->
                            case def of
                                TOpt.Def _ n body _ ->
                                    if n == sought then
                                        case body of
                                            TOpt.Function _ params _ _ ->
                                                Just (List.length params)

                                            TOpt.TrackedFunction _ params _ _ ->
                                                Just (List.length params)

                                            _ ->
                                                Just 1

                                    else
                                        Nothing

                                TOpt.TailDef _ n args _ _ _ ->
                                    if n == sought then
                                        Just (List.length args)

                                    else
                                        Nothing
                )
                Nothing
                funcDefs
    in
    case fromFunc of
        Just arity ->
            arity

        Nothing ->
            -- valueDefs (arity-1 thunk shapes) and misses both floor at 1.
            1


{-| E9.2: is the global an eta-free KERNEL ALIAS — a Define whose body is
exactly a `VarKernel` reference (`cons = Elm.Kernel.List.cons`), Link-chased?
Operator-as-value canonicalizes to the aliasing GLOBAL (`(::)` becomes
`VarGlobal List.cons`), so kernel identity must be recognized through it.
-}
kernelAliasOf : TOpt.Global -> Engine.S -> Maybe ( Name, Name, Name )
kernelAliasOf g s =
    case HashMap.get TOpt.globalHash (==) g s.env.toptNodes of
        Just (TOpt.Define (TOpt.VarKernel _ kernelPrefix home name _) _ _) ->
            Just ( kernelPrefix, home, name )

        Just (TOpt.TrackedDefine _ (TOpt.VarKernel _ kernelPrefix home name _) _ _) ->
            Just ( kernelPrefix, home, name )

        Just (TOpt.Link target) ->
            kernelAliasOf target s

        _ ->
            Nothing


{-| `standaloneMember` with an explicit mint step — the ctor arms mint via
`Engine.standaloneMemberIdFor` so the member's Global lands in the E9
devirt reverse map (globals AND ctors — `Can.Normal` ctors like `List.::`
are VarGlobal/"g|"), and the kernel arm mints via `Engine.kernelMemberIdFor`
for the E9.2 kernel reverse map; the accessor arm keeps the plain intern.
-}
standaloneMemberWith : Step Int -> TOpt.Meta TypeIds.MVarId -> Step WalkPoint
standaloneMemberWith mint meta s0 =
    if canTypeIsArrow meta.tipe then
        case mint s0 of
            Err e ->
                Err e

            Ok ( mid, s1 ) ->
                case Store.loadType meta.tipe s1 of
                    Err e ->
                        Err e

                    Ok ( funcVar, s2 ) ->
                        case injectSpineMemberId 1 mid funcVar s2 of
                            Err e ->
                                Err e

                            Ok ( _, s3 ) ->
                                -- Injected identity: complete to the
                                -- injection depth; beyond-depth slots stay
                                -- flex (EMPTY facts — sound).
                                Ok ( WpHonest funcVar, s3 )

    else
        Ok ( WpNone, s0 )


{-| Sequence the successor walk after a mint arm, on the loaded variable the
arm returns (`WpHonest`). `WpNone` (arrow-free reference) has nothing to walk.
-}
withPapSuccessors : TOpt.Global -> Step WalkPoint -> Step WalkPoint
withPapSuccessors g step s0 =
    case step s0 of
        Err e ->
            Err e

        Ok ( wp, s1 ) ->
            case wp of
                WpHonest funcVar ->
                    case injectPapSuccessors g funcVar s1 of
                        Err e ->
                            Err e

                        Ok ( _, s2 ) ->
                            Ok ( wp, s2 )

                _ ->
                    Ok ( wp, s1 )


{-| The PAP element's key: `p|<global>|<supplied>` — moved here from
`Translate` (plans/lss-ref-pap-spine.md §4.2) so both injection sides mint
through ONE definition. Distinct per (global, arity-prefix) because those ARE
distinct values — and distinct from the callee's own `g|`/`k|` key, which
denotes the unapplied global and licenses a direct-call rewrite that a PAP
cannot support.
-}
papMemberKey : TOpt.Global -> Int -> String
papMemberKey =
    Engine.papMemberKey


{-| L2, deep-PAP successor completion (plans/lss-coverage-four-levers.md
§1.2, `lss.injTotal`): finish `injectPapMember`'s residual. The producer
injection writes `p|g|supplied` at the residual HEAD only; the depths past it
(`papInject|deep`, 584 sites on a self-compile) hold further PAPs of the SAME
global and get `p|g|d` for d in startDepth..arity-1 — the identical walk and
identical keys as the reference-spine successors, entered one level down.
Caller passes startDepth = supplied + 1 and the residual head variable.
-}
injectPapSuccessorsFrom : TOpt.Global -> Int -> Vars.Variable -> Step ()
injectPapSuccessorsFrom g startDepth v0 s0 =
    if not (s0.env.lss.enabled && s0.env.lss.injTotal) then
        Ok ( (), s0 )

    else
        let
            arity =
                declaredArityOf g 8 s0
        in
        if startDepth >= arity then
            Ok ( (), s0 )

        else
            case mintPapSuccessorIds g startDepth arity [] s0 of
                Err e ->
                    Err e

                Ok ( midsRev, s1 ) ->
                    Store.foldSetWrites
                        (papSuccGoC (List.reverse midsRev) CoreDict.empty v0 (Store.setWriteCtx (Store.qOnFor s1) s1.store))
                        (Engine.bumpArgFlowCensus "papInject|deepDone" s1)


{-| Reference-spine PAP successors (plans/lss-ref-pap-spine.md, `lss.refPapSpine`):
after a standalone reference's HEAD member, write the PAP successor members
down the loaded type's result spine — depth d in 1..declaredArity-1 gets
`p|<g>|<d>`, the SAME id `Translate.injectPapMember` (producer partial
applications) and `Translate.memberIdForDepth` (registration self-identity)
mint, so the three paths unify at every join (E9.2 one-identity).

This is the paper's 𝒬 applied to the nested λs of the conceptually-curried
global at its instantiation: Eco's runtime value at spine depth d IS the PAP
object, and `p|g|d` is its established identity. LSS\_013 bounds the walk at
declaredArity — the arrow past the last parameter belongs to the value the
BODY produces, which is the body tie's to claim, never this walk's.

The walk mirrors `spineGoC` (alias-chasing, seen-guarded, ctx-threaded), but
writes a DIFFERENT member per depth, into the RESULT arrow's own slot.

-}
injectPapSuccessors : TOpt.Global -> Vars.Variable -> Step ()
injectPapSuccessors g v0 s0 =
    if not (s0.env.lss.enabled && s0.env.lss.refPapSpine) then
        Ok ( (), s0 )

    else
        let
            arity =
                declaredArityOf g 8 s0
        in
        if arity <= 1 then
            Ok ( (), Engine.bumpArgFlowCensus "refspine|arity1" s0 )

        else
            -- Mint the successor ids first (Step-level interning), then one
            -- ctx-threaded store pass writes them at their depths.
            case mintPapSuccessorIds g 1 arity [] s0 of
                Err e ->
                    Err e

                Ok ( midsRev, s1 ) ->
                    Store.foldSetWrites
                        (papSuccGoC (List.reverse midsRev) CoreDict.empty v0 (Store.setWriteCtx (Store.qOnFor s1) s1.store))
                        (Engine.bumpArgFlowCensus "refspine|inject" s1)


{-| Depth-qualified successors for a ROOT-FOLDED def's OWN spine
(plans/lss-root-fold-depth-qualified-spine.md §3/§4.1). Identical walk and
identical ids to 'injectPapSuccessors', with two deliberate differences:

  - the depth bound is the root lambda's own `arity` (the LSS\_013 bound — the
    arrows a partial application of THIS lambda can peel), not
    `declaredArityOf`, because the caller already has the parameter count;
  - it is NOT gated on `lss.refPapSpine`. That flag governs the
    REFERENCE-side spine; this is the def's own identity write and must not
    depend on it. With `refPapSpine = 0` this becomes the only writer of
    `p|g|d` at those depths, which is strictly more coverage than that arm
    has today and cannot mint a stampable-on-PAP id (it writes `p|`).

-}
injectFoldedSuccessors : TOpt.Global -> Int -> Vars.Variable -> Step ()
injectFoldedSuccessors g arity v0 s0 =
    if arity <= 1 then
        Ok ( (), Engine.bumpArgFlowCensus "rootFold|spineHeadOnly" s0 )

    else
        case mintPapSuccessorIds g 1 arity [] s0 of
            Err e ->
                Err e

            Ok ( midsRev, s1 ) ->
                Store.foldSetWrites
                    (papSuccGoC (List.reverse midsRev) CoreDict.empty v0 (Store.setWriteCtx (Store.qOnFor s1) s1.store))
                    (Engine.bumpArgFlowCensus "rootFold|spineDepth" s1)


mintPapSuccessorIds : TOpt.Global -> Int -> Int -> List Int -> Step (List Int)
mintPapSuccessorIds g d arity acc s0 =
    if d >= arity then
        Ok ( acc, s0 )

    else
        case Engine.papMemberIdFor g d s0 of
            Err e ->
                Err e

            Ok ( mid, s1 ) ->
                mintPapSuccessorIds g (d + 1) arity (mid :: acc) s1


{-| `mids` is depth-ordered (head = the member for the value ONE application
in). `v` is the arrow at the previous depth; step into its result, write the
head member into the result's own arrow slot, recurse with the tail.
-}
papSuccGoC : List Int -> Dict Int () -> Vars.Variable -> Store.SetWriteCtx -> Store.SetWriteCtx
papSuccGoC mids seen v c0 =
    case mids of
        [] ->
            c0

        mid :: rest ->
            let
                key =
                    Engine.pointKey v
            in
            if CoreDict.member key seen then
                c0

            else
                let
                    ( store1, desc ) =
                        UF.get v c0.store

                    c1 =
                        { c0 | store = store1 }

                    seen1 =
                        CoreDict.insert key () seen
                in
                case desc.content of
                    Vars.Structure (Vars.FunL _ res _) ->
                        -- Step into the result value; write there if it is
                        -- itself an arrow (chasing aliases first).
                        papSuccWrite mid rest seen1 res c1

                    Vars.Alias _ _ _ real ->
                        -- Transparent alias: chase without consuming a depth.
                        papSuccGoC mids seen1 real c1

                    _ ->
                        -- Not an arrow (ground/var/slotless Fun1): spine ends.
                        c1


papSuccWrite : Int -> List Int -> Dict Int () -> Vars.Variable -> Store.SetWriteCtx -> Store.SetWriteCtx
papSuccWrite mid rest seen res c0 =
    let
        key =
            Engine.pointKey res
    in
    if CoreDict.member key seen then
        c0

    else
        let
            ( store1, desc ) =
                UF.get res c0.store

            c1 =
                { c0 | store = store1 }

            seen1 =
                CoreDict.insert key () seen
        in
        case desc.content of
            Vars.Structure (Vars.FunL _ _ slot) ->
                -- The result IS an arrow: this member names it; continue the
                -- walk FROM it for the next depth — with `seen` UNCHANGED.
                -- `papSuccGoC` records the variable it is entered on, exactly
                -- as `spineGoC` does. Passing `seen1` (which already holds
                -- `res`) made that guard fire on the very next step, so every
                -- successor walk — the `refPapSpine` reference spine and
                -- `injTotal`'s deep residual — wrote depth 1 and STOPPED
                -- (`papInject|deep|d2 433, d3 40, d4 1`; a 32-ary constructor
                -- reference named at depths 0-1 and unwritten at 2-31). Found
                -- by the post-translation producer census, 2026-09-15
                -- (plans/lss-container-payload-transport.md §12).
                papSuccGoC rest seen res (Store.unifySlotWithSetC Nothing [ mid ] slot c1)

            Vars.Alias _ _ _ real ->
                papSuccWrite mid rest seen1 real c1

            _ ->
                -- Result is not an arrow (fully-ground tail): spine ends.
                c1


{-| LSS\_013 (spine injection): a member id names not just the value's own head
arrow but every arrow of its RESULT chain that a partial application of `m`
traverses — a partial application of member `m` is still `m`, one stage further
in (design §3.3/OQ4). The store shares a partial application's result Point with
the callee's inner-arrow Point (Unify's `FunL × FunL` arm subUnifies
`res1 ~ res2`), so writing `m` on the spine makes ordinary call unification
transport the fact to every partial-application site of `m` — no new transport
machinery.

BOUNDED BY THE VALUE'S ARITY. Only the first `arity` arrows are `m`'s: those are
the value's own parameter arrows, the ones a partial application peels. The type
spine can extend PAST the arity when the fully-applied result is itself a
function (a returned closure `q`): `weird : Int -> (Int -> Int)` has arity 1 but
a 2-arrow spine, and that second arrow is inhabited by `q`, NOT by a PAP of `m`.
The type cannot distinguish it from `add : Int -> Int -> Int` (arity 2, both
arrows `m`'s) — only the value's parameter count can. Descending past the arity
would stamp `q`'s arrow with `m` (unsound: a downstream singleton consumer would
mis-dispatch), and when that beyond-arity Point later unifies against a concrete
return type (e.g. `ChomperResult`) it fails `Lambda /vs/ Type`. So `spineGo`
stops when `remaining` reaches 0.

ARGUMENT-position arrows are never injected: an argument arrow is inhabited by
the CALLER's values, not by `m`. Only the result chain is `m`'s.

The `seen` set mirrors `Store.poisonGo` — defensive against a cyclic type
(store structure is finite and `loadTypeC` alias-expands at load, so a cycle
should not arise, but recursion over an unbounded chain must terminate). Slots
are written with the total-join `Store.unifySlotWithSet` (extra inhabitants
from later unification widen the set; they never corrupt it — LSS\_005).

-}
injectSpineMemberId : Int -> Int -> Vars.Variable -> Step ()
injectSpineMemberId arity mid v0 s0 =
    spineGo mid arity CoreDict.empty v0 s0


spineGo : Int -> Int -> Dict Int () -> Vars.Variable -> Step ()
spineGo mid remaining seen v s0 =
    -- Phase 3: ctx-threaded — one S write-back for the whole spine.
    Store.foldSetWrites (spineGoC mid remaining seen v (Store.setWriteCtx (Store.qOnFor s0) s0.store)) s0


spineGoC : Int -> Int -> Dict Int () -> Vars.Variable -> Store.SetWriteCtx -> Store.SetWriteCtx
spineGoC mid remaining seen v c0 =
    if remaining <= 0 then
        c0

    else
        let
            key =
                Engine.pointKey v
        in
        if CoreDict.member key seen then
            c0

        else
            let
                ( store1, desc ) =
                    UF.get v c0.store

                c1 =
                    { c0 | store = store1 }
            in
            case desc.content of
                Vars.Structure (Vars.FunL _ res slot) ->
                    -- One arrow consumed: descend the result with one fewer
                    -- arrow of budget.
                    spineGoC mid (remaining - 1) (CoreDict.insert key () seen) res (Store.unifySlotWithSetC Nothing [ mid ] slot c1)

                Vars.Alias _ _ _ real ->
                    -- Transparent alias: chase the aliased Point WITHOUT
                    -- spending budget (same arrow, not a new one). Mono stores
                    -- are alias-expanded at load, so this is defensive.
                    spineGoC mid remaining (CoreDict.insert key () seen) real c1

                _ ->
                    -- Non-arrow result (ground type / var), or a slotless `Fun1`
                    -- (lss-off — no slot to write): the spine ends here.
                    c1


joinLetUse : LetEnv -> Name -> TOpt.Meta TypeIds.MVarId -> Step WalkPoint
joinLetUse letEnv name meta s0 =
    case CoreDict.get name letEnv of
        Nothing ->
            Ok ( WpNone, s0 )

        Just rhsVar ->
            if s0.env.lss.sigFlow && not (canTypeMentionsArrow meta.tipe) then
                -- LSS_020 (B.1.h) cost guard, flag-on only: with params
                -- bound into letEnv an unguarded load would fire at every
                -- bound-name occurrence program-wide; an arrow-free join
                -- writes no slots, so skipping it is semantics-free.
                --
                Ok ( WpNone, s0 )

            else
                case Store.loadType meta.tipe s0 of
                    Err e ->
                        Err e

                    Ok ( useVar, s1 ) ->
                        case joinArrowSets identity rhsVar useVar s1 of
                            Err e ->
                                Err e

                            Ok ( _, s2 ) ->
                                -- letEnv-linked flow: the family's own
                                -- invariant (rhs join + poison-on-divergence)
                                -- makes this complete-or-⊤.
                                Ok ( WpHonest useVar, s2 )


{-| §7.4 let boundary, v1 policy: walk two loaded type structures in
parallel, unifying ONLY the set slots of arrows at matching positions. On
structural divergence (either side a variable or the shapes differ — a
generalized position), poison BOTH sides' remaining arrow slots and stop
descending that branch. All uses of a let-bound function thereby share one
set (union over uses — sound; per-use separation is the vNext upgrade, which
is why this stays a separate named function).

`onPoison` (LSS\_020 B.4): applied once per poison event so callers can
attribute the ⊤ — `identity` for the pre-plan let channel (its number is
frozen Run-J data), `Engine.bumpWidenedByCf` for every join the sigFlow
repair adds (via `joinArrowSetsSig`). Phase H.2 widens this parameter into a
poison MODE (PoisonUseOnly) — design for the parameter, don't over-build.

-}
joinArrowSets : (Engine.S -> Engine.S) -> Vars.Variable -> Vars.Variable -> Step ()
joinArrowSets onPoison a b s0 =
    let
        ( store1, descA ) =
            UF.get a s0.store

        ( store2, descB ) =
            UF.get b store1

        s1 =
            { s0 | store = store2 }
    in
    case ( descA.content, descB.content ) of
        ( Vars.Structure flatA, Vars.Structure flatB ) ->
            case ( flatA, flatB ) of
                ( Vars.FunL argA resA slotA, Vars.FunL argB resB slotB ) ->
                    case Store.unifyBestEffort slotA slotB s1 of
                        Err e ->
                            Err e

                        Ok ( _, s2 ) ->
                            case joinArrowSets onPoison argA argB s2 of
                                Err e ->
                                    Err e

                                Ok ( _, s3 ) ->
                                    joinArrowSets onPoison resA resB s3

                ( Vars.Fun1 argA resA, Vars.Fun1 argB resB ) ->
                    case joinArrowSets onPoison argA argB s1 of
                        Err e ->
                            Err e

                        Ok ( _, s2 ) ->
                            joinArrowSets onPoison resA resB s2

                ( Vars.App1 _ _ argsA, Vars.App1 _ _ argsB ) ->
                    joinArrowSetsList onPoison argsA argsB s1

                ( Vars.Tuple1 a1 b1 restA, Vars.Tuple1 a2 b2 restB ) ->
                    joinArrowSetsList onPoison (a1 :: b1 :: restA) (a2 :: b2 :: restB) s1

                ( Vars.Record1 fieldsA extA, Vars.Record1 fieldsB extB ) ->
                    let
                        shared =
                            CoreDict.merge
                                (\_ _ acc -> acc)
                                (\_ va vb acc -> ( va, vb ) :: acc)
                                (\_ _ acc -> acc)
                                fieldsA
                                fieldsB
                                []
                    in
                    case joinArrowSetsPairs onPoison shared s1 of
                        Err e ->
                            Err e

                        Ok ( _, s2 ) ->
                            joinArrowSets onPoison extA extB s2

                ( Vars.EmptyRecord1, _ ) ->
                    Ok ( (), s1 )

                ( _, Vars.EmptyRecord1 ) ->
                    Ok ( (), s1 )

                ( Vars.Unit1, Vars.Unit1 ) ->
                    Ok ( (), s1 )

                _ ->
                    poisonBoth onPoison a b s1

        ( Vars.Alias _ _ _ realA, _ ) ->
            joinArrowSets onPoison realA b s1

        ( _, Vars.Alias _ _ _ realB ) ->
            joinArrowSets onPoison a realB s1

        _ ->
            -- A variable on either side = a generalized position: poison both.
            poisonBoth onPoison a b s1


{-| `joinArrowSets` with sigFlow attribution: every join LSS\_020 adds
(member-root, lambda-result, If/Case hub, Let rhs, local-callee shape) counts
its poison events in `sigStats.widenedByCf` (report-gated inside the bump).
-}
joinArrowSetsSig : Vars.Variable -> Vars.Variable -> Step ()
joinArrowSetsSig =
    joinArrowSets Engine.bumpWidenedByCf


{-| LSS\_023: "values of src flow into dst" — the DIRECTED twin of
`joinArrowSets` (`plans/lss-directed-set-flow.md` §5.1).

Slot positions get a deferred edge (`Store.addSlotSource`) instead of
unification. ARG positions FLIP operands — contravariance: dst's callers'
arguments flow into src's params; the double-flip in nested arg positions is
correctly covariant. Container positions (App1/Record1/Tuple1) DEGRADE the
WHOLE subtree to the symmetric join (per-parameter variance unknown;
symmetric is the sound over-approximation — and `joinArrowSets` never
resumes a directed spine inside, it recurses only into itself). Alias chase,
EmptyRecord/Unit accept, mismatch/variable → `poisonBoth onPoison` — all as
`joinArrowSets`.

**Any FUTURE directed call site must re-argue variance.** A directed walk
that recursed argument positions co-variantly would install wrong-direction
edges and UNDER-approximate — the miscompile class.

-}
flowArrowSets : (Engine.S -> Engine.S) -> Vars.Variable -> Vars.Variable -> Step ()
flowArrowSets onPoison src dst s0 =
    let
        ( store1, descS ) =
            UF.get src s0.store

        ( store2, descD ) =
            UF.get dst store1

        s1 =
            { s0 | store = store2 }
    in
    case ( descS.content, descD.content ) of
        ( Vars.Structure flatS, Vars.Structure flatD ) ->
            case ( flatS, flatD ) of
                ( Vars.FunL argS resS slotS, Vars.FunL argD resD slotD ) ->
                    case Store.addSlotSource slotS slotD s1 of
                        Err e ->
                            Err e

                        Ok ( _, s2 ) ->
                            case flowArrowSets onPoison resS resD s2 of
                                Err e ->
                                    Err e

                                Ok ( _, s3 ) ->
                                    -- ARG: contravariant flip.
                                    flowArrowSets onPoison argD argS s3

                ( Vars.Fun1 argS resS, Vars.Fun1 argD resD ) ->
                    -- Slotless arrow: same variance, no edge to install.
                    case flowArrowSets onPoison resS resD s1 of
                        Err e ->
                            Err e

                        Ok ( _, s2 ) ->
                            flowArrowSets onPoison argD argS s2

                ( Vars.App1 _ _ _, Vars.App1 _ _ _ ) ->
                    degradeToSymmetric onPoison src dst s1

                ( Vars.Tuple1 _ _ _, Vars.Tuple1 _ _ _ ) ->
                    degradeToSymmetric onPoison src dst s1

                ( Vars.Record1 _ _, Vars.Record1 _ _ ) ->
                    degradeToSymmetric onPoison src dst s1

                ( Vars.EmptyRecord1, _ ) ->
                    Ok ( (), s1 )

                ( _, Vars.EmptyRecord1 ) ->
                    Ok ( (), s1 )

                ( Vars.Unit1, Vars.Unit1 ) ->
                    Ok ( (), s1 )

                _ ->
                    poisonBoth onPoison src dst s1

        ( Vars.Alias _ _ _ realS, _ ) ->
            flowArrowSets onPoison realS dst s1

        ( _, Vars.Alias _ _ _ realD ) ->
            flowArrowSets onPoison src realD s1

        _ ->
            -- A variable on either side = a generalized position: poison both.
            poisonBoth onPoison src dst s1


{-| The container degrade: the WHOLE subtree goes symmetric. `flowDegraded`
bumps only when the degraded pair can actually CARRY a set (arrow-mention in
the src structure) — ground leaves like `Int` would otherwise dominate the
counter and make it meaningless.
-}
degradeToSymmetric : (Engine.S -> Engine.S) -> Vars.Variable -> Vars.Variable -> Step ()
degradeToSymmetric onPoison src dst s0 =
    case storeMentionsArrow src s0 of
        Err e ->
            Err e

        Ok ( carries, s1 ) ->
            joinArrowSets onPoison
                src
                dst
                (if carries then
                    Engine.bumpFlowDegraded s1

                 else
                    s1
                )


{-| Does the store structure under this Point mention an arrow? Bounded
walk with a visited list (aliases can cycle through records).
-}
storeMentionsArrow : Vars.Variable -> Engine.S -> Result Engine.Failure ( Bool, Engine.S )
storeMentionsArrow root s0 =
    storeMentionsArrowGo [ root ] [] s0


storeMentionsArrowGo : List Vars.Variable -> List Int -> Engine.S -> Result Engine.Failure ( Bool, Engine.S )
storeMentionsArrowGo pending visited s0 =
    case pending of
        [] ->
            Ok ( False, s0 )

        v :: rest ->
            let
                key =
                    Engine.pointKey v
            in
            if List.member key visited then
                storeMentionsArrowGo rest visited s0

            else
                let
                    ( store1, desc ) =
                        UF.get v s0.store

                    s1 =
                        { s0 | store = store1 }

                    visited1 =
                        key :: visited
                in
                case desc.content of
                    Vars.Structure (Vars.FunL _ _ _) ->
                        Ok ( True, s1 )

                    Vars.Structure (Vars.Fun1 _ _) ->
                        Ok ( True, s1 )

                    Vars.Structure (Vars.App1 _ _ args) ->
                        storeMentionsArrowGo (args ++ rest) visited1 s1

                    Vars.Structure (Vars.Tuple1 a b more) ->
                        storeMentionsArrowGo (a :: b :: more ++ rest) visited1 s1

                    Vars.Structure (Vars.Record1 fields ext) ->
                        storeMentionsArrowGo (CoreDict.values fields ++ (ext :: rest)) visited1 s1

                    Vars.Alias _ _ _ real ->
                        storeMentionsArrowGo (real :: rest) visited1 s1

                    _ ->
                        storeMentionsArrowGo rest visited1 s1


{-| `flowArrowSets` with sigFlow attribution — the directed twin of
`joinArrowSetsSig`.
-}
flowArrowSetsSig : Vars.Variable -> Vars.Variable -> Step ()
flowArrowSetsSig =
    flowArrowSets Engine.bumpWidenedByCf


{-| Set-flow with no poison attribution — the directed twin of
`joinArrowSetsPlain`, for translation-side consumers (kernel tunnels).
-}
flowArrowSetsPlain : Vars.Variable -> Vars.Variable -> Step ()
flowArrowSetsPlain =
    flowArrowSets identity


{-| Flag-gated single-source join (Let rhs → letEnv hub; skip on no point).
-}
sigFlowJoinInto : Vars.Variable -> Maybe Vars.Variable -> Step ()
sigFlowJoinInto target maybePoint s0 =
    if s0.env.lss.sigFlow then
        case maybePoint of
            Just p ->
                joinArrowSetsSig target p s0

            Nothing ->
                Ok ( (), s0 )

    else
        Ok ( (), s0 )


joinArrowSetsList : (Engine.S -> Engine.S) -> List Vars.Variable -> List Vars.Variable -> Step ()
joinArrowSetsList onPoison xs ys s0 =
    case ( xs, ys ) of
        ( x :: xr, y :: yr ) ->
            case joinArrowSets onPoison x y s0 of
                Err e ->
                    Err e

                Ok ( _, s1 ) ->
                    joinArrowSetsList onPoison xr yr s1

        _ ->
            Ok ( (), s0 )


joinArrowSetsPairs : (Engine.S -> Engine.S) -> List ( Vars.Variable, Vars.Variable ) -> Step ()
joinArrowSetsPairs onPoison pairs s0 =
    case pairs of
        [] ->
            Ok ( (), s0 )

        ( x, y ) :: rest ->
            case joinArrowSets onPoison x y s0 of
                Err e ->
                    Err e

                Ok ( _, s1 ) ->
                    joinArrowSetsPairs onPoison rest s1


poisonBoth : (Engine.S -> Engine.S) -> Vars.Variable -> Vars.Variable -> Step ()
poisonBoth onPoison a b s0 =
    -- GAP-9a ⊤ source. One-shot census 2026-08-18 (Run J,
    -- benchmarks/lss-opt.md): 672 invocations on the self-compile vs
    -- topSiteShapes local=7,361 — a minor component of the local-⊤ mass;
    -- the per-event counter was removed after the measurement (plan
    -- lss-fidelity-1 §7). LSS_020 joins attribute their events via
    -- `onPoison` instead.
    case Store.poisonArrowSets a s0 of
        Err e ->
            Err e

        Ok ( _, s1 ) ->
            case Store.poisonArrowSets b s1 of
                Err e ->
                    Err e

                Ok ( _, s2 ) ->
                    Ok ( (), onPoison s2 )


{-| P0 sizing instrument (plans/lss-ctor-arrow-identity.md §8.1): how many
LEADING arrows does this type have? `a -> (Int -> b)` is 2. Compared against
the depth an injection actually covers, this decides whether a deeper
nameable position EXISTS at an argument — the `/a0/r`-class the census says
holds the mass.
-}
canTypeArrowDepth : Can.Type TypeIds.MVarId -> Int
canTypeArrowDepth t =
    case t of
        Can.TLambda _ _ res ->
            1 + canTypeArrowDepth res

        Can.TAlias _ _ _ (Can.Filled real) ->
            canTypeArrowDepth real

        _ ->
            0


canTypeIsArrow : Can.Type TypeIds.MVarId -> Bool
canTypeIsArrow t =
    case t of
        Can.TLambda _ _ _ ->
            True

        Can.TAlias _ _ _ (Can.Filled real) ->
            canTypeIsArrow real

        _ ->
            False


{-| Does a canonical type mention an arrow ANYWHERE (LSS\_020 B.2's cheap
guard — keeps the new loads off the overwhelmingly arrow-free majority)?
Verbatim twin of `Translate.canTypeHasArrow`. `TVar → False` is deliberate: a
pure-TVar position either already connects via the MVarId memo or is
generalized, where a join would only poison.
-}
canTypeMentionsArrow : Can.Type TypeIds.MVarId -> Bool
canTypeMentionsArrow t =
    case t of
        Can.TLambda _ _ _ ->
            True

        Can.TVar _ ->
            False

        Can.TType _ _ typeArgs ->
            List.any canTypeMentionsArrow typeArgs

        Can.TRecord fields _ ->
            CoreDict.foldl (\_ (Can.FieldType _ ft) acc -> acc || canTypeMentionsArrow ft) False fields

        Can.TUnit ->
            False

        Can.TTuple a b rest ->
            canTypeMentionsArrow a || canTypeMentionsArrow b || List.any canTypeMentionsArrow rest

        Can.TAlias _ _ aliasArgs (Can.Filled real) ->
            canTypeMentionsArrow real || List.any (\( _, at ) -> canTypeMentionsArrow at) aliasArgs

        Can.TAlias _ _ aliasArgs (Can.Holey real) ->
            canTypeMentionsArrow real || List.any (\( _, at ) -> canTypeMentionsArrow at) aliasArgs


{-| LSS\_020 (B.1.g): descend an arrow spine binding one param name per arrow
into letEnv; returns the extended env and the spine position after the last
param (`Nothing` on early stop — erased/over-shadowed heads leave the
remaining params untracked, today's behavior, sound). Total: store reads
only. The `seen` set guards the transparent-alias chase (mirrors `spineGoC`);
`Store.arrowParts` handles Fun1+FunL but NOT Alias, hence the explicit arm.
-}
bindParamsFromSpine : List Name -> Vars.Variable -> Dict Int () -> LetEnv -> Engine.S -> ( LetEnv, Maybe Vars.Variable, Engine.S )
bindParamsFromSpine names v seen letEnv s0 =
    case names of
        [] ->
            ( letEnv, Just v, s0 )

        n :: rest ->
            let
                key =
                    Engine.pointKey v

                ( store1, desc ) =
                    UF.get v s0.store

                s1 =
                    { s0 | store = store1 }
            in
            if CoreDict.member key seen then
                ( letEnv, Nothing, s1 )

            else
                case desc.content of
                    Vars.Alias _ _ _ real ->
                        bindParamsFromSpine names real (CoreDict.insert key () seen) letEnv s1

                    _ ->
                        case Store.arrowParts desc.content of
                            Just ( pParam, pRest ) ->
                                bindParamsFromSpine rest
                                    pRest
                                    (CoreDict.insert key () seen)
                                    (CoreDict.insert n pParam letEnv)
                                    s1

                            Nothing ->
                                ( letEnv, Nothing, s1 )


{-| LSS\_020 (B.2): the If/Case hub. Publishes the joined branch flow ONLY
when every branch is `WpHonest` (`WpSelf` skipped — see `WalkPoint`);
otherwise ⊤ is the only honest summary of a partially visible value, so the
hub POISONS (counted: `sigStats.widenedByCf`) — a partial member join would
claim completeness while a blind branch's runtime inhabitants are invisible,
the false-singleton devirt vector. A poisoned hub returns `WpHonest` — ⊤
propagates upward correctly through the parents' joins.
-}
joinCfHub : List WalkPoint -> TOpt.Meta TypeIds.MVarId -> Step WalkPoint
joinCfHub wps meta s0 =
    if not (s0.env.lss.sigFlow && canTypeMentionsArrow meta.tipe) then
        Ok ( WpNone, s0 )

    else
        case Store.loadType meta.tipe s0 of
            Err e ->
                Err e

            Ok ( hub, s1 ) ->
                if List.all hubHonest wps then
                    -- LSS_023: DIRECTED — each branch flows INTO the hub
                    -- (branch → hub), so the branches keep their own sets and
                    -- the hub resolves their union at read. The symmetric
                    -- version unified all branches into one class — the Run-X
                    -- pollution this plan exists to remove.
                    case flowAllSig hub (List.filterMap wpPoint wps) s1 of
                        Err e ->
                            Err e

                        Ok ( _, s2 ) ->
                            Ok ( WpHonest hub, s2 )

                else
                    case Store.poisonArrowSets hub s1 of
                        Err e ->
                            Err e

                        Ok ( _, s2 ) ->
                            Ok ( WpHonest hub, Engine.bumpWidenedByCf s2 )


hubHonest : WalkPoint -> Bool
hubHonest wp =
    case wp of
        WpHonest _ ->
            True

        WpSelf ->
            True

        WpOpaque _ ->
            False

        WpNone ->
            False


flowAllSig : Vars.Variable -> List Vars.Variable -> Step ()
flowAllSig hub pts s0 =
    case pts of
        [] ->
            Ok ( (), s0 )

        p :: rest ->
            -- branch → hub: p is the SOURCE.
            case flowArrowSetsSig p hub s0 of
                Err e ->
                    Err e

                Ok ( _, s1 ) ->
                    flowAllSig hub rest s1


walkIfPairs : LetEnv -> List ( TOpt.Expr TypeIds.MVarId, TOpt.Expr TypeIds.MVarId ) -> List WalkPoint -> Step (List WalkPoint)
walkIfPairs letEnv pairs acc s0 =
    case pairs of
        [] ->
            Ok ( acc, s0 )

        ( cond, branch ) :: rest ->
            case walkExpr letEnv cond s0 of
                Err e ->
                    Err e

                Ok ( _, s1 ) ->
                    case walkExpr letEnv branch s1 of
                        Err e ->
                            Err e

                        Ok ( wp, s2 ) ->
                            walkIfPairs letEnv rest (wp :: acc) s2


walkCollect : LetEnv -> List (TOpt.Expr TypeIds.MVarId) -> List WalkPoint -> Step (List WalkPoint)
walkCollect letEnv exprs acc s0 =
    case exprs of
        [] ->
            Ok ( acc, s0 )

        e :: rest ->
            case walkExpr letEnv e s0 of
                Err e1 ->
                    Err e1

                Ok ( wp, s1 ) ->
                    walkCollect letEnv rest (wp :: acc) s1



-- ====== STRUCTURAL CHILD FOLDS ======


walkChildren : LetEnv -> List (TOpt.Expr TypeIds.MVarId) -> Step ()
walkChildren letEnv exprs s0 =
    case exprs of
        [] ->
            Ok ( (), s0 )

        e :: rest ->
            case walkExpr letEnv e s0 of
                Err e1 ->
                    Err e1

                Ok ( _, s1 ) ->
                    walkChildren letEnv rest s1


directChildren : TOpt.Expr TypeIds.MVarId -> List (TOpt.Expr TypeIds.MVarId)
directChildren expr =
    case expr of
        TOpt.Bool _ _ _ ->
            []

        TOpt.Chr _ _ _ ->
            []

        TOpt.Str _ _ _ ->
            []

        TOpt.Int _ _ _ ->
            []

        TOpt.Float _ _ _ ->
            []

        TOpt.VarLocal _ _ ->
            []

        TOpt.TrackedVarLocal _ _ _ ->
            []

        TOpt.VarGlobal _ _ _ ->
            []

        TOpt.VarEnum _ _ _ _ ->
            []

        TOpt.VarBox _ _ _ ->
            []

        TOpt.VarCycle _ _ _ _ ->
            []

        TOpt.VarDebug _ _ _ _ _ ->
            []

        TOpt.VarKernel _ _ _ _ _ ->
            []

        TOpt.List _ items _ ->
            items

        TOpt.Function _ _ body _ ->
            [ body ]

        TOpt.TrackedFunction _ _ body _ ->
            [ body ]

        TOpt.Call _ func args _ ->
            func :: args

        TOpt.TailCall _ args _ ->
            List.map Tuple.second args

        TOpt.If branches finally _ ->
            List.concatMap (\( c, b ) -> [ c, b ]) branches ++ [ finally ]

        TOpt.Let def body _ ->
            (case def of
                TOpt.Def _ _ rhs _ ->
                    [ rhs ]

                TOpt.TailDef _ _ _ rhs _ _ ->
                    [ rhs ]
            )
                ++ [ body ]

        TOpt.Destruct _ body _ ->
            [ body ]

        TOpt.Case _ _ decider jumps _ ->
            deciderExprs decider ++ List.map Tuple.second jumps

        TOpt.Accessor _ _ _ ->
            []

        TOpt.Access record _ _ _ ->
            [ record ]

        TOpt.Update _ record fields _ ->
            record :: DMap.values A.compareLocated fields

        TOpt.Record fields _ ->
            CoreDict.values fields

        TOpt.TrackedRecord _ fields _ ->
            DMap.values A.compareLocated fields

        TOpt.Unit _ ->
            []

        TOpt.Tuple _ a b rest _ ->
            a :: b :: rest

        TOpt.Shader _ _ _ _ ->
            []


deciderExprs : TOpt.Decider (TOpt.Choice TypeIds.MVarId) -> List (TOpt.Expr TypeIds.MVarId)
deciderExprs decider =
    case decider of
        TOpt.Leaf choice ->
            case choice of
                TOpt.Inline e ->
                    [ e ]

                TOpt.Jump _ ->
                    []

        TOpt.Chain _ success failure ->
            deciderExprs success ++ deciderExprs failure

        TOpt.FanOut _ edges fallback ->
            List.concatMap (\( _, d ) -> deciderExprs d) edges ++ deciderExprs fallback
