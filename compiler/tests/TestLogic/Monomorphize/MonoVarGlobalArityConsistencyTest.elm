module TestLogic.Monomorphize.MonoVarGlobalArityConsistencyTest exposing (suite)

{-| These tests exist because, in a monomorphized graph, a `MonoVarGlobal`
reference to a specialized top-level function carries its own copy of the
function's type, and nothing in the graph makes that copy agree with the type
stored on the function's node. Without a check, a reference could claim a
different number of parameters from its node, or a call through it could
supply more arguments than the node takes, and no test would say so. The test
names call this property MONO\_027.

The check is `TestLogic.Monomorphize.MonoVarGlobalArityConsistency`'s
`expectVarGlobalArityConsistency`, whose docstring defines the _flattened
arity_ it compares, the three kinds of mismatch it looks for and what it leaves
out. It runs a program through global optimization with the substitution
engine, and a program that fails to compile fails the check.

The programs are the standard catalogue of `SourceIR` programs that
`SourceIR.Suite.StandardTestSuites` assembles. It includes, in
`SourceIR.CombinatorCases`, three modules in which every function is a
top-level definition (B and I built from top-level S and K, and a top-level
three-parameter function partially applied by a top-level value). A top-level
function is specialized into a node of its own and referred to by a
`MonoVarGlobal`, so these modules put partially applied references to such
nodes in front of the check.

The tests establish:

  - "has consistent VarGlobal arities": the check passes on every program of
    the standard catalogue.

Among what is not tested:

  - the solver engine's graph, and the graph before global optimization;
  - the value any program computes, since nothing is run.

-}

import SourceIR.Suite.StandardTestSuites as StandardTestSuites
import Test exposing (Test)
import TestLogic.Monomorphize.MonoVarGlobalArityConsistency exposing (expectVarGlobalArityConsistency)


{-| The MONO\_027 tests: the check over the standard catalogue.
-}
suite : Test
suite =
    Test.describe "MonoVarGlobal arity consistency (MONO_027)"
        [ StandardTestSuites.expectSuite expectVarGlobalArityConsistency "has consistent VarGlobal arities"
        ]
