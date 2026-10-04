module TestLogic.Generate.MonoGraphIntegrityTest exposing (suite)

{-| Runs the four monomorphized-graph checks of
`TestLogic.Generate.MonoGraphIntegrity` on the standard catalogue of test
programs, so that a graph with a dangling reference, a registry entry with no
node, or a function-typed definition that is not callable fails a test on any
of those programs, not only on a hand-picked few.

The programs are the ones `SourceIR.Suite.StandardTestSuites.expectSuite`
gives to an expectation: the source programs built by each `SourceIR` case
module it includes. Each checker compiles a program with
`TestLogic.TestPipeline`, whose `runToMono` and `runToGlobalOpt` monomorphize
with the substitution engine rather than the solver engine a default build
uses. A _SpecId_ is the number of one specialization, a definition at one set
of types, and the graph holds at most one node per SpecId.

What the tests establish, one group per checker, as
`TestLogic.Generate.MonoGraphIntegrity` states each check in full:

  - `expectCallableMonoNodes`: in each program's graph after global
    optimization, every function-typed `MonoDefine` has an expression the
    checker counts as callable, and every `MonoTailFunc` has a function type.
  - `expectSpecRegistryComplete`: every SpecId with an entry in the
    specialization registry's `reverseMapping` has a node.
  - `expectMonoGraphComplete`: only that each program monomorphizes. The
    group is named for type completeness, but the checker inspects nothing in
    the graph.
  - `expectMonoGraphClosed`: every SpecId named by a `MonoVarGlobal` has a
    node, and every `MonoVarLocal` is in scope where it occurs, under the
    checker's scope rules.

Among what is not tested: programs from the `SourceIR` case modules that
`StandardTestSuites` leaves out; graphs built by the solver engine; that every
type in the graph is complete; and the references the checkers do not visit,
such as those held inline in a case's decision tree.

-}

import SourceIR.Suite.StandardTestSuites as StandardTestSuites
import Test exposing (Test)
import TestLogic.Generate.MonoGraphIntegrity
    exposing
        ( expectCallableMonoNodes
        , expectMonoGraphClosed
        , expectMonoGraphComplete
        , expectSpecRegistryComplete
        )


{-| The four groups of tests listed above, one per checker, each running that
checker over the standard catalogue of programs.
-}
suite : Test
suite =
    Test.describe "MonoGraph integrity invariants"
        [ Test.describe "MONO_004: All functions are callable MonoNodes"
            [ StandardTestSuites.expectSuite expectCallableMonoNodes "has callable function nodes"
            ]
        , Test.describe "MONO_005: Specialization registry is complete"
            [ StandardTestSuites.expectSuite expectSpecRegistryComplete "has complete registry"
            ]
        , Test.describe "MONO_010: MonoGraph is type complete"
            [ StandardTestSuites.expectSuite expectMonoGraphComplete "is type complete"
            ]
        , Test.describe "MONO_011: MonoGraph is closed and hygienic"
            [ StandardTestSuites.expectSuite expectMonoGraphClosed "is closed"
            ]
        ]
