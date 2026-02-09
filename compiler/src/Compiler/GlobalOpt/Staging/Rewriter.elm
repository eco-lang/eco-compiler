module Compiler.GlobalOpt.Staging.Rewriter exposing
    ( applyStagingSolution
    )

{-| Applies the staging solution to rewrite the MonoGraph.

This module:

1.  Wraps producers whose natural staging differs from canonical
2.  Adjusts types to match canonical staging (flattening)

-}

import Compiler.AST.Monomorphized as Mono
import Compiler.Data.Name exposing (Name)
import Compiler.GlobalOpt.Staging.Types exposing (..)
import Compiler.GlobalOpt.Staging.UnionFind exposing (producerIdToKey)
import Compiler.Monomorphize.Closure as Closure
import Compiler.Reporting.Annotation as A
import Data.Map as Dict exposing (Dict)
import System.TypeCheck.IO as IO


type alias RewriteCtx =
    { lambdaCounter : Int
    , home : IO.Canonical
    }


initRewriteCtx : Mono.MonoGraph -> RewriteCtx
initRewriteCtx (Mono.MonoGraph record) =
    { lambdaCounter = maxLambdaIndexInGraph (Mono.MonoGraph record) + 1
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
        ( nodes1, _ ) =
            Dict.foldl compare
                (\nodeId node ( accNodes, accCtx ) ->
                    let
                        ( newNode, ctx1 ) =
                            rewriteNode solution producerInfo nodeId node accCtx
                    in
                    ( Dict.insert identity nodeId newNode accNodes, ctx1 )
                )
                ( Dict.empty, ctx0 )
                mono0.nodes

        mono1 =
            { mono0 | nodes = nodes1 }
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
                    Dict.get identity key solution.producerClass

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

                Just classId ->
                    let
                        canonicalSeg =
                            Dict.get identity classId solution.classSeg
                                |> Maybe.withDefault []

                        naturalSeg =
                            Dict.get identity key producerInfo.naturalSeg
                                |> Maybe.withDefault []
                    in
                    if naturalSeg == canonicalSeg then
                        -- No wrapper needed: enforce GOPT_001
                        ( Mono.MonoTailFunc params newBody canonType, ctx1 )

                    else
                        -- Wrapper/adaptation needed: canonType already satisfies GOPT_001
                        ( Mono.MonoTailFunc params newBody canonType, ctx1 )

        Mono.MonoDefine expr _ ->
            let
                ( newExpr, ctx1 ) =
                    rewriteExpr solution producerInfo expr ctx0

                -- Use the rewritten expression's type to ensure GOPT_001 consistency
                newType =
                    Mono.typeOf newExpr

                -- Ensure function-typed bare expressions are wrapped in closures.
                -- Without this, bare MonoVarKernel/MonoVarGlobal remain unwrapped and
                -- codegen emits eco.papCreate pointing directly at kernel symbols
                -- (which lack func.func declarations and violate the kernel call ABI).
                ( callableExpr, ctx2 ) =
                    ensureCallable newExpr newType ctx1
            in
            ( Mono.MonoDefine callableExpr (Mono.typeOf callableExpr), ctx2 )

        Mono.MonoPortIncoming expr monoType ->
            let
                ( newExpr, ctx1 ) =
                    rewriteExpr solution producerInfo expr ctx0

                newType =
                    Mono.typeOf newExpr

                ( callableExpr, ctx2 ) =
                    ensureCallable newExpr newType ctx1
            in
            ( Mono.MonoPortIncoming callableExpr monoType, ctx2 )

        Mono.MonoPortOutgoing expr monoType ->
            let
                ( newExpr, ctx1 ) =
                    rewriteExpr solution producerInfo expr ctx0

                newType =
                    Mono.typeOf newExpr

                ( callableExpr, ctx2 ) =
                    ensureCallable newExpr newType ctx1
            in
            ( Mono.MonoPortOutgoing callableExpr monoType, ctx2 )

        Mono.MonoCycle bindings monoType ->
            let
                ( newBindings, ctx1 ) =
                    List.foldl
                        (\( name, expr ) ( accBindings, accCtx ) ->
                            let
                                ( newExpr, ctxN ) =
                                    rewriteExpr solution producerInfo expr accCtx
                            in
                            ( accBindings ++ [ ( name, newExpr ) ], ctxN )
                        )
                        ( [], ctx0 )
                        bindings
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
                    Dict.get identity key solution.producerClass

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
                            Dict.get identity classId solution.classSeg
                                |> Maybe.withDefault []

                        naturalSeg =
                            Dict.get identity key producerInfo.naturalSeg
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
                            ( accBranches ++ [ ( newCond, newThen ) ], ctxNN )
                        )
                        ( [], ctx0 )
                        branches

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
                            ( accBranches ++ [ ( idx, newExpr ) ], ctxN )
                        )
                        ( [], ctx1 )
                        branches
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
                            ( accArgs ++ [ newArg ], ctxN )
                        )
                        ( [], ctx1 )
                        args
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
                            ( accFields ++ [ ( name, newExpr ) ], ctxN )
                        )
                        ( [], ctx0 )
                        fields
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
                            ( accFields ++ [ ( name, newExpr ) ], ctxN )
                        )
                        ( [], ctx1 )
                        fields
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
                            ( accExprs ++ [ newExpr ], ctxN )
                        )
                        ( [], ctx0 )
                        exprs
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
                            ( accExprs ++ [ newExpr ], ctxN )
                        )
                        ( [], ctx0 )
                        exprs
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
                            ( accArgs ++ [ ( argName, newExpr ) ], ctxN )
                        )
                        ( [], ctx0 )
                        args
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
                            ( accEdges ++ [ ( test, newSubDecider ) ], ctxN )
                        )
                        ( [], ctx0 )
                        edges

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
-- ENSURE CALLABLE
-- ============================================================================


