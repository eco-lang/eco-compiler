module TestLogic.Generate.CodeGen.SafepointRegionScopingTest exposing (suite)

{-| Runs the operand scoping check over two catalogues of test programs, so
that generated MLIR in which an op uses an SSA value
defined in a sibling region of a branching op, which MLIR does not allow, is
caught by the test suite.

A branching op such as `eco.case` has one region per alternative, and a value
defined in one of those regions is out of scope in the others. The check is
`TestLogic.Generate.CodeGen.SafepointRegionScoping.expectSafepointRegionScoping`,
whose module docstring defines its terms and lists what it leaves out. It
compiles a program to MLIR and fails if compilation fails, or if an operand of
a _checked op_ (`eco.call`, `eco.papExtend`, `eco.papCreate`,
`eco.papCreateGroup`, `eco.to_heap` or one of five `eco.construct` ops) in any
`func.func` is out of scope where the op sits.

The "safepoint" in this module's name is historical: the checked ops once
also carried GC-root operands, which the code generator no longer emits, so
the operands the check examines are the ops' ordinary ones.

`suite` runs the check on:

  - the standard catalogue, `SourceIR.Suite.StandardTestSuites`, which
    includes `SourceIR.TailRecCaseCases` (self-recursive functions that make
    their recursive call from a branch of a `case`, among them a function
    matching on a three-constructor type whose branches allocate, aimed at
    the loop-step code of `Compiler.GenerateMlir.TailRec` that branches on a
    constructor tag, `compileCaseFanOutStep`) and
    `SourceIR.IfLetSafepointCases` (a variable bound by a `case` pattern
    inside the `else` branch of an `if`);
  - `SourceIR.CaseSafepointLeakCases`, which the standard catalogue leaves
    out: a `case` bound by a `let`, followed by an allocation.

Among what is not tested:

  - that the three-constructor program's `case` is compiled by
    `compileCaseFanOutStep`; no test looks at which code path is taken;
  - what the check does not examine, as its module docstring lists.

-}

import SourceIR.CaseSafepointLeakCases as CaseSafepointLeakCases
import SourceIR.Suite.StandardTestSuites as StandardTestSuites
import Test exposing (Test)
import TestLogic.Generate.CodeGen.SafepointRegionScoping exposing (expectSafepointRegionScoping)


{-| Every test of this module: the scoping check over the standard and
case-leak catalogues.
-}
suite : Test
suite =
    Test.describe "Safepoint Region Scoping"
        [ StandardTestSuites.expectSuite expectSafepointRegionScoping "passes safepoint region scoping invariant"
        , CaseSafepointLeakCases.expectSuite expectSafepointRegionScoping "passes safepoint region scoping for case-leak cases"
        ]
