# Eco IO API: Task error-handling audit

## The headline finding

Almost every IO task in `Eco.*` is typed `Task Never x`, but **the kernels do not
honour that contract**. Of the modules that do real IO, the JavaScript backing
implementations call `__Scheduler_fail(e.message)` inside `catch` blocks all over
the place (`File.js`, `Console.js`, `Process.js`). So the `Never` error channel —
which the type says is uninhabited — is in fact populated with a `String` at
runtime.

The only functions whose types are *honest* about failure are
`Eco.NativeDriver.lowerAndLink` / `lowerAndLinkBytes`, typed `Task String ()`.

### What happens when a `Task Never` actually fails

This isn't harmless. Tracing the scheduler in `elm.js:1790` (`_Scheduler_step`): a
failure root (`rootTag === 1`) walks the continuation stack `proc.g` looking for an
error handler (a `$ === 1` frame, installed by `Task.onError`). A `Task Never`
program never installs one, so the loop hits `!proc.g` and just **`return`s** — the
fiber is silently abandoned mid-flight. The `andThen` chain after it never runs,
nothing is logged, the process doesn't crash. **A failing `Task Never` is a silent
halt, which is worse to debug than a crash.**

So "is it OK to be a `Task Never`?" has a sharp answer: it's only OK if the kernel
*genuinely cannot* call `fail` — otherwise the type is actively dangerous.

## The table

Legend for the verdict column:

- ✅ **Honest Never** — kernel can't fail; type is correct.
- 🩹 **Never by swallowing** — kernel catches errors and returns a sentinel
  (`false`/`Nothing`/fallback/`undefined`); type is technically sound but hides
  real failures.
- ❌ **Lying Never** — kernel calls `__Scheduler_fail`; error channel is populated
  at runtime despite `Never`. Soundness hole → silent fiber death.
- 🟢 **Typed errors** — already carries a real error type.

### Eco.Console

| Function | Type | Verdict | Errors to handle / rationale |
|---|---|---|---|
| `write` | `Handle -> String -> Task Never ()` | ❌ | Kernel `fail`s. Writing is **not** always safe: `EPIPE` (piped into `head`/closed reader — the classic broken-pipe), `EBADF` on a closed process pipe handle, `ENOSPC` to a file-backed handle. The "would we expect console writes to always work?" intuition is right to doubt — they don't. |
| `readLine` | `Task Never String` | 🩹 | No try/catch at all. EOF is folded into `""` (indistinguishable from a blank line). A `stdin` `'error'` event would surface as an **uncaught JS exception** crashing the whole runtime, not a Task failure. |
| `readAll` | `Task Never String` | 🩹 | Same: no `'error'` handler on stdin; read errors crash the runtime rather than failing the task. |
| `log` | `String -> a -> a` | — | Not a Task. Pure trace; swallows its own errors by design. Fine. |

### Eco.File — the worst offender

Every path-based op has a `catch { fail(e.message) }`. These are the
bread-and-butter filesystem errors that real programs must handle.

