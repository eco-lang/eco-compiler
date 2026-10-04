module SourceIR.KernelContextCases exposing (expectSuite)

{-| Programs that call kernel functions from inside a lambda, a `let` binding
and other calls, so that a compiler stage can be checked on kernel calls in
those positions and not only at the top of a definition.

A kernel function is one the runtime implements rather than Elm code, written
as a qualified reference such as `Elm.Kernel.Basics.add`. When a module of a
kernel package is canonicalized, such a reference becomes a direct kernel
reference (`Can.VarKernel`). None of the kernels used here has a declared type
for the type checker, so the type of each call comes only from the code around
it, and `Compiler.Type.PostSolve` records a type for each kernel after solving.
What these programs vary is therefore the code around the call.

This module asserts nothing. `expectSuite` gives the programs, in order, to
the expectation function its caller supplies, stopping at the first one that
function rejects, and that function decides what is checked. The programs run
as one test through `Compiler.BulkCheck.bulkCheck`, so a failure names only the
first program that fails.

Every program is a module named `Test`, built with `makeKernelModule`, whose
one value `testValue` has no arguments and no annotation. In the list below,
`add`, `sub` and `mul` are the `Elm.Kernel.Basics` functions of those names.

  - "Kernel in lambda": `testValue` is `\x -> add x 1`.
  - "Kernel in let binding": `testValue` is `let result = add 3 4 in result`.
  - "Kernel nested calls": `testValue` is `add (mul 2 3) (mul 4 5)`.
  - "Kernel chained arithmetic": `testValue` is `add (add 1 2) (sub 10 5)`,
    so `add` is also called inside a call to itself.

Among what is not tested: a kernel function used as a value without being
called, a kernel call with fewer arguments than the kernel takes, a kernel
call inside an annotated definition, and kernels outside
`Elm.Kernel.Basics`.

-}

import Compiler.AST.Source as Src
import Compiler.AST.SourceBuilder exposing (callExpr, define, intExpr, lambdaExpr, letExpr, makeKernelModule, pVar, qualVarExpr, varExpr)
import Compiler.BulkCheck exposing (TestCase, bulkCheck)
import Expect exposing (Expectation)
import Test exposing (Test)


{-| Returns one test, named "Kernel context " followed by `condStr`, that
gives the programs in this module to `expectFn` in turn until one is rejected,
and then fails with that program's label.
-}
expectSuite : (Src.Module -> Expectation) -> String -> Test
expectSuite expectFn condStr =
    Test.test ("Kernel context " ++ condStr) <|
        \_ -> bulkCheck (testCases expectFn)


{-| Returns the four programs as labelled cases, each giving its program to
`expectFn` when it is run.
-}
testCases : (Src.Module -> Expectation) -> List TestCase
testCases expectFn =
    [ { label = "Kernel in lambda", run = kernelInLambda expectFn }
    , { label = "Kernel in let binding", run = kernelInLetBinding expectFn }
    , { label = "Kernel nested calls", run = kernelNestedCalls expectFn }
    , { label = "Kernel chained arithmetic", run = kernelChainedArith expectFn }
    ]


{-| Gives `expectFn` the program whose `testValue` is the lambda
`\x -> Elm.Kernel.Basics.add x 1`.
-}
kernelInLambda : (Src.Module -> Expectation) -> (() -> Expectation)
kernelInLambda expectFn _ =
    expectFn
        (makeKernelModule "testValue"
            (lambdaExpr [ pVar "x" ]
                (callExpr (qualVarExpr "Elm.Kernel.Basics" "add") [ varExpr "x", intExpr 1 ])
            )
        )


{-| Gives `expectFn` the program whose `testValue` binds
`Elm.Kernel.Basics.add 3 4` to `result` in a `let` and returns `result`.
-}
kernelInLetBinding : (Src.Module -> Expectation) -> (() -> Expectation)
kernelInLetBinding expectFn _ =
    expectFn
        (makeKernelModule "testValue"
            (letExpr
                [ define "result" [] (callExpr (qualVarExpr "Elm.Kernel.Basics" "add") [ intExpr 3, intExpr 4 ]) ]
                (varExpr "result")
            )
        )


{-| Gives `expectFn` the program whose `testValue` is
`Elm.Kernel.Basics.add` applied to two calls of `Elm.Kernel.Basics.mul`.
-}
kernelNestedCalls : (Src.Module -> Expectation) -> (() -> Expectation)
kernelNestedCalls expectFn _ =
    expectFn
        (makeKernelModule "testValue"
            (callExpr (qualVarExpr "Elm.Kernel.Basics" "add")
                [ callExpr (qualVarExpr "Elm.Kernel.Basics" "mul") [ intExpr 2, intExpr 3 ]
                , callExpr (qualVarExpr "Elm.Kernel.Basics" "mul") [ intExpr 4, intExpr 5 ]
                ]
            )
        )


{-| Gives `expectFn` the program whose `testValue` is
`Elm.Kernel.Basics.add` applied to a call of `Elm.Kernel.Basics.add` and a
call of `Elm.Kernel.Basics.sub`.
-}
kernelChainedArith : (Src.Module -> Expectation) -> (() -> Expectation)
kernelChainedArith expectFn _ =
    expectFn
        (makeKernelModule "testValue"
            (callExpr (qualVarExpr "Elm.Kernel.Basics" "add")
                [ callExpr (qualVarExpr "Elm.Kernel.Basics" "add") [ intExpr 1, intExpr 2 ]
                , callExpr (qualVarExpr "Elm.Kernel.Basics" "sub") [ intExpr 10, intExpr 5 ]
                ]
            )
        )
