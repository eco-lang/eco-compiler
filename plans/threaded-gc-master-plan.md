# Threaded GC — master plan (outline)

**Status:** OUTLINE (2026-09-24). Phases 0–5c are DONE (see §4); phase 6 is DONE and default-on (its retention gate was overridden, §4); later phases have no work plan yet.
Phases 4–5 were **reordered on 2026-09-25** (§3, dependency graph): P1 first, then incremental,
parallel and concurrent marking on a snapshot.

**Source:** `design_docs/parallel-gc.md`, the design-space investigation. Section references below
(§n) point into that report. It holds the correctness arguments, estimates, hazards and handbook
citations, and they are not repeated here.

**How this plan is used.** This document fixes the *sequencing* and the *boundaries* of the work.
A detailed work plan for each phase (`plans/threaded-gc-phase-N-<topic>.md`) is written **only when
that phase is about to be implemented**, against the tree as it is then. Earlier phases will move
line numbers, invalidate premises and change measured numbers. That is the point of deferring:
see [[gc-plan-premises-need-rederiving]]. When a phase finishes, update its row in the tracking
table (§4) with the outcome and any facts that later phases must know. Do not edit the later phase
descriptions into mini-plans.

---

## 1. Goals, priorities and constraints (decided 2026-09-24)

1. **Pause time takes precedence over wall time.** Both matter, but where a choice exists, the
   phase that removes the largest pause goes first. The phases are ordered by worst pause removed:

   | today's pause | size |
   |---|---|
   | major-GC mark pause | ~1.3 s |
   | post-major sweep burst inside minor GC | 986 ms worst |
   | typical minor pause | ~31 ms |

2. **The target is massive workloads, not only the self-compile.** HPointers address ~8 TB. Any
   pause that grows with the *old-gen size* is unacceptable in the end state. Only pauses that grow
   with roots or with the nursery are acceptable. This is why concurrent marking is the end state
   for the old gen, and parallel marking is only a stepping stone (§5.8 of the report).
3. **Memory budgets.**

   | workload | budget |
   |---|---|
   | self-compile runs (the main test bed, not the eventual workload) | 15 GB |
   | normal Elm programs (future defaults) | ~4 GB |

   Every phase that changes retention reports old-gen peak and RSS. Heap-relative policies (pacing,
   triggers) must work at 4 GB as well as at 15 GB and beyond.
4. **Reference counting is out of scope.** The RC tier (`plans/opt-tier3-rc-runtime.md`) may later
   become a separate heap implementation. This plan therefore adopts the "frozen published heap"
   invariant (report §11.2, HEAP_SNAPSHOT_001) freely. No RC compatibility is designed in.
5. **Immutability is preserved and relied upon.** HEAP_005 (no old→young pointers) and HEAP_031
   stay. Every concurrent phase leans on the snapshot-closure lemma (report §2.1) and must keep its
   premises true.

## 2. Standing rules (every phase)

- **Independently shippable.** Each phase lands behind a flag, is measured, and then flips to
  default-on (or is closed and reverted) before the next phase that depends on it starts. The flag
  can come out once the phase has been default-on through a release.
- **Gates**, all required:
  - E2E (`--target full`);
  - elm-tests;
  - the heap validator (`ECO_HEAP_VALIDATE` tree) on the runtime unit tests, E2E and the
    GC-pressure stress suite. **Not on the self-compile**: a validator self-compile takes hours
    and is not a gate (decided 2026-09-24). The GC-pressure stress run (≳1,000 minor GCs) is
    what exercises the validators under real GC load;
  - GC-pressure stress (`benchmarks/heap-config-gc-pressure.json`; the default config runs zero
    minor GCs);
  - `out.mlir` byte-identical;
  - the bootstrap fixed point.
- **Verify the artifact, never the exit code.** A crashed run can report rc=0; check the output
  file (`out_md5`).
- **Counter discipline:**
  - Phases that do not change policy must leave GC counters bit-identical.
  - Policy-changing phases (2, 6, 7b) re-baseline the counters deliberately and say so.
  - From phase 3 onward, **GC decisions must never depend on collector progress** (GC_DET_001,
    report §10). The synchronous mode must reproduce the concurrent mode's counters exactly.
- **Measurement:** report wall, GC time, **max pause, p99 pause and an MMU curve**, old-gen peak and
  RSS. From phase 3 onward also report mutator stall, collector CPU and interference. Judge
  mark-path work on the major-GC event log and minor-path work on the per-minor event log
  (phase 0).
- **Retention gate:** gate any retention-affecting change on old-gen peak *before* reading its wall
  time. Factors that raise the old-gen peak compound (the Sep-22 sweep).
- **Invariants:** each phase lists the `invariants.csv` rows it adds or amends, and lands them in the
  same change (report §11).
