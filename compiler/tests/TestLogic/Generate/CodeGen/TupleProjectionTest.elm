module TestLogic.Generate.CodeGen.TupleProjectionTest exposing (suite)

{-| Test suite for CGEN_022: Tuple Projection invariant.

Tuple destructuring must use `eco.project.tuple2` or `eco.project.tuple3`
with valid field indices.

-}

import TestLogic.Generate.CodeGen.TupleProjection exposing (expectTupleProjection)
import SourceIR.Suite.StandardTestSuites as StandardTestSuites
import Test exposing (Test)


suite : Test
suite =
    Test.describe "CGEN_022: Tuple Projection"
        [ StandardTestSuites.expectSuite expectTupleProjection "passes tuple projection invariant"
        ]
