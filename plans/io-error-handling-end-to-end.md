# Plan: End-to-end IO error handling (kernels → scheduler → compiler)

Status: IMPLEMENTED (2026-05-29). See "Implementation outcome" at the bottom.

## Goal

Replace the current "all IO is infallible" model (`Task Never a`, errors become
process crashes or dropped failures) with honest, structured IO/HTTP/Process
errors that are:

1. produced by the native (C++), node-JS, and XHR kernels in a *neutral* form,
2. decoded into typed Elm error ADTs in the `Eco.*` kernel wrappers,
3. threaded through the compiler into the existing `Exit.*` / `Help.Report`
   system so every IO failure renders a structured diagnostic, and
4. backstopped by a scheduler/runtime that treats *unexpected* faults as fatal
   with good diagnostics.

This plan is derived from the engineer's design doc, **corrected against the
actual repository state** (see "Deviations from the original design" below).

---

## What the codebase actually looks like today (verified)

Kernel Elm wrappers live in **two** trees that must stay in lockstep:
- Native path: `eco-kernel-cpp/src/Eco/{File,Console,Process,Http,Env,Runtime,MVar,NativeDriver,Crash}.elm`
- XHR/bootstrap path: `compiler/src-xhr/Eco/{File,Console,Process,Http,Env,Runtime,MVar,NativeDriver,XHR}.elm`

Each `Eco.*` wrapper calls phantom `Eco.Kernel.*` primitives. Those primitives
are backed by **three** implementations:
- C++ native kernel: `eco-kernel-cpp/src/eco/*.cpp` + `eco/*Exports.cpp` (C-linkage `Eco_Kernel_<Module>_<fn>`)
- node JS kernel: `eco-kernel-cpp/src/Eco/Kernel/*.js` (`_File_readString`, `__Scheduler_fail`, etc.)
- XHR path: `compiler/src-xhr/Eco/XHR.elm` + browser plumbing

Current error state per module:
- `Eco.File`, `Eco.Console`, `Eco.Process`, `Eco.Env`, `Eco.Runtime`, `Eco.MVar`: **all `Task Never a`**.
- `Eco.Http`: already `Task Never (Result {statusCode,statusText,url} String)`.
- `Eco.NativeDriver`: already `Task String ()`.

**Crucial precedent (linchpin for feasibility):** `Eco.Http` does NOT construct a
user-facing record in the kernel. `eco-kernel-cpp/src/Eco/Http.elm:26-33` shows
the *kernel* returns a primitive **tuple** `(statusCode, statusText)`, and the
Elm wrapper reshapes it into the record. The JS kernel builds
`__Result_Err(__Utils_Tuple2(0, err.message))`
(`eco-kernel-cpp/src/Eco/Kernel/Http.js`). So the proven, low-risk boundary shape
is **tuples/primitives constructed in the kernel, decoded into ADTs in Elm** —
not records constructed in the kernel.

Compiler error plumbing:
- `compiler/src/Utils/Task/Extra.elm` already has `io`, `mio`, `eio`, `run`,
  `throw`. It does NOT have `ioErr` (but `ioErr` is just `Task.mapError`).
- `compiler/src/Builder/Reporting/Exit.elm` (~3023 lines) defines `Make`,
  `BuildProblem`, `BuildProjectProblem`, `Details`, `DetailsBadDep`,
  `RegistryProblem` (already `RP_Http Http.Error`), `Solver`
  (already `SolverBadHttp ... Http.Error`), `Repl`, `Test`, `Init`, `Diff`,
  `Bump`, `Generate`, `Outline`.
- `compiler/src/Builder/Reporting/Exit/Help.elm` renders via `Help.report` /
  `Help.docReport` → `Report`. Each `xToReport` pattern-matches the ADT.
- Top-level run/exit: `Builder.Reporting.attempt` / `attemptWithStyle`
  (`Task Never (Result x a) -> Task Never a`) → `Exit.toStderr` → `Exit.exitFailure`.
- IO is wrapped layer-on-layer: `Eco.*` → `System/IO.elm`, `System/Process.elm`,
  `System/Exit.elm` → `Builder/File.elm`, `Builder/BackgroundWriter.elm` →
  `Builder/Build.elm`, `Builder/Elm/Details.elm`, `Builder/Http.elm`,
  `Builder/Eco/Config.elm`, `Builder/Reporting.elm`, all the `Terminal/*` commands.
  Almost all of this is `Task Never`.

