module Compiler.GlobalOpt.MonoGlobalOptimize exposing (globalOptimize, globalOptimizeWithLog)

{-| Global optimization pass that runs after monomorphization and inlining but before MLIR codegen.

Assumes MonoInlineSimplify.optimize has already been applied.

This phase:

1.  Ensures top-level function-typed values (globals/ports) are represented as closures before staging
2.  Canonicalizes closure staging via graph-based solver + rewriting (GOPT\_001, GOPT\_003)
3.  Validates closure staging invariants
4.  Clones functions to ensure homogeneous closure parameter ABIs
5.  Annotates call staging metadata (call model, stage arities, etc.)

Monomorphize is staging-agnostic - it preserves curried TLambda structure from TypeSubst.
GlobalOpt owns all staging/ABI decisions and canonicalizes the types to match param counts.

Note: GOPT\_001 (closure params == stage arity) is verified by TestLogic.Generate.MonoFunctionArity,
not at runtime. The compiler trusts that canonicalizeClosureStaging produces correct output.

@docs globalOptimize, globalOptimizeWithLog

-}

import Array
import Compiler.AST.Monomorphized as Mono
import Compiler.Data.Name exposing (Name)
import Compiler.GlobalOpt.AbiCloning as AbiCloning
import Compiler.GlobalOpt.MonoReturnArity as MonoReturnArity
import Compiler.GlobalOpt.Staging as Staging
import Compiler.Monomorphize.Closure as Closure
import Compiler.Reporting.Annotation as A
import Dict exposing (Dict)
import Set exposing (Set)
import System.TypeCheck.IO as IO
import Task exposing (Task)



-- INTERNAL CONTEXT


{-| Internal context for the pass
-}
type alias GlobalCtx =
    { registry : Mono.SpecializationRegistry
    , lambdaCounter : Int
    }


initGlobalCtx : Mono.MonoGraph -> GlobalCtx
initGlobalCtx (Mono.MonoGraph record) =
    { registry = record.registry
    , lambdaCounter = record.nextLambdaIndex
    }


freshLambdaId : IO.Canonical -> GlobalCtx -> ( Mono.LambdaId, GlobalCtx )
freshLambdaId home ctx =
    ( Mono.AnonymousLambda home ctx.lambdaCounter
    , { ctx | lambdaCounter = ctx.lambdaCounter + 1 }
    )



-- CALL STAGING ENVIRONMENT


{-| Environment for tracking call models and source arities of local variables.
This replaces MLIR's Ctx.lookupVarCallModel and Ctx.lookupVarArity logic.
Also carries dynamicSlots from the staging solver for CallKind determination.
-}
type alias CallEnv =
    { varCallModel : Dict Name Mono.CallModel
    , varSourceArity : Dict Name Int
    , dynamicSlots : Set String
    , paramSlotKeys : Dict Name String
    }


emptyCallEnv : Set String -> CallEnv
emptyCallEnv dynamicSlots =
    { varCallModel = Dict.empty
    , varSourceArity = Dict.empty
    , dynamicSlots = dynamicSlots
    , paramSlotKeys = Dict.empty
    }



-- MAIN ENTRY POINT


{-| Run global optimization passes on a monomorphized program graph.

Assumes MonoInlineSimplify.optimize has already been applied externally.

1.  Phase 1: Wrap top-level callables in closures
2.  Phase 2: Staging analysis + graph rewrite (wrappers + types)
3.  Phase 3: Validate closure staging invariants (GOPT\_001, GOPT\_003)
4.  Phase 4: ABI Cloning - ensure homogeneous closure parameters
5.  Phase 5: Annotate call staging metadata using staging solution

-}
globalOptimize : Mono.MonoGraph -> Mono.MonoGraph
globalOptimize graph0a =
    let
        -- Phase 1: Wrap top-level function-typed values in closures
        -- (alias wrappers for globals/kernels, general closures for other exprs).
        graph1 =
            wrapTopLevelCallables graph0a

        -- Phase 2: Staging analysis + graph rewrite (wrappers + types)
        ( stagingSolution, graph2 ) =
            Staging.analyzeAndSolveStaging graph1

        -- Phase 3: Validate closure staging invariants (GOPT_001, GOPT_003)
        graph3 =
            Staging.validateClosureStaging graph2

        -- Phase 4: ABI Cloning - ensure homogeneous closure parameters
        -- Clones functions when a closure-typed parameter receives different
        -- capture ABIs at different call sites.
        graph4 =
            AbiCloning.abiCloningPass graph3
    in
    -- Phase 5: Annotate call staging metadata (with dynamic slots from solver)
    annotateCallStaging stagingSolution.dynamicSlots graph4


{-| Like globalOptimize, but logs each sub-pass to stderr via the provided logger.
-}
globalOptimizeWithLog : (String -> Task x ()) -> Mono.MonoGraph -> Task x Mono.MonoGraph
globalOptimizeWithLog log graph0a =
    log "  Phase 1: Wrap top-level callables..."
        |> Task.andThen
            (\_ ->
                let
                    graph1 =
                        wrapTopLevelCallables graph0a
                in
                log "  Phase 2: Staging analysis + rewrite..."
                    |> Task.andThen
                        (\_ ->
                            let
                                ( stagingSolution, graph2 ) =
                                    Staging.analyzeAndSolveStaging graph1
                            in
                            log "  Phase 3: Validate closure staging..."
                                |> Task.andThen
                                    (\_ ->
                                        let
                                            graph3 =
                                                Staging.validateClosureStaging graph2
                                        in
                                        log "  Phase 4: ABI cloning..."
                                            |> Task.andThen
                                                (\_ ->
                                                    let
                                                        graph4 =
                                                            AbiCloning.abiCloningPass graph3
                                                    in
                                                    log "  Phase 5: Annotate call staging..."
                                                        |> Task.map (\_ -> annotateCallStaging stagingSolution.dynamicSlots graph4)
                                                )
                                    )
                        )
            )



-- ============================================================================
-- CLOSURE STAGING CANONICALIZATION (GOPT_001)
-- ============================================================================
-- SPEC HOME LOOKUP


specHome : Mono.SpecializationRegistry -> Int -> IO.Canonical
specHome registry specId =
    case Array.get specId registry.reverseMapping |> Maybe.andThen identity of
        Just ( global, _, _ ) ->
            case global of
                Mono.Global home _ ->
                    home

                Mono.Accessor _ ->
                    IO.Canonical ( "eco", "accessor" ) "Accessor"

        Nothing ->
            IO.Canonical ( "eco", "global-optimize" ) "GlobalOptimize"



-- COLLECT CASE LEAF FUNCTIONS


collectCaseLeafFunctionsGO :
    Mono.Decider Mono.MonoChoice
    -> List ( Int, Mono.MonoExpr )
    -> List Mono.MonoType
collectCaseLeafFunctionsGO monoDecider monoJumps =
    let
        jumpDict =
            Dict.fromList monoJumps

        collectFromDecider : Mono.Decider Mono.MonoChoice -> List Mono.MonoType -> List Mono.MonoType
        collectFromDecider dec acc =
            case dec of
                Mono.Leaf choice ->
                    case choice of
                        Mono.Inline expr ->
                            case Mono.typeOf expr of
                                Mono.MFunction _ _ ->
                                    Mono.typeOf expr :: acc

                                _ ->
                                    acc

                        Mono.Jump idx ->
                            case Dict.get idx jumpDict of
                                Just jumpExpr ->
                                    case Mono.typeOf jumpExpr of
                                        Mono.MFunction _ _ ->
                                            Mono.typeOf jumpExpr :: acc

                                        _ ->
                                            acc

                                Nothing ->
                                    acc

                Mono.Chain _ success failure ->
                    collectFromDecider success (collectFromDecider failure acc)

                Mono.FanOut _ edges fallback ->
                    let
                        accAfterEdges =
                            List.foldl (\( _, d ) a -> collectFromDecider d a) acc edges
                    in
                    collectFromDecider fallback accAfterEdges
    in
    collectFromDecider monoDecider []



