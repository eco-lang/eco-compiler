module TestLogic.Monomorphize.MonoVarGlobalArityConsistency exposing (expectVarGlobalArityConsistency)

{-| Test logic for invariant MONO\_027: MonoVarGlobal type arity matches node arity.

For every MonoVarGlobal(region, specId, monoType) in the optimized MonoGraph,
the flattened function arity of monoType must equal the flattened function arity
of the referenced node's type at graph.nodes[specId].

A mismatch indicates that buildCurriedFuncType (or similar) produced a truncated
function type for a partial application, losing unsupplied parameter stages.

This check runs after GlobalOpt since staging canonicalization (GOPT\_001) may
adjust node arities.

-}

import Array
import Compiler.AST.Monomorphized as Mono
import Compiler.AST.Source as Src
import Expect
import TestLogic.TestPipeline as Pipeline


{-| MONO\_027: Verify MonoVarGlobal type arity matches referenced node arity.
-}
expectVarGlobalArityConsistency : Src.Module -> Expect.Expectation
expectVarGlobalArityConsistency srcModule =
    case Pipeline.runToGlobalOpt srcModule of
        Err msg ->
            Expect.fail msg

        Ok { optimizedMonoGraph } ->
            let
                issues =
                    collectVarGlobalArityIssues optimizedMonoGraph

                callChainIssues =
                    collectCallChainOverApplication optimizedMonoGraph

                callArgExceedsTypeIssues =
                    collectCallArgExceedsNodeArity optimizedMonoGraph
            in
            let
                allIssues =
                    issues ++ callChainIssues ++ callArgExceedsTypeIssues
            in
            if List.isEmpty allIssues then
                Expect.pass

            else
                Expect.fail (String.join "\n" allIssues)



-- ============================================================================
-- GRAPH WALKER
-- ============================================================================


{-| Collect all VarGlobal arity mismatch issues in the graph.
-}
collectVarGlobalArityIssues : Mono.MonoGraph -> List String
collectVarGlobalArityIssues ((Mono.MonoGraph data) as graph) =
    Array.foldl
        (\maybeNode ( specId, acc ) ->
            case maybeNode of
                Nothing ->
                    ( specId + 1, acc )

                Just node ->
                    ( specId + 1, checkNode graph specId node ++ acc )
        )
        ( 0, [] )
        data.nodes
        |> Tuple.second


checkNode : Mono.MonoGraph -> Int -> Mono.MonoNode -> List String
checkNode graph specId node =
    let
        ctx =
            "SpecId " ++ String.fromInt specId
    in
    case node of
        Mono.MonoDefine expr _ ->
            collectExprIssues graph ctx expr

        Mono.MonoTailFunc _ expr _ ->
            collectExprIssues graph ctx expr

        Mono.MonoPortIncoming expr _ ->
            collectExprIssues graph ctx expr

        Mono.MonoPortOutgoing expr _ ->
            collectExprIssues graph ctx expr

        Mono.MonoCycle defs _ ->
            List.concatMap (\( _, e ) -> collectExprIssues graph ctx e) defs

        _ ->
            []


collectExprIssues : Mono.MonoGraph -> String -> Mono.MonoExpr -> List String
collectExprIssues graph ctx expr =
    case expr of
        Mono.MonoVarGlobal _ refSpecId monoType ->
            checkVarGlobalArity graph ctx refSpecId monoType

        Mono.MonoCall _ funcExpr args _ _ ->
            collectExprIssues graph ctx funcExpr
                ++ List.concatMap (collectExprIssues graph ctx) args

        Mono.MonoClosure closureInfo bodyExpr _ ->
            List.concatMap (\( _, e, _ ) -> collectExprIssues graph ctx e) closureInfo.captures
                ++ collectExprIssues graph ctx bodyExpr

        Mono.MonoLet def bodyExpr _ ->
            collectDefIssues graph ctx def
                ++ collectExprIssues graph ctx bodyExpr

        Mono.MonoIf branches elseExpr _ ->
            List.concatMap (\( c, t ) -> collectExprIssues graph ctx c ++ collectExprIssues graph ctx t) branches
                ++ collectExprIssues graph ctx elseExpr

        Mono.MonoCase _ _ decider branches _ ->
            collectDeciderIssues graph ctx decider
                ++ List.concatMap (\( _, e ) -> collectExprIssues graph ctx e) branches

        Mono.MonoDestruct _ valueExpr _ ->
            collectExprIssues graph ctx valueExpr

        Mono.MonoList _ exprs _ ->
            List.concatMap (collectExprIssues graph ctx) exprs

        Mono.MonoRecordCreate fieldExprs _ ->
            List.concatMap (\( _, e ) -> collectExprIssues graph ctx e) fieldExprs

        Mono.MonoRecordAccess recordExpr _ _ ->
            collectExprIssues graph ctx recordExpr

        Mono.MonoRecordUpdate recordExpr updates _ ->
            collectExprIssues graph ctx recordExpr
                ++ List.concatMap (\( _, e ) -> collectExprIssues graph ctx e) updates

        Mono.MonoTupleCreate _ elementExprs _ ->
            List.concatMap (collectExprIssues graph ctx) elementExprs

        Mono.MonoTailCall _ args _ ->
            List.concatMap (\( _, e ) -> collectExprIssues graph ctx e) args

        _ ->
            []


