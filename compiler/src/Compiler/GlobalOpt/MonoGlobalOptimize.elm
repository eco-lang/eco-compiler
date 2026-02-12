module Compiler.GlobalOpt.MonoGlobalOptimize exposing (globalOptimize)

{-| Global optimization pass that runs after monomorphization but before MLIR codegen.

This phase:

1.  Ensures top-level function-typed values (globals/ports) are represented as closures before staging
2.  Canonicalizes closure/tail-func types by flattening to match param counts (GOPT\_001)
3.  Normalizes ABI for case/if expressions with function-typed results (GOPT\_003)
4.  Annotates call staging metadata (call model, stage arities, etc.)

Monomorphize is staging-agnostic - it preserves curried TLambda structure from TypeSubst.
GlobalOpt owns all staging/ABI decisions and canonicalizes the types to match param counts.

Note: GOPT\_001 (closure params == stage arity) is verified by TestLogic.Generate.MonoFunctionArity,
not at runtime. The compiler trusts that canonicalizeClosureStaging produces correct output.

@docs globalOptimize

-}

import Compiler.AST.Monomorphized as Mono
import Compiler.AST.TypeEnv as TypeEnv
import Compiler.Data.Name exposing (Name)
import Compiler.GlobalOpt.AbiCloning as AbiCloning
import Compiler.GlobalOpt.MonoInlineSimplify as MonoInlineSimplify
import Compiler.GlobalOpt.MonoReturnArity as MonoReturnArity
import Compiler.GlobalOpt.MonoTraverse as Traverse
import Compiler.GlobalOpt.Staging as Staging
import Compiler.Monomorphize.Closure as Closure
import Compiler.Reporting.Annotation as A
import Data.Map as Dict exposing (Dict)
import System.TypeCheck.IO as IO



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
    , lambdaCounter = maxLambdaIndexInGraph (Mono.MonoGraph record) + 1
    }


freshLambdaId : IO.Canonical -> GlobalCtx -> ( Mono.LambdaId, GlobalCtx )
freshLambdaId home ctx =
    ( Mono.AnonymousLambda home ctx.lambdaCounter
    , { ctx | lambdaCounter = ctx.lambdaCounter + 1 }
    )



-- CALL STAGING ENVIRONMENT


{-| Environment for tracking call models and source arities of local variables.
This replaces MLIR's Ctx.lookupVarCallModel and Ctx.lookupVarArity logic.
-}
type alias CallEnv =
    { varCallModel : Dict String Name Mono.CallModel
    , varSourceArity : Dict String Name Int
    }


emptyCallEnv : CallEnv
emptyCallEnv =
    { varCallModel = Dict.empty
    , varSourceArity = Dict.empty
    }



-- MAIN ENTRY POINT


{-| Run global optimization passes on a monomorphized program graph.

New structure using global staging algorithm:

1.  Phase 0: Inlining and simplification
2.  Phase 1+2: Staging analysis + graph rewrite (wrappers + types)
3.  Phase 3: Validate closure staging invariants (GOPT\_001, GOPT\_003)
4.  Phase 4: Annotate call staging metadata using staging solution

-}
globalOptimize : TypeEnv.GlobalTypeEnv -> Mono.MonoGraph -> Mono.MonoGraph
globalOptimize typeEnv graph0 =
    let
        -- Phase 0: Inlining and simplification (runs first so subsequent phases
        -- can canonicalize/normalize any new closures or case/if expressions)
        ( graph0a, _ ) =
            MonoInlineSimplify.optimize typeEnv graph0

        -- Phase 0.5: Wrap top-level function-typed values in closures
        -- (alias wrappers for globals/kernels, general closures for other exprs).
        graph0b =
            wrapTopLevelCallables graph0a

        -- Phase 1+2: Staging analysis + graph rewrite (wrappers + types)
        ( _, graph1 ) =
            Staging.analyzeAndSolveStaging typeEnv graph0b

        -- Phase 3: Validate closure staging invariants (GOPT_001, GOPT_003)
        graph2 =
            Staging.validateClosureStaging graph1

        -- Phase 3.5: ABI Cloning - ensure homogeneous closure parameters
        -- Clones functions when a closure-typed parameter receives different
        -- capture ABIs at different call sites.
        graph2a =
            AbiCloning.abiCloningPass graph2

        -- Phase 4: Annotate call staging metadata using CallEnv + computeCallInfo
        -- This uses the local annotateCallStaging which has the correct PAP arity
        -- semantics via sourceArityForCallee and closureBodyStageArities.
        -- Note: stagingSolution is unused here since all staging-dependent rewrites
        -- were applied in Phase 1+2 by Rewriter.applyStagingSolution.
        graph3 =
            annotateCallStaging graph2a
    in
    graph3



