# GC Optimisation Working List

Captured 2026-09-19 from a review of the allocator, the recorded profiles
(`benchmarks/lss-opt.md`, `benchmarks/tier2-opt.md`, `design_docs/borrow-inf-census.md`,
`guides/cpp-prof-hints.md`) and `design_docs/gc_handbook/`.

**Status: unvalidated candidate list.** Nothing here has been measured in isolation.
Numbers quoted are either recorded measurements (marked *measured*) or arithmetic
bounds (marked *bound*).

Baseline: GC is 29–41% of Stage-7 self-compile wall. Split is roughly
**minor ~86 s / major ~56 s** (Run R/S); within major GC, **mark is 92.4%**.
Retention is **`Custom` 60.7% + `Cons` 36.7% = 97.4%** of everything promoted.

> Not in this file: the Tier 0 measurement-hygiene items (rebuild without
> `ENABLE_GC_STATS`/asserts, add minor-GC phase timing, run the designed-but-never-run
> `plans/gc-param-sweep-experiment.md`) and the Tier 3 dead-code findings
> (`gc_phase_` never set to `Marking` so incremental marking is unreachable; old-gen
> compaction has no production caller; `Closure` scan has no slot cap). Those are
> prerequisites and cleanups rather than optimisations, but they should not be lost.

---

> **Plans lowering this list to implementation detail:**
> - Items **1–5** (§1.a root registration) → `plans/gc-root-registration-cost.md`
>   (TLS shadow stack, `EvaluatorDesc` indirection, `$sat` fast path).
> - Items **6–56** (§1.b–§1.i) → `plans/gc-tier1-constant-factors.md`
>   (11 work packages W0–W10).
> - Tier 2 is not yet lowered. W8 in the Tier-1 plan is the stated
>   prerequisite for #58.

# Tier 1 — constant-factor fixes, single-threaded

## 1.a Root registration — `eco_gc_push_stack_range` (14.53% self time, *measured*)

The single hottest symbol in the whole compiler. Mutator-side, not collection work:
every dynamic closure application through the runtime registers its args array as a
GC root range. Body is `Allocator::instance().getRootSet().pushStackRootRange(...)`
(`RuntimeExports.cpp:4149`) — TLS → `tl_heap_` → `nursery_` → `root_set` chase, then
a `std::vector::push_back`, through an out-of-line cross-TU call with no LTO.

1. Replace the `RootSet`-owned `std::vector<StackRootRange>` with a raw TLS shadow
   stack (`constinit thread_local StackRootRange* eco_tl_root_sp` over a fixed
   pre-committed array), mirroring the existing `eco_tl_bump_state` pattern
   (`Allocator.cpp:165`). Push becomes 3 stores + a pointer bump.
2. Define the push/pop in a header so it inlines; today it is a cross-TU call.
3. Add a single-slot `eco_gc_push_root1(slot)` fast path — several of the hottest
   sites push exactly one slot (`RuntimeExports.cpp:2140`, `:2304`).
4. Cut the number of pushes: `spliceArgsForSaturatedCall` (2.57%) and
   `invokeSaturatedTyped` (3.51%) sit next to it in the profile. Widening the
   direct-call ABI removes both the args array and its registration.
   See `direct-call-decline-census.md`.
5. Extend GC-free / `gc-leaf` function propagation. `plans/gc-free-function-propagation.md`
   got 2,372/44,967 functions (5.27%) → 11,149 statepoints removed → −2.06 MB code,
   −1.35% wall (*measured*). Coverage is still low.

## 1.b The whole-nursery memset — `clearToSpaceFreeRegion` (5.6% of CPU, *measured*)

`NurserySpace.cpp:1841`, unconditional, called at `:533` after `checkAndGrow`. Zeroes
capacity − survivors (~61 MiB at the 64 MiB/side start, up to ~200+ MiB if grown).
Load-bearing because `initHeaderForTag` zeroes only the 8-byte header
(`ThreadLocalHeap.cpp:110`) while setting `hdr->size` to the full field count — so a
partially-initialised object that is traced reads both its unwritten payload slots
*and* its per-object kind bitmap word (`Custom.unboxed` at offset 8, outside the
cleared header) as raw stale bytes.

