# Plan: WebSockets, and `Http.Server` on the reactor with TLS and HTTP/2

Status: **implemented** (2026-10-08; WS0–WS10 done, §10). Plan v2.1 (v2.1 applies the user's answers to §7: W8 context
takeover opt-in, W19 no default connection/stream caps). History: v1 outline (decisions W1–W14) → fact
verification (§2) → two adversarial reviews (native `Http.Server`/HTTP/2; WebSocket API/codec/JS/
tests; §9) → v2. §10 is the progress log.

This plan extends `eco/system` (`plans/eco-system-library.md`, "the base plan") and builds on the
sockets work (`plans/eco-system-sockets.md`, "the sockets plan"). All their rules apply and are not
repeated: base plan §3.2 (boundary rules B1–B8), §3.3 (GC rules G1–G15, templates T1–T9, gates),
§3.4 (keep-alive rule), §3.6 (C++ managers), D13 (docs generator), D15 (JS target); sockets plan
§3.3.1 (IoReactor rules 1–7), §3.3.3 (`Conn`, `Transport`), §3.4 (delivery rule and held FIFOs),
SD13 (Elm is the only address printer), Appendix E (JS conventions, plain property names across
kernel files). **Read base plan §3.3 and sockets plan §3.3 before writing C++ here.**

How to read: §0 decisions, §1 scope, §2 verified facts, §3 architecture, §4 phases (files, steps,
tests, exit criteria), §5–§8 test strategy, ordering, open questions, risks; Appendices A (public
API, normative), B (kernel catalogue, normative), C (manager layouts, normative), D (protocol
behaviour, normative), E (JS notes), F (conformance recipes).

---

## 0. Decisions

| # | Decision |
|---|---|
| W1 | Module **`WebSocket`** (top level), plus the unexposed `WebSocket.Internal` and `WebSocket.Internal.Handshake` (pure Elm). |
| W2 | **Server side both ways, one `Upgrade` type:** socket level `WebSocket.upgradeRequest : Socket.Connection -> Task Socket.Error Upgrade`, and HTTP level `Http.Server.upgradeRequest : Request -> Response -> Task Socket.Error WebSocket.Upgrade` (HTTP/1.1 Upgrade and HTTP/2 extended CONNECT). Both are answered with `WebSocket.accept` / `acceptStreamed` / `reject`. *(Refines v1's `Http.Server.upgrade`: review J16 — the `Request` record cannot carry repeated headers or h2's `:protocol`, so the kernel keeps the raw request.)* |
| W3 | **Subscriptions** `onMessage` (Whole mode only) and `onClose`. While a connection has an `onMessage` subscriber, a *subscription reader* is attached to its readable: messages go to every subscriber in subscription order and are consumed; `Stream.read` fails `Locked`. With no subscriber, messages stay in the readable. Subscribing waits until no read is parked and the readable is not piped (§3.6). |
| W4 | **Close reporting:** a clean close ends the readable with `Closed`; an abnormal end fails reads with `Cancelled reason`. `closed : WebSocket mode -> Task x CloseInfo` always completes with `{ code, reason, clean }` (`Abnormal`/1006 and `clean = False` when no Close frame was received). |
| W5 | **Heartbeat on by default**, per connection: `heartbeat : Maybe Heartbeat`, default `Just { interval = 30000, timeout = 30000 }`. Liveness is counted in **received bytes**, not frames; the pong deadline is suspended while local backpressure has paused reading. On timeout: send Close 1001 best effort, report `Abnormal`. Pongs to pings are always automatic. Explicit `ping : WebSocket mode -> Task Socket.Error Int` (round-trip ms, matched by a unique 8-byte payload). |
| W6 | **One message type** `Message = Text String \| Binary Bytes`, both kinds interleaved in order (opcode is per message, RFC 6455 §5). |
| W7 | **Streaming large messages** with WebSocket's own fragmentation (RFC 6455 §5.4). The mode is **in the type**: `WebSocket mode` with uninhabited markers `Whole` and `Streamed`; `connect`/`connectStreamed`, `accept`/`acceptStreamed`. `Whole`: `readable : WebSocket Whole -> Readable Message`. `Streamed`: `streamedReadable : WebSocket Streamed -> Readable StreamedMessage` with nested body readables. Sending a long message in either mode: `sendText : Readable String -> …`, `sendBinary : Readable Bytes -> …`. Fragment boundaries are never exposed. *(Refines v1's `messages` field: Elm record update cannot change a phantom type, review J10.)* |
| W8 | **permessage-deflate in v1** (RFC 7692), negotiated in pure Elm (`WebSocket.Internal.Handshake`), executed by a dedicated deflate engine per backend (§2 WF6). **On by default**: clients offer it, servers accept it. **Context takeover is opt-in** (user decision 2026-10-08): by default both directions use no context takeover (each message compressed on its own, about 64 KB of zlib state per connection only while a message is being processed — §3.7). |
| W9 | **`Http.Server` moves onto the IoReactor**: no accept or connection threads; HTTP/1.1 keep-alive with **one request in flight per connection**; request body, header, connection and time limits; `closeServer`. `createServer { host, port_ }` keeps working; `createServerWith` adds the options. |
| W10 | **TLS for `Http.Server`** (https, and so wss) through `EcoSystem_Tls`; ALPN chosen by the server (`h2`, `http/1.1`), with *no-ACK fallback* to HTTP/1.1 when a client offers nothing we support. |
| W11 | **HTTP/2 in `Http.Server`** over TLS (ALPN `h2`) on **nghttp2 1.70.0**, vendored like llhttp (§2 WF3). No h2c. |
| W12 | **WebSockets over HTTP/2** (RFC 8441): **server** in `Http.Server` (extended CONNECT), and an **opt-in client** (`http2 = True` in `ConnectOptions`): ALPN `h2`, wait for the server's SETTINGS, use extended CONNECT if `SETTINGS_ENABLE_CONNECT_PROTOCOL = 1`, otherwise fall back to HTTP/1.1 Upgrade on the same TLS connection when ALPN chose `http/1.1`, or on a new connection. One h2 connection per client WebSocket (no pool). |
| W13 | Errors reuse **`Socket.Error`**: new codes `ERR_WS_HANDSHAKE` (with the HTTP status available through `handshakeStatus : Socket.Error -> Maybe Int`), `ERR_WS_PROTOCOL`, `ERR_HTTP2_*`; predicate `errorIsHandshakeFailed`. Codec failures reach streams as `Cancelled "<CODE>: <text>"` (Appendix D.9). |
| W14 | **Close codes** `Normal 1000 \| GoingAway 1001 \| ProtocolError 1002 \| UnsupportedData 1003 \| NoStatus 1005 \| Abnormal 1006 \| InvalidData 1007 \| PolicyViolation 1008 \| MessageTooBig 1009 \| MandatoryExtension 1010 \| InternalError 1011 \| Other Int`. `NoStatus` and `Abnormal` are receive-only. `close : CloseCode -> String -> WebSocket mode -> Task Socket.Error ()` fails `EINVAL` for an unsendable code (allowed: 1000–1003, 1007–1014, 3000–4999) and truncates the reason to 123 bytes on a UTF-8 boundary. |
| W15 | **`Http.Server.Request` gains `version : HttpVersion` and `upgrade : Maybe String`** (`HttpVersion = Http1_0 \| Http1_1 \| Http2`; `upgrade` = the lower-cased protocol a request asks to switch to: HTTP/1.1 `Upgrade` token, or h2 `:protocol`). This changes a public record: accepted because eco/system has not been released (still 1.0.0, never published). *(Review N2.)* |
| W16 | **Stream kernel additions** (both backends): *value-mapped channel pairs* that apply an Elm closure to each tagged chunk (read) or value (write), and a *subscription reader* that can be attached and detached. These carry `Message` values across the kernel boundary without kernels building Elm ADTs (B1). *(Review J1, J2, J8.)* |
| W17 | **`Conn` gets pluggable protocols:** a `ConnProtocol` interface on the reactor (stream faces, HTTP/1.1, HTTP/2, WebSocket) with several timers per connection and a hand-off (`setProtocol`) that passes leftover bytes. *(Review N1, J15.)* |
| W18 | Conformance (Autobahn|Testsuite, h2spec) runs **locally only**, from scripts that install their tools under `/tmp` (Appendix F); never in CI. |
| W19 | **No default caps on connections or HTTP/2 streams** (user decision 2026-10-08): `maxConnections` and `maxConcurrentStreams` are `Maybe Int`, default `Nothing` (unlimited); applications set them. There is no separate cap for WebSocket streams over HTTP/2. Size limits and timeouts keep their defaults (§7). |

## 1. Scope

**In scope:** Appendix A natively on Linux and macOS (macOS untested, as the rest of eco/system) and
on the JS target (Node ≥ 22); local conformance runs; docs and examples.

**Out of scope:** WebSockets over HTTP/3 (RFC 9220); HTTP/2 server push (`ENABLE_PUSH = 0`); h2c
(HTTP/2 without TLS); HTTP/2 in elm/http or `Http.Stream`; a client h2 connection pool; WebSocket
extensions other than permessage-deflate; redirects and proxies for the WebSocket client; SNI
callbacks (one certificate per server); Windows (compile stubs failing `ENOTSUP`, as base plan §1).

## 2. Verified facts

Checked 2026-10-08 (Node v22.23.3, zlib 1.2.13, OpenSSL 3.0.20, nghttp2 sources 1.70.0). Probes are
in `/tmp/ws-facts/` and `/tmp/ws-review/`.

| # | Fact | Status, evidence |
|---|---|---|
| WF1 | Today's `Http.Server`: one accept thread per server, one thread per connection (`HttpServerService.hpp`), llhttp paused at `on_message_complete` (`HttpServerService.cpp:437-440`), unbounded body (`:432-435`), 100-continue sent on headers (`:572-579`), response always `Connection: close` and the user's `Connection` header dropped (`:214-216,233`), user 1xx final statuses passed through (`:203`), URL from the *first* `Host` but the Elm Dict keeps the *last* (`:447-450`, `Server.elm:204-211`), scheme hard-coded `http://`, `respond` completes after a linger close of up to 2 s (`:625-628`), bytes after a request discarded (`:562-566`), the server's keep-alive count never released (`HttpServer.cpp:198-199`), parked requests in a static map not keyed on heap generation (`HttpServerManager.cpp:136`). | verified (review N) |
| WF2 | Static/vendored curl is built with `USE_NGHTTP2 OFF` (`CMakeLists.txt:342`, inside `if(ECO_STATIC OR WIN32)`); no HTTP/2 code exists in the repo. The container has only the runtime `libnghttp2.so.14` 1.52.0, no headers. | verified |
| WF3 | **nghttp2 1.70.0** (MIT; sha256 `aa317e2cf9dca6afa0aed68f8fad6ff303ec6982e25a78c75c0b65e2b9b3ded5`) supports RFC 8441 since 1.34: a server accepts `:protocol` only after submitting `NGHTTP2_SETTINGS_ENABLE_CONNECT_PROTOCOL` (0x08); a client is **not** checked by the library and must read `nghttp2_session_get_remote_settings(…ENABLE_CONNECT_PROTOCOL)` itself. The `nghttp2_ssize` "…2" API (`mem_recv2`, `mem_send2`, `submit_response2`, `data_provider2`) exists since 1.60 (the `ssize_t` API is deprecated). A user-driven, socket-free session round trip (extended CONNECT, 200, DATA both ways, `NGHTTP2_ERR_DEFERRED` + `resume_data` backpressure, END_STREAM) works. Builds as an OBJECT library from `lib/*.c` (26 files) with a generated `nghttp2ver.h` (Route B, zero warnings). | verified (`/tmp/ws-facts/ngbuild`, `/tmp/ws-facts/ngobj`) |
| WF4 | Node 22: an `'upgrade'` listener receives **all** upgrade requests (raw socket + `head`; the server writes nothing; declined upgrades need raw HTTP written by us; `shouldUpgradeCallback` only from 22.21); without a listener upgrades go to `'request'`. `http2.createSecureServer({ allowHTTP1: true })` serves h2, HTTP/1.1 and no-ALPN clients on one port and still emits `'upgrade'` for HTTP/1.1. With `settings: { enableConnectProtocol: true }`, extended CONNECT arrives on **`'connect'`** (compat API) or `'stream'` with `:protocol`; **without a `'connect'` listener Node answers 405**. The h2 client must await `'remoteSettings'` and check `remoteSettings.enableConnectProtocol` (a request to a server without it fails with `NGHTTP2_PROTOCOL_ERROR`). Node's global `WebSocket` (undici) lacks ping RTT, fragments and backpressure: not used. | verified |
| WF5 | SHA-1 + base64 for `Sec-WebSocket-Accept`: OpenSSL natively (already linked), `node:crypto` on JS. | verified |
| WF6 | **The base plan's zlib codecs are not reusable** for permessage-deflate: `StreamCodec.cpp` has fixed windowBits, only `Z_NO_FLUSH`/`Z_FINISH`, no reset, and fails on a sync-flushed stream; JS `_Stream_zlibCodec` likewise. The technique is verified: raw deflate + `Z_SYNC_FLUSH` per message, strip the trailing `00 00 ff ff`, append it before inflating; context takeover = keep the stream, no takeover = `deflateReset`/`inflateReset`; RFC 7692 §7.2.3.2 bytes reproduce ("Hello" → `f2 48 cd c9 c9 07 00`). **windowBits 8:** zlib refuses raw `-8` for deflate; deflating with 9 is safe for an 8-bit peer window (max match distance 250 < 256; probe decoded correctly) — Node does the same; inflate always uses 15. → WS7 writes a dedicated engine. | verified (`/tmp/ws-facts/py/pmd.py`) |
| WF7 | RFC 8441: clients still mask (the h2 stream is used "as if it were the TCP connection" of RFC 6455; §1, §5); no `Sec-WebSocket-Key`/`Accept`, `Connection`/`Upgrade` MUST NOT be sent; `:protocol = websocket`, `:scheme` https/http; `sec-websocket-version: 13`, `-protocol`, `-extensions`, `origin` are used; success is any 2xx (server sends 200); orderly close = `END_STREAM`, abort = `RST_STREAM(CANCEL)`; setting value 0 or 1, never 1 → 0. RFC 9220 suggests 501 for an unknown `:protocol`. RFC 6455: fragmentation purpose (§5.4), control frames may be interleaved, intermediaries may re-fragment, control payload ≤ 125 (so close reason ≤ 123), 1005/1006/1015 never sent, 1004 reserved. | verified (`/tmp/ws-facts/rfc/`) |
| WF8 | Conformance: no docker/podman/Go here; network works. **Autobahn|Testsuite 25.10.1** runs from a portable PyPy 2.7 under `/tmp` (recipe Appendix F), both `fuzzingclient` and `fuzzingserver` modes. **h2spec 2.6.0** static binary runs; a plain Node h2 server scores 128/146, so h2spec is a *baseline to compare*, not an all-green gate. | verified |
| WF9 | `Conn` is `final`, reads only on face requests, delivers to the main thread, uses its single reactor timer for connect/handshake/drain (`Socket/Conn.hpp:124`, `Conn.cpp:555-590,843-861`); `ListenerHandler` is `final` and posts `Accepted` to the main thread (`Listener.cpp:139-144`); the reactor allows one timer per handler. | verified (review N1) |
| WF10 | `ChannelResult` carries only bytes; `channelDispatch` always builds `Bytes` (`ByteChannel.hpp`, `Stream.cpp:609,629`); a stream's `readLock` exists only while a read is parked and `pipedOut` is permanent: there is no attach/detach lock. | verified (review J1, J8) |
| WF11 | The TLS server's ALPN select callback sends a fatal alert when nothing overlaps (`Tls/TlsContext.cpp:212-233`); `Socket.Tls.ServerOptions` carries the user's `alpn` list. | verified (review N13) |
| WF12 | The E2E harnesses cannot start peer processes; a test's peers must be in the same Elm program (raw clients over `Socket.Tcp`/`Socket.Tls`), or a process the test spawns with `System.Process` (system `curl` 7.88.1 has HTTP/2; `node` is available). | verified (review J18, N17) |

---

## 3. Architecture

### 3.1 Module map and imports

| Elm module | Exposed | Effect (manager key) | Kernel home | C++ library |
|---|---|---|---|---|
| `WebSocket` | yes | yes — `"WebSocket"` (`OnMessage`, `OnClose`) | `WebSocket` | `EcoSystem_WebSocket` |
| `WebSocket.Internal` | no | no | — | — |
| `WebSocket.Internal.Handshake` | no | no | none (pure Elm, elm/core only: SF18 of the sockets plan) | — |
| `Http.Server` | yes (changed) | yes — `"Http.Server"` (layout changes, C.1) | `HttpServer` | `EcoSystem_HttpServer` (+ llhttp, + nghttp2) |
| `Http.Server.Response` | yes (unchanged API) | no | `HttpServer` | |
| `Stream` | yes (no API change) | no | `Stream` (kernel additions W16) | `EcoSystem_Stream` |

Imports (acyclic): `WebSocket.Internal.Handshake` → `Socket.Address`; `WebSocket.Internal` →
`Stream.Internal`, `Socket.Internal`, `Socket.Address`; `WebSocket` → `WebSocket.Internal`,
`WebSocket.Internal.Handshake`, `Socket`, `Socket.Tls`, `Stream`; `Http.Server` → `WebSocket`,
`WebSocket.Internal`, `Socket`, `Socket.Tls`, `Socket.Address`. `WebSocket` never imports
`Http.Server`.

C++ libraries: `EcoSystem_WebSocket` links `EcoSystem_Socket`, `EcoSystem_Tls`, `EcoSystem_Stream`,
OpenSSL (SHA-1, RAND) and zlib. `EcoSystem_HttpServer` links `EcoSystem_Socket`, `EcoSystem_Tls`
and `EcoSystem_WebSocket` (h1/h2 upgrade hand-off). `ECO_SYSTEM_MODS += WebSocket`.

### 3.2 `Conn` protocols (W17, phase WS1)

Refactor `Socket/Conn.{hpp,cpp}` (reactor thread only, sockets plan §3.3.3):

```cpp
class ConnProtocol {                         // reactor thread; never touches the heap (G1)
public:
    virtual ~ConnProtocol() = default;
    virtual void onOpen(Conn& c) {}          // after connect / accept (+ TLS handshake)
    virtual void onData(Conn& c, std::string_view bytes) = 0;   // plaintext from the transport
    virtual void onEof(Conn& c) = 0;         // peer FIN (after TLS close_notify / unexpected EOF)
    virtual void onError(Conn& c, int err, const std::string& code) = 0;
    virtual void onWritable(Conn& c) {}      // outbound fell below the low watermark
    virtual void onTimer(Conn& c, int timerId) {}
    virtual void onCloseAll(Conn& c) = 0;    // embed stop / heap reset: abort now
    virtual bool wantsRead() const = 0;      // read interest (demand-driven, sockets rule 1)
};

class Conn : public IoHandler {
public:
    void setProtocol(std::unique_ptr<ConnProtocol> p, std::string leftover);   // hand-off
    void write(std::string bytes, std::function<void(int err)> done);          // queued, in order
    size_t outbound() const;                 // bytes queued, for watermarks
    void updateInterest();                   // re-evaluate read/write interest
    void setDeadline(int timerId, int64_t monoMs);   // 0 cancels; reactor timer = min over ids
    void shutdownWrite();                    // TLS close_notify + SHUT_WR (existing logic)
    void closeGraceful(int64_t drainMs);     // SHUT_WR, discard input until EOF or deadline, close
    void abort(bool reset);                  // existing abort / SO_LINGER{1,0}
    const TlsInfo* tlsInfo() const;          // after handshake (ALPN chooses h1/h2)
};
```

- The existing stream faces become `FaceProtocol` (today's `readReqs`/`writeQ` logic moves there
  unchanged); `Socket` connections use it, so every sockets test must stay green (gate of WS1).
- Several timers per `Conn` are multiplexed onto the one reactor timer (`setDeadline` keeps a small
  array of deadlines; `onTimer` dispatches the expired ids). Ids: 0 connect/handshake, 1 drain,
  2 idle/keep-alive, 3 headers, 4 request, 5 heartbeat, 6 pong, 7 close-handshake.
- `ListenerHandler` gains a **callback mode**: instead of posting `Accepted`, it calls a
  reactor-side factory `std::function<std::unique_ptr<ConnProtocol>(Conn&)>` (HTTP servers). Credit
  in callback mode is `maxConnections - open` when `maxConnections` is set, else unlimited.
- **Hand-off rules** (`setProtocol`): only between protocol callbacks on the reactor thread; the
  new protocol's `onData(leftover)` runs first if `leftover` is non-empty (bytes read past the
  upgrade request or 101 response, plus TLS plaintext still buffered by the transport).
- `Socket.Connection` → WebSocket (socket-level path): the faces must have no parked operation
  (else `EBUSY`); afterwards the old streams fail `Cancelled "upgraded to WebSocket"`; `Socket.close`
  on the old `Connection` aborts the WebSocket.

### 3.3 Stream kernel additions (W16, phase WS1)

C++ (`Stream/Stream.hpp`, `StreamTable.hpp`, `Stream.cpp`, `Core/ByteChannel.hpp`):

```cpp
struct ChannelResult { /* existing fields */ int64_t tag = 0; bool text = false; };
class ByteChannel { /* existing */
    // Tagged write: default implementation forwards to requestWrite when tag == 0.
    virtual void requestWriteTagged(uint64_t token, int64_t tag, bool text, std::string bytes);
};
// A readable whose values are fromWire (tag, text ? String : "", text ? empty : Bytes) — the
// closure is applied on the main thread when a chunk is enqueued (G11); its result is the value.
int64_t createMappedSource(ByteChannel* ch, uint64_t fromWireEnc);
// A writable whose accepted values are passed to toWire (a -> ( Int, String, Bytes )) and
// written with requestWriteTagged; the write completes when the channel completes it.
int64_t createMappedSink(ByteChannel* ch, uint64_t toWireEnc);
// Subscription reader: chunks bypass readQ and fromWire and go to `fn` as POD; reads fail
// Locked while attached. attach fails (returns false) while a read is parked or the pair is
// piped; detach returns the pair to normal reading (later chunks queue as usual).
using ReaderFn = void (*)(int64_t pairId, ChannelResult& r, void* ctx);
bool attachReader(int64_t pairId, ReaderFn fn, void* ctx);
void detachReader(int64_t pairId);
```

- `StreamPair` gains `uint64_t mapFnEnc` (scanned with `forEachWord`, G9) and `ReaderFn reader`.
- A mapped source requests reads only while `readQ` is below capacity (1) or a reader is attached
  (then as fast as the reader takes them — the WebSocket manager delivers synchronously).
