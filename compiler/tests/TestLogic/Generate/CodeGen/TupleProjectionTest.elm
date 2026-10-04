module TestLogic.Generate.CodeGen.TupleProjectionTest exposing (suite)

{-| These tests exist so that the tuple projections the code generator emits are
checked on every program in the standard `SourceIR` catalogue, not only on a
few chosen by hand. A tuple projection is an `eco.project.tuple2` or
`eco.project.tuple3` op, which reads one element of a two- or three-element
tuple; its integer `field` attribute is the element's zero-based index.

The fixture is that catalogue, the programs that
`SourceIR.Suite.StandardTestSuites.expectSuite` gathers. A program whose MLIR
holds no tuple projection passes.

`suite` gives each program to
`TestLogic.Generate.CodeGen.TupleProjection.expectTupleProjection`. The test for
a program passes when the program compiles to MLIR through
`TestLogic.TestPipeline.runToMlir`, and every tuple projection in the result, at
any nesting depth, has an integer `field` from 0 to one less than its tuple's
size, exactly one operand and exactly one result. A failing test reports only
the first violation it finds.

Among what is not tested: that tuple destructuring uses these ops rather than
some other op; the types of a projection's operand and result; and that any
program contains a tuple projection at all.

-}

import SourceIR.Suite.StandardTestSuites as StandardTestSuites
import Test exposing (Test)
import TestLogic.Generate.CodeGen.TupleProjection exposing (expectTupleProjection)


{-| The standard catalogue run through `expectTupleProjection`, as one group of
tests.
-}
suite : Test
suite =
    Test.describe "CGEN_022: Tuple Projection"
        [ StandardTestSuites.expectSuite expectTupleProjection "passes tuple projection invariant"
        ]