- **Assert the invariant you are deleting or relying on.** Every structural premise gets an
  `ECO_HEAP_VALIDATE` check that re-derives it, exercised by the validate-tree unit tests, E2E and
  GC-pressure stress (not the self-compile, which is too slow under the validator).

## 3. Phases

### Dependency graph

**Reordered 2026-09-25**, after phase 3 and before any later phase had a work plan. The old-gen
marking work now builds the snapshot discipline first, single-threaded, and adds threads to a
marker that already runs on a snapshot. The first table below maps the old
numbers to the new; the old numbers remain in the done plans (00–03), the phase 0 baseline and older
loop entries. No retired label is reused.

| old | new | content |
|---|---|---|
| 7a | **4** | Frozen published heap (P1) |
| 5a | **5a** | Incremental marking on the mutator thread (snapshot protocol) |
| 4 | **5b** | Parallel marking, written against the snapshot |
| 5b | **5c** | Concurrent marking on collector threads |
| 6, 7b, 7c, 8 | unchanged | (7a is retired, not reused) |

| Phase | Depends on | Why |
|---|---|---|
| 0 | — | baseline data |
| 1 | 0 | a neutral refactor judged against the phase 0 baseline |
| 2 | 1 | builds on stable block ids and the in-place mark-bit arena |
| 3 | 1 | per-heap state instead of TLS; metadata that is safe to share |
| 4 | 0 | the census of kernel writes into already-survived objects |
| 4b | 4 | young large objects: restores HEAP_005 without the HEAP_061 exception before anything builds on it |
| 5a | 1, 4, 4b | the snapshot lemma that lets the mutator run between mark slices holds only under P1; the young generation must be exception-free |
| 5b | 3, 5a | helper pool; a marker that already runs on a snapshot |
| 5c | 3, 5b | collector threads; parallel-safe mark bits, deques and termination; the snapshot protocol |
| 6 | 2, 3 | thread-safe promotion destination; helper pool |
| 7b | 2, 4 | promotion buffers; the frozen-heap invariant |
| 7c | 3, 6, 7b | collector thread; parallel promotion machinery; survivor regions |
| 8 | per item | gated by measurements |

Phase 6 may be pulled ahead of phase 5 if wall time becomes the pressing need. Phase 4 is small
and can run in parallel with anything after phase 0, but it must land before 5a.

---

### Phase 0 — Measure and fix (no behaviour change)

**Why first:** the minor-GC anatomy, stack depth and cross-core interference are unmeasured. They
decide how phases 5b, 6, 7 and 8 are scoped.

**Scope:**
- Minor-GC phase timers at loop granularity, never per object:
  - the stack walk (moved inside the pause timer);
  - each root phase and each external scanner (CellStore cells and trail);
  - the Cheney loop and the promoted-object loop separately;
  - promotion-allocation time;
  - lazy-sweep bytes and time inside minor GC;
  - `minflt` per minor.
- A per-minor event log mirroring the major-GC event log.
- First-class pause reporting in the banner: max, p99 and an MMU curve for minor and major pauses.
- Stack-depth counters: frames walked, frames matched, slots.
- The L3 co-runner interference experiment (report §7.4.4, H-L3), as a benchmark script with no
  runtime change.
- A validator census of kernel writes into already-survived objects (the `in_phase3_` assertion on
  the self-compile). This is the evidence phase 7a needs.
- Latent-bug fix: the `ensureHeadroom` unsigned underflow (`NurserySpace.cpp:254-256`).
- Stale-documentation fixes listed in report §14.

**Deploy:** the timers are always on in stats builds. Counters stay bit-identical, and `out.mlir`
is byte-identical.

**Exit:** a baseline document recording the pause distribution and the minor-GC anatomy that later
phases are judged against.

---

### Phase 1 — Stable old-gen metadata (pure refactor)

**Why:** every threaded phase needs old-gen metadata that does not move or reallocate underneath
another thread. Done single-threaded, this can be proven neutral.

**Scope:**
- Fixed-capacity or VA-reserved storage with stable block ids for `blocks_` and its parallel arrays.
- A mark-bit arena that grows in place.
- The page index reserved for the whole heap reservation.
- Per-thread `live_bytes` accumulators merged at sync points.
- TLS singletons replaced by explicit per-heap state where GC code reaches them.

The full inventory is in report §3.5 and §3.1.

**Out of scope:** any threads, any policy change.

**Deploy:** no flag needed once gates pass. Counters are bit-identical.

**Exit:** the invariants rows describing stable metadata are added. The design must scale to a
multi-TB heap reservation without committing memory up front.

---

### Phase 2 — Promotion buffers via bitmap allocation (single-threaded policy change)

**Why:** this removes the 986 ms post-major sweep burst (a pause win) and most sweep work (a
throughput win). It is also the thread-safe promotion destination phase 6 requires.

