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

Among what is not tested: that the generated MLIR of a focused program holds
any `eco.project.custom` at all, so a program whose match leaves no projection
passes; the result type the projection declares; `Float` and `Char` fields,
since the focused programs read only `Int` fields; and the value `testValue`
computes, since no program is run.

-}

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
        , pVar
        , tLambda
        , tType
        , tVar
        , varExpr
        )
import Expect
import SourceIR.Suite.StandardTestSuites as StandardTestSuites
import Test exposing (Test)
import TestLogic.Generate.CodeGen.DestructorTypeProjection
    exposing
        ( countProjectionUnboxSequences
        , expectDestructorTypeProjection
        )
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


{-| The three tests on small programs built here, each requiring that the
generated MLIR holds no spurious unbox.
-}
focusedTests : Test
focusedTests =
    Test.describe "Focused CGEN_004 tests"
        [ testResultIntExtraction
        , testMaybeIntExtraction
        , testNestedResultExtraction
        ]


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
            case runToMlir modul of
                Err err ->
                    Expect.fail ("Compilation failed: " ++ err)

                Ok { mlirModule } ->
                    let
                        spuriousCount =
                            countProjectionUnboxSequences mlirModule
                    in
                    if spuriousCount > 0 then
                        Expect.fail
                            ("Found "
                                ++ String.fromInt spuriousCount
                                ++ " spurious projection→unbox sequence(s). "
                                ++ "CGEN_004 requires projections to yield the natural MonoType, "
                                ++ "so extracting Int from Ok should yield i64 directly."
                            )

                    else
                        Expect.pass


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
            case runToMlir modul of
                Err err ->
                    Expect.fail ("Compilation failed: " ++ err)

                Ok { mlirModule } ->
                    let
                        spuriousCount =
                            countProjectionUnboxSequences mlirModule
                    in
                    if spuriousCount > 0 then
                        Expect.fail
                            ("Found "
                                ++ String.fromInt spuriousCount
                                ++ " spurious projection→unbox sequence(s). "
                                ++ "CGEN_004 requires projections to yield the natural MonoType."
                            )

                    else
                        Expect.pass


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
            case runToMlir modul of
                Err err ->
                    Expect.fail ("Compilation failed: " ++ err)

                Ok { mlirModule } ->
                    let
                        spuriousCount =
                            countProjectionUnboxSequences mlirModule
                    in
                    if spuriousCount > 0 then
                        Expect.fail
                            ("Found "
                                ++ String.fromInt spuriousCount
                                ++ " spurious projection→unbox sequence(s). "
                                ++ "CGEN_004 requires projections to yield the natural MonoType."
                            )

                    else
                        Expect.pass
