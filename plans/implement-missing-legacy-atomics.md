# Implement Missing Legacy Atomics as Eco.* XHR Operations

## Status: PLAN

## Goal

Migrate all 15 remaining legacy IO handlers out of `bin/index.js` by implementing
proper Eco.* XHR modules and updating their Elm consumers. After this, all IO goes
through the `eco-io` endpoint, and the legacy `Impure.task` path is fully retired
from these call sites.

Then centralize all IO operations into `System/IO.elm` so the compiler has a single
IO routing layer, and rename functions to their `guida-io-ops.csv` new names.

The two network ops (`getArchive`, `httpUpload`) remain as legacy — they are
intentionally bundled for performance and are not atomic IO primitives.

---

## Resolved Design Decisions

1. **Single URL**: All eco-io traffic (JSON and binary) goes through the same `eco-io`
   URL. The handler distinguishes JSON vs binary requests by inspecting the
   presence of the `X-Eco-Op` header (binary requests set it, JSON requests have
   the op in the JSON body).

2. **API/Main.elm**: Migrate now (Phases 6b + 6c).

3. **Process stdin pipe**: Use direct pipe — the eco-io handler stores `child.stdin`
   streams server-side keyed by handle ID. When Elm writes to that handle, the handler
   writes directly to the child's stdin stream. No temp files.

4. **MVar API divergence**: The XHR variant takes `Bytes.Decode.Decoder`/
   `Bytes.Encode.Encoder` parameters while the kernel variant is type-erased. This is
   intentional and necessary — document in both modules.

5. **Centralize IO in System/IO.elm**: All IO operations currently scattered across
   `Utils/Main.elm`, `API/Main.elm`, `Builder/Http.elm`, `Control/Monad/State/Strict.elm`,
   and `System/Process.elm` move into `System/IO.elm`. Callers import `System.IO`
   (aliased as `IO`) for all IO needs.

---

## Current State

After the first fix round, 15 legacy handlers remain in `bin/index.js`:

| Legacy endpoint | Consumer | Category |
|----------------|----------|----------|
| `newEmptyMVar` | `Utils/Main.elm` | MVar |
| `readMVar` | `Utils/Main.elm` | MVar |
| `takeMVar` | `Utils/Main.elm` | MVar |
| `putMVar` | `Utils/Main.elm` | MVar |
| `binaryDecodeFileOrFail` | `Utils/Main.elm` | Binary file I/O |
| `write` (binary) | `Utils/Main.elm` | Binary file I/O |
| `replGetInputLine` | `Utils/Main.elm` | REPL compound |
| `putStateT` | `Control/Monad/State/Strict.elm` | Runtime state |
| `getStateT` | `bin/index.js` (JS only, no Elm caller) | Runtime state |
| `withCreateProcess` | `System/Process.elm` | Process |
| `waitForProcess` | `System/Process.elm` | Process |
| `getArchive` | `Builder/Http.elm` | Network |
| `httpUpload` | `Builder/Http.elm` | Network |
| `getArgs` | `API/Main.elm` | API entry point |
| `exitWithResponse` | `API/Main.elm` | API entry point |

---

## Key Design Decision: Bytes Transport via Eco.XHR

`Eco.XHR` currently only offers JSON-body helpers (`stringTask`, `jsonTask`,
`bytesTask`, `unitTask`), which all use `Http.jsonBody` for the request.

But `elm/http` natively supports binary transport:
- `Http.bytesBody : String -> Bytes -> Body` — send raw `ArrayBuffer`
- `Http.bytesResolver` — receive raw `ArrayBuffer`

This is exactly how the legacy `Impure.task` path handles binary: it uses
`Http.bytesBody "application/octet-stream" (Bytes.Encode.encode encoder)` for
sending and `Http.bytesResolver` for receiving.

**Solution**: Add bytes-aware helpers to `Eco.XHR` that use `Http.bytesBody` +
`Http.bytesResolver`. This enables both MVar and binary file I/O to migrate to the
eco-io pathway with native binary transport — no base64 needed.

---

## Phase 1: Extend `Eco.XHR` with Binary Transport

**File**: `compiler/src-xhr/Eco/XHR.elm`

### Analysis of existing helpers

The existing `bytesTask` already uses `Http.bytesResolver` to receive raw bytes.
It sends a JSON body (op + args) and receives raw bytes. This is exactly right for
`File.readBytes` and `MVar.read`/`MVar.take` (send a JSON request with path/ID,
receive raw bytes back).

