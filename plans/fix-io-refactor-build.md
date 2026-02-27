# Fix IO Refactor Build Breakage

## Status: IMPLEMENTED

## Summary

The IO refactoring (documented in `io-refactor.md`) modified 5 Elm source files to import
`Eco.*` modules and created XHR implementations in `compiler/src-xhr/Eco/`, but left
3 critical gaps that break all build and test paths.

### Key architectural context

There are two JS entry points for the compiler:

| File | Role | Loads | XHR handlers | Consumers |
|------|------|-------|-------------|-----------|
| `bin/index.js` | **CLI runner** | `guida.js` | Legacy only (no eco-io) | `npx guida`, `npm run build:bin` |
| `lib/index.js` | **Library API** | `guida.min.js` | Legacy only, config-abstracted | npm `require("guida")` |

`lib/index.js` is a programmatic API (`make()`, `format()`, `install()`, etc.) that takes a
`config` object with pluggable IO implementations (`config.readFile`, `config.writeFile`,
`config.details`, etc.) intended for embedding in non-Node environments (e.g. browser with
IndexedDB). However, this library path is **currently dormant**: `guida.min.js` is 0 bytes,
`indexeddb-fs` is listed as a dependency but has zero imports, and no in-repo code exercises
the config API. The library API uses `API.Main` (not `Terminal.Main`).

**Decision**: Focus the fix on `bin/index.js` only. Defer `lib/index.js` migration until the
library API is actively used. The library build (`guida.min.js`) is empty and non-functional
regardless of the IO refactoring.

---

## Problem 1: `elm.json` missing `src-xhr` source directory (BLOCKS COMPILATION)

### Symptom

All builds fail with 7 MODULE NOT FOUND errors:

```
-- MODULE NOT FOUND -- src/System/Exit.elm:    import Eco.Process
-- MODULE NOT FOUND -- src/System/IO.elm:      import Eco.Console
-- MODULE NOT FOUND -- src/System/IO.elm:      import Eco.File
-- MODULE NOT FOUND -- src/Utils/Main.elm:     import Eco.Console
-- MODULE NOT FOUND -- src/Utils/Main.elm:     import Eco.Env
-- MODULE NOT FOUND -- src/Utils/Main.elm:     import Eco.File
-- MODULE NOT FOUND -- src/Utils/Main.elm:     import Eco.Runtime
```

(Plus `Builder/File.elm` imports `Eco.Console` and `Eco.File`.)

### Root cause

`compiler/elm.json` has:
```json
"source-directories": ["src"]
```

The `Eco.*` XHR modules live in `compiler/src-xhr/Eco/` which is not in the source path.

An `elm-bootstrap.json` was created with `["src", "src-xhr"]` but **nothing references it**.
The stock `elm` compiler has no flag to select a non-default elm.json filename — it always
reads `elm.json` from the working directory. All build paths use the default:

| Build path | Tool | Config used |
|------------|------|-------------|
| `npm test` | `elm-test-rs` | `elm.json` |
| `npm run build:bin` | `elm make` via `scripts/build.sh` | `elm.json` |
| `npm run buildself` | `node bin/index.js make` via `scripts/build-self.sh` | `elm.json` |
| `cmake --build build --target guida` | `elm make` via `CMakeLists.txt` | `elm.json` |

### Fix

Add `"src-xhr"` to `compiler/elm.json`:

```json
"source-directories": ["src", "src-xhr"]
```

This is the minimum change. `elm.json` already has `elm/http` (needed by the XHR modules)
and test dependencies (needed by `elm-test-rs`). `elm-bootstrap.json` becomes redundant for
the bootstrap build but can be kept as documentation.

---

## Problem 2: `bin/index.js` has no `eco-io` handler (BLOCKS RUNTIME)

### Symptom

Even after fixing elm.json, running the compiled compiler via `node bin/index.js` will fail.
The migrated Elm code sends all IO requests to the `"eco-io"` URL endpoint via `Eco.XHR`:

```elm
-- Eco/XHR.elm (all XHR modules use this)
Http.task
    { url = "eco-io"
    , body = Http.jsonBody (Encode.object [("op", ...), ("args", ...)])
    , ...
    }
```

But `bin/index.js` has **no handler for `"eco-io"`**. Only the new `eco-boot-runner.js`
(which loads `eco-boot.js`, not `guida.js`) has it:

```javascript
// eco-boot-runner.js line 77
server.post("eco-io", (request) => {
    const parsed = JSON.parse(request.body);
    handleEcoIO(parsed, (status, body) => {
        request.respond(status, null, body);
    });
});
```

Without this handler, `index.js`'s catch-all `setDefaultHandler` will attempt to proxy the
request as a real HTTP call to URL `"eco-io"`, which is not a valid URL and will crash.

### What needs the eco-io handler

The migrated functions route through `Eco.XHR` → `"eco-io"` endpoint:

