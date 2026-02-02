module TestLogic.Generate.CodeGen.RecordProjectionTest exposing (suite)

{-| Test suite for CGEN\_023: Record Projection invariant.

Record field access must use `eco.project.record` with valid field index.

-}

import SourceIR.Suite.StandardTestSuites as StandardTestSuites
import Test exposing (Test)
import TestLogic.Generate.CodeGen.RecordProjection exposing (expectRecordProjection)


suite : Test
suite =
    Test.describe "CGEN_023: Record Projection"
        [ StandardTestSuites.expectSuite expectRecordProjection "passes record projection invariant"
        ]