What's missing is the reverse: sending raw bytes as the request body. We need this
for `File.writeBytes` and `MVar.put`.

### New function: `sendBytesTask`

```elm
{-| Send raw bytes to eco-io, with op and metadata in headers.
    Used by File.writeBytes, MVar.put.
-}
sendBytesTask : String -> List Http.Header -> Bytes -> Task Never ()
sendBytesTask op headers bytes =
    Http.task
        { method = "POST"
        , headers = Http.header "X-Eco-Op" op :: headers
        , url = "eco-io"
        , body = Http.bytesBody "application/octet-stream" bytes
        , resolver = Http.stringResolver (\_ -> Ok ())
        , timeout = Nothing
        }
```

### New function: `rawBytesRecvTask`

The existing `bytesTask` requires a `Bytes.Decode.Decoder a` to decode the response.
But `File.readBytes` needs to return raw `Bytes` — and `Bytes.Decode.bytes` requires
knowing the length in advance. Add a helper that returns the raw `Bytes` directly:

```elm
{-| Send JSON args to eco-io, receive raw bytes back without decoding.
    Used by File.readBytes.
-}
rawBytesRecvTask : String -> Encode.Value -> Task Never Bytes
rawBytesRecvTask op payload =
    Http.task
        { method = "POST"
        , headers = []
        , url = "eco-io"
        , body = Http.jsonBody (encodeRequest op payload)
        , resolver =
            Http.bytesResolver
                (\response ->
                    case response of
                        Http.GoodStatus_ _ body -> Ok body
                        _ -> crash ("eco-io request failed: " ++ op)
                )
        , timeout = Nothing
        }
```

### eco-io handler dispatch for binary requests

The `eco-io` handler in `bin/index.js` currently parses `JSON.parse(request.body)`
to get `{op, args}`. For binary-body requests (with `X-Eco-Op` header), it must
dispatch differently:

```javascript
server.post("eco-io", (request) => {
    try {
        const binaryOp = request.requestHeaders.getHeader("X-Eco-Op");
        if (binaryOp) {
            // Binary request: op in header, raw bytes in body
            handleEcoIOBinary(binaryOp, request, (status, body) => {
                request.respond(status, null, body);
            });
        } else {
            // JSON request: op in body (existing path)
            const parsed = JSON.parse(request.body);
            handleEcoIO(parsed, (status, body) => {
                request.respond(status, null, body);
            });
        }
    } catch (e) {
        console.error("eco-io handler error:", e);
        request.respond(500, null, JSON.stringify({ error: e.message }));
    }
});
```

The `handleEcoIOBinary` function is added to `eco-io-handler.js` alongside
`handleEcoIO`.

---

## Phase 2: Fix `File.readBytes` and `File.writeBytes`

**Files to change:**
- `compiler/src-xhr/Eco/File.elm` — Fix `readBytes` and `writeBytes`
- `compiler/bin/eco-io-handler.js` — Ensure `File.readBytes` returns raw bytes;
  add `File.writeBytes` to binary handler
- `compiler/src/Utils/Main.elm` — Migrate `binaryDecodeFileOrFail` and
  `binaryEncodeFile`

### File.readBytes

Use new `rawBytesRecvTask` — send JSON with the path, receive raw bytes:

```elm
readBytes : String -> Task Never Bytes
readBytes path =
    Eco.XHR.rawBytesRecvTask "File.readBytes"
        (Encode.object [ ( "path", Encode.string path ) ])
```

The eco-io handler's existing `File.readBytes` case already does
`respond(200, buffer)` where `buffer` is a raw `Buffer`. This should work — the
mock-xmlhttprequest will deliver it as `ArrayBuffer` to `Http.bytesResolver`.

### File.writeBytes

Use new `sendBytesTask` — send raw bytes, path in header:

```elm
writeBytes : String -> Bytes -> Task Never ()
writeBytes path bytes =
    Eco.XHR.sendBytesTask "File.writeBytes"
        [ Http.header "X-Eco-Path" path ]
        bytes
```

`eco-io-handler.js` binary handler:
```javascript
case "File.writeBytes": {
    const filePath = request.requestHeaders.getHeader("X-Eco-Path");
    fs.writeFileSync(filePath, Buffer.from(request.body));
    respond(200, "");
    break;
}
```

### Migrating binaryDecodeFileOrFail

