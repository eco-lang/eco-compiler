module Compiler.KernelTests exposing (expectSuite)

{-| Tests for VarKernel expressions.

VarKernel expressions represent references to Elm.Kernel.\* functions.
These can only be created by directly constructing canonical AST,
not from regular Elm source code.

-}

import Compiler.AST.Canonical as Can
import Compiler.AST.CanonicalBuilder
    exposing
        ( callExpr
        , intExpr
        , lambdaExpr
        , letExpr
        , listExpr
        , makeDef
        , makeModule
        , pVar
        , tupleExpr
        , varKernelExpr
        , varLocalExpr
        )
import Expect exposing (Expectation)
import Fuzz
import Test exposing (Test)


expectSuite : (Can.Module -> Expectation) -> String -> Test
expectSuite expectFn condStr =
    Test.describe "VarKernel expressions"
        [ simpleKernelTests expectFn condStr
        , kernelCallTests expectFn condStr
        , kernelInContextTests expectFn condStr
        , kernelFuzzTests expectFn condStr
        ]



-- ============================================================================
-- SIMPLE KERNEL EXPRESSIONS (6 tests)
-- ============================================================================


simpleKernelTests : (Can.Module -> Expectation) -> String -> Test
simpleKernelTests expectFn condStr =
    Test.describe "Simple kernel expressions"
        [ Test.test ("VarKernel List.batch " ++ condStr) (varKernelListBatch expectFn)
        , Test.test ("VarKernel Platform.batch " ++ condStr) (varKernelPlatformBatch expectFn)
        , Test.test ("VarKernel Scheduler.succeed " ++ condStr) (varKernelSchedulerSucceed expectFn)
        , Test.test ("VarKernel Process.spawn " ++ condStr) (varKernelProcessSpawn expectFn)
        , Test.test ("VarKernel JsArray.empty " ++ condStr) (varKernelJsArrayEmpty expectFn)
        , Test.test ("VarKernel Utils.Tuple2 " ++ condStr) (varKernelUtilsTuple2 expectFn)
        ]


varKernelListBatch : (Can.Module -> Expectation) -> (() -> Expectation)
varKernelListBatch expectFn _ =
    let
        modul =
            makeModule "testValue"
                (varKernelExpr 1 "List" "batch")
    in
    expectFn modul


varKernelPlatformBatch : (Can.Module -> Expectation) -> (() -> Expectation)
varKernelPlatformBatch expectFn _ =
    let
        modul =
            makeModule "testValue"
                (varKernelExpr 1 "Platform" "batch")
    in
    expectFn modul


varKernelSchedulerSucceed : (Can.Module -> Expectation) -> (() -> Expectation)
varKernelSchedulerSucceed expectFn _ =
    let
        modul =
            makeModule "testValue"
                (varKernelExpr 1 "Scheduler" "succeed")
    in
    expectFn modul


varKernelProcessSpawn : (Can.Module -> Expectation) -> (() -> Expectation)
varKernelProcessSpawn expectFn _ =
    let
        modul =
            makeModule "testValue"
                (varKernelExpr 1 "Process" "spawn")
    in
    expectFn modul


varKernelJsArrayEmpty : (Can.Module -> Expectation) -> (() -> Expectation)
varKernelJsArrayEmpty expectFn _ =
    let
        modul =
            makeModule "testValue"
                (varKernelExpr 1 "JsArray" "empty")
    in
    expectFn modul


varKernelUtilsTuple2 : (Can.Module -> Expectation) -> (() -> Expectation)
varKernelUtilsTuple2 expectFn _ =
    let
        modul =
            makeModule "testValue"
                (varKernelExpr 1 "Utils" "Tuple2")
    in
    expectFn modul



-- ============================================================================
-- KERNEL FUNCTION CALLS (6 tests)
-- ============================================================================


kernelCallTests : (Can.Module -> Expectation) -> String -> Test
kernelCallTests expectFn condStr =
    Test.describe "Kernel function calls"
        [ Test.test ("Calling kernel function with int arg " ++ condStr) (kernelCallWithIntArg expectFn)
        , Test.test ("Calling kernel function with multiple args " ++ condStr) (kernelCallWithMultipleArgs expectFn)
        , Test.test ("Nested kernel calls " ++ condStr) (nestedKernelCalls expectFn)
        , Test.test ("Multiple kernel calls in tuple " ++ condStr) (multipleKernelCallsInTuple expectFn)
        , Test.test ("Kernel function as higher-order argument " ++ condStr) (kernelAsHigherOrderArg expectFn)
        , Test.test ("Kernel function in list " ++ condStr) (kernelFunctionInList expectFn)
        ]


