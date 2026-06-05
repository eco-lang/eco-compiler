# Testing

All targets below are invoked as `cmake --build build --target <name>` against
a tree configured with the `build` preset (see [building.md](building.md)).

## 1. Elm compiler frontend tests (`elm-tests`)

The Elm-side unit tests for the compiler frontend, run via `elm-test-rs`:

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

## 2. End-to-end tests (`full` / `check`)

The E2E suite covers the C++ runtime (GC, allocator, kernel ops), MLIR codegen,
and Elm end-to-end tests (compile Elm → MLIR → JIT).

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

## 4. Bootstrap test gates

The bootstrap pipeline has two built-in E2E gates that fail-fast on backend
regressions: **Gate A** runs the JIT E2E suite after Stage 1, and **Gate B**
runs the AOT E2E suite after the JS fixed point. Either gate's failure pins the
regression to the stages before it, before further self-compile cycles burn.

See [bootstrap.md](bootstrap.md) for where the gates sit in the chain and the
commands that drive them.