In `Utils/Main.elm` (temporarily; moves to `System/IO.elm` in Phase 8):
```elm
binaryDecodeFileOrFail decoder filename =
    Eco.File.readBytes filename
        |> Task.map (\bytes ->
            case Bytes.Decode.decode decoder bytes of
                Just value -> Ok value
                Nothing -> Err ( 0, "binary decode failed" )
        )
```

### Migrating binaryEncodeFile

In `Utils/Main.elm` (temporarily; moves to `System/IO.elm` in Phase 8):
```elm
binaryEncodeFile toEncoder path value =
    Eco.File.writeBytes path (Bytes.Encode.encode (toEncoder value))
```

---

## Phase 3: Implement MVar XHR with Byte Encoder/Decoder

**Files to change:**
- `compiler/src-xhr/Eco/MVar.elm` — Replace crash stubs with working byte transport
- `compiler/bin/eco-io-handler.js` — Add full MVar semantics (new, read, take, put)
- `compiler/src/Utils/Main.elm` — Migrate from `Impure.task` to `Eco.MVar`

### XHR MVar API (intentionally differs from kernel)

The kernel variant is type-erased (values stay in JS memory):
```elm
read : MVar a -> Task Never a
take : MVar a -> Task Never a
put  : MVar a -> a -> Task Never ()
```

The XHR variant needs encoder/decoder (values cross HTTP as bytes):
```elm
read : Bytes.Decode.Decoder a -> MVar a -> Task Never a
take : Bytes.Decode.Decoder a -> MVar a -> Task Never a
put  : (a -> Bytes.Encode.Encoder) -> MVar a -> a -> Task Never ()
```

This matches the existing `Utils/Main.elm` call-site API exactly — the callers
already supply encoder/decoder.

### MVar XHR Implementation

```elm
new : Task Never (MVar a)
new =
    Eco.XHR.jsonTask "MVar.new" Encode.null Decode.int
        |> Task.map MVar

read : Bytes.Decode.Decoder a -> MVar a -> Task Never a
read decoder (MVar id) =
    Eco.XHR.bytesTask "MVar.read"
        (Encode.object [ ( "id", Encode.int id ) ])
        decoder

take : Bytes.Decode.Decoder a -> MVar a -> Task Never a
take decoder (MVar id) =
    Eco.XHR.bytesTask "MVar.take"
        (Encode.object [ ( "id", Encode.int id ) ])
        decoder

put : (a -> Bytes.Encode.Encoder) -> MVar a -> a -> Task Never ()
put encoder (MVar id) value =
    Eco.XHR.sendBytesTask "MVar.put"
        [ Http.header "X-Eco-MVar-Id" (String.fromInt id) ]
        (Bytes.Encode.encode (encoder value))
```

### eco-io-handler.js MVar Implementation

Full MVar semantics with subscriber queues, storing opaque `ArrayBuffer` values:

```javascript
const mVars = {};
let mVarNextId = 0;

// JSON handler (in handleEcoIO):
case "MVar.new": {
    mVarNextId++;
    mVars[mVarNextId] = { value: undefined, waiters: [] };
    respond(200, JSON.stringify({ value: mVarNextId }));
    break;
}

case "MVar.read": {
    const mvar = mVars[args.id];
    if (mvar.value !== undefined) {
        respond(200, mvar.value);  // raw ArrayBuffer
    } else {
        mvar.waiters.push({ action: "read", respond });
    }
    break;
}

case "MVar.take": {
    const mvar = mVars[args.id];
    if (mvar.value !== undefined) {
        const value = mvar.value;
        mvar.value = undefined;
        wakeUpMVarWaiters(mvar);
        respond(200, value);  // raw ArrayBuffer
    } else {
        mvar.waiters.push({ action: "take", respond });
    }
    break;
}

// Binary handler (in handleEcoIOBinary):
case "MVar.put": {
    const id = parseInt(request.requestHeaders.getHeader("X-Eco-MVar-Id"));
    const mvar = mVars[id];
    if (mvar.value === undefined) {
        mvar.value = request.body;  // raw ArrayBuffer
        wakeUpMVarWaiters(mvar);
        respond(200, "");
    } else {
        mvar.waiters.push({ action: "put", value: request.body, respond });
    }
    break;
}
```

The `wakeUpMVarWaiters` function implements the same wake-up semantics as the
existing `bin/index.js` MVar handlers and the kernel `_MVar_wakeUp`.

