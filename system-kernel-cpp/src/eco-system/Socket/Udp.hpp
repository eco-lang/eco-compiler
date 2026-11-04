//===- Udp.hpp - UDP sockets on the IoReactor -----------------------------===//
//
// Elm code sends and receives datagrams through `Socket.Udp`, and this component implements it: the sockets, the
// tasks that wait on them, and the C exports Elm calls.
//
// A UDP socket is driven from two threads. The socket itself belongs to the reactor thread (`IoReactor`), where a
// `UdpHandler` owns its fd and makes every system call on it. Everything Elm code can see belongs to the eco thread,
// the thread that runs the Elm scheduler: the table of open sockets, the tasks waiting on them, and the datagrams
// nobody has taken yet. The eco thread talks to a handler only by submitting commands to the reactor, and a handler
// answers only by posting `SocketEvent`s, which the socket event drain hands back to this component on the eco
// thread.
//
// Receiving is driven by demand. A handler reads from its socket only while someone wants a datagram: it keeps a
// *credit*, one for each parked receive (a `Socket.Udp.receive` task waiting for a datagram), and it is *unlimited*
// while the socket has `onMessage` subscribers. Each datagram it reads uses up one credit, and with neither credit nor
// subscribers it stops watching the socket, so unread datagrams stay in the operating system's buffer. A datagram
// that does not fit the `kMaxDatagram`-byte buffer is dropped.
//
// Delivery happens on the eco thread. A datagram that arrives is appended to the socket's *held FIFO*, and the FIFO is
// then served from the front: each datagram goes to the oldest parked receive, or, when none is parked, to every
// `onMessage` tagger of the socket (the "Socket.Udp" effect manager, `UdpManager`), and it stays held while there is
// neither. The held FIFO keeps at most `kMaxHeldDatagrams` datagrams and drops the oldest beyond that. A receive that
// starts while datagrams are held takes the oldest at once.
//
// Sends and multicast membership changes are commands to the handler, and each completes its task with one `OpDone`
// event. Sends go out in the order they were made: one that finds the socket's send buffer full waits, and the sends
// after it wait behind it.
//
// Holds. A hold is what keeps the program running while something can still happen (`HoldRelease` and the Scheduler
// own the rule). A bound socket holds nothing of its own. Each parked receive holds by its resume token until it is
// served, failed or killed; each send and membership change holds by its resume token until its `OpDone` is
// dispatched by `SocketTables`; and a socket named by an `onMessage` subscription takes one more, its subscription
// hold. Held datagrams hold nothing.
//
// Heap generations. The table belongs to one heap generation (`currentHeapGeneration`), and holds no Elm heap values.
// When `udpTables` finds the generation changed, every handler of the old heap is closed, the holds of subscriptions
// and parked receives are released, and the table is cleared. The holds of sends and membership changes whose
// `OpDone` is still in flight are not released by the reset.
//
// On Windows the bind fails with ENOTSUP, so no socket is ever opened, and every other kernel finds no socket: they
// fail with ECANCELED, and `udpClose` succeeds.
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

/// The reactor's side of one bound UDP socket: the owner of its fd, which reads datagrams while there is demand,
/// sends in order, and changes multicast membership.
///
/// A handler is made on the eco thread and held by `std::shared_ptr`; every member function but the constructor and
/// destructor must then run on the reactor thread, which the eco thread reaches with `IoReactor::submit`. It reports
/// everything it does as a `SocketEvent` stamped with the heap generation and socket id it was made with: a
/// `Datagram` for each datagram read, an `OpDone` for each send and membership change, and one `UdpClosed` when it
/// closes. Once closed it reads nothing more and fails every later send or membership change with ECANCELED.
///
/// The handler owns its fd from construction. `close` removes it from the reactor and closes it; a handler destroyed
/// without being closed closes the fd itself if it is not registered with the reactor. It cannot be copied.
class UdpHandler final : public IoHandler {
public:
    /// The size of the receive buffer, in bytes. A datagram longer than this is dropped. The bind also asks for
    /// socket send and receive buffers at least this large.
    static constexpr size_t kMaxDatagram = 65536;
    /// How long, in milliseconds, the handler stops reading after an unexpected `recvmsg` error, or after the
    /// reactor refuses to change what it watches.
    static constexpr int64_t kBackoffMs = 100;

    /// Creates the handler of `fd`, a bound, non-blocking, close-on-exec datagram socket, which it owns from now on.
    /// `socketId` and `gen` are copied into every event it posts, and `isV6` says whether `fd` is an IPv6 socket.
    /// Runs on the eco thread. The handler does nothing until `start`.
    UdpHandler(int fd, int64_t socketId, uint64_t gen, bool isV6);
    ~UdpHandler() override;

