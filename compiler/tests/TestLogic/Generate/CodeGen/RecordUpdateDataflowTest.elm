module TestLogic.Generate.CodeGen.RecordUpdateDataflowTest exposing (suite)

{-| Test suite for CGEN\_0D1: Record Update Dataflow Shape invariant.

Detects when a whole record is incorrectly stored as a field during record
update. The bug symptom: `{ original | x = 10 }` yields a record where field
`x` becomes the _original record_ instead of `10`.

This is detected by checking that `eco.construct.record` operands don't include
the source record itself when other operands come from projections of that record.

-}

import SourceIR.Suite.StandardTestSuites as StandardTestSuites
import Test exposing (Test)
import TestLogic.Generate.CodeGen.RecordUpdateDataflow exposing (expectRecordUpdateDataflow)


suite : Test
suite =
    Test.describe "CGEN_0D1: Record Update Dataflow"
        [ StandardTestSuites.expectSuite expectRecordUpdateDataflow "passes record update dataflow invariant"
        ]