-- LAMBDA INDEX SCANNING


maxLambdaIndexInGraph : Mono.MonoGraph -> Int
maxLambdaIndexInGraph (Mono.MonoGraph { nodes }) =
    Dict.foldl compare
        (\_ node acc -> max acc (maxLambdaIndexInNode node))
        0
        nodes


maxLambdaIndexInNode : Mono.MonoNode -> Int
maxLambdaIndexInNode node =
    case node of
        Mono.MonoDefine expr _ ->
            maxLambdaIndexInExpr expr

        Mono.MonoTailFunc _ expr _ ->
            maxLambdaIndexInExpr expr

        Mono.MonoPortIncoming expr _ ->
            maxLambdaIndexInExpr expr

        Mono.MonoPortOutgoing expr _ ->
            maxLambdaIndexInExpr expr

        Mono.MonoCycle defs _ ->
            List.foldl (\( _, e ) acc -> max acc (maxLambdaIndexInExpr e)) 0 defs

        Mono.MonoCtor _ _ ->
            0

        Mono.MonoEnum _ _ ->
            0

        Mono.MonoExtern _ ->
            0


{-| Extract lambda index from closure, or 0 for other expressions.
-}
lambdaIndexOf : Mono.MonoExpr -> Int
lambdaIndexOf expr =
    case expr of
        Mono.MonoClosure info _ _ ->
            case info.lambdaId of
                Mono.AnonymousLambda _ i ->
                    i

        _ ->
            0


maxLambdaIndexInExpr : Mono.MonoExpr -> Int
maxLambdaIndexInExpr =
    Traverse.foldExpr (\e acc -> max (lambdaIndexOf e) acc) 0


maxLambdaIndexInDef : Mono.MonoDef -> Int
maxLambdaIndexInDef =
    Traverse.foldDef (\e acc -> max (lambdaIndexOf e) acc) 0


maxLambdaIndexInDecider : Mono.Decider Mono.MonoChoice -> Int
maxLambdaIndexInDecider =
    Traverse.foldDecider (\e acc -> max (lambdaIndexOf e) acc) 0



-- ============================================================================
-- CLOSURE STAGING CANONICALIZATION (GOPT_001)
-- ============================================================================


{-| Canonicalize closure and tail-func types by flattening to match param counts.

After this pass, for all MonoClosure and MonoTailFunc nodes:
length(closureInfo.params) == length(args of MFunction type)

Monomorphize produces closures where:

  - params come from TOpt.Function (flat list)
  - type comes from TypeSubst.applySubst (curried TLambda chain)

Example transformation:
Before: params=[(x,Int),(y,Int)], type=MFunction [Int] (MFunction [Int] Int)
After: params=[(x,Int),(y,Int)], type=MFunction [Int, Int] Int

This is the GOPT\_001 canonicalization step.

-}
canonicalizeClosureStaging : Mono.MonoGraph -> Mono.MonoGraph
canonicalizeClosureStaging (Mono.MonoGraph data) =
    Mono.MonoGraph
        { data
            | nodes = Dict.map (\_ node -> canonicalizeNode node) data.nodes
        }


