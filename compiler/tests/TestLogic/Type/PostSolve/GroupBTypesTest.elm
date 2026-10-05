module TestLogic.Type.PostSolve.GroupBTypesTest exposing (suite)

{-| Tests that PostSolve types the string, character and float literals and
the unit values of small programs with their own types, in agreement with the
solver (POST\_001).

These tests run `TestLogic.Type.PostSolve.GroupBTypes.expectGroupBTypesValid`,
whose docstring says what it checks. Each program holds such literals in a
different context, so that the placeholder each literal is typed through is
tied to a different kind of expected type. Each test builds a module with
`Compiler.AST.SourceBuilder.makeModuleWithDefs`, whose top-level definitions
have no annotations and which imports only `Basics` and `List`:

  - "literals at top level" uses `s = "hi"`, `c = 'x'`, `f = 1.5` and
    `u = ()`.
  - "literals in containers" uses
    `pairs = [ ( "a", 'b' ), ( "c", 'd' ) ]` and `triple = ( 2.5, (), "e" )`.
  - "literals as call arguments and branches" uses `greet name = name` and
    `msg flag = if flag then greet "yes" else "no"`.
  - "literals in let and case" uses
    `g n = let z = 0.5 in case n of 0 -> ( z, "zero" ) _ -> ( 1.5, "other" )`.

Among what is not tested: shader literals, and annotated definitions.

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


{-| The four tests, each running one small module through PostSolve.
-}
groupBTests : Test
groupBTests =
    Test.describe "GroupB type resolution"
        [ Test.test "literals at top level" <|
            \_ ->
                SB.makeModuleWithDefs "TopLiterals"
                    [ ( "s", [], SB.strExpr "hi" )
                    , ( "c", [], SB.chrExpr "x" )
                    , ( "f", [], SB.floatExpr 1.5 )
                    , ( "u", [], SB.unitExpr )
                    ]
                    |> expectGroupBTypesValid
        , Test.test "literals in containers" <|
            \_ ->
                SB.makeModuleWithDefs "ContainerLiterals"
                    [ ( "pairs"
                      , []
                      , SB.listExpr
                            [ SB.tupleExpr (SB.strExpr "a") (SB.chrExpr "b")
                            , SB.tupleExpr (SB.strExpr "c") (SB.chrExpr "d")
                            ]
                      )
                    , ( "triple", [], SB.tuple3Expr (SB.floatExpr 2.5) SB.unitExpr (SB.strExpr "e") )
                    ]
                    |> expectGroupBTypesValid
        , Test.test "literals as call arguments and branches" <|
            \_ ->
                SB.makeModuleWithDefs "CallLiterals"
                    [ ( "greet", [ SB.pVar "name" ], SB.varExpr "name" )
                    , ( "msg"
                      , [ SB.pVar "flag" ]
                      , SB.ifExpr (SB.varExpr "flag")
                            (SB.callExpr (SB.varExpr "greet") [ SB.strExpr "yes" ])
                            (SB.strExpr "no")
                      )
                    ]
                    |> expectGroupBTypesValid
        , Test.test "literals in let and case" <|
            \_ ->
                SB.makeModuleWithDefs "LetCaseLiterals"
                    [ ( "g"
                      , [ SB.pVar "n" ]
                      , SB.letExpr [ SB.define "z" [] (SB.floatExpr 0.5) ]
                            (SB.caseExpr (SB.varExpr "n")
                                [ ( SB.pInt 0, SB.tupleExpr (SB.varExpr "z") (SB.strExpr "zero") )
                                , ( SB.pAnything, SB.tupleExpr (SB.floatExpr 1.5) (SB.strExpr "other") )
                                ]
                            )
                      )
                    ]
                    |> expectGroupBTypesValid
        ]
