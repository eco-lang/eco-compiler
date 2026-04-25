# Standardize Stress Tests on a Flag-Driven `Platform.worker` Entry Point

## Problem

Every stress test currently has its `n` and `m` parameters hard-coded as
top-level constants:

```elm
n : Int
n = 1000

m : Int
m = 1000
```

The C++ stress-test runner already accepts `-n` / `-m` CLI flags and threads
them into `Elm.Platform.StressFlags`, but only one test
(`ListReverseStressTest`) actually consumes them — via `StressHarness.program`.
All other tests ignore the flags and recompile any time `n` or `m` should change.

We want every stress test to:

1. Take its `n` (cycle count) and `m` (size knob) from `StressFlags`.
2. Use a uniform `Platform.worker`-based entry point.
3. Self-verify its result and emit a single canonical line — so the framework's
   `-- CHECK:` comparator stays robust when `n`/`m` are changed at the CLI.

## Goals

- One uniform entry-point shape across all 98 stress tests.
- Top-level `n` / `m` / `loopCount` constants disappear; they become `let`
  bindings inside a `run` function that takes `flags : StressFlags`.
- A single canonical output line: `<TestModule>: True/False`. CHECK lines
  become `-- CHECK: <TestModule>: True`, identical across all tests.
- **The C++ runner's `-n` / `-m` / `--timeout` / `--seed` values reach the
  Elm side as `flags.numLoops`, `flags.maxSize`, `flags.timeoutMs`, and
  `flags.seed` respectively.** The plumbing for this already exists
  (`StressFlags` → `setPendingFlags` → `Platform.worker init flags`) and
  is exercised today by `ListReverseStressTest`; this plan extends that
  same wiring to all 98 tests.
- No C++ changes — the runner already plumbs flags end-to-end.
- Default behaviour (`-n 1000 -m 1000`) preserves current pass/fail and timing
  characteristics.
- **Wall-clock timeout (`flags.timeoutMs`) overrides the loop count when set.
  When `timeoutMs > 0`, each test ignores its derived `loopCount` and instead
  loops until the wall-clock deadline is reached, returning whatever verdict
  the partial run produced.**

## Non-goals

- Changing the C++ runner.
- Re-tuning per-test divisors. The current `loopCount = n // K` numbers are
  preserved; only their syntactic location changes.
- Touching `RecordUpdateRowPoly` (a small correctness probe — not really a
  stress test).
- Touching `ListReverseStressTest` (already uses the harness; will keep
  working unchanged once the harness gains the new entry point).

## Existing infrastructure (already in place)

| Piece | Location |
|---|---|
| CLI flag parsing (`-n`, `-m`, `--seed`, `--timeout`, …) | `test/stress-elm/main.cpp` |
| `Elm::Platform::StressFlags` C++ struct → Elm record | `Elm.Platform` |
| Per-run flag injection (`platform.setPendingFlags(*flags)`) | `test/ElmE2ETestBase.hpp:489` |
| `StressHarness.program` (sync `seed`/`step`/`check`) | `test/stress-elm/src/StressHarness.elm` |
| Recompile-on-change cache logic | `test/ElmE2ETestBase.hpp` |

### How the C++ runner already plumbs `-n` / `-m` to the Elm side

The path is intact end-to-end and is the contract this plan relies on:

1. `main.cpp` parses `-n / --num-test-loops` into `config.num_test_loops`
   (default 100) and `-m / --max-size` into `config.max_size` (default 100),
   plus `--timeout` into `config.timeout`.
2. `main.cpp` builds an `Elm::Platform::StressFlags` record:
   ```c++
   stressFlags.numLoops  = config.num_test_loops;
   stressFlags.maxSize   = config.max_size;
   stressFlags.timeoutMs = config.timeout.has_value()
                              ? static_cast<int64_t>(config.timeout->count() * 1000)
                              : 0;
   stressFlags.seed      = static_cast<int64_t>(config.seed);
   stressFlags.startMs   = 0;     // populated to wall-clock start at run time
   stressFlags.verbose   = config.verbose;
   ```
   and hands it to `buildStressElmTestSuite(stressFlags)`.
3. `ElmE2EParallelTestSuite` stores `stressFlags_` and, for each MLIR run,
   passes it via `runElmTestFromMlir(mlirPath, elmPath, flagsPerRun)`.
