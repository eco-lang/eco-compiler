module TestLogic.Monomorphize.DebugPolymorphismTest exposing (suite)

{-| Tests invariant MONO\_009 on the standard catalogue of test programs: a
`Debug` kernel reference keeps the kernel's type variables as `CEcoValue`
variables, so every direct call of a `Debug` kernel agrees with the
reference's type, whatever types it is used at.

Each program `SourceIR.Suite.StandardTestSuites.expectSuite` supplies is given
to `TestLogic.Monomorphize.DebugPolymorphism.expectDebugPolymorphismResolved`,
which monomorphizes it with `TestLogic.TestPipeline.runToMono` and, at each
call of a `Debug` kernel, pairs the reference's parameter types with the
arguments: a `CEcoValue` variable agrees with anything, and every other part
must be the type passed. A program with no such call passes once it
monomorphizes.

The catalogue includes `SourceIR.DebugKernelCases`, the programs this check was
first written for, which call the `Debug` kernels at concrete and at `number`
types.

Among what is not tested: `Debug` references passed as function values rather
than called, and the values the `Debug` functions print or return.

-}

import SourceIR.Suite.StandardTestSuites as StandardTestSuites
import Test exposing (Test)
import TestLogic.Monomorphize.DebugPolymorphism exposing (expectDebugPolymorphismResolved)


{-| `expectDebugPolymorphismResolved` over every program of the standard
catalogue.
-}
suite : Test
suite =
    Test.describe "Debug kernel functions handle polymorphism (MONO_009)"
        [ StandardTestSuites.expectSuite expectDebugPolymorphismResolved "calls its Debug kernels at their reference types"
        ]
