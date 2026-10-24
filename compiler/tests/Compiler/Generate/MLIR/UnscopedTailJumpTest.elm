module Compiler.Generate.MLIR.UnscopedTailJumpTest exposing (suite)

{-| SD-12: `Expr.generateExpr` used to lower a `MonoTailCall` it was handed
(through a `generateTailCall` fallback) to an `eco.jump` to joinpoint 0, yet the
code generator never emits an `eco.joinpoint` (tail recursion is lowered to
`scf.while` by `Compiler.Generate.MLIR.TailRec`). That jump was therefore
unscoped, breaking CGEN_030 (a jump must target a lexically enclosing
joinpoint).

No program reached the fallback: every `MonoTailFunc` / `MonoTailDef` body goes
through `TailRec.compileTailFuncToWhile`, whose `compileStep` intercepts each
`MonoTailCall` in tail position (if / case / let / destruct), and the inliner
refuses to inline tail functions. The fallback is gone; `generateExpr` now
crashes with `Expr.unscopedTailCallError` on a `MonoTailCall`, so it can no
longer emit an `eco.jump` at all.

An Elm test cannot catch that crash, so this module checks the two halves that
it can:

  - the crash message names the function and the rule (CGEN_030) and says
    which pass should have lowered the call;
  - tail-recursive programs (top-level and let-bound, with the tail call in
    `case` branches and nested positions) still compile, every one of them to
    MLIR with an `scf.while` and no `eco.jump`, which shows `TailRec` still
    takes every tail call before `generateExpr` would crash on it.

-}

import Compiler.AST.Source as Src
import Compiler.Generate.MLIR.Expr as Expr
import Expect exposing (Expectation)
import SourceIR.LocalTailRecCases as LocalTailRecCases
import SourceIR.TailRecCaseCases as TailRecCaseCases
import Test exposing (Test, describe, test)
import TestLogic.Generate.CodeGen.Invariants exposing (findOpsNamed)
import TestLogic.TestPipeline exposing (runToMlir)


suite : Test
suite =
    describe "SD-12: a MonoTailCall never becomes an unscoped eco.jump"
        [ test "generateExpr's crash message names the function, TailRec and CGEN_030" <|
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
        , TailRecCaseCases.expectSuite expectLoopNoJump "compiles to scf.while with no eco.jump"
        , LocalTailRecCases.expectSuite expectLoopNoJump "compiles to scf.while with no eco.jump"
        ]


{-| Compiles `srcModule` to MLIR and passes when compilation succeeds, the
module holds at least one `scf.while` and no `eco.jump`.
-}
expectLoopNoJump : Src.Module -> Expectation
expectLoopNoJump srcModule =
    case runToMlir srcModule of
        Err err ->
            Expect.fail ("Compilation failed: " ++ err)

        Ok { mlirModule } ->
            let
                jumps =
                    List.length (findOpsNamed "eco.jump" mlirModule)

                loops =
                    List.length (findOpsNamed "scf.while" mlirModule)
            in
            if jumps /= 0 then
                Expect.fail ("SD-12: generated MLIR holds " ++ String.fromInt jumps ++ " eco.jump op(s) with no enclosing eco.joinpoint (CGEN_030)")

            else if loops == 0 then
                Expect.fail "the tail-recursive function was not lowered to an scf.while loop"

            else
                Expect.pass
