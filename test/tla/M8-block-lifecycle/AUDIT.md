# M8 — audit log

Dated entries, newest last. Each records what was checked against which tree, the verdicts, and
every change to the model. A canary re-audit adds an entry here quoting the new hash prefix.
M8 has no pins in `test/tla/manifest.txt` yet (MAPPING.md lists the proposed ones).

## 2026-09-29 — first implementation (assessment only)

**Tree:** 2026-09-29, after the M1–M7 trace hooks; no runtime change. **Tools:** the dev image,
tla2tools 1.8.0 (TLC 2026.09.25 rev 8f4bc8b). Quick runs:
`run_models.py --model M8 --jobs 2 --workers 2 --java-opts="-Xmx3g -XX:MaxDirectMemorySize=1g"`.
Deep runs: once, under `flock /tmp/tla-deep.lock`, `nice -n 10`, 4 workers, `-Xmx5g`.

**Why M8.** The S1 defects CR-018, CR-033 and CR-035 are serial and sit in the old generation's
block lifecycle, which M1–M7 touch only at their edges (M4 abstracts the lifecycle; its
`ReleasedSafe` is blind to address reuse). M8 models the lifecycle with addresses that come back
at the same start under recycled ids, and the side tables keyed by either.

### Results

Quick tier, 25 rows, two at a time with two workers each (`/tmp/tla-M8/quick1.txt`): **25/25 as
expected in 70 s.** States are TLC's distinct states; a failing row's count is where TLC stopped.

| Configuration | Expected | Result | States | Time |
|---|---|---|---|---|
| `MC_quick_mutator` | pass | pass | 190,025 | 13 s |
| `MC_quick_reuse` | pass | pass | 291,269 | 34 s |
| `MC_quick_demote` | pass | pass | 47,365 | 4 s |
| `MC_quick_uniform_large` | pass | pass | 123,816 | 7 s |
| `MC_quick_bagrung` | pass (CR-029) | pass | 107,492 | 8 s |
| `MC_quick_bagrung_witness` | witness `NoSizeClassedBagCarve` | as expected | 6,669 | 2 s |
| `MC_quick_reissue_witness` | witness `NoSameIdSameStartReissue` | as expected | 217 | 1 s |
| `MC_quick_cr018` | violates `NoOverwriteLive` (CR-018) | as expected | 620 | 1 s |
| `MC_quick_cr018_flip` | violates `FlipTrustsTruth` (CR-018) | as expected | 606 | 1 s |
| `MC_quick_cr035` | violates `IndexFaithful` (CR-035) | as expected | 4,046 | 2 s |
| `MC_quick_cr035_lost` | violates `NoLostObject` (CR-035) | as expected | 189,835 | 15 s |
| `MC_quick_cr033` | violates `BlockParseable` (CR-033) | as expected | 5 | 1 s |
| `controls/cr018_count_idle` | pass | pass | 2,316 | 1 s |
| `controls/cr035_flip_purges` | pass | pass | 95,302 | 7 s |
| `controls/cr035_lost_flip_purges` | pass | pass | 267,911 | 18 s |
| `controls/cr033_tail_header` | pass | pass | 2,263 | 1 s |
| `controls/fixed_all` | pass | pass | 180,844 | 17 s |
| 8 mutant rows (`mutants/*.cfg`) | each its target | each as expected | 26 – 2,926 | 1 – 2 s |

Deep tier, one row at a time, 4 workers:

| Configuration | What it stretches | Expected | Result | States | Time |
|---|---|---|---|---|---|
| `MC_deep_broad` | 3 pages, 7 operations, 5 objects, demotion on, every size but a page and a page minus 8 | pass | pass | 4,410,045 | 270 s |
| `MC_deep_fixed` | the same with every size and the three fix candidates | pass | pass | 14,529,613 | 962 s |

### The register entries

**CR-018 — reproduced** (`MC_quick_cr018`, `NoOverwriteLive`, 6 states; `MC_quick_cr018_flip`,
`FlipTrustsTruth`, the same trace). The counterexample, read against the code:
1. `allocate(4)` (the band): `allocateFromBagPage` step 3 (`OGS:2617-2692`) materializes page P
   at Idle, `fully_swept = false`, object A at offset 0, the 2-granule remainder a class-0 cell.
2. The mutator drops A.
3. A STW major: A is unmarked, P's `live_bytes` is 0; `reclaimAllDeadBlocksFromMeta` keeps P
   (`current_heap - bytes < min_heap`, `OGS:6580`); `classifyBlocksAfterMark` leaves it mixed; the
   initial slice gap-sweeps it (one run: a class-2 cell at 0, a class-0 cell at 4), marks it
   `fully_swept` and completes (the light shrink keeps P: `desired_heap >= min_heap`).
4. `allocate(4)` at Idle: step 1 splits P's class-2 cell (`tryAllocateBySplittingLarger`
   `OGS:2409`); `initObjectHeaderWithSize` (`OGS:522`) adds nothing to `live_bytes` at Idle.
   Object B is live in P; P reads `fully_swept && live_bytes == 0`.
