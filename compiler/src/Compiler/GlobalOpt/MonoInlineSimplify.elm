module Compiler.GlobalOpt.MonoInlineSimplify exposing (Metrics, optimize)

{-| Mono IR Inliner and Simplifier.

This pass runs after monomorphization and before MLIR generation to
reduce/eliminate higher-order "pipeline plumbing" before it becomes
ECO closures/PAPs.

Key optimizations:

  - Small-function inlining (with recursion guard)
  - Beta-reduction of immediate lambdas
  - Let-sinking/let-elimination
  - Dead code elimination
  - Case simplifications

@docs Metrics, optimize

-}

import Compiler.AST.Monomorphized as Mono exposing (MonoExpr(..), MonoGraph(..), MonoNode(..), SpecId)
import Compiler.AST.TypeEnv as TypeEnv
import Compiler.Data.Name exposing (Name)
import Compiler.GlobalOpt.MonoTraverse as Traverse
import Compiler.Monomorphize.Closure as Closure
import Compiler.Reporting.Annotation as A exposing (Region)
import Data.Graph as Graph
import Data.Map as Dict exposing (Dict)
import System.TypeCheck.IO as IO



-- ============================================================================
-- ====== PUBLIC API ======
-- ============================================================================


{-| Metrics collected during optimization, available for debugging.
-}
type alias Metrics =
    { closureCountBefore : Int
    , closureCountAfter : Int
    , inlineCount : Int
    , betaReductions : Int
    , letEliminations : Int
    }


{-| Optimize a MonoGraph by inlining small functions and simplifying expressions.
-}
optimize : TypeEnv.GlobalTypeEnv -> MonoGraph -> ( MonoGraph, Metrics )
optimize _ graph =
    let
        (MonoGraph { nodes, main, registry, ctorShapes }) =
            graph

        closuresBefore =
            countClosuresInGraph nodes

        callGraph =
            buildCallGraph nodes registry

        ctx =
            initRewriteCtx nodes registry callGraph

        ( optimizedNodes, finalCtx ) =
            Dict.foldl compare
                (\specId node ( accNodes, accCtx ) ->
                    let
                        ( optimizedNode, newCtx ) =
                            optimizeNode accCtx specId node
                    in
                    ( Dict.insert identity specId optimizedNode accNodes, newCtx )
                )
                ( Dict.empty, ctx )
                nodes

        closuresAfter =
            countClosuresInGraph optimizedNodes

        metrics =
            { closureCountBefore = closuresBefore
            , closureCountAfter = closuresAfter
            , inlineCount = finalCtx.metrics.inlineCount
            , betaReductions = finalCtx.metrics.betaReductions
            , letEliminations = finalCtx.metrics.letEliminations
            }
    in
    ( MonoGraph
        { nodes = optimizedNodes
        , main = main
        , registry = registry
        , ctorShapes = ctorShapes
        }
    , metrics
    )



-- ============================================================================
-- ====== WHITELIST ======
-- ============================================================================


{-| List of qualified names (module.name) that should always be inlined.
Using a List since the whitelist is expected to be small.
The format is "Module.Path.name" where the module path is joined with dots.
-}
type alias InlineWhitelist =
    List String


{-| Default whitelist - empty for now, will be populated in the future.
-}
defaultWhitelist : InlineWhitelist
defaultWhitelist =
    []


{-| Convert a Global to a qualified name string for whitelist lookup.
Format is "Module.name" where Module is the module path.
-}
globalToQualifiedName : Mono.Global -> Maybe String
globalToQualifiedName global =
    case global of
        Mono.Global (IO.Canonical _ moduleName) name ->
            Just (moduleName ++ "." ++ name)

        Mono.Accessor _ ->
            Nothing


isWhitelisted : InlineWhitelist -> Mono.Global -> Bool
isWhitelisted whitelist global =
    case globalToQualifiedName global of
        Just qualifiedName ->
            List.member qualifiedName whitelist

        Nothing ->
            False



-- ============================================================================
-- ====== CALL GRAPH ======
-- ============================================================================


{-| Call graph with SCC-based recursion detection.
-}
type alias CallGraph =
    { edges : Dict Int SpecId (List SpecId)
    , isRecursive : Dict Int SpecId Bool
    }


buildCallGraph : Dict Int SpecId MonoNode -> Mono.SpecializationRegistry -> CallGraph
buildCallGraph nodes registry =
    let
        -- Build edges: for each node, collect specIds it calls
        edges =
            Dict.foldl compare
                (\specId node acc ->
                    let
                        calls =
                            collectCallsFromNode node
                    in
                    Dict.insert identity specId calls acc
                )
                Dict.empty
                nodes

        -- Build graph for SCC computation: (node, key, neighbors)
        graphNodes =
            Dict.foldl compare
                (\specId _ acc ->
                    let
                        neighbors =
                            Dict.get identity specId edges
                                |> Maybe.withDefault []
                    in
                    ( specId, specId, neighbors ) :: acc
                )
                []
                nodes

        -- Compute SCCs
        sccs =
            Graph.stronglyConnComp graphNodes

        -- Mark recursive nodes (those in CyclicSCC)
        isRecursiveFromSCC =
            List.foldl
                (\scc acc ->
                    case scc of
                        Graph.AcyclicSCC _ ->
                            acc

                        Graph.CyclicSCC specIds ->
                            List.foldl
                                (\specId innerAcc ->
                                    Dict.insert identity specId True innerAcc
                                )
                                acc
                                specIds
                )
                Dict.empty
                sccs

        -- Mark all MonoCycle nodes as recursive.
        -- MonoCycle contains mutually recursive definitions that reference each other
        -- via MonoVarLocal, which aren't tracked by the SCC analysis above (it only
        -- tracks MonoVarGlobal references). By marking them all as recursive, we prevent
        -- incorrect inlining of cycle-internal functions.
        isRecursive =
            Dict.foldl compare
                (\specId node acc ->
                    case node of
                        MonoCycle _ _ ->
                            Dict.insert identity specId True acc

                        _ ->
                            acc
                )
                isRecursiveFromSCC
                nodes
    in
    { edges = edges
    , isRecursive = isRecursive
    }


collectCallsFromNode : MonoNode -> List SpecId
collectCallsFromNode node =
    case node of
        MonoDefine expr _ ->
            collectCalls expr

        MonoTailFunc _ expr _ ->
            collectCalls expr

        MonoCtor _ _ ->
            []

        MonoEnum _ _ ->
            []

        MonoExtern _ ->
            []

        MonoPortIncoming expr _ ->
            collectCalls expr

        MonoPortOutgoing expr _ ->
            collectCalls expr

        MonoCycle defs _ ->
            List.concatMap (\( _, expr ) -> collectCalls expr) defs


{-| Extract SpecId from global variable references.
-}
extractSpecId : MonoExpr -> List SpecId -> List SpecId
extractSpecId expr acc =
    case expr of
        MonoVarGlobal _ specId _ ->
            specId :: acc

        _ ->
            acc


collectCalls : MonoExpr -> List SpecId
collectCalls =
    Traverse.foldExpr extractSpecId []



-- ============================================================================
-- ====== COST MODEL ======
-- ============================================================================


{-| Cost threshold for inlining (functions with cost <= this are inlined).
-}
inlineThreshold : Int
inlineThreshold =
    10


{-| Maximum number of inlines per function to prevent explosion.
-}
maxInlinesPerFunction : Int
maxInlinesPerFunction =
    10


