# Implementation Plan: New Invariants for GlobalOpt and Monomorphization

## Executive Summary

This plan adds invariants to guarantee correct GlobalOpt output for MLIR codegen, focusing on CallInfo validation and cross-phase consistency. All invariant checks are implemented as test logic only, not in compiler code.

---

## Part 1: Updates to `design_docs/invariants.csv`

### 1.1 Add Missing MONO_016 (already documented in test logic)

```csv
MONO_016;Monomorphization;Closures;tested;For wrapper closures that call functions returning functions each MonoCall passes only the number of arguments accepted by the callee type at that level. Nested calls respect curried structure: call(f [a]) returns MFunction [B C] D then call(result [b c]) returns D.;TestLogic.Monomorphize.WrapperCurriedCalls (checkWrapperCallArities)
```

### 1.2 New CallInfo Invariants (GOPT_010-015)

```csv
GOPT_010;GlobalOptimization;CallInfo;tested;After annotateCallStaging no MonoCall in the MonoGraph contains defaultCallInfo (initialRemaining=0 stageArities=[]). Every call site has computed CallInfo.;TestLogic.GlobalOpt.CallInfoComplete (checkNoDefaultCallInfo)

GOPT_011;GlobalOptimization;CallInfo;tested;For every MonoCall with StageCurried callModel stageArities is non-empty and all elements are positive integers.;TestLogic.GlobalOpt.CallInfoComplete (checkStageAritiesNonEmpty)

GOPT_012;GlobalOptimization;CallInfo;tested;For every MonoCall with StageCurried callModel sum(stageArities) equals the flattened arity of the callee's function type.;TestLogic.GlobalOpt.CallInfoComplete (checkStageAritiesSumMatchesArity)

GOPT_013;GlobalOptimization;CallInfo;tested;For every MonoCall where argCount < sum(stageArities) initialRemaining equals sum(remainingStageArities). This represents the remaining_arity for PAP creation.;TestLogic.GlobalOpt.CallInfoComplete (checkInitialRemainingConsistency)

GOPT_014;GlobalOptimization;CallInfo;tested;For partial application calls remainingStageArities contains the arities of stages not yet satisfied by provided arguments.;TestLogic.GlobalOpt.CallInfoComplete (checkRemainingStageArities)

GOPT_015;GlobalOptimization;CallInfo;tested;isSingleStageSaturated is true iff argCount >= stageArities[0] and the first stage is fully satisfied in one call.;TestLogic.GlobalOpt.CallInfoComplete (checkSingleStageSaturated)
```

### 1.3 Cross-Phase Invariants (XPHASE_010-011)

```csv
XPHASE_010;CrossPhase;CallInfo;structural;CallInfo values flow unchanged from GlobalOpt output to MLIR generation input. MLIR codegen only reads CallInfo (pattern matches on MonoCall) and never creates MonoCall or uses defaultCallInfo. Verified by code inspection.;Compiler.Generate.MLIR.Expr (no MonoCall construction)

XPHASE_011;CrossPhase;Types;tested;MonoTypes in the graph are identical before and after GlobalOpt except for MFunction canonicalization per GOPT_001. No other type mutations occur.;TestLogic.CrossPhase.TypeConsistency (checkTypePreservation)
```

### 1.4 Lambda ID Uniqueness (MONO_019)

```csv
MONO_019;Monomorphization;Closures;tested;Within a single MonoGraph all lambdaId values across all MonoClosure and MonoTailFunc nodes are unique. No two closures share the same lambdaId.;TestLogic.Monomorphize.LambdaIdUniqueness (checkLambdaIdUniqueness)
```

---

## Part 2: Updates to `design_docs/invariant-test-logic.md`

### 2.1 Add New Section: Global Optimization Phase (GOPT_*)

Insert between the Monomorphization section (ending at line ~663) and the MLIR Codegen section:

