//===- Udp.hpp - UDP sockets on the IoReactor -----------------------------===//
//
// plans/eco-system-sockets.md §3.3.5, §3.3.7, §3.3.8, §3.4, Appendix B.2,
// §D.4. Two halves:
//
//   * UdpHandler (reactor thread, POD only, G1): the IoHandler of one bound
//     SOCK_DGRAM fd (non-blocking, cloexec, SO_SNDBUF/SO_RCVBUF >= 65 536).
//     Receiving is demand-driven with the listener's credit scheme (SD14,
//     N2): one credit per parked Socket.Udp.receive (addCredit(+1); a
//     cancelled receive sends -1, floored at 0), unlimited while the socket
//     has onMessage subscribers (setUnlimited). Readable: recvmsg into a
//     65 536-byte buffer; MSG_TRUNC → drop and continue; post Datagram.
//     Sends are queued in order: sendto with the §D.4 destination
//     conversion (an IPv4 destination on an IPv6 socket goes to
//     ::ffff:a.b.c.d; an IPv6 destination on an IPv4 socket fails
//     EAFNOSUPPORT); EAGAIN → write interest; each send posts OpDone.
//     Membership: IP_ADD/DROP_MEMBERSHIP (imr_interface = the interface
//     address or INADDR_ANY) / IPV6_JOIN/LEAVE_GROUP (ipv6mr_interface = the
//     interface address's scope, if_nametoindex or the decimal index, else
//     the group's scope, else 0); OpDone. close(): fail queued sends
//     ECANCELED, remove, close the fd, post UdpClosed.
//
//   * The main-thread UDP table (T5-style, keyed on the heap generation,
//     holding NO HPointers): UdpEntry { handler, bound endpoint, parked
//     receive tokens (oldest first), the held FIFO of datagrams nobody took
//     yet (max 64, the oldest dropped), closed, counted, subscribed }.
//     Delivery (§3.4): a datagram goes to the oldest parked receive, else to
//     every onMessage tagger of the socket (the "Socket.Udp" manager), else
//     into the held FIFO; held items are served first whenever a consumer
//     appears.
//
// Counts (§3.3.8, G10): a bound socket holds one pendingAsync count from
// the bind completion until its UdpClosed drain; send and membership (R
// mode) hold one each until their OpDone drain (SocketTables.cpp's OpDone
// dispatcher); parked receives (A mode) hold none: their CancelFn returns a
// credit and returns false.
//
// Windows: udpBind fails ENOTSUP on the pool, so no handler ever exists and
// every other kernel fails (or, for udpClose, does nothing) on an unknown id.
//
// Templates used: T2 (bind), T5 (generation-keyed table), T7 (receive kill
// handle), T8 (delivery through the manager), T9/G10 (completions), G12.
//
//===----------------------------------------------------------------------===//

#ifndef ECO_SYSTEM_SOCKET_UDP_HPP
#define ECO_SYSTEM_SOCKET_UDP_HPP

#include "eco-system/Core/Core.hpp"
#include "eco-system/Core/IoReactor.hpp"
#include "eco-system/Core/SocketUtil.hpp"
#include "eco-system/Socket/SocketEvents.hpp"

#include <cstdint>
#include <deque>
#include <memory>
#include <string>
#include <unordered_map>
#include <vector>

namespace Eco::System {

// --- Reactor side --------------------------------------------------------------

class UdpHandler final : public IoHandler {
public:
    static constexpr size_t kMaxDatagram = 65536;     // receive buffer (§3.3.5)
    static constexpr int64_t kBackoffMs = 100;        // unexpected recvmsg errors (N9)

    // Main thread. `fd` is a bound, non-blocking, cloexec SOCK_DGRAM socket
    // (owned from now on); `isV6` its family.
    UdpHandler(int fd, int64_t socketId, uint64_t gen, bool isV6);
    ~UdpHandler() override;

    // --- Reactor thread (submit) ------------------------------------------------
    void start();                     // add to the reactor (no interest until credit or a send)
    void addCredit(int64_t n);        // +1 per parked receive, -1 per cancelled one (floor 0)
    void setUnlimited(bool on);       // while the socket has subscribers
    // One OpDone for `token` each (heap generation `gen_`).
    void send(uint64_t token, std::string address, int64_t port, std::string data);
    void membership(uint64_t token, bool join, std::string group, std::string iface);
    void close();                     // posts UdpClosed