{-| Canonicalize a single MonoNode.
-}
canonicalizeNode : Mono.MonoNode -> Mono.MonoNode
canonicalizeNode node =
    case node of
        Mono.MonoDefine expr monoType ->
            let
                canonExpr =
                    canonicalizeExpr expr

                -- If the expression is a closure, use its canonicalized type
                canonType =
                    case canonExpr of
                        Mono.MonoClosure _ _ closureType ->
                            closureType

                        _ ->
                            monoType
            in
            Mono.MonoDefine canonExpr canonType

        Mono.MonoTailFunc params expr monoType ->
            let
                canonType =
                    flattenTypeToArity (List.length params) monoType
            in
            Mono.MonoTailFunc params (canonicalizeExpr expr) canonType

        Mono.MonoPortIncoming expr monoType ->
            Mono.MonoPortIncoming (canonicalizeExpr expr) monoType

        Mono.MonoPortOutgoing expr monoType ->
            Mono.MonoPortOutgoing (canonicalizeExpr expr) monoType

        Mono.MonoCycle defs monoType ->
            Mono.MonoCycle
                (List.map (\( name, e ) -> ( name, canonicalizeExpr e )) defs)
                monoType

        Mono.MonoCtor _ _ ->
            node

        Mono.MonoEnum _ _ ->
            node

        Mono.MonoExtern _ ->
            node


{-| Canonicalize closure types by flattening to match param counts.
Only closures need special handling - the type is flattened to match the param count.
-}
canonicalizeClosureType : Mono.MonoExpr -> Mono.MonoExpr
canonicalizeClosureType expr =
    case expr of
        Mono.MonoClosure closureInfo body closureType ->
            let
                paramCount =
                    List.length closureInfo.params

                canonType =
                    flattenTypeToArity paramCount closureType
            in
            Mono.MonoClosure closureInfo body canonType

        _ ->
            expr


{-| Recursively canonicalize expressions, flattening closure types.
-}
canonicalizeExpr : Mono.MonoExpr -> Mono.MonoExpr
canonicalizeExpr =
    Traverse.mapExpr canonicalizeClosureType


{-| Canonicalize a definition.
-}
canonicalizeDef : Mono.MonoDef -> Mono.MonoDef
canonicalizeDef =
    Traverse.mapDef canonicalizeClosureType


{-| Canonicalize a decider tree.
-}
canonicalizeDecider : Mono.Decider Mono.MonoChoice -> Mono.Decider Mono.MonoChoice
canonicalizeDecider =
    Traverse.mapDecider canonicalizeClosureType


{-| Canonicalize a choice (inline expression or jump).
-}
canonicalizeChoice : Mono.MonoChoice -> Mono.MonoChoice
canonicalizeChoice =
    Traverse.mapChoice canonicalizeClosureType


