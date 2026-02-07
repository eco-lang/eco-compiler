module Compiler.GlobalOpt.MonoGlobalOptimize exposing (globalOptimize)

{-| Global optimization pass that runs after monomorphization but before MLIR codegen.

This phase:

1.  Canonicalizes closure/tail-func types by flattening to match param counts (GOPT\_016)
2.  Normalizes ABI for case/if expressions with function-typed results (GOPT\_018)
3.  Validates closure staging invariants
4.  Annotates returned closure arities

Monomorphize is staging-agnostic - it preserves curried TLambda structure from TypeSubst.
GlobalOpt owns all staging/ABI decisions and canonicalizes the types to match param counts.

@docs globalOptimize

-}

import Compiler.AST.Monomorphized as Mono
import Compiler.AST.TypeEnv as TypeEnv
import Compiler.Data.Name exposing (Name)
import Compiler.GlobalOpt.MonoInlineSimplify as MonoInlineSimplify
import Compiler.GlobalOpt.MonoReturnArity as MonoReturnArity
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
-}
globalOptimize : TypeEnv.GlobalTypeEnv -> Mono.MonoGraph -> Mono.MonoGraph
globalOptimize typeEnv graph0 =
    let
        -- Phase 1: Canonicalize closure/tail-func types (GOPT_001 fix)
        -- Flatten types to match param counts: MFunction [a] (MFunction [b] c) -> MFunction [a,b] c
        graph1 =
            canonicalizeClosureStaging graph0

        -- Phase 2: ABI normalization (case/if result types, wrapper generation)
        graph2 =
            normalizeCaseIfAbi graph1

        -- Phase 3: Closure staging invariant validation (should pass after phases 1-2)
        graph3 =
            validateClosureStaging graph2

        -- Phase 4: Annotate call staging metadata (call model, stage arities, etc.)
        graph4 =
            annotateCallStaging graph3

        -- Phase 5: Inlining and DCE (call as black box)
        -- ( graph5, _ ) =
        --     MonoInlineSimplify.optimize mode typeEnv graph4
    in
    graph4



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


maxLambdaIndexInExpr : Mono.MonoExpr -> Int
maxLambdaIndexInExpr expr =
    case expr of
        Mono.MonoLiteral _ _ ->
            0

        Mono.MonoVarLocal _ _ ->
            0

        Mono.MonoVarGlobal _ _ _ ->
            0

        Mono.MonoVarKernel _ _ _ _ ->
            0

        Mono.MonoUnit ->
            0

        Mono.MonoList _ items _ ->
            List.foldl (\e acc -> max acc (maxLambdaIndexInExpr e)) 0 items

        Mono.MonoClosure info body _ ->
            let
                idx =
                    case info.lambdaId of
                        Mono.AnonymousLambda _ i ->
                            i
            in
            max idx (maxLambdaIndexInExpr body)

        Mono.MonoCall _ f args _ _ ->
            List.foldl (\e acc -> max acc (maxLambdaIndexInExpr e))
                (maxLambdaIndexInExpr f)
                args

        Mono.MonoTailCall _ args _ ->
            List.foldl (\( _, e ) acc -> max acc (maxLambdaIndexInExpr e)) 0 args

        Mono.MonoIf branches final _ ->
            let
                branchMax =
                    List.foldl
                        (\( cond, then_ ) acc ->
                            max acc (max (maxLambdaIndexInExpr cond) (maxLambdaIndexInExpr then_))
                        )
                        0
                        branches
            in
            max branchMax (maxLambdaIndexInExpr final)

        Mono.MonoLet def body _ ->
            max (maxLambdaIndexInDef def) (maxLambdaIndexInExpr body)

        Mono.MonoDestruct _ inner _ ->
            maxLambdaIndexInExpr inner

        Mono.MonoCase _ _ decider branches _ ->
            let
                decMax =
                    maxLambdaIndexInDecider decider

                branchMax =
                    List.foldl (\( _, e ) acc -> max acc (maxLambdaIndexInExpr e)) 0 branches
            in
            max decMax branchMax

        Mono.MonoRecordCreate fields _ ->
            List.foldl (\( _, e ) acc -> max acc (maxLambdaIndexInExpr e)) 0 fields

        Mono.MonoRecordAccess inner _ _ ->
            maxLambdaIndexInExpr inner

        Mono.MonoRecordUpdate record updates _ ->
            let
                recMax =
                    maxLambdaIndexInExpr record

                updMax =
                    List.foldl (\( _, e ) acc -> max acc (maxLambdaIndexInExpr e)) 0 updates
            in
            max recMax updMax

        Mono.MonoTupleCreate _ elements _ ->
            List.foldl (\e acc -> max acc (maxLambdaIndexInExpr e)) 0 elements