collectDefIssues : Mono.MonoGraph -> String -> Mono.MonoDef -> List String
collectDefIssues graph ctx def =
    case def of
        Mono.MonoDef _ expr ->
            collectExprIssues graph ctx expr

        Mono.MonoTailDef _ _ expr ->
            collectExprIssues graph ctx expr


collectDeciderIssues : Mono.MonoGraph -> String -> Mono.Decider Mono.MonoChoice -> List String
collectDeciderIssues graph ctx decider =
    case decider of
        Mono.Leaf choice ->
            case choice of
                Mono.Inline expr ->
                    collectExprIssues graph ctx expr

                Mono.Jump _ ->
                    []

        Mono.Chain _ success failure ->
            collectDeciderIssues graph ctx success
                ++ collectDeciderIssues graph ctx failure

        Mono.FanOut _ edges fallback ->
            List.concatMap (\( _, d ) -> collectDeciderIssues graph ctx d) edges
                ++ collectDeciderIssues graph ctx fallback



-- ============================================================================
-- ARITY CHECK
-- ============================================================================


{-| Check that a MonoVarGlobal's type arity matches the referenced node's arity.
-}
checkVarGlobalArity : Mono.MonoGraph -> String -> Mono.SpecId -> Mono.MonoType -> List String
checkVarGlobalArity (Mono.MonoGraph data) ctx refSpecId varType =
    case Array.get refSpecId data.nodes of
        Nothing ->
            -- Node pruned or not present; other invariants (MONO_011) handle this
            []

        Just Nothing ->
            -- Slot exists but empty (pruned)
            []

        Just (Just node) ->
            if not (isArityCheckableNode node) then
                []

            else
                let
                        varArity =
                            getFlattenedArity varType

                        nodeArity =
                            getFlattenedArity (Mono.nodeType node)
                    in
                    if varArity /= nodeArity then
                        [ ctx
                            ++ " [MONO_027]: MonoVarGlobal referencing SpecId "
                            ++ String.fromInt refSpecId
                            ++ " has flattened arity "
                            ++ String.fromInt varArity
                            ++ " (type: "
                            ++ Debug.toString varType
                            ++ ") but node has flattened arity "
                            ++ String.fromInt nodeArity
                            ++ " (type: "
                            ++ Debug.toString (Mono.nodeType node)
                            ++ ") nodeKind="
                            ++ nodeKindName node
                            ++ ")"
                        ]

                    else
                        []



-- ============================================================================
-- CALL CHAIN OVER-APPLICATION CHECK
-- ============================================================================


{-| Collect issues where nested MonoCall chains apply more args than a function's
node type supports.

When we see `MonoCall (MonoCall (MonoVarGlobal specId type) innerArgs) outerArgs`,
the total arguments are `innerArgs ++ outerArgs`. We verify this total does not
exceed the flattened arity of the referenced node.

This catches the case where buildCurriedFuncType truncates the type but BOTH the
VarGlobal type and node type agree on the wrong arity — the over-application
is detectable only by seeing that the call result (a non-function type) is used
as a callee in another call.

-}
collectCallChainOverApplication : Mono.MonoGraph -> List String
collectCallChainOverApplication ((Mono.MonoGraph data) as graph) =
    Array.foldl
        (\maybeNode ( specId, acc ) ->
            case maybeNode of
                Nothing ->
                    ( specId + 1, acc )

                Just node ->
                    ( specId + 1, checkNodeCallChains graph ("SpecId " ++ String.fromInt specId) node ++ acc )
        )
        ( 0, [] )
        data.nodes
        |> Tuple.second


