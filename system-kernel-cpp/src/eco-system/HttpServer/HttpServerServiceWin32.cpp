//===- HttpServerServiceWin32.cpp - Windows stub of the HTTP server -------===//
//
// The HTTP server is not supported on Windows. This file replaces both
// HttpServerService.cpp and Http1.cpp there (Http1.cpp is not built on
// Windows). `listenOn` always fails with "ENOTSUP", so this file never opens a
// listener; the other definitions exist to satisfy the linker and do nothing
// useful: `statusReason` returns "unknown", `serializeH1` an empty string,
// `headersAskClose` and `http1Respond` false, and both protocol factories
// null. `http1ServerClosing` only records the closing flag and deadline, and
// `nextResponseKey` still hands out increasing keys.
//
//===----------------------------------------------------------------------===//

#include "eco-system/HttpServer/Http1.hpp"
#include "eco-system/HttpServer/HttpServerService.hpp"

#include <atomic>

namespace Eco::System::HttpSrv {

ListenResult listenOn(const std::string& host, int64_t port) {
    ListenResult r;
    r.code = "ENOTSUP";
    r.message = "eco/system: Http.Server.listenOnHost is not supported on Windows yet (" + host +
                ":" + std::to_string(port) + ")";
    return r;
}

const char* statusReason(int64_t) { return "unknown"; }

std::string serializeH1(const ResponseData&, const H1Options&) { return std::string(); }

bool headersAskClose(const std::vector<std::pair<std::string, std::string>>&) { return false; }

std::unique_ptr<ConnProtocol> makeHttp1Protocol(Conn&, const std::shared_ptr<ServerReactorState>&) {
    return nullptr;
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
