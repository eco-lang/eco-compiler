module TestLogic.Generate.DebugPolymorphismTest exposing (suite)

{-| Test suite for invariant MONO\_009: Debug.\* kernel functions handle polymorphism.
-}

import Compiler.AST.SourceBuilder as SB
import Test exposing (Test)
import TestLogic.Generate.DebugPolymorphism exposing (expectDebugPolymorphismResolved)


suite : Test
suite =
    Test.describe "Debug kernel functions handle polymorphism (MONO_009)"
        [ debugTests
        ]


debugTests : Test
debugTests =
    Test.describe "Debug polymorphism resolution"
        [ Test.test "monomorphic Int value" <|
            \_ ->
                let
                    modul =
                        SB.makeModuleWithDefs "MonoInt"
                            [ ( "x", [], SB.intExpr 42 )
                            , ( "testValue", [], SB.varExpr "x" )
                            ]
                in
                expectDebugPolymorphismResolved modul
        , Test.test "monomorphic String value" <|
            \_ ->
                let
                    modul =
                        SB.makeModuleWithDefs "MonoStr"
                            [ ( "x", [], SB.strExpr "hello" )
                            , ( "testValue", [], SB.varExpr "x" )
                            ]
                in
                expectDebugPolymorphismResolved modul
        , Test.test "monomorphic function" <|
            \_ ->
                let
                    modul =
                        SB.makeModuleWithDefs "MonoFunc"
                            [ ( "double"
                              , [ SB.pVar "x" ]
                              , SB.binopsExpr [ ( SB.varExpr "x", "+" ) ] (SB.varExpr "x")
                              )
                            , ( "testValue", [], SB.callExpr (SB.varExpr "double") [ SB.intExpr 5 ] )
                            ]
                in
                expectDebugPolymorphismResolved modul
        , Test.test "list of integers" <|
            \_ ->
                let
                    modul =
                        SB.makeModuleWithDefs "IntList"
                            [ ( "xs", [], SB.listExpr [ SB.intExpr 1, SB.intExpr 2, SB.intExpr 3 ] )
                            , ( "testValue", [], SB.varExpr "xs" )
                            ]
                in
                expectDebugPolymorphismResolved modul
        ]