checkNodeCallChains : Mono.MonoGraph -> String -> Mono.MonoNode -> List String
checkNodeCallChains graph ctx node =
    case node of
        Mono.MonoDefine expr _ ->
            collectCallChainExprIssues graph ctx expr

        Mono.MonoTailFunc _ expr _ ->
            collectCallChainExprIssues graph ctx expr

        Mono.MonoPortIncoming expr _ ->
            collectCallChainExprIssues graph ctx expr

        Mono.MonoPortOutgoing expr _ ->
            collectCallChainExprIssues graph ctx expr

        Mono.MonoCycle defs _ ->
            List.concatMap (\( _, e ) -> collectCallChainExprIssues graph ctx e) defs

        _ ->
            []


collectCallChainExprIssues : Mono.MonoGraph -> String -> Mono.MonoExpr -> List String
collectCallChainExprIssues graph ctx expr =
    case expr of
        Mono.MonoCall _ funcExpr args _ _ ->
            -- Check if this is a nested call chain
            checkCallChain graph ctx funcExpr (List.length args)
                ++ collectCallChainExprIssues graph ctx funcExpr
                ++ List.concatMap (collectCallChainExprIssues graph ctx) args

        Mono.MonoClosure closureInfo bodyExpr _ ->
            List.concatMap (\( _, e, _ ) -> collectCallChainExprIssues graph ctx e) closureInfo.captures
                ++ collectCallChainExprIssues graph ctx bodyExpr

        Mono.MonoLet def bodyExpr _ ->
            collectCallChainDefIssues graph ctx def
                ++ collectCallChainExprIssues graph ctx bodyExpr

        Mono.MonoIf branches elseExpr _ ->
            List.concatMap (\( c, t ) -> collectCallChainExprIssues graph ctx c ++ collectCallChainExprIssues graph ctx t) branches
                ++ collectCallChainExprIssues graph ctx elseExpr

        Mono.MonoCase _ _ decider branches _ ->
            collectCallChainDeciderIssues graph ctx decider
                ++ List.concatMap (\( _, e ) -> collectCallChainExprIssues graph ctx e) branches

        Mono.MonoDestruct _ valueExpr _ ->
            collectCallChainExprIssues graph ctx valueExpr

        Mono.MonoList _ exprs _ ->
            List.concatMap (collectCallChainExprIssues graph ctx) exprs

        Mono.MonoRecordCreate fieldExprs _ ->
            List.concatMap (\( _, e ) -> collectCallChainExprIssues graph ctx e) fieldExprs

        Mono.MonoRecordAccess recordExpr _ _ ->
            collectCallChainExprIssues graph ctx recordExpr

        Mono.MonoRecordUpdate recordExpr updates _ ->
            collectCallChainExprIssues graph ctx recordExpr
                ++ List.concatMap (\( _, e ) -> collectCallChainExprIssues graph ctx e) updates

        Mono.MonoTupleCreate _ elementExprs _ ->
            List.concatMap (collectCallChainExprIssues graph ctx) elementExprs

        Mono.MonoTailCall _ args _ ->
            List.concatMap (\( _, e ) -> collectCallChainExprIssues graph ctx e) args

        _ ->
            []


collectCallChainDefIssues : Mono.MonoGraph -> String -> Mono.MonoDef -> List String
collectCallChainDefIssues graph ctx def =
    case def of
        Mono.MonoDef _ expr ->
            collectCallChainExprIssues graph ctx expr

        Mono.MonoTailDef _ _ expr ->
            collectCallChainExprIssues graph ctx expr


collectCallChainDeciderIssues : Mono.MonoGraph -> String -> Mono.Decider Mono.MonoChoice -> List String
collectCallChainDeciderIssues graph ctx decider =
    case decider of
        Mono.Leaf choice ->
            case choice of
                Mono.Inline expr ->
                    collectCallChainExprIssues graph ctx expr

                Mono.Jump _ ->
                    []

        Mono.Chain _ success failure ->
            collectCallChainDeciderIssues graph ctx success
                ++ collectCallChainDeciderIssues graph ctx failure

        Mono.FanOut _ edges fallback ->
            List.concatMap (\( _, d ) -> collectCallChainDeciderIssues graph ctx d) edges
                ++ collectCallChainDeciderIssues graph ctx fallback


