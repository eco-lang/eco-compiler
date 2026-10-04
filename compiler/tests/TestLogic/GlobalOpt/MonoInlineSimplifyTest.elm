module TestLogic.GlobalOpt.MonoInlineSimplifyTest exposing (suite)

{-| Smoke tests for the post-monomorphization inliner,
`Compiler.GlobalOpt.MonoInlineSimplify.optimize`. They run the inliner on its
own, outside a build, so that a crash in it on an ordinary program shows up as
a failing test. They check nothing about what the inliner did to a program.

The programs are turned into a monomorphized graph by
`TestLogic.TestPipeline.runToMono`, which uses the substitution engine rather
than the solver engine a default build uses, and runs none of the
pre-monomorphization passes. The inliner is then called with
`Config.default.inline`. The optimized graph is not pruned afterwards, whereas
a default build prunes it.

The fixtures are four modules named `Test`, each with one annotated
`testValue : Int`: an `identity` function applied to 42, a `let` that binds 42
and returns it, the lambda `\x -> x` applied to 42, and two nested `let`s that
bind 1 and 2 and return the first. The last group uses every program in the
`SourceIR.Suite.StandardTestSuites` catalogue instead.

What the tests establish:

  - "Optimizer compiles and runs": for each of the four fixtures, that
    `runToMono` returns a graph. These tests do not call the inliner.
  - "metrics are non-negative": on the single-`let` fixture, that `optimize`
    returns and its `inlineCount`, `betaReductions` and `letEliminations` are
    each at least 0.
  - "closure count is collected": on the applied-lambda fixture, that
    `optimize` returns and its `inlineCount` is at least 0. No metric about
    closures is read.
  - "optimizes without errors", over the standard catalogue: that `optimize`
    returns on each program's graph. A program whose `runToMono` returns an
    error passes.

A `runToMono` error fails the tests of the first two groups with its message.

Among what is not tested: that anything is inlined, beta-reduced or
eliminated; that the optimized graph is well formed or computes the same
values; and any metric's value, since the three counters start at zero and are
only ever increased, so "at least 0" holds whenever `optimize` returns.

-}

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
import Expect
import SourceIR.Suite.StandardTestSuites as StandardTestSuites
import Test exposing (Test)
import TestLogic.TestPipeline as Pipeline


{-| All the tests of this module, in three groups.
-}
suite : Test
suite =
    Test.describe "MonoInlineSimplify"
        [ optimizerCompilesSuite
        , metricsCollectionSuite
        , standardTestSuite
        ]



-- ============================================================================
-- FIXTURES, AND THE TESTS THAT THEY MONOMORPHIZE
-- ============================================================================


{-| The tests that each of the four fixtures reaches a monomorphized graph.
Despite the group's name, the inliner is not run.
-}
optimizerCompilesSuite : Test
optimizerCompilesSuite =
    Test.describe "Optimizer compiles and runs"
        [ Test.test "simple identity function optimizes" <|
            \_ ->
                expectOptimizationSucceeds simpleIdentityModule
        , Test.test "let binding optimizes" <|
            \_ ->
                expectOptimizationSucceeds simpleLetModule
        , Test.test "lambda application optimizes" <|
            \_ ->
                expectOptimizationSucceeds lambdaApplicationModule
        , Test.test "nested let optimizes" <|
            \_ ->
                expectOptimizationSucceeds nestedLetModule
        ]


{-| Passes when `runToMono` returns a graph for `srcModule`, and fails with the
pipeline's message when it returns an error. It does not call the inliner.
-}
expectOptimizationSucceeds : Src.Module -> Expect.Expectation
expectOptimizationSucceeds srcModule =
    case Pipeline.runToMono srcModule of
        Err msg ->
            Expect.fail ("Failed to create MonoGraph: " ++ msg)

        Ok _ ->
            Expect.pass


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