6. High-water-mark clear: zero only `[copy_ptr_, previous bump high-water)` instead of
   to `capacity`. Pre-authorised by decision Q1 in
   `plans/nursery-ghost-data-and-stale-pointer-debug.md:15`. Cheapest possible change.
7. Zero at allocation instead of in bulk — same byte count, but the zeros land in L1
   right before the mutator's own stores overwrite them. `HeapHelpers.hpp:684`
   (`listBacking`) already does exactly this locally.
8. Incremental zeroing ahead of the bump pointer (`zeroed_end_` watermark, 32–64 KiB
   at a time) so the working set stays in L2 rather than evicting all 16 MiB of L3
   in one burst at every GC point.
9. Root-cause and delete: establish that every allocated object is fully initialised
   before the next safepoint, then remove the memset entirely. Related:
   `plans/allocation-group-single-safepoint.md`, HEAP_031 (`FreshStoreNoForward`).

## 1.c Old-gen allocation, and the promotion path that hammers it

357M–475M promotions per run, each calling `oldgen.allocate(size)`
(`NurserySpace.cpp:1043`), commented *"simplified - no TLAB buffering"*.

10. **Bump-allocate virgin pages instead of pre-slicing them onto a free list.**
    Not promotion-specific — it helps any old-gen allocation that lands on a
    fresh page, promotion included.

    There are two kinds of space in the old gen and they want different
    structures. *Recycled* space (holes left by dead objects) is arbitrary in
    address, order and size — a free list is exactly right, and **none of this
    changes it**: sweep still coalesces holes, `pushSpanOnFreeLists` still carves
    them into `classToSize` cells, they still go back on `free_lists_[cls]`.
    *Virgin* space (a page that has never held an object) is contiguous and
    consumed in address order — a free list is the wrong structure, because you
    already know the answer to every query it will ever be asked.

    Today both go through the free list. `populateFromBlock` (`OldGenSpace.cpp:1235`)
    takes a fresh 512 KiB page and, for a 24-byte class, slices it into **21,845
    cells** — each a header `memset` plus (Tier-M) `next_in_class`, `prev_in_class`
    and a per-block thread link — which the allocator then pops back off one at a
    time, in order. That is a full 512 KiB write pass to build a 21,845-node
    doubly-linked list whose only purpose is to be walked once, in order.

    Proposed allocation path for a size class:
    1. Pop from `free_lists_[cls]` — recycled space, reuse first *(unchanged, still step 1)*.
    2. Free list empty → bump in the current virgin page for this class.
    3. Page exhausted → claim another virgin page, reset the cursor.
    4. No virgin pages → today's splitting / sweep-on-demand / bag-page / panic ladder.

    Reuse-before-grow is preserved (it is already the current priority order, and
    `plans/sweep-on-demand-allocation.md` requires it). A page is bump-allocated
    exactly once, while virgin; after its first sweep it is recycled space and
    lives on the free list forever.

    The block keeps `size_class = cls`, so `walkStepFor` still gives sweep a fixed
    stride and the mark bitmap is unchanged — **nothing becomes "mixed"**. The
    enabling field already exists: HEAP_024 defines `BlockInfo.end_of_objects` with
    exactly the two meanings needed — `BlockInfo.end` for fully-populated pages
    (`populateFromBlock`, `:1275`) and the bump frontier for bump-filled blocks
    (`allocateForEvacuation`, `:3805`). Sweep walks `[start, end_of_objects)`, so it
    never touches the un-bumped tail, which is what makes it safe for that tail to
    have no headers.

    **Detail to get right:** a page that is half-bumped when a GC fires. Sweep must
    walk only the populated prefix, dead cells from that prefix go onto the free
    list as normal, and the virgin tail must stay virgin with its cursor intact —
    i.e. sweep must not reset `end_of_objects`, and the per-class cursor must
    survive the cycle. Worth a dedicated test.

    Conventional arrangement rather than anything exotic: `gc_handbook/07-allocation.md`
    pairs sequential allocation inside blocks with free lists for reclaimed space,
    and Immix is built on the same split.

    *(Supersedes an earlier "promotion PLAB" framing — a single mixed-block
    bump buffer for survivors. That version was wrong: it replaced an already-O(1)
    free-list pop with an O(1) bump for no direct gain, stopped reuse of swept
    cells so the heap grew faster and majors fired sooner, and gave up fixed-stride
    sweep by tagging destination blocks `size_class = NUM_SIZE_CLASSES`.)*
