# Allocation-Group Single-Safepoint Lowering

## Goal

Make the "group of adjacent allocations" concept real at the LLVM lowering level:

- one GC decision per group,
- at most one safepoint (the group leader's slow path) for the whole group,
- all non-leader group members are fast-path-only (no GC, no runtime call that can GC),
- `EcoGCLivenessAudit` can safely skip `eco.gc_group_member = true` ops.

## Current state (from the structural survey)

- **`EcoGCPrepare.cpp`** already marks groups:
  - Leader: `eco.gc_group_size` (int), `eco.gc_roots_count` (int), roots via `GCRootCarrier` interface (lines 184–191).
  - Members: `eco.gc_group_member = true` (lines 194–197).
  - Groups are adjacent `isMayAllocOp` ops inside a block with no `isGroupBarrier` between them (calls, terminators, `eco.safepoint`, `papCreate`/`papExtend`).
  - Supported alloc ops: `AllocateCtorOp`, `AllocateStringOp`, `AllocateClosureOp`, `ListConstructOp`, `Tuple2/3ConstructOp`, `RecordConstructOp`, `CustomConstructOp`, `BoxOp`, `AllocateOp`.
- **`EcoToLLVMHeap.cpp`** has:
  - `isCoalescedGroupMember(op)` (line 37) — skip hook, but there's no corresponding group-aware leader lowering today, so it's effectively a no-op in practice.
  - `computeAllocSize(op)` (lines 43–74) — static size for most kinds; returns 0 for `AllocateClosureOp`, `AllocateOp`, and non-scalar `BoxOp` inputs.
- **`EcoToLLVMRuntime.cpp::emitAllocWithSafepoint`** (line 549) emits `__eco_safepoint_marker(roots...)` + a unified `eco_alloc_*` call; no IR-level fast/slow split (the runtime splits internally).
- **Runtime already exposes the primitives we need** (`RuntimeExports.h`, `ThreadLocalHeap.cpp`):
  - `eco_alloc_*_fast/slow` per-kind (lines 138–162).
  - `eco_gc_alloc_region_fast(size_t total) -> void*` / `eco_gc_alloc_region_slow(size_t total) -> void*` (lines 168–169).
  - `ThreadLocalHeap::allocateRegionSlow` (line 131) reserves a contiguous nursery range and returns its base; routes to old gen above `config_->large_object_threshold`.
- **`EcoGCLivenessAudit.cpp`** iterates `GCRootCarrier` ops (line 52), skips nested regions (line 61); no group-member skip today.

## Resolved design decisions

1. **Implementation architecture (Q1, Q8)**: use an **imperative group-lowering helper invoked at the start of `EcoToLLVMHeap`**, *not* a `RewritePattern`. The helper runs once per function before the conversion patterns are applied, walks each block, and rewrites each group in-place into an LLVM-level fast/slow/merge CFG. All group member ops are erased by the helper. Remaining non-grouped allocs are lowered by the existing per-op patterns. This avoids the brittleness of erasing sibling ops mid-`matchAndRewrite` and avoids the overhead of designing a new `eco.alloc_group` op. CFG surgery inside nested regions (`scf.while` / `scf.if` bodies) is fine as long as new blocks stay inside the leader's parent region; explicit tests cover both.
2. **Large-object threshold (Q2)**: cap groups *during formation* in `EcoGCPrepare` — if adding the next op would push `sum(size_i) >= config_->large_object_threshold`, close the current group and start a fresh one. Coalescing must never push a small-alloc pile into old-gen.
3. **Runtime entrypoints (Q3)**: reuse `eco_gc_alloc_region_{fast,slow}(total) -> void*`. No new `eco_reserve_group`.
4. **V1 scope (Q4)**: group only primitive boxes and fixed-size tuples/records/customs/strings/lists. Exclude `AllocateClosureOp` and `AllocateOp` from grouping — they stay on the per-op path. Extending later is optional.
5. **Fast-path form (Q5)**: call form — `eco_gc_alloc_region_fast` with a null check — not inlined nursery bump. Inline later if profiling warrants.
6. **Audit (Q6)**: entirely skip ops with `eco.gc_group_member = true` in `EcoGCLivenessAudit`. Member liveness is covered transitively by the leader's root set.
7. **StatepointConversion (Q7)**: emit the slow path as *exactly*
   ```llvm
   call @__eco_safepoint_marker(...roots...)
   %base = call @eco_gc_alloc_region_slow(totalBytes)
   ```
   so the existing "wrap the next call" contract picks up `eco_gc_alloc_region_slow` with no changes. Verify there's no intervening IR between the marker call and the region-slow call.
8. **Singleton groups (Q9)**: treat missing `eco.gc_group_size` as 1. The group lowering branches on `size > 1`; singletons fall through to the existing single-op path. Keep the attribute on singletons if EcoGCPrepare already emits it.

## Plan

### Step 1 — EcoGCPrepare: tighten grouping

**File:** `runtime/src/codegen/Passes/EcoGCPrepare.cpp`

1. Add `hasFixedAllocSize(op)` — returns true exactly for the ops handled by `computeAllocSize` in EcoToLLVMHeap (BoxOp of scalar input, AllocateCtorOp, AllocateStringOp, ListConstructOp, Tuple2/3ConstructOp, RecordConstructOp, CustomConstructOp). Returns false for `AllocateClosureOp`, `AllocateOp`, and non-scalar `BoxOp`.
2. In `processBlock` (line 131), when accumulating `currentGroup`:
   - If the next `isMayAllocOp` fails `hasFixedAllocSize` — close the current group first, then add the unfit op as a singleton (or simply not push it into a group).
   - If adding the next op would make `runningSum + size(next) >= large_object_threshold` — close the current group first, then start a new group with the next op. (Threshold read from config; if the compiler has no direct access to the runtime constant, plumb it as a CLI flag / pass option that defaults to the runtime value.)
3. Emit `eco.alloc_size_bytes : i64` on every grouped op (leader + members) using the same sizes the gate in (2) used. Optional for singletons but recommended for uniformity.
4. Keep emitting `eco.gc_group_size` on every group leader — including singletons with value 1 — so downstream consumers can rely on the attribute's presence.

### Step 2 — Factor object construction out of the alloc call

**Files:** `EcoToLLVMHeap.cpp`, `EcoToLLVMRuntime.cpp`, `EcoToLLVMInternal.h`

Split the per-op lowering into:

- `getFixedAllocSizeBytes(op) -> int64_t` — the existing `computeAllocSize` renamed; prefer reading `eco.alloc_size_bytes` when present.
- `emitInitObjectAtPtr(op, basePtrI64, rewriter, runtime) -> Value` — given a pre-allocated HPointer-encoded `basePtrI64`, write header + unboxed bitmap + fields for this op kind, and return the resulting HPointer i64. One helper body per op kind, dispatching on the op.

Keep `emitAllocWithSafepoint` as a wrapper that uses the new helpers for single-op cases — non-grouped lowering still goes through one code path.

### Step 3 — Group lowering helper inside EcoToLLVMHeap

**File:** `runtime/src/codegen/Passes/EcoToLLVMHeap.cpp`

At the top of the conversion pass (before `applyPartialConversion` runs patterns), add:

```cpp
void lowerAllocGroupsInFunction(func::FuncOp func, EcoTypeConverter &tc,
                                const EcoRuntime &runtime);
```

For each block of each function (including blocks nested in `scf.while` / `scf.if` bodies — walk with `func.walk([&](Block *b){...})`):

1. Iterate ops; when hitting an op with `eco.gc_group_size > 1` and no `eco.gc_group_member`, collect the next `groupSize` ops as members. Debug-assert each has `eco.gc_group_member = true` and a known `eco.alloc_size_bytes`.
2. Compute `totalBytes = sum(member.eco.alloc_size_bytes)` and `offset_i` prefix sums.
3. **CFG rewrite** (all new blocks live in the leader's parent region):
   - Split the current block just before the leader into `entry` / `after`.
   - In `entry`, append:
     ```
     %base_fast = call i64 @eco_gc_alloc_region_fast(i64 totalBytes)
     %is_null   = icmp eq i64 %base_fast, 0
     cond_br %is_null, ^slow, ^fast(%base_fast)
     ```
   - `^fast(%bf: i64)`: for each member i, compute `obj_i = add %bf, offset_i`, call `emitInitObjectAtPtr(member_i, obj_i)` → `hptr_i_fast`. Branch `br ^merge(hptr_0_fast, ..., hptr_N-1_fast)`.
   - `^slow`: emit `call @__eco_safepoint_marker(roots...)` (using the leader's `GCRootCarrier` root set, converted to addrspace(1) pointers per existing `emitAllocWithSafepoint`), then `%base_slow = call i64 @eco_gc_alloc_region_slow(i64 totalBytes)`. **No IR between these two calls.** Under `ECO_GC_DEBUG`, assert `%base_slow != 0`. Same per-member init → `hptr_i_slow`. Branch `br ^merge(hptr_0_slow, ..., hptr_N-1_slow)`.
   - `^merge(hptr_0, ..., hptr_N-1: i64)` followed by the original `after` suffix.
4. Replace each member op's `!eco.value` result with the corresponding merge block arg, then erase all `groupSize` group ops.
5. After lowering all groups in the function, the remaining (singleton / excluded) alloc ops are lowered by the existing per-op conversion patterns.

**Note on `!eco.value` vs i64:** the member ops produce `!eco.value` results; after the helper runs and before patterns execute, those uses must be type-compatible with the new i64 merge-block args. Either (a) run the helper after an initial type-conversion pass has mapped `!eco.value` → i64, or (b) have the helper keep the merge args as `!eco.value` and let the type converter lower them. Choose whichever matches the existing pass ordering — investigate during implementation. If neither is clean, insert an `eco.unrealized_conversion_cast` at the merge block as a temporary bridge, which the subsequent conversion will drop.

### Step 4 — GC liveness audit: skip members

**File:** `runtime/src/codegen/Passes/EcoGCLivenessAudit.cpp`

After line 53 (carrier check) and line 61 (nested-region skip), add:

```cpp
if (op->hasAttr("eco.gc_group_member")) return;
```

with a comment explaining the invariant from Step 3: group members have no safepoint because the slow path is emitted only at the leader, and no member's SSA result is live at that leader-slow statepoint (the region is reserved before any member init runs).

### Step 5 — ECO_GC_DEBUG assertions

- **Slow-path null check** in the emitted LLVM IR: assert `%base_slow != 0` after `eco_gc_alloc_region_slow`.
- **Lowering guard**: in `EcoToLLVMHeap`, assert that no op with `eco.gc_group_member = true` ever reaches `emitAllocWithSafepoint`, `__eco_safepoint_marker`, or any `*_slow` runtime call.
- **StatepointConversion guard**: after the lowering, verify there's no IR between the marker call and `eco_gc_alloc_region_slow` in the slow block — a simple walk in debug builds suffices.

### Step 6 — Tests

1. **MLIR FileCheck tests under `test/codegen/`:**
   - `alloc_group_single_safepoint.mlir`: function with N adjacent `eco.box` / `eco.allocate_ctor` ops. After `--eco-to-llvm`, assert:
     - exactly one `__eco_safepoint_marker` call per group,
     - exactly one `eco_gc_alloc_region_fast` and one `eco_gc_alloc_region_slow` call per group,
     - no `eco_alloc_*_slow` calls in member init blocks,
     - one conditional branch on the fast-path null check,
     - a merge block with N block args (one per member),
     - marker call immediately followed by `eco_gc_alloc_region_slow` in the slow block (StatepointConversion invariant).
   - `alloc_group_inside_scf_while.mlir`: grouped alloc in a loop body — fast/slow/merge blocks correctly placed in the region.
   - `alloc_group_inside_scf_if.mlir`: grouped alloc inside an `scf.if` branch.
   - `alloc_group_large_object_threshold.mlir`: enough fixed-size allocs adjacent to cross the large-object threshold — assert `EcoGCPrepare` splits them into separate groups (no single group's `totalBytes >= threshold`).
   - `alloc_group_singleton.mlir`: single `eco.box` — falls through to the existing single-op path; no fast/slow split emitted.
   - `alloc_group_closure_excluded.mlir`: `eco.allocateClosure` adjacent to `eco.box` — they do not form a group together (closure excluded in v1).
2. **Allocator gtest under `test/allocator/`:** deliberately near-full nursery; `allocateRegionSlow(total)` returns non-null base with ≥ `total` contiguous free bytes, or goes to old gen above threshold.
3. **Audit test:** module where a value is live across a group and present in the *member's* root set but missing from the *leader's* — audit must flag the leader and NOT flag the member. Conversely, a member with a missing root but value also covered at the leader must not be flagged.
4. **Full E2E:** re-run the full-build test suite; the 23 previously failing audit files should be clean.

### Step 7 — Rollout

- Land Steps 1–5 keeping the existing `emitAllocWithSafepoint` path unchanged. Group lowering short-circuits before it.
- Gate new debug asserts behind `ECO_GC_DEBUG`.
- Remove nothing until the full E2E is green.

## Files touched (expected)

- `runtime/src/codegen/Passes/EcoGCPrepare.cpp` — Step 1.
- `runtime/src/codegen/Passes/EcoToLLVMHeap.cpp` — Steps 2, 3, 5.
- `runtime/src/codegen/Passes/EcoToLLVMRuntime.cpp` — Step 2 (split of `emitAllocWithSafepoint`).
- `runtime/src/codegen/Passes/EcoToLLVMInternal.h` — new helper declarations.
- `runtime/src/codegen/Passes/EcoGCLivenessAudit.cpp` — Step 4.
- `runtime/src/allocator/ThreadLocalHeap.cpp` — optional ECO_GC_DEBUG post-condition assert on `allocateRegionSlow`.
- `test/codegen/alloc_group_*.mlir` — new (six files listed above).
- `test/allocator/ThreadLocalHeapTest.cpp` (or equivalent) — new case.

## Invariants to add to `design_docs/invariants.csv`

- **HEAP_GROUP_SINGLE_SP:** A group (`eco.gc_group_size > 1`) has at most one safepoint — the leader's slow-path `gc.statepoint` wrapping `eco_gc_alloc_region_slow`. Group members never emit a safepoint or a GC-triggering runtime call.
- **HEAP_GROUP_FIXED_SIZE:** Every op in an alloc group has a statically known size, attached as `eco.alloc_size_bytes`.
- **HEAP_GROUP_NURSERY_ONLY:** A group's combined size is strictly less than `large_object_threshold`; coalescing never changes the space (nursery vs old-gen) an object would otherwise land in.
- **HEAP_GROUP_NO_MEMBER_LIVE_AT_SP:** No group member's SSA result is live at the leader's slow-path statepoint, because the region is reserved before any member init runs.
- **HEAP_GROUP_SLOW_MARKER_ADJACENCY:** In the slow block, `__eco_safepoint_marker` is immediately followed by `eco_gc_alloc_region_slow` with no intervening IR. StatepointConversion relies on this.

## Implementation notes / things to verify during coding

- **Threshold plumbing.** `config_->large_object_threshold` is a runtime value. EcoGCPrepare needs it at compile time: either plumb as a pass option with a documented default matching the runtime default, or expose the constant in a header the compiler also reads.
- **`!eco.value` ↔ i64 at merge block args.** Resolve during implementation — see Step 3 "Note on `!eco.value` vs i64".
- **Slow-call keeping.** StatepointConversion's "wrap the next call" walk must not be fooled by anything the debug-only null assert inserts. Either skip that assert in release builds (preferred) or place it *after* StatepointConversion runs.
- **Nested-region liveness.** `EcoGCPrepare` already walks nested blocks, so groups can form inside loops. The liveness union workaround for nested regions (EcoGCPrepare.cpp lines 201–) continues to apply — no new work required.
- **Pass ordering.** `lowerAllocGroupsInFunction` must run before the per-op conversion patterns but within the same pass, so the type converter's context is shared.
