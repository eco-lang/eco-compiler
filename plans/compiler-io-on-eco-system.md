---
status: done
updated: 2026-11-25
---

# Plan: the compiler's IO on eco/system, and the IO functions removed from eco/kernel

## 0. Review log (2026-11-25)

**Implemented 2026-11-25.** §10 records what the code does where it differs from the plan below
(Stage 1 links eco/system's real JS kernels instead of an XHR twin; file locks were dropped, not
moved) and the verification.

The first draft of this plan was reviewed adversarially against the code. Every claim below was
checked in the source; the corrections are folded into the sections that follow. Findings, most
severe first:

| # | Severity | Draft said | The code says | Fixed in |
|---|---|---|---|---|
| R1 | **Blocker** | Streamed MLIR writes: `Handle.openForWrite EnsureEmpty` + `Handle.write` | `FileSystem.Handle.write` writes **at offset 0** every time (`write h b = writeFromOffset h 0 b`). Each chunk would overwrite the previous one. Sequential writes need `writeFromOffset h -1` (the current position). | §6.4 |
| R2 | **Blocker** | Windows: eco/system's Win32 file system code is "compile-only and untested" | Every native Win32 FileSystem op is a stub that fails with `ENOTSUP` (`FileSystemOpsWin32.cpp`), and Windows stdio streams are stubs too (`plans/eco-system-library.md`: "Windows stdio streams fail with ENOTSUP"). CI ships a Windows bundle (`win-aot.yml`, `win-release`). Moved over as is, the native Windows compiler could not read a file or print anything. | D6 (decided: a), P1.5 |
| R3 | **Blocker** | D4(a): pure-Elm SHA-1 / inflate "runs unchanged on all three backends" | eco native `Bitwise` is **64-bit** (CGEN_085, "a known divergence"), while elm/core and every published package assume JS 32-bit wrap-around. SHA-1 depends on 32-bit modular adds and rotates, so a stock package can give a different hash natively. The native compiler would then reject every download with `PP_BadArchiveHash`. | D4, P0, §6.6 |
| R4 | **Blocker** | Stage 1: "polymorphic kernels the compiler doesn't reach stay stubs" | The compiler reaches them. `Stream.writeString` calls `kWrite : a -> Int -> …` and `readUntilClosed` calls `kRead : Int -> Task … a`. `Http.Stream.kSend` takes `List Http.Header`, an opaque elm/http type. Stock Elm can't write an XHR twin of any of these. | D9, §5.4 |
| R5 | High | `Http.fetch` → `Http.Stream.task`, body decoded as UTF-8 | The compiler sends `Accept-Encoding: gzip`, and the old kernels gunzip (and inflate `deflate`). eco/system's HTTP passes the body on still encoded ("No `CURLOPT_ACCEPT_ENCODING`"). Every gzipped registry reply would then fail to decode. | §6.6 |
| R6 | High | `touch` → `changeTimes (now, now)` | Every old `touch` **creates a missing file** (`open(path,'a')`); `changeTimes` fails with `NoSuchFileOrDirectory`. | §6.3 |
| R7 | High | `removeDir` → `remove { recursive = True }` | The old `removeDir` is `rm -rf` (`force: true`): a missing path is not a failure. `remove` fails on it. | §6.3 |
| R8 | High | `readLine` → `Stream.readLine env.stdin` | At end of input the old `readLine` returns `""`; `Stream.readLine` fails with `Closed`, and `Builder/Reporting.elm` would crash on it (`IO.readLine \|> IO.crashOnError`). | §6.2 |
| R9 | High | Paths: convert with `Path.fromPosixString` / `toPosixString`, nothing else | Parsing is lexical and lossy. `""` parses to `Path.empty`, which prints as `"."`, so `canonicalize ""` would succeed (it must fail) and `fileExists ""` would test the cwd. `"a."` loses its dot, and `x/../y` collapses as text. Paths that come back on Windows hold backslashes, which the old kernels normalised to `/` (`_File_normalize`) and the `fp*` helpers rely on. | §6.1 |
| R10 | High | P1.1 `System.environment` equals the flags env "apart from startTime (kept from the first build)" | `environmentNow` reads the clock on **every** call and caches nothing but the stdio ids. The new kernel's `startTime` is therefore the time the task ran. | P1.1 |
| R11 | High | `Builder/Reporting/Exit.elm` switches to `FileSystem.Error` / `ErrorKind` | Exit messages render the old `IOError` constructors. A direct switch changes every IO report and crash text. The plan instead keeps the compiler's IO error type (moved into the compiler) and maps `FileSystem.Error` onto it, so the reports stay byte-identical. | D8, §6.1 |
| R12 | Medium | D2 needs a new kernel binding | Not needed. `kExitWithCode : Int -> Task Never ()` already exists, so the Task form is one line of Elm. Its type is `Int -> Task x ()`, as gren-node's is, not `Task x a`: the kernel *succeeds* when the program is embedded. | P1.2 |
| R13 | Medium | `Runtime.dirname` = `Path.parent env.applicationPath`, "same as dirname's module.filename" | JS `applicationPath` is `realpathSync(module.filename)`, while the old dirname did not resolve links. Stage 1's old dirname was `compiler/bin` (the eco-io handler's `__dirname`). On Windows the path comes back with backslashes, and a native empty path must still fail as before (`ENOENT`). | §6.2 |
| R14 | Medium | P3: add `eco/system` to `compiler/elm.json` | `compiler/elm.json` is read by stock tooling, which can't resolve an unpublished package (it doesn't list eco/kernel either: it uses `src-xhr`). It needs the generated source dir instead (§5.6). | §5.6 |
| R15 | Medium | `test/stress-elm` imports `Eco.Env` | It imports only `Eco.MVar` / `Eco.IO.Error`, which stay. `projects/eco-test` and `projects/eco-init` *do* import removed modules, and the draft missed them. | P7 |
| R16 | Medium | P7 kernel tables: `KernelSetFacts.elm`, `Visibility.elm` | Also `Compiler/Monomorphize/Solver/kernel-license-files.csv` and `kernel-license-audit.csv` (LSS_022 manifest, `test/scripts/check-kernel-license-manifest.sh`), and the invariant text of IO_ERR_001 / IO_ERR_002 / FORBID_IO_001, which names the removed modules. `Visibility.elm`'s `Process` and `Http` rows also cover elm/core and elm/http kernels, which must stay. | P7 |
| R17 | Low | Gates: `full` | `full` is Gate A only. The stage 4b/7a checks the plan relies on run under `--target bootstrap`. | §8 |
| R18 | Low | P5: "`flush` becomes a no-op" | It already is one. | — |
| R19 | Low | "47 tests" in `test/eco-kernel/src` | 46 tests plus `TestServerConfig.elm`. | P7 |
| R20 | Low | Stage 1 `exit` | The eco-io `Process.exit` op turns code 0 into 1 after a handler failure (`handlerFailed`). The new op must keep that. | §5.5 |

The draft was right on the build chain, the 17 importing files, the wrapper layout, D1/D3, the
shared-rewrite-core idea, the reachability gate, and the eco/system JS twins.

## 1. Goal and scope

The compiler (`compiler/src`) does all of its IO through `eco/kernel` (`eco-kernel-cpp/`), the
compiler-internal IO package. `eco/system` (`system-kernel-cpp/`) is the public system API and covers
the same ground. This plan moves the compiler's **file, console, environment, process-exit and
HTTP** IO onto eco/system. It then deletes the eco/kernel modules and functions that are left unused.

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
  `Eco.NativeDriver`, `Eco.Crash`. They stay in eco/kernel, and so does `Eco.IO.Error`, which MVar
  fails with.
- The compiler's knowledge of eco/kernel *as a package it compiles*
  (`Compiler/Monomorphize/Solver/KernelSetFacts.elm`, `Compiler/IR/Kernel/Visibility.elm`,
  `Compiler.IR.Kernel.Facts`). These tables only lose the entries for kernels deleted in §7
  (KERNEL_FACTS_001), and gain `System.environment` (P1.1).
- The native Windows file-system and stdio ops beyond the compiler-reached subset of P1.5 (D6).

## 2. Where things stand

### 2.1 Build chain

| Stage | Built by | IO layer the compiler runs on |
|---|---|---|
| 1 | stock `elm make` in `build/compiler/build-xhr` (no `--optimize`), then `scripts/apply-overrides.js` | `compiler/src-xhr/Eco/*.elm`: same names and signatures as eco/kernel; each op goes over XHR to `compiler/bin/eco-io-handler.js` (mock-xmlhttprequest, **in-process**) |
| 2–5 | `guida.js` / `eco-boot-*.js` (Node), in `build/compiler/build-kernel` | eco/kernel's JS kernels (`eco-kernel-cpp/src/Eco/Kernel/*.js`) via `--local-package eco/kernel=…` |
| 6+ | native | eco/kernel's C++ (`eco-kernel-cpp/src/eco-kernel/`, `ECO_KERNEL_MODS` in `runtime/src/codegen/CMakeLists.txt:925`) |

