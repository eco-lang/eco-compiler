module Compiler.Generate.MLIR.UnscopedTailJumpTest exposing (suite)

{-| An `eco.jump` is only valid inside an `eco.joinpoint` it targets (rule
`CGEN_030`), and the code generator emits no `eco.joinpoint`. A tail call
therefore has to be lowered as a loop by `Compiler.Generate.MLIR.TailRec`, and
`Expr.generateExpr` crashes on any `MonoTailCall` that reaches it instead of
emitting a jump. These tests guard both sides of that arrangement: that the
crash explains itself, and that ordinary tail-recursive programs never reach
it.

The fixtures are the programs of `SourceIR.TailRecCaseCases` (top-level
tail-recursive functions whose tail calls sit in `case` branches, an `if`
inside a branch, a nested `case` and a wildcard destruct) and of
`SourceIR.LocalTailRecCases` (let-bound tail-recursive functions, alone, several
in one `let`, nested, and inside an outer function).

What the tests establish:

  - The message of `Expr.unscopedTailCallError "loop"` contains the quoted name
    `` `loop` ``, the word `TailRec` and the rule id `CGEN_030`.
  - Each program of the two case modules compiles to MLIR that contains at
    least one `scf.while` op and no `eco.jump` op. Each case module's programs
    run as one test.

Among what is not tested: that `generateExpr` actually crashes on a
`MonoTailCall` (an Elm test cannot observe the crash), and that each
tail-recursive function, rather than just some function in the module, became
an `scf.while`.

-}

import Compiler.AST.Source as Src
import Compiler.Generate.MLIR.Expr as Expr
import Expect exposing (Expectation)
import SourceIR.LocalTailRecCases as LocalTailRecCases
import SourceIR.TailRecCaseCases as TailRecCaseCases
import Test exposing (Test, describe, test)
import TestLogic.Generate.CodeGen.Invariants exposing (findOpsNamed)
import TestLogic.TestPipeline exposing (runToMlir)


{-| The crash-message test and the two case-module suites checked with
`expectLoopNoJump`.
-}
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


{-| Compiles `srcModule` to MLIR and passes when compilation succeeds and the
module holds at least one `scf.while` op and no `eco.jump` op, at any depth.
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