computeCost : MonoExpr -> Int
computeCost expr =
    case expr of
        MonoLiteral _ _ ->
            1

        MonoVarLocal _ _ ->
            1

        MonoVarGlobal _ _ _ ->
            1

        MonoVarKernel _ _ _ _ ->
            1

        MonoUnit ->
            1

        MonoList _ items _ ->
            3 + List.sum (List.map computeCost items)

        MonoClosure _ body _ ->
            5 + computeCost body

        MonoCall _ func args _ _ ->
            5 + computeCost func + List.sum (List.map computeCost args)

        MonoTailCall _ args _ ->
            5 + List.sum (List.map (\( _, e ) -> computeCost e) args)

        MonoIf branches final _ ->
            2 + List.sum (List.map (\( c, t ) -> computeCost c + computeCost t) branches) + computeCost final

        MonoLet def body _ ->
            2 + computeCostDef def + computeCost body

        MonoDestruct _ inner _ ->
            2 + computeCost inner

        MonoCase _ _ _ branches _ ->
            3 + List.sum (List.map (\( _, e ) -> computeCost e) branches)

        MonoRecordCreate fields _ ->
            3 + List.sum (List.map (\( _, e ) -> computeCost e) fields)

        MonoRecordAccess inner _ _ ->
            1 + computeCost inner

        MonoRecordUpdate inner updates _ ->
            3 + computeCost inner + List.sum (List.map (\( _, e ) -> computeCost e) updates)

        MonoTupleCreate _ items _ ->
            3 + List.sum (List.map computeCost items)


computeCostDef : Mono.MonoDef -> Int
computeCostDef def =
    case def of
        Mono.MonoDef _ bound ->
            computeCost bound

        Mono.MonoTailDef _ _ bound ->
            computeCost bound



-- ============================================================================
-- ====== REWRITE CONTEXT ======
-- ============================================================================


type alias RewriteCtx =
    { nodes : Dict Int SpecId MonoNode
    , registry : Mono.SpecializationRegistry
    , callGraph : CallGraph
    , whitelist : InlineWhitelist
    , inlineCountThisFunction : Int
    , varCounter : Int
    , lambdaCounter : Int
    , metrics : InternalMetrics
    }


type alias InternalMetrics =
    { inlineCount : Int
    , betaReductions : Int
    , letEliminations : Int
    }


initRewriteCtx : Dict Int SpecId MonoNode -> Mono.SpecializationRegistry -> CallGraph -> RewriteCtx
initRewriteCtx nodes registry callGraph =
    { nodes = nodes
    , registry = registry
    , callGraph = callGraph
    , whitelist = defaultWhitelist
    , inlineCountThisFunction = 0
    , varCounter = 0
    , lambdaCounter = 1000000
    , metrics =
        { inlineCount = 0
        , betaReductions = 0
        , letEliminations = 0
        }
    }


freshVar : RewriteCtx -> ( Name, RewriteCtx )
freshVar ctx =
    ( "mono_inline_" ++ String.fromInt ctx.varCounter
    , { ctx | varCounter = ctx.varCounter + 1 }
    )


{-| Generate a fresh lambda ID to avoid duplicate lambda names when inlining.
-}
freshLambdaId : RewriteCtx -> IO.Canonical -> ( Mono.LambdaId, RewriteCtx )
freshLambdaId ctx home =
    ( Mono.AnonymousLambda home ctx.lambdaCounter
    , { ctx | lambdaCounter = ctx.lambdaCounter + 1 }
    )


{-| Generate a fresh lambda ID for a specialization, looking up the home module.
-}
freshLambdaIdForSpec : RewriteCtx -> Mono.SpecId -> ( Mono.LambdaId, RewriteCtx )
freshLambdaIdForSpec ctx specId =
    let
        home =
            case Dict.get identity specId ctx.registry.reverseMapping of
                Just ( Mono.Global h _, _, _ ) ->
                    h

                Just ( Mono.Accessor _, _, _ ) ->
                    -- Accessor doesn't have a home, use a placeholder
                    IO.Canonical ( "", "" ) ""

                Nothing ->
                    -- Fallback if not found
                    IO.Canonical ( "", "" ) ""
    in
    freshLambdaId ctx home


{-| Generate a fresh lambda ID for a closure.
This is called after children are processed, so nested closures get IDs first.
-}
remapClosureLambdaId : RewriteCtx -> MonoExpr -> ( MonoExpr, RewriteCtx )
remapClosureLambdaId ctx expr =
    case expr of
        MonoClosure info body closureType ->
            let
                home =
                    case info.lambdaId of
                        Mono.AnonymousLambda h _ ->
                            h

                ( newLambdaId, ctx1 ) =
                    freshLambdaId ctx home

                newInfo =
                    { info | lambdaId = newLambdaId }
            in
            ( MonoClosure newInfo body closureType, ctx1 )

        _ ->
            ( expr, ctx )


{-| Remap all lambda IDs in an expression to fresh values.
This is necessary when inlining to avoid duplicate lambda function names in MLIR.
-}
remapLambdaIds : RewriteCtx -> MonoExpr -> ( MonoExpr, RewriteCtx )
remapLambdaIds =
    Traverse.traverseExpr remapClosureLambdaId


{-| A binding created during beta reduction or inlining.
-}
type alias Binding =
    { origName : Name
    , freshName : Name
    , arg : MonoExpr
    , argType : Mono.MonoType
    }



-- ============================================================================
-- ====== NODE OPTIMIZATION ======
-- ============================================================================


optimizeNode : RewriteCtx -> SpecId -> MonoNode -> ( MonoNode, RewriteCtx )
optimizeNode ctx specId node =
    -- Reset per-function inline count at start of each node
    let
        ctxForNode =
            { ctx | inlineCountThisFunction = 0 }
    in
    case node of
        MonoDefine expr tipe ->
            let
                ( optimized, newCtx ) =
                    fixpoint ctxForNode expr
            in
            ( MonoDefine optimized tipe, newCtx )

        MonoTailFunc params expr tipe ->
            let
                ( optimized, newCtx ) =
                    fixpoint ctxForNode expr
            in
            ( MonoTailFunc params optimized tipe, newCtx )

        MonoCycle defs tipe ->
            let
                ( optimizedDefs, newCtx ) =
                    optimizeCycleDefs ctxForNode defs
            in
            ( MonoCycle optimizedDefs tipe, newCtx )

        MonoPortIncoming expr tipe ->
            let
                ( optimized, newCtx ) =
                    fixpoint ctxForNode expr
            in
            ( MonoPortIncoming optimized tipe, newCtx )

        MonoPortOutgoing expr tipe ->
            let
                ( optimized, newCtx ) =
                    fixpoint ctxForNode expr
            in
            ( MonoPortOutgoing optimized tipe, newCtx )

        -- MonoCtor, MonoEnum, MonoExtern pass through unchanged
        _ ->
            ( node, ctx )


optimizeCycleDefs : RewriteCtx -> List ( Name, MonoExpr ) -> ( List ( Name, MonoExpr ), RewriteCtx )
optimizeCycleDefs ctx defs =
    List.foldl
        (\( name, expr ) ( accDefs, accCtx ) ->
            let
                ( optimized, newCtx ) =
                    fixpoint accCtx expr
            in
            ( accDefs ++ [ ( name, optimized ) ], newCtx )
        )
        ( [], ctx )
        defs



-- ============================================================================
-- ====== FIXPOINT LOOP ======
-- ============================================================================


{-| Maximum number of fixpoint iterations.
-}
maxIterations : Int
maxIterations =
    4


fixpoint : RewriteCtx -> MonoExpr -> ( MonoExpr, RewriteCtx )
fixpoint ctx expr =
    iterate 0 expr ctx


iterate : Int -> MonoExpr -> RewriteCtx -> ( MonoExpr, RewriteCtx )
iterate n current ctx =
    if n >= maxIterations then
        ( current, ctx )

    else
        let
            ( rewritten, ctx1 ) =
                rewriteExpr ctx current

            ( simplified, ctx2 ) =
                simplifyLets ctx1 rewritten

            final =
                dce simplified
        in
        if exprEqual final current then
            ( final, ctx2 )

        else
            iterate (n + 1) final ctx2


