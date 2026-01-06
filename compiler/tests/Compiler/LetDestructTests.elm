module Compiler.LetDestructTests exposing (expectSuite)

{-| Tests for destructuring let expressions.
-}

import Compiler.AST.Source as Src
import Compiler.AST.SourceBuilder
    exposing
        ( accessExpr
        , callExpr
        , define
        , destruct
        , intExpr
        , letExpr
        , listExpr
        , makeModule
        , pAlias
        , pAnything
        , pCons
        , pList
        , pRecord
        , pTuple
        , pTuple3
        , pVar
        , recordExpr
        , strExpr
        , tuple3Expr
        , tupleExpr
        , varExpr
        )
import Expect exposing (Expectation)
import Fuzz
import Test exposing (Test)


expectSuite : (Src.Module -> Expectation) -> String -> Test
expectSuite expectFn condStr =
    Test.describe ("Let destruct expressions " ++ condStr)
        [ tupleDestructTests expectFn condStr
        , recordDestructTests expectFn condStr
        , listDestructTests expectFn condStr
        , nestedDestructTests expectFn condStr
        , aliasDestructTests expectFn condStr
        , complexDestructTests expectFn condStr
        , destructFuzzTests expectFn condStr
        ]



-- ============================================================================
-- TUPLE DESTRUCTURING (6 tests)
-- ============================================================================


tupleDestructTests : (Src.Module -> Expectation) -> String -> Test
tupleDestructTests expectFn condStr =
    Test.describe ("Tuple destructuring " ++ condStr)
        [ Test.test ("Destruct 2-tuple " ++ condStr) (destruct2Tuple expectFn)
        , Test.fuzz2 Fuzz.int Fuzz.int ("Destruct fuzzed tuple " ++ condStr) (destructFuzzedTuple expectFn)
        , Test.test ("Destruct 3-tuple " ++ condStr) (destruct3Tuple expectFn)
        , Test.test ("Destruct tuple with wildcard " ++ condStr) (destructTupleWithWildcard expectFn)
        , Test.test ("Multiple tuple destructs " ++ condStr) (multipleTupleDestructs expectFn)
        , Test.fuzz3 Fuzz.int Fuzz.int Fuzz.int ("Destruct fuzzed 3-tuple " ++ condStr) (destructFuzzed3Tuple expectFn)
        ]


destruct2Tuple : (Src.Module -> Expectation) -> (() -> Expectation)
destruct2Tuple expectFn _ =
    let
        pair =
            tupleExpr (intExpr 1) (intExpr 2)

        def =
            destruct (pTuple (pVar "a") (pVar "b")) pair

        modul =
            makeModule "testValue" (letExpr [ def ] (varExpr "a"))
    in
    expectFn modul


destructFuzzedTuple : (Src.Module -> Expectation) -> (Int -> Int -> Expectation)
destructFuzzedTuple expectFn a b =
    let
        pair =
            tupleExpr (intExpr a) (intExpr b)

        def =
            destruct (pTuple (pVar "x") (pVar "y")) pair

        modul =
            makeModule "testValue" (letExpr [ def ] (tupleExpr (varExpr "y") (varExpr "x")))
    in
    expectFn modul


destruct3Tuple : (Src.Module -> Expectation) -> (() -> Expectation)
destruct3Tuple expectFn _ =
    let
        triple =
            tuple3Expr (intExpr 1) (intExpr 2) (intExpr 3)

        def =
            destruct (pTuple3 (pVar "a") (pVar "b") (pVar "c")) triple

        modul =
            makeModule "testValue" (letExpr [ def ] (varExpr "b"))
    in
    expectFn modul


destructTupleWithWildcard : (Src.Module -> Expectation) -> (() -> Expectation)
destructTupleWithWildcard expectFn _ =
    let
        pair =
            tupleExpr (intExpr 1) (intExpr 2)

        def =
            destruct (pTuple (pVar "x") pAnything) pair

        modul =
            makeModule "testValue" (letExpr [ def ] (varExpr "x"))
    in
    expectFn modul


multipleTupleDestructs : (Src.Module -> Expectation) -> (() -> Expectation)
multipleTupleDestructs expectFn _ =
    let
        def1 =
            destruct (pTuple (pVar "a") (pVar "b")) (tupleExpr (intExpr 1) (intExpr 2))

        def2 =
            destruct (pTuple (pVar "c") (pVar "d")) (tupleExpr (intExpr 3) (intExpr 4))

        modul =
            makeModule "testValue"
                (letExpr [ def1, def2 ]
                    (listExpr [ varExpr "a", varExpr "b", varExpr "c", varExpr "d" ])
                )
    in
    expectFn modul


