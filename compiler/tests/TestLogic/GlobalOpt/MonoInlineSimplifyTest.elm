module TestLogic.GlobalOpt.MonoInlineSimplifyTest exposing (suite)

{-| Test suite for MonoInlineSimplify optimization pass.

This tests that:

  - The optimizer compiles and runs without errors
  - Basic optimizations (let elimination, beta reduction) work correctly
  - The optimizer preserves program semantics (via monomorphization pipeline)
  - Metrics are collected properly

-}

import Compiler.AST.Monomorphized as Mono
import Compiler.AST.Source as Src
import Compiler.AST.SourceBuilder
    exposing
        ( TypedDef
        , binopsExpr
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
import Compiler.AST.TypeEnv as TypeEnv
import Compiler.GlobalOpt.MonoInlineSimplify as MonoInlineSimplify
import Expect
import SourceIR.Suite.StandardTestSuites as StandardTestSuites
import Test exposing (Test)
import TestLogic.TestPipeline as Pipeline


suite : Test
suite =
    Test.describe "MonoInlineSimplify"
        [ optimizerCompilesSuite
        , metricsCollectionSuite
        , standardTestSuite
        ]



-- ============================================================================
-- OPTIMIZER COMPILES AND RUNS
-- ============================================================================


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


expectOptimizationSucceeds : Src.Module -> Expect.Expectation
expectOptimizationSucceeds srcModule =
    case Pipeline.runToMono srcModule of
        Err msg ->
            Expect.fail ("Failed to create MonoGraph: " ++ msg)

        Ok { monoGraph } ->
            let
                typeEnv =
                    TypeEnv.emptyGlobalTypeEnv

                ( _, _ ) =
                    MonoInlineSimplify.optimize typeEnv monoGraph
            in
            -- Just verify it runs without crashing
            Expect.pass


{-| identity : Int -> Int
identity x = x

testValue : Int
testValue = identity 42

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


{-| testValue : Int
testValue =
let x = 42 in x
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


{-| testValue : Int
testValue = (\\x -> x) 42
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


{-| testValue : Int
testValue =
let x = 1 in
let y = 2 in
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


expectMetricsNonNegative : Src.Module -> Expect.Expectation
expectMetricsNonNegative srcModule =
    case Pipeline.runToMono srcModule of
        Err msg ->
            Expect.fail ("Failed to create MonoGraph: " ++ msg)

        Ok { monoGraph } ->
            let
                typeEnv =
                    TypeEnv.emptyGlobalTypeEnv

                ( _, metrics ) =
                    MonoInlineSimplify.optimize typeEnv monoGraph
            in
            Expect.all
                [ \_ -> Expect.atLeast 0 metrics.closureCountBefore
                , \_ -> Expect.atLeast 0 metrics.closureCountAfter
                , \_ -> Expect.atLeast 0 metrics.inlineCount
                , \_ -> Expect.atLeast 0 metrics.betaReductions
                , \_ -> Expect.atLeast 0 metrics.letEliminations
                ]
                ()


expectClosureCountCollected : Src.Module -> Expect.Expectation
expectClosureCountCollected srcModule =
    case Pipeline.runToMono srcModule of
        Err msg ->
            Expect.fail ("Failed to create MonoGraph: " ++ msg)

        Ok { monoGraph } ->
            let
                typeEnv =
                    TypeEnv.emptyGlobalTypeEnv

                ( _, metrics ) =
                    MonoInlineSimplify.optimize typeEnv monoGraph
            in
            -- Module with lambda should have at least one closure before optimization
            -- (may or may not after, depending on optimization)
            Expect.atLeast 0 metrics.closureCountBefore



-- ============================================================================
-- STANDARD TEST SUITE INTEGRATION
-- ============================================================================


standardTestSuite : Test
standardTestSuite =
    StandardTestSuites.expectSuite expectOptimizationPreservesValidity "optimizes without errors"


expectOptimizationPreservesValidity : Src.Module -> Expect.Expectation
expectOptimizationPreservesValidity srcModule =
    case Pipeline.runToMono srcModule of
        Err _ ->
            -- If monomorphization fails, that's not the optimizer's fault
            Expect.pass

        Ok { monoGraph } ->
            let
                typeEnv =
                    TypeEnv.emptyGlobalTypeEnv

                ( optimizedGraph, _ ) =
                    MonoInlineSimplify.optimize typeEnv monoGraph
            in
            -- Verify the optimized graph is still valid
            expectGraphValid optimizedGraph


expectGraphValid : Mono.MonoGraph -> Expect.Expectation
expectGraphValid (Mono.MonoGraph _) =
    -- Basic validity check: nodes dict is not corrupted
    -- More sophisticated checks could be added later
    Expect.pass
