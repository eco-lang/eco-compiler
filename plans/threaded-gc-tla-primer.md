# Threaded GC — TLA+ modelling primer

**Status:** REFERENCE (2026-09-28). Read this before any model plan.

**Parent:** `plans/threaded-gc-tla-verification.md`. That plan says *what* gets modelled and why. The
model plans (`plans/threaded-gc-tla-M*.md`) say *how* each model is built. This primer explains the
ideas they all assume:
- what TLA+ and PlusCal are;
- how a C++ atomic, a lock or a plain read-modify-write becomes a model step;
- how to keep a model small enough to check;
- how to prove a model has teeth;
- how a model is checked against the running code.

It ends with a glossary of the GC terms the model plans use.

Every example here was run through the real tools (tla2tools 1.8.0 build 2026.09.25, the version
the dev image pins). The outputs quoted are real.

---

## 1. TLA+ in one page

A **model** (or **spec**) describes a system as:
- a set of **variables**;
- a starting condition (`Init`);
- a set of possible **steps** (`Next`).

A **state** is one value for every variable. A **behaviour** is a sequence of states, where each
state follows from the previous one by one step.

The model checker, **TLC**, starts from every initial state and tries every enabled step in every
reachable state. That exhausts every possible interleaving of the threads, up to the size limits
you give it. Testing runs the interleavings the scheduler happens to pick; TLC runs all of them.

Three ideas matter more than any syntax:

1. **A step is atomic.** Everything inside one step happens at once, with no other thread in
   between. So **a model step must correspond to something the real code does atomically**: one
   CAS, one `fetch_or`, one release store, or one whole critical section under a lock. If you put
   two real operations into one step, the model cannot see the interleaving between them, and a
   bug that lives there becomes invisible. This is the single most common way a model lies (rule
   A1 in the parent plan).
2. **An invariant** is a formula that must hold in *every* reachable state. For example, "no
   object is scanned twice". If some interleaving breaks it, TLC stops and prints that
   interleaving step by step. That printout is called a **counterexample** or **trace**.
3. **A liveness property** says something *eventually* happens, such as "every marker eventually
   exits". Liveness needs **fairness**. Without it, TLC may consider a behaviour where a thread
   simply never runs again, and then nothing ever happens. `fair process` in PlusCal says "if this
   thread can keep taking steps, it eventually does".

### A complete example: the lost mark bit

Two threads each set a different bit in one mark byte. With a plain `b |= mask` the compiler emits
a load and a store. With `fetch_or` it is one atomic read-modify-write. Here is the whole model,
written in PlusCal (§2):

```tla
------------------------------ MODULE LostBit ------------------------------
EXTENDS Naturals
CONSTANT Plain
(* --algorithm LostBit
variables byte = {};                  \* the set of bits that are 1
process T \in {1, 2}
variables tmp = {};
begin
  Load:
    if Plain then
        tmp := byte;                  \* uint8_t v = b;
      Store:
        byte := tmp \cup {self};      \* b = v | mask;
    else
        byte := byte \cup {self};     \* fetch_or(mask): one atomic step
    end if;
end process;
end algorithm; *)
BothBitsSet == (\A t \in {1, 2} : pc[t] = "Done") => byte = {1, 2}
=============================================================================
```

With `Plain = TRUE`, TLC reports (trimmed):

```
Error: Invariant BothBitsSet is violated.
State 1: byte = {}   pc = <<"Load", "Load">>
State 2: <Load(1)>   byte = {}   pc = <<"Store", "Load">>
State 3: <Load(2)>   byte = {}   pc = <<"Store", "Store">>
State 4: <Store(1)>  byte = {1}  pc = <<"Done", "Store">>
State 5: <Store(2)>  byte = {2}  pc = <<"Done", "Done">>
```

Both threads read the empty byte, then each writes back its own bit, and thread 1's bit is lost.
In the heap this is exactly the hazard that row H1 of the 05c audit guards against. A plain
allocate-black store erases a marker's bit, and the sweep then frees a live object. With
`Plain = FALSE`, TLC reports `Model checking completed. No error has been found.` after 4 distinct
states.

Note how the labels (`Load:`, `Store:`) mark the atomic steps. Splitting the plain `|=` into two
labels is what let TLC find the bug.

## 2. PlusCal: pseudo-code that translates to TLA+

