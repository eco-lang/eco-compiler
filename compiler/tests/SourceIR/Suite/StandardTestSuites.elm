module SourceIR.Suite.StandardTestSuites exposing (expectSuite)

{-| This module lets a check on the compiler be run against the standard
catalogue of `SourceIR` test programs in one call, so that the check is tried on
all of those programs rather than on a hand-picked few.

A case module's `expectSuite` builds Elm source programs (`Src.Module` values)
and gives each one to the expectation its caller passes; it does not decide what
is checked. `expectSuite` here does the same one level up. It takes an expectation
and a description from its caller and passes both, unchanged, to the
`expectSuite` of each of the 104 case modules it imports. What is checked, and
after which compiler stage, is therefore decided by the caller.

Most of these modules build fixed programs. Two of them,
`PatternComplexityFuzzCases` and `AccessorFuzzCases`, hold fuzz tests
(`Test.fuzz`), whose programs can vary from run to run.

Some `SourceIR` case modules are not included. `ForeignCases` and `KernelCases`
build canonical modules (`Can.Module`) rather than source modules, so their
suites take a different kind of expectation. The six modules of the negative
catalogue (`CanonicalizeFailsCases`, `LimitFailsCases`, `TypeCheckFailsCases`,
`PatternFailsCases`, `MainFailsCases` and `MonoFailsCases`), whose programs are
meant to be rejected, are gathered by `SourceIR.Suite.RejectedSuites` instead.
`CaseSafepointLeakCases` takes the same kind of expectation but is left out, and
`LimitBoundaryCases`, whose programs sit exactly at the runtime's size limits,
is too costly to run in every suite; only the size-limit and name-clash oracles
run it.

-}

