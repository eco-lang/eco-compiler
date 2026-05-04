# Age-bit sentinel for immediate split-header body reclaim

## Goal

Let `OldGenSpace::sweepNurseryLargeBodies` free split-header bodies (Tag_String /
Tag_ByteBuffer bodies owned by Tag_LargeStringHeader / Tag_LargeByteHeader
nursery headers) **immediately** during all GC phases except compaction, so the
freed space becomes reusable to the old-gen allocator without waiting for major
GC sweep to walk the block.

Today's behaviour: `sweepNurseryLargeBodies` early-returns whenever
`gc_phase_ != Idle` *or* `compact_phase_ != Idle`. Bytes of dead bodies are
attributed to `large_body_deferred_to_major_bytes` and are recovered only by
the next major-GC sweep walk. This plan keeps the deferral only for compaction.

We do this by repurposing one bit of the `Header.age` field on `Tag_Free` cells
as an "already on a free list" sentinel that the lazy sweep coalescer must
honor: never merge across, never rewrite, leave the existing free-list link
intact.

## Design summary (what gets reused)

`Header` (Heap.hpp:101) layout — unchanged on disk:

```
tag       : 5
color     : 2
pin       : 1
age       : 2
unboxed   : 6
refcount  : 16
size      : 32
```

- `age` is meaningful only in the nursery (minor-GC promotion counter).
  Old-gen `Tag_Free` cells never use `age` for anything today.
- For `Tag_Free` in old gen, define:
  - `age & 0b01 == 0` → normal coalescable free cell (current behaviour).
  - `age & 0b01 == 1` → sentinel free cell: already on a free list,
    not to be merged or rewritten by lazy sweep.
- `age & 0b10` is reserved (kept zero) for non-free tags' nursery use; it does
  not collide with the sentinel because nursery objects never have `Tag_Free`.

`Header.size` semantics are **not** touched: `getObjectSize`'s `Tag_Free` case
keeps reading `hdr->size` as the byte count (AllocatorCommon.hpp:131-135).

## Step-by-step implementation plan

### Step 1 — Heap.hpp: document the dual use of `age`

File: `runtime/src/allocator/Heap.hpp` (around line 95-110, the `Header`
struct comment).

- Update the leading comment block to spell out:
  - For non-`Tag_Free` tags: `age` is the nursery promotion counter.
  - For `Tag_Free` in old gen:
    - `age & 0b01` is the "already on free list" sentinel. `0` =
      coalescable; `1` = do not merge or rewrite during lazy sweep.
    - `age & 0b10` is **reserved for future use, must be 0 in `Tag_Free`**.
  - For all `Tag_Free` writes, the only legal `age` values are `0`
    (coalescable) and `1` (sentinel).
  - The 8-byte heap-base sentinel installed by `installHeapBaseSentinel`
    is **exempt** from the `age & 1` convention. It carries `age = 0` and
    is identified by address (`isHeapBasePage`), not by the age bit.
- No layout change. No struct change.

### Step 2 — OldGenSpace.hpp: helpers + invariant comment

File: `runtime/src/allocator/OldGenSpace.hpp`.

1. Add three private static helpers in `OldGenSpace` (place near the existing
   sweep/free-cell helpers, e.g. just below the `FreeCell` block at
   ~line 174 or in the private section of the class):

   ```cpp
   static bool isFreeCellSentinel(const Header* hdr) {
       return (hdr->tag == Tag_Free) && ((hdr->age & 0b01u) != 0);
   }
   static void setFreeCellSentinel(Header* hdr) {
       hdr->age = (hdr->age & ~0b11u) | 0b01u;
   }
   static void clearFreeCellSentinel(Header* hdr) {
       hdr->age = (hdr->age & ~0b11u);
   }
   ```

2. Update the "Split-Header Body Tracking (HEAP_026)" comment block
   (~line 475) to mention:
   - Bodies are freed in all GC phases except compaction.
   - The sentinel bit prevents lazy-sweep coalescing from merging cells the
     fast path has already linked into a free list.

3. (Optional but recommended) Expose `isFreeCellSentinel` to the test access
   shim (`OldGenSpaceTestAccess`) so unit tests can verify the bit is set on
   cells produced by the immediate-free path and clear elsewhere.

### Step 3 — OldGenSpace.cpp: refine `sweepNurseryLargeBodies` skip rule

File: `runtime/src/allocator/OldGenSpace.cpp`, function
`sweepNurseryLargeBodies` (lines 3742-3818).

