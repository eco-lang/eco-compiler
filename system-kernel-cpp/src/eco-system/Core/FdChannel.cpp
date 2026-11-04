//===- FdChannel.cpp - ByteChannel over a file descriptor -----------------===//
//
// The handle and the detached channel thread each hold a shared_ptr to one
// `State`. Requests are pushed and flags set under `State::m` by the eco
// thread, which then writes a byte to the wake pipe; the thread snapshots what
// it wants under the lock, polls without it, and pops a request only after
// its IO call, so a request's data stays put while the call runs.
//
//===----------------------------------------------------------------------===//

#include "eco-system/Core/FdChannel.hpp"

#include <atomic>
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
#include <sys/select.h>
#include <sys/socket.h>
#include <sys/stat.h>
#include <unistd.h>
#endif

namespace Eco::System {

namespace {

// Posts a result for `token` that carries only `op` and `err`.
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
// Windows stub: every request completes with ENOTSUP.
// ---------------------------------------------------------------------------

struct FdChannel::State {
    int fd = -1;
};

int makeCloexecPipe(int fds[2], bool) {
    fds[0] = fds[1] = -1;
    return ENOTSUP;
}

FdChannel::FdChannel(int fd, FdChannelOptions opts) : st_(std::make_shared<State>()), origin_(opts.origin) { st_->fd = fd; }
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
// State shared by the handle (eco thread) and the channel thread.
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

    // Set by the constructor before the thread starts; unguarded after, except `fd`, which the channel thread sets
    // to -1 once the fd turns out to have been closed behind its back, and `FdChannel::fd` reads.
    std::atomic<int> fd{-1};
    uint64_t chanId = 0;
    int wakeR = -1;
    int wakeW = -1;
    bool regular = false;   // regular file: write without chunking
    bool socket = false;    // a socket: written with a non-blocking send()
    int64_t readRemaining = -1;     // bytes left under FdChannelOptions::readLimit (channel thread only)
    bool truncateOnClose = false;   // FdChannelOptions::truncateOnClose
    bool syncOnClose = false;       // FdChannelOptions::syncOnClose
    bool useSelect = false;  // poll() rejects this fd (channel thread only)

    std::mutex m;            // guards everything below
    std::deque<ReadReq> reads;
    std::deque<WriteReq> writes;
    bool closeRequested = false;
    uint64_t closeToken = 0;
    bool stop = false;       // shutdown() requested
    bool finished = false;   // the thread is done (or never started)
    int deadErr = ECANCELED; // error for requests made once finished

    // Closes the wake pipe. Runs when the last of the handle and the thread
    // lets go, so no wake() can follow.
    ~State() {
        if (wakeR >= 0) ::close(wakeR);
        if (wakeW >= 0) ::close(wakeW);
    }

    // Writes one byte to the wake pipe to interrupt the thread's poll. Does
    // nothing when there is no wake pipe.
    void wake() {
        if (wakeW < 0) return;
        char b = 1;
        ssize_t r;
        do { r = ::write(wakeW, &b, 1); } while (r < 0 && errno == EINTR);
        // EAGAIN: the pipe already holds a wake byte; fine.
    }

    // Reads the wake pipe until it is empty. Channel thread.
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

// The largest number of bytes one Read result carries.
constexpr size_t kMaxReadChunk = 1u << 20;

// Makes one read call for the oldest read request and posts its result,
// unless the call would block, in which case the request stays queued. With
// the read limit used up it posts EOF without reading. `buf` is a scratch
// buffer kept across calls. Channel thread.
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

// Makes one write call for the oldest write request. Posts its result once
// all its bytes are written or the call fails; otherwise records the progress
// and leaves it queued. Channel thread.
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
        // At most PIPE_BUF per POLLOUT: keeps a pipe write from blocking.
        if (!st.regular && chunk > PIPE_BUF) chunk = PIPE_BUF;
        ssize_t r;
        if (st.socket) {
            // Per call, so nothing shared with another holder of the socket changes (FD-03).
            int flags = MSG_DONTWAIT;
#ifdef MSG_NOSIGNAL
            flags |= MSG_NOSIGNAL;
#endif
            do { r = ::send(st.fd, data + off, chunk, flags); } while (r < 0 && errno == EINTR);
        } else {
            do { r = ::write(st.fd, data + off, chunk); } while (r < 0 && errno == EINTR);
        }
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

// Answers every queued read and write with `err`.
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

// Does what poll(pfd, n, -1) does, for POLLIN and POLLOUT only, by way of
// select(). Every fd in `pfd` must be below FD_SETSIZE. The channel thread
// switches to this when poll() answers POLLNVAL for an fd that is open, as
// macOS poll() does for some character devices.
int selectAsPoll(struct pollfd* pfd, int n) {
    fd_set rd, wr;
    FD_ZERO(&rd);
    FD_ZERO(&wr);
    int maxFd = -1;
    for (int i = 0; i < n; ++i) {
        pfd[i].revents = 0;
        if (pfd[i].fd < 0) continue;
        if (pfd[i].events & POLLIN) FD_SET(pfd[i].fd, &rd);
        if (pfd[i].events & POLLOUT) FD_SET(pfd[i].fd, &wr);
        if (pfd[i].fd > maxFd) maxFd = pfd[i].fd;
    }
    int r = ::select(maxFd + 1, &rd, &wr, nullptr, nullptr);
    if (r <= 0) return r;
    for (int i = 0; i < n; ++i) {
        if (pfd[i].fd < 0) continue;
        if (FD_ISSET(pfd[i].fd, &rd)) pfd[i].revents |= POLLIN;
        if (FD_ISSET(pfd[i].fd, &wr)) pfd[i].revents |= POLLOUT;
    }
    return r;
}

// Returns whether `fd` is not an open descriptor (fcntl fails with EBADF).
bool fdClosed(int fd) { return ::fcntl(fd, F_GETFD) == -1 && errno == EBADF; }

// Drops the channel's fd after it was found closed behind the channel's back, so the thread never touches the
// number again. Channel thread.
void forgetFd(State& st) { st.fd.store(-1, std::memory_order_relaxed); }

// The channel thread's body. Serves requests until `stop`, or until a close
// is requested and no write is queued, then finishes the channel as
// FdChannel::close and FdChannel::shutdown describe.
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
        const int fd = st.fd.load(std::memory_order_relaxed);
        if (fd < 0 && (wantRead || wantWrite)) {   // closed behind our back: nothing can be served
            failPending(st, EBADF);
            continue;
        }
        if (wantRead && st.readRemaining == 0) {   // read limit used up: EOF now
            doRead(st, buf);
            continue;
        }
        struct pollfd pfd[2];
        pfd[0].fd = (wantRead || wantWrite) ? fd : -1;   // -1: ignored by poll
        pfd[0].events = static_cast<short>((wantRead ? POLLIN : 0) | (wantWrite ? POLLOUT : 0));
        pfd[0].revents = 0;
        pfd[1].fd = st.wakeR;
        pfd[1].events = POLLIN;
        pfd[1].revents = 0;

