module SourceIR.SpecializeAccessorCases exposing (expectSuite, suite, testCases)

{-| Test cases for accessor specialization in Specialize.elm.

These tests cover:

  - MONO\_015: Accessor extension variable unification at call sites
  - Accessors passed to higher-order functions (List.map, List.filter, etc.)
  - Accessor specialization for different record types
  - Virtual global generation for accessors

-}

import Compiler.AST.Source as Src
import Compiler.AST.SourceBuilder
    exposing
        ( AliasDef
        , TypedDef
        , accessExpr
        , accessorExpr
        , binopsExpr
        , boolExpr
        , callExpr
        , define
        , intExpr
        , lambdaExpr
        , letExpr
        , listExpr
        , makeModuleWithTypedDefsUnionsAliases
        , pVar
        , qualVarExpr
        , recordExpr
        , strExpr
        , tLambda
        , tRecord
        , tType
        , varExpr
        )
import Compiler.BulkCheck exposing (TestCase, bulkCheck)
import Expect exposing (Expectation)
import Test exposing (Test)
import TestLogic.TestPipeline exposing (expectMonomorphization)


suite : Test
suite =
    Test.describe "Accessor specialization coverage"
        [ expectSuite expectMonomorphization "monomorphizes accessors"
        ]


{-| Test suite that can be used with different expectation functions.
-}
expectSuite : (Src.Module -> Expectation) -> String -> Test
expectSuite expectFn condStr =
    Test.test ("Accessor specialization " ++ condStr) <|
        \_ -> bulkCheck (testCases expectFn)


testCases : (Src.Module -> Expectation) -> List TestCase
testCases expectFn =
    List.concat
        [ accessorToMapCases expectFn
        , accessorToFilterCases expectFn
        , accessorToFoldCases expectFn
        , accessorExtensionVariableCases expectFn
        , accessorPolymorphicCases expectFn
        ]



-- ============================================================================
-- ACCESSOR TO LIST.MAP TESTS
-- ============================================================================


accessorToMapCases : (Src.Module -> Expectation) -> List TestCase
accessorToMapCases expectFn =
    [ { label = "List.map .name records", run = mapAccessorOnRecords expectFn }
    , { label = "List.map .value on different field type", run = mapAccessorDifferentFieldType expectFn }
    , { label = "Multiple map with different accessors", run = multipleMapWithDifferentAccessors expectFn }
    ]


{-| List.map .name records - basic accessor as function.
Tests MONO\_015: Accessor extension variable unification.
-}
mapAccessorOnRecords : (Src.Module -> Expectation) -> (() -> Expectation)
mapAccessorOnRecords expectFn _ =
    let
        personAlias : AliasDef
        personAlias =
            { name = "Person"
            , args = []
            , tipe = tRecord [ ( "name", tType "String" [] ), ( "age", tType "Int" [] ) ]
            }

        -- getNames : List Person -> List String
        getNamesDef : TypedDef
        getNamesDef =
            { name = "getNames"
            , args = [ pVar "people" ]
            , tipe = tLambda (tType "List" [ tType "Person" [] ]) (tType "List" [ tType "String" [] ])
            , body = callExpr (qualVarExpr "List" "map") [ accessorExpr "name", varExpr "people" ]
            }

        testValueDef : TypedDef
        testValueDef =
            { name = "testValue"
            , args = []
            , tipe = tType "List" [ tType "String" [] ]
            , body =
                callExpr (varExpr "getNames")
                    [ listExpr
                        [ recordExpr [ ( "name", strExpr "Alice" ), ( "age", intExpr 30 ) ]
                        , recordExpr [ ( "name", strExpr "Bob" ), ( "age", intExpr 25 ) ]
                        ]
                    ]
            }

        modul =
            makeModuleWithTypedDefsUnionsAliases "Test"
                [ getNamesDef, testValueDef ]
                []
                [ personAlias ]
    in
    expectFn modul


{-| List.map .value where value has a different type (Int).
-}
mapAccessorDifferentFieldType : (Src.Module -> Expectation) -> (() -> Expectation)
mapAccessorDifferentFieldType expectFn _ =
    let
        itemAlias : AliasDef
        itemAlias =
            { name = "Item"
            , args = []
            , tipe = tRecord [ ( "id", tType "Int" [] ), ( "value", tType "Int" [] ) ]
            }

        -- getValues : List Item -> List Int
        getValuesDef : TypedDef
        getValuesDef =
            { name = "getValues"
            , args = [ pVar "items" ]
            , tipe = tLambda (tType "List" [ tType "Item" [] ]) (tType "List" [ tType "Int" [] ])
            , body = callExpr (qualVarExpr "List" "map") [ accessorExpr "value", varExpr "items" ]
            }

        testValueDef : TypedDef
        testValueDef =
            { name = "testValue"
            , args = []
            , tipe = tType "List" [ tType "Int" [] ]
            , body =
                callExpr (varExpr "getValues")
                    [ listExpr
                        [ recordExpr [ ( "id", intExpr 1 ), ( "value", intExpr 100 ) ]
                        , recordExpr [ ( "id", intExpr 2 ), ( "value", intExpr 200 ) ]
                        ]
                    ]
            }

        modul =
            makeModuleWithTypedDefsUnionsAliases "Test"
                [ getValuesDef, testValueDef ]
                []
                [ itemAlias ]
    in
    expectFn modul


