# Threaded GC — TLA+ model M2: the marker loop, tickets and termination

**Status (2026-09-29): IMPLEMENTED**, steps 1–9 except the canary lines (`test/tla/manifest.txt`,
not built yet; MAPPING.md §10 lists them). The model, results and every change from this plan are
in `test/tla/M2-slice-control/` (MAPPING.md, AUDIT.md): `tla-check` 33/33 as expected; CR-005
reproduced by `episode_stop`; trace validation on `gc-mark-trace` (`slices`, `episode`) accepts
real runs and rejects every doctored log. Corrections to this plan found while implementing:
`two_word` on `slice` and `wrap` on `slice` fail only through a steal the code cannot make (both
moved to three participants), and `anywork_participants_only` on `help` cannot fail (dropped);
see AUDIT.md, Finding 1. The text below is the plan as reviewed.

**Plan status:** IMPLEMENTATION-READY PLAN (2026-09-28). **Adversarial review on 2026-09-28 against the
current tree** (§11): two dead mutants, a dead `wrap` configuration, an assert-based check the runner
cannot match, a merged `anyWork` load and a missing environment shape were corrected. The PlusCal
sketch in §4.5 is the corrected one; it passes the PlusCal translator and SANY (tla2tools 1.8.0,
`pcal -nocfg` then `sany`, no errors). **TLC has not run on this version.** An earlier draft was
model-checked during exploration; §6.1 records what that showed. Its numbers guide the
configurations but are not results.

**Parents:** `plans/threaded-gc-tla-verification.md` (§2 rules A1–A9, §5.1 index) and
`plans/threaded-gc-tla-primer.md` (read first if TLA+ or the GC terms are new).

**Why M2 is first:** it is the smallest model and the one with the most reuse. The same C++
template, `markwork::runMarkerLoop`, drives five different kinds of parallel GC work:

| Environment (`Env`) | File | Used by | `anyWork()` counts | Initial work | Victims `c.n` vs participants |
|---|---|---|---|---|---|
| `OldGenSpace::ParallelEnv` | `OldGenSpace.cpp:3480` | 5b slices, 5c background episodes, assists, closing joins | deques **and** private stacks (`priv`), slots 0..`mark_slots_`−1 | 5b: the t0 greys on slot 0's **private stack** (`markHPointer` → `pushGrey`); 5c: round-robin into the background deques (`launchBackground`) | 5b: F participants over F+B victims (`runMarkers`, `:3547`); 5c: B members plus F joiners over F+B |
| `NurserySpace::MinorEnv` | `NurseryParallel.cpp:148` | phase 6 parallel minor | deques only | round-robin into the deques (`:727-735`) | equal (`:741`) |
| `NurserySpace::RegionEnv` | `NurseryRegion.cpp:280` | 7b region minor | deques only | round-robin (`:854-861`) | equal (`:864`) |
| `NurserySpace::TenureParEnv` | `NurseryTenure.cpp:931` | 7c tenure: pause engine, help, and the L3 background collectors (which can be **stopped**) | deques only | round-robin (`tenureParDistribute`, `:1104`) | pause engine and L3: equal; **help: p participants over V = max(B, p) victims** (`tenureConcFinish`, `:1253`) |
| `NurserySpace::AgeParEnv` | `NurseryTenure.cpp:170` | 07b ageing mark in a pause | deques only | round-robin (`:294-297`) | equal (`:302`) |

The template is the same in all five. The differences that matter to the protocol are the columns
above, the roles (joiners and Assists exist only in `ParallelEnv`), the budget (a finite budget
only in 5b slices; everything else drains with `kDrainBudget`), and stop (5c episodes and 7c L3
only). No `Env` pushes work into a slot from outside the loop while a run is live: the t0 roots,
the round-robin transfers and `launchBackground`'s moves all happen before the launch (IM14). Two
test hooks change the protocol and are modelled as mutants: `test_leave_private_on_exit_`
(`ParallelEnv::publishAll`, `OldGenSpace.cpp:3508-3511`) and `SliceControl::steal_without_ticket`
(`MarkWork.hpp:450-456`). `bgEntry`'s `test_bg_hold_` wait (`OldGenSpace.cpp:4407-4410`) only delays
a member that is already counted active, which the model's interleavings already include.
`MinorEnv` has a FIFO option (`minor_fifo_order`, default off, `AllocatorCommon.hpp:246`) that only
changes which private entry is popped; M2 pops LIFO.

The template also had a real bug that a test only caught under load (§2.3). So the model can
prove it has teeth against history.

---

## 1. What the model checks, in one paragraph

Several threads share a pile of work (grey entries). Each thread takes work, and processing an
entry can create more. Threads can also steal each other's work. The loop must decide, without a
central lock, when **all** work is done. If it decides too early, some grey objects are never
scanned. In a mark that means live objects are left unmarked and later freed: silent heap
corruption. If it never decides, the pause hangs. On top of that, every entry scanned must be paid
for by exactly one **ticket**, so that the amount of work per slice is deterministic (GC_DET_001).
And a **stop** request must leave every unfinished entry where a later run can find it. M2 checks
all of this for every interleaving of 2–3 threads over a small object graph.

## 2. The protocol in plain words

### 2.1 The pieces

- **Grey entries.** Units of work. In marking, an entry is an object whose mark bit is set but
  whose children have not been looked at. Scanning it sets its children's mark bits (test-and-set,
  so each object is greyed once) and pushes the newly greyed children as new entries.
- **Each thread (participant) owns a slot**, which holds:
  - a **private stack** (`MarkWorker::stack`): only the owner touches it, so it needs no atomics;
  - `priv`, a relaxed atomic copy of the private stack's size, so other threads can see "this
    thread still has private work";
  - a **Chase–Lev deque**: the owner pushes and takes at the bottom, thieves steal from the top.
- **Publishing** moves private entries into the deque so thieves can see them:
  - `publishHalf` moves the oldest half when the stack is big (≥ 64) and the deque looks empty;
  - `publishAll` moves everything, and runs whenever the thread leaves the loop or goes idle.
- **The ring.** A 16-entry buffer on the thread's own stack. Entries taken for scanning wait there
  so their memory can be prefetched. The ring is invisible to other threads.
- **Tickets.** Before taking an entry a thread must hold a ticket. Tickets come from a shared
  **pool**: the control's `budget`, or an assist's own pool. They are claimed in batches of 256
  with a CAS. Unused tickets go back to the pool before the thread goes idle. "Exact tickets":
  entries scanned = initial pool − final pool.
- **The state word** (`SliceControl::state`), a single 64-bit atomic:
  - bits 0–31: `active`, the number of participants not idle;
  - bits 32–62: `epoch`, bumped by every reactivation;
  - bit 63: `done`.

  Every write to it is a read-modify-write: `goIdle` is `fetch_sub(1)`, `reactivate` is a CAS
  adding `1 + epochOne`, and the done-decision is a CAS.

### 2.2 One participant's loop (`runMarkerLoop`, `MarkWork.hpp:407-484`)

```
if joined:  reactivate() or return            // a joiner enters a running control
loop:
  stopping = stop                              // relaxed load
  if share_epoch changed: publishAll           // a joiner asked everyone to share
  (1) fill the ring: while not stopping and ring not full:
        claim a ticket (else break); take own entry (private first, then deque)
        (nothing there: give the ticket back and break)
  (2) if the ring has an entry: scan the oldest; continue
  if stopping: exit (still active)
  (3) claim a ticket, try to steal one entry; on success put it in the ring; continue
      (steal found nothing: give the ticket back)
  if Assist: exit (still active)               // assists never idle
  (4) go idle: publishAll; return tickets; goIdle()
      idleUntilWorkOrDone:
        s = state (acquire)
        if done or stop: exit (idle)
        if budget > 0 and anyWork(): reactivate() -> loop   (fails if done: exit)
        if s.active == 0:
            re-check budget > 0 and anyWork()
            if no work: CAS(state: s -> s|done); success -> exit (idle)
        backoff; repeat
exit (still active): publishAll; return tickets; goIdle()
exit (idle):         publishAll (normally empty); return tickets
```

**Why termination is safe.** "Done" is committed by a CAS from the *exact* word `s` in which the
decider saw `active == 0`. Any thread that becomes active again after that load must CAS the word
(adding `1 + epochOne`), so the decider's CAS then fails. And because every thread publishes its
work and returns its tickets *before* its `goIdle` RMW, a decider that reads the post-`goIdle` word
(acquire) also sees that work, and reactivates instead of deciding.

### 2.3 The bug this protocol replaced (an example the model must reproduce)

The first 5b build kept `active` and `done` as **two** atomics. The decider read `active == 0`,
then read `budget` and `anyWork()`, then stored `done = true`. Timeline with markers A and D and a
slice budget of 3:

| # | D (deciding) | A (idle, sees work) | state |
|---|---|---|---|
| 1 | reads `active == 0` | | active 0, budget 3 |
| 2 | | reactivates (`active = 1`), claims the whole budget as one batch | active 1, budget 0 |
| 3 | reads `budget == 0`, so "no work" | | |
| 4 | stores `done = true` | | **done while A is active with tickets and work** |
| 5 | exits | scans, later returns unused tickets | done, budget > 0, work left |

The slice ended with work and budget left. A determinism test found this only under a loaded full
suite (05b plan §10.1 item 10). The model's mutant `two_word` (§5) is exactly this change, and
TLC must find this trace. In the model, A's last step (returning the unused ticket with work left)
needs one steal that "found nothing although work exists", a real `stealAny` outcome (§4.1): the
shortest trace in `slice` has one legitimate and one such give-up, and no wrap.

### 2.4 Roles, joiners and stop (5c)

- **Member.** Idles until the control terminates. Background markers, 5b slice members, minor and
  tenure workers, and closing joiners are Members.
