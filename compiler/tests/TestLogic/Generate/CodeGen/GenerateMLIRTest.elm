module TestLogic.Generate.CodeGen.GenerateMLIRTest exposing (suite)

{-| Checks that every program in the standard catalogue gets through the test
pipeline to MLIR text, so that a program on which some stage fails, or for
which the MLIR text comes out empty, does not go unnoticed.

The fixture is the set of source programs built by the case modules that
`SourceIR.Suite.StandardTestSuites` gathers. Which case modules it includes,
and which it leaves out, is stated there; the programs meant to fail type
checking are among those left out.

What the tests establish:

  - `suite`: for each program in the catalogue,
    `TestLogic.TestPipeline.runToMlir` succeeds, and the MLIR text it gives is
    not empty and contains `func.func` or `eco.` somewhere.

Among what is not tested:

  - whether the MLIR is valid, or what any particular op in it is;
  - MLIR from the monomorphization engine a default build uses, since
    `runToMlir` uses the substitution engine;
  - programs outside the standard catalogue.

-}

import SourceIR.Suite.StandardTestSuites as StandardTestSuites
import Test exposing (Test)
import TestLogic.TestPipeline exposing (expectMLIRGeneration)


{-| The MLIR generation check applied to every program in the standard
catalogue.
-}
suite : Test
suite =
    StandardTestSuites.expectSuite expectMLIRGeneration "generates MLIR"
