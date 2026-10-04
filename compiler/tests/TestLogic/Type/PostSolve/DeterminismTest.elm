module TestLogic.Type.PostSolve.DeterminismTest exposing (suite)

{-| Tests that compiling the same program twice, through PostSolve, gives the
same node types.

These are the only tests in this suite that run
`TestLogic.Type.PostSolve.Determinism.expectDeterministicTypes`, whose
docstring says what it compares and what it leaves out. Without them, no test
in the suite would compare the types that two runs give the same program.

Each test builds a small module with
`Compiler.AST.SourceBuilder.makeModuleWithDefs`, whose top-level definitions
have no annotations and which imports only `Basics` and `List`, and passes it
to `expectDeterministicTypes`:

  - "simple expression produces consistent type" uses a module `Simple` with
    one value, `x = 42`, an integer literal.
  - "complex expression produces consistent type" uses a module `Complex` with
    `max x y = if x > y then x else y`.
  - "function with multiple parameters" uses a module `MultiParam` with
    `addThree a b c = (a + b) + c`, where the inner sum is built as an operator
    chain nested inside the outer one rather than as a parenthesised
    expression.

Among what is not tested: any program with a string, character, float, list,
tuple, record, custom type declaration, `case`, `let`, lambda or type
annotation.

-}

import Compiler.AST.SourceBuilder as SB
import Test exposing (Test)
import TestLogic.Type.PostSolve.Determinism exposing (expectDeterministicTypes)


{-| The determinism tests, under one label.
-}
suite : Test
suite =
    Test.describe "Type inference is deterministic (POST_004)"
        [ determinismTests
        ]


{-| The three tests, each running one small module through PostSolve twice.
-}
determinismTests : Test
determinismTests =
    Test.describe "Deterministic type inference"
        [ Test.test "simple expression produces consistent type" <|
            \_ ->
                let
                    modul =
                        SB.makeModuleWithDefs "Simple"
                            [ ( "x", [], SB.intExpr 42 ) ]
                in
                expectDeterministicTypes modul
        , Test.test "complex expression produces consistent type" <|
            \_ ->
                let
                    modul =
                        SB.makeModuleWithDefs "Complex"
                            [ ( "max"
                              , [ SB.pVar "x", SB.pVar "y" ]
                              , SB.ifExpr
                                    (SB.binopsExpr [ ( SB.varExpr "x", ">" ) ] (SB.varExpr "y"))
                                    (SB.varExpr "x")
                                    (SB.varExpr "y")
                              )
                            ]
                in
                expectDeterministicTypes modul
        , Test.test "function with multiple parameters" <|
            \_ ->
                let
                    modul =
                        SB.makeModuleWithDefs "MultiParam"
                            [ ( "addThree"
                              , [ SB.pVar "a", SB.pVar "b", SB.pVar "c" ]
                              , SB.binopsExpr
                                    [ ( SB.binopsExpr [ ( SB.varExpr "a", "+" ) ] (SB.varExpr "b"), "+" ) ]
                                    (SB.varExpr "c")
                              )
                            ]
                in
                expectDeterministicTypes modul
        ]
