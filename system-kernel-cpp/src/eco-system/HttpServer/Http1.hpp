//===- Http1.hpp - HTTP/1.1 server connections on the IoReactor -----------===//
//
// An `Http.Server` connection that speaks HTTP/1.x has to be parsed, policed and answered on the reactor thread, while
// the answer itself comes from Elm on the eco thread. This component is the reactor side of that exchange.
//
// `Http1Protocol` is the `ConnProtocol` of one such connection. It feeds the bytes it reads to an llhttp request parser
// in strict mode (no lenient flag is set), turns each complete request into a `HttpEvent` of plain data posted with
// `postHttpEvent`, and writes the response it is later handed by `respond`. It never touches the Elm heap. The
// component also holds the per-server state shared by every connection of a server (`ServerConfig`,
// `ServerReactorState`), the factory a server's listener calls for each accepted connection, and the reactor commands
// that answer a request or close a server whichever protocol, HTTP/1.1 or HTTP/2, the connection runs.
//
// Everything follows from one rule: a connection has at most one request in flight. A request is *in flight* from the
// moment it is fully parsed and posted until its response is queued. Each request gets a *key* from `nextResponseKey`,
// which the eco side quotes back to answer it; `ConnShared::key` holds the key in flight, or 0. llhttp is paused when a
// message completes and resumed only once the response is queued, after which the bytes already buffered are parsed,
// so pipelined requests are answered in the order they arrived. A connection moves through these states:
//
//   Idle -> Reading -> AwaitingElm -> (response queued) -> Idle (keep-alive)
//                   -> UpgradePending -> (upgrade taken: Done) or (response) -> Closing
//   any state -> Closing (error, limit, timeout, server close, peer EOF)
//
// While a request is in flight, reading continues until `kPipelineBuffer` unparsed bytes are buffered, so that a FIN
// or reset from the peer is still noticed. Reading also pauses once the queued output reaches `Conn::kLowWatermark`
// after a response is queued, until `onWritable` reports it has fallen below.
//
// Rules on requests, each answered with the status shown and then a close:
//   * Header bytes: the bytes of the URL, the header names and the header values together may not exceed
//     `maxHeaderSize` (431). The method, the version, separators and line ends are not counted.
//   * Body: a Content-Length above `maxBodySize` is refused when the headers end, before any 100 Continue is sent;
//     a body whose bytes so far exceed it is refused as it arrives (413).
//   * Host: an HTTP/1.1 request must carry exactly one Host header and an HTTP/1.0 request at most one, and its value
//     must be a host (an RFC 3986 IP-literal in brackets, that is an IPv6 address, optionally with an RFC 6874 `%25`
//     zone id, or an IPvFuture, or a name of reg-name characters and %-escapes, which covers IPv4 addresses)
//     optionally followed by `:` and at most five digits (400).
//   * Version: a version llhttp accepts other than 1.0 and 1.1 (505).
//   * Expect (HTTP/1.1 only; an HTTP/1.0 request's Expect is ignored, RFC 9110 §10.1.1): one Expect header whose
//     value is `100-continue`, ignoring case and surrounding blanks, is accepted, and
//     on a request with a body (chunked, or a nonzero Content-Length) `HTTP/1.1 100 Continue` is written when the
//     headers end. Because of the one-in-flight rule that is always after every earlier response was queued. Any
//     other Expect value, or more than one Expect header (417).
//   * Timeouts: `kTimerHeaders` runs from the first byte of a request to the end of its headers (`headersMs`), and
//     `kTimerRequest` from the first byte to the end of the body (`requestMs`); either expiring gives 408. Neither
//     runs while Elm answers.
//   * Anything else llhttp rejects (400).
// An error response carries `Connection: close`, and the connection then closes with `Conn::closeGraceful`.
//
// Between requests `kTimerIdle` bounds how long the connection stays idle: `headersMs` for a fresh connection's first
// byte, `keepAliveMs` after a response; when it expires the connection closes without a response. A timeout of 0 or
// less sets no timer. Once the server is closing, `kTimerIdle` instead holds the server's close deadline, at which a
// connection with a request still being read or answered is aborted.
//
// The URL delivered with a request is the target as received, with its scheme lower-cased, when it starts with
// `http://` or `https://` (compared ignoring case, RFC 3986 §3.1). Otherwise it is the scheme (`https` on a TLS server), then the Host value or, when there is none,
// `ServerConfig::fallbackAuthority`, then the target, with `/` put in front of a target that does not start with one
// and `*` turned into `/`.
//
// Upgrades. llhttp flags a request as an upgrade when it has `Upgrade` together with `Connection: upgrade`, or is a
// CONNECT. An upgrade request without a body is delivered with its first Upgrade token, lower-cased, and the connection
// enters UpgradePending: the bytes read after the request, the *head*, are kept for whoever takes the connection over
// with `takeUpgradeHead` and `Conn::setProtocol`. A CONNECT, or an upgrade request with a body, is delivered with no
// token. Any answer to an upgrade request other than a take-over is written with `Connection: close` and the
// connection closes, so the parser is never resumed past one.
//
// A response keeps the connection open only if llhttp says the request allows it, the server is not closing, the
// response's own headers do not ask to close (`headersAskClose`), the request was not an upgrade or CONNECT, the caller
// did not force a close, and the peer has not ended its input with nothing left to parse. After the peer's FIN, the
// request in flight and the complete requests already buffered are answered, then the connection closes.
//
// `ConnShared` is the per-connection state that outlives the protocol: the close hook installed by
// `makeHttp1Protocol` reads it, never the protocol, so a connection whose protocol was replaced by `setProtocol` leaves
// the hook nothing dangling. The hook posts `ConnGone` with the key in flight, if any.
//
// Not built on Windows, where `HttpServerServiceWin32.cpp` provides stand-ins for the free functions.
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