| Elm file | Functions now using eco-io |
|----------|---------------------------|
| `System/IO.elm` | `writeString`, `withFile`, `hClose`, `hFileSize`, `hPutStr`, `getLine` |
| `System/Exit.elm` | `exitWith` (→ `Eco.Process.exit`) |
| `Utils/Main.elm` | 20 functions: `lockFile`, `unlockFile`, `dirDoesFileExist`, `dirFindExecutable`, `dirCreateDirectoryIfMissing`, `dirGetCurrentDirectory`, `dirGetAppUserDataDirectory`, `dirGetModificationTime`, `dirRemoveFile`, `dirRemoveDirectoryRecursive`, `dirDoesDirectoryExist`, `dirCanonicalizePath`, `dirWithCurrentDirectory`, `dirListDirectory`, `envLookupEnv`, `envGetArgs`, `nodeGetDirname`, `nodeMathRandom` |
| `Builder/File.elm` | `readUtf8`, `readStdin` |

### What still uses old-style endpoints

7 functions in `Utils/Main.elm` (plus all of `System/Process.elm`, `Builder/Http.elm`,
`API/Main.elm`, `Control/Monad/State/Strict.elm`) still use `Utils.Impure` → old endpoints:

| Old endpoint | Used by |
|-------------|---------|
| `newEmptyMVar` | `Utils/Main.elm` |
| `readMVar` | `Utils/Main.elm` |
| `takeMVar` | `Utils/Main.elm` |
| `putMVar` | `Utils/Main.elm` |
| `binaryDecodeFileOrFail` | `Utils/Main.elm` |
| `write` (binary) | `Utils/Main.elm` (via `binaryEncodeFile`) |
| `replGetInputLine` | `Utils/Main.elm` |
| `withCreateProcess` | `System/Process.elm` |
| `waitForProcess` | `System/Process.elm` |
| `getArchive` | `Builder/Http.elm` |
| `httpUpload` | `Builder/Http.elm` |
| `getArgs` | `API/Main.elm` |
| `exitWithResponse` | `API/Main.elm` |
| `putStateT` / `getStateT` | `Control/Monad/State/Strict.elm` |

**Both** the eco-io handler and the legacy handlers are needed. `eco-boot-runner.js` already
has both; `index.js` has only the legacy handlers.

### Fix

Add the `eco-io` handler to `compiler/bin/index.js`, identical to how it's done in
`eco-boot-runner.js`:

```javascript
const { handleEcoIO } = require("./eco-io-handler");

server.post("eco-io", (request) => {
    try {
        const parsed = JSON.parse(request.body);
        handleEcoIO(parsed, (status, body) => {
            request.respond(status, null, body);
        });
    } catch (e) {
        console.error("eco-io handler error:", e);
        request.respond(500, null, JSON.stringify({ error: e.message }));
    }
});
```

This must be registered **before** the catch-all `setDefaultHandler`.

The old-style endpoint handlers remain in place for the 14+ legacy operations.

---

## Problem 3: CMakeLists.txt missing `src-xhr` dependency tracking (BUILD CORRECTNESS)

### Symptom

Changes to `src-xhr/*.elm` files won't trigger a CMake rebuild.

### Root cause

`compiler/CMakeLists.txt` line 18-20:
```cmake
file(GLOB_RECURSE ELM_SOURCES
    "${COMPILER_DIR}/src/*.elm"
)
```

### Fix

```cmake
file(GLOB_RECURSE ELM_SOURCES
    "${COMPILER_DIR}/src/*.elm"
    "${COMPILER_DIR}/src-xhr/*.elm"
)
```

---

## Problem 4 (potential): `eco-io-handler.js` re-implements kernel instead of wrapping it

### Observation

The design document (`plans/bootstrap-io-wiring.md` Phase 4) specifies that
`eco-io-handler.js` should be a **thin wrapper** that delegates to the JS kernel
files in `eco-kernel-cpp/src/Eco/Kernel/*.js`:

```
The handler must be a thin wrapper — it translates JSON ↔ JS kernel calls, nothing more.
```

But the actual implementation re-implements all IO operations using Node.js APIs directly,
without importing or referencing any kernel JS files. This was likely a pragmatic choice
because the kernel JS files use Elm's internal scheduler conventions (`__Scheduler_binding`,
`__Scheduler_succeed`, `__Maybe_Just`, etc.) that can't be `require()`d as standard Node
modules.

### Risk

Behavioral drift between `eco-io-handler.js` and the kernel JS. For example:
- `eco-io-handler.js` `File.list` returns a JSON array: `{"value": ["a", "b"]}`
- Kernel `_File_list` returns an Elm `List` via `__Scheduler_succeed(entries)`
  where `entries` is a JS array that the Elm runtime converts to a `List`

The XHR Elm code (`Eco.File.list`) decodes the JSON array via `Decode.list Decode.string`,
which produces an Elm `List String`. This works because the XHR layer handles
serialization/deserialization. But any semantic differences (error handling, edge cases,
return value format) could cause divergent behavior between bootstrap and kernel builds.

### Recommendation

