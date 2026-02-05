module TestLogic.LocalOpt.FunctionTypeEncodeTest exposing (suite)

{-| Test suite for invariant TOPT\_005: Function expressions encode full function type.
-}

import SourceIR.Suite.StandardTestSuites as StandardTestSuites
import Test exposing (Test)
import TestLogic.LocalOpt.FunctionTypeEncode exposing (expectFunctionTypesEncoded)


suite : Test
suite =
    Test.describe "Function expressions encode full function type (TOPT_005)"
        [ StandardTestSuites.expectSuite expectFunctionTypesEncoded "has correctly encoded function types"
        ]
