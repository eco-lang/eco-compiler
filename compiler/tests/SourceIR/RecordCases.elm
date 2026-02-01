module SourceIR.RecordCases exposing (expectSuite, testCases)

{-| Tests for record expressions: creation, access, update.
-}

import Compiler.AST.Source as Src
import Compiler.AST.SourceBuilder
    exposing
        ( accessExpr
        , accessorExpr
        , boolExpr
        , define
        , floatExpr
        , intExpr
        , letExpr
        , listExpr
        , makeModule
        , recordExpr
        , strExpr
        , tupleExpr
        , updateExpr
        , varExpr
        )
import Compiler.BulkCheck exposing (TestCase, bulkCheck)
import Expect exposing (Expectation)
import Test exposing (Test)


expectSuite : (Src.Module -> Expectation) -> String -> Test
expectSuite expectFn condStr =
    Test.test ("Record expressions " ++ condStr) <|
        \_ -> bulkCheck (testCases expectFn)


testCases : (Src.Module -> Expectation) -> List TestCase
testCases expectFn =
    emptyRecordCases expectFn
        ++ singleFieldCases expectFn
        ++ multiFieldCases expectFn
        ++ nestedRecordCases expectFn
        ++ recordAccessCases expectFn
        ++ recordAccessorCases expectFn
        ++ recordUpdateCases expectFn



-- ============================================================================
-- EMPTY RECORD
-- ============================================================================


emptyRecordCases : (Src.Module -> Expectation) -> List TestCase
emptyRecordCases expectFn =
    [ { label = "Empty record", run = emptyRecord expectFn }
    ]


emptyRecord : (Src.Module -> Expectation) -> (() -> Expectation)
emptyRecord expectFn _ =
    let
        modul =
            makeModule "testValue" (recordExpr [])
    in
    expectFn modul



-- ============================================================================
-- SINGLE FIELD RECORDS
-- ============================================================================


singleFieldCases : (Src.Module -> Expectation) -> List TestCase
singleFieldCases expectFn =
    [ { label = "Record with int field", run = recordWithIntField expectFn }
    , { label = "Record with list field", run = recordWithListField expectFn }
    , { label = "Record with tuple field", run = recordWithTupleField expectFn }
    ]


recordWithIntField : (Src.Module -> Expectation) -> (() -> Expectation)
recordWithIntField expectFn _ =
    let
        modul =
            makeModule "testValue" (recordExpr [ ( "value", intExpr 42 ) ])
    in
    expectFn modul


recordWithListField : (Src.Module -> Expectation) -> (() -> Expectation)
recordWithListField expectFn _ =
    let
        modul =
            makeModule "testValue" (recordExpr [ ( "items", listExpr [ intExpr 1, intExpr 2 ] ) ])
    in
    expectFn modul


recordWithTupleField : (Src.Module -> Expectation) -> (() -> Expectation)
recordWithTupleField expectFn _ =
    let
        modul =
            makeModule "testValue" (recordExpr [ ( "pair", tupleExpr (intExpr 1) (strExpr "a") ) ])
    in
    expectFn modul



-- ============================================================================
-- MULTI-FIELD RECORDS
-- ============================================================================


multiFieldCases : (Src.Module -> Expectation) -> List TestCase
multiFieldCases expectFn =
    [ { label = "Two-field record", run = twoFieldRecord expectFn }
    , { label = "Five-field record", run = fiveFieldRecord expectFn }
    , { label = "Record with mixed types", run = recordWithMixedTypes expectFn }
    ]


twoFieldRecord : (Src.Module -> Expectation) -> (() -> Expectation)
twoFieldRecord expectFn _ =
    let
        modul =
            makeModule "testValue"
                (recordExpr
                    [ ( "id", intExpr 1 )
                    , ( "name", strExpr "a" )
                    ]
                )
    in
    expectFn modul


fiveFieldRecord : (Src.Module -> Expectation) -> (() -> Expectation)
fiveFieldRecord expectFn _ =
    let
        modul =
            makeModule "testValue"
                (recordExpr
                    [ ( "a", intExpr 1 )
                    , ( "b", intExpr 2 )
                    , ( "c", intExpr 3 )
                    , ( "d", intExpr 4 )
                    , ( "e", intExpr 5 )
                    ]
                )
    in
    expectFn modul


recordWithMixedTypes : (Src.Module -> Expectation) -> (() -> Expectation)
recordWithMixedTypes expectFn _ =
    let
        modul =
            makeModule "testValue"
                (recordExpr
                    [ ( "count", intExpr 42 )
                    , ( "name", strExpr "test" )
                    , ( "value", floatExpr 3.14 )
                    , ( "enabled", boolExpr True )
                    ]
                )
    in
    expectFn modul



-- ============================================================================
-- NESTED RECORDS
-- ============================================================================


nestedRecordCases : (Src.Module -> Expectation) -> List TestCase
nestedRecordCases expectFn =
    [ { label = "Record containing record", run = recordContainingRecord expectFn }
    , { label = "Deeply nested record", run = deeplyNestedRecord expectFn }
    , { label = "Record containing list of records", run = recordContainingListOfRecords expectFn }
    ]


