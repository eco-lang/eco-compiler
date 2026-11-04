//===- Http2.hpp - HTTP/2 server connections on the IoReactor -------------===//
//
// An https connection whose TLS handshake chose the ALPN protocol "h2" speaks HTTP/2, which carries many requests at
// once over one connection, and this component is the server side of such a connection.
//
// `Http2Protocol` is the `ConnProtocol` that `makeHttp2Protocol` installs on the `Conn`. It runs one nghttp2 *server
// session* without giving it the socket: bytes the `Conn` reads are fed to it from memory, and the frames it produces
// are taken from memory and handed to `Conn::write`. A *stream* is one request and its response, named by an HTTP/2
// stream id. A complete request is posted to the eco thread as a `HttpEvent` with a fresh response key (the key
// `nextResponseKey` hands out, as for HTTP/1.1), and the answer comes back as a reactor command, `respond`, which
// `http1Respond` dispatches here. Everything in this component runs on the reactor thread and touches no GC heap.
//
// An *outstanding key* is one that was delivered and not yet answered. A stream the client resets keeps its key
// outstanding until the program answers it (the answer is then refused) or cancels it with `tunnelCancel`, or the
// connection closes, so a client that resets streams rapidly still counts against the stream cap below. `H2Shared`
// keeps the outstanding keys, and the `Conn`'s close hook posts a `ConnGone` event for each of them.
//
// The session's protocol behaviour:
//
//   * Options: no automatic WINDOW_UPDATE (flow control is manual, below), at most 8 CONTINUATION frames, a stream
//     reset rate limit of a burst of 1000 and 33 a second (beyond it nghttp2 ends the connection), at most 1000
//     queued outbound acknowledgements, and at most 32 settings per SETTINGS frame. nghttp2's HTTP messaging checks
//     stay on, so nghttp2 resets a malformed request itself.
//   * The server's SETTINGS: MAX_CONCURRENT_STREAMS when `ServerConfig::maxConcurrentStreams` is 0 or more,
//     MAX_HEADER_LIST_SIZE `maxHeaderSize`, ENABLE_PUSH 0, ENABLE_CONNECT_PROTOCOL 1, INITIAL_WINDOW_SIZE
//     `kInitialWindow`, NO_RFC7540_PRIORITIES 1.
//   * A request's header list is counted as name + value + 32 bytes per field, pseudo fields included, against
//     `maxHeaderSize`. Past it nothing more is stored and the end of the block is answered 431. Trailers are ignored.
//   * A request is delivered when its END_STREAM arrives. A CONNECT, with or without `:protocol`, is delivered as soon
//     as its headers end, since its request side does not end.
//   * The request's URL is built from `:scheme` (`https` or `http` by `ServerConfig::tls` when it is neither),
//     `:authority` and `:path`. A Host header that differs from `:authority`, ignoring case, is answered 400; a Host
//     header alone supplies the authority, and with neither `ServerConfig::fallbackAuthority` is used. An authority
//     that is not a valid Host value (`validHostValue`, as HTTP/1 checks Host) is answered 400. Pseudo fields
//     are not in the delivered headers. Cookie fields are joined with "; " into one field, at the place of the first.
//     Names arrive lower-case, as HTTP/2 requires. `RequestData::flags` is 2 (HTTP/2), plus 4 under TLS.
//   * A CONNECT whose `:protocol` is `websocket`, ignoring case, is delivered with the upgrade token "websocket"; any
//     other `:protocol` is answered 501. A CONNECT without `:protocol` is delivered without a token.
//   * The server's own answers (400, 408, 413, 431, 501), and the answer to a CONNECT the program did not turn into a
//     tunnel, are followed by RST_STREAM(NO_ERROR) once their END_STREAM is sent, if the client's side of the stream
//     is still open.
//   * Flow control: a stream's window is given back as its body arrives, up to `maxBodySize`; a body that would pass
//     it is answered 413, as is a Content-Length above it, which is answered before any body. The connection window is
//     given back on receipt while the bodies buffered on this connection (received and not delivered) are within
//     `max(maxBodySize * 2, kInitialWindow)`, and otherwise once enough of them are delivered or dropped. The bytes a
//     CONNECT receives before it becomes a tunnel are kept, and its stream window is not given back for them, so at
//     most `kInitialWindow` of them wait.
//   * Input is fed to nghttp2 one frame at a time. With `maxConcurrentStreams` above 0, feeding stops at a frame
//     boundary while that many keys are outstanding. Reading continues until `kInBuffer` bytes wait, so a FIN or a
//     reset from the peer is still noticed.
//   * Responses: a status below 200 or above 999 is sent as 500. Header names are lower-cased. Pseudo fields, empty or
//     invalid names and values, `connection`, `keep-alive`, `proxy-connection`, `transfer-encoding`, `upgrade`,
//     `content-length`, and `te` other than "trailers" are dropped. A `date` is added unless one is kept.
//     `content-length` is the body's size, except for 204, 304 and a tunnel's head. A HEAD request, 204, 304 and an
//     empty body get HEADERS with END_STREAM and no DATA.
//   * Timers: `Conn::kTimerIdle` gives a fresh connection `headersMs` for its first bytes, and later closes the
//     connection with GOAWAY(NO_ERROR) after `keepAliveMs` with no stream and no outstanding key. After
//     `serverClosing` it is the server's `closeDeadline`, at which the connection is aborted. `Conn::kTimerRequest`
//     runs to the earliest `requestMs` deadline of a stream still receiving its request, which is then answered 408. A
//     timeout of 0 or less sets no deadline.
//   * The connection closes gracefully when nghttp2 wants neither to read nor to write (the session ended by a GOAWAY
//     or an error), or when the peer has half-closed or the server is closing and no stream is left that still owes an
//     answer, is being answered or is a tunnel, and nothing is waiting to be written. A request still arriving cannot
//     complete after the peer's FIN, so it does not keep the connection. A socket error aborts the connection.
//
// A *tunnel* is a WebSocket over HTTP/2: an extended CONNECT stream that `bindTunnel` answers and binds to an
// `H2StreamHandler`, which then exchanges the stream's DATA as a byte stream. A tunnel counts as an open stream: it
// keeps a closing connection until it ends or the deadline passes. Calls into a tunnel's methods made while nghttp2 is
// running (from inside one of its callbacks, or while frames are being written) only queue their work, and the step
// already running frames it, because nghttp2 must not be re-entered.
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

