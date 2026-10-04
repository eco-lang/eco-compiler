module TestLogic.Generate.CodeGen.CaseKindScrutineeTest exposing (suite)

{-| An `eco.case` op is given its case kind (the `case_kind` attribute, saying
what sort of value it branches on) and the type of its scrutinee (the value it
branches on) separately, and nothing in the Elm types of `Mlir.Mlir` makes the
two agree. These tests look for generated MLIR in which they disagree, over the
whole standard catalogue of test programs rather than a hand-picked few.

The fixture is the set of Elm source programs that
`SourceIR.Suite.StandardTestSuites.expectSuite` gathers from the `SourceIR` case
modules it includes.

What the tests establish, for each program in the catalogue, through
`TestLogic.Generate.CodeGen.CaseKindScrutinee.expectCaseKindScrutinee`:

  - The program compiles to MLIR through `TestLogic.TestPipeline.runToMlir`
    without an error.
  - Every `eco.case` in the generated module, at any depth, whose `case_kind`
    is a string or a symbol reference and whose `_operand_types` holds a type
    names a case kind the checker knows, and the first type in its
    `_operand_types` is exactly the one that case kind requires, by the table in
    `TestLogic.Generate.CodeGen.CaseKindScrutinee`.

Among what is not tested: an `eco.case` that the checker skips, having no
`case_kind` that is a string or a symbol reference, or no type in
`_operand_types`; any operand type after the first; and the programs of the
`SourceIR` case modules that `expectSuite` leaves out.

-}

import SourceIR.Suite.StandardTestSuites as StandardTestSuites
import Test exposing (Test)
import TestLogic.Generate.CodeGen.CaseKindScrutinee exposing (expectCaseKindScrutinee)


{-| The standard catalogue's tests, each checking its program with
`expectCaseKindScrutinee`, gathered into one group.
-}
suite : Test
suite =
    Test.describe "CGEN_043: Case Kind Scrutinee Type Agreement"
        [ StandardTestSuites.expectSuite expectCaseKindScrutinee "passes case kind scrutinee invariant"
        ]
