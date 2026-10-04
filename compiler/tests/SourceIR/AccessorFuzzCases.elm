module SourceIR.AccessorFuzzCases exposing (expectSuite)

{-| Fuzz tests that put record accessors and field access through whatever
check the caller supplies, on programs that vary from run to run in their field
names, list lengths, record sizes or field values, rather than only on programs
fixed in advance. One of the seven tests is the exception, as listed below.

An accessor is a field name written with a leading dot, such as `.name`. It is
a function that takes a record and returns that field. Field access is the form
`record.name`, which reads the field in place. The first group of tests passes
accessors around as function values; the other two groups use field access, and
build no accessor at all.

Each test is a `Test.fuzz` whose fuzzer generates one expression. The test
wraps it with `makeModule "testValue"`, which, as `Compiler.AST.SourceBuilder`
describes, makes a module named `Test` that imports only `Basics` and `List`
and whose one top-level value is `testValue`, defined as the expression with no
annotation. The module is handed to the caller's `expectFn`. Nothing here
asserts anything: which stage the program goes through, and what counts as
passing, are up to `expectFn`.

The fixture is generated. Field names come from a fixed list of twelve
lower-case names, except in the two multi-field programs, which use fixed
letters and fixed words. Every field that does not hold another record holds
an integer literal, apart from two fields of one record, which hold a string and
`Basics.True`. A fuzzed integer can be negative, and `SourceBuilder.intExpr`
stores it as a negative literal, a form the parser never produces.

The tests, by the program each one builds:

  - "Accessor with List.map": `List.map .f [ { f = n1 }, ... ]`, a list literal
    of one to three records that each have the one field `f`.
  - "Accessor in pipeline": the same list of records followed by
    `|> List.map .f`.
  - "Accessor passed to function": the accessor as the first argument of a
    local function, `let applyAccessor f r = f r in applyAccessor .x { x = n }`.
  - "Two-level chained access": `{ a = { b = 42 } }.a.b`, with the access
    applied to the record literal itself. The two field names are drawn
    independently and can be the same.
  - "Three-level chained access": the same with three nested records.
  - "Access on record with many fields": one field, chosen at random, read from
    a record literal of five to eight fields.
  - "Multiple accessors on same record": three field accesses on one `let`-bound
    record, each field of a different type. Every run builds the same program.

Among what is not tested: an accessor applied directly to a record (`.f r`), an
accessor on a record of more than one field, a field value that is not a
literal in the accessor and chained-access programs, record update, record
patterns and type annotations.

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
        )
import Test exposing (Test)



-- =============================================================================
-- TEST SUITE
-- =============================================================================


{-| Builds the suite "Accessor fuzz tests" from the three groups of tests in
this module, each test handing its generated module to `expectFn`. `condStr` is
appended to the name of the suite, of each group and of each test.
-}
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


{-| Builds the tests that pass an accessor as a function value: to `List.map`,
to `List.map` on the right of `|>`, and to a local function. Each fuzzer is
given a depth budget of 2.
-}
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


{-| Produces a fuzzer for `List.map .f records`, where `f` is a name from
`fieldNameFuzzer` and `records` is a list literal of one to three records whose
one field is `f`.

Each field value is an expression `SourceIR.Fuzz.TypedExpr` generates for
`TInt`, at the depth budget of `scope` less two. With the empty scope of budget
2 that the tests pass, that budget is 0 and there are no variables, so the value
is always an integer literal.

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
                                        B.callExpr
                                            (B.qualVarExpr "List" "map")
                                            [ B.accessorExpr fieldName
                                            , B.listExpr records
                                            ]
                                    )
                        )
            )


