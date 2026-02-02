module TestLogic.Generate.CodeGen.TypeTableUniquenessTest exposing (suite)

{-| Test suite for CGEN\_035: Type Table Uniqueness invariant.

Each module must have at most one `eco.type_table` op at module scope.

-}

import SourceIR.Suite.StandardTestSuites as StandardTestSuites
import Test exposing (Test)
import TestLogic.Generate.CodeGen.TypeTableUniqueness exposing (expectTypeTableUniqueness)


suite : Test
suite =
    Test.describe "CGEN_035: Type Table Uniqueness"
        [ StandardTestSuites.expectSuite expectTypeTableUniqueness "passes type table uniqueness invariant"
        ]
