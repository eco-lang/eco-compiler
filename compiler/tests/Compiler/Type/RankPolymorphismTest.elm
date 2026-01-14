module Compiler.Type.RankPolymorphismTest exposing (suite)

{-| Test suite for invariant TYPE_005: Rank polymorphism is correctly handled.

-}

import Compiler.AST.SourceBuilder as SB
import Compiler.Type.RankPolymorphism exposing (expectRankPolymorphismValid)
import Test exposing (Test)


suite : Test
suite =
    Test.describe "Rank polymorphism is correctly handled (TYPE_005)"
        [ rankTests
        ]


rankTests : Test
rankTests =
    Test.describe "Rank polymorphism"
        [ Test.test "monomorphic let binding" <|
            \_ ->
                let
                    modul =
                        SB.makeModuleWithDefs "MonoLet"
                            [ ( "f"
                              , []
                              , SB.letExpr
                                    [ SB.define "x" [] (SB.intExpr 42) ]
                                    (SB.varExpr "x")
                              )
                            ]
                in
                expectRankPolymorphismValid modul
        , Test.test "polymorphic let binding used monomorphically" <|
            \_ ->
                let
                    modul =
                        SB.makeModuleWithDefs "PolyLet"
                            [ ( "f"
                              , []
                              , SB.letExpr
                                    [ SB.define "myId" [ SB.pVar "x" ] (SB.varExpr "x") ]
                                    (SB.callExpr (SB.varExpr "myId") [ SB.intExpr 42 ])
                              )
                            ]
                in
                expectRankPolymorphismValid modul
        , Test.test "simple function" <|
            \_ ->
                let
                    modul =
                        SB.makeModuleWithDefs "SimpleFunc"
                            [ ( "double"
                              , [ SB.pVar "x" ]
                              , SB.binopsExpr [ ( SB.varExpr "x", "+" ) ] (SB.varExpr "x")
                              )
                            ]
                in
                expectRankPolymorphismValid modul
        , Test.test "function composition" <|
            \_ ->
                let
                    modul =
                        SB.makeModuleWithDefs "Compose"
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
                expectRankPolymorphismValid modul
        ]
