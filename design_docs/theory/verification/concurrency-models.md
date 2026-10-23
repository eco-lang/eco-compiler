# Concurrency Models

The formal models say that each concurrent protocol in the collector is safe on small heaps, and they stay tied to the C++ closely enough to report when that stops being known. Each protocol has its own small model in TLA+, a language that describes a system as a set of states and the atomic steps between them. A model checker explores every interleaving of those steps on small heaps and checks named properties in every state it reaches. One claim is proved rather than only explored: the fact that snapshot marking rests on, that during a mark cycle everything live was either reachable when the cycle started or allocated since, is shown to be inductive, but only for heaps of up to five objects. A mapping names the code behind every model step, and three ties check that the mapping holds: weak-memory drivers run the real headers under the C11 memory model, logs from real runs are matched against the models, and a hash canary reports when the code a model describes changes. The canary warns by default, and a build setting makes it fail the build instead. The result is strong evidence about the design, not a proof of the C++. The models find design bugs before the code is written, and they tell a developer which model to reread when the code moves.

## Many small models, joined by contracts

The collector is described by eight small models rather than one. A single model of the whole heap and every collector thread would have far too many states to explore, so each model covers one protocol. Models fit together through contracts. A contract is a named guarantee one model provides and another assumes, such as "a young object is copied at most once". A model checks the contracts it provides and takes the ones it consumes as given. If a provider's property changes, every consumer's assumption changes with it, so a contract change is a change to several models.

Size is the force that keeps the models apart. The quick configuration of each model should finish in about two minutes, because developers run them while working. When a model grows past that, it is split along a contract instead of being given looser bounds.

The eight models fall into three groups: marking, moving objects, and the threads and memory underneath both.

| Model | Group | Protocol |
|---|---|---|
| M1 | Marking | The snapshot mark cycle of the old generation |
| M2 | Marking | The marker loop: taking work, stealing it, and agreeing that marking has finished |
| M3 | Moving | Forwarding in a minor collection: claim a young object, mark it busy while copying, publish the copy's address |
| M4 | Moving | Promotion in chunks and the mark bitmap at byte and word granularity, with a data-race detector |
| M5 | Moving | Concurrent tenuring, which moves long-lived young objects into the old generation while the program runs, and aging |
| M6 | Threads and memory | The helper pool: starting threads, grouping them for a job, and staying correct across fork and exit |
| M7 | Threads and memory | Page work: returning memory to the OS in the background, committing ahead of need, and lock order |
| M8 | Threads and memory | The old generation's block lifecycle, which is serial and is modeled for the hazard of an address being reused |

The mutator, the thread that runs the Elm program and allocates, is a single process in every model. The runtime allows one mutator per process: a second one aborts as it starts, unless a benchmark or test harness has explicitly allowed it. The models therefore never consider two, and that is also why the marker loop's termination needs no handshake across several program threads.

## What the snapshot model says

Snapshot marking is the clearest example of what a model claims. The collector marks the old generation while the program keeps running, without a write barrier. That is safe because Elm values never change once built: anything reachable when marking starts stays reachable through objects that existed then, and everything allocated afterward is treated as live until the next cycle. The collector's design states this as the snapshot-closure lemma. The model records, at the start of each cycle, the sets the lemma talks about, and states the lemma and the safety goals as named invariants over them.

```tla
    t0Reach  = {},                        \* IM1: old-gen cells reachable at t0
    tSH      = {},                        \* S_H: everything reachable at t0
    tNH      = {};                        \* N_H: allocated after t0

define
    ...
    Held     == ({root[r] : r \in RootSlots} \cup {cell[c] : c \in CellSlots}) \ {Nil}
    Live     == Reach(Held)
    ...
    Marked   == {o \in Obj : mark[o]}
    ...
    \* MODEL_M1_1: no reachable object is ever freed.
    NoLostObject == Live \subseteq alloc
    ...
    SnapshotClosure == CycleOn => Live \subseteq (tSH \cup tNH)
    ...
\* IM1: every old-gen cell reachable at t0 is marked.
IM1 == AtHandoff => t0Reach \subseteq Marked
```

