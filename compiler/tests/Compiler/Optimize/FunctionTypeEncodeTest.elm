module Compiler.Optimize.FunctionTypeEncodeTest exposing (suite)

{-| Test suite for invariant TOPT_005: Function expressions encode full function type.

-}

import Compiler.AST.Source as Src
import Compiler.FunctionTests as FunctionTests
import Compiler.LetTests as LetTests
import Compiler.MultiDefTests as MultiDefTests
import Compiler.Optimize.FunctionTypeEncode exposing (expectFunctionTypesEncoded)
import Expect exposing (Expectation)
import Test exposing (Test)


suite : Test
suite =
    Test.describe "Function expressions encode full function type (TOPT_005)"
        [ expectSuite expectFunctionTypesEncoded "has correctly encoded function types"
        ]


expectSuite : (Src.Module -> Expectation) -> String -> Test
expectSuite expectFn condStr =
    Test.describe condStr
        [ FunctionTests.expectSuite expectFn condStr
        , LetTests.expectSuite expectFn condStr
        , MultiDefTests.expectSuite expectFn condStr
        ]