5. `allocate(6)` (a whole page): `allocateLargeBlock` → no free large block →
   `allocateFromEmptyRegularBlocks` (`OGS:2862`) flips P and writes the new object's header over
   B. Exactly the register's reproduction. The fix candidate (a), counting a mixed-block cell at
   Idle (`controls/cr018_count_idle`), passes; with it every flip takes an empty block
   (`controls/fixed_all`, `MC_deep_fixed`).
   Every mixed-block carve at Idle is uncounted: the pop (`finalizePoppedCell`), the split, the
   bag page's carve, and CR-029's bag-rung carve (below) alike.

**CR-035 — reproduced** (`MC_quick_cr035`, `IndexFaithful`, 7 states; `MC_quick_cr035_lost`,
`NoLostObject`, 13 states). Both rows use `Keep = MC_NoLiveOverwrite`, so no step overwrites a
rooted object and the trace is the stale-entry story alone (without it, the shortest
`IndexFaithful` counterexample overwrites a still-rooted Y, which is CR-018's S1). The chain:
steps 1–3 as CR-018; a young large object Y of 4 granules is carved at P's start at Idle and
registered (`registerLargeBody` `OGS:7537`, key X = P's start); the mutator drops Y; a young large
object Z of a whole page flips P and is registered under X, overwriting Y's key while Y's meta
stays in `nursery_owned_bodies_` with `body_base = X` (`IndexFaithful` fails here). The next minor
reaches Z and colours it, then `sweepNurseryLargeBodies` frees Y's meta: `freeLargeBodyCell`
erases key X first (`OGS:7695`), which is Z's, and finds P large, so frees nothing else. The minor
after that cannot find Z (`youngLargeMeta` `OGH:1217`: no entry), so Z is neither recoloured nor
promoted, and `sweepNurseryLargeBodies` frees Z's meta: the large branch resets P's header to
`Tag_Free` and pushes P onto `free_large_blocks_` while Z is live (`NoLostObject`). The register's
description is exact; one precision: Y must sit at P's start (the flip places Z at `blk.start`;
a Y elsewhere in P only erases its own key). The fix candidate, a purge of `[start, end)` at the
flip as release does (`controls/cr035_flip_purges`, `controls/cr035_lost_flip_purges`), passes
both; CR-018's fix removes the precondition.

**CR-033 — reproduced** (`MC_quick_cr033`, `BlockParseable`, 2 states). Reachability, the entry's
open question: yes, at every geometry. A request of exactly `alloc_buffer_size - 8` bytes
(524,280 at the default) is below `alloc_buffer_size` and above every class, so `allocate` sends
it down Path 4 (`OGS:2076-2091`); `allocateFromBagPage`'s steps 1 and 2 cannot split for it
(`request_cls = NUM_SIZE_CLASSES`, so `start_cls = NUM_SIZE_CLASSES` and the class loop is empty);
step 3 carves a fresh page (`alloc_span = page_size`, no sentinel since D5) and leaves an 8-byte
remainder, under `MIN_FREE_CELL_SIZE`, with no header (`OGS:2678`). The callers that can ask for
that size: `allocateLargePinned` (a String or ByteBuffer), `allocateLargeBody`, `allocateYoungLarge`.
Who reads the tail (by reading, not modelled):
- **bitmap mode (the default): nobody.** The gap sweep reads only set-bit headers (HEAP_055) and
  turns the tail into a trailing `Tag_Free` at the block's next sweep (the object's gap to the
  block end, `pushSpanOnFreeLists` `OGS:5370`); V11 runs after that; the validate-only
  old-gen→nursery walk visits set bits only in mixed blocks (HEAP_024, `NS:1000-1030`);
  compaction, the other header walker, has no production caller. The model agrees:
  `BlockParseable` exempts a block awaiting its gap sweep and holds everywhere else once the tail
  gets a header (`controls/cr033_tail_header`, `controls/fixed_all`).
- **legacy mode (`old_gen_bitmap_alloc = false`): S1.** The header-walking `lazySweep`
  (`OGS:5710`) reads the tail at the page's next sweep. A zero word (a fresh page) decodes as
  `Tag_Int`, size 16 (`sizeof(ElmInt)`): the step overshoots `end_of_objects` by 8, the run
  flushed at the block boundary spans 8 bytes into the next page, and `pushSpanOnFreeLists`
  writes a class-1 cell's header and link over the next block's first word. A reused extent's
  stale word decodes to anything.
The fix candidate (any nonzero remainder through `pushSpanOnFreeLists`) passes.

