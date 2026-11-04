module TestLogic.MonoOpt.PostPruneGraphClosedTest exposing (suite)

{-| Runs the MONO\_011 checks of `TestLogic.MonoOpt.PostPruneGraphClosed` over
the standard catalogue of test programs, so that a post-inline prune that
removes a spec a live body still names, keeps one nothing reaches, or leaves the
registry out of step with the nodes, is looked for in many kinds of program, not
only in the three fixtures of `Compiler.Monomorphize.PostInlinePruneTest`.

A _spec_ is one node of the monomorphized graph, live while its slot holds a
node. MONO\_011 says the graph is closed (every `MonoVarGlobal` names a live
spec) and hygienic (every local in scope), and that after pruning no
unreachable spec is left in the nodes or the registry.
`TestLogic.Generate.MonoGraphIntegrityTest` checks closedness before the
post-monomorphization inliner; these tests check it after it. The checker's
module docstring says how each graph is built and what is not checked.

The fixture is every program that `SourceIR.Suite.StandardTestSuites` passes to
its caller's expectation.

What the tests establish:

  - `"satisfies MONO_011 after the post-inline prune"`: for each program, the
    graph after `Steps.inline` and `Steps.prune` is closed and hygienic, every
    live spec is reachable from the roots, and a spec has a registry entry
    exactly when it is live; and the graph after global optimization is closed
    and hygienic. Both graphs come from one pipeline run, and a failure message
    names the graph it is about.

Among what is not tested: configurations other than the production one, such as
`inline.pruneDead` off, and the substitution engine.

-}

import SourceIR.Suite.StandardTestSuites as StandardTestSuites
import Test exposing (Test)
import TestLogic.MonoOpt.PostPruneGraphClosed exposing (expectClosedAfterPrune)


{-| The MONO\_011 checks over every standard test program.
-}
suite : Test
suite =
    Test.describe "MONO_011 after the post-inline prune"
        [ StandardTestSuites.expectSuite expectClosedAfterPrune "satisfies MONO_011 after the post-inline prune"
        ]
