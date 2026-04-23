# Stress-Test Failures — Test-Fix Loop Log

Baseline (2026-04-23, before session start): 97 tests, 13 failing.

After this session's two fixes:
- elm-test: 12799/12799 passing (no regressions).
- E2E `check`: 1123/1123 passing (no regressions).
- stress-test: **95/97 passing** (+11 fixed), 2 failing.

## FIXED (this session)

### Fix 1 — Process logically immutable
Every update to `root`/`stack`/`mailbox` now allocates a new Process and
updates the holder via a `latestProc_` registry indexed by process id.
Also:
- `ManagerInfo` (`registerManager`) stores closures as encoded `uint64_t`
  HPointers; walked by the external root scanner.
- `initWorker`/`dispatchEffects` capture `procId` before `drain()` and use
  `latestProcessById(id)` after.

Files: `Scheduler.{hpp,cpp}`, `PlatformRuntime.{hpp,cpp}`,
`elm-kernel-cpp/src/{core/TaskEffectManager,http/HttpEffectManager,
time/TimeEffectManager}.cpp`.

Unblocked: **ModifyMVarCounterStress** plus 9 other MVar/Spawn stress
tests.

### Fix 2 — Sleep resume closure GC-rooted across timer thread
`sleepBindingEvaluator` was capturing the resume closure HPointer as a
raw `uint64_t` in the spawned timer thread — stale after any main-thread
GC. Added `Scheduler::registerPendingResume` / `takePendingResume` with
a scanned `pendingResumes_` map; timer thread now captures an opaque
token and recovers the (post-GC, possibly-evacuated) closure via token
lookup.

Files: `Scheduler.{hpp,cpp}`, `elm-kernel-cpp/src/core/ProcessExports.cpp`.

Unblocked: **SpawnThenAndThenChain**.

## OPEN — 2 remaining failures

### 1. SpawnGCChurn — SIGABRT (bogus closure)

```
DIAG: eco_apply_segmentation_unknown bad closure:
  hptr=0x2000... ptr=0x7f...  tag=0 n_values=0 max_values=0 evaluator=(nil)
```
Not fixed by Fix 2 (sleep resume rooting), so a different closure is
going stale. SpawnGCChurn pipelines `Process.spawn` over 300 fibers with
nested `Task.andThen`s, so candidates include the andThen callback
captured in a `StackFrame` Custom, or the closure produced by
`spawnTask` returning `Task.succeed(process)`. Needs a minimal repro
/ trace to confirm.

Attempts: 1 (sleep-rooting fix, no effect on this test).

### 2. BytesRoundtripMixedRecord — missing pattern (roundtrip mismatch)

```
[eq] tag mismatch: 0 vs 3
FAILED: Missing pattern: roundtrip: True
```
Unrelated to async/scheduler paths; likely a latent GC bug in the bytes
round-trip code. Needs separate investigation.

Attempts: 0.
