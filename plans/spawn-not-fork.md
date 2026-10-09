# Plan: spawn child processes instead of forking them (runtime and test harnesses)

Status: **implemented on Linux** (2026-10-09; §5 log). Windows code is written but not compiled or run (no Windows toolchain on this machine). Follows `plans/region-nursery-everywhere.md`, whose main
defect (every E2E program inherited the legacy nursery from the forking test process) and finding F1
(the fork contract's relaunch path) both come from `fork()` copying a live process.

**Read before coding:**
- `design_docs/invariants.csv`: HEAP_007 (the fork contract), HEAP_075 (ForkSafety, the one
  `pthread_atfork` registration), HEAP_082.
- `plans/build-on-windows.md` items 9 (process spawning) and the test-binary gates (§ "stress-elm,
  mlir-equivalence, aot-e2e-runner", "stress-test & elm-http / eco-kernel E2E").
- `system-kernel-cpp/src/eco-system/ChildProcess/Spawn.{hpp,cpp}`: the existing `posix_spawn`
  implementation (POD only, no heap access) that this plan generalises.
- `plans/kernel-parametricity-license.md` §2: `Process.cpp` is a licensed kernel, and
  `KernelSetFacts.elm` cites its line numbers.
- `CLAUDE.md`: run each test command once, tee to `/tmp`. Never run two test binaries at once
  (shared `TestServerConfig.elm`).

## 1. Problem (verified in the tree, 2026-10-09)

**P1. The `Eco.Process` kernel forks.** `eco-kernel-cpp/src/eco-kernel/Process.cpp` (`spawn`,
`spawnProcess`) runs `fork()` + `execvp()`. Every spawn clones the parent's address space,
copy-on-write, including the whole Eco heap. It also runs the HEAP_075 prepare handlers, which stop
the background mark and tenure gangs and take every GC lock. Then the clone throws all of that away
at `execvp`. On Windows the kernel returns ENOSYS.

**P2. The two spawners disagree.** The eco-system library's `ChildProcess/Spawn.cpp` already uses
`posix_spawn(p)`, with file actions, a signal mask, a process group and a built environment block.
`Eco.Process` duplicates that job with `fork`. Neither works on Windows (ENOTSUP / ENOSYS).

**P3. Test children inherit the test process.** `test/ElmE2ETestBase.hpp` (E2E and stress programs)
and `test/IsolatedTestRunner.hpp` (isolated unit suites) fork one child per test from a process
that has already run in-process unit tests. Each child inherits:
- the allocator singleton: its config (the region-nursery-everywhere defect), its first-init-wins
  address reservation (the CR-025 workaround in `TestHelpers.cpp`), and its live GC state;
- live background GC threads, which exist only as stale state in the child;
- `PlatformRuntime`, the scheduler, LLVM initialisation and any other singleton state.

Each child must then "reset" its way back to a clean state (`EcoRunner::reset`, HEAP_082's guard).
Results come back through `mmap(MAP_SHARED)` blocks (`ElmSharedTestResult`).

**P4. Windows has no isolation at all.** Both harnesses fall back to a serial, in-process loop
(`ElmE2ETestBase.hpp:981`, `IsolatedTestRunner.hpp:17`): one crash ends the suite, there are no
timeouts and no parallelism, and `checkProcessOutput` is not honoured.

## 2. Goals and non-goals

- Every production spawn of an external program uses a spawn primitive: `posix_spawn(p)` on
  Linux/macOS, `CreateProcessW` on Windows. No `fork()` in any production path.
- One spawn implementation, shared by `Eco.Process` and the eco-system `ChildProcess`.
- Test children are **spawned fresh processes** on every platform: clean heap, clean singletons,
  real crash isolation, timeouts and parallelism, Windows included.
- **Non-goal:** removing the fork contract. HEAP_007/HEAP_075 stay: embedders may `fork()`, and the
  tests whose subject is fork keep forking (§3 Phase 4).

## 3. Phases

### Phase 0: confirm the premises (no code change)
1. **glibc atfork behaviour.** A unit test registers a `pthread_atfork` prepare counter, calls
   `spawnChild` (posix_spawn) for `/bin/true`, and asserts the counter did not move. Do the same
   for `fork()` as the positive control. Pin it, so a libc change that runs atfork handlers on
   `posix_spawn` is caught. Record the glibc version and the macOS result.
2. **Baseline timing.** Wall time of `build/test/test` unfiltered and `stress-test`, from three
   runs; spawn's per-test cost is judged against these.
3. **Census of forks.** `grep -rn "fork()"` across runtime, kernels and tests; classify each site
   as production spawn, harness isolation, or fork-under-test. The list goes in §5.

### Phase 1: one cross-platform spawn primitive
1. Move `ChildProcess/Spawn.{hpp,cpp}` (POD only: `SpawnSpec`, `StdioMode`, `SpawnedChild`) to a
   runtime-level home both kernels can link, for example `runtime/src/platform/Spawn.{hpp,cpp}`. The
   eco-system kernel keeps a thin forwarder or includes it directly. No behaviour change on POSIX.
2. **Windows implementation: `CreateProcessW`.**
   - **Command line:** argv is joined into one UTF-16 string with the MSVC quoting rules
     (backslashes before a quote double, arguments containing spaces or quotes are quoted), so
     `CommandLineToArgvW` in the child gets back exactly the argv given. A unit test round-trips
     hostile arguments (spaces, quotes, trailing backslashes, empty strings, non-ASCII).
   - **Executable search** (the `posix_spawnp` equivalent): `SearchPathW` over `PATH` with
     `PATHEXT`. An explicit path is used as given.
   - **Handles:** pipes from `CreatePipe`, with only the child's ends inheritable. Inheritance is
     limited to exactly those handles with `STARTUPINFOEXW` + `PROC_THREAD_ATTRIBUTE_HANDLE_LIST`;
     plain `bInheritHandles = TRUE` leaks every inheritable handle into every child and races
     between threads.
   - **Environment:** a UTF-16 block, sorted case-insensitively as Windows expects, built from
     `SpawnSpec.env` and `envMode` like `buildEnv`. **Working directory:** the `lpCurrentDirectory`
     argument.
   - **Process group / kill-tree:** a Job object
     (`JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE`) replaces `setpgroup`, so a timeout or crash kills the
     child's descendants too.
   - **Wait and exit codes:** `WaitForSingleObject` + `GetExitCodeProcess`. Crash codes (for example
     `0xC0000005`, an access violation) map to the same "crashed" outcome a POSIX signal gives.
   - **Wait service:** the POSIX SIGCHLD + `waitpid(WNOHANG)` worker becomes
     `RegisterWaitForSingleObject` (or one waiter thread) posting into the same async-source drain.
3. Tests (portable): spawn with stdin pipe, stdout/stderr pipe, inherit, cwd, env replace and
   merge, a missing executable, exit codes 0/1/255, a child killed by timeout, and a child that
   spawns a grandchild (killed with it).

### Phase 2: `Eco.Process` uses the primitive
1. `spawnBody` / `spawnProcessBody` in `eco-kernel-cpp/src/eco-kernel/Process.cpp` call
   `spawnChild`. The `fork`/`execvp`/`dup2` code is deleted, and Windows returns real processes
   instead of ENOSYS. The stdin pipe (`s_streamHandles`) maps to the primitive's pipe handles. The
   WaitService lanes are unchanged on POSIX.
2. Kernel licence: re-audit the `Process` rows of `KernelSetFacts.elm` (spawn, spawnProcess, wait;
   the evidence cites line numbers) with an advanced `audited:` date, and update
   `kernel-license-manifest.txt`.
3. Gate: the existing `Eco.Process` E2E tests and the eco-system ChildProcess tests, on Linux; on
   Windows, the new spawn tests plus whichever E2E suites `build-on-windows` has enabled.

### Phase 3: test children are spawned, not forked
1. **A runner mode for one test.** The test binaries gain a child mode:
   - `test --run-elm <mlir> --elm <src> [--flags <json>] [--process-output] --result <file>`: run one
     Elm program through `EcoRunner` in a fresh process; write a small result record (passed,
     error text, output, exit code, GC stats for the accumulated banner) to `<file>`; exit with
     the program's status.
   - `test --run-case "<exact name>" --result <file>`: run one registered unit test case.

   A result **file**, not a pipe protocol or shared memory: it works identically on Windows, and
   the program's own stdout/stderr stay free for CHECK matching (`checkProcessOutput`).
   `stress-test` gets the same `--run-elm` mode.
2. **`ElmE2ETestBase.hpp`:** the parallel loop keeps `MAX_PARALLEL_TESTS` and the per-test timeouts,
   but launches each child with `spawnChild` (stdout+stderr to a pipe the parent drains) and reads
   `--result`. Timeout kill is `kill(pid)` on POSIX and the Job object on Windows. The Windows
   serial in-process fallback is deleted. `ECO_TEST_PORT` and the CHECK/STDIN directives go
   through the spawn spec (env, a stdin pipe).
3. **`IsolatedTestRunner.hpp`:** the same, using `--run-case`, for GCPressure, LargeBodyChurn,
   SliceCrashers, PlatformServices and the others. Needs an exact-name lookup (a name, not a
   substring filter). Its Windows fallback is deleted too.
4. **What stops being needed** (keep each as a cheap assertion, delete only where truly dead):
   - the inherited-config defect class (HEAP_082's guard stays, as an assertion);
   - `TestHelpers`' default-config first reservation: it is still needed for in-process unit
     tests, which share one process, but no longer for isolated ones;
   - `ElmSharedTestResult` and the `mmap` plumbing: deleted.
5. **Shared generated files:** `TestServerConfig.elm` is rewritten per run in the shared source
   tree, which is why two test binaries cannot run at once. Pass the server's ports to children by
   environment variable and generate that module once per build tree instead. Separable; do it
   here only if it falls out of the runner change.
6. **Timing:** compare `build/test/test` and `stress-test` wall times with the Phase 0 baseline.
   Spawn adds process start plus `EcoRunner` / LLVM initialisation per program (expected tens of
   ms). If the total grows by more than ~10 %, batch: one spawned child runs N programs in
   sequence with a heap reset between them. Isolation per batch is still clean from the parent.

### Phase 4: what keeps `fork()`
These tests have fork as their subject, so they keep it:
- `test/gc-heap-tsan/fork_harness.cpp` (every arm, including `det-cr004`) and the
  `register-guards` fork rows;
- unit tests that fork inside their body: "fork while a tenure job runs", "fork during a running
  episode", "a forked child runs parallel minors", and the CR-0xx fork reproductions.

They cover the fork contract (HEAP_007/HEAP_075) that embedders rely on. Nothing in them changes.
Phase 0's census confirms the list.

### Phase 5: docs and invariants
- New invariant: no production path calls `fork()`; external programs start through
  `spawnChild` (`posix_spawn` / `CreateProcessW`). Amend HEAP_007's fork contract text to say the
  runtime itself never forks, and that the contract exists for embedders and the fork tests.
- New invariant: the test harnesses run every isolated test and every E2E program in a spawned
  process (`--run-elm` / `--run-case`).
- `plans/build-on-windows.md`: item 9 done by Phase 1–2, and the harness gates updated.
- `docs/options.md`: the runner modes.

## 4. Gates (batched at the end)
Linux: `full`, `stress`, validate unit+E2E and stress, `run-aot-e2e`, `register-guards` (strict),
`tla-canary`, the licence check, bootstrap, and the Phase 3 timing comparison. macOS: the spawn unit
tests and E2E (`mac-build`). Windows (`win-build`): the spawn unit tests, the isolated unit suites
through `--run-case` (crash isolation now real), and the E2E suites `build-on-windows` has enabled
(the Elm JIT suites wait for its Win64 HPtr-return ABI fix).

## 5. Log

### Phase 0
- **Census of `fork()`** (runtime, kernels, tests):
  - production spawn: `Eco.Process` (2 sites);
  - harness isolation: `ElmE2ETestBase`, `IsolatedTestRunner`, `aot_e2e_main`, and
    `mlir_equivalence_main`; plus `PlatformServicesTest`'s `forkExit` fixture, which only needs
    a child with a given exit status;
  - forks inside test bodies, kept by Phase 4: the death-test helpers (`childAborts` in
    GCHelper and ParallelMinor, `runInChild` in IncrementalMark), the per-arity sub-arms of the
    wide-object tests, the fork-subject tests (ConcurrentTenure, ConcurrentMark, ParallelMinor,
    RegionMinor, TenureAgeing, ConcurrencyRegister), `gc-heap-tsan` and `gc-helper-tsan`.
  - The death-test helpers isolate a lambda inside one test, which a spawned process cannot
    receive, and they already run inside a spawned child now.
- **Atfork premise:** pinned by `spawn/S1` on glibc 2.36 (Debian 12). `posix_spawn` runs no
  `pthread_atfork` prepare handler; `fork()` runs it (the positive control). macOS: not checked
  (no Mac here).
- **Baseline** (pre-change binary, unfiltered `build/test/test`, 3 runs, all 0 failures):
  324.92 / 340.67 / 325.26 s, median **325.26 s**. The `stress-test` baseline is **missing**:
  `full` had cleaned the binary away, so the timed runs exited 127, and by the time this was
  noticed the sources already held the spawn changes. The cost is therefore judged on
  `build/test/test`, which runs about 1,476 E2E programs plus the isolated suites.

### Phase 1
- `runtime/src/platform/Spawn.{hpp,cpp}` (`Elm::platform`): the eco/system POSIX
  implementation moved unchanged, plus:
  - new stdio modes `StdinPipe` (for `Eco.Process`) and `ToFile` (stdout and stderr to
    `outputPath`, stdin from `inputPath` or the null device; for the harnesses);
  - `pollChild` / `waitChild` / `killChild` / `releaseChild`;
  - the Windows `CreateProcessW` path: MSVC quoting, `SearchPathW`, the handle list, a sorted
    UTF-16 environment, a `CREATE_SUSPENDED` start, and an opt-in kill-on-close Job
    (`killTreeOnRelease`; off by default so a spawned program outlives its parent as on POSIX).
- `system-kernel-cpp/.../ChildProcess/Spawn.hpp` now aliases the runtime's names; its `Spawn.cpp`
  is deleted. The `addchdir_np` check moved to `runtime/src/codegen/CMakeLists.txt` (a source
  property, `ECO_SPAWN_HAVE_ADDCHDIR_NP`) and to `test/CMakeLists.txt` for the two runners that
  compile `Spawn.cpp` directly.
- The Windows `WaitService` worker waits per child on its process handle (registered by
  `Eco.Process`, else `OpenProcess`), replacing the stub that never completed a wait.
- `test/platform/SpawnTest.cpp`, S1–S9: atfork, exit codes, a missing program (ENOENT, no
  child), `ToFile`, stdin pipe, env merge and replace, cwd, a hostile argv round trip, and
  poll/kill. 9/9 pass.

### Phase 2
- `Eco.Process.spawn` / `spawnProcess` call `spawnChild` (`kShellNone`; `Inherit` or
  `StdinPipe`). A missing program now fails the spawn Task with `CommandNotFound`; with
  fork + execvp it was a child that exited 127.
- **Found:** the `Eco.Process` kernel was never linked into the JIT test binary
  (`EcoKernel_Process` was missing from `test`'s whole-archive list), and no Elm test called
  `spawn` or `wait`. Linked it, and added `test/eco-kernel/src/ProcessSpawnWaitTest.elm` (exit 3,
  `true`, a missing program, piped stdin). It passes.
- Licence: the four `Process` rows of `KernelSetFacts.elm` were re-audited (new line citations;
  `startChild` reads only copied-out strings; B1–B3 unchanged; `audited: 2026-10-09`), then
  `check-kernel-license-manifest.sh --update`.

### Phase 3
- `test/SpawnedChildren.hpp`:
  - `runSpawnedChildren`: up to 8 children, per-test timeouts, SIGINT, output and result files,
    printing as each test completes;
  - `runChildBody` / `defaultVerdict` / `resultRecord`, the child side and the verdicts;
  - `runCaptured`, for the AOT and equivalence runners.
- The child is `<self> --isolated-child <result> <kind> <args…>`, dispatched at the very top of
  `main` (both `test/main.cpp` and `stress-elm/main.cpp`) and ended with `std::_Exit`.
  Construction of the isolated suites moved to `buildIsolatedSuites()`, so a `case` child
  rebuilds only those: building the E2E suites starts the HTTP test server and rewrites
  `TestServerConfig.elm`.
- `IsolatedTestRunner::runTestsParallel` takes child kinds instead of lambdas (codegen,
  bf-codegen), and `IsolatedTestCaseSuite` runs `case <suite> <test>`. `ElmE2ETestBase` runs
  `elm <test|process> <mlir> <elm> <flags>`. `ElmSharedTestResult` is unchanged; it now lives in
  the mapped result file. All `mmap(MAP_ANONYMOUS)` + `fork` code and both Windows serial
  fallbacks are deleted.
- `aot_e2e_main` / `mlir_equivalence_main` `spawn_capture` now call `eco_test::runCaptured`.
- Not done (§3 Phase 3 step 5, separable): `TestServerConfig.elm` is still rewritten per run, so
  two test binaries still cannot run at once.

### Phase 4
No change: the fork-subject tests, the fork harness and the register-guards fork rows keep `fork()`
(§3 Phase 4). Strict `register-guards`: harness arms 20 PASS, 2 RETIRED, 1 WONTFIX.

### Phase 5
SYS_007 (no production fork; the one spawn primitive) and SYS_008 (test children are spawned)
were added. HEAP_007's fork contract now says the runtime never forks itself, and HEAP_082 notes
that E2E children inherit nothing. `docs/options.md` describes the child mode.
`plans/build-on-windows.md` item 9 records the written-but-uncompiled Windows path.

### Gates (Linux, 2026-10-09; all sequential)
| gate | result |
|---|---|
| `full` | 2,379/2,379 (2,369 + 9 spawn + ProcessSpawnWaitTest); JS 162/162 |
| timed `build/test/test`, 3 runs | 326.39 / 326.08 / 325.85 s, median **326.08 s** vs 325.26 s fork baseline: **+0.82 s (+0.25 %)**, inside the baseline's own spread (324.9–340.7). No batching needed. |
| `stress` / validate `stress` | 114/114 / 114/114 |
| validate unit+E2E | 2,380/2,380 |
| `run-aot-e2e` (spawned via `runCaptured`) | 1,134/1,134 |
| `run-mlir-equivalence` (spawned via `runCaptured`) | 979/979 |
| `register-guards` (strict) | green |
| `tla-canary` | green (no TLA region touched) |
| kernel licence | green after the Process re-audit |
| bootstrap | 4b, 8c and 9b pass |

**Not verified:** Windows (`win-build`) and macOS (`mac-build`). The `CreateProcessW` path,
the Windows `WaitService` waiter, the Windows branches of `SpawnedChildren.hpp`, and the macOS
`addinherit_np` / `_NSGetExecutablePath` branches have not been compiled or run here.
