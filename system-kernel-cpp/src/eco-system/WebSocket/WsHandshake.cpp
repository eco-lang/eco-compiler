//===- WsHandshake.cpp - The kernel side of the opening handshake ---------===//
//===----------------------------------------------------------------------===//

#include "eco-system/WebSocket/WsHandshake.hpp"

#include "eco-system/Core/Core.hpp"
#include "eco-system/Core/IoReactor.hpp"
#include "eco-system/WebSocket/Http2Client.hpp"
#include "eco-system/WebSocket/WsEvents.hpp"

#include <cstdio>
#include <cstdlib>
#include <cstring>

#ifndef _WIN32
#include <openssl/evp.h>
#include <openssl/rand.h>
#include <openssl/sha.h>
#else
#include <windows.h>
#include <bcrypt.h>
#pragma comment(lib, "bcrypt")   // wsRandomBytes; also honoured by clang/lld on COFF
#endif

namespace Eco::System {

namespace {

// The GUID RFC 6455 appends to a key before hashing it for the accept value.
[[maybe_unused]] constexpr const char* kGuid = "258EAFA5-E914-47DA-95CA-C5AB0DC85B11";

// Returns the shared reactor.
IoReactor& reactor() { return IoReactor::instance(); }

#ifndef _WIN32
// Returns the `n` bytes at `data` in standard base64, padded.
std::string base64(const unsigned char* data, size_t n) {
    std::string out(4 * ((n + 2) / 3) + 1, '\0');
    int len = EVP_EncodeBlock(reinterpret_cast<unsigned char*>(out.data()), data,
                              static_cast<int>(n));
    out.resize(len < 0 ? 0 : static_cast<size_t>(len));
    return out;
}
#endif

// Returns whether `c` may appear in an RFC 9110 token.
bool isTokenChar(unsigned char c) {
    if (c >= '0' && c <= '9') return true;
    if ((c | 0x20) >= 'a' && (c | 0x20) <= 'z') return true;
    return std::strchr("!#$%&'*+-.^_`|~", c) != nullptr && c != 0;
}

// Returns whether `s` is a non-empty RFC 9110 token.
bool isToken(std::string_view s) {
    if (s.empty()) return false;
    for (unsigned char c : s) {
        if (!isTokenChar(c)) return false;
    }
    return true;
}

// Returns `s` without leading and trailing spaces and tabs.
std::string_view trimOws(std::string_view s) {
    while (!s.empty() && (s.front() == ' ' || s.front() == '\t')) s.remove_prefix(1);
    while (!s.empty() && (s.back() == ' ' || s.back() == '\t')) s.remove_suffix(1);
    return s;
}

// Returns the lines of `head` up to its first blank line, each without its CR LF or LF. The views point into `head`.
std::vector<std::string_view> headLines(std::string_view head) {
    std::vector<std::string_view> lines;
    size_t at = 0;
    while (at < head.size()) {
        size_t nl = head.find('\n', at);
        if (nl == std::string_view::npos) nl = head.size();
        std::string_view line = head.substr(at, nl - at);
        if (!line.empty() && line.back() == '\r') line.remove_suffix(1);
        at = nl + 1;
        if (line.empty()) break;   // the blank line ends the head
        lines.push_back(line);
    }
    return lines;
}

// Reads `v` as `HTTP/d.d` with single digits, and on success writes "d.d" to `out`.
bool parseVersion(std::string_view v, std::string& out) {
    if (v.size() != 8 || v.substr(0, 5) != "HTTP/" || v[6] != '.') return false;
    if (v[5] < '0' || v[5] > '9' || v[7] < '0' || v[7] > '9') return false;
    out.assign(v.substr(5));
    return true;
}

// Appends the header fields in `lines`, skipping the first (the request or status line), to `out`, and returns
// whether all were valid, with the reason in `err` if not. Fields before the invalid one are already appended.
bool parseFields(const std::vector<std::string_view>& lines, HeaderList& out, std::string& err) {
    for (size_t i = 1; i < lines.size(); ++i) {
        std::string_view line = lines[i];
        if (line.front() == ' ' || line.front() == '\t') {
            err = "obsolete line folding";
            return false;
        }
        size_t colon = line.find(':');
        if (colon == std::string_view::npos) {
            err = "a header line without a colon";
            return false;
        }
        std::string_view name = line.substr(0, colon);
        if (!isToken(name)) {
            err = "an invalid header name";
            return false;
        }
        std::string_view value = trimOws(line.substr(colon + 1));
        for (unsigned char c : value) {
            if ((c < 0x20 && c != '\t') || c == 0x7F) {
                err = "a control character in a header value";
                return false;
            }
        }
        out.emplace_back(std::string(name), std::string(value));
    }
    return true;
}

// Returns `s` with ASCII capitals made lower case.
std::string lowerAscii(std::string s) {
    for (char& c : s) {
        if (c >= 'A' && c <= 'Z') c = static_cast<char>(c + 32);
    }
    return s;
}

// Appends each valid header in `headers` to `out` as a CR LF terminated line. With `skipFraming`, also leaves out
// `Content-Length`, `Transfer-Encoding` and `Connection`, so the caller can write its own.
void appendHeaders(std::string& out, const HeaderList& headers, bool skipFraming) {
    for (const auto& [name, value] : headers) {
        if (!httpHeaderValid(name, value)) continue;
        if (skipFraming) {
            std::string n = lowerAscii(name);
            if (n == "content-length" || n == "transfer-encoding" || n == "connection") continue;
        }
        out += name;
        out += ": ";
        out += value;
        out += "\r\n";
    }
}

// Returns the error code in a `ConnProtocol::onError` reason: the part after the first space ("read ECONNRESET"
// gives "ECONNRESET"), or the whole reason if it has no space.
std::string codeOfReason(const std::string& reason) {
    size_t sp = reason.find(' ');
    return sp == std::string::npos ? reason : reason.substr(sp + 1);
}

} // namespace

// --- Key / accept ----------------------------------------------------------------------

std::string wsAcceptFor(const std::string& key) {
#ifndef _WIN32
    std::string input = key + kGuid;
    unsigned char md[SHA_DIGEST_LENGTH];
    SHA1(reinterpret_cast<const unsigned char*>(input.data()), input.size(), md);
    return base64(md, sizeof md);
#else
    (void)key;
    return std::string();
#endif
}

void wsRandomBytes(unsigned char* out, size_t n) {
    // Callers ask for at most a few KiB at a time, so `n` fits the int / ULONG of the system calls.
#ifndef _WIN32
    if (RAND_bytes(out, static_cast<int>(n)) == 1) return;
    const char* source = "RAND_bytes";
#else
    if (BCryptGenRandom(nullptr, out, static_cast<ULONG>(n), BCRYPT_USE_SYSTEM_PREFERRED_RNG) >= 0) return;
    const char* source = "BCryptGenRandom";
#endif
    // A broken system RNG is a fault of the environment, and masking keys and handshake keys must not silently come
    // from anything weaker. The callers run on the reactor thread, inside write paths, where nothing could catch an
    // exception, so this is fatal, as in OpenSSL's own policy.
    std::fprintf(stderr, "eco: fatal: WebSocket: the system random number generator (%s) failed\n", source);
    std::fflush(stderr);
    std::abort();
}

std::string wsNewKey() {
#ifndef _WIN32
    unsigned char raw[16];
    wsRandomBytes(raw, sizeof raw);
    return base64(raw, sizeof raw);
#else
    return std::string();
#endif
}

// --- HTTP heads --------------------------------------------------------------------------

size_t httpHeadLength(std::string_view buf) {
    size_t crlf = buf.find("\r\n\r\n");
    size_t lf = buf.find("\n\n");
    size_t a = crlf == std::string_view::npos ? std::string_view::npos : crlf + 4;
    size_t b = lf == std::string_view::npos ? std::string_view::npos : lf + 2;
    size_t end = a < b ? a : b;
    return end == std::string_view::npos ? 0 : end;
}

bool parseRequestHead(std::string_view head, HttpHead& out, std::string& err) {
    std::vector<std::string_view> lines = headLines(head);
    if (lines.empty()) {
        err = "an empty request";
        return false;
    }
    std::string_view rl = lines[0];
    size_t sp1 = rl.find(' ');
    size_t sp2 = sp1 == std::string_view::npos ? sp1 : rl.find(' ', sp1 + 1);
    if (sp2 == std::string_view::npos || rl.find(' ', sp2 + 1) != std::string_view::npos) {
        err = "an invalid request line";
        return false;
    }
    std::string_view method = rl.substr(0, sp1);
    std::string_view target = rl.substr(sp1 + 1, sp2 - sp1 - 1);
    if (!isToken(method) || target.empty() || !parseVersion(rl.substr(sp2 + 1), out.version)) {
        err = "an invalid request line";
        return false;
    }
    for (unsigned char c : target) {
        if (c <= 0x20 || c == 0x7F) {
            err = "an invalid request target";
            return false;
        }
    }
    out.method.assign(method);
    out.target.assign(target);
    return parseFields(lines, out.headers, err);
}

bool parseResponseHead(std::string_view head, HttpHead& out, std::string& err) {
    std::vector<std::string_view> lines = headLines(head);
    if (lines.empty()) {
        err = "an empty response";
        return false;
    }
    std::string_view sl = lines[0];
    if (sl.size() < 12 || !parseVersion(sl.substr(0, 8), out.version) || sl[8] != ' ') {
        err = "an invalid status line";
        return false;
    }
    int status = 0;
    for (size_t i = 9; i < 12; ++i) {
        if (sl[i] < '0' || sl[i] > '9') {
            err = "an invalid status line";
            return false;
        }
        status = status * 10 + (sl[i] - '0');
    }
    if (sl.size() > 12 && sl[12] != ' ') {
        err = "an invalid status line";
        return false;
    }
    out.status = status;
    out.reasonPhrase.assign(sl.size() > 13 ? sl.substr(13) : std::string_view());
    return parseFields(lines, out.headers, err);
}

bool httpHeaderValid(const std::string& name, const std::string& value) {
    if (!isToken(name)) return false;
    for (char c : value) {
        if (c == '\r' || c == '\n' || c == '\0') return false;
    }
    return true;
}

std::string serializeRequest(const std::string& target, const HeaderList& headers) {
    std::string out = "GET " + target + " HTTP/1.1\r\n";
    appendHeaders(out, headers, false);
    out += "\r\n";
    return out;
}

std::string serializeResponse(int status, const HeaderList& headers, bool withBody,
                              const std::string& body) {
    std::string out = "HTTP/1.1 " + std::to_string(status) + " " + httpStatusReason(status) + "\r\n";
    appendHeaders(out, headers, withBody);
    if (withBody) {
        out += "Content-Length: " + std::to_string(body.size()) + "\r\n";
        out += "Connection: close\r\n\r\n";
        out += body;
    } else {
        out += "\r\n";
    }
    return out;
}

const char* httpStatusReason(int status) {
    switch (status) {
    case 101: return "Switching Protocols";
    case 200: return "OK";
    case 204: return "No Content";
    case 301: return "Moved Permanently";
    case 302: return "Found";
    case 307: return "Temporary Redirect";
    case 308: return "Permanent Redirect";
    case 400: return "Bad Request";
    case 401: return "Unauthorized";
    case 403: return "Forbidden";
    case 404: return "Not Found";
    case 405: return "Method Not Allowed";
    case 408: return "Request Timeout";
    case 409: return "Conflict";
    case 426: return "Upgrade Required";
    case 429: return "Too Many Requests";
    case 431: return "Request Header Fields Too Large";
    case 500: return "Internal Server Error";
    case 501: return "Not Implemented";
    case 503: return "Service Unavailable";
    default:
        if (status >= 100 && status < 200) return "Informational";
        if (status >= 200 && status < 300) return "Success";
        if (status >= 300 && status < 400) return "Redirection";
        if (status >= 400 && status < 500) return "Client Error";
        return "Server Error";
    }
}

// --- Dial (client) -------------------------------------------------------------------------

namespace {

// The HTTP/1.1 half of a dial: writes the request and reads the response head under the dial's deadline, then
// reports to the job and parks the connection. It reports at most one result.
class DialProtocol final : public ConnProtocol {
public:
    // Creates the protocol for `job`, which it keeps alive.
    explicit DialProtocol(std::shared_ptr<DialJob> job) : job_(std::move(job)) {}

