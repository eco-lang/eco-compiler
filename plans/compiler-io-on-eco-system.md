---
status: not-started
updated: 2026-11-25
---

# Plan: the compiler's IO on eco/system, and the IO functions removed from eco/kernel

## 1. Goal and scope

The compiler (`compiler/src`) does all of its IO through `eco/kernel` (`eco-kernel-cpp/`), the
compiler-internal IO package. `eco/system` (`system-kernel-cpp/`) is the public, more polished
system API and now covers the same ground. This plan moves the compiler's **file, console,
environment, process-exit and HTTP** IO onto eco/system, and then deletes the eco/kernel modules and
functions that are left unused.

In scope, in order:

1. **Files**: `Eco.File` → `FileSystem`, `FileSystem.Handle`, `Path`.
2. **Console, environment, exit**: `Eco.Console`, `Eco.Env`, `Eco.Process.exit`,
   `Eco.Runtime.dirname` → `System`, `Stream`, `Terminal`.
3. **HTTP**: `Eco.Http.fetch` / `getArchive` → `Http.Stream` (on elm/http).
4. **The Stage 1 (stock Elm, XHR) twin** of all of the above (§5).
5. **Removing** the eco/kernel IO surface the migration frees (§7).

Out of scope (a later pass):

- **Hashing.** `Eco.Hash` (`string`, `stringWithSeed`, `string64`) stays as it is. Moving the
  in-memory `Data.HashMap` hashing onto `Hash` / `HashedDict` is the next plan. `Builder/File`'s
  on-disk fingerprints need a stable hash and must stay off `Hash.hash` in any case.
- **Compiler-only facilities with no eco/system counterpart**: `Eco.MVar`, `Eco.GC`,
  `Eco.NativeDriver`, `Eco.Crash`. These stay in eco/kernel.
- The compiler's knowledge of eco/kernel *as a package it compiles*
  (`Compiler/Monomorphize/Solver/KernelSetFacts.elm`, `Compiler/IR/Kernel/Visibility.elm`,
  `Compiler.IR.Kernel.Facts`). These tables are updated only to drop entries for kernel functions
  deleted in §7 (KERNEL_FACTS_001).

## 2. Where things stand

### 2.1 Build chain

| Stage | Built by | IO layer the compiler links against |
|---|---|---|
| 1 | stock `elm make` in `build/compiler/build-xhr` (no `--optimize`) | `compiler/src-xhr/Eco/*.elm`: same names and signatures as eco/kernel, each op sent over XHR to `compiler/bin/eco-io-handler.js` (mock-xmlhttprequest, in-process) |
| 2–5 | `guida.js` / `eco-boot-*.js` (Node), in `build/compiler/build-kernel` | eco/kernel's JS kernels (`eco-kernel-cpp/src/Eco/Kernel/*.js`) via `--local-package eco/kernel=…` |
| 6+ | native | eco/kernel's C++ (`eco-kernel-cpp/src/eco-kernel/`, `ECO_KERNEL_MODS` in `runtime/src/codegen/CMakeLists.txt`) |

eco/system already has JS twins for every module (Phase 10, D15 of `plans/eco-system-library.md`),
so stages 2–5 need no new JS work beyond the additions in §4. **Only Stage 1 needs a new
implementation** (§5).

### 2.2 What the compiler calls today

17 files import eco/kernel. Nearly every call goes through one of these wrapper modules, so the
migration is concentrated there:

- `Utils/Main.elm`: files, directories, locks, env, args, MVar, binary file read/write, dirname.
- `System/IO.elm`: the program shape (`Program`, `run`), stdout/stderr handles, `writeString`,
  `readLine`, `isTerminal`.
- `System/Exit.elm`, `System/Crash.elm`.
- `Builder/File.elm`: streamed writes (`open`/`hWriteString`/`close`), `readString`.
- `Builder/Http.elm`: `fetch`, `getArchive`.
- Direct callers: `Builder/Deps/Registry.elm` (`touch`, `modificationTime`),
  `Builder/Eco/Config.elm` (`readString`), `Compiler/GenerateMlir/Backend.elm` (`writeBytes`),
  `API/Main.elm` (`rawArgs`, `Console.write`, `Process.exit`), `Builder/Reporting/Exit.elm` (matches
  `IOError` constructors).

### 2.3 Function mapping

