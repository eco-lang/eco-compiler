# Defer Eager Kernel `Task`s via `taskBinding`

## Status: PLAN ONLY

## Goal

Today most C++ kernel functions in `eco-kernel-cpp/src/eco/` and a handful in
`elm-kernel-cpp/src/` perform their syscall / blocking work **eagerly** — they
run the IO at the moment the kernel function is called from generated code and
then return `taskSucceed(value)` / `taskFail(err)`. The Elm side has no chance
to interleave anything; nothing is parked on the scheduler; nothing observes
the `Task` lifecycle.

The target is the **deferred binding** pattern: each kernel function returns a
`Scheduler::taskBinding(callback)` whose `callback` captures the args, and the
syscall happens **inside** the callback when the scheduler steps the binding.
For example:

```cpp
HPtr Eco_Kernel_File_writeString(HPtr path, HPtr content) {
    return makeBinding([path, content](ResumeFn resume) {
        std::ofstream file(toString(path));
        if (!file) {
            resume(taskFailErrno(errno, …));
            return;
        }
        file << toString(content);
        resume(taskSucceedUnit());
    });
}
```

`Scheduler::taskBinding` lives at `runtime/src/platform/Scheduler.cpp:139`.
`taskSucceed*` / `taskFail*` live at `eco-kernel-cpp/src/eco/KernelHelpers.hpp`.
For working examples of the deferred shape, see:

- `eco-kernel-cpp/src/eco/MVar.cpp` — `readBindingEvaluator` / `takeBindingEvaluator` / `putBindingEvaluator`
- `elm-kernel-cpp/src/core/ProcessExports.cpp` — `sleepBindingEvaluator`
- `elm-kernel-cpp/src/time/TimeExports.cpp` — `timeNowBindingEvaluator`
- `elm-kernel-cpp/src/http/HttpExports.cpp` — `httpBindingEval`

---

## Audit Summary

Legend — **E** = eager IO, **D** = deferred via `taskBinding`,
**PE** = partially eager (fast path bypasses `taskBinding`), **N** = no IO
involved (pure data / scheduler primitive / not a `Task`-producer).

### `eco-kernel-cpp/src/eco/` — Eco-specific kernels

