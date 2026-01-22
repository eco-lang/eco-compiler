module Compiler.Generate.CodeGen.ConstructResultTypeTest exposing (suite)

{-| Test suite for CGEN_025: Construct Result Types invariant.

All `eco.construct.*` ops must produce `!eco.value` result type.

-}

import Compiler.Generate.CodeGen.ConstructResultType exposing (expectConstructResultType)
import Compiler.StandardTestSuites as StandardTestSuites
import Test exposing (Test)


suite : Test
suite =
    Test.describe "CGEN_025: Construct Result Types"
        [ StandardTestSuites.expectSuite expectConstructResultType "passes construct result type invariant"
        ]
