module TestLogic.Generate.CodeGen.CaseNotTerminatorTest exposing (suite)

{-| An `eco.case` op yields SSA values and belongs among a block's body ops, as
`Compiler.Generate.MLIR.Ops` describes, but a block keeps its body ops and its
terminator (the op that ends it) in separate fields, and nothing in the Elm
types of `Mlir.Mlir` stops an `eco.case` being put in the terminator's place.
These tests look for generated MLIR in which that has happened, over the whole
standard catalogue of test programs rather than a hand-picked few.

The fixture is the set of Elm source programs that
`SourceIR.Suite.StandardTestSuites.expectSuite` gathers from the `SourceIR` case
modules it includes.

What the tests establish, for each program in the catalogue, through
`TestLogic.Generate.CodeGen.CaseNotTerminator.expectCaseNotTerminator`:

  - The program compiles to MLIR through `TestLogic.TestPipeline.runToMlir`
    without an error.
  - No block of any region of any op in the generated module, at any depth, has
    a terminator named `eco.case`.

Among what is not tested: what ends each alternative of an `eco.case`, an
`eco.case` among a block's body ops whose `isTerminator` flag is set, and the
programs of the `SourceIR` case modules that `expectSuite` leaves out.

-}

import SourceIR.Suite.StandardTestSuites as StandardTestSuites
import Test exposing (Test)
import TestLogic.Generate.CodeGen.CaseNotTerminator exposing (expectCaseNotTerminator)


{-| The standard catalogue's tests, each checking its program with
`expectCaseNotTerminator`, gathered into one group.
-}
suite : Test
suite =
    Test.describe "CGEN_045: eco.case Not a Terminator"
        [ StandardTestSuites.expectSuite expectCaseNotTerminator "passes eco.case not terminator invariant"
        ]
