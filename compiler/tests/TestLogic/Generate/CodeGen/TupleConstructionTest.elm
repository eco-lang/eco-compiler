module TestLogic.Generate.CodeGen.TupleConstructionTest exposing (suite)

{-| A tuple of two or three elements has its own heap construction ops,
`eco.construct.tuple2` and `eco.construct.tuple3`. These tests look for a tuple
built with the generic `eco.construct.custom` op instead, or with an element
missing, in the MLIR the code generator produces for the standard test
programs.

The programs are those built by the case modules that
`SourceIR.Suite.StandardTestSuites` gathers. Each is compiled to MLIR by
`TestLogic.TestPipeline.runToMlir` and handed to
`TestLogic.Generate.CodeGen.TupleConstruction.expectTupleConstruction`.

What the tests establish:

  - The check on a program fails if it does not compile to MLIR, or if the MLIR
    holds, at any nesting depth, an `eco.construct.tuple2` with fewer than two
    operands, an `eco.construct.tuple3` with fewer than three, or an
    `eco.construct.custom` whose `constructor` attribute is `Tuple2`, `Tuple3`,
    `(,)` or `(,,)`. A tuple op with more operands than elements is accepted.

Among what is not tested: the value-level `eco.make.tuple2`, `eco.make.tuple3`
and `eco.make.custom` ops, the types of the operands, programs outside the
standard catalogue, and MLIR produced by a real build rather than the test
pipeline.

-}

import SourceIR.Suite.StandardTestSuites as StandardTestSuites
import Test exposing (Test)
import TestLogic.Generate.CodeGen.TupleConstruction exposing (expectTupleConstruction)


{-| The tuple construction check applied to the standard test programs, as one
group of tests.
-}
suite : Test
suite =
    Test.describe "CGEN_017: Tuple Construction"
        [ StandardTestSuites.expectSuite expectTupleConstruction "passes tuple construction invariant"
        ]
