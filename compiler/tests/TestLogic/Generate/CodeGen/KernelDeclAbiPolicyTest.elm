module TestLogic.Generate.CodeGen.KernelDeclAbiPolicyTest exposing (suite)

{-| Test suite for KERN\_006: Kernel ABI Type Arbitration invariant.

Verifies that func.func declarations for AllBoxed kernels have all
!eco.value parameter and return types.

-}

import SourceIR.Suite.StandardTestSuites as StandardTestSuites
import Test exposing (Test)
import TestLogic.Generate.CodeGen.KernelDeclAbiPolicy exposing (expectKernelDeclAbiPolicy)


suite : Test
suite =
    Test.describe "KERN_006: Kernel Decl ABI Policy"
        [ StandardTestSuites.expectSuite expectKernelDeclAbiPolicy "passes kernel decl ABI policy invariant"
        ]
