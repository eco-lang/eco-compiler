module Compiler.Generate.TypedOptimizedMonomorphizeTest exposing (suite)

{-| Test suite for verifying that TypedOptimized code can be monomorphized.

This runs all the standard test cases (excluding TypeCheckFails) through
the typed optimization pipeline and then monomorphization.

-}

import Compiler.Generate.TypedOptimizedMonomorphize exposing (expectMonomorphization)
import Compiler.StandardTestSuites as StandardTestSuites
import Test exposing (Test)


suite : Test
suite =
    StandardTestSuites.expectSuite expectMonomorphization "monomorphizes"
