module TestLogic.Canonicalize.ImportResolutionTest exposing (suite)

{-| Test suite for invariant CANON\_004: Import resolution produces valid references.
-}

import Compiler.AST.SourceBuilder as SB
import Test exposing (Test)
import TestLogic.Canonicalize.ImportResolution exposing (expectImportsResolved)


suite : Test
suite =
    Test.describe "Import resolution produces valid references (CANON_004)"
        [ validImportTests
        ]


validImportTests : Test
validImportTests =
    Test.describe "Valid import resolution"
        [ Test.test "module without imports compiles" <|
            \_ ->
                let
                    modul =
                        SB.makeModuleWithDefs "NoImports"
                            [ ( "x", [], SB.intExpr 42 ) ]
                in
                expectImportsResolved modul
        , Test.test "simple function definition" <|
            \_ ->
                let
                    modul =
                        SB.makeModuleWithDefs "Simple"
                            [ ( "id", [ SB.pVar "x" ], SB.varExpr "x" ) ]
                in
                expectImportsResolved modul
        , Test.test "nested function calls" <|
            \_ ->
                let
                    modul =
                        SB.makeModuleWithDefs "Nested"
                            [ ( "f", [ SB.pVar "x" ], SB.varExpr "x" )
                            , ( "g", [ SB.pVar "y" ], SB.callExpr (SB.varExpr "f") [ SB.varExpr "y" ] )
                            ]
                in
                expectImportsResolved modul
        ]
