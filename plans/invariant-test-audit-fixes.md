# Plan: Invariant Test Audit Fixes

## Overview

This plan addresses the issues found in the MONO/GOPT invariant audit:
- Multiple test files reference wrong invariants (MONO_016/GOPT_001 confusion)
- Missing GOPT section in invariant-test-logic.md
- 6 new invariants have no test implementations
- Existing tests run at wrong phases or test wrong things

---

## Part 1: Resolve MONO_016/GOPT_001 Confusion

### Background

The confusion stems from:
- **GOPT_001**: "Closure params match stage arity" — checks `closureInfo.params.length == stageArity(type)`
- **MONO_016**: "Wrapper closures invoke callees stage-by-stage" — checks MonoCall arg counts respect callee type
- **"GOPT_016"**: Referenced in `WrapperCurriedCalls.elm` docstring but **doesn't exist** in invariants.csv

### Resolution

1. **GOPT_001** stays as-is: closure params == stage arity (after GlobalOpt)
2. **MONO_016** is distinct: wrapper closures generate correctly staged MonoCalls
3. Delete all references to "GOPT_016" — it was a typo/confusion

### File Changes

**WrapperCurriedCalls.elm** currently tests GOPT_001 (stage arity), not MONO_016:
- Rename to reflect what it actually tests, OR
- Rewrite to actually test MONO_016

Decision: **Rewrite to test MONO_016** — the actual wrapper currying logic. Move current stage-arity check to the new GOPT_001 test file.

---

## Part 2: Split MonoFunctionArity.elm

### Current State

`TestLogic/Generate/MonoFunctionArity.elm`:
- Runs after GlobalOpt (`Pipeline.runToGlobalOpt`)
- Checks MONO_012 (function arity matches parameters)
- Also checks GOPT_001 (closure params == stage arity)

### New Structure

Create two separate test modules:

#### 2.1 `TestLogic/Monomorphize/MonoFunctionArity.elm` (NEW)

**Tests:** MONO_012 at Monomorphization phase
**Pipeline:** `runToMono`
**Logic:**
- For MonoTailFunc: params.length == flattenedArity(type)
- For MonoCall: argCount <= flattenedArity(calleeType) — no over-application
- Does NOT check stage arity (that's GlobalOpt's job)

#### 2.2 `TestLogic/GlobalOpt/ClosureStageArity.elm` (NEW)

**Tests:** GOPT_001 at GlobalOpt phase
**Pipeline:** `runToGlobalOpt`
**Logic:**
- For MonoClosure: closureInfo.params.length == stageArity(closureType)
- This is established by `canonicalizeClosureStaging`

#### 2.3 Delete/Deprecate `TestLogic/Generate/MonoFunctionArity.elm`

The existing file mixes both concerns. After creating the two new files, remove or deprecate this one.

---

## Part 3: Fix WrapperCurriedCalls.elm to Test MONO_016

### Current State

File claims to test "GOPT_016" but actually checks closure param count == stage arity (which is GOPT_001).

### What MONO_016 Actually Requires

From `invariant-test-logic.md` lines 617-631:

> When creating uncurried wrapper closures for functions that return functions:
> - Get the callee expression's type and determine how many arguments it accepts at the first application level.
> - If the callee accepts fewer arguments than the wrapper provides, generate nested MonoCall expressions.
> - Each MonoCall must pass only the number of arguments the callee type accepts at that level.

### New Test Logic

```elm
-- MONO_016: For every MonoCall in a wrapper closure body,
-- argCount <= stageArity(calleeType)
-- If callee is MFunction [A] (MFunction [B,C] D) and we have args [a,b,c]:
--   First call: call(f, [a]) with stageArity=1, argCount=1 ✓
--   Second call: call(result, [b,c]) with stageArity=2, argCount=2 ✓
-- NOT: call(f, [a,b,c]) with stageArity=1, argCount=3 ✗

checkWrapperCallArities : Mono.MonoGraph -> List Violation
checkWrapperCallArities graph =
    forAllMonoCalls graph <| \fnExpr argExprs context ->
        let
            fnType = Mono.typeOf fnExpr
            stageArity = getStageArity fnType  -- outermost MFunction param count
            argCount = List.length argExprs
        in
        if stageArity > 0 && argCount > stageArity then
            [ violation context
                ("MonoCall has " ++ show argCount ++
                 " args but callee type has stage arity " ++ show stageArity)
            ]
        else
            []
```

### File Changes

