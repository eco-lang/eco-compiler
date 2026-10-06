module TestLogic.GlobalOpt.MonoInlineSimplifyTest exposing (suite)

{-| Tests for the post-monomorphization inliner,
`Compiler.GlobalOpt.MonoInlineSimplify.optimize`, run on its own, outside a
build: that it does the rewrite each small fixture is built for, and that over
the standard catalogue its output keeps two structural invariants.

The programs are turned into a monomorphized graph by
`TestLogic.TestPipeline.runToMono`, the production pipeline up to and
including monomorphization. The inliner is then called with
`Config.default.inline`. The optimized graph is not pruned afterwards, whereas
a default build prunes it.

The fixtures are four modules named `Test`, each with one annotated
`testValue : Int`: an `identity` function applied to 42, a `let` that binds 42
and returns it, the lambda `\x -> x` applied to 42, and two nested `let`s that
bind 1 and 2 and return the first. The last group uses every program in the
`SourceIR.Suite.StandardTestSuites` catalogue instead.

What the tests establish:

  - "Optimizer rewrites each fixture": the counter of the rewrite each fixture
    exists for is positive: `inlineCount` for the identity call,
    `letEliminations` for the single `let`, `betaReductions` for the applied
    lambda, and `letEliminations` of at least 2 for the nested `let`s.
  - "optimizes without errors", over the standard catalogue: `runToMono`
    succeeds; in the optimized graph no live node refers to a SpecId that has
    no node; and no `MonoDefine` holds a `MonoTailCall` other than one to a
    tail-recursive `let` definition in the same body, which is what inlining
    a `MonoTailFunc` body would leave behind.

A `runToMono` error fails every test with its message.

Among what is not tested: that the optimized graph computes the same values,
and the exact values of the counters.

-}

import Array
import Compiler.AST.Monomorphized as Mono
import Compiler.AST.Source as Src
import Compiler.AST.SourceBuilder
    exposing
        ( TypedDef
        , callExpr
        , define
        , intExpr
        , lambdaExpr
        , letExpr
        , makeModuleWithTypedDefsUnionsAliases
        , pVar
        , tLambda
        , tType
        , varExpr
        )
import Compiler.Eco.Config as Config
import Compiler.GlobalOpt.MonoInlineSimplify as MonoInlineSimplify
import Compiler.Monomorphize.MonoTraverse as MonoTraverse
import Expect
import SourceIR.Suite.StandardTestSuites as StandardTestSuites
import Test exposing (Test)
import TestLogic.TestPipeline as Pipeline


{-| All the tests of this module, in two groups.
-}
suite : Test
suite =
    Test.describe "MonoInlineSimplify"
        [ optimizerCompilesSuite
        , standardTestSuite
        ]



-- ============================================================================
-- FIXTURES, AND THE TESTS THAT THEY MONOMORPHIZE
-- ============================================================================


{-| The tests that the inliner does, on each of the four fixtures, the rewrite
the fixture is built for, as its metrics count it.
-}
optimizerCompilesSuite : Test
optimizerCompilesSuite =
    Test.describe "Optimizer rewrites each fixture"
        [ Test.test "a call of an identity function is inlined" <|
            \_ ->
                expectMetric "inlineCount" .inlineCount 1 simpleIdentityModule
        , Test.test "a let binding is eliminated" <|
            \_ ->
                expectMetric "letEliminations" .letEliminations 1 simpleLetModule
        , Test.test "a lambda applied directly is beta-reduced" <|
            \_ ->
                expectMetric "betaReductions" .betaReductions 1 lambdaApplicationModule
        , Test.test "both nested let bindings are eliminated" <|
            \_ ->
                expectMetric "letEliminations" .letEliminations 2 nestedLetModule
        ]


{-| Runs the inliner on the graph `runToMono` makes from `srcModule`, and
passes when the metric `read` returns, named `label`, is at least `atLeast`.
Fails with the pipeline's message when `runToMono` returns an error.
-}
expectMetric : String -> (MonoInlineSimplify.Metrics -> Int) -> Int -> Src.Module -> Expect.Expectation
expectMetric label read atLeast srcModule =
    case Pipeline.runToMono srcModule of
        Err msg ->
            Expect.fail ("Failed to create MonoGraph: " ++ msg)

        Ok { monoGraph } ->
            let
                ( _, metrics ) =
                    MonoInlineSimplify.optimize Config.default.inline monoGraph
            in
            if read metrics >= atLeast then
                Expect.pass

            else
                Expect.fail
                    ("expected " ++ label ++ " >= " ++ String.fromInt atLeast ++ ", got " ++ String.fromInt (read metrics))


{-| A module whose `testValue` calls an annotated identity function:

    identity : Int -> Int
    identity x =
        x

    testValue : Int
    testValue =
        identity 42

-}
simpleIdentityModule : Src.Module
simpleIdentityModule =
    let
        identityDef : TypedDef
        identityDef =
            { name = "identity"
            , args = [ pVar "x" ]
            , tipe = tLambda (tType "Int" []) (tType "Int" [])
            , body = varExpr "x"
            }

        testValueDef : TypedDef
        testValueDef =
            { name = "testValue"
            , args = []
            , tipe = tType "Int" []
            , body = callExpr (varExpr "identity") [ intExpr 42 ]
            }
    in
    makeModuleWithTypedDefsUnionsAliases "Test"
        [ identityDef, testValueDef ]
        []
        []


