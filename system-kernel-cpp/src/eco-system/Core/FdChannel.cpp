//===- FdChannel.cpp - ByteChannel over a file descriptor -----------------===//
//
// See FdChannel.hpp. The channel thread is detached and holds a shared_ptr
// to the channel state, so destroying the handle never races the thread
// (§3.4 leaky-service rule, applied per channel).
//
// Templates used: none (POD only, G1).
//
//===----------------------------------------------------------------------===//

#include "eco-system/Core/FdChannel.hpp"

#include <cerrno>
#include <deque>
#include <mutex>
#include <string>
#include <system_error>
#include <thread>
#include <utility>
#include <vector>

#ifndef _WIN32
#include <climits>
#include <fcntl.h>
#include <poll.h>
#include <sys/stat.h>
#include <unistd.h>
#endif

namespace Eco::System {

namespace {

void postSimple(uint64_t chanId, uint64_t token, ChannelResult::Op op, int err) {
    ChannelResult r;
    r.channelId = chanId;
    r.token = token;
    r.op = op;
    r.err = err;
    postChannelResult(std::move(r));
}

} // namespace

#ifdef _WIN32

// ---------------------------------------------------------------------------
// Windows stub (§1): every request completes with ENOTSUP.
// ---------------------------------------------------------------------------

struct FdChannel::State {
    int fd = -1;
};

int makeCloexecPipe(int fds[2], bool) {
    fds[0] = fds[1] = -1;
    return ENOTSUP;
}

FdChannel::FdChannel(int fd, FdChannelOptions) : st_(std::make_shared<State>()) { st_->fd = fd; }
FdChannel::~FdChannel() = default;

void FdChannel::requestRead(uint64_t token, size_t) {
    postSimple(id(), token, ChannelResult::Op::Read, ENOTSUP);
}
void FdChannel::requestWrite(uint64_t token, std::string) {
    postSimple(id(), token, ChannelResult::Op::Write, ENOTSUP);
}
void FdChannel::close(uint64_t token) {
    postSimple(id(), token, ChannelResult::Op::Close, ENOTSUP);
}
void FdChannel::shutdown() {}
int FdChannel::fd() const { return st_->fd; }

#else // POSIX

// ---------------------------------------------------------------------------
// State shared by the handle (main thread) and the channel thread.
// ---------------------------------------------------------------------------

struct FdChannel::State {
    struct ReadReq {
        uint64_t token;
        size_t maxBytes;
    };
    struct WriteReq {
        uint64_t token;
        std::string bytes;
        size_t off = 0;
    };

    int fd = -1;
    uint64_t chanId = 0;
    int wakeR = -1;
    int wakeW = -1;
    bool regular = false;   // regular file: write without chunking
    int64_t readRemaining = -1;     // FdChannelOptions::readLimit (channel thread only)
    bool truncateOnClose = false;   // FdChannelOptions::truncateOnClose

    std::mutex m;            // guards everything below
    std::deque<ReadReq> reads;
    std::deque<WriteReq> writes;
    bool closeRequested = false;
    uint64_t closeToken = 0;
    bool stop = false;       // shutdown() requested
    bool finished = false;   // the thread is done (or never started)
    int deadErr = ECANCELED; // error for requests made once finished

    ~State() {
        // Last reference gone: nobody can write the wake pipe any more.
        if (wakeR >= 0) ::close(wakeR);
        if (wakeW >= 0) ::close(wakeW);
    }

    void wake() {
        if (wakeW < 0) return;
        char b = 1;
        ssize_t r;
        do { r = ::write(wakeW, &b, 1); } while (r < 0 && errno == EINTR);
        // EAGAIN: the pipe already holds a wake byte; fine.
    }