{-| Check if two expressions are structurally equal.
This is a simple structural comparison.
-}
exprEqual : MonoExpr -> MonoExpr -> Bool
exprEqual e1 e2 =
    -- For simplicity, we use string representation comparison
    -- In production, we'd want a proper structural equality check
    e1 == e2



-- ============================================================================
-- ====== EXPRESSION REWRITING ======
-- ============================================================================


rewriteExpr : RewriteCtx -> MonoExpr -> ( MonoExpr, RewriteCtx )
rewriteExpr ctx expr =
    case expr of
        -- Beta reduction: ((\\x -> body) arg)
        MonoCall region (MonoClosure info closureBody _) args resultType _ ->
            betaReduce ctx region info closureBody args resultType

        -- Direct call inlining
        MonoCall region (MonoVarGlobal varRegion specId funcType) args resultType callInfo ->
            let
                ( maybeInlined, ctx1 ) =
                    tryInlineCall ctx specId args resultType
            in
            case maybeInlined of
                Just inlinedExpr ->
                    -- Recursively rewrite the inlined expression
                    rewriteExpr ctx1 inlinedExpr

                Nothing ->
                    -- Can't inline, just rewrite children
                    let
                        ( rewrittenArgs, ctx2 ) =
                            rewriteExprs ctx1 args
                    in
                    ( MonoCall region (MonoVarGlobal varRegion specId funcType) rewrittenArgs resultType callInfo, ctx2 )

        -- Recursive cases - rewrite children
        MonoCall region func args resultType callInfo ->
            let
                ( rewrittenFunc, ctx1 ) =
                    rewriteExpr ctx func

                ( rewrittenArgs, ctx2 ) =
                    rewriteExprs ctx1 args
            in
            ( MonoCall region rewrittenFunc rewrittenArgs resultType callInfo, ctx2 )

        MonoClosure info body closureType ->
            let
                ( rewrittenCaptures, ctx1 ) =
                    rewriteCaptures ctx info.captures

                ( rewrittenBody, ctx2 ) =
                    rewriteExpr ctx1 body
            in
            ( MonoClosure { info | captures = rewrittenCaptures } rewrittenBody closureType, ctx2 )

        MonoList region items itemType ->
            let
                ( rewrittenItems, ctx1 ) =
                    rewriteExprs ctx items
            in
            ( MonoList region rewrittenItems itemType, ctx1 )

        MonoIf branches final resultType ->
            let
                ( rewrittenBranches, ctx1 ) =
                    rewriteBranches ctx branches

                ( rewrittenFinal, ctx2 ) =
                    rewriteExpr ctx1 final
            in
            -- Simplify if with known condition
            case rewrittenBranches of
                [ ( MonoLiteral (Mono.LBool True) _, thenBranch ) ] ->
                    ( thenBranch, ctx2 )

                [ ( MonoLiteral (Mono.LBool False) _, _ ) ] ->
                    ( rewrittenFinal, ctx2 )

                _ ->
                    ( MonoIf rewrittenBranches rewrittenFinal resultType, ctx2 )

        MonoLet def body resultType ->
            let
                ( rewrittenDef, ctx1 ) =
                    rewriteDef ctx def

                ( rewrittenBody, ctx2 ) =
                    rewriteExpr ctx1 body
            in
            ( MonoLet rewrittenDef rewrittenBody resultType, ctx2 )

        MonoDestruct destructor inner resultType ->
            let
                ( rewrittenInner, ctx1 ) =
                    rewriteExpr ctx inner
            in
            ( MonoDestruct destructor rewrittenInner resultType, ctx1 )

        MonoCase scrutName scrutType decider branches resultType ->
            let
                ( rewrittenBranches, ctx1 ) =
                    rewriteCaseBranches ctx branches
            in
            ( MonoCase scrutName scrutType decider rewrittenBranches resultType, ctx1 )

        MonoRecordCreate fields recordType ->
            let
                ( rewrittenFields, ctx1 ) =
                    rewriteNamedFields ctx fields
            in
            ( MonoRecordCreate rewrittenFields recordType, ctx1 )

        MonoRecordAccess inner fieldName resultType ->
            let
                ( rewrittenInner, ctx1 ) =
                    rewriteExpr ctx inner
            in
            ( MonoRecordAccess rewrittenInner fieldName resultType, ctx1 )

        MonoRecordUpdate inner updates recordType ->
            let
                ( rewrittenInner, ctx1 ) =
                    rewriteExpr ctx inner

                ( rewrittenUpdates, ctx2 ) =
                    rewriteNamedFields ctx1 updates
            in
            ( MonoRecordUpdate rewrittenInner rewrittenUpdates recordType, ctx2 )

        MonoTupleCreate region items tupleType ->
            let
                ( rewrittenItems, ctx1 ) =
                    rewriteExprs ctx items
            in
            ( MonoTupleCreate region rewrittenItems tupleType, ctx1 )

        MonoTailCall name args resultType ->
            -- Never inline MonoTailCall to preserve tail-call optimization
            let
                ( rewrittenArgs, ctx1 ) =
                    rewriteTailCallArgs ctx args
            in
            ( MonoTailCall name rewrittenArgs resultType, ctx1 )

        -- Leaves - no children to rewrite
        MonoLiteral _ _ ->
            ( expr, ctx )

        MonoVarLocal _ _ ->
            ( expr, ctx )

        MonoVarGlobal _ _ _ ->
            ( expr, ctx )

        MonoVarKernel _ _ _ _ ->
            ( expr, ctx )

        MonoUnit ->
            ( expr, ctx )


rewriteExprs : RewriteCtx -> List MonoExpr -> ( List MonoExpr, RewriteCtx )
rewriteExprs ctx exprs =
    List.foldl
        (\expr ( acc, accCtx ) ->
            let
                ( rewritten, newCtx ) =
                    rewriteExpr accCtx expr
            in
            ( acc ++ [ rewritten ], newCtx )
        )
        ( [], ctx )
        exprs


rewriteCaptures : RewriteCtx -> List ( Name, MonoExpr, Bool ) -> ( List ( Name, MonoExpr, Bool ), RewriteCtx )
rewriteCaptures ctx captures =
    List.foldl
        (\( name, expr, isUnboxed ) ( acc, accCtx ) ->
            let
                ( rewritten, newCtx ) =
                    rewriteExpr accCtx expr
            in
            ( acc ++ [ ( name, rewritten, isUnboxed ) ], newCtx )
        )
        ( [], ctx )
        captures


rewriteBranches : RewriteCtx -> List ( MonoExpr, MonoExpr ) -> ( List ( MonoExpr, MonoExpr ), RewriteCtx )
rewriteBranches ctx branches =
    List.foldl
        (\( cond, body ) ( acc, accCtx ) ->
            let
                ( rewrittenCond, ctx1 ) =
                    rewriteExpr accCtx cond

                ( rewrittenBody, ctx2 ) =
                    rewriteExpr ctx1 body
            in
            ( acc ++ [ ( rewrittenCond, rewrittenBody ) ], ctx2 )
        )
        ( [], ctx )
        branches


rewriteDef : RewriteCtx -> Mono.MonoDef -> ( Mono.MonoDef, RewriteCtx )
rewriteDef ctx def =
    case def of
        Mono.MonoDef name bound ->
            let
                ( rewritten, newCtx ) =
                    rewriteExpr ctx bound
            in
            ( Mono.MonoDef name rewritten, newCtx )

        Mono.MonoTailDef name params bound ->
            let
                ( rewritten, newCtx ) =
                    rewriteExpr ctx bound
            in
            ( Mono.MonoTailDef name params rewritten, newCtx )


