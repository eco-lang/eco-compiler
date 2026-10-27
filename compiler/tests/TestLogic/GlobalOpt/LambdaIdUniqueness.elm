module TestLogic.GlobalOpt.LambdaIdUniqueness exposing
    ( expectLambdaIdUniqueness
    , lambdaIdIssues
    )

{-| `MONO_019` says that within one `MonoGraph` each `lambdaId` names one logical
lambda: no two `MonoClosure` nodes share a `lambdaId`. Code generation emits a
nested closure as a function named after its `lambdaId`
(`Compiler.Generate.MLIR.Expr.lambdaIdToString`), so two closures sharing one
would be two functions under one symbol. This module holds the check for that,
run on the graphs a test program goes through.

`expectLambdaIdUniqueness` takes a source module and runs it through
`TestLogic.TestPipeline.runToGlobalOpt`, failing if that run fails. It then
checks three graphs from that one run:

  - the graph straight after monomorphization (`monoGraph`);
  - the graph after the global optimizer (`optimizedMonoGraph`), which is the
    one the invariant is stated for, since the inliner copies closure bodies
    and must give each copy a fresh `lambdaId`;
  - that graph after `Compiler.GlobalOpt.CafHoist.run` at the settings
    `Compiler.Eco.Config.default` gives it, though hoisting is off by default,
    because the pass moves closures into new specs.

It fails with one line per `lambdaId` found more than once in a graph, naming
the graph, the `lambdaId`, and the `SpecId` of every node an occurrence is in.

The closures looked at are every `MonoClosure` in the expression of a
`MonoDefine`, `MonoTailFunc` or port node, at any depth: in calls, closure
captures and bodies, `let` definitions (both kinds), `if` and `case` branches
(both the bodies a decision tree holds inline and those it jumps to),
destructuring, records, tuples, lists and tail-call arguments.

Among what is not checked: `ClosureInfo.srcLambda`, which `MONO_019` explicitly
allows to repeat; `CallInfo.fastEvaluator`, which names a `lambdaId` rather than
defining one; and whether a closure found twice is the same closure reached
twice, since an expression tree reaches each node once.

-}

import Array
import Compiler.AST.Monomorphized as Mono
import Compiler.AST.Source as Src
import Compiler.Eco.Config as Config
import Compiler.Elm.ModuleName as ModuleName
import Compiler.GlobalOpt.CafHoist as CafHoist
import Dict exposing (Dict)
import Expect
import TestLogic.TestPipeline as Pipeline


{-| Returns an expectation that runs `srcModule` through the global optimizer
and passes when no `lambdaId` occurs twice in any of the three graphs the
module docstring lists. It fails with the pipeline's error if the run fails,
and otherwise with one line per repeated `lambdaId`.
-}
expectLambdaIdUniqueness : Src.Module -> Expect.Expectation
expectLambdaIdUniqueness srcModule =
    case Pipeline.runToGlobalOpt srcModule of
        Err msg ->
            Expect.fail msg

        Ok { monoGraph, optimizedMonoGraph } ->
            let
                hoistCfg =
                    Config.default.cafMemo.hoist

                ( hoistedGraph, _ ) =
                    CafHoist.run
                        { minNodes = hoistCfg.minNodes, maxHoists = hoistCfg.maxHoists }
                        optimizedMonoGraph

                issues =
                    lambdaIdIssues "after monomorphization" monoGraph
                        ++ lambdaIdIssues "after GlobalOpt" optimizedMonoGraph
                        ++ lambdaIdIssues "after GlobalOpt + CafHoist" hoistedGraph
            in
            if List.isEmpty issues then
                Expect.pass

            else
                Expect.fail (String.join "\n" issues)


{-| Returns one line for each `lambdaId` that occurs more than once in
`graph`, each beginning with `label`. The list is empty when every `lambdaId`
is unique.
-}
lambdaIdIssues : String -> Mono.MonoGraph -> List String
lambdaIdIssues label (Mono.MonoGraph data) =
    let
        occurrences : Dict ( List String, Int ) (List Int)
        occurrences =
            Array.foldl
                (\maybeNode ( specId, acc ) ->
                    case maybeNode of
                        Nothing ->
                            ( specId + 1, acc )

                        Just node ->
                            ( specId + 1
                            , List.foldl
                                (\lid d ->
                                    Dict.update (lambdaKey lid)
                                        (\prev -> Just (specId :: Maybe.withDefault [] prev))
                                        d
                                )
                                acc
                                (nodeLambdaIds node)
                            )
                )
                ( 0, Dict.empty )
                data.nodes
                |> Tuple.second
    in
    Dict.foldr
        (\key specIds acc ->
            if List.length specIds > 1 then
                (label
                    ++ " [MONO_019]: lambdaId "
                    ++ renderKey key
                    ++ " occurs "
                    ++ String.fromInt (List.length specIds)
                    ++ " times, in SpecIds "
                    ++ String.join ", " (List.map String.fromInt (List.reverse specIds))
                )
                    :: acc

            else
                acc
        )
        []
        occurrences


