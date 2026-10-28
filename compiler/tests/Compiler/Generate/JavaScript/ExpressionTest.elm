module Compiler.Generate.JavaScript.ExpressionTest exposing (suite)

{-| Regression tests for two bugs in `Compiler.Generate.JavaScript.Expression`.
Both are EXPECTED TO FAIL until the bugs are fixed.

  - An infinite Float literal (`1e400`) prints as `Infinity`, passes the
    whole-number test, and is emitted as `Infinity.0`, which is not JavaScript.
  - `generateCoreCall` compares the module name with `Name.jsArray` (`"JsArray"`),
    but elm/core's module is `Elm.JsArray`, so `generateJsArrayCall` never runs
    and `JsArray.singleton x` is an ordinary call instead of `[x]`.

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
        ]
