module TestLogic.Generate.CodeGen.CallAbiConsistencyTest exposing (suite)

{-| Test suite for Call ABI Consistency invariant.

For every `eco.call`, the operand types must match the target function's
declared parameter types. This enforces REP_ABI_001 which requires consistent
type representation at function call boundaries.

This catches cases like:

  - i1 (Bool) passed to a function expecting !eco.value
  - Type mismatches between call sites and function definitions

-}

import TestLogic.Generate.CodeGen.CallAbiConsistency exposing (expectCallAbiConsistency)
import SourceIR.Suite.StandardTestSuites as StandardTestSuites
import Test exposing (Test)


suite : Test
suite =
    Test.describe "REP_ABI_001: Call ABI Consistency"
        [ StandardTestSuites.expectSuite expectCallAbiConsistency "passes call ABI consistency invariant"
        ]