maxLambdaIndexInDef : Mono.MonoDef -> Int
maxLambdaIndexInDef def =
    case def of
        Mono.MonoDef _ bound ->
            maxLambdaIndexInExpr bound

        Mono.MonoTailDef _ _ bound ->
            maxLambdaIndexInExpr bound


maxLambdaIndexInDecider : Mono.Decider Mono.MonoChoice -> Int
maxLambdaIndexInDecider dec =
    case dec of
        Mono.Leaf choice ->
            case choice of
                Mono.Inline expr ->
                    maxLambdaIndexInExpr expr

                Mono.Jump _ ->
                    0

        Mono.Chain _ success failure ->
            max (maxLambdaIndexInDecider success) (maxLambdaIndexInDecider failure)

        Mono.FanOut _ edges fallback ->
            let
                edgeMax =
                    List.foldl (\( _, d ) acc -> max acc (maxLambdaIndexInDecider d)) 0 edges
            in
            max edgeMax (maxLambdaIndexInDecider fallback)



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
  After:  params=[(x,Int),(y,Int)], type=MFunction [Int, Int] Int

This is the GOPT_001 canonicalization step.
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


{-| Recursively canonicalize expressions, flattening closure types.
-}
canonicalizeExpr : Mono.MonoExpr -> Mono.MonoExpr
canonicalizeExpr expr =
    case expr of
        Mono.MonoClosure closureInfo body closureType ->
            let
                paramCount =
                    List.length closureInfo.params

                canonType =
                    flattenTypeToArity paramCount closureType

                canonBody =
                    canonicalizeExpr body

                canonCaptures =
                    List.map (\( n, e, t ) -> ( n, canonicalizeExpr e, t )) closureInfo.captures
            in
            Mono.MonoClosure
                { closureInfo | captures = canonCaptures }
                canonBody
                canonType

        Mono.MonoCall callType fn args resultType callInfo ->
            Mono.MonoCall callType
                (canonicalizeExpr fn)
                (List.map canonicalizeExpr args)
                resultType
                callInfo

        Mono.MonoTailCall specId args resultType ->
            Mono.MonoTailCall specId
                (List.map (\( n, e ) -> ( n, canonicalizeExpr e )) args)
                resultType

        Mono.MonoIf branches final resultType ->
            Mono.MonoIf
                (List.map (\( c, t ) -> ( canonicalizeExpr c, canonicalizeExpr t )) branches)
                (canonicalizeExpr final)
                resultType

        Mono.MonoLet def body resultType ->
            Mono.MonoLet
                (canonicalizeDef def)
                (canonicalizeExpr body)
                resultType

        Mono.MonoCase label scrutinee decider jumps resultType ->
            -- Note: label and scrutinee are Names, not expressions
            Mono.MonoCase label scrutinee
                (canonicalizeDecider decider)
                (List.map (\( i, e ) -> ( i, canonicalizeExpr e )) jumps)
                resultType

        Mono.MonoDestruct path inner resultType ->
            Mono.MonoDestruct path (canonicalizeExpr inner) resultType

        Mono.MonoList region items resultType ->
            Mono.MonoList region (List.map canonicalizeExpr items) resultType

        Mono.MonoRecordCreate fields resultType ->
            Mono.MonoRecordCreate
                (List.map (\( n, e ) -> ( n, canonicalizeExpr e )) fields)
                resultType

        Mono.MonoRecordAccess inner field resultType ->
            Mono.MonoRecordAccess (canonicalizeExpr inner) field resultType

        Mono.MonoRecordUpdate record updates resultType ->
            Mono.MonoRecordUpdate
                (canonicalizeExpr record)
                (List.map (\( n, e ) -> ( n, canonicalizeExpr e )) updates)
                resultType

        Mono.MonoTupleCreate region elements resultType ->
            Mono.MonoTupleCreate region (List.map canonicalizeExpr elements) resultType

        -- Leaf expressions - no sub-expressions to canonicalize
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


