# M5 — audit log

Dated entries, newest last. Each records what was checked against which tree, the verdicts, and
every change to the model. A canary re-audit (parent plan §7.4) adds an entry here quoting the new
hash prefix. The canary is not built yet.

## 2026-09-29 — first implementation (plan §10 steps 1–7)

**Tree:** 2026-09-28/29, post-7c. The M5 files (`TenureWork.hpp`, `NurseryTenure.cpp`,
`NurseryRegion.cpp`, `NurseryRegions.hpp`, `NurserySpace.hpp`, `OldGenTenure.cpp`) are the tree the
plan's review used; `ThreadLocalHeap.cpp`, `OldGenSpace.cpp` and `GCHelperPool.cpp` gained
`ECO_TLA_TRACE` hooks during this work (lines shift by 1–20; no logic changed). **Tools:** the dev
image: tla2tools 1.8.0 (TLC 2026.09.25 rev 8f4bc8b). Every run used 2 TLC workers (quick) or 4
(deep) on a shared, loaded 12-core machine, so the times are rough.

### Results

Quick tier (`tla-check`), 49 rows, run as `run_models.py --model M5 --jobs 2 --workers 2
--java-opts=-Xmx3g`: **49/49 as expected** (48 rows in 330 s, then `MC_k2_cycle_major` in 17 s;
the closing re-run of all 49 with `--jobs 1`: 49/49 in 586 s).
The state counts are TLC's distinct states; a violation's length is its counterexample's.

| Configuration | Expected | Result | Distinct states | Time |
|---|---|---|---|---|
| `MC_quick_exact` | pass | pass | 478,828 | 18.6 s |
| `MC_quick_sync` | pass | pass | 134,547 | 7.2 s |
| `MC_quick_major` | pass | pass | 418,202 | 15.6 s |
| `MC_quick_cycle` | pass | pass | 291,242 | 11.7 s |
| `MC_quick_l3` | pass | pass | 1,599,062 | 80.5 s |
| `MC_gen` | pass | pass | 509,256 | 17.9 s |
| `MC_wrap` | pass | pass | 491,676 | 18.3 s |
| `MC_quick_builders` | pass | pass | 949,410 | 50.4 s |
| `MC_quick_ylos` | pass | pass | 1,094,237 | 54.3 s |
| `MC_quick_ylos_cycle` | pass | pass | 1,639,026 | 69.7 s |
| `MC_quick_ylos_major` | pass | pass | 702,352 | 30.9 s |
| `MC_quick_k2` | pass | pass | 659,562 | 26.6 s |
| `MC_cycle_major` | violates `YoungWalkValid` (CR-017) | as expected, 47 states | 130,112 | 5.3 s |
| `MC_k2_cycle_major` | violates `YoungWalkValid` (CR-017, k = 2) | as expected, 108 states | 684,922 | 16.6 s |
| `MC_fork` | violates `TenuredEqualsLegacy` (CR-013) | as expected, 52 states | 43,381 | 3.1 s |
| `MC_fork_orphan_copy` | violates `ExactlyOnce` (CR-013) | as expected, 64 states | 26,300 | 3.3 s |
| `MC_fork_l3` | deadlock (CR-013) | as expected, 63 states | 411,320 | 15.0 s |

The 32 mutants, each with only its target invariant on the `INVARIANTS` line and only the
operations its story needs (all rejected with the named invariant; 1.7 s to 62 s each):

| Mutant (`mutants/*.cfg`) | Represents | Target | Distinct states | Counterexample |
|---|---|---|---|---|
| `skip_start` | the engine skips a start (`test_tenure_skip_start_every_`) | `TenuredEqualsLegacy` | 1,422 | 57 states |
| `skip_start_resolve` | the same; the next minor's resolve | `TV1_Resolve` | 1,570 | 60 states |
| `skip_start_major` | the same; a STW major's redirect | `TV1_Major` | 2,220 | 56 states |
| `skip_heal` | the merge skips one heal slot (`test_heal_skip_one_`) | `NoDangling` | 20,663 | 83 states |
| `no_root_starts` | roots into Hand not recorded in S | `TenuredEqualsLegacy` | 1,017 | 52 states |
| `no_resolve` | references into Retire not resolved | `NoDangling` | 2,395 | 79 states |
| `merge_before_join` | the merge does not join the collector | `CollectorPrivate` | 18,402 | 60 states |
| `merge_before_join_tv1` | the same, before the publish | `TV1_Heal` | 8,821 | 52 states |
| `collector_heals` | the collector writes the heal slot (07 trap 1) | `CollectorPrivate` | 8,582 | 55 states |
| `skip_fix` | `childOfCopy` does not fix the copy's slot | `OldPointsOld` | 17,744 | 75 states |
| `copy_slot_in_heal` | a copy's slot handed to the heal | `HealYoungOnly` | 12,097 | 61 states |
| `root_in_heal` | a root slot recorded in H (07 trap 8) | `GraphPreserved` | 145,756 | 78 states |
| `gen_not_bumped` | no generation bump (timeline (c)) | `GraphPreserved` | 266,685 | 162 states |
| `wrap_no_discard` | the generation wraps without a discard | `GraphPreserved` | 267,489 | 161 states |
| `major_greys_original` | no `majorRedirect` | `NoDangling` | 3,808 | 82 states |
| `t0_skips_tenuring` | the t0 walk skips Tenuring (07 trap 7) | `NoDangling` | 28,640 | 75 states |
| `copy_not_black` | copies not allocate-black (`test_skip_allocate_black_`) | `MarkerDisjoint` | 1,218 | 46 states |
| `copy_not_black_live` | the same; the handoff frees the copy | `NoDangling` | 2,574 | 75 states |
| `t0_keeps_young` | t0 keeps young targets | `MarkerDisjoint` | 217 | 22 states |
| `grant_t0_cells` | the grant takes t0-live cells (`test_grant_t0_block_`) | `MarkerDisjoint` | 757 | 36 states |
| `l3_no_claim` | L3 without the claim CAS | `ExactlyOnce` | 124,222 | 59 states |
| `builder_in_survivor` | a builder in the survivor part (07 trap 13) | `GraphPreserved` | 41,368 | 50 states |
| `builder_in_survivor_young` | the same | `BuilderYoung` | 72 | 10 states |
| `builder_in_heal` | a builder slot recorded in H (07 trap 8) | `GraphPreserved` | 1,792,873 | 85 states |
| `ylos_slot_in_starts` | a young YLOS slot recorded in S (07 trap 8) | `NoDangling` | 600,638 | 87 states |
| `skip_ylos_resolve` | the merge does not resolve a promoted YLOS's slots | `OldPointsOld` | 37,798 | 70 states |
| `skip_scan_ylos` | the engine does not scan a reached YLOS | `TV1_Ylos` | 486,214 | 76 states |
| `job_skips_ylos` | the engine does not mark a YLOS it reaches | `NoDangling` | 557,362 | 82 states |
| `keep_unreached_ylos` | the sweep keeps unreached generation YLOS | `YlosFreed` | 8,849 | 66 states |
| `t0_greys_ylos` | t0 greys young YLOS | `MarkerDisjoint` | 179 | 20 states |
| `skip_zap` | no zap (`test_skip_zap_`) | `YoungWalkValid` | 135,050 | 90 states |
| `age_mark_no_heal` | the ageing mark drops a marked holder's heal slot | `NoDangling` | 15,887 | 97 states |

Deep tier (`tla-check-deep`), each row once, under the machine-wide lock
(`flock /tmp/tla-deep.lock`, `nice -n 10`, 4 workers, `-Xmx5g`, 2-hour limit):

