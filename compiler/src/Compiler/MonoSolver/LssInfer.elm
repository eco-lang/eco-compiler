module Compiler.MonoSolver.LssInfer exposing
    ( signatureFor
    , instantiateWithSignature
    , injectLambdaMember
    , injectLambdaMemberQualified
    , injectSpineMemberId
    , kernelAliasOf
    , spineDepthForGlobal
    , joinArrowSetsPlain
    )

{-| Lambda-set signature inference (LSS design §7).

A def's LSS signature summarizes what its *body* contributes to the arrows of
its *annotation type* — the facts a caller must apply without walking the
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

Ordinal discipline (LSS_006): a signature's `arrows` index is the minting
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
import Compiler.AST.TypeIds as TypeIds
import Compiler.AST.TypedOptimized as TOpt
import Compiler.Data.Name exposing (Name)
import Compiler.MonoSolver.Engine as Engine exposing (Failure(..), Step)
import Compiler.MonoSolver.KernelSetFacts as KernelSetFacts
import Compiler.MonoSolver.Store as Store
import Compiler.Reporting.Annotation as A
import Compiler.Type.UnionFind as UF
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
ordinals pair (LSS_006).
-}
instantiateWithSignature : TOpt.Global -> Can.Type TypeIds.MVarId -> Step IO.Variable
instantiateWithSignature global funcCanType s0 =
    case signatureFor global s0 of
        Err e ->
            Err e

        Ok ( sig, s1 ) ->
            case Store.loadTypeIsolatedWithArrows funcCanType s1 of
                Err e ->
                    Err e

                Ok ( ( funcVar, slots ), s2 ) ->
                    case applyFacts sig slots funcVar s2 of
                        Err e ->
                            Err e

                        Ok ( _, s3 ) ->
                            Ok ( funcVar, s3 )


{-| Unify a source lambda's own member into the first `arity` arrows of its
loaded type's result spine (LSS_013 spine injection), via 'injectSpineMemberId'.
`arity` is the lambda's parameter count — the exact number of arrows a partial
application of it can peel; the spine is bounded there so a function-returning
body never stamps its returned closure's arrows (see 'injectSpineMemberId').
No-op for untagged lambdas and for any spine arrow with no slot (an erased-var
head has no slot to constrain — sound: the arrow reads back whatever its other
constraints say, or LTop). The argument arrows are deliberately never touched.
-}
injectLambdaMember : Int -> Maybe TypeIds.SrcLambdaId -> IO.Variable -> Step ()
injectLambdaMember arity srcLam funcVar s0 =
    case srcLam of
        Nothing ->
            Ok ( (), s0 )

        Just lamId ->
            injectSpineMemberId arity (Engine.srcLambdaKey lamId) funcVar s0


{-| Fix B (LSS_017): `injectLambdaMember` for TRANSLATION-phase mints —
the member id is spec-qualified via `Engine.lambdaInstanceMemberId` when
the defining global routes keyed, so keyed clones of one source lambda
stay distinguishable. The inference-phase walk (`walkExpr`) keeps the raw
`injectLambdaMember`: signatures are per-unit and pre-spec by design.
-}
injectLambdaMemberQualified : Int -> Maybe TypeIds.SrcLambdaId -> IO.Variable -> Step ()
injectLambdaMemberQualified arity srcLam funcVar s0 =
    case srcLam of
        Nothing ->
            Ok ( (), s0 )

        Just lamId ->
            case Engine.lambdaInstanceMemberId lamId s0 of
                Err e ->
                    Err e

                Ok ( mid, s1 ) ->
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
-}
applyFacts : Engine.LssSignature -> Array IO.Variable -> IO.Variable -> Step ()
applyFacts sig slots funcVar s0 =
    if sig.trivial then
        Ok ( (), s0 )

    else if Array.length sig.arrows /= Array.length slots then
        Store.poisonArrowSets funcVar s0

    else
        applyFactsGo sig.arrows slots 0 s0


