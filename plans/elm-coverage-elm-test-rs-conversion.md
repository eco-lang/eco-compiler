# Convert elm-coverage to use elm-test-rs

## Background

`compiler/elm-coverage/` is a fork of [zwilias/elm-coverage](https://github.com/zwilias/elm-coverage) that instruments Elm source files for code coverage. It currently depends on `elm-test` (the JS-based test runner). We want to switch it to use `elm-test-rs` instead, which is what the rest of the Eco compiler's test suite uses.

## Architecture Differences

### elm-test (current)
- Single Node.js process runs all tests
- Communicates via Elm port `elmTestPort__send`
- Sends a `{"type": "FINISHED"}` JSON message when tests complete
- The compiled test JS defines an `app` variable at module scope

### elm-test-rs (target)
- **Supervisor/worker model**: `node_supervisor.js` spawns `node_runner.js` in `worker_threads`
- Workers communicate with supervisor via `parentPort.postMessage`
- Supervisor listens on `reporter.ports.signalFinished` for completion, then calls `process.exit(exitCode)`
- The compiled Elm code (`Runner.elm.js`) is `require()`d inside worker threads
- Multiple workers (up to 12) may run concurrently, all sharing the same PID
- elm-test-rs uses `--compiler` flag (same as elm-test)

### Coverage injection mechanism (unchanged)
- `elm-instrument` rewrites source files, inserting `Coverage.track "ModuleName" index` calls
- `fake-elm` is a shim that intercepts `elm make`, runs the real compiler, then post-processes the output JS
- Post-processing uses a regex to find `$author$project$Coverage$track` and injects counter-accumulation code
- Coverage data files (`data-*.json`) are collected after tests finish and merged with `info.json`

## Changes Required

### Step 1: Replace data-flush mechanism in `bin/fake-elm` (core change)

**File:** `compiler/elm-coverage/bin/fake-elm`

The current injected code (lines 88-118) does:
1. Declares `var counters = {}`
2. Uses `setTimeout` to wait for `app` to be defined
3. Subscribes to `app.ports.elmTestPort__send`
4. On `"FINISHED"` message, writes `data-<process.pid>.json`

**Problem:** elm-test-rs has no `elmTestPort__send` port. The compiled `Runner.elm.js` runs inside worker threads, not the main process. All workers share the same `process.pid`, so PID-based filenames would collide.

**Solution:** Replace the port-subscription flush with a `process.on('exit')` hook using `worker_threads.threadId` for unique filenames:

```js
var replacement = [
    "// INJECTED COVERAGE FIXTURE",
    'var fs = require("fs");',
    "var counters = {};",
    "process.on('exit', function() {",
    "    if (Object.keys(counters).length > 0) {",
    "        var id = 0;",
    "        try { id = require('worker_threads').threadId; } catch(e) { id = process.pid; }",
    "        fs.writeFileSync('data-' + id + '.json', JSON.stringify(counters));",
    "    }",
    "});",
    "",
    // ... then the same Coverage.track replacement as before
].join("\n");
```

This approach:
- Works with both elm-test and elm-test-rs (runner-agnostic)
- Uses `threadId` (unique per worker thread) instead of `pid` (shared)
- Falls back to `pid` if `worker_threads` is unavailable
- Flushes on process/thread exit rather than on a specific port message
- No longer needs the `setTimeout` or `app` variable check

Also remove the error message referencing "test runner provided by elm-test" (line 94).

### Step 2: Update `lib/runner.js` runTests function

**File:** `compiler/elm-coverage/lib/runner.js`, lines 94-137

The current code spawns:
```js
spawn(args["elm-test"], ["--compiler", fakeElmBinary, args.tests].concat(args._), { cwd: coverageDir })
```

elm-test-rs uses the same `--compiler` flag, so this should work as-is. However, verify:

- [ ] elm-test-rs accepts the same `--compiler <path>` syntax
- [ ] elm-test-rs accepts a bare directory path for tests (e.g., `tests/`)
- [ ] The `cwd` being set to `.coverage/instrumented/` works correctly (elm-test-rs resolves paths relative to cwd)

No code changes expected here, but needs testing.

### Step 3: Update `lib/aggregate.js` data file pattern

**File:** `compiler/elm-coverage/lib/aggregate.js`, line 67

Current pattern: `/^data-\d+.json$/`

This already matches `data-<number>.json`, and `threadId` values are numeric, so **no change needed**. However, the directory searched is `elmTestGeneratedDir` (`.coverage/instrumented/`).

**Verify:** that elm-test-rs workers write `data-*.json` files into the correct directory. Since `fake-elm` injects `fs.writeFileSync('data-...')` with a relative path, and the worker's cwd should be the instrumented dir, this should work. But if elm-test-rs changes the worker cwd, the data files could end up elsewhere.

**Mitigation:** Use an absolute path in the injected code:
```js
var __coverageDir = process.cwd();
// ... later in the exit handler:
fs.writeFileSync(require('path').join(__coverageDir, 'data-' + id + '.json'), ...);
```

### Step 4: Update CLI defaults and package.json

**File:** `compiler/elm-coverage/lib/cliArgs.js`, line 28
- Change default from `"elm-test"` to `"elm-test-rs"`

**File:** `compiler/elm-coverage/package.json`
- Remove `"elm-test": "^0.19.1-revision7"` from dependencies
- Optionally add a note that elm-test-rs must be available on PATH

### Step 5: Verify `setupTests` directory layout compatibility

**File:** `compiler/elm-coverage/lib/runner.js`, lines 55-92

`setupTests` creates this layout under `.coverage/instrumented/`:
```
.coverage/instrumented/
├── elm.json          (copied from project root)
├── src/              (instrumented sources)
│   └── Coverage.elm  (stub module)
└── tests/            (copied from project tests/)
```

elm-test-rs discovers tests by scanning for `Test` values in exposed modules. It generates its own `Runner.elm` and `elm.json` under `elm-stuff/tests-0.19.1/`. This should be fine since elm-test-rs operates relative to the cwd (which is the instrumented dir).

**Verify:** elm-test-rs can find and compile tests from the instrumented directory structure.

### Step 6: Handle worker thread `fs` access

Worker threads in Node.js have full `fs` access, so `require("fs")` in the injected code works. No special handling needed.

However, `process.on('exit')` in a worker thread fires when the **main process** exits, not when the worker is terminated. When elm-test-rs calls `runner.terminate()` (node_supervisor.js line 99), the worker is killed without firing its `exit` handler.

**Better approach:** Use `require('worker_threads').parentPort?.on('close', ...)` or, more reliably, flush synchronously after each `Coverage.track` call (too expensive), or use a periodic flush.

**Recommended fix:** Instead of `process.on('exit')`, detect worker context and use the appropriate hook:

```js
var _coverageFlush = function() {
    if (Object.keys(counters).length > 0) {
        var id = 0;
        try { id = require('worker_threads').threadId; } catch(e) { id = process.pid; }
        var outPath = require('path').join(__coverageDir, 'data-' + id + '.json');
        require('fs').writeFileSync(outPath, JSON.stringify(counters));
    }
};
try {
    var _wt = require('worker_threads');
    if (!_wt.isMainThread) {
        // In a worker thread: flush before termination
        // parentPort 'close' event fires when worker is terminated
        _wt.parentPort.on('close', _coverageFlush);
    } else {
        process.on('exit', _coverageFlush);
    }
} catch(e) {
    process.on('exit', _coverageFlush);
}
```

**IMPORTANT:** Need to verify that `parentPort.on('close')` fires before `worker.terminate()` completes. If it doesn't, an alternative is to monkey-patch the `sendResult` port subscription in the worker to flush after each test result (overhead is small since it's just a JSON write). Or accumulate in a SharedArrayBuffer. The simplest reliable approach may be to write coverage data incrementally with each `sendResult` call.

