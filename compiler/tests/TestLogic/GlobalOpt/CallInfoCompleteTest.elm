module TestLogic.GlobalOpt.CallInfoCompleteTest exposing (suite)

{-| Test suite for CallInfo invariants GOPT\_011 through GOPT\_014.

Validates that after GlobalOpt, all MonoCall CallInfo fields are
internally consistent: stageArities non-empty and positive,
sum matches flattened arity, initialRemaining within bounds, and
isSingleStageSaturated correctly computed.

-}

import SourceIR.Suite.StandardTestSuites as StandardTestSuites
import Test exposing (Test)
import TestLogic.GlobalOpt.CallInfoComplete exposing (expectCallInfoComplete)


suite : Test
suite =
    Test.describe "CallInfo completeness (GOPT_011-014)"
        [ StandardTestSuites.expectSuite expectCallInfoComplete "has valid CallInfo"
        ]
