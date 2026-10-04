module TestLogic.Generate.CodeGen.RecordProjectionTest exposing (suite)

{-| These tests catch code generation that, for some program, reads a record
field with an `eco.project.record` op whose field index is missing or negative.

The programs are those built by the case modules that
`SourceIR.Suite.StandardTestSuites` gathers. Each is compiled to MLIR with
`TestLogic.TestPipeline.runToMlir`.

`suite` checks, for each of those programs:

  - that it compiles to MLIR;
  - that every `eco.project.record` op in the resulting module, at any depth,
    has an integer `field_index` that is not negative, exactly one operand and
    exactly one result.

`TestLogic.Generate.CodeGen.RecordProjection` describes the check, and why on
generated code only the rule against a negative `field_index` can fail.

Among what is not tested: that `field_index` is smaller than the number of
fields in the record or names the field the program reads, the type of the
value read, and that every record field read uses this op.

-}

import SourceIR.Suite.StandardTestSuites as StandardTestSuites
import Test exposing (Test)
import TestLogic.Generate.CodeGen.RecordProjection exposing (expectRecordProjection)


{-| The tests that apply `expectRecordProjection` to every program the standard
case modules build, grouped under one name.
-}
suite : Test
suite =
    Test.describe "CGEN_023: Record Projection"
        [ StandardTestSuites.expectSuite expectRecordProjection "passes record projection invariant"
        ]