1. Update docstring to reference MONO_016 (not GOPT_016)
2. Rewrite `checkWrapperCurriedCalls` to check MonoCall arg counts vs callee stage arity
3. Run via `runToMono` (not `runToGlobalOpt`) since this is a Monomorphization invariant
4. Remove the existing closure param count check (that moves to GOPT_001 test)

---

## Part 4: Fix MonoCaseBranchResultType.elm Error Messages

### Current State

Error messages say "GOPT_003 violation" but tests MONO_018.

### Changes

1. Update error messages from "GOPT_003" to "MONO_018"
2. Keep `runToMono` pipeline (correct for MONO_018)
3. Add a separate test function for GOPT_003 that runs after GlobalOpt

### New Function

```elm
-- GOPT_003: After GlobalOpt, branches also have compatible staging
expectMonoCaseBranchTypesAfterGlobalOpt : Src.Module -> Expectation
expectMonoCaseBranchTypesAfterGlobalOpt srcModule =
    case Pipeline.runToGlobalOpt srcModule of
        Err msg -> Expect.fail msg
        Ok { optimizedMonoGraph } ->
            checkMonoCaseBranchResultTypes optimizedMonoGraph
            |> formatAsExpectation
```

---

## Part 5: Add GOPT Section to invariant-test-logic.md

### Location

Insert between Monomorphization section (ends ~line 663) and MLIR Codegen section.

### Content

```markdown
---

## Global Optimization Phase (GOPT_*)

--
name: Closure params match stage arity
phase: global optimization
invariants: GOPT_001
ir: MonoClosure after GlobalOpt
logic: For every MonoClosure with MFunction type after GlobalOpt:
  * Compute stageArity = length of outermost MFunction param list
  * Assert length(closureInfo.params) == stageArity
  * Established by canonicalizeClosureStaging in GlobalOpt
inputs: GlobalOpt output graphs
oracle: All closures have param counts matching their stage arity.
tests: compiler/tests/TestLogic/GlobalOpt/ClosureStageArityTest.elm
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
tests: NOT YET IMPLEMENTED
--
--
name: Case/if branches have compatible staging
phase: global optimization
invariants: GOPT_003
ir: MonoCase, MonoIf after normalizeCaseIfAbi
logic: For every MonoCase and MonoIf returning function types after GlobalOpt:
  * All branch result types have identical staging signatures
  * Non-conforming branches were wrapped via buildAbiWrapperGO
  * This extends MONO_018 (type equality) to include staging equality
inputs: GlobalOpt output with function-returning cases
oracle: All branches unify to a common staging; no ABI mismatches.
tests: compiler/tests/TestLogic/GlobalOpt/CaseBranchStagingTest.elm
--
--
name: No placeholder CallInfo after GlobalOpt
phase: global optimization
invariants: GOPT_010
ir: MonoCall expressions
logic: Walk all MonoCall expressions in the optimized graph:
  * Assert callInfo does not equal defaultCallInfo
  * defaultCallInfo has stageArities=[] and initialRemaining=0
  * Every call site must have a computed CallInfo reflecting staging decisions
inputs: GlobalOpt output graphs
oracle: Every MonoCall has computed CallInfo; no placeholders remain.
tests: compiler/tests/TestLogic/GlobalOpt/CallInfoCompleteTest.elm
--
--
name: StageCurried stageArities is non-empty and positive
phase: global optimization
invariants: GOPT_011
ir: CallInfo in MonoCall
logic: For every MonoCall with callModel == StageCurried:
  * Assert stageArities is non-empty
  * Assert all elements in stageArities are positive integers
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
  * Compute flattenedArity = total params in flattened MFunction type
  * Assert sum == flattenedArity
inputs: GlobalOpt output graphs with various function arities
oracle: Stage groupings cover exactly all function parameters.
tests: compiler/tests/TestLogic/GlobalOpt/CallInfoCompleteTest.elm
--
--
name: PAP remaining-arity semantics
phase: global optimization
invariants: GOPT_013
ir: CallInfo in MonoCall for partial applications
logic: For StageCurried calls creating/extending PAPs:
  * Assert callInfo.initialRemaining == List.sum callInfo.remainingStageArities
  * remainingStageArities contains arities of unsatisfied stages
  * Example: stageArities=[2,3], argCount=2 -> remainingStageArities=[3], initialRemaining=3
inputs: GlobalOpt graphs with partial applications
oracle: initialRemaining correctly reflects unsatisfied stages.
tests: compiler/tests/TestLogic/GlobalOpt/CallInfoCompleteTest.elm
--
--
name: isSingleStageSaturated semantics
phase: global optimization
invariants: GOPT_014
ir: CallInfo in MonoCall
logic: Assert callInfo.isSingleStageSaturated is true iff:
  * This call does not create/extend a PAP for the current stage
  * Equivalently: argCount >= stageArities[0]
inputs: GlobalOpt graphs with various call patterns
oracle: Flag correctly identifies single-stage saturation.
tests: compiler/tests/TestLogic/GlobalOpt/CallInfoCompleteTest.elm
--
--
name: FlattenedExternal has no staged currying
phase: global optimization
invariants: GOPT_015
ir: CallInfo in MonoCall for kernel/extern calls
logic: For every MonoCall with callModel == FlattenedExternal:
  * Assert stageArities == []
  * Assert remainingStageArities == []
  * Assert initialRemaining == 0
  * MLIR treats such calls as flat ABI calls
inputs: GlobalOpt graphs with kernel calls
oracle: Kernel calls have empty stage information.
tests: compiler/tests/TestLogic/GlobalOpt/CallInfoCompleteTest.elm
--
```

