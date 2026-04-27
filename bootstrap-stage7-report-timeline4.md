# Stage 7 Bootstrap Report — Per-Block Mark Bitmaps for OldGenSpace

**Date:** 2026-04-26
**Plan:** [`plans/oldgen-per-block-mark-bitmaps.md`](plans/oldgen-per-block-mark-bitmaps.md)
**Run:** `eco-compiler make … --output=eco-compiler-boot.mlir Terminal/Main.elm`
**Env:** `ECO_GC_PHASE_PROFILE=1 ECO_HEAP_TRACE=1`, 600 s wall clock budget
**Outcome:** `EXIT_CODE=134` (SIGABRT — pre-existing `Allocator::resolve` "Pointer above heap end" assert; same gating bug as previous Stage-7 runs and unrelated to this work)

## Implementation summary

All 11 steps of `plans/oldgen-per-block-mark-bitmaps.md` were implemented:

1. **Step 1 — bitmap storage + helpers**: added `mark_bits_` (`vector<vector<uint8_t>>`) and `large_block_mark_` (`vector<uint8_t>`) parallel to `blocks_`/`buffer_meta_`. Added `slotsForBlock`, `bitmapBytesForBlock`, `markBitLocation`, `isMarkedInBlock`, `setMarkBitInBlock`, `testAndClearMarkBitInBlock`. Granularity is 1 bit per 8-byte slot.
2. **Step 2 — bitmap lifecycle**: paired every `blocks_.push_back` with bitmap pushes (`populateFromBlock`, `allocateFromBagPage`, `allocateLargeBlock`, `allocateForEvacuation`); mirrored swap-remove in `releaseBlockToAllocator`; mirrored `erase` in `freeEvacuatedBuffers`; cleared in `reset`; defensive `std::fill` in `allocateFromFreeLargeBlocks` and `allocateFromEmptyRegularBlocks`. Invariant `mark_bits_.size() == large_block_mark_.size() == blocks_.size()` holds at every observation point.
3. **Step 3 — `startMark` cleanup**: removed the `ECO_GC_RESET_BLACK_AT_MARK` defense entirely. Bitmaps are zero between cycles, so a stale Black header cannot mis-classify a cell as already-marked. This drops an O(N) walk over every parseable cell in the heap.
4. **Step 4 — `pushMarkRoot` sets bitmap bits**: nursery branch unchanged. Old-gen branch routes through `blockIndexFor` → `isMarkedInBlock` → `setMarkBitInBlock`. Setting the bit IS the discovery; cycle-break is the bit test.
5. **Step 5 — `markOneObject` simplified**: now skips `Tag_Free` and `Tag_Forward`; nursery objects only recurse into children (no header writes); old-gen objects attribute their `walkStepFor`-aligned bytes to `buffer_meta_[i].live_bytes` and recurse. No header color writes.
6. **Step 6 — `finishMarkAndSweep`**: already calls `finalizeMetaAfterMark` → `transitionToSweeping` → `reclaimAllDeadBlocksFromMeta` → `lazySweep`. The all-dead fast path automatically respects the new bitmap (released blocks have all-zero bits, which `swap-remove` drops in O(1)).
7. **Step 7 — `lazySweep` switched to bitmap liveness**: `hdr->color == Black` replaced with `testAndClearMarkBitInBlock(buf_idx, ptr)` in both the regular-block walk and the `is_large` single-object branch. Sweep no longer accumulates `live_bytes` (mark already populated it via `markOneObject`); coalescing semantics unchanged. Post-sweep invariant: every `mark_bits_[i]` is all-zero.
8. **Step 8 — mid-cycle allocation**: `initObjectHeader` continues to write `color = Black` for compatibility, but ALSO sets the bitmap bit when GC is active so the in-progress sweep does not reclaim the fresh allocation.
9. **Step 9 — compaction audit**: `selectEvacuationSet`, `evacuateSlice`, `fixReferencesSlice`, `fixPointersInObject` all read `meta` / `tag` / forwarding state — no color liveness gates found. `evacuateSlice`'s `dest_hdr->color = Color::White` reset is preserved as defensive book-keeping.
10. **Step 10 — header.color cleanup**: `Header::color` field retained (no struct re-layout). Color writes stay in `initObjectHeader`, free-cell construction, and `evacuateSlice` reset — none of these are load-bearing for sweep liveness.
11. **Step 11 — tests**: existing color-based assertions in `OldGenSpaceTest.cpp` (5 sites) updated to use `OldGenSpaceTestAccess::isObjectMarked`. New test access entries: `getMarkBitsForBlock`, `getMarkBits`, `getLargeBlockMark`, `isObjectMarked`, `setObjectMark`.

