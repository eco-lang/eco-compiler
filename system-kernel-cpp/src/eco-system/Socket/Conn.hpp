//===- Conn.hpp - One stream connection on the IoReactor ------------------===//
//
// plans/eco-system-sockets.md §3.3.3. A Conn is the IoHandler of one
// connected stream socket (TCP or Unix; TLS through its Transport, S5). All
// of its IO state is REACTOR-THREAD ONLY: the main thread reaches it only by
// IoReactor::submit()ting lambdas that hold a shared_ptr<Conn> (the faces,
// ConnChannel.hpp, and the kernel bodies, Socket.cpp). Nothing here touches
// the Elm heap (G1); results go out as POD ChannelResults (stream data) and
// SocketEvents (connect results).
//
// Transport: the byte layer between the fd and the connection, so TLS is
// added (S5, EcoSystem_Tls) without Core or Socket knowing OpenSSL. The plain
// transport is recv/send with MSG_NOSIGNAL. Each transport call records in
// wantRead / wantWrite what it waits for, so per-operation interest follows
// the transport (TLS may need to write to read, N6).
//
// Life cycle:
//   * client: built on the main thread (makeClient, no fd yet), then
//     startConnect() on the reactor: socket, options, non-blocking connect
//     (EINPROGRESS → write interest + the connect timer), SO_ERROR, the
//     transport's handshake (same deadline), then ONE SocketEvent Connected
//     (success with endpoints / credentials / TLS info, or a failure after
//     which the fd is closed). A kill (T7) races the result through the
//     `resolved` atomic: exactly one of cancelConnect() and the reactor wins.
//   * server: built on the reactor by the ListenerHandler (makeAccepted)
//     over an accepted fd, registered, then beginServer() runs the transport
//     handshake (plain: done at once) with a deadline and reports to the
//     listener through a callback.
//   * open: the current protocol (ConnProtocol, plans/eco-system-websockets.md
//     §3.2) gets the plaintext while it wants to read, queues writes
//     (write / shutdownWrite), sets deadlines (several ids multiplexed on
//     the reactor's one timer per handler) and closes (closeGraceful /
//     abort). A new Conn runs the stream faces (FaceProtocol: the
//     Socket.Connection streams); setProtocol hands the connection to
//     another protocol with the bytes read past the old one's end.
//   * close: closeGraceful = the queued writes, SHUT_WR, then Draining:
//     discard input until EOF (closing with unread data would make Linux
//     send RST instead of our FIN, N8) and flush what the transport still
//     holds (e.g. a TLS close_notify and its SHUT_WR), bounded by the drain
//     deadline (2 s for the faces); abort() (Socket.close) / reset close at
//     once (no close_notify).
//   * pending transport output (Transport::hasPendingWrite) keeps write
//     interest in every phase and is flushed when writable, so a TLS
//     shutdownWrite that returned 1 (from closeWritable or a write-face
//     shutdown) completes without further requests.
//
// Templates used: none (POD only, G1); T9 completion side (ChannelResult).
//
//===----------------------------------------------------------------------===//

#ifndef ECO_SYSTEM_SOCKET_CONN_HPP
#define ECO_SYSTEM_SOCKET_CONN_HPP

#include "eco-system/Core/ByteChannel.hpp"
#include "eco-system/Core/IoReactor.hpp"
#include "eco-system/Socket/SocketEvents.hpp"

#include <atomic>
#include <cstddef>
#include <cstdint>
#include <deque>
#include <functional>
#include <memory>
#include <string>
#include <string_view>
#include <vector>

#ifndef _WIN32
#include <sys/types.h>
#else
#include <cstddef>
typedef std::ptrdiff_t ssize_t;
#endif