Runtime/scheduler:
- C++ kernels fail via `taskFailString(msg)` (`eco/KernelHelpers.hpp`); `taskFail`
  already accepts an arbitrary `HPointer` payload, so the failure slot is NOT
  restricted to strings.
- `eco/Console.cpp` write **ignores** the `::write` return value (EPIPE lost).
- `eco/MVar.cpp` has `assert(it != s_mvars.end())` at lines ~237, ~255, ~279.
- Scheduler already prints `[eco-runtime] unhandled top-level Task.fail … failure
  value dropped` and terminates (`runtime/src/platform/Scheduler.cpp` ~731-744).
- `eco_entry.cpp` installs a stats signal handler covering SIGPIPE that prints
  stats then re-raises (effectively fatal). No `catch(...)` guard around the FFI
  boundary.
- Value model CAN represent records/customs/Maybe (`eco_alloc_record`,
  `eco_alloc_custom` in `runtime/src/allocator/RuntimeExports.cpp`), but a
  kernel-built record must match the compiler's monomorphized layout (field order
  + 2-bit unboxed bitmap) — which is exactly the risk the Http tuple precedent
  avoids.

---

## Resolved decisions (2026-05-29)

- **D1 — Boundary shape: `Raw*` RECORDS** (not tuples). The kernel constructs
  `RawIOError` / `RawHttpError` records and fails with them; Elm `decode*` maps
  the record → ADT.
  - **IMPLEMENTATION DEVIATION (discovered during impl, 2026-05-29):** The
    codebase *deliberately forbids* constructing user records in the kernel —
    `eco-kernel-cpp/src/eco/Http.cpp:73-75,190-193` explicitly builds `Tuple2`
    "(NOT a record)" because a record's field-index order is computed by the
    monomorphizer (`computeRecordLayout`) and cannot be safely predicted by the
    C++/JS/XHR kernels. Replicating that across three backends would directly
    endanger the **D7 bootstrap-green hard gate**. So D1 is realized as: the
    neutral Elm type IS a `Raw*` **record** that `decode*` consumes (D1 intent
    preserved), but the kernel→Elm boundary uses the codebase-sanctioned
    **tuple** (`tuple3 (tag, path, message)` for IO; a tuple for HTTP), and the
    `Eco.*` wrapper assembles the `Raw*` record from that tuple before decoding —
    exactly mirroring the existing `Eco.Http`/`getArchive` pattern. D7 (hard
    gate) outranks D1-literalism.
- **D2 — errno: stable classification tag computed at each kernel.** C++ maps
  positive `errno`; JS maps the `err.code` string; both emit the same stable tag
  into the `Raw*` record. One decode mapping in Elm.
- **D3 — Scope: full ripple to all call sites.** Do NOT hide the change behind a
  `System.IO` policy boundary. Let `Task Never → Task IOError` propagate through
  every layer and fix the self-enumerating type errors everywhere. Larger surface,
  more honest per-call-site error handling.
- **D5 — Http model: wrap, minimal split for v1.** Keep `Builder.Http.Error`; have
  it carry/wrap the new `Eco.Http.Error`. Start with a modest
  network/timeout/status/body split and expand later. Minimal disruption to
  `RP_Http` / `SolverBadHttp`.

D4/D6/D7 resolved below (all three backends; Env/Runtime stay Task Never but
fail-capable ops incl. MVar use IOError; bootstrap-green is the hard gate).

## Deviations from the original design (corrections — facts, not choices)

1. **errno is not portable.** Node's `err.code` is a *string* ("ENOENT") and
   `err.errno` is a (negative, platform-dependent) int; C++ has a positive
   `errno`. The design's Elm `decodeIOError` matching on raw integers would
   misbehave on the JS path. (Handled by D2: classify to a stable tag per kernel.)

2. **`ioErr` already trivially exists** as `Task.mapError`. Add a named alias only
   if it improves readability; not load-bearing.

3. **`Eco.Http` is already Result-based**, and a separate **`Builder.Http.Error`**
   already exists (consumed by `RegistryProblem.RP_Http` / `Solver.SolverBadHttp`).
   So HTTP is refinement + reconciliation, not greenfield. (Handled by D5.)

