module Compiler.Generate.CodeGen.CustomProjectionTest exposing (suite)

{-| Test suite for CGEN_024: Custom ADT Projection invariant.

Custom ADT field access must use `eco.project.custom` with valid field index.

-}

import Compiler.Generate.CodeGen.CustomProjection exposing (expectCustomProjection)
import Compiler.StandardTestSuites as StandardTestSuites
import Test exposing (Test)


suite : Test
suite =
    Test.describe "CGEN_024: Custom ADT Projection"
        [ StandardTestSuites.expectSuite expectCustomProjection "passes custom projection invariant"
        ]
