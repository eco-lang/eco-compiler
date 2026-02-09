# Plan: Reuse CallEnv + computeCallInfo for Staging Pipeline

## Problem Statement

The `Staging.computeCallInfoForExpr` function (lines 245-283 in `Staging.elm`) computes CallInfo incorrectly by:
1. Using `Mono.typeOf callee` to derive arities instead of actual PAP (partial application) arities
2. Using `Mono.segmentLengths calleeType` which gives type-derived stage arities, not closure body arities
3. Setting `initialRemaining` from type rather than from the closure's actual param count

This violates CGEN_052: "eco.papExtend remaining_arity must equal the source PAP's remaining arity before this application."

The existing `MonoGlobalOptimize.computeCallInfo` (lines 1819-1895) already correctly implements CallInfo semantics by:
- Using `sourceArityForCallee` which returns PAP arity consistent with `papCreate`
- Using `closureBodyStageArities` to get actual body staging after canonicalization
- Setting `initialRemaining = sourceArity`, which is what `applyByStages` expects

## Solution Overview

Make `Staging.annotateCallStaging` delegate to `MonoGlobalOptimize.annotateCallStaging` instead of implementing its own CallInfo computation. This maintains a single source of truth for CallInfo semantics.

---

## Step-by-Step Implementation Plan

### Step 1: Add Import to Staging.elm

**File:** `compiler/src/Compiler/GlobalOpt/Staging.elm`

Add import for MonoGlobalOptimize:
```elm
import Compiler.GlobalOpt.MonoGlobalOptimize as MGO
```

**Lines affected:** Around line 21 (import section)

---

### Step 2: Modify annotateCallStaging to Delegate

**File:** `compiler/src/Compiler/GlobalOpt/Staging.elm`
**Function:** `annotateCallStaging` (lines 115-125)

**Current implementation:**
```elm
annotateCallStaging solution (Mono.MonoGraph mono0) =
    let
        nodes1 =
            Dict.map
                (\_ node -> annotateNode solution node)
                mono0.nodes

        mono1 =
            { mono0 | nodes = nodes1 }
    in
    Mono.MonoGraph mono1
```

**New implementation:**
```elm
annotateCallStaging : StagingSolution -> Mono.MonoGraph -> Mono.MonoGraph
annotateCallStaging _ graph =
    -- Delegate to MonoGlobalOptimize's annotateCallStaging which uses
    -- the correct CallEnv + computeCallInfo machinery for CallInfo semantics.
    -- The staging solution parameter is unused here since all staging-dependent
    -- rewrites (wrappers, type canonicalization) were applied in earlier phases.
    MGO.annotateCallStaging graph
```

**Rationale:**
- The `StagingSolution` parameter becomes unused because:
  1. All staging-dependent rewrites happen in `Staging.analyzeAndSolveStaging` via `Rewriter.applyStagingSolution`
  2. Type canonicalization happens before this phase
  3. `MGO.annotateCallStaging` operates on the already-rewritten graph

---

### Step 3: Remove Dead Code

**File:** `compiler/src/Compiler/GlobalOpt/Staging.elm`

Delete or comment out the following functions that become unused:
1. `annotateNode` (lines 129-143)
2. `annotateExpr` (lines 147-218)
3. `annotateDef` (lines 222-228)
4. `computeCallInfoForExpr` (lines 245-283)

**Note:** Before deleting, verify no other code references these functions.

---

### Step 4: Verify Pipeline Order

**File:** `compiler/src/Compiler/GlobalOpt/MonoGlobalOptimize.elm`
**Function:** `globalOptimize` (lines 94-113)

Current pipeline order (should remain unchanged):
```elm
globalOptimize typeEnv graph0 =
    let
        -- Phase 0: Inlining and simplification
        ( graph0a, _ ) =
            MonoInlineSimplify.optimize typeEnv graph0

        -- Phase 1+2: Staging analysis + graph rewrite (wrappers + types)
        ( stagingSolution, graph1 ) =
            Staging.analyzeAndSolveStaging typeEnv graph0a

        -- Phase 3: Validate closure staging invariants (GOPT_001, GOPT_003)
        graph2 =
            Staging.validateClosureStaging graph1

        -- Phase 4: Annotate call staging metadata using staging solution
        graph3 =
            Staging.annotateCallStaging stagingSolution graph2
    in
    graph3
```

**Verification:** After the change, `Staging.annotateCallStaging` internally calls `MGO.annotateCallStaging`, which:
- Uses `computeCallInfo` on the **post-rewrite** graph
- Has access to canonicalized types and ABI wrappers from Phase 1+2
- Computes `initialRemaining` from `sourceArityForCallee` (PAP arity), not type

---

### Step 5: Run Tests

Execute the following test suites to verify correctness:

1. **CallInfo completeness tests (GOPT_010-015):**
   ```bash
   cd compiler && npx elm-test-rs --fuzz 1 tests/TestLogic/GlobalOpt/CallInfoComplete.elm
   ```

2. **PapExtend arity test (CGEN_052):**
   ```bash
   cd compiler && npx elm-test-rs --fuzz 1 tests/TestLogic/Generate/CodeGen/PapExtendArityTest.elm
   ```

