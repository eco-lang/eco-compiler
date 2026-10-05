module TestLogic.Generate.MonoTypeShapeTest exposing (suite)

{-| The program handed to code generation must hold no number variable, an
`MVar` with the `CNumber` constraint, which stands for an `Int` or a `Float`
not yet chosen. This module runs
`TestLogic.Generate.MonoTypeShape.expectMonoTypesFullyElaborated` on the
programs of the standard test catalogue, those
`SourceIR.Suite.StandardTestSuites.expectSuite` gathers from its case modules.

Each program goes through the pipeline of a default build
(`TestLogic.TestPipeline.runToGlobalOptLssOn`: the solver engine, the
post-monomorphization inliner and the global optimizer), and every type in the
optimized graph, at every position and depth, must be free of number
variables.

Among what is not tested: the generated MLIR, and the `SourceIR` case modules
the standard catalogue leaves out.

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
