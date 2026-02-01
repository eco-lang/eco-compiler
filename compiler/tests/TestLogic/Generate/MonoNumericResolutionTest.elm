module TestLogic.Generate.MonoNumericResolutionTest exposing (suite)

{-| Test suite for invariants:

  - MONO_002: No CNumber MVar at MLIR codegen entry
  - MONO_008: Primitive numeric types are fixed in calls

-}

import TestLogic.Generate.MonoNumericResolution
    exposing
        ( expectNoNumericPolymorphism
        , expectNumericTypesResolved
        )
import SourceIR.Suite.StandardTestSuites as StandardTestSuites
import Test exposing (Test)


suite : Test
suite =
    Test.describe "Numeric type resolution in monomorphization"
        [ noNumericPolymorphismSuite
        , numericTypesResolvedSuite
        ]


noNumericPolymorphismSuite : Test
noNumericPolymorphismSuite =
    Test.describe "No CNumber MVar at MLIR entry (MONO_002)"
        [ StandardTestSuites.expectSuite expectNoNumericPolymorphism "has no CNumber MVars"
        ]


numericTypesResolvedSuite : Test
numericTypesResolvedSuite =
    Test.describe "Numeric types fixed at call sites (MONO_008)"
        [ StandardTestSuites.expectSuite expectNumericTypesResolved "has resolved numeric types"
        ]
