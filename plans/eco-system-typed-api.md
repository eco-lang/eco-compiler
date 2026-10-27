---
status: done
updated: 2026-10-27
---

# eco/system: custom types for stringly-typed API values

The eco/system API has values that are strings but take a fixed or well-known set of values: the
HTTP method on the client side, the upgrade protocol, the TLS version, and the error codes of every
module. This plan replaces them with custom types, so programs pattern-match instead of comparing
strings.

Part A covers the enums, and Part B the error types. One set of steps (below) does both, because
they change the same modules (`Http.Server`, `Socket.Tls`, `WebSocket`).

This is a breaking change to the eco/system API.

## Background: where the strings come from

- **Enums**: the kernels hand over the method, the upgrade token and the TLS version as strings,
  and Elm passes them on (`toMethod`, `toRequest`'s `upgradeToken`, the tuple in `Socket.Tls.info`).
- **Error codes**: three sources.
  - POSIX errno names (`ENOENT`, `ECONNRESET`, …), from `errnoName` (`Core/ErrnoNames.cpp`)
    natively and from Node on JS.
  - Node.js's own codes (`ENOTFOUND`, `ERR_FS_EISDIR`, `ERR_TLS_CERT_ALTNAME_INVALID`,
    `ERR_SSL_<REASON>`, `ERR_SOCKET_BAD_PORT`), which the native kernels copy.
  - OpenSSL certificate names (`CERT_HAS_EXPIRED`, …), and the package's own codes (`ERR_WS_*`).

# Part A: enums

## A1. New module `Http.Method`

It holds the HTTP method type that `Http.Server` and `Http.Stream` share:

    type Method = GET | HEAD | POST | PUT | DELETE | CONNECT | OPTIONS | TRACE | PATCH | UNKNOWN String
    toString : Method -> String
    fromString : String -> Method      -- an unlisted name gives UNKNOWN name, as received

- `Http.Server.Method` and `Http.Server.methodToString` move here, and `Http.Server` no longer
  exposes them. `Request.method` becomes `Http.Method.Method`.
- `OPTIONS` is new. Today an OPTIONS request, such as every CORS preflight, arrives as
  `UNKNOWN "OPTIONS"`.

Why a separate module: `Http.Stream` already takes elm/http's `Http.Header` and reports
`Http.Error`, so the HTTP basics come from elm/http. The method is the only one missing, because
elm/http uses a `String`. Leaving the type in `Http.Server` would make a client import the server
module just to name a method. A broader `Http.Common` would mostly duplicate elm/http.

## A2. `Http.Stream.request` / `task` take `method : Method`

They take a `Method`, not a `String`. The method is sent as `Http.Method.toString` gives it, and
an `UNKNOWN` name is checked as the method string is checked today.

## A3. `Http.Server.Request.upgrade : Maybe Upgrade`

    type Upgrade = WebSocketUpgrade | UnknownUpgrade String     -- in Http.Server

`UnknownUpgrade` holds the lower-cased token, as received. `upgradeRequest` and the
reject-when-not-WebSocket path match on `WebSocketUpgrade`, not on `Just "websocket"`
(`Http/Server.elm:589`, `:624`). `HttpVersion` and `Upgrade` stay in `Http.Server`, since only a
server sees them.

## A4. `Socket.Tls.Info.version : TlsVersion`

The field was `protocol`, a `String`.

    type TlsVersion = Tls1_0 | Tls1_1 | Tls1_2 | Tls1_3 | UnknownTlsVersion String

The mapping is from OpenSSL's names: `"TLSv1"`, `"TLSv1.1"`, `"TLSv1.2"`, `"TLSv1.3"`. The rename
removes the docs' warning that `protocol` is the TLS version and not the application protocol
(`alpn`).

Part A is decided in Elm from the strings the kernels already hand over. Neither the C++ kernels
nor the JS kernels change, and no JS kernel imports these names.

# Part B: error types

## Shared rules

- **R1:** Each module keeps its opaque `Error`, its message (`errorToString`), and FileSystem's
  `errorPath`. `errorCode : Error -> String` is replaced by `errorKind : Error -> ErrorKind`.
