module SourceIR.BinopCases exposing (expectSuite)

{-| Programs that use binary operators, for a compiler stage's tests to run
through. They exercise a stage on operators used alone, in chains, inside
other expressions, and with operands that are themselves compound
expressions.

This module only builds the programs. What is checked about each one is
decided by the expectation function given to `expectSuite`, so nothing here
asserts how an operator is compiled. Each program is built with
`Compiler.AST.SourceBuilder.makeModule`, whose docstring gives the module it
makes; the expression under test is the body of its one value, `testValue`.
An operator chain is built with `binopsExpr`, which stores the chain flat,
with no precedence applied.

The programs, by section:

  - Arithmetic: `1 + 2`, `5 - 3`, `4 * 5`, `10 // 3` and `10 % 3` on `Int`
    literals, and `10.0 / 2.0` and `2.0 ^ 3.0` on `Float` literals. elm/core
    has no `%` operator, so that program only resolves against a `Basics`
    interface that declares one.
  - Comparison: `1 == 1`, `1 /= 2`, `1 < 2`, `2 > 1`, `1 <= 1` and `2 >= 1`
    on `Int` literals, and `"a" < "b"`.
  - Logical: `True && False`, `True || False`, `True && True && True` and
    `False || False || True`.
  - String append: `"hello" ++ " world"`, `"a" ++ "b" ++ "c"` and
    `"" ++ "test"`.
  - List: `[ 1, 2 ] ++ [ 3, 4 ]`, `1 :: [ 2, 3 ]` and `42 :: []`.
  - Chains of more than one operator, with no parentheses: `1 + 2 + 3`,
    `1 + 2 * 3`, `1 + 2 + 3 + 4 + 5` and `1 + 2 - 3 * 4`.
  - Operators inside other expressions: `( 1 + 2, 3 )`, `[ 1 + 2, 3 ]`,
    `( 1 + 2, 3 * 4 )`, `x + y` with `x` and `y` bound by a `let`, `-1 + 2`,
    and `(1 + 2) * (3 + 4)`.
  - Operators with compound operands: `f 1 + 2` with `f x = x` bound by a
    `let`, `r.x + r.y` with `r = { x = 1, y = 2 }` bound by a `let`,
    `(if True then 1 else 0) + 2`, `x + 2` in the body of a `let` that binds
    `x = 1`, and `(1 + 2) * 3`.

Two of these programs have a shape the parser never produces. In
`(1 + 2) * (3 + 4)` the two inner chains, and in `(if True then 1 else 0) + 2`
the `if`, are operands of the chain directly, with no `Parens` node around
them. A chain the parser builds never has another chain as an operand, and has
an `if` only as its last operand. `(1 + 2) * 3` is the one program whose
parenthesised operand has a `Parens` node.

Among what is not tested: the pipe operators `|>` and `<|`, the composition
operators `>>` and `<<`, an operator used as a function such as `(+)`, a
comparison of `Float` values, and a chain of non-associative operators such as
`1 < 2 < 3`.

-}

import Compiler.AST.Source as Src
import Compiler.AST.SourceBuilder
    exposing
        ( accessExpr
        , binopsExpr
        , boolExpr
        , callExpr
        , define
        , floatExpr
        , ifExpr
        , intExpr
        , letExpr
        , listExpr
        , makeModule
        , negateExpr
        , pVar
        , parensExpr
        , recordExpr
        , strExpr
        , tupleExpr
        , varExpr
        )
import Compiler.BulkCheck exposing (TestCase, bulkCheck)
import Expect exposing (Expectation)
import Test exposing (Test)


{-| Builds one test, named "Binary operator expressions " followed by
`condStr`, that applies `expectFn` to every program in this module, in the
order of the sections. It is run with `Compiler.BulkCheck.bulkCheck`, so a
failure names the first program whose expectation fails, and the programs
after it are not run.
-}
expectSuite : (Src.Module -> Expectation) -> String -> Test
expectSuite expectFn condStr =
    Test.test ("Binary operator expressions " ++ condStr) <|
        \_ -> bulkCheck (testCases expectFn)


{-| Returns every case in this module, each a label and the application of
`expectFn` to its program, section by section.
-}
testCases : (Src.Module -> Expectation) -> List TestCase
testCases expectFn =
    List.concat
        [ arithmeticBinopCases expectFn
        , comparisonBinopCases expectFn
        , logicalBinopCases expectFn
        , stringBinopCases expectFn
        , listBinopCases expectFn
        , chainedBinopCases expectFn
        , nestedBinopCases expectFn
        , binopWithExpressionsCases expectFn
        ]



