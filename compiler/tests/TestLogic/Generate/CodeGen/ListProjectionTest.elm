module TestLogic.Generate.CodeGen.ListProjectionTest exposing (suite)

{-| The eco MLIR dialect reads the head and the tail of a cons cell with
`eco.project.list_head` and `eco.project.list_tail`. Each takes the cell as its
one operand and gives one result, and the tail, being a list, must be
`!eco.value`, the type of a boxed value. These tests check that every such op
that code generation emits has that shape, across many programs rather than a
hand-picked few.

The fixture is the standard catalogue of `SourceIR` test programs gathered by
`SourceIR.Suite.StandardTestSuites`. Two of its case modules hold fuzz tests,
whose programs can vary from run to run.

What the tests establish:

  - `suite`: for each program in the catalogue, that
    `TestLogic.TestPipeline.runToMlir` succeeds on it and that, in the MLIR
    module it generates, every `eco.project.list_head` and
    `eco.project.list_tail` op has exactly one operand and one result, and
    every `eco.project.list_tail` result is `!eco.value`, as
    `TestLogic.Generate.CodeGen.ListProjection.expectListProjection` describes.

Among what is not tested:

  - the type of a head's result, which may be unboxed;
  - the type of either op's operand;
  - whether a list is ever taken apart by some other operation.

-}

import SourceIR.Suite.StandardTestSuites as StandardTestSuites
import Test exposing (Test)
import TestLogic.Generate.CodeGen.ListProjection exposing (expectListProjection)


{-| The test group that runs the list-projection shape check on every program
in the standard catalogue.
-}
suite : Test
suite =
    Test.describe "CGEN_021: List Projection"
        [ StandardTestSuites.expectSuite expectListProjection "passes list projection invariant"
        ]