/// The settings of one server, filled in before it starts listening and shared, as a `shared_ptr` to const, with
/// every connection.
///
/// Nothing enforces that its creator does not change it afterwards through a non-const alias; the protocols read it
/// on the reactor thread without a lock. Sizes are in bytes and times in milliseconds.
struct ServerConfig {
    int64_t serverId = 0;
    uint64_t gen = 0;               ///< The heap generation the server was created in, copied into its events.
    bool tls = false;               ///< Requests get the `https` scheme and bit 2 of `RequestData::flags`.
    bool http1 = true;              ///< Whether HTTP/1.x is served; false makes an HTTP/2-only server.
    bool http2 = false;             ///< Whether a connection whose TLS handshake chose `h2` is served with HTTP/2.
    std::string fallbackAuthority;  ///< The `host:port` put in the URL of a request with no Host header.
    int64_t maxBodySize = 16 * 1024 * 1024;
    int64_t maxHeaderSize = 64 * 1024;
    int64_t keepAliveMs = 5000;
    int64_t headersMs = 60000;
    int64_t requestMs = 300000;
    int64_t maxConcurrentStreams = -1;   ///< Used by HTTP/2 only. 0 or less sets no limit on streams.
};

/// The state of one server that its connections share on the reactor thread: its settings, whether it is closing,
/// and its live connections.
///
/// Nothing locks it, so it may be read or changed only on the reactor thread; other threads may only hold and pass on
/// the `shared_ptr`.
struct ServerReactorState {
    std::shared_ptr<const ServerConfig> cfg;
    bool closing = false;
    int64_t closeDeadline = 0;   ///< When closing connections are aborted, in `IoReactor::nowMs` time.
    /// The server's live connections, keyed by address. An entry is added by `makeHttp1Protocol` or
    /// `makeHttp2Protocol` and removed by the close hook it installs.
    std::unordered_map<Conn*, std::weak_ptr<Conn>> conns;
};

/// What an HTTP/1.1 connection's protocol and its close hook both need, shared between them so that it outlives a
/// protocol that is replaced. Used on the reactor thread only.
struct ConnShared {
    int64_t key = 0;   ///< The key of the request in flight, or 0 when none is.
    SockEndpoint remote;
};

/// Returns a new `Http1Protocol` for the accepted connection `c` of the server `srv`.
///
/// It also registers `c` in `srv->conns`, turns on `TCP_NODELAY`, and adds a close hook to `c` that removes it from
/// `srv->conns` and, if a request is in flight, posts `ConnGone` with its key. The protocol keeps `srv`; the hook does
/// not.
std::unique_ptr<ConnProtocol> makeHttp1Protocol(Conn& c,
                                                const std::shared_ptr<ServerReactorState>& srv);

/// Returns the protocol for the established connection `c` of the server `srv`, chosen by what its TLS handshake
/// negotiated.
///
/// A connection whose handshake chose `h2`, on a server with `http2` set, gets `makeHttp2Protocol`. Any other
/// connection, including one with no TLS or no ALPN, gets `makeHttp1Protocol` if the server has `http1` set, and
/// otherwise a null pointer.
std::unique_ptr<ConnProtocol> makeServerProtocol(Conn& c,
                                                 const std::shared_ptr<ServerReactorState>& srv);

/// Marks the server `srv` as closing, with `deadline` (in `IoReactor::nowMs` time) as the moment its unfinished
/// connections are aborted, and tells every live connection still running `Http1Protocol` or `Http2Protocol`.
///
/// An idle HTTP/1.1 connection closes at once; one with a request being read or answered may finish it with
/// `Connection: close`. A connection handed to another protocol is left alone. Must be called on the reactor thread.
void http1ServerClosing(const std::shared_ptr<ServerReactorState>& srv, int64_t deadline);