rewriteCaseBranches : RewriteCtx -> List ( Int, MonoExpr ) -> ( List ( Int, MonoExpr ), RewriteCtx )
rewriteCaseBranches ctx branches =
    List.foldl
        (\( idx, body ) ( acc, accCtx ) ->
            let
                ( rewritten, newCtx ) =
                    rewriteExpr accCtx body
            in
            ( acc ++ [ ( idx, rewritten ) ], newCtx )
        )
        ( [], ctx )
        branches


rewriteNamedFields : RewriteCtx -> List ( Name, MonoExpr ) -> ( List ( Name, MonoExpr ), RewriteCtx )
rewriteNamedFields ctx fields =
    List.foldl
        (\( name, expr ) ( acc, accCtx ) ->
            let
                ( rewritten, newCtx ) =
                    rewriteExpr accCtx expr
            in
            ( acc ++ [ ( name, rewritten ) ], newCtx )
        )
        ( [], ctx )
        fields


rewriteTailCallArgs : RewriteCtx -> List ( Name, MonoExpr ) -> ( List ( Name, MonoExpr ), RewriteCtx )
rewriteTailCallArgs ctx args =
    List.foldl
        (\( name, expr ) ( acc, accCtx ) ->
            let
                ( rewritten, newCtx ) =
                    rewriteExpr accCtx expr
            in
            ( acc ++ [ ( name, rewritten ) ], newCtx )
        )
        ( [], ctx )
        args



-- ============================================================================
-- ====== BETA REDUCTION ======
-- ============================================================================


betaReduce : RewriteCtx -> Region -> Mono.ClosureInfo -> MonoExpr -> List MonoExpr -> Mono.MonoType -> ( MonoExpr, RewriteCtx )
betaReduce ctx region info closureBody args resultType =
    let
        params =
            info.params

        numParams =
            List.length params

        numArgs =
            List.length args
    in
    if numArgs == 0 then
        -- No arguments, just return closure
        ( MonoClosure info closureBody (Mono.typeOf (MonoClosure info closureBody resultType)), ctx )

    else if numArgs == numParams then
        -- Exact application: bind all params to args
        let
            ( bindings, ctx1 ) =
                createBindings ctx params args

            substituted =
                substituteAll bindings closureBody

            newMetrics =
                { inlineCount = ctx1.metrics.inlineCount
                , betaReductions = ctx1.metrics.betaReductions + 1
                , letEliminations = ctx1.metrics.letEliminations
                }
        in
        ( wrapInLets bindings substituted resultType, { ctx1 | metrics = newMetrics } )

    else if numArgs < numParams then
        -- Partial application: bind available params, return closure with remaining
        let
            ( usedParams, remainingParams ) =
                ( List.take numArgs params, List.drop numArgs params )

            ( bindings, ctx1 ) =
                createBindings ctx usedParams args

            substituted =
                substituteAll bindings closureBody

            newClosureType =
                Mono.MFunction (List.map Tuple.second remainingParams) resultType

            -- Recompute captures for the new closure body.
            -- The substitution may have introduced new free variables (the fresh names
            -- bound in the surrounding lets) that need to be captured.
            newCaptures =
                Closure.computeClosureCaptures remainingParams substituted

            newInfo =
                { info | params = remainingParams, captures = newCaptures }

            newMetrics =
                { inlineCount = ctx1.metrics.inlineCount
                , betaReductions = ctx1.metrics.betaReductions + 1
                , letEliminations = ctx1.metrics.letEliminations
                }
        in
        ( wrapInLets bindings (MonoClosure newInfo substituted newClosureType) newClosureType
        , { ctx1 | metrics = newMetrics }
        )

    else
        -- Over-application: apply all params, then call result with extra args
        let
            ( usedArgs, extraArgs ) =
                ( List.take numParams args, List.drop numParams args )

            ( bindings, ctx1 ) =
                createBindings ctx params usedArgs

            substituted =
                substituteAll bindings closureBody

            newMetrics =
                { inlineCount = ctx1.metrics.inlineCount
                , betaReductions = ctx1.metrics.betaReductions + 1
                , letEliminations = ctx1.metrics.letEliminations
                }

            innerExpr =
                wrapInLets bindings substituted (Mono.typeOf closureBody)
        in
        ( MonoCall region innerExpr extraArgs resultType Mono.defaultCallInfo
        , { ctx1 | metrics = newMetrics }
        )


createBindings : RewriteCtx -> List ( Name, Mono.MonoType ) -> List MonoExpr -> ( List Binding, RewriteCtx )
createBindings ctx params args =
    List.foldl
        (\( ( paramName, _ ), arg ) ( acc, accCtx ) ->
            let
                ( freshName, newCtx ) =
                    freshVar accCtx

                binding =
                    { origName = paramName
                    , freshName = freshName
                    , arg = arg
                    , argType = Mono.typeOf arg
                    }
            in
            ( acc ++ [ binding ], newCtx )
        )
        ( [], ctx )
        (List.map2 Tuple.pair params args)


wrapInLets : List Binding -> MonoExpr -> Mono.MonoType -> MonoExpr
wrapInLets bindings body resultType =
    List.foldr
        (\binding acc ->
            MonoLet (Mono.MonoDef binding.freshName binding.arg) acc resultType
        )
        body
        bindings


substituteAll : List Binding -> MonoExpr -> MonoExpr
substituteAll bindings expr =
    List.foldl
        (\binding acc ->
            substitute binding.origName binding.freshName binding.argType acc
        )
        expr
        bindings


substitute : Name -> Name -> Mono.MonoType -> MonoExpr -> MonoExpr
substitute oldName newName varType expr =
    case expr of
        MonoVarLocal name _ ->
            if name == oldName then
                MonoVarLocal newName varType

            else
                expr

        MonoLiteral _ _ ->
            expr

        MonoVarGlobal _ _ _ ->
            expr

        MonoVarKernel _ _ _ _ ->
            expr

        MonoUnit ->
            expr

        MonoList region items itemType ->
            MonoList region (List.map (substitute oldName newName varType) items) itemType

        MonoClosure info body closureType ->
            -- Don't substitute if the name is shadowed by a param
            if List.any (\( n, _ ) -> n == oldName) info.params then
                expr

            else
                let
                    -- When substituting, also rename capture names that match oldName.
                    -- This ensures that if the body now references newName (due to substitution),
                    -- the capture binding also uses newName.
                    newCaptures =
                        List.map
                            (\( n, e, isUnboxed ) ->
                                ( if n == oldName then
                                    newName

                                  else
                                    n
                                , substitute oldName newName varType e
                                , isUnboxed
                                )
                            )
                            info.captures
                in
                MonoClosure { info | captures = newCaptures } (substitute oldName newName varType body) closureType

        MonoCall region func args resultType callInfo ->
            MonoCall region
                (substitute oldName newName varType func)
                (List.map (substitute oldName newName varType) args)
                resultType
                callInfo

        MonoTailCall name args resultType ->
            MonoTailCall name
                (List.map (\( n, e ) -> ( n, substitute oldName newName varType e )) args)
                resultType

        MonoIf branches final resultType ->
            MonoIf
                (List.map (\( c, t ) -> ( substitute oldName newName varType c, substitute oldName newName varType t )) branches)
                (substitute oldName newName varType final)
                resultType

        MonoLet def body resultType ->
            let
                defName =
                    getDefName def
            in
            if defName == oldName then
                -- Name is shadowed, only substitute in the def's bound expression
                MonoLet (substituteDef oldName newName varType def) body resultType

            else
                MonoLet (substituteDef oldName newName varType def) (substitute oldName newName varType body) resultType

        MonoDestruct (Mono.MonoDestructor destructName path destructType) inner resultType ->
            let
                -- The path refers to the source variable, so substitute there
                newPath =
                    substitutePath oldName newName path

                -- The destructName is a NEW binding, don't rename it.
                -- If destructName == oldName, it shadows the param, so don't substitute in inner
                newInner =
                    if destructName == oldName then
                        inner

                    else
                        substitute oldName newName varType inner
            in
            MonoDestruct (Mono.MonoDestructor destructName newPath destructType) newInner resultType

        MonoCase unused rootName decider branches resultType ->
            -- MonoCase has two Name fields: first is unused, second is the root variable
            let
                newRootName =
                    if rootName == oldName then
                        newName

                    else
                        rootName
            in
            MonoCase unused
                newRootName
                decider
                (List.map (\( idx, e ) -> ( idx, substitute oldName newName varType e )) branches)
                resultType

        MonoRecordCreate fields recordType ->
            MonoRecordCreate (List.map (\( n, e ) -> ( n, substitute oldName newName varType e )) fields) recordType

        MonoRecordAccess inner fieldName resultType ->
            MonoRecordAccess (substitute oldName newName varType inner) fieldName resultType

        MonoRecordUpdate inner updates recordType ->
            MonoRecordUpdate
                (substitute oldName newName varType inner)
                (List.map (\( n, e ) -> ( n, substitute oldName newName varType e )) updates)
                recordType

        MonoTupleCreate region items tupleType ->
            MonoTupleCreate region (List.map (substitute oldName newName varType) items) tupleType


