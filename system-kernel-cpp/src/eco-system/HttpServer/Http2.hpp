//===- Http2.hpp - HTTP/2 server connections on the IoReactor -------------===//
//
// plans/eco-system-websockets.md §3.8 (W11, phase WS8). Http2Protocol is the
// ConnProtocol of one https connection whose ALPN chose "h2" (Http1.cpp
// makeServerProtocol): one nghttp2 1.70.0 *server* session, driven without
// sockets by nghttp2_session_mem_recv2 (onData) and nghttp2_session_mem_send2
// (while Conn::outbound() is below Conn::kLowWatermark; onWritable resumes).
//
// REACTOR THREAD ONLY (G1): no heap access; complete requests go to the main
// thread as POD HttpEvents (HttpTables.hpp), responses come back as reactor
// commands (respond, through http1Respond's dispatch).
//
//   * Session options: no automatic WINDOW_UPDATE (flow control is manual,
//     below), max_continuations 8, the stream reset rate limit (burst 1000,
//     33/s: nghttp2's defaults made explicit; exceeding it is answered by
//     nghttp2 with GOAWAY(INTERNAL_ERROR), as Node), max_outbound_ack 1000,
//     max_settings 32. HTTP messaging rules stay on (never
//     set_no_http_messaging): malformed requests are reset by nghttp2.
//   * Initial SETTINGS: MAX_CONCURRENT_STREAMS only when maxConcurrentStreams
//     is set (W19), MAX_HEADER_LIST_SIZE = maxHeaderSize, ENABLE_PUSH 0,
//     ENABLE_CONNECT_PROTOCOL 1, INITIAL_WINDOW_SIZE 64 KiB,
//     NO_RFC7540_PRIORITIES 1.
//   * Per stream: Headers → Body → Delivered → Responding (or Reset / a
//     tunnel, WS9). The header list (name + value + 32 per field, pseudo
//     fields included) is limited to maxHeaderSize: past it nothing more is
//     stored and the end of the block is answered 431. A request is delivered
//     on END_STREAM; an (extended) CONNECT on its HEADERS (it never ends).
//   * Mapping to Request: method/url from :method, :scheme, :authority (a
//     different Host header → 400; without both, the server's own authority)
//     and :path; pseudo fields are not in the header list; cookie crumbs are
//     joined with "; " (RFC 9113 §8.2.3) into one cookie field at the place
//     of the first; names arrive lower-case; flags = version 2 | TLS;
//     extended CONNECT with :protocol websocket (case-insensitive) carries the
//     upgrade token "websocket", any other :protocol is answered 501. A plain
//     CONNECT is delivered without a token (as HTTP/1.1).
//   * Own answers (400, 408, 413, 431, 501) and answers to a CONNECT the
//     program did not hand off: the response, then RST_STREAM(NO_ERROR)
//     once its END_STREAM is out if the client's side is still open (RFC
//     9113 §8.1: a complete response may precede the end of the request).
//   * Flow control (manual): a stream's window is consumed as its body
//     accumulates (up to maxBodySize; beyond it 413, as for a content-length
//     over maxBodySize, which is answered before any body); the connection window
//     is consumed on receipt while the bodies buffered on this connection
//     (received, not yet delivered) stay within maxBodySize × 2, else when
//     they are delivered or dropped. A CONNECT stream's own window is not
//     consumed before a tunnel takes the bytes (WS9; at most 64 KiB wait).
//   * maxConcurrentStreams = Just n: additionally, the input is fed to
//     nghttp2 one frame at a time and stops at a frame boundary while n
//     requests are outstanding: delivered but not answered, including
//     streams the client reset (until the program answers them or the
//     connection closes). Reading continues until kInBuffer bytes wait, so
//     a peer's FIN or reset is still noticed. With the default (unlimited)
//     the reset rate limit is the only bound (documented in Http.Server).
//   * Responses (toH2Nv): status 100–199 or outside 200..999 → 500; names
//     lower-cased; pseudo names, empty or invalid names/values, connection,
//     keep-alive, proxy-connection, transfer-encoding, upgrade, te (other
//     than "trailers") and content-length are dropped; date added unless
//     given; content-length = body size except 204/304; HEAD, 204, 304 and
//     empty bodies are HEADERS with END_STREAM, others HEADERS + DATA (a
//     data_provider2; a tunnel's provider defers while nothing is queued).
//     respond's `done` runs once the frame with END_STREAM was handed to the
//     transport (Conn::write), or with ECANCELED if the stream ends first.
//   * Timers: kTimerIdle — a fresh connection gets headersTimeout for its
//     first bytes; with no stream open and nothing outstanding the
//     connection closes (GOAWAY NO_ERROR) after keepAliveTimeout; after
//     closeServer it is the server's deadline (abort). kTimerRequest — the
//     earliest requestTimeout of a stream still receiving its request (408 +
//     RST_STREAM(NO_ERROR)). A timeout of 0 or less is none.
//   * closeServer: GOAWAY(last processed stream id, NO_ERROR); open streams
//     finish (answers still go out); the connection closes when no stream is
//     left, or is aborted at the deadline. Tunnels (WS9) count as open
//     streams: they keep the connection until they end or the deadline.
//   * The connection closes (closeGraceful) when nghttp2 wants neither to
//     read nor to write (a GOAWAY that ends the session, a fatal error), or
//     when the peer half-closed / the server is closing and no stream that
//     can still be answered is left (after a FIN, a request still arriving
//     cannot complete). A reset (read error) aborts: ConnGone for every key.
//
// Keys (HttpTables) map to stream ids: H2Shared holds the keys delivered on
// this connection and not answered yet; the Conn's close hook posts
// ConnGone for each of them.
//
// WS9 hooks (WebSockets over HTTP/2): H2StreamHandler and the tunnel*
// methods bind an extended CONNECT stream to another protocol (Http.Server's
// upgradeRequest: HttpUpgrade.cpp's ServerTunnel around an H2StreamPort, the
// WebSocket codec's port). Tunnel calls made while nghttp2 runs (from inside
// a callback, or while frames are written) only queue: the running IO step
// frames them; a handler is destroyed only on a later reactor turn after its
// stream closed (retireTunnel), so a stream that ends inside one of its own
// calls never leaves it dangling. onWritable reports a drained write queue.
//
// Templates used: none (POD only, G1).
//
//===----------------------------------------------------------------------===//