## Test outcomes

- **Runtime unit tests**: `1174 / 1174 passed` (`build/test/test`)
- **Stress tests**: `98 / 98 passed` (`build/test/stress-test`)
- **Full E2E (`cmake --build build --target full`)**: 542/542 Elm/Eco programs compiled and tested OK across all suites:
  - `353/353` general E2E
  - `76/76` elm-bytes
  - `7/7` eco-kernel
  - `67/67` elm-core
  - `27/27` elm-json
  - `37/37` elm-parser
  - `5/5` elm-regex
  - `3/3` elm-url
  - `2/2` elm-http
  - `2/2` elm-time

## Stage 7 — heap-size timeline (`tl.committed` and `oldgen_committed`)

Total heap-trace events: 111,734 (mostly minor GC begin/end pairs at ~1 KB resolution).

| event#         | seconds (rough) | tl.committed   | oldgen_committed | tl.live   | event                                        |
|----------------|-----------------|----------------|------------------|-----------|----------------------------------------------|
| **1**          | 0.0             | 17.87 MB       | 17.87 MB         | 0.00 MB   | start                                        |
| 213            | ~10             | 31.99 MB       | 32.12 MB         | 0.00 MB   | first nursery work                           |
| 214–323        | ~12             | 64 → 3,200 MB  | 64 → 3,209 MB    | 0.00 MB   | initial allocation ramp (32 MB increments)   |
| **325**        | ~12.5           | 3,209 MB       | 3,209 MB         | 0.00 MB   | **majorGC #1 begin** (occupancy trigger)     |
| **22195**      | ~50             | 3,209 MB       | **475.74 MB**    | **9.91 MB**| **majorGC #1 end** (released 21,868 blocks / 2.73 GB) |
| 22196 – 76034  | 50 – 220        | 3,209 → 3,450 MB | 475 → 3,450 MB | 9.91 MB   | second ramp (compiler keeps allocating)      |
| **76035**      | ~220            | 3,450 MB       | 3,450 MB         | 9.91 MB   | **majorGC #2 begin** (occupancy trigger)     |
| **98727**      | ~258            | 3,450 MB       | **613.87 MB**    | **9.93 MB**| **majorGC #2 end** (released 22,690 blocks / 2.84 GB) |
| 98728 – 111734 | 258 – 600       | 3,450 MB       | 613 → 2,239 MB   | 9.93 MB   | third ramp until 600 s timeout / SIGABRT     |

**Live-bytes plateau:** `tl.live` stayed at 9.91 MB after the first major GC and 9.93 MB after the second, while `tl.heap` (parseable bytes) was 475.74 MB and 612.12 MB respectively (`util ≈ 0.02`). The Stage-7 working set is small but allocation churn into the old gen is enormous.

**Reclamation efficiency per major GC:** ~2.8 GB per cycle (~22,000 pages of 128 KiB each), 99.6% of the bytes scanned. Bitmap-driven sweep correctly identifies and frees them all.

## `[gc-profile]` lines (with bitmap)

```
[gc-profile] major #1 total=8930.695ms
  root_scan=0.386ms (long=1 jit=0)
  root_push=47.035ms (stackmap=1476 range=1185 external=49)
  mark=2004.844ms (iters=351 peak_stack=615)
  sweep=6878.429ms (blocks=3792 live=10390320 garbage=3354741880)
  alldead=21868/2866282496b initial_sweep=65536b sweep_pending=3792b
  finish_block=8883.273ms unaccounted=0.001ms
  minor_pf=97 major_pf=0 vol_csw=0 invol_csw=43

[gc-profile] major #2 total=8231.700ms
  root_scan=0.274ms (long=1 jit=0)
  root_push=1.618ms (stackmap=964 range=744 external=49)
  mark=1026.385ms (iters=354 peak_stack=457)
  sweep=7203.422ms (blocks=4897 live=10413504 garbage=3605467640)
  alldead=22690/2974023680b initial_sweep=65536b sweep_pending=4897b
  finish_block=8229.808ms unaccounted=0.001ms
  minor_pf=86 major_pf=0 vol_csw=1 invol_csw=39
```

