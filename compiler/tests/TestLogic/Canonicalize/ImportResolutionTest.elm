module TestLogic.Canonicalize.ImportResolutionTest exposing (suite)

{-| Tests that the references a module takes from its imports resolve to
definitions of the imported modules, so that a change which resolved an
imported name to the wrong module, name, constructor or operator would be
noticed.

Canonicalization is the compiler stage that resolves each name a module uses to
the definition it refers to, including names taken from imports. Each test hands
one module to `TestLogic.Canonicalize.ImportResolution.expectImportsResolved`,
which runs it through PostSolve and then checks every reference to another
module against that module's interface; that module's docstring says what it
checks.

Every module is built with `Compiler.AST.SourceBuilder.makeModuleWithDefs`, so
it imports `Basics` and `List`, each exposing everything, and its top-level
definitions have no type annotations.

The tests establish:

  - "module with no foreign references": a module `NoImports` declaring
    `x = 42` passes.
  - "local function calls": a module `Nested` declaring `f x = x` and
    `g y = f y` passes.
  - "qualified imported function": `xs = List.map negate [ 1, 2 ]`, a
    qualified and an unqualified `VarForeign`.
  - "imported operators": `n = 1 + 2 * 3` and `ys = 1 :: []`, `Binop`s of
    `Basics` and `List`.
  - "imported constructor": `t = True`, a `VarCtor` of `Basics`.

Among what is not tested: an import with an alias or an explicit `exposing`
list; an import of a module or a name that does not exist; and any module
whose resolution should fail.

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
        [ Test.test "module with no foreign references" <|
            \_ ->
                SB.makeModuleWithDefs "NoImports" [ ( "x", [], SB.intExpr 42 ) ]
                    |> expectImportsResolved
        , Test.test "local function calls" <|
            \_ ->
                SB.makeModuleWithDefs "Nested"
                    [ ( "f", [ SB.pVar "x" ], SB.varExpr "x" )
                    , ( "g", [ SB.pVar "y" ], SB.callExpr (SB.varExpr "f") [ SB.varExpr "y" ] )
                    ]
                    |> expectImportsResolved
        , Test.test "qualified imported function" <|
            \_ ->
                SB.makeModuleWithDefs "QualifiedFn"
                    [ ( "xs"
                      , []
                      , SB.callExpr (SB.qualVarExpr "List" "map")
                            [ SB.varExpr "negate", SB.listExpr [ SB.intExpr 1, SB.intExpr 2 ] ]
                      )
                    ]
                    |> expectImportsResolved
        , Test.test "imported operators" <|
            \_ ->
                SB.makeModuleWithDefs "Operators"
                    [ ( "n", [], SB.binopsExpr [ ( SB.intExpr 1, "+" ), ( SB.intExpr 2, "*" ) ] (SB.intExpr 3) )
                    , ( "ys", [], SB.binopsExpr [ ( SB.intExpr 1, "::" ) ] (SB.listExpr []) )
                    ]
                    |> expectImportsResolved
        , Test.test "imported constructor" <|
            \_ ->
                SB.makeModuleWithDefs "Ctor" [ ( "t", [], SB.ctorExpr "True" ) ]
                    |> expectImportsResolved
        ]