    void onReady(bool readable, bool writable, bool errorOrHangup) override;
    void onTimer() override;
    void onCloseAll() override;

    UdpHandler(const UdpHandler&) = delete;
    UdpHandler& operator=(const UdpHandler&) = delete;

private:
    struct SendReq {
        uint64_t token;
        SockAddr to;
        std::string data;
        std::string what;   // "address:port" for the error message
    };

    bool canReceive() const;
    void updateInterest();
    void receiveLoop();
    void serviceSends();
    void postOpDone(uint64_t token, int err, const char* syscall, const std::string& what);

    int fd_;
    const int64_t socketId_;
    const uint64_t gen_;
    const bool isV6_;

    // Reactor thread only.
    int64_t credit_ = 0;
    bool unlimited_ = false;
    bool backoff_ = false;
    bool closed_ = false;
    std::deque<SendReq> sendQ_;
    std::vector<char> buf_;
};

// --- Bind (§3.3.7) ---------------------------------------------------------------

struct UdpBindResult {
    int fd = -1;                 // owned (closed by the destructor unless released)
    bool isV6 = false;
    SockEndpoint bound;
    std::string code, message;   // failure (code non-empty)

    UdpBindResult() = default;
    UdpBindResult(UdpBindResult&& o) noexcept;
    UdpBindResult& operator=(UdpBindResult&& o) noexcept;
    UdpBindResult(const UdpBindResult&) = delete;
    UdpBindResult& operator=(const UdpBindResult&) = delete;
    ~UdpBindResult();   // RAII: a killed bind's orphaned result closes its fd (N11)
};

// Pool worker (blocking; POD only, G1).
UdpBindResult udpBindOn(const std::string& address, int64_t port, bool reuseAddress,
                        bool broadcast, bool ipv6Only);

// --- Main-thread table -------------------------------------------------------------

struct UdpEntry {
    std::shared_ptr<UdpHandler> handler;
    SockEndpoint bound;
    std::deque<uint64_t> parkedReceives;   // resume tokens, oldest first (no count of their own)
    std::deque<SocketEvent> held;          // Datagram events nobody took yet (max kMaxHeld)
    bool counted = true;                   // holds the bound socket's pendingAsync count
    bool subscribed = false;               // setUnlimited(true) was sent
    bool closed = false;                   // udpClose ran (the UdpClosed event is pending)
};

constexpr size_t kMaxHeldDatagrams = 64;   // §3.3.4: on overflow drop the oldest

struct UdpTables {
    std::unordered_map<int64_t, UdpEntry> sockets;
    int64_t nextId = 1;
    uint64_t gen = 0;
    bool init = false;
};

// Main thread. The table of the current heap generation (reset first if the
// generation changed: every handler is closed, its counts died with the
// heap). Never hold an entry pointer across an allocation or an Elm call.
UdpTables& udpTables();
UdpEntry* findUdp(int64_t id);

// Main thread: registers the Datagram / UdpClosed dispatchers (and
// ensureSocketTables() for OpDone). Every UDP kernel body calls it first.
void ensureUdpTables();

// The "Socket.Udp" manager changed its subscriptions: sends setUnlimited to
// every socket whose subscribed state changed and schedules the delivery of
// held datagrams (from the socket drain, not from onEffects).
void udpTablesSyncSubscriptions();

// T7 CancelFn of a parked receive: always false (A mode holds no count).
bool cancelParkedReceive(uint64_t token);

// --- Kernel bodies (Appendix B.2) --------------------------------------------------

HPointer udpBindBody(HPointer captured, HPointer resume);        // P
HPointer udpSendBody(HPointer captured, HPointer resume);        // R
HPointer udpReceiveBody(HPointer captured, HPointer resume);     // A
HPointer udpCloseBody(HPointer captured);                        // S
HPointer udpMembershipBody(HPointer captured, HPointer resume);  // R

// --- Manager hooks (UdpManager.cpp) ------------------------------------------------
bool udpManagerHasSubscribers(int64_t socketId);
// Calls every tagger of the socket with `dgramT` (rooted by the caller),
// sendToApp + drain() per message (T8, G12).
void udpManagerDeliver(int64_t socketId, HPointer& dgramT);

} // namespace Eco::System

#endif // ECO_SYSTEM_SOCKET_UDP_HPP
