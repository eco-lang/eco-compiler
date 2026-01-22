module Compiler.Generate.CodeGen.NoAllocateOpsTest exposing (suite)

{-| Test suite for CGEN_039: No Allocate Ops in Codegen invariant.

MLIR codegen must not emit `eco.allocate*` ops; these are introduced by later
lowering passes.

-}

import Compiler.Generate.CodeGen.NoAllocateOps exposing (expectNoAllocateOps)
import Compiler.StandardTestSuites as StandardTestSuites
import Test exposing (Test)


suite : Test
suite =
    Test.describe "CGEN_039: No Allocate Ops in Codegen"
        [ StandardTestSuites.expectSuite expectNoAllocateOps "passes no allocate ops invariant"
        ]
