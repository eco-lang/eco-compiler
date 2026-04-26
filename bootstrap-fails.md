# Bootstrap Failures Log

Failures encountered while running `guides/bootstrap-fix-loop.md` on top of
the oldgen capacity-shrink + large-block reuse plan.

## Failure #1 — Stage 7 OOM at 12 GB cap (Major GC trigger doesn't see global pressure) — FIXED

**Stage:** 7 — `eco-compiler` self-compile to MLIR.

**Symptom:** `acquireOldGenBlock OUT OF SPACE (returning nullptr)` after
~92 s; `oldgen_committed=12287.93 MB` (the 12 GB cap), `tl.live=2.04 MB`,
`allocated_bytes=3043 MB`. Only one major GC fired in the entire run.

**Root cause:** `OldGenSpace::shouldTriggerMajorGC` only checked the
per-thread ratio `allocated_bytes / region_span >= 0.75`.
`allocateFromBagPage` burns a fresh 128 KB page per "between sizes"
request even when the request is much smaller, so committed grew ~6×
faster than `allocated_bytes` and the ratio stayed at ~0.25.

**Fix:** Added a global-pressure trigger to `shouldTriggerMajorGC`: also
fire when `Allocator::old_gen_committed / Allocator::old_gen_max_bytes >=
major_gc_initiating_occupancy / 3` (≈0.25). `maybeShrinkCapacity`
bypasses its hysteresis under the same global pressure so committed
actually drops after the GC.
`runtime/src/allocator/OldGenSpace.cpp:1199` and
`runtime/src/allocator/OldGenSpace.cpp:1300`.

**Status:** FIXED.

---

## Failure #2 — Sweep produces corrupt free-list cells in MIXED blocks — FIXED

**Stage:** 7 — second major GC, after ~26000 BBoP blocks have been
materialized.

**Symptom:** `removeFreeCellsForBlock` (called from `maybeShrinkCapacity`)
SEGFAULTs because `free_lists_[3]` (or another small class) contains a
`FreeCell*` whose value decodes as a `Header` bit pattern (e.g.
`0x1000000000010` = `Tag_Free, size=65536`). A validation pass right
after `sweep()` confirmed the corruption was produced **at sweep time**,
before shrink touched the lists.

**Investigation steps:**
1. Added `pushSpanOnFreeLists` OOB check — caught a span of 4.7 MB
   pushed for a 128 KB block.
2. Walked the block's parseable region — found a Tag_String at offset
   128672 with the correct size (1096 bytes), then 60 zero "Tag_Int"
   objects of 16 bytes each, then bytes that decoded as
   `Tag_DynRecord, size=589833` (= 4.7 MB) with UTF-16 string content.
3. Raw byte dump revealed the actual layout was:
   - 128672..129768: Tag_String (1096 bytes, length=541) ✓
   - 129768..130720: 952 bytes of zeros
   - 130720..130976: Tag_String (256 bytes, length=122) — **a real
     string, but sweep walked PAST its header at 130720**
   - 130976..131072: another Tag_String

**Root cause:** Sweep walks MIXED blocks (size_class = NUM_SIZE_CLASSES)
by `getObjectSize(ptr)` — the object's logical size. Objects allocated
through `tryAllocateBySplittingLarger` get carved into cells of
`classToSize(target_cls)` bytes (e.g. cls=32 → 512 bytes), but the
object's `hdr->size` reflects the caller's requested size, which can be
less than the carved cell. The slack between `getObjectSize(obj)` and
`classToSize(cls)` is invisible to the size formula, so sweep walks
into it, mis-interprets zero bytes as `Tag_Int(0)` (16-byte step),
eventually crossing into the next object's data area and reading random
bytes as a header — usually a wildly oversized `getObjectSize` that
overshoots the block.

**Fix:** Added a `padCellSlack(obj, requested_size, cell_size)` helper
that writes a `Tag_Free` trailing header at `obj + requested_size` when
`cell_size > requested_size`. Called from all three branches of
`allocateFromSizeClass` (free-list pop, splitting-larger,
populate-from-block). For SIZE-CLASS blocks, sweep already walks by
fixed `cellSize`, so the trailing is harmless; for MIXED blocks, the
trailing makes sweep step over the slack correctly.
`runtime/src/allocator/OldGenSpace.cpp:271-292` (helper) and call sites
in `allocateFromSizeClass`.

Also fixed `getObjectSize` for `Tag_Array` to use `header.size`
(capacity) instead of `arr->length` (used elements), since the heap
footprint is sized for the full capacity at allocation time.
`runtime/src/allocator/AllocatorCommon.hpp:120`.

**Status:** FIXED.

---

## Failure #3 — Stage 7 wall-time too slow (O(N²) shrink, eq tag-mismatch) — OPEN

**Stage:** 7 — Stage 7 runs many major GC cycles, each releasing 22000+
blocks from the per-thread `blocks_` vector. Over 13 minutes elapsed
without producing `eco-compiler-boot.mlir`.

**Symptoms / observations:**
1. Major GC trigger fires at ~3 GB committed (per Failure #1's fix).
2. Each cycle's shrink reclaims 2.8–3.0 GB, dropping committed to
   300–700 MB. Working as designed.
3. `[eq] tag mismatch: 3 vs 0` appears once in the log (matches the
   pre-existing `Stage 7 eq tag-mismatch crash 2026-04-25 PM` memory)
   but the program does not abort on it.
4. Per-cycle wall time appears to be on the order of minutes, dominated
   by `removeFreeCellsForBlock` walking all `free_lists_` for every
   released block — a per-shrink O(N · M) pattern where N = blocks
   released and M = total cells across all classes.

**Hypothesis:**
- The shrink is correct but slow at this scale (~26000 blocks ×
  millions of cells).
- The `[eq] tag mismatch` indicates a separate runtime bug somewhere
  (likely in dep solver) that's surfaced at scale; it's recoverable
  enough that the program continues, just spuriously.

**Status:** OPEN — out of scope for the original plan. Would need:
(a) per-block free-cell tracking (e.g. a side index from block to its
cells) to make shrink O(N) instead of O(N · M), and
(b) investigation of the `[eq] tag mismatch` case (separate from the
allocator).

---

## Summary

- **Plan implementation:** complete (Steps 1–6 of
  `plans/oldgen-capacity-shrink-and-large-reuse.md`).
- **Tests:** 1169/1169 unit, 1169/1169 E2E, 98/98 stress all pass.
- **Stage 7 progress vs prior memory:**
  - Apr 24: aborted in `eco_resolve_hptr` immediately.
  - Apr 25 PM: aborted in 4.6 s with `eq tag mismatch` before any module
    compile.
  - **Now:** 5+ major GC cycles complete; each cycle reclaims ~3 GB and
    releases ~23000 blocks; committed cycles between 3.3 GB and 600 MB
    instead of monotonically growing to the 12 GB cap. Stage 7 still
    doesn't finish (Failure #3) but it gets visibly past the historical
    failure points.

## Debug instrumentation left in place

- `removeFreeCellsForBlock` (`OldGenSpace.cpp:~1300`): no-op debug check
  was removed.
- `pushSpanOnFreeLists` OOB guard (`OldGenSpace.cpp:~932`): kept under
  `ECO_OLDGEN_DEBUG`. Detects sweep-time span-overshoot in the future.
- `OldGenSpace::sweep` post-sweep validation (`OldGenSpace.cpp:~1149`):
  kept under `ECO_OLDGEN_DEBUG`. Walks every free-list cell to confirm
  in-heap pointer.

Both diagnostics are quiet by default (no overhead unless
`ECO_OLDGEN_DEBUG=1` is set).