{-| Multiple List.map calls with different accessors on same type.
Tests that each accessor gets its own virtual global.
-}
multipleMapWithDifferentAccessors : (Src.Module -> Expectation) -> (() -> Expectation)
multipleMapWithDifferentAccessors expectFn _ =
    let
        personAlias : AliasDef
        personAlias =
            { name = "Person"
            , args = []
            , tipe = tRecord [ ( "name", tType "String" [] ), ( "age", tType "Int" [] ) ]
            }

        -- Both accessors applied to same list
        testValueDef : TypedDef
        testValueDef =
            { name = "testValue"
            , args = []
            , tipe = tType "Int" []
            , body =
                letExpr
                    [ define "people"
                        []
                        (listExpr
                            [ recordExpr [ ( "name", strExpr "Alice" ), ( "age", intExpr 30 ) ]
                            , recordExpr [ ( "name", strExpr "Bob" ), ( "age", intExpr 25 ) ]
                            ]
                        )
                    , define "names"
                        []
                        (callExpr (qualVarExpr "List" "map") [ accessorExpr "name", varExpr "people" ])
                    , define "ages"
                        []
                        (callExpr (qualVarExpr "List" "map") [ accessorExpr "age", varExpr "people" ])
                    ]
                    -- Return something based on both
                    (callExpr (qualVarExpr "List" "length") [ varExpr "ages" ])
            }

        modul =
            makeModuleWithTypedDefsUnionsAliases "Test"
                [ testValueDef ]
                []
                [ personAlias ]
    in
    expectFn modul



-- ============================================================================
-- ACCESSOR TO LIST.FILTER TESTS
-- ============================================================================


accessorToFilterCases : (Src.Module -> Expectation) -> List TestCase
accessorToFilterCases expectFn =
    [ { label = "Accessor assigned to variable", run = accessorAssignedToVariable expectFn }
    , { label = "Accessor in nested let", run = accessorInNestedLet expectFn }
    ]


{-| Accessor assigned to a variable and then used.
-}
accessorAssignedToVariable : (Src.Module -> Expectation) -> (() -> Expectation)
accessorAssignedToVariable expectFn _ =
    let
        itemAlias : AliasDef
        itemAlias =
            { name = "Item"
            , args = []
            , tipe = tRecord [ ( "value", tType "Int" [] ), ( "label", tType "String" [] ) ]
            }

        -- getValue : Item -> Int
        getValueDef : TypedDef
        getValueDef =
            { name = "getValue"
            , args = [ pVar "item" ]
            , tipe = tLambda (tType "Item" []) (tType "Int" [])
            , body =
                letExpr
                    [ define "accessor" [] (accessorExpr "value")
                    ]
                    (callExpr (varExpr "accessor") [ varExpr "item" ])
            }

        testValueDef : TypedDef
        testValueDef =
            { name = "testValue"
            , args = []
            , tipe = tType "Int" []
            , body =
                callExpr (varExpr "getValue")
                    [ recordExpr [ ( "value", intExpr 42 ), ( "label", strExpr "test" ) ]
                    ]
            }

        modul =
            makeModuleWithTypedDefsUnionsAliases "Test"
                [ getValueDef, testValueDef ]
                []
                [ itemAlias ]
    in
    expectFn modul


{-| Accessor used in nested let binding.
-}
accessorInNestedLet : (Src.Module -> Expectation) -> (() -> Expectation)
accessorInNestedLet expectFn _ =
    let
        itemAlias : AliasDef
        itemAlias =
            { name = "Item"
            , args = []
            , tipe = tRecord [ ( "x", tType "Int" [] ), ( "y", tType "Int" [] ) ]
            }

        -- sumXY : Item -> Int
        sumXYDef : TypedDef
        sumXYDef =
            { name = "sumXY"
            , args = [ pVar "item" ]
            , tipe = tLambda (tType "Item" []) (tType "Int" [])
            , body =
                letExpr
                    [ define "getX" [] (accessorExpr "x")
                    , define "getY" [] (accessorExpr "y")
                    ]
                    (binopsExpr
                        [ ( callExpr (varExpr "getX") [ varExpr "item" ], "+" ) ]
                        (callExpr (varExpr "getY") [ varExpr "item" ])
                    )
            }

        testValueDef : TypedDef
        testValueDef =
            { name = "testValue"
            , args = []
            , tipe = tType "Int" []
            , body =
                callExpr (varExpr "sumXY")
                    [ recordExpr [ ( "x", intExpr 10 ), ( "y", intExpr 20 ) ]
                    ]
            }

        modul =
            makeModuleWithTypedDefsUnionsAliases "Test"
                [ sumXYDef, testValueDef ]
                []
                [ itemAlias ]
    in
    expectFn modul