TLA+ itself is mathematics: `Next` is a formula relating the current state to the next. Writing
thread code directly in that form is tedious. **PlusCal** is an algorithm language that the
translator (`pcal.trans`, run as `pcal File.tla`) turns into TLA+. The PlusCal source lives in a
comment inside the `.tla` file. The translation is written between `\* BEGIN TRANSLATION` and
`\* END TRANSLATION`. **Never edit the translation by hand**: edit the PlusCal and re-translate.
`tla-check` fails if the committed translation is stale (parent plan §6.1).

The constructs the model plans use:

| Construct | Meaning |
|---|---|
| `process T \in S ... end process;` | one thread per element of `S`; `self` is its id |
| `fair process ...` | weakly fair (it eventually runs if it stays able to) |
| `variables x = e;` | globals at the top; process or procedure locals after the header |
| `L: stmt; stmt;` | a **label** starts an atomic step; everything up to the next label is one step |
| `x := e` | assignment. Statements in one step run in order, and later ones see earlier updates |
| `await P;` | the step can only happen when `P` is true: a blocking wait |
| `either A or B end either;` | the model may do A or B: nondeterminism |
| `with v \in S do ... end with;` | pick any element of `S` (nondeterministic); `with v = e` just names a value |
| `if/elsif/else`, `while`, `goto L` | control flow |
| `macro M(args) begin ... end macro;` | text substitution, inlined into the calling step |
| `procedure P(args) variables ...; begin ... return; end procedure;` / `call P(...)` | a subroutine with its own locals and its own steps |
| `define ... end define;` | named formulas that the code and the invariants can use |

**Rules that bite.** All of these were hit while writing the model sketches:

1. **P-syntax process headers have no parentheses:** `fair process Member \in BgSlots`, not
   `fair process (Member \in BgSlots)`. The parenthesised form belongs to the C-like syntax, and
   mixing the two gives `Expected "=" or "\in" but found "Member"`.
2. **Reserved names.** `stack`, `pc` and `self` belong to the translator: a global called `stack`
   gives `Global variable stack redefined`. The translator also defines `Termination`, so do not
   define your own.
3. **A procedure with parameters needs `defaultInitValue`** assigned in the `.cfg`
   (`defaultInitValue = defaultInitValue`, a model value), or TLC stops at startup.
4. **`return` rewrites the procedure's locals** (it pops the call frame). So a step that assigns a
   local cannot also `return`: put the `return` behind its own label (`Missing label`).
5. **A variable may be assigned at most once per step.** Assigning `x` twice needs a label between
   the two assignments.
6. **A label is required** at the start of a procedure, before every `while`, and on the statement
   after a `call` or a `goto`.
7. **A macro cannot take a `goto` target as a parameter.** Write one macro per target (M2 has
   `ClaimOrFill` and `ClaimOrRole`).
8. **Bound variables must not shadow model variables.** `[s \in Slots |-> ...]` fails if `s` is
   also a variable (`Multiply-defined symbol 's'`).
9. **In a single process `process P = id`, `self` is not substituted.** SANY reports `Unknown
   operator self`: use the literal id there (found while writing M6).
10. **Any spec with a procedure needs `EXTENDS Sequences`.** The translation keeps the call stack as
    a sequence. Without it, SANY prints dozens of semantic errors (found while writing M1).
11. **SANY's exit status is 0 even when it reports errors.** Always read its output for
    `*** Errors:` (§7).

## 3. From C++ to model steps

This is the heart of every model plan. The model is always **sequentially consistent (SC)**: one
global order of steps, and every step sees every earlier one. Real C++ with relaxed atomics is
weaker. §3.6 says how that gap is handled.

### 3.1 Atomics

| C++ | Model | Example |
|---|---|---|
| `x.load(order)` | one step reading `x` into a local, or read inline in the step that uses it | `sw := word;` (`idleUntilWorkOrDone` loading the state word) |
| `x.store(v, order)` | one step | `priv[self] := Len(pstack[self]);` |
| `x.fetch_add(n)`, `fetch_or`, `exchange` | one step (read and write together) | `word := [word EXCEPT !.active = @ - 1];` (`goIdle`) |
| `x.compare_exchange(expected, desired)` | one step: `if x = expected then x := desired else <failure path>` | `if word = sw then word := [word EXCEPT !.done = TRUE]` (the done-CAS) |
| a CAS **loop** (`reactivate`, `claimTicket`) | one step per attempt. If a failed attempt changes nothing anyone else can observe, the loop may be modelled as the step of its **successful** attempt | `ClaimOrFill()` models `claimTicket`'s batch CAS |

### 3.2 Plain memory

