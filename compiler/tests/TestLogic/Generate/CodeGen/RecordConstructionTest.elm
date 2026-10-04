module TestLogic.Generate.CodeGen.RecordConstructionTest exposing (suite)

{-| Runs the record construction check on every program in the standard
catalogue, so that generated MLIR building a record with a missing, zero or
too large field count fails a test on many programs rather than on a
hand-picked few.

The code generator builds a non-empty record with an `eco.construct.record` op,
whose `field_count` attribute says how many of its operands are fields. The
rules checked, and why an extra operand is allowed, are described in
`TestLogic.Generate.CodeGen.RecordConstruction`.

The fixture is the catalogue of source programs that
`SourceIR.Suite.StandardTestSuites` gathers from its case modules.

`suite` establishes, for each program in the catalogue, that it compiles to
MLIR and that every `eco.construct.record` op in the result has an integer
`field_count` that is neither 0 nor larger than its number of operands.

Among what is not tested: that an empty record is built as an `eco.constant`
(only that no construction has a `field_count` of 0); that `field_count`
equals the number of fields in the record's type; a negative `field_count`;
and programs outside the catalogue.

-}

import SourceIR.Suite.StandardTestSuites as StandardTestSuites
import Test exposing (Test)
import TestLogic.Generate.CodeGen.RecordConstruction exposing (expectRecordConstruction)


{-| A test group that checks every program in the standard catalogue with
`expectRecordConstruction`.
-}
suite : Test
suite =
    Test.describe "CGEN_018: Record Construction"
        [ StandardTestSuites.expectSuite expectRecordConstruction "passes record construction invariant"
        ]