kernelCallWithIntArg : (Can.Module -> Expectation) -> (() -> Expectation)
kernelCallWithIntArg expectFn _ =
    let
        kernel =
            varKernelExpr 1 "List" "singleton"

        arg =
            intExpr 2 42

        modul =
            makeModule "testValue"
                (callExpr 3 kernel [ arg ])
    in
    expectFn modul


kernelCallWithMultipleArgs : (Can.Module -> Expectation) -> (() -> Expectation)
kernelCallWithMultipleArgs expectFn _ =
    let
        kernel =
            varKernelExpr 1 "List" "cons"

        arg1 =
            intExpr 2 1

        arg2 =
            listExpr 3 []

        modul =
            makeModule "testValue"
                (callExpr 4 kernel [ arg1, arg2 ])
    in
    expectFn modul


nestedKernelCalls : (Can.Module -> Expectation) -> (() -> Expectation)
nestedKernelCalls expectFn _ =
    let
        innerKernel =
            varKernelExpr 1 "List" "singleton"

        innerArg =
            intExpr 2 1

        innerCall =
            callExpr 3 innerKernel [ innerArg ]

        outerKernel =
            varKernelExpr 4 "List" "head"

        modul =
            makeModule "testValue"
                (callExpr 5 outerKernel [ innerCall ])
    in
    expectFn modul


multipleKernelCallsInTuple : (Can.Module -> Expectation) -> (() -> Expectation)
multipleKernelCallsInTuple expectFn _ =
    let
        call1 =
            callExpr 2 (varKernelExpr 1 "List" "head") [ listExpr 3 [] ]

        call2 =
            callExpr 5 (varKernelExpr 4 "List" "tail") [ listExpr 6 [] ]

        modul =
            makeModule "testValue"
                (tupleExpr 7 call1 call2)
    in
    expectFn modul


kernelAsHigherOrderArg : (Can.Module -> Expectation) -> (() -> Expectation)
kernelAsHigherOrderArg expectFn _ =
    let
        -- apply f x = f x (where f is a kernel function)
        applyDef =
            makeDef "apply"
                [ pVar 3 "f", pVar 4 "x" ]
                (callExpr 5 (varLocalExpr 6 "f") [ varLocalExpr 7 "x" ])

        kernel =
            varKernelExpr 8 "List" "singleton"

        arg =
            intExpr 9 42

        body =
            callExpr 10 (varLocalExpr 11 "apply") [ kernel, arg ]

        modul =
            makeModule "testValue"
                (letExpr 1 applyDef body)
    in
    expectFn modul


kernelFunctionInList : (Can.Module -> Expectation) -> (() -> Expectation)
kernelFunctionInList expectFn _ =
    let
        k1 =
            varKernelExpr 1 "List" "head"

        k2 =
            varKernelExpr 2 "List" "tail"

        k3 =
            varKernelExpr 3 "List" "length"

        modul =
            makeModule "testValue"
                (listExpr 4 [ k1, k2, k3 ])
    in
    expectFn modul



-- ============================================================================
-- KERNEL IN CONTEXT (6 tests)
-- ============================================================================


kernelInContextTests : (Can.Module -> Expectation) -> String -> Test
kernelInContextTests expectFn condStr =
    Test.describe "Kernel functions in context"
        [ Test.test ("Kernel function in lambda body " ++ condStr) (kernelInLambdaBody expectFn)
        , Test.test ("Kernel function in let binding " ++ condStr) (kernelInLetBinding expectFn)
        , Test.test ("Multiple kernel functions from same module " ++ condStr) (multipleKernelSameModule expectFn)
        , Test.test ("Kernel functions from different modules " ++ condStr) (kernelDifferentModules expectFn)
        , Test.test ("Kernel function with complex args " ++ condStr) (kernelWithComplexArgs expectFn)
        , Test.test ("Chained kernel calls " ++ condStr) (chainedKernelCalls expectFn)
        ]


