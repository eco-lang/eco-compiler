module Compiler.GlobalOpt.Staging.Rewriter exposing (applyStagingSolution)

{-| Applies the staging solution to rewrite the MonoGraph.

This module:

1.  Wraps producers whose natural staging differs from canonical
2.  Adjusts types to match canonical staging (flattening)


# API

@docs applyStagingSolution

-}

import Array
import Compiler.AST.Monomorphized as Mono
import Compiler.Data.Name exposing (Name)
import Compiler.GlobalOpt.MonoReturnArity as MonoReturnArity
import Compiler.GlobalOpt.Staging.Types exposing (ProducerId(..), ProducerInfo, Segmentation, StagingSolution)
import Compiler.GlobalOpt.Staging.UnionFind exposing (producerIdToKey)
import Compiler.Monomorphize.Closure as Closure
import Compiler.Reporting.Annotation as A
import Dict
import System.TypeCheck.IO as IO
import Utils.Crash exposing (crash)


type alias RewriteCtx =
    { lambdaCounter : Int
    , home : IO.Canonical
    }


initRewriteCtx : Mono.MonoGraph -> RewriteCtx
initRewriteCtx (Mono.MonoGraph record) =
    { lambdaCounter = record.nextLambdaIndex
    , home = IO.Canonical ( "eco", "internal" ) "GlobalOpt"
    }


freshLambdaId : RewriteCtx -> ( Mono.LambdaId, RewriteCtx )
freshLambdaId ctx =
    ( Mono.AnonymousLambda ctx.home ctx.lambdaCounter
    , { ctx | lambdaCounter = ctx.lambdaCounter + 1 }
    )



-- ============================================================================
-- APPLY STAGING SOLUTION
-- ============================================================================


{-| Apply the staging solution to rewrite the MonoGraph.
-}
applyStagingSolution :
    StagingSolution
    -> ProducerInfo
    -> Mono.MonoGraph
    -> Mono.MonoGraph
applyStagingSolution solution producerInfo (Mono.MonoGraph mono0) =
    let
        ctx0 =
            initRewriteCtx (Mono.MonoGraph mono0)

        -- Rewrite all nodes
        ( _, nodes1, finalCtx ) =
            Array.foldl
                (\maybeNode ( nodeId, accNodes, accCtx ) ->
                    case maybeNode of
                        Nothing ->
                            ( nodeId + 1, Array.push Nothing accNodes, accCtx )

                        Just node ->
                            let
                                ( newNode, ctx1 ) =
                                    rewriteNode solution producerInfo nodeId node accCtx
                            in
                            ( nodeId + 1, Array.push (Just newNode) accNodes, ctx1 )
                )
                ( 0, Array.empty, ctx0 )
                mono0.nodes

        mono1 =
            { mono0 | nodes = nodes1, nextLambdaIndex = finalCtx.lambdaCounter }
    in
    Mono.MonoGraph mono1



-- ============================================================================
-- REWRITE NODE
-- ============================================================================


rewriteNode :
    StagingSolution
    -> ProducerInfo
    -> Int
    -> Mono.MonoNode
    -> RewriteCtx
    -> ( Mono.MonoNode, RewriteCtx )
rewriteNode solution producerInfo nodeId node ctx0 =
    case node of
        Mono.MonoTailFunc params body monoType ->
            let
                pid =
                    ProducerTailFunc nodeId

                key =
                    producerIdToKey pid

                maybeClassId =
                    Dict.get key solution.producerClass

                ( newBody, ctx1 ) =
                    rewriteExpr solution producerInfo body ctx0

                -- GOPT_001: Always compute canonical type
                paramCount =
                    List.length params

                canonType =
                    flattenTypeToArity paramCount monoType
            in
            case maybeClassId of
                Nothing ->
                    -- No staging class: enforce GOPT_001
                    ( Mono.MonoTailFunc params newBody canonType, ctx1 )

                Just _ ->
                    ( Mono.MonoTailFunc params newBody canonType, ctx1 )

        Mono.MonoDefine expr _ ->
            let
                ( newExpr, ctx1 ) =
                    rewriteExpr solution producerInfo expr ctx0

                -- Use the rewritten expression's type to ensure GOPT_001 consistency
                newType =
                    Mono.typeOf newExpr
            in
            ( Mono.MonoDefine newExpr newType, ctx1 )

        Mono.MonoCycle bindings monoType ->
            let
                ( newBindings, ctx1 ) =
                    List.foldl
                        (\( name, expr ) ( accBindings, accCtx ) ->
                            let
                                ( newExpr, ctxN ) =
                                    rewriteExpr solution producerInfo expr accCtx
                            in
                            ( ( name, newExpr ) :: accBindings, ctxN )
                        )
                        ( [], ctx0 )
                        bindings
                        |> Tuple.mapFirst List.reverse
            in
            ( Mono.MonoCycle newBindings monoType, ctx1 )

        _ ->
            ( node, ctx0 )