---

## Part 6: Create Missing Test Files

### 6.1 `TestLogic/GlobalOpt/ClosureStageArity.elm`

**Purpose:** Test GOPT_001 (closure params == stage arity)

**Functions:**
- `expectClosureStageArity : Src.Module -> Expectation`
- `checkClosureStageArity : Mono.MonoGraph -> List Violation`

**Logic:** (moved from current MonoFunctionArity.elm)
```elm
checkClosureStageArity graph =
    forAllClosures graph <| \closureInfo closureType context ->
        let
            paramCount = List.length closureInfo.params
            stageArity = getStageArity closureType
        in
        if paramCount /= stageArity then
            [ violation context "Closure params != stage arity" ]
        else
            []
```

### 6.2 `TestLogic/GlobalOpt/CallInfoComplete.elm`

**Purpose:** Test GOPT_010-015 (CallInfo invariants)

**Functions:**
- `expectCallInfoComplete : Src.Module -> Expectation`
- `checkNoPlaceholderCallInfo : Mono.MonoGraph -> List Violation` — GOPT_010
- `checkStageAritiesNonEmpty : Mono.MonoGraph -> List Violation` — GOPT_011
- `checkStageAritiesSumMatchesArity : Mono.MonoGraph -> List Violation` — GOPT_012
- `checkPartialApplicationAritySemantics : Mono.MonoGraph -> List Violation` — GOPT_013
- `checkSingleStageSaturated : Mono.MonoGraph -> List Violation` — GOPT_014
- `checkFlattenedExternalCallInfo : Mono.MonoGraph -> List Violation` — GOPT_015

### 6.3 `TestLogic/GlobalOpt/CaseBranchStaging.elm`

**Purpose:** Test GOPT_003 (case branches have compatible staging after GlobalOpt)

**Functions:**
- `expectCaseBranchStaging : Src.Module -> Expectation`
- `checkCaseBranchStaging : Mono.MonoGraph -> List Violation`

**Logic:** Same as MonoCaseBranchResultType but runs after GlobalOpt and specifically checks staging compatibility.

### 6.4 `TestLogic/Monomorphize/LambdaIdUniqueness.elm`

**Purpose:** Test MONO_019 (lambdaId uniqueness)

**Functions:**
- `expectLambdaIdUniqueness : Src.Module -> Expectation`
- `checkLambdaIdUniqueness : Mono.MonoGraph -> List Violation`

**Logic:**
```elm
checkLambdaIdUniqueness (Mono.MonoGraph data) =
    let
        allIds = collectAllLambdaIds data.nodes
        duplicates = findDuplicates allIds
    in
    List.map (\id -> violation ("Duplicate lambdaId: " ++ show id)) duplicates
```

### 6.5 `TestLogic/Monomorphize/MonoFunctionArity.elm` (NEW location)

**Purpose:** Test MONO_012 at Monomorphization phase

**Functions:**
- `expectMonoFunctionArity : Src.Module -> Expectation`
- `checkMonoFunctionArity : Mono.MonoGraph -> List Violation`

**Pipeline:** `runToMono` (NOT runToGlobalOpt)

**Logic:**
- MonoTailFunc: params.length == flattenedArity(type)
- MonoCall: argCount <= flattenedArity(calleeType)

### 6.6 `TestLogic/CrossPhase/TypeConsistency.elm`

**Purpose:** Test XPHASE_011 (types preserved except MFunction canonicalization)

**Functions:**
- `expectTypeConsistency : Src.Module -> Expectation`
- `checkTypePreservation : Mono.MonoGraph -> Mono.MonoGraph -> List Violation`

**Logic:** Compare monoGraph (before GlobalOpt) with optimizedMonoGraph (after), allowing only MFunction flattening.