-- ============================================================================
-- ARITHMETIC BINOPS
-- ============================================================================


{-| Returns the cases that apply each arithmetic operator once.
-}
arithmeticBinopCases : (Src.Module -> Expectation) -> List TestCase
arithmeticBinopCases expectFn =
    [ { label = "Simple addition", run = simpleAddition expectFn }
    , { label = "Simple subtraction", run = simpleSubtraction expectFn }
    , { label = "Simple multiplication", run = simpleMultiplication expectFn }
    , { label = "Simple division", run = simpleDivision expectFn }
    , { label = "Integer division", run = integerDivision expectFn }
    , { label = "Modulo", run = moduloOp expectFn }
    , { label = "Power", run = powerOp expectFn }
    ]


{-| Applies `expectFn` to the program `1 + 2`.
-}
simpleAddition : (Src.Module -> Expectation) -> (() -> Expectation)
simpleAddition expectFn _ =
    let
        modul =
            makeModule "testValue" (binopsExpr [ ( intExpr 1, "+" ) ] (intExpr 2))
    in
    expectFn modul


{-| Applies `expectFn` to the program `5 - 3`.
-}
simpleSubtraction : (Src.Module -> Expectation) -> (() -> Expectation)
simpleSubtraction expectFn _ =
    let
        modul =
            makeModule "testValue" (binopsExpr [ ( intExpr 5, "-" ) ] (intExpr 3))
    in
    expectFn modul


{-| Applies `expectFn` to the program `4 * 5`.
-}
simpleMultiplication : (Src.Module -> Expectation) -> (() -> Expectation)
simpleMultiplication expectFn _ =
    let
        modul =
            makeModule "testValue" (binopsExpr [ ( intExpr 4, "*" ) ] (intExpr 5))
    in
    expectFn modul


{-| Applies `expectFn` to the program `10.0 / 2.0`.
-}
simpleDivision : (Src.Module -> Expectation) -> (() -> Expectation)
simpleDivision expectFn _ =
    let
        modul =
            makeModule "testValue" (binopsExpr [ ( floatExpr 10.0, "/" ) ] (floatExpr 2.0))
    in
    expectFn modul


{-| Applies `expectFn` to the program `10 // 3`.
-}
integerDivision : (Src.Module -> Expectation) -> (() -> Expectation)
integerDivision expectFn _ =
    let
        modul =
            makeModule "testValue" (binopsExpr [ ( intExpr 10, "//" ) ] (intExpr 3))
    in
    expectFn modul


{-| Applies `expectFn` to the program `10 % 3`. `%` is not an elm/core
operator, so the program only resolves against a `Basics` interface that
declares one.
-}
moduloOp : (Src.Module -> Expectation) -> (() -> Expectation)
moduloOp expectFn _ =
    let
        modul =
            makeModule "testValue" (binopsExpr [ ( intExpr 10, "%" ) ] (intExpr 3))
    in
    expectFn modul


{-| Applies `expectFn` to the program `2.0 ^ 3.0`.
-}
powerOp : (Src.Module -> Expectation) -> (() -> Expectation)
powerOp expectFn _ =
    let
        modul =
            makeModule "testValue" (binopsExpr [ ( floatExpr 2.0, "^" ) ] (floatExpr 3.0))
    in
    expectFn modul



-- ============================================================================
-- COMPARISON BINOPS
-- ============================================================================


{-| Returns the cases that apply one comparison operator each: all six on
`Int` literals, and `<` again on `String` literals.
-}
comparisonBinopCases : (Src.Module -> Expectation) -> List TestCase
comparisonBinopCases expectFn =
    [ { label = "Equals", run = equalsOp expectFn }
    , { label = "Not equals", run = notEqualsOp expectFn }
    , { label = "Less than", run = lessThan expectFn }
    , { label = "Greater than", run = greaterThan expectFn }
    , { label = "Less than or equal", run = lessThanOrEqual expectFn }
    , { label = "Greater than or equal", run = greaterThanOrEqual expectFn }
    , { label = "Compare on strings", run = compareOnStrings expectFn }
    ]


{-| Applies `expectFn` to the program `1 == 1`.
-}
equalsOp : (Src.Module -> Expectation) -> (() -> Expectation)
equalsOp expectFn _ =
    let
        modul =
            makeModule "testValue" (binopsExpr [ ( intExpr 1, "==" ) ] (intExpr 1))
    in
    expectFn modul