| Function | Type | Verdict | Errors to handle / rationale |
|---|---|---|---|
| `readString` | `String -> Task Never String` | ❌ | `ENOENT`, `EACCES`, `EISDIR`. Reading a missing/forbidden file is *expected*, not exceptional. |
| `writeString` | `String -> String -> Task Never ()` | ❌ | `EACCES`, `ENOENT` (parent dir missing), `ENOSPC`, `EROFS`. |
| `readBytes` | `String -> Task Never Bytes` | ❌ | As `readString`. |
| `writeBytes` | `String -> Bytes -> Task Never ()` | ❌ | As `writeString`. |
| `open` | `String -> IOMode -> Task Never Handle` | ❌ | `ENOENT`, `EACCES`. |
| `close` | `Handle -> Task Never ()` | ❌ | `EBADF`. Minor, but still `fail`s. |
| `hWriteString` | `Handle -> String -> Task Never ()` | ❌ | `EBADF`, `EPIPE`. |
| `size` | `Handle -> Task Never Int` | ❌ | `EBADF`. |
| `lock` | `String -> Task Never ()` | 🩹 | **Unimplemented no-op** — always succeeds. Safe *only because it does nothing*; a real impl can block/`EWOULDBLOCK`/`EACCES`. The type will be a lie the moment it's implemented. |
| `unlock` | `String -> Task Never ()` | 🩹 | No-op stub, same caveat. |
| `fileExists` | `String -> Task Never Bool` | 🩹 | Catches → `false`. Conflates "doesn't exist" with `EACCES` (permission-denied on a path that *does* exist reports `false`). |
| `dirExists` | `String -> Task Never Bool` | 🩹 | Same conflation as `fileExists`. |
| `findExecutable` | `String -> Task Never (Maybe String)` | ✅ | Genuinely can't fail — loops PATH, returns `Nothing` if not found. `Maybe` is the right error model. |
| `list` | `String -> Task Never (List String)` | ❌ | `ENOENT`, `ENOTDIR`, `EACCES`. |
| `modificationTime` | `String -> Task Never Time.Posix` | ❌ | `ENOENT`. |
| `touch` | `String -> Task Never ()` | ❌ | `EACCES`, `ENOSPC`. |
| `getCwd` | `Task Never String` | 🩹 | No try/catch; `process.cwd()` throws `ENOENT` if the cwd was unlinked → uncaught exception, not a Task fail. Rare but real. |
| `setCwd` | `String -> Task Never ()` | ❌ | `ENOENT`, `ENOTDIR`, `EACCES`. |
| `canonicalize` | `String -> Task Never String` | 🩹 | On failure silently falls back to `path.resolve` (a lexical, non-symlink-resolving result). Degrades quietly — caller can't tell the path didn't really resolve. |
| `appDataDir` | `String -> Task Never String` | ✅ | Pure path computation from `os.homedir()`/env. No IO. |
| `createDir` | `Bool -> String -> Task Never ()` | ❌ | `EACCES`, `ENOSPC`, `EEXIST` (path is a file), `ENOTDIR`. |
| `removeFile` | `String -> Task Never ()` | ❌ | `ENOENT`, `EACCES`, `EPERM`. |
| `removeDir` | `String -> Task Never ()` | ❌ | Uses `force:true` so `ENOENT` is swallowed, but `EACCES`/`EPERM`/`ENOTEMPTY`-equivalents still `fail`. |

### Eco.Http — genuinely `Never`, but the *Result* shape is the problem

Both kernels never call `fail` — every error path goes into `Result.Err`. So these
are *honest* `Task Never` values. The flaw is in the error type.

| Function | Type | Verdict | Errors to handle / rationale |
|---|---|---|---|
| `fetch` | `… -> Task Never (Result { statusCode, statusText, url } String)` | ✅ Never / ⚠️ error model | The Task can't fail, good. **But** transport-level failures — DNS (`ENOTFOUND`), connection refused (`ECONNREFUSED`), timeout, no route, TLS errors, and even gzip/inflate decode failures — are all crammed into `Result.Err` with the sentinel `statusCode = 0` and the OS message dumped into `statusText`. A consumer can't structurally distinguish "the server said 404" from "there is no network." The "no reachable network" case *is* signalled, but only as a magic `0` that collides with the HTTP-status shape. |
| `getArchive` | `… -> Task Never (Result String { sha, archive })` | ✅ Never / ⚠️ error model | Same: network errors, non-2xx, and zip-parse failures all collapse into one flat `String`. No way to branch on category. |

### Eco.Env

| Function | Type | Verdict | Errors to handle / rationale |
|---|---|---|---|
| `lookup` | `String -> Task Never (Maybe String)` | ✅ | Reads `process.env`; missing → `Nothing`. Correct. |
| `rawArgs` | `Task Never (List String)` | ✅ | Reads `process.argv`; can't fail. |

### Eco.Process

| Function | Type | Verdict | Errors to handle / rationale |
|---|---|---|---|
| `exit` | `ExitCode -> Task Never ()` | ✅ | Calls `process.exit`; never returns at all. Correct. |
| `spawn` | `String -> List String -> Task Never ProcessHandle` | ❌ | `fail`s on `ENOENT` (command not found) and `EACCES`. Spawning a missing binary is a *routine, expected* error — one of the most important to fix. |
| `spawnProcess` | `{…} -> Task Never {…}` | ❌ | Same as `spawn`. |
| `wait` | `ProcessHandle -> Task Never ExitCode` | ✅ | Can't fail; non-zero exit is modelled cleanly via `ExitCode`/`ExitFailure`. Good design — the template the rest of the API should follow. |

### Eco.MVar

