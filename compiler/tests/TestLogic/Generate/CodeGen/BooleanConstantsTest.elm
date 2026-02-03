module TestLogic.Generate.CodeGen.BooleanConstantsTest exposing (suite)

{-| Test suite for CGEN\_009: Boolean Constants invariant.

Boolean constants must use !eco.value representation except in control-flow.

-}

import SourceIR.Suite.StandardTestSuites as StandardTestSuites
import Test exposing (Test)
import TestLogic.Generate.CodeGen.BooleanConstants exposing (expectBooleanConstants)


suite : Test
suite =
    Test.describe "CGEN_009: Boolean Constants"
        [ StandardTestSuites.expectSuite expectBooleanConstants "passes boolean constants invariant"
        ]