{-| Canonicalize a definition.
-}
canonicalizeDef : Mono.MonoDef -> Mono.MonoDef
canonicalizeDef def =
    case def of
        Mono.MonoDef name bound ->
            Mono.MonoDef name (canonicalizeExpr bound)

        Mono.MonoTailDef name params bound ->
            Mono.MonoTailDef name params (canonicalizeExpr bound)


{-| Canonicalize a decider tree.
-}
canonicalizeDecider : Mono.Decider Mono.MonoChoice -> Mono.Decider Mono.MonoChoice
canonicalizeDecider decider =
    case decider of
        Mono.Leaf choice ->
            Mono.Leaf (canonicalizeChoice choice)

        Mono.Chain test success failure ->
            Mono.Chain test
                (canonicalizeDecider success)
                (canonicalizeDecider failure)

        Mono.FanOut path edges fallback ->
            Mono.FanOut path
                (List.map (\( test, d ) -> ( test, canonicalizeDecider d )) edges)
                (canonicalizeDecider fallback)


{-| Canonicalize a choice (inline expression or jump).
-}
canonicalizeChoice : Mono.MonoChoice -> Mono.MonoChoice
canonicalizeChoice choice =
    case choice of
        Mono.Inline expr ->
            Mono.Inline (canonicalizeExpr expr)

        Mono.Jump idx ->
            Mono.Jump idx


{-| Flatten a function type to have exactly `targetArity` arguments in the outer MFunction.

Example:
    flattenTypeToArity 2 (MFunction [a] (MFunction [b] c))
    => MFunction [a, b] c

If the type has more args than targetArity, nest the rest.
If the type has fewer args than targetArity, this is a GOPT_001 violation (bug).
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

        -- GOPT_003 defensive check: total arities must match
        _ =
            if List.sum srcSeg /= List.sum targetSeg then
                Debug.todo
                    ("GOPT_003: branch total arity mismatch: src="
                        ++ Debug.toString srcSeg
                        ++ ", target="
                        ++ Debug.toString targetSeg
                    )

            else
                ()
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
                                }
                        in
                        ( Mono.MonoClosure closureInfo innerBody remainingType, ctx2 )
        in
        buildStages targetType [] ctx0



-- REWRITE EXPR FOR ABI (COMPLETE TRAVERSAL)