eco/system already has JS kernels for every module (`system-kernel-cpp/src/Eco/Kernel/*.js`, D15 of
`plans/eco-system-library.md`), so stages 2–5 need no JS work beyond P1. **Only Stage 1 needs a new
IO layer** (§5).

`scripts/build.sh api` also builds `API/Main.elm` with stock Elm in `BUILD_XHR_DIR`. It is a second
Stage-1-style build and needs `src-system` too (§5.6).

### 2.2 What the compiler calls today

17 files import eco/kernel. Nearly every IO call goes through a wrapper module:

- `Utils/Main.elm` (l.917–1352): files, directories, locks, env, args, MVar, binary file
  read/write, dirname.
- `System/IO.elm`: the program (`Program`, `run`), the `Handle` type and `stdout`/`stderr`, `write*`,
  `readLine`, `isTerminal`, `writeString`, `crashOnError`.
- `System/Exit.elm` (`Eco.Process.exit`), `System/Crash.elm` (`Eco.Crash`, stays).
- `Builder/File.elm`: `withStreamingWriter` (`open WriteMode` / `hWriteString` / `close`),
  `readUtf8` (`Eco.File.readString`).
- `Builder/Http.elm`: `fetch` (→ `get`/`post`), `getArchive`.
- Direct callers: `Builder/Deps/Registry.elm:236,261` (`touch`, `modificationTime`),
  `Builder/Eco/Config.elm:83` (`readString` → `Exit.MakeFileIO`),
  `Compiler/GenerateMlir/Backend.elm:427` (`writeBytes`), `API/Main.elm` (`rawArgs`,
  `Console.write`, `Process.exit`), `Builder/Reporting/Exit.elm` (matches `IOError` constructors in
  `ioErrorToReport`, l.2338).

`IO.Handle` is built only inside `System/IO.elm` (`Handle 1`, `Handle 2`). Other modules pass
`IO.stdout` / `IO.stderr` through (`Exit/Help.elm`, `Text/PrettyPrint/ANSI/Leijen.elm`,
`Utils.builderHPutBuilder`).

### 2.3 Function mapping

Each row is specified exactly in §6. "Path in" means the wrapper converts its `String` argument
with `OsPath.toPath` (§6.1); "path out" means it converts a returned path with `OsPath.fromPath`.

**Files** (`Eco.File` → eco/system):

| eco/kernel | eco/system | Behaviour to keep (old kernels) |
|---|---|---|
| `readString` | `FileSystem.readFile` + `Utf8.decode` (§6.1) | invalid UTF-8 is decoded with U+FFFD (JS `readFileSync 'utf8'`), not refused |
| `readBytes` | `FileSystem.readFile` | — |
| `writeString` | `FileSystem.writeFile` (UTF-8 encode) | — |
| `writeBytes` | `FileSystem.writeFile` | — |
| `writeBytesAtomic` | `writeFileWith { createNew = True, sync = True }` to a temp name, then `FileSystem.move` | temp `<path>.tmp-<n>` created `O_EXCL`; on any failure remove the temp and fail |
| `open WriteMode` + `hWriteString` + `close` | `Handle.openForWrite EnsureEmpty` + `Handle.writeFromOffset h -1` + `Handle.close` | **not** `Handle.write` (R1) |
| `open ReadMode` + `size` + `close` | `FileSystem.metadata { resolveLink = True }` → `.byteSize` | — |
| `fileExists` / `dirExists` | `metadata { resolveLink = True }` → `.entityType == File` / `Directory`; any error ⇒ `False` | `""` ⇒ `False` |
| `list` | `listDirectory` → `Path.toPosixString e.path` | names as the OS gives them except a trailing `.` (accepted, §8) |
| `modificationTime` | `metadata` → `.lastModified` | — |
| `touch` | `changeTimes { now, now, resolveLink = True }`; on `NoSuchFileOrDirectory`, `appendToFile emptyBytes` then `changeTimes` again | creates a missing file (R6) |
| `createDir b` | `makeDirectory { recursive = b }` | — |
| `removeFile` | `remove { recursive = False }` | — |
| `removeDir` | `remove { recursive = True }`; `NoSuchFileOrDirectory` ⇒ success | `rm -rf` (R7) |
| `getCwd` | `currentWorkingDirectory`; `Path.empty` ⇒ fail `FileNotFound ""` | a removed cwd fails (old test `FileGetCwdDeletedFailsTest`) |
| `canonicalize` | `""` ⇒ fail; `realPath`; on **any** failure, absolute against the cwd and normalised (§6.3) | matches `File.js` `_File_canonicalize` |
| `appDataDir name` | `homeDirectory` + `environmentVariables` + `env.platform` (§6.3) | per-OS rules of §2.4 |
| `lock` / `unlock` | **none**: D3 | |
| `IOError` | compiler-owned `System.IOError.IOError`, built from `FileSystem.Error` (D8) | messages unchanged |

**Console, environment, exit:**

| eco/kernel | eco/system | Notes |
|---|---|---|
| `Console.write stdout/stderr` | `Stream.logString content env.stdout/stderr` | can't fail, as today |
| `Console.readLine` | `Stream.readLine env.stdin`; `Closed` ⇒ `""` | R8 |
| `Console.isTerminal h` | `Terminal.isTerminal Terminal.Stdout/Stderr` | |
| `Env.rawArgs` | `List.drop 1 env.args` | JS `env.args` is `process.argv.slice(1)` (starts with the script); native is the C argv. Old rawArgs was `argv.slice(2)` / argv minus argv[0]. |
| `Env.lookup` | `System.environmentVariables` → `Dict.get` | |
| `Runtime.dirname` | `env.applicationPath` → text → parent dir (§6.2) | R13 |
| `Process.exit code` | `System.exitWithCodeTask code` (P1.2) | |

**HTTP:**

| eco/kernel | eco/system | Notes |
|---|---|---|
| `Http.fetch method url headers` | `Http.Stream.task` + `streamResolver`, body read to the end, then gunzip/inflate by `content-encoding`, then UTF-8 | R5. Errors map onto `Builder.Http.Error` as today. |
| `Http.getArchive url` | `Http.Stream.task` for the bytes, then SHA-1, zip directory and inflate in Elm (D4) | redirects are followed by eco/system (≤ 20), as the old kernel did |

### 2.4 Behaviour that must not change

