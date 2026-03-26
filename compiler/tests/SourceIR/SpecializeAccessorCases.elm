module SourceIR.SpecializeAccessorCases exposing (expectSuite, suite)

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
        , UnionCtor
        , UnionDef
        , accessExpr
        , accessorExpr
        , binopsExpr
        , boolExpr
        , callExpr
        , caseExpr
        , ctorExpr
        , define
        , destruct
        , intExpr
        , lambdaExpr
        , letExpr
        , listExpr
        , makeModuleWithTypedDefsUnionsAliases
        , pCtor
        , pTuple
        , pVar
        , qualVarExpr
        , recordExpr
        , strExpr
        , tLambda
        , tRecord
        , tTuple
        , tType
        , tupleExpr
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
        , accessorViaCaseCases expectFn
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



-- ============================================================================
-- ACCESSOR VIA CASE EXPRESSION TESTS
-- ============================================================================


accessorViaCaseCases : (Src.Module -> Expectation) -> List TestCase
accessorViaCaseCases expectFn =
    [ { label = "Accessor selected via case, stored in tuple", run = accessorCaseTuple expectFn }
    , { label = "Accessor selected via case, applied immediately", run = accessorCaseApplied expectFn }
    , { label = "Accessor selected via case, passed to HOF", run = accessorCaseToHof expectFn }
    , { label = "Accessor in case with mixed field types", run = accessorCaseMixedTypes expectFn }
    , { label = "Accessor stored in record field", run = accessorInRecordField expectFn }
    , { label = "Accessor selected via nested case", run = accessorNestedCase expectFn }
    ]


{-| Accessor selected via case expression, stored in a tuple.
Derived from LetDestructFuncTupleTest. Tests MONO\_015: the accessor .a must be
specialized knowing the full record type { a : Int, b : Int } so field a is Int.
-}
accessorCaseTuple : (Src.Module -> Expectation) -> (() -> Expectation)
accessorCaseTuple expectFn _ =
    let
        locUnion : UnionDef
        locUnion =
            { name = "Loc"
            , args = []
            , ctors =
                [ { name = "First", args = [] }
                , { name = "Second", args = [] }
                ]
            }

        -- choose : Loc -> { a : Int, b : Int } -> ( Int, Int )
        chooseDef : TypedDef
        chooseDef =
            { name = "choose"
            , args = [ pVar "loc", pVar "rec" ]
            , tipe =
                tLambda (tType "Loc" [])
                    (tLambda (tRecord [ ( "a", tType "Int" [] ), ( "b", tType "Int" [] ) ])
                        (tTuple (tType "Int" []) (tType "Int" []))
                    )
            , body =
                letExpr
                    [ destruct (pTuple (pVar "getter") (pVar "setter"))
                        (caseExpr (varExpr "loc")
                            [ ( pCtor "First" [], tupleExpr (accessorExpr "a") (accessorExpr "b") )
                            , ( pCtor "Second" [], tupleExpr (accessorExpr "b") (accessorExpr "a") )
                            ]
                        )
                    ]
                    (tupleExpr
                        (callExpr (varExpr "getter") [ varExpr "rec" ])
                        (callExpr (varExpr "setter") [ varExpr "rec" ])
                    )
            }

        testValueDef : TypedDef
        testValueDef =
            { name = "testValue"
            , args = []
            , tipe = tTuple (tType "Int" []) (tType "Int" [])
            , body =
                callExpr (varExpr "choose")
                    [ ctorExpr "First"
                    , recordExpr [ ( "a", intExpr 10 ), ( "b", intExpr 20 ) ]
                    ]
            }

        modul =
            makeModuleWithTypedDefsUnionsAliases "Test"
                [ chooseDef, testValueDef ]
                [ locUnion ]
                []
    in
    expectFn modul