namespace Eco::System {

// --- Transport (reactor thread) ----------------------------------------------

class Transport {
public:
    virtual ~Transport() = default;
    // 0: handshake done; 1: in progress (wantRead/wantWrite set); <0: failed
    // (errCode/errMessage set).
    virtual int handshake() { return 0; }
    // Up to n bytes of application data: >0 bytes, 0 EOF, -1 would block,
    // -2 error (errCode set: the errno name, or a TLS code).
    virtual ssize_t read(char* buf, size_t n) = 0;
    // >=0 bytes accepted, -1 would block, -2 error (errCode set).
    virtual ssize_t write(const char* buf, size_t n) = 0;
    // TLS: close_notify then SHUT_WR; plain: SHUT_WR. 0 done, 1 again
    // (wantRead/wantWrite set), <0 failed (errCode set).
    virtual int shutdownWrite() = 0;
    // TLS: SSL_has_pending (decrypted data that no fd event will announce).
    virtual bool hasBufferedRead() const { return false; }
    // TLS: bytes the transport produced but the socket has not taken yet
    // (records behind an accepted write, a close_notify, the SHUT_WR that
    // follows it). While true the Conn keeps write interest and calls
    // flush() when writable, in every phase that still owns the fd (S5:
    // a write-face shutdown or the final close must not lose them).
    virtual bool hasPendingWrite() const { return false; }
    // Sends what hasPendingWrite() reports: 0 nothing left, 1 again
    // (wantWrite set), -2 error (errCode set; nothing is pending afterwards).
    virtual int flush() { return 0; }
    // TLS: the handshake's result (§3.6 info), captured as POD by the Conn
    // when the handshake ends. False for a plain transport.
    virtual bool info(TlsInfo& out) const { (void)out; return false; }

    bool wantRead = false, wantWrite = false;   // what the last call needs
    std::string errCode, errMessage;            // set by a failed call
    int errNo = 0;                              // its errno (0: a TLS protocol error)
};

// recv/send with MSG_NOSIGNAL (SF10) on `fd` (not owned: the Conn closes it).
std::unique_ptr<Transport> makePlainTransport(int fd);

// Builds the transport of a new connection: `isServer` for accepted ones.
// Called on the reactor thread. nullptr = the plain transport.
using TransportFactory = std::function<std::unique_ptr<Transport>(int fd, bool isServer)>;

// --- Client connect parameters (copied out of the heap by the body, G3) -----

struct ConnectSpec {
    bool isUnix = false;
    std::string address;        // TCP: address text (§D.1); Unix: the path
    int64_t port = 0;           // TCP
    int64_t timeoutMs = 0;      // 0: none (covers connect and handshake)
    bool noDelay = false;       // TCP
    int64_t keepAliveSec = 0;   // TCP; 0: off
    bool isTls = false;         // the factory makes a TLS transport (S5)
};

// --- Protocols (plans/eco-system-websockets.md §3.2, W17) -------------------

class Conn;

// What runs over an open connection: the stream faces (FaceProtocol, the
// Socket.Connection streams), and later HTTP/1.1, HTTP/2 and WebSocket.
// Reactor thread only; never touches the heap (G1). A Conn has exactly one
// current protocol; setProtocol hands the connection to another one.
//
// Callbacks are made by the Conn from inside its own IO loop; a protocol
// may call any Conn method from a callback (write, setDeadline,
// setProtocol, closeGraceful, abort, ...): the Conn finishes the current
// step first (no nested reads). A protocol replaced by setProtocol is kept
// alive until its queued writes are done, so `done` callbacks may capture
// it.
class ConnProtocol {
public:
    virtual ~ConnProtocol() = default;
    // After connect / accept (+ TLS handshake), or when installed by
    // setProtocol on an open connection (before onData(leftover)).
    virtual void onOpen(Conn& /*c*/) {}
    // Plaintext from the transport (or the leftover of a hand-off). Only
    // while wantsRead() (leftover: regardless). The view dies on return.
    virtual void onData(Conn& c, std::string_view bytes) = 0;
    // Peer FIN (after a TLS close_notify, or an unexpected EOF). Once.
    virtual void onEof(Conn& c) = 0;
    // A transport failure. `code` is the stream reason of §D.2 of the
    // sockets plan: "read <CODE>" for a failed read (reading is over) or
    // "write <CODE>" for a failed write or flush (writing is over; queued
    // writes were already failed through their `done`). At most once per
    // direction.
    virtual void onError(Conn& c, int err, const std::string& code) = 0;
    // outbound() fell below kLowWatermark after having reached it.
    virtual void onWritable(Conn& /*c*/) {}
    // A deadline set with setDeadline(timerId, ...) passed (in deadline
    // order; ties by id). Ids owned by the Conn while it uses them
    // (kTimerConnect while connecting, kTimerDrain after closeGraceful)
    // are not forwarded.
    virtual void onTimer(Conn& /*c*/, int /*timerId*/) {}
    // The connection is torn down NOW (Conn::abort: Socket.close / reset,
    // a protocol's own abort, embed stop, heap reset): fail everything
    // pending. The Conn closes the fd when it returns. At most once.
    virtual void onCloseAll(Conn& c) = 0;
    // Read interest (demand-driven, sockets plan §3.3.1 rule 1).
    virtual bool wantsRead() const = 0;
};

class FaceProtocol;

// --- The connection ----------------------------------------------------------

class Conn : public IoHandler {
public:
    enum class Phase : uint8_t { Idle, Connecting, Handshaking, Open, Draining, Closed };

