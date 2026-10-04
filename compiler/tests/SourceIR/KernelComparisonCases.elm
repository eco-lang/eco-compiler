module SourceIR.KernelComparisonCases exposing (expectSuite)

{-| Programs that apply Elm's comparison, equality and logical operators to
literals of the primitive types, so that a check on a compiler stage is run
against each of them.

The module checks nothing itself. `expectSuite` applies the expectation function
it is given to each program, and what is tested depends entirely on that
function. The programs are run as one test through `Compiler.BulkCheck`, so only
the first program the function rejects is reported.

Each program is a module named `Test`, built by `makeKernelModule`, whose one
top-level value `testValue` is the expression listed below. Every operand is a
literal, and every operator expression holds a single operator.

  - "Int comparison operators" is a `let` binding `1 < 2`, `2 > 1`, `1 <= 1`,
    `1 >= 1`, `1 == 1` and `1 /= 2`, whose result is the `<` binding; the other
    five bindings are not used.
  - "Float comparison op" is `1.5 < 2.5`.
  - "String equality op" is `"hello" == "world"`.
  - "Bool logical ops" is a `let` binding `True && False` and `True || False`,
    whose result is the `&&` binding.
  - "Char equality op" is `'a' == 'b'`.

Among what is not tested: ordering operators on `String` or `Char`, `/=` on
anything but integer literals, `==` on `Float`, `compare`, `max`, `min`, `not`
and `xor`, and operators applied to anything other than literals.

-}

import Compiler.AST.Source as Src
import Compiler.AST.SourceBuilder exposing (binopsExpr, boolExpr, chrExpr, define, floatExpr, intExpr, letExpr, makeKernelModule, strExpr, varExpr)
import Compiler.BulkCheck exposing (TestCase, bulkCheck)
import Expect exposing (Expectation)
import Test exposing (Test)


{-| Returns one test, named `"Kernel comparisons "` followed by `condStr`, that
passes when `expectFn` accepts every program in this module, and that fails with
the label of the first program it rejects.
-}
expectSuite : (Src.Module -> Expectation) -> String -> Test
expectSuite expectFn condStr =
    Test.test ("Kernel comparisons " ++ condStr) <|
        \_ -> bulkCheck (testCases expectFn)


{-| Returns the five labelled cases, each of which applies `expectFn` to one
program.
-}
testCases : (Src.Module -> Expectation) -> List TestCase
testCases expectFn =
    [ { label = "Int comparison operators", run = intComparisons expectFn }
    , { label = "Float comparison op", run = \_ -> expectFn (makeKernelModule "testValue" (binopsExpr [ ( floatExpr 1.5, "<" ) ] (floatExpr 2.5))) }
    , { label = "String equality op", run = \_ -> expectFn (makeKernelModule "testValue" (binopsExpr [ ( strExpr "hello", "==" ) ] (strExpr "world"))) }
    , { label = "Bool logical ops", run = boolLogicalOps expectFn }
    , { label = "Char equality op", run = \_ -> expectFn (makeKernelModule "testValue" (binopsExpr [ ( chrExpr "a", "==" ) ] (chrExpr "b"))) }
    ]


{-| Applies `expectFn` to the program whose value is a `let` binding each of the
six comparison and equality operators on two integer literals, and whose result
is the `<` binding.
-}
intComparisons : (Src.Module -> Expectation) -> (() -> Expectation)
intComparisons expectFn _ =
    expectFn
        (makeKernelModule "testValue"
            (letExpr
                [ define "lt" [] (binopsExpr [ ( intExpr 1, "<" ) ] (intExpr 2))
                , define "gt" [] (binopsExpr [ ( intExpr 2, ">" ) ] (intExpr 1))
                , define "le" [] (binopsExpr [ ( intExpr 1, "<=" ) ] (intExpr 1))
                , define "ge" [] (binopsExpr [ ( intExpr 1, ">=" ) ] (intExpr 1))
                , define "eq" [] (binopsExpr [ ( intExpr 1, "==" ) ] (intExpr 1))
                , define "ne" [] (binopsExpr [ ( intExpr 1, "/=" ) ] (intExpr 2))
                ]
                (varExpr "lt")
            )
        )


{-| Applies `expectFn` to the program whose value is a `let` binding
`True && False` and `True || False`, and whose result is the `&&` binding.
-}
boolLogicalOps : (Src.Module -> Expectation) -> (() -> Expectation)
boolLogicalOps expectFn _ =
    expectFn
        (makeKernelModule "testValue"
            (letExpr
                [ define "a" [] (binopsExpr [ ( boolExpr True, "&&" ) ] (boolExpr False))
                , define "b" [] (binopsExpr [ ( boolExpr True, "||" ) ] (boolExpr False))
                ]
                (varExpr "a")
            )
        )