{-| Accessor selected via case, applied immediately (no intermediate storage).
-}
accessorCaseApplied : (Src.Module -> Expectation) -> (() -> Expectation)
accessorCaseApplied expectFn _ =
    let
        whichUnion : UnionDef
        whichUnion =
            { name = "Which"
            , args = []
            , ctors =
                [ { name = "UseA", args = [] }
                , { name = "UseB", args = [] }
                ]
            }

        -- getField : Which -> { a : Int, b : Int } -> Int
        getFieldDef : TypedDef
        getFieldDef =
            { name = "getField"
            , args = [ pVar "which", pVar "rec" ]
            , tipe =
                tLambda (tType "Which" [])
                    (tLambda (tRecord [ ( "a", tType "Int" [] ), ( "b", tType "Int" [] ) ])
                        (tType "Int" [])
                    )
            , body =
                caseExpr (varExpr "which")
                    [ ( pCtor "UseA" [], callExpr (accessorExpr "a") [ varExpr "rec" ] )
                    , ( pCtor "UseB" [], callExpr (accessorExpr "b") [ varExpr "rec" ] )
                    ]
            }

        testValueDef : TypedDef
        testValueDef =
            { name = "testValue"
            , args = []
            , tipe = tType "Int" []
            , body =
                callExpr (varExpr "getField")
                    [ ctorExpr "UseA"
                    , recordExpr [ ( "a", intExpr 42 ), ( "b", intExpr 0 ) ]
                    ]
            }

        modul =
            makeModuleWithTypedDefsUnionsAliases "Test"
                [ getFieldDef, testValueDef ]
                [ whichUnion ]
                []
    in
    expectFn modul


{-| Accessor returned from case, then passed to List.map.
-}
accessorCaseToHof : (Src.Module -> Expectation) -> (() -> Expectation)
accessorCaseToHof expectFn _ =
    let
        sortByUnion : UnionDef
        sortByUnion =
            { name = "SortBy"
            , args = []
            , ctors =
                [ { name = "ByName", args = [] }
                , { name = "ByAge", args = [] }
                ]
            }

        personAlias : AliasDef
        personAlias =
            { name = "Person"
            , args = []
            , tipe = tRecord [ ( "name", tType "String" [] ), ( "age", tType "Int" [] ) ]
            }

        -- sortKey : SortBy -> Person -> String
        -- (both branches return String accessor for type consistency)
        sortKeyDef : TypedDef
        sortKeyDef =
            { name = "sortKey"
            , args = [ pVar "sortBy" ]
            , tipe =
                tLambda (tType "SortBy" [])
                    (tLambda (tType "Person" []) (tType "String" []))
            , body =
                caseExpr (varExpr "sortBy")
                    [ ( pCtor "ByName" [], accessorExpr "name" )
                    , ( pCtor "ByAge" [], accessorExpr "name" )
                    ]
            }

        testValueDef : TypedDef
        testValueDef =
            { name = "testValue"
            , args = []
            , tipe = tType "List" [ tType "String" [] ]
            , body =
                callExpr (qualVarExpr "List" "map")
                    [ callExpr (varExpr "sortKey") [ ctorExpr "ByName" ]
                    , listExpr
                        [ recordExpr [ ( "name", strExpr "Alice" ), ( "age", intExpr 30 ) ] ]
                    ]
            }

        modul =
            makeModuleWithTypedDefsUnionsAliases "Test"
                [ sortKeyDef, testValueDef ]
                [ sortByUnion ]
                [ personAlias ]
    in
    expectFn modul