rewriteExprForAbi : IO.Canonical -> Mono.MonoExpr -> GlobalCtx -> ( Mono.MonoExpr, GlobalCtx )
rewriteExprForAbi home expr ctx =
    case expr of
        -- ABI normalization targets
        Mono.MonoCase scrutName scrutTypeName decider branches resultType ->
            rewriteCaseForAbi home scrutName scrutTypeName decider branches resultType ctx

        Mono.MonoIf branches final resultType ->
            rewriteIfForAbi home branches final resultType ctx

        -- Structural recursion (no lambdas in these)
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

        -- Structural recursion (may contain lambdas)
        Mono.MonoList region items tipe ->
            let
                ( newItems, ctx1 ) =
                    List.foldr
                        (\item ( acc, accCtx ) ->
                            let
                                ( newItem, accCtx1 ) =
                                    rewriteExprForAbi home item accCtx
                            in
                            ( newItem :: acc, accCtx1 )
                        )
                        ( [], ctx )
                        items
            in
            ( Mono.MonoList region newItems tipe, ctx1 )

        Mono.MonoClosure info body tipe ->
            let
                ( newBody, ctx1 ) =
                    rewriteExprForAbi home body ctx
            in
            ( Mono.MonoClosure info newBody tipe, ctx1 )

        Mono.MonoCall region f args tipe callInfo ->
            let
                ( newF, ctx1 ) =
                    rewriteExprForAbi home f ctx

                ( newArgs, ctx2 ) =
                    List.foldr
                        (\arg ( acc, accCtx ) ->
                            let
                                ( newArg, accCtx1 ) =
                                    rewriteExprForAbi home arg accCtx
                            in
                            ( newArg :: acc, accCtx1 )
                        )
                        ( [], ctx1 )
                        args
            in
            ( Mono.MonoCall region newF newArgs tipe callInfo, ctx2 )

        Mono.MonoTailCall name args tipe ->
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
            ( Mono.MonoTailCall name newArgs tipe, ctx1 )

        Mono.MonoLet def body tipe ->
            let
                ( newDef, ctx1 ) =
                    rewriteDefForAbi home def ctx

                ( newBody, ctx2 ) =
                    rewriteExprForAbi home body ctx1
            in
            ( Mono.MonoLet newDef newBody tipe, ctx2 )

        Mono.MonoDestruct destructor inner tipe ->
            let
                ( newInner, ctx1 ) =
                    rewriteExprForAbi home inner ctx
            in
            ( Mono.MonoDestruct destructor newInner tipe, ctx1 )

        Mono.MonoRecordCreate fields tipe ->
            let
                ( newFields, ctx1 ) =
                    List.foldr
                        (\( name, field ) ( acc, accCtx ) ->
                            let
                                ( newField, accCtx1 ) =
                                    rewriteExprForAbi home field accCtx
                            in
                            ( ( name, newField ) :: acc, accCtx1 )
                        )
                        ( [], ctx )
                        fields
            in
            ( Mono.MonoRecordCreate newFields tipe, ctx1 )

        Mono.MonoRecordAccess inner name tipe ->
            let
                ( newInner, ctx1 ) =
                    rewriteExprForAbi home inner ctx
            in
            ( Mono.MonoRecordAccess newInner name tipe, ctx1 )

        Mono.MonoRecordUpdate record updates tipe ->
            let
                ( newRecord, ctx1 ) =
                    rewriteExprForAbi home record ctx

                ( newUpdates, ctx2 ) =
                    List.foldr
                        (\( name, e ) ( acc, accCtx ) ->
                            let
                                ( newE, accCtx1 ) =
                                    rewriteExprForAbi home e accCtx
                            in
                            ( ( name, newE ) :: acc, accCtx1 )
                        )
                        ( [], ctx1 )
                        updates
            in
            ( Mono.MonoRecordUpdate newRecord newUpdates tipe, ctx2 )

        Mono.MonoTupleCreate region elements tipe ->
            let
                ( newElements, ctx1 ) =
                    List.foldr
                        (\elem ( acc, accCtx ) ->
                            let
                                ( newElem, accCtx1 ) =
                                    rewriteExprForAbi home elem accCtx
                            in
                            ( newElem :: acc, accCtx1 )
                        )
                        ( [], ctx )
                        elements
            in
            ( Mono.MonoTupleCreate region newElements tipe, ctx1 )


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
    in
    case leafTypes of
        [] ->
            -- No function leaves, just recurse into components
            let
                ( newDecider, ctx1 ) =
                    rewriteDeciderForAbi home decider ctx0

                ( newBranches, ctx2 ) =
                    rewriteBranchesForAbi home branches ctx1
            in
            ( Mono.MonoCase scrutName scrutTypeName newDecider newBranches resultType, ctx2 )

        _ ->
            -- Function leaves: normalize to canonical ABI
            let
                ( canonicalSeg, flatArgs, flatRet ) =
                    Mono.chooseCanonicalSegmentation leafTypes

                canonicalType =
                    Mono.buildSegmentedFunctionType flatArgs flatRet canonicalSeg

                ( newDecider, newBranches, ctx1 ) =
                    rewriteCaseLeavesToAbiGO home canonicalType canonicalSeg decider branches ctx0
            in
            ( Mono.MonoCase scrutName scrutTypeName newDecider newBranches canonicalType, ctx1 )