| Function | Type | Verdict | Errors to handle / rationale |
|---|---|---|---|
| `new` | `Task Never (MVar a)` | ✅ | Allocates a store slot; can't fail. |
| `read` | `Decoder a -> MVar a -> Task Never a` | 🩹 | Honest re: failure, but a **read of a dropped/missing MVar returns JS `undefined`** as the result value — a non-Elm value handed back as an `a`. That's silent type-corruption, not a clean error. |
| `take` | `Decoder a -> MVar a -> Task Never a` | 🩹 | Same `undefined`-leak on a missing MVar. |
| `put` | `(a -> Encoder) -> MVar a -> a -> Task Never ()` | ✅ | Missing MVar → silently succeeds; on a live MVar always completes. |
| `drop` | `MVar a -> Task Never ()` | ✅ | Idempotent delete; can't fail. |

### Eco.Runtime

| Function | Type | Verdict | Errors to handle / rationale |
|---|---|---|---|
| `dirname` | `Task Never String` | ✅ | Returns `__dirname`. |
| `random` | `Task Never Float` | ✅ | `Math.random()`. |
| `saveState` | `Encode.Value -> Task Never ()` | ✅ | Stores into an in-memory module var. (Would change if backed by disk.) |
| `loadState` | `Task Never Encode.Value` | ✅ | Reads that var; `null` when unset. |

### Eco.NativeDriver — the only honest module

| Function | Type | Verdict | Errors to handle / rationale |
|---|---|---|---|
| `lowerAndLink` | `String -> String -> Task String ()` | 🟢 | Correctly typed: stub always fails in JS bootstrap; native pipeline can fail at any stage (`rc != 0`, "native driver unavailable"). |
| `lowerAndLinkBytes` | `Bytes -> String -> Task String ()` | 🟢 | Same. |

### Eco.Crash

| Function | Type | Verdict | Errors to handle / rationale |
|---|---|---|---|
| `crash` | `String -> a` | — | Not a Task. Prints a stack trace and `process.exit(1)`. Intentionally total/diverging. Fine. |

## Summary counts

- **❌ Lying `Never` (kernel calls `fail`):** 18 — `Console.write`;
  `File.{readString, writeString, readBytes, writeBytes, open, close,
  hWriteString, size, list, modificationTime, touch, setCwd, createDir,
  removeFile, removeDir}`; `Process.{spawn, spawnProcess}`.
- **🩹 Never-by-swallowing (hides/sentinels errors, incl. uncaught-throw and
  `undefined`-leak risks):** 10 — `Console.{readLine, readAll}`;
  `File.{lock, unlock, fileExists, dirExists, getCwd, canonicalize}`;
  `MVar.{read, take}`.
- **✅ Honest `Never`:** the rest of `Env`, `Runtime`, `MVar.{new,put,drop}`,
  `Process.{exit,wait}`, `File.{findExecutable, appDataDir}`, plus
  `Http.{fetch, getArchive}` (Task-honest, but ⚠️ error *model* collapses
  transport vs HTTP errors).
- **🟢 Typed errors:** `NativeDriver.*`.

## On the specific questions

- **"Is writing the console OK to be error-free?"** No. `Console.write` /
  `File.hWriteString` hit `EPIPE` whenever the downstream reader closes early
  (e.g. `yourprog | head`), plus `EBADF` on closed process pipes. The kernel
  already `fail`s on these — so today they cause a silent fiber halt. This one
  deserves a real error type as much as file IO does.
- **"Http can't signal hard errors like no network."** It *does* signal them, but
  dishonestly: they're squeezed into `Result.Err` with `statusCode = 0`,
  indistinguishable-by-type from an HTTP status error. The fix isn't to add a Task
  error channel (the kernel is already total) — it's to widen the `Err` payload
  into a sum type, e.g. `Timeout | NetworkError String | BadStatus { statusCode,
  statusText, url }`.

## Suggested direction

Three distinct remediation buckets, in priority order:

1. **The 18 ❌ functions** should change from `Task Never x` to `Task IOError x`
   (or per-module error sums), so the kernel's existing `fail` calls become
   type-visible and callers are *forced* to handle the silent-halt cases.
   `Process.wait`'s `ExitCode` and `File.findExecutable`'s `Maybe` are the in-repo
   models to imitate.
2. **`Http.fetch`/`getArchive`** keep `Task Never` but replace the
   `statusCode = 0` sentinel with a proper error sum distinguishing transport from
   HTTP failures.
3. **The 🩹 swallowers** are judgement calls: `fileExists`/`dirExists` returning
   `Bool` is arguably fine, but the `EACCES→false` conflation and the
   `MVar.read→undefined` leak are latent bugs worth closing regardless of the
   typing decision. `readLine`/`readAll`/`getCwd` should at least gain try/catch so
   a stdin/cwd error becomes a Task failure instead of an uncaught exception that
   takes down the whole runtime.