- `appDataDir`. On Linux and other POSIX systems it is `<home>/.<name>` (no XDG). On macOS it is
  `<home>/Library/Application Support/<name>`. `<home>` is `HOME`, or the user database's entry
  when `HOME` is unset or empty. `FileSystem.homeDirectory` already has exactly this fallback (its
  doc: "`$HOME` when that is set and not empty, otherwise the home directory recorded for the
  user"). On Windows it is `<name>` under `APPDATA`, else under the home directory. It fails with
  `FileNotFound ""` and the message `cannot find a home directory: set HOME` when there is no home
  (and, on Windows, no `APPDATA`). The scenarios of `FileAppDataDir*Test.elm` are ported (P7).
- `canonicalize` of a missing path (made absolute and normalised), of `""` (fails), and with a
  removed cwd (fails).
- Exit codes. Every **message the compiler composes** stays byte-identical: report titles and texts,
  the `IOError` renderings, crash prefixes. Text the OS or the network library supplies (the
  message of an `OtherIOError`, the detail of an HTTP failure with status 0) may read differently.
  That change is accepted (§8).
- IO_ERR_001: each IO call site still either handles its error or maps it into an `Exit.*`
  constructor. Its text is amended in P7.

## 3. Decisions

The user decided D1–D4 on 2026-11-25. Each took option (a), the recommended one. The review only
corrects how they are implemented. The user decided D6 (Windows) on 2026-11-25 as well: option (a).

**D1 (decided: a): How code deep in the compiler reaches stdout, stderr, stdin, args and the
application path.** Add `System.environment : Task x Environment` to eco/system (P1.1).
`System/IO.elm` gets the streams from it, and no call sites change. `IO.run` stays a
`Platform.worker` with `()` flags on every backend, which avoids the Stage 1 flags problem (stock Elm
rejects a non-JSON flags type).
(Rejected (b): thread an `Environment` through every IO path. That touches every module that prints,
for no gain.)

**D2 (decided: a): Exiting from inside a Task.** Add `System.exitWithCodeTask : Int -> Task x ()`
(P1.2). It wraps the existing `kExitWithCode`, so it needs no new kernel. It never completes unless
the program is embedded in a host, where it succeeds once the scheduler has been asked to stop.
`System.Exit.exitWith` keeps its `Task.map (\_ -> crash …)`, so its type stays `Task Never a`.
(Rejected (b): `setExitCode` plus a never-completing idle task. It relies on LIVE_001, and `IO.run`
re-performs `Task.succeed ()` forever, so the program would never reach an empty event loop
anyway.)

**D3 (decided: a): File locks.** Keep `lock` / `unlock` in eco/kernel, moved from `Eco.File` into a
new module `Eco.FileLock`, which is a new kernel home `FileLock` (§7.2).
(Not now (b): `FileSystem.Handle.lock` / `unlock` as public eco/system API.)

**D4 (decided: a, amended for R3): `getArchive` in pure Elm.** Inflate, SHA-1 and the zip directory
are Elm code that runs unchanged on all three backends **provided it never relies on 32-bit
`Bitwise` wrap-around**.

- P0 picks `folkertdev/elm-flate` (already used natively by `projects/eco-test`'s PNG decoding) for
  raw inflate, gzip and zlib.
- SHA-1 is **vendored** into the compiler as `compiler/src/Codec/Sha1.elm`, ported from
  `TSFoster/elm-sha1` (BSD-3, keep its notice). Every add is reduced with
  `modBy 0x100000000`, every rotate is written as
  `modBy 0x100000000 (x * 2^n) + (x // 2^(32-n))` on values already in `[0, 2^32)`, and no
  `shiftRightZfBy 0` / `and 0xFFFFFFFF` idiom is left. The result is then the same with 32- and
  64-bit `Bitwise`.
- The zip central-directory reader is compiler code too, `compiler/src/Codec/Archive/ZipReader.elm`.
  It reads little-endian fields with `Bytes.Decode.unsignedInt16/32 LE` (no `Bitwise`).
- elm-flate is used as a package only if P0's native test vectors pass. Otherwise it is vendored
  and repaired the same way as SHA-1.

(Rejected (b): `Stream.Transformation.inflateRaw` plus a public `Hash.sha1`. Revisit only if P6's
timing shows the Elm path is too slow.)

**D5:** Stage 1 is served by a **generated stock-Elm copy of the eco/system sources** over a
hand-written `Eco.XhrKernel.*` layer (§5), not by hand-written look-alike modules.

**D6 (decided: a, 2026-11-25): native Windows.** eco/system's native FileSystem and
stdio streams are `ENOTSUP` stubs on Windows (R2). The options:

- **(a) Chosen:** P1.5 implements, natively on Windows, exactly the ops the compiler reaches:
  `stat`, `readFile`, `writeFile`, `appendFile`, `open`/`writeFromOffset`/`fsync`/`close`, `rename`,
  `realpath`, `utimes`, `remove`, `listDirectory`, `makeDirectory`, `currentWorkingDirectory`,
  `homeDirectory`, plus the stdio FdChannel and `applicationPath`. It uses Win32 calls via
  `runtime/src/platform/` helpers and leaves every other op `ENOTSUP`. Per the Windows-low-priority
  rule it may land compile-verified and CI-tested only, without blocking Linux phases.
- (b) Rejected: accept a broken native Windows compiler from P4 until a follow-up plan, and stop shipping the
  Windows bundle meanwhile.
- (c) Rejected: defer P4–P7 until eco/system Windows support exists in its own plan.

**D7:** eco/kernel functions the compiler never used (`Process.spawn` / `spawnProcess` / `wait`,
`File.findExecutable` / `setCwd`, `Console.readAll` / `log`, `Runtime.random` / `saveState` /
`loadState`) are removed with the rest (§7). Only eco/kernel's own tests and `projects/` use them.
eco/system's `ChildProcess` covers spawning.

**D8 (from R11): the compiler owns its IO error type.** `Eco.IO.Error.IOError`'s type and
`toString` are copied into a new compiler module `compiler/src/System/IOError.elm`, with two
converters:

- `fromFileSystem : String -> FileSystem.Error -> IOError`, which maps the error kind and uses the
  path *as the compiler gave it*;
- `fromKernel : Eco.IO.Error.IOError -> IOError`, for MVar and FileLock failures (same
  constructors, a 1:1 map).

`Builder/Reporting/Exit.elm` changes only its import line, so every report stays the same.
`Eco.IO.Error` stays whole in eco/kernel (MVar and FileLock fail with it).

**D9 (from R4): Stage 1 passes polymorphic and opaque kernel values by identity.** Stage 1's
eco-io handler runs in the same Node process as `guida.js` (mock-xmlhttprequest), so a JS value can
cross the boundary as itself, as the MVar stash already does. A single kernel-override value
`Eco.XhrKernel.Coerce.unsafeCoerce : a -> b` (Elm body `Debug.todo "xhr coerce"`, override
`function (x) { return x; }`, override group `xhr-coerce`) turns the `Bytes` that `kWrite` receives
as `a` back into `Bytes`, and a read `Bytes` into the `a` that `kRead` returns. `Http.Header`
values become `( String, String )` the same way (elm/http 2.0.0 builds a header with
`_Http_pair`, a record with fields `a` and `b`, which is what Elm's tuple code reads; a Stage 1
test pins this).

## 4. eco/system additions (P1)

Each addition gets: Elm code, the C++ export (`system-kernel-cpp/src/eco-system/<Mod>/`), the JS
kernel (`system-kernel-cpp/src/Eco/Kernel/<Mod>.js`), a row in the `System` (etc.) list of
`compiler/src/Compiler/IR/Kernel/Visibility.elm` (l.287) for each new export, a line in
`plans/eco-system-library.md` Appendix B, the docs (`docs.json` is regenerated by
`make-docs-package.js`), and E2E tests in `test/eco-system/src/` that run on native and
JS (`run-js-e2e`).

### P1.1 `System.environment : Task x Environment`

1. `SystemExports.cpp`: add
   `uint64_t Eco_Kernel_System_environment()`, which returns
   `makeBinding<systemEnvironmentBody>(alloc::unit())`. In `System.cpp`/`.hpp`, add
   `HPointer systemEnvironmentBody(HPointer)`, which succeeds with `systemEnvironmentNow()` inside
   `ECO_SYSTEM_BODY_GUARD(Never, …)` like the other bodies.
2. `System.js`: add `var _System_environment = __Scheduler_binding(function(callback) {
   callback(__Scheduler_succeed(_System_environmentNow(null))); });`.
3. `System.elm`:
   - split `toEnvironment` into `fromKernel : ( ( String, String, String ), ( List String, Int ), ( Int, Int, Int ) ) -> Environment` and `toEnvironment json = fromKernel (kEnvironmentNow json)`;
   - add `kEnvironment : Task Never ( ( String, String, String ), ( List String, Int ), ( Int, Int, Int ) )` = `Eco.Kernel.System.environment`;
   - add the exposed `environment = kEnvironment |> Task.map fromKernel |> Task.mapError never`
     under `# Environment information`.

   Doc: "the same as the flags `Environment`, except `startTime`, which is the time this task
   ran". It works in any program, including a `Platform.worker` whose flags are not an
   `Environment`. The stdio streams are the same streams as the flags' (`stdioIds` reuses them
   within a heap generation).
4. `Visibility.elm`: add `"environment"` to the `System` row.
5. Tests (`test/eco-system/src/`):
   - `SystemEnvironmentTaskTest.elm`: equal `platform`, `cpuArchitecture`, `applicationPath`,
     `args`; `startTime` ≥ the flags `startTime`;
   - `SystemEnvironmentStdioSharedTest.elm`: alternate writes through the flags' `stdout` and the
     task's `stdout`; the expected output is in order;
   - `SystemEnvironmentWorkerTest.elm`: `main : Program () () ()` via `Platform.worker`, prints
     `List.length env.args > 0` through `env.stdout`.

### P1.2 `System.exitWithCodeTask : Int -> Task x ()`

```elm
exitWithCodeTask : Int -> Task x ()
exitWithCodeTask code =
    kExitWithCode code
        |> Task.mapError never
```

Expose it under `# Exit`. Doc: as `exitWithCode`, but a Task. It does not complete unless the
program is embedded, in which case it succeeds once the stop has been requested. Tests:

- `SystemExitTaskCodeTest.elm`: exits 7, and the harness checks the code;
- `SystemExitTaskAfterWriteTest.elm`: `Stream.writeLine "done" env.stdout` then exit 3. Expect
  `done` on stdout and code 3, on native and JS (JS `process.stdout` to a pipe).

### P1.3 `applicationPath` on Windows

In `System.cpp` `applicationPath()`, add a `_WIN32` branch that returns
`eco::platform::currentExecutablePath()` (`runtime/src/platform/PlatformPaths.hpp`, already
`GetModuleFileNameW` → UTF-8). Update the `Environment` doc ("Linux, macOS and Windows"). FreeBSD is
not a supported host (`CMakePresets.json` has no preset for it), so leave the doc saying `Path.empty`
there.

### P1.4 Worker programs

Check, with the P1.1 worker test extended, that a `Platform.worker` with `()` flags can use
`FileSystem.readFile`, `Stream.writeString`/`readLine` on stdio, `Terminal.isTerminal`, and
`Http.Stream.task` against the test server (`TestServerConfig`), natively and on JS. If the native
C++ managers turn out to assume a `System.program` main, fix that in the managers. The compiler's
`main` has to stay a worker with `()` flags because of Stage 1.

### P1.5 Windows (D6 = a)

`system-kernel-cpp/src/eco-system/FileSystem/FileSystemOpsWin32.cpp`: implement the ops listed under
D6(a) with `CreateFileW` / `ReadFile` / `WriteFile` / `SetFilePointerEx` / `FlushFileBuffers` /
`MoveFileExW(MOVEFILE_REPLACE_EXISTING)` / `GetFinalPathNameByHandleW` / `SetFileTime` /
`DeleteFileW` / `RemoveDirectoryW` (+ recursive walk) / `FindFirstFileW` / `CreateDirectoryW` /
`GetCurrentDirectoryW` / `SHGetKnownFolderPath` or `%USERPROFILE%`. Map `GetLastError()` to the
errno names that `FileSystem.Internal.decodeError` expects (`ENOENT`, `EEXIST`, `EACCES`, `EISDIR`,
`ENOTDIR`, `ENOTEMPTY`, …). Implement the stdio FdChannel over `GetStdHandle`. Gate: `win-build`
compiles and Windows CI runs `test/eco-system`'s FileSystem and stdio tests. Per the
Windows-low-priority rule, a red Windows CI is recorded and does not block P4 on Linux.

## 5. Stage 1: the XHR twin

### 5.1 Requirement

Stage 1 must compile the same `compiler/src` with stock Elm. The eco/system modules it imports
(`FileSystem`, `FileSystem.Handle`, `Path`, `Stream`, `System`, `Terminal`, `Http.Stream`, and what
they import) must therefore exist under stock Elm with the same names, types, constructors and Elm
code. Stock Elm rejects two things the real sources use: `import Eco.Kernel.*`, and `effect
module` outside `@elm` (eco-system-library D12).

### 5.2 Approach: generate the modules, hand-write only the kernel boundary

`compiler/scripts/make-xhr-system.js` generates the modules from eco/system's sources, as
`system-kernel-cpp/scripts/make-docs-package.js` already does for `docs.json`. The rewrites:

- `effect module X where {…} exposing` → `module X exposing`;
- `import Eco.Kernel.*` lines are dropped, and `import Eco.XhrKernel.<Home>` is added for each home
  the module references;
- each code reference `Eco.Kernel.<Home>.<fn>` becomes `Eco.XhrKernel.<Home>.<fn>` if the XHR
  module exposes `<fn>`, otherwise `(Debug.todo "xhr kernel: <Home>.<fn>")`;
- in former effect modules, code uses of `command` / `subscription` become
  `(\_ -> Debug.todo "effect")`, as in docs mode.

So every public signature, constructor, doc comment, decoder, and all of `Path`, *is* eco/system's
code. Only the `k*` wrapper targets differ.

### 5.3 The shared rewrite core

Move `segments`, `rewriteCode` and `rewrite` out of `make-docs-package.js` into
`system-kernel-cpp/scripts/stock-elm-rewrite.js`, exporting
`rewrite(source, { kernelRef: (home, fn) => string, kernelImports: (homes) => string[] })`.
`make-docs-package.js` passes `kernelRef = () => '(Debug.todo "kernel")'` and no imports; its
output must stay byte-identical (check: regenerate `docs.json` and `git diff --exit-code
system-kernel-cpp/docs.json`).

### 5.4 Pieces

1. **Generator** `compiler/scripts/make-xhr-system.js <outDir>`:
   - Roots: `System`, `Stream`, `FileSystem`, `FileSystem.Handle`, `Path`, `Terminal`, `Http.Stream`.
     Follow `import` lines inside `system-kernel-cpp/src` to get the closure (it adds
     `Stream.Internal`, `FileSystem.Internal`, `Http.Method`, …). Emit only the closure, so `Html.Dom`
     (elm/virtual-dom) and the Socket modules are never generated.
   - Read the exposing lists of `compiler/src-xhr/Eco/XhrKernel/*.elm` to decide, per reference,
     wire or stub.
   - Write `<outDir>/<Module/Path>.elm` plus `<outDir>/GENERATED` (a short "do not edit; regenerate
     with …" note), deleting files that are no longer generated.
2. **`compiler/src-xhr/Eco/XhrKernel/<Home>.elm`**. Each exposed function has exactly the type of
   the real `k*` wrapper that calls it, and is built on `Eco.XHR`. The set, derived from §6's
   wrapper code (the reachability gate, item 5, is the check):

   | Home | Functions | Notes |
   |---|---|---|
   | `System` | `environment`, `getEnvironmentVariables`, `exitWithCode` | |
   | `FileSystem` | `stat`, `readFile`, `writeFile`, `appendFile`, `open`, `writeFromOffset`, `fsync`, `close`, `rename`, `realpath`, `utimes`, `remove`, `listDirectory`, `makeDirectory`, `currentWorkingDirectory`, `homeDirectory` | errors `( code, message )` |
   | `Stream` | `write`, `read`, `readChunk`, `carryLine`, `carryAppend`, `cancelReadable`, `stringToUtf8`, `utf8ToString` | `write`/`read` use `Coerce` (D9); the last two are pure Elm (`Bytes.Encode.string`, `Bytes.Decode.string (Bytes.width b)`) because XHR is asynchronous |
   | `Terminal` | `isTerminal` | |
   | `HttpStream` | `send` | headers via `Coerce` (D9); bytes body sent as raw bytes |
   | `Coerce` | `unsafeCoerce` | the override of D9; nothing else |

   `Eco.XHR` gains two helpers for the eco/system error shapes:
   `codeTask : String -> Encode.Value -> Decode.Decoder a -> Task ( String, String ) a` (fails with
   the reply's `( code, error )`), and `kindTask : … -> Task ( Int, String ) a` for Stream ops
   (fails with `( kind, reason )`). Bytes results use `bytesTask`-style variants.
3. **Kernel override** `compiler/kernel-overrides/XhrCoerce.js`: `kind value`,
   `value $author$project$Eco$XhrKernel$Coerce$unsafeCoerce`, `group xhr-coerce`, body
   `var $author$project$Eco$XhrKernel$Coerce$unsafeCoerce = function (x) { return x; };`.
   Regenerate `KernelOverride/Files.elm` (memory: `js-kernel-overrides`). Add a line to
   `plans/js-kernel-overrides.md` saying that the generated eco/system modules mangle as
   `$author$project$FileSystem$…` under Stage 1.
4. **eco-io ops** in `compiler/bin/eco-io-handler.js`, named `<Home>.<fn>`, next to the old ops
   (which go in P7). Each returns the kernel's value shape:
   - FileSystem ops fail with HTTP 500 and `{ "code": <errno name>, "error": <message> }`. Build the
     message with a copy of `_FileSystem_message` from `FileSystem.js` (keep a comment naming the
     source).
   - `Stream.*`: the handler keeps a stream table. Ids 0/1/2 are stdin/stdout/stderr, and HTTP
     bodies get ids from 1000 up, each an in-memory list of Buffers plus a closed flag. There is
     also a per-id carry buffer for `carryLine`/`carryAppend` (port the logic from `Stream.js`).
     `write` to 1/2 is `process.stdout/stderr.write(Buffer)`, answered when its callback fires.
     `readChunk` on 0 reads from `process.stdin`; at end it fails with kind 0 (`Closed`).
   - `System.environment` returns platform, arch, **`path.join(__dirname, "index.js")`** as the
     application path (so its parent is `compiler/bin`, as the old `Runtime.dirname` was),
     `process.argv.slice(1)`, `Date.now()`, and ids `(0, 1, 2)`.
   - `System.exitWithCode` keeps the old rule:
     `process.exit(handlerFailed && code === 0 ? 1 : code)`.
   - `HttpStream.send` performs the request with Node `http`/`https`, follows ≤ 20 redirects, and
     never decodes `content-encoding`. It answers the kernel tuple
     `( kind, badUrl, ( ( status, statusText, url ), headers, streamId ) )` with the whole body
     registered as a stream.
5. **Reachability gate.** After `apply-overrides.js`, a CMake step runs
   `node compiler/scripts/check-xhr-stubs.js ${COMPILER_OUTPUT}`. It fails, naming each one, if
   `guida.js` contains `xhr kernel:`. Stock Elm drops unreferenced definitions, so a surviving stub
   is a reachable kernel with no XHR version.
6. **`kernelRef` wiring test.** `compiler/tests/Eco/XhrKernelTest.elm` (elm-tests, Stage 1) calls
   `Http.Stream`'s header path through `Coerce` on `[ Http.header "a" "b" ]` and expects
   `[ ( "a", "b" ) ]`. This pins D9's assumption about `_Http_pair`.

### 5.5 Build wiring

- `compiler/cmake/bootstrap/build-xhr/elm.json`: add `"src-system"` to `source-directories`. All
  imported packages (`elm/http`, `elm/url`, `elm/time`, `elm/bytes`, `elm/json`) are already
  direct dependencies, and elm/virtual-dom is not needed (Html.Dom isn't generated). CMake copies
  this file at configure time (`compiler/CMakeLists.txt:130`), so re-run `cmake --preset build`
  after editing it.
- `compiler/CMakeLists.txt`: an `add_custom_command` with output `${BUILD_XHR_DIR}/src-system/GENERATED`
  that runs the generator. It depends on `system-kernel-cpp/src/**/*.elm` (GLOB_RECURSE
  CONFIGURE_DEPENDS), on the generator and `stock-elm-rewrite.js`, and on
  `compiler/src-xhr/Eco/XhrKernel/*.elm`. Add that output to the Stage 1 command's DEPENDS. Add the
  gate of §5.4 item 5 as a second `COMMAND` after `apply-overrides.js`.
- `elm-tests` runs against `build-xhr` and gets `src-system` automatically.
- `scripts/build.sh` uses `BUILD_XHR_DIR` and works once the build tree has `src-system`. Note this in
  its header comment.

### 5.6 `compiler/elm.json` (plain compiles, editor tooling)

Don't add `eco/system` as a dependency (R14). Add `"src-system"` to its `source-directories`, and
have CMake create `compiler/src-system` as a link to `${BUILD_XHR_DIR}/src-system`
(`eco_create_dir_link`). Add `compiler/src-system` to `.gitignore` and to the elm-review ignore list
(`compiler/review/`), so the generated code is never linted or committed. Plain compiles then need a
configured build tree, which the `version/` link already assumes.

## 6. The compiler migration (P4–P6), wrapper by wrapper

### 6.1 New compiler modules

**`compiler/src/System/IOError.elm`** (D8): a copy of `eco-kernel-cpp/src/Eco/IO/Error.elm`'s
`IOError` type, `toString` and `pathSuffix`, without the kernel decoding, plus:

```elm
fromFileSystem : String -> FileSystem.Error -> IOError
fromFileSystem path err =
    case FileSystem.errorKind err of
        FileSystem.NoSuchFileOrDirectory -> FileNotFound path
        FileSystem.PermissionDenied -> PermissionDenied path
        FileSystem.NotPermitted -> PermissionDenied path
        FileSystem.NotADirectory -> NotADirectory path
        FileSystem.DirectoryFound -> IsADirectory path
        FileSystem.DirectoryRemoveNotRecursive -> IsADirectory path
        FileSystem.FileExists -> AlreadyExists path
        FileSystem.NoSpace -> NoSpaceLeft (nonEmpty path)
        FileSystem.TooManyOpenFiles -> TooManyOpenFiles
        FileSystem.HandleClosed -> BadFileDescriptor
        _ -> OtherIOError { tag = 0, path = nonEmpty path, message = FileSystem.errorToString err }

fromStream : Stream.Error -> IOError   -- Closed/Cancelled/Locked/Failed -> OtherIOError with Stream.errorToString
fromKernel : Eco.IO.Error.IOError -> IOError   -- constructor for constructor
```

This mirrors the old JS code table (`ENOENT 1, EACCES/EPERM 2, ENOTDIR 3, EISDIR 4, EEXIST 5,
ENOSPC 6, EMFILE/ENFILE 7, EPIPE 8, EBADF 9`). Unit test: `compiler/tests/System/IOErrorTest.elm`, one
case per `ErrorKind`. (Build `FileSystem.Error` values through `FileSystem.Internal.Error`, which the
generated Stage 1 copy exposes to the test.)

**`compiler/src/System/OsPath.elm`**: the only place that converts between the compiler's `String`
paths and `Path`:

```elm
toPath : FilePath -> Path          -- Path.fromPosixString
fromPath : System.Platform -> Path -> FilePath
    -- Path.toPosixString, then on Win32 String.replace "\\" "/"
```

Rules every wrapper in §6.3 follows. A wrapper whose path argument is `""` fails with
`FileNotFound ""` **before** converting, or answers `False` for the two existence queries, because
`Path.fromPosixString ""` is the cwd (R9). Errors carry the original `String`, not the parsed path.

**`compiler/src/Utils/Utf8.elm`**: `encode : String -> Bytes` and
`decode : Bytes -> String`. `decode` tries
`Bytes.Decode.decode (Bytes.Decode.string (Bytes.width b)) b` first (natively that keeps the zero-copy
UTF-8 view for ASCII, as the old `readString` did, HEAP_032). On `Nothing` it falls back to a lossy
Elm decoder that replaces each maximal invalid subsequence with U+FFFD, as Node's
`Buffer.toString('utf8')` does. Unit test `compiler/tests/Utils/Utf8Test.elm`: valid ASCII, valid
multi-byte, truncated sequence, stray continuation, overlong form, surrogate code point, each
against Node's output (record expected strings from `node -e`, per the expose-bugs-as-tests rule).

### 6.2 `System/IO.elm`

- Add `environment : Task Never System.Environment` = `System.environment`.
- `type Handle = Stdout | Stderr` (replacing `Handle Int`; nothing outside this module builds one,
  §2.2). `stdout = Stdout`, `stderr = Stderr`.
- `write h s = environment |> Task.andThen (\env -> Stream.logString s (streamOf h env))`, with
  `streamOf Stdout env = env.stdout` and so on. It can't fail, as now.
- `readLine : Task IOError String`:
  `environment |> andThen (\env -> Stream.readLine env.stdin) |> Task.onError (\e -> if e == Stream.Closed then Task.succeed "" else Task.fail (IOErr.fromStream e))`
  (R8).
- `isTerminal Stdout = Terminal.isTerminal Terminal.Stdout`, and the same for `Stderr`.
- `writeString path content = FileSystem.writeFile (Utf8.encode content) (OsPath.toPath path)`,
  mapped to `()`, with errors through `IOErr.fromFileSystem path`. `""` fails first (§6.1).
- `crashOnError` keeps its text (`"IO error: " ++ IOErr.toString err`) with the compiler's `IOError`.
- `flush` is unchanged (already a no-op).
- `run` is unchanged.
- Update the module doc (handles are no longer numbers).

### 6.3 `Utils/Main.elm` and the direct callers

Each wrapper keeps its name, type and docstring contract. Paths in/out follow §6.1.

| Wrapper | New body (in words) |
|---|---|
| `lockFile` / `unlockFile` | `Eco.FileLock.lock/unlock path \|> Task.mapError IOErr.fromKernel \|> IO.crashOnError` |
| `dirDoesFileExist p` | `""` ⇒ `False`; `metadata {resolveLink=True}` ⇒ `entityType == File`; error ⇒ `False` |
| `dirDoesDirectoryExist p` | the same with `Directory` |
| `dirCreateDirectoryIfMissing b p` | unchanged `""` guard; `makeDirectory {recursive=b}`; crash on error |
| `dirGetCurrentDirectory` | `currentWorkingDirectory`; `== Path.empty` ⇒ crash with `IOErr.FileNotFound ""`; else `fromPath platform` |
| `dirGetAppUserDataDirectory name` | `Win32`: `APPDATA` (non-empty) from `environmentVariables`, else home; others: home from `homeDirectory`. Home `== Path.empty` ⇒ crash with `OtherIOError { tag = 1, path = Nothing, message = "cannot find a home directory: set HOME" }` (the old message; tag 1 = file-not-found class). Join with `fpCombine`: `Darwin` → `home/Library/Application Support/name`, others `home/.name`, Windows `base/name`. |
| `dirGetModificationTime p` | `metadata` → `.lastModified`; crash on error |
| `dirRemoveFile p` | `remove {recursive=False}`; crash on error |
| `dirRemoveDirectoryRecursive p` | `remove {recursive=True}`; `NoSuchFileOrDirectory` ⇒ succeed; other errors crash (R7) |
| `dirGetFileSize p` | `metadata {resolveLink=True}` → `.byteSize`; crash on error |
| `dirCanonicalizePath p` | `""` ⇒ crash (FileNotFound ""); `realPath` ⇒ `fromPath`; on any error: cwd (crash if `Path.empty`), then `if fpIsRelative p then fpCombine cwd p else p`, normalised via `toPath >> fromPath` |
| `dirListDirectory p` | `listDirectory` → `List.map (.path >> Path.toPosixString)`; crash on error |
| `envLookupEnv n` | `System.environmentVariables \|> Task.map (Dict.get n)` |
| `envGetArgs` | `IO.environment \|> Task.map (.args >> List.drop 1)` |
| `nodeGetDirname` | `IO.environment`; text = `fromPath env.platform env.applicationPath`; `""` or `"."` ⇒ crash with `FileNotFound ""` and message `cannot determine the executable's directory`; else `fpTakeDirectory text` |
| `binaryDecodeFileOrFail` | `readFile`; error ⇒ `Err (0, IOErr.toString (fromFileSystem p e))` |
| `binaryEncodeFile` | `writeBytesAtomic` helper below; crash on error |
| `builderHPutBuilder` | unchanged (`IO.write`) |
| MVar wrappers | add `Task.mapError IOErr.fromKernel` before `IO.crashOnError` |

The **`writeBytesAtomic`** helper (private, `Utils/Main.elm`):

```
attempt n:
  tmp = path ++ ".tmp-" ++ String.fromInt n
  writeFileWith { createNew = True, sync = True } bytes (toPath tmp)
    FileExists       -> attempt (n + 1)            (at most 100 tries, then fail)
    other error      -> fail
    ok               -> move (toPath path) (toPath tmp)
                          error -> remove {recursive=False} tmp (ignore its error), fail
start: n = Time.posixToMillis env.startTime * 1000 + (millis now modBy 1000)
```

The exclusive create keeps names unique across processes, as `O_EXCL` did with the pid.

Direct callers:

- `Builder/File.elm`:
  - `readUtf8 p` = `FileSystem.readFile` → `Utf8.decode`, crash on error.
  - `withStreamingWriter p cb` = `Handle.openForWrite EnsureEmpty (toPath p)`, then `cb` with
    `\chunk -> Handle.writeFromOffset h -1 (Utf8.encode chunk)` (**−1, R1**), then `Handle.close h`.
    Crash on any error.
- `Builder/Deps/Registry.elm:236`: `touch registryPath` → `Utils.touch` (new, exposed), with the
  create-if-missing semantics of §2.3 (R6). `:261` → `Utils.dirGetModificationTime`.
- `Builder/Eco/Config.elm:83`: `readUtf8`-style read, with errors as
  `Exit.MakeFileIO (IOErr.fromFileSystem path e)`.
- `Compiler/GenerateMlir/Backend.elm:427`: `FileSystem.writeFile bytes (toPath target)`, crash on
  error.
- `Builder/Reporting/Exit.elm`: `import Eco.IO.Error as IOErr exposing (IOError)` →
  `import System.IOError as IOErr exposing (IOError)`. Nothing else changes.

### 6.4 `System/Exit.elm` and `API/Main.elm`

- `exitWith c = System.exitWithCodeTask (codeOf c) |> Task.map (\_ -> crash "exitWith: process should have exited")`,
  with `codeOf ExitSuccess = 0` and `codeOf (ExitFailure n) = n`. Update the module doc.
- `API/Main.elm`: `Eco.Env.rawArgs` → `Utils.envGetArgs`; `Eco.Console.write Eco.Console.stdout s`
  → `IO.write IO.stdout s`; `Eco.Process.exit Eco.Process.ExitSuccess` → `Exit.exitWith Exit.ExitSuccess`.

### 6.5 Output ordering

Today `Console.write` writes to the fd directly. `Stream.write` "succeeds once the value has been
… written to [the resource]" (Stream docs), and every `IO.write` is awaited before the next. So the
order across stdout and stderr, and output before an exit, stay as they are. The checks:
`test/elm-compile-errors` (stderr text), plus P1.2's exit-after-write test on JS pipes.

### 6.6 `Builder/Http.elm`

**`fetch method url headers onError onSuccess`**:

1. `Http.Stream.task { method = methodOf method, headers = List.map (\(n, v) -> Http.header n v) (addDefaultHeaders headers), url, body = Http.Stream.emptyBody, resolver = Http.Stream.streamResolver Ok, timeout = Nothing }`.
   `methodOf "GET" = Http.Method.GET`, `"POST" = POST`. Keep the default headers, including
   `Accept-Encoding: gzip`: requests stay the same, and step 3 decodes.
2. On the response:
   - `GoodStatus_ meta body`: read all chunks with
     `Stream.readUntilClosed (\c acc -> Ok (c :: acc)) []` and join them with
     `Bytes.Encode.encode (Bytes.Encode.sequence (List.map Bytes.Encode.bytes (List.reverse acc)))`.
     A read failure is `BadHttp url 0 (Stream.errorToString e)`.
   - `BadStatus_ meta body`: `Stream.cancelReadable "unused" body` (ignore its error), then
     `BadHttp url meta.statusCode meta.statusText`.
   - `BadUrl_ u`: `BadHttp url 0 ("bad URL: " ++ u)`. `Timeout_`: `BadHttp url 0 "timeout"`.
     `NetworkError_`: `BadHttp url 0 "network error"`. (The old detail was Node's or curl's message;
     see §8.)
3. Decode by `Dict.get "content-encoding" meta.headers`: `gzip` → `Flate.inflateGZip`, `deflate` →
   `Flate.inflateZlib` (Node's `zlib.inflate` is zlib-wrapped), anything else as is.
   `Nothing` from Flate is `BadHttp url 0 "unable to decompress the response"`.
4. `Utf8.decode`, then `onSuccess`.

**`getArchive url defaultError onSuccess`**:

1. `Http.Stream.task` GET with **no** headers (as before), then read the body as in fetch step 2.
   Any failure or non-2xx ⇒ `Err defaultError`.
2. `sha = Codec.Sha1.toHex (Codec.Sha1.fromBytes bytes)` (40 lowercase hex digits, as Node's
   `digest('hex')`).
3. `Codec.Archive.ZipReader.entries bytes : Maybe (List { name : String, method : Int, data : Bytes })`.
   Find the end-of-central-directory record by scanning back from the end for `0x06054b50`. Walk
   the central directory **in its order** (adm-zip's `getEntries` order). For each entry, read
   name, method, compressed size and local-header offset, then skip the local header (30 bytes +
   its own name and extra lengths). Method 0 = stored, method 8 = `Flate.inflate`; anything else,
   or Zip64 markers (`0xFFFFFFFF` sizes), ⇒ `Nothing`. Directory entries (names ending in `/`) are
   kept, with empty data.
4. `Nothing` anywhere ⇒ `Err defaultError`. Otherwise
   `onSuccess ( sha, List.map (\e -> Zip.Entry e.name (Utf8.decode e.data)) entries )`.

Unit tests (elm-tests, JS semantics):

- `compiler/tests/Codec/Sha1Test.elm`: FIPS 180 vectors (`""`, `"abc"`, the 448-bit message, one
  million `a`), and lengths 55/56/63/64/65 bytes.
- `compiler/tests/Codec/Archive/ZipReaderTest.elm`: fixtures made by `zip -X` (stored and deflated),
  inlined as hex.
- Native correctness is P0's job (R3).

## 7. Removal from eco/kernel (P7)

### 7.1 Remove

Remove completely, from Elm, the JS kernel, the C++ sources and exports, `ECO_KERNEL_MODS`
(`runtime/src/codegen/CMakeLists.txt:925` and the bundle loop at :1542), the eco-io ops, and the
`compiler/src-xhr/Eco/` twins:

- `Eco.Console` (Console.cpp/hpp, ConsoleExports.cpp, Console.js)
- `Eco.Env` (Env.*, EnvExports.cpp, Env.js)
- `Eco.Process` and `Eco.Process.Error` (Process.*, ProcessExports.cpp, Process.js)
- `Eco.Runtime` (Runtime.*, RuntimeExports.cpp, Runtime.js)
- `Eco.Http` and `Eco.Http.Error` (Http.*, HttpExports.cpp, Http.js). This also drops `adm-zip`:
  `compiler/package.json` + `pnpm-lock.yaml`, the `require("adm-zip")` in `eco-io-handler.js`, and
  the build-kernel `node_modules` link with its comment (`compiler/CMakeLists.txt:338–375`). Keep the
  link if anything else in `build-kernel` still `require`s from `node_modules`, so grep first.
- `Eco.File`, after `lock`/`unlock` move (7.2).

### 7.2 Add `Eco.FileLock` (D3)

- `eco-kernel-cpp/src/Eco/FileLock.elm` exposes `lock, unlock : String -> Task IOError ()`.
- Move the lock code out of `File.cpp`/`FileExports.cpp` into `FileLock.cpp`/`.hpp`/`FileLockExports.cpp`,
  exporting `Eco_Kernel_FileLock_lock`/`unlock`, and from `File.js` into `FileLock.js`.
- Add `FileLock` to `ECO_KERNEL_MODS`. `File` goes.
- `compiler/src-xhr/Eco/FileLock.elm` (twin) and eco-io ops `FileLock.lock`/`FileLock.unlock` (renamed
  from `File.lock`/`File.unlock`).
- KernelSetFacts / Visibility / license CSV rows: rename the keys `("Eco","File","lock"|"unlock")` to
  `("Eco","FileLock",…)`.

### 7.3 Keep

`Eco.Crash`, `Eco.GC`, `Eco.Hash`, `Eco.MVar`, `Eco.NativeDriver`, `Eco.FileLock`, `Eco.IO.Error`
(whole: MVar and FileLock fail with it), and `Eco.XHR` (Stage 1 for what's kept, and the base of
`Eco.XhrKernel`).

### 7.4 Tables, invariants, tests, references

1. `eco-kernel-cpp/elm.json`: `exposed-modules` and the summary. Bundle install rules: grep
   `share/eco/kernel` in the CMake files.
2. `KernelSetFacts.elm`, `Visibility.elm`, `kernel-license-files.csv`, `kernel-license-audit.csv`:
   delete each `( "Eco", "<Home>", … )` key of the removed homes. In `Visibility.elm`'s per-home rows,
   remove only the eco/kernel names: the `Process` row keeps elm/core's names (check against
   `elm-kernel-cpp/src/core/ProcessExports.cpp`), and the `Http` row keeps elm/http's `bytesToBlob`,
   `toDataView` and `toFormData`. Re-run `test/scripts/check-kernel-license-manifest.sh` (with
   `--update` only after reviewing the diff) and `scripts/check-kernel-opaque.py`.
3. `design_docs/invariants.csv`: amend IO_ERR_001 to name the compiler's wrappers over eco/system
   (`System.IOError.fromFileSystem`) and `Eco.FileLock`/`Eco.MVar` as the remaining eco/kernel
   leaves. Amend IO_ERR_002 and FORBID_IO_001 to drop `Eco.Process`/`Eco.Http` error payloads. Do
   not renumber the rows.
4. **Tests.** `test/eco-kernel/src` (46 tests + `TestServerConfig.elm`):
   - delete those for removed functions;
   - port to `test/eco-system/src/` the ones that pin behaviour the compiler still relies on,
     rewritten against eco/system: `FileReadHugeFileTest`, `FileReadProcFileTest`,
     `FileWriteDevFullTest`, `FileReadDirectoryTest`, `FileWriteBytesAtomicTest` (as a
     `writeFileWith`+`move` test);
   - the compiler-helper behaviours (`FileAppDataDir*`, `FileCanonicalize*`,
     `FileGetCwdDeletedFailsTest`, `FileTouchErrorClassTest`) can't be E2E tests of eco/system, since
     the helpers live in `compiler/src`. They become `compiler/tests/Utils/MainTest.elm` cases over the
     *pure* parts (the appDataDir path rules split out as
     `appDataDirFor : System.Platform -> Dict String String -> String -> String -> Result IOError String`,
     and the canonicalize fallback as a pure function of cwd and path);
   - `test/elm-http/src/TestServerConfig.elm`: `Eco.Env` → `System.environmentVariables`, and add
     `eco/system` to `test/elm-http/elm.json`.
   - `test/stress-elm` keeps eco/kernel (MVar only), so leave it.
5. `projects/eco-test/src/Hello.elm` and `projects/eco-init/src/Main.elm` import removed modules.
   Port them to eco/system (`System.simpleProgram`, `Stream`, `FileSystem`), or delete them if
   nothing references them. Grep for `projects/eco-test` first: `plans/fix-fallback-tag-int-case-allocation.md`
   and `plans/string-bytes-testing-gap.md` cite it as a repro.
6. Grep the repo (`--include=*.{elm,js,cpp,hpp,h,md,cmake,txt,csv,json,py,sh}`, excluding `build*/`,
   `worktrees/`, `elm-stuff/`, `snapshots/`, `chat_logs/`) for each removed module name
   (`Eco.Console`, …) and kernel symbol (`Eco_Kernel_Console_`, `_Console_`, `"Console.`, …). Fix
   or delete each hit, but leave `done` plans as history.

## 8. Phases

Each phase ends with targeted tests (the full-gate memory rule: the `full` + `bootstrap` gate runs
at the end of P4, P6 and P7, and the user is reminded before a commit when it is owed). Tests run
once, with output tee'd to `/tmp/test_output.txt` (CLAUDE.md). eco/kernel stays in place, untouched,
until P7, so the compiler can migrate one area at a time with both packages as dependencies.

- **P0 D4 packages and native vectors.**
  1. Add `folkertdev/elm-flate` (pin the newest 2.x; `projects/eco-test` uses 2.0.6) and its
     dependencies to `compiler/cmake/bootstrap/build-xhr/elm.json`,
     `compiler/cmake/bootstrap/build-kernel/elm.json` and `compiler/elm.json`. Check it compiles
     with stock Elm and with eco.
  2. Write `compiler/src/Codec/Sha1.elm` (§3 D4) and its elm-tests.
  3. Native check: `test/eco-system/src/ArchiveCodecsNativeTest.elm` (add elm-flate to
     `test/eco-system/elm.json`, and list a link to `compiler/src/Codec/` as a second source dir, or
     copy `Sha1.elm` into the test with a header naming its origin). Use the SHA-1 vectors above, an
     inflate of a `zlib.deflateRawSync` fixture, `inflateGZip` of a `gzip` fixture, and a CRC32
     check. It must pass natively and on JS. If an elm-flate case fails natively, vendor elm-flate
     into `compiler/src/Codec/Flate/` and fix its 32-bit assumptions the same way.
  Done when the test is green on both backends.
- **P1 eco/system additions** (§4: P1.1–P1.5; P1.5 is gated by Windows CI only and never blocks the Linux phases). Done when the new eco-system tests
  pass natively and under `run-js-e2e`.
- **P2 Stage 1 XHR layer** (§5). Done when:
  - Stage 1 compiles with `src-system` present;
  - the stub gate is green;
  - `docs.json` is byte-identical;
  - a throwaway compiler module, made reachable for one run from `Terminal/Main.elm`, calls
    `FileSystem.readFile`, `Stream.writeString env.stdout`, `System.environment` and `Http.Stream.task`
    under Stage 1, and its output is right;
  - `compiler/tests/Eco/XhrKernelTest.elm` passes under `elm-tests`.
  Remove the throwaway afterwards.
- **P3 Dependencies (stages 2+).**
  - `compiler/cmake/bootstrap/build-kernel/elm.json`: add `"eco/system": "1.0.0"` and `"elm/http": "2.0.0"`
    to direct, and `"elm/virtual-dom": "1.0.5"` to indirect (eco/system depends on it).
  - `compiler/CMakeLists.txt`: add `--local-package eco/system=${ECO_SYSTEM_DIR}` after every
    `--local-package eco/kernel=…` (l.423, 451, 481, 558, 620, 663, 1144; grep, don't trust the
    numbers). Add `system-kernel-cpp/src/**/*.elm` and `src/Eco/Kernel/*.js` to `KERNEL_SOURCES`
    (l.379), and `system-kernel-cpp/artifacts.dat` / `typed-artifacts.dat` to
    `ADDITIONAL_CLEAN_FILES` (l.392).
  - Native link: check that `EcoNativeDriver.cpp:663/796/1117` links `ecoSystemLibs()` for the compiler
    build too, and check the stage 6 binary's `nm` for `Eco_Kernel_FileSystem_`.
  - Wipe the caches named in memory `e2e-per-test-builddir-cache-stale` before trusting E2E.
  Done when `bootstrap` builds with eco/system as an unused dependency.
- **P4 Files** (§6.1, §6.3, `IO.writeString`). Port the pure helper tests. Done
  when `elm-tests` and `full` are green and `bootstrap` reaches its fixed points.
- **P5 Console, environment, exit** (§6.2 rest, §6.4). Check the compile-error E2E outputs (stdout
  and stderr text), and `echo | eco init`-style prompts at EOF (R8).
- **P6 HTTP** (§6.6). Run `eco install elm/json` and a registry `update` (delete
  `~/.eco/<ver>/packages/registry.dat`) once on Stage 1, on eco-boot (JS) and on the native stage, each
  with an empty package cache. The SHA must match on all three. Time the unpacking of a large
  package (e.g. `elm/core`) natively; if it takes over 1 s, revisit D4(b).
- **P7 Remove from eco/kernel** (§7).
- **P8 Close-out.** Update `guides/`, `docs/`, the Readme mentions of eco/kernel IO,
  `plans/eco-system-library.md` (new API, Appendix B), memory, and this plan's front matter.

## 9. Verification and risks

- **Gates.** `cmake --build build --target full` (Gate A, which includes `run-js-e2e`), `elm-tests`,
  and `cmake --build build --target bootstrap`, which has the stage 4b JS fixed point (compiler
  output must not change) and stage 7a native self-compile. Time stage 7a against a pre-migration
  baseline, cold and warm, as `eco-stage7a-cold-build` describes. Small wall-time regressions are
  fine; flag anything from ~5 % up (memory `wall-time-tolerance`).
- **Streamed MLIR writes.** Each chunk is now `Utf8.encode` + `Handle.writeFromOffset h -1`. If the
  stage 7a time moves by more than noise, batch chunks in `Backend.elm` to ≥ 64 KiB before writing.
- **Accepted message changes** (§2.4). The `OtherIOError` text is eco/system's message (e.g.
  `ENOENT: no such file or directory, open '/x'`) instead of the old kernel's. The status-0 HTTP
  detail becomes `network error` / `timeout` / `bad URL: …` instead of Node's or curl's text.
  `listDirectory` drops a trailing `.` from a name. Paths through `toPath` are normalised
  lexically: `a/../b` = `b`, even through a link. If any of these needs to stay identical, it's
  a user call.
- **Windows** (D6 = a). Native Windows depends on P1.5; a red Windows CI is recorded and fixed
  there, but does not hold back P4–P7 on Linux. The JS stages on Windows get
  backslash paths back from Node, which `OsPath.fromPath` normalises as `_File_normalize` did.
- **Stage 1 / native parity.** The generated twin shares all Elm above the kernel. Differences can
  only come from `Eco.XhrKernel` + eco-io, which are kept small and checked by the stub gate,
  `XhrKernelTest`, and the bootstrap fixed points.
- **No model checks involved.** None of this touches `runtime/src/allocator/`.

## 10. Implementation record (2026-11-25)

The plan was implemented on 2026-11-25. Where the implementation differs from §3–§8, this section
is what the code does; the sections above are kept as the reviewed plan.

### 10.1 Deviations

- **Stage 1 runs eco/system's real JS kernels, not an XHR twin (replaces D5's kernel layer, D9, and
  §5.2–§5.4 items 2–6).** The eco/system JS kernels (`system-kernel-cpp/src/Eco/Kernel/*.js`) depend
  only on `Elm.Kernel.Scheduler`/`Utils`/`List`, `Maybe` and each other, all present in stock Elm's
  output, and Stage 1 runs in Node anyway. So:
  - `compiler/scripts/make-stage1-system.js` generates the stock-Elm eco/system modules into
    `build/compiler/build-xhr/src-system` (closure of the modules the compiler imports) with the
    shared `system-kernel-cpp/scripts/stock-elm-rewrite.js` (docs.json unchanged, checked byte for
    byte). Each kernel reference, always the whole body of a `kName =` wrapper (checked), becomes a
    `Debug.todo "eco/system kernel <Home>.<fn>"` stub, and `kernels.json` lists the wrappers.
  - `compiler/scripts/link-stage1-system-kernels.js`, run after `apply-overrides.js`, replaces each
    surviving wrapper with `var <wrapper> = _Eco_<Home>_<fn>;` and links the kernel files those
    reach (and their Eco imports) before the first Elm definition, rendered as eco's JS backend
    renders a kernel in development mode. It fails if a stub survives. So there is no
    `Eco.XhrKernel`, no `unsafeCoerce` override and no eco-io op for eco/system: Stage 1 runs the
    kernels Stages 2–5 run.
  - `compiler/bin/index.js` keeps the old exit rule (a failed eco-io handler turns exit 0 into 1)
    with a `process.on("exit")` listener, since exit is now eco/system's `process.exit`.
- **File locks are dropped, not moved (replaces D3 and §7.2).** `Eco.File.lock` / `unlock` were
  no-ops natively (`lockBody` returns unit) and on JS (`// TODO`); only Stage 1's eco-io handler
  serialised them within one process. `Utils.lockWithFileLock` now just runs its task, which is
  what every compiler but Stage 1 did, and no `Eco.FileLock` kernel home was created. Real
  cross-process locking remains D3(b), future work.
- **Module placement.** The UTF-8 helper is `Codec.Utf8` (not `Utils.Utf8`): `System.IO` needs it,
  and `System` → `Utils` would make a folder cycle (`check-folder-cycles.py`). SHA-1 is
  `Codec.Sha1.hex`, written for this plan (not ported), 64-bit-safe as D4 requires.
- **elm-flate is used as a package**: `test/eco-system/src/FlateNativeTest.elm` (raw, zlib, gzip and
  stored streams) passes natively and on JS. `Codec.Sha1` was checked natively once against the
  FIPS vectors with a temporary copy in the E2E suite (the harnesses mirror only flat `src/*.elm`,
  so a compiler module cannot be an E2E test); it is also checked by `compiler/tests/Codec/`.
- **The appDataDir failure** with no home directory is `FileNotFound ""`, which renders exactly as
  the old kernels' failure did (`ENOENT` with an empty path), rather than an `OtherIOError`.
- **Additions not named above**: `System.IO.writeBytes`, `Utils.dirTouch`, `Utils.appDataDirFor`
  (pure, exposed for tests), `Builder.File.readUtf8OrError`, `Codec.Utf8.decodeLossy` (exposed for
  tests).
- **P7 scope notes.** `Eco_Kernel_register_all_gc_roots` (the eco/kernel GC root hook every native
  program calls) lived in `RuntimeExports.cpp`; it moves to `MVarExports.cpp` with `Eco.Runtime`'s
  removal. `eco_entry.cpp` / `eco_embed.cpp` no longer call `Eco::Kernel::Env::init` (it recorded argv
  for `Env.rawArgs`). libzip is no longer used by any kernel (`EcoKernel_Http` was its only user), but
  its detection, vendoring and the AOT/bundle link lines that name it are left in place: removing
  them is a cross-platform build change for a follow-up.
- **P7 as done.** Removed: `Eco.Console`, `Eco.Env`, `Eco.File`, `Eco.Http` (+ `.Error`),
  `Eco.Process` (+ `.Error`), `Eco.Runtime` — Elm, JS kernels, C++ (`*.cpp/.hpp/*Exports.cpp`),
  `KernelExports.h` sections, `ECO_KERNEL_MODS`, the `EcoKernel_*` libraries and their link lines
  (eco-kernel-cpp, test, unified `eco`), the `compiler/src-xhr/Eco/` twins, the eco-io handler ops
  (it now serves only MVar, GC and Crash; `test/scripts/eco-io-handler.test.js`, which tested only
  removed ops, is gone), eco-kernel's now-unused `KernelDebug.hpp`, the `adm-zip` and `which` npm
  dependencies, and the build-kernel `node_modules` link (`cmake/EcoLinkNodeModules.cmake`).
  Tables: 40 KernelSetFacts rows, the eco/kernel rows of `Visibility.elm` (elm/core's `Process`,
  elm/file's `File` and elm/http's `Http` rows kept), 82 + 192 license CSV lines, 41
  `elm_kernel_functions.csv` rows; MVar's two license pins re-audited for `MVarExports.cpp` gaining
  the GC root hook. Tests: 30 `test/eco-kernel` E2E tests and `test/kernel/ConsoleKernelTest.cpp`
  deleted, two Runtime cases of `test/platform/HeapResetKernelStateTest.cpp` deleted,
  `NativeDriverEmptyBytesTest` ported to `FileSystem`, `test/elm-http` moved to eco/system;
  `test/eco-system/src/FileSpecialFilesTest.elm` keeps the procfs, directory, /dev/full, huge-file
  and atomic-write cases. `projects/eco-test` and `projects/eco-init` ported to eco/system.
  Invariants IO_ERR_001, IO_ERR_002 and FORBID_IO_001 amended. The unified `eco` binary now links
  the `EcoSystem_*` libraries (it is the compiler, so it needs them).

### 10.2 Verification (2026-11-25)

- **Bootstrap** (`--target bootstrap`, after P7): all stages pass, including the Stage 4b JS fixed
  point, the Stage 8c native fixed point and Stage 9's unified `eco`.
- **Cold self-compile, before vs after** (the pre-migration `eco` binary and the new one, compiling
  the same `compiler/src` from an empty `eco-stuff`, packages warm, alternated): old 79.9 / 80.0 s,
  new 81.2 / 81.7 s (+1.9 %), peak RSS 7.5–7.8 GB both; the emitted MLIR is byte-identical.
- **P6, package downloads** from an empty `ECO_HOME` with the native `eco` and with `eco-boot.js`:
  the registry fetch (gzip) and elm/core, elm/json and elm/url download, pass the registry's SHA-1
  check, unpack, and compile; the unpacked sources are byte-identical to those Stage 1 unpacked.
  (package.elm-lang.org answers 406 without `Accept-Encoding: gzip`, so the gzip path is the only
  path.)
- **Targeted suites during the work**: JIT E2E eco-system 270/270, elm-compile-errors 222/222,
  elm-http 28/28, eco-kernel 46/46 then 16/16 after P7; JS E2E eco-system 260 (+10 skipped) and
  elm-conformance 35; elm-tests 22,162/22,162; the new eco-system tests natively and on JS; the
  kernel-license manifest, kernel homes, opaque types, folder cycles, ECO_KLOG copies and the other
  `full` script checks.
- **Final gates**: `cmake --build build --target full` passes (JIT E2E 3,172/3,172, JS E2E
  eco-system 261 + 10 skipped and elm-conformance 35, the Node addon and driver CLI checks, every
  script check); `elm-tests` 22,162/22,162 (`KernelLicenseTest` 15 rewritten: no Elm/Eco kernel home
  is shared any more, so it checks each prefix's row is not found under the other); the TLA+ canary
  fired for the removed `Eco.Runtime` scanner registration, audited in M1's AUDIT.md (no model
  change) and re-pinned.

### 10.3 Follow-ups

- libzip (and the eco/kernel-side libcurl/OpenSSL detection) is unused by any kernel; drop its
  vendoring and the AOT/bundle link lines that name it.
- Native Windows: P1.5's Win32 code is compile-unverified here; Windows CI is its gate.
- Real cross-process locking of the package cache, if wanted, is D3(b): `FileSystem.Handle.lock`.
- `Codec.Sha1` is checked natively only by a one-off run and by real installs; a native E2E test
  would need the E2E harnesses to mirror nested source directories.
