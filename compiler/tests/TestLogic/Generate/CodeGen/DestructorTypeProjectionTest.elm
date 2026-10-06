module TestLogic.Generate.CodeGen.DestructorTypeProjectionTest exposing (suite)

{-| These tests look in generated MLIR for a sign that pattern matching read a
field out of a custom-type value at the wrong type: the field comes out boxed,
as an `!eco.value`, and that result is then unboxed. The rule this breaks is
called `CGEN_004` in the test names and failure messages: a field read out of a
constructor should come out at its own specialised type, so an `Int` field
should come out as an `i64`.

The pattern looked for is defined in
`TestLogic.Generate.CodeGen.DestructorTypeProjection`, which calls it a
_spurious unbox_: an `eco.unbox` to `i64`, `f64` or `i16` whose operand is
defined by an `eco.project.custom`, the op that reads one field of a
custom-type value, in the same function.

The tests use two kinds of program. One is the standard catalogue of test
programs that `SourceIR.Suite.StandardTestSuites` runs. The other is three
small programs built here, each a module named `Test` that declares its own
`Maybe` or `Result` type (`maybeUnion`, `resultUnion`), an annotated function
that matches on values of that type and returns an `Int` read out of them, and
a `testValue : Int` that calls the function on constructors applied to `Int`
literals. In the program sketches given with each test, `_` is built as a
variable pattern with that name, not as a wildcard. Each focused test compiles
its program with `TestLogic.TestPipeline.runToMlir` and fails with a message
starting `Compilation failed:` when compilation fails.

What the tests establish:

  - `standardTests`: every program in the standard catalogue compiles, and
    its generated MLIR holds no spurious unbox.

  - `testResultIntExtraction`: matching `Ok value` on a `Result String Int`
    generates no spurious unbox.

  - `testMaybeIntExtraction`: matching `Just value` on a `Maybe Int`
    generates no spurious unbox.

  - `testNestedResultExtraction`: a `case` on one `Result String Int` nested
    in the `Ok` branch of a `case` on another generates no spurious unbox.

  - `testUnboxedFieldPastHeaderBitmap`: field 24 of a 25-`Int`-field
    constructor, past the 24 slots a Custom header bitmap describes, is stored
    unboxed (layouts have no index cap, HEAP\_019) and is projected as `i64`
    with no unbox.

  - `testBoxedStringFieldAtIndex24`: a `String` field at index 24 is projected
    as `!eco.value`.

  - `testPolymorphicFieldAtIndex24`: field 24 of `type Wide a = Wide Int ... a`,
    read by a function polymorphic in `a` and used at `a = Int`, is projected
    as `i64` in the specialisation.

  - `testUnboxedRecordFieldPastHeaderBitmap`: in a record pattern on a record
    of 28 `Int` fields, field `f27` (index 27, which `computeRecordLayout` now
    stores unboxed) is projected by `eco.project.record` as `i64`, and no
    projection reads a boxed field raw.

Each focused test also requires its MLIR to hold at least one
`eco.project.custom`, so a match optimised away fails rather than passing
vacuously.

Among what is not tested: the result type the projection declares; `Float` and `Char` fields,
since the focused programs read only `Int` fields; and the value `testValue`
computes, since no program is run.

-}

import Compiler.AST.Monomorphized as Mono
import Compiler.AST.Source as Src
import Compiler.AST.SourceBuilder
    exposing
        ( TypedDef
        , UnionDef
        , binopsExpr
        , callExpr
        , caseExpr
        , ctorExpr
        , intExpr
        , makeModuleWithTypedDefsUnionsAliases
        , pCtor
        , pRecord
        , pVar
        , recordExpr
        , strExpr
        , tLambda
        , tRecord
        , tType
        , tVar
        , varExpr
        )
import Compiler.Generate.MLIR.Types as Types
import Dict
import Expect
import Mlir.Mlir exposing (MlirType(..))
import SourceIR.Suite.StandardTestSuites as StandardTestSuites
import Test exposing (Test)
import TestLogic.Generate.CodeGen.DestructorTypeProjection
    exposing
        ( checkDestructorTypeProjection
        , checkRecordFieldProjection
        , countCustomProjections
        , countRecordProjections
        , expectDestructorTypeProjection
        , hasProjectionOf
        , hasRecordProjectionOf
        )