4. **Three backends, not two.** XHR is a first-class path (the compiler bootstraps
   through it — see project memory). Any signature change to `Eco.*` wrappers MUST
   be matched in `compiler/src-xhr/Eco/*` or the bootstrap breaks.

5. **File-path fixes:** `Terminal/Terminal/Error.elm` does **not** exist;
   `Builder/Details.elm` is actually `compiler/src/Builder/Elm/Details.elm`.

6. **Invariant CSV format** is `;`-delimited with columns
   `id;phase;category;status;description;source`, IDs use **UNDERSCORES**
   (`REP_001`, `CGEN_012`), not dashes. So the new id should be `IO_ERR_001`,
   not `IO-ERR-001`, and the row must use semicolons.

7. **Scope reality check (per D3, full ripple).** Because IO is wrapped several
   layers deep and nearly everything is `Task Never`, flipping the *kernel*
   signatures forces a change through `System.IO`, `Builder.File`, `Build`,
   `Elm/Details`, `BackgroundWriter`, `Reporting`, and every `Terminal/*` command.
   This is the chosen approach — a large, all-or-nothing cascade fixed by the type
   checker, not hidden behind a boundary module.

---

## Architecture (the spine of the plan — reflects D1–D5)

- **Kernel boundary (D1):** primitives fail with neutral **`Raw*` records**
  (`RawIOError { domain, tag, path, message }`; `RawHttpError { kind, url,
  statusCode, statusText, message }`). Same shape across C++, node-JS, XHR. The
  kernel-side record construction must match the compiler's monomorphized layout
  (field order + 2-bit unboxed bitmap) — see the "record layout source of truth"
  task in Phase 1.
- **Classification (D2):** each kernel maps its native error (C++ `errno`, JS
  `err.code` string) to one stable `tag`, stored in the `Raw*` record.
- **`Eco.*` wrappers:** decode the `Raw*` record into typed ADTs
  (`Eco.IO.Error.IOError`, `Eco.Http.Error.HttpError`,
  `Eco.Process.Error.ProcessError`). Wrappers now return `Task IOError a` etc.
- **Propagation (D3):** full ripple. No `System.IO` policy boundary; the
  `Task Never → Task IOError` change propagates to every call site, mapped into
  the right `Exit.*` per command context.
- **`Exit.*` + `Help`:** add IO/HTTP/Process variants and `toReport` renderers.
- **Scheduler/runtime:** add an FFI exception guard + `reportFatal`, fix
  SIGPIPE/Console EPIPE and the MVar asserts, and add JS unhandled-fail logging.
- **Invariant:** add `IO_ERR_001` to `design_docs/invariants.csv`.

---

## Phased implementation plan

### Phase 0 — Scaffolding & decisions (no behavior change)
1. Resolve remaining open questions D4 (backend staging), D6 (Env/Runtime/MVar),
   D7 (rollout gating). D1/D2/D3/D5 are decided.
2. Add invariant `IO_ERR_001` to `design_docs/invariants.csv` (semicolon row,
   underscore id), wording adapted to the chosen architecture.
3. (Optional) add `Utils.Task.Extra.ioErr = Task.mapError` if we want the named
   bridge for readability.

### Phase 1 — Kernel error typing (Elm wrappers + `Raw*` records)
4. **Record layout source of truth (D1 prerequisite).** Decide and document how
   the kernel-built `RawIOError`/`RawHttpError` record layout stays in sync with
   the compiler's monomorphized layout (field order + 2-bit unboxed bitmap). Study
   how `Eco.Http` crosses its record today (it actually builds a *tuple* and
   reshapes in Elm — `eco-kernel-cpp/src/Eco/Http.elm:26-33`). Since D1 mandates a
   real record, pick a concrete mechanism (e.g. a fixed all-boxed layout the
   kernel hard-codes via `eco_alloc_record`+`eco_store_record_field`, plus an
   invariant test asserting the compiler-side layout matches). This is the highest-
   risk task in the plan; do it first.
