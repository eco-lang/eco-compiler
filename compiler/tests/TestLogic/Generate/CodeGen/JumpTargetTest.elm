module TestLogic.Generate.CodeGen.JumpTargetTest exposing (suite)

{-| A jump in generated MLIR that names no joinpoint, or passes it the wrong
arguments, is a broken program that no type in `Mlir.Mlir` rules out. This
module runs the check for such jumps on every program of the standard
`SourceIR` catalogue, rather than on a few chosen programs.

A _jump_ is an `eco.jump` op. Its integer `target` attribute names a
_joinpoint_, an `eco.joinpoint` op, by the joinpoint's integer `id`, and its
operands are the arguments it passes to the joinpoint's parameters. The check
itself, `expectJumpTarget`, is described in
`TestLogic.Generate.CodeGen.JumpTarget`.

The programs are those that `SourceIR.Suite.StandardTestSuites.expectSuite`
gathers from its case modules. Two of those modules hold fuzz tests, whose
programs vary from run to run.

What the tests establish:

  - `suite` compiles each program to MLIR with `runToMlir`, and passes for it
    when compilation succeeds and every jump in a top-level `func.func` has an
    integer `target`, a joinpoint with that `id` somewhere in the same function
    (it need not enclose the jump), as many operands as that joinpoint has
    parameters, and, if the jump has an `_operand_types` attribute, recorded
    types that match the parameter types.

The code generator builds no `eco.joinpoint` op, so on these programs any
`eco.jump` in a top-level `func.func` is reported as a violation, its target
being missing or not found. A test here passes only when no such function contains an
`eco.jump`.

Among what is not tested: whether joinpoint ids are unique within a function,
and whether a jump's operands really have the types its `_operand_types`
attribute records.

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
