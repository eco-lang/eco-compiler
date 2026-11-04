//===- SocketEvents.hpp - Socket results to the eco thread ----------------===//
//
// Socket work runs on the IoReactor thread, but the tasks and subscriptions waiting for its results live on the
// eco thread, which alone may touch the Elm heap. This component carries those results across: every socket result
// other than stream data (which travels on the channel-results queue of `ByteChannel.hpp`) is one `SocketEvent`, a
// plain record holding no Elm heap pointers, posted on a single queue from any thread and drained on the eco thread.
//
// The drain is added with `addDrainSource`; its ready predicate reads only atomic counters, so it takes no lock. On
// each pass it first runs the requested socket work (below), then pops events one at a time and hands each to the
// dispatch function registered for its kind. When the dispatch function reports that it resumed a task or delivered
// a message, the drain calls `Scheduler::drain()` before taking the next event.
//
// Heap generation: every event carries `gen`, a heap generation taken on the eco thread when the operation or the
// object behind the event began. After a heap reset an event of an older generation refers to tokens and holds
// that died with the old heap (the scheduler voids them at the reset). The drain does not dispatch such an event; it only releases its OS resources,
// aborting the connection it carries, if any. An event whose kind has no dispatch function is released the same
// way. Such an event is called an orphan.
//
// Socket work: `requestSocketWork(fn)` asks the drain to call `fn` on its next pass, once however often it was
// requested before then. It lets code that must not call taggers itself (an effect manager's onEffects) have
// eco-thread work done soon after.
//
// An exception that escapes a dispatch function or a work function is reported with `reportFatal`; it never unwinds
// into the scheduler loop.
//
//===----------------------------------------------------------------------===//

#ifndef ECO_SYSTEM_SOCKET_SOCKET_EVENTS_HPP
#define ECO_SYSTEM_SOCKET_SOCKET_EVENTS_HPP

#include <cstdint>
#include <memory>
#include <string>

namespace Eco::System {

class Conn;

/// A socket's local or remote address, as the Elm side receives it.
///
/// `kind` 0 is an Internet address: `text` is the address and `port` the port. `kind` 1 is a Unix domain address:
/// `text` is the path, empty for an unnamed socket, and `port` is 0. Nothing enforces this pairing.
struct SockEndpoint {
    int kind = 0;
    std::string text;
    int64_t port = 0;
};

/// The process id, user id and group id of the peer of a Unix domain connection.
struct Cred {
    int64_t pid = 0, uid = 0, gid = 0;
};

/// What a completed TLS handshake negotiated: the protocol version, the ALPN protocol and the cipher, as text.
struct TlsInfo {
    std::string protocol, alpn, cipher;
};

/// One socket result on its way to the eco thread.
///
/// Which members are meaningful depends on `kind`; the rest keep their defaults. The record holds no Elm heap
/// pointers, so it may be built on any thread and may outlive a heap reset.
struct SocketEvent {
    /// The kind of result, which selects the dispatch function. `Count_` is not a kind: it stays last, and its
    /// value is the number of kinds.
    enum class Kind : uint8_t { Connected, Accepted, Datagram, OpDone, ListenerClosed, UdpClosed, Count_ };
    /// The number of `Kind` enumerators (`Count_` excluded): the size of the dispatch table.
    static constexpr int kKinds = static_cast<int>(Kind::Count_);

    Kind kind = Kind::OpDone;
    uint64_t gen = 0;                ///< Heap generation; see the file comment.
    uint64_t token = 0;              ///< Connected, OpDone: the waiting task's resume token.
    int64_t ownerId = 0;             ///< Listener id (Accepted, ListenerClosed) or UDP socket id (Datagram, UdpClosed).
    bool failed = false;             ///< True if the operation failed; `code` and `message` then describe it.
    std::string code, message;
    /// Accepted, and a Connected that succeeded: the connection, kept alive while the event is in transit. An
    /// orphan's connection is aborted.
    std::shared_ptr<Conn> conn;
    SockEndpoint local, remote;
    Cred cred;
    bool hasCred = false;            ///< True if `cred` was captured (a Unix domain connection).
    TlsInfo tls;
    bool hasTls = false;             ///< True if `tls` was captured (a TLS handshake completed).
    bool isUnix = false;             ///< Connected, Accepted: true for a Unix domain connection.
    std::string data;                ///< Datagram: the payload.
};

/// Sets up the event queue, once; later calls do nothing. Must be called on the eco thread (its once-flag, the
/// dispatch table and the work list are not locked) before any event is posted. It adds the drain, starts the
/// IoReactor, and registers a scheduler stop hook that calls `IoReactor::closeAll()`, so that the program's
/// listeners and connections do not stay open after the scheduler loop stops on request.
void ensureSocketEvents();

/// Queues `ev` for the drain and wakes the scheduler loop. May be called on any thread. No other lock is taken while
/// the queue's mutex is held: the scheduler is woken after it is released.
void postSocketEvent(SocketEvent ev);

/// A function that handles events of one kind on the eco thread, called by the drain with each such event of the
/// current heap generation. It may move from the event. It returns true if it resumed a task or delivered a message,
/// and the drain then calls `Scheduler::drain()`.
using SocketEventDispatchFn = bool (*)(SocketEvent& ev);

/// Makes `fn` the dispatch function for events of `kind`, replacing any earlier one; null removes it, and events of
/// that kind are then released as orphans. Eco thread only.
void setSocketEventDispatch(SocketEvent::Kind kind, SocketEventDispatchFn fn);

/// A function the drain calls on the eco thread at a caller's request. It may call Elm code and send messages; the
/// drain does not call `Scheduler::drain()` after it, so it must do so itself if it resumed or delivered anything.
using SocketWorkFn = void (*)();

/// Asks the drain to call `fn` on its next pass. A function requested again before that pass runs is still called
/// once. A request made while the work is running is served on a later pass. Eco thread only.
void requestSocketWork(SocketWorkFn fn);

/// Returns the heap generation the allocator is on now (`Allocator::heapGeneration`).
uint64_t currentHeapGeneration();

/// Runs one pass of the drain: the requested socket work, then every queued event, as the file comment describes.
/// Eco thread only. It is the drain `ensureSocketEvents` adds, and may also be called directly.
void socketEventsDrain();

} // namespace Eco::System

#endif // ECO_SYSTEM_SOCKET_SOCKET_EVENTS_HPP
