module TestLogic.Type.PostSolve.DeterminismTest exposing (suite)

{-| Test suite for invariant POST_004: Type inference is deterministic.

-}

import Compiler.AST.SourceBuilder as SB
import TestLogic.Type.PostSolve.Determinism exposing (expectDeterministicTypes)
import Test exposing (Test)


suite : Test
suite =
    Test.describe "Type inference is deterministic (POST_004)"
        [ determinismTests
        ]


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
