# Plan: Fast/Slow Allocation Paths + Allocation Coalescing + Systematic Safepoints

## Summary

Refactor allocation to split into a GC-free bump-pointer fast path and a statepoint-backed slow path.
Add an EcoGCPrepare pass to group adjacent allocations and compute minimal root sets.
Lower grouped allocations as a single bump check (fast) or a single statepoint call (slow).

---

## Phase 1: Runtime Fast/Slow Split

### Step 1.1: Ensure NurserySpace::allocate is pure bump-pointer

**File:** `runtime/src/allocator/NurserySpace.cpp`

Verify (and if needed refactor) that `NurserySpace::allocate(size_t)`:
- Only does: align, check `alloc_ptr_ + size <= alloc_end_`, bump or return nullptr.
- Never triggers GC, never acquires new blocks, no side effects on failure.

### Step 1.2: Add fast/slow/region methods to ThreadLocalHeap

**File:** `runtime/src/allocator/ThreadLocalHeap.hpp` / `.cpp`

Add:
```cpp
void* allocateFast(size_t size);           // bump only, returns nullptr on failure
void* allocateSlow(size_t size, Tag tag);  // may GC, always succeeds or throws
void* allocateRegionSlow(size_t total);    // may GC, allocates contiguous region
```

Refactor existing `allocate(size_t, Tag)` to call `allocateFast` then fallback to `allocateSlow`.

### Step 1.3: Expose through Allocator

**File:** `runtime/src/allocator/Allocator.hpp` / `.cpp`

Thin wrappers delegating to `getThreadHeap()->allocate{Fast,Slow,RegionSlow}(...)`.

### Step 1.4: Add C ABI entry points

**File:** `runtime/src/allocator/RuntimeExports.cpp`

```c
extern "C" uint64_t eco_alloc_custom_fast(uint32_t ctor_id, uint32_t field_count, uint32_t scalar_bytes);
extern "C" uint64_t eco_alloc_custom_slow(uint32_t ctor_id, uint32_t field_count, uint32_t scalar_bytes);
extern "C" void*    eco_gc_alloc_region_fast(size_t total);
extern "C" void*    eco_gc_alloc_region_slow(size_t total);
// ... similar _fast/_slow variants for cons, string, closure, etc.
```

Fast variants return 0/nullptr on failure (no GC). Slow variants may GC.

### Step 1.5: Tests for runtime allocation split

- `allocateFast` succeeds when space available, returns nullptr when nursery full.
- `allocateSlow` triggers minorGC and succeeds.
- `allocateRegionSlow` allocates contiguous region after GC.

---

## Phase 2: Per-Op Fast/Slow Lowering (Option B)

### Step 2.1: Declare fast/slow runtime functions in EcoToLLVMRuntime.cpp

**File:** `runtime/src/codegen/Passes/EcoToLLVMRuntime.cpp`

Add `getOrCreateAlloc*Fast()` and `getOrCreateAlloc*Slow()` helpers for each allocation type.

### Step 2.2: Change HeapOpsToLLVMPass to emit fast/slow pattern

**File:** `runtime/src/codegen/Passes/EcoToLLVMHeap.cpp`

For each allocation op lowering (allocate_ctor, allocate_string, allocate_closure, construct.list):

1. Emit call to `*_fast` variant → check result == 0.
2. Branch: if non-zero → fast block (use result directly), else → slow block.
3. In slow block: compute live `!eco.value` roots (see 2.2a), emit `__eco_safepoint_marker` with those roots + call to `*_slow` variant.
4. Join with phi.

### Step 2.2a: Inline liveness computation for root sets

**CRITICAL (per D10):** Root sets must be complete — there is no conservative fallback in the runtime. Implement a local backward liveness scan within HeapOpsToLLVMPass:

- At each allocation op, walk backward in the current block collecting all `!eco.value` SSA values that have uses after the allocation point.
- Include block arguments of type `!eco.value` (they flow from predecessors).
- Include values defined in dominating blocks that are live across this point.
- This produces a conservative-but-complete root set. EcoGCPrepare (Phase 3) later refines to minimal sets.

### Step 2.3: Update SafepointOpLowering for allocation slow paths

**File:** `runtime/src/codegen/Passes/EcoToLLVMErrorDebug.cpp`

The existing `SafepointOpLowering` handles explicit `eco.safepoint` ops. The new allocation slow paths generate their own marker calls directly in `EcoToLLVMHeap.cpp`. No change needed to explicit safepoint lowering — it continues to work as-is.

### Step 2.4: StatepointConversion compatibility

**File:** `runtime/src/codegen/Passes/StatepointConversion.cpp`

