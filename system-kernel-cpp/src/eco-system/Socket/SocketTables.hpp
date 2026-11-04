//===- SocketTables.hpp - Eco-thread socket tables and delivery -----------===//
//
// The Elm side of a stream socket lives on the eco thread, the thread that runs the Elm scheduler, while the sockets
// themselves are driven by `IoReactor` on the reactor thread. This component is the eco thread's record of every
// socket object it has handed to Elm code, and of every task waiting on one. Everything in it is touched on the eco
// thread only, which is why nothing here takes a lock.
//
// Three tables make up that record, in `SocketTables`:
//   * Listeners, by listener id. A `ListenerEntry` keeps the reactor's `ListenerHandler`, the endpoint it is bound
//     to, and the work waiting on it. A *parked accept* is an `accept` task waiting for a connection; its resume
//     token is queued oldest first. The *held FIFO* is the accepted connections nobody has taken yet. A listener is
//     *closing* once a `closeListener` task has started on it; the resume tokens of those tasks, its *close tokens*,
//     are completed when the reactor reports the listener closed.
//   * Connections, by connection id. A `ConnEntry` keeps the `Conn` and the two stream ids Elm code reads and writes
//     it through. To *materialize* a connection is to give an accepted or connected `Conn` an id, a `ConnEntry` and
//     its two streams; the entry is erased when the second of the two stream faces is destroyed.
//   * Pending connects, by the resume token of the `connect` task, so that killing the task can find the `Conn`.
//
// The tables hold no Elm heap values. A token names a resume closure the Scheduler keeps and roots, and the taggers
// of `onConnection` subscriptions are kept by the Socket effect manager, which this component reaches only through
// `socketManagerHasSubscribers` and `socketManagerDeliver`.
//
// Holds. A hold is what keeps the program running while something can still happen (`HoldRelease` and the Scheduler
// own the rule). An open listener holds nothing of its own. Each parked accept, each close token, each pending
// connect and each operation completed by an `OpDone` event holds by its resume token, and a listener named by an
// `onConnection` subscription takes one more, its *subscription hold* `subHold`. Connections in the held FIFO hold
// nothing. Each event dispatcher releases the holds its event completes; an event of an old heap generation is not
// dispatched, and the holds it would complete are not released.
//
// Delivery. An accepted connection is appended to its listener's held FIFO, and the FIFO is then served from the
// front: each connection goes to the oldest parked accept, or, when none is parked, to every `onConnection` tagger of
// the listener, and it stays held while there is neither. Held connections are therefore delivered in the order they
// were accepted. A closing listener delivers nothing; its held connections are aborted.
//
// Heap generations. The tables belong to one heap generation (`currentHeapGeneration`). When `socketTables` finds the
// generation changed, the tables of the old heap are reset first: every listener, connection and pending connect is
// closed or aborted on the reactor and the tables are cleared. The holds the old tables owned (subscriptions, parked
// accepts, close tokens, pending connects, operations whose `OpDone` is still in flight) need no release: the
// scheduler voided every hold of the old heap when it saw the new generation. The id counters are not reset.
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

/// One listener Elm code has opened, with the tasks and connections waiting on it.
///
/// Plain data. Each resume token in `parkedAccepts` and `closeTokens` carries the hold of its task; `held` carries
/// none.
struct ListenerEntry {
    std::shared_ptr<ListenerHandler> handler;
    SockEndpoint bound;
    std::deque<uint64_t> parkedAccepts;   ///< Resume tokens of parked accepts, oldest first.
    std::deque<SocketEvent> held;         ///< `Accepted` events not yet delivered, oldest first.
    HoldToken subHold = kNoHold;          ///< The subscription hold, or `kNoHold` when none is taken.
    bool subscribed = false;              ///< The last value sent to the handler's `setUnlimited`.
    bool closing = false;                 ///< Set once a `closeListener` task has started; never cleared.
    std::vector<uint64_t> closeTokens;    ///< Resume tokens of the `closeListener` tasks, one per call.
};

/// One materialized connection: the `Conn` and what Elm code needs to name and describe it.
///
/// Plain data. `cred` means something only when `hasCred` is set, and `tls` only when `isTls` is set. The entry is
/// erased by `socketTablesFaceGone` when `facesAlive` reaches zero.
struct ConnEntry {
    std::shared_ptr<Conn> conn;
    int64_t readableId = 0, writableId = 0;   ///< Stream ids of the read and write faces.
    Cred cred;
    bool hasCred = false;
    TlsInfo tls;
    bool isTls = false;
    bool isUnix = false;
    int facesAlive = 2;   ///< How many of the two stream faces have not yet been destroyed.
};