**CR-029 — the premise confirmed; the carve is consistent.** The bag rung's size-classed carve is
reachable serially (`MC_quick_bagrung_witness`, 9 states): with the reservation exhausted
(`acquireOldGenBlock` fails, the bag is empty) and a full uniform block of the class, rung 3 and
rung 6 find no virgin page, rung 4's class-sized split leaves a 1-granule remainder and is
refused, and rung 7 (`allocateFromBagPage` step 1) carves the exact 3-granule request from a
5-granule mixed-only cell and pushes the 2-granule remainder (class table `MC_Cells6b`, where the
request is smaller than its class cell as for the real medium classes; with small classes the
carve equals rung 4's). `MC_quick_bagrung` checks every invariant over the whole scenario
(107,492 states): pass. As the entry's analysis says, the block parses by object size, no cell is
handed out twice and the free lists stay in live blocks. One addition: at Idle this carve, like
every mixed-block carve, is not counted in `live_bytes` (CR-018): a page-sized request can then
flip the block over it.

**CR-014, CR-016 (context).** Their hazards need a parallel minor (M4). Serially, the tail-path
completion inside `allocate()` (`tail_complete` in the coverage below) and the LIFO re-issue of a
released id (`reissue`) keep every invariant; the flip against the mutator's own cursor detaches
it first (`MC_quick_uniform_large`).

**CR-036 (context).** The shape is reachable serially and quickly
(`MC_quick_reissue_witness`, 5 states): a major's reclaim releases id 1 at slot 2, the grow (or a
later `ensureBagPageAvailable`) takes slot 2 back from `old_gen_free_blocks_` (first fit), and the
next bag carve materializes it under id 1 (LIFO). Between cycles this is harmless (every
invariant holds in `MC_quick_reuse`); IM5 matters only inside a cycle, where releases assert.

**New findings: none.** Apart from the three reproductions above, no invariant fails: the pass
rows, `MC_deep_broad` (4.4 M states, every size but the two preconditions), and the fixed rows with `MC_deep_fixed` (14.5 M states, every size).

### Counterexamples checked against the code

Each reproduction was read step by step against the functions cited above; each uses only the
free choices of MAPPING.md §3 the code can make: a free-list pop or split of a cell that is the
only fitting one (so LIFO order does not matter), a sweep slice that runs to completion (the
initial slice's budget is configurable), a light shrink with `desired_heap >= current_heap` (it
releases nothing), and majors and minors at operation boundaries.

### Negative controls (A6)

| Mutant | Target | Shortest story (states) |
|---|---|---|
| `reclaim_ignores_live` | `NoLostObject` | a live page released by the major's reclaim (3) |
| `cursor_ignores_bit` | `NoOverwriteLive` | the refilled cursor hands out the live cell 0 of a queued block (7) |
| `split_keeps_cell` | `NoDoubleAlloc` | the carved cell stays on its list over the new object (5) |
| `no_trailing_header` | `BlockParseable` | a demoted all-dead page gap-swept into a 5-granule cell and a headerless tail (6) |
| `release_keeps_index` | `IndexFaithful` | reclaim releases a page with a dead young large object's entry (4) |
| `release_keeps_free_cells` | `FreeListsInLiveBlocks` | the light shrink releases a swept page, its cells stay listed (4) |
| `flip_ignores_live` | `FlipTrustsTruth` | the flip takes a page with a live object (CR-018's fix on) (4) |
| `detach_skips_queue` | `SideTablesFaithful` | the light shrink releases a queued uniform page, its `partial_` entry stays (6) |

Every counterexample was read and is the intended story.

### Coverage (A8)

`CovMC.tla` with `Cov = TRUE` (one worker) unions the paths taken over every reachable state.
The pass rows together take: the cursor, refill, virgin block, pop, split, sweep-on-demand,
panic, the bag rung's three steps and its sub-16-byte tail (`controls/fixed_all`), the flip, a
free large block, a fresh large block, the in-loop, tail and early-exit ends of a slice, the
drain, reclaim, the shrink's block and bag-page releases, the grow, demotion, `freeUniformCell`
(rewind and queue), `freeLargeBodyCell`'s large, unswept-mixed and mixed branches, promotion in
place, `retireDeadLargeBodies`, a dead large block classified free, a same-id same-start
re-issue, and an uncounted Idle carve. Only `reach_miss` (a young large object not found by
address) and a no-op `freeLargeBodyCell` never occur in a pass row: both are CR-035's chain.

### Decisions and changes while building

- **`NoOverwriteLive` compares allocation order** (object ids are handed out in order and never
  reused): a younger allocation over an older rooted object. The first form flagged the new
  rooted object Z over the dead Y, which is a double allocation (`NoDoubleAlloc`), not an
  overwrite of a live object.
- **`Keep(_)`**, a scenario filter on allocation outcomes: TLC (this version) checks invariants
  on states that a `CONSTRAINT` or an `ACTION_CONSTRAINT` prunes, so neither could isolate
  CR-035 from CR-018's overwrite (checked on a toy spec).
- **Demotion skips the heap-base page** (`OGS:4148`), added after the first draft; the scenarios
  that demote use slot 2.
- **A second class table** (`MC_Cells6b`) for CR-029: with the first, every size-classed request
  fills its cell and the bag rung's carve equals rung 4's.
- `no_slack_header` (a `padCellSlack` mutant) was dropped: no modelled path gives a mixed-block
  cell with slack short of the geometry change; `no_trailing_header` covers `BlockParseable`.


## 2026-09-30 — canary re-audit: register reproductions (GC_MODEL_001)

Pins fired: OGS.lazySweep (3019e316a801).

Change (plans/threaded-gc-register-repros-impl.md, register reproductions; snapshot of the
prior tree `snapshots/register-repros/pre-impl-2026-09-30.tgz`). Code-level guards were added for
the open register entries. The runtime changes are of three kinds only, and none adds, removes or
reorders an atomic step, a lock, a shared location or a memory order on a production path:
- **test accessors** (`AllocatorTestAccess`: `acquireOldGenBlock`, `releaseOldGenBlock`,
  `freeBlocks`, `threadMutexHeldElsewhere`, `adoptThreadHeap`; `OldGenSpaceTestAccess`:
  `sweepCompleteDeferred`, `promoMuHeld`, `cyclePressureFinishDue`). They forward to existing
  functions or read existing fields; unit tests and harnesses call them only. They fire the
  footprint greps `F.promoMu`, `F.threadMutex`, `F.pageWorkCalls`, `F.oldGenFreeBlocks`,
  `F.setThreadHeap`, `F.parPromoActive` and the `Allocator.hpp` census by name only.
- **trace-only probes** (`ECO_TLA_TRACE_ONLY`, compiled out of every other build):
  `m5.item.taken`, `m5.item.copied`, `m5.item.popped` (`TenureWork.hpp`, gated by the new
  `tla_probes`, default false), `m5.l3.claimed` (`NT.TenureParEnv`), `m6.tlh.dtor`
  (`TLH.destructor`), `m6.census.locked` (`P1Census.cpp`). `tlatrace::probe` emits no event;
  it only calls the harness's callback while recording, so no recorded trace changes.
- **a stats-only counter** in `OGS.lazySweep`'s tail completion (`sweep_tail_completions`,
  `sweep_tail_in_promotion`), inside the existing `#if ENABLE_GC_STATS` block in the same
  `promo_mu_` section as the existing `total_post_sweep_shrink_ns` write.