| Configuration | What it stretches | Expected | Result | Distinct states | Time |
|---|---|---|---|---|---|
| `MC_deep` | the plan's all-on configuration: L3, 3-cell extents, 2 fields, 6 minors, majors and cycles (T = 2), 3 operations | violates `YoungWalkValid` (CR-017) | as expected, 50 states | 6,622,199 | 2 min 8 s |
| `MC_deep_major` | the plan's heap (3-cell extents, 2 fields, 6 minors, seed), majors, mode 2, exact engine, 2 operations | pass | pass | 5,409,434 | 2 min 21 s |
| `MC_deep_cycle` | the same with cycles (T = 2) instead of majors | pass | pass | 5,779,452 | 2 min 33 s |
| `MC_deep_l3` | `quick_l3` with 3 operations | pass | pass | 18,018,284 | 5 min 39 s |
| `MC_deep_ops4` | `quick_exact` with 4 operations | pass | pass | 3,683,200 | 56 s |
| `MC_deep_nf2` | `quick_exact` with 2 fields | pass | pass | 2,550,988 | 1 min 14 s |
| `MC_deep_k2` | k = 2 (the plan's `ageing_k2`): 2-cell extents, 6 minors, stops, cycles, 4 operations | pass | pass | 37,922,800 | 18 min 34 s |
| `MC_deep_ext` | builders and generation YLOS together, 4 operations | pass | pass | 56,432,788 | 26 min 5 s |

**Disk, not time, bounds the deep tier.** The first `MC_deep_major` had 3 operations. It reached
134.9 M distinct states at depth 162 in 53 minutes, with 2.4 M states still queued and TLC's state
files at 50 GB on a disk shared with six agents (20 GB left). It was stopped, and `deep_major` and
`deep_cycle` run 2 operations; the operation dimension is `deep_ops4`'s. A deep row should stay
below about 40 M states here. (`MC_deep_k2` and `MC_deep_ext` were first run at 3 operations: 1.5 M
and 3.75 M states in under 70 s, too small for the deep tier; the committed rows run 4.)

Every invariant has at least one mutant (rule A6): `NoDangling` 8, `GraphPreserved` 5,
`MarkerDisjoint` 4, `TenuredEqualsLegacy` 2 (+ `MC_fork`), `CollectorPrivate` 2, `OldPointsOld` 2,
`ExactlyOnce` 1 (+ `MC_fork_orphan_copy`), `YoungWalkValid` 1 (+ CR-017 itself), and one each for
`HealYoungOnly`, `TV1_Heal`, `TV1_Resolve`, `TV1_Major`, `TV1_Ylos`, `BuilderYoung`, `YlosFreed`.
Every existing 7c/07b test hook that the model can express has its mutant (`skip_start`,
`skip_heal`, `copy_not_black`, `grant_t0_cells`, `skip_zap`; `t0_skips_tenuring` is the partial form
of `test_snapshot_skip_young_walk_`); `test_no_body_remark_` needs large bodies, which are not
modelled.

### Counterexamples

Every counterexample was read, to check that it is the intended story and not another path to the
same invariant. Numbers are TLC's (breadth-first, so each is a shortest one); "lids" counts
logical objects, A/B/C are extents 1/2/3, O1.. old cells, Y1 a YLOS cell.

**Register reproductions.**
- **`MC_cycle_major` → `YoungWalkValid` (CR-017), 2 minors, 1 major, 2 lids.** y → seed
  is allocated into the seed's own root, so the seed is held only by y. Minor 1 copies y into A.
  The mutator drops y. The STW major (marking from roots only) frees the seed. Minor 2 hands A over
  (Tenuring, dead y still in it), and at `MN_Cycle`, where a t0 is possible, y's field names the
  freed seed. This is the plan's story exactly, and M1's `MC_quick_region` seen from M5's side.
- **`MC_deep` → `YoungWalkValid` (CR-017), 50 states.** The same chain in the all-on deep
  configuration (y's second field holds the seed).
- **`MC_k2_cycle_major` → `YoungWalkValid` (CR-017 with k = 2), 4 minors, 1 major, 2 lids.** h in
  A; minor 2 ages A; e → h is allocated over h's root; minor 3 copies e into C (Fresh) and records
  e.f in H; t0 at minor 3; job 3 tenures h and a STW major merges it (e.f healed to h's copy); e is
  dropped, so the major frees h's copy; minor 4 ages C to 2, and its t0 walk reads the dead e,
  whose field names the freed copy. C's first ageing mark runs in job 4, after that t0, so 07b's
  zap cannot help: with k = 2 the window covers every object that died since its extent's last
  mark, or before its first.
- **`MC_fork` → `TenuredEqualsLegacy` (CR-013), 3 minors, 1 lid.** Root → o; minor 1
  copies o into A; minor 2 hands A over with S = {o}; the collector takes o's start (`ns` = 2) and
  vanishes (`calive = FALSE`) before its shadow load. Minor 3's join finds no running collector (the
  orphan path) and `JobDone` (the start was taken), so help does nothing and the merge runs without
  o. The next step would be TV1 at minor 3's resolve.
- **`MC_fork_orphan_copy` → `ExactlyOnce` (CR-013), 3 minors, 2 lids.** o is both a
  start and a heal target. The collector takes the start, copies o into O1 and vanishes before the
  publish. Help takes the heal item, finds o unvisited and copies it again into O2 (TV3/TV4 in
  validate builds; in release builds an orphan grant cell whose fields point into the extent).
- **`MC_fork_l3` → deadlock (CR-013 with L3), 2 minors, 2 lids.** Member 101 claims o
  (BUSY) and vanishes; help takes the heal item for o, sees BUSY and waits in `waitPublished`
  forever. The same wait happens at exit: `tenureTeardown` → `tenureConcFinish` → `runMarkerLoop`
  → `TenureParEnv::tenure`.

**Mutants** (core; host in brackets):
- `skip_start` [quick_exact] → `TenuredEqualsLegacy`: root → o; A handed over at minor
  2 with S = {o}; the engine skips it; minor 3 at `J_Merge`. `_resolve` → `TV1_Resolve`:
  the same, one step later at minor 3's resolve of the root. `_major` [quick_major] →
  `TV1_Major`: the same, then a STW major after minor 2.
- `skip_heal` → `NoDangling`, 3 minors, 2 lids: o in A; e → o allocated into o's root;
  minor 2 records e'.f in H; the job copies o through the heal item; minor 3 skips the heal and
  frees A; the next epoch reaches e'.f.
- `no_root_starts` → `TenuredEqualsLegacy`: the root into A at minor 2 is not recorded;
  job 2 has no work; minor 3 at `J_Merge`.
- `no_resolve` → `NoDangling`: root → o; job 2 copies o; minor 3 does not resolve the
  root, and frees A.
- `merge_before_join` → `CollectorPrivate`, 1 lid (the plan expected 2): the collector
  copies o; minor 3 merges without joining; the collector publishes; minor 3 resolves the root to
  the copy while the collector still runs. `_tv1` → `TV1_Heal`: minor 3 merges before
  the collector published o's copy.
- `collector_heals` → `CollectorPrivate`, 2 minors: the collector's heal item stores
  the copy into e'.f itself (07 trap 1).
- `skip_fix` → `OldPointsOld`: o1 → o2, both copied into A at minor 1; job 2 copies both;
  the copy of o1 keeps its slot into A; minor 3's merge makes it an old object pointing young.
- `copy_slot_in_heal` → `HealYoungOnly`, 2 minors: the scan of o1's copy appends
  `<<O1, 1>>` to the heal list.
- `root_in_heal` → `GraphPreserved`, 3 minors, 2 lids (07 trap 8): the root into A at
  minor 2 goes to H; in epoch 2 the mutator reuses that root slot for a new e → o; the collector
  reads the reused slot (e, not in the extent) and never tenures o; minor 3 resolves e'.f into A to
  nothing.
- `gen_not_bumped` [gen] → `GraphPreserved`, 6 minors, 2 lids (timeline (c)): a in A.1
  tenured by job 2 (FWD, gen 1); b copied into A.1 at minor 4; A's second hand-over at minor 5
  keeps gen 1, so job 5 believes a's stale entry for b; minor 6 resolves b's root to a's copy.
  The plan's version went through a heal slot; the root's resolve is shorter.
- `wrap_no_discard` [wrap] → `GraphPreserved`: the same, with the 1-bit generation
  wrapping back to 1 without a discard.
- `major_greys_original` [quick_major] → `NoDangling`: job 2 copies o; a STW major
  greys the original, so the copy is freed; minor 3 resolves the root to the freed copy.
- `t0_skips_tenuring` [quick_cycle] → `NoDangling`, 3 minors, 1 op: t → seed allocated
  into the seed's root; t0 at minor 2 does not walk A; job 2's black copy of t is never scanned;
  minor 3's handoff frees the seed.
- `copy_not_black` [quick_cycle] → `MarkerDisjoint`: t0 at minor 2, then job 2 (in the
  pause, mode 1) copies o white. `_live` → `NoDangling`: minor 3's handoff frees the
  white copy that the root was just resolved to.
- `t0_keeps_young` [quick_cycle] → `MarkerDisjoint`: t0 at minor 1 greys the fill copy a
  root holds.
- `grant_t0_cells` [quick_cycle] → `MarkerDisjoint`: t0 at minor 2 greys the seed; job
  2's grant contains it.
- `l3_no_claim` [quick_l3] → `ExactlyOnce`: o is a start and a heal target; member 101
  takes the start, member 102 the heal item; both copy.

**Mutants** (extensions):
- `builder_in_survivor` [quick_builders] → `GraphPreserved`, 2 minors: a builder copied
  into A's survivor part (07 trap 13); a kernel stores eden object x into it in epoch 1; minor 2 does
  not rescan survivor-part objects (A is the hand-over extent), so the slot still names x's eden
  cell, which the minor clears. The plan's story (the collector reading the builder while the
  kernel writes it) is longer; this one is the same trap's other consequence. `_young` →
  `BuilderYoung`: the builder in a survivor part at minor 1.
- `builder_in_heal` [quick_builders] → `GraphPreserved`, 3 minors, 2 lids (07 trap 8,
  builder form): x in A; builder bb → x allocated over x's root; minor 2 re-copies bb and records
  bb.f → x in H instead of S; in epoch 2 the kernel loads x into a root and stores Nil into bb.f
  before the collector reads the heal slot; x is never tenured; minor 3 resolves the root to nothing.
- `ylos_slot_in_starts` [quick_ylos] → `NoDangling`, 3 minors, 3 lids (07 trap 8, YLOS
  form): h in A; y → h and e → y allocated; minor 2 copies e, first reaches y (generation B), and
  records y.f → h in S instead of H; job 2 tenures h but the merge never heals y.f; minor 3 frees A,
  and y (reached only through e', a hand-over object, so not rescanned) keeps y.f into A.
- `skip_ylos_resolve` [quick_ylos] → `OldPointsOld`: y → h reached at minor 1 (h copied
  into A); minor 2 reaches y as a hand-over member; minor 3 promotes y without resolving y.f.
- `skip_scan_ylos` [quick_ylos] → `TV1_Ylos`: t, y → t, o → y; minor 1 copies o and t
  into A and reaches y; job 2 reaches y through o's copy but does not scan it, so t is never
  tenured; minor 3's merge would resolve y.f to nothing.
- `job_skips_ylos` [quick_ylos] → `NoDangling`: o → y; job 2 copies o but does not mark
  y reached; minor 3 frees y as unreached while o's copy (the root's target) points at it.
- `keep_unreached_ylos` [quick_ylos] → `YlosFreed`: a dead y of generation A survives
  minor 3's sweep, although A is freed.
- `t0_greys_ylos` [quick_ylos_cycle] → `MarkerDisjoint`: t0 at minor 1 greys a young
  YLOS instead of marking it.
- `skip_zap` [quick_k2] → `YoungWalkValid`, 4 minors, 2 lids: h in A; o → h allocated over
  h's root; minor 2 copies o into B and records h in SA (A is ageing); o is dropped; job 3 (A
  tenuring, B ageing) marks nothing and lists o in `zap`; minor 4's merge skips the zap and frees A;
  the t0 walk reads the dead o, whose field names A's freed cell.
- `age_mark_no_heal` [quick_k2] → `NoDangling`, 4 minors, 2 lids: the same shape with o
  live: job 3 marks o but does not add o.f to the heal list; h is never tenured; minor 4 frees A.

### Changes from the plan's sketch (plan §4.5), and why

1. **A per-run operation budget.** With the mutator's loads and drops unbounded, `quick_exact` had
   8.6 million distinct states after 4 minutes, still growing. Measured on `quick_exact` (exact
   engine, 4 minors): 1 operation 4,572 states; 2 operations 55,250; 3 operations 478,828 (26 s);
   4 operations 3,683,200 (2 min 39 s). New constants, as in M1:
   - `MaxTotalOps` (mutator operations per run);
   - `Ops` (the operation kinds explored).

   Quick configurations use 3 operations (L3: 2), deep ones 3 or 4. Each mutant enables only the
   operations its story needs, which is sound for a negative control.
2. **An idle step at the end of the run** (`await minors >= MaxMinors; skip`). With a budget the
   mutator eventually has nothing to do; the idle step keeps `CHECK_DEADLOCK TRUE` meaningful in
   every passing configuration: a deadlock can then only be a pause that blocks (help waiting on a
   BUSY entry, a join that never returns, `E_Copy` with an empty grant).
3. **`go[c]` flags instead of `claunch` / `seen`.** The gang compares `generation_ != seen`
   only for equality; a per-member "launch not yet seen" flag is exact (primer §4.5) and keeps two
   counters out of the state.
