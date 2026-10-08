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
//   * open: the faces queue reads/writes/closes; final close when both
//     directions are done (Draining first, for at most 2 s: discard input
//     if the read face was cancelled before EOF, N8, and flush what the
//     transport still holds, e.g. a TLS close_notify and its SHUT_WR);
//     abort() (Socket.close) / reset close at once (no close_notify).
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

// --- The connection ----------------------------------------------------------

class Conn final : public IoHandler {
public:
    enum class Phase : uint8_t { Idle, Connecting, Handshaking, Open, Draining, Closed };

    // Main thread: a client connection for resume token `token` (the
    // Connected event carries it) of heap generation `gen`.
    static std::shared_ptr<Conn> makeClient(ConnectSpec spec, TransportFactory factory,
                                            uint64_t token, uint64_t gen);
    // Reactor thread: a connection over an accepted fd (owned from now on).
    static std::shared_ptr<Conn> makeAccepted(int fd, bool isUnix, std::unique_ptr<Transport> t);

    ~Conn() override;

    // --- Reactor thread -------------------------------------------------------

    // Client: create the socket and connect (§3.3.3 "Connect").
    void startConnect();
    // Server: the fd is registered (IoReactor::add); run the transport
    // handshake until done (deadline: monotonic ms, 0 none), then call
    // done(*this, ok). For the plain transport done(true) is called at once.
    void beginServer(int64_t deadlineMs, std::function<void(Conn&, bool ok)> done);

    // Face requests (ConnChannel.cpp): one ChannelResult each.
    void reqRead(uint64_t channelId, uint64_t token, size_t maxBytes);
    void reqWrite(uint64_t channelId, uint64_t token, std::string bytes);
    void reqCloseWrite(uint64_t channelId, uint64_t token);   // graceful half-close
    void reqCloseRead(uint64_t channelId, uint64_t token);    // the reader is done (EOF seen)
    void readFaceShutdown();    // cancelReadable / face dropped: abandon reading (no SHUT_RD)
    void writeFaceShutdown();   // cancelWritable / face dropped: fail queued writes, SHUT_WR

    // Socket.close (reset = false) / Socket.reset (reset = true, TCP: SO_LINGER {1,0}).
    void abort(bool reset);

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

private:
    Conn() = default;

    struct ReadReq {
        uint64_t channelId;
        uint64_t token;
        size_t max;
    };
    struct WriteReq {
        uint64_t channelId;
        uint64_t token;
        std::string bytes;
        size_t offset = 0;
    };

    // Client connect.
    void connectFailed(int err);
    void connectFailed(const std::string& code, const std::string& message);
    void connected();
    void runHandshake();
    void handshakeDone();
    std::string target() const;

    // Open-phase IO.
    void serviceReads();
    void serviceWrites();
    void afterIo();
    void updateInterest();
    void flushPending();
    void drainStep();
    void closeNow();

    void postRead(const ReadReq& r, ChannelResult res);
    void failReads(int err, const std::string& reason);
    void failWrites(int err, const std::string& reason);
    void postClose(uint64_t channelId, uint64_t token, int err, const std::string& reason);
    void readResultForLateRequest(ChannelResult& r) const;
    void writeResultForLateRequest(ChannelResult& r) const;

    // Fixed at construction.
    bool isUnix_ = false;
    bool isClient_ = false;
    ConnectSpec spec_;
    TransportFactory factory_;
    uint64_t token_ = 0;     // client: the connect task's resume token
    uint64_t gen_ = 0;       // client: heap generation of the connect

public:
    std::atomic<int> resolved{0};   // client connect race (cancelConnect)

private:
    // Reactor thread only.
    int fd_ = -1;
    Phase phase_ = Phase::Idle;
    std::unique_ptr<Transport> transport_;
    std::function<void(Conn&, bool)> serverDone_;

    std::deque<ReadReq> readReqs_;
    std::deque<WriteReq> writeQ_;
    bool closePending_ = false;          // write face close requested
    uint64_t closeChannel_ = 0, closeToken_ = 0;
    bool readOnWrite_ = false;           // the last read wants writability (TLS)
    bool writeOnRead_ = false;           // the last write/shutdown wants readability (TLS)
    bool readDone_ = false;              // EOF, read error, or the read face is done
    bool writeDone_ = false;             // FIN sent, write error, or the write face is done
    bool eofSeen_ = false;
    bool readAbandoned_ = false;         // read face shut down before EOF
    bool discarding_ = false;            // Draining: still discarding input (N8)
    bool aborted_ = false;               // Socket.close / reset / closeAll
    int readErr_ = 0;                    // errno of a failed read (0: none)
    std::string readErrReason_;
    int writeErr_ = 0;
    std::string writeErrReason_;
};

} // namespace Eco::System

#endif // ECO_SYSTEM_SOCKET_CONN_HPP
