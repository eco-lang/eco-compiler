module TestLogic.Type.PostSolve.KernelTypesTest exposing (suite)

{-| Runs the kernel type environment check on four programs made of a single
literal each. As built, these tests catch a literal-only program that fails to
canonicalize or type check, and nothing about kernel types.

The kernel type environment is the table, keyed by home module and function
name, that PostSolve builds and typed optimization reads the types of kernel
functions from (`Compiler.Type.KernelTypes`). PostSolve adds an entry only
where the program refers to a kernel function. The check,
`TestLogic.Type.PostSolve.KernelTypes.expectKernelTypesValid`, fails on a type
variable with an empty name in any entry, other than a record's extension
variable, and on a program that fails to canonicalize or type check.

Each program is built with `Compiler.AST.SourceBuilder.makeModuleWithDefs`: a
module importing `Basics` and `List` with one unannotated top-level value. None
of the four refers to a kernel function, so the environment the check walks is
empty, and each test passes whenever its program canonicalizes and type checks.

The tests:

  - `x = 42`, an integer literal, in module `IntLit`.
  - `x = 3.14`, a float literal, in module `FloatLit`.
  - `x = "hello"`, a string literal, in module `StrLit`.
  - `xs = [ 1, 2, 3 ]`, a list of integer literals, in module `ListInt`.

Each test name states a type for its literal, but no assertion reads the type
of any node.

Among what is not tested: a program that refers to a kernel function, so no
entry of the environment is ever examined; the types PostSolve gives the
literals.

-}

import Compiler.AST.SourceBuilder as SB
import Test exposing (Test)
import TestLogic.Type.PostSolve.KernelTypes exposing (expectKernelTypesValid)


{-| The kernel type environment tests, grouped under one label.
-}
suite : Test
suite =
    Test.describe "Kernel types are correctly resolved (POST_002)"
        [ kernelTypeTests
        ]


{-| The four literal programs, each run through `expectKernelTypesValid`.
-}
kernelTypeTests : Test
kernelTypeTests =
    Test.describe "Kernel type resolution"
        [ Test.test "Int literals have Int type" <|
            \_ ->
                let
                    modul =
                        SB.makeModuleWithDefs "IntLit"
                            [ ( "x", [], SB.intExpr 42 ) ]
                in
                expectKernelTypesValid modul
        , Test.test "Float literals have Float type" <|
            \_ ->
                let
                    modul =
                        SB.makeModuleWithDefs "FloatLit"
                            [ ( "x", [], SB.floatExpr 3.14 ) ]
                in
                expectKernelTypesValid modul
        , Test.test "String literals have String type" <|
            \_ ->
                let
                    modul =
                        SB.makeModuleWithDefs "StrLit"
                            [ ( "x", [], SB.strExpr "hello" ) ]
                in
                expectKernelTypesValid modul
        , Test.test "List of Ints has List Int type" <|
            \_ ->
                let
                    modul =
                        SB.makeModuleWithDefs "ListInt"
                            [ ( "xs", [], SB.listExpr [ SB.intExpr 1, SB.intExpr 2, SB.intExpr 3 ] ) ]
                in
                expectKernelTypesValid modul
        ]