-- ============================================================================
-- REWRITE EXPRESSION
-- ============================================================================


rewriteExpr :
    StagingSolution
    -> ProducerInfo
    -> Mono.MonoExpr
    -> RewriteCtx
    -> ( Mono.MonoExpr, RewriteCtx )
rewriteExpr solution producerInfo expr ctx0 =
    case expr of
        Mono.MonoClosure closureInfo body monoType ->
            let
                pid =
                    ProducerClosure closureInfo.lambdaId

                key =
                    producerIdToKey pid

                maybeClassId =
                    Dict.get key solution.producerClass

                -- First rewrite body
                ( newBody, ctx1 ) =
                    rewriteExpr solution producerInfo body ctx0

                -- GOPT_001: Always compute canonical type for this closure
                paramCount =
                    List.length closureInfo.params

                canonType =
                    flattenTypeToArity paramCount monoType
            in
            case maybeClassId of
                Nothing ->
                    -- No staging class: enforce GOPT_001
                    ( Mono.MonoClosure closureInfo newBody canonType, ctx1 )

                Just classId ->
                    let
                        canonicalSeg =
                            Array.get classId solution.classSeg
                                |> Maybe.andThen identity
                                |> Maybe.withDefault []

                        naturalSeg =
                            Dict.get key producerInfo.naturalSeg
                                |> Maybe.withDefault []
                    in
                    if naturalSeg == canonicalSeg then
                        -- No wrapper needed: enforce GOPT_001
                        ( Mono.MonoClosure closureInfo newBody canonType, ctx1 )

                    else
                        -- Wrapper needed: pass canonType so inner closure satisfies GOPT_001
                        -- Pass monoType for segmentation derivation
                        wrapClosureToCanonical
                            closureInfo
                            newBody
                            monoType
                            canonType
                            canonicalSeg
                            ctx1

        Mono.MonoIf branches elseExpr monoType ->
            let
                ( newBranches, ctx1 ) =
                    List.foldl
                        (\( cond, then_ ) ( accBranches, accCtx ) ->
                            let
                                ( newCond, ctxN ) =
                                    rewriteExpr solution producerInfo cond accCtx

                                ( newThen, ctxNN ) =
                                    rewriteExpr solution producerInfo then_ ctxN
                            in
                            ( ( newCond, newThen ) :: accBranches, ctxNN )
                        )
                        ( [], ctx0 )
                        branches
                        |> Tuple.mapFirst List.reverse

                ( newElse, ctx2 ) =
                    rewriteExpr solution producerInfo elseExpr ctx1
            in
            ( Mono.MonoIf newBranches newElse monoType, ctx2 )

        Mono.MonoCase name1 name2 decider branches monoType ->
            let
                -- Rewrite expressions inside the decider (Inline leaves)
                ( newDecider, ctx1 ) =
                    rewriteDecider solution producerInfo decider ctx0

                ( newBranches, ctx2 ) =
                    List.foldl
                        (\( idx, branchExpr ) ( accBranches, accCtx ) ->
                            let
                                ( newExpr, ctxN ) =
                                    rewriteExpr solution producerInfo branchExpr accCtx
                            in
                            ( ( idx, newExpr ) :: accBranches, ctxN )
                        )
                        ( [], ctx1 )
                        branches
                        |> Tuple.mapFirst List.reverse
            in
            ( Mono.MonoCase name1 name2 newDecider newBranches monoType, ctx2 )

        Mono.MonoLet def body monoType ->
            let
                ( newDef, ctx1 ) =
                    rewriteDef solution producerInfo def ctx0

                ( newBody, ctx2 ) =
                    rewriteExpr solution producerInfo body ctx1
            in
            ( Mono.MonoLet newDef newBody monoType, ctx2 )

        Mono.MonoCall region callee args monoType callInfo ->
            let
                ( newCallee, ctx1 ) =
                    rewriteExpr solution producerInfo callee ctx0

                ( newArgs, ctx2 ) =
                    List.foldl
                        (\arg ( accArgs, accCtx ) ->
                            let
                                ( newArg, ctxN ) =
                                    rewriteExpr solution producerInfo arg accCtx
                            in
                            ( newArg :: accArgs, ctxN )
                        )
                        ( [], ctx1 )
                        args
                        |> Tuple.mapFirst List.reverse
            in
            ( Mono.MonoCall region newCallee newArgs monoType callInfo, ctx2 )

        Mono.MonoRecordCreate fields monoType ->
            let
                ( newFields, ctx1 ) =
                    List.foldl
                        (\( name, fieldExpr ) ( accFields, accCtx ) ->
                            let
                                ( newExpr, ctxN ) =
                                    rewriteExpr solution producerInfo fieldExpr accCtx
                            in
                            ( ( name, newExpr ) :: accFields, ctxN )
                        )
                        ( [], ctx0 )
                        fields
                        |> Tuple.mapFirst List.reverse
            in
            ( Mono.MonoRecordCreate newFields monoType, ctx1 )

        Mono.MonoRecordUpdate base fields monoType ->
            let
                ( newBase, ctx1 ) =
                    rewriteExpr solution producerInfo base ctx0

                ( newFields, ctx2 ) =
                    List.foldl
                        (\( name, fieldExpr ) ( accFields, accCtx ) ->
                            let
                                ( newExpr, ctxN ) =
                                    rewriteExpr solution producerInfo fieldExpr accCtx
                            in
                            ( ( name, newExpr ) :: accFields, ctxN )
                        )
                        ( [], ctx1 )
                        fields
                        |> Tuple.mapFirst List.reverse
            in
            ( Mono.MonoRecordUpdate newBase newFields monoType, ctx2 )

        Mono.MonoTupleCreate region exprs monoType ->
            let
                ( newExprs, ctx1 ) =
                    List.foldl
                        (\e ( accExprs, accCtx ) ->
                            let
                                ( newExpr, ctxN ) =
                                    rewriteExpr solution producerInfo e accCtx
                            in
                            ( newExpr :: accExprs, ctxN )
                        )
                        ( [], ctx0 )
                        exprs
                        |> Tuple.mapFirst List.reverse
            in
            ( Mono.MonoTupleCreate region newExprs monoType, ctx1 )

        Mono.MonoList region exprs monoType ->
            let
                ( newExprs, ctx1 ) =
                    List.foldl
                        (\e ( accExprs, accCtx ) ->
                            let
                                ( newExpr, ctxN ) =
                                    rewriteExpr solution producerInfo e accCtx
                            in
                            ( newExpr :: accExprs, ctxN )
                        )
                        ( [], ctx0 )
                        exprs
                        |> Tuple.mapFirst List.reverse
            in
            ( Mono.MonoList region newExprs monoType, ctx1 )

        Mono.MonoRecordAccess inner name monoType ->
            let
                ( newInner, ctx1 ) =
                    rewriteExpr solution producerInfo inner ctx0
            in
            ( Mono.MonoRecordAccess newInner name monoType, ctx1 )

        Mono.MonoDestruct destructor inner monoType ->
            let
                ( newInner, ctx1 ) =
                    rewriteExpr solution producerInfo inner ctx0
            in
            ( Mono.MonoDestruct destructor newInner monoType, ctx1 )

        Mono.MonoTailCall name args monoType ->
            let
                ( newArgs, ctx1 ) =
                    List.foldl
                        (\( argName, argExpr ) ( accArgs, accCtx ) ->
                            let
                                ( newExpr, ctxN ) =
                                    rewriteExpr solution producerInfo argExpr accCtx
                            in
                            ( ( argName, newExpr ) :: accArgs, ctxN )
                        )
                        ( [], ctx0 )
                        args
                        |> Tuple.mapFirst List.reverse
            in
            ( Mono.MonoTailCall name newArgs monoType, ctx1 )

        _ ->
            ( expr, ctx0 )