11. Remove the two `std::chrono::high_resolution_clock::now()` calls bracketing
    `OldGenSpace::allocate` (`:633`, `:692`). ~15 s arithmetic *bound* at 357M
    promotions × 2 × ~22 ns. Precedent: `__vdso_clock_gettime` was 22.52% of process
    CPU in the original baseline (`guides/cpp-prof-hints.md:307`).
12. Remove the `GC_STATS_OLDGEN_RECORD_ALLOC` histogram call from the same path (`:619`).
13. Remove the dead `gc_phase_ == GCPhase::Marking` branch at `:639` — `gc_phase_` is
    never set to `Marking`, so this is an unconditional branch on the promotion path
    that can never be taken.
14. Don't drive `lazySweep` from the promotion path while inside a minor GC
    (`:662-665`). The code's own comment at `:673` names this *"the dominant source
    of minor GC outliers"*.
15. Replace the first-fit linear scan of larger size-class free lists in
    `tryAllocateBySplittingLarger` (`:977-1077`) — each list is unbounded in length.

## 1.d `evacuate` per-edge prologue (`NurserySpace.cpp:919`)

Called once per pointer slot of every surviving object.

16. Hoist `allocator_->getHeapBase()` and `getHeapReserved()` (`:941`, `:943`) into
    per-GC locals — two dependent loads re-fetched on every call, both GC-invariant.
    Same at `:1181`, `:1184`, `:1669`.
17. Reorder: test `isInFromSpace` (pure arithmetic, `:1022`) **before** loading the
    child header (`:958`). Today every edge pointing at to-space, old gen or permanent
    space takes a full cache miss on the child and then returns having done nothing —
    in steady state that is the majority of edges.
18. Cache `config_->promotion_age` as a member; currently dereferenced through the
    config pointer per object at `:1041`, `:1212`, `:1730`. (`gc_threshold_` and
    `growth_threshold_` were already cached this way — `NurserySpace.hpp:116-121`.)
19. Cache `config_->use_hybrid_dfs`; loaded per Cons cell scanned (`:1467`).
20. Add `__builtin_expect` on the cold branches — zero hits in the whole file today,
    despite `resolveFast` (`Allocator.hpp:69`) showing the idiom is known.
21. Inline `evacuateUnboxable` (`:1149`) — an out-of-line member whose entire body is
    `if (is_boxed) evacuate(...)`, called once per slot including unboxed ones.
22. De-duplicate the promotion predicate, written out at three sites (`:1041`, `:1212`, `:1730`).
23. Compose the forwarding header as one 64-bit word store instead of three separate
    bitfield stores (`:1139-1146`, `:1250`, `:1762`).

## 1.e Per-object dispatch

24. Table-driven `getObjectSize` (`AllocatorCommon.hpp:238`): a 27-case switch → an
    indirect branch that mispredicts on a data-dependent tag sequence. Replace with a
    32-entry `constexpr {base_bytes, elem_bytes}` table. Called **twice per survivor**
    (`NurserySpace.cpp:488`/`:515` stride, `:1027` copy sizing).
25. Thread the size from the evacuate site to the Cheney stride rather than recomputing.
26. `scanObject`'s own `switch (hdr->tag)` (`:1368`) is a third dispatch on the same
    already-loaded tag — fold with #24/#25 where possible.
27. `Tag_Array` case re-loads `arr->header.size` when `hdr->size` is already in hand
    (`AllocatorCommon.hpp:322`).
