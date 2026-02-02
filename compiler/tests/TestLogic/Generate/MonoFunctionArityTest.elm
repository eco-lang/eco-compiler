module TestLogic.Generate.MonoFunctionArityTest exposing (suite)

{-| Test suite for invariant MONO\_012: Function arity matches parameters and closure info.
-}

import SourceIR.Suite.StandardTestSuites as StandardTestSuites
import Test exposing (Test)
import TestLogic.Generate.MonoFunctionArity exposing (expectFunctionArityMatches)


suite : Test
suite =
    Test.describe "Function arity matches (MONO_012)"
        [ StandardTestSuites.expectSuite expectFunctionArityMatches "has matching function arity"
        ]