substituteDef : Name -> Name -> Mono.MonoType -> Mono.MonoDef -> Mono.MonoDef
substituteDef oldName newName varType def =
    case def of
        Mono.MonoDef name bound ->
            Mono.MonoDef name (substitute oldName newName varType bound)

        Mono.MonoTailDef name params bound ->
            -- Don't substitute if shadowed by a param
            if List.any (\( n, _ ) -> n == oldName) params then
                def

            else
                Mono.MonoTailDef name params (substitute oldName newName varType bound)


substitutePath : Name -> Name -> Mono.MonoPath -> Mono.MonoPath
substitutePath oldName newName path =
    case path of
        Mono.MonoRoot rootName rootType ->
            if rootName == oldName then
                Mono.MonoRoot newName rootType

            else
                path

        Mono.MonoIndex idx container resultType innerPath ->
            Mono.MonoIndex idx container resultType (substitutePath oldName newName innerPath)

        Mono.MonoField fieldIdx resultType innerPath ->
            Mono.MonoField fieldIdx resultType (substitutePath oldName newName innerPath)

        Mono.MonoUnbox resultType innerPath ->
            Mono.MonoUnbox resultType (substitutePath oldName newName innerPath)


getDefName : Mono.MonoDef -> Name
getDefName def =
    case def of
        Mono.MonoDef name _ ->
            name

        Mono.MonoTailDef name _ _ ->
            name



-- ============================================================================
-- ====== DIRECT CALL INLINING ======
-- ============================================================================


tryInlineCall : RewriteCtx -> SpecId -> List MonoExpr -> Mono.MonoType -> ( Maybe MonoExpr, RewriteCtx )
tryInlineCall ctx specId args resultType =
    -- Check budget
    if ctx.inlineCountThisFunction >= maxInlinesPerFunction then
        ( Nothing, ctx )

    else
        -- Look up the callee
        case Dict.get identity specId ctx.nodes of
            Nothing ->
                ( Nothing, ctx )

            Just node ->
                -- Check if recursive
                let
                    isRecursive =
                        Dict.get identity specId ctx.callGraph.isRecursive
                            |> Maybe.withDefault False

                    -- Look up global name for whitelist check
                    maybeGlobal =
                        Dict.get identity specId ctx.registry.reverseMapping
                            |> Maybe.map (\( g, _, _ ) -> g)

                    whitelisted =
                        maybeGlobal
                            |> Maybe.map (isWhitelisted ctx.whitelist)
                            |> Maybe.withDefault False
                in
                -- Never inline recursive functions (even if whitelisted)
                if isRecursive then
                    ( Nothing, ctx )

                else
                    case getInlinableBody node of
                        Nothing ->
                            ( Nothing, ctx )

                        Just ( params, body ) ->
                            let
                                numParams =
                                    List.length params

                                numArgs =
                                    List.length args

                                cost =
                                    computeCost body
                            in
                            -- Check cost threshold (or whitelist)
                            if cost > inlineThreshold && not whitelisted then
                                ( Nothing, ctx )

                            else if numParams == 0 && numArgs > 0 then
                                -- Inlining a non-closure value that's being called.
                                -- The body is likely a function reference. Inline it and
                                -- wrap with a call to apply the remaining arguments.
                                let
                                    ( remappedBody, ctx1 ) =
                                        remapLambdaIds ctx body

                                    inlined =
                                        MonoCall A.zero remappedBody args resultType Mono.defaultCallInfo

                                    newMetrics =
                                        { inlineCount = ctx1.metrics.inlineCount + 1
                                        , betaReductions = ctx1.metrics.betaReductions
                                        , letEliminations = ctx1.metrics.letEliminations
                                        }
                                in
                                ( Just inlined
                                , { ctx1
                                    | metrics = newMetrics
                                    , inlineCountThisFunction = ctx1.inlineCountThisFunction + 1
                                  }
                                )

                            else if numArgs < numParams then
                                -- Partial application: bind available params, return closure with remaining
                                let
                                    ( remappedBody, ctx1 ) =
                                        remapLambdaIds ctx body

                                    ( usedParams, remainingParams ) =
                                        ( List.take numArgs params, List.drop numArgs params )

                                    ( bindings, ctx2 ) =
                                        createBindingsForInline ctx1 usedParams args

                                    substituted =
                                        substituteAllForInline bindings remappedBody

                                    -- Create a new closure with the remaining parameters
                                    ( newLambdaId, ctx3 ) =
                                        freshLambdaIdForSpec ctx2 specId

                                    newClosureType =
                                        Mono.MFunction (List.map Tuple.second remainingParams) resultType

                                    -- Compute captures for the new closure
                                    newCaptures =
                                        Closure.computeClosureCaptures remainingParams substituted

                                    newClosureInfo =
                                        { lambdaId = newLambdaId
                                        , params = remainingParams
                                        , captures = newCaptures
                                        , closureKind = Nothing
                                        , captureAbi = Nothing
                                        }

                                    newClosure =
                                        MonoClosure newClosureInfo substituted newClosureType

                                    inlined =
                                        wrapInLetsForInline bindings newClosure newClosureType

                                    newMetrics =
                                        { inlineCount = ctx3.metrics.inlineCount + 1
                                        , betaReductions = ctx3.metrics.betaReductions
                                        , letEliminations = ctx3.metrics.letEliminations
                                        }
                                in
                                ( Just inlined
                                , { ctx3
                                    | metrics = newMetrics
                                    , inlineCountThisFunction = ctx3.inlineCountThisFunction + 1
                                  }
                                )

                            else if numArgs > numParams then
                                -- Over-application: apply all params, then call result with extra args
                                let
                                    ( remappedBody, ctx1 ) =
                                        remapLambdaIds ctx body

                                    ( usedArgs, extraArgs ) =
                                        ( List.take numParams args, List.drop numParams args )

                                    ( bindings, ctx2 ) =
                                        createBindingsForInline ctx1 params usedArgs

                                    substituted =
                                        substituteAllForInline bindings remappedBody

                                    innerExpr =
                                        wrapInLetsForInline bindings substituted (Mono.typeOf body)

                                    inlined =
                                        MonoCall A.zero innerExpr extraArgs resultType Mono.defaultCallInfo

                                    newMetrics =
                                        { inlineCount = ctx2.metrics.inlineCount + 1
                                        , betaReductions = ctx2.metrics.betaReductions
                                        , letEliminations = ctx2.metrics.letEliminations
                                        }
                                in
                                ( Just inlined
                                , { ctx2
                                    | metrics = newMetrics
                                    , inlineCountThisFunction = ctx2.inlineCountThisFunction + 1
                                  }
                                )

                            else
                                -- Exact application: bind all params to args
                                let
                                    -- First, remap all lambda IDs in the body to avoid duplicate names
                                    ( remappedBody, ctx1 ) =
                                        remapLambdaIds ctx body

                                    ( bindings, ctx2 ) =
                                        createBindingsForInline ctx1 params args

                                    substituted =
                                        substituteAllForInline bindings remappedBody

                                    inlined =
                                        wrapInLetsForInline bindings substituted resultType

                                    newMetrics =
                                        { inlineCount = ctx2.metrics.inlineCount + 1
                                        , betaReductions = ctx2.metrics.betaReductions
                                        , letEliminations = ctx2.metrics.letEliminations
                                        }
                                in
                                ( Just inlined
                                , { ctx2
                                    | metrics = newMetrics
                                    , inlineCountThisFunction = ctx2.inlineCountThisFunction + 1
                                  }
                                )