**Files** (`Eco.File` → eco/system):

| eco/kernel | eco/system | Work needed |
|---|---|---|
| `readString` | `FileSystem.readFile` + UTF-8 decode (elm/bytes) | small helper in `Utils/Main.elm` |
| `readBytes` | `FileSystem.readFile` | none |
| `writeString` | `FileSystem.writeFile` (encode) | none |
| `writeBytes` | `FileSystem.writeFile` | none |
| `writeBytesAtomic` | `writeFileWith { createNew = True, sync = True }` to `<path>.tmp-<n>`, then `FileSystem.move` | Elm helper. Today's C++ names the temp `<path>.tmp-<pid>-<seq>`, created `O_EXCL`, skipping names that exist. eco/system exposes no pid, so `<n>` starts at `env.startTime` millis and goes up on `FileExists`. The exclusive create keeps names unique across processes. |
| `open WriteMode` + `hWriteString` + `close` | `Handle.openForWrite EnsureEmpty` + `Handle.write` (+ `close`) | chunks become `Bytes` via `Bytes.Encode.string`; perf gate §8 |
| `open ReadMode` + `size` + `close` | `FileSystem.metadata` → `.byteSize` | simpler |
| `fileExists` / `dirExists` | `metadata { resolveLink = True }` → `.entityType`, any error ⇒ `False` | helper |
| `list` | `listDirectory` → map to file names | helper |
| `modificationTime` | `metadata` → `.lastModified` | none |
| `touch` | `changeTimes` (now, now) | needs `Time.now` |
| `createDir b` | `makeDirectory { recursive = b }` | none |
| `removeFile` | `remove { recursive = False }` | none |
| `removeDir` (recursive) | `remove { recursive = True }` | none |
| `getCwd` | `currentWorkingDirectory` | none |
| `canonicalize` | `realPath`; on `NotFound`, make the path absolute against the cwd and normalise it with `Path` | `canonicalize` works on paths that don't exist; `realPath` does not |
| `appDataDir name` | `homeDirectory` + `environmentVariables` + `Environment.platform` | the per-OS rules (§2.4) move into Elm |
| `lock` / `unlock` | **none**; see D3 | |
| `IOError` | `FileSystem.Error` (`errorKind`, `errorPath`, `errorToString`) | `Builder/Reporting/Exit.elm` switches to `ErrorKind`; IO_ERR_001 keeps holding |

The compiler passes paths as `String`. The wrappers convert at their boundary with
`Path.fromPosixString` / `Path.toPosixString`. The compiler's own path code (`fp*` in `Utils/Main.elm`)
stays as it is.

**Console, environment, exit:**

| eco/kernel | eco/system | Notes |
|---|---|---|
| `Console.write stdout/stderr` | `Stream.writeString` on `env.stdout` / `env.stderr` | needs access to `env` deep in the compiler: D1 |
| `Console.readLine` | `Stream.readLine env.stdin` | |
| `Console.isTerminal h` | `Terminal.isTerminal` | |
| `Env.rawArgs` | `List.drop 1 env.args` | rawArgs leaves out the program name (JS: `argv.slice(2)`). `env.args` starts with the program (native) or the script (JS), so drop 1 on every backend. |
| `Env.lookup` | `System.environmentVariables` → `Dict.get` | |
| `Runtime.dirname` | `env.applicationPath` → `Path.parent` | native: empty on platforms other than Linux and macOS, see P1.3. JS: the script's path, same as dirname's `module.filename`. |
| `Process.exit code` | D2 | |

**HTTP:**

| eco/kernel | eco/system | Notes |
|---|---|---|
| `Http.fetch method url headers` | `Http.Stream.task` + `streamResolver`, body read with `Stream.readUntilClosed` and decoded as UTF-8 | errors become elm/http's `Http.Error`; `Builder/Http.elm` maps them onto its `Exit` problems as it does today |
| `Http.getArchive url` | `Http.Stream.task` for the bytes, then unzip + SHA-1 in Elm (D4) | |

### 2.4 Behaviour that must not change

