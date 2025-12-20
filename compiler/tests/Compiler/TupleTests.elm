module Compiler.TupleTests exposing (expectSuite)

{-| Tests for tuple expressions: 2-tuples and 3-tuples.
-}

import Compiler.AST.Source as Src
import Compiler.AST.SourceBuilder
    exposing
        ( boolExpr
        , charFuzzer
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
import Fuzz
import Test exposing (Test)


expectSuite : (Src.Module -> Expectation) -> String -> Test
expectSuite expectFn condStr =
    Test.describe ("Tuple expressions " ++ condStr)
        [ tuple2Tests expectFn condStr
        , tuple3Tests expectFn condStr
        , nestedTupleTests expectFn condStr
        , mixedTypeTupleTests expectFn condStr
        , tupleFuzzTests expectFn condStr
        ]



-- ============================================================================
-- 2-TUPLES (6 tests)
-- ============================================================================


tuple2Tests : (Src.Module -> Expectation) -> String -> Test
tuple2Tests expectFn condStr =
    Test.describe ("2-tuples " ++ condStr)
        [ Test.fuzz2 Fuzz.int Fuzz.int ("Pair of ints " ++ condStr) (pairOfInts expectFn)
        , Test.fuzz2 Fuzz.float Fuzz.float ("Pair of floats " ++ condStr) (pairOfFloats expectFn)
        , Test.fuzz2 Fuzz.string Fuzz.string ("Pair of strings " ++ condStr) (pairOfStrings expectFn)
        , Test.test ("Pair with unit " ++ condStr) (pairWithUnits expectFn)
        , Test.fuzz2 Fuzz.bool Fuzz.bool ("Pair of bools " ++ condStr) (pairOfBools expectFn)
        , Test.fuzz2 charFuzzer charFuzzer ("Pair of chars " ++ condStr) (pairOfChars expectFn)
        ]


pairOfInts : (Src.Module -> Expectation) -> (Int -> Int -> Expectation)
pairOfInts expectFn a b =
    let
        modul =
            makeModule "testValue" (tupleExpr (intExpr a) (intExpr b))
    in
    expectFn modul


pairOfFloats : (Src.Module -> Expectation) -> (Float -> Float -> Expectation)
pairOfFloats expectFn a b =
    let
        modul =
            makeModule "testValue" (tupleExpr (floatExpr a) (floatExpr b))
    in
    expectFn modul


pairOfStrings : (Src.Module -> Expectation) -> (String -> String -> Expectation)
pairOfStrings expectFn a b =
    let
        modul =
            makeModule "testValue" (tupleExpr (strExpr a) (strExpr b))
    in
    expectFn modul


pairWithUnits : (Src.Module -> Expectation) -> (() -> Expectation)
pairWithUnits expectFn _ =
    let
        modul =
            makeModule "testValue" (tupleExpr unitExpr unitExpr)
    in
    expectFn modul


pairOfBools : (Src.Module -> Expectation) -> (Bool -> Bool -> Expectation)
pairOfBools expectFn a b =
    let
        modul =
            makeModule "testValue" (tupleExpr (boolExpr a) (boolExpr b))
    in
    expectFn modul


pairOfChars : (Src.Module -> Expectation) -> (String -> String -> Expectation)
pairOfChars expectFn a b =
    let
        modul =
            makeModule "testValue" (tupleExpr (chrExpr a) (chrExpr b))
    in
    expectFn modul



-- ============================================================================
-- 3-TUPLES (6 tests)
-- ============================================================================


tuple3Tests : (Src.Module -> Expectation) -> String -> Test
tuple3Tests expectFn condStr =
    Test.describe ("3-tuples " ++ condStr)
        [ Test.fuzz3 Fuzz.int Fuzz.int Fuzz.int ("Triple of ints " ++ condStr) (tripleOfInts expectFn)
        , Test.fuzz3 Fuzz.int Fuzz.string Fuzz.float ("Triple of mixed types " ++ condStr) (tripleOfMixedTypes expectFn)
        , Test.test ("Triple with bools " ++ condStr) (tripleWithBools expectFn)
        , Test.fuzz3 Fuzz.string Fuzz.string Fuzz.string ("Triple of strings " ++ condStr) (tripleOfStrings expectFn)
        , Test.fuzz3 Fuzz.float Fuzz.float Fuzz.float ("Triple of floats " ++ condStr) (tripleOfFloats expectFn)
        , Test.test ("Triple with units " ++ condStr) (tripleWithUnits expectFn)
        ]


tripleOfInts : (Src.Module -> Expectation) -> (Int -> Int -> Int -> Expectation)
tripleOfInts expectFn a b c =
    let
        modul =
            makeModule "testValue" (tuple3Expr (intExpr a) (intExpr b) (intExpr c))
    in
    expectFn modul


tripleOfMixedTypes : (Src.Module -> Expectation) -> (Int -> String -> Float -> Expectation)
tripleOfMixedTypes expectFn a b c =
    let
        modul =
            makeModule "testValue" (tuple3Expr (intExpr a) (strExpr b) (floatExpr c))
    in
    expectFn modul


tripleWithBools : (Src.Module -> Expectation) -> (() -> Expectation)
tripleWithBools expectFn _ =
    let
        modul =
            makeModule "testValue" (tuple3Expr (boolExpr True) (boolExpr False) (boolExpr True))
    in
    expectFn modul


tripleOfStrings : (Src.Module -> Expectation) -> (String -> String -> String -> Expectation)
tripleOfStrings expectFn a b c =
    let
        modul =
            makeModule "testValue" (tuple3Expr (strExpr a) (strExpr b) (strExpr c))
    in
    expectFn modul


tripleOfFloats : (Src.Module -> Expectation) -> (Float -> Float -> Float -> Expectation)
tripleOfFloats expectFn a b c =
    let
        modul =
            makeModule "testValue" (tuple3Expr (floatExpr a) (floatExpr b) (floatExpr c))
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
        [ Test.fuzz2 Fuzz.int Fuzz.string ("Int and String pair " ++ condStr) (intAndStringPair expectFn)
        , Test.test ("Tuple with list " ++ condStr) (tupleWithList expectFn)
        , Test.test ("Tuple with record " ++ condStr) (tupleWithRecord expectFn)
        , Test.fuzz charFuzzer ("Tuple with char " ++ condStr) (tupleWithChar expectFn)
        , Test.test ("Triple with list and record " ++ condStr) (tripleWithListAndRecord expectFn)
        , Test.fuzz3 Fuzz.int Fuzz.string Fuzz.float ("Triple of int, string, float " ++ condStr) (tripleOfIntStringFloat expectFn)
        ]


intAndStringPair : (Src.Module -> Expectation) -> (Int -> String -> Expectation)
intAndStringPair expectFn n s =
    let
        modul =
            makeModule "testValue" (tupleExpr (intExpr n) (strExpr s))
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


tupleWithChar : (Src.Module -> Expectation) -> (String -> Expectation)
tupleWithChar expectFn c =
    let
        modul =
            makeModule "testValue" (tupleExpr (chrExpr c) (intExpr 42))
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


tripleOfIntStringFloat : (Src.Module -> Expectation) -> (Int -> String -> Float -> Expectation)
tripleOfIntStringFloat expectFn n s f =
    let
        modul =
            makeModule "testValue" (tuple3Expr (intExpr n) (strExpr s) (floatExpr f))
    in
    expectFn modul



-- ============================================================================
-- FUZZ TESTS (7 tests)
-- ============================================================================


tupleFuzzTests : (Src.Module -> Expectation) -> String -> Test
tupleFuzzTests expectFn condStr =
    Test.describe ("Fuzzed tuple tests " ++ condStr)
        [ Test.fuzz2 Fuzz.int Fuzz.int ("Random int pair " ++ condStr) (randomIntPair expectFn)
        , Test.fuzz3 Fuzz.int Fuzz.int Fuzz.int ("Random int triple " ++ condStr) (randomIntTriple expectFn)
        , Test.fuzz2 Fuzz.string Fuzz.int ("Random string-int pair " ++ condStr) (randomStringIntPair expectFn)
        , Test.fuzz2 Fuzz.float Fuzz.bool ("Random float-bool pair " ++ condStr) (randomFloatBoolPair expectFn)
        , Test.fuzz2 Fuzz.float Fuzz.float ("Random float pair " ++ condStr) (randomFloatPair expectFn)
        , Test.fuzz3 Fuzz.bool Fuzz.bool Fuzz.bool ("Random bool triple " ++ condStr) (randomBoolTriple expectFn)
        , Test.fuzz3 Fuzz.int Fuzz.float Fuzz.string ("Random mixed triple " ++ condStr) (randomMixedTriple expectFn)
        ]


randomIntPair : (Src.Module -> Expectation) -> (Int -> Int -> Expectation)
randomIntPair expectFn a b =
    let
        modul =
            makeModule "testValue" (tupleExpr (intExpr a) (intExpr b))
    in
    expectFn modul


randomIntTriple : (Src.Module -> Expectation) -> (Int -> Int -> Int -> Expectation)
randomIntTriple expectFn a b c =
    let
        modul =
            makeModule "testValue" (tuple3Expr (intExpr a) (intExpr b) (intExpr c))
    in
    expectFn modul


randomStringIntPair : (Src.Module -> Expectation) -> (String -> Int -> Expectation)
randomStringIntPair expectFn s n =
    let
        modul =
            makeModule "testValue" (tupleExpr (strExpr s) (intExpr n))
    in
    expectFn modul


randomFloatBoolPair : (Src.Module -> Expectation) -> (Float -> Bool -> Expectation)
randomFloatBoolPair expectFn f b =
    let
        modul =
            makeModule "testValue" (tupleExpr (floatExpr f) (boolExpr b))
    in
    expectFn modul


randomFloatPair : (Src.Module -> Expectation) -> (Float -> Float -> Expectation)
randomFloatPair expectFn a b =
    let
        modul =
            makeModule "testValue" (tupleExpr (floatExpr a) (floatExpr b))
    in
    expectFn modul


randomBoolTriple : (Src.Module -> Expectation) -> (Bool -> Bool -> Bool -> Expectation)
randomBoolTriple expectFn a b c =
    let
        modul =
            makeModule "testValue" (tuple3Expr (boolExpr a) (boolExpr b) (boolExpr c))
    in
    expectFn modul


randomMixedTriple : (Src.Module -> Expectation) -> (Int -> Float -> String -> Expectation)
randomMixedTriple expectFn a b c =
    let
        modul =
            makeModule "testValue" (tuple3Expr (intExpr a) (floatExpr b) (strExpr c))
    in
    expectFn modul
