module Compiler.Generate.CodeGen.CaseKindScrutineeTest exposing (suite)

{-| Test suite for CGEN_043: Case Kind Scrutinee Type Agreement invariant.

`eco.case` scrutinee representation and `case_kind` must agree:

  - `case_kind="bool"` requires `i1` scrutinee
  - `case_kind="int"` requires `i64` scrutinee
  - `case_kind="chr"` requires `i16` (ECO char) scrutinee
  - `case_kind="ctor"` requires `!eco.value` scrutinee
  - `case_kind="str"` requires `!eco.value` scrutinee

-}

import Compiler.Generate.CodeGen.CaseKindScrutinee exposing (expectCaseKindScrutinee)
import Compiler.StandardTestSuites as StandardTestSuites
import Test exposing (Test)


suite : Test
suite =
    Test.describe "CGEN_043: Case Kind Scrutinee Type Agreement"
        [ StandardTestSuites.expectSuite expectCaseKindScrutinee "passes case kind scrutinee invariant"
        ]
