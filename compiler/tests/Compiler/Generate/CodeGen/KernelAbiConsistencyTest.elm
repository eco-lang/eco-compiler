module Compiler.Generate.CodeGen.KernelAbiConsistencyTest exposing (suite)

{-| Test suite for CGEN_038: Kernel ABI Consistency invariant.

All calls to the same kernel function must use identical MLIR argument and
result types.

-}

import Compiler.Generate.CodeGen.KernelAbiConsistency exposing (expectKernelAbiConsistency)
import Compiler.StandardTestSuites as StandardTestSuites
import Test exposing (Test)


suite : Test
suite =
    Test.describe "CGEN_038: Kernel ABI Consistency"
        [ StandardTestSuites.expectSuite expectKernelAbiConsistency "passes kernel ABI consistency invariant"
        ]
