module TestLogic.Generate.Monomorphize.MonoCaseBranchResultTypeTest exposing (suite)

{-| Test suite for MONO\_018: MonoCase branch result types match MonoCase resultType.

For every SpecId in SpecializationRegistry.reverseMapping, the stored
MonoType must equal the type of the corresponding MonoNode.

-}

import SourceIR.Suite.StandardTestSuites as StandardTestSuites
import Test exposing (Test)
import TestLogic.Generate.Monomorphize.MonoCaseBranchResultType exposing (expectMonoCaseBranchResultTypes)


suite : Test
suite =
    Test.describe "MONO_018: MonoCase branches match case result type"
        [ StandardTestSuites.expectSuite expectMonoCaseBranchResultTypes "case branch types match"
        ]