/// Answers the request `key` on `conn` with `r`, and returns whether it was answered.
///
/// On a connection running `Http1Protocol` this is `Http1Protocol::respond`, and on one running `Http2Protocol` it is
/// `Http2Protocol::respond`; for a null `conn` or any other protocol it returns false. When it returns true, `done`
/// has been taken and is called with the result of sending the response; when it returns false, `done` is left as it
/// was for the caller to deal with. `forceClose` makes an HTTP/1.1 response close the connection. Must be called on the
/// reactor thread.
bool http1Respond(const std::shared_ptr<Conn>& conn, int64_t key, ResponseData r, bool forceClose,
                  std::function<void(int err)>& done);

/// Returns a request key not returned before in this process. May be called from any thread.
int64_t nextResponseKey();

/// Returns whether `h` is an acceptable RFC 9110 §7.2 Host value, `uri-host [ ":" port ]`: an RFC 3986 IP-literal
/// in brackets (an IPvFuture, or an IPv6 address with an optional RFC 6874 zone id) or a non-empty reg-name (which
/// covers IPv4 addresses), then optionally `:` and at most five digits. HTTP/1 checks the Host header with it, and
/// HTTP/2 the `:authority` (or its Host); a request that fails is answered 400.
bool validHostValue(const std::string& h);

#ifndef _WIN32

/// The HTTP/1.x protocol of one server connection, as the file comment describes: one request in flight, parsed
/// strictly, answered in order.
///
/// It refers to the server's `ServerConfig` through the `ServerReactorState` it keeps alive. It is neither copyable
/// nor movable, since llhttp holds a pointer to it. Every member is called on the reactor thread.
class Http1Protocol final : public ConnProtocol {
public:
    /// The number of unparsed bytes at which reading pauses while a request is in flight.
    static constexpr size_t kPipelineBuffer = 64 * 1024;
    /// The time in milliseconds a closing connection is given, counted from the close and covering a queued response.
    static constexpr int64_t kCloseDrainMs = 10000;

    /// Creates the protocol of a connection of the server `srv`, sharing `cs` with the connection's close hook.
    /// `srv->cfg` must not be null.
    Http1Protocol(std::shared_ptr<ServerReactorState> srv, std::shared_ptr<ConnShared> cs);
    ~Http1Protocol() override = default;

    /// Starts the idle timer for the first byte, or closes the connection at once if the server is closing.
    void onOpen(Conn& c) override;
    /// Buffers `bytes`, and parses them unless a request is in flight. Ignored once the connection is closing or done.
    void onData(Conn& c, std::string_view bytes) override;
    /// Closes an idle connection, answers 400 to a request cut short, and otherwise lets the request in flight and the
    /// requests buffered behind it be answered before closing.
    void onEof(Conn& c) override;
    /// Aborts the connection; its close hook reports the request in flight as gone.
    void onError(Conn& c, int err, const std::string& code) override;
    void onWritable(Conn& c) override;
    /// Answers 408 when the headers or request timer expires during a read. When `kTimerIdle` expires it closes an
    /// idle connection, or aborts a busy one if the server is closing.
    void onTimer(Conn& c, int timerId) override;
    void onCloseAll(Conn& c) override;
    /// Returns true while idle or reading a request, and while a request is in flight with fewer than
    /// `kPipelineBuffer` bytes buffered; false after the peer's end of input or while the queued output is high.
    bool wantsRead() const override;

    /// Writes `r` as the response to the request `key`, if `key` is the request in flight on this connection, and
    /// returns whether it did.
    ///
    /// On success `done` is moved into `Conn::write`, and the connection either closes, as the file comment's
    /// keep-alive rule decides (`forceClose` forces a close), or goes on to the requests buffered behind this one. On
    /// failure nothing changes and `done` is left as it was.
    bool respond(Conn& c, int64_t key, ResponseData r, bool forceClose,
                 std::function<void(int)>& done);
    /// Applies the server's close to this connection: closes it now if idle, and, while a request is being read or
    /// answered, arms `kTimerIdle` with the server's close deadline, at which it is aborted unless it has closed by
    /// then.
    void serverClosing(Conn& c);

    // Upgrade take-over

    /// Returns whether `key` is an upgrade request in flight on this connection, waiting for an answer.
    bool upgradePending(int64_t key) const;
    /// Ends HTTP/1.1 on `c` for the upgrade request `key`, and returns the bytes read after that request.
    ///
    /// The key in flight and the timers are cleared, and this protocol does nothing more with the connection; the
    /// caller must then install the next protocol with `Conn::setProtocol`, passing it the returned bytes. If
    /// `upgradePending(key)` is false, it changes nothing and returns an empty string.
    std::string takeUpgradeHead(Conn& c, int64_t key);

