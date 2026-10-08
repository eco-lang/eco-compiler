//===- H2StreamPort.hpp - A WebSocket over an HTTP/2 stream (RFC 8441) ----===//
//
// plans/eco-system-websockets.md §3.9 (W12, phase WS9), §10 WS4 notes. The
// WebSocket codec (WsCore) talks to its transport only through WsPort; an
// H2StreamPort is the WsPort of an extended CONNECT stream that was answered
// 2xx: the stream "is used as if it were the TCP connection" (RFC 8441 §5),
// so the frames, the masking and the close handshake stay as RFC 6455.
//
// REACTOR THREAD ONLY (G1). Two sides:
//
//   * H2Tunnel: what carries the stream. Http.Server's h2 connections
//     (Http2Protocol, through an adapter in HttpUpgrade.cpp) and the client's
//     own nghttp2 session (Http2ClientProtocol, Http2Client.hpp) implement
//     it. DATA writes are queued behind earlier ones; received bytes are
//     consumed into the stream's flow-control window only when the codec
//     takes them (tunnelConsume), so a paused codec back-pressures the peer
//     through HTTP/2 flow control.
//   * The stream's owner reports what arrives: streamData, streamEnd (the
//     peer's END_STREAM), streamReset (the stream closed: RST_STREAM, both
//     sides ended, or the connection is gone; no tunnel call is made after
//     it) and streamWritable (queued bytes were framed).
//
// Mapping of the WsPort calls:
//   * portWrite: tunnelWrite; `done` runs at once (0 when queued, ECANCELED
//     when the stream is gone or ended). The codec only writes while
//     portOutbound() (= tunnelQueued()) is below its high watermark, and the
//     owner calls streamWritable when the queue drained.
//   * portCloseGraceful: END_STREAM after the queued bytes (orderly close,
//     RFC 8441 §5); if the peer does not end its side within `drainMs` the
//     stream is reset with CANCEL.
//   * portAbort: RST_STREAM(CANCEL); the core is told at once (portClosed).
//   * portSetDeadline: the codec's timers (Conn timer ids) are kept here per
//     stream (one Conn may carry many tunnels): a timer-only IoHandler armed
//     at the earliest deadline.
//   * portUpdateInterest: hands buffered input to the core when it reads
//     again.
//
// Templates used: none (POD only, G1).
//
//===----------------------------------------------------------------------===//

#ifndef ECO_SYSTEM_WEBSOCKET_H2_STREAM_PORT_HPP
#define ECO_SYSTEM_WEBSOCKET_H2_STREAM_PORT_HPP

#include "eco-system/Socket/Conn.hpp"
#include "eco-system/Socket/SocketEvents.hpp"
#include "eco-system/WebSocket/WsHandshake.hpp"
#include "eco-system/WebSocket/WsProtocol.hpp"

#include <cstddef>
#include <cstdint>
#include <functional>
#include <memory>
#include <string>
#include <string_view>
#include <utility>
#include <vector>

namespace Eco::System {

// The HTTP/2 stream a tunnel runs on (reactor thread).
class H2Tunnel {
public:
    virtual ~H2Tunnel() = default;
    // Queues DATA behind earlier bytes; false when the stream is gone or ended.
    virtual bool tunnelWrite(std::string bytes) = 0;
    // Bytes queued and not yet framed.
    virtual size_t tunnelQueued() const = 0;
    // The codec took `n` received bytes: replenish the stream's window.
    virtual void tunnelConsume(size_t n) = 0;
    // END_STREAM after the queued bytes.
    virtual void tunnelEnd() = 0;
    // RST_STREAM(code).
    virtual void tunnelReset(uint32_t code) = 0;
};

class H2StreamPort final : public WsPort, public std::enable_shared_from_this<H2StreamPort> {
public:
    static constexpr uint32_t kCancel = 0x8;   // NGHTTP2_CANCEL

    explicit H2StreamPort(std::shared_ptr<WsCore> core) : core_(std::move(core)) {}
    ~H2StreamPort() override;

    // The stream was answered: attaches the core, then gives it `buffered`
    // (bytes received before; not consumed yet). `tunnel` may be null when
    // the stream is gone already.
    void bind(H2Tunnel* tunnel, std::string buffered);

    // From the stream's owner.
    void streamData(std::string_view bytes);
    void streamEnd();
    void streamReset(uint32_t code);
    void streamWritable();

    // WsPort.
    void portWrite(std::string bytes, std::function<void(int err)> done) override;
    size_t portOutbound() const override;
    void portSetDeadline(int timerId, int64_t monoMs) override;
    void portUpdateInterest() override;
    void portCloseGraceful(int64_t drainMs) override;
    void portAbort() override;

    H2StreamPort(const H2StreamPort&) = delete;
    H2StreamPort& operator=(const H2StreamPort&) = delete;

    struct Timer;

private:
    void deliver();
    void armTimer();
    void fire();

    std::shared_ptr<WsCore> core_;
    H2Tunnel* tunnel_ = nullptr;
    bool bound_ = false;
    bool gone_ = false;        // the stream closed: no more tunnel calls
    bool ending_ = false;      // our END_STREAM is queued
    bool endPending_ = false;  // the peer's END_STREAM, after the buffered bytes
    bool eofGiven_ = false;
    bool delivering_ = false;
    std::string in_;           // received, not given to the core (not consumed)
    int64_t deadlines_[Conn::kMaxTimers] = {};
    std::shared_ptr<Timer> timer_;
};

// Http.Server.upgradeRequest of an HTTP/2 extended CONNECT (§3.9): the stream
// stays with its connection (delivered, unanswered) until WebSocket.accept,
// reject or abandon. Implemented by Http.Server (HttpUpgrade.cpp: the
// WebSocket library does not link Http.Server); created on the main thread
// (WsTables handshake entry), called on the reactor thread only.
class H2PendingUpgrade {
public:
    virtual ~H2PendingUpgrade() = default;
    // The connection's endpoints; false when the stream or its connection is gone.
    virtual bool describe(SockEndpoint& local, SockEndpoint& remote) = 0;
    // Answers `status` + `headers` without END_STREAM and binds the stream to
    // `port` (H2StreamPort::bind). False when the stream is gone.
    virtual bool accept(int status, const HeaderList& headers, const std::shared_ptr<H2StreamPort>& port) = 0;
    // A complete response (status, headers, body), as Http.Server answers;
    // `done` once it is written (at once when the stream is gone).
    virtual void reject(int status, const HeaderList& headers, std::string body,
                        std::function<void(int)> done) = 0;
    // RST_STREAM(CANCEL).
    virtual void abandon() = 0;
};

} // namespace Eco::System

#endif // ECO_SYSTEM_WEBSOCKET_H2_STREAM_PORT_HPP
