module SourceIR.RecordCases exposing (expectSuite)

{-| Small programs, one per way of building or using a record, for checking
that a compiler stage handles records.

A record can be written as a literal, read with `record.field`, read with an
accessor function such as `.field`, and copied with some fields changed as
`{ r | field = value }`. Each of these is its own Source AST node (`Record`,
`Access`, `Accessor` and `Update`), so a stage can handle one and mishandle
another. A program here isolates one form, or one combination such as nesting
or chaining, so that a failure points at it.

The programs are built with `Compiler.AST.SourceBuilder`, not parsed. Each is a
module named `Test` that imports only `Basics` and `List` and carries no type
annotations, so every record type in it comes from inference. The literals
inside the records, lists and pairs are integer literals, which have type
`number` until something fixes it, except a few string literals and one float
literal. Except in "Accessor function", the module has one top-level value,
`testValue`, and the record that a field access or update starts from is bound
in a `let` as `r` (and `r2`).

Nothing here asserts anything about the programs. `expectSuite` passes the
cases' modules, in turn, to the caller's expectation function, stopping at the
first that fails, so what is checked is whatever that function checks. The
cases, by group:

  - Empty record: `testValue` is `{}`.
  - Single-field records: one field holding an integer literal, a list of
    integer literals, or a pair.
  - Multi-field records: two fields, five fields of integer literals, and
    four fields holding an integer, a string, a float and `True`.
  - Nested records: a record in a field, a record two levels deep beside a
    string field, and a list of two records in a field.
  - Field access: `r.x`, and the chained `r.nested.value`.
  - Accessor functions: `.x` bound to a top-level `testFn` and applied to a
    record, and the pair `( .x, .y )`, which is never applied.
  - Record update: one field changed, two of three fields changed, and two
    updates in sequence, the second applied to the result of the first.

Among what is not tested: record patterns, record type annotations (extensible
or not), an update whose record is anything but a variable, an accessor passed
to another function, and any program that should be rejected, such as access
to a field the record lacks.

-}

import Compiler.AST.Source as Src
import Compiler.AST.SourceBuilder
    exposing
        ( accessExpr
        , accessorExpr
        , boolExpr
        , callExpr
        , define
        , floatExpr
        , intExpr
        , letExpr
        , listExpr
        , makeModule
        , makeModuleWithDefs
        , recordExpr
        , strExpr
        , tupleExpr
        , updateExpr
        , varExpr
        )
import Compiler.BulkCheck exposing (TestCase, bulkCheck)
import Expect exposing (Expectation)
import Test exposing (Test)


{-| Creates one test, named `"Record expressions "` followed by `condStr`, that
runs `expectFn` on the module of every case in this file in turn.

The cases run in order and the test fails at the first case whose expectation
fails, reporting that case's label; the cases after it are not run, as
`Compiler.BulkCheck` describes.

-}
expectSuite : (Src.Module -> Expectation) -> String -> Test
expectSuite expectFn condStr =
    Test.test ("Record expressions " ++ condStr) <|
        \_ -> bulkCheck (testCases expectFn)


{-| Returns every case in this file, in the order they run: empty, single-field,
multi-field and nested records, then field access, accessor functions and
record update.
-}
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


{-| Returns the case whose `testValue` is the empty record.
-}
emptyRecordCases : (Src.Module -> Expectation) -> List TestCase
emptyRecordCases expectFn =
    [ { label = "Empty record", run = emptyRecord expectFn }
    ]


{-| Returns the check that runs `expectFn` on a module whose `testValue` is
`{}`.
-}
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


{-| Returns the cases whose `testValue` is a record with one field.
-}
singleFieldCases : (Src.Module -> Expectation) -> List TestCase
singleFieldCases expectFn =
    [ { label = "Record with int field", run = recordWithIntField expectFn }
    , { label = "Record with list field", run = recordWithListField expectFn }
    , { label = "Record with tuple field", run = recordWithTupleField expectFn }
    ]


{-| Returns the check that runs `expectFn` on a module whose `testValue` is
`{ value = 42 }`.
-}
recordWithIntField : (Src.Module -> Expectation) -> (() -> Expectation)
recordWithIntField expectFn _ =
    let
        modul =
            makeModule "testValue" (recordExpr [ ( "value", intExpr 42 ) ])
    in
    expectFn modul


{-| Returns the check that runs `expectFn` on a module whose `testValue` is
`{ items = [ 1, 2 ] }`.
-}
recordWithListField : (Src.Module -> Expectation) -> (() -> Expectation)
recordWithListField expectFn _ =
    let
        modul =
            makeModule "testValue" (recordExpr [ ( "items", listExpr [ intExpr 1, intExpr 2 ] ) ])
    in
    expectFn modul


{-| Returns the check that runs `expectFn` on a module whose `testValue` is
`{ pair = ( 1, "a" ) }`.
-}
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