rewriteDef :
    StagingSolution
    -> ProducerInfo
    -> Mono.MonoDef
    -> RewriteCtx
    -> ( Mono.MonoDef, RewriteCtx )
rewriteDef solution producerInfo def ctx0 =
    case def of
        Mono.MonoDef name expr ->
            let
                ( newExpr, ctx1 ) =
                    rewriteExpr solution producerInfo expr ctx0
            in
            ( Mono.MonoDef name newExpr, ctx1 )

        Mono.MonoTailDef name params expr ->
            let
                ( newExpr, ctx1 ) =
                    rewriteExpr solution producerInfo expr ctx0
            in
            ( Mono.MonoTailDef name params newExpr, ctx1 )


{-| Rewrite expressions inside a Decider structure.
Traverses the decision tree and rewrites any Inline expressions.
-}
rewriteDecider :
    StagingSolution
    -> ProducerInfo
    -> Mono.Decider Mono.MonoChoice
    -> RewriteCtx
    -> ( Mono.Decider Mono.MonoChoice, RewriteCtx )
rewriteDecider solution producerInfo decider ctx0 =
    case decider of
        Mono.Leaf choice ->
            let
                ( newChoice, ctx1 ) =
                    rewriteChoice solution producerInfo choice ctx0
            in
            ( Mono.Leaf newChoice, ctx1 )

        Mono.Chain tests success failure ->
            let
                ( newSuccess, ctx1 ) =
                    rewriteDecider solution producerInfo success ctx0

                ( newFailure, ctx2 ) =
                    rewriteDecider solution producerInfo failure ctx1
            in
            ( Mono.Chain tests newSuccess newFailure, ctx2 )

        Mono.FanOut path edges fallback ->
            let
                ( newEdges, ctx1 ) =
                    List.foldl
                        (\( test, subDecider ) ( accEdges, accCtx ) ->
                            let
                                ( newSubDecider, ctxN ) =
                                    rewriteDecider solution producerInfo subDecider accCtx
                            in
                            ( ( test, newSubDecider ) :: accEdges, ctxN )
                        )
                        ( [], ctx0 )
                        edges
                        |> Tuple.mapFirst List.reverse

                ( newFallback, ctx2 ) =
                    rewriteDecider solution producerInfo fallback ctx1
            in
            ( Mono.FanOut path newEdges newFallback, ctx2 )