getInlinableBody : MonoNode -> Maybe ( List ( Name, Mono.MonoType ), MonoExpr )
getInlinableBody node =
    case node of
        MonoDefine expr _ ->
            -- Check if the define's expression is a closure
            case expr of
                MonoClosure info body _ ->
                    -- Don't inline closures with Case body.
                    -- MonoCase becomes eco.case in MLIR, which is a terminator (no result value).
                    -- Inlining Case into expression positions breaks MLIR generation.
                    if isCase body then
                        Nothing

                    else
                        Just ( info.params, body )

                _ ->
                    -- Simple define with no parameters (e.g., constants)
                    -- Don't inline if it's a Case expression
                    if isCase expr then
                        Nothing

                    else
                        Just ( [], expr )

        MonoTailFunc params expr _ ->
            -- Don't inline tail functions with Case body
            if isCase expr then
                Nothing

            else
                Just ( params, expr )

        _ ->
            Nothing


{-| Check if an expression is a MonoCase.
Cases cannot be inlined into expression positions because eco.case is a
terminator in MLIR - it doesn't produce a result value, control exits
through eco.return inside the case branches.
-}
isCase : MonoExpr -> Bool
isCase expr =
    case expr of
        MonoCase _ _ _ _ _ ->
            True

        _ ->
            False


createBindingsForInline : RewriteCtx -> List ( Name, Mono.MonoType ) -> List MonoExpr -> ( List Binding, RewriteCtx )
createBindingsForInline ctx params args =
    -- For inlining, we need to handle the case where we have a parameterless define
    if List.isEmpty params then
        ( [], ctx )

    else
        createBindings ctx params args


substituteAllForInline : List Binding -> MonoExpr -> MonoExpr
substituteAllForInline =
    substituteAll


wrapInLetsForInline : List Binding -> MonoExpr -> Mono.MonoType -> MonoExpr
wrapInLetsForInline =
    wrapInLets



-- ============================================================================
-- ====== LET SIMPLIFICATION ======
-- ============================================================================


simplifyLets : RewriteCtx -> MonoExpr -> ( MonoExpr, RewriteCtx )
simplifyLets ctx expr =
    case expr of
        MonoLet def body resultType ->
            let
                defName =
                    getDefName def

                defBound =
                    getDefBound def

                usageCount =
                    countUsages defName body
            in
            if usageCount == 0 && isPureExpr defBound && not (isClosure defBound) then
                -- Unused binding with pure non-closure expression - safe to eliminate.
                -- We exclude closures because in let-rec structures, closures may reference
                -- each other via MonoVarLocal, but those references live in sibling/parent
                -- let bindings, not in the immediate body. Eliminating a "unused" closure
                -- would break those cross-references.
                let
                    newMetrics =
                        { inlineCount = ctx.metrics.inlineCount
                        , betaReductions = ctx.metrics.betaReductions
                        , letEliminations = ctx.metrics.letEliminations + 1
                        }
                in
                simplifyLets { ctx | metrics = newMetrics } body

            else
                let
                    ( simplifiedBound, ctx1 ) =
                        simplifyLets ctx defBound

                    ( simplifiedBody, ctx2 ) =
                        simplifyLets ctx1 body

                    newDef =
                        setDefBound def simplifiedBound
                in
                ( MonoLet newDef simplifiedBody resultType, ctx2 )

        -- Recursive cases
        MonoCall region func args resultType callInfo ->
            let
                ( simplifiedFunc, ctx1 ) =
                    simplifyLets ctx func

                ( simplifiedArgs, ctx2 ) =
                    simplifyLetsExprs ctx1 args
            in
            ( MonoCall region simplifiedFunc simplifiedArgs resultType callInfo, ctx2 )

        MonoClosure info body closureType ->
            let
                ( simplifiedCaptures, ctx1 ) =
                    simplifyLetsCaptures ctx info.captures

                ( simplifiedBody, ctx2 ) =
                    simplifyLets ctx1 body
            in
            ( MonoClosure { info | captures = simplifiedCaptures } simplifiedBody closureType, ctx2 )

        MonoList region items itemType ->
            let
                ( simplifiedItems, ctx1 ) =
                    simplifyLetsExprs ctx items
            in
            ( MonoList region simplifiedItems itemType, ctx1 )

        MonoIf branches final resultType ->
            let
                ( simplifiedBranches, ctx1 ) =
                    simplifyLetsBranches ctx branches

                ( simplifiedFinal, ctx2 ) =
                    simplifyLets ctx1 final
            in
            ( MonoIf simplifiedBranches simplifiedFinal resultType, ctx2 )

        MonoDestruct destructor inner resultType ->
            let
                ( simplifiedInner, ctx1 ) =
                    simplifyLets ctx inner
            in
            ( MonoDestruct destructor simplifiedInner resultType, ctx1 )

        MonoCase scrutName scrutType decider branches resultType ->
            let
                ( simplifiedBranches, ctx1 ) =
                    simplifyLetsCaseBranches ctx branches
            in
            ( MonoCase scrutName scrutType decider simplifiedBranches resultType, ctx1 )

        MonoRecordCreate fields recordType ->
            let
                ( simplifiedFields, ctx1 ) =
                    simplifyLetsNamedFields ctx fields
            in
            ( MonoRecordCreate simplifiedFields recordType, ctx1 )

        MonoRecordAccess inner fieldName resultType ->
            let
                ( simplifiedInner, ctx1 ) =
                    simplifyLets ctx inner
            in
            ( MonoRecordAccess simplifiedInner fieldName resultType, ctx1 )

        MonoRecordUpdate inner updates recordType ->
            let
                ( simplifiedInner, ctx1 ) =
                    simplifyLets ctx inner

                ( simplifiedUpdates, ctx2 ) =
                    simplifyLetsNamedFields ctx1 updates
            in
            ( MonoRecordUpdate simplifiedInner simplifiedUpdates recordType, ctx2 )

        MonoTupleCreate region items tupleType ->
            let
                ( simplifiedItems, ctx1 ) =
                    simplifyLetsExprs ctx items
            in
            ( MonoTupleCreate region simplifiedItems tupleType, ctx1 )

        MonoTailCall name args resultType ->
            let
                ( simplifiedArgs, ctx1 ) =
                    simplifyLetsTailCallArgs ctx args
            in
            ( MonoTailCall name simplifiedArgs resultType, ctx1 )

        -- Leaves
        _ ->
            ( expr, ctx )


simplifyLetsExprs : RewriteCtx -> List MonoExpr -> ( List MonoExpr, RewriteCtx )
simplifyLetsExprs ctx exprs =
    List.foldl
        (\expr ( acc, accCtx ) ->
            let
                ( simplified, newCtx ) =
                    simplifyLets accCtx expr
            in
            ( acc ++ [ simplified ], newCtx )
        )
        ( [], ctx )
        exprs


