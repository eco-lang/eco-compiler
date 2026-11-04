module SourceIR.RejectionControlCases exposing (expectSuite)

{-| Programs that must compile although each is close to one the compiler
rejects: the valid controls of the tests whose rejected programs moved to the
negative catalogue (`SourceIR.Suite.RejectedSuites`). In the standard
catalogue they show that the compiler does not reject too much: a check that
expects acceptance runs on each, and the oracles of
`TestLogic.Canonicalize.NameClashesTest` and `SizeLimitsTest` see the names and
sizes they hold.

This module only builds the programs and asserts nothing itself. `expectSuite`
runs a caller's expectation over them in turn, stopping at the first that fails,
so what is checked, and at which stage of the compiler, is up to the caller.

Each program is a module built with `Compiler.AST.SourceBuilder` that defines
`testValue`. Where the original control had no `testValue`, one is added that
uses the control's definitions. The cases, by where they come from:

  - Names (from the former `Compiler.Canonicalize.DuplicateDeclsTest`): three
    distinct top-level values; two top-level values that each bind a local `x`
    in a `let`.
  - Unification (from the former `Compiler.Type.UnificationErrorsTest`): a
    list of three integer literals; `if True then 1 else 2`; `f x = x` applied
    to `42`; `(1, 2) < (3, 4)`; `("a", 1) < ("b", 2)`.
  - Finite types (from the former `Compiler.Type.OccursCheckTest`): `id`,
    `compose` and a list of tuples.
  - Annotations (from the former `Compiler.Type.AnnotationEnforcementTest`):
    `x : Int` with `42`, `s : String` with `"hello"`, `f : Int -> Int` with
    `f x = x`, `xs : List Int` with `[ 1, 2 ]` and `pair : ( Int, String )` with
    `( 1, "a" )`.
  - Finite polymorphism (from the former polymorphic-recursion tests of
    `Compiler.Monomorphize.Solver.EngineSpecWatchdogTest`): `wrapTwice`
    recurses at its own type and calls the polymorphic `size` at `List a`, and
    `count` is used at several unrelated types, one of them a list of another.

The at-limit controls of `Compiler.Canonicalize.LimitErrorsTest` are not here
but in `SourceIR.LimitBoundaryCases`, which only the size-limit oracle runs:
the checks of the standard catalogue on a function of 2047 parameters ran for
more than four minutes, and one test worker grew to about 11 GB, before the
run was stopped.

-}

import Compiler.AST.SourceBuilder as SB
import Compiler.BulkCheck exposing (TestCase, bulkCheck)
import Compiler.IR.Source as Src
import Expect exposing (Expectation)
import Test exposing (Test)


{-| Builds one test, named "Rejection control cases " followed by `condStr`,
that applies `expectFn` to every program in this module in turn. It fails with
the label of the first program whose expectation fails, and later programs are
not run.
-}
expectSuite : (Src.Module -> Expectation) -> String -> Test
expectSuite expectFn condStr =
    Test.test ("Rejection control cases " ++ condStr) <|
        \_ -> bulkCheck (testCases expectFn)


{-| Returns every case in this module, each applying `expectFn` to its program.
-}
testCases : (Src.Module -> Expectation) -> List TestCase
testCases expectFn =
    List.map (\( label, build ) -> { label = label, run = \_ -> expectFn (build ()) })
        (nameCases ++ unificationCases ++ finiteTypeCases ++ annotationCases ++ polymorphismCases)


{-| Programs whose names are distinct within each scope.
-}
nameCases : List ( String, () -> Src.Module )
nameCases =
    [ ( "distinct declarations"
      , \() ->
            SB.makeModuleWithDefs "Valid"
                [ ( "foo", [], SB.intExpr 1 )
                , ( "bar", [], SB.intExpr 2 )
                , ( "baz", [], SB.intExpr 3 )
                , ( "testValue", [], SB.binopsExpr [ ( SB.varExpr "foo", "+" ), ( SB.varExpr "bar", "+" ) ] (SB.varExpr "baz") )
                ]
      )
    , ( "same name in different scopes"
      , \() ->
            SB.makeModuleWithDefs "ScopedNames"
                [ ( "foo", [], SB.letExpr [ SB.define "x" [] (SB.intExpr 1) ] (SB.varExpr "x") )
                , ( "bar", [], SB.letExpr [ SB.define "x" [] (SB.intExpr 2) ] (SB.varExpr "x") )
                , ( "testValue", [], SB.binopsExpr [ ( SB.varExpr "foo", "+" ) ] (SB.varExpr "bar") )
                ]
      )
    ]