- **A plain read-modify-write that another thread can touch concurrently** becomes two steps: read
  into a local, then write back. That is the whole point of §1's example. The M4 model does this
  for `bitscan::clearBit` and for the plain field `gc_phase_`.
- **Owner-only data** (a private stack, a worker's cursor, a ring buffer on the thread's own stack)
  can be changed freely inside the owner's steps. Nobody else can observe the intermediate states.
  Model it as a per-process variable, or as a global indexed by `self` that only `self` writes.
- **Immutable data** (a heap object after it is published, rule P1) can be read in any step
  without a separate read step. Reading all of an object's fields at once is sound only because
  nobody writes them.

### 3.3 Loops over shared locations are not atomic

`anyWork()` checks every slot's deque and `priv` in turn, and each check is a separate relaxed
load. Between checking slot 1 and slot 2, work can move from slot 2 to slot 1. So the model reads
**one slot per step**:

```tla
I_Scan1:                                       \* env.anyWork(): one slot per step
    while aw # {} do
        with x \in aw do
            found := found \/ AnyWorkNow(x);
            aw := aw \ {x};
        end with;
    end while;
```

Collapsing this into one step (`found := \E x \in Slots : AnyWorkNow(x)`) looks tidier. It would
also hide exactly the interleavings that break termination detectors.

### 3.4 Locks

- **A critical section whose intermediate states nobody can see** becomes one step:

  ```tla
  Pop: queue := Tail(queue); state[job] := "Running";   \* under m_ in workerLoop
  ```

- **If some thread reads the protected data without taking the lock, model the lock explicitly**,
  so the critical section's internal steps are visible to that reader:

  ```tla
  Acq:  await lock = 0; lock := self;
  Body: gc_phase := "Idle";                \* the unlocked reader in another process sees this step
  Rel:  lock := 0;
  ```

  CR-001 (register) is exactly this case: `lazySweep` writes `gc_phase_` under `promo_mu_`, and
  other workers read it without the lock.
- **Condition variables.** `cv.wait(lk, pred)` is modelled as `await pred` inside a step that holds
  the lock (the lock is released while waiting and reacquired before `pred` is rechecked).
  Spurious wakeups need no extra modelling: `await` rechecks the predicate. A **lost wakeup** is
  modelled by making `notify` a separate step that only wakes threads already waiting, which is
  needed only where the code checks a predicate outside the lock.

### 3.5 Threads that start, stop and fork

- A gang member thread is a `process`. "Launch" sets a generation or a flag that the member
  `await`s, and "join" `await`s a finished count.
- **fork()** is a step that snapshots the state for a child in which only the forking thread
  exists. M6 models the child as a copy of the relevant variables in which every other process is
  gone. That is enough to check that no job or mark entry is stranded there.

### 3.6 Memory orders, and why the model can ignore them (mostly)

On real hardware, with relaxed or acquire/release atomics, a thread can observe other threads'
writes late or in a different order. The model's single global order hides this. The plan handles
it in two places:

1. **Where the code's correctness argument uses acquire/release**, the model records the argument
   as an **assumption**, and a weak-memory companion (W1–W5, `plans/threaded-gc-tla-W-weak-memory.md`)
   checks it on the real C++ under the C11 memory model.
2. **Where the code uses relaxed atomics only for indivisibility** (the mark byte's `fetch_or`, a
   ticket pool), SC is fine: indivisibility is all the argument needs.

**Acquire/release in one example (message passing).** Thread A writes an object, then does
`flag.store(1, release)`. Thread B does `flag.load(acquire)`, sees 1, then reads the object. The
pair **synchronises**: everything A wrote before the release is visible to B after the acquire. A
read-modify-write (`fetch_sub`, CAS) continues the chain, which is why every write to the
termination word being an RMW matters. A `relaxed` load gives no such guarantee: B might see
`flag == 1` and still read stale object contents.

### 3.7 Modelling a data race

TLC checks properties; it does not know C++'s rule that a plain access racing with any other access
is undefined behaviour. M4 adds that rule as an invariant, in three parts:
- a plain read-modify-write sets `inflight[b] = self` between its read step and its write step;
- every other access to `b` checks the flag;
- `NoRace == \A b : inflight[b] # 0 => <no other process has a pending access to b>`.

M4 §4 has the details.

## 4. Keeping models small enough to check

State-space size is the budget. A "quick" configuration should finish in seconds to a couple of
minutes, and a "deep" one in minutes to hours.