applyFactsGo : Array Engine.ArrowFact -> Array IO.Variable -> Int -> Step ()
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
                                Store.unifySlotWithSet True [] slot s1

                            else if not (List.isEmpty fact.members) then
                                Store.unifySlotWithSet False fact.members slot s1

                            else
                                Ok ( (), s1 )
                    in
                    case afterSet of
                        Err e ->
                            Err e

                        Ok ( _, s2 ) ->
                            applyFactsGo facts slots (i + 1) s2

        _ ->
            Ok ( (), s0 )



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
Signature-source types are annotation-first (LSS_006).
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
                    zonkSignatures
                        (List.map2
                            (\m ( gkey, _, slots ) -> ( gkey, selfIdOf m, slots ))
                            members
                            loaded
                        )
                        []
                        s2


loadMemberSlots : List UnitMember -> List ( String, IO.Variable, Array IO.Variable ) -> Step (List ( String, IO.Variable, Array IO.Variable ))
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


{-| LSS_020 (B.1.f): the raw member id of the def's OWN body lambda. Filtered
at signature readback — transporting it through signatures is redundant
(callers already receive the def's identity via the `g|` standalone spine
injection, which grounds per LSS_019, and via `injectArgLambdaMember`
translate-side) and harmful (raw `l|` ids decline at AbiCloning per LSS_017,
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


walkMembers : List ( UnitMember, ( String, IO.Variable, Array IO.Variable ) ) -> Step ()
walkMembers pairs s0 =
    case pairs of
        [] ->
            Ok ( (), s0 )

        ( m, ( _, root, _ ) ) :: rest ->
            case m.body of
                Nothing ->
                    walkMembers rest s0

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


zonkSignatures : List ( String, Maybe Int, Array IO.Variable ) -> List ( String, Engine.LssSignature ) -> Step (List ( String, Engine.LssSignature ))
zonkSignatures pending acc s0 =
    case pending of
        [] ->
            Ok ( List.reverse acc, s0 )

        ( gkey, selfId, slots ) :: rest ->
            case zonkOneSignature selfId slots s0 of
                Err e ->
                    Err e

                Ok ( sig, s1 ) ->
                    zonkSignatures rest (( gkey, sig ) :: acc) s1


zonkOneSignature : Maybe Int -> Array IO.Variable -> Step Engine.LssSignature
zonkOneSignature selfId slots s0 =
    zonkSigGo selfId slots (Array.length slots) 0 [] s0


zonkSigGo : Maybe Int -> Array IO.Variable -> Int -> Int -> List Engine.ArrowFact -> Step Engine.LssSignature
zonkSigGo selfId slots n i factsRev s0 =
    if i >= n then
        let
            facts =
                List.reverse factsRev

            trivial =
                List.all identity
                    (List.indexedMap
                        (\j f -> f.rep == j && not f.top && List.isEmpty f.members)
                        facts
                    )
        in
        Ok ( { arrows = Array.fromList facts, trivial = trivial }, s0 )

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
                                    IO.Structure (IO.LambdaSet1 IO.LsTop) ->
                                        -- Members are dead under ⊤ at every
                                        -- fact consumer; carry none.
                                        ( { rep = rep, members = [], top = True }, s2 )

                                    IO.Structure (IO.LambdaSet1 (IO.LsMembers ms0)) ->
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
                                            if List.length ms > s2.env.lss.maxSetSize then
                                                ( { rep = rep, members = [], top = True }
                                                , Engine.bumpWidenedBySigSize s2
                                                )

                                            else
                                                ( { rep = rep, members = ms, top = False }, s2 )

                                        else
                                            -- Phase 2: the store list by pointer
                                            -- (was CoreDict.keys).
                                            ( { rep = rep, members = ms0, top = False }, s2 )

                                    _ ->
                                        -- FlexVar: the body contributed nothing.
                                        ( { rep = rep, members = [], top = False }, s2 )
                        in
                        zonkSigGo selfId slots n (i + 1) (fact :: factsRev) s3


{-| The smallest ordinal j < i whose slot is UF-equivalent to this one (i if
none). Arrows-per-signature is small; the O(n²) is on n ≈ arity.
-}
repOrdinal : Array IO.Variable -> IO.Variable -> Int -> Int -> Step Int
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
    Dict Name IO.Variable


{-| LSS_020 (plan B.0): what a walked expression hands its parent — the Point
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
    | WpHonest IO.Variable
    | WpOpaque IO.Variable


wpPoint : WalkPoint -> Maybe IO.Variable
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
                    standaloneMemberWith (\_ -> 1) (Engine.kernelMemberIdFor ("k|" ++ home ++ "." ++ name) ( kernelPrefix, home, name )) meta s0

                Nothing ->
                    standaloneMemberWith (spineDepthForGlobal g) (Engine.standaloneMemberIdFor ("g|" ++ TOpt.toComparableGlobal g) g) meta s0

        TOpt.VarEnum _ g _ meta ->
            -- E9: ctor mints register the Global for devirt lookup.
            standaloneMemberWith (spineDepthForGlobal g) (Engine.standaloneMemberIdFor ("c|" ++ TOpt.toComparableGlobal g) g) meta s0

        TOpt.VarBox _ g meta ->
            standaloneMemberWith (spineDepthForGlobal g) (Engine.standaloneMemberIdFor ("c|" ++ TOpt.toComparableGlobal g) g) meta s0

        TOpt.VarCycle _ home name meta ->
            -- GAP-7 seam 1 (LSS_020 plan Phase E.1): cycle members resolve
            -- their declared arity through `declaredArityOf`'s Cycle arm
            -- (name-threaded past the Link chase), riding the same
            -- `lss.spineArity` gate as the VarGlobal arm — dormant at the
            -- default `spineArity = False` (depth floors at 1, today's
            -- behavior). The translation-side twin gained its VarCycle arm
            -- in the same change (Translate.injectArgLambdaMember), so both
            -- sides deepen in lockstep through `spineDepthForGlobal`.
            standaloneMemberWith (spineDepthForGlobal (TOpt.Global home name)) (Engine.standaloneMemberIdFor ("g|" ++ TOpt.toComparableGlobal (TOpt.Global home name)) (TOpt.Global home name)) meta s0

        TOpt.VarKernel _ kernelPrefix home name meta ->
            -- E9.2: kernel mints register (prefix, home, name) for devirt
            -- lookup — the "k|" key (and so the member id) is unchanged.
            -- Head-only: see the kernel-alias arm above.
            standaloneMemberWith (\_ -> 1) (Engine.kernelMemberIdFor ("k|" ++ home ++ "." ++ name) ( kernelPrefix, home, name )) meta s0

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

        _ ->
            -- Everything else: structural recursion only. Shared MVarIds
            -- already carry the intra-def flow; re-implementing translate's
            -- demand-concretization corners here would be wrong-layer work.
            case walkChildren letEnv (directChildren expr) s0 of
                Err e ->
                    Err e

                Ok ( _, s1 ) ->
                    Ok ( WpNone, s1 )


{-| LSS_020 (B.1.e): the `Function`/`TrackedFunction` arm body. Flag-on it
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


{-| Call handling. Global callee: instantiate with signature facts and unify
params/result (best-effort). Kernel/Debug callee: every arrow crossing the
ABI is dynamic — poison arg and result arrows (LSS_004). Local callee
(LSS_020 B.3, under `lss.sigFlow`): slot-only call-shape join against the
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
                        Ok ( WpOpaque callVar, s2 )

    else
        case instantiateWithSignature g srcType s0 of
            Err e ->
                Err e

            Ok ( funcVar, s1 ) ->
                case unifyCallShape funcVar args meta s1 of
                    Err e ->
                        Err e

                    Ok ( callVar, s2 ) ->
                        Ok ( WpOpaque callVar, s2 )


{-| Unify a callee instantiation's params against the args and its residual
against the call's own type, so returned arrows carry their sets into this
def's flow. Returns the call's own loaded Point (the value the parent may
propagate — `WpOpaque` class). ISOLATED-instantiation path only: the
whole-type best-effort unify here must never target a shared letEnv family
Point (§7.4; local callees go through `joinCallArgs` instead).
-}
unifyCallShape : IO.Variable -> List (TOpt.Expr TypeIds.MVarId) -> TOpt.Meta TypeIds.MVarId -> Step IO.Variable
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


unifyParamsBestEffort : IO.Variable -> List (TOpt.Expr TypeIds.MVarId) -> Step IO.Variable
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
                    case Store.loadType (TOpt.typeOf arg) s1 of
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


{-| LSS_020 (B.3): a call whose callee is a letEnv-bound local. Slot-only
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
                                            case joinArrowSetsSig restVar callVar s2 of
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
joinCallArgs : IO.Variable -> List (TOpt.Expr TypeIds.MVarId) -> Dict Int () -> Step (Maybe IO.Variable)
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
                    IO.Alias _ _ _ real ->
                        joinCallArgs real args (CoreDict.insert key () seen) s1

                    _ ->
                        case Store.arrowParts desc.content of
                            Just ( pParam, pRest ) ->
                                if canTypeMentionsArrow (TOpt.typeOf arg) then
                                    case Store.loadType (TOpt.typeOf arg) s1 of
                                        Err e ->
                                            Err e

                                        Ok ( argVar, s2 ) ->
                                            case joinArrowSetsSig argVar pParam s2 of
                                                Err e ->
                                                    Err e

                                                Ok ( _, s3 ) ->
                                                    joinCallArgs pRest rest (CoreDict.insert key () seen) s3

                                else
                                    joinCallArgs pRest rest (CoreDict.insert key () seen) s1

                            Nothing ->
                                Ok ( Nothing, s1 )


{-| A kernel call boundary, resolved against the audited set-flow table.

`TypeFaithful` (LSS_022) is the LICENSED tier. A `Transports` license behaves
exactly like a plain callee — instantiate the kernel's own occurrence type in
an isolated memo and unify the call shape, so the type's shared variables
transport sets with no poison and no bespoke machinery. This is
`applyCalleeAt`'s non-in-progress path minus the signature facts (a kernel
has no body and therefore no signature to consult). No arity rule is needed:
`unifyCallShape` peels one arrow per arg and unifies the residual with the
call's own type, which is shape-correct for partial and over-application
alike. An `Inert` license skips the boundary entirely — see the arm.

`Positional` (LSS_021) is the per-param tier, and it IS arity-aligned — a
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


kernelArgsGo : List KernelSetFacts.ParamSetFlow -> List (TOpt.Expr TypeIds.MVarId) -> Bool -> List IO.Variable -> Step ( Bool, List IO.Variable )
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


joinTunnels : IO.Variable -> List IO.Variable -> Step ()
joinTunnels resVar vars s0 =
    case vars of
        [] ->
            Ok ( (), s0 )

        v :: rest ->
            case joinArrowSets identity v resVar s0 of
                Err e ->
                    Err e

                Ok ( _, s1 ) ->
                    joinTunnels resVar rest s1


{-| Set-slot-only join with no poison attribution — the exported form for
translation-side consumers (LSS_021 tunnels).
-}
joinArrowSetsPlain : IO.Variable -> IO.Variable -> Step ()
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
this occurrence (LSS_013 spine injection with an arity bound of 1; nothing to do
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
    standaloneMemberWith (\_ -> 1) (Engine.memberIdFor key)


{-| S.10 (F-5C): how many arrows of this standalone value's occurrence type
are PARAMS, and therefore may carry its member id.

The chomper bound is the soundness argument: the first `declaredArity` arrows
ARE the parameters; arrow `declaredArity + 1` belongs to the returned value,
and the TYPE cannot make that distinction (`A -> (B -> C)` is `A -> B -> C`).
So the count comes from the DEFINITION, never the type.

Returns 1 — today's head-only behaviour — when the flag is off, when the node
cannot be resolved, and for eta-reduced/point-free definitions (zero params).
`max 1` is exactly today's floor at every call site, which makes enabling the
flag MONOTONE: sites only ever gain members at deeper arrows.

-}
spineDepthForGlobal : TOpt.Global -> Engine.S -> Int
spineDepthForGlobal g s =
    if not s.env.lss.spineArity then
        1

    else
        max 1 (declaredArityOf g 8 s)


declaredArityOf : TOpt.Global -> Int -> Engine.S -> Int
declaredArityOf ((TOpt.Global _ name) as g) fuel s =
    declaredArityGo name g fuel s


{-| GAP-7 seam 1 (LSS_020 plan Phase E.1): the arity walk threads the
ORIGINAL sought name through `Link` hops, because a cycle member maps as
`member -> Link(_M$first group)` — recursing with the target alone loses the
name before the `TOpt.Cycle` node is reached. `sought` stays fixed across
hops: correct for the documented single-hop pattern; a multi-hop chain
through a differently-named intermediate floors at 1 (sound — today's
behavior). NOTE the Cycle arm also deepens the VarGlobal/VarEnum/VarBox mint
arms and `Translate.standaloneArgMember` for cross-module references to
cycle members (they are VarGlobals whose node is `Link(group)`) — intended,
symmetric, all through this one function, and dormant under the default
`spineArity = False`.
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

            Just (TOpt.Cycle _ valueDefs funcDefs _) ->
                cycleDefArity sought valueDefs funcDefs

            _ ->
                1


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
standaloneMemberWith : (Engine.S -> Int) -> Step Int -> TOpt.Meta TypeIds.MVarId -> Step WalkPoint
standaloneMemberWith depthOf mint meta s0 =
    if canTypeIsArrow meta.tipe then
        case mint s0 of
            Err e ->
                Err e

            Ok ( mid, s1 ) ->
                case Store.loadType meta.tipe s1 of
                    Err e ->
                        Err e

                    Ok ( funcVar, s2 ) ->
                        case injectSpineMemberId (depthOf s2) mid funcVar s2 of
                            Err e ->
                                Err e

                            Ok ( _, s3 ) ->
                                -- Injected identity: complete to the
                                -- injection depth; beyond-depth slots stay
                                -- flex (EMPTY facts — sound).
                                Ok ( WpHonest funcVar, s3 )

    else
        Ok ( WpNone, s0 )


{-| LSS_013 (spine injection): a member id names not just the value's own head
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
from later unification widen the set; they never corrupt it — LSS_005).
-}
injectSpineMemberId : Int -> Int -> IO.Variable -> Step ()
injectSpineMemberId arity mid v0 s0 =
    spineGo mid arity CoreDict.empty v0 s0


spineGo : Int -> Int -> Dict Int () -> IO.Variable -> Step ()
spineGo mid remaining seen v s0 =
    -- Phase 3: ctx-threaded — one S write-back for the whole spine.
    Store.foldSetWrites (spineGoC mid remaining seen v (Store.setWriteCtx s0.store)) s0


spineGoC : Int -> Int -> Dict Int () -> IO.Variable -> Store.SetWriteCtx -> Store.SetWriteCtx
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
                IO.Structure (IO.FunL _ res slot) ->
                    -- One arrow consumed: descend the result with one fewer
                    -- arrow of budget.
                    spineGoC mid (remaining - 1) (CoreDict.insert key () seen) res (Store.unifySlotWithSetC False [ mid ] slot c1)

                IO.Alias _ _ _ real ->
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

`onPoison` (LSS_020 B.4): applied once per poison event so callers can
attribute the ⊤ — `identity` for the pre-plan let channel (its number is
frozen Run-J data), `Engine.bumpWidenedByCf` for every join the sigFlow
repair adds (via `joinArrowSetsSig`). Phase H.2 widens this parameter into a
poison MODE (PoisonUseOnly) — design for the parameter, don't over-build.
-}
joinArrowSets : (Engine.S -> Engine.S) -> IO.Variable -> IO.Variable -> Step ()
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
        ( IO.Structure flatA, IO.Structure flatB ) ->
            case ( flatA, flatB ) of
                ( IO.FunL argA resA slotA, IO.FunL argB resB slotB ) ->
                    case Store.unifyBestEffort slotA slotB s1 of
                        Err e ->
                            Err e

                        Ok ( _, s2 ) ->
                            case joinArrowSets onPoison argA argB s2 of
                                Err e ->
                                    Err e

                                Ok ( _, s3 ) ->
                                    joinArrowSets onPoison resA resB s3

                ( IO.Fun1 argA resA, IO.Fun1 argB resB ) ->
                    case joinArrowSets onPoison argA argB s1 of
                        Err e ->
                            Err e

                        Ok ( _, s2 ) ->
                            joinArrowSets onPoison resA resB s2

                ( IO.App1 _ _ argsA, IO.App1 _ _ argsB ) ->
                    joinArrowSetsList onPoison argsA argsB s1

                ( IO.Tuple1 a1 b1 restA, IO.Tuple1 a2 b2 restB ) ->
                    joinArrowSetsList onPoison (a1 :: b1 :: restA) (a2 :: b2 :: restB) s1

                ( IO.Record1 fieldsA extA, IO.Record1 fieldsB extB ) ->
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

                ( IO.EmptyRecord1, _ ) ->
                    Ok ( (), s1 )

                ( _, IO.EmptyRecord1 ) ->
                    Ok ( (), s1 )

                ( IO.Unit1, IO.Unit1 ) ->
                    Ok ( (), s1 )

                _ ->
                    poisonBoth onPoison a b s1

        ( IO.Alias _ _ _ realA, _ ) ->
            joinArrowSets onPoison realA b s1

        ( _, IO.Alias _ _ _ realB ) ->
            joinArrowSets onPoison a realB s1

        _ ->
            -- A variable on either side = a generalized position: poison both.
            poisonBoth onPoison a b s1


{-| `joinArrowSets` with sigFlow attribution: every join LSS_020 adds
(member-root, lambda-result, If/Case hub, Let rhs, local-callee shape) counts
its poison events in `sigStats.widenedByCf` (report-gated inside the bump).
-}
joinArrowSetsSig : IO.Variable -> IO.Variable -> Step ()
joinArrowSetsSig =
    joinArrowSets Engine.bumpWidenedByCf


{-| Flag-gated single-source join (Let rhs → letEnv hub; skip on no point).
-}
sigFlowJoinInto : IO.Variable -> Maybe IO.Variable -> Step ()
sigFlowJoinInto target maybePoint s0 =
    if s0.env.lss.sigFlow then
        case maybePoint of
            Just p ->
                joinArrowSetsSig target p s0

            Nothing ->
                Ok ( (), s0 )

    else
        Ok ( (), s0 )


joinArrowSetsList : (Engine.S -> Engine.S) -> List IO.Variable -> List IO.Variable -> Step ()
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


joinArrowSetsPairs : (Engine.S -> Engine.S) -> List ( IO.Variable, IO.Variable ) -> Step ()
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


poisonBoth : (Engine.S -> Engine.S) -> IO.Variable -> IO.Variable -> Step ()
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


canTypeIsArrow : Can.Type TypeIds.MVarId -> Bool
canTypeIsArrow t =
    case t of
        Can.TLambda _ _ ->
            True

        Can.TAlias _ _ _ (Can.Filled real) ->
            canTypeIsArrow real

        _ ->
            False


{-| Does a canonical type mention an arrow ANYWHERE (LSS_020 B.2's cheap
guard — keeps the new loads off the overwhelmingly arrow-free majority)?
Verbatim twin of `Translate.canTypeHasArrow`. `TVar → False` is deliberate: a
pure-TVar position either already connects via the MVarId memo or is
generalized, where a join would only poison.
-}
canTypeMentionsArrow : Can.Type TypeIds.MVarId -> Bool
canTypeMentionsArrow t =
    case t of
        Can.TLambda _ _ ->
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


{-| LSS_020 (B.1.g): descend an arrow spine binding one param name per arrow
into letEnv; returns the extended env and the spine position after the last
param (`Nothing` on early stop — erased/over-shadowed heads leave the
remaining params untracked, today's behavior, sound). Total: store reads
only. The `seen` set guards the transparent-alias chase (mirrors `spineGoC`);
`Store.arrowParts` handles Fun1+FunL but NOT Alias, hence the explicit arm.
-}
bindParamsFromSpine : List Name -> IO.Variable -> Dict Int () -> LetEnv -> Engine.S -> ( LetEnv, Maybe IO.Variable, Engine.S )
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
                    IO.Alias _ _ _ real ->
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


{-| LSS_020 (B.2): the If/Case hub. Publishes the joined branch flow ONLY
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
                    case joinAllSig hub (List.filterMap wpPoint wps) s1 of
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


joinAllSig : IO.Variable -> List IO.Variable -> Step ()
joinAllSig hub pts s0 =
    case pts of
        [] ->
            Ok ( (), s0 )

        p :: rest ->
            case joinArrowSetsSig hub p s0 of
                Err e ->
                    Err e

                Ok ( _, s1 ) ->
                    joinAllSig hub rest s1


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