destructFuzzed3Tuple : (Src.Module -> Expectation) -> (Int -> Int -> Int -> Expectation)
destructFuzzed3Tuple expectFn a b c =
    let
        triple =
            tuple3Expr (intExpr a) (intExpr b) (intExpr c)

        def =
            destruct (pTuple3 (pVar "x") (pVar "y") (pVar "z")) triple

        modul =
            makeModule "testValue" (letExpr [ def ] (tuple3Expr (varExpr "z") (varExpr "y") (varExpr "x")))
    in
    expectFn modul



-- ============================================================================
-- RECORD DESTRUCTURING (6 tests)
-- ============================================================================


recordDestructTests : (Src.Module -> Expectation) -> String -> Test
recordDestructTests expectFn condStr =
    Test.describe ("Record destructuring " ++ condStr)
        [ Test.test ("Destruct single field record " ++ condStr) (destructSingleFieldRecord expectFn)
        , Test.test ("Destruct multi-field record " ++ condStr) (destructMultiFieldRecord expectFn)
        , Test.fuzz2 Fuzz.int Fuzz.int ("Destruct fuzzed record " ++ condStr) (destructFuzzedRecord expectFn)
        , Test.test ("Destruct partial record " ++ condStr) (destructPartialRecord expectFn)
        , Test.test ("Multiple record destructs " ++ condStr) (multipleRecordDestructs expectFn)
        , Test.test ("Destruct record with many fields " ++ condStr) (destructRecordManyFields expectFn)
        ]


destructSingleFieldRecord : (Src.Module -> Expectation) -> (() -> Expectation)
destructSingleFieldRecord expectFn _ =
    let
        record =
            recordExpr [ ( "x", intExpr 42 ) ]

        def =
            destruct (pRecord [ "x" ]) record

        modul =
            makeModule "testValue" (letExpr [ def ] (varExpr "x"))
    in
    expectFn modul


destructMultiFieldRecord : (Src.Module -> Expectation) -> (() -> Expectation)
destructMultiFieldRecord expectFn _ =
    let
        record =
            recordExpr [ ( "x", intExpr 1 ), ( "y", intExpr 2 ) ]

        def =
            destruct (pRecord [ "x", "y" ]) record

        modul =
            makeModule "testValue" (letExpr [ def ] (tupleExpr (varExpr "x") (varExpr "y")))
    in
    expectFn modul


destructFuzzedRecord : (Src.Module -> Expectation) -> (Int -> Int -> Expectation)
destructFuzzedRecord expectFn a b =
    let
        record =
            recordExpr [ ( "first", intExpr a ), ( "second", intExpr b ) ]

        def =
            destruct (pRecord [ "first", "second" ]) record

        modul =
            makeModule "testValue" (letExpr [ def ] (tupleExpr (varExpr "first") (varExpr "second")))
    in
    expectFn modul


destructPartialRecord : (Src.Module -> Expectation) -> (() -> Expectation)
destructPartialRecord expectFn _ =
    let
        record =
            recordExpr [ ( "a", intExpr 1 ), ( "b", intExpr 2 ), ( "c", intExpr 3 ) ]

        def =
            destruct (pRecord [ "a", "c" ]) record

        modul =
            makeModule "testValue" (letExpr [ def ] (tupleExpr (varExpr "a") (varExpr "c")))
    in
    expectFn modul


multipleRecordDestructs : (Src.Module -> Expectation) -> (() -> Expectation)
multipleRecordDestructs expectFn _ =
    let
        def1 =
            destruct (pRecord [ "x" ]) (recordExpr [ ( "x", intExpr 1 ) ])

        def2 =
            destruct (pRecord [ "y" ]) (recordExpr [ ( "y", intExpr 2 ) ])

        modul =
            makeModule "testValue" (letExpr [ def1, def2 ] (tupleExpr (varExpr "x") (varExpr "y")))
    in
    expectFn modul


destructRecordManyFields : (Src.Module -> Expectation) -> (() -> Expectation)
destructRecordManyFields expectFn _ =
    let
        fields =
            List.map (\i -> ( String.fromChar (Char.fromCode (97 + i)), intExpr i )) (List.range 0 5)

        record =
            recordExpr fields

        fieldNames =
            List.map (\( name, _ ) -> name) fields

        def =
            destruct (pRecord fieldNames) record

        modul =
            makeModule "testValue" (letExpr [ def ] (varExpr "a"))
    in
    expectFn modul



-- ============================================================================
-- LIST DESTRUCTURING (4 tests)
-- ============================================================================


