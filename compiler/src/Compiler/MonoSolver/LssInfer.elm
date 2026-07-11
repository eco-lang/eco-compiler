module Compiler.MonoSolver.LssInfer exposing
    ( signatureFor
    , instantiateWithSignature
    , injectLambdaMember
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
import Compiler.MonoSolver.Store as Store
import Compiler.Reporting.Annotation as A
import Compiler.Type.UnionFind as UF
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
                case DMap.get TOpt.toComparableGlobal global s0.env.toptNodes of
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


{-| Unify a source lambda's own member into the head set slot of its loaded
type. No-op for untagged lambdas and non-slotted heads (an erased-var head
has no slot to constrain — sound: the arrow reads back whatever its other
constraints say, or LTop).
-}
injectLambdaMember : Maybe TypeIds.SrcLambdaId -> IO.Variable -> Step ()
injectLambdaMember srcLam funcVar s0 =
    case srcLam of
        Nothing ->
            Ok ( (), s0 )

        Just lamId ->
            injectHeadMemberId (Engine.srcLambdaKey lamId) funcVar s0



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
    case DMap.get TOpt.toComparableGlobal global s0.env.toptNodes of
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

                                        TOpt.TailDef _ name _ bodyExpr defType _ ->
                                            memberOf (TOpt.Global home name) defType (Just bodyExpr) s0
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
    -- capturing per-member arrow-slot arrays (self/sibling annotation vars
    -- share Points — the Σ rule).
    case loadMemberSlots members [] s0 of
        Err e ->
            Err e

        Ok ( slotsByMember, s1 ) ->
            case walkMembers members s1 of
                Err e ->
                    Err e

                Ok ( _, s2 ) ->
                    zonkSignatures slotsByMember [] s2


loadMemberSlots : List UnitMember -> List ( String, Array IO.Variable ) -> Step (List ( String, Array IO.Variable ))
loadMemberSlots members acc s0 =
    case members of
        [] ->
            Ok ( List.reverse acc, s0 )

        m :: rest ->
            case Store.loadTypeWithArrows m.sigType s0 of
                Err e ->
                    Err e

                Ok ( ( _, slots ), s1 ) ->
                    loadMemberSlots rest (( m.gkey, slots ) :: acc) s1


walkMembers : List UnitMember -> Step ()
walkMembers members s0 =
    case members of
        [] ->
            Ok ( (), s0 )

        m :: rest ->
            case m.body of
                Nothing ->
                    walkMembers rest s0

                Just body ->
                    case walkExpr CoreDict.empty body s0 of
                        Err e ->
                            Err e

                        Ok ( _, s1 ) ->
                            walkMembers rest s1


zonkSignatures : List ( String, Array IO.Variable ) -> List ( String, Engine.LssSignature ) -> Step (List ( String, Engine.LssSignature ))
zonkSignatures pending acc s0 =
    case pending of
        [] ->
            Ok ( List.reverse acc, s0 )

        ( gkey, slots ) :: rest ->
            case zonkOneSignature slots s0 of
                Err e ->
                    Err e

                Ok ( sig, s1 ) ->
                    zonkSignatures rest (( gkey, sig ) :: acc) s1


zonkOneSignature : Array IO.Variable -> Step Engine.LssSignature
zonkOneSignature slots s0 =
    zonkSigGo slots (Array.length slots) 0 [] s0


zonkSigGo : Array IO.Variable -> Int -> Int -> List Engine.ArrowFact -> Step Engine.LssSignature
zonkSigGo slots n i factsRev s0 =
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

                            fact =
                                case desc.content of
                                    IO.Structure (IO.LambdaSet1 top members) ->
                                        { rep = rep, members = CoreDict.keys members, top = top }

                                    _ ->
                                        -- FlexVar: the body contributed nothing.
                                        { rep = rep, members = [], top = False }
                        in
                        zonkSigGo slots n (i + 1) (fact :: factsRev) s2


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


{-| letEnv: let-bound name -> its RHS's loaded type Point (for the §7.4
set-slot-only join at use sites).
-}
type alias LetEnv =
    Dict Name IO.Variable


