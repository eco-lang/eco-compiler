module SourceIR.Suite.StandardTestSuites exposing (expectSuite)

{-| Standard test suite aggregator that runs all common test modules.

This module provides a single `expectSuite` function that aggregates all
standard test modules, making it easy to run the same set of tests across
different compiler phases.

-}

import Compiler.AST.Source as Src
import Expect exposing (Expectation)
import SourceIR.AccessorFuzzCases as AccessorFuzzCases
import SourceIR.AnnotatedCases as AnnotatedCases
import SourceIR.ArrayCases as ArrayCases
import SourceIR.AsPatternCases as AsPatternCases
import SourceIR.BinopCases as BinopCases
import SourceIR.BitwiseCases as BitwiseCases
import SourceIR.BoolCaseCases as BoolCaseCases
import SourceIR.BytesFusionCases as BytesFusionCases
import SourceIR.CaseCases as CaseCases
import SourceIR.ClosureAbiBranchCases as ClosureAbiBranchCases
import SourceIR.ClosureCaptureBoolCases as ClosureCaptureBoolCases
import SourceIR.ClosureCases as ClosureCases
import SourceIR.CombinatorCases as CombinatorCases
import SourceIR.CombinatorStdlibCases as CombinatorStdlibCases
import SourceIR.CompositionOpCases as CompositionOpCases
import SourceIR.ControlFlowCases as ControlFlowCases
import SourceIR.DecisionTreeAdvancedCases as DecisionTreeAdvancedCases
import SourceIR.EdgeCaseCases as EdgeCaseCases
import SourceIR.EqualityPapCases as EqualityPapCases
import SourceIR.FloatMathCases as FloatMathCases
import SourceIR.FunctionCases as FunctionCases
import SourceIR.HigherOrderCases as HigherOrderCases
import SourceIR.JoinpointABICases as JoinpointABICases
import SourceIR.KernelComparisonCases as KernelComparisonCases
import SourceIR.KernelCompositionCases as KernelCompositionCases
import SourceIR.KernelContextCases as KernelContextCases
import SourceIR.KernelCtorArgCases as KernelCtorArgCases
import SourceIR.KernelHigherOrderCases as KernelHigherOrderCases
import SourceIR.KernelIntrinsicCases as KernelIntrinsicCases
import SourceIR.KernelOperatorCases as KernelOperatorCases
import SourceIR.KernelPapAbiCases as KernelPapAbiCases
import SourceIR.LetCases as LetCases
import SourceIR.LetDestructCases as LetDestructCases
import SourceIR.LetDestructFnCases as LetDestructFnCases
import SourceIR.LetRecCases as LetRecCases
import SourceIR.ListCases as ListCases
import SourceIR.LiteralCases as LiteralCases
import SourceIR.LocalTailRecCases as LocalTailRecCases
import SourceIR.MaybeResultCases as MaybeResultCases
import SourceIR.MonoCompoundCases as MonoCompoundCases
import SourceIR.MultiDefCases as MultiDefCases
import SourceIR.MutualRecTailRecCases as MutualRecTailRecCases
import SourceIR.OperatorCases as OperatorCases
import SourceIR.ParamArityCases as ParamArityCases
import SourceIR.PatternArgCases as PatternArgCases
import SourceIR.PatternComplexityFuzzCases as PatternComplexityFuzzCases
import SourceIR.PatternMatchingCases as PatternMatchingCases
import SourceIR.PolyChainCases as PolyChainCases
import SourceIR.PolyEscapeCases as PolyEscapeCases
import SourceIR.PortEncodingCases as PortEncodingCases
import SourceIR.PostSolveExprCases as PostSolveExprCases
import SourceIR.RecordCases as RecordCases
import SourceIR.RecursiveTreeTraversalCases as RecursiveTreeTraversalCases
import SourceIR.RecursiveTypeCases as RecursiveTypeCases
import SourceIR.SpecializeAccessorCases as SpecializeAccessorCases
import SourceIR.SpecializeConstructorCases as SpecializeConstructorCases
import SourceIR.SpecializeCycleCases as SpecializeCycleCases
import SourceIR.SpecializeExprCases as SpecializeExprCases
import SourceIR.SpecializePolyLetCases as SpecializePolyLetCases
import SourceIR.SpecializePolyTopCases as SpecializePolyTopCases
import SourceIR.SpecializeRecordCtorCases as SpecializeRecordCtorCases
import SourceIR.IfLetSafepointCases as IfLetSafepointCases
import SourceIR.TailRecCaseCases as TailRecCaseCases
import SourceIR.TailRecLetRecClosureCases as TailRecLetRecClosureCases
import SourceIR.TupleCases as TupleCases
import Test exposing (Test)


