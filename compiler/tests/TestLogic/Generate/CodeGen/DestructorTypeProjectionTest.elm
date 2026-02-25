module TestLogic.Generate.CodeGen.DestructorTypeProjectionTest exposing (suite)

{-| Test suite for CGEN\_004: Destructor Type Projection invariant.

generateDestruct and generateMonoPath must always use the destructor MonoType
to determine the path target MLIR type. This ensures destruct paths yield
their natural type and do not spuriously unbox.

These focused tests verify that when destructuring ADTs with unboxable fields
(like Result Int String), the projection yields the primitive type directly
rather than !eco.value followed by eco.unbox.

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


suite : Test
suite =
    Test.describe "CGEN_004: Destructor Type Projection"
        [ standardTests
        , focusedTests
        ]


{-| Run standard test suites to verify no violations in general code.

Note: This may find legitimate projection→unbox sequences that are NOT violations.
The focused tests below are more precise for testing CGEN\_004 specifically.

-}
standardTests : Test
standardTests =
    Test.describe "Standard test suites"
        [ StandardTestSuites.expectSuite expectDestructorTypeProjection "passes destructor type projection invariant"
        ]


{-| Focused tests for specific patterns that exercise CGEN\_004.
-}
focusedTests : Test
focusedTests =
    Test.describe "Focused CGEN_004 tests"
        [ testResultIntExtraction
        , testMaybeIntExtraction
        , testNestedResultExtraction
        ]



-- Union type definitions


{-| Maybe type: type Maybe a = Just a | Nothing
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


{-| Result type: type Result error ok = Ok ok | Err error
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


{-| Test extracting Int from Result Int String via Ok pattern.

When we pattern match `Ok x` on `Result Int String`, the projection of
the Ok's field should yield i64 directly (since Int is unboxable and
stored unboxed in Ok).

Bug symptom: If CGEN\_004 is violated, the projection yields !eco.value
and requires eco.unbox, resulting in spurious unboxing.

-}
testResultIntExtraction : Test
testResultIntExtraction =
    Test.test "Result Int String Ok extraction yields i64 directly" <|
        \_ ->
            let
                -- getOkValue : Result String Int -> Int
                -- getOkValue result =
                --     case result of
                --         Ok value -> value
                --         Err _ -> 0
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


{-| Test extracting Int from Maybe Int via Just pattern.

Similar to Result, extracting from `Just x` on `Maybe Int` should yield
i64 directly.

-}
testMaybeIntExtraction : Test
testMaybeIntExtraction =
    Test.test "Maybe Int Just extraction yields i64 directly" <|
        \_ ->
            let
                -- getJustValue : Maybe Int -> Int
                -- getJustValue maybe =
                --     case maybe of
                --         Just value -> value
                --         Nothing -> 0
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


{-| Test extracting Int from nested Result structures.

This tests that CGEN\_004 works correctly even with nested polymorphic types.

-}
testNestedResultExtraction : Test
testNestedResultExtraction =
    Test.test "Nested Result Int extraction works correctly" <|
        \_ ->
            let
                -- addResults : Result String Int -> Result String Int -> Int
                -- addResults r1 r2 =
                --     case r1 of
                --         Ok a ->
                --             case r2 of
                --                 Ok b -> a + b
                --                 Err _ -> a
                --         Err _ -> 0
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
