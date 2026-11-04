//===- Conn.hpp - One stream connection on the IoReactor ------------------===//
//
// eco/system does all socket IO on the reactor thread (`IoReactor`), and a connected stream socket needs more than
// readiness events: it has to be connected, possibly secured, read only when someone wants data, written in order, and
// closed without losing what is in flight. A `Conn` is that, for one TCP or Unix stream socket.
//
// Three layers make up a connection, and each has its own interface:
//
//   * The transport, a `Transport`, is the byte layer between the fd and the connection. The plain transport is
//     `recv`/`send`; a TLS transport encrypts and decrypts. The `Conn` never knows which it has. Every transport call
//     records in `wantRead`/`wantWrite` which readiness it is waiting for, and the `Conn` watches what the last call
//     asked for rather than the direction of the call, because a TLS transport may need to write in order to read,
//     and the reverse.
//   * The connection, the `Conn`, is an `IoHandler`: it owns the fd, drives the transport from readiness events, keeps
//     the queue of outgoing writes, and runs the connect, close and timer logic.
//   * The protocol, a `ConnProtocol`, is what runs over an open connection and decides what the bytes mean. A `Conn`
//     has one current protocol at a time. It starts as a `FaceProtocol`, which serves the two byte channels (faces) of
//     a `Socket.Connection`. `setProtocol` hands the connection to another protocol, together with any bytes the old
//     one read past its end; this is a hand-off, and the old protocol is retired, kept alive until no queued write can
//     call back into it.
//
// Reading is demand-driven: the `Conn` asks the reactor for read readiness only while the protocol's `wantsRead`
// returns true, so input nobody has asked for stays in the kernel's buffer. Reads and writes that are requested are
// attempted at once, and wait for readiness only when they cannot complete.
//
// A connection moves through the phases of `Conn::Phase`:
//
//   * A client `Conn` is made by `makeClient`, with no fd. `startConnect` builds the address, creates a
//     non-blocking socket, registers it and connects; a connect still in progress waits for writability and then
//     reads SO_ERROR. The transport's handshake follows, under the same deadline. The result is reported exactly once:
//     as a `SocketEvent` of kind `Connected`, or to a `ConnectCallback` when one is set. A failed connect has closed
//     its fd by the time it is reported. A kill races the result through `resolved`: whichever of `cancelConnect` and
//     the reactor changes it first decides, and the loser reports nothing.
//   * A server `Conn` is made by `makeAccepted` over an accepted fd. Once it is registered, `beginServer` runs the
//     transport's handshake under a deadline and reports the outcome to the callback it was given.
//   * An open connection gives the protocol its plaintext, queues its writes, keeps its deadlines and closes it when
//     asked.
//   * `closeGraceful` sends the queued writes and then, unless the write side has already ended, a FIN (for TLS, a
//     close_notify first). It then drains, when there is input to discard or transport output to flush: it discards
//     input until the peer's EOF and flushes what the transport still holds, bounded by the drain deadline.
//     The input is discarded rather than left unread because closing a TCP socket that still has unread input makes
//     the kernel reset the connection instead of ending it with the FIN.
//   * `abort` closes at once. Queued writes fail, and no close_notify is sent.
//
// The `Conn` holds no Elm heap values. What it reports leaves the reactor thread as `ChannelResult`s (stream data,
// through the faces) and `SocketEvent`s (connect results), neither of which holds a heap pointer.
//
// Threads: everything here runs on the reactor thread, except `makeClient`, which runs before the `Conn` is shared
// with the reactor, `cancelConnect`, which touches only `resolved` and submits a command, and the destructor, which
// runs on whichever thread drops the last `shared_ptr` (eco-thread tables hold some). Nothing is locked; the
// protocol callbacks may call back into the `Conn`, and the `Conn` handles that re-entry itself (see `ConnProtocol`).
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

// Windows has no `ssize_t`, which the transport's signatures use.
#ifndef _WIN32
#include <sys/types.h>
#else
#include <cstddef>
typedef std::ptrdiff_t ssize_t;
#endif

