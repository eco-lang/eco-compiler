module TestLogic.Optimize.OptimizeEquivalentTest exposing (suite)

{-| Test suite for verifying that Erased and Typed optimization paths
produce structurally equivalent results.

This runs all the standard test cases (excluding TypeCheckFails) through
both optimization pipelines and compares the resulting IRs.

-}

import TestLogic.Optimize.OptimizeEquivalent exposing (expectEquivalentOptimization)
import SourceIR.Suite.StandardTestSuites as StandardTestSuites
import Test exposing (Test)


suite : Test
suite =
    StandardTestSuites.expectSuite expectEquivalentOptimization "optimize equivalently"
