module TestLogic.LocalOpt.DeciderExhaustiveTest exposing (suite)

{-| Runs the two decider checks of `TestLogic.LocalOpt.DeciderExhaustive` on
every program in the standard catalogue. They are meant to catch typed
optimization turning a `case` into a decision tree that leaves some value
unmatched, or whose tests need nested matching.

A _decider_ is the decision tree a `case` becomes in the typed optimized IR;
`TestLogic.LocalOpt.DeciderExhaustive` describes its parts. The programs are the
ones `SourceIR.Suite.StandardTestSuites.expectSuite` gathers from the
`SourceIR` case modules.

What the tests establish, for each program:

  - "has no nested patterns in deciders" (`expectDeciderNoNestedPatterns`)
    fails with the pipeline's message if running the program to the end of
    typed optimization returns an error. Its check on the paths the deciders
    test reports nothing for any path, so otherwise it passes.
  - "has complete deciders" (`expectDeciderComplete`) fails in the same way
    when the pipeline returns an error. Its walk of the deciders reports
    nothing for any decider, so otherwise it passes.

So, as `TestLogic.LocalOpt.DeciderExhaustive` describes, both checks pass on a
program when typed optimization succeeds on it.

Among what is not tested: whether any decider covers every value, or whether
two of its tests overlap; and anything about the paths a decider tests.

-}

import SourceIR.Suite.StandardTestSuites as StandardTestSuites
import Test exposing (Test)
import TestLogic.LocalOpt.DeciderExhaustive exposing (expectDeciderComplete, expectDeciderNoNestedPatterns)


{-| The two decider checks, each applied to every standard program in a group
of its own, gathered in one group.
-}
suite : Test
suite =
    Test.describe "Pattern matches compile to exhaustive decision trees (TOPT_002)"
        [ StandardTestSuites.expectSuite expectDeciderNoNestedPatterns "has no nested patterns in deciders"
        , StandardTestSuites.expectSuite expectDeciderComplete "has complete deciders"
        ]