-- ============================================================================
-- ACCESSOR TO FOLD TESTS
-- ============================================================================


accessorToFoldCases : (Src.Module -> Expectation) -> List TestCase
accessorToFoldCases expectFn =
    [ { label = "Accessor in foldl accumulator", run = accessorInFoldAccumulator expectFn }
    ]


{-| Using accessor in a fold to sum a field.
-}
accessorInFoldAccumulator : (Src.Module -> Expectation) -> (() -> Expectation)
accessorInFoldAccumulator expectFn _ =
    let
        itemAlias : AliasDef
        itemAlias =
            { name = "Item"
            , args = []
            , tipe = tRecord [ ( "amount", tType "Int" [] ) ]
            }

        -- sumAmounts : List Item -> Int
        sumAmountsDef : TypedDef
        sumAmountsDef =
            { name = "sumAmounts"
            , args = [ pVar "items" ]
            , tipe = tLambda (tType "List" [ tType "Item" [] ]) (tType "Int" [])
            , body =
                callExpr (qualVarExpr "List" "foldl")
                    [ lambdaExpr [ pVar "item", pVar "acc" ]
                        (binopsExpr [ ( accessExpr (varExpr "item") "amount", "+" ) ] (varExpr "acc"))
                    , intExpr 0
                    , varExpr "items"
                    ]
            }

        testValueDef : TypedDef
        testValueDef =
            { name = "testValue"
            , args = []
            , tipe = tType "Int" []
            , body =
                callExpr (varExpr "sumAmounts")
                    [ listExpr
                        [ recordExpr [ ( "amount", intExpr 10 ) ]
                        , recordExpr [ ( "amount", intExpr 20 ) ]
                        , recordExpr [ ( "amount", intExpr 30 ) ]
                        ]
                    ]
            }

        modul =
            makeModuleWithTypedDefsUnionsAliases "Test"
                [ sumAmountsDef, testValueDef ]
                []
                [ itemAlias ]
    in
    expectFn modul



-- ============================================================================
-- ACCESSOR EXTENSION VARIABLE TESTS
-- ============================================================================


accessorExtensionVariableCases : (Src.Module -> Expectation) -> List TestCase
accessorExtensionVariableCases expectFn =
    [ { label = "Accessor on record with extra fields", run = accessorOnRecordWithExtraFields expectFn }
    , { label = "Same accessor on different record types", run = sameAccessorDifferentRecordTypes expectFn }
    ]


{-| Accessor applied to record with more fields than accessor needs.
Tests extension variable unification.
-}
accessorOnRecordWithExtraFields : (Src.Module -> Expectation) -> (() -> Expectation)
accessorOnRecordWithExtraFields expectFn _ =
    let
        -- bigRecord has many fields, accessor only needs one
        bigRecordAlias : AliasDef
        bigRecordAlias =
            { name = "BigRecord"
            , args = []
            , tipe =
                tRecord
                    [ ( "name", tType "String" [] )
                    , ( "age", tType "Int" [] )
                    , ( "email", tType "String" [] )
                    , ( "active", tType "Bool" [] )
                    ]
            }

        -- getName : BigRecord -> String (using .name accessor)
        getNameDef : TypedDef
        getNameDef =
            { name = "getName"
            , args = [ pVar "rec" ]
            , tipe = tLambda (tType "BigRecord" []) (tType "String" [])
            , body = accessExpr (varExpr "rec") "name"
            }

        -- getNames using accessor function
        getNamesDef : TypedDef
        getNamesDef =
            { name = "getNames"
            , args = [ pVar "recs" ]
            , tipe = tLambda (tType "List" [ tType "BigRecord" [] ]) (tType "List" [ tType "String" [] ])
            , body = callExpr (qualVarExpr "List" "map") [ accessorExpr "name", varExpr "recs" ]
            }

        testValueDef : TypedDef
        testValueDef =
            { name = "testValue"
            , args = []
            , tipe = tType "List" [ tType "String" [] ]
            , body =
                callExpr (varExpr "getNames")
                    [ listExpr
                        [ recordExpr
                            [ ( "name", strExpr "Alice" )
                            , ( "age", intExpr 30 )
                            , ( "email", strExpr "alice@example.com" )
                            , ( "active", boolExpr True )
                            ]
                        ]
                    ]
            }

        modul =
            makeModuleWithTypedDefsUnionsAliases "Test"
                [ getNameDef, getNamesDef, testValueDef ]
                []
                [ bigRecordAlias ]
    in
    expectFn modul


