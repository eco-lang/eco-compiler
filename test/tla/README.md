# TLA+ models of the threaded GC

Model checks of the garbage collector's concurrent protocols. The plan is
`plans/threaded-gc-tla-verification.md`. **Read `plans/threaded-gc-tla-primer.md` first** if TLA+,
PlusCal or the GC terms are new. Every defect a model finds goes into
`plans/threaded-gc-concurrency-register.md`.

## Running

```bash
cmake --build build --target tla-check 2>&1 | tee /tmp/test_output.txt       # quick tier
cmake --build build --target tla-check-deep 2>&1 | tee /tmp/test_output.txt  # deep tier (long)
cmake --build build --target tla-trace 2>&1 | tee /tmp/test_output.txt       # trace validation
```

As with every suite in this repo (CLAUDE.md), run it **once** and read the output file. TLC logs
are kept in `build/tla-logs/<tier>/`, one per configuration, counterexamples included.

For one model or one configuration while working on it:

```bash
test/tla/run_models.py --model M1                       # every quick configuration of M1
test/tla/run_models.py --model M1 --config mutants/     # only its mutants
test/tla/run_models.py --tier deep --model M1 --list    # what the deep tier would run
```

Apalache rows (the deep tier) also need `apalache-mc` on PATH. To run only the lemma, with more
checks at once: `test/tla/run_models.py --tier deep --config lemma/ --jobs 10`.

Tools: `java` on PATH and `tla2tools.jar`, found through `--jar`, `$TLA2TOOLS_JAR` or
`$TLA_TOOLS_DIR/tla2tools.jar`. The dev image (`docker/eco-dev.Dockerfile`) has both: the jar is
vendored at `docker/vendor/tla2tools.jar` (TLC 2026.09.25, rev 8f4bc8b) and the rest are pinned
downloads. Images built with `--build-arg INSTALL_TLA=0`, as GitHub CI's are, have neither.
The targets fail with a clear message when the tools are missing; they never skip.
`-DECO_TLA=OFF` leaves them undefined.

## What `tla-check` checks

For each model directory in `models.txt`:
1. **SANY** parses every module. The runner fails on SANY's error *text*, because SANY exits 0
   even when it reports errors.
2. **Translation freshness**: every PlusCal module is re-translated in a scratch copy, and the
   committed translation must be identical.
