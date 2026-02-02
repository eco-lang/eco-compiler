module TestLogic.Generate.TypedOptimizedMonomorphizeTest exposing (suite)

{-| Test suite for verifying that TypedOptimized code can be monomorphized.

This runs all the standard test cases (excluding TypeCheckFails) through
the typed optimization pipeline and then monomorphization.

-}

import SourceIR.Suite.StandardTestSuites as StandardTestSuites
import Test exposing (Test)
import TestLogic.Generate.TypedOptimizedMonomorphize exposing (expectMonomorphization)


suite : Test
suite =
    StandardTestSuites.expectSuite expectMonomorphization "monomorphizes"