- `appDataDir`: `<home>/.<name>` (no XDG), or `<home>/Library/Application Support/<name>` on
  macOS, where `<home>` is `HOME`, or the user database's entry when `HOME` is unset or empty;
  on Windows `<name>` under `APPDATA`, then `USERPROFILE`, then `HOME`. It fails with
  `FileNotFound` when there is no home directory. Check whether `FileSystem.homeDirectory` already
  follows the same fallback order, and keep the existing eco-kernel tests'
  scenarios (`FileAppDataDir*Test.elm`) as eco-system E2E tests against the new helper.
- `canonicalize` of a missing path, and of `""` (fails).
- Exit codes and every message the compiler prints.
- IO_ERR_001: each IO call site still either handles its error or maps it into an `Exit.*`
  constructor.

## 3. Decisions

D1–D4 were decided by the user on 2026-11-25. Each took option (a), the recommended one. The
rejected options are kept below for the record.

**D1 (decided: a): How code deep in the compiler reaches stdout, stderr, stdin, args and the application path.**
eco/system gives these out only as `System.Environment`, the flags of `main`. In the compiler they
are needed deep inside the code: `IO.write` / `writeLn` / `print` / `printLn` in about 25 files,
`readLine` for prompts, `envGetArgs` in `Terminal/Terminal.elm`, and the application path when
looking up bundled packages in `Builder/Stuff.elm`.

- **(a) Chosen:** add `System.environment : Task x Environment` to eco/system. It gives back
  the same `Environment` as the flags. The kernel already builds it in one call
  (`environmentNow`), and the stdio stream pairs are made once per process and reused, so repeated
  calls are cheap and agree. This needs a new `Task`-returning kernel binding, in C++ and JS.
  `System/IO.elm` then gets the streams from it, and no call sites change.
  It also lets the compiler keep `IO.run` as a `Platform.worker` with `()` flags, which avoids
  the Stage 1 flags problem (§5.4).
- (b) Rejected: thread an `Environment` (or an `IO.Context`) through every IO path. This is the
  pure way, but it touches every module that prints, plus Builder and Terminal plumbing. Large
  diff, no gain.

**D2 (decided: a): Exiting from inside a Task.** `System.Exit.exit : ExitCode -> Task Never a` is called from deep
inside task chains. eco/system's `exitWithCode` is a `Cmd`, and `setExitCode` doesn't stop the
program.

- **(a) Chosen:** add a Task form to eco/system, `System.exitWithCodeTask : Int -> Task x a`. It uses the existing `kExitWithCode` kernel and
  never completes. Same semantics as `exitWithCode`: immediate, with no wait for work still in
  progress. That is safe for the compiler because every write it makes is awaited before it moves
  on. gren-node's `exitWithCode` is a Task too, so the addition follows the API direction.
- (b) Rejected: no API change, but `setExitCode` followed by a task that never completes and holds
  nothing (a read from an idle in-memory `Stream.Transformation.identity`). The program then ends
  at the empty event loop (LIVE_001). This relies on a subtle liveness rule, and `IO.run`'s worker
  must not re-arm anything.

**D3 (decided: a): File locks.** eco/system has no locking. The compiler locks `<cache>/lock` around package
cache work (`Utils.lockWithFileLock`, called from `Builder/Stuff.elm`), so that concurrent `eco`
processes don't corrupt it.

- **(a) Chosen:** keep `lock` / `unlock` in eco/kernel, moved from `Eco.File` into a small
  `Eco.FileLock` module. eco/kernel survives anyway (MVar, GC, NativeDriver, Crash, Hash).
- (b) Not now: add `FileSystem.Handle.lock` / `unlock` (flock / LockFileEx) to eco/system as public
  API, with C++, Win32 and JS twins and tests. Worth doing later only if user programs want it too;
  the compiler could then move over and `Eco.FileLock` could go.

**D4 (decided: a): `getArchive` (download a package zip, take its SHA-1, unpack it).** eco/system has neither a zip
reader nor a public SHA-1 (one exists only inside the C++ WebSocket handshake).

