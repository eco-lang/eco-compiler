# M3 — audit log

Dated entries, newest last. Each records what was checked against which tree, the verdicts, and
every change to the model. A canary re-audit (parent plan §7.4) adds an entry here quoting the new
hash prefix. The canary pins for M3 are not in `test/tla/manifest.txt` yet.

## 2026-09-28 — first implementation

**Tree:** 2026-09-28, post-7c (the tree the plan's adversarial review used). Every file:line the
plan cites was re-checked; the drift is small (below). **Tools:** the dev image: tla2tools 1.8.0
(TLC 2026.09.25 rev 8f4bc8b, pcal 1.12). **Machine:** shared (12 cores, six other agents); quick
rows with 2 TLC workers, deep rows with 4 at `nice 10` (`region3` under the machine-wide deep lock,
`-Xmx5g`). The times are wall-clock under that load.

### Results

Quick tier (`tla-check`), 12 rows: `run_models.py --model M3 --jobs 2 --workers 2`, **12/12 as
expected in 42 s**. The mutants' state counts vary a little between runs (TLC stops at the first
violation its workers meet); the counts below are the runner's.

| Configuration | Expected | Result | Distinct states | Time |
|---|---|---|---|---|
| `MC_quick_legacy` | pass | pass, all seven invariants | 225,963 | 13 s |
| `MC_quick_region` | pass | pass, all seven invariants | 225,963 | 14 s |
| `MC_quick_legacy_run2` (`MaxRun = 2`) | pass | pass | 72,426 | 7 s |
| `mutants/copy_without_cas` | violates `CopyOnce` | as expected | 14,925 | 5 s |
| `mutants/size_from_busy` | violates `SizeFaithful` | as expected | 12 | 2 s |
| `mutants/publish_early` | violates `FwdComplete` | as expected | 10 | 2 s |
| `mutants/no_wait` | violates `AtJoin` | as expected | 266,457 | 12 s |
| `mutants/no_wait_contract` | violates `CopyOnceContract` | as expected | 266,783 | 13 s |
| `mutants/heads_walk` | violates `OwnerWrites` | as expected | 6,095 | 3 s |
| `mutants/heads_all` | violates `OwnerWrites` | as expected | 957 | 3 s |
| `mutants/ylos_unlocked` | violates `YlosOnce` | as expected | 1,817 | 3 s |
| `mutants/never_publish` | deadlock | as expected | 44,016 | 4 s |

(`MC_quick_region` has exactly the legacy count: the two heaps have the same shape, and promotion
changes no control flow.)

Deep tier (`tla-check-deep`):

| Configuration | Expected | Result | Distinct states | Time |
|---|---|---|---|---|
| `MC_deep_liveness` (`Termination`) | pass | pass | 225,963 | 45 s |
| `mutants/never_publish_liveness` | violates `Termination` | as expected | 86,134 | 19 s |
| `MC_deep_legacy3` (three workers) | pass | pass | 10,404,655 | 8 min 27 s (4 workers, depth 149) |
| `MC_deep_region3` (three workers) | pass | pass | 10,404,655 | 5 min 13 s (4 workers, depth 149) |

**Verdict.** For every interleaving of two workers (three in the deep tier) over the example heap,
in both modes: each from-space object is copied at most once; every live slot, root and YLOS slot
included, ends at the copy its original's header forwards to (or at the Retire object's tenured
copy); no BUSY word survives the drain; no copy is sized from a BUSY word; a promoted object never
points at a surviving copy; every slot into Hand is recorded; each YLOS is reached once; only an
object's owner evacuates its slots; and every worker exits. The protocol is textbook (HB 14.4), and
M3 found no defect in it.

### Coverage witnesses (not in the registry)

A pass is only as good as the interleavings it reached. In a scratch copy, each of these was
checked as a negated invariant on the quick configurations, and TLC reached every one, in both
modes unless noted:
- a claim CAS that fails (`E_Claim` and `S_Claim`);
- a wait on a BUSY word (`E_Wait` and `S_Wait`);
- a truncated run (`MaxRun = 1`), and a run that ends at a cell another worker copied (the rule-1
  situation of plan §3.5);
- a second reach of the YLOS that finds it already reached (region mode only after the heap change
  below);