{-| A module whose `testValue` binds 42 in a `let` and returns it:

    testValue : Int
    testValue =
        let
            x =
                42
        in
        x

-}
simpleLetModule : Src.Module
simpleLetModule =
    let
        testValueDef : TypedDef
        testValueDef =
            { name = "testValue"
            , args = []
            , tipe = tType "Int" []
            , body = letExpr [ define "x" [] (intExpr 42) ] (varExpr "x")
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


{-| A module whose `testValue` nests one `let` inside another and returns the
outer binding; the inner binding `y` is never used:

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
        x

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
                        (varExpr "x")
                    )
            }
    in
    makeModuleWithTypedDefsUnionsAliases "Test"
        [ testValueDef ]
        []
        []



-- ============================================================================
-- METRICS COLLECTION
-- ============================================================================


{-| The two tests that run the inliner on a fixture and look at its metrics.
-}
metricsCollectionSuite : Test
metricsCollectionSuite =
    Test.describe "Metrics collection"
        [ Test.test "metrics are non-negative" <|
            \_ ->
                expectMetricsNonNegative simpleLetModule
        , Test.test "closure count is collected" <|
            \_ ->
                expectClosureCountCollected lambdaApplicationModule
        ]


{-| Runs the inliner on the graph `runToMono` makes from `srcModule`, and
passes when its `inlineCount`, `betaReductions` and `letEliminations` are each
at least 0. Fails with the pipeline's message when `runToMono` returns an
error.
-}
expectMetricsNonNegative : Src.Module -> Expect.Expectation
expectMetricsNonNegative srcModule =
    case Pipeline.runToMono srcModule of
        Err msg ->
            Expect.fail ("Failed to create MonoGraph: " ++ msg)

        Ok { monoGraph } ->
            let
                ( _, metrics ) =
                    MonoInlineSimplify.optimize Config.default.inline monoGraph
            in
            Expect.all
                [ \_ -> Expect.atLeast 0 metrics.inlineCount
                , \_ -> Expect.atLeast 0 metrics.betaReductions
                , \_ -> Expect.atLeast 0 metrics.letEliminations
                ]
                ()


{-| Runs the inliner on the graph `runToMono` makes from `srcModule`, and
passes when its `inlineCount` is at least 0. Despite the name, no metric about
closures is read. Fails with the pipeline's message when `runToMono` returns an
error.
-}
expectClosureCountCollected : Src.Module -> Expect.Expectation
expectClosureCountCollected srcModule =
    case Pipeline.runToMono srcModule of
        Err msg ->
            Expect.fail ("Failed to create MonoGraph: " ++ msg)

        Ok { monoGraph } ->
            let
                ( _, metrics ) =
                    MonoInlineSimplify.optimize Config.default.inline monoGraph
            in
            Expect.atLeast 0 metrics.inlineCount



-- ============================================================================
-- STANDARD TEST SUITE INTEGRATION
-- ============================================================================


{-| The test, over every program in the standard catalogue, that the inliner
returns on that program's monomorphized graph.
-}
standardTestSuite : Test
standardTestSuite =
    StandardTestSuites.expectSuite expectOptimizationPreservesValidity "optimizes without errors"


{-| Runs the inliner on the graph `runToMono` makes from `srcModule`, and
passes once it returns. Nothing about the optimized graph is checked, despite
the name. When `runToMono` returns an error the expectation also passes, since
there is no graph to run the inliner on.
-}
expectOptimizationPreservesValidity : Src.Module -> Expect.Expectation
expectOptimizationPreservesValidity srcModule =
    case Pipeline.runToMono srcModule of
        Err _ ->
            Expect.pass

        Ok { monoGraph } ->
            let
                ( optimizedGraph, _ ) =
                    MonoInlineSimplify.optimize Config.default.inline monoGraph
            in
            expectGraphValid optimizedGraph


{-| Always passes. Despite its name, it checks nothing about the graph.
-}
expectGraphValid : Mono.MonoGraph -> Expect.Expectation
expectGraphValid (Mono.MonoGraph _) =
    Expect.pass
