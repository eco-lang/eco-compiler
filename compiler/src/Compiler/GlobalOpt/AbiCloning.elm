module Compiler.GlobalOpt.AbiCloning exposing (AbiCloningStats, abiCloningPass, emptyStats)

{-| ABI Cloning Pass — LSS singleton dispatch upgrade (design §9.2/§9.3,
M3.5 interchangeability rule, LSS_009).

Runs at GlobalOpt Phase 4, AFTER Staging (Phases 2-3) — the order is a
correctness dependency, not convention (design §9.3): the stamps placed
here denote value identity, and Staging's Rewriter is the last pass that
replaces values (wrapper closures). Staging wrappers propagate the
wrappee's `srcLambda` (LSS_008), so they register as BLOCKER instances
below and decline the upgrade wherever wrapping occurred.

The pass:

1.  Indexes the graph: `srcLambda -> all reachable MonoClosure instances`,
    each classified candidate/blocker with precomputed layout keys.
2.  For each `MonoCall` whose callee-type head annotation is a singleton
    lambda set `LSet [m]`: if `m` has no blockers, and the candidates
    compatible with the site's callee layout are unanimous in capture
    layout, stamps `callInfo.closureKind`/`captureAbi`/`fastEvaluator`
    with a REPRESENTATIVE instance (LSS_009 — verbatim copies of one
    member at one layout are interchangeable: monomorphization is
    type-directed and all external influence enters a lambda body via its
    captures/params, so same source + same layouts means alpha-equivalent
    compiled bodies with one `computeClosureCaptures` slot order).
3.  Anything else (no instance, blockers, layout mismatch, ABI
    disagreement) leaves the call untouched —
    `CallGenericApply`/`CallSegmentationUnknown` remain dynamically safe
    (CGEN_060). The declined classes are ABI_CLONE_001 / M5 sizing data.

MLIR codegen consults the stamps ONLY on the generic-apply and
segmentation-unknown emission paths (sites the staging solver could not
type). Typed direct paths are never rerouted — they are already at least
as good.

The blocker rule is load-bearing: `_fast_evaluator` dispatch calls the
stamped instance's fast clone directly with typed capture loads and NO
runtime identity check (EcoToLLVMClosures.cpp `emitFastClosureCall`).
Staging wrappers and `wrapTopLevelCallables` eta-wrappers share a member's
identity but not its code or capture layout — stamping across them is a
silent miscompile.


# API

@docs AbiCloningStats, abiCloningPass, emptyStats

-}

import Array
import Compiler.AST.Monomorphized as Mono
import Compiler.Data.Id as Id
import Compiler.GlobalOpt.Staging.Rewriter as Rewriter
import Compiler.Monomorphize.MonoTraverse as MonoTraverse
import Dict exposing (Dict)



-- ============================================================================
-- ====== STATS ======
-- ============================================================================