{-| Applies `expectFn` to the program `1 /= 2`.
-}
notEqualsOp : (Src.Module -> Expectation) -> (() -> Expectation)
notEqualsOp expectFn _ =
    let
        modul =
            makeModule "testValue" (binopsExpr [ ( intExpr 1, "/=" ) ] (intExpr 2))
    in
    expectFn modul


{-| Applies `expectFn` to the program `1 < 2`.
-}
lessThan : (Src.Module -> Expectation) -> (() -> Expectation)
lessThan expectFn _ =
    let
        modul =
            makeModule "testValue" (binopsExpr [ ( intExpr 1, "<" ) ] (intExpr 2))
    in
    expectFn modul


{-| Applies `expectFn` to the program `2 > 1`.
-}
greaterThan : (Src.Module -> Expectation) -> (() -> Expectation)
greaterThan expectFn _ =
    let
        modul =
            makeModule "testValue" (binopsExpr [ ( intExpr 2, ">" ) ] (intExpr 1))
    in
    expectFn modul


{-| Applies `expectFn` to the program `1 <= 1`.
-}
lessThanOrEqual : (Src.Module -> Expectation) -> (() -> Expectation)
lessThanOrEqual expectFn _ =
    let
        modul =
            makeModule "testValue" (binopsExpr [ ( intExpr 1, "<=" ) ] (intExpr 1))
    in
    expectFn modul


{-| Applies `expectFn` to the program `2 >= 1`.
-}
greaterThanOrEqual : (Src.Module -> Expectation) -> (() -> Expectation)
greaterThanOrEqual expectFn _ =
    let
        modul =
            makeModule "testValue" (binopsExpr [ ( intExpr 2, ">=" ) ] (intExpr 1))
    in
    expectFn modul


{-| Applies `expectFn` to the program `"a" < "b"`, a comparison of two
`String` literals.
-}
compareOnStrings : (Src.Module -> Expectation) -> (() -> Expectation)
compareOnStrings expectFn _ =
    let
        modul =
            makeModule "testValue" (binopsExpr [ ( strExpr "a", "<" ) ] (strExpr "b"))
    in
    expectFn modul



-- ============================================================================
-- LOGICAL BINOPS
-- ============================================================================


{-| Returns the cases that use `&&` and `||`, once each and in chains of
three operands.
-}
logicalBinopCases : (Src.Module -> Expectation) -> List TestCase
logicalBinopCases expectFn =
    [ { label = "And", run = andOp expectFn }
    , { label = "Or", run = orOp expectFn }
    , { label = "Chained and", run = chainedAnd expectFn }
    , { label = "Chained or", run = chainedOr expectFn }
    ]


{-| Applies `expectFn` to the program `True && False`.
-}
andOp : (Src.Module -> Expectation) -> (() -> Expectation)
andOp expectFn _ =
    let
        modul =
            makeModule "testValue" (binopsExpr [ ( boolExpr True, "&&" ) ] (boolExpr False))
    in
    expectFn modul


{-| Applies `expectFn` to the program `True || False`.
-}
orOp : (Src.Module -> Expectation) -> (() -> Expectation)
orOp expectFn _ =
    let
        modul =
            makeModule "testValue" (binopsExpr [ ( boolExpr True, "||" ) ] (boolExpr False))
    in
    expectFn modul


{-| Applies `expectFn` to the program `True && True && True`.
-}
chainedAnd : (Src.Module -> Expectation) -> (() -> Expectation)
chainedAnd expectFn _ =
    let
        modul =
            makeModule "testValue"
                (binopsExpr
                    [ ( boolExpr True, "&&" )
                    , ( boolExpr True, "&&" )
                    ]
                    (boolExpr True)
                )
    in
    expectFn modul


{-| Applies `expectFn` to the program `False || False || True`.
-}
chainedOr : (Src.Module -> Expectation) -> (() -> Expectation)
chainedOr expectFn _ =
    let
        modul =
            makeModule "testValue"
                (binopsExpr
                    [ ( boolExpr False, "||" )
                    , ( boolExpr False, "||" )
                    ]
                    (boolExpr True)
                )
    in
    expectFn modul



-- ============================================================================
-- STRING BINOPS
-- ============================================================================