### Migrating Utils/Main.elm MVar calls

`Utils/Main.elm` defines its own `MVar` type wrapping an `Int`. Keep it, extract
the ID to call `Eco.MVar`:

```elm
readMVar decoder (MVar ref) =
    Eco.MVar.read decoder (Eco.MVar.MVar ref)

takeMVar decoder (MVar ref) =
    Eco.MVar.take decoder (Eco.MVar.MVar ref)

putMVar encoder (MVar ref) value =
    Eco.MVar.put encoder (Eco.MVar.MVar ref) value

newEmptyMVar =
    Eco.MVar.new |> Task.map (\(Eco.MVar.MVar id) -> MVar id)
```

Requires `Eco.MVar` to expose `MVar(..)` (constructors) — both variants already do.

---

## Phase 4: Runtime — Add `loadState`, Migrate `putStateT`

**Files to change:**
- `compiler/src-xhr/Eco/Runtime.elm` — Add `loadState`
- `eco-kernel-cpp/src/Eco/Runtime.elm` — Add `loadState`
- `eco-kernel-cpp/src/Eco/Kernel/Runtime.js` — Add `_Runtime_loadState`
- `compiler/bin/eco-io-handler.js` — Add `Runtime.loadState` handler
- `compiler/src/Control/Monad/State/Strict.elm` — Migrate `put` to
  `Eco.Runtime.saveState`

### loadState

XHR:
```elm
loadState : Task Never Encode.Value
loadState =
    Eco.XHR.jsonTask "Runtime.loadState" Encode.null Decode.value
```

Kernel:
```elm
loadState : Task Never Encode.Value
loadState =
    Eco.Kernel.Runtime.loadState
```

Kernel JS:
```javascript
var _Runtime_loadState = __Scheduler_binding(function(callback) {
    callback(__Scheduler_succeed(_Runtime_replState));
});
```

eco-io-handler.js:
```javascript
case "Runtime.loadState": {
    respond(200, JSON.stringify({ value: global._ecoReplState || null }));
    break;
}
```

### Migrate putStateT

In `Control/Monad/State/Strict.elm`:
```elm
put : IO.ReplState -> Task Never ()
put (IO.ReplState imports types decls) =
    Eco.Runtime.saveState
        (Encode.object
            [ ( "imports", Encode.dict identity Encode.string imports )
            , ( "types", Encode.dict identity Encode.string types )
            , ( "decls", Encode.dict identity Encode.string decls )
            ]
        )
```

### getStateT

No Elm callers exist. Remove the dead `getStateT` handler from `bin/index.js`.
`Eco.Runtime.loadState` is available for future use.

---

## Phase 5: Process — Direct Pipe for CreateProcess

**Files to change:**
- `compiler/src-xhr/Eco/Process.elm` — Add `spawnProcess` with stdio config
- `eco-kernel-cpp/src/Eco/Process.elm` — Add matching `spawnProcess`
- `eco-kernel-cpp/src/Eco/Kernel/Process.js` — Add `_Process_spawnProcess`
- `compiler/bin/eco-io-handler.js` — Add `Process.spawnProcess` handler, expand
  `Console.write` and `File.close` for stream handles
- `compiler/src/System/Process.elm` — Migrate from `Impure.task` to `Eco.Process`

### New Eco.Process API

```elm
type StdStream = Inherit | CreatePipe

spawnProcess :
    { cmd : String
    , args : List String
    , stdin : StdStream
    , stdout : StdStream
    , stderr : StdStream
    }
    -> Task Never { stdinHandle : Maybe Int, processHandle : ProcessHandle }
```

Returns `Maybe Int` for the stdin handle (not `File.Handle`) to avoid coupling
`Eco.Process` to `Eco.File`. The caller wraps it in `IO.Handle`.

### eco-io-handler.js — Direct Pipe Implementation

The handler maintains a server-side stream registry mapping handle IDs to writable
streams:

```javascript
const streamHandles = {};  // id -> { type: "childStdin", stream: child.stdin }
let streamHandleCounter = 1000;  // Start high to avoid colliding with real fds

case "Process.spawnProcess": {
    const { cmd, args: spawnArgs, stdin, stdout, stderr } = args;
    processCounter++;

    const stdioConfig = [
        stdin === "pipe" ? "pipe" : "inherit",
        stdout === "pipe" ? "pipe" : "inherit",
        stderr === "pipe" ? "pipe" : "inherit",
    ];

    const child = child_process.spawn(cmd, spawnArgs, { stdio: stdioConfig });
    processes[processCounter] = child;

    let stdinHandle = null;
    if (stdin === "pipe" && child.stdin) {
        streamHandleCounter++;
        streamHandles[streamHandleCounter] = {
            type: "childStdin",
            stream: child.stdin
        };
        stdinHandle = streamHandleCounter;
    }

    respond(200, JSON.stringify({
        value: { stdinHandle, processHandle: processCounter }
    }));
    break;
}
```

