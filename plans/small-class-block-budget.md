# Small-Class Block Budget for OldGen Allocator

## Goal

Add a "small-class block budget" `Y` (default 128 MiB) to `OldGenSpace`
controlling how the allocator satisfies requests routed to fixed size
classes whose cell size is ≤ a configurable cap (default
`large_object_threshold` = 8 KiB).

While the bytes committed to **uniform** small-class pages are below `Y`:

1. Pop from `free_lists_[cls]` (exact-fit) — no behavior change.
2. If empty, **pull a fresh bag page** via `populateFromBlock(cls)` and
   slice it into uniform cells of `classToSize(cls)`. Do **not** split
   larger free spans down into the class.
3. If the bag is empty (and growth fails), fall through to today's
   policy.

Once `small_class_bytes_ >= Y` (or we're at the old-gen cap), revert to
the existing `tryAllocateFromFreeLists` (pop + split) → sweep-on-demand →
bag → panic-sweep ladder.

This trades a small amount of early committed capacity for less
fragmentation of medium/large free spans into tiny cells.

---

## Step-by-step Plan

### Step 1 — Configuration knobs (`AllocatorCommon.hpp`)

First, add a named default constant in the **Sizing Constants** block,
beside the existing `INITIAL_OLD_GEN_SIZE`:

```cpp
// Default cap on bytes committed to uniform small-class pages before
// the allocator starts splitting larger free cells to satisfy
// fixed-size-class requests. See HeapConfig::small_class_heap_budget_bytes.
constexpr size_t DEFAULT_SMALL_CLASS_HEAP_BUDGET = 1024ULL * 1024 * 1024;  // 1 GiB
```

Then add to `struct HeapConfig`:

```cpp
// Cap on bytes committed to uniform small-class pages before we start
// splitting larger free cells down into those classes. 0 disables.
size_t small_class_heap_budget_bytes = DEFAULT_SMALL_CLASS_HEAP_BUDGET;

// Cell-size cap that defines "small" for budgeting. Defaults to the
// large-object threshold so the heuristic covers all fast-path classes.
size_t small_class_cell_max_bytes = large_object_threshold;
```

Add to `HeapConfig::validate()` in section 6:

- `small_class_heap_budget_bytes <= max_heap_size / 2` (old-gen half).
- `small_class_cell_max_bytes >= MIN_FREE_CELL_SIZE` (must fit a `FreeCell`).
- `small_class_cell_max_bytes <= large_object_threshold` (above LOT bypasses
  fixed classes anyway).

Note: `DEFAULT_MAX_HEAP_SIZE` is 24 GiB → old-gen cap is 12 GiB, so the
1 GiB default comfortably satisfies the validate constraint with the
default `max_heap_size`.

### Step 2 — Bookkeeping state (`OldGenSpace.hpp`)

Add private members:

```cpp
size_t small_class_bytes_;        // sum of totalBytes() of UNIFORM
                                  // (size_class < num_size_classes_)
                                  // small-class pages
size_t small_class_index_limit_;  // exclusive upper bound on "small" cls
```

And helpers (all private):

```cpp
void   recomputeSmallClassLimit();        // from config_
bool   isSmallClassIndex(size_t cls) const;
void   onUniformBlockDedicated(size_t block_index);   // called after
                                                       // populateFromBlock
                                                       // creates a uniform
                                                       // small-class block
void   onBlockReleased(size_t block_index);            // called from any
                                                       // path that drops a
                                                       // block from blocks_
void   onBlockTransitioningToLarge(size_t block_index);// for
                                                       // allocateFromEmpty
                                                       // RegularBlocks
void*  tryPopFromFreeList(size_t cls, size_t requested_size);
bool   shouldPreferBagForSmallClass(size_t cls) const;
```

### Step 3 — Initialization & reset (`OldGenSpace.cpp`)

- Constructor: zero-initialize `small_class_bytes_`,
  `small_class_index_limit_`.
- `OldGenSpace::initialize`: after `num_size_classes_` is set, call
  `recomputeSmallClassLimit()`.
- `OldGenSpace::reset`: clear `small_class_bytes_ = 0;` and call
  `recomputeSmallClassLimit()` after `num_size_classes_` is recomputed.

`recomputeSmallClassLimit` walks `cls 0..num_size_classes_` and sets
`small_class_index_limit_` to the first index whose `classToSize(cls)`
exceeds `config_->small_class_cell_max_bytes` (or to `num_size_classes_`
if all classes fit). When `small_class_heap_budget_bytes == 0` it is set
to 0 (heuristic disabled).

### Step 4 — Accounting hooks

#### Credit on uniform-page dedication (`populateFromBlock`)

`populateFromBlock(cls)` has two paths today:

- **Heap-base detour** (line 899): materializes a **mixed** block
  (`size_class = NUM_SIZE_CLASSES`). **Do NOT credit** — this is not a
  uniform small-class page.
- **Standard path** (line 928 onward): materializes a uniform block with
  `bi.size_class = cls`. **Credit** by calling
  `onUniformBlockDedicated(block_idx)` immediately after the
  `assignPageIndexForBlock(block_idx)` call.

`onUniformBlockDedicated` adds `blocks_[block_idx].totalBytes()` to
`small_class_bytes_` if `isSmallClassIndex(blocks_[block_idx].size_class)`.

#### Debit on release (`releaseBlockToAllocator`)

At the top of `releaseBlockToAllocator(block_index)`, **before** the
`blocks_` swap-remove, call `onBlockReleased(block_index)`. The helper
checks `!is_large && isSmallClassIndex(size_class)` and debits the block's
`totalBytes()` from `small_class_bytes_` (saturating subtract).

#### Debit on uniform → large transition (`allocateFromEmptyRegularBlocks`)

This helper repurposes a fully-free regular page as a large block. If
the page was previously credited (uniform small-class), we need to
debit it **before** we flip `is_large = true`. Add
`onBlockTransitioningToLarge(idx)` at the top of that helper, which is
identical to `onBlockReleased` but does not zero the `size_class`
(release does the swap-remove anyway).

### Step 5 — New allocation helpers

Two helpers, each with a single concern:

```cpp
// Pure free-list manipulation. Pops the head cell of free_lists_[cls]
// and returns it as a raw pointer (or nullptr if the list is empty).
// Does NOT touch the header, padding, allocated_bytes, or stats — the
// caller is responsible for finalising the cell into an object.
FreeCell* tryPopFromFreeList(size_t cls);

// Behaviour-preserving extraction of the existing "turn this cell into
// an object" sequence from the first arm of tryAllocateFromFreeLists:
//   - initObjectHeaderWithSize(cell, classToSize(cls))
//   - padCellSlack(cell, requested_size, classToSize(cls))
//   - allocated_bytes += classToSize(cls)
//   - any GCStats hook recorded by the existing fast path
// Returns the cell as a void*. Used at every call site in
// allocateFromSizeClass that consumes a popped cell, so the existing
// semantics survive bit-for-bit.
void* finalizePoppedCell(FreeCell* cell, size_t cls, size_t requested_size);
```

`tryPopFromFreeList` is intentionally minimal — its **only** job is to
choose the source cell. `finalizePoppedCell` is the existing four-line
finalisation sequence, lifted into a helper so we can reuse it from
the multiple new call sites in `allocateFromSizeClass` without
duplicating logic.

`tryAllocateFromFreeLists` (existing helper) becomes a thin wrapper:

```cpp
void* tryAllocateFromFreeLists(size_t cls, size_t requested_size) {
    if (FreeCell* cell = tryPopFromFreeList(cls)) {
        return finalizePoppedCell(cell, cls, requested_size);
    }
    if (void* p = tryAllocateBySplittingLarger(cls, classToSize(cls))) {
        padCellSlack(p, requested_size, classToSize(cls));
        return p;
    }
    return nullptr;
}
```

This keeps the existing call sites unchanged while the new code uses
the two split helpers directly.

### Step 6 — `shouldPreferBagForSmallClass` predicate

Return `true` iff:

- `isSmallClassIndex(cls)` is true,
- `config_->small_class_heap_budget_bytes != 0`,
- `small_class_bytes_ < config_->small_class_heap_budget_bytes`, and
- `committedToCapRatio() < 1.0` (we're not at the old-gen cap).

We deliberately do **not** check `unassigned_blocks_.empty()` —
`populateFromBlock` already falls through to
`allocator_->acquireOldGenBlock` when the bag is empty, and growing to
satisfy the small-class budget is precisely what this heuristic is for.
If the OS-level grow also fails, `populateFromBlock` returns false and
we drop into the existing fallback ladder.

### Step 7 — Re-order `allocateFromSizeClass`

```cpp
void* OldGenSpace::allocateFromSizeClass(size_t cls, size_t requested_size) {
    assert(cls < num_size_classes_);

    // (1) Exact-fit free list pop. No splitting yet.
    if (FreeCell* cell = tryPopFromFreeList(cls)) {
        return finalizePoppedCell(cell, cls, requested_size);
    }

    // (2) NEW: bag-first for small classes while under budget.
    //     Re-pop after population; the heap-base detour can produce
    //     non-uniform output, in which case the re-pop misses and we
    //     fall through.
    if (shouldPreferBagForSmallClass(cls)) {
        if (populateFromBlock(cls)) {
            if (FreeCell* cell = tryPopFromFreeList(cls)) {
                return finalizePoppedCell(cell, cls, requested_size);
            }
        }
    }

    // (3) Splitting: try larger-cell split.
    if (void* p = tryAllocateBySplittingLarger(cls, classToSize(cls))) {
        padCellSlack(p, requested_size, classToSize(cls));
        return p;
    }

    // (4) Sweep-on-demand (existing logic).
    if (hasPendingSweepWork()) {
        if (void* p = sweepOnDemandAllocate(cls, requested_size)) return p;
    }

    // (5) Bag page — uniform population (used both when budget is
    //     exhausted and when (2) was skipped because the class is
    //     not in the small-class budget range).
    if (populateFromBlock(cls)) {
        if (FreeCell* cell = tryPopFromFreeList(cls)) {
            return finalizePoppedCell(cell, cls, requested_size);
        }
    }

    // (6) Last resort: page-as-single-cell + split.
    if (void* p = allocateFromBagPage(requested_size)) return p;

    // (7) Panic sweep.
    if (void* p = panicSweepAndRetryAllocation(cls, requested_size)) return p;

    return nullptr;
}
```

Notes:

- (1) is what `tryAllocateFromFreeLists`'s first arm does today, just
  spelt with the new two-helper pair so (2) can interpose between
  exact-fit and split.
- (3) is the splitting arm of the same legacy helper.
- `tryAllocateFromFreeLists` itself stays available as a wrapper for
  any other callers (see Step 8).
- Note that the `sweepOnDemandAllocate` path internally calls back into
  `tryAllocateFromFreeLists`; that's intentional. The "no-split while
  under budget" property is enforced at (1)/(2)/(3); paths (4)–(7) run
  only after we've already given the small-class budget its chance.

### Step 8 — Audit other call sites of `tryAllocateFromFreeLists`

Single call site today: `allocateFromSizeClass`. Verify with grep
during implementation. If others exist (`sweepOnDemandAllocate`,
`panicSweepAndRetryAllocation`?), they may stay on the combined helper
since they run *outside* the budget regime and want the historical
"any cell will do" behavior.

### Step 9 — Tests (`test/allocator/`)

New test file (or additions to an existing one) covering:

1. **Budget under cap, fast classes**: configure `Y = 4 * page_size`,
   exhaust per-class free lists, observe that the next ~4 small-class
   allocations each materialize a fresh uniform page and that
   `tryAllocateBySplittingLarger` is **not** called.
2. **Budget exhausted**: continue allocating; observe that allocator
   resumes splitting larger free cells.
3. **Above-cap classes ignored**: with `small_class_cell_max_bytes` set
   below a class's cellSize, that class continues to use the
   pop-then-split fast path immediately.
4. **Heuristic disabled** (`small_class_heap_budget_bytes = 0`):
   behavior matches today's `allocateFromSizeClass`.
5. **Release accounting**: trigger a block release (post-major-GC
   `maybeShrinkCapacity` or `reclaimAllDeadBlocksFromMeta`) and assert
   `small_class_bytes_` decrements.
6. **Heap-base page**: when a small-class request lands on the
   heap-base page detour, `small_class_bytes_` is not credited.

Existing tests to re-run: `cmake --build build --target full` (for
allocator + E2E + stress) and the focused `GCPressureTest`.

### Step 10 — Documentation

Update the file-level comment block in `OldGenSpace.hpp` (lines 47–96)
to mention the new policy: "Below `small_class_heap_budget_bytes`,
small-class allocations prefer fresh pages over splitting."

---

## Resolved Decisions

1. **Heap-base detour is NOT credited.** The heap-base page is a
   *mixed* block (sentinel at offset 0, post-sentinel span pushed via
   `pushSpanOnFreeLists`); crediting it would violate the
   "walk by `classToSize(cls)`" uniformity invariant. Only the
   standard uniform-population path of `populateFromBlock` calls
   `onUniformBlockDedicated`.

2. **Uniform → large transition IS debited.**
   `allocateFromEmptyRegularBlocks` flips a previously-uniform regular
   page to `is_large = true`. We call `onBlockTransitioningToLarge`
   immediately before that flip so the budget no longer counts the
   page. Compaction's `freeEvacuatedBuffers` already goes through
   `releaseBlockToAllocator`, so debiting comes for free; evacuation
   *destinations* are mixed (no `populateFromBlock` call), so no
   spurious credit. We will still confirm with a focused trace during
   implementation that no other in-place `size_class` transitions
   exist.

3. **`tryPopFromFreeList` is purely free-list manipulation** — it
   returns a raw `FreeCell*` and does not touch the header, padding,
   `allocated_bytes`, or stats. The existing finalisation sequence
   (`initObjectHeaderWithSize` → `padCellSlack` →
   `allocated_bytes += cellSize` → any GCStats hook) is lifted into a
   second helper, `finalizePoppedCell`, and reused at every consume
   site. This preserves bit-for-bit parity with the existing fast
   path.

4. **`shouldPreferBagForSmallClass` does NOT short-circuit on bag
   emptiness.** `populateFromBlock` already grows from the OS via
   `acquireOldGenBlock` when the bag is empty, and authorising that
   growth on behalf of small classes is precisely the point of the
   budget. The only growth guard is `committedToCapRatio() < 1.0`
   (plus the budget check itself).

5. **`small_class_cell_max_bytes` default is `large_object_threshold`.**
   The original "8..8 KiB" intent covers small + medium fast-path
   classes, not just the 8..256 B small band. `MAX_SMALL_SIZE` (256 B)
   stays available as a future tuning option if medium-class pages
   turn out to be too "sticky" under the budget.

6. **Y default is `1024 MiB` (1 GiB).** Treated as a tuning parameter
   to be validated empirically (see Calibration section below).

7. **Mutability.** `HeapConfig` is effectively immutable
   post-`initialize`, matching the existing pattern with
   `num_size_classes_`. `recomputeSmallClassLimit` runs only from
   `initialize` / `reset`, not per-allocation.

8. **Budget re-arms after every major GC.** Post-major-GC
   `maybeShrinkCapacity` may release uniform small-class pages,
   debiting `small_class_bytes_`. Net effect: after each major GC the
   budget refills and the bag-first policy resumes — desirable, but
   noted so it's not a surprise.

9. **More frequent / smaller early majors are expected.** Encouraging
   commit growth makes `shouldTriggerMajorGC` (committed/cap-based)
   fire sooner in absolute time during budget fill-up. Functionally
   benign; relevant for stress benchmarking.

10. **Out of scope:** `allocateLargeBlock` (large requests bypass the
    fast path), nursery, ABI, and any invariant in
    `design_docs/invariants.csv`. Pure runtime change.

## Calibration follow-up

Treat the 1 GiB default as a starting point. After landing the
behavior, sweep `Y ∈ {256, 512, 1024, 2048} MiB` against:

- `GCPressureTest` workloads,
- Stage-7 self-compile / stress runs.

Compare across runs:

- Major-GC wall time and sweep time per cycle.
- Mutator fraction (`mutator_s / wall_s`).
- Small vs. large free-list histograms (how much 64 KiB hoard
  accumulates vs. how well small classes are fed).
- `frag_stats_.utilization()` and live/heap distribution.
- Stage-7 crawl/compile throughput and peak RSS.

Adjust the default if 1 GiB triggers pathological early-major-GC
frequency on smaller workloads, or if it leaves splits-into-small
events on the table for larger ones.

---

## Files Touched

- `runtime/src/allocator/AllocatorCommon.hpp` — config fields + validate.
- `runtime/src/allocator/OldGenSpace.hpp` — new members, helpers, doc.
- `runtime/src/allocator/OldGenSpace.cpp` — initialize/reset, hooks in
  `populateFromBlock` / `releaseBlockToAllocator` /
  `allocateFromEmptyRegularBlocks`, new helpers, reordered
  `allocateFromSizeClass`.
- `test/allocator/...` — new tests for the six scenarios above.

## Out of Scope

- Tuning of `Y` (calibration is its own follow-up).
- Changing the bag-page acquisition / OS grow policy itself.
- Any nursery-side change.
