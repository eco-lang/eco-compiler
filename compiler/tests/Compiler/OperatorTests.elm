module Compiler.OperatorTests exposing (expectSuite)

{-| Tests for operator expressions and if expressions.
-}

import Compiler.AST.Source as Src
import Compiler.AST.SourceBuilder
    exposing
        ( boolExpr
        , define
        , floatExpr
        , ifExpr
        , intExpr
        , letExpr
        , listExpr
        , makeModule
        , negateExpr
        , tupleExpr
        , varExpr
        )
import Expect exposing (Expectation)
import Fuzz
import Test exposing (Test)


expectSuite : (Src.Module -> Expectation) -> String -> Test
expectSuite expectFn condStr =
    Test.describe ("Operator and if expressions " ++ condStr)
        [ ifTests expectFn condStr
        , negateTests expectFn condStr
        , combinedTests expectFn condStr
        ]



-- ============================================================================
-- IF EXPRESSIONS (10 tests)
-- ============================================================================


ifTests : (Src.Module -> Expectation) -> String -> Test
ifTests expectFn condStr =
    Test.describe ("If expressions " ++ condStr)
        [ Test.test ("Simple if " ++ condStr) (simpleIf expectFn)
        , Test.fuzz Fuzz.bool ("If with fuzzed condition " ++ condStr) (ifWithFuzzedCondition expectFn)
        , Test.fuzz2 Fuzz.int Fuzz.int ("If with fuzzed branches " ++ condStr) (ifWithFuzzedBranches expectFn)
        , Test.test ("If returning tuples " ++ condStr) (ifReturningTuples expectFn)
        , Test.test ("If returning lists " ++ condStr) (ifReturningLists expectFn)
        , Test.test ("Nested if " ++ condStr) (nestedIf expectFn)
        , Test.test ("If in else branch " ++ condStr) (ifInElseBranch expectFn)
        , Test.test ("Deeply nested if " ++ condStr) (deeplyNestedIf expectFn)
        , Test.test ("If with variable condition " ++ condStr) (ifWithVariableCondition expectFn)
        , Test.fuzz3 Fuzz.bool Fuzz.int Fuzz.int ("If with all fuzzed values " ++ condStr) (ifWithAllFuzzedValues expectFn)
        ]


simpleIf : (Src.Module -> Expectation) -> (() -> Expectation)
simpleIf expectFn _ =
    let
        modul =
            makeModule "testValue" (ifExpr (boolExpr True) (intExpr 1) (intExpr 0))
    in
    expectFn modul


ifWithFuzzedCondition : (Src.Module -> Expectation) -> (Bool -> Expectation)
ifWithFuzzedCondition expectFn b =
    let
        modul =
            makeModule "testValue" (ifExpr (boolExpr b) (intExpr 1) (intExpr 0))
    in
    expectFn modul


ifWithFuzzedBranches : (Src.Module -> Expectation) -> (Int -> Int -> Expectation)
ifWithFuzzedBranches expectFn a b =
    let
        modul =
            makeModule "testValue" (ifExpr (boolExpr True) (intExpr a) (intExpr b))
    in
    expectFn modul


ifReturningTuples : (Src.Module -> Expectation) -> (() -> Expectation)
ifReturningTuples expectFn _ =
    let
        thenBranch =
            tupleExpr (intExpr 1) (intExpr 2)

        elseBranch =
            tupleExpr (intExpr 3) (intExpr 4)

        modul =
            makeModule "testValue" (ifExpr (boolExpr True) thenBranch elseBranch)
    in
    expectFn modul


ifReturningLists : (Src.Module -> Expectation) -> (() -> Expectation)
ifReturningLists expectFn _ =
    let
        thenBranch =
            listExpr [ intExpr 1, intExpr 2 ]

        elseBranch =
            listExpr []

        modul =
            makeModule "testValue" (ifExpr (boolExpr False) thenBranch elseBranch)
    in
    expectFn modul


nestedIf : (Src.Module -> Expectation) -> (() -> Expectation)
nestedIf expectFn _ =
    let
        innerIf =
            ifExpr (boolExpr True) (intExpr 1) (intExpr 2)

        modul =
            makeModule "testValue" (ifExpr (boolExpr True) innerIf (intExpr 0))
    in
    expectFn modul


ifInElseBranch : (Src.Module -> Expectation) -> (() -> Expectation)
ifInElseBranch expectFn _ =
    let
        elseIf =
            ifExpr (boolExpr True) (intExpr 2) (intExpr 3)

        modul =
            makeModule "testValue" (ifExpr (boolExpr False) (intExpr 1) elseIf)
    in
    expectFn modul


deeplyNestedIf : (Src.Module -> Expectation) -> (() -> Expectation)
deeplyNestedIf expectFn _ =
    let
        level3 =
            ifExpr (boolExpr True) (intExpr 3) (intExpr 4)

        level2 =
            ifExpr (boolExpr True) (intExpr 2) level3

        modul =
            makeModule "testValue" (ifExpr (boolExpr True) (intExpr 1) level2)
    in
    expectFn modul


ifWithVariableCondition : (Src.Module -> Expectation) -> (() -> Expectation)
ifWithVariableCondition expectFn _ =
    let
        def =
            define "cond" [] (boolExpr True)

        modul =
            makeModule "testValue"
                (letExpr [ def ] (ifExpr (varExpr "cond") (intExpr 1) (intExpr 0)))
    in
    expectFn modul


