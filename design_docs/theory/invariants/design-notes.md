# Design Notes

Eco's design notes record ideas that were investigated, both dead and still open. They do not describe the system as it runs. Each note is a snapshot of one investigation, and each investigation ends in one of four outcomes. An adopted idea is rebuilt as code and fixed as numbered rules. A rejected idea failed a measured gate, and its note stays as a postmortem. A superseded idea is left as history or deleted. An open idea is parked with a condition for reviving it. The deciding evidence is almost always a count or a side-by-side measurement taken on the compiler compiling itself. Notes are rarely updated with their outcome, so a note's own status line is a starting point: the plans, the invariant catalog, the code and the commit history say what became of it.

## Why the notes go stale

A note is written while its investigation runs. It records the question, the method, the measurements and a recommendation, and it is finished when the investigation is. Status is kept elsewhere, in the plan files, because a plan is the document people edit while the work is built: it has phases, gates and a status describing what exists. Keeping status in one place avoids two records that disagree, but it leaves the note as it stood at the moment of writing. A note that says "nothing is built" keeps saying it after the passes land, and a note that recommends one design may sit beside code that chose another.

Plans are themselves written in stages, each phase's detail only when the phase is about to start, for the reason [invariants-and-design.md](invariants-and-design.md) gives.

## Finding out what became of a note

Most notes open with a status line in their own words: an idea, an investigation, a first or second version of a design, an analysis, or a no-go. That line describes the note when it was written. Investigation reports also tag each claim with the kind of evidence behind it: measured from a run, derived from measured figures, estimated by reasoning, or taken from published work. A recommendation that rests on estimates is weaker than one that rests on measurements, and the tags show which is which.

The outcome is found in four places, checked in this order:

1. The plans. An adopted direction has one or more plan files, and the plan's status says what is built.
2. The invariant catalog. Whatever must stay true after a design lands is written there as a rule, usually citing the note or plan behind it. A note cited from the catalog has been adopted, at least in part.
3. The code. If the passes, modules or heap layouts a note describes exist, the idea is built, whatever the note says. If they are absent, the idea is unbuilt or removed.
4. The commit history. Superseded notes and removed code are often deleted, so absence from the tree is evidence in itself. Commit messages name exact symbols, and searching the history for a deleted pass finds the commit that removed it and the reason.

Each outcome leaves a different trace, and the table says where to confirm it.

| Outcome | What remains | Where to confirm it |
|---|---|---|
| Adopted | Code, rules in the catalog, a plan with a status | The code and the catalog |
| Rejected | A postmortem note, or an entry in the register of parked items | The note's own gate, the register, the commit that deleted the code |
| Superseded | The original note, unchanged or deleted | The replacement plan or note, the history |
| Open | A note with no plan and no code | Its revival condition, usually a count to take first |

Adoption is often partial or reshaped. An idea may be adopted in a narrower form, adopted as an analysis while the work built on it is abandoned, or adopted with its central proposal changed. Several notes read as unbuilt although their designs ship. The note on memoizing top-level constants says there is no implementation, and memoization is on by default. The note on deciding whole-program facts before splitting the back end says nothing is built, and the passes exist.

## How a design moves from note to rule

Every design that goes ahead follows the same five steps, and each leaves its record in a different place, so that the reasoning, the status and the rule each have one home.

1. Investigate. A report or sketch goes into the design documents, with a status line and evidence tags.
2. Plan. A direction worth pursuing gets a plan file, which takes over the status.
3. Gate and ship. Before anything is built, a census counts how often the targeted pattern occurs in a real program. If the population is large enough, the work lands behind a configuration switch that an environment variable can also turn off, so a regression can be ruled in or out without a rebuild. The result is classified in a status table.
4. Fix the rule. What must stay true is written into the invariant catalog, and from then on the note is history.
5. Retire. The note is deleted, or kept as a postmortem that explains the attempt and why it failed.

The status table for the kernel optimization series shows the classification at its finest. Each item is landed, kept on, kept dark, partial, reverted, blocked or rejected. Kept dark matters most to a reader of the code. The code is in the tree and looks live, but its switch is off and it does not run in a normal build. Before treating a pass as part of the pipeline, check its default in the compiler's configuration.

## The evidence that decides

The deciding evidence is almost always one of two measurements on one workload, the compiler compiling itself. A census counts the population a change could affect, before anyone builds the change. A side-by-side comparison runs the compiler with and without it. The self-compile is the standard workload because it is the largest Elm program the project has, and because the compiler is itself a product: any slowdown it carries is paid on every later compile.

Optimizations are judged on the work and the memory they remove, not on how many objects or calls they eliminate. Across the optimization experiments, wall time follows how much data is promoted to the old generation and retained there, and does not follow object or call counts. The same reports find the kernel boundary a small share of the time ([kernels.md](../kernels/kernels.md)). So candidates are ranked by census first, and a change that fails its gate is kept dark or reverted whole.