namespace Eco::System {

// --- Transport (reactor thread) ----------------------------------------------

/// The byte layer between a connection's fd and the `Conn`: plain `recv`/`send`, or TLS.
///
/// The `Conn` owns its transport and calls it only on the reactor thread. A call that cannot complete returns its
/// "again" or "would block" value and sets `wantRead`/`wantWrite` to the readiness it is waiting for; an
/// implementation must set them on every call, clearing the one it does not need. A call that fails sets `errCode`
/// (an errno name or a TLS error code), `errMessage` and `errNo`. The `Conn` reports `errNo` as the errno and `errCode`
/// in the reason; `errMessage` reaches only the message of a failed connect.
/// An implementation does not own the fd: the `Conn` closes it.
class Transport {
public:
    Transport() = default;
    /// Not copyable (and so not movable): an implementation owns per-connection state such as an `SSL*`, which a
    /// copy would free twice. Transports live behind `std::unique_ptr<Transport>`.
    Transport(const Transport&) = delete;
    Transport& operator=(const Transport&) = delete;
    virtual ~Transport() = default;
    /// Advances the handshake. Returns 0 when it is done, 1 when it must be called again once the readiness in
    /// `wantRead`/`wantWrite` arrives, or a negative value when it failed. The default has no handshake and returns 0.
    virtual int handshake() { return 0; }
    /// Reads up to `n` bytes of application data into `buf`. Returns the number of bytes read (> 0), 0 at the peer's
    /// end of input, -1 when it would block, or -2 on failure.
    virtual ssize_t read(char* buf, size_t n) = 0;
    /// Offers the `n` bytes at `buf`. Returns how many were accepted (>= 0), -1 when it would block, or -2 on failure.
    virtual ssize_t write(const char* buf, size_t n) = 0;
    /// Ends the write direction: for TLS a close_notify and then a TCP FIN, for the plain transport the FIN alone.
    /// Returns 0 when done, 1 when it must be called again, or a negative value on failure.
    virtual int shutdownWrite() = 0;
    /// Returns whether the transport holds output it produced that the socket has not yet taken, such as records
    /// behind an accepted write or a close_notify. While it does, an open or draining `Conn` keeps write interest and
    /// calls `flush` when the socket is writable.
    virtual bool hasPendingWrite() const { return false; }
    /// Sends what `hasPendingWrite` reports. Returns 0 when nothing is left, 1 when it must be called again, or -2 on
    /// failure, after which nothing must be left pending. The default returns 0.
    virtual int flush() { return 0; }
    /// Writes to `out` what the handshake negotiated and returns true, or returns false when there is nothing to
    /// report, as for the plain transport, which is the default.
    virtual bool info(TlsInfo& out) const { (void)out; return false; }