    // --- Reactor thread (submit) ------------------------------------------------
    /// Registers the handler with the reactor and watches the fd for whatever there is demand for. Does nothing if
    /// the handler is closed or already registered. If the reactor refuses the fd, the handler stays unregistered and
    /// never reads.
    void start();
    /// Adds `n` to the credit, which never goes below 0, and updates what the fd is watched for. Does nothing once
    /// closed.
    void addCredit(int64_t n);
    /// Turns unlimited receiving on or off: while it is on, the handler reads whatever the credit. Does nothing once
    /// closed.
    void setUnlimited(bool on);
    /// Sends `data` as one datagram to `address` and `port`, after every send queued before it, and posts one
    /// `OpDone` for `token` when it has gone or failed.
    ///
    /// An IPv4 destination on an IPv6 socket is sent to its IPv4-mapped address ::ffff:a.b.c.d; an IPv6 destination
    /// on an IPv4 socket fails with EAFNOSUPPORT, and an address that does not parse with EINVAL. A failure's message
    /// is "send <CODE> <address>:<port>".
    void send(uint64_t token, std::string address, int64_t port, std::string data);
    /// Joins (`join` true) or leaves the multicast group `group` and posts one `OpDone` for `token`.
    ///
    /// `iface`, when not empty, is an address of the same family as `group`; any other text fails with EINVAL. For
    /// IPv4 it chooses the interface by address, and an empty `iface` lets the system choose. For IPv6 only its scope
    /// (the part after '%') is used, as the interface index; an empty `iface` uses the group's own scope, which is 0
    /// when it has none. A `group` that does not parse fails with EINVAL. A failure's message is
    /// "addMembership <CODE>" or "dropMembership <CODE>".
    void membership(uint64_t token, bool join, std::string group, std::string iface);
    /// Closes the socket: fails every queued send with ECANCELED, removes the handler from the reactor, closes the fd
    /// and posts `UdpClosed`. Later calls do nothing, so `UdpClosed` is posted once.
    void close();

    void onReady(bool readable, bool writable, bool errorOrHangup) override;
    void onTimer() override;
    void onCloseAll() override;

    UdpHandler(const UdpHandler&) = delete;
    UdpHandler& operator=(const UdpHandler&) = delete;

private:
    /// One send waiting for the socket to accept it.
    struct SendReq {
        uint64_t token;
        SockAddr to;
        std::string data;
        std::string what;   // "address:port" for the error message
    };

    /// Returns whether the handler should read now: it is open, not backing off, and has credit or is unlimited.
    bool canReceive() const;
    /// Tells the reactor to watch the fd for reading if `canReceive` and for writing if a send is queued. If the
    /// reactor refuses, stops reading for `kBackoffMs`.
    void updateInterest();
    /// Reads datagrams while `canReceive` holds, posting a `Datagram` for each, or until the socket has none ready.
    void receiveLoop();
    /// Sends queued datagrams in order until the queue is empty or the socket's send buffer is full.
    void serviceSends();
    /// Posts the `OpDone` for `token`: success when `err` is 0, otherwise a failure with the message "<syscall>
    /// <CODE>", followed by " <what>" when `what` is not empty.
    void postOpDone(uint64_t token, int err, const char* syscall, const std::string& what);

    int fd_;   ///< -1 once closed.
    const int64_t socketId_;
    const uint64_t gen_;
    const bool isV6_;

    // Reactor thread only.
    int64_t credit_ = 0;
    bool unlimited_ = false;
    bool backoff_ = false;   ///< Reading is paused until the backoff timer fires.
    bool closed_ = false;
    std::deque<SendReq> sendQ_;
    std::vector<char> buf_;
};

// --- Bind ---------------------------------------------------------------

/// What a bind made on a pool worker hands to the eco thread: the bound socket and its address, or why the bind
/// failed.
///
/// The result owns `fd` while it is not -1, and its destructor closes it, so a result that is dropped without being
/// completed does not leak the socket. Taking the fd means setting `fd` to -1. A result can be moved, which hands the
/// fd over and leaves -1 behind, but not copied. Move-assignment first closes the fd the target already holds.
struct UdpBindResult {
    int fd = -1;                 ///< The bound socket; -1 on failure or once taken.
    bool isV6 = false;
    SockEndpoint bound;          ///< The address the socket is bound to.
    std::string code, message;   ///< The failure, when `code` is not empty.

    UdpBindResult() = default;
    UdpBindResult(UdpBindResult&& o) noexcept;
    UdpBindResult& operator=(UdpBindResult&& o) noexcept;
    UdpBindResult(const UdpBindResult&) = delete;
    UdpBindResult& operator=(const UdpBindResult&) = delete;
    ~UdpBindResult();
};

/// Creates a non-blocking, close-on-exec datagram socket and binds it to `address` and `port`, of whichever family
/// `address` is. Meant to run on a pool worker, and touches no Elm heap value.
///
/// `reuseAddress` sets SO_REUSEADDR (and SO_REUSEPORT on macOS), `broadcast` sets SO_BROADCAST, and on an IPv6
/// socket IPV6_V6ONLY is set to `ipv6Only`. Of these only a failure to set SO_BROADCAST fails the bind. The bound
/// address is read back from the socket, and is `address` and `port` if that fails. A failure's message is
/// "bind <CODE> <address>:<port>". On Windows the bind always fails, with the code ENOTSUP and a message saying
/// that sockets are not supported.
UdpBindResult udpBindOn(const std::string& address, int64_t port, bool reuseAddress,
                        bool broadcast, bool ipv6Only);