### Expanding Console.write for stream handles

Currently `Console.write` only handles fd 1 (stdout) and 2 (stderr). It needs to
also handle stream handle IDs:

```javascript
case "Console.write": {
    const { handle, content } = args;
    if (handle === 1) {
        process.stdout.write(content);
    } else if (handle === 2) {
        process.stderr.write(content);
    } else if (streamHandles[handle]) {
        streamHandles[handle].stream.write(content);
    }
    respond(200, "");
    break;
}
```

### Expanding File.close for stream handles

When Elm calls `IO.hClose` on the stdin handle, it routes through `Eco.File.close`.
The handler needs to recognize stream handles:

```javascript
case "File.close": {
    if (streamHandles[args.handle]) {
        streamHandles[args.handle].stream.end();
        delete streamHandles[args.handle];
        respond(200, "");
    } else {
        fs.closeSync(args.handle);
        respond(200, "");
    }
    break;
}
```

### Migrating System/Process.elm

```elm
withCreateProcess createProcess f =
    let
        toStream stdStream =
            case stdStream of
                Inherit -> Eco.Process.Inherit
                CreatePipe -> Eco.Process.CreatePipe
    in
    Eco.Process.spawnProcess
        { cmd = case createProcess.cmdspec of
            RawCommand cmd _ -> cmd
        , args = case createProcess.cmdspec of
            RawCommand _ args -> args
        , stdin = toStream createProcess.std_in
        , stdout = toStream createProcess.std_out
        , stderr = toStream createProcess.std_err
        }
        |> Task.andThen (\result ->
            f (Maybe.map IO.Handle result.stdinHandle)
              Nothing
              Nothing
              (ProcessHandle result.processHandle)
        )

waitForProcess (ProcessHandle ph) =
    Eco.Process.wait (Eco.Process.ProcessHandle ph)
        |> Task.map (\exitCode ->
            case exitCode of
                Eco.Process.ExitSuccess -> Exit.ExitSuccess
                Eco.Process.ExitFailure n -> Exit.ExitFailure n
        )
```

---

## Phase 6: Decompose Compound Ops

### 6a. `replGetInputLine` → `Eco.Console.write` + `Eco.Console.readLine`

In `Utils/Main.elm`:
```elm
replGetInputLine prompt =
    Eco.Console.write Eco.Console.stdout prompt
        |> Task.andThen (\_ -> Eco.Console.readLine)
        |> Task.map Just
```

### 6b. `getArgs` (API/Main.elm) → `Eco.Env.rawArgs`

In `API/Main.elm`: Replace `Impure.task "getArgs"` with `Eco.Env.rawArgs`.

### 6c. `exitWithResponse` (API/Main.elm) → `Eco.Console.write` + `Eco.Process.exit`

In `API/Main.elm`:
```elm
exitWithResponse response =
    Eco.Console.write Eco.Console.stdout (Json.Encode.encode 0 response)
        |> Task.andThen (\_ -> Eco.Process.exit Eco.Process.ExitSuccess)
```

### 6d. `putStateT` → `Eco.Runtime.saveState`

(Covered in Phase 4)

---

## Phase 7: Clean Up Legacy Handlers

Remove from `bin/index.js`:
- `newEmptyMVar`, `readMVar`, `takeMVar`, `putMVar` (after Phase 3)
- `binaryDecodeFileOrFail`, `write` (after Phase 2)
- `putStateT`, `getStateT` (after Phase 4)
- `withCreateProcess`, `waitForProcess` (after Phase 5)
- `replGetInputLine` (after Phase 6a)
- `getArgs`, `exitWithResponse` (after Phase 6b + 6c)

Also remove from `bin/index.js`:
- `mVars`, `mVarsNextCounter` state variables (moved to eco-io-handler)
- `processes`, `nextCounter` state variables (moved to eco-io-handler)
- `stateT` state variable (moved to eco-io-handler)
- `tmp` require (moved to eco-io-handler)
- `readline` interface / `rl` variable (no longer needed)

