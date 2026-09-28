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

Updated 2026-09-28 after the adversarial review of the TLA+ model plans (CR-017 to CR-024 are new;
several entries gained evidence, and CR-002 moved to Confirmed).

| Id | Title | Status | Sev | Model |
|---|---|---|---|---|
| CR-018 | After the sweep, mixed-block allocations are not counted in `live_bytes`, so the empty-block flip can take a live block (**serial**, not a concurrency defect) | Confirmed (shape) | S1 | — (unit test) |
| CR-017 | Region mode: the t0 young walk greys old cells that a STW major freed, through dead hand-over objects | Confirmed (shape); S1 chain suspected | S1 (suspected) | M1, M5, M4 |
| CR-014 | lazySweep's tail completion path runs `onSweepComplete()` inside a parallel minor, bypassing the deferral (also races `live_bytes` and `large_body_index_`) | Confirmed (shape) | S1 (suspected) + S2 | M4, M7, M3 |
| CR-001 | `gc_phase_` written under `promo_mu_`, read unlocked by other promotion workers; the allocate-black/accounting decision moved from pop to finalize | Confirmed | S2 (possible S1) | M4 |
| CR-002 | Gap sweep's plain `clearBit` and word read share a bitmap word with a stashed cell's `setMarkBitAtomic` | Confirmed (shape) | S2 | M4, W3 |
| CR-012 | Multi-mutator only: unlocked committed-bytes reads, process-wide decommit clocks and free list, `acquireOldGenRegion` vs commit-ahead, `validatePageWork` | Confirmed | S2 (precondition) | — |
| CR-021 | Plain reads of `region_end_` and owner words while markers hold `atomic_ref`s ([atomics.ref.generic]/3) | Confirmed | S2 (letter) | W4 |
| CR-023 | A foreign `stopAndJoin` can wait out a whole relaunched episode | Confirmed (shape) | S3 | M6 |
| CR-003 | `GCHelperPool::atforkPrepare` drains and locks in two critical sections (also strands Running jobs; the child's `exit()` hangs) | Confirmed (shape) | S4 | M6 |
| CR-015 | `Allocator::thread_mutex_` has no atfork handler: a non-mutator fork while it is held leaves it locked in the child (the child's `exit()` hangs) | Confirmed (shape) | S4 | M6 |
| CR-006 | gc-heap-tsan runs with `gc_thread_mode = 0`: the pool and concurrent marking are never under TSan together | Confirmed | G | M6/M7 |
| CR-008 | No harness covers fork (including a child that calls `exit()`), multiple heaps, or a gang thread waiting on a pool job | Confirmed | G | M6/M7 |
| CR-010 | IM14 is asserted only at launch | Confirmed | G | M1/M2 |
| CR-011 | `MinorWork.hpp` claims a runtime test of the composed forward words; none exists | Confirmed | G | none (unit test) |
| CR-020 | No TSan harness runs the parallel YLOS reach with more than one worker | Confirmed | G | M3 |
| CR-009 | 05c plan G12 says every region-bound write goes through the setters; `recomputeRegionBounds` writes `region_end_` directly | Confirmed | D | M1/W4 |
| CR-022 | Comments justify promotion chunks as "whole bitmap bytes"; the scans need whole 64-bit words | Confirmed | D | M4, W3 |
| CR-024 | `GCHelperPool.hpp` says the gang's `atexit` handler is registered at the first launch; the constructor registers it | Confirmed | D | M6 |
| CR-016 | Empty-regular-block flip under `promo_mu_` vs a worker's stash or unflushed chunks (exact-size promotion; test geometries) | Suspected | S1 (test geometries) | M4 |
| CR-019 | Legacy mode: a young YLOS header written under `ylos_mu_`, read by a sweep slice under `promo_mu_` | Suspected | S2 | M3 |
| CR-007 | A `promo_mu_` holder can block on a helper discard job; the stall is attributed outside the pause (more routes: CR-014, the pause tenure engine) | Suspected | S3 | M7 |
| CR-004 | Background-gang fork window: the mutator can relaunch between `stopAllForFork` and the gang locks | Suspected (Not-a-bug likely) | S4 → S1 in the child | M6 |
| CR-013 | Tenure-collector fork window: the child inherits a job stopped mid-item (its "possible exit" fails at teardown) | Suspected | S4 → S1 in the child | M5, M6 |
| CR-005 | A fork-stop during the closing join trips `assert(bg_ep_ == Finished)` (on in the everyday `build` preset) | Suspected | S4 | M2, M6 |

---

## Entries

### CR-001 — `gc_phase_` race in parallel promotion, and a decision point that moved

| | |
|---|---|
| Status | Confirmed (2026-09-28), by code reading |
| Severity | S2; possibly S1 (see "why it matters") |
| Found | 2026-09-28, protocol mapping for the TLA+ plan |
| Where | write: `OldGenSpace.cpp:5247` in `lazySweep()`; unlocked reads: `:1075` in `finalizePoppedCellW()`, `:1135` in `finalizeBitmapCellW()` (post-7c tree of 2026-09-28) |
| Models | M4 (race detector, plain field `gc_phase_`; configs `sweep_race_phase`, `sweep_release`) |
| Invariants | HEAP_051, HEAP_054, HEAP_067, IM4, PM6, GC_DET_001 |
| Repro | — (proposed: a gc-heap-tsan scenario that forces sweep-on-demand, ladder rung 5/8, inside a parallel minor) |
| Guard | — |
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

### CR-002 — plain `clearBit` and atomic `fetch_or` on the same mixed-block bitmap byte

| | |
|---|---|
| Status | Confirmed (shape, 2026-09-28), by code reading in the M4 review; not reproduced |
| Severity | S2 |
| Found | 2026-09-28, protocol mapping |
| Where | `OldGenSpace.cpp:5360` `bitscan::clearBit(gbits, nb)` in `lazySweep()` (gap-sweep loop, under `promo_mu_`) vs `OldGenSpace.cpp:1083` `setMarkBitAtomic(id, result)` in `finalizePoppedCellW()` (outside the lock); also the sweeper's plain 64-bit word read `nextSetBit` (`:5339`, through `bitscan::loadWord`, `BitmapScan.hpp:25-29`) (post-7c tree) |
| Models | M4 (config `sweep_race_bitmap`), W3 (W3c classifies the pattern) |
| Invariants | HEAP_050, HEAP_055, IM4 |
| Repro | — |
| Guard | — |
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

### CR-003 — `GCHelperPool::atforkPrepare`: drain and lock are separate critical sections

| | |
|---|---|
| Status | Confirmed (2026-09-28) for the code shape; the hazard needs a fork from a non-mutator thread |
| Severity | S4 |
| Found | 2026-09-28, protocol mapping |
| Where | `GCHelperPool.cpp:260-265` in `GCHelperPool::atforkPrepare()` |
| Models | M6 |
| Invariants | HEAP_058, HEAP_007 |
| Repro | — |
| Guard | — |
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

### CR-004 — background-gang fork window: relaunch between `stopAllForFork` and the gang locks

| | |
|---|---|
| Status | Suspected (2026-09-28) |
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

### CR-005 — fork-stop during the closing join trips `assert(bg_ep_ == Finished)`

| | |
|---|---|
| Status | Suspected (2026-09-28) |
| Severity | S4 (assert builds only, which include the everyday `build` preset: `-O2 -g -UNDEBUG`, `CMakePresets.json:34-35`; release builds fall through to a correct drain) |
| Found | 2026-09-28, protocol mapping |
| Where | `OldGenSpace.cpp:4598-4599` in `closingFinish()` (post-7c tree) |
| Models | M2 (`episode_stop`, invariant `ClosingFinished`), M6 (`ClosingFinished`) |
| Invariants | IM9, IM15 |
| Repro | — |
| Guard | — |
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

### CR-013 — tenure-collector fork window: the child inherits a job stopped mid-item

| | |
|---|---|
| Status | Suspected (2026-09-28) |
| Severity | S4 → S1 in the child |
| Found | 2026-09-28, while writing the M5 plan (finding F1 there) |
| Where | `GCHelperPool.cpp:664-669` (`GCBackgroundGang::atforkPrepare`: `stopAllForFork`, then lock each gang's `m_`); relaunch at `NurseryTenure.cpp:572` (`tenureLaunch`, exact engine) or `:1234` (`tenureConcLaunch`, L3); item bookkeeping at `TenureWork.hpp:301-305` (`SerialEngine::step`: `next_start++` before `tenure()`) and the stack pop before `scanCopy` (post-7c tree) |
| Models | M5 (`fork` configuration, mutant `fork_mid_item`), M6 |
| Invariants | TV1, HEAP_070, FORBID_HEAP_004 |
| Repro | — |
| Guard | — |
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

### CR-014 — lazySweep's tail completion path runs `onSweepComplete()` inside a parallel minor

| | |
|---|---|
| Status | Confirmed (2026-09-28) for the code shape; reachability not yet shown |
| Severity | S1 (suspected); an S2 race on `live_bytes` whenever the path runs |
| Found | 2026-09-28, while writing the M4 plan (its suspicion 2); verified by reading |
| Where | `OldGenSpace.cpp:5466-5472` in `lazySweep()` (tail path: `gc_phase_ = Idle; onSweepComplete();`), compared with the in-loop path at `:5247-5255` (`if (par_promo_active_) sweepCompleteInPromotion(); else onSweepComplete();`) (post-7c tree) |
| Models | M4 (configs `sweep_tail`, `sweep_tail_release`, `sweep_tail_live`), M7 (a release route into its lock chain), M3 (footprint: `large_body_index_`) |
| Invariants | HEAP_054, HEAP_067, PM4, PM6, IM5 |
| Repro | — |
| Guard | — |
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

### CR-015 — `Allocator::thread_mutex_` has no atfork handler

| | |
|---|---|
| Status | Confirmed (2026-09-28) for the code shape |
| Severity | S4 |
| Found | 2026-09-28, while writing the M6 plan |
| Where | `Allocator::thread_mutex_` (a `std::recursive_mutex`), held around every helper post and wait (HEAP_058; `Allocator.cpp:753, 892, 1253`); `pthread_atfork` registrations exist only in `GCHelperPool.cpp:112, 340, 508` (post-7c tree) |
| Models | M6 (`ChildLocksFree`) |
| Invariants | HEAP_058 |
| Repro | — |
| Guard | — |
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

### CR-016 — empty-regular-block flip under `promo_mu_` vs a worker's stash (test geometries only)

| | |
|---|---|
| Status | Suspected (2026-09-28) |
| Severity | S1, but only in test geometries |
| Found | 2026-09-28, while writing the M4 plan (its suspicion 3) |
| Where | `OldGenSpace.cpp:2665` `allocateFromEmptyRegularBlocks` (the `live_bytes == 0` test and skips at `:2676-2679`), stash return at `:1440-1443` (post-7c tree) |
| Models | M4 |
| Invariants | HEAP_054, PM6 |
| Repro | — |
| Guard | — |
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

### CR-006 — the heap-level TSan harness never runs the helper pool

| | |
|---|---|
| Status | Confirmed (2026-09-28) |
| Severity | G |
| Found | 2026-09-28, protocol mapping |
| Where | `test/gc-heap-tsan/heap_driver.cpp:53` (`cfg.gc_thread_mode = 0;`) (post-7c tree) |
| Models | M6, M7 |
| Invariants | HEAP_058, HEAP_059, HEAP_060 |
| Repro | n/a |
| Guard | — |
| Fix | — |

The only harness that runs the real allocator with concurrent marking and parallel minors has the
helper pool switched off. Deferred decommit, commit-ahead, and a gang thread blocking on a pool job
(CR-007) are therefore never under TSan together with marking. **Next step:** add a
`gc_thread_mode = 2` arm, plus a jitter arm, to gc-heap-tsan.

History:
- 2026-09-28 Confirmed: line verified by reading.

### CR-007 — a `promo_mu_` holder can block on a helper discard job

| | |
|---|---|
| Status | Suspected (2026-09-28) |
| Severity | S3 (a stall, not a deadlock); stats misattribution |
| Found | 2026-09-28, protocol mapping |
| Where | `OldGenSpace.cpp:1249-1251` `startVirginBlockShared()` → `ensureBagPageAvailable` (`:866-871`) → `Allocator::acquireOldGenBlock` (`Allocator.cpp:752`) → `PageWork::onReuse` → `GCHelperPool::wait` (`PageWork.cpp:151-169`); `callerInPause()` at `Allocator.cpp:1206` (post-7c tree). Two more routes into the same chain (M7 review, 2026-09-28): the CR-014 tail path (`lazySweep`, `OldGenSpace.cpp:5466-5476`, reached under `promo_mu_` from the ladder at `:2147`, `:2169`, `:2410`) → `onSweepComplete` → `releaseOldGenBlock` → `PageWork::onRelease` → a wait on an overlapping populate; and the pause tenure engine, whose `GCMarkGang` members promote through `allocatePromotion` (`NurseryTenure.cpp:984`, `runJobParallel` `:1167`) |
| Models | M7 (M7b: lock order, `MODEL_M7_StallWitness`) |
| Invariants | HEAP_058, HEAP_059 |
| Repro | — |
| Guard | — |
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

### CR-008 — no harness covers fork, multiple heaps, or a gang thread waiting on a pool job

| | |
|---|---|
| Status | Confirmed (2026-09-28) |
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

### CR-009 — region bounds: plan says "only through the setters", the code has a direct write

| | |
|---|---|
| Status | Confirmed (2026-09-28) |
| Severity | D (benign today) |
| Found | 2026-09-28, protocol mapping |
| Where | `OldGenSpace.cpp:561` in `recomputeRegionBounds()` (`region_end_ = new_end;`), vs 05c plan G12 / row H5 (post-7c tree) |
| Models | M1, W4 |
| Invariants | HEAP_049, IM5 |
| Repro | n/a |
| Guard | — |
| Fix | — |

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

### CR-010 — IM14 (slot quiescence) is asserted only at launch

| | |
|---|---|
| Status | Confirmed (2026-09-28) |
| Severity | G (validator gap) |
| Found | 2026-09-28, protocol mapping |
| Where | `OldGenSpace.cpp:4361` `assertSlotsQuiescent()`; its only caller is `:4433` (`launchBackground`) (post-7c tree) |
| Models | M1, M2 |
| Invariants | IM14 |
| Repro | n/a |
| Guard | — |
| Fix | — |

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

### CR-011 — the promised runtime layout test for forward words does not exist

| | |
|---|---|
| Status | Confirmed (2026-09-28) |
| Severity | G |
| Found | 2026-09-28, protocol mapping |
| Where | `MinorWork.hpp:17-18` (comment: "static_assert on the tag, runtime test on the composed words"); `NurseryParallel.cpp:39-40` (the static_assert) |
| Models | none: M3 assumes the encoding (its trace validation cannot see a mismatch either, because the harness decodes with `mw::fwdAddr`, which always agrees with `mw::fwdWord`) |
| Invariants | HEAP_006, HEAP_067 |
| Repro | n/a |
| Guard | — |
| Fix | — |

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

### CR-017 — region mode: the t0 young walk greys old cells that a STW major freed

| | |
|---|---|
| Status | Confirmed (shape, 2026-09-28) for greying a freed cell, by code reading; the S1 chain beyond it is Suspected |
| Severity | S1 (suspected, long precondition chain). Certain effects: floating garbage, spurious validate-build aborts. Also D: the 07 plan (P§3.16) calls the walk of dead objects "conservative and safe" |
| Found | 2026-09-28, adversarial review of the M1 plan; checked by the orchestrator |
| Where | `NurserySpace::forEachYoung`, `NurserySpace.hpp:800-830` (walks Young and Tenuring extents, skips only `Tag_Free`); `ThreadLocalHeap::startMarkCycle` `markChildren`, `ThreadLocalHeap.cpp:1102`; the only zap is 07b's, for ageing extents, `mergeJob` `NurseryTenure.cpp:816-825`; `OldGenSpace::startMark`, `OldGenSpace.cpp:2881-2889` (a STW major marks nursery objects from roots only) (post-7c tree) |
| Models | M1 (`quick_region`: expected `MarkerFootprint` violation; `quick_region_nomajor` passes), M5 (`YoungWalkValid`, config `cycle_major`), M4 (`marker_on_post_t0`: the worst case's lost bit) |
| Invariants | IM3, IM13, HEAP_063, HEAP_SNAPSHOT_001 |
| Repro | — (proposed: a validate-build unit test in region mode, k = 1: x → c with c old, drop x, explicit major, then force the trigger at the next minor) |
| Guard | — (M1 `quick_region` and M5 `cycle_major` fail on the current code once TLC runs) |
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

### CR-018 — after the sweep, mixed-block allocations are not counted, so the empty-block flip can take a live block

| | |
|---|---|
| Status | Confirmed (shape, 2026-09-28), by code reading; not reproduced |
| Severity | S1. **Serial, not a concurrency defect**: recorded here because this work found it and it is the common root of CR-016 and CR-001's S1 half. Its fix belongs to the old-gen allocator |
| Found | 2026-09-28, adversarial review of the M4 plan; checked by the orchestrator |
| Where | `OldGenSpace::initObjectHeaderWithSize`, `OldGenSpace.cpp:497` (`live_bytes` is added only while `marking_active \|\| gc_phase_ != Idle`); `allocateFromEmptyRegularBlocks`, `:2665-2716` (flips any `fully_swept && live_bytes == 0` block, `:2672`; drops its free cells and its bitmap slot, writes a large header at its start); reached from `allocate()` for `size >= alloc_buffer_size` (`:1931-1933` → `allocateLargeBlock` → `:2733`); all-dead blocks kept by the shrink's `min_heap` floor (`:6214`) (post-7c tree) |
| Models | none (serial). M4 open question 3 |
| Invariants | HEAP_051, HEAP_054 |
| Repro | — (proposed unit test: make a mixed block all-dead at a major, keep it under the `min_heap` floor, finish the sweep, allocate small objects into its free runs, then allocate exactly `alloc_buffer_size` bytes, and check the small objects) |
| Guard | — |
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

### CR-019 — legacy mode: a young YLOS header written under `ylos_mu_`, read by a sweep slice under `promo_mu_`

| | |
|---|---|
| Status | Suspected (2026-09-28) |
| Severity | S2 (legacy nursery only, not the default) |
| Found | 2026-09-28, adversarial review of the M3 plan |
| Where | writes: `NurserySpace::reachYoungLargeP`, `NurseryParallel.cpp:378` (`h->age++`), and `OldGenSpace::promoteYoungLarge`, `OldGenSpace.cpp:7125` (`age = 0`), both plain writes to the header word under `ylos_mu_`; read: the gap sweep's `walkStep(block, getObjectSize(live_obj))`, `OldGenSpace.cpp:5361`, inside `allocatePromotion` under `promo_mu_` (post-7c tree) |
| Models | M3 (footprint note only) |
| Invariants | HEAP_062, HEAP_067 |
| Repro | — |
| Guard | — |
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

### CR-020 — no TSan harness runs the parallel YLOS reach with more than one worker

| | |
|---|---|
| Status | Confirmed (2026-09-28) |
| Severity | G |
| Found | 2026-09-28, adversarial review of the M3 plan |
| Where | `NurserySpace::reachYoungLargeP` (`NurseryParallel.cpp:359-391`) and its region twin `reachYoungLargeR`; `test/gc-helper-tsan/minor_harness.cpp` has no YLOS; `test/gc-heap-tsan/heap_driver.cpp:78-111` allocates no pointer-bearing large object |
| Models | M3 (`ylos_unlocked`) |
| Invariants | HEAP_062, HEAP_067 |
| Repro | n/a |
| Guard | — |
| Fix | — |

The `ylos_mu_` protocol (colour test, age, in-place promotion) is exercised only single-threaded
or not at all under TSan, and it touches `large_body_index_`, which CR-014 can race. **Next step:**
add a YLOS object kind to `minor_harness` (M3's trace plan needs it anyway) and a pointer-bearing
large object to `heap_driver`.

History:
- 2026-09-28 Confirmed: from the M3 review (harness contents read).

### CR-021 — plain reads of `region_end_` and page-index owner words while markers hold `atomic_ref`s

| | |
|---|---|
| Status | Confirmed (2026-09-28), by code reading |
| Severity | S2 (the letter of the standard; read/read, benign on every target) |
| Found | 2026-09-28, adversarial review of the W plan |
| Where | plain reads of `region_end_` at `OldGenSpace.cpp:875` (`ensureBagPageAvailable`), `:2768` (`allocateLargeBlock`), `OldGenSpace.hpp:351` (`getCommittedBytes`); plain reads of owner words in `assignPageIndexForBlock`, `OldGenSpace.cpp:599-609`; markers read both through `atomic_ref` (`regionEnd()`, `OldGenSpace.hpp:409`; `loadOwner`, `:449`) (post-7c tree) |
| Models | W4 |
| Invariants | HEAP_049 |
| Repro | n/a (no C11 tool reports it: it is not a data race) |
| Guard | — |
| Fix | — |

C++20 [atomics.ref.generic]/3: while any `atomic_ref` to an object exists, every access to it must
go through an `atomic_ref`. The single writer reads these words plainly while a background marker
may be inside a `regionEnd()` or `loadOwner()` load. **Fix:** route the writer's reads through
`regionEnd()` / `loadOwner()` (relaxed), which costs nothing.

History:
- 2026-09-28 Confirmed: from the W review; the orchestrator checked the plain reads at `:875`,
  `:2768` and `getCommittedBytes`.

### CR-022 — comments justify promotion chunks as "whole bitmap bytes"; the scans need whole words

| | |
|---|---|
| Status | Confirmed (2026-09-28) |
| Severity | D (the code is correct) |
| Found | 2026-09-28, adversarial reviews of the M4 and W plans |
| Where | `OldGenSpace.hpp:630-631`, `:639-640`, `:689`; `OldGenTenure.cpp:202`; the 07 plan §10.18 item 1. The scans read 64-bit words: `bitscan::loadWord`, `BitmapScan.hpp:25-29` (`nextFreeCell`, `nextSetBit`) |
| Models | M4 (mutant `chunk_unit_subword`), W3 (`W3_BYTE_CHUNK`) |
| Invariants | HEAP_054, HEAP_067 |
| Repro | n/a |
| Guard | M4 `chunk_unit_subword` |
| Fix | — |

Chunks are 64 cells, so each owns whole 64-bit bitmap words, which is what `nextFreeCell` and
`nextSetBit` need: they read a word with a plain load. The comments say chunks own "whole bitmap
bytes", a weaker property that would permit a data race if someone shrank the chunk to 8 cells on
the strength of the comment. **Fix:** correct the comments.

History:
- 2026-09-28 Confirmed: reported by the M4 and W reviews.

### CR-023 — a foreign `stopAndJoin` can wait out a whole relaunched episode

| | |
|---|---|
| Status | Confirmed (shape, 2026-09-28), by code reading |
| Severity | S3 (a stall; nothing is lost). Precondition: a stop from a thread other than the owner (a non-mutator fork's prepare, or exit) |
| Found | 2026-09-28, adversarial review of the M6 plan; checked by the orchestrator |
| Where | `GCBackgroundGang::stopAndJoin` → `joinLocked`, `GCHelperPool.cpp:638-643`, `:622-626` (`cv_done_.wait` releases `m_` until `finished_ >= members`); `GCBackgroundGang::launch`, `:600-613` (`finished_ = 0`, a new `stop_`) (post-7c tree) |
| Models | M6 (the interleaving is in the model; a bounded-wait property would expose it) |
| Invariants | HEAP_065 |
| Repro | — |
| Guard | — |
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

### CR-024 — `GCHelperPool.hpp` says the background gang's `atexit` handler is registered at the first launch

| | |
|---|---|
| Status | Confirmed (2026-09-28) |
| Severity | D |
| Found | 2026-09-28, adversarial review of the M6 plan |
| Where | the comment at `GCHelperPool.hpp:235-236` vs the registration in the constructor `GCBackgroundGang::GCBackgroundGang`, `GCHelperPool.cpp:505-512` |
| Models | M6 (its exit configuration models the code: registration at construction) |
| Invariants | — |
| Repro | n/a |
| Guard | — |
| Fix | — |

The header says `stopAllAtExit` is registered "at the first launch"; the code registers it (and the
atfork handlers) once, in the first gang's constructor. The difference decides whether a gang that
was built but never launched is stopped at exit; M6 models the code. **Fix:** correct the comment.

History:
- 2026-09-28 Confirmed: from the M6 review; the orchestrator read both places.