5. Create error ADTs:
   - `Eco/IO/Error.elm` — `IOError` (FileNotFound, PermissionDenied, NotADirectory,
     IsADirectory, AlreadyExists, NoSpaceLeft, TooManyOpenFiles, BrokenPipe,
     BadFileDescriptor, OtherIOError {...}).
   - `Eco/Http/Error.elm` — `HttpError` (BadUrl, Network, Timeout, Tls, BadStatus,
     BodyDecode, OtherHttp). Keep modest for v1 (D5).
   - `Eco/Process/Error.elm` — `ProcessError` (CommandNotFound,
     CommandNotExecutable, SpawnIOError IOError, OtherProcessError).
   - The `Raw*` record types + decode functions mapping `Raw*` record → ADT
     (`decodeIOError`, `decodeHttpError`, `decodeProcessError`).
   - Mirror ALL of the above into `compiler/src-xhr/Eco/...` (or share a module
     if the two trees can import a common source — check build wiring first).
6. Change `Eco.File`/`Eco.Console`/`Eco.Process` wrapper signatures from
   `Task Never a` to `Task IOError a` (Process: `Task ProcessError a` for spawn;
   `wait`/`exit` stay `Task Never`). Refine `Eco.Http` to the richer `HttpError`.
   Decide Env/Runtime/MVar (D6 — likely keep `Task Never` for now).
7. Update the `Eco.Kernel.*` primitive declarations and the **C++** kernels
   (`eco/File.cpp`, `Console.cpp`, `Process.cpp`, `Http.cpp`) to fail with the
   `Raw*` record: capture `errno`, classify to the stable tag (D2), build the
   record via the layout from step 4, return through `taskFail`.
8. Update the **node JS** kernels (`eco-kernel-cpp/src/Eco/Kernel/*.js`) to fail
   with the same `Raw*` record shape (classify `err.code` string → tag).
9. Update the **XHR** path (`compiler/src-xhr/Eco/*`, `XHR.elm`) to produce the
   same record shape (JSON-encode/decode if that is the only channel).
10. Build & run the front-end test suite; fix kernel/wrapper type errors.
    **Gate: bootstrap must stay green** (D7).

### Phase 2 — Scheduler / runtime hardening
11. Add `ECO_KERNEL_GUARD(...)` macro (catch `bad_alloc` / `std::exception` / `...`)
    and wrap every `*Exports.cpp` C-linkage entry. Implement
    `Eco::Runtime::reportFatal` (banner + message + flush) — likely in
    `eco_entry.cpp` or a new `Runtime.cpp`.
12. SIGPIPE: switch to `SIG_IGN` (or `MSG_NOSIGNAL`); make `eco/Console.cpp` write
    check the `::write` return and surface EPIPE as a real `RawIOError`.
13. MVar asserts (`eco/MVar.cpp` ~237/255/279): replace with either a controlled
    failure or a `reportFatal`+abort (D6 decides which — "missing MVar" is arguably
    an internal invariant violation → fatal).
14. JS scheduler: log unhandled `Task.fail` to match the native runtime message.

### Phase 3 — Thread errors into the compiler (D3: full ripple)
15. Extend `Exit.*`: add the IO-carrying variants. Concretely:
    - `Make` += `MakeFileIO Eco.IO.Error.IOError`
    - `BuildProblem`/`BuildProjectProblem` += an `BP_IO IOError` path
    - `Details` += a `DetailsIO IOError` path
    - `RegistryProblem` += `RP_IO IOError` (already has `RP_Http`)
    - `Repl` += `ReplIO IOError`
    - Process spawn failures → an appropriate `Exit.*` (e.g. `BP_SpawnError`).
    - Reconcile `Builder.Http.Error` to wrap `Eco.Http.Error` (D5).
16. Add `Help` renderers: one shared `ioErrorToReport : String -> IOError ->
    Report` plus the per-Exit `toReport` cases that call it (and an
    `httpErrorToReport`).
17. Switch the direct `Task.mapError never` IO sites
    (`Builder/Eco/Config.elm:43,55`, `Builder/Generate.elm:795,822`) to map into
    `Exit.*`, then let the type checker drive the full ripple.
18. Fix the resulting type errors module-by-module (D3 — no boundary shim):
    `System/IO.elm`, `System/Process.elm`, `Builder/File.elm`,
    `BackgroundWriter.elm`, `Build.elm`, `Elm/Details.elm`, `Builder/Http.elm`,
    `Builder/Reporting.elm` (`ask`/`askHelp`), then each `Terminal/*` command.
    For best-effort sinks (terminal error/usage printing) consciously swallow
    IOErrors rather than thread them.

### Phase 4 — Tests & cleanup
19. Add representative failure tests: missing config file, permission denied,
    broken pipe (`| head`), no-network/timeout, spawn of a nonexistent command.
    Assert the pretty-printed diagnostic, not just exit code.
