module TestLogic.Generate.CodeGen.SsaUniquenessTest exposing (suite)

{-| Test suite for SSA Uniqueness invariant.

Every SSA variable must be defined at most once within its scope.
In MLIR, non-isolated regions (like eco.case alternatives) share the parent's
SSA namespace, so a variable defined in a parent scope must not be redefined
inside an eco.case alternative region.

-}

import SourceIR.Suite.StandardTestSuites as StandardTestSuites
import Test exposing (Test)
import TestLogic.Generate.CodeGen.SsaUniqueness exposing (expectSsaUniqueness)


suite : Test
suite =
    Test.describe "SSA Uniqueness"
        [ StandardTestSuites.expectSuite expectSsaUniqueness "passes SSA uniqueness invariant"
        ]
