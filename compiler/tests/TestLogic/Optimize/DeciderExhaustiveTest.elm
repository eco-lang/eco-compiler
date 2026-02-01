module TestLogic.Optimize.DeciderExhaustiveTest exposing (suite)

{-| Test suite for invariant TOPT_002: Pattern matches compile to exhaustive decision trees.

-}

import TestLogic.Optimize.DeciderExhaustive exposing (expectDeciderComplete, expectDeciderNoNestedPatterns)
import SourceIR.Suite.StandardTestSuites as StandardTestSuites
import Test exposing (Test)


suite : Test
suite =
    Test.describe "Pattern matches compile to exhaustive decision trees (TOPT_002)"
        [ StandardTestSuites.expectSuite expectDeciderNoNestedPatterns "has no nested patterns in deciders"
        , StandardTestSuites.expectSuite expectDeciderComplete "has complete deciders"
        ]
