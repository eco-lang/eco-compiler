module Compiler.RecordTests exposing (expectSuite)

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
import Expect exposing (Expectation)
import Test exposing (Test)


expectSuite : (Src.Module -> Expectation) -> String -> Test
expectSuite expectFn condStr =
    Test.describe ("Record expressions " ++ condStr)
        [ emptyRecordTests expectFn condStr
        , singleFieldTests expectFn condStr
        , multiFieldTests expectFn condStr
        , nestedRecordTests expectFn condStr
        , recordAccessTests expectFn condStr
        , recordAccessorTests expectFn condStr
        , recordUpdateTests expectFn condStr
        ]



-- ============================================================================
-- EMPTY RECORD (2 tests)
-- ============================================================================


emptyRecordTests : (Src.Module -> Expectation) -> String -> Test
emptyRecordTests expectFn condStr =
    Test.describe "Empty records"
        [ Test.test ("Empty record " ++ condStr) (emptyRecord expectFn)
        , Test.test ("Two empty records " ++ condStr) (twoEmptyRecords expectFn)
        ]


emptyRecord : (Src.Module -> Expectation) -> (() -> Expectation)
emptyRecord expectFn _ =
    let
        modul =
            makeModule "testValue" (recordExpr [])
    in
    expectFn modul


twoEmptyRecords : (Src.Module -> Expectation) -> (() -> Expectation)
twoEmptyRecords expectFn _ =
    let
        modul1 =
            makeModule "rec1" (recordExpr [])

        modul2 =
            makeModule "rec2" (recordExpr [])
    in
    Expect.all
        [ \_ -> expectFn modul1
        , \_ -> expectFn modul2
        ]
        ()



-- ============================================================================
-- SINGLE FIELD RECORDS (6 tests)
-- ============================================================================


singleFieldTests : (Src.Module -> Expectation) -> String -> Test
singleFieldTests expectFn condStr =
    Test.describe ("Single field records " ++ condStr)
        [ Test.test ("Record with int field " ++ condStr) (recordWithIntField expectFn)
        , Test.test ("Record with string field " ++ condStr) (recordWithStringField expectFn)
        , Test.test ("Record with float field " ++ condStr) (recordWithFloatField expectFn)
        , Test.test ("Record with bool field " ++ condStr) (recordWithBoolField expectFn)
        , Test.test ("Record with list field " ++ condStr) (recordWithListField expectFn)
        , Test.test ("Record with tuple field " ++ condStr) (recordWithTupleField expectFn)
        ]


recordWithIntField : (Src.Module -> Expectation) -> (() -> Expectation)
recordWithIntField expectFn _ =
    let
        modul =
            makeModule "testValue" (recordExpr [ ( "value", intExpr 42 ) ])
    in
    expectFn modul


recordWithStringField : (Src.Module -> Expectation) -> (() -> Expectation)
recordWithStringField expectFn _ =
    let
        modul =
            makeModule "testValue" (recordExpr [ ( "name", strExpr "hello" ) ])
    in
    expectFn modul


recordWithFloatField : (Src.Module -> Expectation) -> (() -> Expectation)
recordWithFloatField expectFn _ =
    let
        modul =
            makeModule "testValue" (recordExpr [ ( "amount", floatExpr 3.14 ) ])
    in
    expectFn modul


recordWithBoolField : (Src.Module -> Expectation) -> (() -> Expectation)
recordWithBoolField expectFn _ =
    let
        modul =
            makeModule "testValue" (recordExpr [ ( "active", boolExpr True ) ])
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
-- MULTI-FIELD RECORDS (6 tests)
-- ============================================================================


