module TestLogic.Generate.CodeGen.CaseScrutineeTypeTest exposing (suite)

{-| These tests run the check of `TestLogic.Generate.CodeGen.CaseScrutineeType`
over the standard catalogue of test programs, so that an `eco.case` whose
recorded scrutinee type disagrees with its `case_kind`, in the MLIR generated
for any of those programs, fails a test.

An `eco.case` branches on its first operand, the _scrutinee_, and its
`case_kind` attribute says what sort of value that is. The code generator
writes the two separately, and nothing in `Mlir.Mlir` makes them agree.

The programs are the ones `SourceIR.Suite.StandardTestSuites.expectSuite`
gathers from the `SourceIR` case modules; that module says which are included.

Each program is compiled to MLIR with `TestLogic.TestPipeline.runToMlir`. The
expectation applied to it establishes:

  - The program compiles through `runToMlir` without an error.
  - Every `eco.case` in the generated module, at any depth, whose `case_kind`
    is a string or symbol reference naming `int`, `chr`, `bool`, `ctor` or
    `str`, and whose `_operand_types` holds at least one type, has as its first
    operand type `i64` for `int`, `i16` for `chr`, `i1` for `bool`, and
    `!eco.value` for `ctor` and `str`.

When several `eco.case` ops fail, only the first is reported.

Among what is not tested:

  - An `eco.case` with any other `case_kind`, with none, or with no type in
    `_operand_types`, which is skipped.
    `TestLogic.Generate.CodeGen.CaseKindScrutineeTest` runs a similar check
    over the same programs that does report an unknown `case_kind`.
  - Any operand type after the first.
  - Whether the type recorded in `_operand_types` is the type of the value the
    op actually receives.
  - The tags and result types of an `eco.case`.

-}

import SourceIR.Suite.StandardTestSuites as StandardTestSuites
import Test exposing (Test)
import TestLogic.Generate.CodeGen.CaseScrutineeType exposing (expectCaseScrutineeType)


{-| The tests of this module: every program of the standard catalogue, each
checked with `expectCaseScrutineeType`.
-}
suite : Test
suite =
    Test.describe "CGEN_037: Case Scrutinee Type Agreement"
        [ StandardTestSuites.expectSuite expectCaseScrutineeType "passes case scrutinee type invariant"
        ]