**Scope:**
- The old-gen allocator takes free cells from the mark bitmap per size class for uniform blocks.
- A gap sweep, over live objects only, for mixed blocks.
- A per-class current-block cursor that serves as the promotion buffer.
- Reword HEAP_021/024/027 for uniform blocks.
- Decide the fate of `demoteMostlyDeadUniformBlocks`: it becomes the tunable lever
  `demote_live_fraction` (default 0.5 = today; 0.0 = never demote), calibrated by experiment E1.

See report §6.3.

**Hazards that must be named in the work plan:**
- the W6 ladder rule: the refill goes at the rung it replaces, never above the reuse rungs;
- W3/W4: branchy rewrites of predicted code can lose.

**Deploy:** behind a flag, with a deliberate counter re-baseline, gated on old-gen peak and RSS.

**Exit:** the worst minor pause no longer contains a sweep burst. Promotion cost per object is
measured with phase 0's timers.

---

### Phase 3 — Helper-thread infrastructure

**Why:** it provides the plumbing and the discipline every threaded phase uses, and proves both on
work that cannot corrupt the heap.

**Scope:**
- A GC helper-thread pool per process, serving any number of heaps.
- The handshake model: mutator-initiated post/collect at minor-GC slow paths (report §3.2). No async
  doorbell.
