module Compiler.TupleTests exposing (expectSuite)

{-| Tests for tuple expressions: 2-tuples and 3-tuples.
-}

import Compiler.AST.Source as Src
import Compiler.AST.SourceBuilder
    exposing
        ( boolExpr
        , chrExpr
        , floatExpr
        , intExpr
        , listExpr
        , makeModule
        , recordExpr
        , strExpr
        , tuple3Expr
        , tupleExpr
        , unitExpr
        )
import Expect exposing (Expectation)
import Test exposing (Test)


expectSuite : (Src.Module -> Expectation) -> String -> Test
expectSuite expectFn condStr =
    Test.describe ("Tuple expressions " ++ condStr)
        [ tuple2Tests expectFn condStr
        , tuple3Tests expectFn condStr
        , nestedTupleTests expectFn condStr
        , mixedTypeTupleTests expectFn condStr
        ]



-- ============================================================================
-- 2-TUPLES (6 tests)
-- ============================================================================


tuple2Tests : (Src.Module -> Expectation) -> String -> Test
tuple2Tests expectFn condStr =
    Test.describe ("2-tuples " ++ condStr)
        [ Test.test ("Pair of ints " ++ condStr) (pairOfInts expectFn)
        , Test.test ("Pair of floats " ++ condStr) (pairOfFloats expectFn)
        , Test.test ("Pair of strings " ++ condStr) (pairOfStrings expectFn)
        , Test.test ("Pair with unit " ++ condStr) (pairWithUnits expectFn)
        , Test.test ("Pair of bools " ++ condStr) (pairOfBools expectFn)
        , Test.test ("Pair of chars " ++ condStr) (pairOfChars expectFn)
        ]


pairOfInts : (Src.Module -> Expectation) -> (() -> Expectation)
pairOfInts expectFn _ =
    let
        modul =
            makeModule "testValue" (tupleExpr (intExpr 1) (intExpr 2))
    in
    expectFn modul


pairOfFloats : (Src.Module -> Expectation) -> (() -> Expectation)
pairOfFloats expectFn _ =
    let
        modul =
            makeModule "testValue" (tupleExpr (floatExpr 1.5) (floatExpr 2.5))
    in
    expectFn modul


pairOfStrings : (Src.Module -> Expectation) -> (() -> Expectation)
pairOfStrings expectFn _ =
    let
        modul =
            makeModule "testValue" (tupleExpr (strExpr "hello") (strExpr "world"))
    in
    expectFn modul


pairWithUnits : (Src.Module -> Expectation) -> (() -> Expectation)
pairWithUnits expectFn _ =
    let
        modul =
            makeModule "testValue" (tupleExpr unitExpr unitExpr)
    in
    expectFn modul


pairOfBools : (Src.Module -> Expectation) -> (() -> Expectation)
pairOfBools expectFn _ =
    let
        modul =
            makeModule "testValue" (tupleExpr (boolExpr True) (boolExpr False))
    in
    expectFn modul


pairOfChars : (Src.Module -> Expectation) -> (() -> Expectation)
pairOfChars expectFn _ =
    let
        modul =
            makeModule "testValue" (tupleExpr (chrExpr "a") (chrExpr "b"))
    in
    expectFn modul



-- ============================================================================
-- 3-TUPLES (6 tests)
-- ============================================================================


tuple3Tests : (Src.Module -> Expectation) -> String -> Test
tuple3Tests expectFn condStr =
    Test.describe ("3-tuples " ++ condStr)
        [ Test.test ("Triple of ints " ++ condStr) (tripleOfInts expectFn)
        , Test.test ("Triple of mixed types " ++ condStr) (tripleOfMixedTypes expectFn)
        , Test.test ("Triple with bools " ++ condStr) (tripleWithBools expectFn)
        , Test.test ("Triple of strings " ++ condStr) (tripleOfStrings expectFn)
        , Test.test ("Triple of floats " ++ condStr) (tripleOfFloats expectFn)
        , Test.test ("Triple with units " ++ condStr) (tripleWithUnits expectFn)
        ]