-- BRANCH NORMALIZATION HELPERS


{-| Information about ABI normalization needed for function-typed branches.
-}
type alias BranchNormalizationInfo =
    { canonicalType : Mono.MonoType
    , canonicalSeg : List Int
    }


{-| Analyze function types from branches to determine if ABI normalization is needed.
Returns Nothing if no function-typed branches exist.
-}
computeBranchNormalization : List Mono.MonoType -> Maybe BranchNormalizationInfo
computeBranchNormalization funcTypes =
    case funcTypes of
        [] ->
            Nothing

        _ ->
            let
                ( canonicalSeg, flatArgs, flatRet ) =
                    Mono.chooseCanonicalSegmentation funcTypes

                canonicalType =
                    Mono.buildSegmentedFunctionType flatArgs flatRet canonicalSeg
            in
            Just
                { canonicalType = canonicalType
                , canonicalSeg = canonicalSeg
                }


{-| Process a branch result expression with optional ABI normalization.
Always recursively processes the expression for nested case/if normalization.
If normalization info is provided and the expression is function-typed with
non-matching segmentation, wraps it with a canonical-ABI closure.
-}
processBranchResult :
    IO.Canonical
    -> Maybe BranchNormalizationInfo
    -> Mono.MonoExpr
    -> GlobalCtx
    -> ( Mono.MonoExpr, GlobalCtx )
processBranchResult home maybeNorm expr ctx =
    -- Always process the expression first for nested case/if normalization
    let
        ( processedExpr, ctx1 ) =
            rewriteExprForAbi home expr ctx
    in
    case maybeNorm of
        Nothing ->
            ( processedExpr, ctx1 )

        Just norm ->
            case Mono.typeOf processedExpr of
                Mono.MFunction _ _ ->
                    if Mono.segmentLengths (Mono.typeOf processedExpr) == norm.canonicalSeg then
                        ( processedExpr, ctx1 )

                    else
                        buildAbiWrapperGO home norm.canonicalType processedExpr ctx1

                _ ->
                    ( processedExpr, ctx1 )


{-| Process a decider tree, recursing into leaves and optionally normalizing function-typed results.
-}
processDeciderForAbi :
    IO.Canonical
    -> Maybe BranchNormalizationInfo
    -> Mono.Decider Mono.MonoChoice
    -> GlobalCtx
    -> ( Mono.Decider Mono.MonoChoice, GlobalCtx )
processDeciderForAbi home normInfo dec ctx =
    case dec of
        Mono.Leaf choice ->
            case choice of
                Mono.Inline expr ->
                    let
                        ( newExpr, ctx1 ) =
                            processBranchResult home normInfo expr ctx
                    in
                    ( Mono.Leaf (Mono.Inline newExpr), ctx1 )

                Mono.Jump _ ->
                    ( dec, ctx )

        Mono.Chain testChain success failure ->
            let
                ( newSuccess, ctx1 ) =
                    processDeciderForAbi home normInfo success ctx

                ( newFailure, ctx2 ) =
                    processDeciderForAbi home normInfo failure ctx1
            in
            ( Mono.Chain testChain newSuccess newFailure, ctx2 )

        Mono.FanOut path edges fallback ->
            let
                ( newEdges, ctx1 ) =
                    List.foldr
                        (\( test, d ) ( acc, accCtx ) ->
                            let
                                ( newD, accCtx1 ) =
                                    processDeciderForAbi home normInfo d accCtx
                            in
                            ( ( test, newD ) :: acc, accCtx1 )
                        )
                        ( [], ctx )
                        edges

                ( newFallback, ctx2 ) =
                    processDeciderForAbi home normInfo fallback ctx1
            in
            ( Mono.FanOut path newEdges newFallback, ctx2 )


{-| Process jump branches, recursing and optionally normalizing function-typed results.
-}
processJumpsForAbi :
    IO.Canonical
    -> Maybe BranchNormalizationInfo
    -> List ( Int, Mono.MonoExpr )
    -> GlobalCtx
    -> ( List ( Int, Mono.MonoExpr ), GlobalCtx )
processJumpsForAbi home normInfo branches ctx =
    List.foldr
        (\( idx, expr ) ( acc, accCtx ) ->
            let
                ( newExpr, accCtx1 ) =
                    processBranchResult home normInfo expr accCtx
            in
            ( ( idx, newExpr ) :: acc, accCtx1 )
        )
        ( [], ctx )
        branches



-- BUILD NESTED CALLS (GlobalOpt version)


{-| Build nested calls that apply all params to a callee, respecting the callee's staging.
Given calleeType with segmentation [2,3] and params [a,b,c,d,e]:

  - First call: callee(a,b) -> intermediate1
  - Second call: intermediate1(c,d,e) -> result

This follows MONO\_016: never pass more args to a stage than it accepts.

-}
buildNestedCallsGO : A.Region -> Mono.MonoExpr -> List ( Name, Mono.MonoType ) -> Mono.MonoExpr
buildNestedCallsGO region calleeExpr params =
    let
        calleeType =
            Mono.typeOf calleeExpr

        srcSeg =
            Mono.segmentLengths calleeType

        -- Total flattened arity of the callee (sum of all stages)
        totalArity =
            List.sum srcSeg

        paramExprs =
            List.map (\( name, ty ) -> Mono.MonoVarLocal name ty) params

        buildCalls : Mono.MonoExpr -> List Mono.MonoExpr -> List Int -> Int -> Mono.MonoExpr
        buildCalls currentCallee remainingArgs segLengths remainingArity =
            case ( segLengths, remainingArgs ) of
                ( [], _ ) ->
                    currentCallee

                ( m :: restSeg, _ ) ->
                    let
                        ( nowArgs, laterArgs ) =
                            ( List.take m remainingArgs, List.drop m remainingArgs )

                        currentCalleeType =
                            Mono.typeOf currentCallee

                        resultType =
                            Mono.stageReturnType currentCalleeType

                        -- Pre-compute CallInfo for this nested call using the known
                        -- callee segmentation. This avoids relying on sourceArityForCallee
                        -- which may not have access to the captured callee's actual arity.
                        -- remainingArity tracks how many args the current PAP still needs.
                        callInfo =
                            { callModel = Mono.StageCurried
                            , stageArities = segLengths
                            , isSingleStageSaturated = m == remainingArity && remainingArity > 0
                            , initialRemaining = remainingArity
                            , remainingStageArities = restSeg
                            , closureKind = Nothing
                            , captureAbi = Nothing
                            , callKind = Mono.CallDirectKnownSegmentation
                            }

                        callExpr =
                            Mono.MonoCall region currentCallee nowArgs resultType callInfo

                        -- After applying m args, remaining arity decreases
                        newRemainingArity =
                            remainingArity - m
                    in
                    buildCalls callExpr laterArgs restSeg newRemainingArity
    in
    buildCalls calleeExpr paramExprs srcSeg totalArity