import Compiler.IR.Source as Src
import Expect exposing (Expectation)
import SourceIR.AccessorFuzzCases as AccessorFuzzCases
import SourceIR.AccessorPlaceholderCases as AccessorPlaceholderCases
import SourceIR.AccessorScopingCases as AccessorScopingCases
import SourceIR.AnnotatedCases as AnnotatedCases
import SourceIR.ArrayCases as ArrayCases
import SourceIR.AsPatternCases as AsPatternCases
import SourceIR.BinopCases as BinopCases
import SourceIR.BitwiseCases as BitwiseCases
import SourceIR.BoolCaseCases as BoolCaseCases
import SourceIR.BorrowTailCallCases as BorrowTailCallCases
import SourceIR.BytesFusionCases as BytesFusionCases
import SourceIR.CachedTypeInfoCases as CachedTypeInfoCases
import SourceIR.CaseCases as CaseCases
import SourceIR.CharCaseCases as CharCaseCases
import SourceIR.ClosureAbiBranchCases as ClosureAbiBranchCases
import SourceIR.ClosureCaptureBoolCases as ClosureCaptureBoolCases
import SourceIR.ClosureCases as ClosureCases
import SourceIR.CombinatorCases as CombinatorCases
import SourceIR.CombinatorStdlibCases as CombinatorStdlibCases
import SourceIR.CompositionOpCases as CompositionOpCases
import SourceIR.ControlFlowCases as ControlFlowCases
import SourceIR.CovBytesFusionCases as CovBytesFusionCases
import SourceIR.CovCodegenBoundaryCases as CovCodegenBoundaryCases
import SourceIR.CovGenerateMlirCases as CovGenerateMlirCases
import SourceIR.CovInlineCases as CovInlineCases
import SourceIR.CovInlineSimplifyCases as CovInlineSimplifyCases
import SourceIR.CovLambdaBoundaryCases as CovLambdaBoundaryCases
import SourceIR.CovLambdaSetCases as CovLambdaSetCases
import SourceIR.CovMonoAccessorCases as CovMonoAccessorCases
import SourceIR.CovMonoRefineCases as CovMonoRefineCases
import SourceIR.CovMonoRound4Cases as CovMonoRound4Cases
import SourceIR.CovMonoSettleCases as CovMonoSettleCases
import SourceIR.CovMonoSolverCases as CovMonoSolverCases
import SourceIR.CovPatternCases as CovPatternCases
import SourceIR.CovPortCases as CovPortCases
import SourceIR.CovPostSolveKernelCases as CovPostSolveKernelCases
import SourceIR.CovPreMonoCases as CovPreMonoCases
import SourceIR.CovTailRecCases as CovTailRecCases
import SourceIR.DebugKernelCases as DebugKernelCases
import SourceIR.DecisionTreeAdvancedCases as DecisionTreeAdvancedCases
import SourceIR.DependencySCCCases as DependencySCCCases
import SourceIR.EdgeCaseCases as EdgeCaseCases
import SourceIR.EqualityPapCases as EqualityPapCases
import SourceIR.FloatMathCases as FloatMathCases
import SourceIR.FunctionAccumulatorCases as FunctionAccumulatorCases
import SourceIR.FunctionCases as FunctionCases
import SourceIR.GroupBLiteralCases as GroupBLiteralCases
import SourceIR.HigherOrderCases as HigherOrderCases
import SourceIR.IfLetSafepointCases as IfLetSafepointCases
import SourceIR.IfNodeTypeCases as IfNodeTypeCases
import SourceIR.ImportResolutionCases as ImportResolutionCases
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
import SourceIR.LetPolyNameCases as LetPolyNameCases
import SourceIR.LetRecCases as LetRecCases
import SourceIR.ListCases as ListCases
import SourceIR.LiteralCases as LiteralCases
import SourceIR.LocalMultiEnrichCases as LocalMultiEnrichCases
import SourceIR.LocalTailRecCases as LocalTailRecCases
import SourceIR.MaybeResultCases as MaybeResultCases
import SourceIR.MonoCompoundCases as MonoCompoundCases
import SourceIR.MultiDefCases as MultiDefCases
import SourceIR.MutualRecTailRecCases as MutualRecTailRecCases
import SourceIR.NumberCompoundFieldCases as NumberCompoundFieldCases
import SourceIR.OperatorCases as OperatorCases
import SourceIR.ParamArityCases as ParamArityCases
import SourceIR.PatternArgCases as PatternArgCases
import SourceIR.PatternComplexityFuzzCases as PatternComplexityFuzzCases
import SourceIR.PatternMatchingCases as PatternMatchingCases
import SourceIR.PhantomTypeVarCases as PhantomTypeVarCases
import SourceIR.PolyChainCases as PolyChainCases
import SourceIR.PolyEscapeCases as PolyEscapeCases
import SourceIR.PortEncodingCases as PortEncodingCases
import SourceIR.PostSolveDeterminismCases as PostSolveDeterminismCases
import SourceIR.PostSolveExprCases as PostSolveExprCases
import SourceIR.RecordCases as RecordCases
import SourceIR.RecursiveTreeTraversalCases as RecursiveTreeTraversalCases
import SourceIR.RecursiveTypeCases as RecursiveTypeCases
import SourceIR.RejectionControlCases as RejectionControlCases
import SourceIR.SpecializeAccessorCases as SpecializeAccessorCases
import SourceIR.SpecializeConstructorCases as SpecializeConstructorCases
import SourceIR.SpecializeCycleCases as SpecializeCycleCases
import SourceIR.SpecializeExprCases as SpecializeExprCases
import SourceIR.SpecializePolyLetCases as SpecializePolyLetCases
import SourceIR.SpecializePolyTopCases as SpecializePolyTopCases
import SourceIR.SpecializeRecordCtorCases as SpecializeRecordCtorCases
import SourceIR.SyntheticPlaceholderCases as SyntheticPlaceholderCases
import SourceIR.TailDefTypeCases as TailDefTypeCases
import SourceIR.TailLoopMutualRecCases as TailLoopMutualRecCases
import SourceIR.TailRecCaseCases as TailRecCaseCases
import SourceIR.TailRecLetRecClosureCases as TailRecLetRecClosureCases
import SourceIR.TupleCases as TupleCases
import SourceIR.TypeAliasCtorCases as TypeAliasCtorCases
import SourceIR.WideObjectCases as WideObjectCases
import Test exposing (Test)


