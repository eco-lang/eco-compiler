module TestLogic.Monomorphize.WrapperCurriedCallsTest exposing (suite)

{-| Test suite for GOPT\_016: Stage arity invariant for closures.

For every MonoClosure whose MonoType is an MFunction, the length of
closureInfo.params must equal the length of the outermost MFunction
argument list (i.e., stage arity).

Note: This invariant is enforced by GlobalOpt (as GOPT\_016), not Monomorphize.
Monomorphize is now staging-agnostic.

-}

import SourceIR.Suite.StandardTestSuites as StandardTestSuites
import Test exposing (Test)
import TestLogic.Monomorphize.WrapperCurriedCalls exposing (expectWrapperCurriedCalls)


suite : Test
suite =
    Test.describe "GOPT_001: Stage arity invariant"
        [ StandardTestSuites.expectSuite expectWrapperCurriedCalls "stage arity matches params"
        ]