- **Assist.** A foreground helper that joins a *running* background episode for a bounded pool of
  tickets. It never idles: when its pool is empty or it finds nothing, it publishes, returns its
  tickets and leaves.
- **Joined.** An assist or closing participant was not counted in the initial `active`, so its
  first action is `reactivate()`. If the control is already done, it leaves at once.
- **`share_epoch`.** Before an assist or a closing join, the mutator bumps it, and every running
  participant publishes its private stack at its next loop top. Private work would otherwise be out
  of the joiners' reach.
- **Stop.** A request from `GCBackgroundGang::stopAndJoin` (a fork hook, a reset, a late 7c
  collector). Participants stop filling their rings, scan what the ring holds, publish, return
  tickets and leave **without** setting done. Unscanned work stays in the deques. A later run
  finishes it: 5c's relaunch, `closingFinish`'s plain drain (`runMarkers`, F participants over
  F+B victims), or 7c's help in the next pause (p participants over V victims).

## 3. The code the model covers

| Code | Lines (2026-09-28, post-7c) | Model element |
|---|---|---|
| `SliceControl` (state word, budget, stop, share_epoch, victim range `n`) | `MarkWork.hpp:205-258` | `word`, `dirty`, `budget`, `stop`, `share`, `Slots` |
| `claimTicket` / `returnTickets` | `MarkWork.hpp:285-304` | macros `ClaimOrFill`, `ClaimOrRole`, `ReturnTickets` |
| `stealAny` (4 passes, random start, aborts) | `MarkWork.hpp:347-365` | step `R_StealTry` (atomic steal, or "found nothing") |
| `idleUntilWorkOrDone` | `MarkWork.hpp:369-395` | steps `I_Load` … `I_Decide` |
| `runMarkerLoop` | `MarkWork.hpp:407-484` | procedure `Run` |
| `WorkStealingDeque` push/take/steal | `MarkWork.hpp:63-195` | `deque[x]` as a sequence, each operation one step (W1 checks the real algorithm) |
| `ParallelEnv::takeOwn` / `anyWork` / `publishAll` | `OldGenSpace.cpp:3480-3512` | `R_TakeOwn`, `I_Scan*`/`I_Priv*`, procedure `PublishAll` |
| `OldGenSpace::publishHalf`, `publishAll`, `pushGrey` | `OldGenSpace.hpp:963-992` | `R_Push`, `R_PubHalf*`, `PublishAll` |
| `MinorEnv` / `RegionEnv` / `TenureParEnv` / `AgeParEnv` `anyWork` (deques only); `pushGreyP` / `publishHalfP` / `publishAllP` | `NurseryParallel.cpp:114-226`, `NurseryRegion.cpp:280-337`, `NurseryTenure.cpp:931-960`, `:170-197` | constant `AnyWorkCountsPriv = FALSE` |
| `testAndSetMark<ParallelMark>` (`fetch_or`) | `OldGenSpace.cpp:3039` | `R_Kids` (test-and-set of `mark[c]`) |
| t0 greys on slot 0's private stack (`markHPointer` → `greyObject` → `pushGrey`) | `OldGenSpace.cpp:3761`, `:3148-3149` | `InitStack` (`slice`) |
| `launchBackground` (round-robin t0 greys into bg deques) | `OldGenSpace.cpp:4431` | `InitDeque` |
| `assistEpisode` (pool, share_epoch, `units == budget - pool`) | `OldGenSpace.cpp:4534` | process `Joiner`, `J_Assist`, invariant `AssistExact` |
| `closingFinish`: `reapBackground(false)`, closing join, `reapBackground(true)`, `assert(bg_ep_ == Finished)` (`:4599`) | `OldGenSpace.cpp:4569-4604` | `J_ClosingRun`, `J_ClosingCheck`, invariant `ClosingFinished`. The model always takes the join path. That is real even when the members already returned, because `finishedApprox` can lag the members' return; the skip path hands over to a plain drain, which is the `help` shape |
| `GCBackgroundGang::stopAndJoin` storing `stop` | `GCHelperPool.cpp:638-643` (store at `:641`) | process `Mutator` |
| `tenureConcLaunch` / `tenureConcFinish` (L3 stop, then help over V ≥ p slots) | `NurseryTenure.cpp:1222-1271` | configurations `tenure_l3`, `help` (§6) |

**Deliberately outside M2:**
- the heap: M2 uses a fixed graph, and M1 has the real snapshot semantics;
- the deque's internal memory orders: W1;
- how the gang starts and joins threads: M6 (M2 assumes the LaunchJoin contract);
- the pacing that decides *when* to assist;
- jitter and backoff timing. Backoff is a delay, and a delay changes nothing in a model that
  already explores every interleaving;
- **retiring old deque arrays** (05c trap 6: a thief may still read a retired array, so
  `retireAllDequeArrays` runs only when no run can hold one: `runMarkers` `:3560`,
  `reapBackground`, `closingFinish`, `launchBackground`). It is a quiescence rule of the mutator
  (IM14, register CR-010), not part of the loop. M2 treats `steal` as atomic and never frees an
  array; the rule belongs to M1/M6's quiescence premise;
- the `kParallel == false` path (`SerialEnv`, one thread).

## 4. The model

### 4.1 Abstractions, and why each is sound

