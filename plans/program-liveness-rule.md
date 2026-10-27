---
status: done
updated: 2026-10-27
---

# Plan: one program-liveness rule for Eco

Status: **draft, revision 3** (2026-10-20). Not implemented.

- Revision 2 applied review 1 (M1-M9, B1-B14) and adopted decision L-REARM.
- Revision 3 applies review 2 (N1-N7 and minors 1-10) and the user decisions on Q1, on elm/* docs
  and on eco/kernel scope. It lowers every phase to file:line edits, declarations, test sources
  and gates (§10-§12).
- Dispositions of both reviews are in Appendix A.

---

## 0. Executive summary

**Rule.** A program keeps running while it waits for something it asked for: a task in
flight, or a live subscription to a non-ambient source. Opening a resource does not keep the
program running; waiting on it does. The same rule holds on native and JS, for eco/system and
elm/*. eco/kernel is compiler-internal and keeps its behaviour (§16).

**`onEmptyEventLoop` (L-REARM).** The event fires once per *arming*. One armed bit exists per
program run. It starts armed, firing clears it, and only the new `System.rearmEmptyEventLoop :
Cmd msg` sets it. New work never re-arms it.

**What changes in behaviour**

1. Listeners, HTTP servers and UDP sockets stop holding for their lifetime. They hold through
   parked accepts and receives, live subscriptions, and requests delivered but not yet
   answered.
2. Held items hold nothing: queued connections, datagrams and parked HTTP requests. They are
   items nobody has asked for yet.
3. The upgrade handshake keeps the peer's reply held across `upgradeRequest` → `accept`.
4. Waits are really withdrawn:
   - killing `Process.sleep`;
   - dropping a `Time.every` subscription;
   - `Http.cancel`, killing a request, and reusing a tracker. This aborts the curl transfer, and a
     queued request is claimed before it starts.
5. The `onEmptyEventLoop` semantics of L-REARM.
6. JS: a Detached child's `runDuration` timer holds, as it does natively (X4).

**Mechanism.**
- **Native.** A move-only `LivenessHold`, plus `HoldToken` ids. A parked binding's hold is keyed
  by its resume token. There is a per-kind debug census. Acquire and release are thread-safe.
  After the migration the raw `increment/decrementPendingAsync` become private.
- **JS.** A `Liveness.js` helper (`handle(h).hold()`, `hold()`), used by every eco/system
  kernel.

**Phases** (§10). Each is gated by `full` (which includes `run-js-e2e`), and by bootstrap where
noted.

| Phase | Content | Behaviour change |
|---|---|---|
| 1 | Hold API + census; migrate runtime, elm-kernel-cpp, eco-kernel-cpp (mechanical), PortRuntime, embed; L6 swaps | none |
| 2 | L-REARM (native, JS, Elm API, ecosyskernel, docs.json gate) | `onEmptyEventLoop` |
| 3 | Withdrawal (sleep, Time.every, elm/http abort and tracker reuse); Detached `runDuration` on JS | cancellation |
| 4 | system-kernel-cpp migration A: Core, SysWorkPool, FileSystem, ChildProcess, Stream, StreamPipe, HttpStream, Tls | none |
| 5 | system-kernel-cpp migration B: Socket, Udp, HttpServer, WebSocket; JS `Liveness.js`; WebSocket.js on it | none |
| 6 | L2 + held items + upgrade hand-over, native + JS; docs (+ ecosyskernel); raw API private | listeners/servers/UDP |
| 7 | Delete the JS Stream activity epoch | none |

---

## 1. Problem

Liveness is decided resource by resource today:

1. **Open resources disagree.**
   - A listener (`eco-system/Socket/Socket.cpp:325` → `Socket/SocketTables.cpp:182`), an HTTP
     server (`HttpServer/HttpTables.cpp:387` → `:294`) and a UDP socket (`Socket/Udp.cpp:531` →
     `:507`) hold for their lifetime.
   - An idle TCP connection holds nothing.
   - A WebSocket holds only while subscribed (`WebSocket/WsManager.cpp:208-239`).
   - A file watch holds only while subscribed (`FileSystem/FileSystemManager.cpp:152,200`).
2. **Re-arming `onEmptyEventLoop` disagrees.**
   - Native re-arms on any `incrementPendingAsync` (`runtime/src/platform/Scheduler.cpp:664-668`).
   - JS re-arms only on Stream activity (`Eco/Kernel/System.js:115-137`).
   - `System.elm:398-401` documents the split.
   - On both backends, a handler that does IO on every delivery fires forever.
3. **Cancellation disagrees.**
   - A killed native `Process.sleep` keeps its timer (`elm-kernel-cpp/src/core/ProcessExports.cpp:33-38`).
   - A dropped native `Time.every` leaves one tick in flight (`time/TimeEffectManager.cpp:114,147-158`).
   - Native `Http.cancel` and request kill never stop curl (`runtime/src/platform/HttpService.cpp:130`;
     kill handle Unit `http/HttpExports.cpp:627`). There is no default timeout (`HttpService.cpp:218`).
   - A native request queued behind another is never even looked at (single serial worker,
     `HttpService.cpp:31,300-320`).
   - A reused tracker overwrites the old one without cancelling it (`HttpExports.cpp:261-268`).
     JS kills the old request (`elm/http/2.0.0/src/Http.elm:992`).
4. **Held items pin programs.** A parked HTTP request (no `onRequest` subscriber yet) holds
   (`HttpTables.cpp:220-224`). On JS, held accepted sockets are ref'd Node sockets
   (`Eco/Kernel/Socket.js:349,459`).
5. **No shared mechanism.**
   - 85 raw `increment/decrementPendingAsync` lines.
   - About 25 `AsyncRelease` uses (`system-kernel-cpp/src/eco-system/Core/AsyncRelease.hpp`), plus
     PortRuntime's private one (`runtime/src/platform/PortRuntime.cpp:391`).
   - A WebSocket-private JS counter (`WebSocket.js:881-897`).
   - About 50 `_Stream_noteActivity` calls.
   - No invariant states which waits keep a program alive.

---

## 2. The rule (normative)

### 2.1 Defined terms

- **Hold.** One unit of liveness, owned by one kernel object for one reason, and released
  exactly once on every path. Natively it is one `pendingAsync_` count (`Scheduler.hpp:242`),
  owned through `LivenessHold` or `HoldToken` (§5.1). On JS it is one count of a
  `_Liveness_handle`/`_Liveness_hold`, or one ref'd Node handle (§5.2).
- **Task in flight.** A task whose binding has parked waiting for an external completion, until
  that completion is **published**: the resume is on the run queue (native `callClosure1` →
  enqueue; JS `callback(...)`). A killed task is no longer in flight once its kill handle has
  run, unless its operation is in X12.
- **Delivered item.** A connection, datagram, request or handshake that the kernel has handed
  to the program: as the result of an `accept`/`receive`, as a subscription's msg, or as the
  result of `upgradeRequest`. A **held item** is one the kernel has received and keeps for a
  consumer that does not exist yet.
- **Live subscription.** A `Sub` that the program's current `subscriptions` returns, whose
  source can still deliver. "Current" means as of the latest `onEffects`. By LIVE_004, effect
  dispatch completes inside the drain that ran the update.
- **Ambient source.** A source the program did not request and cannot finish: signals,
  terminal resize, the empty-loop event, incoming port messages.
- **Real work.** The run queue is non-empty, OR at least one hold exists, OR an async source
  has a ready event (`Scheduler.cpp:581-591`).
- **Empty event loop.** There is no real work.

### 2.2 Rule

> **LIVE-1.** An Eco program keeps running while it is waiting for something it asked for:
> (a) a task in flight, (b) a live subscription to a non-ambient source, or (c) a delivered
> item that is owed a reply (an HTTP request not yet answered, an upgrade handshake not yet
> accepted or rejected). Each such wait is backed by exactly one hold, acquired before the wait
> can be observed (§6.1) and released only after its result has been published (§6.2).
>
> **LIVE-2.** Opening a resource does not by itself keep the program running; only waiting on it
> does. Held items hold nothing: they wait for a consumer the program has not created.
>
> **LIVE-3.** Ambient sources never hold (§3).
>
> **LIVE-4.** When the loop is empty, the program asks the empty-loop hook once. If the hook is
> armed and at least one `onEmptyEventLoop` subscription exists, the hook is disarmed and every
> such subscription gets its msg. Otherwise the program ends. The hook starts armed, and only
> `System.rearmEmptyEventLoop` arms it again.
>
> **LIVE-5.** Withdrawing a wait releases its hold within the same scheduler turn. Withdrawing
> means killing the task, closing its resource, dropping the subscription, or answering or
> giving up the item. The only exceptions are the operations listed in X12, whose holds last
> until the operation reports. Their result is then dropped.
>
> **LIVE-6.** The rule is the same on both backends and for every public package (eco/system,
> elm/*). Only the mechanism differs (§5).

Notes.

1. **A non-Detached eco/system child holds until its exit is published** (X5). The spawn
   command promises an `onExit` msg (`ChildProcess/ChildProcess.cpp:366`), so the child is a
   task in flight. `ChildProcess` has no subscriptions.
2. **Delivered HTTP requests and handshakes** (LIVE-1c) are holds on behalf of the peer. They
   end on answer, on hand-over, or on connection loss. `closeWithin` (and `close` = `closeWithin
   5000`, `Http/Server.elm:305-307`) bounds them: at the deadline the remaining connections are
   closed (`Http1.cpp:498`), and `eraseKey` releases the hold (`HttpTables.cpp:157-170`).
   `closeWithin 0` aborts at once. There is no separate abort-on-close.
3. **A held item becomes held-for at delivery.** A parked HTTP request starts holding when it is
   delivered to a subscriber, not when it arrives. A held connection or datagram never holds;
   once delivered, it is a connection (idle connections hold nothing) or a value.
4. **A delivered item the program forgets.** An answered-never request or an accepted-never
   `Upgrade` keeps the program running until the peer disconnects. The program owes the reply,
   and the docs say so (§9).

---

## 3. Exceptions (complete list)

| # | Exception | Behaviour | Justification |
|---|---|---|---|
| X1 | `onSignalInterrupt`, `onSignalTerminate` | never hold | Ambient. Native `SystemManager.cpp:113-122`, pre-exit poll `Scheduler.cpp:581-591`; JS `System.js:142-156`. A supervisor that spawns only Detached children and waits for SIGTERM ends at once (release notes, §13). |
| X2 | `Terminal.onResize` | never holds | Ambient. Native `TerminalManager.cpp:131`; JS `Terminal.js:138-158`. |
| X3 | `onEmptyEventLoop` | never holds | It is the empty-loop event; governed by the armed bit (§7). |
| X4 | Detached child | never holds; its `runDuration` timer **does** hold until the limit or exit, on both backends | Ownership given up (native `ChildProcessManager.cpp:142`; JS unref `ChildProcess.js:424-428`). The duration timer is the program's own request to kill the child: native holds it (`ChildProcess.cpp:478`), JS unrefs it (`ChildProcess.js:418`). Phase 3 makes JS keep it ref'd. The `ChildProcess.elm:296-298` doc then loses "On the native backend". |
| X5 | Non-Detached eco/system child | holds until its exit is published | §2.2 note 1. |
| X6 | Embedded program | never ends on its own; `onEmptyEventLoop` never fires | Host lifetime hold `eco_embed.cpp:213` (released on the host thread `:323`); `Scheduler.cpp:599`. |
| X7 | Incoming port subscriptions | never hold; each queued message holds until delivered | `PortRuntime.cpp:465` → `:392`, acquired on the host thread. |
| X8 | Outgoing port sends | no hold | Synchronous or buffered (`PortRuntime.cpp:342-368`). |
| X9 | In-memory streams, `Stream.fromList` | no hold | Only the program can satisfy them. SYS_003 already says so. |
| X10 | *(withdrawn: MVar is eco/kernel, §16)* | — | — |
| X11 | `System.exit`/`exitWithCode` | ends at once | `System.cpp:283-302`. |
| X12 | Pool jobs already inside a blocking syscall: `FileSystem.*` (`FileSystem.cpp:193` → `SysWorkPool.cpp:115`), `Socket.lookup` (`Socket.cpp:358`), bind steps (`Socket.cpp:454/487`, `Udp.cpp:660`, `HttpServer.cpp:205/277`), TLS setup (`Tls.cpp:196/254`) | hold until the job reports; the result is dropped | A pool thread in `getaddrinfo`/`open`/`bind` cannot be interrupted, and each call is bounded by the OS. elm/http is **not** here: L5 makes it withdrawable, queued or running. |

Not exceptions, listed because they look like candidates:
- Terminal raw mode.
- The synchronous modules: `Debug`, `Json`, `Bytes`, `Regex`, `Url`, `Parser`, `Random`, `Time.now/here`.
- `Http.track`. A subscription with no tracked request in flight holds nothing. The request
  holds, and the progress `Sub` adds no hold of its own (user decision; §9 elm/* paragraph).
- elm/file and elm/browser. They are unsupported natively (`file/FileExports.cpp` stubs;
  `browser/Browser.cpp:91-92` `assert(false)`), and a future animation-frame sub must take a
  subscription hold.
- An idle `FileSystem.Handle`.
- An `Http.Stream` body, which holds per read.
- A never-completing binding that never registers. This is a kernel bug, caught by the §6.1
  assertion.

---

## 4. Inventory

**Now** native / JS vs **Required**. "OK" = conforms. All eco/system paths are under
`system-kernel-cpp/src/eco-system/` (C++) and `system-kernel-cpp/src/Eco/Kernel/` (JS). **Ph** is
the phase that changes the row.

### 4.1 eco/system

| API | Native now | JS now | Required | Ph |
|---|---|---|---|---|
| `onEmptyEventLoop` | re-arm on increment `Scheduler.cpp:667` | re-arm on Stream activity `System.js:119-127` | L-REARM (§7) | 2 |
| `rearmEmptyEventLoop` (new) | — | — | sets the bit | 2 |
| signals, `Terminal.onResize`, raw mode, `exit*`, `setExitCode`, `environmentVariables` | none / sync | none / sync | X1, X2, X11 | OK |
| channel `read`/`readLine`/`readUntilClosed` | `Stream.cpp:1115` → `:615` | ref'd while a request is pending `Stream.js:1360-1361,1401` | in flight | OK |
| mapped read, read-ahead | `Stream.cpp:1120` → `:124/137`; `:849`, `StreamPipe.cpp:276` → `Stream.cpp:817` | as above | in flight | OK |
| channel `write`/`enqueue`/`log*` | `Stream.cpp:1233/1250` → `:665` | Node write req | in flight | OK |
| `closeWritable` | `Stream.cpp:1324` → `:699` | close timer unref'd `Stream.js:1502-1503` | in flight | verify (Q1) |
| `cancelReadable`/`cancelWritable` | release `Stream.cpp:207-209,439-441,522-524` | rejects pending requests | same-turn release | OK (+test) |
| `pipeTo`/`pipeThrough`/`awaitAndPipeThrough` | per request `StreamPipe.cpp:97,109,230,288` | per request | in flight | OK |
| in-memory, `fromList` | none | none (`queueMicrotask` `Stream.js:687`) | X9 | OK |
| `FileSystem.*`, `Handle.*` | per job; no kill handle | libuv req | X12 | OK |
| `readFileStream`/`writeFileStream` | open = pool job; stream = channel | fs streams | per request | verify (Q3) |
| `FileSystem.watch*` | per key `FileSystemManager.cpp:200` → `:152` | `persistent:true` `FileSystem.js:936` | live sub | OK |
| `Socket.lookup`, listen/bind steps | pool | callbacks | X12 | OK |
| **listener open** | lifetime `Socket.cpp:322-325` → `SocketTables.cpp:182` | ref'd server `Socket.js:341-375` | none | 6 |
| `accept` parked | no own hold `Socket.cpp:518`; kill `SocketTables.cpp:321-333` returns false | covered by server ref `Socket.js:575-596` | hold while parked; kill releases | 6 |
| `onConnection` | none | none | sub hold per listener (`SocketTables.cpp:297-311`) | 6 |
| held connections | none (native reads only with demand, `SocketTables.cpp:94-133`) | **ref'd accepted socket** in `L.__held` `Socket.js:459` | none | 6 (JS) |
| `closeListener` | `Socket.cpp:537` → `SocketTables.cpp:189` | close cb | in flight; releases sub/accept holds | 6 |
| `connect`, `setNoDelay`/`setKeepAlive`, `close`/`reset`, idle connection | OK | OK | — | OK |
| `peerCredentials`, `Tls.info` | sync (`Socket.cpp:25,657`; `Tls.cpp:282-287`) | sync | n/a | OK |
| `Tls.connect`/`listen` | pool, then hand-off | handshake timer `Tls.js:329` | follows connect / listener rows | 6 |
| **UDP socket bound** | lifetime `Udp.cpp:528-531` → `:507` | ref'd `dgram` `Socket.js:838-857` | none | 6 |
| `Udp.receive` parked | covered; kill `Udp.cpp:621-631` | covered | hold while parked | 6 |
| `Udp.onMessage` | covered | covered | sub hold (`Udp.cpp:603-615`) | 6 |
| held datagrams | none (native reads only with demand, `Socket/Udp.elm:33-38`) | data only | none | OK once the socket is unref'd |
| `Udp.send`/`join`/`leave` | `Udp.cpp:570` | send cb | in flight | OK |
| **HTTP server open** | lifetime `HttpTables.cpp:385-387` → `onServerClosed` `:375-383` | ref'd server `HttpServer.js:1216` | none | 6 |
| `onRequest` | none | none | sub hold per server | 6 |
| request arriving unsubscribed (parked) | **counted** `HttpTables.cpp:216-224` | entry in `s.__queue`; its socket is ref'd | none until delivered | 6 |
| delivered, unanswered request | counted until `eraseKey` `HttpTables.cpp:157-170` | socket ref'd | holds (LIVE-1c) | OK native; JS 6 |
| idle keep-alive connection | none | **ref'd socket** | none | 6 (JS) |
| `send`/respond | `HttpServer.cpp:361` → `HttpTables.cpp:314`; release-then-resume `HttpServer.cpp:164-173` | write cb | publish-then-release | 1 (L6) |
| `close`/`closeWithin` | deadline abort `Http1.cpp:498` | linger timers unref'd `HttpServer.js:550,1366` | unchanged (N1) | OK |
| `upgradeRequest` → `accept`/`reject` | key released in `httpTablesTakeUpgrade` `HttpTables.cpp:432-439`; handshake id holds nothing until `WebSocket.cpp:463-465`/`:573-575` | socket ref'd? | key hold **moves** to the handshake id; released when accept/reject has its own hold, or on abandon/connection gone | 6 |
| `Http.Stream` | `HttpStream.cpp:262` → `:197` | `HttpStream.js:137,425-433` | in flight | OK |
| `WebSocket.connect`, accept/reject/ping/close/`awaitClose`, subs | `WebSocket.cpp:158,301,346,465,575,649,675,720`; `WsManager.cpp:230/231` | hold counter `WebSocket.js:881-897`; 2 raw timers `:2290,2612` | in flight / live sub | OK; JS timers 5 |
| remote close handshake | `wsTablesCloseStarted` `WsTables.cpp:311-316` | counter | in flight | OK (migrate 5) |
| `ChildProcess.run`, `spawn` | `ChildProcess.cpp:571`, `ChildProcessManager.cpp:144` | ref'd | in flight / X5 | OK |
| Detached + `runDuration` | holds (timer `ChildProcess.cpp:478`) | **unref'd** `ChildProcess.js:418` | holds (X4) | 3 (JS) |
| body throws | release then resume `Core.cpp:131-143` | n/a | publish-then-release | 1 (L6) |

### 4.2 elm/* (native `elm-kernel-cpp/src/`; JS stock `~/.eco/0.1.3/packages/elm/...`)

| API | Native now | JS now | Required | Ph |
|---|---|---|---|---|
| `Process.sleep` | `core/ProcessExports.cpp:27-38`, kill Unit | `setTimeout`/`clearTimeout` | kill cancels (§5.3) | 3 |
| `Process.spawn`/`kill` | no hold | stock | none | OK |
| `Time.every` | per tick `time/TimeEffectManager.cpp:93-115`; erase leaves the tick `:271-279` | `clearInterval` on unsub | cancel the stored tick on unsubscribe | 3 |
| `Time.now/here/getZoneName` | sync | sync | n/a | OK |
| `Http.request` (untracked) | `http/HttpExports.cpp:605-628`; kill Unit | XHR, `xhr.abort()` on kill | kill aborts (queued or running) | 3 |
| `Http.cancel` | marks `cancelled` `HttpExports.cpp:693-708`; curl continues | `xhr.abort()` | abort (queued or running) | 3 |
| tracker reuse | overwrite `HttpExports.cpp:261-268` | kills the old request `Http.elm:992` | cancel + abort the old one | 3 |
| `Http.track` | no own hold `HttpExports.cpp:349-360` | XHR events | none (closed Q1) | OK |
| sync modules | sync | sync | n/a | OK |
| elm/file, elm/browser | unsupported | stock | n/a | — |
| ports | X7/X8 | stock | X7/X8 | OK |

The JS claim (L10) for elm/http assumes a `XMLHttpRequest` that keeps a ref'd handle while
open and releases on `abort()`. That is what the E2E shim `test/scripts/js-e2e-xhr.js` does
(injected by `run-js-e2e.js:319-321`). Production Node programs supply their own.

### 4.3 eco/kernel
Out of scope (§16). The only change is the mechanical migration in phase 1.

---

## 5. Shared mechanism

### 5.1 Native API (`runtime/src/platform/Scheduler.hpp`, `Scheduler.cpp`, new `Liveness.hpp`)

New header `runtime/src/platform/Liveness.hpp` (included by `Scheduler.hpp`):

```cpp
namespace Elm::Platform {

// Why a hold exists. Census and embed activity only; holds of every kind count the same
// for liveness, except Host (not "busy", §8).
enum class HoldKind : uint8_t { Task, Subscription, Item, Host, Port };

// The id of one hold. 0 = no hold. A hold acquired by parkResume has the resume token as its
// id (bit 63 clear); a free-standing hold has bit 63 set (from its own counter), so the two
// never collide. Plain data: may be stored in a table entry and copied, but released once.
using HoldToken = uint64_t;
constexpr HoldToken kNoHold = 0;

// Owns at most one hold. Move-only. Destruction releases a still-owned hold.
// Thread-safe in the same sense as Scheduler::releaseHold.
class LivenessHold {
public:
    LivenessHold() noexcept = default;
    static LivenessHold acquire(HoldKind kind, const char* site);  // a free-standing hold
    static LivenessHold adopt(HoldToken t) noexcept;  // takes over a token's release duty
    LivenessHold(LivenessHold&& o) noexcept;           // o becomes empty
    LivenessHold& operator=(LivenessHold&& o) noexcept;  // releases own, then takes o's
    LivenessHold(const LivenessHold&) = delete;
    LivenessHold& operator=(const LivenessHold&) = delete;
    ~LivenessHold();                                    // release() if owned
    void release() noexcept;                            // idempotent
    HoldToken detach() noexcept;                        // gives up ownership, returns the token
    HoldToken token() const noexcept { return t_; }
    explicit operator bool() const noexcept { return t_ != kNoHold; }
private:
    explicit LivenessHold(HoldToken t) noexcept : t_(t) {}
    HoldToken t_ = kNoHold;
};

} // namespace Elm::Platform
```

New `Scheduler` public members (next to `incrementPendingAsync`, `Scheduler.hpp:45-46`):

```cpp
// Registers `resume` (as registerPendingResume does) and acquires a hold whose token is the
// returned resume token. Eco thread only (pendingResumes_ is eco-thread state).
u64 parkResume(HPointer resume, HoldKind kind, const char* site);

// Acquires a free-standing hold. Any thread.
HoldToken acquireHold(HoldKind kind, const char* site);

// Releases hold `t` (a resume token from parkResume, or a token from acquireHold): decrements
// pendingAsync_, then notifies eventCV_ under mutex_ (as decrementPendingAsync does today,
// Scheduler.cpp:670-677). Any thread. Debug builds abort on kNoHold, an unknown token or a
// second release, naming the acquiring site.
void releaseHold(HoldToken t);

// Debug census (ECO_LIVENESS_REPORT=1): prints live holds by kind and site.
void reportHolds(const char* why);
```

Implementation notes (`Scheduler.cpp`).

- **Counting.** `pendingAsync_` stays `std::atomic<int>`. Every acquire is
  `pendingAsync_.fetch_add(1)`.
- **Re-arm.** Until phase 2, every acquire also does `quiescenceArmed_.store(true)` (N6), so phase
  1 is behaviour-preserving. Phase 2 deletes `quiescenceArmed_`.
- **Census.** Debug and validate builds (`!NDEBUG || ECO_HEAP_VALIDATE`) keep
  `std::unordered_map<HoldToken, std::pair<HoldKind, const char*>> holds_`, guarded by a new
  `std::mutex holdsMutex_`. `holdsMutex_` is a leaf lock: never taken while holding `mutex_`, and
  never held while calling out. Release builds keep no map; `releaseHold` only decrements and
  notifies.
- **Token ids.** Free-standing ids come from `std::atomic<uint64_t> nextHoldId_{1}`, as
  `(1ull << 63) | nextHoldId_++`. Resume tokens come from the existing counter, which never sets
  bit 63.
- **Threads.** Acquire and release are safe on any thread:
  - `HoldKind::Host` is released on the host thread (`eco_embed.cpp:323`).
  - `HoldKind::Port` is acquired on the host thread (`PortRuntime.cpp:465`).
  - Helper threads never release `Task` holds. They post the token, and the eco-thread drain
    resumes, then releases.
- **Reports.** `reportHolds` is called at exit when `ECO_LIVENESS_REPORT=1`, and by a 10 s idle
  timer in `runEventLoop`'s wait. It writes to stderr.
- **Raw API.** `incrementPendingAsync`/`decrementPendingAsync` remain public until phase 6.
  Phase 6 moves them to `private:`. Their only callers are then `acquireHold`/`releaseHold`.

`AsyncRelease` (`system-kernel-cpp/src/eco-system/Core/AsyncRelease.hpp:19-32`) is replaced in
phases 4-5 by:

```cpp
// RAII release of one hold, typically the resume-keyed hold of a popped result (G10).
// `dismiss()` when ownership passes elsewhere.
class HoldRelease {
public:
    explicit HoldRelease(HoldToken t) noexcept : t_(t) {}
    ~HoldRelease() { if (t_) Scheduler::instance().releaseHold(t_); }
    void dismiss() noexcept { t_ = kNoHold; }
    HoldRelease(const HoldRelease&) = delete;
    HoldRelease& operator=(const HoldRelease&) = delete;
private:
    HoldToken t_;
};
```

`AsyncRelease` is deleted once its last user is gone (end of phase 5).

**Migration patterns** (every site; one of four shapes):

| Shape | Before | After |
|---|---|---|
| A. park | `t = s.registerPendingResume(r); s.incrementPendingAsync();` (and `counted = true;`) | `t = s.parkResume(r, HoldKind::Task, "<Module.fn>");` (keep `counted = true;`) |
| B. release keyed by resume token | `s.decrementPendingAsync();` next to `takePendingResume(t)` / after `callClosure1(resume, …)` | `s.releaseHold(t);` at the same line |
| C. RAII drain | `AsyncRelease release;` (event `ev` carries `ev.token`) / `AsyncRelease r(flag)` | `HoldRelease release(ev.token);` / `HoldRelease r(entry.hold);` |
| D. entry-owned | `bool counted` field + `incrementPendingAsync()` at creation + `AsyncRelease(entry.counted)` at erase | `HoldToken hold = kNoHold;` field; `hold = s.acquireHold(kind, site)`; `HoldRelease r(entry.hold)` |

A site that decrements without a token at hand (for example `TimeEffectManager`, whose
processing goes through `processReadyAsync`) receives it from the caller. The list per phase
is in §10.

### 5.2 JS helper (`system-kernel-cpp/src/Eco/Kernel/Liveness.js`, phase 5)

```js
/*
import Elm.Kernel.Utils exposing (Tuple0)
*/