{-| Census counters (reported behind `lss.report` / ECO_MONO_LSS_REPORT).

  - dispatchUpgraded: call sites stamped for fast dispatch
  - declinedBlocked: singleton member with a blocker instance (staging
    wrapper stage or adopted synthetic eta-wrapper)
  - declinedNoInstance: singleton member with no MonoClosure instance
    (interned globals/ctors/kernels, tail-def'd lambdas)
  - declinedShape: no candidate matches the site's callee layout / arg
    count / guard set (a PAP value would be the only inhabitant, or Char
    captures)
  - declinedAbiMismatch: layout-compatible candidates disagree on capture
    layout (same source lambda capturing differently-typed environment
    per enclosing specialization)

-}
type alias AbiCloningStats =
    { dispatchUpgraded : Int
    , declinedBlocked : Int
    , declinedNoInstance : Int
    , declinedShape : Int
    , declinedAbiMismatch : Int
    }


{-| All-zero stats (also returned when the pass short-circuits).
-}
emptyStats : AbiCloningStats
emptyStats =
    { dispatchUpgraded = 0
    , declinedBlocked = 0
    , declinedNoInstance = 0
    , declinedShape = 0
    , declinedAbiMismatch = 0
    }



-- ============================================================================
-- ====== INSTANCE INDEX ======
-- ============================================================================


{-| One reachable `MonoClosure` counted against a member, in deterministic
node-walk order (the first compatible candidate is the stamped
representative).

`blocker = True` marks instances that share the member's identity but not
its code: staging-wrapper stages (LSS_008 propagation, synthetic
`Rewriter.wrapperHome`) and adopted synthetic closures (`srcLambda =
Nothing` under a singleton annotation — `wrapTopLevelCallables`
eta-wrappers). Their presence declines the member's sites outright.

`sigKey`/`abiKey` are annotation-widened comparable layouts (params+return
/ captures), precomputed so per-site checks are string compares instead of
repeated `eqLayout` walks.

-}
type alias Instance =
    { lambdaId : Mono.LambdaId
    , captureTypes : List Mono.MonoType
    , paramTypes : List Mono.MonoType
    , returnType : Mono.MonoType
    , blocker : Bool
    , sigKey : String
    , abiKey : String
    }


collectInstances : Mono.MonoGraph -> Dict Int (List Instance)
collectInstances (Mono.MonoGraph record) =
    Array.foldl
        (\maybeNode acc ->
            case maybeNode of
                Just node ->
                    List.foldl (\e a -> MonoTraverse.foldExpr collectExpr a e) acc (nodeExprs node)

                Nothing ->
                    acc
        )
        Dict.empty
        record.nodes
        |> Dict.map (\_ instancesRev -> List.reverse instancesRev)


nodeExprs : Mono.MonoNode -> List Mono.MonoExpr
nodeExprs node =
    case node of
        Mono.MonoDefine expr _ ->
            [ expr ]

        Mono.MonoTailFunc _ expr _ ->
            [ expr ]

        Mono.MonoPortIncoming expr _ ->
            [ expr ]

        Mono.MonoPortOutgoing expr _ ->
            [ expr ]

        Mono.MonoCtor _ _ ->
            []

        Mono.MonoEnum _ _ ->
            []

        Mono.MonoExtern _ ->
            []

        Mono.MonoManagerLeaf _ _ ->
            []


collectExpr : Mono.MonoExpr -> Dict Int (List Instance) -> Dict Int (List Instance)
collectExpr expr acc =
    case expr of
        Mono.MonoClosure closureInfo body tipe ->
            case instanceMember closureInfo tipe of
                Just ( m, isAdopted ) ->
                    let
                        captureTypes =
                            List.map (\( _, e, _ ) -> Mono.typeOf e) closureInfo.captures

                        paramTypes =
                            List.map Tuple.second closureInfo.params

                        returnType =
                            Mono.typeOf body

                        inst =
                            { lambdaId = closureInfo.lambdaId
                            , captureTypes = captureTypes
                            , paramTypes = paramTypes
                            , returnType = returnType
                            , blocker = isAdopted || isWrapperHome closureInfo.lambdaId
                            , sigKey = layoutKey (paramTypes ++ [ returnType ])
                            , abiKey = layoutKey captureTypes
                            }
                    in
                    Dict.update m (\present -> Just (inst :: Maybe.withDefault [] present)) acc

                Nothing ->
                    acc

        _ ->
            acc


{-| Which member this closure instance counts against, and whether the
identity was ADOPTED rather than stamped.

  - `srcLambda = Just m`: the stamped identity (mono-created instances,
    inliner copies, local-multi retranslations — all verbatim copies —
    plus staging wrapper stages via LSS_008 propagation, separated into
    blockers by their synthetic `lambdaId` home).
  - `srcLambda = Nothing` but the type's head annotation is a singleton
    `LSet [m]`: identity adoption (LSS_008) — GlobalOpt-synthesized
    closures (alias/general wrappers from wrapTopLevelCallables) carry no
    provenance stamp, yet their TYPE claims exactly one member, so the
    value can impersonate it at singleton call sites. They register as
    blockers. (`SrcLambdaId` is an opaque supply-only Id, so adoption
    happens here in the index rather than by stamping the ClosureInfo.)
  - `srcLambda = Nothing` with LTop / multi-member annotation: not
    indexed. Such a value can only flow to sites whose sets are at least
    as wide, and v1 never stamps non-singleton sites.

-}
instanceMember : Mono.ClosureInfo -> Mono.MonoType -> Maybe ( Int, Bool )
instanceMember closureInfo tipe =
    case closureInfo.srcLambda of
        Just m ->
            Just ( Id.toComparable m, False )

        Nothing ->
            Maybe.map (\m -> ( m, True )) (Mono.singletonHeadMember tipe)


isWrapperHome : Mono.LambdaId -> Bool
isWrapperHome (Mono.AnonymousLambda home _) =
    home == Rewriter.wrapperHome


{-| Annotation-widened comparable layout of a list of types (LSS_009's
`sigKey`/`abiKey` encoding). Widening first makes the key set-insensitive:
annotation-only differences never change behavior (LSS_005), so they must
not separate interchangeable instances.
-}
layoutKey : List Mono.MonoType -> String
layoutKey types =
    String.join "|" (List.map (\t -> Mono.toComparableMonoType (Mono.widenSets t)) types)



-- ============================================================================
-- ====== PUBLIC API ======
-- ============================================================================


type alias StampCtx =
    { kindIds : Dict Int Int -- member id -> ClosureKindId int
    , nextKind : Int
    , stats : AbiCloningStats
    }


{-| Run the ABI cloning pass on a MonoGraph.

With LSS off (or no singleton sets), the instance index is empty and the
graph is returned untouched — the pass is inert by construction, so the
flag-off pipeline stays byte-identical.

-}
abiCloningPass : Mono.MonoGraph -> ( Mono.MonoGraph, AbiCloningStats )
abiCloningPass ((Mono.MonoGraph record) as graph) =
    let
        index =
            collectInstances graph
    in
    if Dict.isEmpty index then
        ( graph, emptyStats )

    else
        let
            ( nodes1, finalCtx ) =
                Array.foldl
                    (\maybeNode ( accNodes, accCtx ) ->
                        case maybeNode of
                            Just node ->
                                let
                                    ( newNode, ctx1 ) =
                                        stampNode index accCtx node
                                in
                                ( Array.push (Just newNode) accNodes, ctx1 )

                            Nothing ->
                                ( Array.push Nothing accNodes, accCtx )
                    )
                    ( Array.empty, { kindIds = Dict.empty, nextKind = 0, stats = emptyStats } )
                    record.nodes
        in
        ( Mono.MonoGraph { record | nodes = nodes1 }, finalCtx.stats )


stampNode : Dict Int (List Instance) -> StampCtx -> Mono.MonoNode -> ( Mono.MonoNode, StampCtx )
stampNode index ctx node =
    case node of
        Mono.MonoDefine expr tipe ->
            let
                ( newExpr, ctx1 ) =
                    MonoTraverse.traverseExpr (stampExpr index) ctx expr
            in
            ( Mono.MonoDefine newExpr tipe, ctx1 )

        Mono.MonoTailFunc params expr tipe ->
            let
                ( newExpr, ctx1 ) =
                    MonoTraverse.traverseExpr (stampExpr index) ctx expr
            in
            ( Mono.MonoTailFunc params newExpr tipe, ctx1 )

        Mono.MonoPortIncoming expr tipe ->
            let
                ( newExpr, ctx1 ) =
                    MonoTraverse.traverseExpr (stampExpr index) ctx expr
            in
            ( Mono.MonoPortIncoming newExpr tipe, ctx1 )

        Mono.MonoPortOutgoing expr tipe ->
            let
                ( newExpr, ctx1 ) =
                    MonoTraverse.traverseExpr (stampExpr index) ctx expr
            in
            ( Mono.MonoPortOutgoing newExpr tipe, ctx1 )

        other ->
            ( other, ctx )


stampExpr : Dict Int (List Instance) -> StampCtx -> Mono.MonoExpr -> ( Mono.MonoExpr, StampCtx )
stampExpr index ctx expr =
    case expr of
        Mono.MonoCall region func args resultType callInfo ->
            case Mono.headAnno (Mono.typeOf func) of
                Mono.LSet [ m ] ->
                    case Dict.get m index of
                        Just instances ->
                            case resolveRepresentative (Mono.typeOf func) args instances of
                                Stamp inst ->
                                    let
                                        ( kindId, ctx1 ) =
                                            kindIdFor m ctx

                                        stamped =
                                            { callInfo
                                                | closureKind = Just (Mono.Known (Mono.ClosureKindId kindId))
                                                , captureAbi =
                                                    Just
                                                        { captureTypes = inst.captureTypes
                                                        , paramTypes = inst.paramTypes
                                                        , returnType = inst.returnType
                                                        }
                                                , fastEvaluator = Just inst.lambdaId
                                            }

                                        stats1 =
                                            ctx1.stats
                                    in
                                    ( Mono.MonoCall region func args resultType stamped
                                    , { ctx1 | stats = { stats1 | dispatchUpgraded = stats1.dispatchUpgraded + 1 } }
                                    )

                                Decline bump ->
                                    ( expr, bump ctx )

                        Nothing ->
                            ( expr, bumpNoInstance ctx )

                _ ->
                    ( expr, ctx )

        _ ->
            ( expr, ctx )


type Resolution
    = Stamp Instance
    | Decline (StampCtx -> StampCtx)


{-| LSS_009: pick an interchangeable representative for the site, or
decline with the census reason.

  - any blocker among the member's instances → decline (the flowing value
    could be the wrapper — its code and capture layout differ);
  - filter candidates to the site's callee layout (`sigKey`) plus the M3
    shape guards (non-empty params, site arg count == stage arity, no
    Char captures — `emitFastClosureCall`'s i16 capture load is still
    unexercised C++);
  - survivors must be unanimous in capture layout (`abiKey`); the FIRST
    survivor (deterministic node-walk order) is the representative.

-}
resolveRepresentative : Mono.MonoType -> List Mono.MonoExpr -> List Instance -> Resolution
resolveRepresentative calleeType args instances =
    if List.any .blocker instances then
        Decline bumpBlocked

    else
        let
            siteSigKey =
                case calleeType of
                    Mono.MFunction _ fargs fret ->
                        layoutKey (fargs ++ [ fret ])

                    _ ->
                        ""

            argCount =
                List.length args

            compatible =
                List.filter
                    (\inst ->
                        (inst.sigKey == siteSigKey)
                            && (List.length inst.paramTypes == argCount)
                            && (argCount > 0)
                            && not (List.any ((==) Mono.MChar) inst.captureTypes)
                    )
                    instances
        in
        case compatible of
            [] ->
                Decline bumpShape

            first :: rest ->
                if List.all (\inst -> inst.abiKey == first.abiKey) rest then
                    Stamp first

                else
                    Decline bumpAbiMismatch