expectSuite : (Src.Module -> Expectation) -> String -> Test
expectSuite expectFn condStr =
    Test.describe condStr
        [ -- Non-fuzzed Tests
          AnnotatedCases.expectSuite expectFn condStr
        , ArrayCases.expectSuite expectFn condStr
        , AsPatternCases.expectSuite expectFn condStr
        , BinopCases.expectSuite expectFn condStr
        , BitwiseCases.expectSuite expectFn condStr
        , BoolCaseCases.expectSuite expectFn condStr
        , BytesFusionCases.expectSuite expectFn condStr
        , ClosureAbiBranchCases.expectSuite expectFn condStr
        , ClosureCaptureBoolCases.expectSuite expectFn condStr
        , CaseCases.expectSuite expectFn condStr
        , CombinatorCases.expectSuite expectFn condStr
        , CombinatorStdlibCases.expectSuite expectFn condStr
        , CompositionOpCases.expectSuite expectFn condStr
        , ClosureCases.expectSuite expectFn condStr
        , ControlFlowCases.expectSuite expectFn condStr
        , DecisionTreeAdvancedCases.expectSuite expectFn condStr
        , EdgeCaseCases.expectSuite expectFn condStr
        , EqualityPapCases.expectSuite expectFn condStr
        , FloatMathCases.expectSuite expectFn condStr
        , FunctionCases.expectSuite expectFn condStr
        , HigherOrderCases.expectSuite expectFn condStr
        , JoinpointABICases.expectSuite expectFn condStr
        , LetDestructCases.expectSuite expectFn condStr
        , LetDestructFnCases.expectSuite expectFn condStr
        , LetRecCases.expectSuite expectFn condStr
        , LetCases.expectSuite expectFn condStr
        , ListCases.expectSuite expectFn condStr
        , LiteralCases.expectSuite expectFn condStr
        , MonoCompoundCases.expectSuite expectFn condStr
        , MultiDefCases.expectSuite expectFn condStr
        , MutualRecTailRecCases.expectSuite expectFn condStr
        , OperatorCases.expectSuite expectFn condStr
        , ParamArityCases.expectSuite expectFn condStr
        , PatternArgCases.expectSuite expectFn condStr
        , PatternMatchingCases.expectSuite expectFn condStr
        , PolyChainCases.expectSuite expectFn condStr
        , PolyEscapeCases.expectSuite expectFn condStr
        , PortEncodingCases.expectSuite expectFn condStr
        , PostSolveExprCases.expectSuite expectFn condStr
        , RecordCases.expectSuite expectFn condStr
        , MaybeResultCases.expectSuite expectFn condStr
        , RecursiveTreeTraversalCases.expectSuite expectFn condStr
        , RecursiveTypeCases.expectSuite expectFn condStr
        , SpecializeAccessorCases.expectSuite expectFn condStr
        , SpecializeConstructorCases.expectSuite expectFn condStr
        , SpecializeRecordCtorCases.expectSuite expectFn condStr
        , SpecializeCycleCases.expectSuite expectFn condStr
        , SpecializeExprCases.expectSuite expectFn condStr
        , SpecializePolyLetCases.expectSuite expectFn condStr
        , SpecializePolyTopCases.expectSuite expectFn condStr
        , IfLetSafepointCases.expectSuite expectFn condStr
        , LocalTailRecCases.expectSuite expectFn condStr
        , TailRecCaseCases.expectSuite expectFn condStr
        , TailRecLetRecClosureCases.expectSuite expectFn condStr
        , TupleCases.expectSuite expectFn condStr
        , KernelIntrinsicCases.expectSuite expectFn condStr
        , KernelPapAbiCases.expectSuite expectFn condStr
        , KernelOperatorCases.expectSuite expectFn condStr
        , KernelComparisonCases.expectSuite expectFn condStr
        , KernelContextCases.expectSuite expectFn condStr
        , KernelHigherOrderCases.expectSuite expectFn condStr
        , KernelCompositionCases.expectSuite expectFn condStr
        , KernelCtorArgCases.expectSuite expectFn condStr

        -- Fuzz Tests
        , PatternComplexityFuzzCases.expectSuite expectFn condStr
        , AccessorFuzzCases.expectSuite expectFn condStr
        ]