{-| Produces a fuzzer for `records |> List.map .f`, with `f` and `records` as
`accessorWithMapFuzzer` makes them. The right of the `|>` is `List.map` applied
to the accessor alone.
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


{-| Produces a fuzzer for `let applyAccessor f r = f r in applyAccessor .x record`,
where `x` is a name from `fieldNameFuzzer` and `record` is a record literal
whose one field is `x`. `applyAccessor` is a local function with no annotation.

The field value is made as in `accessorWithMapFuzzer`, so with the empty scope
of budget 2 the tests pass it is always an integer literal.

-}
accessorPassedToFunctionFuzzer : Scope -> Fuzzer Src.Expr
accessorPassedToFunctionFuzzer scope =
    fieldNameFuzzer
        |> Fuzz.andThen
            (\fieldName ->
                recordWithFieldFuzzer (decrementDepth scope) fieldName TInt
                    |> Fuzz.map
                        (\record ->
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


{-| Builds the tests that read a field of a nested record literal, two and
three levels down.
-}
chainedAccessTests : (Src.Module -> Expectation) -> String -> Test
chainedAccessTests expectFn condStr =
    Test.describe ("Chained field access " ++ condStr)
        [ Test.fuzz twoLevelAccessFuzzer
            ("Two-level chained access " ++ condStr)
            (\expr -> expectFn (makeModule "testValue" expr))
        , Test.fuzz threeLevelAccessFuzzer
            ("Three-level chained access " ++ condStr)
            (\expr -> expectFn (makeModule "testValue" expr))
        ]


{-| Produces a fuzzer for `{ a = { b = 42 } }.a.b`, where `a` and `b` are
drawn independently from `fieldNameFuzzer` and so can be the same name. `scope`
is not used.
-}
twoLevelAccessFuzzer : Fuzzer Src.Expr
twoLevelAccessFuzzer =
    Fuzz.map2
        (\outerField innerField ->
            let
                innerRecord =
                    B.recordExpr [ ( innerField, B.intExpr 42 ) ]

                outerRecord =
                    B.recordExpr [ ( outerField, innerRecord ) ]
            in
            B.accessExpr
                (B.accessExpr outerRecord outerField)
                innerField
        )
        fieldNameFuzzer
        fieldNameFuzzer


{-| Produces a fuzzer for `{ a = { b = { c = 42 } } }.a.b.c`, where `a`, `b`
and `c` are drawn independently from `fieldNameFuzzer` and so can repeat.
`scope` is not used.
-}
threeLevelAccessFuzzer : Fuzzer Src.Expr
threeLevelAccessFuzzer =
    Fuzz.map3
        (\fieldA fieldB fieldC ->
            let
                cRecord =
                    B.recordExpr [ ( fieldC, B.intExpr 42 ) ]

                bRecord =
                    B.recordExpr [ ( fieldB, cRecord ) ]

                aRecord =
                    B.recordExpr [ ( fieldA, bRecord ) ]
            in
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


{-| Builds the tests that read fields of a record with more than one field.
-}
multiFieldRecordTests : (Src.Module -> Expectation) -> String -> Test
multiFieldRecordTests expectFn condStr =
    Test.describe ("Multi-field record access " ++ condStr)
        [ Test.fuzz manyFieldAccessFuzzer
            ("Access on record with many fields " ++ condStr)
            (\expr -> expectFn (makeModule "testValue" expr))
        , Test.fuzz multipleAccessorsFuzzer
            ("Multiple accessors on same record " ++ condStr)
            (\expr -> expectFn (makeModule "testValue" expr))
        ]


{-| Produces a fuzzer for `{ a = 0, b = 1, ... }.x`: a record literal of five to
eight fields, named with the letters from `a` onwards and each holding its own
position from 0, read at one field `x` chosen at random. Only the number of
fields and the field read vary. `scope` is not used.
-}
manyFieldAccessFuzzer : Fuzzer Src.Expr
manyFieldAccessFuzzer =
    Fuzz.intRange 5 8
        |> Fuzz.andThen
            (\fieldCount ->
                generateFieldNames fieldCount
                    |> Fuzz.andThen
                        (\fieldNames ->
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


{-| Produces a fuzzer that always gives
`let r = { alpha = 1, beta = "hello", gamma = Basics.True } in ( r.alpha, r.beta, r.gamma )`:
three field accesses on one `let`-bound record, reading an integer literal, a
string and a `Bool`. The field names are fixed and distinct.
It uses field access, not accessor functions. `scope` is not used.
-}
multipleAccessorsFuzzer : Fuzzer Src.Expr
multipleAccessorsFuzzer =
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


{-| A fuzzer for a field name, one of twelve fixed lower-case names.
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


{-| Produces a fuzzer that always gives the first `count` of the ten distinct
names `a` to `j`, or all ten when `count` is larger.
-}
generateFieldNames : Int -> Fuzzer (List Name)
generateFieldNames count =
    let
        baseNames =
            [ "a", "b", "c", "d", "e", "f", "g", "h", "i", "j" ]
    in
    Fuzz.constant (List.take count baseNames)


{-| Produces a fuzzer for a record literal whose one field is `fieldName`,
holding an expression that `SourceIR.Fuzz.TypedExpr` generates for
`fieldType`, at the depth budget of `scope` less one.

The record has no other field, so records made with the same name and type all
have the same type and can share a list.

-}
recordWithFieldFuzzer : Scope -> Name -> SimpleType -> Fuzzer Src.Expr
recordWithFieldFuzzer scope fieldName fieldType =
    TE.exprFuzzerForType (decrementDepth scope) fieldType
        |> Fuzz.map
            (\fieldValue ->
                B.recordExpr [ ( fieldName, fieldValue ) ]
            )