#ifndef ECO_SYSTEM_HTTP_SERVER_HTTP2_HPP
#define ECO_SYSTEM_HTTP_SERVER_HTTP2_HPP

#include "eco-system/HttpServer/Http1.hpp"
#include "eco-system/HttpServer/HttpServerService.hpp"
#include "eco-system/Socket/Conn.hpp"

#include <cstdint>
#include <functional>
#include <memory>
#include <string>
#include <string_view>
#include <unordered_map>
#include <unordered_set>
#include <utility>
#include <vector>

struct nghttp2_session;   // nghttp2.h (only Http2.cpp includes it)

namespace Eco::System::HttpSrv {

// Per h2 connection; reactor thread only.
struct H2Shared {
    std::unordered_set<int64_t> keys;   // delivered, not answered (incl. reset streams)
    SockEndpoint remote;
};

// The factory for ALPN "h2" (makeServerProtocol): registers `c` with the
// server, installs the close hook (ConnGone for every key) and returns the
// protocol.
std::unique_ptr<ConnProtocol> makeHttp2Protocol(Conn& c,
                                                const std::shared_ptr<ServerReactorState>& srv);

#ifndef _WIN32

// WS9: the far end of a tunnel (an extended CONNECT stream bound to another
// protocol). Reactor thread; called from inside Http2Protocol (it may call
// the tunnel* methods back).
class H2StreamHandler {
public:
    virtual ~H2StreamHandler() = default;
    // Tunnel bytes (DATA payload). The stream window is replenished only by
    // Http2Protocol::tunnelConsume (backpressure).
    virtual void onData(std::string_view bytes) = 0;
    virtual void onEnd() = 0;                 // the client's END_STREAM
    virtual void onReset(uint32_t code) = 0;  // RST_STREAM, or the connection is gone
    // WS9: bytes queued with tunnelWrite went below Conn::kLowWatermark
    // after the queue had reached it (write backpressure).
    virtual void onWritable() {}
};

class Http2Protocol final : public ConnProtocol {
public:
    // Bytes buffered (not yet given to nghttp2) beyond which reading pauses.
    static constexpr size_t kInBuffer = 64 * 1024;
    static constexpr int64_t kCloseDrainMs = 10000;
    static constexpr int32_t kInitialWindow = 64 * 1024;

    Http2Protocol(std::shared_ptr<ServerReactorState> srv, std::shared_ptr<H2Shared> sh);
    ~Http2Protocol() override;

    void onOpen(Conn& c) override;
    void onData(Conn& c, std::string_view bytes) override;
    void onEof(Conn& c) override;
    void onError(Conn& c, int err, const std::string& code) override;
    void onWritable(Conn& c) override;
    void onTimer(Conn& c, int timerId) override;
    void onCloseAll(Conn& c) override;
    bool wantsRead() const override;

