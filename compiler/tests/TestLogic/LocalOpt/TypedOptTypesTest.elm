module TestLogic.LocalOpt.TypedOptTypesTest exposing (suite)

{-| Test suite for invariant TOPT\_001: TypedOptimized expressions always carry types.
-}

import SourceIR.Suite.StandardTestSuites as StandardTestSuites
import Test exposing (Test)
import TestLogic.LocalOpt.TypedOptTypes exposing (expectAllExprsHaveTypes)


suite : Test
suite =
    Test.describe "TypedOptimized expressions always carry types (TOPT_001)"
        [ StandardTestSuites.expectSuite expectAllExprsHaveTypes "has types on all expressions"
        ]