- **R2:** Every kind type ends in an `Other… String` case holding the raw code. This can't be
  avoided: natively `errnoName` knows ~150 errno names, and on JS Node can report codes this plan
  does not name.
- **R3:** Constructor names reuse today's `errorIs*` names, so the meaning carries over. Cases
  marked *(new)* have no `errorIs*` today. Mappings marked *(change)* differ from today's helpers.
- **R4:** The kind is decided in Elm from the code string the kernel hands over (one `toKind`
  per module). Only `Stream` failures (B7) need a kernel change.

## B1. FileSystem (`FileSystem`, `FileSystem.Handle`)

    type ErrorKind
        = NoSuchFileOrDirectory         -- ENOENT
        | FileExists                    -- EEXIST
        | DirectoryFound                -- EISDIR
        | DirectoryRemoveNotRecursive   -- ERR_FS_EISDIR: a non-recursive remove of a directory (new)
        | NotADirectory                 -- ENOTDIR
        | DirectoryNotEmpty             -- ENOTEMPTY
        | PermissionDenied              -- EACCES
        | NotPermitted                  -- EPERM
        | TooManyOpenFiles              -- EMFILE, ENFILE (change: ENFILE added)
        | LinkLoop                      -- ELOOP
        | PathTooLong                   -- ENAMETOOLONG
        | InvalidInput                  -- EINVAL
        | IOError                       -- EIO
        | NotSupported                  -- ENOTSUP, EOPNOTSUPP (new)
        | CrossDevice                   -- EXDEV: rename across file systems (new)
        | HandleClosed                  -- EBADF: a FileSystem.Handle used after close (new)
        | NoSpace                       -- ENOSPC, EDQUOT (new)
        | ReadOnlyFileSystem            -- EROFS (new)
        | OtherFileSystemError String

## B2. Socket (`Socket`, `Socket.Tcp`, `Socket.Unix`, `Socket.Udp`)

The transport layer: TCP, UDP and Unix sockets share one union type, as they share one
connection type and the generic `Socket` functions (S2). TLS and WebSocket are protocols layered
on a socket, and each has its own error type that wraps this one (B3, B4; S1).

    type ErrorKind
        = ConnectionRefused             -- ECONNREFUSED
        | ConnectionReset               -- ECONNRESET, EPIPE
        | TimedOut                      -- ETIMEDOUT
        | NetworkUnreachable            -- ENETUNREACH, EHOSTUNREACH (new)
        | AddressInUse                  -- EADDRINUSE
        | AddressNotAvailable           -- EADDRNOTAVAIL, EAFNOSUPPORT
        | HostNotFound                  -- ENOTFOUND, EAI_FAIL
        | HostLookupTryAgain            -- EAI_AGAIN (change: was in errorIsHostNotFound; split
                                        --   because it is retryable)
        | PermissionDenied              -- EACCES, EPERM
        | Cancelled                     -- ECANCELED
        | Busy                          -- EBUSY: a stream locked, or a read/write waiting (new)
        | InvalidInput                  -- EINVAL (new)
        | NotSupported                  -- ENOTSUP: e.g. UDP on native Windows, peer credentials (new)
        | MessageTooLarge               -- EMSGSIZE: UDP datagram too large (new)
        | ListenQueueFull               -- EAGAIN: Unix-socket connect on Linux (new)
        | AddressPathFailed FileSystem.ErrorKind   -- a Unix-socket path failed as a file path
                                        --   would: ENOENT, ENOTDIR, ELOOP, EROFS, ENAMETOOLONG,
                                        --   and EACCES on the path (new; see S2)
        | ConnectionTakenOver           -- a connection's streams after another owner, such as
                                        --   WebSocket.receiveUpgrade, took it over (today
                                        --   "upgraded to WebSocket"; stream failures only)
        | OtherSocketError String

    errorKind         : Socket.Error -> ErrorKind
    errorToString     : Socket.Error -> String
    fromStreamFailure : Stream.Failure -> Maybe Socket.Error

