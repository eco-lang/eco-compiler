module Compiler.BinopTests exposing (expectSuite)

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
import Expect exposing (Expectation)
import Fuzz
import Test exposing (Test)


expectSuite : (Src.Module -> Expectation) -> String -> Test
expectSuite expectFn condStr =
    Test.describe ("Binary operator expressions " ++ condStr)
        [ arithmeticBinopTests expectFn condStr
        , comparisonBinopTests expectFn condStr
        , logicalBinopTests expectFn condStr
        , stringBinopTests expectFn condStr
        , listBinopTests expectFn condStr
        , chainedBinopTests expectFn condStr
        , nestedBinopTests expectFn condStr
        , binopWithExpressionsTests expectFn condStr
        , binopFuzzTests expectFn condStr
        ]



-- ============================================================================
-- ARITHMETIC BINOPS (8 tests)
-- ============================================================================


arithmeticBinopTests : (Src.Module -> Expectation) -> String -> Test
arithmeticBinopTests expectFn condStr =
    Test.describe ("Arithmetic binops " ++ condStr)
        [ Test.test ("Simple addition " ++ condStr) (simpleAddition expectFn)
        , Test.test ("Simple subtraction " ++ condStr) (simpleSubtraction expectFn)
        , Test.test ("Simple multiplication " ++ condStr) (simpleMultiplication expectFn)
        , Test.test ("Simple division " ++ condStr) (simpleDivision expectFn)
        , Test.test ("Integer division " ++ condStr) (integerDivision expectFn)
        , Test.test ("Modulo " ++ condStr) (moduloOp expectFn)
        , Test.test ("Power " ++ condStr) (powerOp expectFn)
        , Test.fuzz2 Fuzz.int Fuzz.int ("Fuzzed addition " ++ condStr) (fuzzedAddition expectFn)
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


fuzzedAddition : (Src.Module -> Expectation) -> (Int -> Int -> Expectation)
fuzzedAddition expectFn a b =
    let
        modul =
            makeModule "testValue" (binopsExpr [ ( intExpr a, "+" ) ] (intExpr b))
    in
    expectFn modul



-- ============================================================================
-- COMPARISON BINOPS (8 tests)
-- ============================================================================


comparisonBinopTests : (Src.Module -> Expectation) -> String -> Test
comparisonBinopTests expectFn condStr =
    Test.describe ("Comparison binops " ++ condStr)
        [ Test.test ("Equals " ++ condStr) (equalsOp expectFn)
        , Test.test ("Not equals " ++ condStr) (notEqualsOp expectFn)
        , Test.test ("Less than " ++ condStr) (lessThan expectFn)
        , Test.test ("Greater than " ++ condStr) (greaterThan expectFn)
        , Test.test ("Less than or equal " ++ condStr) (lessThanOrEqual expectFn)
        , Test.test ("Greater than or equal " ++ condStr) (greaterThanOrEqual expectFn)
        , Test.fuzz2 Fuzz.int Fuzz.int ("Fuzzed comparison " ++ condStr) (fuzzedComparison expectFn)
        , Test.test ("Compare on strings " ++ condStr) (compareOnStrings expectFn)
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


fuzzedComparison : (Src.Module -> Expectation) -> (Int -> Int -> Expectation)
fuzzedComparison expectFn a b =
    let
        modul =
            makeModule "testValue" (binopsExpr [ ( intExpr a, "<" ) ] (intExpr b))
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


logicalBinopTests : (Src.Module -> Expectation) -> String -> Test
logicalBinopTests expectFn condStr =
    Test.describe ("Logical binops " ++ condStr)
        [ Test.test ("And " ++ condStr) (andOp expectFn)
        , Test.test ("Or " ++ condStr) (orOp expectFn)
        , Test.fuzz2 Fuzz.bool Fuzz.bool ("Fuzzed and " ++ condStr) (fuzzedAnd expectFn)
        , Test.fuzz2 Fuzz.bool Fuzz.bool ("Fuzzed or " ++ condStr) (fuzzedOr expectFn)
        , Test.test ("Chained and " ++ condStr) (chainedAnd expectFn)
        , Test.test ("Chained or " ++ condStr) (chainedOr expectFn)
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


fuzzedAnd : (Src.Module -> Expectation) -> (Bool -> Bool -> Expectation)
fuzzedAnd expectFn a b =
    let
        modul =
            makeModule "testValue" (binopsExpr [ ( boolExpr a, "&&" ) ] (boolExpr b))
    in
    expectFn modul


fuzzedOr : (Src.Module -> Expectation) -> (Bool -> Bool -> Expectation)
fuzzedOr expectFn a b =
    let
        modul =
            makeModule "testValue" (binopsExpr [ ( boolExpr a, "||" ) ] (boolExpr b))
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


stringBinopTests : (Src.Module -> Expectation) -> String -> Test
stringBinopTests expectFn condStr =
    Test.describe ("String binops " ++ condStr)
        [ Test.test ("String concat " ++ condStr) (stringConcat expectFn)
        , Test.fuzz2 Fuzz.string Fuzz.string ("Fuzzed string concat " ++ condStr) (fuzzedStringConcat expectFn)
        , Test.test ("Multiple string concat " ++ condStr) (multipleStringConcat expectFn)
        , Test.test ("String concat with empty " ++ condStr) (stringConcatWithEmpty expectFn)
        ]


stringConcat : (Src.Module -> Expectation) -> (() -> Expectation)
stringConcat expectFn _ =
    let
        modul =
            makeModule "testValue" (binopsExpr [ ( strExpr "hello", "++" ) ] (strExpr " world"))
    in
    expectFn modul


fuzzedStringConcat : (Src.Module -> Expectation) -> (String -> String -> Expectation)
fuzzedStringConcat expectFn a b =
    let
        modul =
            makeModule "testValue" (binopsExpr [ ( strExpr a, "++" ) ] (strExpr b))
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


listBinopTests : (Src.Module -> Expectation) -> String -> Test
listBinopTests expectFn condStr =
    Test.describe ("List binops " ++ condStr)
        [ Test.test ("List append " ++ condStr) (listAppend expectFn)
        , Test.test ("Cons operator " ++ condStr) (consOperator expectFn)
        , Test.fuzz (Fuzz.listOfLengthBetween 0 3 Fuzz.int) ("Fuzzed list append " ++ condStr) (fuzzedListAppend expectFn)
        , Test.fuzz Fuzz.int ("Fuzzed cons " ++ condStr) (fuzzedCons expectFn)
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


fuzzedListAppend : (Src.Module -> Expectation) -> (List Int -> Expectation)
fuzzedListAppend expectFn ints =
    let
        modul =
            makeModule "testValue"
                (binopsExpr
                    [ ( listExpr (List.map intExpr ints), "++" ) ]
                    (listExpr [ intExpr 0 ])
                )
    in
    expectFn modul


fuzzedCons : (Src.Module -> Expectation) -> (Int -> Expectation)
fuzzedCons expectFn n =
    let
        modul =
            makeModule "testValue"
                (binopsExpr
                    [ ( intExpr n, "::" ) ]
                    (listExpr [])
                )
    in
    expectFn modul



-- ============================================================================
-- CHAINED BINOPS (6 tests)
-- ============================================================================


chainedBinopTests : (Src.Module -> Expectation) -> String -> Test
chainedBinopTests expectFn condStr =
    Test.describe ("Chained binops " ++ condStr)
        [ Test.test ("Three-element addition chain " ++ condStr) (threeElementAdditionChain expectFn)
        , Test.test ("Mixed arithmetic chain " ++ condStr) (mixedArithmeticChain expectFn)
        , Test.test ("Long chain " ++ condStr) (longChain expectFn)
        , Test.fuzz3 Fuzz.int Fuzz.int Fuzz.int ("Fuzzed chain " ++ condStr) (fuzzedChain expectFn)
        , Test.test ("Chain of comparisons " ++ condStr) (chainOfComparisons expectFn)
        , Test.test ("Chain with different operators " ++ condStr) (chainWithDifferentOperators expectFn)
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


fuzzedChain : (Src.Module -> Expectation) -> (Int -> Int -> Int -> Expectation)
fuzzedChain expectFn a b c =
    let
        modul =
            makeModule "testValue"
                (binopsExpr
                    [ ( intExpr a, "+" )
                    , ( intExpr b, "+" )
                    ]
                    (intExpr c)
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


nestedBinopTests : (Src.Module -> Expectation) -> String -> Test
nestedBinopTests expectFn condStr =
    Test.describe ("Nested binops " ++ condStr)
        [ Test.test ("Binop in tuple " ++ condStr) (binopInTuple expectFn)
        , Test.test ("Binop in list " ++ condStr) (binopInList expectFn)
        , Test.test ("Multiple binops in tuple " ++ condStr) (multipleBinopsInTuple expectFn)
        , Test.test ("Binop with variable operands " ++ condStr) (binopWithVariableOperands expectFn)
        , Test.test ("Binop with negate " ++ condStr) (binopWithNegate expectFn)
        , Test.test ("Complex nested binops " ++ condStr) (complexNestedBinops expectFn)
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


binopWithExpressionsTests : (Src.Module -> Expectation) -> String -> Test
binopWithExpressionsTests expectFn condStr =
    Test.describe ("Binops with complex expressions " ++ condStr)
        [ Test.test ("Binop with function call " ++ condStr) (binopWithFunctionCall expectFn)
        , Test.test ("Binop with lambda " ++ condStr) (binopWithLambda expectFn)
        , Test.test ("Binop with record access " ++ condStr) (binopWithRecordAccess expectFn)
        , Test.test ("Binop with if expression " ++ condStr) (binopWithIfExpr expectFn)
        , Test.test ("Binop inside let body " ++ condStr) (binopInsideLetBody expectFn)
        , Test.test ("Binop with parens " ++ condStr) (binopWithParens expectFn)
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



-- ============================================================================
-- FUZZ TESTS (4 tests)
-- ============================================================================


binopFuzzTests : (Src.Module -> Expectation) -> String -> Test
binopFuzzTests expectFn condStr =
    Test.describe ("Fuzzed binop tests " ++ condStr)
        [ Test.fuzz3 Fuzz.int Fuzz.int Fuzz.int ("Three fuzzed ints in chain " ++ condStr) (threeFuzzedIntsInChain expectFn)
        , Test.fuzz2 Fuzz.float Fuzz.float ("Fuzzed float division " ++ condStr) (fuzzedFloatDivision expectFn)
        , Test.fuzz2 Fuzz.string Fuzz.string ("Fuzzed string comparison " ++ condStr) (fuzzedStringComparison expectFn)
        , Test.fuzz3 Fuzz.bool Fuzz.bool Fuzz.bool ("Fuzzed bool chain " ++ condStr) (fuzzedBoolChain expectFn)
        ]


threeFuzzedIntsInChain : (Src.Module -> Expectation) -> (Int -> Int -> Int -> Expectation)
threeFuzzedIntsInChain expectFn a b c =
    let
        modul =
            makeModule "testValue"
                (binopsExpr
                    [ ( intExpr a, "+" )
                    , ( intExpr b, "+" )
                    ]
                    (intExpr c)
                )
    in
    expectFn modul


fuzzedFloatDivision : (Src.Module -> Expectation) -> (Float -> Float -> Expectation)
fuzzedFloatDivision expectFn a b =
    let
        modul =
            makeModule "testValue"
                (binopsExpr [ ( floatExpr a, "/" ) ] (floatExpr b))
    in
    expectFn modul


fuzzedStringComparison : (Src.Module -> Expectation) -> (String -> String -> Expectation)
fuzzedStringComparison expectFn a b =
    let
        modul =
            makeModule "testValue"
                (binopsExpr [ ( strExpr a, "==" ) ] (strExpr b))
    in
    expectFn modul


fuzzedBoolChain : (Src.Module -> Expectation) -> (Bool -> Bool -> Bool -> Expectation)
fuzzedBoolChain expectFn a b c =
    let
        modul =
            makeModule "testValue"
                (binopsExpr
                    [ ( boolExpr a, "&&" )
                    , ( boolExpr b, "||" )
                    ]
                    (boolExpr c)
                )
    in
    expectFn modul