/// What one HTTP/2 connection's protocol and its close hook both need, shared between them so that the hook can still
/// read it after the protocol is gone. Used on the reactor thread only.
struct H2Shared {
    std::unordered_set<int64_t> keys;   ///< The outstanding keys, including those of streams the client reset.
    SockEndpoint remote;                ///< The peer's address, copied into every request.
};

/// Creates the protocol for a connection whose TLS handshake chose "h2", serving it as a connection of `srv`.
///
/// It also turns off Nagle's algorithm on `c`, adds `c` to `srv->conns`, and installs a close hook on `c` that removes
/// it from `srv->conns` again (if `srv` still exists) and posts a `ConnGone` event, in key order, for every key still
/// outstanding when the connection closes. The protocol keeps `srv`.
std::unique_ptr<ConnProtocol> makeHttp2Protocol(Conn& c,
                                                const std::shared_ptr<ServerReactorState>& srv);

#ifndef _WIN32

/// The receiving end of a tunnel: what a stream bound by `Http2Protocol::bindTunnel` reports to.
///
/// The `Http2Protocol` that owns the stream owns the handler and calls it on the reactor thread, often from inside an
/// nghttp2 callback.
/// When the stream closes, or the connection's streams are dropped, the handler is destroyed by a command submitted to
/// the reactor rather than at once, so a stream that ends inside one of the handler's own calls does not destroy it
/// while that call runs. Handlers still bound when the `Http2Protocol` is destroyed are destroyed with it.
class H2StreamHandler {
public:
    virtual ~H2StreamHandler() = default;
    /// Receives the next DATA payload of the stream. The stream's flow-control window is given back only as the
    /// handler reports bytes taken with `Http2Protocol::tunnelConsume`, so a handler that stops consuming stops the
    /// client from sending. `bytes` is valid only during the call.
    virtual void onData(std::string_view bytes) = 0;
    /// Reports the client's END_STREAM: no more data will arrive.
    virtual void onEnd() = 0;
    /// Reports that the stream is over: closed with HTTP/2 error code `code` (NO_ERROR for an orderly close), or the
    /// connection is ending, with CANCEL. It can be called again for the same stream when the connection ends after
    /// the first report, so an implementation must tolerate a repeat.
    virtual void onReset(uint32_t code) = 0;
    /// Reports that the bytes queued with `Http2Protocol::tunnelWrite` have fallen below `Conn::kLowWatermark` after
    /// having reached it. The default does nothing.
    virtual void onWritable() {}
};

/// The HTTP/2 server side of one connection, as the file comment describes.
///
/// nghttp2 holds a pointer to it as the session's user data, so it cannot be copied. Every member function must be
/// called on the reactor thread, with `c` the `Conn` the protocol is installed on.
class Http2Protocol final : public ConnProtocol {
public:
    /// The number of received bytes, not yet given to nghttp2, at which reading pauses.
    static constexpr size_t kInBuffer = 64 * 1024;
    /// The drain time in milliseconds passed to `Conn::closeGraceful` when the connection closes.
    static constexpr int64_t kCloseDrainMs = 10000;
    /// The initial flow-control window, in bytes, this server gives every stream, and the least connection budget.
    static constexpr int32_t kInitialWindow = 64 * 1024;