        int n = st.useSelect ? selectAsPoll(pfd, 2) : ::poll(pfd, 2, -1);
        if (n < 0) {
            int e = errno;
            if (e == EINTR || e == EAGAIN) continue;
            if (e == EBADF && pfd[0].fd >= 0 && fdClosed(fd)) forgetFd(st);   // select on a closed fd
            failPending(st, e);
            continue;
        }
        if (pfd[1].revents & POLLIN) st.drainWake();
        if (pfd[0].fd < 0) continue;
        short rev = pfd[0].revents;
        if (rev & POLLNVAL) {
            if (fdClosed(fd)) {
                // Closed behind our back. The number is no longer ours and may already name another file, so it
                // is never used again: not polled, read, written, truncated, synced or closed (FD-01).
                forgetFd(st);
                failPending(st, EBADF);
                continue;
            }
            if (!st.useSelect && fd < FD_SETSIZE && st.wakeR < FD_SETSIZE) {
                st.useSelect = true;   // open, but not pollable (macOS devices)
                continue;
            }
            failPending(st, ENOTSUP);   // open, but neither poll nor select can wait on it (FD-05)
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
    const int fd = st.fd.load(std::memory_order_relaxed);   // -1 if it was closed behind our back
    if (closeRequested && st.truncateOnClose && fd > 2) {
        off_t pos = ::lseek(fd, 0, SEEK_CUR);
        int rc;
        if (pos < 0) rc = -1;
        else do { rc = ::ftruncate(fd, pos); } while (rc != 0 && errno == EINTR);
        if (rc != 0) closeErr = errno;
    }
    if (closeRequested && st.syncOnClose && fd > 2) {
        int rc;
        do { rc = ::fsync(fd); } while (rc != 0 && errno == EINTR);
        if (rc != 0 && closeErr == 0) closeErr = errno;
    }
    if (fd > 2) {
        // No retry on EINTR: the fd is released either way on Linux/macOS.
        if (::close(fd) != 0 && errno != EINTR && closeErr == 0) closeErr = errno;
    }
    if (closeRequested) postSimple(st.chanId, closeToken, ChannelResult::Op::Close, closeErr);
}

} // namespace

FdChannel::FdChannel(int fd, FdChannelOptions opts) : st_(std::make_shared<State>()), origin_(opts.origin) {
    st_->fd = fd;
    st_->chanId = id();
    st_->readRemaining = opts.readLimit;
    st_->truncateOnClose = opts.truncateOnClose;
    st_->syncOnClose = opts.syncOnClose;
    struct stat sb;
    if (::fstat(fd, &sb) == 0) {
        st_->regular = S_ISREG(sb.st_mode);
        st_->socket = S_ISSOCK(sb.st_mode);
    }
    // A pipe or terminal whose open file description is the channel's alone is made non-blocking, so a write
    // never blocks the thread past its wake pipe (FD-03); an inherited one is left as it is, since the flag would
    // reach every other holder of the description.
    if (opts.nonBlocking && fd > 2 && !st_->regular && !st_->socket) {
        int fl = ::fcntl(fd, F_GETFL);
        if (fl >= 0 && !(fl & O_NONBLOCK)) (void)::fcntl(fd, F_SETFL, fl | O_NONBLOCK);
    }

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
    // No thread will ever run, so the fd is closed here.
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