{-| Returns the cases whose `testValue` is a flat record with several fields.
-}
multiFieldCases : (Src.Module -> Expectation) -> List TestCase
multiFieldCases expectFn =
    [ { label = "Two-field record", run = twoFieldRecord expectFn }
    , { label = "Five-field record", run = fiveFieldRecord expectFn }
    , { label = "Record with mixed types", run = recordWithMixedTypes expectFn }
    ]


{-| Returns the check that runs `expectFn` on a module whose `testValue` is
`{ id = 1, name = "a" }`.
-}
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


{-| Returns the check that runs `expectFn` on a module whose `testValue` is a
record of five fields, `a` to `e`, holding the integer literals 1 to 5.
-}
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


{-| Returns the check that runs `expectFn` on a module whose `testValue` is
`{ count = 42, name = "test", value = 3.14, enabled = True }`.
-}
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


{-| Returns the cases whose `testValue` is a record with records inside it.
-}
nestedRecordCases : (Src.Module -> Expectation) -> List TestCase
nestedRecordCases expectFn =
    [ { label = "Record containing record", run = recordContainingRecord expectFn }
    , { label = "Deeply nested record", run = deeplyNestedRecord expectFn }
    , { label = "Record containing list of records", run = recordContainingListOfRecords expectFn }
    ]


{-| Returns the check that runs `expectFn` on a module whose `testValue` is
`{ nested = { x = 10 } }`.
-}
recordContainingRecord : (Src.Module -> Expectation) -> (() -> Expectation)
recordContainingRecord expectFn _ =
    let
        inner =
            recordExpr [ ( "x", intExpr 10 ) ]

        modul =
            makeModule "testValue" (recordExpr [ ( "nested", inner ) ])
    in
    expectFn modul


{-| Returns the check that runs `expectFn` on a module whose `testValue` is
`{ outer = { inner = { value = 42 } }, name = "test" }`.
-}
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


{-| Returns the check that runs `expectFn` on a module whose `testValue` is
`{ items = [ { id = 1 }, { id = 2 } ] }`.
-}
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


{-| Returns the cases that read a field with `record.field`.
-}
recordAccessCases : (Src.Module -> Expectation) -> List TestCase
recordAccessCases expectFn =
    [ { label = "Access single field", run = accessSingleField expectFn }
    , { label = "Chained access", run = chainedAccess expectFn }
    ]


{-| Returns the check that runs `expectFn` on a module whose `testValue` binds
`r = { x = 10 }` in a `let` and returns `r.x`.
-}
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


{-| Returns the check that runs `expectFn` on a module whose `testValue` binds
`r = { nested = { value = 42 } }` in a `let` and returns `r.nested.value`.
-}
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


{-| Returns the cases that use an accessor function such as `.x`.
-}
recordAccessorCases : (Src.Module -> Expectation) -> List TestCase
recordAccessorCases expectFn =
    [ { label = "Accessor function", run = accessorFunction expectFn }
    , { label = "Multiple accessor functions", run = multipleAccessorFunctions expectFn }
    ]


{-| Returns the check that runs `expectFn` on a module named `Test` with two
top-level values: `testFn`, defined as `.x`, and `testValue`, defined as
`testFn { x = 1 }`.
-}
accessorFunction : (Src.Module -> Expectation) -> (() -> Expectation)
accessorFunction expectFn _ =
    let
        modul =
            makeModuleWithDefs "Test"
                [ ( "testFn", [], accessorExpr "x" )
                , ( "testValue", [], callExpr (varExpr "testFn") [ recordExpr [ ( "x", intExpr 1 ) ] ] )
                ]
    in
    expectFn modul


{-| Returns the check that runs `expectFn` on a module whose `testValue` is the
pair `( .x, .y )`. Neither accessor is applied, so nothing fixes the record
types they take.
-}
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


{-| Returns the cases that copy a record with some fields changed.
-}
recordUpdateCases : (Src.Module -> Expectation) -> List TestCase
recordUpdateCases expectFn =
    [ { label = "Update single field", run = updateSingleField expectFn }
    , { label = "Update multiple fields", run = updateMultipleFields expectFn }
    , { label = "Chained updates", run = chainedUpdates expectFn }
    ]


{-| Returns the check that runs `expectFn` on a module whose `testValue` binds
`r = { x = 10, y = 20 }` in a `let` and returns `{ r | x = 100 }`.
-}
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


{-| Returns the check that runs `expectFn` on a module whose `testValue` binds
`r = { x = 10, y = 20, z = 30 }` in a `let` and returns
`{ r | x = 100, z = 300 }`.
-}
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


{-| Returns the check that runs `expectFn` on a module whose `testValue` binds
`r = { x = 1, y = 2 }` and `r2 = { r | x = 10 }` in one `let` and returns
`{ r2 | y = 20 }`.
-}
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