`test/gc-heap-tsan/promo_sweep.cpp` gained non-trace arms (`promoDetMain`, tail mode, exact arrays
every minor); its trace section (`promoTraceMain`, the M4 trace harness) is byte-identical.

Runs (2026-09-30, this tree): `run_traces.py` (every harness rebuilt): **135/135 as expected** in 83 s.

The stats-only counter does not touch block state, lists or `live_bytes`.

**Verdict: no model change needed.**

## 2026-09-30 — register-fixes §3.1: CR-033 fixed (GC_MODEL_001)

Pin fired: region `OGS.allocateFromBagPage`, new hash prefix **8e85cd8f9aa1**.

Change (plans/threaded-gc-register-fixes.md §3.1; snapshot `snapshots/register-fixes/pre-phase1.tgz`):
the fresh-page carve's remainder test `remainder >= MIN_FREE_CELL_SIZE` became `remainder != 0`
(plus an 8-alignment assert), so an 8-byte tail goes through `pushSpanOnFreeLists` and gets an
unlinked `Tag_Free` header (HEAP_024 amended). Serial code under the same locks as before; no atomic
step, lock, shared location or memory order changes.

M8 models this carve (`FreshPage`): **model updated first** - the fixed behaviour is the default and the pre-fix test is the A6 mutant `bag_tail_headerless` (`violates:BlockParseable`, 43 states); `MC_quick_cr033` now passes (2,263 states); `controls/cr033_tail_header` retired (it is the default now); `bag_tail_header` dropped from `fixed_all`, `MC_deep_fixed` and `coverage.cfg`. M8 quick tier 25/25 as expected (2026-09-30). **Verdict: model updated.**

## 2026-09-30 — register-fixes §3.2: CR-018 fixed (GC_MODEL_001)

Pin fired: region `OGS.initObjectHeaderWithSize`, new hash prefix **2d1af3f18a67**.

Change (plans/threaded-gc-register-fixes.md §3.2; HEAP_073 new): `initObjectHeaderWithSize` adds
`cell_bytes` to `live_bytes` in every phase (the colour and mark bit stay phase-gated). **Model updated
first**: `Gate`'s Idle branch now adds the cell by default; the pre-fix gate is the A6 mutant
`idle_uncounted` (`mutants/idle_uncounted.cfg` violates `NoOverwriteLive`, 1,098 states;
`mutants/idle_uncounted_flip.cfg` violates `FlipTrustsTruth`, 1,274 states). `MC_quick_cr018` and
`MC_quick_cr018_flip` now pass (2,316 states each); `controls/cr018_count_idle` retired (it is the
default); `count_mixed_idle` dropped from `fixed_all`, `MC_deep_fixed`, `coverage.cfg`. CR-035's
rows keep reproducing on CR-018's pre-fix precondition by carrying `MUTANT idle_uncounted` (§3.3
then moves them to mutants). M8 quick 26/26 as expected.

