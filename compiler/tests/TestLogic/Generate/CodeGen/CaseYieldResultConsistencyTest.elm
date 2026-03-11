module TestLogic.Generate.CodeGen.CaseYieldResultConsistencyTest exposing (suite)

{-| Test suite for CGEN\_010: eco.case Yield-Result Type Consistency invariant.

Verifies that eco.yield operand types match eco.case result types
in every alternative.

-}

import SourceIR.Suite.StandardTestSuites as StandardTestSuites
import Test exposing (Test)
import TestLogic.Generate.CodeGen.CaseYieldResultConsistency exposing (expectCaseYieldResultConsistency)


suite : Test
suite =
    Test.describe "CGEN_010: Case Yield-Result Consistency"
        [ StandardTestSuites.expectSuite expectCaseYieldResultConsistency "passes case yield-result consistency invariant"
        ]
