module Compiler.Generate.CodeGen.EcoUnboxSanityTest exposing (suite, expectSuite)

{-| Test suite for CGEN_0E2: eco.unbox Sanity invariant.

eco.unbox converts !eco.value (boxed) to a primitive type (i1, i16, i64, f64).
This test verifies:

1.  The operand is !eco.value
2.  The result is a primitive type (i1, i16, i64, or f64)

Note: i32 is NOT a primitive in eco.

-}

import Compiler.AST.Source as Src
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
import Compiler.Generate.CodeGen.EcoUnboxSanity exposing (expectEcoUnboxSanity)
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
import Compiler.PortEncodingTests as PortEncodingTests
import Compiler.RecordTests as RecordTests
import Compiler.SpecializeAccessorTests as SpecializeAccessorTests
import Compiler.SpecializeConstructorTests as SpecializeConstructorTests
import Compiler.SpecializeCycleTests as SpecializeCycleTests
import Compiler.SpecializeExprTests as SpecializeExprTests
import Compiler.TupleTests as TupleTests
import Compiler.Type.PostSolve.PostSolveExprTests as PostSolveExprTests
import Expect exposing (Expectation)
import Test exposing (Test)


suite : Test
suite =
    Test.describe "CGEN_0E2: eco.unbox Sanity"
        [ expectSuite expectEcoUnboxSanity "passes eco.unbox sanity invariant"
        ]


expectSuite : (Src.Module -> Expectation) -> String -> Test
expectSuite expectFn condStr =
    Test.describe ("eco.unbox sanity invariant " ++ condStr)
        [ AnnotatedTests.expectSuite expectFn condStr
        , ArrayTest.expectSuite expectFn condStr
        , AsPatternTests.expectSuite expectFn condStr
        , BinopTests.expectSuite expectFn condStr
        , BitwiseTests.expectSuite expectFn condStr
        , CaseTests.expectSuite expectFn condStr
        , ClosureTests.expectSuite expectFn condStr
        , ControlFlowTests.expectSuite expectFn condStr
        , DecisionTreeAdvancedTests.expectSuite expectFn condStr
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
        , PortEncodingTests.expectSuite expectFn condStr
        , PostSolveExprTests.expectSuite expectFn condStr
        , RecordTests.expectSuite expectFn condStr
        , SpecializeAccessorTests.expectSuite expectFn condStr
        , SpecializeConstructorTests.expectSuite expectFn condStr
        , SpecializeCycleTests.expectSuite expectFn condStr
        , SpecializeExprTests.expectSuite expectFn condStr
        , TupleTests.expectSuite expectFn condStr
        ]