```markdown
---

## Global Optimization Phase (GOPT_*)

--
name: Closure params match stage arity
phase: global optimization
invariants: GOPT_001
ir: MonoClosure after GlobalOpt
logic: For every MonoClosure with MFunction type after GlobalOpt:
  * Compute stageParamTypes = first param list in MFunction type
  * Assert length(closureInfo.params) == length(stageParamTypes)
  * This is established by canonicalizeClosureStaging
inputs: Monomorphized graphs processed through GlobalOpt
oracle: All closures have param counts matching their stage arity.
tests: compiler/tests/TestLogic/Generate/MonoFunctionArityTest.elm
--
--
name: Returned closure param counts tracked
phase: global optimization
invariants: GOPT_002
ir: MonoGraph.returnedClosureParamCounts
logic: For every function that returns a closure:
  * The returnedClosureParamCounts map entry equals the first-stage parameter count
  * Computed by computeReturnedClosureParamCount after ABI normalization
inputs: GlobalOpt output graphs
oracle: Map is complete for all closure-returning functions.
--
--
name: Case/if branches have compatible staging
phase: global optimization
invariants: GOPT_003
ir: MonoCase, MonoIf after normalizeCaseIfAbi
logic: For every MonoCase and MonoIf returning function types:
  * All branch result types have identical staging signatures
  * Non-conforming branches are wrapped via buildAbiWrapperGO
inputs: GlobalOpt output with function-returning cases
oracle: All branches unify to a common staging; no ABI mismatches.
tests: compiler/tests/TestLogic/Monomorphize/MonoCaseBranchResultTypeTest.elm
--
--
name: No defaultCallInfo after GlobalOpt
phase: global optimization
invariants: GOPT_010
ir: MonoCall expressions
logic: Walk all MonoCall expressions in the graph:
  * Assert callInfo.stageArities /= []
  * Assert callInfo does not equal defaultCallInfo
  * defaultCallInfo has initialRemaining=0 and stageArities=[]
inputs: GlobalOpt output graphs
oracle: Every MonoCall has computed CallInfo; no placeholders remain.
tests: compiler/tests/TestLogic/GlobalOpt/CallInfoCompleteTest.elm
--
--
name: stageArities non-empty for StageCurried
phase: global optimization
invariants: GOPT_011
ir: CallInfo in MonoCall
logic: For every MonoCall with callModel == StageCurried:
  * Assert List.length stageArities > 0
  * Assert all elements in stageArities > 0
inputs: GlobalOpt output graphs
oracle: StageCurried calls always have valid stage arities.
tests: compiler/tests/TestLogic/GlobalOpt/CallInfoCompleteTest.elm
--
--
name: stageArities sum equals flattened arity
phase: global optimization
invariants: GOPT_012
ir: CallInfo in MonoCall
logic: For every MonoCall with StageCurried callModel:
  * Compute sum = List.sum callInfo.stageArities
  * Compute flattenedArity = count all params in flattened MFunction type
  * Assert sum == flattenedArity
inputs: GlobalOpt output graphs with various function arities
oracle: Stage groupings cover exactly all function parameters.
tests: compiler/tests/TestLogic/GlobalOpt/CallInfoCompleteTest.elm
--
--
name: initialRemaining consistency
phase: global optimization
invariants: GOPT_013
ir: CallInfo in MonoCall for partial applications
logic: For every MonoCall where argCount < sum(stageArities):
  * This is a partial application
  * Assert callInfo.initialRemaining == List.sum callInfo.remainingStageArities
  * initialRemaining represents the remaining_arity for PAP creation
inputs: GlobalOpt graphs with partial applications
oracle: initialRemaining correctly reflects unsatisfied stages.
tests: compiler/tests/TestLogic/GlobalOpt/CallInfoCompleteTest.elm
--
--
name: remainingStageArities consistency
phase: global optimization
invariants: GOPT_014
ir: CallInfo in MonoCall
logic: For partial application calls:
  * Compute consumedArgs = argCount
  * Walk stageArities consuming args until exhausted
  * remainingStageArities should contain the unconsumed stage arities
  * Example: stageArities=[2,3], argCount=2 -> remainingStageArities=[3]
inputs: GlobalOpt graphs with varied partial applications
oracle: remainingStageArities correctly represents unsatisfied stages.
tests: compiler/tests/TestLogic/GlobalOpt/CallInfoCompleteTest.elm
--
--
name: isSingleStageSaturated correctness
phase: global optimization
invariants: GOPT_015
ir: CallInfo in MonoCall
logic: Assert callInfo.isSingleStageSaturated is true iff:
  * argCount >= stageArities[0]
  * The first stage is fully satisfied by the call
inputs: GlobalOpt graphs with various call patterns
oracle: Flag correctly identifies single-stage saturation.
tests: compiler/tests/TestLogic/GlobalOpt/CallInfoCompleteTest.elm
--
```

