module Compiler.Generate.CodeGen.GenerateMLIRTest exposing (suite)

{-| Test suite for verifying that monomorphized code can be compiled to MLIR.

This runs all the standard test cases (excluding TypeCheckFails) through
the typed optimization pipeline, monomorphization, and MLIR code generation.

-}

import Compiler.AnnotatedTests as AnnotatedTests
import Compiler.ArrayTest as ArrayTest
import Compiler.AsPatternTests as AsPatternTests
import Compiler.BinopTests as BinopTests
import Compiler.BitwiseTests as BitwiseTests
import Compiler.CaseTests as CaseTests
import Compiler.ClosureTests as ClosureTests
import Compiler.ControlFlowTests as ControlFlowTests
import Compiler.DeepFuzzTests as DeepFuzzTests
import Compiler.EdgeCaseTests as EdgeCaseTests
import Compiler.FloatMathTests as FloatMathTests
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
import Compiler.PatternMatchingTests as PatternMatchingTests
import Compiler.RecordTests as RecordTests
import Compiler.SpecializeAccessorTests as SpecializeAccessorTests
import Compiler.SpecializeConstructorTests as SpecializeConstructorTests
import Compiler.SpecializeCycleTests as SpecializeCycleTests
import Compiler.SpecializeExprTests as SpecializeExprTests
import Compiler.TupleTests as TupleTests
import Test exposing (Test)


suite : Test
suite =
    Test.describe "Monomorphized code generates MLIR successfully"
        [ AnnotatedTests.expectSuite expectMLIRGeneration "generates MLIR"
        , ArrayTest.expectSuite expectMLIRGeneration "generates MLIR"
        , AsPatternTests.expectSuite expectMLIRGeneration "generates MLIR"
        , BinopTests.expectSuite expectMLIRGeneration "generates MLIR"
        , BitwiseTests.expectSuite expectMLIRGeneration "generates MLIR"
        , CaseTests.expectSuite expectMLIRGeneration "generates MLIR"
        , ClosureTests.expectSuite expectMLIRGeneration "generates MLIR"
        , ControlFlowTests.expectSuite expectMLIRGeneration "generates MLIR"
        , DeepFuzzTests.expectSuite expectMLIRGeneration "generates MLIR"
        , EdgeCaseTests.expectSuite expectMLIRGeneration "generates MLIR"
        , FloatMathTests.expectSuite expectMLIRGeneration "generates MLIR"
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
        , PatternMatchingTests.expectSuite expectMLIRGeneration "generates MLIR"
        , RecordTests.expectSuite expectMLIRGeneration "generates MLIR"
        , SpecializeAccessorTests.expectSuite expectMLIRGeneration "generates MLIR"
        , SpecializeConstructorTests.expectSuite expectMLIRGeneration "generates MLIR"
        , SpecializeCycleTests.expectSuite expectMLIRGeneration "generates MLIR"
        , SpecializeExprTests.expectSuite expectMLIRGeneration "generates MLIR"
        , TupleTests.expectSuite expectMLIRGeneration "generates MLIR"
        ]
