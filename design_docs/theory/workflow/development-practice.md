# Development practice

Work on Eco runs as a loop: measure, plan, implement, measure again. A plan is a markdown design document that states a hypothesis and the gates the change must pass, written before the work and amended as it lands. A benchmark protocol fixes the workload, the measure, the number of runs and how each result is recorded. A guide turns the loop into a prompt that an agent can run unattended. Diagnostic tools, chief among them a heap profiler, supply the numbers. A step is kept when it beats the best result so far on a frozen workload, or when it removes code without losing time, and every step is written down whatever its verdict. Results flow back into the plan's text, the code's comments, the rule catalog and the commit messages. A plan's status line is not kept up to date consistently, so a plan is read for its reasoning, and the code and the history decide whether its work exists.

## A step counts only against a reference

The rule behind every part of the practice is that a measurement means something only beside another measurement taken the same way. Eco's optimizations are often flat or negative, their effects are small next to the noise of a self-compile, and several of them interact. A single number, or a comparison with a number remembered from last week, cannot say whether one change helped. So each series of experiments keeps a reference row, which is the best result so far, and judges every candidate against it on the same input with the same command line.

Measuring also comes first. Many plans open with a census, a measurement phase that counts what the compiler emits or allocates, and say that nothing is built until the census ranks the target. The plans give the reason themselves: estimates of where time and memory go are wrong often enough that building on them wastes work. One series records a case where the allocation census ranked a unit low and data on what stays live showed that it mattered, which is why a census is a ranking to check rather than a verdict.

## The four kinds of artifact

The practice lives in four kinds of file. They follow the order in which a change meets them: the plan that argues it, the protocol that measures it, the guide that repeats the loop, and the tools that explain the numbers.

### Plans

A plan is one file in a flat directory, named by a short topic slug in hyphenated lowercase words. A typical plan has a status line, a goal, a list of verified facts about the current code, numbered units or phases each with a gate, a switch that turns the change off and a way to roll it back, and, once measured, a results section. The verified facts are there because an agent or a newcomer writing from memory gets the code wrong. The plan records what was checked in the code, so a reviewer can check it again.

Related plans share a prefix, so the directory is searched by topic. A numbered series sets the order of a body of work, a track groups several series, and prefixes such as fix and remove name the kind of work. When a sweep of measurements is part of a plan's argument, its data sits in a folder or file beside the plan.

Plans and the rest of the repository point at each other. Plans cite the rule catalog's numbered rules and the long-lived design documents. The rule catalog, the options documentation and many source files cite plan sections for their rationale. Most commits that touch a plan also touch code or tests, so a plan is edited together with its change rather than in a separate documentation pass. The commit message carries the final reason for the version that lands.

### Benchmark protocols

The benchmarks directory holds experiment protocols rather than one suite. Each protocol is a markdown file plus the scripts that run it, and each serves one area: back-end lowering, native compile time, the front end, the collector, the kernels, and two series of whole-program optimizations. A protocol fixes four things. The workload is usually the compiler compiling itself, with its input frozen for the whole series. The measure is wall time first, then peak memory, allocation counts and collector counters. The protocol also fixes the number of runs, and a recording format in which each run is appended to a log as a labeled row.

The scripts beside the protocols do five jobs. Timing scripts take the median of several runs under GNU time. An interleaved script runs a reference and a candidate alternately in one sitting. Census scripts count what the compiler emits. Comparers check that two collector configurations behave identically and exit with an error when they do not. A sweep scorer ranks the cells of a parameter sweep. Heap configurations live as small JSON files in their own folder.

The comparison of Eco against stock Elm that users see lives with the examples. The protocols here exist to decide whether one change to Eco is worth keeping.

### Guides

Guides come in three kinds. Loop prompts are written for an autonomous agent: a setup phase, a strictly ordered loop, a revert rule and a stop condition. Their companions are working-notes files that grow as the loop runs, holding the baseline, each round's numbers, the fixes applied and the dead ends. A loop prompt names its notes file, so each round reads and extends it. Howtos are step-by-step instructions for people: profiling C++, profiling memory, measuring test coverage and turning on the collector's debug checks.

