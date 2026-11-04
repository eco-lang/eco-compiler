//===- Listener.hpp - A listening stream socket on the IoReactor ----------===//
//
// A listening socket must not accept connections faster than something will take them, and this component is a
// listening stream socket, run on the reactor, that accepts only as many as it has been asked for.
//
// A `ListenerHandler` is the `IoHandler` of one listening fd, TCP or Unix. It accepts connections, wraps each one in a
// `Conn`, runs the connection's transport handshake, and hands every connection whose handshake succeeds on. TLS is
// not built in: a `TransportFactory` given at construction builds each accepted connection's transport, and without
// one the transport is plain.
//
// Accepting is driven by demand, and the demand is kept here, on the reactor thread:
//   * *Credit* is the number of connections still wanted. `addCredit` raises or lowers it, and it never falls below
//     zero. *Unlimited*, set by `setUnlimited`, wants every connection whatever the credit.
//   * A credit is *reserved* when a connection is accepted and given back if its handshake fails, so it is used up
//     only by a connection that is handed on.
//   * At most `kMaxHandshakes` connections are in their handshake at once.
// The listener watches its fd for readability only while those rules allow another accept, and accepts until they
// stop allowing it or the fd has nothing more to give.
//
// A connection whose handshake succeeds is handed on in one of two ways:
//   * By default it is posted to the eco thread as a `SocketEvent` of kind `Accepted`, carrying the `Conn`.
//   * In *callback mode*, set by `setCallbackMode`, a `ProtocolFactory` called on the reactor thread gives it a
//     protocol, and the connection stays on the reactor. Credit and unlimited do not apply. Instead, when a maximum is
//     given, the listener accepts while fewer than that many of its accepted connections are *open*, meaning their
//     fd is not yet closed, handshaking ones included.
//
// Plain handshakes complete at once. A handshake through a transport factory has a deadline of
// `kHandshakeTimeoutMs`, and one that fails or passes its deadline is aborted with nothing reported.
//
// An accept that fails for want of a resource, such as file descriptors or memory, or for any reason not known to be
// transient, stops the listener watching its fd for `kBackoffMs`, so that a level-triggered fd that stays readable
// does not make it spin. The same pause follows a failure to change the fd's interest.
//
// Closing aborts the connections still in their handshake, unregisters the listener, closes the fd and unlinks a Unix
// path the listener owns, and only then posts a `SocketEvent` of kind `ListenerClosed`, so that whoever receives it
// can listen on the same address at once. In callback mode nothing is posted.
//
//===----------------------------------------------------------------------===//

#ifndef ECO_SYSTEM_SOCKET_LISTENER_HPP
#define ECO_SYSTEM_SOCKET_LISTENER_HPP

#include "eco-system/Core/IoReactor.hpp"
#include "eco-system/Socket/Conn.hpp"

#include <cstdint>
#include <functional>
#include <memory>
#include <string>
#include <vector>

namespace Eco::System {

/// The reactor-side handler of one listening stream socket, which accepts connections as the file comment describes.
///
/// A `ListenerHandler` has identity and is held by `std::shared_ptr`; it cannot be copied. It owns its listening fd
/// and, when told to, the Unix socket path: both are released by `close` or `onCloseAll`, or by the destructor if the
/// listener was never registered with the reactor. Once `start` has registered it, the reactor keeps it alive until it
/// is closed. Each connection still in its handshake is kept alive by the listener until its handshake ends or the
/// listener closes. Apart from the constructor, the destructor and `setCallbackMode`, every member function must be
/// called on the reactor thread; nothing here takes a lock.
class ListenerHandler final : public IoHandler {
public:
    /// The largest number of accepted connections that may be in their transport handshake at once, per listener.
    static constexpr int kMaxHandshakes = 64;
    /// The time, in milliseconds, a handshake through a transport factory may take before it is abandoned.
    static constexpr int64_t kHandshakeTimeoutMs = 120000;
    /// The pause, in milliseconds, in watching the fd after an accept or interest change fails.
    static constexpr int64_t kBackoffMs = 100;

