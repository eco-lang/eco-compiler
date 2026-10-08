//===- Conn.cpp - One stream connection on the IoReactor ------------------===//
//
// See Conn.hpp (plans/eco-system-sockets.md §3.3.3, §D.2, §D.3, §D.5).
// Reactor thread only, except makeClient (main thread, before the Conn is
// shared with the reactor) and cancelConnect (main thread, atomics only).
//
// Reads and writes are attempted at once when requested (most complete
// without waiting), and otherwise wait for readiness with demand-driven
// interest (§3.3.1 rule 1). A request produces exactly one ChannelResult.
// Error reasons (§D.2): "read <CODE>", "write <CODE>", "socket closed".
//
// Templates used: none (POD only, G1); T9 completion side (ChannelResult).
//
//===----------------------------------------------------------------------===//

#include "eco-system/Socket/Conn.hpp"

#include "eco-system/Core/SocketUtil.hpp"

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

constexpr size_t kChunk = 64 * 1024;
constexpr int64_t kDiscardDrainMs = 2000;   // N8, SF8
constexpr const char* kSocketClosed = "socket closed";

char* scratch() {
    thread_local std::vector<char> buf(kChunk);   // reactor thread
    return buf.data();
}

IoReactor& reactor() { return IoReactor::instance(); }

#ifndef _WIN32

// --- The plain transport -------------------------------------------------------

class PlainTransport final : public Transport {
public:
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
    ssize_t fail(int e) {
        errNo = e;
        errCode = errnoName(e);
        errMessage = std::strerror(e);
        return -2;
    }

    int fd_;
};

#else // _WIN32: never reached (the kernels fail ENOTSUP first, §1)

class PlainTransport final : public Transport {
public:
    explicit PlainTransport(int) {}
    ssize_t read(char*, size_t) override { return fail(); }
    ssize_t write(const char*, size_t) override { return fail(); }
    int shutdownWrite() override { return static_cast<int>(fail()); }

private:
    ssize_t fail() {
        errNo = ENOTSUP;
        errCode = "ENOTSUP";
        errMessage = "not supported on Windows yet";
        return -2;
    }
};

#endif

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
    if (spec_.timeoutMs > 0) reactor().setTimer(key(), reactor().nowMs() + spec_.timeoutMs);
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
    // Unix: EAGAIN = the listener's backlog is full (§D.3); reported as is.
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
    reactor().setTimer(key(), 0);
    (void)reactor().setInterest(key(), false, false);
    phase_ = Phase::Open;
    if (!isClient_) {
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
    SocketEvent ev;
    ev.kind = SocketEvent::Kind::Connected;
    ev.gen = gen_;
    ev.token = token_;
    ev.conn = std::static_pointer_cast<Conn>(shared_from_this());
    describe(ev, std::string());
    postSocketEvent(std::move(ev));
}

