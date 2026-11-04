//===- H2StreamPort.hpp - A WebSocket over an HTTP/2 stream (RFC 8441) ----===//
//
// A WebSocket can run over one stream of an HTTP/2 connection, and this component lets the transport-independent
// WebSocket codec (`WsCore`) do so unchanged.
//
// RFC 8441 opens such a WebSocket with an extended CONNECT request; once that is answered with a 2xx status, the
// stream is used as if it were a TCP connection. The frames, the masking and the close handshake are therefore those
// of RFC 6455, and `WsCore` needs only a `WsPort` that writes to and reads from the stream. `H2StreamPort` is that
// port. One HTTP/2 connection carries many streams, so everything a port keeps (buffered input, deadlines) is kept
// per stream, here, rather than on the connection.
//
// A port sits between two parties:
//
//   * The *tunnel* (`H2Tunnel`) is whatever carries the stream: it queues outgoing DATA and returns flow-control
//     credit for received bytes. Received bytes are consumed into the stream's flow-control window only when the
//     codec takes them, so a codec that has stopped reading holds the peer back through HTTP/2 flow control.
//   * The stream's *owner* reports what arrives through `streamData`, `streamEnd`, `streamReset` and
//     `streamWritable`.
//
// Terms used below. A port is *bound* once `bind` has attached the core. The stream is *gone* once `streamReset` has
// been called or `bind` was given no tunnel; after that the port makes no call on its tunnel.
//
// `H2PendingUpgrade` is the other half of the server side: the interface through which a WebSocket answers an
// extended CONNECT that has been received but not yet answered.
//
// Everything here is used on the reactor thread only.
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

/// The HTTP/2 stream an `H2StreamPort` runs on, as seen by the port.
///
/// An implementation is supplied by whatever owns the stream. The port calls these functions on the reactor thread,
/// and any of them may report back into the port (`streamData`, `streamWritable`, `streamReset`) before it returns.
/// The port does not own its tunnel and makes no call on it once `streamReset` has been called.
class H2Tunnel {
public:
    virtual ~H2Tunnel() = default;
    /// Queues `bytes` to be sent as DATA after the bytes of earlier calls. Returns false, queueing nothing, when the
    /// stream is gone or our side of it has ended.
    virtual bool tunnelWrite(std::string bytes) = 0;
    /// Returns the number of bytes queued by `tunnelWrite` and not yet framed.
    virtual size_t tunnelQueued() const = 0;
    /// Reports that the codec has taken `n` more received bytes, so that the stream's flow-control window can be
    /// replenished by `n`.
    virtual void tunnelConsume(size_t n) = 0;
    /// Ends our side of the stream (END_STREAM) after the queued bytes.
    virtual void tunnelEnd() = 0;
    /// Resets the stream with RST_STREAM and the HTTP/2 error code `code`.
    virtual void tunnelReset(uint32_t code) = 0;
};

/// The `WsPort` of one HTTP/2 stream that carries a WebSocket.
///
/// A port is made with its core and must be owned by a `std::shared_ptr`: `bind` and the other entry points take
/// `shared_from_this()`, so that a call that re-enters the port through its tunnel or its core cannot destroy it
/// while it runs. It cannot be copied.
///
/// Received bytes are kept until the core wants to read, and only the bytes the core has taken are reported to the
/// tunnel as consumed. The peer's END_STREAM reaches the core, as `WsCore::portEof`, only after every byte received
/// before it has been taken.
///
/// The `WsPort` calls map onto the stream as follows. `portWrite` queues on the tunnel and calls `done` before it
/// returns. `portCloseGraceful` ends our side after the queued bytes, and resets the stream with CANCEL if
/// `streamReset` has not been called within the drain time. `portAbort` resets the stream with CANCEL and, if the
/// port is bound, reports `WsCore::portClosed` at once. Deadlines are kept by the port itself, on a timer-only
/// reactor handler of its own.
///
/// Destroying a port removes its timer and detaches it from its core, and, if it is bound and its stream is not gone,
/// reports `WsCore::portClosed`.
class H2StreamPort final : public WsPort, public std::enable_shared_from_this<H2StreamPort> {
public:
    /// The HTTP/2 error code CANCEL, which the port resets its stream with.
    static constexpr uint32_t kCancel = 0x8;   // NGHTTP2_CANCEL

    /// Creates an unbound port for `core`.
    explicit H2StreamPort(std::shared_ptr<WsCore> core) : core_(std::move(core)) {}
    ~H2StreamPort() override;

    /// Attaches the core and gives it `buffered`, the bytes received on the stream before this call and not yet
    /// consumed, ahead of anything `streamData` has added since. When `tunnel` is null or `streamReset` has already
    /// been called, the stream is gone and the core is told at once, with `WsCore::portClosed`. Otherwise the port
    /// keeps `tunnel`, which must stay valid until `streamReset` is called or the port is destroyed. The port must
    /// already be owned by a `std::shared_ptr`.
    void bind(H2Tunnel* tunnel, std::string buffered);

