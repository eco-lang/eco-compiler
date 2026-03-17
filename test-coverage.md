# Running Tests with Coverage

This guide explains how to run the Eco compiler's Elm test suite under
`elm-test-rs` with code coverage instrumentation, using the modified
`elm-coverage` tool in `compiler/elm-coverage/`.

## Prerequisites

- Node.js (v18+)
- `elm` and `elm-test-rs` available on PATH (both are installed in
  `compiler/node_modules/.bin/`)

## Quick Start

From the `compiler/` directory:

```bash
env PATH="$(pwd)/node_modules/.bin:$PATH" \
  node elm-coverage/bin/elm-coverage src/ \
    --tests tests/ \
    --elm-test elm-test-rs \
    -- --workers 8 --fuzz 1
```

The HTML report is written to `.coverage/coverage.html`.

## Detailed Usage

### Command Structure

```
node elm-coverage/bin/elm-coverage <source-path> [options] -- [elm-test-rs-options]
```

Arguments before `--` go to elm-coverage. Arguments after `--` are forwarded
to elm-test-rs.

### elm-coverage Options

| Flag | Default | Description |
|------|---------|-------------|
| `<source-path>` | `src/` | Directory of Elm sources to instrument |
| `--tests <path>` | `tests/` | Directory containing test files |
| `--elm-test <path>` | `elm-test-rs` | Path or name of the test runner binary |
| `--force / --no-force` | `--force` | Continue generating the report even if tests fail |
| `--silent` | `false` | Suppress test runner output |
| `--report <type>` | `html` | Report format: `html`, `json`, or `codecov` |
| `--open` | `false` | Open the HTML report in a browser when done |
| `-v, --verbose` | `false` | Print debug messages |

### elm-test-rs Options (after `--`)

| Flag | Description |
|------|-------------|
| `--workers <n>` | Number of worker threads (use 8 to limit memory) |
| `--fuzz <n>` | Number of fuzz iterations per fuzz test |
| `--seed <n>` | Reproduce a specific test run |

### PATH Setup

Both `elm` and `elm-test-rs` must be on PATH because:

- `elm-test-rs` is invoked by name by elm-coverage's runner.
- `elm` (the real compiler) is invoked by the `fake-elm` shim, which uses
  `which.sync("elm")` to locate it.

The simplest way is to prepend `node_modules/.bin`:

```bash
export PATH="$(pwd)/node_modules/.bin:$PATH"
```

Or pass it inline with `env` as shown in the Quick Start.

### Important: Use `tests/` Not `build-xhr/tests/`

`build-xhr/tests` is a symlink to `../tests`. elm-coverage copies it verbatim,
preserving the symlink, which breaks inside the instrumented directory. Always
point `--tests` at the real `tests/` directory.

## Output

### Report Files

| Path | Content |
|------|---------|
| `.coverage/coverage.html` | Per-module HTML coverage report |
| `.coverage/coverage.json` | Machine-readable coverage (with `--report json`) |
| `.coverage/codecov.json` | Codecov-compatible upload format (with `--report codecov`) |
| `.coverage/info.json` | Raw instrumentation metadata |
| `.coverage/instrumented/` | Instrumented source tree (ephemeral) |
| `.coverage/instrumented/data-<N>.json` | Per-worker coverage data files |

### Coverage Categories

The report breaks coverage into four categories per module:

- **decls** -- top-level function declarations
- **let decls** -- let-binding declarations
- **lambdas** -- anonymous function expressions
- **branches** -- case/if branches

## How It Works

1. **Instrument**: `elm-instrument` rewrites each `.elm` source file, inserting
   `Coverage.track "ModuleName" index` calls at every trackable expression.

2. **Compile**: elm-test-rs compiles the instrumented sources using `fake-elm`
   as the compiler. `fake-elm` delegates to the real `elm make`, then
   post-processes the output JS to replace the `Coverage.track` function body
   with counter-accumulation code.

3. **Run**: elm-test-rs runs tests in worker threads. Each worker accumulates
   coverage hits in a `counters` object keyed by module name and expression
   index. A debounced timer (100ms) periodically flushes counters to
   `data-<threadId>.json` in the instrumented directory. A `process.on('exit')`
   handler ensures a final flush.

4. **Aggregate**: After tests finish, elm-coverage reads all `data-*.json`
   files, merges them with `info.json`, and generates the report.

## Modifications from Upstream elm-coverage

This fork has three changes from the original [zwilias/elm-coverage] to support
elm-test-rs:

1. **Coverage directory via environment variable** (`runner.js`, `fake-elm`):
   elm-test-rs runs `elm make` from `elm-stuff/tests-0.19.1/`, not the
   instrumented directory. The runner passes `ELM_COVERAGE_DIR` as an
   environment variable containing the absolute path to the instrumented
   directory, and `fake-elm` bakes this path into the injected JS.

2. **Count-based tracking** (`fake-elm`, `aggregate.js`): The original pushed
   every expression index into an array, producing ~500MB of JSON per worker.
   The modified version uses `counters[module][index] = count`, reducing data
   files to ~100KB each. `aggregate.js` handles both formats.

3. **Default test runner** (`cliArgs.js`): Changed from `elm-test` to
   `elm-test-rs`.

## Troubleshooting

**`Error: not found: elm`** -- `elm` is not on PATH. Prepend
`node_modules/.bin` as shown above.

**`Error: spawn elm-test-rs ENOENT`** -- `elm-test-rs` is not on PATH. Same
fix.

**`No file was found in your tests/ directory`** -- The tests directory inside
`.coverage/instrumented/` is empty or a broken symlink. Make sure `--tests`
points to a real directory, not a symlink.

**`RangeError: Invalid string length`** -- You may be running an older version
of `fake-elm` that uses the array-based tracking format. Ensure the
count-based version is in place.

**All coverage is 0%** -- Coverage data files were not written to the
instrumented directory. Check that `ELM_COVERAGE_DIR` is being set (run with
`-v` to see debug output) and that data files appear in
`.coverage/instrumented/`.

**`TEST RUN INCOMPLETE because Test.skip was used`** -- This is expected. Some
tests in the suite use `Test.skip`. All non-skipped tests still run and
coverage is collected normally. Use `--force` (the default) to generate the
report anyway.
