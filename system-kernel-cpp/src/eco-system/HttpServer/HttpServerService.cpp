//===- HttpServerService.cpp - Sockets and threads behind Http.Server -----===//
//
// See HttpServerService.hpp. POSIX (Linux, macOS); Windows uses
// HttpServerServiceWin32.cpp.
//
// Leaky singleton with detached threads (§3.4): std::exit never runs a
// destructor that races a live accept or connection thread. Every fd is
// opened O_CLOEXEC (accept4 / SOCK_CLOEXEC on Linux, fcntl elsewhere: the
// sockets are created off the main thread, but children are spawned with
// posix_spawn, which only inherits fds without FD_CLOEXEC, so the window is
// the one between socket() and fcntl() — the same as libuv's on macOS).
// EINTR is retried everywhere. Writes use MSG_NOSIGNAL (Linux) or
// SO_NOSIGPIPE (macOS), so a vanished client never raises SIGPIPE.
//
// Templates used: none (POD only, G1).
//
//===----------------------------------------------------------------------===//

#include "eco-system/HttpServer/HttpServerService.hpp"

#include "eco-system/Core/Core.hpp"        // errnoName
#include "eco-system/Core/FdChannel.hpp"   // makeCloexecPipe
#include "platform/Scheduler.hpp"

#include <llhttp.h>

#include <algorithm>
#include <atomic>
#include <cctype>
#include <cerrno>
#include <chrono>
#include <cstring>
#include <ctime>
#include <deque>
#include <memory>
#include <mutex>
#include <system_error>
#include <thread>
#include <unordered_map>

#include <arpa/inet.h>
#include <fcntl.h>
#include <netdb.h>
#include <netinet/in.h>
#include <netinet/tcp.h>
#include <poll.h>
#include <sys/socket.h>
#include <sys/types.h>
#include <unistd.h>

namespace Eco::System::HttpSrv {

using ::Elm::Platform::Scheduler;

namespace {

constexpr size_t kMaxHeaderBytes = 64 * 1024;   // larger → 431
constexpr size_t kReadChunk = 64 * 1024;

#if defined(MSG_NOSIGNAL)
constexpr int kSendFlags = MSG_NOSIGNAL;
#else
constexpr int kSendFlags = 0;
#endif

// Used where accept4 / SOCK_CLOEXEC are missing (macOS).
[[maybe_unused]] void setCloexec(int fd) {
    int fl = ::fcntl(fd, F_GETFD);
    if (fl >= 0) (void)::fcntl(fd, F_SETFD, fl | FD_CLOEXEC);
}

void setNoSigpipe(int fd) {
#if defined(SO_NOSIGPIPE)
    int one = 1;
    (void)::setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &one, sizeof(one));
#else
    (void)fd;
#endif
}

void closeFd(int fd) {
    if (fd >= 0) {
        while (::close(fd) < 0 && errno == EINTR) {
        }
    }
}

// Writes all of `data` (blocking socket). False on error (EPIPE, reset, ...).
bool writeAll(int fd, const char* data, size_t n) {
    while (n > 0) {
        ssize_t w = ::send(fd, data, n, kSendFlags);
        if (w < 0) {
            if (errno == EINTR) continue;
            if (errno == EAGAIN || errno == EWOULDBLOCK) {
                struct pollfd p{fd, POLLOUT, 0};
                (void)::poll(&p, 1, 1000);
                continue;
            }
            return false;
        }
        data += w;
        n -= static_cast<size_t>(w);
    }
    return true;
}

// The authority for request URLs without a Host header (E.5). IPv6
// literals are bracketed.
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

// RFC 7231 IMF-fixdate, e.g. "Tue, 07 Oct 2026 18:50:00 GMT".
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

std::string serializeResponse(const ResponseData& r, bool isHead) {
    // node rejects codes outside 100..999 (RangeError); answer 500 instead.
    int64_t status = (r.status < 100 || r.status > 999) ? 500 : r.status;
    bool noBody = (status >= 100 && status < 200) || status == 204 || status == 304;
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
    out += "Connection: close\r\n\r\n";
    if (!noBody && !isHead) out += r.body;
    return out;
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
#if defined(SOCK_CLOEXEC)
        int fd = ::socket(a->ai_family, a->ai_socktype | SOCK_CLOEXEC, a->ai_protocol);
#else
        int fd = ::socket(a->ai_family, a->ai_socktype, a->ai_protocol);
        if (fd >= 0) setCloexec(fd);
#endif
        if (fd < 0) {
            lastErr = errno;
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
        return res;
    }
    ::freeaddrinfo(list);
    if (lastErr == 0) lastErr = EADDRNOTAVAIL;
    const char* m = std::strerror(lastErr);
    res.code = ::Eco::System::errnoName(lastErr);
    res.message = std::string(lastSyscall) + " " + res.code + ": " + (m ? m : "") + " " + where;
    return res;
}

// ---------------------------------------------------------------------------
// The service
// ---------------------------------------------------------------------------

namespace {

struct Conn {
    int64_t key = 0;
    int fd = -1;
    int wake[2] = {-1, -1};
    std::mutex m;
    bool hasResponse = false;
    ResponseData response;
    uint64_t token = 0;

