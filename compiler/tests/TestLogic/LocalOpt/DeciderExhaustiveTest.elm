module TestLogic.LocalOpt.DeciderExhaustiveTest exposing (suite)

{-| Runs the two decider checks of `TestLogic.LocalOpt.DeciderExhaustive` on
every program in the standard catalogue. They catch typed optimization turning
a `case` into a decision tree with a leaf that jumps to a missing branch,
whose `FanOut` tests repeat or are malformed, or which tests one part of the
matched value as two different kinds of value.

A _decider_ is the decision tree a `case` becomes in the typed optimized IR;
`TestLogic.LocalOpt.DeciderExhaustive` describes its parts and the checks. The
programs are the ones `SourceIR.Suite.StandardTestSuites.expectSuite` gathers
from the `SourceIR` case modules.

What the tests establish, for each program, over every `case` in it (including
those in inline branches and in the values of recursive groups):

  - "has consistent decider paths" (`expectDeciderPathsConsistent`): every test
    a decider makes at one path is of one kind.
  - "has complete deciders" (`expectDeciderComplete`): every `Jump` names an
    existing jump target, no `FanOut` makes
    the same test twice, and every constructor test's index is below its
    constructor count.

Both fail with the pipeline's message if running the program to the end of
typed optimization returns an error.

Among what is not tested: whether a decider covers every value of the
scrutinee's type; jump targets no leaf names, which the catalogue's redundant
patterns produce; and whether each leaf selects the branch the source `case`
would.

-}

import SourceIR.Suite.StandardTestSuites as StandardTestSuites
import Test exposing (Test)
import TestLogic.LocalOpt.DeciderExhaustive exposing (expectDeciderComplete, expectDeciderPathsConsistent)


{-| The two decider checks, each applied to every standard program in a group
of its own, gathered in one group.
-}
suite : Test
suite =
    Test.describe "Pattern matches compile to well-formed decision trees (TOPT_002)"
        [ StandardTestSuites.expectSuite expectDeciderPathsConsistent "has consistent decider paths"
        , StandardTestSuites.expectSuite expectDeciderComplete "has complete deciders"
        ]
