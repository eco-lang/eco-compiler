module TestLogic.Generate.CodeGen.CaseScrutineeTypeTest exposing (suite)

{-| Test suite for CGEN\_037: Case Scrutinee Type Agreement invariant.

`eco.case` scrutinee is `i1` only for boolean cases; otherwise `!eco.value`.

-}

import SourceIR.Suite.StandardTestSuites as StandardTestSuites
import Test exposing (Test)
import TestLogic.Generate.CodeGen.CaseScrutineeType exposing (expectCaseScrutineeType)


suite : Test
suite =
    Test.describe "CGEN_037: Case Scrutinee Type Agreement"
        [ StandardTestSuites.expectSuite expectCaseScrutineeType "passes case scrutinee type invariant"
        ]
