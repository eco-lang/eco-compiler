module TestLogic.Monomorphize.MonoCaseBranchResultTypeTest exposing (suite)

{-| Test suite for GOPT\_018: MonoCase branch result types match MonoCase resultType.

For every SpecId in SpecializationRegistry.reverseMapping, the stored
MonoType must equal the type of the corresponding MonoNode.

Note: This invariant is enforced by GlobalOpt (as GOPT\_018), not Monomorphize.
Monomorphize is now staging-agnostic.

-}

import SourceIR.Suite.StandardTestSuites as StandardTestSuites
import Test exposing (Test)
import TestLogic.Monomorphize.MonoCaseBranchResultType exposing (expectMonoCaseBranchResultTypes)


suite : Test
suite =
    Test.describe "GOPT_018: MonoCase branches match case result type"
        [ StandardTestSuites.expectSuite expectMonoCaseBranchResultTypes "case branch types match"
        ]
