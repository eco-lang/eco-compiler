# Migrate to LLVM's RewriteStatepointsForGC Pass

## Status: DEFERRED
## Priority: Medium (correctness improvement, replaces manual statepoint conversion)
## Prerequisite: Option B dead-relocate fix must be in place first as interim solution

---

## Goal

Replace our manual `gc.statepoint` + `gc.relocate` emission in `StatepointConversion.cpp` with LLVM's built-in `RewriteStatepointsForGC` pass. This pass correctly handles all statepoint lowering invariants including instruction ordering relative to other statepoints, liveness computation, and base pointer derivation.

## Why

Our current `convertSafepointMarkers` manually emits `gc.relocate` after each `gc.statepoint` and rewrites SSA uses. This has two problems:

1. **Instruction reordering**: LLVM's optimizer can move a `gc.relocate` from statepoint S1 past statepoint S2 in the same basic block, violating SelectionDAG's assumption that all relocates from S1 are visited before S2 begins. Evidence: `__closure_wrapper_Terminal_Main_lambda_8605$cap` crash at `-O2`.

2. **Reimplementing LLVM's logic**: We duplicate what `RewriteStatepointsForGC` already does (liveness analysis, relocate insertion, SSA rewriting), but without its ordering guarantees or integration with the optimization pipeline.

`RewriteStatepointsForGC` is designed to run as part of the LLVM pass pipeline and produces statepoint sequences that are compatible with SelectionDAG's expectations.

## Current Architecture

```
Elm compiler → eco.safepoint ops in MLIR
    ↓
SafepointOpLowering (MLIR pass) → __eco_safepoint_marker calls with inttoptr args
    ↓
convertSafepointMarkers (LLVM IR pass) → gc.statepoint + gc.relocate + SSA rewrite
    ↓
LLVM optimization → may reorder gc.relocate (BUG)
    ↓
SelectionDAG codegen → asserts on ordering
```

## Target Architecture

```
Elm compiler → eco.safepoint ops in MLIR
    ↓
SafepointOpLowering (MLIR pass) → calls to __eco_gc_safepoint_nop with gc-root args
    ↓
MLIR → LLVM IR translation (safepoint markers become regular calls)
    ↓
LLVM optimization pipeline (including RewriteStatepointsForGC)
    → Automatically identifies GC roots at each call site
    → Inserts gc.statepoint wrapping each call
    → Inserts gc.relocate with correct ordering
    → Rewrites SSA uses
    ↓
SelectionDAG codegen → works correctly
```

## Steps

### Step 1: Change SafepointOpLowering to emit abstract GC root annotations

Instead of emitting `__eco_safepoint_marker(inttoptr %val)` calls, emit the safepoint as a call to a no-op function that LLVM's `RewriteStatepointsForGC` can recognize. The key insight: `RewriteStatepointsForGC` works on functions with `gc "statepoint-example"` attribute and rewrites ALL calls in those functions (not just marker calls) into statepoints with gc-live bundles computed from liveness analysis.

This means we may not need explicit safepoint markers at all — every call (including `eco_alloc_*`, kernel calls, etc.) would automatically get statepoint treatment. The Elm compiler's `emitSafepoint` would become unnecessary on the LLVM IR side; the pass handles liveness automatically.

### Step 2: Integrate RewriteStatepointsForGC into the pipeline

Add `RewriteStatepointsForGC` to the LLVM pass pipeline in:
- `eco-boot.cpp` (AOT native compiler)
- `ecoc.cpp` (AOT + JIT paths)
- `EcoRunner.cpp` (test JIT)

The pass should run after other optimizations but before codegen. It needs the `gc "statepoint-example"` function attribute (already present on our functions).

### Step 3: Remove convertSafepointMarkers

Once `RewriteStatepointsForGC` handles statepoint insertion:
- Remove `convertSafepointMarkers` from `StatepointConversion.cpp`
- Remove `removeDeadGCRelocates` (no longer needed)
- Remove `SafepointOpLowering` from the MLIR pass (or simplify it to just strip the marker ops)
- The `__eco_safepoint_marker` / `__eco_gc_safepoint_nop` functions become unnecessary

### Step 4: Verify HPointer representation compatibility

Our HPointers are `i64` values that are `inttoptr`'d to `ptr addrspace(1)` for GC purposes. `RewriteStatepointsForGC` identifies GC pointers by their type (`ptr addrspace(1)`). We need to verify:
- The pass correctly identifies our `inttoptr i64 → ptr addrspace(1)` values as GC roots
- The `ptrtoint` back to `i64` after relocation is handled correctly
- Or: consider changing the HPointer representation to `ptr addrspace(1)` throughout, eliminating the inttoptr/ptrtoint dance

### Step 5: Handle the nop safepoint pattern

Our current safepoints call a no-op function (`__eco_gc_safepoint_nop`). `RewriteStatepointsForGC` wraps ALL calls (not just our markers) in statepoints. This means:
- Calls to `eco_alloc_*`, kernel functions, etc. would all get statepoints automatically
- The explicit `eco.safepoint` ops before these calls might become redundant
- We may want to keep them for the MLIR-level liveness tracking, or remove them entirely

## Risks

- `RewriteStatepointsForGC` may not handle our `i64` ↔ `ptr addrspace(1)` representation well
- The pass adds statepoints to ALL calls, which may increase overhead for calls that can't trigger GC
- Need to verify stack map format compatibility with our `ThreadLocalHeap::collectStackRootsFromStackMap`

## Testing

- All existing E2E tests must pass
- Bootstrap through Stage 8 must succeed
- GC stress tests must not regress
- Stack map parsing must still work correctly
