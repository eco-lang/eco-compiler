module TestLogic.Generate.CodeGen.CaseNotTerminatorTest exposing (suite)

{-| Test suite for CGEN\_045: eco.case is NOT a block terminator.

eco.case is a value-producing expression and must never be a block terminator.

-}

import SourceIR.Suite.StandardTestSuites as StandardTestSuites
import Test exposing (Test)
import TestLogic.Generate.CodeGen.CaseNotTerminator exposing (expectCaseNotTerminator)


suite : Test
suite =
    Test.describe "CGEN_045: eco.case Not a Terminator"
        [ StandardTestSuites.expectSuite expectCaseNotTerminator "passes eco.case not terminator invariant"
        ]
