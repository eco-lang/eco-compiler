module Compiler.Generate.MonoTypeShapeTest exposing (suite)

{-| Test suite for invariant MONO_001: MonoType encodes fully elaborated runtime shapes.

-}

import Compiler.Generate.MonoTypeShape exposing (expectMonoTypesFullyElaborated)
import Compiler.StandardTestSuites as StandardTestSuites
import Test exposing (Test)


suite : Test
suite =
    Test.describe "MonoType encodes fully elaborated runtime shapes (MONO_001)"
        [ StandardTestSuites.expectSuite expectMonoTypesFullyElaborated "has fully elaborated MonoTypes"
        ]