rewriteCaseLeavesToAbiGO :
    IO.Canonical
    -> Mono.MonoType
    -> Mono.Segmentation
    -> Mono.Decider Mono.MonoChoice
    -> List ( Int, Mono.MonoExpr )
    -> GlobalCtx
    -> ( Mono.Decider Mono.MonoChoice, List ( Int, Mono.MonoExpr ), GlobalCtx )
rewriteCaseLeavesToAbiGO home targetType targetSeg decider jumps ctx0 =
    let
        rewriteLeafExpr : Mono.MonoExpr -> GlobalCtx -> ( Mono.MonoExpr, GlobalCtx )
        rewriteLeafExpr expr ctx =
            case Mono.typeOf expr of
                Mono.MFunction _ _ ->
                    if Mono.segmentLengths (Mono.typeOf expr) == targetSeg then
                        ( expr, ctx )

                    else
                        buildAbiWrapperGO home targetType expr ctx

                _ ->
                    ( expr, ctx )

        rewriteDecider : Mono.Decider Mono.MonoChoice -> GlobalCtx -> ( Mono.Decider Mono.MonoChoice, GlobalCtx )
        rewriteDecider dec ctx =
            case dec of
                Mono.Leaf choice ->
                    case choice of
                        Mono.Inline expr ->
                            let
                                ( newExpr, ctx1 ) =
                                    rewriteLeafExpr expr ctx
                            in
                            ( Mono.Leaf (Mono.Inline newExpr), ctx1 )

                        Mono.Jump _ ->
                            ( dec, ctx )

                Mono.Chain testChain success failure ->
                    let
                        ( newSuccess, ctx1 ) =
                            rewriteDecider success ctx

                        ( newFailure, ctx2 ) =
                            rewriteDecider failure ctx1
                    in
                    ( Mono.Chain testChain newSuccess newFailure, ctx2 )

                Mono.FanOut path edges fallback ->
                    let
                        ( newEdges, ctx1 ) =
                            List.foldr
                                (\( test, d ) ( acc, accCtx ) ->
                                    let
                                        ( newD, accCtx1 ) =
                                            rewriteDecider d accCtx
                                    in
                                    ( ( test, newD ) :: acc, accCtx1 )
                                )
                                ( [], ctx )
                                edges

                        ( newFallback, ctx2 ) =
                            rewriteDecider fallback ctx1
                    in
                    ( Mono.FanOut path newEdges newFallback, ctx2 )

        rewriteJumps : List ( Int, Mono.MonoExpr ) -> GlobalCtx -> ( List ( Int, Mono.MonoExpr ), GlobalCtx )
        rewriteJumps js ctx =
            List.foldr
                (\( idx, expr ) ( acc, accCtx ) ->
                    let
                        ( newExpr, accCtx1 ) =
                            rewriteLeafExpr expr accCtx
                    in
                    ( ( idx, newExpr ) :: acc, accCtx1 )
                )
                ( [], ctx )
                js

        ( newDecider, ctxAfterDecider ) =
            rewriteDecider decider ctx0

        ( newJumps, ctxAfterJumps ) =
            rewriteJumps jumps ctxAfterDecider
    in
    ( newDecider, newJumps, ctxAfterJumps )


rewriteDeciderForAbi :
    IO.Canonical
    -> Mono.Decider Mono.MonoChoice
    -> GlobalCtx
    -> ( Mono.Decider Mono.MonoChoice, GlobalCtx )
rewriteDeciderForAbi home dec ctx =
    case dec of
        Mono.Leaf choice ->
            case choice of
                Mono.Inline expr ->
                    let
                        ( newExpr, ctx1 ) =
                            rewriteExprForAbi home expr ctx
                    in
                    ( Mono.Leaf (Mono.Inline newExpr), ctx1 )

                Mono.Jump _ ->
                    ( dec, ctx )

        Mono.Chain testChain success failure ->
            let
                ( newSuccess, ctx1 ) =
                    rewriteDeciderForAbi home success ctx

                ( newFailure, ctx2 ) =
                    rewriteDeciderForAbi home failure ctx1
            in
            ( Mono.Chain testChain newSuccess newFailure, ctx2 )

        Mono.FanOut path edges fallback ->
            let
                ( newEdges, ctx1 ) =
                    List.foldr
                        (\( test, d ) ( acc, accCtx ) ->
                            let
                                ( newD, accCtx1 ) =
                                    rewriteDeciderForAbi home d accCtx
                            in
                            ( ( test, newD ) :: acc, accCtx1 )
                        )
                        ( [], ctx )
                        edges

                ( newFallback, ctx2 ) =
                    rewriteDeciderForAbi home fallback ctx1
            in
            ( Mono.FanOut path newEdges newFallback, ctx2 )