4. `runElmTestFromMlir` calls
   `Elm::Platform::PlatformRuntime::instance().setPendingFlags(*flags)`
   immediately before invoking the JIT. The `Platform.worker` instance
   reads those pending flags as its `flags` argument when its `init`
   function runs.

That means **today** any `Program StressFlags Model Msg` in the stress-test
directory automatically receives the CLI `-n` / `-m` / `--timeout` /
`--seed` values in its `init flags` parameter — no further C++ work is
required. `ListReverseStressTest` is the existence proof. The only reason
the rest of the suite ignores them is that those tests declare
`Program () Model Msg` (or no `Program` at all, just `Html.text`).

This plan therefore reduces to: change every test's `main` to declare
`Program StressFlags Model Msg` and consume the values that are already
arriving on the wire. **No `main.cpp`, `ElmE2ETestBase.hpp`,
`PlatformRuntime`, or `EcoRunner` change is needed.**

`StressFlags` shape (already defined):

```elm
type alias StressFlags =
    { maxSize   : Int   -- M, "size" knob (-m)
    , numLoops  : Int   -- N, cycle count (-n)
    , seed      : Int
    , startMs   : Int
    , timeoutMs : Int
    , verbose   : Bool
    }
```

## Design: extend `StressHarness` with `taskProgram`

We add a single new entry point that subsumes both the synchronous and
Task-based test shapes. Tests do their own internal loop using `flags.numLoops`
and `flags.maxSize`; the harness only handles plumbing.

```elm
-- New entry point
taskProgram :
    { label : String
    , run   : StressFlags -> Task Never Bool
    }
    -> Program StressFlags Model Msg
```

The harness calls `run flags` exactly once and emits

```
<label>: True
```

(or `False`) via `Debug.log label ok`. The C++ runner's CHECK matcher then
needs only `-- CHECK: <label>: True`.

The existing `program { label, seed, step, check }` API stays — it is just an
internal convenience for tests with a pure synchronous shape; under the hood
it now delegates to `taskProgram` so we have a single Task-driven core.

### Timeout-driven looping

The harness exposes a small helper that every test uses for its outer loop:

```elm
-- Loop a Task until the count is exhausted *or* the wall-clock deadline
-- is reached, whichever comes first. When `flags.timeoutMs == 0` the
-- deadline check is skipped and the count alone governs termination.
loopWhile :
    StressFlags
    -> Int                          -- iteration budget (loopCount)
    -> (Int -> Task Never Bool)     -- one cycle, given the iteration index
    -> Task Never Bool
```

Semantics:

- If `flags.timeoutMs == 0`, behaves exactly like the existing
  `repeatCycle loopCount` helpers — runs `count` iterations.
- If `flags.timeoutMs > 0`, the iteration budget becomes effectively
  unbounded (e.g. `Int / 4`) and the loop terminates when
  `Time.now - flags.startMs >= flags.timeoutMs`.
- In both modes, returns `False` immediately if any cycle returns `False`
  (preserves fail-fast).
- The polling cadence: check `Time.now` once per iteration. For very
  short cycles this is fine; tests whose single-cycle cost is sub-millisecond
  can opt to check every K-th iteration via a second helper
  `loopWhileEvery : StressFlags -> Int -> Int -> (Int -> Task Never Bool) -> Task Never Bool`
  (the extra `Int` is the polling interval). The synchronous-test
  driver calls this for free.

For purely synchronous tests, the equivalent is built on `Task.succeed`
internally — no Time.now overhead between iterations, but the deadline is
sampled at iteration boundaries via the same `loopWhile` plumbing.

The C++ runner passes `flags.startMs` (already populated to the run start)
and `flags.timeoutMs` (already wired from the existing CLI flag). No C++
change is required.

### Why one shape, not three (sync / Task / Spawn)?

Spawn-based tests (`SpawnFanout` etc.) currently use `Platform.worker`'s
`update` messaging only because they need a `Process.sleep` after spawning to
let fibers drain. That can be expressed inside a single Task chain:

```elm
spawnAll
    |> Task.andThen (\_ -> Process.sleep settleMs)
    |> Task.andThen (\_ -> verify)
```

So all three families collapse to "a `Task Never Bool`". One harness entry
point covers them all.

## The migration template

### Synchronous tests (Array/List/Dict/Bytes/Json/Char/Closure/Maybe/Multi/Nested/PartialApp/RecordUpdate/Result/Set/String/TailRec/Tree/Tuple/Mixed/DeepTree/DiagBytes/JsonRoundtripNestedTree)

