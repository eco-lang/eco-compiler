//===- Http1.hpp - HTTP/1.1 server connections on the IoReactor -----------===//
//
// plans/eco-system-websockets.md §3.4 (W9, phase WS2). Http1Protocol is the
// ConnProtocol (§3.2) of one accepted Http.Server connection: an llhttp
// request parser (strict: no lenient flag is ever set) driving the state
// machine
//
//   Idle → Reading → AwaitingElm → (response queued) → Idle (keep-alive) …
//                  ↘ UpgradePending → (declined: response) → Closing
//   any state → Closing (error, limit, timeout, server close, peer EOF)
//
// REACTOR THREAD ONLY (G1): no heap access; complete requests go to the
// main thread as POD HttpEvents (HttpTables.hpp), responses come back as
// reactor commands (respond()).
//
//   * One request in flight: llhttp is paused at on_message_complete;
//     nothing more is parsed until the response is queued (Conn::write);
//     then llhttp_resume and the bytes already buffered are parsed, so
//     pipelined requests are answered in order. While a request waits for
//     Elm, reading continues only until kPipelineBuffer bytes are buffered
//     (so a peer's FIN or reset is still noticed), then TCP back-pressures
//     the client. Reading also pauses while the response queue is above
//     Conn::kLowWatermark (onWritable resumes it).
//   * Limits (ServerConfig): the request line + header block ≤
//     maxHeaderSize (431); the body ≤ maxBodySize (413, checked against
//     Content-Length before any 100-continue, and as a running total).
//     Every error response closes the connection (Connection: close, then
//     Conn::closeGraceful: FIN, discard input until EOF or the drain
//     deadline, N8).
//   * Timers (Conn ids): kTimerHeaders from the first byte of a request to
//     the end of its headers, kTimerRequest from the first byte to the end
//     of the body (408 + close); kTimerIdle while Idle (keep-alive: close
//     silently; a fresh connection waits headersTimeout for its first
//     byte). A timeout of 0 or less is none. No timer runs while Elm
//     answers. After closeServer, kTimerIdle is the server's deadline
//     (abort).
//   * Expect: "100-continue" (case-insensitive) on a request with a body
//     is answered "HTTP/1.1 100 Continue" when the request is parsed, which
//     is always after every earlier response was queued (one in flight);
//     never when Content-Length exceeds maxBodySize (413). Any other Expect
//     value: 417 + close.
//   * Host (E.5 revised): HTTP/1.1 needs exactly one Host header, HTTP/1.0
//     at most one; a value that is not `host [":" port]` (RFC 3986 reg-name,
//     IPv4, or a bracketed IPv6 literal) → 400. The request URL is "http://"
//     + Host (or the server's fallback authority) + the target; an
//     absolute-form target is kept as is.
//   * Versions other than HTTP/1.0 and HTTP/1.1 → 505.
//   * Upgrade / CONNECT: llhttp's upgrade flag (Upgrade + Connection:
//     upgrade, or CONNECT) is recorded at on_message_complete. An upgrade
//     request without a body is delivered with its first Upgrade token
//     (lower-cased) and the connection enters UpgradePending: the bytes
//     after the request (the "head") are kept for the hand-off (WS5,
//     takeUpgradeHead). CONNECT and upgrade requests with a body are
//     delivered without a token. In every case llhttp_resume_after_upgrade
//     is never called, so any response other than a hand-off is written
//     with Connection: close and the connection closes (no h2c smuggling).
//   * Responses (respond): serializeH1 with keep-alive iff the request
//     allows it (llhttp_should_keep_alive), the server is not closing, the
//     user's headers do not say Connection: close, the request was not an
//     upgrade/CONNECT, and the peer has not half-closed with nothing more
//     buffered.
//   * Half-close: after the peer's FIN the in-flight request and the
//     requests already buffered are answered, then the connection closes.
//
// Connection bookkeeping shared with the main thread's tables:
//   * ServerReactorState (one per server, reactor thread only once shared):
//     the config, the closing flag and deadline, the live connections
//     (closeServer walks them).
//   * ConnShared (one per connection): the key of the request in flight and
//     the peer's endpoint. The Conn's close hook posts ConnGone{key} with
//     it and unregisters the connection; it never touches the protocol, so
//     a protocol handed off later (WS5) leaves nothing dangling.
//
// Hooks for the WS5 hand-off (Http.Server.upgradeRequest): upgradePending,
// takeUpgradeHead (ends HTTP/1.1 on the connection and clears the key; the
// caller then installs the WebSocket protocol with Conn::setProtocol).
//
// Templates used: none (POD only, G1).
//
//===----------------------------------------------------------------------===//

