---
status: done
updated: 2026-10-27
---

# Plan: `eco/system` API refactor for 0.2.0

Status: **implemented** (2026-10-19, §10, §11; all gates green). The API as stubs (every function `Debug.todo`) is in the `ecosyskernel` review repository (github.com/rupertlssmith/ecosyskernel), built with stock elm 0.19.1. Decided: D1–D20; no open questions. Review round (2026-10-19) folded in: A1, B1–B9, C1–C6. Naming review: §6. This collects review feedback
on the draft API (`plans/eco-system-library.md`, published at
<https://elm-doc-preview.netlify.app/?repo=rupertlssmith%2Fecosyskernel&version=master>) and the
decisions taken so far. The 0.2.0 release is an alpha, so later releases can still reshape it.

Sources:
- Slack thread with Martin Stewart (feedback) and the author (responses).
- Follow-up design discussion, which checked each point against the source in `system-kernel-cpp/src/`.

---

## 1. Current module tree (19 exposed)

```
System
Stream, Stream.Log
System.File, System.File.Path, System.File.FileHandle
System.Process
System.Terminal
Http.Server, Http.Server.Response, Http.Dom, Http.Stream
Socket, Socket.Address, Socket.Tcp, Socket.Unix, Socket.Udp, Socket.Tls
WebSocket
```

Internal modules: `Stream.Internal`, `System.File.Internal`, `Socket.Internal`,
`Http.Server.Internal`, `WebSocket.Internal`, `WebSocket.Internal.Handshake`.

## 2. Feedback received

### From Martin Stewart (Slack)

| # | Suggestion | Response |
|---|---|---|
| F1 | Merge `Http.Server` and `Http.Server.Response`: you nearly always import both, and both are small. | Accepted in Slack. See D2. |
| F2 | `bodyAsString` and `bodyFromJson` (`Http.Server`) are named inconsistently. | Accepted in Slack: rename `bodyFromJson` → `bodyAsJson`, D7. |
| F3 | Flatten `System.File.FileHandle` → `System.FileHandle` and `System.File.Path` → `System.FilePath`: the nesting adds length and makes autocomplete harder. The author suggested folding both into `System.File`, and Martin agreed. | Path: top-level `Path`, D4. Handles: **kept separate**, D1. |
| F4 | Remove `Stream.Log` and add `logBytes`, `logString`, `logLine` to `Stream`. | Accepted in Slack, named `log`, `logString`, `logLine`, stream last like `write` (D8). `Stream.Log` exposes only `bytes`, `string` and `line`; its `ignoreErrors` is a private helper and moves into `Stream` with them, unexposed. |
| F5 | `System.Terminal.Size` doc: "Size of a terminal **viewport**", so it is not read as the size of the content. | Accepted in Slack. |
| F6 | `System.Program` should be a custom type, not a type alias. | A custom type isn't possible (`main` must be a `Platform.Program`), and the alias exists because `Environment` can't be JSON flags. Decided: programs are plain `Platform.Program Environment model msg`, with the compiler supplying `Environment` (D13), built with `Platform.worker` or `System.simpleProgram` (D14). |
| F7 | Put the program's start time in `Environment`, so apps don't need a Loading state or a `millisToPosix 0` placeholder. | Decided: D15. |
| F8 | `getPlatform` and `getCpuArchitecture` repeat what `Environment` already provides, and neither can change while the program runs. | Decided: D15. |
| F9 | `endSimpleProgram` and `exit` overlap. Keep one, or have the simple program exit by itself when its task finishes. | Decided: D13, D14. Note: both are already `Cmd`s. `endSimpleProgram : Task Never a -> Cmd msg` runs a task and then exits; `exit : Cmd msg` exits immediately. |
| F10 | `defineProgram` → `program`, `defineSimpleProgram` → `simpleProgram`. | Decided: D13, D14. |
| F11 | Once `Eco.Console` is internal, there is no way to read from the terminal. | Already possible: `Environment.stdin` is a `Stream.Readable Bytes`. The docs should make this obvious (D16). |

### Items from the Slack thread built since

Unix domain sockets, TCP and UDP (`Socket.*`, plus `Socket.Tls`), WebSockets (`WebSocket`), and
HTML response bodies built straight from elm/html values (`Http.Server.Response.setBodyAsHtml` and
`Http.Dom`).

## 3. Decisions

| # | Decision |
|---|---|
| D1 | **File handles stay in their own module** and are not merged into the file system module. Merging would clash on `metadata`, `changeAccess`, `changeOwner` and `changeTimes`, which exist with a `Path` argument in one module and a handle in the other. It would also put generic names (`read`, `write`, `truncate`, `close`) next to `readFile`, `writeFile` and `truncateFile`. Only the file system module uses handles; sockets don't (§5.2). |
| D2 | **Merge `Http.Server.Response` into `Http.Server`** (F1). `Http.Stream` doesn't block this: it is the HTTP *client*, imports only elm/http, and never uses the server's `Response`. |
| D3 | **`Http.Stream` stays in `eco/system`, as the client next to `Http.Server`.** Its JS kernel is Node-only (`node:http`/`https`, `Buffer`, `process.env`), like every JS kernel in the package. Its docs should say it doesn't run in the browser. If browser support is ever wanted, it should become its own package (with `Stream`), based on `fetch`, so browser apps don't depend on `eco/system`. See §5.1. |
| D4 | **Drop the `System.` prefix** (2026-10-19). `System` itself stays, as the program entry point (programs, `Environment`, exit, signals). Every other module is named after its domain, as `Socket` already is. Nesting everything under `System.` instead would make the names longer (`System.Socket.Tcp`), against F3. The new names: **`System.File` → `FileSystem`**, **`System.Process` → `ChildProcess`**, **`System.Terminal` → `Terminal`**, **`System.File.Path` → `Path`** (top-level), and the handle module moves to **`FileSystem.Handle`**. The plain names `Process` (elm/core) and `File` (elm/file) aren't possible, because Elm forbids two packages exposing the same module name in one project; `FileSystem` and `ChildProcess` are gren-node's names. `Path` is top-level, not folded into `FileSystem`, because `System` (`applicationPath`), `Socket.Address` and `Socket.Unix` all use it, and socket code shouldn't need to import the file system to get a path type. |
| D5 | **The DOM view module stays exposed, as `Html.Dom`** (2026-10-19; was P6 / Q2). User code can use it, e.g. to inspect `Html` values or render them to strings outside the server. It moves out of `Http` because it is a view of `Html`/`Svg` (`VirtualDom`) values and has nothing to do with HTTP. |
| D6 | **Handle `read`/`write` stay as they are** (2026-10-19). Handles have no file position: `read` reads the whole file from offset 0, and `write` writes at offset 0, so two `write` calls overwrite each other rather than appending. Both functions already say so in their docs, and staying close to gren-node has value. The only change is one sentence in the `FileSystem.Handle` module doc: handles have no file position, every read and write names its offset, and sequential IO is what `readFileStream`/`writeFileStream` are for. |
| D7 | **`Http.Server.bodyFromJson` → `bodyAsJson`** (2026-10-19, F2). The signature stays `Json.Decode.Decoder a -> Request -> Result Json.Decode.Error a`. "As" matches `bodyAsString` and the response side (`setBodyAsString`, `setBodyAsBytes`, `setBodyAsHtml`); "From" read backwards, since the function decodes the body *as* JSON. Not part of the decision, but noted: it decodes a body that isn't valid UTF-8 as `""`, so the caller gets a misleading JSON error rather than an encoding error. |
| D8 | **Naming renames** (2026-10-19; §6 rules N1–N5, rows N-a…N-g, N-i, N-k, N-l, N-o…N-u):<ul><li>`Http.Server`: `createServerWith` → **`listen : ListenOptions -> Task Error Server`**; `createServer` → **`listenOnHost : String -> Int -> Task Error Server`**, which resolves the host name as today (`getaddrinfo` natively, Node in JS; `""` listens on all interfaces), mirroring `Socket.Tcp.connectToHost`; `ServerOptions` → `ListenOptions`; `defaultServerOptions` → `defaultListenOptions`; `closeServer` → `close`; `closeServerWithin` → `closeWithin`; `serverPort : Server -> Int` → **`endpoint : Server -> InetEndpoint`** (`port` is reserved; an HTTP server is never on a Unix socket, so `InetEndpoint` rather than `Endpoint`. The kernels must now also return the bound address, not just the port); `ServerError(..)` → an opaque `Error` with `errorCode`, `errorToString` and `errorIsAddressInUse`, `errorIsAddressNotAvailable`, `errorIsHostNotFound`, `errorIsPermissionDenied`, `errorIsCertificateInvalid` (the failures of `listen`/`listenOnHost`, named as in `Socket`), like `FileSystem.Error` and `Socket.Error`; `requestInfo` → `requestToString`.</li><li>`Path`: `parentPath` → `parent`.</li><li>`WebSocket`: `upgradeRequest` → `receiveUpgrade`; `closed` → `awaitClose`; `handshakeStatus` → `errorHandshakeStatus` (it reads a `Socket.Error`, like `errorCode`).</li><li>`Stream`: `readBytesAsString` → `readString`, `writeStringAsBytes` → `writeString`, `writeLineAsBytes` → `writeLine`. The F4 log functions take the stream **last**, like `write`: `log : Bytes -> Writable Bytes -> Task x ()`, `logString : String -> Writable Bytes -> Task x ()`, `logLine : String -> Writable Bytes -> Task x ()` (`Stream.Log` took it first).</li><li>`ChildProcess`: the `StreamIO` fields `input`, `output`, `error` → `stdin`, `stdout`, `stderr`, matching `Environment`.</li><li>`Html.Dom`: `fromNode` → `fromHtml`; `render : Node -> String` → `toString : Node -> String`; `toString : VirtualDom.Node msg -> String` → `htmlToString` (the fast path, the same as `toString << fromHtml`). `fromAttribute` and `attributes` are unchanged.</li><li>`System`: `getEnvironmentVariables` → `environmentVariables`. `Terminal`: `getConfiguration` → `configuration`, `setStdInRawMode` → `setStdinRawMode`. `FileSystem`: `tmpDirectory` → `tempDirectory`.</li></ul> |
| D9 | **`Stream.Transformation` module** (2026-10-19, N-j; layout revised by C1). The ways to *build* transformations leave `Stream`; *using* them stays:<ul><li>**`Stream` keeps** the `Transformation` type (an alias over `Stream.Internal`, as for `Readable`/`Writable`), `pipeThrough`, `awaitAndPipeThrough` and `pipeTo`, so all piping is in one module. There's no import cycle: `Stream.Transformation` imports `Stream`, never the reverse. A type `Stream.Transformation` and a module `Stream.Transformation` coexist; this was checked with stock elm 0.19.1.</li><li>**`Stream.Transformation` gets** `identityTransformation` → `identity`, `identityTransformationWithOptions` → `identityWith`, `nullTransformation` → `null`, `customTransformation` → `custom`, `customTransformationWithOptions` → `customWith` (rule N4: one `…With` suffix everywhere), `CustomTransformationAction(..)` → `CustomAction(..)` (constructors unchanged), and `readable`/`writable` (a transformation's two sides).</li><li>Codecs, named like zlib and Node's `zlib` module: `textEncoder`, `textDecoder` (unchanged, the WHATWG names); `gzipCompression` → `gzip`, `gzipDecompression` → `gunzip`, `deflateCompression` → `deflate`, `deflateDecompression` → `inflate`, `deflateRawCompression` → `deflateRaw`, `deflateRawDecompression` → `inflateRaw`.</li></ul> |
| D10 | **`Terminal.setProcessTitle` → `Terminal.setTitle`** (2026-10-19; was N-m / Q7). It sets the **terminal window title**: it writes the OSC 2 sequence `ESC ] 2 ; <title> BEL` to stdout when stdout is a terminal, and otherwise does nothing (the same test as raw mode). It never writes the sequence into a redirected file or pipe. Why:<ul><li>POSIX has no process title. What exists is platform-specific: Linux's 15-byte `comm` (`prctl(PR_SET_NAME)`/`pthread_setname_np`), FreeBSD's `setproctitle`, and nothing on macOS.</li><li>The current function does neither job well, and its doc is wrong. It says the title "will usually display … in the title bar of your terminal emulator", but neither kernel writes an escape sequence. Native only changes the main thread's `comm` on Linux (a no-op on macOS). JS sets Node's `process.title`, which also rewrites the command line shown by `ps`, so the backends already differ.</li><li>A terminal title is portable (xterm-compatible terminals on Linux and macOS, Windows Terminal) and belongs in `Terminal`.</li></ul>The process-name behaviour is dropped. If it's wanted later, it would be a Linux-only `System.setProcessName`. Implementation note: terminals don't restore the title at exit. If restoring is wanted, xterm's title stack (`CSI 22;2 t` to push, `CSI 23;2 t` to pop, pushed on first use) can be added, in the same place as the raw-mode restore-at-exit. |
| D11 | **Handle type names** (was P3): in `FileSystem.Handle`, `FileHandle r w` → `Handle r w`, `ReadableFileHandle` → `ReadableHandle`, `WriteableFileHandle` → `WriteableHandle`, `ReadWriteableFileHandle` → `ReadWriteableHandle`. |
| D12 | **Durable write and exclusive create in `FileSystem`** (was P5; one shape for both, C3), so typical programs never need the handle module. Handles are then only needed for random access on one open file.<ul><li>`writeFileWith : WriteOptions -> Bytes -> Path -> Task Error Path` and `writeFileStreamWith : WriteOptions -> WriteFileStreamMode -> Path -> Task Error (Writable Bytes)`, with `WriteOptions = { createNew : Bool, sync : Bool }` and `defaultWriteOptions` (both `False`).</li><li>`createNew`: open with `O_EXCL`; fails with `errorIsFileExists` if the path exists.</li><li>`sync`: fsync before `writeFileWith` succeeds, or when the stream is closed for `writeFileStreamWith`.</li><li>`writeFile` / `writeFileStream` stay as the default-options forms (rule N4). `WriteFileStreamMode` is unchanged; no `CreateNew` mode.</li></ul> |
| D13 | **Programs are plain `Platform.Program Environment model msg`; the compiler supplies `Environment` as the flags** (was P7a, F6). Today `System.Program` must be an alias of `Platform.Program () (Model model) (Msg model msg)`: flags must be JSON-decodable (the compiler's `BadFlags` check, `compiler/src/Compiler/LocalOpt/{Typed,Erased}/Module.elm`), `Environment` holds streams, and so `System` gathers it with a task after startup and wraps the user's model in `Uninitialized`/`Initialized`. Chosen instead: Eco compiler and runtime support so that a program whose flags type is `System.Environment` gets the environment built by the runtime before `init` runs. Consequences:<ul><li>Compiler: accept `System.Environment` (and only it, from `eco/system`) as a flags type in the `BadFlags` check, and make the generated program entry construct it. Native and JS backends both.</li><li>Runtime and kernels: the environment construction now in `initializeEnvironment` moves to program start.</li><li>Stock `elm make` (and tools that run it on applications, such as elm-test) rejects such a `main`. That is acceptable: stock elm already can't build `eco/system` programs, because of the kernel code. Package docs are unaffected: a package has no `main`.</li><li>`System.Program`, `ProgramConfiguration`, `defineProgram` and the internal `Model`/`Msg` wrappers are removed (D14).</li></ul> |
| D14 | **Program builders** (was P7b, P7c, P7d; F9, F10):<ul><li>Full programs use **`Platform.worker`** directly, with `init : Environment -> ( model, Cmd msg )`. No `System.program` builder.</li><li>**`System.simpleProgram : (Environment -> Task Never a) -> Platform.Program Environment () ()`** (the exact model/msg types are settled in implementation). The program ends once the task and any IO it started have finished. `defineSimpleProgram`, `endSimpleProgram` and `SimpleProgram` are removed.</li><li>`exit`, `exitWithCode` and `setExitCode` stay, for programs that end early. A simple program exits with a code by ending its task with `setExitCode`.</li><li>No `System.Program` alias for `Platform.Program Environment model msg` (C6): user code can add its own.</li></ul> |
| D15 | **`Environment`** (was P8; F7, F8): add `startTime : Time.Posix`, read once at startup. Remove `getPlatform` and `getCpuArchitecture`; read `env.platform` and `env.cpuArchitecture`. |
| D16 | **Docs and examples** (was P9; F5, F11):<ul><li>`Terminal.Size`: "Size of a terminal viewport. Handy to know for drawing a text-based UI."</li><li>A small program in **`examples/src/`** that reads stdin line by line with `Stream.readLine` (D18), e.g. numbers each line like `nl`. `Cat.elm` already pipes stdin through unchanged; this one shows line-oriented reading. `System`'s `Environment` doc can link to it.</li></ul> |
| D17 | **`WebSocket.streamedReadable` → `readableStreamed`** (was N-h): rule N3, variants add a suffix, matching `connectStreamed` and `acceptStreamed`. |
| D18 | **`Stream.readLine : Readable Bytes -> Task Error String`** (2026-10-19; a gap found in the review, needed by D16). It reads up to and including the next `\n`, decodes it as UTF-8, and returns it without the terminator (and without a preceding `\r`). An unterminated last line is returned as is; after that it fails with `Closed`. Invalid UTF-8 cancels the stream, as `readString` does. Implementation: bytes read past the newline must be kept for the next read. That is mutable state, so it lives **in the kernel's stream table** (C++ StreamTable and its JS port), not in Elm. Any later `read`/`readString`/`readLine` on the same stream returns those buffered bytes first. Lines longer than the stream's chunk size must work. |
| D19 | **Naming rules revised** (2026-10-19, B6, B9): N2 is loosened. A name carries its type's noun only when it would otherwise mean the module's main type. So the merged `Http.Server` keeps `send`, `setStatus`, `setHeader`, `setBody…` and `bodyAsString`/`bodyAsJson` without a noun, but `requestToString` keeps it (plain `toString` would mean `Server`). `Socket.Tls` keeps its role-named `ClientOptions`/`ServerOptions` as an exception to N4, because `Tls.connect`/`listen` already take `Socket.Tcp`'s `ConnectOptions`/`ListenOptions` next to them. |
| D20 | **Two error styles, on purpose** (2026-10-19, C5). Errors that are a small closed set expose their constructors for pattern matching: `Stream.Error(..)` = `Closed \| Cancelled String \| Locked`. Errors carrying OS, resolver or TLS codes are opaque, with `errorCode`, `errorToString` and `errorIs…` predicates: `FileSystem.Error`, `Socket.Error`, `Http.Server.Error`. New error types pick one of these two styles. |

## 4. Proposals

All proposals P3–P9 were decided on 2026-10-19; see D11–D16. P1/P2 became D4, P4 became D6, P6 became D5.

## 5. Findings behind the decisions

### 5.1 `Http.Stream` and the browser

A browser version would use `fetch` with `ReadableStream`. Downloads (`response.body`) map
directly, and `AbortController` covers both the headers-only timeout and `Process.kill`. The gaps:
- Streamed uploads need `duplex: 'half'`, which only Chromium supports, and only over HTTP/2 or HTTP/3.
- The browser follows redirects itself, so the curl-style redirect rules can't be reproduced.
- CORS and forbidden headers apply.
- `Stream`'s compression uses `node:zlib`; the browser equivalent is `CompressionStream`.

### 5.2 What file handles give over the path API

The path API already covers whole-file IO and sequential and ranged stream IO
(`readFileStream From/Between`, `writeFileStream ReplaceFrom/Append`). Before D12, only handles provided:
1. `sync`/`syncData` (fsync/fdatasync). D12 adds sync-on-finish to `FileSystem` writes;
2. exclusive create (`ExpectNotExisting`, `"wx"`). D12 adds this to `FileSystem` too;
3. random reads and writes on one open file (`readFromOffset`/`writeFromOffset`, i.e. pread/pwrite);
4. operations on the open file even after its path is renamed or replaced (`fstat` and friends).

A `FileHandle` is the OS fd. Sockets do have fds, but the API never exposes them: a
`Socket.Connection` is an id plus a readable stream, a writable stream and the endpoints. What
files, sockets, processes, WebSockets and HTTP bodies have in common is `Stream`, so no general
handle module is needed.

## 6. Naming review (2026-10-19)

All exposed names were audited against the author's convention, extended into rules N1–N5 for
modules with several types and for operations with variants.

### Rules

- **N1. Leave out the module's noun.** In a module named after a noun, functions on that noun's
  main type have short names that don't repeat it: `List.map`, `Thing.build`, `Server.close`.
  Conversions are `toString`/`fromString`.
- **N2. Other types in the module carry their noun when the name would otherwise mean the
  module's main type** (D19). Actions put it after the verb (`closeListener`, `cancelReadable`).
  Accessors and conversions put it first (`listenerEndpoint`, `upgradeTarget`, `requestToString`).
  Where nothing is ambiguous, no noun is needed (`Http.Server.setStatus`, `bodyAsString`). When a module collects many such prefixes for one type, that
  type is a candidate for its own module. Watch this as operations are added: it is how names grow long.
- **N3. Variants add a suffix to the base name**, never a prefix: `connect` / `connectStreamed`,
  `accept` / `acceptStreamed`.
- **N4. Required configuration goes in the base function's argument.** `connect`, `listen`,
  `bind`, `run` and `spawn` all take an options record, built from `defaultXOptions`, with
  `XOptions` named after the operation (exception: `Socket.Tls`, D19). Optional settings use a
  `…With` variant, the only suffix for this (`writeFileWith`, `identityWith`); the plain name is the
  default-options form. A convenience form that resolves a host name is `…ToHost` / `…OnHost`.
- **N5. Tasks that read a value have no `get` prefix**, like `Time.now`, `FileSystem.homeDirectory`
  and `FileSystem.metadata`. One spelling per abbreviation and per concept: `stdin`/`stdout`/`stderr`
  everywhere (also `ChildProcess.StreamIO`), `temp`.

### Most of the API already follows these rules

`Socket.*`, `Socket.Address`, `ChildProcess`, `FileSystem.Handle`, the file system names (once
`System.File` is renamed `FileSystem`, `readFile` / `listDirectory` stop repeating the module noun),
and nearly all of `WebSocket` and `Stream`.

### Deviations and proposed fixes

| # | Module | Now | Proposed | Rule | Status |
|---|---|---|---|---|---|
| N-a | `Http.Server` | `createServer`, `createServerWith`, `closeServer`, `closeServerWithin`, `ServerOptions`, `defaultServerOptions`, `ServerError` | `listen : ListenOptions -> …`, `listenOnHost : String -> Int -> …`, `close`, `closeWithin`, `ListenOptions`, `defaultListenOptions`, `Error`. Starting a server is `listen`, as in `Socket.Tcp`/`Unix`/`Tls`. The host-name form is kept (A1). | N1, N4 | **Accepted** (D8) |
| N-b | `Http.Server` | `serverPort : Server -> Int` | `endpoint : Server -> InetEndpoint` (`port` is reserved; matches `Socket.listenerEndpoint`) | N1 | **Accepted** (D8) |
| N-c | `Http.Server` | `ServerError(..)`, a constructor exposing `{ code, message }` | An opaque `Error` with `errorCode`, `errorToString`, `errorIs…`, as `FileSystem.Error` and `Socket.Error` already have. | consistency | **Accepted** (D8) |
| N-d | `Http.Server` | `requestInfo : Request -> String` | `requestToString` (cf. `methodToString`) | N2 | **Accepted** (D8) |
| N-e | `Path` | `parentPath` | `parent` | N1 | **Accepted** (D8) |
| N-f | `WebSocket` | `upgradeRequest : Socket.Connection -> Task Socket.Error Upgrade` | It's an action, but it sits in the `upgrade…` family of accessors (`upgradeTarget`, `upgradeHeaders`, …). It also has the same name as `Http.Server.upgradeRequest`, which does something else (answers a request with an upgrade). Proposed: `receiveUpgrade`. | N2 | **Accepted** (D8) |
| N-g | `WebSocket` | `closed : WebSocket mode -> Task x CloseInfo` | Reads like a `Bool` check. Proposed: `awaitClose` (cf. `Stream.awaitAndPipeThrough`). | clarity | **Accepted** (D8) |
| N-h | `WebSocket` | `streamedReadable` | `readableStreamed` | N3 | **Accepted** (D17) |
| N-i | `Stream` | `readBytesAsString`, `writeStringAsBytes`, `writeLineAsBytes` | `readString`, `writeString`, `writeLine`: the `Readable Bytes` / `Writable Bytes` types already say "bytes". Then F4's log functions become `log`, `logString`, `logLine`, the same shape as `write` / `writeString` / `writeLine`. | consistency | **Accepted** (D8) |
| N-j | `Stream` | `identityTransformation`, `nullTransformation`, `customTransformation[WithOptions]`, `gzipCompression`, … | `Transformation` is the N2 case: the builders and codecs move to `Stream.Transformation` (`identity`, `custom`, `gzip`, …); the type and piping stay in `Stream`. | N2 | **Accepted: split out** (D9) |
| N-k | `System`, `Terminal` | `getEnvironmentVariables`, `Terminal.getConfiguration` (`getPlatform` / `getCpuArchitecture` are removed, D15) | `environmentVariables`, `configuration` | N5 | **Accepted** (D8) |
| N-l | `Terminal` | `setStdInRawMode`; `FileSystem.makeTempDirectory` next to `tmpDirectory` | `setStdinRawMode`; `tmpDirectory` → `tempDirectory` | N5 | **Accepted** (D8) |
| N-m | `Terminal` | `setProcessTitle` | `setTitle`, as a terminal window title (D10). | placement | **Decided** (D10) |
| N-n | `Http.Stream` | `streamBody`, `expectStream`, `streamResolver` | **Keep.** They mirror elm/http's `stringBody` / `expectString` / `stringResolver`, and matching the package it extends matters more than N1. | exception | Exception, kept |
| N-o | `Stream` (from `Stream.Log`) | `line : Writable Bytes -> String -> …` (stream first) | `logLine : String -> Writable Bytes -> …`, stream last like `write` | consistency | **Accepted** (D8) |
| N-p | `Stream.Transformation` | `…WithOptions` | `…With` (`identityWith`, `customWith`), as `writeFileWith` | N4 | **Accepted** (D9) |
| N-q | `ChildProcess` | `StreamIO { input, output, error }` | `{ stdin, stdout, stderr }` | N5 | **Accepted** (D8) |
| N-r | `Html.Dom` | `fromNode`, `render : Node -> String`, `toString : Html -> String` | `fromHtml`, `toString : Node -> String`, `htmlToString` | N1 | **Accepted** (D8) |
| N-s | `WebSocket` | `handshakeStatus : Socket.Error -> Maybe Int` | `errorHandshakeStatus` | N2 | **Accepted** (D8) |
| N-t | `Http.Server` | `send`, `setStatus`, `setBody…`, `bodyAsString` (no noun after the merge) | Keep: unambiguous under the loosened N2 | N2 | **Kept** (D19) |
| N-u | `Socket.Tls` | `ClientOptions`, `ServerOptions` (role names) | Keep: `Tcp`'s `ConnectOptions`/`ListenOptions` sit next to them | N4 | **Exception** (D19) |

Minor, unchanged unless wanted: `ChildProcess.Connection` (how a child's stdio is connected)
shares a name with `Socket.Connection`; `System.Platform` (the OS type) has the same name as
elm/core's `Platform` module, which D13 programs import. Possible new names: `ChildProcess.Relation`,
`System.OperatingSystem`.

## 7. Proposed module structure (17 exposed)

```
System                     Environment (+ startTime), simpleProgram, exit, signals (D13–D15)
Stream                     Readable, Writable, Transformation type; read/readString/readLine, write/writeString/writeLine,
                           pipeThrough/awaitAndPipeThrough/pipeTo, log/logString/logLine (Stream.Log removed; D8, D9, D18)
Stream.Transformation      identity/null/custom (+ …With), readable/writable, text and zlib codecs (D9)
FileSystem                 was System.File (D4; + durable write, exclusive create: D12)
FileSystem.Handle          was System.File.FileHandle (D1, D4, D6, D11)
Path                       was System.File.Path (D4)
ChildProcess               was System.Process (D4)
Terminal                   was System.Terminal (D4; setTitle D10)
Socket, Socket.Address, Socket.Tcp, Socket.Unix, Socket.Udp, Socket.Tls   (unchanged)
WebSocket                  (unchanged)
Http.Server                merged with Http.Server.Response (D2); listen/listenOnHost, renames D7, D8
Http.Stream                HTTP client for system programs (D3)
Html.Dom                   was Http.Dom (D5); fromHtml, toString, htmlToString (D8)
```

Internal modules after the change: `Stream.Internal`, `FileSystem.Internal` (still shared by
`FileSystem` and `FileSystem.Handle`), `Socket.Internal`, `Http.Server.Internal`,
`WebSocket.Internal`, `WebSocket.Internal.Handshake`.

## 8. Open questions

None. Every item is decided (D1–D20).

## 9. Impact checklist (for implementation)

- Effect managers are keyed by **bare module name** (`eco-system-library.md` D11). Renaming
  `System.File`, `System.Process` and `System.Terminal`, and touching `Http.Server`, means
  changing the name strings in the C++ managers (`src/eco-system/{FileSystem,ChildProcess,Terminal,HttpServer}/*Manager.{hpp,cpp}`)
  and in `compiler/tests/TestLogic/Generate/EcoSystemManagerRegistrationTest.elm`. Check that the
  JS effect-module bodies need no change.
- `elm.json` `exposed-modules`; `README.md` module list; `docs.json` (regenerate with
  `pnpm run docs:check`; note that `pnpm docs` runs pnpm's own command).
- Tests: `test/eco-system/src/*` (including `PackageLinksTest`, `FileHandleTest`) and
  `test/stress-elm/src/EcoSystem*`, plus any examples or benchmarks that import `System.*`.
- Kernel homes (`Eco.Kernel.FileSystem`, `ChildProcess`, `Terminal`, …) already use the new
  names, so the kernels don't change.
- Update `plans/eco-system-library.md` D5 (module names) to point here.
- D13 is the one change outside `eco/system`: the compiler's `BadFlags` check and program entry (both backends), with compiler tests. Every program in `examples/src/`, `test/eco-system`, `test/stress-elm` and the README changes its `main`. Do D13/D14 first or last, as their own step, not mixed with the renames.
- `examples/src/`: update all ten programs for D4/D8/D9/D14, and add the stdin line example (D16).
- Kernel work beyond renames: `Stream.readLine` (D18) needs a per-stream pending-bytes buffer in the C++ StreamTable and its JS port, with tests for lines longer than a chunk, CRLF, a final unterminated line, and mixing `read` with `readLine`. `Http.Server.listen`/`listenOnHost` must return the bound address for `endpoint : Server -> InetEndpoint` (D8). `Terminal.setTitle` (D10) is new kernel code on both backends. `writeFileWith`/`writeFileStreamWith` (D12) need `O_EXCL` and fsync on both backends.
- D8/D9 renames touch every caller of `Stream` (`writeLineAsBytes`, `Stream.Log.line`, the codecs) and of `Http.Server` in `test/eco-system`, `test/stress-elm`, the README example and the JS kernels' Elm-facing docs. `make-docs-package.js` needs no change. Do the renames in one pass per module, and check `docs.json` with `pnpm run docs:check`.

## 10. Implementation (lowered, 2026-10-19)

The review repository (`ecosyskernel`) is the **normative API**: every exposed name, type and doc
comment in `system-kernel-cpp/src` must end up equal to it, except that implementations replace
the `Debug.todo` bodies. Work in the phase order below. Each phase lists its files, its steps and
how it is checked. Gates are run once, at the end (§10.8), per the project rule that the test
suites run once with output to `/tmp/test_output.txt`.

### 10.1 Design details settled while lowering

- **D13 mechanism (flags).** The runtime is unchanged and PORT_007 still holds. The flags decoder
  stays compiler-synthesized, and `initWorker` decodes the host JSON (`null` when absent)
  exactly as today. The new part is in the decoder *builder*. When the entry's annotation, before
  deep dealiasing, is `Platform.Program F model msg` and `F` is (an alias chain ending in)
  `eco/system`'s `System.Environment`, the decoder is a reference to the **unexposed** global
  `System.environmentDecoder` instead of `Port.toFlagsDecoder F`, and the `BadFlags` payload check
  is skipped. Three sites:
  1. `Compiler/Monomorphize/EntryPrep.elm` (`insertFlagsDecoderNode`), for native;
  2. `Compiler/LocalOpt/Typed/Module.elm` (`addDefHelp`, the `TOpt.Dynamic` main);
  3. `Compiler/LocalOpt/Erased/Module.elm` (the `Opt.Dynamic` main), for JS.

  The test is one shared helper, **`Compiler/Elm/EcoEnvironment.elm`**, with
  `isEnvironmentFlags : Can.Type Name -> Bool` (peels top-level `TAlias`es to reach
  `Platform.Program`, then checks the flags argument's alias chain against
  `ModuleName.Canonical Pkg.ecoSystem "System"` / `"Environment"`) and the names
  `systemHome` / `environmentDecoderName`.
- **`System.environmentDecoder`** (System.elm, unexposed):
  `Json.Decode.map toEnvironment Json.Decode.value`. `toEnvironment json` calls the new **pure
  kernel `Eco.Kernel.System.environmentNow : Json.Decode.Value -> ( ( String, String, String ), (
  List String, Int ), ( Int, Int, Int ) )`**: (platform, arch, applicationPath), (argv, start time
  in ms), (stdin, stdout, stderr ids). The argument is the decoded JSON value. It is unused, but it
  makes the call depend on the lambda parameter, so no constant hoisting or CAF pass can move it to
  module initialisation. This is a value-returning kernel that does startup work (stdio pair
  creation, as `environment` did inside a binding). It is not a Task, so KERNEL_TASK_IO_001 does
  not apply. It runs exactly once, inside `decodeFlags` on native and `_Platform_initialize` on
  JS, before `init`.
- **`System.simpleProgram`** = `Platform.worker { init = \env -> ( (), command (Execute (Task.map
  (always ()) (run env))) ), update = \_ m -> ( m, Cmd.none ), subscriptions = \_ -> Sub.none }`.
  The `Execute` command and the C++ `SystemManager` are unchanged.
- **`Http.Server.send`** used `System.endSimpleProgram` to turn its kernel task into a `Cmd`. That
  function is removed, and an Elm package cannot hide an exposed function. So **`Http.Server`
  becomes `effect module … where { command = MyCmd, subscription = MySub }`** with
  `type MyCmd msg = Respond (Task Never ())` (tag 0, one boxed field). `HttpServerManager.cpp`
  gains the `SystemManager` pattern: onEffects `rawSpawn`s every `Respond` task, plus `cmdMapEval`.
  The JS effect-manager body spawns it the same way.
- **Manager keys** (`eco-system-library.md` D11, bare module names) and registration symbols:
  `"System.File"` → `"FileSystem"` (`Eco_System_registerManager_FileSystem`),
  `"System.Process"` → `"ChildProcess"` (`…_ChildProcess`), `"System.Terminal"` → `"Terminal"`
  (`…_Terminal`). `"Http.Server"` keeps its key and now also has a command map. On JS, manager
  keys are the Elm module names, so they follow the renames by themselves.
- **`Stream.readLine` (D18) kernel design.** Each stream pair gets a **POD carry buffer**
  (`std::string carry` + read offset; a `Uint8Array` in JS). Bytes in it are off-heap, so no GC
  root is involved. Three new kernel tasks, all `Int` id last:
  - `carryLine : Bool -> Int -> Task Never (Maybe Bytes)` returns the next line from the carry
    without `\n` and without a preceding `\r`. When the flag (`atEnd`) is set, the remainder is
    returned if non-empty. Otherwise `Nothing`.
  - `carryAppend : Bytes -> Int -> Task Never ()`.
  - `readChunk : Int -> Task SErr a` is today's `read`, ignoring the carry.

  `read` becomes "carry first": if the pair's carry is non-empty, return it as one `Bytes` value
  and clear it; else the old body. `readLine` in Elm: `carryLine False` → `Just` → decode;
  `Nothing` → `readChunk` → `carryAppend` → loop; `Closed` from `readChunk` → `carryLine True` →
  `Just` → decode, `Nothing` → fail `Closed`. Invalid UTF-8 → `cancelReadable` + `Cancelled`, as
  `readString`. Cost is linear (one copy into the carry per chunk; lines are taken by offset; the
  buffer is compacted when the offset passes half its size). Concurrent readers of one stream are
  not supported, as for `read`.
- **`Http.Server.endpoint`.** The server kernels' result changes from `( id, port )` to
  `( id, address, port )` (tuple3, Int/String/Int, mask `0x5`). The address is the bound socket
  address as text (`getsockname` → `SocketUtil` text natively, `server.address().address` in JS).
  `Server` stores an `InetEndpoint`, parsed with `Socket.Address.fromString`. An unparseable
  address (never expected) falls back to the unspecified address of the family.
  `listenOnHost` uses today's `createServer` kernel; `listen` uses `createServerWith`.
- **`Http.Server.Error`** is opaque `Error { code, message }`. The predicates test codes as
  `Socket`'s do (`EADDRINUSE`; `EADDRNOTAVAIL`/`EAFNOSUPPORT`; `ENOTFOUND`/`EAI_AGAIN`/`EAI_FAIL`;
  `EACCES`/`EPERM`; prefix `ERR_SSL_`).
- **`FileSystem.writeFileWith`** in pure Elm over the existing handle kernels. With both options
  off it is `writeFile`. Otherwise: `open` (`"wx"` with `createNew`, else `"w"`) → `writeFromOffset
  0` → `fsync` when `sync` → `close`. The handle is closed on failure too, and the error carries
  the path. **`writeFileStreamWith`** passes the options to the existing `writeFileStream` kernel
  in its mode argument: bits 0–1 = mode (0 Replace, 1 ReplaceFrom, 2 Append), bit 2 = createNew
  (`O_EXCL`, implies `O_CREAT`), bit 3 = sync on close. `FsRes` gains `syncOnClose` next to
  `truncateOnClose`, carried to the `FdChannel`, which `fsync`s before `close` (JS: `fs.fsync`
  before `fs.close`).
- **`Terminal.setTitle`** uses the existing kernel slot, renamed `Eco.Kernel.Terminal.setTitle`.
  Native: if `isatty(1)`, write `ESC ] 2 ; title BEL` to fd 1 (one `write`, `EINTR` retried); the
  Windows stub stays. JS: `if (process.stdout.isTTY) process.stdout.write('\x1b]2;' + title +
  '\x07')`. The `comm`/`process.title` code is removed.
- **Dead kernels removed:** `getPlatform`, `getCpuArchitecture` and the Task `environment`, from
  C++ (body + export + header) and JS.
- **Kernel names that stay** (Elm-internal, invisible to users): `setStdInRawMode`, every
  `Eco.Kernel.Dom.*`, every `Eco.Kernel.Stream.*` codec kernel, `Eco.Kernel.HttpServer.*`.

### 10.2 Phase I1 — compiler (D13)

1. Add `compiler/src/Compiler/Elm/EcoEnvironment.elm` (helper above; exposed through the
   compiler's own module list, if it keeps one).
2. `EntryPrep.insertFlagsDecoderNode`: when `isEnvironmentFlags tipe`, the decoder expr is
   `TOpt.VarGlobal A.zero (TOpt.Global systemHome environmentDecoderName) { tipe = decoderCanType,
   tvar = Nothing }`, with the deps set holding that global.
3. `Typed/Module.elm` and `Erased/Module.elm` `addDefHelp`: before `Effects.checkPayload`, when
   `isEnvironmentFlags tipe`, use `Names.registerGlobal` for the same global.
4. Unit test `compiler/tests/TestLogic/Generate/EcoEnvironmentFlagsTest.elm`: `isEnvironmentFlags`
   on the direct type, through a user alias of `Environment`, through an alias of the whole
   `Program`, and negative cases (a user record named `Environment` in another module, `()`
   flags).
5. Update `EcoSystemManagerRegistrationTest.elm` (`System.Process` → `ChildProcess` and symbol).
6. Amend invariant **PORT_007**: append the eco/system `Environment` special case.

### 10.3 Phase I2 — eco/system Elm sources (`system-kernel-cpp/src`)

Module moves (git mv):

| From | To |
|---|---|
| `System/File.elm` | `FileSystem.elm` |
| `System/File/FileHandle.elm` | `FileSystem/Handle.elm` |
| `System/File/Internal.elm` | `FileSystem/Internal.elm` |
| `System/File/Path.elm` | `Path.elm` |
| `System/Process.elm` | `ChildProcess.elm` |
| `System/Terminal.elm` | `Terminal.elm` |
| `Http/Dom.elm` | `Html/Dom.elm` |
| `Http/Server/Response.elm` | merged into `Http/Server.elm` (deleted) |
| `Stream/Log.elm` | merged into `Stream.elm` (deleted) |
| — | `Stream/Transformation.elm` (new) |

Then make each module's exposing list, annotations and doc comments equal to the review repo, and
re-implement:
- `System`: environment decoder, `simpleProgram`; remove `Program`, `ProgramConfiguration`,
  `defineProgram`, the `Model`/`Msg` wrappers, `SimpleProgram`, `defineSimpleProgram`,
  `endSimpleProgram`, `getPlatform`, `getCpuArchitecture`, `initializeEnvironment`;
  `getEnvironmentVariables` → `environmentVariables`.
- `Stream` + `Stream.Transformation` (D9, D18), `FileSystem` (D12, `tempDirectory`),
  `FileSystem.Handle` (D11, module-doc paragraph D6), `Path.parent`, `ChildProcess.StreamIO`
  fields, `Terminal` (`configuration`, `setStdinRawMode`, `setTitle`).
- `Http.Server`: `MyCmd`/`command`, the Response functions, `listen`, `listenOnHost`, `endpoint`,
  `close`, `closeWithin`, `ListenOptions`, opaque `Error` + predicates, `bodyAsJson`,
  `requestToString`.
- `Html.Dom` renames; `WebSocket` renames.

Update `elm.json` exposed-modules to the review repo's list; regenerate `docs.json`.

### 10.4 Phase I3 — kernels (C++ `src/eco-system`, JS `src/Eco/Kernel`)

| Area | C++ | JS |
|---|---|---|
| Manager keys | `FileSystemManager.cpp/hpp`, `ChildProcessManager.cpp/hpp`, `TerminalManager.cpp/hpp`: key strings, symbols, comments | none (keys = module names) |
| Http.Server cmd | `HttpServerManager.cpp/hpp`: `CTOR_RESPOND`, spawn in onEffects, `cmdMapEval` | Elm manager body (in `Http/Server.elm`) |
| endpoint | `HttpServer.cpp` `serverResult`, both start paths | `HttpServer.js` results |
| environmentNow | `System.cpp/hpp`, `SystemExports.cpp`; remove `getPlatform`/`getCpuArchitecture`/`environment` | `System.js` |
| readLine | `StreamTable.hpp` (carry), `Stream.cpp` (read carry-first, `readChunk`, `carryLine`, `carryAppend`), `Stream.hpp`, `StreamExports.cpp` | `Stream.js` |
| writeFileStream flags | `FileSystemOps.cpp` (`opWriteFileStream` bits), `FileSystem.hpp` (`FsRes::syncOnClose`), `FileSystem.cpp` (sink creation), `FdChannel.cpp/hpp` (fsync on close) | `FileSystem.js` (`wx`, fsync) |
| setTitle | `Terminal.cpp/hpp`, `TerminalExports.cpp` | `Terminal.js` |

C++ kernel rules: G2/G3 (copy inputs out first, allocate results last), `StackRootGuard` for every
HPointer held across an allocation, tuple masks per HEAP_046, Int args/results as `int64_t`
(REP_ABI_001).

### 10.5 Phase I4 — callers

Every Elm program using eco/system is updated by one codemod
(`/tmp`-hosted script, not committed), then fixed by hand where needed:
- `test/eco-system/src/*.elm` (≈180 E2E tests and helpers),
- `test/stress-elm/src/EcoSystem*.elm` and `StressHarness.elm` if it imports eco/system,
- `test/conformance/src/*.elm`,
- `examples/src/*.elm` (10 programs) + a new **`examples/src/Nl.elm`** (D16: number stdin lines
  with `Stream.readLine`),
- `system-kernel-cpp/tests/tests/*.elm` (unit tests),
- the `eco init` scaffold template in `compiler/src/Terminal/Init.elm`,
- `docs/getting-started.md`, `system-kernel-cpp/README.md`.

The codemod rewrites imports and qualified names per §6/D4/D8/D9/D11/D14/D17, and the
`main`/program shapes:
- `System.SimpleProgram msg` → `Platform.Program System.Environment () ()`, and
  `System.defineSimpleProgram (\env -> System.endSimpleProgram T)` → `System.simpleProgram (\env -> T)`.
- `System.Program M Msg` → `Platform.Program System.Environment M Msg`,
  `System.defineProgram {…}` → `Platform.worker {…}`.

Simple programs that built a `Cmd` other than `endSimpleProgram` (`exitWithCode`, `Cmd.batch`)
are rewritten by hand, to tasks ending in `setExitCode` or to `Platform.worker`.

New E2E tests (test/eco-system/src):
- `StreamReadLineTest`: stdin lines: LF, CRLF, an unterminated last line, an empty line, a line
  longer than 64 KiB, and mixing `read` after `readLine`.
- `FileWriteOptionsTest`: `createNew` on a new path and on an existing path (`errorIsFileExists`),
  `sync`, `writeFileStreamWith` with `createNew` and `sync`.
- `EnvironmentStartTimeTest`: `startTime` is after 2020 and not after `Time.now`.
- `HttpServerEndpointTest`: `listenOnHost "127.0.0.1" 0` → `endpoint` address `127.0.0.1`, port > 0;
  `listen` on the IPv6 loopback, when available.
- `TerminalSetTitleTest`: with stdout redirected (the harness), `setTitle` writes nothing.

### 10.6 Phase I5 — docs and other references

`system-kernel-cpp/README.md`, `docs/getting-started.md`, the module-name comments in the C++/JS
kernels, and `plans/eco-system-library.md` D5 pointing here. `design_docs` audits are history and
are left alone.

### 10.7 Phase I6 — review repo sync check

Rebuild the review stubs from the implemented sources with the stub generator and compare the
docs output with `ecosyskernel/docs.json`. Any difference is either a bug in the implementation
or a deliberate doc fix that must be copied back to `ecosyskernel`.

### 10.8 Gates (run once each, at the end)

1. `cmake --build build --target elm-tests` (compiler front-end + new unit test).
2. Wipe stale caches (memory: `build/test/*/eco-stuff`, `~/.eco/<ver>` package artifacts incl.
   eco/system), then `TEST_FILTER=eco-system cmake --build build --target full` (native E2E of
   the eco-system suite), then the whole `full` E2E.
3. JS E2E for the eco-system suite (`run-js-e2e`).
4. `eco-system-core-test` and the eco-system stress programs (`stress-test`, EcoSystem filter),
   with `ulimit -c 0`.
5. Every `examples/src` program compiles (and `Hello`, `Cat`, `Nl` run).
6. `pnpm run docs:check` in `system-kernel-cpp` (and the §10.7 comparison).

Exit criterion: all gates green, or every failure explained as pre-existing (memory baseline:
stress 111/113 with two known failures).

## 11. Progress log

**2026-10-19 — implementation (phases I1–I6).**
- I1 compiler: `Compiler/Elm/EcoEnvironment.elm` + the three decoder sites; unit test
  `TestLogic/Generate/EcoEnvironmentFlagsTest.elm`; the registration test's dotted-home case now
  uses `Socket.Udp` (the old `System.Process` home is gone). PORT_007 amended.
- I2 Elm sources: the modules were moved (plain `mv`; git cannot run in the container), rewritten,
  and their exposing lists, module docs and every exposed doc comment and annotation copied from
  the review repo by a merge script. The stock-elm docs build of the package is identical to
  `ecosyskernel/docs.json` in every module, name, type and comment. The only difference left is
  internal: the implementation exposes `Readable`, `Writable`, `Transformation`, `Error`,
  `Response`, `Connection`, … as aliases over `*.Internal` types, as before, where the stubs
  declare opaque types.
- I3 kernels: as §10.4. Two layout notes found while writing them: tuple masks are 2 bits per slot
  (`( Int, String, Int )` is `0x11`, `( List String, Int )` is `0x4`); Bool kernel arguments arrive
  as encoded constants (`Export::decodeBoxedBool`).
- I4 callers: a codemod (scratch, not committed) for ≈200 files, then hand fixes. Things the
  codemod could not do, fixed by hand:
  - opaque `Http.Server.Error`: callers that destructured `ServerError e` now use `errorCode` /
    `errorToString`; outputs printing `code ++ " " ++ message` print `errorToString`
    (`code: message`), with the CHECK lines updated;
  - `getPlatform` / `getCpuArchitecture` callers read `env`;
  - `StreamIO` field accesses;
  - the examples (hand-converted, user-facing).
- **Consequence of D14 found while converting the examples:** full programs (`Platform.worker`)
  that used `System.endSimpleProgram task` to run a task as a `Cmd` now use
  `Task.perform (\_ -> SomeMsg) task`, the ordinary Elm way. To log and then exit, they log with
  `Task.perform (\_ -> Exit 1)` and answer `Exit code` with `System.exitWithCode code` (TcpEcho,
  UdpEcho, HttpEcho, WsChat).
- New tests: `StreamReadLineTest`, `FileWriteOptionsTest`, `EnvironmentStartTimeTest`,
  `HttpServerEndpointTest`. The planned `TerminalSetTitleTest` became part of `TerminalTest`
  (its old `setProcessTitle` / `/proc` check is replaced by "setTitle succeeds and writes nothing
  to a piped stdout"). New example `examples/src/Nl.elm`.
- Docs: `system-kernel-cpp/README.md`, `docs/getting-started.md`, the `eco init` scaffold
  (`compiler/src/Terminal/Init.elm`), `plans/eco-system-library.md` D5.
- Unit tests of the package (`system-kernel-cpp/tests`, elm-test-rs): 898 passed.
- Fixes found by the gates: (1) the JS kernels `Dom.js` and `HttpServer.js` import Elm names
  (`import Http.Dom as Dom exposing (…, render)`); the old module name made eco/system fail to
  build as a dependency (the error is silent even with `--Xpackage-errors`), fixed to `Html.Dom`
  / `toString`. (2) `examples/benchmarks/src/Bench.elm` was a caller too. (3) The comment-only
  rename sweep also rewrote `-- CHECK:` directives, which are comments; restored. (4) The
  harness's `-- STDIN:` does not unescape `\r`, so the CRLF case of `StreamReadLineTest` moved to
  the file part.
- Gates (§10.8): elm-tests 14,124/0 (+6 new) and package unit tests 898/0; native JIT E2E
  2,385/2,390 in the `full` run, the 5 failures being (3)/(4) above, re-run green after the fix;
  eco-system core unit tests pass; JS E2E 166/166 (3 skipped by design); eco-system stress 13/13;
  every `examples/src` program and `Bench.elm` compiles to MLIR; `Hello`, `Cat`, `Nl` run on JS
  and natively (`eco-boot-native`); `docs:check` output identical to `ecosyskernel/docs.json`.

