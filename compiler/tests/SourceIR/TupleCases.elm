module SourceIR.TupleCases exposing (expectSuite)

{-| Tests for tuple expressions: 2-tuples and 3-tuples.
-}

import Compiler.AST.Source as Src
import Compiler.AST.SourceBuilder
    exposing
        ( intExpr
        , listExpr
        , makeModule
        , recordExpr
        , strExpr
        , tuple3Expr
        , tupleExpr
        )
import Compiler.BulkCheck exposing (TestCase, bulkCheck)
import Expect exposing (Expectation)
import Test exposing (Test)


expectSuite : (Src.Module -> Expectation) -> String -> Test
expectSuite expectFn condStr =
    Test.test ("Tuple expressions " ++ condStr) <|
        \_ -> bulkCheck (testCases expectFn)


testCases : (Src.Module -> Expectation) -> List TestCase
testCases expectFn =
    tuple2Cases expectFn
        ++ tuple3Cases expectFn
        ++ nestedTupleCases expectFn
        ++ mixedTypeTupleCases expectFn



-- ============================================================================
-- 2-TUPLES
-- ============================================================================


tuple2Cases : (Src.Module -> Expectation) -> List TestCase
tuple2Cases expectFn =
    [ { label = "Pair of ints", run = pairOfInts expectFn }
    ]


pairOfInts : (Src.Module -> Expectation) -> (() -> Expectation)
pairOfInts expectFn _ =
    let
        modul =
            makeModule "testValue" (tupleExpr (intExpr 1) (intExpr 2))
    in
    expectFn modul



-- ============================================================================
-- 3-TUPLES
-- ============================================================================


tuple3Cases : (Src.Module -> Expectation) -> List TestCase
tuple3Cases expectFn =
    [ { label = "Triple of ints", run = tripleOfInts expectFn }
    , { label = "Triple of mixed types", run = tripleOfMixedTypes expectFn }
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
            makeModule "testValue" (tuple3Expr (intExpr 42) (strExpr "hello") (intExpr 100))
    in
    expectFn modul



-- ============================================================================
-- NESTED TUPLES
-- ============================================================================


nestedTupleCases : (Src.Module -> Expectation) -> List TestCase
nestedTupleCases expectFn =
    [ { label = "Tuple containing tuple", run = tupleContainingTuple expectFn }
    , { label = "Deeply nested tuple", run = deeplyNestedTuple expectFn }
    , { label = "2-tuple containing 3-tuples", run = tuple2Containing3Tuples expectFn }
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



-- ============================================================================
-- MIXED TYPE TUPLES
-- ============================================================================


mixedTypeTupleCases : (Src.Module -> Expectation) -> List TestCase
mixedTypeTupleCases expectFn =
    [ { label = "Tuple with list", run = tupleWithList expectFn }
    , { label = "Tuple with record", run = tupleWithRecord expectFn }
    , { label = "Triple with list and record", run = tripleWithListAndRecord expectFn }
    ]


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
