module TestLogic.Canonicalize.ImportResolutionTest exposing (suite)

{-| Tests that small modules importing `Basics` and `List` compile as far as
PostSolve, the pass after type checking that fixes up some of the types type
checking recorded for expression nodes, so that a change which stopped such a
module from canonicalizing or type checking would be noticed.

Canonicalization is the compiler stage that resolves each name a module uses to
the definition it refers to, including names taken from imports. The rule these
tests are named for is that this resolution succeeds. Each test hands one module
to `TestLogic.Canonicalize.ImportResolution.expectImportsResolved`, which
passes exactly when the module gets through canonicalization, type checking and
PostSolve; that module's docstring says what the expectation does and does not
check.

Every module is built with `Compiler.AST.SourceBuilder.makeModuleWithDefs`, so
it imports `Basics` and `List`, each exposing everything, and its top-level
definitions have no type annotations. No definition uses an imported name: each
body is a literal, a reference to an argument, or a call of another top-level
definition of the same module.

The tests establish:

  - "module without imports compiles": a module `NoImports` declaring
    `x = 42` passes. Despite the test's name, the module has the two imports
    every `makeModuleWithDefs` module has.
  - "simple function definition": a module `Simple` declaring `id x = x`
    passes.
  - "nested function calls": a module `Nested` declaring `f x = x` and
    `g y = f y` passes. Its one call is of `f` from `g`; no call is nested
    inside another.

Among what is not tested: a reference to an imported name, qualified or not; an
import with an alias or an explicit `exposing` list; an import of a module or a
name that does not exist; and any module whose resolution should fail.

-}

import Compiler.AST.SourceBuilder as SB
import Test exposing (Test)
import TestLogic.Canonicalize.ImportResolution exposing (expectImportsResolved)


{-| The suite of import resolution tests, which holds the one group
`validImportTests`.
-}
suite : Test
suite =
    Test.describe "Import resolution produces valid references (CANON_004)"
        [ validImportTests
        ]


{-| The tests of modules whose resolution is expected to succeed, one per
module, each passing when `expectImportsResolved` passes on its module.
-}
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