listDestructTests : (Src.Module -> Expectation) -> String -> Test
listDestructTests expectFn condStr =
    Test.describe ("List destructuring " ++ condStr)
        [ Test.test ("Destruct cons pattern " ++ condStr) (destructConsPattern expectFn)
        , Test.test ("Destruct fixed list pattern " ++ condStr) (destructFixedListPattern expectFn)
        , Test.fuzz2 Fuzz.int Fuzz.int ("Destruct fuzzed list " ++ condStr) (destructFuzzedList expectFn)
        , Test.test ("Destruct nested cons " ++ condStr) (destructNestedCons expectFn)
        ]


destructConsPattern : (Src.Module -> Expectation) -> (() -> Expectation)
destructConsPattern expectFn _ =
    let
        list =
            listExpr [ intExpr 1, intExpr 2, intExpr 3 ]

        def =
            destruct (pCons (pVar "head") (pVar "tail")) list

        modul =
            makeModule "testValue" (letExpr [ def ] (varExpr "head"))
    in
    expectFn modul


destructFixedListPattern : (Src.Module -> Expectation) -> (() -> Expectation)
destructFixedListPattern expectFn _ =
    let
        list =
            listExpr [ intExpr 1, intExpr 2 ]

        def =
            destruct (pList [ pVar "a", pVar "b" ]) list

        modul =
            makeModule "testValue" (letExpr [ def ] (tupleExpr (varExpr "a") (varExpr "b")))
    in
    expectFn modul


destructFuzzedList : (Src.Module -> Expectation) -> (Int -> Int -> Expectation)
destructFuzzedList expectFn a b =
    let
        list =
            listExpr [ intExpr a, intExpr b ]

        def =
            destruct (pCons (pVar "h") (pVar "t")) list

        modul =
            makeModule "testValue" (letExpr [ def ] (varExpr "h"))
    in
    expectFn modul


destructNestedCons : (Src.Module -> Expectation) -> (() -> Expectation)
destructNestedCons expectFn _ =
    let
        list =
            listExpr [ intExpr 1, intExpr 2, intExpr 3 ]

        def =
            destruct (pCons (pVar "a") (pCons (pVar "b") (pVar "rest"))) list

        modul =
            makeModule "testValue" (letExpr [ def ] (tupleExpr (varExpr "a") (varExpr "b")))
    in
    expectFn modul



-- ============================================================================
-- NESTED DESTRUCTURING (6 tests)
-- ============================================================================


nestedDestructTests : (Src.Module -> Expectation) -> String -> Test
nestedDestructTests expectFn condStr =
    Test.describe ("Nested destructuring " ++ condStr)
        [ Test.test ("Destruct tuple of tuples " ++ condStr) (destructTupleOfTuples expectFn)
        , Test.test ("Destruct tuple with record " ++ condStr) (destructTupleWithRecord expectFn)
        , Test.test ("Destruct record with nested tuple " ++ condStr) (destructRecordWithNestedTuple expectFn)
        , Test.test ("Deeply nested destruct " ++ condStr) (deeplyNestedDestruct expectFn)
        , Test.fuzz2 Fuzz.int Fuzz.int ("Nested destruct with fuzzed values " ++ condStr) (nestedDestructFuzzed expectFn)
        , Test.test ("Triple nested destruct " ++ condStr) (tripleNestedDestruct expectFn)
        ]


destructTupleOfTuples : (Src.Module -> Expectation) -> (() -> Expectation)
destructTupleOfTuples expectFn _ =
    let
        nested =
            tupleExpr (tupleExpr (intExpr 1) (intExpr 2)) (tupleExpr (intExpr 3) (intExpr 4))

        def =
            destruct (pTuple (pTuple (pVar "a") (pVar "b")) (pTuple (pVar "c") (pVar "d"))) nested

        modul =
            makeModule "testValue" (letExpr [ def ] (listExpr [ varExpr "a", varExpr "b", varExpr "c", varExpr "d" ]))
    in
    expectFn modul


destructTupleWithRecord : (Src.Module -> Expectation) -> (() -> Expectation)
destructTupleWithRecord expectFn _ =
    let
        nested =
            tupleExpr (recordExpr [ ( "x", intExpr 1 ) ]) (intExpr 2)

        def =
            destruct (pTuple (pRecord [ "x" ]) (pVar "y")) nested

        modul =
            makeModule "testValue" (letExpr [ def ] (tupleExpr (varExpr "x") (varExpr "y")))
    in
    expectFn modul