| File:line | Function | Kind | IO performed eagerly |
|---|---|---|---|
| `File.cpp:19`  | `readString(path)`              | E  | `std::ifstream`; reads whole file via `rdbuf()` |
| `File.cpp:31`  | `writeString(path, content)`    | E  | `std::ofstream` open + write |
| `File.cpp:43`  | `readBytes(path)`               | E  | binary read of whole file |
| `File.cpp:58`  | `writeBytes(path, bytes)`       | E  | binary write |
| `File.cpp:73`  | `open(path, mode)`              | E  | `::open()` |
| `File.cpp:93`  | `close(handle)`                 | E  | `::close()` |
| `File.cpp:99`  | `hWriteString(handle, content)` | E  | `::write(fd, …)` |
| `File.cpp:110` | `size(handle)`                  | E  | `fstat()` |
| `File.cpp:120` | `lock(path)` ⁽stub⁾             | E  | TODO — returns success at call time |
| `File.cpp:125` | `unlock(path)` ⁽stub⁾           | E  | TODO — returns success at call time |
| `File.cpp:130` | `fileExists(path)`              | E  | `stat()` |
| `File.cpp:137` | `dirExists(path)`               | E  | `stat()` |
| `File.cpp:144` | `findExecutable(name)`          | E  | parses `PATH`, calls `access()` per dir |
| `File.cpp:168` | `list(path)`                    | E  | `opendir`/`readdir`/`closedir` |
| `File.cpp:187` | `modificationTime(path)`        | E  | `stat()` |
| `File.cpp:200` | `getCwd()`                      | E  | `getcwd()` |
| `File.cpp:208` | `setCwd(path)`                  | E  | `chdir()` |
| `File.cpp:217` | `canonicalize(path)`            | E  | `realpath()` (+ `std::filesystem::absolute` fallback) |
| `File.cpp:228` | `appDataDir(name)`              | E  | reads `HOME` env var |
| `File.cpp:243` | `createDir(parents, path)`      | E  | `std::filesystem::create_director(y/ies)` |
| `File.cpp:258` | `removeFile(path)`              | E  | `unlink()` |
| `File.cpp:267` | `removeDir(path)`               | E  | `std::filesystem::remove_all()` |
| `File.cpp:277` | `touch(path)`                   | E  | `::open(O_CREAT)` + `utimensat()` |
| `Process.cpp:19`  | `exit(code)`                  | E  | `::exit()` — never returns; not strictly a `Task` value |
| `Process.cpp:25`  | `spawn(cmd, args)`            | E  | `fork()` + `execvp()` |
| `Process.cpp:50`  | `spawnProcess(cmd, args, …)`  | E  | `pipe()` + `fork()` + `execvp()` |
| `Process.cpp:124` | `wait(handle)`                | E  | `waitpid()` — **blocks the scheduler thread** |
| `Console.cpp:12`  | `write(handle, content)`      | E  | loop of `::write()` with `EINTR` handling |
| `Console.cpp:44`  | `readLine()`                  | E  | `std::getline(std::cin, …)` — **blocks scheduler thread** |
| `Console.cpp:52`  | `readAll()`                   | E  | reads stdin to EOF — **blocks scheduler thread** |
| `Console.cpp:64`  | `log(tag, value)`             | E  | `::write(STDERR, …)`; returns `value` (identity), not a `Task` wrapper |
| `Env.cpp:19`      | `lookup(name)`                | E  | `getenv()` |
| `Env.cpp:25`      | `rawArgs()`                   | E  | reads `s_argv[]` immediately |
| `Http.cpp:21`     | `fetch(method, url, headers)` | E  | `curl_easy_perform()` — **synchronous**; blocks scheduler thread for whole request |
| `Http.cpp:102`    | `getArchive(url)`             | E  | `curl_easy_perform()` + `SHA1` + libzip extract — **blocks scheduler thread** for whole download |
| `Runtime.cpp:18`  | `dirname()`                   | E  | `readlink("/proc/self/exe")` |
| `Runtime.cpp:34`  | `random()`                    | E  | in-process PRNG; no syscall, but result frozen at call time |
| `Runtime.cpp:40`  | `saveState(state)`            | E  | mutates `s_savedState` immediately |
| `Runtime.cpp:46`  | `loadState()`                 | E  | reads `s_savedState` immediately |
| `NativeDriver.cpp:26` | `lowerAndLink(mlirPath, outputPath)`     | E  | drives MLIR → LLVM → linker **synchronously** |
| `NativeDriver.cpp:38` | `lowerAndLinkBytes(bytes, outputPath)`   | E  | same, with in-memory MLIR bytecode |
| `Crash.cpp:20`    | `crash(message)`              | E  | `fprintf(stderr)` + `backtrace_symbols_fd` + `::exit(1)`; never returns; not a `Task` value |
| `MVar.cpp:234` | `read(id)`        | PE → D | fast path returns `taskSucceed(value)` synchronously when full; otherwise returns `taskBinding(readBindingEvaluator)` and parks the resume in `pendingResumes_` |
| `MVar.cpp:256` | `take(id)`        | PE → D | same shape |
| `MVar.cpp:284` | `put(id, value)`  | PE → D | same shape |
| `MVar.cpp:313` | `drop(id)`        | PE     | in-memory state mutated synchronously; not blocking |
| `MVarExports.cpp:13`   | `Eco_Kernel_MVar_new()`         | PE     | `MVar::newEmpty()` allocates an in-memory slot; no syscall |
| `MVarExports.cpp:37–47`| `_put_Int` / `_put_Float` / `_put_Char` | PE → D | box primitive then delegate to `MVar::put` |

### `elm-kernel-cpp/src/` — stock-Elm kernels

