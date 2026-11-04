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
//
// On Windows HttpServerServiceWin32.cpp replaces the implementation: `listenOn`
// always fails with "ENOTSUP", and the other functions are inert stubs.
//
//===----------------------------------------------------------------------===//

#ifndef ECO_SYSTEM_HTTP_SERVER_HTTP_SERVER_SERVICE_HPP
#define ECO_SYSTEM_HTTP_SERVER_HTTP_SERVER_SERVICE_HPP

#include <cstdint>
#include <string>
#include <utility>
#include <vector>

namespace Eco::System::HttpSrv {

/// The outcome of `listenOn`: a listening socket, or the reason there is none.
/// On success `fd` is a non-blocking, close-on-exec listening descriptor and
/// `code` is empty; on failure `fd` is -1, `code` is the error name
/// ("EADDRINUSE", "ENOTFOUND", "ERR_SOCKET_BAD_PORT", ...) and `message` the
/// Node-style text. `fd` is a plain int: this record does not close it, so the
/// receiver owns the descriptor.
struct ListenResult {
    int fd = -1;
    int64_t boundPort = 0;   // on success the port bound (the requested one if it can't be read); 0 on failure
    std::string boundAddress;   // the bound address as text; may be empty
    std::string code;
    std::string message;
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
/// Failures: a port outside 0..65535 gives "ERR_SOCKET_BAD_PORT", any
/// getaddrinfo failure gives "ENOTFOUND", and otherwise the errno name of the
/// last address's failure ("EADDRNOTAVAIL" if no address was tried). Blocks on
/// name resolution.
ListenResult listenOn(const std::string& host, int64_t port);

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
