//===- WsTables.hpp - Main-thread WebSocket tables ------------------------===//
//
// plans/eco-system-websockets.md §3.6 (phase WS4). Main thread only (G1, no
// mutex). The tables hold NO HPointers (tokens are Scheduler resume tokens;
// the message taggers live in the manager, WsManager.cpp; fromWire/toWire
// live in the stream pairs), so they need no root scanner. They are keyed
// on the heap generation (T5): on a new generation every entry's reactor
// object is closed first (its counts and tokens died with the heap).
//
//   * handshakes: hsId / upId → the Conn parked in a HoldProtocol after
//     `dial` (client), `readUpgrade` (server) or Http.Server's `takeUpgrade`
//     (server, WS5), until `open`, `reject` or `abandon` consumes it. All
//     kinds share one id space (`open` takes any).
//   * sockets: wsId → the WsCore, its stream pair ids, the Closed state and
//     CloseInfo, the parked `closed` tasks, and the keep-alive counts of
//     §3.6: the close handshake (from a local close until Closed) and one
//     count per parked `closed` task (the R-mode operations hold their own
//     until their WsEvent). Entries stay after Closed (so `closed` answers
//     late callers) until both stream faces are gone; then only the
//     CloseInfo is kept, in a bounded FIFO of recently closed ids.
//   * pending dials: resume token → DialJob, for the T7 kill race.
//
// The WsEvent dispatchers (Dialed, UpgradeRead, Opened, OpDone, PingDone,
// Closed) are registered by ensureWsTables(); each releases exactly the
// count its event carries (G10).
//
// Templates used: T5 (generation-keyed tables, POD only), T9/G10
// (completions), G12.
//
//===----------------------------------------------------------------------===//

#ifndef ECO_SYSTEM_WEBSOCKET_WS_TABLES_HPP
#define ECO_SYSTEM_WEBSOCKET_WS_TABLES_HPP

#include "eco-system/Core/Core.hpp"
#include "eco-system/Socket/Conn.hpp"
#include "eco-system/WebSocket/H2StreamPort.hpp"
#include "eco-system/WebSocket/WsEvents.hpp"
#include "eco-system/WebSocket/WsHandshake.hpp"
#include "eco-system/WebSocket/WsProtocol.hpp"

#include <cstdint>
#include <deque>
#include <memory>
#include <string>
#include <unordered_map>
#include <vector>

namespace Eco::System {

struct WsHandshakeEntry {
    std::shared_ptr<Conn> conn;
    bool server = false;
    std::shared_ptr<H2PendingUpgrade> h2;   // WS9: an h2 extended CONNECT (conn is null)
};

struct WsCloseInfo {
    int code = 1006;
    std::string reason;
    bool clean = false;
};

struct WsEntry {
    std::shared_ptr<WsCore> core;
    int64_t readableId = 0, writableId = 0;
    bool closed = false;
    WsCloseInfo info;
    bool closeDelivered = false;          // the onClose subscribers got it (C.2)
    std::vector<uint64_t> closedWaiters;  // parked `closed` tasks (one count each)
    bool closeCounted = false;            // the close handshake's count (§3.6)
    int facesAlive = 2;
    uint64_t outSeq = 0;                  // outgoing streams opened (openOutgoing, WS6)
};

struct WsTables {
    std::unordered_map<int64_t, WsHandshakeEntry> handshakes;
    std::unordered_map<int64_t, WsEntry> sockets;
    std::unordered_map<uint64_t, std::shared_ptr<DialJob>> pendingDials;
    std::deque<std::pair<int64_t, WsCloseInfo>> recentlyClosed;   // bounded
    int64_t nextHsId = 1;
    int64_t nextWsId = 1;
    uint64_t gen = 0;
    bool init = false;
};

// Main thread. The tables of the current heap generation (reset first if
// the generation changed). Never hold an entry pointer across an
// allocation or an Elm call: look it up again (G11).
WsTables& wsTables();
WsEntry* findWs(int64_t wsId);

// Main thread: registers the WsEvent dispatchers (and the socket tables,
// for readUpgrade). Every WebSocket kernel body calls it first. Idempotent.
void ensureWsTables();

// Main thread (Http.Server.upgradeRequest, WS5): registers a server
// connection taken from Http.Server as a handshake id (the id space of
// readUpgrade / dial). The caller parks it in a HoldProtocol on the reactor
// (before any `open` is submitted). Holds no keep-alive count.
int64_t wsTablesAddServerHandshake(std::shared_ptr<Conn> conn);
// The same for an HTTP/2 extended CONNECT stream (WS9): open / reject /
// abandon go through `h2` on the reactor.
int64_t wsTablesAddServerH2Handshake(std::shared_ptr<H2PendingUpgrade> h2);

// The CloseInfo of a WebSocket that is gone from `sockets` (or Abnormal).
WsCloseInfo wsRecentCloseInfo(int64_t wsId);

// A local close started (close, closeWritable, cancelWritable): takes the
// close handshake's keep-alive count once, released by the Closed event.
void wsTablesCloseStarted(int64_t wsId);
// A stream face of `wsId` was destroyed (WsChannel.cpp).
void wsTablesFaceGone(int64_t wsId);
// Erases a Closed WebSocket whose faces are gone and that nobody subscribes
// to any more (the manager calls it when subscriptions go away).
void wsTablesRetire(int64_t wsId);

// T7 CancelFns.
bool cancelPendingDial(uint64_t token);      // true iff the dial never resolved
bool cancelClosedWaiter(uint64_t token);     // true iff the parked `closed` was removed

// List ( String, List String ): one element per header line, in order.
// Allocates; the result is fresh.
HPointer buildHeaderList(const HeaderList& headers);

} // namespace Eco::System

#endif // ECO_SYSTEM_WEBSOCKET_WS_TABLES_HPP