- **(a) Chosen:** pure Elm packages, for example `folkertdev/elm-flate` for inflate,
  `TSFoster/elm-sha1`, and a small zip central-directory reader in `Builder/Http.elm` (or
  `agu-z/elm-zip`, if its dependencies suit). The exact packages and versions are confirmed in P0
  against the registry (and against eco's native backend: none may use kernel code). Pure Elm runs unchanged on all three backends, including Stage 1, so this
  needs no shim, no eco-io op and no kernel code. Package archives are small, so pure-Elm inflate
  on native is fast enough; P6 measures it.
- (b) Rejected: `Stream.Transformation.inflateRaw` plus a new public `Hash.sha1` in eco/system.
  Faster, but it needs native, JS and Stage 1 implementations of both. Revisit only if P6's timing
  shows pure-Elm unpacking is too slow.

Decisions that follow from the above or from the code:

- **D5:** Stage 1 is served by a **generated stock-Elm copy of the eco/system sources** over an XHR
  *kernel* layer, not by hand-written look-alike modules (§5).
- **D6:** `Path` is pure Elm (no imports). Stage 1 uses the real file through the generated copy,
  unchanged.
- **D7:** eco/kernel modules the compiler never used (`Process.spawn` / `spawnProcess` / `wait`,
  `File.findExecutable` / `setCwd`, `Console.readAll` / `log`, `Runtime.random` / `saveState` /
  `loadState`) are removed along with the rest (§7). They are used only by eco/kernel's own tests.
  eco/system's `ChildProcess` covers spawning.

## 4. eco/system additions (Phase 1)

Following D1(a) and D2(a). D3(a) and D4(a) add nothing to eco/system.

- **P1.1 `System.environment : Task x Environment`.** New kernel `Eco.Kernel.System.environment`
  (C++ `SystemExports.cpp`, JS `System.js`) that returns the same tuple as `environmentNow`. The
  Elm side shares the record-building code with the flags decoder. Doc: the result equals the
  flags `Environment`, apart from `startTime` (kept from the first build). Tests in
  `test/eco-system`: equals the flags env; stdio streams are the same streams (a write through
  either interleaves in order); works in a `Platform.worker` program with `()` flags.
- **P1.2 `System.exitWithCodeTask : Int -> Task x a`.** Tests: exit code seen by
  the parent; output awaited before it is on stdout; embedded behaviour documented as for
  `exitWithCode`.
- **P1.3 `applicationPath` on Windows** (`GetModuleFileNameW`). The compiler finds its bundled
  packages from it (`Builder/Stuff.elm` `resolveBundledPackages`), and eco/kernel's `dirname` works
  there today. Also check FreeBSD if it is a supported host; if not, document it.
- **P1.4 Worker programs.** Check (and test) that a `Platform.worker` with `()` flags can use
  `FileSystem`, `Stream` on stdio, `Terminal` and `Http.Stream` natively and on JS, and that the
  native C++ managers don't assume a `System.program` / `simpleProgram` main. If this fails, the
  fallback is to switch `IO.run` to `System.simpleProgram` and take §5.4's alias route.
- Add each to `plans/eco-system-library.md` Appendix B (kernel table) and to the docs.

## 5. Stage 1: the XHR twin

### 5.1 Requirement

Stage 1 must compile the same `compiler/src` with stock Elm. The modules it imports
(`FileSystem`, `FileSystem.Handle`, `Path`, `Stream`, `System`, `Terminal`, `Http.Stream`) must
therefore exist under stock Elm with **the same names, types, constructors and behaviour** as
eco/system. Stock Elm rejects two things the real sources use: `import Eco.Kernel.*` and
`effect module` outside `@elm` (eco-system-library D12).

### 5.2 Approach: generate the public modules, hand-write only the kernel

The XHR twin is **generated from eco/system's own sources**, as `docs.json` already is
(`system-kernel-cpp/scripts/make-docs-package.js`, D13). That script already turns
`effect module` into `module`, drops kernel imports and replaces kernel references. The XHR
generator does the same, with one difference: a kernel reference `Eco.Kernel.<Home>.<fn>` is
rewritten to `Eco.XhrKernel.<Home>.<fn>` when the hand-written XHR kernel provides it, and to
`(Debug.todo "xhr kernel: <Home>.<fn>")` when it doesn't.

As a result:

- Every public signature, constructor, doc comment, error decoder (`FileSystem.Internal`,
  `Stream.decodeError`), metadata decoder and all of `Path` are **the eco/system code itself**.
  The API is identical by construction, with no signature-diffing gate to maintain.
- The hand-written part is only the **kernel boundary**. eco/system keeps it narrow on purpose:
  every module calls its kernel only through the `k*` wrappers at the end of the file, with neutral
  shapes (Int ids, tuples, `( code, message )` errors, `Bytes`). Those shapes are what
  `Eco.XhrKernel.*` and the eco-io handler implement.
- Kernel functions the compiler never reaches stay `Debug.todo`. Stage 1 isn't built with
  `--optimize`, so this compiles (cf. `plans/xhr-crash-debug-todo.md`).

### 5.3 Pieces

1. **Shared rewrite core.** Move the code/non-code splitter and the effect-module and kernel
   rewrites out of `make-docs-package.js` into `system-kernel-cpp/scripts/stock-elm-rewrite.js`.
   `make-docs-package.js` (docs mode: everything → `Debug.todo`) and the new
   `compiler/scripts/make-xhr-system.js` (xhr mode) both use it, so `docs.json` and Stage 1 can't
   drift apart.
2. **`make-xhr-system.js`** writes the generated modules to `build/compiler/build-xhr/src-system/`
   (build tree, never checked in). It reads the exposing lists of `compiler/src-xhr/Eco/XhrKernel/*.elm`
   to decide which references to wire and which to stub. Effect-manager bodies and `command` /
   `subscription` uses become `Debug.todo`, as in docs mode. The compiler uses no `Cmd` / `Sub` from
   eco/system once D2(a) is in place.
3. **`compiler/src-xhr/Eco/XhrKernel/<Home>.elm`**, one per kernel home the compiler reaches
   (`System`, `FileSystem`, `Stream`, `Terminal`, `HttpStream`). Each `fn` has exactly the type of the
   real module's `k<Fn>` wrapper and is built on `Eco.XHR`. Expected set, to be confirmed by the
   reachability check in item 6:
   - `System`: `environment` (P1.1), `getEnvironmentVariables`, `setExitCode`, `exitWithCode`.
   - `FileSystem`: `stat`, `readFile`, `writeFile`, `open` / `writeFromOffset` / `close` (for
     `Handle`), `fsync`, `rename`, `realpath`, `utimes`, `remove`, `listDirectory`, `makeDirectory`,
     `currentWorkingDirectory`, `homeDirectory`, and the `Handle` module's equivalents it reaches.
   - `Stream`: `readChunk`, `carryLine`, `carryAppend`, `write`, `closeWritable`, `cancel*`, and the
     stdio ids.
   - `Terminal`: `isTerminal`.
   - `HttpStream`: `send` (whole body, served back as a stream id).
   - Synchronous kernels (`stringToUtf8`, `utf8ToString`) are implemented in **pure Elm** (elm/bytes)
     in `Eco.XhrKernel`, since XHR can only be asynchronous.
   - Polymorphic kernels the compiler doesn't reach (e.g. `Stream.read : Int -> Task … a`) stay
     stubs, because XHR can't produce an arbitrary `a`.
4. **eco-io ops** in `compiler/bin/eco-io-handler.js`, named `<Home>.<fn>` (`FileSystem.readFile`,
   `Stream.readChunk`, …), each returning the kernel's value shape and failing with the same
   `( code, message )` tuple that `FileSystem.js` / `Stream.js` produce. The errno-name table is
   copied from `FileSystem.js`. The handler keeps a small stream table (stdio ids 0–5; HTTP bodies
   as in-memory readables; the line carry buffer). Implement these alongside the old ops; the old
   ones go in §7.
5. **Build wiring.** In `compiler/cmake/bootstrap/build-xhr/elm.json`, add `src-system` to
   `source-directories` and make sure eco/system's dependencies (`elm/http`, `elm/url`, `elm/time`;
   `elm/virtual-dom` only if a reachable module imports it, and `Html.Dom` is not reached) are
   listed. A CMake rule regenerates `src-system/` when `system-kernel-cpp/src/**/*.elm` or the
   generator changes, and it joins `ELM_SOURCES` for Stage 1. `elm-tests`, which runs against
   `build-xhr`, picks it up automatically.
