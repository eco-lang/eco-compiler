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
