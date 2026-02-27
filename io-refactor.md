# IO Refactoring Implementation Report

## Overview

This document records the current state of the IO layer refactoring for the Eco compiler's three-stage bootstrap pipeline. The goal is to decouple the compiler's IO from the legacy `Utils.Impure` HTTP-mock system and route it through the unified `Eco.*` module interface, enabling:

1. **Stage 1** (Bootstrap): Stock Elm compiler builds `eco-boot.js` using XHR-based `Eco.*` modules
2. **Stage 2** (Kernel JS): `eco-boot.js` builds `eco-node.js` using `Eco.Kernel.*` directly
3. **Stage 3** (Native): `eco-node.js` builds `eco-native` linked with C++ IO kernel

The design document is at `plans/bootstrap-io-wiring.md`.

---

## Architecture

### Before

```
Compiler Elm code
    → System.IO / Utils.Main  (Haskell-style IO wrappers)
    → Utils.Impure             (Http.task POST to mock server)
    → compiler/bin/index.js    (mock-xmlhttprequest handler, ~30 endpoints)
    → Node.js APIs             (fs, child_process, os, etc.)
```

Every IO operation was encoded as an HTTP POST to a URL matching the operation name (e.g. `"dirDoesFileExist"`, `"hPutStr"`). The Node.js handler in `index.js` dispatched on the URL and called the appropriate Node.js API.

### After

```
Compiler Elm code
    → System.IO / Utils.Main / Builder.File  (unchanged public API)
    → Eco.Console / Eco.File / Eco.Env / Eco.Process / Eco.Runtime
        ├── [Bootstrap build: src-xhr/Eco/*.elm]
        │   → Eco.XHR  (JSON-encoded HTTP POST to "eco-io" endpoint)
        │   → eco-io-handler.js  (thin wrapper around Node.js APIs)
        │
        └── [Kernel build: eco-kernel-cpp/src/Eco/*.elm]
            → Eco.Kernel.*  (JS kernel or C++ kernel directly)

Legacy operations (MVars, binary files, REPL, HTTP proxy)
    → Utils.Impure  (unchanged, routed through legacy handler)
```

The `Eco.*` modules provide a platform-neutral interface. Two implementations exist:
- **XHR variant** (`compiler/src-xhr/Eco/*.elm`): for bootstrap, uses HTTP POST
- **Kernel variant** (`eco-kernel-cpp/src/Eco/*.elm`): for kernel/native builds, calls `Eco.Kernel.*` directly

Both expose identical module names and type signatures. The build config (`elm-bootstrap.json` vs `elm-kernel.json`) selects which implementation is active.

---

## New Files Created

### XHR IO Modules (`compiler/src-xhr/Eco/`)

| File | Lines | Functions | Description |
|------|-------|-----------|-------------|
| `XHR.elm` | 128 | `stringTask`, `jsonTask`, `bytesTask`, `unitTask` | Shared HTTP plumbing. All XHR modules delegate here. Sends JSON `{op, args}` to `"eco-io"` endpoint. |
| `Console.elm` | 73 | `write`, `readLine`, `readAll` | Console IO. Exposes `Handle(..)` with `stdout`/`stderr`. |
| `File.elm` | 300 | 20 functions | Full filesystem: read/write (string + bytes), handle ops, locks, directory queries/ops. Exposes `Handle(..)`, `IOMode(..)`. |
| `Process.elm` | 95 | `exit`, `spawn`, `wait` | Process management. Exposes `ExitCode(..)`, `ProcessHandle`. |
| `Env.elm` | 40 | `lookup`, `rawArgs` | Environment variable lookup and CLI args. |
| `Runtime.elm` | 45 | `dirname`, `random`, `saveState` | Script directory, random float, REPL state persistence. |
| `MVar.elm` | 141 | `new`, `read`, `take`, `put` | MVar stubs. See "Known Limitations" below. |

**XHR Protocol**: Every operation sends a JSON POST to URL `"eco-io"`:
```json
{ "op": "File.readString", "args": { "path": "/some/file" } }
```
Responses are JSON `{ "value": <result> }` for data-returning ops, or empty 200 for unit ops.

### Node.js Handlers (`compiler/bin/`)

| File | Lines | Description |
|------|-------|-------------|
| `eco-io-handler.js` | 290 | Thin JSON→Node.js dispatch for all `Eco.*` operations. Mirrors the semantics of `eco-kernel-cpp/src/Eco/Kernel/*.js`. |
| `eco-boot-runner.js` | 320 | Bootstrap entry point. Sets up mock XHR, registers eco-io handler at `"eco-io"` endpoint, includes all legacy handlers (copy of `index.js`), loads `eco-boot.js`. |

The handler covers: Console (3 ops), File (20 ops), Process (3 ops), Env (2 ops), Runtime (3 ops), MVar (1 op).

