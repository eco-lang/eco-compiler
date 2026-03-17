module TestLogic.TypedPipelineTest exposing (suite)

{-| Test suite that drives all standard test cases through the full pipeline
for coverage measurement.

Uses `expectCoverageRun` which validates that test cases are valid Elm
(passes canonicalization, type checking, and typed optimization) and then
runs the backend pipeline (Mono → GlobalOpt → MLIR) for coverage. Backend
failures are logged but do not fail the test — they represent bugs to
investigate, not invalid test cases.

-}

import SourceIR.Suite.StandardTestSuites as StandardTestSuites
import Test exposing (Test)
import TestLogic.TestPipeline exposing (expectCoverageRun)


suite : Test
suite =
    StandardTestSuites.expectSuite expectCoverageRun "coverage run"
