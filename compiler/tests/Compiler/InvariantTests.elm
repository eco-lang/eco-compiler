module Compiler.InvariantTests exposing (suite)

{-| Aggregated test suite for all compiler invariants.

This module combines all invariant tests from different phases:

  - Canonicalization (CANON_001-006)
  - Type checking (TYPE_001-006)
  - Typed optimization (TOPT_001-005)
  - Monomorphization (MONO_001-015)
  - Post-solve (POST_001-004)

See design_docs/invariant-test-logic.md for the full list of invariants.

-}

import Compiler.Canonicalize.CachedTypeInfoTest as CachedTypeInfoTest
import Compiler.Canonicalize.DependencySCCTest as DependencySCCTest
import Compiler.Canonicalize.DuplicateDeclsTest as DuplicateDeclsTest
import Compiler.Canonicalize.GlobalNamesTest as GlobalNamesTest
import Compiler.Canonicalize.IdAssignmentTest as IdAssignmentTest
import Compiler.Canonicalize.ImportResolutionTest as ImportResolutionTest
import Compiler.Generate.CEcoValueLayoutTest as CEcoValueLayoutTest
import Compiler.Generate.DebugPolymorphismTest as DebugPolymorphismTest
import Compiler.Generate.MonoFunctionArityTest as MonoFunctionArityTest
import Compiler.Generate.MonoGraphIntegrityTest as MonoGraphIntegrityTest
import Compiler.Generate.MonoLayoutIntegrityTest as MonoLayoutIntegrityTest
import Compiler.Generate.MonoNumericResolutionTest as MonoNumericResolutionTest
import Compiler.Generate.MonoTypeShapeTest as MonoTypeShapeTest
import Compiler.Generate.MonomorphizeTest as MonomorphizeTest
import Compiler.Generate.TypedOptimizedMonomorphizeTest as TypedOptimizedMonomorphizeTest
import Compiler.BitwiseTests as BitwiseTests
import Compiler.ClosureTests as ClosureTests
import Compiler.ControlFlowTests as ControlFlowTests
import Compiler.FloatMathTests as FloatMathTests
import Compiler.PatternMatchingTests as PatternMatchingTests
import Compiler.SpecializeAccessorTests as SpecializeAccessorTests
import Compiler.SpecializeConstructorTests as SpecializeConstructorTests
import Compiler.SpecializeCycleTests as SpecializeCycleTests
import Compiler.SpecializeExprTests as SpecializeExprTests
import Compiler.Optimize.AnnotationsPreservedTest as AnnotationsPreservedTest
import Compiler.Optimize.DeciderExhaustiveTest as DeciderExhaustiveTest
import Compiler.Optimize.FunctionTypeEncodeTest as FunctionTypeEncodeTest
import Compiler.Optimize.OptimizeEquivalentTest as OptimizeEquivalentTest
import Compiler.Optimize.Typed.TailDefTypesTest as TailDefTypesTest
import Compiler.Optimize.TypedOptTypesTest as TypedOptTypesTest
import Compiler.Generate.Monomorphize.TailFuncSpecializationTest as TailFuncSpecializationTest
import Compiler.Type.AnnotationEnforcementTest as AnnotationEnforcementTest
import Compiler.Type.Constrain.TypedErasedCheckingParityTest as TypedErasedCheckingParityTest
import Compiler.Type.OccursCheckTest as OccursCheckTest
import Compiler.Type.PostSolve.DeterminismTest as DeterminismTest
import Compiler.Type.PostSolve.GroupBTypesTest as GroupBTypesTest
import Compiler.Type.PostSolve.KernelTypesTest as KernelTypesTest
import Compiler.Type.PostSolve.NoSyntheticVarsTest as NoSyntheticVarsTest
import Compiler.Type.RankPolymorphismTest as RankPolymorphismTest
import Compiler.Type.UnificationErrorsTest as UnificationErrorsTest
import Test exposing (Test)


suite : Test
suite =
    Test.describe "Compiler Invariants"
        [ canonicalizationInvariants
        , typeCheckingInvariants
        , postSolveInvariants
        , typedOptimizationInvariants
        , monomorphizationInvariants
        ]


canonicalizationInvariants : Test
canonicalizationInvariants =
    Test.describe "Canonicalization Invariants"
        [ GlobalNamesTest.suite -- CANON_001
        , IdAssignmentTest.suite -- CANON_002
        , DuplicateDeclsTest.suite -- CANON_003
        , ImportResolutionTest.suite -- CANON_004
        , DependencySCCTest.suite -- CANON_005
        , CachedTypeInfoTest.suite -- CANON_006
        ]


typeCheckingInvariants : Test
typeCheckingInvariants =
    Test.describe "Type Checking Invariants"
        [ TypedErasedCheckingParityTest.suite -- TYPE_001, TYPE_003
        , UnificationErrorsTest.suite -- TYPE_002
        , OccursCheckTest.suite -- TYPE_004
        , RankPolymorphismTest.suite -- TYPE_005
        , AnnotationEnforcementTest.suite -- TYPE_006
        ]


postSolveInvariants : Test
postSolveInvariants =
    Test.describe "Post-Solve Invariants"
        [ GroupBTypesTest.suite -- POST_001
        , KernelTypesTest.suite -- POST_002
        , NoSyntheticVarsTest.suite -- POST_003
        , DeterminismTest.suite -- POST_004
        ]


typedOptimizationInvariants : Test
typedOptimizationInvariants =
    Test.describe "Typed Optimization Invariants"
        [ TypedOptTypesTest.suite -- TOPT_001
        , DeciderExhaustiveTest.suite -- TOPT_002
        , AnnotationsPreservedTest.suite -- TOPT_003
        , OptimizeEquivalentTest.suite -- TOPT_004
        , FunctionTypeEncodeTest.suite -- TOPT_005
        , TailDefTypesTest.suite -- TOPT_TAILDEF_001: TailDef arg/return types match annotation
        ]


monomorphizationInvariants : Test
monomorphizationInvariants =
    Test.describe "Monomorphization Invariants"
        [ MonoTypeShapeTest.suite -- MONO_001
        , MonoNumericResolutionTest.suite -- MONO_002, MONO_008
        , CEcoValueLayoutTest.suite -- MONO_003
        , MonoGraphIntegrityTest.suite -- MONO_004, MONO_005, MONO_010, MONO_011
        , MonoLayoutIntegrityTest.suite -- MONO_006, MONO_007, MONO_013, MONO_014
        , DebugPolymorphismTest.suite -- MONO_009
        , MonoFunctionArityTest.suite -- MONO_012
        , MonomorphizeTest.suite -- General monomorphization tests
        , TypedOptimizedMonomorphizeTest.suite -- Integration tests

        -- Specialize.elm coverage tests
        , SpecializeCycleTests.suite -- Cycle detection and mutual recursion
        , SpecializeConstructorTests.suite -- Constructor specialization
        , SpecializeAccessorTests.suite -- MONO_015: Accessor extension variable unification
        , SpecializeExprTests.suite -- Expression branch coverage
        , TailFuncSpecializationTest.suite -- MONO_TAILFUNC_001: MonoTailFunc types match annotation

        -- MLIR and Monomorphize coverage tests
        , BitwiseTests.suite -- MLIR.Intrinsics.bitwiseIntrinsic
        , FloatMathTests.suite -- MLIR.Intrinsics.basicsIntrinsic float operations
        , PatternMatchingTests.suite -- MLIR.Patterns coverage
        , ClosureTests.suite -- Monomorphize.Closure coverage
        , ControlFlowTests.suite -- MLIR.Expr control flow coverage
        ]
