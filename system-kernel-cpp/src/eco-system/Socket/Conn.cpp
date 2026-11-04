//===- Conn.cpp - One stream connection on the IoReactor ------------------===//
//
// Re-entry. Protocol callbacks may call back into the Conn, so the IO loop marks the Conn busy (`busy_`, set by
// `BusyScope`) while it runs. A request for IO that arrives while busy only sets `again_` and the directions it wants
// (`againRead_`, `againWrite_`); `runIo` loops once more for them, and `guarded` runs them after a single callback
// made outside the loop. Interest is applied only once the Conn is no longer busy (`afterIo`).
//
// Read buffers. Data reaches `onData` as a view into a reactor-thread buffer, which is reused by the next read. A
// callback on one Conn may drive another Conn (a write or `updateInterest` on it reads too), so there is one buffer
// per nesting depth of `serviceReads` (`g_readDepth`, `readBuffer`) and a view is never overwritten while it is
// still in use.
//
//===----------------------------------------------------------------------===//

#include "eco-system/Socket/Conn.hpp"

#include "eco-system/Core/SocketUtil.hpp"
#include "eco-system/Socket/FaceProtocol.hpp"

#include <algorithm>
#include <cerrno>
#include <cstring>
#include <utility>
#include <vector>

#ifndef _WIN32
#include <netinet/in.h>
#include <netinet/tcp.h>
#include <sys/socket.h>
#include <sys/un.h>
#include <unistd.h>
#if defined(__APPLE__)
#include <sys/ucred.h>
#endif
#endif

namespace Eco::System {

namespace {

// The size in bytes of one read, and of each read buffer.
constexpr size_t kChunk = 64 * 1024;
// The default face-detached reason, the one face requests fail with once another protocol has the connection.
constexpr const char* kSocketClosed = "socket closed";

// Returns the reactor thread's buffer of `kChunk` bytes for input that is read only to be discarded.
char* scratch() {
    thread_local std::vector<char> buf(kChunk);   // reactor thread
    return buf.data();
}

// How many calls of serviceReads are on the reactor thread's stack.
thread_local int g_readDepth = 0;

// Returns the reactor thread's read buffer of `kChunk` bytes for nesting depth `depth`, creating it if needed. The
// buffer is not freed or moved when deeper ones are created.
char* readBuffer(int depth) {
    thread_local std::vector<std::vector<char>> bufs;   // reactor thread
    while (bufs.size() <= static_cast<size_t>(depth)) bufs.emplace_back(kChunk);
    return bufs[static_cast<size_t>(depth)].data();
}

// Counts one level of serviceReads nesting for the lifetime of the object.
struct ReadDepth {
    ReadDepth() { ++g_readDepth; }
    ~ReadDepth() { --g_readDepth; }
    ReadDepth(const ReadDepth&) = delete;
    ReadDepth& operator=(const ReadDepth&) = delete;
};

// Returns the shared reactor.
IoReactor& reactor() { return IoReactor::instance(); }

#ifndef _WIN32

// --- The plain transport -------------------------------------------------------

// The transport that is the socket itself: recv, send and shutdown, retried on EINTR.
class PlainTransport final : public Transport {
public:
    // Creates a transport over `fd`, which it uses but does not own.
    explicit PlainTransport(int fd) : fd_(fd) {}

    ssize_t read(char* buf, size_t n) override {
        wantRead = wantWrite = false;
        for (;;) {
            ssize_t got = ::recv(fd_, buf, n, 0);
            if (got >= 0) return got;
            int e = errno;
            if (e == EINTR) continue;
            if (e == EAGAIN || e == EWOULDBLOCK) {
                wantRead = true;
                return -1;
            }
            return fail(e);
        }
    }

    ssize_t write(const char* buf, size_t n) override {
        wantRead = wantWrite = false;
        for (;;) {
            ssize_t put = ::send(fd_, buf, n, kSendFlags);
            if (put >= 0) return put;
            int e = errno;
            if (e == EINTR) continue;
            if (e == EAGAIN || e == EWOULDBLOCK) {
                wantWrite = true;
                return -1;
            }
            return fail(e);
        }
    }

    int shutdownWrite() override {
        wantRead = wantWrite = false;
        if (::shutdown(fd_, SHUT_WR) == 0) return 0;
        int e = errno;
        (void)fail(e);
        return -1;
    }

private:
    // Records errno `e` as the failure and returns -2.
    ssize_t fail(int e) {
        errNo = e;
        errCode = errnoName(e);
        errMessage = std::strerror(e);
        return -2;
    }