This is not a build blocker. Document this as a known deviation from the design. Consider
adding integration tests that exercise the same operations through both the XHR and kernel
paths and compare results.

---

## Problem 5 (potential): Type-level issues in migrated Elm code

### Observation

We cannot verify whether the modified Elm code has type errors until the MODULE NOT FOUND
errors are resolved. Once `elm.json` includes `src-xhr`, the build may reveal additional
issues. These could include:

1. **Handle constructor visibility**: `System/IO.elm` pattern-matches on `Eco.File.Handle`:
   ```elm
   -- System/IO.elm line 182
   |> Task.map (\(Eco.File.Handle fd) -> Handle fd)
   ```
   and constructs them:
   ```elm
   -- System/IO.elm line 207
   Eco.File.close (Eco.File.Handle handle)
   ```
   This requires `Handle(..)` (constructors exposed), which the XHR variant does expose.
   If the kernel variant only exposes `Handle` (opaque), Stage 2 will fail.

2. **hPutStr routing**: `System/IO.elm` routes `hPutStr` through `Eco.Console.write`:
   ```elm
   hPutStr (Handle fd) content =
       Eco.Console.write (Eco.Console.Handle fd) content
   ```
   But `hPutStr` can be called with file descriptor handles (not just stdout=1/stderr=2).
   The `eco-io-handler.js` Console.write handler only handles fd 1 and 2. If hPutStr is
   called with a file handle opened via `withFile`, the write will silently do nothing.

   In the old code, `hPutStr` went to `index.js`'s handler which called `fs.write(fd, ...)`,
   supporting any file descriptor. The migration changed the routing but narrowed the
   semantics.

3. **`Eco.File.readBytes`/`writeBytes` XHR transport**: The `readBytes` implementation uses
   `Bytes.Decode.bytes` with a length prefix that the handler doesn't produce. The
   `writeBytes` implementation doesn't actually send the byte content. These are documented
   as non-functional in `io-refactor.md` and not exercised by the compiler, but they are
   compile-time valid (they should type-check fine).

---

## Minimal Fix Checklist

These changes are needed to restore the build:

### 1. `compiler/elm.json` — Add `src-xhr` source directory

```diff
  "source-directories": [
-     "src"
+     "src",
+     "src-xhr"
  ],
```

### 2. `compiler/bin/index.js` — Register eco-io handler

Add, before the `setDefaultHandler` call (before line 443):

```javascript
const { handleEcoIO } = require("./eco-io-handler");

server.post("eco-io", (request) => {
    try {
        const parsed = JSON.parse(request.body);
        handleEcoIO(parsed, (status, body) => {
            request.respond(status, null, body);
        });
    } catch (e) {
        console.error("eco-io handler error:", e);
        request.respond(500, null, JSON.stringify({ error: e.message }));
    }
});
```

### 3. `compiler/CMakeLists.txt` — Track `src-xhr` files

```diff
  file(GLOB_RECURSE ELM_SOURCES
      "${COMPILER_DIR}/src/*.elm"
+     "${COMPILER_DIR}/src-xhr/*.elm"
  )
```

### 4. Verify build

```bash
cd compiler && npm test     # elm-test-rs with fuzz 10
npm run build:bin           # elm make → bin/guida.js
node bin/index.js make --help  # smoke test the compiled compiler
```

---

## Deferred / Follow-up Items

These are not build blockers but should be tracked:

1. **hPutStr fd routing** — `System/IO.elm:hPutStr` now routes file-descriptor writes through
   `Eco.Console.write`, which only handles stdout/stderr. This is a behavioral regression for
   any code that calls `hPutStr` with a handle from `withFile`. Needs investigation of whether
   the compiler actually does this. If so, either:
   - Route non-console fds through `Eco.File` instead, or
   - Expand `eco-io-handler.js` Console.write to handle arbitrary fds.

2. **Handle constructor visibility** — The XHR variant exposes `Handle(..)` constructors,
   the kernel variant exposes `Handle` (opaque). Either add `toInt`/`fromInt` to both, or
   expose constructors in the kernel variant.

3. **`elm-bootstrap.json` disposition** — Now redundant if `elm.json` includes `src-xhr`.
   Keep as documentation of the bootstrap-specific config intent.

4. **eco-io-handler.js kernel wrapping** — Currently re-implements Node.js IO instead of
   wrapping the kernel JS. Consider adding integration tests to verify behavioral parity.

5. **Legacy handler duplication** — `eco-boot-runner.js` copies all handlers from `index.js`.
   Now that `index.js` will also have the eco-io handler, the two files have significant
   overlap. Consider extracting shared handler code.

6. **`lib/index.js` (Library API entry point)** — Dormant. `guida.min.js` is 0 bytes.
   `indexeddb-fs` dependency has zero imports. The config-abstracted IO model
   (`config.readFile`, `config.writeFile`, etc.) cannot reuse `eco-io-handler.js` directly
   because it hardcodes Node.js APIs. When the library API is revived, it will need its own
   eco-io handler that translates through the config abstraction. Not a concern until then.