simplifyLetsCaptures : RewriteCtx -> List ( Name, MonoExpr, Bool ) -> ( List ( Name, MonoExpr, Bool ), RewriteCtx )
simplifyLetsCaptures ctx captures =
    List.foldl
        (\( name, expr, isUnboxed ) ( acc, accCtx ) ->
            let
                ( simplified, newCtx ) =
                    simplifyLets accCtx expr
            in
            ( acc ++ [ ( name, simplified, isUnboxed ) ], newCtx )
        )
        ( [], ctx )
        captures


simplifyLetsBranches : RewriteCtx -> List ( MonoExpr, MonoExpr ) -> ( List ( MonoExpr, MonoExpr ), RewriteCtx )
simplifyLetsBranches ctx branches =
    List.foldl
        (\( cond, body ) ( acc, accCtx ) ->
            let
                ( simplifiedCond, ctx1 ) =
                    simplifyLets accCtx cond

                ( simplifiedBody, ctx2 ) =
                    simplifyLets ctx1 body
            in
            ( acc ++ [ ( simplifiedCond, simplifiedBody ) ], ctx2 )
        )
        ( [], ctx )
        branches


simplifyLetsCaseBranches : RewriteCtx -> List ( Int, MonoExpr ) -> ( List ( Int, MonoExpr ), RewriteCtx )
simplifyLetsCaseBranches ctx branches =
    List.foldl
        (\( idx, body ) ( acc, accCtx ) ->
            let
                ( simplified, newCtx ) =
                    simplifyLets accCtx body
            in
            ( acc ++ [ ( idx, simplified ) ], newCtx )
        )
        ( [], ctx )
        branches


simplifyLetsNamedFields : RewriteCtx -> List ( Name, MonoExpr ) -> ( List ( Name, MonoExpr ), RewriteCtx )
simplifyLetsNamedFields ctx fields =
    List.foldl
        (\( name, expr ) ( acc, accCtx ) ->
            let
                ( simplified, newCtx ) =
                    simplifyLets accCtx expr
            in
            ( acc ++ [ ( name, simplified ) ], newCtx )
        )
        ( [], ctx )
        fields


simplifyLetsTailCallArgs : RewriteCtx -> List ( Name, MonoExpr ) -> ( List ( Name, MonoExpr ), RewriteCtx )
simplifyLetsTailCallArgs ctx args =
    List.foldl
        (\( name, expr ) ( acc, accCtx ) ->
            let
                ( simplified, newCtx ) =
                    simplifyLets accCtx expr
            in
            ( acc ++ [ ( name, simplified ) ], newCtx )
        )
        ( [], ctx )
        args


getDefBound : Mono.MonoDef -> MonoExpr
getDefBound def =
    case def of
        Mono.MonoDef _ bound ->
            bound

        Mono.MonoTailDef _ _ bound ->
            bound


setDefBound : Mono.MonoDef -> MonoExpr -> Mono.MonoDef
setDefBound def newBound =
    case def of
        Mono.MonoDef name _ ->
            Mono.MonoDef name newBound

        Mono.MonoTailDef name params _ ->
            Mono.MonoTailDef name params newBound


{-| Check if an expression is a closure.
-}
isClosure : MonoExpr -> Bool
isClosure expr =
    case expr of
        MonoClosure _ _ _ ->
            True

        _ ->
            False


{-| Check if an expression is pure (no side effects).
We're conservative here - only eliminate bindings we're certain are pure.
Function calls might have side effects (like Debug.log), so we don't eliminate them.
-}
isPureExpr : MonoExpr -> Bool
isPureExpr expr =
    case expr of
        MonoLiteral _ _ ->
            True

        MonoVarLocal _ _ ->
            True

        MonoVarGlobal _ _ _ ->
            True

        MonoVarKernel _ _ _ _ ->
            -- Kernel functions could have side effects
            False

        MonoUnit ->
            True

        MonoList _ items _ ->
            List.all isPureExpr items

        MonoClosure _ _ _ ->
            -- Closure creation is pure (evaluation is not)
            True

        MonoCall _ _ _ _ _ ->
            -- Function calls might have side effects
            False

        MonoTailCall _ _ _ ->
            -- Tail calls might have side effects
            False

        MonoIf branches final _ ->
            List.all (\( c, t ) -> isPureExpr c && isPureExpr t) branches
                && isPureExpr final

        MonoLet _ body _ ->
            -- Conservatively, check the body
            isPureExpr body

        MonoDestruct _ inner _ ->
            isPureExpr inner

        MonoCase _ _ _ branches _ ->
            List.all (\( _, e ) -> isPureExpr e) branches

        MonoRecordCreate fields _ ->
            List.all (\( _, e ) -> isPureExpr e) fields

        MonoRecordAccess inner _ _ ->
            isPureExpr inner

        MonoRecordUpdate inner updates _ ->
            isPureExpr inner && List.all (\( _, e ) -> isPureExpr e) updates

        MonoTupleCreate _ items _ ->
            List.all isPureExpr items


countUsages : Name -> MonoExpr -> Int
countUsages name expr =
    case expr of
        MonoVarLocal n _ ->
            if n == name then
                1

            else
                0

        MonoLiteral _ _ ->
            0

        MonoVarGlobal _ _ _ ->
            0

        MonoVarKernel _ _ _ _ ->
            0

        MonoUnit ->
            0

        MonoList _ items _ ->
            List.sum (List.map (countUsages name) items)

        MonoClosure info body _ ->
            -- Don't count if shadowed by param
            if List.any (\( n, _ ) -> n == name) info.params then
                List.sum (List.map (\( _, e, _ ) -> countUsages name e) info.captures)

            else
                List.sum (List.map (\( _, e, _ ) -> countUsages name e) info.captures)
                    + countUsages name body

        MonoCall _ func args _ _ ->
            countUsages name func + List.sum (List.map (countUsages name) args)

        MonoTailCall funcName args _ ->
            -- Count if this is a tail call to the variable
            (if funcName == name then
                1

             else
                0
            )
                + List.sum (List.map (\( _, e ) -> countUsages name e) args)

        MonoIf branches final _ ->
            List.sum (List.map (\( c, t ) -> countUsages name c + countUsages name t) branches)
                + countUsages name final

        MonoLet def body _ ->
            let
                defName =
                    getDefName def

                boundUsages =
                    countUsagesInDef name def
            in
            if defName == name then
                boundUsages

            else
                boundUsages + countUsages name body

        MonoDestruct (Mono.MonoDestructor _ path _) inner _ ->
            -- Count usage in the path (the source being destructured) + usage in inner
            -- Note: destructName is the OUTPUT binding, not an input usage
            countUsagesInPath name path + countUsages name inner

        MonoCase _ rootName _ branches _ ->
            -- MonoCase has two Names: first is unused, second is the root variable
            let
                rootUsage =
                    if rootName == name then
                        1

                    else
                        0
            in
            rootUsage + List.sum (List.map (\( _, e ) -> countUsages name e) branches)

        MonoRecordCreate fields _ ->
            List.sum (List.map (\( _, e ) -> countUsages name e) fields)

        MonoRecordAccess inner _ _ ->
            countUsages name inner

        MonoRecordUpdate inner updates _ ->
            countUsages name inner + List.sum (List.map (\( _, e ) -> countUsages name e) updates)

        MonoTupleCreate _ items _ ->
            List.sum (List.map (countUsages name) items)


countUsagesInDef : Name -> Mono.MonoDef -> Int
countUsagesInDef name def =
    case def of
        Mono.MonoDef _ bound ->
            countUsages name bound

        Mono.MonoTailDef _ params bound ->
            if List.any (\( n, _ ) -> n == name) params then
                0

            else
                countUsages name bound


