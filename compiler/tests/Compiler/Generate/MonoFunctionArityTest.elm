module Compiler.Generate.MonoFunctionArityTest exposing (suite)

{-| Test suite for invariant MONO_012: Function arity matches parameters and closure info.

-}

import Compiler.AST.Source as Src
import Compiler.FunctionTests as FunctionTests
import Compiler.Generate.MonoFunctionArity exposing (expectFunctionArityMatches)
import Compiler.LetTests as LetTests
import Compiler.MultiDefTests as MultiDefTests
import Expect exposing (Expectation)
import Test exposing (Test)


suite : Test
suite =
    Test.describe "Function arity matches (MONO_012)"
        [ expectSuite expectFunctionArityMatches "has matching function arity"
        ]


expectSuite : (Src.Module -> Expectation) -> String -> Test
expectSuite expectFn condStr =
    Test.describe condStr
        [ FunctionTests.expectSuite expectFn condStr
        , LetTests.expectSuite expectFn condStr
        , MultiDefTests.expectSuite expectFn condStr
        ]
