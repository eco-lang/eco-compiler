module SourceIR.SpecializeAccessorCases exposing (expectSuite, suite)

{-| Programs in which a record accessor function such as `.name` is used as a
value, for checking whatever property the caller's expectation tests.

An accessor `.field` has the type `{ r | field : a } -> a`: it works on any
record that has `field`, and the extension variable `r` stands for whatever
other fields the record has. To specialise an accessor, monomorphization needs
the full record type it is applied to, so at each use that type has to be
found. In the substitution engine (`Compiler.Monomorphize.Specialize`) an
accessor passed as a call argument takes its record type from the parameter it
is passed for. A standalone accessor, such as one in a tuple or a `case` branch,
is specialised from its own type, or, when that type is not yet a closed record
or the field it reads holds a function, left for
`Compiler.Monomorphize.ResolveAccessorValues`. An accessor specialised by either
of the first two routes becomes a reference to the global `Mono.Accessor field`
at one record type. The programs here put accessors in several of these
positions.

Every program is a module named `Test` built with
`makeModuleWithTypedDefsUnionsAliases`, so every top-level value has an
annotation, and each defines an annotated `testValue`. Every record type named
in an annotation is closed, and no alias or custom type has a type parameter.
Field values are string and integer literals, `Basics.True` in one program,
and in another an accessor; an integer literal is an `Int` only where
something, such as an annotation, fixes it.

`expectSuite expectFn condStr` is a single elm-test test, named
"Accessor specialization " followed by `condStr`, that gives fifteen programs
in turn to `expectFn` and fails with the first it rejects (`Compiler.BulkCheck`).
`expectFn` decides what is checked. `suite` runs the same programs against
`TestLogic.TestPipeline.expectMonomorphization`. The programs, by group:

  - `.name` or `.value` passed to `List.map` inside an annotated function, and
    `.name` and `.age` passed to `List.map` over one let-bound list.
  - One accessor, or two, bound to `let` variables and applied to a record.
  - A field access (`item.amount`, not an accessor) in a lambda passed to
    `List.foldl`.
  - `.name` passed to `List.map` for a record type with four fields, and for
    two record types that both have `name`.
  - `.id` passed to `List.map` whose result is passed to `List.length`.
  - Accessors in `case` branches: returned as a pair that a `let`
    destructures; applied to a record in the branch; returned from a function
    whose partial application is passed to `List.map`, or let-bound and
    applied; and chosen by nested `case`s. Also `.a` stored in a record field
    and called through it.

Among what is not tested: an accessor passed to `List.filter` or any function
other than `List.map`; an accessor in a function annotated with an extensible
record or a type variable; a record type with a type parameter; a record type,
named in an annotation, with a function-typed field. `suite` checks only that
`runToMono` succeeds and gives a graph with a `main` and some nodes; it does not
look at how any accessor was specialised, and it evaluates no program's result.

-}

