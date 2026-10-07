//===- HttpServerService.hpp - Sockets and threads behind Http.Server -----===//
//
// plans/eco-system-library.md §3.4, Phase 7 step 7.2, Appendix B.6 / E.5.
// The POD half of the HttpServer kernel module: no heap access, no Elm
// calls, no Debug.log anywhere in here (G1).
//
//   * listenOn (a SysWorkPool worker, P mode): resolve the host, socket,
//     SO_REUSEADDR, bind, listen. Every fd is O_CLOEXEC (§3.4).
//   * startServer (main thread): one detached ACCEPT thread per server. A
//     server is never closed (there is no close in the v1 API), so the
//     accept thread blocks in accept() for the life of the process.
//   * One detached CONNECTION thread per client. It polls {socket, wake
//     pipe}, feeds llhttp, and when the first request is complete posts a
//     POD RequestEvent (absolute URL per E.5) and waits on its wake pipe for
//     the response. respond() (main thread) hands the response over and
//     writes the wake pipe; the connection thread writes HTTP/1.1 with
//     Content-Length and Connection: close, closes the socket and posts a
//     ResponseDone for the respond task (C mode). No keep-alive in v1.
//   * Malformed requests are answered 400 (431 for oversized headers) by
//     the connection thread itself; they never reach Elm.
//
// Results reach the main thread through two queues read by the Http.Server
// manager's drain (HttpServerManager.cpp, one eco/system async source);
// threads call notifyWorkAvailableFromAsync() after pushing.
//
// Windows: a stub (HttpServerServiceWin32.cpp) whose listenOn fails with
// ENOTSUP (§1).
//
// Templates used: none (POD only, G1).
//
//===----------------------------------------------------------------------===//

#ifndef ECO_SYSTEM_HTTP_SERVER_HTTP_SERVER_SERVICE_HPP
#define ECO_SYSTEM_HTTP_SERVER_HTTP_SERVER_SERVICE_HPP

#include <cstdint>
#include <string>
#include <utility>
#include <vector>

namespace Eco::System::HttpSrv {

// The outcome of listenOn. fd >= 0 on success; otherwise `code` is the
// error name ("EADDRINUSE", "ENOTFOUND", ...) and `message` node-like text.
struct ListenResult {
    int fd = -1;
    std::string code;
    std::string message;
};

// One complete request, as posted by a connection thread.
struct RequestEvent {
    int64_t serverId = 0;
    int64_t key = 0;                 // the response key (C.5 tagger argument)
    std::string method;              // "GET", "OPTIONS", ...
    std::string url;                 // absolute (E.5)
    std::vector<std::pair<std::string, std::string>> headers;   // arrival order, raw case
    std::string body;
};

// A response handed to a connection (main thread → connection thread).
struct ResponseData {
    int64_t status = 200;
    std::vector<std::pair<std::string, std::string>> headers;   // one line each
    std::string body;
};

// Worker thread (P mode). Blocking: name resolution, socket, bind, listen.
ListenResult listenOn(const std::string& host, int64_t port);

class HttpServerService {
public:
    // Main thread (the first call binds the Scheduler).
    static HttpServerService& instance();

    // Main thread. Starts the accept thread for the listening socket `fd`
    // (from listenOn) and returns the server id (> 0). `host`/`port` are the
    // fallback authority of request URLs without a Host header (E.5).
    // Throws std::system_error if no thread can be started (fd is closed).
    int64_t startServer(int fd, const std::string& host, int64_t port);

    // Main thread. Hands `resp` to the connection waiting under `key`; its
    // thread writes it, closes the connection and then posts `token` as a
    // ResponseDone. Returns false (and posts nothing) when `key` is unknown
    // or was already answered.
    bool respond(int64_t key, uint64_t token, ResponseData resp);

    // Main thread. Moves every queued event out.
    void drainRequests(std::vector<RequestEvent>& out);
    void drainDone(std::vector<uint64_t>& out);

    // Lock-free; any thread (the Scheduler's ready predicate).
    bool hasEvents() const;

    struct Impl;

private:
    HttpServerService();
    Impl* impl_;
};

// The reason phrase of a status code ("OK", "Not Found", ...; "unknown" otherwise, as node).
const char* statusReason(int64_t status);

// Serialises a response (POD, exposed for the Core unit tests). `isHead`
// suppresses the body; 1xx, 204 and 304 get neither body nor Content-Length.
// User headers named Content-Length, Connection or Transfer-Encoding are
// dropped (the server writes its own), as are lines with CR, LF or NUL.
std::string serializeResponse(const ResponseData& r, bool isHead);

} // namespace Eco::System::HttpSrv

#endif // ECO_SYSTEM_HTTP_SERVER_HTTP_SERVER_SERVICE_HPP
