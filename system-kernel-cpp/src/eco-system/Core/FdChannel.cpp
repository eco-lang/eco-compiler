//===- FdChannel.cpp - ByteChannel over a file descriptor -----------------===//
//
// The handle and the detached channel thread each hold a shared_ptr to one
// `State`. Requests are pushed and flags set under `State::m` by the eco
// thread, which then writes a byte to the wake pipe; the thread snapshots what
// it wants under the lock, polls without it, and pops a request only after
// its IO call, so a request's data stays put while the call runs. On Windows
// the same requests are served by blocking calls on a reader thread and a
// writer thread instead, which wait on a condition variable, not a pipe.
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
#else
#include <chrono>
#include <condition_variable>
#ifndef WIN32_LEAN_AND_MEAN
#define WIN32_LEAN_AND_MEAN
#endif
#ifndef NOMINMAX
#define NOMINMAX
#endif
#include <windows.h>
#include <io.h>
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
// Windows: blocking calls on a reader thread and a writer thread.
//
// The handle and both threads share one `State`. The writer thread serves the
// writes and, as on POSIX, finishes the channel after `shutdown`, or after
// `close` once the queued writes are done. The reader thread serves the reads
// until the channel has finished. Each takes the oldest request under the lock,
// makes its blocking call without it, and pops the request after the call,
// unless the channel finished meanwhile: the finish then answered it with
// ECANCELED and the call's result is dropped.
// ---------------------------------------------------------------------------

int errnoFromWin32Error(unsigned long code) {
    switch (code) {
    case ERROR_FILE_NOT_FOUND:
    case ERROR_PATH_NOT_FOUND:
    case ERROR_INVALID_DRIVE:
    case ERROR_BAD_NETPATH:
    case ERROR_BAD_NET_NAME:
    case ERROR_INVALID_NAME:
    case ERROR_BAD_PATHNAME:
        return ENOENT;
    case ERROR_FILE_EXISTS:
    case ERROR_ALREADY_EXISTS:
        return EEXIST;
    case ERROR_ACCESS_DENIED:
    case ERROR_SHARING_VIOLATION:
    case ERROR_LOCK_VIOLATION:
        return EACCES;
    case ERROR_DIR_NOT_EMPTY:
        return ENOTEMPTY;
    case ERROR_DIRECTORY:
        return ENOTDIR;
    case ERROR_DISK_FULL:
    case ERROR_HANDLE_DISK_FULL:
        return ENOSPC;
    case ERROR_TOO_MANY_OPEN_FILES:
        return EMFILE;
    case ERROR_INVALID_HANDLE:
        return EBADF;
    case ERROR_NOT_SAME_DEVICE:
        return EXDEV;
    case ERROR_FILENAME_EXCED_RANGE:
        return ENAMETOOLONG;
    case ERROR_BROKEN_PIPE:
    case ERROR_NO_DATA:
        return EPIPE;
    case ERROR_OPERATION_ABORTED:
        return ECANCELED;
    case ERROR_NOT_SUPPORTED:
    case ERROR_CALL_NOT_IMPLEMENTED:
        return ENOTSUP;
    case ERROR_INVALID_PARAMETER:
        return EINVAL;
    case ERROR_WRITE_PROTECT:
        return EROFS;
    case ERROR_CANT_RESOLVE_FILENAME:
        return ELOOP;
    case ERROR_NOT_ENOUGH_MEMORY:
    case ERROR_OUTOFMEMORY:
        return ENOMEM;
    default:
        return 0;
    }
}

struct FdChannel::State {
    struct ReadReq {
        uint64_t token;
        size_t maxBytes;
    };
    struct WriteReq {
        uint64_t token;
        std::string bytes;
    };

    // Set by the constructor before the threads start; unguarded after.
    int fd = -1;                        // the CRT fd; 0 to 2 are stdio
    HANDLE h = INVALID_HANDLE_VALUE;    // its OS handle, not owned: closing `fd` closes it
    bool console = false;               // `h` is a console: ReadConsoleW / WriteConsoleW
    uint64_t chanId = 0;
    bool truncateOnClose = false;       // FdChannelOptions::truncateOnClose
    bool syncOnClose = false;           // FdChannelOptions::syncOnClose

