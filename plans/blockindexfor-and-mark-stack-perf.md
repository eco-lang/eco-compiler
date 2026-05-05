# O(1) blockIndexFor + cached mark-stack indices + MarkContext

## Goal

Three independent perf fixes for the major-GC mark phase, each addressing a
specific finding from a recent profile / debug session:

1. **`blockIndexFor` falls through to a linear scan in some steady-state
   cases.** Replace last-write-wins page table with a two-owner-per-slot
   table and rebuild the table after `maybeShrinkCapacity` recomputes
   `region_base_` / `region_end_`.
2. **`blockIndexFor(obj)` is called twice per marked object** (once in
   `pushMarkRoot` to set the bit, once in `markOneObject` to attribute live
   bytes). Cache the index on the mark stack entry and pass it through.
3. **TLS-resolved `Allocator::instance()` / `getRootSet()` are called
   repeatedly during root collection / scan** (one per stackmap root). Bundle
   them into a single per-major-GC `MarkContext` resolved once and threaded
   through.

These three are loosely coupled but share a delivery vehicle (mark-time
infrastructure in `OldGenSpace`) so we plan them together. They can land as
three sequential commits to keep diffs reviewable.

## Background / what we found

### blockIndexFor

`OldGenSpace::blockIndexFor` (`runtime/src/allocator/OldGenSpace.cpp:539`)
maintains `page_to_block_index_`, a flat
`std::vector<size_t>` mapping each page slot
(`(p - region_base_) / page_size`) to a single owning block. Lookup is:

1. Check `[region_base_, region_end_)` membership.
2. Index the page table.
3. Verify the resolved block's `[start, end)` actually contains the address.
4. **Fallback: linear scan over `blocks_`.**

The defensive scan has been observed to hit in production. Two known causes:

- **Slot shadowing.** `assignPageIndexForBlock` overwrites the slot
  unconditionally. If two blocks are recorded as covering the same slot
  (e.g. via padding / boundary geometry on `is_large` reuse), the second
  write hides the first.
- **`region_base_` drift.** `maybeShrinkCapacity`
  (`runtime/src/allocator/OldGenSpace.cpp:2904-2916`) recomputes
  `region_base_` and `region_end_` after batch releases, but does not
  rebuild `page_to_block_index_`. The old slot indices now correspond to
  different physical address windows.

NOTE on the "two owners per slot" claim (resolved Q1): real heap geometries
DO produce two owners per page slot. A 512 KiB block can straddle two
page-sized slots, and its neighbour also intersects one of them — this is
inherent in using non-page-aligned block extents over page-sized slots and
cannot be fixed by rebuilding alone. The two-owner table is therefore
required for a scan-free `blockIndexFor`, not just a robustness measure.

### Mark stack double-lookup

Mark hot path:

- `pushMarkRoot(obj)` calls `blockIndexFor(obj)` once
  (`runtime/src/allocator/OldGenSpace.cpp:1751`), uses it to set the
  bit, then pushes only `obj` (a `void*`) onto `mark_stack`.
- `incrementalMark` pops `void*`s and calls
  `markOneObject(obj)` (`runtime/src/allocator/OldGenSpace.cpp:1597`).
  `markOneObject` then calls `blockIndexFor(obj)` AGAIN
  (`runtime/src/allocator/OldGenSpace.cpp:1793`) to attribute live bytes.

Caching the index on each stack entry eliminates the second call.

### TLS / RootSet repeated lookup

`ThreadLocalHeap::majorGC` (`runtime/src/allocator/ThreadLocalHeap.cpp:438`)
calls `nursery_.getRootSet()` four times during a single major GC and
`Allocator::instance()` once per stackmap root inside
`collectStackRootsFromStackMap` (line 660). Resolving these once at the top
and threading them through is a small, mechanical win — significant on
heavy stack-walk paths.

## Plan

### Step 1 — Two-owner page table + rebuild after shrink

