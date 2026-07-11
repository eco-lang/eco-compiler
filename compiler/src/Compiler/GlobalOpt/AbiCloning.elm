module Compiler.GlobalOpt.AbiCloning exposing (AbiCloningStats, abiCloningPass, emptyStats)

{-| ABI Cloning Pass — LSS singleton dispatch upgrade (design §9.2/§9.3).

Runs at GlobalOpt Phase 4, AFTER Staging (Phases 2-3) — the order is a
correctness dependency, not convention (design §9.3): the stamps placed
here denote value identity, and Staging's Rewriter is the last pass that
replaces values (wrapper closures). Staging wrappers propagate the
wrappee's `srcLambda` (LSS_008), so they register as additional instances
below and the uniqueness guard declines the upgrade wherever wrapping
occurred.

The pass:

1.  Indexes the graph: `srcLambda -> reachable MonoClosure instances`.
2.  For each `MonoCall` whose callee-type head annotation is a singleton
    lambda set `LSet [m]` with exactly ONE reachable instance of `m` whose
    ABI is determinable, stamps `callInfo.closureKind`,
    `callInfo.captureAbi`, and `callInfo.fastEvaluator`.
3.  Any ambiguity (no instance, several instances, shape mismatch) leaves
    the call untouched — `CallGenericApply`/`CallSegmentationUnknown`
    remain dynamically safe (CGEN_060). The multiple-instance case is
    ABI_CLONE_001's future cloning trigger; v1 only counts it.

MLIR codegen consults the stamps ONLY on the generic-apply and
segmentation-unknown emission paths (sites the staging solver could not
type). Typed direct paths are never rerouted — they are already at least
as good.

The instance-uniqueness guard is load-bearing: `_fast_evaluator` dispatch
calls the instance's fast clone directly with typed capture loads and NO
runtime identity check (EcoToLLVMClosures.cpp `emitFastClosureCall`).
Stamping a site whose value could be any other object — a staging
wrapper, an inliner copy — is a silent miscompile.


# API

@docs AbiCloningStats, abiCloningPass, emptyStats

-}

import Array
import Compiler.AST.Monomorphized as Mono
import Compiler.Data.Id as Id
import Compiler.Monomorphize.MonoTraverse as MonoTraverse
import Dict exposing (Dict)



-- ============================================================================
-- ====== STATS ======
-- ============================================================================


