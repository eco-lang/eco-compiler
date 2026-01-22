module Compiler.Generate.CodeGen.TupleProjectionTest exposing (suite)

{-| Test suite for CGEN_022: Tuple Projection invariant.

Tuple destructuring must use `eco.project.tuple2` or `eco.project.tuple3`
with valid field indices.

-}

import Compiler.Generate.CodeGen.TupleProjection exposing (expectTupleProjection)
import Compiler.StandardTestSuites as StandardTestSuites
import Test exposing (Test)


suite : Test
suite =
    Test.describe "CGEN_022: Tuple Projection"
        [ StandardTestSuites.expectSuite expectTupleProjection "passes tuple projection invariant"
        ]
