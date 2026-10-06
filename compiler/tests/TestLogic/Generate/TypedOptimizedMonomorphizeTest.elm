module TestLogic.Generate.TypedOptimizedMonomorphizeTest exposing (suite)

{-| Checks that each program of the standard `SourceIR` catalogue can be
monomorphized, and nothing more, so that a standard program the pipeline
rejects with an error at or before monomorphization fails a test that says only
that.

The fixture is the catalogue that
`SourceIR.Suite.StandardTestSuites.expectSuite` runs, whose module docstring
says which case modules it includes and which it leaves out. Each program is
run through `TestLogic.TestPipeline.runToMono`: canonicalization, type
checking, PostSolve and typed optimization, then the production pipeline's
pre-monomorphization passes and monomorphization.

`suite`, a group named "monomorphizes", establishes for each program:

  - that `runToMono` returns a graph; when it returns an `Err` instead, the
    test fails with that error's message;
  - that the graph has a `main` and a node array that is not empty.

Among what is not tested: the solver engine, global optimization and MLIR
generation; the types or contents of any node; and the `SourceIR` case
modules that `StandardTestSuites` leaves out, among them
`TypeCheckFailsCases`. A stage that crashes rather than returning an `Err` is
not caught, as `TestLogic.TestPipeline` describes.

-}

import SourceIR.Suite.StandardTestSuites as StandardTestSuites
import Test exposing (Test)
import TestLogic.TestPipeline exposing (expectMonomorphization)


{-| The group of tests that applies `expectMonomorphization` to each program of
the standard catalogue.
-}
suite : Test
suite =
    StandardTestSuites.expectSuite expectMonomorphization "monomorphizes"
