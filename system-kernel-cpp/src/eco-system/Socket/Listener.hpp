//===- Listener.hpp - A listening stream socket on the IoReactor ----------===//
//
// plans/eco-system-sockets.md §3.3.4. A ListenerHandler is the IoHandler of
// one listening fd (TCP or Unix; TLS through its TransportFactory, S5).
// Reactor-thread only, except construction (main thread, in the listen
// completion, before it is shared with the reactor).
//
// Credit (SD14, N2): accepting is demand-driven and the demand lives on the
// reactor side. `credit` counts the connections the main thread wants: one
// per parked Socket.accept (addCredit(+1); a cancelled accept sends -1,
// floored at 0), plus "unlimited" while the listener has onConnection
// subscribers (setUnlimited). Read interest only while credit allows and
// fewer than kMaxHandshakes TLS handshakes are running.
//
//   * Readable: accept (accept4 SOCK_NONBLOCK|SOCK_CLOEXEC; macOS accept +
//     fcntl + SO_NOSIGPIPE, SF9) while credit allows. Each accepted fd
//     becomes a Conn with the factory's transport; a finite credit is
//     reserved at accept and returned if the handshake fails (so it is
//     consumed only on completion, N10). The plain handshake completes at
//     once, so a plain connection is posted (SocketEvent Accepted) at once.
//     A TLS handshake runs on the reactor with a 120 s deadline (Node's
//     default); a failed or timed-out one is dropped silently.
//   * Errors: EAGAIN/EWOULDBLOCK stop; ECONNABORTED/EINTR/EPROTO retry;
//     EMFILE/ENFILE/ENOBUFS/ENOMEM (and anything unexpected) drop interest
//     and retry from a 100 ms timer (no spin, N9).
//   * close(): close every handshaking connection, remove, close the fd,
//     unlink the Unix path if this listener created it, THEN post
//     ListenerClosed, so the closeListener task completes once the address
//     is free again (an immediate re-listen works).
//
// Templates used: none (POD only, G1).
//
//===----------------------------------------------------------------------===//

#ifndef ECO_SYSTEM_SOCKET_LISTENER_HPP
#define ECO_SYSTEM_SOCKET_LISTENER_HPP

#include "eco-system/Core/IoReactor.hpp"
#include "eco-system/Socket/Conn.hpp"

#include <cstdint>
#include <memory>
#include <string>
#include <vector>

namespace Eco::System {

class ListenerHandler final : public IoHandler {
public:
    static constexpr int kMaxHandshakes = 64;               // per listener (N10)
    static constexpr int64_t kHandshakeTimeoutMs = 120000;  // Node's default
    static constexpr int64_t kBackoffMs = 100;              // EMFILE & co. (N9)

    // Main thread. `fd` is a listening, non-blocking, cloexec socket (owned
    // from now on). `unixPath`: the listen path of a Unix listener (endpoints
    // of accepted connections, §D.3); `ownsPath`: unlink it on close.
    // `factory` null = plain transport.
    ListenerHandler(int fd, int64_t listenerId, uint64_t gen, bool isUnix, std::string unixPath,
                    bool ownsPath, TransportFactory factory);
    ~ListenerHandler() override;

    // --- Reactor thread (submit) ------------------------------------------------
    void start();                     // add to the reactor (no interest until credit)
    void addCredit(int64_t n);        // +1 per parked accept, -1 per cancelled one (floor 0)
    void setUnlimited(bool on);       // while the listener has subscribers
    void close();                     // §3.3.4 "Close"; posts ListenerClosed

    void onReady(bool readable, bool writable, bool errorOrHangup) override;
    void onTimer() override;
    void onCloseAll() override;

    ListenerHandler(const ListenerHandler&) = delete;
    ListenerHandler& operator=(const ListenerHandler&) = delete;

private:
    bool canAccept() const;
    void updateInterest();
    void acceptLoop();
    void established(Conn& c, bool ok);
    void closeNow(bool post);

    int fd_;
    const int64_t listenerId_;
    const uint64_t gen_;
    const bool isUnix_;
    const std::string unixPath_;
    bool ownsPath_;
    TransportFactory factory_;

    // Reactor thread only.
    int64_t credit_ = 0;
    bool unlimited_ = false;
    bool backoff_ = false;
    bool closed_ = false;
    struct Handshake {
        std::shared_ptr<Conn> conn;
        bool reserved;   // holds one finite credit (returned on failure)
    };
    std::vector<Handshake> handshaking_;
};

} // namespace Eco::System

#endif // ECO_SYSTEM_SOCKET_LISTENER_HPP
