module SourceIR.KernelCompositionCases exposing (expectSuite)

{-| A program in which the result of one direct kernel call is the argument of
another, so that a check on a compiler stage is run against kernel calls that
are composed.

A direct kernel call is a call to a function named with a kernel module prefix,
such as `Elm.Kernel.List.reverse`, written in the program itself rather than
reached through a module such as `List`. Such a name refers to the kernel only
in a module that is canonicalized as part of a kernel package
(`Compiler.Canonicalize.Expression` owns that rule); anywhere else it is not
found.

The module checks nothing itself. `expectSuite` applies the expectation function
it is given to the program, and what is tested depends entirely on that
function.

The program is a module named `Test`, built by `makeKernelModule`, whose one
top-level value `testValue` is

    Elm.Kernel.List.reverse
        (Elm.Kernel.List.map2 (\x y -> x * y) [ 1, 2, 3 ] [ 4, 5, 6 ])

Both are kernel functions the C++ kernel exports (`Elm_Kernel_List_reverse`,
`Elm_Kernel_List_map2`); the kernel has no one-list `map`.

Among what is not tested: kernel modules other than `Elm.Kernel.List`, a chain
of more than two kernel calls, and composition written with `>>`, `<<`, `|>` or
`<|`.

-}

import Compiler.AST.Source as Src
import Compiler.AST.SourceBuilder exposing (binopsExpr, callExpr, intExpr, lambdaExpr, listExpr, makeKernelModule, pVar, qualVarExpr, varExpr)
import Compiler.BulkCheck exposing (TestCase, bulkCheck)
import Expect exposing (Expectation)
import Test exposing (Test)


{-| Returns one test, named `"Kernel composition "` followed by `condStr`, that
passes when `expectFn` accepts the program in this module.
-}
expectSuite : (Src.Module -> Expectation) -> String -> Test
expectSuite expectFn condStr =
    Test.test ("Kernel composition " ++ condStr) <|
        \_ -> bulkCheck (testCases expectFn)


{-| Returns the one labelled case, which applies `expectFn` to the program.
-}
testCases : (Src.Module -> Expectation) -> List TestCase
testCases expectFn =
    [ { label = "Chained List.map2 and List.reverse", run = chainedListOps expectFn }
    ]


{-| Applies `expectFn` to the program whose value is a call of
`Elm.Kernel.List.reverse` on the result of calling `Elm.Kernel.List.map2` with
the lambda `\x y -> x * y` and the lists `[ 1, 2, 3 ]` and `[ 4, 5, 6 ]`.
-}
chainedListOps : (Src.Module -> Expectation) -> (() -> Expectation)
chainedListOps expectFn _ =
    expectFn
        (makeKernelModule "testValue"
            (callExpr (qualVarExpr "Elm.Kernel.List" "reverse")
                [ callExpr (qualVarExpr "Elm.Kernel.List" "map2")
                    [ lambdaExpr [ pVar "x", pVar "y" ] (binopsExpr [ ( varExpr "x", "*" ) ] (varExpr "y"))
                    , listExpr [ intExpr 1, intExpr 2, intExpr 3 ]
                    , listExpr [ intExpr 4, intExpr 5, intExpr 6 ]
                    ]
                ]
            )
        )
