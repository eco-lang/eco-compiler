module TestLogic.Generate.MonoTypeShapeTest exposing (suite)

{-| Test suite for invariant MONO\_001: MonoType encodes fully elaborated runtime shapes.
-}

import SourceIR.Suite.StandardTestSuites as StandardTestSuites
import Test exposing (Test)
import TestLogic.Generate.MonoTypeShape exposing (expectMonoTypesFullyElaborated)


suite : Test
suite =
    Test.describe "MonoType encodes fully elaborated runtime shapes (MONO_001)"
        [ StandardTestSuites.expectSuite expectMonoTypesFullyElaborated "has fully elaborated MonoTypes"
        ]
