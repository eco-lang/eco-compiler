# Plan: sockets for `eco/system` — TCP, UDP, Unix and TLS

Status: **implemented** (S0–S7, 2026-10-08; §10 has results and deviations). Plan v3 (2026-10-07). History: v1 sketch → v2 (SD10–SD12: `connectToHost`,
the IO reactor, `close`/`reset`) → two adversarial reviews (native; Elm/JS/tests; §9) → v3.
§10 is the progress log.

This plan extends the `eco/system` package (`system-kernel-cpp/`, `plans/eco-system-library.md`,
"the base plan") with socket programming: TCP and Unix stream sockets, UDP datagram sockets, IPv4
and IPv6 addresses, name lookup, and TLS. The base plan's §3.2 (boundary rules B1–B8), §3.3 (GC
rules G1–G15, templates T1–T9, gates), §3.4 (services, keep-alive rule), §3.6 (C++ effect managers)
and D15 (JS target) apply unchanged and are not repeated. **Read base plan §3.3 before writing any
C++ here.**

How to read this plan:
- §0–§2: decisions, scope, verified facts.
- §3: architecture (§3.3, the IO reactor, is the core of the native side).
- §4: phases, each with files, steps, tests and exit criteria.
- Appendices: A public API (normative), B kernel catalogue (normative), C effect-manager layouts
  (normative), D behaviour notes (normative), E JS notes (normative for S6).

---

## 0. Decisions

| # | Decision |
|---|---|
| SD1 | **Namespace `Socket.*`**: `Socket`, `Socket.Address`, `Socket.Tcp`, `Socket.Unix`, `Socket.Udp`, `Socket.Tls` (plus the unexposed `Socket.Internal`). |
| SD2 | **Both subscriptions and tasks** for incoming work: `Socket.onConnection` / `Socket.accept`, `Socket.Udp.onMessage` / `Socket.Udp.receive`. Delivery rule: §3.4. |
| SD3 | **Hosts are `Address` values** in `connect`, `listen`, `bind`. Names are resolved explicitly (`Socket.lookup`) or by `connectToHost` (SD10). TLS also takes the server name as a `String`. |
| SD4 | **Not in v1:** Unix datagram sockets, Linux abstract names, fd passing, `socketpair`. **In v1:** `Socket.Unix.peerCredentials`. |
| SD5 | **TLS is a separate module** (`Socket.Tls`, kernel home `Tls`, library `EcoSystem_Tls`) on OpenSSL 3 natively and Node `tls` on JS. |
| SD6 | **TCP, Unix and TLS share `Socket.Connection` and `Socket.Listener`.** Only creation is kind-specific. |
| SD7 | **A stream connection is a `Stream` pair.** `Stream.closeWritable` is a half-close (TLS: `close_notify`, then FIN). |
| SD8 | **Datagrams are values, not streams.** |
| SD9 | Style as the base package: opaque handles with accessors; option records with `default…`; one opaque `Socket.Error` with `errorCode`/`errorToString`/`errorIs…`; the handle last; `()`; `Path` for paths. |
| SD10 | **`Socket.Tcp.connectToHost`**: plain Elm over `lookup` + `connect`, trying each address in turn (§D.2). |
| SD11 | **All socket IO is non-blocking on one shared event loop**, the `IoReactor` (§3.3): one epoll (Linux) / kqueue (macOS) thread feeding the eco scheduler through async-source drains. No thread per socket. The `Scheduler` is not changed. |
| SD12 | **Ending a connection:** graceful `Stream.closeWritable` + read to `Closed`; `Socket.close` (stop now; queued writes dropped; kernel-buffered data still sent; FIN); `Socket.reset` (`SO_LINGER {1,0}`, RST). No linger option. |
| SD13 | **Elm's `Socket.Address.toString` is the only address printer.** Kernels (C and JS) may return any valid RFC 4291 text plus `%scope`; Elm parses and prints canonically (§D.1), so native and JS agree by construction. |
| SD14 | **Undelivered work is held, never dropped silently:** an accepted connection or received datagram with no consumer goes to a per-listener / per-socket FIFO on the main thread and is served first to the next consumer (§3.4). This replaces v2's "nothing is accepted without demand", which the review showed is racy. |

## 1. Scope

**In scope:** Appendix A on **Linux and macOS** natively (macOS written, untested, like the rest of
eco/system) and on the **JS target** (Node ≥ 22), the same tests passing on both except the
`SKIP-JS` tests listed in Appendix E; build, bundle, test and documentation integration.

**Out of scope (follow-ups, §8):** SD4's Unix extras; Windows (libraries compile; fallible tasks fail
`"ENOTSUP"`; subscriptions crash with `eco/system: <function> is not supported on Windows yet`);
moving child pipes, stdio and `Http.Server` onto the reactor; the reactor inside the Scheduler's idle
wait; STARTTLS (`Socket.Tls.upgrade`); happy eyeballs; client certificates; options beyond Appendix A.

## 2. Verified facts

Checked on 2026-10-07 in this tree and container (Node v22.23.3, Python 3.11.2, OpenSSL 3.0.20).

| # | Fact | Where |
|---|---|---|
| SF1 | `FdChannel` owns its fd; only its thread closes it. A socket needs a duplex channel. | `Core/FdChannel.hpp:8-12`, `FdChannel.cpp:326-329` |
| SF2 | `ByteChannel` contract: one `ChannelResult` per request, ECANCELED after `shutdown()`, the requester owns `pendingAsync`. The stream table owns each channel (`StreamPair::channel` is a `unique_ptr`, destroyed when the pair is erased) and tolerates results for erased pairs (still decrements). `ChannelResult.reason` overrides the errno text. | `Core/ByteChannel.hpp:7-22,40-48`; `Stream/StreamTable.hpp:108`; `Stream.cpp:217-226,572-596,670-676` |
| SF3 | A `ByteChannel` must be constructed on the main thread (`addDrainSource` via `call_once`). The precedent for faces over shared off-heap state is `HttpTransferChannel` over `HttpTransfer`. | `ByteChannel.hpp:75`; `ChannelDrain.cpp:47-51`; `HttpStream/HttpTransfer.hpp:104-120` |
| SF4 | Manager registration is generic for any eco/system effect module, dotted names included (`Eco_System_registerManager_Http_Server` exists). | `compiler/src/Generate/MLIR/Functions.elm:326-345,579-583` |
| SF5 | Kernel homes `Socket` and `Tls` are unused. | `test/scripts/check-kernel-homes.sh` |
| SF6 | OpenSSL is already on every native AOT link on Linux (`-lssl -lcrypto`, or static archives) and macOS (brew `openssl@3` statics, there for libzip/SHA1; macOS curl is the SDK's). `ecoSystemLibs()` is generated from `ECO_SYSTEM_MODS` and linked inside `--start-group`. So `EcoSystem_Tls` needs only `ECO_SYSTEM_MODS += Tls` and `target_link_libraries(EcoSystem_Tls PRIVATE OpenSSL::SSL)`. Windows curl uses Schannel. | `EcoNativeDriver.cpp:597-618,1060,1126,1142-1150`; `runtime/src/codegen/CMakeLists.txt:1380-1386,1585`; `CMakeLists.txt:330-337` |
| SF7 | The scheduler idles in `eventCV_.wait` until a registered async source's `ready()` is true; `notifyWorkAvailableFromAsync()` wakes it; `processReadyAsync()` runs every drain on the main thread. | `runtime/src/platform/Scheduler.cpp:562-624,666-701` |
| SF8 | `HttpServerService` has the listen/accept helpers (cloexec, `accept4` on Linux at `:512-514`, `SO_NOSIGPIPE`/`MSG_NOSIGNAL` `:60-75`) and the graceful close that drains input for 2 s after `SHUT_WR` (`:476-498`). Its manager parks requests with no subscriber (`HttpServerManager.cpp:187-199`). | `HttpServer/*` |
| SF9 | macOS children are spawned with `POSIX_SPAWN_CLOEXEC_DEFAULT`, so an fd between `accept` and `fcntl(FD_CLOEXEC)` is not inherited. | `ChildProcess/Spawn.cpp:205-207` |
| SF10 | SIGPIPE is ignored in standalone programs but **not in embed mode**; socket writes must use `MSG_NOSIGNAL`/`SO_NOSIGPIPE`, and TLS must not write through OpenSSL's socket BIO. | `eco_entry.cpp:304-323` |
| SF11 | T7 kill handles: `cancel(token)` returns true only if it removed a job that will never produce a result (then the handle decrements); otherwise the drain finds the resume gone, decrements and skips. | `Core/KillHandle.cpp:6-13` |
| SF12 | `SysWorkPool`'s drain skips `complete` for an orphaned token (killed task). | `Core/SysWorkPool.cpp:117` |
| SF13 | Test harnesses: `-- CHECK:` supports `{{regex}}` on both backends; `-- SKIP-JS:` skips a **whole** test; tests are discovered by a top-level `main`; `ECO_TEST_PORT` is a free, unbound port; stdout and stderr are both captured. | `test/CheckPatterns.hpp:31-38`; `test/scripts/run-js-e2e.js:28,240-243,351-353,447`; `test/TestPort.hpp` |
| SF14 | The JS `Stream.js` Node adapters destroy the Node stream on close: unusable as-is for a duplex socket (half-close would kill both directions). `_Stream_describeError` yields `"<code>: <message>"` unless the error carries a `reason`. | `Stream.js:216-230,695,719,816-821,870-874,1027` |
| SF15 | Node v22: `resetAndDestroy` exists; it throws on Unix and on `TLSSocket` (use the raw `net.Socket` underneath); Unix sockets report `localAddress`/`remoteAddress` `undefined`; `setNoDelay`/`setKeepAlive` are no-ops on Unix sockets; `server.maxConnections` drops; a `udp6` socket sending to `127.0.0.1` fails `EINVAL` (to `::ffff:127.0.0.1` works); IPv6 multicast interface must be `"::%<ifname>"`; `dns.lookup("")` succeeds with `[]`; `tls.getCACertificates('system')` exists; a 65 508-byte datagram fails `EMSGSIZE`. | review J probes |
| SF16 | glibc `inet_pton` rejects IPv4 fields with leading zeros and has no scope support; Python 3.11 `ipaddress` prints IPv4-mapped addresses in hex (`::ffff:7f00:1`) and says `::ffff:127.0.0.1` is not loopback. | probes |
| SF17 | This container: `::1` binds; IPv4 multicast join works; broadcast without `SO_BROADCAST` gives `EACCES`; `localhost` resolves `::1` first. | probes |
| SF18 | `system-kernel-cpp/tests/` (elm-test-rs, `tests/tests/*.elm`) compiles `../src` with **stock elm and only elm/core**: `Socket.Address` and what it imports must be pure Elm without `Bytes`. `System.File.Path` qualifies. | `system-kernel-cpp/tests/elm.json` |

---

## 3. Architecture

### 3.1 Module map

| Elm module | Exposed | Effect module (manager key) | Kernel home | C++ library |
|---|---|---|---|---|
| `Socket` | yes | yes — `"Socket"` (`OnConnection`) | `Socket` | `EcoSystem_Socket` |
| `Socket.Address` | yes | no | none (pure Elm, SF18) | — |
| `Socket.Tcp` | yes | no | `Socket` | `EcoSystem_Socket` |
| `Socket.Unix` | yes | no | `Socket` | `EcoSystem_Socket` |
| `Socket.Udp` | yes | yes — `"Socket.Udp"` (`OnMessage`) | `Socket` | `EcoSystem_Socket` |
| `Socket.Tls` | yes | no | `Tls` | `EcoSystem_Tls` (links `EcoSystem_Socket`, `OpenSSL::SSL`) |
| `Socket.Internal` | no | no | — | — |

Import graph (acyclic): `Socket.Address` → `System.File.Path`; `Socket.Internal` → `Socket.Address`,
`Stream.Internal`; `Socket` → `Socket.Internal`, `Socket.Address`, `Stream`; `Socket.Tcp`/`Socket.Unix`
→ `Socket`, `Socket.Internal`; `Socket.Udp` → `Socket`, `Socket.Internal`, `Socket.Address`;
`Socket.Tls` → `Socket`, `Socket.Tcp`, `Socket.Internal`.

`Socket.Internal` holds (F23 alias pattern):

```elm
type Connection = Connection { id : Int, readable : Readable Bytes, writable : Writable Bytes, local : Endpoint, remote : Endpoint }
type Listener = Listener { id : Int, endpoint : Endpoint }
type Error = Error { code : String, message : String }
type UdpSocket = UdpSocket { id : Int, endpoint : InetEndpoint }

toError : ( String, String ) -> Error
toEndpoint : ( Int, String, Int ) -> Endpoint          -- §3.2 EpT, §D.1 fallback
toInetEndpoint : ( String, Int ) -> InetEndpoint
toConnection : ( Int, ( Int, Int ), ( ( Int, String, Int ), ( Int, String, Int ) ) ) -> Connection
toListener : ( Int, ( Int, String, Int ) ) -> Listener
```

`Socket` exposes `type alias Connection = Internal.Connection` etc.; `Socket.Udp` exposes
`type alias Socket = Internal.UdpSocket`. `Endpoint(..)` and `InetEndpoint` live in `Socket.Address`
(users need the constructors; an alias cannot expose them).

### 3.2 Boundary shapes

Per base plan B1–B8. Masks: 2 bits per slot (0 boxed, 1 Int), slot *i* at bits *2i*.

| Name | Tuple | Mask |
|---|---|---|
| `FErr` | `( String code, String message )` | 0 |
| `EpT` | `( Int kind, String text, Int port )`; kind 0 Inet (text = address, any RFC 4291 form, IPv6 scope as `%ifname` or `%index`), 1 Unix (text = POSIX path, `""` unnamed; port 0) | `0x11` |
| `ConnT` | `( Int connId, ( Int readableId, Int writableId ), ( EpT local, EpT remote ) )` | outer `0x1`; `(Int, Int)` `0x5`; `(EpT, EpT)` 0 |
| `ListenT` | `( Int listenerId, EpT bound )` | `0x1` |
| `UdpT` | `( Int socketId, ( String address, Int port ) )` | outer `0x1`; inner `0x4` |
| `DgramT` | `( Bytes data, ( String fromAddress, Int fromPort ) )` | outer 0; inner `0x4` |
| `CredT` | `( Int pid, Int uid, Int gid )` | `0x15` |
| `InfoT` | `( String protocol, Maybe String alpn, String cipher )` | 0 |

**Decoding fallback (§D.1):** if a kernel's address text does not parse (should not happen), Elm uses
`any IPv6` when the text contains `:`, otherwise `any IPv4`.

### 3.3 Native: the IO reactor

#### 3.3.1 `IoReactor` (`EcoSystem_Core`: `Core/IoReactor.{hpp,cpp}`)

One leaky singleton (base plan §3.4) with one detached thread, started on first use from the main
thread. Backends: epoll + `eventfd` (Linux), kqueue + `EVFILT_USER` with `EV_CLEAR` (macOS); WIN32:
a stub whose `submit` drops work (Windows kernels fail before reaching it).

```cpp
namespace Eco::System {
// Reactor-thread object owning one fd's IO. Never touches the heap (G1).
class IoHandler : public std::enable_shared_from_this<IoHandler> {
public:
    virtual ~IoHandler() = default;
    virtual void onReady(bool readable, bool writable, bool errorOrHangup) = 0;   // reactor thread
    virtual void onTimer() {}                                                     // reactor thread
    virtual void onCloseAll() = 0;      // reactor thread: embed stop / exit quiesce: close now
    uint64_t key() const;               // slot | generation << 32, set by add()
};

class IoReactor {
public:
    static IoReactor& instance();
    // Any thread. Runs fn on the reactor thread, in submission order. fn may capture only POD and
    // shared_ptrs to reactor-side state (G1).
    void submit(std::function<void()> fn);
    // Reactor thread only:
    uint64_t add(std::shared_ptr<IoHandler> h, int fd);      // registered with NO interest
    void setInterest(uint64_t key, bool read, bool write);   // demand-driven, see below
    void setTimer(uint64_t key, int64_t deadlineMonoMs);     // one timer per handler; 0 cancels
    void remove(uint64_t key);                               // EPOLL_CTL_DEL / EV_DELETE; caller closes fd after
    int64_t nowMs() const;                                   // steady clock
    // Main thread: close every handler (embed stop, §3.3.9) and wait until done.
    void closeAll();
};
}
```

Rules (each is a review fix; §9):
1. **Interest is level-triggered and demand-driven, and an fd with no interest is not in the kernel
   set.** `setInterest(key, false, false)` does `EPOLL_CTL_DEL` (kqueue: `EV_DELETE` both filters);
   any other value `ADD`/`MOD`. epoll reports `EPOLLERR`/`EPOLLHUP` even with no requested events,
   so a registered idle fd that the peer resets would spin (N1).
2. **Event data is the 64-bit key** (slot index + generation), never the fd. `remove` bumps the
   slot's generation; an event whose generation does not match is dropped (fd-number reuse,
   descriptions duplicated into children).