6. **Reachability gate.** After Stage 1, check `guida.js` for the string `xhr kernel:`. Stock Elm
   drops unreferenced definitions, so if a stub survives, a kernel function the compiler can reach
   has no XHR implementation. The check fails the build and names it. This catches a later
   compiler change that starts using a new eco/system function.
7. **Kernel overrides.** `compiler/kernel-overrides/*.js` patch Stage 1 output by mangled name
   (`$author$project$…`). The generated modules are application modules under Stage 1, so their
   names mangle as `$author$project$FileSystem$…`. No override targets them today; note this in
   `plans/js-kernel-overrides.md`.

### 5.4 The program's flags type

Stock Elm rejects a `main` whose flags type isn't JSON-shaped, so `Platform.Program System.Environment …`
can't compile in Stage 1. With D1(a), `IO.run` stays a `Platform.worker` with `()` flags on every
backend, and the problem doesn't arise.

Only if P1.4 shows that native requires a `System` main: add `type alias SimpleProgram =
Platform.Program Environment () ()` to eco/system. The XHR generator rewrites its body to
`Platform.Program () () ()` and supplies `Environment` through `Eco.XhrKernel.System.environment`.
`IO.Program` then names `System.SimpleProgram`. This would be the generator's single
signature-level special case.

## 6. Phases

