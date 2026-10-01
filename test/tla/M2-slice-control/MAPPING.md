# M2 — the marker loop, tickets and termination: model ↔ code

The model is `SliceControl.tla` (PlusCal plus its committed translation). `MC.tla` holds the graphs
and the initial work. The plan is `plans/threaded-gc-tla-M2-slice-control.md`; its §2 explains the
protocol. **This file cites code, never plan text** (parent plan §12, trap 1).

Line numbers are for the tree of 2026-09-29 (post-7c, with the compiled-out `ECO_TLA_TRACE` hooks of
the trace agents). Several agents edit these files, so the functions are named too. `MW` =
`runtime/src/allocator/MarkWork.hpp`, `OGS` = `OldGenSpace.cpp`, `OGH` = `OldGenSpace.hpp`, `NP` =
`NurseryParallel.cpp`, `NR` = `NurseryRegion.cpp`, `NT` = `NurseryTenure.cpp`, `GHP` =
`GCHelperPool.cpp`.

## 1. Variables

| Variable | Meaning | Code counterpart | Footprint row |
|---|---|---|---|
| `deque[x]` | slot x's deque, oldest at the head | `MarkWorker::deque` / `MinorWorker::deque` (`WorkStealingDeque`, `MW:90-219`) | H10; for the minor drain, `P6.M17` (06 P§3.11 row M17: `MinorWorker` slots and the drain's `SliceControl`) |
| `pstack[x]` | slot x's private stack, oldest at the head | `MarkWorker::stack`, `MinorWorker::stack` (from `head`) | H10 |
| `priv[x]` | the published size of `pstack[x]` | `MarkWorker::priv`, `MinorWorker::priv` (relaxed stores) | H10 |
| `mark[n]` | node n's mark bit | the mark byte: `testAndSetMark` (`OGS:3132`, parallel `fetch_or` `:3161`); SynthHeap's `marks[i].exchange` | H1 (bytes are M4's) |
| `scanned[n]` | ghost: how often n was scanned | IM10's sharded scanned set (validate builds) | — |
| `budget` | the control's ticket pool | `SliceControl::budget` (`MW:245`) | H10 (the control) |
| `apool` | the current assist's pool | `assistEpisode`'s local `std::atomic<int64_t> pool` (`OGS:4644`) | — (mutator stack) |
| `word` | the state word `[active, epoch, done]`; `epoch` stays 0 unless `EpochMod > 0` | `SliceControl::state` (`MW:246`): bits 0–31, 32–62, 63 | H10 |
| `dirty[p]` | "someone reactivated since p loaded the word" (§4, the epoch) | the epoch bits of `state` against the decider's `s` | H10 |
| `stop` | the stop request | `SliceControl::stop` (`MW:250`), stored by `GCBackgroundGang::stopAndJoin` (`GHP:660`, store `:663`) | H10 |
| `share` | the share epoch | `SliceControl::share_epoch` (`MW:254`), bumped by `assistEpisode` and `closingFinish` | H10 |
| `uBudget`, `uAssist` | ghosts: scans paid from `budget` / `apool` | `MarkerCounters::units` (except the `steal_without_ticket` hook's scan) | H10 (`ctr`) |
| `ring`, `tickets`, `active`, `seen`, `stopping`, `kids`, `c`, `sw`, `aw`, `giveups`, `half` (Run's locals) | the ring, `w.tickets`, the loop's `active`, `w.share_seen`, `stopping`, the entry's children left, the child being pushed, the decider's saved `s` (sign of `active` only, §4), the slots `anyWork` has still to read, the capped give-ups, the entries `publishHalf` has still to push | `runMarkerLoop`'s locals and `MarkerCounters` (`MW:471`) | owner-only |
| `k` (Joiner) | assists done | the mutator's pacing loop | owner-only |
| `Slots` (constant) | the victim range `c.n` | `SliceControl::n` (`MW:257`): `mark_slots_` in 5b / 5c, `V` in 7c help, `n` in the nursery envs | H13 |

## 2. Steps (A1: one label = one atomic step of the code)

A label sits only at a shared access. Owner-only work (the ring, the private stack, `w.tickets`, the
role, the saved word) is folded into the neighbouring shared access, and a call that does nothing (an
empty `publishAll`, a `returnTickets` of zero) is not a step. `runMarkerLoop` is `MW:471-559`.

| Label | Code | The one shared access |
|---|---|---|
| `M_Run` | `markerEntry` / `bgEntry` / the nursery entries → `runMarkerLoop(..., joined = false)` | none (the call) |
| `J_Start` | `assistEpisode` `OGS:4644` / `closingFinish` `OGS:4680`: `share_epoch.fetch_add` | the RMW on `share_epoch` (and the assist's pool, a mutator local) |
| `J_AJoin`, `J_CJoin` | `assistEntry` `OGS:4525` / `closingEntry` `OGS:4532` → `runMarkerLoop`'s `if (joined && !c.reactivate()) return;` (`MW:478`) | `reactivate`'s CAS loop (`MW:280`): one successful CAS, or the load that sees `done` |
| `J_AssistCheck` | `assistEpisode`'s `units == budget - pool` assert, then the next assist's or the closing's `share_epoch.fetch_add` | the RMW on `share_epoch` |
| `J_ClosingCheck` | `closingFinish`: `reapBackground(true)` (`OGS:4614`, `bg_->join()`), then `assert(bg_ep_ == Finished)` (`OGS:4710`) | the join (LaunchJoin) |
| `S_Stop` | `GCBackgroundGang::stopAndJoin` `GHP:663` | `stop_->store(true)` |
| `R_Top` | `MW:492` `stopRequested()` (relaxed load) when a stop can come; else `MW:494` the `share_epoch` load when a joiner exists; else the fill's first step | one load |
| `R_Share` | `MW:494-495`: `share_epoch.load`; if it changed, `publishAll` (its pushes are `PA_Loop` steps) | one load |
| `R_Fill` | `MW:498-499`: `claimTicket` (`MW:323`): a local ticket (then this step is `takeOwn`), the batch CAS on the pool, or the load that finds it empty (break) | one CAS or load |
| `R_TakeOwn` | `MW:500`: `env.takeOwn` (`OGS:3587`; `NP:148`, `NR:280`, `NT:171`, `NT:953`): private pop + `priv` store, or `deque.take()` (`MW:121`) | the `priv` store, or the take |
| `R_PopPub`, `R_PopPubLoop`, `R_PopPubPriv` | `takeOwn`'s `if ((++w.pops & 63) == 0) publishHalf(w)` (`OGS:3587`; `NP:170`; `NR:290`; `NT:186`, `:949`): `emptyApprox`, one `deque.push` per step, the `priv` store | one load, push or store |
| `R_Scan` | `MW:506-512`: the oldest ring entry, `env.scan`; its first child's test-and-set folds in (the entry's children are immutable, P1) | the first `fetch_or` |
| `R_Kids` | the next child's `testAndSetMark` (`OGS:3161`) | one `fetch_or` |
| `R_Push` | `pushGrey` (`OGH:995`) / `pushGreyP` (`NP:114`): stack push + `priv` store | the `priv` store |
| `R_PubHalf`, `R_PubHalfLoop`, `R_PubHalfPriv` | `publishHalf` (`OGH:979`) / `publishHalfP` (`NP:124`): `emptyApprox` (the first push folds in: only the owner can make its empty deque non-empty), one `deque.push` per step, the `priv` store | one load, push or store |
| `R_Steal` | `MW:529`: `claimTicket` before the steal; an Assist whose claim fails leaves (`MW:534`) | one CAS or load |
| `R_StealTry` | `stealAny` (`MW:390-419`): one successful `deque.steal()` (`MW:145`), or "found nothing" | the steal's CAS on `top` |
| `R_StealClaim` | `MUTANT steal_without_ticket` only: the hook's claim after the steal (`MW:521-527`) | one CAS or load |
| `R_Idle`, `R_Idle2`, `R_Idle3` | `MW:536-539`: `publishAll`, `returnTickets` (`MW:337`, `fetch_add`), `goIdle` (`MW:274`, `fetch_sub`) | one push / RMW each |
| `I_Load` | `idleUntilWorkOrDone` (`MW:421-458`) `:423`: `state.load(acquire)`; `done` → return; without a stop the `stopRequested()` load folds in | one load |
| `I_Stop` | `:429`: `stopRequested()` | one load |
| `I_Budget1`, `I_Budget2` | `:433`, `:440`: `budget.load(acquire)` (folded when the budget cannot run out, `BudgetNeverEmpty`) | one load |
| `I_Scan1`, `I_Scan2` | `anyWork()` (`OGS:3601`; `NP:183`; `NR:296`; `NT:193`, `:977`): one slot's `emptyApprox` per step, slots in index order, first hit returns; the reader's own `priv` folds in (it wrote it) | one slot's `bottom`/`top` pair (§4) |
| `I_Priv1`, `I_Priv2` | `ParallelEnv::anyWork`'s `priv.load` of that slot (`OGS:3604`); `AnyWorkCountsPriv` only | one load |
| `I_React` | `:434`: `reactivate()` | one CAS (or the load that sees `done`) |
| `I_Decide` | `:443`: the done-CAS from `s` | one CAS |
| `R_ExitActive`, `R_ExitActive2`, `R_ExitActive3` | `MW:547-551`: `publishAll`, `returnTickets`, `goIdle` | one push / RMW each |
| `R_ExitIdle`, `R_ExitIdle2`, `R_ExitIdle3` | `MW:555-557`: `publishAll` and `returnTickets` after termination; no-ops (the idle path published and returned), a step only when a mutant left something | — |
| `PA_Loop`, `PA_Priv` | `publishAll` (`OGH:989`; `publishAllP` `NP:140`; `ParallelEnv::publishAll` `OGS:3611`): one `deque.push` per step, oldest first; `priv.store(0)` | one push or store |

The initial work: 5b's t0 greys on slot 0's private stack (`markHPointer` `OGS:3864` → `greyObject`
→ `pushGrey`) is `InitStack`; the round-robin distributions before a launch are `InitDeque`
(`launchBackground` `OGS:4539`; `NP:735`; `NR:860`; `NT:296-298`; `tenureParDistribute` `NT:1126`).
No `Env` pushes work into a slot from outside the loop while a run is live (IM14,
`assertSlotsQuiescent` `OGS:4469`).

## 3. The five environments and the configurations

| `Env` | `anyWork` | Victims vs participants | Configurations |
|---|---|---|---|
| `OldGenSpace::ParallelEnv` (`OGS:3583-3614`) | deques and `priv`, slots `0..mark_slots_-1` | 5b: F over F+B (`runMarkers` `OGS:3630`); 5c: B members plus a joiner over F+B | `slice`, `slice3` (5b); `episode`, `episode_bgstop`, `episode_stop`, `episode_stop_drain` (5c); `help_priv` (the plain drain after a stopped episode); `liveness_slice`, `liveness_help_priv` |
| `NurserySpace::MinorEnv` (`NP:148-226`) | deques only (`par_n_` slots) | equal | `minor`, `liveness_minor` |
| `NurserySpace::RegionEnv` (`NR:280-337`) | deques only | equal | `minor` |
| `NurserySpace::AgeParEnv` (`NT:171-198`) | deques only | equal | `minor` |
| `NurserySpace::TenureParEnv` (`NT:953-982`) | deques only (`n` = the victim range) | pause engine and L3 equal; help: p over V = max(B, p) (`tenureConcFinish` `NT:1261`, the control at `NT:1275`) | `minor` (pause engine), `tenure_l3` (stoppable L3), `help` (p < B: work in a slot no participant owns; p ≥ B is `minor`'s shape) |

`slice_dq` (a finite budget with a deques-only `anyWork`) matches no real environment: it hosts
`idle_before_publish`. The harness environments (`test/gc-helper-tsan/mark_harness.cpp`: `SynthEnv`
`:233`, `PackedEnv` `:434`; `minor_harness.cpp`'s `Copier::Env`) mirror `ParallelEnv` and
`MinorEnv`. `MinorEnv`'s FIFO option (`minor_fifo_order`, `AllocatorCommon.hpp:721`, default off)
only changes which private entry is popped; the model pops LIFO.

## 4. Abstractions, and why each is sound

| Real thing | Model | Argument |
|---|---|---|
| the heap graph | a constant graph (`MC.tla`) | objects are immutable while marked (P1); M2 only needs "scanning creates entries" |
| the Chase–Lev deque | a sequence, each push / take / steal one step | linearizable (PPoPP'13), including the take/steal race on the last element and growth; W1 checks our implementation under C11 |
| `stealAny`'s four passes | one step: steal from some non-empty victim, or "found nothing" | "found nothing although work exists" is a real outcome only when a victim was read before its owner pushed, or CASes were lost to other thieves. **Pass configurations allow it without limit** (an over-approximation: sound for a pass). **Expected-failure configurations** (mutants, `wrap`, CR-005) allow it only when every other deque is empty (`CapGiveUps`, `MaxGiveUps = 0`), so every counterexample is one the code can produce (AUDIT.md 2026-09-29: three failures needed an impossible give-up). Liveness caps it at `MaxGiveUps = 1` per run |
| `anyWork()` | one slot per step (`I_Scan*`), then that slot's `priv` in a separate step (`I_Priv*`), index order, first hit returns | the deque and `priv` loads are separate in the code. `emptyApprox`'s two relaxed loads stay one step: while only pushes run it is exact at its `bottom` load; a concurrent take or steal comes from a thread counted active, so a done-CAS in that window fails anyway. Reading one's own `priv` needs no step (only the owner writes it) |
| `publishHalf` at ≥ 64 entries, checked every 32 pushes and every 64 pops | after a push or a pop that leaves ≥ `PUB_MIN`, *may* publish half (`either`) when the deque is empty | over-approximates both thresholds. The pop-side one (`R_PopPub*`) never fires at model-check scale (a stack never exceeds 2 after a pop), so it adds no states; the trace needs it |
| the 31-bit epoch | `EpochMod = 0`: no epoch; `dirty[p]` set by every reactivation while p is between `I_Load` and its done-CAS (`DecWindow`) | exact: the epoch is only compared, and the CAS fails iff someone reactivated since the load. `wrap` (`EpochMod = 2`) shows what a wrap would do (§6) |
| the saved word `s` | with `EpochMod = 0`, `active`'s sign only (`Saved`) | the code tests `active == 0` and CASes only from such a word; between the load and the CAS, `goIdle` cannot run from 0 and every reactivation sets `dirty` |
| a drain's budget (`kDrainBudget`) | `Budget0 = 40`, and the idle loop's two budget loads fold away (`BudgetNeverEmpty`) | a run draws at most 2 × `Nodes` scans (split_tas) and `TB` held tickets per participant. `BudgetOK` checks the premise in every state; `budget_premise` shows it can fail |
| ticket batch 256, ring 16, publish threshold 64 | `TB = 2`, `RING = 1` (deep 2), `PUB_MIN = 2`; the trace uses the code's values | small values keep "a thread holds more tickets than it needs" and "an entry is invisible in a ring" reachable |
| `Env::prefetch`, jitter, backoff, `test_bg_hold_` | not modelled | delays; the model already explores every interleaving. `bgEntry`'s hold (`OGS:4512`) delays a member that is already counted active |
| several foreground members | one joiner | the assist pool and the share epoch are the joiner's only effects; more joiners add interleavings of the same steps |
| retiring old deque arrays | not modelled | a quiescence rule of the mutator (IM14, register CR-010): `retireAllDequeArrays` (`OGS:4479`) runs from `runMarkers` only when `bg_ep_ != Running`, from `reapBackground` after the join, `closingFinish` after the joins, and `launchBackground` before the launch. The model never frees an array; it assumes the rule |
| `kParallel == false` (`SerialEnv`) | not modelled | one thread |

## 5. Footprint rows (A3)

| Row | Model |
|---|---|
| H10 (05c P§3.6) slot deques, private stacks, counters | `deque`, `pstack`, `priv`, `uBudget`/`uAssist` (`ctr.units`); `retireOldArrays` and `reset` are the quiescence rule of §4 |
| H11 `alloc_stats_.pm` | not modelled: merged after the join from the members' own counters |
| H12 test hooks | `test_leave_private_on_exit_` = mutant `skip_exit_publish`; `test_steal_without_ticket_` (`c.steal_without_ticket`) = mutant `steal_without_ticket`; `test_bg_hold_` delays only (§4) |
| H13 `markers_[]`, `mark_slots_`, `mark_parallel_` | `Slots` (the victim range), fixed during a run (`ensureMarkers` runs with no episode) |
| 06 P§3.11 (the parallel minor) | no row lists the workers' slots or the `SliceControl`: they are H10's shape (`MinorWorker`: `stack`/`head`, `priv`, `deque`, `ctr`), modelled here with `AnyWorkCountsPriv = FALSE`. Proposed to the orchestrator as a new row |
| T7 (07 P§3.17) job-private state; the L3 collectors' slots (`tenure_workers_`) | H10's shape; `tenure_l3`, `help` |
| the pool of an assist | `apool` (a mutator stack local, shared only with the foreground members of that assist) |

Census of `MW` (2026-09-29): every atomic maps to `word`/`dirty` (`state`), `budget`/`apool`,
`stop`, `share` (`share_epoch`), a deque (`top_`, `bottom_`, `array_`, the element stores: W1) or
`priv`. `SliceControl::n`, `jitter_us` and `steal_without_ticket` are plain fields written before the
launch (LaunchJoin). The trace build adds `tlaNextCtl`'s counter and the thread-local `tla_run`
(`MW:33-56`), which exist only when `ECO_TLA_TRACE` is defined.

## 6. Invariants (A7)

| Invariant | Id | Where the code checks it |
|---|---|---|
| `ScanOnce` | IM10 | `im10NoteScan` (validate builds) |
| `TerminationSafe` | the termination rule (05b P§3.3) under HEAP_064 / HEAP_065 | `runMarkers`' `assert(c.active() == 0 && c.done())`; the harness's `min(budget, remaining)` checks |
| `Drain` | IM15 plus the Drain contract (parent plan §5.0) | `assertNoPrivateWork` (`OGS:4452`); `closingFinish`'s `markStackEmpty` assert |
| `TicketsExact` | IM12 / GC_DET_001 | `runMarkers`' `units == budget - c.budget` assert |
| `AssistExact` | the assert in `assistEpisode` | `units == budget - pool` |
| `ClosingFinished` | the assert in `closingFinish`; since register-fixes Phase 5 (CR-005, 2026-10-01) `word.done \/ stop` | `assert(bg_ep_ == BgEpisode::Finished \|\| bg_ep_ == BgEpisode::None)`: a foreign stop's leftovers are drained by `runMarkers` |
| `BudgetOK` | MODEL_M2_1: the premise of the folded budget loads | — (the model's own abstraction) |
| `AllExit` | MODEL_M2_2: every participant exits (liveness) | — |
| `Postcondition` | `Drain /\ TicketsExact` (the plan's name; not listed separately in a configuration) | — |

**The epoch's assumption** (`wrap`, `witness:TerminationSafe`). With a 1-bit epoch TLC finds the
ABA with three participants and only realizable steals: a decider loads `s` (active 0); two others
reactivate (the epoch wraps), one claims the rest of the budget and finds nothing to steal (the other
holds the only entry in its ring), the other's claim fails and it idles with its children published,
the first returns its tickets; the word is `s` again and the done-CAS succeeds with budget and work
left. So the protocol assumes **fewer than 2^31 reactivations between one decider's state load and
its done-CAS**. That is very unlikely rather than impossible: a spinner can reactivate every few
hundred nanoseconds (at 200 ns, 2^31 reactivations take about 430 s for one spinner and 54 s for
eight), so a wrap needs the decider held off the CPU for tens of seconds (plausible only for a
background member at `SCHED_IDLE` under load) while others spin, and then the word must match
exactly.

## 7. Contracts (parent plan §5.0)

M2 provides **Drain**: `ScanOnce ∧ TerminationSafe ∧ Drain`, in every pass configuration. What M1
and M3 use: exactly-once scans, and a run that terminates (`done`) with budget left scanned
everything reachable with no entry left anywhere. What M5 and M6 use: a stopped run leaves no private
work and every greyed-but-unscanned node in a deque (`episode_bgstop`, `tenure_l3`,
`episode_stop_drain`), and a later run with fewer participants than victims finishes it (`help`,
`help_priv`). M2 does not provide M1's atomic scan (M1's own argument).

M2 uses **LaunchJoin** (M6): the launch publishes the initial distribution, the join publishes the
members' writes, a stop is seen at the member's next loop top or idle round. And it assumes the
quiescence rule of IM14 / CR-010 (§4): no `Env` touches a slot's owner-only state, and no deque array
is retired, while a run can hold it. The model's initial states are that premise; it does not check
where the mutator enforces it.

## 8. Weak memory (A4)

The model is sequentially consistent.

| What M2 assumes under SC | Code | Companion | Status (`test/genmc/AUDIT.md`, 2026-09-28) |
|---|---|---|---|
| the deque is linearizable (push/take/steal, the last-element race, growth, the release element store and acquire steal load) | `WorkStealingDeque` (`MW:90-219`) | W1 (`w1_deque`, two thieves) | PASS |
| a decider that acquires a member's `goIdle` also sees the work it published before it | `publishAll` → `returnTickets` → `goIdle` (`MW:536-538`, `:548-550`), the decider's acquire load | W2 (`w2_termination`) | PASS |
| a reactivation between a decider's load and its CAS fails the CAS | `reactivate`, the done-CAS | W2 (`w2_reactivate`) | PASS |
| returned tickets are seen by a decider's budget load | `returnTickets`, `budget.load(acquire)` | W2 (`w2_returned_tickets`) | PASS |
| `priv` publishes private work to `anyWork` | `priv` stores, `ParallelEnv::anyWork` | W2 (`w2_priv`) | PASS |
| trap 5 (publish after `goIdle`) is harmless in the mark env | — (the code publishes first) | W2 (`w2_idle_before_publish`) | fails under RC11, passes under SC; the one-scan reduction fails under SC. M2 agrees (AUDIT.md) |
| a stop is seen by a decider that acquired the stopped participant's `goIdle` | `stop` is a relaxed load | read-read coherence after that acquire | argued, not checked |

## 9. Trace validation (A5)

Harness: `test/gc-helper-tsan/mark_harness.cpp`, trace build `gc-mark-trace` (the project's
`ECO_TLA_TRACE` option): the real `runMarkerLoop` over `SynthHeap`/`SynthEnv`, a `ParallelEnv`
mirror. Scenarios `slices` (n Members on `GCMarkGang`, 5b slices then a drain) and `episode` (B
background Members on `GCBackgroundGang`, this thread as slot 0 making assists, then a stop, the
closing join, or the closing join once the members have returned, which finds the control done);
rows in `test/tla/traces.txt`. Spec: `TraceSliceControl.tla` with `TraceSlices.cfg`
/ `TraceEpisode.cfg`, matched in any order the log allows (`TraceAnyOrder`); `TraceSliceControl.keep`
lists the matched events. Results: AUDIT.md, 2026-09-29.

**Hooks** (compiled out unless `-DECO_TLA_TRACE=1`; `w` is the code's slot, the model's process is
`w + 1`):

| Event | Hook | Fields | Model step |
|---|---|---|---|
| `mw.run` | `runMarkerLoop` entry `MW:475` | `w`, `ctl`, `assist`, `joined` | `M_Run`; a joiner: check (its next step is `J_AJoin`/`J_CJoin`) |
| `mw.claim` | `claimTicket`'s successful CAS `MW:330` (via `ECO_MW_TRACE_POOL`) | `w`, `took`, `old`, `new`, `pool`; `rmw` `B<ctl>` for the control's budget | the claim in `R_Top`/`R_Fill`/`R_Steal` |
| `mw.ret` | `returnTickets`' `fetch_add` `MW:341` | `w`, `cnt`, `old`, `new`, `pool`; `rmw` `B<ctl>` | `R_Idle*`, `R_ExitActive*`, `R_ExitIdle2` |
| `mw.take` | after `env.takeOwn` `MW:501` | `w`, `e` (0: nothing) | `TakeOwn` in `R_Top`/`R_Fill`/`R_TakeOwn` |
| `mw.scan` | before `env.scan` `MW:510` (and the hook's scan `:525`) | `w`, `e` | `R_Scan` |
| `mw.push` | `SynthHeap::pushGrey` | `w`, `e` | `R_Push` |
| `mw.pub` | each `deque.push` of `SynthHeap::publishHalf` / `publishAll` | `w`, `e`, `put` `mwe<e>` | `R_PubHalf*`, `R_PopPub*`, `R_Idle`, `PA_Loop`, `R_ExitActive`, `R_ExitIdle` |
| `mw.priv` | the `priv` store ending a publish | `w`, `cnt` | `R_PubHalfPriv`, `R_PopPubPriv`, `PA_Priv`, `PA_Loop` |
| `mw.steal` | `stealAny`'s success `MW:406` | `w`, `v`, `e`, `get` `mwe<e>` | `R_Steal`/`R_StealTry` |
| `mw.stealNone` | `stealAny` returning `kEmpty` `MW:393`, `:414` | `w` | the give-up in `R_Steal`/`R_StealTry` |
| `mw.idle` | `goIdle` `MW:276` | `w`, `act`; `rmw` `S<ctl>` `old`/`new` | `GoIdle` in `R_Idle*`, `R_ExitActive*` |
| `mw.react` | `reactivate`'s CAS `MW:290` | `w`, `act`; `rmw` `S<ctl>` | `I_React`, `J_AJoin`, `J_CJoin` |
| `mw.reactDone` | `reactivate` seeing `done` `MW:284` | `w`; `rd` `S<ctl>` | the `done` branch of the same |
| `mw.seeDone` | `idleUntilWorkOrDone` `MW:425` | `w`; `rd` `S<ctl>` | `I_Load` with `done` |
| `mw.seeStop` | `MW:430` | `w`, `get` `stop<ctl>` | `I_Stop` with `stop` |
| `mw.decide` | the done-CAS `MW:446`, `:451` | `w`, `ok`; `rmw` or `rd` `S<ctl>` | `I_Decide` |
| `mw.exit` | `runMarkerLoop`'s returns `MW:479`, `:551`, `:558` | `w`, `why`; `get` `stop<ctl>` when it saw the stop | check: the run returned |
| `mw.ctl`, `mw.end` | the harness, before and after each slice's gang run | `ctl`, `budget`, `drain`, `active`, `victims`; `units`, `left`, `done` | a fresh control over the deques the last run left; check |
| `mw.assist`, `mw.assistEnd`, `mw.closing`, `mw.stopReq`, `mw.joined` | the harness's episode | pool, units, `put` `stop<ctl>`, `done`, entries left | `J_Start`/`J_AssistCheck`; `AssistExact`'s check; `J_CJoin`; `S_Stop`; `J_ClosingCheck` or the stop's check |

The state word's RMWs and the control budget's RMWs are chained by value (merger `rmw`); a steal
follows the publish of its entry (`put`/`get`); a member that saw the stop follows the stop request.
The gang events (`GHP`, already in the tree) order the harness against the members.

**Hidden** (no hook): a failed claim (the pool read 0), the loop-top `stop` and `share_epoch` loads,
the children's test-and-sets after the first, `publishHalf`'s `emptyApprox` on a non-empty deque, the
idle loop's state, budget and `anyWork` loads (`HiddenAt` in the spec). Every other step is matched.

**Where these hooks also fire.** `MarkWork.hpp` is shared: M1's tiny-graph trace (`gc-heap-trace
tiny`, the real allocator) and M3's minor trace (`gc-minor-trace`) record every event, so their raw
logs now contain `mw.*` events. Their `.keep` files drop them after the merge; the chains they add
(`S<ctl>`, `B<ctl>`, one serial per control) are complete, so the merge still succeeds (checked on
M1's rows, AUDIT.md).

## 10. A1–A9

| Rule | M2 |
|---|---|
| A1 | §2: every label one atomic step; `anyWork` per slot and per location; `publishAll`/`publishHalf` one push per step, then `priv`; `emptyApprox` one step (§4) |
| A2 | the state word is one record changed only by RMW-shaped steps; `priv` a count; mark bits per node (bytes are M4's) |
| A3 | §5 |
| A4 | §8: W1, W2 |
| A5 | §9 |
| A6 | every invariant has a mutant: `TerminationSafe` (`two_word`, `return_after_idle`, `idle_before_publish`, `idle_before_publish_onescan`, `joiner_no_reactivate`, `joiner_invisible`, `stop_sets_done`, `anywork_participants_only`), `ScanOnce` (`split_tas`), `Drain` (`skip_exit_publish`, on `episode_bgstop` and `tenure_l3`), `TicketsExact` (`steal_without_ticket`), `AssistExact` (`assist_returns_to_budget`), `ClosingFinished` (`member_exits_undone`; `episode_stop` passes since CR-005's fix), `BudgetOK` (`budget_premise`), `AllExit` (`never_decide`). The historical bug is `two_word` |
| A7 | §6 |
| A8 | 2–3 participants, 4–5 nodes, `TB = 2`, `RING = 1–2`, `PUB_MIN = 2`; no state constraint (the epoch is exact, every other variable bounded); the 1-bit epoch in `wrap` |
| A9 | proposed canary lines (not in `manifest.txt` yet): `file` `MW`; `region`s: `ParallelEnv` (`OGS:3583-3614`), `publishHalf`/`publishAll`/`pushGrey` (`OGH:979-1002`), `pushGreyP`…`MinorEnv` (`NP:114-226`), `RegionEnv` (`NR:280-337`), `AgeParEnv` (`NT:171-198`), `TenureParEnv` (`NT:953-982`), `runMarkers`, `launchBackground`, `bgEntry`/`assistEntry`/`closingEntry`, `reapBackground`, `assistEpisode`, `closingFinish` (`OGS`), `tenureConcLaunch`/`tenureConcFinish` (`NT:1244-1293`), the round-robin distributions (`NP:727-735`, `NR:854-861`, `NT:294-298`, `tenureParDistribute`); `census`: `OGS`, `NP`, `NR`, `NT`, `GHP` |

## 11. Differences from the plan's sketch (all recorded in AUDIT.md)

- Steps merged at shared accesses (§2): the loop-top loads, the fill's claim and take, the first
  push of a publish, the first child's test-and-set, the joiner's reactivate moved into the Joiner.
- `BudgetNeverEmpty` folds a drain's budget loads, with `BudgetOK` and its negative control.
- The pop-side `publishHalf` (`R_PopPub*`, the plan's open question 3), for the trace.
- The joiner loops over `AssistRuns` assists (the trace makes several); the model-check
  configurations use at most one.
- `GreyKid` takes the children in id order (`Min`), the harness's field order.
- Expected failures allow only realizable give-ups; `wrap` and `two_word` need three participants.
- Mutants added: `idle_before_publish_onescan`, `joiner_invisible`, `skip_exit_publish` on
  `tenure_l3`, `budget_premise`; `anywork_participants_only` on `help` dropped (it cannot fail
  realizably). Configurations added: `slice3`, `episode_stop_drain`, three liveness rows.

<!-- canary-pins begin -->
## Canary pins (A9)

The code this model describes, pinned in `test/tla/manifest.txt` (generated 2026-09-29
from this model's A9 row). A pin that fires names this model; re-audit, then write an
AUDIT.md entry quoting the new hash prefix (`test/tla/README.md`, "The canary").

| Kind | Path | Id |
|---|---|---|
| file | `runtime/src/allocator/MarkWork.hpp` | `-` |
| file | `runtime/src/allocator/TlaTrace.hpp` | `-` |
| file | `test/gc-helper-tsan/mark_harness.cpp` | `-` |
| region | `runtime/src/allocator/OldGenSpace.cpp` | `OGS.launchBackground` |
| region | `runtime/src/allocator/OldGenSpace.cpp` | `OGS.reapBackground` |
| region | `runtime/src/allocator/OldGenSpace.cpp` | `OGS.runCycleStepConcurrent` |
| region | `runtime/src/allocator/OldGenSpace.cpp` | `OGS.assistEpisode` |
| region | `runtime/src/allocator/OldGenSpace.cpp` | `OGS.closingFinish` |
| region | `runtime/src/allocator/OldGenSpace.cpp` | `OGS.runMarkers` |
| region | `runtime/src/allocator/OldGenSpace.cpp` | `OGS.ParallelEnv` |
| region | `runtime/src/allocator/OldGenSpace.hpp` | `OGH.publishGrey` |
| region | `runtime/src/allocator/NurseryParallel.cpp` | `NP.MinorEnv` |
| region | `runtime/src/allocator/NurseryParallel.cpp` | `NP.minorGCParallel` |
| region | `runtime/src/allocator/NurseryRegion.cpp` | `NR.RegionEnv` |
| region | `runtime/src/allocator/NurseryRegion.cpp` | `NR.minorGCRegion` |
| region | `runtime/src/allocator/NurseryTenure.cpp` | `NT.AgeParEnv` |
| region | `runtime/src/allocator/NurseryTenure.cpp` | `NT.TenureParEnv` |
| region | `runtime/src/allocator/NurseryTenure.cpp` | `NT.tenureParDistribute` |
| region | `runtime/src/allocator/NurseryTenure.cpp` | `NT.tenureConcLaunch` |
| region | `runtime/src/allocator/NurseryTenure.cpp` | `NT.tenureConcFinish` |
| census | `runtime/src/allocator/MarkWork.hpp` | `-` |
| census | `runtime/src/allocator/NurseryParallel.cpp` | `-` |
| census | `runtime/src/allocator/NurseryRegion.cpp` | `-` |
| census | `runtime/src/allocator/NurseryTenure.cpp` | `-` |
| census | `runtime/src/allocator/OldGenSpace.cpp` | `-` |
| census | `runtime/src/allocator/OldGenSpace.hpp` | `-` |
| grep | `-` | `H10` |
| grep | `-` | `H11` |
| grep | `-` | `H12` |
| grep | `-` | `H13` |
| grep | `-` | `P6.M17` |
<!-- canary-pins end -->