-- CLOSURE WRAPPER BUILDERS (GlobalOpt versions using GlobalCtx)


{-| Create an alias closure wrapper around a callee expression.
Used for wrapping MonoVarGlobal and MonoVarKernel in closures.
-}
makeAliasClosureGO :
    IO.Canonical
    -> Mono.MonoExpr
    -> List Mono.MonoType
    -> Mono.MonoType
    -> Mono.MonoType
    -> GlobalCtx
    -> ( Mono.MonoExpr, GlobalCtx )
makeAliasClosureGO home calleeExpr argTypes retType funcType ctx =
    let
        params =
            Closure.freshParams argTypes

        paramExprs =
            List.map (\( name, ty ) -> Mono.MonoVarLocal name ty) params

        ( lambdaId, ctx1 ) =
            freshLambdaId home ctx

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
            , closureKind = Nothing
            , captureAbi = Nothing
            }
    in
    ( Mono.MonoClosure closureInfo callExpr funcType, ctx1 )


{-| Create a general closure wrapper around an arbitrary expression.
Used for wrapping non-closure, non-global expressions.
-}
makeGeneralClosureGO :
    IO.Canonical
    -> Mono.MonoExpr
    -> List Mono.MonoType
    -> Mono.MonoType
    -> Mono.MonoType
    -> GlobalCtx
    -> ( Mono.MonoExpr, GlobalCtx )
makeGeneralClosureGO home expr argTypes retType funcType ctx =
    let
        params =
            Closure.freshParams argTypes

        paramExprs =
            List.map (\( name, ty ) -> Mono.MonoVarLocal name ty) params

        ( lambdaId, ctx1 ) =
            freshLambdaId home ctx

        region =
            Closure.extractRegion expr

        callExpr =
            Mono.MonoCall region expr paramExprs retType Mono.defaultCallInfo

        captures =
            Closure.computeClosureCaptures params callExpr

        closureInfo =
            { lambdaId = lambdaId
            , captures = captures
            , params = params
            , closureKind = Nothing
            , captureAbi = Nothing
            }
    in
    ( Mono.MonoClosure closureInfo callExpr funcType, ctx1 )


{-| Ensure a top-level node expression is directly callable.
This wraps bare MonoVarGlobal/MonoVarKernel in closures.
Called during ABI normalization, BEFORE rewriteExprForAbi.
-}
ensureCallableForNode :
    IO.Canonical
    -> Mono.MonoExpr
    -> Mono.MonoType
    -> GlobalCtx
    -> ( Mono.MonoExpr, GlobalCtx )
ensureCallableForNode home expr monoType ctx =
    case monoType of
        Mono.MFunction _ _ ->
            let
                stageArgTypes =
                    Mono.stageParamTypes monoType

                stageRetType =
                    Mono.stageReturnType monoType
            in
            case expr of
                Mono.MonoClosure _ _ _ ->
                    -- Already a closure: nothing to do
                    ( expr, ctx )

                Mono.MonoVarGlobal region specId _ ->
                    -- Alias wrapper around a global function specialization
                    makeAliasClosureGO home
                        (Mono.MonoVarGlobal region specId monoType)
                        stageArgTypes
                        stageRetType
                        monoType
                        ctx

                Mono.MonoVarKernel region kernelHome name kernelAbiType ->
                    -- Kernels use flattened ABI (all params at once)
                    let
                        ( kernelFlatArgTypes, kernelFlatRetType ) =
                            Closure.flattenFunctionType kernelAbiType

                        flattenedFuncType =
                            Mono.MFunction kernelFlatArgTypes kernelFlatRetType
                    in
                    makeAliasClosureGO home
                        (Mono.MonoVarKernel region kernelHome name kernelAbiType)
                        kernelFlatArgTypes
                        kernelFlatRetType
                        flattenedFuncType
                        ctx

                _ ->
                    -- General expression: wrap in a closure using staging of monoType
                    makeGeneralClosureGO home expr stageArgTypes stageRetType monoType ctx

        _ ->
            -- Non-function: leave as-is
            ( expr, ctx )



-- BUILD ABI WRAPPER


buildAbiWrapperGO :
    IO.Canonical
    -> Mono.MonoType
    -> Mono.MonoExpr
    -> GlobalCtx
    -> ( Mono.MonoExpr, GlobalCtx )
buildAbiWrapperGO home targetType calleeExpr ctx0 =
    let
        srcType =
            Mono.typeOf calleeExpr

        targetSeg =
            Mono.segmentLengths targetType

        srcSeg =
            Mono.segmentLengths srcType

        -- Note: GOPT_003 (total arities match) is verified by tests,
        -- not at runtime. See TestLogic.Monomorphize.MonoCaseBranchResultType.
    in
    if targetSeg == srcSeg then
        ( calleeExpr, ctx0 )

    else
        let
            region =
                Closure.extractRegion calleeExpr

            buildStages :
                Mono.MonoType
                -> List ( Name, Mono.MonoType )
                -> GlobalCtx
                -> ( Mono.MonoExpr, GlobalCtx )
            buildStages remainingType accParams ctx =
                let
                    stageArgTypes =
                        Mono.stageParamTypes remainingType

                    stageRetType =
                        Mono.stageReturnType remainingType
                in
                case stageArgTypes of
                    [] ->
                        ( buildNestedCallsGO region calleeExpr accParams, ctx )

                    _ ->
                        let
                            paramsForStage =
                                Closure.freshParams stageArgTypes

                            newAccParams =
                                accParams ++ paramsForStage

                            ( innerBody, ctx1 ) =
                                buildStages stageRetType newAccParams ctx

                            captures =
                                Closure.computeClosureCaptures paramsForStage innerBody

                            ( lambdaId, ctx2 ) =
                                freshLambdaId home ctx1

                            closureInfo =
                                { lambdaId = lambdaId
                                , captures = captures
                                , params = paramsForStage
                                , closureKind = Nothing
                                , captureAbi = Nothing
                                }
                        in
                        ( Mono.MonoClosure closureInfo innerBody remainingType, ctx2 )
        in
        buildStages targetType [] ctx0



-- REWRITE EXPR FOR ABI
--
-- Uses MonoTraverse for structural recursion, with special handling for
-- MonoCase and MonoIf (the ABI normalization targets).