kernelInLambdaBody : (Can.Module -> Expectation) -> (() -> Expectation)
kernelInLambdaBody expectFn _ =
    let
        body =
            callExpr 3 (varKernelExpr 2 "List" "singleton") [ varLocalExpr 4 "x" ]

        lambda =
            lambdaExpr 1 [ pVar 5 "x" ] body

        modul =
            makeModule "testValue" lambda
    in
    expectFn modul


kernelInLetBinding : (Can.Module -> Expectation) -> (() -> Expectation)
kernelInLetBinding expectFn _ =
    let
        kernelCall =
            callExpr 3 (varKernelExpr 2 "List" "singleton") [ intExpr 4 1 ]

        def =
            makeDef "result" [] kernelCall

        body =
            varLocalExpr 5 "result"

        modul =
            makeModule "testValue"
                (letExpr 1 def body)
    in
    expectFn modul


multipleKernelSameModule : (Can.Module -> Expectation) -> (() -> Expectation)
multipleKernelSameModule expectFn _ =
    let
        k1 =
            varKernelExpr 1 "List" "cons"

        k2 =
            varKernelExpr 2 "List" "singleton"

        k3 =
            varKernelExpr 3 "List" "append"

        modul =
            makeModule "testValue"
                (listExpr 4 [ k1, k2, k3 ])
    in
    expectFn modul


kernelDifferentModules : (Can.Module -> Expectation) -> (() -> Expectation)
kernelDifferentModules expectFn _ =
    let
        k1 =
            varKernelExpr 1 "List" "cons"

        k2 =
            varKernelExpr 2 "Platform" "batch"

        k3 =
            varKernelExpr 3 "Scheduler" "succeed"

        modul =
            makeModule "testValue"
                (listExpr 4 [ k1, k2, k3 ])
    in
    expectFn modul


kernelWithComplexArgs : (Can.Module -> Expectation) -> (() -> Expectation)
kernelWithComplexArgs expectFn _ =
    let
        arg1 =
            tupleExpr 2 (intExpr 3 1) (intExpr 4 2)

        arg2 =
            listExpr 5 [ intExpr 6 3, intExpr 7 4 ]

        kernel =
            varKernelExpr 8 "Utils" "pair"

        modul =
            makeModule "testValue"
                (callExpr 1 kernel [ arg1, arg2 ])
    in
    expectFn modul


chainedKernelCalls : (Can.Module -> Expectation) -> (() -> Expectation)
chainedKernelCalls expectFn _ =
    let
        -- head (tail (singleton 1))
        innermost =
            callExpr 3 (varKernelExpr 2 "List" "singleton") [ intExpr 4 1 ]

        middle =
            callExpr 6 (varKernelExpr 5 "List" "tail") [ innermost ]

        outer =
            callExpr 8 (varKernelExpr 7 "List" "head") [ middle ]

        modul =
            makeModule "testValue" outer
    in
    expectFn modul



-- ============================================================================
-- FUZZ TESTS (2 tests)
-- ============================================================================


kernelFuzzTests : (Can.Module -> Expectation) -> String -> Test
kernelFuzzTests expectFn condStr =
    Test.describe "Fuzzed kernel tests"
        [ Test.fuzz Fuzz.int ("Kernel call with fuzzed int " ++ condStr) (kernelCallFuzzedInt expectFn)
        , Test.fuzz3 Fuzz.int Fuzz.int Fuzz.int ("Multiple kernel calls with fuzzed ints " ++ condStr) (multipleKernelCallsFuzzedInts expectFn)
        ]


kernelCallFuzzedInt : (Can.Module -> Expectation) -> (Int -> Expectation)
kernelCallFuzzedInt expectFn n =
    let
        kernel =
            varKernelExpr 1 "List" "singleton"

        arg =
            intExpr 2 n

        modul =
            makeModule "testValue"
                (callExpr 3 kernel [ arg ])
    in
    expectFn modul


multipleKernelCallsFuzzedInts : (Can.Module -> Expectation) -> (Int -> Int -> Int -> Expectation)
multipleKernelCallsFuzzedInts expectFn a b c =
    let
        call1 =
            callExpr 2 (varKernelExpr 1 "List" "singleton") [ intExpr 3 a ]

        call2 =
            callExpr 5 (varKernelExpr 4 "List" "singleton") [ intExpr 6 b ]

        call3 =
            callExpr 8 (varKernelExpr 7 "List" "singleton") [ intExpr 9 c ]

        modul =
            makeModule "testValue"
                (listExpr 10 [ call1, call2, call3 ])
    in
    expectFn modul