    bool wantRead = false, wantWrite = false;   ///< What the last call needs.
    std::string errCode, errMessage;            ///< Set by a failed call.
    int errNo = 0;                              ///< The errno of the last failure, or 0 for a TLS protocol error.
};

/// Returns a plain transport over `fd`, which it does not own. Writes are sent with `kSendFlags` (MSG_NOSIGNAL where
/// it is defined). On Windows its reads, writes and shutdowns fail with ENOTSUP; the handshake succeeds at once.
std::unique_ptr<Transport> makePlainTransport(int fd);

/// A function that builds the transport of a new connection over `fd`, with `isServer` set for an accepted one.
///
/// It is called on the reactor thread. A null factory, or a null result, means the plain transport. A client `Conn`
/// calls it with `isServer` false once its connect has succeeded.
using TransportFactory = std::function<std::unique_ptr<Transport>(int fd, bool isServer)>;

// --- Client connect parameters ------------------------------------------------

/// What a client connection is to connect to, and the socket options to set on it.
///
/// It is copied out of the Elm heap before the `Conn` is made. The TCP-only members are ignored for a Unix socket.
struct ConnectSpec {
    bool isUnix = false;
    std::string address;        ///< For TCP, an address as text, as `inetToSockaddr` accepts it; for Unix, the path.
    int64_t port = 0;           // TCP
    int64_t timeoutMs = 0;      ///< Milliseconds for the connect and the handshake together; 0 or less for no limit.
    bool noDelay = false;       // TCP
    int64_t keepAliveSec = 0;   ///< TCP keep-alive idle time in seconds; 0 or less leaves keep-alive off.
};

// --- Protocols ------------------------------------------------------------------

class Conn;

/// What runs over an open connection and decides what its bytes mean.
///
/// A `Conn` owns its current protocol and calls it on the reactor thread. An implementation must not touch the Elm
/// heap. The `Conn` calls the protocol from inside its own IO loop, and a callback may call any `Conn` method. IO that
/// a callback asks for (`write`, `shutdownWrite`, `updateInterest`, `closeGraceful`) is carried out after the callback
/// returns, so a callback never runs inside a second read of the same connection. `abort`, `cancelWrites` and
/// `setProtocol` take effect at once; `setProtocol` calls the new protocol before it returns. A protocol replaced by
/// `setProtocol` is kept alive at least until its queued writes and pending shutdown callbacks have run, so their
/// `done` callbacks may refer to it.
class ConnProtocol {
public:
    virtual ~ConnProtocol() = default;
    /// Reports that the connection is open: called when a client connection reporting through a `SocketEvent`
    /// completes its handshake, and by `setProtocol` on an open connection, before any leftover bytes. It is not
    /// called for an accepted connection or a connect reported to a `ConnectCallback` until a protocol is installed
    /// with `setProtocol`. The default does nothing.
    virtual void onOpen(Conn& /*c*/) {}
    /// Delivers plaintext read from the transport, only while `wantsRead` returns true, or the leftover bytes of a
    /// hand-off, whatever `wantsRead` returns. `bytes` is valid only until the call returns.
    virtual void onData(Conn& c, std::string_view bytes) = 0;
    /// Reports the peer's end of input. Called at most once, and no data follows it.
    virtual void onEof(Conn& c) = 0;
    /// Reports a failure with its errno `err`. `code` is "read <CODE>" for a failed read, after which reading is
    /// over, or "write <CODE>" for a failed write or flush, after which writing is over and the queued writes have
    /// already been failed through their `done`. `<CODE>` is the transport's error code, or the errno name. When the
    /// reactor cannot watch the fd, the connection closes; the read error is reported, with the reactor's errno, unless
    /// reading had already ended, and, while the connection is still open, a write error is reported unless writing
    /// had already ended.
    virtual void onError(Conn& c, int err, const std::string& code) = 0;
    /// Reports that `Conn::outbound` has fallen below `Conn::kLowWatermark` after having reached it. The default does
    /// nothing.
    virtual void onWritable(Conn& /*c*/) {}
    /// Reports that the deadline set with `Conn::setDeadline` for `timerId` has passed. Deadlines due together are
    /// reported in deadline order, ties by id; one set again by an earlier callback of the same firing is skipped.
    /// Only an open connection reports them, and `Conn::kTimerDrain` is not reported once `Conn::closeGraceful` has
    /// been called. The default does nothing.
    virtual void onTimer(Conn& /*c*/, int /*timerId*/) {}
    /// Tells the protocol that the connection is being torn down now, by `Conn::abort`: it must fail everything it
    /// has pending. It cannot start IO from here. The `Conn` closes the fd after it returns. Called at most once.
    virtual void onCloseAll(Conn& c) = 0;
    /// Returns whether the protocol wants data now. The `Conn` has read interest, and reads, only while this is true.
    virtual bool wantsRead() const = 0;
};

class FaceProtocol;

// --- The connection ----------------------------------------------------------

/// One connected stream socket, from the connect or accept until it is closed, as the file comment describes.
///
/// A `Conn` has identity. It is made only by `makeClient` or `makeAccepted` and is always held by `std::shared_ptr`;
/// the reactor holds one while it is registered. It cannot be copied. It owns its fd from the moment it has one, and
/// closes it when it closes; the destructor closes the fd only for a `Conn` that was never registered with the
/// reactor. Apart from `makeClient`, `cancelConnect` and the destructor, which runs on whichever thread drops the last
/// reference, every member must be called on the reactor thread.
class Conn : public IoHandler {
public:
    /// Where a connection is in its life. Idle: a client not yet started. Connecting: a client's connect is in
    /// progress. Handshaking: the transport's handshake is running. Open: the protocol has the connection. Draining:
    /// after `closeGraceful`, the write side has ended, and input is being discarded or transport output flushed, or
    /// both. Closed: final; the fd is gone.
    enum class Phase : uint8_t { Idle, Connecting, Handshaking, Open, Draining, Closed };