{-| Same accessor (.name) applied to different record types.
Tests that separate specializations are created.
-}
sameAccessorDifferentRecordTypes : (Src.Module -> Expectation) -> (() -> Expectation)
sameAccessorDifferentRecordTypes expectFn _ =
    let
        personAlias : AliasDef
        personAlias =
            { name = "Person"
            , args = []
            , tipe = tRecord [ ( "name", tType "String" [] ), ( "age", tType "Int" [] ) ]
            }

        companyAlias : AliasDef
        companyAlias =
            { name = "Company"
            , args = []
            , tipe = tRecord [ ( "name", tType "String" [] ), ( "employees", tType "Int" [] ) ]
            }

        -- getPersonNames : List Person -> List String
        getPersonNamesDef : TypedDef
        getPersonNamesDef =
            { name = "getPersonNames"
            , args = [ pVar "people" ]
            , tipe = tLambda (tType "List" [ tType "Person" [] ]) (tType "List" [ tType "String" [] ])
            , body = callExpr (qualVarExpr "List" "map") [ accessorExpr "name", varExpr "people" ]
            }

        -- getCompanyNames : List Company -> List String
        getCompanyNamesDef : TypedDef
        getCompanyNamesDef =
            { name = "getCompanyNames"
            , args = [ pVar "companies" ]
            , tipe = tLambda (tType "List" [ tType "Company" [] ]) (tType "List" [ tType "String" [] ])
            , body = callExpr (qualVarExpr "List" "map") [ accessorExpr "name", varExpr "companies" ]
            }

        testValueDef : TypedDef
        testValueDef =
            { name = "testValue"
            , args = []
            , tipe = tType "Int" []
            , body =
                letExpr
                    [ define "personNames"
                        []
                        (callExpr (varExpr "getPersonNames")
                            [ listExpr [ recordExpr [ ( "name", strExpr "Alice" ), ( "age", intExpr 30 ) ] ] ]
                        )
                    , define "companyNames"
                        []
                        (callExpr (varExpr "getCompanyNames")
                            [ listExpr [ recordExpr [ ( "name", strExpr "ACME" ), ( "employees", intExpr 100 ) ] ] ]
                        )
                    ]
                    (binopsExpr
                        [ ( callExpr (qualVarExpr "List" "length") [ varExpr "personNames" ], "+" ) ]
                        (callExpr (qualVarExpr "List" "length") [ varExpr "companyNames" ])
                    )
            }

        modul =
            makeModuleWithTypedDefsUnionsAliases "Test"
                [ getPersonNamesDef, getCompanyNamesDef, testValueDef ]
                []
                [ personAlias, companyAlias ]
    in
    expectFn modul



-- ============================================================================
-- POLYMORPHIC ACCESSOR TESTS
-- ============================================================================


accessorPolymorphicCases : (Src.Module -> Expectation) -> List TestCase
accessorPolymorphicCases expectFn =
    [ { label = "Generic function using accessor", run = genericFunctionUsingAccessor expectFn }
    ]


{-| Generic function that uses an accessor.
Tests polymorphic accessor instantiation.
-}
genericFunctionUsingAccessor : (Src.Module -> Expectation) -> (() -> Expectation)
genericFunctionUsingAccessor expectFn _ =
    let
        itemAlias : AliasDef
        itemAlias =
            { name = "Item"
            , args = []
            , tipe = tRecord [ ( "id", tType "Int" [] ), ( "label", tType "String" [] ) ]
            }

        -- countIds : List Item -> Int
        countIdsDef : TypedDef
        countIdsDef =
            { name = "countIds"
            , args = [ pVar "items" ]
            , tipe = tLambda (tType "List" [ tType "Item" [] ]) (tType "Int" [])
            , body =
                callExpr (qualVarExpr "List" "length")
                    [ callExpr (qualVarExpr "List" "map") [ accessorExpr "id", varExpr "items" ]
                    ]
            }

        testValueDef : TypedDef
        testValueDef =
            { name = "testValue"
            , args = []
            , tipe = tType "Int" []
            , body =
                callExpr (varExpr "countIds")
                    [ listExpr
                        [ recordExpr [ ( "id", intExpr 1 ), ( "label", strExpr "A" ) ]
                        , recordExpr [ ( "id", intExpr 2 ), ( "label", strExpr "B" ) ]
                        ]
                    ]
            }

        modul =
            makeModuleWithTypedDefsUnionsAliases "Test"
                [ countIdsDef, testValueDef ]
                []
                [ itemAlias ]
    in
    expectFn modul