{-| Returns the cases that append `String` literals with `++`.
-}
stringBinopCases : (Src.Module -> Expectation) -> List TestCase
stringBinopCases expectFn =
    [ { label = "String concat", run = stringConcat expectFn }
    , { label = "Multiple string concat", run = multipleStringConcat expectFn }
    , { label = "String concat with empty", run = stringConcatWithEmpty expectFn }
    ]


{-| Applies `expectFn` to the program `"hello" ++ " world"`.
-}
stringConcat : (Src.Module -> Expectation) -> (() -> Expectation)
stringConcat expectFn _ =
    let
        modul =
            makeModule "testValue" (binopsExpr [ ( strExpr "hello", "++" ) ] (strExpr " world"))
    in
    expectFn modul


{-| Applies `expectFn` to the program `"a" ++ "b" ++ "c"`.
-}
multipleStringConcat : (Src.Module -> Expectation) -> (() -> Expectation)
multipleStringConcat expectFn _ =
    let
        modul =
            makeModule "testValue"
                (binopsExpr
                    [ ( strExpr "a", "++" )
                    , ( strExpr "b", "++" )
                    ]
                    (strExpr "c")
                )
    in
    expectFn modul


{-| Applies `expectFn` to the program `"" ++ "test"`, whose left operand is
the empty string.
-}
stringConcatWithEmpty : (Src.Module -> Expectation) -> (() -> Expectation)
stringConcatWithEmpty expectFn _ =
    let
        modul =
            makeModule "testValue" (binopsExpr [ ( strExpr "", "++" ) ] (strExpr "test"))
    in
    expectFn modul



-- ============================================================================
-- LIST BINOPS
-- ============================================================================


{-| Returns the cases that use `++` on lists and `::`.
-}
listBinopCases : (Src.Module -> Expectation) -> List TestCase
listBinopCases expectFn =
    [ { label = "List append", run = listAppend expectFn }
    , { label = "Cons operator", run = consOperator expectFn }
    , { label = "Cons with constant", run = consWithConstant expectFn }
    ]


{-| Applies `expectFn` to the program `[ 1, 2 ] ++ [ 3, 4 ]`.
-}
listAppend : (Src.Module -> Expectation) -> (() -> Expectation)
listAppend expectFn _ =
    let
        modul =
            makeModule "testValue"
                (binopsExpr
                    [ ( listExpr [ intExpr 1, intExpr 2 ], "++" ) ]
                    (listExpr [ intExpr 3, intExpr 4 ])
                )
    in
    expectFn modul


{-| Applies `expectFn` to the program `1 :: [ 2, 3 ]`.
-}
consOperator : (Src.Module -> Expectation) -> (() -> Expectation)
consOperator expectFn _ =
    let
        modul =
            makeModule "testValue"
                (binopsExpr
                    [ ( intExpr 1, "::" ) ]
                    (listExpr [ intExpr 2, intExpr 3 ])
                )
    in
    expectFn modul


{-| Applies `expectFn` to the program `42 :: []`, a cons onto the empty list.
-}
consWithConstant : (Src.Module -> Expectation) -> (() -> Expectation)
consWithConstant expectFn _ =
    let
        modul =
            makeModule "testValue"
                (binopsExpr
                    [ ( intExpr 42, "::" ) ]
                    (listExpr [])
                )
    in
    expectFn modul



-- ============================================================================
-- CHAINED BINOPS
-- ============================================================================


{-| Returns the cases with more than one operator in a chain and no
parentheses, so that the operators' precedence and associativity decide how
they group.
-}
chainedBinopCases : (Src.Module -> Expectation) -> List TestCase
chainedBinopCases expectFn =
    [ { label = "Three-element addition chain", run = threeElementAdditionChain expectFn }
    , { label = "Mixed arithmetic chain", run = mixedArithmeticChain expectFn }
    , { label = "Long chain", run = longChain expectFn }
    , { label = "Chain with different operators", run = chainWithDifferentOperators expectFn }
    ]


{-| Applies `expectFn` to the program `1 + 2 + 3`.
-}
threeElementAdditionChain : (Src.Module -> Expectation) -> (() -> Expectation)
threeElementAdditionChain expectFn _ =
    let
        modul =
            makeModule "testValue"
                (binopsExpr
                    [ ( intExpr 1, "+" )
                    , ( intExpr 2, "+" )
                    ]
                    (intExpr 3)
                )
    in
    expectFn modul