    int fd_;
};

#else // _WIN32: never reached (the kernels fail ENOTSUP first)

// A transport whose reads, writes and shutdowns fail with ENOTSUP; the handshake succeeds at once.
class PlainTransport final : public Transport {
public:
    // Creates the transport; the fd is ignored.
    explicit PlainTransport(int) {}
    ssize_t read(char*, size_t) override { return fail(); }
    ssize_t write(const char*, size_t) override { return fail(); }
    int shutdownWrite() override { return static_cast<int>(fail()); }

private:
    // Records ENOTSUP as the failure and returns -2.
    ssize_t fail() {
        errNo = ENOTSUP;
        errCode = "ENOTSUP";
        errMessage = "not supported on Windows yet";
        return -2;
    }
};

#endif

// Closes `fd` if it is not negative, ignoring failure. Does nothing on Windows.
void closeFd(int fd) {
#ifndef _WIN32
    if (fd >= 0) (void)::close(fd);
#else
    (void)fd;
#endif
}

} // namespace

std::unique_ptr<Transport> makePlainTransport(int fd) {
    return std::make_unique<PlainTransport>(fd);
}

// ---------------------------------------------------------------------------
// Construction
// ---------------------------------------------------------------------------

Conn::Conn() : faceDetachedReason_(kSocketClosed) {
    auto f = std::make_unique<FaceProtocol>();
    face_ = f.get();
    protocol_ = std::move(f);
}

std::shared_ptr<Conn> Conn::makeClient(ConnectSpec spec, TransportFactory factory, uint64_t token,
                                       uint64_t gen) {
    std::shared_ptr<Conn> c(new Conn());
    c->isClient_ = true;
    c->isUnix_ = spec.isUnix;
    c->spec_ = std::move(spec);
    c->factory_ = std::move(factory);
    c->token_ = token;
    c->gen_ = gen;
    return c;
}

std::shared_ptr<Conn> Conn::makeAccepted(int fd, bool isUnix, std::unique_ptr<Transport> t) {
    std::shared_ptr<Conn> c(new Conn());
    c->isClient_ = false;
    c->isUnix_ = isUnix;
    c->fd_ = fd;
    c->transport_ = t ? std::move(t) : makePlainTransport(fd);
    return c;
}

Conn::~Conn() {
    // Only reachable with an open fd if the Conn never reached the reactor
    // table (a registered one is kept alive by its slot).
    if (fd_ >= 0 && key() == 0) closeFd(fd_);
}

// Marks the Conn busy for the lifetime of the object, and restores the previous state after it.
struct Conn::BusyScope {
    explicit BusyScope(Conn& c) : c_(c), prev_(c.busy_) { c.busy_ = true; }
    ~BusyScope() { c_.busy_ = prev_; }
    BusyScope(const BusyScope&) = delete;
    BusyScope& operator=(const BusyScope&) = delete;
    Conn& c_;
    bool prev_;
};

template <typename F>
void Conn::guarded(F&& f) {
    if (busy_) {
        f();
        return;
    }
    {
        BusyScope b(*this);
        again_ = againRead_ = againWrite_ = false;
        f();
    }
    bool r = againRead_, w = againWrite_;
    again_ = againRead_ = againWrite_ = false;
    if (phase_ == Phase::Open) runIo(r, w);
}

// ---------------------------------------------------------------------------
// Client connect
// ---------------------------------------------------------------------------

std::string Conn::target() const {
    if (isUnix_) return spec_.address;
    return spec_.address + ":" + std::to_string(spec_.port);
}

void Conn::startConnect() {
    if (resolved.load(std::memory_order_acquire) != 0) {   // killed before it started
        phase_ = Phase::Closed;
        return;
    }
#ifdef _WIN32
    connectFailed(ENOTSUP);
#else
    SockAddr sa;
    int e = isUnix_ ? unixSockaddr(spec_.address, sa) : inetToSockaddr(spec_.address, spec_.port, sa);
    if (e != 0) {
        connectFailed(e);
        return;
    }
    fd_ = socketCloexec(sa.family(), SOCK_STREAM, 0, /*nonBlocking=*/true, &e);
    if (fd_ < 0) {
        connectFailed(e);
        return;
    }
    if (!isUnix_) {
        if (spec_.noDelay) (void)setNoDelay(true);
        if (spec_.keepAliveSec > 0) (void)setKeepAlive(spec_.keepAliveSec);
    }
    auto self = std::static_pointer_cast<Conn>(shared_from_this());
    if (reactor().add(self, fd_) == 0) {
        connectFailed(EINVAL);
        return;
    }
    if (spec_.timeoutMs > 0) setDeadline(kTimerConnect, reactor().nowMs() + spec_.timeoutMs);
    int rc = ::connect(fd_, sa.get(), sa.len);
    if (rc == 0) {
        connected();
        return;
    }
    e = errno;
    if (e == EINPROGRESS || e == EINTR) {   // EINTR: the connect goes on asynchronously
        phase_ = Phase::Connecting;
        int ie = reactor().setInterest(key(), false, true);
        if (ie != 0) connectFailed(ie);
        return;
    }
    // Unix: EAGAIN = the listener's backlog is full; reported as is.
    // ENOTSOCK = the path is a file that is not a socket (macOS); reported as
    // Linux reports it, ECONNREFUSED: nobody listens there.
    if (isUnix_ && e == ENOTSOCK) e = ECONNREFUSED;
    connectFailed(e);
#endif
}

void Conn::connectFailed(int err) {
    connectFailed(errnoName(err), std::string("connect ") + errnoName(err) + " " + target());
}

void Conn::connectFailed(const std::string& code, const std::string& message) {
    int expected = 0;
    bool post = isClient_ && resolved.compare_exchange_strong(expected, 1);
    readDone_ = writeDone_ = true;
    closeNow();
    if (!post) return;   // killed: the kill handle released the count
    if (connectCb_) {
        auto cb = std::move(connectCb_);
        connectCb_ = nullptr;
        cb(*this, false, code, message);
        return;
    }
    SocketEvent ev;
    ev.kind = SocketEvent::Kind::Connected;
    ev.gen = gen_;
    ev.token = token_;
    ev.failed = true;
    ev.code = code;
    ev.message = message;
    postSocketEvent(std::move(ev));
}

void Conn::connected() {
    if (factory_) transport_ = factory_(fd_, false);
    if (!transport_) transport_ = makePlainTransport(fd_);
    phase_ = Phase::Handshaking;
    runHandshake();
}

void Conn::runHandshake() {
    int rc = transport_->handshake();
    if (rc == 0) {
        handshakeDone();
        return;
    }
    if (rc > 0) {
        int e = reactor().setInterest(key(), transport_->wantRead, transport_->wantWrite);
        if (e == 0) return;
        transport_->errCode = errnoName(e);
        transport_->errMessage = std::strerror(e);
    }
    // Failed.
    if (isClient_) {
        std::string code = transport_->errCode.empty() ? "EPROTO" : transport_->errCode;
        std::string msg = transport_->errMessage.empty() ? code : transport_->errMessage;
        connectFailed(code, msg);
        return;
    }
    auto done = std::move(serverDone_);
    serverDone_ = nullptr;
    if (done) done(*this, false);   // the listener closes it
}

void Conn::handshakeDone() {
    setDeadline(kTimerConnect, 0);
    (void)reactor().setInterest(key(), false, false);
    phase_ = Phase::Open;
    hasTls_ = transport_ && transport_->info(tls_);
    if (!isClient_) {
        // The listener posts the connection, or installs its protocol
        // (callback mode: setProtocol calls onOpen).
        auto done = std::move(serverDone_);
        serverDone_ = nullptr;
        if (done) done(*this, true);
        return;
    }
    int expected = 0;
    if (!resolved.compare_exchange_strong(expected, 1)) {   // killed meanwhile
        abort(false);
        return;
    }
    if (connectCb_) {
        auto cb = std::move(connectCb_);
        connectCb_ = nullptr;
        cb(*this, true, std::string(), std::string());
        return;
    }
    SocketEvent ev;
    ev.kind = SocketEvent::Kind::Connected;
    ev.gen = gen_;
    ev.token = token_;
    ev.conn = std::static_pointer_cast<Conn>(shared_from_this());
    describe(ev, std::string());
    postSocketEvent(std::move(ev));
    if (protocol_) guarded([this] { protocol_->onOpen(*this); });
}

void Conn::beginServer(int64_t deadlineMs, std::function<void(Conn&, bool)> done) {
    serverDone_ = std::move(done);
    phase_ = Phase::Handshaking;
    if (deadlineMs > 0) setDeadline(kTimerConnect, deadlineMs);
    runHandshake();
}

bool Conn::cancelConnect() {
    int expected = 0;
    if (!resolved.compare_exchange_strong(expected, 2)) return false;   // result already posted
    auto self = std::static_pointer_cast<Conn>(shared_from_this());
    reactor().submit([self] { self->abort(false); });
    return true;
}

void Conn::describe(SocketEvent& ev, const std::string& listenPath) const {
    ev.isUnix = isUnix_;
    if (isUnix_) {
        // From the arguments, not getsockname/getpeername.
        ev.local = SockEndpoint{1, isClient_ ? std::string() : listenPath, 0};
        ev.remote = SockEndpoint{1, isClient_ ? spec_.address : std::string(), 0};
#if defined(__linux__)
        struct ucred uc;
        socklen_t len = sizeof(uc);
        if (::getsockopt(fd_, SOL_SOCKET, SO_PEERCRED, &uc, &len) == 0) {
            ev.cred = Cred{uc.pid, uc.uid, uc.gid};
            ev.hasCred = true;
        }
#elif defined(__APPLE__)
        struct xucred xu;
        socklen_t len = sizeof(xu);
        if (::getsockopt(fd_, SOL_LOCAL, LOCAL_PEERCRED, &xu, &len) == 0 &&
            xu.cr_version == XUCRED_VERSION) {
            pid_t pid = 0;
            socklen_t plen = sizeof(pid);
            (void)::getsockopt(fd_, SOL_LOCAL, LOCAL_PEERPID, &pid, &plen);
            ev.cred = Cred{pid, xu.cr_uid, xu.cr_ngroups > 0 ? xu.cr_groups[0] : 0};
            ev.hasCred = true;
        }
#endif
    } else {
#ifndef _WIN32
        SockAddr a;
        a.len = sizeof(a.ss);
        if (::getsockname(fd_, a.get(), &a.len) == 0) {
            ev.local.kind = 0;
            (void)sockaddrToInet(a, ev.local.text, ev.local.port);
        }
        SockAddr b;
        b.len = sizeof(b.ss);
        if (::getpeername(fd_, b.get(), &b.len) == 0) {
            ev.remote.kind = 0;
            (void)sockaddrToInet(b, ev.remote.text, ev.remote.port);
        }
#endif
    }
    if (transport_ && transport_->info(ev.tls)) ev.hasTls = true;
}

// ---------------------------------------------------------------------------
// Options
// ---------------------------------------------------------------------------

int Conn::setNoDelay(bool on) {
    if (isUnix_) return 0;
#ifndef _WIN32
    if (fd_ < 0) return 0;   // closed: nothing to set
    int v = on ? 1 : 0;
    if (::setsockopt(fd_, IPPROTO_TCP, TCP_NODELAY, &v, sizeof(v)) < 0) return errno;
    return 0;
#else
    (void)on;
    return ENOTSUP;
#endif
}

int Conn::setKeepAlive(int64_t seconds) {
    if (isUnix_) return 0;
#ifndef _WIN32
    if (fd_ < 0) return 0;   // closed: nothing to set
    int on = seconds > 0 ? 1 : 0;
    if (::setsockopt(fd_, SOL_SOCKET, SO_KEEPALIVE, &on, sizeof(on)) < 0) return errno;
    if (on) {
        int idle = seconds > 0x7fffffff ? 0x7fffffff : static_cast<int>(seconds);
#if defined(TCP_KEEPIDLE)
        if (::setsockopt(fd_, IPPROTO_TCP, TCP_KEEPIDLE, &idle, sizeof(idle)) < 0) return errno;
#elif defined(TCP_KEEPALIVE)
        if (::setsockopt(fd_, IPPROTO_TCP, TCP_KEEPALIVE, &idle, sizeof(idle)) < 0) return errno;
#endif
    }
    return 0;
#else
    (void)seconds;
    return ENOTSUP;
#endif
}

// ---------------------------------------------------------------------------
// Protocols
// ---------------------------------------------------------------------------

void Conn::setProtocol(std::unique_ptr<ConnProtocol> p, std::string leftover) {
    if (protocol_) retired_.push_back(std::move(protocol_));   // its `done`s may still run
    protocol_ = std::move(p);
    face_ = dynamic_cast<FaceProtocol*>(protocol_.get());
    if (!protocol_ || phase_ != Phase::Open || closing_) return;
    ConnProtocol* np = protocol_.get();
    guarded([&] {
        np->onOpen(*this);
        if (!leftover.empty() && protocol_.get() == np && phase_ == Phase::Open && !closing_) {
            np->onData(*this, std::string_view(leftover));
        }
        // Plaintext a TLS transport still holds is read by the IO step that
        // follows (no fd event would announce it).
        again_ = againRead_ = true;
    });
}

// Called only at the start of onReady and onTimer, so no protocol method is on the stack.
void Conn::reapRetired() {
    if (!retired_.empty() && !busy_ && outQ_.empty() && shutDone_.empty()) retired_.clear();
}

void Conn::addCloseHook(std::function<void(Conn&)> hook) {
    if (phase_ == Phase::Closed) {
        hook(*this);
        return;
    }
    closeHooks_.push_back(std::move(hook));
}

// --- Face requests -------------------------------------------------------------

namespace {

// Answers a face request with ECANCELED and `reason`.
void postDetached(uint64_t channelId, uint64_t token, ChannelResult::Op op,
                  const std::string& reason) {
    ChannelResult r;
    r.channelId = channelId;
    r.token = token;
    r.op = op;
    r.err = ECANCELED;
    r.reason = reason;
    postChannelResult(std::move(r));
}

} // namespace

void Conn::reqRead(uint64_t channelId, uint64_t token, size_t maxBytes) {
    if (face_) face_->reqRead(*this, channelId, token, maxBytes);
    else postDetached(channelId, token, ChannelResult::Op::Read, faceDetachedReason_);
}

void Conn::reqWrite(uint64_t channelId, uint64_t token, std::string bytes) {
    if (face_) face_->reqWrite(*this, channelId, token, std::move(bytes));
    else postDetached(channelId, token, ChannelResult::Op::Write, faceDetachedReason_);
}

void Conn::reqCloseWrite(uint64_t channelId, uint64_t token) {
    if (face_) face_->reqCloseWrite(*this, channelId, token);
    else postDetached(channelId, token, ChannelResult::Op::Close, faceDetachedReason_);
}

void Conn::reqCloseRead(uint64_t channelId, uint64_t token) {
    if (face_) face_->reqCloseRead(*this, channelId, token);
    else postDetached(channelId, token, ChannelResult::Op::Close, faceDetachedReason_);
}

void Conn::readFaceShutdown() {
    if (face_) face_->readFaceShutdown(*this);
}

void Conn::writeFaceShutdown() {
    if (face_) face_->writeFaceShutdown(*this);
}

// --- Writes ----------------------------------------------------------------------

void Conn::write(std::string bytes, std::function<void(int)> done) {
    if (phase_ != Phase::Open || writeDone_ || shutRequested_ || closing_ || aborting_) {
        if (done) done(writeErr_ != 0 && !aborted_ ? writeErr_ : ECANCELED);
        return;
    }
    outBytes_ += bytes.size();
    outQ_.push_back(OutReq{std::move(bytes), 0, std::move(done)});
    if (outBytes_ >= kLowWatermark) aboveLow_ = true;
    runIo(false, true);   // most writes complete at once
}

void Conn::shutdownWrite(std::function<void(int)> done) {
    if (phase_ != Phase::Open || aborting_) {
        if (done) done(ECANCELED);
        return;
    }
    if (writeDone_) {   // the FIN is out (0) or writing failed
        if (done) done(writeErr_);
        return;
    }
    if (done) shutDone_.push_back(std::move(done));
    shutRequested_ = true;
    runIo(false, true);
}

void Conn::cancelWrites(int err) {
    failOutbound(err);
    runIo(false, true);   // a requested shutdown may proceed now
}

void Conn::closeGraceful(int64_t drainMs) {
    if (phase_ != Phase::Open || closing_ || aborting_) return;
    closing_ = true;
    setDeadline(kTimerDrain, reactor().nowMs() + (drainMs > 0 ? drainMs : kFaceDrainMs));
    if (!writeDone_) shutRequested_ = true;   // SHUT_WR after the queued writes, best effort
    runIo(false, true);
}

void Conn::updateInterest() {
    if (phase_ == Phase::Open) runIo(true, true);
}

void Conn::failOutbound(int err) {
    std::deque<OutReq> q;
    q.swap(outQ_);
    outBytes_ = 0;
    aboveLow_ = false;
    for (auto& o : q) {
        if (o.done) o.done(err);
    }
    finishShutdown(err);
}

void Conn::finishShutdown(int err) {
    std::vector<std::function<void(int)>> cbs;
    cbs.swap(shutDone_);
    for (auto& cb : cbs) cb(err);
}

// ---------------------------------------------------------------------------
// IO (Open phase)
// ---------------------------------------------------------------------------

void Conn::runIo(bool tryRead, bool tryWrite) {
    if (phase_ != Phase::Open || aborting_) return;
    if (busy_) {
        again_ = true;
        againRead_ = againRead_ || tryRead;
        againWrite_ = againWrite_ || tryWrite;
        return;
    }
    {
        BusyScope b(*this);
        bool rd = tryRead, wr = tryWrite;
        for (;;) {
            again_ = againRead_ = againWrite_ = false;
            if (wr) flushPending();   // first: a TLS read or close may wait on it
            if (phase_ == Phase::Open && (readOnWrite_ ? wr : rd)) serviceReads();
            if (phase_ == Phase::Open && (!outQ_.empty() || shutRequested_) &&
                (writeOnRead_ ? rd : wr)) {
                serviceWrites();
            }
            if (!again_ || phase_ != Phase::Open) break;
            rd = againRead_;
            wr = againWrite_;
        }
        again_ = againRead_ = againWrite_ = false;
    }
    afterIo();
}

void Conn::serviceReads() {
    char* buf = readBuffer(g_readDepth);
    ReadDepth depth;
    while (phase_ == Phase::Open && !closing_ && !readDone_ && protocol_ && protocol_->wantsRead()) {
        ssize_t got = transport_->read(buf, kChunk);
        if (got > 0) {
            protocol_->onData(*this, std::string_view(buf, static_cast<size_t>(got)));
            continue;
        }
        if (got == 0) {   // end of input
            eofSeen_ = true;
            readDone_ = true;
            protocol_->onEof(*this);
            return;
        }
        if (got == -1) {
            readOnWrite_ = transport_->wantWrite;
            return;
        }
        readErr_ = transport_->errNo != 0 ? transport_->errNo : EIO;
        readErrReason_ = "read " + (transport_->errCode.empty() ? std::string(errnoName(readErr_))
                                                               : transport_->errCode);
        readDone_ = true;
        protocol_->onError(*this, readErr_, readErrReason_);
        return;
    }
}

void Conn::serviceWrites() {
    while (!outQ_.empty() && phase_ == Phase::Open) {
        OutReq& w = outQ_.front();
        if (w.offset < w.bytes.size()) {
            ssize_t put = transport_->write(w.bytes.data() + w.offset, w.bytes.size() - w.offset);
            if (put == -1 || put == 0) {
                writeOnRead_ = put == -1 && transport_->wantRead;
                return;
            }
            if (put < 0) {
                writeFailed();
                return;
            }
            w.offset += static_cast<size_t>(put);
            outBytes_ -= static_cast<size_t>(put);
            if (w.offset < w.bytes.size()) continue;   // partial: try again (EAGAIN next)
        }
        auto done = std::move(w.done);
        outQ_.pop_front();
        if (done) done(0);
        if (aboveLow_ && outBytes_ < kLowWatermark) {
            aboveLow_ = false;
            if (protocol_ && phase_ == Phase::Open) protocol_->onWritable(*this);
        }
    }
    if (shutRequested_ && outQ_.empty() && !writeDone_ && phase_ == Phase::Open) {
        int rc = transport_->shutdownWrite();
        if (rc == 1) {   // TLS: the close_notify waits for writability
            writeOnRead_ = transport_->wantRead;
            return;
        }
        shutRequested_ = false;
        writeDone_ = true;
        if (rc == 0) {
            finishShutdown(0);
        } else if (!shutDone_.empty()) {   // best effort (no callback): silent
            writeErr_ = transport_->errNo != 0 ? transport_->errNo : EIO;
            writeErrReason_ = "write " + (transport_->errCode.empty()
                                              ? std::string(errnoName(writeErr_))
                                              : transport_->errCode);
            finishShutdown(writeErr_);
        }
    }
}

void Conn::writeFailed() {
    writeErr_ = transport_->errNo != 0 ? transport_->errNo : EIO;
    writeErrReason_ = "write " + (transport_->errCode.empty() ? std::string(errnoName(writeErr_))
                                                             : transport_->errCode);
    writeDone_ = true;
    shutRequested_ = false;
    failOutbound(writeErr_);
    if (protocol_ && phase_ == Phase::Open) protocol_->onError(*this, writeErr_, writeErrReason_);
}

void Conn::flushPending() {
    if (!transport_ || !transport_->hasPendingWrite()) return;
    if (transport_->flush() >= 0) return;
    if (writeErr_ == 0) {
        writeErr_ = transport_->errNo != 0 ? transport_->errNo : EIO;
        writeErrReason_ = "write " + (transport_->errCode.empty() ? std::string(errnoName(writeErr_))
                                                                  : transport_->errCode);
    }
    if (!writeDone_) {
        writeDone_ = true;
        shutRequested_ = false;
        failOutbound(writeErr_);
        if (protocol_ && phase_ == Phase::Open) protocol_->onError(*this, writeErr_, writeErrReason_);
    }
}

void Conn::afterIo() {
    if (phase_ != Phase::Open || busy_) return;
    if (closing_ && outQ_.empty() && !shutRequested_) {
        enterDraining();
        return;
    }
    applyInterest();
}

void Conn::applyInterest() {
    bool r = false, w = false;
    if (!closing_ && !readDone_ && protocol_ && protocol_->wantsRead()) (readOnWrite_ ? w : r) = true;
    if (!outQ_.empty() || shutRequested_) (writeOnRead_ ? r : w) = true;
    if (transport_ && transport_->hasPendingWrite()) w = true;   // e.g. a close_notify
    int e = reactor().setInterest(key(), r, w);
    if (e == 0) return;
    // The fd cannot be watched: fail what waits and give the socket up.
    std::string code = errnoName(e);
    readErr_ = writeErr_ = e;
    readErrReason_ = "read " + code;
    writeErrReason_ = "write " + code;
    bool readWasDone = readDone_;
    readDone_ = writeDone_ = true;
    shutRequested_ = false;
    {
        BusyScope b(*this);   // the callbacks may not start IO: the fd is closed next
        if (protocol_ && !readWasDone) protocol_->onError(*this, e, readErrReason_);
        failOutbound(e);
        if (protocol_ && phase_ == Phase::Open) protocol_->onError(*this, e, writeErrReason_);
    }
    closeNow();
}

// Input is discarded only if it has not ended or failed; closing with unread input would reset the connection
// instead of ending it with the FIN already sent.
void Conn::enterDraining() {
    discarding_ = !eofSeen_ && readErr_ == 0 && !aborted_;
    bool flushing = !aborted_ && transport_ && transport_->hasPendingWrite();
    if (!discarding_ && !flushing) {
        closeNow();
        return;
    }
    phase_ = Phase::Draining;
    if (deadlines_[kTimerDrain] == 0) setDeadline(kTimerDrain, reactor().nowMs() + kFaceDrainMs);
    drainStep();
}

// The drain deadline (fireTimer) closes the connection if this does not finish first.
void Conn::drainStep() {
    bool wantR = false, wantW = false;
    if (transport_ && transport_->hasPendingWrite()) {
        if (transport_->flush() == 1) wantW = true;   // < 0: given up (nothing pending)
    }
#ifndef _WIN32
    if (discarding_) {
        char* buf = scratch();
        wantR = true;   // bounded loop: other handlers get their turn
        for (int i = 0; i < 16; ++i) {
            ssize_t got = ::recv(fd_, buf, kChunk, 0);
            if (got > 0) continue;
            if (got < 0 && errno == EINTR) continue;
            if (got < 0 && (errno == EAGAIN || errno == EWOULDBLOCK)) break;
            discarding_ = false;   // EOF or an error: done
            wantR = false;
            break;
        }
    }
#else
    discarding_ = false;
#endif
    if (!wantR && !wantW) {
        closeNow();
        return;
    }
    if (reactor().setInterest(key(), wantR, wantW) != 0) closeNow();
}

void Conn::closeNow() {
    if (key() != 0) reactor().remove(key());   // remove before close, as IoHandler requires
    closeFd(fd_);
    fd_ = -1;
    phase_ = Phase::Closed;
    transport_.reset();
    for (auto& d : deadlines_) d = 0;
    shutRequested_ = false;
    if (!outQ_.empty() || !shutDone_.empty()) failOutbound(ECANCELED);
    std::vector<std::function<void(Conn&)>> hooks;
    hooks.swap(closeHooks_);
    for (auto& h : hooks) h(*this);
}

// ---------------------------------------------------------------------------
// Timers: several deadlines on the reactor's one timer per handler
// ---------------------------------------------------------------------------

void Conn::setDeadline(int timerId, int64_t monoMs) {
    if (timerId < 0 || timerId >= kMaxTimers) return;
    deadlines_[timerId] = monoMs > 0 ? monoMs : 0;
    armTimer();
}

int64_t Conn::deadline(int timerId) const {
    if (timerId < 0 || timerId >= kMaxTimers) return 0;
    return deadlines_[timerId];
}

void Conn::armTimer() {
    if (key() == 0) return;
    int64_t earliest = 0;
    for (int64_t d : deadlines_) {
        if (d > 0 && (earliest == 0 || d < earliest)) earliest = d;
    }
    reactor().setTimer(key(), earliest);
}

void Conn::onTimer() {
    reapRetired();
    int64_t now = reactor().nowMs();
    struct Due {
        int64_t at;
        int id;
    };
    Due due[kMaxTimers];
    int n = 0;
    for (int i = 0; i < kMaxTimers; ++i) {
        if (deadlines_[i] > 0 && deadlines_[i] <= now) {
            due[n++] = Due{deadlines_[i], i};
            deadlines_[i] = 0;
        }
    }
    std::sort(due, due + n, [](const Due& a, const Due& b) {
        return a.at != b.at ? a.at < b.at : a.id < b.id;
    });
    armTimer();
    for (int k = 0; k < n; ++k) {
        if (phase_ == Phase::Closed) return;
        if (deadlines_[due[k].id] != 0) continue;   // set again by an earlier callback
        fireTimer(due[k].id);
    }
}

void Conn::fireTimer(int id) {
    switch (phase_) {
    case Phase::Connecting:
    case Phase::Handshaking:
        if (id == kTimerConnect) timedOut();
        return;
    case Phase::Draining:
        if (id == kTimerDrain) closeNow();
        return;
    case Phase::Open:
        if (closing_ && id == kTimerDrain) {   // the writes did not get out in time
            closeNow();
            return;
        }
        if (protocol_) guarded([this, id] { protocol_->onTimer(*this, id); });
        return;
    default:
        return;
    }
}

void Conn::timedOut() {
    if (isClient_) {
        connectFailed("ETIMEDOUT", "connect ETIMEDOUT " + target());
        return;
    }
    auto done = std::move(serverDone_);
    serverDone_ = nullptr;
    if (done) done(*this, false);   // the listener closes it
}

// ---------------------------------------------------------------------------
// Abort / reset
// ---------------------------------------------------------------------------

void Conn::abort(bool reset) {
    switch (phase_) {
    case Phase::Idle:
        aborted_ = true;
        readDone_ = writeDone_ = true;
        phase_ = Phase::Closed;
        return;
    case Phase::Connecting:
        connectFailed("ECANCELED", "connect ECANCELED " + target());
        aborted_ = true;
        return;
    case Phase::Handshaking:
        if (isClient_) {
            connectFailed("ECANCELED", "connect ECANCELED " + target());
        } else {
            serverDone_ = nullptr;
            readDone_ = writeDone_ = true;
            closeNow();
        }
        aborted_ = true;
        return;
    case Phase::Closed:
        aborted_ = true;   // later requests: "socket closed"
        return;
    case Phase::Open:
    case Phase::Draining:
        break;
    }
    if (aborting_) return;   // a protocol aborting from its onCloseAll
    aborting_ = true;
#ifndef _WIN32
    if (reset && !isUnix_ && fd_ >= 0) {
        struct linger lg;
        lg.l_onoff = 1;
        lg.l_linger = 0;
        (void)::setsockopt(fd_, SOL_SOCKET, SO_LINGER, &lg, sizeof(lg));
    }
#else
    (void)reset;
#endif
    aborted_ = true;
    if (protocol_) {
        BusyScope b(*this);   // no IO from here on
        protocol_->onCloseAll(*this);
    }
    shutRequested_ = false;
    failOutbound(ECANCELED);
    readDone_ = writeDone_ = true;
    closeNow();
}

// ---------------------------------------------------------------------------
// IoHandler
// ---------------------------------------------------------------------------

void Conn::onReady(bool readable, bool writable, bool errorOrHangup) {
    reapRetired();
    switch (phase_) {
    case Phase::Connecting: {
#ifndef _WIN32
        int err = 0;
        socklen_t len = sizeof(err);
        if (::getsockopt(fd_, SOL_SOCKET, SO_ERROR, &err, &len) < 0) err = errno;
        if (err != 0) {
            connectFailed(err);
            return;
        }
        (void)reactor().setInterest(key(), false, false);
        connected();
#endif
        return;
    }
    case Phase::Handshaking:
        runHandshake();
        return;
    case Phase::Open:
        // errorOrHangup only arrives while there is interest: treated as both
        // directions ready (the syscalls report the error).
        runIo(readable || errorOrHangup, writable || errorOrHangup);
        return;
    case Phase::Draining:
        drainStep();
        return;
    default:
        if (key() != 0) (void)reactor().setInterest(key(), false, false);
        return;
    }
}

void Conn::onCloseAll() {
    serverDone_ = nullptr;
    abort(false);
    if (key() != 0) closeNow();
}

} // namespace Eco::System
