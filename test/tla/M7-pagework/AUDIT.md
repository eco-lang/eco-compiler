# M7 — audit log

Dated entries, newest last. Each records what was checked against which tree, the verdicts, and
every change to the model. A canary re-audit (parent plan §7.4) adds an entry here quoting the new
hash prefix. The canary is not built yet.

## 2026-09-28 — first implementation

**Tree:** 2026-09-28, post-7c (the tree the plan's adversarial review used). **Tools:** the dev
image: tla2tools 1.8.0 (TLC 2026.09.25 rev 8f4bc8b). **Machine:** 12 cores shared with six other
agents (load average 20–26 during these runs), so the times are rough.

### Results

Quick tier (`tla-check`), 18 rows, `run_models.py --model M7 --jobs 2 --workers 2
--java-opts=-Xmx3g`: 18/18 as expected in 20 s. The state counts are TLC's distinct states:

| Configuration | Module | Expected | Result | States | Time |
|---|---|---|---|---|---|
| `pw_basic` (3 extents, 2 slots, 1 worker, 5 operations) | PageWork | pass | pass: 7 invariants, `MutatorFinishes` | 26,496 | 4 s |
| `pw_two_workers` (as `pw_basic`, 2 workers) | PageWork | pass | pass | 54,298 | 7 s |
| `lock_order` (members `mut`, `g1`) | LockOrder | pass | pass: no deadlock, `AllFinish` | 206 | 1 s |
| `lock_order_3` (members `mut`, `g1`, `g2`) | LockOrder | pass | pass | 468 | 2 s |
| `lock_order_stall` | LockOrder | witness `MODEL_M7_StallWitness` | as expected | 74 | 2 s |
| 13 mutants (`mutants/*.cfg`) | both | each its target | each as expected | 48 – 4,296 (at the stop; it varies with the worker interleaving) | 1–3 s each |

Deep tier (`tla-check-deep`), run once each with `nice -n 10` and 4 workers (`pw_deep` at `-Xmx6g`;
`pw_deep_liveness` under the machine-wide deep lock at `-Xmx5g`):

| Configuration | Expected | Result | States | Time |
|---|---|---|---|---|
| `pw_deep` (4 extents, 3 slots, 2 workers, 7 operations; invariants) | pass | pass: 7 invariants (depth 49) | 25,499,543 | 11 min 52 s |
| `pw_deep_liveness` (as `pw_deep` at 5 operations; `MutatorFinishes`) | pass | pass (depth 43) | 3,957,361 | 6 min 18 s |

Measured growth at the deep scope (invariants only): 4 operations 665,232 states (17 s, 2
workers), 5 operations 3,957,361 (71 s, 2 workers), 7 operations 25,499,543 (`pw_deep`). The
liveness check costs about five times the safety run at the same scope (5 operations: 71 s
without `MutatorFinishes`, 6 min 18 s with it, on twice the workers).

### Counterexamples

Every counterexample was read, to check that it is the intended story and not another path to
the same invariant. The shortest (TLC breadth-first, one worker), in caller operations:

| Mutant | Target | Shortest behaviour |
|---|---|---|
| `reuse_no_wait` | `HEAP_059` | 13 states, 3 operations: release 1; sync ages {1}, a Discard {1} is posted; reuse 1 finds it Posted and does not wait; the heap owns 1; the worker starts the Discard with 1 still to `madvise`. The plan's §2.2 timeline without step 3's wait |
| `release_no_await_populate` | `HEAP_060` | 15 states, 4 operations: sync opens window {3}, a Populate is posted; fresh acquire of 3; release 3 without waiting for the Populate; sync ages {3}, a Discard is posted; the worker starts the Discard while the Populate is still Posted. **This order needs a non-FIFO pool** (M6's contract allows it; the code's one worker is FIFO). The FIFO-feasible race is reachable too, within the same 4 operations with two workers (16 states): `w1` dequeues the Populate first, as FIFO would, then `w2` the Discard, and both bodies run over extent 3. It is unreachable in the base (reachability check below) |
| `release_no_await_populate_2w` | `HEAP_060` | the same 15-state behaviour |
| `skip_posted_extents` | `DetChoice` | 13 states, 4 operations: release 1; release 2; sync ages {1}; reuse: the mutant skips the Posted 1 and takes 2, while the job-blind ghost takes 1 |
| `reuse_keeps_pending` | `V1` | 6 states, 2 operations: release 1; reuse 1, whose cancel leaves it Pending; at `M_Touch` the extent is still tracked |
| `reuse_bypass` | `TrackedInFree` | 7 states, 2 operations: release 1; a reuse route that never calls `onReuse` hands 1 to the heap; 1 is Pending and no longer in the free list |
| `age_stale_entry` | `NoOwnedPosted` | 11 states, 3 operations: release 1; reuse 1 cancels its discard (its `pending_order_` entry goes stale); sync ages the stale entry and posts a Discard of 1, which the heap owns |
| `takeslot_no_wait` | `PostIdle` | 18 states, 4 operations (one slot, no window): release 1; release 2; sync ages {1} into the slot; sync ages {2}: `takeSlot` finds no Idle slot and hands back the busy one, and the post rewrites a Posted job |
| `job_never_done` | `MutatorFinishes` | a lasso: release 1; sync ages {1}; the worker runs the Discard and never stores Done; reuse 1 waits for ever |
| `tm_then_promo` | deadlock | 8 states: `mut` takes `thread_mutex_` then wants `promo_mu_`; `g1` takes `promo_mu_` then wants `thread_mutex_` |
| `worker_takes_tm` | deadlock | 8 states: the worker starts the job; `mut` takes `promo_mu_` and `thread_mutex_`, meets the job and blocks in `wait`; the job body wants `thread_mutex_` |
| `collector_takes_tm` | deadlock | 13 states: `mut` finishes its promotion, then `tenureTeardown` holds `thread_mutex_` and joins the collector, which wants `thread_mutex_`; `g1` then blocks at `P_Tm` |
| `lost_wakeup` | `AllFinish` | a lasso: `mut` takes both locks, meets the job and sees it not Done; the worker stores Done and notifies; `mut` then blocks, for ever, holding `promo_mu_` and `thread_mutex_`; `g1` starves at `P_Promo` |
| witness `lock_order_stall` | `MODEL_M7_StallWitness` | 6 states: `mut` takes `promo_mu_`, then `thread_mutex_`, meets the Posted job and blocks in `wait`; `g1` waits at `P_Promo`. The plan's §2.4 timeline, steps 1–3 |

Two mutants first produced counterexamples through the model's free window choice: two windows
over the same fresh extent, which `topUpWindow` never posts (each window starts at
`max(window_end_, bump)`, `PageWork.cpp:214-215`). That is the parent plan's trap 11 (an
over-approximation manufacturing a mutant's failure). `takeslot_no_wait` now runs with one slot
and no window, and `job_never_done` with no window, so both fail on paths the code can take.

### Reachability checks (the passes are not vacuous)

A scratch module extending `PageWork` (not committed) stated each of these as "never happens" and
TLC violated every one in `pw_basic`'s constants: a release waiting on an in-flight populate; a
release with two overlapping populates to wait for; a reuse waiting on a Posted discard; a reuse
waiting while that discard's body runs; `takeSlot` waiting with every slot busy; a cancel; a
Discard job of two extents; a Done discard reaped at a sync point; a reuse finding its job Done
but not yet reaped; a populate running over a heap-owned extent; the caller finishing all its
operations. With two workers, "a Discard body and a Populate body over the same extent run at
once" is reachable under `release_no_await_populate` and unreachable in the base.

### Changes from the plan's sketch (plan §4.6), and why

1. **Steps with no code counterpart removed** (A1, primer §4.2):
   - `M_Next`: `n := n + 1` moved into `M_Choose`, the loop's own step;
   - `M_SyncDone`: `batch` is cleared in `M_Window`, `win` in `M_PostP`;
   - `W_Loop` and `W_Done`: `W_Body` does one `madvise` per step and, when none is left, the
     Done store, then `goto W_Take`. The last `madvise` and the Done store stay separate steps,
     as in the code;
   - M7b's `P_First`: merged into `P_Promo` (the `tm_then_promo` branch takes `thread_mutex_`
     there instead).
