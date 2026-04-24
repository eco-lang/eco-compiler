# Major GC Trigger & Post-GC Growth Policy

## Goal

Implement a two-part policy for the old generation:

1. **Initiating-occupancy trigger**: initiate a major GC when old-gen committed bytes exceed ~75% of the old-gen cap (`nursery_offset`).
2. **Post-major-GC growth rule**: if live data still occupies >50% of committed old-gen capacity immediately after a major GC finishes, grow committed capacity so that `live / capacity ≤ 50%` (subject to the global old-gen cap).

Defaults: `major_gc_initiating_occupancy = 0.75`, `major_gc_target_utilization = 0.50`. Tunable via `HeapConfig`.

## Current State (verified in tree)

- `runtime/src/allocator/AllocatorCommon.hpp:140` — `HeapConfig` with `promotion_age`, `nursery_gc_threshold`; `validate()` at line 179.
- `runtime/src/allocator/Allocator.hpp`:
  - `nursery_offset` (line 143) = global old-gen cap (start of nursery region).
  - `old_gen_committed` (line 142) = global committed old-gen bytes.
  - `collectAtSafepoint()` (line 106) delegates to `tl_heap_->collectAtSafepoint()` (`Allocator.cpp:206`).
  - `friend class OldGenSpace;` at line 243 → `OldGenSpace` can access private `Allocator` members.
- `runtime/src/allocator/ThreadLocalHeap.cpp`:
  - `collectAtSafepoint()` (line 217) currently calls `minorGC()` **unconditionally** — no major-GC path here today.
  - `majorGC()` (line 227) exists but is only invoked from old-gen allocation slow paths (lines 151, 175).
- `runtime/src/allocator/OldGenSpace`:
  - `finishMarkAndSweep()` at lines 273–277 (header). Its body (`OldGenSpace.cpp:644`) calls `computeFragmentationStats()`, and `onSweepComplete()` (line 753) also calls it. After a full major sweep completes, `frag_stats_.live_bytes` is the authoritative post-GC live set and `allocated_bytes` is reassigned from it (`OldGenSpace.cpp:780`).
  - Per-thread old-gen region is `[region_base_, region_end_)`, carved out by `ThreadLocalHeap` from the shared old-gen half. `blocks_` within that region are individual `BlockInfo` ranges and need not be contiguous or densely packed. `contains()` only checks the region bounds.

## Design Decisions (from user Q&A)

1. **Live-set source**: `frag_stats_.live_bytes` (ensure `computeFragmentationStats()` / `onSweepComplete()` has run before reading).
2. **Capacity accounting**: global cap (`nursery_offset`), first-come-first-served via `thread_mutex_`. No per-thread fair-share yet.
3. **Region contiguity**: each `OldGenSpace` owns a single contiguous reserved range `[region_base_, region_end_)` that's sized at `ThreadLocalHeap` construction (`old_gen_max_size`). Growing committed capacity means bumping `region_end_` *within* that per-thread reserved slice — new `BlockInfo`s fit in the already-reserved address range. Do not change region bounds for other threads.
4. **Knobs**: config-driven only. `major_gc_initiating_occupancy` and `major_gc_target_utilization` live in `HeapConfig`; allocator and `OldGenSpace` read from `config_`. No `static constexpr` duplicates in `OldGenSpace.hpp`.
5. **`collectAtSafepoint` semantics**: threshold-gated minor GC. Replace the current unconditional `minorGC()` with `if (isNurseryNearFull(cfg->nursery_gc_threshold)) minorGC();` followed by `if (parent_->shouldTriggerMajorGC()) majorGC();`.
6. **GCStats telemetry**: distinct counters for occupancy-trigger vs allocation-failure trigger — `major_gc_occupancy_triggers` and `major_gc_alloc_failure_triggers`.

## Code Changes — File by File

### `runtime/src/allocator/AllocatorCommon.hpp`