{-| Check a call expression for over-application through call chains.

Given `MonoCall funcExpr outerArgs`, check if funcExpr is itself a call
to a known global. If so, sum all args and compare against the node's arity.

-}
checkCallChain : Mono.MonoGraph -> String -> Mono.MonoExpr -> Int -> List String
checkCallChain (Mono.MonoGraph data) ctx funcExpr outerArgCount =
    case funcExpr of
        Mono.MonoCall _ innerFuncExpr innerArgs _ _ ->
            let
                totalArgs =
                    List.length innerArgs + outerArgCount
            in
            case innerFuncExpr of
                Mono.MonoVarGlobal _ refSpecId _ ->
                    case Array.get refSpecId data.nodes of
                        Just (Just node) ->
                            if not (isArityCheckableNode node) then
                                []

                            else
                                let
                                    nodeArity =
                                        getFlattenedArity (Mono.nodeType node)
                                in
                                if nodeArity > 0 && totalArgs > nodeArity then
                                    [ ctx
                                        ++ " [MONO_027]: Call chain to SpecId "
                                        ++ String.fromInt refSpecId
                                        ++ " applies "
                                        ++ String.fromInt totalArgs
                                        ++ " total args but node has flattened arity "
                                        ++ String.fromInt nodeArity
                                    ++ " (nodeType: "
                                    ++ Debug.toString (Mono.nodeType node)
                                    ++ " nodeKind="
                                    ++ nodeKindName node
                                    ++ ")"
                                ]

                            else
                                []

                        _ ->
                            []

                -- Recurse deeper for longer chains: call(call(call(f, a), b), c)
                Mono.MonoCall _ _ _ _ _ ->
                    checkCallChain (Mono.MonoGraph data) ctx innerFuncExpr totalArgs

                _ ->
                    []

        _ ->
            []



-- ============================================================================
-- CALL ARG COUNT vs NODE ARITY CHECK
-- ============================================================================


{-| For every MonoCall whose callee is a MonoVarGlobal, verify the arg count
does not exceed the referenced node's flattened arity.

Unlike the MONO_012 check which compares against the VarGlobal's carried type
(which may be truncated), this compares against the actual node type in the graph.

-}
collectCallArgExceedsNodeArity : Mono.MonoGraph -> List String
collectCallArgExceedsNodeArity ((Mono.MonoGraph data) as graph) =
    Array.foldl
        (\maybeNode ( specId, acc ) ->
            case maybeNode of
                Nothing ->
                    ( specId + 1, acc )

                Just node ->
                    ( specId + 1, checkNodeCallArgs graph ("SpecId " ++ String.fromInt specId) node ++ acc )
        )
        ( 0, [] )
        data.nodes
        |> Tuple.second


checkNodeCallArgs : Mono.MonoGraph -> String -> Mono.MonoNode -> List String
checkNodeCallArgs graph ctx node =
    case node of
        Mono.MonoDefine expr _ ->
            collectCallArgExprIssues graph ctx expr

        Mono.MonoTailFunc _ expr _ ->
            collectCallArgExprIssues graph ctx expr

        Mono.MonoPortIncoming expr _ ->
            collectCallArgExprIssues graph ctx expr

        Mono.MonoPortOutgoing expr _ ->
            collectCallArgExprIssues graph ctx expr

        Mono.MonoCycle defs _ ->
            List.concatMap (\( _, e ) -> collectCallArgExprIssues graph ctx e) defs

        _ ->
            []


collectCallArgExprIssues : Mono.MonoGraph -> String -> Mono.MonoExpr -> List String
collectCallArgExprIssues graph ctx expr =
    case expr of
        Mono.MonoCall _ funcExpr args _ _ ->
            checkDirectCallArgs graph ctx funcExpr args
                ++ collectCallArgExprIssues graph ctx funcExpr
                ++ List.concatMap (collectCallArgExprIssues graph ctx) args

        Mono.MonoClosure closureInfo bodyExpr _ ->
            List.concatMap (\( _, e, _ ) -> collectCallArgExprIssues graph ctx e) closureInfo.captures
                ++ collectCallArgExprIssues graph ctx bodyExpr

        Mono.MonoLet def bodyExpr _ ->
            (case def of
                Mono.MonoDef _ e ->
                    collectCallArgExprIssues graph ctx e

                Mono.MonoTailDef _ _ e ->
                    collectCallArgExprIssues graph ctx e
            )
                ++ collectCallArgExprIssues graph ctx bodyExpr

        Mono.MonoIf branches elseExpr _ ->
            List.concatMap (\( c, t ) -> collectCallArgExprIssues graph ctx c ++ collectCallArgExprIssues graph ctx t) branches
                ++ collectCallArgExprIssues graph ctx elseExpr

        Mono.MonoCase _ _ decider branches _ ->
            collectCallArgDeciderIssues graph ctx decider
                ++ List.concatMap (\( _, e ) -> collectCallArgExprIssues graph ctx e) branches

        Mono.MonoDestruct _ valueExpr _ ->
            collectCallArgExprIssues graph ctx valueExpr

        Mono.MonoList _ exprs _ ->
            List.concatMap (collectCallArgExprIssues graph ctx) exprs

        Mono.MonoRecordCreate fieldExprs _ ->
            List.concatMap (\( _, e ) -> collectCallArgExprIssues graph ctx e) fieldExprs

        Mono.MonoRecordAccess recordExpr _ _ ->
            collectCallArgExprIssues graph ctx recordExpr

        Mono.MonoRecordUpdate recordExpr updates _ ->
            collectCallArgExprIssues graph ctx recordExpr
                ++ List.concatMap (\( _, e ) -> collectCallArgExprIssues graph ctx e) updates

        Mono.MonoTupleCreate _ elementExprs _ ->
            List.concatMap (collectCallArgExprIssues graph ctx) elementExprs

        Mono.MonoTailCall _ args _ ->
            List.concatMap (\( _, e ) -> collectCallArgExprIssues graph ctx e) args

        _ ->
            []


