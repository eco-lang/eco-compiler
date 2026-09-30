# M1 — audit log

Dated entries, newest last. Each records what was checked against which tree, the verdicts, and
every change to the model. A canary re-audit (parent plan §7.4) adds an entry here quoting the new
hash prefix. The canary is not built yet.

## 2026-09-28 — first implementation

**Tree:** 2026-09-28, post-7c (the tree the plan's adversarial review used). **Tools:** the dev
image: tla2tools 1.8.0 (TLC 2026.09.25 rev 8f4bc8b), Apalache 0.62.2.

### Results

Quick tier (`tla-check`), 18 rows. The state counts are TLC's distinct states:

| Configuration | Expected | Result | States |
|---|---|---|---|
| `MC_quick` | pass | pass, all nine invariants | 2,915,545 |
| `MC_quick_sync` | pass | pass | 216,800 |
| `MC_quick_region_nomajor` | pass | pass | 1,028,216 |
| `MC_quick_region` | violates `MarkerFootprint` (CR-017) | as expected | — |
| 14 mutants (`mutants/*.cfg`) | each its target | each as expected | 346 – 79,098 |

Deep tier (`tla-check-deep`):

| Configuration | Expected | Result | States | Time |
|---|---|---|---|---|
| `MC_deep_ops3` (3 operations per run) | pass | pass | 32,011,689 | 3 min 42 s, 12 workers |
| `MC_deep_long` (6 minors, T = 3, 2 stops, 2 majors) | pass | pass | 21,950,853 | 6 min, 4 workers |
| `MC_deep_wide` (6 ids, 2 fields) | pass | pass | 36,358,263 | 13 min 20 s, 4 workers |
| `MC_deep_region` (region mode, 3 operations, no major) | pass | pass | 9,043,480 | 3 min 16 s, 4 workers |
| `MC_deep_liveness` (`CycleEnds`, fair mutator) | pass | pass | 168,649 | 11 s |
| `mutants/closing_never` | violates `CycleEnds` | as expected | 211,859 | — |

### Counterexamples (the plan's §2.4 timelines, now produced by TLC)

Every counterexample was read, to check that it is the intended story and not another path to
the same invariant. The starting heap: old `1 → 2` and `4`, young `3 → 4`, `r1 → 1`, `r2 → 3`,
empty `c1`. The shortest counterexamples below mostly end at a **pressure finish** at minor 2,
which hands off early. That path was missing from the model before the plan's review.

- **`p1_violation` → `IM1`** (timeline (a), short form). The steps: minor 1, then t0 greys `{1, 4}`.
  A kernel writes `1.f := Nil`. The marker scans 1 (no children) and then 4. Minor 2 promotes 3
  black, and a pressure finish drains and hands off. At `H_Free`, 2 is in `t0Reach` but unmarked.
  In this short form 2 is garbage by then, so no live object is lost.
- **`p1_violation_live` → `NoLostObject`** (timeline (a) as written). The steps: minor 1 and t0.
  `r2 := 1.f`, so the mutator holds 2. `1.f := Nil`. The marker scans 1 after the write. Minor 2,
  a pressure finish, and `H_Free` frees 2 while `r2` points at it.
- **`no_alloc_black` → `IM2`** (timeline (b)). The steps: minor 1 ages 3, and t0 greys `{1, 4}`.
  The marker scans 1 and 4. Minor 2 promotes 3 without marking it. A pressure finish, then at
  `H_Free` 3 is live (via `r2`), old and unmarked.
- **`release_during_cycle` → `IM1`** (timeline (c)). The steps: minor 1 and t0 (grey `{1, 4}`).
  `r1 := 1.f` makes 1 unreachable, with `r1` holding 2. A runtime path frees 1 before it is
  scanned. The marker skips the freed entry and scans 4. Minor 2, a pressure finish, then at
  `H_Free` 2 is live and unmarked.
- **`skip_young_walk` → `IM1`** (timeline (d)). The steps: minor 1, then t0 without the young walk:
  grey `{1}`, so 4 is not greyed. The marker scans 1 and 2. Minor 2 promotes 3 black, and black
  objects are never scanned. A pressure finish, then at `H_Free` 4 is reachable through 3 and
  unmarked.
- **`MC_quick_region` → `MarkerFootprint`** (CR-017, region mode). The steps: minor 1 ages 3. Drop
  `r2`, so 3 is dead. A STW major frees 4, which only the dead 3 referenced. Minor 2 hands 3's
  extent over and keeps the dead 3 as a zombie. The trigger fires, and t0's young walk greys the
  freed 4 (grey `{1, 4}`, `t0Old = {1, 2}`).

The other mutants were read too: each is the plan's story, in its shortest form.
- `lazy_external`: the store is overwritten with `Nil` after t0, before any late read.
- `skip_ylos`: the live YLOS cell itself is left unmarked.
- `hidden_root`: it resurfaces the old garbage object 4.
- `promote_ignores_builder`: it uses the free id 6: builder 6, age it, allocate 5, `6.f := 5`,
  promote 6.
- `handoff_skips_drain`: the full schedule, handing off at minor 4 with greys left.

### Changes from the plan's sketch (plan §4.5), and why

1. **A TLC evaluation error in the sketch.** The builder write's guard
   `await root[r2] = Nil \/ ~builder[root[r2]]` applied `builder` to `Nil`. TLC evaluates both
   sides of a disjunction in an action to enumerate successors, so the left side does not guard
   the right. SANY cannot see this. Fix: `IsBuilder(v) == v # Nil /\ builder[v]`.
2. **The quick bounds.** The plan's `MaxOps = 2` per epoch over four epochs gave more than 6.6
   million distinct states after two minutes, still growing. Measured: 4,893 states with no
   mutator operations, 168,649 with one per run, 2,915,545 with two. Each operation multiplies the
   space by about 17 to 34. New constants:
   - `MaxTotalOps` (the operations per run);
   - `Ops` (the operation kinds explored).

   Every quick configuration explores every kind with two operations per run. Each mutant enables
   only the operations its story needs. That is sound for a negative control, because removing
   behaviours cannot create a violation.
3. **Dead-state hygiene** (primer §4.2). A free resets the freed id's fields, age, builder flag and
   mark, and `mark` and `grey` are cleared outside a cycle. A freed id's `gen` is kept, because
   CR-017's path reads it. The state count barely changed, and the model got simpler to read.
4. **`ReachIn`**: an early-stopping `RECURSIVE` fixpoint (TLC only), in place of the `|Obj|`-round
   recursive function. It gives the same state counts and is about 4× faster (`MC_quick`: 84 s →
   20 s on 10 workers).
5. **Mutants added** so that every invariant and property has one (rule A6). The plan's table had
   none for `NoLostObject`, `DeferredOK` or `CycleEnds`:
   - `p1_violation_live` targets `NoLostObject`;
   - `defer_live_ylos` targets `DeferredOK`;
   - `closing_never` targets `CycleEnds`.
6. **`CycleEnds` needs the mutator's procedure steps under fairness.** PlusCal's `Mutator` action
   excludes its procedures, so the fair action is `MutatorAll`.
7. **`SnapshotLemma.tla`** (the plan's §4.7) was written for Apalache. Its results and changes are
   in the next section.

### The snapshot-closure lemma (`SnapshotLemma.tla`, plan §4.7)

Apalache 0.62.2, 5 objects, 1 field, 2 roots, 1 store. The inductive step was checked one action
at a time, 10 to 12 checks in parallel on 12 cores. The times are wall-clock under that load.

| Check (`lemma/*.args`) | Expected | Result | Time |
|---|---|---|---|
| `base5`: `LemmaInv` holds in the starting heap | pass | pass | 30 s |
| `step5_<A>`: `LemmaStep` for each of the 15 actions | pass | **pass, all 15** | from 5 min (`Handoff`) to about an hour: `MinorT0` 64 min, `MinorCycle` 62 min, `BWrite` 33 min, `MinorIdle` 30 min, `Alloc` 25 min, the rest 7 to 22 min |
| `im2_5`: `LemmaImpliesIM2` in every state satisfying `LemmaInv` | pass | pass | 20 s |
| `neg5_P1Write`: a kernel write to an old object | violates `LemmaCoreStep` | as expected | 67 s |

**Verdict: `LemmaInv` is an inductive invariant of the heap actions for 5 objects.** It holds in
the starting heap, and every one of the 15 actions preserves it from any state that satisfies it.
So it holds in every reachable state, with no bound on time or on the number of cycles. With the
grey set empty it implies IM2: every reachable old-gen cell is marked. The snapshot-closure lemma
(`SnapshotClosure`) and the marker's completeness are proved at this heap size, not just
model-checked.

The module text that was checked is the committed one, except for two things. The header comment
changed, and `P1Write` / `LemmaCore` / `LemmaCoreStep` were added. Those definitions are outside
`Next`, `Init`, `IndInit`, `LemmaInv` and `LemmaStep`. Every checked copy was diffed against the
committed file.

The negative control fails in `OldSHClosed`, not in `FieldsFrozen` (which only restates P1, and
is left out of `LemmaCore` on purpose). The counterexample: post-t0 black 3 → t0-old 4, and the
write `4.f := 3`. So S_H's old graph is no longer closed under fields. That conjunct is where P1
enters the argument: it is what makes "trace today's heap" equal "trace the t0 graph". So the
lemma needs P1 beyond the statement of P1 itself.

**How the lemma was made checkable.** Each problem was found in a run and fixed:
1. **The plan's `LemmaInv` was not yet inductive.** Four counterexamples to induction (CTIs), all
   from unreachable states:
   - `AgeOrder` must cover only **live** young objects. A dead object can point at a freed id
     that a later allocation reuses. This was found by hand while writing the module.
   - An idle state needs `IdleClean`: no greys, no deferred frees, no marks. Also found by hand.
   - `YlosShapes`: `deferred` and `t0Ylos` hold young large objects only. The first run's CTIs
     for `MinorCycle` and `Handoff` both started from an old or non-YLOS id in `deferred` or
     `t0Ylos`.
2. **The encoding stalled Z3.** Reachability was a fold of set comprehensions over symbolic sets,
   and `Live` and `WhiteReachable` repeat it in several conjuncts. No single action's step
   finished in 35 minutes. The rewrite:
   - reachability became a boolean vector over the concrete ids, iterated N times;
   - `SuccIn` and `Held` became filters over `Obj`;
   - `WhiteReachable` became one vector from the whole grey set, instead of a fold per (object,
     grey) pair. The two are equivalent.
3. **Checking the type predicate stalled.** `x \in SUBSET Obj` as a *checked* conjunct makes
   Apalache expand the powerset. The module keeps `TypeGen` for generating `IndInit`, and
   `TypeInv` (`\subseteq`, pointwise ranges) inside `LemmaInv`.
4. **The inductive step is an action invariant** (`LemmaStep == LemmaInv'`), checked on the
   transition only, one action per run. Otherwise Apalache first re-checks all of `LemmaInv` on
   the `IndInit` state, which is true by construction and was the costliest query.

**Scope.** 5 objects, not the plan's 6 then 8: at N = 5 the slowest action already takes about
an hour on a loaded machine (`MinorT0`, `MinorCycle`). N = 6 is the next step; run it overnight with
`run_models.py --tier deep --config lemma/`, after changing `CInit5` to `CInit6` in the
`.args` files. The lemma covers legacy mode only, because region mode has CR-017.

### Not done in this step

- The canary (`TLA-REGION` markers, `test/tla/manifest.txt`, `tla-canary`): parent plan Step 1.
- Trace validation (plan §8): hooks, the cycle projection, and the tiny-graph driver.
- The weak-memory companions W3/W4 (M1's A4 row).

## 2026-09-29 — trace validation (plan §8, rule A5)

**Tree:** 2026-09-29 (post-7c, with the compiled-out `ECO_TLA_TRACE` hooks added this day).
**Tools:** the dev image: tla2tools 1.8.0 with CommunityModules (Json, IOUtils), g++ 12, cmake,
ninja. The shared infrastructure (hooks header, recorder, merger, `common/Trace*.tla`, runner,
`tla-trace`) is described in `test/tla/README.md`, "Trace validation"; the events and hook points
in MAPPING.md §10.

### What was built

- **Hooks** (compiled out unless `-DECO_TLA_TRACE=1`) in `ThreadLocalHeap.cpp` (`minorGC`,
  `majorGC`, `startMarkCycle`, `finishMarkCycleNow`, `completeMarkCycle`), `OldGenSpace.cpp`
  (`greyObject`, `scanEntry`, `runPostMarkTail`, `beginMarkCycle`, `launchBackground`,
  `reapBackground`, `assistEpisode`, `closingFinish`, `runCycleStepConcurrent`) and
  `GCHelperPool.cpp` (`GCMarkGang::memberLoop` / `run`, `GCBackgroundGang::memberLoop` / `launch`
  / `joinLocked`, `stopAllForFork`). The production objects compile unchanged: with the build
  tree's own flags (clang, `-O2`, asserts on), the preprocessed `EcoRuntimeStatic` sources of the
  three files contain no trace token, only one `((void)0);` per hook.
- **(a) Cycle projection**: `TraceCycle.tla`, on the trace build of `heap_driver.cpp`
  (`gc-heap-trace cycle <scenario>`): 200 steps, a cycle forced every 20 minors (the old graph of
  60,000 pairs), a mutator fork two or three steps after each t0, an explicit major every 60 steps
  mid-cycle. Five scenarios: `legacy-b2` (B = 2, T = 4), `legacy-b4-t8` (B = 4, T = 8),
  `parminor-b2` (4 parallel minor workers), `region-b2` (region nursery, mode 2) and
  `pressure-b2` (a 20 MiB heap: cycles start on global pressure and about half end on the
  pressure finish).
- **(b) Tiny graph**: `TraceHeap.tla`, on `test/gc-heap-tsan/tiny_graph.cpp`
  (`gc-heap-trace tiny <seed> <steps> <B> <T> <jitter>`): at most 8 Tuple2 objects (one pointer
  field; the id in the unboxed field), two roots, an external root scanner as `c1`, random loads,
  drops, store writes and reads, chain-shaped allocations, triggers, forks and majors, with the
  background members started up to `jitter` µs late so that they scan while the mutator runs.
- **Negative controls**: each trace spec has doctored-log rows (`mutate=`) that must be rejected.

### Results (`tla-trace`, 2 rows at a time, 2 TLC workers each)

| Row | Events | Expected | Result | TLC states | Time |
|---|---|---|---|---|---|
| (a) `cycle,legacy-b2` | 340 | accept | accept | 5,798 | 2.7 s |
| (a) `cycle,legacy-b4-t8` | 384 | accept | accept | 7,688 | 2.7 s |
| (a) `cycle,parminor-b2` | 302 | accept | accept | 4,537 | 2.8 s |
| (a) `cycle,region-b2` | 347 | accept | accept | 6,086 | 2.5 s |
| (a) `cycle,pressure-b2` | 495 | accept | accept | 10,032 | 3.2 s |
| (a) `legacy-b2`, `drop:closing:1` (no closing join at k = T) | 339 | reject | reject at event 19 of 339 | 393 | 1.9 s |
| (a) `legacy-b2`, `set:step:2:k=5` (a wrong k) | 340 | reject | reject at 12 | 272 | 1.7 s |
| (a) `legacy-b2`, `drop:minor:6` (a handoff without its minor) | 339 | reject | reject at 20 | 398 | 1.9 s |
| (a) `pressure-b2`, `swap:pressure:1` (a reap before the pressure decision) | 495 | reject | reject | 7,451 | 2.5 s |
| (b) `tiny,1,60,2,2,300` | 313 | accept | accept | 1,586 | 3.2 s |
| (b) `tiny,3,80,2,4,2000` | 417 | accept | accept | 2,395 | 3.4 s |
| (b) `tiny,14,80,1,4,1500` | 436 | accept | accept | 2,045 | 3.2 s |
| (b) `tiny,25,80,2,3,800` | 465 | accept | accept | 2,882 | 3.7 s |
| (b) `tiny,25`, `drop:scan:1` (a scan that never happened) | 464 | reject | reject | 198 | 2.4 s |
| (b) `tiny,25`, `set:t0end:1:greys=99` (a wrong snapshot) | 465 | reject | reject at 7 | 30 | 2.2 s |
| (b) `tiny,25`, `set:heap:1:old=510` (a heap the model cannot have) | 465 | reject | reject | 58 | 2.3 s |
| (b) `tiny,25`, `set:marks:1:marked=510` (a liveness decision the model cannot make) | 465 | reject | reject | 302 | 2.5 s |
| (b) `tiny,25`, `drop:closing:1` | 464 | reject | reject | 285 | 2.4 s |

18/18 as expected in 26 s. The logs depend on the schedule, so every run is different. Beyond
the registered rows: 15 more cycle runs (each scenario three times) and 24 more tiny-graph seeds
(B = 1 or 2, T = 2 to 4, jitter 100 to 2,200 µs) were all accepted. Across those runs the logs
held every cycle path M1 has: scheduled handoffs, pressure finishes, joins (a major during
marking, and after the closing), fork stops with and without work left (relaunch or finished),
stops after the members had already finished, early done, assists, closings with and without
work, and, in (b), scans by the background members and by the mutator as member 0 of the
in-pause gang runs (676 and 49 scans in the kept logs).

### Finding: a model error, fixed

**The model's assist could not stop while grey entries were left.** Trace (a) rejected
`pressure-b2` and `parminor-b2` runs at the same pattern: a step with an assist, then a fork stop,
then at the next step `reap done = false`, `relaunch`: the code still had work. The model could not
relaunch, because its `A_Loop` (`while n < AssistMax /\ grey # {}`) had to scan until the grey set
of the static heap was empty. The code's assist does not: an Assist leaves as soon as its own grey
set is empty and a steal finds nothing ("never idles: leave", `runMarkerLoop`,
`MarkWork.hpp:461-462`), so it scans fewer entries than its budget while other entries sit in the
background members' private stacks and rings; and one that joins a stopped control scans nothing.
The model was more restrictive than the code (it missed behaviours), a gap the model checks could
not see.

Fix: `A_Loop` may leave early (`either` scan `or goto A_Done`). PlusCal re-translated; MAPPING.md
§2, §3 and §8 updated. `run_models.py --model M1`: **18/18 as expected** in 100 s (2 × 2 workers);
`MC_quick` 3,005,665 states (was 2,915,545), `MC_quick_region_nomajor` 1,066,396 (was 1,028,216),
`MC_quick_sync` 216,800 (unchanged), every mutant still fails with its target. The deep tier was
not re-run: every configuration uses `AssistMax = 1`, where an assist that stops at once reaches
the same state as P_Decide's "no assist" branch (only `pc` differs), so the reachable heap, cycle
and episode states, and with them every invariant's verdict, are unchanged. The lemma
(`SnapshotLemma.tla`) has no `Assist`: its `Scan` action covers every scan.

### Found on the way (harness and spec, not the model or the code)

- `MaxMinors` equal to the log's number of minors stopped the model's mutator loop before the
  log's last operations: the trace specs use the count plus one.
- Outside a cycle the mark bitmap is not the allocation record (reachable old objects read 0 after
  a handoff or a STW major), so "unreachable and bit clear" cannot tell a free after the pause.
  The driver reads the marks with a probe at `runPostMarkTail`'s entry, where they are the
  liveness decision.
- A STW major moves nothing: an unreachable young object stays until the next minor.
- A `.cfg` bound computed over the whole log made TLC's initial states take 25 s; the merger now
  counts events in the header (`TraceCount`).

### No code defect found

Every run of the real allocator is a behaviour of M1 at the projection of (a) and at the object
level of (b): the snapshot's greys, every scan, every mark at every handoff and STW major, every
promotion and every free agree with the model, in legacy mode, with 1 or 2 background members,
fork stops and joins.

### Limits

- (b) runs legacy mode only, without young large objects, builders or pressure finishes; region
  mode is in (a) only (CR-017 stays M1's `quick_region`).
- In (b) the second foreground member (`eco-mark1`) never took work: the mutator, as member 0 of
  the assist and closing runs, scanned every in-pause entry. The spec maps a foreground member's
  scan like the mutator's (`A_Loop` / `D_Loop`), but no log has exercised that case yet.
- Allocate-black is checked through its effect (a promotion left unmarked would be freed at the
  handoff, and `marks` and `heap` would differ from the model), not event by event.
- Mark bytes are not ordered: a `grey` logs no byte value. M1's steps on different objects commute,
  and bytes are M4's (its trace can add `rmw` fields; the merger chains them).
- The fork stop comes from the mutator between pauses (a real `fork()`), never from another
  thread during a pause (CR-003/004/005 are M6's).

### Not done

- The canary lines for M1 (`TLA-REGION` markers, `test/tla/manifest.txt`): parent plan Step 1.
  The hooks sit inside functions M1's A9 row lists; a pin taken before them sees them as a change.
- The weak-memory companions W3/W4: see MAPPING.md §7.

## 2026-09-29 — canary baseline (GC_MODEL_001)

The canary (`test/tla/manifest.txt`, `tla-canary` in every build) was first pinned today: 69 pins
name this model (8 census, 3 file, 19 grep, 39 region); the list is in MAPPING.md's "Canary pins (A9)" block. This is the
baseline: the pinned code is the code this model was checked against today (after the trace hooks,
wave 3's fixes and the `TLA-REGION` markers landed). From now on, a pin that fires needs an entry
here quoting the new hash prefix before `check-tla-manifest.sh --update` accepts it.

## 2026-09-29 — the snapshot-closure lemma at 6 objects (partial; stopped)

The same `lemma/*.args` checks with `CInit6` in place of `CInit5` (Apalache 0.62.2, `nice -n 19`,
two to eight at once on the shared 12-core machine). Stopped on the owner's request after about
10 hours; the unfinished steps were not run to completion.

| Check | Result | Time |
|---|---|---|
| `base` (LemmaInv holds in the starting heap) | pass | 12 s |
| `im2` (LemmaInv implies IM2) | pass | 126 s |
| `neg_P1Write` (P1 broken) | violates `LemmaCoreStep`, as expected | 56 s |
| step `Alloc` | pass | 15,108 s (4.2 h) |
| step `BAlloc` | pass | 11,037 s (3.1 h) |
| step `Closing` | pass | 10,622 s (3.0 h) |
| step `CellW` | pass | 14,108 s (3.9 h) |
| steps `BClear`, `BWrite`, `CellR`, `Drop`, `Scan`, `MinorT0`, `MinorCycle` | stopped unfinished (up to 4.6 h in) | — |
| steps `Load`, `Handoff`, `MajorIdle`, `MinorIdle` | not started | — |

So at 6 objects the base case, the IM2 consequence, the negative control and 4 of the 15 inductive
steps check out; the lemma is **proved** only at 5 objects (above). Each step costs 3–4+ hours
here at 6 objects, against 5–64 minutes at 5, so 8 objects is out of reach on this machine. The
nightly workflow (`.github/workflows/tla-nightly.yml`, `lemma` matrix) runs the 5-object rows.


## 2026-09-29 — ABA audit: a freed cell reused at the same id

**Why:** register CR-034, a structure that remembered an object by address after a STW major freed
it (ABA). The models name objects by logical ids, so they rarely reuse an id while something still
refers to it. This entry checks M1's scope: deferred frees, the t0 YLOS snapshot, the cycle's grey
entries and the cycle blocks. **Tree:** 2026-09-29.

### Code verdicts (M1's scope)

- `deferred_frees_` (`OldGenSpace.hpp:1501`; filled `sweepNurseryLargeBodies` `OGS:7656-7661`,
  consumed `processDeferredFrees` `OGS:5077-5085` at the handoff, before reclaim): **safe**. The
  deferral unlinks the index key and recycles the id, but the cell stays allocated until the
  handoff, and IM5 (no release during a cycle) keeps its block. No other object can occupy the
  address, so `freeLargeBodyCell`'s erase by address hits the same cell. The model says the same
  with `DeferredOK` (`deferred ⊆ alloc`).
- The t0 YLOS set (`snapshotYoungLarge` `OGS:4426`, validate-only `mark_view_.ylos_t0`):
  **safe**. A t0 YLOS is either promoted in place (the same object) or deferred when it dies, so
  its address is never reused before the handoff (`NoReleaseInCycle`).
- `cycle_alloc_log_`, `cycle_t0_reach_`, `im11_t0_greys_` (validate-only): **safe**, for the same
  reason (no free of a logged cell during a cycle; the checks run before the handoff frees).
- `nursery_visited_` (`OGS:3345`): **safe**. It is cleared by every `prepareMark` (`OGS:3051`) and
  used only by a serial STW mark, inside one pause, while nothing moves.
- **The cycle's grey entries: hazard, a consequence of CR-017.** The t0 walk can grey an old cell
  that a STW major freed (CR-017). That grey entry is an address kept across a point where the cell
  can be reused. During the cycle the cell is handed out again through the mixed free lists:
  `allocateFromSizeClassBitmap` rungs 2 and 4 (`OGS:977`, `:988`) and `allocateFromBagPage` step 1
  (`OGS:2581`). `prepareMark` does not clear the free lists at t0. A background marker that pops the
  stale entry after the reuse scans the new object, because `scanObject` skips only `Tag_Free` and
  `Tag_Forward` (`OGS:3599`). The new object may be:
  - a YLOS being filled by the mutator, or with young children. Then `greyObject<ParallelMark>`
    aborts in every build ("parallel marker reached nursery object", `OGS:3310-3313`);
  - a promoted copy in the middle of its minor. Its fields still name from-space objects until the
    copy is scanned.

  Either way the marker's reads race the writer's plain writes (S2). Validate builds abort earlier,
  in IM4 (`assertCellWasWhite`), at the pop. CR-017's fix removes the stale entry and this with it.

### Model changes

- **New invariant `MarkerNoYoungKid`** (MODEL_M1_2): `MarkerFootprint`'s second conjunct, on its
  own. A marker never holds an allocated object with a young child. It is split out so that a
  configuration can target the reuse consequence: in CR-017's configuration the first conjunct
  fails at t0, before any reuse.
- **New configurations.** Each puts the old id 4 in `YlosIds`, so the mutator's `alloc` may give
  the freed old cell 4 to a young large object. That is the one mutator allocation that lands in an
  old-gen cell. No new constant; the existing rows are unchanged (`MC_quick` still has 3,005,665
  states).
  - `MC_quick_reuse` (legacy, one STW major, all nine invariants plus `MarkerNoYoungKid`): **pass**,
    2,976,835 states, 82 s on 2 workers.
  - `MC_quick_region_reuse` (region, one STW major, the story's operations): **violates
    `MarkerNoYoungKid`**, 126,734 states, 20-state counterexample. Minor 1 ages 3 (alive through r2).
    The mutator allocates YLOS 5 into r2, so 3 dies. A STW major frees 4. Minor 2 keeps the dead 3
    as a zombie. The t0 walk greys the freed 4 (CR-017). The mutator reallocates 4 as a YLOS whose
    field is 5, while the stale entry is still grey. This is exactly the code chain above.
  - `MC_quick_region_reuse_live` (the same bounds, the other eight invariants): **pass**, 3,721,152
    states, 111 s on 2 workers. In M1's abstraction the stale grey plus the reuse loses no reachable
    object. The byte-level consequences are M4's (BitFaithful).
- **New mutant `defer_released`:** `P_Minor` releases a deferred cell at once but keeps it on
  `deferred`, so `H_Free` frees whatever holds the id by then. It **violates `NoLostObject`**:
  291,679 states, 28-state counterexample (t0; YLOS 5 allocated and dropped; the next minor defers
  and releases 5; 5 is reallocated and rooted; a pressure finish frees it). This shows M1 would see
  the ABA if the code ever released a deferred cell early.
- `MAPPING.md` §3 (the reuse row), §5 (`MarkerNoYoungKid`), §8.

### Results

- `run_models.py --model M1` (quick tier, 2 × 2 workers): **22/22 as expected** in 230 s. Every
  earlier row's state count is unchanged (`MC_quick` 3,005,665; `MC_quick_region_nomajor`
  1,066,396).
- New rows (runner counts): `MC_quick_reuse` pass, 2,976,835 states; `MC_quick_region_reuse`
  violates `MarkerNoYoungKid`, 121,924 states; `mutants/defer_released` violates `NoLostObject`,
  298,511 states; `MC_quick_region_reuse_live` pass, 3,721,152 states.
- `run_traces.py --model M1`: **18/18 as expected** in 23 s. The trace specs extend the model, and
  the new invariant and mutant branch do not change them.

Register: the stale-grey reuse is a new consequence of CR-017, reported to the orchestrator as a
candidate entry. It flips to `pass` together with `MC_quick_region` in CR-017's fix.
