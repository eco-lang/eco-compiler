module Compiler.Type.PostSolve.GroupBTypesTest exposing (suite)

{-| Test suite for invariant POST_001: GroupB types are fully resolved.

-}

import Compiler.AST.SourceBuilder as SB
import Compiler.Type.PostSolve.GroupBTypes exposing (expectGroupBTypesValid)
import Test exposing (Test)


suite : Test
suite =
    Test.describe "GroupB types are fully resolved (POST_001)"
        [ groupBTests
        ]


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
