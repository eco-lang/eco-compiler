module TestLogic.Generate.CodeGen.CaseYieldResultConsistencyTest exposing (suite)

{-| These tests catch generated code in which an `eco.yield` ending an
`eco.case` alternative records a different number of operand types, or
different types, from the results the `eco.case` declares. The rule, and how
it is checked, are stated in
`TestLogic.Generate.CodeGen.CaseYieldResultConsistency`. This module applies
that check to many programs.

The fixture is the standard catalogue of test programs, the case modules that
`SourceIR.Suite.StandardTestSuites` lists. Which case modules it leaves out is
stated there.

What `suite` establishes, for each program in the catalogue:

  - The program compiles to MLIR, and for every `eco.case` at any depth, each
    `eco.yield` that ends a block of one of its alternatives records as many
    operand types as the case has results, each equal to the result type at
    the same position. A program for which `runToMlir` returns an error fails
    its test. A failing test reports only the first mismatch, as
    `TestLogic.Generate.CodeGen.Invariants` describes for
    `violationsToExpectation`.

Among what is not tested:

  - Programs outside the catalogue.
  - The types of the yielded values themselves: the check compares the types
    recorded in each `eco.yield`'s `_operand_types` attribute, and skips an
    `eco.yield` that has none.
  - Whether every block of an alternative ends with `eco.yield`.

-}

import SourceIR.Suite.StandardTestSuites as StandardTestSuites
import Test exposing (Test)
import TestLogic.Generate.CodeGen.CaseYieldResultConsistency exposing (expectCaseYieldResultConsistency)


{-| The tests: one group that runs `expectCaseYieldResultConsistency` on every
program in the standard catalogue.
-}
suite : Test
suite =
    Test.describe "CGEN_010: Case Yield-Result Consistency"
        [ StandardTestSuites.expectSuite expectCaseYieldResultConsistency "passes case yield-result consistency invariant"
        ]
