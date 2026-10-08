//===- WsEvents.hpp - WebSocket results to the main thread ----------------===//
//
// plans/eco-system-websockets.md §3.6 "Results to the main thread": message
// data travels on the channel-results queue (the mapped readable,
// ByteChannel.hpp); every other WebSocket result is one POD WsEvent on this
// queue (the sockets plan §3.3.2 pattern, as SocketEvents), posted by the
// IoReactor thread and drained on the main thread by a drain registered with
// the eco/system async source.
//
//   * Dialed: a client handshake ended (dial): the HTTP status and response
//     headers, the Conn (held by a HoldProtocol until open), or a failure.
//   * UpgradeRead: a socket-level opening request was read (readUpgrade).
//   * Opened: open installed the codec (endpoints), or failed.
//   * OpDone: an R-mode operation finished (close, reject).
//   * PingDone: a ping's pong arrived (rtt), or the ping failed.
//   * Closed: a WebSocket ended: ( code, reason, clean ).
//   * BodyNeeded (WS6): a streamed message started: create its body's
//     stream pair on the main thread and hand the id to the core
//     (WsCore::bodyReady).
//   * BodyDispose (WS6): a body's pair that nobody can receive any more.
//
// The drain hands each event to the dispatch function registered for its
// kind (WsTables.cpp) and calls Scheduler::drain() after every event that
// resumed a task or delivered a message (G12; the dispatcher returns true).
// Events of an older heap generation are dropped after releasing their OS
// resources (an orphaned Conn is aborted), never resumed or counted (F24).
// requestWsWork(fn) runs `fn` from the drain (the manager's deferred held-
// close deliveries).
//
// Lock order (sockets plan §3.3.1 rule 6): IoReactor command mutex → this
// queue's mutex → Scheduler mutex.
//
// Templates used: T8/G12 (drain side), G10 (dispatchers own the counts).
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

struct WsEvent {
    enum class Kind : uint8_t { Dialed, UpgradeRead, Opened, OpDone, PingDone, Closed, BodyNeeded, BodyDispose };
    static constexpr int kKinds = 8;

    Kind kind = Kind::OpDone;
    uint64_t gen = 0;                 // heap generation of the originating main-thread object
    uint64_t token = 0;               // the task's resume token (0: none)
    int64_t wsId = 0;                 // Opened / PingDone / Closed
    bool failed = false;              // failure: code + message (FErr)
    std::string code, message;
    std::shared_ptr<Conn> conn;       // Dialed / UpgradeRead: the held connection
    // Dialed: the response; UpgradeRead: the request.
    int64_t status = 0;
    bool isH2 = false;
    std::string method, target, version;
    std::vector<std::pair<std::string, std::string>> headers;   // in order, original case
    SockEndpoint local, remote;       // UpgradeRead / Opened
    bool isTls = false;
    int64_t rtt = 0;                  // PingDone
    int closeCode = 0;                // Closed
    std::string reason;
    bool clean = false;
    uint64_t bodySeq = 0;             // BodyNeeded: the body's sequence number in its core
    bool bodyText = false;            // BodyNeeded: a text body (String chunks)
    int64_t pairId = 0;               // BodyDispose: the stream pair
};

// Main thread: creates the queue (binding the Scheduler on the main thread),
// registers the drain. Idempotent; every WebSocket kernel body calls it
// (through ensureWsTables) before it submits reactor work.
void ensureWsEvents();

// Any thread. Queues `ev` and wakes the scheduler loop.
void postWsEvent(WsEvent ev);

// Main thread. Returns true if it resumed a task or delivered a message.
using WsEventDispatchFn = bool (*)(WsEvent& ev);
void setWsEventDispatch(WsEvent::Kind kind, WsEventDispatchFn fn);

// Main thread. Runs `fn` from the drain soon (deduplicated by function).
using WsWorkFn = void (*)();
void requestWsWork(WsWorkFn fn);

// Main thread (the drain, or a test).
void wsEventsDrain();

} // namespace Eco::System

#endif // ECO_SYSTEM_WEBSOCKET_WS_EVENTS_HPP
