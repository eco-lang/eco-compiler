module TestLogic.Monomorphize.MonoVarGlobalArityConsistency exposing (expectVarGlobalArityConsistency)

{-| Checks that the references to a specialization in a monomorphized graph
agree with the specialization's node about how many parameters it takes.

A monomorphized program is a graph of nodes indexed by SpecId, one per
specialization of a top-level definition. An expression refers to one with a
`MonoVarGlobal`, which carries the SpecId and its own copy of the type. Nothing
in the graph makes that copy agree with the type stored on the node, so a
reference can claim fewer or more parameters than the node has, and a call
through it can supply more arguments than the node takes.

Monomorphization keeps currying, and global optimization regroups parameters
into stages, so one function type may be a chain of `MFunction`s, each with its
own parameter list. The checks here therefore count the _flattened arity_ of a
type: the parameters of every stage of the chain added together, which is 2 for
`a -> b -> c` however the two parameters are grouped, and 0 for a type that is
not a function.

`expectVarGlobalArityConsistency` runs a source module through
`TestLogic.TestPipeline.runToGlobalOpt`, which monomorphizes with the
substitution engine and then runs the inliner and the global optimizer, and
checks the optimized graph. Any pipeline failure fails the expectation. Three
checks are made over the bodies of the define, tail-function and port nodes,
visiting every subexpression, including closure captures, `let` definitions and
the branch bodies a `case` holds in its decision tree as well as in its jump
list:

  - every `MonoVarGlobal` has the same flattened arity as its node's type;
  - a call whose callee is itself a call, as in `(f a) b`, does not supply more
    arguments in all, counted across every call in the chain, than the
    flattened arity of the node of the innermost callee `f` when that is a
    `MonoVarGlobal`. Two calls that are each within the arity can together
    exceed it;
  - a call whose callee is a `MonoVarGlobal` does not supply more arguments
    than the flattened arity of the node's type.
    `TestLogic.Generate.MonoFunctionArity` compares the same count with the type
    the callee expression carries.

The two call checks apply only when the node's flattened arity is above 0. A
failure lists every mismatch found, one per line, each naming the SpecId of the
node whose body it was found in.

Among what is not checked:

  - references to a SpecId with no node in the graph (out of range, or an
    empty slot);
  - references to constructor and enum nodes;
  - calls with fewer arguments than the node takes, which are partial
    applications;
  - calls whose innermost callee is not a `MonoVarGlobal`;
  - the graph before global optimization, and the graph the solver engine
    produces.

-}

import Array
import Compiler.AST.Monomorphized as Mono
import Compiler.AST.Source as Src
import Expect
import TestLogic.TestPipeline as Pipeline