#ifndef ECO_SYSTEM_HTTP_SERVER_HTTP1_HPP
#define ECO_SYSTEM_HTTP_SERVER_HTTP1_HPP

#include "eco-system/HttpServer/HttpServerService.hpp"
#include "eco-system/Socket/Conn.hpp"

#include <atomic>
#include <cstdint>
#include <functional>
#include <memory>
#include <string>
#include <string_view>
#include <unordered_map>
#include <utility>
#include <vector>

#ifndef _WIN32
#include <llhttp.h>
#endif

namespace Eco::System::HttpSrv {

// Immutable once the server is created; read on both threads.
struct ServerConfig {
    int64_t serverId = 0;
    uint64_t gen = 0;               // heap generation of createServer
    bool tls = false;               // TLS (WS3): URL scheme https, flags bit 2
    bool http2 = false;             // createServerWith's http2: ALPN h2 (Http2.cpp, WS8)
    std::string fallbackAuthority;  // host:port for requests without Host (E.5)
    int64_t maxBodySize = 16 * 1024 * 1024;
    int64_t maxHeaderSize = 64 * 1024;
    int64_t keepAliveMs = 5000;
    int64_t headersMs = 60000;
    int64_t requestMs = 300000;
    int64_t maxConcurrentStreams = -1;   // HTTP/2 (WS8): -1 unlimited (W19)
};

// Reactor thread only (the main thread only passes the shared_ptr around).
struct ServerReactorState {
    std::shared_ptr<const ServerConfig> cfg;
    bool closing = false;
    int64_t closeDeadline = 0;   // monotonic ms (IoReactor::nowMs)
    std::unordered_map<Conn*, std::weak_ptr<Conn>> conns;
};

// Per connection; reactor thread only.
struct ConnShared {
    int64_t key = 0;   // the request in flight (delivered or about to be), 0: none
    SockEndpoint remote;
};

// The factory of ListenerHandler's callback mode: registers `c` with the
// server, installs the close hook (ConnGone) and returns the protocol.
std::unique_ptr<ConnProtocol> makeHttp1Protocol(Conn& c,
                                                const std::shared_ptr<ServerReactorState>& srv);

// The callback-mode factory of every Http.Server listener (websockets plan
// §3.5, WS3). It runs once the connection is established, i.e. after the TLS
// handshake of an https server, and dispatches on the ALPN protocol the
// handshake chose (Conn::tlsInfo()->alpn): "h2" → Http2Protocol (phase WS8),
// anything else (http/1.1, or no ALPN: plain TCP, a client that offered
// none, or the NoAck fallback) → makeHttp1Protocol. Only servers created
// with http2 offer "h2" (HttpServer.cpp httpServerAlpn).
std::unique_ptr<ConnProtocol> makeServerProtocol(Conn& c,
                                                 const std::shared_ptr<ServerReactorState>& srv);

// Reactor command of closeServer: marks the server closing with `deadline`
// and tells every live HTTP/1.1 connection (idle ones close at once) and
// every HTTP/2 connection (GOAWAY, Http2.cpp).
void http1ServerClosing(const std::shared_ptr<ServerReactorState>& srv, int64_t deadline);

// Reactor command of respond: answers `key` on `conn` if it is still the
// request in flight there (HTTP/1.1) or a delivered, unanswered stream
// (HTTP/2, Http2Protocol::respond); `done` is moved into the write and runs
// once the transport took the bytes (or failed). False (and `done` left
// untouched) when the key is not in flight on a live connection.
// `forceClose`: Connection: close (the 503s of closeServer).
bool http1Respond(const std::shared_ptr<Conn>& conn, int64_t key, ResponseData r, bool forceClose,
                  std::function<void(int err)>& done);

// Response keys: unique per process (any thread).
int64_t nextResponseKey();

#ifndef _WIN32

class Http1Protocol final : public ConnProtocol {
public:
    // Bytes buffered (not yet parsed) beyond which reading pauses while a
    // request waits for Elm or an upgrade.
    static constexpr size_t kPipelineBuffer = 64 * 1024;
    // The drain deadline of a close after a response or an error (bounds the
    // queued response too, Conn::closeGraceful).
    static constexpr int64_t kCloseDrainMs = 10000;