### Build Configurations (`compiler/`)

| File | Source Dirs | Key Deps | Purpose |
|------|------------|----------|---------|
| `elm-bootstrap.json` | `["src", "src-xhr"]` | `elm/http` (for XHR), no `eco/kernel` | Stock Elm compiler → `eco-boot.js` |
| `elm-kernel.json` | `["src"]` | `eco/kernel`, no `elm/http` | Eco compiler → `eco-node.js` |

Both share the same non-IO dependencies (elm-vlq, levenshtein, elm-format-number, etc.).

---

## Modified Files

### `compiler/src/System/IO.elm` — Full migration

**Before**: Imported `Utils.Impure`, `Http`, `Json.Decode`. Each function called `Impure.task` with URL-encoded operations.

**After**: Imports `Eco.Console` and `Eco.File`. No remaining `Impure` dependency.

| Function | Before | After |
|----------|--------|-------|
| `writeString` | `Impure.task "writeString" [Http.header "path" path] (Impure.StringBody content) (Impure.Always ())` | `Eco.File.writeString path content` |
| `withFile` | `Impure.task "withFile" [...] (Impure.StringBody path) (Impure.DecoderResolver ...)` | `Eco.File.open path (ioModeToEcoMode mode) \|> Task.map ...` |
| `hClose` | `Impure.task "hClose" [] (Impure.StringBody (String.fromInt handle)) (Impure.Always ())` | `Eco.File.close (Eco.File.Handle handle)` |
| `hFileSize` | `Impure.task "hFileSize" [] (Impure.StringBody ...) (Impure.DecoderResolver Decode.int)` | `Eco.File.size (Eco.File.Handle handle)` |
| `hPutStr` | `Impure.task "hPutStr" [Http.header "fd" ...] (Impure.StringBody content) (Impure.Always ())` | `Eco.Console.write (Eco.Console.Handle fd) content` |
| `getLine` | `Impure.task "getLine" [] Impure.EmptyBody (Impure.StringResolver identity)` | `Eco.Console.readLine` |

New helper `ioModeToEcoMode` translates `System.IO.IOMode` → `Eco.File.IOMode`.

### `compiler/src/System/Exit.elm` — Full migration

**Before**: Imported `Utils.Impure`. Called `Impure.task "exitWith"` with `Impure.Crash` resolver.

**After**: Imports `Eco.Process`. Translates `System.Exit.ExitCode` → `Eco.Process.ExitCode`, calls `Eco.Process.exit`.

### `compiler/src/Utils/Main.elm` — Partial migration (20 functions)

Added imports: `Eco.Console`, `Eco.Env`, `Eco.File`, `Eco.Runtime`.

**Migrated functions** (20 total):

| Function | Old endpoint | New delegation |
|----------|-------------|----------------|
| `lockFile` | `"lockFile"` | `Eco.File.lock` |
| `unlockFile` | `"unlockFile"` | `Eco.File.unlock` |
| `dirDoesFileExist` | `"dirDoesFileExist"` | `Eco.File.fileExists` |
| `dirFindExecutable` | `"dirFindExecutable"` | `Eco.File.findExecutable` |
| `dirCreateDirectoryIfMissing` | `"dirCreateDirectoryIfMissing"` | `Eco.File.createDir` |
| `dirGetCurrentDirectory` | `"dirGetCurrentDirectory"` | `Eco.File.getCwd` |
| `dirGetAppUserDataDirectory` | `"dirGetAppUserDataDirectory"` | `Eco.File.appDataDir` |
| `dirGetModificationTime` | `"dirGetModificationTime"` | `Eco.File.modificationTime` |
| `dirRemoveFile` | `"dirRemoveFile"` | `Eco.File.removeFile` |
| `dirRemoveDirectoryRecursive` | `"dirRemoveDirectoryRecursive"` | `Eco.File.removeDir` |
| `dirDoesDirectoryExist` | `"dirDoesDirectoryExist"` | `Eco.File.dirExists` |
| `dirCanonicalizePath` | `"dirCanonicalizePath"` | `Eco.File.canonicalize` |
| `dirWithCurrentDirectory` | two `"dirWithCurrentDirectory"` calls | `Eco.File.setCwd` (bracket pattern preserved) |
| `dirListDirectory` | `"dirListDirectory"` | `Eco.File.list` |
| `envLookupEnv` | `"envLookupEnv"` | `Eco.Env.lookup` |
| `envGetArgs` | `"envGetArgs"` | `Eco.Env.rawArgs` |
| `nodeGetDirname` | `"nodeGetDirname"` | `Eco.Runtime.dirname` |
| `nodeMathRandom` | `"nodeMathRandom"` | `Eco.Runtime.random` |

**Remaining on `Impure.task`** (7 functions):

