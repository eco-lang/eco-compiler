module Compiler.Generate.CodeGen.CaseScrutineeTypeTest exposing (suite)

{-| Test suite for CGEN_037: Case Scrutinee Type Agreement invariant.

`eco.case` scrutinee is `i1` only for boolean cases; otherwise `!eco.value`.

-}

import Compiler.Generate.CodeGen.CaseScrutineeType exposing (expectCaseScrutineeType)
import Compiler.StandardTestSuites as StandardTestSuites
import Test exposing (Test)


suite : Test
suite =
    Test.describe "CGEN_037: Case Scrutinee Type Agreement"
        [ StandardTestSuites.expectSuite expectCaseScrutineeType "passes case scrutinee type invariant"
        ]