1. **Small bounds** give most of the benefit (the *small-scope hypothesis*): 2–3 threads, 4–6
   objects, rings of 1–2 entries, a ticket batch of 2. Real constants (ring 16, batch 256, publish
   threshold 64) are scaled down. Each model's plan says which scaling preserves the behaviour and
   why.
2. **Clear dead variables.** A local that still holds last step's value makes otherwise-identical
   states different. Set it back to a constant when it is dead, or avoid storing it at all
   (`with e = Head(ring) do ... end with` instead of `e := Head(ring)`). On M2 the first draft kept
   the scanned entry, the child being pushed, the saved state word and a success flag in locals:
   the episode configuration passed 22 million distinct states without finishing. The cleanup is
   still good practice, but it barely helped there: that state space came from interleavings, and
   only smaller bounds shrank it (M2 plan §6.1).
3. **Over-approximate with nondeterminism.** If the real code decides something by a threshold the
   small model cannot reach (publish half at 64 entries), let the model *choose* (`either skip or
   publish`). Every real behaviour is still a model behaviour, so an invariant that holds for the
   model holds for the code.
   - The price is possible **spurious counterexamples**, behaviours the code cannot produce. Each
     counterexample must be checked against the code before it is filed as a bug.
4. **Bound "adversarial" choices for liveness.** A steal that "found nothing although work exists"
   is a legal outcome of the real four-pass `stealAny`. Allowed without limit, it would let TLC
   build a behaviour where a thread never succeeds, and liveness would fail spuriously. The models
   cap such choices (`MaxGiveUps`).
5. **Symmetry.** If threads are interchangeable, declare them a symmetry set in the `.cfg` and TLC
   explores one representative of each permutation. Only use this when roles really are
   identical.
6. **Split, don't grow.** If a model needs more than a few minutes at quick scope, split it along a
   contract (parent plan §5.0), rather than raising the bounds.

## 5. Negative controls: proving a model has teeth

A model that finds no bug might be correct, or might be too abstract to see the bug. Every
invariant therefore gets at least one **mutant**: a deliberately broken variant, selected by a
`MUTANT` constant, that TLC **must** reject with that invariant.

```tla
I_Decide:                                      \* CAS(word: sw -> sw | done)
    if ~found then
        if MUTANT = "two_word" then
            word := [word EXCEPT !.done = TRUE];  \* separate atomics: no CAS
            goto R_ExitIdle;
        elsif word = sw then
            word := [word EXCEPT !.done = TRUE];
            goto R_ExitIdle;
        end if;
    end if;
```

`models.txt` records, per mutant, the invariant that must fail. The runner checks both TLC's exit
status and the violated invariant's **name**. A mutant that "fails" by deadlocking, or by breaking
a different invariant, does not count. Where a real bug once happened (the 5b two-load termination
race, the `JsonRoundtrip` stale copies), that bug is a mutant, so the model provably would have
caught it.

## 6. Trace validation: checking the code against the model

A model can be correct and still describe a different program from the one that runs. Trace
validation closes that gap.

1. The TSan harnesses are compiled with `-DECO_TLA_TRACE=1`. At each protocol point, the code
   appends an event to a per-thread buffer, e.g. `{"t":2,"ev":"goIdle","word":"a0e3"}`.
2. After the run, the buffers are merged into one sequence. The merge respects each thread's
   order, and for events that are read-modify-writes on one atomic word, the order of the values
   they observed. Every RMW on the termination word logs the word before and after, and those
   values form a chain, so the merge is unambiguous there.
3. A **trace spec** (`TraceSliceControl.tla`) reads the log with CommunityModules' `Json` module.
   It defines `TraceNext`, which is the model's `Next` restricted so that the *i*-th step must
   match the *i*-th event (same thread, same action, same observed values). Steps the code does not
   log are allowed in between.
4. TLC is asked whether a behaviour of length `Len(log)` exists. **If it does not, the code did
   something the model says is impossible.** Either the code has a bug (register entry), or the
   model is wrong (fix the model and write an AUDIT.md entry).

A sketch of the idea:

```tla
VARIABLE i                                  \* how many events have been matched
Log == ndJsonDeserialize("trace.ndjson")
IsEvent(t, name) == Log[i].t = t /\ Log[i].ev = name
TraceNext ==
    \/ /\ i <= Len(Log)
       /\ \E t \in Participants :
            \/ IsEvent(t, "goIdle") /\ GoIdleStep(t) /\ word'.epoch = Log[i].epoch
            \/ IsEvent(t, "doneCAS") /\ DecideStep(t)
            \/ ...
       /\ i' = i + 1
    \/ /\ UNCHANGED i /\ HiddenStep            \* unlogged steps (private pushes, etc.)
TraceAccepted == <>(i = Len(Log) + 1)
```

