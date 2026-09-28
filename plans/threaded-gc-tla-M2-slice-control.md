# Threaded GC — TLA+ model M2: the marker loop, tickets and termination

**Status:** IMPLEMENTATION-READY PLAN (2026-09-28). The PlusCal sketch in §4.5 passes the PlusCal
translator and SANY (tla2tools 1.8.0). **TLC has not run on this version.** An earlier draft was
model-checked during exploration; §6.1 records what that showed. Its numbers guide the
configurations but are not results.

**Parents:** `plans/threaded-gc-tla-verification.md` (§2 rules A1–A9, §5.1 index) and
`plans/threaded-gc-tla-primer.md` (read first if TLA+ or the GC terms are new).

**Why M2 is first:** it is the smallest model and the one with the most reuse. The same C++
template, `markwork::runMarkerLoop`, drives five different kinds of parallel GC work:

| Environment (`Env`) | File | Used by | `anyWork()` counts |
|---|---|---|---|
| `OldGenSpace::ParallelEnv` | `OldGenSpace.cpp:3480` | 5b slices, 5c background episodes, assists, closing joins | deques **and** private stacks (`priv`) |
| `NurserySpace::MinorEnv` | `NurseryParallel.cpp:148` | phase 6 parallel minor | deques only |
| `NurserySpace::RegionEnv` | `NurseryRegion.cpp:280` | 7b region minor | deques only |
| `NurserySpace::TenureParEnv` | `NurseryTenure.cpp:931` | 7c tenure: pause engine, help, and the L3 background collectors (which can be **stopped**) | deques only |
| `NurserySpace::AgeParEnv` | `NurseryTenure.cpp:170` | 07b ageing mark in a pause | deques only |

It also had a real bug that a test only caught under load (§2.3). So the model can prove it has
teeth against history.

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
TLC must find this trace.

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
  finishes it: 5c's relaunch, or 7c's help in the next pause.

## 3. The code the model covers

| Code | Lines (2026-09-28, post-7c) | Model element |
|---|---|---|
| `SliceControl` (state word, budget, stop, share_epoch) | `MarkWork.hpp:205-258` | `word`, `budget`, `stop`, `share` |
| `claimTicket` / `returnTickets` | `MarkWork.hpp:285-304` | macros `ClaimOrFill`, `ClaimOrRole`, `ReturnTickets` |
| `stealAny` (4 passes, random start, aborts) | `MarkWork.hpp:347-365` | step `R_StealTry` (atomic steal, or "found nothing") |
| `idleUntilWorkOrDone` | `MarkWork.hpp:369-395` | steps `I_Load` … `I_Retry` |
| `runMarkerLoop` | `MarkWork.hpp:407-484` | procedure `Run` |
| `WorkStealingDeque` push/take/steal | `MarkWork.hpp:63-195` | `deque[x]` as a sequence, each operation one step (W1 checks the real algorithm) |
| `ParallelEnv::takeOwn` / `anyWork` / `publishAll` | `OldGenSpace.cpp:3480-3510` | `R_TakeOwn`, `AnyWorkNow`, procedure `PublishAll` |
| `OldGenSpace::publishHalf`, `publishAll`, `pushGrey` | `OldGenSpace.hpp:881-906` | `R_Push`, `R_PubHalf*`, `PublishAll` |
| `MinorEnv` / `RegionEnv` / `TenureParEnv` / `AgeParEnv` `anyWork` (deques only) | see the table above | constant `AnyWorkCountsPriv = FALSE` |
| `testAndSetMark<ParallelMark>` (`fetch_or`) | `OldGenSpace.cpp:3039` | `R_Kids` (test-and-set of `mark[c]`) |
| `launchBackground` (round-robin t0 greys into bg deques) | `OldGenSpace.cpp:4431` | `InitDeque` |
| `assistEpisode` (pool, share_epoch, `units == budget - pool`) | `OldGenSpace.cpp:4534` | process `Joiner`, `J_Assist`, `J_AssistCheck` |
| `closingFinish` (closing join, `assert(bg_ep_ == Finished)`) | `OldGenSpace.cpp:4569` | `J_ClosingRun`, `J_ClosingCheck` |
| `GCBackgroundGang::stopAndJoin` storing `stop` | `GCHelperPool.cpp:638` | process `Mutator` |
| `tenureConcLaunch` / `tenureConcFinish` (L3 stop, then help) | `NurseryTenure.cpp:1222-1270` | configuration `tenure_l3` (§6) |

**Deliberately outside M2:**
- the heap: M2 uses a fixed graph, and M1 has the real snapshot semantics;
- the deque's internal memory orders: W1;
- how the gang starts and joins threads: M6 (M2 assumes the LaunchJoin contract);
- the pacing that decides *when* to assist;
- jitter and backoff timing. Backoff is a delay, and a delay changes nothing in a model that
  already explores every interleaving.

