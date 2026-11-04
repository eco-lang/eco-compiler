//===- Http2Client.hpp - The WebSocket client over HTTP/2 (RFC 8441) ------===//
//
// A WebSocket dial can ask to run over HTTP/2 (RFC 8441), and when the TLS handshake of a dial that asked for it chose
// ALPN "h2", this component is the connection's protocol from then on: it carries the opening handshake and then the
// WebSocket itself on one HTTP/2 stream.
//
// RFC 8441 opens a WebSocket with an *extended CONNECT*: a CONNECT request with a `:protocol` pseudo-header, which a
// server may be sent only after its SETTINGS have set ENABLE_CONNECT_PROTOCOL to 1. A 2xx answer turns the stream
// into a byte pipe for RFC 6455 frames, which `H2StreamPort` connects to the WebSocket codec. `Http2ClientProtocol`
// runs an nghttp2 client session over the `Conn`'s bytes (the session has no socket of its own), and carries exactly
// one WebSocket: when its stream closes, the session ends and the connection closes.
//
// The protocol goes through these steps.
//
//   1. It sends its SETTINGS (no server push; an initial stream window of `kInitialWindow`) and waits for the
//      server's. Window updates are not sent automatically: a received byte is credited back to the stream's
//      window only when it is consumed, as below.
//   2. If the server's SETTINGS set ENABLE_CONNECT_PROTOCOL to 1, it sends the extended CONNECT (`:method` CONNECT,
//      `:protocol` websocket, `:scheme` https, `:path` and `:authority` from the `DialSpec`, then
//      `DialSpec::h2Headers`). nghttp2 does not make this check for a client, so this protocol does. Otherwise it
//      ends the session with GOAWAY(NO_ERROR), closes the connection gracefully and calls `DialJob::redialHttp1`.
//   3. The response HEADERS are reported with `DialJob::h2HeadDone` when they carry a valid `:status`; an informational
//      (1xx) HEADERS frame that does not end the stream is skipped. The answered stream is then *held*: until
//      `bindPort`, its DATA is kept here and not credited back to the stream's window, so the window bounds how much a
//      server can send. The connection's window is credited at once for all DATA.
//   4. `bindPort` binds the held stream to an `H2StreamPort`, and this protocol is then the port's `H2Tunnel`.
//      Outgoing bytes are sent as DATA, END_STREAM ends our side, RST_STREAM resets the stream, and received bytes
//      are credited back as the port reports them consumed.
//   5. When the stream closes, the port, if bound, is told with `H2StreamPort::streamReset`, the session ends with
//      GOAWAY(NO_ERROR), and the connection is closed gracefully once that is written. A connection that reports a read
//      or write error is aborted; one that reaches end of input is closed gracefully.
//
// Until the response HEADERS arrive, the dial can fail. Each failure is reported with `DialJob::failed` and the
// connection is aborted: ETIMEDOUT "WebSocket handshake ETIMEDOUT <address>:<port>" when the dial's deadline passes;
// ERR_WS_HANDSHAKE when the server sends what nghttp2 rejects, answers with no `:status`, resets the opening stream,
// or ends the session or the connection; ENOMEM when no session can be made; and, for a read or write error, the
// transport's code. An abort from elsewhere fails it with ECANCELED. After the answer, a failure of the connection
// closes the stream with CANCEL.
//
// Everything here is used on the reactor thread only. The class is not built on Windows, where
// `makeHttp2ClientProtocol` returns null.
//
//===----------------------------------------------------------------------===//

#ifndef ECO_SYSTEM_WEBSOCKET_HTTP2_CLIENT_HPP
#define ECO_SYSTEM_WEBSOCKET_HTTP2_CLIENT_HPP

#include "eco-system/Socket/Conn.hpp"
#include "eco-system/WebSocket/H2StreamPort.hpp"
#include "eco-system/WebSocket/WsHandshake.hpp"

#include <cstdint>
#include <memory>
#include <string>
#include <string_view>

struct nghttp2_session;   // nghttp2.h (only Http2Client.cpp includes it)

namespace Eco::System {

/// Creates the protocol for a connection of `job` whose TLS handshake chose ALPN "h2", or returns null on Windows.
std::unique_ptr<ConnProtocol> makeHttp2ClientProtocol(std::shared_ptr<DialJob> job);

#ifndef _WIN32

/// The protocol of one client connection that carries a WebSocket over HTTP/2, from the first SETTINGS until the
/// session ends, as the file comment describes.
///
/// It is installed on an open connection with `Conn::setProtocol`, whose `onOpen` call starts the session. It keeps
/// `job` for the whole connection. It cannot be copied. Destroying it resets the bound port's stream with CANCEL, so
/// the port is not left with a dangling tunnel, and frees the session.
class Http2ClientProtocol final : public ConnProtocol, public H2Tunnel {
public:
    /// The initial stream flow-control window, in bytes, that our SETTINGS give the server. It bounds the DATA a
    /// held stream can receive before `bindPort`.
    static constexpr int32_t kInitialWindow = 64 * 1024;
    /// The drain time, in milliseconds, given to `Conn::closeGraceful` when this protocol closes the connection.
    static constexpr int64_t kCloseDrainMs = 2000;

    /// Creates a protocol that reports the handshake to `job`.
    explicit Http2ClientProtocol(std::shared_ptr<DialJob> job) : job_(std::move(job)) {}
    ~Http2ClientProtocol() override;

    void onOpen(Conn& c) override;
    void onData(Conn& c, std::string_view bytes) override;
    void onEof(Conn& c) override;
    void onError(Conn& c, int err, const std::string& code) override;
    void onWritable(Conn& c) override;
    void onTimer(Conn& c, int timerId) override;
    void onCloseAll(Conn& c) override;
    /// Returns whether the session wants input, except that it returns false once the protocol is closing, when there
    /// is no session, and from when the connection's queued output reaches `Conn::kLowWatermark` until `onWritable`.
    bool wantsRead() const override;