tripleOfInts : (Src.Module -> Expectation) -> (() -> Expectation)
tripleOfInts expectFn _ =
    let
        modul =
            makeModule "testValue" (tuple3Expr (intExpr 1) (intExpr 2) (intExpr 3))
    in
    expectFn modul


tripleOfMixedTypes : (Src.Module -> Expectation) -> (() -> Expectation)
tripleOfMixedTypes expectFn _ =
    let
        modul =
            makeModule "testValue" (tuple3Expr (intExpr 42) (strExpr "hello") (floatExpr 3.14))
    in
    expectFn modul


tripleWithBools : (Src.Module -> Expectation) -> (() -> Expectation)
tripleWithBools expectFn _ =
    let
        modul =
            makeModule "testValue" (tuple3Expr (boolExpr True) (boolExpr False) (boolExpr True))
    in
    expectFn modul


tripleOfStrings : (Src.Module -> Expectation) -> (() -> Expectation)
tripleOfStrings expectFn _ =
    let
        modul =
            makeModule "testValue" (tuple3Expr (strExpr "a") (strExpr "b") (strExpr "c"))
    in
    expectFn modul


tripleOfFloats : (Src.Module -> Expectation) -> (() -> Expectation)
tripleOfFloats expectFn _ =
    let
        modul =
            makeModule "testValue" (tuple3Expr (floatExpr 1.1) (floatExpr 2.2) (floatExpr 3.3))
    in
    expectFn modul


tripleWithUnits : (Src.Module -> Expectation) -> (() -> Expectation)
tripleWithUnits expectFn _ =
    let
        modul =
            makeModule "testValue" (tuple3Expr unitExpr unitExpr unitExpr)
    in
    expectFn modul



-- ============================================================================
-- NESTED TUPLES (6 tests)
-- ============================================================================


nestedTupleTests : (Src.Module -> Expectation) -> String -> Test
nestedTupleTests expectFn condStr =
    Test.describe ("Nested tuples " ++ condStr)
        [ Test.test ("Tuple containing tuple " ++ condStr) (tupleContainingTuple expectFn)
        , Test.test ("Tuple containing nested tuples " ++ condStr) (tupleContainingNestedTuples expectFn)
        , Test.test ("Deeply nested tuple " ++ condStr) (deeplyNestedTuple expectFn)
        , Test.test ("3-tuple containing 2-tuples " ++ condStr) (tuple3Containing2Tuples expectFn)
        , Test.test ("2-tuple containing 3-tuples " ++ condStr) (tuple2Containing3Tuples expectFn)
        , Test.test ("Triple nested three levels deep " ++ condStr) (tripleNestedThreeLevels expectFn)
        ]


tupleContainingTuple : (Src.Module -> Expectation) -> (() -> Expectation)
tupleContainingTuple expectFn _ =
    let
        inner =
            tupleExpr (intExpr 1) (intExpr 2)

        modul =
            makeModule "testValue" (tupleExpr inner (intExpr 3))
    in
    expectFn modul


tupleContainingNestedTuples : (Src.Module -> Expectation) -> (() -> Expectation)
tupleContainingNestedTuples expectFn _ =
    let
        inner1 =
            tupleExpr (intExpr 1) (intExpr 2)

        inner2 =
            tupleExpr (strExpr "a") (strExpr "b")

        modul =
            makeModule "testValue" (tupleExpr inner1 inner2)
    in
    expectFn modul


deeplyNestedTuple : (Src.Module -> Expectation) -> (() -> Expectation)
deeplyNestedTuple expectFn _ =
    let
        level3 =
            tupleExpr (intExpr 1) (intExpr 2)

        level2 =
            tupleExpr level3 (intExpr 3)

        modul =
            makeModule "testValue" (tupleExpr (intExpr 0) level2)
    in
    expectFn modul