destructRecordWithNestedTuple : (Src.Module -> Expectation) -> (() -> Expectation)
destructRecordWithNestedTuple expectFn _ =
    let
        record =
            recordExpr [ ( "pair", tupleExpr (intExpr 1) (intExpr 2) ) ]

        def =
            define "r" [] record

        modul =
            makeModule "testValue" (letExpr [ def ] (accessExpr (varExpr "r") "pair"))
    in
    expectFn modul


deeplyNestedDestruct : (Src.Module -> Expectation) -> (() -> Expectation)
deeplyNestedDestruct expectFn _ =
    let
        deep =
            tupleExpr
                (tupleExpr (intExpr 1) (tupleExpr (intExpr 2) (intExpr 3)))
                (intExpr 4)

        def =
            destruct
                (pTuple
                    (pTuple (pVar "a") (pTuple (pVar "b") (pVar "c")))
                    (pVar "d")
                )
                deep

        modul =
            makeModule "testValue" (letExpr [ def ] (listExpr [ varExpr "a", varExpr "b", varExpr "c", varExpr "d" ]))
    in
    expectFn modul


nestedDestructFuzzed : (Src.Module -> Expectation) -> (Int -> Int -> Expectation)
nestedDestructFuzzed expectFn a b =
    let
        nested =
            tupleExpr (tupleExpr (intExpr a) (intExpr b)) (intExpr 0)

        def =
            destruct (pTuple (pTuple (pVar "x") (pVar "y")) pAnything) nested

        modul =
            makeModule "testValue" (letExpr [ def ] (tupleExpr (varExpr "x") (varExpr "y")))
    in
    expectFn modul


tripleNestedDestruct : (Src.Module -> Expectation) -> (() -> Expectation)
tripleNestedDestruct expectFn _ =
    let
        triple =
            tuple3Expr
                (tupleExpr (intExpr 1) (intExpr 2))
                (tupleExpr (intExpr 3) (intExpr 4))
                (tupleExpr (intExpr 5) (intExpr 6))

        def =
            destruct
                (pTuple3
                    (pTuple (pVar "a") (pVar "b"))
                    (pTuple (pVar "c") (pVar "d"))
                    (pTuple (pVar "e") (pVar "f"))
                )
                triple

        modul =
            makeModule "testValue"
                (letExpr [ def ]
                    (listExpr [ varExpr "a", varExpr "b", varExpr "c", varExpr "d", varExpr "e", varExpr "f" ])
                )
    in
    expectFn modul



-- ============================================================================
-- ALIAS DESTRUCTURING (4 tests)
-- ============================================================================


aliasDestructTests : (Src.Module -> Expectation) -> String -> Test
aliasDestructTests expectFn condStr =
    Test.describe ("Alias pattern destructuring " ++ condStr)
        [ Test.test ("Destruct with simple alias " ++ condStr) (destructWithSimpleAlias expectFn)
        , Test.test ("Destruct with nested alias " ++ condStr) (destructWithNestedAlias expectFn)
        , Test.fuzz Fuzz.int ("Alias destruct with fuzzed value " ++ condStr) (aliasDestructFuzzed expectFn)

        -- Moved to TypeCheckFails.elm: , Test.test ("Multiple aliases in destruct " ++ condStr) (multipleAliasesInDestruct expectFn)
        ]


destructWithSimpleAlias : (Src.Module -> Expectation) -> (() -> Expectation)
destructWithSimpleAlias expectFn _ =
    let
        pair =
            tupleExpr (intExpr 1) (intExpr 2)

        def =
            destruct (pAlias (pTuple (pVar "a") (pVar "b")) "whole") pair

        modul =
            makeModule "testValue" (letExpr [ def ] (tupleExpr (varExpr "whole") (varExpr "a")))
    in
    expectFn modul


destructWithNestedAlias : (Src.Module -> Expectation) -> (() -> Expectation)
destructWithNestedAlias expectFn _ =
    let
        nested =
            tupleExpr (tupleExpr (intExpr 1) (intExpr 2)) (intExpr 3)

        def =
            destruct
                (pTuple
                    (pAlias (pTuple (pVar "a") (pVar "b")) "inner")
                    (pVar "c")
                )
                nested

        modul =
            makeModule "testValue" (letExpr [ def ] (tupleExpr (varExpr "inner") (varExpr "a")))
    in
    expectFn modul


aliasDestructFuzzed : (Src.Module -> Expectation) -> (Int -> Expectation)
aliasDestructFuzzed expectFn n =
    let
        pair =
            tupleExpr (intExpr n) (intExpr 0)

        def =
            destruct (pAlias (pTuple (pVar "x") pAnything) "pair") pair

        modul =
            makeModule "testValue" (letExpr [ def ] (tupleExpr (varExpr "pair") (varExpr "x")))
    in
    expectFn modul



