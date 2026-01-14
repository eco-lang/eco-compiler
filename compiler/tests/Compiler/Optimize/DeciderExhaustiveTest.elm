module Compiler.Optimize.DeciderExhaustiveTest exposing (suite)

{-| Test suite for invariant TOPT_002: Pattern matches compile to exhaustive decision trees.

-}

import Compiler.AST.Source as Src
import Compiler.CaseTests as CaseTests
import Compiler.EdgeCaseTests as EdgeCaseTests
import Compiler.Optimize.DeciderExhaustive exposing (expectDeciderNoNestedPatterns, expectDeciderComplete)
import Compiler.PatternArgTests as PatternArgTests
import Expect exposing (Expectation)
import Test exposing (Test)


suite : Test
suite =
    Test.describe "Pattern matches compile to exhaustive decision trees (TOPT_002)"
        [ expectSuite expectDeciderNoNestedPatterns "has no nested patterns in deciders"
        , expectSuite expectDeciderComplete "has complete deciders"
        ]


expectSuite : (Src.Module -> Expectation) -> String -> Test
expectSuite expectFn condStr =
    Test.describe condStr
        [ CaseTests.expectSuite expectFn condStr
        , PatternArgTests.expectSuite expectFn condStr
        , EdgeCaseTests.expectSuite expectFn condStr
        ]