## 4. The model

### 4.1 Abstractions, and why each is sound

| Real thing | Model | Why it is sound (or where it over-approximates) |
|---|---|---|
| The heap graph, read by `scanObject` | A constant graph `Nodes`, `Edges` | Objects are immutable during marking (P1); M2 only needs "scanning creates new entries" |
| Chase–Lev deque | A sequence: push/take at the end, steal at the head, each one atomic step | The algorithm is linearizable (PPoPP'13). W1 checks our implementation of it under C11 |
| `stealAny`'s four passes with aborts | One step that steals from some non-empty victim, or returns "nothing" | Returning nothing although work exists is a real outcome (it scanned victims at different moments, or lost CASes). It is capped by `MaxGiveUps` so liveness is not spuriously broken (primer §4.4) |
| `publishHalf` at ≥ 64 entries, checked every 32 pushes / 64 pops | After each push, *may* publish half (`either skip or ...`) when ≥ `PUB_MIN` and the deque is empty | Over-approximation: it includes every real threshold behaviour. A counterexample that needs an impossible publish must be checked against the code (primer §4.3) |
| `takeOwn`'s `publishHalf` every 64 pops | Not modelled separately | The push-side choice already produces every publish shape |
| `priv` written after each private push/pop | Written in the same step as the owner-only stack change | Only `priv` is shared. Owner-only stack changes are invisible to others (primer §3.2) |
| `publishAll` storing `priv = 0` at the end | Separate step `PA_Priv` after the per-entry pushes | Faithful: while publishing, an entry is both in the deque and counted in `priv`. That double counting is conservative, and the model keeps it |
| Ticket batches of 256 | `TB = 2` | Keeps "a thread holds more tickets than it needs" reachable with tiny pools, which is the shape of the §2.3 bug |
| Ring of 16 | `RING = 1` or `2` | One entry is enough for "ticket held, entry invisible to others". Two adds reordering |

### 4.2 Constants

| Constant | Meaning | Code value | Model values |
|---|---|---|---|
| `Nodes`, `Edges`, `Roots` | the object graph | the heap | 4 nodes (diamond `1→{2,3}→4`), deep: 5 nodes |
| `BgSlots` | participants counted active at the start (their slots) | B background markers / N workers | `{1,2}` or `{2,3}` |
| `FgSlot` | the joiner's slot, 0 = none | foreground slot 0..F−1 | `0` or `1` |
| `InitDeque` | the initial distribution of entries | t0 greys round-robin (`launchBackground`) or on worker 0 (`minorGCParallel` step 4) | per configuration |
| `Budget0` | the control's pool | `kDrainBudget` (drain) or a slice budget | `40` (drain), `3` (slice) |
| `TB` | ticket batch | 256 | 2 |
| `RING` | ring depth | 16 | 1–2 |
| `PUB_MIN` | publishHalf threshold | 64 | 2 |
| `AnyWorkCountsPriv` | environment | TRUE = `ParallelEnv`; FALSE = minor/region/tenure/age | both |
| `StopAllowed` | a stop may arrive | 5c episodes, 7c L3 | per configuration |
| `AssistRuns`, `AssistBudget` | joiner's assists | paced by `runCycleStepConcurrent` | 0–1, 2 |
| `DoClosing` | joiner ends with a closing join | `closingFinish` | per configuration |
| `MaxGiveUps` | "found nothing" outcomes while work exists | unbounded in principle | 1 |
| `MaxEpoch` | state constraint on reactivations (§4.7) | 2^31 before wrap | 6 |
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
| `word` | the state word as a record `[active, epoch, done]` | `c.state` | RMWs only |
| `stop`, `share` | stop request, share epoch | `c.stop`, `c.share_epoch` | the mutator |
| `uBudget`, `uAssist` | ghost unit counters per pool | `ctr.units` summed per pool | the scanner |
| procedure locals `ring`, `tickets`, `active`, `seen`, `sw`, `found`, … | per-participant loop state | the locals of `runMarkerLoop` / `MarkerCounters` | owner |

### 4.4 Steps: model labels to code lines

| Label | Code (`MarkWork.hpp` unless noted) | Atomic operation it stands for |
|---|---|---|
| `R_Join` | 412 | `reactivate()` CAS (or return when done) |
| `R_Top` | 423 | `stop.load(relaxed)` |
| `R_Share` | 425-426 | `share_epoch.load`; then `publishAll` |
| `R_Fill` + `ClaimOrFill` | 429-430, 285-296 | `claimTicket`'s batch CAS on the pool |
| `R_TakeOwn` | 431-433; `ParallelEnv::takeOwn` | private pop + `priv` store, or `deque.take()` |
| `R_AfterFill` | 436-441 | scan the oldest ring entry (children read: immutable) |
| `R_Kids` | `testAndSetMark` (`OldGenSpace.cpp:3039`) | `fetch_or` on the child's mark |
| `R_Push`, `R_PubHalf*` | `pushGrey`, `publishHalf` (`OldGenSpace.hpp:881-906`) | owner push + `priv` store; each deque push |
| `R_Stopping` | 448 | leave (still active) when stopping and the ring is empty |
| `R_Steal` + `ClaimOrRole`, `R_StealTry` | 457-461, 347-365 | ticket claim, then one `deque.steal()` |
| `R_Role` | 462 | an Assist leaves instead of idling |
| `R_Idle`, `R_Idle2`, `R_Idle3` | 464-467 | `publishAll`, `returnTickets`, `goIdle` (`fetch_sub`) |
| `I_Load`, `I_Stop` | 372-374 | `state.load(acquire)`, `stop.load` |
| `I_Budget1`, `I_Scan1` | 375 | `budget.load(acquire)`, then one slot's `emptyApprox`/`priv` per step |
| `I_React` | 376 | `reactivate()` |
| `I_Zero`, `I_Budget2`, `I_Scan2` | 379-382 | the `active == 0` branch's re-check |
| `I_Decide` | 385-389 | the done-CAS from `s` |
| `R_ExitActive*` | 475-479 | `publishAll`, `returnTickets`, `goIdle` |
| `R_ExitIdle*` | 481-483 | `publishAll`, `returnTickets` |

### 4.5 The PlusCal sketch

File: `test/tla/M2-slice-control/SliceControl.tla`. This is the text that passed the translator.
The generated translation is omitted here.

```tla
---------------------------- MODULE SliceControl ----------------------------
EXTENDS Naturals, Sequences, FiniteSets, TLC

CONSTANTS
    Nodes, Edges, Roots,      \* the immutable object graph (P1: frozen heap)
    BgSlots,                  \* slots whose participants start counted active
    FgSlot,                   \* 0 = no foreground joiner
    InitDeque,                \* [Slots -> Seq(Nodes)]: the launch distribution
    Budget0,                  \* initial c.budget (tickets)
    TB,                       \* kTicketBatch (256 in code)
    RING,                     \* kRingDepth (16 in code)
    PUB_MIN,                  \* kPublishMin (64 in code)
    AnyWorkCountsPriv,        \* TRUE = ParallelEnv (mark), FALSE = the nursery envs
    StopAllowed,              \* a stop request may arrive (bg episodes, 7c L3)
    AssistRuns,               \* how many assist runs the joiner makes
    AssistBudget,             \* tickets per assist run
    DoClosing,                \* the joiner ends with a closing (Member) run
    MaxGiveUps,               \* spurious empty steals per participant
    MaxEpoch,                 \* TLC state constraint: reactivations explored
    MUTANT

Slots == BgSlots \cup (IF FgSlot = 0 THEN {} ELSE {FgSlot})
MutId == 0
Children(n) == {m \in Nodes : <<n, m>> \in Edges}
RECURSIVE ReachFrom(_)
ReachFrom(S) == LET N == S \cup UNION {Children(n) : n \in S}
                IN IF N = S THEN S ELSE ReachFrom(N)
Reachable == ReachFrom(Roots)
Range(sq) == {sq[i] : i \in 1..Len(sq)}

(* --algorithm SliceControl
variables
    deque   = InitDeque,                      \* WorkStealingDeque per slot
    pstack  = [s \in Slots |-> <<>>],         \* private stack (owner only)
    priv    = [s \in Slots |-> 0],            \* published size of stack (relaxed)
    mark    = [n \in Nodes |-> n \in Roots],  \* mark bits (fetch_or)
    scanned = [n \in Nodes |-> 0],            \* ghost: scans per node
    budget  = Budget0,                        \* c.budget
    apool   = 0,                              \* the current assist pool
    word    = [active |-> Cardinality(BgSlots), epoch |-> 0, done |-> FALSE],
    stop    = FALSE,                          \* c.stop
    share   = 0,                              \* c.share_epoch
    uBudget = 0,                              \* ghost: scans paid from c.budget
    uAssist = 0;                              \* ghost: scans paid from apool (this run)

define
    NullWord == [active |-> 0, epoch |-> 0, done |-> FALSE]
    NoWorkAnywhere == \A x \in Slots : deque[x] = <<>> /\ pstack[x] = <<>>
    AnyWorkNow(x) == deque[x] # <<>> \/ (AnyWorkCountsPriv /\ priv[x] # 0)
    \* Every entry scanned at most once (IM10).
    ScanOnce == \A n \in Nodes : scanned[n] <= 1
    \* The done bit is set only when nothing is left to do (P§3.3):
    \* either the budget ran out, or no entry is held anywhere.
    TerminationSafe ==
        word.done => (budget = 0 \/ (NoWorkAnywhere /\ word.active = 0))
end define;

\* claimTicket(w, pool) that jumps to R_AfterFill / R_Role when the pool is empty
\* (PlusCal macros cannot take a goto target as a parameter).
macro ClaimOrFill() begin
    if tickets > 0 then
        tickets := tickets - 1;
    elsif pool = "budget" /\ budget > 0 then
        tickets := (IF budget < TB THEN budget ELSE TB) - 1;
        budget  := budget - (IF budget < TB THEN budget ELSE TB);
    elsif pool = "assist" /\ apool > 0 then
        tickets := (IF apool < TB THEN apool ELSE TB) - 1;
        apool   := apool - (IF apool < TB THEN apool ELSE TB);
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
    else
        goto R_Role;
    end if;
end macro;

macro ReturnTickets() begin
    if pool = "budget" then budget := budget + tickets;
    else apool := apool + tickets; end if;
    tickets := 0;
end macro;

\* publishAll(self): push every private entry, oldest first, one deque push
\* per step; priv is stored only at the end (as in OldGenSpace::publishAll).
procedure PublishAll()
begin
  PA_Loop:
    while pstack[self] # <<>> do
        deque[self] := Append(deque[self], Head(pstack[self]));
        pstack[self] := Tail(pstack[self]);
    end while;
  PA_Priv:
    priv[self] := 0;
    return;
end procedure;

\* runMarkerLoop(env, self, c, pool, role, joined)
procedure Run(role, joined, pool)
variables ring = <<>>, tickets = 0, active = TRUE, seen = 0,
          stopping = FALSE, kids = {}, c = 0,
          wasSet = FALSE, sw = NullWord,
          aw = {}, found = FALSE, giveups = 0, half = 0;
begin
  R_Join:
    if joined then                                   \* c.reactivate()
        if word.done then return;
        else word := [word EXCEPT !.active = @ + 1, !.epoch = @ + 1];
        end if;
    end if;
  R_Top:
    while TRUE do
        stopping := stop;                            \* c.stopRequested() (relaxed)
      R_Share:
        if share # seen then
            seen := share;
            call PublishAll();
        end if;
      R_Fill:                                        \* (1) fill the ring
        while ~stopping /\ Len(ring) < RING do
            ClaimOrFill();
          R_TakeOwn:                                 \* env.takeOwn(self)
            if pstack[self] # <<>> then              \* private first
                ring := Append(ring, pstack[self][Len(pstack[self])]);
                pstack[self] := SubSeq(pstack[self], 1, Len(pstack[self]) - 1);
                priv[self] := Len(pstack[self]);
            elsif deque[self] # <<>> then            \* deque.take(): bottom
                ring := Append(ring, deque[self][Len(deque[self])]);
                deque[self] := SubSeq(deque[self], 1, Len(deque[self]) - 1);
            else
                tickets := tickets + 1;              \* ++w.tickets
                goto R_AfterFill;
            end if;
        end while;
      R_AfterFill:                                   \* (2) scan the oldest ring entry
        if ring # <<>> then
            scanned[Head(ring)] := scanned[Head(ring)] + 1;
            kids := Children(Head(ring));
            ring := Tail(ring);
            if pool = "budget" then uBudget := uBudget + 1;
            else uAssist := uAssist + 1; end if;
          R_Kids:
            while kids # {} do
                c := CHOOSE ch \in kids : TRUE;
                kids := kids \ {c};
                wasSet := mark[c];                   \* test-and-set: fetch_or
                mark[c] := TRUE;
              R_Push:                                \* pushGrey
                if ~wasSet then
                    pstack[self] := Append(pstack[self], c);
                    priv[self] := Len(pstack[self]);
                    c := 0;
                  R_PubHalf:                         \* publishHalf (maybe)
                    either
                        skip;
                    or
                        await Len(pstack[self]) >= PUB_MIN /\ deque[self] = <<>>;
                        half := Len(pstack[self]) \div 2;
                      R_PubHalfLoop:
                        while half > 0 do
                            deque[self] := Append(deque[self], Head(pstack[self]));
                            pstack[self] := Tail(pstack[self]);
                            half := half - 1;
                        end while;
                      R_PubHalfPriv:
                        priv[self] := Len(pstack[self]);
                    end either;
                else
                    c := 0;
                end if;
              R_PushDone:
                wasSet := FALSE;
            end while;
            goto R_Top;
        end if;
      R_Stopping:
        if stopping then goto R_ExitActive; end if;
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
            await giveups < MaxGiveUps
                  \/ \A x \in Slots \ {self} : deque[x] = <<>>;
            if \E x \in Slots \ {self} : deque[x] # <<>> then
                giveups := giveups + 1;
            end if;
            tickets := tickets + 1;                  \* ++w.tickets
        end either;
      R_Role:
        if role = "Assist" then goto R_ExitActive; end if;
      R_Idle:                                        \* (4) idle: publish, return, goIdle
        if MUTANT = "idle_before_publish" then
            word := [word EXCEPT !.active = @ - 1];
            active := FALSE;
            call PublishAll();
        else
            call PublishAll();
        end if;
      R_Idle2:
        if MUTANT = "return_after_idle" then
            if active then
                word := [word EXCEPT !.active = @ - 1];
                active := FALSE;
            end if;
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
      I_Load:                                        \* idleUntilWorkOrDone
        sw := word;
        if sw.done then goto R_ExitIdle; end if;
      I_Stop:
        if stop then goto R_ExitIdle; end if;
      I_Budget1:
        if budget > 0 then aw := Slots; found := FALSE;
        else aw := {}; found := FALSE; end if;
      I_Scan1:                                       \* env.anyWork(): one slot per step
        while aw # {} do
            with x \in aw do
                found := found \/ AnyWorkNow(x);
                aw := aw \ {x};
            end with;
        end while;
      I_React:
        if found then                                \* c.reactivate()
            if word.done then goto R_ExitIdle;
            else
                word := [word EXCEPT !.active = @ + 1, !.epoch = @ + 1];
                active := TRUE;
                sw := NullWord; found := FALSE;
                goto R_Top;
            end if;
        end if;
      I_Zero:
        if sw.active # 0 then goto I_Load; end if;   \* backoff; retry
      I_Budget2:
        if budget > 0 then aw := Slots; found := FALSE;
        else aw := {}; found := FALSE; end if;
      I_Scan2:
        while aw # {} do
            with x \in aw do
                found := found \/ AnyWorkNow(x);
                aw := aw \ {x};
            end with;
        end while;
      I_Decide:                                      \* CAS(word: s -> s | done)
        if ~found then
            if MUTANT = "two_word" then
                word := [word EXCEPT !.done = TRUE];  \* separate atomics: no CAS
                goto R_ExitIdle;
            elsif word = sw then
                word := [word EXCEPT !.done = TRUE];
                goto R_ExitIdle;
            end if;
        end if;
      I_Retry:
        goto I_Load;
    end while;
  R_ExitActive:                                      \* exit while still active
    call PublishAll();
  R_ExitActive2:
    ReturnTickets();
  R_ExitActive3:
    word := [word EXCEPT !.active = @ - 1];
    return;
  R_ExitIdle:                                        \* exit after termination or stop
    if MUTANT # "skip_exit_publish" then call PublishAll(); end if;
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
fair process Joiner \in (IF FgSlot = 0 THEN {} ELSE {FgSlot})
variables k = 0;
begin
  J_Loop:
    while k < AssistRuns do
        share := share + 1;                          \* share_epoch.fetch_add
        apool := AssistBudget;
        uAssist := 0;
      J_Assist:
        call Run("Assist", TRUE, "assist");
      J_AssistCheck:                                 \* units == budget - pool.load()
        assert uAssist = AssistBudget - apool;
        k := k + 1;
    end while;
  J_Closing:
    if DoClosing then
        share := share + 1;
      J_ClosingRun:
        call Run("Member", TRUE, "budget");
      J_ClosingCheck:                                \* closingFinish: reapBackground(true)
        await \A m \in BgSlots : pc[m] = "Done";
        assert word.done;                            \* assert(bg_ep_ == Finished): fails
                                                     \* with StopAllowed (register CR-005)
    end if;
end process;

\* The mutator / a fork hook on another thread: stopAndJoin() sets c.stop at any time.
process Mutator = MutId
begin
  S_Maybe:
    either
        await StopAllowed;
        stop := TRUE;
    or
        skip;
    end either;
end process;

end algorithm; *)
\* BEGIN TRANSLATION
\* END TRANSLATION

Participants == BgSlots \cup (IF FgSlot = 0 THEN {} ELSE {FgSlot})
AllDone == \A p \in Participants : pc[p] = "Done"

\* After every participant has exited:
\*  - no private work and every unscanned greyed entry is in a deque (IM15);
\*  - tickets are exact (IM12, GC_DET_001);
\*  - without a stop and with budget left, everything reachable was scanned.
Postcondition ==
    AllDone =>
        /\ \A x \in Slots : pstack[x] = <<>>
        /\ {n \in Nodes : mark[n] /\ scanned[n] = 0}
               \subseteq UNION {Range(deque[x]) : x \in Slots}
        /\ uBudget = Budget0 - budget
        /\ (~stop /\ budget > 0) => \A n \in Reachable : scanned[n] = 1

AllExit == <>AllDone

\* TLC state constraint (not an invariant): stop exploring past MaxEpoch
\* reactivations. Idle markers can re-wake without bound (see §4.7).
EpochBound == word.epoch <= MaxEpoch
=============================================================================
```

### 4.6 The properties, explained

| Property | Kind | What it says | What a violation looks like |
|---|---|---|---|
| `ScanOnce` | invariant | no entry is scanned twice (IM10) | two threads end up holding the same entry, e.g. a take and a steal both win the last deque element |
| `TerminationSafe` | invariant | `done` implies the budget is exhausted, or no entry is held anywhere and nobody is active | §2.3's trace: `done` set while A is active with work and tickets |
| `Postcondition` | invariant (checked once all have exited) | no private work left (IM15); every greyed-but-unscanned node is in a deque (what 5c's relaunch and 7c's help rely on); exact tickets (IM12); without a stop and with budget left, every reachable node was scanned | an exit path that skips `publishAll`; tickets returned to the wrong pool; a node greyed but never scanned |
| `J_AssistCheck` | assertion | an assist consumed exactly the tickets it took from its pool | an assist scanning with tickets from the wrong pool |
| `J_ClosingCheck` | assertion | after the closing join and the background members' exit, the control is done | a stop during the closing join (CR-005, §6) |
| `AllExit` | liveness (`PROPERTY`) | every participant eventually exits | a participant stuck idling while work exists; a livelock |

**Why `TerminationSafe` has the `budget = 0` escape.** A 5b slice ends when its tickets run out,
and unscanned work then legitimately stays for the next slice. For drain runs (`kDrainBudget`),
`budget = 0` is unreachable at the model's sizes, so the invariant reduces to "no work left".

### 4.7 Epochs: an unbounded counter, and what its wrap would mean

With `AnyWorkCountsPriv = TRUE`, an idle marker sees another marker's `priv > 0` and reactivates.
It cannot steal private work, so it goes idle again, and repeats. Every round bumps `epoch`, so
the model's state space is infinite. The same spin exists in the real mark environment. Phase 6
removed it from the nursery environments for speed: "counting private stacks made minors 5–40×
slower on long chains", 06 plan §10.1. So:

1. **Normal configurations** add the TLC state constraint `CONSTRAINT EpochBound` (`MaxEpoch = 6`).
   TLC explores all behaviours with at most six reactivations. This bounds the search; it does not
   prove anything beyond it.
2. **The wrap configuration** (`wrap`, §6) makes the epoch wrap like a real 31-bit field shrunk to
   2 bits. Add a constant `EpochMod`, and use `(@ + 1) % EpochMod` in the two reactivation updates.
   - Expected result: TLC finds an ABA violation of `TerminationSafe`. The decider loads word `s`,
     others reactivate and idle exactly `EpochMod` times, the word returns to `s`, and the done-CAS
     succeeds wrongly.
   - That documents the protocol's real assumption: **fewer than 2^31 reactivations between one
     decider's load and its CAS**. The assumption is recorded in MAPPING.md (not a register entry,
     since 2^31 reactivations inside one decider's few instructions cannot happen).

## 5. Negative controls (mutants)

Implemented in the sketch unless marked "to add".

| `MUTANT` | Code change it represents | Configuration | Must violate | Story |
|---|---|---|---|---|
| `two_word` | separate `active` and `done` atomics (the first 5b build) | `slice` | `TerminationSafe` | §2.3 |
| `return_after_idle` | return tickets **after** `goIdle` (05b trap 3) | `slice` | `TerminationSafe` | an idle marker holds the last tickets, the decider sees `budget = 0` and decides, then the tickets come back with work left |
| `idle_before_publish` | `goIdle` before `publishAll` (05b/05c trap 5) | `minor` (`AnyWorkCountsPriv = FALSE`) | `TerminationSafe` | a worker idles with private work that is invisible to a deques-only `anyWork` |
| `idle_before_publish` | same | `slice` (`AnyWorkCountsPriv = TRUE`) | **expected to pass** | answers 05c §10.1 item 2: in the mark environment `priv` makes the private work visible, so safety holds by design there, and only there |
| `skip_exit_publish` | the IM15 negative control (`test_leave_private_on_exit_`) | `episode_stop` without closing | `Postcondition` | a stopped participant leaves private entries no later run can find |
| `steal_without_ticket` (to add) | the `c.steal_without_ticket` hook (`MarkWork.hpp:450-456`): steal first, scan unaccounted if no ticket | `slice` | `Postcondition` (`uBudget = Budget0 − budget`) | units ≠ tickets consumed (IM12) |
| `joiner_no_reactivate` (to add) | a joiner that skips `reactivate()` | `episode` | `TerminationSafe` | the decider sees `active == 0` while the joiner is scanning |
| `stop_sets_done` (to add) | a stop exit that also sets `done` | `episode_stop` | `TerminationSafe` | done with work left in the deques |
| `anywork_skips_slot` (to add) | `anyWork()` misses the last slot | `episode` | `TerminationSafe` | work in the skipped slot at decision time |

"To add" means a two-to-five-line change at the named label, in the same `IF MUTANT = ...` style.
Each mutant is a row in `models.txt` naming its configuration and the property it must violate
(parent plan §6.1).

## 6. Configurations

`MC.tla` defines the graphs and initial distributions. The quick graph is the diamond `1→{2,3}→4`
with root 1; the deep graph adds `4→5` and root 3.

| Config | Models | Key constants | Tier | Expected |
|---|---|---|---|---|
| `slice` | a 5b slice with a small budget | `BgSlots={1,2}`, `FgSlot=0`, `Budget0=3`, priv counted | quick | pass |
| `minor` | phase 6 / 7b region minor / 07b age mark | `BgSlots={1,2}`, drain, `AnyWorkCountsPriv=FALSE` | quick | pass |
| `episode` | 5c episode with one assist and a closing join | `BgSlots={2,3}`, `FgSlot=1`, `RING=1`, no stop | quick | pass |
| `episode_bgstop` | 5c episode stopped by a fork hook, no closing | as `episode`, `StopAllowed`, `DoClosing=FALSE` | quick | pass (the Postcondition is 5c's relaunch premise) |
| `episode_stop` | stop during the closing join | as `episode`, `StopAllowed`, `DoClosing=TRUE` | quick | **fails `J_ClosingCheck`: reproduces CR-005** (moves to pass when CR-005 is fixed) |
| `tenure_l3` | 7c L3 collectors that can be stopped, then help | `BgSlots={1,2}`, deques-only, `StopAllowed` | quick | pass. Then a second run over the leftover deques with fresh participants must finish the work (`tenureConcFinish`); see §8 step 6 |
| `wrap` | the epoch ABA | `slice` + `EpochMod=2` (to add) | deep | **fails `TerminationSafe`** (documents the 31-bit assumption) |
| `deep_episode` | 5c with 5 nodes, two roots, ring 2 | | deep | pass |
| `liveness_minor` | `AllExit` for the deques-only envs | `minor` + `PROPERTY AllExit` | deep | pass |

Every configuration sets `defaultInitValue = defaultInitValue` (primer §2 rule 3) and
`CONSTRAINT EpochBound`.

### 6.1 What exploration showed (earlier draft; guidance, not results)

- The `minor` configuration finished with **111,952 distinct states**.
- A 5-node episode (two background members plus a joiner, ring 2) passed **22 million** distinct
  states without finishing. That is why the quick episode uses 4 nodes and `RING = 1`, and the
  5-node one is deep.
- The first slice run never finished. That exposed the unbounded epoch of §4.7 and led to
  `EpochBound`.
- Clearing dead locals did **not** noticeably shrink the episode's state space. The size comes
  from interleavings, not stale values. Shrink by bounds.

## 7. Accuracy notes (parent plan rules A1–A9)

| Rule | M2 |
|---|---|
| A1 | Every label is one atomic operation or one owner-only change (§4.4). `anyWork()` is one slot per step (`I_Scan1`/`I_Scan2`). `publishAll` is one push per step, then `priv`. The done-CAS compares the whole saved word. |
| A2 | The state word is one record updated only by RMW-style steps (`fetch_sub`, CAS). `priv` is a count. Mark bits are per node here (byte sharing is M4's). |
| A3 | Footprint rows: 05c H10 (slot deques, private stacks, counters), H13 (`markers_[]`, `mark_slots_`), H7 (none needed: markers read no cycle state in M2). The 7c L3 slots (`tenure_workers_`) are the same shape. |
| A4 | **W1** (the deque's orders, including the release element store and acquire steal load added for TSan). **W2** (a thief's or decider's view of publish → `goIdle`). The SC model assumes both. |
| A5 | Trace validation on `gc-mark-tsan` `terminationStress` and `episodeStorm`, and on `gc-minor-tsan` (§8). |
| A6 | §5. The historical bug (`two_word`) is the first mutant. |
| A7 | `ScanOnce` = IM10, `Postcondition` parts = IM15 / IM12, `TerminationSafe` = HEAP_064 / HEAP_065 termination; `J_AssistCheck` = the assert in `assistEpisode`; `J_ClosingCheck` = the assert in `closingFinish`. |
| A8 | 2–3 participants, 4–5 nodes, `TB = 2`, `RING = 1–2`, `PUB_MIN = 2`. `EpochBound` constraint, plus the 2-bit `wrap` configuration for the counter's wrap. |
| A9 | `file`: `MarkWork.hpp` (std-only; every line is protocol). `region`: `ParallelEnv` (`OldGenSpace.cpp:3480-3510`), `publishHalf`/`publishAll`/`pushGrey` (`OldGenSpace.hpp:881-906`), `MinorEnv::anyWork`/`takeOwn` and `pushGreyP`/`publishHalfP`/`publishAllP` (`NurseryParallel.cpp:114-188`), `RegionEnv::anyWork` (`NurseryRegion.cpp:280-300`), `TenureParEnv` (`NurseryTenure.cpp:931-960`), `AgeParEnv` (`NurseryTenure.cpp:170-200`), `launchBackground`, `assistEpisode`, `closingFinish`. `census`: `OldGenSpace.cpp`, `NurseryParallel.cpp`, `NurseryTenure.cpp`. |

## 8. Trace validation

**Harnesses:** `test/gc-helper-tsan/mark_harness.cpp` (`terminationStress`, `episodeStorm`) and
`minor_harness.cpp`. Both already run the real `runMarkerLoop`.

**Hooks.** Add `ECO_TLA_TRACE(...)` calls in `MarkWork.hpp`. They compile to nothing unless
`ECO_TLA_TRACE` is defined; only the trace build of the harnesses defines it. Each event records
`{t: self, ev, ...}`:

| Event | Where (`MarkWork.hpp`) | Extra fields |
|---|---|---|
| `claim` | after a successful `claimTicket` CAS (290) | `pool`, `took`, `left` (the pool value written) |
| `take` | after `takeOwn` returns non-empty (431) | `e`, `src` (`priv`/`deque`) |
| `scan` | before `env.scan` (440) | `e` |
| `push` | in the env's `pushGrey` / `pushGreyP` | `e` |
| `publish` | per entry in `publishHalf` / `publishAll` | `e` |
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
  match, and allows unlogged owner-only steps (ring pushes, private pops) in between;
- `TraceAccepted` holds when all events are matched.

A rejected trace is either a code bug or a model error; both get recorded (parent plan §6.3).

## 9. Implementation steps

1. Create `test/tla/M2-slice-control/` with `SliceControl.tla` (§4.5), `MC.tla`, the configurations of §6, MAPPING.md (§4.4 plus A3's rows) and
   AUDIT.md.
2. `pcal` + `sany`. Then TLC on `slice`, `minor`, `episode`, `episode_bgstop`, `tenure_l3`. If a
   quick configuration exceeds about 2 minutes, reduce `RING` or the graph before anything else.
3. Run `episode_stop` and confirm it reproduces **CR-005**. Record the trace in the register entry
   (status Reproduced).
4. Add the "to add" mutants. Confirm every mutant fails with its named property and the
   `idle_before_publish`/`slice` pair passes. Record the answer to 05c trap 5.
5. Add `wrap` (`EpochMod`) and confirm the ABA trace. Write the assumption into MAPPING.md.
6. `tenure_l3` follow-on. Model 7c's help as a second phase in the same spec: after the stopped run,
   a fresh set of participants (V ≥ B slots, the old deques as `InitDeque`) runs to done, and
   `Postcondition` must then hold with every reachable node scanned. The cheap way is a constant
   `Phases = 2` and a process that starts the second run after all first-run participants are
   Done.
7. Wire into `models.txt` (tier, configuration, expected outcome per row) and `test/tla/manifest.txt`
   (A9's `file`, `region` and `census` lines).
8. Trace validation (§8): hooks, merger, trace spec. Run on `terminationStress` first, where only
   the state word and deques matter.
9. Close-out: AUDIT.md first entry; register updates (CR-005 → Reproduced); the parent plan's §11
   row.

## 10. Open questions for the implementer

1. Does `tenureConcFinish`'s help run, which uses a **new** `SliceControl` over V ≥ B slots, need
   anything from the stopped control beyond "all work is in the deques"? The code suggests not, and
   step 6 checks it.
2. The minor and tenure environments ignore `priv`. Is there any stop path in those environments
   (only 7c L3 is stoppable) where a participant exits with private work? `publishAll` on every
   exit says no. The `tenure_l3` configuration with `skip_exit_publish` should show why it matters.
