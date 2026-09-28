# Threaded GC — TLA+ model M7: PageWork (deferred decommit, commit-ahead) and the lock order

**Status:** IMPLEMENTATION-READY PLAN (2026-09-28). The PlusCal sketches in §4.6 pass the PlusCal
translator and SANY (tla2tools 1.8.0). **TLC has not run on them.** Expected results in §5 and §6
are predictions from reading the code.

**Parents:** `plans/threaded-gc-tla-verification.md` (rules A1–A9, §5.0 contracts) and
`plans/threaded-gc-tla-primer.md`. The layout follows `plans/threaded-gc-tla-M2-slice-control.md`.
M7 assumes M6's **pool contract**: a posted job is eventually run exactly once, and `wait`
returns only when the job is Done.

**Register entries:** CR-007 (a `promo_mu_` holder blocking on a helper job), CR-006 (coverage),
and CR-012 as a note (PageWork is shared by every heap).

---

## 1. Why this model, and what it checks

`PageWork` (`runtime/src/allocator/PageWork.cpp`) moves two kinds of page housekeeping off the
mutator onto the helper pool (threaded-gc-03, HEAP_059/HEAP_060):

- **Deferred decommit (U1).** When the old gen releases an extent (a range of pages), the pages are
  not given back to the OS at once (`MADV_DONTNEED`). The extent sits in the free list as
  **Pending**. If it is still unused after one major GC, a helper job **discards** it. If the
  allocator reuses it before then, the discard is cancelled and the pages are still resident, which
  saves a refault.
- **Commit-ahead (U2).** At each pause end, the range just above the old gen's allocation frontier
  (the "bump") is mapped, and a helper job **pre-faults** it (`MADV_POPULATE_WRITE`). Fresh blocks
  then arrive already backed by memory.

Because the helper runs later, on another thread, three things can go wrong, and M7 checks each at
small scale:

1. **A reused extent is discarded under its new owner.** The heap writes an object, the helper's
   `MADV_DONTNEED` then zeroes the pages, and the object reads back as zeros. That is silent heap
   corruption. HEAP_059 forbids it.
2. **A discard races a populate on the same pages.** Not corruption, but it leaves discarded pages
   resident again. HEAP_060 makes a release wait for any overlapping in-flight populate.
3. **Allocation choices depend on helper progress.** Which extent an allocation gets must depend
   only on mutator state, never on how far a helper got, or runs stop being reproducible
   (GC_DET_001).

A second small module checks the **lock chain** of a parallel minor that needs a fresh page:
- `promo_mu_` → `Allocator::thread_mutex_` → the pool's `m_` inside `wait`;
- no deadlock, and every waiter gets through (CR-007).

## 2. The protocol in plain words

### 2.1 An extent's life

| State | In the free list? | Meaning | Leaves by |
|---|---|---|---|
| owned by the heap | no | in use | `releaseOldGenBlock` → Pending |
| **Pending** | yes | released, still resident, discard not posted yet | reuse → **cancel** (resident); aged at a sync point → Posted |
| **Posted** | **yes** (so choices never depend on the job) | a Discard job for it is queued or running | reuse → **wait** for the job, then reap; job Done → reaped at a later sync point / slot take |
| free, not tracked | yes | discarded (or decommit off) | reuse (reads as zero-fill) |

Every PageWork call runs on the mutator **under `Allocator::thread_mutex_`** (HEAP_058). So PageWork
itself is single-threaded. The only concurrency is between those calls and the helper workers
running job bodies.

**Aging** (`syncPoint`, `PageWork.cpp:234-266`):
- At each pause end, the mutator bumps `sync_epoch_`, and `major_epoch_` if the pause contained a
  major (`Allocator::onGCPauseEnd`, `Allocator.cpp:1243-1262`).
- A Pending extent is aged when `major_epoch − pending.major_epoch > decommit_delay_majors`
  (default 1).
- All aged extents go into one Discard job, which is posted into one of 8 job slots (`takeSlot`
  reaps finished slots and, if all 8 are busy, waits for the oldest).

### 2.2 The rule "never discard under a new owner", as a timeline

Mutator M, helper worker W; extent X released long ago, now aged.

| # | M | W | X |
|---|---|---|---|
| 1 | sync point: X aged → Discard job J{X} posted; X stays in the free list | | Posted |
| 2 | promotion needs a page: `acquireOldGenBlock` first-fit picks X (swap-remove) | | chosen |
| 3 | `onReuse(X)`: X is Posted → `awaitSlot(J)` → **`pool.wait(J)` blocks** | takes J, runs `MADV_DONTNEED(X)` | discarded |
| 4 | | J Done, notify | |
| 5 | wakes; reaps J (X untracked); `MADV_WILLNEED`; returns X | | |
| 6 | the heap writes objects into X | | owned, data |

If step 3 did not wait (mutant `reuse_no_wait`), step 6 could come first, and W's discard would then
zero the heap's objects. The worker's body in the model asserts `owner[x] = "free"` at exactly the
moment of the `madvise`, so TLC finds that order at once.