-- ============================================================================
-- COMPLEX DESTRUCTURING (4 tests)
-- ============================================================================


complexDestructTests : (Src.Module -> Expectation) -> String -> Test
complexDestructTests expectFn condStr =
    Test.describe ("Complex destructuring scenarios " ++ condStr)
        [ Test.test ("Mixed destruct and define " ++ condStr) (mixedDestructAndDefine expectFn)
        , Test.test ("Destruct in nested let " ++ condStr) (destructInNestedLet expectFn)
        , Test.test ("Chain of destructs " ++ condStr) (chainOfDestructs expectFn)
        , Test.test ("Destruct with function call result " ++ condStr) (destructWithFunctionCallResult expectFn)
        ]


mixedDestructAndDefine : (Src.Module -> Expectation) -> (() -> Expectation)
mixedDestructAndDefine expectFn _ =
    let
        def1 =
            define "x" [] (intExpr 1)

        def2 =
            destruct (pTuple (pVar "a") (pVar "b")) (tupleExpr (intExpr 2) (intExpr 3))

        def3 =
            define "y" [] (intExpr 4)

        modul =
            makeModule "testValue" (letExpr [ def1, def2, def3 ] (listExpr [ varExpr "x", varExpr "a", varExpr "b", varExpr "y" ]))
    in
    expectFn modul


destructInNestedLet : (Src.Module -> Expectation) -> (() -> Expectation)
destructInNestedLet expectFn _ =
    let
        outerDef =
            define "pair" [] (tupleExpr (intExpr 1) (intExpr 2))

        innerLet =
            letExpr
                [ destruct (pTuple (pVar "a") (pVar "b")) (varExpr "pair") ]
                (tupleExpr (varExpr "b") (varExpr "a"))

        modul =
            makeModule "testValue" (letExpr [ outerDef ] innerLet)
    in
    expectFn modul


chainOfDestructs : (Src.Module -> Expectation) -> (() -> Expectation)
chainOfDestructs expectFn _ =
    let
        def1 =
            destruct (pTuple (pVar "a") (pVar "rest1")) (tupleExpr (intExpr 1) (tupleExpr (intExpr 2) (intExpr 3)))

        def2 =
            destruct (pTuple (pVar "b") (pVar "c")) (varExpr "rest1")

        modul =
            makeModule "testValue" (letExpr [ def1, def2 ] (listExpr [ varExpr "a", varExpr "b", varExpr "c" ]))
    in
    expectFn modul


destructWithFunctionCallResult : (Src.Module -> Expectation) -> (() -> Expectation)
destructWithFunctionCallResult expectFn _ =
    let
        fnDef =
            define "makePair" [] (tupleExpr (intExpr 1) (intExpr 2))

        destructDef =
            destruct (pTuple (pVar "a") (pVar "b")) (callExpr (varExpr "makePair") [])

        modul =
            makeModule "testValue" (letExpr [ fnDef, destructDef ] (tupleExpr (varExpr "a") (varExpr "b")))
    in
    expectFn modul



-- ============================================================================
-- FUZZ TESTS (2 tests)
-- ============================================================================


destructFuzzTests : (Src.Module -> Expectation) -> String -> Test
destructFuzzTests expectFn condStr =
    Test.describe ("Fuzzed destruct tests " ++ condStr)
        [ Test.fuzz3 Fuzz.int Fuzz.int Fuzz.int ("Destruct triple with fuzzed values " ++ condStr) (destructTripleFuzzed expectFn)
        , Test.fuzz2 Fuzz.int Fuzz.string ("Destruct mixed types " ++ condStr) (destructMixedTypes expectFn)
        ]


destructTripleFuzzed : (Src.Module -> Expectation) -> (Int -> Int -> Int -> Expectation)
destructTripleFuzzed expectFn a b c =
    let
        triple =
            tuple3Expr (intExpr a) (intExpr b) (intExpr c)

        def =
            destruct (pTuple3 (pVar "x") (pVar "y") (pVar "z")) triple

        modul =
            makeModule "testValue"
                (letExpr [ def ]
                    (tuple3Expr (varExpr "z") (varExpr "y") (varExpr "x"))
                )
    in
    expectFn modul


destructMixedTypes : (Src.Module -> Expectation) -> (Int -> String -> Expectation)
destructMixedTypes expectFn n s =
    let
        record =
            recordExpr [ ( "num", intExpr n ), ( "str", strExpr s ) ]

        def =
            destruct (pRecord [ "num", "str" ]) record

        modul =
            makeModule "testValue" (letExpr [ def ] (tupleExpr (varExpr "num") (varExpr "str")))
    in
    expectFn modul
