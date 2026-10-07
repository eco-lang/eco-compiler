//===- HttpServerServiceWin32.cpp - Windows stub of the HTTP server -------===//
//
// plans/eco-system-library.md §1: Windows is out of scope for now.
// `createServer` fails with "ENOTSUP" (listenOn below); `onRequest` crashes
// with a clear message (HttpServerManager.cpp). No server is ever started,
// so the service never has events. llhttp is not built on Windows.
//
// Templates used: none (POD only).
//
//===----------------------------------------------------------------------===//

#include "eco-system/HttpServer/HttpServerService.hpp"

#include <system_error>

namespace Eco::System::HttpSrv {

ListenResult listenOn(const std::string& host, int64_t port) {
    ListenResult r;
    r.code = "ENOTSUP";
    r.message = "eco/system: Http.Server.createServer is not supported on Windows yet (" + host +
                ":" + std::to_string(port) + ")";
    return r;
}

const char* statusReason(int64_t) { return "unknown"; }

std::string serializeResponse(const ResponseData&, bool) { return std::string(); }

struct HttpServerService::Impl {};

HttpServerService& HttpServerService::instance() {
    static HttpServerService* s = new HttpServerService();   // leaky (§3.4)
    return *s;
}

HttpServerService::HttpServerService() : impl_(new Impl()) {}

int64_t HttpServerService::startServer(int, const std::string&, int64_t) {
    throw std::system_error(std::make_error_code(std::errc::not_supported));
}

bool HttpServerService::respond(int64_t, uint64_t, ResponseData) { return false; }

void HttpServerService::drainRequests(std::vector<RequestEvent>&) {}

void HttpServerService::drainDone(std::vector<uint64_t>&) {}

bool HttpServerService::hasEvents() const { return false; }

} // namespace Eco::System::HttpSrv