2. **Dead-state hygiene:** `rsel` and `takenSlot` are reset when dead.
3. **New invariant `PostIdle`** (the post CAS, `GCHelperPool.cpp:153-156`): a job is written and
   posted only into an Idle slot. It is the model's check of the A3 argument that the caller
   never rewrites the fields of a job a worker is running. Mutant `takeslot_no_wait`.
4. **Mutants added** so that every invariant and property has one (rule A6). The plan had none
   for `V1`, `TrackedInFree`, `MutatorFinishes` or `AllFinish`:
   - `reuse_keeps_pending` → `V1`;
   - `reuse_bypass` → `TrackedInFree`: a reuse route that never calls `onReuse`, the premise of
     plan §2.5 ("every reuse funnels through `onReuse`");
   - `job_never_done` → `MutatorFinishes`: it breaks the PoolJob contract M7a consumes;
   - `lost_wakeup` → `AllFinish`: its configuration turns the deadlock check off, because the
     stranded waiter blocks every thread and the deadlock check would stop TLC first.
5. **The plan's two "to add" mutants are built:**
   - `age_stale_entry`: a ghost `stale`, written only under that mutant, so the other
     configurations' states are unchanged;
   - `collector_takes_tm`: a `Collector` process and the mutator's teardown (`T_Tm`, `T_Join`,
     `T_Rel`) are in **every** M7b configuration, not only in the mutant's: the edge
     `thread_mutex_` → background-gang join exists in the code, so `lock_order` checks it.
     `AllFinish` quantifies over every process, the collector included.
6. **`lock_order_3`** (three members) added to the quick tier: 468 states, and the three deadlock
   mutants still deadlock with three members.
7. **The deep configuration is split.** `pw_deep` checks the invariants at the plan's bounds
   (25.5 million states, 12 minutes); `pw_deep_liveness` checks `MutatorFinishes` at 5
   operations. A probe of the plan's single configuration (invariants and `MutatorFinishes` at 7
   operations) had reached only 2.4 million states after 8 minutes: TLC's liveness checking is
   periodic and runs over the whole behaviour graph (the runner cannot pass `-lncheck final`),
   and it costs about five times the safety run at the same scope.
8. **No `MC.tla`:** every constant is a `.cfg` literal.

### Where the code differs from the plan (the model follows the code)

- `postDiscardBatch` erases the batch's `pending_` entries **before** `takeSlot` may wait
  (`PageWork.cpp:258-259`, then `:191`), so during that wait the batch is tracked nowhere. The
  model keeps them `Pending` until `M_Post`. Nothing can observe the difference (the caller holds
  `thread_mutex_`; workers never read `pending_`), and the model is the more tracked of the two.
- `startVirginBlockW` (`OldGenSpace.cpp:1279-1281`) also reaches `ensureBagPageAvailable` →
  `acquireOldGenBlock` under `promo_mu_`. It runs only in a non-chunked (one-worker) promotion,
  so no other member can stall behind it. Not in the plan's census.
- `allocatePromotion`'s `per_alloc_sweep` slice (`OldGenSpace.cpp:1559-1563`) runs `lazySweep`
  **outside** `promo_mu_` (one-worker identity), so its tail path is not in the lock chain.
- Line drift: `lazySweep`'s tail completion is `OldGenSpace.cpp:5467-5476` (plan: 5466-5476);
  the in-loop one `:5246-5255`; `HelperJob::state` is `GCHelperPool.hpp:49`. The rest of the
  plan's §3 table matches.

### What the models show about the register (CR-007, CR-012, CR-014)

