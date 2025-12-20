module Compiler.Generate.CodeGen.GenerateMLIRTest exposing (suite)

{-| Test suite for verifying that monomorphized code can be compiled to MLIR.

This runs all the standard test cases (excluding TypeCheckFails) through
the typed optimization pipeline, monomorphization, and MLIR code generation.

-}

import Compiler.AsPatternTests as AsPatternTests
import Compiler.BinopTests as BinopTests
import Compiler.CaseTests as CaseTests
import Compiler.DeepFuzzTests as DeepFuzzTests
import Compiler.EdgeCaseTests as EdgeCaseTests
import Compiler.FunctionTests as FunctionTests
import Compiler.Generate.CodeGen.GenerateMLIR exposing (expectMLIRGeneration)
import Compiler.HigherOrderTests as HigherOrderTests
import Compiler.LetDestructTests as LetDestructTests
import Compiler.LetRecTests as LetRecTests
import Compiler.LetTests as LetTests
import Compiler.ListTests as ListTests
import Compiler.LiteralTests as LiteralTests
import Compiler.MultiDefTests as MultiDefTests
import Compiler.OperatorTests as OperatorTests
import Compiler.PatternArgTests as PatternArgTests
import Compiler.RecordTests as RecordTests
import Compiler.TupleTests as TupleTests
import Test exposing (Test)


suite : Test
suite =
    Test.describe "Monomorphized code generates MLIR successfully"
        [ AsPatternTests.expectSuite expectMLIRGeneration "generates MLIR"
        , BinopTests.expectSuite expectMLIRGeneration "generates MLIR"
        , CaseTests.expectSuite expectMLIRGeneration "generates MLIR"
        , EdgeCaseTests.expectSuite expectMLIRGeneration "generates MLIR"
        , FunctionTests.expectSuite expectMLIRGeneration "generates MLIR"
        , HigherOrderTests.expectSuite expectMLIRGeneration "generates MLIR"
        , LetDestructTests.expectSuite expectMLIRGeneration "generates MLIR"
        , LetRecTests.expectSuite expectMLIRGeneration "generates MLIR"
        , LetTests.expectSuite expectMLIRGeneration "generates MLIR"
        , ListTests.expectSuite expectMLIRGeneration "generates MLIR"
        , LiteralTests.expectSuite expectMLIRGeneration "generates MLIR"
        , MultiDefTests.expectSuite expectMLIRGeneration "generates MLIR"
        , OperatorTests.expectSuite expectMLIRGeneration "generates MLIR"
        , PatternArgTests.expectSuite expectMLIRGeneration "generates MLIR"
        , RecordTests.expectSuite expectMLIRGeneration "generates MLIR"
        , TupleTests.expectSuite expectMLIRGeneration "generates MLIR"

        -- Deep structural fuzz tests
        , DeepFuzzTests.expectSuite expectMLIRGeneration "generates MLIR"
        ]