    // Timer ids (setDeadline). Several deadlines share the reactor's one
    // timer per handler: the earliest is armed, onTimer dispatches every
    // expired id.
    static constexpr int kTimerConnect = 0;          // connect / TLS handshake (Conn)
    static constexpr int kTimerDrain = 1;            // closeGraceful (Conn)
    static constexpr int kTimerIdle = 2;             // idle / keep-alive
    static constexpr int kTimerHeaders = 3;
    static constexpr int kTimerRequest = 4;
    static constexpr int kTimerHeartbeat = 5;
    static constexpr int kTimerPong = 6;
    static constexpr int kTimerCloseHandshake = 7;
    static constexpr int kMaxTimers = 8;

    // onWritable fires when outbound() drops below this after reaching it.
    static constexpr size_t kLowWatermark = 64 * 1024;
    // The drain of the stream faces' final close (N8, SF8).
    static constexpr int64_t kFaceDrainMs = 2000;

    // Main thread: a client connection for resume token `token` (the
    // Connected event carries it) of heap generation `gen`. Its protocol is
    // a FaceProtocol.
    static std::shared_ptr<Conn> makeClient(ConnectSpec spec, TransportFactory factory,
                                            uint64_t token, uint64_t gen);
    // Reactor thread: a connection over an accepted fd (owned from now on).
    // Its protocol is a FaceProtocol until setProtocol (listener callback
    // mode).
    static std::shared_ptr<Conn> makeAccepted(int fd, bool isUnix, std::unique_ptr<Transport> t);

    ~Conn() override;

    // --- Reactor thread -------------------------------------------------------

    // Client: create the socket and connect (§3.3.3 "Connect").
    void startConnect();
    // Client, set before startConnect: the connect result goes to `cb` on
    // the reactor thread instead of a SocketEvent Connected (the WebSocket
    // dial, plans/eco-system-websockets.md §3.6). On success the connection
    // is Open with its FaceProtocol (`cb` typically installs another
    // protocol); on failure it is already closed. Called at most once.
    using ConnectCallback =
        std::function<void(Conn&, bool ok, const std::string& code, const std::string& message)>;
    void setConnectCallback(ConnectCallback cb) { connectCb_ = std::move(cb); }
    // Server: the fd is registered (IoReactor::add); run the transport
    // handshake until done (deadline: monotonic ms, 0 none), then call
    // done(*this, ok). For the plain transport done(true) is called at once.
    void beginServer(int64_t deadlineMs, std::function<void(Conn&, bool ok)> done);

    // Hand-off (§3.2): installs `p` (the old protocol is retired, kept alive
    // until its queued writes are done). On an open connection: p->onOpen,
    // then p->onData(leftover) if `leftover` is non-empty (bytes the old
    // protocol read past its end), then interest is re-evaluated, which
    // also delivers plaintext a TLS transport still buffers. Only between
    // protocol callbacks or from a reactor command.
    void setProtocol(std::unique_ptr<ConnProtocol> p, std::string leftover);
    ConnProtocol* protocol() const { return protocol_.get(); }

