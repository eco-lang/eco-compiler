//===- Http1.cpp - HTTP/1.1 server connections on the IoReactor -----------===//
//
// See Http1.hpp (plans/eco-system-websockets.md §3.4, phase WS2). Reactor
// thread only; POSIX (llhttp is not built on Windows, where
// HttpServerServiceWin32.cpp provides the stubs).
//
// Templates used: none (POD only, G1).
//
//===----------------------------------------------------------------------===//

#include "eco-system/HttpServer/Http1.hpp"

#include "eco-system/Core/IoReactor.hpp"
#include "eco-system/HttpServer/Http2.hpp"
#include "eco-system/HttpServer/HttpTables.hpp"

#include <algorithm>
#include <cctype>
#include <cstring>
#include <utility>

namespace Eco::System::HttpSrv {

namespace {

std::atomic<int64_t> g_nextKey{1};

IoReactor& reactor() { return IoReactor::instance(); }

// The deadline `ms` from now; a timeout of 0 or less is none (0 cancels).
int64_t after(int64_t ms) { return ms > 0 ? reactor().nowMs() + ms : 0; }

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

std::string trim(const std::string& s, size_t a, size_t b) {
    while (a < b && (s[a] == ' ' || s[a] == '\t')) ++a;
    while (b > a && (s[b - 1] == ' ' || s[b - 1] == '\t')) --b;
    return s.substr(a, b - a);
}

std::string lowerAscii(std::string s) {
    for (char& c : s) c = static_cast<char>(std::tolower(static_cast<unsigned char>(c)));
    return s;
}

// The first element of a comma-separated list, trimmed and lower-cased.
std::string firstToken(const std::string& v) {
    size_t j = v.find(',');
    return lowerAscii(trim(v, 0, j == std::string::npos ? v.size() : j));
}

bool isHex(char c) { return std::isxdigit(static_cast<unsigned char>(c)) != 0; }

bool isRegNameChar(char c) {
    if (std::isalnum(static_cast<unsigned char>(c))) return true;
    return std::strchr("-._~!$&'()*+,;=", c) != nullptr && c != '\0';
}

// RFC 9110 §7.2: Host = uri-host [ ":" port ]; uri-host is an IP-literal
// ("[" IPv6 / IPvFuture "]"), an IPv4 address or a reg-name (unreserved,
// pct-encoded, sub-delims). An empty value is refused (§3.4: invalid).
bool validHost(const std::string& h) {
    if (h.empty()) return false;
    size_t i = 0;
    if (h[0] == '[') {
        size_t close = h.find(']');
        if (close == std::string::npos || close < 2) return false;
        bool colon = false;
        for (size_t k = 1; k < close; ++k) {
            char c = h[k];
            if (c == ':') colon = true;
            if (!(isHex(c) || c == ':' || c == '.' || c == '%' || isRegNameChar(c))) return false;
        }
        if (!colon) return false;
        i = close + 1;
    } else {
        size_t n = 0;
        while (i < h.size() && h[i] != ':') {
            char c = h[i];
            if (c == '%') {
                if (i + 2 >= h.size() || !isHex(h[i + 1]) || !isHex(h[i + 2])) return false;
                i += 3;
                ++n;
                continue;
            }
            if (!isRegNameChar(c)) return false;
            ++i;
            ++n;
        }
        if (n == 0) return false;
    }
    if (i == h.size()) return true;
    if (h[i] != ':') return false;
    ++i;
    if (h.size() - i > 5) return false;
    for (; i < h.size(); ++i) {
        if (!std::isdigit(static_cast<unsigned char>(h[i]))) return false;
    }
    return true;
}

Http1Protocol* self(llhttp_t* p) { return static_cast<Http1Protocol*>(p->data); }

constexpr const char k100Continue[] = "HTTP/1.1 100 Continue\r\n\r\n";

} // namespace

int64_t nextResponseKey() { return g_nextKey.fetch_add(1, std::memory_order_relaxed); }

// ---------------------------------------------------------------------------
// llhttp
// ---------------------------------------------------------------------------

const llhttp_settings_t& Http1Protocol::settings() {
    static const llhttp_settings_t s = [] {
        llhttp_settings_t st;
        llhttp_settings_init(&st);
        st.on_message_begin = &Http1Protocol::cbMessageBegin;
        st.on_url = &Http1Protocol::cbUrl;
        st.on_header_field = &Http1Protocol::cbHeaderField;
        st.on_header_value = &Http1Protocol::cbHeaderValue;
        st.on_headers_complete = &Http1Protocol::cbHeadersComplete;
        st.on_body = &Http1Protocol::cbBody;
        st.on_message_complete = &Http1Protocol::cbMessageComplete;
        return st;
    }();
    return s;
}

int Http1Protocol::cbMessageBegin(llhttp_t* p) {
    self(p)->resetRequest();
    return 0;
}

bool Http1Protocol::countHeaderBytes(size_t n) {
    headerBytes_ += n;
    if (static_cast<int64_t>(headerBytes_) > cfg_.maxHeaderSize) {
        errorStatus_ = 431;
        return false;
    }
    return true;
}

int Http1Protocol::cbUrl(llhttp_t* p, const char* at, size_t n) {
    Http1Protocol* s = self(p);
    if (!s->countHeaderBytes(n)) return HPE_USER;
    s->url_.append(at, n);
    return 0;
}

int Http1Protocol::cbHeaderField(llhttp_t* p, const char* at, size_t n) {
    Http1Protocol* s = self(p);
    if (!s->countHeaderBytes(n)) return HPE_USER;
    if (s->headers_.empty() || s->inValue_) {
        s->headers_.emplace_back();
        s->inValue_ = false;
    }
    s->headers_.back().first.append(at, n);
    return 0;
}

int Http1Protocol::cbHeaderValue(llhttp_t* p, const char* at, size_t n) {
    Http1Protocol* s = self(p);
    if (!s->countHeaderBytes(n)) return HPE_USER;
    if (s->headers_.empty()) s->headers_.emplace_back();
    s->inValue_ = true;
    s->headers_.back().second.append(at, n);
    return 0;
}

int Http1Protocol::cbHeadersComplete(llhttp_t* p) { return self(p)->headersComplete(); }

int Http1Protocol::headersComplete() {
    if (parser_.http_major != 1 || parser_.http_minor > 1) {
        errorStatus_ = 505;
        return -1;
    }
    // Host (§3.4): exactly one for HTTP/1.1, at most one for HTTP/1.0,
    // with a valid value.
    int hosts = 0;
    bool hostOk = true;
    const std::string* expect = nullptr;
    int expects = 0;
    for (const auto& h : headers_) {
        if (iequals(h.first, "host")) {
            ++hosts;
            if (!validHost(trim(h.second, 0, h.second.size()))) hostOk = false;
        } else if (iequals(h.first, "expect")) {
            ++expects;
            expect = &h.second;
        }
    }
    if (hosts > 1 || !hostOk || (hosts == 0 && parser_.http_minor == 1)) {
        errorStatus_ = 400;
        return -1;
    }
    bool hasBody = (parser_.flags & F_CHUNKED) != 0 || parser_.content_length > 0;
    if ((parser_.flags & F_CONTENT_LENGTH) != 0 &&
        parser_.content_length > static_cast<uint64_t>(cfg_.maxBodySize)) {
        errorStatus_ = 413;   // before any 100-continue
        return -1;
    }
    if (expects > 0) {
        if (expects > 1 || !iequals(trim(*expect, 0, expect->size()), "100-continue")) {
            errorStatus_ = 417;
            return -1;
        }
        // At the head of the pipeline by construction (one in flight): every
        // earlier response is queued before this one is parsed.
        if (hasBody && cur_ != nullptr) cur_->write(std::string(k100Continue), nullptr);
    }
    if (cur_ != nullptr) cur_->setDeadline(Conn::kTimerHeaders, 0);
    return 0;
}

int Http1Protocol::cbBody(llhttp_t* p, const char* at, size_t n) {
    Http1Protocol* s = self(p);
    if (static_cast<int64_t>(s->body_.size() + n) > s->cfg_.maxBodySize) {
        s->errorStatus_ = 413;   // the running total of a chunked body
        return HPE_USER;
    }
    s->body_.append(at, n);
    return 0;
}

int Http1Protocol::cbMessageComplete(llhttp_t* p) {
    Http1Protocol* s = self(p);
    s->messageDone_ = true;
    s->isHead_ = p->method == HTTP_HEAD;
    s->shouldKeepAlive_ = llhttp_should_keep_alive(p) != 0;
    s->mustClose_ = llhttp_get_upgrade(p) != 0;   // Upgrade + Connection: upgrade, or CONNECT
    return HPE_PAUSED;   // one request in flight
}

// ---------------------------------------------------------------------------
// The protocol
// ---------------------------------------------------------------------------

Http1Protocol::Http1Protocol(std::shared_ptr<ServerReactorState> srv, std::shared_ptr<ConnShared> cs)
    : srv_(std::move(srv)), cs_(std::move(cs)), cfg_(*srv_->cfg) {
    llhttp_init(&parser_, HTTP_REQUEST, &settings());   // strict: no lenient flags, ever
    parser_.data = this;
}

void Http1Protocol::resetRequest() {
    url_.clear();
    headers_.clear();
    inValue_ = false;
    body_.clear();
    headerBytes_ = 0;
    errorStatus_ = 0;
    messageDone_ = false;
}

void Http1Protocol::onOpen(Conn& c) {
    state_ = State::Idle;
    // A fresh connection gets headersTimeout for its first byte (slowloris).
    if (srv_->closing) {
        closeNow(c);
        return;
    }
    c.setDeadline(Conn::kTimerIdle, after(cfg_.headersMs));
}

bool Http1Protocol::wantsRead() const {
    if (peerEof_ || outHigh_) return false;
    switch (state_) {
    case State::Idle:
    case State::Reading:
        return true;
    case State::AwaitingElm:
    case State::UpgradePending:
        return in_.size() < kPipelineBuffer;
    default:
        return false;
    }
}

void Http1Protocol::onData(Conn& c, std::string_view bytes) {
    if (state_ == State::Closing || state_ == State::Done) return;
    in_.append(bytes.data(), bytes.size());
    if (state_ == State::Idle || state_ == State::Reading) parse(c);
}

void Http1Protocol::startRequest(Conn& c) {
    state_ = State::Reading;
    resetRequest();
    if (!srv_->closing) c.setDeadline(Conn::kTimerIdle, 0);   // else: the server's deadline
    c.setDeadline(Conn::kTimerHeaders, after(cfg_.headersMs));
    c.setDeadline(Conn::kTimerRequest, after(cfg_.requestMs));
}

void Http1Protocol::parse(Conn& c) {
    while (!in_.empty()) {
        if (state_ == State::Idle) startRequest(c);
        if (state_ != State::Reading) return;
        messageDone_ = false;
        cur_ = &c;
        llhttp_errno_t err = llhttp_execute(&parser_, in_.data(), in_.size());
        cur_ = nullptr;
        if (state_ != State::Reading) return;
        if (err == HPE_OK) {
            in_.clear();   // all consumed (llhttp keeps its own state)
            return;
        }
        if ((err == HPE_PAUSED || err == HPE_PAUSED_UPGRADE) && messageDone_) {
            const char* pos = llhttp_get_error_pos(&parser_);
            size_t used = in_.size();
            if (pos != nullptr && pos >= in_.data() && pos <= in_.data() + in_.size()) {
                used = static_cast<size_t>(pos - in_.data());
            }
            in_.erase(0, used);
            messageComplete(c);
            return;   // one in flight: the rest waits for the response
        }
        // A parse error (strict llhttp: smuggling attempts land here) or a
        // limit / rule broken in a callback.
        failRequest(c, errorStatus_ != 0 ? errorStatus_ : 400);
        return;
    }
}

std::string Http1Protocol::absoluteUrl(const std::string& host) const {
    const std::string& target = url_;
    if (target.rfind("http://", 0) == 0 || target.rfind("https://", 0) == 0) return target;
    std::string authority = host.empty() ? cfg_.fallbackAuthority : host;
    std::string path =
        !target.empty() && target[0] == '/' ? target : "/" + (target == "*" ? std::string() : target);
    return (cfg_.tls ? "https://" : "http://") + authority + path;
}

void Http1Protocol::messageComplete(Conn& c) {
    c.setDeadline(Conn::kTimerHeaders, 0);
    c.setDeadline(Conn::kTimerRequest, 0);
    int64_t key = nextResponseKey();
    cs_->key = key;

    HttpEvent ev;
    ev.kind = HttpEvent::Kind::Request;
    ev.gen = cfg_.gen;
    ev.serverId = cfg_.serverId;
    ev.key = key;
    ev.conn = std::static_pointer_cast<Conn>(c.shared_from_this());
    RequestData& r = ev.req;
    const char* m = llhttp_method_name(static_cast<llhttp_method_t>(parser_.method));
    r.method = m ? m : "GET";
    r.target = url_;
    std::string host, upgradeHeader;
    bool hasUpgradeHeader = false;
    for (const auto& h : headers_) {
        if (host.empty() && iequals(h.first, "host")) host = trim(h.second, 0, h.second.size());
        if (!hasUpgradeHeader && iequals(h.first, "upgrade")) {
            hasUpgradeHeader = true;
            upgradeHeader = h.second;
        }
    }
    r.url = absoluteUrl(host);
    r.flags = (parser_.http_minor == 0 ? 0 : 1) | (cfg_.tls ? 4 : 0);
    r.isHead = isHead_;
    r.remote = cs_->remote;
    bool isConnect = parser_.method == HTTP_CONNECT;
    // An upgrade request with a body is a normal request whose upgrade is
    // refused (§3.4); CONNECT carries no token. Both still close afterwards
    // (mustClose_).
    if (mustClose_ && !isConnect && body_.empty() && hasUpgradeHeader) {
        r.upgrade = firstToken(upgradeHeader);
    }
    r.headers = std::move(headers_);
    r.body = std::move(body_);
    headers_.clear();
    body_.clear();
    state_ = r.upgrade.empty() ? State::AwaitingElm : State::UpgradePending;
    postHttpEvent(std::move(ev));
}

void Http1Protocol::closeNow(Conn& c) {
    state_ = State::Closing;
    cs_->key = 0;
    c.setDeadline(Conn::kTimerHeaders, 0);
    c.setDeadline(Conn::kTimerRequest, 0);
    c.setDeadline(Conn::kTimerIdle, 0);
    c.closeGraceful(kCloseDrainMs);
}

void Http1Protocol::failRequest(Conn& c, int64_t status) {
    ResponseData r;
    r.status = status;
    H1Options o;
    o.keepAlive = false;
    c.write(serializeH1(r, o), nullptr);
    closeNow(c);
}

bool Http1Protocol::respond(Conn& c, int64_t key, ResponseData r, bool forceClose,
                            std::function<void(int)>& done) {
    if (key == 0 || cs_->key != key ||
        (state_ != State::AwaitingElm && state_ != State::UpgradePending)) {
        return false;
    }
    bool keepAlive = !forceClose && !mustClose_ && shouldKeepAlive_ && !srv_->closing &&
                     !headersAskClose(r.headers) && !(peerEof_ && in_.empty());
    H1Options o;
    o.isHead = isHead_;
    o.keepAlive = keepAlive;
    cs_->key = 0;
    c.write(serializeH1(r, o), std::move(done));
    if (c.outbound() >= Conn::kLowWatermark) outHigh_ = true;
    if (!keepAlive) {
        closeNow(c);
        return true;
    }
    state_ = State::Idle;
    llhttp_resume(&parser_);
    afterResponse(c);
    return true;
}

void Http1Protocol::afterResponse(Conn& c) {
    if (!in_.empty()) parse(c);   // pipelined requests, in order
    if (state_ == State::Reading && peerEof_) {
        eofWhileReading(c);   // the peer's FIN came during the last request: nothing more follows
        return;
    }
    if (state_ == State::Idle) {
        if (peerEof_ || srv_->closing) {
            closeNow(c);
            return;
        }
        c.setDeadline(Conn::kTimerIdle, after(cfg_.keepAliveMs));
    }
    c.updateInterest();
}

void Http1Protocol::serverClosing(Conn& c) {
    switch (state_) {
    case State::Idle:
        closeNow(c);   // nothing in flight
        return;
    case State::Reading:
    case State::AwaitingElm:
    case State::UpgradePending:
        // Finishes with Connection: close, or is aborted at the deadline.
        c.setDeadline(Conn::kTimerIdle, srv_->closeDeadline);
        return;
    default:
        return;
    }
}

void Http1Protocol::onEof(Conn& c) {
    peerEof_ = true;
    switch (state_) {
    case State::Idle:
        closeNow(c);
        return;
    case State::Reading:
        eofWhileReading(c);
        return;
    default:
        return;   // a request waits for Elm: answered, then closed
    }
}

void Http1Protocol::eofWhileReading(Conn& c) {
    // Between messages (only CRLFs seen): close; mid-request: 400.
    if (llhttp_finish(&parser_) == HPE_OK) {
        closeNow(c);
    } else {
        failRequest(c, 400);
    }
}

void Http1Protocol::onError(Conn& c, int /*err*/, const std::string& /*code*/) {
    // The peer reset the connection or a write failed: nothing more can be
    // exchanged. The close hook reports the request in flight (ConnGone).
    if (state_ != State::Done) c.abort(false);
}

void Http1Protocol::onWritable(Conn& c) {
    if (!outHigh_) return;
    outHigh_ = false;
    c.updateInterest();
}

void Http1Protocol::onTimer(Conn& c, int timerId) {
    if (state_ == State::Closing || state_ == State::Done) return;
    if (timerId == Conn::kTimerIdle) {
        if (srv_->closing && state_ != State::Idle) {
            c.abort(false);   // closeServer's deadline
            return;
        }
        if (state_ == State::Idle) closeNow(c);   // keep-alive (or first-byte) timeout
        return;
    }
    if ((timerId == Conn::kTimerHeaders || timerId == Conn::kTimerRequest) &&
        state_ == State::Reading) {
        failRequest(c, 408);
    }
}

void Http1Protocol::onCloseAll(Conn& /*c*/) { state_ = State::Done; }

bool Http1Protocol::upgradePending(int64_t key) const {
    return key != 0 && state_ == State::UpgradePending && cs_->key == key;
}

std::string Http1Protocol::takeUpgradeHead(Conn& c, int64_t key) {
    if (!upgradePending(key)) return std::string();
    state_ = State::Done;
    cs_->key = 0;
    c.setDeadline(Conn::kTimerHeaders, 0);
    c.setDeadline(Conn::kTimerRequest, 0);
    c.setDeadline(Conn::kTimerIdle, 0);
    std::string head = std::move(in_);
    in_.clear();
    return head;
}

// ---------------------------------------------------------------------------
// Server-level helpers
// ---------------------------------------------------------------------------

std::unique_ptr<ConnProtocol> makeHttp1Protocol(Conn& c,
                                                const std::shared_ptr<ServerReactorState>& srv) {
    auto cs = std::make_shared<ConnShared>();
    {
        SocketEvent tmp;
        c.describe(tmp, std::string());
        cs->remote = tmp.remote;
    }
    (void)c.setNoDelay(true);
    srv->conns[&c] = std::static_pointer_cast<Conn>(c.shared_from_this());
    std::weak_ptr<ServerReactorState> weak = srv;
    uint64_t gen = srv->cfg->gen;
    int64_t serverId = srv->cfg->serverId;
    c.addCloseHook([weak, cs, gen, serverId](Conn& conn) {
        if (auto s = weak.lock()) s->conns.erase(&conn);
        if (cs->key != 0) {
            HttpEvent ev;
            ev.kind = HttpEvent::Kind::ConnGone;
            ev.gen = gen;
            ev.serverId = serverId;
            ev.key = cs->key;
            cs->key = 0;
            postHttpEvent(std::move(ev));
        }
    });
    return std::make_unique<Http1Protocol>(srv, cs);
}

std::unique_ptr<ConnProtocol> makeServerProtocol(Conn& c,
                                                 const std::shared_ptr<ServerReactorState>& srv) {
    const TlsInfo* tls = c.tlsInfo();
    if (tls && tls->alpn == "h2" && srv->cfg->http2) return makeHttp2Protocol(c, srv);
    return makeHttp1Protocol(c, srv);
}

void http1ServerClosing(const std::shared_ptr<ServerReactorState>& srv, int64_t deadline) {
    srv->closing = true;
    srv->closeDeadline = deadline;
    // Copy first: closing connections leave the map from their close hooks.
    std::vector<std::shared_ptr<Conn>> live;
    live.reserve(srv->conns.size());
    for (auto& kv : srv->conns) {
        if (auto c = kv.second.lock()) live.push_back(std::move(c));
    }
    for (auto& c : live) {
        // Connections handed to another protocol (WebSocket, WS5) are
        // detached from the server and stay open.
        if (auto* p = dynamic_cast<Http1Protocol*>(c->protocol())) p->serverClosing(*c);
        else if (auto* p2 = dynamic_cast<Http2Protocol*>(c->protocol())) p2->serverClosing(*c);
    }
}

bool http1Respond(const std::shared_ptr<Conn>& conn, int64_t key, ResponseData r, bool forceClose,
                  std::function<void(int)>& done) {
    if (!conn) return false;
    if (auto* p = dynamic_cast<Http1Protocol*>(conn->protocol()))
        return p->respond(*conn, key, std::move(r), forceClose, done);
    if (auto* p2 = dynamic_cast<Http2Protocol*>(conn->protocol()))
        return p2->respond(*conn, key, std::move(r), forceClose, done);
    return false;
}

} // namespace Eco::System::HttpSrv