**Verdict: model updated.**

## 2026-09-30 — register-fixes §3.3 + §3.4: CR-035 and CR-016 fixed (GC_MODEL_001, one audit)

Pin fired: region `OGS.allocateFromEmptyRegularBlocks`, new hash prefix **241b815c0313**.

Change (plans/threaded-gc-register-fixes.md §3.3, §3.4): (1) CR-035: after `removeFreeCellsForBlock`
the flip calls the new `retireIndexRange(start, end)` (retire semantics as `retireDeadLargeBodies`:
erase, `body_base` cleared, id NOT recycled; validate builds re-check that no key maps into the
block, message "flip"; stats `empty_block_flips`, `flip_index_retired`). (2) CR-016: the function
returns nullptr first when `par_promo_active_ && promo_ctx_->n > 1` (stats
`flip_skipped_parallel`). M8 is serial (no parallel promotion), so (2) never applies in M8.

**Model updated first** for (1): `Flip`'s index purge is the default; the pre-fix flip is the A6
mutant `flip_keeps_index`. `MC_quick_cr035` / `MC_quick_cr035_lost` moved to
`mutants/flip_keeps_index{,_lost}.cfg` with `MUTANT = {"idle_uncounted", "flip_keeps_index"}`
(`violates:IndexFaithful`, 4,090 states / `violates:NoLostObject`, 170,510 states); the
`controls/cr035_flip_purges*` rows keep `MUTANT = {"idle_uncounted"}` and pass (95,302 / 267,911
states): the purge alone closes the chain. `fixed_all`, `MC_deep_fixed` and `coverage.cfg` now run
`MUTANT = {}` (the fixed code is the default). M8 quick 26/26 as expected.

**Verdict: model updated.**

## 2026-09-30 — register-fixes §3.5: CR-036, BlockTable per-id generation (GC_MODEL_001)

Pin fired: file `BlockTable.hpp`, new hash prefix **3400ac12ae09**.

Change (plans/threaded-gc-register-fixes.md §3.5; HEAP_048, HEAP_063 amended): a new
`ReservedArray<uint32_t> gen_` reserved, committed and released beside `live_`; `add()` increments
`gen_[id]` (monotone, `clear()` keeps it); accessor `generation(id)`; `storageBase` case 7,
`kStorageArrays = 8`. `BlockInfo` unchanged (40 bytes). Owner-only like the rest of the table; no
atomic, lock or memory order. IM5 (validate) now keys on the generation. M8's id model is unchanged:
ids are still re-issued LIFO, so `MC_quick_reissue_witness` stays a `witness:` row (5 states: the
same-id, same-start re-issue is reachable, and harmless between cycles); what changed is that the
validate check can now tell the two incarnations apart.

**Verdict: no model change needed.**

## 2026-09-30 — register-fixes Phase 2 (§4.1-§4.4): CR-014, CR-001 (race), CR-002, CR-028 fixed (GC_MODEL_001, one audit for the batch)

Pins fired for M8: region `OGS.lazySweep` (**b033f3f0c837**), region `OGS.onSweepComplete` (**9a0fe8aa36e1**: the PM7 tripwire as its first statement).

Change: both completions call one lambda (`completeSweep`), which inside a parallel promotion defers the shrink (CR-014); outside a promotion the serial path is exactly as before (`onSweepComplete` right away). V11 is factored into `validateV11` and deferred to the merge for N > 1 (CR-028). M8 is the serial block lifecycle: its sweep completion and shrink are the serial path, unchanged.

**Verdict: no model change needed.**

## 2026-09-30 — register-fixes Phase 3 (§5.1-§5.3): CR-037, CR-017, CR-038/CR-039 fixed (GC_MODEL_001, one audit for the batch)

Pin fired for M8: region `TLH.majorGC`, new hash prefix **dde8f0dcca5e**.

Change (plans/threaded-gc-register-fixes.md §5.2, HEAP_074): in region mode, right after
`finishMarkAndSweep` and before the pause ends, `nursery_.zapDeadAfterMajor(old_gen_)` turns the
Young extents' unreached survivors into `Tag_Free` fillers. It writes only nursery survivor-extent
memory (never an old-gen block, a free list, `live_bytes`, the block table or the large-body index)
and reads `nursery_visited_`. M8 models the old generation's block lifecycle serially; nothing it
models changes.

**Verdict: no model change needed.**

## 2026-10-01 — register-fixes §6.1: CR-019 fixed, relaxed atomic whole-word YLOS header access (GC_MODEL_001)

Pins fired: region `OGS.promoteYoungLarge` (**ab64ef2a56ee**), region `OGS.lazySweep` (**6066819cec59**).

