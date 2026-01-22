module Compiler.Optimize.FunctionTypeEncodeTest exposing (suite)

{-| Test suite for invariant TOPT_005: Function expressions encode full function type.

-}

import Compiler.Optimize.FunctionTypeEncode exposing (expectFunctionTypesEncoded)
import Compiler.StandardTestSuites as StandardTestSuites
import Test exposing (Test)


suite : Test
suite =
    Test.describe "Function expressions encode full function type (TOPT_005)"
        [ StandardTestSuites.expectSuite expectFunctionTypesEncoded "has correctly encoded function types"
        ]
