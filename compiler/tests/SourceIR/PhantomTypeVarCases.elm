module SourceIR.PhantomTypeVarCases exposing (expectSuite, suite)

{-| Programs in which a constructor's type has a phantom type variable, and a
check that the monomorphizer does not specialize that constructor once per
phantom instantiation.

Monomorphization makes a separate copy, a _specialization_, of each definition
and constructor for each concrete type it is used at. In
`type RStep e a = ROk a | RErr (List e)`, the constructor `RErr` has type
`List e -> RStep e a`: its argument does not mention `a`, so `a` is a _phantom_
type variable for it. If the monomorphizer let a fresh variable standing for
`a` into the key it files specializations under, uses of `RErr` at one concrete
type would each get their own copy. Without `suite`'s count that would go
unnoticed here: `expectMonomorphization` checks only that the graph has a
`main` and at least one node.

The fixture is one module, `Test`, holding `RStep` and these annotated
definitions:

  - `mapStep : (a -> b) -> RStep e a -> RStep e b`, whose `RErr` branch builds
    a new `RErr` from the old one's list, at the new phantom type `b`;
  - `applyR : RStep e (a -> b) -> RStep e a -> RStep e b`, which, given an
    `RErr` first argument, builds a new `RErr` from its list and otherwise
    calls `mapStep`;
  - `base : RStep String Int` and `idFunc : RStep String (Int -> Int)`, both
    `ROk`;
  - `r1 = applyR idFunc base` and `r2 = applyR idFunc r1`, both
    `RStep String Int`;
  - `testValue : Int`, a `case` on `r2` giving the `ROk` value or 0.

Every `RErr` the program builds therefore has the one type
`List String -> RStep String Int`.

What the tests establish:

  - `expectSuite` hands the module to the expectation function it is given; what
    is checked depends on that function.
  - `suite` runs `expectSuite` with `TestLogic.TestPipeline.expectMonomorphization`,
    and also asserts that the monomorphized graph's registry, its table of
    specializations, holds at most one specialization named `RErr`.

Among what is not tested: a program using `RErr` at more than one error type,
so that "one specialization per distinct `e`" is never checked beyond the
single `String` case; that `RErr` is specialized at all, since a count of zero
passes; and the `RErr` count under the solver engine, since `runToMono` uses
the substitution engine.

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


{-| The tests this module runs itself: the fixture through
`expectMonomorphization`, and the check that `RErr` has at most one
specialization.
-}
suite : Test
suite =
    Test.describe "Phantom type variable specialization"
        [ expectSuite expectMonomorphization "monomorphizes"
        , Test.test "RErr should not have duplicate specs from phantom type var" <|
            \_ -> assertNoPhantomDuplication ()
        ]


{-| Creates a test, named `"Phantom type var "` followed by `condStr`, that
passes when `expectFn` passes on the fixture module.
-}
expectSuite : (Src.Module -> Expectation) -> String -> Test
expectSuite expectFn condStr =
    Test.test ("Phantom type var " ++ condStr) <|
        \_ -> bulkCheck (testCases expectFn)


{-| Returns the one labelled case of this module, which applies `expectFn` to
the fixture module.
-}
testCases : (Src.Module -> Expectation) -> List TestCase
testCases expectFn =
    [ { label = "Phantom type var via mapStep/applyR"
      , run = \() -> expectFn phantomTestModule
      }
    ]


{-| The fixture module, `Test`, as the module docstring describes it.
-}
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


{-| Creates an expectation that monomorphizing the fixture module with
`TestLogic.TestPipeline.runToMono` succeeds and gives a registry in which at
most one specialization is named `RErr`.

The count covers every `Mono.Global` called `RErr`, whatever its module, and
skips removed entries. Since every `RErr` the fixture builds has the same type,
a count above one means `RErr` was specialized more than once for that type.

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
            if rerrCount > 1 then
                Expect.fail
                    ("RErr has "
                        ++ String.fromInt rerrCount
                        ++ " specializations but expected 1. "
                        ++ "Phantom type variable `a` is leaking into SpecKeys."
                    )

            else
                Expect.pass