    // Timer ids for `setDeadline`. All share the reactor's one timer per handler: the earliest deadline is armed, and
    // the ids that are due when it fires are dispatched, except one set again by an earlier callback of that firing.
    // The `Conn` itself uses only the first two. The others are free for protocols to use as they choose; their names
    // say what they are meant for, and the `Conn` gives them no meaning.

    /// The deadline of the connect and the transport handshake, used by the `Conn`.
    static constexpr int kTimerConnect = 0;
    /// The deadline of `closeGraceful`, used by the `Conn`.
    static constexpr int kTimerDrain = 1;
    /// A protocol timer id, named for an idle or keep-alive deadline.
    static constexpr int kTimerIdle = 2;
    /// A protocol timer id, named for a deadline on receiving headers.
    static constexpr int kTimerHeaders = 3;
    /// A protocol timer id, named for a deadline on a whole request.
    static constexpr int kTimerRequest = 4;
    /// A protocol timer id, named for a heartbeat deadline.
    static constexpr int kTimerHeartbeat = 5;
    /// A protocol timer id, named for a deadline on the answer to a heartbeat.
    static constexpr int kTimerPong = 6;
    /// A protocol timer id, named for a closing-handshake deadline.
    static constexpr int kTimerCloseHandshake = 7;
    /// The number of timer ids; valid ids are 0 to `kMaxTimers - 1`.
    static constexpr int kMaxTimers = 8;

    /// The number of queued outbound bytes below which `ConnProtocol::onWritable` is reported, once the queue has
    /// reached it.
    static constexpr size_t kLowWatermark = 64 * 1024;
    /// The drain time in milliseconds of the stream faces' final close, and the one `closeGraceful` uses when given
    /// none.
    static constexpr int64_t kFaceDrainMs = 2000;

    /// Returns a new client connection to `spec`, not yet started, whose protocol is a `FaceProtocol`. `factory`
    /// builds its transport. `token` and `gen` are the resume token and heap generation the `Connected` event
    /// carries. May be called off the reactor thread, before the `Conn` is shared with it.
    static std::shared_ptr<Conn> makeClient(ConnectSpec spec, TransportFactory factory,
                                            uint64_t token, uint64_t gen);
    /// Returns a server connection over the accepted `fd`, which it owns from now on, using transport `t`, or the
    /// plain transport when `t` is null. Its protocol is a `FaceProtocol` until `setProtocol` replaces it.
    static std::shared_ptr<Conn> makeAccepted(int fd, bool isUnix, std::unique_ptr<Transport> t);

    ~Conn() override;

    // --- Reactor thread -------------------------------------------------------

    /// Starts a client connection: creates the socket, sets the TCP options of the spec, registers it and connects.
    /// The result is reported once, as the type's comment describes. Does nothing but mark the connection Closed if
    /// `cancelConnect` has already won.
    void startConnect();
    /// A function that receives a client's connect result in place of a `Connected` event: whether it succeeded, and
    /// on failure the error code and message. On success the connection is Open with its `FaceProtocol`, and
    /// `ConnProtocol::onOpen` has not been called; on failure the connection is already closed.
    using ConnectCallback =
        std::function<void(Conn&, bool ok, const std::string& code, const std::string& message)>;
    /// Makes `cb` receive the connect result, which it then does at most once. Must be called before `startConnect`.
    void setConnectCallback(ConnectCallback cb) { connectCb_ = std::move(cb); }
    /// Runs the transport handshake of a server connection and calls `done` with the outcome, false on failure or
    /// when `deadlineMs` (monotonic milliseconds; 0 for none) passes. The fd must already be registered. With the
    /// plain transport `done(*this, true)` is called before this returns. On failure the `Conn` does not close
    /// itself; that is left to `done`. `done` is not called if the connection is aborted first.
    void beginServer(int64_t deadlineMs, std::function<void(Conn&, bool ok)> done);

    /// Makes `p` the current protocol, retiring the old one. If `p` is a `FaceProtocol` it becomes `face()`. On an
    /// open connection that is not closing, `p->onOpen` is called, then `p->onData(leftover)` if `leftover` is not
    /// empty and `p` is still current, and then a read is attempted, which also reaches input a TLS transport already
    /// holds. Otherwise `p` is installed, nothing is called and `leftover` is discarded.
    void setProtocol(std::unique_ptr<ConnProtocol> p, std::string leftover);
    /// Returns the current protocol, or null if none is installed. It is valid until the next `setProtocol`.
    ConnProtocol* protocol() const { return protocol_.get(); }