### 2.2 Add Cross-Phase Invariants Section

After GOPT section:

```markdown
---

## Cross-Phase Invariants (XPHASE_*)

--
name: CallInfo flows unchanged to MLIR
phase: cross-phase
invariants: XPHASE_010
ir: MonoGraph from GlobalOpt to MLIR codegen
logic: Structural verification by code inspection:
  * MLIR codegen (Compiler.Generate.MLIR.Expr) only pattern-matches on MonoCall
  * It never constructs MonoCall expressions
  * It never uses defaultCallInfo
  * Therefore CallInfo values from GlobalOpt pass through unchanged
inputs: Code review
oracle: No MonoCall construction or defaultCallInfo usage in MLIR codegen.
verification: structural (code inspection)
--
--
name: Types preserved except canonicalization
phase: cross-phase
invariants: XPHASE_011
ir: MonoTypes before/after GlobalOpt
logic: Compare MonoTypes before and after GlobalOpt:
  * MFunction types may be canonicalized (nested -> flat per GOPT_001)
  * No other type changes allowed
  * No type information lost
inputs: Monomorphized graphs before/after GlobalOpt
oracle: Type mutations are limited to documented canonicalization.
tests: compiler/tests/TestLogic/CrossPhase/TypeConsistencyTest.elm
--
```

### 2.3 Add MONO_019 to Monomorphization Section

```markdown
--
name: Lambda IDs are unique within graph
phase: monomorphization
invariants: MONO_019
ir: MonoGraph (all MonoClosure and MonoTailFunc nodes)
logic: Collect all lambdaId values from:
  * closureInfo.lambdaId in MonoClosure expressions
  * Any lambdaId in MonoTailFunc nodes
Assert the collected set has no duplicates.
inputs: Monomorphized graphs with many closures
oracle: Every closure/function has a unique lambdaId.
tests: compiler/tests/TestLogic/Monomorphize/LambdaIdUniquenessTest.elm
--
```

---

## Part 3: New Test Files to Create

### 3.1 `compiler/tests/TestLogic/GlobalOpt/CallInfoComplete.elm`

**Purpose**: Implement test logic for GOPT_010 through GOPT_015

**Functions to implement**:
- `expectCallInfoComplete : Src.Module -> Expectation` - Main entry point
- `checkNoDefaultCallInfo : Mono.MonoGraph -> List Violation` - GOPT_010
- `checkStageAritiesNonEmpty : Mono.MonoGraph -> List Violation` - GOPT_011
- `checkStageAritiesSumMatchesArity : Mono.MonoGraph -> List Violation` - GOPT_012
- `checkInitialRemainingConsistency : Mono.MonoGraph -> List Violation` - GOPT_013
- `checkRemainingStageArities : Mono.MonoGraph -> List Violation` - GOPT_014
- `checkSingleStageSaturated : Mono.MonoGraph -> List Violation` - GOPT_015

**Algorithm for each check**:

```elm
-- GOPT_010: No defaultCallInfo
checkNoDefaultCallInfo graph =
    forAllCalls graph <| \callInfo context ->
        if callInfo == defaultCallInfo then
            [ violation context "Call still has defaultCallInfo" ]
        else
            []

-- GOPT_011: stageArities non-empty for StageCurried
checkStageAritiesNonEmpty graph =
    forAllCalls graph <| \callInfo context ->
        case callInfo.callModel of
            StageCurried ->
                if List.isEmpty callInfo.stageArities then
                    [ violation context "StageCurried with empty stageArities" ]
                else if List.any (\n -> n <= 0) callInfo.stageArities then
                    [ violation context "stageArities contains non-positive value" ]
                else
                    []
            _ ->
                []

-- GOPT_012: sum(stageArities) == flattenedArity
checkStageAritiesSumMatchesArity graph =
    forAllCalls graph <| \callInfo fnExpr context ->
        let
            sum = List.sum callInfo.stageArities
            flattenedArity = getFlattenedArity (Mono.typeOf fnExpr)
        in
        if callInfo.callModel == StageCurried && sum /= flattenedArity then
            [ violation context ("stageArities sum " ++ show sum ++ " != arity " ++ show flattenedArity) ]
        else
            []

-- GOPT_013: initialRemaining == sum(remainingStageArities)
checkInitialRemainingConsistency graph =
    forAllCalls graph <| \callInfo argCount context ->
        let
            remaining = List.sum callInfo.remainingStageArities
        in
        if callInfo.initialRemaining /= remaining then
            [ violation context ("initialRemaining " ++ show callInfo.initialRemaining ++ " != sum of remaining " ++ show remaining) ]
        else
            []

-- GOPT_014: remainingStageArities correctness
checkRemainingStageArities graph =
    forAllCalls graph <| \callInfo argCount context ->
        let
            expected = computeExpectedRemaining callInfo.stageArities argCount
        in
        if callInfo.remainingStageArities /= expected then
            [ violation context "remainingStageArities mismatch" ]
        else
            []

-- GOPT_015: isSingleStageSaturated
checkSingleStageSaturated graph =
    forAllCalls graph <| \callInfo argCount context ->
        let
            firstStage = List.head callInfo.stageArities |> Maybe.withDefault 0
            expected = argCount >= firstStage
        in
        if callInfo.isSingleStageSaturated /= expected then
            [ violation context "isSingleStageSaturated mismatch" ]
        else
            []
```

### 3.2 `compiler/tests/TestLogic/GlobalOpt/CallInfoCompleteTest.elm`

**Purpose**: Test file that uses the test logic

**Structure**: Generate varied Elm source modules and run `expectCallInfoComplete`

### 3.3 `compiler/tests/TestLogic/Monomorphize/LambdaIdUniqueness.elm`

**Purpose**: Implement MONO_019 test logic

```elm
checkLambdaIdUniqueness : Mono.MonoGraph -> List Violation
checkLambdaIdUniqueness (Mono.MonoGraph data) =
    let
        allLambdaIds =
            collectLambdaIds data.nodes

        duplicates =
            findDuplicates allLambdaIds
    in
    List.map (\id -> violation ("Duplicate lambdaId: " ++ show id)) duplicates
```

### 3.4 XPHASE_010: Structural Verification (No Test File Needed)

**Purpose**: XPHASE_010 is verified structurally, not by test logic

**Verification**: Code inspection confirms that `Compiler/Generate/MLIR/Expr.elm`:
- Only pattern-matches on `MonoCall _ func args resultType callInfo`
- Never constructs `MonoCall` expressions
- Never uses `defaultCallInfo`

This invariant is "structural" - if the code structure changes to violate it, a separate code review is needed.

### 3.5 `compiler/tests/TestLogic/CrossPhase/TypeConsistency.elm`

**Purpose**: Implement XPHASE_011 test logic

**Algorithm**:
1. Capture MonoTypes before GlobalOpt
2. Run GlobalOpt
3. Compare types, allowing only MFunction canonicalization

---

## Part 4: Existing Test Files to Update

### 4.1 `compiler/tests/TestLogic/Generate/MonoFunctionArity.elm`