{-| Flatten a function type to have exactly `targetArity` arguments in the outer MFunction.

Example:
flattenTypeToArity 2 (MFunction [a] (MFunction [b] c))
=> MFunction [a, b] c

If the type has more args than targetArity, nest the rest.
If the type has fewer args than targetArity, this is a GOPT\_001 violation (bug).

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
        -- Non-function type being used where function expected
        -- This can happen for thunks or partially applied values
        -- Return as-is and let validation catch it if it's a real problem
        monoType

    else
        -- Fewer args than params - this is a GOPT_001 violation
        Debug.todo
            ("GOPT_001 canonicalization error: type has "
                ++ String.fromInt (List.length allArgs)
                ++ " args but closure has "
                ++ String.fromInt targetArity
                ++ " params. Type: "
                ++ Debug.toString monoType
            )


{-| Split a list at the given index.
-}
splitAt : Int -> List a -> ( List a, List a )
splitAt n xs =
    ( List.take n xs, List.drop n xs )



-- SPEC HOME LOOKUP


specHome : Mono.SpecializationRegistry -> Int -> IO.Canonical
specHome registry specId =
    case Dict.get identity specId registry.reverseMapping of
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
            Dict.fromList identity monoJumps

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
                            case Dict.get identity idx jumpDict of
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

        paramExprs =
            List.map (\( name, ty ) -> Mono.MonoVarLocal name ty) params

        buildCalls : Mono.MonoExpr -> List Mono.MonoExpr -> List Int -> Mono.MonoExpr
        buildCalls currentCallee remainingArgs segLengths =
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

                        callExpr =
                            Mono.MonoCall region currentCallee nowArgs resultType Mono.defaultCallInfo
                    in
                    buildCalls callExpr laterArgs restSeg
    in
    buildCalls calleeExpr paramExprs srcSeg



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

        ( newNodes, _ ) =
            Dict.foldl compare
                (\specId node ( accNodes, accCtx ) ->
                    let
                        home =
                            specHome accCtx.registry specId

                        ( newNode, accCtx1 ) =
                            wrapNodeCallables home node accCtx
                    in
                    ( Dict.insert identity specId newNode accNodes, accCtx1 )
                )
                ( Dict.empty, ctx0 )
                record0.nodes
    in
    Mono.MonoGraph { record0 | nodes = newNodes }


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



-- NORMALIZE CASE/IF ABI (GRAPH-LEVEL)


normalizeCaseIfAbi : Mono.MonoGraph -> Mono.MonoGraph
normalizeCaseIfAbi (Mono.MonoGraph record0) =
    let
        ctx0 =
            initGlobalCtx (Mono.MonoGraph record0)

        ( newNodes, _ ) =
            Dict.foldl compare
                (\specId node ( accNodes, accCtx ) ->
                    let
                        home =
                            specHome accCtx.registry specId

                        ( newNode, accCtx1 ) =
                            rewriteNodeForAbi home node accCtx
                    in
                    ( Dict.insert identity specId newNode accNodes, accCtx1 )
                )
                ( Dict.empty, ctx0 )
                record0.nodes
    in
    Mono.MonoGraph { record0 | nodes = newNodes }


rewriteNodeForAbi : IO.Canonical -> Mono.MonoNode -> GlobalCtx -> ( Mono.MonoNode, GlobalCtx )
rewriteNodeForAbi home node ctx =
    case node of
        Mono.MonoDefine expr tipe ->
            let
                -- Ensure function-typed expressions are callable closures (Phase 1 of plan)
                ( callableExpr, ctx0 ) =
                    ensureCallableForNode home expr tipe ctx

                ( newExpr, ctx1 ) =
                    rewriteExprForAbi home callableExpr ctx0
            in
            ( Mono.MonoDefine newExpr tipe, ctx1 )

        Mono.MonoTailFunc params body tipe ->
            let
                ( newBody, ctx1 ) =
                    rewriteExprForAbi home body ctx
            in
            ( Mono.MonoTailFunc params newBody tipe, ctx1 )

        Mono.MonoPortIncoming expr tipe ->
            let
                -- Ensure function-typed expressions are callable closures
                ( callableExpr, ctx0 ) =
                    ensureCallableForNode home expr tipe ctx

                ( newExpr, ctx1 ) =
                    rewriteExprForAbi home callableExpr ctx0
            in
            ( Mono.MonoPortIncoming newExpr tipe, ctx1 )

        Mono.MonoPortOutgoing expr tipe ->
            let
                -- Ensure function-typed expressions are callable closures
                ( callableExpr, ctx0 ) =
                    ensureCallableForNode home expr tipe ctx

                ( newExpr, ctx1 ) =
                    rewriteExprForAbi home callableExpr ctx0
            in
            ( Mono.MonoPortOutgoing newExpr tipe, ctx1 )

        Mono.MonoCycle defs tipe ->
            let
                ( newDefs, ctx1 ) =
                    List.foldr
                        (\( n, e ) ( acc, accCtx ) ->
                            let
                                ( newE, accCtx1 ) =
                                    rewriteExprForAbi home e accCtx
                            in
                            ( ( n, newE ) :: acc, accCtx1 )
                        )
                        ( [], ctx )
                        defs
            in
            ( Mono.MonoCycle newDefs tipe, ctx1 )

        Mono.MonoCtor _ _ ->
            ( node, ctx )

        Mono.MonoEnum _ _ ->
            ( node, ctx )

        Mono.MonoExtern _ ->
            ( node, ctx )



-- CALL STAGING ANNOTATION


{-| Phase: Annotate all MonoCall nodes with precomputed staging metadata.
After this phase, MLIR codegen can use CallInfo directly without
recomputing call models or stage arities.
-}
annotateCallStaging : Mono.MonoGraph -> Mono.MonoGraph
annotateCallStaging graph =
    let
        (Mono.MonoGraph record) =
            graph

        newNodes =
            Dict.map (\_ node -> annotateNodeCalls graph emptyCallEnv node) record.nodes
    in
    Mono.MonoGraph { record | nodes = newNodes }


annotateNodeCalls : Mono.MonoGraph -> CallEnv -> Mono.MonoNode -> Mono.MonoNode
annotateNodeCalls graph env node =
    case node of
        Mono.MonoDefine expr tipe ->
            Mono.MonoDefine (annotateExprCalls graph env expr) tipe

        Mono.MonoTailFunc params body tipe ->
            Mono.MonoTailFunc params (annotateExprCalls graph env body) tipe

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

        -- MonoCall: annotate with call info after recursing on children
        Mono.MonoCall region func args resultType _ ->
            let
                newFunc =
                    recurse func

                newArgs =
                    List.map recurse args

                callInfo =
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

        -- MonoClosure: recurse into captures and body
        Mono.MonoClosure info body closureType ->
            let
                newCaptures =
                    List.map (\( n, e, t ) -> ( n, recurse e, t )) info.captures

                newBody =
                    recurse body
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
                                    Dict.insert identity name model env.varCallModel
                            }

                        Nothing ->
                            env

                env2 =
                    case maybeSourceArity of
                        Just arity ->
                            { env1
                                | varSourceArity =
                                    Dict.insert identity name arity env1.varSourceArity
                            }

                        Nothing ->
                            env1
            in
            ( Mono.MonoDef name bound1, env2 )

        Mono.MonoTailDef name params bound ->
            -- Tail defs are only referenced by MonoTailCall (string name),
            -- not VarLocal, so no callModel mapping is needed.
            ( Mono.MonoTailDef name params (annotateExprCalls graph env bound), env )


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
            case Dict.get identity specId nodes of
                Just (Mono.MonoExtern _) ->
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
            Dict.get identity name env.varCallModel

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
            case Dict.get identity specId nodes of
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
            Dict.get identity name env.varSourceArity

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
                    -- Unknown callee (function parameter): use total arity for flattened externals
                    Just (countTotalArityFromType resultType)

        _ ->
            Nothing


