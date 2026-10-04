module TestLogic.Generate.CodeGen.KernelDeclInstanceConsistencyTest exposing (suite)

{-| Runs the kernel declaration agreement check over the whole standard
catalogue of test programs, so that a kernel used at MLIR types other than
those its declaration states is caught in any of those programs, not only in a
few chosen by hand.

A kernel is a function the runtime implements rather than Elm code. The
generated MLIR declares each kernel it uses as a `func.func` and refers to it
by symbol from calls and partial applications. The check, and exactly which
uses it compares with which declarations, is
`TestLogic.Generate.CodeGen.KernelDeclInstanceConsistency`; its docstring sets
out the rules.

The programs are the ones `SourceIR.Suite.StandardTestSuites.expectSuite`
gathers from its case modules. Each is compiled to MLIR with
`TestLogic.TestPipeline.runToMlir`, which monomorphizes with the substitution
engine and then runs the post-monomorphization optimizations.

  - `suite` passes for a program when it compiles to MLIR and every
    `eco.call`, `eco.papCreate` and `eco.papExtend` naming a declared
    `Elm_Kernel_` kernel agrees with that kernel's declaration. A program that
    does not compile fails.

Among what is not tested:

  - The uses and kernels the checker's own docstring lists as not tested, among
    them kernels whose symbol starts with `Eco_Kernel_` and uses of a kernel
    that has no declaration.
  - Kernel uses through partial application. No `eco.papExtend` the code
    generator emits names its function, so none is compared with a
    declaration, and the `eco.papCreate` it builds for a kernel captures
    nothing, so it has no operand types to compare.
  - MLIR produced by the solver monomorphization engine.
  - Programs of the `SourceIR` case modules that the standard catalogue leaves
    out.

-}

import SourceIR.Suite.StandardTestSuites as StandardTestSuites
import Test exposing (Test)
import TestLogic.Generate.CodeGen.KernelDeclInstanceConsistency exposing (expectKernelDeclInstanceConsistency)


{-| The group of tests that applies the kernel declaration agreement check to
every program of the standard catalogue.
-}
suite : Test
suite =
    Test.describe "CGEN_038: Kernel decl/instance consistency"
        [ StandardTestSuites.expectSuite expectKernelDeclInstanceConsistency "passes kernel decl/instance consistency invariant"
        ]
