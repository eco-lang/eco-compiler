module TestLogic.TypedPipelineTest exposing (suite)

{-| Test suite that drives all standard test cases through the full pipeline
to MLIR generation with no additional assertions beyond "it doesn't crash".

Used as the coverage-driving test: any SourceIR test case that successfully
produces MLIR output counts as a pass.

-}

import SourceIR.Suite.StandardTestSuites as StandardTestSuites
import Test exposing (Test)
import TestLogic.TestPipeline exposing (expectMLIRGeneration)


suite : Test
suite =
    StandardTestSuites.expectSuite expectMLIRGeneration "generates MLIR"