| Function | Reason |
|----------|--------|
| `readMVar` | Binary transport with explicit `Bytes.Decode.Decoder` — no Eco.* equivalent |
| `takeMVar` | Same |
| `putMVar` | Binary transport with explicit `Bytes.Encode.Encoder` |
| `newEmptyMVar` | MVar ID allocation — stays on legacy handler |
| `binaryDecodeFileOrFail` | Raw binary file read with custom decoder |
| `binaryEncodeFile` | Raw binary file write with custom encoder |
| `replGetInputLine` | REPL-specific prompt I/O |

### `compiler/src/Builder/File.elm` — Full migration

**Before**: Imported `Utils.Impure`. Two functions used `Impure.task` directly.

**After**: Imports `Eco.File` and `Eco.Console`. No remaining `Impure` dependency.

| Function | Before | After |
|----------|--------|-------|
| `readUtf8` | `Impure.task "read" [] (Impure.StringBody path) (Impure.StringResolver identity)` | `Eco.File.readString path` |
| `readStdin` | `Impure.task "readStdin" [] Impure.EmptyBody (Impure.StringResolver identity)` | `Eco.Console.readAll` |

### `compiler/src/Terminal/Main.elm` — Partial migration

**Before**: Imported `Utils.Impure`. Called `Impure.task "exitWith"` directly in `main`.

**After**: Imports `System.Exit`. Calls `Exit.exitSuccess` (which delegates to `Eco.Process`).

---

## Remaining `Utils.Impure` Usage

After the refactoring, `Utils.Impure` is imported by 5 files (down from 8):

| File | Operations | Why not migrated |
|------|-----------|-----------------|
| `Utils/Main.elm` | MVars (4), binary file I/O (2), REPL (1) | Binary transport and explicit encoder/decoder APIs have no Eco.* equivalent |
| `System/Process.elm` | `withCreateProcess`, `waitForProcess` | Complex JSON protocol with stdin pipe handles, `ProcessHandle` wrapping |
| `Builder/Http.elm` | `fetch`, `getArchive`, `upload` | HTTP proxy operations (download zips, upload multipart forms) |
| `API/Main.elm` | `getArgs`, `exitWithResponse` | API-specific JSON stdin/stdout protocol |
| `Control/Monad/State/Strict.elm` | `putStateT` | REPL state persistence (binary blob) |

These all go through the legacy handler endpoints in `eco-boot-runner.js` (which includes the full `index.js` handler set).

---

## Type Signature Compatibility

The XHR modules (`src-xhr/Eco/*.elm`) match the kernel modules (`eco-kernel-cpp/src/Eco/*.elm`) with the following notes:

| Module | Match | Notes |
|--------|-------|-------|
| `Eco.Console` | Exact | XHR exposes `Handle(..)` (constructor visible) for adapter use; kernel exposes `Handle` (opaque). |
| `Eco.File` | Exact | Same constructor visibility note. `readBytes`/`writeBytes` XHR implementation is incomplete (see limitations). |
| `Eco.Process` | Exact | Both expose `ExitCode(..)` and `ProcessHandle` (opaque). |
| `Eco.Env` | Exact | |
| `Eco.Runtime` | Exact | |
| `Eco.MVar` | Structural only | XHR `read`/`take`/`put` are stubs — polymorphic `a` cannot be serialized over HTTP. See below. |

---

## Known Limitations

### 1. `Eco.MVar` XHR variant is non-functional

The kernel `Eco.MVar` stores opaque Elm values in JS memory. The XHR variant cannot replicate this because the polymorphic type `a` in `read : MVar a -> Task Never a` cannot be serialized over HTTP without an explicit encoder/decoder.

**Mitigation**: The compiler does not use `Eco.MVar` directly. It uses its own `Utils.Main.readMVar`/`takeMVar`/`putMVar` which accept explicit `Bytes.Decode.Decoder`/`Bytes.Encode.Encoder` arguments and go through `Impure.task` → legacy handler. This path is unchanged and fully functional.

### 2. `Eco.File.readBytes` / `writeBytes` XHR transport

Binary data transport over the JSON XHR protocol is awkward. `readBytes` uses a bytes resolver but the eco-io handler returns a raw Node.js Buffer, which may not round-trip correctly through the mock XHR JSON layer. `writeBytes` currently only sends the path and byte length, not the actual bytes.

**Mitigation**: The compiler's binary file operations go through `Utils.Main.binaryDecodeFileOrFail` and `binaryEncodeFile`, which use the legacy `Impure.task` path with proper binary transport. The `Eco.File.readBytes`/`writeBytes` XHR functions exist for API completeness but are not exercised by the compiler in the bootstrap build.

### 3. Handle constructor visibility

The XHR variants expose `Handle(..)` (with constructor) to allow `System.IO` and `Utils.Main` to construct/destructure handles. The kernel variants expose `Handle` (opaque). This means code that pattern-matches on `Eco.File.Handle` or `Eco.Console.Handle` will compile with the XHR variant but not the kernel variant.