`Socket.accept`, `closeListener` and `lookup`, and every function of `Socket.Tcp`,
`Socket.Unix` and `Socket.Udp`, keep `Socket.Error`. `accept` stays generic even on a TLS
listener, because a TLS listener closes a client whose handshake fails before `accept` sees it.

## B3. Socket.Tls

`Socket.Tls.Error` is a plain custom type, not opaque with an `errorKind`: the layering is the
information, and its message comes from the wrapped error or the `Problem`.

    type Error
        = SocketError Socket.Error      -- failed below TLS
        | TlsError Problem              -- failed in TLS itself

    type Problem
        = CertificateRejected CertificateProblem   -- connect: the server's certificate was rejected
                                                   --   (today errorIsCertificateInvalid)
        | CertificateUnusable String    -- certificates this end supplied cannot be used: listen's
                                        --   chain or key, or connect's TrustedCertificates PEM
                                        --   with no readable certificate; ERR_SSL_<REASON>,
                                        --   holds <REASON>
        | HandshakeFailed String        -- ERR_SSL_<REASON>; holds <REASON>, e.g. "UNKNOWN"

    type CertificateProblem
        = Expired                       -- CERT_HAS_EXPIRED
        | NotYetValid                   -- CERT_NOT_YET_VALID
        | Revoked                       -- CERT_REVOKED
        | SelfSigned                    -- DEPTH_ZERO_SELF_SIGNED_CERT
        | SelfSignedInChain             -- SELF_SIGNED_CERT_IN_CHAIN
        | IssuerNotTrusted              -- UNABLE_TO_GET_ISSUER_CERT_LOCALLY
        | LeafNotVerifiable             -- UNABLE_TO_VERIFY_LEAF_SIGNATURE
        | NameMismatch                  -- ERR_TLS_CERT_ALTNAME_INVALID
        | VerificationFailed            -- CERT_VERIFY_FAILED: native catch-all (tlsVerifyCode); on
                                        --   JS, any other Node verification code

    errorToString     : Error -> String
    fromStreamFailure : Stream.Failure -> Maybe Error   -- TLS failures, and socket ones wrapped
                                                        --   as SocketError, so one call covers
                                                        --   a TLS connection's streams

    connect : ClientOptions -> Socket.Tcp.ConnectOptions -> Task Socket.Tls.Error Socket.Connection
    listen  : ServerOptions -> Socket.Tcp.ListenOptions  -> Task Socket.Tls.Error Socket.Listener
    info    : Socket.Connection -> Task Socket.Tls.Error Info

- The `String` in `CertificateUnusable` and `HandshakeFailed` stays, because OpenSSL has hundreds
  of reason strings, and natively the code is built from one (`tlsErrorCode`,
  `Tls/TlsContext.cpp:259`).
- A peer that drops during the handshake is ECONNRESET from the native TLS transport, so it is a
  `SocketError`. Only failures produced by TLS itself (certificate checks, `ERR_SSL_<REASON>`)
  are a `TlsError`.

## B4. WebSocket

    type Error
        = SocketError Socket.Error      -- the connection under the WebSocket failed
        | TlsError Socket.Tls.Problem   -- wss:// only
        | HandshakeRefused Int          -- the server answered with this status (was errorHandshakeStatus)
        | HandshakeFailed               -- ERR_WS_HANDSHAKE for any other reason
        | HeartbeatTimedOut             -- message streams: today "heartbeat ETIMEDOUT"
        | MessageTooLarge               -- message streams: today "ERR_WS_MESSAGE_TOO_BIG"
        | ProtocolViolation String      -- message streams: today "ERR_WS_PROTOCOL: <details>";
                                        --   holds <details>

    errorToString     : Error -> String
    fromStreamFailure : Stream.Failure -> Maybe Error

Every WebSocket function that fails with `Socket.Error` today fails with `WebSocket.Error`:
`connect`, `connectStreamed`, `receiveUpgrade`, `accept`, `acceptStreamed`, `sendText`,
`sendBinary`, `ping` and `close`, plus `Http.Server.upgradeRequest`. `errorIsHandshakeFailed` and
`errorHandshakeStatus` are removed.

`WebSocket.Error` lists each lower layer's own failure once, at the same depth, rather than
wrapping `Socket.Tls.Error`:

