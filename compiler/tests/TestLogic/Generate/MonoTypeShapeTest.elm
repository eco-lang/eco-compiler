module TestLogic.Generate.MonoTypeShapeTest exposing (suite)

{-| Monomorphization must leave no number variable in the program it produces.
A number variable is an `MVar` with the `CNumber` constraint, and it stands for
an `Int` or a `Float` not yet chosen; the `MonoType` and `Constraint`
docstrings in `Compiler.AST.Monomorphized` own that rule. This module runs
`TestLogic.Generate.MonoTypeShape.expectMonoTypesFullyElaborated` on the
programs of the standard test catalogue, those
`SourceIR.Suite.StandardTestSuites.expectSuite` gathers from its case modules.

Each program is monomorphized with `TestLogic.TestPipeline.runToMono`, which
uses the substitution engine, not the engine a default build uses, and stops
before global optimization and MLIR generation.

  - `suite` applies `expectMonoTypesFullyElaborated`, which walks the types of
    nodes, of the expressions in them, of tail function, closure and tail
    definition parameters, and of `let` definitions. Despite the names, the
    only type it rejects is a number variable; every concrete type passes, and
    so does an `MVar` with the `CEcoValue` constraint.

As the `MonoTypeShape` docstring explains, the substitution engine already
closes every number variable that walk can reach, so the test passes whenever
its program gets through monomorphization in the test pipeline.

Among what is not tested: the element types of a tuple type and the field
types of a record type, the decision tree of a `case` and any branch body held
inline in it, the graph after global optimization, the generated MLIR, the
engine a default build uses, and the `SourceIR` case modules the standard
catalogue leaves out.

-}

import SourceIR.Suite.StandardTestSuites as StandardTestSuites
import Test exposing (Test)
import TestLogic.Generate.MonoTypeShape exposing (expectMonoTypesFullyElaborated)


{-| The test of this module: `expectMonoTypesFullyElaborated` applied to the
programs of the standard catalogue.
-}
suite : Test
suite =
    Test.describe "MonoType encodes fully elaborated runtime shapes (MONO_001)"
        [ StandardTestSuites.expectSuite expectMonoTypesFullyElaborated "has fully elaborated MonoTypes"
        ]