{-| Well-typed programs whose shapes the unification failures share.
-}
unificationCases : List ( String, () -> Src.Module )
unificationCases =
    [ ( "homogeneous list"
      , \() -> SB.makeModuleWithDefs "ValidList" [ ( "testValue", [], SB.listExpr [ SB.intExpr 1, SB.intExpr 2, SB.intExpr 3 ] ) ]
      )
    , ( "valid if expression"
      , \() -> SB.makeModuleWithDefs "ValidIf" [ ( "testValue", [], SB.ifExpr (SB.boolExpr True) (SB.intExpr 1) (SB.intExpr 2) ) ]
      )
    , ( "valid function application"
      , \() ->
            SB.makeModuleWithDefs "ValidApp"
                [ ( "f", [ SB.pVar "x" ], SB.varExpr "x" )
                , ( "testValue", [], SB.callExpr (SB.varExpr "f") [ SB.intExpr 42 ] )
                ]
      )
    , ( "comparable tuple with all comparable elements"
      , \() ->
            SB.makeModuleWithDefs "TupleCompValid"
                [ ( "testValue"
                  , []
                  , SB.binopsExpr [ ( SB.tupleExpr (SB.intExpr 1) (SB.intExpr 2), "<" ) ] (SB.tupleExpr (SB.intExpr 3) (SB.intExpr 4))
                  )
                ]
      )
    , ( "comparable tuple with mixed comparable elements"
      , \() ->
            SB.makeModuleWithDefs "TupleCompMixedValid"
                [ ( "testValue"
                  , []
                  , SB.binopsExpr [ ( SB.tupleExpr (SB.strExpr "a") (SB.intExpr 1), "<" ) ] (SB.tupleExpr (SB.strExpr "b") (SB.intExpr 2))
                  )
                ]
      )
    ]


{-| Definitions with ordinary types, against which the occurs check must not
fire.
-}
finiteTypeCases : List ( String, () -> Src.Module )
finiteTypeCases =
    [ ( "simple identity function"
      , \() ->
            SB.makeModuleWithDefs "Identity"
                [ ( "id", [ SB.pVar "x" ], SB.varExpr "x" )
                , ( "testValue", [], SB.callExpr (SB.varExpr "id") [ SB.intExpr 1 ] )
                ]
      )
    , ( "composition function"
      , \() ->
            SB.makeModuleWithDefs "Compose"
                [ ( "compose"
                  , [ SB.pVar "f", SB.pVar "g", SB.pVar "x" ]
                  , SB.callExpr (SB.varExpr "f") [ SB.callExpr (SB.varExpr "g") [ SB.varExpr "x" ] ]
                  )
                , ( "testValue"
                  , []
                  , SB.callExpr (SB.varExpr "compose")
                        [ SB.lambdaExpr [ SB.pVar "a" ] (SB.binopsExpr [ ( SB.varExpr "a", "+" ) ] (SB.intExpr 1))
                        , SB.lambdaExpr [ SB.pVar "b" ] (SB.binopsExpr [ ( SB.varExpr "b", "*" ) ] (SB.intExpr 2))
                        , SB.intExpr 3
                        ]
                  )
                ]
      )
    , ( "nested data structures"
      , \() ->
            SB.makeModuleWithDefs "Nested"
                [ ( "testValue"
                  , []
                  , SB.listExpr
                        [ SB.tupleExpr (SB.intExpr 1) (SB.strExpr "a")
                        , SB.tupleExpr (SB.intExpr 2) (SB.strExpr "b")
                        ]
                  )
                ]
      )
    ]


{-| One annotated definition each, whose body agrees with the annotation.
-}
annotationCases : List ( String, () -> Src.Module )
annotationCases =
    [ ( "Int annotation on Int value"
      , \() -> annotatedWithTestValue "MatchInt" "x" [] (SB.tType "Int" []) (SB.intExpr 42) (SB.varExpr "x")
      )
    , ( "String annotation on String value"
      , \() -> annotatedWithTestValue "MatchString" "s" [] (SB.tType "String" []) (SB.strExpr "hello") (SB.varExpr "s")
      )
    , ( "function annotation on function"
      , \() ->
            annotatedWithTestValue "MatchFunc"
                "f"
                [ SB.pVar "x" ]
                (SB.tLambda (SB.tType "Int" []) (SB.tType "Int" []))
                (SB.varExpr "x")
                (SB.callExpr (SB.varExpr "f") [ SB.intExpr 1 ])
      )
    , ( "List Int annotation on list of ints"
      , \() -> annotatedWithTestValue "MatchList" "xs" [] (SB.tType "List" [ SB.tType "Int" [] ]) (SB.listExpr [ SB.intExpr 1, SB.intExpr 2 ]) (SB.varExpr "xs")
      )
    , ( "tuple annotation on tuple"
      , \() ->
            annotatedWithTestValue "MatchTuple"
                "pair"
                []
                (SB.tTuple (SB.tType "Int" []) (SB.tType "String" []))
                (SB.tupleExpr (SB.intExpr 1) (SB.strExpr "a"))
                (SB.varExpr "pair")
      )
    ]


