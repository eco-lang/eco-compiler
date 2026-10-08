//===- HttpServerService.hpp - Listening and wire format of Http.Server ---===//
//
// plans/eco-system-library.md Phase 7 step 7.2, Appendix E.5, and
// plans/eco-system-websockets.md §3.4 (phase WS2). What is left of the
// thread-based service once Http.Server moved onto the IoReactor
// (Http1.{hpp,cpp}, HttpTables.{hpp,cpp}): POD helpers only, no heap
// access, no Elm calls, no Debug.log (G1).
//
//   * listenOn (a SysWorkPool worker, P mode): resolve the host (IPv4
//     first), socket, SO_REUSEADDR, bind, listen. The fd is O_CLOEXEC and
//     NON-BLOCKING (it is handed to a ListenerHandler in callback mode); the
//     result carries the bound port (port 0 picks one). Error texts are
//     Node's ("listen EADDRINUSE: address already in use 127.0.0.1:8080").
//   * serializeH1: an HTTP/1.1 response (§3.4 "Responses").
//   * statusReason: the reason phrase of a status code.
//
// Windows: HttpServerServiceWin32.cpp, whose listenOn fails with ENOTSUP
// (§1).
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

// The outcome of listenOn. fd >= 0 on success (non-blocking, cloexec);
// otherwise `code` is the error name ("EADDRINUSE", "ENOTFOUND", ...) and
// `message` Node-like text.
struct ListenResult {
    int fd = -1;
    int64_t boundPort = 0;   // the port actually bound (getsockname)
    std::string code;
    std::string message;
};

// A response (the respond kernel's arguments, copied out of the heap).
struct ResponseData {
    int64_t status = 200;
    std::vector<std::pair<std::string, std::string>> headers;   // one line each
    std::string body;
};

// How serializeH1 frames a response (§3.4).
struct H1Options {
    bool isHead = false;      // the request was HEAD: headers only (Content-Length kept)
    bool keepAlive = false;   // "Connection: keep-alive", else "Connection: close"
};

// Worker thread (P mode). Blocking: name resolution, socket, bind, listen.
ListenResult listenOn(const std::string& host, int64_t port);

// The reason phrase of a status code ("OK", "Not Found", ...; "unknown"
// otherwise, as Node).
const char* statusReason(int64_t status);

// Serialises a response, always as "HTTP/1.1":
//   * a status outside 100..999 is answered 500 (Node throws a RangeError);
//     a user status 100..199 (a final 1xx, including 101 outside an
//     upgrade) is answered 500 too (§3.4);
//   * 204 and 304 get neither body nor Content-Length; every other status
//     gets Content-Length (HEAD: the length of the body it would have had,
//     no body);
//   * user headers named Content-Length, Connection or Transfer-Encoding
//     are dropped (the server writes its own), as are lines with CR, LF or
//     NUL and empty names; a Date header is added unless one was given;
//   * "Connection: keep-alive" or "Connection: close" per `o.keepAlive`.
std::string serializeH1(const ResponseData& r, const H1Options& o);

// True when one of the user's Connection headers lists the token "close"
// (case-insensitive): the response then closes the connection (§3.4).
bool headersAskClose(const std::vector<std::pair<std::string, std::string>>& headers);

} // namespace Eco::System::HttpSrv

#endif // ECO_SYSTEM_HTTP_SERVER_HTTP_SERVER_SERVICE_HPP