import TestLogic.Generate.CodeGen.Invariants exposing (violationsToExpectation)
import TestLogic.TestPipeline exposing (runToMlir)


{-| The whole suite: `standardTests` and `focusedTests`.
-}
suite : Test
suite =
    Test.describe "CGEN_004: Destructor Type Projection"
        [ standardTests
        , focusedTests
        ]


{-| The tests that run `expectDestructorTypeProjection` on every program in the
standard catalogue. A program fails when it does not compile or when its
generated MLIR holds any spurious unbox.
-}
standardTests : Test
standardTests =
    Test.describe "Standard test suites"
        [ StandardTestSuites.expectSuite expectDestructorTypeProjection "passes destructor type projection invariant"
        ]


{-| The tests on small programs built here, each requiring that the generated
MLIR holds no spurious unbox (or, for the record test, no raw read of a boxed
record field).
-}
focusedTests : Test
focusedTests =
    Test.describe "Focused CGEN_004 tests"
        [ testResultIntExtraction
        , testMaybeIntExtraction
        , testNestedResultExtraction
        , testUnboxedFieldPastHeaderBitmap
        , testBoxedStringFieldAtIndex24
        , testPolymorphicFieldAtIndex24
        , testUnboxedRecordFieldPastHeaderBitmap
        ]


{-| Compiles `modul` with `TestLogic.TestPipeline.runToMlir` and passes when the
generated MLIR holds at least one `eco.project.custom` (so the match under test
was not optimised away), no spurious unbox and no raw read of a boxed field.
-}
expectProjectedWithoutSpuriousUnbox : Src.Module -> Expect.Expectation
expectProjectedWithoutSpuriousUnbox modul =
    case runToMlir modul of
        Err err ->
            Expect.fail ("Compilation failed: " ++ err)

        Ok { mlirModule } ->
            if countCustomProjections mlirModule == 0 then
                Expect.fail "No eco.project.custom was generated, so the match under test was not exercised"

            else
                violationsToExpectation (checkDestructorTypeProjection mlirModule)


{-| Compiles `modul` and passes when, as for
`expectProjectedWithoutSpuriousUnbox`, it holds an `eco.project.custom` and no
spurious unbox, and the module holds an `eco.project.custom` of field `index` whose
result type is `ty`.
-}
expectProjectedAt : Int -> MlirType -> Src.Module -> Expect.Expectation
expectProjectedAt index ty modul =
    case runToMlir modul of
        Err err ->
            Expect.fail ("Compilation failed: " ++ err)

        Ok { mlirModule } ->
            Expect.all
                [ \m ->
                    if countCustomProjections m == 0 then
                        Expect.fail "No eco.project.custom was generated, so the match under test was not exercised"

                    else
                        violationsToExpectation (checkDestructorTypeProjection m)
                , \m ->
                    hasProjectionOf index ty m
                        |> Expect.equal True
                        |> Expect.onFail ("expected an eco.project.custom of field " ++ String.fromInt index ++ " with the expected result type")
                ]
                mlirModule


{-| A module `Test` declaring `type Wide = Wide Int ... Int T24` (24 `Int`
fields, then one of type `field24Type`) and

    lastField : Wide -> R
    lastField w =
        case w of
            Wide f0 f1 ... f24 ->
                f24

    testValue : R
    testValue =
        lastField (Wide 0 1 ... 23 last)

where `R` is `field24Type` and `last` is `lastArg`.

-}
wideCtorModule : Src.Type -> Src.Expr -> Src.Module
wideCtorModule field24Type lastArg =
    let
        fieldNames =
            List.map (\i -> "f" ++ String.fromInt i) (List.range 0 24)

        wideUnion : UnionDef
        wideUnion =
            { name = "Wide"
            , args = []
            , ctors = [ { name = "Wide", args = List.repeat 24 (tType "Int" []) ++ [ field24Type ] } ]
            }

        lastFieldDef : TypedDef
        lastFieldDef =
            { name = "lastField"
            , args = [ pVar "w" ]
            , tipe = tLambda (tType "Wide" []) field24Type
            , body =
                caseExpr (varExpr "w")
                    [ ( pCtor "Wide" (List.map pVar fieldNames), varExpr "f24" ) ]
            }

        testValueDef : TypedDef
        testValueDef =
            { name = "testValue"
            , args = []
            , tipe = field24Type
            , body =
                callExpr (varExpr "lastField")
                    [ callExpr (ctorExpr "Wide") (List.map intExpr (List.range 0 23) ++ [ lastArg ]) ]
            }
    in
    makeModuleWithTypedDefsUnionsAliases "Test"
        [ lastFieldDef, testValueDef ]
        [ wideUnion ]
        []


