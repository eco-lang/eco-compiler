module Compiler.Canonicalize.GlobalNamesTest exposing (suite)

{-| Test suite for invariant CANON_001: Global names are fully qualified.

This module gathers test cases and runs them with the GlobalNames test logic.

-}

import Compiler.AST.Canonical as Can
import Compiler.AST.Source as Src
import Compiler.AnnotatedTests as AnnotatedTests
import Compiler.ArrayTest as ArrayTest
import Compiler.AsPatternTests as AsPatternTests
import Compiler.BinopTests as BinopTests
import Compiler.BitwiseTests as BitwiseTests
import Compiler.Canonicalize.GlobalNames exposing (expectGlobalNamesQualified, expectGlobalNamesQualifiedCanonical)
import Compiler.CaseTests as CaseTests
import Compiler.ClosureTests as ClosureTests
import Compiler.ControlFlowTests as ControlFlowTests
import Compiler.DeepFuzzTests as DeepFuzzTests
import Compiler.EdgeCaseTests as EdgeCaseTests
import Compiler.FloatMathTests as FloatMathTests
import Compiler.ForeignTests as ForeignTests
import Compiler.FunctionTests as FunctionTests
import Compiler.HigherOrderTests as HigherOrderTests
import Compiler.KernelTests as KernelTests
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
import Compiler.TypeCheckFails as TypeCheckFails
import Expect exposing (Expectation)
import Test exposing (Test)


suite : Test
suite =
    expectSuite expectGlobalNamesQualified expectGlobalNamesQualifiedCanonical "has qualified global names"


expectSuite : (Src.Module -> Expectation) -> (Can.Module -> Expectation) -> String -> Test
expectSuite expectFn expectFnCanonical condStr =
    Test.describe "Global names are fully qualified (CANON_001)"
        [ AnnotatedTests.expectSuite expectFn condStr
        , ArrayTest.expectSuite expectFn condStr
        , AsPatternTests.expectSuite expectFn condStr
        , BinopTests.expectSuite expectFn condStr
        , BitwiseTests.expectSuite expectFn condStr
        , CaseTests.expectSuite expectFn condStr
        , ClosureTests.expectSuite expectFn condStr
        , ControlFlowTests.expectSuite expectFn condStr
        , DeepFuzzTests.expectSuite expectFn condStr
        , EdgeCaseTests.expectSuite expectFn condStr
        , FloatMathTests.expectSuite expectFn condStr
        , FunctionTests.expectSuite expectFn condStr
        , HigherOrderTests.expectSuite expectFn condStr
        , LetDestructTests.expectSuite expectFn condStr
        , LetRecTests.expectSuite expectFn condStr
        , LetTests.expectSuite expectFn condStr
        , ListTests.expectSuite expectFn condStr
        , LiteralTests.expectSuite expectFn condStr
        , MultiDefTests.expectSuite expectFn condStr
        , OperatorTests.expectSuite expectFn condStr
        , PatternArgTests.expectSuite expectFn condStr
        , PatternMatchingTests.expectSuite expectFn condStr
        , RecordTests.expectSuite expectFn condStr
        , SpecializeAccessorTests.expectSuite expectFn condStr
        , SpecializeConstructorTests.expectSuite expectFn condStr
        , SpecializeCycleTests.expectSuite expectFn condStr
        , SpecializeExprTests.expectSuite expectFn condStr
        , TupleTests.expectSuite expectFn condStr
        , TypeCheckFails.expectSuite expectFn condStr

        -- Kernel and Foreign tests require canonical AST (not from Source)
        , KernelTests.expectSuite expectFnCanonical condStr
        , ForeignTests.expectSuite expectFnCanonical condStr
        ]