- **CR-007, the deadlock hypothesis: Not-a-bug.** `lock_order` and `lock_order_3` pass TLC's
  deadlock check and `AllFinish` with the whole lock graph (`promo_mu_` → `thread_mutex_` →
  {pool wait, the teardown's collector join}). The check has teeth: `tm_then_promo`,
  `worker_takes_tm` and `collector_takes_tm` each deadlock.
- **CR-007, the stall: reachable** (`lock_order_stall`, 6 states). A gang thread blocks in
  `pool.wait` holding `promo_mu_` and `thread_mutex_` while another member spins, then sleeps, on
  `promo_mu_`. How long and how often is a measurement (CR-006's `gc_thread_mode = 2` arm).
  `lost_wakeup` shows the stall would become permanent if the pool ever lost a wakeup (M6).
- **CR-007, the misattribution: confirmed by reading.** `callerInPause()` (`Allocator.cpp:1206-1208`)
  reads the thread-local `tl_heap_`, which only `setThreadHeap` writes, for heap threads; on a
  gang thread it is null, so `GCHelperPool::noteStall` counts the stall in
  `stall_outside_pause`, and `pageHookStall` (`Allocator.cpp:1176-1179`) finds no heap to add it
  to. Stats only.
- **CR-014's release route** is in the same chain (a populate instead of a discard), and M7b's job
  is generic, so the verdicts above cover it. M7a's release branch is caller-agnostic: a release
  on a gang thread under `promo_mu_` still waits for overlapping populates, so HEAP_059 and
  HEAP_060 hold on that route. CR-014's own suspicions (a release of a block a worker still
  refers to; the `live_bytes` and `large_body_index_` races) are the ReleaseContract, M4's.
- **CR-012 (multiple mutators): no change, but a scope result.** Every PageWork call holds the
  process-wide `thread_mutex_` for its whole duration, waits included, so the calls of every heap
  form one sequence, and M7a's one caller stands for all of them. So HEAP_059, HEAP_060, V1, V2
  and `PostIdle` hold for any number of heaps, whatever the process-wide clocks do (aging is a
  free choice). What CR-012 lists stays outside the model: the unlocked `old_gen_in_use_bytes_`
  reads, per-heap GC_DET_001, `validatePageWork`'s reads of other heaps, and
  `acquireOldGenRegion` re-mapping a window.

### Not done in this step

- Trace validation (plan §8, step 7): done on 2026-09-29 (next entry).
- The canary (`TLA-REGION` markers, `test/tla/manifest.txt`): the lines M7 needs are below.
- The weak-memory companion `w_pool_done` (A4).

### Canary lines this model needs (A9; not yet in `test/tla/manifest.txt`)

| Kind | Path | What | Why |
|---|---|---|---|
| file | `runtime/src/allocator/PageWork.cpp`, `PageWork.hpp` | whole files | M7a's subject |
| file | `runtime/src/allocator/GCHelperPool.cpp`, `GCHelperPool.hpp` | whole files (M6's pins; add M7) | `post`, `wait`, `workerLoop`, `HelperJob::state` |
| file | `runtime/src/allocator/MinorWork.hpp` | whole file (add M7) | `SpinMutex` |
| region | `Allocator.cpp` | `Allocator::acquireOldGenBlock`, `releaseOldGenBlock`, `acquireOldGenRegion`, `onGCPauseEnd`, `rebuildPageWork`, `cleanupThread`, `finishTenureForExit`, `callerInPause` | the callers, their locks, the config, the teardown edge, the misattribution |
| region | `OldGenSpace.cpp` | `ensureBagPageAvailable`, `startVirginBlockShared`, `startVirginBlockW`, `ladderFrom2W`, `allocatePromotion` (both lock sections and the `per_alloc_sweep` slice), `allocateFromBagPage`'s sweep and acquire, `allocateLargeBlock`'s acquire, `sweepOnDemandAllocate`, `panicSweepAndRetryAllocation`, `lazySweep`'s two completion paths, `releaseBlockToAllocator`'s and `releaseUnassignedBlockToAllocator`'s release calls | every route into the chain (MAPPING.md §4) |
| region | `NurseryTenure.cpp` | `NurserySpace::tenureTeardown`, `runJobParallel`, the tenure engine's allocation (`allocatePromotion` / `grantAllocateShared`) | the collector join; the pause engine's promotion |
| census | `Allocator.cpp`, `GCHelperPool.cpp`, `OldGenTenure.cpp`, `NurseryTenure.cpp` | the concurrency regex | a new lock or atomic on these paths (the collector must never take an allocator lock) |
| grep | `runtime/src/allocator/` | `promo_mu_`, `thread_mutex_`, `acquireOldGenBlock(`, `releaseOldGenBlock(`, `stopAndJoin(`, `onReuse(`, `onRelease(`, `onFreshBump(`, `syncPoint(`, `old_gen_free_blocks_`, `setThreadHeap(` | new routes into PageWork or the chain |

## 2026-09-29 — trace validation (plan §8, step 7)

**Tree:** 2026-09-29. **Tools:** as before, plus the shared trace infrastructure
(`test/tla/trace/`, `test/tla/common/Trace*.tla`, `run_traces.py`).

### What was built

- **Hooks** (compiled out unless `-DECO_TLA_TRACE=1`): 17 `PW_TRACE` events in `PageWork.cpp`
  (`runJob`, `reapDone`, `awaitSlot`, `onRelease`, `onReuse`, `onFreshBump`, `postDiscardBatch`,
  `topUpWindow`, `syncPoint`), each stamped from one process-wide seq_cst counter; and one
  `nameThread("eco-gc", i)` in `GCHelperPool::workerLoop`. MAPPING.md §10 lists them.
- **Production compile unchanged:** preprocessed with `EcoRuntimeStatic`'s flags, `PageWork.cpp`
  has exactly 17 `((void)0)` (one per hook) and otherwise differs only by braces around
  `reapDone`'s `if` body; compiled from the preprocessed text, the old and new files give
  identical machine code (`objdump -d`). The `GCHelperPool.cpp` line vanishes in preprocessing.
  Both files compile warning-free with the production command.
- **Harness:** `test/gc-helper-tsan/harness.cpp`'s H2/H3 `script()` takes the extent count, seed,
  decommit delay and reuse percentage as optional parameters (the TSan run's defaults are
  unchanged), and a trace-build entry point `gc-helper-trace pagework ...`. The CMake target
  `gc-helper-trace` (no TSan) is in `test/gc-helper-tsan/CMakeLists.txt` under the project's
  `ECO_TLA_TRACE` option.
- **Spec:** `TracePageWork.tla` / `.cfg` / `.keep`, matched in order (`TraceInOrder`). Each matched
  step must also keep the model's invariants.

### Model changes, found while mapping events to steps (all three were found by reading the code for the event design, before any trace was rejected)

1. **`reapDone` is not atomic** (A1, primer §3.3). It reads each slot's state with its own
   acquire load (`PageWork.cpp:115-124`), so a slot that turns Done after the loop passed it stays
   unreaped. The model's `ReapAllDone` reaped every Done slot in one step, so a real run in which
   a job finished mid-loop (two workers) would have been rejected. Now `ReapSomeDone`: any subset
   of the slots Done at the step's instant, which covers every outcome of the loop.
2. **Discard bodies run in batch order** (release order), not by extent id. `W_Body` took
   `CHOOSE x \in todo`, so every multi-extent discard whose batch was not in ascending order would
   have been rejected. Now any remaining extent.
3. **A populate is one content-neutral `madvise`:** it no longer has per-extent body steps (folded
   into its Done step); `HEAP_060` reads only whether it is in flight.

Also: the two slot scans are explicit minima (the code's index order), and the three free
choices are named (`ReapChoices`, `AgeChoices`, `WindowChoices`) so that the trace configuration
can narrow them to the logged value. Without that, TLC enumerates `SUBSET` of the fresh extents
at every window step (2^64 at 64 extents).

Re-checked: quick tier 18/18 as expected (`pw_basic` 22,518 states, `pw_two_workers` 40,224:
fewer than before, because the folded populate outweighs the reap subsets); every mutant still
fails with its target. Deep: `pw_deep` pass, 13,269,227 states in 1 min 20 s (4 workers, under
the deep lock); `pw_deep_liveness` pass, 1,941,065 states in 1 min 10 s.

### Results

`run_traces.py --model M7`, 15 rows (the harness runs once per distinct invocation; its rows share
the log). Three full runs, 15/15 as expected each time:

| Row (args after `pagework`) | Expected | Result | Events | States | TLC |
|---|---|---|---|---|---|
| `fake,1,0,300,16,4,1` (H2, 1 worker) | accept | accept | 829 | 1,237 | 2 s |
| `fake,2,300,300,16,4,2` (H2, 2 workers, jitter) | accept | accept | 853 | 1,288 | 2 s |
| `fake,4,0,400,16,4,3` (H2, 4 workers) | accept | accept | 1,062 | 1,591 | 2 s |
| `fake,2,5000,400,64,8,33,0,5` (H2, slow pool, slots full) | accept | accept | 1,101 | 1,871 | 5 s |
| `real,1,0,300,16,4,4` (H3) | accept | accept | 855 | 1,263 | 2 s |
| `real,2,300,300,16,4,5` (H3, 2 workers, jitter) | accept | accept | 827 | 1,245 | 2 s |
| `real,1,5000,400,64,8,34,0,5` (H3, slots full) | accept | accept | 1,190 | 2,158 | 5 s |
| `real,2,3000,400,64,8,35,1,10` (H3, 2 workers) | accept | accept | 1,234 | 1,850 | 6 s |
| 7 negative controls on `real,1,5000,400,64,8,34,0,5` | reject | reject | 1,189–1,190 | 1–226 | 1–2 s |

The event and state counts vary from run to run with the schedule; the numbers are the second
run's. Besides the registry, 17 more recorded runs (seeds 1–35 and 101–106; 1, 2 and 4 workers;
fake and real ops; 12 to 64 extents; delay 0, 1 and 2; up to 1,866 events) were all accepted, in
2–6 s each.

**Coverage** (counted from the merged logs): releases waiting on an overlapping populate (up to
11 per run), reuses cancelling a Pending discard, reuses waiting on a Posted one, reuses of an
already reaped extent, multi-extent discards, reaps at sync points and in `takeSlot`, windows (up
to 15), `takeSlot` waiting with all 8 slots busy (runs with delay 0 and 5 % reuses: with the
script's own 35 %, every reuse of a Posted extent waits on it and drains the FIFO pool, so at most
5–6 slots are ever busy), and a discard body running while another worker runs a populate (two
workers).

**Negative controls**, each rejected where intended:
- `drop:await:1`: the first wait is a release's wait for its overlapping populate (HEAP_060's
  wait); without it no behaviour gets past the release;
- `set:acq:1:st=3`: the code's tracking state must be the model's `pw`;
- `set:reaped:1:mask=255`: a reap of eight jobs at the first sync point, before any post;
- `drop:pend:1`: a release that never becomes Pending;
- `drop:start:1`: a job body with no dequeue;
- `set:sync:1:size=99`: the aged batch's size;
- `drop:jobdone:1`: the job the release waits on never becomes Done.

**End-to-end code mutants** (scratch copies of `PageWork.cpp` built into the harness; the tree is
unchanged):
- `onReuse` without `awaitSlot` for a Posted extent (the model's `reuse_no_wait`): H2's own fake
  discard aborts every run ("discard of an extent that is not free") before a log is written. The
  harness is the first line of defence for HEAP_059.
- `onReuse` of a Posted extent whose job is already Done forgets the entry without reaping the
  slot (harmless to the pages, but not the protocol): of three seeds, the one that took that path
  was rejected at its first occurrence (event 200: `acq st=2` followed by `reused` with no
  `await`); the two that never took it were accepted, correctly.

### Findings

- **No code defect.** Every recorded run of the real `PageWork` and `GCHelperPool` is a behaviour
  of M7a, with the invariants holding at every matched step at up to 64 extents, 8 slots and 4
  workers.
- **Model errors, fixed:** `reapDone`'s atomicity and the discard order (above). Neither changes a
  verdict: the model checks pass and every mutant fails as before.
- **What the trace cannot check:** the invariants are also checked on the trace, but they cannot
  fail there unless the model can reach a violation. The model's structure (the waits are steps
  that must be matched) is what rejects a deviating run, and the H2/H3 page checks catch HEAP_059
  first.

### Canary lines for the hooks' files (for `test/tla/manifest.txt`; not built yet)

```
file    -  runtime/src/allocator/PageWork.cpp      -  M7
file    -  runtime/src/allocator/PageWork.hpp      -  M7
census  -  runtime/src/allocator/PageWork.cpp      -  M7
file    -  runtime/src/allocator/GCHelperPool.cpp  -  M6,M7
file    -  runtime/src/allocator/GCHelperPool.hpp  -  M6,M7
file    -  test/gc-helper-tsan/harness.cpp         -  M7
```

`PageWork.cpp` needs a census pin now: its trace-only stamp counter (`std::atomic`, `fetch_add`)
is a concurrency line the census regex matches, even though it is compiled out.

## 2026-09-29 — canary baseline (GC_MODEL_001)

The canary (`test/tla/manifest.txt`, `tla-canary` in every build) was first pinned today: 44 pins
name this model (9 census, 6 file, 6 grep, 23 region); the list is in MAPPING.md's "Canary pins (A9)" block. This is the
baseline: the pinned code is the code this model was checked against today (after the trace hooks,
wave 3's fixes and the `TLA-REGION` markers landed). From now on, a pin that fires needs an entry
here quoting the new hash prefix before `check-tla-manifest.sh --update` accepts it.

## 2026-09-29 — ABA audit (a key reused after a free), and `pw_aba`

**Why:** CR-034 is an ABA defect (a structure remembered an object by address; the address was
freed and reused by a different object; a later lookup took the new object for the old). The
models use logical ids, so this class is a blind spot. This entry audits every PageWork /
free-extent structure that holds an address across a release and a reuse. **Tree:** 2026-09-29.
Line numbers: `PW` = `PageWork.cpp`, `AL` = `Allocator.cpp`.

### Verdicts (code reading)

| Structure | Filled | Consumed / cleared | Identity guard | Verdict |
|---|---|---|---|---|
| `pending_` (key: extent start) | `onRelease` `PW:168-170` | `onReuse` cancel `PW:181-188`; aging `PW:278-298`; `drainAll(true)` `PW:311-321` | one record per start: `onRelease` aborts on a tracked start (`PW:165-167`); every removal from `old_gen_free_blocks_` calls `onReuse` first (`AL:782-799`, the only removal); the free list never splits or coalesces (below) | safe |
| `pending_order_` (start, seq) | `PW:170` | aging `PW:278-283` | `seq` stamp: an entry whose record was cancelled and re-released at the same start is skipped (`PW:281`) | safe; the stamp is load-bearing (mutant `age_stale_entry`) |
| `posted_discard_` (start → slot) | `postDiscardBatch` `PW:231-234` | `reap` `PW:96-103` (via `awaitSlot` from `onReuse` `PW:190-192`, `takeSlot`, `reapDone`) | a reuse of a Posted start waits for and reaps its job before the extent is touched; `reap` also checks `Posted::slot` (`PW:100`) | safe; the slot check is redundant (probe below) |
| `PageJob::extents`, `lo`/`hi` | post (`PW:229`, `PW:260-261`) | `runJob` `PW:65-81`, `reap` | a posted discard's extents stay in the free list and a reuse waits (HEAP_059); a populate is above the bump and a release waits for an overlapping one (HEAP_060, `PW:151-157`) | safe (modelled) |
| `window_end_` | `topUpWindow` `PW:254` | `onFreshBump` `PW:206`, `topUpWindow` `PW:248` | only grows; new windows start at `max(window_end_, bump)`, above every released extent (the bump never moves back, `AL:927-937`) | safe |
| `epoch_`, `major_epoch_`, `next_release_seq_`, `next_seq_` | sync points; release; post | aging; "oldest slot" | 64-bit, monotone, never an identity except `seq` above | safe |
| `old_gen_free_blocks_` (start, size) | `releaseOldGenBlock` `AL:938` | `acquireOldGenBlock` first fit `AL:782-793`; `reset` `AL:1083` | entries come from releases of disjoint owned blocks; an acquire takes a whole entry (no split, `AL:780-793`) and a release appends (no coalesce, `AL:938`), so a start names exactly one extent for its whole free-list life, and V2a (`AL:1318-1327`) checks the record and the entry agree in size | safe |
| `validatePageWork`'s `used` (`AL:1307`) | per call | per call | rebuilt under `thread_mutex_` each call | safe (its unlocked reads of other heaps are CR-012) |

`Allocator::reset` (`AL:1037-1052`) drains every job and discards every Pending extent before the
free list is cleared (`AL:1083`) and `PageWork` is rebuilt (`rebuildPageWork`), so no record
survives into the next heap at the same addresses; `heap_generation_` plays no part in PageWork.
Several heaps: every PageWork call is under `thread_mutex_`, so heap B reusing heap A's released
extent cancels or waits exactly as the owner would (MAPPING.md §3); CR-012 keeps the unlocked
counters and `acquireOldGenRegion`'s re-map of a window.

**No hazard in M7's scope.** An overlap with a *different* start (a split or coalesced extent
reacquired while a record for another start covers part of it) is the one shape keying by start
could miss, and the code cannot produce it. That premise is now written into MAPPING.md §3; a
change to the free list's first-fit or append is caught by the canary pins `AL.acquireOldGenBlock`
and `AL.releaseOldGenBlock`, and would need the model's extents to become ranges.

**Side finding (not ABA, not concurrency; for the orchestrator):** a first-fit reuse of a
**larger** free extent hands out the whole extent (`AL:787-793`, `old_gen_in_use_bytes_ +=
block_size` at `AL:834`), but the caller records only the size it asked for (`populateFromBlock`,
`ensureBagPageAvailable`, `allocateFromBagPage`: `alloc_buffer_size`; `allocateLargeBlock`:
`bi.end = block_base + block_size` of its own request, `OldGenSpace.cpp:2946`) and later releases
only that (`releaseBlockToAllocator` → `releaseOldGenBlock(blk.start, total)`). The tail is
lost from the free list until `reset` (resident, never discarded, never reused), and
`old_gen_in_use_bytes_` (`getOldGenCommittedBytes`, the pressure triggers' numerator) grows by the
tail each time. Reachable whenever a released large block's extent is first in the list for a page
request. The plan (`plans/oldgen-capacity-shrink-and-large-reuse.md` Step 1) put splitting out of
scope; the permanent loss and the accounting drift are not written down anywhere.

### Model change: `pw_aba.cfg` (quick, pass)

The model already lets an extent id (= its start, the maps' key) be released, reused and
released again; `reuse_keeps_pending` (V1), `reuse_no_wait` (HEAP_059) and `age_stale_entry`
(NoOwnedPosted) are the ABA mutants (same start, stale record). `pw_basic`'s 5 operations reach
only about two reuse cycles, with the window taking some of them. `pw_aba` gives the depth to the
cycles: 3 extents all owned, no window (`InitFresh = {}`), 2 slots, 2 workers, 10 operations, every
invariant. No PlusCal change (the translation is unchanged).

| Run | Result | States | Time |
|---|---|---|---|
| `pw_aba` | pass (depth 44) | 238,633 | 3.4 s (2 workers) |
| `age_stale_entry` at `pw_aba`'s constants (scratch) | violates `NoOwnedPosted` | 463 at the stop | < 1 s |
| `reuse_keeps_pending` at `pw_aba`'s constants (scratch) | violates `V1` | 43 at the stop | < 1 s |
| `reuse_no_wait` at `pw_aba`'s constants (scratch) | violates `HEAP_059` | 1,047 at the stop | < 1 s |
| probe `reap_any_slot` (scratch only: `Reap` and `ReapSomeDone` forget a Posted extent whatever `postedIn` says, i.e. `reap` without `PW:100`'s slot check), at `pw_aba` and `pw_basic` | pass | 238,633 and 22,518: **the same state spaces** | — |

The probe's identical state counts show the slot check never changes a behaviour: a Posted
extent's job is always reaped before the extent can be reused, re-released and posted again (the
reuse waits and reaps, `PW:190-192`). It is a defensive guard, not a load-bearing one, so the probe
is recorded here and not kept as a mutant (a mutant must fail, rule A6).

Quick tier after the change: `run_models.py --model M7 --jobs 2 --workers 2
--java-opts="-Xmx3g -XX:MaxDirectMemorySize=1g"`: **19/19 as expected** in 9 s. Trace validation:
`run_traces.py --model M7`: **15/15 as expected** (the accept rows accept; the negative controls
reject). No canary pin changed (no code change).


## 2026-09-30 — canary re-audit: register reproductions (GC_MODEL_001)

Pins fired: OGS.lazySweep (3019e316a801), NT.TenureParEnv (53fc7d8f27b8), census Allocator.hpp (bedee6e4aa91), greps F.promoMu (2da021596e6c), F.threadMutex (e1f93bebd039), F.pageWorkCalls (8f281f438097), F.oldGenFreeBlocks (9df02db9364c), F.setThreadHeap (01d12addfaca).

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

Accessor text and a trace-only probe only. The new CR-007 guard reproduces M7's `lock_order_stall` witness in code (a 200 ms stall behind a latched Discard job).

**Verdict: no model change needed.**

## 2026-09-30 — register-fixes §3.1: CR-033 fixed (GC_MODEL_001)

Pin fired: region `OGS.allocateFromBagPage`, new hash prefix **8e85cd8f9aa1**.

Change (plans/threaded-gc-register-fixes.md §3.1; snapshot `snapshots/register-fixes/pre-phase1.tgz`):
the fresh-page carve's remainder test `remainder >= MIN_FREE_CELL_SIZE` became `remainder != 0`
(plus an 8-alignment assert), so an 8-byte tail goes through `pushSpanOnFreeLists` and gets an
unlinked `Tag_Free` header (HEAP_024 amended). Serial code under the same locks as before; no atomic
step, lock, shared location or memory order changes.

M7 models the page supply (`acquireOldGenBlock` via `ensureBagPageAvailable`, and the tail-completion release route); the carve change runs after the page is acquired and touches no page-work state, lock or counter. **Verdict: no model change needed.**

## 2026-09-30 — register-fixes Phase 2 (§4.1-§4.4): CR-014, CR-001 (race), CR-002, CR-028 fixed (GC_MODEL_001, one audit for the batch)

Pins fired for M7: region `OGS.allocatePromotion` (**9551468c0f86**: CR-002's rung-2 rewrite — an unswept-block head is finalized before the unlock, the batch peeks; PM8), region `OGS.lazySweep` (**b033f3f0c837**: CR-014's `completeSweep` for both completions, CR-028's deferred V11), census `OldGenSpace.cpp` (**2afe7bc4cf4d**).

Change that matters to M7: CR-014's fix closes the release route from the tail completion under `promo_mu_` for N > 1 (the shrink now runs in `endParallelPromotion`, after the join and outside `promo_mu_`); with N = 1 the route stays through `sweepCompleteInPromotion`'s one-worker branch, where no other member exists to stall. `onSweepComplete` now aborts inside a parallel promotion (PM7). The in-lock finalize (CR-002) adds no acquire, release or wait: `finalizePoppedCellW` touches only the cell, its mark byte and `live_bytes`. The route census row (MAPPING.md §4) is updated. M7 models the route generically (`P_Tm` → `P_Reuse`), so no state changes.

**Verdict: MAPPING.md updated; no model change needed.**

## 2026-10-01 — register-fixes §6.1: CR-019 fixed, relaxed atomic whole-word YLOS header access (GC_MODEL_001)

Pins fired: region `OGS.lazySweep`, new hash prefix **6066819cec59**.

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

M7 models the page supply and the release routes; the sweep's header reads acquire, release and wait for nothing. **Verdict: no model change needed.**

## 2026-10-01 — register-fixes §6.2: CR-012 option F (a second live mutator is forbidden), CR-012(d) fixed (GC_MODEL_001)

Pins fired: region `AL.acquireOldGenBlock` (**4f5f0b1d4dcd**), region `AL.releaseOldGenBlock` (**0fe08577fb84**), region `AL.acquireOldGenRegion` (**31cefe0c2ae5**), census `Allocator.cpp` (**88ca56595b84**), census `Allocator.hpp` (**1936ebd9fe0e**), grep `F.threadMutex` (**ac671f10dc1d**), grep `F.pageWorkCalls` (**cc75623b8fe3**: the new `onFreshBump` caller).

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

The new `onFreshBump` call in `acquireOldGenRegion` runs under `thread_mutex_` like every PageWork call and is a fresh bump at the bump pointer, i.e. M7a's `M_Choose` fresh branch (owner fresh → heap, never waits, never re-maps the window): the code now matches the model's HEAP_060 claim on this route instead of contradicting it. The in-use counter is not a PageWork input. MAPPING.md: `M_Choose` (fresh) row names the route; the `thread_mutex_` row and "outside the model" record that several heaps are forbidden by HEAP_007 (opt-in only) and that CR-012(d) is fixed. The TracePageWork harness drives PageWork standalone (no Allocator), so no trace changes. **Verdict: no model change needed; MAPPING.md updated.**

## 2026-10-01 — register-fixes §6.3: CR-007 fixed, no-wait acquire for a promotion holder with n > 1 (GC_MODEL_001)

Pins fired: file `PageWork.hpp` (**681db7309a0a**), file `PageWork.cpp` (**3b5ca6feb509**), file `test/gc-helper-tsan/harness.cpp` (**f3f06ed92a5e**), regions `OGS.allocateFromBagPage` (**8707d299ec96**), `OGS.ensureBagPageAvailable` (**37f3ac00eb2f**), `OGS.allocateLargeBlock` (**e2c48a27f642**), `OGS.releaseBlockToAllocator` (**2dc05c9c0440**), `OGS.releaseUnassignedBlockToAllocator` (**b1038520c58f**), `AL.acquireOldGenBlock` (**58fd49f66454**), greps `F.pageWorkCalls` (**9c2d8130d065**), `F.oldGenFreeBlocks` (**aa1d3a2debd5**).

**Model first (before the code).** `PageWork.tla`: constant `NoWait`; ghosts `gPend` (Pending membership kept by
caller steps only), `nwAcq`, `nwFallback`; a new `M_Choose` branch (the no-wait acquire: first
Pending → `M_Reuse` (cancel), else a fresh extent, else the cap fallback = first fit → `M_Reuse`,
which may wait); the ghost `gFree` makes the same choice from `gPend`; invariants `NoWaitUnlessCap`
(`nwAcq /\ pc = AS_Wait => nwFallback`) and `PendGhost` (`gPend` = the Pending set); mutants
`nowait_skip_posted` (a skip keyed on job state: takes a reaped extent) and `nowait_first_fit` (the
pre-fix first fit). `LockOrder.tla`: constant `CapExhausted`; at `P_Pick` a member meets the Posted
extent only if `CapExhausted` (mutant `nowait_off` restores the old pick). Re-translated both.
`NoWait = TRUE` in `pw_basic`, `pw_two_workers`, `pw_aba`, `pw_deep`, `pw_deep_liveness` (with the two
new invariants where the row lists invariants); `NoWait = FALSE` in the 9 older mutants (unchanged
verdicts); `CapExhausted = TRUE` in `lock_order`, `lock_order_3`, `lock_order_stall` and the four lock
mutants. Conservativeness: with `NoWait = FALSE` the new spec has exactly the old reachable set
(`pw_basic` 22,518 distinct states, old and new; the 26,496 above predates later edits).

TLC (quick, 24/24 as expected): `pw_nowait` (new) pass 48,319 states; `pw_basic` pass 23,567;
`pw_two_workers` pass 41,953; `pw_aba` pass 285,088; `lock_order_nostall` (new, `CapExhausted =
FALSE`) pass 290 (the witness invariant HOLDS); `lock_order_stall` still `witness:` (81);
`mutants/nowait_skip_posted` violates `DetChoice` (3,452); `mutants/nowait_first_fit` violates
`NoWaitUnlessCap` (698); `mutants/nowait_off` violates `MODEL_M7_StallWitness` (85). Non-vacuity
(scratch invariants on `pw_nowait`): a no-wait Pending reuse reaching `M_Touch` and a cap-fallback
wait in `AS_Wait` are both reachable. Deep: `pw_deep` pass 13,561,819 distinct states (depth 44,
121 s, 4 workers), `pw_deep_liveness` pass 1,956,641 (59 s).

**Trace.** `TracePageWork`: event `nw k x` (`PageWork::noteNoWait`, logged before the `acq` / `fresh`
it announces) sets `nwNext`; the next `acq` must be the no-wait branch with `nwFallback <=> k = 3`, a
`fresh` after `k = 2` needs no Pending extent in the list, an `acq` with no `nw` must be the
first-fit branch; `NoWaitUnlessCap` and `PendGhost` join the per-step invariants. The harness
(`harness.cpp`) gains a 12th argument, the share of reuses made under the policy (default 0: older
rows replay unchanged). `.keep` gains `nw`. New rows: 2 accept (`fake,…,50`: 56 Pending, 3 fresh,
7 fallback picks; `real,…,100`: 9 / 8 / 25) and 3 reject (`set:nw:2:k=3`, `set:nw:1:k=1`,
`set:nw:12:k=2`). `run_traces.py --model M7`: 20/20 as expected.

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

**Verdict: model updated (PageWork, LockOrder, TracePageWork), MAPPING.md updated (variables, the
no-wait `M_Choose` row, `P_Pick`, §4 route note, §6 invariants, §10 trace, A5).**


## 2026-10-01 — register-fixes Phase 5: no teardown under thread_mutex_, the fork prepare order (HEAP_075) (GC_MODEL_001)

Pins fired: files `GCHelperPool.hpp` (**376411c19869**), `GCHelperPool.cpp` (**22f4e3f2b546**); new file and census pins `GCFork.cpp`; regions `AL.onGCPauseEnd` (**21aae9bc0c5a**), `AL.cleanupThread` (**b3491e1c948b**), `AL.finishTenureForExit` (**1eb1d4117cf9**); censuses `Allocator.cpp` (**98ff871fcd48**), `Allocator.hpp` (**12959cd0b43c**), `GCHelperPool.cpp` (**98e0cc199b0b**), `GCHelperPool.hpp` (**297cf886ba5a**); greps `F.threadMutex` (**6cdf9fdc0767**), `F.setThreadHeap` (**792561bbb51f**).

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

**Model first (§7.2 step 2, checked before step 3).** `LockOrder.tla`: `MUTANT` is now a SET; the
parallel minor is a `GCMarkGang` run (`R_Run`: the caller "mut" takes `run_m_` and starts the members;
`R_Join`: after every member returned, `run_m_` is released); the teardown joins the collector through
its gang `m_` (`T_JLock`, `T_Join`) with NO `thread_mutex_` (the pre-fix hold is mutant
`teardown_under_tm`); a `Forker` process (constant `Fork`) runs GCFork's prepare: stopAndJoin of the
collector (its `m_`, then the wait), the collector's `m_` held, `run_m_`, `thread_mutex_`, the pool drain
(the job Done), then the parent handlers release (mutant `fork_tm_first`: `thread_mutex_` first). Results
(TLC): new row `lock_order_fork` **pass** (1,188 states, deadlock check + AllFinish); mutants
`teardown_under_tm` **deadlock** (1,176; mut holds thread_mutex_ at `T_JLock` waiting for the m_ the
forker holds at `F_Tm`) and `fork_tm_first` **deadlock** (600; the forker holds thread_mutex_ at
`F_RunM` while the run's member g1 waits for it under promo_mu_ and mut's run waits for g1). Since the
teardown no longer holds thread_mutex_, `collector_takes_tm` alone deadlocks nothing; its row now runs
with `teardown_under_tm` too (deadlock, 966). Every other row unchanged in verdict (`lock_order` 804,
`lock_order_3` 2,382, `lock_order_stall` witness 408, `lock_order_nostall` 930). `run_models.py --model
M7`: 27/27. Grep of every `lock_guard<std::recursive_mutex> lock(thread_mutex_)` site: none reaches
`GCMarkGang::run`/`configure`, a `GCBackgroundGang` construction/launch/join/stopAndJoin or the registry
after the change (`initThread` constructs a ThreadLocalHeap under it, which builds no gang; pool
`configure` under it takes only the pool's m_, the innermost leaf). PageWork (M7a) is unchanged: every
call still runs under `thread_mutex_`; the pool's `post` only moved its CAS into the existing `m_`
section (workers still take only `m_`). The new trace-only probe `m6.tm.held` in `onGCPauseEnd` fires
under `thread_mutex_` and changes no step. **Verdict: model updated (LockOrder, MAPPING.md).**

## 2026-10-01 — frontend-heap-release P1: DiscardAllPending, the explicit release's drainAll(true) (GC_MODEL_001)

Pins fired: census `Allocator.cpp` (**7d5d75af1902**), grep `F.threadMutex` (**00cb061f21bd**): four new
`thread_mutex_` lock_guards. New pin: region `AL.releaseDiscard` (M6, M7). `PageWork.{hpp,cpp}` (file pins)
are unchanged: `drainAll` was already public.

plans/frontend-heap-release.md P1 (§3, HEAP_076): the explicit release. New `ThreadLocalHeap::majorGCAndShrink` (TLA-REGION `TLH.majorGCAndShrink`): ONE pause and ONE sync point (an outermost `PauseEndHook` around a nested `majorGC(MajorReason::Explicit)`, then `OldGenSpace::finishSweepForRelease` (lazy sweep driven to Idle, `while (gc_phase_ != GCPhase::Idle)`, aborts if a cycle is active) and `shrinkToFloorForRelease` = `maybeShrinkCapacity(0, ShrinkPass::Forced)`). New `Allocator::collectMajorAndRelease` (after that pause, under `thread_mutex_` only: TLA-REGION `AL.releaseDiscard` = `page_work_->drainAll(decommitOn())` + counter reads; `malloc_trim` after the lock) and `Allocator::collectMinor` (two `thread_mutex_` snapshot sections around a plain `minorGC`). Both are fatal inside a pause (`pause_depth_ != 0`).

MAPPING.md said `drainAll` ran only at reset and teardown (outside the model). The explicit release calls
`drainAll(true)` on a live heap, so it is now a modelled mutator step (the plan's preferred option, §3.8),
not an AUDIT argument. `PageWork.tla`: a new `M_Choose` branch **DiscardAllPending** = `M_DrainSlots`
(`awaitSlot` on every slot in slot order: wait until Idle or Done, reap; loop) then `M_DrainDiscard` (every
Pending extent → `none`, discarded inline by the mutator, still in the free list; `gPend` and `stale`
cleared, as `pending_` / `pending_order_` are). New invariant `DrainSafe`: at `M_DrainDiscard` every slot is
Idle and every Pending extent is free (HEAP_059 for the inline discard). New mutant `drain_no_await` (the
slot loop skipped) violates it: counterexample (746 states) = a sync point posts a Populate job for the
window, then the drain reaches `M_DrainDiscard` with that slot still Posted — the intended story. The step
is unconditional (no new constant), so every existing row now also explores it; `DrainSafe` was added to
`pw_basic`, `pw_two_workers`, `pw_aba`, `pw_nowait`, `pw_deep`. Re-translated (pcal).

Results (`run_models.py --model M7`, TLC): quick 28/28 as expected — `pw_basic` pass 26,956 states,
`pw_two_workers` 47,380, `pw_aba` 353,875, `pw_nowait` 55,810; every older mutant keeps its verdict;
`mutants/drain_no_await` violates `DrainSafe`. Deep: `pw_deep` pass 14,679,327 states (135 s, 6 workers;
was 13,561,819), `pw_deep_liveness` pass 2,064,629 (57 s; `MutatorFinishes`: the drain's waits return).
Non-vacuity (scratch invariants on `pw_basic`): `M_DrainDiscard` is reached with a Pending extent, and the
drain's `AS_Wait` is reached on a busy slot. HEAP_060, V1, TrackedInFree, NoOwnedPosted, DetChoice,
PendGhost, PostIdle and NoWaitUnlessCap hold with the new step (the drain changes neither the free list nor
its ghost, so GC_DET_001's `DetChoice` is untouched: `drainAll(true)` empties `pending_` identically in modes
1 and 2). LockOrder (M7b) is unchanged: the drain adds no edge beyond the existing `thread_mutex_` → pool
`m_`. **Verdict: model updated (PageWork.tla, MAPPING.md, models.txt).**

## 2026-10-05 — Windows build: the probe page's alignment under _WIN32 (GC_MODEL_001)

Pin fired: file `PageWork.cpp` (**6a3a3b932b3a**).

Change: `g_probe_page`, the page the constructor hands to one `ops_.populate` call to probe
`MADV_POPULATE_WRITE` support, is declared `alignas(8192)` under `#if defined(_WIN32)`, because clang-cl
rejects alignments above 8192. Every other platform keeps `alignas(65536)`, so the Linux and macOS
preprocessed source is unchanged. The probe runs once in the constructor, before any job can be posted,
on a page no other thread touches; MAPPING.md maps no step to it. No atomic step, lock, shared location or
memory order was added, removed or reordered. The six added lines move every later `PageWork.cpp` line by
+6; the line citations in MAPPING.md and `test/genmc/w_pool_done.cpp` were already about 15 lines out
(`runJob` is cited at `:50-63` and sat at `:65`) and are left as they are. **Verdict: no model change
needed.**

## 2026-10-05 — Windows link: the probe page's alignment under _WIN32 is 4096 (GC_MODEL_001)

Pin fired: file `PageWork.cpp` (**2dc7a9205c9a**).

Change: `g_probe_page` under `_WIN32` is `alignas(4096)`, not `alignas(8192)` (this morning's entry):
the object compiled, but linking `eco-compiler.exe` failed with LNK1164, because a PE image's
sections align to at most `/ALIGN` (4096 by default). Linux and macOS keep `alignas(65536)`. As
before, the probe is one `ops_.populate` call in the constructor, before any job can be posted, on a
page no other thread touches; MAPPING.md maps no step to it, and no atomic step, lock, shared location
or memory order changed. **Verdict: no model change needed.**
