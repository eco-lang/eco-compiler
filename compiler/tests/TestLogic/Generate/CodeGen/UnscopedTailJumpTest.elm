module TestLogic.Generate.CodeGen.UnscopedTailJumpTest exposing (suite)

{-| An `eco.jump` is only valid inside an `eco.joinpoint` it targets (rule
`CGEN_030`), and the code generator emits no `eco.joinpoint`. A tail call
therefore has to be lowered as a loop by `Compiler.GenerateMlir.TailRec`, and
`Expr.generateExpr` crashes on any `MonoTailCall` that reaches it instead of
emitting a jump. These tests guard one side of that arrangement: that ordinary
tail-recursive programs never reach the crash. The other side, that the crash
explains itself, is pinned by the unit test
`Compiler.GenerateMlir.ExprUnscopedTailCallErrorTest`.

The fixtures are the programs of `SourceIR.TailRecCaseCases` (tail-recursive
functions whose tail calls sit in `case` branches, an `if` inside a branch, a
nested `case`, a wildcard destruct and a three-constructor fan-out, and one
whose tail call is under an `if` with no `case`) and of
`SourceIR.LocalTailRecCases` (let-bound tail-recursive functions, alone, several
in one `let`, nested, and inside an outer function).

What the tests establish:

  - Each program of the two case modules compiles to MLIR that contains at
    least one `scf.while` op and no `eco.jump` op. Each case module's programs
    run as one test.

Among what is not tested: that `generateExpr` actually crashes on a
`MonoTailCall` (an Elm test cannot observe the crash), and that each
tail-recursive function, rather than just some function in the module, became
an `scf.while`.

-}

import Compiler.IR.Source as Src
import Expect exposing (Expectation)
import SourceIR.LocalTailRecCases as LocalTailRecCases
import SourceIR.TailRecCaseCases as TailRecCaseCases
import Test exposing (Test, describe)
import TestLogic.Generate.CodeGen.Invariants exposing (findOpsNamed)
import TestLogic.TestPipeline exposing (runToMlir)


{-| The two case-module suites checked with `expectLoopNoJump`.
-}
suite : Test
suite =
    describe "SD-12: a MonoTailCall never becomes an unscoped eco.jump"
        [ TailRecCaseCases.expectSuite expectLoopNoJump "compiles to scf.while with no eco.jump"
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