/// The eco thread's socket tables for one heap generation, as the file comment describes.
///
/// Plain data, reached through `socketTables`. Listener and connection ids come from `nextListenerId` and
/// `nextConnId`, which start at 1 and are not reset with the tables, so an id is not reused within the process.
/// `pendingConnects` is keyed by the connect task's resume token.
struct SocketTables {
    std::unordered_map<int64_t, ListenerEntry> listeners;
    std::unordered_map<int64_t, ConnEntry> conns;
    std::unordered_map<uint64_t, std::shared_ptr<Conn>> pendingConnects;
    int64_t nextListenerId = 1;
    int64_t nextConnId = 1;
    uint64_t gen = 0;    ///< The heap generation the tables belong to; meaningful only once `init` is set.
    bool init = false;   ///< Set by the first call of `socketTables`.
};

/// Returns the tables of the current heap generation, resetting them first, as the file comment describes, if the
/// generation has changed since the last call. The tables are created on the first call and never freed. Eco thread
/// only.
SocketTables& socketTables();

/// Returns the entry of listener `id`, or null if there is none. The pointer is valid until the entry is erased or
/// the tables are reset; running Elm code can do either, so look the entry up again after it.
ListenerEntry* findListener(int64_t id);

/// Returns the entry of connection `id`, or null if there is none. The pointer is valid until the entry is erased
/// or the tables are reset; running Elm code can do either, so look the entry up again after it.
ConnEntry* findConn(int64_t id);

/// Makes sure the socket event queue exists (`ensureSocketEvents`) and installs this component's dispatch functions
/// for `Connected`, `Accepted`, `OpDone` and `ListenerClosed` events; the dispatch functions are installed on the
/// first call only. Eco thread only.
void ensureSocketTables();

/// Materializes the connection carried by `ev`, an `Accepted` or successful `Connected` event, and returns its new
/// connection id.
///
/// Adds a `ConnEntry` copying the event's credentials, TLS information and Unix flag, and creates a readable and a
/// writable stream over `ev.conn` whose ids it records. `ev` is not changed. Allocates nothing on the Elm heap. Eco
/// thread only.
int64_t materializeConnection(SocketEvent& ev);

/// Builds the Elm value of endpoint `ep`: a triple of its kind, its text and its port. The result is not rooted.
HPointer buildEndpoint(const SockEndpoint& ep);

/// Builds the Elm value of connection `connId`: `( connId, ( readableId, writableId ), ( local, remote ) )`, with
/// the stream ids from its `ConnEntry` (both 0 if there is none) and the endpoints from `ev`. The result is not
/// rooted.
HPointer buildConnT(int64_t connId, const SocketEvent& ev);

/// Builds the Elm value of listener `listenerId`: `( listenerId, endpoint )`, with `bound` built by
/// `buildEndpoint`. The result is not rooted.
HPointer buildListenT(int64_t listenerId, const SockEndpoint& bound);

/// Records that one stream face of connection `connId` was destroyed, and erases its entry when it was the second.
/// Does nothing for an unknown id.
void socketTablesFaceGone(int64_t connId);

/// Brings every listener in line with the Socket effect manager's current subscriptions.
///
/// For each listener that is not closing and has a handler, the subscription hold is taken while some subscription
/// names it and released otherwise, and the handler is told through `setUnlimited` to accept every connection while
/// it is named. A closing listener, or one without a handler, loses its subscription hold. If a named listener has
/// held connections, their delivery is requested from the socket event drain (`requestSocketWork`) rather than made
/// here. Eco thread only.
void socketTablesSyncSubscriptions();

/// Kills the pending connect whose task has resume token `token`. Returns false if there is no such pending connect
/// (its result was handled, or a heap reset cleared it) or if the result was claimed before the cancel, and true if
/// the connect will report nothing. A pending connect that is found is removed whatever the result. The hold is not
/// released here.
/// A kill function for `makeKillHandle`.
bool cancelPendingConnect(uint64_t token);

/// Kills the parked accept with resume token `token`. Returns true if it was still parked, after removing it and
/// taking back the credit it gave its listener (unless the listener is closing); false otherwise. The hold is not
/// released here. A kill function for `makeKillHandle`.
bool cancelParkedAccept(uint64_t token);

// Defined by the Socket effect manager (SocketManager.cpp).

/// Returns whether any `onConnection` subscription names listener `listenerId`.
bool socketManagerHasSubscribers(int64_t listenerId);

/// Sends `connT` to the application through every `onConnection` tagger of listener `listenerId`, draining the
/// Scheduler after each message. `connT` must be rooted by the caller, and may be updated by a collection.
void socketManagerDeliver(int64_t listenerId, HPointer& connT);

} // namespace Eco::System

#endif // ECO_SYSTEM_SOCKET_SOCKET_TABLES_HPP