{-| Ensure that function-typed expressions at the top level of a MonoDefine
are wrapped in closures. Bare MonoVarKernel and MonoVarGlobal expressions
need this so that codegen creates a lambda function (called via eco.call)
rather than emitting eco.papCreate directly referencing a kernel symbol.
-}
ensureCallable : Mono.MonoExpr -> Mono.MonoType -> RewriteCtx -> ( Mono.MonoExpr, RewriteCtx )
ensureCallable expr monoType ctx =
    case monoType of
        Mono.MFunction _ _ ->
            case expr of
                Mono.MonoClosure _ _ _ ->
                    ( expr, ctx )

                Mono.MonoVarGlobal region specId _ ->
                    let
                        stageArgTypes =
                            Mono.stageParamTypes monoType

                        stageRetType =
                            Mono.stageReturnType monoType
                    in
                    makeAliasClosure
                        (Mono.MonoVarGlobal region specId monoType)
                        stageArgTypes
                        stageRetType
                        monoType
                        ctx

                Mono.MonoVarKernel region kernelHome name kernelAbiType ->
                    let
                        ( kernelFlatArgTypes, kernelFlatRetType ) =
                            Closure.flattenFunctionType kernelAbiType

                        flattenedFuncType =
                            Mono.MFunction kernelFlatArgTypes kernelFlatRetType
                    in
                    makeAliasClosure
                        (Mono.MonoVarKernel region kernelHome name kernelAbiType)
                        kernelFlatArgTypes
                        kernelFlatRetType
                        flattenedFuncType
                        ctx

                _ ->
                    let
                        stageArgTypes =
                            Mono.stageParamTypes monoType

                        stageRetType =
                            Mono.stageReturnType monoType
                    in
                    makeAliasClosure expr stageArgTypes stageRetType monoType ctx

        _ ->
            ( expr, ctx )


{-| Wrap a callee expression in a closure that takes fresh params and calls it.
-}
makeAliasClosure :
    Mono.MonoExpr
    -> List Mono.MonoType
    -> Mono.MonoType
    -> Mono.MonoType
    -> RewriteCtx
    -> ( Mono.MonoExpr, RewriteCtx )