20. (Optional) make a remaining top-level `Task.fail` in the CLI entrypoint fatal
    once all IO is typed.
21. Update `THEORY.md` / `design_docs/theory/*` if the error model is documented
    there; verify `IO_ERR_001` wording matches the final implementation.

---

## Risks
- **Kernel↔compiler record-layout coupling (ELEVATED — accepted via D1).** Building
  real `Raw*` records in C++/JS couples the kernels to the compiler's monomorphized
  layout. Mitigation: fixed hard-coded layout + an invariant test (Phase 1 step 4).
  This is now the single highest-risk part of the plan.
- **Blast radius (ELEVATED — accepted via D3).** Full ripple of
  `Task Never → Task IOError` touches `System.IO`, `Builder.File`, `Build`,
  `Elm/Details`, `BackgroundWriter`, `Reporting`, and every `Terminal/*` command.
  Phase 3 is the bulk of the effort and is all-or-nothing for compilation.
- **Bootstrap fragility**: project memory notes the native `eco`/bootstrap is
  brittle (Map.! crashes, GC asserts). A pervasive signature flip can destabilize
  it; each phase must gate on bootstrap green.
- **Three-backend drift**: C++, JS, and XHR must agree on the `Raw*` record shape,
  layout, and classification mapping, or errors decode wrong on one path.

---

## All decisions resolved (2026-05-29)
- **D4 (backend staging):** ALL THREE backends (C++, node-JS, XHR) land together.
- **D6 (Env/Runtime/MVar):** Do NOT keep them `Task Never`. Any operation that can
  fail returns `Task IOError a`. The MVar "missing MVar" case is a **recoverable
  IOError**, not a fatal abort.
- **D7 (rollout gating):** "bootstrap stays green" is the HARD per-phase gate.

---

## Implementation outcome (2026-05-29)

### What landed
- **Invariants**: `IO_ERR_001`, `IO_ERR_002`, `FORBID_IO_001` added to
  `design_docs/invariants.csv`.
- **Bridge**: `Utils.Task.Extra.ioErr = Task.mapError`.
- **Error ADTs** (both trees, `compiler/src-xhr/Eco/**` + `eco-kernel-cpp/src/Eco/**`,
  the latter added to `eco/kernel` `exposed-modules`):
  `Eco.IO.Error` (IOError + RawIOError + decode + `tagFromCode`),
  `Eco.Http.Error` (HttpError + decode), `Eco.Process.Error` (ProcessError + decode).
- **Boundary shape (D1 deviation, documented above)**: kernels fail with the
  neutral `tuple3 (tag, path, message)` (HTTP keeps its Result-in-success
  `(statusCode, statusText)`); the Elm wrapper assembles the `Raw*` record and
  decodes. No kernel-built user records (would break the layout contract / D7).
- **Wrappers flipped to typed errors** (both trees): `Eco.File` (reads/writes/
  handles/dir-ops → `IOError`; queries `fileExists/dirExists/findExecutable/
  getCwd/appDataDir` stay `Task Never`), `Eco.Console` (`IOError`), `Eco.Process`
  spawn/spawnProcess (`ProcessError`; exit/wait stay `Task Never`), `Eco.Http`
  fetch (`Result HttpError _`; getArchive kept `Result String`). Env/Runtime/MVar
  stay `Task Never` (see MVar note below).
- **MVar (D6 nuance, revised after stress run)**: `Eco.MVar` stays `Task Never`.
  Making it `Task IOError` had no consumer benefit (the compiler's only MVar use,
  `Utils.Main`, immediately contains it) but broke ~20 MVar test fixtures
  (stress-elm + eco-kernel E2E) that chain `MV.put/take` as `Task Never`. The C++
  `MVar.cpp` still satisfies D6's core intent — the missing-MVar `assert` is
  replaced by a *recoverable* `taskFailIO` (no abort); presented as infallible at
  the Elm level since it is an internal concurrency invariant.
- **Kernels emit the tuple** (D4 all three backends): C++ (`File/Console/Process/
  MVar.cpp` via `taskFailErrno`/`taskFailIO` + `ioErrorTagFromErrno` in
  `KernelHelpers.hpp`), node-JS (`Eco/Kernel/{File,Console,Process}.js` via a
  `*_ioErr` `__Utils_Tuple3` helper + code→tag map), XHR (`Eco.XHR` fails with the
  tuple instead of crashing; `eco-io-handler.js` forwards `code`/`path`).