    int64_t readRemaining = -1;         // reader thread only: bytes left under FdChannelOptions::readLimit
    std::string readCarry;              // reader thread only: console text converted but not yet returned
    wchar_t pendingHigh = 0;            // reader thread only: a high surrogate whose low half is still to come
    std::string writeCarry;             // writer thread only: an incomplete UTF-8 sequence ending a console write

    std::mutex m;                       // guards everything below
    std::condition_variable cv;         // signalled on every change below
    std::deque<ReadReq> reads;
    std::deque<WriteReq> writes;
    bool closeRequested = false;
    uint64_t closeToken = 0;
    bool stop = false;                  // shutdown() requested
    bool finished = false;              // the channel is finished (or never started)
    int deadErr = ECANCELED;            // error for requests made once finished
    bool readerInCall = false;          // the reader thread is in a blocking read call
    bool readerExited = true;           // the reader thread is not running (set false when it starts)
    HANDLE readerThread = nullptr;      // a real handle to the reader thread, for CancelSynchronousIo

    ~State() {
        if (readerThread) ::CloseHandle(readerThread);
    }
};

int makeCloexecPipe(int fds[2], bool) {
    fds[0] = fds[1] = -1;
    return ENOTSUP;
}

namespace {

using State = FdChannel::State;

// The largest number of bytes one Read result carries.
constexpr size_t kMaxReadChunk = 1u << 20;
// The most UTF-16 units one console call reads or writes.
constexpr DWORD kConsoleChunk = 8192;

// Returns the errno for Win32 error `code`, or EIO when none fits.
int errnoOr(DWORD code) {
    int e = errnoFromWin32Error(code);
    return e ? e : EIO;
}

// Returns the OS handle of `fd`: the process's standard handle for 0 to 2, and otherwise the CRT's. Returns
// INVALID_HANDLE_VALUE when there is none.
HANDLE osHandleOf(int fd) {
    HANDLE h = INVALID_HANDLE_VALUE;
    if (fd == 0) h = ::GetStdHandle(STD_INPUT_HANDLE);
    else if (fd == 1) h = ::GetStdHandle(STD_OUTPUT_HANDLE);
    else if (fd == 2) h = ::GetStdHandle(STD_ERROR_HANDLE);
    else if (fd > 2) h = reinterpret_cast<HANDLE>(::_get_osfhandle(fd));
    return h == nullptr ? INVALID_HANDLE_VALUE : h;   // GetStdHandle gives NULL when there is no such handle
}

// Appends UTF-16 `w[0..n)` to `out` as UTF-8; unpaired surrogates become U+FFFD.
void appendUtf8(std::string& out, const wchar_t* w, int n) {
    if (n <= 0) return;
    int len = ::WideCharToMultiByte(CP_UTF8, 0, w, n, nullptr, 0, nullptr, nullptr);
    if (len <= 0) return;
    size_t at = out.size();
    out.resize(at + static_cast<size_t>(len));
    ::WideCharToMultiByte(CP_UTF8, 0, w, n, &out[at], len, nullptr, nullptr);
}

// Makes one read call on a console for up to `maxBytes` bytes of UTF-8, into `out`. Text converted beyond
// `maxBytes` waits in `readCarry` for the next read. Sets `eof` when the input begins with Ctrl+Z, as at an
// end of input typed on Windows. Returns 0 or an errno. Reader thread, without the lock.
int consoleRead(State& st, size_t maxBytes, std::string& out, bool& eof) {
    while (st.readCarry.empty()) {
        wchar_t wbuf[kConsoleChunk + 1];
        DWORD start = 0;
        if (st.pendingHigh) {
            wbuf[0] = st.pendingHigh;
            st.pendingHigh = 0;
            start = 1;
        }
        DWORD got = 0;
        if (!::ReadConsoleW(st.h, wbuf + start, kConsoleChunk, &got, nullptr)) return errnoOr(::GetLastError());
        if (got == 0) {
            // Nothing read, as after Ctrl+C; read again unless the channel finished meanwhile.
            std::lock_guard<std::mutex> lk(st.m);
            if (st.finished) return ECANCELED;
            continue;
        }
        if (start == 0 && wbuf[0] == L'\x1a') {
            eof = true;
            return 0;
        }
        DWORD n = start + got;
        if (wbuf[n - 1] >= 0xD800 && wbuf[n - 1] <= 0xDBFF) st.pendingHigh = wbuf[--n];
        appendUtf8(st.readCarry, wbuf, static_cast<int>(n));
    }
    size_t take = st.readCarry.size() < maxBytes ? st.readCarry.size() : maxBytes;
    out.assign(st.readCarry, 0, take);
    st.readCarry.erase(0, take);
    return 0;
}

// Makes one read call for up to `maxBytes` bytes into `out`, setting `eof` at the end of the input. Returns 0
// or an errno. Reader thread, without the lock.
int readOnce(State& st, size_t maxBytes, std::vector<char>& buf, std::string& out, bool& eof) {
    if (st.h == INVALID_HANDLE_VALUE) return EBADF;
    if (st.console) return consoleRead(st, maxBytes, out, eof);
    if (buf.size() < maxBytes) buf.resize(maxBytes);
    DWORD got = 0;
    if (!::ReadFile(st.h, buf.data(), static_cast<DWORD>(maxBytes), &got, nullptr)) {
        DWORD code = ::GetLastError();
        if (code == ERROR_BROKEN_PIPE || code == ERROR_HANDLE_EOF) {   // the writing end closed: EOF
            eof = true;
            return 0;
        }
        return errnoOr(code);
    }
    if (got == 0) eof = true;
    else out.assign(buf.data(), got);
    return 0;
}

// Returns how many bytes at the end of `s` form an incomplete UTF-8 sequence, 0 to 3.
size_t incompleteUtf8Tail(const std::string& s) {
    size_t n = s.size();
    for (size_t back = 1; back <= 3 && back <= n; ++back) {
        unsigned char c = static_cast<unsigned char>(s[n - back]);
        if ((c & 0xC0) == 0x80) continue;   // continuation byte: keep looking for the lead
        size_t need = (c & 0xE0) == 0xC0 ? 2 : (c & 0xF0) == 0xE0 ? 3 : (c & 0xF8) == 0xF0 ? 4 : 1;
        return back < need ? back : 0;
    }
    return 0;
}

// Writes all `len` bytes at `data` to a console as UTF-16, keeping an incomplete trailing UTF-8 sequence in
// `writeCarry` for the next write. Returns 0 or an errno. Writer thread, without the lock.
int consoleWrite(State& st, const char* data, size_t len) {
    std::string text = std::move(st.writeCarry);
    st.writeCarry.clear();
    text.append(data, len);
    size_t tail = incompleteUtf8Tail(text);
    st.writeCarry.assign(text, text.size() - tail, tail);
    text.resize(text.size() - tail);
    if (text.empty()) return 0;
    std::wstring w;
    // Converted in pieces, so the count fits an int.
    for (size_t at = 0; at < text.size();) {
        size_t piece = text.size() - at;
        if (piece > (1u << 28)) {
            piece = 1u << 28;
            while (piece > 0 && (static_cast<unsigned char>(text[at + piece]) & 0xC0) == 0x80) --piece;
        }
        int wl = ::MultiByteToWideChar(CP_UTF8, 0, text.data() + at, static_cast<int>(piece), nullptr, 0);
        if (wl <= 0) return errnoOr(::GetLastError());
        size_t wat = w.size();
        w.resize(wat + static_cast<size_t>(wl));
        ::MultiByteToWideChar(CP_UTF8, 0, text.data() + at, static_cast<int>(piece), &w[wat], wl);
        at += piece;
    }
    for (size_t off = 0; off < w.size();) {
        DWORD chunk = static_cast<DWORD>(w.size() - off < kConsoleChunk ? w.size() - off : kConsoleChunk);
        // Never split a surrogate pair between two calls.
        if (chunk > 1 && off + chunk < w.size() && w[off + chunk - 1] >= 0xD800 && w[off + chunk - 1] <= 0xDBFF)
            --chunk;
        DWORD put = 0;
        if (!::WriteConsoleW(st.h, w.data() + off, chunk, &put, nullptr)) return errnoOr(::GetLastError());
        if (put == 0) return EIO;
        off += put;
    }
    return 0;
}

// Writes all `len` bytes at `data`, setting `written` to how many went out. Returns 0 or an errno. Writer
// thread, without the lock.
int writeAllWin(State& st, const char* data, size_t len, size_t& written) {
    written = 0;
    if (st.h == INVALID_HANDLE_VALUE) return EBADF;
    if (st.console) {
        int e = consoleWrite(st, data, len);
        if (e == 0) written = len;
        return e;
    }
    while (written < len) {
        size_t rest = len - written;
        DWORD chunk = static_cast<DWORD>(rest > (1u << 30) ? (1u << 30) : rest);
        DWORD put = 0;
        if (!::WriteFile(st.h, data + written, chunk, &put, nullptr)) return errnoOr(::GetLastError());
        if (put == 0) return EIO;
        written += put;
    }
    return 0;
}

// The reader thread's body: serves reads in order until the channel finishes.
void readerThreadMain(std::shared_ptr<State> sp) {
    State& st = *sp;
    HANDLE self = nullptr;
    ::DuplicateHandle(::GetCurrentProcess(), ::GetCurrentThread(), ::GetCurrentProcess(), &self, 0, FALSE,
                      DUPLICATE_SAME_ACCESS);
    {
        std::lock_guard<std::mutex> lk(st.m);
        st.readerThread = self;
    }
    std::vector<char> buf;
    for (;;) {
        uint64_t token;
        size_t maxBytes;
        {
            std::unique_lock<std::mutex> lk(st.m);
            st.cv.wait(lk, [&] { return st.finished || !st.reads.empty(); });
            if (st.finished) break;
            token = st.reads.front().token;
            maxBytes = st.reads.front().maxBytes;
            st.readerInCall = true;
        }
        if (maxBytes == 0) maxBytes = 1;
        if (maxBytes > kMaxReadChunk) maxBytes = kMaxReadChunk;
        if (st.readRemaining >= 0 && maxBytes > static_cast<uint64_t>(st.readRemaining))
            maxBytes = static_cast<size_t>(st.readRemaining);

        ChannelResult res;
        res.channelId = st.chanId;
        res.token = token;
        res.op = ChannelResult::Op::Read;
        bool eof = false;
        int e = 0;
        if (maxBytes == 0) eof = true;   // the read limit is used up
        else e = readOnce(st, maxBytes, buf, res.bytes, eof);
        if (e) {
            res.err = e;
            res.bytes.clear();
        } else if (eof) {
            res.eof = true;
            res.bytes.clear();
        } else if (st.readRemaining >= 0) {
            st.readRemaining -= static_cast<int64_t>(res.bytes.size());
        }
        {
            std::lock_guard<std::mutex> lk(st.m);
            st.readerInCall = false;
            if (st.finished) break;   // the finish answered this read already
            st.reads.pop_front();
        }
        postChannelResult(std::move(res));
    }
    {
        std::lock_guard<std::mutex> lk(st.m);
        st.readerInCall = false;
        st.readerExited = true;
    }
    st.cv.notify_all();
}

// The writer thread's body. Serves writes until `stop`, or until a close is requested and no write is queued,
// then finishes the channel as FdChannel::close and FdChannel::shutdown describe.
void writerThreadMain(std::shared_ptr<State> sp) {
    State& st = *sp;
    for (;;) {
        uint64_t token;
        const char* data;
        size_t len;
        {
            std::unique_lock<std::mutex> lk(st.m);
            st.cv.wait(lk, [&] { return st.stop || st.closeRequested || !st.writes.empty(); });
            if (st.stop) break;
            if (st.closeRequested && st.writes.empty()) break;
            // Only this thread pops, so the front element and its bytes stay put during the call.
            auto& w = st.writes.front();
            token = w.token;
            data = w.bytes.data();
            len = w.bytes.size();
        }
        ChannelResult res;
        res.channelId = st.chanId;
        res.token = token;
        res.op = ChannelResult::Op::Write;
        res.err = writeAllWin(st, data, len, res.written);
        {
            std::lock_guard<std::mutex> lk(st.m);
            st.writes.pop_front();
        }
        postChannelResult(std::move(res));
    }

    // Finish: cancel what is left, close the fd (never 0-2), report the close.
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
    st.cv.notify_all();   // the reader thread exits once out of its call
    for (auto& r : reads) postSimple(st.chanId, r.token, ChannelResult::Op::Read, ECANCELED);
    for (auto& w : writes) postSimple(st.chanId, w.token, ChannelResult::Op::Write, ECANCELED);

    int closeErr = 0;
    if (st.fd > 2) {
        // The fd is closed only once the reader thread can no longer use its handle: a blocking read is
        // cancelled, again every 20 ms in case the cancel came just before the call began.
        std::unique_lock<std::mutex> lk(st.m);
        while (!st.readerExited) {
            if (st.readerInCall && st.readerThread) ::CancelSynchronousIo(st.readerThread);
            st.cv.wait_for(lk, std::chrono::milliseconds(20));
        }
    }
    if (closeRequested && st.truncateOnClose && st.fd > 2 && st.h != INVALID_HANDLE_VALUE) {
        if (!::SetEndOfFile(st.h)) closeErr = errnoOr(::GetLastError());   // at the file pointer
    }
    if (closeRequested && st.syncOnClose && st.fd > 2 && st.h != INVALID_HANDLE_VALUE) {
        if (!::FlushFileBuffers(st.h) && closeErr == 0) closeErr = errnoOr(::GetLastError());
    }
    if (st.fd > 2) {
        if (::_close(st.fd) != 0 && closeErr == 0) closeErr = errno;
    }
    if (closeRequested) postSimple(st.chanId, closeToken, ChannelResult::Op::Close, closeErr);
}

} // namespace

