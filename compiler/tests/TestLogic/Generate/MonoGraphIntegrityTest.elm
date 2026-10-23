module TestLogic.Generate.MonoGraphIntegrityTest exposing (suite)

{-| Runs the four monomorphized-graph checks of
`TestLogic.Generate.MonoGraphIntegrity` on the standard catalogue of test
programs, so that a graph with a dangling reference, a registry entry with no
node or a node with no registry entry, or a function-typed definition that is
not callable fails a test on any of those programs, not only on a hand-picked few.

The programs are the ones `SourceIR.Suite.StandardTestSuites.expectSuite`
gives to an expectation: the source programs built by each `SourceIR` case
module it includes. Each checker compiles a program with
`TestLogic.TestPipeline`, whose `runToMono` and `runToGlobalOpt` compile it the
way a default build does. A _SpecId_ is the number of one specialization, a definition at one set
of types, and the graph holds at most one node per SpecId.

What the tests establish, one group per checker, as
`TestLogic.Generate.MonoGraphIntegrity` states each check in full:

  - `expectCallableMonoNodes`: in each program's graph after global
    optimization, every function-typed `MonoDefine` has an expression the
    checker counts as callable, and every `MonoTailFunc` has a function type.
  - `expectSpecRegistryComplete` (MONO\_005): every SpecId with an entry in
    the specialization registry's `reverseMapping` has a node and every node
    has an entry; no specialization (global and spec key of its type) has
    two SpecIds; and the registry's `mapping`, when the graph keeps it,
    agrees with `reverseMapping`. The graph `runToMono` returns has an empty
    `mapping`, so that last part compares nothing there.
  - `expectMonoGraphComplete`: every custom type the graph uses, including in
    the constructor fields of its `ctorShapes` table, has an entry in that
    table.
  - `expectMonoGraphClosed`: every SpecId named by a `MonoVarGlobal` has a
    node, every `MonoVarLocal` is in scope where it occurs (closures see only
    their parameters and captures, a case's root variable must be in scope),
    and a `let` definition names a later one only when they are mutually
    recursive.

Among what is not tested: programs from the `SourceIR` case modules that
`StandardTestSuites` leaves out; graphs built by the substitution engine; and that a
`ctorShapes` entry lists all of its type's constructors.

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
        , Test.describe "MONO_005: Specialization registry and nodes agree (no missing or orphan entries, one SpecId per key)"
            [ StandardTestSuites.expectSuite expectSpecRegistryComplete "has a registry that agrees with its nodes"
            ]
        , Test.describe "MONO_010: MonoGraph is type complete"
            [ StandardTestSuites.expectSuite expectMonoGraphComplete "is type complete"
            ]
        , Test.describe "MONO_011: MonoGraph is closed and hygienic"
            [ StandardTestSuites.expectSuite expectMonoGraphClosed "is closed"
            ]
        ]