- JS (`Stream.js`): `_Stream_createMappedSource(channel, fromWire)`, `_Stream_createMappedSink(
  channel, toWire)`, `_Stream_attachReader(id, fn)`, `_Stream_detachReader(id)`. Channel chunks for
  mapped pairs are plain objects `{ tag, text, bytes }` (plain property names, sockets plan S6c).
- Tests (WS1): Core unit tests for mapped source/sink (values, backpressure, errors, erase) and
  attach/detach (parked read → refuse; piped → refuse; detach then read); an Elm E2E test via a
  test-only kernel is not needed: WS4's tests exercise them end to end.

### 3.4 `Http.Server` on the reactor (W9, phase WS2)

**Listening.** `createServer { host, port_ }` keeps today's `listenOn` (name lookup, IPv4 first, the
error text `HttpServerStartErrorTest` checks) but makes the socket non-blocking and hands it to a
`ListenerHandler` in callback mode. `createServerWith` takes an `Address` (sockets plan SD3) and the
options (Appendix A.2); it returns the bound port (`port_ = 0` works).

**Per connection, `Http1Protocol`** (C++ `HttpServer/Http1.{hpp,cpp}`), state machine:

```
ReadingHead → ReadingBody → AwaitingElm → Writing → Idle (keep-alive) → ReadingHead …
                                   ↘ UpgradePending → (hand-off) Upgraded | Writing (declined) → Closing
any state → Closing (error, limit, timeout, server close, peer EOF after the last response)
```

- **One request in flight** (decided): llhttp is paused at `on_message_complete`; reading stops
  (`wantsRead` false) until the response is fully queued; then `llhttp_resume` and parse the
  remaining buffered bytes. Pipelined requests therefore get answered in order; a slow Elm handler
  back-pressures the client through TCP.
- **Limits** (Appendix A.2 defaults): header block ≤ `maxHeaderSize` (431); body ≤ `maxBodySize`
  (413 + close; checked against `Content-Length` before any 100-continue, and as a running total for
  chunked bodies); `maxConnections` when set (listener credit; default unlimited, W19).
- **Timeouts** (Conn timers): `headersTimeout` from the first byte of a request to the end of its
  headers (408 + close), `requestTimeout` from the first byte to the end of the body (408 + close),
  `keepAliveTimeout` while `Idle` (close silently). There is no timeout on Elm's answer (the client
  may close; `respond` on a dead key completes at once).
- **Expect: 100-continue:** sent when the request reaches the head of the pipeline and the length is
  acceptable; never before an earlier response; `Expect` values other than `100-continue` → 417.
- **Host and URL (E.5 revised):** HTTP/1.1 without `Host`, with two `Host` headers, or with invalid
  syntax → 400. Scheme `https://` under TLS. The URL authority is the `Host` value.
- **Request smuggling:** llhttp in strict mode (no lenient flags ever); after any parse error: 400 +
  `Connection: close` + linger close (today's behaviour).
- **Responses** (`serializeH1(resp, {isHead, keepAlive, http10})`): `Connection: keep-alive`/`close`
  decided per request (`llhttp_should_keep_alive`, server closing, the user's `Connection: close`,
  HTTP/1.0 without keep-alive); a user final status 100–199 (and 101 outside an upgrade) → 500; the
  rest of today's rules (Content-Length, Date, HEAD/204/304, dropped hop-by-hop headers, CR/LF/NUL
  filtering) unchanged.
- **Upgrade and CONNECT:** at `on_message_complete` record `parser->upgrade`. An upgrade request is
  delivered as a `Request` with `upgrade = Just token` (first `Upgrade` token, lower-cased, when
  `Connection` contains `upgrade`); the connection enters `UpgradePending`: no parsing, no reading,
  the *head* (`buf[llhttp_get_error_pos() .. n)` after `llhttp_resume` returns
  `HPE_PAUSED_UPGRADE`, plus transport-buffered plaintext) kept. `Http.Server.upgradeRequest` hands
  it to WebSocket (§3.5); any other response to an upgrade request or CONNECT is written with
  `Connection: close` and the connection closes (never `llhttp_resume_after_upgrade`, so `h2c`
  smuggling is impossible). An upgrade request with a body is treated as a normal request whose
  upgrade is refused.
- **Half-closed client:** after the peer's FIN, finish the in-flight request and any already-parsed
  pipelined requests, then close.

**Main-thread tables** (`HttpServer/HttpTables.{hpp,cpp}`, keyed on heap generation, no HPointers):
- `HttpServers`: id → `{ listener, flags (tls, http2), boundPort, closed, closeToken, deadline }`.
- `HttpKeys`: key → `{ serverId, weak_ptr<Conn>, seq or h2 streamId, isHead, version, flags,
  upgradeCopy (raw request line, headers with duplicates and original case, head bytes) }`.
- Events (POD queue + drain): `Request`, `RespondDone`, `ConnGone{keys}`, `ServerClosed`.

**`respond`** keeps its ABI; it completes when the transport accepted the bytes (no 2 s wait). A key
whose connection is gone completes at once. `upgradeRequest` consumes the key; a later `send` on that
`Response` is ignored.