| File:line | Function | Kind | Notes |
|---|---|---|---|
| `core/ProcessExports.cpp:52` | `Elm_Kernel_Process_sleep(time)` | D | `taskBinding(sleepBindingEvaluator)`. ✅ |
| `time/TimeExports.cpp:213` | `Elm_Kernel_Time_now(millisToPosix)` | D | `taskBinding(timeNowBindingEvaluator)`. ✅ |
| `time/TimeExports.cpp:244` | `Elm_Kernel_Time_here()` | E | `localtime_r()` eagerly via `getLocalTimezoneOffset()`. |
| `time/TimeExports.cpp:254` | `Elm_Kernel_Time_getZoneName()` | E | `TZ` env var, `readlink("/etc/localtime")`, `fopen("/etc/timezone")` — filesystem IO at call time. |
| `time/TimeExports.cpp:273` | `Elm_Kernel_Time_setInterval(ms, tagger)` | N | builds a `Sub` Custom; no IO |
| `http/HttpExports.cpp:667` | `Elm_Kernel_Http_toTask(...)` | D | `taskBinding(httpBindingEval)`. ✅ |
| `core/SchedulerExports.cpp` (all) | `Scheduler_succeed/fail/andThen/onError/spawn/kill` | N | pure `Task` constructors |
| `file/File.cpp:96–148` | `toString`/`toBytes`/`toUrl`/`uploadOne`/… | N | `assert(false && "not implemented")` stubs |
| `time/Time.cpp:14–34` | `now`/`here`/`getZoneName`/`setInterval` | N | stubs; real impls live in `TimeExports.cpp` |

### Counts

| Bucket | Count |
|---|---|
| Eager IO, needs conversion to deferred binding | **41 functions** (39 in eco-kernel-cpp + 2 in elm-kernel-cpp/time) |
| Already deferred (`taskBinding`) | 3 Elm + 3 Eco-MVar binding paths |
| Partially eager (fast path bypasses binding) | MVar `read`/`take`/`put`, plus `drop` / `_new` / typed `_put_*` siblings |
| No-IO / pure constructors / stubs / effect-manager glue | rest |

---

## Resolved decisions

(Captured from the design-question pass that preceded this rev of the plan.)

| # | Question | Decision |
|---|---|---|
| Q1 | Helper location | **New header** `eco-kernel-cpp/src/eco/TaskBinding.hpp`. `KernelHelpers.hpp` stays scoped to synchronous / pure helpers. |
| Q2 | Helper API shape | **No** variadic kind-inferred template in Phase 0. Helper takes a single `HPointer` "captured payload" (built via existing alloc helpers — usually a tuple / record / custom). An optional `makeBindingFromCaptured(std::initializer_list<TaggedArg>)` may be added later if raw-primitive captures emerge as a recurring pattern. |
| Q3 | `readLine` / `readAll` true async | **Out of scope.** Implement as bindings with **synchronous evaluators** (Task construction is deferred; the evaluator still blocks on stdin). Plan a separate `StdinService` (worker thread + `pendingResumes_` token, mirror of `TimerService` / `HttpService`) for a follow-up change. |
| Q4 | `Process::wait` strategy | **Two-phase.** Phase 4a: binding with a **blocking evaluator** (Task construction fixed, ordering matches JS, scheduler still blocks during `waitpid`). Phase 4b: replace with **`WaitService`** — `SIGCHLD` + `waitpid(WNOHANG)` worker that registers a `pendingResume` token and drains exits on the main thread. |
| Q5 | MVar PE uniformity | **Keep the fast paths.** They only touch in-process state (mutex + map) — no syscalls — and aren't part of the IO-ordering bug class this plan addresses. The "always binding" reshape is a hypothetical future option, not part of this plan. Phase 9 from the prior draft is **removed.** |
| Q6 | Compiler hot-path overhead | Take a **baseline** (wall-clock, CPU, peak RSS for `cmake --build build --target full`) **before** Phase 3 lands. Re-measure on the **same hardware** after each subsequent phase. Acceptable fallbacks if regression appears: micro-optimise binding allocation (small-capture reuse, avoid unnecessary tuple packing) or special-case very hot side-effect-free kernels (e.g. `rawArgs`) as pure `Task.succeed` constructors. |
| Q7 | `crash` / `exit` / `log` | **Stay eager.** `crash` and `exit` never return; wrapping them in a `Task`/binding would be misleading. `Console::log` is an identity helper, not a `Task` producer. Document each as an explicit exemption from the invariant (Q9). |
| Q8 | `eco-stuff` / `d.dat` impact | No `configHash` / bytecode-layout change. **One-time** `rm -rf build/compiler/build-kernel/eco-stuff` (and any equivalent native cache dirs), then clean bootstrap that asserts: (a) `configHash` unchanged for the same Elm source, (b) MLIR / JS artifacts byte-identical pre/post, (c) only native code bits differ. |
| Q9 | Invariant scope | `KERNEL_TASK_IO_001` covers **every** C++ symbol returning `Task` in `eco-kernel-cpp/` and `elm-kernel-cpp/`. Exemptions, named explicitly in the invariant row: pure `Task` constructors (`Scheduler_succeed/fail/andThen/onError/spawn/kill`, `taskReceive`), terminator non-returners (`Process_exit`, `Crash_crash`), and identity/logging non-`Task` helpers (`Console_log`). |
| Q10 | `Eco.Http` Phase 5 | **Extend `HttpService`** — don't fork an `EcoHttpService`. Teach `HttpService::Result` (or an extension thereof) to carry the extra data `Eco.Http.getArchive` needs (extracted entries, SHA1, archive-specific error variants). The Eco binding evaluator submits to the same pool and post-processes the result (libzip extract + SHA1) into the richer Eco-level shape. Keeps one worker pool, one tracking registry, one `pendingResumes_` integration. |