**Update**: This file already tests GOPT_001. Verify it runs after GlobalOpt (it does - uses `Pipeline.runToGlobalOpt`).

No changes needed.

### 4.2 `compiler/tests/TestLogic/Monomorphize/MonoCaseBranchResultType.elm`

**Update**: This file tests GOPT_003 but currently runs only to Mono. Should optionally also run after GlobalOpt to verify the normalization worked.

Add:
```elm
-- Also test after GlobalOpt to verify normalization
expectMonoCaseBranchResultTypesAfterGlobalOpt : Src.Module -> Expectation
expectMonoCaseBranchResultTypesAfterGlobalOpt srcModule =
    case Pipeline.runToGlobalOpt srcModule of
        Err msg ->
            Expect.fail ("GlobalOpt failed: " ++ msg)

        Ok { optimizedMonoGraph } ->
            -- Same logic, but on optimizedMonoGraph
            ...
```

---

## Part 5: Directory Structure

```
compiler/tests/TestLogic/
├── GlobalOpt/
│   ├── CallInfoComplete.elm         # NEW: GOPT_010-015 test logic
│   ├── CallInfoCompleteTest.elm     # NEW: Test cases
│   └── MonoInlineSimplifyTest.elm   # Existing
├── Monomorphize/
│   ├── MonoCaseBranchResultType.elm     # Existing (minor update)
│   ├── LambdaIdUniqueness.elm           # NEW: MONO_019 test logic
│   ├── LambdaIdUniquenessTest.elm       # NEW: Test cases
│   └── ...
└── CrossPhase/
    ├── TypeConsistency.elm          # NEW: XPHASE_011 test logic
    └── TypeConsistencyTest.elm      # NEW: Test cases
    # Note: XPHASE_010 is structural, no test file needed
```

---

## Part 6: Implementation Order

### Phase 1: Foundation (invariants.csv + invariant-test-logic.md)
1. Add MONO_016 to invariants.csv
2. Add GOPT_010-015 to invariants.csv
3. Add XPHASE_010-011 to invariants.csv
4. Add MONO_019 to invariants.csv
5. Add Global Optimization section to invariant-test-logic.md
6. Add Cross-Phase section to invariant-test-logic.md
7. Add MONO_019 entry to invariant-test-logic.md

### Phase 2: Core CallInfo Tests
1. Create `TestLogic/GlobalOpt/CallInfoComplete.elm`
2. Create `TestLogic/GlobalOpt/CallInfoCompleteTest.elm`
3. Run tests to validate GOPT_010-015

### Phase 3: Auxiliary Tests
1. Create `TestLogic/Monomorphize/LambdaIdUniqueness.elm`
2. Create `TestLogic/Monomorphize/LambdaIdUniquenessTest.elm`
3. Create `TestLogic/CrossPhase/TypeConsistency.elm`
4. Create `TestLogic/CrossPhase/TypeConsistencyTest.elm`
5. Document XPHASE_010 structural verification (code inspection only)

### Phase 4: Integration
1. Update existing tests as needed
2. Run full test suite
3. Verify all new invariants pass

---

## Part 7: Key Helper Functions Needed

### For CallInfo validation:

```elm
-- Extract all MonoCall expressions with their CallInfo
forAllCalls : Mono.MonoGraph -> (Mono.CallInfo -> Mono.MonoExpr -> List Int -> String -> List Violation) -> List Violation

-- Get flattened arity from function type
getFlattenedArity : Mono.MonoType -> Int

-- Compute expected remaining stage arities
computeExpectedRemaining : List Int -> Int -> List Int

-- Check if CallInfo equals defaultCallInfo
isDefaultCallInfo : Mono.CallInfo -> Bool
```

### For Lambda ID checking:

```elm
-- Collect all lambdaIds from nodes
collectLambdaIds : Dict Int Mono.MonoNode -> List Int

-- Collect lambdaIds from expressions recursively
collectExprLambdaIds : Mono.MonoExpr -> List Int
```

