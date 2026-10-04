module TestLogic.Generate.CodeGen.KernelDeclAbiPolicyTest exposing (suite)

{-| Runs the kernel declaration ABI check on every program in the standard
catalogue of `SourceIR` test programs, so that the check is tried on many
programs rather than on a hand-picked few.

A kernel is a function implemented by the runtime rather than compiled from
Elm. The generated MLIR declares each kernel it uses as a top-level `func.func`
marked `is_kernel`, and `TestLogic.Generate.CodeGen.KernelDeclAbiPolicy`
checks those declarations against the backend ABI policy that
`Compiler.Generate.MLIR.KernelAbi.kernelBackendAbiPolicy` assigns to each
kernel. That policy is `ElmDerived` for every kernel, and for it the check
reports nothing, so at present this suite fails only when a program does not
compile to MLIR.

The programs are those that `SourceIR.Suite.StandardTestSuites.expectSuite`
supplies.

What the tests establish:

  - For each program, `expectKernelDeclAbiPolicy` passes: the program compiles
    to MLIR, and no kernel declaration in it is reported against the policy.

Among what is not tested: the argument and result types of any kernel
declaration, and programs outside the standard catalogue.

-}

import SourceIR.Suite.StandardTestSuites as StandardTestSuites
import Test exposing (Test)
import TestLogic.Generate.CodeGen.KernelDeclAbiPolicy exposing (expectKernelDeclAbiPolicy)


{-| The test group that applies `expectKernelDeclAbiPolicy` to every program
in the standard catalogue.
-}
suite : Test
suite =
    Test.describe "KERN_006: Kernel Decl ABI Policy"
        [ StandardTestSuites.expectSuite expectKernelDeclAbiPolicy "passes kernel decl ABI policy invariant"
        ]
