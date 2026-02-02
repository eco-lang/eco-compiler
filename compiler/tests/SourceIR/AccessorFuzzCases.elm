module SourceIR.AccessorFuzzCases exposing (expectSuite)

{-| Fuzz tests for accessor function handling.

These tests stress the compiler's handling of .field accessor syntax by generating:

1.  Accessors as first-class functions passed to higher-order functions
2.  Chained field access (record.a.b.c)
3.  Records with varying numbers of fields
4.  Accessor expressions in various contexts

The goal is to find edge cases in how the compiler handles accessor
functions, particularly when they're used in complex ways.

-}

import Compiler.AST.Source as Src
import Compiler.AST.SourceBuilder as B exposing (makeModule)
import Compiler.Data.Name exposing (Name)
import Expect exposing (Expectation)
import Fuzz exposing (Fuzzer)
import SourceIR.Fuzz.TypedExpr as TE
    exposing
        ( Scope
        , SimpleType(..)
        , decrementDepth
        , emptyScope
        , nameFuzzer
        )
import Test exposing (Test)



-- =============================================================================
-- TEST SUITE
-- =============================================================================


expectSuite : (Src.Module -> Expectation) -> String -> Test
expectSuite expectFn condStr =
    Test.describe ("Accessor fuzz tests " ++ condStr)
        [ accessorAsFirstClassTests expectFn condStr
        , chainedAccessTests expectFn condStr
        , multiFieldRecordTests expectFn condStr
        ]



-- =============================================================================
-- ACCESSOR AS FIRST-CLASS FUNCTION TESTS
-- =============================================================================


accessorAsFirstClassTests : (Src.Module -> Expectation) -> String -> Test
accessorAsFirstClassTests expectFn condStr =
    Test.describe ("Accessor as first-class function " ++ condStr)
        [ Test.fuzz (accessorWithMapFuzzer (emptyScope 2))
            ("Accessor with List.map " ++ condStr)
            (\expr -> expectFn (makeModule "testValue" expr))
        , Test.fuzz (accessorInPipelineFuzzer (emptyScope 2))
            ("Accessor in pipeline " ++ condStr)
            (\expr -> expectFn (makeModule "testValue" expr))
        , Test.fuzz (accessorPassedToFunctionFuzzer (emptyScope 2))
            ("Accessor passed to function " ++ condStr)
            (\expr -> expectFn (makeModule "testValue" expr))
        ]


{-| Generate: List.map .fieldName [ { fieldName = value }, ... ]
-}
accessorWithMapFuzzer : Scope -> Fuzzer Src.Expr
accessorWithMapFuzzer scope =
    fieldNameFuzzer
        |> Fuzz.andThen
            (\fieldName ->
                Fuzz.intRange 1 3
                    |> Fuzz.andThen
                        (\listLen ->
                            Fuzz.listOfLength listLen (recordWithFieldFuzzer (decrementDepth scope) fieldName TInt)
                                |> Fuzz.map
                                    (\records ->
                                        -- List.map .fieldName [ records... ]
                                        B.callExpr
                                            (B.qualVarExpr "List" "map")
                                            [ B.accessorExpr fieldName
                                            , B.listExpr records
                                            ]
                                    )
                        )
            )


{-| Generate: records |> List.map .field |> List.head
Accessor used in pipeline context.
-}
accessorInPipelineFuzzer : Scope -> Fuzzer Src.Expr
accessorInPipelineFuzzer scope =
    fieldNameFuzzer
        |> Fuzz.andThen
            (\fieldName ->
                Fuzz.intRange 1 3
                    |> Fuzz.andThen
                        (\listLen ->
                            Fuzz.listOfLength listLen (recordWithFieldFuzzer (decrementDepth scope) fieldName TInt)
                                |> Fuzz.map
                                    (\records ->
                                        -- [ records ] |> List.map .field
                                        let
                                            recordList =
                                                B.listExpr records

                                            mapCall =
                                                B.callExpr
                                                    (B.qualVarExpr "List" "map")
                                                    [ B.accessorExpr fieldName ]
                                        in
                                        B.binopsExpr
                                            [ ( recordList, "|>" ) ]
                                            mapCall
                                    )
                        )
            )


{-| Generate: applyToField .fieldName record
Accessor passed directly to a helper function.
-}
accessorPassedToFunctionFuzzer : Scope -> Fuzzer Src.Expr
accessorPassedToFunctionFuzzer scope =
    fieldNameFuzzer
        |> Fuzz.andThen
            (\fieldName ->
                recordWithFieldFuzzer (decrementDepth scope) fieldName TInt
                    |> Fuzz.map
                        (\record ->
                            -- Create a let expression that defines a function taking an accessor
                            -- let
                            --     applyAccessor f r = f r
                            -- in
                            -- applyAccessor .fieldName record
                            let
                                accessorParam =
                                    B.pVar "f"

                                recordParam =
                                    B.pVar "r"

                                helperBody =
                                    B.callExpr (B.varExpr "f") [ B.varExpr "r" ]

                                helperDef =
                                    B.define "applyAccessor" [ accessorParam, recordParam ] helperBody

                                mainCall =
                                    B.callExpr
                                        (B.varExpr "applyAccessor")
                                        [ B.accessorExpr fieldName, record ]
                            in
                            B.letExpr [ helperDef ] mainCall
                        )
            )



-- =============================================================================
-- CHAINED FIELD ACCESS TESTS
-- =============================================================================


