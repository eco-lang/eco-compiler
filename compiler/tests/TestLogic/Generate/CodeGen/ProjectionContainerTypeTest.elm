module TestLogic.Generate.CodeGen.ProjectionContainerTypeTest exposing (suite)

{-| Runs the projection container check on every program in the standard
catalogue of `SourceIR` test programs.

A _projection op_, such as `eco.project.record`, reads a field out of its one
operand, the _container_. A container whose type is a primitive, such as `i64`,
would be read as a pointer to a heap value. This suite reports a projection
whose container has a type its op does not accept. The projection ops and the
types each accepts are listed in `TestLogic.Generate.CodeGen.ProjectionContainerType`.

The fixture is the catalogue that `SourceIR.Suite.StandardTestSuites` runs.

For each program, `suite` checks that:

  - `TestLogic.TestPipeline.runToMlir` compiles it to MLIR without an error;
  - every projection op inside a top-level `func.func` has exactly one operand;
  - that operand, when it is defined in the same function, has type
    `!eco.value`, or, for `eco.project.tuple2`, `eco.project.tuple3` and
    `eco.project.custom` only, is a _promoted aggregate_ of the matching kind:
    a tuple or custom value held as an SSA struct value rather than on the
    heap.

Among what is not tested: a container defined outside the projection's own
function, projection ops outside a top-level `func.func`, and the projection's
result type and field index.

-}

import SourceIR.Suite.StandardTestSuites as StandardTestSuites
import Test exposing (Test)
import TestLogic.Generate.CodeGen.ProjectionContainerType exposing (expectProjectionContainerType)


{-| The test suite: every program in the standard catalogue, each checked with
`expectProjectionContainerType`.
-}
suite : Test
suite =
    Test.describe "CGEN_0E1: Projection Container Types"
        [ StandardTestSuites.expectSuite expectProjectionContainerType "passes projection container type invariant"
        ]