rewriteExprForAbi : IO.Canonical -> Mono.MonoExpr -> GlobalCtx -> ( Mono.MonoExpr, GlobalCtx )
rewriteExprForAbi home expr ctx =
    case expr of
        -- ABI normalization targets - use dedicated handlers
        Mono.MonoCase scrutName scrutTypeName decider branches resultType ->
            rewriteCaseForAbi home scrutName scrutTypeName decider branches resultType ctx

        Mono.MonoIf branches final resultType ->
            rewriteIfForAbi home branches final resultType ctx

        -- Manual recursion for other expression types
        Mono.MonoClosure info body closureType ->
            let
                ( newCaptures, ctx1 ) =
                    List.foldr
                        (\( n, e, t ) ( acc, accCtx ) ->
                            let
                                ( newE, accCtx1 ) =
                                    rewriteExprForAbi home e accCtx
                            in
                            ( ( n, newE, t ) :: acc, accCtx1 )
                        )
                        ( [], ctx )
                        info.captures

                ( newBody, ctx2 ) =
                    rewriteExprForAbi home body ctx1
            in
            ( Mono.MonoClosure { info | captures = newCaptures } newBody closureType, ctx2 )

        Mono.MonoCall region func args resultType callInfo ->
            let
                ( newFunc, ctx1 ) =
                    rewriteExprForAbi home func ctx

                ( newArgs, ctx2 ) =
                    List.foldr
                        (\e ( acc, accCtx ) ->
                            let
                                ( newE, accCtx1 ) =
                                    rewriteExprForAbi home e accCtx
                            in
                            ( newE :: acc, accCtx1 )
                        )
                        ( [], ctx1 )
                        args
            in
            ( Mono.MonoCall region newFunc newArgs resultType callInfo, ctx2 )

        Mono.MonoTailCall name args resultType ->
            let
                ( newArgs, ctx1 ) =
                    List.foldr
                        (\( n, e ) ( acc, accCtx ) ->
                            let
                                ( newE, accCtx1 ) =
                                    rewriteExprForAbi home e accCtx
                            in
                            ( ( n, newE ) :: acc, accCtx1 )
                        )
                        ( [], ctx )
                        args
            in
            ( Mono.MonoTailCall name newArgs resultType, ctx1 )

        Mono.MonoLet def body resultType ->
            let
                ( newDef, ctx1 ) =
                    rewriteDefForAbi home def ctx

                ( newBody, ctx2 ) =
                    rewriteExprForAbi home body ctx1
            in
            ( Mono.MonoLet newDef newBody resultType, ctx2 )

        Mono.MonoDestruct path inner resultType ->
            let
                ( newInner, ctx1 ) =
                    rewriteExprForAbi home inner ctx
            in
            ( Mono.MonoDestruct path newInner resultType, ctx1 )

        Mono.MonoList region items resultType ->
            let
                ( newItems, ctx1 ) =
                    List.foldr
                        (\e ( acc, accCtx ) ->
                            let
                                ( newE, accCtx1 ) =
                                    rewriteExprForAbi home e accCtx
                            in
                            ( newE :: acc, accCtx1 )
                        )
                        ( [], ctx )
                        items
            in
            ( Mono.MonoList region newItems resultType, ctx1 )

        Mono.MonoRecordCreate fields resultType ->
            let
                ( newFields, ctx1 ) =
                    List.foldr
                        (\( n, e ) ( acc, accCtx ) ->
                            let
                                ( newE, accCtx1 ) =
                                    rewriteExprForAbi home e accCtx
                            in
                            ( ( n, newE ) :: acc, accCtx1 )
                        )
                        ( [], ctx )
                        fields
            in
            ( Mono.MonoRecordCreate newFields resultType, ctx1 )

        Mono.MonoRecordAccess inner field resultType ->
            let
                ( newInner, ctx1 ) =
                    rewriteExprForAbi home inner ctx
            in
            ( Mono.MonoRecordAccess newInner field resultType, ctx1 )

        Mono.MonoRecordUpdate record updates resultType ->
            let
                ( newRecord, ctx1 ) =
                    rewriteExprForAbi home record ctx

                ( newUpdates, ctx2 ) =
                    List.foldr
                        (\( n, e ) ( acc, accCtx ) ->
                            let
                                ( newE, accCtx1 ) =
                                    rewriteExprForAbi home e accCtx
                            in
                            ( ( n, newE ) :: acc, accCtx1 )
                        )
                        ( [], ctx1 )
                        updates
            in
            ( Mono.MonoRecordUpdate newRecord newUpdates resultType, ctx2 )

        Mono.MonoTupleCreate region elements resultType ->
            let
                ( newElements, ctx1 ) =
                    List.foldr
                        (\e ( acc, accCtx ) ->
                            let
                                ( newE, accCtx1 ) =
                                    rewriteExprForAbi home e accCtx
                            in
                            ( newE :: acc, accCtx1 )
                        )
                        ( [], ctx )
                        elements
            in
            ( Mono.MonoTupleCreate region newElements resultType, ctx1 )

        -- Leaf expressions - no children to process
        Mono.MonoLiteral _ _ ->
            ( expr, ctx )

        Mono.MonoVarLocal _ _ ->
            ( expr, ctx )

        Mono.MonoVarGlobal _ _ _ ->
            ( expr, ctx )

        Mono.MonoVarKernel _ _ _ _ ->
            ( expr, ctx )

        Mono.MonoUnit ->
            ( expr, ctx )


rewriteDefForAbi : IO.Canonical -> Mono.MonoDef -> GlobalCtx -> ( Mono.MonoDef, GlobalCtx )
rewriteDefForAbi home def ctx =
    case def of
        Mono.MonoDef name bound ->
            let
                ( newBound, ctx1 ) =
                    rewriteExprForAbi home bound ctx
            in
            ( Mono.MonoDef name newBound, ctx1 )

        Mono.MonoTailDef name params bound ->
            let
                ( newBound, ctx1 ) =
                    rewriteExprForAbi home bound ctx
            in
            ( Mono.MonoTailDef name params newBound, ctx1 )



-- REWRITE CASE FOR ABI


rewriteCaseForAbi :
    IO.Canonical
    -> Name
    -> Name
    -> Mono.Decider Mono.MonoChoice
    -> List ( Int, Mono.MonoExpr )
    -> Mono.MonoType
    -> GlobalCtx
    -> ( Mono.MonoExpr, GlobalCtx )
rewriteCaseForAbi home scrutName scrutTypeName decider branches resultType ctx0 =
    let
        leafTypes =
            collectCaseLeafFunctionsGO decider branches

        normInfo =
            computeBranchNormalization leafTypes

        ( newDecider, ctx1 ) =
            processDeciderForAbi home normInfo decider ctx0

        ( newBranches, ctx2 ) =
            processJumpsForAbi home normInfo branches ctx1

        finalType =
            case normInfo of
                Nothing ->
                    resultType

                Just info ->
                    info.canonicalType
    in
    ( Mono.MonoCase scrutName scrutTypeName newDecider newBranches finalType, ctx2 )



-- REWRITE IF FOR ABI


rewriteIfForAbi :
    IO.Canonical
    -> List ( Mono.MonoExpr, Mono.MonoExpr )
    -> Mono.MonoExpr
    -> Mono.MonoType
    -> GlobalCtx
    -> ( Mono.MonoExpr, GlobalCtx )
rewriteIfForAbi home branches final resultType ctx0 =
    let
        branchResults =
            List.map Tuple.second branches ++ [ final ]

        leafTypes =
            branchResults
                |> List.filterMap
                    (\e ->
                        case Mono.typeOf e of
                            Mono.MFunction _ _ ->
                                Just (Mono.typeOf e)

                            _ ->
                                Nothing
                    )

        normInfo =
            computeBranchNormalization leafTypes

        ( newBranches, ctx1 ) =
            List.foldr
                (\( cond, then_ ) ( acc, accCtx ) ->
                    let
                        -- Process condition normally (no normalization)
                        ( newCond, accCtx1 ) =
                            rewriteExprForAbi home cond accCtx

                        -- Process then-branch with potential normalization
                        ( newThen, accCtx2 ) =
                            processBranchResult home normInfo then_ accCtx1
                    in
                    ( ( newCond, newThen ) :: acc, accCtx2 )
                )
                ( [], ctx0 )
                branches

        ( newFinal, ctx2 ) =
            processBranchResult home normInfo final ctx1

        finalType =
            case normInfo of
                Nothing ->
                    resultType

                Just info ->
                    info.canonicalType
    in
    ( Mono.MonoIf newBranches newFinal finalType, ctx2 )