{-| A comparable key for a `lambdaId`: its module's package author and name,
its module name, and its index.
-}
lambdaKey : Mono.LambdaId -> ( List String, Int )
lambdaKey (Mono.AnonymousLambda (ModuleName.Canonical ( author, project ) moduleName) index) =
    ( [ author, project, moduleName ], index )


{-| Renders a `lambdaKey` as `author/project/Module.Name#index`.
-}
renderKey : ( List String, Int ) -> String
renderKey ( parts, index ) =
    String.join "/" parts ++ "#" ++ String.fromInt index


{-| Returns the `lambdaId` of every closure in the expression of one node.
Only `MonoDefine`, `MonoTailFunc` and port nodes hold an expression.
-}
nodeLambdaIds : Mono.MonoNode -> List Mono.LambdaId
nodeLambdaIds node =
    case node of
        Mono.MonoDefine expr _ ->
            exprLambdaIds expr []

        Mono.MonoTailFunc _ expr _ ->
            exprLambdaIds expr []

        Mono.MonoPortIncoming expr _ ->
            exprLambdaIds expr []

        Mono.MonoPortOutgoing expr _ ->
            exprLambdaIds expr []

        _ ->
            []


{-| Adds the `lambdaId` of every closure in `expr`, at any depth, to `acc`.
-}
exprLambdaIds : Mono.MonoExpr -> List Mono.LambdaId -> List Mono.LambdaId
exprLambdaIds expr acc =
    case expr of
        Mono.MonoClosure info body _ ->
            List.foldl (\( _, e, _ ) a -> exprLambdaIds e a)
                (exprLambdaIds body (info.lambdaId :: acc))
                info.captures

        Mono.MonoCall _ func args _ _ ->
            List.foldl exprLambdaIds (exprLambdaIds func acc) args

        Mono.MonoTailCall _ args _ ->
            List.foldl (\( _, e ) a -> exprLambdaIds e a) acc args

        Mono.MonoIf branches final _ ->
            List.foldl (\( c, t ) a -> exprLambdaIds t (exprLambdaIds c a))
                (exprLambdaIds final acc)
                branches

        Mono.MonoLet def body _ ->
            exprLambdaIds body (exprLambdaIds (defBound def) acc)

        Mono.MonoDestruct _ body _ ->
            exprLambdaIds body acc

        Mono.MonoCase _ _ decider branches _ ->
            List.foldl (\( _, e ) a -> exprLambdaIds e a)
                (deciderLambdaIds decider acc)
                branches

        Mono.MonoList _ items _ ->
            List.foldl exprLambdaIds acc items

        Mono.MonoRecordCreate fields _ ->
            List.foldl (\( _, e ) a -> exprLambdaIds e a) acc fields

        Mono.MonoRecordAccess inner _ _ ->
            exprLambdaIds inner acc

        Mono.MonoRecordUpdate inner updates _ ->
            List.foldl (\( _, e ) a -> exprLambdaIds e a) (exprLambdaIds inner acc) updates

        Mono.MonoTupleCreate _ items _ ->
            List.foldl exprLambdaIds acc items

        Mono.MonoLiteral _ _ ->
            acc

        Mono.MonoVarLocal _ _ ->
            acc

        Mono.MonoVarGlobal _ _ _ ->
            acc

        Mono.MonoVarKernel _ _ _ _ _ ->
            acc

        Mono.MonoUnit ->
            acc

        Mono.MonoAccessorValue _ _ _ ->
            acc


{-| Adds the `lambdaId`s in the bodies a decision tree holds inline. A `Jump`
leaf adds none: its body is one of the `case`'s branches.
-}
deciderLambdaIds : Mono.Decider Mono.MonoChoice -> List Mono.LambdaId -> List Mono.LambdaId
deciderLambdaIds decider acc =
    case decider of
        Mono.Leaf (Mono.Inline e) ->
            exprLambdaIds e acc

        Mono.Leaf (Mono.Jump _) ->
            acc

        Mono.Chain _ success failure ->
            deciderLambdaIds failure (deciderLambdaIds success acc)

        Mono.FanOut _ edges fallback ->
            deciderLambdaIds fallback
                (List.foldl (\( _, d ) a -> deciderLambdaIds d a) acc edges)


{-| Returns the expression a `let` definition binds, for either kind of
definition.
-}
defBound : Mono.MonoDef -> Mono.MonoExpr
defBound def =
    case def of
        Mono.MonoDef _ bound ->
            bound

        Mono.MonoTailDef _ _ bound ->
            bound