rewriteBranchesForAbi :
    IO.Canonical
    -> List ( Int, Mono.MonoExpr )
    -> GlobalCtx
    -> ( List ( Int, Mono.MonoExpr ), GlobalCtx )
rewriteBranchesForAbi home branches ctx =
    List.foldr
        (\( idx, expr ) ( acc, accCtx ) ->
            let
                ( newExpr, accCtx1 ) =
                    rewriteExprForAbi home expr accCtx
            in
            ( ( idx, newExpr ) :: acc, accCtx1 )
        )
        ( [], ctx )
        branches



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
        branchResults : List Mono.MonoExpr
        branchResults =
            List.map Tuple.second branches ++ [ final ]

        leafTypes : List Mono.MonoType
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
    in
    case leafTypes of
        [] ->
            -- No function leaves, just recurse structurally
            let
                ( newBranches, ctx1 ) =
                    List.foldr
                        (\( cond, then_ ) ( acc, accCtx ) ->
                            let
                                ( newCond, accCtx1 ) =
                                    rewriteExprForAbi home cond accCtx

                                ( newThen, accCtx2 ) =
                                    rewriteExprForAbi home then_ accCtx1
                            in
                            ( ( newCond, newThen ) :: acc, accCtx2 )
                        )
                        ( [], ctx0 )
                        branches

                ( newFinal, ctx2 ) =
                    rewriteExprForAbi home final ctx1
            in
            ( Mono.MonoIf newBranches newFinal resultType, ctx2 )

        _ ->
            -- Function leaves: normalize to canonical ABI
            let
                ( canonicalSeg, flatArgs, flatRet ) =
                    Mono.chooseCanonicalSegmentation leafTypes

                canonicalType =
                    Mono.buildSegmentedFunctionType flatArgs flatRet canonicalSeg

                rewriteResultExpr : Mono.MonoExpr -> GlobalCtx -> ( Mono.MonoExpr, GlobalCtx )
                rewriteResultExpr expr ctx =
                    case Mono.typeOf expr of
                        Mono.MFunction _ _ ->
                            if Mono.segmentLengths (Mono.typeOf expr) == canonicalSeg then
                                rewriteExprForAbi home expr ctx

                            else
                                buildAbiWrapperGO home canonicalType expr ctx

                        _ ->
                            rewriteExprForAbi home expr ctx

                ( newBranches, ctx1 ) =
                    List.foldr
                        (\( cond, then_ ) ( acc, accCtx ) ->
                            let
                                ( newCond, accCtx1 ) =
                                    rewriteExprForAbi home cond accCtx

                                ( newThen, accCtx2 ) =
                                    rewriteResultExpr then_ accCtx1
                            in
                            ( ( newCond, newThen ) :: acc, accCtx2 )
                        )
                        ( [], ctx0 )
                        branches

                ( newFinal, ctx2 ) =
                    rewriteResultExpr final ctx1
            in
            ( Mono.MonoIf newBranches newFinal canonicalType, ctx2 )



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



-- VALIDATE CLOSURE STAGING


validateClosureStaging : Mono.MonoGraph -> Mono.MonoGraph
validateClosureStaging (Mono.MonoGraph record) =
    let
        _ =
            Dict.foldl compare
                (\_ node () -> validateNodeClosures node)
                ()
                record.nodes
    in
    Mono.MonoGraph record