**Fallback approach if `close` event is unreliable:** Patch `node_runner.js` via fake-elm to flush coverage data alongside each `sendResult` message. This is wasteful but reliable. Better: flush once when all tests for this worker are done. The worker knows it's done when `dispatchWork` sends no more work — but the worker itself doesn't know this.

**Simplest reliable approach:** Write coverage on `process.on('exit')` in the **supervisor** process. This requires the counters to be in the main thread. Since `Runner.elm.js` is loaded in workers, the counters are per-worker. We need to aggregate them. Options:
1. Each worker writes its own file on `process.on('beforeExit')` — but workers are terminated, not exited
2. Workers post coverage data to supervisor via `parentPort.postMessage` — requires patching supervisor too
3. **Use `Atomics` / `SharedArrayBuffer`** — overkill
4. **Write file after each test result** (overwrite, not append) — simple and reliable

**Recommended final approach:**
```js
// After each Coverage.track call, counters are updated in memory.
// Overwrite the data file after each track call (or debounced).
// This ensures data is persisted even if the worker is terminated.
var _coverageDirty = false;
var _coverageTimer = null;
function _scheduleCoverageFlush() {
    if (!_coverageDirty) return;
    if (_coverageTimer) return;
    _coverageTimer = setTimeout(function() {
        _coverageTimer = null;
        _coverageDirty = false;
        _coverageFlush();
    }, 100);
}
```

Or even simpler: just write on every track call. The overhead of `writeFileSync` is ~0.1ms and each test probably triggers many track calls, but this is coverage tooling — performance is secondary. Actually this would be too frequent (thousands of track calls per test).

**Final recommendation:** Use a debounced write (100ms timer) plus a `process.on('exit')` fallback. The timer ensures data is written even if the worker is terminated, with at most 100ms of lost coverage at the tail end (negligible in practice).

## Testing Plan

1. Run elm-coverage on a small Elm project using elm-test-rs, verify coverage data is collected
2. Verify multi-worker scenarios produce correct per-thread data files
3. Verify aggregation merges all data files correctly
4. Compare coverage output between old (elm-test) and new (elm-test-rs) to ensure parity
5. Test with `--force` flag when some tests fail

## Risk Assessment

| Risk | Impact | Mitigation |
|------|--------|------------|
| Worker termination kills data flush | Coverage data lost | Debounced periodic writes |
| elm-test-rs changes cwd for workers | Data files in wrong dir | Use absolute paths |
| threadId collision (shouldn't happen) | Data overwritten | threadIds are guaranteed unique |
| elm-test-rs doesn't support `--compiler` | Whole approach broken | Verified: it does support it |
| Regex for `$author$project$Coverage$track` doesn't match | No coverage injection | Same compiled Elm output, should match |

## Files Modified

| File | Change | Effort |
|------|--------|--------|
| `bin/fake-elm` | Replace port-flush with debounced write + exit hook | Medium |
| `lib/cliArgs.js` | Default `--elm-test` to `"elm-test-rs"` | Trivial |
| `package.json` | Remove elm-test dependency | Trivial |
| `lib/runner.js` | No changes expected (verify only) | None |
| `lib/aggregate.js` | No changes expected (verify only) | None |
