//===- HttpTables.hpp - Main-thread tables and events of Http.Server ------===//
//
// plans/eco-system-websockets.md §3.4 "Main-thread tables", "respond",
// "closeServer", "Keep-alive counts", "Manager" (phase WS2).
//
// Events (reactor → main thread): one POD queue, drained by an eco/system
// async source on the main thread (the SocketEvents pattern, sockets plan
// §3.3.2). Every event carries the heap generation of its server; an event
// of a dead heap releases nothing (its counts died with the heap).
//   * Request{serverId, key, request}: a complete request (Http1.cpp).
//   * RespondDone{token}: a response's bytes were taken by the transport
//     (or failed): the respond task completes.
//   * ConnGone{serverId, key}: the connection of a delivered request closed
//     before the answer.
//   * ServerClosed{serverId}: closeServer's reactor part ran (the listener
//     is closed, the port is free).
//
// Tables (main thread only, keyed on heap generation as a T5 Registry, no
// HPointers: tokens are Scheduler resume tokens, taggers live in the
// manager):
//   * HttpServers: id → the ListenerHandler, the reactor-side state, the
//     config, the closed flag, the closeServer tokens and the requests
//     parked while the server had no subscriber (bounded: maxBodySize × 4
//     bytes per server, beyond it answered 503).
//   * HttpKeys: key → the server, the connection (weak), and while parked
//     the request itself. Keys are erased by respond, takeUpgrade (WS5),
//     ConnGone, closeServer (parked: 503) and a new heap generation.
//
// Keep-alive counts (§3.4): a server holds one until ServerClosed; every
// key holds one until it is erased; a respond task holds one until its
// RespondDone; a closeServer task until ServerClosed. Idle connections
// hold none.
//
// Templates used: T5 (generation-keyed tables), T8/G12 via the manager,
// G10 (AsyncRelease on every count).
//
//===----------------------------------------------------------------------===//

#ifndef ECO_SYSTEM_HTTP_SERVER_HTTP_TABLES_HPP
#define ECO_SYSTEM_HTTP_SERVER_HTTP_TABLES_HPP

#include "eco-system/HttpServer/HttpServerService.hpp"
#include "eco-system/Socket/Conn.hpp"           // TransportFactory
#include "eco-system/Socket/SocketEvents.hpp"   // SockEndpoint

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

// A complete request as the manager hands it to Elm (C.1), plus what the
// WS5 hand-off needs (the raw target, the version, the peer).
struct RequestData {
    std::string method;   // "GET", "OPTIONS", ...
    std::string target;   // the raw request target
    std::string url;      // absolute (E.5)
    std::vector<std::pair<std::string, std::string>> headers;   // arrival order, raw case
    std::string body;
    int64_t flags = 1;    // C.1: bits 0-1 version (0 = 1.0, 1 = 1.1, 2 = 2), bit 2 TLS
    std::string upgrade;  // lower-cased upgrade token, "" = none
    bool isHead = false;
    SockEndpoint remote;
};

struct HttpEvent {
    enum class Kind : uint8_t { Request, RespondDone, ConnGone, ServerClosed };
    Kind kind = Kind::RespondDone;
    uint64_t gen = 0;
    int64_t serverId = 0;
    int64_t key = 0;                // Request, ConnGone
    uint64_t token = 0;             // RespondDone
    std::weak_ptr<Conn> conn;       // Request
    RequestData req;                // Request
};

// Any thread. Queues `ev` and wakes the scheduler loop. The queue must have
// been created on the main thread first (ensureHttpTables).
void postHttpEvent(HttpEvent ev);

// Main thread: creates the queue (binding the Scheduler), registers the
// drain and the socket stop hook. Idempotent.
void ensureHttpTables();

// Main thread: a listening fd (non-blocking, cloexec; owned from now on)
// becomes a server: a ListenerHandler in callback mode (the connection's
// protocol from makeServerProtocol once its handshake is done,
// maxConnections < 0: unlimited), the table entry and the server's
// keep-alive count. `transport`: the TLS transport factory of an https
// server (WS3, websockets plan §3.5), null for plain TCP. Returns the
// server id.
int64_t httpTablesStartServer(int fd, std::shared_ptr<ServerConfig> cfg, int64_t maxConnections,
                              TransportFactory transport = nullptr);

// Main thread, from the respond body: false when `key` is unknown
// (answered, gone, or of a dead heap: complete at once). Otherwise erases
// the key (releasing its count) and submits the response; `token` (a
// registered resume holding its own count) completes through RespondDone.
bool httpTablesRespond(int64_t key, uint64_t token, ResponseData resp);

// Main thread, from the closeServer body: false when the server is unknown
// or already closed and its ServerClosed was drained (complete at once).
// Otherwise `token` (registered, counted) completes on ServerClosed.
bool httpTablesCloseServer(int64_t serverId, int64_t deadlineMs, uint64_t token);

// Main thread, for WS5's takeUpgrade (HttpUpgrade.cpp): when `key` is an upgrade request still
// waiting for its answer, moves its request (raw target, headers with
// duplicates and original case, version flags, peer) into `out`, its
// connection into `conn`, erases the key (releasing its count: a later
// respond on it completes at once) and returns true. The caller then
// submits Http1Protocol::takeUpgradeHead + Conn::setProtocol to the reactor.
bool httpTablesTakeUpgrade(int64_t key, RequestData& out, std::weak_ptr<Conn>& conn);

// Main thread: the manager's subscriptions changed (onEffects): parked
// requests of servers that now have a subscriber are delivered from the
// drain (never from onEffects itself).
void httpTablesSubscriptionsChanged();

// Tests only (EcoSystemCoreTest.cpp, no scheduler loop): pops the oldest
// queued event without handling it.
bool httpTablesPopEventForTest(HttpEvent& out);

// --- Manager hooks (HttpServerManager.cpp) -------------------------------------
// Registered by the manager's registration (function pointers, so the tables
// do not link the manager: the Core unit test drives them without one).
// Without hooks no server has a subscriber.
struct HttpManagerHooks {
    bool (*hasSubscriber)(int64_t serverId) = nullptr;
    // Calls every tagger of the server with the request (T8, G12: sendToApp +
    // drain() per tagger). Runs Elm: callers re-look-up everything afterwards.
    void (*deliver)(int64_t serverId, int64_t key, const RequestData& req) = nullptr;
};
void setHttpManagerHooks(HttpManagerHooks hooks);

} // namespace HttpSrv
} // namespace Eco::System

#endif // ECO_SYSTEM_HTTP_SERVER_HTTP_TABLES_HPP
