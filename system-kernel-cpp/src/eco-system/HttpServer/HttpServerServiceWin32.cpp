//===- HttpServerServiceWin32.cpp - Windows stub of the HTTP server -------===//
//
// plans/eco-system-library.md §1: Windows is out of scope for now.
// `createServer` fails with "ENOTSUP" (listenOn below), `createServerWith`
// fails in Socket's tcpListenOn (ENOTSUP), and `onRequest` crashes with a
// clear message (HttpServerManager.cpp). No server is ever started, so the
// reactor-side HTTP/1.1 functions (Http1.cpp, which needs llhttp, not built
// on Windows) are never reached; these stubs only satisfy the linker.
//
// Templates used: none (POD only).
//
//===----------------------------------------------------------------------===//

#include "eco-system/HttpServer/Http1.hpp"
#include "eco-system/HttpServer/HttpServerService.hpp"

#include <atomic>

namespace Eco::System::HttpSrv {

ListenResult listenOn(const std::string& host, int64_t port) {
    ListenResult r;
    r.code = "ENOTSUP";
    r.message = "eco/system: Http.Server.createServer is not supported on Windows yet (" + host +
                ":" + std::to_string(port) + ")";
    return r;
}

const char* statusReason(int64_t) { return "unknown"; }

std::string serializeH1(const ResponseData&, const H1Options&) { return std::string(); }

bool headersAskClose(const std::vector<std::pair<std::string, std::string>>&) { return false; }

std::unique_ptr<ConnProtocol> makeHttp1Protocol(Conn&, const std::shared_ptr<ServerReactorState>&) {
    return nullptr;   // the listener aborts the connection
}

std::unique_ptr<ConnProtocol> makeServerProtocol(Conn&, const std::shared_ptr<ServerReactorState>&) {
    return nullptr;
}

void http1ServerClosing(const std::shared_ptr<ServerReactorState>& srv, int64_t deadline) {
    srv->closing = true;
    srv->closeDeadline = deadline;
}

bool http1Respond(const std::shared_ptr<Conn>&, int64_t, ResponseData, bool,
                  std::function<void(int)>&) {
    return false;
}

int64_t nextResponseKey() {
    static std::atomic<int64_t> next{1};
    return next.fetch_add(1);
}

} // namespace Eco::System::HttpSrv