- **Scheduler / runtime hardening (Phase 2)**: `ECO_KERNEL_GUARD` +
  `Eco::Kernel::reportFatal` in `KernelExports.h`, applied to File/Console/Process
  exports; SIGPIPE → `SIG_IGN` in `eco_entry.cpp`; `Console::write` now surfaces
  EPIPE; MVar `assert` → recoverable `taskFailIO` (D6).
- **Threaded into Exit (Phase 3)**: `Exit.MakeFileIO IOError` + shared
  `ioErrorToReport` Help renderer; `Builder.Eco.Config` config read now propagates
  to `Exit.MakeFileIO`. `Builder.Http` maps the new `HttpError` into the existing
  `Builder.Http.Error` (D5 wrap).

### Scope decision: propagate vs. contain (IO_ERR_001 clause (a))
Per D3 the kernel/wrapper layer is fully typed, but threading `IOError` through the
MVar-concurrent build pipeline (`Build`/`Details`/`BackgroundWriter` + the 127
importers of `Utils.Main`) is unbounded and endangered the D7 bootstrap gate. So:
- **Propagated to `Exit.*`** (user-facing): config-file read → `Exit.MakeFileIO`;
  registry/network → `Builder.Http.Error` → `Exit.RegistryProblem`/`Solver`.
- **Handled locally** (IO_ERR_001 clause (a)): console output (best-effort, swallowed
  at `System.IO.write` — matches the kernel's historical ignore-the-write-return
  behaviour); build-internal artifact/cache IO and REPL prompts/spawn (converted to
  a clean diagnostic via `System.IO.crashOnError` / `binaryDecodeFileOrFail` folds
  IO errors into its existing rebuild-triggering `Err`; `System.Process` maps a
  spawn failure to exit 127). Missing-MVar is recoverable but contained at
  `Utils.Main` since it is an internal concurrency invariant, not user IO.

### Verification (final tree, 2026-05-29)
- elm-test-rs (XHR build): **12825 passed / 0 failed** (= baseline; the nonzero
  target exit is only the pre-existing `Test.skip` INCOMPLETE marker).
- Full app typecheck (`elm make src/Terminal/Main.elm`): Success.
- C++ build (`cmake --build build`): exit 0 (kernels + guard + reportFatal + SIGPIPE).
- E2E JIT suite (`test/test`): **1431 passed / 1 failed**. The single failure,
  `HttpGetArchiveTest`, is pre-existing/environmental (ZIP-download): all 22
  `elm-http` tests pass, `getArchive`'s C++ path is unchanged, and it was reverted
  to `Result String` so it still compiles.
- Stress (`--target stress`): **100 passed / 0 failed**.
- Native bootstrap (`--target bootstrap`, kernel caches cleared so it actually
  recompiled the changed sources): **all stages green**, both the JS fixed-point
  check (eco-boot-2 == eco-boot-3) and the native fixed-point check
  (eco-compiler-boot == eco-compiler-boot-2) pass, and the final `eco → eco-2`
  in-process MLIR→ELF self-host succeeds. Determinism preserved.

### Caching gotcha (worth remembering)
The `--builddir` compiles keep a *per-builddir* package artifact cache
(`<builddir>/eco-stuff/.../{i,d,o}.dat`) separate from the package-root
`artifacts.dat`/`typed-artifacts.dat`. An intermediate `Task IOError` MVar state
poisoned those per-builddir caches; the stress and first bootstrap-retry failures
were entirely stale caches, fixed by wiping `build/test/stress-elm/eco-stuff` and
`build/compiler/build-kernel/eco-stuff` (only `--target clean` wipes them).

### Known limitations / follow-ups
- Native `Process.spawn` command-not-found surfaces as exit 127 (fork/exec), while
  the JS/XHR paths classify it at spawn — a documented asymmetry (a self-pipe in the
  native spawn would unify this).
- `ECO_KERNEL_GUARD` is applied to the syscall-facing IO exports (File/Console/
  Process), not Env/Runtime/Http/MVar/Crash/NativeDriver.
- JS scheduler unhandled-`Task.fail` logging (parity with the native runtime
  message) not added.