{-| A module holding the definition `name`, with parameters `args`, annotation
`tipe` and body `body`, and an unannotated `testValue` equal to `use`.
-}
annotatedWithTestValue : String -> String -> List Src.Pattern -> Src.Type -> Src.Expr -> Src.Expr -> Src.Module
annotatedWithTestValue moduleName name args tipe body use =
    SB.makeModuleWithTypedDefs moduleName
        [ { name = name, args = args, tipe = tipe, body = body } ]
        |> withValue "testValue" use


{-| Polymorphism with a finite set of specializations, which the solver
engine's polymorphic-recursion check must accept. As Elm:

    size : List b -> Int
    size xs =
        List.length xs

    wrapTwice : Int -> a -> Int
    wrapTwice n x =
        case n of
            0 ->
                size [ x, x ]

            _ ->
                wrapTwice (n - 1) x

    count : a -> Int
    count _ =
        1

    testValue : Int
    testValue =
        wrapTwice 3 1 + wrapTwice 2 "s" + count 1 + count [ 1 ] + count [ [ 1 ] ] + count "s"

-}
polymorphismCases : List ( String, () -> Src.Module )
polymorphismCases =
    [ ( "finite polymorphism"
      , \() ->
            SB.makeModuleWithTypedDefsUnionsAliases "Test"
                [ { name = "size"
                  , args = [ SB.pVar "xs" ]
                  , tipe = SB.tLambda (SB.tType "List" [ SB.tVar "b" ]) (SB.tType "Int" [])
                  , body = SB.callExpr (SB.qualVarExpr "List" "length") [ SB.varExpr "xs" ]
                  }
                , { name = "wrapTwice"
                  , args = [ SB.pVar "n", SB.pVar "x" ]
                  , tipe = SB.tLambda (SB.tType "Int" []) (SB.tLambda (SB.tVar "a") (SB.tType "Int" []))
                  , body =
                        SB.caseExpr (SB.varExpr "n")
                            [ ( SB.pInt 0, SB.callExpr (SB.varExpr "size") [ SB.listExpr [ SB.varExpr "x", SB.varExpr "x" ] ] )
                            , ( SB.pAnything
                              , SB.callExpr (SB.varExpr "wrapTwice")
                                    [ SB.parensExpr (SB.binopsExpr [ ( SB.varExpr "n", "-" ) ] (SB.intExpr 1)), SB.varExpr "x" ]
                              )
                            ]
                  }
                , { name = "count"
                  , args = [ SB.pAnything ]
                  , tipe = SB.tLambda (SB.tVar "a") (SB.tType "Int" [])
                  , body = SB.intExpr 1
                  }
                , { name = "testValue"
                  , args = []
                  , tipe = SB.tType "Int" []
                  , body =
                        SB.binopsExpr
                            [ ( SB.callExpr (SB.varExpr "wrapTwice") [ SB.intExpr 3, SB.intExpr 1 ], "+" )
                            , ( SB.callExpr (SB.varExpr "wrapTwice") [ SB.intExpr 2, SB.strExpr "s" ], "+" )
                            , ( SB.callExpr (SB.varExpr "count") [ SB.intExpr 1 ], "+" )
                            , ( SB.callExpr (SB.varExpr "count") [ SB.listExpr [ SB.intExpr 1 ] ], "+" )
                            , ( SB.callExpr (SB.varExpr "count") [ SB.listExpr [ SB.listExpr [ SB.intExpr 1 ] ] ], "+" )
                            ]
                            (SB.callExpr (SB.varExpr "count") [ SB.strExpr "s" ])
                  }
                ]
                []
                []
      )
    ]


{-| `srcModule` with an unannotated top-level value `name` equal to `body`
appended.
-}
withValue : String -> Src.Expr -> Src.Module -> Src.Module
withValue name body (Src.Module data) =
    let
        (Src.Module template) =
            SB.makeModuleWithDefs "unused" [ ( name, [], body ) ]
    in
    Src.Module { data | values = data.values ++ template.values }