| Real thing | Model | Why it is sound (or where it over-approximates) |
|---|---|---|
| The heap graph, read by `scanObject` | A constant graph `Nodes`, `Edges` | Objects are immutable during marking (P1); M2 only needs "scanning creates new entries" |
| Chase–Lev deque | A sequence: push/take at the end, steal at the head, each one atomic step | The algorithm is linearizable (PPoPP'13), including the take/steal race on the last element (both CAS `top`; the loser gets `kEmpty`/`kAbort`), and growth (the owner copies into a new array and publishes it; old arrays are never written again and are freed only after a join). W1 checks our implementation under C11 |
| `stealAny`'s four passes with aborts | One step that steals from some non-empty victim, or returns "nothing" | Returning nothing although work exists is a real outcome (it scanned victims at different moments, or four passes lost CASes). **Safety configurations allow it without limit** (`CapGiveUps = FALSE`): the cap would remove real behaviours, and the `wrap` trace needs two such give-ups. Only the liveness configuration caps it at `MaxGiveUps` per run, so that liveness is not spuriously broken (primer §4.4) |
| `anyWork()`: per slot, slots in index order, first hit returns. `ParallelEnv` (`OldGenSpace.cpp:3498-3504`, and the harness `SynthEnv`/`PackedEnv`, `mark_harness.cpp:208`, `:409`): `!deque.emptyApprox() \|\| priv.load() != 0`. `MinorEnv` (`NurseryParallel.cpp:183`), `RegionEnv` (`NurseryRegion.cpp:296`), `AgeParEnv` (`NurseryTenure.cpp:192`), `TenureParEnv` (`:955`), harness `Copier::Env` (`minor_harness.cpp:376`): `!deque.emptyApprox()` only | `I_Scan*` reads one slot's deque per step, then (`AnyWorkCountsPriv` only) `I_Priv*` reads that slot's `priv` in a **separate** step; slots in index order (`Min`), stopping at the first hit | The deque and `priv` loads are separate in the code. Merged, they hide a false "no work" while the slot's owner publishes: the reader sees the deque empty before the pushes and `priv = 0` after them. `emptyApprox` itself (bottom, then top: two relaxed loads, `MarkWork.hpp:135-137`) stays one step: while only pushes run concurrently it is exact at its `bottom` load. A concurrent `take` or `steal` can make it report "empty" for a deque that was never empty, but either comes from a counted-active thread, so a done-CAS in that window fails anyway and the false "empty" only delays a reactivation |
| `publishHalf` at ≥ 64 entries, checked every 32 pushes / 64 pops | After a push that brings the stack to ≥ `PUB_MIN`, *may* publish half (`either`) when the deque is empty | Over-approximation of the push-side check: it includes every real threshold behaviour. A counterexample that needs an impossible publish must be checked against the code (primer §4.3) |
| `takeOwn`'s `publishHalf` every 64 pops | **Not modelled** (an under-approximation of timing only) | The pop-side publish moves the same oldest half at a different moment. No protocol step depends on when it happens (`priv` double-counts during every publish). With the diamond graph a stack never exceeds 2, so at quick scale a pop-side publish (stack ≥ `PUB_MIN` after a pop) could not fire anyway. Add it (a `PublishHalf` procedure called from `R_TakeOwn`) if a deep graph makes it reachable |
| `priv` written after each private push/pop | Written in the same step as the owner-only stack change | Only `priv` is shared. Owner-only stack changes are invisible to others (primer §3.2) |
| `publishAll` storing `priv = 0` at the end | Separate step `PA_Priv` after the per-entry pushes; an empty stack returns at once (`if (w.stack.empty()) return;`) | Faithful: while publishing, an entry is both in the deque and counted in `priv`. That double counting is conservative, and the model keeps it |
| The state word's 31-bit epoch | `EpochMod = 0`: no epoch in the state; a flag `dirty[p]` per participant, set by every reactivation while `p` is between its `I_Load` and its done-CAS | Exact, not an approximation: the epoch only grows, and its only use is to make a decider's CAS fail when anyone reactivated since the decider's load. The flag records exactly that. The state space becomes finite without a state constraint (§4.7) |
| Owner-only decisions (ring full, stack size, role, `sw.active`) | Folded into the neighbouring step; labels sit only at shared accesses | Owner-only data is invisible to other threads (primer §3.2). A label on a purely local decision adds interleavings and states but no behaviour |
| Ticket batches of 256 | `TB = 2` | Keeps "a thread holds more tickets than it needs" reachable with tiny pools, which is the shape of the §2.3 bug |
| Ring of 16 | `RING = 1` (quick) or `2` (deep) | One entry is enough for "ticket held, entry invisible to others". Two adds reordering |
| Victim range `c.n` larger than the participant set | Constant `VictimSlots`: slots with a deque and no participant | 5b runs over F+B victims with F participants, and 7c help with p < V, have deques only thieves can reach (§1 table) |

### 4.2 Constants

| Constant | Meaning | Code value | Model values |
|---|---|---|---|
| `Nodes`, `Edges`, `Roots` | the object graph | the heap | 4 nodes (diamond `1→{2,3}→4`), deep: 5 nodes |
| `BgSlots` | participants counted active at the start (their slots) | B background markers / N workers | `{1,2}` or `{2,3}` |
| `FgSlot` | the joiner's slot, 0 = none | foreground slot 0..F−1 | `0` or `1` |
| `VictimSlots` | slots with a deque but no participant | 5b: the B background slots; 7c help: slots p..V−1 | `{}`, or `{3}` in `help` |
| `InitDeque` | the entries in the deques at launch | round-robin into the deques (`launchBackground`, and every nursery env: `minorGCParallel` step 4, `NurseryParallel.cpp:727-735`) | per configuration |
| `InitStack` | the entries on private stacks at launch (`priv` starts at their count) | 5b: the t0 greys on slot 0's private stack; empty elsewhere | root on slot 1 in `slice`; else empty |
| `Budget0` | the control's pool | `kDrainBudget` (drain) or a slice budget | `40` (drain), `3` (slice) |
| `TB` | ticket batch | 256 | 2 |
| `RING` | ring depth | 16 | 1 (quick), 2 (deep) |
| `PUB_MIN` | publishHalf threshold (`ASSUME PUB_MIN >= 2`: a half must be non-empty) | 64 | 2 |
| `AnyWorkCountsPriv` | environment | TRUE = `ParallelEnv`; FALSE = minor/region/tenure/age | both |
| `StopAllowed` | a stop may arrive (the `Mutator` process exists only then) | 5c episodes, 7c L3 | per configuration |
| `AssistRuns`, `AssistBudget` | joiner's assists | paced by `runCycleStepConcurrent` | 0–1, 2 |
| `DoClosing` | joiner ends with a closing join | `closingFinish` | per configuration |
| `CapGiveUps`, `MaxGiveUps` | cap on "found nothing" outcomes while work exists | unbounded | `FALSE` (safety); `TRUE`, 1 (liveness only) |
| `EpochMod` | 0 = exact epoch (dirty flags); k > 0 = epoch mod k (§4.7) | 2^31 | 0; 2 in `wrap` |
| `MUTANT` | negative control selector | — | `"none"` or a §5 name |

### 4.3 Variables

| Variable | Meaning | Code counterpart | Written by |
|---|---|---|---|
| `deque[x]` | slot x's deque | `markers_[x]->deque` | owner (push/take), thieves (steal) |
| `pstack[x]` | slot x's private stack (`stack` is reserved in PlusCal) | `MarkWorker::stack` | owner only |
| `priv[x]` | published private size | `MarkWorker::priv` | owner (relaxed store) |
| `mark[n]` | mark bit | the mark byte | anyone (`fetch_or`) |
| `scanned[n]` | ghost: how often n was scanned | IM10's sharded set | the scanner |
| `budget`, `apool` | the pools | `c.budget`, the assist's local `std::atomic<int64_t>` | claims and returns |
| `word` | the state word as a record `[active, epoch, done]`; `epoch` stays 0 unless `EpochMod > 0` | `c.state` | RMWs only |
| `dirty[p]` | "someone reactivated since p loaded the word" (the epoch, §4.1, §4.7) | the epoch bits of `c.state` relative to p's `s` | every reactivation; p resets its own |
| `stop`, `share` | stop request, share epoch | `c.stop`, `c.share_epoch` | another thread (`Mutator`); the joiner |
| `uBudget`, `uAssist` | ghost: scans paid from each pool | the scans (`ctr.units` counts them too, except the `steal_without_ticket` hook's) | the scanner |
| procedure locals `ring`, `tickets`, `active`, `seen`, `sw`, `aw`, … | per-participant loop state | the locals of `runMarkerLoop` / `MarkerCounters` | owner |

### 4.4 Steps: model labels to code lines

| Label | Code (`MarkWork.hpp` unless noted) | Atomic operation it stands for |
|---|---|---|
| `R_Join` | 412, 248-257 | `reactivate()` CAS (or return when done) |
| `R_Top` | 423 | `stop.load(relaxed)`. Without a joiner `share_epoch` is constant, so its load folds in here |
| `R_Share` | 425-426 | `share_epoch.load`; then `publishAll` |
| `R_Fill` + `ClaimOrFill` | 429-430, 285-296 | `claimTicket`'s batch CAS on the pool (a local ticket needs no shared access) |
| `R_TakeOwn` | 431-433; `ParallelEnv::takeOwn` (`OldGenSpace.cpp:3484-3494`) | private pop + `priv` store, or `deque.take()` |
| `R_AfterFill` | 436-448 | scan the oldest ring entry (children read: immutable); with an empty ring: leave when stopping (448), else go to the steal |
| `R_Kids` | `testAndSetMark` (`OldGenSpace.cpp:3039`) | `fetch_or` on the child's mark |
| `R_Push`, `R_PubHalf*` | `pushGrey`, `publishHalf` (`OldGenSpace.hpp:967-992`) | owner push + `priv` store; `emptyApprox`; each deque push; the final `priv` store |
| `R_Steal` + `ClaimOrRole`, `R_StealTry` | 457-462, 347-365 | ticket claim, then one `deque.steal()`; an Assist leaves instead of idling (462) |
| `R_Idle`, `R_Idle2`, `R_Idle3` | 464-467 | `publishAll`, `returnTickets`, `goIdle` (`fetch_sub`) |
| `I_Load`, `I_Stop` | 372-374 | `state.load(acquire)`, `stop.load` |
| `I_Budget1`, `I_Scan1`, `I_Priv1` | 375, 379 | `budget.load(acquire)`; one slot's `emptyApprox`, then (mark env) its `priv`, per step; with no work, the `active == 0` test on `s` (379) |
| `I_React` | 376 | `reactivate()` |
| `I_Budget2`, `I_Scan2`, `I_Priv2` | 382 | the `active == 0` branch's re-read of budget and work |
| `I_Decide` | 385-391 | the done-CAS from `s`; on failure `continue` |
| `R_ExitActive*` | 475-479 | `publishAll`, `returnTickets`, `goIdle` |
| `R_ExitIdle*` | 481-483 | `publishAll`, `returnTickets`: both no-ops here, since the idle path published and returned before `goIdle`; one step unless a mutant left something |

### 4.5 The PlusCal sketch

File: `test/tla/M2-slice-control/SliceControl.tla`. This is the text that passed the translator and
SANY on 2026-09-28 (review copy; `pcal -nocfg`, then `sany`: no errors). The generated
translation is omitted here.

```tla
---------------------------- MODULE SliceControl ----------------------------
EXTENDS Naturals, Sequences, FiniteSets, TLC

CONSTANTS
    Nodes, Edges, Roots,      \* the immutable object graph (P1: frozen heap)
    BgSlots,                  \* slots whose participants start counted active
    FgSlot,                   \* 0 = no foreground joiner
    VictimSlots,              \* slots with a deque but no participant (c.n > participants)
    InitDeque,                \* [Slots -> Seq(Nodes)]: work in the deques at launch
    InitStack,                \* [Slots -> Seq(Nodes)]: work on private stacks at launch (5b: slot 0)
    Budget0,                  \* initial c.budget (tickets)
    TB,                       \* kTicketBatch (256 in code)
    RING,                     \* kRingDepth (16 in code)
    PUB_MIN,                  \* kPublishMin (64 in code)
    AnyWorkCountsPriv,        \* TRUE = ParallelEnv (mark), FALSE = the nursery envs
    StopAllowed,              \* a stop request may arrive (bg episodes, 7c L3)
    AssistRuns,               \* how many assist runs the joiner makes
    AssistBudget,             \* tickets per assist run
    DoClosing,                \* the joiner ends with a closing (Member) run
    CapGiveUps,               \* TRUE only for liveness: cap the spurious empty steals
    MaxGiveUps,               \* the cap per run when CapGiveUps
    EpochMod,                 \* 0 = exact epoch (dirty flags); k > 0 = epoch mod k (wrap)
    MUTANT

JoinerSet == IF FgSlot = 0 THEN {} ELSE {FgSlot}
Procs == BgSlots \cup JoinerSet                   \* the participants
Slots == Procs \cup VictimSlots                   \* the victim range c.n
MutId == 0
MutSet == IF StopAllowed THEN {MutId} ELSE {}
Children(n) == {m \in Nodes : <<n, m>> \in Edges}
RECURSIVE ReachFrom(_)
ReachFrom(S) == LET N == S \cup UNION {Children(n) : n \in S}
                IN IF N = S THEN S ELSE ReachFrom(N)
Reachable == ReachFrom(Roots)
Range(sq) == {sq[i] : i \in 1..Len(sq)}
Min(S) == CHOOSE x \in S : \A y \in S : x <= y

ASSUME /\ UNION {Range(InitDeque[x]) \cup Range(InitStack[x]) : x \in Slots} = Roots
       /\ PUB_MIN >= 2 /\ TB >= 1 /\ RING >= 1

(* --algorithm SliceControl
variables
    deque   = InitDeque,                      \* WorkStealingDeque per slot
    pstack  = InitStack,                      \* private stack (owner only)
    priv    = [s \in Slots |-> Len(InitStack[s])],  \* published size of stack (relaxed)
    mark    = [n \in Nodes |-> n \in Roots],  \* mark bits (fetch_or)
    scanned = [n \in Nodes |-> 0],            \* ghost: scans per node
    budget  = Budget0,                        \* c.budget
    apool   = 0,                              \* the current assist pool
    word    = [active |-> Cardinality(BgSlots), epoch |-> 0, done |-> FALSE],
    dirty   = [p \in Procs |-> FALSE],        \* EpochMod = 0: "reactivated since my load"
    stop    = FALSE,                          \* c.stop
    share   = 0,                              \* c.share_epoch
    uBudget = 0,                              \* ghost: scans paid from c.budget
    uAssist = 0;                              \* ghost: scans paid from apool (this run)

define
    NullWord == [active |-> 0, epoch |-> 0, done |-> FALSE]
    NoWorkAnywhere == \A x \in Slots : deque[x] = <<>> /\ pstack[x] = <<>>
    \* Every entry scanned at most once (IM10).
    ScanOnce == \A n \in Nodes : scanned[n] <= 1
    \* The done bit is set only when nothing is left to do (P§3.3):
    \* either the budget ran out, or no entry is held anywhere.
    TerminationSafe ==
        word.done => (budget = 0 \/ (NoWorkAnywhere /\ word.active = 0))
    \* The deciders between their state load (I_Load) and their done-CAS.
    DecWindow == {"I_Stop", "I_Budget1", "I_Scan1", "I_Priv1",
                  "I_Budget2", "I_Scan2", "I_Priv2", "I_Decide"}
    \* reactivate(): the epoch bump. EpochMod = 0: the epoch never wraps, and its
    \* only use is to fail the done-CAS of a decider that loaded the word
    \* earlier, so it is exactly a dirty flag per open decision window.
    NextEpoch(e) == IF EpochMod = 0 THEN 0 ELSE (e + 1) % EpochMod
    Bump(me) == IF EpochMod = 0
                THEN [p \in Procs |-> p # me /\ pc[p] \in DecWindow]
                ELSE dirty
end define;

\* claimTicket(w, pool). On an empty pool: the fill loop breaks (to the scan if
\* the ring holds an entry, else to the steal); the steal falls through to the
\* role check. PlusCal macros cannot take a goto target as a parameter.
macro ClaimOrFill() begin
    if tickets > 0 then
        tickets := tickets - 1;
    elsif pool = "budget" /\ budget > 0 then
        tickets := (IF budget < TB THEN budget ELSE TB) - 1;
        budget  := budget - (IF budget < TB THEN budget ELSE TB);
    elsif pool = "assist" /\ apool > 0 then
        tickets := (IF apool < TB THEN apool ELSE TB) - 1;
        apool   := apool - (IF apool < TB THEN apool ELSE TB);
    elsif ring = <<>> then
        goto R_Steal;
    else
        goto R_AfterFill;
    end if;
end macro;

macro ClaimOrRole() begin
    if tickets > 0 then
        tickets := tickets - 1;
    elsif pool = "budget" /\ budget > 0 then
        tickets := (IF budget < TB THEN budget ELSE TB) - 1;
        budget  := budget - (IF budget < TB THEN budget ELSE TB);
    elsif pool = "assist" /\ apool > 0 then
        tickets := (IF apool < TB THEN apool ELSE TB) - 1;
        apool   := apool - (IF apool < TB THEN apool ELSE TB);
    elsif role = "Assist" then
        goto R_ExitActive;                           \* an Assist never idles
    else
        goto R_Idle;
    end if;
end macro;

macro ReturnTickets() begin
    if pool = "budget" then budget := budget + tickets;
    else apool := apool + tickets; end if;
    tickets := 0;
end macro;

\* After one child: the next child, or back to the loop top.
macro NextKid() begin
    if kids # {} then goto R_Kids; else goto R_Top; end if;
end macro;

\* publishAll(self): an empty stack returns at once; otherwise one deque push
\* per step, oldest first, and priv is stored only at the end (as in
\* OldGenSpace::publishAll / publishAllP). MUTANT skip_exit_publish is the
\* code's test_leave_private_on_exit_ hook: ParallelEnv::publishAll returns
\* before doing anything, at every call site.
procedure PublishAll()
begin
  PA_Loop:
    if pstack[self] = <<>> \/ MUTANT = "skip_exit_publish" then
        return;
    else
        deque[self] := Append(deque[self], Head(pstack[self]));
        pstack[self] := Tail(pstack[self]);
        if pstack[self] # <<>> then goto PA_Loop; end if;
    end if;
  PA_Priv:
    priv[self] := 0;
    return;
end procedure;

\* runMarkerLoop(env, self, c, pool, role, joined). Labels sit only at shared
\* accesses; owner-only decisions (ring, stack sizes, role, sw) are folded into
\* the neighbouring step.
procedure Run(role, joined, pool)
variables ring = <<>>, tickets = 0, active = TRUE, seen = 0,
          stopping = FALSE, kids = {}, c = 0,
          wasSet = FALSE, sw = NullWord, aw = {}, giveups = 0, half = 0;
begin
  R_Join:
    if joined then                                   \* c.reactivate()
        if word.done then return;
        else
            word := [word EXCEPT !.active = @ + 1, !.epoch = NextEpoch(@)];
            dirty := Bump(self);
        end if;
    end if;
  R_Top:
    while TRUE do
        stopping := stop;                            \* c.stopRequested() (relaxed)
        if JoinerSet = {} /\ (stopping \/ Len(ring) >= RING) then
            goto R_AfterFill;                        \* no joiner: share_epoch is constant
        elsif JoinerSet = {} then
            goto R_Fill;
        end if;
      R_Share:                                       \* share_epoch.load(relaxed)
        if share # seen then
            seen := share;
            call PublishAll();
        elsif stopping \/ Len(ring) >= RING then
            goto R_AfterFill;
        end if;
      R_Fill:                                        \* (1) fill the ring: claimTicket
        while ~stopping /\ Len(ring) < RING do
            ClaimOrFill();
          R_TakeOwn:                                 \* env.takeOwn(self)
            if pstack[self] # <<>> then              \* private first
                ring := Append(ring, pstack[self][Len(pstack[self])]);
                pstack[self] := SubSeq(pstack[self], 1, Len(pstack[self]) - 1);
                priv[self] := Len(pstack[self]);
                if Len(ring) >= RING then goto R_AfterFill; end if;
            elsif deque[self] # <<>> then            \* deque.take(): bottom
                ring := Append(ring, deque[self][Len(deque[self])]);
                deque[self] := SubSeq(deque[self], 1, Len(deque[self]) - 1);
                if Len(ring) >= RING then goto R_AfterFill; end if;
            elsif ring = <<>> then
                tickets := tickets + 1;              \* ++w.tickets; break
                goto R_Steal;
            else
                tickets := tickets + 1;
                goto R_AfterFill;
            end if;
        end while;
      R_AfterFill:                                   \* (2) scan the oldest ring entry
        if ring = <<>> then
            if stopping then goto R_ExitActive;      \* ring empty; still active
            else goto R_Steal; end if;
        else
            scanned[Head(ring)] := scanned[Head(ring)] + 1;
            kids := Children(Head(ring));
            ring := Tail(ring);
            if pool = "budget" then uBudget := uBudget + 1;
            else uAssist := uAssist + 1; end if;
            if kids = {} then goto R_Top; else goto R_Kids; end if;
        end if;
      R_Kids:                                        \* one child: test-and-set (fetch_or)
        c := CHOOSE ch \in kids : TRUE;
        kids := kids \ {c};
        wasSet := mark[c];
        if MUTANT # "split_tas" then mark[c] := TRUE; end if;
      R_Push:                                        \* pushGrey: stack push + priv store
        if MUTANT = "split_tas" then mark[c] := TRUE; end if;   \* a plain store, later
        if wasSet then
            c := 0; wasSet := FALSE;
            NextKid();
        elsif Len(pstack[self]) + 1 >= PUB_MIN then
            pstack[self] := Append(pstack[self], c);
            priv[self] := Len(pstack[self]);
            c := 0;
            goto R_PubHalf;
        else
            pstack[self] := Append(pstack[self], c);
            priv[self] := Len(pstack[self]);
            c := 0;
            NextKid();
        end if;
      R_PubHalf:                                     \* publishHalf: deque.emptyApprox()
        either
            await deque[self] = <<>>;
            half := Len(pstack[self]) \div 2;
            goto R_PubHalfLoop;
        or
            NextKid();                               \* not at a multiple of 32, or not empty
        end either;
      R_PubHalfLoop:                                 \* one deque.push per step
        deque[self] := Append(deque[self], Head(pstack[self]));
        pstack[self] := Tail(pstack[self]);
        half := half - 1;
        if half > 0 then goto R_PubHalfLoop; end if;
      R_PubHalfPriv:
        priv[self] := Len(pstack[self]);
        NextKid();
      R_Steal:                                       \* (3) steal, ticket first
        ClaimOrRole();
      R_StealTry:                                    \* stealAny: each steal is atomic
        either
            with v \in {x \in Slots \ {self} : deque[x] # <<>>} do
                ring := Append(ring, Head(deque[v]));
                deque[v] := Tail(deque[v]);
            end with;
            goto R_Top;
        or                                           \* found nothing (or lost races)
            await ~CapGiveUps \/ giveups < MaxGiveUps
                  \/ \A x \in Slots \ {self} : deque[x] = <<>>;
            if CapGiveUps /\ \E x \in Slots \ {self} : deque[x] # <<>> then
                giveups := giveups + 1;
            end if;
            tickets := tickets + 1;                  \* ++w.tickets
            if role = "Assist" then goto R_ExitActive; end if;   \* never idles
        end either;
      R_Idle:                                        \* (4) idle: publish, return, goIdle
        if MUTANT = "idle_before_publish" then
            ReturnTickets();                         \* variant: return, goIdle, then publish
        elsif pstack[self] # <<>> then
            call PublishAll();
        end if;
      R_Idle2:
        if MUTANT = "idle_before_publish" then
            word := [word EXCEPT !.active = @ - 1];
            active := FALSE;
            if pstack[self] # <<>> then call PublishAll(); end if;
        elsif MUTANT = "return_after_idle" then
            word := [word EXCEPT !.active = @ - 1];
            active := FALSE;
        else
            ReturnTickets();
        end if;
      R_Idle3:
        if active then
            word := [word EXCEPT !.active = @ - 1];
            active := FALSE;
        elsif MUTANT = "return_after_idle" then
            ReturnTickets();
        end if;
      I_Load:                                        \* idleUntilWorkOrDone: s = state.load
        if word.done then goto R_ExitIdle;
        else sw := word; end if;
      I_Stop:
        if stop then
            dirty[self] := FALSE; sw := NullWord;
            goto R_ExitIdle;
        end if;
      I_Budget1:                                     \* budget.load(acquire) > 0 && anyWork()
        if budget > 0 then aw := Slots;
        elsif sw.active # 0 then                     \* backoff; retry
            dirty[self] := FALSE; sw := NullWord;
            goto I_Load;
        else goto I_Budget2;
        end if;
      I_Scan1:                                       \* anyWork(): slot order, first hit returns
        with x = Min(aw) do
            if deque[x] # <<>> then                  \* !deque.emptyApprox()
                aw := {};
                goto I_React;
            elsif AnyWorkCountsPriv then
                goto I_Priv1;
            elsif aw # {x} then
                aw := aw \ {x};
                goto I_Scan1;
            elsif sw.active # 0 then
                aw := {}; dirty[self] := FALSE; sw := NullWord;
                goto I_Load;
            else
                aw := {};
                goto I_Budget2;
            end if;
        end with;
      I_Priv1:                                       \* || priv.load(): a second load
        with x = Min(aw) do
            if priv[x] # 0 then
                aw := {};
                goto I_React;
            elsif aw # {x} then
                aw := aw \ {x};
                goto I_Scan1;
            elsif sw.active # 0 then
                aw := {}; dirty[self] := FALSE; sw := NullWord;
                goto I_Load;
            else
                aw := {};
                goto I_Budget2;
            end if;
        end with;
      I_React:                                       \* c.reactivate()
        if word.done then
            dirty[self] := FALSE; sw := NullWord;
            goto R_ExitIdle;
        else
            word := [word EXCEPT !.active = @ + 1, !.epoch = NextEpoch(@)];
            dirty := Bump(self);
            active := TRUE;
            sw := NullWord;
            goto R_Top;
        end if;
      I_Budget2:                                     \* active == 0 in s: re-read budget, work
        if budget > 0 then aw := Slots;
        else goto I_Decide; end if;
      I_Scan2:
        with x = Min(aw) do
            if deque[x] # <<>> then                  \* work: `continue`
                aw := {}; dirty[self] := FALSE; sw := NullWord;
                goto I_Load;
            elsif AnyWorkCountsPriv then
                goto I_Priv2;
            elsif aw # {x} then
                aw := aw \ {x};
                goto I_Scan2;
            else
                aw := {};
                goto I_Decide;
            end if;
        end with;
      I_Priv2:
        with x = Min(aw) do
            if priv[x] # 0 then
                aw := {}; dirty[self] := FALSE; sw := NullWord;
                goto I_Load;
            elsif aw # {x} then
                aw := aw \ {x};
                goto I_Scan2;
            else
                aw := {};
                goto I_Decide;
            end if;
        end with;
      I_Decide:                                      \* CAS(state: s -> s | done)
        if MUTANT = "two_word" \/ (word = sw /\ ~dirty[self]) then
            word := [word EXCEPT !.done = TRUE];     \* two_word: no CAS at all
            dirty[self] := FALSE; sw := NullWord;
            goto R_ExitIdle;
        else                                         \* CAS failed: `continue`
            dirty[self] := FALSE; sw := NullWord;
            goto I_Load;
        end if;
    end while;
  R_ExitActive:                                      \* exit while still active
    if MUTANT = "idle_before_publish" then           \* 05c Step 3 variant: goIdle first
        word := [word EXCEPT !.active = @ - 1];      \* (an Assist's tickets go to its pool)
    end if;
    if pstack[self] # <<>> then call PublishAll(); end if;
  R_ExitActive2:
    ReturnTickets();
  R_ExitActive3:
    if MUTANT # "idle_before_publish" then
        word := [word EXCEPT !.active = @ - 1];
    end if;
    return;
  R_ExitIdle:                                        \* exit after termination or stop:
    if pstack[self] = <<>> /\ tickets = 0 then       \* publishAll and returnTickets
        return;                                      \* are no-ops (published at idle)
    else
        call PublishAll();
    end if;
  R_ExitIdle2:
    ReturnTickets();
  R_ExitIdle3:
    return;
end procedure;

\* Background members / 5b members / minor and tenure workers: counted active at launch.
fair process Member \in BgSlots
begin
  M_Run:
    call Run("Member", FALSE, "budget");
end process;

\* The foreground joiner (the mutator's GCMarkGang member on slot FgSlot):
\* AssistRuns bounded assists, then optionally the closing join.
fair process Joiner \in JoinerSet
variables k = 0;
begin
  J_Loop:
    while k < AssistRuns do
        share := share + 1;                          \* share_epoch.fetch_add
        apool := AssistBudget;
        uAssist := 0;
      J_Assist:
        call Run("Assist", TRUE, "assist");
      J_AssistCheck:                                 \* units == budget - pool: AssistExact
        k := k + 1;
    end while;
  J_Closing:
    if DoClosing then
        share := share + 1;
      J_ClosingRun:
        call Run("Member", TRUE, "budget");
      J_ClosingCheck:                                \* reapBackground(true): bg_->join();
        await \A m \in BgSlots : pc[m] = "Done";     \* then the assert: ClosingFinished
    end if;
end process;

\* Another thread (a fork hook, atexit, the owner's stopBackground or a late 7c
\* collector) runs stopAndJoin(): stop_->store(true) at any moment. Not fair:
\* it may never run.
process Mutator \in MutSet
begin
  S_Stop:
    stop := TRUE;
end process;

end algorithm; *)
\* BEGIN TRANSLATION
\* END TRANSLATION

AllDone == \A p \in Procs : pc[p] = "Done"

\* The Drain contract (parent plan §5.0), checked once every participant has
\* exited: nothing is held privately (IM15), every greyed-but-unscanned node
\* is in a deque (what 5c's relaunch, the closing drain and 7c's help start
\* from), and a run that terminated with budget left scanned everything
\* reachable. With ScanOnce and TerminationSafe this is what M1, M3 and M5
\* assume.
Drain ==
    AllDone =>
        /\ \A x \in Slots : pstack[x] = <<>>
        /\ {n \in Nodes : mark[n] /\ scanned[n] = 0}
               \subseteq UNION {Range(deque[x]) : x \in Slots}
        /\ (word.done /\ budget > 0) => \A n \in Reachable : scanned[n] = 1

\* Exact tickets (IM12, GC_DET_001): scans paid from c.budget = tickets consumed.
TicketsExact == AllDone => uBudget = Budget0 - budget

Postcondition == Drain /\ TicketsExact

\* The assert in assistEpisode: the assist's units == budget - pool.
AssistExact ==
    \A j \in JoinerSet : pc[j] = "J_AssistCheck" => uAssist = AssistBudget - apool

\* The assert in closingFinish, after reapBackground(true): bg_ep_ == Finished.
\* Violated with StopAllowed and DoClosing: register CR-005.
ClosingFinished ==
    \A j \in JoinerSet :
        (pc[j] = "J_ClosingCheck" /\ \A m \in BgSlots : pc[m] = "Done") => word.done

AllExit == <>AllDone
=============================================================================
```

### 4.6 The properties, explained

| Property | Kind | What it says | What a violation looks like |
|---|---|---|---|
| `ScanOnce` | invariant | no entry is scanned twice (IM10) | two threads end up holding the same entry, e.g. a take and a steal both win the last deque element, or two scanners both grey one child |
| `TerminationSafe` | invariant | `done` implies the budget is exhausted, or no entry is held anywhere and nobody is active | §2.3's trace: `done` set while A is active with work and tickets |
| `Drain` | invariant (checked once all have exited) | **the Drain contract** (below): no private work left (IM15); every greyed-but-unscanned node is in a deque; a run that terminated (`done`) with budget left scanned every reachable node | an exit path that skips `publishAll`; a node greyed but never scanned |
| `TicketsExact` | invariant (same) | exact tickets (IM12, GC_DET_001): scans paid from `c.budget` = tickets it lost | tickets returned to the wrong pool; a scan without a ticket |
| `Postcondition` | invariant | `Drain /\ TicketsExact` (the name the mutant table uses) | either of the above |
| `AssistExact` | invariant | at `J_AssistCheck`: the assist's scans = `AssistBudget − apool` (the assert in `assistEpisode`, `OldGenSpace.cpp:4557-4558`) | an assist scanning with tickets from the wrong pool |
| `ClosingFinished` | invariant | at `J_ClosingCheck`, once the background members have exited: the control is done (the assert in `closingFinish`, `OldGenSpace.cpp:4599`) | a stop during the closing join (CR-005, §6) |
| `AllExit` | liveness (`PROPERTY`) | every participant eventually exits | a participant stuck idling while work exists; a livelock |

The two checks that were `assert` statements in the first sketch are invariants over `pc` now:
the runner matches a violation by invariant name (parent plan §6.1), and TLC reports a failed
`assert` as an evaluation error without a name.

**Why `TerminationSafe` has the `budget = 0` escape.** A 5b slice ends when its tickets run out,
and unscanned work then legitimately stays for the next slice. For drain runs (`kDrainBudget`),
`budget = 0` is unreachable at the model's sizes, so the invariant reduces to "no work left".

**The Drain contract, as the other models use it.** Parent plan §5.0 states it as "a run ends with
every grey entry scanned exactly once and nothing held privately; a stop leaves every unscanned
entry in a deque". M2 discharges it as `ScanOnce /\ TerminationSafe /\ Drain`, in every
configuration of §6:
- M1 ("the loop consumes the grey set exactly once and terminates only when it is empty") and M3
  ("the drain ends when the grey set is empty and nobody is busy") use `ScanOnce`, the
  `done`-with-budget clause of `Drain`, and `TerminationSafe` (`done` ⇒ no entry anywhere and
  `active = 0`, so no ring holds one).
- M5 and M6 ("a stop leaves all unscanned work where help finds it") use `Drain`'s first two
  clauses in `episode_bgstop` and `tenure_l3`, and the `help` configuration shows that a run with
  fewer participants than victims then finishes it.
- What M2 does **not** discharge: M1's "several markers are observationally one consumer" also
  needs each scan to look atomic to M1's mutator. In M2 a scan's children are greyed one
  `fetch_or` per step. M1 has to justify the atomic scan itself (marks are monotone and the heap
  is frozen, P1); M2 only guarantees the exactly-once and completeness facts.

### 4.7 Epochs: an unbounded counter, and what its wrap would mean

With `AnyWorkCountsPriv = TRUE`, an idle marker sees another marker's `priv > 0` and reactivates.
It cannot steal private work, so it goes idle again, and repeats. Every round bumps `epoch`. The
same spin exists in the real mark environment. Phase 6 removed it from the nursery environments
for speed: "counting private stacks made minors 5–40× slower on long chains", 06 plan §10.1. A
model that stores the epoch therefore has an infinite state space. The first draft bounded it with
a state constraint (`epoch <= 6`). That was unsound for this purpose: TLC neither explores nor
checks states outside a constraint, so any behaviour with more reactivations was silently cut off,
and a liveness check under such a constraint can report spurious violations. So:

1. **Normal configurations (`EpochMod = 0`)** keep no epoch at all. The epoch never wraps in
   practice, and the code uses it only for equality: the done-CAS from `s` fails iff someone
   reactivated since the decider loaded `s`. The model records exactly that fact: every
   reactivation sets `dirty[p]` for each participant `p` that is between its `I_Load` and its
   done-CAS (`DecWindow`), and `I_Decide` requires `word = sw /\ ~dirty[self]`. Each participant
   clears its own flag when it leaves that window, so a dead flag never splits states. The state
   space is finite with **no state constraint**, and no behaviour is cut off.
2. **The wrap configuration** (`wrap`, §6) sets `EpochMod = 2`: the epoch is stored and bumped
   `(@ + 1) % 2` (a 1-bit field), and the flags are unused.
   - Expected result: TLC finds an ABA violation of `TerminationSafe`. The decider loads word `s`,
     another participant reactivates and idles twice (each time claiming the budget, finding
     nothing to steal and returning it), the word returns to `s`, and the done-CAS succeeds with
     budget and work left. The trace needs two "found nothing" steals by one participant, so
     `wrap` runs with `CapGiveUps = FALSE`; with a cap of 1 it would pass, as the first draft's
     `wrap` would have.
   - That documents the protocol's real assumption: **fewer than 2^31 reactivations between one
     decider's load and its CAS**. The assumption is recorded in MAPPING.md. It is very unlikely
     rather than impossible: the idle spin can reactivate every few hundred nanoseconds per
     spinner, so a wrap needs the decider held off the CPU for seconds (plausible only for a
     background member at `SCHED_IDLE` under load) while others spin, and then the word must match
     exactly.

## 5. Negative controls (mutants)

Implemented in the sketch unless marked "to add".

| `MUTANT` | Code change it represents | Configuration | Must violate | Story |
|---|---|---|---|---|
| `two_word` | separate `active` and `done` atomics (the first 5b build) | `slice` | `TerminationSafe` | §2.3, with §2.3's names (D decides, A reactivates). Shortest trace in the corrected sketch: A's claim and legitimate empty steal (it keeps the ticket for a moment); D exhausts the budget and publishes its private stack; A returns its ticket and goes idle; D loads `s`; A reactivates, claims the last ticket, finds nothing to steal (one spurious give-up); D reads `budget = 0` twice and sets `done`; A returns the ticket with work left. No wrap needed |
| `return_after_idle` | return tickets **after** `goIdle` (05b trap 3) | `slice` | `TerminationSafe` | an idle marker holds the last ticket, the decider sees `budget = 0` and decides, then the ticket comes back with work left (no give-up needed) |
| `idle_before_publish` | trap 5 isolated: `publishAll` moved after `goIdle`, nothing else. Idle path: `returnTickets` → `goIdle` → `publishAll`. Exit-active path: `goIdle` → `publishAll` → `returnTickets` (05c's "Step 3 regression variant", an Assist leaving; its tickets go to its own pool) | `slice_dq` (`slice` with `AnyWorkCountsPriv = FALSE`) | `TerminationSafe` | a marker whose claim failed goes idle with private work; the other returns its ticket, sees two empty deques twice and decides |
| `idle_before_publish` | same | `slice`, `episode` (`AnyWorkCountsPriv = TRUE`) | **expected to pass (under SC; to be confirmed by TLC)** | 05c §10.1 item 2 at per-load granularity. A decider's first scan **can** miss a slot whose owner publishes between the scan's deque load and its `priv` load (the W review found this interleaving; the model now has it). But no ticket moves in the decider's window, so the decider scans twice, and the second scan's deque load comes after that publish and sees the entries; no one can take them without reactivating, which fails the CAS. So safety needs `priv` **and** the double scan. If TLC finds a violation here, trap 5 is load-bearing under SC and the 05c claim is wrong. The weak-memory side is W2 (`w2_idle_before_publish`). The first draft's mutant also moved `returnTickets` after `goIdle`; that version fails `slice` through the ticket path alone (it is `return_after_idle`), which says nothing about trap 5. Under a drain budget the idle path never holds private work, so `minor` (the first draft's host) could not fail |
| `skip_exit_publish` | the IM15 negative control `test_leave_private_on_exit_`: `ParallelEnv::publishAll` returns at once, **at every call site** | `episode_bgstop` | `Postcondition` | a stopped participant exits with private entries no later run can find. (The first draft skipped only the idle exit, where the stack is always empty: a mutant that could not fail) |
| `split_tas` | the mark test and set as a plain read and a later plain store | `minor` | `ScanOnce` | two scanners both see node 4 unmarked, both push it, it is scanned twice |
| `steal_without_ticket` (to add) | the `c.steal_without_ticket` hook (`MarkWork.hpp:450-456`): steal first, and scan without a ticket if the claim then fails | `slice` | `Postcondition` (`TicketsExact`) | more scans than tickets consumed. The hook also skips `++w.units`, so the code's own `units == budget − pool` assert cannot see it; the harness's consumption checks do (`mark_harness.cpp` `synthMark`) |
| `assist_returns_to_budget` (to add) | `returnTickets` to `c.budget` instead of the assist's pool | `episode` | `AssistExact` | the assist's pool comes back short |
| `joiner_no_reactivate` (to add) | a joiner that skips `reactivate()` | `episode` | `TerminationSafe` | the decider sees `active == 0` while the joiner holds an entry in its ring, then the joiner pushes its children |
| `stop_sets_done` (to add) | a stop exit that also sets `done` | `episode_bgstop` | `TerminationSafe` | done with work left in the deques |
| `anywork_participants_only` (to add; replaces `anywork_skips_slot`) | `anyWork()` scans the participants' slots instead of the victim range (the 05c change: "`n` is the VICTIM range, no longer the participant count", `MarkWork.hpp:228-230`) | `episode` (also `help`) | `TerminationSafe` | the assist leaves its published work in slot 1's deque; the members decide done without looking there. (The first draft's "misses the last slot" skipped a background member's slot, whose deque is empty whenever its owner is idle: it could not fail) |
| `never_decide` (to add) | `I_Decide` never commits | `liveness_minor` | `AllExit` | every participant idles for ever |

"To add" means a two-to-five-line change at the named label, in the same `IF MUTANT = ...` style.
Each mutant is a row in `models.txt` naming its configuration and the property it must violate
(parent plan §6.1). A mutant configuration lists only its target property. The configurations
need no `CHECK_DEADLOCK FALSE`: every process ends in `Done` or keeps a step enabled.

## 6. Configurations

`MC.tla` defines the graphs and initial distributions. The quick graph is the diamond `1→{2,3}→4`
with root 1; the deep graph adds `4→5` and root 3. Unless a row says otherwise: `VictimSlots = {}`,
`InitStack` empty, `TB = 2`, `RING = 1`, `PUB_MIN = 2`, `CapGiveUps = FALSE`, `EpochMod = 0`,
`StopAllowed = FALSE`, `AssistRuns = 0`, `DoClosing = FALSE`, drain `Budget0 = 40`.

| Config | Models | Key constants | Tier | Expected |
|---|---|---|---|---|
| `slice` | a 5b slice with a small budget, starting from the t0 greys on slot 0's private stack | `BgSlots={1,2}`, `FgSlot=0`, `InitStack` = root on slot 1, `Budget0=3`, priv counted | quick | pass |
| `slice_dq` | host for `idle_before_publish` only: `slice` with a deques-only `anyWork` (no real env has a finite budget and a deques-only `anyWork`) | `slice` + `AnyWorkCountsPriv=FALSE` | quick | pass (the mutant must fail) |
| `minor` | phase 6 / 7b region minor / 07b age mark / 7c pause engine | `BgSlots={1,2}`, root in `deque[1]` (round-robin), deques-only | quick | pass |
| `episode` | 5c episode with one assist and a closing join | `BgSlots={2,3}`, `FgSlot=1`, root in `deque[2]` (`launchBackground`), `AssistRuns=1`, `AssistBudget=2`, `DoClosing=TRUE`, priv counted | quick | pass |
| `episode_bgstop` | 5c episode stopped by a fork hook or a reset, no closing | as `episode`, `StopAllowed`, `DoClosing=FALSE` | quick | pass (`Drain` is 5c's relaunch premise) |
| `episode_stop` | stop during the closing join | as `episode`, `StopAllowed`, `DoClosing=TRUE`, `AssistRuns=0` (the assist adds states and nothing to CR-005) | quick | **fails `ClosingFinished`: reproduces CR-005** (moves to pass when CR-005 is fixed) |
| `tenure_l3` | 7c L3 collectors that can be stopped | `BgSlots={1,2}`, root in `deque[1]`, deques-only, `StopAllowed` | quick | pass |
| `help` | 7c help (`tenureConcFinish`: p participants over V = max(B, p) victims) and, priv-counted, the plain drain after a stopped episode (`closingFinish` → `runMarkers`: F over F+B) | `BgSlots={1,2}`, `VictimSlots={3}`, root in `deque[3]` only, deques-only; a second row with priv counted | quick | pass: the leftover work of a stopped run is finished by participants that can only steal it |
| `wrap` | the epoch ABA | `slice` + `EpochMod=2` (`CapGiveUps=FALSE` is required, §4.7) | deep | **fails `TerminationSafe`** (documents the 31-bit assumption) |
| `deep_episode` | 5c with 5 nodes, two roots, ring 2 | `episode` + deep graph, `RING=2` | deep | pass |
| `liveness_minor` | `AllExit` for the deques-only envs | `minor` + `CapGiveUps=TRUE`, `MaxGiveUps=1`, `PROPERTY AllExit` | deep | pass |

Every configuration sets `defaultInitValue = defaultInitValue` (primer §2 rule 3). No
configuration needs a `CONSTRAINT`: the state space is finite (§4.7). The expected-pass rows check
`TerminationSafe`, `ScanOnce`, `Postcondition`, `AssistExact` and `ClosingFinished`; a mutant row
checks only its target.

**The `help` row replaces the first draft's "second phase in the same spec".** A stopped run's
`Drain` postcondition (no private work, empty rings, every unscanned grey entry in a deque) is
exactly a launch state with work in deques only. The frozen heap (P1) makes the help run a fresh
run over the not-yet-scanned subgraph. So a separate configuration whose initial work sits in a
slot no participant owns checks the hand-over without doubling the model.

### 6.1 What exploration showed (earlier draft; guidance, not results)

- The `minor` configuration finished with **111,952 distinct states**.
- A 5-node episode (two background members plus a joiner, ring 2) passed **22 million** distinct
  states without finishing. That is why the quick episode uses 4 nodes and `RING = 1`, and the
  5-node one is deep.
- The first slice run never finished. That exposed the unbounded epoch of §4.7 and led to
  `EpochBound`.
- Clearing dead locals did **not** noticeably shrink the episode's state space. The size comes
  from interleavings, not stale values. Shrink by bounds.

**Reductions made in the 2026-09-28 review** (none of them removes a behaviour of the code, and
`two_word`, `return_after_idle` and CR-005 stay reachable, §5):
1. No epoch in the state (`dirty` flags, §4.7). With `EpochBound = 6` every state existed in up to
   seven epoch copies.
2. The `Mutator` process exists only when `StopAllowed`. Before, every state of a no-stop
   configuration came twice (the mutator's `skip` step done or not).
3. Labels only at shared accesses. The first draft had steps whose only effect was to move `pc`:
   `R_Stopping`, `R_Role`, `R_PushDone`, `I_Zero`, `I_Retry`, the exit test of every `while`, the
   `R_Fill` re-entry with a full ring, `R_PubHalf` for stacks below `PUB_MIN`, `R_Share` without a
   joiner, and the `publishAll`/`returnTickets` calls on an empty stack or zero tickets. Each one
   was an extra interleaving point for every other process.
4. `anyWork` in the code's slot order, stopping at the first hit (the draft picked slots in any
   order and scanned on after a hit).
5. `episode_stop` without the assist.

It is still unmeasured whether each quick configuration fits in about two minutes. If one does
not: first `TB = 1` in the drain configurations (the ticket count per participant becomes 0/1;
batching matters only in `slice`), then `PUB_MIN` above the stack size in `minor` (the
publish-half choice then never fires; keep it in `slice` and `episode`).

## 7. Accuracy notes (parent plan rules A1–A9)

| Rule | M2 |
|---|---|
| A1 | Every label is one atomic operation (§4.4); owner-only decisions are folded into the neighbouring step, so no label is a pure `pc` move. `anyWork()` is one slot per step, and in `ParallelEnv` the slot's deque and its `priv` are two steps (`I_Scan*`, `I_Priv*`). `publishAll` and `publishHalf` are one push per step, then `priv`. The done-CAS compares the saved word and the `dirty` flag. `emptyApprox`'s two loads stay one step (argument in §4.1). |
| A2 | The state word is one record updated only by RMW-style steps (`fetch_sub`, CAS). `priv` is a count. Mark bits are per node here (byte sharing is M4's). |
| A3 | Footprint rows: 05c H10 (slot deques, private stacks, counters), H13 (`markers_[]`, `mark_slots_`), H7 (none needed: markers read no cycle state in M2). The 7c L3 slots (`tenure_workers_`) are the same shape. Census of 2026-09-28: every atomic in `MarkWork.hpp` maps to `word`/`dirty`, `budget`/`apool`, `stop`, `share`, a deque or `priv`; `SliceControl::n`, `jitter_us` and `steal_without_ticket` are plain fields written before the launch (LaunchJoin). The mutator-only touches (`OldGenSpace.cpp:370-380`, `:2850`, `retireAllDequeArrays`) happen while no run is live (IM14, CR-010) and are outside the loop. Pacing reads (`markWorkApprox`, `bgConsumedApprox`) are read-only hints. |
| A4 | **W1** (the deque's orders, including the release element store and acquire steal load added for TSan). **W2** (a thief's or decider's view of publish → `goIdle`). The SC model assumes both. The stop flag is a relaxed load; the model's SC view of it is safe because a decider that acquires a stopped participant's `goIdle` must, by read-read coherence, also read `stop == true`. |
| A5 | Trace validation on `gc-mark-tsan` `terminationStress` and `episodeStorm`, and on `gc-minor-tsan` (§8). |
| A6 | §5. The historical bug (`two_word`) is the first mutant. Every invariant has a mutant: `TerminationSafe` (several), `ScanOnce` (`split_tas`), `Drain` (`skip_exit_publish`), `TicketsExact` (`steal_without_ticket`), `AssistExact` (`assist_returns_to_budget`), `ClosingFinished` (the expected CR-005 failure), `AllExit` (`never_decide`). |
| A7 | `ScanOnce` = IM10, `Drain` = IM15 plus the §5.0 Drain contract, `TicketsExact` = IM12 / GC_DET_001, `TerminationSafe` = the P§3.3 termination rule under HEAP_064 / HEAP_065; `AssistExact` = the assert in `assistEpisode`; `ClosingFinished` = the assert in `closingFinish`. |
| A8 | 2–3 participants, 4–5 nodes, `TB = 2`, `RING = 1–2`, `PUB_MIN = 2`. No state constraint: the epoch is exact (`dirty`) and every other variable is bounded. The 1-bit `wrap` configuration (`EpochMod = 2`) covers the counter's wrap. |
| A9 | `file`: `MarkWork.hpp` (std-only; every line is protocol). `region`: `ParallelEnv` (`OldGenSpace.cpp:3480-3512`), `publishHalf`/`publishAll`/`pushGrey` (`OldGenSpace.hpp:963-992`), `MinorEnv` and `pushGreyP`/`publishHalfP`/`publishAllP` (`NurseryParallel.cpp:114-226`), `RegionEnv` (`NurseryRegion.cpp:280-337`), `TenureParEnv::takeOwn`…`publishAll` (`NurseryTenure.cpp:931-960`), `AgeParEnv::takeOwn`…`publishAll` (`NurseryTenure.cpp:170-197`), `runMarkers` (victim range, `OldGenSpace.cpp:3527-3580`), `launchBackground`, `bgEntry`, `assistEpisode`, `closingFinish`, `tenureConcFinish` (V vs p), and the round-robin distributions (`NurseryParallel.cpp:727-735`, `NurseryRegion.cpp:854-861`, `NurseryTenure.cpp:294-297`, `:1104-1130`). `census`: `OldGenSpace.cpp`, `NurseryParallel.cpp`, `NurseryRegion.cpp`, `NurseryTenure.cpp`, `GCHelperPool.cpp` (`stopAndJoin`). |

## 8. Trace validation

**Harnesses:** `test/gc-helper-tsan/mark_harness.cpp` (target `gc-mark-tsan`: `terminationStress`,
`episodeStorm`) and `minor_harness.cpp` (`gc-minor-tsan`). Both run the real `runMarkerLoop`, but
over their **own** environments: `SynthEnv`/`SynthHeap` and `PackedEnv`/`PackedHeap`
(`mark_harness.cpp:126-216`, `:328-418`) and `Copier::Env` (`minor_harness.cpp:360-384`), which
mirror `ParallelEnv` and `MinorEnv`. The trace build needs **small** instances: the gate runs use
a 60,000-node chain and 40,000 slices (`terminationStress(8, 40000)`), far beyond what TLC can
replay. Add trace-only entry points, e.g. `terminationStress(2, 200)` on a 64-node chain and
`episodeStorm(1, 2, …)` on a few hundred nodes. `episodeStorm` stops an episode only from the main
thread between assists, never during a closing join, so CR-005 does not appear in the trace
corpus; M2's `episode_stop` is its only reproduction.

**Hooks.** Add `ECO_TLA_TRACE(...)` calls in `MarkWork.hpp`. They compile to nothing unless
`ECO_TLA_TRACE` is defined; only the trace build of the harnesses defines it. Each event records
`{t: self, ev, ...}`:

| Event | Where (`MarkWork.hpp`) | Extra fields |
|---|---|---|
| `claim` | after a successful `claimTicket` CAS (290) | `pool`, `took`, `left` (the pool value written) |
| `take` | after `takeOwn` returns non-empty (431) | `e`, `src` (`priv`/`deque`) |
| `scan` | before `env.scan` (440) | `e` |
| `push` | in the harness heap's `pushGrey` (`SynthHeap`, `PackedHeap`, `Copier`), not in `OldGenSpace`: the harnesses do not use it | `e` |
| `publish` | per entry in the harness heap's `publishHalf` / `publishAll`, and the final `priv` store | `e` / `priv` |
| `ret` | after `returnTickets`' `fetch_add` (300) | `pool`, `before`, `after` |
| `stateLoad` | after `idleUntilWorkOrDone`'s `state.load` (372) | `s` (the word). The trace spec needs it to place the decider's window: `dirty[p]` maps to "the real epoch now ≠ `s.epoch`" |
| `steal` | after `stealFrom` (357) | `v`, `e` or `empty` / `abort` |
| `goIdle` | after `fetch_sub` (246) | `before`, `after` (the word) |
| `reactivate` | after a successful CAS (252) | `before`, `after` |
| `decide` | after the done-CAS (385) | `before`, `ok` |
| `stopSeen` | 374 / 423 when `stop` is true | — |
| `exit` | at return | `why` (`done` / `stop` / `assist` / `joinFailed`) |

**Ordering.**
- Per thread: a sequence number.
- Across threads: the state-word events (`goIdle`, `reactivate`, `decide`) log `before`/`after`, so
  they chain into a single order. Every RMW on one location is totally ordered.
- Pool claims and returns log the value written, which chains the same way.
- Deque events are ordered by the merger using the pushed and taken entry ids: an entry is pushed
  before it is taken or stolen.

**Trace spec.** `TraceSliceControl.tla` extends `SliceControl`:
- it reads the merged log with `ndJsonDeserialize`;
- `TraceNext` allows the step named by event *i* only if its thread, label and observed values
  match, and allows unlogged steps in between: owner-only ones (ring pushes, private pops) and the
  unlogged relaxed loads (`stop`, `share_epoch`, the idle budget reads, `anyWork`'s per-slot reads),
  whose values the trace spec lets TLC choose consistently with the state;
- it keeps a ghost copy of the real epoch (from `reactivate` events) to map the model's `dirty`
  flags, since `EpochMod = 0` stores no epoch;
- `TraceAccepted` holds when all events are matched.

A rejected trace is either a code bug or a model error; both get recorded (parent plan §6.3).

## 9. Implementation steps

1. Create `test/tla/M2-slice-control/` with `SliceControl.tla` (§4.5), `MC.tla`, the configurations of §6, MAPPING.md (§4.4 plus A3's rows) and
   AUDIT.md.
2. `pcal` + `sany` (grep SANY's output for errors: its exit status is 0 either way). Then TLC on
   `slice`, `minor`, `episode`, `episode_bgstop`, `tenure_l3`, `help`. If a quick configuration
   exceeds about 2 minutes, apply §6.1's fallbacks (`TB = 1` in drain configurations, then
   `PUB_MIN`), then `RING` or the graph.
3. Run `episode_stop` and confirm it reproduces **CR-005** as a violation of `ClosingFinished`.
   Record the trace in the register entry (status Reproduced).
4. Add the "to add" mutants. Confirm every mutant fails with its named property, that
   `idle_before_publish` fails on `slice_dq` and passes on `slice` and `episode`. Record the answer
   to 05c trap 5 (§5: `priv` and the double scan together).
5. Run `wrap` and confirm the ABA trace. Write the assumption, with §4.7's numbers, into MAPPING.md.
6. Run `help` in both variants (deques-only; priv counted). This is the hand-over from a stopped
   run (§6): 7c's help and closingFinish's plain drain.
7. Wire into `models.txt` (tier, configuration, expected outcome per row) and `test/tla/manifest.txt`
   (A9's `file`, `region` and `census` lines).
8. Trace validation (§8): hooks (in `MarkWork.hpp` and in the harness heaps), small trace-only
   harness instances, merger, trace spec. Run on `terminationStress` first, where only the state
   word and deques matter.
9. Close-out: AUDIT.md first entry; register updates (CR-005 → Reproduced); the parent plan's §11
   row.

## 10. Open questions for the implementer

1. Does `tenureConcFinish`'s help run, which uses a **new** `SliceControl` over V ≥ B slots, need
   anything from the stopped control beyond "all work is in the deques"? The code suggests not:
   it reads only `done()` and the workers' counters (`NurseryTenure.cpp:1239-1271`). `help`
   (step 6) checks the hand-over.
2. The minor and tenure environments ignore `priv`. Is there any stop path in those environments
   (only 7c L3 is stoppable) where a participant exits with private work? `publishAll` on every
   exit says no. Running `skip_exit_publish` on `tenure_l3` as well shows why it matters, although
   the test hook itself exists only in `ParallelEnv`.
3. Should the pop-side `publishHalf` (§4.1) be added for `deep_episode`? Only if the deep graph
   lets a private stack reach `PUB_MIN + 1`.

## 11. Adversarial review (2026-09-28)

Against the current tree, with the sketch re-run through `pcal -nocfg` and `sany` (no errors). TLC
was not run; reachability below is by hand-simulation of the corrected sketch.

| Id | Severity | Finding | Change |
|---|---|---|---|
| R1 | Blocker | `skip_exit_publish` skipped `publishAll` only at the idle exit, where the stack is always empty (the idle path published before `goIdle`): the mutant could not fail. The code's hook `test_leave_private_on_exit_` disables `ParallelEnv::publishAll` at every call site (`OldGenSpace.cpp:3508-3511`) | The mutant lives in `PublishAll` (returns at once); host `episode_bgstop` |
| R2 | Blocker | `idle_before_publish` on `minor` could not fail: under a drain budget the idle path never holds private work. The mutant also moved `returnTickets` after `goIdle`, so on `slice` it fails through the ticket path (`return_after_idle`), contradicting "expected to pass" and saying nothing about trap 5. 05c trap 5 is the Assist exit | Trap 5 isolated (publish moved, tickets not); applied to the idle and exit-active paths; hosts `slice_dq` (must fail), `slice`/`episode` (expected pass, with the reason) |
| R3 | Major | `anyWork`'s per-slot deque and `priv` loads were one step (A1). The merge hides a decider missing a slot whose owner publishes between the two loads (also raised by the W review) | Split (`I_Scan*`, `I_Priv*`), code slot order, early exit; `emptyApprox`'s two loads kept as one step, with the argument (§4.1) |
| R4 | Major | `wrap` was unreachable: in `slice` the ABA needs one participant to find nothing to steal twice, and `MaxGiveUps = 1` capped it | `CapGiveUps = FALSE` in every safety configuration; the cap is for liveness only |
| R5 | Major | `EpochBound` silently cut off every behaviour with more than six reactivations (TLC neither explores nor checks states outside a constraint), made `liveness_minor` unsound, and multiplied states by the epoch | Exact `dirty` flags instead of an epoch; no state constraint; `EpochMod` for `wrap` (§4.7) |
| R6 | Major | `J_AssistCheck` and `J_ClosingCheck` were `assert`s; the runner matches invariant names, and CR-005's expected failure named an assert | Invariants `AssistExact`, `ClosingFinished` |
| R7 | Major | `anywork_skips_slot` skipped a background member's slot, whose deque is empty whenever its owner is idle: it could not fail | `anywork_participants_only`: the 05c victim-range bug class |
| R8 | Major | Missing environment shapes: slots with a deque and no participant (5b: F over F+B; 7c help: p over V), and 5b's initial work on slot 0's private stack; the "second phase" for 7c help was not expressible | `VictimSlots`, `InitStack`, configuration `help` |
| R9 | Major | State space: the `Mutator` doubled every no-stop state; about ten labels only moved `pc`; `anyWork` scanned slots in every order and after a hit | §6.1's reductions; `episode_stop` without the assist |
| R10 | Minor | No mutant for `ScanOnce`, `AssistExact`, `AllExit` (A6); the Drain contract was not a named property | `split_tas` (implemented), two "to add" mutants; invariant `Drain` and a section on how M1/M3/M5/M6 use it (§4.6) |
| R11 | Minor | `Postcondition`'s "everything scanned" clause was vacuous after a late stop (`~stop`) | Now `word.done /\ budget > 0` |
| R12 | Minor | Reference drift: `OldGenSpace.hpp:881-906` (now 963-992), `NurseryParallel.cpp:114-188` (114-226), `RegionEnv` 280-300 (280-337), `AgeParEnv` 170-200 (170-197), `ParallelEnv` 3480-3510 (3480-3512), `tenureConcFinish` end (1271); "minor greys on worker 0" (they go round-robin) | Fixed in §1, §3, §4, §7 |
| R13 | Minor | The pop-side `publishHalf` was claimed to be covered by the push-side choice; it is a timing under-approximation (unreachable at quick scale) | §4.1 states it; open question 3 |
| R14 | Minor | Trace validation: the harnesses use their own `Env`s and heaps (hooks belong there), run gate-sized instances, and the event list lacked `returnTickets` and the state load | §8 |
| R15 | Minor | "2^31 reactivations cannot happen" overstated; `wrap` called 2 bits but configured 1 | §4.7 |
| R16 | Minor | `closingFinish`'s `reapBackground(false)` branch was not mentioned | §3: the join path is always real (`finishedApprox` can lag) |

Checked and found right: the state word's RMW-only discipline and the one-step CAS loops
(`reactivate`, `claimTicket`); stop leaves every unscanned entry in a deque, including entries in
the ring or in a thief's hand (both are scanned before the exit; `MarkWork.hpp:423-448`); the
`two_word`, `return_after_idle` and CR-005 traces are reachable in the corrected sketch (§5, §6);
no `Env` pushes work from outside the loop during a run.
