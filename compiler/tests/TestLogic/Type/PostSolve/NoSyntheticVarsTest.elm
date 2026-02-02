module TestLogic.Type.PostSolve.NoSyntheticVarsTest exposing (suite)

{-| Test suite for invariant POST\_003: No synthetic type variables remain.
-}

import Compiler.AST.SourceBuilder as SB
import Test exposing (Test)
import TestLogic.Type.PostSolve.NoSyntheticVars exposing (expectNoSyntheticVars)


suite : Test
suite =
    Test.describe "No synthetic type variables remain (POST_003)"
        [ syntheticVarTests
        ]


syntheticVarTests : Test
syntheticVarTests =
    Test.describe "Synthetic variable elimination"
        [ Test.test "fully constrained expression has no synthetic vars" <|
            \_ ->
                let
                    modul =
                        SB.makeModuleWithDefs "FullyConstrained"
                            [ ( "x"
                              , []
                              , SB.binopsExpr [ ( SB.intExpr 1, "+" ) ] (SB.intExpr 2)
                              )
                            ]
                in
                expectNoSyntheticVars modul
        , Test.test "polymorphic function generalizes properly" <|
            \_ ->
                let
                    modul =
                        SB.makeModuleWithDefs "Polymorphic"
                            [ ( "id", [ SB.pVar "x" ], SB.varExpr "x" ) ]
                in
                expectNoSyntheticVars modul
        , Test.test "nested let with type propagation" <|
            \_ ->
                let
                    modul =
                        SB.makeModuleWithDefs "NestedLet"
                            [ ( "f"
                              , []
                              , SB.letExpr
                                    [ SB.define "x" [] (SB.intExpr 1) ]
                                    (SB.letExpr
                                        [ SB.define "y" [] (SB.varExpr "x") ]
                                        (SB.varExpr "y")
                                    )
                              )
                            ]
                in
                expectNoSyntheticVars modul
        ]