---

## Implementation Plan

The migration is mechanical per-kernel but touches a lot of surface, so the
plan is staged to keep each step independently testable. Phase 0 builds a
shared helper to avoid hand-rolling closure-capture boilerplate at every site.
Phases 1–7 sweep the eager kernels module-by-module in risk/priority order.
Phase 8 covers the stock-Elm Time exceptions. Phases 10–11 are tests +
invariants + docs.

### Phase 0 — Build a `makeBinding` helper

**Goal:** introduce a single helper that takes a body and a single `HPointer`
"captured payload" (typically a tuple/record/custom built via existing alloc
helpers), and produces a `Task_Binding` HPointer. All eager kernels then
become a small wrapper over this helper.

#### 0.1 Design (per Q1 + Q2)

`Scheduler::taskBinding(HPointer callback)` requires `callback` to be a Custom
closure HPointer whose evaluator the scheduler invokes with `void* args[]`.
Today every site rolls its own:

1. Allocate a closure of arity `2` via `allocClosureK(eval, 2, PK_Boxed)`
   (one captured payload + one runtime-supplied resume arg).
2. `closureCapture(payload, PK_Boxed)`.
3. Write a static `void* eval(void* args[])` that decodes the payload + the
   resume HPointer, calls
   `Scheduler::callClosure1(resume, succeedOrFailTask)`, and returns
   `encode(unit())`.

The helper consolidates this:

```cpp
// "BindingBody" : decode the captured payload and produce the Task to deliver
// to the resume continuation. The helper handles closure construction,
// rooting of the resume HPointer, the callClosure1, and the kill-handle.
using BindingBody = HPointer (*)(HPointer captured);

HPointer makeBinding(BindingBody body, HPointer captured);
```

Per **Q2**, kind-inferred variadic templates are NOT introduced in this
phase. Callers that want to capture multiple values pack them into an Elm
tuple/record/custom themselves using the existing
`tuple2`/`tuple3`/`record`/`custom` helpers in `HeapHelpers.hpp` — the same
layout the scheduler GC scanners already understand. This:

- keeps the Elm/native heap boundary explicit (every captured value is an
  HPointer; no raw int/float aliasing),
