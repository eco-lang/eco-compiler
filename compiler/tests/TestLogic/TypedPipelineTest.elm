module TestLogic.TypedPipelineTest exposing (suite)

{-| Runs every program of the standard test catalogue through the whole
substitution-engine pipeline, so that a catalogue program the front end
rejects is noticed, and so that the back-end stages are executed on every
program.

The fixture is the catalogue that `SourceIR.Suite.StandardTestSuites` gathers:
the Elm source programs built by the `SourceIR` case modules it includes, two
of which are fuzz modules whose programs vary from run to run. Each program
must define `testValue`, because the check first adds the synthetic `main`
that `TestLogic.TestPipeline` builds around it.

What the tests establish, for each program, through
`TestLogic.TestPipeline.expectCoverageRun`:

  - The program, with the synthetic `main` added, is canonicalized, type
    checked, run through PostSolve and optimized by the typed optimizer
    without any of those stages returning an error. An error fails the test
    with a message beginning "Invalid test case (frontend failure)".

Among what is not tested:

  - Anything about monomorphization, global optimization or MLIR generation.
    They run after the typed optimizer, but an error from any of them passes
    and their output is not inspected. Only a crash in one of them ends the
    test.
  - That the program is valid Elm in full: the pattern match checker is not
    run.

-}

import SourceIR.Suite.StandardTestSuites as StandardTestSuites
import Test exposing (Test)
import TestLogic.TestPipeline exposing (expectCoverageRun)


{-| The test group `coverage run`: the standard catalogue, with each program
checked by `expectCoverageRun`.
-}
suite : Test
suite =
    StandardTestSuites.expectSuite expectCoverageRun "coverage run"