    // Queues `bytes` behind earlier writes; done(0) once the transport took
    // all of them, done(errno) on failure / cancel. On a connection whose
    // write side is finished (or after shutdownWrite / closeGraceful) done
    // is called at once, inside write(). `done` may be null.
    void write(std::string bytes, std::function<void(int err)> done);
    // Bytes queued and not yet taken by the transport.
    size_t outbound() const { return outBytes_; }
    // Re-evaluates read/write interest after the protocol's wants changed
    // (and attempts the IO at once: most reads find data, and TLS may hold
    // decrypted bytes no fd event announces, N6).
    void updateInterest();
    // Deadline `timerId` (0..kMaxTimers-1) at monotonic `monoMs`; 0 cancels.
    void setDeadline(int timerId, int64_t monoMs);
    int64_t deadline(int timerId) const;
    // FIN after the queued writes (TLS: close_notify first). done(0) once
    // sent, done(errno) on failure; with a null `done` failures are silent
    // (best effort). No-op (done(0/err) at once) when writing is over.
    void shutdownWrite(std::function<void(int err)> done = nullptr);
    // Fails every queued write and pending shutdownWrite callback with
    // `err` (the shutdown itself stays requested).
    void cancelWrites(int err);
    // Orderly close: the queued writes, then SHUT_WR, then discard input
    // until EOF (unless already seen) while what the transport holds is
    // flushed; the fd closes then, or when `drainMs` (> 0) passes. The
    // protocol gets no more data.
    void closeGraceful(int64_t drainMs);
    // Socket.close (reset = false) / Socket.reset (reset = true, TCP:
    // SO_LINGER {1,0}): onCloseAll, fail the rest, close now. No close_notify.
    void abort(bool reset);
    // The TLS handshake's result; nullptr for plain or before the handshake.
    const TlsInfo* tlsInfo() const { return hasTls_ ? &tls_ : nullptr; }
    // Called once on the reactor thread when the fd is closed.
    void addCloseHook(std::function<void(Conn&)> hook);

    // State the protocols read (reactor thread).
    bool eofSeen() const { return eofSeen_; }
    int readError() const { return readErr_; }
    const std::string& readErrorReason() const { return readErrReason_; }
    int writeError() const { return writeErr_; }
    const std::string& writeErrorReason() const { return writeErrReason_; }
    bool writeEnded() const { return writeDone_; }   // FIN sent, failed, or given up
    bool aborted() const { return aborted_; }
    bool closing() const { return closing_; }

    // Face requests (ConnChannel.cpp), forwarded to the FaceProtocol; one
    // ChannelResult each. After a hand-off away from the faces they fail
    // ECANCELED with faceDetachedReason (default "socket closed").
    void reqRead(uint64_t channelId, uint64_t token, size_t maxBytes);
    void reqWrite(uint64_t channelId, uint64_t token, std::string bytes);
    void reqCloseWrite(uint64_t channelId, uint64_t token);   // graceful half-close
    void reqCloseRead(uint64_t channelId, uint64_t token);    // the reader is done (EOF seen)
    void readFaceShutdown();    // cancelReadable / face dropped: abandon reading (no SHUT_RD)
    void writeFaceShutdown();   // cancelWritable / face dropped: fail queued writes, SHUT_WR
    // The FaceProtocol while it is the current protocol, else nullptr.
    FaceProtocol* face() const { return face_; }
    void setFaceDetachedReason(std::string reason) { faceDetachedReason_ = std::move(reason); }

    // setNoDelay / setKeepAlive (R mode): 0 or errno. Unix: no effect.
    int setNoDelay(bool on);
    int setKeepAlive(int64_t seconds);

