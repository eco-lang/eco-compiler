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
substitution engine). For each program it fails if the program does not
compile, if a `reverseMapping` entry has no node at its `SpecId`, or if the
entry's type is not `==` to its node's type. The programs are those of
`SourceIR.Suite.StandardTestSuites`, in one group named
`"registry type matches node"`.

Among what is not tested: a node with no registry entry, the graph the solver
engine produces, and the graph after global optimization.

-}

import SourceIR.Suite.StandardTestSuites as StandardTestSuites
import Test exposing (Test)
import TestLogic.Monomorphize.RegistryNodeTypeConsistency exposing (expectRegistryNodeTypeConsistency)


{-| The standard test programs, each checked with
`expectRegistryNodeTypeConsistency`.
-}
suite : Test
suite =
    Test.describe "MONO_017: Registry type matches node type"
        [ StandardTestSuites.expectSuite expectRegistryNodeTypeConsistency "registry type matches node"
        ]