    void drainWake() {
        char buf[64];
        ssize_t r;
        do { r = ::read(wakeR, buf, sizeof buf); } while (r > 0 || (r < 0 && errno == EINTR));
    }
};

int makeCloexecPipe(int fds[2], bool nonBlocking) {
#if defined(__linux__)
    if (::pipe2(fds, O_CLOEXEC | (nonBlocking ? O_NONBLOCK : 0)) != 0) return errno;
    return 0;
#else
    if (::pipe(fds) != 0) return errno;
    for (int i = 0; i < 2; ++i) {
        int fdFlags = ::fcntl(fds[i], F_GETFD);
        if (fdFlags < 0 || ::fcntl(fds[i], F_SETFD, fdFlags | FD_CLOEXEC) < 0) goto fail;
        if (nonBlocking) {
            int flFlags = ::fcntl(fds[i], F_GETFL);
            if (flFlags < 0 || ::fcntl(fds[i], F_SETFL, flFlags | O_NONBLOCK) < 0) goto fail;
        }
    }
    return 0;
fail:
    {
        int e = errno;
        ::close(fds[0]);
        ::close(fds[1]);
        fds[0] = fds[1] = -1;
        return e;
    }
#endif
}

namespace {

using State = FdChannel::State;

constexpr size_t kMaxReadChunk = 1u << 20;

// One read for the head request, after poll reported readiness.
void doRead(State& st, std::vector<char>& buf) {
    uint64_t token;
    size_t maxBytes;
    {
        std::lock_guard<std::mutex> lk(st.m);
        token = st.reads.front().token;
        maxBytes = st.reads.front().maxBytes;
    }
    if (maxBytes == 0) maxBytes = 1;
    if (maxBytes > kMaxReadChunk) maxBytes = kMaxReadChunk;
    if (st.readRemaining >= 0 && maxBytes > static_cast<uint64_t>(st.readRemaining))
        maxBytes = static_cast<size_t>(st.readRemaining);
    if (buf.size() < maxBytes) buf.resize(maxBytes);

    ssize_t r = 0;
    int e = 0;
    if (maxBytes > 0) {   // 0 only when the read limit is used up: EOF
        do { r = ::read(st.fd, buf.data(), maxBytes); } while (r < 0 && errno == EINTR);
        e = errno;
        if (r < 0 && (e == EAGAIN || e == EWOULDBLOCK)) return;   // spurious: poll again
        if (r > 0 && st.readRemaining >= 0) st.readRemaining -= r;
    }

    ChannelResult res;
    res.channelId = st.chanId;
    res.token = token;
    res.op = ChannelResult::Op::Read;
    if (r < 0) res.err = e;
    else if (r == 0) res.eof = true;
    else res.bytes.assign(buf.data(), static_cast<size_t>(r));
    {
        std::lock_guard<std::mutex> lk(st.m);
        st.reads.pop_front();
    }
    postChannelResult(std::move(res));
}

// One write chunk for the head request, after poll reported readiness.
void doWrite(State& st) {
    uint64_t token;
    const char* data;
    size_t len, off;
    {
        std::lock_guard<std::mutex> lk(st.m);
        // Element references survive push_back on a deque; only this thread
        // pops, so `data` stays valid until we pop below.
        auto& w = st.writes.front();
        token = w.token;
        data = w.bytes.data();
        len = w.bytes.size();
        off = w.off;
    }
    int err = 0;
    if (off < len) {
        size_t chunk = len - off;
        if (!st.regular && chunk > PIPE_BUF) chunk = PIPE_BUF;   // never block past POLLOUT
        ssize_t r;
        do { r = ::write(st.fd, data + off, chunk); } while (r < 0 && errno == EINTR);
        if (r < 0) {
            int e = errno;
            if (e == EAGAIN || e == EWOULDBLOCK) return;
            err = e;
        } else {
            off += static_cast<size_t>(r);
        }
    }
    if (err == 0 && off < len) {
        std::lock_guard<std::mutex> lk(st.m);
        st.writes.front().off = off;
        return;
    }
    ChannelResult res;
    res.channelId = st.chanId;
    res.token = token;
    res.op = ChannelResult::Op::Write;
    res.err = err;
    res.written = off;
    {
        std::lock_guard<std::mutex> lk(st.m);
        st.writes.pop_front();
    }
    postChannelResult(std::move(res));
}

// Complete every pending request with `err` (POLLNVAL / poll failure).
void failPending(State& st, int err) {
    std::deque<State::ReadReq> reads;
    std::deque<State::WriteReq> writes;
    {
        std::lock_guard<std::mutex> lk(st.m);
        reads.swap(st.reads);
        writes.swap(st.writes);
    }
    for (auto& r : reads) postSimple(st.chanId, r.token, ChannelResult::Op::Read, err);
    for (auto& w : writes) postSimple(st.chanId, w.token, ChannelResult::Op::Write, err);
}

// The channel thread. Owns the fd: it is the only closer (§3.4).
void channelThread(std::shared_ptr<State> sp) {
    State& st = *sp;
    std::vector<char> buf;
    for (;;) {
        bool wantRead, wantWrite;
        {
            std::lock_guard<std::mutex> lk(st.m);
            if (st.stop) break;
            if (st.closeRequested && st.writes.empty()) break;
            wantRead = !st.reads.empty();
            wantWrite = !st.writes.empty();
        }
        if (wantRead && st.readRemaining == 0) {   // read limit used up: EOF now
            doRead(st, buf);
            continue;
        }
        struct pollfd pfd[2];
        pfd[0].fd = (wantRead || wantWrite) ? st.fd : -1;   // -1: ignored by poll
        pfd[0].events = static_cast<short>((wantRead ? POLLIN : 0) | (wantWrite ? POLLOUT : 0));
        pfd[0].revents = 0;
        pfd[1].fd = st.wakeR;
        pfd[1].events = POLLIN;
        pfd[1].revents = 0;

        int n = ::poll(pfd, 2, -1);
        if (n < 0) {
            int e = errno;
            if (e == EINTR || e == EAGAIN) continue;
            failPending(st, e);
            continue;
        }
        if (pfd[1].revents & POLLIN) st.drainWake();
        if (pfd[0].fd < 0) continue;
        short rev = pfd[0].revents;
        if (rev & POLLNVAL) {
            failPending(st, EBADF);
            continue;
        }
        if (wantRead && (rev & (POLLIN | POLLHUP | POLLERR))) doRead(st, buf);
        if (wantWrite && (rev & (POLLOUT | POLLHUP | POLLERR))) doWrite(st);
    }

    // Finish: cancel what is left, close the fd (never 0–2), report the close.
    std::deque<State::ReadReq> reads;
    std::deque<State::WriteReq> writes;
    bool closeRequested;
    uint64_t closeToken;
    {
        std::lock_guard<std::mutex> lk(st.m);
        st.finished = true;
        reads.swap(st.reads);
        writes.swap(st.writes);
        closeRequested = st.closeRequested;
        closeToken = st.closeToken;
    }
    for (auto& r : reads) postSimple(st.chanId, r.token, ChannelResult::Op::Read, ECANCELED);
    for (auto& w : writes) postSimple(st.chanId, w.token, ChannelResult::Op::Write, ECANCELED);
    int closeErr = 0;
    if (closeRequested && st.truncateOnClose && st.fd > 2) {
        off_t pos = ::lseek(st.fd, 0, SEEK_CUR);
        int rc;
        if (pos < 0) rc = -1;
        else do { rc = ::ftruncate(st.fd, pos); } while (rc != 0 && errno == EINTR);
        if (rc != 0) closeErr = errno;
    }
    if (st.fd > 2) {
        // No retry on EINTR: the fd is released either way on Linux/macOS.
        if (::close(st.fd) != 0 && errno != EINTR && closeErr == 0) closeErr = errno;
    }
    if (closeRequested) postSimple(st.chanId, closeToken, ChannelResult::Op::Close, closeErr);
}

} // namespace

FdChannel::FdChannel(int fd, FdChannelOptions opts) : st_(std::make_shared<State>()) {
    st_->fd = fd;
    st_->chanId = id();
    st_->readRemaining = opts.readLimit;
    st_->truncateOnClose = opts.truncateOnClose;
    struct stat sb;
    if (::fstat(fd, &sb) == 0) st_->regular = S_ISREG(sb.st_mode);

    int w[2] = {-1, -1};
    int e = makeCloexecPipe(w, /*nonBlocking=*/true);
    if (e == 0) {
        st_->wakeR = w[0];
        st_->wakeW = w[1];
        try {
            std::thread(channelThread, st_).detach();
            return;
        } catch (const std::system_error& se) {
            e = se.code().value() ? se.code().value() : EAGAIN;
        }
    }
    // No thread will ever run: this is the only place the fd can be closed.
    st_->finished = true;
    st_->deadErr = e;
    if (fd > 2) ::close(fd);
}

FdChannel::~FdChannel() {
    bool closing;
    {
        std::lock_guard<std::mutex> lk(st_->m);
        closing = st_->closeRequested || st_->finished || st_->stop;
    }
    if (!closing) shutdown();   // otherwise the thread finishes on its own
}

void FdChannel::requestRead(uint64_t token, size_t maxBytes) {
    int err = 0;
    {
        std::lock_guard<std::mutex> lk(st_->m);
        if (st_->finished) err = st_->deadErr;
        else if (st_->stop || st_->closeRequested) err = ECANCELED;
        else st_->reads.push_back(State::ReadReq{token, maxBytes});
    }
    if (err) postSimple(id(), token, ChannelResult::Op::Read, err);
    else st_->wake();
}

void FdChannel::requestWrite(uint64_t token, std::string bytes) {
    int err = 0;
    {
        std::lock_guard<std::mutex> lk(st_->m);
        if (st_->finished) err = st_->deadErr;
        else if (st_->stop || st_->closeRequested) err = ECANCELED;
        else st_->writes.push_back(State::WriteReq{token, std::move(bytes), 0});
    }
    if (err) postSimple(id(), token, ChannelResult::Op::Write, err);
    else st_->wake();
}

void FdChannel::close(uint64_t token) {
    int err = 0;
    {
        std::lock_guard<std::mutex> lk(st_->m);
        if (st_->finished) err = st_->deadErr;
        else if (st_->stop || st_->closeRequested) err = ECANCELED;
        else {
            st_->closeRequested = true;
            st_->closeToken = token;
        }
    }
    if (err) postSimple(id(), token, ChannelResult::Op::Close, err);
    else st_->wake();
}

void FdChannel::shutdown() {
    {
        std::lock_guard<std::mutex> lk(st_->m);
        if (st_->stop || st_->finished) return;
        st_->stop = true;
    }
    st_->wake();
}

int FdChannel::fd() const { return st_->fd; }

#endif // _WIN32

} // namespace Eco::System
