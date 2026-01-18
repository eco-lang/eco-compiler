module Compiler.Generate.CodeGen.ProjectionContainerTypeTest exposing (suite, expectSuite)

{-| Test suite for CGEN_0E1: Projection Container Type invariant.

All projection operations (eco.project.record, eco.project.custom, etc.)
must have !eco.value as their container operand type. This prevents
segfaults from treating primitives as heap pointers.

The dangerous pattern is: project -> eco.unbox -> project
where eco.unbox produces a primitive that is incorrectly used as a container.

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
import Compiler.Generate.CodeGen.ProjectionContainerType exposing (expectProjectionContainerType)
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
    Test.describe "CGEN_0E1: Projection Container Types"
        [ expectSuite expectProjectionContainerType "passes projection container type invariant"
        ]


expectSuite : (Src.Module -> Expectation) -> String -> Test
expectSuite expectFn condStr =
    Test.describe ("Projection container type invariant " ++ condStr)
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