---

## Phase 8: Centralize All IO into `System/IO.elm`

Move all IO operations from their scattered locations into `System/IO.elm`, renaming
to the `guida-io-ops.csv` new names. After this, every compiler module that does IO
imports `System.IO as IO` and calls `IO.<name>`.

### CSV Name Review for IO.* Namespace

Most CSV `new_name` values work well in the `IO.*` namespace. Three need adjustment
because they're too generic in a flat namespace:

| CSV `new_name` | Problem | Proposed fix |
|---|---|---|
| `list` | `IO.list` — list what? | `listDir` |
| `lookup` | `IO.lookup` — look up what? | `lookupEnv` |
| `upload` | `IO.upload` — upload what? | `httpUpload` |

All other names read well as `IO.<name>`:

**File ops** (atomic): `IO.readString`, `IO.writeString`, `IO.readBytes`,
`IO.writeBytes`, `IO.open`, `IO.close`, `IO.size`, `IO.lock`, `IO.unlock`,
`IO.fileExists`, `IO.dirExists`, `IO.findExecutable`, `IO.listDir`,
`IO.modificationTime`, `IO.getCwd`, `IO.setCwd`, `IO.canonicalize`,
`IO.appDataDir`, `IO.createDir`, `IO.removeFile`, `IO.removeDir`

**File ops** (compound): `IO.decodeFile`, `IO.encodeFile`, `IO.withCwd`

**Console ops** (atomic): `IO.write`, `IO.readLine`, `IO.readAll`

**Console ops** (compound): `IO.writeLn`, `IO.print`, `IO.printLn`, `IO.prompt`

**Env/Process ops** (atomic): `IO.lookupEnv`, `IO.rawArgs`, `IO.exit`, `IO.spawn`,
`IO.wait`

**Env/Process ops** (compound): `IO.parseArgs`, `IO.respond`

**MVar ops** (atomic): `IO.newMVar`, `IO.newMVarWith`, `IO.readMVar`, `IO.takeMVar`,
`IO.putMVar`

**MVar ops** (compound): `IO.newChan`, `IO.readChan`, `IO.writeChan`, `IO.fork`

**Combinators**: `IO.bracket`, `IO.withLock`

**Runtime ops** (atomic): `IO.dirname`, `IO.random`, `IO.saveState`, `IO.loadState`

**Network ops** (compound, legacy): `IO.fetchArchive`, `IO.httpUpload`

**Noops**: `IO.flush`, `IO.isTerminal`, `IO.progName`, `IO.manager`,
`IO.withInterrupt`

**Combinators**: `IO.bracket`, `IO.withLock`
(`bracket_` → `IO.bracket`: pure task sequencing — acquire, act, release;
`lockWithFileLock` → `IO.withLock`: compound of `lock` + action + `unlock`)

### What Moves

Functions moving **from `Utils/Main.elm` to `System/IO.elm`**:

