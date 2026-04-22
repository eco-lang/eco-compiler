# Stress-Test CLI Params and Elm Platform.worker Flag Plumbing

## Motivation

Stress tests for the Eco runtime currently come in two flavors:

1. **C++ stress tests** in `test/main.cpp` — use rapidcheck, configured via
   `-n/--num-tests`, `--max-size` (long form only), `--timeout`, `--seed`, etc.
2. **Elm stress tests** in `test/stress-elm/` — a separate binary running
   Elm programs end-to-end. Each test is a standalone Elm program with
   hard-coded iteration counts (`n = 1000`, `m = 1000`, `count = 500`, …).

The two binaries disagree on CLI flags, and the Elm stress tests have no way
to take runtime parameters: if you want a 10× longer stress run, you have to
edit each `.elm` source file. This plan unifies the CLI surface and plumbs
`N`, `M`, and a timeout through to Elm stress programs via
`Platform.worker` flags.

## Goals

- Unify the "how many iterations" and "how large" CLI knobs across both test
  binaries.
- Convert Elm stress tests to `Platform.worker` programs that receive
  `{ numLoops, maxSize, timeoutMs, seed, startMs, verbose }` as `flags`.
- Have each stress test perform one iteration per `update` cycle, checking
  a per-iteration wall-clock timeout against `flags.timeoutMs`.
- Leave room for adding more parameters later without rewriting every test.

## Non-goals

- A general JSON-decoded flags pipeline for arbitrary user-defined flag
  shapes. Eco is native and all stress tests share one flag shape; that's
  the simplification we lean on.
- Changing rapidcheck behavior in `test/main.cpp`. The rename there is
  cosmetic (short-form aliases only).

## Current state

### CLI today

`test/main.cpp`:
- `-n, --num-tests <N>` — rapidcheck `max_success` (default 5).
- `--max-size <N>` (no short form) — rapidcheck `max_size` (default 50).
- `--timeout <TIME>`, `--seed <SEED>`, `--repeat`, `--duration`, `--filter`, …

`test/stress-elm/main.cpp`:
- `-f/--filter`, `-r/--repeat`, `-t/--duration`, `--timeout`, `-v`, `-L`, `-h`.
- No `-n` or `-m`.

### Elm stress tests today

~90 `.elm` files under `test/stress-elm/src/`. Each is a standalone `main`
with fixed constants. Some use `Platform.worker` already (e.g.
`ManyLiveMVarsStress.elm`); others use `Html.text` one-shot programs
(e.g. `ListReverseStressTest.elm`, `BytesRoundtripInt8.elm`). Pass/fail is
signaled by a `-- CHECK:` comment matched against the program's stdout via
`verifyPatterns` in `test/ElmE2ETestBase.hpp`.

### Platform.worker flags wiring

`runtime/src/platform/PlatformRuntime.cpp:432` hardcodes:

```cpp
HPointer flags = unit();
```

Nothing threads values in from the runner. `EcoRunner::Options`
(`runtime/src/codegen/EcoRunner.hpp:81`) only carries `enableOpt` and
`captureOutput`.

### Test execution pipeline

`test/stress-elm/main.cpp` builds an `ElmE2EParallelTestSuite` via
`StressElmTest::buildStressElmTestSuite()`. The suite forks one child per
test and calls `runElmTestFromMlir` (`ElmE2ETestBase.hpp:465`), which
uses a `thread_local EcoRunner` with default options. Each fork is a
clean process boundary, so per-test flag values carry across without
shared-state issues.

## Design

### 1. CLI flags (both binaries)

Add these identically to both `test/main.cpp` and
`test/stress-elm/main.cpp`:

| Short | Long                   | Meaning                                 |
|-------|------------------------|-----------------------------------------|
| `-n`  | `--num-test-loops <N>` | Outer iteration count                   |
| `-m`  | `--max-size <M>`       | Secondary size knob                     |

In `test/main.cpp`:
- `--num-test-loops` replaces `--num-tests` as the canonical long form.
  Keep `--num-tests` as a silent alias for one release.
- `-m` becomes the short form for the existing `--max-size`.

In `test/stress-elm/main.cpp`:
- Both flags are new. Defaults: `-n 100`, `-m 100` (modest so CI is fast;
  crank up with flags for stress runs).

### 2. Shared Elm flag record

All Elm stress tests consume one flag shape:

```elm
type alias StressFlags =
    { numLoops : Int      -- from -n
    , maxSize  : Int      -- from -m
    , timeoutMs: Int      -- 0 = no timeout
    , seed     : Int      -- 0 = platform chooses
    , startMs  : Int      -- wall-clock captured at runner start
    , verbose  : Bool
    }
```

