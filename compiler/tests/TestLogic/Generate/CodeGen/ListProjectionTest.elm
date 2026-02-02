module TestLogic.Generate.CodeGen.ListProjectionTest exposing (suite)

{-| Test suite for CGEN\_021: List Projection invariant.

List destructuring must use only `eco.project.list_head` and `eco.project.list_tail`.

-}

import SourceIR.Suite.StandardTestSuites as StandardTestSuites
import Test exposing (Test)
import TestLogic.Generate.CodeGen.ListProjection exposing (expectListProjection)


suite : Test
suite =
    Test.describe "CGEN_021: List Projection"
        [ StandardTestSuites.expectSuite expectListProjection "passes list projection invariant"
        ]