The loop prompts are explicit about order because nobody watches them run. The test-fixing loop says to run its steps strictly in order without skipping or combining any, requires a chain of evidence to a root cause before a fix, and lists the files a fix touches so a failed fix can be reverted. One step waits for the agent's usage allowance to reset, which only makes sense in a loop that runs alone.

The numbers in a working-notes file come from that series' own baseline compiler. They sit next to instructions that stay true, and they describe that series rather than Eco as it is.

### The heap profiler

The heap profiler is a stand-alone Python tool that compiles the self-hosted compiler under a chosen heap configuration and reports what the collector did. It runs one configuration, sweeps a table of variants, or diffs two results. Each invocation writes a timestamped results folder with a readable report, a median row per cell, every raw run and the arguments used.

Its metrics include wall time, processor time, peak memory, pause-time percentiles, bytes promoted and tenured, and the old generation's peak. It also reports minimum mutator utilization, which is the worst share of a time window left to the program rather than the collector. That metric needs a build with phase timers.

The profiler is strict about which runs count, because a collector timing is only comparable when the work and the machine are the same. Cells run one at a time, since concurrent runs disturb each other's timing. A run counts only if it exits cleanly, receives no signal and produces output byte for byte identical to the first valid run of the sitting, since a run that computes something different is not a timing of the same work. The machine name and the results folder come from a local file that git ignores, so raw profiling output never lands in the repository. A summary that supports a decision goes into a protocol's log or a plan's results section, and that is committed.

## How one step is judged

A series starts from a snapshot of the source tree that is its reference. Each step makes one change, builds, measures once on the frozen input, and is kept or reverted by comparing wall time with the reference. The back-end protocol spells this out most completely.

```text
ref = snapshot of the baseline tree           -- best row so far; never re-measured
for each planned step s:
    verify the live tree equals ref
    implement s; snapshot try-s; save diff(ref, try-s) as a patch
    build eco-boot-native
    run ONCE on the frozen input (ecoGCR.mlir), shipped default flags
    sanity: rc == 0, output ELF about the expected size, stats banner complete
    floor = max(1.0 s, 1% of wall)
    WIN  if wall fell by more than floor
         (or wall did not rise beyond floor and the targeted phase improved > 3x its spread)
    LOSS if wall rose by more than floor
    FLAT otherwise
    append the log entry, whatever the verdict
    WIN: snapshot keep-s; ref = keep-s
    FLAT that deletes code or work: kept
    LOSS, or FLAT that adds complexity: restore ref; verify ref
after the series: run the correctness gates once; on failure bisect over keep-* snapshots
```

Steps are kept on wall time alone, and the expensive correctness gates run once at the end, because a self-compile costs tens of minutes and running the gates per step would make a series too slow to finish. The per-step sanity checks are the ones that cost nothing, and the return-code check exists because a crashed run is fast and would read as a win. A flat step that adds complexity is reverted, because code with no measured gain is a cost to everyone after. The protocol does not say whether a kept flat step becomes the reference, and its log does it both ways, so a protocol that copies this loop should decide.

The workload and the command line stay fixed for the whole series. The input is never regenerated mid-series, and a step that changes a default edits the default in the source, so the command line never changes. Only then can a difference be put down to the one change in the step.

Some effects are smaller than the drift between sittings. Re-runs of a step can disagree with its first measurement by more than the effects still on the list, so for those the protocol switches to interleaved pairs: reference, candidate, reference, candidate, in one sitting, judged by the median of the paired differences. That cancels drift instead of averaging over it, and it replaces comparing a candidate with a reference measured hours before. Counters that are exact for a given binary, such as the number of collections or allocations, are judged from a single run. Wall time is judged only by repetition.

