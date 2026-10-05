module TestLogic.Canonicalize.CachedTypeInfoTest exposing (suite)

{-| Tests that catch type information recorded for a module that does not
match the module's source.

Each test builds a module and passes it to
`TestLogic.Canonicalize.CachedTypeInfo.expectTypeInfoCached`, whose docstring
states what it checks: every top-level definition has a closed annotation, and
an annotated definition's recorded type is its written type up to renaming of
type variables.

The tests in `typeInfoTests` use `Compiler.AST.SourceBuilder.makeModuleWithDefs`,
whose definitions carry no type annotations:

  - "simple typed value" runs a module whose one definition is `x = 42`.
  - "polymorphic function" runs a module whose one definition is `id x = x`.
  - "higher-order function" runs a module whose one definition is
    `apply f x = f x`.

The tests in `annotatedTests` use `makeModuleWithTypedDefs`, so the recorded
type is compared with a written one:

  - "annotated polymorphic functions" holds `id : a -> a` and
    `pair : a -> b -> ( a, b )`, two definitions in one module.
  - "annotated extensible record" holds `getX : { r | x : Int } -> Int`.

Among what is not tested:

  - the type found for an unannotated definition, beyond it being closed;
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
        , annotatedTests
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


{-| Two tests, each running a module of annotated definitions through
`expectTypeInfoCached`, which compares each recorded type with the written one.
-}
annotatedTests : Test
annotatedTests =
    Test.describe "Annotated definitions"
        [ Test.test "annotated polymorphic functions" <|
            \_ ->
                SB.makeModuleWithTypedDefs "AnnotatedPoly"
                    [ { name = "id"
                      , args = [ SB.pVar "x" ]
                      , tipe = SB.tLambda (SB.tVar "a") (SB.tVar "a")
                      , body = SB.varExpr "x"
                      }
                    , { name = "pair"
                      , args = [ SB.pVar "x", SB.pVar "y" ]
                      , tipe =
                            SB.tLambda (SB.tVar "a")
                                (SB.tLambda (SB.tVar "b") (SB.tTuple (SB.tVar "a") (SB.tVar "b")))
                      , body = SB.tupleExpr (SB.varExpr "x") (SB.varExpr "y")
                      }
                    ]
                    |> expectTypeInfoCached
        , Test.test "annotated extensible record" <|
            \_ ->
                SB.makeModuleWithTypedDefs "AnnotatedRecord"
                    [ { name = "getX"
                      , args = [ SB.pVar "r" ]
                      , tipe = SB.tLambda (SB.tExtRecord "r" [ ( "x", SB.tType "Int" [] ) ]) (SB.tType "Int" [])
                      , body = SB.accessExpr (SB.varExpr "r") "x"
                      }
                    ]
                    |> expectTypeInfoCached
        ]