From `test/tla/M1-snapshot-mark/SnapshotMark.tla`, trimmed. The three sets at the top are ghost variables: the code has nothing like them, and they exist only so the properties can be stated. `SnapshotClosure` is the lemma itself: during a cycle, everything live was either reachable at the start or allocated since. `IM1` is checked only at the handoff, the moment before the sweep frees anything, because that is the only point where an unmarked reachable object does harm.

The model checker TLC checks these properties in every reachable state of small heaps. Apalache, a second checker that reasons symbolically, also proves `SnapshotClosure` inductive: whenever it holds before a step, it holds after. That proof covers heaps of up to five objects. At six objects only some steps finish and at eight the proof is out of reach, so for larger heaps the lemma rests on the argument in the collector's design document, not on a proof.

## Holding a model to the code

A model is only worth what its link to the code is worth. Each model has a mapping that lists every shared memory location and every atomic step in the code, and names the model variable or step that stands for it. A footprint table goes with it: one row per shared location, each with a search over the source that finds the location again, so a reader can check that the list is complete. The mapping cites code and never the plan behind it, because the two diverge. A model of the plan document would describe detached helper threads, while the code joins them, and that model would check a program that does not exist.

Three ties check that the mapping holds, each covering something the model checker cannot see.

```
                   mapping: which code is which step
     model  <------------------------------------------>  C++ collector
       ^                                                    |   |   |
       | "does some model behavior match this whole log?"   |   |   |
       +------------ event logs from real runs -------------+   |   |
                                                                |   |
     GenMC drivers  <---- real headers, weak memory orders -----+   |
                                                                    |
     canary  <---- hashes of the pinned code -----------------------+
       |
       +----> names the models whose code changed
```

Weak-memory drivers exist because TLC assumes sequential consistency, in which every thread sees all writes in one global order. The code uses relaxed and acquire-release orders, which allow more behaviors. GenMC, a model checker for C and C++ under weak memory, runs the real collector headers under the C11 model, and each driver has mutants that weaken one order to show the driver can fail ([runtime-tests.md](runtime-tests.md) describes the drivers). Every place a model relies on an order weaker than sequential consistency is listed in its mapping with the driver that covers it.

Trace validation exists because a model can pass while describing a different program. If a loop in the model cannot stop where the code's loop can, the model has fewer behaviors than the code, and checking the model alone never notices. So trace builds turn on hooks in the allocator that record events, merge each thread's events into one interleaving, and ask TLC whether some behavior of the model matches the whole log. A log the model rejects is a finding. The snapshot model's assist step is the example: real logs it rejected showed a model loop that could not stop where the code's loop can. The hooks are compiled out of normal builds. Trace builds are kept apart from ThreadSanitizer builds, because the global sequence counter that orders the log adds happens-before edges between threads and would hide the races ThreadSanitizer exists to find.

The canary is the third tie, and the one a developer meets in every build.

## Expected outcomes and the defect register

Every check has a recorded expected outcome, and the runner demands exactly that outcome. A registry lists each model configuration with its tier (quick, or deep for the slow runs), its tool (TLC or Apalache) and what must happen: a pass, the violation of one named invariant, a deadlock, or a witness that some state is reachable. The runner parses each model, confirms that its TLA+ is a fresh translation of its PlusCal source (PlusCal is an algorithm-like language that translates into TLA+), runs the checker and compares. A mutant that passes, or that fails by violating some other invariant, fails the run. So does a check that hits its time limit, because a run that did not finish has shown nothing.

```text
# model  directory  module  config  tier  tool  expected
...
M1  M1-snapshot-mark  MC  MC_quick.cfg                        quick  tlc  pass
...
M1  M1-snapshot-mark  MC  MC_quick_region.cfg                 quick  tlc  pass                       # CR-017 fixed (HEAP_074)
M1  M1-snapshot-mark  MC  mutants/no_cr017_fix.cfg           quick  tlc  violates:MarkerFootprint   # CR-017 pre-fix code: regression mutant of HEAP_074
M1  M1-snapshot-mark  MC  mutants/p1_violation.cfg            quick  tlc  violates:IM1
...
M1  M1-snapshot-mark  MC  mutants/hidden_root.cfg             quick  tlc  violates:SnapshotClosure
```

