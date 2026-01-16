# Implementation Plan: Stubbed Test Logic

This plan describes the implementation of all stubbed test logic functions, with realistic feasibility assessments based on what's actually exposed from the compiler.

## Table of Contents

1. [Architecture Overview](#architecture-overview)
2. [Existing Resource Pool](#existing-resource-pool)
3. [Synthetic IR Generation Strategy](#synthetic-ir-generation-strategy)
4. [Feasibility Assessment](#feasibility-assessment)
5. [Implementation Details](#implementation-details)

---

## Architecture Overview

### Test Structure Pattern

The test infrastructure follows a composable pattern:

```
Test Case Modules (FunctionTests, CaseTests, etc.)
    └── expectSuite : (Src.Module -> Expectation) -> String -> Test
            │
            ▼
Test Logic Modules (MonoTypeShape, GlobalNames, etc.)
    └── expectXxx : Src.Module -> Expectation
            │
            ▼
Test Suite Modules (MonoTypeShapeTest, GlobalNamesTest, etc.)
    └── suite : Test  (wires expectSuite with expectXxx)
```

### Key Insight

Test logic functions receive `Src.Module` and must:
1. Run the pipeline to the relevant stage
2. Extract the IR/data to verify
3. Traverse and check invariants
4. Return `Expect.pass` or `Expect.fail`

Existing test cases provide comprehensive coverage via property-based fuzzing.

---

## Existing Resource Pool

### Reusable Pipeline Execution

**`Compiler.Generate.TypedOptimizedMonomorphize`** provides the complete pipeline:
- `expectMonomorphization` - Full pipeline with MonoGraph verification
- Internal helpers: `runWithIdsTypeCheck`, `runTypedOptimization`, `localGraphToGlobalGraph`, `buildGlobalTypeEnv`, `monomorphizeAny`

**Pattern to reuse:** Copy and adapt the pipeline stages to stop at intermediate points and return data for inspection.

### Reusable AST Traversal

**`Compiler.Canonicalize.IdAssignment`** provides:
- `collectExprIdsAsList` - Recursive expression traversal
- `collectPatternIdsAsList` - Recursive pattern traversal
- `collectModuleIdsAsList` - Module-level collection
- `findDuplicates` - Duplicate detection

**`Compiler.Canonicalize.GlobalNames`** provides:
- `collectExprIssues` - Expression issue collection with visitor pattern
- `collectPatternIssues` - Pattern issue collection
- `validateHome` - IO.Canonical validation
- `addIssueIf` - Conditional issue accumulation

**Pattern to reuse:** Adapt traversal patterns for new IR types (TOpt.Expr, MonoExpr, MonoType).

### Reusable Error Handling

**`Compiler.Canonicalize.DuplicateDecls`** provides:
- `expectSpecificError` - Generic predicate-based error testing
- `errorToString` - Error formatting

**`Compiler.Type.UnificationErrors`** provides:
- `canonicalizeModule` - Safe canonicalization with error handling
- `runTypeCheck` - Type checking with error collection
- `typeErrorToString` - Type error formatting

### Exposed Types (No Compiler Modification Needed)

From **`Compiler.AST.Monomorphized`**:
- `MonoType(..)` - All constructors exposed (MInt, MFloat, MVar, etc.)
- `Constraint(..)` - CEcoValue, CNumber exposed
- `MonoGraph(..)` - Graph structure exposed
- `MonoNode(..)` - All node variants exposed
- `MonoExpr(..)` - All expression variants exposed
- `RecordLayout`, `TupleLayout`, `CtorLayout`, `FieldInfo` - Layout types exposed
- `typeOf` - Type extraction utility
- `SpecializationRegistry`, `SpecId`, `SpecKey` - Registry types exposed

From **`Compiler.AST.TypedOptimized`**:
- `Expr(..)` - All expression variants exposed (each carries `Can.Type` as last arg)
- `Node(..)`, `Def(..)`, `Decider(..)`, `Choice(..)` - Core types exposed
- `LocalGraph(..)`, `LocalGraphData`, `GlobalGraph(..)` - Graph structures exposed
- `Annotations` - Type alias for annotation dict
- `typeOf` - Type extraction utility

From **`Compiler.Type.PostSolve`**:
- `postSolve` - The main function exposed
- `NodeTypes` - Type alias exposed

---

## Synthetic IR Generation Strategy

In addition to testing through the full pipeline from `Src.Module`, we can generate intermediate IR structures directly to probe specific compiler phases. This approach complements property-based source testing with more precise, edge-case-focused tests.

### Benefits of Synthetic IR Testing

1. **Precise control** - Construct exact IR structures to test specific invariants
2. **Edge case coverage** - Create malformed or boundary cases not easily expressed as source
3. **Phase isolation** - Test a phase in isolation without running earlier pipeline stages
4. **Faster execution** - Skip pipeline stages that aren't relevant to the invariant being tested
5. **Targeted regression tests** - When a bug is found, create minimal synthetic IR that reproduces it

### Phases That Benefit from Synthetic IR

| Phase Under Test | Input IR to Generate | Exposed Constructors |
|------------------|---------------------|----------------------|
| **Monomorphization** | `TOpt.LocalGraph`, `TOpt.GlobalGraph` | `Expr(..)`, `Def(..)`, `Node(..)`, `LocalGraph(..)`, `GlobalGraph(..)`, `Decider(..)`, `Choice(..)` |
| **Runtime Layout** | `Mono.MonoGraph` | `MonoType(..)`, `MonoNode(..)`, `MonoExpr(..)`, `RecordLayout`, `TupleLayout`, `CtorLayout` |

### TypedOptimized Builder Module (Proposed)

Create `compiler/tests/Compiler/AST/TypedOptimizedBuilder.elm` similar to `CanonicalBuilder.elm`:

```elm
module Compiler.AST.TypedOptimizedBuilder exposing
    ( -- Type construction
      intType, floatType, boolType, stringType, charType, unitType
    , funType, listType, tupleType, recordType
    , typeVar

    -- Expression construction (each returns typed Expr)
    , intLiteral, floatLiteral, boolLiteral, stringLiteral, charLiteral
    , varLocal, varGlobal, varKernel
    , call, tailCall
    , lambda, letDef, letDestruct
    , caseBranch, deciderChain, deciderFanout
    , record, recordAccess, recordUpdate
    , tuple, tupleIndex
    , ctor, ctorAccess

    -- Graph construction
    , localGraph, globalGraph
    , defineNode, tailFuncNode

    -- Annotation helpers
    , emptyAnnotations, withAnnotation
    )
```

### Example: Synthetic IR for Monomorphization Testing

```elm
-- Test MONO_001: MonoTypes fully elaborated
-- Create a TypedOptimized graph with a polymorphic function
-- Verify monomorphization resolves all type variables

syntheticPolymorphicIdentity : TOpt.LocalGraph
syntheticPolymorphicIdentity =
    let
        -- Type: a -> a
        typeVar_a = Can.TVar "a"
        identityType = funType typeVar_a typeVar_a

        -- Expression: \x -> x
        identityExpr =
            lambda
                [ ( "x", typeVar_a ) ]
                (varLocal "x" typeVar_a)
                identityType
    in
    localGraph
        [ defineNode "identity" identityExpr identityType ]
        (withAnnotation "identity" identityType emptyAnnotations)


-- Test MONO_008: Numeric type resolution
-- Create a graph with number-constrained type variable

syntheticNumericAdd : TOpt.LocalGraph
syntheticNumericAdd =
    let
        -- number -> number -> number
        numVar = Can.TVar "number"  -- with number constraint
        addType = funType numVar (funType numVar numVar)

        -- Usage at concrete Int type
        addInts =
            call
                (varKernel "Basics" "add" addType)
                [ intLiteral 1, intLiteral 2 ]
                intType
    in
    localGraph
        [ defineNode "result" addInts intType ]
        emptyAnnotations
```

### Combining Synthetic IR with Property-Based Testing

The synthetic IR approach should be used **in addition to**, not instead of, property-based source testing:

| Testing Approach | Purpose | Coverage |
|------------------|---------|----------|
| Property-based source tests | Verify invariants hold for arbitrary valid programs | Broad, explores many code paths |
| Synthetic IR tests | Target specific edge cases and boundary conditions | Deep, probes specific invariant aspects |
| Combined | Maximum confidence in invariant correctness | Both broad and deep |

### Integration Pattern

```elm
-- In test logic module:
expectMonoTypesFullyElaborated : Src.Module -> Expect.Expectation
expectMonoTypesFullyElaborated srcModule =
    -- Property-based: full pipeline test
    case runToMonoGraph srcModule of
        Err msg -> Expect.fail msg
        Ok monoGraph -> verifyFullElaboration monoGraph

-- In dedicated synthetic test module:
module Compiler.Generate.MonoTypeShapeSynthetic exposing (suite)

suite : Test
suite =
    describe "MONO_001 Synthetic IR Tests"
        [ test "polymorphic identity is monomorphized" <|
            \() ->
                syntheticPolymorphicIdentity
                    |> monomorphizeLocalGraph
                    |> Result.map verifyFullElaboration
                    |> expectOk

        , test "numeric constraint resolved to Int at Int usage" <|
            \() ->
                syntheticNumericAdd
                    |> monomorphizeLocalGraph
                    |> Result.map (verifyTypeAt "result" MInt)
                    |> expectOk
        ]
```

### Implementation Priority for Synthetic IR

1. **Phase 1**: Create `TypedOptimizedBuilder.elm` with basic constructors
2. **Phase 2**: Add synthetic tests for MONO_001, MONO_002, MONO_008 (type elaboration)
3. **Phase 3**: Add synthetic tests for MONO_004, MONO_005 (graph integrity)
4. **Phase 4**: Expand to layout invariants (MONO_006, MONO_007, MONO_013, MONO_014)

---

## Feasibility Assessment

### Fully Feasible (Have All Needed Access)

| ID | Function | Reason |
|----|----------|--------|
| MONO_001 | `expectMonoTypesFullyElaborated` | MonoType constructors exposed; can traverse MonoGraph |
| MONO_002 | `expectNoNumericPolymorphism` | MonoType.MVar and Constraint.CNumber exposed |
| MONO_004 | `expectCallableMonoNodes` | MonoNode constructors exposed |
| MONO_005 | `expectSpecRegistryComplete` | SpecializationRegistry exposed |
| MONO_006 | `expectRecordTupleLayoutsComplete` | RecordLayout, TupleLayout exposed |
| MONO_007 | `expectRecordAccessMatchesLayout` | MonoExpr and layouts exposed |
| MONO_008 | `expectNumericTypesResolved` | MonoType exposed; can check call sites |
| MONO_010 | `expectMonoGraphComplete` | MonoGraph structure exposed |
| MONO_011 | `expectMonoGraphClosed` | MonoGraph, SpecId exposed |
| MONO_012 | `expectFunctionArityMatches` | MonoType.MFunction and MonoNode exposed |
| MONO_013 | `expectCtorLayoutsConsistent` | CtorLayout exposed |
| MONO_014 | `expectLayoutsCanonical` | Layout types exposed |
| MONO_003 | `expectValidCEcoValueLayout` | Constraint.CEcoValue exposed |
| MONO_009 | `expectDebugPolymorphismResolved` | MonoExpr, Constraint exposed |
| TOPT_001 | `expectAllExprsHaveTypes` | TOpt.Expr carries type as last arg; typeOf exposed |
| TOPT_001 | `expectTypesWellFormed` | Can.Type structure traversable |
| TOPT_002 | `expectDeciderNoNestedPatterns` | Decider, Path exposed |
| TOPT_002 | `expectDeciderComplete` | Decider structure exposed |
| TOPT_003 | `expectAnnotationsPreserved` | LocalGraphData.annotations exposed |
| TOPT_005 | `expectFunctionTypesEncoded` | TOpt.Expr, Can.Type exposed |
| POST_003 | `expectNoSyntheticVars` | NodeTypes and Can.Type exposed |
| POST_004 | `expectDeterministicTypes` | Can run PostSolve multiple times |
| POST_001 | `expectGroupBTypesValid` | NodeTypes before/after accessible |
| POST_002 | `expectKernelTypesValid` | KernelTypeEnv returned from postSolve |

### Partially Feasible (Limited Testing Possible)

| ID | Function | Limitation | Approach |
|----|----------|------------|----------|
| CANON_004 | `expectImportsResolved` | Foreign.createInitialEnv internals not exposed | Test via error detection only |
| CANON_005 | `expectValidSCCs` | Graph.stronglyConnComp internals not exposed | Test via error detection (RecursiveDecl/RecursiveLet) |
| CANON_006 | `expectTypeInfoCached` | Cached fields on VarForeign etc. need interface lookup | Verify presence, not recomputation |
| TYPE_004 | `expectInfiniteTypeDetected` | Already covered by UnificationErrors | Delegate to existing |
| TYPE_004 | `expectNoInfiniteTypes` | Cycle detection in Can.Type | Implement type traversal |

### Not Feasible Without Compiler Modification

| ID | Function | Reason |
|----|----------|--------|
| TYPE_005 | `expectRankPolymorphismValid` | Solver rank pools not exposed; internal state |

---

## Implementation Details

### Helper Functions to Create

Create in existing modules rather than new helper modules (simpler):

#### In `TypedOptimizedMonomorphize.elm` (extend existing):

```elm
-- Run pipeline and return intermediate MonoGraph for inspection
runToMonoGraph : Src.Module -> Result String Mono.MonoGraph

-- Run pipeline and return TypedOptimized LocalGraph
runToTypedOptimized : Src.Module -> Result String TOpt.LocalGraph

-- Run pipeline and return PostSolve results
runToPostSolve : Src.Module -> Result String { nodeTypes : NodeTypes, kernelEnv : KernelTypeEnv, canonical : Can.Module }
```

### Phase 1: Monomorphization Tests (13 functions)

#### MONO_001: `expectMonoTypesFullyElaborated`

```elm
expectMonoTypesFullyElaborated : Src.Module -> Expect.Expectation
expectMonoTypesFullyElaborated srcModule =
    case runToMonoGraph srcModule of
        Err msg -> Expect.fail msg
        Ok monoGraph ->
            let issues = collectMonoTypeIssues monoGraph
            in if List.isEmpty issues then Expect.pass
               else Expect.fail (String.join "\n" issues)

collectMonoTypeIssues : Mono.MonoGraph -> List String
collectMonoTypeIssues (Mono.MonoGraph data) =
    -- Traverse all MonoTypes in nodes
    -- For each MonoType:
    --   - If MVar with CNumber -> issue (should be resolved)
    --   - MInt, MFloat, MBool, etc. -> ok
    --   - MVar with CEcoValue -> ok (allowed at codegen)
```

#### MONO_002: `expectNoNumericPolymorphism`

```elm
expectNoNumericPolymorphism : Src.Module -> Expect.Expectation
expectNoNumericPolymorphism srcModule =
    case runToMonoGraph srcModule of
        Err msg -> Expect.fail msg
        Ok monoGraph ->
            let cNumberVars = findCNumberVars monoGraph
            in if List.isEmpty cNumberVars then Expect.pass
               else Expect.fail ("CNumber MVars found: " ++ ...)

findCNumberVars : Mono.MonoGraph -> List String
findCNumberVars graph =
    -- Traverse all MonoTypes
    -- Collect any MVar _ CNumber occurrences
```

#### MONO_004: `expectCallableMonoNodes`

```elm
expectCallableMonoNodes : Src.Module -> Expect.Expectation
expectCallableMonoNodes srcModule =
    case runToMonoGraph srcModule of
        Err msg -> Expect.fail msg
        Ok (Mono.MonoGraph data) ->
            let issues = checkCallableNodes data.nodes
            in ...

checkCallableNodes : Dict SpecId MonoNode -> List String
checkCallableNodes nodes =
    -- For each node with function MonoType:
    --   Verify it's MonoTailFunc or MonoDefine with MonoClosure
```

#### MONO_005: `expectSpecRegistryComplete`

```elm
expectSpecRegistryComplete : Src.Module -> Expect.Expectation
expectSpecRegistryComplete srcModule =
    case runToMonoGraph srcModule of
        Err msg -> Expect.fail msg
        Ok (Mono.MonoGraph data) ->
            -- For each SpecId in registry: verify node exists
            -- For each SpecId reference: verify in registry
            -- Find orphan entries
```

#### MONO_006, MONO_007, MONO_013, MONO_014: Layout Tests

```elm
-- All follow same pattern:
-- 1. Run to MonoGraph
-- 2. Extract relevant layout info
-- 3. Verify consistency with MonoType structure
-- 4. Verify no mismatches between usage and definition
```

#### MONO_008: `expectNumericTypesResolved`

```elm
expectNumericTypesResolved : Src.Module -> Expect.Expectation
expectNumericTypesResolved srcModule =
    case runToMonoGraph srcModule of
        Err msg -> Expect.fail msg
        Ok monoGraph ->
            -- Find all call sites (MonoCall expressions)
            -- For each: verify numeric args are MInt or MFloat
```

#### MONO_010, MONO_011: Graph Completeness and Closure

```elm
expectMonoGraphComplete : Src.Module -> Expect.Expectation
-- Verify all referenced MonoTypes defined
-- Verify ctorLayouts complete

expectMonoGraphClosed : Src.Module -> Expect.Expectation
-- Verify all MonoVarLocal in scope
-- Verify all MonoVarGlobal and SpecId references exist
```

#### MONO_012: `expectFunctionArityMatches`

```elm
expectFunctionArityMatches : Src.Module -> Expect.Expectation
expectFunctionArityMatches srcModule =
    case runToMonoGraph srcModule of
        Err msg -> Expect.fail msg
        Ok monoGraph ->
            -- For each function node: compare type arity with param count
            -- For each call: verify arg count matches
```

#### MONO_003, MONO_009: CEcoValue Tests

```elm
expectValidCEcoValueLayout : Src.Module -> Expect.Expectation
-- Verify CEcoValue vars only in non-layout positions

expectDebugPolymorphismResolved : Src.Module -> Expect.Expectation
-- Find Debug.* calls, verify type args are MVar with CEcoValue
```

### Phase 2: Typed Optimization Tests (6 functions)

#### TOPT_001: `expectAllExprsHaveTypes`, `expectTypesWellFormed`

```elm
expectAllExprsHaveTypes : Src.Module -> Expect.Expectation
expectAllExprsHaveTypes srcModule =
    case runToTypedOptimized srcModule of
        Err msg -> Expect.fail msg
        Ok localGraph ->
            -- Traverse all TOpt.Expr in graph
            -- For each: extract type via TOpt.typeOf
            -- Verify non-null/placeholder

expectTypesWellFormed : Src.Module -> Expect.Expectation
-- Same traversal, but check Can.Type structure
-- No dangling vars, valid type constructors, correct arities
```

#### TOPT_002: `expectDeciderNoNestedPatterns`, `expectDeciderComplete`

```elm
expectDeciderNoNestedPatterns : Src.Module -> Expect.Expectation
expectDeciderNoNestedPatterns srcModule =
    case runToTypedOptimized srcModule of
        Err msg -> Expect.fail msg
        Ok localGraph ->
            -- Find all Case expressions with Decider
            -- Walk Decider structure, check all Paths
            -- No nested pattern constructors in paths

expectDeciderComplete : Src.Module -> Expect.Expectation
-- Similar, but verify exhaustiveness via Decider structure
```

#### TOPT_003: `expectAnnotationsPreserved`

```elm
expectAnnotationsPreserved : Src.Module -> Expect.Expectation
expectAnnotationsPreserved srcModule =
    case runToTypedOptimized srcModule of
        Err msg -> Expect.fail msg
        Ok (TOpt.LocalGraph graphData) ->
            -- Get graphData.annotations
            -- Compare with type checking annotations (from earlier stage)
            -- Verify all top-level names present with same schemes
```

**Note:** Need to capture annotations from type checking stage. Modify pipeline helper to return both.

#### TOPT_005: `expectFunctionTypesEncoded`

```elm
expectFunctionTypesEncoded : Src.Module -> Expect.Expectation
expectFunctionTypesEncoded srcModule =
    case runToTypedOptimized srcModule of
        Err msg -> Expect.fail msg
        Ok localGraph ->
            -- Find function expressions (Lambda nodes)
            -- Extract params and result type
            -- Compute expected TLambda chain
            -- Compare with attached type
```

### Phase 3: Post-Solve Tests (4 functions)

#### POST_001: `expectGroupBTypesValid`

```elm
expectGroupBTypesValid : Src.Module -> Expect.Expectation
expectGroupBTypesValid srcModule =
    -- 1. Run to type checking, get pre-PostSolve nodeTypes
    -- 2. Run PostSolve
    -- 3. For Group B expressions (lists, tuples, records, lambdas):
    --    a. Verify type changed from synthetic var to concrete
    --    b. Verify structural reconstruction matches
```

**Note:** Need pipeline helper that returns nodeTypes before and after PostSolve.

#### POST_002: `expectKernelTypesValid`

```elm
expectKernelTypesValid : Src.Module -> Expect.Expectation
expectKernelTypesValid srcModule =
    case runToPostSolve srcModule of
        Err msg -> Expect.fail msg
        Ok result ->
            -- result.kernelEnv contains kernel types
            -- Find VarKernel usages in canonical module
            -- Verify kernelEnv has entries for all used kernels
```

#### POST_003: `expectNoSyntheticVars`

```elm
expectNoSyntheticVars : Src.Module -> Expect.Expectation
expectNoSyntheticVars srcModule =
    case runToPostSolve srcModule of
        Err msg -> Expect.fail msg
        Ok result ->
            -- Traverse all types in result.nodeTypes
            -- Check for synthetic vars (implementation-specific check)
            -- Kernel expressions may have synthetic vars (allowed)
```

**Challenge:** Need to identify "synthetic" vars. May need heuristic (e.g., negative IDs or naming convention).

#### POST_004: `expectDeterministicTypes`

```elm
expectDeterministicTypes : Src.Module -> Expect.Expectation
expectDeterministicTypes srcModule =
    case ( runToPostSolve srcModule, runToPostSolve srcModule, runToPostSolve srcModule ) of
        ( Ok r1, Ok r2, Ok r3 ) ->
            if nodeTypesEqual r1.nodeTypes r2.nodeTypes && nodeTypesEqual r2.nodeTypes r3.nodeTypes
            then Expect.pass
            else Expect.fail "PostSolve produced different results"
        _ -> Expect.fail "Pipeline failed"
```

### Phase 4: Type Checking Tests (3 functions)

#### TYPE_004: `expectInfiniteTypeDetected`

```elm
expectInfiniteTypeDetected : Src.Module -> Expect.Expectation
expectInfiniteTypeDetected srcModule =
    -- Delegate to existing UnificationErrors.expectInfiniteTypeError
    UnificationErrors.expectInfiniteTypeError srcModule
```

#### TYPE_004: `expectNoInfiniteTypes`

```elm
expectNoInfiniteTypes : Src.Module -> Expect.Expectation
expectNoInfiniteTypes srcModule =
    case runToPostSolve srcModule of
        Err msg -> Expect.fail msg
        Ok result ->
            -- Traverse all types in nodeTypes
            -- Check for cycles using visited set
            let cycles = findTypeCycles result.nodeTypes
            in if List.isEmpty cycles then Expect.pass
               else Expect.fail ("Cyclic types found: " ++ ...)
```

#### TYPE_005: `expectRankPolymorphismValid`

```elm
expectRankPolymorphismValid : Src.Module -> Expect.Expectation
expectRankPolymorphismValid srcModule =
    -- NOT FEASIBLE: Solver rank pools not exposed
    -- Alternative: Test observable behavior only
    -- If module compiles successfully and types match expected, pass
    TOMono.expectMonomorphization srcModule
```

**Note:** Keep as delegation since true rank inspection not possible.

### Phase 5: Canonicalization Tests (3 functions)

#### CANON_004: `expectImportsResolved`

```elm
expectImportsResolved : Src.Module -> Expect.Expectation
expectImportsResolved srcModule =
    -- Test via error detection only
    -- If canonicalization succeeds: imports resolved
    -- If fails with ImportNotFound/ImportExposingNotFound: capture specific error
    case canonicalizeModule srcModule of
        Ok _ -> Expect.pass
        Err msg -> Expect.fail msg
```

**Limited:** Can't test "Ambiguous*" errors or partial success scenarios without crafting specific test cases.

#### CANON_005: `expectValidSCCs`

```elm
expectValidSCCs : Src.Module -> Expect.Expectation
expectValidSCCs srcModule =
    -- Test via error detection
    -- RecursiveDecl/RecursiveLet errors indicate SCC issues
    -- Successful canonicalization implies correct SCC handling
    case canonicalizeModule srcModule of
        Ok _ -> Expect.pass
        Err msg -> Expect.fail msg
```

**Note:** True SCC verification would require reimplementing Graph.stronglyConnComp or accessing internals.

#### CANON_006: `expectTypeInfoCached`

```elm
expectTypeInfoCached : Src.Module -> Expect.Expectation
expectTypeInfoCached srcModule =
    case canonicalizeModule srcModule of
        Err msg -> Expect.fail msg
        Ok canModule ->
            -- Traverse canonical module
            -- For VarForeign, VarCtor, etc.: check cached type field exists
            -- Cannot recompute from interface without access to lookup logic
            let missing = findMissingCachedTypes canModule
            in if List.isEmpty missing then Expect.pass
               else Expect.fail ("Missing cached types: " ++ ...)
```

---

## Implementation Priority Order

### Phase 1: Infrastructure + High-Value Tests
1. Extend `TypedOptimizedMonomorphize.elm` with `runToMonoGraph`, `runToTypedOptimized`, `runToPostSolve`
2. Create `TypedOptimizedBuilder.elm` for synthetic IR construction
3. Implement MONO_001 `expectMonoTypesFullyElaborated` (pipeline-based)
4. Implement MONO_002 `expectNoNumericPolymorphism` (pipeline-based)
5. Implement MONO_004 `expectCallableMonoNodes` (pipeline-based)

### Phase 2: More Monomorphization Tests + Synthetic IR
6. Implement MONO_005 `expectSpecRegistryComplete`
7. Implement MONO_010 `expectMonoGraphComplete`
8. Implement MONO_011 `expectMonoGraphClosed`
9. Implement MONO_012 `expectFunctionArityMatches`
10. Add synthetic IR tests for MONO_001, MONO_002, MONO_008 (type elaboration edge cases)

### Phase 3: Typed Optimization Tests
11. Implement TOPT_001 `expectAllExprsHaveTypes` and `expectTypesWellFormed`
12. Implement TOPT_002 `expectDeciderNoNestedPatterns` and `expectDeciderComplete`
13. Implement TOPT_003 `expectAnnotationsPreserved`
14. Implement TOPT_005 `expectFunctionTypesEncoded`

### Phase 4: Post-Solve and Remaining Tests
15. Implement POST_003 `expectNoSyntheticVars`
16. Implement POST_004 `expectDeterministicTypes`
17. Implement POST_001 `expectGroupBTypesValid`
18. Implement POST_002 `expectKernelTypesValid`
19. Implement TYPE_004 `expectNoInfiniteTypes`

### Phase 5: Layout and Final Tests
20. Implement MONO_006, 007, 013, 014 (layout tests)
21. Implement MONO_003, 009 (CEcoValue tests)
22. Implement MONO_008 `expectNumericTypesResolved`
23. Add synthetic IR tests for layout invariants (MONO_006, MONO_007, MONO_013, MONO_014)

### Deferred/Limited Implementation
- CANON_004 `expectImportsResolved` - Error detection only
- CANON_005 `expectValidSCCs` - Error detection only
- CANON_006 `expectTypeInfoCached` - Presence check only
- TYPE_004 `expectInfiniteTypeDetected` - Delegate to existing
- TYPE_005 `expectRankPolymorphismValid` - Keep as delegation (infeasible)

---

## Summary

### Feasibility by Category

| Category | Fully Implementable | Limited | Not Feasible |
|----------|---------------------|---------|--------------|
| Canonicalization (3) | 0 | 3 | 0 |
| Type Checking (3) | 1 | 1 | 1 |
| Post-Solve (4) | 4 | 0 | 0 |
| Typed Optimization (6) | 6 | 0 | 0 |
| Monomorphization (13) | 13 | 0 | 0 |
| **Total (29)** | **24** | **4** | **1** |

**24 of 29 stubbed functions can be fully implemented without compiler modification.**

### Testing Strategy Overview

| Strategy | Purpose | Applies To |
|----------|---------|------------|
| **Pipeline-based tests** | Property-based testing from source through relevant compiler stage | All 24 implementable functions |
| **Synthetic IR tests** | Targeted edge cases using directly-constructed IR | MONO_001-014 (monomorphization) |
| **Error detection tests** | Verify invariants via error presence/absence | CANON_004-006 (limited) |
| **Delegation** | Reuse existing test logic | TYPE_004 (infinite types), TYPE_005 (rank polymorphism) |

### Key Deliverables

1. **Pipeline helpers** in `TypedOptimizedMonomorphize.elm`:
   - `runToMonoGraph : Src.Module -> Result String Mono.MonoGraph`
   - `runToTypedOptimized : Src.Module -> Result String TOpt.LocalGraph`
   - `runToPostSolve : Src.Module -> Result String { nodeTypes, kernelEnv, canonical }`

2. **TypedOptimizedBuilder.elm** (new module):
   - Type construction helpers (intType, funType, listType, etc.)
   - Expression construction helpers (intLiteral, varLocal, call, lambda, etc.)
   - Graph construction helpers (localGraph, defineNode, etc.)

3. **28 implemented test logic functions** across 20 modules (24 full + 4 limited)

4. **Synthetic IR test suites** for monomorphization invariants (complementary coverage)