| Current name | New name in IO | Callers to update |
|---|---|---|
| `dirDoesFileExist` | `fileExists` | Builder/File, Terminal/Test, Builder/Stuff, Terminal/Format, Terminal/Init |
| `dirDoesDirectoryExist` | `dirExists` | Terminal/Test, Terminal/Format, Builder/Elm/Details, Builder/Elm/Outline, Builder/Deps/Solver |
| `dirFindExecutable` | `findExecutable` | Terminal/Test, Terminal/Publish, Terminal/Repl |
| `dirCreateDirectoryIfMissing` | `createDir` | Builder/File, Terminal/Test, Builder/Stuff, Terminal/Make, Terminal/Publish, Terminal/Repl, Terminal/Init, Builder/Deps/Diff, Builder/Deps/Solver |
| `dirGetCurrentDirectory` | `getCwd` | Builder/Stuff |
| `dirGetAppUserDataDirectory` | `appDataDir` | Builder/Stuff |
| `dirGetModificationTime` | `modificationTime` | Builder/File |
| `dirListDirectory` | `listDir` | Terminal/Test, Terminal/Format, Builder/Elm/Outline |
| `dirRemoveFile` | `removeFile` | Builder/File |
| `dirRemoveDirectoryRecursive` | `removeDir` | Terminal/Publish |
| `dirCanonicalizePath` | `canonicalize` | Builder/Build, Builder/Elm/Outline |
| `dirWithCurrentDirectory` | `withCwd` | Terminal/Test, Terminal/Publish |
| `envLookupEnv` | `lookupEnv` | Builder/Stuff, Builder/Deps/Website |
| `envGetProgName` | `progName` | Terminal/Terminal/Error |
| `envGetArgs` | `rawArgs` | Terminal/Terminal |
| `binaryDecodeFileOrFail` | `decodeFile` | Builder/File |
| `binaryEncodeFile` | `encodeFile` | Builder/File |
| `builderHPutBuilder` | (alias for `IO.write`) | Terminal/Test, Terminal/Repl, Builder/Reporting |
| `newEmptyMVar` | `newMVar` | Builder/Build, Builder/Elm/Details, Builder/Generate, Builder/Deps/Solver, Builder/BackgroundWriter |
| `newMVar` | `newMVarWith` | Builder/Build, Builder/Elm/Details, Builder/Generate, Builder/Reporting, Builder/BackgroundWriter |
| `readMVar` | `readMVar` | Builder/Build, Builder/Elm/Details, Builder/Generate, Builder/Deps/Solver, Builder/Reporting |
| `takeMVar` | `takeMVar` | Builder/Build, Builder/Elm/Details, Builder/Reporting, Builder/BackgroundWriter |
| `putMVar` | `putMVar` | Builder/Build, Builder/Elm/Details, Builder/Generate, Builder/Deps/Solver, Builder/Reporting, Builder/BackgroundWriter |
| `newChan` | `newChan` | Builder/Reporting |
| `readChan` | `readChan` | Builder/Reporting |
| `writeChan` | `writeChan` | Builder/Reporting |
| `forkIO` | `fork` | Builder/Build, Builder/Elm/Details, Builder/Generate, Builder/Deps/Solver, Builder/Reporting, Builder/BackgroundWriter |
| `bracket_` | `bracket` | Terminal/Publish |
| `lockWithFileLock` | `withLock` | Builder/Stuff |
| `replGetInputLine` | `prompt` | Terminal/Repl |
| `replGetInputLineWithInitial` | (removed — just calls `prompt`) | Terminal/Repl |
| `replWithInterrupt` | `withInterrupt` | Terminal/Repl |
| `nodeGetDirname` | `dirname` | Terminal/Test |
| `nodeMathRandom` | `random` | Terminal/Test |

Functions moving **from `System/Process.elm` to `System/IO.elm`**:

| Current name | New name in IO |
|---|---|
| `withCreateProcess` | `spawn` |
| `waitForProcess` | `wait` |
| `proc` | `proc` |
| Types: `CreateProcess`, `CmdSpec`, `StdStream`, `ProcessHandle` | Keep names |

Functions moving **from `Control/Monad/State/Strict.elm`**:

| Current name | New name in IO |
|---|---|
| `put` (StateT) | `saveState` |

Functions moving **from `API/Main.elm`**:

| Current name | New name in IO |
|---|---|
| `getArgs` | `parseArgs` |
| `exitWithResponse` | `respond` |

Functions moving **from `Builder/Http.elm`** (legacy, but centralized):

| Current name | New name in IO |
|---|---|
| `getArchive` | `fetchArchive` |
| `httpUpload` | `httpUpload` |

### What stays in System/IO.elm (already there)

These are already in `System/IO.elm` and get renamed:

| Current name | New name |
|---|---|
| `writeString` | `writeString` (no change) |
| `withFile` | `open` |
| `hClose` | `close` |
| `hFileSize` | `size` |
| `hFlush` | `flush` |
| `hIsTerminalDevice` | `isTerminal` |
| `hPutStr` | `write` |
| `hPutStrLn` | `writeLn` |
| `putStr` | `print` |
| `putStrLn` | `printLn` |
| `getLine` | `readLine` |
| `stdout` | `stdout` (no change) |
| `stderr` | `stderr` (no change) |

### Impact on Utils/Main.elm

After Phase 8, `Utils/Main.elm` loses ~60 IO functions and their associated types
(`MVar`, `Chan`, `ChItem`, `Stream`, `LockSharedExclusive`, `ReplSettings`,
`ReplInputT`, `ThreadId`). These all move to `System/IO.elm`.

`Utils/Main.elm` retains only pure utility functions (map operations, list helpers,
encoders/decoders, HTTP types, etc.).

### Caller Updates

Each caller file needs:
1. Remove `Utils.Main` imports for moved functions
2. Add/update `import System.IO as IO` (most already have this)
3. Change call sites: `Utils.dirDoesFileExist` → `IO.fileExists`, etc.