walkExpr : LetEnv -> TOpt.Expr TypeIds.MVarId -> Step ()
walkExpr letEnv expr s0 =
    case expr of
        TOpt.Function srcLam _ body meta ->
            case Store.loadType meta.tipe s0 of
                Err e ->
                    Err e

                Ok ( funcVar, s1 ) ->
                    case injectLambdaMember srcLam funcVar s1 of
                        Err e ->
                            Err e

                        Ok ( _, s2 ) ->
                            walkExpr letEnv body s2

        TOpt.TrackedFunction srcLam _ body meta ->
            case Store.loadType meta.tipe s0 of
                Err e ->
                    Err e

                Ok ( funcVar, s1 ) ->
                    case injectLambdaMember srcLam funcVar s1 of
                        Err e ->
                            Err e

                        Ok ( _, s2 ) ->
                            walkExpr letEnv body s2

        TOpt.Call _ func args meta ->
            case walkCall func args meta s0 of
                Err e ->
                    Err e

                Ok ( _, s1 ) ->
                    walkChildren letEnv (func :: args) s1

        TOpt.VarGlobal _ g meta ->
            standaloneMember ("g|" ++ TOpt.toComparableGlobal g) meta s0

        TOpt.VarEnum _ g _ meta ->
            standaloneMember ("c|" ++ TOpt.toComparableGlobal g) meta s0

        TOpt.VarBox _ g meta ->
            standaloneMember ("c|" ++ TOpt.toComparableGlobal g) meta s0

        TOpt.VarCycle _ home name meta ->
            standaloneMember ("g|" ++ TOpt.toComparableGlobal (TOpt.Global home name)) meta s0

        TOpt.VarKernel _ _ home name meta ->
            standaloneMember ("k|" ++ home ++ "." ++ name) meta s0

        TOpt.Accessor _ field meta ->
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

                        Ok ( _, s1 ) ->
                            case Store.loadType defType s1 of
                                Err e ->
                                    Err e

                                Ok ( rhsVar, s2 ) ->
                                    walkExpr (CoreDict.insert name rhsVar letEnv) body s2

                TOpt.TailDef _ name _ rhs defType _ ->
                    case walkExpr letEnv rhs s0 of
                        Err e ->
                            Err e

                        Ok ( _, s1 ) ->
                            case Store.loadType defType s1 of
                                Err e ->
                                    Err e

                                Ok ( rhsVar, s2 ) ->
                                    walkExpr (CoreDict.insert name rhsVar letEnv) body s2

        _ ->
            -- Everything else: structural recursion only. Shared MVarIds
            -- already carry the intra-def flow; re-implementing translate's
            -- demand-concretization corners here would be wrong-layer work.
            walkChildren letEnv (directChildren expr) s0


{-| Call handling. Global callee: instantiate with signature facts and unify
params/result (best-effort). Kernel/Debug callee: every arrow crossing the
ABI is dynamic — poison arg and result arrows (LSS_004). Anything else:
children only (the caller recurses via walkChildren).
-}
walkCall : TOpt.Expr TypeIds.MVarId -> List (TOpt.Expr TypeIds.MVarId) -> TOpt.Meta TypeIds.MVarId -> Step ()
walkCall func args meta s0 =
    case func of
        TOpt.VarGlobal _ g funcMeta ->
            applyCalleeAt g funcMeta.tipe args meta s0

        TOpt.VarCycle _ home name funcMeta ->
            applyCalleeAt (TOpt.Global home name) funcMeta.tipe args meta s0

        TOpt.VarKernel _ _ _ _ _ ->
            poisonCallBoundary args meta s0

        TOpt.VarDebug _ _ _ _ _ ->
            poisonCallBoundary args meta s0

        _ ->
            Ok ( (), s0 )


applyCalleeAt : TOpt.Global -> Can.Type TypeIds.MVarId -> List (TOpt.Expr TypeIds.MVarId) -> TOpt.Meta TypeIds.MVarId -> Step ()
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
                unifyCallShape funcVar args meta s1

    else
        case instantiateWithSignature g srcType s0 of
            Err e ->
                Err e

            Ok ( funcVar, s1 ) ->
                unifyCallShape funcVar args meta s1


{-| Unify a callee instantiation's params against the args and its residual
against the call's own type, so returned arrows carry their sets into this
def's flow.
-}
unifyCallShape : IO.Variable -> List (TOpt.Expr TypeIds.MVarId) -> TOpt.Meta TypeIds.MVarId -> Step ()
unifyCallShape funcVar args meta s0 =
    case unifyParamsBestEffort funcVar args s0 of
        Err e ->
            Err e

        Ok ( restVar, s1 ) ->
            case Store.loadType meta.tipe s1 of
                Err e ->
                    Err e

                Ok ( callVar, s2 ) ->
                    Store.unifyBestEffort restVar callVar s2


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


poisonCallBoundary : List (TOpt.Expr TypeIds.MVarId) -> TOpt.Meta TypeIds.MVarId -> Step ()
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
                            Ok ( (), Engine.bumpWidenedByKernel s3 )


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