// --- Eco-thread table -------------------------------------------------------------

/// The eco thread's record of one open UDP socket and of the work waiting on it.
struct UdpEntry {
    std::shared_ptr<UdpHandler> handler;   ///< Set at bind, before the entry enters the table.
    SockEndpoint bound;
    /// The resume tokens of the parked receives, oldest first. Each holds by its token.
    std::deque<uint64_t> parkedReceives;
    /// The `Datagram` events nobody has taken yet, oldest first, at most `kMaxHeldDatagrams`. They hold nothing.
    std::deque<SocketEvent> held;
    /// The subscription hold, taken while an `onMessage` subscription names the socket.
    HoldToken subHold = kNoHold;
    bool subscribed = false;               ///< Whether the handler was last told to receive unlimited.
    bool closed = false;                   ///< `udpClose` has run; the entry stays until `UdpClosed` arrives.
};

/// The most datagrams a socket's held FIFO keeps; when another arrives, the oldest is dropped.
constexpr size_t kMaxHeldDatagrams = 64;

/// The UDP sockets of one heap generation, by socket id, including closed ones until their `UdpClosed` arrives.
struct UdpTables {
    std::unordered_map<int64_t, UdpEntry> sockets;
    int64_t nextId = 1;   ///< The id the next bound socket gets; not reset with the table.
    uint64_t gen = 0;     ///< The heap generation the table belongs to.
    bool init = false;    ///< Whether `gen` has been set.
};

/// Returns the table of the current heap generation, first resetting it if the generation changed, as the file
/// comment describes. Eco thread only.
UdpTables& udpTables();
/// Returns the entry of socket `id`, or null if there is none. The pointer is valid until the entry is erased or the
/// table reset, which Elm code or a drain run in the meantime can cause. Eco thread only.
UdpEntry* findUdp(int64_t id);

/// Makes sure the socket event drain dispatches `Datagram` and `UdpClosed` events here and `OpDone` events to
/// `SocketTables`. Every UDP kernel body calls it before using the table. Eco thread only.
void ensureUdpTables();

/// Brings every open socket in line with the current `onMessage` subscriptions: tells each handler whose state
/// changed to receive unlimited or not, takes or releases each socket's subscription hold, and, when a subscribed
/// socket has held datagrams, asks the socket event drain to deliver them on its next pass. Eco thread only.
void udpTablesSyncSubscriptions();

/// Withdraws the parked receive with resume token `token`, for its kill handle, and returns whether it was still
/// parked. When it returns true the kill handle releases the receive's hold; when false, whoever took the receive
/// releases it. A withdrawn receive gives back its credit, unless the socket is closed.
bool cancelParkedReceive(uint64_t token);

// --- Kernel bodies --------------------------------------------------

// The step functions of the Tasks the exports in UdpExports.cpp return. Each runs on the eco thread when its Task
// runs, reads its arguments from `captured`, the payload the export built, and, for the async ones, completes the
// Task through `resume`. Send, receive and membership fail with ECANCELED for a socket id that names no open
// socket.

/// Binds a socket on a pool worker with `udpBindOn`, and on success adds it to the table and succeeds with
/// `( socketId, ( address, port ) )`, the bound address. Returns `()` as the kill handle, so nothing cancels a bind
/// once it has started.
HPointer udpBindBody(HPointer captured, HPointer resume);
/// Asks the socket's handler to send one datagram, and completes when the handler reports the send done.
HPointer udpSendBody(HPointer captured, HPointer resume);
/// Succeeds with the socket's oldest held datagram, as `( data, ( fromAddress, fromPort ) )`, or parks until one
/// arrives and returns a kill handle that withdraws the receive. Fails with ECANCELED if the socket closes first.
HPointer udpReceiveBody(HPointer captured, HPointer resume);
/// Closes the socket and succeeds; does nothing more for a socket that is closed or unknown. Fails the parked
/// receives with ECANCELED and drops the held datagrams at once; the handler closes on the reactor thread.
HPointer udpCloseBody(HPointer captured);
/// Asks the socket's handler to join or leave a multicast group, and completes when the handler reports it done.
HPointer udpMembershipBody(HPointer captured, HPointer resume);

// --- Manager hooks (UdpManager.cpp) ------------------------------------------------
/// Returns whether any `onMessage` subscription names socket `socketId`.
bool udpManagerHasSubscribers(int64_t socketId);
/// Calls every `onMessage` tagger of socket `socketId` with `dgramT` and sends each resulting message to the
/// application, running the scheduler after each. `dgramT` must be rooted by the caller.
void udpManagerDeliver(int64_t socketId, HPointer& dgramT);

} // namespace Eco::System

#endif // ECO_SYSTEM_SOCKET_UDP_HPP
