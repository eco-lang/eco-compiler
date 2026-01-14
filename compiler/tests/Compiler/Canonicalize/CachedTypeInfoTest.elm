module Compiler.Canonicalize.CachedTypeInfoTest exposing (suite)

{-| Test suite for invariant CANON_006: Cached type info matches source.

-}

import Compiler.AST.SourceBuilder as SB
import Compiler.Canonicalize.CachedTypeInfo exposing (expectTypeInfoCached)
import Test exposing (Test)


suite : Test
suite =
    Test.describe "Cached type info matches source (CANON_006)"
        [ typeInfoTests
        ]


typeInfoTests : Test
typeInfoTests =
    Test.describe "Type info caching"
        [ Test.test "simple typed value" <|
            \_ ->
                let
                    modul =
                        SB.makeModuleWithDefs "TypedValue"
                            [ ( "x", [], SB.intExpr 42 ) ]
                in
                expectTypeInfoCached modul
        , Test.test "polymorphic function" <|
            \_ ->
                let
                    modul =
                        SB.makeModuleWithDefs "Polymorphic"
                            [ ( "id", [ SB.pVar "x" ], SB.varExpr "x" ) ]
                in
                expectTypeInfoCached modul
        , Test.test "higher-order function" <|
            \_ ->
                let
                    modul =
                        SB.makeModuleWithDefs "HigherOrder"
                            [ ( "apply"
                              , [ SB.pVar "f", SB.pVar "x" ]
                              , SB.callExpr (SB.varExpr "f") [ SB.varExpr "x" ]
                              )
                            ]
                in
                expectTypeInfoCached modul
        ]
