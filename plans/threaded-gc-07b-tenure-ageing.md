# Threaded GC 07b — Tenure ageing in the region nursery (lever L1)

**Status:** DONE (2026-09-28). Built, gated and measured; **the default stays k = 1** (§7.4):
ageing cuts promoted bytes (−7 % at k = 2, −12 % at k = 3) but costs wall (+6.0 / +11.3 s) and
pause p99 (28 → 46 / 71 ms), and the old-gen peak follows the major trigger, not the ageing.
`promotion_age = k` (2 or 3) enables it in region mode. Loop entries `TA` (v1) and `TA2`.
Implements `plans/threaded-gc-07-concurrent-tenuring.md` P§12 (lever L1: tenure age k > 1, in-place
ageing), with the design corrections in §2 below. Loop entries: `TA2`, `TA3` (tenure age 2, 3)
in `benchmarks/gc-opt-loop.md`, judged against `TG7d`.

**Naming.** Phase 07's own sub-parts are "7b" (survivor regions) and "7c" (concurrent tenuring).
This plan is *phase 07b* as a file name only; in text it is "tenure ageing" or "L1".

---

## 0. Goal and premise

With k = 1 (TG7d) an object copied into the fill at minor j is handed over at minor j + 1 and
tenured if live then: it is tenured at its second minor. With tenure age k it stays in its survivor
extent (never copied again) until minor j + k and is tenured only if live then. Objects that die
during minors j + 1 … j + k − 1 are never promoted.

**Premise (existing data, Sep 22, legacy nursery, `promotion_age` 1/2/3):** age 2 cut the old-gen
peak by about 13 % relative to age 1, but legacy pays for it with a second in-pause copy (nursery
copies 0.71 → 1.37 B, wall +17.7 s). Ageing *in place* keeps the promotion saving without that
copy. What it costs instead is collector work: a mark through the ageing extents at every
hand-over (§2.4). The experiment (§6) measures whether the saving pays for that.

## 1. Configuration

- **`promotion_age` is the region tenure age k.** Region mode no longer requires
  `promotion_age = 1`; it accepts 1 … 3 (the same range as legacy, whose header age field is 2
  bits). Legacy `promotion_age = k` is then the oracle for region `promotion_age = k` (§5, E1).
  The default stays 1; `nursery_regions = 2` (auto) keeps resolving to regions.
- **Extents:** a heap owns `n = k + 3` extents (`k + 4` with eden flip): eden (or two), the fill,
  k − 1 ageing extents, the hand-over extent and the retiring extent. `regionExtents()` returns
  this. `k = 3` with flip gives 7; role tables are sized 8.
- **One collector for k ≥ 2.** The mark (§2.4) runs on the exact engine only. With k ≥ 2 the
  launch never uses the L3 concurrent-parallel engine; `tenure_collector_threads > 1` is ignored
  (recorded in the stats as `age_forced_exact`). Help and the grant fallback finish the mark
  serially before the parallel engine takes the tenure phase (§3.6).

## 2. Design

### 2.1 Extent states and roles

`XState` becomes `{Free, Young, Tenuring}` plus `Extent::age` (1 … k) for Young extents.

| at minor m start | role in the minor | at minor m end |
|---|---|---|
| Free (one of them) | **Fill** (G_m) | Young, age 1 |
| Young, age a < k | **Age** (survivor part); the age-1 extent's builder area is **PrevBuilders** | Young, age a + 1 |
| Young, age k | **Hand** (survivor part); with k = 1 its builder area is **PrevBuilders** | Tenuring |
| Tenuring | **Retire** | Free |

Between minors `roleOf` returns **Fresh** for the age-1 extent (survivor part and builder area),
**Aged** for Young extents with age ≥ 2 (survivor part only; their builder areas are Stale), and
**Tenuring**. `HandBuilders` is renamed **PrevBuilders**: it is the builder area of the extent
filled at the previous minor, which is the Hand extent only when k = 1.

### 2.2 The pause (minor m)

Unchanged for Eden, PrevBuilders (copy), Hand (record into S or H), Retire (resolve), Fill.
New:
- **A reference into an Age extent is recorded as a target in `SA`** (per worker, merged in worker
  order into `pend_SA`), whatever holds it: roots, builders, fill copies, young YLOS. It is never a
  heal slot: the holder is either a root/builder (rescanned every minor) or a fill copy, which the
  hand-over job of the target's extent finds by marking (§2.4).