| Failure | `ws://` | `wss://` |
|---|---|---|
| TCP: refused, reset, timeout, DNS | `SocketError e` | `SocketError e` |
| TLS: certificate rejected, handshake failed | (cannot happen) | `TlsError problem` |
| WebSocket handshake | `HandshakeRefused n` / `HandshakeFailed` | `HandshakeRefused n` / `HandshakeFailed` |

Wrapping `Socket.Tls.Error` would make the same refused TCP connection `SocketError e` over
`ws://` but `TlsError (Socket.Tls.SocketError e)` over `wss://`, so it would need two patterns.
Converting a `Socket.Tls.Error` is total and lossless: `SocketError e` stays `SocketError e`, and
`TlsError p` stays `TlsError p`. A `wss://` client can get `TlsError (CertificateUnusable …)`
when its `TrustedCertificates` PEM holds no readable certificate, so `Problem` is shared by
clients and listeners rather than split.

The names `MessageTooLarge` and `ProtocolViolation` avoid a clash with `CloseCode`'s existing
`MessageTooBig` and `ProtocolError` constructors in the same module.

One type covers both the operations and the WebSocket's message streams (S3). An operation
never produces `HeartbeatTimedOut`, `MessageTooLarge` or `ProtocolViolation`, and a message stream never
produces `HandshakeRefused` or `HandshakeFailed`. A broken connection is `SocketError` in both
places.

## B5. Http.Server (`listen`, `listenOnHost`)

    type ErrorKind
        = AddressInUse                  -- EADDRINUSE
        | AddressNotAvailable           -- EADDRNOTAVAIL, EAFNOSUPPORT
        | HostNotFound                  -- ENOTFOUND, EAI_FAIL
        | HostLookupTryAgain            -- EAI_AGAIN (change, as in Socket)
        | PermissionDenied              -- EACCES, EPERM
        | InvalidPort                   -- ERR_SOCKET_BAD_PORT (new)
        | InvalidInput                  -- EINVAL (new)
        | NotSupported                  -- ENOTSUP: native Windows (new)
        | CertificateUnusable String    -- ERR_SSL_<REASON>: an unusable certificate chain or key;
                                        --   holds <REASON> (today errorIsCertificateInvalid)
        | OtherServerError String

## B6. ChildProcess (`run`)

`FailedRun.InitError { program, arguments, errorCode : String }` becomes
`InitError { program, arguments, error : StartError }`.

    type StartError
        = ProgramNotFound               -- ENOENT
        | PermissionDenied              -- EACCES: not executable, or a directory on the path not searchable
        | NotExecutable                 -- ENOEXEC: not an executable format
        | ArgumentsTooLong              -- E2BIG
        | ProcessLimitReached           -- EAGAIN, ENOMEM, EMFILE, ENFILE
        | OtherStartError String

## B7. Stream (`Stream.Error`)

A stream is an abstract data flow, so `Stream` knows nothing about sockets, files or WebSockets.
Its error covers what any stream can go through. A failure of the resource behind the stream is
an opaque `Failure`, and the module that implements the stream reads it back as that module's own
typed error. This is the pattern of Go's `errors.As`.

    type Error
        = Closed            -- the stream has ended: a read after every value was read, or a
                            --   write or close into a stream that was closed or that its
                            --   transformation ended (change: writes failed with Cancelled before)
        | Locked            -- unchanged
        | Cancelled String  -- the program cancelled the stream, with the reason it gave: either
                            --   side (cancelReadable, cancelWritable), a transformation's Cancel,
                            --   or a readUntilClosed step's Err
        | Failed Failure    -- the resource behind the stream failed

    type Failure            -- opaque; internally its origin, code and message
    failureToString : Failure -> String

Each implementation reads its own failures, and returns `Nothing` for anyone else's:

    Socket.fromStreamFailure      : Stream.Failure -> Maybe Socket.Error
    Socket.Tls.fromStreamFailure  : Stream.Failure -> Maybe Socket.Tls.Error
    FileSystem.fromStreamFailure  : Stream.Failure -> Maybe FileSystem.Error
    WebSocket.fromStreamFailure   : Stream.Failure -> Maybe WebSocket.Error
    Http.Stream.fromStreamFailure : Stream.Failure -> Maybe Http.Error    -- elm/http's type

