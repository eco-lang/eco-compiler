module SourceIR.KernelCases exposing (expectSuite)

{-| Canonical modules containing kernel references, built by hand so that a
check on the canonical AST, or on a stage that starts from it, can be run
against kernel references in a range of positions.

A kernel reference names a value of a kernel module, such as
`Elm.Kernel.List.cons`, and appears in the canonical AST as `Can.VarKernel`. The
canonicalizer produces one only in a module of a kernel package. These cases
are written directly as canonical AST with `Compiler.AST.CanonicalBuilder`, with
no source text.

Every case is a module made by `makeModule`, so it is the module `Test` of
`elm/core` and has one declaration, `testValue`, which takes no arguments and
has no annotation. Every kernel reference has the `Elm` prefix. Each expression
and pattern in a case has an id chosen by hand and different from every other id
in that case. Nothing here checks that a kernel function of the given name
exists.

This module asserts nothing itself. `expectSuite` applies the caller's
expectation to the module of each case, so what a case establishes is whatever
that expectation checks. There are 22 cases:

  - Eight bare references: `testValue` is a kernel reference on its own, to
    `List.batch`, `Platform.batch`, `Scheduler.succeed`, `Process.spawn`,
    `JsArray.empty`, `Utils.Tuple2`, `Basics.pi` or `Basics.add`.
  - Six cases of calling or passing kernel functions: a kernel function
    applied to an `Int`; to an `Int` and an empty list; to the result of
    another kernel call; two kernel calls as the two halves of a pair; a kernel
    function passed to a let-bound function that applies it; and three uncalled
    kernel references as the elements of a list.
  - Eight cases of kernels in context: a kernel call as a lambda body; as a
    let-bound value; three references from one kernel module in a list; three
    from different modules in a list; a kernel function applied to a pair and a
    list; three calls nested one inside the next; and a kernel function called
    through a let-bound name, directly and through a second name bound to the
    first.

Among what is not tested: references with the `Eco` prefix, kernel references
inside `if`, `case` or record expressions, and kernel references in annotated
definitions or in definitions that take arguments.

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


{-| Returns one test, named `"VarKernel expressions "` followed by `condStr`,
that applies `expectFn` to the module of each case in turn. It stops at
the first case that fails and reports it under that case's label, as
`Compiler.BulkCheck.bulkCheck` describes.
-}
expectSuite : (Can.Module -> Expectation) -> String -> Test
expectSuite expectFn condStr =
    Test.test ("VarKernel expressions " ++ condStr) <|
        \_ -> bulkCheck (testCases expectFn)


{-| Returns all 22 cases, each applying `expectFn` to its module: the bare
references first, then the calls, then the kernels in context.
-}
testCases : (Can.Module -> Expectation) -> List TestCase
testCases expectFn =
    List.concat
        [ simpleKernelCases expectFn
        , kernelCallCases expectFn
        , kernelInContextCases expectFn
        ]



-- ============================================================================
-- SIMPLE KERNEL EXPRESSIONS
-- ============================================================================


{-| Returns the eight cases in which `testValue` is a kernel reference on its
own, each applying `expectFn` to its module.
-}
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


{-| Applies `expectFn` to a module whose `testValue` is the bare reference
`Elm.Kernel.List.batch`.
-}
varKernelListBatch : (Can.Module -> Expectation) -> (() -> Expectation)
varKernelListBatch expectFn _ =
    let
        modul =
            makeModule "testValue"
                (varKernelExpr 1 "List" "batch")
    in
    expectFn modul


{-| Applies `expectFn` to a module whose `testValue` is the bare reference
`Elm.Kernel.Platform.batch`.
-}
varKernelPlatformBatch : (Can.Module -> Expectation) -> (() -> Expectation)
varKernelPlatformBatch expectFn _ =
    let
        modul =
            makeModule "testValue"
                (varKernelExpr 1 "Platform" "batch")
    in
    expectFn modul


{-| Applies `expectFn` to a module whose `testValue` is the bare reference
`Elm.Kernel.Scheduler.succeed`.
-}
varKernelSchedulerSucceed : (Can.Module -> Expectation) -> (() -> Expectation)
varKernelSchedulerSucceed expectFn _ =
    let
        modul =
            makeModule "testValue"
                (varKernelExpr 1 "Scheduler" "succeed")
    in
    expectFn modul


{-| Applies `expectFn` to a module whose `testValue` is the bare reference
`Elm.Kernel.Process.spawn`.
-}
varKernelProcessSpawn : (Can.Module -> Expectation) -> (() -> Expectation)
varKernelProcessSpawn expectFn _ =
    let
        modul =
            makeModule "testValue"
                (varKernelExpr 1 "Process" "spawn")
    in
    expectFn modul


{-| Applies `expectFn` to a module whose `testValue` is the bare reference
`Elm.Kernel.JsArray.empty`.
-}
varKernelJsArrayEmpty : (Can.Module -> Expectation) -> (() -> Expectation)
varKernelJsArrayEmpty expectFn _ =
    let
        modul =
            makeModule "testValue"
                (varKernelExpr 1 "JsArray" "empty")
    in
    expectFn modul


{-| Applies `expectFn` to a module whose `testValue` is the bare reference
`Elm.Kernel.Utils.Tuple2`.
-}
varKernelUtilsTuple2 : (Can.Module -> Expectation) -> (() -> Expectation)
varKernelUtilsTuple2 expectFn _ =
    let
        modul =
            makeModule "testValue"
                (varKernelExpr 1 "Utils" "Tuple2")
    in
    expectFn modul


{-| Applies `expectFn` to a module whose `testValue` is the bare reference
`Elm.Kernel.Basics.pi`.

The case's label refers to the MLIR back end, where
`Compiler.Generate.MLIR.Intrinsics` has a float-constant intrinsic for
`Basics.pi`.

-}
varKernelBasicsPi : (Can.Module -> Expectation) -> (() -> Expectation)
varKernelBasicsPi expectFn _ =
    let
        modul =
            makeModule "testValue"
                (varKernelExpr 1 "Basics" "pi")
    in
    expectFn modul


{-| Applies `expectFn` to a module whose `testValue` is
`Elm.Kernel.Basics.add`, referenced without being called.

The case's label refers to the MLIR back end, where
`Compiler.Generate.MLIR.Intrinsics` has intrinsics for calls of `Basics.add`, a
kernel function that takes arguments.

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
-- KERNEL FUNCTIONS CALLED, PASSED OR COLLECTED
-- ============================================================================


{-| Returns the six cases in which a kernel function is called, or passed or
collected as a value, each applying `expectFn` to its module.
-}
kernelCallCases : (Can.Module -> Expectation) -> List TestCase
kernelCallCases expectFn =
    [ { label = "Calling kernel function with int arg", run = kernelCallWithIntArg expectFn }
    , { label = "Calling kernel function with multiple args", run = kernelCallWithMultipleArgs expectFn }
    , { label = "Nested kernel calls", run = nestedKernelCalls expectFn }
    , { label = "Multiple kernel calls in tuple", run = multipleKernelCallsInTuple expectFn }
    , { label = "Kernel function as higher-order argument", run = kernelAsHigherOrderArg expectFn }
    , { label = "Kernel function in list", run = kernelFunctionInList expectFn }
    ]


{-| Applies `expectFn` to a module whose `testValue` is
`Elm.Kernel.List.singleton 42`.
-}
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


{-| Applies `expectFn` to a module whose `testValue` is
`Elm.Kernel.List.cons 1 []`, one call with two arguments.
-}
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


{-| Applies `expectFn` to a module whose `testValue` is
`Elm.Kernel.List.head (Elm.Kernel.List.singleton 1)`.
-}
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


{-| Applies `expectFn` to a module whose `testValue` is the pair
`( Elm.Kernel.List.head [], Elm.Kernel.List.tail [] )`.
-}
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


{-| Applies `expectFn` to a module whose `testValue` is
`let apply f x = f x in apply Elm.Kernel.List.singleton 42`, so the kernel
function is an argument and is called through the parameter `f`.
-}
kernelAsHigherOrderArg : (Can.Module -> Expectation) -> (() -> Expectation)
kernelAsHigherOrderArg expectFn _ =
    let
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


{-| Applies `expectFn` to a module whose `testValue` is the list of the uncalled
references `Elm.Kernel.List.head`, `Elm.Kernel.List.tail` and
`Elm.Kernel.List.length`.
-}
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
-- KERNEL IN CONTEXT
-- ============================================================================


{-| Returns the eight cases in which a kernel reference sits inside a lambda, a
`let`, a list or a chain of calls, or is called with a pair and a list as its
arguments, each applying `expectFn` to its module.
-}
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


{-| Applies `expectFn` to a module whose `testValue` is
`\x -> Elm.Kernel.List.singleton x`.
-}
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


{-| Applies `expectFn` to a module whose `testValue` is
`let result = Elm.Kernel.List.singleton 1 in result`.
-}
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


{-| Applies `expectFn` to a module whose `testValue` is the list of the uncalled
references `Elm.Kernel.List.cons`, `Elm.Kernel.List.singleton` and
`Elm.Kernel.List.append`, all from one kernel module.
-}
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


{-| Applies `expectFn` to a module whose `testValue` is the list of the uncalled
references `Elm.Kernel.List.cons`, `Elm.Kernel.Platform.batch` and
`Elm.Kernel.Scheduler.succeed`, from three kernel modules.
-}
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


{-| Applies `expectFn` to a module whose `testValue` is
`Elm.Kernel.Utils.pair ( 1, 2 ) [ 3, 4 ]`.
-}
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


{-| Applies `expectFn` to a module whose `testValue` is
`Elm.Kernel.List.head (Elm.Kernel.List.tail (Elm.Kernel.List.singleton 1))`.
-}
chainedKernelCalls : (Can.Module -> Expectation) -> (() -> Expectation)
chainedKernelCalls expectFn _ =
    let
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


{-| Applies `expectFn` to a module whose `testValue` is
`let f = Elm.Kernel.List.singleton in f 42`, a call made through a local name
bound to a kernel function.
-}
kernelAliasDirectCall : (Can.Module -> Expectation) -> (() -> Expectation)
kernelAliasDirectCall expectFn _ =
    let
        kernelFn =
            varKernelExpr 2 "List" "singleton"

        fDef =
            makeDef "f" [] kernelFn

        body =
            callExpr 4 (varLocalExpr 5 "f") [ intExpr 6 42 ]

        modul =
            makeModule "testValue"
                (letExpr 1 fDef body)
    in
    expectFn modul


{-| Applies `expectFn` to a module whose `testValue` is
`let f = Elm.Kernel.List.singleton in let g = f in g 42`, a call made through a
local name bound to another local name that is bound to a kernel function.
-}
kernelAliasTransitiveCall : (Can.Module -> Expectation) -> (() -> Expectation)
kernelAliasTransitiveCall expectFn _ =
    let
        kernelFn =
            varKernelExpr 2 "List" "singleton"

        fDef =
            makeDef "f" [] kernelFn

        gDef =
            makeDef "g" [] (varLocalExpr 4 "f")

        innerBody =
            callExpr 6 (varLocalExpr 7 "g") [ intExpr 8 42 ]

        innerLet =
            letExpr 3 gDef innerBody

        modul =
            makeModule "testValue"
                (letExpr 1 fDef innerLet)
    in
    expectFn modul
