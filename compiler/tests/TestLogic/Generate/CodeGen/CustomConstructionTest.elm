module TestLogic.Generate.CodeGen.CustomConstructionTest exposing (suite)

{-| Test suite for CGEN\_020: Custom ADT Construction invariant.

`eco.construct.custom` is only for user-defined custom ADTs.
Attributes must have valid `tag` and `size`, and `size` must match operand count.

-}

import SourceIR.Suite.StandardTestSuites as StandardTestSuites
import Test exposing (Test)
import TestLogic.Generate.CodeGen.CustomConstruction exposing (expectCustomConstruction)


suite : Test
suite =
    Test.describe "CGEN_020: Custom ADT Construction"
        [ StandardTestSuites.expectSuite expectCustomConstruction "passes custom construction invariant"
        ]