3. **`remove` before `close`**, always; only the handler closes its fd, on the reactor thread.
4. **Wake:** `submit` pushes under the command mutex, then writes the eventfd / triggers
   `EVFILT_USER`. The loop resets the eventfd (or relies on `EV_CLEAR`) **before** draining the
   command queue.
5. **Loop:** `runOnce(timeout)`: timeout = earliest timer deadline (min-heap) or infinite; wait;
   dispatch timers whose deadline passed; dispatch events (`EPOLLIN`→readable, `EPOLLOUT`→writable,
   `EPOLLERR|EPOLLHUP|EPOLLRDHUP`→errorOrHangup; kqueue `EV_EOF`/`EV_ERROR`→errorOrHangup);
   drain commands. `runOnce` is the unit a later Scheduler integration would call (§8).
6. **Lock order:** command mutex → channel-results queue / socket-events queue → Scheduler mutex.
   No lock is held while calling a handler.
7. **Exit:** `std::exit` may run while the thread is inside a handler; handlers hold only POD and
   OS resources, so this is safe for plain sockets. TLS adds an atexit quiesce (§3.6).

#### 3.3.2 Socket results to the main thread (`EcoSystem_Socket`: `Socket/SocketEvents.{hpp,cpp}`)

Stream data uses the existing channel-results queue (`postChannelResult`, SF2). Everything else uses
one new POD queue, `SocketEvent`, drained by a main-thread drain registered with `addDrainSource`
(ready predicate: a lock-free non-empty flag). The drain resumes tasks / delivers messages and calls
`Scheduler::drain()` once per resumed task or delivered message (G12).

```cpp
struct SockEndpoint { int kind = 0; std::string text; int64_t port = 0; };   // EpT, POD
struct Cred { int64_t pid = 0, uid = 0, gid = 0; };
struct TlsInfo { std::string protocol, alpn, cipher; };
struct SocketEvent {
    enum class Kind : uint8_t { Connected, Accepted, Datagram, OpDone, ListenerClosed, UdpClosed };
    Kind kind;
    uint64_t token = 0;              // Connected / OpDone / *Closed: the task's resume token (0: none)
    int64_t ownerId = 0;             // listener id (Accepted, ListenerClosed) or udp id (Datagram, UdpClosed)
    bool failed = false; std::string code, message;   // failure (§D.5)
    std::shared_ptr<Conn> conn;      // Connected / Accepted
    SockEndpoint local, remote;
    Cred cred; bool hasCred = false; // Unix: captured at accept/connect
    TlsInfo tls; bool hasTls = false;// captured at handshake end
    std::string data;                // Datagram payload
};
```

#### 3.3.3 Connections (`Socket/Conn.{hpp,cpp}`, `Socket/ConnChannel.{hpp,cpp}`)

`Conn : IoHandler` holds the fd and all per-connection IO state, **reactor-thread only**. It has a
pluggable **transport** so TLS is added without Core or Socket knowing OpenSSL:

```cpp
class Transport {                       // reactor thread
public:
    virtual ~Transport() = default;
    // 0: handshake done; 1: in progress (wantRead/wantWrite set); <0: failed (errCode/errMessage set)
    virtual int handshake() { return 0; }
    // Up to n bytes of application data: >0 bytes, 0 EOF, -1 would block, -2 error.
    virtual ssize_t read(char* buf, size_t n) = 0;
    virtual ssize_t write(const char* buf, size_t n) = 0;   // >=0 accepted, -1 would block, -2 error
    virtual int shutdownWrite() = 0;    // TLS: close_notify then SHUT_WR; plain: SHUT_WR. 0 done, 1 again
    virtual bool hasBufferedRead() const { return false; }   // TLS: SSL_has_pending
    bool wantRead = false, wantWrite = false;               // what the last call needs
    std::string errCode, errMessage;
};
std::unique_ptr<Transport> makePlainTransport(int fd);      // recv/send with MSG_NOSIGNAL
using TransportFactory = std::function<std::unique_ptr<Transport>(int fd, bool isServer)>;
```

`Conn` state: `fd`, `transport`, `readReqs` (deque of `{channelId, token, max}`), `writeQ` (deque of
`{channelId, token, bytes, offset}`), `closeToken` (write face close), flags `readDone` (EOF or read
face closed), `writeDone`, `readAbandoned` (read face shut down before EOF), `closed`.

Reactor behaviour:
- **Interest** = read if `readReqs` non-empty or the transport `wantRead` or draining (below); write
  if `writeQ` non-empty or `wantWrite` or a pending `shutdownWrite` returned 1.
- **Read request** (`submit`): push; if `transport->hasBufferedRead()` serve immediately (TLS
  buffered plaintext would otherwise hang, N6); else update interest.
- **Readable:** while `readReqs` non-empty: `read(max)`: >0 → `ChannelResult{Read, bytes}`; 0 →
  EOF result for this and every queued read, `readDone`; -1 → stop; -2 → error result with
  `reason = "read <CODE>"` (e.g. `"read ECONNRESET"`) for every queued read.
- **Writable:** write from `writeQ` front; a request completes (`ChannelResult{Write, written}`) when
  all its bytes are accepted; an error fails it and every later write with `reason = "write <CODE>"`;
  then, if a close is pending and `writeQ` is empty, `shutdownWrite()`; when it returns 0 →
  `ChannelResult{Close}` for `closeToken`, `writeDone`.
- **errorOrHangup** only arrives with demand (rule 1); it is treated as readable + writable (the
  syscalls report the error).
- **Final close** when `readDone && writeDone`, or on abort: if `readAbandoned` and not aborting,
  keep reading and discarding for up to **2 s** (timer) or until EOF before closing, so Linux does
  not turn the FIN into RST (N8, SF8). Then `remove(key)`, `close(fd)`.
- **Abort** (`Socket.close`): fail every queued read/write with `ECANCELED`, `reason = "socket
  closed"`; complete a pending close token with err 0; no drain; `remove`; `close`. Later requests
  complete at once with the same reason. **Reset:** `setsockopt(SO_LINGER, {1, 0})` (TCP only),
  then abort.
- **Connect** (client `Conn`): non-blocking `connect`: `0` → connected; `EINPROGRESS` → write
  interest + timer; `EAGAIN` (Unix, full backlog) → fail `EAGAIN`; on writable
  `getsockopt(SO_ERROR)`; then `handshake()` until 0 (TLS). The connect timeout covers TCP connect
  **and** the TLS handshake; timeout → `ETIMEDOUT`. Result: one `SocketEvent::Connected` (endpoints
  per §D.3/`getsockname`/`getpeername`, Unix credentials, TLS info) or a failure (the reactor closes
  the fd).

**Faces** (main thread, SF3): `ConnReadFace` and `ConnWriteFace` derive from `ByteChannel`, each
holding `std::shared_ptr<Conn>`. `requestRead/Write/close` `submit` lambdas to the reactor.
`shutdown()` on the read face sets `readAbandoned` and drops read interest (no `SHUT_RD`); on the
write face it fails queued writes `ECANCELED` and runs `shutdownWrite`. A face destroyed without
close/shutdown calls `shutdown()` (its stream pair was erased) and notifies `SocketTables` so the
`ConnEntry` is erased with its second face.

#### 3.3.4 Listeners (`Socket/Listener.{hpp,cpp}`)

`ListenerHandler : IoHandler` over a listening fd, with a `TransportFactory` (plain, or TLS supplied
by `EcoSystem_Tls`). **Credit** lives on the reactor side: `int64_t credit` (−1 = unlimited). The main
thread sends `addCredit(n)` (one per parked `accept`; −1 when one is cancelled, floor 0) and
`setUnlimited(bool)` (while the listener has subscribers). Read interest only while
`credit != 0 && handshaking < 64`.
- **Readable:** loop `accept4(SOCK_NONBLOCK|SOCK_CLOEXEC)` (macOS: `accept` + `fcntl` +
  `SO_NOSIGPIPE`, SF9) while credit allows: on success decrement finite credit, create a `Conn`.
  Plain: post `Accepted` at once. TLS: handshake in the reactor with a **120 s** deadline (Node's
  default); credit is consumed only on completion (a failed or timed-out handshake returns the
  credit and is dropped silently, as Node without a `tlsClientError` listener); at most 64
  concurrent handshakes per listener.
- **Errors:** `EAGAIN`/`EWOULDBLOCK` → stop; `ECONNABORTED`/`EINTR` → retry; `EMFILE`/`ENFILE`/
  `ENOBUFS`/`ENOMEM` → drop interest and retry from a 100 ms timer (no spin, N9).
- **Close** (`closeListener`): close every handshaking connection, `remove`, `close(fd)`, unlink the
  Unix path if this listener created it, then post `ListenerClosed{token}`: the task completes only
  after the fd is closed and the path unlinked, so an immediate re-listen works.

**Main thread** (`Socket/SocketTables.{hpp,cpp}`, registries keyed on `heapGeneration`, holding **no
HPointers** — tokens are scheduler resume tokens; taggers live in the managers):
- `ListenerEntry { shared_ptr<ListenerHandler>; SockEndpoint bound; deque<uint64_t> parkedAccepts;
  deque<SocketEvent> held; bool closed; }`
- `ConnEntry { shared_ptr<Conn>; int64_t readableId, writableId; Cred cred; TlsInfo tls; bool isUnix,
  isTls; int facesAlive; }` — erased when both faces are gone.
- `UdpEntry { shared_ptr<UdpHandler>; SockEndpoint bound; deque<uint64_t> parkedReceives;
  deque<SocketEvent> held (max 64; on overflow drop the oldest); bool closed; }`

