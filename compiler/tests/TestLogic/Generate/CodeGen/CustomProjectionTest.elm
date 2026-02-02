module TestLogic.Generate.CodeGen.CustomProjectionTest exposing (suite)

{-| Test suite for CGEN\_024: Custom ADT Projection invariant.

Custom ADT field access must use `eco.project.custom` with valid field index.

-}

import SourceIR.Suite.StandardTestSuites as StandardTestSuites
import Test exposing (Test)
import TestLogic.Generate.CodeGen.CustomProjection exposing (expectCustomProjection)


suite : Test
suite =
    Test.describe "CGEN_024: Custom ADT Projection"
        [ StandardTestSuites.expectSuite expectCustomProjection "passes custom projection invariant"
        ]
