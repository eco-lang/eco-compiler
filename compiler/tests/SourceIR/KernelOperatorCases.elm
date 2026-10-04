module SourceIR.KernelOperatorCases exposing (expectSuite)

{-| Supplies programs that apply Elm's arithmetic, division, power, pipe, cons
and append operators, so that the stage tests that run the standard source
programs (`SourceIR.Suite.StandardTestSuites`) are run against each of those
operators.

The module asserts nothing itself. `expectSuite` is given an expectation
function, and the stage and the property checked are whatever that function
checks. Every case runs inside one test through `Compiler.BulkCheck`, so a
failure reports only the first failing case.

Every program is built with `makeKernelModule`: a module `Test` whose one value,
`testValue`, is the expression shown below, importing the kernel import set that
`Compiler.AST.SourceBuilder` lists. The cases are:

  - Arithmetic: a `let` binding `a = 3 + 4`, `b = 10 - 3` and `c = 6 * 7`,
    whose body is `a + b + c`.
  - Float division: `10.0 / 3.0`.
  - Integer division: `10 // 3`.
  - Power: `2 ^ 10`.
  - Pipe: `5 |> Elm.Kernel.Basics.abs`, which pipes into the kernel-qualified
    name `Elm.Kernel.Basics.abs` rather than into `Basics.abs`.
  - Cons: `0 :: [ 1, 2 ]`.
  - Append: `[ 1 ] ++ [ 2 ]`, on lists.

Among what is not tested: `++` on strings, `<|`, `>>` and `<<`, equality and
comparison operators, an operator used as a function value such as `(+)`, and
a chain that mixes operators of different precedence.

-}

import Compiler.AST.Source as Src
import Compiler.AST.SourceBuilder exposing (binopsExpr, define, floatExpr, intExpr, letExpr, listExpr, makeKernelModule, qualVarExpr, varExpr)
import Compiler.BulkCheck exposing (TestCase, bulkCheck)
import Expect exposing (Expectation)
import Test exposing (Test)


{-| Builds one test, named `Kernel operators` followed by `condStr`, that passes
when `expectFn` passes for every program in this module.
-}
expectSuite : (Src.Module -> Expectation) -> String -> Test
expectSuite expectFn condStr =
    Test.test ("Kernel operators " ++ condStr) <|
        \_ -> bulkCheck (testCases expectFn)


{-| Returns the labelled cases, each applying `expectFn` to one program.
-}
testCases : (Src.Module -> Expectation) -> List TestCase
testCases expectFn =
    [ { label = "Arithmetic operators", run = arithmeticOps expectFn }
    , { label = "Float division", run = \_ -> expectFn (makeKernelModule "testValue" (binopsExpr [ ( floatExpr 10.0, "/" ) ] (floatExpr 3.0))) }
    , { label = "Integer division", run = \_ -> expectFn (makeKernelModule "testValue" (binopsExpr [ ( intExpr 10, "//" ) ] (intExpr 3))) }
    , { label = "Power operator", run = \_ -> expectFn (makeKernelModule "testValue" (binopsExpr [ ( intExpr 2, "^" ) ] (intExpr 10))) }
    , { label = "Pipe operator", run = \_ -> expectFn (makeKernelModule "testValue" (binopsExpr [ ( intExpr 5, "|>" ) ] (qualVarExpr "Elm.Kernel.Basics" "abs"))) }
    , { label = ":: cons operator", run = \_ -> expectFn (makeKernelModule "testValue" (binopsExpr [ ( intExpr 0, "::" ) ] (listExpr [ intExpr 1, intExpr 2 ]))) }
    , { label = "++ append operator", run = \_ -> expectFn (makeKernelModule "testValue" (binopsExpr [ ( listExpr [ intExpr 1 ], "++" ) ] (listExpr [ intExpr 2 ]))) }
    ]


{-| Applies `expectFn` to the program that binds `3 + 4`, `10 - 3` and `6 * 7`
in a `let` and adds the three results.
-}
arithmeticOps : (Src.Module -> Expectation) -> (() -> Expectation)
arithmeticOps expectFn _ =
    expectFn
        (makeKernelModule "testValue"
            (letExpr
                [ define "a" [] (binopsExpr [ ( intExpr 3, "+" ) ] (intExpr 4))
                , define "b" [] (binopsExpr [ ( intExpr 10, "-" ) ] (intExpr 3))
                , define "c" [] (binopsExpr [ ( intExpr 6, "*" ) ] (intExpr 7))
                ]
                (binopsExpr [ ( varExpr "a", "+" ), ( varExpr "b", "+" ) ] (varExpr "c"))
            )
        )