#### 3.3.5 UDP (`Socket/Udp.{hpp,cpp}`)

`UdpHandler : IoHandler`: bound `SOCK_DGRAM` fd, non-blocking, cloexec; `SO_SNDBUF` and `SO_RCVBUF`
≥ 65 536 (macOS's default `maxdgram` is 9 216, N15). Same credit scheme as listeners (one credit per
parked `receive`, unlimited while subscribed). **Readable:** `recvmsg` into a 65 536-byte buffer;
`MSG_TRUNC` in `msg_flags` → drop and continue; post `Datagram`. **Send** (`submit`): queue;
`sendto` with the destination converted per §D.4; `EAGAIN` → write interest; result `OpDone`.
**Membership:** `IP_ADD_MEMBERSHIP` (`imr_interface` = the interface address or `INADDR_ANY`) /
`IPV6_JOIN_GROUP` (`ipv6mr_interface` = `if_nametoindex` of the interface address's scope, or the
decimal scope, 0 if none) and the drop variants. **Close:** `remove`, `close`, post `UdpClosed`.

#### 3.3.6 Name lookup

`getaddrinfo(name, nullptr, {AF_UNSPEC, SOCK_STREAM, flags 0})` on `SysWorkPool` (P mode).
`""` → `ENOTFOUND` without calling. Results in returned order, duplicates removed, printed with
`inet_ntop` (+ `%ifname` scope). Errors (§D.5): `EAI_NONAME`/`EAI_NODATA` → `ENOTFOUND`; `EAI_AGAIN`
→ `EAI_AGAIN`; `EAI_MEMORY` → `ENOMEM`; `EAI_SYSTEM` → the errno name; others → `EAI_FAIL`.
Message: `getaddrinfo <CODE> <name>` (Node's wording).

#### 3.3.7 Listen and bind

`tcpListen`/`unixListen`/`udpBind` run on `SysWorkPool` (socket, options, bind, listen). Their
`PoolResult` owns the fd (and created Unix path) through an RAII holder, so a killed task's orphaned
result (SF12) closes the fd and unlinks the path in its destructor (N11). `complete` (main thread)
hands the fd to the reactor (`submit` add), records the table entry and increments a `pendingAsync`
count for the listener/socket (released by its `*Closed` drain). Options:
- TCP: `SO_REUSEADDR` always; for IPv6 addresses `IPV6_V6ONLY` set explicitly to `ipv6Only`
  (Linux's default comes from `bindv6only`); `listen(backlog)`.
- Unix: §D.3 path checks first; `removeExisting` (only an existing socket); `bind`;
  `chmod(permissions)` if given, **before** `listen`; `listen(511)`.
- UDP: `SO_REUSEADDR` (+ `SO_REUSEPORT` on macOS) if `reuseAddress`; `SO_BROADCAST`;
  `IPV6_V6ONLY` as TCP; buffer sizes.

#### 3.3.8 Keep-alive rule additions (base plan §3.4)

| Holds a `pendingAsync` count | Released by |
|---|---|
| an open listener | the `ListenerClosed` drain (or heap reset) |
| a bound UDP socket | the `UdpClosed` drain |
| a connect in progress (each `connectToHost` attempt too) | the `Connected` drain, or the kill handle if `cancel` removed it |
| an R-mode operation in flight (`OpDone`) | its drain |
| a parked fd read/write on a connection (existing channel rule) | as today |

Parked `accept` and `receive` tasks hold **no** count of their own (their listener / socket does);
their `CancelFn` removes the token from the parked deque, returns one credit and returns **false**
(nothing to decrement, SF11). An idle connection with no parked read or write holds nothing (as
stdio streams).

#### 3.3.9 Heap reset, embed stop

The tables are cleared on a new `heapGeneration` (as `Registry`), closing every entry's reactor
object first (`submit` abort / close; counts are dropped with the heap). `eco_app_stop` (embed) calls
`IoReactor::closeAll()` through a stop hook, so listeners and sockets do not stay bound in the host
process.

### 3.4 Delivery rule (SD2, SD14)

An accepted connection (datagram) arriving on the main thread goes, in order:
1. to the **oldest parked `accept`** (`receive`) task of that listener (socket);
2. else to **every** `onConnection` (`onMessage`) tagger of that listener (socket), in subscription
   order (as `Http.Server.onRequest`), the same `Connection` value to each;
3. else into the entry's **held FIFO** (datagrams: max 64, oldest dropped).

When a consumer appears (a new `accept`, or `onEffects` adding the first tagger), held items are
served **first**, in order. `closeListener` aborts every held connection and fails every parked
`accept` with `ECANCELED`; `Socket.Udp.close` drops held datagrams and fails parked `receive`s. A
subscription naming a closed or unknown listener/socket never fires.

### 3.5 Effect managers

C++ managers per base plan C.0 (T6), modelled on `HttpServerManager.cpp`:
- **`"Socket"`** (C.1): registry listener id → encoded taggers (scanned). `onEffects`: rebuild the
  map; for each listener whose tagger list became non-empty send `setUnlimited(true)` and deliver
  its held FIFO; became empty → `setUnlimited(false)`. Delivery (T8): build `ConnT` once (rooted),
  call each tagger, `sendToApp`, `drain()`.
- **`"Socket.Udp"`** (C.2): the same with `DgramT`.

JS (D15): real Elm manager bodies, as `Http.Server`'s: one listener process per subscribed id via the
JS-only kernels `attachConnectionListener`/`attachMessageListener`, delivery with
`Platform.sendToSelf`, and `holdConnection`/`holdDatagram` for items that arrive after the last
subscriber left (Appendix E).

### 3.6 TLS (`EcoSystem_Tls`: `Tls/{TlsContext,TlsTransport,Tls,TlsExports}.{hpp,cpp}`)

- **Transport:** `TlsTransport : Transport` with an `SSL*` over **memory BIOs**; the transport moves
  bytes between the socket (`recv`/`send` with `MSG_NOSIGNAL`) and the BIOs, so OpenSSL never writes
  to the socket (no SIGPIPE in embed mode, SF10). `SSL_OP_NO_RENEGOTIATION`,
  `SSL_MODE_ENABLE_PARTIAL_WRITE`, `SSL_MODE_ACCEPT_MOVING_WRITE_BUFFER`,
  `SSL_OP_IGNORE_UNEXPECTED_EOF` (a FIN without `close_notify` is `Closed`, as Node). Per-operation
  `wantRead`/`wantWrite` drive interest independently of demand (N6).
- **Contexts** (`TlsContext`): built on `SysWorkPool` (CA loading is file IO), never on the reactor or
  main thread. Client verification:
  - `SystemCertificates`: `SSL_CERT_FILE`/`SSL_CERT_DIR` if set; else
    `SSL_CTX_set_default_verify_paths`; if the store is then empty, the first existing of
    `/etc/ssl/certs/ca-certificates.crt`, `/etc/pki/tls/certs/ca-bundle.crt`,
    `/etc/ssl/ca-bundle.pem`, `/etc/ssl/cert.pem`, `/usr/local/etc/openssl@3/cert.pem`,
    `/opt/homebrew/etc/openssl@3/cert.pem`. Cached process-wide.
  - `TrustedCertificates pem`: a fresh store with only those certificates.
  - `NoVerification`: `SSL_VERIFY_NONE`.
  - Host check: if `serverName` parses as an address, **no SNI** and
    `X509_VERIFY_PARAM_set1_ip_asc`; else SNI + `SSL_set1_host`.
  - ALPN: `SSL_set_alpn_protos`; the server select callback picks the first server protocol the
    client offers; no overlap → `SSL_TLSEXT_ERR_ALERT_FATAL` (Node's behaviour).
- **Init and exit:** first use calls `OPENSSL_init_ssl(OPENSSL_INIT_NO_ATEXIT, nullptr)` and then
  registers `atexit(tlsQuiesce)`, which asks the reactor to stop dispatching handlers and waits
  ≤ 100 ms for acknowledgement. Atexit handlers run in reverse order, so this runs before any
  OpenSSL cleanup curl may have registered earlier (N13).
- **Close:** `closeWritable` → `close_notify` + `SHUT_WR`; `Socket.close` sends no `close_notify`
  (Node's `destroy()`); `Socket.reset` as plain.
- **Errors** (§D.5).
- **Info** (`protocol`, `alpn`, `cipher`) is captured as POD when the handshake ends and stored in
  the `ConnEntry`; `Socket.Tls.info` answers from it.
- **Windows:** stubs failing `ENOTSUP`.

---

## 4. Phases

**Rules for every phase.** Work happens in repo copies under `/work/worktrees/<n>` (own `build/`,
`ECO_HOME=<copy>/.eco-home`), merged by 3-way `git merge-file` run from `/tmp` (git does not work
inside `/work`). Every C++ file starts with a header comment naming the base-plan templates it
uses. Gates (base plan §3.3.3): `full` (which includes `run-js-e2e`), the validate tree
(`ECO_NURSERY_POISON=1 ECO_HEAP_CONFIG=$PWD/benchmarks/heap-config-gc-pressure.json
build-validate/test/test --filter eco-system`), stress (`-n 10` under validate), the root-bound
check, `check-kernel-homes.sh`. Each test command runs once, teed to `/tmp`. Never two `test/test`
binaries on one source tree at once.

### S0 — API stubs, docs, plumbing

Files: `system-kernel-cpp/src/Socket.elm`, `src/Socket/{Address,Internal,Tcp,Unix,Udp,Tls}.elm`,
`src/Eco/Kernel/{Socket,Tls}.js`, `src/eco-system/{Socket,Tls}/*`, `system-kernel-cpp/CMakeLists.txt`,
`runtime/src/codegen/CMakeLists.txt` (`ECO_SYSTEM_MODS`), `elm.json`, `README.md`.

1. Every Appendix A module with full annotations and doc comments; kernel wrappers annotated per
   Appendix B (`kX : … ; kX = Eco.Kernel.Socket.x`); effect plumbing per Appendix C with trivial Elm
   manager bodies; Elm logic written where it is pure (decoders, `connectToHost`), kernels stubbed.
2. `elm.json` `exposed-modules` (flat) gains the six public modules; README module list.
3. JS kernel files with every Appendix B/E function failing with code `"ENOTSUP"` ("not implemented
   yet"); headers import exactly what they use (base plan F14 pitfall).
4. C++: `ECO_SYSTEM_MODS += Socket Tls`; `eco_system_module(Socket POSIX …)`,
   `eco_system_module(Tls POSIX …)` with `target_link_libraries(EcoSystem_Tls PUBLIC EcoSystem_Socket
   PRIVATE OpenSSL::SSL)` (`find_package(OpenSSL REQUIRED)` on POSIX); exports for every Appendix B
   symbol failing `"ENOTSUP"`; `Eco_System_registerManager_Socket` / `_Socket_Udp` with managers
   that accept subscriptions and never fire.
5. **Exit:** `pnpm run docs:check` (with `build/toolchain/bin` on `PATH`) lists the new modules;
   `test/eco-system/src/SocketSmokeTest.elm` (imports every module, prints a parsed address, calls
   one stub and prints its error code) passes natively and on JS; `check-kernel-homes.sh` ok;
   `full` green.

### S1 — `Socket.Address`

Files: `src/Socket/Address.elm`, `scripts/gen-address-golden.py`, `tests/tests/AddressGolden.elm`,
`tests/tests/AddressTest.elm`.

1. Implement §D.1. Representation: `V4 Int` (32-bit) | `V6 (List Int) String` (16 octets, scope).
2. The generator writes cases from a fixed input list (valid and invalid for every §D.1 rule:
   scopes, mapped and compatible addresses, `::`, leading/trailing zero groups, single zero group,
   upper case, 8 groups, 9 groups, two `::`, `1.2.3`, `01.2.3.4`, `256.0.0.1`, `1.2.3.4.5`, empty,
   whitespace, …). Validity: Python `ipaddress` on the part before `%` + the §D.1 scope grammar.
   Canonical text: `ipaddress.compressed`, except IPv4-mapped (`::ffff:0:0/96`), printed `::ffff:` +
   dotted by the generator. Predicates: computed by the generator from the octets (§D.1), not by
   `ipaddress`. The output records the Python version.
3. Tests: golden validity, `toString`, `toOctets`, `family`, predicates, `unmapIPv4`; `fromOctets`
   edge cases (wrong length, out of range); `loopback`/`any`.
4. **Exit:** `cmake --build build --target eco-system-elm-tests` green.

### S2 — `IoReactor` and `SocketUtil`

Files: `Core/IoReactor.{hpp,cpp}`, `Core/SocketUtil.{hpp,cpp}`, `HttpServer/HttpServerService.cpp`
(uses `SocketUtil`), `system-kernel-cpp/CMakeLists.txt`, `test/eco-system-core/EcoSystemCoreTest.cpp`.

1. §3.3.1 with both backends (kqueue under `#ifdef __APPLE__`, untested) and a WIN32 stub.
2. `SocketUtil`: `setCloexec`, `setNonBlocking`, `setNoSigPipe`, `kSendFlags`; sockaddr ⇄ `(text,
   port)` with `%ifname` (via `if_indextoname`) and parsing `%ifname` or `%index`; Unix sockaddr from
   a path with the §D.3 length check; `errnoName` (existing table); `gaiCode`; WIN32 stubs.
3. Core unit tests (no Elm): a test handler over `socketpair` echoing through the reactor; an idle
   registered-then-unregistered fd whose peer closes → **no busy loop** (`runOnce` iterations over
   200 ms ≤ 5); 1 000 pairs with interleaved traffic; `submit` racing readiness; `remove` then an
   event for the old generation dropped; timer ordering; `closeAll`.
4. **Exit:** core test green normally and under the validate tree; `Http.Server` tests unchanged.

### S3 — TCP and Unix stream sockets

Files: `Socket/{Conn,ConnChannel,Listener,SocketEvents,SocketTables,SocketManager,Socket,SocketExports}.{hpp,cpp}`,
the Elm modules `Socket`, `Socket.Tcp`, `Socket.Unix`, tests.

1. §3.3.2–3.3.4, 3.3.6–3.3.9; kernels B.1; manager C.1; kill handles (T7) on `tcpConnect`,
   `unixConnect`, `accept`, `lookup`.
2. Elm: wrappers and decoders; `connectToHost` (§D.2); `Socket.close`/`reset` as
   `Task.mapError never`.
3. Tests in `test/eco-system/src/` (all loopback; JS too unless marked SKIP-JS):
   - `SocketTcpEchoTest`: listen `127.0.0.1:0`, `onConnection`; the server reads to `Closed` **then**
     writes the reply and closes; the client writes, half-closes, reads to `Closed`.
   - `SocketTcpAcceptTaskTest`: task-only server; two clients; each arrives through its own
     `accept`; `listenerEndpoint` port ≠ 0.
   - `SocketTcpBothTest`: a parked `accept` and a subscription; the first connection goes to the
     task, the second to the subscription.
   - `SocketTcpHeldTest`: connect before anyone accepts or subscribes; a later `accept` gets it.
   - `SocketTcpRefusedTest`: connect to `ECO_TEST_PORT` → `ECONNREFUSED`, `errorIsConnectionRefused`.
   - `SocketTcpInUseTest`: a second listen on the same port → `EADDRINUSE`.
   - `SocketTcpTimeoutTest` (**SKIP-JS**: Node accepts eagerly): listener with backlog 1 and no
     accept, fill its queue, connect with `timeout = Just 300` → `ETIMEDOUT`; a second such connect
     killed with `Process.kill` stops (the program exits by itself).
   - `SocketTcpCloseTest`: `Socket.close` with a parked read → `{{socket closed}}`; data written
     before it arrives; the peer reads to `Closed`; `close` twice is fine.
   - `SocketTcpResetTest`: `Socket.reset`; the peer's read fails `{{read ECONNRESET}}`.
   - `SocketTcpOptionsTest`: `setNoDelay`, `setKeepAlive (Just 1500)` succeed on TCP and on Unix.
   - `SocketTcpIpv6Test`: listen `::1`; prints `ipv6: ok` or `ipv6: unavailable <code>`;
     CHECK `{{ipv6: (ok|unavailable \w+)}}`; dual-stack `any IPv6` with an IPv4 client shows an
     IPv4-mapped remote that `unmapIPv4` turns into `127.0.0.1`.
   - `SocketTcpConnectToHostTest`: `"127.0.0.1"`; `"localhost"` reaches a listener bound only to
     `127.0.0.1` although `::1` comes first (SF17); `"no-such-host.invalid"` →
     `errorIsHostNotFound`.
   - `SocketTcpKillAcceptTest`: kill a parked `accept`; a later `accept` still gets the next client.
   - `SocketLookupTest`: `localhost` contains a loopback address; `""` → `ENOTFOUND`.
   - `SocketCloseListenerTest`: a parked accept fails `errorIsCancelled`; `closeListener` twice is
     fine; re-listen on the same port succeeds; the program then exits by itself.
   - `SocketUnixTest`: listen in a temp dir with `permissions = Just 384` (0o600; checked via
     `System.File.stat`), connect, echo; the accepted side's remote is `Unix ""`, the client's
     remote is the path; `closeListener` unlinks the path; `removeExisting` replaces a stale socket
     and refuses a regular file (`EADDRINUSE`); connect to a missing path → `ENOENT`; a 200-byte
     path → `ENAMETOOLONG`.
   - `SocketUnixPeerCredentialsTest` (**SKIP-JS**: no peer credentials in Node): own pid/uid/gid;
     on a TCP connection → `EINVAL`.
   - Stress `test/stress-elm/src/EcoSystemSocket.elm`: 2 000 short connections in waves of 100 plus
     one 64 MiB transfer, checksummed.
4. **Exit:** native eco-system suite, validate tree, stress green.

### S4 — UDP

Files: `Socket/{Udp,UdpManager}.{hpp,cpp}` (+ exports), `src/Socket/Udp.elm`, tests.

1. §3.3.5; kernels B.2; manager C.2.
2. Tests: `SocketUdpEchoTest` (two sockets; `send`/`onMessage`; `localEndpoint`);
   `SocketUdpReceiveTaskTest` (task-only; a held datagram served to a later `receive`);
   `SocketUdpBothTest` (§3.4 order); `SocketUdpLargeTest` (a 65 507-byte datagram arrives whole);
   `SocketUdpBroadcastTest` (to `127.255.255.255` without `broadcast` → `EACCES`; with it the send
   succeeds); `SocketUdpIpv6Test` (`::1`, `ok|unavailable`; an `any IPv6` socket sending to
   `127.0.0.1` reaches an IPv4 socket); `SocketUdpCloseTest` (a parked `receive` →
   `errorIsCancelled`; the program exits); `SocketUdpMulticastTest` (IPv4 join/leave of
   `239.255.0.1` with interface `Just (loopback IPv4)` succeeds).
3. **Exit:** as S3.

### S5 — TLS

Files: `src/eco-system/Tls/*`, `src/Socket/Tls.elm`, `test/eco-system/scripts/gen-tls-fixtures.sh`,
`test/eco-system/src/TlsFixtures.elm`, tests.

1. §3.6; kernels B.3.
2. Fixtures (generated once, checked in): `gen-tls-fixtures.sh` uses the `openssl` CLI to make a test
   CA (100 years); a server certificate for `DNS:localhost, IP:127.0.0.1` signed by it (100 years);
   an **expired** server certificate signed with `openssl ca -startdate 20000101000000Z -enddate
   20010101000000Z` (a throwaway `openssl ca` config and database in a temp dir); a self-signed
   certificate. All PEMs become `String` constants in `TlsFixtures.elm` (no `main`, SF13).
3. Tests: `SocketTlsEchoTest` (server + client with `TrustedCertificates caPem`, `serverName =
   "localhost"`, ALPN `["h2","http/1.1"]` vs server `["http/1.1"]` → `info.alpn == Just
   "http/1.1"`, protocol `TLSv1.3`; echo with half-close); `SocketTlsVerifyTest` (expired →
   `CERT_HAS_EXPIRED`; self-signed → `DEPTH_ZERO_SELF_SIGNED_CERT`; `serverName = "example.com"` →
   `ERR_TLS_CERT_ALTNAME_INVALID`; `serverName = "127.0.0.1"` succeeds via the IP SAN;
   `NoVerification` succeeds against the self-signed server; every failure `errorIsCertificateInvalid`);
   `SocketTlsAlpnTest` (no overlap → the client fails
   `{{ERR_SSL_TLSV1_ALERT_NO_APPLICATION_PROTOCOL}}`); `SocketTlsResetTest` (`Socket.reset` on a
   TLS connection → the peer's read `{{ECONNRESET}}`); `SocketTlsInfoTest` (`info` on a plain TCP
   connection → `EINVAL`).
4. **Exit:** as S3.

### S6 — JS target

Files: `src/Eco/Kernel/{Socket,Tls}.js`, the Elm manager bodies of `Socket` and `Socket.Udp`,
`src/Eco/Kernel/Stream.js` (the duplex helper and `reason` support only).

1. Appendix E.
2. **Exit:** `run-js-e2e` green for every Socket test except the Appendix E skips; native suite
   unchanged.

### S7 — Documentation and examples

1. `examples/system/src/TcpEcho.elm`, `UdpEcho.elm`, `TlsGet.elm` (connects to a host given on the
   command line with `Socket.Tls.connect`, sends `GET / HTTP/1.0`, prints the status line).
2. `docs/getting-started.md` "System programs": a sockets paragraph; README module list and status;
   `design_docs/invariants.csv` `SYS_004` ("socket IO runs on the IoReactor thread; it never touches
   the heap; an fd is closed only by its handler, after `remove`").
3. **Exit:** examples build as AOT binaries and run (`TlsGet` only if the network is reachable);
   `full` green.

**Ordering:** S0 → (S1 ∥ S2) → S3 → (S4 ∥ S5) → S6 → S7. S6's TCP/Unix part may start after S3.

## 5. Test strategy summary

Pure Elm golden tests (S1); C++ reactor unit tests (S2); E2E loopback programs on native, the
validate tree and JS (S3–S6); stress under validate (S3). No external network in tests.

## 6. Ordering and dependencies

§4 "Ordering". `EcoSystem_Tls` → `EcoSystem_Socket` (transport factory, tables) → `EcoSystem_Core`
(reactor) and `EcoSystem_Stream` (stream pairs).

## 7. Open questions

None blocking. (Resolved: SD10 `connectToHost`; SD11 reactor placement; SD12 close/reset.)

## 8. Risks and follow-ups

| # | Risk | Mitigation |
|---|---|---|
| R1 | The reactor is new concurrency code on two OS backends. | S2 unit tests (idle hangup, 1 000 pairs, racing wake, stale generation); validate tree; stress. |
| R2 | IPv6 or multicast missing in CI containers. | IPv6 tests CHECK `ok|unavailable`; multicast only IPv4 on loopback. |
| R3 | TLS CA store on user machines (brew/static builds). | §3.6 probe list; `SSL_CERT_FILE`; tests use `TrustedCertificates`. |
| R4 | Unreachable connections leak (no finalizers): a dropped `Connection` keeps its fd until the program ends. | Documented in `Socket`'s module docs, as for streams. |
| R5 | Several subscribers of one listener get the same `Connection`. | Documented; one subscription per listener is the normal shape. |
| R6 | macOS untested (kqueue, `LOCAL_PEERCRED`, buffer sizes). | Same status as the rest of eco/system; README says so. |

Follow-ups: child pipes, stdio and `Http.Server` on the reactor (`Http.Server` gains `close`); the
reactor inside the Scheduler's idle wait if profiling warrants; SD4's Unix extras; STARTTLS; happy
eyeballs; client certificates; a Winsock/Schannel (or libuv) port.

## 9. Adversarial review log (2026-10-07)

Native review (N) and Elm/JS/test review (J). All fixed in v3.

| # | Sev | Finding | Fix |
|---|---|---|---|
| N1 | BLOCKER | epoll reports ERR/HUP on idle registered fds → busy loop | §3.3.1 rule 1 |
| N2 | BLOCKER | "nothing accepted without demand" is racy; undelivered connections undefined | SD14, §3.4, reactor-side credit |
| N3 | MAJOR | Modes K/L stale; control ops as S break fd ownership | Appendix B modes R/A; creds and TLS info captured as POD |
| N4 | MAJOR | Face ownership vs the stream table's `unique_ptr`; faces must be built on the main thread | §3.3.3 faces over `shared_ptr<Conn>` |
| N5 | MAJOR | No transport abstraction for TLS | §3.3.3 `Transport`, `TransportFactory` |
| N6 | MAJOR | TLS buffered plaintext; want-write during read | `hasBufferedRead`; per-op want flags |
| N7 | MAJOR | SIGPIPE through OpenSSL's socket BIO in embed mode | memory BIOs |
| N8 | MAJOR | `SHUT_RD` + close with unread data → RST | no `SHUT_RD`; 2 s discard-drain |
| N9 | MAJOR | accept `EMFILE` spin | timer back-off |
| N10 | MAJOR | TLS handshake demand and timeout | credit on completion; cap 64; 120 s |
| N11 | MAJOR | killed listen/connect leak fds | RAII pool results; orphaned connects closed |
| N12 | MAJOR | default CA store | probe list |
| N13 | MAJOR | OpenSSL atexit cleanup vs the reactor | `OPENSSL_INIT_NO_ATEXIT` + quiesce |
| N14 | MAJOR | stale events for reused fds | key with generation; DEL before close |
| N15 | MAJOR | macOS `maxdgram` 9 216 | buffer sizes |
| N16–N30 | MINOR | SF6 details; stale R2/R5; a new event queue and lock order; close details; UDP v4-mapped sends and the v6 multicast index; broadcast routing; `sun_path` NUL; Unix connect `EAGAIN`; missing masks; scope printing; EAI mapping; option rounding; TLS details (IP SNI, ALPN alert, unexpected EOF, contexts on the pool); WIN32 stubs; embed stop; test design; heap reset | §2, §3.3.x, §3.6, Appendices B/D, §4 |
| J1 | BLOCKER | JS adapters destroy the socket on close | Appendix E duplex helper |
| J2 | MAJOR | reason strings differ on JS | `err.reason`; CHECK regexes |
| J3 | MAJOR | `resetAndDestroy` throws on `TLSSocket` | keep the raw socket |
| J4 | MAJOR | Unix endpoints undefined; Node reports none | §D.3 rule from arguments |
| J5 | MAJOR | connect-timeout test impossible on JS | native-only test; JS timer for the option |
| J6 | MAJOR | `SKIP-JS` is per test | tests split |
| J7 | MAJOR | lost connection when the subscription leaves | hold kernels / held FIFO |
| J8 | MAJOR | IPv6 multicast interface form | `::%ifname` |
| J9 | MAJOR | v4 destination on udp6 fails on JS | v4-mapped conversion on both backends |
| J10 | MAJOR | Python as oracle is unstable | generator computes predicates and mapped printing |
| J11 | MAJOR | IP literal as TLS serverName | no SNI + IP check |
| J12–J22 | MINOR | IPv6 CHECK alternation; lookup offline/`""`; accept-test observability; option edge cases; `sun_path` length; TLS fixture recipe, ALPN alert, JS system CA; "agree by construction" (SD13); `exposing (..)` clashes; coverage gaps; JS `noteActivity` + header pitfall; stale text, masks, test paths | §3.2, §4, Appendices A/D/E |

## 10. Progress log

- 2026-10-07 — **S0 + S1 done** (repo copy `worktrees/p11a`, merged). Seven Elm modules per Appendix A,
  JS stubs, C++ stub exports for every Appendix B symbol, `ECO_SYSTEM_MODS += Socket Tls`, the two
  managers (accept subscriptions, never fire), `SocketSmokeTest`; `Socket.Address` with
  `scripts/gen-address-golden.py` (150 inputs, Python 3.11.2) and `AddressTest`. Results: elm-tests
  757/757, native eco-system 81/81, JS smoke ok, `full` green (2240/2240, JS 81/81), docs list the
  new modules. Bundle and AOT link needed no change (driven by `ECO_SYSTEM_MODS`).
  - Deviations: the Appendix E JS-only kernels are `Task Never`, so their stubs never complete
    (`attach*`) or succeed (`hold*`) instead of failing `ENOTSUP`. `Socket.Internal` also exports
    `toAddress` (the §3.2 fallback parse), `connectTimeoutMs`, `keepAliveSeconds`, `tcpConnectArgs`,
    `tcpListenArgs`, so `Socket.Tls` packs its arguments without importing `Socket.Address`.
    `keepAlive = Just n` with `n <= 1000` (including 0 and negatives) is 1 s. Negative Unix
    `permissions` are sent as -1 (none). `connectToHost` builds its empty-lookup `ENOTFOUND` in Elm.
- 2026-10-07 — **S2 done** (`worktrees/p11b`, merged). `Core/IoReactor.{hpp,cpp}` (epoll+eventfd;
  kqueue under `__APPLE__`, compile-checked against a stub header only; WIN32 stub),
  `Core/SocketUtil.{hpp,cpp}`, `HttpServerService.cpp` on the shared helpers (accept4/socket
  cloexec fallbacks moved), core unit tests. Results: core test 1445 checks / 0 failures, under the
  validate tree 1450 / 0; Http tests 18/18; `full` green. The idle-hangup test saw 0 loop iterations
  in 200 ms.
  - Deviations: `setInterest` returns `int` (0 or errno: `epoll_ctl`/`kevent` can fail; callers fail
    the operation); `EPOLLRDHUP` is **not requested** (it stays raised after FIN and would spin a
    write-only waiter; FIN still appears as readable); events are also filtered by the slot's
    current interest; `add(h, -1)` makes a timer-only handler; `quiesce(ms)` is irreversible and
    parks the reactor; `closeAll` relies on each handler's `onCloseAll` removing and closing itself;
    `unixSockaddr("")` → `ENOENT`, unknown/empty scope or a scope on IPv4 → `EINVAL`. Extra API:
    `onReactorThread()`, `loopIterations()`, `injectEventForTest`, `socketCloexec`,
    `acceptCloexec`, `SockAddr`, `inetToSockaddr`/`sockaddrToInet`, `unixSockaddr`,
    `mapIPv4ToIPv6`, `gaiCode`.
  - Note for S3: the `SocketEvent` drain must bind `Scheduler::instance()` on the main thread (as
    `SignalService`/`HttpServerService`); the reactor thread never calls it.
- 2026-10-07 — **S3 done** (`worktrees/p11c`). `Socket/{SocketEvents,Conn,ConnChannel,Listener,
  SocketTables}.{hpp,cpp}`, real `Socket.cpp`/`SocketExports.cpp` bodies (all B.1 rows; T7 kill
  handles on connect/accept/lookup), the `"Socket"` manager delivering per §3.4, 17 E2E tests
  (`SocketTestHelp.elm` + 16 programs) and `stress-elm/src/EcoSystemSocket.elm`. Results: native
  eco-system 98/98, validate tree 98/98, stress `-n 10` under validate green, core test 1445/0,
  root-bound and kernel-homes ok; unfiltered `build/test/test` 2257/2257 (`full` not run: JS e2e waits for S6).
  - Deviations: embed stop needed a hook mechanism: `Scheduler::addStopHook` (runtime), run on the
    eco thread when `runEventLoop` exits on a stop request; `ensureSocketEvents` registers
    `IoReactor::closeAll`. `SocketEvent` gained `gen` (heap generation; a dead heap's events only
    release OS resources) and `isUnix`; `Transport` gained `errNo` and `info(TlsInfo&)`.
    `requestSocketWork(fn)` runs deferred main-thread work from the socket drain (held FIFOs after
    `onEffects`). A finite listener credit is reserved at accept and returned if the handshake
    fails. `setNoDelay`/`setKeepAlive` on a closed connection succeed (Node). Unnamed Unix
    endpoints are `Path.empty` (printed `.`). `SocketSmokeTest` now exercises the real kernels
    (`lookup ""` → `ENOTFOUND`, refused connect on `ECO_TEST_PORT`), so it fails on JS until S6.
  - Notes for S4/S5: see the API notes in `Socket/*.hpp`; TLS plugs in via `TransportFactory`
    (`socketStartConnect`, `completeListen`), `ConnEntry::tls/isTls` feed `Tls.info`; UDP adds
    `setSocketEventDispatch(Datagram/UdpClosed)` and a `UdpEntry` table beside `SocketTables`.
- 2026-10-08 — **S4 done** (`worktrees/p11d`). `Socket/Udp.{hpp,cpp}` (`UdpHandler` on the reactor,
  `udpBindOn` on the pool, the generation-keyed `UdpTables`, the Datagram/UdpClosed dispatchers, the
  B.2 bodies), real `UdpExports.cpp`, the `"Socket.Udp"` manager delivering per §3.4
  (`UdpManager.cpp`: `udpManagerHasSubscribers`/`udpManagerDeliver`, `onEffects` →
  `udpTablesSyncSubscriptions`), `Udp.cpp` in `system-kernel-cpp/CMakeLists.txt`. `Socket/Udp.elm`
  needed no change. Tests: `SocketUdpTestHelp.elm` + 8 programs (`SocketUdp{Echo,ReceiveTask,Both,
  Large,Broadcast,Ipv6,Close,Multicast}Test`), none SKIP-JS; a UDP burst in
  `stress-elm/src/EcoSystemSocket.elm` (`numLoops` waves of 100 parked receives + 100 datagrams up to
  4 KiB, every one checked). Results: `build/test/test --filter eco-system/Socket` 26/26
  (`/tmp/eco-p11d-socket1.txt`); unfiltered `--filter eco-system` 105/106
  (`/tmp/eco-p11d-ecosystem.txt`: only `SignalInterruptTest` failed with empty output, then passed
  alone, `/tmp/eco-p11d-signal.txt`; it is flaky in the full run and not socket-related); validate tree
  `eco-system/Socket` 26/26 (`/tmp/eco-p11d-validate.txt`); stress `-n 10` under validate green
  (`/tmp/eco-p11d-stress.txt`); root-bound and kernel-homes ok. `full` not run (JS waits for S6). On
  this container IPv6 is available: `SocketUdpIpv6Test` printed `ipv6: ok` and `v4 from v6 socket: ok
  from 127.0.0.1 reply mapped True unmapped 127.0.0.1`.
  - Deviations / decisions the plan left open: `send`, `receive` and `join/leaveMulticast` on a
    closed (or unknown) socket fail `ECANCELED` (messages `send ECANCELED addr:port`, `receive
    ECANCELED`, `addMembership ECANCELED`); queued sends still in the reactor when the socket closes
    fail the same way. Other messages follow Node: `bind <CODE> addr:port`, `send <CODE> addr:port`,
    `addMembership <CODE>` / `dropMembership <CODE>`. An unparsable destination fails `EINVAL`. The
    bind result owns its fd through its own RAII type (`UdpBindResult`, not `ListenFd`). Buffer sizes
    are only ever raised to 65 536 (Linux's defaults are larger). As with listeners, a finite credit
    is consumed by every datagram read even while subscribed. `recvmsg` retries `EINTR` and queued
    ICMP errors (`ECONNREFUSED`, `ECONNRESET`, `EHOSTUNREACH`, `ENETUNREACH`); anything else backs off
    100 ms. IPv6 membership: the interface index is the interface address's scope, else the group's
    own scope, else 0; an IPv4 group with an IPv6 interface (or vice versa) fails `EINVAL`.
    `udpClose` drops held datagrams and fails parked receives in the body; the socket's count is
    released by the `UdpClosed` drain. The UDP table lives in `Udp.cpp` (`udpTables()`), not in
    `SocketTables`; it reuses SocketTables' OpDone dispatcher.
  - Problem found (pre-existing, from S3): `runtime/src/platform/Scheduler.cpp` changed
    (`addStopHook`) but `compiler/src/Compiler/MonoSolver/kernel-license-manifest.txt` still pins the
    old hash for `Scheduler.andThen/fail/kill…`, so the default ALL build fails at
    `kernel-license-manifest.stamp` (also in the merged `/work` tree). It needs the LSS_022 re-audit
    (`check-kernel-license-manifest.sh . --update` + `audited:` dates); S4 built with `-- -k 0` and
    did not touch it.
  - Notes for S6 (behaviour the tests check): sender endpoint == the other socket's
    `localEndpoint` (`127.0.0.1 <port>`, `::1 <port>`); a datagram sent before any receive is held and
    served in order; parked receive beats the subscription; 65 507 bytes arrive whole and 65 508 fail
    `EMSGSIZE`; `127.255.255.255` without `broadcast` → `EACCES` (`errorIsPermissionDenied`), with it
    ok; IPv4 destination on an `any IPv6` socket arrives from `127.0.0.1` and the reply comes back
    IPv4-mapped; IPv6 destination on an IPv4 socket → `EAFNOSUPPORT`; close fails a parked receive
    `ECANCELED`, `close` twice is fine, `receive`/`send` after close → `ECANCELED`, the program then
    exits; multicast `239.255.0.1` on `Just 127.0.0.1` join/leave ok, leaving again →
    `EADDRNOTAVAIL`.
- 2026-10-08 — **S6a done** (JS target, TCP/Unix/lookup half; `worktrees/p11f`). `Stream.js`:
  `_Stream_nodeDuplexChannels(socket, options)` (`{ read, write, abort, reset }`, documented above
  the function; `_Stream_describeError` already honoured `reason`, unchanged). `Socket.js`: every
  B.1 kernel on `node:net`/`node:dns`/`node:fs`, the §3.4 delivery rule in JS tables (parked
  accepts, manager listener, held FIFO), `attachConnectionListener`/`holdConnection`; the real Elm
  manager body of `Socket` (`MySub` unchanged; same shape as `Http.Server`'s). UDP kernels and
  `Tls.js` are still the S0 stubs. Results: JS `run-js-e2e` filtered to Socket 16/16 + 2 SKIP-JS
  (`/tmp/eco-p11f-js-socket.txt`); whole JS suite 96/96 + 2 skipped (`/tmp/eco-p11f-js-all.txt`);
  native eco-system 97/98 in one run (`/tmp/eco-p11f-native.txt`): `SignalInterruptTest` (no
  socket code) had empty output at load average 24 and passed when re-run alone
  (`/tmp/eco-p11f-native-signal.txt`). All socket tests passed natively, so the Elm manager body needs no new native symbol.
  - Deviations (JS vs native):
    - **Idle connections are `unref`'d**: the duplex refs the socket only while a read, write or
      write-close is pending, so an idle connection does not keep the program alive (native: no
      `pendingAsync` count, §3.3.8). Node keeps reading into its own buffer (up to its
      high-water mark) while the program is not reading; native leaves the data in the kernel.
    - **`closeListener` completes on the next turn after `server.close()`**, not on `'close'`:
      Node frees the port and unlinks the Unix path when the listening handle closes, but its
      `'close'` event also waits for every accepted connection to end.
    - **Unix `permissions`**: `chmod` runs after Node's bind+listen (Node has no hook between
      them), before the task succeeds; a client could connect in that window.
    - **Read-side abandon**: after the read face is shut down before EOF, the final close
      discards incoming data for up to 2 s (as native), with an unref'd timer.
    - `peerCredentials`: `ENOTSUP` on a Unix connection, `EINVAL` on others (as native and
      Appendix A; Appendix E says only `ENOTSUP`). `tcpListen` with an address Node's `isIP`
      rejects fails `EINVAL` before listening. Lookup maps Node's codes: `EAI_NONAME`/
      `EAI_NODATA` → `ENOTFOUND`, `EAI_MEMORY` → `ENOMEM`, other `EAI_*` → `EAI_FAIL`; Node
      gives no errno for `EAI_SYSTEM`.
    - A socket error fails later reads and writes with `read <CODE>` / `write <CODE>`,
      whichever direction saw it first (Node destroys the socket on any error); native
      reports each direction's own syscall result.
    - Connect-time `noDelay`/`keepAlive` are applied on `'connect'`.
  - Notes for S6b (UDP + TLS): the duplex takes `options.raw` (the `net.Socket` under a
    `TLSSocket`), which is used for `reset` (`resetAndDestroy`) and destroyed with the TLS socket. A client TLS
    socket should be created as Appendix E says (its own `net.Socket`, `pause()`d before
    connect, `{ socket }` to `tls.connect`); materialize with `_Socket_materialize` after
    `'secureConnect'`. Check that `ref`/`unref` and `pause`/`resume` on a `TLSSocket` reach the
    raw socket. For the TLS server, use `tls.createServer` with `pauseOnConnect` (the duplex pauses
    first), and route accepted sockets through `_Socket_onConnection` from `'secureConnection'`
    (failed handshakes then never reach the held FIFO, as native). `_Socket_listen` is
    generic over `net.createServer`; it needs a factory argument for TLS. UDP can copy the
    listener table pattern (`__parked`/`__listener`/`__held` with seq ordering; held max 64 with the
    oldest dropped, where listeners drop the newest).
- 2026-10-08 — **S6b (UDP part) done** (JS target; `worktrees/p11g`). `Socket.js`: every B.2 kernel on
  `node:dgram` (`udpBind`, `udpSend`, `udpReceive`, `udpClose`, `udpMembership`), the §3.4 delivery
  rule in a JS socket table (`__parked`/`__listener`/`__held`, arrival seq kept in a `WeakMap` on
  the DgramT so the tuple is unchanged), `attachMessageListener`/`holdDatagram`; the S0
  `notImplemented` helper is gone (Tls.js has its own). The real Elm manager body of `Socket.Udp`
  (`MySub` unchanged; the same shape as `Socket`'s, with `Dict`/`Process` imports). Results: JS
  `run-js-e2e` filtered to `eco-system/SocketUdp` 8/8, none skipped (`/tmp/eco-p11g-js-udp.txt`;
  `SocketUdpIpv6Test` printed `ipv6: ok` and `v4 from v6 socket: ok from 127.0.0.1 reply mapped True
  unmapped 127.0.0.1`); whole JS suite 104/104 + 2 SKIP-JS (`/tmp/eco-p11g-js-all.txt`; no TLS
  tests exist in this tree yet); native `build/test/test --filter eco-system/Socket` 26/26
  (`/tmp/eco-p11g-native-socket.txt`), so the Elm manager body needs no native symbol.
  - Codes and messages as native: `bind <CODE> addr:port`, `send <CODE> addr:port`,
    `addMembership <CODE>`/`dropMembership <CODE>`, `receive ECANCELED`; an unparsable bind or send
    address fails `EINVAL` before Node is called; operations on a closed socket fail `ECANCELED`;
    sends still in flight when the socket closes fail `ECANCELED` (Node's later callback is
    ignored). Node already gives native's `EMSGSIZE` (65 508 bytes), `EACCES` (broadcast without
    `setBroadcast`) and `EADDRNOTAVAIL` (leaving twice).
  - Deviations (JS vs native):
    - **IPv6 destination on a `udp4` socket**: Node fails `EINVAL`; the kernel checks the family
      first and fails `EAFNOSUPPORT` (native's code, §D.4).
    - **Buffer sizes** are raised to 65 536 after the bind with `set{Send,Recv}BufferSize`, only
      when lower (as native). Appendix E's `createSocket({ sendBufferSize: 65536, recvBufferSize:
      65536 })` would *lower* Linux's default (212 992 here).
    - **`ipv6Only = False`** leaves the system default (Node/libuv sets `IPV6_V6ONLY` only when
      asked; native sets it to 0 explicitly): differs only where `net.ipv6.bindv6only = 1`.
    - **Node reads eagerly**: datagrams with no consumer go to the held FIFO (max 64, oldest dropped)
      at once; native leaves them in the kernel buffer while no credit is outstanding.
    - **Keep-alive**: a bound `dgram` socket stays ref'd until `udpClose` (Node then closes the fd at
      once), matching native's bound-socket `pendingAsync` count; the manager's listener binding
      holds nothing.
    - **Membership** is synchronous in Node (native: an R-mode reactor round trip). IPv6: the
      interface is passed as `"::%<scope>"` (the interface address's scope, else the group's, else
      none, as native); a decimal scope is mapped to an interface name through
      `os.networkInterfaces()` `scopeid` (libuv resolves only names), else passed through. A group
      and interface of different families fail `EINVAL` (as native).
    - A datagram truncated by the receive buffer is not detectable in Node (native drops
      `MSG_TRUNC`); unreachable at ≤ 65 507 bytes over IPv4.
- 2026-10-08 — **S5 done** (`worktrees/p11e`). `Tls/{TlsContext,TlsTransport,Tls,TlsExports}.{hpp,cpp}`
  (B.3 for real), `Conn` drives pending transport output, `test/eco-system/scripts/gen-tls-fixtures.sh`
  → `TlsFixtures.elm` (EC P-256; CA, server, expired via `openssl ca -startdate/-enddate`,
  self-signed), `SocketTlsHelp.elm` and 7 E2E programs: the five of §4 S5 plus
  `SocketTlsTimeoutTest` (the connect timeout covers the handshake: a silent plain server →
  `ETIMEDOUT`) and `SocketTlsBulkTest` (8 MiB to a late reader, then `cancelWritable`: the
  write-face shutdown's `close_notify` + FIN). `Socket/Tls.elm` needed no change. Results: native
  `eco-system/Socket` 25/25; `eco-system` 104/105 (the one failure, `SignalInterruptTest` with
  empty output while other trees were building, passes alone); validate tree
  (`ECO_NURSERY_POISON=1`, gc-pressure config) `eco-system/SocketTls` 7/7; AOT
  (`TEST_FILTER=eco-system/SocketTls run-aot-e2e`) 7/7, so `EcoSystem_Tls` links through the
  native driver unchanged; root-bound and kernel-homes ok. JS e2e not run (S6).
  - Transport additions (`Conn.hpp`): `hasPendingWrite()` / `flush()`. TLS output the socket did
    not take (records behind a completed write, `close_notify`, the SHUT_WR after it) keeps write
    interest in every phase and is flushed when writable; the final close waits for it in
    `Draining` (with the N8 discard, same 2 s timer). So a `shutdownWrite` returning 1 — from
    `closeWritable` or from a write-face shutdown, which still calls it once — completes without
    further requests. Plain transports are unchanged (no pending output).
  - Connect is two bindings: the pool completion parks `{ConnectSpec, TlsClientConfig}` in a
    main-thread table (heap-generation keyed) and returns `makeAsyncBinding<stage2>(id)`; the drain
    resumes with it, the scheduler steps into it and installs `socketStartConnect`'s kill handle.
    Stage 1's kill handle is `SysWorkPool::cancel`. Listen is one pool job (context, then
    `tcpListenOn`) completed by `completeListen(…, tlsServerFactory)`.
  - Deviations: servers send **no TLS 1.3 session tickets** (`SSL_CTX_set_num_tickets(0)`: no
    resumption in v1, and unread tickets would turn a client's `close` into RST); TLS 1.2 minimum
    (Node's default); `SSL_OP_NO_COMPRESSION`; factories never return null (a failed `SSL_new`
    gives a transport whose handshake fails, so TLS never falls back to plain); `info` on a
    connection whose two streams are finished fails `EINVAL` (its `ConnEntry` is gone: call it
    early); bad PEM / ALPN lists: `ERR_SSL_<REASON>` from the PEM/X509 error (e.g.
    `ERR_SSL_NO_START_LINE`; Node says `ERR_OSSL_PEM_*`), an ALPN name of 0 or > 255 bytes
    `EINVAL`; handshake EOF/reset → `ECONNRESET` "Client network socket disconnected before secure
    TLS connection was established" (Node's text); the altname message is shortened.
  - Observed: `shutdownWrite` returning 1 is practically unreachable on loopback (epoll reports
    writable only with ≥ 1/3 of the send buffer free, and the transport holds ≤ 64 KiB + record
    overhead), so `SocketTlsBulkTest` exercises the pending-output path of writes, not that branch.
  - The build tree's default graph stops at `kernel-license-manifest.stamp`: S3's
    `Scheduler::addStopHook` changed `runtime/src/platform/Scheduler.cpp`, whose hash the LSS_022
    manifest pins for six `Scheduler.*` rows (also on `/work`). Needs a re-audit +
    `check-kernel-license-manifest.sh --update` before `full`; S5 built with `-k 0` and targets.
  - Notes for S6 (JS): the tests CHECK these exact strings — `CERT_HAS_EXPIRED`,
    `DEPTH_ZERO_SELF_SIGNED_CERT`, `ERR_TLS_CERT_ALTNAME_INVALID` (all `certificate-invalid True`),
    `{{(UNABLE_TO_GET_ISSUER_CERT_LOCALLY|UNABLE_TO_VERIFY_LEAF_SIGNATURE)}}` for the system store,
    `{{ERR_SSL_TLSV1_ALERT_NO_APPLICATION_PROTOCOL}}` (`certificate-invalid False`), `ETIMEDOUT`,
    `EINVAL` from `info` on plain TCP (both ends), protocol `TLSv1.3` on both ends, ALPN
    `http/1.1` / `none`, `cipher named: True` (non-empty and equal on both ends), `Cancelled: {{read
    ECONNRESET}}` / `{{write (EPIPE|ECONNRESET)}}` after `reset`; ALPN selection is server
    preference (server `["http/1.1","h2"]`, client `["h2","http/1.1"]` → `http/1.1`).
- 2026-10-08 — **S6c done** (JS target, TLS part; `worktrees/p11h`). `Tls.js`: every B.3 kernel on
  `node:tls` (Appendix E TLS bullet, rewritten to match). `Socket.js`: `_Socket_materialize` takes an
  `extra` (`{ raw, tlsInfo }`: the duplex's `options.raw` and the entry's handshake info);
  `_Socket_listen` takes a server factory (`_Socket_plainServer` by default; it may set
  `L.abortPending`, called by `closeListener`); `_Socket_tcpListenWith(callback, target, settings,
  factory)` is the shared TCP listen; `_Socket_onConnection(L, socket, extra)`. `Stream.js`
  unchanged (the S6a duplex already took `options.raw`; `ref`/`unref`/`pause`/`resume` on the
  `TLSSocket` reach the TCP handle because the raw socket is connected before `tls.connect`).
  Results: JS `run-js-e2e` filtered to `eco-system/SocketTls` 7/7, none skipped
  (`/tmp/eco-p11h-js-tls3.txt`, and `/tmp/eco-p11h-js-tls4.txt` after a final comment-only edit; iterations 1–2 failed as below, `/tmp/eco-p11h-js-tls{1,2}.txt`);
  whole JS suite 111/111 + the 2 Appendix E SKIP-JS (`/tmp/eco-p11h-js-all.txt`); native
  `build/test/test --filter eco-system/Socket` 33/33 (`/tmp/eco-p11h-native-socket.txt`; no native
  code changed).
  - Problems found on the way (now in Appendix E): `tls.Server` ignores `secureContext` (every
    handshake failed with `ERR_SSL_SSL/TLS_ALERT_HANDSHAKE_FAILURE`); double-underscore field names
    are shortened **per kernel file**, so `{ __local, __remote }` from `Socket.js` read as
    `undefined` in `Tls.js` (cross-file objects now use plain names); a client `destroy()` right
    after `'secureConnect'` drops the TLS 1.3 client `Finished` still queued in `TLSWrap`, so the
    server never emits `'secureConnection'` (tryCase's `accept` would hang) — the connect task now
    succeeds only after an empty write's callback (which waits for that output).
  - Deviations (JS vs native):
    - **Session tickets:** Node servers send TLS 1.3 tickets (native: none). Probed: a Node client
      closing without reading still sends FIN, not RST (TLSWrap consumes them), so no visible
      effect between JS peers.
    - **Server handshakes:** Node handshakes every accepted connection at once (no credit, no cap
      of 64); a handshake in progress holds the program alive (ref'd). Handshake timeout: Node's
      `handshakeTimeout` (120 s, same value).
    - **Messages:** Node's own texts. OpenSSL errors carry Node's prefix and source location
      (`C0…:error:0A000460:SSL routines:ssl3_read_bytes:tlsv1 alert no application protocol:
      ../deps/openssl/…:918:SSL alert number 120`; native `error:0A000460:SSL routines::…`); the
      altname message is Node's full text. Codes match (§D.5).
    - **Listen-time errors:** the certificate is checked with `crypto.X509Certificate`, the key
      with `createPrivateKey`, the pair with `createSecureContext` (labels `certificateChain:` /
      `privateKey:` as native). A garbage key gives `ERR_SSL_UNSUPPORTED` (OpenSSL 3 DECODER
      reason); native's code for that case was not compared. Node accepts an empty or garbage `ca`
      silently; JS fails it `ERR_SSL_NO_CERTIFICATES` as native.
    - **SSL_CERT_FILE** alone: native and JS load only that file; `SSL_CERT_DIR` alone: JS relies on
      `tls.getCACertificates('system')` honouring it (it does, OpenSSL's env semantics).
    - IP-literal detection is Node's `net.isIP` (native: `a2i_IPADDRESS`); they may differ on
      scoped IPv6 literals.

- 2026-10-08 — **S7 done** (lead, in `/work`). Examples `examples/system/src/{TcpEcho,UdpEcho,TlsGet}.elm`
  (built as AOT binaries with `eco-boot-native` and run: TCP and UDP echo checked with Python
  clients; `TlsGet example.com` prints `HTTP/1.1 200 OK`, `TlsGet expired.badssl.com` exits 1 with
  `CERT_HAS_EXPIRED`); `docs/getting-started.md` sockets bullet; README module list and status;
  `design_docs/invariants.csv` `SYS_004`.
  - **Compiler bug found by `TlsGet`:** the native backend decoded the `\r` escape in string literals
    as a backslash and an `r` (JS was right), so every `"\r\n"` HTTP request was malformed (400).
    Fixed in `Mlir/Bytecode/StringTable.elm` (`unescapeStringSlow`: `\r` → U+000D) and
    `Mlir/Pretty.elm` (`convertUnicodeEscapesToUtf8`: `\r` → MLIR `\0D`); regression test
    `test/elm-core/src/StringEscapeCrTest.elm` (JIT and AOT pass).
  - **`SignalInterruptTest` flake fixed** (`worktrees/p11i`): under load a SIGINT that had reached
    the handler could be lost because the event loop exited as quiescent before the signal reader
    thread posted it (signal subscriptions hold no `pendingAsync`). `Scheduler::runEventLoop` now
    polls the async sources' `ready()` before treating the loop as quiescent, and `SignalService`'s
    ready check drains the self-pipe (and on Linux pending subscribed signals) on the main thread.
    40/40 under load (was 3/24 failing). Scheduler rows re-audited (LSS_022). Recorded in
    `plans/eco-system-library.md` §10.
  - **Gates:** `full` green (native 2273/2273, JS eco-system 111/111 with the 2 Appendix E skips,
    core 1445 checks), `/tmp/eco-sock-full.txt`.
  - **Validate tree** (`ECO_NURSERY_POISON=1`, gc-pressure heap config): eco-system 113/113, no
    STALE or poison reports (`/tmp/eco-sock-validate.txt`). **AOT** `run-aot-e2e` `TEST_FILTER=eco-`:
    127/127 (`/tmp/eco-sock-aot.txt`). Root-bound check, kernel homes, elm-tests, docs (six Socket
    modules, no `Debug.todo`) ok.
  - **Stress under validate:** `EcoSystemSocket` passes; `EcoSystemTransformChain` (base plan,
    in-memory streams, no sockets) now exceeds the harness's fixed 60 s at `-n 10` (n=4 14 s, n=6
    41 s; normal build 3 s at n=10). All samples are in the validator's O(list-length)
    duplicate-push scan in `OldGenSpace::pushSpanOnFreeLists` (`ECO_HEAP_VALIDATE`); allocator and
    stream code are unchanged since it last passed (2026-10-07 19:28), so the cause is the heap's
    free-list shape on this run, not socket code. With the allocator's own knob
    `ECO_VALIDATE_FREELIST_DUP_SCAN=0` (every other validator check stays on) stress `EcoSystem`
    `-n 10` is 10/10 (`/tmp/eco-sock-stress2.txt`); with the scan on, TransformChain passes at `-n 6`.

---

## Appendix A — Public API (normative)

```elm
module Socket.Address exposing
    ( Address, Family(..), Endpoint(..), InetEndpoint
    , fromString, toString, fromOctets, toOctets
    , family, loopback, any, isLoopback, isUnspecified, isIPv4Mapped, unmapIPv4
    )

type Address
type Family = IPv4 | IPv6
type Endpoint = Inet InetEndpoint | Unix Path            -- Path: System.File.Path; Unix "" = unnamed
type alias InetEndpoint = { address : Address, port_ : Int }

fromString : String -> Maybe Address
toString : Address -> String
fromOctets : List Int -> Maybe Address                   -- 4 or 16 values, each 0–255; no scope
toOctets : Address -> List Int
family : Address -> Family
loopback : Family -> Address
any : Family -> Address
isLoopback : Address -> Bool
isUnspecified : Address -> Bool
isIPv4Mapped : Address -> Bool
unmapIPv4 : Address -> Address
```

```elm
effect module Socket where { subscription = MySub } exposing
    ( Connection, readable, writable, localEndpoint, remoteEndpoint, close, reset
    , Listener, listenerEndpoint, accept, onConnection, closeListener
    , lookup
    , Error, errorCode, errorToString
    , errorIsConnectionRefused, errorIsConnectionReset, errorIsTimedOut, errorIsAddressInUse
    , errorIsAddressNotAvailable, errorIsHostNotFound, errorIsPermissionDenied, errorIsCancelled
    , errorIsCertificateInvalid
    )

type alias Connection = Internal.Connection
readable : Connection -> Stream.Readable Bytes
writable : Connection -> Stream.Writable Bytes
localEndpoint : Connection -> Endpoint
remoteEndpoint : Connection -> Endpoint
close : Connection -> Task x ()
reset : Connection -> Task x ()

type alias Listener = Internal.Listener
listenerEndpoint : Listener -> Endpoint
accept : Listener -> Task Error Connection
onConnection : Listener -> (Connection -> msg) -> Sub msg
closeListener : Listener -> Task Error ()

lookup : String -> Task Error (List Address)

type alias Error = Internal.Error
errorCode : Error -> String
errorToString : Error -> String                          -- code ++ ": " ++ message
errorIsConnectionRefused : Error -> Bool                 -- ECONNREFUSED
errorIsConnectionReset : Error -> Bool                   -- ECONNRESET, EPIPE
errorIsTimedOut : Error -> Bool                          -- ETIMEDOUT
errorIsAddressInUse : Error -> Bool                      -- EADDRINUSE
errorIsAddressNotAvailable : Error -> Bool               -- EADDRNOTAVAIL, EAFNOSUPPORT
errorIsHostNotFound : Error -> Bool                      -- ENOTFOUND, EAI_AGAIN, EAI_FAIL
errorIsPermissionDenied : Error -> Bool                  -- EACCES, EPERM
errorIsCancelled : Error -> Bool                         -- ECANCELED
errorIsCertificateInvalid : Error -> Bool                -- §D.5 certificate codes
```

Doc comments state: a connection holds resources until closed or read to the end (R4); one
subscription per listener (R5); qualified imports are recommended (`close`, `localEndpoint` exist in
several modules).

```elm
module Socket.Tcp exposing
    ( ConnectOptions, defaultConnectOptions, connect, connectToHost
    , ListenOptions, defaultListenOptions, listen
    , setNoDelay, setKeepAlive
    )

type alias ConnectOptions =
    { address : Address, port_ : Int
    , timeout : Maybe Int        -- ms until connected (TLS: and handshaken); Just n with n <= 0 = Nothing
    , noDelay : Bool             -- default False
    , keepAlive : Maybe Int      -- idle ms, rounded up to whole seconds, minimum 1 s; default Nothing
    }
defaultConnectOptions : Address -> Int -> ConnectOptions
connect : ConnectOptions -> Task Socket.Error Socket.Connection
connectToHost : String -> Int -> Task Socket.Error Socket.Connection

type alias ListenOptions =
    { address : Address, port_ : Int
    , backlog : Int              -- default 511
    , ipv6Only : Bool            -- default False
    }
defaultListenOptions : Address -> Int -> ListenOptions
listen : ListenOptions -> Task Socket.Error Socket.Listener

setNoDelay : Bool -> Socket.Connection -> Task Socket.Error ()          -- Unix: succeeds, no effect
setKeepAlive : Maybe Int -> Socket.Connection -> Task Socket.Error ()   -- Unix: succeeds, no effect
```

```elm
module Socket.Unix exposing
    ( connect, ListenOptions, defaultListenOptions, listen, peerCredentials )

connect : Path -> Task Socket.Error Socket.Connection
type alias ListenOptions =
    { path : Path
    , removeExisting : Bool      -- default False; removes only an existing socket
    , permissions : Maybe Int    -- numeric mode (0o600 is 384); default Nothing
    }
defaultListenOptions : Path -> ListenOptions
listen : ListenOptions -> Task Socket.Error Socket.Listener
peerCredentials : Socket.Connection -> Task Socket.Error { pid : Int, uid : Int, gid : Int }  -- non-Unix: EINVAL
```

```elm
effect module Socket.Udp where { subscription = MySub } exposing
    ( Socket, Datagram, BindOptions, defaultBindOptions, bind, localEndpoint
    , send, receive, onMessage, close
    , joinMulticast, leaveMulticast
    )

type alias Socket = Internal.UdpSocket
type alias Datagram = { data : Bytes, from : InetEndpoint }
type alias BindOptions =
    { address : Address, port_ : Int
    , reuseAddress : Bool        -- default False
    , broadcast : Bool           -- default False
    , ipv6Only : Bool            -- default False
    }
defaultBindOptions : Address -> Int -> BindOptions
bind : BindOptions -> Task Socket.Error Socket
localEndpoint : Socket -> InetEndpoint
send : InetEndpoint -> Bytes -> Socket -> Task Socket.Error ()
receive : Socket -> Task Socket.Error Datagram
onMessage : Socket -> (Datagram -> msg) -> Sub msg
close : Socket -> Task x ()
joinMulticast : Address -> Maybe Address -> Socket -> Task Socket.Error ()
    -- group, interface: IPv4 = the interface's address; IPv6 = an address whose scope names the
    -- interface (e.g. "::%lo"), the address bits being ignored
leaveMulticast : Address -> Maybe Address -> Socket -> Task Socket.Error ()
```

```elm
module Socket.Tls exposing
    ( ClientOptions, Verification(..), defaultClientOptions, connect
    , ServerOptions, listen
    , Info, info
    )

type alias ClientOptions =
    { serverName : String        -- DNS name (SNI + check) or IP literal (no SNI, IP SAN check)
    , verification : Verification
    , alpn : List String         -- default []
    }
type Verification = SystemCertificates | TrustedCertificates String | NoVerification
defaultClientOptions : String -> ClientOptions                       -- SystemCertificates, no ALPN
connect : ClientOptions -> Socket.Tcp.ConnectOptions -> Task Socket.Error Socket.Connection

type alias ServerOptions = { certificateChain : String, privateKey : String, alpn : List String }
listen : ServerOptions -> Socket.Tcp.ListenOptions -> Task Socket.Error Socket.Listener

type alias Info = { protocol : String, alpn : Maybe String, cipher : String }
info : Socket.Connection -> Task Socket.Error Info                    -- non-TLS: EINVAL
```

## Appendix B — Kernel catalogue (normative)

Wrappers are annotated in the calling module (base plan Appendix B conventions). **Modes:** S sync
binding; P SysWorkPool (T2); R reactor round trip (async binding: `incrementPendingAsync`, `submit`,
result via `SocketEvent`, the drain resumes and decrements); A parked on a table entry (no own count;
`CancelFn` returns false, §3.3.8); M manager.

### B.1 `Eco.Kernel.Socket` — stream sockets

| Kernel fn | Elm type | Mode | Notes |
|---|---|---|---|
| `lookup` | `String -> Task FErr (List String)` | P | §3.3.6 |
| `tcpConnect` | `( String, Int, Int ) -> ( Bool, Int ) -> Task FErr ConnT` | R | `(address, port, timeoutMs; 0 none)`, `(noDelay, keepAliveSec; 0 off)`; kill → abort; an orphaned success is closed |
| `unixConnect` | `String -> Task FErr ConnT` | R | |
| `tcpListen` | `( String, Int ) -> ( Int, Bool ) -> Task FErr ListenT` | P | `(address, port)`, `(backlog, ipv6Only)` |
| `unixListen` | `String -> ( Bool, Int ) -> Task FErr ListenT` | P | `(path, (removeExisting, mode; -1 none))` |
| `accept` | `Int -> Task FErr ConnT` | A | held first (§3.4); closed listener → `ECANCELED` |
| `closeListener` | `Int -> Task FErr ()` | R | idempotent |
| `close` | `Int -> Task Never ()` | S | `submit` abort; returns at once |
| `reset` | `Int -> Task Never ()` | S | `submit` reset |
| `setNoDelay` | `Bool -> Int -> Task FErr ()` | R | Unix: ok, no effect |
| `setKeepAlive` | `Int -> Int -> Task FErr ()` | R | `(seconds; 0 off, connId)`; Linux `TCP_KEEPIDLE`, macOS `TCP_KEEPALIVE` |
| `peerCredentials` | `Int -> Task FErr CredT` | S | from `ConnEntry`; non-Unix `EINVAL` |
| `"Socket"` manager | — | M | C.1 |

### B.2 `Eco.Kernel.Socket` — UDP

| Kernel fn | Elm type | Mode | Notes |
|---|---|---|---|
| `udpBind` | `( String, Int ) -> ( Bool, Bool, Bool ) -> Task FErr UdpT` | P | `(reuseAddress, broadcast, ipv6Only)` |
| `udpSend` | `( String, Int ) -> Bytes -> Int -> Task FErr ()` | R | §D.4 address conversion |
| `udpReceive` | `Int -> Task FErr DgramT` | A | held first |
| `udpClose` | `Int -> Task Never ()` | S | `submit` close; parked receives fail at once |
| `udpMembership` | `Bool -> String -> String -> Int -> Task FErr ()` | R | `(join, group, interface or "", socketId)` |
| `"Socket.Udp"` manager | — | M | C.2 |

### B.3 `Eco.Kernel.Tls`

| Kernel fn | Elm type | Mode | Notes |
|---|---|---|---|
| `connect` | `( String, Int, Int ) -> ( Bool, Int ) -> ( String, ( Int, String ), List String ) -> Task FErr ConnT` | P then R | context on the pool (system context cached), then as `tcpConnect` with a TLS transport; `(serverName, (verification 0 system / 1 trusted / 2 none, pem), alpn)` |
| `listen` | `( String, Int ) -> ( Int, Bool ) -> ( String, String, List String ) -> Task FErr ListenT` | P | `(certificateChain, privateKey, alpn)`; entry in the shared listener table |
| `info` | `Int -> Task FErr InfoT` | S | from `ConnEntry`; non-TLS `EINVAL` |

## Appendix C — Effect-manager layouts (normative)

### C.1 `Socket` (key `"Socket"`)

```elm
type MySub msg
    = OnConnection Int (( Int, ( Int, Int ), ( ( Int, String, Int ), ( Int, String, Int ) ) ) -> msg)
    -- tag 0: [listenerId unboxed Int (mask 0b01), tagger boxed]; tagger argument = ConnT
```

### C.2 `Socket.Udp` (key `"Socket.Udp"`)

```elm
type MySub msg = OnMessage Int (( Bytes, ( String, Int ) ) -> msg)
    -- tag 0: [socketId unboxed Int (mask 0b01), tagger boxed]; tagger argument = DgramT
```

## Appendix D — Behaviour notes (normative)

### D.1 Addresses
- **IPv4:** four decimal fields 0–255, 1–3 digits, no leading zeros except `0` (glibc `inet_pton`,
  Node `isIP`).
- **IPv6:** RFC 4291 text: 1–4 hex digits per group (either case), at most one `::`, an optional
  trailing dotted IPv4 (counts as two groups), exactly 8 groups without `::` and at most 7 with it;
  optional scope: `%` followed by 1–15 characters from `[A-Za-z0-9_.-]` (an interface name or a
  decimal index). `fromOctets` gives no scope.
- **Printing** (`toString`): IPv4 dotted decimal. IPv6 per RFC 5952: lower case, no leading zeros,
  the longest run of **two or more** zero groups (leftmost on ties) as `::`, a single zero group
  printed `0`; **IPv4-mapped** (`::ffff:0:0/96`) printed `::ffff:a.b.c.d`; every other address
  (including the deprecated IPv4-compatible `::a.b.c.d`) in hex groups; then `%scope`.
- **Predicates:** `isLoopback` = 127.0.0.0/8, `::1`, or IPv4-mapped 127.0.0.0/8; `isUnspecified` =
  `0.0.0.0` or `::`; `isIPv4Mapped` = `::ffff:0:0/96`; `unmapIPv4` maps those to IPv4 and returns
  everything else unchanged. `loopback`/`any` give `127.0.0.1`/`::1` and `0.0.0.0`/`::`.

### D.2 Connections
- End of input is `Closed` on the readable. Errors: reads fail `Cancelled "read <CODE>"`, writes
  `Cancelled "write <CODE>"` (on Linux a write after a peer's RST may report `EPIPE` or
  `ECONNRESET`; tests CHECK `{{write (EPIPE|ECONNRESET)}}`).
- **Graceful end:** `Stream.closeWritable` completes once every queued write is in the kernel and
  FIN (TLS: `close_notify` then FIN) is sent; the program then reads to `Closed`. If the program
  cancelled its readable, the final close discards incoming data for up to 2 s first (§3.3.3).
- **`Socket.close`:** our queued writes are dropped and fail `Cancelled "socket closed"`; parked
  reads fail the same; a pending `closeWritable` completes; the fd is closed: bytes already in the
  kernel's send buffer are still delivered, then FIN — **except that Linux sends RST if unread data
  is in the receive buffer** (macOS sends FIN). Later operations on the streams fail `Cancelled
  "socket closed"`. Idempotent. TLS: no `close_notify`.
- **`Socket.reset`:** `SO_LINGER {1, 0}`, then as `close`: the kernel discards its buffers and sends
  RST; the peer's next operation fails `ECONNRESET`. Unix sockets: same as `close`.
- **`connectToHost name port`:** if `Socket.Address.fromString name` succeeds, connect to it.
  Otherwise `Socket.lookup name` (empty → `ENOTFOUND`) and try each address in order with
  `defaultConnectOptions`; the first success wins; if all fail, the **last** error. Killing the task
  kills the attempt in progress.

### D.3 Unix sockets
- A path whose UTF-8 length is ≥ `sizeof(sun_path)` (108 Linux, 104 macOS) fails `ENAMETOOLONG`
  before any syscall (both backends).
- `listen`: an existing path fails `EADDRINUSE` unless `removeExisting`, which removes it only if it
  is a socket (otherwise `EADDRINUSE`). Order: bind → chmod → listen. `closeListener` unlinks the path.
- Endpoints: the server side's local endpoint is the listen path, its remote is `Unix ""`; the
  client side's remote is the path it connected to, its local `Unix ""`. Native takes these from the
  listener/connect arguments, not from `getsockname`/`getpeername`.
- Non-blocking `connect` may return 0, or `EAGAIN` (full backlog → fails `EAGAIN`).
- `setNoDelay`/`setKeepAlive` succeed and do nothing. `peerCredentials`: Linux `SO_PEERCRED`;
  macOS `LOCAL_PEERCRED` (uid, gid) + `LOCAL_PEERPID`; captured at accept/connect.

### D.4 UDP
- An IPv4 destination on an IPv6 socket is sent to `::ffff:a.b.c.d` (an `ipv6Only` socket fails as
  the kernel reports); an IPv6 destination on an IPv4 socket fails `EAFNOSUPPORT`. Sender addresses
  are reported as the kernel gives them (`unmapIPv4` normalises).
- Datagrams up to 65 507 bytes (IPv4) are sent and received whole; larger ones fail `EMSGSIZE`.

### D.5 Error codes and messages
- errno names as the base plan (`ErrnoNames.cpp`); messages `<syscall> <CODE>` plus the address
  where Node adds one (e.g. `connect ECONNREFUSED 127.0.0.1:4000`, `getaddrinfo ENOTFOUND name`).
- TLS verification: `X509_V_ERR_CERT_HAS_EXPIRED` → `CERT_HAS_EXPIRED`;
  `X509_V_ERR_CERT_NOT_YET_VALID` → `CERT_NOT_YET_VALID`; `X509_V_ERR_DEPTH_ZERO_SELF_SIGNED_CERT` →
  `DEPTH_ZERO_SELF_SIGNED_CERT`; `X509_V_ERR_SELF_SIGNED_CERT_IN_CHAIN` →
  `SELF_SIGNED_CERT_IN_CHAIN`; `X509_V_ERR_UNABLE_TO_GET_ISSUER_CERT_LOCALLY` →
  `UNABLE_TO_GET_ISSUER_CERT_LOCALLY`; `X509_V_ERR_UNABLE_TO_VERIFY_LEAF_SIGNATURE` →
  `UNABLE_TO_VERIFY_LEAF_SIGNATURE`; `X509_V_ERR_CERT_REVOKED` → `CERT_REVOKED`;
  `X509_V_ERR_HOSTNAME_MISMATCH`/`X509_V_ERR_IP_ADDRESS_MISMATCH` → `ERR_TLS_CERT_ALTNAME_INVALID`;
  any other verify error → `CERT_VERIFY_FAILED`. `errorIsCertificateInvalid` is true for all of these.
- TLS protocol errors: `ERR_SSL_<REASON>`, from `ERR_reason_error_string` upper-cased with spaces as
  `_` (e.g. `ERR_SSL_TLSV1_ALERT_NO_APPLICATION_PROTOCOL`), as Node.

## Appendix E — JS target notes (normative for S6)

- **Duplex channel pair** (`Stream.js`, new): `_Stream_nodeDuplexChannels(socket)` returns
  `{ read, write, abort(reason), reset(reason) }` over one `net.Socket`/`TLSSocket` created with
  `allowHalfOpen: true`: read close/shutdown stops reading (pause, detach) without destroying; write
  close → `socket.end()`, completing on `'finish'`; the socket is destroyed only when both sides are
  done or on `abort`/`reset`. Errors carry `reason` (`"read ECONNRESET"`, `"socket closed"`);
  `_Stream_describeError` uses `reason` when present (SF14).
- **Accept:** `net.createServer({ allowHalfOpen: true, pauseOnConnect: true })`; Node accepts
  eagerly, so JS keeps accepted sockets in the held FIFO (bounded at the listen backlog; beyond it
  the newest is destroyed). `closeListener` destroys held sockets and completes on the server's
  `'close'`.
- **Connect timeout:** `setTimeout` + `destroy` + a synthetic `ETIMEDOUT` (Node's `timeout` option is
  an idle timeout).
- **UDP:** `dgram.createSocket({ type, reuseAddr, ipv6Only })`, buffer sizes raised to 65 536 after
  the bind only when lower (S6b: the create options would lower Linux's default); Node reads eagerly, so undelivered datagrams go to the held FIFO (max 64, oldest
  dropped). `addMembership(group, iface)`, IPv6 `iface` = `"::%<scope>"`. IPv4 destinations on a
  `udp6` socket are sent to `::ffff:a.b.c.d`.
- **Lookup:** `dns.lookup(name, { all: true, order: 'verbatim', hints: 0 })`; `""` → `ENOTFOUND`
  without calling.
- **Unix:** endpoints per §D.3 from the arguments (Node reports none); `peerCredentials` fails
  `ENOTSUP`; `setNoDelay`/`setKeepAlive` no-ops.
- **TLS:** the client creates the `net.Socket` itself (`allowHalfOpen`, paused), **connects it
  first** and then passes `{ socket }` to `tls.connect`, so the `TLSSocket` wraps its TCP handle
  (`ref`/`unref` and `pause`/`resume` reach it through `TLSWrap`'s proxied methods; an unconnected
  socket would be wrapped in a `JSStreamSocket`, where they do not) and `reset` can call the raw
  socket's `resetAndDestroy()`; server reset via `tlsSocket._parent`. One timer covers connect and
  handshake (`ETIMEDOUT`). IP literal: no `servername`, `host` = the literal (IP SAN check); DNS
  name: `servername`; `""`: no name check (native's `SSL_set1_host` is skipped). The task succeeds
  after `'secureConnect'` **and an empty write's callback** (it completes once `TLSWrap`'s pending
  output, the client `Finished`, is flushed; a `destroy()` inside `'secureConnect'` drops it and the
  server never finishes its handshake). `SystemCertificates`: the certificates of the file
  `SSL_CERT_FILE` names if set (plus `tls.getCACertificates('system')` when `SSL_CERT_DIR` is set
  too; an unreadable file gives an empty store), else `tls.getCACertificates('system')` (which
  honours `SSL_CERT_DIR`); read once per process. `TrustedCertificates`: the PEM's parseable
  certificates (none → `ERR_SSL_NO_CERTIFICATES`). Server: `tls.createServer({ cert, key,
  ALPNProtocols, allowHalfOpen, pauseOnConnect })` through the shared listener code (a server
  factory argument); `tls.Server` **ignores a `secureContext` option**, so the certificate and key
  are checked first (`X509Certificate`, `createPrivateKey`, `createSecureContext`, for native's
  listen-time errors) and passed again. Connections enter the §3.4 rule on `'secureConnection'`;
  failed handshakes are dropped (`tlsClientError`); `closeListener` destroys handshakes in
  progress. `info` captured at the handshake from `getProtocol()`, `alpnProtocol`,
  `getCipher().name`. Codes: Node's verification codes outside §D.5's list →
  `CERT_VERIFY_FAILED`; `ERR_OSSL_<LIB>_<REASON>` → `ERR_SSL_<REASON>` (from the error's
  `reason`); ALPN names checked as native (`EINVAL`).
- **Every kernel that starts IO calls `_Stream_noteActivity()`**; kernel headers import every
  double-underscore name used, comments included (base plan F14 pitfall). **Double-underscore
  field names are shortened per kernel file** (even in DEV mode), so an object written in
  `Socket.js` and read in `Tls.js` (or the reverse) must use plain property names (S6c).
- **JS-only kernels** (manager bodies): `attachConnectionListener : Int -> (ConnT -> Task Never ()) -> Task Never ()`,
  `holdConnection : Int -> ConnT -> Task Never ()`, `attachMessageListener`, `holdDatagram` (same
  shapes with `DgramT`).
- **SKIP-JS tests:** `SocketTcpTimeoutTest` (Node accepts eagerly), `SocketUnixPeerCredentialsTest`
  (no peer credentials in Node).
