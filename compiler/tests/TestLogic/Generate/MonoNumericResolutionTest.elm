module TestLogic.Generate.MonoNumericResolutionTest exposing (suite)

{-| Monomorphization must leave no number variable in the program it produces.
A number variable is an `MVar` with the `CNumber` constraint, and it stands for
an `Int` or a `Float` not yet chosen; the `MonoType` and `Constraint`
docstrings in `Compiler.AST.Monomorphized` own that rule. This module runs the
two checks for it in `TestLogic.Generate.MonoNumericResolution` on the programs
of the standard test catalogue.

The programs are those `SourceIR.Suite.StandardTestSuites.expectSuite` gathers
from its case modules. Each check monomorphizes a program with
`TestLogic.TestPipeline.runToMono`, which uses the substitution engine, not the
engine a default build uses, and stops before global optimization and MLIR
generation.

  - `noNumericPolymorphismSuite` applies `expectNoNumericPolymorphism`, which
    looks for a number variable in the types of nodes, of the expressions in
    them, of tail function, closure and tail definition parameters, and of
    `let` definitions, with the exceptions its own docstring lists.
  - `numericTypesResolvedSuite` applies `expectNumericTypesResolved`, which
    looks only in the types of call and tail-call arguments.

As the `MonoNumericResolution` docstring explains, the substitution engine
already closes every number variable these checks can reach, so on a graph
`runToMono` returns they find nothing. A test here passes whenever its program
gets through monomorphization in the test pipeline.

Among what is not tested: a number variable inside a tuple or record type or
in a case branch body held inline in its decision tree, the graph after global
optimization, the generated MLIR, the engine a default build uses, and the
`SourceIR` case modules the standard catalogue leaves out.

-}

import SourceIR.Suite.StandardTestSuites as StandardTestSuites
import Test exposing (Test)
import TestLogic.Generate.MonoNumericResolution
    exposing
        ( expectNoNumericPolymorphism
        , expectNumericTypesResolved
        )


{-| All the tests of this module: `noNumericPolymorphismSuite` and
`numericTypesResolvedSuite` in one group.
-}
suite : Test
suite =
    Test.describe "Numeric type resolution in monomorphization"
        [ noNumericPolymorphismSuite
        , numericTypesResolvedSuite
        ]


{-| The group that applies `expectNoNumericPolymorphism` to the programs of the
standard catalogue. Its name says "at MLIR entry", but the graph checked is
taken before MLIR generation.
-}
noNumericPolymorphismSuite : Test
noNumericPolymorphismSuite =
    Test.describe "No CNumber MVar at MLIR entry (MONO_002)"
        [ StandardTestSuites.expectSuite expectNoNumericPolymorphism "has no CNumber MVars"
        ]


{-| The group that applies `expectNumericTypesResolved`, which inspects only the
types of call and tail-call arguments, to the programs of the standard
catalogue.
-}
numericTypesResolvedSuite : Test
numericTypesResolvedSuite =
    Test.describe "Numeric types fixed at call sites (MONO_008)"
        [ StandardTestSuites.expectSuite expectNumericTypesResolved "has resolved numeric types"
        ]