    /// Queues `bytes` behind earlier writes and attempts to send them. `done`, which may be null, receives 0 once the
    /// transport has accepted all of them, which may be before this returns, or an errno if the write fails or is
    /// cancelled. If the connection is not open, or its write side has ended, or a shutdown or graceful close has been
    /// requested, `done` is called before this returns, with the recorded write error, or ECANCELED when there is none
    /// or the connection was aborted.
    void write(std::string bytes, std::function<void(int err)> done);
    /// Returns the number of queued bytes the transport has not yet accepted.
    size_t outbound() const { return outBytes_; }
    /// Re-evaluates read and write interest after the protocol's wants have changed, attempting the IO at once.
    /// Attempting the read is what delivers input a TLS transport holds and no fd event would announce.
    void updateInterest();
    /// Sets the deadline for `timerId` to monotonic `monoMs`, or cancels it when `monoMs` is 0 or less. An id outside
    /// 0 to `kMaxTimers - 1` is ignored.
    void setDeadline(int timerId, int64_t monoMs);
    /// Returns the deadline set for `timerId`, or 0 when none is set or the id is out of range.
    int64_t deadline(int timerId) const;
    /// Requests the end of the write direction after the queued writes (for TLS a close_notify, then the FIN).
    /// `done`, which may be null, receives 0 once it is sent or an errno on failure or cancellation. If the connection
    /// is not open or is being aborted, `done` receives ECANCELED at once; if the FIN has already been sent, it
    /// receives 0 at once.
    void shutdownWrite(std::function<void(int err)> done = nullptr);
    /// Fails every queued write and pending `shutdownWrite` callback with `err`. A requested shutdown stays
    /// requested, and proceeds now the queue is empty.
    void cancelWrites(int err);
    /// Starts an orderly close of an open connection: the queued writes, then the FIN, then draining, as the file
    /// comment describes. The connection closes when the drain ends, or when `drainMs` passes (`kFaceDrainMs` when
    /// `drainMs` is 0 or less), counted from this call and covering the writes too. The protocol receives no more data.
    /// Does nothing if the connection is not open, is already closing, or is being aborted.
    void closeGraceful(int64_t drainMs);
    /// Closes the connection now. `reset` asks for a TCP reset (SO_LINGER with a zero timeout); it has no effect on a
    /// Unix socket. An open or draining connection calls `ConnProtocol::onCloseAll`, fails the queued writes with
    /// ECANCELED, and closes the fd, sending no close_notify; `reset` applies only here. A client still connecting or
    /// handshaking fails its connect with ECANCELED, reported unless `cancelConnect` won. A server still handshaking
    /// closes without calling the `beginServer` callback. An Idle client is marked Closed and nothing is reported.
    void abort(bool reset);
    /// Returns what the TLS handshake negotiated, or null for a transport with nothing to report or before the
    /// handshake has ended. The pointer is valid as long as the `Conn`.
    const TlsInfo* tlsInfo() const { return hasTls_ ? &tls_ : nullptr; }
    /// Makes `hook` run on the reactor thread when the connection closes its fd, or at once if it is already Closed.
    void addCloseHook(std::function<void(Conn&)> hook);

    // State the protocols read.

    /// Returns whether the peer's end of input has been read.
    bool eofSeen() const { return eofSeen_; }
    /// Returns the errno of a failed read, or 0 when there was none.
    int readError() const { return readErr_; }
    /// Returns the reason of a failed read ("read <CODE>"), or an empty string when there was none.
    const std::string& readErrorReason() const { return readErrReason_; }
    /// Returns the errno recorded when the write direction failed, or 0 when none was recorded.
    int writeError() const { return writeErr_; }
    /// Returns the reason of the recorded write error ("write <CODE>"), or an empty string when there was none.
    const std::string& writeErrorReason() const { return writeErrReason_; }
    /// Returns whether the write direction has ended: the FIN was sent, writing failed, or it was given up.
    bool writeEnded() const { return writeDone_; }
    /// Returns whether `abort` has been called.
    bool aborted() const { return aborted_; }
    /// Returns whether `closeGraceful` has been called.
    bool closing() const { return closing_; }

