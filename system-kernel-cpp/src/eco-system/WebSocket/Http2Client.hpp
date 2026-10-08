//===- Http2Client.hpp - The WebSocket client over HTTP/2 (RFC 8441) ------===//
//
// plans/eco-system-websockets.md §3.9 "Client (opt-in)", W12 (phase WS9).
// `WebSocket.connect` with `http2 = True` on a wss URL dials with ALPN
// "h2,http/1.1" (DialJob, WsHandshake.hpp). When the server chose h2, the
// connection's protocol is an Http2ClientProtocol: one nghttp2 1.70.0
// *client* session (no sockets: nghttp2_session_mem_recv2 / mem_send2), for
// exactly one WebSocket (no pool, W12):
//
//   1. Our SETTINGS (ENABLE_PUSH 0, INITIAL_WINDOW_SIZE 64 KiB; no automatic
//      WINDOW_UPDATE: flow control is manual), then wait for the server's.
//   2. The server's SETTINGS_ENABLE_CONNECT_PROTOCOL (nghttp2 does not check
//      it for a client, WF3): 1 → the extended CONNECT (:method CONNECT,
//      :protocol websocket, :scheme https, :path, :authority, then
//      sec-websocket-version 13, -protocol, -extensions and the user's
//      fields; no Connection, Upgrade or key, RFC 8441 §4); 0 → GOAWAY
//      (NO_ERROR), close, and DialJob::redialHttp1 (the same address over
//      HTTP/1.1, within the same deadline).
//   3. The response HEADERS (1xx skipped) → DialJob::h2HeadDone posts Dialed
//      (status, the header fields, isH2): Elm accepts any 2xx (D.2). Until
//      `open` the stream's DATA is kept (not consumed: its window, 64 KiB,
//      bounds it), as a HoldProtocol keeps the bytes past a 101.
//   4. `open` binds the stream to an H2StreamPort (bindPort); this protocol
//      is then the port's H2Tunnel: frames stay masked (WF7), DATA is written
//      with a deferred data provider, received bytes are consumed into the
//      stream window when the codec takes them, END_STREAM is the orderly
//      close, RST_STREAM(CANCEL) the abort.
//   5. When the stream is closed (both sides ended, or reset) the session
//      ends: GOAWAY(NO_ERROR) and the connection closes.
//
// Everything before step 3 is bounded by the dial's deadline (kTimerHeaders):
// ETIMEDOUT "WebSocket handshake ETIMEDOUT <address>:<port>". A server that
// closes or resets the stream before answering fails the dial with
// ERR_WS_HANDSHAKE.
//
// REACTOR THREAD ONLY (G1). POSIX only (nghttp2 is not built on Windows,
// where the factory returns null and dial fails ENOTSUP anyway).
//
// Templates used: none (POD only, G1).
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

// The protocol for a dial whose ALPN chose h2 (null on Windows).
std::unique_ptr<ConnProtocol> makeHttp2ClientProtocol(std::shared_ptr<DialJob> job);

#ifndef _WIN32

class Http2ClientProtocol final : public ConnProtocol, public H2Tunnel {
public:
    static constexpr int32_t kInitialWindow = 64 * 1024;
    static constexpr int64_t kCloseDrainMs = 2000;

    explicit Http2ClientProtocol(std::shared_ptr<DialJob> job) : job_(std::move(job)) {}
    ~Http2ClientProtocol() override;

    void onOpen(Conn& c) override;
    void onData(Conn& c, std::string_view bytes) override;
    void onEof(Conn& c) override;
    void onError(Conn& c, int err, const std::string& code) override;
    void onWritable(Conn& c) override;
    void onTimer(Conn& c, int timerId) override;
    void onCloseAll(Conn& c) override;
    bool wantsRead() const override;

    // `open` (reactor command): binds the answered stream to `port` (which
    // attaches its core and gets the bytes kept so far). False when there is
    // no answered stream (the connection failed before).
    bool bindPort(std::shared_ptr<H2StreamPort> port);

    // H2Tunnel.
    bool tunnelWrite(std::string bytes) override;
    size_t tunnelQueued() const override;
    void tunnelConsume(size_t n) override;
    void tunnelEnd() override;
    void tunnelReset(uint32_t code) override;

    Http2ClientProtocol(const Http2ClientProtocol&) = delete;
    Http2ClientProtocol& operator=(const Http2ClientProtocol&) = delete;

    struct Cb;   // nghttp2 callbacks (Http2Client.cpp)

private:
    enum class Phase : uint8_t { Settings, Requested, Held, Bound, Done };
    friend struct Cb;

    void afterIo();
    void process();
    void flush();
    void failDial(const std::string& code, const std::string& message);
    void streamGone(uint32_t code);
    void endOfStream();
    void endSession();
    void submitRequest();

    std::shared_ptr<DialJob> job_;
    Conn* conn_ = nullptr;
    nghttp2_session* session_ = nullptr;
    Phase phase_ = Phase::Settings;
    int32_t sid_ = -1;

    // The response.
    int status_ = 0;
    HeaderList headers_;
    std::string held_;           // DATA before `open` (not consumed)
    bool heldEnd_ = false;       // END_STREAM before `open`
    bool streamClosed_ = false;
    uint32_t closeCode_ = 0;
    std::shared_ptr<H2StreamPort> port_;

    // The request body (tunnel bytes).
    std::string out_;
    size_t outOff_ = 0;
    bool outEnd_ = false;
    bool deferred_ = false;
    bool notifyWritable_ = false;

    std::string in_;
    bool processing_ = false;
    bool flushing_ = false;
    bool flushAgain_ = false;
    bool outHigh_ = false;
    bool fallback_ = false;      // redial over HTTP/1.1 after this IO step
    bool ending_ = false;        // GOAWAY submitted: close once it is out
    bool done_ = false;          // closing / closed
};

#endif // !_WIN32

} // namespace Eco::System

#endif // ECO_SYSTEM_WEBSOCKET_HTTP2_CLIENT_HPP
