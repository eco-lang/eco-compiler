//===- HttpServerService.hpp - Listening and wire format of Http.Server ---===//
//
// The parts of the HTTP server that need neither the Elm heap nor the event
// loop: opening the listening socket, and turning a response into HTTP/1.1
// bytes.
//
// Error codes follow Node's `http` module. A listen that fails with an errno
// gets a "syscall CODE: text address" message whose text is the C library's
// strerror: for example code "EADDRINUSE" with message
// "listen EADDRINUSE: Address already in use 127.0.0.1:8080" on glibc.
// `listenOn` runs on a worker thread, where strerror is not safe to call, so
// it returns the errno, and `createServer`'s completion (HttpServer.cpp) builds
// that text on the eco thread.
//
// On Windows HttpServerServiceWin32.cpp replaces the implementation: `listenOn`
// always fails with "ENOTSUP", and the other functions are inert stubs.
//
//===----------------------------------------------------------------------===//

#ifndef ECO_SYSTEM_HTTP_SERVER_HTTP_SERVER_SERVICE_HPP
#define ECO_SYSTEM_HTTP_SERVER_HTTP_SERVER_SERVICE_HPP

#include "platform/TestHooks.hpp"

#include <cstdint>
#include <string>
#include <utility>
#include <vector>

struct addrinfo;

namespace Eco::System::HttpSrv {

/// The outcome of `listenOn`: a listening socket, or the reason there is none.
/// On success `fd` is a non-blocking, close-on-exec listening descriptor and
/// `code` is empty; on failure `fd` is -1, `code` is the error name
/// ("EADDRINUSE", "ENOTFOUND", "ERR_SOCKET_BAD_PORT", ...), and `message`, or
/// for an errno failure `sysErr`, `syscall` and `where`, give the Node-style
/// text. `fd` is a plain int: this
/// record does not close it, so the receiver owns the descriptor.
struct ListenResult {
    int fd = -1;
    int64_t boundPort = 0;   // on success the port bound (the requested one if it can't be read); 0 on failure
    std::string boundAddress;   // the bound address as text; may be empty
    std::string code;
    /// The whole message, for a failure without an errno (`sysErr` 0). Empty
    /// for an errno failure, whose message is "syscall CODE: strerror where".
    std::string message;
    int sysErr = 0;          // an errno failure: the errno of the last address tried; 0 otherwise
    std::string syscall;     // an errno failure: "socket" or "listen", as node names the call
    std::string where;       // an errno failure: the `host:port` authority asked for
};


/// A response to serialise: status, header lines in order, and body, all as
/// plain values.
struct ResponseData {
    int64_t status = 200;
    std::vector<std::pair<std::string, std::string>> headers;   // name, value; one line each
    std::string body;
};

/// The facts about the connection and request that change how `serializeH1`
/// frames a response.
struct H1Options {
    bool isHead = false;      // the request was HEAD: headers only (Content-Length kept)
    bool keepAlive = false;   // "Connection: keep-alive", else "Connection: close"
};

/// Opens a TCP socket listening on `host` and `port`. An empty `host` means
/// every local address, and port 0 lets the system pick one. The resolved addresses are
/// tried IPv4 first, and the first that binds and listens is returned.
/// Failures: a port outside 0..65535 gives "ERR_SOCKET_BAD_PORT"; a
/// getaddrinfo failure gives the code `gaiCode` maps it to ("ENOTFOUND" for no
/// such name, "EAI_AGAIN", "ENOMEM", the errno name for EAI_SYSTEM, ...) with
/// the message "getaddrinfo CODE host"; and otherwise the errno name of the
/// last address's failure ("EADDRNOTAVAIL" if no address was tried), with
/// `sysErr` set. Blocks on name resolution. Safe on any thread: it formats no
/// strerror text.
ListenResult listenOn(const std::string& host, int64_t port);

#if ECO_TEST_HOOKS && !defined(_WIN32)
/// A resolver with the signature of `::getaddrinfo`.
using GetaddrinfoFn = int (*)(const char* node, const char* service, const struct addrinfo* hints,
                              struct addrinfo** res);
/// Test-only (HTTPSRV-06): makes `listenOn` resolve with `fn` instead of `::getaddrinfo`, and returns the previous
/// resolver; null restores `::getaddrinfo`. A stub that returns non-zero need not set `*res`; one that returns 0
/// must give a list `freeaddrinfo` can free. Any thread, but not while a `listenOn` runs.
GetaddrinfoFn setListenResolverForTest(GetaddrinfoFn fn);
#endif

/// Returns the reason phrase of `status` ("OK", "Not Found", ...), or
/// "unknown" for a code with none. The string is static.
const char* statusReason(int64_t status);

/// Returns `r` as the bytes of an HTTP/1.1 response, framed as `o` says:
///   * a status below 200 or above 999 is sent as 500;
///   * 204 and 304 get neither body nor Content-Length; every other status
///     gets Content-Length, and the body unless `o.isHead`;
///   * headers named Content-Length, Connection or Transfer-Encoding
///     (any case) are dropped, as are headers with an empty name or a CR, LF
///     or NUL in the name or value; a Date header is added unless a kept one
///     is named Date;
///   * the last header is "Connection: keep-alive" if `o.keepAlive`, else
///     "Connection: close".
std::string serializeH1(const ResponseData& r, const H1Options& o);

/// Returns true when a header in `headers` named Connection (any case) lists
/// the token "close" (any case) in its comma-separated value.
bool headersAskClose(const std::vector<std::pair<std::string, std::string>>& headers);

} // namespace Eco::System::HttpSrv

#endif // ECO_SYSTEM_HTTP_SERVER_HTTP_SERVER_SERVICE_HPP