    void onOpen(Conn& c) override {
        if (job_->deadline() > 0) c.setDeadline(Conn::kTimerHeaders, job_->deadline());
        c.write(job_->request(), nullptr);   // failures arrive through onError
    }

    void onData(Conn& c, std::string_view bytes) override {
        if (done_) return;
        buf_.append(bytes.data(), bytes.size());
        size_t n = httpHeadLength(buf_);
        if (n == 0) {
            if (buf_.size() > kMaxHead) fail(c, "ERR_WS_HANDSHAKE", "the response head is larger than 64 KiB");
            return;
        }
        if (n > kMaxHead) {
            fail(c, "ERR_WS_HANDSHAKE", "the response head is larger than 64 KiB");
            return;
        }
        HttpHead head;
        std::string err;
        if (!parseResponseHead(std::string_view(buf_).substr(0, n), head, err)) {
            fail(c, "ERR_WS_HANDSHAKE", "invalid HTTP response: " + err);
            return;
        }
        done_ = true;
        c.setDeadline(Conn::kTimerHeaders, 0);
        std::string leftover = buf_.substr(n);
        buf_.clear();
        job_->headDone(c, std::move(head));
        if (c.phase() == Conn::Phase::Open) {
            c.setProtocol(std::make_unique<HoldProtocol>(), std::move(leftover));   // retires us
        }
    }

