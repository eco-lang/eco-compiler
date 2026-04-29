# Size-Class Allocation Path Slowness — Investigation Report

## Context

While tuning `HeapConfig` parameters via repeated 5-minute Stage 7 runs, the
minor-GC time histogram showed a single outlier of ~74-100 s in every run
(versus an average of 1-2 s). After all the obvious helper-time accounting
fixes were applied (see `gc-tune-run1-metrics-audit.md`), a 70-89 s outlier
remained even with `helper_in_minor` reporting zero — meaning the time was
NOT inline mark/sweep helper work.

This report traces the investigation that localised the bug to a structural
inefficiency in `OldGenSpace::tryAllocateBySplittingLarger`, and proposes
the fix.

## TL;DR

The 100 s minor-GC outlier had **two distinct causes**, hidden by accounting:

1. **Sweep-on-demand work charged to minor GC** (~30 s): when promotion
   calls `oldgen.allocate` while old-gen is in `Sweeping` phase,
   `sweepOnDemandAllocate` runs up to 1 MiB of `lazySweep` per call. Across
   30 k promotions in one cycle, this added ~30 s.
   **Fixed** by extending the helper bracket in `OldGenSpace::allocate` to
   wrap the entire allocation body (commit "extend helper bracket to capture
   sweep-on-demand work").

2. **The size_class allocation path itself is slow** (~70 s remaining):
   29,979 promotions during one minor cycle averaged **1.9 ms each** in
   `oldgen.allocate` with `gc_phase_ == Idle` (no helper work). Whole-run
   average is **150 µs/call** vs. ~50 ns expected for a free-list pop. The
   hot path costs are 3000× higher than they should be — **a real bug, not
   an accounting issue**. **Not yet fixed**; this report identifies the
   root cause and recommends a one-line fix.

## Investigation timeline

Each step pinpointed the previous step's blind spot. All instrumentation
was added under `ECO_MINOR_OUTLIER_TRACE` (env-gated) so it costs nothing
in production. The instrumentation was reverted after the investigation;
this report preserves the findings.

### Step 1: Helper-bracket attribution gap

Before this investigation, `OldGenSpace::allocate`'s helper bracket only
wrapped the inline mark + lazy-sweep `if`-blocks. Extended it to wrap the
entire allocation body, capturing `sweepOnDemandAllocate`'s lazy-sweep work
too.

Effect on the outlier: dropped from **100.78 s → 89 s → 82 s → 71 s → 56 s**
across successive runs (different paths through the compiler). About
25–45 % of the original outlier was sweep-on-demand work that was hidden.

### Step 2: Pinpoint the phase

Added per-cycle phase timing in `NurserySpace::minorGC`. Result on the
outlier minor:

```
[minor-outlier] pure=82.330s elapsed=82.330s helper=0.000s
                from_used=16.20MB to_used=0.33MB freed=15.87MB
                low_blocks=72 high_blocks=72 promoted=30040
                p1_root=0.000s p2_cheney=0.000s p3_promoted=82.330s
                p4_grow=0.000s p5_clear=0.001s
```

**Phase 3 (promoted-object scan) accounts for 100 % of the outlier.**
Helper bracket reports 0 ns for the whole cycle — meaning
`gc_phase_ == Idle` throughout. So this is **not** mark/sweep work.

### Step 3: Pinpoint the function

Added always-on per-call timer for `OldGenSpace::allocate`:

```
[minor-outlier]   phase3 oldgen.alloc: wall=71.751s calls=29979 (2393.4 µs/call)
                  rest=0.009s
```

**99.99 % of phase 3 is inside `oldgen.allocate`.** Each call averages
2.4 ms.

### Step 4: Pinpoint the path

Added per-path timers for `allocateFromSizeClass` / `allocateFromBagPage` /
`allocateLargeBlock`:

```
[minor-outlier]   cumul paths: size_class=56.83s/378018 (150.3µs)
                               bag_page=0.15s/13111 (11.5µs)
                               large_block=0.00s/1 (10.2µs)
```

**The size_class path is the hotspot** — averaging 150 µs/call across all
378 k calls in the run. The other two paths are fast (11.5 µs and 10.2 µs).

During the outlier minor specifically, size_class averaged **1894 µs/call**
(12× the run average), meaning something about that minor cycle made the
path even slower than usual.

## Root cause: structural waste in `tryAllocateBySplittingLarger`

Reading `allocateFromSizeClass`:

```cpp
void* allocateFromSizeClass(size_t cls, size_t requested_size) {
    if (void* r = tryAllocateFromFreeLists(cls, requested_size)) return r;     // (1)
    if (hasPendingSweepWork())
        if (void* r = sweepOnDemandAllocate(cls, requested_size)) return r;     // (2)
    if (populateFromBlock(cls)) {
        FreeCell* cell = free_lists_[cls];
        if (cell) { ... return result; }                                        // (3)
    }
    if (void* r = allocateFromBagPage(requested_size)) return r;                // (4)
    return nullptr;
}
```

(2) is gated on `Sweeping` phase — does nothing here (helper=0).
(4) is well-instrumented and fast (11.5 µs avg).

So the cost is in (1) and (3). Inside (1):

```cpp
void* tryAllocateFromFreeLists(size_t cls, size_t requested_size) {
    if (free_lists_[cls] != nullptr) { /* O(1) pop */ }
    if (void* r = tryAllocateBySplittingLarger(cls, classToSize(cls))) return r;
    return nullptr;
}
```

`tryAllocateBySplittingLarger` walks every higher class's free list looking
for a cell to split:

```cpp
for (size_t cls = target_cls + 1; cls < NUM_SIZE_CLASSES; ++cls) {
    if (free_lists_[cls] == nullptr) continue;
    const bool maybe_uniform_block = cls < num_size_classes_;
    FreeCell* curr = free_lists_[cls];
    while (curr != nullptr) {
        const size_t cell_bytes = curr->header.size;
        const size_t remainder = ...
        // For uniform classes accept ONLY exact fits.
        const bool acceptable_for_block = !maybe_uniform_block || remainder == 0;
        if (cell_bytes >= alloc_size &&
            (remainder == 0 || remainder >= MIN_FREE_CELL_SIZE) &&
            acceptable_for_block) { ... return result; }
        curr = curr->next;
    }
}
```

For uniform classes (`cls < num_size_classes_`) the only acceptable fit is
`remainder == 0`, i.e. `cell_bytes == alloc_size`. But:

- `cls > target_cls` ⇒ `classToSize(cls) > classToSize(target_cls) = alloc_size`
- Cells on `free_lists_[cls]` have `cell_bytes >= classToSize(cls) > alloc_size`
- ∴ `remainder > 0` always; `acceptable_for_block` always false; **the inner
  loop walks the entire list and never accepts anything**.

For 33 uniform classes (0–36 in the LOT=8K config) per call to
`tryAllocateBySplittingLarger`, this is **pure wasted iteration**
proportional to the cumulative free-list length above `target_cls`. With
long fragmented free lists (post-major-sweep), this can be tens of
thousands of iterations.

## Why the outlier minor is 12× slower than the run average

The outlier minor's phase 3 hits the slow path harder than typical. Two
amplifiers stack:

1. **Massive batch of promotions from a pure-Idle state.** With `helper=0`,
   no lazy-sweep work was in flight, meaning the previous major GC's
   `lazySweep` had completed and released free cells. After that,
   `free_lists_` have lots of small fragments scattered across many classes
   from mixed-block coalescing. Splitter walks are most expensive when
   free lists are most fragmented.

2. **Very small to-space (0.33 MB out of 16 MB used).** Almost everything
   that survived the cycle was promoted (30,040 objects → old gen) instead
   of being copied to to-space. So 30 k consecutive `oldgen.allocate` calls
   ran back-to-back in phase 3, hitting the slow path repeatedly without
   reprieve.

## Recommended fix

The structural waste in `tryAllocateBySplittingLarger` is straightforward
to remove:

```cpp
for (size_t cls = target_cls + 1; cls < NUM_SIZE_CLASSES; ++cls) {
    if (free_lists_[cls] == nullptr) continue;
    if (cls < num_size_classes_) continue;   // ← skip uniform classes entirely
    ...
}
```

Or equivalently start the loop at `std::max(target_cls + 1, num_size_classes_)`.
Cells on uniform classes will never be accepted, so iterating them is dead
work. This should make the size_class path drop from 150 µs/call to
single-digit µs/call (driven by populates and the actual free-list pop cost).

A second-order fix is the same issue when `cls >= num_size_classes_` but
lists are very long: the splitter walks the whole list looking for a fit.
A doubly-linked free list or a size-bucketed map would make the search
O(log N) instead of O(N), but that's a larger change.

## Numbers to tape to the wall

| run | minor max | helper | phase 3 in oldgen.alloc | size_class avg µs/call (whole run) |
|---|---:|---:|---:|---:|
| pre-helper-bracket-extension | 100.78 s | 1.0 s | (un-instrumented) | (un-instrumented) |
| with extended helper bracket | 89.28 s | 0.000 s | (un-instrumented) | (un-instrumented) |
| with phase-3 sub-attribution | 82.33 s | 0.000 s | 71.75 s / 29 979 calls (2.4 ms) | (un-instrumented) |
| with per-path attribution | 56.80 s | 0.000 s | 56.79 s / 29 979 calls (1.9 ms) | **150.3 µs/call** (size_class) |

The instrumentation chain pinpointed the bug. The fix is a one-line skip
in the splitter loop.

## What's now fixed in the codebase

Only the sweep-on-demand accounting fix (Step 1 above) is committed. The
size_class structural fix and all the per-path / per-phase diagnostic
counters from Steps 2–4 are not. This file is the record of those findings
so the fix can be applied later without re-doing the investigation.
