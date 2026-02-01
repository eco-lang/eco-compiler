module TestLogic.Generate.Monomorphize.WrapperCurriedCallsTest exposing (suite)

{-| Test suite for MONO\_016: Stage arity invariant for closures.

For every MonoClosure whose MonoType is an MFunction, the length of
closureInfo.params must equal the length of the outermost MFunction
argument list (i.e., stage arity).

-}

import TestLogic.Generate.Monomorphize.WrapperCurriedCalls exposing (expectWrapperCurriedCalls)
import SourceIR.Suite.StandardTestSuites as StandardTestSuites
import Test exposing (Test)


suite : Test
suite =
    Test.describe "MONO_016: Stage arity invariant"
        [ StandardTestSuites.expectSuite expectWrapperCurriedCalls "stage arity matches params"
        ]