    ~Conn() {
        closeFd(wake[0]);
        closeFd(wake[1]);
    }
};

struct Server {
    int64_t id = 0;
    int fd = -1;
    std::string authority;   // E.5 fallback
};

} // namespace

struct HttpServerService::Impl {
    Scheduler* sched = nullptr;

    std::mutex qMutex;
    std::deque<RequestEvent> requests;
    std::deque<uint64_t> done;
    std::atomic<size_t> ready{0};

    // Connections waiting for their response: written by connection threads
    // (insert) and the main thread (take). Never allocates on the heap of
    // Elm, so the mutex is fine (G9 is about the Elm heap).
    std::mutex connMutex;
    std::unordered_map<int64_t, std::shared_ptr<Conn>> waiting;

    std::atomic<int64_t> nextServerId{1};
    std::atomic<int64_t> nextKey{1};

    void postRequest(RequestEvent ev) {
        {
            std::lock_guard<std::mutex> lk(qMutex);
            requests.push_back(std::move(ev));
            ready.fetch_add(1, std::memory_order_release);
        }
        sched->notifyWorkAvailableFromAsync();   // outside qMutex
    }

    void postDone(uint64_t token) {
        {
            std::lock_guard<std::mutex> lk(qMutex);
            done.push_back(token);
            ready.fetch_add(1, std::memory_order_release);
        }
        sched->notifyWorkAvailableFromAsync();
    }