This is mechanical but touches ~20 files. The renaming can be done with
find-and-replace since the old names are unique.

---

## Phase 8 also requires: Update `guida-io-ops.csv`

Change three names in the CSV to match the IO namespace adjustments:

```diff
- dirListDirectory,list,1,...
+ dirListDirectory,listDir,1,...

- envLookupEnv,lookup,1,...
+ envLookupEnv,lookupEnv,1,...

- httpUpload,upload,1,...
+ httpUpload,httpUpload,1,...
```

Add two missing compound ops and update `newMVar` naming:

```diff
+ bracket_,bracket,3,no,task,1,no,compound,acquire + action + release (pure Task sequencing)
+ lockWithFileLock,withLock,3,no,task,1,yes,compound,lock + action + unlock (bracket over file lock)
+ newMVar,newMVarWith,2,no,task,...,no,compound,newMVar + putMVar (create MVar with initial value)

- newEmptyMVar,new,0,...
+ newEmptyMVar,newMVar,0,...
```

Note: `replRunInputT` stays in `Terminal/Repl.elm`, not moved to `System/IO.elm`.

---

## Final State

### Remaining legacy handlers (permanent, 2 total):

| Handler | Reason |
|---------|--------|
| `getArchive` | Network — intentionally bundled (HTTP GET + ZIP decompress + SHA1) |
| `httpUpload` | Network — intentionally bundled (multipart encode + HTTP POST) |

### Everything else migrated to eco-io:

| Old handler | New `IO.*` path |
|-------------|---------------|
| `newEmptyMVar` | `IO.newMVar` / `IO.newMVarWith` |
| `readMVar` | `IO.readMVar` |
| `takeMVar` | `IO.takeMVar` |
| `putMVar` | `IO.putMVar` |
| `binaryDecodeFileOrFail` | `IO.decodeFile` |
| `write` (binary) | `IO.encodeFile` |
| `putStateT` | `IO.saveState` |
| `getStateT` | Dead — removed. `IO.loadState` available |
| `withCreateProcess` | `IO.spawn` |
| `waitForProcess` | `IO.wait` |
| `replGetInputLine` | `IO.prompt` |
| `getArgs` | `IO.parseArgs` |
| `exitWithResponse` | `IO.respond` |

---

## Implementation Order

1. **Phase 1** — Extend `Eco.XHR` with `sendBytesTask` and `rawBytesRecvTask`
2. **Phase 2** — Fix `File.readBytes`/`writeBytes`, migrate
   `binaryDecodeFileOrFail`/`binaryEncodeFile`
3. **Phase 3** — Implement MVar XHR with encoder/decoder, migrate MVar ops
4. **Phase 4** — Add `Runtime.loadState`, migrate `putStateT`
5. **Phase 5** — Expand `Eco.Process` with `spawnProcess` (direct pipe), migrate
   `System/Process.elm`
6. **Phase 6** — Decompose compound ops (`replGetInputLine`, `getArgs`,
   `exitWithResponse`)
7. **Phase 7** — Remove all migrated legacy handlers from `bin/index.js`
8. **Phase 8** — Centralize all IO into `System/IO.elm`, rename to CSV names,
   update all callers, update CSV for the 3 adjusted names

---

## Verification

After each phase:
```bash
cd compiler && npx elm-test-rs --fuzz 1   # All 7865 tests pass
npm run build:bin                          # elm make succeeds
node bin/index.js make --help              # Smoke test
```

After Phase 5 (process), additionally test:
```bash
echo ':exit' | node bin/index.js repl      # REPL spawn test
```

---

## Open Questions

1. **Stream handle ID range**: Using `streamHandleCounter` starting at 1000 to avoid
   colliding with real file descriptors. Is this sufficient, or should we use a
   separate namespace (e.g. negative IDs, or a prefix convention)? The Elm side
   treats handles as opaque `Int`s, so any integer works.

2. **Eco.MVar API divergence documentation**: The XHR variant has
   `read : Decoder a -> MVar a -> ...` while the kernel has `read : MVar a -> ...`.
   Both modules should document this and explain why.

3. **MVar waiter semantics**: The wakeUp function needs to handle interleaved
   read/take/put waiters correctly. Port the exact semantics from the existing
   `bin/index.js` MVar handlers and kernel `_MVar_wakeUp`.