From `test/tla/models.txt`, trimmed. Each mutant names the one invariant it must break, which is why properties are named invariants and never assertions inside the algorithm: the runner can match a name but not an anonymous assertion failure. The pair of rows for one register defect shows the life of a fix. The fixed configuration must pass, and the code's behavior before the fix lives on as a mutant that must violate a named invariant, so the defect cannot return without a model failing.

Defects found by any of the tools go into one register. Each entry moves through a fixed sequence of statuses: suspected, confirmed, reproduced, guarded, fixed and closed, and each move needs named evidence. A configuration that reproduces a defect is expected to violate its invariant until the fix lands. The change that fixes the code flips that row to a pass and keeps the broken behavior as a mutant, as the rows above show.

## The canary

The canary is what keeps the other ties meaningful, because a model that passes says nothing once the code it describes has changed. It is a hash check that takes about a second, so it runs in every default build. A manifest pins the code each model covers, and each pin names the models (and GenMC drivers) that must be reread if its hash changes. Pins come in four kinds, from the widest to the most targeted:

- a whole file, for small protocol headers;
- a region of a file, the text between a begin marker and an end marker in the source, with comments stripped and whitespace collapsed;
- a census of a file, which is every line matching a pattern for concurrency: atomics, memory orders, mutexes, fences, fork handlers and thread creation;
- a footprint search, the same search a footprint row uses, for plain shared fields that the census cannot recognize.

Pins are narrow on purpose. Hashing a whole allocator file of several thousand lines would fire on every edit and teach people to accept the change without looking. Regions pin just the code a model describes, and the census catches an atomic added anywhere in a covered file. Census and footprint pins keep the text they matched, so a failure prints the lines added and removed.

Hashes alone would let unguarded code arrive beside guarded code, so the checker also checks coverage. Every region marker must be pinned, every model must have a pin, every footprint row must appear in some mapping, and every allocator file with a concurrency line must have a census pin. The kernel license manifest is built the same way, for the same reason.

Accepting a changed hash is a separate, audited step. The update command refuses until the audit log of every model the pin names quotes the first twelve hex digits of the changed hash. The verdict is therefore written before the code is accepted, even when the verdict is that no model change is needed.

By default a canary failure prints a warning banner and the build continues, checking again on every build. A build setting turns the failure into a build error, and the script run by hand fails unless it is told to warn. Nothing in continuous integration notices a warning, so the banner is the only signal. Whichever form it takes, it means one thing: read the models it names and their mappings, decide whether they still describe the code, and only then accept the hash.

## Why the modeling rules are strict

The collector's concurrency bugs corrupt the heap without crashing where the mistake happened. A lost mark frees a live object, and a double copy leaves two versions of one value. Either shows up much later as a wrong result or a crash elsewhere. Stress tests rarely reach the fork and emergency-collection paths, while exhaustive exploration of a small heap reaches every interleaving there. Concurrent tenuring sharpens this, because it copies objects while the program runs, where a missed interleaving is hardest to see in testing. Its model is built from the merged code rather than from its design.

A model that differs from the code in the wrong way can pass while the code fails, so the models follow accuracy rules.

- One model step is one atomic step of the code. A plain load and a write that depends on it are two steps, and a loop that checks several locations for work is split into one step per location. Merging them erases exactly the interleavings that break termination protocols.
- Shared memory is modeled at the unit the hardware shares. Mark bits live in bytes that cover eight slots, and promotion chunks own whole 64-bit words, so a model with one bit per object cannot see a lost update. The snapshot model is the exception: it keeps one true-or-false mark per object and leaves byte sharing to the bitmap model and its weak-memory driver, and its mapping states why that split is sound.
- Every invariant has a mutant that must break it. A model that cannot fail proves nothing, and a mutant that passes shows that a configuration's target is unreachable within its bounds.
- Model properties are named after the rows of the invariant catalog, so one id links the catalog row, the model and the runtime check.
- A counter that is only compared for equality becomes a per-observer flag meaning "changed since I last read it", and a counter that wraps is given a tiny width so the wrap is reachable. Bounding the counter with a state constraint does not work, because TLC neither explores nor checks states outside a constraint, and liveness checking under a constraint is unreliable.

