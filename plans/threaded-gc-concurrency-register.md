# Threaded GC — concurrency register

**What this is:** the rolling record of concurrency defects in Eco's GC and its runtime interface.
Every defect is recorded from the moment it is suspected until it is closed, with the evidence for
each step. Created 2026-09-28, seeded from the protocol mapping done for
`plans/threaded-gc-tla-verification.md` (§8 of that plan defines this file).

**Line numbers** are from the tree named in each entry. Entries seeded on 2026-09-28 were
re-verified against the post-7c tree the same day. Functions are named too, because lines drift.

**It is a record, not a plan.** It has no steps and is never "done". Fixes are planned in the
relevant phase plan or in a small plan of their own. This file links to that plan and records the
outcome.

---

## How to use this file

**What goes in:** any suspected or confirmed concurrency defect, whatever found it:
- code reading;
- a TLC counterexample;
- a rejected trace (`tla-trace`);
- a TSan report;
- a GenMC/C11 finding;
- a validator abort;
- a determinism mismatch between thread counts or under jitter;
- a stress crash.

Also recorded:
- **coverage gaps** (a protocol path no harness exercises);
- **premise drift** (a plan, comment or invariant claims something the code does not do, and a
  model or audit relies on the claim).

**Ids:** `CR-NNN`, assigned in order and never reused. Entries are never deleted: a closed entry
stays as history. Split an entry when its parts need different fixes, and link the pieces.

**Status: each step needs the evidence named here.**

| Status | Entered when |
|---|---|
| Suspected | there is a plausible reading or hypothesis. Cite file:line **and** the function, with the tree date |
| Confirmed | code reading establishes the access pattern beyond doubt (quote the lines), **or** a model that is faithful to its MAPPING.md produces a counterexample |
| Reproduced | a recorded command makes it happen or makes a checker report it: a TSan harness, GenMC/C11 driver, TLC trace, unit test or stress config |
| Guarded | a regression guard (test, validator, model mutant or harness scenario) **fails on the current code**. It may land disabled or expected-fail until the fix |
| Fixed | the fix has landed, the guard passes, and the guard fails again when the fix is reverted (the negative-control rule every threaded-GC phase uses) |
| Closed | the fix has been through the gates of the phase that owns the code |
| Not-a-bug | a written argument says why, preferably a model result |
| Won't-fix | accepted risk, with the rationale and a guard that notices if the accepted premise changes |
| Duplicate | points at the surviving entry |

**Severity**

| Class | Meaning |
|---|---|
| S1 | unsound: a live object freed, lost or corrupted |
| S2 | a C++ data race (undefined behaviour) whose effect is benign today. It must still be fixed: the compiler may exploit it, and "benign" is an argument that decays |
| S3 | liveness: deadlock, livelock, unbounded stall |
| S4 | environmental robustness: fork, exit, signals, multiple heaps. Give the precondition |
| G | coverage gap: no harness, test or validator exercises the path |
| D | premise drift: a document claims something the code does not do |

A conditional severity is written as `S4 → S1`: an environmental precondition whose consequence,
if met, is unsound.

**Update points:**
- at discovery;
- at each model step's close-out (`plans/threaded-gc-tla-verification.md` §9);
- at each threaded-GC phase close-out (add "register: N open" to the master plan §4 row);
- whenever a canary re-audit turns up a defect.

Keep the summary table sorted by status, then severity.

**Cross-links:**
- each entry names the model that should catch it, and that model's A6 row lists the entry's
  mutant;
- a fixed entry's guard is named in the owning phase plan's gates.

**Entry template**

```
### CR-NNN — <one-line title>

| | |
|---|---|
| Status | Suspected (YYYY-MM-DD) |
| Severity | S? |
| Found | YYYY-MM-DD, <how> |
| Where | file:line in function() (tree of YYYY-MM-DD) |
| Models | M? |
| Invariants | ... |
| Repro | — |
| Guard | — |
| Fix | — |

<Description. Evidence (quote the lines). Why it matters. Next step.>

History:
- YYYY-MM-DD <status>: <what happened, who or what found it>
```

---

## Summary

Updated 2026-09-29, after the models, the weak-memory drivers, trace validation and the register
guards were implemented (plans/threaded-gc-tla-verification.md §11). Sorted by status (open and
guarded first, then reproduced, confirmed, suspected, fixed, not-a-bug), then severity. Every entry
has its evidence and history below; CR-025 to CR-038 are new since the model plans' review.

