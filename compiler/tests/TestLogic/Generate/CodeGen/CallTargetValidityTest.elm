module TestLogic.Generate.CodeGen.CallTargetValidityTest exposing (suite)

{-| Test suite for CGEN_044: Call Target Validity invariant.

Every `eco.call` callee must resolve to an existing `func.func` symbol
in the module, and calls must not target placeholder/stub implementations
when a non-stub implementation is present.

-}

import TestLogic.Generate.CodeGen.CallTargetValidity exposing (expectCallTargetValidity)
import SourceIR.Suite.StandardTestSuites as StandardTestSuites
import Test exposing (Test)


suite : Test
suite =
    Test.describe "CGEN_044: Call Target Validity"
        [ StandardTestSuites.expectSuite expectCallTargetValidity "passes call target validity invariant"
        ]