{-| Rewrite a MonoChoice, handling Inline expressions.
-}
rewriteChoice :
    StagingSolution
    -> ProducerInfo
    -> Mono.MonoChoice
    -> RewriteCtx
    -> ( Mono.MonoChoice, RewriteCtx )
rewriteChoice solution producerInfo choice ctx0 =
    case choice of
        Mono.Inline expr ->
            let
                ( newExpr, ctx1 ) =
                    rewriteExpr solution producerInfo expr ctx0
            in
            ( Mono.Inline newExpr, ctx1 )

        Mono.Jump idx ->
            ( Mono.Jump idx, ctx0 )



-- ============================================================================
-- WRAPPER BUILDING
-- ============================================================================


{-| Wrap a closure to match canonical staging.
Creates a new closure with the canonical staging that calls the original.
-}
wrapClosureToCanonical :
    Mono.ClosureInfo
    -> Mono.MonoExpr
    -> Mono.MonoType
    -> Mono.MonoType
    -> Segmentation
    -> RewriteCtx
    -> ( Mono.MonoExpr, RewriteCtx )
wrapClosureToCanonical originalInfo originalBody originalType canonType canonicalSeg ctx0 =
    let
        -- Use originalType for segmentation derivation (flat args/ret)
        ( flatArgs, flatRet ) =
            Mono.decomposeFunctionType originalType

        targetType =
            buildSegmentedFunctionType canonicalSeg flatArgs flatRet

        -- Build nested closures matching canonical staging
    in
    buildNestedWrapper
        targetType
        (Mono.MonoClosure originalInfo originalBody canonType)
        []
        ctx0


{-| Build nested closures that implement the canonical staging.
-}
buildNestedWrapper :
    Mono.MonoType
    -> Mono.MonoExpr
    -> List ( Name, Mono.MonoType )
    -> RewriteCtx
    -> ( Mono.MonoExpr, RewriteCtx )
buildNestedWrapper remainingType calleeExpr accParams ctx0 =
    let
        stageArgTypes =
            Mono.stageParamTypes remainingType

        stageRetType =
            Mono.stageReturnType remainingType
    in
    case stageArgTypes of
        [] ->
            -- No more stages - build the nested calls
            let
                region =
                    Closure.extractRegion calleeExpr

                finalCall =
                    buildNestedCalls region calleeExpr accParams
            in
            ( finalCall, ctx0 )

        _ ->
            -- Build closure for this stage
            let
                paramsForStage =
                    Closure.freshParams stageArgTypes

                newAccParams =
                    accParams ++ paramsForStage

                ( innerBody, ctx1 ) =
                    buildNestedWrapper stageRetType calleeExpr newAccParams ctx0

                captures =
                    Closure.computeClosureCaptures paramsForStage innerBody

                ( lambdaId, ctx2 ) =
                    freshLambdaId ctx1

                closureInfo =
                    { lambdaId = lambdaId
                    , captures = captures
                    , params = paramsForStage
                    , closureKind = Nothing
                    , captureAbi = Nothing
                    }
            in
            ( Mono.MonoClosure closureInfo innerBody remainingType, ctx2 )