Each phase ends green on `cmake --build build --target full` (tests run once, output tee'd to
`/tmp/test_output.txt` per CLAUDE.md), plus `elm-tests` where Elm changed. eco/kernel stays in
place, untouched, until P7. So the compiler can migrate one area at a time with both packages as
dependencies.

- **P0 D4 packages.** D1–D4 are decided (§3). Choose the inflate, SHA-1 and zip packages and pin
  their versions. Check that each is pure Elm and compiles with both stock Elm (Stage 1) and eco
  (stages 2+). Add them to `compiler/elm.json` and to both bootstrap `elm.json` files.
- **P1 eco/system additions** (§4), with tests on native and JS (`run-js-e2e`).
- **P2 Stage 1 XHR layer** (§5): shared rewrite core; generator; `Eco.XhrKernel.*`; eco-io ops;
  build wiring; reachability gate. Done when Stage 1 compiles with `src-system/` present and a
  throwaway compiler test that calls `FileSystem.readFile`, `Stream.writeString env.stdout` and
  `System.environment` passes under `elm-tests`.
- **P3 Dependencies.** Add `eco/system` (and `elm/http` directly) to
  `compiler/cmake/bootstrap/build-kernel/elm.json` and `compiler/elm.json`. Add
  `--local-package eco/system=${CMAKE_SOURCE_DIR}/system-kernel-cpp` next to every
  `--local-package eco/kernel=…` in `compiler/CMakeLists.txt` (it is repeatable). Add the
  eco/system sources to the stage-2+ dependency globs and to the artifact-cache invalidation (as
  done for eco-kernel-cpp's `artifacts.dat`). Check the native link pulls in the `EcoSystem_*`
  libraries for the compiler (`ecoSystemLibs()`).
- **P4 Files.** Rewrite the file wrappers in `Utils/Main.elm` and `System/IO.elm`, plus
  `Builder/File.elm`, `Builder/Eco/Config.elm`, `Builder/Deps/Registry.elm` and
  `Compiler/GenerateMlir/Backend.elm`, onto `FileSystem` / `FileSystem.Handle` / `Path` per §2.3.
  Change `Builder/Reporting/Exit.elm` from `IOError` constructors to `FileSystem.Error` and
  `ErrorKind`, keeping the rendered messages. Keep `lock` / `unlock` on eco/kernel (D3). Port the
  behaviour tests named in §2.4 to the new helpers.
- **P5 Console, environment, exit.** `System/IO.elm`: `Handle` becomes the stream chosen from
  `System.environment`. `write` / `writeLn` / `print` / `printLn` go to `Stream.writeString`
  (still unable to fail; a broken pipe is swallowed as today); `readLine` → `Stream.readLine`;
  `isTerminal` → `Terminal.isTerminal`; `flush` becomes a no-op, documented (each write has
  completed when its task completes). `Utils/Main.elm`: args, env lookup, dirname per §2.3.
  `System/Exit.elm` and `API/Main.elm`: D2. Check stdout/stderr ordering on a terminal and in
  pipes, which the E2E compile-error tests already capture.
- **P6 HTTP.** `Builder/Http.elm`: `fetch` on `Http.Stream.task`; `getArchive` per D4. Run the
  package-install paths (`eco install`, registry `update`) against the real registry once, and
  time a large package's unpacking natively.
- **P7 Remove from eco/kernel** (§7).
- **P8 Close-out.** Update memory/docs (`guides/`, `docs/`, Readme mentions of eco/kernel IO),
  `plans/eco-system-library.md` (new API), and this plan's front matter.

## 7. Removal from eco/kernel (P7)

Remove completely, in Elm, the JS kernel, the C++ sources and exports, `ECO_KERNEL_MODS`, the
eco-io handler ops and the `compiler/src-xhr/Eco/` twins:

- `Eco.Console` (Console.cpp/hpp, ConsoleExports.cpp, Console.js)
- `Eco.Env` (Env.*, EnvExports.cpp, Env.js)
- `Eco.Process` and `Eco.Process.Error` (Process.*, ProcessExports.cpp, Process.js)
- `Eco.Runtime` (Runtime.*, RuntimeExports.cpp, Runtime.js)
- `Eco.Http` and `Eco.Http.Error` (Http.*, HttpExports.cpp, Http.js). This also drops the `adm-zip`
  Node dependency that `Http.js` requires (`compiler/CMakeLists.txt` ~l.428, package.json).
- `Eco.File`, except `lock` / `unlock`, which move to `Eco.FileLock` (D3a).

Keep: `Eco.Crash`, `Eco.GC`, `Eco.Hash`, `Eco.MVar`, `Eco.NativeDriver`, `Eco.FileLock`, and
`Eco.IO.Error`, which MVar and FileLock still fail with. Trim `Eco.IO.Error` to the constructors those
two can produce, or leave it whole; this is a judgement call when the code is in front of us.
`Eco.XHR` stays for the Stage 1 versions of what's kept.

Also in P7:

- Update `eco-kernel-cpp/elm.json` `exposed-modules` and its summary, and the bundle install rules.
- Update `KernelSetFacts.elm` and `Kernel/Visibility.elm` (and any C++ kernel-facts / ABI tables keyed by
  `Eco` homes). Grep for each removed `( "Eco", "<Home>", … )` key and each
  `Eco_Kernel_<Home>_` symbol.
- **Tests.** `test/eco-kernel/src` has 47 tests. Delete those for removed functions. Where one
  pins behaviour that the compiler still depends on through the new helpers (appDataDir,
  canonicalize of a deleted cwd or of `""`, atomic write, huge and `/proc` file reads, `/dev/full`
  write errors), port it to `test/eco-system` against eco/system or the compiler helper, so the
  regression cover isn't lost. `test/elm-http` and `test/stress-elm` import `Eco.Env`: move them to
  `System.environmentVariables`.
- `src-xhr`: delete `Eco/Console.elm`, `Env.elm`, `Process.elm`, `Process/Error.elm`,
  `Runtime.elm`, `Http.elm`, `Http/Error.elm`, `File.elm` (keep a `FileLock.elm` twin), and their ops in
  `eco-io-handler.js`.
- Grep the repo (`--include=*.{elm,js,cpp,hpp,h,md,cmake,txt}`, excluding `build/`, `worktrees/`,
  `elm-stuff/`) for every removed module and kernel name. Fix or delete each hit; leave `done`
  plans as history.

## 8. Verification and risks

- **Gates:** `full`; `elm-tests`; `run-js-e2e`; Stage 4b JS fixed point (compiler output must
  not change); Stage 7a timing against a pre-migration baseline, measured cold and warm as
  `eco-stage7a-cold-build` describes. Streamed MLIR writes now encode chunks to `Bytes` and go
  through `Handle.write`. If that costs measurably, write bigger chunks or use `writeFileStream` with
  `Stream.enqueue`.
- **Windows and macOS.** eco/system's Win32 file-system code was compile-only and untested when the
  package landed (`plans/eco-system-library.md`). The compiler on Windows (`win-build`) will now
  depend on it. Expect CI-found fixes there, and treat Windows CI as a P4/P5 gate, not as follow-up.
  The same applies to `applicationPath` (P1.3).
- **Stdout semantics.** Today `Console.write` goes straight to the fd. Stream writes go through
  eco/system's channel; ordering between stdout and stderr, and output before an immediate exit,
  must stay as it is (P5).
- **Stage 1 / native parity.** The generated twin shares all Elm above the kernel. Differences can
  only come from `Eco.XhrKernel` + eco-io, which are small and checked by the reachability gate
  and the existing `elm-tests` / bootstrap fixed-point checks.
- **No model checks involved.** None of this touches `runtime/src/allocator/`.