Why fixed shape: no JSON decoder pipeline needed. C++ builds the Elm
`Record*` by hand. `startMs` is pre-populated by the runner so `init`
doesn't need `Task.perform Time.now`.

### 3. Runtime plumbing

**`runtime/src/codegen/EcoRunner.hpp`** — extend `Options`:

```cpp
struct StressFlags {
    int64_t numLoops;
    int64_t maxSize;
    int64_t timeoutMs;
    int64_t seed;
    int64_t startMs;
    bool    verbose;
};

struct Options {
    bool enableOpt = false;
    bool captureOutput = true;
    std::optional<StressFlags> flags;  // nullopt → pass unit()
};
```

**`runtime/src/platform/PlatformRuntime.cpp:432`** — replace the hardcoded
`unit()` with an `HPointer flags` argument. Signature change:

```cpp
HPointer initWorker(HPointer impl, HPointer flags);
```

Callers in `EcoRunner::Impl::runFile` build the `Record*` when
`options.flags` is set, else pass `unit()` (preserves all non-worker and
untouched-test behavior).

Record field order: alphabetical by Elm convention — `maxSize`,
`numLoops`, `seed`, `startMs`, `timeoutMs`, `verbose`. Double-check
against the `Record` layout used by the existing init/update/subscriptions
triple.

### 4. Test-runner plumbing

Thread `StressFlags` through:

1. `StressElmTest::buildStressElmTestSuite(StressFlags)` — take the CLI
   values from `stress-elm/main.cpp`'s `StressConfig`.
2. `ElmE2EParallelTestSuite` constructor — add an optional flags field.
3. `runMlirTestsParallel` / `runElmTestFromMlir` — add a `StressFlags`
   parameter and set it on the runner's options before `runFile`.

The `stress-elm` binary populates `startMs` at the moment the suite
starts; the value is shared across all tests in the run. (Alternative:
populate per-test in the fork, giving each test its own zero-point. Per-test
is cleaner for timeout semantics and costs nothing — go with that.)

The `test/main.cpp` binary does **not** opt in. `Options.flags = nullopt`
means `initWorker` receives `unit()` as today — behavior-preserving for
all existing E2E tests.

### 5. Shared Elm harness

Introduce `test/stress-elm/src/StressHarness.elm` (skipped by
`hasTopLevelMain` in `ElmE2ETestBase.hpp:797` because it has no `main`):

```elm
module StressHarness exposing (Model, Msg, program, StressFlags)

type alias StressFlags =
    { numLoops : Int, maxSize : Int, timeoutMs : Int
    , seed : Int, startMs : Int, verbose : Bool }

type Msg state = Tick | Tock Int  -- Tock carries Time.now

type alias Model state =
    { remaining : Int, startMs : Int, timeoutMs : Int
    , state : state, verdict : Maybe Bool, label : String }

program :
    { label : String
    , seed  : StressFlags -> state
    , step  : StressFlags -> state -> state
    , check : state -> Bool
    }
    -> Program StressFlags (Model state) (Msg state)
program cfg =
    Platform.worker
        { init = init cfg
        , update = update cfg
        , subscriptions = \_ -> Sub.none
        }

-- init/update omitted here; spec below.
```

Per-iteration logic in `update`:

- `Tick` with `remaining <= 0`: compute `verdict = check state`, log
  `<label>: <verdict>`, stop.
- `Tick` with `remaining > 0`: advance `state = step flags state`,
  decrement, schedule `Tock` via `Task.perform Tock Time.now`.
- `Tock now`: if `timeoutMs > 0 && now - startMs > timeoutMs`, set
  `verdict = Just False`, log `TIMEOUT`; else schedule another `Tick`.

The `-- CHECK:` string in each test still drives pass/fail — the harness
just formats the log line consistently (`<label>: True` / `<label>: False`
/ `<label>: TIMEOUT`).

### 6. Per-test migration

Each existing test shrinks to:

```elm
module ListReverseStressTest exposing (main)

-- CHECK: ListReverseStressTest: True

import StressHarness exposing (StressFlags, program)

type alias State = { list : List Int, ok : Bool }

seed : StressFlags -> State
seed f = { list = List.range 1 f.maxSize, ok = True }

step : StressFlags -> State -> State
step _ s = { s | list = List.reverse s.list }

check : State -> Bool
check s = s.ok && s.list == List.range 1 (List.length s.list) ||
          s.list == List.reverse (List.range 1 (List.length s.list))

main = program { label = "ListReverseStressTest"
               , seed = seed, step = step, check = check }
```