    Http1Protocol(std::shared_ptr<ServerReactorState> srv, std::shared_ptr<ConnShared> cs);
    ~Http1Protocol() override = default;

    void onOpen(Conn& c) override;
    void onData(Conn& c, std::string_view bytes) override;
    void onEof(Conn& c) override;
    void onError(Conn& c, int err, const std::string& code) override;
    void onWritable(Conn& c) override;
    void onTimer(Conn& c, int timerId) override;
    void onCloseAll(Conn& c) override;
    bool wantsRead() const override;

    bool respond(Conn& c, int64_t key, ResponseData r, bool forceClose,
                 std::function<void(int)>& done);
    void serverClosing(Conn& c);

    // --- WS5 hand-off -----------------------------------------------------------
    // True while `key` is an upgrade request waiting for its answer.
    bool upgradePending(int64_t key) const;
    // Ends HTTP/1.1 on this connection for `key` (precondition:
    // upgradePending(key)): clears the key and the timers and returns the
    // bytes read past the request. The caller installs the next protocol
    // with Conn::setProtocol(p, head) in the same reactor step.
    std::string takeUpgradeHead(Conn& c, int64_t key);

    Http1Protocol(const Http1Protocol&) = delete;
    Http1Protocol& operator=(const Http1Protocol&) = delete;

private:
    enum class State : uint8_t { Idle, Reading, AwaitingElm, UpgradePending, Closing, Done };

    // llhttp callbacks (parser.data = this).
    static int cbMessageBegin(llhttp_t* p);
    static int cbUrl(llhttp_t* p, const char* at, size_t n);
    static int cbHeaderField(llhttp_t* p, const char* at, size_t n);
    static int cbHeaderValue(llhttp_t* p, const char* at, size_t n);
    static int cbHeadersComplete(llhttp_t* p);
    static int cbBody(llhttp_t* p, const char* at, size_t n);
    static int cbMessageComplete(llhttp_t* p);
    static const llhttp_settings_t& settings();

    bool countHeaderBytes(size_t n);
    int headersComplete();
    void resetRequest();
    void startRequest(Conn& c);
    void parse(Conn& c);
    void messageComplete(Conn& c);
    void failRequest(Conn& c, int64_t status);
    void closeNow(Conn& c);
    void afterResponse(Conn& c);
    void eofWhileReading(Conn& c);
    std::string absoluteUrl(const std::string& host) const;

    std::shared_ptr<ServerReactorState> srv_;
    std::shared_ptr<ConnShared> cs_;
    const ServerConfig& cfg_;
    llhttp_t parser_;
    Conn* cur_ = nullptr;          // the Conn while llhttp runs (100-continue)

    State state_ = State::Idle;
    std::string in_;               // read, not parsed yet
    bool peerEof_ = false;
    bool outHigh_ = false;         // the response queue reached Conn::kLowWatermark

    // The request being parsed.
    std::string url_;
    std::vector<std::pair<std::string, std::string>> headers_;
    bool inValue_ = false;
    std::string body_;
    size_t headerBytes_ = 0;
    int64_t errorStatus_ = 0;      // a limit / rule broken in a callback (HPE_USER)
    bool messageDone_ = false;

    // The request in flight (after on_message_complete).
    bool isHead_ = false;
    bool shouldKeepAlive_ = false;
    bool mustClose_ = false;       // upgrade / CONNECT: never parse past it
};

#endif // !_WIN32

} // namespace Eco::System::HttpSrv

#endif // ECO_SYSTEM_HTTP_SERVER_HTTP1_HPP
