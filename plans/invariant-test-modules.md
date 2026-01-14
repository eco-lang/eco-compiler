# Invariant Test Modules Plan

This plan describes the implementation of test logic modules for invariants defined in `design_docs/invariant-test-logic.md`.

## Implementation Status

### Completed (High Priority)
- [x] CANON_001: GlobalNames.elm + GlobalNamesTest.elm
- [x] CANON_002: IdAssignment.elm (already existed)
- [x] CANON_003: DuplicateDecls.elm + DuplicateDeclsTest.elm
- [x] TYPE_001/003: Covered by TypedErasedCheckingParity.elm (already existed)
- [x] TYPE_002: UnificationErrors.elm + UnificationErrorsTest.elm
- [x] TOPT_001: TypedOptTypes.elm + TypedOptTypesTest.elm
- [x] TOPT_002: DeciderExhaustive.elm + DeciderExhaustiveTest.elm
- [x] MONO_001: MonoTypeShape.elm + MonoTypeShapeTest.elm
- [x] MONO_004/005/010/011: MonoGraphIntegrity.elm + MonoGraphIntegrityTest.elm
- [x] Aggregator: InvariantTests.elm

### Completed (Medium Priority)
- [x] TYPE_004: OccursCheck.elm + OccursCheckTest.elm
- [x] TYPE_006: AnnotationEnforcement.elm + AnnotationEnforcementTest.elm
- [x] TOPT_003: AnnotationsPreserved.elm + AnnotationsPreservedTest.elm
- [x] TOPT_005: FunctionTypeEncode.elm + FunctionTypeEncodeTest.elm
- [x] MONO_002/008: MonoNumericResolution.elm + MonoNumericResolutionTest.elm
- [x] MONO_006/007/013/014: MonoLayoutIntegrity.elm + MonoLayoutIntegrityTest.elm
- [x] MONO_012: MonoFunctionArity.elm + MonoFunctionArityTest.elm

### Completed (Low Priority)
- [x] CANON_004: ImportResolution.elm + ImportResolutionTest.elm
- [x] CANON_005: DependencySCC.elm + DependencySCCTest.elm
- [x] CANON_006: CachedTypeInfo.elm + CachedTypeInfoTest.elm
- [x] TYPE_005: RankPolymorphism.elm + RankPolymorphismTest.elm
- [x] POST_001: GroupBTypes.elm + GroupBTypesTest.elm
- [x] POST_002: KernelTypes.elm + KernelTypesTest.elm
- [x] POST_003: NoSyntheticVars.elm + NoSyntheticVarsTest.elm
- [x] POST_004: Determinism.elm + DeterminismTest.elm
- [x] TOPT_004: Type preservation (covered by OptimizeEquivalent)
- [x] MONO_003: CEcoValueLayout.elm + CEcoValueLayoutTest.elm
- [x] MONO_009: DebugPolymorphism.elm + DebugPolymorphismTest.elm

### Remaining (Out of Scope)
- [ ] CGEN_001-014: MLIR codegen (requires MLIR parsing)
- [ ] HEAP_001-019: C++ runtime tests (out of scope for Elm)
- [ ] XPHASE_001-002: C++ cross-phase tests (out of scope for Elm)

## Overview

Create test logic modules for 73 invariants across 8 phases:
- Canonicalization (6 tests: CANON_001-006)
- Type checking (6 tests: TYPE_001-006)
- Post-solve (4 tests: POST_001-004)
- Typed optimization (5 tests: TOPT_001-005)
- Monomorphization (14 tests: MONO_001-014)
- MLIR codegen (14 tests: CGEN_001-014)
- Runtime heap (19 tests: HEAP_001-019)
- Cross-phase (2 tests: XPHASE_001-002)

## Directory Structure