For MVar-using tests (`ManyLiveMVarsStress.elm` etc.), `state` becomes a
record containing the MVar handles and the harness `step` returns a
`Task`. That requires a second harness variant
(`programWithTasks`) that threads `Task.perform` through `update`. Add
only when needed.

### 7. Timeout: two layers

- **Elm-level (graceful):** harness samples `Time.now` each cycle,
  bails with `verdict = Just False` when deadline exceeded. State stays
  consistent; `Debug.log` still fires.
- **Process-level (backstop):** existing `TEST_TIMEOUT_SECONDS` +
  `SIGKILL` path in `ElmE2ETestBase.hpp:712`. Set the process kill
  deadline to ~2× the Elm-level timeout so the graceful path wins when
  the test is responsive and the backstop catches infinite loops.

CLI `--timeout` maps to both: passed as `flags.timeoutMs` and used to
widen the process kill deadline.

## Implementation plan

1. **CLI surface**
   - `test/main.cpp`: add `-n` as short alias for `--num-tests`, add
     `--num-test-loops` as new canonical long form, add `-m` as short
     form for `--max-size`. Update `--help`.
   - `test/stress-elm/main.cpp`: add `-n/--num-test-loops`,
     `-m/--max-size`. Store in `StressConfig`.

2. **Runtime plumbing**
   - Define `StressFlags` struct in `runtime/src/codegen/EcoRunner.hpp`.
   - Add `std::optional<StressFlags>` to `EcoRunner::Options`.
   - Change `PlatformRuntime::initWorker` to accept `HPointer flags`.
   - In `EcoRunner::Impl::runFile`, build the `Record*` when
     `options.flags.has_value()`; otherwise pass `unit()`.

3. **Test-runner plumbing**
   - Add `StressFlags` parameter to `runElmTestFromMlir`,
     `runMlirTestsParallel`, and `ElmE2EParallelTestSuite`.
   - Update `StressElmTest::buildStressElmTestSuite` to take a
     `StressFlags`.
   - `test/stress-elm/main.cpp` translates `StressConfig` → `StressFlags`
     and passes it to the suite.

4. **Elm harness**
   - Add `test/stress-elm/src/StressHarness.elm` with `program`,
     `StressFlags`, `Model`, `Msg`.
   - Verify `hasTopLevelMain` filters it out (it has no `main`).

5. **Proof-of-concept migration**
   - Migrate `ListReverseStressTest.elm` to use `StressHarness.program`.
   - Run `cmake --build build --target full` with
     `-n 100 -m 100` and `-n 10000 -m 1000` to confirm the knobs
     actually scale work.

6. **Bulk migration**
   - Migrate the ~90 remaining `.elm` stress tests. Each is mechanical:
     extract `state`/`step`/`check` from the existing `main`.
   - Add `programWithTasks` variant when the first MVar test needs it.

## Tradeoffs

- **Fixed flag shape.** Every test pays for every field; adding a new
  dimension requires coordinated runtime+harness update. Accept this —
  per-test flag shapes would need a decoder pipeline we don't have.
- **`Time.now` per iteration.** Cheap for N in thousands to low millions;
  dominates for N in billions. If that becomes an issue, sample every K
  iterations. Measure on the POC before over-engineering.
- **Two harness variants** (pure `step` vs `step : Task`). Accept —
  simpler than making the pure path pay for `Task.perform`.

## Open questions

- Should `--seed 0` mean "time-based random" on the Elm side (harness
  picks from `startMs`) or "seed is literally 0"? Leaning toward the
  former: explicit randomness when the user doesn't ask for
  reproducibility.
- Do we want the stress harness to emit structured output (JSON) for
  dashboards, or keep the `-- CHECK:` grep contract? Current proposal:
  keep `-- CHECK:`, structured output later if needed.

## Files to touch

- `test/main.cpp` — CLI short-form additions, `--help` text.
- `test/stress-elm/main.cpp` — CLI additions, `StressConfig` → `StressFlags`
  translation, pass into suite builder.
- `test/stress-elm/StressElmTest.hpp` — `buildStressElmTestSuite` takes
  `StressFlags`.
- `test/ElmE2ETestBase.hpp` — thread `StressFlags` through
  `ElmE2EParallelTestSuite`, `runMlirTestsParallel`,
  `runElmTestFromMlir`.
- `runtime/src/codegen/EcoRunner.hpp` / `.cpp` — `StressFlags` struct,
  `Options.flags`, build record in `runFile`.
- `runtime/src/platform/PlatformRuntime.hpp` / `.cpp` —
  `initWorker(impl, flags)` signature.
- `test/stress-elm/src/StressHarness.elm` — new shared harness module.
- `test/stress-elm/src/*.elm` — per-test migration (~90 files).
