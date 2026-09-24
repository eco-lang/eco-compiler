# Threaded GC — master plan (outline)

**Status:** OUTLINE (2026-09-24). No phase has a work plan yet.

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
  - the heap validator on the **self-compile** as well as E2E;
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
  `ECO_HEAP_VALIDATE` check that re-derives it, exercised on the self-compile.

## 3. Phases

### Dependency graph

| Phase | Depends on | Why |
|---|---|---|
| 0 | — | baseline data |
| 1 | 0 | a neutral refactor judged against the phase 0 baseline |
| 2 | 1 | builds on stable block ids and the in-place mark-bit arena |
| 3 | 1 | per-heap state instead of TLS; metadata that is safe to share |
| 4 | 3 | helper pool |
| 5a | 1 (and 0 for pause data) | snapshot protocol; single-threaded |
| 5b | 3, 4, 5a | collector threads; parallel-safe mark bits and assist; the snapshot protocol |
| 6 | 2, 3 | thread-safe promotion destination; helper pool |
| 7a | 0 | the census of kernel writes into already-survived objects |
| 7b | 2, 7a | promotion buffers; the frozen-heap invariant |
| 7c | 3, 6, 7b | collector thread; parallel promotion machinery; survivor regions |
| 8 | per item | gated by measurements |

Phase 6 may be pulled ahead of phase 5 if wall time becomes the pressing need. Phase 7a can run in
parallel with anything after phase 0.

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
- Decide the fate of `demoteMostlyDeadUniformBlocks`.

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

### Phase 4 — Parallel stop-the-world marking

**Why:** it cuts the largest pause (~1.3 s → ~0.4 s at 4 threads) at low risk, and it builds the
atomic mark bits, work-stealing deques and termination detection that phase 5b reuses.

**Scope:**
- Atomic mark test-and-set.
- Chase–Lev deques.
- Two-phase termination.
- Large-array chunking.
- A per-thread prefetch ring.
- Deterministic merge of per-thread accounting.

See report §5.8.

**Deploy:** behind `gc_threads`, where `gc_threads=1` is the reference. Counters are
bit-identical.

**Exit:** the major-pause reduction is confirmed on the major-GC event log with per-collection
pairing.

---

### Phase 5 — Concurrent marking

**Why:** it is the only old-gen design whose pause does not grow with heap size (goal 2).

#### 5a — Incremental marking on the mutator thread (snapshot protocol)

- Snapshot at a minor-GC end:
  - roots;
  - off-heap stores (CellStore cells and trail, MVar, scheduler queues);
  - the nursery survivors, via promote-all or a grey buffer (report §5.2).
- Log old-gen allocations so they are allocated black.
- Defer `freeLargeBodyCell` while marking.
- Emergency majors join the running cycle.
- Mark slices run at each minor-GC end; the handoff runs today's post-mark tail.
- Validator: "everything reachable at handoff is marked or allocated after t0".
- Deployable on its own: it spreads the major pause across minor pauses, and it is
  deterministic.

#### 5b — Marking moves to collector threads

- Concurrent mark slices on the phase 3 pool, parallel across markers using phase 4's machinery.
- Heap-relative pacing: the trigger comes from promotion rate × predicted mark time.
- Mark assist when the collector is late.
- The trigger margin is validated at both the 15 GB and the 4 GB budget.

**Invariants:** HEAP_SNAPSHOT_002 (mutable roots are off-heap and snapshotted); HEAP_026
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

#### 7a — Frozen published heap (P1)

- Adopt HEAP_SNAPSHOT_001: no writes into an object that has survived a GC unless it is flagged
  `builder`.
- Fix or `builder`-flag every kernel path the phase 0 census found.
- Enforce it with a validator tripwire.
- Adopt FORBID_HEAP_005 (no identity-negative comparisons).
- Ships as correctness hardening even if 7b and 7c never happen.

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
| 1 Stable metadata | — | not started | |
| 2 Bitmap allocation | — | not started | |
| 3 Helper-thread infra | — | not started | |
| 4 Parallel STW mark | — | not started | |
| 5a Incremental mark | — | not started | |
| 5b Concurrent mark | — | not started | |
| 6 Parallel STW minor | — | not started | |
| 7a Frozen published heap | — | not started | |
| 7b Survivor regions | — | not started | |
| 7c Concurrent tenuring | — | not started | |
| 8 Massive-workload items | — | not started | |

## 5. Expected pause trajectory

These are targets, not measurements. Update the table as each phase lands.

| After phase | Worst pause | Typical minor pause |
|---|---|---|
| today | ~1.3 s (major mark); 986 ms (sweep burst) | ~31 ms |
| 2 | ~1.3 s (major mark) | ~31 ms |
| 4 | ~0.4 s (major, 4 threads) | ~31 ms |
| 5b | ~50 ms (root snapshot) | ~31 ms |
| 6 | ~50 ms | ~12 ms |
| 7c | roots + first copy (sized by phase 0) | roots + first copy |