Bucket 1 + the `MVar` `undefined`-leak are genuine correctness issues (silent
fiber death / type corruption); buckets 2–3 are API-honesty improvements.

---

# Part II — Follow-up investigation (remediation design)

This part assumes we commit to giving the IO tasks a real error channel and works
through the four design questions that raises. It draws on the native runtime
(`runtime/src/platform/Scheduler.cpp`, `eco-kernel-cpp/src/eco/*.cpp`) and the
compiler's call graph (`compiler/src`), not just the Elm API surface.

## Q1 — How should errors be represented?

### What the kernels can actually produce today

The error payload that reaches Elm is constructed in C++/JS. Right now it is
**always a bare `String`**:

- Native: `taskFailString(msg)` in `eco-kernel-cpp/src/eco/KernelHelpers.hpp:64`
  allocates an `ElmString` and wraps it in `Task_Fail`. Every native kernel error
  is a hand-written sentence (`"File not found: " + path`, `"fork failed"`, …).
  The underlying `errno` is **discarded** — e.g. `File::readString`
  (`eco/File.cpp:18`) only checks `if (!file)` and never reads `errno`.
- JS bootstrap: `__Scheduler_fail(e.message)` — also just a string.

So "String is enough for a first pass" is not merely acceptable, it is *what the
kernels emit today*. A first pass can land with zero kernel changes: flip the
types from `Task Never x` to `Task String x` and the existing messages flow
through.

### The better target: structured errors with a String catch-all

A bare string can't be branched on. The high-value distinction the compiler
actually needs is "file genuinely missing" vs "permission denied" vs "everything
else", because those drive different user-facing advice. Proposed shapes:

```elm
-- Eco.IO.Error — shared by File / Console / Process (they all bottom out in errno)
type IOError
    = FileNotFound FilePath          -- ENOENT
    | PermissionDenied FilePath      -- EACCES, EPERM
    | NotADirectory FilePath         -- ENOTDIR
    | IsADirectory FilePath          -- EISDIR
    | AlreadyExists FilePath         -- EEXIST
    | NoSpaceLeft                    -- ENOSPC
    | TooManyOpenFiles               -- EMFILE / ENFILE
    | BrokenPipe                     -- EPIPE  (Console.write down a closed pipe)
    | BadFileDescriptor              -- EBADF
    | OtherIOError                   -- catch-all; ALWAYS keep this
        { errno : Int, path : Maybe FilePath, message : String }
```

```elm
-- Eco.Http.Error — a separate domain; do NOT force network errors into IOError
type HttpError
    = Timeout
    | NetworkUnreachable String      -- DNS / ECONNREFUSED / no route / TLS
    | BadStatus { statusCode : Int, statusText : String, url : String }
    | BadBody String                 -- gzip/inflate/decode failure

-- Eco.Process.Error
type ProcessError
    = CommandNotFound String
    | SpawnFailed { cmd : String, message : String }
```

Design decisions worth stating:

1. **A `String` (or `{ message : String }`) catch-all constructor is mandatory,
   not optional.** Three independent sources can only ever produce a string: the
   JS bootstrap kernels (`e.message`), the C++ `catch (std::exception&)` /
   `catch (...)` paths (see Q2), and any `errno` value we haven't mapped yet.
   `OtherIOError`/`BadBody`/`SpawnFailed{message}` are those escape hatches.