{-| Build nested calls to apply all accumulated parameters.
-}
buildNestedCalls :
    A.Region
    -> Mono.MonoExpr
    -> List ( Name, Mono.MonoType )
    -> Mono.MonoExpr
buildNestedCalls region calleeExpr params =
    let
        -- Compute the total flattened arity of the callee (sum of all stages)
        totalArity =
            countTotalArityFromType (Mono.typeOf calleeExpr)

        buildCallsHelper : Mono.MonoExpr -> List ( Name, Mono.MonoType ) -> Int -> Mono.MonoExpr
        buildCallsHelper currentCallee remainingParams remainingArity =
            if List.isEmpty remainingParams then
                currentCallee

            else
                let
                    calleeType =
                        Mono.typeOf currentCallee

                    stageArgTypes =
                        Mono.stageParamTypes calleeType

                    stageArity =
                        List.length stageArgTypes
                in
                if stageArity == 0 then
                    crash
                        ("buildNestedCalls: callee type has no function stage but "
                            ++ String.fromInt (List.length remainingParams)
                            ++ " params remain. calleeType="
                            ++ Mono.toComparableMonoType calleeType
                        )

                else
                    let
                        ( argsForStage, restParams ) =
                            splitAt stageArity remainingParams

                        argExprs =
                            List.map (\( name, ty ) -> Mono.MonoVarLocal name ty) argsForStage

                        resultType =
                            Mono.stageReturnType calleeType

                        -- Compute the remaining stage segmentation from the callee type
                        restStages =
                            MonoReturnArity.collectStageArities resultType

                        -- Pre-compute CallInfo so annotateCallStaging doesn't need to
                        -- re-derive the arity from a potentially-captured callee variable.
                        callInfo =
                            { callModel = Mono.StageCurried
                            , stageArities = MonoReturnArity.collectStageArities calleeType
                            , isSingleStageSaturated = stageArity == remainingArity && remainingArity > 0
                            , initialRemaining = remainingArity
                            , remainingStageArities = restStages
                            , closureKind = Nothing
                            , captureAbi = Nothing
                            , callKind = Mono.CallDirectKnownSegmentation
                            }

                        callExpr =
                            Mono.MonoCall region currentCallee argExprs resultType callInfo

                        newRemainingArity =
                            remainingArity - stageArity
                    in
                    buildCallsHelper callExpr restParams newRemainingArity
    in
    if List.isEmpty params then
        calleeExpr

    else
        buildCallsHelper calleeExpr params totalArity


{-| Count total arity by summing all stage arities.
-}
countTotalArityFromType : Mono.MonoType -> Int
countTotalArityFromType monoType =
    case monoType of
        Mono.MFunction argTypes resultType ->
            List.length argTypes + countTotalArityFromType resultType

        _ ->
            0



-- ============================================================================
-- HELPERS
-- ============================================================================


{-| Flatten a function type to a given arity.
Flattens nested MFunction to match the target param count.
-}
flattenTypeToArity : Int -> Mono.MonoType -> Mono.MonoType
flattenTypeToArity targetArity monoType =
    let
        ( allArgs, finalResult ) =
            Closure.flattenFunctionType monoType
    in
    if targetArity == 0 then
        -- Not a function type, return as-is
        monoType

    else if List.length allArgs == targetArity then
        -- Already correct arity
        Mono.MFunction allArgs finalResult

    else if List.length allArgs > targetArity then
        -- More args than params - take first N, nest the rest
        let
            ( firstArgs, restArgs ) =
                splitAt targetArity allArgs

            nestedResult =
                if List.isEmpty restArgs then
                    finalResult

                else
                    Mono.MFunction restArgs finalResult
        in
        Mono.MFunction firstArgs nestedResult

    else if List.isEmpty allArgs then
        -- Non-function type - return as-is
        monoType

    else
        -- Fewer args than params - mono graph is inconsistent
        crash
            ("flattenTypeToArity: paramCount ("
                ++ String.fromInt targetArity
                ++ ") > number of flattened args ("
                ++ String.fromInt (List.length allArgs)
                ++ "); mono graph is inconsistent"
            )


{-| Build a function type from segmentation and flattened args/return.
-}
buildSegmentedFunctionType : Segmentation -> List Mono.MonoType -> Mono.MonoType -> Mono.MonoType
buildSegmentedFunctionType seg args ret =
    -- Note: Mono.buildSegmentedFunctionType takes (flatArgs, finalRet, seg)
    Mono.buildSegmentedFunctionType args ret seg


{-| Split a list at index n.
-}
splitAt : Int -> List a -> ( List a, List a )
splitAt n xs =
    ( List.take n xs, List.drop n xs )
