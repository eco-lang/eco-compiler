module TestLogic.Generate.CodeGen.RecordUpdateDataflowTest exposing (suite)

{-| These tests catch code generation that, while building a record, stores as
one of its fields the record its other fields were read from. That is the
symptom of a faulty record update: `{ r | x = 10 }` giving a record whose `x` is
the whole of `r` instead of `10`.

The programs are those built by the case modules that
`SourceIR.Suite.StandardTestSuites` gathers. Each is compiled to MLIR with
`TestLogic.TestPipeline.runToMlir`.

`suite` checks, for each of those programs:

  - that it compiles to MLIR;
  - that no `eco.construct.record` op in any top-level function has one of
    its _source records_ among its field operands. The source records of a
    construction are the records from which at least one of its field operands
    was read by an `eco.project.record` op in the same function, as
    `TestLogic.Generate.CodeGen.RecordUpdateDataflow` describes.

The check is a heuristic and judges every record construction, not only those
generated for record updates. A correct construction such as
`{ a = r.a, orig = r }` would be reported.

Among what is not tested: a construction none of whose field operands was read
from a record, which includes the faulty form of an update to a one-field
record.

-}

import SourceIR.Suite.StandardTestSuites as StandardTestSuites
import Test exposing (Test)
import TestLogic.Generate.CodeGen.RecordUpdateDataflow exposing (expectRecordUpdateDataflow)


{-| The tests that apply `expectRecordUpdateDataflow` to every program the
standard case modules build, grouped under one name.
-}
suite : Test
suite =
    Test.describe "CGEN_0D1: Record Update Dataflow"
        [ StandardTestSuites.expectSuite expectRecordUpdateDataflow "passes record update dataflow invariant"
        ]