{-| A module whose `testValue` binds 42 in a `let` it never uses, so the
binding is dead and the inliner drops it:

    testValue : Int
    testValue =
        let
            x =
                42
        in
        7

-}
simpleLetModule : Src.Module
simpleLetModule =
    let
        testValueDef : TypedDef
        testValueDef =
            { name = "testValue"
            , args = []
            , tipe = tType "Int" []
            , body = letExpr [ define "x" [] (intExpr 42) ] (intExpr 7)
            }
    in
    makeModuleWithTypedDefsUnionsAliases "Test"
        [ testValueDef ]
        []
        []


{-| A module whose `testValue` applies a lambda directly to an argument:

    testValue : Int
    testValue =
        (\x -> x) 42

-}
lambdaApplicationModule : Src.Module
lambdaApplicationModule =
    let
        testValueDef : TypedDef
        testValueDef =
            { name = "testValue"
            , args = []
            , tipe = tType "Int" []
            , body =
                callExpr
                    (lambdaExpr [ pVar "x" ] (varExpr "x"))
                    [ intExpr 42 ]
            }
    in
    makeModuleWithTypedDefsUnionsAliases "Test"
        [ testValueDef ]
        []
        []


{-| A module whose `testValue` nests one `let` inside another and uses
neither binding, so both are dead and the inliner drops both:

    testValue : Int
    testValue =
        let
            x =
                1
        in
        let
            y =
                2
        in
        3

-}
nestedLetModule : Src.Module
nestedLetModule =
    let
        testValueDef : TypedDef
        testValueDef =
            { name = "testValue"
            , args = []
            , tipe = tType "Int" []
            , body =
                letExpr [ define "x" [] (intExpr 1) ]
                    (letExpr [ define "y" [] (intExpr 2) ]
                        (intExpr 3)
                    )
            }
    in
    makeModuleWithTypedDefsUnionsAliases "Test"
        [ testValueDef ]
        []
        []



-- ============================================================================
-- STANDARD TEST SUITE INTEGRATION
-- ============================================================================


{-| The test, over every program in the standard catalogue, that the inliner's
output keeps the invariants `graphIssues` checks.
-}
standardTestSuite : Test
standardTestSuite =
    StandardTestSuites.expectSuite expectOptimizationPreservesValidity "optimizes without errors"


{-| Runs the inliner on the graph `runToMono` makes from `srcModule`, and
passes when `graphIssues` finds nothing in the result. Fails with the
pipeline's message when `runToMono` returns an error.
-}
expectOptimizationPreservesValidity : Src.Module -> Expect.Expectation
expectOptimizationPreservesValidity srcModule =
    case Pipeline.runToMono srcModule of
        Err msg ->
            Expect.fail ("Failed to create MonoGraph: " ++ msg)

        Ok { monoGraph } ->
            let
                ( optimizedGraph, _ ) =
                    MonoInlineSimplify.optimize Config.default.inline monoGraph
            in
            case graphIssues optimizedGraph of
                [] ->
                    Expect.pass

                issues ->
                    Expect.fail (String.join "\n" issues)


{-| Returns a line for each problem in `graph`: a live node that refers (as
`MonoTraverse.collectSpecEdges` finds references) to a SpecId with no node,
and a `MonoDefine` whose body holds a `MonoTailCall` to a name that no
`MonoTailDef` in the same body defines.
-}
graphIssues : Mono.MonoGraph -> List String
graphIssues (Mono.MonoGraph record) =
    let
        edges =
            MonoTraverse.collectSpecEdges record.nodes

        isLive specId =
            case Array.get specId record.nodes of
                Just (Just _) ->
                    True

                _ ->
                    False
    in
    Array.foldl
        (\entry ( specId, acc ) ->
            case entry of
                Nothing ->
                    ( specId + 1, acc )

                Just node ->
                    let
                        dangling =
                            Array.get specId edges
                                |> Maybe.andThen identity
                                |> Maybe.withDefault []
                                |> List.filter (\t -> not (isLive t))
                                |> List.map
                                    (\t ->
                                        "SpecId " ++ String.fromInt specId ++ " refers to SpecId " ++ String.fromInt t ++ ", which has no node"
                                    )

                        orphans =
                            case node of
                                Mono.MonoDefine expr _ ->
                                    orphanTailCalls expr
                                        |> List.map
                                            (\n ->
                                                "SpecId " ++ String.fromInt specId ++ " (a MonoDefine) holds a MonoTailCall to '" ++ n ++ "' outside any tail-recursive definition of that name"
                                            )

                                _ ->
                                    []
                    in
                    ( specId + 1, acc ++ dangling ++ orphans )
        )
        ( 0, [] )
        record.nodes
        |> Tuple.second


{-| Returns the names of the `MonoTailCall`s in `expr` that no `MonoTailDef`
in `expr` defines.
-}
orphanTailCalls : Mono.MonoExpr -> List String
orphanTailCalls expr =
    let
        ( tailDefs, tailCalls ) =
            MonoTraverse.foldExpr
                (\e ( defs, calls ) ->
                    case e of
                        Mono.MonoLet (Mono.MonoTailDef name _ _) _ _ ->
                            ( name :: defs, calls )

                        Mono.MonoTailCall name _ _ ->
                            ( defs, name :: calls )

                        _ ->
                            ( defs, calls )
                )
                ( [], [] )
                expr
    in
    List.filter (\n -> not (List.member n tailDefs)) tailCalls