{-| A standalone function value contributes an interned member to the head
arrow of its OWN type at this occurrence (nothing to do for non-arrows).
-}
standaloneMember : String -> TOpt.Meta TypeIds.MVarId -> Step ()
standaloneMember key meta s0 =
    if canTypeIsArrow meta.tipe then
        case Engine.memberIdFor key s0 of
            Err e ->
                Err e

            Ok ( mid, s1 ) ->
                case Store.loadType meta.tipe s1 of
                    Err e ->
                        Err e

                    Ok ( funcVar, s2 ) ->
                        injectHeadMemberId mid funcVar s2

    else
        Ok ( (), s0 )


injectHeadMemberId : Int -> IO.Variable -> Step ()
injectHeadMemberId mid funcVar s0 =
    let
        ( store1, desc ) =
            UF.get funcVar s0.store

        s1 =
            { s0 | store = store1 }
    in
    case Store.arrowSetSlot desc.content of
        Just slot ->
            Store.unifySlotWithSet False [ mid ] slot s1

        Nothing ->
            Ok ( (), s1 )


joinLetUse : LetEnv -> Name -> TOpt.Meta TypeIds.MVarId -> Step ()
joinLetUse letEnv name meta s0 =
    case CoreDict.get name letEnv of
        Nothing ->
            Ok ( (), s0 )

        Just rhsVar ->
            case Store.loadType meta.tipe s0 of
                Err e ->
                    Err e

                Ok ( useVar, s1 ) ->
                    joinArrowSets rhsVar useVar s1


{-| §7.4 let boundary, v1 policy: walk two loaded type structures in
parallel, unifying ONLY the set slots of arrows at matching positions. On
structural divergence (either side a variable or the shapes differ — a
generalized position), poison BOTH sides' remaining arrow slots and stop
descending that branch. All uses of a let-bound function thereby share one
set (union over uses — sound; per-use separation is the vNext upgrade, which
is why this stays a separate named function).
-}
joinArrowSets : IO.Variable -> IO.Variable -> Step ()
joinArrowSets a b s0 =
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
                            case joinArrowSets argA argB s2 of
                                Err e ->
                                    Err e

                                Ok ( _, s3 ) ->
                                    joinArrowSets resA resB s3

                ( IO.Fun1 argA resA, IO.Fun1 argB resB ) ->
                    case joinArrowSets argA argB s1 of
                        Err e ->
                            Err e

                        Ok ( _, s2 ) ->
                            joinArrowSets resA resB s2

                ( IO.App1 _ _ argsA, IO.App1 _ _ argsB ) ->
                    joinArrowSetsList argsA argsB s1

                ( IO.Tuple1 a1 b1 restA, IO.Tuple1 a2 b2 restB ) ->
                    joinArrowSetsList (a1 :: b1 :: restA) (a2 :: b2 :: restB) s1

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
                    case joinArrowSetsPairs shared s1 of
                        Err e ->
                            Err e

                        Ok ( _, s2 ) ->
                            joinArrowSets extA extB s2

                ( IO.EmptyRecord1, _ ) ->
                    Ok ( (), s1 )

                ( _, IO.EmptyRecord1 ) ->
                    Ok ( (), s1 )

                ( IO.Unit1, IO.Unit1 ) ->
                    Ok ( (), s1 )

                _ ->
                    poisonBoth a b s1

        ( IO.Alias _ _ _ realA, _ ) ->
            joinArrowSets realA b s1

        ( _, IO.Alias _ _ _ realB ) ->
            joinArrowSets a realB s1

        _ ->
            -- A variable on either side = a generalized position: poison both.
            poisonBoth a b s1


joinArrowSetsList : List IO.Variable -> List IO.Variable -> Step ()
joinArrowSetsList xs ys s0 =
    case ( xs, ys ) of
        ( x :: xr, y :: yr ) ->
            case joinArrowSets x y s0 of
                Err e ->
                    Err e

                Ok ( _, s1 ) ->
                    joinArrowSetsList xr yr s1

        _ ->
            Ok ( (), s0 )


joinArrowSetsPairs : List ( IO.Variable, IO.Variable ) -> Step ()
joinArrowSetsPairs pairs s0 =
    case pairs of
        [] ->
            Ok ( (), s0 )

        ( x, y ) :: rest ->
            case joinArrowSets x y s0 of
                Err e ->
                    Err e

                Ok ( _, s1 ) ->
                    joinArrowSetsPairs rest s1


poisonBoth : IO.Variable -> IO.Variable -> Step ()
poisonBoth a b s0 =
    case Store.poisonArrowSets a s0 of
        Err e ->
            Err e

        Ok ( _, s1 ) ->
            Store.poisonArrowSets b s1


canTypeIsArrow : Can.Type TypeIds.MVarId -> Bool
canTypeIsArrow t =
    case t of
        Can.TLambda _ _ ->
            True

        Can.TAlias _ _ _ (Can.Filled real) ->
            canTypeIsArrow real

        _ ->
            False



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