validateNodeClosures : Mono.MonoNode -> ()
validateNodeClosures node =
    case node of
        Mono.MonoDefine expr _ ->
            validateExprClosures expr

        Mono.MonoTailFunc _ body _ ->
            validateExprClosures body

        Mono.MonoPortIncoming expr _ ->
            validateExprClosures expr

        Mono.MonoPortOutgoing expr _ ->
            validateExprClosures expr

        Mono.MonoCycle defs _ ->
            List.foldl (\( _, e ) () -> validateExprClosures e) () defs

        _ ->
            ()


validateExprClosures : Mono.MonoExpr -> ()
validateExprClosures expr =
    case expr of
        Mono.MonoClosure info body tipe ->
            let
                expectedParams =
                    Mono.stageParamTypes tipe

                actualParams =
                    info.params

                _ =
                    if List.length actualParams /= List.length expectedParams then
                        Debug.todo
                            ("GOPT_001 violation: closure has "
                                ++ String.fromInt (List.length actualParams)
                                ++ " params but type expects "
                                ++ String.fromInt (List.length expectedParams)
                            )

                    else
                        ()
            in
            validateExprClosures body

        Mono.MonoCall _ f args _ _ ->
            let
                _ =
                    validateExprClosures f
            in
            List.foldl (\e () -> validateExprClosures e) () args

        Mono.MonoLet def body _ ->
            let
                _ =
                    validateDefClosures def
            in
            validateExprClosures body

        Mono.MonoCase _ _ decider branches _ ->
            let
                _ =
                    validateDeciderClosures decider
            in
            List.foldl (\( _, e ) () -> validateExprClosures e) () branches

        Mono.MonoIf branches final _ ->
            let
                _ =
                    List.foldl
                        (\( c, t ) () ->
                            let
                                _ =
                                    validateExprClosures c
                            in
                            validateExprClosures t
                        )
                        ()
                        branches
            in
            validateExprClosures final

        Mono.MonoList _ items _ ->
            List.foldl (\e () -> validateExprClosures e) () items

        Mono.MonoTailCall _ args _ ->
            List.foldl (\( _, e ) () -> validateExprClosures e) () args

        Mono.MonoDestruct _ inner _ ->
            validateExprClosures inner

        Mono.MonoRecordCreate fields _ ->
            List.foldl (\( _, e ) () -> validateExprClosures e) () fields

        Mono.MonoRecordAccess inner _ _ ->
            validateExprClosures inner

        Mono.MonoRecordUpdate record updates _ ->
            let
                _ =
                    validateExprClosures record
            in
            List.foldl (\( _, e ) () -> validateExprClosures e) () updates

        Mono.MonoTupleCreate _ elements _ ->
            List.foldl (\e () -> validateExprClosures e) () elements

        _ ->
            ()


validateDefClosures : Mono.MonoDef -> ()
validateDefClosures def =
    case def of
        Mono.MonoDef _ bound ->
            validateExprClosures bound

        Mono.MonoTailDef _ _ bound ->
            validateExprClosures bound


