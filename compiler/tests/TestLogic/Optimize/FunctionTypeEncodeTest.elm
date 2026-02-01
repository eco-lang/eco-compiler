module TestLogic.Optimize.FunctionTypeEncodeTest exposing (suite)

{-| Test suite for invariant TOPT_005: Function expressions encode full function type.

-}

import TestLogic.Optimize.FunctionTypeEncode exposing (expectFunctionTypesEncoded)
import SourceIR.Suite.StandardTestSuites as StandardTestSuites
import Test exposing (Test)


suite : Test
suite =
    Test.describe "Function expressions encode full function type (TOPT_005)"
        [ StandardTestSuites.expectSuite expectFunctionTypesEncoded "has correctly encoded function types"
        ]