## What the record holds

The notes below are the ones that explain code a reader is likely to meet, grouped by outcome.

### Adopted, often in a changed form

On the compiler side, four adopted notes shape the code:

- Lambda set specialization tracks which functions can reach each call site and turns calls whose set has one member into direct calls. A large block of catalog rules governs it.
- Specialization reuses the type checker's unification engine, but not in the form first proposed. Driving specialization entirely from the solver failed once already: an earlier specializer built that way proved incomplete and blocked further work, and was deleted. The note on that failure recommends keeping the demand-driven worklist that finds which instances are needed and swapping only the unification engine, which is what the compiler does.
- Top-level constants are memoized, computed once and kept in a permanent area of memory, and this is on by default. Hoisting closed expressions out to become such constants is built but switched off.
- Debug logging is observable output, because the native path does not strip it. The logging policy forbids any pass to delete, merge or move an expression that logs, and the optimization passes cite it as binding.

Strings, bytes, arrays and kernel calls each have an adopted note, and the string and array notes are adopted only in part. UTF-8 strings are used only for input that is entirely ASCII. The investigation judges a general second encoding, with transparent fallback to the first, too costly. Restricting the compact form to ASCII keeps a character's index equal to its byte offset, so string operations stay correct without knowing which form they hold. Fused compilation of byte encoders and decoders is adopted with its own blocks of rules. The array note is adopted in part: element-access operations are built in, while array fusion and loop lowering are not. The series on reducing calls between generated code and kernel functions is finished, and its main product is a table of facts about kernel functions that the optimizer consults.

The parallel collection report is the source of the threaded collector, but its recommendation is not followed as written. The report prefers parallel stop-the-world collection, which gives most of the throughput at lower risk for a batch compiler with one mutator thread. The threaded collector puts short pauses first and targets very large workloads, so concurrent marking is the default and parallel marking is the simpler mode beneath it. Both rest on a lemma the report states: heap contents never change once published, so no write barrier is needed.

In the back end, parallel optimization is adopted with its proposal reshaped. One proposal turns off inter-procedural optimization entirely and puts each function in its own module. The binary being built is the compiler itself, and it would pay the lost optimization on every compile, so instead the program is split into partitions close in number to the core count and each partition is fully optimized. Whole-program facts are decided in MLIR before the split so that the LLVM side can work on each partition alone. All drivers share one back-end routine for the steps that rewrite collection points, keep frame pointers and set the target's data layout, because separate copies of those steps drift apart in the order they run them.

### Rejected on a measurement

Escape analysis on the lowered code was built, measured and removed. It came with a splitting of functions so that aggregates could travel unboxed across calls. The single-function pass classified almost every construct as escaping, the cross-function engine admitted few values, and the end-to-end comparison was net negative on allocation volume. Value aggregates keep a lowering of their own, and the compiler does emit aggregate operations; only the escape-driven machinery is gone. Its successor is borrow inference, which infers lifetimes from function signatures and so avoids the obstacles the census listed: closures, coupling between caller and callee, the collector's safe points, returns and loops.

Borrow inference as an always-on analysis failed in turn. The analysis costs far more time than any consumer returns, and the one consumer measured had almost no values to act on. It ships switched off, usable as an oracle, and a reference-counting track in the runtime that would consume its results waits behind its own gate.

Two lambda set designs failed their own gates. Stack-allocated unions of captured values were a no-go because the share of allocations that come from sets with several members is close to nothing. A program of closing the gaps between Eco's lambda set analysis and the published inference it is based on was abandoned because it did not move coverage. Its postmortem finds that the effort went into the middle of the analysis while the deficits sit at the two ends: definitions that state no sets, and consumers that exploit only sets with one member. A single budget setting moved coverage more than the whole program of fixes.

Several smaller optimizations each showed no gain when measured: fusing list combinators pairwise, raising function arity, flattening record stores, and writing the list higher-order functions in Elm instead of in the kernel. The register of parked items records each one with the condition under which it could return.

### Open

Several designs are open, and each says what would move it forward:

- Extending lambda set specialization to sets with several members, in a sketch called multiset defunctionalization, waits on a census gate written into the sketch. It is deliberately not a plan.
- Looking through closures to reach kernel functions is unbuilt as specified. The pass that turns closure calls into direct calls skips calls whose target is a kernel function, and a count of the calls it declines, with the reason for each, ranks the remaining work.
- Embedding the linker in the compiler binary is deferred. Linking spawns a separate process, which in the distribution build is a static linker bundled with Eco.
- Incremental builds are explored as an ownership rule first: a specialization belongs to the module that requests it, so dependencies follow import order. The notes list the flows that break that rule and are explored by experiment, with no plan. No incremental pipeline after type checking exists.
- Running Elm on several threads is a design space with some decisions taken. Each thread would own its own heap with one mutator, and threads would communicate only by messages. A single heap shared by several mutators is rejected, because it needs cross-thread references to young objects or stop-the-world minor collections, and marking handshakes with every mutator. None of the chosen design is built; its draft rules are not in the catalog, and the runtime has one mutator per process.
- Error handling at the top level is unfinished: an unhandled task failure is printed and dropped.