- region: a recorded Hand slot and a resolved Retire slot;
- `AllDone`;
- under `no_wait`, the plan's own story too (`7`'s slot left at 0), besides the shorter one TLC
  prints.

### Counterexamples

Every counterexample was read, to check it is the intended story and not another path to the same
invariant. The traces are in MAPPING.md §9. In short (worker 1 is the mutator, which copies `1` and
`3` in the root phase):
- **`heads_walk`** is the plan's story, with the run ending at a **forwarded** `5`, not at a
  truncation: worker 1's run from `3'` copies `4`; worker 2, scanning the YLOS `7`, copies `5`;
  worker 1 loads `FWD(105)`, links `104 → 105`, and its walk goes from `104` into `105`. 71 states.
- **`heads_all`**: worker 1's run from `3'` copies `4`, meets `5` unforwarded at `k = MaxRun = 1`,
  pushes `104`, then evacuates `104`'s head. 53 states.
- **`ylos_unlocked`**: workers scanning `1'` and `3'` both pass the colour test on `7` before either
  sets it. 60 states.
- **`copy_without_cas`** is the plan's story exactly: worker 1 scans `7` and loads `Unfwd` from
  `5`; worker 2's run from the pushed `4'` claims `5`; worker 1's store-claim ignores BUSY. 82
  states.
- **`no_wait`**: the shortest trace loses `5'`'s head, not `7`'s slot as the plan tells it: worker
  1 claims the shared leaf `2` (scanning `1'`); worker 2, scanning `5'`, reads `2`'s BUSY word as
  address 0. The same mechanism on the other shared object. The plan's variant is reachable too
  (witness above). 134 states; `no_wait_contract` is the same behaviour.
- **`size_from_busy`** and **`publish_early`** fail on worker 1's first root copy (12 and 10
  states).
- **`never_publish`**: worker 1 waits at `S_Wait` on `5`, worker 2 at `E_Wait` on `2`; neither
  publish ever comes. As a liveness check with deadlock checking off, TLC reports the same state
  as a stuttering violation of `Termination`.

### Changes from the plan's sketch (plan §5.5), and why

1. **TLC could not compare the header states.** The sketch's `hdr[o] ∈ {"H", "BUSY"} ∪ CopyIds`
   mixes strings and integers, and TLC stops at `FwdComplete`'s `hdr[o] \in CopyIds` with
   "Attempted to compare string "H" with non-string". SANY cannot see it. `Unfwd` and `Busy` are
   now model values (constants, `Unfwd = Unfwd` in every `.cfg`).
2. **`spineRunP` fidelity** (the code, `NurseryParallel.cpp:397-442`; `spineRunR` the same):
   - the heads pass runs only `if (needs_heads && k > 0)` (`:424-425`, `:431`): some copied cell's
     head is a heap pointer. The sketch ran it always. That over-approximates for the pass rows,
     but for `heads_all` it manufactured a failure the code cannot produce: the run's only cell,
     `4 = Cons(Nil, 5)`, has a constant head, so the code skips the pass (parent plan §12 trap 11);
   - a Nil tail ends the run (`:403-405`); the sketch called `Evacuate` on it;
   - the header is loaded before the Cons test (`:408-414`); the sketch tested the id first. No
     behaviour of the example heap depends on it (every Cons tail is a Cons or Nil).
3. **The heap: `4 = Cons(9, 5)`** instead of `Cons(Nil, 5)`, so that `needs_heads` is set and the
   heads pass runs at all. `9` is the old leaf: evacuating it changes nothing.