{-| Applies `expectFn` to the program `1 + 2 * 3`.
-}
mixedArithmeticChain : (Src.Module -> Expectation) -> (() -> Expectation)
mixedArithmeticChain expectFn _ =
    let
        modul =
            makeModule "testValue"
                (binopsExpr
                    [ ( intExpr 1, "+" )
                    , ( intExpr 2, "*" )
                    ]
                    (intExpr 3)
                )
    in
    expectFn modul


{-| Applies `expectFn` to the program `1 + 2 + 3 + 4 + 5`.
-}
longChain : (Src.Module -> Expectation) -> (() -> Expectation)
longChain expectFn _ =
    let
        modul =
            makeModule "testValue"
                (binopsExpr
                    [ ( intExpr 1, "+" )
                    , ( intExpr 2, "+" )
                    , ( intExpr 3, "+" )
                    , ( intExpr 4, "+" )
                    ]
                    (intExpr 5)
                )
    in
    expectFn modul


{-| Applies `expectFn` to the program `1 + 2 - 3 * 4`.
-}
chainWithDifferentOperators : (Src.Module -> Expectation) -> (() -> Expectation)
chainWithDifferentOperators expectFn _ =
    let
        modul =
            makeModule "testValue"
                (binopsExpr
                    [ ( intExpr 1, "+" )
                    , ( intExpr 2, "-" )
                    , ( intExpr 3, "*" )
                    ]
                    (intExpr 4)
                )
    in
    expectFn modul



-- ============================================================================
-- NESTED BINOPS
-- ============================================================================


{-| Returns the cases with an operator inside a tuple, a list or a `let`,
applied to a negation, or with operator chains as operands.
-}
nestedBinopCases : (Src.Module -> Expectation) -> List TestCase
nestedBinopCases expectFn =
    [ { label = "Binop in tuple", run = binopInTuple expectFn }
    , { label = "Binop in list", run = binopInList expectFn }
    , { label = "Multiple binops in tuple", run = multipleBinopsInTuple expectFn }
    , { label = "Binop with variable operands", run = binopWithVariableOperands expectFn }
    , { label = "Binop with negate", run = binopWithNegate expectFn }
    , { label = "Complex nested binops", run = complexNestedBinops expectFn }
    ]


{-| Applies `expectFn` to the program `( 1 + 2, 3 )`.
-}
binopInTuple : (Src.Module -> Expectation) -> (() -> Expectation)
binopInTuple expectFn _ =
    let
        sum =
            binopsExpr [ ( intExpr 1, "+" ) ] (intExpr 2)

        modul =
            makeModule "testValue" (tupleExpr sum (intExpr 3))
    in
    expectFn modul


{-| Applies `expectFn` to the program `[ 1 + 2, 3 ]`.
-}
binopInList : (Src.Module -> Expectation) -> (() -> Expectation)
binopInList expectFn _ =
    let
        sum =
            binopsExpr [ ( intExpr 1, "+" ) ] (intExpr 2)

        modul =
            makeModule "testValue" (listExpr [ sum, intExpr 3 ])
    in
    expectFn modul


{-| Applies `expectFn` to the program `( 1 + 2, 3 * 4 )`.
-}
multipleBinopsInTuple : (Src.Module -> Expectation) -> (() -> Expectation)
multipleBinopsInTuple expectFn _ =
    let
        sum =
            binopsExpr [ ( intExpr 1, "+" ) ] (intExpr 2)

        prod =
            binopsExpr [ ( intExpr 3, "*" ) ] (intExpr 4)

        modul =
            makeModule "testValue" (tupleExpr sum prod)
    in
    expectFn modul


{-| Applies `expectFn` to a program whose value is `x + y`, inside a `let`
that binds `x = 1` and `y = 2`.
-}
binopWithVariableOperands : (Src.Module -> Expectation) -> (() -> Expectation)
binopWithVariableOperands expectFn _ =
    let
        def1 =
            define "x" [] (intExpr 1)

        def2 =
            define "y" [] (intExpr 2)

        sum =
            binopsExpr [ ( varExpr "x", "+" ) ] (varExpr "y")

        modul =
            makeModule "testValue" (letExpr [ def1, def2 ] sum)
    in
    expectFn modul


{-| Applies `expectFn` to the program `-1 + 2`, where the left operand is a
negation of the literal `1`.
-}
binopWithNegate : (Src.Module -> Expectation) -> (() -> Expectation)
binopWithNegate expectFn _ =
    let
        modul =
            makeModule "testValue"
                (binopsExpr [ ( negateExpr (intExpr 1), "+" ) ] (intExpr 2))
    in
    expectFn modul