3. **Full E2E tests:**
   ```bash
   cmake --build build --target check
   ```

4. **Staging validation tests (GOPT_001, GOPT_003):**
   ```bash
   cd compiler && npx elm-test-rs --fuzz 1 tests/TestLogic/GlobalOpt/
   ```

---

## Affected Files Summary

| File | Changes |
|------|---------|
| `compiler/src/Compiler/GlobalOpt/Staging.elm` | Add import, replace `annotateCallStaging`, remove dead code |
| `compiler/src/Compiler/GlobalOpt/MonoGlobalOptimize.elm` | No changes needed |

---

## Invariants Affected

| Invariant | Status | Notes |
|-----------|--------|-------|
| GOPT_010 | Preserved | All MonoCall nodes get non-placeholder CallInfo |
| GOPT_011 | Preserved | StageCurried calls get non-empty stageArities |
| GOPT_012 | Preserved | stageArities sum matches total arity |
| GOPT_013 | Preserved | initialRemaining/remainingStageArities semantics correct |
| GOPT_014 | Preserved | isSingleStageSaturated computed correctly |
| GOPT_015 | Preserved | FlattenedExternal calls handled correctly |
| CGEN_052 | **Fixed** | papExtend remaining_arity now matches source PAP |

---

## Why This Works

1. **sourceArityForCallee** (line 1677-1685) returns:
   - For kernels: total ABI arity (flattened)
   - For user closures: `closureInfo.params` length (PAP arity matching `papCreate`)
   - For aliases: the aliased value's arity

2. **closureBodyStageArities** (line 1708-1806) returns:
   - Actual stage arities from closure bodies after canonicalization
   - Handles case/if expressions that return closures with different staging

3. **computeCallInfo** (line 1819-1895) sets:
   - `initialRemaining = sourceArity` (from `sourceArityForCallee`)
   - `remainingStageArities` from `closureBodyStageArities` or falls back to type

This ensures the `let f = (+) in f 1 2` case works correctly:
- `f` is bound to `(+)` which has `sourceArity = 2` (kernel's total ABI arity)
- `f 1 2` gets `initialRemaining = 2`, matching what `papCreate` used

---

## Risks and Mitigations

| Risk | Mitigation |
|------|------------|
| Staging solution has data needed later | **Verified:** `StagingSolution` is only used in `analyzeAndSolveStaging` via `Rewriter.applyStagingSolution`. No downstream user after call annotation. |
| Performance regression from double traversal | **Not a concern:** We're *replacing* the Staging traversal with the MGO traversal, not adding one. Single O(N) traversal remains. |
| Tests depend on Staging internals | **Verified:** No tests directly call `computeCallInfoForExpr`. Tests assert on CallInfo properties in the final graph (GOPT_010-015). |

---

## Design Decisions (Resolved)

### 1. StagingSolution usage after annotateCallStaging

**Decision:** No downstream code depends on `StagingSolution` after call annotation.

**Rationale:**
- `StagingSolution` is produced in `Staging.analyzeAndSolveStaging`
- Consumed by `Staging.Rewriter.applyStagingSolution` to rewrite closures/tail-funcs to canonical staging
- Threaded through `Rewriter.rewriteNode`/`rewriteExpr`/`wrapClosureToCanonical` for canonical segmentation lookup
- After that, `globalOptimize` passes it only to `annotateCallStaging` (which we're changing)

### 2. Keep StagingSolution parameter (short-term)

**Decision:** Keep the parameter but ignore it.

```elm
annotateCallStaging : StagingSolution -> Mono.MonoGraph -> Mono.MonoGraph
annotateCallStaging _ graph =
    -- CallInfo computation is now delegated to MonoGlobalOptimize.annotateCallStaging
    -- which uses CallEnv + computeCallInfo for correct PAP arity semantics.
    -- The staging solution parameter is unused here since all staging-dependent
    -- rewrites (wrappers, type canonicalization) were applied in earlier phases
    -- by Rewriter.applyStagingSolution.
    MGO.annotateCallStaging graph
```

**Rationale:**
- Preserves existing `globalOptimize` call site
- Maintains documented 4-phase shape in `pass_global_optimization_theory.md`
- Can be removed later as a follow-up refactor once confidence is established

### 3. No tests directly test computeCallInfoForExpr

**Decision:** Safe to delete `computeCallInfoForExpr` and related dead code.

**Rationale:**
- `computeCallInfoForExpr` is only used in `annotateExpr` → `annotateCallStaging`
- GlobalOpt invariant tests (GOPT_010-015) assert on CallInfo properties in the final graph
- No test module imports `Compiler.GlobalOpt.Staging` to call `computeCallInfoForExpr` directly

### 4. Performance: single traversal maintained

**Decision:** No performance concern.

**Rationale:**
- Current: `Staging.annotateCallStaging` does one full graph traversal
- New: `MGO.annotateCallStaging` does one full graph traversal
- We're *replacing* the Staging traversal with the MGO traversal, not adding a second one
- Cost of O(N) tree walk over `MonoGraph` is tiny compared to monomorphization, specialization, and MLIR codegen