    // Face requests. Each is forwarded to the `FaceProtocol` while it is the current protocol, which answers it with
    // one `ChannelResult` for `channelId` and `token`. Once another protocol has taken over, a request is answered at
    // once with ECANCELED and the face-detached reason, "socket closed" unless `setFaceDetachedReason` changed it.

    /// Asks for up to `maxBytes` bytes from the read face.
    void reqRead(uint64_t channelId, uint64_t token, size_t maxBytes);
    /// Asks for `bytes` to be written through the write face.
    void reqWrite(uint64_t channelId, uint64_t token, std::string bytes);
    /// Asks for the write face to be closed: a graceful half-close.
    void reqCloseWrite(uint64_t channelId, uint64_t token);
    /// Tells the read face that its reader is done, after the end of input.
    void reqCloseRead(uint64_t channelId, uint64_t token);
    /// Abandons reading on behalf of a read face that is cancelled or dropped. No SHUT_RD is sent. Does nothing once
    /// another protocol has taken over.
    void readFaceShutdown();
    /// Fails the queued writes and sends the FIN on behalf of a write face that is cancelled or dropped. Does nothing
    /// once another protocol has taken over.
    void writeFaceShutdown();
    /// Returns the `FaceProtocol` while it is the current protocol, else null. Valid until the next `setProtocol`.
    FaceProtocol* face() const { return face_; }
    /// Sets the reason face requests fail with once another protocol has taken over.
    void setFaceDetachedReason(std::string reason) { faceDetachedReason_ = std::move(reason); }

    /// Sets or clears TCP_NODELAY. Returns 0 or the errno of the failure. Returns 0 without effect for a Unix socket
    /// or a connection with no fd, and ENOTSUP on Windows.
    int setNoDelay(bool on);
    /// Turns TCP keep-alive on with an idle time of `seconds` (clamped to the range of `int`), or off when `seconds`
    /// is 0 or less. Returns 0 or the errno of the first failing option. Returns 0 without effect for a Unix socket or
    /// a connection with no fd, and ENOTSUP on Windows.
    int setKeepAlive(int64_t seconds);

    /// Writes the endpoints, peer credentials and TLS details of an established connection into `ev`. For TCP the
    /// endpoints come from the socket. For Unix they come from the arguments instead: a client's remote endpoint is
    /// the path it connected to and its local one is empty, and an accepted connection's local endpoint is
    /// `listenPath`, the listener's path, and its remote one empty. Peer credentials are filled in for Unix sockets
    /// on Linux and macOS, when the system provides them. An endpoint whose system call fails is left as it was.
    void describe(SocketEvent& ev, const std::string& listenPath) const;

    /// Returns whether this is a Unix socket.
    bool isUnix() const { return isUnix_; }
    /// Returns the current phase.
    Phase phase() const { return phase_; }

    void onReady(bool readable, bool writable, bool errorOrHangup) override;
    void onTimer() override;
    /// Aborts the connection without calling the `beginServer` callback, and closes the fd.
    void onCloseAll() override;

    // --- Off the reactor thread -------------------------------------------------

    /// Tries to cancel a client connect, from any thread. Returns true if it won the race on `resolved`, in which case
    /// no result will be reported, neither as a `Connected` event nor to the `ConnectCallback`, and the `Conn` is
    /// aborted through a submitted reactor command. Returns false if the result has already been claimed for
    /// reporting.
    bool cancelConnect();

    Conn(const Conn&) = delete;
    Conn& operator=(const Conn&) = delete;

protected:
    /// Creates a connection in the Idle phase with no fd, whose protocol is a new `FaceProtocol`.
    Conn();

private:
    /// One queued write: the bytes, how many of them the transport has accepted, and whom to tell.
    struct OutReq {
        std::string bytes;
        size_t offset = 0;
        std::function<void(int)> done;
    };

    // Client connect.

    /// Fails the connect with errno `err`, with the message "connect <CODE> <target>".
    void connectFailed(int err);
    /// Closes the connection and reports a failed connect with `code` and `message`, unless this is not a client or
    /// `cancelConnect` has won.
    void connectFailed(const std::string& code, const std::string& message);
    /// Installs the transport once the socket is connected, and starts the handshake.
    void connected();
    /// Advances the handshake, waiting for the readiness it asks for, and finishes or fails it.
    void runHandshake();
    /// Opens the connection after the handshake and reports the result to the listener, the connect callback or a
    /// `Connected` event. A client whose connect was cancelled meanwhile is aborted instead.
    void handshakeDone();
    /// Returns the connect target for messages: the path, or "address:port".
    std::string target() const;