Where each of today's reasons goes:

| Today's reason | New error |
|---|---|
| `"WritableStream is closed"`, `"TransformStream has been terminated"` | `Closed` |
| a program's reason (cancel, `Cancel`, `readUntilClosed`) | `Cancelled reason` |
| `"read <CODE>"`, `"write <CODE>"` on a socket | `Failed`; `Socket.fromStreamFailure` gives the kind, such as `ConnectionReset` |
| a TLS failure on a TLS connection's streams | `Failed`; `Socket.Tls.fromStreamFailure` gives `TlsError` (and socket failures as `SocketError`) |
| `"socket closed"` | `Failed`; `Socket.fromStreamFailure` gives kind `Cancelled` (ECANCELED, as socket operations report it) |
| `"upgraded to WebSocket"` | `Failed`; `Socket.fromStreamFailure` gives kind `ConnectionTakenOver` |
| heartbeat, message too big, `ERR_WS_PROTOCOL` | `Failed`; `WebSocket.fromStreamFailure` |
| `"<CODE>: <message>"` on a file stream | `Failed`; `FileSystem.fromStreamFailure` |
| `"<CODE>: <message>"` on a child-process pipe | `Failed`; only `failureToString` for now (ChildProcess has no general error type) |
| an HTTP response body stream (`Http.Stream`) | `Failed`; `Http.Stream.fromStreamFailure` |

Consequences:

- **Kernel change.** Unlike R4 for the other families, this needs the C++ and JS kernels to hand
  over a failure's origin, code and message as structured values, not as today's combined reason
  string. Parsing that string in Elm would be fragile.
- **Who can make a `Failure`.** Its constructors stay internal to the package, in
  `Stream.Internal`. A stream implemented in Elm, such as a custom transformation, fails with
  `Cancelled reason`, as it can today. A future implementation inside this package adds its own
  `fromStreamFailure`, and `Stream` does not change.
- **Rejected alternative.** A type parameter (`Readable error value`) would make the error precise
  wherever the stream is held. But it would change every stream signature, force `pipeTo` and
  `pipeThrough` to unify or map the error types, and thread the parameter through every
  transformation.

# Decisions

## Accepted (Oct 21)

- **D1:** `Socket.Tls.Info.protocol` is renamed to `version` (A4).
- **D2:** The method constructors keep their upper-case names (`GET`, `OPTIONS`, `UNKNOWN`), as
  `Http.Server` has today, rather than `Get` / `UnknownMethod`, to limit churn.
- **D3:** A new `Http.Method` module holds `Method` (A1).
- **E1:** `errorCode : Error -> String` is dropped. The `Other…` cases carry the raw code, and
  `errorToString` includes it.
- **E2:** The ~28 `errorIs*` functions are removed in favour of matching on `errorKind`.
- **E3:** `Http.Server.ErrorKind` stays a separate type from `Socket.ErrorKind`, as `Error` is
  today, so a server program matches only on what `listen` can produce.
- **E4:** `Stream` stays generic: `Closed | Locked | Cancelled String | Failed Failure`, with a
  `fromStreamFailure` in each implementing module (B7).
- **E5:** `Closed` also answers a write or close into an ended stream. This replaces
  `Cancelled "WritableStream is closed"` and `Cancelled "TransformStream has been terminated"`.
- **E6:** The Socket kind for streams taken over by a WebSocket is named `ConnectionTakenOver`.
- **S1:** Socket errors are layered (B2–B4). The transports share `Socket.Error`, and
  `Socket.Tls.Error` and `WebSocket.Error` each own their layer's failures and include the layer
  below. A socket error comes from a call to a specific module, so, unlike a stream failure (B7),
  the precise type is in the signature, with no accessor. Costs: 13 signatures change (3 in
  `Socket.Tls`, 9 in `WebSocket`, and `Http.Server.upgradeRequest`), and a chain that mixes plain
  `Socket` tasks with TLS or WebSocket tasks needs a `Task.mapError` (for example
  `Task.mapError Socket.Tls.SocketError`).