- Amend HEAP_007.
- The GC_DET_001 rule.
- `ECO_GC_THREAD` modes `0` (today's path), `sync` (same work items on the mutator) and concurrent.
- TSan-tested protocol harness.
- Stall, collector-CPU and interference reporting.
- **First user:** background page decommit/prefault, which touches no HPointers.

**Deploy:** default-on for decommit only once all modes agree on counters.

**Exit:** a reusable pool plus handshake API, and the measurement split in the banner.

---

### Phase 4 — Frozen published heap (P1)

**Why first:** every snapshot design rests on the snapshot-closure lemma (report §2.1): nothing
writes a pointer into an object that has already been published.
- Incremental marking (5a) lets the mutator run between mark slices; concurrent marking (5c) and
  concurrent tenuring (7c) run a collector alongside it.
- A kernel that writes into an already-survived object breaks the lemma for all three. The marker
  can then miss a live object: silent, rare and catastrophic.

Phase 0's census found no violation on E2E, but the full-scale census is still owed. This phase
turns "no violation seen" into an enforced invariant before any snapshot marker depends on it.
Formerly 7a; it was always scheduled "in parallel with anything after phase 0", and now it is
also a precondition.

**Scope:**
- The full-scale census that phase 0 owes: a periodic or signal-safe census dump on the
  self-compile (baseline §5).
- Adopt HEAP_SNAPSHOT_001: no writes into an object that has survived a GC unless it is flagged
  `builder`.
- Fix or `builder`-flag every kernel path the census finds.
- Enforce it with a validator tripwire.
- Adopt FORBID_HEAP_005 (no identity-negative comparisons).

**Deploy:** correctness hardening; no flag. Counters are bit-identical unless a kernel path has to
change.

**Exit:** HEAP_SNAPSHOT_001 is enforced by a validator that runs in the validate-tree gates, and
the full-scale census reports zero violations.

---

### Phase 5 — Old-gen marking on a snapshot

**Why:** it is the only old-gen design whose pause does not grow with heap size (goal 2). It is
built in three steps: the snapshot discipline without threads, then threads on a marker that
already honours it, then the move off the pause.

**Rule for all of phase 5: write every marker as if the world were running.**
- Markers read only the snapshot (roots, off-heap stores, nursery survivors as of t0) and the heap.
  They never read mutator-owned structures: free lists, cursors, `unassigned_blocks_`, the large
  body index.
- Nothing is released, reused or re-parsed under a running cycle; releases are deferred to the
  handoff.
- All per-marker state (live bytes, stack peaks, counters) is merged explicitly at the handoff.
- A 5b that quietly relied on the mutator being stopped would have to be rewritten for 5c.

#### 5a — Incremental marking on the mutator thread (snapshot protocol)

- Snapshot at a minor-GC end:
  - roots;
  - off-heap stores (CellStore cells and trail, MVar, scheduler queues);
  - the nursery survivors, via promote-all or a grey buffer (report §5.2).
- Log old-gen allocations so they are allocated black.
- Defer `freeLargeBodyCell` and block releases while marking.
- Emergency majors join the running cycle.
- Mark slices run at each minor-GC end; the handoff runs today's post-mark tail.
- Validator: "everything reachable at handoff is marked or allocated after t0".
- Deployable on its own. It spreads the major pause (today ~5 s at the last major) across minor
  pauses. It is deterministic, and single-threaded, so every bug reproduces exactly.

#### 5b — Parallel marking (formerly phase 4)

- Atomic mark test-and-set (`fetch_or` on `mark_.slot(id)`, HEAP_050).
- Chase–Lev deques and work stealing; the paused mutator is itself a worker.
- Two-phase termination, with spin-then-yield-then-sleep idling so an oversubscribed machine does
  not starve the worker being waited for.
- Large-array chunking.
- A per-thread prefetch ring.
- One `LiveBytesAccumulator` per marker (HEAP_051), merged deterministically.
- The worker count comes from available cores (affinity mask and cgroup quota), not
  `hardware_concurrency`; `gc_helper_threads = 0` means auto. With one core, run the same work
  inline.
- It runs 5a's slices, the handoff and any emergency full mark in parallel. It also works as a
  plain stop-the-world parallel mark when incremental marking is off.

See report §5.8. **Deploy:** behind `gc_threads`, where `gc_threads=1` is the reference, and
counters are bit-identical to it. **Exit:** slice and major-pause reductions confirmed on the
major-GC event log with per-collection pairing.

#### 5c — Marking moves to collector threads (formerly 5b)

- Concurrent mark slices on the phase 3 pool, parallel across markers using 5b's machinery.
  (As built, 2026-09-27: on a per-heap `GCBackgroundGang`, not the FIFO pool. A background
  episode lasts seconds and would block decommit jobs, and an unprivileged thread cannot get its
  priority back.)
- Heap-relative pacing: the trigger comes from promotion rate × predicted mark time.
- Mark assist when the collector is late (work moves onto mutator threads, never onto extra
  threads).
- The concurrent collector runs at low priority, so it only takes cores the mutators leave idle.
- The trigger margin is validated at both the 15 GB and the 4 GB budget.

**Invariants (phase 5):** HEAP_SNAPSHOT_002 (mutable roots are off-heap and snapshotted); HEAP_026
amendment.

**Exit:** the major pause equals the root-snapshot pause (~50 ms today, independent of heap size).
The old-gen peak increase is within budget.

---

### Phase 6 — Parallel stop-the-world minor GC

**Why:** it gives the largest wall-time win (−30 to −38 s at 4 threads) and shortens the most
frequent pause (~31 ms → ~12 ms).

**Scope:**
- A composed-word CAS forwarding install.
- Per-thread to-space copy buffers with parsable fillers.
- Block-local Cheney scanning with stealing.
- Promoted-object packets.
- List-spine copying in bounded runs, preserving hybrid-DFS contiguity.
- Parallel promotion into phase 2's buffers.
- A minor-GC trigger based on object bytes, so counters stay deterministic.
- En-masse promotion of the survivor prefix (report §7.3) is evaluated here as a variant.

**Deploy:** behind `gc_threads`, with a deliberate counter re-baseline only if the object-bytes
trigger changes the counts. Judge on wall time as well as GC time: mutator locality regressions
are possible.

**Exit:** minor pause and wall time improved at 2, 4 and 8 threads. No regression at 1 thread
beyond the documented CAS tax.

---

### Phase 7 — Concurrent tenuring

**Why:** promotion (~75–80 % of the minor pause) leaves the pause entirely. The minor pause shrinks
to roots plus the first copy.

(7a, the frozen published heap, is now phase 4, a precondition of 7b and 7c.)

#### 7b — Eden plus rotating survivor regions, promotion still synchronous

- Layout change: eden plus three survivor regions, forwarding held off-header.
- Recorded slots and roots.
- Split-header body sweeping keyed to the owning region.
- Validators re-specified as "points into a retained region".
- Deployable on its own. Expected to reduce nursery memory.

#### 7c — Promotion on a collector thread

- The collector promotes the previous survivor region during the mutator epoch and heals the
  recorded slots.
- The mutator waits or helps if the collector is late.
- Major GCs start only when the collector is drained.

**Invariants:** FORBID_HEAP_004 (no concurrent header forwarding); HEAP_006/HEAP_030 reconciled.

**Exit:** the minor pause is measured against phase 0's root-scan figure, the retention bound is
confirmed (three survivor regions), and interference is within the phase 0 co-runner estimate.

---

### Phase 8 — Massive-workload items (selected by data)

These items are independent of each other. Each becomes its own work plan only when phase 0's or a
later phase's measurements show it matters at the target scale:

| Item | Build it if… | Report |
|---|---|---|
| Generational stack scanning (return-address watermark) | stack-walk time is significant | §3.3 |
| Incremental / concurrent t0 prepare (`clearForMark` O(heap/64), sweep drain) and handoff tail | 05c E7: the remaining heap-size-dependent in-cycle pause work | 05c P§10.9 |
| CellStore dirty-chunk root scanning | the external-scanner time grows with the store | — |
| Concurrent mark-bitmap clearing / double-buffered bitmaps | always at TB scale, since the bitmap is heap/64 | — |
| Concurrent evacuation of sparse old-gen pages (fragmentation, RSS) | long-running huge heaps need it | §8.1 |
| Pipelined nursery regions (design B) | the budget allows +256–512 MB and phase 7's residual pause still matters | §7.4 |
| Parallel sweep in the major pause, or a block hand-over sweeper | a mixed-block sweep residual remains after phase 2 | §6.2 |
| Idle-time GC for Platform.worker programs | — | §8.3 |

---

## 4. Tracking

| Phase | Work plan | Status | Outcome / facts for later phases |
|---|---|---|---|
| 0 Measure and fix | `plans/threaded-gc-00-measure-and-fix.md` | **DONE (2026-09-24)**, snapshot `keep-T00`, `bin/eco-opt-prev` = `eco-optT00`; results in `benchmarks/threaded-gc-00-baseline.md` | (1) Promotion ≈ 67 % of the minor pause; the old-gen allocator alone ≈ 36 % (32 ns/promotion). (2) Worst pauses: majors 1.3–2.7 s, then post-major lazy-sweep bursts 0.4–0.9 s. MMU = 0 up to 2 s windows. (3) Stack walk negligible (0.1 ms/minor); CellStore root scan up to 8.6 ms/pause. (4) A memory-heavy co-runner made the mutator ~8 % FASTER, a spin-only one 2.4 % slower: interference is not a blocker. (5) New lead: 4.9 M page faults inside minors, ≈ one per promoted 4 KiB. (6) Judge GC counters against a SAME-SESSION control; object counts depend on launch args/env. (7) P1: no violations seen (E2E census 0; validator self-compile 72 % of minors clean); a full-scale census count is still owed. |
| 1 Stable metadata | `plans/threaded-gc-01-stable-metadata.md` | **DONE (2026-09-24)**, snapshot `keep-TG1`, `bin/eco-opt-prev` = `eco-optTG1f`; loop entry TG1 in `benchmarks/gc-opt-loop.md` | (1) Blocks have stable `BlockId`s; every metadata table is VA-reserved (`ReservedArray`) and **never moves**; iteration ORDER is separate and must stay vector-identical (counters depend on it). Only `sweep_buffer_index_`/`fixup_buffer_index_` are positions (HEAP_048). (2) Page index keyed from `heap_base`, owners stored as id+1, never rebuilt; lookups must bounds-check the committed slot count (HEAP_049). (3) Mark bits: fixed per-id arena slot (`arena + id*stride`), 2 MiB-aligned/granule for THP; the startMark bulk clear stays (HEAP_050). Phase 5b's `fetch_or` goes on `mark_.slot(id)`. (4) Marker writes only a `LiveBytesAccumulator`, merged at `finalizeMetaAfterMark`; phase 5b = one per marker (HEAP_051). (5) Free-list back-links are addresses, no block-count limit (HEAP_052); GC state is per-heap, not TLS (HEAP_053). (6) The mark loop is **alignment-sensitive**: `-falign-loops=64` is pinned for `OldGenSpace.cpp`; a few-% mark swing with identical instructions means check the loop address first. (7) The validator self-compile is dropped as a gate (too slow); validate = unit tests + E2E + GC-pressure stress. Validate stress has 5 PRE-EXISTING `JsonRoundtrip*` aborts. (8) 8 TB of metadata reserves ~130 GB VA and costs +64 KiB RSS. |
| 2 Bitmap allocation | `plans/threaded-gc-02-bitmap-allocation.md` | **DONE (2026-09-25)**, snapshot `keep-TG2`, `bin/eco-opt-prev` = `eco-optTG2`; loop entry TG2 in `benchmarks/gc-opt-loop.md` | (1) **Cursor ownership:** per size class ONE `AllocCursor` owns at most one uniform block (`BlockInfo.alloc_state` Current); partially free blocks wait on `partial_[cls]` in position order; cursors/queues reset at `startMark`; a block is `detachFromAllocation`ed before release/large-flip/demotion/compaction. Phase 6 = one cursor per thread per class (HEAP_054). (2) **A uniform block's mark bitmap IS its allocation map** (bit set ⇔ allocated); uniform blocks are never swept and are **not header-parsable** (free cells have stale or no headers) — any new walker must skip clear cell-start bits (HEAP_021/024/027). Phase 5b's parallel marker sets the same bits. (3) `live_bytes` is exact for uniform blocks (popcount × cell, V8); cursors carry `pending_live` folded by `syncCursorLiveBytes` before any reader. (4) **Remaining sweep cost** is the mixed-block gap sweep (reads only live headers, HEAP_055): 3.7 GB covered in-pause, est 0.24 s over the run, worst 63 ms in one pause (was 820 ms). Promotion allocation is 16.1 ns (was 32.0) — the hit path tests the next cell's bit; no integer `div` anywhere on the path. (5) **`demote_live_fraction` lever, default 0.3** (E1: 0.0 pins the peak and has the lowest pauses at +1–3 majors; 0.75 brings back 0.6 s pauses). (6) **The garbage-fraction major trigger is chaotic** (legacy: 4–7 majors, 8.8–16.2 GB peak across gf 0.65–0.75): phase 2 adds the **LiveBudget** trigger, k = 4.5 × min(L_i, 1.5·L_{i−1}) (HEAP_057). Judge any trigger/allocator change on a gf sweep, never one run. (7) A major now leaves nothing to sweep when there are no mixed blocks, so the GC is Idle at once and **compaction becomes reachable right after a major** — it exposed a latent HEAP_048 fixup-cursor false positive (fixed). |
| 3 Helper-thread infra | `plans/threaded-gc-03-helper-threads.md` | **DONE (2026-09-25)**, snapshot `keep-TG3`, `bin/eco-opt-prev` = `eco-optTG3`; loop entry TG3 in `benchmarks/gc-opt-loop.md` | (1) **Pool API:** `GCHelperPool` (one per process; std-only, no allocator includes; TSan harness `test/gc-helper-tsan` built with g++, since clang 14 here has no TSan runtime). Jobs are intrusive `HelperJob`s: post / wait / drain; a job's state is read only to wait (GC_DET_001). (2) **Sync point:** `ThreadLocalHeap` PauseEndHook → `Allocator::onGCPauseEnd(heap, had_major)` at the end of the OUTERMOST pause; `sync_epoch_` / `major_epoch_` are the only clocks policy may use. (3) **Modes:** `ECO_GC_THREAD` 0/1/2 (one character: the environment is a program input); `ECO_GC_HELPER_JITTER_US` is the determinism probe. Gate recipe: counters must be identical in 0, 1, 2 and 2+jitter (they were, across 11 runs). (4) **First users, worth −8.5 s wall, −7.2 s GC:** deferred decommit with a delay counted in MAJORS (a pause-end delay was the wrong unit); commit-ahead 128 MiB + `MADV_POPULATE_WRITE`. In-minor faults 4.71 M → 29 k. (5) **Fork safety:** `pthread_atfork` (prepare drains; the child re-constructs mutex and condvars and restarts workers lazily). Every later phase's pool state must be added to `atforkChild`. (6) **Interference** of 1 helper was negative (−3.1 s), and pinning did nothing: the L3 is not a blocker at this job volume (1.9 s of helper CPU per run). |
| 4 Frozen published heap (P1) | `plans/threaded-gc-04-frozen-published-heap.md` | **DONE (2026-09-25)**, snapshot `keep-TG4`, `bin/eco-opt-prev` = `eco-optTG4`; loop entry TG4 | (1) **P1 holds at full scale:** census build (`-DECO_P1_CENSUS=ON`, `ECO_P1_CENSUS=1`) on the self-compile found 0 violations in 744 M nursery-survivor, 265 M promoted-object (sample 16) and 18.8 M write-site checks; E2E + stress clean in abort mode. (2) **Validate builds now enforce P1** (`ECO_P1_CENSUS` defaults to 2 there): every later phase's validate gates re-check it. Tests that write on purpose force mode 1. (3) Two hazards were real and are fixed: chunk-chain backings (now builders, bounded to ¼ nursery by `chunkChainFits`), and **born-old pointer objects** (HEAP_061: minor GCs scan them as roots until their children are old; compaction is skipped while any is pending). (4) **For 5a:** builder objects that exist at t0 are written after t0 by design, so the snapshot needs a builder-root/grey path; born-old pending objects are the only old→young holders and must be snapshot roots too (**withdrawn by 4b:** there are none). (5) Out of scope, recorded: the 5 validate-stress `JsonRoundtrip*` aborts are a stale closure in `eco_apply_closure_eval`, not P1 (**fixed in 4b**). |
| 4b Young large objects | `plans/threaded-gc-04b-young-large-objects.md` | **DONE (2026-09-26)**, snapshot `keep-TG4b`, `bin/eco-opt-prev` = `eco-optTG4b`; loop entry TG4b | (1) **HEAP_005 is strict again; HEAP_061 retired; HEAP_062 in.** A large pointer-bearing object goes to the nursery up to min(⅛ nursery, 128 KiB) (E1: an 8 MB array in the nursery is 1.9× slower; YLOS wins from ~800 KB and loses at 80 KB), else to the young large-object space: a pinned old-gen cell that is young — reached through a bounding box + index lookup in the copiers, scanned in place, promoted in place, freed at minor end. JSON arrays over 1,021 elements are chunked. (2) **The self-compile makes zero large pointer allocations**: wall/RSS flat, out.mlir identical, counters identical except promoted +241/copied +1,880 (unattributed; same-source relowering is not bit-exact either). (3) **Validate stress is 101/101 for the first time:** the `JsonRoundtrip*` aborts were two stale-copy bugs (`invokeSaturatedTyped`'s by-value `closure_bits`, `runDecoder`'s `jvalEnc`); `Json.Decode.array` built an invalid Array above 1,056 elements. (4) **For 5a:** YLOS objects are part of the young generation at t0 and are handled with the nursery; the TG4 note about born-old snapshot roots is withdrawn. |
| 5a Incremental mark | `plans/threaded-gc-05a-incremental-marking.md` | **DONE (2026-09-26), DEFAULT-ON T = 32**, snapshot `keep-TG5a`, `bin/eco-opt-prev` = `eco-optTG5a`; loop entry TG5a | (1) **Self-compile worst pause 4.83 s -> 336 ms** (triple medians; slice p99 306 ms, t0 <= 136 ms, handoff <= 154 ms), old-gen peak +1.6 %, wall flat, majors 7 = 7; T = 0 reproduces every STW decision counter (E0). (2) **t0 = the trigger's minor end**: the old-gen targets of every root/off-heap store AND of every young object (survivor prefix + YLOS) are greyed in that pause, so a slice never touches a young object or a root (IM3; HEAP_063, HEAP_SNAPSHOT_002). Builders need nothing more: the young walk covers them. (3) **A uniform bitmap is only an allocation map outside a cycle**: mid-cycle the cursor serves post-t0 virgin blocks only (retention cost measured, Plan B not needed). (4) **Pacing that works**: front-loaded over the first ceil(T/2) slices with doubling on overrun; the planned spread-over-T form left 1-2 s closing slices. **Allocate-black bytes must be excluded from the trigger baseline** or each cycle's promotions enlarge the next budget (5-6 majors vs 7). (5) **Fixed schedule**: handoff at minor t0 + T + 1 regardless of progress; 5b/5c inherit it for GC_DET_001 (plan P§9 contract). (6) The trigger is still chaotic: the gf sweep swings the peak +/-30 % in BOTH arms (sweep medians equal); heap-relative trigger pacing is 5c's job. (7) The handoff tail (release of freed blocks) is now the next-largest in-cycle pause after slices; a late-trigger cycle in round 1 spent 4.5 s releasing 8 GB, so make the tail incremental if it resurfaces. |
| 5b Parallel mark | `plans/threaded-gc-05b-parallel-marking.md` | **DONE (2026-09-26), DEFAULT-ON: auto markers (cap 16), T = 32**, snapshot `keep-TG5b`, `bin/eco-opt-prev` = `eco-optTG5b`; loop entry TG5b | (1) **In-pause slice mark 9.9 s -> 1.3 s** (16 markers); the **worst pause is now the minor-GC floor (~189 ms)** from 4 markers on; wall -6 to -8 s; collector CPU 19 s at 16 markers. (2) **Exact tickets**: every counter, mark units included, is bit-identical at every marker count and under jitter (GC_DET_001). (3) **Private stacks were decisive**: Chase-Lev push/take per entry (a seq_cst fence per pop) plus an unconditional fetch_or gave NO gain at 2 markers; a private owner stack publishing its oldest half when the deque is empty, plus test-before-fetch_or, fixed it. (4) **Termination must be one CAS on (active, epoch, done)**: separate loads let a reactivating marker grab the whole budget between the decider's two reads (found by a determinism test under full-suite load; the TSan harness now has a chain-graph termination stress that fails on the old code). (5) The t0 snapshot must not chunk young arrays. (6) Smaller T is not worth it: T = 8/16 at 16 markers raise the peak 12 % with no pause gain. (7) For 5c: markers never read young objects or roots after t0; the validate-only YLOS index reads (IM3, HEAP_BUILDER_001) are safe only because the mutator is paused. |
| 5c Concurrent mark | `plans/threaded-gc-05c-concurrent-marking.md` | **DONE (2026-09-27), DEFAULT-ON: `conc_mark` = 2, auto background markers (cap 4), priority 0, assist lag 8; Headroom trigger (margin 1.5) and paced LiveBudget default-on**, snapshot `keep-TG5c`, `bin/eco-opt-prev` = `eco-optTG5c`; loop entry TG5c | (1) **Marking left the pauses:** at T = 32 the background finishes by T/4 in 6 of 7 cycles; kind-4 pauses 224 → 0, all-pause p99 127.5 → 116.3 ms, wall −1.0 s, collector CPU 19.7 → 12.6 s, interference +0.1 % mutator CPU. The worst pause is still the minor floor (~190 ms). (2) **Every decision counter and every cycle's units are identical** at `conc_mark` 0 / 1 / 2, B = 1…8 and under jitter (GC_DET_001); mode 0 reproduces TG5b exactly. (3) **Priority is one-way and low priority is harmful:** under 24 spinning co-runners, SCHED_IDLE markers made a 9.5 s closing pause and nice 19 made 1.0 s; priority 0 had 224 ms (mode 0: 262 ms). Background and foreground are separate thread sets. (4) **Heap-size independence holds while B markers × the cycle's mutator time cover the mark work** (E7: 0 ms in-pause mark at 1 and 4 GB with a 150 ms minor period; at 20 ms, assists take over at 4 GB). The t0 prepare (`clearForMark`) and the handoff tail still grow with the heap (phase 8). (5) **Trigger pacing:** P̂ (integer EWMA of old-gen bytes per minor) × H_c = T + 1. The paced LiveBudget cut the gf-sweep peak spread 44.5 % → 6.4 % (max RSS 9.6–10.2 GB vs 9.8–14.3 GB) for +1–2 majors that cost no pause time: **default-on** (the plan's "+1 major" rule rejected it; overridden after review). The garbage backstop was rejected (36 % spread). The Headroom trigger ships (at an 11 GB cap: peak 94.4 % → 81.5 % of the cap). T stays 32 (T = 8/16: +12 % peak). (6) For phases 6/7: the P§3.6 audit table is the template. Allocate-black on pre-t0 bytes is atomic; cursors must own only post-t0 blocks (IM13). Retire deque arrays only when nothing runs. `gc-heap-tsan` runs the real allocator under TSan. (7) The master plan said "on the phase 3 pool": deliberately a per-heap `GCBackgroundGang` instead (seconds-long episodes would block decommit jobs, and priority cannot be restored). |
| 6 Parallel STW minor | `plans/threaded-gc-06-parallel-minor.md` | **DONE (2026-09-27), DEFAULT-ON: auto workers, cap 8** (retention gate E7 failed and was overridden after review), snapshot `keep-TG6`, `bin/eco-opt-prev` = `eco-optTG6d`; loop entry TG6. Default self-compile: wall 162.6 → 123.3 s, minor GC 46.8 → 12.3 s, minor p99 111.9 → 25.4 ms, max RSS 12.4 GB | (1) **At N = 16** (triples): wall 160.9 → 121.9 s, minor GC 46.8 → 9.5 s, minor p99 111.9 → 20.2 ms, worst minor 177.5 → 74.2 ms, collector CPU 89.5 s; per-minor object counters identical at every N and under jitter (E1). (2) **Retention gate failed:** gf-sweep median old-gen peak +8.8 % (limit +3 %), max RSS +8.6 %. The cause is **promotion order**, not concurrency: a one-worker parallel engine shows the same peak. Depth-first promotion clusters lifetimes into blocks worse than Cheney's breadth-first order, the majors recover less, the garbage-fraction denominator stays higher, and the chaotic trigger amplifies it. FIFO grey order halves it at N = 1 but not at 16. (3) Design as built: claim-then-publish header words; LABs + Tag_Free fillers with object-byte nursery accounting (HEAP_068); per-class **shared blocks claimed in adaptive chunks** (per-worker blocks inflated committed and moved the first major from minor 91 to 165); a spin lock for ladder rungs 2–8 with batched free-list pops; idle workers wake only for stealable work (counting private stacks made minors 5–40× slower on long chains). (4) For 7b/7c: the promotion buffers (`PromoCtx`) and HEAP_068 carry over; the claim protocol does not. **Promotion order is a retention input**: any copier that changes it must pass a gf-sweep retention gate. |
| 7b Survivor regions | — | not started | |
| 7c Concurrent tenuring | — | not started | |
| 8 Massive-workload items | — | not started | |

## 5. Expected pause trajectory

These are targets, not measurements. Update the table as each phase lands.

| After phase | Worst pause | Typical minor pause |
|---|---|---|
| today | ~1.3 s (major mark); 986 ms (sweep burst) | ~31 ms |
| 2 | **measured:** 4.72 s (major, one extra LiveBudget major at a larger live set; was 2.64 s); **minor-only max 178 ms** (was 976 ms), no sweep burst | p50 5.4 ms, p99 142 ms (was 5.9 / 153 ms) |
| 3 | **measured:** last major 5.16 s (triple median; was 5.34 s); minor-only max 176 ms, no in-minor page faults (4.7 M → 29 k) | p50 4.9 ms, p99 114 ms (was 5.3 / 142 ms) |
| 4 | **measured:** unchanged (correctness phase; wall flat) | unchanged |
| 5a | **measured:** 336 ms worst (minor + slice, T = 32; was 4.83 s); t0 <= 136 ms, handoff <= 154 ms | minor pause + one slice (slice p99 306 ms) |
| 5b | **measured:** 189 ms = the minor-pause floor (16 markers; slice mark max 30 ms; t0 <= 24 ms; handoff <= 102 ms); incremental off + 16 markers: 735 ms (was 4.64 s) | minor pause + slice (slice p99 141 ms) |
| 5c | **measured:** 190 ms = the minor-pause floor (unchanged); kind-4 pauses 224 → 0; all-pause p99 127.5 → 116.3 ms; t0 ≤ 139 ms, handoff ≤ 164 ms (both including the minor); in-pause mark 0 at 1 and 4 GB live (E7, 150 ms minors) | minor pause only (p99 115 ms) |
| 6 | **measured (default, N = 8):** 116.5 ms worst minor (triple median; was 177.5 ms; 74 ms at N = 16); minor p99 25.4 ms (was 111.9); wall −39 s; old-gen peak +24 % (retention gate overridden) | p50 2.1 ms (was 4.8) |
| 7c | roots + first copy (sized by phase 0) | roots + first copy |
