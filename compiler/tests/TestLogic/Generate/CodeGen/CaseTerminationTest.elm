module TestLogic.Generate.CodeGen.CaseTerminationTest exposing (suite)

{-| Test suite for CGEN\_028: Case Alternative Termination invariant.

Every `eco.case` alternative region must terminate with `eco.yield`.
This is the only valid terminator for case alternatives.

-}

import SourceIR.Suite.StandardTestSuites as StandardTestSuites
import Test exposing (Test)
import TestLogic.Generate.CodeGen.CaseTermination exposing (expectCaseTermination)


suite : Test
suite =
    Test.describe "CGEN_028: Case Alternative Termination"
        [ StandardTestSuites.expectSuite expectCaseTermination "passes case termination invariant"
        ]