    /// Creates a listener over `fd`, a listening, non-blocking socket that the listener owns from now on. It may be
    /// called on the eco thread, before the listener is shared with the reactor.
    ///
    /// `listenerId` and `gen` are the owner id and heap generation carried by the events the listener posts.
    /// `unixPath` is the path a Unix listener listens on; it is reported as the local endpoint in each `Accepted`
    /// event. `ownsPath` makes the listener unlink `unixPath` when it closes. `factory` builds each accepted
    /// connection's transport, and when it is null the transport is plain.
    ListenerHandler(int fd, int64_t listenerId, uint64_t gen, bool isUnix, std::string unixPath,
                    bool ownsPath, TransportFactory factory);
    ~ListenerHandler() override;

    /// A function that builds the protocol for an accepted connection whose handshake has succeeded, in callback mode.
    ///
    /// It is called on the reactor thread with the `Conn`, once per connection. A null result aborts the connection.
    using ProtocolFactory = std::function<std::unique_ptr<ConnProtocol>(Conn&)>;
    /// Puts the listener in callback mode: each connection whose handshake succeeds is given the protocol `factory`
    /// builds instead of being posted. The listener accepts while fewer than `maxConnections` of its connections are
    /// open, or without limit when `maxConnections` is negative. It may be called on the eco thread, and must be
    /// called before `start`.
    void setCallbackMode(ProtocolFactory factory, int64_t maxConnections);

    // --- Reactor thread ------------------------------------------------------

    /// Returns how many connections this listener accepted in callback mode whose fd is not yet closed. Outside
    /// callback mode it is 0.
    int64_t openConnections() const { return open_; }
    /// Registers the listener with the reactor and starts watching its fd if accepting is allowed. Does nothing if the
    /// listener is closed or already registered, or if the reactor does not register it.
    void start();
    /// Adds `n`, which may be negative, to the credit, keeping it at 0 or above. Does nothing once closed.
    void addCredit(int64_t n);
    /// Sets whether the listener accepts every connection whatever its credit. Does nothing once closed.
    void setUnlimited(bool on);
    /// Closes the listener as the file comment describes, posting `ListenerClosed` unless in callback mode.
    void close();

    /// Accepts connections while accepting is allowed, whatever readiness is reported.
    void onReady(bool readable, bool writable, bool errorOrHangup) override;
    /// Ends a backoff pause and watches the fd again if accepting is allowed.
    void onTimer() override;
    /// Does the same as `close`.
    void onCloseAll() override;

    ListenerHandler(const ListenerHandler&) = delete;
    ListenerHandler& operator=(const ListenerHandler&) = delete;

private:
    /// Returns whether another connection may be accepted now: not closed, not backing off, below `kMaxHandshakes`,
    /// and, in callback mode, below the connection limit, otherwise unlimited or with credit left.
    bool canAccept() const;
    /// While registered and open, watches the fd for readability exactly when `canAccept` holds, and starts a backoff
    /// pause if that fails and none is running.
    void updateInterest();
    /// Accepts connections until `canAccept` fails, the fd would block, or an accept fails in a way that starts a
    /// backoff pause, and begins each one's handshake. It does nothing on Windows.
    void acceptLoop();
    /// Receives the outcome `ok` of the handshake of `c`, and hands the connection on, or aborts it.
    void established(Conn& c, bool ok);
    /// Closes the listener if it is open, and posts `ListenerClosed` if `post` is set and the listener is not in
    /// callback mode.
    void closeNow(bool post);
    /// Counts one fewer open connection in callback mode, called when an accepted connection's fd closes.
    void connClosed();

    int fd_;
    const int64_t listenerId_;
    const uint64_t gen_;
    const bool isUnix_;
    const std::string unixPath_;
    bool ownsPath_;
    TransportFactory factory_;

    // Callback mode, fixed before start().
    ProtocolFactory protocolFactory_;
    int64_t maxConnections_ = -1;

    // Reactor thread only.
    int64_t open_ = 0;                ///< Callback mode: accepted connections whose fd is not closed yet.
    int64_t credit_ = 0;
    bool unlimited_ = false;
    bool backoff_ = false;
    bool closed_ = false;
    /// An accepted connection whose transport handshake has not yet ended.
    struct Handshake {
        std::shared_ptr<Conn> conn;
        bool reserved;   ///< Whether the connection holds a reserved credit, given back if its handshake fails.
    };
    std::vector<Handshake> handshaking_;
};

} // namespace Eco::System

#endif // ECO_SYSTEM_SOCKET_LISTENER_HPP