    /// Adds `bytes`, received on the stream, to what the core is given. Ignored once the stream is gone.
    void streamData(std::string_view bytes);
    /// Reports the peer's END_STREAM. The core receives it once it has taken every byte received before. Ignored
    /// once the stream is gone.
    void streamEnd();
    /// Reports that the stream has closed, for HTTP/2 error code `code`; the port makes no further tunnel call.
    /// When `code` is 0 the core is first given what it will take of the bytes still held, and a pending
    /// `portEof` once nothing is held; otherwise they are dropped. Cancels the deadlines and, if bound, reports `WsCore::portClosed`. A second call does nothing.
    void streamReset(uint32_t code);
    /// Reports that queued bytes have been framed, by calling `WsCore::portWritable`, if the port is bound and the
    /// stream is not gone.
    void streamWritable();

    /// Calls `done`, before returning, with 0 when the tunnel queued `bytes`, and with ECANCELED when it did not or
    /// when the port is unbound, the stream is gone or our side has been ended. A 0 says only that the bytes were
    /// queued.
    void portWrite(std::string bytes, std::function<void(int err)> done) override;
    /// Returns the tunnel's queued bytes, or 0 once the stream is gone.
    size_t portOutbound() const override;
    /// Ignores `Conn::kTimerDrain` and ids out of range; a negative `monoMs` cancels like 0. Once the stream is gone
    /// only a `monoMs` of exactly 0 is acted on, cancelling that deadline.
    void portSetDeadline(int timerId, int64_t monoMs) override;
    /// Gives the core whatever held input it now wants.
    void portUpdateInterest() override;
    /// Ends our side of the stream after the queued bytes, and resets it with CANCEL when the drain time passes
    /// unless `streamReset` is called first; if the stream is reset during `tunnelEnd`, no drain time is set. A
    /// `drainMs` of 0 or less waits 2 seconds. Further `portWrite` calls fail. Does nothing once the stream is gone
    /// or our side is ending.
    void portCloseGraceful(int64_t drainMs) override;
    /// Does nothing once the stream is gone.
    void portAbort() override;

    H2StreamPort(const H2StreamPort&) = delete;
    H2StreamPort& operator=(const H2StreamPort&) = delete;

    /// The reactor handler that fires the port's deadlines.
    struct Timer;

private:
    /// Gives the core held input while it wants to read, consuming on the tunnel what it took, then the peer's
    /// END_STREAM once nothing is held. Does nothing when called again from inside itself.
    void deliver();
    /// Sets the timer to the earliest deadline, registering it with the reactor first if needed.
    void armTimer();
    /// Handles the deadlines that have passed.
    void fire();

    std::shared_ptr<WsCore> core_;
    // The stream's tunnel, not owned; null before `bind`, after `streamReset`, when bound with none,
    // and when `bind` came after `streamReset`.
    H2Tunnel* tunnel_ = nullptr;
    bool bound_ = false;
    bool gone_ = false;        // the stream closed: no more tunnel calls
    bool ending_ = false;      // our END_STREAM is queued
    bool endPending_ = false;  // the peer's END_STREAM, after the buffered bytes
    bool eofGiven_ = false;    // portEof has been called
    bool delivering_ = false;  // deliver is running
    std::string in_;           // received, not given to the core (not consumed)
    int64_t deadlines_[Conn::kMaxTimers] = {};   // monotonic ms per Conn timer id; 0: none
    std::shared_ptr<Timer> timer_;   // null until a deadline is first set
};

/// An HTTP/2 extended CONNECT that a server has received and not yet answered, as the WebSocket side sees it.
///
/// The stream stays with its connection until one of `accept`, `reject` or `abandon` answers it. An implementation is
/// supplied by the HTTP server, and its functions must be called on the reactor thread.
class H2PendingUpgrade {
public:
    virtual ~H2PendingUpgrade() = default;
    /// Writes the connection's local and remote endpoints to `local` and `remote`. Returns false when the stream or
    /// its connection is gone.
    virtual bool describe(SockEndpoint& local, SockEndpoint& remote) = 0;
    /// Answers the stream with `status` and `headers`, without END_STREAM, and binds the stream to `port` with
    /// `H2StreamPort::bind`. Returns false when the stream is gone.
    virtual bool accept(int status, const HeaderList& headers, const std::shared_ptr<H2StreamPort>& port) = 0;
    /// Answers the stream with a complete response of `status`, `headers` and `body`, and calls `done` once it is
    /// written, or at once when the stream is gone.
    virtual void reject(int status, const HeaderList& headers, std::string body,
                        std::function<void(int)> done) = 0;
    /// Drops the stream, resetting it with RST_STREAM(CANCEL) while it still awaits its answer;
    /// otherwise sends nothing.
    virtual void abandon() = 0;
};

} // namespace Eco::System

#endif // ECO_SYSTEM_WEBSOCKET_H2_STREAM_PORT_HPP
