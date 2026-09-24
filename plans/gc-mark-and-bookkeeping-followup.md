# Plan: GC mark-path and old-gen bookkeeping follow-up (working-list items 38–54)

> **STATUS: COMPLETE — 2026-09-23. All eleven items dispositioned.** Run through
> `benchmarks/gc-opt-loop.md`; the entries and evidence are in its §6 and the outcome table in
> its §0. Summary: **item 40 WIN** (-1.83 s wall, -0.78 s GC; needed an arena re-pack this plan
> did not anticipate), **item 54 WIN, FIFO variant** (mark -12.1 %), **items 51 + 43 shipped
> flat**, **items 47, 42, 45, 46 closed unbuilt** (47 by reading, the rest on arithmetic),
> **items 44, 52, 38 refuted and reverted**.
>
> Three premises in this file are WRONG as written and would have caused defects, not just
> misses — corrected in the loop's §6 entries, flagged here at their items: **item 43's single
> write site**, **item 40's single block-removal path**, **item 44's "the per-item path already
> covers it"**. Item 38 should no longer be cited as the prerequisite for working-list #60.
>
> Parallel-marking prerequisites after this plan: **#58 is unblocked** (item 40's flat array
> landed). #59 (per-worker `live_bytes`) inherits a refuted premise from item 52 — the RMW it
> would batch is not a cache miss. #60 (per-worker visited bitmaps) needs a new design.

Successor to `plans/gc-tier1-constant-factors.md`. It lowers the eleven Tier-1 items that
`benchmarks/gc-opt-loop.md` never built: the whole of its **W8** package (38, 40, 51, 52, 54)
and the **W9 tail** (42–47) that was left "not attempted" after item 41 measured flat.

**Every line number and premise below was re-verified against the tree on 2026-09-23.** The
parent plan's citations had drifted by the time the loop ran, and the loop's own findings
section records that *"the same drift applies to its premises, not just its citations."* Three
premises in this list had already drifted too — they are corrected in place and flagged
**PREMISE CORRECTED**.

---

## 0. Why this list is worth revisiting at all

The loop closed by concluding that constant-factor work was exhausted and only parallel
marking remained. **W1 then found −14.54 s of GC time in exactly that territory** — more than
all eleven measured packages combined — by deleting a bulk memset rather than making a loop
cheaper. So "the arithmetic bound is small" should not be read as "closed".

Two facts shape the ordering below, both from the loop's own record:

- **Pure deletions have been flat-to-positive every time.** W0, W2, W5, W9, W10 all kept.
- **Restructure-to-remove-a-scan has lost every time it was measured**: item 24 (+3.16 s GC),
  W4 (+1.96 s GC), W6 (+77.5 s wall). Three for three.

Of the eleven items here, **44, 43, 47, 51** are deletions and **40, 38, 52, 54, 42, 45, 46**
are restructures. The deletions go first.

