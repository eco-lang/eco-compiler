//===- WsEvents.hpp - WebSocket results to the eco thread -----------------===//
//
// WebSocket I/O runs on the IoReactor thread, but the tasks waiting for its results live on the eco thread, which
// alone may touch the Elm heap. This component carries those results across. Message data travels on the
// channel-results queue of `ByteChannel.hpp`; every other WebSocket result is one `WsEvent`, a plain record holding
// no Elm heap pointers, posted on a single queue from any thread and drained on the eco thread. It is the WebSocket
// counterpart of `SocketEvents.hpp`, and works the same way.
//
// The drain is added with `addDrainSource`; its ready predicate reads only atomic values, so it takes no lock. On
// each pass it first runs the requested work (below), then pops events one at a time and hands each to the
// dispatch function registered for its kind. When the dispatch function returns true, the drain calls
// `Scheduler::drain()` before taking the next event.
//
// Heap generation: every event carries `gen`, the heap generation (`currentHeapGeneration`) taken on the eco thread
// when the operation or the object behind the event began. An event of an older generation refers to tokens and
// counts that died with the old heap, so the drain does not dispatch it; it only aborts the connection the event
// carries, if any, on the reactor. An event whose kind has no dispatch function is released the same way. Such an
// event is called an orphan.
//
// WebSocket work: `requestWsWork(fn)` asks the drain to call `fn` on its next pass, once however often it was
// requested before then. It lets code that must not deliver messages itself (an effect manager's onEffects) have
// eco-thread work done soon after.
//
// An exception that escapes a dispatch function or a work function is reported with `reportFatal`; it never unwinds
// into the scheduler loop.
//
//===----------------------------------------------------------------------===//

#ifndef ECO_SYSTEM_WEBSOCKET_WS_EVENTS_HPP
#define ECO_SYSTEM_WEBSOCKET_WS_EVENTS_HPP

#include "eco-system/Socket/SocketEvents.hpp"

#include <cstdint>
#include <memory>
#include <string>
#include <utility>
#include <vector>

namespace Eco::System {

class Conn;

/// One WebSocket result on its way to the eco thread.
///
/// Which members are meaningful depends on `kind`; the rest keep their defaults. The record holds no Elm heap
/// pointers, so it may be built on any thread and may outlive a heap reset.
struct WsEvent {
    /// The kind of result, which selects the dispatch function.
    ///
    /// `Dialed`: a client opening handshake ended, with the response's status and headers and the connection, or
    /// failed. `UpgradeRead`: an opening request was read from a server-side connection, or reading it failed.
    /// `Opened`: the WebSocket codec was installed on the connection, with its endpoints, or could not be.
    /// `OpDone`: a close or reject operation finished. `PingDone`: a ping was answered, with its round-trip time,
    /// or failed. `Closed`: a WebSocket ended. `BodyNeeded`: a streamed message started, and its body needs a stream
    /// pair created on the eco thread. `BodyDispose`: a body's stream pair can no longer be received and is to be
    /// discarded. `HandshakeGone`: the connection of a server handshake taken from `Http.Server` is gone before the
    /// handshake was answered.
    enum class Kind : uint8_t { Dialed, UpgradeRead, Opened, OpDone, PingDone, Closed, BodyNeeded, BodyDispose,
                                HandshakeGone };
    /// The number of `Kind` enumerators: the size of the dispatch table. Nothing checks that the two agree.
    static constexpr int kKinds = 9;

    Kind kind = Kind::OpDone;
    uint64_t gen = 0;                 ///< Heap generation; see the file comment.
    uint64_t token = 0;               ///< The waiting task's resume token; 0 if no task waits.
    int64_t wsId = 0;                 ///< The WebSocket's id; for HandshakeGone, the handshake id.
    bool failed = false;              ///< True if the operation failed; `code` and `message` then describe it.
    std::string code, message;
    /// Dialed and UpgradeRead that succeeded: the connection, kept alive while the event is in transit. An orphan's
    /// connection is aborted.
    std::shared_ptr<Conn> conn;
    // Dialed: the response's status and headers. UpgradeRead: the request's method, target, version and headers.
    int64_t status = 0;
    bool isH2 = false;                ///< Dialed: true if the handshake ran over HTTP/2.
    std::string method, target, version;
    std::vector<std::pair<std::string, std::string>> headers;
    SockEndpoint local, remote;       // UpgradeRead, Opened
    bool isTls = false;               ///< Dialed, UpgradeRead: true if the connection is TLS.
    int64_t rtt = 0;                  ///< PingDone: the round-trip time in milliseconds.
    // Closed: the close code and reason, and whether the closing handshake completed.
    int closeCode = 0;
    std::string reason;
    bool clean = false;
    uint64_t bodySeq = 0;             ///< BodyNeeded: the body's sequence number within its WebSocket.
    bool bodyText = false;            ///< BodyNeeded: true for a text body.
    int64_t pairId = 0;               ///< BodyDispose: the stream pair to discard.
};

/// Sets up the event queue, once; later calls do nothing. Must be called on the eco thread (its once-flag is not
/// locked) before any event is posted. It calls `ensureSocketEvents`, which starts the IoReactor, and adds the drain.
void ensureWsEvents();

/// Queues `ev` for the drain and wakes the scheduler loop. May be called on any thread. No other lock is taken while
/// the queue's mutex is held: the scheduler is woken after it is released.
void postWsEvent(WsEvent ev);

/// A function that handles events of one kind on the eco thread, called by the drain with each such event of the
/// current heap generation. It may move from the event. Returns true to have the drain call `Scheduler::drain()`,
/// which it needs when it resumed a task or delivered a message without draining.
using WsEventDispatchFn = bool (*)(WsEvent& ev);

/// Makes `fn` the dispatch function for events of `kind`, replacing any earlier one; null removes it, and events of
/// that kind are then released as orphans. Eco thread only.
void setWsEventDispatch(WsEvent::Kind kind, WsEventDispatchFn fn);

/// A function the drain calls on the eco thread at a caller's request. The drain does not call `Scheduler::drain()`
/// after it, so it must do so itself if it resumed or delivered anything.
using WsWorkFn = void (*)();

/// Asks the drain to call `fn` on its next pass. A function requested again before that pass runs is still called
/// once. A request made while the work is running is served on a later pass. Eco thread only: the work list is not
/// locked.
void requestWsWork(WsWorkFn fn);

/// Runs one pass of the drain: the requested work, then every queued event, as the file comment describes. Eco
/// thread only. It is the drain `ensureWsEvents` adds.
void wsEventsDrain();

} // namespace Eco::System

#endif // ECO_SYSTEM_WEBSOCKET_WS_EVENTS_HPP