- Keep the `assert` that compaction is not Evacuating/FixingRefs at entry.
- Replace the early-return condition
  `gc_phase_ != GCPhase::Idle || compact_phase_ != CompactionPhase::Idle`
  with: defer **only** when `compact_phase_ != CompactionPhase::Idle`.
- Stat semantics:
  - `large_body_minor_sweep_skips` keeps incrementing only on the
    compaction-deferred path.
  - `large_body_deferred_to_major_bytes` is now bumped only when compaction
    is in flight. (Strictly speaking it is now "deferred to next minor after
    compaction completes", so update the GCStats comment in Step 8.)

### Step 4 — OldGenSpace.cpp: rewrite `freeLargeBodyCell` to honor GC phase

File: `runtime/src/allocator/OldGenSpace.cpp`, function `freeLargeBodyCell`
(lines 3820-3902).

The current function already handles two cases (is_large vs. regular). The
required edits:

1. **Large-block branch (`m.is_large == true`)** — already routes to
   `free_large_blocks_` via `markBlockAsFreeLarge`-style code. Works in any
   non-compaction phase because sweep always treats a large block as a single
   live-or-dead unit (it does not coalesce inside one). No behavioural change
   needed; keep the existing `Tag_Free` header overlay and `live_bytes = 0`,
   `fully_swept = true` updates. **Do not** set the sentinel bit on
   `is_large` cells (they aren't on a size-class free list).

2. **Regular-block branch (`m.is_large == false`)** — the current code already
   clears the mark bit, calls `pushSpanOnFreeLists`, and updates
   `buffer_meta_[idx].live_bytes / garbage_bytes`. Add:
   - Compute `need_sentinel`:
     ```cpp
     bool need_sentinel = false;
     switch (gc_phase_) {
         case GCPhase::Idle:     need_sentinel = false; break;
         case GCPhase::Marking:  need_sentinel = true;  break;
         case GCPhase::Sweeping:
             need_sentinel = (idx >= buffer_meta_.size()) ||
                             !buffer_meta_[idx].fully_swept;
             break;
     }
     ```
   - **Before** `pushSpanOnFreeLists` slices the span into class-sized cells,
     the sentinel decision needs to be applied to every `Tag_Free` header
     written by that path. The cleanest way is to extend `pushSpanOnFreeLists`
     with an `age_sentinel` parameter (Step 5) and pass it through.
   - Account for the fact that the current code treats this only as
     bookkeeping for `garbage_bytes`; sentinel cells should count toward
     `garbage_bytes` exactly the same way (they will be skipped by sweep, not
     re-added to a different free list).

3. Keep the existing comment at line 2760-2780 that warns about
   `freeLargeBodyCell` pushing onto a free list in a DIFFERENT block — that
   note refers to `reclaimAllDeadBlocksFromMeta` paths and is independent of
   the sentinel work.

4. Add a comment near the `large_body_index_.erase` call at line 3822
   stating that `freeLargeBodyCell` is the authoritative ownership transition
   for split-header bodies (Resolved Decisions §3). The `erase` calls in
   sweep at lines 2208-2218 and 2247-2257 must remain idempotent guards and
   must NOT push onto `free_large_body_ids_` — only `freeLargeBodyCell`
   recycles `LargeBodyId`s.

### Step 5 — OldGenSpace.cpp: thread sentinel flag through `pushSpanOnFreeLists`

File: `runtime/src/allocator/OldGenSpace.cpp`, helper `pushSpanOnFreeLists`
(lines 1926-2006) and its sole adjacent wrapper `pushCoalescedFreeCell`
(lines 2008-2012).

1. Add an optional bool parameter, default `false`:
   `pushSpanOnFreeLists(FreeCell** free_lists, char* span_start,
   size_t span_bytes, const BlockInfo* block = nullptr,
   bool age_sentinel = false)`.
2. In every place this helper writes a `Tag_Free` header (uniform branch,
   mixed branch, trailing-leftover branch — three sites), after
   `cell->header.tag = Tag_Free; cell->header.size = ...; cell->header.color = ...`,
   add:
   ```cpp
   if (age_sentinel) cell->header.age = 0b01;
   else              cell->header.age = 0;
   ```
   The `std::memset(&cell->header, 0, sizeof(Header))` already zeros `age`,
   so the `else` branch is technically redundant — leave the explicit assign
   for readability.
3. `pushCoalescedFreeCell` keeps `age_sentinel = false` always: the lazy-sweep
   coalescer uses it for normally-merged garbage runs, which must remain
   coalescable on the next major (the cell goes onto a free list and stays
   there until allocation).
4. `freeLargeBodyCell` (Step 4) calls `pushSpanOnFreeLists(..., need_sentinel)`.

### Step 6 — OldGenSpace.cpp: teach `lazySweep` to honor sentinel cells

File: `runtime/src/allocator/OldGenSpace.cpp`, function `lazySweep` (lines
2125-2300+), inner walk loop at lines 2230-2267.

The loop today decides liveness with:
```cpp
const bool live = (hdr->tag != Tag_Free) &&
    testAndClearMarkBitInBlock(sweep_buffer_index_, sweep_cursor_);
```
and then routes dead cells into the run-coalescing path via `run_start` /
`run_bytes`.

Refine the dead-cell branch:

```cpp
if (live) {
    flushRun(sweep_buffer_index_);
} else if (hdr->tag == Tag_Free && isFreeCellSentinel(hdr)) {
    // Already on a free list, accounted for by freeLargeBodyCell. Treat as
    // a hard run boundary: flush any pending coalesced run *before* this
    // cell, then step over it. Do NOT touch the header or its free-list
    // link, and do NOT increment garbage_bytes again — freeLargeBodyCell
    // is the authoritative accounting site for sentinel cells.
    flushRun(sweep_buffer_index_);
} else {
    // Existing path: extend the coalescing run. Either a non-sentinel
    // Tag_Free cell or a dead non-free object. The eventual flushRun
    // updates garbage_bytes for the run.
    if (run_start == nullptr) { run_start = sweep_cursor_; run_bytes = 0; }
    run_bytes += step;
    // Existing large_body_index_ cleanup for pinned String/ByteBuffer bodies
    // remains as-is (same branch as today). It is defensive only;
    // freeLargeBodyCell is authoritative — see Resolved Decisions §3.
}

sweep_cursor_ += step;
work_done += step;
```

Three subtleties to verify in implementation:

- Non-sentinel `Tag_Free` cells (e.g. from `padCellSlack` slack remainders,
  the trailing-leftover branch of `pushSpanOnFreeLists`, or coalesced runs
  flushed by an earlier sweep slice in this same block) keep folding into
  the run. This is intentional: they were not on a size-class free list
  when sweep visited them, so coalescing rewrites their headers harmlessly.
  Resolved Decision §1 confirms uniform-page free cells from
  `populateFromBlock` are non-sentinel and rely on `mid_cycle` /
  `fully_swept` guards rather than the age bit.

- `testAndClearMarkBitInBlock` short-circuits on `Tag_Free` (it is gated by
  `hdr->tag != Tag_Free`). Sentinel cells therefore never reach the mark-bit
  read, and `freeLargeBodyCell` cleared the bit before installing the
  sentinel anyway. The "post-sweep bitmap is all-zero" invariant holds.

- `walkStep(block, getObjectSize(sweep_cursor_))` continues to use
  `hdr->size`; sentinel cells carry a valid `size`, so stepping is
  unchanged.

### Step 7 — Audit every other `Tag_Free` writer to keep sentinel = 0

Code paths that produce `Tag_Free` headers and must keep `age = 0`
(coalescable):

1. Uniform page slicing in `populateFromBlock` (lines ~1117-1126). The
   `std::memset` zeros `age`; explicitly document `age = 0` here. Per
   Resolved Decision §1, uniform-page free cells are non-sentinel and rely
   on the `mid_cycle` / `fully_swept` guards already in place.
2. Heap-base sentinel at `installHeapBaseSentinel` (lines 273-280). It uses
   `pin = 1` and is parked at offset 0; `age = 0`. **Exempt** from the
   `age & 1` convention per Resolved Decision §7. Leave alone; document
   the exemption inline.
3. `padCellSlack` trailing free header (lines 550-562). `age = 0` after
   memset. Leave alone.
4. Mixed-block one-big-cell wrapper at `whole->header.tag = Tag_Free;`
   (line 999) and the post-sentinel split in the heap-base path (line 1009).
   `age = 0`.
5. Sweep's coalesced run flushing (via `pushCoalescedFreeCell` at line 2137,
   which calls `pushSpanOnFreeLists` with default `age_sentinel = false`).
6. `freeLargeBodyCell`'s `is_large` branch overlay at line 3848 (`hdr->tag
   = Tag_Free; hdr->size = ...`). The cell is parked in `free_large_blocks_`,
   not on a size-class free list; lazy sweep doesn't walk inside it. `age = 0`
   is fine. Add an explicit `age = 0` for hygiene.

The principle: only the `freeLargeBodyCell` regular-block path produces
sentinel cells. Every other writer leaves `age = 0`. Legal `age` values for
`Tag_Free` are exactly `0` and `1`; the high age bit (`0b10`) is reserved
and must remain 0.

### Step 8 — GCStats.hpp: refresh comment block

File: `runtime/src/allocator/GCStats.hpp`, the "Split-Header Large-Body
Minor-Reclaim Stats" block (lines 306-327).

- Update the description: the sweep early-returns only when compaction is in
  flight; major-GC mid-cycle no longer defers.
- Keep the four counters; clarify that
  `large_body_deferred_to_major_bytes` is now "bytes deferred until
  compaction completes, then drained on the next minor".

### Step 9 — Tests

1. Existing tests: run
   ```
   cmake --build build --target full 2>&1 | tee /tmp/test_output.txt
   ```
   to confirm no regressions. Watch for:
   - Stress-test E2E (`stress` suite) — the LOT=8K/16K bug family lives in the
     same area; any new regression is likely sentinel-related.
   - Any tests under `runtime/tests` exercising `OldGenSpace::sweep`.

2. New unit tests (under `runtime/tests/allocator/` if a similar test file
   already exists, otherwise extend the closest one):
   - **t1**: trigger a minor GC while `gc_phase_ == Marking`, ensure
     `sweepNurseryLargeBodies` frees a non-large body, verify the cell is
     present on the appropriate `free_lists_[cls]`, and the cell's header
     has `tag == Tag_Free`, `age & 1 == 1`.
   - **t2**: same as t1 but with `gc_phase_ == Sweeping` and
     `fully_swept[idx] == false` for the body's block. Then drive `lazySweep`
     to completion across that block; assert the sentinel cell's
     `(header, free-list link)` are intact (header.tag == Tag_Free,
     age & 1 == 1, the free-list pop returns the same address).
   - **t3**: trigger a minor GC while `compact_phase_ != Idle`. Verify the
     body remains in `nursery_owned_bodies_`, `large_body_minor_sweep_skips`
     incremented, `large_body_deferred_to_major_bytes` accounted.
   - **t4**: with `gc_phase_ == Sweeping` *and* `fully_swept[idx] == true`,
     free the body immediately and check `age & 1 == 0` (no sentinel needed
     because sweep won't re-walk).
   - **t5**: lazy-sweep coalescing test — adjacent dead non-`Tag_Free`
     objects continue to merge into a single coalesced cell, while a
     sentinel cell sandwiched between two dead runs splits them into two
     non-merged free cells.

3. Stress-soak: rerun a 60s+ session with `ECO_OLDGEN_DEBUG=1` and
   `LOT=8K` to catch any free-list invariant violation surfaced by the
   debug validator (see `bugs/C-lot-8K-alignment-investigation.md` and
   `project_lot8k_freelist_check.md` for context).

### Step 10 — Update the relevant invariants

File: `design_docs/invariants.csv`. Add or amend:

- **HEAP_026** (split-header bodies) — extend to say that bodies become
  reclaimable in all GC phases except compaction.
- A new **HEAP_xxx** ("free-cell sentinel"): for `Tag_Free` cells in old gen,
  `Header.age & 0b01 == 1` ⇒ already on a free list; lazy sweep must not
  coalesce or rewrite. Producers: `freeLargeBodyCell` regular-block path.
  Everywhere else `age & 0b01 == 0`.

## Files to touch

| File | Change |
| --- | --- |
| `runtime/src/allocator/Heap.hpp` | Comment the dual use of `Header.age`. |
| `runtime/src/allocator/OldGenSpace.hpp` | Add `isFreeCellSentinel` / `setFreeCellSentinel` / `clearFreeCellSentinel` helpers; update HEAP_026 comment. |
| `runtime/src/allocator/OldGenSpace.cpp` | Drop major-mid-cycle skip in `sweepNurseryLargeBodies`; sentinel-aware `freeLargeBodyCell`; thread `age_sentinel` through `pushSpanOnFreeLists`; sentinel-aware `lazySweep`. |
| `runtime/src/allocator/AllocatorCommon.hpp` | None (size handling unchanged). |
| `runtime/src/allocator/GCStats.hpp` | Refresh the split-header stats comment. |
| `runtime/tests/allocator/...` | New tests t1-t5 + stress sweep. |
| `design_docs/invariants.csv` | Update HEAP_026; new free-cell sentinel invariant. |

## Resolved decisions (incorporated above)

1. **Uniform-page free cells from `populateFromBlock`**: keep `age = 0`
   (non-sentinel). Justification: those pages are created either before a
   major GC (sweep not in progress) or as part of sweep coalescing, where
   the `mid_cycle` / `fully_swept` guards already prevent sweep from
   revisiting them. Sentinel is only needed when a free cell is created
   *mid-major outside sweep* and the block will continue to be walked by
   sweep this cycle. Step 7 already keeps `age = 0` here; this is the rule.

2. **Sentinel cells must NOT re-add to `garbage_bytes` in sweep.**
   `freeLargeBodyCell` is authoritative: it clears the mark bit, decrements
   `live_bytes`, increments `garbage_bytes` once (line 3884). Sweep's
   coalescing logic stays the way it is for non-sentinel runs (live ⇒ flush;
   non-sentinel dead ⇒ extend run, run-flush updates `garbage_bytes`).
   Sentinel cells are **structural boundaries only**: they flush any pending
   run *before* themselves, but neither extend a run nor add to
   `garbage_bytes`. The Step 6 pseudocode is hereby corrected: drop the
   `buffer_meta_[…].garbage_bytes += step` line for the sentinel branch.

3. **`large_body_index_` ownership.** Authoritative ownership transition for
   split-header bodies runs through `freeLargeBodyCell`. Major sweep's
   existing `large_body_index_.erase` calls (lines 2208-2218 / 2247-2257)
   are kept as **defensive idempotent guards** — they must NOT change the
   `LargeBodyId` lifecycle (don't push onto `free_large_body_ids_` from the
   sweep path; `freeLargeBodyCell` already does that). Add a comment at
   each defensive `erase` site noting that authoritative ownership runs
   through `freeLargeBodyCell` and that this branch is a no-op when
   `freeLargeBodyCell` got there first.

4. **`testAndClearMarkBitInBlock` and sentinel.** Sweep's liveness test
   already short-circuits on `Tag_Free`, so it never touches the mark bit
   of a sentinel cell. `freeLargeBodyCell` clears the bit before installing
   the sentinel (line 3872), so the cell carries bit = 0 through sweep and
   into the next cycle. The "post-sweep bitmap is all-zero" invariant is
   preserved. No code change required; document in Step 6.

5. **`large_body_deferred_to_major_bytes` field name**: do NOT rename. The
   field is internal, and renaming ripples through stat printers. Update
   the GCStats comment only (Step 8): "deferred" now means "deferred because
   compaction was in flight", not "because major GC was in progress".

6. **Reserved `age & 0b10` for `Tag_Free`**: explicitly document in
   `Heap.hpp` (Step 1) as *reserved for future use, must remain 0 in
   `Tag_Free` cells*. The convention written into the comment block:
   - `age & 0b01`: sentinel (already on free list).
   - `age & 0b10`: reserved; must be 0 for `Tag_Free`.
   For all `Tag_Free` writes today, write either `age = 0` (coalescable) or
   `age = 1` (sentinel) — never any other value.

7. **Heap-base sentinel exempt from the `age & 1` convention.**
   `installHeapBaseSentinel` (line 273-280) keeps `age = 0`. Sweep
   special-cases it via `isHeapBasePage` (line 2172-2181), so the sentinel
   bit would be redundant and risks conflating two different concepts
   ("heap base guard cell" vs "already on free list"). Document in Step 1
   (`Heap.hpp` comment) and Step 7 (audit checklist) that the heap-base
   sentinel is exempt and is identified by address/page-index, not by the
   age bit.

## Pre-implementation verification

Before writing code:

- **Test harness check**: build the existing allocator test target
  (`GCPressureTest.cpp` and friends in `runtime/tests/allocator/`) under the
  CMake config and run it once via the project's runner (ctest or the
  bespoke script). Confirm it is wired into the build. If not wired in,
  add a test target before adding the new t1-t5 tests.
- **Stat field name lock-in**: confirm no external dashboard/parser depends
  on the literal name `large_body_deferred_to_major_bytes` before editing
  the comment. (Internal-only; expected to be safe.)

## Stop point

This is the plan. No code changes have been made.
