# Testing

All targets below are invoked as `cmake --build build --target <name>` against
a tree configured with the `build` preset (see [building.md](building.md)).

## 1. Elm compiler tests (`elm-tests`)

The Elm-side unit tests for the compiler, run via `elm-test-rs`. They cover the
front end (parse, canonicalize, type), the middle end (local and global
optimization, monomorphization) and MLIR generation (`compiler/tests/`):

```bash
cmake --build build --target elm-tests
```

The target shells out to the CMake-fetched `elm-test-rs` binary against the
build-tree shadow root. To run it manually with custom flags (e.g. higher fuzz,
a specific test file):

```bash
PATH="$PWD/build/toolchain/bin:$PATH" \
    build/toolchain/bin/elm-test-rs \
        --project build/compiler/build-xhr \
        --fuzz 1
```

`elm-test-rs` discovers the `elm` compiler via `PATH`, hence the prefix.

`eco-system-elm-tests` runs the pure-Elm tests of the `eco/system` package
(`system-kernel-cpp/tests`) the same way.

## 2. End-to-end tests (`full` / `check`)

The E2E suite covers the C++ runtime (GC, allocator, kernel ops), MLIR codegen,
and Elm end-to-end tests (compile Elm → MLIR → JIT), including the `eco/system`
suite (`test/eco-system`).

`check` and `full` first run static source checks
(`test/scripts/check-root-bounded.py`, `check-large-body-access.sh`, and for
`full` also `check-kernel-homes.sh`). `full` then also builds and runs
`eco-system-core-test`, compiles the `eco-system-examples`, and (except on
Windows) runs `run-js-e2e`, the eco-system suite on the JS target.

```bash
# Full clean rebuild + run E2E tests — use after compiler changes.
cmake --build build --target full

# Incremental build + run E2E tests.
cmake --build build --target check

# Run the E2E tests without rebuilding.
cmake --build build --target run-tests
```

> Prefer `full` after any Elm/MLIR change: it cleans first, so it never
> consumes stale `.mlir` files. Reserve `check` for changes that are purely
> C++ with no MLIR regeneration.

Filter by test name with `TEST_FILTER`:

```bash
TEST_FILTER=elm cmake --build build --target check
TEST_FILTER=String cmake --build build --target run-tests
```

The underlying test binary can also be run directly for finer control:

```bash
./build/test/test                       # Run all tests
./build/test/test --filter elm          # Filter by name
./build/test/test -n 1000               # 1000 property-test iterations
./build/test/test --seed 42             # Reproducible run
./build/test/test --list                # List tests without running
```

### AOT and MLIR-equivalence suites

- `run-aot-e2e` — the same E2E tests ahead-of-time: compile via Stage 3's
  `eco-boot-2.js`, lower with `eco-boot-native` to a native binary, run it and
  check stdout against `-- CHECK:` directives (Gate B of the bootstrap).
- `run-mlir-equivalence` — compare Stage 2 and Stage 6 MLIR output.
- `run-js-e2e` — the eco-system E2E tests compiled to JS with Stage 1 and run
  under node (`TEST_FILTER` takes comma-separated substrings).

## 3. Stress tests (`stress`)

The stress suite runs longer-lived Elm programs that exercise the runtime and
GC under sustained load. It lives in a separate binary (`stress-test`) so its
high iteration counts don't slow the normal `check` cycle.

```bash
# Build + run the full stress suite.
cmake --build build --target stress

# Build only the stress binary (faster than a full rebuild).
cmake --build build --target stress-test
```

Run the binary directly to scale or filter the work:

```bash
./build/test/stress-test                              # Defaults
./build/test/stress-test -n 500 -m 200                # numLoops / maxSize knobs
./build/test/stress-test --filter ListReverseStressTest -n 1000
./build/test/stress-test --list                       # List stress programs
./build/test/stress-test --timeout 5m                 # Per-suite wall-clock budget
./build/test/stress-test --seed 42                    # Reproducible run
```

Stress programs that opt in to parameterization use the shared `StressHarness`
module (`test/stress-elm/src/StressHarness.elm`): `-n` sets `numLoops` (outer
iteration count), `-m` sets `maxSize` (a secondary size knob, e.g. list/array
length), and `--timeout` is threaded through as `timeoutMs` so a harness-based
program can bail from its inner loop once the budget is exhausted.

## 4. GC concurrency verification

These are not part of `check` or `full`; see `test/tla/README.md` and
[build-targets.md](build-targets.md#verification-targets).

- `tla-canary` (in ALL) — warns (fails with `ECO_TLA_CANARY_STRICT=ON`) when
  GC code pinned by `test/tla/manifest.txt` changes before every model it names
  has an `AUDIT.md` verdict for the new code (GC_MODEL_001).
- `tla-check` / `tla-check-deep` / `tla-trace` — run the TLA+ models under
  `test/tla/` (quick and deep tiers) and trace validation; need Java and
  tla2tools.jar.
- `genmc-check` — the weak-memory drivers under `test/genmc/`; needs the
  GenMC image (see [building.md](building.md)).
- `register-guards` / `register-guards-stress` — the code guards for the GC
  concurrency register, including the fork and TSan arms (`fork-det`,
  `tsan-det`).
- TSan tiers — `test/gc-heap-tsan/` and `test/gc-helper-tsan/` are standalone
  g++ projects that run the allocator under ThreadSanitizer; their headers give
  the build commands.

## 5. Conformance scripts

`test/conformance/h2spec.sh` (HTTP/2) and `test/conformance/autobahn.sh`
(WebSocket) score eco/system's servers against upstream conformance suites and
compare with a baseline. They are local-only (never run in CI) and download
their tools under `/tmp`.

## 6. Bootstrap test gates

The bootstrap pipeline has two built-in E2E gates that fail-fast on backend
regressions: **Gate A** runs the JIT E2E suite after Stage 1, and **Gate B**
runs the AOT E2E suite after the JS fixed point. Either gate's failure pins the
regression to the stages before it, before further self-compile cycles burn.

See [bootstrap.md](bootstrap.md) for where the gates sit in the chain and the
commands that drive them.
