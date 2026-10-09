# M2 — audit log

Dated entries, newest last. Each records what was checked against which tree, the verdicts, and
every change to the model. A canary re-audit (parent plan §7.4) adds an entry here quoting the new
hash prefix. The canary is not built yet.

## 2026-09-29 — first implementation, trace validation

**Tree:** 2026-09-29 (post-7c), with the compiled-out `ECO_TLA_TRACE` hooks of the trace agents,
M2's included (below). **Tools:** the dev image: tla2tools 1.8.0 (TLC 2026.09.25 rev 8f4bc8b) with
CommunityModules, g++ 12, clang 14. The model was started by an earlier agent (its scratch work,
checked again here before use); every result below was re-run for this entry.

### What was checked against the code

`MarkWork.hpp` in full, the five `Env`s (`ParallelEnv`, `MinorEnv`, `RegionEnv`, `AgeParEnv`,
`TenureParEnv`), `publishHalf`/`publishAll`/`pushGrey` and their `P` versions, `runMarkers`,
`launchBackground`, `bgEntry`/`assistEntry`/`closingEntry`, `reapBackground`, `assistEpisode`,
`closingFinish`, `tenureConcLaunch`/`tenureConcFinish`, every `SliceControl` construction (victims vs
participants), `GCBackgroundGang::stopAndJoin` and `GCMarkGang::run`. MAPPING.md §2 maps every label
to its line; §4 gives each abstraction's argument. Every write of `SliceControl::state` and `budget`
is in `MarkWork.hpp` (grepped). Two gaps between the plan and the code were closed in the model: the
pop-side `publishHalf` (`takeOwn`'s every-64-pops call, now `R_PopPub*`) and several assists per
episode (the joiner's loop).

### Results

Quick tier (`run_models.py --model M2`, 2 × 2 workers): **33/33 as expected** (228 s; the final
run after every change, 245 s on a loaded machine). The states of a failing row vary a little from
run to run (TLC stops at the first violation it meets).

| Configuration | Expected | Result | States | Time |
|---|---|---|---|---|
| `slice` | pass | pass | 2,293 | 2 s |
| `slice3` (three participants) | pass | pass | 563,851 | 21 s |
| `slice_dq` | pass | pass | 2,118 | 3 s |
| `minor` | pass | pass | 1,065 | 2 s |
| `episode` | pass | pass | 2,219,701 | 71 s |
| `episode_bgstop` | pass | pass | 1,470,774 | 54 s |
| `episode_stop` | violates `ClosingFinished` (CR-005) | as expected | 5,058 | 3 s |
| `episode_stop_drain` (every other invariant) | pass | pass | 2,195,001 | 76 s |
| `tenure_l3` | pass | pass | 4,924 | 2 s |
| `help` | pass | pass | 2,409 | 2 s |
| `help_priv` | pass | pass | 3,527 | 2 s |
| `wrap` (1-bit epoch, three participants) | witness `TerminationSafe` | as expected | 749,772 | 20 s |
| `liveness_minor`, `liveness_slice`, `liveness_help_priv` (`AllExit`) | pass | pass | 2,834; 3,692; 8,730 | 3–4 s |
| `idle_before_publish` on `slice`, `slice3`, `episode` | pass | pass | 2,944; 700,772; 2,535,184 | 2 s, 22 s, 77 s |
| 15 failing mutants | each its target | each as expected | 13 – 440,347 | 2–15 s |

Deep tier: see the end of this entry.

### Finding 1: three expected failures needed a steal the code cannot make

The model's `stealAny` may return "found nothing" while a victim holds work (plan §4.1): a real
outcome when a victim was read before its owner pushed, or four passes lost CASes to other thieves.
Every pass configuration keeps it unlimited. But a counterexample built on it is only real if such a
steal is possible in that state. Re-running every expected failure with give-ups allowed only when
every other deque is empty (`CapGiveUps`, `MaxGiveUps = 0`: behaviours the code certainly has):

| Configuration | Unlimited give-ups | Only realizable give-ups |
|---|---|---|
| `two_word` on `slice` (the plan's host) | fails | **passes** (2,115 states) |
| `anywork_participants_only` on `help` | fails | **passes** (1,025 states) |
| `wrap` on `slice` (the plan's host) | fails | **passes** (4,012 states) |
| every other mutant, `episode_stop` | fails | fails |

In all three the shortest trace has a participant give up while an idle participant's published
entries sit in its reach, with no other thief: `stealAny` returns that entry. So:
- **`two_word`**: with two participants the historical race only damages a slice through that
  impossible steal. In today's loop an active participant never looks at `done`: it scans until its
  tickets or the reachable work run out. It moves to `slice3`, where the plan's §2.3 story is
  realizable: D reads `active == 0`; A and C reactivate; A claims the rest of the budget and takes the
  only entry, C's claim gets the last ticket and its steal finds nothing (A holds the entry in its
  ring); D reads `budget == 0` twice and stores `done`; C returns its ticket: `done` with budget left
  while A is active with work.
- **`anywork_participants_only` on `help`** cannot fail: slot 3 only ever loses work (no participant
  owns it), and the first steal takes the root. Dropped; the `episode` row stays (the assist leaves
  its published work in slot 1, which the members' `anyWork` skips).
- **`wrap`** moves to `slice3` (MAPPING.md §6 has the realizable ABA).

Every expected-failure configuration now runs with realizable give-ups only, so every counterexample
below is one the code can produce (modulo the model's other abstractions). The pass configurations
keep the over-approximation.

### Counterexamples read (all at realizable give-ups)

Every counterexample was read against its story.
- **`two_word`** (`slice3`): as above, 37 steps.
- **`return_after_idle`**: marker 2's steal finds nothing (legitimately), it goes idle holding 2
  tickets; marker 1 publishes 2 and 3, goes idle, reads `budget == 0` twice and decides; the tickets
  come back: `done`, budget 2, two entries left. No give-up needed, as the plan says.
- **`idle_before_publish`** (`slice_dq`): marker 1's claim fails, it goes idle before publishing;
  marker 2 returns its ticket, goes idle, sees two empty deques twice and decides with 2 and 3
  private.
- **`idle_before_publish_onescan`** (`slice`, priv counted): the decider reads deque 1 empty, marker
  1 publishes (2, 3, then `priv = 0`), the decider reads `priv[1] = 0` and commits without the
  re-check. The same mutant with the re-check passes (`idle_before_publish_slice`, `_slice3`,
  `_episode`).
- **`skip_exit_publish`** (`episode_bgstop`): member 2 is stopped with 2 and 3 private and leaves
  without publishing: `Drain` fails at the end. On `tenure_l3` the same with a stopped collector.
- **`split_tas`** (`minor`): both scanners read node 4 unmarked, both push it, it is scanned twice.
- **`steal_without_ticket`** (`slice`): marker 2 steals entry 2 with the budget spent, its claim
  fails and it scans anyway: four scans, three tickets.
- **`assist_returns_to_budget`** (`episode`): the assist claims its 2 tickets, a member has the
  root, the assist's steal finds nothing and it returns the tickets to `c.budget` (40): `AssistExact`.
- **`joiner_no_reactivate`** (`episode`): the assist never counted itself, so its `goIdle` at the
  exit uncounts member 2 while it scans the root; member 3 decides with member 2 pushing children.
  The plan's story (the joiner itself invisible) is the new **`joiner_invisible`**: the assist holds
  the root in its ring, both members idle and decide, the assist pushes 2 after the decider's scan.
- **`stop_sets_done`** (`episode_bgstop`): member 3 idles (member 2 holds the root), sees the stop
  and sets `done` while member 2 is active.
- **`anywork_participants_only`** (`episode`): the assist steals the root, scans 1 and 3, runs out of
  pool and publishes 2 and 4 into slot 1; the members, idle, scan slots 2 and 3 only and decide.
- **`budget_premise`**: 3 tickets in a drain configuration with the budget loads folded; the budget
  reaches 0.
- **`never_decide`**: every participant idles for ever (`AllExit`).
- **`episode_stop` (CR-005)**: the closing joiner bumps `share_epoch`, the stop arrives, both members
  leave on it (the root stays in deque 2), the joiner reactivates (the control is not done), sees the
  stop at its loop top and leaves: at `J_ClosingCheck` every member is done and `done` is false.
  `episode_stop_drain` passes: the leftover is in the deques for the plain drain.
- **`wrap`**: MAPPING.md §6, 48 steps.

### 05c trap 5 (plan §5, step 4) and the W2 cross-check

`idle_before_publish` (publish after `goIdle`, nothing else changed) **fails** with a deques-only
`anyWork` (`slice_dq`) and **passes** with `priv` counted (`slice`, `slice3`, `episode`). With `priv`
counted but the decider's re-check removed (`idle_before_publish_onescan`) it fails again: a scan can
miss a slot whose owner publishes between the scan's deque load and its `priv` load. So under SC the
answer to trap 5 is: the order is not load-bearing in the mark environment, because `priv` **and**
the double scan together cover it; it is load-bearing in every deques-only environment.

This agrees with W2 (`test/genmc/AUDIT.md`): `w2_idle_before_publish` fails under RC11 and passes
under SC (`-sc`), and `w2_idle_before_publish_onescan_sc` fails under SC. The SC answers of the two
tools match row for row; under C11 the order is load-bearing even in the mark environment (the
relaxed `priv` and deque loads can both miss), which is why the code publishes before `goIdle` in
every environment.

### Changes from the plan's sketch (plan §4.5), and why

1. **Steps merged at shared accesses** (primer §4): the loop-top `stop` and `share_epoch` loads
   fold when constant; a claim with a ticket in hand is the take's step; the first push of a
   publish folds into `emptyApprox` or the call's step; the first child's test-and-set into the
   scan; an empty `publishAll` or a zero `returnTickets` is no step. The joiner's `reactivate` is a
   Joiner step before the call. `episode` went from over 5 M states to 2.2 M.
2. **`BudgetNeverEmpty`**: a drain's two idle budget loads have a fixed outcome and fold away.
   `BudgetOK` checks the premise in every state; `budget_premise` (the operator overridden to TRUE
   with a 3-ticket budget) shows it can fail.
3. **`Saved`**: with an exact epoch the decider keeps only `active`'s sign of `s` (MAPPING.md §4).
4. **The pop-side `publishHalf`** (`R_PopPub*`, the plan's open question 3): adds no state at
   model-check scale; the trace needs it.
5. **The joiner loops over `AssistRuns`** (the plan's `AssistRuns ∈ {0, 1}`): the episode trace makes
   several assists. The configurations use at most one, with the same state counts.
6. **`GreyKid` takes children in id order** (`Min`): TLC's `CHOOSE` already did; now explicit,
   because the trace's harness greys children in field order.
7. **Expected failures use realizable give-ups** (Finding 1); `two_word` and `wrap` on `slice3`;
   `anywork_participants_only` on `help` dropped.
8. **Mutants added** beyond the plan's list: `idle_before_publish_onescan` (the SC half of the W2
   cross-check), `joiner_invisible` (the plan's joiner story), `skip_exit_publish` on `tenure_l3`
   (open question 2), `budget_premise` (for `BudgetOK`). **Configurations added**: `slice3`,
   `episode_stop_drain`, `liveness_slice`, `liveness_help_priv`, deep `liveness_slice3`.
   `liveness_minor` and `never_decide` run in 3 s and moved to the quick tier; `wrap` too (20 s).
9. The plan's `Postcondition` (`Drain ∧ TicketsExact`) is kept as a name; the configurations list
   the two separately.

### The plan's open questions

1. 7c's help needs nothing from the stopped control but "all work in the deques": `help` and
   `help_priv` start from that state alone and pass; `tenureConcFinish` builds a fresh
   `SliceControl` and reads only `done()` and the counters.
2. No stop path of the deques-only environments exits with private work: every exit publishes
   (`tenure_l3` passes; `skip_exit_publish` on `tenure_l3` shows the publish is what makes it pass).
3. The pop-side `publishHalf` is modelled (change 4).

### The weak spot the model assumes: CR-010 (IM14's assertion points)

The model starts every run from its initial distribution and ends it when every participant has
returned; between the two, nothing outside the loop touches a slot's owner-only state or retires a
deque array (MAPPING.md §4, §7). By reading, every mutator touch in the tree keeps that per slot:
`launchBackground` (asserted), `runMarkers` (retirement only when `bg_ep_ != Running`),
`reapBackground` and `closingFinish` (after the joins), the nursery drains and `tenureConcFinish`
(before the launch, after the join). But `assistEpisode` and `closingFinish` reset the **foreground**
slots' counters (`ctr.resetRun`) while the background gang legitimately runs, so
`assertSlotsQuiescent` as written (`bg_->running() || fg_run_active_`) would abort at exactly the
points CR-010 proposes to assert. The model's precondition is per slot ("the slot's owner is not in a
run"); the assertion needs the same slot range that `assertNoPrivateWork` already uses (foreground
slots only while an episode runs). Recorded for the register (not edited here).

### Trace validation (plan §8, rule A5)

**What was built** (MAPPING.md §9 has every event, hook and model step):
- **Hooks** in `MarkWork.hpp` (19 call sites, compiled out unless `-DECO_TLA_TRACE=1`): the run's
  start and exits, claims and returns (the control's budget chained by value), takes, scans,
  steals and give-ups, `goIdle`, `reactivate` and its `done` answer, the idle loop's `done` and
  stop exits, and the done-CAS (both outcomes). A trace-only serial per `SliceControl` and a
  thread-local "current run" give the fields (`tlaNextCtl`, `tla_run`).
- **Harness** events in `mark_harness.cpp`'s `SynthHeap` (private push, each publish push, the `priv`
  store ending a publish) and two trace scenarios, `slices` and `episode`, in the trace build
  `gc-mark-trace` (new target in `test/gc-helper-tsan/CMakeLists.txt`, behind the project's
  `ECO_TLA_TRACE` option). The TSan build is unchanged (the scenarios are argv-selected; with no
  arguments `main` runs the old storms).
- **Spec** `TraceSliceControl.tla` (+ `TraceSlices.cfg`, `TraceEpisode.cfg`,
  `TraceSliceControl.keep`): the model's own steps constrained by each event, a fresh control per
  slice (`NewCtl`), the hidden steps listed exactly (`HiddenAt`), any order the log allows.
- **Production unchanged:** `MarkWork.hpp` preprocessed with `EcoRuntimeStatic`'s flags (clang,
  `-O2 -g -UNDEBUG`, its defines and includes) has no trace token and exactly 19 `((void)0)`, one per
  hook. `OldGenSpace.cpp`, `NurseryParallel.cpp`, `NurseryRegion.cpp`, `NurseryTenure.cpp` compile
  (`-fsyntax-only`) with and without `-DECO_TLA_TRACE=1`, with only their existing warnings;
  `mark_harness.cpp` and `minor_harness.cpp` compile warning-free (g++ `-Wall -Wextra`). GenMC's W1
  and W2 rows compile the hooked header: 21/21 as expected.

**Results** (`run_traces.py --model M2`, 2 rows at a time, 2 TLC workers each): **20/20 as expected
in 139 s** (the final run; an earlier run of the first 18 rows: 18/18 in 77 s).

| Row | Events | Expected | Result | TLC states | Time |
|---|---|---|---|---|---|
| `slices,2,6,0,4,3,1,50` | 93 | accept | accept | 620 | 2.4 s |
| `slices,2,8,64,6,4,2,100` | 450 | accept | accept | 9243 | 7.9 s |
| `slices,3,10,20,8,3,3,200` | 292 | accept | accept | 14930 | 6.6 s |
| `episode,2,6,20,2,4,1,2,200` | 127 | accept | accept | 182951 | 26.0 s |
| `episode,2,30,0,1,3,1,3,200` | 32 | accept | accept | 9355 | 5.4 s |
| `episode,2,4,0,1,2,0,5,0` | 56 | accept | accept | 25266 | 5.8 s |
| `episode,2,4,0,0,2,2,5,0` | 42 | accept | accept | 3063 | 3.2 s |
| `slices,2,8,64,6,4,2,100` `drop:mw.scan:1` | 449 | reject | reject | 17 | 2.7 s |
| `slices,2,8,64,6,4,2,100` `set:mw.claim:1:took=99` | 450 | reject | reject | 5 | 3.0 s |
| `slices,2,8,64,6,4,2,100` `set:mw.idle:1:act=7` | 450 | reject | reject | 53 | 3.3 s |
| `slices,2,8,64,6,4,2,100` `drop:mw.pub:1` | 449 | reject | reject | 41 | 3.5 s |
| `slices,2,8,64,6,4,2,100` `drop:mw.seeDone:1` | 449 | reject | reject | 89 | 3.3 s |
| `slices,2,8,64,6,4,2,100` `set:mw.end:1:units=99` | 450 | reject | reject | 93 | 3.0 s |
| `episode,2,6,20,2,4,0,1,200` `set:mw.assistEnd:1:units=99` | 204 | reject | reject | 43598 | 10.2 s |
| `episode,2,6,20,2,4,0,1,200` `set:mw.assist:1:budget=7` | 204 | reject | reject | 126 | 2.9 s |
| `episode,2,6,20,2,4,0,1,200` `set:mw.react:1:act=9` | 204 | reject | reject | 8910 | 4.8 s |
| `episode,2,6,20,2,4,0,1,200` `drop:mw.closing:1` | 203 | reject | reject | 143254 | 19.5 s |
| `episode,2,6,20,2,4,1,2,200` `drop:mw.stopReq:1` | 126 | reject | reject | 163528 | 20.4 s |
| `episode,2,4,0,0,2,2,5,0` `drop:mw.reactDone:1` | 41 | reject | reject | 2950 | 3.0 s |
| `episode,2,6,20,2,4,0,1,200` | 204 | accept | accept | 1018739 | 130.7 s |

Beyond the registered rows, 44 more harness runs were all accepted: 20 with the first pacing (the
registered argument sets with other seeds, and `slices,2,12,30,10,5,*,0`,
`episode,1,10,10,3,3,0,*,100`), 10 with the final pacing (below), and 14 while building the spec.
Across them the logs hold every event kind: publishHalf on the push side (the 64-leaf hub),
steals, give-ups, reactivations (dozens per episode: an idle member keeps seeing another's `priv`),
failed done-CASes, joins that find the control done, stops seen at the loop top and in the
idle loop, the assists' pools and the closing join. No log shows the pop-side `publishHalf` (a stack
never reaches 64 on a 64th pop in these graphs).

**Findings.** No code defect, and no model error: every rejection seen while building was the trace
spec's own mistake, fixed before the rows were registered:
- the done-CAS's outcome was read from the word's `done` bit after the step; a failed CAS against a
  word someone else had just made done looked like a success. It is now "the step changed the word";
- an `IF ... THEN ... ELSE` swallowed the conjunction after it (the joiner's `mw.run` check);
- `Reachable`, a constant only `Drain` uses, was evaluated at TLC's start before the log was cached,
  re-parsing the log for every edge (minutes at start-up); the trace configurations replace it.

**An observation on the code (not a defect).** With `priv` counted (`ParallelEnv`), an idle member
that sees another's private work re-wakes, claims a batch, finds nothing to take or steal, returns
it and idles again, for as long as the owner holds that work: four RMWs on the shared state word
and budget per round. One episode log under a loaded machine held 3,737 such rounds (22,572 events)
while the owner scanned 28 entries with private work in hand (the harness paused inside those
scans). The nursery environments dropped `priv` from `anyWork` for this cost (06 P§10.1); the mark
environment keeps it, and it is what makes trap 5 harmless there (above). The harness now pauses
only while the scanner holds no private work; episode logs are 150–210 events again. Recorded for
performance work, not the register.

**Limits.**
- Three background members (`episode,3,12,40,3,6,0,*,150`, 914 events, with the first pacing) did
  not finish in TLC: over 7 M states after 12 minutes. The registered episodes have two members; the model checks three
  participants (`slice3`, `wrap`) and the joiner.
- The harness's heap is `SynthHeap`, a mirror of `ParallelEnv`; the nursery environments' loops are
  traced only through M3's minor trace, which records these events and drops them (below).
- The trace does not order the idle loop's loads (not logged: a spinner would log thousands); the
  spec places them wherever the model allows, which is the model's own nondeterminism.

**The other models' traces.** `MarkWork.hpp`'s hooks also fire in M3's `gc-minor-trace` (the real
`runMarkerLoop` over `Copier::Env`) and M1's tiny-graph `gc-heap-trace` (the real allocator), both of
which record every event; their `.keep` files drop the `mw.*` events after the merge. Run once with a
private build directory: M3 15/15 as expected (its raw logs carry the new events; every merge
succeeded); M1's tiny-graph rows: every merge succeeded with the `mw.*` events in the raw logs
(e.g. 614 events, 320 kept), and the 5 negative controls were rejected, but the 4 `accept` rows were
**rejected at the M6 agent's new probes** (`probe("m6.closing")`, `"m6.stopset"`,
`"m6.bg.stopped"` in `OldGenSpace.cpp` / `GCHelperPool.cpp`): `tiny_graph.cpp`'s probe callback logs
a `marks` event for every probe, and `TraceHeap` reads a `marks` that is not a handoff's as a STW
major's. The first unmatched event of each rejected row is such a `marks`; none involves M2's
hooks. Reported to the orchestrator (M1 and M6 own those files).

### Deep tier (`run_models.py --tier deep --model M2`, once, 4 workers, under the shared lock)

**2/2 as expected in 713 s.**

| Configuration | Expected | Result | States | Time |
|---|---|---|---|---|
| `deep_episode` (5 nodes, two roots, ring 2, one assist, the closing join) | pass | pass | 2,980,776 | 78 s |
| `liveness_slice3` (`AllExit`, three participants, priv counted) | pass | pass | 2,918,683 | 10 min 35 s |

The first draft's 5-node episode had passed 22 M states without finishing (plan §6.1); the step
merges bring it to 3 M.

### For the orchestrator (the register and the parent plan are not edited here)

- **CR-005:** reproduced independently by M2's `episode_stop` (`violates:ClosingFinished`, 5,058
  states; story above): a stop during the closing join. With the assert compiled out the leftover
  is in the deques for the plain drain (`episode_stop_drain` and `help_priv` pass).
- **CR-010:** the analysis above: the proposed assertion points need a slot range.
- **New, a footprint gap (not a defect):** 06 P§3.11 has no row for the parallel minor's worker slots
  (`MinorWorker` stack, `priv`, deque, counters) or its `SliceControl`; M2 covers them as H10's
  shape (MAPPING.md §5). Proposed: a P6.M17 row "worker slots and the drain's `SliceControl`".
- **Plan corrections (Finding 1):** `two_word` and `wrap` need three participants to fail through
  steps the code can take; `anywork_participants_only` on `help` cannot fail.
- **Harness note:** `SynthHeap::publishAll` stores `priv = 0` even on an empty stack, where
  `OldGenSpace::publishAll` returns first; a store of the value already there, harmless.

## 2026-09-29 — canary baseline (GC_MODEL_001)

The canary (`test/tla/manifest.txt`, `tla-canary` in every build) was first pinned today: 31 pins
name this model (6 census, 3 file, 5 grep, 17 region); the list is in MAPPING.md's "Canary pins (A9)" block. This is the
baseline: the pinned code is the code this model was checked against today (after the trace hooks,
wave 3's fixes and the `TLA-REGION` markers landed). From now on, a pin that fires needs an entry
here quoting the new hash prefix before `check-tla-manifest.sh --update` accepts it.


## 2026-09-30 — canary: HEAP_071 and HEAP_072 merged (GC_MODEL_001)

New hash prefixes: 3c350fb64616 (`NR.minorGCRegion`).

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

**Verdict: no model change.** The edits are in the hand-over prep, which runs in the pause before
any worker starts. The slice, episode and help control that M2 describes is unchanged.

Runs (2026-09-30, this tree): `run_models.py --tier quick`, 3 jobs × 4 workers: M5 64/64 in 159 s,
M1 22/22 in 63 s, M2 33/33 in 57 s, M3 12/12 in 8 s, all as expected. M5 deep rows `--config boundary`,
`ylos_stamp_k2` and `ylos_drop_k2`, one row at a time, 8 workers: 11/11 as expected in 1,173 s, with
state counts identical to the entries of 2026-09-29. `tla-trace` (harnesses rebuilt on this tree):
135/135 as expected in 140 s.


## 2026-09-30 — canary re-audit: register reproductions (GC_MODEL_001)

Pins fired: NT.TenureParEnv (new hash prefix 53fc7d8f27b8).

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

The one edit in the pinned region is the trace-only `m5.l3.claimed` probe after the claim loop; M2's slice, episode and help control is untouched.

**Verdict: no model change needed.**

## 2026-09-30 — register-fixes Phase 0, Step 0.3: test accessors (GC_MODEL_001)

Pin fired: grep H12 (`OldGenSpace.hpp` test hooks), new hash prefix **3167be7a492d**.

Change (plans/threaded-gc-register-fixes.md Step 0.3; snapshot `snapshots/register-fixes/pre-phase0.tgz`):
a new negative-control field `OldGenSpace::test_idle_uncounted_` (default false; read by CR-018's
fix in §3.2, nothing reads it yet) and two `OldGenSpaceTestAccess` accessors, `setIdleUncounted`
(sets the hook) and `sweepTailInPromotion` (reads the existing stats counter
`alloc_stats_.bm.sweep_tail_in_promotion`). Unit tests call them only. No atomic step, lock,
shared location or memory order on any production path changes; M2's slice, episode and help
control is untouched.

**Verdict: test accessor, no model change.**

## 2026-09-30 — register-fixes §3.5: CR-036 negative-control hook (GC_MODEL_001)

Pin fired: grep H12 (`OldGenSpace.hpp` test hooks), new hash prefix **c9364ed6abde**.

Change: a validate-only negative-control field `test_im5_ignore_gen_` (IM5 without the new
generation compare) and its `OldGenSpaceTestAccess::setIm5IgnoreGeneration`; plus the test
accessors `blockGeneration`, `captureT0Blocks`, `t0BlocksChangedWhy`, `clearT0Blocks`. Tests only;
M2's slice, episode and help control is untouched.

**Verdict: test accessor, no model change.**

## 2026-09-30 — register-fixes Phase 2 (§4.1-§4.4): CR-014, CR-001 (race), CR-002, CR-028 fixed (GC_MODEL_001, one audit for the batch)

Pins fired for M2: Census `runtime/src/allocator/OldGenSpace.cpp` (**2afe7bc4cf4d**: the relaxed `std::atomic_ref<GCPhase>(gc_phase_)` store in `lazySweep`'s `completeSweep` and the relaxed loads in `finalizePoppedCellW`, `finalizeBitmapCellW` and the validate-only PM8 check) and census `runtime/src/allocator/OldGenSpace.hpp` (**493c238780a8**: `static_assert(std::atomic_ref<GCPhase>::is_always_lock_free)`).

The new atomic lines are `gc_phase_` accesses inside parallel promotion (M4's domain). M2's slice, ticket, episode and termination control is untouched; no new atomic or lock in its footprint.

**Verdict: no model change needed.**


## 2026-10-01 — register-fixes Phase 5: CR-005 closingFinish accepts a stopped episode (GC_MODEL_001)

Pins fired: regions `OGS.launchBackground` (**011248915015**), `OGS.runCycleStepConcurrent` (**289cdccf4bd4**), `OGS.closingFinish` (**af1f59d07ebb**), `NT.tenureConcLaunch` (**873a1bb7f7be**).

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

Model updated FIRST (before the code): `ClosingFinished` (SliceControl.tla) is now
`word.done \/ stop` for the closing check (closingFinish accepts an episode a foreign stop ended, and
the drain finishes it: `episode_stop_drain` already passed); `MC_quick_episode_stop` flips from
`violates:ClosingFinished` to **pass** (2,080,859 states; it now also checks TerminationSafe, ScanOnce,
Drain). New A6 mutant `member_exits_undone` (an idle member leaves with neither done nor a stop, in
`I_Stop`): **violates ClosingFinished** (529,943 states). PlusCal re-translated. `run_models.py --model
M2`: 34/34 as expected. A refused launch never starts a member (no marker loop runs), so the Drain
contract is unaffected; `tenureConcLaunch`'s refusal leaves the L3 job to `tenureConcFinish` in the
pause (M2's `MC_quick_tenure_l3` help path). **Verdict: model updated (ClosingFinished, mutant).**

## 2026-10-05 — Windows link: the paced assist's expected-work product without __int128 (GC_MODEL_001)

Pin fired: region `OGS.runCycleStepConcurrent` (**d618e7fcb354**).

Change: the paced assist's `expected = cycle_predicted_ * num / H` (P§3.5, GC_DET_001) was computed
in `unsigned __int128`, whose divide lowers to `__udivti3`, which the MSVC runtime lacks (`ecoc.exe`
failed to link on Windows). It is now `q * num + (r * num) / H` with `q, r = predicted / H,
predicted % H`: exact, because `num <= H` keeps `q * num <= predicted`, and `T` is a `uint32_t`, so
`r * num < H * H < 2^62`. Checked against the `__int128` form on 20,000,075 cases, the edges included
(predicted = 2^64 - 1, H = 2^31): no mismatch. Same value on every platform, so the decision stays
deterministic. No atomic step, lock, shared location or memory order changed. M2 takes the assist count
`k` as owner-only and models what an assist does (`J_Start`, `J_AssistCheck`), not how its budget is
computed; the decision and `k` are unchanged.
**Verdict: no model change needed.**

## 2026-10-09 — plans/large-object-space.md: the large-object space, header-less bodies, O7 (GC_MODEL_001)

Change (plans/large-object-space.md, HEAP_080/HEAP_081): every old-gen-direct large object (split String/Bytes bodies, YLOS, pinned pointer-free objects, the permanent fallback) now lives in LOS blocks: ordinary `alloc_buffer_size` blocks acquired like bag pages and materialized with `BlockInfo::los` (page index, mark arena, region bounds unchanged), whose free space a mutator-only `LargeObjectSpace` manages (1 KiB granules, a bitmap per block); larger objects keep is_large blocks. Every LOS object is tracked in `large_bodies_` (kind 0 body, 1 YLOS, 2 old: `promoteYoungLarge` and `promoteLargeHeader` re-kind to 2 instead of erasing); `losSweepAtMarkEnd` (inside `finalizeMetaAfterMark`) frees unmarked tracked LOS entries and sets LOS `live_bytes` to used granules; empty LOS blocks beyond `los_empty_keep` are released after the reclaim. LOS blocks are excluded from the flip, reclaim, shrink, evacuation and lazy sweep (`fully_swept` stays true). Bodies are header-less in raw blocks (`kLosRaw`): `greyObject` marks them without a push. O7: `takeFreeAt` releases a reused extent's tail.

Pin fired: census `OldGenSpace.cpp` (**714b07d48107**): one relaxed `atomic_ref<uint64_t>::fetch_add` on `BufferMetadata::live_bytes` in `OldGenSpace::attributeNewCell` (allocate-black for a header-less LOS body), the same location and order as `initObjectHeaderWithSize`'s. Mutator only, no slice/ticket/termination state. **Verdict: no model change needed.**
