//===- HttpTables.hpp - Eco-thread tables and events of Http.Server -------===//
//
// An HTTP server's sockets live on the reactor thread, while its requests are answered by Elm code on the eco thread
// (the thread that runs the Elm scheduler). This component is the eco-thread side of that split: it receives what the
// reactor reports, keeps track of every server and every request that is still owed an answer, and takes the holds
// that keep the program alive by the rules the third fact below lists.
//
// Everything rests on three facts.
//
// First, the reactor and the eco thread share no tables. The reactor reports through one queue of `HttpEvent`s,
// which `postHttpEvent` fills from any thread and a drain on the eco thread empties. The eco thread reaches the
// reactor only by submitting closures to it. An event is one of:
//   * Request: a complete request arrived on a connection, under a new *key*, the number that names that request
//     until it is answered.
//   * RespondDone: the transport took a response's bytes, or failed to.
//   * ConnGone: the connection of a request that was still owed an answer closed.
//   * ServerClosed: the reactor part of closing a server ran, so its listener is closed and the port is free.
//
// Second, a request can arrive while nothing in the program is subscribed to its server. Such a request is
// *parked*: kept, in arrival order, until a subscriber appears or the server closes. A server's parked requests are
// bounded at four times its `maxBodySize` in bytes, as `requestSize` in the source estimates them; a request that
// would go over the bound is answered 503, except that a server with nothing parked always accepts one.
// A parked request still waiting when its server is closed is answered 503 too. A request that is handed to a
// subscriber is *delivered*.
//
// Third, the program must not stop while a peer is owed an answer, and must not be kept alive by a server nobody
// asks for. Holds, the liveness counts `Liveness.hpp` defines, follow from that:
//   * A server holds nothing of its own. It holds one while an onRequest subscription names it and it is not
//     closed, as of the last `httpTablesSubscriptionsChanged`.
//   * A delivered request holds one from delivery until its key is erased, or until `httpTablesTakeUpgrade` hands
//     the hold to its caller. A parked request holds none.
//
// A delivered upgrade request whose connection closes (ConnGone) before the program takes it over is not erased:
// its key becomes a *tombstone*, which holds nothing (its hold, request and connection are released) and only
// remembers that the connection is gone, so that `httpTablesTakeUpgrade` can tell that from a key answered
// already. A tombstone is erased by that take, by a respond on its key, or when its server's ServerClosed is
// drained; so there is at most one per delivered upgrade request the program has not taken.
//   * A respond task and a closeServer task each hold one, under the resume token the caller passes, until their
//     RespondDone or ServerClosed is drained.
//   * An idle connection holds none.
//
// The tables are eco-thread only and hold no heap values: tokens are Scheduler resume tokens, and the taggers that
// turn a request into a message live in the manager, which the tables reach through `HttpManagerHooks`. They are
// keyed on the heap generation. When the heap is reset, the next use of the tables closes the old servers'
// listeners and aborts their connections on the reactor and empties the tables. The old holds, including those of
// waiting respond and closeServer tasks, need no release: the scheduler voided every hold of the old heap when it
// saw the new generation. Every event carries a heap generation, and the drain drops an event of an earlier
// generation unread.
//
//===----------------------------------------------------------------------===//

#ifndef ECO_SYSTEM_HTTP_SERVER_HTTP_TABLES_HPP
#define ECO_SYSTEM_HTTP_SERVER_HTTP_TABLES_HPP

#include "eco-system/HttpServer/HttpServerService.hpp"
#include "eco-system/Socket/Conn.hpp"           // TransportFactory
#include "eco-system/Socket/SocketEvents.hpp"   // SockEndpoint
#include "platform/Liveness.hpp"                // HoldToken

#include <cstdint>
#include <memory>
#include <string>
#include <utility>
#include <vector>