Current `convertSafepointMarkers` finds `__eco_safepoint_marker` calls and converts the *following* call into a `gc.statepoint`. The new pattern emits:
```
call @__eco_safepoint_marker(... roots ...)
%result = call @eco_alloc_custom_slow(...)
```

Verify that `findTargetCall()` correctly picks up the slow alloc call. May need minor adjustment if the marker and target call are in different basic blocks (they shouldn't be — both in the slow block).

### Step 2.5: E2E tests

Run `cmake --build build --target full` and verify no regressions.
Add MLIR FileCheck tests for the new IR pattern (fast/slow branching).

---

## Phase 3: EcoGCPrepare Pass (Option C — Precise Root Sets)

### Step 3.1: Declare pass

**File:** `runtime/src/codegen/Passes.h`

```cpp
std::unique_ptr<mlir::Pass> createEcoGCPreparePass();
```

### Step 3.2: Implement EcoGCPrepare

**New file:** `runtime/src/codegen/Passes/EcoGCPrepare.cpp`

Algorithm:
1. Walk each `func.func` block-by-block.
2. Identify may-allocate ops: `eco.allocate_ctor`, `eco.allocate_string`, `eco.allocate_closure`, `eco.construct.list`, `eco.papCreate`, `eco.papExtend`.
3. Group adjacent may-allocate ops (stop at calls, terminators, explicit safepoints).
4. For each group, compute backward liveness of `!eco.value` SSA values at group entry.
5. Attach `eco.gc_roots = [...]` attribute on first op, `eco.gc_group_size = N` attribute.
6. Mark subsequent ops with `eco.gc_group_member = true`.

### Step 3.3: Wire into pass pipeline

**File:** `runtime/src/codegen/EcoToLLVM.cpp` (or wherever the pipeline is assembled)

Insert `createEcoGCPreparePass()` before `createHeapOpsToLLVMPass()`.

### Step 3.4: Switch HeapOpsToLLVMPass to use precomputed roots

**File:** `runtime/src/codegen/Passes/EcoToLLVMHeap.cpp`

When lowering an alloc op, check for `eco.gc_roots` attribute. If present, use those values (the minimal set from EcoGCPrepare) as arguments to `__eco_safepoint_marker` in the slow block, **replacing** the inline liveness computation from Step 2.2a. If not present (e.g., pass didn't run), fall back to the inline liveness scan.

### Step 3.4a: Rewrite explicit eco.safepoint operands

**File:** `runtime/src/codegen/Passes/EcoGCPrepare.cpp`

For each `eco.safepoint` op, recompute live `!eco.value` values via liveness analysis and replace the op's operand list with the computed set (per D9).

### Step 3.5: Tests

- Unit tests for liveness computation (hand-crafted MLIR modules).
- Verify root sets are minimal (no dead values included).

---

## Phase 4: Allocation Coalescing

### Step 4.1: Extend HeapOpsToLLVMPass for group lowering

**File:** `runtime/src/codegen/Passes/EcoToLLVMHeap.cpp`

When lowering an op with `eco.gc_group_size > 1`:
1. Compute total size across all ops in the group.
2. Emit one `eco_gc_alloc_region_fast(total)` → null check.
3. Fast block: GEP to slice region into per-object pointers, initialize each.
4. Slow block: one `__eco_safepoint_marker` + `eco_gc_alloc_region_slow(total)` → slice + initialize.
5. Phi-join per-object results.

For subsequent ops in the group (`eco.gc_group_member = true`): skip lowering — their results come from the first op's phi nodes. Track via a side map in the pass.

### Step 4.2: Handle non-constant sizes

Some allocations have dynamic sizes (e.g., `eco.allocate_string` with runtime length). For groups containing dynamic sizes:
- Emit `add` chain to compute total.
- Each sub-pointer offset is the running sum of prior sizes.

### Step 4.3: Tests

- FileCheck tests for coalesced IR output.
- E2E tests with high GC pressure to validate correctness.
- Benchmark: measure allocation throughput improvement.

---

## Phase 5: Hardening & Optimization

### Step 5.1: Profile-guided coalescing thresholds

Add heuristics: don't coalesce groups that would request > N bytes (e.g., 4KB) to avoid wasting nursery space on failed fast paths that then GC unnecessarily.

### Step 5.2: `no_alloc` attribute for relaxing barriers

Add a `no_alloc` trait/attribute to Eco functions proven not to allocate (e.g., arithmetic kernels). EcoGCPrepare uses this to allow coalescing across such calls.

### Step 5.3: papCreate/papExtend coalescing

Once basic coalescing is stable, extend to include PAP operations where their initialization can be expressed as region slicing + inline init.

---

## Implementation Order

1. **Phase 1** (runtime split) — can be done independently, no codegen changes.
2. **Phase 2** (per-op fast/slow + inline liveness) — requires Phase 1. Includes local liveness for complete root sets (mandatory per D10). Gets correctness without coalescing.
3. **Phase 3** (EcoGCPrepare) — requires Phase 2 working. Refines root sets to minimal, adds grouping metadata. Also recomputes roots for explicit `eco.safepoint` ops (per D9).
4. **Phase 4** (coalescing) — requires Phase 3. Fuses grouped allocs into single bump+statepoint.
5. **Phase 5** (hardening) — after everything is stable. Adds `no_alloc` traits, PAP coalescing, size thresholds.

---

## Resolved Design Decisions

### D1: NurserySpace block acquisition → slow-path only
`NurserySpace::allocate` is strictly "within-current-from-space bump; return nullptr if no room." Block acquisition and GC triggers live exclusively in `allocateSlow` / `allocateRegionSlow`.

### D2: Header init — split from allocation, inline in IR
For coalescing: runtime helpers provide **raw memory** (`eco_gc_alloc_region_fast/slow`). MLIR lowering does per-object header init inline in generated IR. Small C++ helpers remain available for complex layouts but the basic header writes are inlined.

### D3: Call barriers — start conservative
All calls (`eco.call`, kernel calls, unknown intrinsics) are barriers; no coalescing across them. Future enhancement: add a `no_alloc` attribute/trait and use it to relax barriers for proven non-allocating functions.

### D4: Large allocations — bypass coalescing
Large objects (≥ `large_object_threshold`) route through the existing `allocateLargePinned` path with a dedicated slow-path statepoint. They are never coalesced into nursery regions.

### D5: papCreate/papExtend — standalone fast/slow, no coalescing initially
These get individual fast/slow paths but are NOT coalesced with simpler allocs due to complex initialization (captures, segmentation, ABI). Revisit once basic coalescing is stable.

### D6: StatepointConversion pairing — works as-is
Marker + target call are generated back-to-back in the same slow basic block. `findTargetCall()` finds the first non-intrinsic CallInst after the marker within the same block. No modification needed.

### D7: Pass ordering — EcoGCPrepare runs after all simplifications
Pipeline: high-level Eco passes → EcoPAPSimplify → control-flow lowering → **EcoGCPrepare** → EcoToLLVM lowering. This ensures EcoGCPrepare sees the final allocation structure.

### D8: Thread-local pointers — NOT exposed to IR
Fast paths call C functions (`eco_gc_alloc_region_fast`); those use `Allocator::instance()` and `tl_heap_` internally. No thread-local exposure to generated code. Phase 5's "inline fast path" is **dropped** — the function-call overhead is acceptable and avoids architectural complexity.

### D9: Explicit eco.safepoint roots — recompute via liveness
EcoGCPrepare recomputes live `!eco.value` sets at each `eco.safepoint` using liveness analysis and **replaces** the front-end-supplied operands. Front-end operands serve as documentation/hints only.

### D10: No safety net — precision is mandatory
`collectStackRootsFromStackMap` reads ONLY from `__LLVM_StackMaps` metadata generated by statepoints. If a statepoint's `gc-live` set is incomplete, the missing roots are invisible to the collector and objects can be incorrectly reclaimed. **Root sets must be complete at every statepoint from day one.**

---

## Critical Implication of D10: Phasing Strategy

Because there is no conservative fallback, we cannot ship incomplete root sets. This constrains the rollout:

- **Phase 2 (per-op fast/slow) CANNOT ship with empty root sets.** We must either:
  - (a) Implement EcoGCPrepare (Phase 3) first or concurrently, OR
  - (b) Use a simple conservative approximation: at each slow-path statepoint, include ALL `!eco.value` SSA values that are live at that point (computed via a lightweight backward scan in HeapOpsToLLVMPass itself, without a separate pass).

- **Recommended approach**: implement (b) as a stepping stone — a local liveness computation inline in HeapOpsToLLVMPass that collects all live `!eco.value` values. Then EcoGCPrepare (Phase 3) refines this to minimal sets and adds coalescing metadata.

---

## Assumptions

1. **NurserySpace::allocate is already pure bump-pointer** — no block acquisition or GC, returns nullptr when current block is full.
2. **StatepointConversion is correct and battle-tested** — we rely on it without modification for the new slow-path pattern.
3. **Root set precision is mandatory from the start** — no conservative fallback exists in the runtime. Every statepoint must have a complete gc-live set.
4. **All Elm objects are immutable** — no write barriers needed, which simplifies the fast path considerably.
5. **Single-threaded compilation** — EcoGCPrepare doesn't need to worry about concurrent mutation of IR.