{-| The test that reading an `Int` field at index 24 of a constructor, past the
24 slots a Custom header bitmap describes, projects it as `i64` with no unbox.
`computeCtorLayout` has no index cap, so the field is stored unboxed and its
kind goes in an extension kind word (HEAP\_019). The program is
`wideCtorModule` with an `Int` field 24 and argument `24`.
-}
testUnboxedFieldPastHeaderBitmap : Test
testUnboxedFieldPastHeaderBitmap =
    Test.test "Int field at index 24 is projected unboxed (i64) with no unbox" <|
        \_ ->
            wideCtorModule (tType "Int" []) (intExpr 24)
                |> expectProjectedAt 24 I64


{-| The test that a boxed field at index 24 (a `String`) is projected as
`!eco.value`: the boxed branch of the custom-container projection at an index
past the header bitmap. A primitive is never boxed by index, so no `Int`
variant of this path exists. The program is `wideCtorModule` with a `String`
field 24 and argument `"x"`.
-}
testBoxedStringFieldAtIndex24 : Test
testBoxedStringFieldAtIndex24 =
    Test.test "boxed field at index 24 is projected as !eco.value" <|
        \_ ->
            wideCtorModule (tType "String" []) (strExpr "x")
                |> expectProjectedAt 24 (NamedStruct "eco.value")


{-| The test that field 24 of a polymorphic constructor, read by a function
polymorphic in that field's type and used at `Int`, is projected as `i64` in
the specialisation. The program declares `type Wide a = Wide Int ... Int a`
(24 `Int` fields, then `a`) and

    lastField : Wide a -> a
    lastField w =
        case w of
            Wide f0 f1 ... f24 ->
                f24

    testValue : Int
    testValue =
        lastField (Wide 0 1 ... 24)

It exercises the shape-scanning path of the custom-field lookup past slot 24.

-}
testPolymorphicFieldAtIndex24 : Test
testPolymorphicFieldAtIndex24 =
    Test.test "polymorphic field at index 24 used at Int is projected unboxed (i64)" <|
        \_ ->
            let
                fieldNames =
                    List.map (\i -> "f" ++ String.fromInt i) (List.range 0 24)

                wideUnion : UnionDef
                wideUnion =
                    { name = "Wide"
                    , args = [ "a" ]
                    , ctors = [ { name = "Wide", args = List.repeat 24 (tType "Int" []) ++ [ tVar "a" ] } ]
                    }

                lastFieldDef : TypedDef
                lastFieldDef =
                    { name = "lastField"
                    , args = [ pVar "w" ]
                    , tipe = tLambda (tType "Wide" [ tVar "a" ]) (tVar "a")
                    , body =
                        caseExpr (varExpr "w")
                            [ ( pCtor "Wide" (List.map pVar fieldNames), varExpr "f24" ) ]
                    }

                testValueDef : TypedDef
                testValueDef =
                    { name = "testValue"
                    , args = []
                    , tipe = tType "Int" []
                    , body =
                        callExpr (varExpr "lastField")
                            [ callExpr (ctorExpr "Wide") (List.map intExpr (List.range 0 24)) ]
                    }
            in
            makeModuleWithTypedDefsUnionsAliases "Test"
                [ lastFieldDef, testValueDef ]
                [ wideUnion ]
                []
                |> expectProjectedAt 24 I64