{-| Creates an expectation that passes when `srcModule` compiles through global
optimization and the optimized graph has none of the three kinds of mismatch
the module docstring lists. On failure it lists every mismatch found, the
reference checks first, then the call-chain checks, then the direct-call checks.
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


{-| Returns a message for every `MonoVarGlobal` in the bodies of `graph`'s nodes
whose flattened arity differs from that of its node's type, when that node is
present and accepted by `isArityCheckableNode`. Messages from higher SpecIds
come first.
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


{-| Returns the reference-arity messages for the body of `node`, the node at
`specId`, each prefixed with that SpecId. A node with no body (constructor,
enum, extern, manager leaf) gives none.
-}
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

        _ ->
            []


{-| Returns the reference-arity messages for every `MonoVarGlobal` in `expr`, at
any depth, each prefixed with `ctx`. A call's callee is visited as well as its
arguments, and a `case`'s decision tree as well as its jump branches.
-}
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


{-| Returns the reference-arity messages for the body of a `let` definition.
-}
collectDefIssues : Mono.MonoGraph -> String -> Mono.MonoDef -> List String
collectDefIssues graph ctx def =
    case def of
        Mono.MonoDef _ expr ->
            collectExprIssues graph ctx expr

        Mono.MonoTailDef _ _ expr ->
            collectExprIssues graph ctx expr


{-| Returns the reference-arity messages for the branch bodies a decision tree
holds inline in its leaves. A `Jump` leaf gives none: its body is in the
`case`'s jump list.
-}
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


{-| Returns a message when a reference to `refSpecId` carrying `varType` has a
different flattened arity from the node at that SpecId, and nothing otherwise.
A SpecId with no node (out of range or an empty slot), and a node
`isArityCheckableNode` rejects, give nothing.
-}
checkVarGlobalArity : Mono.MonoGraph -> String -> Mono.SpecId -> Mono.MonoType -> List String
checkVarGlobalArity (Mono.MonoGraph data) ctx refSpecId varType =
    case Array.get refSpecId data.nodes of
        Nothing ->
            []

        Just Nothing ->
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


{-| Returns a message for every call chain in the bodies of `graph`'s nodes that
supplies more arguments than the node of its innermost callee takes, when that
node is present, accepted by `isArityCheckableNode` and of flattened arity
above 0.

A call chain is a call whose callee is itself a call, as in `(f a) b`. When
`f` is a `MonoVarGlobal`, the arguments of every call in the chain are added
together and compared with the flattened arity of `f`'s node. This finds an
over-application even when the reference and the node agree on a type with
too few parameters, where each call alone is within the arity. A chain is
checked once, at its outermost call. Messages from higher SpecIds come
first.

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


{-| Returns the call-chain messages for the body of `node`, each prefixed with
`ctx`. A node with no body gives none.
-}
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

        _ ->
            []


{-| Returns the call-chain messages for every call in `expr`, at any depth, each
prefixed with `ctx`. It visits the same subexpressions as `collectExprIssues`.
A chain is checked only at its outermost call: the shorter chains inside it
supply fewer arguments to the same innermost callee, so they cannot exceed an
arity the whole chain stays within, and checking them too would repeat its
message.
-}
collectCallChainExprIssues : Mono.MonoGraph -> String -> Mono.MonoExpr -> List String
collectCallChainExprIssues graph ctx expr =
    case expr of
        Mono.MonoCall _ funcExpr args _ _ ->
            checkCallChain graph ctx funcExpr (List.length args)
                ++ collectCallChainCalleeIssues graph ctx funcExpr
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


{-| Returns the call-chain messages inside `funcExpr`, the callee of a call
whose chain has already been checked: when `funcExpr` is itself a call, the
calls further down the same chain are not checked again, but their arguments
are walked; otherwise `funcExpr` is walked as `collectCallChainExprIssues`
walks it.
-}
collectCallChainCalleeIssues : Mono.MonoGraph -> String -> Mono.MonoExpr -> List String
collectCallChainCalleeIssues graph ctx funcExpr =
    case funcExpr of
        Mono.MonoCall _ innerFuncExpr innerArgs _ _ ->
            collectCallChainCalleeIssues graph ctx innerFuncExpr
                ++ List.concatMap (collectCallChainExprIssues graph ctx) innerArgs

        _ ->
            collectCallChainExprIssues graph ctx funcExpr


{-| Returns the call-chain messages for the body of a `let` definition.
-}
collectCallChainDefIssues : Mono.MonoGraph -> String -> Mono.MonoDef -> List String
collectCallChainDefIssues graph ctx def =
    case def of
        Mono.MonoDef _ expr ->
            collectCallChainExprIssues graph ctx expr

        Mono.MonoTailDef _ _ expr ->
            collectCallChainExprIssues graph ctx expr


{-| Returns the call-chain messages for the branch bodies a decision tree holds
inline in its leaves.
-}
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


{-| Returns a message when `funcExpr`, the callee of a call with
`outerArgCount` arguments, is itself a call, possibly nested, whose innermost
callee is a `MonoVarGlobal`, and the arguments of all the calls exceed the
flattened arity of that global's node.

It gives nothing when `funcExpr` is not a call, when the innermost callee is
not a `MonoVarGlobal`, when the SpecId has no node or `isArityCheckableNode`
rejects it, or when the node's flattened arity is 0.

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

                Mono.MonoCall _ _ _ _ _ ->
                    checkCallChain (Mono.MonoGraph data) ctx innerFuncExpr totalArgs

                _ ->
                    []

        _ ->
            []



-- ============================================================================
-- CALL ARG COUNT vs NODE ARITY CHECK
-- ============================================================================


{-| Returns a message for every call in the bodies of `graph`'s nodes whose
callee is a `MonoVarGlobal` and which supplies more arguments than the
flattened arity of the referenced node's type, when that node is present,
accepted by `isArityCheckableNode` and of flattened arity above 0. The count is
compared with the node's type, not with the type the reference carries.
Messages from higher SpecIds come first.
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


{-| Returns the direct-call messages for the body of `node`, each prefixed with
`ctx`. A node with no body gives none.
-}
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

        _ ->
            []


{-| Returns the direct-call messages for every call in `expr`, at any depth, each
prefixed with `ctx`. It visits the same subexpressions as `collectExprIssues`.
-}
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


{-| Returns the direct-call messages for the branch bodies a decision tree holds
inline in its leaves.
-}
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


{-| Returns a message when `funcExpr` is a `MonoVarGlobal` whose node is
present, accepted by `isArityCheckableNode` and of flattened arity above 0, and
`args` holds more arguments than that arity. The message also gives the
flattened arity of the type the reference carries.
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


{-| Tells whether references to `node` are checked at all: `False` for
constructor and enum nodes, `True` for the rest.

A constructor or enum node stores the type of the value it builds, not a
function type. An extern or manager-leaf node stores the type it was requested
at, which is a function type for a function-valued kernel or effect-manager
leaf, so references to those are checked like any other.

-}
isArityCheckableNode : Mono.MonoNode -> Bool
isArityCheckableNode node =
    case node of
        Mono.MonoCtor _ _ ->
            False

        Mono.MonoEnum _ _ ->
            False

        _ ->
            True


{-| Returns the name of `node`'s constructor, for failure messages.
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


{-| Returns the flattened arity of `monoType`: the parameter counts of every
stage of a chain of `MFunction`s added together, or 0 for a type that is not a
function. A function of one parameter returning a function of one parameter
gives 2, as does a function of two parameters.
-}
getFlattenedArity : Mono.MonoType -> Int
getFlattenedArity monoType =
    case monoType of
        Mono.MFunction _ _ params result ->
            List.length params + getFlattenedArity result

        _ ->
            0