- **S2:** A Unix-socket address is a file-system path, so `Socket.Unix.connect` and `listen`
  fail as a file operation on that path would. Those failures are
  `AddressPathFailed FileSystem.ErrorKind`, reusing B1's kinds: `NoSuchFileOrDirectory` (ENOENT:
  nothing at the path on connect, a missing parent directory on listen), `NotADirectory`
  (ENOTDIR), `LinkLoop` (ELOOP), `ReadOnlyFileSystem` (EROFS), `PathTooLong` (ENAMETOOLONG), and
  `PermissionDenied` (EACCES on the socket file or its directory). This replaces the
  `NoSuchFile` / `PathTooLong` socket cases, which left ENOTDIR, ELOOP and EROFS in
  `OtherSocketError` and described ENOENT on listen poorly.
  - The mapping is by module: in `Socket.Unix.connect` and `listen`, the path errnos above,
    EACCES included, become `AddressPathFailed`. The socket-level `PermissionDenied` is left for
    privileged ports and other socket denials.
  - `EADDRINUSE` (something already at the path) and `ECONNREFUSED` (nobody listening) stay
    socket-level, as `AddressInUse` and `ConnectionRefused`: they describe the socket, not the
    path.
  - `Socket` imports `FileSystem` for the kind type. `FileSystem` does not import `Socket`, so
    there is no cycle.
  - TCP, UDP and Unix sockets keep one shared union type. They are alternative transports
    sharing one connection type and the generic `Socket` functions, unlike TLS and WebSocket,
    which are protocols layered on a socket (S1).
- **S3:** `WebSocket` has one error type for its operations and its message streams (B4), not a
  separate `StreamError`. Users handle one type, and a broken connection is `SocketError`
  wherever it happens, instead of `SocketError` from operations and `ConnectionFailed` from
  streams. The cost is that each place admits cases it never produces. This is the same trade-off
  as `Stream.Error` in general.

# Details settled while writing the stubs (Oct 21)

The ecosyskernel stubs (step 1) fixed these points, which the decisions above leave open. They are
listed here for review, and the implementation must match them:

- **Pipes:** `pipeThrough` and `pipeTo` pass a source's `Failed` on unchanged. When a `pipeTo`'s
  destination ends, the source is cancelled from its reading side, and the task fails with the
  destination's own error (`Cancelled`, `Failed`, or `Closed` for a closed destination).
- **Decompressors:** a decompressor that fails is `Stream.Failed`, read only with
  `failureToString`, like a child-process pipe.
- **Invalid UTF-8:** `readString` and `readLine` still cancel the stream themselves on invalid
  UTF-8 and fail with `Cancelled`, with a reason of the package's own.
- **File-stream errors:** an error from `FileSystem.fromStreamFailure` has `errorPath` =
  `Path.empty`, since a stream does not carry its file's path.
- **HTTP body streams:** `Http.Stream.fromStreamFailure` always gives `Http.NetworkError`. Every
  body-stream failure in both kernels is a network failure, and nothing times out after the
  headers.
- **WebSocket names:** the WebSocket cases are `MessageTooLarge` and `ProtocolViolation String`
  (B4), to avoid `CloseCode`'s constructors.
- **WebSocket ping:** a `ping` with no pong fails with `SocketError` of kind `TimedOut`, not
  `HeartbeatTimedOut`. Operations never produce the stream-only cases.
- **TLS accept:** TLS that cannot be accepted on an open connection is `HandshakeFailed reason`,
  with reason `"UNKNOWN"` when OpenSSL gives none.

To verify during the implementation (the stubs state them, but they were inferred, not checked):

- whether a streamed WebSocket message being received when this end starts closing fails with
  `Stream.Failed`;
- whether a TLS failure after the handshake reaches a stream as a `TlsError` (via
  `Socket.Tls.fromStreamFailure`);