FdChannel::FdChannel(int fd, FdChannelOptions opts) : st_(std::make_shared<State>()), origin_(opts.origin) {
    st_->fd = fd;
    st_->h = osHandleOf(fd);
    st_->chanId = id();
    st_->readRemaining = opts.readLimit;
    st_->truncateOnClose = opts.truncateOnClose;
    st_->syncOnClose = opts.syncOnClose;
    DWORD mode = 0;
    st_->console = st_->h != INVALID_HANDLE_VALUE && ::GetFileType(st_->h) == FILE_TYPE_CHAR &&
                   ::GetConsoleMode(st_->h, &mode) != 0;

    int e = 0;
    bool readerStarted = false;
    try {
        st_->readerExited = false;
        std::thread(readerThreadMain, st_).detach();
        readerStarted = true;
        std::thread(writerThreadMain, st_).detach();
        return;
    } catch (const std::system_error& se) {
        e = se.code().value() ? se.code().value() : EAGAIN;
    }
    // No writer thread will run, so the channel is finished here. A reader thread that did start has no read to
    // serve, so it never touches the handle, and leaves once it sees `finished`.
    {
        std::lock_guard<std::mutex> lk(st_->m);
        st_->finished = true;
        st_->deadErr = e;
        if (!readerStarted) st_->readerExited = true;
    }
    st_->cv.notify_all();
    if (fd > 2) ::_close(fd);
}

FdChannel::~FdChannel() {
    bool closing;
    {
        std::lock_guard<std::mutex> lk(st_->m);
        closing = st_->closeRequested || st_->finished || st_->stop;
    }
    if (!closing) shutdown();   // otherwise the writer thread finishes on its own
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
    else st_->cv.notify_all();
}

void FdChannel::requestWrite(uint64_t token, std::string bytes) {
    int err = 0;
    {
        std::lock_guard<std::mutex> lk(st_->m);
        if (st_->finished) err = st_->deadErr;
        else if (st_->stop || st_->closeRequested) err = ECANCELED;
        else st_->writes.push_back(State::WriteReq{token, std::move(bytes)});
    }
    if (err) postSimple(id(), token, ChannelResult::Op::Write, err);
    else st_->cv.notify_all();
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
    else st_->cv.notify_all();
}

void FdChannel::shutdown() {
    {
        std::lock_guard<std::mutex> lk(st_->m);
        if (st_->stop || st_->finished) return;
        st_->stop = true;
    }
    st_->cv.notify_all();
}

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
