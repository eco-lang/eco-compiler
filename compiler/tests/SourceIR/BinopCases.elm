module SourceIR.BinopCases exposing (expectSuite, testCases)

{-| Tests for binary operator expressions.
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
        , lambdaExpr
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


expectSuite : (Src.Module -> Expectation) -> String -> Test
expectSuite expectFn condStr =
    Test.test ("Binary operator expressions " ++ condStr) <|
        \_ -> bulkCheck (testCases expectFn)


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
-- ARITHMETIC BINOPS (8 tests)
-- ============================================================================


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


simpleAddition : (Src.Module -> Expectation) -> (() -> Expectation)
simpleAddition expectFn _ =
    let
        modul =
            makeModule "testValue" (binopsExpr [ ( intExpr 1, "+" ) ] (intExpr 2))
    in
    expectFn modul


simpleSubtraction : (Src.Module -> Expectation) -> (() -> Expectation)
simpleSubtraction expectFn _ =
    let
        modul =
            makeModule "testValue" (binopsExpr [ ( intExpr 5, "-" ) ] (intExpr 3))
    in
    expectFn modul


simpleMultiplication : (Src.Module -> Expectation) -> (() -> Expectation)
simpleMultiplication expectFn _ =
    let
        modul =
            makeModule "testValue" (binopsExpr [ ( intExpr 4, "*" ) ] (intExpr 5))
    in
    expectFn modul


simpleDivision : (Src.Module -> Expectation) -> (() -> Expectation)
simpleDivision expectFn _ =
    let
        modul =
            makeModule "testValue" (binopsExpr [ ( floatExpr 10.0, "/" ) ] (floatExpr 2.0))
    in
    expectFn modul


integerDivision : (Src.Module -> Expectation) -> (() -> Expectation)
integerDivision expectFn _ =
    let
        modul =
            makeModule "testValue" (binopsExpr [ ( intExpr 10, "//" ) ] (intExpr 3))
    in
    expectFn modul


moduloOp : (Src.Module -> Expectation) -> (() -> Expectation)
moduloOp expectFn _ =
    let
        modul =
            makeModule "testValue" (binopsExpr [ ( intExpr 10, "%" ) ] (intExpr 3))
    in
    expectFn modul


powerOp : (Src.Module -> Expectation) -> (() -> Expectation)
powerOp expectFn _ =
    let
        modul =
            makeModule "testValue" (binopsExpr [ ( floatExpr 2.0, "^" ) ] (floatExpr 3.0))
    in
    expectFn modul


additionWithConstants : (Src.Module -> Expectation) -> (() -> Expectation)
additionWithConstants expectFn _ =
    let
        modul =
            makeModule "testValue" (binopsExpr [ ( intExpr 42, "+" ) ] (intExpr 42))
    in
    expectFn modul



-- ============================================================================
-- COMPARISON BINOPS (8 tests)
-- ============================================================================


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


equalsOp : (Src.Module -> Expectation) -> (() -> Expectation)
equalsOp expectFn _ =
    let
        modul =
            makeModule "testValue" (binopsExpr [ ( intExpr 1, "==" ) ] (intExpr 1))
    in
    expectFn modul


notEqualsOp : (Src.Module -> Expectation) -> (() -> Expectation)
notEqualsOp expectFn _ =
    let
        modul =
            makeModule "testValue" (binopsExpr [ ( intExpr 1, "/=" ) ] (intExpr 2))
    in
    expectFn modul


lessThan : (Src.Module -> Expectation) -> (() -> Expectation)
lessThan expectFn _ =
    let
        modul =
            makeModule "testValue" (binopsExpr [ ( intExpr 1, "<" ) ] (intExpr 2))
    in
    expectFn modul


greaterThan : (Src.Module -> Expectation) -> (() -> Expectation)
greaterThan expectFn _ =
    let
        modul =
            makeModule "testValue" (binopsExpr [ ( intExpr 2, ">" ) ] (intExpr 1))
    in
    expectFn modul


lessThanOrEqual : (Src.Module -> Expectation) -> (() -> Expectation)
lessThanOrEqual expectFn _ =
    let
        modul =
            makeModule "testValue" (binopsExpr [ ( intExpr 1, "<=" ) ] (intExpr 1))
    in
    expectFn modul


greaterThanOrEqual : (Src.Module -> Expectation) -> (() -> Expectation)
greaterThanOrEqual expectFn _ =
    let
        modul =
            makeModule "testValue" (binopsExpr [ ( intExpr 2, ">=" ) ] (intExpr 1))
    in
    expectFn modul


comparisonWithConstants : (Src.Module -> Expectation) -> (() -> Expectation)
comparisonWithConstants expectFn _ =
    let
        modul =
            makeModule "testValue" (binopsExpr [ ( intExpr 1, "<" ) ] (intExpr 2))
    in
    expectFn modul


compareOnStrings : (Src.Module -> Expectation) -> (() -> Expectation)
compareOnStrings expectFn _ =
    let
        modul =
            makeModule "testValue" (binopsExpr [ ( strExpr "a", "<" ) ] (strExpr "b"))
    in
    expectFn modul



-- ============================================================================
-- LOGICAL BINOPS (6 tests)
-- ============================================================================


logicalBinopCases : (Src.Module -> Expectation) -> List TestCase
logicalBinopCases expectFn =
    [ { label = "And", run = andOp expectFn }
    , { label = "Or", run = orOp expectFn }
    , { label = "Chained and", run = chainedAnd expectFn }
    , { label = "Chained or", run = chainedOr expectFn }
    ]


andOp : (Src.Module -> Expectation) -> (() -> Expectation)
andOp expectFn _ =
    let
        modul =
            makeModule "testValue" (binopsExpr [ ( boolExpr True, "&&" ) ] (boolExpr False))
    in
    expectFn modul


orOp : (Src.Module -> Expectation) -> (() -> Expectation)
orOp expectFn _ =
    let
        modul =
            makeModule "testValue" (binopsExpr [ ( boolExpr True, "||" ) ] (boolExpr False))
    in
    expectFn modul


andWithConstants : (Src.Module -> Expectation) -> (() -> Expectation)
andWithConstants expectFn _ =
    let
        modul =
            makeModule "testValue" (binopsExpr [ ( boolExpr True, "&&" ) ] (boolExpr False))
    in
    expectFn modul


orWithConstants : (Src.Module -> Expectation) -> (() -> Expectation)
orWithConstants expectFn _ =
    let
        modul =
            makeModule "testValue" (binopsExpr [ ( boolExpr True, "||" ) ] (boolExpr False))
    in
    expectFn modul


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
-- STRING BINOPS (4 tests)
-- ============================================================================


stringBinopCases : (Src.Module -> Expectation) -> List TestCase
stringBinopCases expectFn =
    [ { label = "String concat", run = stringConcat expectFn }
    , { label = "Multiple string concat", run = multipleStringConcat expectFn }
    , { label = "String concat with empty", run = stringConcatWithEmpty expectFn }
    ]


stringConcat : (Src.Module -> Expectation) -> (() -> Expectation)
stringConcat expectFn _ =
    let
        modul =
            makeModule "testValue" (binopsExpr [ ( strExpr "hello", "++" ) ] (strExpr " world"))
    in
    expectFn modul


stringConcatWithConstants : (Src.Module -> Expectation) -> (() -> Expectation)
stringConcatWithConstants expectFn _ =
    let
        modul =
            makeModule "testValue" (binopsExpr [ ( strExpr "hello", "++" ) ] (strExpr "hello"))
    in
    expectFn modul


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


stringConcatWithEmpty : (Src.Module -> Expectation) -> (() -> Expectation)
stringConcatWithEmpty expectFn _ =
    let
        modul =
            makeModule "testValue" (binopsExpr [ ( strExpr "", "++" ) ] (strExpr "test"))
    in
    expectFn modul



-- ============================================================================
-- LIST BINOPS (4 tests)
-- ============================================================================


listBinopCases : (Src.Module -> Expectation) -> List TestCase
listBinopCases expectFn =
    [ { label = "List append", run = listAppend expectFn }
    , { label = "Cons operator", run = consOperator expectFn }
    , { label = "Cons with constant", run = consWithConstant expectFn }
    ]


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


listAppendWithConstants : (Src.Module -> Expectation) -> (() -> Expectation)
listAppendWithConstants expectFn _ =
    let
        modul =
            makeModule "testValue"
                (binopsExpr
                    [ ( listExpr [ intExpr 1, intExpr 2, intExpr 3 ], "++" ) ]
                    (listExpr [ intExpr 0 ])
                )
    in
    expectFn modul


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
-- CHAINED BINOPS (6 tests)
-- ============================================================================


chainedBinopCases : (Src.Module -> Expectation) -> List TestCase
chainedBinopCases expectFn =
    [ { label = "Three-element addition chain", run = threeElementAdditionChain expectFn }
    , { label = "Mixed arithmetic chain", run = mixedArithmeticChain expectFn }
    , { label = "Long chain", run = longChain expectFn }
    , { label = "Chain with different operators", run = chainWithDifferentOperators expectFn }
    ]


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


chainWithConstants : (Src.Module -> Expectation) -> (() -> Expectation)
chainWithConstants expectFn _ =
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


chainOfComparisons : (Src.Module -> Expectation) -> (() -> Expectation)
chainOfComparisons expectFn _ =
    let
        -- Note: In Elm, chained comparisons like a < b < c don't work as expected,
        -- but we're testing ID uniqueness of the AST
        modul =
            makeModule "testValue"
                (binopsExpr
                    [ ( intExpr 1, "<" )
                    ]
                    (intExpr 2)
                )
    in
    expectFn modul


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
-- NESTED BINOPS (6 tests)
-- ============================================================================


nestedBinopCases : (Src.Module -> Expectation) -> List TestCase
nestedBinopCases expectFn =
    [ { label = "Binop in tuple", run = binopInTuple expectFn }
    , { label = "Binop in list", run = binopInList expectFn }
    , { label = "Multiple binops in tuple", run = multipleBinopsInTuple expectFn }
    , { label = "Binop with variable operands", run = binopWithVariableOperands expectFn }
    , { label = "Binop with negate", run = binopWithNegate expectFn }
    , { label = "Complex nested binops", run = complexNestedBinops expectFn }
    ]


binopInTuple : (Src.Module -> Expectation) -> (() -> Expectation)
binopInTuple expectFn _ =
    let
        sum =
            binopsExpr [ ( intExpr 1, "+" ) ] (intExpr 2)

        modul =
            makeModule "testValue" (tupleExpr sum (intExpr 3))
    in
    expectFn modul


binopInList : (Src.Module -> Expectation) -> (() -> Expectation)
binopInList expectFn _ =
    let
        sum =
            binopsExpr [ ( intExpr 1, "+" ) ] (intExpr 2)

        modul =
            makeModule "testValue" (listExpr [ sum, intExpr 3 ])
    in
    expectFn modul


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


binopWithNegate : (Src.Module -> Expectation) -> (() -> Expectation)
binopWithNegate expectFn _ =
    let
        modul =
            makeModule "testValue"
                (binopsExpr [ ( negateExpr (intExpr 1), "+" ) ] (intExpr 2))
    in
    expectFn modul


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
-- BINOP WITH EXPRESSIONS (6 tests)
-- ============================================================================


binopWithExpressionsCases : (Src.Module -> Expectation) -> List TestCase
binopWithExpressionsCases expectFn =
    [ { label = "Binop with function call", run = binopWithFunctionCall expectFn }
    , { label = "Binop with record access", run = binopWithRecordAccess expectFn }
    , { label = "Binop with if expression", run = binopWithIfExpr expectFn }
    , { label = "Binop inside let body", run = binopInsideLetBody expectFn }
    , { label = "Binop with parens", run = binopWithParens expectFn }
    ]


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


binopWithLambda : (Src.Module -> Expectation) -> (() -> Expectation)
binopWithLambda expectFn _ =
    let
        -- Storing functions in a tuple, then "comparing" them
        -- (would fail at runtime but tests ID uniqueness)
        fn1 =
            lambdaExpr [ pVar "x" ] (varExpr "x")

        fn2 =
            lambdaExpr [ pVar "y" ] (varExpr "y")

        modul =
            makeModule "testValue" (tupleExpr fn1 fn2)
    in
    expectFn modul


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
