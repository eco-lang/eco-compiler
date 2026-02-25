module SourceIR.LetDestructCases exposing (expectSuite)

{-| Tests for destructuring let expressions.
-}

import Compiler.AST.Source as Src
import Compiler.AST.SourceBuilder
    exposing
        ( callExpr
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
        , tuple3Expr
        , tupleExpr
        , varExpr
        )
import Compiler.BulkCheck exposing (TestCase, bulkCheck)
import Expect exposing (Expectation)
import Test exposing (Test)


expectSuite : (Src.Module -> Expectation) -> String -> Test
expectSuite expectFn condStr =
    Test.test ("Let destruct expressions " ++ condStr) <|
        \_ -> bulkCheck (testCases expectFn)


testCases : (Src.Module -> Expectation) -> List TestCase
testCases expectFn =
    tupleDestructCases expectFn
        ++ recordDestructCases expectFn
        ++ listDestructCases expectFn
        ++ nestedDestructCases expectFn
        ++ aliasDestructCases expectFn
        ++ complexDestructCases expectFn



-- ============================================================================
-- TUPLE DESTRUCTURING
-- ============================================================================


tupleDestructCases : (Src.Module -> Expectation) -> List TestCase
tupleDestructCases expectFn =
    [ { label = "Destruct 2-tuple", run = destruct2Tuple expectFn }
    , { label = "Destruct 3-tuple", run = destruct3Tuple expectFn }
    , { label = "Destruct tuple with wildcard", run = destructTupleWithWildcard expectFn }
    , { label = "Multiple tuple destructs", run = multipleTupleDestructs expectFn }
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



-- ============================================================================
-- RECORD DESTRUCTURING
-- ============================================================================


recordDestructCases : (Src.Module -> Expectation) -> List TestCase
recordDestructCases expectFn =
    [ { label = "Destruct single field record", run = destructSingleFieldRecord expectFn }
    , { label = "Destruct multi-field record", run = destructMultiFieldRecord expectFn }
    , { label = "Destruct partial record", run = destructPartialRecord expectFn }
    , { label = "Multiple record destructs", run = multipleRecordDestructs expectFn }
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



-- ============================================================================
-- LIST DESTRUCTURING
-- ============================================================================


listDestructCases : (Src.Module -> Expectation) -> List TestCase
listDestructCases expectFn =
    [ { label = "Destruct cons pattern", run = destructConsPattern expectFn }
    , { label = "Destruct fixed list pattern", run = destructFixedListPattern expectFn }
    , { label = "Destruct nested cons", run = destructNestedCons expectFn }
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
-- NESTED DESTRUCTURING
-- ============================================================================


nestedDestructCases : (Src.Module -> Expectation) -> List TestCase
nestedDestructCases expectFn =
    [ { label = "Destruct tuple of tuples", run = destructTupleOfTuples expectFn }
    , { label = "Destruct tuple with record", run = destructTupleWithRecord expectFn }
    , { label = "Deeply nested destruct", run = deeplyNestedDestruct expectFn }
    , { label = "Triple nested destruct", run = tripleNestedDestruct expectFn }
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
-- ALIAS DESTRUCTURING
-- ============================================================================


aliasDestructCases : (Src.Module -> Expectation) -> List TestCase
aliasDestructCases expectFn =
    [ { label = "Destruct with simple alias", run = destructWithSimpleAlias expectFn }
    , { label = "Destruct with nested alias", run = destructWithNestedAlias expectFn }
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



-- ============================================================================
-- COMPLEX DESTRUCTURING
-- ============================================================================


complexDestructCases : (Src.Module -> Expectation) -> List TestCase
complexDestructCases expectFn =
    [ { label = "Mixed destruct and define", run = mixedDestructAndDefine expectFn }
    , { label = "Destruct in nested let", run = destructInNestedLet expectFn }
    , { label = "Chain of destructs", run = chainOfDestructs expectFn }
    , { label = "Destruct with function call result", run = destructWithFunctionCallResult expectFn }
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
