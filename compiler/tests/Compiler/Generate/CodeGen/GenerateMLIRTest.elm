module Compiler.Generate.CodeGen.GenerateMLIRTest exposing (suite)

{-| Test suite for verifying that monomorphized code can be compiled to MLIR.

This runs all the standard test cases (excluding TypeCheckFails) through
the typed optimization pipeline, monomorphization, and MLIR code generation.

-}

import Compiler.Generate.CodeGen.GenerateMLIR exposing (expectMLIRGeneration)
import Compiler.StandardTestSuites as StandardTestSuites
import Test exposing (Test)


suite : Test
suite =
    StandardTestSuites.expectSuite expectMLIRGeneration "generates MLIR"