collectCallArgDeciderIssues : Mono.MonoGraph -> String -> Mono.Decider Mono.MonoChoice -> List String
collectCallArgDeciderIssues graph ctx decider =
    case decider of
        Mono.Leaf choice ->
            case choice of
                Mono.Inline expr ->
                    collectCallArgExprIssues graph ctx expr

                Mono.Jump _ ->
                    []

        Mono.Chain _ success failure ->
            collectCallArgDeciderIssues graph ctx success
                ++ collectCallArgDeciderIssues graph ctx failure

        Mono.FanOut _ edges fallback ->
            List.concatMap (\( _, d ) -> collectCallArgDeciderIssues graph ctx d) edges
                ++ collectCallArgDeciderIssues graph ctx fallback


{-| Check a direct MonoCall: if callee is MonoVarGlobal, compare arg count
against the actual node's arity (not the VarGlobal's carried type).
-}
checkDirectCallArgs : Mono.MonoGraph -> String -> Mono.MonoExpr -> List Mono.MonoExpr -> List String
checkDirectCallArgs (Mono.MonoGraph data) ctx funcExpr args =
    case funcExpr of
        Mono.MonoVarGlobal _ refSpecId varType ->
            case Array.get refSpecId data.nodes of
                Just (Just node) ->
                    if not (isArityCheckableNode node) then
                        []

                    else
                        let
                            argCount =
                                List.length args

                            nodeArity =
                                getFlattenedArity (Mono.nodeType node)

                            varArity =
                                getFlattenedArity varType
                        in
                        if nodeArity > 0 && argCount > nodeArity then
                        [ ctx
                            ++ " [MONO_027]: MonoCall to SpecId "
                            ++ String.fromInt refSpecId
                            ++ " has "
                            ++ String.fromInt argCount
                            ++ " args but node has flattened arity "
                            ++ String.fromInt nodeArity
                            ++ " (varType arity="
                            ++ String.fromInt varArity
                            ++ ", nodeType: "
                            ++ Debug.toString (Mono.nodeType node)
                            ++ " nodeKind="
                            ++ nodeKindName node
                            ++ ")"
                        ]

                    else
                        []

                _ ->
                    []

        _ ->
            []





{-| Is this a node kind where VarGlobal type arity comparison is meaningful?
Constructor, enum, extern, and manager nodes store only the result type,
not a function type, so arity comparison is not applicable.
-}
isArityCheckableNode : Mono.MonoNode -> Bool
isArityCheckableNode node =
    case node of
        Mono.MonoCtor _ _ ->
            False

        Mono.MonoEnum _ _ ->
            False

        Mono.MonoExtern _ ->
            False

        Mono.MonoManagerLeaf _ _ ->
            False

        _ ->
            True


{-| Human-readable name for a MonoNode variant.
-}
nodeKindName : Mono.MonoNode -> String
nodeKindName node =
    case node of
        Mono.MonoDefine _ _ ->
            "MonoDefine"

        Mono.MonoTailFunc _ _ _ ->
            "MonoTailFunc"

        Mono.MonoCtor _ _ ->
            "MonoCtor"

        Mono.MonoEnum _ _ ->
            "MonoEnum"

        Mono.MonoExtern _ ->
            "MonoExtern"

        Mono.MonoManagerLeaf _ _ ->
            "MonoManagerLeaf"

        Mono.MonoPortIncoming _ _ ->
            "MonoPortIncoming"

        Mono.MonoPortOutgoing _ _ ->
            "MonoPortOutgoing"

        Mono.MonoCycle _ _ ->
            "MonoCycle"


{-| Flatten a curried function type into total parameter count.

For example, `MFunction [a] (MFunction [b] c)` has flattened arity 2.
Non-function types have flattened arity 0.

-}
getFlattenedArity : Mono.MonoType -> Int
getFlattenedArity monoType =
    case monoType of
        Mono.MFunction params result ->
            List.length params + getFlattenedArity result

        _ ->
            0