makeAliasClosure calleeExpr argTypes retType funcType ctx =
    let
        params =
            Closure.freshParams argTypes

        paramExprs =
            List.map (\( name, ty ) -> Mono.MonoVarLocal name ty) params

        ( lambdaId, ctx1 ) =
            freshLambdaId ctx

        region =
            Closure.extractRegion calleeExpr

        callExpr =
            Mono.MonoCall region calleeExpr paramExprs retType Mono.defaultCallInfo

        captures =
            Closure.computeClosureCaptures params callExpr

        closureInfo =
            { lambdaId = lambdaId
            , captures = captures
            , params = params
            }
    in
    ( Mono.MonoClosure closureInfo callExpr funcType, ctx1 )



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
        region =
            Closure.extractRegion (Mono.MonoClosure originalInfo originalBody canonType)
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
    if List.isEmpty params then
        calleeExpr

    else
        let
            calleeType =
                Mono.typeOf calleeExpr

            stageArgTypes =
                Mono.stageParamTypes calleeType

            stageArity =
                List.length stageArgTypes

            ( argsForStage, remainingParams ) =
                splitAt stageArity params

            argExprs =
                List.map (\( name, ty ) -> Mono.MonoVarLocal name ty) argsForStage

            resultType =
                Mono.stageReturnType calleeType

            callExpr =
                Mono.MonoCall region calleeExpr argExprs resultType Mono.defaultCallInfo
        in
        buildNestedCalls region callExpr remainingParams



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

    else if List.length allArgs == 0 then
        -- Non-function type - return as-is
        monoType

    else
        -- Fewer args than params - mono graph is inconsistent
        Debug.todo
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


{-| Find the maximum lambda index in the graph for generating fresh IDs.
-}
maxLambdaIndexInGraph : Mono.MonoGraph -> Int
maxLambdaIndexInGraph (Mono.MonoGraph mono) =
    Dict.foldl compare
        (\_ node acc -> max acc (maxLambdaIndexInNode node))
        0
        mono.nodes


maxLambdaIndexInNode : Mono.MonoNode -> Int
maxLambdaIndexInNode node =
    case node of
        Mono.MonoDefine expr _ ->
            maxLambdaIndexInExpr expr

        Mono.MonoTailFunc _ body _ ->
            maxLambdaIndexInExpr body

        Mono.MonoCycle bindings _ ->
            List.foldl (\( _, e ) acc -> max acc (maxLambdaIndexInExpr e)) 0 bindings

        _ ->
            0


maxLambdaIndexInExpr : Mono.MonoExpr -> Int
maxLambdaIndexInExpr expr =
    case expr of
        Mono.MonoClosure closureInfo body _ ->
            let
                thisIndex =
                    case closureInfo.lambdaId of
                        Mono.AnonymousLambda _ idx ->
                            idx
            in
            max thisIndex (maxLambdaIndexInExpr body)

        Mono.MonoIf branches elseExpr _ ->
            let
                branchMax =
                    List.foldl
                        (\( cond, then_ ) acc ->
                            max acc (max (maxLambdaIndexInExpr cond) (maxLambdaIndexInExpr then_))
                        )
                        0
                        branches
            in
            max branchMax (maxLambdaIndexInExpr elseExpr)

        Mono.MonoCase _ _ _ branches _ ->
            List.foldl (\( _, e ) acc -> max acc (maxLambdaIndexInExpr e)) 0 branches

        Mono.MonoLet def body _ ->
            max (maxLambdaIndexInDef def) (maxLambdaIndexInExpr body)

        Mono.MonoCall _ callee args _ _ ->
            let
                calleeMax =
                    maxLambdaIndexInExpr callee
            in
            List.foldl (\arg acc -> max acc (maxLambdaIndexInExpr arg)) calleeMax args

        Mono.MonoRecordCreate fields _ ->
            List.foldl (\( _, e ) acc -> max acc (maxLambdaIndexInExpr e)) 0 fields

        Mono.MonoRecordUpdate base fields _ ->
            let
                baseMax =
                    maxLambdaIndexInExpr base
            in
            List.foldl (\( _, e ) acc -> max acc (maxLambdaIndexInExpr e)) baseMax fields

        Mono.MonoTupleCreate _ exprs _ ->
            List.foldl (\e acc -> max acc (maxLambdaIndexInExpr e)) 0 exprs

        Mono.MonoList _ exprs _ ->
            List.foldl (\e acc -> max acc (maxLambdaIndexInExpr e)) 0 exprs

        Mono.MonoRecordAccess inner _ _ ->
            maxLambdaIndexInExpr inner

        Mono.MonoDestruct _ inner _ ->
            maxLambdaIndexInExpr inner

        _ ->
            0


maxLambdaIndexInDef : Mono.MonoDef -> Int
maxLambdaIndexInDef def =
    case def of
        Mono.MonoDef _ expr ->
            maxLambdaIndexInExpr expr

        Mono.MonoTailDef _ _ expr ->
            maxLambdaIndexInExpr expr
