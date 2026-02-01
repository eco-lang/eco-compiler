module TestLogic.Generate.CodeGen.TupleConstructionTest exposing (suite)

{-| Test suite for CGEN_017: Tuple Construction invariant.

Tuples must use `eco.construct.tuple2` or `eco.construct.tuple3`;
never `eco.construct.custom`.

-}

import TestLogic.Generate.CodeGen.TupleConstruction exposing (expectTupleConstruction)
import SourceIR.Suite.StandardTestSuites as StandardTestSuites
import Test exposing (Test)


suite : Test
suite =
    Test.describe "CGEN_017: Tuple Construction"
        [ StandardTestSuites.expectSuite expectTupleConstruction "passes tuple construction invariant"
        ]
