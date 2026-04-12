# Plan: Allocation-Based Statepoints for GC

## Goal

Re-introduce allocation-based statepoints so that **every place that may run GC has a stackmap record**. Currently, only `eco.safepoint` (poll-based) produces statepoints. Allocation calls use unified `eco_alloc_*` functions that may GC internally but have no statepoint coverage — meaning if GC runs from an allocation slow path, `collectStackRootsFromStackMap()` cannot find a stackmap record for the caller, and stack roots are invisible.

After this change:
- Allocation slow paths (`eco_alloc_*_slow`) are statepoint-wrapped.
- `__eco_safepoint_poll` remains an additional safepoint for loops/back-edges.
- GC entered from either path uses the same `collectStackRootsFromStackMap()`.

## Current State

| Component | Status |
|-----------|--------|
| `__eco_safepoint_poll` runtime impl | Fully implemented |
| `shouldCollectAtSafepoint` / `collectAtSafepoint` | Fully implemented (Allocator delegates to ThreadLocalHeap) |
| `collectStackRootsFromStackMap` | Fully implemented (x86-64, frame-pointer walking) |
| `minorGC` / `majorGC` | Fully implemented |
| Fast/slow alloc C++ functions | Implemented in `RuntimeExports.cpp` (e.g. `eco_alloc_cons_fast/slow`) |
| Fast/slow alloc declared in header | **NO** — only unified variants in `RuntimeExports.h` |
| Fast/slow alloc registered for JIT | **NO** — `RuntimeSymbols.cpp` only registers unified variants |
| Fast/slow alloc used in codegen | **NO** — `EcoToLLVMHeap.cpp` calls unified `eco_alloc_*` only |
| `eco.safepoint` → marker+poll lowering | Fully implemented (`EcoToLLVMErrorDebug.cpp`) |
| `StatepointConversion` Phase 1 | Only handles `__eco_safepoint_poll` as target |
| `StatepointConversion` Phase 2 | Generic (alloca+relocate+mem2reg), should work for any target |
| `EcoGCPrepare` live root computation | Implemented (`computeLiveEcoValues`) for safepoints AND allocation groups |
| `convertSafepointMarkers` in pipeline | Called in JIT, AOT, and test runner paths |
| `removeDeadGCRelocates` in pipeline | Called only in AOT path (`eco-boot.cpp`) |

## Decisions (from Q&A)

| Question | Decision | Rationale |
|----------|----------|-----------|
| **Q1: Live root computation** | Recompute inline at each alloc site | Same logic as `eco.safepoint` lowering; avoids threading new attributes through EcoGCPrepare. Refactor to shared helper later. |
| **Q2: Coalesced groups** | Per-op statepoints | Group coalescing is orthogonal to correctness. One slow alloc → one marker → one statepoint. Add grouping later with dedicated tests. |
| **Q3: `eco_alloc_string_literal`** | Skip fast/slow for now | Literals typically use `allocatePermanent` at startup; treat as "no GC here". Revisit only if crashes trace to string-literal allocation. |
| **Q4: `eco_allocate` (generic)** | Yes, add fast/slow | Underlying `Allocator::allocateFast/Slow` exist. Expose as `eco_allocate_fast/slow` C wrappers if not already present. |
| **Q5: `removeDeadGCRelocates` in JIT** | Yes, safe to add | Pass only removes dead `gc.relocate` + `ptrtoint` pairs. Run in JIT/test paths before codegen. Ensure `convertSafepointMarkers` runs before optimizations, `removeDeadGCRelocates` runs after. |
| **Q6: Compilation time** | Accept; no flag | 3 blocks per alloc is linear in alloc count. Not the dominant cost. If it regresses, coalesce later or skip boxing ops. |
| **Q7: PHI merging** | Verified by design; add test | Canonical fast/slow pattern produces well-formed SSA. StatepointConversion Phase 2 (alloca+mem2reg) handles this. Add dedicated multi-alloc test to confirm. |
| **Q8: Boxing ops** | Yes, include in fast/slow | Correctness and uniformity trump micro-optimization. Fast path is just a bump-pointer + null check. Slow path only entered on nursery exhaustion. Optimize later if profiling shows overhead. |

## Implementation Steps

### Step 1: Declare fast/slow alloc variants in RuntimeExports.h

**File:** `runtime/src/allocator/RuntimeExports.h`

Add `extern "C"` declarations for all fast/slow variants that already exist in `RuntimeExports.cpp`:
- `eco_alloc_cons_fast` / `eco_alloc_cons_slow`
- `eco_alloc_custom_fast` / `eco_alloc_custom_slow`
- `eco_alloc_string_fast` / `eco_alloc_string_slow`
- `eco_alloc_closure_fast` / `eco_alloc_closure_slow`
- `eco_alloc_int_fast` / `eco_alloc_int_slow`
- `eco_alloc_float_fast` / `eco_alloc_float_slow`
- `eco_alloc_char_fast` / `eco_alloc_char_slow`
- `eco_alloc_tuple2_fast` / `eco_alloc_tuple2_slow`
- `eco_alloc_tuple3_fast` / `eco_alloc_tuple3_slow`
- `eco_alloc_record_fast` / `eco_alloc_record_slow`
- `eco_allocate_fast` / `eco_allocate_slow` (generic)
- `eco_gc_alloc_region_fast` / `eco_gc_alloc_region_slow`

