module TestLogic.Monomorphize.MonoRecordUpdateShapeTest exposing (suite)

{-| Runs the record-update check of
`TestLogic.Monomorphize.MonoRecordUpdateShape` on every program in the
standard `SourceIR` catalogue, so that a monomorphized record update whose
result type lacks a field of the record it updates fails a test on any of
those programs. Why such an update is a fault is stated in that module's
docstring: code generation builds the new record with the layout of the input
record's type, while a field read on the result takes its position from the
result's type.

The fixture is the set of programs that
`SourceIR.Suite.StandardTestSuites.expectSuite` hands to an expectation; that
module's docstring says which case modules it includes. Each program is
compiled to a monomorphized graph by `TestPipeline.runToMono`, which uses the
substitution engine.

What `suite` establishes, for each of those programs:

  - `runToMono` returns no error.
  - Every `MonoRecordUpdate` in the graph whose input record has an `MRecord`
    type has a result type that is also a record and has every field name of
    the input record's type.

Among what is not tested: field types, which are not compared; record updates
whose input record's type is not an `MRecord`, such as a type variable, which
are skipped; the solver engine; the graph after global optimization; and the
MLIR that code generation emits for an update.

-}

import SourceIR.Suite.StandardTestSuites as StandardTestSuites
import Test exposing (Test)
import TestLogic.Monomorphize.MonoRecordUpdateShape exposing (expectMonoRecordUpdateShape)


{-| The test group that applies `expectMonoRecordUpdateShape` to every program
of the standard `SourceIR` catalogue.
-}
suite : Test
suite =
    Test.describe "MonoRecordUpdate shape is >= source record shape"
        [ StandardTestSuites.expectSuite expectMonoRecordUpdateShape "record update result type preserves source fields"
        ]