- In `HeapConfig` (after `nursery_gc_threshold`):
  ```cpp
  float major_gc_initiating_occupancy = 0.75f;
  float major_gc_target_utilization   = 0.50f;
  ```
- In `HeapConfig::validate()` (line 179):
  - `major_gc_initiating_occupancy` and `major_gc_target_utilization` each in `(0.0, 1.0)`.
  - `major_gc_initiating_occupancy > major_gc_target_utilization` (prevents the grow rule from firing below the trigger and creating a grow loop).

### `runtime/src/allocator/GCStats.hpp` / `GCStats.cpp`

- Add two counters to `GCStats`:
  ```cpp
  uint64_t major_gc_occupancy_triggers   = 0;
  uint64_t major_gc_alloc_failure_triggers = 0;
  ```
- Include them in aggregation / reset / `operator+=`.
- No change to timing; these are simple increment counters.

### `runtime/src/allocator/Allocator.hpp`

- Public inline queries:
  ```cpp
  size_t getOldGenMaxBytes() const       { return nursery_offset; }
  size_t getOldGenCommittedBytes() const { return old_gen_committed; }
  bool   shouldTriggerMajorGC() const;   // impl in .cpp
  ```
- Private method declaration:
  ```cpp
  void ensureOldGenCapacityFor(OldGenSpace& space, size_t new_capacity_bytes);
  ```
  `OldGenSpace` is already a friend (line 243), so no new friendship.

### `runtime/src/allocator/Allocator.cpp`

- `shouldTriggerMajorGC()`:
  ```cpp
  if (nursery_offset == 0) return false;
  return static_cast<double>(old_gen_committed) / nursery_offset
         >= config_.major_gc_initiating_occupancy;
  ```