**NOT included:** `eco_alloc_string_literal` — literals use `allocatePermanent`, no GC.

Verify each is already implemented in `RuntimeExports.cpp`. If any are missing (especially the generic `eco_allocate_fast/slow`), implement them:
- Fast: call `Allocator::allocateFast` (bump-pointer, return 0 on failure)
- Slow: call `Allocator::allocateSlow` (may GC, always succeeds)

### Step 2: Register fast/slow variants in RuntimeSymbols.cpp

**File:** `runtime/src/codegen/RuntimeSymbols.cpp`

Add JIT symbol registrations for all fast and slow variants (both `registerRuntimeSymbols` overloads). Both fast and slow are needed since generated code calls fast directly, and slow is the statepoint target.

### Step 3: Extract `computeLiveEcoValues` into a shared header

**From:** `runtime/src/codegen/Passes/EcoGCPrepare.cpp` (currently `static`)
**To:** A shared header accessible by both `EcoGCPrepare.cpp` and `EcoToLLVMHeap.cpp`

Options:
- Add to `EcoToLLVMInternal.h` (already shared across lowering patterns), or
- Create a small `EcoGCUtils.h` header.

The function `computeLiveEcoValues(Operation *targetOp)` and its helper `isEcoValue(Value)` need to be accessible from the heap lowering patterns.

### Step 4: Rewrite allocation lowering in EcoToLLVMHeap.cpp

**File:** `runtime/src/codegen/Passes/EcoToLLVMHeap.cpp`

For each allocation op pattern (BoxOp, AllocateOp, AllocateCtorOp, AllocateStringOp, ListConstructOp, Tuple2/3ConstructOp, RecordConstructOp, CustomConstructOp):

Replace the current single call to `eco_alloc_*` with the fast+slow split:

1. Call `eco_alloc_*_fast(args)` → returns i64 (0 on failure).
2. Compare result to 0 via `LLVM::ICmpOp(eq)`.
3. Split into three blocks: current (with `CondBr`), slowBlock, contBlock.
4. **Fast path** (current block → contBlock): pass `fastRes` as block arg.
5. **Slow path** (slowBlock):
   a. Recompute live `!eco.value` roots inline via `computeLiveEcoValues(originalEcoAllocOp)`.
   b. Convert roots to `ptr addrspace(1)` via `inttoptr` (same as safepoint lowering in `EcoToLLVMErrorDebug.cpp`).
   c. Emit `call @__eco_safepoint_marker(roots...)`.
   d. Emit `call @eco_alloc_*_slow(args)` → returns i64.
   e. `Br` to contBlock with slow result.
6. contBlock takes one block argument (i64): the allocated object. All subsequent uses of the allocation result use this argument.

**Per-op, not per-group:** Each allocation op gets its own fast/slow split independently. Ignore `eco.gc_group_member` attributes for now — they remain as metadata for future coalescing.

**Key invariant:** In the slow path, `__eco_safepoint_marker` and `eco_alloc_*_slow` are adjacent with no intervening instructions, so `StatepointConversion` can pair them.

### Step 5: Update StatepointConversion Phase 1

**File:** `runtime/src/codegen/Passes/StatepointConversion.cpp`

Phase 1 currently finds `__eco_safepoint_marker` calls and expects the next instruction to be a call to `__eco_safepoint_poll`. Generalize:

- After finding a `__eco_safepoint_marker` call, find the next non-debug `CallInst`.
- Accept the target if it is any of:
  - `__eco_safepoint_poll` (existing poll safepoint)
  - Any function matching `eco_alloc_*_slow` (allocation slow paths)
  - `eco_gc_alloc_region_slow`
- Build `gc.statepoint` wrapping the target call:
  - Target = callee function
  - Call arguments = original call args
  - `gc-live` bundle = marker operands (live roots)
- **If target returns a value** (allocation slow paths return i64 or ptr):
  - Emit `gc.result` to capture the return value
  - Replace all uses of the original call result with the `gc.result`
- **If target is void** (`__eco_safepoint_poll`): existing behavior, no `gc.result`.
- Erase marker call and original target call.
- Record `SafepointInfo` for Phase 2 as before.

**Phase 2:** No changes expected — it operates generically on the gc-live bundle regardless of target. Verify it handles non-void statepoint targets correctly (the `gc.result` value should not be treated as a GC root).

### Step 6: Add `removeDeadGCRelocates` to JIT and test paths

**Files:**
- `ecoc.cpp` (JIT transformer, ~line 238)
- `runtime/src/codegen/EcoRunner.cpp` (test runner transformer, ~line 186)

In both transformer hooks, add `eco::removeDeadGCRelocates(*m)` **after** any LLVM optimization passes but **before** codegen. The ordering in each transformer should be:

```
convertSafepointMarkers(*m)   // markers → gc.statepoint
[LLVM optimizations]           // may create dead gc.relocate via inlining/DCE
removeDeadGCRelocates(*m)      // clean up dead gc.relocate before SelectionDAG
```

### Step 7: Add IR inspection tests

**Directory:** `test/codegen/`

1. **`safepoint_alloc_statepoint.mlir`**: Single allocation op with live roots.
   - CHECK: `eco_alloc_*_fast` call, `icmp eq ... 0`, `br`, slow block with `__eco_safepoint_marker` + `eco_alloc_*_slow`.
   - CHECK (after statepoint conversion): `gc.statepoint` wrapping the slow call, `gc.result` for allocation result.

2. **`safepoint_alloc_live_roots.mlir`**: Allocation with multiple live `!eco.value` values.
   - CHECK: All live roots appear in the `gc-live` bundle.
   - CHECK: `gc.relocate` emitted for each root after the statepoint.

3. **`safepoint_alloc_relocate.mlir`**: Relocated values used after allocation.
   - CHECK: Uses of pre-allocation roots are replaced with relocated versions post-statepoint.

4. **`safepoint_alloc_multi_sequential.mlir`**: Multiple sequential allocations in one block.
   - CHECK: Each produces its own fast/slow split.
   - CHECK: No invalid PHIs or dangling gc.relocate after full pipeline.
   - CHECK: Second allocation's live roots include the first allocation's result (now a block arg from the first fast/slow merge).

### Step 8: Add GC stress E2E test

**Directory:** `test/` (E2E)

Add or modify a test that:
- Uses a small nursery (low threshold) to force frequent minor GCs from allocation slow paths.
- Executes allocation-heavy Elm code compiled through the full MLIR pipeline.
- Verifies correctness (no crashes, correct output).
- Optionally enable GC debug logging to confirm `collectStackRootsFromStackMap()` fires from both poll and allocation entry points.

## File Change Summary

| File | Change | Complexity |
|------|--------|------------|
| `runtime/src/allocator/RuntimeExports.h` | Add `extern "C"` declarations for fast/slow alloc variants | Low |
| `runtime/src/allocator/RuntimeExports.cpp` | Add any missing fast/slow implementations (verify generic `eco_allocate_fast/slow`) | Low |
| `runtime/src/codegen/RuntimeSymbols.cpp` | Register fast/slow alloc symbols for JIT | Low |
| `runtime/src/codegen/Passes/EcoGCPrepare.cpp` | Extract `computeLiveEcoValues` + `isEcoValue` to shared header | Low |
| `runtime/src/codegen/Passes/EcoToLLVMInternal.h` (or new `EcoGCUtils.h`) | Shared `computeLiveEcoValues` declaration | Low |
| `runtime/src/codegen/Passes/EcoToLLVMHeap.cpp` | **Core change:** Rewrite all allocation lowerings to fast+slow+marker pattern | **High** |
| `runtime/src/codegen/Passes/StatepointConversion.cpp` | Generalize Phase 1 to accept allocation slow paths as statepoint targets; handle non-void gc.result | Medium |
| `ecoc.cpp` | Add `removeDeadGCRelocates` to JIT transformer | Low |
| `runtime/src/codegen/EcoRunner.cpp` | Add `removeDeadGCRelocates` to test transformer | Low |
| `test/codegen/safepoint_alloc_*.mlir` | 4 new IR inspection tests | Medium |
| `test/` (E2E) | GC stress test with small nursery | Medium |

**No changes needed:**
- `runtime/src/codegen/Passes/EcoToLLVMErrorDebug.cpp` — safepoint poll lowering already correct
- `runtime/src/allocator/Allocator.hpp/.cpp` — already implemented
- `runtime/src/allocator/ThreadLocalHeap.hpp/.cpp` — already implemented
- `runtime/src/codegen/Passes/EcoToLLVMInternal.h` (fast/slow getOrCreate*) — already declared

## Risk Areas

1. **EcoToLLVMHeap.cpp rewrite (Step 4)** is the highest-risk change. Each allocation pattern needs careful block splitting, PHI threading, and root computation. Errors here produce miscompiles or crashes at GC time.

2. **StatepointConversion non-void targets (Step 5)** — Phase 1 may have implicit assumptions that the target is void (`__eco_safepoint_poll`). Need to audit `gc.result` handling carefully.

3. **Live root accuracy** — if `computeLiveEcoValues` misses a root at an allocation site, GC will not relocate that root's pointer, leading to use-after-move bugs. The existing function is battle-tested for `eco.safepoint` ops but needs verification in the allocation lowering context (which runs at a different point in the pipeline).

## Implementation Order

Recommended order to minimize risk and enable incremental testing:

1. Steps 1-2 (header + symbols) — pure additive, no behavior change
2. Step 3 (extract shared helper) — refactor only, no behavior change
3. Step 5 (StatepointConversion) — generalize to accept allocation targets, test with existing safepoint tests to verify no regression
4. Step 6 (`removeDeadGCRelocates` in JIT) — small wiring change
5. Step 4 (allocation lowering rewrite) — the big change, now with all infrastructure in place
6. Steps 7-8 (tests) — validate everything end-to-end