    void onEof(Conn& c) override {
        fail(c, "ERR_WS_HANDSHAKE", "the server closed the connection during the opening handshake");
    }

    void onError(Conn& c, int, const std::string& code) override {
        fail(c, codeOfReason(code), code + " " + job_->target());
    }

    void onTimer(Conn& c, int timerId) override {
        if (timerId != Conn::kTimerHeaders) return;
        fail(c, "ETIMEDOUT", "WebSocket handshake ETIMEDOUT " + job_->target());
    }

    void onCloseAll(Conn&) override {
        if (done_) return;
        done_ = true;
        job_->failed("ECANCELED", "connect ECANCELED " + job_->target());
    }

    bool wantsRead() const override { return !done_; }

private:
    // Reports the failure to the job and aborts `c`, unless a result was reported already.
    void fail(Conn& c, const std::string& code, const std::string& message) {
        if (done_) return;
        done_ = true;
        job_->failed(code, message);
        c.abort(false);
    }

    std::shared_ptr<DialJob> job_;
    std::string buf_;
    bool done_ = false;
};

} // namespace

std::string DialJob::target() const {
    size_t i = next_ > 0 ? next_ - 1 : 0;
    std::string addr = i < spec_.addresses.size() ? spec_.addresses[i] : std::string();
    if (addr.find(':') != std::string::npos) addr = "[" + addr + "]";
    return addr + ":" + std::to_string(spec_.port);
}

void DialJob::start() { tryNext(); }

bool DialJob::cancel() {
    int expected = 0;
    if (!resolved.compare_exchange_strong(expected, 2)) return false;   // result already posted
    auto self = shared_from_this();
    reactor().submit([self] {
        std::shared_ptr<Conn> c = std::move(self->current_);
        if (c) c->abort(false);
    });
    return true;
}

void DialJob::tryNext() {
    if (resolved.load(std::memory_order_acquire) != 0) {
        current_.reset();
        return;
    }
    if (next_ >= spec_.addresses.size()) {
        failed(lastCode_.empty() ? std::string("ENOTFOUND") : lastCode_,
               lastMessage_.empty() ? std::string("connect ENOTFOUND") : lastMessage_);
        return;
    }
    int64_t remaining = 0;
    if (spec_.deadlineMs > 0) {
        remaining = spec_.deadlineMs - reactor().nowMs();
        if (remaining <= 0) {
            ++next_;
            failed("ETIMEDOUT", "connect ETIMEDOUT " + target());
            return;
        }
    }
    ConnectSpec cs;
    cs.isUnix = false;
    cs.address = spec_.addresses[next_++];
    cs.port = spec_.port;
    cs.timeoutMs = remaining;
    auto c = Conn::makeClient(std::move(cs), spec_.factory, 0, spec_.gen);
    current_ = c;
    auto self = shared_from_this();
    c->setConnectCallback([self](Conn& conn, bool ok, const std::string& code, const std::string& message) {
        self->onConnect(conn, ok, code, message);
    });
    c->startConnect();
}

void DialJob::onConnect(Conn& c, bool ok, const std::string& code, const std::string& message) {
    if (resolved.load(std::memory_order_acquire) != 0) {   // cancelled meanwhile
        current_.reset();
        if (ok) c.abort(false);
        return;
    }
    if (!ok) {
        lastCode_ = code;
        lastMessage_ = message;
        current_.reset();
        tryNext();
        return;
    }
    if (spec_.http2) {
        // When the server did not choose h2, or `makeHttp2ClientProtocol` returns null, the HTTP/1.1 Upgrade is
        // made on this same connection.
        const TlsInfo* ti = c.tlsInfo();
        if (ti && ti->alpn == "h2") {
            if (auto h2 = makeHttp2ClientProtocol(shared_from_this())) {
                c.setProtocol(std::move(h2), std::string());
                return;
            }
        }
    }
    c.setProtocol(std::make_unique<DialProtocol>(shared_from_this()), std::string());
}

void DialJob::h2HeadDone(Conn& c, int status, HeaderList headers) {
    current_.reset();
    int expected = 0;
    if (!resolved.compare_exchange_strong(expected, 1)) {   // killed: nobody waits
        c.abort(false);
        return;
    }
    WsEvent ev;
    ev.kind = WsEvent::Kind::Dialed;
    ev.gen = spec_.gen;
    ev.token = spec_.token;
    ev.conn = std::static_pointer_cast<Conn>(c.shared_from_this());
    ev.status = status;
    ev.isH2 = true;
    ev.headers = std::move(headers);
    ev.isTls = spec_.isTls;
    postWsEvent(std::move(ev));
}

void DialJob::redialHttp1() {
    current_.reset();
    spec_.http2 = false;
    spec_.factory = spec_.h1Factory;
    if (next_ > 0) --next_;   // the same address again
    tryNext();
}

void DialJob::headDone(Conn& c, HttpHead head) {
    current_.reset();
    int expected = 0;
    if (!resolved.compare_exchange_strong(expected, 1)) {   // killed: nobody waits
        c.abort(false);
        return;
    }
    WsEvent ev;
    ev.kind = WsEvent::Kind::Dialed;
    ev.gen = spec_.gen;
    ev.token = spec_.token;
    ev.conn = std::static_pointer_cast<Conn>(c.shared_from_this());
    ev.status = head.status;
    ev.isH2 = false;   // HTTP/1.1 (h2: h2HeadDone)
    ev.headers = std::move(head.headers);
    ev.isTls = spec_.isTls;
    postWsEvent(std::move(ev));
}

void DialJob::failed(const std::string& code, const std::string& message) {
    current_.reset();
    int expected = 0;
    if (!resolved.compare_exchange_strong(expected, 1)) return;   // cancelled, or resolved already
    WsEvent ev;
    ev.kind = WsEvent::Kind::Dialed;
    ev.gen = spec_.gen;
    ev.token = spec_.token;
    ev.failed = true;
    ev.code = code;
    ev.message = message;
    postWsEvent(std::move(ev));
}

// --- Upgrade read (server) -------------------------------------------------------------------

void UpgradeReadProtocol::onOpen(Conn& c) {
    if (c.eofSeen()) {
        fail(c, "ERR_WS_HANDSHAKE", "the client closed the connection before sending an opening request",
             false);
        return;
    }
    if (timeoutMs_ > 0) c.setDeadline(Conn::kTimerHeaders, reactor().nowMs() + timeoutMs_);
}

void UpgradeReadProtocol::onData(Conn& c, std::string_view bytes) {
    if (done_) return;
    buf_.append(bytes.data(), bytes.size());
    size_t n = httpHeadLength(buf_);
    if (n == 0) {
        if (buf_.size() > kMaxHead) fail(c, "ERR_WS_HANDSHAKE", "the request head is larger than 64 KiB", true);
        return;
    }
    HttpHead head;
    std::string err;
    if (n > kMaxHead) {
        fail(c, "ERR_WS_HANDSHAKE", "the request head is larger than 64 KiB", true);
        return;
    }
    if (!parseRequestHead(std::string_view(buf_).substr(0, n), head, err)) {
        fail(c, "ERR_WS_HANDSHAKE", "invalid HTTP request: " + err, true);
        return;
    }
    done_ = true;
    c.setDeadline(Conn::kTimerHeaders, 0);
    std::string leftover = buf_.substr(n);
    buf_.clear();
    SocketEvent se;
    c.describe(se, std::string());
    WsEvent ev;
    ev.kind = WsEvent::Kind::UpgradeRead;
    ev.gen = gen_;
    ev.token = token_;
    ev.conn = std::static_pointer_cast<Conn>(c.shared_from_this());
    ev.method = std::move(head.method);
    ev.target = std::move(head.target);
    ev.version = std::move(head.version);
    ev.headers = std::move(head.headers);
    ev.local = se.local;
    ev.remote = se.remote;
    ev.isTls = se.hasTls;
    postWsEvent(std::move(ev));
    c.setProtocol(std::make_unique<HoldProtocol>(), std::move(leftover));   // retires us
}

void UpgradeReadProtocol::onEof(Conn& c) {
    fail(c, "ERR_WS_HANDSHAKE", "the client closed the connection before sending an opening request",
         false);
}

void UpgradeReadProtocol::onError(Conn& c, int, const std::string& code) {
    fail(c, codeOfReason(code), code, false);
}

void UpgradeReadProtocol::onTimer(Conn& c, int timerId) {
    if (timerId != Conn::kTimerHeaders) return;
    fail(c, "ETIMEDOUT", "upgradeRequest ETIMEDOUT", false);
}

void UpgradeReadProtocol::onCloseAll(Conn&) {
    if (done_) return;
    done_ = true;
    WsEvent ev;
    ev.kind = WsEvent::Kind::UpgradeRead;
    ev.gen = gen_;
    ev.token = token_;
    ev.failed = true;
    ev.code = "ECANCELED";
    ev.message = "socket closed";
    postWsEvent(std::move(ev));
}

void UpgradeReadProtocol::fail(Conn& c, const std::string& code, const std::string& message,
                               bool answer400) {
    if (done_) return;
    done_ = true;
    c.setDeadline(Conn::kTimerHeaders, 0);
    WsEvent ev;
    ev.kind = WsEvent::Kind::UpgradeRead;
    ev.gen = gen_;
    ev.token = token_;
    ev.failed = true;
    ev.code = code;
    ev.message = message;
    postWsEvent(std::move(ev));
    if (answer400) {
        c.write(serializeResponse(400, HeaderList{}, true, std::string()), nullptr);
        c.closeGraceful(Conn::kFaceDrainMs);
    } else {
        c.abort(false);
    }
}

} // namespace Eco::System
