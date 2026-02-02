module TestLogic.Canonicalize.DependencySCCTest exposing (suite)

{-| Test suite for invariant CANON\_005: Dependency SCCs are correctly computed.
-}

import Compiler.AST.SourceBuilder as SB
import Test exposing (Test)
import TestLogic.Canonicalize.DependencySCC exposing (expectValidSCCs)


suite : Test
suite =
    Test.describe "Dependency SCCs are correctly computed (CANON_005)"
        [ sccTests
        ]


sccTests : Test
sccTests =
    Test.describe "SCC computation"
        [ Test.test "independent definitions have separate SCCs" <|
            \_ ->
                let
                    modul =
                        SB.makeModuleWithDefs "Independent"
                            [ ( "a", [], SB.intExpr 1 )
                            , ( "b", [], SB.intExpr 2 )
                            , ( "c", [], SB.intExpr 3 )
                            ]
                in
                expectValidSCCs modul
        , Test.test "linear dependency chain" <|
            \_ ->
                let
                    modul =
                        SB.makeModuleWithDefs "Chain"
                            [ ( "a", [], SB.intExpr 1 )
                            , ( "b", [], SB.varExpr "a" )
                            , ( "c", [], SB.varExpr "b" )
                            ]
                in
                expectValidSCCs modul
        , Test.test "simple function dependency" <|
            \_ ->
                let
                    modul =
                        SB.makeModuleWithDefs "FnDep"
                            [ ( "helper", [ SB.pVar "x" ], SB.varExpr "x" )
                            , ( "result"
                              , []
                              , SB.callExpr (SB.varExpr "helper") [ SB.intExpr 42 ]
                              )
                            ]
                in
                expectValidSCCs modul
        ]