A census that turns several switches off cumulatively has the same problem as a multi-change step: it cannot say which switch caused an effect. The switch census therefore turns off one switch at a time.

## Reading a plan

A plan's text is reliable for its reasoning and unreliable for its status. Status is not machine-readable. About two thirds of the plans have no line starting with the word status. Those that do use different words, such as implemented, shipped, done, proposed, shelved, no-go and superseded, followed by free text, and some put the status in a banner or in bold. Several plans say that nothing is built while commits that implement them are in the history. A superseded plan says so in prose, and a plan can be superseded for the order of work yet remain the description of what is built.

Reading a plan therefore takes three checks, in this order.

1. Read the status line, the goal and any results section, to learn what the plan intends and what it claims.
2. Look in the code for what the plan says it adds: the switch it names, the pass or function it describes, the rule it cites. Its presence or absence is the fact.
3. Search the commit history for the plan's topic. A landing commit usually edits the results section together with the code, and its message carries the final reason.

When plan and code disagree, the code is right about what exists and the commit message is right about why the landed version has its shape. The plan stays the best record of the alternatives considered and the facts checked beforehand.

References inside plans and protocols need the same care. A plan can quote a build configuration name the build does not use, and a script can describe itself under a path it does not live at. Check a plan's commands against the build documentation before running them.

## What the record keeps

A negative result stays findable, so that nobody tries the same design again blind. Plans that came out negative are kept and labeled as no-go or shelved, and one plan is a register of things the evidence says not to do. Finished plans are treated less consistently. Some are deleted, while most stay as as-built records, and no document says which practice governs.

A protocol whose switches nothing in the code reads is marked expired with a banner rather than deleted. Setting an environment variable that nothing reads does nothing and reports nothing, so an old row from such a protocol would be misread as a measurement. The banner says why the protocol is expired and keeps its measuring method for reuse.

A plan is where a change is argued, and it can be superseded without anyone noticing. A reason that must outlast the plan goes where readers look for it: a numbered rule in the catalog, a code comment or the commit message. A catalog row is cited by checks and code, so a change to it is visible, though rows can still go stale like any other text.

## What the practice depends on

The practice leans on parts described elsewhere. Plans gate on and cite the rule catalog. Plans and loops quote the build targets from the parent document, and the self-compile's MLIR is the usual workload. The loop prompts call the project's documented test commands as their gates. The protocols assume GNU time and a quiet machine that runs nothing else.

The runtime's statistics output is a format other code parses. The collector's summary banner, its event log, phase-timer output and closure statistics are read by the summarizing scripts, the comparers and the heap profiler. A change to one of those formats breaks them, so it should be made together with the scripts that read it.

## Examples of changes that fit the theory
A change fits when its numbers can be set beside the ones already recorded: the same frozen input, the same recording format and the same judgment against a reference row.

- An optimization effort starts as a plan with a status, verified facts, units with gates, a switch, a rollback and an expected effect. Its measurements go in the nearest protocol's log in that log's format, the verdict is recorded even when flat, and the landing commit edits the plan's results section together with the code. The record then shows what was tried and what it gave.
- A tracked measurement is a protocol file that freezes the input and the command line, a script that emits tab-separated rows, and a comparer that exits with an error on mismatch. The comparers for collector configurations have this shape, and a failing comparer stops a loop where a printed difference might be missed.
- A heap configuration to try is a JSON file beside the others, or an entry in the heap profiler's variants table. The tool stays unchanged, so earlier results stay comparable with later ones.
- A recurring agent task is a loop prompt paired with a working-notes file, so each round starts from what the last one found.
- A protocol whose switches nothing in the code reads gets an expiry banner that says why and what remains valid.