chainedAccessTests : (Src.Module -> Expectation) -> String -> Test
chainedAccessTests expectFn condStr =
    Test.describe ("Chained field access " ++ condStr)
        [ Test.fuzz (twoLevelAccessFuzzer (emptyScope 2))
            ("Two-level chained access " ++ condStr)
            (\expr -> expectFn (makeModule "testValue" expr))
        , Test.fuzz (threeLevelAccessFuzzer (emptyScope 2))
            ("Three-level chained access " ++ condStr)
            (\expr -> expectFn (makeModule "testValue" expr))
        ]


{-| Generate: record.outer.inner
-}
twoLevelAccessFuzzer : Scope -> Fuzzer Src.Expr
twoLevelAccessFuzzer scope =
    Fuzz.map2
        (\outerField innerField ->
            let
                -- Create { outer = { inner = 42 } }
                innerRecord =
                    B.recordExpr [ ( innerField, B.intExpr 42 ) ]

                outerRecord =
                    B.recordExpr [ ( outerField, innerRecord ) ]
            in
            -- outerRecord.outer.inner
            B.accessExpr
                (B.accessExpr outerRecord outerField)
                innerField
        )
        fieldNameFuzzer
        fieldNameFuzzer


{-| Generate: record.a.b.c
-}
threeLevelAccessFuzzer : Scope -> Fuzzer Src.Expr
threeLevelAccessFuzzer scope =
    Fuzz.map3
        (\fieldA fieldB fieldC ->
            let
                -- Create { a = { b = { c = 42 } } }
                cRecord =
                    B.recordExpr [ ( fieldC, B.intExpr 42 ) ]

                bRecord =
                    B.recordExpr [ ( fieldB, cRecord ) ]

                aRecord =
                    B.recordExpr [ ( fieldA, bRecord ) ]
            in
            -- aRecord.a.b.c
            B.accessExpr
                (B.accessExpr
                    (B.accessExpr aRecord fieldA)
                    fieldB
                )
                fieldC
        )
        fieldNameFuzzer
        fieldNameFuzzer
        fieldNameFuzzer



-- =============================================================================
-- MULTI-FIELD RECORD TESTS
-- =============================================================================


multiFieldRecordTests : (Src.Module -> Expectation) -> String -> Test
multiFieldRecordTests expectFn condStr =
    Test.describe ("Multi-field record access " ++ condStr)
        [ Test.fuzz (manyFieldAccessFuzzer (emptyScope 2))
            ("Access on record with many fields " ++ condStr)
            (\expr -> expectFn (makeModule "testValue" expr))
        , Test.fuzz (multipleAccessorsFuzzer (emptyScope 2))
            ("Multiple accessors on same record " ++ condStr)
            (\expr -> expectFn (makeModule "testValue" expr))
        ]


{-| Generate: record.fieldN where record has 5-8 fields
Tests accessor lookup in records with many fields.
-}
manyFieldAccessFuzzer : Scope -> Fuzzer Src.Expr
manyFieldAccessFuzzer scope =
    Fuzz.intRange 5 8
        |> Fuzz.andThen
            (\fieldCount ->
                generateFieldNames fieldCount
                    |> Fuzz.andThen
                        (\fieldNames ->
                            -- Pick a random field to access
                            Fuzz.intRange 0 (fieldCount - 1)
                                |> Fuzz.andThen
                                    (\targetIdx ->
                                        let
                                            targetField =
                                                List.head (List.drop targetIdx fieldNames)
                                                    |> Maybe.withDefault "x"

                                            fields =
                                                List.indexedMap
                                                    (\i name -> ( name, B.intExpr i ))
                                                    fieldNames

                                            record =
                                                B.recordExpr fields
                                        in
                                        Fuzz.constant (B.accessExpr record targetField)
                                    )
                        )
            )


{-| Generate: (record.a, record.b, record.c)
Multiple accessor expressions on the same record.
-}
multipleAccessorsFuzzer : Scope -> Fuzzer Src.Expr
multipleAccessorsFuzzer _ =
    -- Use fixed distinct field names to avoid duplicates
    let
        fieldA =
            "alpha"

        fieldB =
            "beta"

        fieldC =
            "gamma"

        record =
            B.recordExpr
                [ ( fieldA, B.intExpr 1 )
                , ( fieldB, B.strExpr "hello" )
                , ( fieldC, B.boolExpr True )
                ]

        recordVar =
            B.varExpr "r"
    in
    Fuzz.constant
        (B.letExpr
            [ B.define "r" [] record ]
            (B.tuple3Expr
                (B.accessExpr recordVar fieldA)
                (B.accessExpr recordVar fieldB)
                (B.accessExpr recordVar fieldC)
            )
        )



-- =============================================================================
-- HELPER FUNCTIONS
-- =============================================================================


{-| Generate a valid Elm field name.
-}
fieldNameFuzzer : Fuzzer Name
fieldNameFuzzer =
    Fuzz.oneOfValues
        [ "x"
        , "y"
        , "z"
        , "name"
        , "value"
        , "data"
        , "item"
        , "first"
        , "second"
        , "inner"
        , "outer"
        , "field"
        ]


{-| Generate a list of unique field names.
-}
generateFieldNames : Int -> Fuzzer (List Name)
generateFieldNames count =
    let
        baseNames =
            [ "a", "b", "c", "d", "e", "f", "g", "h", "i", "j" ]
    in
    Fuzz.constant (List.take count baseNames)


{-| Generate a record expression with the specified field.
All records in a list must have the same shape, so we don't add extra fields.
-}
recordWithFieldFuzzer : Scope -> Name -> SimpleType -> Fuzzer Src.Expr
recordWithFieldFuzzer scope fieldName fieldType =
    TE.exprFuzzerForType (decrementDepth scope) fieldType
        |> Fuzz.map
            (\fieldValue ->
                B.recordExpr [ ( fieldName, fieldValue ) ]
            )
