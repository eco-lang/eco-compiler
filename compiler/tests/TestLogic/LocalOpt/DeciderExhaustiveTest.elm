module TestLogic.LocalOpt.DeciderExhaustiveTest exposing (suite)

{-| Test suite for invariant TOPT\_002: Pattern matches compile to exhaustive decision trees.
-}

import SourceIR.Suite.StandardTestSuites as StandardTestSuites
import Test exposing (Test)
import TestLogic.LocalOpt.DeciderExhaustive exposing (expectDeciderComplete, expectDeciderNoNestedPatterns)


suite : Test
suite =
    Test.describe "Pattern matches compile to exhaustive decision trees (TOPT_002)"
        [ StandardTestSuites.expectSuite expectDeciderNoNestedPatterns "has no nested patterns in deciders"
        , StandardTestSuites.expectSuite expectDeciderComplete "has complete deciders"
        ]