```
compiler/tests/Compiler/
├── Canonicalize/
│   ├── IdAssignment.elm          (existing - covers CANON_002)
│   ├── GlobalNames.elm           (new - CANON_001)
│   ├── DuplicateDecls.elm        (new - CANON_003)
│   ├── ImportResolution.elm      (new - CANON_004)
│   ├── DependencySCC.elm         (new - CANON_005)
│   └── CachedTypeInfo.elm        (new - CANON_006)
├── Type/
│   ├── ConstraintCoverage.elm    (new - TYPE_001)
│   ├── UnificationErrors.elm     (new - TYPE_002)
│   ├── NodeTypesCoverage.elm     (new - TYPE_003)
│   ├── OccursCheck.elm           (new - TYPE_004)
│   ├── RankPolymorphism.elm      (new - TYPE_005)
│   └── AnnotationEnforcement.elm (new - TYPE_006)
├── Type/PostSolve/
│   ├── GroupBTypes.elm           (new - POST_001)
│   ├── KernelTypes.elm           (new - POST_002)
│   ├── NoSyntheticVars.elm       (new - POST_003)
│   └── Determinism.elm           (new - POST_004)
├── Optimize/
│   ├── TypedOptTypes.elm         (new - TOPT_001)
│   ├── DeciderExhaustive.elm     (new - TOPT_002)
│   ├── AnnotationsPreserved.elm  (new - TOPT_003)
│   ├── TypePreserving.elm        (new - TOPT_004)
│   └── FunctionTypeEncode.elm    (new - TOPT_005)
├── Generate/
│   ├── MonoTypeShape.elm         (new - MONO_001)
│   ├── NoCNumberAtCodegen.elm    (new - MONO_002)
│   ├── CEcoValueLayout.elm       (new - MONO_003)
│   ├── CallableMonoNodes.elm     (new - MONO_004)
│   ├── SpecRegistry.elm          (new - MONO_005)
│   ├── RecordTupleLayouts.elm    (new - MONO_006)
│   ├── RecordAccessLayout.elm    (new - MONO_007)
│   ├── NumericTypeFixed.elm      (new - MONO_008)
│   ├── DebugPolymorphic.elm      (new - MONO_009)
│   ├── MonoGraphComplete.elm     (new - MONO_010)
│   ├── MonoGraphClosed.elm       (new - MONO_011)
│   ├── FunctionArity.elm         (new - MONO_012)
│   ├── CtorLayouts.elm           (new - MONO_013)
│   └── CanonicalLayouts.elm      (new - MONO_014)
└── Generate/CodeGen/
    ├── BoxingPrimitives.elm      (new - CGEN_001)
    ├── PartialAppClosure.elm     (new - CGEN_002)
    ├── ClosureApplication.elm    (new - CGEN_003)
    ├── DestructPaths.elm         (new - CGEN_004)
    ├── EcoProject.elm            (new - CGEN_005)
    ├── LetBindings.elm           (new - CGEN_006)
    ├── ArgBoxing.elm             (new - CGEN_007)
    ├── OperandTypes.elm          (new - CGEN_008)
    ├── BoolConstants.elm         (new - CGEN_009)
    ├── EcoCaseResults.elm        (new - CGEN_010)
    ├── CallTargets.elm           (new - CGEN_011)
    ├── MonoTypeMlirMapping.elm   (new - CGEN_012)
    ├── CEcoValueLowering.elm     (new - CGEN_013)
    └── CtorLayoutsCodegen.elm    (new - CGEN_014)
```

**Note**: HEAP_* and XPHASE_* invariants are for the C++ runtime and require runtime-level testing, not Elm test modules. These will be tracked separately.

## Pattern for Each Test Logic Module

Each module follows this pattern:

```elm
module Compiler.<Phase>.<InvariantName> exposing (expectXxx)

{-| Test logic for invariant <ID>: <Name>
-}

import ...
import Expect

expectXxx : <InputType> -> Expect.Expectation
expectXxx input =
    -- Implementation that checks the invariant
    ...
```

## Implementation Steps

### Phase 1: Canonicalization Tests

#### 1.1 GlobalNames.elm (CANON_001)
- **Function**: `expectGlobalNamesQualified : Can.Module -> Expect.Expectation`
- **Logic**: Walk all expressions, for VarForeign/VarKernel/VarCtor/VarOperator/top-level Var, assert `home` is `IO.Canonical`; for VarLocal, assert no `home` field
- **Testing**: Property-based with generated modules

#### 1.2 IdAssignment.elm (CANON_002) - EXISTS
- Already implemented; verifies unique non-negative IDs

#### 1.3 DuplicateDecls.elm (CANON_003)
- **Function**: `expectDuplicateError : Src.Module -> CanError.Error -> Expect.Expectation`
- **Logic**: Run canonicalization on modules with intentional duplicates; verify specific error types
- **Testing**: Unit tests with crafted duplicate scenarios

#### 1.4 ImportResolution.elm (CANON_004)
- **Function**: `expectImportResolution : Src.Module -> Dict IO.Canonical Interface -> Expect.Expectation`
- **Logic**: Test valid imports resolve; missing modules yield ImportNotFound; missing symbols yield ImportExposingNotFound
- **Testing**: Unit tests with various interface configurations

#### 1.5 DependencySCC.elm (CANON_005)
- **Function**: `expectSCCCorrect : Src.Module -> Expect.Expectation`
- **Logic**: Build dependency graph, run SCC, verify grouping matches; test recursive/mutual-recursive detection
- **Testing**: Unit tests with recursive and non-recursive definitions