**Files:** `runtime/src/allocator/OldGenSpace.hpp`,
`runtime/src/allocator/OldGenSpace.cpp`,
`test/allocator/OldGenLazySweepTest.cpp` (test-access type).

1. Define a `PageOwners { size_t primary; size_t secondary; }` struct in the
   `OldGenSpace` private section, near `page_to_block_index_`. Both slots
   default to `NO_BLOCK` (already defined at file scope in
   `OldGenSpace.cpp:167` — leave it there; do NOT shadow it inside the
   class).
2. Change `page_to_block_index_` to
   `std::vector<PageOwners>`.
3. Update `resizePageIndexForRegion` to grow with both owners set to
   `NO_BLOCK`.
4. Rewrite `assignPageIndexForBlock`:
   - For each covered slot, set the first empty owner (or the matching
     existing one) to `block_index`.
   - In `ECO_BIDX_DEBUG` builds, abort if a slot already has two distinct
     non-matching owners.
5. Rewrite `clearPageIndexForBlock` to clear whichever owner matches.
6. Add `void rebuildPageIndexFromBlocks()` private helper:
   - `resizePageIndexForRegion();`
   - Reset every slot to `{NO_BLOCK, NO_BLOCK}`.
   - For each `i` in `blocks_`, `assignPageIndexForBlock(i)`.
7. Call `rebuildPageIndexFromBlocks()` from EVERY path that mutates
   `region_base_` / `region_end_` after the initial setup. Centralise this
   by adding a helper `recomputeRegionBoundsAndRebuildIndex()` that
   computes new `region_base_`/`region_end_` from `blocks_` +
   `unassigned_blocks_` and then calls `rebuildPageIndexFromBlocks()`.
   Sites to convert (per `grep` of `region_base_ =` / `region_end_ =`):
   - `maybeShrinkCapacity` (`OldGenSpace.cpp:2915-2916`).
   - `reclaimAllDeadBlocksFromMeta` (`OldGenSpace.cpp:3309`).
   - `releaseBlockToAllocator`'s non-batch tail
     (`OldGenSpace.cpp:3194`).
   - The fixup-pass tail (`OldGenSpace.cpp:3237`).
   - `OldGenSpace.cpp:3621-3623` (compaction allocate-for-evac path).
   The grow paths at `OldGenSpace.cpp:1096-1098`, `1189-1191`, and
   `1469-1473` extend `region_end_` and call `assignPageIndexForBlock`
   for the new block, so they don't need a full rebuild — but we should
   confirm `resizePageIndexForRegion()` runs first.
   `initialize` and `reset` set bounds from scratch and already populate
   the index correctly via `assignPageIndexForBlock`; leave them alone.
8. Rewrite `blockIndexFor` to test `owners.primary` then `owners.secondary`.
   Behind `ECO_BIDX_DEBUG`, keep a linear-scan fallback that aborts with a
   diagnostic; in release builds, return `blocks_.size()` if both fail.
9. Update `OldGenSpaceTestAccess::getPageToBlockIndex` to return
   `const std::vector<PageOwners>&`, and forward-declare or qualify the type
   (`OldGenSpace::PageOwners`) where needed.
10. The `blockIndexFor agrees with linear scan after populate/release
    cycles` test (`test/allocator/OldGenLazySweepTest.cpp:206`) should keep
    passing without modification — it only uses the public test wrapper.

### Step 2 — Cache block index on mark-stack entries

**Files:** `runtime/src/allocator/OldGenSpace.hpp`,
`runtime/src/allocator/OldGenSpace.cpp`.

1. Define `struct MarkStackEntry { void* obj; uint32_t block_index; };` in
   the `OldGenSpace` private section near `mark_stack`. Use `uint32_t`
   (not `size_t`) so the entry packs to 16 bytes with natural alignment
   instead of 24; `blocks_.size()` is bounded by total committed pages
   and well within `uint32_t` range (consistent with the existing
   `CellHandle` convention). The "no block" sentinel becomes
   `static_cast<uint32_t>(-1)`; nursery entries use the same sentinel
   since they don't index into `blocks_`. Callers that compare against
   `blocks_.size()` need to widen / cast appropriately.