- `ensureOldGenCapacityFor(space, new_capacity_bytes)`:
  - Acquire `thread_mutex_`.
  - `current = space.region_end_ - space.region_base_`; early-return if `new_capacity_bytes <= current`.
  - Clamp so we never exceed the reserved slice this thread owns *and* the global cap. Concretely: `space_reservation_limit = space.region_base_ + space.max_region_size_` (this is what `ThreadLocalHeap` gave it; check if it's already stored — see Note below); if not stored, clamp only against global `nursery_offset` via `acquireOldGenBlock`'s existing bounds check (line 345 already rejects if `old_gen_committed + size > nursery_offset`).
  - Loop until `space.region_end_ - space.region_base_ >= new_capacity_bytes`:
    - Ask for the next block via the existing `acquireOldGenBlock(block_size)` path (already bumps `old_gen_committed` and reserves address space). Push into `space.blocks_`; advance `space.region_end_` to cover the new tail.
    - Break on failure (e.g. out of global old-gen address space).
- Note: investigate whether `OldGenSpace` already tracks the per-thread reservation upper bound. If not, rely on `acquireOldGenBlock` refusing past `nursery_offset`; add tracking only if needed.

### `runtime/src/allocator/ThreadLocalHeap.cpp`

- Edit `collectAtSafepoint()` (line 217):
  ```cpp
  force_gc_ = false;
  if (isNurseryNearFull(config_->nursery_gc_threshold)) {
      minorGC();
  }
  if (parent_->shouldTriggerMajorGC()) {
      GC_STATS_INC(stats_.major_gc_occupancy_triggers);
      majorGC();
  }
  ```
  (Behaviour change: minor GC is no longer unconditional when `collectAtSafepoint` runs. `shouldCollectAtSafepoint()` already uses `isNurseryNearFull`, so in practice this is just tightening the one-off `force_gc_` case — acceptable per the spec.)
- In the hard-path allocation-failure `majorGC()` callers (`ThreadLocalHeap.cpp:151, 175`), increment `major_gc_alloc_failure_triggers` before the call.

### `runtime/src/allocator/OldGenSpace.hpp`

- Private declaration:
  ```cpp
  void adjustCapacityAfterMajorGC();
  ```
- No new `static constexpr` constants (config-driven, per decision #4).

### `runtime/src/allocator/OldGenSpace.cpp`

- Implement `adjustCapacityAfterMajorGC()`:
  ```cpp
  // Preconditions: called at the end of finishMarkAndSweep after
  // computeFragmentationStats() / onSweepComplete() has run, so
  // frag_stats_ reflects the full post-GC live set.
  if (region_base_ == nullptr || region_end_ <= region_base_) return;

  const size_t capacity = region_end_ - region_base_;
  const size_t live     = frag_stats_.live_bytes;
  if (live == 0 || capacity == 0) return;

  const double occupancy = static_cast<double>(live) / capacity;
  const float grow_threshold = config_->major_gc_initiating_occupancy;
  const float target         = config_->major_gc_target_utilization;

  if (occupancy <= target)          return;  // healthy
  if (occupancy <  grow_threshold)  return;  // moderate, tolerated

  size_t desired = static_cast<size_t>(std::ceil(live / static_cast<double>(target)));
  size_t global_cap = allocator_->getOldGenMaxBytes();
  if (desired > global_cap) desired = global_cap;
  if (desired <= capacity)  return;

  allocator_->ensureOldGenCapacityFor(*this, desired);
  ```
- In both `finishMarkAndSweep` overloads (`#if ENABLE_GC_STATS`), after sweep/fragmentation stats finalize, call `adjustCapacityAfterMajorGC()`. Since lazy sweeping can defer full stats, this call should sit at the latest point where `frag_stats_` is known to be up to date — if that's only `onSweepComplete()`, invoke from there instead. Confirm during implementation.

## Tests (no mocking)

1. **Unit — `HeapConfig::validate()`**: reject out-of-range values; reject `initiating <= target`.
2. **Unit — `shouldTriggerMajorGC`**: with controlled `nursery_offset` and `old_gen_committed` via `AllocatorTestAccess`, assert boundary at configured fraction.
3. **Integration — 75% trigger path**: allocate long-lived objects until old-gen occupancy crosses 75%; hit safepoint; assert `GCStats::major_gc_occupancy_triggers > 0`.
4. **Integration — 50% growth path**: pin live objects so post-GC `live/capacity > 75%`; run major GC; assert `region_end_ - region_base_` grew to roughly `2 × live`, capped at global.
5. **Integration — no-op when healthy**: post-GC occupancy 40%; assert capacity unchanged.
6. **Integration — no-op in hysteresis band**: post-GC occupancy 60% (between target and grow threshold); assert capacity unchanged.
7. **Integration — clamp at cap**: post-GC live very close to `nursery_offset`; assert capacity grows up to cap and no further, no crash.
8. **Integration — alloc-failure telemetry**: force old-gen allocation failure; assert `major_gc_alloc_failure_triggers > 0` and `major_gc_occupancy_triggers` unchanged.
9. **E2E**: `cmake --build build --target full` (stress filter) — confirm no regressions.

## Risks / Non-goals

- The 50%–75% hysteresis band is deliberate (prevents thrashing); workloads whose steady-state live set sits at ~70% will keep their current capacity.
- No old-gen **shrink** policy. Surplus buffer return remains `BUFFER_RETURN_THRESHOLD`'s job.
- Hard-path `majorGC()` from allocation failure is unchanged other than stats increment.
- Growth is best-effort: if the global old-gen cap is already exhausted, `ensureOldGenCapacityFor` silently stops at the cap — caller must not assume the requested capacity was achieved.

## Implementation Order

1. Add `HeapConfig` fields + validation + `GCStats` counters. (Leaf change, no behaviour yet.)
2. Add `Allocator::shouldTriggerMajorGC`, `getOldGenMaxBytes/Committed`, `ensureOldGenCapacityFor`. Unit-test in isolation.
3. Add `OldGenSpace::adjustCapacityAfterMajorGC` and wire into `finishMarkAndSweep` / `onSweepComplete`.
4. Modify `ThreadLocalHeap::collectAtSafepoint` + telemetry at alloc-failure sites.
5. Integration tests 3–8.
6. Full E2E run.