- **YLOS of the ageing generations.** The hand-over preparation re-marks (colour) the YLOS
  objects and the large bodies of the Hand extent *and of every Age extent*, so the minor's sweep
  frees none of them before their generation is handed over. It also builds `age_ylos`, the
  sorted snapshot of the ageing generations' YLOS objects. `reachYoungLargeR` checks `hand_ylos`,
  then `age_ylos` (a hit is pushed to `SA` and not scanned in the pause), *before* the colour
  test.
- **Worker count:** the builder bytes come from the previous fill (the age-1 extent, or Hand
  when k = 1).

### 2.3 The job's inputs

`starts = S` (Hand targets from roots/builders/hand YLOS), `heal = H` (slots of fill copies and
young YLOS that point into Hand), `ylos = hand_ylos` as today, plus:
- `age_starts = SA`;
- `age` ranges: for each Aged extent at launch (the Age extents of minor m, now age 2 … k): base,
  survivor top, and a job-private mark bitmap (1 bit per 8-byte granule, bits
  `[0, (surv_top - base) / 8)` cleared at launch);
- `age_ylos` with a per-entry marked flag.

### 2.4 The job: mark, sweep, tenure

The exact engine gains two phases before the existing ones. Both are resumable (all state in
`SerialState`) and stop only between items, so the engine stays exact.

1. **Mark** (items: one `age_starts` entry, or one popped object). Marks every object in the Age
   extents and every `age_ylos` object reachable from `age_starts`, scanning each once,
   read-only. For each child slot `s` of a marked object:
   - target in an Age extent: mark it, push it;
   - target in `age_ylos`: mark the entry, push it;
   - target in Hand: append `s` to `heal` (it is both a tenure start and a heal slot);
   - target in `hand_ylos`: `reachYlos` (scanned by the tenure phase, as today);
   - any other nursery address: TV6 (every build) — a live object points into a retired or stale
     extent;
   - otherwise (old, permanent, constant): ignored.
2. **Sweep** (items: one bitmap word). A scan of each Age extent's mark bitmap in address order;
   the **gap** before each marked object (dead objects, LAB fillers, earlier zaps) is appended to
   `zap` as a span `(address, bytes)`, and so is the gap after the last one. Only marked objects'
   headers are read (for their sizes). *As built (v2):* the first build walked every object
   header of the extent and zapped object by object; that sweep was the dominant cost of a late
   job's help (§7).
3. **Tenure**: the existing phases (stack, starts, heal, YLOS) unchanged. `heal` now also holds the
   mark's slots.

**Why the mark (nepotism, P§12.2):** a slot recorded when its holder was copied says nothing about
whether the holder is still live k − 1 minors later. Treating recorded holders as roots would
tenure young garbage. The mark derives the live holders from this minor's sources only.

### 2.5 The merge (start of minor m + 1)

As today, plus, after the census check and the heal:
- **Zap:** every span in `zap` gets one Tag_Free filler header of its size (the header write
  only; `NurserySpace::writeFiller`). Spans are layout class (adjacent dead objects merge); the
  dead *bytes* are object class.

**Why zap (the stale-holder problem).** With k = 1 every object left in a survivor extent between
minors was live at its last minor or dies with its extent within one minor. With k ≥ 2 a dead
object can sit in an ageing extent for k − 1 more minors. Its slots may name a Hand object that
was not tenured (retired next minor), a hand-generation YLOS object that the merge frees, or an old
object that a STW major freed. Three pause-time walkers read every object of the young extents:
the t0 young walk (greys old children conservatively), the P1 census, and the TV validators. A
dead object with a dangling slot makes the t0 walk grey freed memory. Zapping at the merge after
each hand-over means an object dead at hand-over h is gone before any walker runs after minor
h + 1's merge, which is the same window k = 1 already has for its Tenuring extent (an object dead
at minor h lives until its extent retires at h + 1). A STW major at pause p and the job of p see
the same roots, and no t0 walk runs in the pause of a STW major, so nothing between p and the
merge at p + 1 reads a zapped-to-be object's children.