**`closeServer`** (graceful with a deadline, default 5 s): stop accepting (free the port), answer
parked requests 503 + close, close idle keep-alive connections at once, let in-flight requests finish
with `Connection: close`, h2: GOAWAY (last stream id) then let open streams finish; at the deadline
abort the rest. Upgraded (WebSocket) connections are detached and stay open (Node's behaviour).
The task completes when the listener is closed and the deadline work is scheduled.

**Keep-alive counts:** the server holds 1 until `ServerClosed`; each delivered-but-unanswered request
holds 1 (released by `respond`, `upgradeRequest`, or `ConnGone`); idle keep-alive connections hold 0.

**Manager (C.1):** the tagger argument becomes `((method, url), (headers, body), (key, flags,
upgradeToken))`. Parked requests (no subscriber) move into `HttpTables`, bounded by bytes per server
(`maxBodySize × 4`; beyond it answer 503), and are cleared on a new heap generation.

### 3.5 TLS and ALPN for `Http.Server` (W10, phase WS3)

- `ServerOptions.tls : Maybe Socket.Tls.ServerOptions`; its `alpn` field is **ignored** (documented):
  the server sets `["h2", "http/1.1"]` when `http2`, else `["http/1.1"]`.
- `Tls/TlsContext` gains a server mode **`alpnFallback = NoAck`**: on no overlap the select callback
  returns `SSL_TLSEXT_ERR_NOACK` (no ALPN → HTTP/1.1) instead of a fatal alert. `Socket.Tls.listen`
  keeps the fatal alert.
- After the handshake the factory reads `Conn::tlsInfo()->alpn`: `"h2"` → `Http2Protocol`, else
  `Http1Protocol`.
- With `http2`, TLS 1.2 cipher suites are restricted to ECDHE + AEAD (RFC 9113 §9.2.2); TLS 1.3 is
  unaffected. `http2 = True` with `tls = Nothing` → `createServerWith` fails `EINVAL`.

### 3.6 WebSocket core (phase WS4)

**Elm** (`WebSocket`, `WebSocket.Internal`, `WebSocket.Internal.Handshake`):
- `Handshake` (pure, unit-tested with elm-test-rs): WebSocket URL parser (`ws`/`wss`, case-insensitive
  scheme, `[IPv6%25zone]` via `Socket.Address`, ports 0–65535 with defaults 80/443, path default
  `/`, query kept, fragment or userinfo → `EINVAL`); `Host` header (`host` or `host:port` unless the
  default port; IPv6 bracketed, no zone); token-list parsing (case-insensitive); protocol tokens
  validated as RFC 9110 tokens; the extension header grammar; permessage-deflate negotiation in both
  roles (RFC 7692 §7.1, Appendix D.7); building the request and the 101/200 response headers;
  validating a response and a request (Appendix D.2, D.3).
- `Internal`: `WebSocket mode = WebSocket { id, readable : Int, writable : Int, protocol : Maybe
  String, compression : Maybe Negotiated, local : Endpoint, remote : Endpoint }`; `Upgrade { id,
  method, target, version, headers : List ( String, String ), expectedAccept : String, isH2 : Bool,
  remote : Endpoint }`; `fromWire : ( Int, String, Bytes ) -> Message` (tag 1 text, 2 binary);
  `fromWireStreamed : ( Int, String, Bytes ) -> StreamedMessage`: a streamed message arrives as
  `( 3, bodyIdText, emptyBytes )` (text) or `( 4, bodyIdText, emptyBytes )` (binary) where
  `bodyIdText` is the decimal id of the body's readable pair, and becomes `StreamedText (Readable
  id)` / `StreamedBinary (Readable id)`; `toWire : Message -> ( Int, String, Bytes )` (tag 1 text,
  2 binary).
- `WebSocket`: the public API (Appendix A.1) and the JS manager body.

**C++ codec** (`WebSocket/WsProtocol.{hpp,cpp}`: a `ConnProtocol`; `WebSocket/WsFrame.{hpp,cpp}`:
pure frame parser/serializer, unit-testable; `WebSocket/WsDeflate.{hpp,cpp}`: §3.7):
- **Connection state:** `Open → CloseSent | CloseReceived → Closing (TCP) → Closed`.
- **Reader:** `Header` (2–14 bytes) → `Payload { remaining, maskKeyOffset }`. Control frames are
  buffered (≤ 125) and handled at once (ping → priority pong with the same payload; pong → match a
  pending `ping`; close → validate, echo once, enter `CloseReceived`). Data: message state
  `Idle | InMessage { opcode, rsv1, utf8State, size }`; `Whole`: append to a message buffer, check
  `maxMessageSize` against the frame header **before** buffering (1009), UTF-8 validated
  incrementally and failing fast at the first bad byte (1007); `Streamed`: emit body chunks to the
  current body channel, split text at code-point boundaries. Inflate in bounded steps (≤ 64 KiB out
  per step). Reading pauses when the outbound application queue (results not yet consumed by Elm) is
  above the high watermark; the pong deadline is suspended while paused.
- **Writer:** three lanes: control (pong, ping, close) first, then the data FIFO, then the active
  outgoing-stream (fragments; data messages written meanwhile queue behind it). Client frames masked
  with keys from a pooled `RAND_bytes` buffer. Deflate per Appendix D.7.
- **Timers** (`Conn::setDeadline`): heartbeat interval, pong timeout, close handshake (30 s, server
  closes TCP first; client waits for FIN), handshake (client connect).
- **Results to the main thread:** `ChannelResult { tag, text, bytes }` on the mapped source (tags in
  Appendix B.1); `WsEvent { Closed{code, reason, clean}, PingDone{token, rtt}, … }` on the WebSocket
  event queue (a new POD queue + drain, sockets plan §3.3.2 pattern).
- **Keep-alive counts:** one per `onMessage` or `onClose` subscription; one per parked read, write,
  `closed`, `ping` or outgoing stream; one while the close handshake runs. Heartbeat timers hold none
  (an idle client with no subscription and nothing parked lets the program exit).

**Handshake execution:**
- *Client* (`connect`): Elm parses the URL, builds the request headers (Handshake), does
  `Socket.lookup` (not cancellable; documented), then calls kernel `dial` with all addresses and the
  remaining time: the reactor tries each address in order, does TLS (verification and SNI from the
  options; ALPN `h2,http/1.1` if `http2`), writes the request, reads the response head (≤ 64 KiB),
  all under one deadline. Elm validates the response (Handshake) and calls `open` with the negotiated
  parameters; the leftover bytes after the head go to the codec.
- *Server, socket level* (`WebSocket.upgradeRequest conn`): kernel `readUpgrade` takes the `Conn`
  (§3.2 rules), reads the request head (≤ 64 KiB, within a fixed, documented 30 s: WS4 removed
  `AcceptOptions.handshakeTimeout`, §10), returns it raw; Elm builds the `Upgrade`. *HTTP level* (`Http.Server.upgradeRequest`): kernel `takeUpgrade key` returns the same
  shape from `HttpKeys.upgradeCopy`.
- *Accept*: Elm validates the request (Appendix D.3; failure → `reject` 400/426 and `ERR_WS_HANDSHAKE`),
  negotiates protocol and compression, then kernel `open` writes the 101 (or h2 200) and switches the
  connection's protocol to `WsProtocol`. For HTTP/1.1, the 101 is written only after every earlier
  pipelined response was flushed (guaranteed by one-in-flight). `reject` writes the status, headers
  and body, then closes.

**Manager `"WebSocket"`** (C.2): registry wsId → `{ msgTaggers, closeTaggers, readerAttached,
heldClose }` (taggers encoded, scanned). First `OnMessage` → `attachReader` (retried each `onEffects`
until it succeeds, if a read is parked); last removed → `detachReader`. The reader callback builds the
`( Int kind, String, Bytes )` tuple once (rooted) and calls every tagger (T8, G12). `OnClose`: deliver
`CloseInfo` once; if the connection closed with no subscriber, hold the event and deliver it to the
first subscriber (SD14 pattern). JS: real Elm manager bodies with JS-only kernels.

### 3.7 permessage-deflate engine (W8, phase WS7)

`WebSocket/WsDeflate.{hpp,cpp}` (C++, zlib directly) and the JS twin in `WebSocket.js`
(`zlib.createDeflateRaw`/`createInflateRaw` driven synchronously through the zlib handle, as
`Stream.js` does):
- Deflate: `deflateInit2(Z_DEFAULT_COMPRESSION, Z_DEFLATED, -max(9, bits), 8, Z_DEFAULT_STRATEGY)`;
  per message (or per outgoing-stream chunk): `deflate(Z_SYNC_FLUSH)`; at the end of the message
  strip a trailing `00 00 ff ff` if present; empty message → payload `00`; no context takeover →
  `deflateReset` after each message.
- Inflate: `inflateInit2(-15)`; append `00 00 ff ff` at the end of each message; inflate in steps of
  ≤ 64 KiB output, checking the running size against `maxMessageSize` (Whole) inside the loop
  (compression bombs → 1009); a block with BFINAL inside a message is accepted (RFC 7692 §7.2.3.4)
  and the stream re-initialised; no context takeover → `inflateReset` after each message.
- Messages below `threshold` bytes (default 64) are sent uncompressed (RSV1 is per message).
- **Context takeover is opt-in** (W8). Server policy (`ServerCompression`): `maxWindowBits`
  (default 15), `contextTakeover` (default `False`: the response always carries
  `server_no_context_takeover` and `client_no_context_takeover` — RFC 7692 lets a server include the
  latter even when the client did not offer it; `True`: takeover allowed in each direction the client
  did not restrict), `threshold`. Client offer (`ClientCompression`): by default offers
  `server_no_context_takeover` and `client_no_context_takeover`; `contextTakeover = True` offers
  neither. Without takeover the zlib streams are reset after every message; their buffers are
  allocated per connection but stay small and cold (documented: with takeover, about 300 KB per
  connection at 15 bits). CRIME/BREACH note: do not mix secrets with
  attacker-controlled data in one compressed connection.
- Streamed bodies: compressed/decompressed incrementally; a skipped (cancelled) body is still
  inflated (to keep the window in sync) and validated as UTF-8, and its output discarded.

### 3.8 HTTP/2 in `Http.Server` (W11, phase WS8)

**Build:** `system-kernel-cpp/CMakeLists.txt`, under `if(NOT WIN32)`: `FetchContent_Declare(nghttp2
URL https://github.com/nghttp2/nghttp2/releases/download/v1.70.0/nghttp2-1.70.0.tar.gz URL_HASH
SHA256=aa317e2cf9dca6afa0aed68f8fad6ff303ec6982e25a78c75c0b65e2b9b3ded5 DOWNLOAD_EXTRACT_TIMESTAMP
TRUE SOURCE_SUBDIR eco-no-cmake)`; `configure_file(lib/includes/nghttp2/nghttp2ver.h.in …)` with
`PACKAGE_VERSION "1.70.0"`, `PACKAGE_VERSION_NUM 0x014600`; `add_library(nghttp2_objects OBJECT
${nghttp2_SOURCE_DIR}/lib/*.c)` (26 files, C99, PIC, hidden visibility), definitions
`BUILDING_NGHTTP2 NGHTTP2_STATICLIB HAVE_ARPA_INET_H HAVE_NETINET_IN_H HAVE_CLOCK_GETTIME
HAVE_DECL_CLOCK_MONOTONIC=1`, includes `lib/includes`, `lib`, the generated dir;
`target_sources(EcoSystem_HttpServer PRIVATE $<TARGET_OBJECTS:nghttp2_objects>)` (the AOT driver
links only `EcoSystem_*` archives). License notice added next to llhttp's.

**`Http2Protocol`** (`HttpServer/Http2.{hpp,cpp}`): one nghttp2 *server* session per connection,
driven by `nghttp2_session_mem_recv2` on `onData` and `nghttp2_session_mem_send2` while
`Conn::outbound()` is below the high watermark (resumed in `onWritable`).
- **Options:** `nghttp2_option_set_no_auto_window_update`, `set_max_continuations` (8),
  `set_stream_reset_rate_limit` (burst 1000, rate 33/s — nghttp2's defaults made explicit),
  `set_max_outbound_ack`, `set_max_settings`, `set_no_rfc7540_priorities`; never
  `set_no_http_messaging`.
- **Initial SETTINGS:** `MAX_CONCURRENT_STREAMS = n` only when `maxConcurrentStreams = Just n`
  (default: not sent, i.e. unlimited, W19), `MAX_HEADER_LIST_SIZE
  = maxHeaderSize`, `ENABLE_PUSH = 0`, `ENABLE_CONNECT_PROTOCOL = 1`, `INITIAL_WINDOW_SIZE = 64 KiB`.
- **Per stream:** `{ key, state ∈ Headers | Body | Delivered | Responding | Reset | Tunnel, body,
  bytes }`. Header list size enforced in `on_header_callback` (name + value + 32 per field):
  on overflow stop storing headers, mark the stream `TooLarge`, and at the end of the header block
  submit a 431 response followed by `RST_STREAM(NO_ERROR)`. Requests are delivered on
  `END_STREAM`; extended CONNECT on HEADERS (it never ends).
- **Flow control (manual):** the connection window is consumed on receipt, bounded by a per-
  connection body budget (`maxBodySize × 2`); a stream's window is consumed as its body accumulates
  up to `maxBodySize` (beyond: submit a 413 response, then `RST_STREAM(NO_ERROR)` — RFC 9113 §8.1
  allows a complete response before the request ends); tunnel streams
  consume only when the WebSocket codec takes the bytes (backpressure).
- **Rapid reset (CVE-2023-44487):** always on: nghttp2's stream reset rate limit (burst 1000,
  33/s) → `GOAWAY(ENHANCE_YOUR_CALM)`. When `maxConcurrentStreams = Just n`, additionally count
  outstanding = delivered-but-unanswered streams **including reset ones** (until Elm answers or the
  key is dropped) and stop calling `mem_recv2` at `n` outstanding. With the default (unlimited) the
  rate limit is the only bound: documented, with the advice to set a cap on public servers.
  CONTINUATION flood bounded by `max_continuations`.
- **Mapping to `Request`:** method/url from `:method`, `:scheme`, `:authority` (a different `Host`
  → 400), `:path`; pseudo-headers removed from the header list; `cookie` crumbs joined with `"; "`
  (RFC 9113 §8.2.3); header names arrive lower-case (documented: use case-insensitive lookups);
  `version = Http2`; `upgrade = Just "websocket"` for extended CONNECT with `:protocol = websocket`,
  other `:protocol` values → 501.
- **Responses** (`toH2Nv`): names lower-cased; drop `connection`, `keep-alive`, `proxy-connection`,
  `transfer-encoding`, `upgrade`, and `te` other than `trailers`; user 1xx/101 → 500; HEAD, 204 and
  304 as HEADERS with `END_STREAM`; otherwise HEADERS + DATA (`data_provider2`, `NGHTTP2_ERR_DEFERRED`
  while the body is not yet queued — bodies are complete Bytes today, so DATA is written at once).
- **GOAWAY** on `closeServer` (last processed stream id); live tunnels survive GOAWAY until their
  WebSocket closes or the deadline; abnormal tunnel end → `RST_STREAM(CANCEL)` (WF7).

### 3.9 WebSockets over HTTP/2 (W12, phase WS9)

- **Server:** an extended CONNECT stream is delivered as a `Request` (`upgrade = Just "websocket"`);
  `upgradeRequest` returns an `Upgrade` with `isH2 = True` (no key/accept; headers from the h2 header
  list); `accept` answers `:status 200` (no END_STREAM) with `sec-websocket-protocol` /
  `-extensions` as negotiated, and binds the stream to a `WsProtocol` instance whose "transport" is
  the h2 stream (an `H2StreamPort` adapter: writes become DATA frames with deferred data providers;
  reads come from `on_data_chunk_recv`, consumed into the window only when the codec takes them).
  Tunnels count against `maxConcurrentStreams` like any stream when it is set; there is no separate
  WebSocket cap (W19).
  Orderly close: after the WebSocket close handshake, send `END_STREAM`; abort: `RST_STREAM(CANCEL)`.
- **Client (opt-in):** `dial` with ALPN `h2,http/1.1`; if ALPN = `h2`, start an nghttp2 *client*
  session (`Http2ClientProtocol`), send SETTINGS, wait for the server's SETTINGS, read
  `remote ENABLE_CONNECT_PROTOCOL`; if 1, send `:method CONNECT, :protocol websocket, :scheme https,
  :path, :authority, sec-websocket-version 13, …` and accept any 2xx; if 0, send GOAWAY and
  redial over HTTP/1.1 within the same deadline. If ALPN = `http/1.1`, continue with the HTTP/1.1
  Upgrade on the same connection. Frames stay masked (WF7).

### 3.10 JS target (all phases; Appendix E)

`WebSocket.js` holds the codec as a class over any Node Duplex (`net.Socket`, `TLSSocket`, or an
`Http2Stream`), reading `'data'` with pause/resume, masks from a pooled `crypto.randomFillSync`
buffer, UTF-8 via `TextDecoder('utf-8', { fatal: true })` with `stream: true`, deflate through the
synchronous zlib handle. `HttpServer.js` moves to `http2.createSecureServer({ allowHTTP1: true })`
(TLS) or `http.createServer` (plain), with per-socket request queues (one in flight), `'upgrade'`
and `'connect'` listeners (declined upgrades written as raw HTTP/1.1), header filtering and cookie
joining for h2, and Node timeouts set to the plan's values.

---

## 4. Phases

**Rules for every phase.** Repo copies under `/work/worktrees/<n>` with their own `build/` and
`ECO_HOME`, merged by 3-way `git merge-file` from `/tmp`. Native and JS land together; every new
test runs on both backends unless marked `-- SKIP-JS:` with a reason. Gates: `full` (incl.
`run-js-e2e`), validate tree (`ECO_NURSERY_POISON=1 ECO_HEAP_CONFIG=…gc-pressure.json
build-validate/test/test --filter eco-system`), stress under validate (`-n 10`,
`ECO_VALIDATE_FREELIST_DUP_SCAN=0`), `check-root-bounded.py`, `check-kernel-homes.sh`, the license
manifest (re-audit rows if a pinned file changes), each test command run once and teed to `/tmp`.
Each phase adds a §10 entry with results and deviations.

### WS0 — API stubs, docs, plumbing
Files: `src/WebSocket.elm`, `src/WebSocket/Internal.elm`, `src/WebSocket/Internal/Handshake.elm`
(signatures only), `src/Http/Server.elm` (new API, `Request` fields, C.1 layout), `src/Eco/Kernel/
WebSocket.js`, `src/eco-system/WebSocket/*` (stub exports, `Eco_System_registerManager_WebSocket`),
`HttpServer` stubs for the new kernels, `elm.json`, README, `runtime/src/codegen/CMakeLists.txt`.
1. Appendix A modules with doc comments; kernels annotated per Appendix B; new kernels fail
   `ENOTSUP`. 2. `Request` gains `version`/`upgrade` (W15): the native and JS request kernels fill
   `Http1_1`/`Nothing` for now; the C.1 tagger layout changes now (C++, JS, Elm, tests) so later
   phases only fill values. 3. `ECO_SYSTEM_MODS += WebSocket`.
Exit: docs list `WebSocket` and the new `Http.Server` items; `WebSocketSmokeTest` (imports, URL
parse, a stub error) passes on both backends; all `HttpServer*` tests pass; `full` green.

### WS1 — Core refactors: `ConnProtocol`, listener callback mode, Stream additions
Files: `Socket/{Conn,ConnChannel,Listener}.{hpp,cpp}`, new `Socket/FaceProtocol.{hpp,cpp}`,
`Stream/{Stream.hpp,StreamTable.hpp,Stream.cpp}`, `Core/ByteChannel.hpp`, `Eco/Kernel/Stream.js`,
`test/eco-system-core/EcoSystemCoreTest.cpp`.
1. §3.2: extract `FaceProtocol` (no behaviour change), multi-timer `setDeadline`, `setProtocol`,
   `write`/`outbound`/`onWritable`, listener callback mode. 2. §3.3 Stream additions, C++ and JS.
3. Core tests: Conn protocol hand-off with leftover bytes; multi-timer ordering; mapped source/sink;
   attach/detach rules.
Exit: every `eco-system/Socket*` test green natively, under validate, and on JS; core test green;
stress `EcoSystemSocket` green.

### WS2 — `Http.Server` on the reactor
Files: `HttpServer/{Http1,HttpTables,HttpServerManager,HttpServer,HttpServerExports}.{hpp,cpp}`
(rewrite of `HttpServerService` usage; `HttpServerService.cpp` keeps only `listenOn`,
`serializeH1`, `statusReason`), `Http/Server.elm`, `Eco/Kernel/HttpServer.js`, tests.
1. §3.4 completely (state machine, limits, timeouts, 100-continue, Host/URL rules, responses,
   upgrade *pending* (declined with `Connection: close` until WS5), closeServer, counts, manager).
2. JS parity (Appendix E.2). 3. Tests (raw clients over `Socket.Tcp` in the same program):
   `HttpServerKeepAliveTest` (two requests on one connection, `Connection: keep-alive`),
   `HttpServerPipelineTest` (three pipelined requests answered in order; slow handler),
   `HttpServerLimitsTest` (431, 413 by Content-Length and by chunked total, no 100-continue on 413),
   `HttpServerTimeoutTest` (headers 408, idle close; **SKIP-JS** only if Node's timers cannot be set
   to the test's short values), `HttpServerHostTest` (missing/duplicate Host 400, absolute URL),
   `HttpServerSmugglingTest` (CL+TE, duplicate CL, `TE: chunked, identity`, obs-fold, bare LF,
   space before colon → 400 and close), `HttpServerOneXxTest` (user 103 → 500),
   `HttpServerCloseTest` (closeServer: idle closed, in-flight finishes, parked 503, port reusable,
   program exits), `HttpServerUpgradeDeclinedTest` (Upgrade request answered 426 → closed),
   `HttpServerConnectTest` (CONNECT → closed after the response, both backends).
   Rewrite the thread-based Core tests (`EcoSystemCoreTest.cpp:727,760-900`) for `serializeH1` and
   the parser handler. Stress: `EcoSystemHttpServerKeepAlive.elm` (many keep-alive clients).
Exit: all existing `HttpServer*` tests plus the new ones on both backends; validate; stress.

### WS3 — TLS for `Http.Server`
Files: `Tls/TlsContext.{hpp,cpp}` (`alpnFallback`), `HttpServer/*` (TLS factory, ALPN dispatch stub:
h2 → HTTP/1.1 until WS8), `Http/Server.elm`, `HttpServer.js`, tests.
1. §3.5. 2. Tests: `HttpServerTlsTest` (https GET via a raw `Socket.Tls` client with the test CA;
   `url` scheme `https`; ALPN `http/1.1`; a client offering only `http/1.0` still connects (NoAck);
   `http2 = True` without TLS → `EINVAL`).
Exit: as WS2.

### WS4 — WebSocket core (client, socket-level server)
Files: `WebSocket/{WsFrame,WsProtocol,WsHandshake(kernel side: key/accept, head reader),WsTables,
WsManager,WebSocket,WebSocketExports}.{hpp,cpp}`, `src/WebSocket*.elm`, `Eco/Kernel/WebSocket.js`,
`Socket.js` (`_Socket_detach`), `system-kernel-cpp/tests/tests/HandshakeTest.elm`, tests.
1. §3.6 without streaming and compression: Handshake module + elm tests; frame codec (Appendix D.1,
   D.4–D.6, D.8); `dial`, `readUpgrade`, `open`, `reject`, `close`, `closed`, `ping`, `onMessage`,
   `onClose`; the mapped readable/writable; keep-alive counts. 2. JS (Appendix E.3).
3. Tests (`test/eco-system/src/WebSocket*Test.elm`, server and client in one program; malformed
   peers written over raw `Socket.Tcp`): `WebSocketEchoTest` (text and binary interleaved, order),
   `WebSocketFragmentsTest` (raw peer sends fragmented text with a ping between fragments; one
   `Text` value), `WebSocketHandshakeServerTest` (POST, no key, 20-byte key, version 8 → 426 with
   `Sec-WebSocket-Version: 13`, protocol negotiation), `WebSocketHandshakeClientTest` (bad accept,
   protocol not offered, extension not offered, 302 → `ERR_WS_HANDSHAKE` with `handshakeStatus`),
   `WebSocketEarlyFrameTest` (101 and the first frame in one write), `WebSocketFramingErrorsTest`
   (unmasked client frame, masked server frame, RSV bits, reserved opcode, control > 125,
   fragmented control, 64-bit length with MSB set → 1002), `WebSocketUtf8Test` (invalid text, invalid
   fragmented text failing fast, invalid close reason → 1007), `WebSocketCloseTest` (codes, 1-byte
   payload → 1002, invalid code → 1002, `close` EINVAL for 1005/1006/999, reason truncation, `closed`
   clean and abnormal, close timeout, data after Close ignored), `WebSocketHeartbeatTest` (a raw
   peer that stops answering → `Abnormal`; `ping` RTT; liveness by bytes during a large frame;
   backpressure does not time out), `WebSocketSubscriptionTest` (`onMessage` attach while a read is
   parked waits; messages readable after unsubscribe; two subscribers; `onClose` held for a late
   subscriber), `WebSocketExitTest` (a client with only `onMessage` stays alive; with nothing
   subscribed or parked the program exits), `WebSocketTlsTest` (wss with the test CA),
   `WebSocketUrlTest` (IPv6 literal, default ports in Host, invalid URLs). Stress:
   `EcoSystemWebSocket.elm` (500 concurrent echo connections with heartbeats; 64 MiB of messages).
Exit: native, validate, JS, stress green; Autobahn `fuzzingclient` cases 1–7 and 9 (Appendix F)
against `test/conformance/WsEchoServer.elm` (a small echo server program added in this phase;
WS10 promotes it to `examples/system`) recorded in §10 (local, informational).

### WS5 — `Http.Server.upgradeRequest` (HTTP/1.1)
Files: `HttpServer/Http1.cpp` (`takeUpgrade`), `WebSocket/*` (accept over an `Http1Protocol` hand-off),
`Http/Server.elm`, `HttpServer.js` (`'upgrade'` listener synthesising the `Request`), tests.
1. §3.4 upgrade path end to end. 2. Tests: `HttpServerWebSocketTest` (HTTP and WebSocket on one
   port; a pipelined GET before the upgrade answered first; a declined upgrade answered with
   `Connection: close`; `send` after upgrade ignored), `HttpsServerWebSocketTest` (wss through
   `createServerWith` + TLS).
Exit: as WS4.

### WS6 — Streamed messages
Files: `WebSocket/WsProtocol.cpp` (streamed lanes), `src/WebSocket.elm` (`connectStreamed`,
`acceptStreamed`, `streamedReadable`, `sendText`, `sendBinary`), `WebSocket.js`, tests.
1. §3.6 streamed receive (nested body pairs created on the main thread per message; next message
   held until the body is read to `Closed` or cancelled; cancel discards the rest; Close mid-body
   fails the body `Cancelled` and closes the parent), streamed send (kernel `openOutgoing` returns a
   sink id; Elm `Stream.pipeTo`; data writes queue behind; an empty readable sends one empty FIN
   frame; aborting mid-message fails the connection with 1011 — documented). 2. Tests:
   `WebSocketStreamedTest` (100 MiB message streamed both ways with bounded memory: check RSS growth
   via a small `/proc/self/status` read, **SKIP-JS** for the RSS part only if needed — split test),
   `WebSocketStreamedCancelTest`, `WebSocketStreamedUtf8Test` (code-point boundaries, invalid byte in
   a later fragment fails the body), `WebSocketSendStreamInterleaveTest` (a data message written
   during a stream arrives after it; pings during the stream still answered).
Exit: as WS4.

### WS7 — permessage-deflate
Files: `WebSocket/WsDeflate.{hpp,cpp}`, Handshake negotiation code + elm tests, `WebSocket.js`,
tests.
1. §3.7 and Appendix D.7. 2. Tests: `WebSocketDeflateTest` (negotiation matrix: offers with and
   without `client_max_window_bits`, server policy no-context-takeover, window bits 8 → deflate 9,
   declined offer → uncompressed; RFC 7692 example bytes; context takeover across messages;
   threshold), `WebSocketDeflateBombTest` (1 KiB compressing to 1 GiB → 1009 with bounded memory),
   `WebSocketDeflateStreamedTest` (streamed + compressed, skipping a compressed body keeps later
   messages correct). Elm tests for the negotiation grammar (duplicates, unknown parameters, quoted
   values, leading zeros).
Exit: as WS4; Autobahn cases 12–13 recorded (informational).

### WS8 — HTTP/2 in `Http.Server`
Files: `system-kernel-cpp/CMakeLists.txt` (nghttp2 OBJECT library), `HttpServer/Http2.{hpp,cpp}`,
`HttpServer/*` (ALPN dispatch), `HttpServer.js` (`http2.createSecureServer({ allowHTTP1: true })`),
license notices (`LICENSE`/docs list of bundled third-party code), tests.
1. §3.8. 2. Tests (peers: `System.Process.run "curl" ["--http2", …]` with the test CA, and a Node
   script for h2-specific cases; both are available in the dev container — WF12):
   `HttpServerHttp2Test` (GET/POST, `version = Http2`, lower-case headers, cookie joining, HEAD,
   204, 1xx → 500, absolute URL from `:authority`), `HttpServerHttp2ConcurrencyTest` (100 parallel
   streams answered out of order), `HttpServerHttp2LimitsTest` (header list, body 413, rapid reset
   via the Node script → GOAWAY ENHANCE_YOUR_CALM with the default unlimited streams;
   `maxConcurrentStreams = Just 10` advertised and enforced), `HttpServerHttp2CloseTest` (GOAWAY, in-flight
   finishes). h2spec baseline recorded (Appendix F) and kept in §10 for comparison.
Exit: as WS4, plus the h2spec result not worse than the recorded baseline.

### WS9 — WebSockets over HTTP/2
Files: `HttpServer/Http2.cpp` (tunnels), `WebSocket/{H2StreamPort,Http2Client}.{hpp,cpp}`,
`WebSocket/WsProtocol.cpp` (port abstraction), `WebSocket.elm` (`http2` option), `WebSocket.js`,
tests.
1. §3.9 server and client. 2. Tests: `WebSocketHttp2ServerTest` (Node h2 client script does an
   extended CONNECT; echo; END_STREAM close; RST_STREAM CANCEL on abort; unknown `:protocol` → 501),
   `WebSocketHttp2ClientTest` (our client against our server with `http2 = True`; against an
   HTTP/1.1-only server it falls back), `WebSocketHttp2ManyTest` (50 WebSockets and ordinary
   requests on one h2 connection, no cap).
Exit: as WS4.

### WS10 — Conformance, docs, examples
1. `test/conformance/autobahn.sh` and `test/conformance/h2spec.sh` (Appendix F; install under `/tmp`,
   local only, never in CI); full Autobahn runs (fuzzingclient against `WsEchoServer`, fuzzingserver
   with `WsAutobahnClient`) with and without compression; results summarised in §10.
2. Examples: `examples/system/src/WsEchoServer.elm` (Http.Server + upgrade, optional TLS),
   `WsChat.elm` (broadcast to all connections), `WsClient.elm` (connects to a URL, prints messages),
   `WsAutobahnClient.elm` (the fuzzingserver driver).
3. Docs: getting-started (WebSockets, https, HTTP/2), README, `design_docs/invariants.csv`
   `SYS_005` (WebSocket codec rules: masking direction, control frames first, UTF-8, close codes) and
   `SYS_006` (`Http.Server` one request in flight, limits, no lenient parsing).
Exit: examples build as AOT binaries and run; `full` green; conformance summary recorded.

**Ordering:** WS0 → WS1 → (WS2 ∥ WS4) → (WS3 ∥ WS5 ∥ WS6 ∥ WS7) → WS8 → WS9 → WS10. WS5 needs WS2
and WS4; WS3 needs WS2; WS8 needs WS3; WS9 needs WS4 and WS8.

## 5. Test strategy summary

Pure Elm tests (Handshake: URL, Host, tokens, extension grammar, deflate negotiation); C++ Core tests
(Conn protocols, Stream additions, frame codec, deflate engine vectors, `serializeH1`/`toH2Nv`);
E2E tests on native, validate tree and JS, with peers in the same program (raw `Socket.Tcp`/`Tls`
clients and servers) or spawned (`curl --http2`, Node scripts); shared test vectors from Appendix D
run on both codecs (R4); stress under validate; local conformance (Autobahn, h2spec).

## 6. Ordering and dependencies

§4 "Ordering". New external dependency: **nghttp2 1.70.0** (WS8), vendored. Everything else is
already linked: OpenSSL (TLS, SHA-1, RAND), zlib, llhttp.

## 7. Open questions

None. Resolved 2026-10-08:
1. **Compression:** on by default; context takeover opt-in (W8, §3.7).
2. **Default limits:** `maxMessageSize` 16 MiB, `handshakeTimeout` 30 s, close timeout 30 s,
   `maxBodySize` 16 MiB, `maxHeaderSize` 64 KiB, `keepAliveTimeout` 5 s, `headersTimeout` 60 s,
   `requestTimeout` 300 s, `closeServer` deadline 5 s. **No** default cap on connections or HTTP/2
   streams (W19).
3. **WebSocket streams over HTTP/2:** no separate cap (W19).

## 8. Risks

| # | Risk | Mitigation |
|---|---|---|
| R1 | The `Conn` refactor and moving a working server touch tested code. | WS1 is behaviour-neutral and gated on every Socket test; WS2 keeps all `HttpServer*` tests and adds raw-client tests before anything builds on it. |
| R2 | HTTP/2 and WebSocket parsing are security surfaces (smuggling, rapid reset, CONTINUATION flood, compression bombs, slowloris). | Strict llhttp; nghttp2's limits made explicit; one-in-flight; byte budgets; timeouts; bounded inflate; dedicated tests; h2spec and Autobahn locally. |
| R3 | Two codec engines (C++ and JS) drift. | Elm owns negotiation and handshake validation; Appendix D test vectors run on both; the same E2E suite and Autobahn runs on both. |
| R4 | One reactor thread does TLS, HPACK, deflate and every socket. | Bounded work per event (64 KiB inflate steps, watermarks); documented; a multi-reactor is a follow-up. |
| R5 | Memory per connection (zlib, h2 windows, held messages); no default connection or stream caps (W19). | No context takeover by default, h2 body budgets, optional `maxConnections` / `maxConcurrentStreams`, reset rate limit; per-connection costs and the advice to set caps on public servers documented. |
| R6 | Conformance tools are local only (no Docker; PyPy recipe). | Scripts in `test/conformance/`; results recorded per phase; never a CI gate. |
| R7 | **Runtime finding (WS6, 2026-10-08):** large `Bytes` (> 8 KiB, allocated in the old generation) that become garbage are not reclaimed promptly: their allocation does not trigger a GC and minor GCs do not free them, so a program that streams large chunks through Elm grows RSS (measured ~300 MB for 1000 × 256 KiB dropped chunks). Affects every eco/system stream, not only WebSocket. | Out of this plan's scope (allocator code covered by the TLA+ models, `test/tla/README.md`). **Partly resolved 2026-10-08 by `plans/large-body-gc-trigger.md`:** direct old-gen bytes now request minors (HEAP_079) and a failed body allocation recovers or prints `eco: out of memory` (HEAP_026). **Still open:** bodies in (64 KiB, alloc_buffer_size) take a fresh 512 KiB bag page each (the largest size class is 64 KiB, so 64 KiB + header never fits a recycled cell): 8x the bytes for every 64 KiB stream chunk; the native Autobahn `--no-split` server still grew to 11.6 GB (§10 of that plan). WebSocket tests bound only the WebSocket layer's own buffering (`WebSocketStreamedMemoryTest`). |

## 9. Review log (2026-10-08)

Facts (F): WF6 invalid as written (dedicated deflate engine); WF3/WF4/WF7/WF8 verified with
corrections (client must check SETTINGS; Node `'connect'` or 405; RST_STREAM(CANCEL); Docker → PyPy).
Native review (N): 2 BLOCKER, 15 MAJOR, 9 MINOR. WebSocket review (J): 2 BLOCKER, 18 MAJOR, 11 MINOR.

| # | Sev | Finding | Fix (section) |
|---|---|---|---|
| N1 | BLOCKER | `Conn`/`ListenerHandler` cannot host an HTTP parser | W17, §3.2, WS1 |
| N2 | BLOCKER | `Request.version` breaks a public record; C.1 tuple full | W15, C.1 |
| N3 | MAJOR | no pipelining policy | §3.4 one in flight |
| N4 | MAJOR | unbounded bodies and parked requests | §3.4 limits, budgets |
| N5 | MAJOR | no slowloris/request timeouts | §3.4 timeouts |
| N6 | MAJOR | response rules (Connection, 1xx) | §3.4 serializeH1 |
| N7 | MAJOR | llhttp upgrade mechanics, head bytes, h2c smuggling | §3.4 upgrade |
| N8 | MAJOR | respond key semantics, 2 s completion | §3.4 HttpKeys, respond |
| N9 | MAJOR | Host first/last mismatch, scheme | §3.4 Host and URL |
| N10 | MAJOR | h2 header mapping, cookies, pseudo-headers | §3.8 mapping |
| N11 | MAJOR | nghttp2 integration (flow control, rapid reset, options) | §3.8 |
| N12 | MAJOR | system nghttp2 unusable | W11, §3.8 build |
| N13 | MAJOR | ALPN override and fallback | §3.5 |
| N14 | MAJOR | closeServer semantics | §3.4 closeServer |
| N15 | MAJOR | keep-alive counts and exit | §3.4 counts |
| N16 | MAJOR | 100-continue ordering and 413 | §3.4 |
| N17 | MAJOR | tests cannot reach new behaviour | WS2/WS8 peers (WF12) |
| N18 | MAJOR | extended CONNECT server details | §3.9 |
| N19–N26 | MINOR | smuggling tests; CONNECT divergence; HTTP/1.0; naming/placement; half-close; listen paths; maxConnections and single reactor; Windows/heap reset/embed | §3.4, WS2, A.2, R4 |
| J1, J2 | BLOCKER | `Message` values cannot cross the kernel boundary | W16, §3.3 |
| J3 | MAJOR | WF6 false | §3.7 |
| J4 | MAJOR | deflate negotiation underspecified | §3.7, D.7, A.1 |
| J5 | MAJOR | handshake validation incomplete | D.2, D.3 |
| J6 | MAJOR | URL parsing and Host | §3.6 Handshake |
| J7 | MAJOR | one timeout impossible in Elm | `dial` kernel |
| J8 | MAJOR | `onMessage` lock model | W3, §3.3 attach/detach |
| J9 | MAJOR | keep-alive counts | §3.6 counts |
| J10 | MAJOR | mode-dependent Locked | W7 phantom mode |
| J11 | MAJOR | heartbeat under backpressure / large frames | W5, §3.6 |
| J12 | MAJOR | close rules | W14, D.5 |
| J13 | MAJOR | streamed receive details | WS6, §3.7 |
| J14 | MAJOR | sendStream design | W7 `sendText`/`sendBinary` |
| J15 | MAJOR | connection hand-off | §3.2 |
| J16 | MAJOR | `Http.Server.upgrade` design | W2 |
| J17 | MAJOR | conformance cannot run here | W18, Appendix F |
| J18 | MAJOR | test gaps | WS4–WS9 test lists |
| J19 | MAJOR | Node upgrade/connect behaviour | §3.10, E |
| J20 | MAJOR | RFC 8441 details | §3.9 |
| J21–J31 | MINOR | error codes/handshakeStatus; `reject` headers; names; codec CPU; phase split; Appendix D gaps; docs generator; protocol tokens; default ports; heartbeat both ends; deflate memory | W13, A.1, R4, §4, D, Q1 |

## 10. Progress log

- 2026-10-08 — **WS0 done** (repo copy `worktrees/p12a`). `src/WebSocket.elm` (Appendix A.1, full
  docs, the JS manager body per C.2), `src/WebSocket/Internal.elm` (handle types, decoders),
  `src/WebSocket/Internal/Handshake.elm` (pure: URL parser, `Host` header, TLS server name, token
  lists, RFC 9110 tokens, the D.2 request headers, D.2/D.3 checks, the 101/200 response headers,
  the extension grammar and the negotiation entry points), `Http.Server` A.2 additions (`HttpVersion`,
  `Request.version`/`upgrade`, `ServerOptions`/`defaultServerOptions` with the §7 values and
  `Nothing` caps, `createServerWith`, `serverPort`, `closeServer`, `closeServerWithin`,
  `upgradeRequest`), the C.1 tagger layout in Elm, C++ (`HttpServerManager`, inner triple mask 0x5)
  and JS (`HttpServer.js` + the Elm manager body), `Eco/Kernel/WebSocket.js`,
  `src/eco-system/WebSocket/{WebSocket,WebSocketExports,WsManager}.{hpp,cpp}` (stub exports for
  every B.1 symbol, `Eco_System_registerManager_WebSocket` accepting subscriptions and never
  firing), B.2 stubs in `HttpServer{,Exports}.cpp`/`HttpServer.js`, `eco_system_module(WebSocket …)`
  (links `EcoSystem_Socket`, `EcoSystem_Tls`, `EcoSystem_Stream`, OpenSSL::Crypto on POSIX),
  `ECO_SYSTEM_MODS += WebSocket`, `elm.json`, README, `test/eco-system/src/WebSocketSmokeTest.elm`.
  Results: eco/system elm tests 757/757 (`/tmp/eco-p12a-elmtests.txt`); `docs:check` lists
  `WebSocket` (29 values) and the new `Http.Server` items, no `Debug.todo` in `docs.json`
  (`/tmp/eco-p12a-docs.txt`); `check-kernel-homes.sh` OK (10 homes); native `--filter eco-system`
  114/114 (`/tmp/eco-p12a-native-ecosystem.txt`); JS `eco-system/HttpServer,WebSocketSmoke` 6/6
  (`/tmp/eco-p12a-js.txt`); `full` green (`/tmp/eco-p12a-full.txt`: core test 1445 checks / 0
  failures, JIT E2E 2274/2274, JS eco-system 112 passed + 2 existing SKIP-JS of 114).
  - Deviations: `Message`, `StreamedMessage` and `fromWire`/`fromWireStreamed`/`toWire` live in
    `WebSocket`, not `WebSocket.Internal` (§3.6): `Message(..)` is exposed with its constructors,
    which an alias cannot re-export (base plan F23), and `Internal` cannot import `WebSocket`.
    `readUpgrade` and `takeUpgrade` return the client's endpoint as a third slot of the inner
    tuple (B.1/B.2 rows updated): `Upgrade.remote` had no source on the `Http.Server` path.
    `Server` is `Server { id, port_ }` (`port` is a reserved word); `createServer` returns the port
    it was given (0 stays 0 until WS2). `handshakeKey` and `acceptFor` are real already (OpenSSL
    RAND/SHA-1/base64 natively, `node:crypto` on JS), so `EcoSystem_WebSocket` links
    OpenSSL::Crypto now (zlib waits for WS7). Task Never stubs: `reject`, `close` and
    `closeServer` succeed doing nothing, `closed` succeeds with `(1006, "", False)`; JS
    `attachMessageListener`/`attachCloseListener` never complete, `holdClose` succeeds.
    `RequestEvent` gained `flags` (default 1) and `upgrade` (""); both backends fill HTTP/1.1, no
    TLS, no upgrade. `createServerWith` checks `http2` without `tls` → `EINVAL` in Elm.
    `handshakeStatus` reads the status from an `ERR_WS_HANDSHAKE` message of the form
    `"status <n>: <text>"` (`WebSocket.Internal.handshakeError`). `sendText`/`sendBinary` map
    stream errors to `Socket.Error` (`Cancelled r` → `ECANCELED r`, `Closed` → `ECANCELED "socket
    closed"`, `Locked` → `EBUSY`); WS6 may refine. URL parser choices: non-ASCII → `EINVAL` (no
    percent-encoding), host names lower-cased, `ws://h:/` = default port, bracketed IPv4 rejected.
    Simplified until WS4/WS7: the extension grammar (no `,`/`;` inside quoted values),
    `negotiateServer` declines every offer, `negotiateClient` accepts one `permessage-deflate`
    answer without checking it against the offer.
  - Plan problems for WS4: (1) `dial`'s result does not say whether HTTP/2 was used; Elm infers
    `isH2 = http2 && status /= 101`. (2) No kernel releases a dialed handshake (`hsId`) when Elm's
    D.2 check or the negotiation fails (the code has a `WS4` note). (3)
    `AcceptOptions.handshakeTimeout` has no consumer: `upgradeRequest` reads the request before any
    `AcceptOptions` exist (WS0 passes 30000 to `readUpgrade`), and `open`'s parameters carry no
    handshake timeout.
- 2026-10-08 — **WS1 done** (`worktrees/p12b`). `Socket/Conn.{hpp,cpp}` (protocols, multi-timer,
  write queue, closeGraceful), new `Socket/FaceProtocol.{hpp,cpp}` (the face logic moved out of
  `Conn`, unchanged rules), `Socket/Listener.{hpp,cpp}` (callback mode), `Core/ByteChannel.hpp` +
  `ChannelDrain.cpp` (`tag`/`text`, `requestWriteTagged`), `Stream/{Stream.hpp,StreamTable.hpp,
  Stream.cpp,StreamPipe.cpp}` (mapped pairs, subscription reader), `Eco/Kernel/Stream.js` (JS twins),
  `test/eco-system-core/EcoSystemCoreTest.cpp` (+6 tests; the core test now links `EcoSystem_Socket`
  and `EcoSystem_Stream`), `system-kernel-cpp/CMakeLists.txt`. `ConnChannel` and `TlsTransport` needed
  no change (`Conn::req*` forward to the `FaceProtocol`). Results: core test 1579 checks / 0
  (`/tmp/eco-p12b-core2.txt`; under the validate tree with poison + gc-pressure 1579 / 0,
  `/tmp/eco-p12b-validate-core.txt`); native `--filter eco-system` 113/113
  (`/tmp/eco-p12b-native-ecosystem.txt`), `eco-system/Socket` 33/33 on the final code
  (`/tmp/eco-p12b-native-socket2.txt`); validate tree `eco-system/Socket` 33/33
  (`/tmp/eco-p12b-validate-socket2.txt`); stress `EcoSystemSocket -n 10` under validate green
  (`/tmp/eco-p12b-stress2.txt`); JS `run-js-e2e` `eco-system/Socket,eco-system/Stream` 50/50 + the 2
  Appendix E skips (`/tmp/eco-p12b-js.txt`); root-bound and kernel-homes ok; `full` green (native
  2273/2273, JS 111/111 + 2 skips, `/tmp/eco-p12b-full.txt`; it ran before the last change — per-depth
  read buffers in `Conn::serviceReads` — after which core, native/validate Socket and stress were
  re-run green). The JS mapped paths, which no E2E test reaches before WS4, were checked with a
  scratch Node harness (mapped source/sink, reader, pipe, tag-0 fallback, ENOTSUP).
  - API as implemented (for WS2–WS9): `ConnProtocol` exactly as §3.2. `Conn` (non-final, protected
    ctor): `setProtocol(p, leftover)`, `protocol()`, `write(bytes, done)`, `outbound()`,
    `updateInterest()`, `setDeadline(id, monoMs)` / `deadline(id)`, `shutdownWrite(done = nullptr)`,
    `cancelWrites(err)`, `closeGraceful(drainMs)`, `abort(reset)`, `tlsInfo()`,
    `addCloseHook(fn(Conn&))`, state getters `eofSeen() readError() readErrorReason() writeError()
    writeErrorReason() writeEnded() aborted() closing()`, `face()`, `setFaceDetachedReason(s)`;
    constants `kTimerConnect=0 … kTimerCloseHandshake=7`, `kMaxTimers=8`, `kLowWatermark=64 KiB`,
    `kFaceDrainMs=2000`. `FaceProtocol`: `idle()` and `takeBuffered()` for the socket-level hand-off
    (WS4: EBUSY unless `idle()`). `ListenerHandler::setCallbackMode(ProtocolFactory, maxConnections)`
    (main thread, before `start()`), `openConnections()`. Stream: `ChannelResult::{tag, text}`,
    `ByteChannel::requestWriteTagged(token, tag, text, bytes)`, `createMappedSource(ch, fromWireEnc)`,
    `createMappedSink(ch, toWireEnc)`, `ReaderFn`, `attachReader(id, fn, ctx)`, `detachReader(id)`;
    internal `streamMappedMaybeRead`, `streamMapForSink`, `streamUncountedToken`. JS:
    `_Stream_createMappedSource(channel, fromWire)`, `_Stream_createMappedSink(channel, toWire)`,
    `_Stream_attachReader(id, fn) -> Bool`, `_Stream_detachReader(id)` (API notes at the top of
    `Stream.js`).
  - Decisions the plan left open / deviations:
    - `onError`'s `code` is the §D.2 stream reason (`"read <CODE>"` / `"write <CODE>"`), so a
      protocol knows the direction; called at most once per direction; write failures also fail the
      queued `done`s first. `onCloseAll` is called on **every** abort (Socket.close/reset, a
      protocol's own `abort`, embed stop, heap reset), not only embed stop/heap reset.
    - `onOpen` runs from `setProtocol` on an open connection (before `onData(leftover)`) and after a
      client connect; a server `Conn` gets it through the listener's `setProtocol` (callback mode).
    - Protocol callbacks run inside the Conn's IO step: Conn calls made from them (write,
      updateInterest, setProtocol, closeGraceful) are deferred to the end of the step, never nested
      reads. A protocol replaced by `setProtocol` is retired, not destroyed, until its queued writes
      are done (so `done` lambdas may capture it). Read buffers are per nesting level (a protocol may
      drive another `Conn` from `onData`).
    - `shutdownWrite`/`cancelWrites`/`addCloseHook`/getters are additions to §3.2's list (the face
      needs them). `shutdownWrite` without `done` is best effort (failures silent, as the old write-face
      shutdown). `closeGraceful(drainMs <= 0)` uses 2 s (never unbounded); the drain deadline starts
      at the call and also bounds the queued writes. After `closeGraceful` the protocol gets no data.
    - Timer ids 0 (while connecting/handshaking) and 1 (after `closeGraceful`) belong to the Conn;
      otherwise all ids go to the protocol. Expired ids fire in (deadline, id) order; an id re-armed by
      an earlier callback in the same batch is skipped.
    - `FaceProtocol` reads 64 KiB per transport read whatever a request's `maxBytes` (every caller
      asks 64 KiB); bytes past a smaller request are kept and served first.
    - Callback-mode listener: `open` counts accepted connections until their fd closes (handshaking
      ones included), via a close hook; `addCredit`/`setUnlimited` do not apply.
    - **Mapped source maps lazily**: §3.3 says fromWire runs when a chunk is enqueued; it runs when a
      consumer takes the chunk (an immediate read, a parked read, a pipe). The read-ahead chunk waits
      as POD (`rawQ`), so `attachReader` can hand already-read chunks to the reader (as POD, in order,
      from the channel drain through a posted "kick" result) without stranding a mapped value; the
      closure still runs only on the main thread. Read-ahead requests use **uncounted** tokens (an
      idle mapped source keeps nothing alive; their orphans release nothing); a parked read holds its
      own count; a pipe makes the in-flight read counted. A pair is never erased while a read-ahead or
      kick is outstanding.
    - The reader also gets the end once (`eof`, or `err` + reason) after the queued chunks. Attach
      also fails if mapped values are queued (unreachable: values are only mapped for a consumer).
    - Mapped sink: `text` = the String component is non-empty (`bytes` = its UTF-8), else the Bytes
      component; the tag decides meaning. An errored mapped sink fails writes before calling toWire.
    - JS: chunks are `{ tag, text, bytes }` with `text` the String component (a JS string, `''` for
      binary) and `bytes` a Uint8Array or null — the natural JS form, not C++'s `bool text`; mapped
      sinks call `requestWriteTagged({ tag, text, bytes }, done)` with both components (tag 0 falls
      back to `requestWrite`, others fail ENOTSUP). New optional channel method `setDemand(bool)`
      (a parked read or a pipe waits) is the JS twin of native's counting, for WS4's ref/unref.
  - Notes for later phases: hand-off from a socket-level `Connection` (WS4) =
    `face()->idle()` check, `setFaceDetachedReason("upgraded to WebSocket")`, `setProtocol(ws,
    face()->takeBuffered())` (TLS-buffered plaintext is read by `setProtocol`). The C++ reader's
    `fn` runs from the channel drain, which calls `Scheduler::drain()` after dispatching (the WS
    manager may `sendToApp` per message, G12).
- 2026-10-08 — **WS2 done** (`worktrees/p12c`). `Http.Server` runs on the IoReactor: new
  `HttpServer/Http1.{hpp,cpp}` (`Http1Protocol`, a `ConnProtocol` behind a callback-mode
  `ListenerHandler`), new `HttpServer/HttpTables.{hpp,cpp}` (main-thread tables + POD event queue +
  drain), `HttpServerService.{hpp,cpp}` cut down to `listenOn` (non-blocking, bound port),
  `serializeH1`, `statusReason`, `headersAskClose`; `HttpServer.cpp`/`HttpServerExports.cpp`
  (createServer, createServerWith, respond, closeServer real; takeUpgrade still `ENOTSUP`),
  `HttpServerManager.cpp` (delivery only; parking moved to `HttpTables`), Windows stubs in
  `HttpServerServiceWin32.cpp`; `Socket/Listener.{hpp,cpp}` (callback mode posts no
  `ListenerClosed`); `system-kernel-cpp/CMakeLists.txt` (`EcoSystem_HttpServer` links
  `EcoSystem_Socket`; llhttp's include dir PUBLIC); `src/Http/Server.elm` (docs, `createServer`
  maps the bound port); `src/Eco/Kernel/HttpServer.js` (rewritten per E.2). Tests: 10 new E2E
  programs over a shared raw-client helper `test/eco-system/src/HttpServerRawHelp.elm`
  (`HttpServer{KeepAlive,Pipeline,Limits,Timeout,Host,Smuggling,OneXx,Close,UpgradeDeclined,
  Connect}Test`, none SKIP-JS), the thread-based Core tests replaced by `testHttpServerWireFormat`
  (serializeH1) and four reactor tests (`testHttp1KeepAlivePipeline`, `testHttp1Limits`,
  `testHttp1UpgradeConnectGone`, `testHttp1TimeoutsAndClose`), stress
  `test/stress-elm/src/EcoSystemHttpServerKeepAlive.elm` (40 concurrent keep-alive clients × 8
  requests per wave, pipelined pairs, checked responses; it closes its server and ends by itself).
  Existing tests changed: `WebSocketSmokeTest` expects `createServerWith: ok` (was the WS0 stub's
  `ENOTSUP`); `HttpServerNotFoundTest` only its doc comment (connections are kept alive now); no
  other `HttpServer*` test needed a change.
  - Results: core test 1697 checks / 0 (`/tmp/eco-p12c-core2.txt`; validate tree with poison +
    gc-pressure 1697 / 0, `/tmp/eco-p12c-validate-core.txt`); native `--filter eco-system` 124/124
    (`/tmp/eco-p12c-native-ecosystem.txt`); validate `eco-system/HttpServer` 15/15
    (`/tmp/eco-p12c-validate-http.txt`); stress `EcoSystemHttpServer -n 10` under validate 2/2
    (`/tmp/eco-p12c-stress-validate.txt`); JS `run-js-e2e` 122/122 + the 2 Appendix E skips
    (`/tmp/eco-p12c-js-all.txt`); `check-root-bounded` and `check-kernel-homes` ok
    (`/tmp/eco-p12c-rootbound.txt`, `/tmp/eco-p12c-homes.txt`); `full` green (core 1697 / 0, native
    2284/2284, JS 122/122 + 2 skips, `/tmp/eco-p12c-full.txt`; `httpTablesTakeUpgrade`, which
    nothing calls yet, was added while it ran and compiled afterwards). No pinned kernel file
    changed (license manifest untouched).
  - Internal API (for WS3/WS5/WS8):
    - `HttpSrv::ServerConfig` (immutable: serverId, gen, tls, fallbackAuthority, limits, timeouts),
      `ServerReactorState` (reactor-only: cfg, closing, closeDeadline, live `conns`), `ConnShared`
      (key in flight, peer endpoint). `makeHttp1Protocol(conn, srv)` is the callback-mode factory
      (registers the connection, installs the close hook that posts `ConnGone{key}`; WS3's TLS
      factory dispatches on ALPN to it). `http1ServerClosing(srv, deadline)`,
      `http1Respond(conn, key, resp, forceClose, done&)`, `nextResponseKey()`.
    - `Http1Protocol::upgradePending(key)` and `takeUpgradeHead(conn, key)` (ends HTTP/1.1 on the
      connection, clears the key and timers, returns the bytes read past the request; the caller
      then calls `Conn::setProtocol(ws, head)` in the same reactor command). Main thread:
      `httpTablesTakeUpgrade(key, RequestData&, weak_ptr<Conn>&)` (the kept raw request: target,
      headers with duplicates and case, version flags, peer; erases the key and its count).
      Connections handed to another protocol are skipped by `closeServer` (detached).
    - `HttpTables`: `postHttpEvent`, `ensureHttpTables`, `httpTablesStartServer(fd, cfg,
      maxConnections)`, `httpTablesRespond`, `httpTablesCloseServer`,
      `httpTablesSubscriptionsChanged`, `setHttpManagerHooks` (function pointers, so the tables do
      not link the manager: the Core test drives them without Elm), `httpTablesPopEventForTest`.
  - Decisions the plan left open / deviations:
    - **`createServer`'s kernel returns `( serverId, boundPort )`** (B.2 said unchanged): with
      port 0 `serverPort` is the real port for `createServer` too (both backends).
    - **Reading during `AwaitingElm`/`UpgradePending`** continues until 64 KiB are buffered
      (§3.4 says reading stops): TCP still back-pressures a pipelining client, but a peer's FIN
      (half-close: answered, then closed) or reset (abort → `ConnGone`, which releases the key's
      count so the program can exit) is noticed while Elm thinks. Reading also pauses while the
      response queue is above `Conn::kLowWatermark`.
    - A fresh connection waits `headersTimeout` for its first byte, then closes silently
      (slowloris); a timeout of 0 or less is none (documented in `ServerOptions`).
    - Every close after a response or an error is `Conn::closeGraceful(10 s)`: the drain deadline
      also bounds writing the response (WS1 semantics).
    - Versions other than HTTP/1.0 / 1.1 → 505 natively; `Expect` with a value other than
      `100-continue` (or two Expect headers) → 417 + close; HTTP/1.0 needs no `Host` but at most
      one valid one; the Host grammar is RFC 3986 (reg-name, IPv4, bracketed IP literal) with a
      port of at most 5 digits; an absolute-form target is kept as the URL (E.5).
    - CONNECT and upgrade requests with a body are delivered without a token and closed after
      their response; an upgrade request without a body carries the first `Upgrade` token.
    - A request whose server is closed and has no subscriber is answered 503; parked requests
      are bounded at `maxBodySize × 4` bytes per server but at least one is always parked.
    - JS: `maxConnections` is Node's `server.maxConnections`: connections over the limit are
      dropped (native: they wait in the backlog). Node's `connectionsCheckingInterval` is set to a
      quarter of the shortest timeout (≤ 30 s) so short timeouts fire on time, and
      `headersTimeout` is clamped to `requestTimeout` (Node requires it). Node's own
      `requireHostHeader` is off (the Host rules are the kernel's on both backends). The kernel
      writes `Connection` itself, so Node adds no `Keep-Alive: timeout=` header. Upgrade/CONNECT
      answers are raw HTTP/1.1 on the detached socket, linger bounded at 10 s. `closeServer`
      completes on the next turn after `server.close()` (as `closeListener`); its deadline timer
      is unref'd. An upgrade request with a body still gets its token in JS (Node gives no clean
      way to read that body; untested, WS5 may revisit). A client that half-closes right after
      its request: Node (httpAllowHalfOpen off) aborts the request and ends the socket, where
      native answers it first. A closed socket's keys are forgotten (native `ConnGone`).
  - Plan problems found: (1) B.2 "createServer unchanged" vs. a real `serverPort` for port 0
    (above). (2) WS1's callback-mode listener still posted `ListenerClosed` with its id into the
    Socket tables, where it could close an unrelated Socket listener with the same id; it no
    longer posts in callback mode. (3) §3.4 "reading stops" would hide a client's disconnect
    while Elm answers, so a never-answered request would keep the program alive forever (above).
    (4) Node's 30 s default `connectionsCheckingInterval` makes `headersTimeout`/
    `requestTimeout` coarse (E.2 says only "set to the options").
- 2026-10-08 — **WS3 done** (`worktrees/p12e`). HTTPS for `Http.Server`:
  `Tls/TlsContext.{hpp,cpp}` (additive: `TlsServerMode { alpnNoAck, h2Ciphers }` as a defaulted
  last parameter of `buildTlsServerConfig`, `TlsServerConfig::alpnNoAck`; the select callback
  returns `SSL_TLSEXT_ERR_NOACK` on no overlap in that mode; `Socket.Tls.listen` passes the default
  and keeps the fatal alert), `HttpServer/HttpServer.cpp` (`createServerWith` with `tls`: the pool
  job builds the server context — NoAck, the server's own ALPN list `httpServerAlpn`, the
  RFC 9113 §9.2.2 TLS 1.2 list (ECDHE + AES-GCM/ChaCha20) when `http2` — then `tcpListenOn`; the
  completion hands `makeTlsServerFactory(cfg)` to the listener; `ServerConfig.tls`/`http2`),
  `HttpServer/HttpTables.{hpp,cpp}` (`httpTablesStartServer(…, TransportFactory transport =
  nullptr)`; the callback-mode factory is now `makeServerProtocol`), `HttpServer/Http1.{hpp,cpp}`
  (`makeServerProtocol`: runs after the handshake, dispatches on `Conn::tlsInfo()->alpn`, `"h2"` →
  WS8 hook, else `makeHttp1Protocol`; `ServerConfig::http2`), `HttpServerServiceWin32.cpp` (stub),
  `system-kernel-cpp/CMakeLists.txt` (`EcoSystem_HttpServer` links `EcoSystem_Tls`),
  `src/Http/Server.elm` (docs: https URLs, ALPN, `http2` serves HTTP/1.1 until WS8, an example;
  the fallback `Url` of an unparsable URL is `Https` under TLS), `src/Eco/Kernel/HttpServer.js`
  (`https.createServer`, per-connection ALPN, `flags` bit 2, `https://` URLs, the h2 cipher list,
  closeServer aborts TLS handshakes in progress), new `test/eco-system/src/HttpServerTlsTest.elm`
  (raw HTTP/1.1 over `Socket.Tls` clients with the test CA, both backends: `https://` URLs; ALPN
  `http/1.1` with the user's server `alpn = ["h2"]` ignored; a client offering `h2,http/1.1` gets
  `http/1.1`; offering only `http/1.0`, or nothing → no ALPN and served (NoAck); keep-alive and
  `Connection: close` over TLS; HTTP/1.0 over TLS; `http2 = True` without TLS → `EINVAL`, with TLS
  accepted (ALPN `http/1.1`); an unusable key → `ERR_SSL_*`). `SocketTlsAlpnTest` (unchanged)
  still checks `Socket.Tls.listen`'s fatal alert on no overlap.
  - Results: native `eco-system/HttpServer` 16/16 (`/tmp/eco-p12e-native-http.txt`),
    `eco-system/SocketTls` 7/7 (`/tmp/eco-p12e-native-sockettls.txt`), `eco-system` 125/125
    (`/tmp/eco-p12e-native-ecosystem.txt`); JS `run-js-e2e` `eco-system/HttpServer,
    eco-system/SocketTls` 23/23 (`/tmp/eco-p12e-js.txt`); core test 1698 checks / 0
    (`/tmp/eco-p12e-core.txt`); `check-root-bounded` and `check-kernel-homes` ok
    (`/tmp/eco-p12e-rootbound.txt`, `/tmp/eco-p12e-homes.txt`); `full` green (core 1698 / 0, native 2285/2285, JS 123/123 + the 2 Appendix E skips, `/tmp/eco-p12e-full.txt`). No validate tree or
    stress run (optional for this phase; no GC-facing code changed: the only heap read is the
    `Just ( chain, key )` copy-out inside the G3 scope). No pinned kernel file changed (license
    manifest untouched).
  - Decisions / deviations:
    - **`http2 = True` is accepted** (with `tls`) and serves HTTP/1.1 until WS8: §3.5's
      `["h2", "http/1.1"]` would let a client choose `h2` and then get HTTP/1.1 bytes, so
      `httpServerAlpn` (native) / `_HttpServer_alpnList` (JS) offer only `http/1.1` for now — WS8
      changes that one function on each backend. The TLS 1.2 cipher restriction is already applied
      when `http2` is set (JS: the same TLS 1.2 list plus the three TLS 1.3 suites, without which
      Node would disable TLS 1.3). The ALPN dispatch in `makeServerProtocol` is in place
      (`"h2"` branch empty).
    - The user's `ServerOptions.alpn` is not passed to the kernel at all (the B.2 tls shape
      `Maybe ( certificateChain, privateKey )` from WS0 already dropped it).
    - Certificate/key failures: native `ERR_SSL_<REASON>` from the PEM/X509 error (as
      `Socket.Tls.listen`); JS the same checks as `Tls.js`'s listen (leaf certificate, key, pair),
      mapped with `Tls.js`'s `code`/`errorMessage` (imported by `HttpServer.js`).
    - JS NoAck (**plan problem, E.2**): `https.createServer({ ALPNProtocols: ['http/1.1'] })`
      answers a client with no common protocol with a fatal `no_application_protocol` alert (Node
      22: `SelectALPNCallback` returns `SSL_TLSEXT_ERR_ALERT_FATAL`; an `ALPNCallback` returning
      `undefined` does the same, any other value must be one of the client's protocols), so E.2 as
      written cannot meet §3.5. `HttpServer.js` therefore replaces `tls.Server`'s `'connection'`
      listener: it reads the ClientHello (records reassembled, at most 64 KiB, 120 s), parses the
      ALPN extension, `unshift`s the bytes (TLSSocket feeds a raw socket's buffered data to the
      handshake) and calls the original listener with `server.ALPNProtocols` set for that one
      connection: the server's list when the client offers one of its protocols or no ALPN, none
      otherwise (the offer is then ignored, as native NoAck). This relies on `tlsConnectionListener`
      reading `this.ALPNProtocols` per connection (internal, Node 22; verified by probe and the
      test). WS8 can reuse it for `http2.createSecureServer` (same `tls.Server` base).
    - JS: closeServer destroys connections still in their TLS handshake (native: the listener
      aborts them); requests are tracked on the `TLSSocket` (`'secureConnection'`), raw sockets
      also on `'connection'` so the close deadline reaches them.
    - No Core unit test for the NoAck callback (covered end to end by `HttpServerTlsTest` on both
      backends).
- 2026-10-08 — **WS4 done** (`worktrees/p12d`): WebSocket core, client and socket-level server,
  Whole mode, no streaming, no compression. C++ `src/eco-system/WebSocket/`: `WsFrame` (pure
  decoder/serializer, UTF-8, close payloads), `WsProtocol` (`WsCore` + the `WsPort` interface +
  `WsProtocol`, the `ConnProtocol` over a `Conn`), `WsHandshake` (key/accept, HTTP heads, `DialJob` +
  `DialProtocol`, `UpgradeReadProtocol`, `HoldProtocol`), `WsChannel` (the two stream faces),
  `WsEvents` (POD queue + drain), `WsTables` (handshake ids, WebSockets, pending dials, dispatchers),
  `WsManager` (C.2), `WebSocket`/`WebSocketExports` (B.1 bodies); `Socket/Conn.{hpp,cpp}`
  (`setConnectCallback`); `CMakeLists.txt`. Elm: `WebSocket.elm` (dial result, `abandon`, no
  `handshakeTimeout`, no deflate offer yet), `WebSocket/Internal/Handshake.elm` (version ≥ 1.1, the
  full RFC 6455 §9.1 extension grammar). JS: `Eco/Kernel/WebSocket.js` (codec, dial, readUpgrade,
  kernels, manager kernels), `Socket.js` (`_Socket_detach`), `Stream.js` (duplex `detach`; fixes
  WS1's `A1(...)` calls in the mapped paths: Elm defines no `A1`). Tests: `tests/HandshakeTest.elm`
  (96 cases); core `testWsFrameCodec`, `testWsHttpHeads`; E2E `WebSocket{Echo,Fragments,
  HandshakeServer,HandshakeClient,EarlyFrame,FramingErrors,Utf8,Close,CloseTimeout,Heartbeat,
  Subscription,Exit,Tls,Url}Test` + helpers `WebSocketTestHelp`, `WebSocketSha1` (pure-Elm SHA-1
  for raw servers); `WebSocketSmokeTest` updated (a dial to port 1 is refused; the zone URL case is
  in HandshakeTest); stress `EcoSystemWebSocket.elm`; `test/conformance/{elm.json,WsEchoServer.elm}`.
  Results: eco/system elm tests 853/853 (`/tmp/eco-p12d-elmtests1.txt`); core test 1651 checks / 0
  (`/tmp/eco-p12d-core1.txt`); native `--filter eco-system` 128/128
  (`/tmp/eco-p12d-native-ecosystem.txt`); JS `run-js-e2e` 126 passed + the 2 Appendix E skips
  (`/tmp/eco-p12d-js-full.txt`); validate tree `eco-system/WebSocket` with poison + gc-pressure
  15/15 (`/tmp/eco-p12d-validate-ws1.txt`); stress `EcoSystemWebSocket -n 10` under validate PASSED
  (`/tmp/eco-p12d-validate-stress1.txt`; natively about 8 s); root-bound and kernel-homes ok
  (`/tmp/eco-p12d-rootbound.txt`, `/tmp/eco-p12d-homes.txt`); license manifest unchanged;
  `full` green (`/tmp/eco-p12d-full.txt`: core 1651 checks / 0, JIT E2E 2288/2288, JS 126 passed + 2
  skips). Autobahn|Testsuite 25.10.1 `fuzzingclient`, cases 1–7 and 9 (300 cases) against
  `WsEchoServer`: JS backend 297 OK + 3 INFORMATIONAL, no failure (`/tmp/eco-autobahn/reports-js`);
  native (`eco-boot-native` binary of `WsEchoServer`) 290 OK + 7 NON-STRICT (3.2, 3.3, 4.1.3,
  4.1.4, 4.2.3, 4.2.4, 5.15) + 3 INFORMATIONAL, all close behaviours OK, no failure
  (`/tmp/eco-autobahn/reports-native`). NON-STRICT = the connection failed before the echo of the
  valid message that preceded the bad frame: the echo is written by Elm after its read, and failing
  the connection stops writes at once (the peer's bad frame was in the same TCP read); Autobahn
  accepts both orders. Runs: `/tmp/eco-autobahn/` (wstest from `/tmp/ws-facts/dl-pypy`,
  `fuzzingclient-{js,native}.json`, `summarize.py`).
  - Resolved WS0 problems: (1) `dial` returns `(hsId, (status, isH2), headers)`; (2) kernel
    `abandon : Int -> Task Never ()` releases a dialed (or read) handshake id whose response Elm
    refuses or whose `open` failed; (3) `AcceptOptions.handshakeTimeout` is **removed**:
    `upgradeRequest` reads the request within a documented 30 s (an `upgradeRequestWith` can come
    later without breaking anything); A.1, B.1 and §3.6 updated.
  - Decisions / deviations:
    - `http2 = True` dials HTTP/1.1 (ALPN offers only `http/1.1`; `isH2` is always False) until WS9.
      The client sends no permessage-deflate offer (`offeredCompression` returns `Nothing`) and the
      server declines every offer until WS7, whatever the options say; an extension in a response
      fails the handshake (not offered).
    - `Conn` gained a client connect callback (`setConnectCallback`): `dial` drives one client Conn
      per address itself instead of the Socket tables' `Connected` event. The DialJob's own
      `resolved` atomic races the kill handle (as `Conn::cancelConnect`).
    - Two files beyond §4's list: `WsChannel` (the faces) and `WsEvents` (the queue).
    - CloseInfo is the first Close received (D.5): for the side that closes first it is the peer's
      echo (its code, usually no reason). `closed` and `onClose` complete when the close handshake
      is through (both Close frames), not when TCP is gone; the server then closes TCP
      (`closeGraceful`, FIN + 2 s drain) and the client waits for the FIN (close timeout), in the
      background. A connection that fails or ends without a Close posts at once.
    - Readable end reasons: clean → `Closed`; failures per D.9 (`ERR_WS_PROTOCOL: …`,
      `ERR_WS_INVALID_DATA: …`, `ERR_WS_MESSAGE_TOO_BIG`, `ERR_WS_INTERNAL_ERROR: the writable was
      cancelled`); EOF/abort without a Close `socket closed`; transport errors `read <CODE>`;
      heartbeat timeout `heartbeat ETIMEDOUT` (W5; not listed in D.9). A failed connection's
      CloseInfo is our code and text (≤ 123 bytes), clean False; heartbeat timeout is `Abnormal ""`.
    - Already-complete messages stay readable before the readable's error (they were valid).
    - Reading pauses at 1 MiB or 1 024 queued messages (§3.6 "high watermark"); messages over
      256 KiB are sent in 256 KiB fragments, handed to the transport while its queue is below
      64 KiB, so pongs wait behind at most one fragment. TCP_NODELAY is set on WebSocket
      connections (both backends).
    - `ping` times out after the heartbeat timeout, or 30 s without a heartbeat; a pong answers its
      ping and every earlier one. The heartbeat ping payload has its top bit set, `ping`'s not.
    - Keep-alive (§3.6): one count per subscribed connection while open (onMessage) / until its
      close is delivered (onClose), rather than one per subscription (same liveness). Heartbeat and
      close timers hold nothing. A local close (`close`, `closeWritable`, `cancelWritable`) holds one
      until `Closed`.
    - `readUpgrade` answers a request that is not HTTP (or a head over 64 KiB) with 400 and closes;
      `EBUSY` while a face has a read, write or close in flight; the faces' leftover bytes go to the
      handshake. Closed WebSockets keep their CloseInfo in the table until both stream faces are
      gone, then in a FIFO of the 4 096 most recent (for late `closed` calls).
    - `reject` clamps the status to 100–999, drops headers with CR/LF/NUL or an invalid name and the
      user's `Content-Length`/`Transfer-Encoding`/`Connection` (it sets them itself).
    - The native manager retries `attachReader` on every `onEffects`; the JS one every 5 ms while
      its listener process lives (it cannot see onEffects).
    - The close timeout is not configurable, so `WebSocketCloseTimeoutTest` takes 30 s (split out of
      `WebSocketCloseTest`). `WebSocketExitTest` uses a Node client spawned `Detached` (NoShell).
  - Plan problems / notes for later phases:
    - WS5 (`Http.Server.upgradeRequest`): `takeUpgrade` should park the connection in a
      `HoldProtocol` (WsHandshake.hpp, with the bytes after the head as its leftover) and register it
      in `wsTables().handshakes` (main thread; ids shared with `readUpgrade`/`dial` through
      `nextHsId`), then `open`/`reject`/`abandon` work unchanged. `open` installs the codec with
      `Conn::setProtocol(std::make_unique<WsProtocol>(core), leftover)`.
    - WS6: `WsDecoder` assembles whole messages; streamed mode needs a per-fragment payload callback
      (the payload chunks are at hand inside `feed`) and `WsCore` a body lane; `open` and the JS
      `open` fail `ENOTSUP` for mode 2 today, `openOutgoing` too.
    - WS7: `WsDecoder::startFrame` rejects RSV1 unconditionally; it must allow it on a message's
      first frame once deflate is negotiated (`WsConfig` gets the parameters); `offeredCompression`
      must return `options.compression`; the module docs already describe compression as on.
    - WS9: `WsCore` talks only to `WsPort` (`portWrite`, `portOutbound`, `portSetDeadline`,
      `portUpdateInterest`, `portCloseGraceful` = END_STREAM, `portAbort` = RST_STREAM(CANCEL)); an
      `H2StreamPort` calls `attach` and the `port*` entry points. Timer ids are the `Conn` ones
      (`kTimerHeartbeat`, `kTimerPong`, `kTimerCloseHandshake`): an h2 port must keep per-stream
      deadlines itself (the Conn's are per connection). `DialJob` is where the h2 client attempt
      goes (ALPN `h2,http/1.1`, `isH2` in the Dialed event).
    - p12c merge: `Socket/Conn.{hpp,cpp}` gained only `setConnectCallback` (three small hunks).
- 2026-10-08 — **WS5 done** (`worktrees/p12g`): `Http.Server.upgradeRequest` over HTTP/1.1, plain
  and TLS. Native: new `HttpServer/HttpUpgrade.cpp` (`httpServerTakeUpgradeBody`, S mode: main
  thread `httpTablesTakeUpgrade` consumes the key and returns the kept raw request; the connection
  is registered with `wsTablesAddServerHandshake` (new, `WsTables.{hpp,cpp}`; ids from `nextHsId`);
  a reactor command, submitted before any `open`, runs `Http1Protocol::takeUpgradeHead` and
  `Conn::setProtocol(HoldProtocol, head)`; the result is `readUpgrade`'s shape, version from the
  request flags), `HttpServerExports.cpp` (`takeUpgrade` bound to it), `HttpServer.hpp`/`.cpp`
  (declaration, header comment), `system-kernel-cpp/CMakeLists.txt` (`HttpUpgrade.cpp`;
  `EcoSystem_HttpServer` links `EcoSystem_WebSocket`). `Http1.{hpp,cpp}` and the WebSocket kernels
  are unchanged: `open`/`reject`/`abandon` work on the new ids as they are. Elm: `Http.Server.
  upgradeRequest` fails `EINVAL` at once when `request.upgrade /= Just "websocket"`, docs (101
  after earlier pipelined responses, `closeServer` leaves the WebSocket open, errors). JS:
  `HttpServer.js` (`'upgrade'` entries keep method, target, version, raw headers and their own
  error listener; `takeUpgrade` removes the socket (and a TLS socket's raw parent) from the
  server's set, clears node's socket timeout, consumes the key and calls the new
  `_WebSocket_parkUpgrade` in `WebSocket.js`, which parks the socket with the `'upgrade'` head as
  a handshake id). Tests: new helper `test/eco-system/src/HttpServerWebSocketHelp.elm`, new
  `HttpServerWebSocketTest` (raw pipelined `GET /slow` (300 ms) + opening request + a masked frame
  in one write → 200, then 101, then the early frame's echo, only frames after the 101 although
  the `Response` is sent after the upgrade; second `upgradeRequest` → `EINVAL`; `upgradeTarget`
  keeps the query; `upgradeRequest` on a plain request → `EINVAL`; a `WebSocket.connect` client
  plus an ordinary request on the same port while it is open; declined 426 → `Connection: close`
  + closed; `closeServerWithin 100` → new connections refused, the upgraded WebSocket still echoes
  after 500 ms), `HttpsServerWebSocketTest` (the same over TLS: raw `Socket.Tls` pipelined case,
  `wss://localhost` client with the test CA, closeServer case); `WebSocketSmokeTest` now expects
  `upgradeRequest: EINVAL: upgradeRequest EINVAL: the request does not ask for a WebSocket …` (was
  the WS0 stub's `ENOTSUP`). `README.md` WebSocket line. Neither new test is SKIP-JS.
  - Results: native `eco-system/HttpServerWebSocket` 1/1 and `eco-system/HttpsServer` 1/1
    (`/tmp/eco-p12g-native-http2.txt`, `/tmp/eco-p12g-native-https1.txt`; the first
    `eco-system/HttpServer` run, `/tmp/eco-p12g-native-http1.txt`, had 16/17 with the new test
    failing to compile: the helper imported `Url`, which the test project does not depend on),
    `eco-system/WebSocket` 15/15 (`/tmp/eco-p12g-native-ws1.txt`), `eco-system` 141/141
    (`/tmp/eco-p12g-native-ecosystem.txt`); JS `run-js-e2e`
    `eco-system/HttpServer,eco-system/HttpsServer,eco-system/WebSocket` 33/33
    (`/tmp/eco-p12g-js1.txt`); core test 1769 checks / 0 (`/tmp/eco-p12g-core.txt`);
    `check-root-bounded` and `check-kernel-homes` ok (`/tmp/eco-p12g-rootbound.txt`,
    `/tmp/eco-p12g-homes.txt`); `full` green (`/tmp/eco-p12g-full.txt`: core 1769 / 0, JIT E2E
    2301/2301, JS 139 passed + the 2 Appendix E skips). No validate tree or stress run (the only
    heap code is the S body's result, built under one `StackRootGuard` as `onUpgradeRead`). No
    pinned kernel file changed (license manifest untouched).
  - Decisions / deviations:
    - The kernel body lives in a new `HttpUpgrade.cpp` rather than `Http1.cpp` (§4 WS5 "Files"):
      it needs WebSocket's tables and `HoldProtocol`, and keeping `Http1.*` untouched avoids
      conflicts with WS8 (p12f), which edits the HTTP/1.1 files in parallel.
    - `takeUpgrade` errors: `EINVAL` (unknown, answered, already taken, parked or non-upgrade key;
      also a key whose `ConnGone` was drained), `ECANCELED "socket closed"` (the `Conn` object is
      gone). A connection that closed after its key was taken but before the reactor command ran
      stays as it was; `open` then fails `ECONNRESET "socket closed"` (WS4 behaviour). B.2 row
      updated.
    - The token check (`"websocket"`) is in Elm; the kernel accepts any upgrade token, so a
      `Response` paired with another request's `Request` still reaches `accept`'s D.3 checks (400).
    - An upgraded connection still counts against `maxConnections` until it closes (native: the
      listener's open count; JS: node's `server.maxConnections`). It stays in the server's
      reactor-side connection map only for the heap-reset sweep; `closeServer` skips it (WS2).
    - Like a `readUpgrade` handshake, a taken upgrade nobody accepts or rejects keeps its
      connection parked (no timeout; WS4 semantics).
  - Plan problems: none new. §4 WS5 lists `HttpServer.js` "synthesising the `Request`" in the
    `'upgrade'` listener: WS2 already did that; WS5 only keeps the data `takeUpgrade` needs.

- 2026-10-08 — **WS8 done** (`worktrees/p12f`). HTTP/2 in `Http.Server` on nghttp2 1.70.0:
  `system-kernel-cpp/CMakeLists.txt` (Route B: `FetchContent_Declare(nghttp2 URL … URL_HASH SHA256=aa31…
  SOURCE_SUBDIR eco-no-cmake)`, generated `nghttp2-gen/nghttp2/nghttp2ver.h` (1.70.0 / 0x014600),
  `nghttp2_objects` OBJECT library from `lib/*.c` (count checked = 26; C99, PIC, hidden; zero
  warnings), merged into `libEcoSystem_HttpServer.a`; POSIX only; the core test gets the include
  dirs), new `HttpServer/Http2.{hpp,cpp}` (`Http2Protocol`, `H2Shared`, `makeHttp2Protocol`,
  WS9 hooks), `HttpServer/Http1.{hpp,cpp}` (`makeServerProtocol`: `"h2"` → `makeHttp2Protocol`
  when the server has `http2`; `http1Respond` / `http1ServerClosing` dispatch to `Http2Protocol`
  too — names kept; `ServerConfig::maxConcurrentStreams`), `HttpServer/HttpServer.cpp`
  (`httpServerAlpn(http2)` = `["h2", "http/1.1"]`; `maxConcurrentStreams` copied from the B.2
  slot), `src/Eco/Kernel/HttpServer.js` (`_HttpServer_alpnList` offers `h2` with `http2`;
  `_HttpServer_createH2Server`: `http2.createSecureServer({ allowHTTP1: true, settings: {
  enableConnectProtocol, enablePush: false, initialWindowSize 64 KiB, maxConcurrentStreams only
  when set, maxHeaderListSize } })`, the WS3 NoAck ClientHello peek reused unchanged;
  `_HttpServer_onH2Request` / `_HttpServer_writeH2`; sessions tracked for `closeServer`),
  `src/Http/Server.elm` (docs only: `http2`, `maxConcurrentStreams`, header names, URL),
  `system-kernel-cpp/README.md` (new "Bundled third-party code": llhttp and nghttp2, MIT text),
  tests: `test/eco-system/src/HttpServerH2Help.elm` (program + peers: writes the test CA and a Node
  script `h2.js` into a temp dir; `curl --http2 --cacert … --resolve`, `node h2.js <mode>`: Node
  `http2` client modes `concurrency`/`close`/`connect`, raw-frame modes `rapid-reset`/`limit`/`big-header`, the last with a digits-only HPACK
  `:status` decoder),
  `HttpServerHttp2Test`, `HttpServerHttp2ConcurrencyTest`, `HttpServerHttp2LimitsTest`,
  `HttpServerHttp2CloseTest` (all on both backends, no SKIP-JS), `HttpServerTlsTest` (http2 + TLS
  now negotiates `h2`), Core `testHttp2Protocol` (nghttp2 client session over a socket against a
  plain callback-mode listener: SETTINGS, mapping, cookies, toH2Nv filtering, 1xx → 500, HEAD,
  400/413/501, extended CONNECT delivered with `upgrade` and answered + RST(NO_ERROR), reset key,
  GOAWAY on closeServer, the cap, ConnGone per key).
  - Results: core test 1753 checks / 0 (`/tmp/eco-p12f-core2.txt`); native
    `eco-system/HttpServer` 20/20 (`/tmp/eco-p12f-native-http.txt`), `eco-system` 129/129
    (`/tmp/eco-p12f-native-ecosystem.txt`); JS `run-js-e2e eco-system/HttpServer` 20/20
    (`/tmp/eco-p12f-js-http2.txt`; the first run, `/tmp/eco-p12f-js-http.txt`, failed the
    concurrency test's strict reverse-order check under load: relaxed, see below);
    `check-root-bounded` ok, `check-kernel-homes` ok (`/tmp/eco-p12f-rootbound.txt`,
    `/tmp/eco-p12f-homes.txt`); AOT `run-aot-e2e eco-system/HttpServerHttp2` 4/4
    (`/tmp/eco-p12f-aot-h2.txt`: the nghttp2 objects are in the archive the AOT driver links);
    `full` green on the third run (core 1753 / 0, native 2289/2289, JS 127/127 + the 2
    Appendix E skips, `/tmp/eco-p12f-full.txt`; runs 1 and 2: below). No validate tree or stress
    run (no GC-facing code changed: Http2 is reactor-only POD; the heap paths are WS2's). No
    pinned kernel file changed (license manifest untouched). The Limits test and the curl helper
    changed after the native/JS filter runs above; their last runs: native and JS
    `HttpServerHttp2*` 4/4 (`/tmp/eco-p12f-native-h2b.txt`, `/tmp/eco-p12f-js-h2b.txt`) and `full`.
  - **h2spec 2.6.0 baseline** (informational, `-t -k`, against a scratch `createServerWith { tls,
    http2 = True, maxConcurrentStreams = Just 100 }` program answering 200 "ok"; outputs
    `/tmp/eco-p12f-h2spec/h2spec-{native,js}.txt`): **native 136/146** (1 skipped, 9 failed),
    **JS 133/146** (1 skipped, 12 failed); a plain Node server scored 128/146 (WF8). The 9 native
    failures are a subset of Node's: nghttp2's lenient handling of frames on closed / half-closed
    streams (5.1 #5, #8, #9, #11, #12; 5.1.1 #2), PRIORITY frames ignored (5.3.1 #2, 6.3 #1:
    `NO_RFC7540_PRIORITIES`), and 6.9.1 #3 (stream window overflow ends the connection instead of
    RST_STREAM). Later phases: not worse than these.
  - Decisions / deviations:
    - The plan's options list: `nghttp2_option_set_no_rfc7540_priorities` does not exist; it is
      `SETTINGS_NO_RFC7540_PRIORITIES = 1` in the initial SETTINGS. Options set:
      no_auto_window_update, max_continuations 8, stream_reset_rate_limit (1000, 33),
      max_outbound_ack 1000, max_settings 32.
    - **Rapid reset → GOAWAY(INTERNAL_ERROR), not ENHANCE_YOUR_CALM (plan problem):** nghttp2's
      stream reset rate limiter answers with `GOAWAY(last_recv_stream_id, INTERNAL_ERROR)` (a
      graceful GOAWAY: no new streams; the connection ends when no stream is active), and Node 22
      does exactly the same (probe: 1100 HEADERS+RST → `goaway last 2001 INTERNAL_ERROR`). A second,
      own limiter could send ENHANCE_YOUR_CALM natively but not on JS (Node's fires first), so both
      backends keep nghttp2's behaviour and `HttpServerHttp2LimitsTest` expects INTERNAL_ERROR.
    - `maxConcurrentStreams = Just n` natively: the input is fed to nghttp2 one frame at a time
      and stops at a frame boundary while n requests are delivered and unanswered (reset ones
      included, until answered or the connection closes); reading continues up to 64 KiB so a FIN
      or reset is noticed. Queued answers are framed *before* held input is fed (an answered stream
      closes when its END_STREAM is out; otherwise nghttp2 refuses the next stream as over the
      advertised limit). `Just 0` advertises 0 (nghttp2 refuses every stream) and does not hold
      input. **JS:** Node refuses streams over the limit (REFUSED_STREAM) and cannot count reset
      streams; the test checks only what both share (the 11th of 11 is not served while the first
      10 wait; natively it is answered after the first answer, Node refuses it).
    - Node enforces `MAX_HEADER_LIST_SIZE` itself (RST_STREAM ENHANCE_YOUR_CALM), so JS
      advertises twice `maxHeaderSize` and answers 431 itself above `maxHeaderSize` (native
      advertises `maxHeaderSize`); both count name + value + 32 incl. pseudo fields.
    - h2 limits beyond §3.8: a `content-length` over `maxBodySize` is answered 413 at the end of
      the headers (both backends), as HTTP/1.1. Timers: `headersTimeout` for a fresh connection's
      first bytes, `keepAliveTimeout` with no stream open → GOAWAY(NO_ERROR) and close,
      `requestTimeout` per stream still receiving its request → 408 + RST(NO_ERROR). JS has none of
      these for h2 (Node's own), documented in `HttpServer.js`.
    - Own answers and answers to a CONNECT that is not handed off: the response, then
      `RST_STREAM(NO_ERROR)` in `on_frame_send` of our END_STREAM, only if the client's side is
      still open (RFC 9113 §8.1). A plain CONNECT (no `:protocol`) is delivered without a token
      (as HTTP/1.1). `Expect` is not read over h2 on either backend (Node's compat events are
      routed to the h2 handler). `respond`'s `forceClose` has no meaning over h2 (closeServer's
      GOAWAY covers it).
    - `respond` completes when the frame carrying END_STREAM was handed to `Conn::write` and that
      write finished (the dones of a flush batch ride on its write), ECANCELED when the stream
      ends first. A reset stream's key stays outstanding until `respond` (which then reports it
      gone, completing at once) or the connection closes (ConnGone for every key of the
      connection, from the close hook). The url scheme is `:scheme` (http/https), else https.
    - Connection closing: when nghttp2 wants neither read nor write; or (peer FIN / closeServer)
      with no stream that can still be answered (after a FIN a request still arriving cannot
      complete); closeServer's deadline aborts (tunnels included, WS9).
    - JS: `Http2SecureServer` (Node 22) ignores the HTTP/1 options of its constructor, so
      `maxHeaderSize`, `requestTimeout`, `headersTimeout`, `keepAliveTimeout`,
      `connectionsCheckingInterval`, `requireHostHeader`, `joinDuplicateHeaders` are set as
      properties (read by Node's HTTP/1 connection listener; verified by probe: 431, 408).
      Multi-valued response headers Node only allows once fall back to the last value.
    - Third-party notice: no llhttp notice existed anywhere in the repo; both are now listed in
      `system-kernel-cpp/README.md` ("Bundled third-party code").
    - `HttpServerHttp2ConcurrencyTest` answers the latest request first, 3 ms apart, and checks
      only the ends of the completion order (first among the last ten, last among the first ten):
      Node batches neighbouring answers under load (seen `99,96,97,98,…`).
    - The 431 check uses the raw Node peer, not curl: the first `full` run
      (`/tmp/eco-p12f-full-run1.txt`, otherwise green: core 1753 / 0, native 2288/2289) failed it
      with curl exit 92 — a client that already has the server's SETTINGS refuses to send a list
      over the advertised MAX_HEADER_LIST_SIZE, so with curl the outcome depends on timing.
    - The second `full` run (`/tmp/eco-p12f-full-run2.txt`, again only this test failing) hit
      curl exit 92 on a 413: curl 7.88 reports the server's RST_STREAM(NO_ERROR) after a complete
      response (sent when the upload is still open, RFC 9113 §8.1 — timing dependent) as an
      error. `HttpServerH2Help.curl` accepts exit 92 when the response was written to stdout.
      The four tests then passed natively under a 14-process CPU load
      (`/tmp/eco-p12f-native-h2-load.txt`).
    - h2spec ran against a scratch program, not `WsEchoServer --http2` (Appendix F; WS10).
  - Notes for WS9 (tunnels): `Http2Protocol` keeps an extended CONNECT stream in `Delivered`
    with `connect` set; its DATA is buffered in `Stream::tunnelIn` (connection window consumed,
    stream window **not**: at most 64 KiB wait). Hooks (reactor thread, on the Conn's protocol via
    `dynamic_cast<Http2Protocol*>`): `tunnelPending(key)`; `bindTunnel(c, key, head, handler,
    buffered&)` answers `head` (2xx, no END_STREAM; a deferred data provider), binds an
    `H2StreamHandler` (`onData(bytes)`, `onEnd()` = client END_STREAM, `onReset(code)` = stream
    closed, 0 when orderly, or connection gone), returns the stream id and the bytes received so
    far (not yet consumed); `tunnelConsume(c, sid, n)` (replenish the stream window as the codec
    takes bytes), `tunnelWrite(c, sid, bytes)` (DATA, resumes the deferred provider),
    `tunnelEnd(c, sid)` (END_STREAM after the queued bytes), `tunnelReset(c, sid, code)`
    (RST_STREAM, e.g. CANCEL), `tunnelQueued(sid)` (bytes not yet framed; there is no "drained"
    callback yet — add one if `H2StreamPort` needs write backpressure events). The main thread's
    `httpTablesTakeUpgrade` already keeps h2 upgrade requests (token "websocket"). None of the
    tunnel paths is exercised in WS8. `maybeClose` treats tunnels as live streams (GOAWAY leaves
    them open until they end or the closeServer deadline).
- 2026-10-08 — **WS6 done** (`worktrees/p12h`): streamed messages, both backends. C++
  `WebSocket/WsFrame.{hpp,cpp}` (decoder **raw data mode**: `onDataStart(opcode, compressed)` /
  `onDataChunk` / `onDataEnd` instead of whole messages; `utf8CompletePrefix`; an `encodeFrame`
  overload with RSV1), `WsProtocol.{hpp,cpp}` (`WsCore`: the bodies, the held input, the outgoing
  streams; `processInput` replaces the inline feed), `WsChannel.{hpp,cpp}` (`WsBodyChannel`,
  `WsOutChannel`), `WsEvents.hpp` (`BodyNeeded`, `BodyDispose`), `WsTables.{hpp,cpp}` (their
  dispatchers, `WsEntry::outSeq`), `WebSocket{,Exports}.cpp` + `WebSocket.hpp` (`open` mode 2,
  `openOutgoing`); `Stream/{Stream.hpp,StreamTable.hpp,Stream.cpp,StreamPipe.cpp}` (text channel
  sources: a read result with `ChannelResult::text` becomes a String; `createTextChannelSink`;
  `discardReadable`); `Eco/Kernel/Stream.js` (the same: string chunks, `createTextChannelSink`,
  `discardReadable`), `Eco/Kernel/WebSocket.js` (decoder raw mode, bodies, held input, outgoing
  streams, `openOutgoing`); `src/WebSocket.elm` (docs; `sendStream` cancels its sink when the pipe
  fails). Tests: `WebSocketStreamedTest` (100 MiB `sendBinary` → server pipes its body back with
  `sendBinary` → client reads it to the end, pattern-checked; a streamed text; an empty streamed
  message), `WebSocketStreamedMemoryTest` (VmRSS from /proc/self/status via `System.File`: 100 MiB
  each way, body left unread 1.5 s then cancelled: < 32 MiB growth), `WebSocketStreamedCancelTest`,
  `WebSocketStreamedUtf8Test`, `WebSocketSendStreamInterleaveTest`; helpers in `WebSocketTestHelp`
  (`patternSource`, `readPatternBody`, `rssKiB`, `parseFramesFin`, …). None SKIP-JS.
  - Results: see the WS7 entry (one verification run covers both phases; WS6's tests were also
    run alone on both backends while developing: green).
  - Decisions / deviations:
    - **Body pairs** are plain channel sources created on the main thread from a `BodyNeeded`
      event posted when a message starts; the core announces the message (`( 3 | 4, "<pairId>",
      _ )`) once `bodyReady` brings the id back; a pair nobody can receive any more (readable
      cancelled first) is dropped (`BodyDispose` → `discardReadable`). JS creates the pair
      synchronously.
    - **Text** bodies and text sends needed String-valued channel pairs (§3.3 has only Bytes and
      mapped pairs): a channel source whose read result has `text` set yields a String (both
      backends); `createTextChannelSink` is a writable of Strings. Body chunks are whole characters
      (an unfinished character waits), coalesced up to 256 KiB per read; reading pauses while 1 MiB
      waits in a body.
    - **Held input**: after a streamed message's last frame nothing more is decoded (control frames
      behind it included) until its body was read to `Closed` or cancelled. A cancelled body's
      message is still decoded (and inflated, validated) to its end. `maxMessageSize` does not apply
      in the streamed mode (documented).
    - Data received before a failure stays readable on the body, then the failure: a Close in the
      middle of a message fails the body `Cancelled "socket closed"` (the readable ends `Closed`);
      a connection failure gives the readable's reason. Our own Close fails an unfinished body the
      same way and releases the hold. `cancelReadable` on the readable during a body lets that body
      finish; later messages are discarded.
    - **Outgoing streams**: `openOutgoing` (S mode, not R: B.1 updated) puts a placeholder in the
      data FIFO with a reactor command submitted before the id is returned. Chunks go out as non-FIN
      fragments (split at 256 KiB, empty chunks skipped); the end is a FIN frame: an empty
      continuation (`0x00` when compressed, WS7) or one empty frame with the opcode for an empty
      stream. An abort after the first fragment fails the connection with 1011; before it, the
      stream is dropped quietly (a pipe that never started, e.g. a locked source: `sendStream`
      cancels its sink when `pipeTo` fails); a `WsOutChannel` destroyed unclosed aborts.
    - JS raw-mode chunks are unmasked in place and passed as views (no copy per frame).
  - **Plan problem (runtime, not WebSocket): large `Bytes` are never reclaimed.** A plain Elm loop
    that allocates and drops 1 000 × 256 KiB `Bytes` grows VmRSS by about 300 MB, with no GC at all;
    with small-object churn (5 minor GCs) by 620 MB ("Lg-body freed (minor): 0"). Bodies at or above
    the large-object threshold (8 KiB) go to the old generation, their allocation triggers no
    collection, and a minor GC does not free them. Any eco/system stream that hands big chunks to
    Elm (files, sockets, HTTP, WebSocket bodies) therefore grows by the volume it delivers until a
    major GC happens. §4's "100 MiB both ways with bounded memory, RSS-checked" cannot hold
    natively: the check was split — `WebSocketStreamedTest` checks the round trip,
    `WebSocketStreamedMemoryTest` the WebSocket layer's own buffering (stalled reader, cancelled
    body, both directions: no chunk reaches Elm). A runtime follow-up (large-body bytes as a GC
    trigger, and freeing dead young large bodies at minor GCs) is needed; not attempted here
    (allocator code, TLA-modelled).
- 2026-10-08 — **WS7 done** (`worktrees/p12h`): permessage-deflate, both backends. New
  `WebSocket/WsDeflate.{hpp,cpp}` (§3.7 engine: `Deflater` — raw deflate, window max(9, bits),
  sync flush, trailer stripped, `"\0"` for an empty message, `deflateReset` without takeover;
  `Inflater` — raw inflate 15, 00 00 ff ff appended, steps of ≤ 64 KiB, BFINAL accepted with the
  window kept (`inflateGetDictionary` / reset / `inflateSetDictionary`), reset without takeover,
  lazy zlib init); `WsFrame` (RSV1 allowed on a data message's first frame when negotiated: on a
  continuation or control frame 1002), `WsProtocol` (raw data mode for every message when deflate
  is on; inflated size checked against `maxMessageSize` inside the loop, 1009; streamed bodies
  pause inflating while full; invalid data 1007 "invalid compressed data: <zlib>"; whole messages
  ≥ `threshold` and every streamed chunk compressed); `WebSocket.cpp` (`open`'s deflate
  parameters); `CMakeLists.txt` (WsDeflate.cpp; zlib via `EcoSystem_Stream`).
  `WebSocket/Internal/Handshake.elm`: D.7 negotiation in both roles (`deflateParams`: unknown,
  repeated, valueless/valued-wrongly parameters, 8–15 without leading zeros, quoted values via the
  grammar; `negotiateServer`: first acceptable offer; `negotiateClient`: response checks).
  `WebSocket.elm`: `offeredCompression = options.compression`, `openParams` passes the threshold,
  docs. JS: `_WebSocket_deflater` / `_WebSocket_inflater` (zlib handles driven synchronously,
  `writeSync` as Stream.js; BFINAL: a new InflateRaw with the last 32 KiB of output as its
  dictionary) and the codec. Tests: elm `HandshakeTest` negotiation (48 cases, replacing the 3 WS4 ones); core
  `testWsDeflate` (RFC 7692 §7.2.3.1–.6 vectors both ways, takeover, BFINAL with a later
  back-reference, two blocks, stored block, window 8 → 9, streamed chunks + `0x00`, 64 MiB of
  zeros in ≤ 64 KiB steps, invalid data, decoder RSV1 rules, raw mode); E2E `WebSocketDeflateTest`
  (raw clients vs our server: the RFC bytes in, `f2 48 cd c9 c9 07 00` / `f2 00 11 00 00` out with
  takeover, threshold, no-takeover determinism, `server_max_window_bits=8`, declined, RSV1 on a
  continuation), `WebSocketDeflateMatrixTest` (our client vs our server: 7 option combinations,
  `compression` on both sides, echo intact), `WebSocketDeflateBombTest`, `WebSocketDeflateStreamedTest`
  (streamed + compressed with takeover; a cancelled compressed body still inflated so the next
  message, compressed against its window, arrives intact). Existing tests updated for the new
  defaults: `WebSocketEchoTest` (`compression True`), `WebSocketHandshakeClientTest` (the default
  offer in the request; "extension not offered" now with `compression = Nothing`; new cases:
  unknown extension, invalid deflate answer, deflate accepted).
  - Results (one verification run for WS6 + WS7, each command once per iteration, teed): eco/system
    elm tests 898/898 (`/tmp/eco-p12h-elmtests.txt`); core test 2113 checks / 0
    (`/tmp/eco-p12h-core.txt`); native `--filter eco-system/WebSocket` 24/24
    (`/tmp/eco-p12h-native-ws.txt`), `--filter eco-system` 148/148
    (`/tmp/eco-p12h-native-ecosystem.txt`); JS `run-js-e2e` `eco-system/WebSocket` 24/24, no
    skips (`/tmp/eco-p12h-js-ws.txt`); validate tree (poison + gc-pressure) `eco-system/WebSocket`
    24/24 on the second iteration (`/tmp/eco-p12h-validate-ws2.txt`; the first,
    `/tmp/eco-p12h-validate-ws.txt`, had `WebSocketDeflateBombTest` over its RSS bound — the
    gc-pressure heap configuration grows the heap by about 140 MB once at its first collections,
    in the regular build too, so the measured run now follows an unmeasured one — and
    `WebSocketFramingErrorsTest` timing out once under the load of the parallel 100 MiB tests: it
    passed alone under validate and in the second run); stress `EcoSystemWebSocket -n 10` under
    validate PASSED (`/tmp/eco-p12h-stress.txt`); `check-root-bounded` and `check-kernel-homes` ok
    (`/tmp/eco-p12h-rootbound.txt`, `/tmp/eco-p12h-homes.txt`); `full` green
    (`/tmp/eco-p12h-full.txt`: core 2114 checks / 0, JIT E2E 2308/2308, JS 146 passed + the 2
    Appendix E skips). No pinned kernel file changed (the license manifest covers no eco/system
    file).
  - Decisions / deviations:
    - **B.1 `open`**: the deflate `Bool` became the `threshold` Int (`-1` = none); the kernel
      needs the threshold and B.1 had no slot for it.
    - Negotiation (server): `server_no_context_takeover` when offered or without takeover;
      `client_no_context_takeover` when offered or without takeover; `server_max_window_bits` =
      min(offer, policy), sent when offered or below 15; `client_max_window_bits` never sent (we
      inflate with 15). Client: a response may omit `server_no_context_takeover` although asked
      (we can inflate with takeover: accepted, as ws does); `client_max_window_bits` only if
      offered and with a value; `server_max_window_bits` ≤ our limit. `compression` reports what
      each side does: `clientNoContextTakeover` is also True on a client that offered not to take
      over context, the window sizes are the effective ones.
    - Streamed messages are always compressed (threshold applies to whole messages); their final
      fragment is `0x00` (RFC 7692 §7.2.3.6) — an empty one would let the receiver's appended
      00 00 ff ff open a block that never ends, which broke the next message under context
      takeover (found by `WebSocketDeflateStreamedTest`).
    - The bomb: DEFLATE tops out near 1 032:1, so "1 KiB → 1 GiB" is impossible; the test sends a
      fixed-Huffman stream (158:1) that would inflate to 1 GiB (6.6 MB), and the server fails at
      16 MiB; in the streamed mode a 200 MiB bomb is stalled, then cancelled.
  - Autobahn|Testsuite 25.10.1 `fuzzingclient`, cases 12.* and 13.* (216 cases: permessage-deflate
    with every offer variant the suite makes, message sizes up to 128 KiB, window bits 8–15, context
    takeover on and off) against `test/conformance/WsEchoServer.elm` built from this tree (default
    `AcceptOptions`: compression accepted without context takeover): **native 216 OK, JS 216 OK**,
    every close behaviour OK (`/tmp/eco-p12h/autobahn/reports-{native,js}`, port 9161; local,
    informational).
  - Notes for WS9 (H2StreamPort + compression): compression and streaming live entirely in
    `WsCore` (decoder raw mode, `Inflater`/`Deflater` per core), so an h2 tunnel gets both
    unchanged through `WsPort`; `Handshake.responseHeaders` already carries
    `Sec-WebSocket-Extensions` on the `isH2` path. What the port must honour: (1) `wantsRead()` is
    False not only under the 1 MiB / 1 024-message watermarks but also while a streamed body
    holds the input (`held_`), while 1 MiB waits in a body, and while compressed input waits for
    room — an `H2StreamPort` must stop consuming *that stream's* flow-control window (not the
    connection's) until `portUpdateInterest`, and must not push more `portData` meanwhile (the core
    queues it in `pendingIn_`, unbounded by design only because the Conn stops reading); (2) a
    single `portData` may inflate up to 64 KiB × steps synchronously on the reactor — keep h2 DATA
    chunks moderate; (3) per-stream timers (heartbeat, pong, close handshake) as WS4 noted;
    (4) JS: the codec uses `pause`/`resume`/`writableLength`/`end`/`destroy`, all present on an
    `Http2Stream`; `ref`/`unref` are already in try/catch, `setNoDelay` is done on the raw socket
    in `open` (skip it for h2).
- 2026-10-08 — **WS10 done** (`worktrees/p12j`; without WS9, which runs in parallel: no
  WebSocket-over-h2 example or conformance run). Conformance scripts (local only, header comments
  say never CI; W18): new `test/conformance/common.sh` (shared: checksummed downloads, building an
  `examples/system` program natively — Stage-1 `compiler/bin/index.js --local-package
  eco/system=…` to MLIR, then `eco-boot-native` — and as JS with a launcher, port waits, the test
  certificate extracted from `TlsFixtures.elm`), `test/conformance/autobahn.sh` (installs PyPy
  2.7.23 + static OpenSSL 1.1.1w + cryptography 3.3.2 + autobahntestsuite 25.10.1 under
  `/tmp/eco-autobahn-tools` per Appendix F — the install path was run from scratch and works;
  `--mode server|client|both`, `--backend`, `--cases` (default `*`), `--exclude`, `--variants
  default,takeover,off`, `--no-split`, `--no-build`, `--install-only`, `WSTEST=`; prints a summary
  of every non-OK case and of crashed programs), `test/conformance/h2spec.sh` (h2spec 2.6.0 to
  `/tmp/eco-h2spec-tools`, `WsEchoServer --tls … --http2` on both backends, `-t -k`, score and
  failed cases, exit 1 when below `test/conformance/h2spec-baseline.txt`: native 136/146, JS
  133/146 from WS8). Examples (`examples/system/src/`, compiled by `eco-system-examples`, so by
  `full`): `WsEchoServer.elm` (Http.Server + `upgradeRequest`; args `[PORT] [--tls CERT KEY]
  [--http2] [--no-compression] [--context-takeover]`; 64 MiB messages, no heartbeat; plain
  requests get a text answer) — **promoted**: `test/conformance/{elm.json,WsEchoServer.elm}` (WS4,
  socket-level `WebSocket.upgradeRequest`) are removed; `WsChat.elm` (broadcast with
  `onMessage`/`onClose` per connection, joins/leaves announced, `GET /` serves a small browser
  client); `WsClient.elm` (`URL [--cacert FILE | --insecure] [--no-compression] [MESSAGE ...]`:
  sends the messages, prints what arrives, closes after as many messages as it sent, prints the
  CloseInfo); `WsAutobahnClient.elm` (the fuzzingserver driver: `/getCaseCount`, `/runCase`
  echoing until the end, `/updateReports`; 64 MiB, no heartbeat, `--no-compression`). Docs:
  `docs/getting-started.md` (Http.Server keep-alive/limits, https, HTTP/2 and WebSocket paragraphs
  with the example commands), `system-kernel-cpp/README.md` (`Http.Server` and `WebSocket` module
  lines; WebSockets over HTTP/2 marked in progress, made complete at the WS9 merge; the bundled third-party notice was already
  complete), `design_docs/invariants.csv` `SYS_005` (WebSocket codec rules) and `SYS_006`
  (`Http.Server`: one request in flight, strict parsing, limits), Appendix F updated.
  - Results: `full` green (`/tmp/eco-p12j-full.txt`: core 2169 checks / 0, JIT E2E 2314/2314, JS
    152 passed + the 2 Appendix E skips; the four new examples compile). Example AOT binaries
    (built with `common.sh`, `/tmp/eco-p12j-aot/`) run against each other
    (`/tmp/eco-p12j-aot-run.txt`): native `ws-client` → native `ws-echo-server` (`hello world`
    echoed with permessage-deflate, `closed: 1000 Normal (clean)`; `--no-compression` with
    non-ASCII text; JS `ws-client` → native server; `curl` gets the text answer), native client →
    `wss://localhost` native server `--tls … --http2` with `--cacert` (echo, clean close; `curl
    --http2` gets HTTP/2), native client → JS server (echo, clean close). `ws-chat` with two
    `ws-client`s (`/tmp/eco-p12j-aot-chat.txt`): joins, messages and the leave reach the other
    client (but see the onClose problem below).
  - **Autobahn|Testsuite 25.10.1**, every case (`*` = 517: 1–7, 9, 10, 12, 13), one process per case
    group (`/tmp/eco-p12j-autobahn-run2/` for the JS server and both clients,
    `/tmp/eco-autobahn-run/` for the native server; summaries `/tmp/eco-p12j-autobahn-full2.txt`,
    `/tmp/eco-p12j-autobahn-native3.txt`):
    - server (fuzzingclient → `WsEchoServer`), default compression (accepted, no context
      takeover): **native** 507 OK + 7 NON-STRICT + 3 INFORMATIONAL, **JS** 514 OK + 3
      INFORMATIONAL; every close behaviour OK. Context takeover (`--context-takeover`, 12.* and
      13.*, 216 cases): **native 216 OK, JS 216 OK**.
    - client (fuzzingserver → `WsAutobahnClient`, default offer): **native** 506 OK + 8
      NON-STRICT + 3 INFORMATIONAL, **JS** 507 OK + 7 NON-STRICT + 3 INFORMATIONAL; every close
      behaviour OK.
    - Non-OK cases: NON-STRICT 3.2, 3.3, 4.1.3, 4.1.4, 4.2.3, 4.2.4, 5.15 (native server; both
      clients; native client also 4.2.5) — a valid message is followed in the same TCP read by a
      bad frame (RSV bits, reserved opcode, a continuation with nothing to continue): the
      connection is failed (1002) before the application echoed the valid message; Autobahn
      accepts both orders (WS4's reason; the JS server reads per frame and echoes first).
      INFORMATIONAL 7.1.6 (a 256 KiB message, then Close, then a ping: whether the echo of the
      message gets out before the Close echo is timing-dependent), 7.13.1, 7.13.2 (Close with code
      5000 / 65535, which we answer with 1002; "undefined by the spec"): Autobahn grades these
      informational for every implementation. No FAILED case on any run
      that completed.
    - **Native crash (runtime, R7):** with all cases in one process (first run,
      `/tmp/eco-p12j-autobahn-run1/server-native-default.server.log`) and with 13.* in one process
      (`/tmp/eco-p12j-autobahn-run2/logs/server-native-default.13.server.log`) the native
      `WsEchoServer` aborted in case 13.6.17: `ThreadLocalHeap::allocLargeByteBuffer` assertion
      "Failed to allocate large byte buffer body in old gen" — the old generation reached its
      20 GB cap with no major GC (5.7 GB allocated in the nursery, 4.6 GB of large bodies freed at
      minor GCs). RSS of the native server reached 7.1 GB during 12.* and 7.9 GB during 13.*, the
      native client 8.0 GB; the JS server stayed below 170 MB. Hence the script's default of one
      process per subsection for 12.* and 13.* (no crash then). Same root cause as R7 (large
      `Bytes` not reclaimed; here every echoed message up to 16 MiB is a large body): the runtime
      follow-up is needed before a long-running native WebSocket server can carry heavy traffic.
  - **h2spec 2.6.0** (`test/conformance/h2spec.sh`, `/tmp/eco-p12j-h2spec3.txt`, outputs
    `/tmp/eco-h2spec-run/`): **native 137/146** (1 skipped, 8 failed: 5.1 #8 #9 #11 #12, 5.1.1 #2,
    5.3.1 #2, 6.3 #1, 6.9.1 #3 — WS8's list without 5.1 #5), **JS 133/146** (12 failed: the native
    ones plus 5.1 half-closed (remote) DATA and HEADERS, 6.1 DATA on a stream not open, 6.7 PING
    with ACK: Node's http2). Not worse than the WS8 baseline.
  - Decisions / deviations:
    - `WsEchoServer` uses `Http.Server` (A.2 path) instead of the WS4 socket-level path; the
      codec under test is the same. The conformance runs use the example directly; there is no
      separate conformance program any more.
    - The autobahn variants: cases 1–11 never offer compression, so "with and without
      compression" is the server's `default` (on, no takeover) vs `takeover` on 12.*/13.*; `off`
      (`--no-compression`) exists but only turns 12.*/13.* into UNIMPLEMENTED, so it is not in
      the default set. The client runs the default offer.
    - One process per case group by default (and per subsection for 12/13), because of the
      native crash above; a crashed program is detected (a zombie is not "alive") and reported,
      and the script then exits 1.
    - h2spec's JUnit file contains raw frame bytes (not well-formed XML): failures are read with a
      pattern; its text output needs `grep -a` (ugrep treats it as binary).
    - The h2spec baseline stays at WS8's 136 natively (137 was measured now; 5.1 #5 is
      timing-dependent).
  - **Plan problems / findings:**
    - **Native `onClose` can overtake `onMessage`** (WS4 manager, found by `WsChat`): `WsManager`
      delivers `Closed` from the WebSocket event drain while messages already received are still
      on their way to the subscription reader through the channel drain, so `onClose` may arrive
      before earlier messages (seen: `hi`, leave, `there`, `friends`); an application that drops
      its `onMessage` subscription when `onClose` arrives (as `WsChat` does) detaches the reader
      and those messages stay on the readable, never delivered (about 1 run in 3 with two native
      ends; probes in `/tmp/eco-p12j-scratch/`). JS delivers in order. Suggested fix: while a
      reader is attached, deliver the close after the reader saw the readable's end
      (`readerFn` gets `eof` / `err` after the queued chunks), or flush the readable's queued
      chunks to the reader before `deliverClose`; add an E2E test (many messages then Close, the
      subscriber unsubscribes on `onClose`). Not fixed here (WS4 code, outside WS10's scope);
      fixed at integration (below).
    - The R7 runtime problem is worse than §8 says for servers: a native WebSocket echo server
      fails after a few GB of large messages (above), not only grows.

- 2026-10-08 — **WS9 done** (`worktrees/p12i`). WebSockets over HTTP/2 (RFC 8441), server and
  opt-in client, on both backends. `WsCore`, `WsProtocol`, `WsDecoder` and `WsFrame` are
  **unchanged** (WS4's `WsPort` was enough), so the WS6/WS7 work merges around it. Native: new
  `WebSocket/H2StreamPort.{hpp,cpp}` (`H2Tunnel`: the stream seen from the port;
  `H2StreamPort`: the `WsPort` of an extended CONNECT stream; `H2PendingUpgrade`: the server's
  taken extended CONNECT, implemented by Http.Server), new `WebSocket/Http2Client.{hpp,cpp}`
  (`Http2ClientProtocol`: one nghttp2 client session per client WebSocket, W12),
  `WebSocket/WsHandshake.{hpp,cpp}` (`DialSpec`: `http2`, `h1Factory`, `target`/`authority`/
  `h2Headers`; `DialJob::onConnect` installs `Http2ClientProtocol` when ALPN chose `h2`,
  `h2HeadDone`, `redialHttp1`), `WebSocket/WebSocket.cpp` (`dial` reads the `http2` flag, builds
  the h2 fields from Elm's HTTP/1.1 header list, two TLS client contexts — ALPN `h2,http/1.1`
  and `http/1.1` for the redial; `open`/`reject`/`abandon` branches for h2 client and server
  handshakes), `WebSocket/WsTables.{hpp,cpp}` (`WsHandshakeEntry::h2`,
  `wsTablesAddServerH2Handshake`, heap reset abandons h2 handshakes),
  `HttpServer/HttpUpgrade.cpp` (`takeUpgrade` of an h2 key: `H2Upgrade` + `ServerTunnel`, result
  `( hsId, ( "CONNECT", path, "2" ), ( fields, True, remote ) )`), `HttpServer/Http2.{hpp,cpp}`
  (`H2StreamHandler::onWritable`, `tunnelCancel`, re-entrancy guard in `afterIo`, deferred
  handler destruction, writable notifications), `system-kernel-cpp/CMakeLists.txt` (the two new
  sources; **the nghttp2 objects now live in `libEcoSystem_WebSocket.a`**). JS: `WebSocket.js`
  (`_WebSocket_h2Duplex`, `_WebSocket_h2Fields`, `_WebSocket_parkH2Upgrade`; `dial` offers
  `h2` and runs `h2Exchange`; `open`/`reject` h2 branches), `HttpServer.js` (extended CONNECT
  entries keep method, path and fields; `takeUpgrade` h2 branch). Elm: docs only
  (`ConnectOptions.http2`, `Http.Server.upgradeRequest`); `docs.json` regenerated;
  `system-kernel-cpp/README.md`. Tests: new helper `test/eco-system/src/WebSocketH2Help.elm`
  (program + Node peer `ws.js`: masked frames by hand on extended CONNECT streams, and a Node h2
  server without `enableConnectProtocol`), `WebSocketHttp2ServerTest` (echo with protocol
  `chat`, unmasked server frames, Close then END_STREAM both ways → stream closed NO_ERROR;
  `/quiet`: no pongs → heartbeat Close 1001 + END_STREAM, the client never ends its side →
  RST_STREAM(CANCEL) after the 2 s drain, server `Abnormal`; client RST(CANCEL) → server
  `Abnormal`; `reject 403` as an ordinary response; `:protocol chat` → 501),
  `WebSocketHttp2ClientTest` (our client, `http2 = True`: to our h2 server → `Http2` upgrade,
  echo, clean close; a 4 MiB message plus 8 × 64 KiB texts at once, echoed (flow control and
  write backpressure on both sides); to a TLS server without `http2` → HTTP/1.1 on the same
  connection; `http2 = False` → HTTP/1.1; to a Node h2 server without extended CONNECT → GOAWAY
  NO_ERROR, redial over HTTP/1.1, frames masked), `WebSocketHttp2ManyTest` (from the Node side:
  50 WebSockets and 10 GETs at once on one session, default options (no cap): 50 echoed, 50 closed
  cleanly, 10 answered; the server counts 50 clean closes). None is SKIP-JS.
  - Results: native `eco-system/WebSocketHttp2` 3/3 (`/tmp/eco-p12i-native-ws9.txt`; first runs
    `/tmp/eco-p12i-native-ws9-{1,2}.txt`), `eco-system` 148/148
    (`/tmp/eco-p12i-native-ecosystem.txt`); JS `run-js-e2e` `eco-system/WebSocket,
    eco-system/HttpServer` 39/39 (`/tmp/eco-p12i-js.txt`; WS9 alone `/tmp/eco-p12i-js-ws9-1.txt`);
    AOT `aot-e2e-runner --filter eco-system/WebSocketHttp2` 3/3 (`/tmp/eco-p12i-aot.txt`: the
    moved nghttp2 objects link for both Http2.cpp and Http2Client.cpp); core test 1825 checks / 0
    (`/tmp/eco-p12i-core.txt`); `check-root-bounded` and `check-kernel-homes` ok
    (`/tmp/eco-p12i-rootbound.txt`, `/tmp/eco-p12i-homes.txt`); `full` green (core 1825 checks / 0, JIT E2E 2308/2308, JS 146 passed + the 2 Appendix E skips)
    (`/tmp/eco-p12i-full.txt`). No validate tree or stress run (no GC-facing change: the new heap
    code is `takeUpgrade`'s result, moved into one function under the same single
    `StackRootGuard`; `dial`'s copy-out gained only C++ string work inside the G3 scope). No
    pinned kernel file changed (license manifest untouched). h2spec not re-run (the non-tunnel
    path changed only by the `afterIo` guard).
  - Decisions / deviations:
    - **nghttp2 moved archives** (plan §3.8 put it in `libEcoSystem_HttpServer.a`): the client
      session is in `EcoSystem_WebSocket`, which `EcoSystem_HttpServer` links (CMake order) and
      the AOT driver links in one group; one copy only (two would risk duplicate members).
    - **The WebSocket library does not link Http.Server**, so the server side goes through an
      interface: `H2PendingUpgrade` (`describe`, `accept`, `reject`, `abandon`) held by the
      handshake entry, implemented in `HttpUpgrade.cpp`, whose `ServerTunnel` is both
      Http2Protocol's `H2StreamHandler` and the port's `H2Tunnel`. The client's
      `Http2ClientProtocol` is its own `H2Tunnel`.
    - **Per-stream deadlines** (WS4 note): `H2StreamPort` keeps the codec's timer ids itself on a
      timer-only reactor handler (the Conn's timers are per connection; one h2 connection carries
      many tunnels).
    - `portWrite` completes when the bytes are queued on the stream; the codec writes only while
      `tunnelQueued()` < 64 KiB, and `streamWritable` (new `H2StreamHandler::onWritable`, called
      by Http2Protocol / Http2ClientProtocol after framing when a queue that reached 64 KiB
      drained) resumes it. Received bytes are consumed into the stream window only when the codec
      takes them (64 KiB windows: a paused codec back-pressures the peer).
    - **Orderly close and abort**: `portCloseGraceful` = END_STREAM after the queued bytes, then
      RST_STREAM(CANCEL) if the peer has not ended its side within the drain time (2 s, as a TCP
      drain ends in a close); `portAbort` = RST_STREAM(CANCEL) and the core is told at once.
      (No public API aborts a WebSocket; the test reaches the RST through the drain after a
      heartbeat failure.)
    - Re-entrancy (Http2.cpp): tunnel calls made while nghttp2 runs (inside a callback, e.g. the
      codec answering a ping while DATA is received, or during a flush) only queue: `afterIo`
      returns early (sets `flushAgain_` while flushing) and the running step frames them. A tunnel
      handler is destroyed on a later reactor turn after its stream closed (`retireTunnel`), so a
      stream that ends inside a call its handler made never leaves it dangling.
    - `abandon` of a taken h2 upgrade: new `Http2Protocol::tunnelCancel(key)` (RST_STREAM(CANCEL),
      key forgotten). `reject`: `Http2Protocol::respond` (a complete response, then
      RST_STREAM(NO_ERROR) because the request side is still open, WS8 rule).
    - Client request fields: built by the kernel from the HTTP/1.1 header list Elm already builds
      (D.2): `Host` → `:authority`; `Upgrade`, `Connection`, `Sec-WebSocket-Key` and other
      connection-specific fields dropped; names lower-cased; `:scheme https` (h2 is wss-only: Elm
      passes `http2 && secure`). Elm's response check already accepted any 2xx for `isH2`.
      1xx responses are skipped. A stream reset or session end before the answer →
      `ERR_WS_HANDSHAKE`; everything before the answer is under the dial's one deadline.
    - The fallback redial (ENABLE_CONNECT_PROTOCOL 0) uses the same address with a second TLS
      context offering only `http/1.1` (built with the first on the pool), after GOAWAY(NO_ERROR)
      and a graceful close of the h2 connection; when the client's stream ends, its session ends
      too (GOAWAY, close: one connection per WebSocket, W12).
    - Before `open` the client keeps the stream's DATA unconsumed (its 64 KiB window bounds it),
      as a HoldProtocol keeps the bytes after a 101.
    - JS: `_WebSocket_h2Duplex` gives an `Http2Stream` the socket face the codec uses (no codec
      change): `end` = END_STREAM, `destroy` = `close(NGHTTP2_CANCEL)`; `ref`/`unref` go to the
      client's own session, and do nothing for a server stream (the Http.Server session keeps the
      process alive while it is open; it is closed by `closeServer`). The client uses
      `http2.connect` with `createConnection` returning our TLS socket and waits for
      `'remoteSettings'`; a stream's close closes its client session (GOAWAY).
    - `WebSocketHttp2ManyTest` drives the 50 WebSockets from the Node side (one session, plus the
      GETs), not with our client: our client opens one connection per WebSocket by design (W12).
  - Plan problems: (1) §3.8/WS8 placed nghttp2 in the HttpServer archive, which the h2 client in
    the WebSocket library cannot use (above). (2) §4 WS9 lists `WebSocket/WsProtocol.cpp (port
    abstraction)`: WS4 had already done it; nothing changed there. (3) There is no public way to
    abort a WebSocket (the "RST_STREAM CANCEL on abort" case of §4 WS9 is reached through the
    drain after a failed close, and through the peer's reset).


---

- 2026-10-08 — **Integration** (all phases merged into the main tree).
  - `WebSocketHttp2StreamedTest` (new): `connectStreamed` with `http2 = True` and compression
    against an `Http.Server` with HTTP/2; a 4 MiB binary message from `sendBinary` and a streamed
    text message, both echoed and read as streamed bodies (WS6 + WS7 + WS9 on one tunnel). Both
    backends pass.
  - Native `onClose` ordering (WS10 finding) fixed in `WsManager.cpp`: while the subscription
    reader is attached and has not seen the readable's end, `wsManagerOnClosed` (and a held close)
    waits; `readerFn` delivers the close when the end reaches it, after every queued message, and
    the keep-alive count stays until then. New `WebSocketCloseOrderTest`: a raw server writes 200
    text frames and a Close in one write; the client (`onMessage` + `onClose`, dropping both on
    the close) must see all 200 in order first. Against the old manager it saw 1 of 200; with the
    fix 200 of 200, natively (all 29 WebSocket tests green) and on JS.
  - R7 root cause (the native Autobahn crash): a large `Bytes` body goes straight to the old
    generation while its nursery header is 16 bytes, so gigabytes of large bodies can be allocated
    between two minor GCs, and the major-GC triggers are only evaluated at minors and safepoints;
    the old generation reached its cap before any trigger was evaluated. Follow-up (runtime): count
    large-body bytes towards a minor-GC request (the minor already frees dead young large bodies).
  - Runtime fix (found by the validate tree, `WebSocketHttp2ManyTest` under gc-pressure: TV7 stale
    nursery pointer in `PlatformRuntime::gatherEffects`): `dispatchEffects` decoded the sub bag
    into a local before gathering the cmd bag, whose `cmdMap` calls (PORT_005) may GC, so the
    second gather read a stale bag. Each bag is now decoded from `activeBatch_` (a scanned root)
    right before its gather. Reproduced on the first run before the fix; 3/3 green after.
  - Stress: `EcoSystemHttpServerSequential` printed `False` once in the first gate run (some
    request answered wrongly or not at all); not reproduced in 12 reruns (7 alone, 5 with the
    whole EcoSystem set, with per-request diagnostics). A suspect is the harness's free-port
    window (`test/TestPort.hpp`: the port is closed before the child binds it).
  - `HttpServerHttp2LimitsTest` failed once under AOT: curl 7.88 exit 92 with empty stdout (the
    RST_STREAM(NO_ERROR) after an early 413 arrived in the same read as the response, and curl
    dropped both). `HttpServerH2Help.curl` now repeats the request (up to 3 tries) in exactly that
    case; the 92-with-output tolerance stays. 3/3 AOT, JIT and JS green after.
  - Final gates on the merged tree after the runtime fix (`/tmp/eco-final-*.txt`): `full` green
    (core 2169 checks / 0, JIT E2E 2319/2319, JS 157 passed + 2 skips); validate tree eco-system
    159/159; stress under validate 12/12; AOT `eco-` 172/173 (the curl race above, fixed and
    re-run); `check-root-bounded`, `check-kernel-homes`, license manifest OK.
  - Follow-up for R7: `plans/large-body-gc-trigger.md`.

## Appendix A — Public API (normative)

### A.1 `WebSocket`

```elm
effect module WebSocket where { subscription = MySub } exposing
    ( WebSocket, Whole, Streamed, Message(..), StreamedMessage(..)
    , readable, streamedReadable, writable, sendText, sendBinary
    , protocol, compression, Negotiated, localEndpoint, remoteEndpoint
    , onMessage, onClose, ping, close, closed
    , CloseCode(..), CloseInfo, Heartbeat
    , ConnectOptions, ClientCompression, defaultConnectOptions, connect, connectStreamed
    , Upgrade, upgradeRequest, upgradeTarget, upgradeHeaders, upgradeProtocols, upgradeOrigin
    , upgradeRemote, AcceptOptions, ServerCompression, defaultAcceptOptions
    , accept, acceptStreamed, reject
    , errorIsHandshakeFailed, handshakeStatus
    )

type alias WebSocket mode = Internal.WebSocket mode
type Whole = Whole Never                       -- mode markers (uninhabited)
type Streamed = Streamed Never
type Message = Text String | Binary Bytes
type StreamedMessage = StreamedText (Stream.Readable String) | StreamedBinary (Stream.Readable Bytes)

readable : WebSocket Whole -> Stream.Readable Message           -- Closed after a clean close
streamedReadable : WebSocket Streamed -> Stream.Readable StreamedMessage
writable : WebSocket mode -> Stream.Writable Message            -- closeWritable = close Normal ""
sendText : Stream.Readable String -> WebSocket mode -> Task Socket.Error ()     -- one fragmented message
sendBinary : Stream.Readable Bytes -> WebSocket mode -> Task Socket.Error ()
protocol : WebSocket mode -> Maybe String
compression : WebSocket mode -> Maybe Negotiated
type alias Negotiated = { serverNoContextTakeover : Bool, clientNoContextTakeover : Bool
                        , serverMaxWindowBits : Int, clientMaxWindowBits : Int }
localEndpoint : WebSocket mode -> Socket.Address.Endpoint
remoteEndpoint : WebSocket mode -> Socket.Address.Endpoint

onMessage : WebSocket Whole -> (Message -> msg) -> Sub msg
onClose : WebSocket mode -> (CloseInfo -> msg) -> Sub msg
ping : WebSocket mode -> Task Socket.Error Int                 -- round trip ms
close : CloseCode -> String -> WebSocket mode -> Task Socket.Error ()   -- EINVAL: unsendable code
closed : WebSocket mode -> Task x CloseInfo

type CloseCode
    = Normal | GoingAway | ProtocolError | UnsupportedData | NoStatus | Abnormal | InvalidData
    | PolicyViolation | MessageTooBig | MandatoryExtension | InternalError | Other Int
type alias CloseInfo = { code : CloseCode, reason : String, clean : Bool }
type alias Heartbeat = { interval : Int, timeout : Int }       -- ms

type alias ClientCompression =                                 -- what the client offers
    { clientMaxWindowBits : Maybe (Maybe Int)                   -- Just Nothing = offer without value
    , serverMaxWindowBits : Maybe Int
    , contextTakeover : Bool        -- False (default): offer client_ and server_no_context_takeover
    , threshold : Int }
type alias ConnectOptions =
    { url : String, headers : List ( String, String ), protocols : List String
    , verification : Socket.Tls.Verification, timeout : Maybe Int
    , maxMessageSize : Int, heartbeat : Maybe Heartbeat
    , compression : Maybe ClientCompression, http2 : Bool }
defaultConnectOptions : String -> ConnectOptions
    -- headers [], protocols [], SystemCertificates, timeout Just 30000, 16 MiB, Just {30000,30000},
    -- Just { clientMaxWindowBits = Just Nothing, serverMaxWindowBits = Nothing, contextTakeover = False,
    --        threshold = 64 }, False
connect : ConnectOptions -> Task Socket.Error (WebSocket Whole)
connectStreamed : ConnectOptions -> Task Socket.Error (WebSocket Streamed)

type alias Upgrade = Internal.Upgrade
upgradeRequest : Socket.Connection -> Task Socket.Error Upgrade
upgradeTarget : Upgrade -> String                              -- path and query
upgradeHeaders : Upgrade -> List ( String, String )            -- lower-case names, duplicates kept
upgradeProtocols : Upgrade -> List String
upgradeOrigin : Upgrade -> Maybe String
upgradeRemote : Upgrade -> Socket.Address.Endpoint

type alias ServerCompression = { maxWindowBits : Int, contextTakeover : Bool, threshold : Int }
type alias AcceptOptions =                                     -- (WS4: no handshakeTimeout, §10)
    { protocol : Maybe String, headers : List ( String, String ), maxMessageSize : Int
    , heartbeat : Maybe Heartbeat, compression : Maybe ServerCompression }
defaultAcceptOptions : AcceptOptions
    -- Nothing, [], 16 MiB, Just {30000,30000}, Just { maxWindowBits = 15, contextTakeover = False,
    --  threshold = 64 }
accept : AcceptOptions -> Upgrade -> Task Socket.Error (WebSocket Whole)
acceptStreamed : AcceptOptions -> Upgrade -> Task Socket.Error (WebSocket Streamed)
reject : Int -> List ( String, String ) -> String -> Upgrade -> Task x ()   -- status, headers, body

errorIsHandshakeFailed : Socket.Error -> Bool
handshakeStatus : Socket.Error -> Maybe Int
```

Doc comments state: import qualified (names shared with `Socket`); one connection per handshake (no
CONNECTING-state queueing per host — a deliberate deviation from RFC 6455 §4.1); no redirects or
proxies; compression memory and CRIME/BREACH note; a dropped streamed body stalls the connection;
heartbeat runs on both ends by default.

### A.2 `Http.Server` additions

```elm
type HttpVersion = Http1_0 | Http1_1 | Http2
type alias Request =
    { headers : Dict String String, method : Method, body : Bytes, url : Url
    , version : HttpVersion, upgrade : Maybe String }           -- W15

type alias ServerOptions =
    { address : Socket.Address.Address, port_ : Int
    , tls : Maybe Socket.Tls.ServerOptions                       -- its alpn field is ignored
    , http2 : Bool                                               -- requires tls
    , maxConnections : Maybe Int                                  -- default Nothing (W19)
    , maxConcurrentStreams : Maybe Int                            -- default Nothing (W19)
    , maxBodySize : Int, maxHeaderSize : Int
    , keepAliveTimeout : Int, headersTimeout : Int, requestTimeout : Int }
defaultServerOptions : Socket.Address.Address -> Int -> ServerOptions     -- §7 values
createServerWith : ServerOptions -> Task ServerError Server
serverPort : Server -> Int
closeServer : Server -> Task x ()                                -- graceful, 5 s deadline
closeServerWithin : Int -> Server -> Task x ()
upgradeRequest : Request -> Response -> Task Socket.Error WebSocket.Upgrade
```

## Appendix B — Kernel catalogue (normative)

Conventions and modes as the sockets plan Appendix B (S, P, R reactor round trip, A parked, M
manager). Shapes: `FErr = ( String, String )`; `EpT = ( Int, String, Int )`.

### B.1 `Eco.Kernel.WebSocket`

| Kernel fn | Elm type | Mode | Notes |
|---|---|---|---|
| `handshakeKey` | `Task Never ( String, String )` | S | `(key, expectedAccept)`: 16 random bytes base64, SHA-1 accept |
| `acceptFor` | `String -> String` | pure | SHA-1 + base64 of key ++ GUID (B5 exception like `utf8ToString`) |
| `dial` | `( List String, Int, Int ) -> ( ( Bool, String ), ( Int, String ), ( Bool, Bool ) ) -> ( String, List ( String, String ) ) -> Task FErr ( Int, ( Int, Bool ), List ( String, List String ) )` | P/R | `(addresses, port, timeoutMs)`, `((tls, serverName), (verification, pem), (http2, _))`, `(requestHead target, headers)` → `(hsId, (status, isH2), responseHeaders)` (WS4: `isH2` added; one element per header line); wss builds its context on the pool first; kill aborts |
| `readUpgrade` | `Int -> Int -> Task FErr ( Int, ( String, String, String ), ( List ( String, List String ), Bool, EpT ) )` | R | `(connId, timeoutMs)` → `(upId, (method, target, version), (headers, isH2, remote))`; takes the `Conn` (§3.2); `remote` added in WS0 (§10) |
| `open` | `Int -> ( Int, List ( String, String ) ) -> ( ( Int, Int, Int ), ( Int, Int, Int ), ( Int, ( Bool, Int ), ( Bool, Int ) ) ) -> (( Int, String, Bytes ) -> a) -> (b -> ( Int, String, Bytes )) -> Task FErr ( Int, ( Int, Int ), ( EpT, EpT ) )` | R | `(hsOrUpId, (status 101/200 or 0 for client, responseHeaders), ((role, mode, maxMsg), (hbInterval, hbTimeout, closeTimeout), (threshold, (ourNoCtx, ourBits), (peerNoCtx, peerBits))), fromWire, toWire)` → `(wsId, (readableId, writableId), (local, remote))`; WS7: the deflate `Bool` became `threshold` (`-1`: no permessage-deflate), which the kernel needs too (§10) |
| `reject` | `Int -> ( Int, List ( String, String ), String ) -> Task Never ()` | R | writes status + headers + body, closes |
| `abandon` | `Int -> Task Never ()` | S | WS4: releases a handshake id nobody answers (the client's response failed Elm's checks); closes its connection |
| `close` | `Int -> Int -> String -> Task Never ()` | R | `(wsId, code, reason)` (validated in Elm); completes once our Close is written |
| `closed` | `Int -> Task Never ( Int, String, Bool )` | A | completes at once if already closed |
| `ping` | `Int -> Task FErr Int` | R | RTT ms; ECANCELED on close, ETIMEDOUT after heartbeat timeout |
| `openOutgoing` | `Int -> Int -> Task FErr Int` | S | `(wsId, kind 1 text / 2 binary)` → sink pair id (a text or binary channel sink; the stream's place in the data FIFO is taken by a reactor command submitted before the id is returned, so no round trip is needed: WS6 made it S, §10) |
| `"WebSocket"` manager | — | M | C.2 |
| JS-only | `attachMessageListener`, `attachCloseListener`, `holdClose` | — | manager bodies |

Mapped-source tags: 1 text (String slot = text), 2 binary (Bytes slot), 3 streamed text body (String
slot = decimal body pair id), 4 streamed binary body. Mapped-sink tags: 1 text, 2 binary.
Masks: `( Int, String, Bytes )` 0x1; `( Int, ( Int, Int ), ( EpT, EpT ) )` 0x1, inner `0x5`;
`dial`'s `( Int, ( Int, Bool ), List … )` 0x1, inner 0x1.

### B.2 `Eco.Kernel.HttpServer` (changes)

| Kernel fn | Elm type | Mode | Notes |
|---|---|---|---|
| `createServer` | `String -> Int -> Task ( String, String ) ( Int, Int )` | P | now reactor-backed; returns `( serverId, boundPort )` (WS2, §10) |
| `createServerWith` | `( ( String, Int ), ( Bool, Int ) ) -> Maybe ( String, String ) -> ( ( Int, Int, Int ), ( Int, Int, Int ) ) -> Task ( String, String ) ( Int, Int )` | P | `((address, port), (http2, maxConnections; -1 unlimited))`, `tls (certificateChain, privateKey)`, `((keepAlive, headersT, requestT), (maxBody, maxHeader, maxStreams; -1 unlimited))` → `(serverId, boundPort)` |
| `respond` | unchanged | R | completes when the bytes are queued; dead key → at once |
| `closeServer` | `Int -> Int -> Task Never ()` | R | `(serverId, deadlineMs)` |
| `takeUpgrade` | `Int -> Task ( String, String ) ( Int, ( String, String, String ), ( List ( String, List String ), Bool, EpT ) )` | S | `key` → same shape as `WebSocket.readUpgrade` (with the client's endpoint, WS0 §10); consumes the key (a later `respond` does nothing); the id is a handshake id of the WebSocket tables (`open`/`reject`/`abandon`); `EINVAL` for an unknown, answered or non-upgrade key, `ECANCELED` when the connection is gone (WS5, §10) |

## Appendix C — Effect-manager layouts (normative)

### C.1 `Http.Server` (changed)

```elm
type MySub msg
    = OnRequest Int (( ( String, String ), ( List ( String, List String ), Bytes ), ( Int, Int, String ) ) -> msg)
    -- tag 0: [serverId unboxed Int, tagger boxed]; argument ((method, url), (headers, body),
    -- (key, flags, upgradeToken)); flags bits 0–1 version (0 = 1.0, 1 = 1.1, 2 = 2), bit 2 TLS;
    -- inner triple mask 0x5
```

### C.2 `WebSocket`

```elm
type MySub msg
    = OnMessage Int (( Int, String, Bytes ) -> msg)    -- tag 0: [wsId unboxed, tagger]; mask 0x1 inner
    | OnClose Int (( Int, String, Bool ) -> msg)       -- tag 1: [wsId unboxed, tagger]
```

## Appendix D — Protocol behaviour (normative for both codecs)

**D.1 Frames.** FIN, RSV1–3, opcode, MASK, length (7, 16 or 64 bits; non-minimal lengths accepted;
64-bit with MSB set → 1002). Opcodes 0, 1, 2, 8, 9, 10; others → 1002. RSV2/RSV3 always → 1002;
RSV1 only on the first frame of a data message with deflate negotiated, else 1002. Client frames
MUST be masked, server frames MUST NOT (violation → 1002). Control frames: payload ≤ 125, FIN set,
never compressed; may arrive between fragments. A continuation without a message in progress, or a
new data frame inside one → 1002.

**D.2 Client handshake.** Request: `GET <target> HTTP/1.1`, `Host`, `Upgrade: websocket`,
`Connection: Upgrade`, `Sec-WebSocket-Key`, `Sec-WebSocket-Version: 13`, optional `Origin`,
`Sec-WebSocket-Protocol`, `Sec-WebSocket-Extensions`, user headers (CR/LF or reserved names →
`EINVAL`). Response: status 101 (else `ERR_WS_HANDSHAKE` with the status; no redirects), `Upgrade`
contains `websocket` and `Connection` contains `upgrade` (case-insensitive token lists),
`Sec-WebSocket-Accept` equals the expected value, a returned protocol was offered, every returned
extension and parameter was offered (D.7). h2 (RFC 8441): extended CONNECT, any 2xx, no key/accept,
no `Connection`/`Upgrade`.

**D.3 Server handshake.** `GET`, HTTP ≥ 1.1, `Host` present, `Upgrade` contains `websocket`,
`Connection` contains `upgrade`, `Sec-WebSocket-Key` base64 of 16 bytes (else 400); version ≠ 13 →
426 with `Sec-WebSocket-Version: 13`. The chosen protocol must be one offered (else `accept` fails
`EINVAL`). h2: `:method CONNECT`, `:protocol websocket`, `:scheme`, `:path`, `:authority`,
`sec-websocket-version: 13`; answer 200.

**D.4 Messages.** Whole: reassemble ≤ `maxMessageSize` (checked from each frame header before
buffering; exceed → 1009). Text: UTF-8 validated incrementally, fail fast (1007), including inside
fragments. Streamed: body chunks emitted as they arrive (text split at code points).

**D.5 Close.** Payload empty or ≥ 2 bytes (1 byte → 1002); code valid on receipt: 1000–1003,
1007–1014, 3000–4999 (else 1002); reason UTF-8 (else 1007). The first Close received sets
`CloseInfo`; it is echoed once (with its code; empty payload echoed empty). After sending Close, data
frames are discarded; outgoing data after our Close fails `Cancelled "socket closed"`. Close timeout
30 s, then abort. The server closes TCP after the handshake; the client waits for FIN (bounded by the
close timeout). Failing the connection (1002/1007/1009/1011): send Close, stop processing input,
reads fail `Cancelled`. `cancelReadable`: discard further data messages, keep handling control
frames. `cancelWritable`: fail the connection with 1011.

**D.6 Ping/pong and heartbeat.** Every ping is answered with a pong carrying its payload, ahead of
queued data; several pings may be answered by a pong to the latest only. Unsolicited pongs ignored.
Heartbeat per W5.

**D.7 permessage-deflate negotiation (RFC 7692 §7.1).** Client offer from `ClientCompression`
(`client_max_window_bits` with no value when `Just Nothing`). Server: consider offers in order, answer
at most one `permessage-deflate`; never include `client_max_window_bits` unless offered; may include
`server_max_window_bits` ≤ any offered value; must echo `server_no_context_takeover` if offered or
decline the offer; values 8–15, no leading zeros, possibly quoted; duplicate or unknown parameters →
decline that offer (server) or fail the connection (client). Window bits 8 → deflate with 9; inflate
always 15. Engine rules: §3.7.

**D.8 Masking.** Fresh unpredictable 32-bit keys from `RAND_bytes` / `crypto.randomFillSync` pools.

**D.9 Error codes and reasons.** Handshake: `ERR_WS_HANDSHAKE` (`handshakeStatus` = status when one
was received). Codec failures as stream reasons: `"ERR_WS_PROTOCOL: <text>"` (1002),
`"ERR_WS_INVALID_DATA: <text>"` (1007), `"ERR_WS_MESSAGE_TOO_BIG"` (1009), `"socket closed"`,
`"read <CODE>"`/`"write <CODE>"` for transport errors (sockets plan D.2).

**D.10 HTTP rules.** §3.4 (HTTP/1.1) and §3.8 (HTTP/2) are normative for both backends.

## Appendix E — JS notes

**E.1 General.** Plain property names across kernel files; every kernel starting IO calls
`_Stream_noteActivity()`; kernel headers import every double-underscore name; timers `unref`'d,
sockets ref'd per the keep-alive counts (§3.4, §3.6).

**E.2 `HttpServer.js`.** `http.createServer` (plain) or `http2.createSecureServer({ allowHTTP1: true,
settings: { enableConnectProtocol: true, maxConcurrentStreams (only when set) } })` (TLS; without `http2` use
`https.createServer` with `ALPNProtocols: ['http/1.1']`; Node answers no ALPN overlap with a fatal
alert, so the NoAck fallback of §3.5 needs a ClientHello peek and a per-connection
`ALPNProtocols` — §10 WS3). Per-socket queue: deliver one request per
connection at a time. Timeouts: `keepAliveTimeout`, `headersTimeout`, `requestTimeout` set to the
options. `'upgrade'` listener: synthesise the `Request` (version, upgrade token) and keep the socket +
head for `takeUpgrade`; declined upgrades written as raw HTTP/1.1 with `Connection: close`.
`'connect'` listener (h1 and h2): h1 CONNECT answered by the user then closed; h2 extended CONNECT
delivered as an upgrade request; unknown `:protocol` → 501. h2 requests: drop pseudo-headers from the
list, join cookies, never set a `Connection` header (Node warns). `closeServer`: `server.close()`,
`closeIdleConnections()`, track h2 sessions and `session.close()`, `closeAllConnections()` at the
deadline.

**E.3 `WebSocket.js`.** Codec class over a Duplex; `dial` builds on `Socket.js`/`Tls.js` internals
(connect each address; TLS options as `Tls.js`; ALPN); h2 client via `http2.connect` with a
`createConnection` returning our TLS socket, awaiting `'remoteSettings'` and checking
`enableConnectProtocol`; `_Socket_detach(connId)` hands a `Socket.Connection`'s Node socket (and any
buffered data) to the codec.

**E.4 Expected SKIP-JS.** Only tests that measure native-only behaviour (e.g. kernel-buffer
backpressure); each with a reason.

## Appendix F — Conformance recipes (local only)

**Autobahn|Testsuite 25.10.1** (`test/conformance/autobahn.sh`, installs under
`/tmp/eco-autobahn-tools`, works in `/tmp/eco-autobahn-run`; WS10):
1. Download `https://downloads.python.org/pypy/pypy2.7-v7.3.23-linux64.tar.gz`, extract.
2. Build OpenSSL 1.1.1w statically under `/tmp` (`./config no-shared -fPIC && make`): the system
   OpenSSL 3 fails `cryptography` 3.3.2 with `FIPS_mode`.
3. `pypy -m ensurepip`; `pip install 'pip<21' typing incremental==16.10.1 pycparser`;
   `CFLAGS=-I…/include LDFLAGS=-L…/lib pip install --no-binary cryptography cryptography==3.3.2`;
   `pip install autobahntestsuite==25.10.1` (cryptography first, so the suite's install does not
   build it against OpenSSL 3).
4. Server under test (`examples/system/src/WsEchoServer.elm`, native and JS): `wstest -m
   fuzzingclient -s fuzzingclient.json` (`{"outdir": …, "servers": [{"agent": "eco-…", "url":
   "ws://127.0.0.1:9001"}], "cases": […], "exclude-cases": []}`). Client under test
   (`examples/system/src/WsAutobahnClient.elm`): `wstest -m fuzzingserver -s fuzzingserver.json`;
   the client fetches `/getCaseCount`, runs `/runCase?case=N&agent=eco`, then
   `/updateReports?agent=eco`. The script runs every top-level case group with a fresh process
   (`--no-split` for one), so a crash stays in its group and is reported.
5. Reports: `index.json` (`{agent: {case: {behavior, behaviorClose, remoteCloseCode, …}}}`); the script
   prints a summary of non-OK cases.

**h2spec 2.6.0** (`test/conformance/h2spec.sh`): download
`https://github.com/summerwind/h2spec/releases/download/v2.6.0/h2spec_linux_amd64.tar.gz` to
`/tmp/eco-h2spec-tools`; run `h2spec -h 127.0.0.1 -p PORT -t -k -j …` against `WsEchoServer
--tls cert key --http2` (the test certificate from `TlsFixtures.elm`), on both backends; compare
with `test/conformance/h2spec-baseline.txt` (the WS8 baseline; the script fails when a backend
scores lower). The JUnit file can hold raw frame bytes, so failures are read with a pattern.