    // Fills the endpoints / credentials / TLS info of an established
    // connection (§D.3: Unix endpoints come from the arguments; `listenPath`
    // is the listener's path for accepted Unix connections).
    void describe(SocketEvent& ev, const std::string& listenPath) const;

    bool isUnix() const { return isUnix_; }
    Phase phase() const { return phase_; }

    void onReady(bool readable, bool writable, bool errorOrHangup) override;
    void onTimer() override;
    void onCloseAll() override;

    // --- Main thread ----------------------------------------------------------

    // T7 race of a client connect: 0 pending, 1 the reactor posted the
    // result, 2 the kill handle cancelled it. cancelConnect() returns true
    // iff it won (then nothing will be posted and the caller releases the
    // count); it submits the abort itself.
    bool cancelConnect();

    Conn(const Conn&) = delete;
    Conn& operator=(const Conn&) = delete;

protected:
    Conn();

private:
    struct OutReq {
        std::string bytes;
        size_t offset = 0;
        std::function<void(int)> done;
    };

    // Client connect.
    void connectFailed(int err);
    void connectFailed(const std::string& code, const std::string& message);
    void connected();
    void runHandshake();
    void handshakeDone();
    std::string target() const;

    // Open-phase IO.
    void runIo(bool tryRead, bool tryWrite);
    void serviceReads();
    void serviceWrites();
    void afterIo();
    void applyInterest();
    void flushPending();
    void writeFailed();
    void failOutbound(int err);
    void finishShutdown(int err);
    void enterDraining();
    void drainStep();
    void closeNow();
    void reapRetired();
    void armTimer();
    void fireTimer(int id);
    void timedOut();
    struct BusyScope;
    template <typename F>
    void guarded(F&& f);

    // Fixed at construction.
    bool isUnix_ = false;
    bool isClient_ = false;
    ConnectSpec spec_;
    TransportFactory factory_;
    uint64_t token_ = 0;     // client: the connect task's resume token
    uint64_t gen_ = 0;       // client: heap generation of the connect
    ConnectCallback connectCb_;   // client: report to it instead of a SocketEvent

public:
    std::atomic<int> resolved{0};   // client connect race (cancelConnect)

private:
    // Reactor thread only.
    int fd_ = -1;
    Phase phase_ = Phase::Idle;
    std::unique_ptr<Transport> transport_;
    std::function<void(Conn&, bool)> serverDone_;
    TlsInfo tls_;
    bool hasTls_ = false;

    std::unique_ptr<ConnProtocol> protocol_;
    FaceProtocol* face_ = nullptr;
    std::vector<std::unique_ptr<ConnProtocol>> retired_;
    std::string faceDetachedReason_;

    std::deque<OutReq> outQ_;
    size_t outBytes_ = 0;
    bool aboveLow_ = false;              // outbound reached kLowWatermark (onWritable edge)
    bool shutRequested_ = false;         // a shutdownWrite waits behind outQ_ (or for TLS)
    std::vector<std::function<void(int)>> shutDone_;

    bool readOnWrite_ = false;           // the last read wants writability (TLS)
    bool writeOnRead_ = false;           // the last write/shutdown wants readability (TLS)
    bool readDone_ = false;              // EOF or a read error (transport level)
    bool writeDone_ = false;             // FIN sent, write error, or writing given up
    bool eofSeen_ = false;
    bool closing_ = false;               // closeGraceful requested
    bool discarding_ = false;            // Draining: still discarding input (N8)
    bool aborted_ = false;               // Socket.close / reset / closeAll
    bool aborting_ = false;
    int readErr_ = 0;                    // errno of a failed read (0: none)
    std::string readErrReason_;
    int writeErr_ = 0;
    std::string writeErrReason_;

    bool busy_ = false;                  // inside runIo (protocol callbacks may re-enter)
    bool again_ = false;
    bool againRead_ = false, againWrite_ = false;

    int64_t deadlines_[kMaxTimers] = {};
    std::vector<std::function<void(Conn&)>> closeHooks_;
};

} // namespace Eco::System

#endif // ECO_SYSTEM_SOCKET_CONN_HPP
