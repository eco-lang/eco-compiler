module TestLogic.Generate.CodeGen.RecordConstructionTest exposing (suite)

{-| Test suite for CGEN_018: Record Construction invariant.

Non-empty records must use `eco.construct.record`;
empty records must use `eco.constant EmptyRec`.

-}

import TestLogic.Generate.CodeGen.RecordConstruction exposing (expectRecordConstruction)
import SourceIR.Suite.StandardTestSuites as StandardTestSuites
import Test exposing (Test)


suite : Test
suite =
    Test.describe "CGEN_018: Record Construction"
        [ StandardTestSuites.expectSuite expectRecordConstruction "passes record construction invariant"
        ]