{-| Accessor in case with mixed field types (Int and String).
The case branches return accessors with different concrete return types.
-}
accessorCaseMixedTypes : (Src.Module -> Expectation) -> (() -> Expectation)
accessorCaseMixedTypes expectFn _ =
    let
        fieldUnion : UnionDef
        fieldUnion =
            { name = "Field"
            , args = []
            , ctors =
                [ { name = "IntField", args = [] }
                , { name = "StrField", args = [] }
                ]
            }

        -- pickAccessor : Field -> { count : Int, label : String } -> Int
        pickAccessorDef : TypedDef
        pickAccessorDef =
            { name = "pickAccessor"
            , args = [ pVar "field" ]
            , tipe =
                tLambda (tType "Field" [])
                    (tLambda (tRecord [ ( "count", tType "Int" [] ), ( "label", tType "String" [] ) ]) (tType "Int" []))
            , body =
                caseExpr (varExpr "field")
                    [ ( pCtor "IntField" [], accessorExpr "count" )
                    , ( pCtor "StrField" [], accessorExpr "count" )
                    ]
            }

        testValueDef : TypedDef
        testValueDef =
            { name = "testValue"
            , args = []
            , tipe = tType "Int" []
            , body =
                letExpr
                    [ define "f" [] (callExpr (varExpr "pickAccessor") [ ctorExpr "IntField" ]) ]
                    (callExpr (varExpr "f")
                        [ recordExpr [ ( "count", intExpr 5 ), ( "label", strExpr "hello" ) ] ]
                    )
            }

        modul =
            makeModuleWithTypedDefsUnionsAliases "Test"
                [ pickAccessorDef, testValueDef ]
                [ fieldUnion ]
                []
    in
    expectFn modul


{-| Accessor stored in a record field (not a tuple).
-}
accessorInRecordField : (Src.Module -> Expectation) -> (() -> Expectation)
accessorInRecordField expectFn _ =
    let
        testValueDef : TypedDef
        testValueDef =
            { name = "testValue"
            , args = []
            , tipe = tType "Int" []
            , body =
                letExpr
                    [ define "ops" []
                        (recordExpr
                            [ ( "getter", accessorExpr "a" )
                            ]
                        )
                    ]
                    (callExpr (accessExpr (varExpr "ops") "getter")
                        [ recordExpr [ ( "a", intExpr 10 ), ( "b", intExpr 20 ) ] ]
                    )
            }

        modul =
            makeModuleWithTypedDefsUnionsAliases "Test"
                [ testValueDef ]
                []
                []
    in
    expectFn modul


{-| Accessor selected via nested case expressions.
-}
accessorNestedCase : (Src.Module -> Expectation) -> (() -> Expectation)
accessorNestedCase expectFn _ =
    let
        outerUnion : UnionDef
        outerUnion =
            { name = "Outer"
            , args = []
            , ctors =
                [ { name = "OutA", args = [] }
                , { name = "OutB", args = [] }
                ]
            }

        innerUnion : UnionDef
        innerUnion =
            { name = "Inner"
            , args = []
            , ctors =
                [ { name = "InX", args = [] }
                , { name = "InY", args = [] }
                ]
            }

        -- pickAccessor : Outer -> Inner -> { x : Int, y : Int, z : Int } -> Int
        pickAccessorDef : TypedDef
        pickAccessorDef =
            { name = "pickAccessor"
            , args = [ pVar "outer", pVar "inner" ]
            , tipe =
                tLambda (tType "Outer" [])
                    (tLambda (tType "Inner" [])
                        (tLambda
                            (tRecord [ ( "x", tType "Int" [] ), ( "y", tType "Int" [] ), ( "z", tType "Int" [] ) ])
                            (tType "Int" [])
                        )
                    )
            , body =
                caseExpr (varExpr "outer")
                    [ ( pCtor "OutA" []
                      , caseExpr (varExpr "inner")
                            [ ( pCtor "InX" [], accessorExpr "x" )
                            , ( pCtor "InY" [], accessorExpr "y" )
                            ]
                      )
                    , ( pCtor "OutB" [], accessorExpr "z" )
                    ]
            }

        testValueDef : TypedDef
        testValueDef =
            { name = "testValue"
            , args = []
            , tipe = tType "Int" []
            , body =
                callExpr (varExpr "pickAccessor")
                    [ ctorExpr "OutA"
                    , ctorExpr "InX"
                    , recordExpr [ ( "x", intExpr 1 ), ( "y", intExpr 2 ), ( "z", intExpr 3 ) ]
                    ]
            }

        modul =
            makeModuleWithTypedDefsUnionsAliases "Test"
                [ pickAccessorDef, testValueDef ]
                [ outerUnion, innerUnion ]
                []
    in
    expectFn modul