{-| Applies `expectFn` to a program meaning `(1 + 2) * (3 + 4)`. The two
inner chains are operands of the outer one directly, with no `Parens` node
around them, a shape the parser never produces.
-}
complexNestedBinops : (Src.Module -> Expectation) -> (() -> Expectation)
complexNestedBinops expectFn _ =
    let
        inner1 =
            binopsExpr [ ( intExpr 1, "+" ) ] (intExpr 2)

        inner2 =
            binopsExpr [ ( intExpr 3, "+" ) ] (intExpr 4)

        modul =
            makeModule "testValue"
                (binopsExpr [ ( inner1, "*" ) ] inner2)
    in
    expectFn modul



-- ============================================================================
-- BINOP WITH EXPRESSIONS
-- ============================================================================


{-| Returns the cases whose operands are a call, a record field access, an
`if`, a variable bound by a `let`, or a parenthesised chain.
-}
binopWithExpressionsCases : (Src.Module -> Expectation) -> List TestCase
binopWithExpressionsCases expectFn =
    [ { label = "Binop with function call", run = binopWithFunctionCall expectFn }
    , { label = "Binop with record access", run = binopWithRecordAccess expectFn }
    , { label = "Binop with if expression", run = binopWithIfExpr expectFn }
    , { label = "Binop inside let body", run = binopInsideLetBody expectFn }
    , { label = "Binop with parens", run = binopWithParens expectFn }
    ]


{-| Applies `expectFn` to a program whose value is `f 1 + 2`, inside a `let`
that binds `f x = x`.
-}
binopWithFunctionCall : (Src.Module -> Expectation) -> (() -> Expectation)
binopWithFunctionCall expectFn _ =
    let
        fn =
            define "f" [ pVar "x" ] (varExpr "x")

        call =
            callExpr (varExpr "f") [ intExpr 1 ]

        modul =
            makeModule "testValue"
                (letExpr [ fn ]
                    (binopsExpr [ ( call, "+" ) ] (intExpr 2))
                )
    in
    expectFn modul


{-| Applies `expectFn` to a program whose value is `r.x + r.y`, inside a
`let` that binds `r = { x = 1, y = 2 }`.
-}
binopWithRecordAccess : (Src.Module -> Expectation) -> (() -> Expectation)
binopWithRecordAccess expectFn _ =
    let
        record =
            recordExpr [ ( "x", intExpr 1 ), ( "y", intExpr 2 ) ]

        def =
            define "r" [] record

        sum =
            binopsExpr
                [ ( accessExpr (varExpr "r") "x", "+" ) ]
                (accessExpr (varExpr "r") "y")

        modul =
            makeModule "testValue" (letExpr [ def ] sum)
    in
    expectFn modul


{-| Applies `expectFn` to a program meaning `(if True then 1 else 0) + 2`.
The `if` is the chain's left operand directly, with no `Parens` node around
it, a shape the parser never produces.
-}
binopWithIfExpr : (Src.Module -> Expectation) -> (() -> Expectation)
binopWithIfExpr expectFn _ =
    let
        ifExpr_ =
            ifExpr (boolExpr True) (intExpr 1) (intExpr 0)

        modul =
            makeModule "testValue"
                (binopsExpr [ ( ifExpr_, "+" ) ] (intExpr 2))
    in
    expectFn modul


{-| Applies `expectFn` to a program whose value is `x + 2`, inside a `let`
that binds `x = 1`.
-}
binopInsideLetBody : (Src.Module -> Expectation) -> (() -> Expectation)
binopInsideLetBody expectFn _ =
    let
        def =
            define "x" [] (intExpr 1)

        sum =
            binopsExpr [ ( varExpr "x", "+" ) ] (intExpr 2)

        modul =
            makeModule "testValue" (letExpr [ def ] sum)
    in
    expectFn modul


{-| Applies `expectFn` to the program `(1 + 2) * 3`, whose left operand is
wrapped in a `Parens` node.
-}
binopWithParens : (Src.Module -> Expectation) -> (() -> Expectation)
binopWithParens expectFn _ =
    let
        inner =
            parensExpr (binopsExpr [ ( intExpr 1, "+" ) ] (intExpr 2))

        modul =
            makeModule "testValue"
                (binopsExpr [ ( inner, "*" ) ] (intExpr 3))
    in
    expectFn modul