4. **The region heap keeps both of the YLOS's parents.** The plan's region heap replaced `1`'s
   field `7` by the Hand object `11`, so `7` had one parent and the region configuration never
   reached it twice. The region heap is now the legacy heap with `2 → Retire 12` and `4`'s head →
   Hand `11` (recorded by the run's heads pass or by the scanner of a pushed `4'`). Its ages are
   all 0 (TV9; `reachYoungLargeR` sets the YLOS's age to 1).
5. **Dead-state hygiene** (primer §4.2): `res[self]` is cleared after use, and `wr` after the root
   loop.
6. **Added rows:**
   - `MC_quick_legacy_run2` (`MaxRun = 2`): a two-cell run to Nil, so the heads pass counts two cells
     (the `i + 1 < m` step);
   - `MC_deep_region3` (the plan listed only `legacy3`);
   - `MC_deep_liveness`: PlusCal's `Termination` (the plan allowed `<>AllDone` in a deep row);
   - mutant `never_publish` (a claimant that returns without publishing), as a deadlock row in
     quick and as `violates:Termination` in deep, so that the deadlock check and the liveness
     property have teeth (A6).
7. **Mutant configurations turn deadlock checking off**, so that only the target can fail. The pass
   rows keep it on: the spec terminates, and a stuck wait would show as a deadlock.

Plan line drift found while checking (all minor): the region role table is rebuilt after the drain
by `checkAndGrow` at `NurseryRegion.cpp:1021` (plan: `:1022`); `releaseBlockToAllocator`'s erase
loop is `OldGenSpace.cpp:6056-6073`. Everything else the plan cites matched.

### Register entries touching M3

- **CR-011** (no layout test of the forward words). Unchanged: **Confirmed, G**. M3 assumes that
  `Unfwd`, `Busy` and a forward word never collide (MAPPING.md §7); no model or trace can see a
  layout mismatch. Re-checked: no test composes `mw::fwdWord` and decodes it through `Heap.hpp`'s
  `Forward` (the W5 driver `test/genmc/w5_forwarding.cpp` only round-trips through `mw::fwdAddr`).
- **CR-014** (`lazySweep`'s tail path runs the shrink inside a parallel minor). Unchanged:
  **Confirmed (shape)**; M3 has no sweep, so it cannot show it. Code reading for M3's footprint
  (P6.M9): every route to `releaseBlockToAllocator`, and so to the `large_body_index_` erase loop
  that races `youngLargeMeta` under `ylos_mu_`, goes through `maybeShrinkCapacity` (`:5873`, and
  `:5890` via `releaseUnassignedBlockToAllocator`), which only `onSweepComplete` (`:5502`) and
  `adjustCapacityAfterMajorGC` (`:5669`) call. `lazySweep`'s own erases (`:5311`, `:5404`) are on
  the header-walk path, unreachable in a parallel minor (it requires bitmap allocation,
  `resolveMinorThreads`, `:2948`). So after CR-014's candidate fix (path 2 through
  `sweepCompleteInPromotion`, which defers at `n > 1`, `:1363-1366`), nothing outside `ylos_mu_`
  erases the index during a legacy drain, and M3's one-step `Y_Lock` is exact for the index.
- **CR-019** (a young YLOS header written under `ylos_mu_`, read by a sweep slice under
  `promo_mu_`). Proposed: **Confirmed (shape)**, by code reading. The open question was whether a
  young YLOS can sit in a mixed block that a sweep slice walks inside a legacy drain. It can:
  - `allocateYoungLarge` → `allocateTrackedCell` → `allocate` (`OldGenSpace.cpp:7011-7013`); sizes
    in `[largest fixed class, alloc_buffer_size)` go to `allocateFromBagPage` (`:1940-1943`), and
    `allocateFromSizeClass`'s last resort also does (`:2229`): bag pages are mixed blocks. In
    legacy mode the YLOS threshold is `nursery_capacity / 8` (`ThreadLocalHeap.hpp:216-221`), so a
    small nursery puts YLOS objects in that band;
  - a YLOS allocated during marking is allocated black (`initObjectHeaderWithSize`, `:497-518`),
    and `prepareMetaForLazySweep` (`:3925-3933`) marks every block unswept when the sweep starts,
    bag pages acquired during marking included, so the sweep walks that block and steps over the
    YLOS;
  - inside the drain, `allocatePromotion`'s ladder (`ladderFrom2W`, `:1336-1346`) runs
    `sweepOnDemandAllocate` and `panicSweepAndRetryAllocation` under `promo_mu_`, both `lazySweep`,
    whose gap sweep reads the header of each marked cell (`getObjectSize(live_obj)`, `:5361`);
  - meanwhile another worker's `reachYoungLargeP` writes `h->age++` (`NurseryParallel.cpp:378`) or
    `promoteYoungLarge` writes `age = 0` (`OldGenSpace.cpp:7125`) under `ylos_mu_`.

  Dynamic reachability is not shown (it needs the sweep to reach that block during the drain).
  M3 cannot show it (no sweep, no YLOS in M4). A `gc-heap-tsan` legacy scenario with a small
  nursery that allocates a pointer-bearing large object during marking would reproduce it.
- **CR-020** (no TSan harness runs the parallel YLOS reach with more than one worker). Unchanged:
  **Confirmed, G**, with model evidence for the protocol's logic: `YlosOnce` holds for every
  interleaving of two and three workers in both modes, a second reach is reached in both, and
  `ylos_unlocked` fails. What the model cannot cover is the C++ data-race side (CR-019, and CR-014's
  index race); the next step is unchanged (a YLOS kind in `minor_harness`, which trace validation
  needs too, and a pointer-bearing large object in `heap_driver`).

### Not done in this step

- Trace validation (plan §9): the harness is `gc-minor-tsan`, a target of the standalone project
  `test/gc-helper-tsan/` (`minor_harness.cpp`), not a directory of its own. It needs a tiny-heap
  mode that writes the heap into the trace header, a YLOS object kind, the `ECO_TLA_TRACE` hooks in
  `MinorWork.hpp`, and `TraceMinorForwarding.tla`.
- The canary lines (`test/tla/manifest.txt`); the proposed lines are in the report to the
  orchestrator.
- The weak-memory companions W5 and W1 (A4: W pending).

## 2026-09-29 — trace validation (plan §9, rule A5)

**Tree:** 2026-09-29, with the shared trace infrastructure (`TlaTrace.hpp`, `test/tla/trace/`,
`common/Trace*.tla`, `run_traces.py`). **Verdict: every trace accepted; every negative control
rejected; no model change and no code defect.**

### What was built

- **Hooks in `runtime/src/allocator/MinorWork.hpp`** (compiled out unless `-DECO_TLA_TRACE=1`):
  `claim` (after the CAS: an `rmw` on success, the observed word on failure), `publish` (after the
  release store), `wait` (`waitPublished`'s first non-BUSY load). Two trace-only helpers
  (`tlaWordKind`, `tlaFwdTo`) exist only under `ECO_TLA_TRACE_ENABLED`. The code changes are a
  local `ok` in `claim` and braces around `waitPublished`'s return; the texts the W5 mutants patch
  (`mutate.sh`) are unchanged.
- **Production unchanged:** `NurseryParallel.cpp` and `NurseryRegion.cpp` (every allocator file
  sees `MinorWork.hpp` through `NurserySpace.hpp` / `OldGenSpace.hpp`), preprocessed with
  `EcoRuntimeStatic`'s flags from `build/build.ninja` (clang++, `-O2`): 4 `((void)0)` each, one per
  hook, and 0 before; compiled without `-g`, their disassembly is byte-identical before and after.
- **`test/gc-helper-tsan/minor_harness.cpp`:**
  - a **YLOS object kind** in both modes (the plan's §9 requirement, and CR-020): nodes in a
    `ylos` region, reached under `ylos_mu` (test-and-set of a reached flag, then promotion in place
    or ageing, in one critical section), pushed after unlocking, scanned in place. The random heaps
    now have 20–60 YLOS objects (1–40 slots), referenced from random slots and roots, so most have
    several parents. New checks: every reachable YLOS reached exactly once, promoted or aged, its
    slots updated to the copies;
  - a **tiny mode** (`tiny <seed> <workers> <spine run> <pace us>`): seed 0 is `MC.tla`'s legacy
    heap, other seeds random heaps of its kind (5–6 objects, a YLOS, old 9, three roots), with
    random pauses at the protocol points; it writes the heap into the trace header;
  - the harness's events (`load`, `copy`, `slot`, `link`, `trunc`, `heads`, `scan`, `ylos`,
    `ypush`) and a bounded spine run (`spine run` argument; `kSpineRun` = 512 otherwise).
- **`test/gc-helper-tsan/CMakeLists.txt`:** target `gc-minor-trace` under `option(ECO_TLA_TRACE)`
  (the same option M7's `gc-helper-trace` uses).
- **`TraceMinorForwarding.tla` / `.cfg` / `.keep`**, and 15 rows in `test/tla/traces.txt`: 6
  `accept` (seed 0 with 2 and 3 workers and spine runs of 1 and 2; seeds 3, 7, 15) and 9
  negative controls on seed 0. MAPPING.md §11 maps every event to its hook and model step.

### Results

`run_traces.py --model M3 --jobs 2 --workers 2`, four times (the logs vary with the schedule):
**15/15 as expected each time**, 24–29 s per pass (the first includes a 6 s build).

| Row | Events | Distinct states | TLC time |
|---|---|---|---|
| `tiny,0,2,1,300` | 38–41 | 781–2,010 | 3–4 s |
| `tiny,0,3,1,300` | 37–41 | up to 3,971 | 4 s |
| `tiny,0,2,2,300` | 37 | 1,548 | 3–4 s |
| `tiny,3,2,1,300` | 39–43 | 235–568 | 3–5 s |
| `tiny,7,3,1,300` | 41–44 | 2,129–3,293 | 3–7 s |
| `tiny,15,3,1,300` | 41 | up to 41,273 | 4–9 s |
| 9 negative controls | 37–38 | 5–609 | 2–3 s, each rejected |

Where the controls stop: a second copy, the unpromoted copy, the early BUSY word, the missing root
slot, the copy before its claim and the wrong forward all stop in worker 0's root phase (5–13
states); the lost first YLOS reach at event 17 of 38; the two-cell heads pass at event 38 of 38.

**A wider sweep by hand** (the same harness, merger and spec): 115 more logs (seeds 0–49, 2 and 3
workers, spine runs 1 and 2, pauses 200–600 µs). **All accepted**, at most 45,276 states and 7 s
each. What they exercised:

| Situation | Logs |
|---|---|
| a lost claim (the CAS failed) | 22 |
| a wait on a BUSY word | 23 |
| a BUSY word observed by a load or a failed claim | 25 |
| a lost YLOS reach (a second worker found it reached) | 25 |
| a truncated spine run | 13 |
| a load of a forward word another worker published | 61 |
| three active workers | 22 |

### Changes from the plan's §9

- `load` is logged at the call sites (the harness's `evacuate` and `spine`), not in `loadHeader`:
  `waitPublished` spins on `loadHeader`, and a hook there would log every spin. `wait` logs the
  loop's exit only.
- The model's word values are logged as `w` (0 / 1 / 2) and `to` (the forward target's model id);
  the merger orders a header word's events by the raw word (`val` / `old` / `new` = `W<word>`).
- Events the plan did not list: `trunc` (the bounded run's push, which carries the put key) and
  `ypush` (the push after `ylos_mu`, likewise); `take` is `scan` (logged where the entry's scan
  starts, with its get key).
- The spec is `TraceAnyOrder` (vector clocks from the merger), not a hand-written per-object merge.

### CR-020: the TSan run with the YLOS kind

`gc-minor-tsan` (g++, `-fsanitize=thread`, the normal TSan target), rebuilt with the YLOS kind
under the machine-wide lock (`ninja -j4`), run once as `gc-minor-tsan 2` (under the lock): 2 random
heaps × 1, 2, 4, 8 and 16 workers × LABs of 4 KiB and 32 KiB, plus the jitter-50 subset: **30
runs, `minor_harness PASS`, 0 ThreadSanitizer reports.** Each heap has 20–60 YLOS objects with
several parents, so the parallel `ylos_mu` reach (test-and-set, in-place promotion or ageing, push,
in-place scan) now runs under TSan with up to 16 workers, and the harness checks that every
reachable YLOS is reached exactly once. The default 200-heap run was not done (a shared machine,
with the deep lock queued behind other models); `gc-minor-tsan` with no argument runs it. For
CR-020 this closes the harness half (`minor_harness`); the other half (a pointer-bearing large
object in `gc-heap-tsan`'s `heap_driver`, which would reach CR-019's sweep read) is still open.

### Still not done

- Tracing the production functions (plan §11 Q4) and region mode: the harness has no region roles.
- The canary lines for `MinorWork.hpp` (now carrying the hooks) and the harness's regions: in the
  report to the orchestrator.

## 2026-09-29 — canary baseline (GC_MODEL_001)

The canary (`test/tla/manifest.txt`, `tla-canary` in every build) was first pinned today: 40 pins
name this model (6 census, 4 file, 13 grep, 17 region); the list is in MAPPING.md's "Canary pins (A9)" block. This is the
baseline: the pinned code is the code this model was checked against today (after the trace hooks,
wave 3's fixes and the `TLA-REGION` markers landed). From now on, a pin that fires needs an entry
here quoting the new hash prefix before `check-tla-manifest.sh --update` accepts it.

## 2026-09-29 — ABA audit (addresses reused after a free): no model change

This entry follows CR-034 (a YLOS address reused after a STW major, then taken for the old object).
It asks whether anything in M3's window can free an object and let a **different** object take its
address or large-body id before a consumer looks it up. Verdict: **no**, so M3 is unchanged. The
new MAPPING.md §3 row states the argument; it applies to every address list M3 covers:
`young_large_scan_`, `promoted_buf_`, the per-worker `promoted_log`, `ylos_young`, `lb_seen`,
`lb_promoted`, and the `youngLargeMeta` lookup in `reachYoungLarge{,P,R}`.
- **The window is one pause.** Every list above is cleared at minor start. It is consumed before
  `NurserySpace::minorGC` returns, by the drain, the merge (`NP:797-833`, `NR:931-955`) and
  `censusRecord` (`NurserySpace.cpp:1177`, before `sweepNurseryLargeBodies` at `:1219`). No major runs inside a
  minor: the nursery never calls `majorGC`, and a failed promotion aborts. A STW major or handoff
  in the same pause runs after `minorGC` returns, when nothing reads these lists any more.
- **Only the mutator adds index entries** (`registerLargeBody` `OGS:7526`, from
  `allocateYoungLarge` and `allocateLargeBody`). Inside a pause the index only loses entries:
  in-place promotion, and CR-014's release under `promo_mu_`. So a lookup by an address read in the
  pause cannot find a newer object. It can only fail to find one.
- **Every address is read from a slot the pause reaches**: a root, a copy, a reached YLOS or a
  builder. The object at that address is therefore live. A lazy-sweep slice inside the drain frees
  only cells that were dead at the last mark. `retireDeadLargeBodies` (`OGS:1793`) had already
  erased their index entries before any reuse, and the header walk erases them as it passes
  (`OGS:5639`, `:5740`).
- **Across pauses**, only the P1 census keeps YLOS addresses (`census_ylos_`, `R.census`). It
  drops them when `majorEpoch()` changes (`NurserySpace.cpp:2726`, `:2849`). `major_epoch_` is bumped in
  `finalizeMetaAfterMark`, before any retire or free of a major or a handoff, and it is never
  reset. `Allocator::reset` destroys the heaps, so the census lists do not survive a reset either.
  Deferred frees happen after the bump.

A faithful "free, then reallocate at the same id" step has nothing to model here: no action in the
pause can reallocate an id that is still in use.

Found on the way. These are outside M3's scope and were reported to the orchestrator for the
register:
- **The empty-block flip keeps stale large-body index entries** (`allocateFromEmptyRegularBlocks`
  `OGS:2855-2913`, which has no cleanup like `releaseBlockToAllocator`'s at `:6403-6437`). Take a
  dead YLOS or body Y at a mixed block's start, still indexed and uncounted (CR-018's Idle gate).
  An exact-`alloc_buffer_size` YLOS or body Z flipped onto that block takes Y's address, and
  `registerLargeBody` overwrites the index key. At the next minor Y's stale meta is freed:
  `freeLargeBodyCell` erases the key (now Z's) before its `is_large` test (`:7695`). Z then drops
  out of the minor (not scanned, so its young children dangle), and one minor later its meta, never
  recoloured, frees Z's whole block while Z is live. This is S1 and serial.
- Ids retired by a major (`retireIndexEntry`) are never recycled, because
  `sweepNurseryLargeBodies` drops the stale entry without a push (`:7636-7645`). That leaks 24 B of
  `large_bodies_` per retired body (a growth leak, not ABA).
- `releaseBlockToAllocator` recycles an id that may still sit in `nursery_owned_bodies_`, so a
  re-registered id can appear there twice. This is benign: no id is pushed twice, and every
  consumer tolerates a duplicate.