    /// Creates a protocol for a connection of the server `srv`, sharing `sh` with the connection's close hook. The
    /// session is created by `onOpen`.
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

    /// Answers the request delivered under `key` with `r`, and returns whether the answer was accepted.
    ///
    /// It returns false, leaving `done` untouched, when `key` is not outstanding on this connection, when the
    /// connection has ended (closing for `serverClosing` does not count), when the client has reset the stream, and
    /// when nghttp2 refuses the response (the stream is then reset with INTERNAL_ERROR). In every case but the first
    /// two, `key` stops being outstanding. On success `done` is taken: it is called with the result of the
    /// `Conn::write` that carries the response's END_STREAM, or with ECANCELED if the stream or the connection ends
    /// first. `forceClose` is ignored. Answering a CONNECT here, rather than with `bindTunnel`, resets its stream with
    /// NO_ERROR once the answer is sent, if the client's side of it is still open.
    bool respond(Conn& c, int64_t key, ResponseData r, bool forceClose,
                 std::function<void(int)>& done);
    /// Starts closing the connection because its server is closing: sends GOAWAY(NO_ERROR) naming the last stream
    /// processed, lets the open streams finish, and arms the server's close deadline. Does nothing if the connection is
    /// already closing or closed.
    void serverClosing(Conn& c);

    /// Returns whether `key` is an outstanding extended CONNECT with `:protocol` "websocket", which `bindTunnel` can
    /// turn into a tunnel.
    bool tunnelPending(int64_t key) const;
    /// Answers the pending extended CONNECT `key` with `head`, binds its stream to `h`, and returns the stream id, or 0
    /// when `key` is not pending (see `tunnelPending`) or the connection has ended.
    ///
    /// `head` is sent as the response headers without END_STREAM or `content-length`, and its body is ignored; a status
    /// below 200 or above 999 is sent as 500, as for any response. The bytes the stream received before this call are
    /// moved into `buffered`, and are not yet given back to the stream's window: the caller reports them with
    /// `tunnelConsume` as they are taken. If nghttp2 refuses the headers, the stream is reset with INTERNAL_ERROR and
    /// its id is still returned.
    int32_t bindTunnel(Conn& c, int64_t key, ResponseData head, std::unique_ptr<H2StreamHandler> h,
                       std::string& buffered);
    /// Gives `n` bytes back to the flow-control window of the tunnel stream `streamId`, letting the client send more.
    void tunnelConsume(Conn& c, int32_t streamId, size_t n);
    /// Queues `bytes` to be sent as DATA on the tunnel stream `streamId`, and returns false when that stream is not a
    /// tunnel of this live connection or has been ended with `tunnelEnd`. Once the queue reaches `Conn::kLowWatermark`
    /// the handler's `onWritable` reports when it falls below it again.
    bool tunnelWrite(Conn& c, int32_t streamId, std::string bytes);
    /// Ends the tunnel stream `streamId` in order: END_STREAM is sent after the bytes already queued. Does
    /// nothing for a stream that is not a live tunnel or is already ended.
    void tunnelEnd(Conn& c, int32_t streamId);
    /// Resets the stream `streamId` with HTTP/2 error code `code`. Does nothing for a stream that is not open.
    void tunnelReset(Conn& c, int32_t streamId, uint32_t code);
    /// Returns how many bytes queued with `tunnelWrite` on `streamId` have not yet been framed, or 0 for an unknown
    /// stream.
    size_t tunnelQueued(int32_t streamId) const;
    /// Stops `key` being outstanding without answering it, and resets its stream with CANCEL if it is still waiting
    /// for an answer. Does nothing once the connection has ended; the key then stays outstanding.
    void tunnelCancel(Conn& c, int64_t key);

    Http2Protocol(const Http2Protocol&) = delete;
    Http2Protocol& operator=(const Http2Protocol&) = delete;

    /// The state of one stream, defined in the source file.
    struct Stream;
    /// The nghttp2 callbacks, defined in the source file.
    struct Cb;

private:
    friend struct Cb;