Each model plan lists its events, where the hooks go in the C++, and what the trace spec checks.

## 7. Tools and commands

In the dev image (`docker/eco-dev.Dockerfile`):

| Command | Does |
|---|---|
| `pcal Foo.tla` | translate the PlusCal inside `Foo.tla`, rewriting its translation block (add `-nocfg` to stop it writing a `.cfg`) |
| `sany Foo.tla` | parse and semantic-check only. **Its exit status is 0 even when it reports errors**: check the output for `*** Errors:` (found while writing the M1 sketch) |
| `tlc -workers N -config MC_quick.cfg MC.tla` | model-check. Exit status 0 = no error; a nonzero status means a violation or an error. The runner reads the message, not only the status |
| `apalache-mc check --inv=Inv Foo.tla` | symbolic check with bounded depth, or an inductive-invariant check with `--init`/`--next` options. Needs type annotations |
| `tlapm Foo.tla` | TLAPS proofs (only with `INSTALL_TLAPS=1`) |

`MC.tla` is a tiny module that `EXTENDS` the model and defines the constants a `.cfg` cannot write
inline, such as functions, graphs and sequences. Each `.cfg` then assigns them with
`CONSTANT X <- MC_X`.

---

## 8. Glossary of the GC terms in the model plans

Each entry gives the meaning in this codebase, a small example where it helps, and the model that
uses it most.

**Mutator.** The thread running the Elm program. There is one per heap (HEAP_007). "Mutator" as
opposed to the **collector**, the code (on any thread) doing GC work.

**Heap, nursery, old generation.** New objects are allocated in the **nursery** (the young
generation), a region that is cheap to allocate into by bumping a pointer. A **minor GC** copies
the nursery's live objects out and reuses the region. Objects that survive long enough are
**promoted** (or **tenured**) into the **old generation**, which is collected by a **major GC**
(marking, then sweeping).

**Young large object (YLOS).** A large pointer-bearing object that would be too expensive to copy.
It is allocated in an old-gen cell but treated as young until it is promoted in place (HEAP_062).
(M1, M3.)

**Builder.** An object that a C++ kernel is still filling in (`Header.builder == 1`). Builders are
always young and may be written after allocation (HEAP_BUILDER_*). (M1.)

**Root.** A place outside the heap that holds a heap pointer: a stack slot, a global, the RootSet,
the CellStore. Everything reachable from roots is **live**. (M1.)

**Frozen published heap (P1, HEAP_SNAPSHOT_001).** Once an object has survived a GC, nobody writes
its fields again (builders excepted). This is what lets the marker run while the mutator runs. The
marker can read old objects without racing, because they no longer change. (M1.)

**Mark bit; white / grey / black.** Marking finds live old-gen objects. **White** = not yet found.
**Grey** = found (mark bit set, entry on a work list), but its children are not yet looked at.
**Black** = found and scanned. The work lists are the **grey set**. Example: root → A → B. Marking
greys A, scans A (A black, B grey), then scans B.

**Snapshot, t0.** A concurrent mark cycle starts at **t0**, the end of the minor GC that triggers
it. In that pause, every root's old target is greyed. The lemma (parallel-gc.md §2.1) says that,
given P1, everything reachable later is either reachable from those t0 greys or allocated after
t0. (M1.)

**Allocate-black.** Any old-gen allocation during a cycle gets its mark bit set immediately, so
the sweep that follows the cycle cannot free it. (M1, M4.)

**Handoff.** The end of a cycle: the marker is done, and the sweep may now free everything still
white. (M1.)

**Slice, episode, assist, closing.**
- 5a: marking runs in **slices** inside minor-GC pauses.
- 5c: a **background episode** marks on background threads while the mutator runs. If the episode
  falls behind, the mutator's pause adds foreground helpers: an **assist** (bounded) or the
  **closing** join (until the episode finishes). (M1, M2.)

**Marker, participant, slot.** A **marker** is a thread doing mark work. A **slot** is a marker's
per-thread state (private stack, deque, counters). Slots 0..F−1 are foreground (slot 0 is the
mutator) and F..F+B−1 are background. (M2.)

**Private stack, `priv`.** A marker's own grey entries, which no other thread touches. `priv` is a
relaxed atomic copy of its size, so other markers can tell the marker still has work. (M2.)