One item is not judged on its own delta at all: **40 gates parallel marking** (working-list
#58 needs an atomic mark-bit set, which needs a flat array). Even a flat 40 is worth landing.

---

## 1. Work packages

| package | items | shape | basis |
|---|---|---|---|
| **W11** — cheap deletions | 51, 44, 43, 47 | deletion | 44 is a bulk memset; rest are bounds |
| **W12** — mark-path data structures | 40, 38, 52 | restructure | mark = 92.4 % of major GC |
| **W13** — prefetch | 54 | restructure | needs 40 |
| **W14** — old-gen tail | 42, 45, 46 | restructure | bound, low value |

Sequencing:

```
W11: 51 ─► 44 ─► 43 ─► 47          (independent, but land the deletions first)
W12: 40 ─┬─► 38                    (40 first: it is the gate, and 38/52 read cleaner after)
         ├─► 52
         └─► W13: 54               (54 wants 40's flat probe to be worth prefetching into)
W14: 42, 45, 46                    (independent; lowest value, do last or not at all)
```

**40 → #58 → parallel marking** is the reason this plan exists at all. If only one package
lands, it should be W12.

---

## 2. W11 — the deletions

### Item 51 — inline `Allocator::isInNursery`

> **OUTCOME: SHIPPED (W11a), flat.** Premise correct; unmeasurable at this scale.


**Today.** `Allocator.cpp:462`:

```cpp
bool Allocator::isInNursery(void *ptr) {
    return tl_heap_ && tl_heap_->isInNursery(ptr);
}
```

`ThreadLocalHeap::isInNursery` is already inline (`ThreadLocalHeap.hpp:220`,
`nursery_.contains(ptr)` — two range compares). So the entire cost is an out-of-line cross-TU
call with no LTO, executed **twice per marked object**: `OldGenSpace.cpp:1810` (`pushMarkRoot`)
and `:1865` (`markOneObject`).

**Change.** Move the body into `Allocator.hpp` as an inline member. The complete
`ThreadLocalHeap` type is required, and **`Allocator.hpp` already `#include`s
`ThreadLocalHeap.hpp` at the bottom for exactly this reason** — `getRootSet()` is defined
out-of-line there with a comment explaining the pattern (`Allocator.hpp:529-535`). Follow it:
declare `bool isInNursery(void *ptr);` in the class, define it after the include.

**Traps.** `tl_heap_` is the TLS heap pointer; keep the null check — cold callers run before
`initThread`. Do not change the signature to `const` without checking every caller.

**Expected.** Two calls × ~700 M marked objects per run. Pure call-overhead removal.
**Gate:** counters bit-identical.

---

### Item 44 — stop bulk-zeroing the mark bitmaps

> **OUTCOME: REFUTED (W11b), reverted. PREMISE WRONG.** Sweep does NOT leave the bitmap
> all-zero: the validate assert this plan asked for fired on the 2nd major GC of a self-compile,
> on a block with `fully_swept=1`, and the mid-cycle free-list pop this plan blames is not the
> cause. The bulk clear is load-bearing for a second, undocumented reason. See loop §6 W11b.


**This is the highest-value item in W11 and the one the loop explicitly flagged.** It is
structurally the same shape as the W1 win: delete a bulk memset that a per-item path already
covers.

**Today.** `OldGenSpace.cpp:1568-1573`, at the start of every mark cycle:

```cpp
for (auto& bits : mark_bits_) {
    std::fill(bits.begin(), bits.end(), 0);
}
std::fill(large_block_mark_.begin(), large_block_mark_.end(), 0);
```

`testAndClearMarkBitInBlock` (`OldGenSpace.hpp:1049`) exists **specifically** to make this
unnecessary — its comment says *"Used by sweep so that the bitmap is left all-zero post-sweep
(precondition for the next mark cycle to skip bulk-zeroing)."*

**The code already documents exactly why the precondition fails** (`:1560-1567`): the
"bitmap is zero between cycles" invariant holds only when sweep visits every cell, and it does
not when the mutator pops a cell off a free list **mid-sweep**. `initObjectHeaderWithSize`
(`:391-401`) sets the bit for that cell:

```cpp
if (marking_active || gc_phase_ != GCPhase::Idle) {
    hdr->color = static_cast<u32>(Color::Black);
    if (contains(obj)) {
        const size_t block_index = blockIndexFor(obj);
        if (block_index < blocks_.size()) {
            setMarkBitInBlock(block_index, obj);
```

If sweep has already advanced past that block it never revisits, so the bit carries over. The
recorded consequence is severe and is worth quoting because it is the reason this must not be
done casually: the carry-over bit makes `pushMarkRoot` return early next cycle, so
`markOneObject` never runs, the cell's bytes are never attributed to `live_bytes`, the block
looks all-dead, and `madvise(DONTNEED)` zero-fills pages other objects still reference.

**Change — clear only the blocks that can actually be dirty.**

1. Add `std::vector<uint32_t> marks_dirty_blocks_;` plus `std::vector<uint8_t>
   marks_dirty_flag_;` (indexed by block, to dedupe pushes) as `OldGenSpace` members.
2. In `initObjectHeaderWithSize`, at the point where `setMarkBitInBlock` is called, record the
   block **only when sweep can no longer reach it** — i.e. when
   `buffer_meta_[block_index].fully_swept` is true, or `gc_phase_ == GCPhase::Sweeping &&
   block_index < sweep_buffer_index_`. If sweep will still walk the block, its
   `testAndClearMarkBitInBlock` cleans up and nothing need be recorded.
3. Replace the loop at `:1568` with a walk of `marks_dirty_blocks_`, `std::fill`-ing only
   those bitmaps, then clear both vectors.
4. Keep `std::fill(large_block_mark_...)` as-is unless profiling says otherwise — it is one
   byte per block, not a bitmap.
5. Resize `marks_dirty_flag_` wherever `mark_bits_` is resized, and clear both in `reset()`.

**Correctness gate specific to this item.** The dangerous failure is silent: a stale bit
causes under-attribution of `live_bytes` and then a wrongly released block. Add a
`ECO_HEAP_VALIDATE`-only check at the top of the mark cycle that, **after** the targeted
clear, asserts every bitmap is all-zero — i.e. re-derive the old invariant and assert it
rather than trusting the analysis. Run it over the self-compile (6 majors) and the stress
suite. Remove the assert only once it has been green across both.

**Expected.** `mark_bits_` totals one bit per 8 bytes of committed old gen: on a ~5 GB heap
that is ~80 MB of bitmap zeroed per major, ~6 majors per self-compile ⇒ ~0.5 GB of writes.
Smaller than W1's 246 GB by two orders of magnitude, so **expect flat on wall** — keep it for
the deletion, and because it removes an O(heap) step from the mark prologue that parallel
marking would otherwise inherit.

---

### Item 43 — don't walk every free cell in `transitionToSweeping`

> **OUTCOME: SHIPPED (W11a), flat. PREMISE WRONG — READ THIS BEFORE TRUSTING A LINE NUMBER.**
> There are TWO sentinel write sites, not one, and the `:2407` named below is the wrong one: it
> writes the trailing remainder header, which is never LINKED onto a free list and so can never
> appear in the walk this item skips. The linked site is `:2341` in `placeAndLink`. Counting at
> `:2407` would have skipped the walk while sentinels were live on the lists.


**Today.** `OldGenSpace.cpp:2505-2513`:

```cpp
for (size_t i = 0; i < NUM_SIZE_CLASSES; i++) {
    for (FreeCell* c = free_lists_[i]; c != nullptr; c = c->next_in_class) {
        if (c->header.age == 0b01) c->header.age = 0;
    }
    free_lists_[i] = nullptr;
}
```

It walks **every free cell in the heap** to downgrade a rare "on free list" sentinel
(`age == 0b01`), and then discards the lists it just traversed. The sentinel exists so sweep
does not coalesce a cell that is still on a list; after the head wipe none are, so it must be
cleared or sweep treats each as a hard run boundary and leaks its bytes.

Sentinel cells originate from only two places, both named in the comment: `freeLargeBodyCell`
and `splitter::remainder` mid-sweep pushes.

**Change.** Maintain `size_t free_list_sentinel_count_`. **There is exactly ONE write site**
(verified 2026-09-23): `OldGenSpace.cpp:2407`, inside the span-header writer, guarded by its
`age_sentinel` parameter:

```cpp
if (age_sentinel) hdr->age = 0b01;
else              hdr->age = 0;
```

- increment in that `if`, which makes the counter trivially correct at the producing end;
- decrement in `transitionToSweeping` as each is downgraded;
- skip the inner walk entirely when the count is zero and just null the heads.

**Trap.** The counter must be decremented on *every* path that clears the sentinel, including
cell reuse via `finalizePoppedCell` (which memsets the header). A missed decrement makes the
counter drift upward, which is safe (you just do the walk) — a missed **increment** is not.
Prefer to over-count: initialise conservatively and only skip on an exact zero.

**Expected.** Runs once per major GC (~6 per self-compile). Below the noise floor by
arithmetic; it is a deletion, judged as one.

---

### Item 47 — drop the defensive `large_body_index_` lookup in the sweep inner loop

> **OUTCOME: CLOSED UNBUILT by reading (W11a) — it is LOAD-BEARING.** A split-header body below
> `alloc_buffer_size` lands in an ordinary size-class block, so the inner-loop copy at `:2685` is
> reachable. `OldGenSpace.hpp:568`'s "idempotent guards only" is about accounting authority, not
> reachability.


**PREMISE CORRECTED.** The working list says "a `large_body_index_.find` per pinned
string/bytebuffer cell". In the current tree (`OldGenSpace.cpp:2637-2648`) the `find` is
already guarded:

```cpp
Header* hdr = reinterpret_cast<Header*>(sweep_cursor_);
if (hdr->pin && (hdr->tag == Tag_String || hdr->tag == Tag_ByteBuffer)) {
    auto it = large_body_index_.find(sweep_cursor_);
```

so it runs only for a **pinned** `String`/`ByteBuffer` cell in a dead block — far rarer than
"per cell". A second copy of the same shape sits at `:2685-2696`.

**Change.** Two options, and the measurement is the same either way:

- If the guard is genuinely idempotent-defensive (its own comment says so), move both `find`
  blocks behind `#if ECO_HEAP_VALIDATE` and assert there that the entry is absent.
- If it is load-bearing (i.e. sweep really can reach a body cell before
  `promoteLargeHeader`/`sweepNurseryLargeBodies` retire it — which the comment at `:2632`
  asserts it can), then it must stay, and this item is **closed unbuilt**.

**Resolve by reading before building.** Establish whether a pinned body cell can reach sweep
with a live `large_body_index_` entry. If yes, close the item and record why — that is a
cheaper outcome than a build cycle, and six items in the parent loop were closed exactly this
way.

---

## 3. W12 — mark-path data structures

Mark is **92.4 % of major-GC time** and fully stop-the-world. These three items all remove
memory-system work from the per-marked-object path.

### Item 40 — flatten `mark_bits_` into one arena *(the gate)*

> **OUTCOME: WIN, SHIPPED (W12b).** -1.83 s wall, -0.78 s GC, counters bit-identical.
> TWO corrections: (1) the trap list names only `releaseBlock`'s swap-remove — compaction also
> removes blocks via `vector::erase` at `:4190`, and missing it desynchronises the offset array;
> (2) an append-only arena leaks holes as blocks are released (+172 MB RSS measured). The fix is
> to re-pack at the mark prologue, the one point where every bitmap is about to be zeroed anyway.


**Today.** `OldGenSpace.hpp:522`:

```cpp
std::vector<std::vector<uint8_t>> mark_bits_;
std::vector<uint8_t>              large_block_mark_;
```

Every mark-bit operation chases a pointer to the inner vector and then bounds-checks. The four
primitives are already inline in the header (`OldGenSpace.hpp:1004-1064`): `markBitLocation`,
`isMarkedInBlock`, `setMarkBitInBlock`, `testAndClearMarkBitInBlock`. Each does
`mark_bits_[block_index]` (bounds branch + load of the inner vector's data pointer) then
`byte_index >= bits.size()` (second bounds branch) before touching a bit.

`pushMarkRoot` calls `isMarkedInBlock` **then** `setMarkBitInBlock` (`:1824-1825`) — two full
lookups for one logical test-and-set.

**Change.**

1. Replace with one arena plus a per-block offset:
   ```cpp
   std::vector<uint8_t>  mark_bits_arena_;   // all blocks' bitmaps, back to back
   std::vector<uint32_t> mark_bits_offset_;  // byte offset of block i's bitmap
   std::vector<uint32_t> mark_bits_len_;     // bytes of block i's bitmap (0 for is_large)
   ```
   Keep `large_block_mark_` as it is.
2. Rewrite the four primitives against the arena. The existing `markBitLocation` already
   computes `(byte_index, mask)` from the block start and `MARK_ALIGNMENT`; only the
   dereference changes:
   `uint8_t* p = mark_bits_arena_.data() + mark_bits_offset_[i] + byte_index;`
3. **Collapse `isMarkedInBlock` + `setMarkBitInBlock` in `pushMarkRoot` into one
   `testAndSetMarkBitInBlock`** returning "was already set". This is half the win and is only
   possible once the lookup is cheap enough to be obviously worth fusing.
4. Handle resize. Blocks are added and released dynamically, and
   `allocateFromEmptyRegularBlocks` (`:1447-1450`) *clears* a block's bitmap when flipping it
   to `is_large`. With an arena, "clear" means zero the range and set `mark_bits_len_[i] = 0`;
   the arena slot is retained, not reclaimed. Append-only offsets keep this simple: growing
   the arena on a new block is a `resize`, and released blocks leave a hole. If hole
   accumulation matters, rebuild the arena at `reset()`.
5. Preserve the invariant asserted in the header comment:
   `mark_bits_.size() == large_block_mark_.size() == blocks_.size()` becomes
   `mark_bits_offset_.size() == mark_bits_len_.size() == large_block_mark_.size() ==
   blocks_.size()`.

**Traps.**

- **Two** test/debug accessors expose the type (`OldGenSpace.hpp:1308` `getMarkBitsForBlock`
  returning `mark_bits_[i]`, and `:1311` `getMarkBits` returning the whole
  `vector<vector<uint8_t>>`). A repo-wide grep finds **no users outside the header today**, so
  both can be reshaped to return a `span`-like view over the arena, or deleted — check again
  at implementation time rather than trusting this note.
- The `byte_index >= bits.size()` guard currently returns `false` for out-of-range slots.
  Some callers rely on that (objects outside the block's bitmap extent). Keep the equivalent
  check against `mark_bits_len_[i]` — do not drop it as "obviously impossible".
- Do not change `MARK_ALIGNMENT` or the bit layout in the same step; this is a container
  change only, so the bitmap content must be bit-identical.

**Expected.** Two loads and up to four bounds branches per bit op become one add and one
bounds branch. Per marked object that is at least one dependent load removed on the critical
path, and `pushMarkRoot`'s double lookup becomes single. **Judge on GC time, not wall.**

**Why it lands even if flat:** working-list #58 (atomic mark-bit set for parallel marking)
requires a flat array — `lock or` on a `vector<vector<>>` element means resolving the inner
pointer under contention. This is the prerequisite the loop's own closing line names.

---

### Item 38 — replace `nursery_visited_` with a bitmap

> **OUTCOME: NO WIN (W12d), reverted — mark +415 ms (+5.8 %).** The set is SPARSE against a
> ~512 MB nursery span, so the 8 MB bitmap has a worse working set than the hash nodes. Banked:
> max RSS is 45 MB lower without the set, so an arena-allocated or open-addressed set is the
> promising direction. Do NOT cite this item as the prerequisite for #60.


**Today.** `OldGenSpace.hpp:486`: `std::unordered_set<void *> nursery_visited_;`, used in
`pushMarkRoot` (`:1810-1815`):

```cpp
if (allocator_ref_->isInNursery(obj)) {
    if (nursery_visited_.insert(obj).second) {
        mark_stack.push_back(MarkStackEntry{obj, NO_BLOCK_U32});
    }
    return;
}
```

One hash and potentially one malloc per distinct live nursery object reached during the major
mark pause. It exists because major GC must not write `color` into nursery headers (minor GC
owns them), so the set is the only cycle-breaker for nursery traversal.

**Change.** A side bitmap over the nursery extent, one bit per `MARK_ALIGNMENT` slot:

1. The nursery is a contiguous extent per thread (HEAP_042/043), so
   `(obj - nursery_base) / MARK_ALIGNMENT` is the bit index — the same arithmetic
   `markBitLocation` already does for old gen.
2. Size it from the nursery's committed capacity; reallocate on `checkAndGrow`, or size to
   `nursery_max_block_count` once and never resize (simpler, and the cap is known).
3. `nursery_visited_.clear()` at `:1578` becomes a `std::fill` of the bitmap — which is
   O(nursery/64) and runs ~6 times per self-compile, so it does not reintroduce item 44's
   problem at any meaningful scale.
4. Keep the API shape: a `testAndSetNurseryVisited(obj)` returning "was already visited" maps
   one-to-one onto the `insert(...).second` idiom, so `pushMarkRoot` barely changes.

**Traps.**

- The set is keyed on arbitrary interior-free object pointers; confirm every insert is
  8-byte-aligned and inside the nursery extent before indexing. Assert under
  `ECO_HEAP_VALIDATE`.
- Minor GC moves nursery objects. The bitmap is only valid within one major mark; it is
  already cleared per cycle, but if a minor GC can run *during* an incremental major mark,
  addresses shift and both the set and a bitmap are equally invalid. Check
  `gc_phase_`/`marking_active` interaction before relying on this — the parent list notes
  `gc_phase_` is never set to `Marking`, so incremental marking may be unreachable today
  (Tier-3 dead-code finding). **Confirm which of the two applies before building.**

**Expected.** Removes a hash and a possible allocation per distinct live nursery object from
inside the STW pause. Also the prerequisite for #60 (per-worker visited bitmaps).

---

### Item 52 — accumulate `live_bytes` locally instead of a scattered RMW

> **OUTCOME: NO WIN (W12c), reverted — mark +33 ms.** Premise refuted: `buffer_meta_` is ~2 MB
> and mark has per-block run locality, so the "third random cache line" was already resident.


**Today.** `OldGenSpace.cpp:1903`, in `markOneObject`:

```cpp
buffer_meta_[blk_idx].live_bytes += step;
```

A read-modify-write into a per-block metadata array, per marked object — a **third random
cache line** touched per object, on top of the object header and the mark bit.

**Change.** The mark stack is drained in `incrementalMark` (`:1633-1637`), which pops in LIFO
order, so consecutive objects are *not* reliably from the same block. Two options:

- **(a) Last-block cache.** Keep `uint32_t last_blk_; size_t last_blk_bytes_;` in the drain
  loop; when `blk_idx == last_blk_` accumulate locally, otherwise flush and switch. Cheap,
  and captures the run-locality that survivor copying tends to produce. Degrades to today's
  behaviour when blocks interleave.
- **(b) Deferred per-block accumulator.** A `std::vector<uint32_t>` sized to `blocks_`, summed
  into `buffer_meta_` at the end of mark. Removes the RMW entirely but adds a second array of
  the same shape — which is the cache line you were trying to avoid, unless it is denser.

Prefer **(a)**: it is strictly less machinery, and (b)'s benefit depends on the accumulator
being hotter than `buffer_meta_`, which is unproven.

**Trap.** `live_bytes` is also written outside mark — `initObjectHeaderWithSize` (`:401`) and
`allocateFromEmptyRegularBlocks` (`:1443`). A local accumulator must be flushed before any of
those can observe the field, i.e. before mark ends. If incremental marking ever becomes
reachable, flush at every `incrementalMark` return, not just at completion.

**Expected.** One random write per marked object removed, but this is a **restructure** and
the loop's record on those is 0 for 3. Measure alone, not stacked with 40.

---

## 4. W13 — prefetching

### Item 54 — prefetch in the mark loop

> **OUTCOME: WIN, SHIPPED — the FIFO variant (W13c), depth 16.** Both variants were built.
> Prefetch-on-grey (W13) won mark -141 ms; the FIFO ring then beat IT by a further **-789.6 ms
> (-10.4 %)**, for -12.1 % against no prefetch — the largest mark-path win in either plan.
>
> **This plan's reason for preferring on-grey is refuted.** It warned the FIFO "changes traversal
> order ... and therefore possibly `out.mlir`". It cannot: Elm exposes no pointer identity, so
> nothing the compiler computes can depend on trace order. Output is byte-identical, verified.
>
> The variable was DISTANCE, not hint count: LIFO gives on-grey a distance of ~1 for the last
> child pushed, while the ring fixes it at 16 objects (~660 ns of cover at 41.3 ns/object). The
> real hazard is not ordering but the ring's in-flight entries — `incrementalMark` reports
> completion via `!mark_stack.empty()`, so the ring MUST be drained before every return or live
> objects are swept. One collection (68 % survival) is 6 % slower: prefetch pays in proportion to
> the miss rate. A survival-ratio-adaptive depth is the open follow-up.


**Today.** `OldGenSpace.cpp:1633-1637` is the entire drain:

```cpp
while (!mark_stack.empty() && units_done < work_units) {
    MarkStackEntry entry = mark_stack.back();
    mark_stack.pop_back();
    if (markOneObject(entry.obj, entry.block_index)) ++units_done;
}
```

No prefetching anywhere on the mark path. Mark is latency-bound pointer chasing, which is what
prefetch targets.

**Change.** The handbook recipe (`gc_handbook/02-mark-sweep.md §2.6`): a small FIFO between
the mark stack and the scan. Pop into a ring of 8–32 entries; on push, issue
`__builtin_prefetch` for the object header (and, once item 40 lands, for its mark-bit byte);
process the entry that falls out the far end. Depth is the tunable — start at 16 and sweep
8/16/32 in one binary via a `HeapConfig` knob, the way W7 did with `minor_sweep_divisor`.

**Traps.**

- The FIFO changes traversal order (it delays processing by `depth` objects). Mark order is
  not semantically load-bearing, but it **will change allocation order of anything the mark
  triggers** and therefore possibly `out.mlir`. If output stops being byte-identical, that is
  a red flag to investigate, not to accept.
- Prefetch-on-grey (issue the prefetch at `pushMarkRoot` time rather than at pop) is the
  cheaper variant and does not reorder anything. **Try that first.**

**Do item 40 first.** Prefetching the mark bit is only worth an instruction slot if the bit's
address is one add away; through `vector<vector<>>` the prefetch itself needs a dependent load.

**Disposition risk.** This is an add-work-to-save-misses change, the class that has now lost
twice in this series (item 53 was skipped for exactly this reason, W4 lost). Budget one
measurement and revert quickly.

---

## 5. W14 — old-gen bookkeeping tail

> **OUTCOME: ALL THREE CLOSED UNBUILT on arithmetic.** The Major GC Event Log accounts for 100 %
> of major-GC time, and everything 42 and 46 touch is inside the **491 ms** sweep bucket — 0.27 %
> of a 181.71 s run. All three add an index or a header field rather than deleting a scan, and two
> sit on paths with a documented corruption history. See loop §6 W14.

The loop did not attempt these because item 41 showed the scans they target are themselves
below the noise floor. They are documented here so they are not lost, with honest expectations.

### Item 42 — stop scanning whole indexes per released block

`OldGenSpace.cpp:3292-3302` iterates **the entire `large_body_index_` hash map** for each
released block, to drop entries whose `body_base` falls inside it. `releaseBlockToAllocator`
is called in a loop by `reclaimAllDeadBlocksFromMeta` and `maybeShrinkCapacity`, so the cost
is O(released × |index|). A linear scan of `free_large_blocks_` sits at `:1377-1385`.

**Change.** Give `BlockInfo` (or a parallel array) a small `std::vector<LargeBodyId>` of the
bodies based in that block, maintained where `large_body_index_` is inserted into and erased
from. Release then walks only that block's list. The comment at `:3271-3288` documents a real
past corruption (`bugs/C-lot-8K-alignment-investigation.md` v15) that this cleanup prevents —
**preserve the behaviour exactly**, including the `ECO_HEAP_VALIDATE` class-4 assert that
follows it, which is what would catch a missed entry.

**Expected.** Large bodies are rare; `|large_body_index_|` is small. Low value. Do last.

### Item 45 — index the empty-block search

`OldGenSpace.cpp:1421`: `for (size_t i = 0; i < blocks_.size(); ++i)` per large allocation,
looking for a fully-swept, zero-live regular block. Replace with a maintained free-block list
or a bitmap over `blocks_`, updated wherever `fully_swept`/`live_bytes` transition.

**Expected.** Thousands of blocks on a 5 GB heap, but large allocations are rare. Low value;
the risk is keeping the index coherent across sweep, release and the `is_large` flip.

### Item 46 — remove per-object large-body map lookups

`markLargeBodySeen` (`:4330`) does an `unordered_map` lookup per split-header scanned;
`promoteLargeHeader` (`:4345`) linearly scans `nursery_owned_bodies_` per promoted split
header.

**The loop's objection stands and should be read before starting.** The natural fix wants a
`LargeBodyId` stored in the header, which means claiming ~15 bits of `Header.refcount` plus an
overflow-sentinel scheme — substantial header surgery, and it **collides with working-list
item 32**, which wanted the same bits and was closed by arithmetic (0.36 % of scanned objects
are pointer-free against a ≥15 % gate). If those bits are ever split, do it once, deliberately,
for both consumers. **Recommend: leave closed unless the header is being reworked anyway.**

---

## 6. Method, gates and tooling

This plan is run through `benchmarks/gc-opt-loop.md` unchanged — one package per iteration,
three cold self-compiles, judged on **GC time** against the last WIN, with determinism and
fixed-point checked before any number is read.

Tooling that did not exist when the parent plan was written and that these items should use:

- **`benchmarks/heap-config-gc-pressure.json`** — the stress suite at shipped defaults runs
  **zero minor GCs** and passes vacuously. This config (64K buffers, 4 nursery blocks pinned)
  makes it run ~1,263. **Any GC change must be gated with it**, and the cycle count checked,
  not assumed.
- **The heap-validate build is repaired and green** (it was RED and blocking W8 for the whole
  parent loop). Build BOTH `test` and `ecoc` in the validator tree or 12 Elm cases fail with
  `exit 127` and look like a codegen regression.
- **Pin the seed: `--seed 1790156644220971348`.** The validator suite is seed-flaky — its
  heap-graph generator can emit a 0-field `Tag_Custom`, which HEAP_044 forbids, and aborts in
  the from-space pre-walk. Pre-existing, unrelated to any change under test.
- **`ECO_NURSERY_POISON=1`** fills the nursery free region with `0xD8` and traps any traced
  word the mutator never wrote (`ECO_POISON_NONFATAL=1` to census rather than abort). Relevant
  to 38 and 40 because both change what the collector reads.

**Mandatory per item:** E2E `--target check`; stress suite under the GC-pressure config with
the cycle count verified non-zero; heap-validate green with the pinned seed. Item 44
additionally owes the "bitmaps are all-zero after the targeted clear" assert described above,
green across both the self-compile and the stress suite, before its assert is removed.

**Disposition.** Flat deletions ship (W11, and 40 for its gating value). Flat restructures do
not — 52 and 54 are reverted unless they move GC time outside the 2σ = 5.3 s band.

---

## 7. Relationship to other plans

- `plans/gc-tier1-constant-factors.md` — parent. Its W8 and W9-tail are this file; the rest is
  measured and recorded in `benchmarks/gc-opt-loop.md`.
- `gc-opt-working-list.md` — items 38, 40, 42–47, 51, 52, 54 in Tier 1.
- **Working-list #57–63 (parallel marking) is the reason item 40 matters**; #58 needs its flat
  array, #59 builds on 52's per-worker accumulation, #60 on 38's bitmap. Landing W12 makes
  three of the seven parallel-marking prerequisites already true.
- `plans/oldgen-per-block-mark-bitmaps.md` — introduced the structure item 40 changes. Read it
  for why per-block bitmaps were chosen over a single heap-wide one; the arena keeps that
  choice and changes only the container.
- `plans/nursery-per-site-zeroing.md` — the W1/W1b work, and the source of the gc-pressure
  config and the poison tripwire this plan uses.
