//===- SocketTables.hpp - Main-thread socket tables and delivery ----------===//
//
// plans/eco-system-sockets.md §3.3.4 "Main thread", §3.3.8, §3.3.9, §3.4.
// Main thread only (G1, no mutex). The tables hold NO HPointers: tokens are
// Scheduler resume tokens (the resumes are rooted by the Scheduler) and the
// taggers live in the managers. They are keyed on the heap generation (as a
// T5 Registry): on a new generation every entry's reactor object is closed
// first (submit abort / close; its counts died with the heap) and the
// tables are cleared.
//
//   * ListenerEntry: the ListenerHandler, the bound endpoint, the parked
//     accept tokens (oldest first), the held FIFO of accepted connections
//     nobody took yet (SD14), the closing state with the closeListener
//     tokens, and whether the listener still holds its pendingAsync count.
//   * ConnEntry: the Conn, its two stream ids, the Unix credentials and TLS
//     info captured as POD, and how many faces are alive (erased with the
//     second face).
//   * pending connects: resume token → client Conn, for the T7 kill race.
//
// Delivery (§3.4): an accepted connection goes to the oldest parked accept
// of its listener, else to every onConnection tagger of the listener (the
// "Socket" manager), else into the held FIFO; held items are served first,
// in order, whenever a consumer appears.
//
// The event dispatchers (Connected, Accepted, OpDone, ListenerClosed) are
// registered by ensureSocketTables(); each releases exactly the counts its
// event carries (G10, §3.3.8).
//
// Templates used: T5 (heap-generation keyed tables), T8 (delivery through
// the manager), T9/G10 (completions), G12.
//
//===----------------------------------------------------------------------===//

#ifndef ECO_SYSTEM_SOCKET_SOCKET_TABLES_HPP
#define ECO_SYSTEM_SOCKET_SOCKET_TABLES_HPP

#include "eco-system/Core/Core.hpp"
#include "eco-system/Socket/Conn.hpp"
#include "eco-system/Socket/Listener.hpp"
#include "eco-system/Socket/SocketEvents.hpp"

#include <cstdint>
#include <deque>
#include <memory>
#include <unordered_map>
#include <vector>

namespace Eco::System {

struct ListenerEntry {
    std::shared_ptr<ListenerHandler> handler;
    SockEndpoint bound;
    std::deque<uint64_t> parkedAccepts;   // resume tokens, oldest first (no count of their own)
    std::deque<SocketEvent> held;         // Accepted events nobody took yet
    bool counted = true;                  // holds the open listener's pendingAsync count
    bool subscribed = false;              // setUnlimited(true) was sent
    bool closing = false;                 // closeListener started
    std::vector<uint64_t> closeTokens;    // closeListener tasks (one count each)
};

struct ConnEntry {
    std::shared_ptr<Conn> conn;
    int64_t readableId = 0, writableId = 0;
    Cred cred;
    bool hasCred = false;
    TlsInfo tls;
    bool isTls = false;
    bool isUnix = false;
    int facesAlive = 2;
};

struct SocketTables {
    std::unordered_map<int64_t, ListenerEntry> listeners;
    std::unordered_map<int64_t, ConnEntry> conns;
    std::unordered_map<uint64_t, std::shared_ptr<Conn>> pendingConnects;
    int64_t nextListenerId = 1;
    int64_t nextConnId = 1;
    uint64_t gen = 0;
    bool init = false;
};

// Main thread. The tables of the current heap generation (reset first if
// the generation changed). Never hold an entry pointer across an
// allocation or an Elm call: look it up again (G11).
SocketTables& socketTables();
ListenerEntry* findListener(int64_t id);
ConnEntry* findConn(int64_t id);

// Main thread: registers the event dispatchers (and ensureSocketEvents()).
// Every socket kernel body calls it first. Idempotent.
void ensureSocketTables();

// A connected Conn (Connected / Accepted event) becomes a Connection: two
// stream pairs over the faces and a ConnEntry. No heap allocation. Returns
// the connection id.
int64_t materializeConnection(SocketEvent& ev);

// EpT / ConnT / ListenT values (§3.2). Allocate; the results are fresh
// (the caller roots them).
HPointer buildEndpoint(const SockEndpoint& ep);
HPointer buildConnT(int64_t connId, const SocketEvent& ev);
HPointer buildListenT(int64_t listenerId, const SockEndpoint& bound);

// A face of connection `connId` was destroyed (ConnChannel.cpp).
void socketTablesFaceGone(int64_t connId);

// The "Socket" manager changed its subscriptions: sends setUnlimited to
// every listener whose subscribed state changed and schedules the delivery
// of held connections (from the socket drain, not from onEffects).
void socketTablesSyncSubscriptions();

// T7 CancelFns.
bool cancelPendingConnect(uint64_t token);   // true iff the connect never resolved
bool cancelParkedAccept(uint64_t token);     // always false (A mode holds no count)

// --- Manager hooks (SocketManager.cpp) ----------------------------------------
bool socketManagerHasSubscribers(int64_t listenerId);
// Calls every tagger of the listener with `connT` (rooted by the caller),
// sendToApp + drain() per message (T8, G12).
void socketManagerDeliver(int64_t listenerId, HPointer& connT);

} // namespace Eco::System

#endif // ECO_SYSTEM_SOCKET_SOCKET_TABLES_HPP