    // Open-phase IO.

    /// Runs one IO step of an open connection: flushes the transport when `tryWrite`, reads while the protocol wants
    /// data, writes the queue and then any requested FIN, and repeats while callbacks asked for more. `tryRead` and
    /// `tryWrite` say which directions are ready or were requested. Called while busy, it only records the request.
    void runIo(bool tryRead, bool tryWrite);
    /// Reads and delivers to the protocol until it stops wanting data, the read would block, or input ends or fails.
    void serviceReads();
    /// Sends queued writes in order, completing each one's `done`, and then the requested shutdown.
    void serviceWrites();
    /// Starts draining a closing connection whose writes are done, or else re-applies interest.
    void afterIo();
    /// Asks the reactor for the interest the current state needs. If it cannot, fails both directions and closes.
    void applyInterest();
    /// Flushes the transport's pending output; a failure ends the write direction.
    void flushPending();
    /// Ends the write direction after a failed write: records the error, fails the queue and reports it.
    void writeFailed();
    /// Fails every queued write, then every pending shutdown callback, with `err`.
    void failOutbound(int err);
    /// Calls every pending shutdown callback with `err`.
    void finishShutdown(int err);
    /// Enters the Draining phase, or closes at once when there is neither input to discard nor output to flush.
    void enterDraining();
    /// Flushes and discards what it can without blocking, and closes when neither is left.
    void drainStep();
    /// Removes the handler from the reactor, closes the fd, fails what is still queued with ECANCELED and runs the
    /// close hooks.
    void closeNow();
    /// Destroys the retired protocols once nothing queued can call them, and never while a callback is running.
    void reapRetired();
    /// Arms the reactor timer for the earliest deadline set, if the `Conn` is registered.
    void armTimer();
    /// Acts on the deadline `id` according to the phase.
    void fireTimer(int id);
    /// Fails a connect or server handshake whose deadline has passed.
    void timedOut();
    struct BusyScope;
    /// Calls `f`, which calls the protocol, as one step: IO requested meanwhile runs after it returns. Called while
    /// already busy, it just calls `f`.
    template <typename F>
    void guarded(F&& f);

    // Fixed at construction.
    bool isUnix_ = false;
    bool isClient_ = false;
    ConnectSpec spec_;
    TransportFactory factory_;
    uint64_t token_ = 0;     // client: the connect task's resume token
    uint64_t gen_ = 0;       // client: heap generation of the connect

    // Set by `setConnectCallback`; moved out when the result is reported.
    ConnectCallback connectCb_;   // client: report to it instead of a SocketEvent

public:
    /// Which side claimed a client connect's result: 0 neither yet, 1 the reactor, which will report it, 2
    /// `cancelConnect`. Each side changes it only from 0, by compare-and-exchange.
    std::atomic<int> resolved{0};

private:
    // Reactor thread only.
    int fd_ = -1;
    Phase phase_ = Phase::Idle;
    std::unique_ptr<Transport> transport_;
    std::function<void(Conn&, bool)> serverDone_;
    TlsInfo tls_;
    bool hasTls_ = false;

    std::unique_ptr<ConnProtocol> protocol_;
    FaceProtocol* face_ = nullptr;   // protocol_ when it is a FaceProtocol, else null; owned through protocol_
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
    bool discarding_ = false;            // Draining: still discarding input
    bool aborted_ = false;               // abort called (also from onCloseAll)
    bool aborting_ = false;              // abort is tearing an open or draining connection down
    int readErr_ = 0;                    // errno of a failed read (0: none)
    std::string readErrReason_;
    int writeErr_ = 0;
    std::string writeErrReason_;

    bool busy_ = false;                  // inside runIo or a guarded step: IO requests are deferred
    bool again_ = false;                 // a deferred IO request is waiting
    bool againRead_ = false, againWrite_ = false;   // the directions it asked for

    int64_t deadlines_[kMaxTimers] = {};   // monotonic ms per timer id; 0: none
    std::vector<std::function<void(Conn&)>> closeHooks_;
};

} // namespace Eco::System

#endif // ECO_SYSTEM_SOCKET_CONN_HPP