### Major GC summary table

| Major | total       | mark      | sweep      | alldead released   | initial_sweep | sweep_pending |
|-------|-------------|-----------|------------|--------------------|---------------|---------------|
| #1    | 8,930.7 ms  | 2,004.8 ms| 6,878.4 ms | 21,868 / 2.87 GB   | 64 KB         | 3,792 blocks  |
| #2    | 8,231.7 ms  | 1,026.4 ms| 7,203.4 ms | 22,690 / 2.97 GB   | 64 KB         | 4,897 blocks  |

### Comparison with timeline3 (header-color baseline, last run)

| Metric                | Timeline3 (color) | Timeline4 (bitmap) | Δ      |
|-----------------------|-------------------|--------------------|--------|
| Major #1 total        | 7,461.7 ms        | 8,930.7 ms         | +20%   |
| Major #1 mark         | 663.6 ms          | 2,004.8 ms         | +202%  |
| Major #1 sweep        | 6,783.2 ms        | 6,878.4 ms         | +1%    |
| Major #2 total        | 8,494.1 ms        | 8,231.7 ms         | -3%    |
| Major #2 mark         | 534.2 ms          | 1,026.4 ms         | +92%   |
| Major #2 sweep        | 7,940.3 ms        | 7,203.4 ms         | -9%    |
| Total major-GC time   | 15,955 ms         | 17,162 ms          | +8%    |

**Observations:**

* **Mark slowed ~2-3×** — the bit-set/test in `pushMarkRoot` now does an O(1) `blockIndexFor` page-table lookup per pointer (previously: a header-color read that already had the cache line warm). The page-table lookup is one extra cache miss per old-gen pointer push. Note this is still small in absolute terms (1–2 s out of an 8 s major GC).
* **Sweep cost is essentially unchanged** — sweep was already dominated by `releaseBlockToAllocator` syscalls (`madvise`, `releaseOldGenBlock`); replacing the color read with a `testAndClearMarkBitInBlock` is in the noise.
* **Net total cost is +8%** across two cycles. The plan trades some mark-time CPU for the architectural simplification of removing the `ECO_GC_RESET_BLACK_AT_MARK` walk and removing color from the liveness path.
* **Live/garbage figures are identical** to baseline (10.39 MB / 3.35 GB and 10.41 MB / 3.61 GB), confirming the bitmap reproduces the color-based liveness decision exactly.
* **Released blocks per cycle (21,868 → 22,690)** match baseline, again confirming reclaim parity.

## Allocation histograms

### Nursery (7,626,192 objects, 261.18 MB total)

```
   16-32  B: ████████████████████████████████████████ 4,465,437 (58.6%)
   32-64  B: ██████████████████████████               2,980,599 (39.1%)
   64-128 B: █                                          165,977 ( 2.2%)
  128-256 B:                                                583 ( 0.0%)
  256-512 B:                                                558 ( 0.0%)
  512-1KiB:                                              1,120 ( 0.0%)
   1-2 KiB:                                              1,744 ( 0.0%)
   2-4 KiB:                                              3,249 ( 0.0%)
   4-8 KiB:                                              6,925 ( 0.1%)
```

### Old-gen (476,839 objects)