namespace Eco::System {

class Conn;

namespace HttpSrv {

struct ServerConfig;
struct ServerReactorState;

/// One complete request as it is handed to Elm, together with what taking it over as an upgrade needs: the raw
/// target, the version flags and the peer.
struct RequestData {
    std::string method;   ///< As received, such as `GET` or `OPTIONS`.
    std::string target;   ///< The request target exactly as received.
    std::string url;      ///< The absolute URL the target resolves to.
    std::vector<std::pair<std::string, std::string>> headers;   ///< In arrival order, names in their received case.
    std::string body;
    int64_t flags = 1;    ///< Bits 0-1 the version (0 HTTP/1.0, 1 HTTP/1.1, 2 HTTP/2), bit 2 set for TLS.
    std::string upgrade;  ///< The lower-cased upgrade token the request asks for, or empty for none.
    bool isHead = false;
    SockEndpoint remote;
};

/// One report from the reactor thread to the eco thread, of a kind the file comment lists.
///
/// Only the members a kind names are meaningful for it; the others keep their defaults.
struct HttpEvent {
    enum class Kind : uint8_t { Request, RespondDone, ConnGone, ServerClosed };
    Kind kind = Kind::RespondDone;
    uint64_t gen = 0;               ///< The heap generation the event belongs to; the drain drops an event of another.
    int64_t serverId = 0;           ///< Request, ConnGone, ServerClosed.
    int64_t key = 0;                ///< Request, ConnGone.
    uint64_t token = 0;             ///< RespondDone.
    std::weak_ptr<Conn> conn;       ///< Request.
    RequestData req;                ///< Request.
};

/// Queues `ev` for the drain and wakes the scheduler loop. May be called from any thread. `ensureHttpTables` is
/// meant to have been called on the eco thread first; until it has, no drain is registered to receive `ev`.
void postHttpEvent(HttpEvent ev);

/// Must be called on the eco thread. The first call creates the event queue, calls `ensureSocketEvents` (which
/// starts the reactor and registers the scheduler stop hook that closes its handlers), and adds the drain.
void ensureHttpTables();

/// Makes the listening socket `fd` into a server and returns the server's id. Eco thread only.
///
/// `fd` must be listening and non-blocking, and is owned by the server from now on. `cfg` is shared with the
/// reactor, and its `serverId` and `gen` are overwritten with the new id and the current heap generation. The
/// server accepts while fewer than `maxConnections` of its connections are open, or without limit when it is
/// negative, and gives each connection the protocol `makeServerProtocol` builds. `transport` builds each
/// connection's transport, such as TLS; when it is null the transport is plain TCP. The server takes no hold.
int64_t httpTablesStartServer(int fd, std::shared_ptr<ServerConfig> cfg, int64_t maxConnections,
                              TransportFactory transport = nullptr);

/// Answers the request `key` with `resp`, and returns false, doing nothing, when `key` is not in the table (already
/// answered, taken as an upgrade, its connection gone, or of an earlier heap). Eco thread only.
///
/// Otherwise it erases the key, releasing its hold, hands the response to the reactor and returns true. `token` is
/// the caller's resume token, which names its hold. When the RespondDone for this response is drained, whether or
/// not the response could be sent, the hold is released and the task is resumed with Unit unless it was killed.
bool httpTablesRespond(int64_t key, uint64_t token, ResponseData resp);

/// Closes the server `serverId`, and returns false, doing nothing, when there is no such server (never started,
/// already closed with its ServerClosed drained, or of an earlier heap). Eco thread only.
///
/// Otherwise it returns true. `token` is the caller's resume token naming its hold; when the ServerClosed is
/// drained the hold is released and the task is resumed with Unit unless it was killed. A server already closing
/// only adds `token` to those waiting. On the first call it releases the server's subscription hold, answers every
/// parked request 503, and asks the reactor to close the listener and to finish the server's connections, aborting
/// those still unfinished `deadlineMs` milliseconds from then (a negative value counts as 0), as
/// `http1ServerClosing` describes.
bool httpTablesCloseServer(int64_t serverId, int64_t deadlineMs, uint64_t token);

/// What `httpTablesTakeUpgrade` found.
enum class TakeUpgrade : uint8_t {
    Taken,     ///< The request was taken over.
    Gone,      ///< A tombstone: the request's connection closed before the take. The key is erased now.
    Refused,   ///< Not in the table (answered already, or of an earlier heap), parked, or not an upgrade request.
};

/// Takes over the upgrade request `key`. Eco thread only.
///
/// It returns `Refused`, changing nothing, when `key` is not in the table, is parked, or is not an upgrade request,
/// and `Gone`, erasing the key, when it is a tombstone (see the file comment). Otherwise it moves the request into
/// `out`, copies its connection into `conn`, and moves its delivery hold into `hold`, which the caller must release
/// from then on. It erases the key, so a later respond on it does nothing, and returns `Taken`.
TakeUpgrade httpTablesTakeUpgrade(int64_t key, RequestData& out, std::weak_ptr<Conn>& conn,
                           ::Elm::Platform::HoldToken& hold);

/// Tells the tables that the set of onRequest subscriptions has changed. Eco thread only.
///
/// It acquires or releases each server's subscription hold to match, and, if some server with a subscriber has
/// parked requests, asks the next drain pass to deliver them; they are never delivered from inside this call.
void httpTablesSubscriptionsChanged();

/// Removes the oldest queued event into `out` without handling it, and returns false when the queue is empty. For
/// tests that run without a scheduler loop.
bool httpTablesPopEventForTest(HttpEvent& out);

/// The two calls the tables make into the onRequest subscriptions, as plain function pointers so that the tables do
/// not depend on the effect manager that owns the subscriptions. A null `hasSubscriber` behaves as no subscriber.
struct HttpManagerHooks {
    /// Returns whether any onRequest subscription names `serverId`.
    bool (*hasSubscriber)(int64_t serverId) = nullptr;
    /// Must hand the request `key` of `serverId` to the subscriptions that name the server. It may run Elm code, so
    /// the tables look everything up again afterwards. Must be non-null whenever `hasSubscriber` can return true:
    /// a request otherwise takes its delivery hold and is not delivered.
    void (*deliver)(int64_t serverId, int64_t key, const RequestData& req) = nullptr;
};

/// Installs `hooks` in place of any installed before. Eco thread only. Until it is called no server has a
/// subscriber.
void setHttpManagerHooks(HttpManagerHooks hooks);

} // namespace HttpSrv
} // namespace Eco::System

#endif // ECO_SYSTEM_HTTP_SERVER_HTTP_TABLES_HPP
