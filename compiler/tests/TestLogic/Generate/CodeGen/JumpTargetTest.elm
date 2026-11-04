module TestLogic.Generate.CodeGen.JumpTargetTest exposing (suite)

{-| A jump in generated MLIR that names no enclosing joinpoint, or passes it the
wrong arguments, is a broken program that no type in `Mlir.Mlir` rules out.
This module runs the check for such jumps,
`TestLogic.Generate.CodeGen.JumpTarget.expectJumpTarget`, on every program of
the standard `SourceIR` catalogue. The checker itself is pinned on hand-built
MLIR by `TestLogic.Generate.CodeGen.JumpTargetCheckerTest`.

A _jump_ is an `eco.jump` op. Its integer `target` attribute names a
_joinpoint_, an `eco.joinpoint` op that encloses the jump, by the joinpoint's
integer `id`, and its operands are the arguments it passes to the joinpoint's
parameters.

What the tests establish:

  - `suite` compiles each catalogue program to MLIR with `runToMlir`, and
    passes for it when compilation succeeds and every jump targets an
    enclosing joinpoint with as many parameters as it has operands, each of
    the operand's defined type. The code generator emits no `eco.joinpoint`
    (tail recursion becomes `scf.while`), so on these programs the check
    amounts to: no `eco.jump` is generated. (`Expr.generateExpr` crashes on a
    `MonoTailCall` that `TailRec` did not lower, instead of emitting one.)

Among what is not tested: whether joinpoint ids are unique within a function.

-}

import SourceIR.Suite.StandardTestSuites as StandardTestSuites
import Test exposing (Test)
import TestLogic.Generate.CodeGen.JumpTarget exposing (expectJumpTarget)


{-| The test group of this module: the standard catalogue's suites, each
applying `expectJumpTarget` to its programs.
-}
suite : Test
suite =
    Test.describe "CGEN_030: Jump Target Validity"
        [ StandardTestSuites.expectSuite expectJumpTarget "passes jump target invariant"
        ]