void Conn::beginServer(int64_t deadlineMs, std::function<void(Conn&, bool)> done) {
    serverDone_ = std::move(done);
    phase_ = Phase::Handshaking;
    if (deadlineMs > 0) reactor().setTimer(key(), deadlineMs);
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
        // §D.3: from the arguments, not getsockname/getpeername.
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
    if (fd_ < 0) return 0;   // closed: nothing to set (as Node)
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
    if (fd_ < 0) return 0;   // closed: nothing to set (as Node)
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
// Results
// ---------------------------------------------------------------------------

void Conn::postRead(const ReadReq& r, ChannelResult res) {
    res.channelId = r.channelId;
    res.token = r.token;
    res.op = ChannelResult::Op::Read;
    postChannelResult(std::move(res));
}

void Conn::failReads(int err, const std::string& reason) {
    std::deque<ReadReq> reqs;
    reqs.swap(readReqs_);
    for (const ReadReq& r : reqs) {
        ChannelResult res;
        res.err = err;
        res.reason = reason;
        postRead(r, std::move(res));
    }
}

void Conn::failWrites(int err, const std::string& reason) {
    std::deque<WriteReq> reqs;
    reqs.swap(writeQ_);
    for (const WriteReq& w : reqs) {
        ChannelResult res;
        res.channelId = w.channelId;
        res.token = w.token;
        res.op = ChannelResult::Op::Write;
        res.err = err;
        res.reason = reason;
        postChannelResult(std::move(res));
    }
}

void Conn::postClose(uint64_t channelId, uint64_t token, int err, const std::string& reason) {
    ChannelResult res;
    res.channelId = channelId;
    res.token = token;
    res.op = ChannelResult::Op::Close;
    res.err = err;
    res.reason = reason;
    postChannelResult(std::move(res));
}

// A read requested after reading ended.
void Conn::readResultForLateRequest(ChannelResult& r) const {
    if (eofSeen_) {
        r.eof = true;
    } else if (readErr_ != 0) {
        r.err = readErr_;
        r.reason = readErrReason_;
    } else {
        r.err = ECANCELED;
        r.reason = kSocketClosed;
    }
}

// A write (or close) requested after writing ended.
void Conn::writeResultForLateRequest(ChannelResult& r) const {
    if (writeErr_ != 0 && !aborted_) {
        r.err = writeErr_;
        r.reason = writeErrReason_;
    } else {
        r.err = ECANCELED;
        r.reason = kSocketClosed;
    }
}

// ---------------------------------------------------------------------------
// Face requests
// ---------------------------------------------------------------------------

void Conn::reqRead(uint64_t channelId, uint64_t token, size_t maxBytes) {
    if (phase_ != Phase::Open || readDone_) {
        ChannelResult r;
        readResultForLateRequest(r);
        postRead(ReadReq{channelId, token, maxBytes}, std::move(r));
        return;
    }
    readReqs_.push_back(ReadReq{channelId, token, maxBytes});
    // At once: most reads find data (and TLS may hold decrypted bytes that
    // no fd event announces, N6).
    serviceReads();
    afterIo();
}

void Conn::reqWrite(uint64_t channelId, uint64_t token, std::string bytes) {
    if (phase_ != Phase::Open || writeDone_ || closePending_) {
        ChannelResult r;
        r.channelId = channelId;
        r.token = token;
        r.op = ChannelResult::Op::Write;
        writeResultForLateRequest(r);
        postChannelResult(std::move(r));
        return;
    }
    writeQ_.push_back(WriteReq{channelId, token, std::move(bytes), 0});
    serviceWrites();
    afterIo();
}

void Conn::reqCloseWrite(uint64_t channelId, uint64_t token) {
    if (phase_ != Phase::Open || writeDone_ || closePending_) {
        ChannelResult r;
        writeResultForLateRequest(r);
        postClose(channelId, token, r.err, r.reason);
        return;
    }
    closePending_ = true;
    closeChannel_ = channelId;
    closeToken_ = token;
    serviceWrites();
    afterIo();
}

void Conn::reqCloseRead(uint64_t channelId, uint64_t token) {
    if (!readDone_) {
        // Closed before EOF (not done by the stream table, which closes a
        // source only after EOF): treat as abandoned.
        if (!eofSeen_ && readErr_ == 0) readAbandoned_ = true;
        readDone_ = true;
        failReads(ECANCELED, std::string());
    }
    postClose(channelId, token, 0, std::string());
    afterIo();
}

void Conn::readFaceShutdown() {
    failReads(ECANCELED, aborted_ ? std::string(kSocketClosed) : std::string());
    if (!readDone_) {
        readDone_ = true;
        if (!eofSeen_ && readErr_ == 0) readAbandoned_ = true;   // no SHUT_RD (N8)
    }
    afterIo();
}

void Conn::writeFaceShutdown() {
    failWrites(ECANCELED, aborted_ ? std::string(kSocketClosed) : std::string());
    if (closePending_) {
        closePending_ = false;
        postClose(closeChannel_, closeToken_, ECANCELED, std::string());
    }
    if (!writeDone_) {
        writeDone_ = true;
        if (phase_ == Phase::Open && transport_) (void)transport_->shutdownWrite();   // FIN, best effort
    }
    afterIo();
}

// ---------------------------------------------------------------------------
// IO
// ---------------------------------------------------------------------------

void Conn::serviceReads() {
    char* buf = scratch();
    while (!readReqs_.empty() && !readDone_ && phase_ == Phase::Open) {
        const ReadReq rq = readReqs_.front();
        size_t n = rq.max == 0 ? 1 : (rq.max > kChunk ? kChunk : rq.max);
        ssize_t got = transport_->read(buf, n);
        if (got > 0) {
            readReqs_.pop_front();
            ChannelResult res;
            res.bytes.assign(buf, static_cast<size_t>(got));
            postRead(rq, std::move(res));
            continue;
        }
        if (got == 0) {   // end of input: this read and every queued one
            eofSeen_ = true;
            readDone_ = true;
            std::deque<ReadReq> reqs;
            reqs.swap(readReqs_);
            for (const ReadReq& r : reqs) {
                ChannelResult res;
                res.eof = true;
                postRead(r, std::move(res));
            }
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
        failReads(readErr_, readErrReason_);
        return;
    }
}

void Conn::serviceWrites() {
    while (!writeQ_.empty() && phase_ == Phase::Open) {
        WriteReq& w = writeQ_.front();
        if (w.offset < w.bytes.size()) {
            ssize_t put = transport_->write(w.bytes.data() + w.offset, w.bytes.size() - w.offset);
            if (put == -1 || put == 0) {
                writeOnRead_ = put == -1 && transport_->wantRead;
                return;
            }
            if (put < 0) {
                writeErr_ = transport_->errNo != 0 ? transport_->errNo : EIO;
                writeErrReason_ = "write " + (transport_->errCode.empty()
                                                  ? std::string(errnoName(writeErr_))
                                                  : transport_->errCode);
                writeDone_ = true;
                failWrites(writeErr_, writeErrReason_);
                if (closePending_) {
                    closePending_ = false;
                    postClose(closeChannel_, closeToken_, writeErr_, writeErrReason_);
                }
                return;
            }
            w.offset += static_cast<size_t>(put);
            if (w.offset < w.bytes.size()) continue;   // partial: try again (EAGAIN next)
        }
        ChannelResult res;
        res.channelId = w.channelId;
        res.token = w.token;
        res.op = ChannelResult::Op::Write;
        res.written = w.bytes.size();
        writeQ_.pop_front();
        postChannelResult(std::move(res));
    }
    if (closePending_ && writeQ_.empty() && !writeDone_ && phase_ == Phase::Open) {
        int rc = transport_->shutdownWrite();
        if (rc == 1) {
            writeOnRead_ = transport_->wantRead;
            return;
        }
        closePending_ = false;
        writeDone_ = true;
        if (rc == 0) {
            postClose(closeChannel_, closeToken_, 0, std::string());
        } else {
            writeErr_ = transport_->errNo != 0 ? transport_->errNo : EIO;
            writeErrReason_ = "write " + (transport_->errCode.empty()
                                              ? std::string(errnoName(writeErr_))
                                              : transport_->errCode);
            postClose(closeChannel_, closeToken_, writeErr_, writeErrReason_);
        }
    }
}

void Conn::afterIo() {
    if (phase_ != Phase::Open) return;
    if (readDone_ && writeDone_ && readReqs_.empty() && writeQ_.empty() && !closePending_) {
        // §3.3.3: the read face was cancelled before EOF. Closing with
        // unread data would make Linux send RST instead of our FIN (N8):
        // discard incoming data until EOF. And what the transport still
        // holds (a TLS close_notify, its SHUT_WR) is sent first. Both for at
        // most 2 s.
        discarding_ = readAbandoned_ && !eofSeen_ && readErr_ == 0 && !aborted_;
        bool flushing = !aborted_ && transport_ && transport_->hasPendingWrite();
        if (discarding_ || flushing) {
            phase_ = Phase::Draining;
            reactor().setTimer(key(), reactor().nowMs() + kDiscardDrainMs);
            drainStep();
            return;
        }
        closeNow();
        return;
    }
    updateInterest();
}

void Conn::updateInterest() {
    bool r = false, w = false;
    if (!readReqs_.empty() && !readDone_) (readOnWrite_ ? w : r) = true;
    if (!writeQ_.empty() || closePending_) (writeOnRead_ ? r : w) = true;
    if (transport_ && transport_->hasPendingWrite()) w = true;   // S5: e.g. a close_notify
    int e = reactor().setInterest(key(), r, w);
    if (e == 0) return;
    // The fd cannot be watched: fail what waits and give the socket up.
    std::string code = errnoName(e);
    readErr_ = writeErr_ = e;
    readErrReason_ = "read " + code;
    writeErrReason_ = "write " + code;
    failReads(e, readErrReason_);
    failWrites(e, writeErrReason_);
    if (closePending_) {
        closePending_ = false;
        postClose(closeChannel_, closeToken_, e, writeErrReason_);
    }
    readDone_ = writeDone_ = true;
    closeNow();
}

// Open phase, writable: send what the transport still holds. A failure
// ends the write direction (the peer is gone).
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
        failWrites(writeErr_, writeErrReason_);
        if (closePending_) {
            closePending_ = false;
            postClose(closeChannel_, closeToken_, writeErr_, writeErrReason_);
        }
    }
}