2. Change `std::vector<void*> mark_stack;` to
   `std::vector<MarkStackEntry> mark_stack;` in
   `OldGenSpace.hpp:501`.
3. In `pushMarkRoot` (`OldGenSpace.cpp:1736`):
   - Nursery branch: push `{obj, blocks_.size()}` instead of just `obj`.
   - Old-gen branch: compute `block_index = blockIndexFor(obj)` (which we
     already do), set the bit, and push `{obj, block_index}`.
4. Add an internal helper
   `void pushMarkRootWithBlock(void* obj, size_t block_index)` that skips
   the lookup. Use it from any caller that already has the index. (Optional
   for first cut — only useful if we adopt the same-block child
   optimisation in step 2.5 below.)
5. Add `bool markOneObject(void* obj, size_t block_index)` overload. Move
   the existing body into it; the original
   `markOneObject(void*)` becomes a wrapper that calls `blockIndexFor` and
   forwards. Keep the wrapper for non-stack callers (only one currently:
   the lazy-sweep call at `OldGenSpace.cpp:607`, which already has no
   cached index).
6. In `incrementalMark` (`OldGenSpace.cpp:1594-1598`), pop a
   `MarkStackEntry` and call
   `markOneObject(entry.obj, entry.block_index)`.
7. In the new `markOneObject(obj, block_index)`, skip the second
   `blockIndexFor` call — use the cached `block_index` for the
   `buffer_meta_` attribution at `OldGenSpace.cpp:1793-1799`. Recompute
   only on the nursery branch (which doesn't use the index anyway).
8. (Optional, defer to a follow-up unless trivial) Threading the parent's
   block index into `markChildren` lets us call `pushMarkRootWithBlock` for
   intra-block children. This requires checking `child >= blk.start &&
   child < blk.end` per child, which adds a branch — likely a wash. Skip
   unless profiling shows the per-child `blockIndexFor` is hot.

### Step 3 — MarkContext for one-shot TLS resolution

NOTE (resolved Q4): the inner mark loop already uses cached
`allocator_ref_` and the helpers (`markChildren`, `markHPointer`,
`markUnboxable`) don't reach for TLS. The ~7% TLS hit observed in the
profile is concentrated in major-GC startup and root scan, not the per-
object loop. Step 3 is therefore primarily a hoist of TLS calls in
`ThreadLocalHeap::majorGC` and `collectStackRootsFromStackMap`; the
`MarkContext` plumbing into `OldGenSpace` is mostly future-proofing.

**Files:** `runtime/src/allocator/OldGenSpace.hpp`,
`runtime/src/allocator/OldGenSpace.cpp`,
`runtime/src/allocator/ThreadLocalHeap.cpp`.

1. Define `struct MarkContext { Allocator* alloc; RootSet* roots; };` in
   `OldGenSpace.hpp` near the marking-state region (forward-declare
   `RootSet` if needed). Skip `GCStats*` for now — `GCStats& stats` is
   already passed explicitly to all the stats-emitting entry points and we
   don't want to duplicate that channel.
2. Add `MarkContext* current_mark_ctx_;` to `OldGenSpace`'s private state
   (initialise to `nullptr` in the constructor / reset paths).
3. Add a `MarkContext&` parameter to the existing `startMark` overloads
   ONLY (resolved Q3). Keep `incrementalMark` / `finishMarkAndSweep`
   signatures unchanged to minimise call-site churn; they read the
   stored `current_mark_ctx_` instead. There are no test-accessor
   wrappers for `startMark`, so the only direct caller is
   `ThreadLocalHeap::majorGC`.
4. In `ThreadLocalHeap::majorGC` (`ThreadLocalHeap.cpp:438`):
   - Resolve `RootSet& rs = nursery_.getRootSet()` ONCE at the top.
   - Build `MarkContext ctx{ &*parent_, &rs };` (or pass in the existing
     `*parent_` reference; we already have `Allocator&`).
   - Pass `ctx` into `startMark`.
   - Replace the four direct `nursery_.getRootSet()` calls with `rs`.
5. In `collectStackRootsFromStackMap` (`ThreadLocalHeap.cpp:660`), hoist
   `Allocator& alloc = Allocator::instance();` above the loop. The current
   code resolves it inside the per-stack-frame loop body.
6. Inside `OldGenSpace`, store `current_mark_ctx_ = &ctx` in `startMark`
   and clear it in `finishMarkAndSweep` (both overloads). Marking helpers
   that use `allocator_ref_` continue to do so unchanged — it's already
   cached and not TLS. The MarkContext exists for paths that today reach
   for `Allocator::instance()` / `getRootSet()` afresh; if we find none in
   the per-object hot path, this step is mostly defensive plumbing for
   future helpers.

NOTE: the original design memo over-claimed about TLS in the per-object
inner loop. The real wins are:

- One `Allocator::instance()` per major GC instead of per stackmap root.
- One `getRootSet()` per major GC instead of four.
- A clean place to add future TLS-cached state without touching call sites
  again.

If on closer reading there's no measurable per-object TLS to eliminate,
step 3 reduces to the small hoist (#5) plus the four-into-one
`getRootSet()` (#4) — with the `MarkContext` struct deferred.

### Test plan

- Existing `test/allocator/OldGenLazySweepTest.cpp` page-index test
  continues to pass (covers step 1 correctness).
- Add a new test that exercises the shrink path: allocate enough to grow
  multiple pages, drop roots, run major GC twice, verify
  `OldGenSpaceTestAccess::blockIndexFor` agrees with a linear scan AFTER
  the shrink. (This catches the rebuild-after-region_base-drift bug.)
- Mark-stack change is invisible from the outside; rely on existing GC
  test coverage and `cmake --build build --target full` for E2E
  validation.
- For `MarkContext`: no behavioural change expected; rely on full-test
  pass plus a perf check via `[gc-profile]` to confirm no regression.

## Resolved questions

All seven design questions resolved with the user. Summary:

- **Q1** — Two-owner table is required; geometries do produce overlapping
  page slots when 512 KiB blocks straddle 512 KiB page boundaries.
- **Q2** — Multiple sites mutate `region_base_`/`region_end_`; centralise
  via `recomputeRegionBoundsAndRebuildIndex()` (see Step 1.7).
- **Q3** — Add `MarkContext&` to `startMark` only; store it for use by
  the unchanged `incrementalMark` / `finishMarkAndSweep`.
- **Q4** — Per-object mark loop is NOT TLS-bound; step 3 reduces to a
  hoist in `ThreadLocalHeap::majorGC` + `collectStackRootsFromStackMap`.
  `MarkContext` is structural future-proofing.
- **Q5** — Defer the same-block child optimisation; reprofile after
  steps 1+2 land.
- **Q6** — Use `uint32_t block_index` to keep `MarkStackEntry` at 16 B
  with natural alignment (consistent with `CellHandle`'s 65535-block
  bound).
- **Q7** — Keep `markOneObject(void*)` as a cold wrapper that calls
  `blockIndexFor`; the hot path (mark-stack drain) always supplies the
  index from `MarkStackEntry`. Sole non-stack caller is the
  `OldGenSpace.cpp:607` lazy-sweep adjacent path; running through
  `blockIndexFor` once there is fine.

## Open items for implementation review

- Confirm by inspection that the grow paths (`OldGenSpace.cpp:1096`,
  `1189`, `1469`) call `resizePageIndexForRegion()` BEFORE
  `assignPageIndexForBlock()` so a freshly-extended `region_end_` has
  index slots to write into. If not, add the call.
- Decide commit ordering: ship Step 1 (two-owner + rebuild) on its own
  first, since it fixes correctness drift; then Step 2 (mark-stack
  cache); then Step 3 (TLS hoist + MarkContext shell). Each commit
  should pass `cmake --build build --target full` independently.