-- WRAP TOP-LEVEL CALLABLES (GRAPH-LEVEL)


{-| Phase: Ensure all top-level function-typed values are closures.

This runs after inlining/simplification but before the staging solver.
It wraps bare MonoVarGlobal and MonoVarKernel in alias closures via
ensureCallableForNode, and wraps other function-typed expressions in
general closures.

-}
wrapTopLevelCallables : Mono.MonoGraph -> Mono.MonoGraph
wrapTopLevelCallables (Mono.MonoGraph record0) =
    let
        ctx0 =
            initGlobalCtx (Mono.MonoGraph record0)

        ( newNodes, finalCtx ) =
            Array.foldl
                (\maybeNode ( accNodes, specId, accCtx ) ->
                    case maybeNode of
                        Just node ->
                            let
                                home =
                                    specHome accCtx.registry specId

                                ( newNode, accCtx1 ) =
                                    wrapNodeCallables home node accCtx
                            in
                            ( Array.push (Just newNode) accNodes, specId + 1, accCtx1 )

                        Nothing ->
                            ( Array.push Nothing accNodes, specId + 1, accCtx )
                )
                ( Array.empty, 0, ctx0 )
                record0.nodes
                |> (\( n, _, c ) -> ( n, c ))
    in
    Mono.MonoGraph { record0 | nodes = newNodes, nextLambdaIndex = finalCtx.lambdaCounter }


wrapNodeCallables :
    IO.Canonical
    -> Mono.MonoNode
    -> GlobalCtx
    -> ( Mono.MonoNode, GlobalCtx )
wrapNodeCallables home node ctx =
    case node of
        Mono.MonoDefine expr tipe ->
            let
                ( callableExpr, ctx1 ) =
                    ensureCallableForNode home expr tipe ctx
            in
            ( Mono.MonoDefine callableExpr tipe, ctx1 )

        Mono.MonoPortIncoming expr tipe ->
            let
                ( callableExpr, ctx1 ) =
                    ensureCallableForNode home expr tipe ctx
            in
            ( Mono.MonoPortIncoming callableExpr tipe, ctx1 )

        Mono.MonoPortOutgoing expr tipe ->
            let
                ( callableExpr, ctx1 ) =
                    ensureCallableForNode home expr tipe ctx
            in
            ( Mono.MonoPortOutgoing callableExpr tipe, ctx1 )

        Mono.MonoTailFunc params body tipe ->
            ( Mono.MonoTailFunc params body tipe, ctx )

        Mono.MonoCycle defs tipe ->
            ( Mono.MonoCycle defs tipe, ctx )

        Mono.MonoCtor shape tipe ->
            ( Mono.MonoCtor shape tipe, ctx )

        Mono.MonoEnum tag tipe ->
            ( Mono.MonoEnum tag tipe, ctx )

        Mono.MonoExtern tipe ->
            ( Mono.MonoExtern tipe, ctx )

        Mono.MonoManagerLeaf leafHome tipe ->
            ( Mono.MonoManagerLeaf leafHome tipe, ctx )



-- NORMALIZE CASE/IF ABI (GRAPH-LEVEL)
-- CALL STAGING ANNOTATION


{-| Phase: Annotate all MonoCall nodes with precomputed staging metadata.
After this phase, MLIR codegen can use CallInfo directly without
recomputing call models or stage arities.
-}
annotateCallStaging : Set String -> Mono.MonoGraph -> Mono.MonoGraph
annotateCallStaging dynamicSlots graph =
    let
        (Mono.MonoGraph record) =
            graph

        env =
            emptyCallEnv dynamicSlots

        newNodes =
            Array.indexedMap
                (\nodeId -> Maybe.map (annotateNodeCalls graph nodeId env))
                record.nodes
    in
    Mono.MonoGraph { record | nodes = newNodes }


annotateNodeCalls : Mono.MonoGraph -> Int -> CallEnv -> Mono.MonoNode -> Mono.MonoNode
annotateNodeCalls graph nodeId env node =
    case node of
        Mono.MonoDefine expr tipe ->
            Mono.MonoDefine (annotateExprCalls graph env expr) tipe

        Mono.MonoTailFunc params body tipe ->
            let
                paramSlotKeys =
                    params
                        |> List.indexedMap
                            (\index ( name, ty ) ->
                                if Mono.isFunctionType ty then
                                    Just
                                        ( name
                                        , "P:" ++ String.fromInt nodeId ++ ":" ++ String.fromInt index
                                        )

                                else
                                    Nothing
                            )
                        |> List.filterMap identity
                        |> Dict.fromList

                envWithParams =
                    { env | paramSlotKeys = paramSlotKeys }
            in
            Mono.MonoTailFunc params (annotateExprCalls graph envWithParams body) tipe

        Mono.MonoPortIncoming expr tipe ->
            Mono.MonoPortIncoming (annotateExprCalls graph env expr) tipe

        Mono.MonoPortOutgoing expr tipe ->
            Mono.MonoPortOutgoing (annotateExprCalls graph env expr) tipe

        Mono.MonoCycle defs tipe ->
            let
                newDefs =
                    List.map
                        (\( name, e ) -> ( name, annotateExprCalls graph env e ))
                        defs
            in
            Mono.MonoCycle newDefs tipe

        -- Constructors, enums, externs contain no expressions
        _ ->
            node


