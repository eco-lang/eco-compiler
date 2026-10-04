module TestLogic.Type.AnnotationEnforcementTest exposing (suite)

{-| Tests that the type checker holds a definition to its type annotation.
Without them, a checker that ignored annotations and kept only the types it
inferred would go unnoticed, and a wrong annotation would be accepted.

Each test builds a module holding one annotated top-level definition with
`Compiler.AST.SourceBuilder.makeModuleWithTypedDefs`, and hands it to an
expectation from `TestLogic.Type.AnnotationEnforcement`, which canonicalizes
the module and runs constraint generation and the solver, and nothing after.
The numeric bodies are integer literals, whose own type is the constrained
`number`; an `Int` annotation fixes it, and a `String` annotation contradicts
it.

The matching tests each hand their module to
`expectMatchingAnnotationSucceeds`, which requires no type error:

  - `x : Int` with body `42`.
  - `s : String` with body `"hello"`.
  - `f : Int -> Int` with `f x = x`, an annotation more specific than the body
    requires.
  - `xs : List Int` with body `[ 1, 2 ]`.
  - `pair : ( Int, String )` with body `( 1, "a" )`.

The mismatch tests each hand their module to `expectAnnotationMismatchError`,
which requires at least one type error of any kind:

  - `x : Int` with body `"hello"`.
  - `x : String` with body `42`.
  - `f : Int -> String` with `f x = x`, which returns its `Int` argument.
  - `xs : List String` with body `[ 1 ]`.
  - `pair : ( String, Int )` with body `( 1, "a" )`, the element types the
    other way round.

A mismatch test therefore shows that the module canonicalizes and then fails to
type-check, not that the error it produces concerns the annotation.

Among what is not tested: type variables in annotations, records and custom
types, annotations on let-bound definitions, modules with more than one
definition, and what a mismatch error reports.

-}

import Compiler.AST.SourceBuilder as SB
import Test exposing (Test)
import TestLogic.Type.AnnotationEnforcement
    exposing
        ( expectAnnotationMismatchError
        , expectMatchingAnnotationSucceeds
        )


{-| The tests that annotations are enforced: the matching-annotation tests, then
the mismatched-annotation tests.
-}
suite : Test
suite =
    Test.describe "Annotations are enforced, not ignored (TYPE_006)"
        [ matchingAnnotationTests
        , mismatchedAnnotationTests
        ]


{-| Five tests, each giving one definition an annotation its body agrees with
and expecting the module to type-check with no errors.
-}
matchingAnnotationTests : Test
matchingAnnotationTests =
    Test.describe "Matching annotations succeed"
        [ Test.test "Int annotation on Int value" <|
            \_ ->
                let
                    modul =
                        SB.makeModuleWithTypedDefs "MatchInt"
                            [ { name = "x"
                              , args = []
                              , tipe = SB.tType "Int" []
                              , body = SB.intExpr 42
                              }
                            ]
                in
                expectMatchingAnnotationSucceeds modul
        , Test.test "String annotation on String value" <|
            \_ ->
                let
                    modul =
                        SB.makeModuleWithTypedDefs "MatchString"
                            [ { name = "s"
                              , args = []
                              , tipe = SB.tType "String" []
                              , body = SB.strExpr "hello"
                              }
                            ]
                in
                expectMatchingAnnotationSucceeds modul
        , Test.test "function annotation on function" <|
            \_ ->
                let
                    modul =
                        SB.makeModuleWithTypedDefs "MatchFunc"
                            [ { name = "f"
                              , args = [ SB.pVar "x" ]
                              , tipe =
                                    SB.tLambda
                                        (SB.tType "Int" [])
                                        (SB.tType "Int" [])
                              , body = SB.varExpr "x"
                              }
                            ]
                in
                expectMatchingAnnotationSucceeds modul
        , Test.test "List Int annotation on list of ints" <|
            \_ ->
                let
                    modul =
                        SB.makeModuleWithTypedDefs "MatchList"
                            [ { name = "xs"
                              , args = []
                              , tipe =
                                    SB.tType "List"
                                        [ SB.tType "Int" [] ]
                              , body = SB.listExpr [ SB.intExpr 1, SB.intExpr 2 ]
                              }
                            ]
                in
                expectMatchingAnnotationSucceeds modul
        , Test.test "tuple annotation on tuple" <|
            \_ ->
                let
                    modul =
                        SB.makeModuleWithTypedDefs "MatchTuple"
                            [ { name = "pair"
                              , args = []
                              , tipe =
                                    SB.tTuple
                                        (SB.tType "Int" [])
                                        (SB.tType "String" [])
                              , body = SB.tupleExpr (SB.intExpr 1) (SB.strExpr "a")
                              }
                            ]
                in
                expectMatchingAnnotationSucceeds modul
        ]


{-| Five tests, each giving one definition an annotation its body contradicts
and expecting the module to fail to type-check, with any type error.
-}
mismatchedAnnotationTests : Test
mismatchedAnnotationTests =
    Test.describe "Mismatched annotations produce errors"
        [ Test.test "Int annotation on String value" <|
            \_ ->
                let
                    modul =
                        SB.makeModuleWithTypedDefs "MismatchIntStr"
                            [ { name = "x"
                              , args = []
                              , tipe = SB.tType "Int" []
                              , body = SB.strExpr "hello"
                              }
                            ]
                in
                expectAnnotationMismatchError modul
        , Test.test "String annotation on Int value" <|
            \_ ->
                let
                    modul =
                        SB.makeModuleWithTypedDefs "MismatchStrInt"
                            [ { name = "x"
                              , args = []
                              , tipe = SB.tType "String" []
                              , body = SB.intExpr 42
                              }
                            ]
                in
                expectAnnotationMismatchError modul
        , Test.test "wrong function return type" <|
            \_ ->
                let
                    modul =
                        SB.makeModuleWithTypedDefs "MismatchFuncReturn"
                            [ { name = "f"
                              , args = [ SB.pVar "x" ]
                              , tipe =
                                    SB.tLambda
                                        (SB.tType "Int" [])
                                        (SB.tType "String" [])
                              , body = SB.varExpr "x" -- Returns Int, not String
                              }
                            ]
                in
                expectAnnotationMismatchError modul
        , Test.test "wrong list element type" <|
            \_ ->
                let
                    modul =
                        SB.makeModuleWithTypedDefs "MismatchListElem"
                            [ { name = "xs"
                              , args = []
                              , tipe =
                                    SB.tType "List"
                                        [ SB.tType "String" [] ]
                              , body = SB.listExpr [ SB.intExpr 1 ] -- integer literals, not strings
                              }
                            ]
                in
                expectAnnotationMismatchError modul
        , Test.test "wrong tuple element type" <|
            \_ ->
                let
                    modul =
                        SB.makeModuleWithTypedDefs "MismatchTupleElem"
                            [ { name = "pair"
                              , args = []
                              , tipe =
                                    SB.tTuple
                                        (SB.tType "String" [])
                                        (SB.tType "Int" [])
                              , body = SB.tupleExpr (SB.intExpr 1) (SB.strExpr "a") -- element types swapped
                              }
                            ]
                in
                expectAnnotationMismatchError modul
        ]