// Draining: flush the transport's pending output and/or discard input;
// close when neither is left (or on the 2 s timer, onTimer).
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
    if (key() != 0) reactor().remove(key());   // remove before close (rule 3)
    closeFd(fd_);
    fd_ = -1;
    phase_ = Phase::Closed;
    transport_.reset();
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
    failReads(ECANCELED, kSocketClosed);
    failWrites(ECANCELED, kSocketClosed);
    if (closePending_) {   // a pending closeWritable completes (§D.2)
        closePending_ = false;
        postClose(closeChannel_, closeToken_, 0, std::string());
    }
    readDone_ = writeDone_ = true;
    closeNow();
}

// ---------------------------------------------------------------------------
// IoHandler
// ---------------------------------------------------------------------------

void Conn::onReady(bool readable, bool writable, bool errorOrHangup) {
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
    case Phase::Open: {
        bool rd = readable || errorOrHangup;
        bool wr = writable || errorOrHangup;
        if (wr) flushPending();   // first: a TLS read or close may wait on it
        if (!readReqs_.empty() && !readDone_ && (readOnWrite_ ? wr : rd)) serviceReads();
        if ((!writeQ_.empty() || closePending_) && (writeOnRead_ ? rd : wr)) serviceWrites();
        afterIo();
        return;
    }
    case Phase::Draining:
        drainStep();
        return;
    default:
        if (key() != 0) (void)reactor().setInterest(key(), false, false);
        return;
    }
}

void Conn::onTimer() {
    switch (phase_) {
    case Phase::Connecting:
    case Phase::Handshaking:
        if (isClient_) {
            connectFailed("ETIMEDOUT", "connect ETIMEDOUT " + target());
        } else {
            auto done = std::move(serverDone_);
            serverDone_ = nullptr;
            if (done) done(*this, false);   // the listener closes it
        }
        return;
    case Phase::Draining:
        closeNow();
        return;
    default:
        return;
    }
}

void Conn::onCloseAll() {
    serverDone_ = nullptr;
    abort(false);
    if (key() != 0) closeNow();
}

} // namespace Eco::System