- reuses the existing GC-rooting and bitmap rules unchanged,
- keeps the helper's signature trivial.

If, after Phase 3 lands, repeated raw-primitive captures emerge as a real
pattern (and the boxing overhead is measurable per Q6), add
`makeBindingFromCaptured(std::initializer_list<TaggedArg>)` as a follow-up,
mirroring the existing `closureCapture(..., PK_Int/Float/Char)` convention.

Implementation lives in `eco-kernel-cpp/src/eco/TaskBinding.hpp` (Q1). The
helper generates a tiny boilerplate evaluator that:

1. Decodes the captured payload HPointer (already kept alive by the closure's
   capture slot, which the scheduler's GC scanners traverse).
2. Decodes the resume HPointer and roots both via `StackRootGuard` before any
   allocation in `body`.
3. Calls `body(captured)`, which returns a Task HPointer built via
   `taskSucceed*` / `taskFail*` from `KernelHelpers.hpp`.
4. `Scheduler::callClosure1(resume, taskFromBody)`.
5. Returns `encode(unit())` as the kill-handle.

#### 0.2 Verify against existing sites

Refactor `Elm_Kernel_Process_sleep` (the smallest existing deferred site, in
`elm-kernel-cpp/src/core/ProcessExports.cpp`) to use `makeBinding` as the
proof of concept. The sleep currently captures a `double` (millis) directly;
porting it forces us to either (a) box the float into a tiny ElmFloat custom
and pass that as the `captured` HPointer, or (b) decide right now to add the
`makeBindingFromCaptured` shape ahead of schedule. Pick (a) for Phase 0
unless boxing overhead shows up in the baseline measurement — that's
consistent with Q2's "no kind-inferred template yet" decision and verifies
the simple-payload shape actually works.

Confirm `stress` + E2E stay green after the port. This is the only behavioral
change in Phase 0.

#### 0.3 Stack-rooting + GC review

The helper must not regress the rooting discipline currently practised in
MVar / sleep / Http evaluators. Review every existing deferred site against
the helper's generated evaluator and confirm:

- Captures are rooted **before** any allocation in `body`.
- `body` may itself allocate (e.g. `allocStringFromUTF8`) without invalidating
  captures.
- The kill-handle return path doesn't leave dangling HPointer arguments.

### Phase 1 — `eco-kernel-cpp/src/eco/Console.cpp`

**Why first:** smallest module (4 functions), straightforward syscalls, and
`readLine` / `readAll` already block the whole scheduler — the highest
correctness win per LoC.

1. `write(handle, content)` → defer the `::write` loop into the binding body.
2. `readLine()` / `readAll()` → defer the stdin reads into the binding body
   with a **synchronous evaluator** (per Q3). This fixes Task-construction
   ordering but the evaluator still blocks the scheduler thread on stdin;
   true async stdin (a `StdinService` mirror of `TimerService` / `HttpService`)
   is a separate follow-up plan and is explicitly out of scope here. Drop a
   `// TODO(StdinService)` comment at each site referencing this plan.
3. `log(tag, value)` is **not** a `Task` (it's identity on `value`) — per Q7
   it stays eager. Add a comment pointing at the Q7 row of this plan so the
   exemption is obvious to future readers.

### Phase 2 — `eco-kernel-cpp/src/eco/Env.cpp`

Two functions. `lookup(name)` → defer `getenv` into the binding body.
`rawArgs()` → defer the `s_argv[]` walk into the binding body (also
re-evaluates argv at consumption time, in case Env::init were ever called
late — which it isn't today, but keeps the contract honest).

### Phase 3 — `eco-kernel-cpp/src/eco/File.cpp`

Largest module (22 + 2 stubs). **Take the Q6 baseline measurement before this
phase lands** (wall-clock, CPU, peak RSS for `cmake --build build --target full`
on the same hardware that subsequent phases will re-run on). The Eco compiler
itself is the heaviest user of these kernels, so any per-call regression shows
up most clearly here.

Mechanical conversion of each function, in this order to limit churn-per-PR:

1. **Read-only stat-like (cheap):** `fileExists`, `dirExists`,
   `modificationTime`, `size`, `getCwd`, `canonicalize`, `appDataDir`,
   `findExecutable`, `list`.
2. **Mutating filesystem:** `setCwd`, `createDir`, `removeFile`, `removeDir`,
   `touch`.
3. **Read/write streams:** `readString`, `writeString`, `readBytes`,
   `writeBytes`, `open`, `close`, `hWriteString`.
4. **Stubs:** `lock`, `unlock` — keep as no-ops but still go through
   `taskBinding` so the deferral surface is uniform.

For each: rewrite as `makeBinding(...)` with all args packed into one
HPointer payload via the existing `tuple*`/`record`/`custom` helpers (per
Q2's "no kind-inferred templates" decision). The existing `taskSucceed*` /
`taskFail*` / `taskFailErrno` helpers are unchanged and used inside the
body. Re-measure after this phase; if a hot kernel (e.g. `readString` in the
compiler's source-crawling loop) regresses noticeably, apply the Q6
fallbacks — micro-optimise small-capture allocation, or special-case
side-effect-free kernels (e.g. `rawArgs`) as pure `Task.succeed` constructors.

### Phase 4 — `eco-kernel-cpp/src/eco/Process.cpp`

Split into two sub-phases per Q4:

#### Phase 4a — Binding wrapping (blocking evaluator)

1. `spawn` / `spawnProcess` → defer `fork`+`execvp` into the binding body.
2. `wait(handle)` → defer `waitpid` into a binding with a **blocking
   evaluator**. Task construction is now correctly ordered against JS, but
   the scheduler thread still blocks during `waitpid`. Drop a
   `// TODO(WaitService)` comment referencing Phase 4b.
3. `exit(code)` stays eager per Q7 (terminator non-returner; explicit
   invariant exemption — Q9). Annotate as such.

#### Phase 4b — Replace blocking `wait` with `WaitService`

Mirror of `TimerService` / `HttpService`:

1. A worker thread (or signal handler) registers a `SIGCHLD` handler that
   nudges the scheduler via `notifyWorkAvailableFromAsync()` and queues a
   completion record `{pid, exit_status}` whenever
   `waitpid(-1, &st, WNOHANG)` returns a non-zero pid.
2. `Eco_Kernel_Process_wait` binding body: register a `pendingResume`,
   `incrementPendingAsync()`, record `{pid → token}` in a registry, and
   return `unit()` as the kill-handle.
3. The async-source drain (registered with `Scheduler::registerAsyncSource`)
   maps queued completions back to tokens, allocates the
   `taskSucceedInt(exitCode)` on the main thread, and calls
   `callClosure1(resume, succeedTask)` exactly as HTTP does today.
4. GC-rooting: the registry stores only `pid` + `token` (no HPointers), so
   no extra scanner is needed; `pendingResumes_` keeps the resume closure
   alive.

Phase 4b can ship in a separate PR from 4a once 4a is settled.

### Phase 5 — `eco-kernel-cpp/src/eco/Http.cpp`

Worst-case eager-IO offender: synchronous `curl_easy_perform` blocks the
scheduler for the entire network call. Per Q10 we **extend the existing
`HttpService`** (`elm-kernel-cpp/src/http/`) rather than forking a parallel
service:

1. **Extend `HttpService::Request` / `HttpService::Result`** to carry the
   extra payload `Eco.Http.getArchive` needs:
   - On `Request`: an opaque `post_process: enum { None, ExtractArchive }`
     tag (or equivalent flag) so the worker knows whether to also run
     libzip + SHA1 before returning the body.
   - On `Result`: an optional `archive_entries: vector<{path, content}>` +
     `sha1: string` block populated only when `ExtractArchive` was set,
     plus archive-specific error variants if libzip fails.
2. **Worker side:** the existing libcurl-based worker runs as today;
   `ExtractArchive` adds a post-fetch step that runs entirely on the worker
   thread (libzip + OpenSSL SHA1 are thread-safe enough to run here, exactly
   as `Eco.Http.getArchive` does today).
3. **`Eco_Kernel_Http_fetch` binding body:** submit to the same worker pool
   with `post_process = None`. On drain, build the existing Tuple2 response
   shape (`{statusCode, statusText, body}` / err Tuple2) on the main thread
   and `callClosure1(resume, succeedTask)`.
4. **`Eco_Kernel_Http_getArchive` binding body:** submit with
   `post_process = ExtractArchive`. On drain, materialise the
   `(sha, [(path, content)])` Tuple2-of-list on the main thread (same
   rooting discipline as today's eager `getArchive`).
5. **Shared infra reused:**
   - one curl-multi worker pool,
   - one tracking registry (`g_httpTracked` / `g_trackerToken`),
   - one async-source drain registered with `Scheduler::registerAsyncSource`,
   - one `pendingResumes_` integration.

This is the largest semantic change in the plan; it deserves its own dedicated
review and a separate PR (or two: extension first, then Eco.Http port).

### Phase 6 — `eco-kernel-cpp/src/eco/NativeDriver.cpp`

Two functions, both heavy. Options:

- Keep the lowering on the main thread (it's CPU-bound, GC-touching) and just
  wrap in `taskBinding` so it runs at scheduler-step time. Doesn't unblock
  concurrency but matches the contract.
- Move lowering to a worker thread (similar to HTTP). Risky — the LLVM /
  linker stack is not necessarily thread-safe; also touches GC roots since
  the input `bytes` HPointer must stay alive.

Recommend **easy wrap** here; revisit if the MLIR→native compile becomes a
scheduler-fairness problem in practice.

### Phase 7 — `eco-kernel-cpp/src/eco/Runtime.cpp`

1. `dirname()` → defer `readlink` (mostly for uniformity; the call is
   microsecond-scale).
2. `random()` → defer the PRNG draw so successive `Runtime.random` references
   see distinct values, mirroring how `Time.now` was fixed.
3. `saveState` / `loadState` → defer in-memory mutations into the binding
   body. The GC root scanner registered by `registerGcRootScanner` stays as
   is.

### Phase 8 — `elm-kernel-cpp/src/time/TimeExports.cpp`

The two stock-Elm exceptions:

1. `Elm_Kernel_Time_here()` → defer `localtime_r` into the binding body. The
   binding captures nothing. (Matches the existing `Elm_Kernel_Time_now`
   shape.)
2. `Elm_Kernel_Time_getZoneName()` → defer the `TZ` / `/etc/localtime` /
   `/etc/timezone` reads into the binding body. Same shape.

### ~~Phase 9 — MVar PE uniformity~~ (cancelled per Q5)

Removed. `MVar::read/take/put` keep their synchronous fast paths — they only
touch in-process state (mutex + map), no syscalls, and aren't part of the
IO-ordering bug class this plan addresses. The "always binding" reshape
remains a hypothetical future option, not part of this plan.

### Phase 10 — Tests & invariants

1. **Behavioural:** the existing E2E (`cmake --build build --target full`) and
   stress (`cmake --build build --target stress`) suites must stay green
   after each phase; gate each PR on both.
2. **Interleaving sentinel:** add a tiny test where two parallel
   `Process.spawn (Task.map ... (File.readString fileA))` and analogous
   `fileB` tasks are interleaved by `Task.andThen`. With eager IO, both
   syscalls happen at call time, sequentially. With deferred bindings, the
   scheduler observes both binding stalls and can choose order. The test
   asserts the scheduler observes both bindings (e.g. via a probe in
   `TaskBinding.hpp`).
3. **Invariant doc:** per Q9, add a `KERNEL_TASK_IO_*` invariant family to
   `design_docs/invariants.csv`:
   - `KERNEL_TASK_IO_001`: every C++ symbol returning `Task` in
     `eco-kernel-cpp/` and `elm-kernel-cpp/` must perform its IO inside a
     `taskBinding` callback, not at call time. Named exemptions, listed
     verbatim in the invariant row:
     - **Pure Task constructors:** `Elm_Kernel_Scheduler_succeed/fail/andThen/onError/spawn/kill`, `taskReceive`.
     - **Terminator non-returners:** `Eco_Kernel_Process_exit`, `Eco_Kernel_Crash_crash`.
     - **Identity / logging non-`Task` helpers:** `Eco_Kernel_Console_log`.
   - `KERNEL_TASK_IO_002`: binding callbacks must root all HPointer captures
     before any allocation.
4. **Performance check (per Q6):** re-run the wall-clock / CPU / peak-RSS
   measurement of `cmake --build build --target full` on the same hardware
   as the pre-Phase-3 baseline. Note any regression > 5% in the PR
   description and apply Q6 fallbacks (small-capture micro-opt,
   side-effect-free hot kernels as pure constructors) before merging the
   phase that introduced it.
5. **Bootstrap fixed-point (per Q8):**
   - One-time `rm -rf build/compiler/build-kernel/eco-stuff` and any
     equivalent native cache dirs before the first clean rebuild after
     each phase lands.
   - Then rerun the 9-stage chain (`cmake --build build --target bootstrap`)
     and assert:
     - fixed point holds (S5 MLIR == S7a MLIR == S8a MLIR, S8c native ELF,
       `eco-2 == eco-compiler-boot-2`),
     - `configHash` is unchanged for the same Elm source,
     - MLIR / JS artifacts are byte-identical pre/post,
     - only native code bits differ,
     - Gate A (E2E) and Gate B (AOT) both 100%.

### Phase 11 — Documentation

1. Update `eco-kernel-cpp/src/eco/KernelHelpers.hpp` header comment to point
   at `TaskBinding.hpp` and discourage new `taskSucceed*` use in the
   synchronous return position of kernel functions.
2. Add a one-paragraph note to `THEORY.md` or a new
   `design_docs/theory/kernel-task-deferral.md` explaining the invariant and
   pointing at this plan.
3. Cross-link from `plans/bootstrap-io-wiring.md` and
   `plans/eco-kernel-full-implementation.md`, both of which currently describe
   the kernels as eager.

---

## Risk / blast radius

- The Eco compiler is *itself* the heaviest user of these kernels (every
  build crawls thousands of files via `Eco.File.readString` etc.). Phase 3
  must not regress per-call overhead — see Q6 on closure-allocation cost.
- `eco-stuff` cache invalidation: if the kernel functions' Elm-level shape
  changes (e.g. they start returning a `Task` rather than a forced result),
  upstream `d.dat` may break. **Likely not affected** since the Elm-level
  signatures don't change — only the C++ body's eagerness — but worth
  verifying with a one-off bootstrap.
- GC root scanners (HTTP tracking, Runtime saved state, MVar slots, Time
  intervals) all assume main-thread allocation. Worker-pool–based phases (5
  and possibly 4, 6) must follow the same "drain on main thread, no HPointer
  on workers" rule already used by `HttpService`.

---

## Phase ordering rationale

1. Phase 0 (helper) lands once; everything else depends on it.
2. Phases 1, 2, 7, 8 are small (≤ 4 functions each) — good warm-up PRs that
   shake out Phase 0 helper bugs before the big File.cpp churn.
3. Phase 3 (File.cpp) is the biggest mechanical PR; benefits from a settled
   helper. **Q6 baseline measurement happens immediately before this phase**;
   all subsequent phases re-measure on the same hardware.
4. Phases 4a, 5, 6 each introduce or reuse a worker pool — these are the
   riskiest and benefit from a stable test baseline established by
   phases 1–3.
5. Phase 4b (`WaitService`) ships after 4a once stable, in its own PR.
6. Phase 9 from the prior draft is **cancelled** per Q5.
7. Phase 10 (tests + invariants + bootstrap fixed-point checks) and
   Phase 11 (documentation) close out the change.
