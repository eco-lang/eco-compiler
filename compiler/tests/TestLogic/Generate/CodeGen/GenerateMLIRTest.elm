module TestLogic.Generate.CodeGen.GenerateMLIRTest exposing (suite)

{-| Test suite for verifying that monomorphized code can be compiled to MLIR.

This runs all the standard test cases (excluding TypeCheckFails) through
the typed optimization pipeline, monomorphization, and MLIR code generation.

-}

import SourceIR.Suite.StandardTestSuites as StandardTestSuites
import Test exposing (Test)
import TestLogic.Generate.CodeGen.GenerateMLIR exposing (expectMLIRGeneration)


suite : Test
suite =
    StandardTestSuites.expectSuite expectMLIRGeneration "generates MLIR"