{-| Census counters (reported behind `lss.report` / ECO_MONO_LSS_REPORT).

  - dispatchUpgraded: call sites stamped for fast dispatch
  - declinedMultiInstance: singleton member with >1 reachable instance
    (staging wrappers, inliner copies — ABI_CLONE_001's trigger set)
  - declinedNoInstance: singleton member with no MonoClosure instance
    (interned globals/ctors/kernels, tail-def'd lambdas)
  - declinedShape: instance found but site/instance ABI shapes disagree
    (arity mismatch = the value would be a PAP; Char captures = untested
    i16 load path in emitFastClosureCall)

-}
type alias AbiCloningStats =
    { dispatchUpgraded : Int
    , declinedMultiInstance : Int
    , declinedNoInstance : Int
    , declinedShape : Int
    }


{-| All-zero stats (also returned when the pass short-circuits).
-}
emptyStats : AbiCloningStats
emptyStats =
    { dispatchUpgraded = 0
    , declinedMultiInstance = 0
    , declinedNoInstance = 0
    , declinedShape = 0
    }



-- ============================================================================
-- ====== INSTANCE INDEX ======
-- ============================================================================


{-| Reachable `MonoClosure` instances of one source member. Only exact
uniqueness matters; beyond one instance the details are irrelevant.
-}
type Instances
    = One Instance
    | Many


type alias Instance =
    { lambdaId : Mono.LambdaId
    , captureTypes : List Mono.MonoType
    , paramTypes : List Mono.MonoType
    , returnType : Mono.MonoType
    }


collectInstances : Mono.MonoGraph -> Dict Int Instances
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


collectExpr : Mono.MonoExpr -> Dict Int Instances -> Dict Int Instances
collectExpr expr acc =
    case expr of
        Mono.MonoClosure closureInfo body tipe ->
            case instanceMember closureInfo tipe of
                Just m ->
                    Dict.update m
                        (\present ->
                            case present of
                                Nothing ->
                                    Just
                                        (One
                                            { lambdaId = closureInfo.lambdaId
                                            , captureTypes = List.map (\( _, e, _ ) -> Mono.typeOf e) closureInfo.captures
                                            , paramTypes = List.map Tuple.second closureInfo.params
                                            , returnType = Mono.typeOf body
                                            }
                                        )

                                Just _ ->
                                    Just Many
                        )
                        acc

                Nothing ->
                    acc

        _ ->
            acc


{-| Which member this closure instance counts against in the index.

  - `srcLambda = Just m`: the stamped identity (mono-created instances,
    staging wrapper stages via LSS_008 propagation, inliner copies).
  - `srcLambda = Nothing` but the type's head annotation is a singleton
    `LSet [m]`: identity adoption (LSS_008) — GlobalOpt-synthesized
    closures (alias/general wrappers from wrapTopLevelCallables) carry no
    provenance stamp, yet their TYPE claims exactly one member, so the
    value can impersonate it at singleton call sites. Counting them as
    instances of that member makes the uniqueness guard decline the
    upgrade there. (`SrcLambdaId` is an opaque supply-only Id, so adoption
    happens here in the index rather than by stamping the ClosureInfo.)
  - `srcLambda = Nothing` with LTop / multi-member annotation: not
    indexed. Such a value can only flow to sites whose sets are at least
    as wide, and v1 never stamps non-singleton sites.

-}
instanceMember : Mono.ClosureInfo -> Mono.MonoType -> Maybe Int
instanceMember closureInfo tipe =
    case closureInfo.srcLambda of
        Just m ->
            Just (Id.toComparable m)

        Nothing ->
            Mono.singletonHeadMember tipe



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


stampNode : Dict Int Instances -> StampCtx -> Mono.MonoNode -> ( Mono.MonoNode, StampCtx )
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


stampExpr : Dict Int Instances -> StampCtx -> Mono.MonoExpr -> ( Mono.MonoExpr, StampCtx )
stampExpr index ctx expr =
    case expr of
        Mono.MonoCall region func args resultType callInfo ->
            case Mono.headAnno (Mono.typeOf func) of
                Mono.LSet [ m ] ->
                    case Dict.get m index of
                        Just (One inst) ->
                            if shapeOk (Mono.typeOf func) args inst then
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

                            else
                                ( expr, bumpShape ctx )

                        Just Many ->
                            ( expr, bumpMulti ctx )

                        Nothing ->
                            ( expr, bumpNoInstance ctx )

                _ ->
                    ( expr, ctx )

        _ ->
            ( expr, ctx )


{-| ABI-shape guards (all load-bearing, design §9.3):

  - non-empty params: zero-param closures are evaluated eagerly and never
    dispatch through papExtend;
  - site arg count == instance stage arity: the fast clone consumes the
    full stage — over/under-application keeps the dynamic path;
  - callee-type first-stage arity == instance stage arity: a PAP of the
    instance has strictly fewer remaining params, so this type check is
    what proves the flowing value is the RAW instance, not a runtime PAP
    of it (sets track provenance, not application depth — OQ4);
  - no Char captures: `emitFastClosureCall` loads every capture slot as
    i64 and only converts f64/pointer types; a Char capture would skew
    the fast clone's i16 parameter. First producer of that C++ path —
    keep it out of scope until it is exercised deliberately.

-}
shapeOk : Mono.MonoType -> List Mono.MonoExpr -> Instance -> Bool
shapeOk calleeType args inst =
    let
        stageArity =
            List.length inst.paramTypes

        calleeHeadArity =
            case calleeType of
                Mono.MFunction _ fargs _ ->
                    List.length fargs

                _ ->
                    -1
    in
    (stageArity > 0)
        && (List.length args == stageArity)
        && (calleeHeadArity == stageArity)
        && not (List.any ((==) Mono.MChar) inst.captureTypes)


kindIdFor : Int -> StampCtx -> ( Int, StampCtx )
kindIdFor m ctx =
    case Dict.get m ctx.kindIds of
        Just kid ->
            ( kid, ctx )

        Nothing ->
            ( ctx.nextKind
            , { ctx | kindIds = Dict.insert m ctx.nextKind ctx.kindIds, nextKind = ctx.nextKind + 1 }
            )


bumpMulti : StampCtx -> StampCtx
bumpMulti ctx =
    let
        stats =
            ctx.stats
    in
    { ctx | stats = { stats | declinedMultiInstance = stats.declinedMultiInstance + 1 } }


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