ifWithAllFuzzedValues : (Src.Module -> Expectation) -> (Bool -> Int -> Int -> Expectation)
ifWithAllFuzzedValues expectFn cond thenVal elseVal =
    let
        modul =
            makeModule "testValue" (ifExpr (boolExpr cond) (intExpr thenVal) (intExpr elseVal))
    in
    expectFn modul



-- ============================================================================
-- NEGATE EXPRESSIONS (6 tests)
-- ============================================================================


negateTests : (Src.Module -> Expectation) -> String -> Test
negateTests expectFn condStr =
    Test.describe ("Negate expressions " ++ condStr)
        [ Test.test ("Negate int " ++ condStr) (negateInt expectFn)
        , Test.fuzz Fuzz.int ("Negate fuzzed int " ++ condStr) (negateFuzzedInt expectFn)
        , Test.test ("Negate float " ++ condStr) (negateFloat expectFn)
        , Test.fuzz Fuzz.float ("Negate fuzzed float " ++ condStr) (negateFuzzedFloat expectFn)
        , Test.test ("Double negate " ++ condStr) (doubleNegate expectFn)
        , Test.test ("Negate variable " ++ condStr) (negateVariable expectFn)
        ]


negateInt : (Src.Module -> Expectation) -> (() -> Expectation)
negateInt expectFn _ =
    let
        modul =
            makeModule "testValue" (negateExpr (intExpr 42))
    in
    expectFn modul


negateFuzzedInt : (Src.Module -> Expectation) -> (Int -> Expectation)
negateFuzzedInt expectFn n =
    let
        modul =
            makeModule "testValue" (negateExpr (intExpr n))
    in
    expectFn modul


negateFloat : (Src.Module -> Expectation) -> (() -> Expectation)
negateFloat expectFn _ =
    let
        modul =
            makeModule "testValue" (negateExpr (floatExpr 3.14))
    in
    expectFn modul


negateFuzzedFloat : (Src.Module -> Expectation) -> (Float -> Expectation)
negateFuzzedFloat expectFn f =
    let
        modul =
            makeModule "testValue" (negateExpr (floatExpr f))
    in
    expectFn modul


doubleNegate : (Src.Module -> Expectation) -> (() -> Expectation)
doubleNegate expectFn _ =
    let
        modul =
            makeModule "testValue" (negateExpr (negateExpr (intExpr 42)))
    in
    expectFn modul


negateVariable : (Src.Module -> Expectation) -> (() -> Expectation)
negateVariable expectFn _ =
    let
        def =
            define "x" [] (intExpr 42)

        modul =
            makeModule "testValue" (letExpr [ def ] (negateExpr (varExpr "x")))
    in
    expectFn modul



-- ============================================================================
-- COMBINED TESTS (4 tests)
-- ============================================================================


combinedTests : (Src.Module -> Expectation) -> String -> Test
combinedTests expectFn condStr =
    Test.describe ("Combined operator tests " ++ condStr)
        [ Test.test ("If with negate condition " ++ condStr) (ifWithNegateCondition expectFn)
        , Test.test ("Negate inside if branches " ++ condStr) (negateInsideIfBranches expectFn)
        , Test.test ("If inside tuple with negate " ++ condStr) (ifInsideTupleWithNegate expectFn)
        , Test.test ("Multiple ifs and negates in list " ++ condStr) (multipleIfsAndNegatesInList expectFn)
        ]


ifWithNegateCondition : (Src.Module -> Expectation) -> (() -> Expectation)
ifWithNegateCondition expectFn _ =
    let
        -- Note: This would be a type error in real Elm, but we're testing ID uniqueness
        modul =
            makeModule "testValue"
                (ifExpr (boolExpr True)
                    (negateExpr (intExpr 1))
                    (negateExpr (intExpr 2))
                )
    in
    expectFn modul


negateInsideIfBranches : (Src.Module -> Expectation) -> (() -> Expectation)
negateInsideIfBranches expectFn _ =
    let
        modul =
            makeModule "testValue"
                (ifExpr (boolExpr True)
                    (negateExpr (intExpr 1))
                    (intExpr 1)
                )
    in
    expectFn modul


ifInsideTupleWithNegate : (Src.Module -> Expectation) -> (() -> Expectation)
ifInsideTupleWithNegate expectFn _ =
    let
        if_ =
            ifExpr (boolExpr True) (intExpr 1) (intExpr 0)

        neg =
            negateExpr (intExpr 5)

        modul =
            makeModule "testValue" (tupleExpr if_ neg)
    in
    expectFn modul


multipleIfsAndNegatesInList : (Src.Module -> Expectation) -> (() -> Expectation)
multipleIfsAndNegatesInList expectFn _ =
    let
        if1 =
            ifExpr (boolExpr True) (intExpr 1) (intExpr 0)

        if2 =
            ifExpr (boolExpr False) (intExpr 2) (intExpr 3)

        neg1 =
            negateExpr (intExpr 4)

        neg2 =
            negateExpr (intExpr 5)

        modul =
            makeModule "testValue" (listExpr [ if1, if2, neg1, neg2 ])
    in
    expectFn modul