annotateExprCalls : Mono.MonoGraph -> CallEnv -> Mono.MonoExpr -> Mono.MonoExpr
annotateExprCalls graph env expr =
    let
        recurse =
            annotateExprCalls graph env
    in
    case expr of
        -- Special case: MonoLet needs proper CallEnv scoping
        Mono.MonoLet def body tipe ->
            let
                ( def1, env1 ) =
                    annotateDefCalls graph env def

                body1 =
                    annotateExprCalls graph env1 body
            in
            Mono.MonoLet def1 body1 tipe

        -- MonoCall: annotate with call info after recursing on children.
        -- If the call already has a non-default CallInfo (e.g., pre-computed by
        -- buildNestedCallsGO for wrapper calls), keep it rather than re-deriving.
        Mono.MonoCall region func args resultType existingCallInfo ->
            let
                newFunc =
                    recurse func

                newArgs =
                    List.map recurse args

                callInfo =
                    if not (List.isEmpty existingCallInfo.stageArities) then
                        -- Pre-computed CallInfo (e.g., from buildNestedCalls in wrappers)
                        existingCallInfo

                    else
                        computeCallInfo graph env newFunc newArgs resultType
            in
            Mono.MonoCall region newFunc newArgs resultType callInfo

        -- MonoCase: recurse into decider and jumps
        Mono.MonoCase label scrutinee decider jumps resultType ->
            let
                newDecider =
                    annotateDeciderCalls graph env decider

                newJumps =
                    List.map (\( i, e ) -> ( i, recurse e )) jumps
            in
            Mono.MonoCase label scrutinee newDecider newJumps resultType

        -- MonoIf: recurse into branches and final
        Mono.MonoIf branches final resultType ->
            let
                newBranches =
                    List.map (\( c, t ) -> ( recurse c, recurse t )) branches

                newFinal =
                    recurse final
            in
            Mono.MonoIf newBranches newFinal resultType

        -- MonoClosure: recurse into captures and body.
        -- Populate varSourceArity for captured variables so that calls
        -- to captured closures inside the body use correct arity.
        Mono.MonoClosure info body closureType ->
            let
                newCaptures =
                    List.map (\( n, e, t ) -> ( n, annotateExprCalls graph env e, t )) info.captures

                -- Add capture arities to env for the body
                envWithCaptures =
                    List.foldl
                        (\( name, captureExpr, _ ) envAcc ->
                            case sourceArityForExpr graph envAcc captureExpr of
                                Just arity ->
                                    { envAcc
                                        | varSourceArity =
                                            Dict.insert name arity envAcc.varSourceArity
                                    }

                                Nothing ->
                                    envAcc
                        )
                        env
                        newCaptures

                newBody =
                    annotateExprCalls graph envWithCaptures body
            in
            Mono.MonoClosure { info | captures = newCaptures } newBody closureType

        -- MonoTailCall: recurse into args
        Mono.MonoTailCall name args resultType ->
            let
                newArgs =
                    List.map (\( n, e ) -> ( n, recurse e )) args
            in
            Mono.MonoTailCall name newArgs resultType

        -- MonoDestruct: recurse into inner
        Mono.MonoDestruct path inner resultType ->
            Mono.MonoDestruct path (recurse inner) resultType

        -- MonoList: recurse into items
        Mono.MonoList region items resultType ->
            Mono.MonoList region (List.map recurse items) resultType

        -- MonoRecordCreate: recurse into fields
        Mono.MonoRecordCreate fields resultType ->
            let
                newFields =
                    List.map (\( n, e ) -> ( n, recurse e )) fields
            in
            Mono.MonoRecordCreate newFields resultType

        -- MonoRecordAccess: recurse into inner
        Mono.MonoRecordAccess inner field resultType ->
            Mono.MonoRecordAccess (recurse inner) field resultType

        -- MonoRecordUpdate: recurse into record and updates
        Mono.MonoRecordUpdate record updates resultType ->
            let
                newRecord =
                    recurse record

                newUpdates =
                    List.map (\( n, e ) -> ( n, recurse e )) updates
            in
            Mono.MonoRecordUpdate newRecord newUpdates resultType

        -- MonoTupleCreate: recurse into elements
        Mono.MonoTupleCreate region elements resultType ->
            Mono.MonoTupleCreate region (List.map recurse elements) resultType

        -- Leaf expressions: no recursion needed
        Mono.MonoLiteral _ _ ->
            expr

        Mono.MonoVarLocal _ _ ->
            expr

        Mono.MonoVarGlobal _ _ _ ->
            expr

        Mono.MonoVarKernel _ _ _ _ ->
            expr

        Mono.MonoUnit ->
            expr


{-| Annotate calls in a definition and propagate call model to CallEnv.
This replaces MLIR's Ctx.lookupVarCallModel logic for local aliases.
-}
annotateDefCalls :
    Mono.MonoGraph
    -> CallEnv
    -> Mono.MonoDef
    -> ( Mono.MonoDef, CallEnv )
annotateDefCalls graph env def =
    case def of
        Mono.MonoDef name bound ->
            let
                bound1 =
                    annotateExprCalls graph env bound

                maybeModel =
                    callModelForExpr graph env bound1

                -- Extract source arity from the bound expression
                maybeSourceArity =
                    sourceArityForExpr graph env bound1

                env1 =
                    case maybeModel of
                        Just model ->
                            { env
                                | varCallModel =
                                    Dict.insert name model env.varCallModel
                            }

                        Nothing ->
                            env

                env2 =
                    case maybeSourceArity of
                        Just arity ->
                            { env1
                                | varSourceArity =
                                    Dict.insert name arity env1.varSourceArity
                            }

                        Nothing ->
                            env1
            in
            ( Mono.MonoDef name bound1, env2 )

        Mono.MonoTailDef name params bound ->
            -- Tail defs are also referenced by MonoVarLocal for the initial
            -- (non-tail) entry call. Track their source arity so that
            -- sourceArityForCallee returns the correct param count.
            let
                tailArity =
                    List.length params

                env1 =
                    { env
                        | varSourceArity =
                            Dict.insert name tailArity env.varSourceArity
                    }
            in
            ( Mono.MonoTailDef name params (annotateExprCalls graph env1 bound), env1 )


annotateDeciderCalls : Mono.MonoGraph -> CallEnv -> Mono.Decider Mono.MonoChoice -> Mono.Decider Mono.MonoChoice
annotateDeciderCalls graph env decider =
    case decider of
        Mono.Leaf choice ->
            Mono.Leaf (annotateChoiceCalls graph env choice)

        Mono.Chain edges success failure ->
            Mono.Chain edges
                (annotateDeciderCalls graph env success)
                (annotateDeciderCalls graph env failure)

        Mono.FanOut path edges fallback ->
            Mono.FanOut path
                (List.map (\( test, d ) -> ( test, annotateDeciderCalls graph env d )) edges)
                (annotateDeciderCalls graph env fallback)


annotateChoiceCalls : Mono.MonoGraph -> CallEnv -> Mono.MonoChoice -> Mono.MonoChoice
annotateChoiceCalls graph env choice =
    case choice of
        Mono.Inline expr ->
            Mono.Inline (annotateExprCalls graph env expr)

        Mono.Jump i ->
            Mono.Jump i


{-| Determine call model for an expression.
Mirrors MLIR's Expr.callModelForExpr but operates on MonoGraph.
-}
callModelForExpr : Mono.MonoGraph -> CallEnv -> Mono.MonoExpr -> Maybe Mono.CallModel
callModelForExpr (Mono.MonoGraph { nodes }) env expr =
    case expr of
        Mono.MonoVarGlobal _ specId _ ->
            case Array.get specId nodes |> Maybe.andThen identity of
                Just (Mono.MonoExtern _) ->
                    Just Mono.FlattenedExternal

                Just (Mono.MonoManagerLeaf _ _) ->
                    Just Mono.FlattenedExternal

                Just (Mono.MonoCtor _ _) ->
                    Just Mono.FlattenedExternal

                Just (Mono.MonoEnum _ _) ->
                    Just Mono.FlattenedExternal

                _ ->
                    Just Mono.StageCurried

        Mono.MonoVarKernel _ _ _ _ ->
            Just Mono.FlattenedExternal

        Mono.MonoVarLocal name _ ->
            Dict.get name env.varCallModel

        Mono.MonoClosure _ _ _ ->
            Just Mono.StageCurried

        _ ->
            Nothing


{-| Get call model for a callee, defaulting to StageCurried.
-}
callModelForCallee : Mono.MonoGraph -> CallEnv -> Mono.MonoExpr -> Mono.CallModel
callModelForCallee graph env funcExpr =
    case callModelForExpr graph env funcExpr of
        Just model ->
            model

        Nothing ->
            -- Default: user closures / expressions use StageCurried model
            Mono.StageCurried


