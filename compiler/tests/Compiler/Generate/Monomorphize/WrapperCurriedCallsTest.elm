module Compiler.Generate.Monomorphize.WrapperCurriedCallsTest exposing (suite)

{-| Test suite for MONO\_016: Wrapper closures generate curried calls.

When creating uncurried wrapper closures for functions that return functions,
the wrapper must generate nested MonoCall expressions that respect the original
curried parameter structure.

-}

import Compiler.Generate.Monomorphize.WrapperCurriedCalls exposing (expectWrapperCurriedCalls)
import Compiler.StandardTestSuites as StandardTestSuites
import Test exposing (Test)


suite : Test
suite =
    Test.describe "MONO_016: Wrapper closures generate curried calls"
        [ StandardTestSuites.expectSuite expectWrapperCurriedCalls "generates curried wrapper calls"
        ]
