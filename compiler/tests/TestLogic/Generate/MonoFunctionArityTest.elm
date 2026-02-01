module TestLogic.Generate.MonoFunctionArityTest exposing (suite)

{-| Test suite for invariant MONO_012: Function arity matches parameters and closure info.

-}

import TestLogic.Generate.MonoFunctionArity exposing (expectFunctionArityMatches)
import SourceIR.Suite.StandardTestSuites as StandardTestSuites
import Test exposing (Test)


suite : Test
suite =
    Test.describe "Function arity matches (MONO_012)"
        [ StandardTestSuites.expectSuite expectFunctionArityMatches "has matching function arity"
        ]
