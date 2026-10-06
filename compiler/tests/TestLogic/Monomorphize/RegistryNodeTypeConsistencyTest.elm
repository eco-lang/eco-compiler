module TestLogic.Monomorphize.RegistryNodeTypeConsistencyTest exposing (suite)

{-| Runs the check that the specialization registry and the graph's nodes agree
on the type of every specialization, over the standard test programs.

A _specialization_ is one definition at one `MonoType`, numbered by a `SpecId`.
A monomorphized graph records each specialization's type twice: on its node,
and in its entry in the registry's `reverseMapping`. If the two differ, code that reads a
specialization's type from the registry sees a type other than the one its node
was built at.

The check is
`TestLogic.Monomorphize.RegistryNodeTypeConsistency.expectRegistryNodeTypeConsistency`,
which compiles each program with `TestLogic.TestPipeline.runToMono` (the
production pipeline). For each program it fails if the program does not
compile, if a `reverseMapping` entry has no node at its `SpecId`, or if the
entry's type does not have its node type's layout. Constructor specializations
are skipped there and pinned by the "MONO_017 BUG PIN" group: the solver engine
registers a constructor at its function type while its node holds the
constructed type. The programs are those of `SourceIR.Suite.StandardTestSuites`.

Among what is not tested: a node with no registry entry, and the graph after
global optimization.

-}

import SourceIR.SpecializeConstructorCases as SpecializeConstructorCases
import SourceIR.Suite.StandardTestSuites as StandardTestSuites
import Test exposing (Test)
import TestLogic.Monomorphize.RegistryNodeTypeConsistency exposing (expectCtorRegistryTypes, expectRegistryNodeTypeConsistency)


{-| The standard test programs, each checked with
`expectRegistryNodeTypeConsistency`.
-}
suite : Test
suite =
    Test.describe "MONO_017: Registry type matches node type"
        [ StandardTestSuites.expectSuite expectRegistryNodeTypeConsistency "registry type matches node"
        , Test.describe "MONO_017 BUG PIN: the solver engine registers a constructor spec at its function type"
            [ SpecializeConstructorCases.expectSuite expectCtorRegistryTypes "constructor registry type matches node" ]
        ]