**Before:**

```elm
module ArrayConcatMap exposing (main)

-- CHECK: result: True

import Array exposing (Array)
import Html exposing (text)


n : Int
n = 1000


m : Int
m = 1000


loop : Int -> Bool -> Bool
loop count ok =
    if count <= 0 then ok
    else
        let
            original = Array.initialize m (\i -> i + 1)
            expanded = concatMap (\x -> Array.fromList [ x, x + m, x + m * 2 ]) original
            len = Array.length expanded
        in
        loop (count - 1) (ok && len == m * 3)


main =
    let
        result = loop n True
        _ = Debug.log "result" result
    in
    text "done"
```

**After:**

```elm
module ArrayConcatMap exposing (main)

-- CHECK: ArrayConcatMap: True

import Array exposing (Array)
import StressHarness exposing (StressFlags)
import Task


loop : Int -> Int -> Bool -> Bool
loop size count ok =
    if count <= 0 then ok
    else
        let
            original = Array.initialize size (\i -> i + 1)
            expanded = concatMap (\x -> Array.fromList [ x, x + size, x + size * 2 ]) original
        in
        loop size (count - 1) (ok && Array.length expanded == size * 3)


run : StressFlags -> Task.Task Never Bool
run flags =
    Task.succeed (loop flags.maxSize flags.numLoops True)


main : Program StressFlags StressHarness.Model StressHarness.Msg
main =
    StressHarness.taskProgram
        { label = "ArrayConcatMap"
        , run = run
        }
```

### Tests with a derived divisor

Tests that previously had `loopCount : Int = n // K` move the divisor into
`run` and feed it through `loopWhile` so the timeout can override:

```elm
run : StressFlags -> Task.Task Never Bool
run flags =
    let
        loopCount = flags.numLoops // 4
    in
    StressHarness.loopWhile flags loopCount (\_ ->
        Task.succeed (oneCycle flags.maxSize))
```

When `flags.timeoutMs > 0` the explicit `loopCount` is treated as an
upper bound only and the deadline takes over.

The divisor table from the previous refactor is preserved verbatim
(see "Per-test divisor table" below).

### Task-based tests (MVar*, Modify*, MVarHolding*, TaskAndThen*, TaskSequenceMassive)

`run` returns the existing Task chain directly. Outer cycle wrapping
(the `repeatCycle loopCount` helper from the previous refactor) is replaced
by `StressHarness.loopWhile`:

```elm
run : StressFlags -> Task.Task Never Bool
run flags =
    let
        loopCount = flags.numLoops // 100
        cycle _ = singleCycle flags  -- existing Task.Task Never Bool, parameterized on flags
    in
    StressHarness.loopWhile flags loopCount cycle
```

`loopWhile` handles both fail-fast and the timeout-overrides-count rule
uniformly, so individual tests no longer need to write their own
`repeatCycle` recursion.

### Spawn-based tests (SpawnFanout, SpawnGCChurn, SpawnThenAndThenChain)

The current `Platform.worker` handles `Spawned` → `Process.sleep` →
`AllDone` → `Debug.log "done"`. Refactor into a single Task driven by
`loopWhile`:

```elm
run : StressFlags -> Task.Task Never Bool
run flags =
    let
        loopCount = flags.numLoops // 100   -- or // 1000 per the divisor table
        oneRound _ =
            spawnAll flags.maxSize
                |> Task.andThen (\_ -> Process.sleep 500)
                |> Task.map (\_ -> True)
    in
    StressHarness.loopWhile flags loopCount oneRound
```

(Spawn tests' verification is currently a textual `"done"` log — under the
new convention they emit `True` instead, and any genuine failure mode in
the worker would surface as a runtime error rather than `False`. This
matches what they tested before.)

Under timeout mode, `loopWhile` keeps re-running `spawnAll` until the
deadline; this is the natural way to keep the scheduler under load for a
soak test.

## Per-test divisor table (preserved from current state)

