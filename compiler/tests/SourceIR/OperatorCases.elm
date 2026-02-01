module SourceIR.OperatorCases exposing (expectSuite, testCases)

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
import Compiler.BulkCheck exposing (TestCase, bulkCheck)
import Expect exposing (Expectation)
import Test exposing (Test)


expectSuite : (Src.Module -> Expectation) -> String -> Test
expectSuite expectFn condStr =
    Test.test ("Operator and if expressions " ++ condStr) <|
        \_ -> bulkCheck (testCases expectFn)


testCases : (Src.Module -> Expectation) -> List TestCase
testCases expectFn =
    List.concat
        [ ifCases expectFn
        , negateCases expectFn
        , combinedCases expectFn
        ]



-- ============================================================================
-- IF EXPRESSIONS (10 tests)
-- ============================================================================


ifCases : (Src.Module -> Expectation) -> List TestCase
ifCases expectFn =
    [ { label = "Simple if", run = simpleIf expectFn }
    , { label = "If with int branches", run = ifWithIntBranches expectFn }
    , { label = "If returning tuples", run = ifReturningTuples expectFn }
    , { label = "If returning lists", run = ifReturningLists expectFn }
    , { label = "Nested if", run = nestedIf expectFn }
    , { label = "If in else branch", run = ifInElseBranch expectFn }
    , { label = "Deeply nested if", run = deeplyNestedIf expectFn }
    , { label = "If with variable condition", run = ifWithVariableCondition expectFn }
    ]


simpleIf : (Src.Module -> Expectation) -> (() -> Expectation)
simpleIf expectFn _ =
    let
        modul =
            makeModule "testValue" (ifExpr (boolExpr True) (intExpr 1) (intExpr 0))
    in
    expectFn modul


ifWithBoolCondition : (Src.Module -> Expectation) -> (() -> Expectation)
ifWithBoolCondition expectFn _ =
    let
        modul =
            makeModule "testValue" (ifExpr (boolExpr True) (intExpr 1) (intExpr 0))
    in
    expectFn modul


ifWithIntBranches : (Src.Module -> Expectation) -> (() -> Expectation)
ifWithIntBranches expectFn _ =
    let
        modul =
            makeModule "testValue" (ifExpr (boolExpr True) (intExpr 1) (intExpr 2))
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


ifWithFixedValues : (Src.Module -> Expectation) -> (() -> Expectation)
ifWithFixedValues expectFn _ =
    let
        modul =
            makeModule "testValue" (ifExpr (boolExpr True) (intExpr 1) (intExpr 2))
    in
    expectFn modul



-- ============================================================================
-- NEGATE EXPRESSIONS (6 tests)
-- ============================================================================


negateCases : (Src.Module -> Expectation) -> List TestCase
negateCases expectFn =
    [ { label = "Negate int", run = negateInt expectFn }
    , { label = "Negate float", run = negateFloat expectFn }
    , { label = "Double negate", run = doubleNegate expectFn }
    , { label = "Negate variable", run = negateVariable expectFn }
    ]


negateInt : (Src.Module -> Expectation) -> (() -> Expectation)
negateInt expectFn _ =
    let
        modul =
            makeModule "testValue" (negateExpr (intExpr 42))
    in
    expectFn modul


negateIntValue : (Src.Module -> Expectation) -> (() -> Expectation)
negateIntValue expectFn _ =
    let
        modul =
            makeModule "testValue" (negateExpr (intExpr 42))
    in
    expectFn modul


negateFloat : (Src.Module -> Expectation) -> (() -> Expectation)
negateFloat expectFn _ =
    let
        modul =
            makeModule "testValue" (negateExpr (floatExpr 3.14))
    in
    expectFn modul


negateFloatValue : (Src.Module -> Expectation) -> (() -> Expectation)
negateFloatValue expectFn _ =
    let
        modul =
            makeModule "testValue" (negateExpr (floatExpr 3.14))
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


combinedCases : (Src.Module -> Expectation) -> List TestCase
combinedCases expectFn =
    [ { label = "If with negate condition", run = ifWithNegateCondition expectFn }
    , { label = "Negate inside if branches", run = negateInsideIfBranches expectFn }
    , { label = "If inside tuple with negate", run = ifInsideTupleWithNegate expectFn }
    , { label = "Multiple ifs and negates in list", run = multipleIfsAndNegatesInList expectFn }
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