Why the *choice* in step 2 does not look at X's state: a Posted extent stays in the free list and
first-fit may pick it. The price is a possible wait. The benefit is that the choice is the same
whether the helper has run or not, which is GC_DET_001. The model keeps a **ghost copy** of the free
list (`gFree`), updated by the same mutator operations but never reading PageWork state, and checks
`freeList = gFree` in every state (`DetChoice`). The mutant `skip_posted_extents` ("skip extents
whose discard is still posted", an optimisation someone might plausibly add) breaks it.

### 2.3 Commit-ahead and the release wait

- `topUpWindow` (`PageWork.cpp:210-232`) commits `[max(window_end, bump), target)` on the mutator
  and posts a Populate job over it.
- A fresh bump allocation inside the window **does not wait** for the populate (`onFreshBump`,
  171-187). Populate never changes a page's contents, so the mutator may write while it runs
  (HEAP_060; plan 03 P§3.7).
- The one ordering prevented: an extent acquired from the window, used, and **released** while its
  populate is still running. Its later discard could race the populate and leave the pages
  resident. So `onRelease` first waits for any in-flight populate that overlaps it
  (`awaitPopulateOverlapping`, 127-133).

With the default single pool worker, jobs run in FIFO order, so a populate posted earlier always
finishes before a later discard starts, and the wait is belt-and-braces. With
`gc_helper_threads > 1` the two can run at once. The model uses two workers to make that case
reachable.

### 2.4 The lock chain (CR-007), as a timeline

A parallel minor. G1 is a gang thread, G0 the mutator (also a gang member), W a pool worker.

| # | G1 | G0 | W |
|---|---|---|---|
| 1 | `allocatePromotion` → lock `promo_mu_` (`OldGenSpace.cpp:1587`) | | |
| 2 | ladder → `startVirginBlockShared` (1249) → `ensureBagPageAvailable` (866) → `acquireOldGenBlock` → **lock `thread_mutex_`** (`Allocator.cpp:753`) | | |
| 3 | first-fit picks a Posted extent → `onReuse` → `pool.wait(J)` → **blocks, holding `promo_mu_` and `thread_mutex_`** | wants `promo_mu_`: spins 256 rounds, yields 256, then sleeps 10 µs per round (`MinorWork.hpp:91-107`) | runs J (takes only the pool's `m_`) |
| 4 | | | J Done, notify |
| 5 | wakes, returns the extent, unlocks both | gets `promo_mu_` | |

There is no cycle: W takes neither `promo_mu_` nor `thread_mutex_` (HEAP_058: "workers never take
`thread_mutex_`"). So this is a **stall**, not a deadlock.

A side effect: `callerInPause()` (`Allocator.cpp:1206`) reads the calling thread's `tl_heap_`,
which is null on gang threads, so G1's stall is counted as "outside a pause". That is stats only.

The model checks the chain for deadlock and starvation. Its mutants show what would deadlock:
- a path that takes `thread_mutex_` before `promo_mu_`;
- a job body that takes `thread_mutex_`.

The 7c tenure collector never enters this chain. It allocates only from its grant, chosen in the
pause (07 plan P§3.17 rows T6/T10).

## 3. The code the model covers

| Code | Lines (2026-09-28, post-7c) | Model element |
|---|---|---|
| `PageWork::onRelease` | `PageWork.cpp:135-149` | `M_Choose` (release branch), `M_RelWait`, `M_RelPend` |
| `PageWork::awaitPopulateOverlapping` | 127-133 | `M_RelWait` loop |
| `PageWork::onReuse` | 151-169 | `M_Reuse` |
| `PageWork::onFreshBump` | 171-187 | the fresh-acquire branch |
| `PageWork::syncPoint` (reap, age, post, top up) | 234-266 | the sync branch: `M_Age`, `M_Take`, `M_Post`, `M_Window`, `M_TakeP`, `M_PostP` |
| `postDiscardBatch`, `topUpWindow` | 189-232 | `M_Post`, `M_PostP` |
| `takeSlot`, `reapDone`, `reap`, `awaitSlot` | 76-125 | procedures `TakeSlot`, `AwaitSlot`; macros `Reap`, `ReapAllDone` |
| `PageWork::runJob` (the job bodies) | 50-63 | process `Worker`, `W_Body` |
| `Allocator::acquireOldGenBlock` (first-fit, swap-remove, `onReuse`, V1, V4, `MADV_WILLNEED`) | `Allocator.cpp:752-886` (onReuse 792, V1 794, V4 806) | the reuse branch, `M_Touch` |
| `Allocator::releaseOldGenBlock` | 891-939 (onRelease 901) | the release branch |
| `Allocator::onGCPauseEnd` (epochs, `syncPoint`) | 1243-1262 | the sync branch |
| `Allocator::validatePageWork` (V2a, V2b, V3) | 1272-1315 | `TrackedInFree`, `NoOwnedPosted` |
| `OldGenSpace::allocatePromotion` → `startVirginBlockShared` → `ensureBagPageAvailable` | `OldGenSpace.cpp:1536-1600, 1249, 866-882` | `LockOrder.tla`: `P_Promo`, `P_Tm`, `P_Reuse` |
| `minorwork::SpinMutex` | `MinorWork.hpp:85-113` | `promo` |

**Outside M7:**
- the pool's internals (M6a);
- which blocks the old gen releases, and when (OldGenSpace policy);
- partial overlaps of a bump request with the window's end. The model works in whole extents. The
  window's 2 MiB granule and `alloc_buffer_size` blocks make a straddle possible in the code, but
  `onFreshBump` only splits the commit and never waits, so a straddle adds no new interleaving.

## 4. The model

### 4.1 Two modules

- **`PageWork.tla` (M7a)**: extents, the free list, PageWork tracking, job slots, the mutator's
  four operations (release, reuse, fresh acquire, sync point), and pool workers running bodies.
- **`LockOrder.tla` (M7b)**: gang members, `promo_mu_`, a recursive `thread_mutex_`, one posted
  discard job and a worker.

### 4.2 Abstractions

| Real thing | Model | Why sound |
|---|---|---|
| Extents of varied sizes; first-fit by size | all extents one size; first-fit = index 1; the exact swap-remove | page requests are all `alloc_buffer_size`; large extents only add "skip too-small entries", which reads no PageWork state |
| 8 job slots, "wait for the oldest" | 2 slots, "wait for any busy slot" | a superset of the real choices (over-approximation) |
| 1..64 pool workers | 1 or 2 workers | 2 makes the populate/discard race reachable |
| `thread_mutex_` around every PageWork call | implicit: one mutator makes every call; worker steps interleave between the mutator's steps | faithful for one heap. **Several heaps share one PageWork** (CR-012): modelling that would need an explicit `tm` and two mutators, which is a deep configuration if CR-012 is ever accepted |
| `delay_syncs` (default never), `pending_cap` (default 0) | only `DelayMajors` | the defaults. The others only post *more* discards, which the aging choice already over-approximates |
| Page contents | `content[x] \in {"data","zero","none"}` | enough to state "the heap's data is never zeroed" |
| `MADV_POPULATE_WRITE` | a body step with no effect | content-neutral by definition |
| The pool | M6's contract: `Posted → Running → Done`, run once, fair workers | checked in M6a |

### 4.3 Constants

| Constant | Module | Meaning | Values |
|---|---|---|---|
| `Extents`, `InitHeap`, `InitFresh` | M7a | extents; those owned at start (below bump); those above bump (window range) | `{1,2,3}`, `{1,2}`, `{3}` |
| `Slots` | M7a | job slots | `{1,2}` |
| `Workers` | M7a | pool workers | `{"w1"}` or `{"w1","w2"}` |
| `DelayMajors` | M7a | `decommit_delay_majors` | 0 (fast aging, for mutants) or 1 (default) |
| `MaxOps`, `MaxMajors` | M7a | bounds | 5–6, 3 |
| `Members` | M7b | gang members | `{"mut","g1"}` |
| `MUTANT` | both | §5 | |

### 4.4 Variables (M7a)

| Variable | Code counterpart |
|---|---|
| `owner[x]` | heap-owned / free / above the bump (`fresh`) |
| `content[x]` | the pages' contents |
| `freeList` | `Allocator::old_gen_free_blocks_` |
| `gFree` | ghost: the free list as a job-blind allocator would keep it (GC_DET_001) |
| `pw[x]`, `pendMajor[x]`, `postedIn[x]` | `PageWork::pending_` / `posted_discard_` entries |
| `sstate[s]`, `skind[s]`, `sext[s]` | `slots_[s]`: job state, kind, extents or populate range |
| `covered` | extents ever inside a populate window (`window_end_`) |
| `majors` | `major_epoch_` |
| `takenSlot` | `takeSlot`'s return value |

M7b's variables are the lock holders (`promo`, `tmOwner` with `tmDepth`), the pool's `m`, the job
state, `reused` (the posted extent was handed out once), and `waiting` (blocked in `wait`).

### 4.5 Labels to code

| Label | Code | Step |
|---|---|---|
| `M_Choose` (release) | `Allocator.cpp:891-901` | pick an owned extent; compute the overlapping populates |
| `M_RelWait` | `PageWork.cpp:127-133` | wait for one overlapping populate, reap it; loop |
| `M_RelPend` | 135-149 | Pending; append to the free list (and the ghost) |
| `M_Choose` (reuse) | `Allocator.cpp:776-790` | first-fit + swap-remove (the ghost does the same) |
| `M_Reuse` | `PageWork.cpp:151-169` | cancel Pending, or wait for Posted |
| `M_Touch` | `Allocator.cpp:794-815` | V1 assert; the heap owns and writes it |
| fresh branch | `PageWork.cpp:171-187` | bump acquire, no wait |
| `M_Age` | 238-257 | age by majors |
| `M_Take`/`M_Post` | 113-125, 189-208 | take a slot; post the Discard job |
| `M_Window`/`M_TakeP`/`M_PostP` | 210-232 | top up the window; post a Populate |
| `AS_Wait` | 103-111 | `pool.wait` then `reap` |
| `TS_*` | 113-125 | `takeSlot` |
| `W_Take`, `W_Body`, `W_Done` | `GCHelperPool.cpp:203-221`, `PageWork.cpp:50-63` | dequeue; one `madvise` per extent; Done |
| `P_Promo` | `OldGenSpace.cpp:1587-1596` | `promo_mu_` |
| `P_Tm` | `Allocator.cpp:753` | `thread_mutex_` (recursive) |
| `P_Reuse`, `PW_*` | `Allocator.cpp:792`, `PageWork.cpp:160`, `GCHelperPool.cpp:236-252` | onReuse → wait |

### 4.6 The PlusCal sketches

Files: `test/tla/M7-pagework/PageWork.tla` and `LockOrder.tla`. This is the text that passed the
translator; the translations are omitted.

**M7a — PageWork.tla**

```tla
------------------------------ MODULE PageWork ------------------------------
(***************************************************************************)
(* M7a: PageWork (runtime/src/allocator/PageWork.cpp): deferred decommit   *)
(* (Pending -> Posted discard -> reaped; a reuse cancels or waits) and     *)
(* commit-ahead (populate jobs; a release waits for an overlapping one),   *)
(* driven by one mutator under Allocator::thread_mutex_, with the jobs run *)
(* on helper-pool workers. The pool is M6a's contract: a posted job is     *)
(* eventually run once; wait returns only when it is Done.                 *)
(***************************************************************************)
EXTENDS Naturals, Sequences, FiniteSets, TLC

CONSTANTS
    Extents,         \* old-gen extents of one size (alloc_buffer_size)
    InitHeap,        \* extents the heap owns at the start (below the bump)
    InitFresh,       \* extents above the bump (the commit-ahead window's range)
    Slots,           \* PageWork::slots_ (kJobSlots = 8 in code)
    Workers,         \* pool workers (gc_helper_threads, default 1)
    DelayMajors,     \* decommit_delay_majors (default 1)
    MaxOps,          \* bound on mutator operations
    MaxMajors,       \* bound on major epochs
    MUTANT           \* "none", "reuse_no_wait", "release_no_await_populate",
                     \* "skip_posted_extents"

TruncLast(sq) == SubSeq(sq, 1, Len(sq) - 1)
Range(sq) == {sq[i] : i \in 1..Len(sq)}
\* old_gen_free_blocks_' swap-remove: *it = back(); pop_back().
RemoveAt(sq, i) == IF i = Len(sq) THEN TruncLast(sq)
                   ELSE TruncLast([sq EXCEPT ![i] = sq[Len(sq)]])
\* The mutant's choice: the first extent whose discard is not Posted.
FirstNotPosted(sq, st) ==
    CHOOSE i \in 1..Len(sq) : st[sq[i]] # "Posted" /\ \A k \in 1..(i - 1) : st[sq[k]] = "Posted"

(* --algorithm PageWork
variables
    owner     = [e \in Extents |-> IF e \in InitHeap THEN "heap"
                                   ELSE IF e \in InitFresh THEN "fresh" ELSE "free"],
    content   = [e \in Extents |-> IF e \in InitHeap THEN "data" ELSE "none"],
    freeList  = <<>>,                       \* old_gen_free_blocks_
    gFree     = <<>>,                       \* ghost: the same list, job-blind (GC_DET_001)
    pw        = [e \in Extents |-> "none"], \* PageWork tracking: none / Pending / Posted
    pendMajor = [e \in Extents |-> 0],      \* Pending::major_epoch
    postedIn  = [e \in Extents |-> 0],      \* Posted::slot
    sstate    = [s \in Slots |-> "Idle"],   \* HelperJob::state of PageJob s
    skind     = [s \in Slots |-> "None"],   \* Discard / Populate
    sext      = [s \in Slots |-> {}],       \* extents (discard) or covered range (populate)
    covered   = {},                         \* extents ever inside a populate window
    majors    = 0,                          \* major_epoch at the sync points
    takenSlot = 0;                          \* TakeSlot's result

define
    PopulateInFlightOver(e) ==
        \E s \in Slots : skind[s] = "Populate" /\ sstate[s] \in {"Posted", "Running"}
                         /\ e \in sext[s]
    \* HEAP_059: nothing the heap owns is ever discarded (checked also as an
    \* assert at the discard body). Stated as a state invariant too:
    NoOwnedPosted == \A x \in Extents : owner[x] = "heap" => pw[x] = "none"
    \* GC_DET_001: the free list (hence every acquire's choice) never depends
    \* on helper progress: it equals its job-blind ghost.
    DetChoice == freeList = gFree
end define;

\* PageWork::reap(s): observed Done; forget the posted extents; slot Idle.
macro Reap(s) begin
    pw := [x \in Extents |-> IF skind[s] = "Discard" /\ x \in sext[s] /\ pw[x] = "Posted"
                                /\ postedIn[x] = s THEN "none" ELSE pw[x]];
    skind[s] := "None";
    sext[s] := {};
    sstate[s] := "Idle";
end macro;

\* PageWork::reapDone(): reap every Done slot.
macro ReapAllDone() begin
    pw := [x \in Extents |-> IF \E s \in Slots : sstate[s] = "Done" /\ skind[s] = "Discard"
                                   /\ x \in sext[s] /\ postedIn[x] = s /\ pw[x] = "Posted"
                              THEN "none" ELSE pw[x]];
    skind  := [s \in Slots |-> IF sstate[s] = "Done" THEN "None" ELSE skind[s]];
    sext   := [s \in Slots |-> IF sstate[s] = "Done" THEN {} ELSE sext[s]];
    sstate := [s \in Slots |-> IF sstate[s] = "Done" THEN "Idle" ELSE sstate[s]];
end macro;

\* awaitSlot(s): pool.wait(s) (returns when Done), then reap.
procedure AwaitSlot(as)
begin
  AS_Wait:
    await sstate[as] \in {"Idle", "Done"};
    if sstate[as] = "Done" then Reap(as); end if;
    return;
end procedure;

\* takeSlot: reapDone, then an Idle slot, else wait for the oldest (any here).
procedure TakeSlot()
variables ts = 0;
begin
  TS_ReapDone:
    ReapAllDone();
    if \E s \in Slots : sstate[s] = "Idle" then
        takenSlot := CHOOSE s \in Slots : sstate[s] = "Idle";
        return;
    end if;
  TS_Oldest:
    with s \in Slots do ts := s; end with;
  TS_Wait:
    call AwaitSlot(ts);
  TS_Got:
    takenSlot := ts;                     \* (return resets the local ts)
    return;
end procedure;

\* The mutator: each operation is one PageWork call under thread_mutex_.
fair process Mutator = "mut"
variables n = 0, ext = 0, rs = {}, rsel = 0, batch = {};
begin
  M_Loop:
    while n < MaxOps do
      M_Choose:
        either                                            \* releaseOldGenBlock(ext)
            await \E x \in Extents : owner[x] = "heap";
            with x \in {y \in Extents : owner[y] = "heap"} do ext := x; end with;
            rs := {s \in Slots : skind[s] = "Populate" /\ sstate[s] # "Idle" /\ ext \in sext[s]};
          M_RelWait:                                      \* awaitPopulateOverlapping
            if MUTANT # "release_no_await_populate" /\ rs # {} then
                rsel := CHOOSE s \in rs : TRUE;
                rs := rs \ {rsel};
                call AwaitSlot(rsel);
                goto M_RelWait;
            end if;
          M_RelPend:                                      \* onRelease: Pending, free list
            owner[ext] := "free";
            content[ext] := "none";
            pw[ext] := "Pending";
            pendMajor[ext] := majors;
            freeList := Append(freeList, ext);
            gFree := Append(gFree, ext);
            ext := 0; rs := {};
        or                                                \* acquireOldGenBlock: reuse
            await freeList # <<>>;
            if MUTANT = "skip_posted_extents" /\ \E i \in 1..Len(freeList) : pw[freeList[i]] # "Posted" then
                ext := freeList[FirstNotPosted(freeList, pw)];
                freeList := RemoveAt(freeList, FirstNotPosted(freeList, pw));
            else
                ext := freeList[1];                         \* first fit (all extents one size)
                freeList := RemoveAt(freeList, 1);
            end if;
            gFree := RemoveAt(gFree, 1);                  \* the job-blind choice
          M_Reuse:                                        \* onReuse (BEFORE any touch)
            if pw[ext] = "Pending" then
                pw[ext] := "none";                          \* Cancelled: still resident
            elsif pw[ext] = "Posted" then
                if MUTANT = "reuse_no_wait" then
                    pw[ext] := "none";
                else
                    call AwaitSlot(postedIn[ext]);          \* AfterDiscard
                end if;
            end if;
          M_Touch:                                        \* V1, then the heap writes it
            assert pw[ext] = "none";
            owner[ext] := "heap";
            content[ext] := "data";
            ext := 0;
        or                                                \* acquireOldGenBlock: fresh bump
            await \E x \in Extents : owner[x] = "fresh";
            with x \in {y \in Extents : owner[y] = "fresh"} do
                owner[x] := "heap";                       \* onFreshBump: never waits
                content[x] := "data";                     \* populate is content-neutral
            end with;
        or                                                \* onGCPauseEnd -> syncPoint
            await majors < MaxMajors;
            with hadMajor \in BOOLEAN do
                if hadMajor then majors := majors + 1; end if;
            end with;
          M_Age:                                          \* (b) age by majors
            batch := {x \in Extents : pw[x] = "Pending" /\ majors - pendMajor[x] > DelayMajors};
            if batch # {} then
              M_Take:
                call TakeSlot();
              M_Post:                                     \* (c) one Discard job
                skind[takenSlot] := "Discard";
                sext[takenSlot] := batch;
                pw := [x \in Extents |-> IF x \in batch THEN "Posted" ELSE pw[x]];
                postedIn := [x \in Extents |-> IF x \in batch THEN takenSlot ELSE postedIn[x]];
                sstate[takenSlot] := "Posted";
            end if;
          M_Window:                                       \* (d) topUpWindow
            if \E x \in Extents : owner[x] = "fresh" /\ x \notin covered then
              M_TakeP:
                call TakeSlot();
              M_PostP:
                skind[takenSlot] := "Populate";
                sext[takenSlot] := {x \in Extents : owner[x] = "fresh" /\ x \notin covered};
                covered := covered \cup {x \in Extents : owner[x] = "fresh"};
                sstate[takenSlot] := "Posted";
            end if;
          M_SyncDone:
            batch := {};
        end either;
      M_Next:
        n := n + 1;
    end while;
end process;

\* Pool workers run job bodies (M6a's contract: each posted job runs once).
fair process Worker \in Workers
variables cur = 0, todo = {};
begin
  W_Loop:
    while TRUE do
      W_Take:
        await \E s \in Slots : sstate[s] = "Posted";
        with s \in {x \in Slots : sstate[x] = "Posted"} do
            cur := s;
            sstate[s] := "Running";
            todo := sext[s];
        end with;
      W_Body:                                             \* one madvise per extent
        while todo # {} do
            with x \in todo do
                if skind[cur] = "Discard" then
                    assert owner[x] = "free";             \* HEAP_059: never under an owner
                    assert ~PopulateInFlightOver(x);      \* HEAP_060's purpose
                    content[x] := "zero";
                end if;                                   \* Populate: content-neutral
                todo := todo \ {x};
            end with;
        end while;
      W_Done:
        sstate[cur] := "Done";
        cur := 0;
    end while;
end process;

end algorithm; *)
\* BEGIN TRANSLATION  (generated by pcal; not shown)
\* END TRANSLATION

-----------------------------------------------------------------------------
\* V2a: every tracked extent is in the free list, except the one an acquire has
\* just swap-removed and is passing to onReuse (the same thread_mutex_ section
\* in the code; two steps here).
TrackedInFree == \A x \in Extents : pw[x] # "none" => (x \in Range(freeList) \/ x = ext)

\* Liveness: the mutator's waits all return (worker fairness).
MutatorFinishes == <>(pc["mut"] = "Done")
=============================================================================
```

**M7b — LockOrder.tla**

```tla
------------------------------ MODULE LockOrder ------------------------------
(***************************************************************************)
(* M7b: the lock chain of a parallel minor whose promotion needs a fresh   *)
(* old-gen page (CR-007):                                                  *)
(*   promo_mu_ (minorwork::SpinMutex)                                      *)
(*     -> Allocator::thread_mutex_ (std::recursive_mutex, acquireOldGenBlock)*)
(*       -> GCHelperPool::m_ inside wait() (PageWork::onReuse on a Posted  *)
(*          discard).                                                      *)
(* Pool workers take only m_. The mutator is gang member "mut".            *)
(***************************************************************************)
EXTENDS Naturals, Sequences, FiniteSets, TLC

CONSTANTS
    Members,         \* parallel-minor gang members, including "mut" (worker 0)
    MUTANT           \* "none", "tm_then_promo", "worker_takes_tm"

(* --algorithm LockOrder
variables
    promo   = "none",            \* promo_mu_ holder
    tmOwner = "none",            \* thread_mutex_ owner (recursive: depth below)
    tmDepth = 0,
    m       = "none",            \* the pool's m_ (held only inside short steps here)
    job     = "Posted",          \* the discard job posted on the extent being reused
    reused  = FALSE,             \* the posted extent was handed out (once)
    waiting = {};                \* blocked in cv_done_.wait

define
    TmFree(p) == tmOwner \in {"none", p}
end define;

\* pool.wait(job): lock m_, check Done, block (releases m_), re-check on wake.
procedure PoolWait()
begin
  PW_Lock:
    await m = "none";
    if job = "Done" then return;
    else waiting := waiting \cup {self};
    end if;
  PW_Blocked:
    await self \notin waiting;
    goto PW_Lock;
end procedure;

\* allocatePromotion -> ladder -> startVirginBlockShared -> ensureBagPageAvailable
\* -> Allocator::acquireOldGenBlock (under promo_mu_).
fair process Member \in Members
begin
  P_First:
    if MUTANT = "tm_then_promo" /\ self = "mut" then   \* a path taking the locks in reverse
        await TmFree(self);
        tmOwner := self; tmDepth := tmDepth + 1;
      P_ThenPromo:
        await promo = "none";
        promo := self;
        goto P_Release;
    end if;
  P_Promo:                                              \* SpinMutex::lock (spin/yield/sleep)
    await promo = "none";
    promo := self;
  P_Tm:                                                 \* lock_guard<recursive_mutex>
    await TmFree(self);
    tmOwner := self;
    tmDepth := tmDepth + 1;
  P_Pick:                                               \* first-fit: the posted extent, once
    if ~reused then
        reused := TRUE;
      P_Reuse:                                          \* onReuse: Posted -> awaitSlot -> wait
        if job # "Done" then call PoolWait(); end if;
    end if;
  P_Release:
    tmDepth := tmDepth - 1;                             \* ~lock_guard (recursive depth)
    if tmDepth = 0 then tmOwner := "none"; end if;
  P_Unpromo:
    promo := "none";
end process;

\* A pool worker running the posted discard job (M6a's workerLoop).
fair process Worker = "w1"
begin
  W_Take:
    await m = "none" /\ job = "Posted";
    job := "Running";
  W_Body:                                               \* madvise: no allocator lock ...
    if MUTANT = "worker_takes_tm" then                  \* ... unless a job calls back in
        await tmOwner = "none";
        tmOwner := "w1"; tmDepth := 1;
      W_BodyRel:
        tmOwner := "none"; tmDepth := 0;
    end if;
  W_Done:
    await m = "none";
    job := "Done";
  W_Notify:
    waiting := {};
end process;

end algorithm; *)
\* BEGIN TRANSLATION  (generated by pcal; not shown)
\* END TRANSLATION

-----------------------------------------------------------------------------
\* Liveness: every member finishes its promotion (no starvation behind the
\* spin lock while the holder waits for the helper).
AllFinish == <>(\A p \in Members \cup {"w1"} : pc[p] = "Done")
=============================================================================
```

### 4.7 Properties

| Property | Module | Kind | Meaning | Expected |
|---|---|---|---|---|
| `W_Body`: `assert owner[x] = "free"` | M7a | assertion at the `madvise` | **HEAP_059**: nothing the heap owns is discarded | holds; fails under `reuse_no_wait` |
| `W_Body`: `assert ~PopulateInFlightOver(x)` | M7a | assertion | HEAP_060's purpose: no discard races a populate | holds; fails under `release_no_await_populate` (two workers) |
| `M_Touch`: `assert pw[ext] = "none"` | M7a | assertion | V1: the extent handed out is untracked | holds |
| `NoOwnedPosted` | M7a | invariant | no owned extent is Pending/Posted | holds |
| `TrackedInFree` | M7a | invariant | V2a: tracked extents are in the free list (except the one in `onReuse`) | holds |
| `DetChoice` | M7a | invariant | GC_DET_001: the free list equals its job-blind ghost | holds; fails under `skip_posted_extents` |
| `MutatorFinishes` | M7a | liveness | every wait returns | holds (fair workers) |
| deadlock | M7b | TLC's default check (the translation's `Terminating` makes finished runs legal) | the lock chain cannot deadlock | holds; fails under `tm_then_promo`, `worker_takes_tm` |
| `AllFinish` | M7b | liveness | every member finishes | holds |

For M7a, configurations set `CHECK_DEADLOCK FALSE`: workers loop forever, and the translation's
`Terminating` does not cover them. `MutatorFinishes` covers progress instead.

## 5. Negative controls

| `MUTANT` | Code change | Configuration | Must violate |
|---|---|---|---|
| `reuse_no_wait` | `onReuse` of a Posted extent returns without `awaitSlot` | `pw_basic` (`DelayMajors = 0`) | `W_Body` HEAP_059 assert |
| `release_no_await_populate` | `onRelease` skips `awaitPopulateOverlapping` | `pw_two_workers` | `W_Body` populate assert |
| `skip_posted_extents` | first-fit skips extents whose discard is Posted | `pw_basic` | `DetChoice` |
| `tm_then_promo` | a path taking `thread_mutex_` before `promo_mu_` | `lock_order` | deadlock |
| `worker_takes_tm` | a job body calls into the allocator | `lock_order` | deadlock |
| `discard_before_age` (to add) | post a discard at release time (no aging) | `pw_basic` | none of the safety properties: a **policy** change. Kept as a *positive* control that `reuse_no_wait` is the real hazard, not early discards |

"Decommit delay counted in pause ends" is not a mutant: it changes *when* discards are posted,
never whether one can run under an owner (the reuse wait covers every timing). Plan 03 rejected it
on cost.

## 6. Configurations

| Config | Module | Key constants | Expected |
|---|---|---|---|
| `pw_basic` | M7a | 3 extents (`{1,2}` owned, `{3}` fresh), 2 slots, 1 worker, `DelayMajors = 0`, `MaxOps = 5` | pass |
| `pw_default_delay` | M7a | as `pw_basic`, `DelayMajors = 1`, `MaxMajors = 3` | pass |
| `pw_two_workers` | M7a | 2 workers | pass |
| `lock_order` | M7b | `Members = {"mut","g1"}` | pass |
| `pw_deep` | M7a (deep) | 4 extents, 3 slots, 2 workers, `MaxOps = 7` | pass |
| mutants | as §5 | | fail as listed |

## 7. Accuracy notes (rules A1–A9)

| Rule | M7 |
|---|---|
| A1 | PageWork calls are serialised by `thread_mutex_`, so each call body is one step, split only where it **waits**: a wait is where a worker can interleave, and the model puts a label there (`M_RelWait`, `M_Reuse` → `AS_Wait`, `TS_Wait`). The reuse is split between the choice and `onReuse` to state V2's exception honestly. One `madvise` per extent is one worker step. |
| A2 | Extents are the unit (both the madvise unit and the free-list unit). No sub-extent sharing. |
| A3 | Footprint: 07 plan T10 (helper jobs never target a granted block), plan 03 P§3.6-3.7, HEAP_058 (workers take no allocator lock), V1–V3. |
| A4 | None. Every handoff is the pool mutex (M6), and the job's `failures` field is read after Done (acquire). |
| A5 | `gc-helper-tsan` `harness.cpp` H2 (PageWork over fake ops, with a lock standing in for `thread_mutex_`; the fake discard already checks "the extent is free before and after a yield") and H3 (real `mmap`, per-page patterns). §8. |
| A6 | §5. |
| A7 | HEAP_058, HEAP_059, HEAP_060, GC_DET_001, V1, V2a/b, V3. V4 (poison on resident reuse), V5 (drained at reset) and V6 (mode 0 inert) are runtime-only and outside the model. |
| A8 | 3–4 extents, 2–3 slots, 1–2 workers, 3 majors. |
| A9 | `file`: `PageWork.cpp`, `PageWork.hpp`. `region`: `Allocator::acquireOldGenBlock`, `releaseOldGenBlock`, `onGCPauseEnd`, `rebuildPageWork`; `OldGenSpace::ensureBagPageAvailable`, `startVirginBlockShared`, `allocatePromotion`'s lock section. `census`: `Allocator.cpp`, `MinorWork.hpp` (`SpinMutex`). `grep`: `promo_mu_`, `thread_mutex_`. |

## 8. Trace validation

- **Harness:** `test/gc-helper-tsan/harness.cpp`.
  - H2 already drives PageWork from a random script under a lock, with fake page ops. Log from the
    script and the fake ops.
  - H3 uses real `mmap`/`madvise`, and its per-page patterns detect a discard under an owner
    directly. Its log is the same.
- **Events:**

  | Event | Where | Fields |
  |---|---|---|
  | `release` | `onRelease` | extent, waited slots |
  | `reuse` | `onReuse` | extent, result (`Cancelled`/`AfterDiscard`/`NeverDiscarded`) |
  | `fresh` | `onFreshBump` | extent, bytes to commit |
  | `sync` | `syncPoint` | epoch, major epoch, aged extents |
  | `post` | `postDiscardBatch`, `topUpWindow` | slot, kind, extents / range |
  | `body` | the fake `discard` / `populate` ops | slot, extent |
  | `done`, `reap` | worker completion, `reap` | slot |

- **Ordering:** every mutator event happens under the script's lock, so the log order is total.
  Worker events are ordered against it by the pool mutex (M6's per-mutex counter).
- **The trace spec** matches `release`/`reuse`/`sync`/`post` to the mutator's branches and `body`
  to `W_Body`. A `body` on an extent the trace shows as owned is rejected by the model's assertion,
  which is exactly H3's pattern check, stated formally.

## 9. Implementation steps

1. Create `test/tla/M7-pagework/` with both modules (§4.6), `MC.tla`, the §6 configurations,
   MAPPING.md (§4.5 plus A3) and AUDIT.md.
2. `pcal` + `sany`, then TLC on `pw_basic`, `pw_default_delay`, `pw_two_workers`, `lock_order`.
3. Run each §5 mutant; confirm the named failure.
4. Deep configuration.
5. Wire into `models.txt` / `manifest.txt` (A9).
6. Register: CR-007. Once `lock_order` passes and the mutants deadlock, move CR-007 to
   **Not-a-bug (stall, not deadlock)**, keeping the stats note. Record separately whether the stall
   matters: that is measurement, "GC-pressure stress with `gc_thread_mode = 2`" (CR-006 adds that
   arm to `gc-heap-tsan`).
7. Trace validation (§8) on H2, then H3.

## 10. Open questions

1. **Several heaps, one PageWork.** Every heap's pause end calls `syncPoint` on the one process-wide
   `PageWork` with the process-wide epochs (CR-012). If multiple mutators are ever supported, M7a
   needs an explicit `thread_mutex_` and a second mutator, and `DetChoice` becomes per-heap.
2. **Can `releaseOldGenBlock` ever run inside a parallel minor**, under `promo_mu_` on a gang
   thread? If so, a release could wait on a populate while holding `promo_mu_`: the same stall
   shape, with a different job. Partial audit (2026-09-28):
   - the only callers are `releaseBlockToAllocator` (`OldGenSpace.cpp:5995`, which asserts
     `!cycleActive()`) and `releaseUnassignedBlockToAllocator` (6135);
   - with more than one worker, `lazySweep`'s end-of-sweep shrink is deferred to the merge
     (`sweepCompleteInPromotion`, 1361), which is the obvious route.

   Finish the audit (every caller chain versus `par_promo_active_`) before finalising
   `LockOrder.tla`'s member steps. If a route exists, add a release step to `Member`.
