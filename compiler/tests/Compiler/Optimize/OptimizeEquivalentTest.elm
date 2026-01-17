module Compiler.Optimize.OptimizeEquivalentTest exposing (suite)

{-| Test suite for verifying that Erased and Typed optimization paths
produce structurally equivalent results.

This runs all the standard test cases (excluding TypeCheckFails) through
both optimization pipelines and compares the resulting IRs.

-}

import Compiler.AnnotatedTests as AnnotatedTests
import Compiler.ArrayTest as ArrayTest
import Compiler.AsPatternTests as AsPatternTests
import Compiler.BinopTests as BinopTests
import Compiler.BitwiseTests as BitwiseTests
import Compiler.CaseTests as CaseTests
import Compiler.ClosureTests as ClosureTests
import Compiler.ControlFlowTests as ControlFlowTests
import Compiler.DecisionTreeAdvancedTests as DecisionTreeAdvancedTests
import Compiler.DeepFuzzTests as DeepFuzzTests
import Compiler.EdgeCaseTests as EdgeCaseTests
import Compiler.FloatMathTests as FloatMathTests
import Compiler.FunctionTests as FunctionTests
import Compiler.HigherOrderTests as HigherOrderTests
import Compiler.LetDestructTests as LetDestructTests
import Compiler.LetRecTests as LetRecTests
import Compiler.LetTests as LetTests
import Compiler.ListTests as ListTests
import Compiler.LiteralTests as LiteralTests
import Compiler.MultiDefTests as MultiDefTests
import Compiler.OperatorTests as OperatorTests
import Compiler.Optimize.OptimizeEquivalent exposing (expectEquivalentOptimization)
import Compiler.PatternArgTests as PatternArgTests
import Compiler.PatternMatchingTests as PatternMatchingTests
import Compiler.PortEncodingTests as PortEncodingTests
import Compiler.Type.PostSolve.PostSolveExprTests as PostSolveExprTests
import Compiler.RecordTests as RecordTests
import Compiler.SpecializeAccessorTests as SpecializeAccessorTests
import Compiler.SpecializeConstructorTests as SpecializeConstructorTests
import Compiler.SpecializeCycleTests as SpecializeCycleTests
import Compiler.SpecializeExprTests as SpecializeExprTests
import Compiler.TupleTests as TupleTests
import Test exposing (Test)


suite : Test
suite =
    Test.describe "Erased and Typed optimization produce equivalent results"
        [ AnnotatedTests.expectSuite expectEquivalentOptimization "optimize equivalently"
        , ArrayTest.expectSuite expectEquivalentOptimization "optimize equivalently"
        , AsPatternTests.expectSuite expectEquivalentOptimization "optimize equivalently"
        , BinopTests.expectSuite expectEquivalentOptimization "optimize equivalently"
        , BitwiseTests.expectSuite expectEquivalentOptimization "optimize equivalently"
        , CaseTests.expectSuite expectEquivalentOptimization "optimize equivalently"
        , ClosureTests.expectSuite expectEquivalentOptimization "optimize equivalently"
        , ControlFlowTests.expectSuite expectEquivalentOptimization "optimize equivalently"
        , DecisionTreeAdvancedTests.expectSuite expectEquivalentOptimization "optimize equivalently"
        , DeepFuzzTests.expectSuite expectEquivalentOptimization "optimize equivalently"
        , EdgeCaseTests.expectSuite expectEquivalentOptimization "optimize equivalently"
        , FloatMathTests.expectSuite expectEquivalentOptimization "optimize equivalently"
        , FunctionTests.expectSuite expectEquivalentOptimization "optimize equivalently"
        , HigherOrderTests.expectSuite expectEquivalentOptimization "optimize equivalently"
        , LetDestructTests.expectSuite expectEquivalentOptimization "optimize equivalently"
        , LetRecTests.expectSuite expectEquivalentOptimization "optimize equivalently"
        , LetTests.expectSuite expectEquivalentOptimization "optimize equivalently"
        , ListTests.expectSuite expectEquivalentOptimization "optimize equivalently"
        , LiteralTests.expectSuite expectEquivalentOptimization "optimize equivalently"
        , MultiDefTests.expectSuite expectEquivalentOptimization "optimize equivalently"
        , OperatorTests.expectSuite expectEquivalentOptimization "optimize equivalently"
        , PatternArgTests.expectSuite expectEquivalentOptimization "optimize equivalently"
        , PatternMatchingTests.expectSuite expectEquivalentOptimization "optimize equivalently"
        , PortEncodingTests.expectSuite expectEquivalentOptimization "optimize equivalently"
        , PostSolveExprTests.expectSuite expectEquivalentOptimization "optimize equivalently"
        , RecordTests.expectSuite expectEquivalentOptimization "optimize equivalently"
        , SpecializeAccessorTests.expectSuite expectEquivalentOptimization "optimize equivalently"
        , SpecializeConstructorTests.expectSuite expectEquivalentOptimization "optimize equivalently"
        , SpecializeCycleTests.expectSuite expectEquivalentOptimization "optimize equivalently"
        , SpecializeExprTests.expectSuite expectEquivalentOptimization "optimize equivalently"
        , TupleTests.expectSuite expectEquivalentOptimization "optimize equivalently"
        ]
