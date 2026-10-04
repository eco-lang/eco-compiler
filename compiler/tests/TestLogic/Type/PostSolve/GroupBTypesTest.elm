module TestLogic.Type.PostSolve.GroupBTypesTest exposing (suite)

{-| Tests that the node types PostSolve leaves for two small programs hold no
type variable whose name starts with a digit.

These are the only tests in this suite that run
`TestLogic.Type.PostSolve.GroupBTypes.expectGroupBTypesValid`, whose
docstring says what it searches and which names it takes to be solver
placeholders. As that docstring says, no variable the solver names starts with
a digit, so a test here fails only when its program does not get through
PostSolve, or when a digit-named variable reaches a node type some other way.

Each test builds a module with `Compiler.AST.SourceBuilder.makeModuleWithDefs`,
whose top-level definitions have no annotations and which imports only
`Basics` and `List`, and passes it to `expectGroupBTypesValid`:

  - "simple function has resolved type" uses a module `SimpleFunc` with
    `add x y = x + y`.
  - "function calling another function" uses a module `CallChain` with
    `double x = x + x` and `quadruple x = double (double x)`.

Among what is not tested: any program with a string, character, float or unit
literal, or with a list, tuple, record, `case`, `let`, lambda or type
annotation.

-}

import Compiler.AST.SourceBuilder as SB
import Test exposing (Test)
import TestLogic.Type.PostSolve.GroupBTypes exposing (expectGroupBTypesValid)


{-| The PostSolve type-variable tests, under one label.
-}
suite : Test
suite =
    Test.describe "GroupB types are fully resolved (POST_001)"
        [ groupBTests
        ]


{-| The two tests, each running one small module through PostSolve.
-}
groupBTests : Test
groupBTests =
    Test.describe "GroupB type resolution"
        [ Test.test "simple function has resolved type" <|
            \_ ->
                let
                    modul =
                        SB.makeModuleWithDefs "SimpleFunc"
                            [ ( "add"
                              , [ SB.pVar "x", SB.pVar "y" ]
                              , SB.binopsExpr [ ( SB.varExpr "x", "+" ) ] (SB.varExpr "y")
                              )
                            ]
                in
                expectGroupBTypesValid modul
        , Test.test "function calling another function" <|
            \_ ->
                let
                    modul =
                        SB.makeModuleWithDefs "CallChain"
                            [ ( "double"
                              , [ SB.pVar "x" ]
                              , SB.binopsExpr [ ( SB.varExpr "x", "+" ) ] (SB.varExpr "x")
                              )
                            , ( "quadruple"
                              , [ SB.pVar "x" ]
                              , SB.callExpr (SB.varExpr "double")
                                    [ SB.callExpr (SB.varExpr "double") [ SB.varExpr "x" ] ]
                              )
                            ]
                in
                expectGroupBTypesValid modul
        ]