| Test | `loopCount` expression in `run` |
|---|---|
| ArrayZipUnzip, BytesRoundtripFloat32/64, BytesRoundtripInt8/32, BytesRoundtripNestedList, DictFoldRebuild, DictFromArrayToArray, DictFromListToList, JsonRoundtripFloat, JsonRoundtripNullable, ListConcatMap, SetBuildFold | `flags.numLoops // 2` |
| BytesRoundtripInt16Mixed, BytesRoundtripTaggedUnion, BytesRoundtripUIntMixed, DictUnionDiff, JsonRoundtripNestedTree, JsonRoundtripOneOf, JsonRoundtripString | `flags.numLoops // 4` |
| BytesRoundtripMixedRecord, BytesRoundtripString, JsonRoundtripDict, JsonRoundtripIndex, JsonRoundtripKeyValuePairs, JsonRoundtripObject | `flags.numLoops // 8` |
| BytesRoundtripAndThenChain, BytesRoundtripGrowingLoopList, BytesRoundtripListOfMaybeRecords, BytesRoundtripListOfRecords, BytesRoundtripMixedTupleLoopState, BytesRoundtripPapReuse | `flags.numLoops // 20` |
| BytesRoundtripNestedBytes | `flags.numLoops // 30` |
| BytesRoundtripListOfListsOfStrings, BytesRoundtripNestedRecord, ManyLiveMVarsStress, MVarBlockingReadAwaitsPutStress, MVarChanPipelineStress, MVarHoldingClosureStress, MVarHoldingEmbeddedConstantsAcrossGC, MVarHoldingHugeListAcrossGC, MVarHoldingLargeStringAcrossGC, MVarHoldingListOfMaybeAcrossGC, MVarHoldingMVarStress, MVarHoldingNestedRecordAcrossGC, MVarHoldingTaskValueStress, SpawnFanout | `flags.numLoops // 100` |
| DiagBytesString | `flags.numLoops // 200` |
| SpawnGCChurn, SpawnThenAndThenChain | `flags.numLoops // 1000` |
| All others | `flags.numLoops` (no divisor) |

## CHECK-line standardization

Every test's CHECK becomes:

```elm
-- CHECK: <ModuleName>: True
```

Tests that currently rely on the framework comparing a numeric output (e.g.
`seq: 499500` in TaskSequenceMassive, `chain: 1000` in TaskAndThenDeepChain,
`papCapture: 41000` in TaskAndThenPapCapture) move the equality check
**inside** the test:

```elm
run flags =
    Task.sequence (buildTasks flags.maxSize)
        |> Task.map (List.foldl (+) 0)
        |> Task.map (\actual ->
            actual == expectedSum flags.maxSize)

expectedSum size =
    size * (size - 1) // 2
```

This eliminates a class of breakage where varying `m` invalidates a
hard-coded CHECK number.

`Debug.log` the actual numeric value alongside the Bool so failure-mode
debugging is preserved:

```elm
let _ = Debug.log "actual" actual in
let _ = Debug.log "expected" expected in
ok
```

## Migration plan (phased)

### Phase 1 — Harness extension
1. Add `taskProgram` to `test/stress-elm/src/StressHarness.elm`. Internally,
   re-implement existing `program` as a thin wrapper that builds a Task and
   calls `taskProgram`.
2. Port one synchronous test (`ArrayConcatMap`) and one Task-based test
   (`MVarHoldingClosureStress`) by hand.
3. Verify the CLI → flags wiring **end-to-end** by running the pilot tests
   under three CLI invocations and confirming the Elm side observes the
   correct `flags.numLoops` / `flags.maxSize` (e.g. via a verbose
   `Debug.log` of `flags`):
   - `/work/build/test/stress-test -f ArrayConcatMap` (defaults applied)
   - `/work/build/test/stress-test -f ArrayConcatMap -n 100 -m 100`
   - `/work/build/test/stress-test -f ArrayConcatMap -n 5000 -m 5000`
   The pilot tests must use the values they receive — confirm allocation
   counts in GC stats scale linearly with `-n` and `-m`.

### Phase 2 — Mechanical port: synchronous tests
A Python migration script handles the bulk of synchronous tests. For each
test it:

1. Removes top-level `n`, `m`, `loopCount` constants.
2. Replaces references to `n`, `m`, `loopCount` inside loop / generator
   functions with extra parameters (no global mutable scope in Elm — each
   helper accepts `size` / `count` arguments).
3. Removes the existing `Html.text "done"`-style `main`.
4. Adds `import StressHarness exposing (StressFlags)` and `import Task`.
5. Emits a uniform `run flags = ...` and `main = StressHarness.taskProgram { label = "<Module>", run = run }`.
6. Rewrites the `-- CHECK:` line.

Tests where the loop is anything other than `loop ... n True` (e.g.
`loop original n True`, `loop left right n True`, `loop seed n True`) need
manual review and are listed in an "exceptions" set the script reports;
those are hand-edited.