4. **L3's item order is a bag.** The sketch gave L3 members the exact engine's order (stack, then
   starts, then heals). Real members take from their own deque and steal from others', so any
   pending entry may come next; the model lets a member (and the claiming help) take any pending
   copy, start, heal target or YLOS entry (M2's Drain contract). This is the plan's "one shared
   `jstack` bag", made literal. It is the main cost of `quick_l3` (1.6 M states at 2 operations).
5. **L3 reads heal values later than the code.** `tenureParDistribute` (`NT:1121-1127`) reads the
   heal slots' values in the launch pause; the model's members read them when they take the entry.
   The slots are immutable until the merge (P1), so both reads return the same value.
6. **`CollectorPrivate` counts only a live collector** (`running > 0 /\ calive`). A fork child's
   dead collector leaves `running` stuck above 0, and every later merge would otherwise violate it.
7. **`YoungWalkValid` covers every target, not only old ones**, and every object the t0 walk visits
   (young YLOS and the Fresh builder area included), as plan §8.3 asks for k = 2. It holds for
   k = 1 without majors (all quick configurations), so it is applied to every configuration.
8. **Dead-state hygiene** (primer §4.2): the fill tops `ftop` / `fbot` are mutator locals reset
   after the minor (the sketch kept `xtop` global); `cage` is reset at the handoff; `drop` only
   picks a non-empty root.
9. **One value type per variable.** YLOS states are tuples (`<<"Free", 0>>`, `<<"G", x>>`, ...):
   TLC cannot compare a string with a tuple ("Attempted to check equality of the function
   <<"G", 1>> with the value ...", found on the first `quick_ylos` run).
10. **A PlusCal comment may not contain `*)`.** `(HEAP_BUILDER_*)` in a comment closed the algorithm
    block; the translator still said "Translation completed" (SANY then reported a lexical error).
11. **Names.** The sketch's `grant_t0_block` is the §5 table's `grant_t0_cells`; `root_in_heal`
    (07 trap 8) is in the core, with root heal entries `<<<<"R", r>>, 1>>`, and `builder_in_heal`
    is its builder form.
12. **The extensions (§8.1–§8.3)**, which the plan gives only as deltas, were built in the same
    module, switched off by `BC = 0`, `YC = 0`, `K = 1`; switched off, their variables stay
    constant and add no states (`quick_exact` went from 495,856 states with the core-only module to
    478,828, the difference being change 8's hygiene). The choices made:
    - builders: `BC` builder cells per extent; a kernel allocates a builder (fields from held
      plain values), stores held plain values into it and clears it; a builder is reachable only
      from its kernel's root (HEAP_BUILDER_003), and builders do not nest. The previous fill's
      builder area (PrevBuilders) is evacuated like eden and cleared after the minor;
    - generation YLOS: `YC` Y cells whose state `ys` is the pause's colour and generation. The
      minor's first reach joins generation m and scans with `kColYoungYlos`; a hand-over member is
      reached and scanned with `kColHandYlos`; the job reaches members through copies and scans them
      read-only; the merge promotes the reached and resolves their slots into the extent; the
      minor's sweep frees Y0 cells not reached and unreached members of the retiring generation
      (deferred to the handoff mid-cycle, `YDead`). The t0 snapshot marks every young YLOS black
      and greys its old children (`snapshotYoungLarge`); a STW major frees unmarked YLOS cells;
      allocation mid-cycle is black;
    - ageing (k = 2): four extents, the Age role records `SA`, the job's mark (`astack`, `amark`,
      heal slots of marked holders, age-generation YLOS) and sweep (`zap`), the merge's zap. A mark
      item scans one whole object (it reads only immutable objects and writes job-private state);
      a sweep item covers a whole extent (the code's item is one bitmap word). New marks are
      pushed, and heal slots appended, in `SetToSeq` order, which equals field order at `NF = 1`
      (trace validation needs field order at `NF > 1`).
13. **Invariants added:** `TV1_Ylos` (the merge's YLOS resolve), `BuilderYoung` (HEAP_BUILDER_001),
    `YlosFreed` (an unreached generation YLOS is freed with its extent); `TenuredEqualsLegacy` gained
    two conjuncts (the reached YLOS set and the ageing mark equal the live sets at the hand-over);
    `HealYoungOnly` accepts slots of young YLOS and of marked ageing objects; `MarkerDisjoint`'s
    "old cells only" became "`OldAddr`" (old cells and non-young YLOS cells).
14. **Mutants added** beyond the plan's table, so every new invariant and every extension path has
    one: `builder_in_survivor_young`, `builder_in_heal`, `ylos_slot_in_starts`, `skip_ylos_resolve`,
    `skip_scan_ylos`, `job_skips_ylos`, `keep_unreached_ylos`, `t0_greys_ylos`, `age_mark_no_heal`;
    and two more CR-013 facets, `MC_fork_orphan_copy` and `MC_fork_l3`.
15. **Tiering.**
    - `quick_l3` runs 2 operations (3 had more than 3.3 M states after 3 minutes); `deep_l3` runs 3.
    - `quick_k2` is in the quick tier (28 s), although the plan kept ageing out of it: the ageing
      paths are cheap at one-cell extents, and `skip_zap` needs a host there anyway. The plan's
      `ageing_k2` is `MC_deep_k2`.
    - **The plan's deep tier did not fit.** Its `deep_major` / `deep_cycle` (L3, 3-cell extents, 2
      fields, 6 minors) had more than 4.5 M states after 4.5 minutes at 2 operations, still growing;
      the L3 bag with 2 fields is the cost (4 minors grow just as fast). With the exact engine and 3
      operations it still passed 135 M states without finishing (the deep table). The deep tier
      stretches one dimension at a time instead: `deep_major` and `deep_cycle` keep the plan's heap
      (3-cell extents, 2 fields, 6 minors, a seeded old object) with the exact engine and 2
      operations; `deep_l3` is L3 at 3 operations; `deep_ops4` and `deep_nf2` stretch the operations
      and the fields; `deep_k2` and `deep_ext` the extensions. `deep` keeps the plan's all-on
      parameters: it fails CR-017 early, breadth-first, so it is cheap.
16. **`fork`** is `quick_exact` with 3 minors (the story needs 3).

### The code against the plan (checked while building)

Every file:line the plan cites was checked against the tree. They match, except:
- `ThreadLocalHeap.cpp`, `OldGenSpace.cpp`, `GCHelperPool.cpp`: shifted by the new trace hooks
  (MAPPING.md uses the current lines).
- **L3 reads the heal values in the pause** (`tenureParDistribute`), not on the collector (the plan's
  §2.3 describes the exact engine). No correctness consequence (change 5).
- **The t0 snapshot also walks every young YLOS** (`snapshotYoungLarge`, `OGS:4189`: marks the cell
  and greys its old children, dead members included), which the plan's §2 does not mention. Dead
  young YLOS do not add a CR-017 path of their own: a STW major frees every unmarked YLOS cell
  (`lazySweep`'s large-cell branch), so none survives to the next t0; but a dead Tenuring object
  whose YLOS child a major freed is CR-017's chain again.
- **`tenureJoin` helps after a plain join too** when the job is not done ("stopped by a fork hook",
  `NT:631`); the model's `J_Help` follows both join branches.
- **The minor's YLOS sweep defers frees mid-cycle** (`deferred_frees_`, `OGS:7313`), modelled as
  `YDead`.
- **CR-017 is not confined to k = 1.** 07b's zap removes ageing objects dead at the job's mark; an
  object that dies after the mark is walked at the next t0 like a dead k = 1 Tenuring object
  (`MC_k2_cycle_major`).

### Register-relevant findings (for the orchestrator; the register is not edited here)

- **CR-017: reproduced from M5's side** (`MC_cycle_major`, 47 states; `MC_deep`), and **extended**:
  with tenure age k = 2 the same chain goes through an ageing extent (`MC_k2_cycle_major`), because
  07b's zap covers only objects dead at a job's mark. A fix must zap (or not walk) dead objects of
  every Young extent a STW major did not reach, not only of the Tenuring one.
- **CR-013: reproduced at model level, three facets** (`MC_fork`: a taken start never tenured;
  `MC_fork_orphan_copy`: an orphan copy and a second copy; `MC_fork_l3`: help waits forever on a
  dead member's BUSY entry). The register's open question ("wait on a half-published shadow word,
  M5 to assess") is answered: **yes for L3**, at the child's next minor and at exit
  (`tenureTeardown` → `tenureConcFinish`, `NT:905-907`, runs the same claiming engine). With the
  exact engine, by code reading (teardown is not in the model): `tenureTeardown` finishes the job
  with `runJobExact` and merges with `heal = false`, which skips TV3/TV4, the YLOS resolve and the
  heal (`NT:686-744`); no check on that path trips over the lost item, so only a child that runs
  another minor hits TV1.
- No new code defect was found. Every other checked property passes in every configuration.

### What is left

- **Trace validation** (plan §9, step 8): a later wave. The harness exists: `gc-tenure-tsan`
  (`test/gc-helper-tsan/tenure_harness.cpp`, target at `test/gc-helper-tsan/CMakeLists.txt:51`); it
  runs the real `SerialEngine` on the real `GCBackgroundGang` over a synthetic heap of node and cons
  cells (ageing arenas on even seeds). `test/gc-heap-tsan/heap_driver.cpp` has the region scenarios
  (1 and 4 collectors). The shared infrastructure now exists: the `ECO_TLA_TRACE` header
  (`runtime/src/allocator/TlaTrace.hpp`), the recorder and merger (`test/tla/trace/`), the
  registry and runner (`test/tla/traces.txt`, `run_traces.py`), and the gang events
  (`gang.launch`, `gang.start`, `gang.exit`, `gang.join`, `stop`). M5 needs a TRACE-build target
  for the tenure harness (today `gc-tenure-tsan` is a TSan build only; trace builds must be
  separate), a `harness` line and `trace` rows in `traces.txt`, `TraceTenuring.tla` (and a `.keep`
  list), and these hooks.
  M5 still needs hooks for: `launch` (`tenureLaunch`, before `R.collector->launch`, `NT:572`,
  `:1234`), `item` (`SerialEngine::step`, `TW:277-320`), `load` (`TW:255`, `NT:971`), `claim`
  (`NT:979`), `copy` (`TW:262`, `NT:983-985`), `publish` (`TW:265`, `NT:1001`), `fix` (`TW:434`,
  spine writes `TW:480`, `:488`), `stopSeen` (`TW:218`), `join`/`help` (`tenureJoin`, `NT:581-654`),
  `merge` (`NT:800`), `resolve` (`NR:352`), and for the extensions `reach` (`TW:421`, `NT:1005`),
  `mark`/`sweep` (`TW:323`), `zap` (`NT:820`). The trace spec must take placement from the `copy`
  event (the model's exact engine uses `CHOOSE`), start with node-only seeds (the model has no cons
  cells, so `spineRun`'s order cannot match), use field order for the ageing mark's pushes at
  `NF > 1` (change 12), and read `NF` per object (the harness's nodes have varying slot counts).
- **The canary (A9)** is a later wave. The lines M5 asks for, for `test/tla/manifest.txt`:
  - `file`: `runtime/src/allocator/TenureWork.hpp`, `runtime/src/allocator/NurseryRegions.hpp`;
  - `region` (`TLA-REGION(<id>)` markers around these functions): in `NurseryTenure.cpp`
    `TenureHeapEnv`, `runJobExact` + `tenureEntry`, `tenureLaunch`, `tenureJoin`, `mergeJob`,
    `tenureTeardown`, `TenureParEnv` (its `tenure`, `reachYlos`, `childOfCopy`, `spineRun`, `scan`),
    `tenureParDistribute` + `tenureParCollect` + `runJobParallel`, `tenureConcEntry` +
    `tenureConcLaunch` + `tenureConcFinish`; in `NurseryRegion.cpp` `majorRedirect`,
    `resolveRetire`, `copyClaimedR`, `evacuateR`, `reachYoungLargeR`, and `minorGCRegion`'s
    beginMinor + hand-over preparation, S/H/SA merge, and epilogue + endMinor blocks; in
    `NurserySpace.hpp` `forEachYoung`; in `OldGenTenure.cpp` `grantTenure`, `grantAllocate`,
    `grantAllocateShared`, `returnTenureGrant` (shared with M4); in `OldGenSpace.cpp`
    `greyObject`'s nursery branch (the `majorRedirect` call), `snapshotYoungLarge`,
    `promoteYoungLarge`, and `sweepNurseryLargeBodies`' deferred-free branch; in
    `ThreadLocalHeap.cpp` `minorGC`'s `tenureJoin` call and `TenureLaunchScope`, `majorGC`'s
    `tenureJoin` + `finishMarkCycleNow(Join)`, and `startMarkCycle`'s `snapshotYoungLarge` +
    `forEachYoung` calls; `GCHelperPool.cpp` is M6's `file` line, which M5 should also name;
  - `census`: `NurseryTenure.cpp`, `NurseryRegion.cpp`, `OldGenTenure.cpp`, `TenureWork.hpp`,
    `NurseryRegions.hpp`;
  - `grep`: rows T1–T5 and T9 of `test/tla/footprint-greps.txt` (T6–T8, T10, T11 are written
    abstractions; MAPPING.md §4 covers all eleven). Worth adding there: `kAllocTenure` over all
    allocator files (every block-selection skip, T6), `pend_S|pend_H|pend_SA`,
    `hand_ylos_reached`, `X.gen =`, and `writeFiller` in `NurseryTenure.cpp` (the zap).
- **Weak memory (A4):** W5 and W1, and `w_running_chain`, are W pending.
- **Not modelled:** large bodies (`lb_bodies`, `lb_promoted`, 07 traps 14/15), YLOS builders,
  ageing-generation YLOS with k = 2 together, `runJobParallel`'s `PromoCtx` allocation, the
  `!granted` fallback, eden flip, the STW major inside the hand-over minor (plan §8.4), the
  refinement R1 (§8.5), and the fork child's fresh collector threads.

## 2026-09-29 — wave 2: trace validation (plan §10 step 8)

**Tree:** as above, plus this wave's compiled-out hooks. **Tools:** as above; `merge_trace.py`,
`run_traces.py`, `common/TraceAnyOrder.tla` from the shared infrastructure.

### What was added

- **Hooks** (`ECO_TLA_TRACE`, `((void)0)` in production builds; checked by preprocessing and
  syntax-checking `NurseryTenure.cpp`, `NurseryRegion.cpp`, `NurserySpace.cpp` and
  `ThreadLocalHeap.cpp` with `build/`'s `EcoRuntimeStatic` flags: no `tlatrace` reference is left,
  one `((void)0)` per hook, no new diagnostic):
  - `TenureWork.hpp` (11, the engine): `tstop` and `tend` in `run`, `titem` (start, heal) in
    `step`, `tload`, `tcopy`, `tpub` in `tenure`, `treach` in `reachYlos`, `tchild` and `tfix` in
    `childOfCopy`, `tchild` in `scanYlos`. The header now includes `TlaTrace.hpp` (std-only).
  - `NurseryTenure.cpp` (the pause): `tj.launch` on each of `tenureLaunch`'s five paths (a
    trace-only helper, `ECO_TLA_TRACE_ONLY`), `tj.help` in `tenureJoin` (exact and L3), `tj.merge`
    at the end of `mergeJob`.
  - `NurseryRegion.cpp`: none (the minor is checked through its outcome, below).
- **Harnesses:** `gc-tenure-trace` (`test/gc-helper-tsan`: `tenure_harness.cpp`'s new `tiny` mode
  and a CMake target under `option(ECO_TLA_TRACE)`), and `gc-heap-trace tenure`
  (`test/gc-heap-tsan/tiny_tenure.cpp`, new, wired into `heap_driver.cpp` and the CMakeLists).
- **Specs:** `TraceTenuring.tla` (the engine storm, event by event) and `TraceTenurePause.tla` (the
  pause projection of the real allocator), both `EXTENDS Tenuring, TraceAnyOrder`; MAPPING.md §8
  has both event tables.
- **Rows** in `test/tla/traces.txt`: 10 accepted traces and 17 negative controls.

### Results

`run_traces.py --model M5 --jobs 2 --workers 2 --java-opts=-Xmx3g`, run three times: **27/27 as
expected** each time (47 s, 46 s, 47 s once the harnesses were built). The event counts vary by
at most one between runs (the schedule); TLC's time per row is 2 to 9 s.

| Row | Harness args | Events (3 runs) | Stops / helps (seed's run) |
|---|---|---|---|
| storm 1 | `tiny,1,20,4,2,1,1,2,50,20` | 823–824 | 9 / 8 |
| storm 2 | `tiny,2,20,4,2,1,1,2,60,30` | 859–860 | 8 / 8 |
| storm 3 | `tiny,3,20,5,2,1,2,1,70,20` | 594–595 | 15 / 14 (one stop with no work left) |
| storm 4 | `tiny,4,30,6,3,1,2,2,40,10` | 1,723 | 15 / 15 |
| storm 5 | `tiny,5,20,3,1,0,0,1,100,50` | 472–473 | 20 / 15 |
| pause 1 | `tenure,1,40,1500,15` | 270–271 | see below |
| pause 2 | `tenure,2,40,1500,15` | 267 | |
| pause 3 | `tenure,3,40,300,15` | 262–263 | |
| pause 5 | `tenure,5,40,3000,25` | 243 | |
| pause 6 | `tenure,6,60,1500,10` | 411–412 | |

A 40-step pause run (six seeds counted) has 34–36 minors and 4–6 STW majors, 17–23 of its joins are
stops, 2–4 jobs are helped in the pause, 3–6 objects are tenured and 0–2 heal slots healed.

What the storm covers, counted on two logs: stale shadow entries (a load that sees the FWD word of
an earlier generation, then copies: 63 and 48 loads), current-generation FWD hits, first-time
copies, YLOS reach and scan (21 reaches, 16 resolved YLOS slots in storm 2), stops before start,
mid-job and after the last item, and help.

**Negative controls** (every one rejected, at the event it doctors):
- storm, on seed 1: `set:tload:1:st=1` (a BUSY entry; the exact engine never claims),
  `drop:tpub:1`, `set:titem:1:idx=9`, `drop:tstop:1` (a collector that returns without seeing the
  stop), `swap:tchild:1`, `set:tfix:1:val=0`, `set:treach:1:new=false`,
  `set:gang.join:1:stop=true` (job 1 is joined without a stop in every run: the stop decisions
  come from the seed), `set:tshadow:1:g=7777`;
- projection, on seed 1: `set:tj.launch:1:gen=9`, `set:tj.launch:2:starts=5`,
  `set:tj.merge:1:tenured=7`, `drop:tj.merge:1`, `drop:minor:3`, `set:troots:1:reach=510`,
  `swap:tj.launch:1`, `set:alloc:1:v=7`.

### Finding: a model error, corrected (the engine's stop check)

The first storm logs were accepted; storm seed 3 (`tiny,3,20,5,2,1,2,1,70,20`) was **rejected** by
the model as committed in the first entry, at event 323: the collector finished the last item of
job 12, then `run()` saw the stop flag and returned Stopped (`tstop`), and the pause found the job
done and did not help. The model's engine loop was `while ~JobDone \/ sc # Nil do (stop check;
item)`, so with no work left it could only leave through "done" (`E_Ret`), never through the stop
check. The code (`SerialEngine::run`, `TenureWork.hpp:218-236`) checks the flag first, then asks
`step()` for an item. **Model error, not a code defect:** the two exits lead to the same state, and
both are legal. The engine loop now checks the stop first (`E_Loop`: stop between items, else
`E_Ret` when no item is left, else an item), as the code does. With it, every storm and pause log
is accepted.

Re-checked after the change: the quick tier (`run_models.py --model M5`) is 49/49 as expected
again, with the same state counts as before (the two exits reach the same states); the deep rows
re-run under the lock: **8/8 as expected**, with the earlier state counts: `deep` violates
`YoungWalkValid` (CR-017; 6,892,752 states when found), `deep_nf2` 2,550,988, `deep_ops4`
3,683,200, `deep_major` 5,409,434, `deep_cycle` 5,779,452, `deep_l3` 18,018,284 (8 min 36 s),
`deep_k2` 37,922,800 (15 min 35 s), `deep_ext` 56,432,788 (20 min 48 s).

A harness error found on the way (not a model or code finding): the first pause driver allocated
up to three objects per *step*, but a STW major does not empty eden, so two steps separated by a
major put more objects in eden than the model's `EC`; those logs were rightly rejected at the
allocation. The driver now bounds allocations between minors.

### How the two specs relate the code to the model

- **Storm (event by event).** The harness replaces the minor: its `job` event is matched by
  `TJob`, a trace-spec action that loads the job's heap and inputs from the header and applies
  `MN_Launch`'s own generation bump (or wrap discard) and launch, with the harness's start and heal
  order. Everything after that is the model's own steps. Copies are matched by name: the model's
  exact engine chooses its cells (`CHOOSE`), and `cmap` records which cell each logged copy is.
  The stale-generation logic is checked for real: the harness rebuilds each job at the same
  addresses, so the shadow's earlier entries are there, and every `tload` must see exactly the
  model's entry (state and generation; the destination when current).
- **Pause projection (outcome by outcome).** The real minor's slot order and cell placement differ
  from the model's (roots in the root set's order, a LIFO drain, LABs), so the minor's and the
  engine's steps are hidden, and the model's heap is compared through logical ids and counts: the
  launch's extent, generation, distinct starts and heal slots; the merge's forwarded objects and
  healed slots; after every collection each root's id and generation and the reachable ids. The
  model finds the collector interleaving (and the stop store) that explains the pause's join, help
  and merge.

### Not covered (and why)

- **L3** (`TenureParEnv`): not in the std-only harness; the projection runs one exact collector.
  A projection row with `tenure_collector_threads > 1` on a large extent is possible later
  (`tj.launch` logs path `l3`), with the model's `Collectors = 2`.
- **Ageing (k = 2)** and **builders**: the storm's ageing arena and the model's mark items are not
  matched yet (the model pushes marks and heal slots in `SetToSeq` order, the code in field order:
  equal only at `NF = 1`; the code's sweep is one item per bitmap word, the model's one per extent).
  The projection driver allocates no builders.
- **Per-object minor events** (`resolveRetire`, the S/H recording): order-sensitive against the
  model's slot order, so the projection checks their outcome (roots, reachability, launch sizes)
  instead; `NurseryRegion.cpp` has no hook.
- **Forks**: the projection driver does not fork (M5's `Env` stops once; M6 traces the gang).

### Canary lines for the hooks' files (for `test/tla/manifest.txt`, later wave)

`file runtime/src/allocator/TenureWork.hpp M5` (now with the engine hooks); `region` markers in
`NurseryTenure.cpp` around `tenureLaunch` (incl. the `tla_launch` helper), `tenureJoin` and
`mergeJob` (M5); `census runtime/src/allocator/NurseryTenure.cpp M5`. The harness files are test
code and need no pin.

## 2026-09-29 — canary baseline (GC_MODEL_001)

The canary (`test/tla/manifest.txt`, `tla-canary` in every build) was first pinned today: 50 pins
name this model (6 census, 3 file, 8 grep, 33 region); the list is in MAPPING.md's "Canary pins (A9)" block. This is the
baseline: the pinned code is the code this model was checked against today (after the trace hooks,
wave 3's fixes and the `TLA-REGION` markers landed). From now on, a pin that fires needs an entry
here quoting the new hash prefix before `check-tla-manifest.sh --update` accepts it.

## 2026-09-29 — CR-034: address-keyed YLOS and large-body lists; the major × region boundary

**Tree:** 2026-09-29 (CR-034's tree). **Tools:** as above. Assessment only: no runtime, harness or
register change. Runs: quick rows with 4 TLC workers in scratch; deep rows under
`flock /tmp/tla-deep.lock`, `nice -n 10`, 4 workers, `-Xmx5g -XX:MaxDirectMemorySize=2g`.

### Why M5 missed CR-034

The generation-YLOS extension represented a member by its state `ys = Gen(x)`, i.e. by object
identity: when a STW major freed a member, the membership vanished with it, and a new YLOS at the
same cell started as `Y0`. That is fix candidate 1 ("drop at the major"), not the code: the code keeps
the address in `Extent::ylos_gen` (`NRH:79`), and the next prep takes whatever young YLOS sits there
(`youngLargeMeta(y) != nullptr` is the only check, `NR:751-753`, `:773-775`). The model already reused
freed Y cells (`yalloc` picks the lowest free one); what it lacked was the stale address.

### What was added (switched off in every existing configuration)

- Constants `YlosGen` (`"identity"` = the model before today, the default; `"code"`; the fix
  controls `"drop"`, `"age1"`, `"stamp"`, `"lbid"`), `LbKey` (`"identity"` default; `"code"`, `"kind"`,
  `"drop"`), `Cr017Oracle` (`FALSE` default). Every existing `.cfg` (and both trace `.cfg`s) sets the
  defaults; `TraceTenuring`'s `TJob` sets the new variables.
- `ystale`, `yrec`, the ghost `yjoin`: `MJ_Mark` records a freed member's address in its Young
  extent's list; `MN_Begin`'s prep claims it for its list through `PrepMatch` (hand-over first, as
  `reachYoungLargeR` and `markTarget` search `hand_ylos` first); `MN_Epilogue` drops lists of extents
  that stop being Young. MAPPING.md §1-§3.
- Large bodies (op `"lalloc"`, `ys = YBody`, `lbl`, `ycol`, `bodyLids`): the lb_bodies lists, the
  prep's `markLargeBodySeen`, `lb_seen`, the colour test of the minor's sweep and of the first reach
  (`NR:526`), `promoteLargeHeader` at the merge, the major's and the handoff's frees.
- Invariants: `YlosGenIdentity` (MODEL_M5_2: every member of a generation's snapshot joined that
  generation; fires at the prep, the earliest point), `T0GreyAllocated` (CR-017's half of
  `YoungWalkValid`: the cells the t0 snapshot greys; young targets are dropped by range,
  `OGS:3325-3327`).
- **No existing row changed:** with the defaults the new variables are constant or a function of
  `ys`, so the state counts are unchanged (`MC_quick_ylos_major` 702,352, `MC_quick_exact` 478,828,
  as in the first entry; the whole quick tier below).

### CR-034 reproduced (`YlosGen = "code"`)

| Configuration | Invariant | Counterexample | Distinct states (at the violation) |
|---|---|---|---|
| `MC_ylos_aba` (quick_ylos_major's bounds: k = 1, mode 1, 3 minors, 1 major, 3 ops) | `YlosGenIdentity` | 38 states | ~91 K |
| `MC_ylos_aba_heap005` (the same, one Y cell) | `OldPointsOld` (HEAP_005) | 63 states | ~196 K |
| `MC_k2_ylos_aba` (k = 2, 4 minors) | `NoDangling` | 50 states | ~59 K |

- `MC_ylos_aba`: A = `yalloc` into Y1 (root 1); minor 1 first-reaches A (joins X1's generation);
  `alloc` e over root 1 (A dead); the STW major frees A, leaving Y1 in X1's list; `yalloc` B into Y1
  (the lowest free cell); minor 2's hand-over prep (X1 hand) finds B through the stale entry and
  claims it (`ys = Gen(1)`, `yjoin = 0`). The register's steps 1-4.
- `MC_ylos_aba_heap005`: the same with B → e. Minor 2 reaches B as a hand-over member (`kColHandYlos`:
  scanned, e copied into the fill X2 and B's slot rewritten, nothing recorded in H); minor 3's merge
  promotes B in place (`YOld`) with B.f → e's copy in X2: an old object pointing young, step 5. With two
  Y cells TLC's shortest path gives B a YLOS child instead (the same HEAP_005 violation).
- `MC_k2_ylos_aba` (**k = 2, the ageing prep, `NR:773`**): X1 is ageing at minor 2, so B is claimed
  for `age_ylos`; `reachYoungLargeR` then only records it in SA (`NR:519-523`), it is never scanned, and
  e (held only by B) is not evacuated: B dangles into eden at the end of minor 2. In steady state the
  job's ageing mark then scans B and aborts in TV6 (`youngElsewhere`, every build); at start-up (no
  job yet) nothing notices.

### Fix-candidate controls (`controls/`)

| Control | k | Result | States / counterexample |
|---|---|---|---|
| `ylos_drop` (candidate 1: the major drops a freed YLOS from every list; = `"identity"`) | 1 | pass | 702,352 |
| `ylos_drop_k2` (deep) | 2 | pass | 2,575,180 (70 s) |
| `ylos_stamp` (candidate 2 with a never-reused stamp: a registration serial or epoch) | 1 | pass | 713,090 |
| `ylos_stamp_k2` (deep) | 2 | pass | 2,611,186 (50 s) |
| `ylos_age1` (skip an entry whose YLOS has header age 0; the scratch tree's fix) | 1 | pass | 713,090 |
| `ylos_age1_k2` | 2 | **violates `YlosGenIdentity`** | 59 states |
| `ylos_age1_k2_heap005` | 2 | **violates `OldPointsOld`** | 95 states |
| `ylos_lbid` (candidate 2 with the LargeBodyId as the stamp) | 1 | **violates `YlosGenIdentity`** | 38 states |

- **The age ≥ 1 check is enough at k = 1 only.** At k = 1 a stale entry is read once, at the very
  next minor's hand-over prep, before the new YLOS can be reached and aged. At k = 2 the entry is read
  twice: the ageing prep skips B (age 0), B then joins the new fill's generation (age 1), and at the
  next minor the freed member's extent, now the hand-over, claims B (age 1 passes). The merge promotes B
  while its slot points into its own (ageing) generation's extent (`ylos_age1_k2_heap005`: minors 1-4,
  1 major).
- **The LargeBodyId is not an identity.** `releaseBlockToAllocator` pushes a freed entry's id on
  `free_large_body_ids_` (`OGS:6431`) and `registerLargeBody` pops the last one (`OGS:7530`): in
  CR-034's chain (the block all-dead and released) the new YLOS gets the old id. (Ids retired by
  `retireDeadLargeBodies` or the lazy sweep are not recycled, so there the id would happen to work.)
- Candidate 1, as an implementation: every kind-1 retirement by a major must drop the address
  (`OGS:1805`, `:1831`, `:5641`, `:5742`, `:6427-6433`). With `old_gen_bitmap_alloc` on (the default)
  all of them have run when `runPostMarkTail` returns, so pruning every Young extent's `ylos_gen` and
  `lb_bodies` by an index lookup at the end of a STW major is equivalent; with it off the lazy sweep
  retires entries after the mutator resumes, and a prune at the major's end is not enough.

### The lb_bodies lists (the parallel audit's item)

`Extent::lb_bodies` has CR-034's shape: the prep re-marks each listed body by address
(`markLargeBodySeen`, `NR:749`, `:771`), and `markLargeBodySeen` colours whatever index entry is at that
address, of either kind (`OGS:7542-7552`). The parallel audit's verdict ("floating garbage only") holds
when the address is reused by another body. **It does not hold when it is reused by a young YLOS not
yet reached:** the minor flips its colour first (`NR:675`), a new YLOS carries the previous colour
(`TLH:469`), and the prep's re-mark gives it this minor's colour, so its first reach returns "already
reached this minor" (`NR:526`): it is neither scanned nor aged, and its eden children are not
evacuated. Modelled (`LbKey`): `MC_lb_aba` violates `NoDangling` (52 states: `lalloc` h + body in Y1;
minor 1 copies h into X1 and lists Y1; h dies; the major frees the body; `yalloc` B → e into Y1; minor
2's prep colours B; B's first reach is skipped; e is lost with eden). `lb_kind` (colour kind-0 entries
only), `lb_drop` and `lb_stamp` pass (636,386 each). At k = 2 the same happens through the ageing prep
(`MC_deep_boundary_k2_lb`, 52 states).

### The other address-keyed lists

MAPPING.md §9 has the table: `hand_ylos` / `st.ylos` / `reached[]`, `age_ylos`, `pend_S`, `pend_H` (and the
ageing heal slots), `pend_SA`, `J.lb_promoted`, `lb_seen`, the shadow, `st.zap`, `st.stack` /
`promoted_log`, `young_large_scan_`, `deferred_frees_`: **safe**, each with its argument (no free and
reuse inside its window: the prep colours what the sweep would free, a STW major merges before it
marks, the handoff frees no young YLOS, survivor cells are freed only at retirement); the shadow is
already modelled (generations). The validate-only P1 census reads `ylos_gen` too: benign.

### The major × region boundary, all at once (deep)

| Configuration | Bounds | Result | Distinct states | Time |
|---|---|---|---|---|
| `MC_deep_boundary` | k = 1, mode 2, builders (BC = 1), 2 YLOS cells, large bodies, EC = 2, SC = 3, OC = 4, MaxLid = 4, 4 minors, 1 major, cycles (T = 1), stops, 3 ops of 8 kinds; `"stamp"`, `"kind"`, oracle | pass | 40,436,211 | 12 min 6 s |
| `MC_deep_boundary_cr017` / `_cr034` | the same bounds, the code | `T0GreyAllocated` (47 states) / `YlosGenIdentity` (38) | — | 14 s / 7 s |
| `MC_deep_boundary_k2` | k = 2, mode 2, 1 YLOS cell, large bodies, EC = SC = 1, OC = 4, MaxLid = 4, 5 minors, 1 major, cycles, 3 ops of 5 kinds; the same fixes and oracle; `T0GreyAllocated` for `YoungWalkValid` | pass | 14,080,348 | 3 min 11 s |
| `MC_deep_boundary_k2_cr017` / `_cr034` / `_lb` | the same bounds, the code | `T0GreyAllocated` (47) / `YlosGenIdentity` (38) / `NoDangling` (52) | — | 1-2 s |
| `MC_deep_boundary_k2_m2` | `MC_deep_boundary_k2` with two STW majors | pass | 24,099,550 | 5 min 16 s |
| `controls/ylos_age1_boundary` | `MC_deep_boundary` with the age ≥ 1 check instead of the stamp | pass | 40,436,211 | 12 min 11 s |

Every `_cr017` / `_cr034` / `_lb` row is the hunter's bounds with the code: each fails as expected, so
the bounds admit CR-017's and CR-034's chains. The hunters look past the known defects: CR-034 with the
fix controls, CR-017 with `Cr017Oracle` (the t0 walk skips dead survivor and builder objects; a
model-only stand-in for any CR-017 fix, not a design), and at k = 2 the finding below by checking
`T0GreyAllocated` instead of `YoungWalkValid`. Size: 3 operations and one Y cell (k = 2) or two (k = 1)
keep the rows under the ~40 M-state disk guide; 4 operations would be about 7 times more. Not in the
boundary: L3 (`Collectors = 2`, excluded at k = 2 by `age_forced_exact`), forks.

**The boundary counterexamples, read:**
- `_cr017` (k = 1 and 2, 47 states): **CR-017 through a large header's own body.** `lalloc` h; minor 1
  copies h into X1; h dies; the STW major frees h's body (h is unreachable, so the body is unmarked);
  minor 2's t0 walks the dead h and greys the freed body cell (the marker greys a large header's body,
  `OGS:3543-3548`). No tenured object is needed: any large string or bytes value whose header dies
  after surviving one minor, followed by a STW major and a t0 at the next minor.
- `_cr034` (38 states): `MC_ylos_aba`'s chain; `_lb` (52 states): `MC_lb_aba`'s chain, at k = 2 through
  the ageing prep (`NR:771`).
- **The first run of `MC_deep_boundary_k2` (with `YoungWalkValid`) failed: a new path, not CR-017 or
  CR-034** (88 states in its minimal form `MC_k2_ylos_walk`: k = 2, no major, no reuse). o is copied into
  X1 at minor 1; Y (a YLOS) → o is allocated; minor 2 first-reaches Y (it joins X2's generation) and
  records o in SA (X1 is ageing); Y dies in epoch 2; at minor 3 X1 is handed over and X2 ages, but Y is
  dead, so the ageing mark never scans it and Y's slot into X1 is never healed; minor 4 retires X1, and
  the t0 at minor 4 walks every young YLOS (`snapshotYoungLarge`, `OGS:4426-4446`), dead Y included,
  whose slot names a cell of the retired X1. 07b's zap (`NT:849-857`) fills dead ageing *survivor*
  objects "so no walker reads their possibly dangling slots"; dead ageing-generation YLOS are not
  zapped. **Benign today by code reading:** the snapshot's `greyObject` drops a young target by range
  before any load (`OGS:3325-3327`), the P1 census only hashes the YLOS, and no mutator-side check sees a
  dead object. `T0GreyAllocated` holds in every boundary row.

### Findings (for the orchestrator; the register is not edited here)

1. **CR-034, extended.** (a) k ≥ 2: the ageing prep (`NR:773-779`) claims the new YLOS for `age_ylos`,
   and the pause never scans it (`NR:519-523`): its eden children are lost at that same minor
   (`MC_k2_ylos_aba`; TV6 in the job at steady state, silent at start-up). (b) The scratch tree's age ≥ 1
   check is sound at k = 1 only (`ylos_age1_k2`). (c) The LargeBodyId is recycled LIFO
   (`OGS:6431` → `OGS:7530`), so it is not an identity stamp (`ylos_lbid`). (d) Sound: dropping the
   address at every kind-1 retirement of a major, or a never-reused stamp (both pass at k = 1 and 2,
   and across the whole boundary). (e) Unmodelled but by the same code: a YLOS *builder* claimed this
   way is promoted while its kernel still writes it.
2. **New, S1 (Reproduced in the model; region mode, default k = 1): `lb_bodies` has CR-034's ABA, and
   it can hide a live YLOS from the minor.** Where: `NurserySpace::minorGCRegion`'s preps,
   `markLargeBodySeen(b, minor_color_)` over `Hx.lb_bodies` / `Ax.lb_bodies` (`NR:749`, `:771`);
   `OldGenSpace::markLargeBodySeen` colours any index entry, no kind check (`OGS:7542-7552`);
   `reachYoungLargeR`'s "already reached this minor" return (`NR:526`); the colour flip (`NR:675`) and a
   new YLOS's registration colour (`ThreadLocalHeap::allocateYoungLarge`, `TLH:469`). Interleaving:
   header h of a large string copied into F at minor j (its body address Z joins `F.lb_bodies`,
   `NR:425`/`:928`); h dies; a STW major frees the body (index entry erased, Z kept in the list); a new
   YLOS B → e is allocated at Z; minor j+1's prep colours B; B's first reach returns unscanned and unaged;
   e (held only by B) is not evacuated and B's slot dangles into eden; B is also skipped for its Hand
   targets. Fixes that pass: colour kind-0 entries only in `markLargeBodySeen` (or check the kind at the
   prep), drop at the major, or a stamp. Suggest adding it to CR-034 (same root cause, second list) or a
   sibling entry.
3. **New, S4/D (Reproduced in the model; k ≥ 2 only, opt-in):** a dead ageing-generation YLOS keeps an
   unhealed young slot into a retired extent that `snapshotYoungLarge` reads at the next t0
   (`MC_k2_ylos_walk`); benign today (`OGS:3325-3327`), but it breaks the premise 07b's zap comment states
   (`NT:849-852`) for YLOS: a future walker that checks young YLOS children (TV7) would trip.
4. **CR-017, wider:** the freed old child can be a large header's own body (`_cr017` rows), so CR-017
   needs no tenured object.
5. Nothing else failed: every boundary hunter passes with the defects above looked past.

### Canary (A9) lines to add for this model (not edited here)

M5 now depends on `OGS.releaseBlockToAllocator` (the id push, the index erase), `OGS.retireDeadLargeBodies`,
`OGH.youngLargeMeta`: add `M5` to those pins. `registerLargeBody`, `markLargeBodySeen` and
`allocateYoungLarge` (`OldGenSpace.cpp`, `ThreadLocalHeap.cpp`) have no `TLA-REGION` markers yet; they
should get pins naming M5.

### Checks

- Quick tier, `run_models.py --model M5 --jobs 2 --workers 2` (SANY, translation freshness, 64 rows):
  **64/64 as expected** in 340 s. The 12 passing configurations of the first entry have exactly its
  state counts; the new rows as in the tables above.
- Deep: the boundary rows and `controls/ylos_*_k2` / `ylos_age1_boundary` as in the tables (run by hand
  under the lock, each once; the deep tier's older rows were not re-run: their configurations only
  gained the defaults, which leave the state space unchanged).
- Trace validation, `run_traces.py --model M5 --jobs 2 --workers 2`: **27/27 as expected** (10 accepted logs, 17 rejected negative controls) in 25 s.

### Files

`Tenuring.tla` (PlusCal and translation), every `.cfg` (the three new constants' defaults),
`TraceTenuring.tla` (`TJob`), new `MC_ylos_aba*.cfg`, `MC_k2_ylos_aba.cfg`, `MC_lb_aba.cfg`,
`MC_k2_ylos_walk.cfg`, `MC_cycle_major_t0grey.cfg`, `MC_deep_boundary*.cfg`, `controls/*.cfg`;
MAPPING.md (§1-§3, §5, §6, new §9); `test/tla/models.txt` (M5's rows); `test/tla/README.md` (layout).


## 2026-09-30 — canary: HEAP_071 and HEAP_072 merged (GC_MODEL_001)

New hash prefixes: 325187bc686f (`NR.copyClaimedR`), 1dcbb38f752b (`NR.reachYoungLargeR`), 3c350fb64616 (`NR.minorGCRegion`), b463014eb999 (grep T4).

The canary fired after the SG4 and LB3 changes (gc-opt-loop rows, 2026-09-29) were merged onto the
TLA+ tree, which had been pinned from `keep-TA2`. The two changes are the two fixes of `2-gc-bugs.md`.
Snapshots `keep-TA2` and `keep-LB3` show the exact diff: reversing the edits below reproduces every
old manifest hash, and the current `NurseryRegion.cpp` is `keep-LB3`'s apart from the markers.

- **Bug 1, HEAP_071** (SG4): no header-only heap object; the default shadow granule is 16 B.
  `copyClaimedR` (`NR:406-412`): the "survivor under 16 B" abort also fires in validate builds at any
  granule, and reports the tag. This is a validate-only check before the copy, not a protocol step.
- **Bug 2, CR-034 → HEAP_072** (LB3): a region generation's YLOS member is an incarnation, not an
  address. `reachYoungLargeR` stamps `LargeBodyMeta::join_minor = R.minor_seq` inside the existing
  `ylos_mu_` section (`NR:538`). The hand-over and ageing preps of `minorGCRegion` accept an entry
  only through `youngLargeMember(y, X.gen_minor)` (`NR:758`, `:780`), and so does the validate-only
  P1 census (`NurserySpace.cpp:2830`, which is why grep H8 lost that line).

Neither fix adds an atomic, a lock, a memory order or a shared location (the censuses did not
fire). The rest of both changes is not pinned: `youngLargeMember` and the `join_minor` field
(`OldGenSpace.hpp`), a validate-only HEAP_051 check at the end of `markLiveMergeAll`, the empty-Bytes
constant in the kernels and heap helpers, and the defaults (`shadow_granule_log2` 4,
`major_gc_live_budget` 3.0).

**Verdict: model updated (CR-034 is fixed in the code).** The pre-fix prep, `youngLargeMeta(y)` alone,
was `YlosGen = "code"`. The fix is the existing `"stamp"` control ("a never-reused stamp never matches
a stale entry"), for two reasons checked in the code:
- `registerLargeBody` builds a fresh `LargeBodyMeta{...}` even for a recycled id (`OGS:7547`), so a new
  occupant starts with `join_minor = 0`. `"lbid"`'s failure (a recycled id taken for a stamp) does not
  carry over.
- `++R.minor_seq` (`NR:716`) runs before any stamp or `gen_minor` is written, so every generation
  number is at least 1 and an unjoined occupant never matches. An occupant registered after the major
  that freed the member joins at a later minor, if it joins at all.

Changes:
- `Tenuring.tla`: `"code"` renamed `"addr"` (the pre-HEAP_072 code, kept as CR-034's regression mutant);
  `"stamp"` documented as the code (the `YlosGen` comment, `ASSUME`, `PrepOK` comments). The
  translation was regenerated (`pcal -nocfg`); it differs by one blank line only.
- Configs: `MC_deep_boundary_cr017` and `_k2_cr017` ("the code") now use `"stamp"`, and still violate
  `T0GreyAllocated` (CR-017 is open). `MC_ylos_aba`, `_heap005`, `MC_k2_ylos_aba`,
  `MC_deep_boundary_cr034` and `_k2_cr034` use `"addr"` with unchanged expectations, as mutants.
  `controls/ylos_stamp` and `_k2` are now the CR-034 rows. Headers updated.
- `models.txt` comments; `MAPPING.md`: `MN_Begin`, the reach row, the prep-checks row, `LbKey`'s row,
  `YlosGenIdentity` (enforced by construction since HEAP_072), A6 (the `"addr"` rows are
  `YlosGenIdentity`'s mutants), §9's `ylos_gen`, `hand_ylos`, `age_ylos` and P1-census rows, and the
  shadow-granule row, which now cites HEAP_071 (the 16-byte granule needs every survivor >= 16 B).
- **CR-037 (`lb_bodies`) is not fixed**: `markLargeBodySeen` still colours by address.
  `MC_lb_aba` and `MC_deep_boundary_k2_lb` still violate `NoDangling`. CR-017 and CR-038 are open too.
- T4 (bug 1): the shadow protocol is unchanged; the edit is a validate-only abort before the copy.

Coverage gap (for the canary, not the model): `youngLargeMember`, the `join_minor` field and the reset
in `registerLargeBody` sit outside every pin, and H8's regex does not match `youngLargeMember`. The
fix depends on all three. **Closed the same day**: new region pins `OGH.youngLargeMember` (M5),
`OGH.LargeBodyMeta` (M5, M8; the `join_minor = 0` default) and `OGS.registerLargeBody` (M3, M5, M8),
added with `--update` (228 pins). Negative control: `join_minor = 1` and `>=` in `youngLargeMember`,
in a copy of the tree, fire `OGH.LargeBodyMeta` and `OGH.youngLargeMember`.

Runs (2026-09-30, this tree): `run_models.py --tier quick`, 3 jobs × 4 workers: M5 64/64 in 159 s,
M1 22/22 in 63 s, M2 33/33 in 57 s, M3 12/12 in 8 s, all as expected. M5 deep rows `--config boundary`,
`ylos_stamp_k2` and `ylos_drop_k2`, one row at a time, 8 workers: 11/11 as expected in 1,173 s, with
state counts identical to the entries of 2026-09-29. `tla-trace` (harnesses rebuilt on this tree):
135/135 as expected in 140 s.


## 2026-09-30 — canary re-audit: register reproductions (GC_MODEL_001)

Pins fired: file TenureWork.hpp (1b0803bf3a66), region NT.TenureParEnv (53fc7d8f27b8).

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

Probes only, as pause points for the fork harness's `det-cr013-*` arms, which reproduce M5's three CR-013 fork counterexamples in code (TV1, TV3/TV4, TV6, L3 hang). CR-037 (`MC_lb_aba`) is reproduced in code at k = 1 and k = 2.

**Verdict: no model change needed.**

## 2026-09-30 — Step 0.4: the wider CR-038 variant (`MC_k2_ylos_walk2`) — CR-039 registered

Row added (plans/threaded-gc-register-fixes.md Step 0.4, decision 2): `MC_k2_ylos_walk2.cfg`, a copy
of `MC_k2_ylos_walk.cfg` with `YC = 2` (two YLOS cells) and `INVARIANTS T0GreyAllocated
YoungWalkValid` (T0GreyAllocated first: when both fail in the same state TLC names the first).
Quick tier.

**Verdict: `violates:T0GreyAllocated`** (1,859,910 states, 20 s, 4 workers). With `T0GreyAllocated`
alone: 1,827,950 distinct states, depth 89, the same chain. The counterexample is the suspected
chain exactly: Z = `Y1` joins generation 1 at minor 1; Y = `Y2` (slot → `Y1`) joins generation 2 at
minor 2; both die in epoch 2; minor 3 hands X1 over without reaching Z; minor 4 frees Z
(`ys[1] = Free`) while Y (generation 2, `yjoin = 2`) is still indexed, and the t0 walk at minor 4's
`MN_Cycle` reads Y's slot into the freed Z. Registered as **CR-039** (S1-class, opt-in k ≥ 2), with
the code guard `cr038Z` (`CR-039 [xfail CR-039]`, reproduced: t0 marks Z's `Tag_Free` cell) and a
control. §5.3 of the fix plan (the merge clears dead ageing-generation YLOS slots) covers it; its
mutant `skip_ylos_zap_2` will be hosted on this row. No code change, so the canary does not fire.

## 2026-09-30 — register-fixes Phase 3 (§5.1-§5.3): CR-037, CR-017, CR-038 and CR-039 fixed, models first (GC_MODEL_001, one audit for the batch)

Pins fired for M5: region `TLH.majorGC` (**dde8f0dcca5e**), region `NR.evacuateR` (**1e4eb8b5439c**),
region `NT.mergeJob` (**2892c92bf479**), grep `T1` (**c5204e1f0f08**: the zap's walk of a Young
extent's `[base, surv_top)`), grep `T2` (**55313b0b0e81**: step 5c's guard line mentions `heal`);
new region pins `OGS.markLargeBodySeen` (M5) and `NR.zapDeadAfterMajor` (M1, M5), added with `-`.

**§5.1 CR-037 (model, then code).** `LbKey`'s pre-fix value is renamed `"code"` → `"addr"`; `"kind"`
is THE CODE: `OGS.markLargeBodySeen` returns unless the entry is kind 0 with `body_base == body`.
`MC_lb_aba` (157,323 states) and `MC_deep_boundary_k2_lb` (135,627) stay `violates:NoDangling`,
re-commented as regression mutants of HEAP_072 (lb); `controls/lb_kind` = the code (pass, 636,386).
The `_cr034` boundary rows carry `"addr"` (the code of their time); the `_cr017` rows now carry `"kind"`.

**§5.2 CR-017 (NEW RULE: passed TLC before any code).** `MJ_Mark` frees, after the sweep, every S cell
of a Young extent not in `MajorLive` (`MajorZapX`; mutants `no_cr017_fix` = no zap, `zap_tenuring` =
Tenuring too, `zap_fresh_only` = age-1 only). Quick: `MC_cycle_major` pass, every invariant (866,366),
`MC_k2_cycle_major` pass, every invariant (2,042,764), `MC_cycle_major_t0grey` pass (866,366); mutants
`no_cr017_fix` YoungWalkValid (129,031), `_k2` YoungWalkValid (697,760), `_t0grey` T0GreyAllocated
(130,872), `zap_tenuring` NoDangling (306,143: the major reaches a merged extent only through its
copies, so the forwarded originals still named by roots would be zapped), `zap_fresh_only`
YoungWalkValid (830,230). Deep: `Cr017Oracle = FALSE` in `MC_deep_boundary` (pass, 40,407,300, 390 s),
`_k2` (pass, 14,167,540) and `_k2_m2` (pass, 24,369,088); `MC_deep_boundary_cr017` /
`_k2_cr017` = `MUTANT = "no_cr017_fix"` with the code otherwise, `violates:T0GreyAllocated` (1,406,258 /
86,892). The other deep rows: `deep_major` 5,412,606, `deep_cycle` 5,779,452, `deep_l3` 18,018,284,
`deep_ops4` 3,683,200, `deep_nf2` 2,550,988, `deep_k2` 37,922,800, `deep_ext` 56,432,788, controls
`ylos_drop_k2`, `ylos_stamp_k2`, `ylos_age1_boundary` (40,410,296) pass; `_cr034` rows violate
`YlosGenIdentity` as before. **`MC_deep` re-hosted** (the plan's trap): with the early CR-017
violation gone, the plan §6 bounds exceeded 58.8M distinct states and 9.5 GB of state files (the disk
filled), the boundary bounds at 4 minors 122.4M states (depth 92, 4.7 GB) and at 3 minors 156.5M
states, both unfinished within the disk. It now runs EC 2, SC 2, OC 4, MaxLid 4, NF 1, 3 minors,
2 operations, Collectors 2, majors, cycles and stops: **pass, 18,313,899 states, 120 s**; the same
bounds with `MUTANT = "no_cr017_fix"` (a scratch run) violate `YoungWalkValid` (105,978 states), so the
re-hosted row still reaches CR-017's chain.

**§5.3 CR-038 / CR-039.** `J_Merge` clears every slot of a `Gen(ageX)` YLOS not in `amark` (mergeJob
step 5c; mutant `skip_ylos_zap`). `MC_k2_ylos_walk` pass, every invariant (3,556,232);
`MC_k2_ylos_walk2` (CR-039) pass, every invariant (6,712,854): **the planned fix closes CR-039**, no
separate design was needed (the clearing happens at the merge of the job whose ageing mark missed Y,
which precedes the t0 that would read Y's slot to the freed Z). Mutants `skip_ylos_zap`
YoungWalkValid (976,535), `skip_ylos_zap_2` T0GreyAllocated (1,835,176). `YoungWalkValid` is back in
`MC_deep_boundary_k2` and `_k2_m2`.

Quick tier 72/72 as expected (253 s). Trace: `TraceTenurePause` maps the new event `mzap zapped`
into `MJ_Mark` (no longer hidden) and checks the zapped S-cell count; the harness records `mzap`; two
new reject rows (`set:mzap:2:zapped=0`, `set:mzap:1:zapped=1`, seed 2) are rejected; `run_traces.py
--model M5` 29/29. `T1`: the zap writes Young-extent survivor cells only in the major's pause (no job
runs: the major's `tenureJoin` merged it; the zap aborts otherwise). `T2`: step 5c writes ageing YLOS
slots in the merge, a pause step, never a heal slot of the running job. `NR.evacuateR`: a validate-only
header load (no protocol change).

**Verdict: model updated (MJ_Mark zap, J_Merge step 5c, LbKey rename), MAPPING.md updated (MJ_Mark,
J_Merge, LbKey, the lb_bodies footprint row, A6, canary pins).**

## 2026-10-01 — register-fixes §6.1: CR-019 fixed, relaxed atomic whole-word YLOS header access (GC_MODEL_001)

Pins fired: region `OGS.promoteYoungLarge` (**ab64ef2a56ee**), region `NR.reachYoungLargeR` (**183e2cd3fb44**), grep `T3` (**6e200a1c6e88**: the validate check now reads the local copy `hv.age`).

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

Region mode: the first reach still sets age 1 under `ylos_mu_` and joins generation m in the same section; only the access is now a whole-word relaxed load/store. No M5 action or variable changes. **Verdict: no model change needed.**

## 2026-10-01 — register-fixes §6.3: CR-007 fixed, no-wait acquire for a promotion holder with n > 1 (GC_MODEL_001)

Pins fired: region `OGS.releaseBlockToAllocator` (**2dc05c9c0440**).

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

The validate-only release abort; the pause tenure engine (`runJobParallel`) promotes through `allocatePromotion` and now gets the no-wait page policy, which changes which extent a page comes from, never a tenuring decision. **Verdict: no model change needed.**


## 2026-10-01 — register-fixes Phase 5: CR-013 tenure launch refused under a fork hold (GC_MODEL_001)

Pins fired: regions `TLH.minorGC` (**896f924a1e35**), `TLH.majorGC` (**69a04246e15b**), `NT.tenureLaunch` (**c844a0dfc358**), `NT.tenureConcLaunch` (**873a1bb7f7be**).

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

Model first: the three CR-013 rows `MC_fork`, `MC_fork_orphan_copy`, `MC_fork_l3` were moved to
`mutants/fork.cfg`, `mutants/fork_orphan_copy.cfg`, `mutants/fork_l3.cfg` with their verdicts unchanged
(`violates:TenuredEqualsLegacy` 41,129 states, `violates:ExactlyOnce` 26,767, `deadlock` 417,729),
labelled "pre-fix launch window; closed by fork_hold_": with the fix a collector launch during a fork's
prepare is refused (no member is mid-item at the fork; M6 `gangs_two_gangs_window` now passes, its
mutants `no_fork_hold` / `hold_after_stop` violate ChildHeldTenure). A refused launch leaves the job
Running with no member; `tenureJoin`'s orphan branch (`!running()`: `finish_here`) or, for L3,
`tenureConcFinish` finishes it in the pause, which is M5's existing "stopped before any item" path.
`TLH.minorGC` / `majorGC`: a validate-only owner check at entry. **Verdict: model rows moved to
mutants (A6); no spec change needed.** Code guards: fork-trace arms `det-cr013-{start,copy,copy-scan,
l3-exit,l3-minor}` clean (window closed by the refusal; the child's orphan path is sound); revert (no
hold): start/copy/copy-scan/l3-minor reproduce TV1, TV3/TV4, TV6, the L3 hang again.


## 2026-10-05 — wide objects Phase 1d: D-semantics walker split (GC_MODEL_001)

Pins fired: none (unpinned shared walkers HeapChildWalk / NurseryChildWalk / OldGenSpace
scanChildren / NurserySpace scanObject). Voluntary entry (plans/wide-object-tail-kind-words.md §5).

Change (plans/wide-object-tail-kind-words-phase-1.md §1d): the Custom/Record arms of scanEntryP
scan all `hdr->size` slots (header-bitmap loop, then a tail loop treating slots past 24/32 as
boxed); the Closure arm reads kinds through `closureSlotKind` (UB-free for n_values >= 32). The
object is frozen (HEAP_SNAPSHOT_001); kinds are plain reads of the object, as before; no atomic,
lock, memory order or step is added or reordered. The tail loop is dead in production (verifier
caps; builder asserts). **Verdict: no model change needed.**

The mark pass (`OldGenSpace` scanChildren) and the compaction fix pass use the same accessors, so
they still visit exactly the same slots.


## 2026-10-05 — wide objects Phase 2: closure packed word n:11|max:11|rk:2|kinds:40 + tail kind words (GC_MODEL_001)

Pins fired: none (unpinned shared walker `NurseryChildWalk.hpp`, reached by `scanEntryR` and the
tenure engine through `forEachChildSlot`). Voluntary entry (plans/wide-object-tail-kind-words.md §5).

Change: the walker's Closure arm is textually unchanged; `closureSlotKind` now reads params 20.. from
the closure's K = extWords(max_values, 20) tail extension kind words (inline kinds cover params
0..19). The object is frozen when tenured (HEAP_SNAPSHOT_001), the ext words are written only at
allocation (HEAP_077), and the object's size is still a function of its header word (header.size =
value slots + K), so promotion copies the ext words with the body. No atomic, lock, memory order or
step is added or reordered. **Verdict: no model change needed.**

## 2026-10-05 — wide-object-tail-kind-words Phase 3A (Custom/Record ext kind words) (GC_MODEL_001)

No pin fired; voluntary entry (unpinned NurseryChildWalk.hpp, reached by `scanEntryR` and the
tenure engine through forEachChildSlot, and the YLOS header fix-up; plans/wide-object-tail-kind-words.md §5).
Promotion copies getObjectSize bytes, so the ext words travel with the body.

Change: Custom/Record objects may carry K = header.unboxed extension kind words after
values[size] (HEAP_019, HEAP_077). Object size is still a function of the header word alone
(getObjectSizeFromHeader adds hdr->unboxed, which shares the 32-bit word with tag). The tail loop of
the Custom/Record scan arms reads the slot kind through customSlotKind / recordSlotKind, whose bodies
now add the ext-word branch (header bitmap, then the ext words, bounded by header.unboxed); the
walker text itself has been unchanged since Phase 1d. Ext words and K are written only at
allocation, before the object is reachable by any GC (HEAP_031/034/SNAPSHOT_001): initHeaderForTag
composes the header in a local and writes it with one 8-byte store, and the YLOS header fix-up in
OldGenSpace::allocateYoungLarge (not a TLA region) is one relaxed whole-word load/edit/store
(loadHeaderRelaxed / storeHeaderRelaxed). No atomic, lock, memory order, claim or publish is added;
the header word is the same modelled location; children are read from a frozen object.
Validate builds add validateExtKinds (K, padding, inertness census) in the serial scan, the
validate pre-walk and OldGenSpace scanChildren: reads only, abort on failure.
`tla-trace` after the change: 150/150 rows as expected.

**Verdict: no model change needed.**

## 2026-10-09 — plans/large-object-space.md: the large-object space, header-less bodies, O7 (GC_MODEL_001)

Change (plans/large-object-space.md, HEAP_080/HEAP_081): every old-gen-direct large object (split String/Bytes bodies, YLOS, pinned pointer-free objects, the permanent fallback) now lives in LOS blocks: ordinary `alloc_buffer_size` blocks acquired like bag pages and materialized with `BlockInfo::los` (page index, mark arena, region bounds unchanged), whose free space a mutator-only `LargeObjectSpace` manages (1 KiB granules, a bitmap per block); larger objects keep is_large blocks. Every LOS object is tracked in `large_bodies_` (kind 0 body, 1 YLOS, 2 old: `promoteYoungLarge` and `promoteLargeHeader` re-kind to 2 instead of erasing); `losSweepAtMarkEnd` (inside `finalizeMetaAfterMark`) frees unmarked tracked LOS entries and sets LOS `live_bytes` to used granules; empty LOS blocks beyond `los_empty_keep` are released after the reclaim. LOS blocks are excluded from the flip, reclaim, shrink, evacuation and lazy sweep (`fully_swept` stays true). Bodies are header-less in raw blocks (`kLosRaw`): `greyObject` marks them without a push. O7: `takeFreeAt` releases a reused extent's tail.

Pins fired: regions `OGS.greyObject` (**beee5d40d9af**), `OGS.sweepNurseryLargeBodies` (**5eae8e786621**), `OGS.promoteYoungLarge` (**c9b5ac30eae3**), `OGS.registerLargeBody` (**b84bdbca9fc6**).

The tenure paths are unchanged: `lb_bodies`/`lb_seen`/`lb_promoted` still name bodies by address, `markLargeBodySeen` colours kind 0 only, `promoteLargeHeader` (now a re-kind to 2, keeping the entry, so trap 14's "promoted body still indexed" holds a fortiori) and `promoteYoungLarge` (re-kind) run at the merge as before. `YlosGen` = "stamp" (HEAP_072's `join_minor`) is still the code; id recycling changed only in that kind-2 retirements now recycle ids, and the model's `ylos_lbid` control already shows ids are not a stamp. With the LOS, bodies (raw pool) and YLOS (object pool) never share a cell, so the model's shared Y cells (`lalloc` bodies and YLOS) are a superset of the code's behaviours. `greyObject`'s raw arm: see M1. **Verdict: no model change needed.**
