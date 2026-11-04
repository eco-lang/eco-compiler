module Compiler.GenerateMlir.ExprUnscopedTailCallErrorTest exposing (suite)

{-| Pins the message of `Compiler.GenerateMlir.Expr.unscopedTailCallError`, the
crash `Expr.generateExpr` raises on a `MonoTailCall` that
`Compiler.GenerateMlir.TailRec` did not lower to a loop, instead of emitting an
`eco.jump` with no enclosing `eco.joinpoint` (rule `CGEN_030`). The message
must say which function and what went wrong, so that a crash explains itself.

The test establishes that `Expr.unscopedTailCallError "loop"` contains the
quoted name `` `loop` ``, the word `TailRec` and the rule id `CGEN_030`.

Among what is not tested: that `generateExpr` actually crashes on a
`MonoTailCall` (an Elm test cannot observe the crash); that ordinary programs
never reach it is checked by `TestLogic.Generate.CodeGen.UnscopedTailJumpTest`.

-}

import Compiler.GenerateMlir.Expr as Expr
import Expect
import Test exposing (Test)


{-| The pin of the module docstring.
-}
suite : Test
suite =
    Test.test "generateExpr's crash message names the function, TailRec and CGEN_030" <|
        \_ ->
            let
                message =
                    Expr.unscopedTailCallError "loop"
            in
            Expect.all
                [ \m -> Expect.equal True (String.contains "`loop`" m) |> Expect.onFail ("no function name in: " ++ m)
                , \m -> Expect.equal True (String.contains "TailRec" m) |> Expect.onFail ("no TailRec in: " ++ m)
                , \m -> Expect.equal True (String.contains "CGEN_030" m) |> Expect.onFail ("no CGEN_030 in: " ++ m)
                ]
                message