kindIdFor : Int -> StampCtx -> ( Int, StampCtx )
kindIdFor m ctx =
    case Dict.get m ctx.kindIds of
        Just kid ->
            ( kid, ctx )

        Nothing ->
            ( ctx.nextKind
            , { ctx | kindIds = Dict.insert m ctx.nextKind ctx.kindIds, nextKind = ctx.nextKind + 1 }
            )


bumpBlocked : StampCtx -> StampCtx
bumpBlocked ctx =
    let
        stats =
            ctx.stats
    in
    { ctx | stats = { stats | declinedBlocked = stats.declinedBlocked + 1 } }


bumpNoInstance : StampCtx -> StampCtx
bumpNoInstance ctx =
    let
        stats =
            ctx.stats
    in
    { ctx | stats = { stats | declinedNoInstance = stats.declinedNoInstance + 1 } }


bumpShape : StampCtx -> StampCtx
bumpShape ctx =
    let
        stats =
            ctx.stats
    in
    { ctx | stats = { stats | declinedShape = stats.declinedShape + 1 } }


bumpAbiMismatch : StampCtx -> StampCtx
bumpAbiMismatch ctx =
    let
        stats =
            ctx.stats
    in
    { ctx | stats = { stats | declinedAbiMismatch = stats.declinedAbiMismatch + 1 } }