#### 1.6 CachedTypeInfo.elm (CANON_006)
- **Function**: `expectCachedTypesConsistent : Can.Module -> Expect.Expectation`
- **Logic**: For VarForeign/VarCtor/VarDebug/VarOperator/Binop and PCtor/PatternCtorArg, verify cached types match environment
- **Testing**: Property-based with varied modules

### Phase 2: Type Checking Tests

#### 2.1 ConstraintCoverage.elm (TYPE_001)
- **Function**: `expectConstraintsCoverAll : Can.Module -> Expect.Expectation`
- **Logic**: Mark reachable canonical nodes; after constraint generation, verify all marked nodes have constraints
- **Testing**: Property-based with complex modules

#### 2.2 UnificationErrors.elm (TYPE_002)
- **Function**: `expectUnificationErrorsReported : Src.Module -> Expect.Expectation`
- **Logic**: For modules with type conflicts, verify solver produces Type.Error and BadTypes
- **Testing**: Unit tests with known type errors

#### 2.3 NodeTypesCoverage.elm (TYPE_003)
- **Function**: `expectNodeTypesComplete : Can.Module -> NodeTypes -> Expect.Expectation`
- **Logic**: Verify all expression/pattern IDs >= 0 exist in NodeTypes; negative IDs absent
- **Testing**: Property-based after type checking

#### 2.4 OccursCheck.elm (TYPE_004)
- **Function**: `expectOccursCheckTriggered : Src.Module -> Expect.Expectation`
- **Logic**: For recursive type scenarios (a ~ List a), verify Occurs error; no infinite types in NodeTypes
- **Testing**: Unit tests with known infinite-type attempts

#### 2.5 RankPolymorphism.elm (TYPE_005)
- **Function**: `expectRankPolymorphismCorrect : Src.Module -> Expect.Expectation`
- **Logic**: Test nested lets for proper generalization; verify only correct-rank variables quantified
- **Testing**: Unit tests with classic ML rank examples

#### 2.6 AnnotationEnforcement.elm (TYPE_006)
- **Function**: `expectAnnotationsEnforced : Src.Module -> Expect.Expectation`
- **Logic**: For annotated expressions, verify matching succeeds; mismatches produce Type.Error
- **Testing**: Unit tests with matching and mismatched annotations

### Phase 3: Post-Solve Tests

#### 3.1 GroupBTypes.elm (POST_001)
- **Function**: `expectGroupBTypesStructural : NodeTypes -> NodeTypes -> Expect.Expectation`
- **Logic**: Compare pre/post PostSolve NodeTypes; Group B expressions (lists, tuples, records, lambdas) get concrete types
- **Testing**: Property-based comparing snapshots

#### 3.2 KernelTypes.elm (POST_002)
- **Function**: `expectKernelTypesInferred : Can.Module -> KernelTypeEnv -> Expect.Expectation`
- **Logic**: Verify kernel alias seeding and first-usage-wins scheme
- **Testing**: Unit tests with kernel definitions

#### 3.3 NoSyntheticVars.elm (POST_003)
- **Function**: `expectNoSyntheticVars : NodeTypes -> Expect.Expectation`
- **Logic**: Scan NodeTypes for non-kernel expressions; assert no unconstrained synthetic vars remain
- **Testing**: Property-based after PostSolve

#### 3.4 Determinism.elm (POST_004)
- **Function**: `expectDeterministic : Can.Module -> NodeTypes -> Expect.Expectation`
- **Logic**: Run PostSolve multiple times; assert results are identical
- **Testing**: Property-based with repeated execution

### Phase 4: Typed Optimization Tests

#### 4.1 TypedOptTypes.elm (TOPT_001)
- **Function**: `expectExprsHaveTypes : TOpt.Module -> Expect.Expectation`
- **Logic**: For each TOpt.Expr, assert last constructor arg is Can.Type; verify typeOf returns it
- **Testing**: Property-based with varied modules

#### 4.2 DeciderExhaustive.elm (TOPT_002)
- **Function**: `expectDeciderExhaustive : TOpt.Module -> Expect.Expectation`
- **Logic**: Compare source patterns to Decider trees; verify no nested patterns, trees are exhaustive
- **Testing**: Property-based with pattern-rich programs

#### 4.3 AnnotationsPreserved.elm (TOPT_003)
- **Function**: `expectAnnotationsPreserved : TOpt.LocalGraphData -> TypedCan.Module -> Expect.Expectation`
- **Logic**: Compare type schemes from type checking with LocalGraphData.Annotations
- **Testing**: Property-based with annotated programs