{-| The test that a record pattern reading field 27 of a record of 28 `Int`
fields `f00` to `f27` projects it unboxed, as `i64`.
`Compiler.Generate.MLIR.Types.computeRecordLayout` has no index cap, so every
field is stored unboxed; field 27 is past the 26 slots the old Elm-side bitmap
could describe (bug B3 of `plans/wide-object-tail-kind-words.md` read it raw
while it was stored boxed). The program is

    viaPat : { f00 : Int, ..., f27 : Int } -> Int
    viaPat { f27, f25 } =
        f27 * 1000 + f25

    testValue : Int
    testValue =
        viaPat { f00 = 0, f01 = 1, ..., f27 = 27 }

The test also runs the layout-driven raw-read check, which reads the layout
from `Types` and so finds no boxed primitive field.

-}
testUnboxedRecordFieldPastHeaderBitmap : Test
testUnboxedRecordFieldPastHeaderBitmap =
    Test.test "record field 27 of a 28-Int record is projected unboxed (i64)" <|
        \_ ->
            let
                fieldNames =
                    List.map (\i -> "f" ++ String.padLeft 2 '0' (String.fromInt i)) (List.range 0 27)

                layout : Types.RecordLayout
                layout =
                    Types.computeRecordLayout
                        (Dict.fromList (List.map (\name -> ( name, Mono.MInt )) fieldNames))

                viaPatDef : TypedDef
                viaPatDef =
                    { name = "viaPat"
                    , args = [ pRecord [ "f27", "f25" ] ]
                    , tipe =
                        tLambda (tRecord (List.map (\name -> ( name, tType "Int" [] )) fieldNames))
                            (tType "Int" [])
                    , body =
                        binopsExpr [ ( varExpr "f27", "*" ), ( intExpr 1000, "+" ) ] (varExpr "f25")
                    }

                testValueDef : TypedDef
                testValueDef =
                    { name = "testValue"
                    , args = []
                    , tipe = tType "Int" []
                    , body =
                        callExpr (varExpr "viaPat")
                            [ recordExpr (List.indexedMap (\i name -> ( name, intExpr i )) fieldNames) ]
                    }

                modul =
                    makeModuleWithTypedDefsUnionsAliases "Test"
                        [ viaPatDef, testValueDef ]
                        []
                        []
            in
            case runToMlir modul of
                Err err ->
                    Expect.fail ("Compilation failed: " ++ err)

                Ok { mlirModule } ->
                    if countRecordProjections mlirModule == 0 then
                        Expect.fail "No eco.project.record was generated, so the record pattern under test was not exercised"

                    else
                        Expect.all
                            [ \m -> violationsToExpectation (checkRecordFieldProjection layout m)
                            , \m ->
                                hasRecordProjectionOf 27 I64 m
                                    |> Expect.equal True
                                    |> Expect.onFail "expected an eco.project.record of field 27 with result type i64"
                            ]
                            mlirModule


{-| The declaration `type Maybe a = Just a | Nothing`, which
`testMaybeIntExtraction`'s program declares for itself.
-}
maybeUnion : UnionDef
maybeUnion =
    { name = "Maybe"
    , args = [ "a" ]
    , ctors =
        [ { name = "Just", args = [ tVar "a" ] }
        , { name = "Nothing", args = [] }
        ]
    }


{-| The declaration `type Result error ok = Ok ok | Err error`, which the
programs of `testResultIntExtraction` and `testNestedResultExtraction` declare
for themselves. The error type comes first, so in `Result String Int` the `Ok`
field is the `Int`.
-}
resultUnion : UnionDef
resultUnion =
    { name = "Result"
    , args = [ "error", "ok" ]
    , ctors =
        [ { name = "Ok", args = [ tVar "ok" ] }
        , { name = "Err", args = [ tVar "error" ] }
        ]
    }


{-| The test that reading the `Int` out of `Ok` on a `Result String Int`
generates no spurious unbox. The test name says `Result Int String`, but the
program's annotation is `Result String Int`. Written as Elm source, the
program is:

    getOkValue : Result String Int -> Int
    getOkValue result =
        case result of
            Ok value ->
                value

            Err _ ->
                0

    testValue : Int
    testValue =
        getOkValue (Ok 42)

-}
testResultIntExtraction : Test
testResultIntExtraction =
    Test.test "Result Int String Ok extraction yields i64 directly" <|
        \_ ->
            let
                getOkValueDef : TypedDef
                getOkValueDef =
                    { name = "getOkValue"
                    , args = [ pVar "result" ]
                    , tipe = tLambda (tType "Result" [ tType "String" [], tType "Int" [] ]) (tType "Int" [])
                    , body =
                        caseExpr (varExpr "result")
                            [ ( pCtor "Ok" [ pVar "value" ], varExpr "value" )
                            , ( pCtor "Err" [ pVar "_" ], intExpr 0 )
                            ]
                    }

                testValueDef : TypedDef
                testValueDef =
                    { name = "testValue"
                    , args = []
                    , tipe = tType "Int" []
                    , body =
                        callExpr (varExpr "getOkValue")
                            [ callExpr (ctorExpr "Ok") [ intExpr 42 ] ]
                    }

                modul =
                    makeModuleWithTypedDefsUnionsAliases "Test"
                        [ getOkValueDef, testValueDef ]
                        [ resultUnion ]
                        []
            in
            expectProjectedWithoutSpuriousUnbox modul