{-| Builds one group of tests named `condStr`, holding the suite of each
included case module, with `expectFn` as the check those suites apply to their
programs.

`condStr` is also passed to each case module, whose own test or group name ends
with it, so it should say what `expectFn` checks.

-}
expectSuite : (Src.Module -> Expectation) -> String -> Test
expectSuite expectFn condStr =
    Test.describe condStr
        [ -- Fixed programs
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
        , PhantomTypeVarCases.expectSuite expectFn condStr
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
        , IfNodeTypeCases.expectSuite expectFn condStr
        , LocalTailRecCases.expectSuite expectFn condStr
        , TailRecCaseCases.expectSuite expectFn condStr
        , TailRecLetRecClosureCases.expectSuite expectFn condStr
        , TupleCases.expectSuite expectFn condStr
        , TypeAliasCtorCases.expectSuite expectFn condStr
        , KernelIntrinsicCases.expectSuite expectFn condStr
        , KernelPapAbiCases.expectSuite expectFn condStr
        , KernelOperatorCases.expectSuite expectFn condStr
        , KernelComparisonCases.expectSuite expectFn condStr
        , KernelContextCases.expectSuite expectFn condStr
        , KernelHigherOrderCases.expectSuite expectFn condStr
        , KernelCompositionCases.expectSuite expectFn condStr
        , KernelCtorArgCases.expectSuite expectFn condStr

        -- Coverage-loop programs
        , CovPostSolveKernelCases.expectSuite expectFn condStr
        , CovPreMonoCases.expectSuite expectFn condStr
        , CovMonoSolverCases.expectSuite expectFn condStr
        , CovMonoRound4Cases.expectSuite expectFn condStr
        , CovMonoRefineCases.expectSuite expectFn condStr
        , CovMonoAccessorCases.expectSuite expectFn condStr
        , CovMonoSettleCases.expectSuite expectFn condStr
        , CovPortCases.expectSuite expectFn condStr
        , CovLambdaBoundaryCases.expectSuite expectFn condStr
        , CovLambdaSetCases.expectSuite expectFn condStr
        , CovInlineCases.expectSuite expectFn condStr
        , CovBytesFusionCases.expectSuite expectFn condStr
        , CovInlineSimplifyCases.expectSuite expectFn condStr
        , CovGenerateMlirCases.expectSuite expectFn condStr
        , CovCodegenBoundaryCases.expectSuite expectFn condStr
        , CovTailRecCases.expectSuite expectFn condStr
        , CovPatternCases.expectSuite expectFn condStr
        , WideObjectCases.expectSuite expectFn condStr
        , RejectionControlCases.expectSuite expectFn condStr

        -- Programs moved from unit tests whose checks now run over this
        -- catalogue
        , AccessorPlaceholderCases.expectSuite expectFn condStr
        , BorrowTailCallCases.expectSuite expectFn condStr
        , CachedTypeInfoCases.expectSuite expectFn condStr
        , CharCaseCases.expectSuite expectFn condStr
        , DebugKernelCases.expectSuite expectFn condStr
        , DependencySCCCases.expectSuite expectFn condStr
        , FunctionAccumulatorCases.expectSuite expectFn condStr
        , GroupBLiteralCases.expectSuite expectFn condStr
        , ImportResolutionCases.expectSuite expectFn condStr
        , LetPolyNameCases.expectSuite expectFn condStr
        , LocalMultiEnrichCases.expectSuite expectFn condStr
        , NumberCompoundFieldCases.expectSuite expectFn condStr
        , PostSolveDeterminismCases.expectSuite expectFn condStr
        , SyntheticPlaceholderCases.expectSuite expectFn condStr
        , TailDefTypeCases.expectSuite expectFn condStr
        , TailLoopMutualRecCases.expectSuite expectFn condStr

        -- Fuzz tests (AccessorScopingCases builds fixed programs)
        , PatternComplexityFuzzCases.expectSuite expectFn condStr
        , AccessorScopingCases.expectSuite expectFn condStr
        , AccessorFuzzCases.expectSuite expectFn condStr
        ]
