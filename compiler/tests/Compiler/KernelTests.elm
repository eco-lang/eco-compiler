module Compiler.KernelTests exposing (expectSuite, testCases)

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
import Compiler.BulkCheck exposing (TestCase, bulkCheck)
import Expect exposing (Expectation)
import Test exposing (Test)


expectSuite : (Can.Module -> Expectation) -> String -> Test
expectSuite expectFn condStr =
    Test.test ("VarKernel expressions " ++ condStr) <|
        \_ -> bulkCheck (testCases expectFn)


testCases : (Can.Module -> Expectation) -> List TestCase
testCases expectFn =
    List.concat
        [ simpleKernelCases expectFn
        , kernelCallCases expectFn
        , kernelInContextCases expectFn
        ]



-- ============================================================================
-- SIMPLE KERNEL EXPRESSIONS (8 tests)
-- ============================================================================


simpleKernelCases : (Can.Module -> Expectation) -> List TestCase
simpleKernelCases expectFn =
    [ { label = "VarKernel List.batch", run = varKernelListBatch expectFn }
    , { label = "VarKernel Platform.batch", run = varKernelPlatformBatch expectFn }
    , { label = "VarKernel Scheduler.succeed", run = varKernelSchedulerSucceed expectFn }
    , { label = "VarKernel Process.spawn", run = varKernelProcessSpawn expectFn }
    , { label = "VarKernel JsArray.empty", run = varKernelJsArrayEmpty expectFn }
    , { label = "VarKernel Utils.Tuple2", run = varKernelUtilsTuple2 expectFn }
    , { label = "VarKernel Basics.pi (ConstantFloat intrinsic)", run = varKernelBasicsPi expectFn }
    , { label = "VarKernel Basics.add (intrinsic function arity>0)", run = varKernelBasicsAdd expectFn }
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


{-| Tests the ConstantFloat intrinsic branch in generateVarKernel.
Basics.pi is recognized as a constant float intrinsic and generates
an arith.constant operation directly.
-}
varKernelBasicsPi : (Can.Module -> Expectation) -> (() -> Expectation)
varKernelBasicsPi expectFn _ =
    let
        modul =
            makeModule "testValue"
                (varKernelExpr 1 "Basics" "pi")
    in
    expectFn modul


{-| Tests the intrinsic function with arity > 0 branch in generateVarKernel.
Basics.add is an intrinsic function that, when referenced without being called,
creates a papCreate (partial application) closure with arity 2.
-}
varKernelBasicsAdd : (Can.Module -> Expectation) -> (() -> Expectation)
varKernelBasicsAdd expectFn _ =
    let
        modul =
            makeModule "testValue"
                (varKernelExpr 1 "Basics" "add")
    in
    expectFn modul



-- ============================================================================
-- KERNEL FUNCTION CALLS (6 tests)
-- ============================================================================


kernelCallCases : (Can.Module -> Expectation) -> List TestCase
kernelCallCases expectFn =
    [ { label = "Calling kernel function with int arg", run = kernelCallWithIntArg expectFn }
    , { label = "Calling kernel function with multiple args", run = kernelCallWithMultipleArgs expectFn }
    , { label = "Nested kernel calls", run = nestedKernelCalls expectFn }
    , { label = "Multiple kernel calls in tuple", run = multipleKernelCallsInTuple expectFn }
    , { label = "Kernel function as higher-order argument", run = kernelAsHigherOrderArg expectFn }
    , { label = "Kernel function in list", run = kernelFunctionInList expectFn }
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


kernelInContextCases : (Can.Module -> Expectation) -> List TestCase
kernelInContextCases expectFn =
    [ { label = "Kernel function in lambda body", run = kernelInLambdaBody expectFn }
    , { label = "Kernel function in let binding", run = kernelInLetBinding expectFn }
    , { label = "Multiple kernel functions from same module", run = multipleKernelSameModule expectFn }
    , { label = "Kernel functions from different modules", run = kernelDifferentModules expectFn }
    , { label = "Kernel function with complex args", run = kernelWithComplexArgs expectFn }
    , { label = "Chained kernel calls", run = chainedKernelCalls expectFn }
    , { label = "Kernel alias direct call", run = kernelAliasDirectCall expectFn }
    , { label = "Kernel alias transitive call", run = kernelAliasTransitiveCall expectFn }
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


{-| Tests that a local alias to a kernel function uses flattened call model.
let f = Elm.Kernel.List.singleton in f 42
The call through 'f' should use flattened external arity (all args at once),
not stage-curried arity.
-}
kernelAliasDirectCall : (Can.Module -> Expectation) -> (() -> Expectation)
kernelAliasDirectCall expectFn _ =
    let
        -- f = Elm.Kernel.List.singleton
        kernelFn =
            varKernelExpr 2 "List" "singleton"

        fDef =
            makeDef "f" [] kernelFn

        -- f 42
        body =
            callExpr 4 (varLocalExpr 5 "f") [ intExpr 6 42 ]

        modul =
            makeModule "testValue"
                (letExpr 1 fDef body)
    in
    expectFn modul


{-| Tests transitive propagation of kernel call model through alias chains.
let f = Elm.Kernel.List.singleton in let g = f in g 42
The call through 'g' should inherit 'f's flattened external call model.
-}
kernelAliasTransitiveCall : (Can.Module -> Expectation) -> (() -> Expectation)
kernelAliasTransitiveCall expectFn _ =
    let
        -- f = Elm.Kernel.List.singleton
        kernelFn =
            varKernelExpr 2 "List" "singleton"

        fDef =
            makeDef "f" [] kernelFn

        -- g = f
        gDef =
            makeDef "g" [] (varLocalExpr 4 "f")

        -- g 42
        innerBody =
            callExpr 6 (varLocalExpr 7 "g") [ intExpr 8 42 ]

        -- let g = f in g 42
        innerLet =
            letExpr 3 gDef innerBody

        modul =
            makeModule "testValue"
                (letExpr 1 fDef innerLet)
    in
    expectFn modul