tuple3Containing2Tuples : (Src.Module -> Expectation) -> (() -> Expectation)
tuple3Containing2Tuples expectFn _ =
    let
        pair1 =
            tupleExpr (intExpr 1) (intExpr 2)

        pair2 =
            tupleExpr (intExpr 3) (intExpr 4)

        pair3 =
            tupleExpr (intExpr 5) (intExpr 6)

        modul =
            makeModule "testValue" (tuple3Expr pair1 pair2 pair3)
    in
    expectFn modul


tuple2Containing3Tuples : (Src.Module -> Expectation) -> (() -> Expectation)
tuple2Containing3Tuples expectFn _ =
    let
        triple1 =
            tuple3Expr (intExpr 1) (intExpr 2) (intExpr 3)

        triple2 =
            tuple3Expr (intExpr 4) (intExpr 5) (intExpr 6)

        modul =
            makeModule "testValue" (tupleExpr triple1 triple2)
    in
    expectFn modul


tripleNestedThreeLevels : (Src.Module -> Expectation) -> (() -> Expectation)
tripleNestedThreeLevels expectFn _ =
    let
        innermost =
            tuple3Expr (intExpr 1) (intExpr 2) (intExpr 3)

        middle =
            tuple3Expr innermost (intExpr 4) (intExpr 5)

        modul =
            makeModule "testValue" (tuple3Expr middle (intExpr 6) (intExpr 7))
    in
    expectFn modul



-- ============================================================================
-- MIXED TYPE TUPLES (6 tests)
-- ============================================================================


mixedTypeTupleTests : (Src.Module -> Expectation) -> String -> Test
mixedTypeTupleTests expectFn condStr =
    Test.describe ("Mixed type tuples " ++ condStr)
        [ Test.test ("Int and String pair " ++ condStr) (intAndStringPair expectFn)
        , Test.test ("Tuple with list " ++ condStr) (tupleWithList expectFn)
        , Test.test ("Tuple with record " ++ condStr) (tupleWithRecord expectFn)
        , Test.test ("Tuple with char " ++ condStr) (tupleWithChar expectFn)
        , Test.test ("Triple with list and record " ++ condStr) (tripleWithListAndRecord expectFn)
        , Test.test ("Triple of int, string, float " ++ condStr) (tripleOfIntStringFloat expectFn)
        ]


intAndStringPair : (Src.Module -> Expectation) -> (() -> Expectation)
intAndStringPair expectFn _ =
    let
        modul =
            makeModule "testValue" (tupleExpr (intExpr 42) (strExpr "hello"))
    in
    expectFn modul


tupleWithList : (Src.Module -> Expectation) -> (() -> Expectation)
tupleWithList expectFn _ =
    let
        list =
            listExpr [ intExpr 1, intExpr 2 ]

        modul =
            makeModule "testValue" (tupleExpr list (strExpr "hello"))
    in
    expectFn modul


tupleWithRecord : (Src.Module -> Expectation) -> (() -> Expectation)
tupleWithRecord expectFn _ =
    let
        record =
            recordExpr [ ( "x", intExpr 10 ) ]

        modul =
            makeModule "testValue" (tupleExpr record (intExpr 20))
    in
    expectFn modul


tupleWithChar : (Src.Module -> Expectation) -> (() -> Expectation)
tupleWithChar expectFn _ =
    let
        modul =
            makeModule "testValue" (tupleExpr (chrExpr "x") (intExpr 42))
    in
    expectFn modul


tripleWithListAndRecord : (Src.Module -> Expectation) -> (() -> Expectation)
tripleWithListAndRecord expectFn _ =
    let
        list =
            listExpr [ intExpr 1 ]

        record =
            recordExpr [ ( "y", strExpr "test" ) ]

        modul =
            makeModule "testValue" (tuple3Expr list record (intExpr 5))
    in
    expectFn modul


tripleOfIntStringFloat : (Src.Module -> Expectation) -> (() -> Expectation)
tripleOfIntStringFloat expectFn _ =
    let
        modul =
            makeModule "testValue" (tuple3Expr (intExpr 42) (strExpr "hello") (floatExpr 3.14))
    in
    expectFn modul