{-| Get the source arity for an expression (the papCreate arity).
This is the closure's actual param count, which may differ from type-derived arities.
Uses the same logic as Context.extractNodeSignature to ensure consistency with codegen.
-}
sourceArityForExpr : Mono.MonoGraph -> CallEnv -> Mono.MonoExpr -> Maybe Int
sourceArityForExpr graph env expr =
    let
        (Mono.MonoGraph { nodes }) =
            graph
    in
    case expr of
        Mono.MonoVarGlobal _ specId _ ->
            -- Look up the node to get its closure's param count
            -- Match the exact logic of extractNodeSignature in Context.elm
            case Array.get specId nodes |> Maybe.andThen identity of
                Just (Mono.MonoDefine innerExpr _) ->
                    -- For defines, check if the expression is a closure
                    case innerExpr of
                        Mono.MonoClosure closureInfo _ _ ->
                            Just (List.length closureInfo.params)

                        _ ->
                            -- Thunk (nullary function) - return 0, codegen calls directly
                            Just 0

                Just (Mono.MonoTailFunc params _ _) ->
                    Just (List.length params)

                Just (Mono.MonoExtern monoType) ->
                    -- Externs use total ABI arity (flattened)
                    Just (List.length (Tuple.first (Mono.decomposeFunctionType monoType)))

                Just (Mono.MonoManagerLeaf _ monoType) ->
                    -- Manager leaf uses total ABI arity (flattened), like extern
                    Just (List.length (Tuple.first (Mono.decomposeFunctionType monoType)))

                Just (Mono.MonoCtor shape _) ->
                    Just (List.length shape.fieldTypes)

                Just (Mono.MonoEnum _ _) ->
                    -- Nullary enum constructor
                    Just 0

                Just (Mono.MonoPortIncoming innerExpr _) ->
                    case innerExpr of
                        Mono.MonoClosure closureInfo _ _ ->
                            Just (List.length closureInfo.params)

                        _ ->
                            Just 0

                Just (Mono.MonoPortOutgoing innerExpr _) ->
                    case innerExpr of
                        Mono.MonoClosure closureInfo _ _ ->
                            Just (List.length closureInfo.params)

                        _ ->
                            Just 0

                Just (Mono.MonoCycle _ _) ->
                    Just 0

                Nothing ->
                    -- Node not found - shouldn't happen
                    Nothing

        Mono.MonoVarKernel _ _ _ kernelType ->
            -- Kernels use total ABI arity (flattened)
            Just (List.length (Tuple.first (Mono.decomposeFunctionType kernelType)))

        Mono.MonoVarLocal name _ ->
            -- Look up from CallEnv
            Dict.get name env.varSourceArity

        Mono.MonoClosure closureInfo _ _ ->
            Just (List.length closureInfo.params)

        Mono.MonoCall _ func args resultType _ ->
            -- For partial applications, compute the result PAP's remaining arity
            -- Result arity = source arity - args applied
            case sourceArityForExpr graph env func of
                Just sourceArity ->
                    let
                        argCount =
                            List.length args

                        resultArity =
                            sourceArity - argCount
                    in
                    if resultArity > 0 then
                        -- Partial application: remaining = source - applied
                        Just resultArity

                    else
                        -- Saturated or over-applied call returning a function.
                        -- Use the body's stage arities and consume any excess args.
                        let
                            excessArgs =
                                argCount - sourceArity

                            -- Consume excess args from the returned closure's stage arities.
                            -- For saturated calls (excessArgs == 0), returns the first stage arity.
                            -- For over-applied calls (excessArgs > 0), subtracts consumed args.
                            consumeFromStages excess stages =
                                case stages of
                                    [] ->
                                        Nothing

                                    stage :: rest ->
                                        if excess >= stage then
                                            consumeFromStages (excess - stage) rest

                                        else
                                            Just (stage - excess)
                        in
                        case closureBodyStageArities graph func of
                            Just stages ->
                                consumeFromStages excessArgs stages

                            Nothing ->
                                -- Nested call or unknown callee.
                                -- Use first-stage arity of result type (stage-curried assumption).
                                case MonoReturnArity.collectStageArities resultType of
                                    firstStage :: _ ->
                                        Just firstStage

                                    [] ->
                                        Nothing

                Nothing ->
                    -- Unknown callee (function parameter): use first-stage arity
                    -- of the result type (consistent with stage-curried model).
                    Just (firstStageArityFromType resultType)

        Mono.MonoLet def body _ ->
            let
                ( _, env1 ) =
                    annotateDefCalls graph env def
            in
            sourceArityForExpr graph env1 body

        _ ->
            Nothing


{-| Get source arity for a callee, with fallback for unknown callees.
For unknown callees (like function parameters), we use first-stage arity
from the type's outermost MFunction layer. This correctly handles
multi-stage function types like MFunction [Int] (MFunction [Int] Int)
where the first-stage arity is 1, not the total arity of 2.

Note: FlattenedExternal callees are handled separately by callModelForCallee
and never reach this function's fallback (they use FlattenedExternal CallInfo).
-}
sourceArityForCallee : Mono.MonoGraph -> CallEnv -> Mono.MonoExpr -> Int
sourceArityForCallee graph env funcExpr =
    case sourceArityForExpr graph env funcExpr of
        Just arity ->
            arity

        Nothing ->
            -- Fallback: use FIRST-STAGE arity for unknown callees (function parameters)
            -- For StageCurried calls, this must be the outermost MFunction's param count,
            -- not the total arity across all stages. The subsequent stages are tracked
            -- separately in remainingStageArities.
            firstStageArityFromType (Mono.typeOf funcExpr)


{-| Get first-stage arity from a function type.
For MFunction [a, b] (MFunction [c] D), returns 2 (just the outermost stage).
For non-function types, returns 0.
-}
firstStageArityFromType : Mono.MonoType -> Int
firstStageArityFromType monoType =
    case monoType of
        Mono.MFunction argTypes _ ->
            List.length argTypes

        _ ->
            0


{-| Count total arity by summing all stage arities.
-}
countTotalArityFromType : Mono.MonoType -> Int
countTotalArityFromType monoType =
    case monoType of
        Mono.MFunction argTypes resultType ->
            List.length argTypes + countTotalArityFromType resultType

        _ ->
            0


