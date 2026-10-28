module Compiler.Generate.JavaScript.ExpressionTest exposing (suite)

{-| Regression tests for bugs, since fixed, in
`Compiler.Generate.JavaScript.Expression`.

  - An infinite Float literal (`1e400`) printed as `Infinity`, passed the
    whole-number test, and was emitted as `Infinity.0`, which is not JavaScript.
  - `generateCoreCall` compared the module name with `Name.jsArray`, which was
    `"JsArray"`, but elm/core's module is `Elm.JsArray`, so
    `generateJsArrayCall` never ran and `JsArray.singleton x` was an ordinary
    call instead of `[x]`.
  - A negative Int literal value (a hex literal at or above 2^63, such as
    `0xFFFFFFFFFFFFFFFF`, is -1) under a prefix negation would print as `--1`,
    which is not JavaScript; it prints as a parenthesized negation.

-}

import Compiler.AST.Optimized as Opt
import Compiler.Elm.ModuleName as ModuleName
import Compiler.Elm.Package as Pkg
import Compiler.Generate.JavaScript.Builder as JS
import Compiler.Generate.JavaScript.Expression as Expr
import Compiler.Generate.Mode as Mode
import Compiler.Reporting.Annotation as A
import Expect
import Test exposing (Test, describe, test)


home : ModuleName.Canonical
home =
    ModuleName.Canonical Pkg.dummyName "Main"


render : Opt.Expr -> String
render expr =
    let
        (JS.Builder b) =
            JS.exprToBuilder (Expr.codeToExpr (Expr.generate (Mode.Dev Nothing) home expr)) (JS.emptyBuilder 1)
    in
    b.revBuilders


suite : Test
suite =
    describe "Compiler.Generate.JavaScript.Expression"
        [ test "an infinite Float literal is not emitted as Infinity.0" <|
            \_ ->
                render (Opt.Float A.zero (1 / 0))
                    |> String.contains "Infinity.0"
                    |> Expect.equal False
        , test "JsArray.singleton x is inlined as an array literal (bug: Name.jsArray /= \"Elm.JsArray\")" <|
            \_ ->
                render
                    (Opt.Call A.zero
                        (Opt.VarGlobal A.zero (Opt.Global (ModuleName.Canonical Pkg.core "Elm.JsArray") "singleton"))
                        [ Opt.Int A.zero 5 ]
                    )
                    |> String.startsWith "["
                    |> Expect.equal True
        , test "a negative Int literal prints as a negation of its magnitude" <|
            \_ ->
                render (Opt.Int A.zero -1)
                    |> Expect.equal "-1"
        , test "negate of a negative Int literal is not --1" <|
            \_ ->
                render
                    (Opt.Call A.zero
                        (Opt.VarGlobal A.zero (Opt.Global (ModuleName.Canonical Pkg.core "Basics") "negate"))
                        [ Opt.Int A.zero -1 ]
                    )
                    |> Expect.equal "-(-1)"
        ]