    void acceptLoop(std::shared_ptr<Server> srv);
    void connLoop(std::shared_ptr<Server> srv, int fd);
};

namespace {

// llhttp callbacks collect the first request of a connection.
struct ParseState {
    std::string url;
    std::vector<std::pair<std::string, std::string>> headers;
    bool inValue = false;
    std::string body;
    size_t headerBytes = 0;
    bool tooLarge = false;
    bool headersDone = false;
    bool complete = false;
    bool expectContinue = false;
};

ParseState* stateOf(llhttp_t* p) { return static_cast<ParseState*>(p->data); }

int onUrl(llhttp_t* p, const char* at, size_t n) {
    ParseState* s = stateOf(p);
    s->headerBytes += n;
    if (s->headerBytes > kMaxHeaderBytes) { s->tooLarge = true; return HPE_USER; }
    s->url.append(at, n);
    return 0;
}

int onHeaderField(llhttp_t* p, const char* at, size_t n) {
    ParseState* s = stateOf(p);
    s->headerBytes += n;
    if (s->headerBytes > kMaxHeaderBytes) { s->tooLarge = true; return HPE_USER; }
    if (s->headers.empty() || s->inValue) {
        s->headers.emplace_back();
        s->inValue = false;
    }
    s->headers.back().first.append(at, n);
    return 0;
}

int onHeaderValue(llhttp_t* p, const char* at, size_t n) {
    ParseState* s = stateOf(p);
    s->headerBytes += n;
    if (s->headerBytes > kMaxHeaderBytes) { s->tooLarge = true; return HPE_USER; }
    if (s->headers.empty()) s->headers.emplace_back();
    s->inValue = true;
    s->headers.back().second.append(at, n);
    return 0;
}

int onHeadersComplete(llhttp_t* p) {
    ParseState* s = stateOf(p);
    s->headersDone = true;
    for (const auto& h : s->headers) {
        if (iequals(h.first, "expect") && iequals(h.second, "100-continue")) s->expectContinue = true;
    }
    return 0;
}

int onBody(llhttp_t* p, const char* at, size_t n) {
    stateOf(p)->body.append(at, n);
    return 0;
}

int onMessageComplete(llhttp_t* p) {
    stateOf(p)->complete = true;
    return HPE_PAUSED;   // one request per connection (no keep-alive in v1)
}

// The absolute request URL of E.5.
std::string absoluteUrl(const ParseState& s, const std::string& fallbackAuthority) {
    const std::string& target = s.url;
    if (target.rfind("http://", 0) == 0 || target.rfind("https://", 0) == 0) return target;
    std::string authority = fallbackAuthority;
    for (const auto& h : s.headers) {
        if (iequals(h.first, "host") && !h.second.empty()) authority = h.second;   // the first Host
        if (iequals(h.first, "host")) break;
    }
    std::string path = target.empty() || target[0] != '/' ? "/" + (target == "*" ? std::string() : target)
                                                           : target;
    return "http://" + authority + path;
}

// Closes a connection gracefully: FIN first, then wait (bounded) for the
// client's FIN so unread client bytes do not turn the close into a reset
// that could destroy the response in flight.
void lingerClose(int fd) {
    (void)::shutdown(fd, SHUT_WR);
    char buf[4096];
    auto deadline = std::chrono::steady_clock::now() + std::chrono::seconds(2);
    for (;;) {
        auto left = std::chrono::duration_cast<std::chrono::milliseconds>(
                        deadline - std::chrono::steady_clock::now())
                        .count();
        if (left <= 0) break;
        struct pollfd p{fd, POLLIN, 0};
        int r = ::poll(&p, 1, static_cast<int>(left));
        if (r < 0 && errno == EINTR) continue;
        if (r <= 0) break;
        ssize_t n = ::recv(fd, buf, sizeof(buf), 0);
        if (n < 0 && errno == EINTR) continue;
        if (n <= 0) break;
    }
    closeFd(fd);
}

void sendSimple(int fd, int status) {
    ResponseData r;
    r.status = status;
    std::string out = serializeResponse(r, false);
    (void)writeAll(fd, out.data(), out.size());
}

} // namespace

void HttpServerService::Impl::acceptLoop(std::shared_ptr<Server> srv) {
    for (;;) {
#if defined(__linux__)
        int fd = ::accept4(srv->fd, nullptr, nullptr, SOCK_CLOEXEC);
#else
        int fd = ::accept(srv->fd, nullptr, nullptr);
        if (fd >= 0) setCloexec(fd);
#endif
        if (fd < 0) {
            int e = errno;
            if (e == EINTR || e == ECONNABORTED || e == EAGAIN || e == EWOULDBLOCK) continue;
            if (e == EMFILE || e == ENFILE || e == ENOBUFS || e == ENOMEM) {
                std::this_thread::sleep_for(std::chrono::milliseconds(50));
                continue;
            }
            // EBADF/EINVAL: the listening socket is gone; nothing to serve.
            return;
        }
        setNoSigpipe(fd);
        int one = 1;
        (void)::setsockopt(fd, IPPROTO_TCP, TCP_NODELAY, &one, sizeof(one));
        try {
            std::thread([this, srv, fd] { connLoop(srv, fd); }).detach();
        } catch (...) {
            closeFd(fd);   // no thread: drop the connection
        }
    }
}

void HttpServerService::Impl::connLoop(std::shared_ptr<Server> srv, int fd) {
    auto conn = std::make_shared<Conn>();
    conn->fd = fd;
    if (::Eco::System::makeCloexecPipe(conn->wake, /*nonBlocking=*/true) != 0) {
        closeFd(fd);
        return;
    }

    ParseState ps;
    llhttp_settings_t settings;
    llhttp_settings_init(&settings);
    settings.on_url = &onUrl;
    settings.on_header_field = &onHeaderField;
    settings.on_header_value = &onHeaderValue;
    settings.on_headers_complete = &onHeadersComplete;
    settings.on_body = &onBody;
    settings.on_message_complete = &onMessageComplete;
    llhttp_t parser;
    llhttp_init(&parser, HTTP_REQUEST, &settings);
    parser.data = &ps;

    std::string buf(kReadChunk, '\0');
    bool continueSent = false;
    // Read until the first request is complete.
    while (!ps.complete) {
        struct pollfd pfds[2] = {{fd, POLLIN, 0}, {conn->wake[0], POLLIN, 0}};
        int pr = ::poll(pfds, 2, -1);
        if (pr < 0) {
            if (errno == EINTR) continue;
            closeFd(fd);
            return;
        }
        if (!(pfds[0].revents & (POLLIN | POLLHUP | POLLERR))) continue;
        ssize_t n = ::recv(fd, &buf[0], buf.size(), 0);
        if (n < 0) {
            if (errno == EINTR || errno == EAGAIN || errno == EWOULDBLOCK) continue;
            closeFd(fd);
            return;
        }
        llhttp_errno_t err;
        if (n == 0) {
            err = llhttp_finish(&parser);   // EOF: ends a body without length
            if (!ps.complete) {
                if (err != HPE_OK && err != HPE_PAUSED && ps.headerBytes > 0) sendSimple(fd, 400);
                closeFd(fd);
                return;
            }
            break;
        }
        err = llhttp_execute(&parser, buf.data(), static_cast<size_t>(n));
        if (err == HPE_PAUSED_UPGRADE) {
            ps.complete = true;   // an upgrade request: answered like any other
            break;
        }
        if (err != HPE_OK && err != HPE_PAUSED) {
            sendSimple(fd, ps.tooLarge ? 431 : 400);
            lingerClose(fd);
            return;
        }
        if (ps.headersDone && ps.expectContinue && !continueSent && !ps.complete) {
            static const char k100[] = "HTTP/1.1 100 Continue\r\n\r\n";
            continueSent = true;
            if (!writeAll(fd, k100, sizeof(k100) - 1)) {
                closeFd(fd);
                return;
            }
        }
    }

    const char* methodName = llhttp_method_name(static_cast<llhttp_method_t>(parser.method));
    std::string method = methodName ? methodName : "GET";
    bool isHead = method == "HEAD";

    RequestEvent ev;
    ev.serverId = srv->id;
    ev.key = nextKey.fetch_add(1, std::memory_order_relaxed);
    ev.method = method;
    ev.url = absoluteUrl(ps, srv->authority);
    ev.headers = std::move(ps.headers);
    ev.body = std::move(ps.body);
    conn->key = ev.key;
    {
        std::lock_guard<std::mutex> lk(connMutex);
        waiting.emplace(conn->key, conn);
    }
    postRequest(std::move(ev));

    // Wait for the response (respond() writes the wake pipe).
    for (;;) {
        {
            std::lock_guard<std::mutex> lk(conn->m);
            if (conn->hasResponse) break;
        }
        struct pollfd p{conn->wake[0], POLLIN, 0};
        int pr = ::poll(&p, 1, -1);
        if (pr < 0 && errno != EINTR) {
            std::this_thread::sleep_for(std::chrono::milliseconds(10));
            continue;
        }
        if (pr > 0) {
            char drain[64];
            while (::read(conn->wake[0], drain, sizeof(drain)) < 0 && errno == EINTR) {
            }
        }
    }
    ResponseData resp;
    uint64_t token = 0;
    {
        std::lock_guard<std::mutex> lk(conn->m);
        resp = std::move(conn->response);
        token = conn->token;
    }
    std::string out = serializeResponse(resp, isHead);
    (void)writeAll(fd, out.data(), out.size());   // a vanished client is not an error of the task
    lingerClose(fd);
    if (token != 0) postDone(token);
}

HttpServerService& HttpServerService::instance() {
    static HttpServerService* s = new HttpServerService();   // leaky (§3.4)
    return *s;
}

HttpServerService::HttpServerService() : impl_(new Impl()) {
    impl_->sched = &Scheduler::instance();   // bound on the main thread
}

int64_t HttpServerService::startServer(int fd, const std::string& host, int64_t port) {
    auto srv = std::make_shared<Server>();
    srv->id = impl_->nextServerId.fetch_add(1, std::memory_order_relaxed);
    srv->fd = fd;
    srv->authority = authorityOf(host, port);
    Impl* impl = impl_;
    try {
        std::thread([impl, srv] { impl->acceptLoop(srv); }).detach();
    } catch (...) {
        closeFd(fd);
        throw;
    }
    return srv->id;
}

bool HttpServerService::respond(int64_t key, uint64_t token, ResponseData resp) {
    std::shared_ptr<Conn> conn;
    {
        std::lock_guard<std::mutex> lk(impl_->connMutex);
        auto it = impl_->waiting.find(key);
        if (it == impl_->waiting.end()) return false;
        conn = std::move(it->second);
        impl_->waiting.erase(it);
    }
    {
        std::lock_guard<std::mutex> lk(conn->m);
        conn->response = std::move(resp);
        conn->token = token;
        conn->hasResponse = true;
    }
    char one = 1;
    while (::write(conn->wake[1], &one, 1) < 0 && errno == EINTR) {
    }
    return true;
}

void HttpServerService::drainRequests(std::vector<RequestEvent>& out) {
    std::lock_guard<std::mutex> lk(impl_->qMutex);
    while (!impl_->requests.empty()) {
        out.push_back(std::move(impl_->requests.front()));
        impl_->requests.pop_front();
        impl_->ready.fetch_sub(1, std::memory_order_acq_rel);
    }
}

void HttpServerService::drainDone(std::vector<uint64_t>& out) {
    std::lock_guard<std::mutex> lk(impl_->qMutex);
    while (!impl_->done.empty()) {
        out.push_back(impl_->done.front());
        impl_->done.pop_front();
        impl_->ready.fetch_sub(1, std::memory_order_acq_rel);
    }
}

bool HttpServerService::hasEvents() const {
    return impl_->ready.load(std::memory_order_acquire) > 0;
}

} // namespace Eco::System::HttpSrv