// A Node handle (net.Server, net.Socket, dgram.Socket, http2 session socket) that is ref'd
// exactly while at least one hold on it exists. Starts unref'd: call it before or right
// after creating the handle (Node allows unref() before listen/bind).
function _Liveness_handle(h)
{
	var count = 0, reffed = true, gone = false;
	function update() {
		var want = count > 0 && !gone;
		if (want === reffed) return;
		reffed = want;
		try { if (want) h.ref(); else h.unref(); } catch (e) { /* destroyed */ }
	}
	update();
	return {
		hold: function() {               // -> release function, idempotent
			var done = false;
			count++; update();
			return function() { if (done) return; done = true; count--; update(); };
		},
		gone: function() { gone = true; update(); },   // handle closed: never ref again
		count: function() { return count; }
	};
}

// A hold not tied to one handle: one shared keep-alive interval, ref'd while any exist.
var _Liveness_freeCount = 0;
var _Liveness_timer = null;
function _Liveness_hold()
{
	var done = false;
	if (_Liveness_timer === null) {
		_Liveness_timer = setInterval(function() {}, 1 << 30);
	}
	if (_Liveness_freeCount++ === 0) _Liveness_timer.ref();
	return function() {
		if (done) return; done = true;
		if (--_Liveness_freeCount === 0) _Liveness_timer.unref();
	};
}
```

Every eco/system JS kernel imports `Eco.Kernel.Liveness exposing (handle, hold)` and uses
`__Liveness_handle`/`__Liveness_hold`. JS is single-threaded, so no locking is needed. The call
sites are listed in phases 5-6.

### 5.3 Withdrawal mechanics (native, phase 3)

**`Process.sleep` kill** (`elm-kernel-cpp/src/core/ProcessExports.cpp`). The body returns a kill
closure in place of `unit()` (`:36-38`).

```cpp
// args[0] = token (PK_Int), args[1] = ().
static void* sleepKillEval(void* args[]) {
    uint64_t token = reinterpret_cast<uint64_t>(args[0]);
    auto& s = Elm::Platform::Scheduler::instance();
    (void)s.takePendingResume(token);               // never resumes; a fired token finds Nil
    if (Elm::Platform::TimerService::instance().cancel(token))
        s.releaseHold(token);                       // we removed it: we own the release
    // else processReadyAsync pops it, finds Nil and releases (Scheduler.cpp:701-705)
    return reinterpret_cast<void*>(Export::encode(Elm::alloc::unit()));
}
```

The kill closure is built with `allocClosureK(&sleepKillEval, 2, PK_Boxed)` and
`closureCapture(p, unboxedInt(token), PK_Int)` (pattern: `system-kernel-cpp/.../Core/KillHandle.cpp:42-51`).
Exactly one release happens.

**`Time.every` unsubscribe** (`TimeEffectManager.cpp`).
- Add `uint64_t tickToken = 0;` to `IntervalState` (`:55-62`).
- `scheduleTimerTick` (`:93-115`) returns its token. Its callers store it under `g_timerMutex`
  if the generation still matches.
- In `onEffects`' erase loop (`:271-279`), collect `it->second.tickToken` into a
  `std::vector<uint64_t> toCancel` before `erase`. After the mutex is dropped, each one is
  cancelled with the same three lines as `sleepKillEval`.
- The generation check (`:147-158`) stays for a tick that already fired.

**elm/http abort** (`runtime/src/platform/HttpService.{hpp,cpp}`, `elm-kernel-cpp/src/http/HttpExports.cpp`,
`HttpEffectManager.cpp`).

```cpp
// HttpService.hpp
struct RequestControl {                       // shared by the eco thread and the worker
    enum : uint8_t { Queued, Running, AbortRequested, Aborted };
    std::atomic<uint8_t> state{Queued};
};
struct Request { ...; std::shared_ptr<RequestControl> control; };  // nullptr: not abortable (eco lane)
```

- **Worker** (`HttpService.cpp:300-320`). After popping, if `req.control`:
  `uint8_t q = Queued; if (!req.control->state.compare_exchange_strong(q, Running)) continue;`.
  That request was aborted while queued: nothing is posted, and the eco thread already released.
  `perform` gets the control. `xferInfoCb` (`:110-131`) returns 1 when
  `state.load() == AbortRequested`. That yields `CURLE_ABORTED_BY_CALLBACK`, mapped to
  `ErrorKind::NetworkError`, and the result is posted as usual.
- **Eco thread** (`HttpExports.cpp`). There is a map
  `std::unordered_map<uint64_t, std::shared_ptr<RequestControl>> g_httpControl`, guarded by
  `g_trackedMutex`. The binding (`:605-628`) inserts it, and `httpDrain` (`:395-411`) erases it.
  ```cpp
  // Aborts request `token`. True iff it was still queued and is now claimed: the caller then
  // owns the release (the worker posts nothing for it). False: it is running or done, and its
  // result reaches httpDrain, which drops it (cancelled or Nil resume) and releases.
  bool httpAbort(uint64_t token);
  ```
  It does a CAS from `Queued` to `Aborted`. On failure, it does a CAS from `Running` to
  `AbortRequested`.
- **Kill handle.** `httpBindingEval` returns `makeHttpKillHandle(token)` (local `killEval`, same
  shape as `sleepKillEval`). The kill closure does `takePendingResume(token)`, then
  `httpClearTracked(token)`, then `if (httpAbort(token)) releaseHold(token);`.
- **`Http.cancel`** (`Eco_Http_cancelTracker`, `:693-708`). After setting `cancelled = true`,
  copy `token` out, release `g_trackedMutex`, then
  `if (httpAbort(token)) { takePendingResume(token); httpClearTracked(token); releaseHold(token); }`.
- **Tracker reuse** (`httpRegisterTracked`, `:261-268`). If `g_trackerToken[trackerStr]` names an
  older token still in `g_httpTracked`, set its `cancelled = true` and remember it. After
  unlocking, run the same claim-or-abort as `Http.cancel` on it. This matches elm/http's
  `Process.kill pid` (`Http.elm:992`).
- **Single release.** Running or finished requests release only in `httpDrain`'s
  Nil-or-cancelled branch (`:403-409`). Queued-claimed requests release only on the eco thread
  that claimed them. eco/kernel requests (`eco_lane`, `control == nullptr`) are unchanged.

**JS Detached `runDuration`** (`ChildProcess.js:418`). Keep the duration timer ref'd for
Detached children too (delete the `unref` branch for the timer only; the child stays unref'd).

---

## 6. Ordering guarantees

### 6.1 Hold before wait
- Eco-thread bindings acquire inside their body (`parkResume`) before returning to the
  scheduler. Examples: `ProcessExports.cpp:31-34`, `HttpExports.cpp:616`. The body runs inside
  `drain()`, so no exit check intervenes.
- Host-thread acquires (`PortRuntime.cpp:465`) acquire before pushing the item and notifying.
  An exit check that ran earlier saw no item either.
- Subscription holds are acquired in `onEffects`, inside the update's drain (LIVE_004).
- **Debug assertion (phase 1).** `detail::asyncBindingTrampoline` (`TaskBinding.hpp`, the
  `makeAsyncBinding` path `:160-175`) records `pendingAsync_` and the census size before the
  body. Afterwards it asserts that the body either resumed synchronously or acquired a hold. On
  failure it aborts with the binding's name.

### 6.2 Hold before publish
- A hold is released only after its result is on the run queue. With `HoldRelease`, the idiom
  is: construct it first, then resume, and let it release at scope end.
- Two sites release before resuming. Phase 1 swaps them (L6). Both run on the eco thread inside
  a body, so the swap is a locality fix, not a bug fix.
  - `HttpServer.cpp:164-173` (`completeNow`): move `s.decrementPendingAsync()` (`:167`) after
    `Scheduler::callClosure1(resume, task)` (`:173`), and keep `token`/`counted` until then.
  - `Core.cpp:131-143` (`asyncFailure`): move `if (counted) s.decrementPendingAsync();` (`:138`)
    after `Scheduler::callClosure1(resume, task)` (`:141`).
- **Missed wakeup.** The window is closed by taking `mutex_` around the notify in `releaseHold`.

### 6.3 Resource creation → first `onEffects` (no grace hold)
- Native `PlatformRuntime::dispatchEffects` (`PlatformRuntime.cpp:330-400`) calls every
  registered manager's `onEffects` inline (`callClosure4`, `rawSpawn`, `drain()`). A reentrant
  `enqueueEffects` is dispatched by the outer loop (`:300-313`) before returning.
- On JS, elm/core drains synchronously and microtasks run before `beforeExit`.
- So a subscription made in the update that receives the listener holds before the run queue
  can empty.
- **LIVE_004** pins this: effect dispatch for an update completes before the drain that ran the
  update returns, and a manager's `onEffects` task must not park.

---

## 7. `onEmptyEventLoop` (decision L-REARM)

### 7.1 Rule
- One armed bit per program run, starting armed.
- When the loop is empty: if the bit is armed and at least one subscription exists, clear the
  bit, then deliver every subscription's msg in subscription order. Otherwise the program ends.
- `rearmEmptyEventLoop` sets the bit. Nothing else does.

### 7.2 Edge cases

| Case | Behaviour |
|---|---|
| Handler starts work, no rearm | the work completes; the program ends at the next empty loop |
| Handler logs on every fire | one fire, one log, ends |
| Rearm with no new work | fires again at once; a busy loop the program asked for; documented, not blocked |
| Rearm while unsubscribed | sets the bit, nothing else |
| ...then a first subscription | fires at the next empty loop (the bit is armed) |
| First subscription late, never fired | fires once (starts armed) |
| Fire → unsubscribe → resubscribe, no rearm | does not fire again (the bit is per program run) |
| Several subscriptions | all receive their msg on the one firing |
| Subscription dropped while armed | program ends at the next empty loop; the bit stays armed |
| Embedded | never fires |
| `exit` in handler | ends at once |

### 7.3 Elm API (`system-kernel-cpp/src/System.elm` **and** `ecosyskernel/src/System.elm`)

- Exposing list, line 5: `, onEmptyEventLoop, rearmEmptyEventLoop, onSignalInterrupt, onSignalTerminate`.
- `@docs`, line 70: `@docs onEmptyEventLoop, rearmEmptyEventLoop, onSignalInterrupt, onSignalTerminate`.
- In `-- SUBSCRIPTIONS`, right after `onEmptyEventLoop` (`:406-408`):
  ```elm
  {-| Asks for [`onEmptyEventLoop`](#onEmptyEventLoop) to deliver its message again the next
  time the program has an empty event loop.

  Issue it while handling that message, or in any later update before the event loop is next
  empty, for example once more jobs have been queued. If the program issues it and then starts
  no work, the event loop is empty again at once, so the message arrives again at once; a
  program that issues it on every delivery without starting work never ends. Issuing it when
  there is no `onEmptyEventLoop` subscription has no effect until the program subscribes.

  -}
  rearmEmptyEventLoop : Cmd msg
  rearmEmptyEventLoop =
      command (Execute kRearmEmptyEventLoop)
  ```
  ecosyskernel body: `Debug.todo "Implement System API"`, as for the others (`ecosyskernel/src/System.elm:266-267`).
- Kernel wrapper next to `kSetExitCode` (`System.elm:685-690`). It is not in the JS-only block
  (`:693-704`).
  ```elm
  {-| Makes a task that arms the empty-event-loop hook, so that `onEmptyEventLoop` delivers its
  message at the next empty event loop.
  -}
  kRearmEmptyEventLoop : Task Never ()
  kRearmEmptyEventLoop =
      Eco.Kernel.System.rearmEmptyEventLoop
  ```
- `onEmptyEventLoop` docstring (replaces `:390-404`):
  ```elm
  {-| Creates a subscription that receives `msg` when the program has an empty event loop:
  nothing it is waiting for is left, so the program would otherwise end.

  The message arrives once. Work started while handling it runs to completion, and the next time
  the event loop is empty the program ends. To receive the message again at the next empty
  event loop, issue [`rearmEmptyEventLoop`](#rearmEmptyEventLoop). If the program has several
  `onEmptyEventLoop` subscriptions, each receives its message at the same moment.

  Whether the message is due is one setting for the whole run of the program. It starts on, so a
  program that subscribes some time after it starts still receives the message once. Delivering
  the message turns it off, and only `rearmEmptyEventLoop` turns it on again: subscribing anew
  after a delivery is not enough.

  The subscription does not keep the program running. On the native backend it never fires
  when the program is embedded in a host application.

  -}
  ```
- `kAttachEmptyEventLoopListener` docstring (`:697-700`):
  ```elm
  {-| Makes a task that never completes and, each time the program has an empty event loop while
  the empty-event-loop hook is armed, disarms the hook and spawns the given task. Killing its
  process detaches it.
  -}
  ```
- **No `MyCmd` change.** `Execute` already carries any `Task Never ()`. The native manager
  spawns every `Execute` and drains (`SystemManager.cpp:161-178`), and `cmdMapEval` returns the
  command unchanged. On JS, `onEffects` spawns the tasks with `Process.spawn` (`System.elm:589`),
  and elm/core runs them in the same drain. The tags in `SystemManager.hpp:7-35` are unchanged.

### 7.4 Native implementation (phase 2)

- `Scheduler.hpp:73-74`: `using QuiescenceListener = bool (*)(void* ctx); // true iff it delivered`.
  Rewrite the comment block `:62-72` to: "called at every quiescent point (never in embed mode),
  with `mutex_` released, on the eco thread; the loop continues iff some listener returned
  true".
- Add `void removeQuiescenceListener(QuiescenceListener fn, void* ctx);`, used by unit tests.
- Delete `quiescenceArmed_` (`Scheduler.hpp:255-260`) and its store in the acquire path.
- `Scheduler.cpp:593-610` becomes:
  ```cpp
  if (!embedMode_.load() && !quiescenceListeners_.empty()) {
      auto listeners = quiescenceListeners_;
      lock.unlock();
      bool delivered = false;
      for (auto& [fn, ctx] : listeners) delivered |= fn(ctx);
      lock.lock();
      if (delivered) continue;
  }
  break;
  ```
- `SystemManager.cpp`:
  - `ManagerState` (`:42-52`) gains `bool emptyLoopArmed = true;`. Being registry state, it is
    armed again after a heap reset (F24), and it is accessed on the eco thread only.
  - Replace `onQuiescent` (`:97-105`):
    ```cpp
    bool onQuiescent(void*) {
        ManagerState& st = state();
        if (!st.emptyLoopArmed || st.msgs[CTOR_ON_EMPTY_EVENT_LOOP].empty()) return false;
        st.emptyLoopArmed = false;          // before delivery: a rearm in the handler sticks
        try {
            deliver(CTOR_ON_EMPTY_EVENT_LOOP);
        } catch (const std::exception& e) {
            ::Eco::Kernel::reportFatal(e.what());
        } catch (...) {
            ::Eco::Kernel::reportFatal("unknown native exception in onEmptyEventLoop");
        }
        return true;   // reportFatal does not return ([[noreturn]]); true keeps the contract
    }
    ```
    `reportFatal` must be declared `[[noreturn]]`; phase 2 checks its declaration and adds the
    attribute if it is missing.
  - Add `void rearmEmptyEventLoop() { state().emptyLoopArmed = true; }`. Declare it in
    `SystemManager.hpp` (in namespace `Eco::System::SystemManager`).
- `System.cpp`: add `HPointer systemRearmEmptyEventLoopBody(HPointer)`, which calls
  `SystemManager::rearmEmptyEventLoop()` and returns `succeedUnit()`. Model it on
  `systemSetExitCodeBody`.
- `SystemExports.cpp` (after `:26-30`):
  ```cpp
  // rearmEmptyEventLoop : Task Never ()
  uint64_t Eco_Kernel_System_rearmEmptyEventLoop() {
      ECO_KERNEL_GUARD(
          return enc(makeBinding<systemRearmEmptyEventLoopBody>(alloc::unit()));
      )
  }
  ```
  Add the declaration wherever the other `Eco_Kernel_System_*` exports are declared and
  registered for the JIT. Find them with
  `grep -rn "Eco_Kernel_System_setExitCode" runtime system-kernel-cpp compiler`, and mirror
  every hit.

### 7.5 JS implementation (phase 2, `Eco/Kernel/System.js:108-137`)

```js
var _System_emptyLoopArmed = true;

// rearmEmptyEventLoop : Task Never ()
var _System_rearmEmptyEventLoop = __Scheduler_binding(function(callback)
{
	_System_emptyLoopArmed = true;
	callback(__Scheduler_succeed(__Utils_Tuple0));
});

// onEmptyEventLoop (Node 'beforeExit'): fires only while armed, disarming first. When
// unarmed it schedules nothing, so Node exits. After firing it keeps the loop alive for one
// more turn, so a second 'beforeExit' reads the bit again even if the handler started
// nothing ref'd.
var _System_attachEmptyEventLoopListener = function(task)
{
	return __Scheduler_binding(function(callback)
	{
		var listener = function()
		{
			if (!_System_emptyLoopArmed) return;
			_System_emptyLoopArmed = false;
			__Scheduler_rawSpawn(task);
			setImmediate(function() {});
		};
		process.on('beforeExit', listener);
		return function() { process.removeListener('beforeExit', listener); };
	});
};
```

Remove `__Stream_activityCount` from the kernel import header of `System.js`.

---

## 8. Embedding
- `eco_embed.cpp:213` becomes `g_lifetime = sched.acquireHold(HoldKind::Host, "eco_embed")`, and
  `:323` becomes `sched.releaseHold(g_lifetime)` on the host thread.
- The activity hook (`fireActivity`, defined `Scheduler.cpp:656-662`, called `:618-619`) reports
  busy iff `!runQueue_.empty() || pendingAsync_ - hostHolds_ > 0`. `hostHolds_` is an atomic
  count of `Host` holds.
- `setLivenessBaseline` is deleted in phase 6, with its caller (`eco_embed.cpp:218`) and
  `livenessBaseline_`. Until then it is kept and equals `hostHolds_`.
- Port holds briefly report busy, which is harmless. `eco_node_addon.cpp:146-164` is unchanged.
- An embedded open-but-unsubscribed listener stops pinning the Node host after phase 6 (§13).

---

## 9. Documentation (final wording)

All eco/system doc edits are made identically in `system-kernel-cpp/src/**.elm` and
`ecosyskernel/src/**.elm`, and gated by the docs.json equality check (§10.0). elm/* doc comments
are not edited: elm/http and the others are upstream and unmodified.

**`System.elm` module doc**, replacing lines 38-44:

```
A program runs while it is waiting for something it asked for, and ends when it is not. It is
waiting while a task it started has not finished, such as a read, a write, an `accept`, a
sleep, an HTTP request or a child process it spawned; while it subscribes to something that can
still deliver, such as new connections on an open listener, messages on an open WebSocket or
changes to a watched file; and while it owes an answer to an HTTP request it was given.
Opening something does not keep a program running: an open listener with no `accept` waiting
and no subscription, or an open connection with no read or write in progress, does not.
Connections, datagrams and requests that arrive while nothing asks for them are held for later
and do not keep a program running either. Some subscriptions never keep a program running,
because they wait for things the program did not ask for; their docs say so.

When nothing is left to wait for, the program has an _empty event loop_ and ends, unless it
subscribes to [`onEmptyEventLoop`](#onEmptyEventLoop), which is told once and can ask to be
told again with [`rearmEmptyEventLoop`](#rearmEmptyEventLoop). [`exit`](#exit) and
[`exitWithCode`](#exitWithCode) end the program at once, whatever it is waiting for.

The same rule covers the `elm/*` packages. A `Process.sleep` keeps the program running until it
ends, a `Time.every` subscription while it exists, and an `elm/http` request while it is in
flight. `Http.track` adds nothing of its own: a tracker with no request in flight does not keep
the program running.
```

**`System.program`** (`:292-294`). Its docstring gains one paragraph, so that the
long-running-program entry point states when it ends:

```elm
{-| Creates a long-running program from an `init`, an `update` and `subscriptions`, as
`Platform.worker` does, with the program's [`Environment`](#Environment) as its flags.

The program runs while it is waiting for something, as the module documentation describes,
and ends when it has an empty event loop that [`onEmptyEventLoop`](#onEmptyEventLoop) does not
take over.

-}
```

**`onEmptyEventLoop`, `rearmEmptyEventLoop`**: §7.3.

**Per-function sentences** (phase 6 unless noted):

| File:line | Old | New |
|---|---|---|
| `Socket.elm:36-38` | "...an open [`Listener`](#Listener) keeps it running until it is closed." | "...an open [`Listener`](#Listener) keeps it running only while an [`accept`](#accept) is waiting or an [`onConnection`](#onConnection) subscription exists. Held connections do not keep it running." |
| `Socket.elm:199-200` | "An open listener keeps the program running until it is closed with [`closeListener`](#closeListener)." | "An open listener keeps the program running only while an `accept` on it is waiting or an `onConnection` subscription to it exists." |
| `Socket/Udp.elm:19-20` | "An open socket keeps the program running until it is [closed](#close)." | "An open socket keeps the program running only while a [`receive`](#receive) is waiting or an [`onMessage`](#onMessage) subscription exists." |
| `Socket/Udp.elm:84-86` | "The socket stays open, and keeps the program running, until it is closed with [`close`](#close)." | "The socket stays open until it is closed with [`close`](#close)." |
| `Http/Server.elm:134-135`, `:260-261` | "A listening server keeps the program running until it is closed with [`close`](#close)." | "A listening server keeps the program running only while an [`onRequest`](#onRequest) subscription to it exists or a request it handed over has not been answered." |
| `Http/Server.elm:320` | "A closed server no longer keeps the program running." | "Once the deadline has passed, nothing of a closed server keeps the program running." |
| `Http/Server.elm` `upgradeRequest` docstring | — | add: "The program keeps running until the `Upgrade` has been accepted or rejected with `WebSocket.accept` or `WebSocket.reject`, or its connection has gone away." |
| `ChildProcess.elm:296-298` (phase 3) | "...On the native backend, a detached child with a `runDuration` does keep the program running, until the limit expires or the child exits." | "...A detached child with a `runDuration` does keep the program running, until the limit expires or the child exits." |

**Design docs.**
- `plans/eco-system-library.md` §3.4 (`:547-550`) and §3.7 point here.
- Invariants: §12.

---

## 10. Implementation phases

### 10.0 Gates and conventions (every phase)

Per `/work/CLAUDE.md` and memory notes. Each test command runs once, with output in `/tmp`.

```bash
# Package sources (Elm or JS kernels) changed: drop stale caches first
rm -rf build/test/*/eco-stuff
# and move aside ~/.eco/0.1.3/packages/eco/system/*/artifacts.dat if eco/system sources changed
ulimit -c 0                                         # negative-control tests dump cores otherwise

cmake --build build --target full 2>&1 | tee /tmp/liveness-phaseN-full.txt          # native E2E + run-js-e2e
cmake --build build --target test && build/test/test --filter platform-services 2>&1 | tee /tmp/liveness-phaseN-unit.txt
cmake --build build --target elm-tests 2>&1 | tee /tmp/liveness-phaseN-elm.txt       # when Elm changes
```

- **Bootstrap** (phases 1, 2, 3): `cmake --build build --target bootstrap 2>&1 | tee /tmp/liveness-phaseN-boot.txt`.
- **docs.json equality** (phases 2, 3, 6):
  ```bash
  cmake --build build --target eco-system-docs
  (cd ecosyskernel && ../build/toolchain/bin/elm make --docs=/tmp/liveness-ecosys-docs.json)
  diff <(jq -S . system-kernel-cpp/docs.json) <(jq -S . /tmp/liveness-ecosys-docs.json) \
    && echo DOCS-EQUAL
  ```
  Then copy `/tmp/liveness-ecosys-docs.json` over `ecosyskernel/docs.json` (the committed copy).
- **Rollback.** Each phase is one or more commits, one module per commit in phases 4-5. Revert
  the phase's commits; there are no data migrations. Phases 4, 5 and 7 are pure refactors.
  Phase 6 depends on 4-5. Phases 2 and 3 are independent of each other.

### 10.1 Phase 1 — hold API, census, mechanical migration outside system-kernel-cpp

1. Add `runtime/src/platform/Liveness.hpp` (§5.1), and in `Scheduler.hpp/.cpp` add `parkResume`,
   `acquireHold`, `releaseHold`, `reportHolds`, `holdsMutex_`, `holds_`, `nextHoldId_` and
   `hostHolds_`. `acquireHold`/`parkResume` keep `quiescenceArmed_.store(true)` (N6).
   `LivenessHold`'s members are defined in `Scheduler.cpp`.
2. Migrate the runtime:
   - `Scheduler.cpp:701-716` (`processReadyAsync`): both `decrementPendingAsync()` (`:705,716`)
     become `releaseHold(token)`.
   - `PortRuntime.cpp:465` becomes `uint64_t h = sched.acquireHold(HoldKind::Port, "port.in");`,
     stored with the queued item (`pendingSends_` element gains `HoldToken hold`). `:391-392`:
     the private `struct AsyncRelease` becomes `HoldRelease(item.hold)`.
   - `eco_embed.cpp:213,323` → §8.
3. elm-kernel-cpp:
   - `ProcessExports.cpp:31-32` → shape A.
   - `TimeEffectManager.cpp:112-113` → shape A.
   - `HttpExports.cpp:615-616` → shape A; `:408` and `:467` → shape B (`releaseHold(r.token)`).
4. eco-kernel-cpp, mechanical (§16):
   - `MVar.cpp:176-177, 207-208, 239-240` → shape A.
   - `MVar.cpp:73, 83, 326` → shape B with the waiter's token (`w.token`).
   - `Process.cpp:177-178` → A; `:134`, `:147` → B.
   - `Http.cpp:348-349` → A; `:290`, `:327` → B.
5. L6 swaps (§6.2).
6. Debug assertion in `TaskBinding.hpp` (§6.1).
7. Unit tests (`test/platform/PlatformServicesTest.cpp`, new cases PS4-PS9, §11.2).
8. Gate: unit, `full`, bootstrap. Expected: no E2E change. PS1-PS3 unchanged.

### 10.2 Phase 2 — L-REARM

Edits:
1. §7.4 native.
2. §7.5 JS.
3. §7.3 Elm, in both `system-kernel-cpp/src/System.elm` and `ecosyskernel/src/System.elm`.
4. §9 module doc and `program` text, in both files.
5. Delete the re-arm store from `acquireHold`/`parkResume`, and delete `quiescenceArmed_`.
6. Re-baseline PS1-PS3 (§11.2). Test listeners return `false` once they have nothing to do, so
   they cannot spin.
7. Re-baseline `test/eco-system/src/OnEmptyEventLoopTest.elm`. Its header says "delivered a second
   time", and the CHECKs change (§11.1). Run
   `grep -rln onEmptyEventLoop test examples system-kernel-cpp/src` and re-check every hit.
8. Add the §11.1 L-REARM tests.

Gate: unit, `full`, bootstrap (the compiler links eco/system), docs.json equality, elm-tests.

### 10.3 Phase 3 — withdrawal

Edits:
1. §5.3: sleep kill, Time.every, `RequestControl` + `httpAbort` + kill handle + cancel + tracker
   reuse.
2. JS `ChildProcess.js:418` (X4).
3. `ChildProcess.elm:296-298` doc, in both trees.
4. §11.1 withdrawal tests.
5. Unit tests PS10-PS12 (§11.2).

Gate: unit (+ TSan build of PS10 if `build-heap-tsan` exists; memory: recreate on demand),
`full`, bootstrap, docs.json.

### 10.4 Phase 4 — system-kernel-cpp migration A (no behaviour change)

One commit per module, each gated by `full`:

| Module | Sites (shape) |
|---|---|
| Core | `Core.cpp:138` (B, `token`); `KillHandle.cpp:34` (B, `releaseHold(token)`); add `HoldRelease` to `AsyncRelease.hpp` |
| SysWorkPool | `SysWorkPool.cpp:12,115` (C with the job token) |
| FileSystem | `FileSystem.cpp:192-193` (A); `FileSystemManager.cpp:152,200` (D: the per-key `bool` becomes `HoldToken`, kind `Subscription`) |
| ChildProcess | `ChildProcess.cpp:247,325,366` (B/C); `:477-478,570-571` (A); `ChildProcessManager.cpp:144` (D, kind `Task`, stored in the child entry) |
| Stream | `Stream.cpp:124,137,615,665,699,817` (B/C); `:849,1115,1120,1233,1250,1324` (A); `:207-209,439-441,522-524` (B) |
| StreamPipe | `StreamPipe.cpp:97,109,230,276,288` (A/B) |
| HttpStream | `HttpStream.cpp:51,197` (C); `:262` (A) |
| Tls | `Tls.cpp:196,254` (A) |

After each module, `grep -n "incrementPendingAsync\|decrementPendingAsync\|AsyncRelease" <module files>` is empty.

### 10.5 Phase 5 — system-kernel-cpp migration B + JS helper (no behaviour change)

| Module | Sites |
|---|---|
| Socket | `Socket.cpp:338,358,454,487,537,587` (A); `:325` (D: `ListenerEntry::counted` → `HoldToken lifetime`, kind `Task`, still acquired); `SocketTables.cpp:21,139,172,189` (C); `:182` (C on `entry.lifetime`) |
| Udp | `Udp.cpp:570,660` (A, via `startOp`/inline); `:531` (D: `UdpEntry::counted` → `lifetime`); `:32,507` (C) |
| HttpServer | `HttpServer.cpp:205,277,361,384` (A); `:165` (B); `HttpTables.cpp:224` (D: `KeyEntry::counted` → `HoldToken hold`, kind `Item`); `:387` (D: `ServerEntry::counted` → `lifetime`); `:17,162,294,297,314` (C) |
| WebSocket | `WebSocket.cpp:158,301,346,465,575,649,675,720` (A); `WsManager.cpp:230,231` (D, kind `Subscription`); `WsTables.cpp:315` (D: `closeCounted` → `HoldToken closeHold`); `:19,92,120,151,177,188,203,210` (C) |

JS:
- Add `Liveness.js` (§5.2), and add it to the eco/system kernel list wherever `Stream.js` is
  listed. Find those places with `grep -rn "Stream.js" system-kernel-cpp compiler CMakeLists.txt`.
- Rewrite `WebSocket.js:881-897` on `__Liveness_handle(socket)`: `holds` becomes a counter of
  `hold()` releases. The two raw timers (`:2290`, `:2612`) are unref'd, and the hold for that
  phase is taken through the handle.
- Delete `AsyncRelease`.

Gate: `full` per module commit.

### 10.6 Phase 6 — L2, held items, upgrade hand-over, docs, raw API private

**Native Socket**
- `Socket.cpp:322-325`: delete `e.counted = true;` (`lifetime`) and the acquire. `ListenerEntry`
  (`SocketTables.hpp:52-60`): remove `lifetime`, and add `HoldToken subHold = kNoHold;`.
- `SocketTables.cpp:297-311` (`socketTablesSyncSubscriptions`): after `e.subscribed = on;`, add
  `if (on && !e.subHold) e.subHold = sched.acquireHold(HoldKind::Subscription, "Socket.onConnection"); if (!on && e.subHold) { sched.releaseHold(e.subHold); e.subHold = kNoHold; }`.
- `Socket.cpp:518`: `token = Scheduler::instance().registerPendingResume(resume);` →
  `token = Scheduler::instance().parkResume(resume, HoldKind::Task, "Socket.accept");`.
- `SocketTables.cpp:321-333` (`cancelParkedAccept`): `return true;` when found (the kill handle
  releases), and still `false` when not found.
- `SocketTables.cpp:99-108` (`serveHeld`, giving a held item to the oldest parked accept): add
  `HoldRelease r(token);` before the resume.
- `onListenerClosed` (`:178-193`): `HoldRelease` for `entry.subHold`, and for each parked-accept
  token after its `resumeFail`.
- Held FIFO: unchanged (it never held).

**Native Udp**
- The same five edits:
  - `Udp.cpp:528-531` delete;
  - `Udp.hpp:146` `counted` → `subHold`;
  - sync at `Udp.cpp:603-615`;
  - parked receive `:720` uses `parkResume`;
  - `cancelParkedReceive` (`:619-631`) returns true when found;
  - serve `:455-460` adds `HoldRelease`;
  - close `:505-515` releases.

**Native HttpServer**
- `HttpTables.cpp:385-387`: delete the server lifetime acquire. `ServerEntry` gains
  `HoldToken subHold`. Add `void httpTablesSyncSubscriptionHolds()`, called from
  `httpTablesSubscriptionsChanged` (`:445-453`). It acquires or releases `subHold` per server
  from `httpManagerHasSubscriber(id)`.
- `onRequest` (`:212-251`): do not acquire at `:220-224`; `k.hold = kNoHold`. In the immediate
  delivery branch (`:233-236`), `k.hold = sched.acquireHold(HoldKind::Item, "Http.Server.request")`
  before `httpManagerDeliver`. Parked keys stay uncounted (N4).
- `deliverParked` (`:255-277`): acquire `k->hold` before `httpManagerDeliver`.
- `eraseKey` (`:157-170`): `HoldRelease release(it->second.hold);` (`kNoHold` for parked keys).
- JS `kHoldRequest` re-hold (`HttpServer.js:1461-1475`): a request re-held because the
  subscriber went away releases its delivery hold (see JS below). Native has no re-hold path.
  Phase 6 confirms this with `grep -n holdRequest system-kernel-cpp/src/eco-system`.
- `onServerClosed` (`:375-383`): release `subHold`.

**Native upgrade hand-over (N5)**
- `HttpTables.cpp:432-439` (`httpTablesTakeUpgrade`): new out-param `HoldToken& hold`. Set
  `hold = k->hold; k->hold = kNoHold;` before `eraseKey(key)`.
- `HttpUpgrade.cpp:209-221`: pass it to
  `wsTablesAddServerHandshake(std::shared_ptr<Conn> c, HoldToken hold)` (`WsTables.cpp:287`,
  `WsTables.hpp:100`). It stores the token in the handshake entry (new field
  `HoldToken peerHold`).
- `WebSocket.cpp:463-465` (accept) and `:573-575` (reject): after `parkResume` for the operation,
  `HoldRelease(it->second.peerHold)` before `t.handshakes.erase(it)`. The peer is then held by
  the operation, with no gap and no double count.
- `kAbandon` body, connection-gone and heap-reset erasure of handshakes (`WsTables.cpp`, every
  `handshakes.erase`): release `peerHold`.

**JS Socket.js**
- `_Socket_listen` (`:341-375`): `L.__live = __Liveness_handle(server)` right after the server is
  created (unref'd).
- `_Socket_accept` (`:575-596`): `entry.__release = L.__live.hold()` on park. The callback path
  and the kill function call `entry.__release()`.
- The manager listener attach and detach (where `L.__listener` is set and cleared):
  `L.__subRelease = L.__live.hold()` / `L.__subRelease()`.
- `_Socket_onConnection`: `socket.unref()` on every accepted socket. Stream channels re-ref per
  pending request (`Stream.js:1360-1361`), as for connected sockets.
- `closeListener`: `L.__live.gone()`, then release all.
- UDP (`:838-857`): `U.__live = __Liveness_handle(socket)`, with receive park, subscription and
  close handled the same way.

**JS HttpServer.js**
- At server creation (`:1100-1110`): `s.__live = __Liveness_handle(server)`.
- In the listener attach (`:1436-1455`): `s.__subRelease = s.__live.hold()`. Detach releases it.
- On each `'connection'`/`'secureConnection'` (and http2 `'session'` socket):
  `conn.__live = __Liveness_handle(socket)` (unref'd: idle keep-alive holds nothing).
- In `_HttpServer_deliver` (`:489-500`) to a listener: `e.__release = e.__conn.__live.hold()`.
  Release on response `'finish'`/`'close'`, on `upgradeRequest` hand-over (moved to the
  handshake, then released when accept/reject starts), and when `kHoldRequest` re-holds the entry.
- Server close: `s.__live.gone()`.

**Docs**: §9, in both trees.

**Raw API private**
- Move `incrementPendingAsync`/`decrementPendingAsync` to `private:` in `Scheduler.hpp`.
- `grep -rn "incrementPendingAsync\|decrementPendingAsync" runtime elm-kernel-cpp eco-kernel-cpp system-kernel-cpp test`
  must list only `Scheduler.{hpp,cpp}`.
- Migrate the test uses (`test/platform/PlatformServicesTest.cpp`,
  `test/eco-system-core/EcoSystemCoreTest.cpp`; 6 lines) to `acquireHold`/`releaseHold`.
- Delete `setLivenessBaseline` (§8).

**Tests**: §11.1 phase-6 tests. Re-baseline `HarnessExitZeroTest`, `FileWatchTest`,
`HttpServerKeepAliveTest`, `WebSocketExitTest`, `EcoSystemCoreTest.cpp:688`,
`test/stress-elm/src/EcoSystemProcess{Run,Kill}.elm`. Audit every
`grep -l "listen\|bind" test/eco-system/src/*.elm test/stress-elm/src/*.elm`: each program that
must stay up subscribes, accepts or ends with `exit`.

Gate: unit, `full`, docs.json equality, `cmake --build build --target stress 2>&1 | tee /tmp/liveness-phase6-stress.txt`,
and `test/embed` (in `full`).

### 10.7 Phase 7 — delete the JS Stream activity epoch
- Delete `_Stream_noteActivity`/`_Stream_activityCount` (`Stream.js:142-155`) and every call
  (`grep -rn "noteActivity\|activityCount" system-kernel-cpp/src/Eco/Kernel`, about 50 lines in
  9 files), together with their kernel-import entries.
- Gate: `full`.

---

## 11. Tests

### 11.1 E2E (`test/eco-system/src/`, both backends)

Conventions (`ExitWithCodeTest.elm`): a module doc saying what is checked, then `-- CHECK:` /
`-- CHECK-NOT:` / `-- EXIT:` lines. The watchdog is 60 s (`test/IsolatedTestRunner.hpp:28`;
`run-js-e2e.js:54`). **Negative tests use durations above 60 s**, so that a regression is a
timeout. External peers are Detached `node -e` children, as in `WebSocketExitTest.elm:42-89`.
The elm/http test server is `ECO_TEST_HTTP_URL` (`TestServerConfig.elm`), whose `/slow?ms=N`
route answers after N ms on both servers.

New helper `LiveTestHelp.elm`:

```elm
module LiveTestHelp exposing (log, node)

{-| Helpers for the liveness tests: logging a line, and starting a Detached Node process as an
external peer, which does not keep the program running.
-}

import ChildProcess as Process
import Stream
import System
import Task


{-| Writes `line` to stdout and then sends `msg`.
-}
log : System.Environment -> msg -> String -> Cmd msg
log env msg line =
    Task.perform (\_ -> msg) (Stream.logLine line env.stdout)


{-| Starts `node -e script` as a Detached child; both of its msgs are `msg`.
-}
node : msg -> String -> Cmd msg
node msg script =
    Process.spawn "node"
        [ "-e", script ]
        (Process.defaultSpawnOptions (Process.Detached (\_ -> msg)) (\_ -> msg)
            |> (\o -> { o | shell = Process.NoShell })
        )
```

**L-REARM (phase 2)**

`OnEmptyEventLoopTest.elm` (re-baselined): header "fires once; the IO its handler starts runs
to completion, then the program ends". CHECKs:
```
-- CHECK: fired: 1
-- CHECK: io from first fire
-- CHECK-NOT: fired: 2
-- EXIT: 0
```
Source unchanged.

`OnEmptyEventLoopLogTest.elm`:
```elm
module OnEmptyEventLoopLogTest exposing (main)

{-| A handler that logs on every delivery is delivered once: the IO it starts does not arm the
hook again, so the program ends after the log line. A loop would be killed by the watchdog.
-}

-- CHECK: fired: 1
-- CHECK: logged 1
-- CHECK-NOT: fired: 2
-- EXIT: 0

import LiveTestHelp as L
import System


type Msg
    = Empty
    | Logged


main : Platform.Program System.Environment ( System.Environment, Int ) Msg
main =
    Platform.worker
        { init = \env -> ( ( env, 0 ), Cmd.none )
        , update =
            \msg ( env, n ) ->
                case msg of
                    Empty ->
                        let
                            _ =
                                Debug.log "fired" (n + 1)
                        in
                        ( ( env, n + 1 ), L.log env Logged ("logged " ++ String.fromInt (n + 1)) )

                    Logged ->
                        ( ( env, n ), Cmd.none )
        , subscriptions = \_ -> System.onEmptyEventLoop Empty
        }
```

`OnEmptyEventLoopJobQueueTest.elm`. The model holds `jobs = [1, 2, 3]`. On `Empty`: pop a
job, log `job N`, run `Process.sleep 10`. On `Slept`: if jobs remain, issue
`System.rearmEmptyEventLoop`. The program ends after job 3, because `Slept` for job 3 does not
rearm.
```
-- CHECK: job 1
-- CHECK: job 2
-- CHECK: job 3
-- CHECK-NOT: fired: 4
-- EXIT: 0
```
It also `Debug.log "fired"` on each `Empty`. With three jobs and rearm only while jobs remain
after the pop, it fires exactly three times.

`OnEmptyEventLoopRearmBusyTest.elm`. On `Empty`, `n + 1`. If `n + 1 < 5`, issue
`rearmEmptyEventLoop` with no other work.
```
-- CHECK: fired: 5
-- CHECK-NOT: fired: 6
-- EXIT: 0
```

`OnEmptyEventLoopTwoSubsTest.elm`: `subscriptions = \_ -> Sub.batch [ System.onEmptyEventLoop A, System.onEmptyEventLoop B ]`.
Each branch logs.
```
-- CHECK: got A
-- CHECK: got B
-- CHECK-NOT: got A
-- EXIT: 0
```
CHECK-NOT after both checks that no second firing happened. The two CHECK lines are matched in
subscription order; if the order differs between backends, that is a finding, not a test
tweak.

`OnEmptyEventLoopLateTest.elm`: `init` runs `Process.sleep 50 |> Task.perform (\_ -> Woke)`. The
model flag `subscribed` becomes True on `Woke`, and subscriptions return
`onEmptyEventLoop Empty` only then.
```
-- CHECK: woke
-- CHECK: fired: 1
-- CHECK-NOT: fired: 2
-- EXIT: 0
```

`OnEmptyEventLoopRearmUnsubscribedTest.elm`: `init` issues
`Cmd.batch [ System.rearmEmptyEventLoop, sleep 50 → Woke ]`. It subscribes after `Woke`.
Expected: fires once (same CHECKs as Late).

`OnEmptyEventLoopResubscribeTest.elm`: fires; the handler unsubscribes and starts
`sleep 50 → Woke`; on `Woke` it subscribes again without a rearm. Expected:
```
-- CHECK: fired: 1
-- CHECK: woke
-- CHECK-NOT: fired: 2
-- EXIT: 0
```

`OnEmptyEventLoopSleepTest.elm`: the handler starts `Process.sleep 50` and logs `slept`; no
rearm. Expected: `fired: 1`, `slept`, `CHECK-NOT: fired: 2`, `EXIT: 0`. Native used to fire twice.

**Withdrawal (phase 3)**

`LiveSleepKilledTest.elm`:
```elm
-- CHECK: killed
-- EXIT: 0
-- init: Process.spawn (Process.sleep 120000) |> Task.andThen Process.kill |> Task.perform (\_ -> Killed)
-- update Killed: log "killed"
```
(Process here is elm/core `Process`.)

`LiveTimeEveryDropTest.elm`: subscribes to `Time.every 120000 Tick` while `model.on`. `init`
sends `Drop` through `Task.succeed`. `Drop` sets `on = False` and logs `dropped`.
CHECK: `dropped`, EXIT 0.

`LiveHttpCancelTest.elm`: `Http.request { … , url = base ++ "/slow?ms=120000", tracker = Just "t", timeout = Nothing }`,
then `Process.sleep 200`, then `Http.cancel "t"`. On the `Cancelled` msg, log `cancelled`.
EXIT 0. It must not receive the response msg: `CHECK-NOT: response`.

`LiveHttpCancelQueuedTest.elm` (N2):
- Request A: `/slow?ms=1500`, untracked; logs `a done`.
- Request B: `/slow?ms=120000`, tracker `"b"`.
- Then `Http.cancel "b"` in the same update.
- Natively, B is queued behind A and is claimed.
```
-- CHECK: a done
-- CHECK-NOT: b response
-- EXIT: 0
```

`LiveHttpKillTest.elm`: `Process.spawn (Http.task { … "/slow?ms=120000" … })`, then
`sleep 200`, then `Process.kill`. Logs `killed`, EXIT 0.

`LiveHttpTrackerReuseTest.elm` (N3): request 1 to `/slow?ms=120000` with tracker `"t"`; after
`sleep 200`, request 2 to `/slow?ms=10` with tracker `"t"`.
```
-- CHECK: second done
-- CHECK-NOT: first done
-- EXIT: 0
```

`LiveDetachedRunDurationTest.elm` (X4): spawn Detached `sleep 30` with
`runDuration = Milliseconds 300`. The program stays until the limit (logs `exit` via `onExit`
on both backends), then ends. EXIT 0. That it ends at all is checked by the watchdog: 30 s <
60 s, so this test is positive, not negative.

**Phase 6**

`LiveListenerUnsubscribedTest.elm`: `H.listenLocal`, log `listening`, nothing else. EXIT 0.

`LiveListenerHeldTest.elm` (N4): listen, then `L.node` a client that connects, then sleeps
120 s with the socket open. No accept, no subscription. The program logs `listening`; the
connection is held and must not keep the program alive. EXIT 0.

`LiveListenerSubscribedTest.elm`: listen; subscribe `onConnection l Conn`; the client connects
after 300 ms. The handler logs `conn` and `Socket.closeListener` → logs `closed`. EXIT 0.

`LiveListenerAcceptTest.elm`: listen; `Socket.accept l |> Task.attempt Accepted`; the client
connects after 300 ms. Logs `accepted`, then closes the connection and the listener. EXIT 0.

`LiveListenerAcceptKilledTest.elm`: `Process.spawn (Socket.accept l)`, `sleep 50`,
`Process.kill`. Logs `killed`. EXIT 0.

`LiveUdpUnsubscribedTest.elm`, `LiveUdpOnMessageTest.elm`: as above, with a `node -e` dgram
sender after 300 ms; on the message, unsubscribe and `Udp.close`.

`LiveHttpServerUnsubscribedTest.elm`: listen on port 0; a client sends one request after
300 ms and keeps the connection open for 120 s. No `onRequest`. The request is parked, and must
not keep the program alive. EXIT 0.

`LiveHttpServerOnRequestTest.elm`: `onRequest` while not done; on the request, `send` 200 and set
done. Logs `served`. EXIT 0.

`LiveHttpServerUnansweredTest.elm` (positive, LIVE-1c): on the request, do not answer; after
`sleep 500`, answer and log `answered late`; the client prints its status code to a file
nothing checks. CHECK `answered late`, EXIT 0.

`LiveHttpServerCloseUnansweredTest.elm` (N1): the request is delivered; the handler fiber is
killed; then `Http.Server.closeWithin 300 server`. The client never times out. The program ends
within the deadline + ε (the watchdog catches a hang). EXIT 0.

`LiveHttpUpgradeTest.elm` (N5): the client sends a WebSocket upgrade request (`WebSocketExitTest`'s
client script). The handler runs `upgradeRequest`, then `Process.sleep 500`, then
`WebSocket.accept`, logs `accepted`, and closes. In the sleep window, nothing else holds; the
handshake hold must keep the program alive. CHECK `accepted`, EXIT 0.

`LiveStreamCancelTest.elm` (phase 6, any phase works): `Stream.read env.stdin` in a spawned
fiber with `-- STDIN:` absent (stdin is `/dev/null`, so use a pipe from a Detached child, or
skip natively if it is EOF at once). `cancelReadable` → EXIT 0. If stdin cannot be held open
in the harness, the test reads from a socket connection the program accepted from an external
client, and cancels that.

`LiveSignalOnlyTest.elm`, `LiveResizeOnlyTest.elm`: only the ambient sub; EXIT 0.

`LiveDetachedChildTest.elm`: Detached `sleep 120`; EXIT 0.

`LiveSpawnedChildTest.elm`: non-Detached `sleep 0.3`; logs `exit 0` from `onExit`; EXIT 0.

### 11.2 Unit (`test/platform/PlatformServicesTest.cpp`, suite `platform-services`)

| ID | Test | Phase |
|---|---|---|
| PS1 (rebaselined) | listener returns true and starts a 5 ms timer only on its first call, then returns false (the bit is SystemManager's); the loop calls it twice and exits | 2 |
| PS2 (rebaselined) | a listener returning false → called once, loop exits; second `runEventLoop` → called once more (no bit in the Scheduler) | 2 |
| PS3 | embed mode never calls listeners | unchanged |
| PS4 | `LivenessHold` acquire/move/release: `pendingAsync` 0→1→1→0; move-assign releases the old one | 1 |
| PS5 | double `releaseHold` aborts (debug; run as an isolated death test) | 1 |
| PS6 | `parkResume` token == resume token; `releaseHold(token)` balances | 1 |
| PS7 | 4 host threads × 10,000 acquire/release with the eco loop waiting: ends at 0, no lost wakeup (TSan build) | 1 |
| PS8 | census: `reportHolds` lists kind and site of a live hold | 1 |
| PS9 | LIVE_004: a test manager's `onEffects` records `Scheduler::drainDepth()`; it runs inside the update's drain | 1 |
| PS10 | sleep kill vs concurrent fire: 1,000 iterations of schedule(0 ms) + kill; `pendingAsync` returns to 0 every time (TSan) | 3 |
| PS11 | `httpAbort` on a queued request: true; the worker posts nothing (queue a blocking request first) | 3 |
| PS12 | `Time.every` unsubscribe cancels the stored tick: `pendingAsync` drops at once | 3 |

PS9 needs a small read-only `drainDepth()` accessor. The unit runner isolates each test in a
child (`IsolatedTestCaseSuite`, `test/main.cpp:603-614`), so permanently registered listeners do
not leak between tests. PS1/PS2 also call `removeQuiescenceListener` at the end.

---

## 12. Invariants (`design_docs/invariants.csv`; columns `id;phase;category;status;description;source`)

Added in the phase that makes each true:

```
LIVE_001;Runtime;ProgramLiveness;tested;A program keeps running exactly while it waits for something it asked for: a task in flight, a live subscription to a non-ambient source, or a delivered item owed a reply (an unanswered HTTP request, an Upgrade not yet accepted or rejected). Opening a resource holds nothing, and held items (connections, datagrams, requests nobody has asked for yet) hold nothing. Same on native and JS for eco/system and elm/*; eco/kernel is out of scope (plans/program-liveness-rule.md §16);plans/program-liveness-rule.md|runtime/src/platform/Scheduler.cpp|system-kernel-cpp/src/eco-system
LIVE_002;Runtime;ProgramLiveness;tested;Ambient sources hold nothing: signal and resize subscriptions, onEmptyEventLoop, incoming port subscriptions. Detached children hold nothing except their runDuration timer;system-kernel-cpp/src/eco-system/System/SystemManager.cpp|system-kernel-cpp/src/eco-system/Terminal|runtime/src/platform/PortRuntime.cpp
LIVE_003;Runtime;ProgramLiveness;enforced;A hold is released only after the result it waited for has been published (resume enqueued or message sent), and every hold is released exactly once on every path; debug builds abort on a double or unknown release (Scheduler::releaseHold);runtime/src/platform/Scheduler.cpp|runtime/src/platform/Liveness.hpp
LIVE_004;Runtime;EffectDispatch;tested;Effect dispatch for an update completes, every manager's onEffects having run, before the drain that ran the update returns, and no manager's onEffects task parks. Subscription holds therefore exist before the run queue can empty (no grace hold is needed);runtime/src/platform/PlatformRuntime.cpp|test/platform/PlatformServicesTest.cpp
LIVE_005;Runtime;EmptyEventLoop;tested;onEmptyEventLoop fires only while its armed bit is set and a subscription exists; firing clears the bit before delivery; only System.rearmEmptyEventLoop sets it; it starts set for each program run; acquiring holds never sets it. Same on both backends; never fires in embed mode;system-kernel-cpp/src/eco-system/System/SystemManager.cpp|system-kernel-cpp/src/Eco/Kernel/System.js|runtime/src/platform/Scheduler.cpp
LIVE_006;Runtime;ProgramLiveness;enforced;Only Scheduler's hold API (parkResume, acquireHold, releaseHold, LivenessHold, HoldRelease) changes pendingAsync_; increment/decrementPendingAsync are private. This includes processReadyAsync's releases, PortRuntime and eco_embed;runtime/src/platform/Scheduler.hpp
```

SYS_003 (line 743): replace "one pendingAsync count per piece of external IO that should keep
the program alive" with "one hold (LIVE_001, LIVE_006) per wait that keeps the program
running". Keep "in-memory stream parking, signal and resize subscriptions hold none".

---

## 13. Risks

1. **Servers.** A program that listens and has nothing pending before it subscribes ends
   (LIVE-2). The same goes for a program relying on a parked request or a held connection.
   Mitigations: release notes, `ECO_LIVENESS_REPORT`.
2. **`onEmptyEventLoop` users** relying on IO re-arming get one delivery and must issue
   `rearmEmptyEventLoop`.
3. **Signal-only supervisors** end at once (X1).
4. **N-API embedders**: an open, unsubscribed listener no longer pins the host loop.
5. **The compiler** links eco/system and elm/* (`Process.sleep`, `Time`, streams, child
   processes), so phases 1-3 are bootstrap-gated. eco/kernel behaviour is unchanged.
6. **Migration** of about 110 sites: a lost release hangs, a double release exits early. Mitigations:
   the census aborts in debug, one module per commit, `full` per commit.
7. **Timer and curl races**: §5.3 single-release arguments; PS10/PS11.
8. **curl abort latency.** libcurl calls xferinfo at least about once per second while
   connected, and during resolution with the threaded resolver. Queued requests are claimed
   at once.

---

## 14. Decisions

| ID | Decision |
|---|---|
| L1 | Adopt LIVE-1…LIVE-6 (§2.2). |
| L2 | Listener, server and UDP socket stop holding for their lifetime. They hold via parked accept/receive, subscriptions and delivered items. Held items hold nothing (N4). No grace hold; LIVE_004 instead. |
| L3 | *(withdrawn: grace hold.)* |
| L4 | Non-Detached child holds until its exit is published. Detached holds nothing except its `runDuration` timer, on both backends. |
| L5 | Real withdrawal: sleep kill, `Time.every` unsubscribe, elm/http cancel, kill and tracker reuse (queued: claimed; running: curl abort). `close`/`closeWithin` keep their deadline semantics (N1). Only X12 holds until report. |
| L6 | Publish-then-release swaps in `HttpServer.cpp:164-173`, `Core.cpp:131-143`. |
| L7 | *(withdrawn: MVar, §16.)* |
| L8 | Native `LivenessHold`/`HoldToken`/`parkResume`/`HoldRelease`, thread-safe, with census. Raw counters private in phase 6. |
| L-REARM | `onEmptyEventLoop` fires once per arming, with one bit per run, starting armed. `rearmEmptyEventLoop` (via `Execute`) is the only setter. Both backends identical. |
| L10 | Stock elm/* JS kernels are not patched, and their doc comments are not edited. The System module doc states the rule for elm/* (§9). |
| L11 | Embed activity excludes `Host` holds; the baseline API is removed. |
| L12 | The rule is stated once in `System` docs, with exceptions at their functions. LIVE_* invariants are added. Every eco/system doc change lands in ecosyskernel too, gated by docs.json equality. |
| L13 | eco/kernel keeps its behaviour, and is migrated mechanically to the hold API in phase 1 (§16). |
| L14 | The upgrade handshake carries the request's hold until accept/reject has its own, or the handshake ends (N5). |

---

## 15. Open questions

- **Q1. JS details** (before phase 6):
  - Does `closeWritable` hold until the close completes (`Stream.js:1502` unrefs the close timer)?
  - Is an unanswered request's socket ref'd? Phase 6 makes it explicit anyway.
  - Do http2 session sockets need the same per-connection handle as HTTP/1 sockets?
- **Q2. curl abort latency.** Is about one second "prompt" for a running request? The service
  uses `curl_easy_perform`, so `curl_multi_wakeup` does not apply. The alternative is a short
  `CURLOPT_LOW_SPEED`-style poll, which is not proposed.
- **Q3. File streams.** The `readFileStream`/`writeFileStream` holds are assumed to be per
  request; the phase 4 audit confirms this.
- **Q4. `LiveStreamCancelTest`** needs a held-open stdin or a socket read; the harness choice is
  open.
- **Q5. eco/kernel follow-up**: which way should MVar go?

Closed:
- the grace-hold boundary (dropped);
- `async_hooks` (unused);
- `Http.track` with no request in flight (does not hold; user decision);
- `curl_multi_wakeup` (not applicable, N2);
- `Http.server.js` (in the published package, never selected);
- Console and the MVar census (out of scope).

---

## 16. Out of scope: eco/kernel (known issues)

eco/kernel (`eco-kernel-cpp/` and its JS kernels) is compiler-internal. Its behaviour is
unchanged. Known deviations, for a later compiler-aware change:

| Issue | Native | JS | Effect |
|---|---|---|---|
| Blocked MVar wait | holds (`MVar.cpp:177/208/240` → `:83`) | none (`Eco/Kernel/MVar.js:6-72`) | a deadlock hangs natively, and exits 0 silently on JS |
| Killed MVar waiter | kill handle Unit (`MVar.cpp:177-181,208-212,240-244`): the waiter stays queued and keeps its hold | n/a | a killed native waiter can keep the program alive |
| `Process.spawn`/`spawnProcess` | no hold (`Process.cpp:62,81`); only `wait` holds | ref'd child and stdin pipe (`Eco/Kernel/Process.js:30-66`) | JS waits for the child; native does not |

The follow-up must weigh the compiler's MVar use (`compiler/src/Utils/Main.elm`,
`System/IO.elm`, `Builder/*`). Dropping native holds without a deadlock diagnostic would turn a
compiler deadlock into a silent `EXIT 0`.

**Mechanical migration (phase 1).** The 12 raw lines (`MVar.cpp:73,83,177,208,240,326`,
`Process.cpp:134,147,178`, `Http.cpp:290,327,349`) become shapes A/B at the same points. This was
chosen over a private escape hatch, for three reasons:
- the raw API can be private with no exception (LIVE_006 checkable by grep);
- eco/kernel holds appear in the census, which is where a hung compiler is diagnosed;
- every site is park-then-release-after-resume or release-on-Nil, keyed by a resume token, so
  shapes A and B apply without restructuring. Phase 1 bootstrap checks it.

---

## Appendix A. Review dispositions

### Review 1 (revision 2)

| Finding | Disposition |
|---|---|
| M1 `async_hooks` | Accepted; removed by L-REARM. |
| M2 elm/http not withdrawable | Accepted; L5/§5.3 (extended by N2, N3). |
| M3 MVar | Accepted as a finding; L7 dropped by user decision; §16. |
| M4, M5 grace hold | Accepted; the grace hold is dropped (not kept as a defence: unobservable, untestable), LIVE_004 + PS9 instead. |
| M6 eco `Process.spawn` | Accepted as a finding; unchanged by user decision; §16. |
| M7 inventory gaps | Accepted; rows added (§4.1). |
| M8 migration phases | Accepted; phases 4-5. |
| M9 host threads | Accepted; §5.1 Threads, PS7. |
| B1-B14 | Accepted. B8's fix (abort-on-close) was later withdrawn by N1, because B8's premise was false. |

### Review 2 (revision 3)

| Finding | Verified against | Disposition |
|---|---|---|
| N1 `close` abort contradicts the API | `Http/Server.elm:305-320`, `HttpTables.cpp:157-170` | Accepted; the abort and its doc sentence are dropped; the test is respecified with `closeWithin 300` (§2.2 note 2). |
| N2 queued requests never abort | `HttpService.cpp:31,300-320` | Accepted; `RequestControl` CAS claim (§5.3), `LiveHttpCancelQueuedTest`, PS11; Q (`curl_multi_wakeup`) closed. |
| N3 tracker reuse | `HttpExports.cpp:261-268` | Accepted; claim-or-abort of the old token (§5.3), `LiveHttpTrackerReuseTest`. |
| N4 held items | `HttpTables.cpp:216-224`; `Socket.js:349,459`; native held FIFOs hold nothing (`SocketTables.cpp:166`) | Accepted. Decision: held items hold nothing; the hold starts at delivery (LIVE-2, §2.2 note 3). Native: parked keys uncounted. JS: accepted sockets unref'd, per-connection HTTP handles. Tests `LiveListenerHeldTest`, `LiveHttpServerUnsubscribedTest` with a connected client. |
| N5 upgrade gap | `HttpTables.cpp:432-439`, `HttpUpgrade.cpp:209-221`, `WebSocket.cpp:463-465` | Accepted; `peerHold` hand-over (§10.6, L14), test with a sleep between upgrade and accept. |
| N6 phase 1 not behaviour-preserving | `Scheduler.cpp:664-668` | Accepted; acquire keeps the re-arm until phase 2 (now L-REARM's phase). |
| N7 ecosyskernel missing | `ecosyskernel/src/System.elm`, `docs.json` | Accepted; every doc/API change in both trees, docs.json equality gate (§10.0). |
| minor 1 `onQuiescent` catch path | `SystemManager.cpp:96-104` | Accepted; returns true, `reportFatal` `[[noreturn]]`. |
| minor 2 kernel wrapper placement, citation | `System.elm:682-704` | Accepted. |
| minor 3 "inside onEffects" on JS | `System.elm:589` | Accepted; reworded. |
| minor 4 bit per program run | — | Accepted; docstring states it; `OnEmptyEventLoopResubscribeTest`. |
| minor 5 job-queue count | — | Accepted; pinned at 3. |
| minor 6 token placement, counts | `Scheduler.cpp:701-716`, `MVar.cpp:64-84` | Accepted; resume-keyed `HoldToken` (§5.1) needs no side slot; the count is corrected to 85. |
| minor 7 sleep kill captures token | — | Accepted; `sleepKillEval`. |
| minor 8 curl abort details | `HttpExports.cpp:403-409,700-713` | Accepted; `g_httpControl` reachable from cancel; Risk 8. |
| minor 9 JS unref details | — | Accepted; per-connection handles; Q1 extended. |
| minor 10 PS re-baselining | `PlatformServicesTest.cpp:84-116` | Accepted; listeners return false, `removeQuiescenceListener`, isolated children. |

### User decisions applied in revision 3
- Q1 closed: `Http.track` with no tracked request in flight does not hold; it is not an
  exception.
- elm/http doc comments are not edited; the System module doc gains the elm/* paragraph (§9).
- eco/kernel is out of scope except for the mechanical migration (§16).