validateDeciderClosures : Mono.Decider Mono.MonoChoice -> ()
validateDeciderClosures dec =
    case dec of
        Mono.Leaf choice ->
            case choice of
                Mono.Inline expr ->
                    validateExprClosures expr

                Mono.Jump _ ->
                    ()

        Mono.Chain _ success failure ->
            let
                _ =
                    validateDeciderClosures success
            in
            validateDeciderClosures failure

        Mono.FanOut _ edges fallback ->
            let
                _ =
                    List.foldl (\( _, d ) () -> validateDeciderClosures d) () edges
            in
            validateDeciderClosures fallback



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
    case expr of
        Mono.MonoCall region func args resultType _ ->
            let
                func1 =
                    annotateExprCalls graph env func

                args1 =
                    List.map (annotateExprCalls graph env) args

                callInfo =
                    computeCallInfo graph env func1 args1 resultType
            in
            Mono.MonoCall region func1 args1 resultType callInfo

        Mono.MonoLet def body tipe ->
            let
                ( def1, env1 ) =
                    annotateDefCalls graph env def

                body1 =
                    annotateExprCalls graph env1 body
            in
            Mono.MonoLet def1 body1 tipe

        Mono.MonoClosure info body tipe ->
            let
                newCaptures =
                    List.map
                        (\( n, e, flag ) -> ( n, annotateExprCalls graph env e, flag ))
                        info.captures

                body1 =
                    annotateExprCalls graph env body
            in
            Mono.MonoClosure { info | captures = newCaptures } body1 tipe

        Mono.MonoIf branches final tipe ->
            let
                branches1 =
                    List.map
                        (\( c, t ) ->
                            ( annotateExprCalls graph env c
                            , annotateExprCalls graph env t
                            )
                        )
                        branches

                final1 =
                    annotateExprCalls graph env final
            in
            Mono.MonoIf branches1 final1 tipe

        Mono.MonoDestruct d inner tipe ->
            Mono.MonoDestruct d (annotateExprCalls graph env inner) tipe

        Mono.MonoCase s1 s2 decider branches tipe ->
            let
                decider1 =
                    annotateDeciderCalls graph env decider

                branches1 =
                    List.map
                        (\( p, e ) -> ( p, annotateExprCalls graph env e ))
                        branches
            in
            Mono.MonoCase s1 s2 decider1 branches1 tipe

        Mono.MonoList region items tipe ->
            Mono.MonoList region (List.map (annotateExprCalls graph env) items) tipe

        Mono.MonoRecordCreate fields tipe ->
            Mono.MonoRecordCreate
                (List.map (\( n, e ) -> ( n, annotateExprCalls graph env e )) fields)
                tipe

        Mono.MonoRecordAccess inner name tipe ->
            Mono.MonoRecordAccess (annotateExprCalls graph env inner) name tipe

        Mono.MonoRecordUpdate record updates tipe ->
            Mono.MonoRecordUpdate
                (annotateExprCalls graph env record)
                (List.map (\( n, e ) -> ( n, annotateExprCalls graph env e )) updates)
                tipe

        Mono.MonoTupleCreate region items tipe ->
            Mono.MonoTupleCreate region (List.map (annotateExprCalls graph env) items) tipe

        Mono.MonoTailCall name args tipe ->
            -- Tail calls use their own representation, no CallInfo needed
            Mono.MonoTailCall name
                (List.map (\( n, e ) -> ( n, annotateExprCalls graph env e )) args)
                tipe

        -- Leaves: literals, vars (no subexpressions)
        _ ->
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


{-| Get call model for a callee, defaulting to StageCurried. -}
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
                        resultArity =
                            sourceArity - List.length args
                    in
                    if resultArity > 0 then
                        -- Partial application: remaining = source - applied
                        Just resultArity

                    else
                        -- Saturated call returning a function.
                        -- For known callees (user closures), use the body's first-stage arity.
                        -- For nested calls or unknown callees, use first-stage of result type
                        -- (assuming stage-curried closures).
                        case closureBodyStageArities graph func of
                            Just (firstStage :: _) ->
                                -- Known callee: use first-stage arity from body
                                Just firstStage

                            Just [] ->
                                -- Body is not a function
                                Nothing

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


{-| Count total arity by summing all stage arities. -}
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

        -- Get stage arities from an expression's body
        getExprBodyArities : Mono.MonoExpr -> Maybe (List Int)
        getExprBodyArities e =
            case e of
                Mono.MonoClosure _ body _ ->
                    -- Check if the closure body is a case/if that returns closures.
                    -- If so, look at the actual closures in branches (after canonicalization)
                    -- rather than using the type, which may have a different staging.
                    case body of
                        Mono.MonoCase _ _ _ jumps _ ->
                            case jumps of
                                ( _, branchExpr ) :: _ ->
                                    getClosureArityFromExpr branchExpr

                                [] ->
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

                Mono.MonoCase _ _ _ jumps _ ->
                    -- After canonicalization, all branches have the same staging.
                    -- Look at the first jump's closure to get the actual staging.
                    case jumps of
                        ( _, branchExpr ) :: _ ->
                            getClosureArityFromExpr branchExpr

                        [] ->
                            -- No jumps, use Nothing to trigger fallback
                            Nothing

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
            }