## Changing the record

A change to the design record fits when it keeps the notes as reasoning and the plans, catalog and code as status, because each of those is maintained where the work happens and the notes are not.

### Examples of changes that fit the theory
- An investigation goes in as a report with a status line and evidence tags, and takes a census before anything is built. A census is cheap, and the measured population decides whether building is worth it.
- An adopted direction moves into a plan with phases and gates, lands behind a switch that the environment can turn off, and has its outcome recorded in a status table. Its status then lives where it is maintained.
- A failed gate is written up as a no-go that states its revival condition, so that a later reader knows what evidence would reopen it.
- A design that becomes a rule gets a catalog row that cites the note, which keeps the route from rule to reason open.
- A superseded note gets its status line pointed at the replacement, or is deleted, so the tree does not offer a dead design as live.

### Examples of changes that would break the theory
- Reviving a parked item without its revival condition being met. The recorded measurement stands until something replaces it. Reopen the item only with fresh evidence and a fresh census.
- Ranking or justifying an optimization by allocation or call counts alone. Wall time follows retained data and removed work, not counts. Measure those.
- Rebuilding a removed pass from a stale note. The reason it failed is in the postmortem and the commit that removed it. Read both first.
- Writing a plan whose status contradicts its note without touching the note. The next reader then finds two records that disagree. Point the note's status line at the plan.
- Citing line numbers from a note. They point into code that has moved. Cite the symbol, which the history can find.

## References

Parent: [invariants-and-design.md](invariants-and-design.md).

- `design_docs/`: the investigation reports. `design_docs/theory/` holds this theory and is not part of this record; `llvm-docs`, `mlir-docs`, `gc_handbook`, `perceus_gc`, `mlton` and the PDFs are third-party reference material; `all-*.csv` and the test-case listings are generated catalogs.
- `plans/`: the status record. `plans/opt-tier4-parked.md` is the register of parked items with revival conditions; `plans/opt-tier1-aggregate-promotion.md`, `plans/opt-tier3-rc-runtime.md` and `plans/threaded-gc-master-plan.md` ("How this plan is used") are live roadmaps.
- `design_docs/invariants.csv`: where adopted designs become rules (LSS_*, BFOPS_*, BFUSE_*, HEAP_032 for ASCII-only UTF-8, CGEN_061, CGEN_063, REP_AGG_001 for value aggregates).
- `kernel-opt-status.md`: the status table with the seven dispositions; `guides/kernel-opt-loop.md` and `benchmarks/` for the measurement protocol.
- `design_docs/parallel-gc.md`, `design_docs/multi-threaded-eco/README.md`: evidence-tagged investigation reports.
- `design_docs/globalopt/borrow-inference-design.md` (section 2, the escape analysis postmortem).
- `design_docs/monomorphization/lambda-set-specialization-design.md`, `capture-union-representation.md`, `multiset-defunctionalization-design.md`, `solver-reuse-evaluation.md`; `design_docs/hm-solver-reuse.md`; `design_docs/auto-borrow-inference/lss-why-the-fidelity-program-failed.md`.
- `design_docs/caf-memoization-design.md`, `design_docs/utf8-string-encoding-investigation.md`, `design_docs/fused-bytes-compilation.md`, `design_docs/array-optimisation.md`, `design_docs/kernel-boundary-reduction.md`, `design_docs/debug-log-ordering-policy.md`.
- `design_docs/backend-parallel-optimization.md`, `design_docs/mlir-level-partitioning-whole-program-steps.md`, `design_docs/converge-pipelines.md`, `design_docs/lld-in-eco.md`, `design_docs/distribution.md`.
- `design_docs/kernel-closure-lookthrough.md`, `direct-call-decline-census.md`, `design_docs/explicit-meta-structures.md`, `design_docs/incremental-builds/README.md`, `error-handling.md`, `tuple-project-fun-error.md` (open, unverified), `let-number-misspec-error.md` (superseded).
- `compiler/src/Compiler/Eco/Config.elm`: the defaults that say which adopted compiler designs run. `compiler/src/Compiler/MonoSolver/`, `compiler/src/Compiler/GlobalOpt/`: where they live.
- `runtime/src/codegen/Passes/` (`EcoGCStrategy.cpp`, `EcoToLLVMValueAgg.cpp`), `runtime/src/codegen/EcoBackend.cpp`, `runtime/src/allocator/`, `runtime/src/platform/Scheduler.cpp`: where adopted back-end and runtime designs live.
