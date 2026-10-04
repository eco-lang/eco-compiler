module TestLogic.Canonicalize.CachedTypeInfoTest exposing (suite)

{-| Tests meant to catch type information recorded for a module that does not
match the module's source. What they can catch is narrower: one of three small
modules failing to get through the front end of the compiler.

Each test builds a module with `Compiler.AST.SourceBuilder.makeModuleWithDefs`,
whose definitions carry no type annotations, and passes it to
`TestLogic.Canonicalize.CachedTypeInfo.expectTypeInfoCached`, whose docstring
states what it checks. What that means here is that a test passes
when its module gets through canonicalization, type checking and the PostSolve
pass that follows type checking, and fails when one of those stages fails.

The tests, all in `typeInfoTests`:

  - "simple typed value" runs a module whose one definition is `x = 42`.
  - "polymorphic function" runs a module whose one definition is `id x = x`.
  - "higher-order function" runs a module whose one definition is
    `apply f x = f x`.

Among what is not tested:

  - the type found for any definition, so `id` is not shown to be polymorphic;
  - a definition with a type annotation;
  - a module with more than one definition;
  - type information saved to or read back from disk.

-}

import Compiler.AST.SourceBuilder as SB
import Test exposing (Test)
import TestLogic.Canonicalize.CachedTypeInfo exposing (expectTypeInfoCached)


{-| The tests of this module, under one label.
-}
suite : Test
suite =
    Test.describe "Cached type info matches source (CANON_006)"
        [ typeInfoTests
        ]


{-| Three tests, each running a module of one unannotated definition through
`expectTypeInfoCached`.
-}
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
