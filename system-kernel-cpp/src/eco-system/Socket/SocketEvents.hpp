//===- SocketEvents.hpp - Socket results to the main thread ---------------===//
//
// plans/eco-system-sockets.md §3.3.2. Stream data travels on the existing
// channel-results queue (ByteChannel.hpp); every other socket result is one
// POD SocketEvent on this queue, posted by the IoReactor thread (or by the
// main thread itself) and drained on the main thread by a drain registered
// with the eco/system async source (ready predicate: a lock-free count).
//
// The drain hands each event to the dispatch function registered for its
// kind (SocketTables.cpp registers Connected / Accepted / OpDone /
// ListenerClosed; S4's UDP code registers Datagram / UdpClosed) and calls
// Scheduler::drain() after every event that resumed a task or delivered a
// message (G12; the dispatch function reports that by returning true).
//
// Heap generations: every event carries the heap generation of the main-
// thread object that caused it (`gen`, captured on the main thread when
// the reactor object was created). An event of an older generation belongs
// to a dead heap (heap-reset harnesses, F24): its tokens and counts died
// with the heap, so the drain only releases its OS resources (an orphaned
// connection is aborted) and never resumes or decrements.
//
// Deferred main-thread work: requestSocketWork(fn) runs `fn` from the drain
// (once per request, deduplicated by function). The managers use it to
// deliver held FIFOs after onEffects (which must not call taggers itself).
//
// Lock order (§3.3.1 rule 6): IoReactor command mutex → this queue's mutex →
// Scheduler mutex.
//
// Templates used: T8/G12 (drain side), G10 (dispatchers own the counts).
//
//===----------------------------------------------------------------------===//

#ifndef ECO_SYSTEM_SOCKET_SOCKET_EVENTS_HPP
#define ECO_SYSTEM_SOCKET_SOCKET_EVENTS_HPP

#include <cstdint>
#include <memory>
#include <string>

namespace Eco::System {

class Conn;

// EpT (§3.2): kind 0 Inet (text = address, port), 1 Unix (text = path; "" unnamed; port 0).
struct SockEndpoint {
    int kind = 0;
    std::string text;
    int64_t port = 0;
};

// CredT (§3.2): a Unix peer's credentials, captured at accept/connect.
struct Cred {
    int64_t pid = 0, uid = 0, gid = 0;
};

// InfoT (§3.2): captured when a TLS handshake ends (S5).
struct TlsInfo {
    std::string protocol, alpn, cipher;
};

struct SocketEvent {
    enum class Kind : uint8_t { Connected, Accepted, Datagram, OpDone, ListenerClosed, UdpClosed };
    static constexpr int kKinds = 6;

    Kind kind = Kind::OpDone;
    uint64_t gen = 0;                // heap generation of the originating main-thread object
    uint64_t token = 0;              // Connected / OpDone / *Closed: the task's resume token (0: none)
    int64_t ownerId = 0;             // listener id (Accepted, ListenerClosed) or udp id (Datagram, UdpClosed)
    bool failed = false;             // failure (§D.5): code + message
    std::string code, message;
    std::shared_ptr<Conn> conn;      // Connected / Accepted
    SockEndpoint local, remote;
    Cred cred;
    bool hasCred = false;            // Unix: captured at accept/connect
    TlsInfo tls;
    bool hasTls = false;             // captured at handshake end
    bool isUnix = false;             // Connected / Accepted: a Unix domain connection
    std::string data;                // Datagram payload (S4)
};

// Main thread. Creates the queue (binding Scheduler::instance() on the main
// thread), registers the drain and the embed stop hook (§3.3.9). Every
// socket kernel body calls it before it submits work to the reactor.
// Idempotent.
void ensureSocketEvents();

// Any thread. Queues `ev` and wakes the scheduler loop.
void postSocketEvent(SocketEvent ev);

// Main thread. The handler of one event kind: returns true if it resumed a
// task or delivered a message (the drain then calls Scheduler::drain()).
// It runs only for events of the current heap generation.
using SocketEventDispatchFn = bool (*)(SocketEvent& ev);
void setSocketEventDispatch(SocketEvent::Kind kind, SocketEventDispatchFn fn);

// Main thread. Runs `fn` from the drain soon (deduplicated by function); fn
// may call Elm, sendToApp and drain() itself.
using SocketWorkFn = void (*)();
void requestSocketWork(SocketWorkFn fn);

// The heap generation the main thread is on now (Allocator::heapGeneration).
uint64_t currentHeapGeneration();

// Main thread (the drain, or a test).
void socketEventsDrain();

} // namespace Eco::System

#endif // ECO_SYSTEM_SOCKET_SOCKET_EVENTS_HPP
