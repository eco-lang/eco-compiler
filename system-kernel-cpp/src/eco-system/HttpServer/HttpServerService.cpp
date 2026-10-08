//===- HttpServerService.cpp - Listening and wire format of Http.Server ---===//
//
// See HttpServerService.hpp. POSIX (Linux, macOS); Windows uses
// HttpServerServiceWin32.cpp. Every fd is O_CLOEXEC (socketCloexec,
// Core/SocketUtil). The connections themselves run on the IoReactor
// (Http1.cpp, plans/eco-system-websockets.md §3.4).
//
// Templates used: none (POD only, G1).
//
//===----------------------------------------------------------------------===//

#include "eco-system/HttpServer/HttpServerService.hpp"

#include "eco-system/Core/Core.hpp"        // errnoName
#include "eco-system/Core/SocketUtil.hpp"  // socketCloexec, SockAddr, sockaddrToInet

#include <algorithm>
#include <cctype>
#include <cerrno>
#include <cstring>
#include <ctime>

#include <netdb.h>
#include <netinet/in.h>
#include <sys/socket.h>
#include <sys/types.h>
#include <unistd.h>

namespace Eco::System::HttpSrv {

namespace {

void closeFd(int fd) {
    if (fd >= 0) {
        while (::close(fd) < 0 && errno == EINTR) {
        }
    }
}

// Node's text for a listen address: IPv6 literals are bracketed.
std::string authorityOf(const std::string& host, int64_t port) {
    std::string h = host.empty() ? std::string("localhost") : host;
    if (h.find(':') != std::string::npos && h.front() != '[') h = "[" + h + "]";
    return h + ":" + std::to_string(port);
}

bool iequals(const std::string& a, const char* b) {
    size_t n = std::strlen(b);
    if (a.size() != n) return false;
    for (size_t i = 0; i < n; ++i) {
        if (std::tolower(static_cast<unsigned char>(a[i])) !=
            std::tolower(static_cast<unsigned char>(b[i])))
            return false;
    }
    return true;
}

bool hasBadChar(const std::string& s) {
    for (char c : s) {
        if (c == '\r' || c == '\n' || c == '\0') return true;
    }
    return false;
}

// RFC 9110 IMF-fixdate, e.g. "Tue, 07 Oct 2026 18:50:00 GMT".
std::string httpDate() {
    std::time_t t = std::time(nullptr);
    struct tm g;
    ::gmtime_r(&t, &g);
    char buf[64];
    std::strftime(buf, sizeof(buf), "%a, %d %b %Y %H:%M:%S GMT", &g);
    return buf;
}

} // namespace

// ---------------------------------------------------------------------------
// Responses
// ---------------------------------------------------------------------------

const char* statusReason(int64_t status) {
    switch (status) {
        case 100: return "Continue";
        case 101: return "Switching Protocols";
        case 102: return "Processing";
        case 103: return "Early Hints";
        case 200: return "OK";
        case 201: return "Created";
        case 202: return "Accepted";
        case 203: return "Non-Authoritative Information";
        case 204: return "No Content";
        case 205: return "Reset Content";
        case 206: return "Partial Content";
        case 207: return "Multi-Status";
        case 208: return "Already Reported";
        case 226: return "IM Used";
        case 300: return "Multiple Choices";
        case 301: return "Moved Permanently";
        case 302: return "Found";
        case 303: return "See Other";
        case 304: return "Not Modified";
        case 305: return "Use Proxy";
        case 307: return "Temporary Redirect";
        case 308: return "Permanent Redirect";
        case 400: return "Bad Request";
        case 401: return "Unauthorized";
        case 402: return "Payment Required";
        case 403: return "Forbidden";
        case 404: return "Not Found";
        case 405: return "Method Not Allowed";
        case 406: return "Not Acceptable";
        case 407: return "Proxy Authentication Required";
        case 408: return "Request Timeout";
        case 409: return "Conflict";
        case 410: return "Gone";
        case 411: return "Length Required";
        case 412: return "Precondition Failed";
        case 413: return "Payload Too Large";
        case 414: return "URI Too Long";
        case 415: return "Unsupported Media Type";
        case 416: return "Range Not Satisfiable";
        case 417: return "Expectation Failed";
        case 418: return "I'm a Teapot";
        case 421: return "Misdirected Request";
        case 422: return "Unprocessable Entity";
        case 423: return "Locked";
        case 424: return "Failed Dependency";
        case 425: return "Too Early";
        case 426: return "Upgrade Required";
        case 428: return "Precondition Required";
        case 429: return "Too Many Requests";
        case 431: return "Request Header Fields Too Large";
        case 451: return "Unavailable For Legal Reasons";
        case 500: return "Internal Server Error";
        case 501: return "Not Implemented";
        case 502: return "Bad Gateway";
        case 503: return "Service Unavailable";
        case 504: return "Gateway Timeout";
        case 505: return "HTTP Version Not Supported";
        case 506: return "Variant Also Negotiates";
        case 507: return "Insufficient Storage";
        case 508: return "Loop Detected";
        case 509: return "Bandwidth Limit Exceeded";
        case 510: return "Not Extended";
        case 511: return "Network Authentication Required";
        default: return "unknown";   // node's fallback
    }
}

std::string serializeH1(const ResponseData& r, const H1Options& o) {
    // Node rejects codes outside 100..999 (RangeError); a final 1xx (and
    // 101 outside an upgrade) cannot be a response either (§3.4): 500.
    int64_t status = (r.status < 200 || r.status > 999) ? 500 : r.status;
    bool noBody = status == 204 || status == 304;
    std::string out;
    out.reserve(256 + r.body.size());
    out += "HTTP/1.1 ";
    out += std::to_string(status);
    out += ' ';
    out += statusReason(status);
    out += "\r\n";
    bool hasDate = false;
    for (const auto& h : r.headers) {
        if (h.first.empty() || hasBadChar(h.first) || hasBadChar(h.second)) continue;
        if (iequals(h.first, "content-length") || iequals(h.first, "connection") ||
            iequals(h.first, "transfer-encoding"))
            continue;
        if (iequals(h.first, "date")) hasDate = true;
        out += h.first;
        out += ": ";
        out += h.second;
        out += "\r\n";
    }
    if (!hasDate) {
        out += "Date: ";
        out += httpDate();
        out += "\r\n";
    }
    if (!noBody) {
        out += "Content-Length: ";
        out += std::to_string(r.body.size());
        out += "\r\n";
    }
    out += o.keepAlive ? "Connection: keep-alive\r\n\r\n" : "Connection: close\r\n\r\n";
    if (!noBody && !o.isHead) out += r.body;
    return out;
}

bool headersAskClose(const std::vector<std::pair<std::string, std::string>>& headers) {
    for (const auto& h : headers) {
        if (!iequals(h.first, "connection")) continue;
        // A comma-separated token list (RFC 9110 §7.6.1).
        size_t i = 0;
        const std::string& v = h.second;
        while (i <= v.size()) {
            size_t j = v.find(',', i);
            if (j == std::string::npos) j = v.size();
            size_t a = i, b = j;
            while (a < b && (v[a] == ' ' || v[a] == '\t')) ++a;
            while (b > a && (v[b - 1] == ' ' || v[b - 1] == '\t')) --b;
            if (iequals(v.substr(a, b - a), "close")) return true;
            i = j + 1;
        }
    }
    return false;
}

// ---------------------------------------------------------------------------
// listenOn (worker thread)
// ---------------------------------------------------------------------------

ListenResult listenOn(const std::string& host, int64_t port) {
    ListenResult res;
    std::string where = authorityOf(host, port);
    if (port < 0 || port > 65535) {
        res.code = "ERR_SOCKET_BAD_PORT";
        res.message = "Port should be >= 0 and < 65536. Received " + std::to_string(port) + ".";
        return res;
    }
    struct addrinfo hints;
    std::memset(&hints, 0, sizeof(hints));
    hints.ai_family = AF_UNSPEC;
    hints.ai_socktype = SOCK_STREAM;
    hints.ai_flags = AI_PASSIVE;
    std::string service = std::to_string(port);
    struct addrinfo* list = nullptr;
    int gai = ::getaddrinfo(host.empty() ? nullptr : host.c_str(), service.c_str(), &hints, &list);
    if (gai != 0) {
        res.code = "ENOTFOUND";
        res.message = "getaddrinfo ENOTFOUND " + host;
        return res;
    }
    // IPv4 first: "localhost" then serves clients that try 127.0.0.1, and an
    // empty host binds 0.0.0.0 (node binds :: dual-stack; both accept IPv4).
    std::vector<struct addrinfo*> addrs;
    for (struct addrinfo* a = list; a; a = a->ai_next) addrs.push_back(a);
    std::stable_sort(addrs.begin(), addrs.end(), [](struct addrinfo* a, struct addrinfo* b) {
        return a->ai_family == AF_INET && b->ai_family != AF_INET;
    });

    int lastErr = 0;
    const char* lastSyscall = "listen";
    for (struct addrinfo* a : addrs) {
        int sockErr = 0;
        // Non-blocking: the fd is handed to a ListenerHandler (the reactor).
        int fd = ::Eco::System::socketCloexec(a->ai_family, a->ai_socktype, a->ai_protocol,
                                              /*nonBlocking=*/true, &sockErr);
        if (fd < 0) {
            lastErr = sockErr;
            lastSyscall = "socket";
            continue;
        }
        int one = 1;
        (void)::setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &one, sizeof(one));
        if (::bind(fd, a->ai_addr, a->ai_addrlen) < 0) {
            lastErr = errno;
            lastSyscall = "listen";   // node reports bind failures as "listen"
            closeFd(fd);
            continue;
        }
        if (::listen(fd, 511) < 0) {
            lastErr = errno;
            lastSyscall = "listen";
            closeFd(fd);
            continue;
        }
        ::freeaddrinfo(list);
        res.fd = fd;
        res.boundPort = port;
        ::Eco::System::SockAddr bound;
        bound.len = sizeof(bound.ss);
        std::string text;
        int64_t p = 0;
        if (::getsockname(fd, bound.get(), &bound.len) == 0 &&
            ::Eco::System::sockaddrToInet(bound, text, p)) {
            res.boundPort = p;
        }
        return res;
    }
    ::freeaddrinfo(list);
    if (lastErr == 0) lastErr = EADDRNOTAVAIL;
    const char* m = std::strerror(lastErr);
    res.code = ::Eco::System::errnoName(lastErr);
    res.message = std::string(lastSyscall) + " " + res.code + ": " + (m ? m : "") + " " + where;
    return res;
}

} // namespace Eco::System::HttpSrv
