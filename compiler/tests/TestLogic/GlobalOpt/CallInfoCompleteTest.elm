module TestLogic.GlobalOpt.CallInfoCompleteTest exposing (suite)

{-| Nothing in the types of a `CallInfo` stops its fields from contradicting
each other, so these tests look for such a contradiction in each program of the
standard catalogue once the global optimizer has run.

The fixture is the set of source programs that
`SourceIR.Suite.StandardTestSuites` gathers from its case modules. Most are
fixed; those built by its fuzz tests can vary from run to run.

`suite` gives each of those programs to
`TestLogic.GlobalOpt.CallInfoComplete.expectCallInfoComplete`. A test fails
when the program does not get through the global optimizer, or when a
`MonoCall` the check reaches, whose `callModel` is `StageCurried`, breaks one
of the rules listed in that module's docstring. The rules relate
`stageArities`, `initialRemaining` and `isSingleStageSaturated` to each other,
to the number of arguments at the call and to the callee's type, and that
docstring names the calls each rule exempts.

Among what is not tested:

  - calls whose `callModel` is `FlattenedExternal`, and calls inside a branch
    that a `case` decision tree holds inline;
  - the `CallInfo` fields the rules do not name;
  - programs that are not in the standard catalogue;
  - that the check reports a `CallInfo` known to be inconsistent, since no test
    gives it one.

-}

import SourceIR.Suite.StandardTestSuites as StandardTestSuites
import Test exposing (Test)
import TestLogic.GlobalOpt.CallInfoComplete exposing (expectCallInfoComplete)


{-| The consistency check for staged calls' `CallInfo`, applied to every
program of the standard catalogue as one test group.
-}
suite : Test
suite =
    Test.describe "CallInfo completeness (GOPT_011-015)"
        [ StandardTestSuites.expectSuite expectCallInfoComplete "has valid CallInfo"
        ]