countUsagesInPath : Name -> Mono.MonoPath -> Int
countUsagesInPath name path =
    case path of
        Mono.MonoRoot rootName _ ->
            if rootName == name then
                1

            else
                0

        Mono.MonoIndex _ _ _ innerPath ->
            countUsagesInPath name innerPath

        Mono.MonoField _ _ innerPath ->
            countUsagesInPath name innerPath

        Mono.MonoUnbox _ innerPath ->
            countUsagesInPath name innerPath


inlineVar : Name -> MonoExpr -> MonoExpr -> MonoExpr
inlineVar name replacement expr =
    case expr of
        MonoVarLocal n _ ->
            if n == name then
                replacement

            else
                expr

        MonoLiteral _ _ ->
            expr

        MonoVarGlobal _ _ _ ->
            expr

        MonoVarKernel _ _ _ _ ->
            expr

        MonoUnit ->
            expr

        MonoList region items itemType ->
            MonoList region (List.map (inlineVar name replacement) items) itemType

        MonoClosure info body closureType ->
            if List.any (\( n, _ ) -> n == name) info.params then
                expr

            else
                let
                    newCaptures =
                        List.map
                            (\( n, e, isUnboxed ) -> ( n, inlineVar name replacement e, isUnboxed ))
                            info.captures
                in
                MonoClosure { info | captures = newCaptures } (inlineVar name replacement body) closureType

        MonoCall region func args resultType callInfo ->
            MonoCall region
                (inlineVar name replacement func)
                (List.map (inlineVar name replacement) args)
                resultType
                callInfo

        MonoTailCall n args resultType ->
            MonoTailCall n
                (List.map (\( argName, e ) -> ( argName, inlineVar name replacement e )) args)
                resultType

        MonoIf branches final resultType ->
            MonoIf
                (List.map (\( c, t ) -> ( inlineVar name replacement c, inlineVar name replacement t )) branches)
                (inlineVar name replacement final)
                resultType

        MonoLet def body resultType ->
            let
                defName =
                    getDefName def
            in
            if defName == name then
                MonoLet (inlineVarInDef name replacement def) body resultType

            else
                MonoLet (inlineVarInDef name replacement def) (inlineVar name replacement body) resultType

        MonoDestruct destructor inner resultType ->
            MonoDestruct destructor (inlineVar name replacement inner) resultType

        MonoCase scrutName scrutType decider branches resultType ->
            MonoCase scrutName
                scrutType
                decider
                (List.map (\( idx, e ) -> ( idx, inlineVar name replacement e )) branches)
                resultType

        MonoRecordCreate fields recordType ->
            MonoRecordCreate (List.map (\( n, e ) -> ( n, inlineVar name replacement e )) fields) recordType

        MonoRecordAccess inner fieldName resultType ->
            MonoRecordAccess (inlineVar name replacement inner) fieldName resultType

        MonoRecordUpdate inner updates recordType ->
            MonoRecordUpdate
                (inlineVar name replacement inner)
                (List.map (\( n, e ) -> ( n, inlineVar name replacement e )) updates)
                recordType

        MonoTupleCreate region items tupleType ->
            MonoTupleCreate region (List.map (inlineVar name replacement) items) tupleType


inlineVarInDef : Name -> MonoExpr -> Mono.MonoDef -> Mono.MonoDef
inlineVarInDef name replacement def =
    case def of
        Mono.MonoDef n bound ->
            Mono.MonoDef n (inlineVar name replacement bound)

        Mono.MonoTailDef n params bound ->
            if List.any (\( pn, _ ) -> pn == name) params then
                def

            else
                Mono.MonoTailDef n params (inlineVar name replacement bound)



-- ============================================================================
-- ====== DEAD CODE ELIMINATION ======
-- ============================================================================


dce : MonoExpr -> MonoExpr
dce expr =
    -- Most DCE is handled by let simplification
    -- This pass handles any remaining cases
    case expr of
        MonoLet def body resultType ->
            let
                dcedBound =
                    dce (getDefBound def)

                dcedBody =
                    dce body
            in
            MonoLet (setDefBound def dcedBound) dcedBody resultType

        MonoCall region func args resultType callInfo ->
            MonoCall region (dce func) (List.map dce args) resultType callInfo

        MonoClosure info body closureType ->
            let
                dcedCaptures =
                    List.map (\( n, e, isUnboxed ) -> ( n, dce e, isUnboxed )) info.captures
            in
            MonoClosure { info | captures = dcedCaptures } (dce body) closureType

        MonoList region items itemType ->
            MonoList region (List.map dce items) itemType

        MonoIf branches final resultType ->
            MonoIf
                (List.map (\( c, t ) -> ( dce c, dce t )) branches)
                (dce final)
                resultType

        MonoDestruct destructor inner resultType ->
            MonoDestruct destructor (dce inner) resultType

        MonoCase scrutName scrutType decider branches resultType ->
            MonoCase scrutName
                scrutType
                decider
                (List.map (\( idx, e ) -> ( idx, dce e )) branches)
                resultType

        MonoRecordCreate fields recordType ->
            MonoRecordCreate (List.map (\( n, e ) -> ( n, dce e )) fields) recordType

        MonoRecordAccess inner fieldName resultType ->
            MonoRecordAccess (dce inner) fieldName resultType

        MonoRecordUpdate inner updates recordType ->
            MonoRecordUpdate (dce inner) (List.map (\( n, e ) -> ( n, dce e )) updates) recordType

        MonoTupleCreate region items tupleType ->
            MonoTupleCreate region (List.map dce items) tupleType

        MonoTailCall name args resultType ->
            MonoTailCall name (List.map (\( n, e ) -> ( n, dce e )) args) resultType

        _ ->
            expr



-- ============================================================================
-- ====== METRICS COLLECTION ======
-- ============================================================================


countClosures : MonoExpr -> Int
countClosures expr =
    case expr of
        MonoClosure _ body _ ->
            1 + countClosures body

        MonoCall _ func args _ _ ->
            countClosures func + List.sum (List.map countClosures args)

        MonoLet def body _ ->
            countClosuresInDef def + countClosures body

        MonoIf branches final _ ->
            List.sum (List.map (\( c, t ) -> countClosures c + countClosures t) branches)
                + countClosures final

        MonoDestruct _ inner _ ->
            countClosures inner

        MonoCase _ _ _ branches _ ->
            List.sum (List.map (\( _, e ) -> countClosures e) branches)

        MonoList _ items _ ->
            List.sum (List.map countClosures items)

        MonoRecordCreate fields _ ->
            List.sum (List.map (\( _, e ) -> countClosures e) fields)

        MonoRecordAccess inner _ _ ->
            countClosures inner

        MonoRecordUpdate inner updates _ ->
            countClosures inner + List.sum (List.map (\( _, e ) -> countClosures e) updates)

        MonoTupleCreate _ items _ ->
            List.sum (List.map countClosures items)

        MonoTailCall _ args _ ->
            List.sum (List.map (\( _, e ) -> countClosures e) args)

        _ ->
            0


countClosuresInDef : Mono.MonoDef -> Int
countClosuresInDef def =
    case def of
        Mono.MonoDef _ bound ->
            countClosures bound

        Mono.MonoTailDef _ _ bound ->
            countClosures bound


countClosuresInNode : MonoNode -> Int
countClosuresInNode node =
    case node of
        MonoDefine expr _ ->
            countClosures expr

        MonoTailFunc _ expr _ ->
            countClosures expr

        MonoCycle defs _ ->
            List.sum (List.map (\( _, e ) -> countClosures e) defs)

        MonoPortIncoming expr _ ->
            countClosures expr

        MonoPortOutgoing expr _ ->
            countClosures expr

        _ ->
            0


countClosuresInGraph : Dict Int SpecId MonoNode -> Int
countClosuresInGraph nodes =
    Dict.foldl compare
        (\_ node acc -> acc + countClosuresInNode node)
        0
        nodes