3. **TLC** runs every configuration of the tier, in a scratch copy of the directory, and its
   outcome must be the one `models.txt` expects:
   - `pass`;
   - `violates:<Invariant>` (a mutant, or a register entry reproduced before its fix);
   - `deadlock`;
   - `witness:<Invariant>` (a configuration that fails on purpose to show a state is reachable,
     e.g. M7's stall witness; judged exactly like `violates:`).

   A mutant that passes, or fails for another reason, fails the check. So does a configuration
   that hits the time limit.

On a shared machine, cap each TLC's heap with `--java-opts=-Xmx4g` (or `$ECO_TLA_JAVA_OPTS`), and
choose `--jobs` / `--workers` so that their product fits the cores.

## Layout

```
test/tla/
  README.md          this file
  CMakeLists.txt     the tla-check, tla-check-deep and tla-trace targets
  models.txt         registry: model, directory, module, config, tier, tool, expected outcome
  run_models.py      the runner
  manifest.txt       the canary's pins (below, "The canary"); footprint-greps.txt: its greps;
  census/            the text each census and grep pin hashes
  traces.txt         trace-validation registry: harnesses, and trace rows (below)
  run_traces.py      the trace-validation runner (builds and runs the harnesses, merges, runs TLC)
  common/            modules shared by the models, copied next to a model's modules for SANY/TLC
    TraceLog.tla         reads a merged trace (Json): the log, its header, counts, progress
    TraceInOrder.tla     match the events in log order (counter tl; invariant TLUnmatched)
    TraceAnyOrder.tla    match them in any order the log allows (tpos; invariant TPUnmatched)
  trace/
    TlaTrace.cpp         the recorder behind runtime/src/allocator/TlaTrace.hpp (trace builds only)
    merge_trace.py       per-thread raw logs -> one interleaving with vector clocks (--selftest)
  toy-lostbit/       the primer's LostBit: proves the targets end to end (one pass, one mutant)
  M1-snapshot-mark/  M1: the snapshot mark cycle (plans/threaded-gc-tla-M1-snapshot-mark.md)
    SnapshotMark.tla     PlusCal source and its committed translation
    MC.tla               the starting heap (constants a .cfg cannot write)
    MC_quick*.cfg        quick-tier configurations
    MC_deep*.cfg         deep-tier configurations
    mutants/*.cfg        negative controls, one per mutant, each listing only its target
    SnapshotLemma.tla    the snapshot-closure lemma as an inductive invariant, for Apalache
    lemma/*.args         Apalache rows: base case, one inductive step per action, IM2, a
                         negative control (deep tier; about an hour for the slowest step)
    TraceCycle.tla/.cfg/.keep  trace (a): the cycle projection of the real allocator's runs
    TraceHeap.tla/.cfg/.keep   trace (b): the tiny graph, every scan and liveness decision
    MAPPING.md           model <-> code: variables, steps, abstractions, footprint rows, invariant ids
    AUDIT.md             dated log: results, counterexamples, every re-audit
  M2-slice-control/  M2: runMarkerLoop, tickets, termination (SliceControl.tla; TraceSliceControl
                     on gc-mark-trace)
  M3-minor-forwarding/ M3: claim -> BUSY -> publish forwarding, phase 6 and 7b (MinorForwarding.tla;
                     TraceMinorForwarding on gc-minor-trace)
  M4-promotion-bitmap/ M4: promotion chunks, the stash, sweep slices, the mark bitmap at byte and word
                     granularity with a race detector (PromoBitmap.tla; controls/ holds the fix
                     candidates; TracePromoBitmap on gc-heap-trace promo; TraceRace.cfg by hand)
  M5-tenuring/       M5: 7b/7c concurrent tenuring and 07b ageing (plans/threaded-gc-tla-M5-tenuring.md)
    Tenuring.tla         PlusCal source and its committed translation (the core; builders, YLOS
                         and k = 2 extensions switched by constants)
    MC.tla               extends the model (every constant is set by the .cfg files)
    MC_*.cfg             quick and deep configurations, CR-017 / CR-013 / CR-034 reproductions
    mutants/*.cfg        negative controls, one per mutant, each listing only its target
    controls/*.cfg       CR-034's fix candidates (the YlosGen / LbKey constants)
    TraceTenuring.tla/.cfg/.keep     trace (a): the engine storm (gc-tenure-trace), event by event
    TraceTenurePause.tla/.cfg/.keep  trace (b): the pause projection of the real allocator's
                                     region nursery (gc-heap-trace tenure)
    MAPPING.md, AUDIT.md as for M1
  M6-lifecycle/      M6: helper pool, gangs, fork and exit (HelperPool.tla, Gangs.tla; TracePool on
                     gc-pool-trace, TraceGangs on gc-fork-trace; the fork harness is
                     test/gc-heap-tsan/fork_harness.cpp)
  M7-pagework/       M7: deferred decommit, commit-ahead (PageWork.tla) and the lock order
                     (LockOrder.tla); TracePageWork on gc-helper-trace
  M8-block-lifecycle/ M8: the old generation's block lifecycle, serial (BlockLifecycle.tla):
                     release and re-creation at the same start, live_bytes / fully_swept, the
                     flip, the shrink, the gap sweep, the bag rung, large_body_index_ and young
                     large objects (CR-018, CR-033, CR-035); CovMC.tla + coverage.cfg by hand
```

Every model directory has the same parts as M1: the PlusCal module and its translation, `MC.tla`,
quick and deep configurations, `mutants/`, the trace specs, `MAPPING.md` (with a generated
"Canary pins (A9)" block at the end) and `AUDIT.md`. The weak-memory drivers are in `test/genmc/`
(`genmc-check`, `test/genmc/AUDIT.md`).

## Working on a model

- **Edit the PlusCal, never the translation.** Re-translate in a scratch copy and copy it back:
  `cp SnapshotMark.tla /tmp/x/ && (cd /tmp/x && pcal -nocfg SnapshotMark.tla) && cp /tmp/x/SnapshotMark.tla .`
  (`pcal` writes a `.old` backup next to the file it translates).
- **Every checked property is a named invariant**, never a PlusCal `assert`: the runner matches
  mutants by invariant name.
- **Every invariant has a mutant** (rule A6). A mutant's configuration lists only its target
  invariant, and its plan row carries the shortest violating behaviour. Read the counterexample in
  the log and check it is the intended story, not another path to the same invariant.
- **Keep quick configurations quick** (about two minutes each at most). Split along a contract, or
  move breadth to the deep tier, rather than raise the bounds.
- **Record every result and every change of verdict in the model's AUDIT.md**, and every defect
  in the register.

## Trace validation (`tla-trace`)

A model can pass and still describe another program. Trace validation checks real runs of the code
against the model (parent plan §6.3, rule A5; primer §6). The code logs events at its protocol
points, a merger interleaves the threads' logs, and TLC looks for a behaviour of the model that
matches the whole log. A log that no behaviour matches is a finding: a code defect (the register)
or a model error (fix the model, and write an AUDIT.md entry). M1's two traces are the worked
example (`M1-snapshot-mark/TraceCycle.tla`, `TraceHeap.tla`; M1's MAPPING.md §10).

```bash
cmake --build build --target tla-trace 2>&1 | tee /tmp/test_output.txt
test/tla/run_traces.py --model M1 --jobs 2 --workers 2 --java-opts=-Xmx3g    # by hand
test/tla/run_traces.py --row tiny --list                                     # what would run
```

The target builds each harness in its trace build under `build/tla-trace/<harness>`, runs it,
merges its log, and runs TLC; logs, raw traces and merged traces are kept in
`build/tla-logs/trace/`. Budget: 15 minutes (M1's 18 rows take under a minute once the harness is
built; the first build of the allocator takes one or two). It needs `cmake`, `ninja` and `g++`
besides Java; a missing tool fails the run with a message.

**1. Hooks.** `ECO_TLA_TRACE("ev", "key", value, ...)` (`runtime/src/allocator/TlaTrace.hpp`)
expands to `((void)0)` unless the file is compiled with `-DECO_TLA_TRACE=1`, so production code,
counters and behaviour are unchanged. In a trace build it appends one event to the calling
thread's buffer. Its arguments are evaluated only when the event is recorded, but must still have
no side effects.
- Values: integers, enums, bools, string literals; `Elm::tlatrace::obj(p)` (an object, logged as the
  harness's id for it, else its address); `Elm::tlatrace::key(prefix, a[, b])` (a string key).
- `ECO_TLA_TRACE_ONLY(stmt)` is a statement that exists only in trace builds (naming a thread,
  binding a serial, a harness probe). Code that must know whether it is in a trace build tests
  `ECO_TLA_TRACE_ENABLED`.
- Field names `t`, `s`, `ts`, `ev`, `i`, `n`, `vc`, `nxt`, `pk` are reserved.
- Already in the tree, for every model to reuse: the gangs' ordering events (`gang.launch`,
  `gang.start`, `gang.exit`, `gang.join`, `gang.run`, `gang.runEnd` in `GCHelperPool.cpp`, with
  the put/get keys below), M1's cycle events, and M1's `grey` / `scan`.

**2. Recording.** A trace harness links `test/tla/trace/TlaTrace.cpp`. It calls
`tlatrace::begin(header_json, keep)` and `tlatrace::end()` while no other thread logs (between
collections); `end()` writes the raw log to `$ECO_TLA_TRACE_OUT`: a header line, then each thread's
events with a per-thread sequence number `s` and a steady-clock `ts`. `keep` limits recording to
some event names (`"gang."` stands for a prefix), which keeps logs of big heaps small. Also:
`nameThread` (the name a thread logs under), `setObjId` (how `obj(p)` becomes an id), `setProbe`
(a harness callback that `probe("where")` hooks call inside a pause) and `bind` / `bound` (serials
that two threads agree on). A thread's buffer is registered under a lock at its first event of a
trace, so trace builds are never TSan builds (parent plan §6.3, trap 5).

**3. Merging** (`trace/merge_trace.py RAW -o OUT [--keep-file F]`; `--selftest`). It builds one
interleaving of all threads that respects:
- each thread's order (`s`);
- publications: an event with `"get": k` follows every event with `"put": k` (a launch and the
  members it starts, an exit and the join that waits for it, a push and the scan of the entry);
- modification order: the RMWs of one location (`"rmw": loc, "old": v, "new": w`) chain by value,
  each one's `old` being the previous one's `new`; the first `old` is inferred (or given in the
  header's `locinit`);
- reads-from: a load (`"rd": loc, "val": v`) sits after the write of `v` and before the next write;
- clocks: events with `"clk": c` are ordered by `"tick"` (a counter taken under a lock, or a
  global seq_cst counter in a trace build).

Where these leave the order open, the smaller `ts` goes first (a hint only). Where values repeat
(ABA) the merger backtracks until one chain fits every constraint, and uses it. A cycle, or RMWs
that do not chain (an unlogged write of that location), is an error. The merged log's header gains
`threads`, `tev` (each thread's event indices), `count` and `counts` (events per name); each event
gains `i` (its index), `n` (its index in its thread), `vc` (a vector clock: `vc[v]` of thread v's
events must precede it), `nxt` (the next event name on its thread) and `pk` (each thread's next
event at or after it). A `<Module>.keep` file next to the trace spec lists the events to keep; the
rest are dropped after the order is computed, so orderings through them survive in `vc`.
Integers beyond TLC's 32 bits become strings.

**4. The trace spec.** `Trace<Name>.tla` EXTENDS the model and one of `common/TraceInOrder.tla`
(events matched in the merged order; one counter `tl`) or `common/TraceAnyOrder.tla` (any order
the vector clocks allow; one counter per thread, `tpos`: this is "where the order is ambiguous,
the trace spec admits either order"). It defines:
- `Matched(e)` (in order) or `Matched(u, e)` (any order): for each event, the one model step it
  is (the model's action, constrained by the event's fields), or a check on the state that changes
  nothing; `OTHER -> FALSE`, so an event nobody expected rejects the trace;
- `Hidden`: the model steps the code does not log (control steps, decisions logged elsewhere,
  internal loops). Decide every label: matched, hidden, or never;
- `TraceInit == Init /\ TLInit` (or `TPInit`) and
  `TraceNext == TLMatch(Matched) \/ (Hidden /\ UNCHANGED tl)` (or `TPMatch`, `tpos`).

Constants come from the log: header fields (`TraceHdr.T`) and `TraceCount("ev")`. The log is
`trace.ndjson` next to the spec (the runner puts it there) or `$ECO_TLA_TRACE_FILE`.

**5. Acceptance.** The `.cfg` lists one invariant, `TLUnmatched` or `TPUnmatched` ("some event is
still unmatched"). TLC reporting it **violated** means a behaviour matched the whole log: the
trace is **accepted**. TLC finishing with **no error** means no behaviour matches it: the trace is
**rejected**; the runner then prints how far the best behaviour got (the spec's `TRACE-PROGRESS`
lines) and the events after it. Anything else (a parse error, a timeout, a harness or merge
failure) is an error.

**6. Negative controls.** A row with `mutate=` doctors the raw log before the merge and must be
rejected: a trace spec that accepts a doctored log has no teeth at that point (rule A6, for
traces). `drop:<ev>:<k>` deletes the k-th `ev` event (time order), `set:<ev>:<k>:<field>=<json>`
changes a field, `swap:<ev>:<k>` swaps it with the next event of its thread. The logs depend on
the schedule, so choose mutations whose rejection does not (an impossible value, a missing step).

**The registry** (`traces.txt`):
```
harness <name> <source dir> <cmake target>
trace <model> <dir> <module> <config> <harness> <args,comma-separated> <accept|reject> [mutate=<m>]
```
A harness line names a CMake project with an `ECO_TLA_TRACE` option; the runner configures it with
`-DECO_TLA_TRACE=ON -DCMAKE_CXX_COMPILER=g++` and builds the target. Each distinct harness
invocation runs once, and its rows (the `accept` row and the negative controls) share its log.

**Adding a model's trace validation:**
1. **Hooks** at the protocol points of the model's A5 list: `ECO_TLA_TRACE` calls, compiled out.
   Log the values an RMW observed and wrote (`rmw`/`old`/`new`) on shared words, the value a
   racing load read (`rd`/`val`), and `put`/`get` keys for publications the gang events do not
   already give. Build the production runtime afterwards (e.g. `EcoRuntimeStatic`) to confirm it
   still compiles.
2. **A harness scenario** in its trace build: the harness's CMakeLists builds a separate target
   when `-DECO_TLA_TRACE=ON` (`-DECO_TLA_TRACE=1`, `trace/TlaTrace.cpp` linked, no TSan; see
   `test/gc-heap-tsan/CMakeLists.txt`). Its `main` runs a named scenario between `begin()` and
   `end()`, small enough for TLC (hundreds to a few thousand events), and writes the constants
   the spec needs into the header. Check the raw log with `trace/merge_trace.py`.
3. **The spec**: `Trace<Name>.tla`, `Trace<Name>.cfg`, and `Trace<Name>.keep` if the log has
   events the spec does not match, in the model's directory.
4. **Rows** in `traces.txt`: the harness line (once), `accept` rows, and a `mutate=` row for each
   check that matters.
5. **Run** `test/tla/run_traces.py --model <Mn>` a few times (the logs vary from run to run; every
   run must be accepted), then record the rows and results in AUDIT.md and the A5 row in
   MAPPING.md. A rejection is a finding: decide model error or code defect before anything else.

**Traps met while building M1's traces:**
- A `<-` bound in the `.cfg` that TLC evaluates over the whole log (a set comprehension) is
  recomputed and made the initial states take 25 s; `TraceCount` reads the header's counts.
- A model loop bounded by the log's count (M1's `MaxMinors`) stops before the log's last events:
  add one.
- Do not assume a model step can stop when the code's can: M1's assist could not stop with work
  left, and trace (a) rejected real runs until the model was fixed (M1 AUDIT.md).
- A harness's own observation must be exact: "unreachable and not marked" is not "freed" outside
  a cycle (the bitmap is not the allocation record then), so M1's driver reads the marks with a
  probe at the tail, where they are the liveness decision.

## The canary (`tla-canary`, GC_MODEL_001)

A model that passes says nothing once the code it describes has changed. The canary pins the code
each model covers, and fails the build when that code changes (parent plan §7). It runs in `ALL`
(every `cmake --build build`), needs only `sh`, `awk` and `sha256sum`, and takes about a second.

**Files:**
- `manifest.txt`: one pin per line, `<kind> <sha256> <path> <id> <models>`:
  - `file`: a whole file, byte for byte (small protocol headers such as `MarkWork.hpp`);
  - `region`: the code between `// TLA-REGION(<id>) begin` and `// TLA-REGION(<id>) end`, with
    `//` comments stripped and whitespace collapsed (a function inside a large file);
  - `census`: every line of a file that matches the concurrency regex (atomics, memory orders,
    RMWs, fences, mutexes, locks, `std::thread`, `pthread_atfork`), comments stripped, sorted. It
    catches a new atomic or lock even where no region was edited;
  - `grep`: a footprint row's re-derivation grep (`footprint-greps.txt`), for plain shared fields
    such as `region_end_ =` that the census cannot see;
  - `nocode`: a model with no code to pin (the toy).
- `footprint-greps.txt`: footprint row id → path globs → grep. The rows are the phase plans'
  shared-state audits: H1–H15 (05c), P6.M1–P6.M15 (06), T1–T11 (07).
- `census/`: the text each `census` and `grep` pin hashes, so a failure prints the added and
  removed lines.

**What it checks:** the hashes; that every `TLA-REGION` marker in `runtime/src` and
`elm-kernel-cpp/src` is pinned (and every pinned region exists); that every model in `models.txt`
(and every W driver family in `test/genmc/drivers.txt`) has a pin, and every pin names a known
model; that every footprint row appears in some model's MAPPING.md; and that every allocator file
with a concurrency line has a census pin.

**When it fires** (the message lists the pins, their models and the new hash prefixes):
1. Read the change. Does it add, remove or reorder an atomic step, a lock, a shared location or a
   memory order? Does it touch a footprint row?
2. Check each affected action and variable in the named models' MAPPING.md. If a model no longer
   matches, update the spec and MAPPING.md, and run `tla-check` (and `tla-trace` for a traced
   path).
3. Add an AUDIT.md entry to **each** named model (for W1–W5, `test/genmc/AUDIT.md`): the date, what
   changed, the verdict ("no model change needed" is a fine verdict; a missing one is not), and the
   new hash prefix (12 hex digits).
4. Only then: `test/scripts/check-tla-manifest.sh . --update`. It **refuses** while a named model's
   AUDIT.md does not quote the new prefix.

A defect found on the way goes into the register. **The build target is warn-only by default**
while the TLA+ work is young: a failing canary prints its report and a WARNING banner, the build
continues, and the check re-runs on every build until it passes. Configure with
`-DECO_TLA_CANARY_STRICT=ON` to make it fail the build (gates, CI and merges should). Run by hand,
the script is strict unless `ECO_TLA_CANARY=warn` is set.

**Adding a pin:** put the markers in the code, add the line with `-` as its hash, and run
`--update`, which fills in new hashes without asking for an audit entry. A new marker in a file
the build does not already depend on needs a CMake reconfigure. List the pin in the model's
MAPPING.md "Canary pins (A9)" block too.

**Footprint rows vs canary greps.** Rows named `H*`, `P6.M*` and `T*` are the phase plans'
shared-state audit rows: each must appear in some model's MAPPING.md **outside** the generated
"Canary pins" block, as a variable or a written abstraction (check 4). Rows named `F.*` are
canary greps only (for example `F.atfork`, `F.vnodeRegistry`: a new `pthread_atfork` call, or a
latent unregistered store, needs a verdict) and are exempt from that check.

**First pinned 2026-09-29:** 224 pins (16 files, 128 regions, 25 censuses, 54 greps, the toy's
`nocode`), covering M1–M7 and the drivers W1–W5, `w_pool_done`, `w_running_chain`.