multiFieldTests : (Src.Module -> Expectation) -> String -> Test
multiFieldTests expectFn condStr =
    Test.describe ("Multi-field records " ++ condStr)
        [ Test.test ("Two-field record " ++ condStr) (twoFieldRecord expectFn)
        , Test.test ("Three-field record " ++ condStr) (threeFieldRecord expectFn)
        , Test.test ("Five-field record " ++ condStr) (fiveFieldRecord expectFn)
        , Test.test ("Record with mixed types " ++ condStr) (recordWithMixedTypes expectFn)
        , Test.test ("Record with two int fields " ++ condStr) (recordWithTwoIntFields expectFn)
        , Test.test ("Record with ten fields " ++ condStr) (recordWithTenFields expectFn)
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


threeFieldRecord : (Src.Module -> Expectation) -> (() -> Expectation)
threeFieldRecord expectFn _ =
    let
        modul =
            makeModule "testValue"
                (recordExpr
                    [ ( "id", intExpr 1 )
                    , ( "name", strExpr "a" )
                    , ( "active", boolExpr True )
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


recordWithTwoIntFields : (Src.Module -> Expectation) -> (() -> Expectation)
recordWithTwoIntFields expectFn _ =
    let
        modul =
            makeModule "testValue"
                (recordExpr
                    [ ( "x", intExpr 1 )
                    , ( "y", intExpr 2 )
                    ]
                )
    in
    expectFn modul


recordWithTenFields : (Src.Module -> Expectation) -> (() -> Expectation)
recordWithTenFields expectFn _ =
    let
        fields =
            List.indexedMap (\i _ -> ( "field" ++ String.fromInt i, intExpr i )) (List.range 0 9)

        modul =
            makeModule "testValue" (recordExpr fields)
    in
    expectFn modul



-- ============================================================================
-- NESTED RECORDS (6 tests)
-- ============================================================================


nestedRecordTests : (Src.Module -> Expectation) -> String -> Test
nestedRecordTests expectFn condStr =
    Test.describe ("Nested records " ++ condStr)
        [ Test.test ("Record containing record " ++ condStr) (recordContainingRecord expectFn)
        , Test.test ("Deeply nested record " ++ condStr) (deeplyNestedRecord expectFn)
        , Test.test ("Record with list field " ++ condStr) (recordWithListFieldNested expectFn)
        , Test.test ("Record with tuple field " ++ condStr) (recordWithTupleFieldNested expectFn)
        , Test.test ("Multiple levels of nesting " ++ condStr) (multipleLevelsOfNesting expectFn)
        , Test.test ("Record containing list of records " ++ condStr) (recordContainingListOfRecords expectFn)
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


recordWithListFieldNested : (Src.Module -> Expectation) -> (() -> Expectation)
recordWithListFieldNested expectFn _ =
    let
        list =
            listExpr [ intExpr 1, intExpr 2, intExpr 3 ]

        modul =
            makeModule "testValue" (recordExpr [ ( "items", list ) ])
    in
    expectFn modul


recordWithTupleFieldNested : (Src.Module -> Expectation) -> (() -> Expectation)
recordWithTupleFieldNested expectFn _ =
    let
        tuple =
            tupleExpr (intExpr 1) (strExpr "one")

        modul =
            makeModule "testValue" (recordExpr [ ( "pair", tuple ) ])
    in
    expectFn modul


multipleLevelsOfNesting : (Src.Module -> Expectation) -> (() -> Expectation)
multipleLevelsOfNesting expectFn _ =
    let
        deepest =
            recordExpr [ ( "z", intExpr 1 ) ]

        middle =
            recordExpr [ ( "y", deepest ), ( "count", intExpr 2 ) ]

        modul =
            makeModule "testValue"
                (recordExpr
                    [ ( "x", middle )
                    , ( "label", strExpr "outer" )
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
-- RECORD ACCESS (4 tests)
-- ============================================================================


recordAccessTests : (Src.Module -> Expectation) -> String -> Test
recordAccessTests expectFn condStr =
    Test.describe ("Record access " ++ condStr)
        [ Test.test ("Access single field " ++ condStr) (accessSingleField expectFn)
        , Test.test ("Access from multi-field record " ++ condStr) (accessFromMultiFieldRecord expectFn)
        , Test.test ("Chained access " ++ condStr) (chainedAccess expectFn)
        , Test.test ("Multiple accesses " ++ condStr) (multipleAccesses expectFn)
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


accessFromMultiFieldRecord : (Src.Module -> Expectation) -> (() -> Expectation)
accessFromMultiFieldRecord expectFn _ =
    let
        record =
            recordExpr
                [ ( "x", intExpr 10 )
                , ( "y", intExpr 20 )
                ]

        def =
            define "r" [] record

        access =
            accessExpr (varExpr "r") "y"

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


multipleAccesses : (Src.Module -> Expectation) -> (() -> Expectation)
multipleAccesses expectFn _ =
    let
        record =
            recordExpr
                [ ( "x", intExpr 1 )
                , ( "y", intExpr 2 )
                ]

        def =
            define "r" [] record

        result =
            tupleExpr (accessExpr (varExpr "r") "x") (accessExpr (varExpr "r") "y")

        modul =
            makeModule "testValue" (letExpr [ def ] result)
    in
    expectFn modul



-- ============================================================================
-- RECORD ACCESSOR FUNCTIONS (4 tests)
-- ============================================================================


recordAccessorTests : (Src.Module -> Expectation) -> String -> Test
recordAccessorTests expectFn condStr =
    Test.describe ("Record accessor functions " ++ condStr)
        [ Test.test ("Accessor function " ++ condStr) (accessorFunction expectFn)
        , Test.test ("Different accessor function " ++ condStr) (differentAccessorFunction expectFn)
        , Test.test ("Multiple accessor functions " ++ condStr) (multipleAccessorFunctions expectFn)
        , Test.test ("Accessor in list " ++ condStr) (accessorInList expectFn)
        ]


accessorFunction : (Src.Module -> Expectation) -> (() -> Expectation)
accessorFunction expectFn _ =
    let
        modul =
            makeModule "testValue" (accessorExpr "x")
    in
    expectFn modul


differentAccessorFunction : (Src.Module -> Expectation) -> (() -> Expectation)
differentAccessorFunction expectFn _ =
    let
        modul =
            makeModule "testValue" (accessorExpr "name")
    in
    expectFn modul


multipleAccessorFunctions : (Src.Module -> Expectation) -> (() -> Expectation)
multipleAccessorFunctions expectFn _ =
    let
        modul =
            makeModule "testValue" (tupleExpr (accessorExpr "x") (accessorExpr "y"))
    in
    expectFn modul


accessorInList : (Src.Module -> Expectation) -> (() -> Expectation)
accessorInList expectFn _ =
    let
        modul =
            makeModule "testValue" (listExpr [ accessorExpr "a", accessorExpr "b", accessorExpr "c" ])
    in
    expectFn modul



-- ============================================================================
-- RECORD UPDATE (5 tests)
-- ============================================================================


recordUpdateTests : (Src.Module -> Expectation) -> String -> Test
recordUpdateTests expectFn condStr =
    Test.describe ("Record update " ++ condStr)
        [ Test.test ("Update single field " ++ condStr) (updateSingleField expectFn)
        , Test.test ("Update multiple fields " ++ condStr) (updateMultipleFields expectFn)

        -- Moved to TypeCheckFails.elm: , Test.test ("Update with computed value " ++ condStr) (updateWithComputedValue expectFn)
        , Test.test ("Chained updates " ++ condStr) (chainedUpdates expectFn)
        , Test.test ("Update with value " ++ condStr) (updateWithValue expectFn)
        , Test.test ("Update all fields " ++ condStr) (updateAllFields expectFn)
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


updateWithValue : (Src.Module -> Expectation) -> (() -> Expectation)
updateWithValue expectFn _ =
    let
        record =
            recordExpr [ ( "count", intExpr 0 ) ]

        def =
            define "r" [] record

        update =
            updateExpr (varExpr "r") [ ( "count", intExpr 42 ) ]

        modul =
            makeModule "testValue" (letExpr [ def ] update)
    in
    expectFn modul


updateAllFields : (Src.Module -> Expectation) -> (() -> Expectation)
updateAllFields expectFn _ =
    let
        record =
            recordExpr
                [ ( "a", intExpr 1 )
                , ( "b", intExpr 2 )
                , ( "c", intExpr 3 )
                ]

        def =
            define "r" [] record

        update =
            updateExpr (varExpr "r")
                [ ( "a", intExpr 10 )
                , ( "b", intExpr 20 )
                , ( "c", intExpr 30 )
                ]

        modul =
            makeModule "testValue" (letExpr [ def ] update)
    in
    expectFn modul
