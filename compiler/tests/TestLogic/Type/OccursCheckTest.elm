module TestLogic.Type.OccursCheckTest exposing (suite)

{-| Tests that a definition whose type would have to contain itself is rejected,
and that three definitions that have ordinary types are accepted.
Without them, a front end that let an infinite type through, or one that
rejected an ordinary definition, would go unnoticed. The suite labels the
property TYPE\_004.

A type is _infinite_ when a type variable would have to equal a type containing
that same variable, so that no finite type satisfies the equation. The check
that refuses one is the _occurs check_ (`Compiler.Type.Occurs`).

Each test builds a one-module program with
`Compiler.AST.SourceBuilder.makeModuleWithDefs`: unannotated top-level
definitions, importing `Basics` and `List`. The expectations come from
`TestLogic.Type.OccursCheck` and run the program through canonicalization,
type checking and PostSolve.

  - "self-referential through function application" builds module `SelfRef`
    defining `f x = f`. `expectInfiniteTypeDetected` passes when the module
    fails to canonicalize or type check, without looking at the error.
  - "simple identity function" (`id x = x`), "composition function"
    (`compose f g x = f (g x)`) and "nested data structures"
    (`nested = [ ( 1, "a" ), ( 2, "b" ) ]`) each pass under
    `expectNoInfiniteTypes` when the module gets through PostSolve. That
    expectation's walk of the node types never reports anything, so these tests
    check only that the module is accepted.

Among what is not tested: that the rejection of `f x = f` is an infinite-type
error rather than some other error, the name such an error carries, infinite
types arising in a `let` or a lambda, and annotated definitions.

-}

import Compiler.AST.SourceBuilder as SB
import Test exposing (Test)
import TestLogic.Type.OccursCheck exposing (expectInfiniteTypeDetected, expectNoInfiniteTypes)


{-| The occurs-check tests: one program that must be rejected and three that
must be accepted.
-}
suite : Test
suite =
    Test.describe "Occurs check forbids infinite types (TYPE_004)"
        [ infiniteTypeTests
        , validTypeTests
        ]


{-| The test that `f x = f` is rejected. The test passes when the module fails
to canonicalize or type check, for any reason.
-}
infiniteTypeTests : Test
infiniteTypeTests =
    Test.describe "Infinite type detection"
        [ -- f's result type is f's own type: f : a -> (a -> (a -> ...)).
          Test.test "self-referential through function application" <|
            \_ ->
                let
                    modul =
                        SB.makeModuleWithDefs "SelfRef"
                            [ ( "f"
                              , [ SB.pVar "x" ]
                              , SB.varExpr "f"
                              )
                            ]
                in
                expectInfiniteTypeDetected modul
        ]


{-| The tests that three definitions with ordinary types, `id`, `compose` and a
list of tuples, get through PostSolve.
-}
validTypeTests : Test
validTypeTests =
    Test.describe "Valid types without cycles"
        [ Test.test "simple identity function" <|
            \_ ->
                let
                    modul =
                        SB.makeModuleWithDefs "Identity"
                            [ ( "id", [ SB.pVar "x" ], SB.varExpr "x" ) ]
                in
                expectNoInfiniteTypes modul
        , Test.test "composition function" <|
            \_ ->
                let
                    modul =
                        SB.makeModuleWithDefs "Compose"
                            [ ( "compose"
                              , [ SB.pVar "f", SB.pVar "g", SB.pVar "x" ]
                              , SB.callExpr (SB.varExpr "f")
                                    [ SB.callExpr (SB.varExpr "g") [ SB.varExpr "x" ] ]
                              )
                            ]
                in
                expectNoInfiniteTypes modul
        , Test.test "nested data structures" <|
            \_ ->
                let
                    modul =
                        SB.makeModuleWithDefs "Nested"
                            [ ( "nested"
                              , []
                              , SB.listExpr
                                    [ SB.tupleExpr (SB.intExpr 1) (SB.strExpr "a")
                                    , SB.tupleExpr (SB.intExpr 2) (SB.strExpr "b")
                                    ]
                              )
                            ]
                in
                expectNoInfiniteTypes modul
        ]