28. Old gen: `markOneObject` calls `walkStepFor(block, getObjectSize(obj))`
    (`OldGenSpace.cpp:1868`) and `walkStepFor` **discards** the result for uniform
    pages (`:190-195`) — a full switch evaluated and thrown away per marked object.

## 1.f Slot scanning

29. Use `pointerMaskFromKindBitmap` (`Heap.hpp:280`, already exists, unused by the GC)
    to build a 1-bit pointer mask once per object, then `ctz`-iterate only the boxed
    slots. Today every slot — Int, Float, Char included — costs a bitmap reload, a
    shift, a mask, a compare and a call (`NurserySpace.cpp:1401`, `:1412`, `:1431`).
30. Hoist the bitmap word into a local. The compiler cannot do it: `evacuateUnboxable`
    writes through `Unboxable&` into the same object, so it must re-load. For
    `Custom`/`Closure` the bitmap is a bitfield, so each reload is load + shift + mask
    *before* the per-slot extraction.
31. Hoist the uniform-kind branch out of the `ElmArray` / `ListBacking` element loops
    (`:1583`, `:1513`) instead of re-testing `is_boxed` inside the callee per element.
32. Add a "has no boxed slots" bit to `Header` — there are **15 unused `refcount` bits**
    (`Heap.hpp:168`). Lets the Cheney scan and `markChildren` skip dispatch entirely
    for pointer-free objects; boxed `Int`/`Float` are very common in this heap.
    (`gc_handbook/10-other-partitioned.md §10.1`.)
33. Drop the redundant Phase 2 Cheney loop (`:485-489`) — Phase 3's outer `while`
    (`:511-516`) re-runs it immediately with an identical body.
34. Revisit the hybrid-DFS Cons path (`:1460`, `:1657-1835`): it traverses every list
    spine three times (spine copy → head pass → the Cheney scan reaching the cells
    anyway) for allocation contiguity. Measure whether the locality pays for it.

## 1.g STL containers and allocation inside the GC pause

35. `std::vector<void*> promoted_objects` is constructed **inside** `minorGC`
    (`:418`), so it mallocs and doubles from zero every cycle. Make it a member with
    retained capacity.
36. Root phases 1a/1c iterate `std::unordered_set` in bucket order (`:424`, `:445`) —
    pointer chase per node, roots touched in random address order. A sorted vector is
    faster to walk and address-ordered.
37. `ExternalRootScanner` is `std::function<void(EvacuateFn)>` taking a `std::function`
    **by value** (`RootSet.hpp:91`); the lambda at `:474` captures 24 bytes, over
    libstdc++'s 16-byte SBO → a heap allocation per scanner per GC, plus an indirect
    call per root. Use a function pointer + `void*` context.
38. `std::unordered_set<void*> nursery_visited_` (`OldGenSpace.hpp:478`) — one malloc
    and hash per distinct live nursery object, during the mark pause. Replace with a
    side bitmap over the nursery extent.
39. `ThreadLocalHeap::collectRoots()` (`:781`) returns `std::unordered_set` **by value**
    from a `const&`, then passes it by `const&` into `startMark`. Pure waste; return
    the reference.
