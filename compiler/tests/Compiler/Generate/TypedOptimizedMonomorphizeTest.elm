module Compiler.Generate.TypedOptimizedMonomorphizeTest exposing (suite)

{-| Test suite for verifying that TypedOptimized code can be monomorphized.

This runs all the standard test cases (excluding TypeCheckFails) through
the typed optimization pipeline and then monomorphization.

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
import Compiler.Generate.TypedOptimizedMonomorphize exposing (expectMonomorphization)
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
    Test.describe "TypedOptimized code monomorphizes successfully"
        [ AnnotatedTests.expectSuite expectMonomorphization "monomorphizes"
        , ArrayTest.expectSuite expectMonomorphization "monomorphizes"
        , AsPatternTests.expectSuite expectMonomorphization "monomorphizes"
        , BinopTests.expectSuite expectMonomorphization "monomorphizes"
        , BitwiseTests.expectSuite expectMonomorphization "monomorphizes"
        , CaseTests.expectSuite expectMonomorphization "monomorphizes"
        , ClosureTests.expectSuite expectMonomorphization "monomorphizes"
        , ControlFlowTests.expectSuite expectMonomorphization "monomorphizes"
        , DeepFuzzTests.expectSuite expectMonomorphization "monomorphizes"
        , EdgeCaseTests.expectSuite expectMonomorphization "monomorphizes"
        , FloatMathTests.expectSuite expectMonomorphization "monomorphizes"
        , FunctionTests.expectSuite expectMonomorphization "monomorphizes"
        , HigherOrderTests.expectSuite expectMonomorphization "monomorphizes"
        , LetDestructTests.expectSuite expectMonomorphization "monomorphizes"
        , LetRecTests.expectSuite expectMonomorphization "monomorphizes"
        , LetTests.expectSuite expectMonomorphization "monomorphizes"
        , ListTests.expectSuite expectMonomorphization "monomorphizes"
        , LiteralTests.expectSuite expectMonomorphization "monomorphizes"
        , MultiDefTests.expectSuite expectMonomorphization "monomorphizes"
        , OperatorTests.expectSuite expectMonomorphization "monomorphizes"
        , PatternArgTests.expectSuite expectMonomorphization "monomorphizes"
        , PatternMatchingTests.expectSuite expectMonomorphization "monomorphizes"
        , RecordTests.expectSuite expectMonomorphization "monomorphizes"
        , SpecializeAccessorTests.expectSuite expectMonomorphization "monomorphizes"
        , SpecializeConstructorTests.expectSuite expectMonomorphization "monomorphizes"
        , SpecializeCycleTests.expectSuite expectMonomorphization "monomorphizes"
        , SpecializeExprTests.expectSuite expectMonomorphization "monomorphizes"
        , TupleTests.expectSuite expectMonomorphization "monomorphizes"
        ]
