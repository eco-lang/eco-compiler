module Compiler.Generate.MonoGraphIntegrityTest exposing (suite)

{-| Test suite for MonoGraph integrity invariants:

  - MONO_004: All functions are callable MonoNodes
  - MONO_005: Specialization registry is complete and consistent
  - MONO_010: MonoGraph is type complete
  - MONO_011: MonoGraph is closed and hygienic

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
import Compiler.Generate.MonoGraphIntegrity exposing
    ( expectCallableMonoNodes
    , expectMonoGraphComplete
    , expectMonoGraphClosed
    , expectSpecRegistryComplete
    )
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
import Compiler.Type.PostSolve.PostSolveExprTests as PostSolveExprTests
import Compiler.RecordTests as RecordTests
import Compiler.SpecializeAccessorTests as SpecializeAccessorTests
import Compiler.SpecializeConstructorTests as SpecializeConstructorTests
import Compiler.SpecializeCycleTests as SpecializeCycleTests
import Compiler.SpecializeExprTests as SpecializeExprTests
import Compiler.TupleTests as TupleTests
import Expect exposing (Expectation)
import Test exposing (Test)


suite : Test
suite =
    Test.describe "MonoGraph integrity invariants"
        [ Test.describe "MONO_004: All functions are callable MonoNodes"
            [ expectSuite expectCallableMonoNodes "has callable function nodes"
            ]
        , Test.describe "MONO_005: Specialization registry is complete"
            [ expectSuite expectSpecRegistryComplete "has complete registry"
            ]
        , Test.describe "MONO_010: MonoGraph is type complete"
            [ expectSuite expectMonoGraphComplete "is type complete"
            ]
        , Test.describe "MONO_011: MonoGraph is closed and hygienic"
            [ expectSuite expectMonoGraphClosed "is closed"
            ]
        ]


expectSuite : (Src.Module -> Expectation) -> String -> Test
expectSuite expectFn condStr =
    Test.describe condStr
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