**Why not in the collector:** the census re-hashes every recorded survivor before the heal; a
collector-side header write would be a census mismatch and would break FORBID_HEAP_004's literal
form. The pause cost is one 8-byte store per dead object (E3 measures it as `zap_ns`).

### 2.6 YLOS and large bodies

- A YLOS object first reached at minor j joins generation j (its extent's `ylos_gen`), is
  re-coloured at every minor until j + k, and is handed over with G_j. At the hand-over it is
  promoted in place if the tenure job or the mark reached it, otherwise freed by that minor's
  sweep, exactly as today. Every holder that is dead at the hand-over is zapped in the same merge
  that frees it, or retires in the same minor.
- Large bodies of headers in Age extents are re-marked at every minor until their extent's
  hand-over. A dead header's body is freed after that hand-over; the header was zapped.

### 2.7 Majors

- **t0 young walk** (`forEachYoung`): the survivor parts of all Young extents and of Tenuring,
  plus the builder area of the age-1 extent. Zapped objects are fillers and skipped.
- **STW major:** joins and merges the job first (zap included), as today. Unchanged otherwise.
- **`majorRedirect`**: unchanged (Tenuring only).

### 2.8 Invariants (amend in Step 9)

- **HEAP_069:** k = `promotion_age`; n = k + 3 (+1 with flip); the role table of §2.1; the
  zap rule: between minors, every non-free object of a survivor extent was live at the last
  hand-over mark or was copied at the last minor.
- **HEAP_070:** the mark and sweep phases; `heal` includes the mark's slots; the merge zaps.
- **FORBID_HEAP_004:** unchanged (the collector writes only its mark bitmaps, shadow, grant
  cells and private state; zapping is pause work).

---

## 3. Implementation steps

Each step names files and functions. `R.n_surv = k + 2` survivor extents.

### Step 1 — Config (`AllocatorCommon.hpp`, `HeapConfigJson.cpp`)
- `regionTenureAge()` = `promotion_age`; `regionExtents()` = `k + 3 + flip`.
- `regionIncompatibility()`: drop `promotion_age != 1`; keep the rest.
- `NurseryRegions.hpp`: `constexpr int kMaxSurv = 5` (k ≤ 3), `role_of_k[8]`.

### Step 2 — Region state (`NurseryRegions.hpp`)
- `Extent`: `age` (0 when not Young); `std::vector<uint64_t> mark_bits` (job-private while a job
  runs).
- `XState { Free, Young, Tenuring }`.
- `RegionState`: `x[kMaxSurv]`, `shadow[kMaxSurv]`, `n_surv`, `k`, `prev` (in-minor: the previous
  fill's index), `prev_bld_off`, `pend_SA`, `age_ylos`, and `extentOf` over `n_surv`.
- `Role`: rename `HandBuilders` → `PrevBuilders`; add `Age` (in minor) and `Aged` (between).
- `RegionWorker`: `SA`.
- `TenureJob`: `age` ranges (`struct AgeRange { char* base; char* top; uint64_t* bits; }` × ≤ 2),
  `zap` vector, `age_ylos` copy with flags.

### Step 3 — Ring and minor (`NurseryRegion.cpp`)
- `initRegions`: n_surv extents at `k = n_ext - n_surv + i`; shadows for each.
- `rebuildRoles`: §2.1's table; `roleOf` returns PrevBuilders for `k == prev_k && off >= prev_bld_off`.
- `minorGCRegion` beginMinor: classify (Hand = Young age k, Age = Young age < k, Retire =
  Tenuring, Fill = a Free one); TV10: at most k + 1 non-free.
- Hand-over prep: re-mark lb_bodies and ylos colours of Hand and Age extents; build `hand_ylos`
  (Hand gen) and `age_ylos` (Age gens).
- `evacuateR`: `case Role::Age: rw.SA.push_back(obj); return;`; `case Role::PrevBuilders` = old
  HandBuilders; `reachYoungLargeR`: `age_ylos` hit → `rw.SA` (before the colour test).
- Merge per worker `SA` into `pend_SA`; stats `rs.age_starts`.
- PM2 validator: children of fill copies may be Fill, Age, Hand or NotMine.
- endMinor: Fill → Young(1); Age: age + 1; Hand → Tenuring; Retire → Free; TV10: non-free ≤ k + 1.
- `regionEndMinorValidate`: TV2 on Tenuring as today; **TV2Y**: every child of a non-free object in
  a Young extent that lies in the slot block is inside some Young/Tenuring survivor part (or the
  age-1 builder area).
- `regionAssertValidPointer` (TV7): Fresh → survivor part or builder area of the age-1 extent;
  Aged → survivor part of that extent; Age (in minor) → survivor part.
- `regionCheckAndGrow`, `syncRegionStats`, `forEachYoung`, `censusRecordRegion`: loop over
  `n_surv` and treat every Young extent (builder area only for age 1).

### Step 4 — Engine (`TenureWork.hpp`)
- `SerialState`: `age_starts`, `next_age_start`, `age_stack`, `age_ylos`, `age_ylos_marked`,
  `zap`, `sweep_x`, `sweep_p` (resumable sweep cursor), `mark_done`, counters `age_marked`,
  `age_marked_bytes`, `zapped`, `zapped_bytes`; `done()` includes the new phases.
- Env gains: `int ageIndex(const void*)`, `bool testAndSetMark(int i, const void*)`,
  `bool isMarked(int i, const void*)`, `int ageCount()`, `char* ageBase(i)`, `char* ageTop(i)`,
  `bool isFree(const void*)`.
- `SerialEngine::step()`: mark items, then sweep items, then the existing ones.
- `markChild(parent, slot)` per §2.4.1.

### Step 5 — Job (`NurseryTenure.cpp`)
- `tenureLaunch`: Tenuring index over `n_surv`; move `pend_SA` into `st.age_starts`; build
  `J.age` ranges from the Aged extents (clear their bits over `[base, surv_top)`); copy
  `age_ylos`; with k ≥ 2 force the exact engine (`conc_par = false`, count
  `rs.age_forced_exact` when B > 1).
- `TenureHeapEnv`: the new Env functions over `J.age`.
- `mergeJob`: after the heal, zap (serial, or on the gang above `heal_parallel_min`); stats
  `rs.zapped`, `rs.zapped_bytes`, `rs.age_marked`, `rs.zap_ns`; the MinorGCRecord gets
  `rg_zapped`.
- `runJobParallel` (help, fallback, sync parallel): if the mark phases are not done, finish them
  first with `finishJobMarkPhases(oldgen, n)`: on the minor's gang (`AgeParEnv`: atomic
  bitmap OR, per-worker heal / reached-YLOS lists merged in worker order), then the sweep in n
  bitmap-word chunks stitched in address order (TVZ in validate builds: the stitched spans equal
  the exact scan). *As built (v2):* the first build finished them serially in the pause.

### Step 6 — Stats (`GCStats.hpp/.cpp`)
- `RegionTenureCounters`: `age_starts`, `age_marked`, `age_marked_bytes`, `zapped`,
  `zapped_bytes`, `zap_ns`, `age_forced_exact`, `tenure_age`. The region banner block prints one
  line: `ageing: k=… marked … (… MB), zapped … (… MB, … s in pauses), age starts …`.

### Step 7 — TSan harness (`test/gc-helper-tsan/tenure_harness.cpp`)
- Env stubs for the new functions (`ageCount() = 0`), plus one scenario with a synthetic ageing
  extent: mark + sweep + tenure on the collector with stops, verifying the zap set equals the
  unreachable ageing objects and the heal set equals the live holders' Hand slots.

### Step 8 — Unit tests (`test/allocator/RegionMinorTest.cpp`, new `TenureAgeingTest.cpp`)
- `regionConfig(k, n)` gains the age; config validation accepts `promotion_age` 2 and 3 with
  regions.
- **Oracle (E1):** legacy `promotion_age = k` vs region `promotion_age = k`, forked child, same
  seeded mutator: per-minor promoted counts equal with the one-minor shift, for k = 2, 3 at N = 1
  and 4.
- **Ageing semantics:** an object live for exactly j minors is tenured iff j ≥ k (k = 1, 2, 3).
- **Nepotism:** a dead ageing holder of a Hand object does not tenure it.
- **Zap:** after the merge, a dead ageing object is a filler; a live one is intact; the t0 young
  walk visits only live-or-fresh objects.
- **Heal through ageing:** a live ageing holder's slot to a tenured object names the copy after
  the merge.
- **YLOS ageing:** a young large array reached at minor j and held by an ageing object survives
  until j + k and is promoted in place; one held only by a dead ageing object is freed.
- **Mode 1 = mode 2** at k = 2 (every counter), and with a forced stop / help.
- **Negative controls:** skipping the mark's heal append is caught (TV1 at resolve); disabling
  the zap is caught by the stale-holder validator.

### Step 9 — Docs
Invariants (§2.8), THEORY.md (region section: one paragraph), master plan row "L1 tenure ageing",
phase 07 P§12 pointing here, this plan's §7 as built.

---

## 4. Traps

1. **Colour before snapshot:** the hand-over prep colours ageing YLOS; `reachYoungLargeR` must test
   `hand_ylos` and `age_ylos` before `m->color == minor_color_` or an ageing member is treated as
   already reached and never recorded.
2. **PrevBuilders is not the Hand's builder area** once k ≥ 2. The worker-count space test and the
   rule table must use the previous fill.
3. **The mark bitmap covers `[base, surv_top)` only**, cleared at launch; an object is marked by its
   start granule.
4. **Zap after the census check and after the heal**; never zap an object in `heal` (impossible:
   heal holders are marked; validate asserts it).
5. **Hand objects never point into Age extents** (older → younger is impossible for immutable
   objects; builders stay in the fill). TV6 in the tenure phase keeps checking it.
6. **The fill's copies point into Age extents between minors** (recorded in SA); TV2Y must allow
   any Young/Tenuring survivor part.
7. **`regionExtents()` changes the slot geometry**: every heap slot is `(k + 3 + flip) × X`.
8. **The legacy oracle compares promoted counts only.** Survived counts are lower by design (no
   re-copies).

## 5. Gates

| gate | check |
|---|---|
| G1 | unit suite green (default and region pinned tests), new ageing tests |
| G2 | E2E `--target check` green at default (k = 1) and with `promotion_age = 2` via env config |
| G3 | validate build: unit, E2E and GC-pressure stress at k = 2 and k = 3, modes 1 and 2 |
| G4 | tenure TSan harness (incl. the ageing scenario) and `gc-heap-tsan`, 0 warnings |
| G5 | E1 oracle MATCH for k = 2, 3 |
| G6 | self-compile output identical (md5 933c3ff0d288…) at k = 1, 2, 3 |

## 6. Experiments

All arms: the TG7d default binary (stats build) and its phase-timer relink, no GC environment
except `ECO_HEAP_CONFIG={"promotion_age": k}` (equal-length values in every arm), strictly serial,
three runs per arm.

- **E1 (oracle):** unit-level, §3 Step 8.
- **E2 (ageing, main):** region k = 1 / 2 / 3: wall, GC time, pause p50/p99/p99.9/max (phase-timer),
  tenured objects and MiB, old-gen peak, max RSS, majors, collector busy/CPU, late %, marked and
  zapped counts, zap time.
- **E3 (legacy reference):** legacy `promotion_age` 1 / 2 / 3 (same binary,
  `ECO_NURSERY_REGIONS=0`): promoted MiB and old-gen peak — the retention the ageing is meant to
  buy — and the copy cost legacy pays for it.
- **E4 (retention sweep):** gf 0.65 / 0.70 / 0.75 at region k = 1 and the best k: old-gen peak and
  majors (the trigger is chaotic; one point is never evidence).

**Decision rule:** a k > 1 becomes the default only if it improves wall *or* old-gen peak by more
than the noise band without regressing the other beyond it, and pause p99 does not rise by more
than 10 %. Otherwise it ships default-off (k = 1) with the results recorded.

## 7. As built

### 7.1 What was built

Every step of §3. Two design changes (v2, loop entry `TA2`) after the first measurement (`TA`):
- **Gap sweep.** The first sweep walked every ageing object header and zapped object by object.
  The sweep now scans the mark bitmap and zaps each dead *gap* with one filler (§2.4). It reads only
  marked objects' headers. Spans are layout class, so the tests compare dead *bytes*.
- **Parallel help mark.** A late job's help first finished the mark and sweep serially in the
  pause. `finishJobMarkPhases(oldgen, n)` now runs them on the minor's gang (`AgeParEnv`) and sweeps
  in bitmap-word chunks. TVZ (validate builds) checks the stitched spans against the exact scan.

Also: the region nursery accepts `promotion_age` 1..3 (auto resolves to regions for all three);
the L3 collector members are not used with k ≥ 2 (`age_forced_exact`); the banner prints an
`ageing` line; `benchmarks/ta-summary.py` summarises arms.

### 7.2 Gates

| gate | result |
|---|---|
| G1 | unit 1946/1946, validate unit 1947/1947; 8 ageing tests (oracle, lifetime, nepotism + zap, heal through the mark, YLOS ageing, modes 1 = 2 with stops, help on 4 workers, negative control) |
| G2 | E2E 942/942 at k = 2 and 3 (default build, 1 and 4 workers) |
| G3 | validate E2E 942/942 (k = 3; k = 2 mode 1); validate stress 101/101 at k = 2 / 3, pressure and pressure-parallel configs, modes 1 and 2, jitter 50 µs |
| G4 | tenure TSan harness (with an ageing arena: mark set, zap spans, heal slots checked) 3 + 2 runs, one on 2 CPUs; `gc-heap-tsan` with k = 2 and k = 3 scenarios 3 + 2 runs, one on 2 CPUs; 0 warnings |
| G5 | E1 oracle MATCH for k = 1, 2, 3 at 1 and 4 workers (promoted counts, per-tag bytes, checksum; region survived < legacy survived for k > 1) |
| G6 | self-compile output 933c3ff0d288 in every run at k = 1, 2, 3 |

### 7.3 Measurements

Stats build `eco-optTA2`, three runs per arm, medians (full tables in `benchmarks/gc-opt-loop.md`, TA2):

| k | wall s | GC s | promoted MiB | old-gen peak MB (gf 0.65 / 0.70 / 0.75) | max RSS GB (0.70) | pause p99 / max ms |
|---|---|---|---|---|---|---|
| 1 | 112.45 | 7.84 | 19,862 | 9,540 / 11,922 / 9,546 | 13.35 | 28.2 / 86.7 |
| 2 | 118.11 | 8.11 | 18,476 | 12,126 / 10,394 / 12,271 | 11.95 | 46.3 / 119.5 |
| 3 | 123.39 | 8.31 | 17,532 | — / 11,644 / — | 13.41 | 70.7 / 156.8 |

Legacy reference (same session): age 1 / 2 / 3 = 121.7 / 124.8 / 131.0 s, GC 12.6 / 16.5 / 21.0 s,
peak (gf 0.70) 11,434 / 10,206 / 9,759 MB.

Where the time goes at k = 2: help in pauses 2.0 → 5.4 s (late jobs are bigger: the mark adds
~676 M object visits over the run, as many as the tenure copies), collector CPU 20.2 → 24.0 s,
zap 0.06 s. v1 had help 7.1 s at k = 2 and 19.7 s at k = 3.

### 7.4 Decision

§6's rule: a k > 1 becomes the default only if it improves wall or old-gen peak beyond the noise
without regressing the other, and pause p99 rises by at most 10 %. k = 2 and k = 3 regress wall
(+5.4 % / +9.7 %) and p99 (+64 % / +151 %). The peak advantage at gf 0.70 (−13 %) reverses at
0.65 and 0.75 (+27 % / +29 %), so across the sweep the median peak is higher at k = 2. The default
stays **k = 1**. Region ageing does dominate legacy ageing (k = 2: 6.7 s faster than legacy age 2,
half the GC time) and cuts promoted bytes, so it remains available as `promotion_age = 2 | 3`.

### 7.5 What would make it pay

- The mark re-traverses every live ageing object at each hand-over. Remembering the previous
  job's marks for objects that stay live (an extent marked at h is marked again at h + 1 only for
  k ≥ 3) would cut k = 3's cost, not k = 2's.
- The peak is set by the trigger, not by the promoted volume. Ageing can only help memory together
  with a trigger that responds to the smaller promotion rate (phase 5c's paced LiveBudget is tuned
  for k = 1).