## Where and when the checks run

Only the canary runs in every build. The quick and deep TLC runs, the Apalache proofs and the GenMC drivers are far too heavy for hosted runners, and running them in continuous integration is declined on cost. They run in the development container when a model is finished and before a concurrent phase is switched on by default. The container image can be built without the model toolchain, and the CI image is.

The toolchain is pinned for reasons a developer upgrading it would need to know. The models run on TLC 1.8.0 rather than the stable 1.7.4, because the community modules that trace validation needs fail on 1.7.4. The TLC jar is kept in the repository, because upstream re-uploads 1.8.0 in place and a download pinned by hash would stop matching. GenMC is built with the compiler version it supports rather than the project's own LLVM. Spin loops are straightened out in the drivers, because GenMC cannot run pause, yield or sleep calls.

## What the models leave out

The models are evidence about the design and its mapping to the code, and their limits are part of what they say.

There is no proof of the C++. That would need a verified semantics of C++ of the kind research frameworks such as Iris or VST provide, which is out of proportion for this project. The models check small heaps, the one inductive proof covers heaps of up to five objects, and anything a mapping abstracts is argued in the mapping rather than checked. Two examples are the snapshot model's single mark bit per object and the allocation buffers' filler objects, which the forwarding model leaves out on the argument that only their owner touches them before the threads join.

Collector policy is not modeled: when to collect, how fast to mark, the shape of allocation buffers and the size classes. Policy is measured rather than verified, and the rule that collection is deterministic is enforced by a validator instead.

Only the collector as built is modeled: one mutator in the process, with either the region nursery or the legacy semi-space nursery. A single heap shared by several mutators is declined, so it is absent from the models. Concurrent clearing of the mark bitmap and concurrent evacuation of the old generation are not built, and each would need its own model first. One heap per thread, exchanging messages, is the planned direction for multi-threaded Elm and is not built either. Its design notes plan models of their own and bring them under the same canary rule.

GenMC is the weak-memory tool because it runs the real headers. C11Tester tests randomly, so a pass from it is weaker evidence. herd7 needs hand-written litmus tests, which drift from the code they stand for.

## Examples of changes that fit the theory
A change fits when the model, its mapping and its audit log move with the code, and the verdict is written down.

- Changing a protocol a model covers: edit the PlusCal source (never the generated translation), the mapping and the audit log in the same change, run the quick model checks, and run trace validation for traced paths. Every fix to a register defect has this shape: its rows flip to a pass, and the old behavior stays as a mutant.
- Adding a concurrent phase: write its model before the implementation, with the mapping and its footprint rows, mutants and a trace specification, then add pins and register entries. Concurrent bitmap clearing and concurrent evacuation are the candidates the verification plan names.
- Adding an atomic or a lock to a file that is already covered: the census fires, and the change is a model question first. Often the verdict is that no model change is needed, and it goes into the audit log with the hash prefix.
- Widening a limit the pinned code encodes, such as the most fields an object may have or the largest closure arity: the canary fires, and the audit entry records that no model change is needed.
- Guarding an address or identifier reuse, where one thread still holds the old meaning: add a configuration with a reused id and a mutant. The block lifecycle model exists for this reason, though its protocol is serial.
- Pinning a region: add begin and end markers in the source, add the pin with `-` as its hash, accept it through the update step, and list the pin in the model's mapping.

## Examples of changes that would break the theory
A change breaks the theory when it quiets the canary or a checker without anyone deciding whether the model still describes the code.