| Id | Title | Status | Sev | Model |
|---|---|---|---|---|
| CR-014 | lazySweep's tail completion path runs `onSweepComplete()` inside a parallel minor, bypassing the deferral (also races `live_bytes` and `large_body_index_`; with LIFO re-issue, a double allocation) | Reproduced (TLC); Guarded (model) | S1 + S2 | M4, M7, M3 |
| CR-016 | Empty-regular-block flip under `promo_mu_` vs a worker's stash or claimed chunk (exact-size promotion; test geometries) | Reproduced (TLC; TSan with heap corruption); Guarded | S1 (test geometries) | M4 |
| CR-017 | Region mode: the t0 young walk greys old cells that a STW major freed, through dead hand-over objects (at k = 2 also through dead ageing extents) | Reproduced (code, TLC); Guarded; S1 chain suspected | S1 (suspected) | M1, M5, M4 |
| CR-018 | After the sweep, mixed-block allocations are not counted in `live_bytes`, so the empty-block flip can take a live block (**serial**, not a concurrency defect) | Reproduced (code); Guarded (xfail test) | S1 | — (unit test) |
| CR-033 | `allocateFromBagPage`'s fresh-page carve leaves an 8-byte tail without a header (**serial**) | Reproduced (TLC); Guarded (model) | S1 in legacy allocation; benign in bitmap mode (default) | M8 |
| CR-034 | Region mode: a YLOS address reused after a STW major is taken for a hand-over member (ABA); its slots dangle | Reproduced (code; TLC three ways, k = 1 and 2); Guarded (model) | S1 | M5, M3 |
| CR-035 | The empty-block flip keeps stale large-body index entries, so a live body at the same address can be freed (**serial**) | Reproduced (TLC); Guarded (model) | S1 | M8, M4 |
| CR-037 | Region mode: the hand-over's `lb_bodies` colouring by address hides a new YLOS at a reused address from the minor | Reproduced (TLC); Guarded (model) | S1 | M5 |
| CR-001 | `gc_phase_` written under `promo_mu_`, read unlocked by other promotion workers; the allocate-black/accounting decision moved from pop to finalize | Reproduced (TLC, GenMC, TSan); Guarded | S2 + S1 | M4, W3 |
| CR-002 | Gap sweep's plain word read shares a bitmap word with a batch-popped cell's `fetch_or` after the unlock | Reproduced (TLC, TSan, traces); Guarded | S2 | M4, W3 |
| CR-019 | Legacy mode: a young YLOS header written under `ylos_mu_`, read by a sweep slice under `promo_mu_` | Reproduced (TSan, every run); Guarded | S2 | M3 |
| CR-028 | The validate-only V11 header walk in `lazySweep` races with workers writing popped cells | Reproduced (TSan); Guarded | S2 (validate builds) | M4 |
| CR-007 | A `promo_mu_` holder can block on a helper discard job (a stall; deadlock is Not-a-bug by M7b) | Reproduced (TLC witness); Guarded | S3 | M7 |
| CR-023 | A foreign `stopAndJoin` can wait out a whole relaunched episode | Reproduced (TLC; code: 43/11,653 forks); Guarded | S3 | M6 |
| CR-003 | `GCHelperPool::atforkPrepare` drains and locks in two critical sections (also strands Running jobs; the child's `exit()` hangs) | Reproduced (TLC; code, deterministic arm); Guarded | S4 | M6 |
| CR-005 | A foreign stop (e.g. a fork's prepare) before `closingFinish` trips `assert(bg_ep_ == Finished)` (on in the everyday `build` preset) | Reproduced (TLC; code: 14/40 trials); Guarded | S4 | M2, M6 |
| CR-013 | Tenure-collector fork window: the child inherits a job stopped mid-item (lost start, double copy, or an L3 hang at exit) | Reproduced (TLC, 3 ways); Guarded (model) | S4 → S1 in the child | M5, M6 |
| CR-015 | `Allocator::thread_mutex_` has no atfork handler: a non-mutator fork while it is held leaves it locked in the child | Reproduced (TLC; code: 3–8% of host forks); Guarded | S4 | M6 |
| CR-031 | A host-forked child's `exit()` tears down the dead mutator's heap (crashes on the torn `RootSet`) | Reproduced (fork harness); Guarded | S4 | M6 |
| CR-032 | The validate-only P1 census has a mutex and tables with no atfork handler | Reproduced (fork harness); Guarded | S4 (validate) | M6 |
| CR-038 | k ≥ 2: a dead ageing-generation YLOS keeps an unhealed slot into a retired extent, read by the t0 snapshot | Reproduced (TLC) | D (latent; opt-in k ≥ 2) | M5 |
| CR-012 | Multi-mutator only: unlocked committed-bytes reads, process-wide decommit clocks and free list, `acquireOldGenRegion` vs commit-ahead, `validatePageWork` | Confirmed; **decision needed** (support or forbid multiple mutators) | S2 (precondition) | — |
| CR-036 | IM5's t0-block check cannot see a same-id, same-start re-issue | Confirmed (shape) | G (validate) | M1, M4 |
| CR-021 | Plain reads of region bounds and owner words while markers hold `atomic_ref`s ([atomics.ref.generic]/3) | Fixed | S2 (letter) | W4 |
| CR-006 | gc-heap-tsan ran with `gc_thread_mode = 0`: the pool and concurrent marking were never under TSan together | Fixed (the `pool` arms, 0 warnings) | G | M6/M7 |
| CR-008 | No harness covered fork, multiple heaps, or a gang thread waiting on a pool job | Fixed for fork and two heaps (the fork harness); the pool-wait part is CR-006's | G | M6/M7 |
| CR-010 | IM14 (slot quiescence) was asserted only at launch | Fixed (slot-range asserts at every slot touch; negative control) | G | M1/M2 |
| CR-011 | `MinorWork.hpp` claimed a runtime test of the composed forward words; none existed | Fixed (unit test) | G | none (unit test) |
| CR-020 | No TSan harness ran the parallel YLOS reach with more than one worker | Fixed (harness and heap arms, 0 warnings) | G | M3 |
| CR-030 | Three 05b/05c unit tests failed intermittently (vacuous negative controls, a test hook cleared early) | Fixed (tests); runtime Not-a-bug | G | M2, M1 |
| CR-009 | `recomputeRegionBounds` wrote `region_end_` directly, not through the setter | Fixed | D | M1/W4 |
| CR-022 | Comments justified promotion chunks as "whole bitmap bytes"; the scans need whole words | Fixed | D | M4, W3 |
| CR-024 | `GCHelperPool.hpp` said the gang's `atexit` handler is registered at the first launch | Fixed | D | M6 |
| CR-025 | Helper-job stalls on gang threads were counted as outside the pause | Fixed | D | M7 |
| CR-026 | HEAP_058 and `GCHelperPool.hpp` described the helper handshake more narrowly than the code | Fixed | D | M7, M6, W |
| CR-027 | The 06 shared-state table and a comment misdescribed `gc_phase_` and `live_bytes` | Fixed | D | M4 |
| CR-029 | The bag rung (parallel ladder, serial heap exhaustion) sent size-classed requests to `allocateFromBagPage`, whose assert forbade them | Fixed (assert and comment; guard tests); options (b)/(c) open | D + abort in assert builds | M4 |
| CR-004 | Background-gang fork window: a launch can happen between `stopAllForFork` and the gang locks | Not-a-bug (proposed, M6: `ChildHeapSafe` holds for every mutator fork) | S4 | M6 |

---

## Entries

### CR-001 — `gc_phase_` race in parallel promotion, and a decision point that moved

| | |
|---|---|
| Status | Reproduced (2026-09-29): TLC (M4, both halves), GenMC (W3d) and **TSan on the real allocator** (the race). Guarded (model rows; the TSan `promo` scenario) |
| Severity | S2; possibly S1 (see "why it matters") |
| Found | 2026-09-28, protocol mapping for the TLA+ plan |
| Where | write: `OldGenSpace.cpp:5247` in `lazySweep()`; unlocked reads: `:1075` in `finalizePoppedCellW()`, `:1135` in `finalizeBitmapCellW()` (post-7c tree of 2026-09-28) |
| Models | M4 (race detector, plain field `gc_phase_`; configs `sweep_race_phase`, `sweep_release`) |
| Invariants | HEAP_051, HEAP_054, HEAP_067, IM4, PM6, GC_DET_001 |
| Repro | race half: `test/genmc/run_drivers.py --only w3d` (GenMC RC11 reports the race on `phase_idle`: a plain write under the lock against the unlocked read). Heap level still proposed: a gc-heap-tsan scenario that forces sweep-on-demand, ladder rung 5/8, inside a parallel minor |
| Guard | M4 `sweep_race_phase` (`violates:NoRacePhase`) and `sweep_release` (`violates:ReleasedSafe`); `test/genmc` row `w3d` (expected `race`). All fail on the current code by design and flip to pass with the fix |
| Fix | — |

**Evidence.** `gc_phase_` is a plain `GCPhase` field (`OldGenSpace.hpp:815`). Inside a parallel
minor, ladder rungs 5/8 run `lazySweep` under `promo_mu_`. When the sweep finishes it does
`gc_phase_ = GCPhase::Idle` (`:5247`). Other workers read the field **outside** the lock:

```cpp
// finalizePoppedCellW, :1075 (called after unlock, and for stash pops before the lock)
if (marking_active || gc_phase_ != GCPhase::Idle) {
    hdr->color = Black; ... setMarkBitAtomic(id, result);
    std::atomic_ref<uint64_t>(blocks_.meta(id).live_bytes).fetch_add(cell_size, relaxed);
} else { hdr->color = White; }
// finalizeBitmapCellW, :1135
hdr->color = (marking_active || gc_phase_ != GCPhase::Idle) ? Black : White;
```

The phase 6 plan assumes nothing writes during the pause (06 plan, around line 578). This write
breaks that assumption.

**Why it matters.** There are two separate problems:
1. **Undefined behaviour.** An unsynchronised plain write and read of the same object is a data
   race, whatever the observed values.
2. **The decision point moved, even if the field were atomic.** In serial promotion, a free-list
   pop and its finalize are adjacent, so the pop's phase decides the colour and the `live_bytes`
   accounting. In parallel promotion a cell can be popped under the lock while the phase is
   Sweeping, and then another worker (or, through the stash, the same worker later) can complete
   the sweep before the finalize runs. The finalize then sees Idle and **skips the
   `live_bytes += cell_size`** that the serial order would have done.
   - When N > 1, `onSweepComplete` is deferred to the merge (`sweepCompleteInPromotion`), and its
     shrink reads per-block `live_bytes`.
   - An **under**-count is the dangerous direction. parallel-gc.md §3.5 records the historical
     bug: "lost increments ⇒ a live block released as all-dead".
   - Whether any post-sweep reader can release or demote a block because of this under-count is
     **not yet established**. That is the question that decides S2 or S1.

**Update (2026-09-28, M4 plan).** A concrete path to S1 has been identified, not yet confirmed:
- the sweep completes inside a parallel minor, so `onSweepComplete` is deferred
  (`sweepCompleteInPromotion`, `:1361`);
- cells finalized after that point see `Idle` and add nothing to `live_bytes` (`:1075`; the same
  holds for `initObjectHeaderWithSize`, `:497`);
- the deferred light shrink then runs in `endParallelPromotion` (`:1530-1533`) and releases blocks
  whose `live_bytes == 0` (`:5802`).

A block could therefore be released with a freshly promoted object in it. That needs a mixed block
that is all-dead at the mark yet still unreleased until the sweep; whether that can happen is the
M4 plan's open question 1. See also CR-014, which reaches the shrink without the deferral at all.

**Next step.**
- Check every reader of `live_bytes` between sweep completion and the next mark (the deferred
  shrink, block release, demotion, IM6).
- Build the heap-tsan scenario.
- Model it in M4 (the plain-field race and the pop/finalize split).
- Fix candidates:
  - decide colour and accounting **at pop time**, under the lock, and carry the decision with the
    stashed cell;
  - make `gc_phase_` a relaxed atomic. This alone fixes only problem 1.

History:
- 2026-09-28 Confirmed (code reading): the write/read pair was reported by a mapping agent and
  verified by reading the lines above. The pop/finalize decision-point issue was found while
  verifying it.
- 2026-09-28 Adversarial review of the TLA+ plans:
  - **More callers.** The 7c pause tenure engine runs the same promotion ladder on `GCMarkGang`
    members: `runJobParallel` (`NurseryTenure.cpp:1167`) calls `allocatePromotion` (`:984`) on the
    sync path (`:523`), the grant fallback (`:549`) and help (`:643`). So the race is reachable
    from 7c help too, not only from the phase-6 parallel minor.
  - **Model.** M4's free list was FIFO while the code's is LIFO (`pushSpanOnFreeLists` `:4989-4997`,
    `tryPopFromFreeList` `:2004`), which made the S1 half unreachable in the model; fixed. The
    configs `sweep_race_phase` and `sweep_release` now target the race and the release.
  - **Related serial defect.** CR-018 is the same `live_bytes` blind spot without any concurrency.
- 2026-09-28 Race half Reproduced (C11): GenMC 0.19 (RC11) on W3d, which includes the real
  `BitmapScan.hpp` and reduces the phase-change code, reports the race on `phase_idle`
  (`test/genmc/AUDIT.md`). The S1 half (the moved allocate-black/accounting decision) is M4's.
- 2026-09-29 Reproduced (TLC), both halves (`test/tla/M4-promotion-bitmap/AUDIT.md`):
  - race: `sweep_race_phase`, 19 states. W1's chunk allocation reads `gc_phase_` without the lock
    (`finalizeBitmapCellW`, `OldGenSpace.cpp:1136`); W2 completes the sweep under the lock and
    writes `gc_phase_ = Idle` (`:5272`). Nothing orders the two.
  - S1 half: `sweep_release`, 32 states. W1 batch-pops D's cells 6 and 7; W2 completes the sweep,
    deferring the shrink; W1 finalizes cell 6, reads Idle and adds no `live_bytes`; the deferred
    shrink at the merge releases D with cell 6 in it (subject to the shrink's sizing rule, M4 plan
    §10 Q1).
  - Fix candidates (M4 controls): `phase_atomic` passes `NoRacePhase` but still fails
    `ReleasedSafe` (the moved decision point remains); `count_until_shrink` passes `ReleasedSafe`.
- 2026-09-29 **Reproduced under TSan on the real allocator** (M4 wave 2): `build-heap-tsan/gc-heap-tsan promo …` (`test/gc-heap-tsan/promo_sweep.cpp`, the TSan build; expected-fail, never part of the default run) reports the race in
  all 8 runs with sweep slices of 4 KiB or more (never at 144 B, where the sweep never finishes
  inside a minor). The pair: the in-loop `gc_phase_ = Idle` (`OldGenSpace.cpp:5352`, under
  `promo_mu_`) against the unlocked plain read in `finalizePoppedCellW` (`:1089`).

### CR-002 — plain `clearBit` and atomic `fetch_or` on the same mixed-block bitmap byte

| | |
|---|---|
| Status | Reproduced (2026-09-29): TLC, TSan on the real allocator, and in real traces; Guarded (model row; the TSan `promo` scenario) |
| Severity | S2 |
| Found | 2026-09-28, protocol mapping |
| Where | `OldGenSpace.cpp:5360` `bitscan::clearBit(gbits, nb)` in `lazySweep()` (gap-sweep loop, under `promo_mu_`) vs `OldGenSpace.cpp:1083` `setMarkBitAtomic(id, result)` in `finalizePoppedCellW()` (outside the lock); also the sweeper's plain 64-bit word read `nextSetBit` (`:5339`, through `bitscan::loadWord`, `BitmapScan.hpp:25-29`) (post-7c tree) |
| Models | M4 (config `sweep_race_bitmap`), W3 (W3c classifies the pattern) |
| Invariants | HEAP_050, HEAP_055, IM4 |
| Repro | `test/tla/run_models.py --model M4 --config sweep_race_bitmap` (`violates:NoRaceBitmap`, 23 states); GenMC W3c classifies the race |
| Guard | M4 `sweep_race_bitmap` (expected-fail; flips to pass with the fix) |
| Fix | — |

**Hypothesis.** A mark byte covers 8 slots (64 heap bytes); the sweeper's `nextSetBit` reads a
whole 64-bit word (64 slots, 512 heap bytes), so the race window is a word, not a byte. The gap sweep advances in budgeted
slices, each under its own hold of `promo_mu_`. It flushes each gap to a free list and then
plain-clears the next live object's bit. So a free cell flushed in slice *k* can share a byte with a
live object that a later slice (*k*+1 or beyond) clears. In between, another worker can batch-pop
that cell into its stash (under the lock) and finalize it **outside** the lock, which
`fetch_or`s the same byte while the sweeper's plain read-modify-write of that byte is in flight.

**Consequences:**
- The C++ data race itself (undefined behaviour).
- The observable worst case is a lost allocate-black bit behind the sweep cursor. That looks
  harmless because Sweeping and Marking never overlap and `startMark` clears the bitmaps.

**Next step.**
- ~~Confirm the precondition in code~~ (done by the M4 review, below).
- Reproduce: M4 `sweep_race_bitmap` (TLC), W3c (C11 checker), and the CR-001 heap-tsan scenario.

History:
- 2026-09-28 Suspected: from the mapping agent's reading; the precondition is not yet independently
  verified.
- 2026-09-28 Confirmed (shape), by the M4 adversarial review's code reading. In one gap-sweep
  iteration `flushRun` (`:5359`) pushes the gap before `clearBit` (`:5360`); the budget is checked
  only at the loop head (`:5336`), so a slice can end with a flushed gap and a still-set bit in the
  same word; another worker's batch pop under the lock takes up to 17 cells into its stash and
  finalizes them outside the lock. The W review added the word-wide `nextSetBit` read. Not yet
  reproduced by any tool.
- 2026-09-28 GenMC W3c (C11): the finalizer's `fetch_or` outside the lock races the sweeper's plain
  `loadWord`/`clearBit` on the shared word, as expected. The driver hard-codes the precondition
  (the stashed cell and the gap in one word), so this classifies the race; it does not show that
  the interleaving is reachable. The status waits on M4.
- 2026-09-29 Reproduced (TLC): `sweep_race_bitmap`, 23 states. W2, promoting another size class,
  sweeps D and `[1,2]` and leaves the flushed cells; W1 batch-pops cell 1 and finalizes it with
  `fetch_or` on M1 after its unlock; W2's next slice does a plain `nextSetBit` word read of M
  (`OldGenSpace.cpp:5364`), unordered with that `fetch_or`. Fix candidate `finalize_in_lock` passes
  `NoRaceBitmap` (it does not fix CR-001's `NoRacePhase`).
- 2026-09-29 **Reproduced under TSan on the real allocator** (M4 wave 2): `build-heap-tsan/gc-heap-tsan promo …` (`test/gc-heap-tsan/promo_sweep.cpp`, the TSan build; expected-fail, never part of the default run) reports it at every
  sweep-slice size (10 of 13 runs without exact-size Arrays). The pair: `lazySweep` →
  `nextSetBit` → `loadWord` (a plain 8-byte read under `promo_mu_`, reached from `ladderFrom2W`)
  against `setMarkBitAtomic`'s `fetch_or` in `finalizePoppedCellW` after the unlock. Also seen in
  real traces: M4's hand-run `TraceRace.cfg` (the race detector over the trace spec) reports
  `NoRaceBitmap` violated in all 16 multi-threaded logs.

### CR-003 — `GCHelperPool::atforkPrepare`: drain and lock are separate critical sections

| | |
|---|---|
| Status | Reproduced (2026-09-29): TLC (M6) and **in code** (fork harness, deterministic `det-cr003` 5/5); Guarded |
| Severity | S4 |
| Found | 2026-09-28, protocol mapping |
| Where | `GCHelperPool.cpp:260-265` in `GCHelperPool::atforkPrepare()` |
| Models | M6 |
| Invariants | HEAP_058, HEAP_007 |
| Repro | `test/tla/run_models.py --model M6 --config pool_host_fork_stranded` (`violates:ChildNoStranded`, 10 states); `pool_fix_drain`, `pool_fix_post` (each fix alone still fails) |
| Guard | M6 `pool_host_fork_stranded` (expected-fail); `pool_fix_both` and `pool_host_child_fix_all` pass with the fixes modelled |
| Fix | — |

```cpp
void GCHelperPool::atforkPrepare() {
    GCHelperPool& p = instance();
    if (p.configured_.load(std::memory_order_acquire)) p.drain();
    p.m_.lock();
}
```

A `post()` from another thread between `drain()` and `m_.lock()` survives into the child as a job
in state Posted. `atforkChild` resets the queue, so the job is in no queue, and a later `wait()` on
it in the child never returns.

- Today every `post()` comes from the mutator under `thread_mutex_`. The hazard therefore needs a
  fork from **a thread other than the mutator** while the mutator is at a sync point. The embed
  host is the plausible source (for example, a child-process spawn on a Node host thread).
- Children that exec immediately are unaffected.

**Update (2026-09-28, M6 plan).** Draining under `m_` is not enough on its own. `post()` does its
Idle→Posted CAS **outside** `m_` (`GCHelperPool.cpp:153-157`) and enqueues later under `m_`
(`:169-176`), so a fork between the two still strands a Posted job. The M6 model predicts that the
fix needs the CAS under `m_` as well.

**Next step.** Model it in M6 (the environment action "fork from a non-mutator thread"). Candidate
fixes:
- drain while holding `m_`: wait on `cv_done_` for `outstanding_ == 0` inside one critical
  section, move the CAS under `m_`, and refuse new posts while a fork is pending;
- or document "fork only from the mutator" as a precondition and assert it.

History:
- 2026-09-28 Confirmed (shape): lines verified by reading; the precondition analysis is the
  mapping agent's.
- 2026-09-28 M6 adversarial review, checked by the orchestrator:
  - **Precondition, sharpened:** the stranded job matters in a child that calls `exit()` (not
    `_exit` or `exec`), or when the "other thread" is a second mutator (with two mutators, each one's
    fork is a non-mutator fork for every other heap).
  - **A second way to strand a job:** a job already Running on a pool worker is stranded too; the
    worker does not exist in the child.
  - **Consequence at exit:** the child's `exit()` runs `~Allocator` (the static
    `g_allocator_storage`), which locks `thread_mutex_` and calls `page_work_->drainAll`
    (`Allocator.cpp:218-224`), so it hangs on the stranded job.
- 2026-09-29 Reproduced (model), M6 (`test/tla/M6-lifecycle/AUDIT.md`). The shortest path is
  `post`'s CAS-to-enqueue window, not the drain-then-post story above: the mutator CASes j1 to
  Posted; the host thread drains (outstanding 0), locks and forks; j1 is stranded in the child.
  The drain-then-post story is `pool_fix_post`. Either fix alone fails; both together pass.
- 2026-09-29 **Resolution, from M6's step 7** (both choices modelled):
  - (a) "`fork()` without an immediate `exec` is supported only from a heap's mutator between
    pauses, with one mutator", plus a guard in the child handlers: every mutator-fork
    configuration passes, including a child that goes on running (`ChildProgress`). The guard must
    run **before** `thread_mutex_` is taken (`guard_after_tm` fails) and must cover `~Allocator`.
    It does not help CR-005 or CR-023, which happen in the parent.
  - (b) fix CR-003, CR-015 and CR-005 in code: `FIX=all` passes. A `thread_mutex_` atfork handler
    alone fixes CR-003 and CR-015, but only if its prepare runs **before** the pool's (the other
    order deadlocks the parent: `tm_last`). It adds the lock-order edges registry / gang `m_` /
    `run_m_` → `thread_mutex_`, which conflict with `~Allocator` and `reset` (they hold
    `thread_mutex_` and then take gang locks): M7b must check that. (b) also unmasks CR-013 at
    the child's `exit()` (once the hang is gone, `tenureTeardown` runs the orphan job), so (b)
    still needs (a)'s guard.
  - **Recommendation:** adopt (a) as the contract, with its guard before `thread_mutex_`, plus
    CR-005's fix. With the guard landed, CR-003, CR-004 and CR-015 become Won't-fix (guarded).
- 2026-09-29 **Reproduced in code** (M6 wave 2): `test/gc-heap-tsan/fork_harness.cpp` (target `gc-fork-harness`; each trial in its own process with a deadline, each child probing under `alarm()`; an arm exits 1 when it reproduces its entry), arm `det-cr003` (trace build;
  probe hooks hold one thread in the drain-then-post window while the host forks): 5 of 5. At random
  (`host`, 1,015 forks) CR-003 never shows on its own, because the CAS window sits inside a post
  that holds `thread_mutex_`, so it surfaces as CR-015.

### CR-004 — background-gang fork window: relaunch between `stopAllForFork` and the gang locks

| | |
|---|---|
| Status | Not-a-bug (proposed 2026-09-29, from M6): the window exists and is wider than described, but nothing is lost in a child forked by the mutator |
| Severity | S4 → S1 in the child |
| Found | 2026-09-28, protocol mapping |
| Where | `GCHelperPool.cpp:664-669` (bg-gang `atforkPrepare`: `stopAllForFork` under the registry mutex, then lock every gang's `m_`); relaunch at `OldGenSpace.cpp:4689-4692` in `runCycleStepConcurrent()` (post-7c tree) |
| Models | M6 |
| Invariants | IM15, HEAP_065 |
| Repro | — |
| Guard | — |
| Fix | — |

**Hypothesis.** With a fork from a non-mutator thread:
1. `stopAllForFork` stops and joins the running episodes.
2. Before prepare locks the gangs' `m_`, the mutator reaches a minor end. It sees
   `bg_ep_ == None` with work left and relaunches (`launchBackground` takes `m_`, which is not yet
   held).
3. Prepare then locks `m_` and the fork happens while the members are mid-run.
4. The child has no member threads. Entries the members had taken into their **rings** (locals on
   their own stacks) are in no deque, so the child's cycle can finish with live objects unmarked,
   and the handoff frees them.

**Possible exit (2026-09-28, M6 plan).** The window looks real, but it may be harmless. A child
forked by a thread other than the mutator has **no mutator for this heap**: the heap is bound to
the mutator thread, which does not exist in the child. So nothing in the child can run the cycle
that lost the entries. If M6's `ChildHeapSafe` holds, the proposed outcome is Not-a-bug, with a
guard that asserts the heap is never used from a thread that does not own it (already true
through `tl_heap_`).

**Next step.** Confirm in M6. If a fix is needed after all, the direction is the same as CR-003's:
one critical section, or a fork-pending flag that blocks relaunch.

History:
- 2026-09-28 Suspected: reported by the mapping agent; the relaunch site was verified by reading,
  the window was not reproduced.
- 2026-09-28 M6 adversarial review: the "possible exit" holds up so far. Nothing in the child runs
  the lost cycle, even at exit: `~OldGenSpace` only stops and resets the gang and never marks
  (`OldGenSpace.cpp:229-233`, checked by the orchestrator). The Not-a-bug verdict still waits on
  M6's `ChildHeapSafe` result (TLC). The same argument **fails for CR-013** (see there).
- 2026-09-29 M6: the window is confirmed (15 states) and wider than described: **any** launch (a
  later cycle's t0, or a relaunch) between `stopAllForFork` and the gang's `m_` lock. But
  `ChildHeapSafe` holds in every mutator-fork configuration, quick and deep: a child forked by the
  mutator never marks the dead heap, not even at teardown (M6 plan §2.5). For a fork from another
  thread, the child cannot use the heap at all (CR-003, CR-015), and the fork contract of CR-003's
  resolution excludes it. **Proposed Not-a-bug**; it becomes Won't-fix (guarded) once the fork
  contract's guard lands, which notices a host fork.
- 2026-09-29 The window is reproduced in code (M6 fork harness `relaunch`, 3 of 11,653 forks land in
  it; `det-cr004` 5/5) and the supported contract holds (`mut`: 302 mutator forks, every child
  finishes its cycle and checks every rooted value). The Not-a-bug proposal stands: nothing is lost
  in a child forked by the mutator.

### CR-005 — fork-stop during the closing join trips `assert(bg_ep_ == Finished)`

| | |
|---|---|
| Status | Reproduced (2026-09-29): TLC (M2, M6) and **in code** (fork harness `closing`: the parent aborts in `closingFinish` in 14 of 40 trials; `det-cr005` 5/5); Guarded |
| Severity | S4 (assert builds only, which include the everyday `build` preset: `-O2 -g -UNDEBUG`, `CMakePresets.json:34-35`; release builds fall through to a correct drain) |
| Found | 2026-09-28, protocol mapping |
| Where | `OldGenSpace.cpp:4598-4599` in `closingFinish()` (post-7c tree) |
| Models | M2 (`episode_stop`, invariant `ClosingFinished`), M6 (`ClosingFinished`) |
| Invariants | IM9, IM15 |
| Repro | `test/tla/run_models.py --model M6 --config gangs_host_fork` (`violates:ClosingFinished`, 46 states; also `gangs_host_fork_1cpu_closing` and the `mark_first` deep row) |
| Guard | M6 `gangs_host_fork` (expected-fail); the candidate fix (accept `None` after a fork-stop, then drain) passes as `gangs_host_fork_fix_closing` |
| Fix | — |

The closing join runs the foreground Members until termination, then calls
`reapBackground(/*wait=*/true)` and asserts `bg_ep_ == Finished`. A fork-stop from another thread
during the join makes the episode end without done, so reap returns None and the assert fires.
Without asserts, the following `if (!markStackEmpty())` drain (`:4601-4604`) completes the mark,
which is correct. It shares CR-003/004's non-mutator-fork precondition.

History:
- 2026-09-28 Suspected: the assert was verified by reading; the path is the mapping agent's
  analysis.
- 2026-09-28 Adversarial reviews:
  - **M2:** reachable in the model by hand trace: the closing joiner reactivates, the stop
    arrives, everyone exits, the members are done, and `done` is false. The assert became the
    named invariant `ClosingFinished`, so the runner can match it.
  - **M6:** it fires in the everyday `build` preset, not just in debug builds. A second mutator's
    own fork also triggers it.
- 2026-09-29 Reproduced (model), M6. The window is wider than recorded: **any** foreign stop whose
  member has not finished before `closingFinish` starts. Both early reaps return "Running", the
  closing members leave on the stop, `reapBackground(true)` returns `None`, and the assert fails
  in the parent. The candidate fix (accept `None`, then drain) passes.
- 2026-09-29 Reproduced at the marker-loop level too: M2 `episode_stop` (`violates:ClosingFinished`):
  the closing joiner reactivates, the stop arrives, the members and the joiner all leave, and
  `done` stays false. The leftover work stays in the deques, so a drain after `None` is complete
  (`episode_stop_drain` passes): the candidate fix loses nothing.
- 2026-09-29 **Reproduced in code** (M6 wave 2): `test/gc-heap-tsan/fork_harness.cpp` (target `gc-fork-harness`; each trial in its own process with a deadline, each child probing under `alarm()`; an arm exits 1 when it reproduces its entry), arm `closing`: the parent aborts in
  `closingFinish` in 14 of 40 trials (1,148 forks); `closing-early` (the wider window): 16 of 40;
  `det-cr005`: 5 of 5.

### CR-013 — tenure-collector fork window: the child inherits a job stopped mid-item

| | |
|---|---|
| Status | Reproduced (model, TLC, 2026-09-29), three ways; Guarded at model level by M5's expected-fail rows |
| Severity | S4 → S1 in the child |
| Found | 2026-09-28, while writing the M5 plan (finding F1 there) |
| Where | `GCHelperPool.cpp:664-669` (`GCBackgroundGang::atforkPrepare`: `stopAllForFork`, then lock each gang's `m_`); relaunch at `NurseryTenure.cpp:572` (`tenureLaunch`, exact engine) or `:1234` (`tenureConcLaunch`, L3); item bookkeeping at `TenureWork.hpp:301-305` (`SerialEngine::step`: `next_start++` before `tenure()`) and the stack pop before `scanCopy` (post-7c tree) |
| Models | M5 (`fork` configuration, mutant `fork_mid_item`), M6 |
| Invariants | TV1, HEAP_070, FORBID_HEAP_004 |
| Repro | `test/tla/run_models.py --model M5 --config fork` (`violates:TenuredEqualsLegacy`), `fork_orphan_copy` (`violates:ExactlyOnce`), `fork_l3` (`deadlock`) |
| Guard | the three M5 rows above (expected-fail; they flip to pass with a fix or with the fork contract's guard, see CR-003) |
| Fix | — |

**Hypothesis.** This is CR-004's window, but for the 7c tenure collector:
1. A thread other than the mutator forks.
2. `stopAllForFork` stops the tenure gang at an item boundary.
3. Before prepare locks the gang's `m_`, the mutator reaches a minor end and `tenureLaunch`
   relaunches the collector.
4. The fork then happens while the collector is in the middle of an item.
5. In the child the collector thread does not exist, but the job's bookkeeping says the item was
   taken:
   - the exact engine advances `next_start` (or pops its copy stack) *before* it copies and
     publishes;
   - for L3, the members' ring entries are on dead threads' stacks.
6. The child's orphan path (`tenureJoin`: "fork / orphan: treat as stopped", `NurseryTenure.cpp:615`)
   re-runs the exact engine from the recorded position, skipping the half-done item.
7. If that object is reachable only through the skipped start, it is never tenured, and the child's
   next minor aborts in TV1 at `resolveRetire`. With TV1 compiled out (release builds), the slot
   would dangle into a retired extent.

**Precondition:** a fork from a thread other than the mutator (CR-003, CR-004).

**Possible exit:** CR-004's argument applies here too. The child's orphan path runs at the child's
next minor, and a child forked by another thread has no mutator to run one. Resolve it together
with CR-004. **The M6 review found that this exit fails at teardown:** a host-forked child that
calls `exit()` runs `~ThreadLocalHeap` → `tenureTeardown` (`ThreadLocalHeap.cpp:238-241`) → the
orphan path (`runJobExact` / `tenureConcFinish`, `NurseryTenure.cpp:900-914`) on the dead mutator's
heap. It may abort in a validator, or wait on a half-published shadow word (M5 to assess).

**Next step:** reproduce in M5 (`fork_mid_item`) and M6.

History:
- 2026-09-28 Suspected: found by the M5 plan author; the item bookkeeping was verified by reading
  `TenureWork.hpp`; the window itself is CR-004's and not independently reproduced.
- 2026-09-28 M5 adversarial review:
  - the window is confirmed in `GCBackgroundGang::memberLoop` (`GCHelperPool.cpp:575-588`): a member
    that has reacquired the gang mutex runs its job outside it, so prepare's later lock does not
    stop it;
  - more failure modes in the child: an orphan copy (TV3/TV4 in validate builds); a copy's scan cut
    short (TV6, then a dangling slot); for L3, a dead member's BUSY entry that makes help spin
    forever (S3 in the child; TLC reports it as a deadlock, not an invariant);
  - reachable in M5 within 3 minors (`fork_mid_item`).
- 2026-09-29 Reproduced (model), M5, three ways:
  - `fork`: the collector takes o's start and vanishes (the fork); the child's orphan path finds
    the job done and merges without o, and TV1 fails at the next resolve.
  - `fork_orphan_copy`: the collector copies o but vanishes before publishing; help copies o a
    second time (TV3/TV4).
  - `fork_l3`: a dead L3 member leaves a BUSY shadow entry and help waits for it forever. This
    answers "M5 to assess": `tenureTeardown` → `tenureConcFinish` (`NurseryTenure.cpp:905-907`)
    waits the same way, so **an L3 child hangs at exit** (S4, the "possible exit" of this entry
    is a hang with the L3 engine).
  - The exact engine's teardown looks clean by code reading only (its merge uses `heal = false`,
    which skips TV3/TV4 and the resolves); teardown is not in the model.
- 2026-09-29 M6: the window is confirmed at the gang level too (`two_gangs_window`, 17 states: the
  7c collector gang is live when a host fork happens). The teardown consequence is M5's (above).

### CR-014 — lazySweep's tail completion path runs `onSweepComplete()` inside a parallel minor

| | |
|---|---|
| Status | Reproduced (TLC, 2026-09-29): the FATAL, the silent release and the `live_bytes` race; Guarded at model level by M4's expected-fail rows |
| Severity | S1 (suspected); an S2 race on `live_bytes` whenever the path runs |
| Found | 2026-09-28, while writing the M4 plan (its suspicion 2); verified by reading |
| Where | `OldGenSpace.cpp:5466-5472` in `lazySweep()` (tail path: `gc_phase_ = Idle; onSweepComplete();`), compared with the in-loop path at `:5247-5255` (`if (par_promo_active_) sweepCompleteInPromotion(); else onSweepComplete();`) (post-7c tree) |
| Models | M4 (configs `sweep_tail`, `sweep_tail_release`, `sweep_tail_live`), M7 (a release route into its lock chain), M3 (footprint: `large_body_index_`) |
| Invariants | HEAP_054, HEAP_067, PM4, PM6, IM5 |
| Repro | `test/tla/run_models.py --model M4 --config sweep_tail` (`violates:DetachNotCurrent`, 25 states), `sweep_tail_release` (`ReleasedSafe`), `sweep_tail_live` (`NoRaceLive`, no mutant needed) |
| Guard | the three M4 rows above (expected-fail; fix candidate `tail_defers` passes all three) |
| Fix | — |

`lazySweep` can finish the sweep in two places:
1. Inside its loop, when the cursor finds no block left. This path checks `par_promo_active_` and
   defers the post-sweep shrink to the merge.
2. After the loop, when the last block's final iteration used up the budget and the target class's
   list is still empty. This path calls `onSweepComplete()` **unconditionally**.

Inside a parallel minor, `lazySweep` runs under `promo_mu_` on a worker (sweep-on-demand and panic
rungs). So path 2 runs the shrink on that worker while other workers are still allocating:
- worker cursors hold unflushed pending bytes;
- stashed cells are popped but not finalized;
- a retired shared block may still be referenced by a worker's last chunk.

The shrink reads `live_bytes` and releases blocks. The outcomes range from an abort in
`detachFromAllocation` (every build) to a silent release of a block that holds, or is about to
hold, promoted objects. It is also reachable at N = 1 in 7c's pause engine: there the deferral
normally hands worker 0's cursors back first (`sweepCompleteInPromotion`), and path 2 skips that.

**Next step:**
- make the M4 model's two completion paths faithful and confirm the violation;
- then build a gc-heap-tsan or unit scenario whose sweep budget ends exactly at the last block
  inside a parallel minor.

**More consequences (adversarial review, 2026-09-28):**
- **A data race on `live_bytes`, whatever the shrink decides** (M4 review). The shrink reads
  `live_bytes` plainly (`:6378`, `:5802`) while other workers `fetch_add` it through `atomic_ref`
  (`:1033`, `:1084`).
- **A `std::unordered_map` data race that can crash** (M3 review; code shape verified). The shrink
  reaches `releaseBlockToAllocator` (via `maybeShrinkCapacity`, `:5502`, `:5873`), which iterates
  and erases `large_body_index_` (`:6061-6070`) under `promo_mu_`, while another worker's
  `reachYoungLargeP` calls `youngLargeMeta` → `large_body_index_.find` (`OldGenSpace.hpp:1190`)
  under `ylos_mu_`.
- **A stall** (M7 review): the release goes through `releaseOldGenBlock` → `PageWork::onRelease`,
  which can wait on an overlapping populate while holding `promo_mu_` (CR-007).

Candidate fix: route path 2 through the same `par_promo_active_` check as path 1.

History:
- 2026-09-28 Confirmed (shape): reported by the M4 plan author; both paths verified by reading.
- 2026-09-28 Three consequences added from the M3, M4 and M7 adversarial reviews; the boundary
  condition reworded (M4 review).
- 2026-09-28 M3 implementation (code reading) narrows the parallel minor's side: every route to the
  `large_body_index_` erase loop (`OldGenSpace.cpp:6056-6073`) goes through `maybeShrinkCapacity`,
  and `lazySweep`'s own erases (`:5311`, `:5404`) are on the header-walk path, which a parallel
  minor cannot reach (it needs bitmap allocation, `resolveMinorThreads`, `:2948`). So once the
  tail completion is deferred (the candidate fix), nothing outside `ylos_mu_` erases the index
  during a legacy drain.
- 2026-09-29 Reproduced (TLC), M4. `sweep_tail`, 25 states: W2 publishes queued block V and
  allocates in it inside the lock, so V is Current with `live_bytes` 0; W2's next promotion, of
  another size class, sweeps everything and completes on the tail path; the shrink picks V and
  `detachFromAllocation` aborts (`OldGenSpace.cpp:713-718`). Refinements: the FATAL needs a Current
  block of **another** size class (with one class, `advanceSharedW` retires the exhausted block
  first, `:1227-1228`), and the tail path needs the sweeper's own list empty after the last block
  (otherwise the early exit at `:5478` returns first). The silent release and the `live_bytes` race
  reproduce too; the race needs no mutant at all. `tail_defers` (the candidate fix) passes all
  three.
- 2026-09-29 M4 wave 2 (TSan scenario `promo`): the tail completion (`OldGenSpace.cpp:5594`) was
  never hit in 4 runs under gdb (against 35 and 56 in-loop completions in two of them), so CR-014
  is not reproduced on the real allocator yet. The scenario needs the M4 model's precondition: a
  Current block of another size class and the sweeper's own list empty after the last block.
- 2026-09-29 Address-reuse (ABA) audit: a further consequence, **Reproduced (model)** in M4. The tail-path
  shrink releases block D inside a parallel minor; the virgin rung then re-issues D's id (always:
  the free list is LIFO) and often its start (`startVirginBlockShared`, first fit). A worker's
  stashed cell of old D is then handed out a second time, so two promoted objects share one address;
  `mark_.assign` also zeroes a stale chunk's bits. `run_models.py --model M4 --config
  MC_quick_sweep_tail_reuse` violates `NoDoubleAlloc` (44 states); without the re-issue
  (`MC_quick_sweep_tail_nda`) it passes, and the fix candidate `tail_defers` still passes with it
  (`controls/tail_defers_reuse`). Also by reading: requeueing a re-issued non-uniform id makes it
  kAllocQueued, so a later detach asserts, or in NDEBUG builds indexes `partial_[NUM_SIZE_CLASSES]`
  out of bounds.

### CR-015 — `Allocator::thread_mutex_` has no atfork handler

| | |
|---|---|
| Status | Reproduced (2026-09-29): TLC (M6) and **in code** (fork harness: 3.2% of host-fork children, 7.9% with two heaps; `det-cr015` 5/5); Guarded |
| Severity | S4 |
| Found | 2026-09-28, while writing the M6 plan |
| Where | `Allocator::thread_mutex_` (a `std::recursive_mutex`), held around every helper post and wait (HEAP_058; `Allocator.cpp:753, 892, 1253`); `pthread_atfork` registrations exist only in `GCHelperPool.cpp:112, 340, 508` (post-7c tree) |
| Models | M6 (`ChildLocksFree`) |
| Invariants | HEAP_058 |
| Repro | `test/tla/run_models.py --model M6 --config pool_host_fork_locks` (`violates:ChildLocksFree`, 9 states) and `pool_host_child_hang` (`violates:HostChildProgress`, 14 states) |
| Guard | the two M6 rows above (expected-fail) |
| Fix | — |

If a thread other than the mutator forks while the mutator holds `thread_mutex_` (inside a pause
end, a block acquire or a release), the child inherits the mutex locked by a thread that does not
exist there. The child's first allocator call that takes it deadlocks. This happens whatever the
pool's own handlers do. The precondition is the same as CR-003 and CR-004. It only matters for a
child that uses the allocator without exec'ing. **Next step:** M6 `ChildLocksFree`; then decide,
together with CR-003/004, whether "fork only from the mutator, or exec at once" becomes a
documented, asserted precondition.

History:
- 2026-09-28 Confirmed (shape): reported by the M6 plan author; the registrations were grepped.
- 2026-09-28 M6 adversarial review: the child need not use the allocator to hang. `exit()` alone
  runs `~Allocator`, which locks `thread_mutex_` (`Allocator.cpp:218-224`). So the precondition is
  "a child that calls `exit()` (not `_exit`/`exec`)", or a second mutator's fork.
- 2026-09-29 Reproduced (model), M6: the mutator holds `thread_mutex_` when a host thread forks;
  in the child the first allocator call, or `exit()`, blocks forever (`host_child_hang`). The fix
  and the fork contract are discussed under CR-003 (2026-09-29).
- 2026-09-29 **Reproduced in code** (M6 wave 2): `test/gc-heap-tsan/fork_harness.cpp` (target `gc-fork-harness`; each trial in its own process with a deadline, each child probing under `alarm()`; an arm exits 1 when it reproduces its entry). Arm `host`: 3.2% of 1,015 host-fork
  children block on `thread_mutex_`; `two-heap`: 7.9% of 993 block on the other heap's
  `thread_mutex_`; `host-exit`: 2.3% of 1,372 children hang in `~Allocator`. Deterministic arm
  `det-cr015`: 5 of 5.

### CR-016 — empty-regular-block flip under `promo_mu_` vs a worker's stash (test geometries only)

| | |
|---|---|
| Status | Reproduced (2026-09-29): TLC, and **TSan on the real allocator, with heap corruption**, in test geometries; Guarded (model rows; the TSan `promo` scenario with exact-size Arrays) |
| Severity | S1, but only in test geometries |
| Found | 2026-09-28, while writing the M4 plan (its suspicion 3) |
| Where | `OldGenSpace.cpp:2665` `allocateFromEmptyRegularBlocks` (the `live_bytes == 0` test and skips at `:2676-2679`), stash return at `:1440-1443` (post-7c tree) |
| Models | M4 |
| Invariants | HEAP_054, PM6 |
| Repro | `test/tla/run_models.py --model M4 --config sweep_large` (17 states) and `minor_large` (16 states, no sweep pending), both `violates:ReleasedSafe` |
| Guard | M4 `sweep_large`, `minor_large` (expected-fail). No fix candidate yet: CR-016 still fails with every other fix on |
| Fix | — |

Under `promo_mu_`, a promotion of at least `alloc_buffer_size` bytes can flip an "empty" regular
block to large. It judges emptiness by `live_bytes == 0`, so it can pick a mixed block whose free
cells all sit, popped but unfinalized, in another worker's stash. The stashed cells are later
finalized into the flipped block, or pushed back onto a free list at the merge. The path needs a
nursery object at least a block long, which the 512 KiB default makes impossible; small test
geometries reach it. **Next step:** confirm in M4, then either make the flip skip blocks with
stashed cells or document the geometry precondition.

**Adversarial review (2026-09-28, M4):**
- the flip needs a promotion of **exactly** `alloc_buffer_size` bytes (a regular block's size; the
  block-size assert is at `:6015`, the flip's size test at `:2680`);
- a second variant needs no stash and no sweep: a retired shared block whose cells are all in
  workers' unflushed chunks. The skip at `:2676` covers only `kAllocCurrent` blocks, although the
  comment at `:2674` names this hazard;
- M4 now models it (`W_Large` step, config `sweep_large`; `ReleasedSafe` checks stashes too);
- the common root with CR-001's S1 half is CR-018: the flip trusts a `live_bytes` that is not
  maintained in every phase.

History:
- 2026-09-28 Suspected: reported by the M4 plan author; not independently verified.
- 2026-09-28 M4 adversarial review: the exact-size precondition, the chunk variant, and the model
  configuration added.
- 2026-09-29 Reproduced (TLC), M4, two variants. `sweep_large`: the flip takes D while W1's stash
  holds D's cells. `minor_large`, with no sweep pending: W1 claims V's only chunk; W2's
  `advanceSharedW` retires V to `kAllocNone`; W2's exact-size promotion then flips V while W1's
  cursor still points into it, because the flip skips only Current blocks (`OldGenSpace.cpp:2677`).
  It fails with every other fix candidate on, so it needs its own fix (CR-018 is its serial root).
- 2026-09-29 **Reproduced on the real allocator** (M4 wave 2): `build-heap-tsan/gc-heap-tsan promo …` (`test/gc-heap-tsan/promo_sweep.cpp`, the TSan build; expected-fail, never part of the default run) with exact-size Arrays on. TSan
  reports `MarkBitArena::drop`'s `memset` and the Array copy landing on another worker's `setBit`
  and objects, plus a plain `live_bytes` read (`OldGenSpace.cpp:2750`) against `flushCursorW`'s
  `fetch_add`. It **corrupted the heap**: one "Invalid tag after forward resolution" abort and one
  HEAP_BUILDER_001 abort. S1 is shown, still only in test geometries.

### CR-006 — the heap-level TSan harness never runs the helper pool

| | |
|---|---|
| Status | Fixed (2026-09-29): the gap is closed (coverage) |
| Severity | G |
| Found | 2026-09-28, protocol mapping |
| Where | `test/gc-heap-tsan/heap_driver.cpp:53` (`cfg.gc_thread_mode = 0;`) (post-7c tree) |
| Models | M6, M7 |
| Invariants | HEAP_058, HEAP_059, HEAP_060 |
| Repro | n/a |
| Guard | `gc-heap-tsan pool [jitter_us]` (the nine scenarios with `gc_thread_mode = 2`, two helpers, decommit on, commit-ahead) and two new default-run scenarios with the pool on (`test/gc-heap-tsan/README.md`, "Register arms") |
| Fix | — |

The only harness that runs the real allocator with concurrent marking and parallel minors has the
helper pool switched off. Deferred decommit, commit-ahead, and a gang thread blocking on a pool job
(CR-007) are therefore never under TSan together with marking. **Next step:** add a
`gc_thread_mode = 2` arm, plus a jitter arm, to gc-heap-tsan.

History:
- 2026-09-28 Confirmed: line verified by reading.
- 2026-09-29 Gap closed (wave 3b): `gc-heap-tsan pool` runs the nine scenarios with `gc_thread_mode =
  2`, two helper threads, `decommit_on_oldgen_release` on, discards posted at the next pause end
  and a 1 MiB commit-ahead window; with the CR-020 families on, each scenario releases 200–440
  extents and runs 26–38 Discard and 7–11 Populate jobs. Results: `pool` twice (458 s, 618 s), the
  jitter arm `pool 50` (427 s), and a stall-heavy `pool 20000 3 2` (42 pool stalls): PASS, **0 TSan
  warnings**. The default run gained two scenarios with the pool and families on (seeds 10, 11)
  and still passes with 0 warnings (11 scenarios, 559 s).

### CR-007 — a `promo_mu_` holder can block on a helper discard job

| | |
|---|---|
| Status | Reproduced (model, TLC witness, 2026-09-28) and Guarded (the witness row flips if the stall goes away). The deadlock hypothesis is Not-a-bug (M7b). The misattribution was split off as CR-025 (Fixed), HEAP_058's wording as CR-026 (Fixed) |
| Severity | S3 (a stall, not a deadlock) |
| Found | 2026-09-28, protocol mapping |
| Where | `OldGenSpace.cpp:1249-1251` `startVirginBlockShared()` → `ensureBagPageAvailable` (`:866-871`) → `Allocator::acquireOldGenBlock` (`Allocator.cpp:752`) → `PageWork::onReuse` → `GCHelperPool::wait` (`PageWork.cpp:151-169`); `callerInPause()` at `Allocator.cpp:1206` (post-7c tree). Two more routes into the same chain (M7 review, 2026-09-28): the CR-014 tail path (`lazySweep`, `OldGenSpace.cpp:5466-5476`, reached under `promo_mu_` from the ladder at `:2147`, `:2169`, `:2410`) → `onSweepComplete` → `releaseOldGenBlock` → `PageWork::onRelease` → a wait on an overlapping populate; and the pause tenure engine, whose `GCMarkGang` members promote through `allocatePromotion` (`NurseryTenure.cpp:984`, `runJobParallel` `:1167`) |
| Models | M7 (M7b: lock order, `MODEL_M7_StallWitness`) |
| Invariants | HEAP_058, HEAP_059 |
| Repro | `test/tla/run_models.py --model M7 --config lock_order_stall` (witness: `MODEL_M7_StallWitness` is violated, i.e. the stall state is reachable) |
| Guard | M7 `lock_order` and `lock_order_3` (deadlock check + `AllFinish` over the whole lock graph) guard the no-deadlock verdict; the three lock mutants (`tm_then_promo`, `worker_takes_tm`, `collector_takes_tm`) show a deadlock would be caught |
| Fix | — |

A parallel-minor gang thread that holds the promotion spin lock can take `thread_mutex_` and then
wait for a posted discard job. The lock order is `promo_mu_` → `thread_mutex_` → pool `m_`. Helper
jobs take no allocator locks, so there is no cycle, but every other promotion worker spins and then
sleeps in 10 µs steps. `callerInPause()` reads the calling thread's `tl_heap_`, which is null on
gang threads, so the stall is counted as outside the pause. **Next step:** confirm the path and
measure how often it fires (GC-pressure stress with `gc_thread_mode = 2`). Model deadlock freedom
and bounded waiting in M7.

**Premise drift in HEAP_058** (found by the M7 review): the row says helper jobs are "posted and
collected only at mutator slow paths", but waits also happen on gang threads, under `promo_mu_`.
When M7 runs, split this entry: the deadlock hypothesis becomes Not-a-bug by M7b (the lock graph
`promo_mu_` → `thread_mutex_` → {pool `m_`, a background-gang join} is acyclic); the stall and its
misattribution stay open, and HEAP_058's wording gets a D entry of its own.

History:
- 2026-09-28 Suspected: from the mapping agent's reading; not verified independently.
- 2026-09-28 Two more routes added and HEAP_058 drift noted, from the M7 adversarial review (routes checked by reading: `lazySweep` tail at `:5466-5476`, `allocatePromotion` call in the tenure engine at `NurseryTenure.cpp:984`).
- 2026-09-28 Split, as the M7 plan said (`test/tla/M7-pagework/AUDIT.md`):
  - **Deadlock: Not-a-bug.** M7b's `lock_order` (two members) and `lock_order_3` (three) pass
    TLC's deadlock check and `AllFinish` over the whole lock graph `promo_mu_` → `thread_mutex_` →
    {pool wait, tenure teardown's collector join}. The three lock mutants each deadlock.
  - **Stall: Reproduced (model).** `lock_order_stall` reaches the witness in 6 states: `mut`
    takes `promo_mu_` and `thread_mutex_`, meets the posted job and blocks in `wait`, while `g1`
    waits at `P_Promo`. How long and how often it fires is still a measurement (CR-006's
    `gc_thread_mode = 2` arm).
  - A further route found by the M7 implementation: `startVirginBlockW` (`OldGenSpace.cpp:1279-1281`)
    also reaches `acquireOldGenBlock` under `promo_mu_`, but only with one worker, so it cannot
    stall another worker.
  - The misattribution became CR-025; HEAP_058's wording became CR-026.
- 2026-09-29 Guarded: `models.txt` expects M7 `lock_order_stall` to reach `MODEL_M7_StallWitness`
  (`witness:`), so a change that removes the stall makes that row fail and forces a verdict. The
  stall's cost is still unmeasured (CR-006's `gc_thread_mode = 2` arm is the vehicle).
- 2026-09-29 The stall happens on the real allocator, race-free: under TSan (`gc-heap-tsan pool 20000 3
  1`, wave 3b), gdb backtraced 23 pool stalls with 0 warnings; 8 were this entry's route inside a
  parallel minor (`ladderFrom2W` → `startVirginBlockShared` → `ensureBagPageAvailable` →
  `acquireOldGenBlock` → `PageWork::onReuse` → `awaitSlot` → `GCHelperPool::wait`, with
  `promo_mu_` held). All 8 were on gang member 0, the mutator thread; no other gang thread was seen
  waiting, so the stall's effect on the other workers is what M7's witness shows and is still
  unmeasured in time.

### CR-008 — no harness covers fork, multiple heaps, or a gang thread waiting on a pool job

| | |
|---|---|
| Status | Fixed (2026-09-29) for fork and multiple heaps: the fork harness now covers them (arms `mut`, `host`, `host-exit`, `two-heap`, `closing`, `closing-early`, `relaunch`, and four deterministic arms); the gang-thread-waiting-on-a-pool-job part is CR-006's arm |
| Severity | G |
| Found | 2026-09-28, harness inventory |
| Where | `test/gc-helper-tsan/` (pool, mark, minor harnesses), `test/gc-heap-tsan/` |
| Models | M6, M7 |
| Invariants | HEAP_007, HEAP_058 |
| Repro | n/a |
| Guard | — |
| Fix | — |

Fork is covered only by unit tests that fork between pauses from the mutator
(`testHelperPoolSurvivesFork`, `testBgGangForkWhileRunning`, `testConcMarkForkDuringEpisode`). The
05c plan's Step 4.3 asked for forks inside the bg-gang storm, and `mark_harness.cpp` has none.
Multiple heaps appear only in the synthetic benchmark driver. **Next step:** a fork harness (a
forking thread that is not the mutator, at random points) and a two-heap arm. These are the
reproduction vehicles for CR-003/004/005.

History:
- 2026-09-28 Confirmed: the harness inventory was read.
- 2026-09-28 M6 review: the fork harness needs an arm where the child calls `exit()` (not only
  `_exit`), since CR-003, CR-013 and CR-015 all bite at the child's teardown.
- 2026-09-29 Trace validation (M1, `test/tla/traces.txt`): the trace scenarios of
  `test/gc-heap-tsan` (built without TSan) now reach a pressure finish and a fork-hook stop of a
  background episode (`stopAllForFork` called from the driver). The TSan scenarios still reach
  neither, so the gap stands for TSan; it is no longer a gap for model conformance.
- 2026-09-29 M6: the fork harness also needs two arms that the model shows matter: "a relaunch
  due during the fork's prepare" (CR-004's wider window, CR-023) and "a stop just before
  `closingFinish`" (CR-005's window).
- 2026-09-29 Gap closed for fork and multiple heaps (M6 wave 2): `test/gc-heap-tsan/fork_harness.cpp` (target `gc-fork-harness`; each trial in its own process with a deadline, each child probing under `alarm()`; an arm exits 1 when it reproduces its entry), with the arms this entry
  asked for (a non-mutator forking thread at random points; a child calling `exit()`; a two-heap
  arm; a relaunch due during prepare; a stop just before `closingFinish`) plus deterministic arms
  for CR-003, CR-004, CR-005 and CR-015. It found two new defects (CR-031, CR-032).

### CR-009 — region bounds: plan says "only through the setters", the code has a direct write

| | |
|---|---|
| Status | Fixed (2026-09-29) |
| Severity | D (benign today) |
| Found | 2026-09-28, protocol mapping |
| Where | `OldGenSpace.cpp:561` in `recomputeRegionBounds()` (`region_end_ = new_end;`), vs 05c plan G12 / row H5 (post-7c tree) |
| Models | M1, W4 |
| Invariants | HEAP_049, IM5 |
| Repro | n/a |
| Guard | the canary's region pin `OGS.recomputeRegionBounds` (W4): restoring the direct write fails `tla-canary` (checked 2026-09-30). Not the footprint grep H5 (`region_end_ =\|region_base_ =`): it matches nothing now, and it did not match the original line either (two spaces before `=`). GenMC `W4_RECOMPUTE_PLAIN` states the hazard |
| Fix | `recomputeRegionBounds` (`OldGenSpace.cpp:577-597`, tree of 2026-09-30) calls `setRegionEnd(new_end)` |

Row H5 of the 05c audit relies on every `region_base_`/`region_end_` write going through
`setRegionBase/End` (relaxed `atomic_ref` stores). `recomputeRegionBounds` calls `setRegionBase`
but assigns `region_end_` directly. Its callers (`maybeShrinkCapacity` and the release paths)
assert `!cycleActive()` (IM5), so no background marker is running, and the write is not a race
today. It becomes one if a release path is ever allowed during a cycle. **Next step:** route it
through `setRegionEnd`, then pin it with the footprint grep `region_end_ =`.

History:
- 2026-09-28 Confirmed: line verified by reading.
- 2026-09-28 W review: `W4_RECOMPUTE_PLAIN` states the hazard in C11 terms (a plain write racing a
  marker's relaxed `atomic_ref` load, if a release path ever ran during a cycle). The guard is
  still the footprint grep `region_end_ =`.
- 2026-09-28 GenMC: `W4_RECOMPUTE_PLAIN` is flagged (a race on `region_end`) when the plain write
  runs during a cycle, which today's IM5 asserts prevent. No status change: the fix is still to route
  the write through `setRegionEnd`.
- 2026-09-29 Fixed (wave 3a). Every region-bound write now goes through the setters; the grep
  `region_end_ =|region_base_ =` matches nothing outside them. Unit tests and GenMC (60/60) pass.
- 2026-09-30 Guard checked by reverting the fix in a copy of the tree to be merged
  (`/tmp/cr-register/`). Restoring `region_end_  = new_end;` fails `tla-canary`, but only through
  the region pin `OGS.recomputeRegionBounds`. H5 does not fire: its ERE needs exactly one space
  before `=`, and the original line has two. So H5 would not have caught this defect.
  `region_(base|end)_ *=` would match any spacing. Status unchanged.

### CR-010 — IM14 (slot quiescence) is asserted only at launch

| | |
|---|---|
| Status | Fixed (2026-09-29): the validator gap is closed |
| Severity | G (validator gap) |
| Found | 2026-09-28, protocol mapping |
| Where | `OldGenSpace.cpp:4361` `assertSlotsQuiescent()`; its only caller is `:4433` (`launchBackground`) (post-7c tree) |
| Models | M1, M2 |
| Invariants | IM14 |
| Repro | n/a |
| Guard | test "threaded-gc-05c: negative control — an assist resetting a background slot's counter is caught (IM14, CR-010)" (`test/allocator/ConcurrentMarkTest.cpp`; a validate build: `cmake --preset build -DECO_HEAP_VALIDATE=ON`, then `test/test --filter threaded-gc-05c`) |
| Fix | `OldGenSpace::assertSlotsQuiescent(where, lo, hi)` takes a slot range (the launch call keeps its meaning); validate builds call it at every mutator touch of owner-only slot state: `reset`, `prepareMark`, `ensureMarkers`, `markLiveTake`, `markLiveMergeAll`, `runMarkers` (reset, merge), `handoffMarkCycle` (sum, deque reset), `retireAllDequeArrays` (every slot: trap 6), `mergeBackgroundCounters` [F, S), `assistEpisode` and `closingFinish` (foreground slots only), `setSnapshotMode(true)` (slot 0) |

The mutator may touch a slot's owner-only state (stack, deque push/take, retired arrays, counters,
accumulator) only while no gang runs on it. Merges, `retireAllDequeArrays`, deque resets and
counter resets are protected by control flow, not by an assertion. A future change to the step
logic could break IM14 silently. **Next step:** call `assertSlotsQuiescent` in validate builds at
every owner-only mutator touch (the merge, the retirement, the reset). Then check with M2/M1 that
the assertion points match the model's quiescence precondition.

History:
- 2026-09-28 Confirmed: the call sites were grepped.
- 2026-09-28 M1 review: M1's `IM9` covers the handoff's quiescence point; launch and relaunch are
  quiescent by construction in M1 (t0 runs with no episode). The merge and retirement points
  belong to M2's model.
- 2026-09-29 M2 implementation: every mutator touch of a slot's owner-only state matches the model's
  per-slot quiescence precondition. But `assistEpisode` (`OldGenSpace.cpp:4644`) and `closingFinish`
  (`:4680`) reset the **foreground** slots' `ctr` while the background gang legitimately runs on the
  other slots, so `assertSlotsQuiescent` as written (`bg_->running() || fg_run_active_` → abort)
  would fire there. **Next step (refined):** give it a slot range, as `assertNoPrivateWork` has,
  and call it at the merge, the retirement and the reset for the slots actually touched.
- 2026-09-29 Fixed. The foreground-only ranges at the assist and closing resets remove the false
  positive M2 predicted. Negative control: the validate-only hook `test_assist_resets_bg_ctr_`
  widens the assist's reset to background slot F; the child aborts with "IM14: slots [0, …)
  touched at an assist's counter reset while the background gang runs", and without the hook it
  exits 0. Validate tree results: 05a 25/25, 05b 19/20 (the CR-030 flake), 05c 35/35, 06 18/18,
  07 39/39; `gc-heap-tsan` default run PASS (441 s, no TSan warning, no IM14 abort). Release
  code: every new check compiles away; only the launch check changed (now inlined, with the new
  message). Note: no CMake preset turns `ECO_HEAP_VALIDATE` on; validate runs need
  `-DECO_HEAP_VALIDATE=ON`.

### CR-011 — the promised runtime layout test for forward words does not exist

| | |
|---|---|
| Status | Fixed (2026-09-29): the gap is closed by a unit test with a negative control |
| Severity | G |
| Found | 2026-09-28, protocol mapping |
| Where | `MinorWork.hpp:17-18` (comment: "static_assert on the tag, runtime test on the composed words"); `NurseryParallel.cpp:39-40` (the static_assert) |
| Models | none: M3 assumes the encoding (its trace validation cannot see a mismatch either, because the harness decodes with `mw::fwdAddr`, which always agrees with `mw::fwdWord`) |
| Invariants | HEAP_006, HEAP_067 |
| Repro | n/a |
| Guard | `testForwardWordMatchesBitfields` (`test/allocator/ConcurrencyRegisterTest.cpp`; `build/test/test --filter CR-011`) |
| Fix | the test itself; the comment at `MinorWork.hpp:17-20` names it |

`MinorWork.hpp` builds forward and BUSY words from its own bit constants (tag bits 0..4, colour
5..6, `forward_ptr` 7..46). Only the tag value is pinned against `Heap.hpp`'s bitfields. The 06
plan's `testForwardWordMatchesBitfields` is absent: no test file mentions `fwdWord` or `kBusy`. A
change to the `Header`/`Forward` bitfield layout would make the parallel minor publish forwards that
the rest of the runtime decodes differently. **Next step:** add the test (compose words with
`mw::fwdWord` and decode them through `Heap.hpp`'s `Forward`, over edge addresses and colours).
Cases the test must include: `dst = 8`, `dst = HPOINTER_ADDRESS_LIMIT - 8`, every colour, and
`fwdWord(dst, c) != kBusy` for all of them. An address at or above 2^43 would mask to BUSY and
hang every waiter. This is a unit test's job, not a model's: TLA+ sees the words as abstract
states.

History:
- 2026-09-28 Confirmed: grep of `test/` and `runtime/`.
- 2026-09-28 Models field corrected by the M3 adversarial review: no model can catch this; the unit test is the guard.
- 2026-09-28 M3 implementation: M3 assumes the header encodings never collide, as expected; no
  model or trace can see a layout mismatch. `test/genmc/w5_forwarding.cpp` round-trips through
  `mw::fwdAddr` only, so it is not the missing test either. The unit test is still the guard.
- 2026-09-29 Fixed (gap closed): `testForwardWordMatchesBitfields` composes words with
  `mw::fwdWord` for 88 addresses (8, `HPOINTER_ADDRESS_LIMIT - 8`, halves, each of the 40 address
  bits set and clear) × 4 colours, decodes each through `Heap.hpp`'s `Forward` and `Header`,
  rebuilds it from the bitfields, checks the `mw` decoders and `!= kBusy`, and checks BUSY's
  decoding and `(kFwdMask + 1) << 3 == HPOINTER_ADDRESS_LIMIT`. It passes; with `kColorShift`
  changed from 5 to 6 in a scratch copy it fails ("mw::colorOf != colour").

### CR-012 — multiple mutators only: unlocked committed-bytes reads and process-wide decommit clocks

| | |
|---|---|
| Status | Confirmed (2026-09-28) for the accesses; the precondition (more than one mutator) holds only in the benchmark driver |
| Severity | S2 (precondition: more than one mutator) |
| Found | 2026-09-28, protocol mapping |
| Where | `Allocator.hpp:251` `getOldGenCommittedBytes()` returns `old_gen_in_use_bytes_` with no lock; read by triggers at `OldGenSpace.cpp:4124, 4253, 5547, 5770`. `Allocator::sync_epoch_`/`major_epoch_` (`Allocator.hpp:381-382`) are process-wide (post-7c tree) |
| Models | — (M7 if multiple heaps are ever modelled) |
| Invariants | HEAP_007, GC_DET_001, HEAP_059 |
| Repro | — |
| Guard | — |
| Fix | — |

With more than one mutator:
- `old_gen_in_use_bytes_` is written by one heap's thread under `thread_mutex_` while another
  heap's trigger reads it without the lock: a data race.
- Decommit aging runs on process-wide clocks that interleave between heaps, so per-heap
  determinism (GC_DET_001) does not hold across heaps.
- The released-extent free list is process-wide too, so which extent a heap reuses depends on
  other heaps' releases: that alone breaks per-heap GC_DET_001 (M7 review).
- Suspected (M7 review, 2026-09-28): `Allocator::acquireOldGenRegion` (`Allocator.cpp:1004-1006`)
  maps `[heap_base + old_gen_committed, +initial_size)` with `commitAt`, which is
  `mmap(MAP_FIXED)` (`PlatformVirtualMemory_posix.cpp:70-75`), without calling `onFreshBump`. It
  runs at every heap creation (`OldGenSpace::initialize`, `OldGenSpace.cpp:341`). If another heap's
  pause end has opened a commit-ahead window over that range and posted a Populate, the new
  mapping throws the populated pages away, possibly while the populate runs. The range is fresh,
  so this costs RSS and latency, not contents; it contradicts HEAP_060's "never re-mapped" claim.
- Suspected (M7 review, validate builds only): `validatePageWork` (`Allocator.cpp:1281-1289`)
  reads every heap's `blocks_` and `unassigned_blocks_` under `thread_mutex_` alone, while other
  heaps' mutators change those tables without that lock (e.g. `materializeVirginBlock`).

Production entry points create exactly one mutator; only `runtime/src/main.cpp`'s
`program_threads` creates more. **Next step:** decide whether multiple mutators are supported. If
not, assert it outside the benchmark driver and mark this Won't-fix with that guard. If they are,
use a relaxed atomic plus per-heap clocks.

History:
- 2026-09-28 Confirmed (accesses): the reads and the unlocked accessor were verified by reading.
- 2026-09-28 Three multi-heap findings added from the M7 adversarial review (free-list determinism; `acquireOldGenRegion` vs commit-ahead; `validatePageWork`). M7 now states that multiple heaps are outside its scope (M7 plan §10 Q1).
- 2026-09-28 Scope note from the M7 implementation: every PageWork call, waits included, holds the
  process-wide `thread_mutex_`, so M7a's one modelled caller stands for any number of heaps.
  HEAP_059, HEAP_060, V1, V2 and `PostIdle` therefore hold with several mutators too. Only the items
  listed above stay open.
- 2026-09-29 **Decision needed (the user's)**, with the analysis done (wave 3a). The only producer
  of more than one mutator is `runtime/src/main.cpp`'s `num_program_threads` (plus the
  gc-heap-tsan harnesses and a few unit tests).
  - **Supporting** several mutators needs: `old_gen_in_use_bytes_` a relaxed atomic (or read under
    `thread_mutex_`); per-heap `sync_epoch_`/`major_epoch_` and released-extent free list (per-heap
    GC_DET_001); `acquireOldGenRegion` through `onFreshBump` (HEAP_060); `validatePageWork` per
    heap; M7 (or a new model) over several heaps; TSan runs with 2+ heaps and the pool on.
  - **Not supporting** them needs: `initThread` to abort on a second live `ThreadLocalHeap` unless
    an explicit opt-in is set (benchmark mode, test harnesses); a unit test that it aborts and that
    the opt-in suppresses it; HEAP_007 to state one mutator per process; this entry Won't-fix with
    that guard.
- 2026-09-29 Address-reuse audit: `Allocator::thread_heaps_` is keyed by `std::thread::id`
  (`Allocator.hpp:410`, adopted at `Allocator.cpp` ~:335); if a mutator thread exits without
  `cleanupThread` and the id is recycled, a new thread adopts the old heap. Multiple mutators only;
  latent.

### CR-017 — region mode: the t0 young walk greys old cells that a STW major freed

| | |
|---|---|
| Status | Reproduced in code (2026-09-29, k = 1 and k = 2) and in the models (M1, M5); Guarded (expected-fail unit tests; model rows) |
| Severity | S1 (suspected, long precondition chain). Certain effects: floating garbage, spurious validate-build aborts. Also D: the 07 plan (P§3.16) calls the walk of dead objects "conservative and safe" |
| Found | 2026-09-28, adversarial review of the M1 plan; checked by the orchestrator |
| Where | `NurserySpace::forEachYoung`, `NurserySpace.hpp:800-830` (walks Young and Tenuring extents, skips only `Tag_Free`); `ThreadLocalHeap::startMarkCycle` `markChildren`, `ThreadLocalHeap.cpp:1102`; the only zap is 07b's, for ageing extents, `mergeJob` `NurseryTenure.cpp:816-825`; `OldGenSpace::startMark`, `OldGenSpace.cpp:2881-2889` (a STW major marks nursery objects from roots only) (post-7c tree) |
| Models | M1 (`quick_region`: expected `MarkerFootprint` violation; `quick_region_nomajor` passes), M5 (`YoungWalkValid`, config `cycle_major`), M4 (`marker_on_post_t0`: the worst case's lost bit) |
| Invariants | IM3, IM13, HEAP_063, HEAP_SNAPSHOT_001 |
| Repro | `test/tla/run_models.py --model M1 --config MC_quick_region` (TLC, 17-state counterexample, `test/tla/M1-snapshot-mark/AUDIT.md`); `--model M5 --config cycle_major` and `k2_cycle_major` (`YoungWalkValid`). Code-level repro still proposed: a validate-build unit test in region mode, k = 1: x → c with c old, drop x, explicit major, then force the trigger at the next minor |
| Guard | model only: `models.txt` expects M1 `MC_quick_region` to violate `MarkerFootprint`, and M5 `cycle_major`, `k2_cycle_major` and `deep` to violate `YoungWalkValid`; each flips to `pass` in the fixing change. A code-level guard (the unit test above) is still needed for Guarded |
| Fix | — |

With the default region nursery and tenure age k = 1, the Tenuring extent at a minor is the one
filled at the previous minor, so it holds objects that died during the last epoch. The 07b merge
zaps dead **ageing** objects exactly because "no walker (t0 young walk, census, validators) reads
its possibly dangling slots", but nothing zaps dead hand-over objects. The chain:
1. x is copied into extent E at minor m−1; x then dies with its only-referenced old child c.
2. A STW major runs in that epoch (an explicit major, or an allocation failure in
   `allocateYoungLarge`/`allocateLargePinned`). It traces nursery objects from roots only, so it
   frees c.
3. At minor m, E is handed over (Tenuring), the trigger fires, and `forEachYoung` walks x:
   `markChildren(x)` greys c's freed cell.
4. Effects: a mark bit on a free cell and a marker scanning its stale image (floating garbage);
   validate builds can abort in IM4 (`assertCellWasWhite`) when the cell is reallocated
   mid-cycle, or IM6 at the handoff.
5. Worst case (suspected S1): the stale image's children lie in a block released after the major
   and rematerialised as a post-t0 cursor or grant block. A background marker's test-and-set there
   races the owner's plain `setBit` (IM13's premise), which can lose an allocate-black bit and free
   a live copy at the handoff.

Candidate fixes: at a region-mode STW major, zap the dead objects of the Young and Tenuring extents
it did not reach (as the 07b merge zap does), or mark the hand-over extent transitively at the
hand-over minor and zap what it did not reach before the t0 walk. Either makes M1's `quick_region`
and M5's `cycle_major` pass.

History:
- 2026-09-28 Confirmed (shape): found by the M1 adversarial review; the orchestrator verified each
  cited line (the walk's `Tag_Free`-only skip, the ageing-only zap and its comment, `startMark`'s
  roots-only marking). M5 added `YoungWalkValid` and reproduces it by hand trace in 2 minors.
- 2026-09-28 Reproduced in the model: M1's first implementation. TLC's shortest counterexample is
  exactly the chain above: minor 1 ages 3, drop `r2`, a STW major frees 4, minor 2 keeps the dead 3,
  and t0 greys the freed 4. With no STW major, region mode passes every invariant
  (`MC_quick_region_nomajor`, 1,028,216 states; `MC_deep_region`, 9,043,480 states).
- 2026-09-29 Reproduced from M5's side (`test/tla/M5-tenuring/AUDIT.md`), and **wider than this
  entry said**:
  - `cycle_major` (47 steps) and `deep` (50): y → seed is allocated over the seed's root; minor 1
    copies y into extent A; y is dropped; a STW major frees the seed; minor 2 hands A over; the t0
    walk reads the dead y's field naming the freed seed.
  - **New, `k2_cycle_major` (tenure age k = 2, 07b):** a Fresh object dies in the epoch in which a
    major frees its old child. At the next minor its extent becomes an **ageing** extent, which the
    t0 walk reads before that extent's first ageing mark, so 07b's zap cannot help.
  - Consequence for the fix: zapping at the STW major must cover the dead objects of **every** Young
    extent the major did not reach, not only the Tenuring extent. The candidate "hand-over minor
    marks and zaps its extent" is not enough on its own at k > 1.
  - M5 also notes that the t0 snapshot walks every young YLOS (`snapshotYoungLarge`); M5 models
    it, and the YLOS walk is not part of this defect (young YLOS are marked black at t0).
- 2026-09-29 **Reproduced in code**, both variants, in the ordinary RelWithDebInfo build (no
  validator needed): after the explicit major, c's cell is free, and the forced-trigger minor's t0
  walk marks it through the dead x, at k = 1 (the hand-over extent) and at k = 2 (the ageing
  extent). Negative control: with `test_snapshot_skip_young_walk_` set at that minor the cell stays
  unmarked (XPASS), so the greying comes from the young walk. Run (fails today):
  `ECO_TEST_XFAIL=strict build/test/test --filter "xfail CR-017"`. Guarded by the two `[xfail
  CR-017]` tests. The S1 chain beyond the greyed cell (a lost bit in a rematerialised block) is
  still not shown.
- 2026-09-29 **Not the cause of lss-payoff's reverted `k = 3.0` validate failure** (E2's HEAP_044
  abort): instrumented, the run's 6 t0 walks grey no old cell from a dead young parent, and
  suppressing every dead-parent grey (a superset of this entry's zap fix) turns the `[xfail CR-017]`
  tests into XPASS but leaves E2's abort unchanged. That failure is CR-034 (a YLOS address reused
  after a STW major). The same instrumentation does see this entry's grey in its xfail tests.
- 2026-09-29 Address-reuse (ABA) audit: a concrete S1-class consequence, **Reproduced (model)** in M1
  (`run_models.py --model M1 --config MC_quick_region_reuse`, violates `MarkerNoYoungKid` in 20
  steps; the new invariant is `MarkerFootprint`'s second conjunct on its own). The stale t0 grey of a
  freed cell survives into the cycle; the cell is popped again from a mixed free list during the
  cycle (`prepareMark` does not clear the lists: `OldGenSpace.cpp` ~:977, :988, :2581); a
  background marker then pops the stale entry and scans the **new** object (`scanObject` skips only
  Free and Forward headers). For a YLOS being filled, or a copy made in the middle of a minor, that
  is an abort in every build ("parallel marker reached nursery object", ~:3310) plus an S2 race with
  the writer; validate builds abort earlier, in IM4, at the pop. With the reuse but no dangling grey
  (`MC_quick_region_reuse_live`) nothing reachable is lost. This entry's fix removes the chain.
- 2026-09-29 Wider than recorded (M5 boundary work): the freed old cell can be a large header's own
  **body**, which the marker greys (`OldGenSpace.cpp` ~:3543-3548); no tenured object is needed. M5
  `MC_cycle_major_t0grey` violates the new invariant `T0GreyAllocated` (47 states).

### CR-018 — after the sweep, mixed-block allocations are not counted, so the empty-block flip can take a live block

| | |
|---|---|
| Status | Reproduced (code, 2026-09-29) and Guarded by an expected-fail unit test |
| Severity | S1. **Serial, not a concurrency defect**: recorded here because this work found it and it is the common root of CR-016 and CR-001's S1 half. Its fix belongs to the old-gen allocator |
| Found | 2026-09-28, adversarial review of the M4 plan; checked by the orchestrator |
| Where | `OldGenSpace::initObjectHeaderWithSize`, `OldGenSpace.cpp:497` (`live_bytes` is added only while `marking_active \|\| gc_phase_ != Idle`); `allocateFromEmptyRegularBlocks`, `:2665-2716` (flips any `fully_swept && live_bytes == 0` block, `:2672`; drops its free cells and its bitmap slot, writes a large header at its start); reached from `allocate()` for `size >= alloc_buffer_size` (`:1931-1933` → `allocateLargeBlock` → `:2733`); all-dead blocks kept by the shrink's `min_heap` floor (`:6214`) (post-7c tree) |
| Models | none (serial). M4 open question 3 |
| Invariants | HEAP_051, HEAP_054 |
| Repro | `ECO_TEST_XFAIL=strict build/test/test --filter "xfail CR-018"` (fails today) |
| Guard | `[xfail CR-018]` in the test suite's expected-fail convention (`test/allocator/ConcurrencyRegisterTest.cpp`): the default run passes while the defect reproduces (and fails with XPASS once it stops); `ECO_TEST_XFAIL=strict` asserts the fixed behaviour, so it fails today |
| Fix | — |

After the sweep completes (`gc_phase_ = Idle`), an allocation popped from a mixed block's free run
does not add to that block's `live_bytes`. A block that was all-dead at the mark, kept by the shrink
floor, and then refilled with small objects therefore still reads `fully_swept && live_bytes == 0`.
The next old-gen allocation of exactly `alloc_buffer_size` bytes (a regular block's size) can pick it
in `allocateFromEmptyRegularBlocks`, which flips it to a large block over the live objects. The
exact-size precondition makes it rare, but nothing prevents it at the default geometry (for example
a pointer-free buffer of exactly that total size). The same flip in the middle of a cycle aborts in
validate builds (the H9 check). **Fix candidates:** count mixed-block `live_bytes` in every phase,
or stop trusting it after the sweep (skip blocks that have handed out cells since their sweep).

History:
- 2026-09-28 Confirmed (shape): found by the M4 adversarial review; the orchestrator verified the
  phase gate at `:497`, the flip's test at `:2672` and its `removeFreeCellsForBlock` (which shows a
  flipped block may still have cells on the free lists), and the size dispatch at `:1931`.
- 2026-09-29 Reproduced in code, exactly as predicted: the mixed block P holds 49,152 live bytes
  but `live_bytes` reads 0, and a 64 KiB allocation flips P to a large block at P's start,
  overwriting all three 16 KiB objects. Negative control: a scratch candidate fix (count mixed-block
  cells in `live_bytes` at Idle, in `initObjectHeaderWithSize`) gives XPASS and `live_bytes` reads
  49,152. Guarded by `[xfail CR-018]`.
- 2026-09-29 **Reproduced (model)** too, M8 (`MC_quick_cr018`: `NoOverwriteLive`, 6 states;
  `MC_quick_cr018_flip`: `FlipTrustsTruth`): a band request carves a fresh page P; the object dies; a
  major keeps P by the `min_heap` floor and sweeps it; an Idle split in P adds nothing to
  `live_bytes` (`OldGenSpace.cpp` ~:522); an exact-page request flips P over the live object. Fix
  (a), counting the cell at Idle, passes. The same undercount applies to **every** mixed carve at
  Idle, including CR-029's bag-rung carve.

### CR-019 — legacy mode: a young YLOS header written under `ylos_mu_`, read by a sweep slice under `promo_mu_`

| | |
|---|---|
| Status | Reproduced (TSan, 2026-09-29) and Guarded (expected-fail arm) |
| Severity | S2 (legacy nursery only, not the default) |
| Found | 2026-09-28, adversarial review of the M3 plan |
| Where | writes: `NurserySpace::reachYoungLargeP`, `NurseryParallel.cpp:378` (`h->age++`), and `OldGenSpace::promoteYoungLarge`, `OldGenSpace.cpp:7125` (`age = 0`), both plain writes to the header word under `ylos_mu_`; read: the gap sweep's `walkStep(block, getObjectSize(live_obj))`, `OldGenSpace.cpp:5361`, inside `allocatePromotion` under `promo_mu_` (post-7c tree) |
| Models | M3 (footprint note only) |
| Invariants | HEAP_062, HEAP_067 |
| Repro | `gc-heap-tsan ylos-sweep [seed [rounds [workers [jitter_us [age [sweep_bytes]]]]]]` (`test/gc-heap-tsan/ylos_sweep.cpp`): TSan reports the race in 30/30 runs at the default 1024 B sweep slice, 40/40 at 4096 B, 10/10 with jitter 50, 10/10 at age 3, 3/10 at 144 B |
| Guard | the `ylos-sweep` arm (expected-fail; not in the default run) |
| Fix | — |

Two workers of a legacy parallel minor can touch one YLOS header under different locks: one ages
or promotes it, the other steps over it in a sweep slice. The sweep only visits a marked cell, and a
YLOS allocated while `gc_phase_ != Idle` is allocated black (`:497-518`). Benign on x86 (the tag and
size bits are rewritten unchanged), but a data race. **What would settle it:** whether a young YLOS
cell can sit in a **mixed** block that a sweep slice walks inside a legacy parallel minor. YLOS cells
come from `allocateTrackedCell` (`:7077`): large blocks and uniform blocks are never gap-swept
(`:1705`), so only a mixed-block placement matters. Alternatively, a `gc-heap-tsan` legacy scenario
that allocates a large pointer-bearing object during marking.

History:
- 2026-09-28 Suspected: from the M3 review; the orchestrator verified the write sites and that YLOS
  cells come from `allocateTrackedCell`; the mixed-block placement is not established.
- 2026-09-28 Confirmed (shape), from the M3 implementation's reading; the orchestrator re-read the
  lines. It answers the open placement question: a legacy YLOS whose size lies in [the largest size
  class, `alloc_buffer_size`) is allocated by `allocateFromBagPage` (`OldGenSpace.cpp:1940-1943`,
  `:2229`), i.e. in a mixed block; allocated during marking it is black (`:497-518`), and
  `prepareMetaForLazySweep` (`:3925-3933`) marks every block unswept. Inside a parallel drain,
  `ladderFrom2W` (`:1336-1346`) runs `sweepOnDemandAllocate` (and `panicSweepAndRetryAllocation`)
  under `promo_mu_`; the gap sweep then reads the live YLOS's header word through
  `getObjectSize(live_obj)` (`:5383`), while `reachYoungLargeP` writes `h->age++`
  (`NurseryParallel.cpp:378`) under `ylos_mu_`. Two different locks, one plain write: a data race if
  both run at once. Not shown dynamically. **Next step:** a `gc-heap-tsan` legacy scenario with a
  small nursery and mid-size pointer-bearing large objects (it also closes part of CR-020).
- 2026-09-29 **Reproduced under TSan** (wave 3b): legacy nursery with 4 KiB blocks, so each 2–4 KiB
  YLOS gets its own mixed bag page; a STW major leaves a lazy sweep pending; then parallel minors
  run with no pre-drain slice and no virgin block before sweep-on-demand. Key frames: the read is
  `getObjectSizeFromHeader` ← `lazySweep` (the gap sweep, or the V11 walk: CR-028) ←
  `sweepOnDemandAllocate` ← `ladderFrom2W` ← `allocatePromotion` ← `copyClaimed`, under
  `promo_mu_`; the write is `reachYoungLargeP`'s `h->age++` (`NurseryParallel.cpp:378`) or
  `promoteYoungLarge`'s `age = 0`, under `ylos_mu_`. All four write/read pairings seen (85 reports
  in the last 10 runs). About 3 s per run.

### CR-020 — no TSan harness runs the parallel YLOS reach with more than one worker

| | |
|---|---|
| Status | Fixed (2026-09-29): both halves of the gap are closed (coverage) |
| Severity | G |
| Found | 2026-09-28, adversarial review of the M3 plan |
| Where | `NurserySpace::reachYoungLargeP` (`NurseryParallel.cpp:359-391`) and its region twin `reachYoungLargeR`; `test/gc-helper-tsan/minor_harness.cpp` has no YLOS; `test/gc-heap-tsan/heap_driver.cpp:78-111` allocates no pointer-bearing large object |
| Models | M3 (`ylos_unlocked`) |
| Invariants | HEAP_062, HEAP_067 |
| Repro | n/a |
| Guard | `gc-minor-tsan` with the YLOS kind (harness half); `gc-heap-tsan ylos [jitter_us]`, the `pool` arm and two default-run scenarios (heap half) |
| Fix | — |

The `ylos_mu_` protocol (colour test, age, in-place promotion) is exercised only single-threaded
or not at all under TSan, and it touches `large_body_index_`, which CR-014 can race. **Next step:**
add a YLOS object kind to `minor_harness` (M3's trace plan needs it anyway) and a pointer-bearing
large object to `heap_driver`.

History:
- 2026-09-28 Confirmed: from the M3 review (harness contents read).
- 2026-09-28 M3 implementation: `YlosOnce` holds for 2 and 3 workers in both nursery modes, and the
  `ylos_unlocked` mutant fails it, so the protocol is right at model level. The C++ side is still
  untested under TSan: the gap stays open until `minor_harness` gets its YLOS kind (M3's trace
  validation needs it too).
- 2026-09-29 The harness half is done (M3 wave 2): `test/gc-helper-tsan/minor_harness.cpp` now has a
  YLOS object kind in both nursery modes. `gc-minor-tsan 2` (30 runs: 2 heaps × 1/2/4/8/16 workers
  × 2 LAB sizes, plus the jitter-50 subset; 20–60 YLOS objects per heap, several parents each)
  printed `minor_harness PASS` with **0 ThreadSanitizer reports**. Still open: a pointer-bearing
  large object in `test/gc-heap-tsan/heap_driver.cpp` (the heap-level half, which would also reach
  CR-019's sweep read), and the default 200-heap run.
- 2026-09-29 Heap half closed (wave 3b): `gc-heap-tsan ylos` adds, every second step, a pointer-bearing
  Array of 8.1–48 KiB (legacy: up to 12 KiB in the nursery, the rest YLOS in mixed bag pages and
  large blocks; region: all YLOS) whose elements point at young Ints, old Tuple2s and the previous
  Array, with 8 young parents each rooted separately so a parallel minor deals them to different
  workers (a first version rooted them under one tree and never reached a YLOS from two threads).
  gdb `dprintf`: in legacy scenario 3 all 746 minors with a YLOS reach had reaches on 2–4 threads;
  in region scenario 5 all 450. One full run (9 scenarios, 450 families each, 427 s): PASS, 0 TSan
  warnings.

### CR-021 — plain reads of `region_end_` and page-index owner words while markers hold `atomic_ref`s

| | |
|---|---|
| Status | Fixed (2026-09-29) |
| Severity | S2 (the letter of the standard; read/read, benign on every target) |
| Found | 2026-09-28, adversarial review of the W plan |
| Where | plain reads of `region_end_` at `OldGenSpace.cpp:875` (`ensureBagPageAvailable`), `:2768` (`allocateLargeBlock`), `OldGenSpace.hpp:351` (`getCommittedBytes`); plain reads of owner words in `assignPageIndexForBlock`, `OldGenSpace.cpp:599-609`; markers read both through `atomic_ref` (`regionEnd()`, `OldGenSpace.hpp:409`; `loadOwner`, `:449`) (post-7c tree) |
| Models | W4 |
| Invariants | HEAP_049 |
| Repro | n/a (no C11 tool reports it: it is not a data race) |
| Guard | `tla-canary`, but only partly (checked 2026-09-30; see History). Reverting the whole fix fails it through footprint grep H3 (`[.]primary\|[.]secondary`, every owner-word access), H5 (which happens to match a restored `region_base_ ==` test) and the region pins. A plain read restored alone, on a line without `==` and outside every pinned region, passes: for example `getCommittedBytes` or `resizePageIndexForRegion`. The census does not help, because these lines have no atomic keyword. No C11 tool can report a read/read |
| Fix | every plain read of `region_base_`/`region_end_` goes through `regionBase()`/`regionEnd()` (`OldGenSpace.cpp` `ensureBagPageAvailable`, `allocateFromBagPage`, `populateFromBlock`, `allocateLargeBlock`, `adjustCapacityAfterMajorGC`, `releaseBlockToAllocator`, `releaseUnassignedBlockToAllocator`, `allocateForEvacuation`; `OldGenSpace.hpp` `getCommittedBytes`, `resizePageIndexForRegion`; `Allocator.cpp` `ensureOldGenCapacityFor`); owner-word reads use `loadOwnerRelaxed` (`OldGenSpace.hpp:458`, tree of 2026-09-30) in `assignPageIndexForBlock`, `clearPageIndexForBlock` and the V2 validator |

C++20 [atomics.ref.generic]/3: while any `atomic_ref` to an object exists, every access to it must
go through an `atomic_ref`. The single writer reads these words plainly while a background marker
may be inside a `regionEnd()` or `loadOwner()` load. **Fix:** route the writer's reads through
`regionEnd()` / `loadOwner()` (relaxed), which costs nothing.

History:
- 2026-09-28 Confirmed: from the W review; the orchestrator checked the plain reads at `:875`,
  `:2768` and `getCommittedBytes`.
- 2026-09-28 GenMC W4, as predicted: a plain read against an `atomic_ref` read is read/read, so no
  C11 checker reports it. It stays a letter-of-the-standard fix.
- 2026-09-29 Fixed (wave 3a), `region_base_` reads included (the same hazard). The disassembly of
  every changed function was compared before and after: no locked instruction or fence was added;
  at most a couple of reload `mov`s differ. Unit tests and GenMC (60/60) pass.
- 2026-09-30 Guard checked by reverting fix sites in a copy of the tree to be merged
  (`/tmp/cr-register/`), one site per run:
  - `tla-canary` fails for `ensureBagPageAvailable` (its region pin and H5), `clearPageIndexForBlock`
    (H3), `adjustCapacityAfterMajorGC` and `Allocator::ensureOldGenCapacityFor` (both through H5,
    only because each restored line has a `region_base_ ==` test).
  - It passes for `getCommittedBytes` and `resizePageIndexForRegion` (`OldGenSpace.hpp`: no pinned
    region, no `==`).
  - By the same reading, a restored `> region_end_` test or the capacity line would also pass on its
    own in `populateFromBlock`, `allocateForEvacuation`, `adjustCapacityAfterMajorGC` and
    `Allocator::ensureOldGenCapacityFor`.
  The Guard field above used to claim the census and grep pins covered this. It now says what does.
  Status stays Fixed: no plain read of `region_base_`/`region_end_` is left outside the accessors,
  the setters and the constructor.
  A canary grep row `region_(base|end)_` over `runtime/src/allocator/*.{cpp,hpp}` would guard every
  site. It would pin 7 lines today: the two member declarations, the constructor's initialiser,
  and the two accessors and two setters.

### CR-022 — comments justify promotion chunks as "whole bitmap bytes"; the scans need whole words

| | |
|---|---|
| Status | Fixed (2026-09-29) |
| Severity | D (the code is correct) |
| Found | 2026-09-28, adversarial reviews of the M4 and W plans |
| Where | `OldGenSpace.hpp:630-631`, `:639-640`, `:689`; `OldGenTenure.cpp:202`; the 07 plan §10.18 item 1. The scans read 64-bit words: `bitscan::loadWord`, `BitmapScan.hpp:25-29` (`nextFreeCell`, `nextSetBit`) |
| Models | M4 (mutant `chunk_unit_subword`), W3 (`W3_BYTE_CHUNK`) |
| Invariants | HEAP_054, HEAP_067 |
| Repro | n/a |
| Guard | M4 `chunk_unit_subword`; GenMC `W3_BYTE_CHUNK` (8-cell chunks race through the scans' word read) |
| Fix | the comments at `OldGenSpace.hpp:640, 651, 704`, `OldGenTenure.cpp:207` (tree of 2026-09-30), the 07 plan §10.18 item 1 and its T5 row, and HEAP_054 now say whole 64-bit words |

Chunks are 64 cells, so each owns whole 64-bit bitmap words, which is what `nextFreeCell` and
`nextSetBit` need: they read a word with a plain load. The comments say chunks own "whole bitmap
bytes", a weaker property that would permit a data race if someone shrank the chunk to 8 cells on
the strength of the comment. **Fix:** correct the comments.

History:
- 2026-09-28 Confirmed: reported by the M4 and W reviews.
- 2026-09-28 Second guard: GenMC `W3_BYTE_CHUNK` is flagged (8-cell chunks race through
  `bitscan::loadWord`), `test/genmc/AUDIT.md`.
- 2026-09-29 M4's `chunk_unit_subword` mutant fails `NoRaceBitmap` as intended (the guard works).
- 2026-09-29 Fixed (wave 3a): the comments and HEAP_054 now name the word, which the scans need.

### CR-023 — a foreign `stopAndJoin` can wait out a whole relaunched episode

| | |
|---|---|
| Status | Reproduced (2026-09-29): TLC (M6) and **in code** (fork harness `relaunch`: 43 stalls in 11,653 forks; three recorded traces accepted by M6's trace spec); Guarded |
| Severity | S3 (a stall; nothing is lost). Precondition: a stop from a thread other than the owner (a non-mutator fork's prepare, or exit) |
| Found | 2026-09-28, adversarial review of the M6 plan; checked by the orchestrator |
| Where | `GCBackgroundGang::stopAndJoin` → `joinLocked`, `GCHelperPool.cpp:638-643`, `:622-626` (`cv_done_.wait` releases `m_` until `finished_ >= members`); `GCBackgroundGang::launch`, `:600-613` (`finished_ = 0`, a new `stop_`) (post-7c tree) |
| Models | M6 (the interleaving is in the model; a bounded-wait property would expose it) |
| Invariants | HEAP_065 |
| Repro | `test/tla/run_models.py --model M6 --config gangs_host_fork_stall` (`violates:StopWaitsOwnEpisode`, 24 states) |
| Guard | M6 `gangs_host_fork_stall` (expected-fail); the fork harness arm `relaunch` |
| Fix | — |

A foreign thread's `stopAndJoin` sets the running episode's stop flag and then waits in
`joinLocked`, releasing `m_`. The members stop and finish, but the owner's own `join` (its reap) can
win `m_` first, clear `running_`, and relaunch. `launch` resets `finished_ = 0` and installs a fresh,
unstopped control. The foreign waiter wakes, re-checks `finished_ >= members`, finds it false, and
waits for the relaunched episode to finish on its own: a fork prepare (or exit) can stall for a
whole episode. **Fix candidates:** wait on a generation (`generation_` at entry) rather than on
`finished_`, or refuse relaunch while a foreign stop is pending (the same fork-pending flag
CR-003/004 would need).

History:
- 2026-09-28 Confirmed (shape): from the M6 review; the orchestrator read `joinLocked`,
  `stopAndJoin` and `launch`.
- 2026-09-29 Reproduced (model), M6: the owner reaps and relaunches generation 2 while the host's
  prepare still waits in `joinLocked`. `ParentProgress` holds everywhere, so it is a stall, not a
  hang.
- 2026-09-29 **Reproduced in code** (M6 wave 2): fork harness arm `relaunch`, 43 stalls in 11,653 forks
  (0.37%); three recorded host-fork logs are real instances (the stop was for generation 2, the
  join returned for generation 3), and M6's trace spec accepts them, as the model allows. New: the
  stall becomes a **deadlock** when combined with any episode that waits on the mutator (the test
  hold did this and hung one trace run). Severity stays S3 for production (no production episode
  waits on the mutator); note it for any future design where one does.

### CR-024 — `GCHelperPool.hpp` says the background gang's `atexit` handler is registered at the first launch

| | |
|---|---|
| Status | Fixed (2026-09-29) |
| Severity | D |
| Found | 2026-09-28, adversarial review of the M6 plan |
| Where | the comment at `GCHelperPool.hpp:235-236` vs the registration in the constructor `GCBackgroundGang::GCBackgroundGang`, `GCHelperPool.cpp:505-512` |
| Models | M6 (its exit configuration models the code: registration at construction) |
| Invariants | — |
| Repro | n/a |
| Guard | the canary's whole-file pin on `GCHelperPool.hpp` (M6, M7, `w_pool_done`, `w_running_chain`): any edit to the file, this comment included, fails `tla-canary` until those models are re-audited |
| Fix | the comment at `GCHelperPool.hpp:249-253` |

The header says `stopAllAtExit` is registered "at the first launch"; the code registers it (and the
atfork handlers) once, in the first gang's constructor. The difference decides whether a gang that
was built but never launched is stopped at exit; M6 models the code. **Fix:** correct the comment.

History:
- 2026-09-28 Confirmed: from the M6 review; the orchestrator read both places.
- 2026-09-29 Fixed (wave 3a): the comment now says the constructor registers the handlers.

### CR-025 — helper-job stalls on gang threads are counted as "outside the pause"

| | |
|---|---|
| Status | Fixed (2026-09-29) |
| Severity | D (a statistic reports something false; no effect on the heap or on decisions) |
| Found | 2026-09-28, protocol mapping; split from CR-007 by the M7 implementation |
| Where | `Allocator::callerInPause()`, `Allocator.cpp:1206-1208` (`tl_heap_ != nullptr && tl_heap_->inPause()`); its result feeds `GCHelperPool::noteStall` (`GCHelperPool.cpp:230-234`, `stall_outside_pause` / `stall_outside_pause_ns`) and `pageHookStall` (`Allocator.cpp:1170-1182`, which adds the stall to the calling heap's `tg` stats only when it finds one) (tree of 2026-09-28) |
| Models | M7 (the stall itself is CR-007) |
| Invariants | HEAP_058 |
| Repro | n/a (a statistic) |
| Guard | `testCR025GangMemberStallInPause` (`build/test/test --filter CR-025`) |
| Fix | `GCMarkGang::onMemberRun()` (a `thread_local` set by `memberLoop` around the job, `GCHelperPool.hpp:199-206`, `GCHelperPool.cpp:445-447`); `Allocator::callerInPause()` also returns true when it is set (`Allocator.cpp:1221-1227`, tree of 2026-09-30) |

`tl_heap_` is thread-local and null on `GCMarkGang` threads. When a parallel-minor or pause
tenure-engine member waits on a helper job under `promo_mu_` (CR-007's routes), `callerInPause()`
returns false although the whole wait is inside a minor-GC pause. The stall is then counted in
`stall_outside_pause`, and `pageHookStall` finds no heap, so the pause's own stall timer misses it.
Any measurement of CR-007 through these counters under-reports pause stalls. **Fix:** pass the
pause state explicitly from the promotion path (the heap is known there), or resolve the owning
heap from the gang's context rather than from `tl_heap_`. **Next step:** fix before CR-007 is
measured.

History:
- 2026-09-28 Confirmed: noted in CR-007 by the mapping agent; split off by the M7 implementation;
  the orchestrator read `callerInPause`, `noteStall` and `pageHookStall`.
- 2026-09-29 Fixed: the pause state is resolved from the gang (a gang member runs only inside a
  pause) rather than threaded through the promotion path; `in_pause` feeds only stall accounting,
  never a decision. The test passes; reverting only `callerInPause` fails it, and reverting the
  whole fix fails it earlier. Remaining note (not this entry): the concurrent tenure collector's own
  helper-job waits are still counted in `stall_outside_pause`, although they never stall the
  mutator.

### CR-026 — HEAP_058 and `GCHelperPool.hpp` describe the helper handshake more narrowly than the code

| | |
|---|---|
| Status | Fixed (2026-09-29) |
| Severity | D |
| Found | 2026-09-28, M7 adversarial review (waits off the mutator); M7 implementation (publication outside the mutex) |
| Where | `design_docs/invariants.csv` HEAP_058; the comment at `GCHelperPool.hpp:12-16`; vs `GCHelperPool::wait`'s fast path (`GCHelperPool.cpp:236-238`, `state.load(acquire)` before taking `m_`), `HelperJob::isDone`/`isIdle` (`GCHelperPool.hpp:56-57`), and the gang-thread waits of CR-007 (tree of 2026-09-28) |
| Models | M7 (models the code), M6 (`PoolJob`), W (`w_pool_done`, proposed) |
| Invariants | HEAP_058 |
| Repro | n/a |
| Guard | GenMC `w_pool_done` (passes on the code; its four mutants, which weaken the `Done` store or the fast-path loads to relaxed, race on the job's payload) |
| Fix | HEAP_058 and the `GCHelperPool.hpp:11-24` (tree of 2026-09-30) comment now say waits also happen on gang threads under `promo_mu_`, and that the fast path publishes `Done` by release/acquire outside `m_`, citing `w_pool_done` |

Two claims no longer match the code:
- HEAP_058 says jobs are "posted and collected only at mutator slow paths". Waits also happen on
  gang threads under `promo_mu_` (CR-007's routes: the parallel minor's virgin-block path, the
  CR-014 tail, the pause tenure engine).
- HEAP_058 and the header comment say "publication is the GCHelperPool mutex's release/acquire".
  `wait`'s fast path and `isDone` read `state` with an acquire load outside `m_`. Publication there
  rests on the worker's release store of `Done` (made inside `m_`) pairing with that acquire load,
  which is W's proposed `w_pool_done` pattern, not the mutex.

Both are correct code under a wider argument than the documents give. The models (M6 `PoolJob`, M7)
use the code's behaviour. **Fix:** amend HEAP_058 and the header comment; land `w_pool_done` as the
guard of the fast path's ordering.

History:
- 2026-09-28 Confirmed: the first point from the M7 review (recorded in CR-007), the second from
  the M7 implementation; the orchestrator read `wait`, `isDone` and the comment.
- 2026-09-28 Guard: `test/genmc/w_pool_done.cpp` checks the fast path's release/acquire under RC11
  and passes; `POOL_RELAXED_DONE`, `POOL_RELAXED_DONE_REAP`, `POOL_RELAXED_FASTPATH` and
  `POOL_RELAXED_ISDONE` are flagged. `w_pool_done_relaxed_cas` also shows that `post`'s CAS order
  is not what publishes a job to the worker (the pool mutex does). Only the text fix is left.
- 2026-09-29 Fixed (wave 3a).

### CR-027 — the 06 shared-state table and an `OldGenSpace.cpp` comment misdescribe `gc_phase_` and `live_bytes`

| | |
|---|---|
| Status | Fixed (2026-09-29) |
| Severity | D |
| Found | 2026-09-29, M4 implementation |
| Where | `plans/threaded-gc-06-parallel-minor.md` P§3.11 (rows M5, M6; no `live_bytes` row); the comment at `OldGenSpace.cpp:1871-1875` vs `beginMarkCycle`'s `gc_phase_ = GCPhase::Marking` (`:4156`); the M4 plan's A3 row (tree of 2026-09-29) |
| Models | M4 (models the code) |
| Invariants | HEAP_054, HEAP_067 |
| Repro | n/a |
| Guard | M4's `NoRaceLive` and `NoRacePhase` (they check the accesses the table omits) |
| Fix | the 06 plan P§3.11 (row M5 at word granularity, row M6's `gc_phase_` rule as it is, new row M16 for `live_bytes`) and the `OldGenSpace.cpp` comment in `allocate` (now at `:2011-2020`, tree of 2026-09-30) |

The audit tables are the premises every footprint argument starts from (parent plan rule A3), and
four statements in and around them are wrong:
- **No row for `live_bytes`.** Promotion workers add to it atomically outside `promo_mu_`, and the
  sweep and shrink read it plainly under the lock (CR-014's race).
- **Row M6 lists `gc_phase_` with the rule "`promo_mu_`".** CR-001's readers break that rule:
  `finalizeBitmapCellW` reads it without the lock. (The M4 plan's A3 row says `gc_phase_` is
  missing from the table; it is there, under the wrong rule.)
- **Row M5, "distinct blocks never share a bitmap byte",** predates chunked cursors: several workers'
  chunks share one block, and the relevant unit is the 64-bit word (CR-022).
- **The comment at `OldGenSpace.cpp:1871-1875`** says `gc_phase_` is assigned at four sites and
  "never Marking"; `beginMarkCycle` sets it to Marking (`:4156`).

**Fix:** amend the 06 table (a `live_bytes` row; M6's `gc_phase_` rule as it really is; M5 at word
granularity) and the comment. The canary's footprint greps should gain `live_bytes` and
`gc_phase_ =` rows so a new access fires.

History:
- 2026-09-29 Confirmed: from the M4 implementation; the orchestrator read the comment and `:4156`.
- 2026-09-29 Fixed (wave 3a). The canary's footprint greps gain `P6.M16` (`live_bytes`) and a `gc_phase_ =` row.

### CR-028 — the validate-only V11 header walk in `lazySweep` races with workers writing popped cells

| | |
|---|---|
| Status | Reproduced (TSan, 2026-09-29); Guarded (the `promo` scenario, expected-fail) |
| Severity | S2 in validate builds only (`ECO_HEAP_VALIDATE`); it can also abort spuriously |
| Found | 2026-09-29, M4 wave 2 (TSan scenario `promo`) |
| Where | the V11 check inside `OldGenSpace::lazySweep` (validate builds), run under `promo_mu_` from the promotion ladder, against other promotion workers' writes into cells popped from the same block (tree of 2026-09-29) |
| Models | M4 (the model has no validator steps) |
| Invariants | HEAP_054 (V11), HEAP_067 |
| Repro | `build-heap-tsan/gc-heap-tsan promo …` (`test/gc-heap-tsan/promo_sweep.cpp`): TSan flags it in 11 of 17 runs; one run aborted in V11 |
| Guard | the same scenario (expected-fail) |
| Fix | — |

The validator re-reads object headers while it sweeps a block. Inside a parallel minor, other
workers are writing headers and bodies into cells they popped from that block's free runs, so the
validator reads memory another thread is writing, without ordering. The sweep itself reads only
mark bits for live objects (CR-002 is its race); V11 adds header reads on top. **Fix:** skip V11
while `par_promo_active_`, or run it only on blocks no worker can pop from. **Why it matters:**
validate builds are the gate for heap soundness (master plan §2), and a racy validator produces
false aborts and TSan noise that hide real reports.

History:
- 2026-09-29 Reproduced: M4 wave 2's TSan scenario (`test/tla/M4-promotion-bitmap/AUDIT.md`).

### CR-029 — the promotion ladder's bag rung sends size-classed requests to `allocateFromBagPage`, whose assert forbids them

| | |
|---|---|
| Status | Fixed (2026-09-29): option (a), the assert and comment; options (b) and (c) stay proposals |
| Severity | D (a false premise in an assert and its comment) + an abort in assert builds (the everyday `build` preset). Release builds: benign (no S1, no S2; analysed 2026-09-29) |
| Found | 2026-09-29, M4 wave 2 |
| Where | `OldGenSpace::ladderFrom2W`, `OldGenSpace.cpp:1395` (`allocateFromBagPage(requested_size)` after `sweepOnDemandAllocate` and `virgin()` fail); `OldGenSpace::allocateFromBagPage`, `:2458-2461` (`assert(request_cls >= num_size_classes_ && "...caller must route size-classed requests through allocateFromSizeClass")`, with the comment "Branch (C) is the only caller"); other size-classed callers at `:971` and `:2307` (tree of 2026-09-29) |
| Models | M4 (the model cannot show this path: it has no bag rung) |
| Invariants | HEAP_051 |
| Repro | `build-heap-tsan/gc-heap-tsan promo …` (`test/gc-heap-tsan/promo_sweep.cpp`) |
| Guard | `CR-029: … (bitmap ladder, rung 7)` and `(legacy ladder, step 6)` in `test/allocator/ConcurrencyRegisterTest.cpp` (`build/test/test --filter "CR-029"`): pass on the new code, abort on the old (4/4) |
| Fix | `OldGenSpace::allocateFromBagPage` (`OldGenSpace.cpp:2545-2572`, tree of 2026-09-30): the assert is now `requested_size < alloc_buffer_size && (requested_size & 7) == 0`, and the comment lists all five callers and the exact-size carve argument. A test-access wrapper of `ensureOldGenCapacityFor` was added at `Allocator.hpp:605` so a test can exhaust the reservation |

The ladder's last rungs are: sweep on demand, a virgin block, the bag page, then the panic sweep.
The likely path: a worker publishes a fresh virgin block, and the other workers' chunk claims empty
it before its publisher claims from it, so `virgin()` returns nothing and the worker falls through
to the bag rung with a size-classed request. The comment and the assert say that cannot happen;
three call sites say otherwise. **Next step:** decide what the bag rung should do for a
size-classed request (route it through the size-class path, or make `allocateFromBagPage` handle
it and fix the assert and comment), and analyse the release-build behaviour now. Add the bag rung
to M4 if the fix keeps it.

History:
- 2026-09-29 Reproduced: M4 wave 2; the orchestrator read the three call sites, the assert and its
  comment.
- 2026-09-29 Analysed (wave 3c, code reading; `/tmp/wave3c/`). **Release builds are benign**: a
  size-classed request runs the same code as a request in the (LOT, `alloc_buffer_size`) band with
  a smaller carve. Step 1 splits only from the mixed-only lists (`start_cls = max(request_cls,
  num_size_classes_)`); step 2 is a budgeted `lazySweep` under `promo_mu_` (no race beyond
  CR-001/002); step 3 materialises a fresh mixed block and carves the object at offset 0, and the
  mixed walk and mark attribution use the object's own size (`walkStepFor`), so the block stays
  consistent; mid-cycle the object is black and counted in `live_bytes`; PM6/IM4 account it. The
  only cost is a missed opportunity (a fresh page used as a mixed block; an exact fit on the list
  can be passed over). **Reachability is wider than recorded:** serially too, through the bitmap
  mutator ladder's rung 7 (`OldGenSpace.cpp` ~:987) and legacy `allocateFromSizeClass` step 6
  (~:2327), whenever the bag is empty and `acquireOldGenBlock` fails (old-gen reservation
  exhausted): in assert builds heap exhaustion aborts here instead of reaching the panic sweep.
  In parallel promotion the extra route is `startVirginBlockShared` publishing chunk 0 to
  everyone, other workers' lock-free `claimChunkW` draining the few units, then the publisher's
  `virgin()` failing; reachable at the default 512 KiB blocks too (8 KiB class: 1 unit).
  **Fix:** (a) replace the assert and the "Branch (C) is the only caller" comment with
  `assert(requested_size < alloc_buffer_size && (requested_size & 7) == 0)` and a comment that
  lists the callers; (b) optionally retry the exact pop in step 2; (c) recommended for the
  parallel path: `startVirginBlockShared` reserves the publisher's first chunk in the publish
  step, so `virgin()` cannot fail after a publish. Model the bag rung in M4 once fixed.
- 2026-09-29 Fixed (a) (wave 3d). The guard drives the serial route (reservation exhausted, bag
  drained, tiny sweep budgets, a dead 16 KiB object three sweep slices ahead) and checks the
  6000-byte result: placed at the dead cell in the mixed block, black and marked, `live_bytes` and
  `allocated_bytes` +6000 exactly, no higher rung used, the block parses by object size, and the
  next major attributes exactly 3 × 16 KiB + 6000. On the old code it aborts at the assert (4/4).
  Still open: (b) retry the exact pop in step 2; (c) reserve the publisher's first chunk in
  `startVirginBlockShared`; model the bag rung in M4; re-run the TSan `promo` scenario to confirm
  the parallel route no longer aborts.
- 2026-09-29 M8 confirms the premise the fix relies on: the size-classed carve at the bag rung is
  reachable serially (9 states: the reservation exhausted, rung 4 refuses a 1-granule remainder,
  rung 7 step 1 carves the exact request) and keeps every M8 invariant (107k states). Its cell is
  uncounted at Idle like any mixed carve (CR-018).

### CR-030 — three 05b/05c unit tests fail intermittently (two of them negative controls)

| | |
|---|---|
| Status | Fixed (2026-09-29): the tests are deterministic; the runtime was not at fault (Not-a-bug) |
| Severity | G (a negative control that sometimes misses is a guard that sometimes does not guard); possibly a real defect behind it |
| Found | 2026-09-29, wave 3a's full unit run (one test per process), on a loaded machine |
| Where | tests 185 "threaded-gc-05b: negative control — skipping marker 1's accumulator is caught", 208 "threaded-gc-05c: the t0 greys are distributed over the background deques" and 210 "threaded-gc-05c: negative control — skipping a background merge is caught" in `build/test/test` (tree of 2026-09-29) |
| Models | M2 (distribution and merges), M1 |
| Invariants | IM10, IM14, HEAP_064, HEAP_065 |
| Repro | run each test several times under load: 185 failed 1 in 3 (before and after wave 3a's changes), 208 1 in 3 (before only), 210 once in the full run, then 3 of 3 passes. Seeds in `/tmp/wave3/unit_before.log` |
| Guard | the tests themselves; each negative control fails 8/8 with its fault removed |
| Fix | test changes only: 185 (`ParallelMarkTest.cpp:624`: finish any build-started cycle before the hook, up to 32 forced cycles, exit 2 if marker 1 never lost bytes), 208 (`ConcurrentMarkTest.cpp:809`: drain before setting the hold, assert the hold survives `startCycle`), 210 (`:850`: one background member, drain first); a `holdNextCycle` helper (`:125`) applied to four more 05c tests that lost the hold 1/32 to 32/32 times |

- 185 and 210 fail at `Assertion failed: WIFEXITED(st) && WEXITSTATUS(st) == 0`: the forked child
  that applies the fault and expects the validator to catch it did not exit cleanly.
- 208 fails at `OA::slotDequeSize(og(a), i) > 0`: some background slot got no t0 grey.

Likely schedule dependence in the tests (which marker gets work, how the t0 greys are split),
which the load of this session made visible. But a negative control whose child dies another way
could also be hiding a different failure. **Next step:** reproduce each under a fixed seed and
`taskset`/jitter; read what the child printed; decide whether the test or the code is wrong.

History:
- 2026-09-29 Suspected: from wave 3a's unit runs; not investigated.
- 2026-09-29 Reproduced and explained (wave 3c; gdb and strace logs in `/tmp/wave3c/`):
  - 185 (`ParallelMarkTest.cpp:624`, 5/30 and 8/30 failures): in every failure marker 1 marked
    nothing in the forced cycle (e.g. `m0=25480 m1=0 m2=0 m3=20922`), so skipping its accumulator
    loses nothing and the child returns 1. Vacuous negative control.
  - 208 (`ConcurrentMarkTest.cpp:796`, 4/30): the build-started cycle's `closingFinish` clears
    `test_bg_hold_` (`OldGenSpace.cpp` ~:4758), so the next launch sees no hold and the unheld
    members drain a deque before the test reads it. The same latent pattern (a hold set without
    draining first) is in six more 05c tests.
  - 210 (`ConcurrentMarkTest.cpp:836`, 2/30): the skipped background member marked nothing
    (`slot2=0 slot3=30193`). Vacuous negative control.
  Test fixes are precise (drain to the handoff before setting the hook; loop until the skipped
  marker has work, or use one background member); the runtime is not at fault.
- 2026-09-29 Fixed (wave 3d): failures under load went from 14/32, 11/32 and 5/32 to 0/96 each; the
  four other held tests went to 0/32. Negative controls with the fault removed: 185 fails 8/8
  (exit 2, "marker 1 marked nothing in 32 forced cycles"), 210 fails 8/8, 208 without the drain
  fails 57/64 at the new hold assert. Full unit portion: 619 tests, 0 failures.
- 2026-09-29 The rewrite of test 185 (wave 3d) broke its **validate-build** branch, which still
  demanded an abort (`WIFSIGNALED`): after draining the build-started cycle first, marker 1's lost
  bytes sit in mixed blocks, which IM6 (`validateCycleUniformLive`, uniform blocks only) does not
  check, so the child's own post-sweep comparison catches the loss and exits 0 (3/3 in a validate
  tree). Fixed: the validate branch accepts either catcher (the IM6 abort or exit 0) and still fails
  on exit 1 or 2; 5/5 in a validate build. This is also the second failure lss-payoff saw with
  `k = 3.0` in the validate build: it is this test, not a GC defect.

### CR-031 — a host-forked child's `exit()` tears down the dead mutator's heap

| | |
|---|---|
| Status | Reproduced (2026-09-29, fork harness); Guarded (the `host-exit` arm, expected-fail) |
| Severity | S4 (precondition: a fork from a thread other than the heap's mutator, and a child that calls `exit()`) |
| Found | 2026-09-29, M6 wave 2 (the fork harness) |
| Where | the child's static destruction: `Allocator::~Allocator` → `ThreadLocalHeap::~ThreadLocalHeap` of a heap whose mutator thread does not exist in the child; the `RootSet` hash set was copied by `fork()` while the parent's mutator was updating it (tree of 2026-09-29) |
| Models | M6 (the fork contract; a child's teardown of heaps it does not own is outside the model) |
| Invariants | HEAP_007 |
| Repro | `gc-fork-harness host-exit …` (`test/gc-heap-tsan/fork_harness.cpp`): of 1,372 host-fork children that call `exit()`, 4 crashed in `~ThreadLocalHeap` on the `RootSet` hash set and 1 aborted in malloc (0.7% in all; the harness updates roots on every allocation, which overstates the rate) |
| Guard | the same arm (expected-fail) |
| Fix | — |

The child inherits every heap, but only the forking thread. A heap whose mutator was another thread
may have been mid-update of its non-thread-safe tables (the `RootSet` hash set, malloc's state) at
the instant of the fork, and `exit()` then runs its destructors over that torn state. Fixing CR-003
and CR-015 alone does not help. The fork contract with its guard (CR-003's resolution: the child
handlers record which heaps the forking thread owns, and the child skips teardown of the others)
does.

History:
- 2026-09-29 Reproduced: M6 wave 2 (`test/tla/M6-lifecycle/AUDIT.md`).

### CR-032 — the validate-only P1 census has a mutex and tables with no atfork handler

| | |
|---|---|
| Status | Reproduced (2026-09-29, fork harness, validate builds); Guarded (the `host` arm with the census on, expected-fail) |
| Severity | S4, validate builds only (`ECO_HEAP_VALIDATE`), with a host fork |
| Found | 2026-09-29, M6 wave 2 |
| Where | `runtime/src/allocator/P1Census.cpp` (`p1::recordPromoted`, `p1::forget`, the census mutex and tables) (tree of 2026-09-29) |
| Models | M6 |
| Invariants | HEAP_SNAPSHOT_001 (the census checks P1) |
| Repro | `FORK_HARNESS_CENSUS=1 gc-fork-harness host …`: host children blocked in `p1::recordPromoted` or crashed in `p1::forget` (the harness turns the census off by default) |
| Guard | the same arm with the census on (expected-fail) |
| Fix | — |

Like `thread_mutex_` (CR-015), the census mutex is not reset in the child, and its tables can be
torn. It only matters for validate builds that fork from a non-mutator thread; the fork contract's
guard covers it, or the census can register its own atfork handlers.

History:
- 2026-09-29 Reproduced: M6 wave 2.

### CR-033 — `allocateFromBagPage`'s fresh-page carve leaves a tail under `MIN_FREE_CELL_SIZE` without a header

| | |
|---|---|
| Status | Reproduced (model, TLC, 2026-09-29); Guarded at model level by M8 `MC_quick_cr033` |
| Severity | S1 in legacy old-gen allocation (`old_gen_bitmap_alloc` off, by code reading); benign in bitmap mode, the default. **Serial** |
| Found | 2026-09-29, wave 3d (while adding CR-029's guard) |
| Where | `OldGenSpace::allocateFromBagPage`, the fresh-page step (`OldGenSpace.cpp` ~:2610-2617): `if (remainder >= MIN_FREE_CELL_SIZE) pushSpanOnFreeLists(...)` — a remainder in (0, `MIN_FREE_CELL_SIZE`) gets no header at all; compare `pushSpanOnFreeLists`, whose comment says trailing bytes under `MIN_FREE_CELL_SIZE` get a non-linked `Tag_Free` header "so block-walking sweep can still parse them" (tree of 2026-09-29) |
| Models | none (serial) |
| Invariants | HEAP_051 (mixed blocks parse by object size), HEAP_054 |
| Repro | `test/tla/run_models.py --model M8 --config MC_quick_cr033` (`violates:BlockParseable`, one step) |
| Guard | M8 `MC_quick_cr033` (expected-fail); the fix candidate passes as a control |
| Fix | — (candidate: push any nonzero remainder through `pushSpanOnFreeLists`, which already writes a header for a small tail, as the split path at `:2394` avoids small remainders altogether) |

A request of exactly `alloc_span - 8` (8-aligned, below `alloc_buffer_size`) carves the object at
the page's start and leaves an 8-byte tail whose bytes were never given a header. The next block
walk (the lazy sweep, the mixed walk, V-validators) reads whatever the page held there as a header.
Whether an 8-byte tail can occur depends on `alloc_span` and the size routing; that is the first
thing the reproducing test must establish.

History:
- 2026-09-29 Suspected: noted by the wave 3d agent; the orchestrator read the fresh-page step and
  `pushSpanOnFreeLists`'s comment.
- 2026-09-29 **Reproduced (model)**, M8 (`test/tla/M8-block-lifecycle/`), and reachable at every
  geometry: a request of exactly `alloc_buffer_size − 8` (524,280 B at the default) takes Path 4;
  steps 1–2 cannot split (its class is `NUM_SIZE_CLASSES`), and step 3 leaves an 8-byte tail with no
  header. Who reads it decides the severity: in bitmap mode (the default) nothing does (the gap sweep
  covers it and the validate walk reads set bits only), so it is benign; in legacy mode the header
  sweep (`OldGenSpace.cpp` ~:5710) reads the zero word as a 16-byte `Tag_Int`, overshoots by 8, and
  the flushed free run then overwrites the next page's first word: S1 (by code reading, not
  modelled). The fix candidate (push any nonzero remainder through `pushSpanOnFreeLists`) passes.

### CR-034 — region mode: a YLOS address reused after a STW major is taken for a hand-over member (ABA)

| | |
|---|---|
| Status | Reproduced (2026-09-29): in code (a scratch validate build at k = 3.0, 5/5) and in the model (M5, three ways); Guarded at model level by M5's expected-fail rows |
| Severity | S1: a live old object's slots dangle into a recycled nursery extent (HEAP_005, HEAP_062). Region mode, the default |
| Found | 2026-09-29, while checking whether lss-payoff's reverted `k = 3.0` failure was CR-017 (it is not) |
| Where | `NurserySpace::minorGCRegion`'s hand-over prep, `NurseryRegion.cpp:751-753` (`for (void* y : Hx.ylos_gen)`, `if (oldgen.youngLargeMeta(y) == nullptr) continue; // retired by a major in between (dead)`), the same pattern for the ageing extents at `:773`; `region::Extent::ylos_gen` (`NurseryRegions.hpp:79`); a STW major erases the YLOS's index entry but not its `ylos_gen` entry (`OldGenSpace::releaseBlockToAllocator`, reached from `reclaimAllDeadBlocksFromMeta`); `reachYoungLargeR` (`NurseryRegion.cpp` ~:511-518); the merge's in-place promotion (`mergeJob`, `NurseryTenure.cpp` ~:756-769) (tree of 2026-09-29) |
| Models | M5 (constant `YlosGen = "code"` models `ylos_gen` by address; invariant `YlosGenIdentity`), M3 |
| Invariants | HEAP_005, HEAP_062, HEAP_070; seen as HEAP_044 |
| Repro | scratch tree `/tmp/k3/` (not in the repo): `MAJOR_GC_LIVE_BUDGET = 3.0`, `-DECO_HEAP_VALIDATE=ON`, `test --filter "E2 in a unit test"` → `OldGenSpace::scanObject` HEAP_044 assert ("live 0-field Tag_Custom") in the third explicit STW major, seed 42, tenure mode 1 (mode 2 hits the same ABA). At 4.5 it passes (3/3): k only changes block placement, which makes the address reuse happen |
| Guard | M5 `MC_ylos_aba` (`violates:YlosGenIdentity`), `MC_ylos_aba_heap005` (`violates:OldPointsOld`), `MC_k2_ylos_aba` (`violates:NoDangling`); each flips with a fix |
| Fix | — |

The chain, from instrumented runs (every step logged with a sequence number):
1. The mutator allocates YLOS A (an Array) at address X; minor m−1 reaches it, and X joins the
   fill extent's `ylos_gen`.
2. A STW major finds A dead; its block is all-dead and released; the large-body index entry is
   erased, but X stays in that extent's `ylos_gen`.
3. During the lazy sweep the block is re-created at the same start, and the mutator allocates a
   different YLOS B at X.
4. Minor m's hand-over prep looks X up with `youngLargeMeta(X)`, finds **B**, and treats B as a
   member of the hand-over generation: it is scanned read-only and its young children are copied
   into the new fill, but its slots are not healed.
5. The tenure merge promotes B in place while its children are still young; nothing scans B again.
   B is live (reached through more than 40 links from the roots), and its slots point into a nursery
   extent that is later recycled. The next STW major's marker reads a word of an unboxed-Int Cons
   there as a header (`Tag_Custom`, size 0): HEAP_044.

The test "is it still ours?" by address alone is unsound whenever addresses can be reused between
the two points. **Fix candidates:** drop a dead YLOS from every extent's `ylos_gen` when a major frees
it; or store an identity stamp with each `ylos_gen` entry (the LargeBodyId, or an epoch) and compare
it. A cheap check that fixed E2 in the scratch tree: a real member was aged to ≥ 1 when it joined, so
skip a `ylos_gen` entry whose YLOS still has header age 0 (all 39 threaded-gc-07 tests pass with it).
**Model gap:** M5's §8.2 extension represents `ylos_gen` members by object id, so an address reused
by another object is invisible to it; extend it with a reused-id step (free + re-allocate at the same
id across a STW major) to guard the fix at model level.

This also unblocks the RSS lever `MAJOR_GC_LIVE_BUDGET = 3.0` (plans/gc-param-sweep): HEAP_057's
"every k is policy-safe" holds; k = 3.0 only exposed this defect.

History:
- 2026-09-29 Reproduced in a scratch validate build (5/5 at k = 3.0, 0/3 at 4.5), root-caused with
  validate-only instrumentation, and confirmed by a positive control (the age-0 guard makes E2 pass)
  and a negative control (suppressing CR-017's dead-parent greys does not help).
- 2026-09-29 **Reproduced in the model** (M5; `test/tla/M5-tenuring/AUDIT.md`). M5 had missed it because
  its generation-YLOS extension tracked members by identity: a freed member simply vanished, which is
  fix candidate 1's behaviour. With `ylos_gen` kept by address (`YlosGen = "code"`) and the new
  invariant `YlosGenIdentity` (every member of a generation's snapshot joined that generation):
  - `test/tla/run_models.py --model M5 --config MC_ylos_aba` violates `YlosGenIdentity` (38 states): the entry's steps 1–4;
  - `MC_ylos_aba_heap005` violates `OldPointsOld` (HEAP_005, 63 states): step 5, B promoted with a
    slot into the Fresh extent;
  - **new path at k = 2:** `MC_k2_ylos_aba` violates `NoDangling` (50 states): the ageing prep
    (`NurseryRegion.cpp` :773-775) claims B and the pause records it without scanning it
    (:519-523), so B's eden child is lost at that minor.
  Not modelled, but the same code: a claimed YLOS builder would be promoted while its kernel still
  writes it.
- 2026-09-29 **Fix-design evidence** (model controls, `controls/`; no code changed): dropping the freed
  address from every `ylos_gen` at the major passes (k = 1 and k = 2), and so does a never-reused
  stamp (a serial or epoch). The scratch tree's "skip header age 0" check passes at k = 1 (and over
  the whole combined boundary, 40.4M states) but **fails at k = 2** (`YlosGenIdentity` in 59 states,
  `OldPointsOld` in 95: the ageing prep skips B while it is age 0, B joins the next generation at
  age 1, and the next hand-over claims it). The `LargeBodyId` is **not** a usable stamp: a release
  pushes the freed id (`OldGenSpace.cpp` ~:6431) and the next registration pops it LIFO (~:7530),
  so B gets A's id (fails in 38 states). Implementation note for candidate 1: every kind-1
  retirement site of a major must drop the address; with `old_gen_bitmap_alloc` on (the default),
  pruning every Young extent's lists at the end of the major is equivalent, but with it off the
  lazy sweep retires entries after the mutator resumes, so that prune is not enough.

### CR-035 — the empty-block flip keeps stale large-body index entries, so a live body at the same address can be freed

| | |
|---|---|
| Status | Reproduced (model, TLC, 2026-09-29); Guarded at model level by M8 `MC_quick_cr035`, `MC_quick_cr035_lost` |
| Severity | S1 (a live young large object or large body freed); **serial**, not a concurrency defect |
| Found | 2026-09-29, the address-reuse (ABA) audit after CR-034 |
| Where | `OldGenSpace::allocateFromEmptyRegularBlocks` (`OldGenSpace.cpp` ~:2855-2913) flips a block to large without purging `large_body_index_` for its range, unlike `releaseBlockToAllocator` (~:6424-6433), which does; `registerLargeBody` (~:7537, `large_body_index_[body] = id`) overwrites the key of a new body at the same address; `freeLargeBodyCell` (~:7695) erases by address (`large_body_index_.erase(m.body_base)`) before its `is_large` test (tree of 2026-09-29) |
| Models | M4 (its `ReleasedSafe` is blind to address reuse by construction) |
| Invariants | HEAP_026, HEAP_062 |
| Repro | `test/tla/run_models.py --model M8 --config MC_quick_cr035` (`violates:IndexFaithful`) and `MC_quick_cr035_lost` (`violates:NoLostObject`, 13 states) |
| Guard | the two M8 rows (expected-fail); purging the index at the flip passes both as a control |
| Fix | — (candidate: purge `[start, end)` at the flip, as release does; CR-018's fix (a) also removes the precondition) |

The chain: a dead YLOS or large body Y sits at the start X of a mixed page whose `live_bytes`
reads 0 (the CR-018 precondition), so an exact-size allocation flips the page and places a new
large object Z at X, re-registering key X for Z. At the next minor, Y's stale meta is freed, which
erases key X, which is now Z's. At the following minor Z is not found through the index: it is not
reached, not scanned and never recoloured, and the sweep frees its block while Z is live.

Side notes from the same audit (not defects): recycled `LargeBodyId`s can stay listed in
`nursery_owned_bodies_` after a release (duplicates are benign; about 24 bytes leak per retired id,
and the "already there" comment on that path is wrong); a first-fit reuse of a larger free extent
drops its tail, so committed bytes drift upward (`Allocator.cpp` ~:787-793).

History:
- 2026-09-29 Confirmed (shape): the ABA audit's reading; the orchestrator re-read the flip (no
  index purge), release's purge and `freeLargeBodyCell`'s erase by address.
- 2026-09-29 **Reproduced (model)**, M8: the S1 chain as described, in 13 states: a dead YLOS Y at page P's
  **start** (precision: Y must be at the start); a page-sized YLOS Z flips P and takes key X while Y's
  meta stays in `nursery_owned_bodies_` (`IndexFaithful` fails here); the next minor frees Y's meta,
  and `erase(X)` removes Z's key; the minor after cannot find Z, frees it, and pushes P onto
  `free_large_blocks_` while Z is live (`NoLostObject`). Purging the index at the flip passes both
  rows.

### CR-036 — IM5's t0-block check cannot see a same-id, same-start re-issue

| | |
|---|---|
| Status | Confirmed (shape, 2026-09-29), by code reading |
| Severity | G (validate-only coverage gap; not live today) |
| Found | 2026-09-29, the address-reuse (ABA) audit |
| Where | `OldGenSpace::checkT0BlocksUnchanged` and `isT0Block` (`OldGenSpace.hpp` ~:1474-1477; `cycle_t0_blocks_` filled at `OldGenSpace.cpp` ~:4418) compare id, start, class and `is_large` only (tree of 2026-09-29) |
| Models | M1 (IM5 is `NoReleaseInCycle`), M4 |
| Invariants | IM5, HEAP_063 |
| Repro | n/a |
| Guard | — |
| Fix | — (candidate: a per-id generation counter captured in `T0Block`) |

A release in the middle of a cycle followed by a re-issue of the same block id at the same start
with the same class would pass IM5's check. It cannot happen today, because every release path
asserts `!cycleActive()`; but CR-014 shows a release path that runs where the deferral was meant to
apply, and IM5 is what a validate build relies on to notice such a regression.

History:
- 2026-09-29 Confirmed (shape): the ABA audit.
- 2026-09-29 M8: a same-id, same-start re-issue is reachable within one major (witness
  `MC_quick_reissue_witness`, 5 states) and harmless between cycles, consistent with this entry
  (the gap only matters if a release ever happens during a cycle).

### CR-037 — region mode: the hand-over's `lb_bodies` colouring by address hides a new YLOS at a reused address from the minor

| | |
|---|---|
| Status | Reproduced (model, TLC, 2026-09-29); Guarded at model level by M5 `MC_lb_aba` |
| Severity | S1 (a live young object is lost with eden). Region mode, the default, at k = 1 |
| Found | 2026-09-29, M5's address-reuse work (the parallel audit had judged this list "floating garbage only"; that holds only when the address holds another body) |
| Where | `NurserySpace::minorGCRegion`'s hand-over prep, `NurseryRegion.cpp` ~:749 and ~:771 (`for (b : Hx.lb_bodies) oldgen.markLargeBodySeen(b, minor_color_)`); `OldGenSpace::markLargeBodySeen` (`OldGenSpace.cpp` ~:7542-7552) colours whatever index entry is at the address, with no kind check; `reachYoungLargeR`'s "already reached this minor" return (`NurseryRegion.cpp` ~:526); the colour flip (~:675); a new YLOS registered with the old colour (`ThreadLocalHeap.cpp` ~:469) (tree of 2026-09-29) |
| Models | M5 (constant `LbKey`) |
| Invariants | HEAP_062, HEAP_070 |
| Repro | `test/tla/run_models.py --model M5 --config MC_lb_aba` (52 states) |
| Guard | M5 `MC_lb_aba` (expected-fail) |
| Fix | — (model controls that pass: colour kind-0 index entries only; drop the address at the major; an identity stamp) |

Same class as CR-034 (an address remembered across a STW major), a different list and a different
mechanism. A large string's header is copied into the Fresh extent and its body address joins that
extent's `lb_bodies`. The header dies, and a STW major frees the body. A new YLOS B, pointing at a
young object e, is allocated at the same address. At the next hand-over the prep colours the index
entry at that address, which is now B's, with this minor's colour; B's first reach then sees the
colour, returns "already reached", and B is neither scanned nor aged, so e is lost with eden.

History:
- 2026-09-29 Reproduced (model): M5 `MC_lb_aba`; the auditor's "floating garbage" verdict corrected
  by the model for the case where the address holds a young, not-yet-reached YLOS.

### CR-038 — k ≥ 2: a dead ageing-generation YLOS keeps an unhealed slot into a retired extent, which the t0 snapshot reads

| | |
|---|---|
| Status | Reproduced (model, TLC, 2026-09-29) |
| Severity | D today (benign: the snapshot drops young targets by address range); S4 as a premise for any future walker. **Opt-in** tenure age k ≥ 2 only |
| Found | 2026-09-29, M5's address-reuse and boundary work |
| Where | `OldGenSpace::snapshotYoungLarge` (`OldGenSpace.cpp` ~:4426) walks every young YLOS at t0; 07b's zap in `mergeJob` (`NurseryTenure.cpp` ~:849-857) covers dead survivor objects only, not YLOS; the snapshot drops young targets by range (`OldGenSpace.cpp` ~:3325-3327) (tree of 2026-09-29) |
| Models | M5 |
| Invariants | HEAP_070 (07b's zap premise) |
| Repro | `test/tla/run_models.py --model M5 --config MC_k2_ylos_walk` (88 states; no major needed) |
| Guard | M5 `MC_k2_ylos_walk` (expected-fail) |
| Fix | — |

At k = 2, a YLOS of an ageing generation that dies keeps a slot pointing into an extent that has
since been retired and recycled; nothing heals or zaps it, and the next t0 snapshot reads it. Today
the read is harmless because the snapshot discards young targets by range, but it breaks the stated
premise of the zap ("no dead object's slot is read after its extent is retired"), so any future
walker that follows YLOS children would read a recycled extent.

History:
- 2026-09-29 Reproduced (model): M5 `MC_k2_ylos_walk`.
