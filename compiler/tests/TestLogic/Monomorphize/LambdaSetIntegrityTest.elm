module TestLogic.Monomorphize.LambdaSetIntegrityTest exposing (suite)

{-| Test suite for invariant LSS\_002: lambda-set lowering totality.
-}

import SourceIR.Suite.StandardTestSuites as StandardTestSuites
import Test exposing (Test)
import TestLogic.Monomorphize.LambdaSetIntegrity exposing (expectLambdaSetIntegrity)


suite : Test
suite =
    Test.describe "Lambda set integrity (LSS_002)"
        [ StandardTestSuites.expectSuite expectLambdaSetIntegrity "satisfies LSS_002"
        ]