- Running the update step to clear a canary failure. The tool refuses without an audit entry, and an entry written to get past the gate, or a bulk re-bless after a refactor, leaves models without a real verdict. Read the change and its footprint rows, and update the model where it no longer matches.
- Ignoring a canary warning because the build went on. Nothing else notices it; treat the warning as the failure it reports.
- Editing the generated TLA+ translation by hand. The freshness check fails, and the next translation discards the edit. Edit the PlusCal and translate it again.
- Making a mutant pass, or loosening a bound to keep a run fast. Either removes the evidence that the model can fail. Split the model along a contract, or move the breadth to the deep tier.
- Letting a model drift toward the plan or the comments, merging two atomic steps into one, or writing a loop that cannot stop where the code's loop can. Each hides interleavings the code has. Cite the code, keep steps atomic, and let trace validation check the result.
- Adding shared state with no footprint row. The census sees an added atomic but not a plain field, and the register's first entries are all shared locations that the mapping tables missed. Add the footprint search and the mapping entry with the field.
- Checking a property with an assertion, or naming several invariants in one mutant's configuration. The runner matches one invariant by name, so either form makes the expected outcome unmatchable.
- Building a concurrency feature with no model. Concurrent evacuation, for example, would break the rules for forwarding through object headers that several models assume. Its model belongs before its code.

## References

Parent: [verification.md](verification.md).

- `test/tla/README.md`: how to run the models, the layout, trace validation and the canary protocol. Start here.
- `test/tla/models.txt`, `test/tla/manifest.txt`: the registries of expected outcomes and of pins; `test/tla/census/` holds the matched text of census and footprint pins.
- `test/tla/M1-snapshot-mark/` to `test/tla/M8-*/`: one directory per model, each with its PlusCal source and translation, `MC.tla`, quick and deep configurations, `mutants/`, trace specifications, `MAPPING.md` and `AUDIT.md`. M1's `SnapshotMark.tla`, `MAPPING.md` and `AUDIT.md` are the worked example.
- `test/tla/run_models.py`, `test/tla/run_traces.py`, `test/tla/trace/`, `test/tla/common/`: the runner and trace machinery.
- `test/scripts/check-tla-manifest.sh` (`--update` is the audited acceptance step) and the `tla-canary` block of the top-level `CMakeLists.txt`. `ECO_TLA_CANARY_STRICT=ON` makes a failure stop the build; it is OFF by default and no preset sets it. A hand run is strict unless `ECO_TLA_CANARY=warn`.
- `runtime/src/allocator/TlaTrace.hpp`: the trace hooks, compiled in by `ECO_TLA_TRACE`; region markers are `// TLA-REGION(<id>) begin` and `end`.
- `test/genmc/` with `drivers.txt` and `AUDIT.md`: the weak-memory drivers.
- `test/gc-heap-tsan/`: the race-detector and fork harnesses that produce traces.
- `plans/threaded-gc-tla-verification.md`: accuracy rules A1 to A9, the contracts (Drain, CopyOnce, LaunchJoin, PoolJob, SnapshotCycle, TenureDisjoint, BitFaithful, ReleaseContract), the canary design and the traps. `plans/threaded-gc-tla-primer.md` is a reader's guide; `plans/threaded-gc-tla-W-weak-memory.md` covers the choice of weak-memory tool.
- `plans/threaded-gc-concurrency-register.md`: every defect the models and tools have found, with its status.
- `design_docs/parallel-gc.md` section 2.1: the immutability premise and the snapshot-closure lemma.
- `design_docs/multi-threaded-eco/06-invariants-and-open-questions.md`: the models planned for one heap per thread.
- `docker/vendor/README.md`, `docker/vendor/tla2tools.jar` (TLC 1.8.0), `docker/eco-dev.Dockerfile`: the toolchain.

Invariants: HEAP_007 (one mutator per process), HEAP_SNAPSHOT_001 and HEAP_SNAPSHOT_002 (relied on by M1), HEAP_074 (the CR-017 fix), GC_DET_001 (deterministic collection, enforced by a validator). The canary rule (investigate the named models, never just repair the hash) is in `test/tla/README.md` "The canary", not in the catalog.

Known disagreements in the repository's documents, where the code and `test/tla/README.md` are right: `plans/threaded-gc-tla-verification.md` says a canary failure fails the build, while the code warns by default. The same plan names seven models, while `models.txt`, `manifest.txt` and the README include the eighth, the block lifecycle model. The headers of some `AUDIT.md` files say the canary is not built, though they record many canary re-audits below the header.