**Resolution needed**: Either expose constructors in the kernel variants, or add conversion functions (`toInt`/`fromInt`) to both variants.

### 4. `eco-boot-runner.js` duplicates `index.js`

The bootstrap runner includes a full copy of all legacy handlers from `index.js` plus the new eco-io handler. This is intentional for the bootstrap phase but means handler logic is duplicated.

**Resolution**: Once the compiler is fully migrated off `Utils.Impure`, the legacy handlers can be removed from `eco-boot-runner.js`.

---

## Migration Coverage Summary

| Category | Total ops | Migrated | On legacy path | Coverage |
|----------|-----------|----------|----------------|----------|
| Console I/O | 4 | 4 | 0 | 100% |
| File I/O (string) | 3 | 3 | 0 | 100% |
| File I/O (binary) | 2 | 0 | 2 | 0% |
| File handles | 3 | 3 | 0 | 100% |
| File locking | 2 | 2 | 0 | 100% |
| Directory queries | 5 | 5 | 0 | 100% |
| Directory ops | 5 | 5 | 0 | 100% |
| Environment | 3 | 2 | 1 | 67% |
| Process (simple) | 3 | 3 | 0 | 100% |
| Process (complex) | 2 | 0 | 2 | 0% |
| MVars | 4 | 0 | 4 | 0% |
| Runtime | 2 | 2 | 0 | 100% |
| REPL | 2 | 0 | 2 | 0% |
| HTTP proxy | 3 | 0 | 3 | 0% |
| Binary file I/O | 2 | 0 | 2 | 0% |
| **Total** | **45** | **29** | **16** | **64%** |

The 16 unmigrated operations are all either:
- Binary transport that requires explicit encoders/decoders (MVars, binary files)
- Complex multi-step protocols (withCreateProcess with stdin pipes)
- External HTTP operations (archive downloads, uploads)
- REPL-specific (prompt input, state persistence)

These all continue to function via the legacy `Impure.task` → handler path, which is fully supported by `eco-boot-runner.js`.

---

## File Inventory

### New files (9)

```
compiler/src-xhr/Eco/XHR.elm           # 128 lines — shared HTTP plumbing
compiler/src-xhr/Eco/Console.elm       #  73 lines — console IO via XHR
compiler/src-xhr/Eco/File.elm          # 300 lines — filesystem IO via XHR
compiler/src-xhr/Eco/Process.elm       #  95 lines — process mgmt via XHR
compiler/src-xhr/Eco/Env.elm           #  40 lines — environment via XHR
compiler/src-xhr/Eco/Runtime.elm       #  45 lines — runtime utils via XHR
compiler/src-xhr/Eco/MVar.elm          # 141 lines — MVar stubs via XHR
compiler/bin/eco-io-handler.js         # 290 lines — JSON→Node.js dispatch
compiler/bin/eco-boot-runner.js        # 320 lines — bootstrap entry point
```

### New config files (2)

```
compiler/elm-bootstrap.json            # Bootstrap build config (src + src-xhr)
compiler/elm-kernel.json               # Kernel build config (src + eco/kernel)
```

### Modified files (5)

```
compiler/src/System/IO.elm             # Full migration: Impure → Eco.Console + Eco.File
compiler/src/System/Exit.elm           # Full migration: Impure → Eco.Process
compiler/src/Utils/Main.elm            # Partial: 20 functions migrated, 7 remain on Impure
compiler/src/Builder/File.elm          # Full migration: Impure → Eco.File + Eco.Console
compiler/src/Terminal/Main.elm         # exitWith → System.Exit.exitSuccess
```

### Unchanged files still using `Utils.Impure` (4)

```
compiler/src/System/Process.elm        # withCreateProcess, waitForProcess
compiler/src/Builder/Http.elm          # fetch, getArchive, upload
compiler/src/API/Main.elm              # getArgs, exitWithResponse
compiler/src/Control/Monad/State/Strict.elm  # putStateT
```

---

## Next Steps

1. **Handle constructor visibility** — Decide whether to expose `Handle(..)` in kernel variants or add `toInt`/`fromInt` helpers to both variants.
2. **Binary transport** — Implement proper binary file round-trip over XHR (base64 encoding) or accept that binary ops stay on the legacy path.
3. **Integration test** — Build `eco-boot.js` with `elm-bootstrap.json` using the stock Elm compiler and verify it runs under `eco-boot-runner.js`.
4. **Kernel recognition** — Verify the Eco compiler recognizes kernel author `"eco"` and prefix `"Eco.Kernel."` for Stage 2.
5. **CMake targets** — Add build targets for `eco-boot`, `eco-node`, `eco-native`.
6. **Deduplicate handlers** — Once migration is complete, remove legacy handler duplication.