recordContainingRecord : (Src.Module -> Expectation) -> (() -> Expectation)
recordContainingRecord expectFn _ =
    let
        inner =
            recordExpr [ ( "x", intExpr 10 ) ]

        modul =
            makeModule "testValue" (recordExpr [ ( "nested", inner ) ])
    in
    expectFn modul


deeplyNestedRecord : (Src.Module -> Expectation) -> (() -> Expectation)
deeplyNestedRecord expectFn _ =
    let
        level3 =
            recordExpr [ ( "value", intExpr 42 ) ]

        level2 =
            recordExpr [ ( "inner", level3 ) ]

        modul =
            makeModule "testValue"
                (recordExpr
                    [ ( "outer", level2 )
                    , ( "name", strExpr "test" )
                    ]
                )
    in
    expectFn modul


recordContainingListOfRecords : (Src.Module -> Expectation) -> (() -> Expectation)
recordContainingListOfRecords expectFn _ =
    let
        item1 =
            recordExpr [ ( "id", intExpr 1 ) ]

        item2 =
            recordExpr [ ( "id", intExpr 2 ) ]

        modul =
            makeModule "testValue"
                (recordExpr
                    [ ( "items", listExpr [ item1, item2 ] )
                    ]
                )
    in
    expectFn modul



-- ============================================================================
-- RECORD ACCESS
-- ============================================================================


recordAccessCases : (Src.Module -> Expectation) -> List TestCase
recordAccessCases expectFn =
    [ { label = "Access single field", run = accessSingleField expectFn }
    , { label = "Chained access", run = chainedAccess expectFn }
    ]


accessSingleField : (Src.Module -> Expectation) -> (() -> Expectation)
accessSingleField expectFn _ =
    let
        record =
            recordExpr [ ( "x", intExpr 10 ) ]

        def =
            define "r" [] record

        access =
            accessExpr (varExpr "r") "x"

        modul =
            makeModule "testValue" (letExpr [ def ] access)
    in
    expectFn modul


chainedAccess : (Src.Module -> Expectation) -> (() -> Expectation)
chainedAccess expectFn _ =
    let
        inner =
            recordExpr [ ( "value", intExpr 42 ) ]

        outer =
            recordExpr [ ( "nested", inner ) ]

        def =
            define "r" [] outer

        access =
            accessExpr (accessExpr (varExpr "r") "nested") "value"

        modul =
            makeModule "testValue" (letExpr [ def ] access)
    in
    expectFn modul



-- ============================================================================
-- RECORD ACCESSOR FUNCTIONS
-- ============================================================================


recordAccessorCases : (Src.Module -> Expectation) -> List TestCase
recordAccessorCases expectFn =
    [ { label = "Accessor function", run = accessorFunction expectFn }
    , { label = "Multiple accessor functions", run = multipleAccessorFunctions expectFn }
    ]


accessorFunction : (Src.Module -> Expectation) -> (() -> Expectation)
accessorFunction expectFn _ =
    let
        modul =
            makeModule "testValue" (accessorExpr "x")
    in
    expectFn modul


multipleAccessorFunctions : (Src.Module -> Expectation) -> (() -> Expectation)
multipleAccessorFunctions expectFn _ =
    let
        modul =
            makeModule "testValue" (tupleExpr (accessorExpr "x") (accessorExpr "y"))
    in
    expectFn modul



-- ============================================================================
-- RECORD UPDATE
-- ============================================================================


recordUpdateCases : (Src.Module -> Expectation) -> List TestCase
recordUpdateCases expectFn =
    [ { label = "Update single field", run = updateSingleField expectFn }
    , { label = "Update multiple fields", run = updateMultipleFields expectFn }
    , { label = "Chained updates", run = chainedUpdates expectFn }
    ]


updateSingleField : (Src.Module -> Expectation) -> (() -> Expectation)
updateSingleField expectFn _ =
    let
        record =
            recordExpr
                [ ( "x", intExpr 10 )
                , ( "y", intExpr 20 )
                ]

        def =
            define "r" [] record

        update =
            updateExpr (varExpr "r") [ ( "x", intExpr 100 ) ]

        modul =
            makeModule "testValue" (letExpr [ def ] update)
    in
    expectFn modul


updateMultipleFields : (Src.Module -> Expectation) -> (() -> Expectation)
updateMultipleFields expectFn _ =
    let
        record =
            recordExpr
                [ ( "x", intExpr 10 )
                , ( "y", intExpr 20 )
                , ( "z", intExpr 30 )
                ]

        def =
            define "r" [] record

        update =
            updateExpr (varExpr "r")
                [ ( "x", intExpr 100 )
                , ( "z", intExpr 300 )
                ]

        modul =
            makeModule "testValue" (letExpr [ def ] update)
    in
    expectFn modul


chainedUpdates : (Src.Module -> Expectation) -> (() -> Expectation)
chainedUpdates expectFn _ =
    let
        record =
            recordExpr
                [ ( "x", intExpr 1 )
                , ( "y", intExpr 2 )
                ]

        defR =
            define "r" [] record

        update1 =
            updateExpr (varExpr "r") [ ( "x", intExpr 10 ) ]

        defR2 =
            define "r2" [] update1

        update2 =
            updateExpr (varExpr "r2") [ ( "y", intExpr 20 ) ]

        modul =
            makeModule "testValue" (letExpr [ defR, defR2 ] update2)
    in
    expectFn modul