import Compiler.AST.Source as Src
import Compiler.AST.SourceBuilder
    exposing
        ( AliasDef
        , TypedDef
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


{-| Runs the programs against `TestLogic.TestPipeline.expectMonomorphization`,
which passes when the substitution engine monomorphizes a program to a graph
with a `main` and some nodes.
-}
suite : Test
suite =
    Test.describe "Accessor specialization coverage"
        [ expectSuite expectMonomorphization "monomorphizes accessors"
        ]


{-| Builds one test, named "Accessor specialization " followed by `condStr`,
that applies `expectFn` to each program in turn and fails with the label of the
first program it rejects.
-}
expectSuite : (Src.Module -> Expectation) -> String -> Test
expectSuite expectFn condStr =
    Test.test ("Accessor specialization " ++ condStr) <|
        \_ -> bulkCheck (testCases expectFn)


{-| Returns every labelled case, each applying `expectFn` to its program.
-}
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
-- ACCESSORS PASSED TO LIST.MAP
-- ============================================================================


{-| Returns the cases that pass an accessor to `List.map`.
-}
accessorToMapCases : (Src.Module -> Expectation) -> List TestCase
accessorToMapCases expectFn =
    [ { label = "List.map .name records", run = mapAccessorOnRecords expectFn }
    , { label = "List.map .value on different field type", run = mapAccessorDifferentFieldType expectFn }
    , { label = "Multiple map with different accessors", run = multipleMapWithDifferentAccessors expectFn }
    ]


{-| Applies `expectFn` to a program that maps `.name` over a list of records,
inside a function annotated with the record's alias:

    type alias Person =
        { name : String, age : Int }

    getNames : List Person -> List String
    getNames people =
        List.map .name people

    testValue : List String
    testValue =
        getNames [ { name = "Alice", age = 30 }, { name = "Bob", age = 25 } ]

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


{-| Applies `expectFn` to a program that maps `.value`, an `Int` field, over a
list of records:

    type alias Item =
        { id : Int, value : Int }

    getValues : List Item -> List Int
    getValues items =
        List.map .value items

    testValue : List Int
    testValue =
        getValues [ { id = 1, value = 100 }, { id = 2, value = 200 } ]

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


{-| Applies `expectFn` to a program that maps two accessors over the same
let-bound list:

    type alias Person =
        { name : String, age : Int }

    testValue : Int
    testValue =
        let
            people =
                [ { name = "Alice", age = 30 }, { name = "Bob", age = 25 } ]

            names =
                List.map .name people

            ages =
                List.map .age people
        in
        List.length ages

`names` is not used, and no annotation names `Person`, so nothing fixes the
`age` literals to `Int`.

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
-- ACCESSORS BOUND IN LET
-- ============================================================================


{-| Returns the cases that bind an accessor to a `let` variable and apply the
variable to a record.
-}
accessorToFilterCases : (Src.Module -> Expectation) -> List TestCase
accessorToFilterCases expectFn =
    [ { label = "Accessor assigned to variable", run = accessorAssignedToVariable expectFn }
    , { label = "Accessor in nested let", run = accessorInNestedLet expectFn }
    ]


{-| Applies `expectFn` to a program that binds `.value` to a local variable and
applies it:

    type alias Item =
        { value : Int, label : String }

    getValue : Item -> Int
    getValue item =
        let
            accessor =
                .value
        in
        accessor item

    testValue : Int
    testValue =
        getValue { value = 42, label = "test" }

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


{-| Applies `expectFn` to a program that binds two accessors in one `let` and
adds their results. The `let` is not nested, whatever the case's label says:

    type alias Item =
        { x : Int, y : Int }

    sumXY : Item -> Int
    sumXY item =
        let
            getX =
                .x

            getY =
                .y
        in
        getX item + getY item

    testValue : Int
    testValue =
        sumXY { x = 10, y = 20 }

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
-- FIELD ACCESS IN A FOLD
-- ============================================================================


{-| Returns the case that reads a field inside a lambda passed to `List.foldl`.
-}
accessorToFoldCases : (Src.Module -> Expectation) -> List TestCase
accessorToFoldCases expectFn =
    [ { label = "Accessor in foldl accumulator", run = accessorInFoldAccumulator expectFn }
    ]


{-| Applies `expectFn` to a program that sums a field with `List.foldl`. It
reads the field with `item.amount` and has no accessor function:

    type alias Item =
        { amount : Int }

    sumAmounts : List Item -> Int
    sumAmounts items =
        List.foldl (\item acc -> item.amount + acc) 0 items

    testValue : Int
    testValue =
        sumAmounts [ { amount = 10 }, { amount = 20 }, { amount = 30 } ]

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
-- ONE ACCESSOR, LARGER OR SEVERAL RECORD TYPES
-- ============================================================================


{-| Returns the cases in which `.name`'s extension variable must stand for
fields besides `name`: three more fields in one record type, or different
fields in two.
-}
accessorExtensionVariableCases : (Src.Module -> Expectation) -> List TestCase
accessorExtensionVariableCases expectFn =
    [ { label = "Accessor on record with extra fields", run = accessorOnRecordWithExtraFields expectFn }
    , { label = "Same accessor on different record types", run = sameAccessorDifferentRecordTypes expectFn }
    ]


{-| Applies `expectFn` to a program that maps `.name` over records with three
other fields:

    type alias BigRecord =
        { name : String, age : Int, email : String, active : Bool }

    getName : BigRecord -> String
    getName rec =
        rec.name

    getNames : List BigRecord -> List String
    getNames recs =
        List.map .name recs

    testValue : List String
    testValue =
        getNames [ { name = "Alice", age = 30, email = "alice@example.com", active = True } ]

`getName` uses field access, not an accessor, and `testValue` does not use it.

-}
accessorOnRecordWithExtraFields : (Src.Module -> Expectation) -> (() -> Expectation)
accessorOnRecordWithExtraFields expectFn _ =
    let
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

        getNameDef : TypedDef
        getNameDef =
            { name = "getName"
            , args = [ pVar "rec" ]
            , tipe = tLambda (tType "BigRecord" []) (tType "String" [])
            , body = accessExpr (varExpr "rec") "name"
            }

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


{-| Applies `expectFn` to a program that maps `.name` over lists of two
different record types:

    type alias Person =
        { name : String, age : Int }

    type alias Company =
        { name : String, employees : Int }

    getPersonNames : List Person -> List String
    getPersonNames people =
        List.map .name people

    getCompanyNames : List Company -> List String
    getCompanyNames companies =
        List.map .name companies

    testValue : Int
    testValue =
        let
            personNames =
                getPersonNames [ { name = "Alice", age = 30 } ]

            companyNames =
                getCompanyNames [ { name = "ACME", employees = 100 } ]
        in
        List.length personNames + List.length companyNames

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

        getPersonNamesDef : TypedDef
        getPersonNamesDef =
            { name = "getPersonNames"
            , args = [ pVar "people" ]
            , tipe = tLambda (tType "List" [ tType "Person" [] ]) (tType "List" [ tType "String" [] ])
            , body = callExpr (qualVarExpr "List" "map") [ accessorExpr "name", varExpr "people" ]
            }

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
-- MAPPED ACCESSOR UNDER ANOTHER CALL
-- ============================================================================


{-| Returns the case whose mapped accessor result is passed to `List.length`.
Despite the group's name, its function is not polymorphic.
-}
accessorPolymorphicCases : (Src.Module -> Expectation) -> List TestCase
accessorPolymorphicCases expectFn =
    [ { label = "Generic function using accessor", run = genericFunctionUsingAccessor expectFn }
    ]


{-| Applies `expectFn` to a program that counts the result of mapping `.id`.
`countIds` is annotated with a closed record alias, so `countIds` itself is
not polymorphic, whatever the case's label says:

    type alias Item =
        { id : Int, label : String }

    countIds : List Item -> Int
    countIds items =
        List.length (List.map .id items)

    testValue : Int
    testValue =
        countIds [ { id = 1, label = "A" }, { id = 2, label = "B" } ]

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
-- ACCESSORS CHOSEN BY CASE OR STORED IN A RECORD
-- ============================================================================


{-| Returns the cases in which an accessor appears in a `case` branch, or in a
field of a record, rather than as an argument to a call.
-}
accessorViaCaseCases : (Src.Module -> Expectation) -> List TestCase
accessorViaCaseCases expectFn =
    [ { label = "Accessor selected via case, stored in tuple", run = accessorCaseTuple expectFn }
    , { label = "Accessor selected via case, applied immediately", run = accessorCaseApplied expectFn }
    , { label = "Accessor selected via case, passed to HOF", run = accessorCaseToHof expectFn }
    , { label = "Accessor in case with mixed field types", run = accessorCaseMixedTypes expectFn }
    , { label = "Accessor stored in record field", run = accessorInRecordField expectFn }
    , { label = "Accessor selected via nested case", run = accessorNestedCase expectFn }
    ]


{-| Applies `expectFn` to a program in which a `case` returns a pair of
accessors, the pair is destructured in a `let`, and each accessor is then
applied to a record:

    type Loc
        = First
        | Second

    choose : Loc -> { a : Int, b : Int } -> ( Int, Int )
    choose loc rec =
        let
            ( getter, setter ) =
                case loc of
                    First ->
                        ( .a, .b )

                    Second ->
                        ( .b, .a )
        in
        ( getter rec, setter rec )

    testValue : ( Int, Int )
    testValue =
        choose First { a = 10, b = 20 }

No accessor here is a call argument, so none takes its record type from a
parameter; each is an element of a tuple.

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


{-| Applies `expectFn` to a program in which each branch of a `case` calls an
accessor directly on a record:

    type Which
        = UseA
        | UseB

    getField : Which -> { a : Int, b : Int } -> Int
    getField which rec =
        case which of
            UseA ->
                .a rec

            UseB ->
                .b rec

    testValue : Int
    testValue =
        getField UseA { a = 42, b = 0 }

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


{-| Applies `expectFn` to a program in which a function returns an accessor
from a `case`, and its result is passed to `List.map`:

    type SortBy
        = ByName
        | ByAge

    type alias Person =
        { name : String, age : Int }

    sortKey : SortBy -> Person -> String
    sortKey sortBy =
        case sortBy of
            ByName ->
                .name

            ByAge ->
                .name

    testValue : List String
    testValue =
        List.map (sortKey ByName) [ { name = "Alice", age = 30 } ]

Both branches return `.name`; `.age` would not fit the annotation's `String`
result.

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


{-| Applies `expectFn` to a program in which a function returns an accessor
from a `case`, and the result is let-bound and applied to a record:

    type Field
        = IntField
        | StrField

    pickAccessor : Field -> { count : Int, label : String } -> Int
    pickAccessor field =
        case field of
            IntField ->
                .count

            StrField ->
                .count

    testValue : Int
    testValue =
        let
            f =
                pickAccessor IntField
        in
        f { count = 5, label = "hello" }

The record has an `Int` and a `String` field, but both branches return
`.count`, so every accessor here has an `Int` result.

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


{-| Applies `expectFn` to a program that stores `.a` in a field of a let-bound
record and calls it through that field:

    testValue : Int
    testValue =
        let
            ops =
                { getter = .a }
        in
        ops.getter { a = 10, b = 20 }

No annotation names either record type.

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
                    [ define "ops"
                        []
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


{-| Applies `expectFn` to a program in which nested `case`s choose one of three
accessors, and the function returning it is called with the record as an extra
argument:

    type Outer
        = OutA
        | OutB

    type Inner
        = InX
        | InY

    pickAccessor : Outer -> Inner -> { x : Int, y : Int, z : Int } -> Int
    pickAccessor outer inner =
        case outer of
            OutA ->
                case inner of
                    InX ->
                        .x

                    InY ->
                        .y

            OutB ->
                .z

    testValue : Int
    testValue =
        pickAccessor OutA InX { x = 1, y = 2, z = 3 }

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