    Http1Protocol(const Http1Protocol&) = delete;
    Http1Protocol& operator=(const Http1Protocol&) = delete;

private:
    /// Where the connection is, as the file comment's state diagram shows. `Done` means this protocol has finished
    /// with the connection: it was torn down, or taken over after an upgrade.
    enum class State : uint8_t { Idle, Reading, AwaitingElm, UpgradePending, Closing, Done };

    // llhttp callbacks. Each finds its protocol through the parser's `data` pointer and returns 0 to go on, or nonzero
    // to stop or pause.

    /// Clears the request being parsed as a new message begins.
    static int cbMessageBegin(llhttp_t* p);
    /// Appends a piece of the request target, failing with 431 once the header byte limit is passed.
    static int cbUrl(llhttp_t* p, const char* at, size_t n);
    /// Appends a piece of a header name, starting a new header after a value, failing with 431 once the header byte
    /// limit is passed.
    static int cbHeaderField(llhttp_t* p, const char* at, size_t n);
    /// Appends a piece of the current header's value, failing with 431 once the header byte limit is passed.
    static int cbHeaderValue(llhttp_t* p, const char* at, size_t n);
    /// Calls `headersComplete`.
    static int cbHeadersComplete(llhttp_t* p);
    /// Appends a piece of the body, failing with 413 once the body would pass `maxBodySize`.
    static int cbBody(llhttp_t* p, const char* at, size_t n);
    /// Records what the response needs to know about the completed request and pauses the parser.
    static int cbMessageComplete(llhttp_t* p);
    /// Returns the llhttp callback table shared by every connection, built on first use.
    static const llhttp_settings_t& settings();

    /// Adds `n` to the header bytes of the request being parsed, and returns false, with 431 recorded, once they
    /// exceed `maxHeaderSize`.
    bool countHeaderBytes(size_t n);
    /// Applies the version, Host, Content-Length and Expect rules once the headers are parsed, writes 100 Continue
    /// where they call for it, and stops the headers timer. Returns 0 to go on, or -1 with the status recorded.
    int headersComplete();
    /// Clears the request being parsed.
    void resetRequest();
    /// Moves from Idle to Reading as the first byte of a request arrives, and starts the headers and request timers.
    void startRequest(Conn& c);
    /// Parses the buffered input while the connection is reading, posting a completed request or answering an error.
    void parse(Conn& c);
    /// Stops the request timers, gives the completed request a key and posts it as a `Request` event.
    void messageComplete(Conn& c);
    /// Writes a response with `status` and no body, with `Connection: close`, and closes the connection.
    void failRequest(Conn& c, int64_t status);
    /// Clears the key in flight and every timer, and closes the connection gracefully.
    void closeNow(Conn& c);
    /// Goes on after a response that kept the connection open: parses buffered requests, then, if no request is in
    /// flight, closes the connection if the peer has ended its input or the server is closing, or else starts the
    /// keep-alive timer.
    void afterResponse(Conn& c);
    /// Handles the peer's end of input while a request is being read: a close if nothing but blank lines was read
    /// since the last message, 400 otherwise.
    void eofWhileReading(Conn& c);
    /// Returns the URL of the parsed request, built from its target and `host` as the file comment describes.
    std::string absoluteUrl(const std::string& host) const;

    std::shared_ptr<ServerReactorState> srv_;
    std::shared_ptr<ConnShared> cs_;
    /// The server's settings, `*srv_->cfg`, kept alive by `srv_`.
    const ServerConfig& cfg_;
    llhttp_t parser_;
    /// The connection being parsed, set only while `llhttp_execute` runs so that callbacks can write and set timers;
    /// null otherwise.
    Conn* cur_ = nullptr;

    State state_ = State::Idle;
    std::string in_;               ///< Bytes read and not yet parsed.
    bool peerEof_ = false;
    bool outHigh_ = false;         ///< The queued output reached `Conn::kLowWatermark` and has not yet fallen below.

    // The request being parsed
    std::string url_;
    std::vector<std::pair<std::string, std::string>> headers_;
    bool inValue_ = false;         ///< The last piece appended was part of a header value.
    std::string body_;
    size_t headerBytes_ = 0;
    int64_t errorStatus_ = 0;      ///< The status a callback chose when it stopped the parser, or 0.
    bool messageDone_ = false;

    // The request in flight
    bool isHead_ = false;
    bool shouldKeepAlive_ = false;
    /// The request was an upgrade or CONNECT, so a response to it closes the connection.
    bool mustClose_ = false;
};

#endif // !_WIN32

} // namespace Eco::System::HttpSrv

#endif // ECO_SYSTEM_HTTP_SERVER_HTTP1_HPP