40. `mark_bits_` is `vector<vector<uint8_t>>` (`OldGenSpace.hpp:514`) — a pointer
    indirection per block and four bounds branches per bit op (`:1006`, `:1021`,
    `:1041`). Flatten to one arena. (Also a prerequisite for #45.)

## 1.h Old-gen bookkeeping — O(n²) and repeated full walks

41. `fixupIndicesAfterBlockMove` (`OldGenSpace.cpp:3144`) walks **all** of
    `buffer_meta_` per released block; `reclaimAllDeadBlocksFromMeta` and
    `maybeShrinkCapacity` release blocks in a loop ⇒ O(released × #blocks). Thousands
    × thousands at 512 KiB pages on a 5 GB heap.
42. `releaseBlockToAllocator` (`:3258`) iterates the **entire** `large_body_index_`
    hash map per released block; also a linear scan of `free_large_blocks_` (`:3228`).
43. `transitionToSweeping` (`:2469`) walks every free cell in the heap just to clear a
    rare sentinel, then discards the lists.
44. Mark bitmaps are bulk-zeroed every cycle (`:1548`) even though `testAndClear`
    (`:1041`) exists specifically to make that unnecessary.
45. `allocateFromEmptyRegularBlocks` (`:1396`) linearly scans every block in `blocks_`
    per large allocation.
46. `markLargeBodySeen` does an `unordered_map` lookup per split-header scanned
    (`:4289`, called from `NurserySpace.cpp:1620`); `promoteLargeHeader` (`:4301`)
    linearly scans `nursery_owned_bodies_` per promoted split header.
47. Sweep inner loop does a `large_body_index_.find` per pinned string/bytebuffer cell
    (`:2653`) — described in its own comment as a "defensive idempotent guard".
48. `getenv`-backed magic statics on the sweep hot path (`:2218`, `:2416`) compile to a
    guard-variable atomic load + branch on every call.
49. `gatherFreeListSnapshotInto` (`:3479`) runs Floyd cycle detection plus a per-cell
    `unordered_map` insert over every free cell, in the `ENABLE_GC_STATS` build — i.e.
    the standard `build` preset. Only ~10–17 majors per run, so low value, but it is
    a debugging tripwire shipped as telemetry.
50. `sweepNurseryLargeBodies` (`:4367`) runs at the end of every minor GC even when
    there is nothing to sweep.
51. `Allocator::isInNursery` is an out-of-line cross-TU call executed twice per marked
    object (`OldGenSpace.cpp:1784` and `:1839`) for what is two range compares.
52. `markOneObject` does a scattered read-modify-write into `buffer_meta_[blk].live_bytes`
    (`:1869`) — a third random cache line per object, on top of the header and the mark bit.

## 1.i Prefetching and instrumentation

53. No prefetching anywhere in the Cheney scan (`:485-489`) — a linear walk through
    to-space is the ideal place for `__builtin_prefetch`.
54. No prefetching in the mark loop; consider the FIFO prefetch buffer from
    `gc_handbook/02-mark-sweep.md §2.6` (8–32 entries) between the mark stack and the
    scan, and/or prefetch-on-grey.
55. `GC_STATS_MINOR_INC_{SURVIVORS,PROMOTED}` are out-of-line calls into `GCStats.cpp:448`
    per surviving *and* per promoted object. Inline or compile out of bootstrap builds.
56. `StackMap::findRecord` does a hash lookup per stack frame including frames that can
    never match (`StackMap.cpp:292`). Acknowledged as deferred in
    `plans/stackmap-unwinder-gc-roots.md:133`.

---

# Tier 2 — parallel, concurrent, and promotion-volume reduction

12 cores available (i5-12600H: 4 P + 8 E), one mutator thread during a self-compile.

## 2.a Parallel marking — the clearest algorithmic win

Mark is 92.4% of major-GC time and 100% stop-the-world. Recipe:
`gc_handbook/14-parallel-gc.md §14.2`. Expect ~3–4× at 6–8 threads (latency-bound,
not compute-bound): 51.8 s → ~14 s.

57. Work-stealing deques per worker. **Non-negotiable on this CPU** — with 4 P-cores
    and 8 E-cores, static partitioning would be badly skewed.
58. Atomic mark-bit set (`lock or` / CAS) on the per-block side bitmap. Do #40 first.
59. Per-worker `live_bytes` accumulation merged at the barrier, replacing the scattered
    RMW into `buffer_meta_` (#52).
60. Per-worker nursery-visited bitmaps replacing the shared `unordered_set` (#38).
61. Explicit heap handoff to GC workers — `Allocator::instance().getCurrentThreadHeap()`
    is TLS, so workers must be handed the heap rather than resolving it.
62. Amend HEAP_007 ("each heap region is owned by exactly one ThreadLocalHeap"). Parallel
    STW helpers do not violate its intent — the owner is stopped, no mutation is in
    flight — but the invariant text needs to say so.
63. Termination detection + phase barrier (`gc_handbook/14-parallel-gc.md §14.7`).

## 2.b Parallel minor GC

Minor GC is the bigger half (~86 s) and averages ~60 ms per cycle — long enough to
amortise thread wake-up. Lower priority than 2.a because Tier 1 will already have
removed a large fraction of it.

64. Per-worker evacuation and promotion destinations, so workers never contend on
    a shared cursor or free-list head: a per-worker, per-class bump cursor over
    virgin pages (the structure #10 introduces, one instance per worker), plus a
    contention strategy for the recycled free lists — per-worker shards, or claim
    a run of cells per pop rather than one.
65. CAS forwarding-pointer install with loser rollback
    (`gc_handbook/14-parallel-gc.md §14.4`).
66. Chunked claiming of to-space scan ranges (parallel Cheney).
67. Parallel root scanning — the five root populations are independent and can be
    handed to different workers.

## 2.c Concurrent marking — Eco is unusually well suited to this

Concurrent marking normally needs an SATB or incremental-update write barrier. **In an
immutable heap it does not**: fields are never overwritten, so every reference reachable
at the start of the mark stays reachable by its original path, and new objects only
*add* edges. The snapshot-at-the-beginning is preserved for free. This would move most
of the ~56 s of major-GC pause off the critical path with no write barrier at all.

68. Concurrent old-gen mark with a short STW root re-scan at the end.
69. Allocate-black (or grey) for objects promoted into old gen during the mark.
70. Decide how a concurrent mark interacts with a minor GC moving nursery objects —
    simplest option is to snapshot the nursery as roots at the STW start and mark only
    old-gen objects concurrently.
71. **Prerequisite:** enforce HEAP_005 (no old→young pointers) rather than merely
    document it. It is marked `documented`, not `enforced`, and has been violated in
    production — HEAP_038 records a bisected failure where a >8 KiB `ListBacking`
    landed directly in pinned old gen and was then filled with nursery pointers. The
    same discipline underpins barrier-free concurrent marking.

## 2.d Reduce promotion volume

357M objects / 10.2 GiB promoted per run, and with `promotion_age = 2` **every promoted
object is `memcpy`d three times** (age 0→1, 1→2, then into old gen).

72. Sweep `promotion_age`. `= 1` removes one full copy of every survivor. Only three
    valid values (2-bit `Header.age`, capped at 3 by `HeapConfig::validate`).
73. Sweep nursery size (`nursery_block_count`, `nursery_max_block_count`) — a larger
    nursery gives more objects time to die before the first collection. Interacts with
    #6–#8: today a bigger nursery also means a bigger memset.
74. Eliminate the 0-field `Custom` promotions. `tier2-opt.md:245` records **19.7M–23.8M
    promoted objects (9.1–10.0%, 301 MiB) carrying zero data** — nullary constructors
    that HEAP_044 null-cons HPointer embedding is designed to remove entirely. Find out
    why they are still heap-allocated; ~10% of promotion for free.
75. Attack `Custom` retention (60.7%) — `plans/sum-type-wrapper-unboxing.md` targets
    exactly this.
76. Attack `Cons` retention (36.7%). Note `plans/promotion-time-list-chunking.md` was
    tried and reverted (+5.7% wall; mean promotable run 1.69 against a gate of ≥8).
77. Consider adaptive tenuring / a survivor space. There is none today: survivors are
    packed at the base of the new from-space and `checkAndGrow` only resizes the whole
    nursery, so an object allocated just before GC *n* is promoted at GC *n+2*
    regardless of intervening allocation volume.

## 2.e Longer shots

78. Lazy sweeping is already in place; consider parallel chunked sweep
    (`gc_handbook/14-parallel-gc.md §14.3`) if sweep ever becomes visible again — it is
    currently only 7.6% of major-GC time.
79. Region/Immix-style mark-region for the old gen (`gc_handbook/10-other-partitioned.md`).
    Probably not worth it: mark dominates, and sweep is already amortised.