{-| Get source arity for a callee, with fallback for unknown callees.
For unknown callees (like function parameters), we use total arity since
they could be flattened externals that expect all args at once.
-}
sourceArityForCallee : Mono.MonoGraph -> CallEnv -> Mono.MonoExpr -> Int
sourceArityForCallee graph env funcExpr =
    case sourceArityForExpr graph env funcExpr of
        Just arity ->
            arity

        Nothing ->
            -- Fallback: use TOTAL arity for unknown callees (function parameters)
            -- Since they could be flattened externals, we must batch all args.
            countTotalArityFromType (Mono.typeOf funcExpr)


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
            Dict.get identity specId nodes
                |> Maybe.andThen getNodeBodyArities

        Mono.MonoClosure _ body _ ->
            Just (MonoReturnArity.collectStageArities (Mono.typeOf body))

        _ ->
            Nothing


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
computeCallInfo graph env func args resultType =
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
            , dispatchMode = Nothing
            , captureAbi = Nothing
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
                -- This is what CGEN_052 requires for papExtend's remaining_arity
                sourceArity : Int
                sourceArity =
                    sourceArityForCallee graph env func

                argCount : Int
                argCount =
                    List.length args

                -- Single-stage saturated: all args provided in one call, fitting the closure's params
                -- This uses sourceArity (closure's actual param count) not type-derived arity
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
                            -- Since we use total arity for sourceArity (treating it as flattened),
                            -- remainingStageArities should be empty (no subsequent stages).
                            -- This ensures isSaturatedCall is true when all args are consumed.
                            []
            in
            { callModel = Mono.StageCurried
            , stageArities = stageAritiesFull
            , isSingleStageSaturated = isSingleStageSaturated
            , initialRemaining = initialRemaining
            , remainingStageArities = remainingStageArities
            , closureKind = Nothing
            , dispatchMode = Nothing
            , captureAbi = Nothing
            }