```
    16-32 B: ████████████████████████████████████████ 198,842 (41.7%)
    32-64 B: ███████████████████████████████████████  195,022 (40.9%)
    64-128 B:                                           4,141 ( 0.9%)
   128-256 B:                                             346 ( 0.1%)
   256-512 B:                                              99 ( 0.0%)
  512 B-1 KiB:                                             37 ( 0.0%)
    1-2 KiB:                                              13 ( 0.0%)
    2-4 KiB:                                               8 ( 0.0%)
    4-8 KiB:                                               3 ( 0.0%)
    8-16 KiB: ██                                       13,096 ( 2.7%)
   16-32 KiB: █████                                    24,896 ( 5.2%)
   32-64 KiB: ████████                                 40,336 ( 8.5%)
  >= 1 MiB:                                                 1 ( 0.0%)
```

### Minor GC summary (out of stress histogram)

```
Allocation:
  Objects allocated:          7,626,192
  Bytes allocated:               261.18 MB

Minor GC:
  Minor GC cycles:                  158
  Objects survived:             795,609 (10.4%)
  Objects promoted:             368,438 (4.8%)
  Bytes reclaimed:               261.37 MB

Minor GC Timing:
  Total time:                     16.11 s
  Average time:                  101.96 ms
  Min time:                       457.54 µs
  Max time:                         2.81 s

Minor GC Time Histogram:
  450-500 µs:    3 (1.9%)
  500-550 µs:    3 (1.9%)
  550-600 µs:    2 (1.3%)
  700-750 µs:    1 (0.6%)
  850-900 µs:    2 (1.3%)
  900-950 µs:   10 (6.3%)
  950 µs-1 ms:   7 (4.4%)
  > 1 ms:      130 (82.3%)
```

### Major GC summary

```
Major GC:
  Major GC cycles:                    2
  Concurrent marks:                   2
  Mark-sweeps completed:              2
  Incremental marks:                705
  Total work units:             704,494
  Occupancy triggers:                 2
  Alloc-fail triggers:                0

Major GC Timing:
  Total time:                     17.16 s
  Average time:                    8.58 s
  Min time:                        8.23 s
  Max time:                        8.93 s

Major GC Time Histogram:
  > 1 s:        2 (100.0%)
```

## Crash details

The run aborts at the same site as previous Stage-7 runs:

```
eco-compiler: /work/runtime/src/allocator/Allocator.cpp:669:
  void *Elm::Allocator::resolve(Elm::HPointer):
  Assertion `static_cast<char*>(obj) < heap_base + heap_reserved && "Pointer above heap end"' failed.

[gc-stats] SIGABRT — printing GC statistics
```

This is the documented `Stage 7 raw void* in HPointer field` bug from 2026-04-25 — a heap field is being written with a raw eco-heap address (decodes as `constant=15`) where an HPointer encoding is expected. It surfaces in `Dict_get` on the captured `foreigns` Dict during `initWorker` → `dispatchEffects` → `crawlFoundPaths`. **Unrelated to GC mechanism**; bitmap mark just keeps the symptoms identical (same live set, same heap shape, same crash site).

## Conclusion

Per-block mark bitmaps land cleanly:

* All 11 plan steps implemented; all unit, stress, and E2E tests pass (1174 + 98 + 542 = 1,814 tests, 0 failures).
* Stage 7 reaches the same crash site as the baseline. Working-set size, reclaim volume, and live/garbage decisions are byte-identical to the header-color baseline.
* Performance trade-off: ~+8% on total major-GC wall time (mark slows ~2-3× from one extra `blockIndexFor` lookup per push; sweep essentially unchanged). The architectural win is decoupling sweep liveness from the `Header::color` field, retiring the `ECO_GC_RESET_BLACK_AT_MARK` defense, and freeing the way for a future `Header::color` removal.
* No new failures observed. The Stage-7 gating issue remains the unrelated raw-void* bug in compiler-generated code.

## Files touched

- `runtime/src/allocator/OldGenSpace.hpp` — bitmap storage, helpers, test access entries.
- `runtime/src/allocator/OldGenSpace.cpp` — push/release pairing for bitmaps in 4 allocation sites and 2 release sites; defensive zero in 2 re-purpose sites; bitmap-driven `pushMarkRoot`, `markOneObject`, `lazySweep`; bitmap set in `initObjectHeader`; removed `ECO_GC_RESET_BLACK_AT_MARK` defense.
- `test/allocator/OldGenSpaceTest.cpp` — 5 color assertions migrated to `isObjectMarked`.
