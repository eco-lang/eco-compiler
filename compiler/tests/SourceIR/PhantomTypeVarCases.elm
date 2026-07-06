module SourceIR.PhantomTypeVarCases exposing (expectSuite, suite)

{-| Regression test for phantom type variable duplication in monomorphization.

When a constructor like `RErr (List e)` has type `List e -> RStep e a`,
the phantom `a` can cause excess specializations if fresh MVarIds leak
into SpecKeys. In the real compiler bootstrap, this causes OOM during
Stage 5 as thousands of duplicate specializations accumulate.

These tests verify the pattern compiles correctly. With the fix in place,
`RErr` should have exactly 1 specialization per distinct (e) type, not
per distinct (e, a) pair.

-}

import Array
import Compiler.AST.Monomorphized as Mono
import Compiler.AST.Source as Src
import Compiler.AST.SourceBuilder
    exposing
        ( TypedDef
        , UnionDef
        , callExpr
        , caseExpr
        , ctorExpr
        , intExpr
        , lambdaExpr
        , makeModuleWithTypedDefsUnionsAliases
        , pCtor
        , pVar
        , tLambda
        , tType
        , tVar
        , varExpr
        )
import Compiler.BulkCheck exposing (TestCase, bulkCheck)
import Expect exposing (Expectation)
import Test exposing (Test)
import TestLogic.TestPipeline exposing (expectMonomorphization, runToMono)


suite : Test
suite =
    Test.describe "Phantom type variable specialization"
        [ expectSuite expectMonomorphization "monomorphizes"
        , Test.test "RErr should not have duplicate specs from phantom type var" <|
            \_ -> assertNoPhantomDuplication ()
        ]


expectSuite : (Src.Module -> Expectation) -> String -> Test
expectSuite expectFn condStr =
    Test.test ("Phantom type var " ++ condStr) <|
        \_ -> bulkCheck (testCases expectFn)


testCases : (Src.Module -> Expectation) -> List TestCase
testCases expectFn =
    [ { label = "Phantom type var via mapStep/applyR"
      , run = \() -> expectFn phantomTestModule
      }
    ]


phantomTestModule : Src.Module
phantomTestModule =
    let
        rstepUnion : UnionDef
        rstepUnion =
            { name = "RStep"
            , args = [ "e", "a" ]
            , ctors =
                [ { name = "ROk", args = [ tVar "a" ] }
                , { name = "RErr", args = [ tType "List" [ tVar "e" ] ] }
                ]
            }

        -- mapStep : (a -> b) -> RStep e a -> RStep e b
        -- RErr branch reconstructs RErr at phantom type b
        mapStepDef : TypedDef
        mapStepDef =
            { name = "mapStep"
            , args = [ pVar "f", pVar "step" ]
            , tipe =
                tLambda (tLambda (tVar "a") (tVar "b"))
                    (tLambda (tType "RStep" [ tVar "e", tVar "a" ])
                        (tType "RStep" [ tVar "e", tVar "b" ])
                    )
            , body =
                caseExpr (varExpr "step")
                    [ ( pCtor "ROk" [ pVar "val" ]
                      , callExpr (ctorExpr "ROk") [ callExpr (varExpr "f") [ varExpr "val" ] ]
                      )
                    , ( pCtor "RErr" [ pVar "errs" ]
                      , callExpr (ctorExpr "RErr") [ varExpr "errs" ]
                      )
                    ]
            }

        -- applyR : RStep e (a -> b) -> RStep e a -> RStep e b
        applyRDef : TypedDef
        applyRDef =
            { name = "applyR"
            , args = [ pVar "funcStep", pVar "argStep" ]
            , tipe =
                tLambda (tType "RStep" [ tVar "e", tLambda (tVar "a") (tVar "b") ])
                    (tLambda (tType "RStep" [ tVar "e", tVar "a" ])
                        (tType "RStep" [ tVar "e", tVar "b" ])
                    )
            , body =
                caseExpr (varExpr "funcStep")
                    [ ( pCtor "RErr" [ pVar "errs" ]
                      , callExpr (ctorExpr "RErr") [ varExpr "errs" ]
                      )
                    , ( pCtor "ROk" [ pVar "func" ]
                      , callExpr (varExpr "mapStep") [ varExpr "func", varExpr "argStep" ]
                      )
                    ]
            }

        baseDef : TypedDef
        baseDef =
            { name = "base"
            , args = []
            , tipe = tType "RStep" [ tType "String" [], tType "Int" [] ]
            , body = callExpr (ctorExpr "ROk") [ intExpr 42 ]
            }

        idFuncDef : TypedDef
        idFuncDef =
            { name = "idFunc"
            , args = []
            , tipe = tType "RStep" [ tType "String" [], tLambda (tType "Int" []) (tType "Int" []) ]
            , body =
                callExpr (ctorExpr "ROk")
                    [ lambdaExpr [ pVar "x" ] (varExpr "x") ]
            }

        r1Def : TypedDef
        r1Def =
            { name = "r1"
            , args = []
            , tipe = tType "RStep" [ tType "String" [], tType "Int" [] ]
            , body = callExpr (varExpr "applyR") [ varExpr "idFunc", varExpr "base" ]
            }

        r2Def : TypedDef
        r2Def =
            { name = "r2"
            , args = []
            , tipe = tType "RStep" [ tType "String" [], tType "Int" [] ]
            , body = callExpr (varExpr "applyR") [ varExpr "idFunc", varExpr "r1" ]
            }

        testValueDef : TypedDef
        testValueDef =
            { name = "testValue"
            , args = []
            , tipe = tType "Int" []
            , body =
                caseExpr (varExpr "r2")
                    [ ( pCtor "ROk" [ pVar "v" ], varExpr "v" )
                    , ( pCtor "RErr" [ pVar "e" ], intExpr 0 )
                    ]
            }
    in
    makeModuleWithTypedDefsUnionsAliases "Test"
        [ mapStepDef, applyRDef, baseDef, idFuncDef, r1Def, r2Def, testValueDef ]
        [ rstepUnion ]
        []


{-| Assert that the RErr constructor does not have more specializations
than it should. With the phantom type var bug, RErr gets one spec per
call site (due to distinct phantom MVarIds). Without the bug, RErr should
have at most 1 specialization per distinct error type (just String here).
-}
assertNoPhantomDuplication : () -> Expectation
assertNoPhantomDuplication () =
    case runToMono phantomTestModule of
        Err msg ->
            Expect.fail ("Monomorphization failed: " ++ msg)

        Ok { monoGraph } ->
            let
                (Mono.MonoGraph data) =
                    monoGraph

                -- Count specializations of RErr by scanning registry
                rerrCount =
                    Array.foldl
                        (\maybeEntry count ->
                            case maybeEntry of
                                Just ( Mono.Global _ name, _ ) ->
                                    if name == "RErr" then
                                        count + 1

                                    else
                                        count

                                _ ->
                                    count
                        )
                        0
                        data.registry.reverseMapping
            in
            -- With only one error type (String), RErr should have at most 1 spec.
            -- With the phantom bug, it gets one per applyR/mapStep call site.
            if rerrCount > 1 then
                Expect.fail
                    ("RErr has "
                        ++ String.fromInt rerrCount
                        ++ " specializations but expected 1. "
                        ++ "Phantom type variable `a` is leaking into SpecKeys."
                    )

            else
                Expect.pass