2. **Keep the classification logic in Elm, keep C++ dumb.** Rather than have each
   C++ kernel decide which constructor to build, have the kernels return a small
   record `{ errno : Int, path : String, message : String }` (replacing today's
   `taskFailString`) and do the `errno → constructor` mapping once, in Elm. That
   localizes the only interesting logic to a testable Elm function and keeps the
   ~30 kernel call sites a mechanical "return errno instead of a sentence" edit.
   The kernels must start reading `errno` (they currently don't).
3. **One shared `IOError` for the filesystem/console/process family; a distinct
   `HttpError`.** They share an errno-shaped origin, so a single decoder serves
   File/Console/Process. HTTP has genuinely different categories (transport vs
   status vs body) and already returns a `Result` payload, so it stays separate —
   this is also the fix for the `statusCode = 0` sentinel flagged in Part I.

### Phasing

- **Phase 1 (cheap):** `Task Never x → Task String x`; existing messages flow; the
  compiler's existing rendering just prints the string. Unblocks everything below.
- **Phase 2:** kernels return `{ errno, path, message }`; introduce the structured
  types above with the `errno → constructor` decoder in Elm; render properly (Q3).

## Q2 — The scheduler vs. C++ exceptions (the "a Task MUST respond" contract)

### The contract, confirmed in the runtime

A `Task_Binding` is the only place async/native work happens. In
`Scheduler.cpp:742-784` the binding's callback is invoked and is expected to call
its **resume closure exactly once** (succeed or fail); until it does, the fiber is
parked and `stepProcess` `break`s (line 783). If the resume is never called, the
process is stuck. (Confirmed symmetric in the MVar evaluators, which either call
`callClosure1(resume, …)` now or register a pending resume for later —
`eco-kernel-cpp/src/eco/MVar.cpp:138-222`.)

A failure that *is* produced but unhandled doesn't hang — it's dropped: the native
runtime even logs it (`Scheduler.cpp:700-710`,
`"unhandled top-level Task.fail … failure value dropped"`), which is strictly
better than the JS path's silent halt described in Part I.

### How native kernels behave today

Expected failures are already handled **by return value, not exceptions**: every
native kernel checks its C return codes and returns a `Task_Fail` HPointer via
`taskFailString` (`eco/File.cpp`, `eco/Process.cpp` `fork()<0`, `eco/Http.cpp`
curl init). So the *expected-error* contract is honored.

The gap is **unexpected C++ exceptions**, and it is serious:

- **There is no `try/catch` anywhere on the path.** Not in the kernel bodies, not
  in the `extern "C"` export wrappers (`eco/FileExports.cpp` etc.), not in
  `stepProcess` (`Scheduler.cpp`), not in `eco_main_thread` / `main`
  (`runtime/src/codegen/eco_entry.cpp:144-290`).
- C++ stdlib operations inside the kernels *can* throw: `std::bad_alloc` from
  `std::ostringstream << rdbuf()` / `std::vector<uint8_t> buffer(size)` /
  `std::string content(st.size, …)` on large files (`File.cpp:24,48`,
  `Http.cpp:184`); `std::filesystem_error` from the **throwing**
  `std::filesystem::absolute` in `File::canonicalize`'s fallback (`File.cpp:213`);
  `std::length_error`. These propagate out of an `extern "C"` function — which is
  **undefined behaviour** at the C ABI boundary — and, in practice, reach the top
  with no handler → `std::terminate` → `SIGABRT`. The signal handler in
  `eco_entry.cpp:224-259` prints GC stats and re-raises, so the crash is at least
  observable, but the Task contract is violated by a *crash* rather than a *hang*.

### Fix: a guard at the C-linkage boundary

Exceptions must not cross `extern "C"` anyway, so the natural and complete place to
catch is each `*Exports.cpp` wrapper. A single macro keeps it uniform:

```cpp
// Wrap a kernel body so any C++ exception becomes a Task_Fail instead of
// crossing the extern "C" boundary (UB) or terminating the process.
#define ECO_KERNEL_GUARD(BODY)                                              \
    try { BODY }                                                            \
    catch (const std::bad_alloc&) { return Elm::oomAbort(); /* see below */}\
    catch (const std::system_error& e) {                                    \
        return Eco::Kernel::taskFailErrno(e.code().value(), e.what()); }    \
    catch (const std::exception& e) {                                       \
        return Eco::Kernel::taskFailString(e.what()); }                     \
    catch (...) {                                                           \
        return Eco::Kernel::taskFailString("unknown native error"); }
```

`std::filesystem_error` and `std::ios_base::failure` both derive from
`std::system_error`, so they carry an `errno`-bearing `error_code` straight into
the structured `IOError` from Q1.

### Fatal vs. recoverable — what C++ lets us distinguish

| Class | Examples | Catchable? | Recommended handling |
|---|---|---|---|
| Recoverable IO | `std::system_error`, `std::filesystem_error`, `std::ios_base::failure` | yes | → structured `Task_Fail` (errno-mapped) |
| Generic C++ | any other `std::exception` | yes | → `Task_Fail` with `e.what()` (String catch-all) |
| Foreign throw | `catch (...)` | yes | → `Task_Fail "unknown native error"` |
| **OOM** | `std::bad_alloc` | yes, but special | **Do not funnel into a normal fail** — building the error value re-allocates and may re-throw. On a GC runtime heap exhaustion is effectively terminal: print a clear OOM line and `abort()`, or return a **pre-allocated static** OOM error value reserved at startup. |
| **Signals** | SIGSEGV/SIGBUS (faults), SIGTERM/SIGINT (shutdown), SIGKILL (uncatchable), stack overflow | **no** (not C++ exceptions; `try/catch` can't see them) | Out of scope for Task responses — exactly the "acceptable not to handle" cases. Leave to the existing signal handlers. Process shutdown is correct-by-construction: the process dies and the in-flight Task simply ceases to exist. |

So the user's intuition is right: OOM and "process being shut down" are the two
categories it's acceptable *not* to convert into Task responses. Everything else
should become a `Task_Fail` so the Elm-side contract ("a binding always resumes")
is restored.

### Two adjacent native bugs to fix in the same pass

- **SIGPIPE.** `eco_entry.cpp:252-258` installs a SIGPIPE handler that re-raises
  `SIG_DFL` → writing down a closed pipe *kills the process*. And native
  `Console::write` (`eco/Console.cpp:11-21`) ignores the `::write` return value
  entirely. To make `BrokenPipe` a recoverable Task error we must
  `signal(SIGPIPE, SIG_IGN)` (or use `MSG_NOSIGNAL`) **and** check `::write`'s
  return / `errno`. Today EPIPE is doubly lost.
- **`assert` on a missing MVar.** `MVar::read/take/put` (`eco/MVar.cpp:237,255,279`)
  `assert(it != s_mvars.end())`. In release (`NDEBUG`) the assert vanishes and the
  binding evaluators silently abandon the fiber (return unit, never resume) — a
  stuck-task contract violation. This should become an explicit `Task_Fail`, not an
  assert/UB.

## Q3 — Call-site impact assessment, error threading, and rendering

### The leverage point: the change is self-enumerating

The compiler already runs the standard elm-compiler dual-Task pattern:

- `IO a` is morally `Task Never a`; programs run via `System.IO.run : Task Never () -> Program`.
- `Utils/Task/Extra.elm` is the bridge layer:
  - `io  : Task Never a -> Task x a` = `Task.mapError never`  (`Extra.elm:59`)
  - `eio : (x -> y) -> Task Never (Result x a) -> Task y a`    (`Extra.elm:85`)
  - `run : Task x a -> Task Never (Result x a)`                (`Extra.elm:37`)

The key fact: **`io` calls `never`.** The instant an Eco IO primitive becomes
`Task IOError a`, every `io`-wrapped call site stops type-checking, because `never`
demands a `Never` error. The compiler will therefore *hand us the exact list of
call sites that need attention*. Migration is "follow the type errors," not a
manual hunt — the impact surface is mechanically discoverable.

### Where the calls live (assessment)

| Eco module | Call sites | Where | Choke point to edit |
|---|---|---|---|
| `Eco.File` | heavy (~25) | `Utils/Main.elm`, `Builder/File.elm`, `Builder/Deps/Registry.elm`, `System/IO.elm`, `Compiler/Generate/MLIR/Backend.elm` | **`Builder/File.elm`** (binary/utf8 read/write), `System/IO.elm`, `Utils/Main.elm` (dir ops) |
| `Eco.Console` | medium (~8) | `Utils/Main.elm`, `Builder/File.elm`, `System/IO.elm`, `API/Main.elm` | `System/IO.elm` |
| `Eco.Process` | medium (~8) | `System/Process.elm`, `System/Exit.elm`, `API/Main.elm` | `System/Process.elm` |
| `Eco.Http` | light (2) | `Builder/Http.elm` | `Builder/Http.elm` (already has its own `Error`) |
| `Eco.Env` | light (3) | `Utils/Main.elm`, `API/Main.elm` | leave `Task Never` (Part I: honest) |
| `Eco.Runtime` | light (3) | `Utils/Main.elm`, `Control/Monad/State/Strict.elm` | leave `Task Never` |
| `Eco.MVar` | heavy (6 wrappers, many uses) | `Utils/Main.elm` wrappers; consumed in `Build.elm`, `Details.elm`, `Generate.elm`, `BackgroundWriter.elm` | see Q4 |
| `Eco.NativeDriver` | light (1) | `Terminal/Make.elm` | already `Task String ()` |

There is **no single IO monad** everything funnels through, but there are a few
natural wrapper modules (`Builder.File`, `System.IO`, `System.Process`,
`Builder.Http`, `Utils.Main`) — edit those and most call sites are covered.

### Threading strategy

Add one bridge to `Utils.Task.Extra` mirroring `eio`, for tasks that fail in the
IO channel directly:

```elm
-- Map a real IO failure into the caller's local error type.
ioErr : (IOError -> x) -> Task IOError a -> Task x a
ioErr toX = Task.mapError toX
```

Then at each (now type-erroring) call site, replace `io thing` with
`ioErr (Exit.… ) thing`, choosing the `Exit.*` constructor that fits the
subsystem:

| Subsystem | Maps IOError into |
|---|---|
| `Builder.File` during a build | `Exit.BuildProblem` (add `BP_IO IOError`) — joins `BP_PathUnknown` etc. |
| `Builder.Deps.Registry` / `Builder.Http` | `Exit.RegistryProblem` (extend with transport-vs-status from `HttpError`) |
| `Terminal.Make` (NativeDriver) | `Exit.Make` / `Exit.Generate` (already a `String` error) |
| REPL IO (`System.IO`, `Utils.Main`) | `Exit.Repl` |
| `System.Process` build hooks | the relevant command's `Exit.*` branch |

### Rendering — make it Elm-quality

The central machinery exists and is where new IO errors must plug in:

- `Builder/Reporting/Exit.elm` — the central `Exit` sum (`Init`, `Install`, `Make`,
  `Repl`, `BuildProblem`/`BuildProjectProblem`, `RegistryProblem`, `Details`,
  `Outline`, `Generate`, …). **There is no general IO/filesystem constructor today**
  — the closest is `BP_PathUnknown FilePath`. This is the main type to extend.
- `Builder/Reporting/Exit/Help.elm` — the renderer: `Report`,
  `report : String -> Maybe String -> String -> List Doc -> Report`,
  `reportToDoc`, `reportToJson`, `toStderr`.
- `Builder/Reporting.elm` — `attempt`/`attemptWithStyle` run a
  `Task Never (Result x a)`, convert `x` to a `Help.Report`, and exit. This is the
  top-level funnel where a propagated IO error becomes terminal output.

A good IO-error report follows the existing Elm house style: an ALL-CAPS title
(`FILE NOT FOUND`, `PERMISSION DENIED`), the offending path, what the compiler was
trying to do, the raw OS message, and a concrete hint. Sketch:

```elm
toReport : IOError -> Help.Report
toReport err =
    case err of
        FileNotFound path ->
            Help.report "FILE NOT FOUND" (Just path)
                "I was looking for this file but it does not exist:"
                [ D.indent 4 (D.fromChars path)
                , D.reflow "Was it moved or deleted? Check the path and try again."
                ]
        PermissionDenied path -> …
        OtherIOError r -> Help.report "FILE ERROR" r.path r.message [ … ]
```

### Bootstrap caveat

The JS bootstrap stages link the JS kernels, which only ever produce `e.message`.
So whatever type we pick must degrade to the `OtherIOError {message}` / String
catch-all when running under the bootstrap — another reason the catch-all in Q1 is
load-bearing. Structured `errno` classification only kicks in on the native path.

## Q4 — MVar coordination: avoiding deadlock on the new error paths

### The architecture already encodes failures as values, not Task errors

This is the most important finding for this question. The parallel build does **not**
let compile failures fail tasks — it stores them as ordinary values in the result
MVars: `BResult` has `RProblem`, `RBlocked`, `RNotFound`
(`Builder/Build.elm:744`), and the join logic pattern-matches them
(`Build.elm:1071-1078`). Tasks are deliberately `Task Never (…)`.

The whole fork/join model rests on one invariant: **every MVar is `put` exactly
once.** It's even spelled out in the code — `Build.elm:835-841`: *"this MVar … MUST
be filled here — leaving it empty deadlocks any later changed module that tries to
load this dep's interface."* The `fork` combinator guarantees it structurally by
making the put the **last** action:

```elm
-- Builder/Build.elm:198
fork encoder work =
    Utils.newEmptyMVar
        |> Task.andThen (\mvar ->
            Utils.forkIO (Task.andThen (Utils.putMVar encoder mvar) work)  -- put is last
                |> Task.map (\_ -> mvar))
```

### Exactly the hazard the question anticipates

If `work` becomes `Task IOError a` (can now fail), then
`Task.andThen (putMVar mvar) work` **skips the put on the failure path** → the MVar
is never filled → every `readMVar`/`takeMVar` on it blocks.

Native manifestation, precisely: a parked reader/taker calls
`incrementPendingAsync()` (`MVar.cpp:157,187,217`). The event loop only terminates
when `pendingAsync_ == 0` (`Scheduler.cpp:510`). An orphaned waiter pins that
counter above zero **forever**, so the build **hangs permanently** — it does not
crash and does not exit. (Contrast: if nothing were keeping the loop alive it would
*exit early* with the answer never produced. The `incrementPendingAsync` on park is
what turns it into a true hang.) This is the deadlock the question predicts, and
it is real, not theoretical.

### Options

**Option A — keep `fork` total; carry the error in the MVar payload (recommended).**
Wrap the fallible work in the existing `Utils.Task.Extra.run` so the put *always*
happens, with a `Result`:

```elm
fork : (Result x a -> BE.Encoder) -> Task x a -> Task Never (MVar (Result x a))
fork encoder work =
    Utils.newEmptyMVar
        |> Task.andThen (\mvar ->
            Utils.forkIO (Extra.run work |> Task.andThen (Utils.putMVar encoder mvar))
                |> Task.map (\_ -> mvar))
```

The join then reads a `Result`, short-circuits on the first `Err`, and propagates
the error via the *parent's* error channel. This:
- preserves the "always fill the slot" invariant the code already depends on;
- is exactly the established `RProblem`-as-value pattern, extended from compile
  errors to IO errors (so it's idiomatic here, not a new concept);
- needs **no** scheduler, cancellation, or kill machinery — lowest risk.

This is "propagate errors via MVars," and it's the right answer because the build's
existing design is *already* value-propagation; we're just widening the payload.

**Option B — structured cancellation (kill siblings on first error).** Tempting, but
`Scheduler::killTask` is explicitly *best-effort* and does not reliably stop a
parked fiber (`Scheduler.cpp:439-462`: *"This is a best-effort kill — a full
solution would need runQueue-side bookkeeping per logical process id"*). Building
reliable cancellation is a much larger change. Defer.

**Option C — poison/drop on teardown.** `Eco.MVar.drop` already "abandons waiters"
and balances `pendingAsync` so the loop can exit (`MVar.cpp:301-325`). This is the
built-in unblock primitive — but abandoning a waiter *silently drops its
continuation* (no value delivered), so it only suits whole-build teardown *after*
the error has been captured elsewhere (e.g. via Option A), never per-task
propagation. Useful as the final-cleanup step, not the mechanism.

### The separate take-then-put bracket hazard

Two sites do `takeMVar … fallibleWork … putMVar` rather than fork-then-put:

- `loadInterface` (`Build.elm:1175`): takes a `CachedInterface`, reads it, puts it
  back.
- `BackgroundWriter` (`Builder/BackgroundWriter.elm`): takes the work-list, writes,
  signals completion.

If the fallible middle now fails, the slot is left **empty *and* the taken value is
lost** — strictly worse than the fork case, because even a retry can't recover the
value. These need a bracket / `finally`:

```elm
Utils.takeMVar dec mvar
    |> Task.andThen (\v ->
        fallible v
            |> Task.onError (\e ->
                -- restore the slot before propagating, or no one else can proceed
                Utils.putMVar enc mvar v |> Task.andThen (\_ -> Task.fail e)))
```

### The invariant to adopt (and ideally enforce)

> For every MVar, exactly one `put` occurs on every control-flow path — success or
> failure. Fallible producers are wrapped with `run` (fill the slot with a
> `Result`); take-then-put brackets restore the slot on error.

Pushing the `run` into `fork` makes this structural rather than per-site
discipline, which is what closes the deadlock class — including the pre-existing
latent one already flagged at `Build.elm:835` (the `RBlocked` path that can return
without initializing the `RCached` slot).

## Consolidated roadmap

1. **Native exception guard (Q2)** — add `ECO_KERNEL_GUARD` to every `*Exports.cpp`
   wrapper; special-case `bad_alloc`; fix SIGPIPE + `Console::write` return check;
   turn the MVar `assert`s into `Task_Fail`. *Restores the "always resume" contract;
   prerequisite for trusting any IO error channel.*
2. **Harden fork/join (Q4)** — push `Extra.run` into `fork`; bracket the
   take-then-put sites. *Must land before or with the type change, or the first
   real IO failure hangs the build.*
3. **Phase-1 types (Q1)** — `Task Never x → Task String x` on the ❌/🩹 functions;
   existing messages render as-is. *Self-enumerating via `io`/`never`.*
4. **Thread + render (Q3)** — add `ioErr`, route each subsystem into `Exit.*`, add
   IO constructors to `Builder.Reporting.Exit` + reports in `Exit/Help`.
5. **Phase-2 structured errors (Q1)** — kernels return `{ errno, path, message }`;
   add `IOError`/`HttpError`/`ProcessError` with errno-decode in Elm; refine HTTP to
   kill the `statusCode = 0` sentinel.