---

## Part 8: Summary of Changes

| File | Action | Invariants |
|------|--------|------------|
| design_docs/invariants.csv | Add 9 new entries | MONO_016, GOPT_010-015, MONO_019, XPHASE_010-011 |
| design_docs/invariant-test-logic.md | Add 2 new sections + 1 entry | GOPT_*, XPHASE_*, MONO_019 |
| TestLogic/GlobalOpt/CallInfoComplete.elm | Create new | GOPT_010-015 |
| TestLogic/GlobalOpt/CallInfoCompleteTest.elm | Create new | Tests for above |
| TestLogic/Monomorphize/LambdaIdUniqueness.elm | Create new | MONO_019 |
| TestLogic/Monomorphize/LambdaIdUniquenessTest.elm | Create new | Tests for above |
| TestLogic/CrossPhase/TypeConsistency.elm | Create new | XPHASE_011 |
| TestLogic/CrossPhase/TypeConsistencyTest.elm | Create new | Tests for above |
| (XPHASE_010) | Structural verification | Code inspection only |

---

## Open Questions (RESOLVED)

### Q1: FlattenedExternal CallModel handling

**Question**: Should GOPT_011/012 checks apply to FlattenedExternal calls, or only StageCurried?

**Resolution**: Only StageCurried calls need stageArities validation. FlattenedExternal (kernel) calls have fixed ABIs and don't use staged currying. However, GOPT_010 (no defaultCallInfo) applies to ALL calls - even kernel calls need computed CallInfo (with FlattenedExternal callModel).

Evidence: `defaultCallInfo` is used as a placeholder in both Monomorphize and GlobalOpt, replaced by `computeCallInfo` for all call models.

### Q2: XPHASE_010 implementation strategy

**Question**: How do we capture CallInfo at MLIR codegen entry without modifying compiler code?

**Resolution**: Use structural verification (Option 3). Confirmed that MLIR codegen in `Compiler/Generate/MLIR/Expr.elm` only reads CallInfo:
- `generateCall`, `generateClosureApplication`, `generateSaturatedCall` receive `callInfo` as parameter
- No `MonoCall` construction or `defaultCallInfo` usage in MLIR codegen
- MLIR only pattern-matches on `MonoCall _ func args resultType callInfo`

Therefore: rely on GOPT_010-015 to validate correctness after GlobalOpt. XPHASE_010 can be documented as "structurally enforced" rather than tested.

### Q3: Where do lambdaIds come from?

**Question**: Are lambdaIds assigned in Monomorphization or earlier?

**Resolution**: lambdaIds are assigned during Monomorphization in `Specialize.elm:132-133`:
```elm
lambdaId =
    Mono.AnonymousLambda state.currentModule state.lambdaCounter
```
They are never modified after. Test should run after Monomorphization but before GlobalOpt to catch issues early. Running after GlobalOpt is also valid since lambdaIds don't change.

### Q4: TestPipeline.runToGlobalOpt availability

**Question**: Does TestPipeline already expose a `runToGlobalOpt` function?

**Resolution**: Yes, it exists at `TestLogic/TestPipeline.elm:307`:
```elm
runToGlobalOpt : Src.Module -> Result String GlobalOptArtifacts

type alias GlobalOptArtifacts =
    { canonical : Can.Module
    , annotations : Dict String Name.Name Can.Annotation
    , nodeTypes : PostSolve.NodeTypes
    , kernelEnv : KernelTypes.KernelTypeEnv
    , localGraph : TOpt.LocalGraph
    , globalGraph : TOpt.GlobalGraph
    , globalTypeEnv : TypeEnv.GlobalTypeEnv
    , monoGraph : Mono.MonoGraph           -- Before GlobalOpt
    , optimizedMonoGraph : Mono.MonoGraph  -- After GlobalOpt
    }
```
Tests can access both `monoGraph` and `optimizedMonoGraph` to compare before/after states.