{-| Get the remaining stage arities from the closure's body type.
This is used to get the actual staging after GlobalOpt canonicalization.

For a function with params, this extracts the return type's stages from the closure's body
(which may have been canonicalized differently than the declared type).

-}
closureBodyStageArities : Mono.MonoGraph -> Mono.MonoExpr -> Maybe (List Int)
closureBodyStageArities graph expr =
    let
        (Mono.MonoGraph { nodes }) =
            graph

        -- Get stage arities from a node's closure body
        getNodeBodyArities : Mono.MonoNode -> Maybe (List Int)
        getNodeBodyArities node =
            case node of
                Mono.MonoDefine innerExpr _ ->
                    getExprBodyArities innerExpr

                Mono.MonoTailFunc _ bodyExpr _ ->
                    Just (MonoReturnArity.collectStageArities (Mono.typeOf bodyExpr))

                Mono.MonoPortIncoming innerExpr _ ->
                    getExprBodyArities innerExpr

                Mono.MonoPortOutgoing innerExpr _ ->
                    getExprBodyArities innerExpr

                _ ->
                    Nothing

        -- Extract the first Inline expression from a Decider tree.
        -- When all case branches are simple (used once), the optimizer inlines them
        -- directly into Leaf nodes as Inline expressions, leaving the jumps list empty.
        firstInlineExpr : Mono.Decider Mono.MonoChoice -> Maybe Mono.MonoExpr
        firstInlineExpr decider =
            case decider of
                Mono.Leaf (Mono.Inline inlineExpr) ->
                    Just inlineExpr

                Mono.Leaf (Mono.Jump _) ->
                    Nothing

                Mono.Chain _ yes no ->
                    case firstInlineExpr yes of
                        Just e ->
                            Just e

                        Nothing ->
                            firstInlineExpr no

                Mono.FanOut _ tests fallback ->
                    let
                        tryTests ts =
                            case ts of
                                [] ->
                                    firstInlineExpr fallback

                                ( _, d ) :: rest ->
                                    case firstInlineExpr d of
                                        Just e ->
                                            Just e

                                        Nothing ->
                                            tryTests rest
                    in
                    tryTests tests

        -- Try to get closure arity from a case expression, checking both jumps and inline decider leaves
        getClosureArityFromCase : Mono.Decider Mono.MonoChoice -> List ( Int, Mono.MonoExpr ) -> Maybe (List Int)
        getClosureArityFromCase decider jumps =
            case jumps of
                ( _, branchExpr ) :: _ ->
                    getClosureArityFromExpr branchExpr

                [] ->
                    -- Jumps list empty: branches are inlined in the decider tree
                    firstInlineExpr decider
                        |> Maybe.andThen getClosureArityFromExpr

        -- Get stage arities from an expression's body
        getExprBodyArities : Mono.MonoExpr -> Maybe (List Int)
        getExprBodyArities e =
            case e of
                Mono.MonoClosure _ body _ ->
                    -- Check if the closure body is a case/if that returns closures.
                    -- If so, look at the actual closures in branches (after canonicalization)
                    -- rather than using the type, which may have a different staging.
                    case body of
                        Mono.MonoCase _ _ decider jumps _ ->
                            case getClosureArityFromCase decider jumps of
                                Just arities ->
                                    Just arities

                                Nothing ->
                                    Just (MonoReturnArity.collectStageArities (Mono.typeOf body))

                        Mono.MonoIf branches _ _ ->
                            case branches of
                                ( _, thenExpr ) :: _ ->
                                    getClosureArityFromExpr thenExpr

                                [] ->
                                    Just (MonoReturnArity.collectStageArities (Mono.typeOf body))

                        _ ->
                            -- For regular closures, use the body's type
                            Just (MonoReturnArity.collectStageArities (Mono.typeOf body))

                Mono.MonoCase _ _ decider jumps _ ->
                    -- After canonicalization, all branches have the same staging.
                    -- Look at the first jump's closure or inline expression.
                    getClosureArityFromCase decider jumps

                Mono.MonoIf branches _ _ ->
                    -- Look at the first branch's expression for actual staging
                    case branches of
                        ( _, thenExpr ) :: _ ->
                            getClosureArityFromExpr thenExpr

                        [] ->
                            Nothing

                _ ->
                    Nothing

        -- Get the full stage arities from a closure expression (for case/if branches)
        getClosureArityFromExpr : Mono.MonoExpr -> Maybe (List Int)
        getClosureArityFromExpr e =
            case e of
                Mono.MonoClosure closureInfo body _ ->
                    -- First stage arity = this closure's params
                    -- Remaining stages = from body type
                    Just (List.length closureInfo.params :: MonoReturnArity.collectStageArities (Mono.typeOf body))

                _ ->
                    -- Not a closure, fall back
                    Nothing
    in
    case expr of
        Mono.MonoVarGlobal _ specId _ ->
            Array.get specId nodes
                |> Maybe.andThen identity
                |> Maybe.andThen getNodeBodyArities

        Mono.MonoClosure _ body _ ->
            Just (MonoReturnArity.collectStageArities (Mono.typeOf body))

        _ ->
            Nothing


{-| Check if a callee expression is a dynamic staging slot (function parameter
    whose equivalence class has no producer segmentation). Only these callees
    should use CallGenericApply for runtime dispatch.
-}
isDynamicCallee : CallEnv -> Mono.MonoExpr -> Bool
isDynamicCallee env funcExpr =
    case funcExpr of
        Mono.MonoVarLocal name monoType ->
            case Dict.get name env.paramSlotKeys of
                Just slotKey ->
                    Set.member slotKey env.dynamicSlots
                        && Mono.isFunctionType monoType

                Nothing ->
                    False

        _ ->
            False


{-| Compute CallInfo for a MonoCall based on callee and arguments.
This is the core logic that moves staging decisions into GlobalOpt.
-}
computeCallInfo :
    Mono.MonoGraph
    -> CallEnv
    -> Mono.MonoExpr
    -> List Mono.MonoExpr
    -> Mono.MonoType
    -> Mono.CallInfo
computeCallInfo graph env func args _ =
    let
        callModel =
            callModelForCallee graph env func
    in
    case callModel of
        Mono.FlattenedExternal ->
            -- No staged-curried logic needed; existing MLIR code treats
            -- extern partial vs saturated based on resultType alone.
            { callModel = Mono.FlattenedExternal
            , stageArities = []
            , isSingleStageSaturated = False
            , initialRemaining = 0
            , remainingStageArities = []
            , closureKind = Nothing
            , captureAbi = Nothing
            , callKind = Mono.CallDirectFlat
            }

        Mono.StageCurried ->
            let
                funcType : Mono.MonoType
                funcType =
                    Mono.typeOf func

                -- Full stage segmentation for the function type
                stageAritiesFull : List Int
                stageAritiesFull =
                    MonoReturnArity.collectStageArities funcType

                -- Source arity: the actual closure's param count (matches papCreate arity)
                -- For known callees (globals, let-bindings), this is the closure's param count.
                -- For unknown callees (function parameters), this is the first-stage arity
                -- from the type. This is what CGEN_052 requires for papExtend's remaining_arity.
                sourceArity : Int
                sourceArity =
                    sourceArityForCallee graph env func

                argCount : Int
                argCount =
                    List.length args

                -- Single-stage saturated: all args provided in one call, fitting the closure's params
                -- True when argCount exactly equals sourceArity (first-stage arity)
                isSingleStageSaturated : Bool
                isSingleStageSaturated =
                    argCount == sourceArity && sourceArity > 0

                -- Stage arity at this call site (for applyByStages sourceRemaining)
                -- CGEN_052: must match the source PAP's remaining_arity
                initialRemaining : Int
                initialRemaining =
                    sourceArity

                -- Stage arities for subsequent stages (for applyByStages)
                -- IMPORTANT: Use the closure body's type (which reflects GlobalOpt canonicalization)
                -- rather than the declared return type, because case expressions may have
                -- different staging after canonicalization (e.g., [2] vs [1,1])
                remainingStageArities : List Int
                remainingStageArities =
                    let
                        bodyArities =
                            closureBodyStageArities graph func
                    in
                    case bodyArities of
                        Just arities ->
                            -- Known callee: use actual body's stage arities
                            arities

                        Nothing ->
                            -- Unknown callee (e.g., function parameter):
                            -- No body arities available. Use empty list so that
                            -- applyByStages correctly detects saturation when
                            -- all args fill the first stage.
                            []

                -- Determine call kind: use CallGenericApply for dynamic callees
                -- (function parameters whose staging slot has no producer segmentation),
                -- otherwise use CallDirectKnownSegmentation for typed closure dispatch.
                callKind : Mono.CallKind
                callKind =
                    if isDynamicCallee env func then
                        Mono.CallGenericApply

                    else
                        Mono.CallDirectKnownSegmentation
            in
            { callModel = Mono.StageCurried
            , stageArities = stageAritiesFull
            , isSingleStageSaturated = isSingleStageSaturated
            , initialRemaining = initialRemaining
            , remainingStageArities = remainingStageArities
            , closureKind = Nothing
            , captureAbi = Nothing
            , callKind = callKind
            }