#### 4.4 TypePreserving.elm (TOPT_004)
- **Function**: `expectTypesPreserved : TypedCan.Expr -> TOpt.Expr -> Expect.Expectation`
- **Logic**: For optimized expressions, verify stored Can.Type matches expected from input
- **Testing**: Property-based comparing IR pairs

#### 4.5 FunctionTypeEncode.elm (TOPT_005)
- **Function**: `expectFunctionTypesEncoded : TOpt.Module -> Expect.Expectation`
- **Logic**: For function expressions, extract params and result; compute TLambda chain; assert matches attached type
- **Testing**: Property-based with varied arities

### Phase 5: Monomorphization Tests

#### 5.1-5.14 (MONO_001-014)
Each follows similar pattern for MonoGraph verification:
- MonoType shapes (MONO_001)
- No CNumber MVar at codegen (MONO_002)
- CEcoValue layout-neutrality (MONO_003)
- Callable MonoNodes (MONO_004)
- SpecializationRegistry completeness (MONO_005)
- RecordLayout/TupleLayout correctness (MONO_006)
- Record access/layout match (MONO_007)
- Numeric types fixed at calls (MONO_008)
- Debug calls polymorphic (MONO_009)
- MonoGraph type-complete (MONO_010)
- MonoGraph closed (MONO_011)
- Function arity match (MONO_012)
- CtorLayout consistency (MONO_013)
- Layout canonicalization (MONO_014)

### Phase 6: MLIR Codegen Tests

#### 6.1-6.14 (CGEN_001-014)
These require MLIR output inspection. Pattern:
- **Function**: `expectXxx : Mono.MonoGraph -> MlirOutput -> Expect.Expectation`
- Verify boxing primitives (CGEN_001)
- Partial application routing (CGEN_002)
- Closure application (CGEN_003)
- Destruct paths (CGEN_004)
- eco.project types (CGEN_005)
- Let binding preservation (CGEN_006)
- Argument boxing (CGEN_007)
- _operand_types accuracy (CGEN_008)
- Boolean constants (CGEN_009)
- eco.case result types (CGEN_010)
- eco.call targets exist (CGEN_011)
- monoTypeToMlir mapping (CGEN_012)
- CEcoValue lowering (CGEN_013)
- CtorLayouts in codegen (CGEN_014)

### Phase 7-8: Runtime and Cross-Phase (Out of Scope for Elm)

HEAP_001-019 and XPHASE_001-002 are C++ runtime tests, handled separately in `runtime/test/`.

## Prioritization

1. **High Priority** (fundamental invariants):
   - CANON_001-003 (basic canonicalization correctness)
   - TYPE_001-003 (constraint and type coverage)
   - TOPT_001-002 (typed optimization structure)
   - MONO_001, MONO_004, MONO_010-011 (MonoGraph integrity)

2. **Medium Priority** (correctness properties):
   - TYPE_004-006 (type system edge cases)
   - POST_001-004 (PostSolve correctness)
   - TOPT_003-005 (optimization preservation)
   - MONO_002-003, MONO_005-009 (specialization details)

3. **Lower Priority** (optimization and edge cases):
   - CANON_004-006 (import/SCC/caching)
   - MONO_012-014 (layout details)
   - CGEN_001-014 (MLIR verification - requires MLIR parsing)

## Testing Approach

- **Property-based testing**: For invariants checked over varied inputs (most cases)
- **Unit testing**: For error detection (CANON_003, TYPE_002, TYPE_004)
- **Snapshot testing**: For determinism (POST_004)
- **Differential testing**: For preservation (TOPT_004)

## Implementation Order

1. Create folder structure
2. Implement high-priority canonicalization tests (CANON_001-003)
3. Implement high-priority type checking tests (TYPE_001-003)
4. Implement typed optimization tests (TOPT_001-002)
5. Implement core monomorphization tests (MONO_001, MONO_004, MONO_010-011)
6. Implement remaining tests by priority
7. Create test suite aggregators (e.g., `CanonicalizeInvariantTest.elm`)

## Open Questions

1. **MLIR Parsing**: CGEN tests require parsing MLIR output. Need to decide:
   - Parse MLIR text to check attributes?
   - Use string matching for specific patterns?
   - Skip until MLIR tooling is available?

2. **Interface for NodeTypes/KernelTypeEnv**: Some tests need access to internal solver state. Verify these types are exposed appropriately.

3. **Test Case Reuse**: Should invariant tests reuse existing test case modules (AnnotatedTests, CaseTests, etc.) or have their own?
