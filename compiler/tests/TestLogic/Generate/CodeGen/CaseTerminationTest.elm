module TestLogic.Generate.CodeGen.CaseTerminationTest exposing (suite)

{-| These tests catch generated code in which an `eco.case` alternative ends
with a terminator other than `eco.yield`, such as `eco.return` or `eco.jump`.
An alternative gives the `eco.case` its results by ending in `eco.yield`; the
rule, and how it is checked, are stated in
`TestLogic.Generate.CodeGen.CaseTermination`. This module applies that check to
many programs.

The fixture is the standard catalogue of test programs, the case modules that
`SourceIR.Suite.StandardTestSuites` lists. Which case modules it leaves out is
stated there.

What `suite` establishes, for each program in the catalogue:

  - The program compiles to MLIR, and every block of every `eco.case`
    alternative, at any depth, ends with `eco.yield`. A program for which
    `runToMlir` returns an error fails its test. A failing test reports only
    the first offending block, as `TestLogic.Generate.CodeGen.Invariants`
    describes for `violationsToExpectation`.

Among what is not tested:

  - Programs outside the catalogue.
  - Whether the values an alternative yields match the `eco.case`'s result
    types.

-}

import SourceIR.Suite.StandardTestSuites as StandardTestSuites
import Test exposing (Test)
import TestLogic.Generate.CodeGen.CaseTermination exposing (expectCaseTermination)


{-| The tests: one group that runs `expectCaseTermination` on every program in
the standard catalogue.
-}
suite : Test
suite =
    Test.describe "CGEN_028: Case Alternative Termination"
        [ StandardTestSuites.expectSuite expectCaseTermination "passes case termination invariant"
        ]