- the exact text of each `errorToString` (the docs' examples are illustrative);
- that `listen` / `bind` on an address not belonging to this machine is `AddressNotAvailable`
  (EADDRNOTAVAIL).

# Implementation (done Oct 21)

All six steps are done; nothing is committed.

- **Stubs and docs.** The real package's docs are synced from the stubs, and its generated
  `docs.json` equals `ecosyskernel/docs.json`. One stub doc changed while implementing:
  `Socket.Tls.errorToString` gives a `TlsError`'s code and a fixed description, because a `TlsError`
  keeps only its `Problem`, not the TLS library's message.
- **Kernels.** A reason the kernel makes itself is marked: `\x01origin\x1fcode\x1fmessage` for a
  resource failure (Core.hpp `failureReason`; Stream.js `_Stream_failureReason`), `\x02...` for an
  ended stream. `Stream.Internal.decodeReason` reads it, so the `(kind, reason)` SErr shape is
  unchanged. `ByteChannel::encodeFailure` / `failureOrigin` (C++) and `__encodeFailure` /
  `__origin` (JS) let each channel tag its failures: sockets (`socketFailureReason`), WebSockets
  (`websocketFailureReason`), HTTP transfers (`"http"`, code `NETWORK`), file streams (`"file"`),
  child pipes (`"pipe"`), stdio (`"stdio"`), codecs (`"codec"`).
- **Socket.Unix path failures** carry an internal `onPath` flag (`Socket.Internal.onUnixPath`),
  set by `connect` and `listen`. The JS kernel checks a listen path's parent directory first,
  because Node reports a missing one as EACCES where bind(2) reports ENOENT.
- **Tests.** Package unit tests `HttpMethodTest` and `StreamReasonTest`. New E2E tests
  `HttpMethodOptionsTest`, `HttpServerUnknownUpgradeTest`, `SocketUnixPathErrorsTest` and
  `FileStreamFailureTest`. `test/eco-system/src/ErrorNames.elm` prints every error type for
  CHECK lines. About 115 tests, helpers and examples were migrated.
- **Gates.** `elm-tests` passed 14,138 / 0, with eco/system 918 / 0. JIT E2E passed 2448 / 2448
  (3 type-only failures fixed and re-run). JS E2E passed 208 / 0 (4 skipped). `docs.json` equality
  holds.
- **Known gap.** A working directory that does not exist reaches `ChildProcess.run` as ENOENT, so
  it is `InitError ProgramNotFound`. The kernels cannot tell it from a missing program.

# Steps

1. **Normative stubs.** Update `/work/ecosyskernel` (the new `Http.Method`, and changed types,
   signatures and docs), then make `system-kernel-cpp/src` match. Its stock-elm `docs.json` must
   equal `ecosyskernel/docs.json`.
2. **Kernels (C++ and JS), for B7 only.** Stream failures carry `( origin, code, message )`, and
   writes into an ended stream report `Closed`.
3. **Elm.**
   - Part A's types and their mapping from the kernel strings.
   - One `toKind` per module, `errorKind`, `fromStreamFailure`, and `InitError.error`.
   - Remove `errorCode` and `errorIs*`.
4. **Migrate callers.**
   - The package's tests (`system-kernel-cpp/tests`, e.g. `HandshakeTest`).
   - The `test/eco-system` E2E tests that use `Http.Server`, `Http.Stream`, `Socket.*`,
     `WebSocket` or stream errors.
   - `examples/src` (`HttpEcho.elm`, `WsChat.elm`, `WsEchoServer.elm`).
   - Every match on a reason string or code. The `test/elm-http` tests use stock elm/http and are
     unaffected.
5. **Tests.**
   - Unit tests for `Http.Method.fromString` / `toString` round trips (including `OPTIONS` and
     `UNKNOWN`), the TLS version mapping, each `toKind` mapping, and each `fromStreamFailure`, on
     both backends.
   - E2E tests: an OPTIONS request, a non-WebSocket upgrade (`UnknownUpgrade`), a reset socket
     read, a WebSocket heartbeat timeout, a write after close, a file stream failure, and
     Unix-socket path failures (connect to a missing path, listen in a missing directory, and
     listen under a path component that is a file).
6. **Gates.** `elm-tests`, `eco-system-elm-tests`, `--target full` (JIT + JS E2E), and the
   `docs.json` equality check against ecosyskernel.