**Deque; work stealing; Chase–Lev.** Each slot also has a **deque** (a double-ended queue). The
owner pushes and takes at the bottom; other threads (**thieves**) **steal** from the top. The
implementation is the Chase–Lev algorithm (PPoPP 2013 memory orders). A steal can **abort** when it
loses a race. (M2, W1.)

**Publish (half / all).** Moving entries from the private stack to the deque, so thieves can see
them. (M2.)

**Tickets, budget, pool.** Work is metered: a marker must hold a **ticket** to take an entry. It
claims tickets in batches from a shared **pool** (the control's **budget**, or an assist's own
pool). "Exact tickets" means entries scanned = tickets consumed, which makes the work counts
deterministic (GC_DET_001). (M2.)

**Termination detection.** Deciding that no marker has work and none can get any, so the run is
over. The state word packs `active` (markers not idle), `epoch` (bumped on every reactivation) and
`done`. A marker commits "done" by CAS from the exact word in which it saw `active == 0`. (M2.)

**Stop.** A request (fork, reset) for a background episode to wind down without finishing. The
unscanned work stays in the deques for a later relaunch. (M2, M6.)

**Forwarding pointer; BUSY; claim / publish.** When a minor GC copies an object, it overwrites the
original's header with a **forward** word that points at the copy. In the parallel minor, a worker
first **claims** the object by CASing its header to **BUSY** ("being copied"), copies it, then
**publishes** the forward word with a release store. Others that see BUSY wait. (M3.)

**LAB, filler.** A **local allocation buffer** is a chunk of to-space a worker owns, so copies can
be bump-allocated without contention. A **filler** is a dummy `Tag_Free` object that plugs the
unused tail of a LAB, so the region stays walkable. (M3.)

**Size class; uniform / mixed block; cursor; chunk.** The old gen is carved into blocks.
- A **uniform** block holds cells of one **size class**. Its mark bitmap doubles as its allocation
  map (HEAP_054).
- A **mixed** block holds varied sizes and is swept.
- A **cursor** is an allocator's position in one uniform block.
- In a parallel minor, workers share one block per class and CAS-claim **chunks** of 64 cells.
(M4.)

**Sweep, lazy sweep, gap sweep.** After marking, dead space is returned to free lists.
- **Lazy sweep:** done a little at a time, interleaved with allocation.
- **Gap sweep:** in a mixed block, walk the set mark bits (the live objects) and free the gaps
  between them (HEAP_055). (M4.)

**Helper pool, job.** Process-wide threads that run small jobs posted by a mutator: discard or
prefault pages. A **job** goes Idle → Posted → Running → Done. (M6, M7.)

**Gang.** A fixed set of threads started together to run one function. The **mark gang** runs
inside pauses (foreground). A **background gang** runs a mark episode outside pauses. (M6.)

**Epoch (sync / major).** Counters that the mutator bumps at the end of a pause (`sync_epoch_`) or
of a pause that contained a major GC (`major_epoch_`). Policy may depend only on these, never on
how far a helper got (GC_DET_001). (M7.)

**Deferred decommit, commit-ahead.**
- **Deferred decommit:** a released old-gen extent keeps its memory until it has been unused for a
  while, then a helper discards it (`MADV_DONTNEED`).
- **Commit-ahead:** memory just above the allocation frontier is mapped and pre-faulted in the
  background (`MADV_POPULATE_WRITE`). (M7.)

**fork / atfork.** `fork()` copies the process, but only the calling thread survives in the child.
`pthread_atfork` handlers run just before (prepare) and just after (parent, child), so each
subsystem can make its state safe to copy. (M6.)

**Data race.** Two threads access the same memory, at least one writes, at least one access is
not atomic, and nothing orders them (no lock, no acquire/release pair). In C++ this is undefined
behaviour, even if the hardware result looks harmless. (M4.)

**Happens-before.** The order C++ guarantees between operations in different threads: program
order within a thread, plus synchronisation (release → acquire, lock release → next lock acquire,
thread launch → start, finish → join). (W1–W5.)

**TSan.** ThreadSanitizer, a compiler instrument that reports data races *in the executions that
actually ran*. The repo's harnesses: `test/gc-helper-tsan`, `test/gc-heap-tsan`.

**Validator.** An `ECO_HEAP_VALIDATE` runtime check. IM1–IM16 are the mark-cycle ones, PM1–PM6
the parallel-minor ones, V1–V6 the page-work ones.