    // Reactor command of respond (through http1Respond): false (and `done`
    // untouched) when `key` is not a delivered, unanswered request on a live
    // stream of this connection (a reset stream's key is forgotten then).
    bool respond(Conn& c, int64_t key, ResponseData r, bool forceClose,
                 std::function<void(int)>& done);
    // closeServer: GOAWAY, then the open streams finish.
    void serverClosing(Conn& c);

    // --- WS9 hooks (tunnels) ------------------------------------------------------
    // True while `key` is an extended CONNECT (upgrade "websocket") waiting
    // for its answer.
    bool tunnelPending(int64_t key) const;
    // Answers `key` with `head` (2xx, no END_STREAM) and binds the stream to
    // `h`; returns the stream id (0: not pending) and moves the bytes received
    // so far into `buffered` (not yet consumed: call tunnelConsume as the
    // handler takes them).
    int32_t bindTunnel(Conn& c, int64_t key, ResponseData head, std::unique_ptr<H2StreamHandler> h,
                       std::string& buffered);
    void tunnelConsume(Conn& c, int32_t streamId, size_t n);
    // Queues tunnel bytes as DATA (false: the stream is gone).
    bool tunnelWrite(Conn& c, int32_t streamId, std::string bytes);
    // Orderly end (END_STREAM after the queued bytes) / abort (RST_STREAM).
    void tunnelEnd(Conn& c, int32_t streamId);
    void tunnelReset(Conn& c, int32_t streamId, uint32_t code);
    // Bytes queued for a tunnel and not yet framed.
    size_t tunnelQueued(int32_t streamId) const;
    // WS9: a pending extended CONNECT nobody answers (WebSocket abandon):
    // RST_STREAM(CANCEL); the key is forgotten.
    void tunnelCancel(Conn& c, int64_t key);

    Http2Protocol(const Http2Protocol&) = delete;
    Http2Protocol& operator=(const Http2Protocol&) = delete;

    // nghttp2 callbacks (Http2.cpp), public for the C callback table only.
    struct Stream;
    struct Cb;

private:
    friend struct Cb;

    Stream* find(int32_t id);
    void process(Conn& c);
    void flush(Conn& c);
    void afterIo(Conn& c);
    void maybeClose(Conn& c);
    void updateTimers(Conn& c);
    void fatal(Conn& c);
    bool capped() const;

    void endHeaders(Stream& s);
    void requestComplete(Stream& s);
    void deliver(Stream& s);
    void ownResponse(Stream& s, int64_t status);
    bool submitResponse(Stream& s, const ResponseData& r, bool endAfterHeaders);
    void releaseBody(Stream& s);
    void consumeConnection();
    void retireKey(int64_t key);
    void closeStream(int32_t id, uint32_t code);
    void notifyWritable();
    static void retireTunnel(std::unique_ptr<H2StreamHandler> t, uint32_t code);

    std::shared_ptr<ServerReactorState> srv_;
    std::shared_ptr<H2Shared> sh_;
    const ServerConfig& cfg_;
    nghttp2_session* session_ = nullptr;
    Conn* conn_ = nullptr;

    std::unordered_map<int32_t, std::unique_ptr<Stream>> streams_;
    std::unordered_map<int64_t, int32_t> keyStream_;   // outstanding (incl. reset streams)

    std::string in_;           // read, not yet given to nghttp2 (from inOff_)
    size_t inOff_ = 0;
    size_t prefaceLeft_ = 24;  // the client connection preface
    size_t frameLeft_ = 0;     // the rest of the frame being fed

    size_t buffered_ = 0;      // body bytes received on this connection, not yet delivered
    size_t connPending_ = 0;   // received, not yet consumed at connection level

    std::vector<std::function<void(int)>> sentDones_;   // END_STREAM framed: run after the write
    bool flushing_ = false;
    bool flushAgain_ = false;
    bool processing_ = false;
    bool sawData_ = false;     // any byte received (first-byte timeout over)
    bool outHigh_ = false;
    bool writableWaiters_ = false;   // a tunnel waits for its queue to drain (WS9)
    bool peerEof_ = false;
    bool closing_ = false;     // closeServer: GOAWAY submitted
    bool done_ = false;        // closing / closed: no more input
};

#endif // !_WIN32

} // namespace Eco::System::HttpSrv

#endif // ECO_SYSTEM_HTTP_SERVER_HTTP2_HPP
