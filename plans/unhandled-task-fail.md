# Plan: What an Unhandled `Task.fail` Does

**Status: DONE 2026-10-26. Settled as "warn and carry on". The crash was built, then reversed the
same day.**

## Context

`error-handling.md` (now deleted) recorded a TODO. A `Task.fail` can reach the bottom of a
process's stack with no `Task.onError` frame to catch it. When that happens, the native scheduler
prints a warning to stderr, drops the failure value and ends that one process, and the program
carries on (`runtime/src/platform/Scheduler.cpp`, the `else` arm of the `Task_Succeed`/`Task_Fail`
case in the step loop). The TODO proposed crashing the program instead, the way
`Eco.Kernel.Crash.crash` does.

Who can reach this path:
- Only user code that starts a process with `Process.spawn` on a task whose error type is not
  `Never`, and never handles the error.
- Not the libraries. `Task.perform` needs `Task Never a`, and `Task.attempt` turns failure into a
  `Result`. The library commands run by `Process.spawn` (`Http.Server`'s `Respond`, `System`'s
  `Execute`) carry `Task Never ()`. The compiler's own IO wraps each fallible call in
  `crashOnError`. `System.simpleProgram` handles its task's failure itself and exits 1
  (`SimpleProgramFailExitTest`).

## Decision

**Warn and carry on, as before.** Stock Elm's JavaScript scheduler (elm/core `Scheduler.js`, which
the JavaScript backend also runs) ends a failed process silently, and the program keeps going. Eco
native does the same, plus one warning line on stderr. The scheduler code is unchanged.

The decision is now pinned by an invariant and a test:
- SCHED_002 states the behaviour, and SCHED_001's wording is unchanged.
- `test/eco-system/src/UnhandledTaskFailWarnsTest.elm` checks it. A spawned process fails, the
  warning appears, the main process logs afterwards, and the program exits 0 with no crash line.

## History

1. **Crash built.**
   - `UnhandledTaskFailCrashTest.elm` failed against the old scheduler.
   - `crashOnUnhandledFail` then printed
     `Eco crash: unhandled Task.fail (no Task.onError caught it): "boom"` and exited 1, and the test
     passed.
   - The six `Scheduler.*` kernel-license rows were re-audited, and their line citations moved
     down by 2 for the new `#include` lines.
2. **Reversed.**
   - `Scheduler.cpp` was restored byte for byte. Its hash again equals the one pinned by the
     2026-10-24 audit, so the 2026-10-26 re-audit notes and citation changes were removed and the
     license manifest went back to its earlier pins.
   - The test was renamed and changed to expect the warning.
   - `error-handling.md` stays deleted. Its TODO is decided, and the `design-notes.md` bullet that
     called top-level error handling unfinished stays removed.