### Phase 3 — Task-based tests
Hand-port each MVar*, Modify*, MVarHolding*, TaskAndThen*, TaskSequenceMassive
test. Pattern: lift the existing `init`'s `task = ...` body into a
top-level `run flags = ...`, threading flag-derived values through.
The existing `singleCycle` / `repeatCycle` shape from the previous refactor
maps directly.

### Phase 4 — Spawn-based tests
Convert `SpawnFanout`, `SpawnGCChurn`, `SpawnThenAndThenChain` from
multi-message `Platform.worker` to single-Task `run`, folding the
`Process.sleep` settle window into the Task chain.

### Phase 5 — Special / left-alone
- `ListReverseStressTest` keeps its existing call to `StressHarness.program`.
  Confirm it still compiles after harness extension.
- `RecordUpdateRowPoly` stays unchanged. (It's not in the parameterized
  pool; debate whether to drop it from the stress suite or leave it as a
  zero-cost smoke test.)

### Phase 6 — Verification
1. Clean `test/stress-elm/eco-stuff/` cache.
2. Run `/work/build/test/stress-test` (default `-n 1000 -m 1000`): all 98
   tests must pass.
3. Run `/work/build/test/stress-test -n 100 -m 100`: all pass; suite total
   should drop to ~30 s.
4. Run `/work/build/test/stress-test -n 5000 -m 5000`: spot-check a handful
   of tests for sane scaling (no test should explode > 5 min).
5. Re-run the per-test timing harness (`/tmp/time_tests.sh`) at default
   parameters to confirm no test crosses 10 s.
6. **Timeout-override smoke test:** run
   `/work/build/test/stress-test --timeout 30s -n 100000 -m 1000` and verify
   that (a) every test finishes near the per-test wall-clock budget rather
   than running for `n=100000` cycles, and (b) the suite still reports
   pass/fail correctly. Also run `--timeout 5s` to confirm short timeouts
   bail out cleanly.

## Risks and mitigations

- **Recompilation cost**: every `.elm` file is touched, so all 98 MLIR caches
  invalidate. Already routine for this codebase; phase 6's clean cache run
  takes ~5 minutes.
- **Hidden shadowing in mechanical ports**: when introducing `flags : StressFlags`,
  any local `flags` variable in a test would shadow it. None observed, but
  the migration script will refuse to rewrite a file that already binds
  `flags` and emit a manual-port flag.
- **Process-based tests timing**: Spawn-based tests rely on `Process.sleep N`
  for fibers to drain. The new Task chain preserves the same sleep value,
  so behaviour is unchanged.
- **CHECK regressions**: tests that previously printed numeric outputs lose
  that output. Mitigation: keep `Debug.log` of the numeric value alongside
  the Bool verdict for failure forensics.
- **`Task.succeed (pure)` and the scheduler**: synchronous tests wrap pure
  computation in `Task.succeed` solely so the harness can drive them
  uniformly. `Task.succeed` does not yield, so there's no behavioural change
  for these tests vs. the current `Html.text "done"` shape.
- **`Time.now` overhead in tight loops**: `loopWhile` consults `Time.now`
  once per iteration whenever `flags.timeoutMs > 0`. For a test whose single
  cycle is sub-millisecond (e.g. `TailRecurse`) the time-syscall cost can
  dominate. Mitigation: tests that opt into `loopWhileEvery k` only sample
  the deadline every `k` iterations. Default to checking every iteration in
  Phase 1; profile and downgrade to `loopWhileEvery` for affected tests in
  Phase 6 if needed.
- **Timeout granularity at iteration boundaries**: a test that has just
  begun a long inner cycle when the deadline arrives still has to finish
  that cycle. This is acceptable — tests' single-cycle cost is bounded by
  per-test design (most cycles are tens of ms). Tests with very long
  cycles (e.g. `BytesRoundtripUIntMixed`) may overshoot a tight timeout by
  a few seconds; document this rather than try to interrupt mid-cycle.

## Out of scope (potential follow-ups)

- Wiring `flags.timeoutMs` into per-test cooperative timeout checks.
- Wiring `flags.seed` so `Gen.*` based tests use a CLI-controlled seed.
- Moving `RecordUpdateRowPoly` to `test/elm-test-rs` or similar, where it
  belongs as a correctness probe rather than a stress test.
- Per-test custom labels / verbosity levels via `flags.verbose`.