    /// Binds the held stream to `port` with `H2StreamPort::bind`, giving it the DATA kept so far, and returns true.
    /// The port is given this protocol as its tunnel, or no tunnel if the stream has closed or the protocol is
    /// closing; an END_STREAM received while held is then passed on with `H2StreamPort::streamEnd` unless the
    /// stream has closed. Returns false, and does nothing, when no response has been reported or a port is bound
    /// already.
    bool bindPort(std::shared_ptr<H2StreamPort> port);

    // The `H2Tunnel` of the bound stream. Once the stream has closed or the protocol is closing, every call but
    // `tunnelQueued` does nothing, and `tunnelWrite` returns false.

    /// Also returns false before the extended CONNECT has been sent and after `tunnelEnd`.
    bool tunnelWrite(std::string bytes) override;
    size_t tunnelQueued() const override;
    void tunnelConsume(size_t n) override;
    void tunnelEnd() override;
    void tunnelReset(uint32_t code) override;

    Http2ClientProtocol(const Http2ClientProtocol&) = delete;
    Http2ClientProtocol& operator=(const Http2ClientProtocol&) = delete;

    /// The nghttp2 session callbacks, which act on the protocol passed as their user data.
    struct Cb;

private:
    /// How far the opening handshake has gone. The dial can fail only in `Settings` and `Requested`.
    ///
    /// `Settings` waits for the server's SETTINGS, `Requested` for the answer to the extended CONNECT. `Held` is an
    /// answered stream waiting for `bindPort`, and `Bound` one bound to a port. `Done` is set only when the server
    /// does not allow extended CONNECT and the dial is to be redialled over HTTP/1.1.
    enum class Phase : uint8_t { Settings, Requested, Held, Bound, Done };
    friend struct Cb;

    /// Runs one IO step: frames pending output, feeds the received input to the session, frames again, then acts on the
    /// outcome (redial over HTTP/1.1, notify the port once its queue falls below `Conn::kLowWatermark`, close the
    /// connection once the session is over). Called while the session is reading input, it does nothing, as the step
    /// that is running frames the output afterwards; called during `flush`, it makes the flush loop once more.
    void afterIo();
    /// Feeds the input received so far to the session. Does nothing while already doing so. A session error fails
    /// the dial during the handshake, and otherwise closes the stream with CANCEL and ends the session.
    void process();
    /// Writes the session's output to the connection until there is none or the connection's queue reaches
    /// `Conn::kLowWatermark`, which then pauses reading. A session error closes the stream with CANCEL.
    void flush();
    /// Reports the dial failed with `code` and `message`, and aborts the connection, unless the protocol is
    /// closing already.
    void failDial(const std::string& code, const std::string& message);
    /// Handles the close of the stream with HTTP/2 error code `code`, once: fails the dial with ERR_WS_HANDSHAKE
    /// during the handshake, and otherwise resets the bound port's stream with `code` and ends the session.
    void streamGone(uint32_t code);
    /// Handles the server's END_STREAM: passes it to the bound port, or records it while the stream is held.
    void endOfStream();
    /// Ends the session with GOAWAY(NO_ERROR), once; the connection closes when that has been written.
    void endSession();
    /// Sends the extended CONNECT for the job's `DialSpec`, or fails the dial with ERR_WS_HANDSHAKE if nghttp2
    /// refuses it.
    void submitRequest();

    std::shared_ptr<DialJob> job_;
    /// The connection this protocol is installed on, which owns it. Null until `onOpen`.
    Conn* conn_ = nullptr;
    /// The session, owned and freed by the destructor. Null until `onOpen` makes it, or if it could not.
    nghttp2_session* session_ = nullptr;
    Phase phase_ = Phase::Settings;
    int32_t sid_ = -1;   ///< The extended CONNECT's stream id; -1 until it is sent.

    // The response.
    int status_ = 0;             ///< 0 while no valid `:status` has been read.
    HeaderList headers_;         ///< The regular fields; pseudo-headers are dropped.
    std::string held_;           ///< DATA received while held, not yet credited to the stream window.
    bool heldEnd_ = false;       ///< The server's END_STREAM arrived while held.
    bool streamClosed_ = false;
    std::shared_ptr<H2StreamPort> port_;

    // The request body (tunnel bytes).
    std::string out_;
    size_t outOff_ = 0;          ///< How much of `out_` has been framed.
    bool outEnd_ = false;        ///< `tunnelEnd` was called: END_STREAM follows `out_`.
    bool deferred_ = false;      ///< The data provider deferred; the next write or end must resume it.
    bool notifyWritable_ = false;   ///< The queue reached `Conn::kLowWatermark`; the port is owed `streamWritable`.

    // The IO step.
    std::string in_;             ///< Received bytes not yet given to the session.
    bool processing_ = false;    ///< Inside `nghttp2_session_mem_recv2`.
    bool flushing_ = false;      ///< Inside `flush`.
    bool flushAgain_ = false;    ///< `afterIo` was called during `flush`.
    bool outHigh_ = false;       ///< The connection's queue reached `Conn::kLowWatermark`; reading is paused.
    bool fallback_ = false;      ///< Redial over HTTP/1.1 at the end of this IO step.
    bool ending_ = false;        ///< The session is ending: close the connection once nothing is left to write.
    bool done_ = false;          ///< Closing or closed: nothing more is reported or sent.
};

#endif // !_WIN32

} // namespace Eco::System

#endif // ECO_SYSTEM_WEBSOCKET_HTTP2_CLIENT_HPP