    /// Returns the stream with id `id`, or null if it is not open. The pointer is valid until the stream closes.
    Stream* find(int32_t id);
    /// Feeds the received input to nghttp2, one frame at a time, until it runs out, the cap is reached at a frame
    /// boundary or the connection ends. A session error ends the connection through `fatal`.
    void process(Conn& c);
    /// Hands the frames nghttp2 has ready to the `Conn`, while its outbound queue is below `Conn::kLowWatermark`.
    void flush(Conn& c);
    /// Runs one IO step after any event: writes, reads, writes again, then reports drained tunnels, rearms the timers,
    /// closes the connection if it is finished, and updates read interest.
    void afterIo(Conn& c);
    /// Closes the connection gracefully when nothing is left for it to do, as the file comment describes.
    void maybeClose(Conn& c);
    /// Sets the idle and request deadlines from the connection's current state.
    void updateTimers(Conn& c);
    /// Ends the connection after a session error: writes a little of what nghttp2 has framed (usually a GOAWAY),
    /// cancels every pending `done`, and closes gracefully.
    void fatal(Conn& c);
    /// Returns whether `maxConcurrentStreams` is positive and the outstanding keys have reached it.
    bool capped() const;

    /// Checks a request whose header block has ended, answering it with 431, 413, 400 or 501 when it fails, and
    /// delivers a CONNECT at once.
    void endHeaders(Stream& s);
    /// Delivers a request whose END_STREAM has arrived, if it is still receiving its body.
    void requestComplete(Stream& s);
    /// Posts the request on `s` to the eco thread under a new key, which becomes outstanding.
    void deliver(Stream& s);
    /// Answers `s` with an empty response of `status` from the server itself, discarding its body. Once the answer
    /// is sent, the stream is reset with NO_ERROR if the client's side of it is still open. If nghttp2 refuses the
    /// response, the stream is reset with INTERNAL_ERROR.
    void ownResponse(Stream& s, int64_t status);
    /// Submits `r` as the response on `s` and returns whether nghttp2 accepted it. `endAfterHeaders` true, despite the
    /// name, means a tunnel's head: no END_STREAM and no `content-length`, and DATA follows from `tunnelWrite`.
    bool submitResponse(Stream& s, const ResponseData& r, bool endAfterHeaders);
    /// Drops the body, and any bytes kept for a tunnel, buffered on `s`.
    void releaseBody(Stream& s);
    /// Gives the received bytes back to the connection window, if the buffered bodies are within budget.
    void consumeConnection();
    /// Stops `key` being outstanding.
    void retireKey(int64_t key);
    /// Forgets the stream `id`, closed with error code `code`, cancelling its `done` and retiring its tunnel handler.
    /// Its key, if outstanding, stays outstanding.
    void closeStream(int32_t id, uint32_t code);
    /// Calls `onWritable` on every tunnel whose queue has fallen below `Conn::kLowWatermark` after reaching it.
    void notifyWritable();
    /// Reports `code` to `t` and destroys it in a command submitted to the reactor.
    static void retireTunnel(std::unique_ptr<H2StreamHandler> t, uint32_t code);

    std::shared_ptr<ServerReactorState> srv_;
    std::shared_ptr<H2Shared> sh_;
    const ServerConfig& cfg_;          ///< `*srv_->cfg`, which `srv_` keeps alive.
    nghttp2_session* session_ = nullptr;   ///< Owned; null before `onOpen` or when the session could not be made.
    Conn* conn_ = nullptr;             ///< The connection, set by `onOpen`; it owns this protocol.

    std::unordered_map<int32_t, std::unique_ptr<Stream>> streams_;
    std::unordered_map<int64_t, int32_t> keyStream_;   ///< The stream id of each outstanding key.

    std::string in_;           ///< Received bytes; those from `inOff_` have not been given to nghttp2.
    size_t inOff_ = 0;
    size_t prefaceLeft_ = 24;  ///< The bytes of the client connection preface still to feed.
    size_t frameLeft_ = 0;     ///< The bytes of the frame being fed still to feed.

    size_t buffered_ = 0;      ///< Body bytes received on this connection and not yet delivered or dropped.
    size_t connPending_ = 0;   ///< Bytes received and not yet given back to the connection window.

    /// The `done` callbacks of responses whose END_STREAM has been framed, for the next `Conn::write`.
    std::vector<std::function<void(int)>> sentDones_;
    bool flushing_ = false;
    bool flushAgain_ = false;  ///< Something asked for a flush while one was running.
    bool processing_ = false;
    bool sawData_ = false;     ///< Some byte has been received, so the first-bytes timeout is over.
    bool outHigh_ = false;     ///< The `Conn`'s outbound queue reached `Conn::kLowWatermark`; reading pauses.
    bool writableWaiters_ = false;   ///< Some tunnel waits for its queue to drain.
    bool peerEof_ = false;
    bool closing_ = false;     ///< The server is closing and GOAWAY has been submitted.
    bool done_ = false;        ///< The connection is closing or closed; nothing more is fed or sent.
};

#endif // !_WIN32

} // namespace Eco::System::HttpSrv

#endif // ECO_SYSTEM_HTTP_SERVER_HTTP2_HPP