---

## Part 7: Add MONO_019 to invariant-test-logic.md

Insert after MONO_018 section:

```markdown
--
name: Lambda IDs are unique within graph
phase: monomorphization
invariants: MONO_019
ir: MonoGraph (all MonoClosure and MonoTailFunc nodes)
logic: Collect all lambdaId values from:
  * closureInfo.lambdaId in MonoClosure expressions
  * Any lambdaId in related structures
Assert the collected set has no duplicates.
inputs: Monomorphized graphs with many closures
oracle: Every closure/function has a unique lambdaId.
tests: compiler/tests/TestLogic/Monomorphize/LambdaIdUniquenessTest.elm
--
```

---

## Part 8: Add CrossPhase Section to invariant-test-logic.md

The existing XPHASE section only has XPHASE_001 and XPHASE_002. Add entries for XPHASE_010 and XPHASE_011:

```markdown
--
name: CallInfo flows unchanged to MLIR
phase: cross-phase
invariants: XPHASE_010
ir: MonoGraph from GlobalOpt to MLIR codegen
logic: Structural verification by code inspection:
  * MLIR codegen only pattern-matches on MonoCall
  * It never constructs MonoCall expressions
  * It never uses defaultCallInfo
  * Therefore CallInfo values from GlobalOpt pass through unchanged
inputs: Code review
oracle: No MonoCall construction or defaultCallInfo usage in MLIR codegen.
verification: structural (code inspection)
--
--
name: Types preserved except MFunction canonicalization
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

---

## Part 9: Implementation Order

### Phase 1: Documentation Updates
1. Add GOPT section to invariant-test-logic.md (all 9 invariants)
2. Add MONO_019 entry to invariant-test-logic.md
3. Add XPHASE_010, XPHASE_011 entries to invariant-test-logic.md

### Phase 2: Fix Existing Tests
1. Fix `WrapperCurriedCalls.elm`:
   - Update docstring (MONO_016, not GOPT_016)
   - Rewrite to check MonoCall arg counts vs callee stage arity
   - Change pipeline to `runToMono`
2. Fix `MonoCaseBranchResultType.elm`:
   - Change error messages from "GOPT_003" to "MONO_018"
3. Delete/deprecate `TestLogic/Generate/MonoFunctionArity.elm`

### Phase 3: Create New Test Files
1. `TestLogic/Monomorphize/MonoFunctionArity.elm` — MONO_012
2. `TestLogic/Monomorphize/LambdaIdUniqueness.elm` — MONO_019
3. `TestLogic/GlobalOpt/ClosureStageArity.elm` — GOPT_001
4. `TestLogic/GlobalOpt/CaseBranchStaging.elm` — GOPT_003
5. `TestLogic/GlobalOpt/CallInfoComplete.elm` — GOPT_010-015
6. Create `TestLogic/CrossPhase/` directory
7. `TestLogic/CrossPhase/TypeConsistency.elm` — XPHASE_011

### Phase 4: Create Test Case Files
For each new test logic file, create corresponding `*Test.elm` files with actual test cases.

### Phase 5: Verification
1. Run `npx elm-test-rs --fuzz 1` in compiler directory
2. Verify all new tests pass
3. Verify no regressions in existing tests

---

## Summary of Changes

| File | Action | Invariants |
|------|--------|------------|
| design_docs/invariant-test-logic.md | Add GOPT section (9 entries) | GOPT_001-003, GOPT_010-015 |
| design_docs/invariant-test-logic.md | Add MONO_019 entry | MONO_019 |
| design_docs/invariant-test-logic.md | Add XPHASE entries | XPHASE_010, XPHASE_011 |
| TestLogic/Monomorphize/WrapperCurriedCalls.elm | Rewrite for MONO_016 | MONO_016 |
| TestLogic/Monomorphize/MonoCaseBranchResultType.elm | Fix error messages | MONO_018 |
| TestLogic/Generate/MonoFunctionArity.elm | Delete/deprecate | — |
| TestLogic/Monomorphize/MonoFunctionArity.elm | Create new | MONO_012 |
| TestLogic/Monomorphize/LambdaIdUniqueness.elm | Create new | MONO_019 |
| TestLogic/GlobalOpt/ClosureStageArity.elm | Create new | GOPT_001 |
| TestLogic/GlobalOpt/CaseBranchStaging.elm | Create new | GOPT_003 |
| TestLogic/GlobalOpt/CallInfoComplete.elm | Create new | GOPT_010-015 |
| TestLogic/CrossPhase/TypeConsistency.elm | Create new | XPHASE_011 |
