module TestLogic.Generate.CodeGen.ConstructResultTypeTest exposing (suite)

{-| Test suite for CGEN\_025: Construct Result Types invariant.

All `eco.construct.*` ops must produce `!eco.value` result type.

-}

import SourceIR.Suite.StandardTestSuites as StandardTestSuites
import Test exposing (Test)
import TestLogic.Generate.CodeGen.ConstructResultType exposing (expectConstructResultType)


suite : Test
suite =
    Test.describe "CGEN_025: Construct Result Types"
        [ StandardTestSuites.expectSuite expectConstructResultType "passes construct result type invariant"
        ]