Change (plans/threaded-gc-register-fixes.md §6.1, CR-019; HEAP_062/HEAP_067 amended): every
access to a header word that another thread may touch during a legacy parallel minor is a relaxed
atomic whole-word access through the new helpers `loadHeaderRelaxed` / `storeHeaderRelaxed`
(`AllocatorCommon.hpp`, newly census-pinned for M3, M4). Writers: `reachYoungLargeP` (age++ under
`ylos_mu_`), `promoteYoungLarge` (age = 0), region `reachYoungLargeR` (age = 1). Readers:
`lazySweep`'s gap sweep (one load per live object, reused for the trace event), the header walk
(one load reused for tag, sentinel and pin), the large-block branch's pin read, and the
validate-only `validateV11` walk. The values written are unchanged (tag/size/pin kept); no lock,
step order or memory order beyond "relaxed" is added, so no happens-before edge changes. TSan:
`det-cr019` both orders and `ylos-sweep` are clean (were: a report every run).

M8 is serial over the block lifecycle; the parse, the run building, the index retire and the sentinel boundary see identical header values. **Verdict: no model change needed.**

## 2026-10-01 — register-fixes §6.2: CR-012 option F (a second live mutator is forbidden), CR-012(d) fixed (GC_MODEL_001)

Pins fired: region `AL.acquireOldGenBlock` (**4f5f0b1d4dcd**), region `AL.releaseOldGenBlock` (**0fe08577fb84**).

Change (plans/threaded-gc-register-fixes.md §6.2, CR-012 option F; HEAP_007, HEAP_060, GC_DET_001
amended): (1) `initThread` aborts when another `ThreadLocalHeap` is live unless
`allowMultipleMutators(true)` (a new `thread_mutex_`-guarded flag, reset by `reset()`; opted in only by
`main.cpp --threads N>1` and the two-heap test harnesses). (2) `acquireOldGenRegion` goes through
`PageWork::onFreshBump` (and the commit observer) like `acquireOldGenBlock`'s bump, so a heap's
initial region commits only the part above the commit-ahead window (CR-012(d), fixed with sequential
mutators too). (3) Hardening (§6.2 step 6): `old_gen_in_use_bytes_` is a `std::atomic<size_t>`
written only under `thread_mutex_` by a relaxed load + relaxed store (`addOldGenInUse` /
`subOldGenInUse`), read relaxed by `getOldGenCommittedBytes` (the unlocked triggers): no RMW, no
ordering, same values; TSan `cr012:a` is now clean. `allowMultipleMutators` takes `thread_mutex_` as a
leaf (it calls nothing).

Only the in-use byte counter's access changed (same values); the extent choice, the free list and the bump are unchanged. **Verdict: no model change needed.**

## 2026-10-01 — register-fixes §6.3: CR-007 fixed, no-wait acquire for a promotion holder with n > 1 (GC_MODEL_001)

Pins fired: regions `OGS.allocateFromBagPage` (**8707d299ec96**), `OGS.ensureBagPageAvailable` (**37f3ac00eb2f**), `OGS.allocateLargeBlock` (**e2c48a27f642**), `OGS.releaseBlockToAllocator` (**2dc05c9c0440**), `OGS.releaseUnassignedBlockToAllocator` (**b1038520c58f**), `AL.acquireOldGenBlock` (**58fd49f66454**).

Change (plans/threaded-gc-register-fixes.md §6.3, CR-007; HEAP_058/HEAP_059 amended): a promotion
holder of a parallel promotion with n > 1 workers (`OldGenSpace::acquireWaitPolicy()` =
`AcquireWait::AvoidUnderPromo`, passed at `ensureBagPageAvailable`, `allocateFromBagPage` and
`allocateLargeBlock`) gets the no-wait policy in `Allocator::acquireOldGenBlock` (modes 1/2 with
decommit on): (1) the first fitting **Pending** extent (`PageWork::isPending`, job-blind; `onReuse`
cancels it, never waits), (2) else a fresh bump, (3) else -- the old-gen cap leaves no bump room --
today's first fit (may wait; counted). The first-fit body was factored into a `takeFreeAt` lambda
(no behaviour change for `Allowed`). New PageWork API: `isPending`, `decommitOn`, `noteNoWait` (the
counters `nowait_pending_reuse_bytes`, `nowait_fresh_bytes`, `nowait_fallback_waits` and the M7 trace
event `nw`), `noteNoWaitSkip` (`nowait_skipped_extents`). Validate builds: a no-wait Pending reuse
must not raise `reuse_waits`, and `releaseBlockToAllocator` / `releaseUnassignedBlockToAllocator` abort
while `acquireWaitPolicy() != Allowed`. No lock, atomic or memory order is added; every new
PageWork call runs under `thread_mutex_` like the old ones.

M8 models the block lifecycle serially and treats the page supply as "some extent"; which free extent or fresh bump an acquire returns is not an M8 choice, and the release paths only gained a validate-only abort. **Verdict: no model change needed.**


## 2026-10-01 — register-fixes Phase 5: owner check at the GC entries (GC_MODEL_001)

Pins fired: regions `TLH.minorGC` (**896f924a1e35**), `TLH.majorGC` (**69a04246e15b**).