## Examples of changes that would break the theory
- Quoting a plan's status line as present truth. Status lines lag the code. Check the code and the history, and when landing a change, update the status and cite the landing commit.
- Measuring a candidate against a remembered or regenerated baseline, or changing the workload mid-series. The difference would mix the change with drift and with the change in input. Take a fresh paired run against the same frozen input.
- Adding a one-off timing script that bypasses the existing result formats. Its numbers cannot be compared with any recorded row. Extend the heap profiler's variants or a protocol instead.
- Keeping a step that adds complexity on a flat result, or several changes in one step. The first leaves cost with no gain, and the second cannot say which change did what. Revert the flat step, and split the combined one.
- Writing profiling output into the repository tree. Raw runs are machine-specific and large. Use the machine-local results folder and commit only the summary.
- Changing a statistics format in the runtime without the scripts that parse it. The comparers and the profiler would fail or, worse, misread. Change both together.
- Putting a durable design reason only in a plan. Plans are superseded without notice. Put the reason in the rule catalog, the design documents or a code comment, and cite the plan from there.

## References

Parent: [build-and-workflow.md](workflow.md).

- `plans/`: the plans, flat, searched by topic prefix (numbered series such as `kernel-opt-NN-*`, `threaded-gc-NN-*` and `borrow-inference-phaseN-*`; tracks such as `opt-tier1..4-*`; `fix-*`, `remove-*`, `lss-*`). `compiler/plans/` holds one file, a fix plan for CGEN_052.
- `plans/large-body-gc-trigger.md`, `plans/large-body-gc-trigger/variants.json`, `plans/gc-param-sweep/`: a results section added with the code, and sweep data kept beside plans.
- `plans/lss-dispatch-value-extraction.md`, `plans/io-monad-caller-direct-state.md`: plans that measure before building.
- `plans/accumulator-templates.md`, `benchmarks/tier2-opt.md`: a census that under-ranked a unit, and a negative result kept and labeled.
- `plans/borrow-inference-phase3-interprocedural.md`: superseded for sequencing, kept as the as-built description.
- `benchmarks/backend-opt-loop.md` (sections 1, 2 and 4): the step loop shown above. Also `benchmarks/lss-compile-opt-loop.md`, `benchmarks/fe-opt-loop.md`, `benchmarks/gc-opt-loop.md`, `benchmarks/kernel-opt.md`, `benchmarks/borrow-inf-opt.md`.
- `benchmarks/flag-off-lss-loop.md`: an expired protocol with its banner, and the one-switch-at-a-time census.
- `benchmarks/lss-loop-ab.sh` (interleaved pairs, reason in its header), `benchmarks/lss-loop-snap.sh` (reference snapshots), `benchmarks/backend-bench.sh` (median timing; its header names it `scripts/backend-bench.sh`).
- `benchmarks/*-census.sh`, `benchmarks/*-census.py`, `benchmarks/tg7-compare.py`, `benchmarks/gc-sweep-eval.py`, `benchmarks/gc-event-log-summary.py`, `benchmarks/heapcfg/`.
- `guides/test-fix-loop.md`, `guides/kernel-opt-loop.md`, `guides/perf-tune-loop.md`: loop prompts. `guides/mem-hints.md`, `guides/test-fails.md`: working notes. `guides/profiling-command.md`: one Node process at a time.
- `guides/cpp-profiling-howto.md`, `guides/mem-profiling-howto.md`, `guides/test-coverage-howto.md`, `guides/gc-diagnostics.md` (documents `ECO_GC_DEBUG`, `ECO_GC_DEBUG_COMP`, `ECO_GC_DEBUG_LIVENESS`).
- `heap-profile.py` (`build_parser`, `cmd_run`, `cmd_sweep`, `cmd_diff`, `VARIANTS`), `heap-profile.local.example.json`.
- Runtime statistics parsed by the scripts: the GC stats banner, `ECO_GC_EVENT_LOG`, phase-timer builds, `ECO_CLOSURE_STATS`.
- `design_docs/invariants.csv`, `docs/options.md`: the rule catalog and the options documentation, both citing plans.
- `examples/benchmarks/`: the user-facing comparison with stock Elm.
- Siblings: [build-system.md](build-system.md), [bootstrap.md](bootstrap.md).