{-| The test that reading the `Int` out of `Just` on a `Maybe Int` generates no
spurious unbox. Written as Elm source, the program is:

    getJustValue : Maybe Int -> Int
    getJustValue maybe =
        case maybe of
            Just value ->
                value

            Nothing ->
                0

    testValue : Int
    testValue =
        getJustValue (Just 42)

-}
testMaybeIntExtraction : Test
testMaybeIntExtraction =
    Test.test "Maybe Int Just extraction yields i64 directly" <|
        \_ ->
            let
                getJustValueDef : TypedDef
                getJustValueDef =
                    { name = "getJustValue"
                    , args = [ pVar "maybe" ]
                    , tipe = tLambda (tType "Maybe" [ tType "Int" [] ]) (tType "Int" [])
                    , body =
                        caseExpr (varExpr "maybe")
                            [ ( pCtor "Just" [ pVar "value" ], varExpr "value" )
                            , ( pCtor "Nothing" [], intExpr 0 )
                            ]
                    }

                testValueDef : TypedDef
                testValueDef =
                    { name = "testValue"
                    , args = []
                    , tipe = tType "Int" []
                    , body =
                        callExpr (varExpr "getJustValue")
                            [ callExpr (ctorExpr "Just") [ intExpr 42 ] ]
                    }

                modul =
                    makeModuleWithTypedDefsUnionsAliases "Test"
                        [ getJustValueDef, testValueDef ]
                        [ maybeUnion ]
                        []
            in
            expectProjectedWithoutSpuriousUnbox modul


{-| The test that reading the `Int`s out of two `Result String Int` values, with
the `case` on the second nested in the `Ok` branch of the `case` on the first,
generates no spurious unbox. Neither `Result` holds another; only the matches
are nested. Written as Elm source, the program is:

    addResults : Result String Int -> Result String Int -> Int
    addResults r1 r2 =
        case r1 of
            Ok a ->
                case r2 of
                    Ok b ->
                        a + b

                    Err _ ->
                        a

            Err _ ->
                0

and `testValue : Int` is `(addResults (Ok 21)) (Ok 21)`, which applies
`addResults` one argument at a time: it calls the partial application
`addResults (Ok 21)` on the second `Ok 21`.

-}
testNestedResultExtraction : Test
testNestedResultExtraction =
    Test.test "Nested Result Int extraction works correctly" <|
        \_ ->
            let
                addResultsDef : TypedDef
                addResultsDef =
                    { name = "addResults"
                    , args = [ pVar "r1", pVar "r2" ]
                    , tipe =
                        tLambda (tType "Result" [ tType "String" [], tType "Int" [] ])
                            (tLambda (tType "Result" [ tType "String" [], tType "Int" [] ]) (tType "Int" []))
                    , body =
                        caseExpr (varExpr "r1")
                            [ ( pCtor "Ok" [ pVar "a" ]
                              , caseExpr (varExpr "r2")
                                    [ ( pCtor "Ok" [ pVar "b" ]
                                      , binopsExpr [ ( varExpr "a", "+" ) ] (varExpr "b")
                                      )
                                    , ( pCtor "Err" [ pVar "_" ], varExpr "a" )
                                    ]
                              )
                            , ( pCtor "Err" [ pVar "_" ], intExpr 0 )
                            ]
                    }

                testValueDef : TypedDef
                testValueDef =
                    { name = "testValue"
                    , args = []
                    , tipe = tType "Int" []
                    , body =
                        callExpr
                            (callExpr (varExpr "addResults")
                                [ callExpr (ctorExpr "Ok") [ intExpr 21 ] ]
                            )
                            [ callExpr (ctorExpr "Ok") [ intExpr 21 ] ]
                    }

                modul =
                    makeModuleWithTypedDefsUnionsAliases "Test"
                        [ addResultsDef, testValueDef ]
                        [ resultUnion ]
                        []
            in
            expectProjectedWithoutSpuriousUnbox modul