Change (plans/threaded-gc-register-fixes.md §7, Phase 5; HEAP_007 fork contract, HEAP_058, HEAP_065,
HEAP_070 amended, HEAP_075 new): (1) `GCFork.{hpp,cpp}`: ONE `pthread_atfork` registration with fixed
layers (gangs: registry -> each background gang's `m_` to set `fork_hold_` -> `stopAllForFork` -> each
gang's `m_` held -> `GCMarkGang` `run_m_` -> its `m_`; allocator: `thread_mutex_`; census: the P1 census
mutex and detector N's; pool: `GCHelperPool::m_`, drained and held); the three old registrations are
gone. (2) No teardown holds `thread_mutex_` while it takes a gang lock (`cleanupThread`,
`finishTenureForExit`, `reset`, `~Allocator`). (3) CR-003/015: `post`'s Idle->Posted CAS and the enqueue
in one `m_` section; the pool prepare drains and keeps `m_` in one section; the allocator layer locks
`thread_mutex_`, the child re-creates it and records `fork_child_` / `fork_owner_`. (4) CR-013/004:
`GCBackgroundGang::launch` returns false (refuses) while `fork_hold_`; `launchBackground` then leaves
`bg_ep_ = None` (`cm.episodes_refused`), `tenureLaunch` / `tenureConcLaunch` count `rs.fork_refusals`
and the join's orphan path finishes the job. (5) CR-023: `stopAndJoin` waits for
`generation_ != my_gen || finished_ >= members` and clears `running_` only for its own generation;
`launch` notifies `cv_done_`. (6) CR-005: `closingFinish` accepts `bg_ep_ == None`. (7) CR-031:
`~Allocator` (and `initThread`, `getCombinedStats`, `validatePageWork`) never touch a heap the forker
does not own in a forked child; validate builds check `ThreadLocalHeap::owner_` in `minorGC` /
`majorGC`. (8) CR-032: the census layer; `atexitReport` returns in a forked child. Trace-only: the
probe `m6.tm.held` in `onGCPauseEnd` (under `thread_mutex_`), `fork.bghold`, `gang.refuse`, the step
event's `refused` field and an M1 `stop` after a refused launch.

Only a validate-only `assertOwner` at the entry of `minorGC` / `majorGC` (HEAP_007 / CR-031). No block
lifecycle step changes. **Verdict: no model change needed.**

## 2026-10-01 — frontend-heap-release P1: explicit release, ShrinkPass::Forced (GC_MODEL_001)

Pins fired: regions `OGS.onSweepComplete` (**fecf4917088c**), `OGS.maybeShrinkCapacity` (**16f2d7bb56c4**).
New pin: region `TLH.majorGCAndShrink` (M1, M4, M8).

plans/frontend-heap-release.md P1 (§3, HEAP_076): the explicit release. New `ThreadLocalHeap::majorGCAndShrink` (TLA-REGION `TLH.majorGCAndShrink`): ONE pause and ONE sync point (an outermost `PauseEndHook` around a nested `majorGC(MajorReason::Explicit)`, then `OldGenSpace::finishSweepForRelease` (lazy sweep driven to Idle, `while (gc_phase_ != GCPhase::Idle)`, aborts if a cycle is active) and `shrinkToFloorForRelease` = `maybeShrinkCapacity(0, ShrinkPass::Forced)`). New `Allocator::collectMajorAndRelease` (after that pause, under `thread_mutex_` only: TLA-REGION `AL.releaseDiscard` = `page_work_->drainAll(decommitOn())` + counter reads; `malloc_trim` after the lock) and `Allocator::collectMinor` (two `thread_mutex_` snapshot sections around a plain `minorGC`). Both are fatal inside a pause (`pause_depth_ != 0`).

What changed in the pinned regions: `bool light_pass` → `ShrinkPass { Heavy, Light, Forced }` (the two
existing callers unchanged in behaviour), and the `Forced` arm: no hysteresis, the same floor
`max(initial_old_gen_size, alloc_buffer_size)`, nothing at all during a compaction, an unfinished sweep
(`gc_phase_ != GCPhase::Idle`) or a mark cycle.

Re-audit. M8's `Shrink`/`ShrinkPass`/`ShrinkPick`/`BagPass` already abstract `maybeShrinkCapacity`'s
hysteresis gates and `desired_heap` as "any desired size from the floor up" (MAPPING §3), so the forced
pass (desired = the floor, no gate) is one of the modelled runs; its guards only add early returns. Its
caller is a new serial path: STW major → `finishSweepForRelease` (the same `lazySweep` the model's sweep
loop is, run to `Complete`, whose `onSweepComplete` light shrink is unchanged) → the forced shrink, all on the
mutator inside one pause, which M8 (serial) covers as a sequence of its existing steps: `fully_swept`,
`live_bytes == 0` (HEAP_073) and the flip/reclaim interplay are unchanged, and no block is released that
the heavy or light pass could not release with a lower `desired_heap`. **Verdict: no model change needed.**

## 2026-10-05 — macOS build: BufferMetadata::live_bytes declared uint64_t (GC_MODEL_001)

Pin fired: file `BlockTable.hpp` (**37a0440b8bf9**).

Change: `BufferMetadata::live_bytes` is declared `uint64_t` instead of `size_t`, the type of the
`std::atomic_ref<uint64_t>` that `initObjectHeaderWithSize`, `flushCursorW` and `finalizePoppedCellW`
already apply to it. On macOS `size_t` (`unsigned long`) and `uint64_t` (`unsigned long long`) are
distinct types, so those `atomic_ref`s did not compile; on LP64 Linux they are the same type, so the Linux
build is unchanged. Width and representation are unchanged on every platform, and M8's `lb` is a value.
**Verdict: no model change needed.**

## 2026-10-09 — plans/large-object-space.md: the large-object space, header-less bodies, O7 (GC_MODEL_001)

Change (plans/large-object-space.md, HEAP_080/HEAP_081): every old-gen-direct large object (split String/Bytes bodies, YLOS, pinned pointer-free objects, the permanent fallback) now lives in LOS blocks: ordinary `alloc_buffer_size` blocks acquired like bag pages and materialized with `BlockInfo::los` (page index, mark arena, region bounds unchanged), whose free space a mutator-only `LargeObjectSpace` manages (1 KiB granules, a bitmap per block); larger objects keep is_large blocks. Every LOS object is tracked in `large_bodies_` (kind 0 body, 1 YLOS, 2 old: `promoteYoungLarge` and `promoteLargeHeader` re-kind to 2 instead of erasing); `losSweepAtMarkEnd` (inside `finalizeMetaAfterMark`) frees unmarked tracked LOS entries and sets LOS `live_bytes` to used granules; empty LOS blocks beyond `los_empty_keep` are released after the reclaim. LOS blocks are excluded from the flip, reclaim, shrink, evacuation and lazy sweep (`fully_swept` stays true). Bodies are header-less in raw blocks (`kLosRaw`): `greyObject` marks them without a push. O7: `takeFreeAt` releases a reused extent's tail.

Pins fired: file `BlockTable.hpp` (**275f070c6f0f**: `BlockInfo::los`, kLosBlock/kLosRaw); regions `OGS.classifyBlocksAfterMark` (**71443a1141f0**), `OGS.sweepNurseryLargeBodies` (**5eae8e786621**), `OGS.freeLargeBodyCell` (**bf5198fc3e22**), `OGS.promoteYoungLarge` (**c9b5ac30eae3**), `OGS.registerLargeBody` (**b84bdbca9fc6**), `OGS.allocateFromEmptyRegularBlocks` (**01961268bb26**), `OGS.lazySweep` (**f2052ad635f1**), `OGS.maybeShrinkCapacity` (**90bb953ccd90**), `AL.acquireOldGenBlock` (**c06879029f66**).

**The model no longer described the code** (young large objects and pinned objects took cells from `allocate()`: bag pages and large blocks). **Verdict: model updated.** `BlockLifecycle.tla`: constants `LOS` (TRUE = the code since 2026-10-09; FALSE = the earlier placement, which every pre-existing row keeps, so the CR-018 / CR-035 rows, controls and mutants stay meaningful history) and `LosKeep`; a block field `los`; `LosAlloc`/`LosPlace` (allocateLos: any free granule run of an LOS block, else a fresh LOS block from the bag, `Gate` = initObjectHeaderWithSize), `RegisterOld` (kind 2, not owned), `FreeLosCell` (freeLargeBodyCell's LOS arm), `PromoteYL` re-kinds under LOS, `SweepBodies` drops kind-2 ids, `LosSweep` (losSweepAtMarkEnd) after the mark, `LosReleaseEmpty` after the reclaim; `FlipOK`/`ReclaimPick`/`ShrinkPick` skip LOS blocks and `ResetForMark` keeps them fully_swept; invariants `IndexFaithful` (kind 2 entries), `BlockParseable` and `FreeListsInLiveBlocks` (LOS blocks), new `LosTracked` and `LosSeparation`. New rows: `MC_quick_los.cfg` (pass: 470,469 distinct states; witness runs confirm every new path is reachable: los_alloc, los_block, los_free, los_sweep, los_release, promoteyl_los), `MC_quick_los_page.cfg` (pass: 35,496), mutant `mutants/los_promote_untracks.cfg` (violates `LosTracked`: the promotion leak found 2026-10-09 by LargeBodyChurn (b), which a code validator `validateLosTracking` now also catches: negative control recorded in the plan). Spot checks of pre-LOS rows with `LOS = FALSE`: `MC_quick_mutator.cfg` pass (188,810 states, unchanged), `mutants/flip_keeps_index.cfg` violates `IndexFaithful` (unchanged). MAPPING.md §2/§3/§5 updated. The full `tla-check` run is recorded in plans/large-object-space.md §10.
