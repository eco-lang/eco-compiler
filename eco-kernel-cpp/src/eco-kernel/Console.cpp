//===- Console.cpp - Console kernel module implementation -----------------===//
//
// Each Task-returning function packs what its body needs into the binding's captured value and leaves all IO to
// the body. `write` and `isTerminal` capture a Tuple2 whose slot 0 is the handle as an unboxed Int; slot 1 is the
// String for `write` and Unit for `isTerminal`. `readLine` and `readAll` capture an unboxed Int naming the read
// (`ReadKind`) in a Tuple2 of the same shape.
//
// Output goes straight to the file descriptors with `write`, or `_write` on Windows, not through a buffered stream,
// through `writeAll`, which retries a write interrupted by a signal and continues a short one.
//
// Input is read on a thread of this module's own, the stdin reader, so the eco thread never blocks on it
// (CONSOLE-04). `readLine` and `readAll` are async-park bindings: the body parks the resume closure under a Task
// hold and queues a request; the reader serves requests one at a time, in order, reading descriptor 0 raw into a
// buffer it alone owns (bytes after a line stay buffered for the next request), and queues the text read as a
// `std::string`. It never touches the Elm heap. `stdinDrain`, an async source on the eco thread, turns each result
// into a succeeding Task, resumes the parked closure with it and releases the hold. Killing a read takes its
// resume and releases its hold at once (`readKillEval`); a request not yet started is dropped, and one in progress
// still consumes what it reads, its result discarded.
//
//===----------------------------------------------------------------------===//

#include "Console.hpp"
#include "KernelHelpers.hpp"
#include "Process.hpp"
#include "TaskBinding.hpp"
#include <cerrno>
#include <condition_variable>
#include <deque>
#include <mutex>
#include <string>
#include <system_error>
#include <thread>
#include <unordered_set>

#if defined(_WIN32)
#include <io.h>
#include <stdio.h>
// The platform layer: `_eco_write` is one unbuffered write that may write fewer bytes than asked, the `_fd`
// functions give the descriptors of the three standard streams, and `_eco_isatty` says whether a descriptor is a
// terminal. On Windows `_write` takes an `unsigned int` length, so callers cap a single write at 0x7fffffff bytes.
namespace { inline int _eco_write(int fd, const void* buf, unsigned int len) {
    return ::_write(fd, buf, len);
} }
namespace { inline int _eco_read(int fd, void* buf, unsigned int len) {
    return ::_read(fd, buf, len);
} }
namespace {
inline int _eco_stdout_fd() { return ::_fileno(stdout); }
inline int _eco_stderr_fd() { return ::_fileno(stderr); }
inline int _eco_stdin_fd() { return ::_fileno(stdin); }
inline bool _eco_isatty(int fd) { return ::_isatty(fd) != 0; }
}
#else
#include <unistd.h>
// The POSIX platform layer, with the same meaning as the Windows one above.
namespace { inline ssize_t _eco_write(int fd, const void* buf, size_t len) {
    return ::write(fd, buf, len);
} }
namespace { inline ssize_t _eco_read(int fd, void* buf, size_t len) {
    return ::read(fd, buf, len);
} }
namespace {
inline int _eco_stdout_fd() { return STDOUT_FILENO; }
inline int _eco_stderr_fd() { return STDERR_FILENO; }
inline int _eco_stdin_fd() { return STDIN_FILENO; }
inline bool _eco_isatty(int fd) { return ::isatty(fd) != 0; }
}
#endif

namespace Eco::Kernel::Console {

namespace {

// Writes all `len` bytes at `data` to `fd`, retrying a write interrupted by a signal (EINTR) and continuing after a
// short one. Returns 0 when every byte was written, else the `errno` of the write that failed; bytes already
// written stay written. On Windows each `_write` is capped at 0x7fffffff bytes, its `unsigned int` length, and the
// loop goes on past that. A non-blocking descriptor's EAGAIN is a failure like any other (decision D19).
int writeAll(int fd, const char* data, size_t len) {
    while (len > 0) {
        auto n = _eco_write(fd, data,
#if defined(_WIN32)
                            static_cast<unsigned int>(len > 0x7fffffff ? 0x7fffffff : len));
#else
                            len);
#endif
        if (n < 0) {
            if (errno == EINTR) continue;
            return errno;
        }
        data += n;
        len -= static_cast<size_t>(n);
    }
    return 0;
}

// Writes the String in `captured` to the stream its handle names and returns the Task `write` documents.
// `captured` is the Tuple2 `write` builds. The String is copied out before anything allocates.
HPointer writeBody(HPointer captured) {
    int64_t handle;
    HPointer contentHP;
    {
        Tuple2* tup = static_cast<Tuple2*>(
            Elm::Allocator::instance().resolve(captured));
        handle = tup->a.i;
        contentHP = tup->b.p;
    }
    std::string str = toString(Export::encode(contentHP));

    int fd;
    if (handle == 1) {
        fd = _eco_stdout_fd();
    } else if (handle == 2) {
        fd = _eco_stderr_fd();
    } else {
        // A `spawnProcess` stdin pipe still open, or nothing: an unknown handle fails rather than losing the data.
        fd = Process::streamHandleFd(handle);
        if (fd < 0) {
            return failErrno(EBADF, "", "console write: no such handle " + std::to_string(handle));
        }
    }
    if (int err = writeAll(fd, str.data(), str.size())) {
        return failErrno(err, "", "console write failed");
    }
    return succeedUnit();
}

// ---- The stdin reader (CONSOLE-04) ----------------------------------------------------------------------------

// What a read request reads: one line (`readLine`) or everything to the end of input (`readAll`). The value is
// the unboxed Int captured by the binding.
enum class ReadKind : int64_t { Line = 0, All = 1 };

// A queued read: the token its resume is parked under, and what to read.
struct ReadRequest {
    std::uint64_t token;
    ReadKind kind;
};

// A finished read, waiting for `stdinDrain`.
struct ReadResult {
    std::uint64_t token;
    std::string text;
};

// The reader's shared state. `mu` guards `requests`, `results` and `threadStarted`; `buffered` belongs to the
// reader thread alone. Never destroyed: the reader may still be blocked in a read while the process exits.
struct StdinReader {
    std::mutex mu;
    std::condition_variable cv;
    std::deque<ReadRequest> requests;
    std::deque<ReadResult> results;
    bool threadStarted = false;
    // Bytes read from descriptor 0 but not yet handed out: what followed the last line returned.
    std::string buffered;
};

StdinReader& stdinReader() {
    static StdinReader* r = new StdinReader();
    return *r;
}

// Tokens of reads killed while in progress: their hold is released, so `stdinDrain` must not release it again
// when their result arrives. Eco thread only.
std::unordered_set<std::uint64_t>& withdrawnReads() {
    static auto* s = new std::unordered_set<std::uint64_t>();
    return *s;
}

// Reads up to `len` bytes from standard input into `buf`, retrying on EINTR. Returns the count, 0 at the end of
// input, and 0 also when standard input cannot be read (the reads never fail).
size_t readSomeStdin(char* buf, size_t len) {
    for (;;) {
        auto n = _eco_read(_eco_stdin_fd(), buf,
#if defined(_WIN32)
                           static_cast<unsigned int>(len));
#else
                           len);
#endif
        if (n >= 0) return static_cast<size_t>(n);
        if (errno != EINTR) return 0;
    }
}

// Serves `req` on the reader thread: returns one line without its `\n` (or what is left at the end of input), or
// everything to the end of input, and keeps any bytes after a line in `buffered`.
std::string serveRead(StdinReader& r, ReadKind kind) {
    char chunk[65536];
    if (kind == ReadKind::Line) {
        for (;;) {
            size_t nl = r.buffered.find('\n');
            if (nl != std::string::npos) {
                std::string line = r.buffered.substr(0, nl);
                r.buffered.erase(0, nl + 1);
                return line;
            }
            size_t n = readSomeStdin(chunk, sizeof chunk);
            if (n == 0) break;
            r.buffered.append(chunk, n);
        }
    } else {
        for (;;) {
            size_t n = readSomeStdin(chunk, sizeof chunk);
            if (n == 0) break;
            r.buffered.append(chunk, n);
        }
    }
    std::string all;
    all.swap(r.buffered);
    return all;
}

// The reader thread: serves queued requests in order, queues each result and wakes the event loop.
void readerLoop() {
    StdinReader& r = stdinReader();
    for (;;) {
        ReadRequest req;
        {
            std::unique_lock<std::mutex> lk(r.mu);
            r.cv.wait(lk, [&] { return !r.requests.empty(); });
            req = r.requests.front();
            r.requests.pop_front();
        }
        std::string text = serveRead(r, req.kind);
        {
            std::lock_guard<std::mutex> lk(r.mu);
            r.results.push_back(ReadResult{req.token, std::move(text)});
        }
        // Not under `mu`: the scheduler calls `stdinReady`, which takes `mu`, with its own lock held.
        Elm::Platform::Scheduler::instance().notifyWorkAvailableFromAsync();
    }
}

// Delivers every finished read: resumes the closure parked under its token with a Task that succeeds with the
// text, and releases the hold. A killed read (no parked closure) only has its withdrawn mark cleared. Called by the
// scheduler as an async source, on the eco thread; GC points.
void stdinDrain() {
    auto& sched = Elm::Platform::Scheduler::instance();
    StdinReader& r = stdinReader();
    for (;;) {
        ReadResult res;
        {
            std::lock_guard<std::mutex> lk(r.mu);
            if (r.results.empty()) return;
            res = std::move(r.results.front());
            r.results.pop_front();
        }
        HPointer resumeClosure = sched.takePendingResume(res.token);
        if (Elm::alloc::isNil(resumeClosure)) {
            if (withdrawnReads().erase(res.token) == 0) sched.releaseHold(res.token);
            continue;
        }
        HPointer task = Elm::alloc::unit();
        {
            Elm::StackRootGuard guard(&resumeClosure, &task);
            task = succeedString(res.text);
            Elm::Platform::Scheduler::callClosure1(resumeClosure, task);
        }
        sched.releaseHold(res.token);
    }
}

// Whether a finished read is waiting for `stdinDrain`. Does not block (`mu` is held only briefly).
bool stdinReady() {
    StdinReader& r = stdinReader();
    std::lock_guard<std::mutex> lk(r.mu);
    return !r.results.empty();
}

// Registers `stdinDrain` as a scheduler async source, once per process.
void stdinEnsureRegistered() {
    static std::once_flag flag;
    std::call_once(flag, [] {
        Elm::Platform::Scheduler::instance().registerAsyncSource(stdinDrain, stdinReady);
    });
}

// Evaluates a read's kill handle: `args[0]` is the token as raw bits and `args[1]` the `()` the handle is applied
// to. If the read has not been delivered, takes its resume and releases its hold; a request still queued is
// dropped, and one in progress is marked withdrawn so `stdinDrain` discards its result without a second release.
void* readKillEval(void* args[]) {
    const std::uint64_t token = reinterpret_cast<std::uint64_t>(args[0]);
    auto& sched = Elm::Platform::Scheduler::instance();
    if (!Elm::alloc::isNil(sched.takePendingResume(token))) {
        bool dropped = false;
        {
            StdinReader& r = stdinReader();
            std::lock_guard<std::mutex> lk(r.mu);
            for (auto it = r.requests.begin(); it != r.requests.end(); ++it) {
                if (it->token == token) {
                    r.requests.erase(it);
                    dropped = true;
                    break;
                }
            }
        }
        if (!dropped) withdrawnReads().insert(token);
        sched.releaseHold(token);
    }
    return reinterpret_cast<void*>(Export::encode(Elm::alloc::unit()));
}

// Async-park body for `readLine` and `readAll`: `captured` is the tuple ( ReadKind as an unboxed Int, unit ).
// Parks `resume` under a Task hold, queues the request for the reader (starting it on first use) and returns the
// kill handle. The result is delivered later by `stdinDrain`. When no reader thread can be started, the read
// succeeds at once with the empty string, as at the end of input.
HPointer readBody(HPointer captured, HPointer resume) {
    ReadKind kind;
    {
        Tuple2* tup = static_cast<Tuple2*>(
            Elm::Allocator::instance().resolve(captured));
        kind = static_cast<ReadKind>(tup->a.i);
    }
    auto& sched = Elm::Platform::Scheduler::instance();
    const char* site = kind == ReadKind::Line ? "Eco.Console.readLine" : "Eco.Console.readAll";
    std::uint64_t token = sched.parkResume(resume, Elm::Platform::HoldKind::Task, site);
    StdinReader& r = stdinReader();
    bool started = true;
    {
        std::lock_guard<std::mutex> lk(r.mu);
        if (!r.threadStarted) {
            try {
                std::thread(readerLoop).detach();
                r.threadStarted = true;
            } catch (const std::system_error&) {
                started = false;
            }
        }
        if (started) {
            r.requests.push_back(ReadRequest{token, kind});
        } else {
            r.results.push_back(ReadResult{token, std::string()});
        }
    }
    r.cv.notify_one();
    if (!started) sched.notifyWorkAvailableFromAsync();

    // The kill handle: a closure of arity 2 with the token captured, applied to `()` when the task is killed.
    // `p` stays valid while nothing allocates; closureCapture does not.
    HPointer kill = Elm::alloc::allocClosureK(&readKillEval, /*max_values=*/2, Elm::PK_Boxed);
    void* p = Elm::Allocator::instance().resolve(kill);
    Elm::alloc::closureCapture(p, Elm::alloc::unboxedInt(static_cast<int64_t>(token)), Elm::PK_Int);
    return kill;
}

// Makes the Task of a read of `kind`.
HPointer makeRead(ReadKind kind) {
    stdinEnsureRegistered();
    HPointer payload = Elm::alloc::tuple2(
        Elm::alloc::unboxedInt(static_cast<int64_t>(kind)),
        Elm::alloc::boxed(Elm::alloc::unit()),
        /*unboxed_mask=*/0x1);
    return Elm::Platform::makeAsyncBinding<readBody>(payload);
}

// Returns the Task `isTerminal` documents for the handle in `captured`, the Tuple2 `isTerminal` builds.
HPointer isTerminalBody(HPointer captured) {
    int64_t handle;
    {
        Tuple2* tup = static_cast<Tuple2*>(
            Elm::Allocator::instance().resolve(captured));
        handle = tup->a.i;
    }
    bool tty = false;
    if (handle == 0) {
        tty = _eco_isatty(_eco_stdin_fd());
    } else if (handle == 1) {
        tty = _eco_isatty(_eco_stdout_fd());
    } else if (handle == 2) {
        tty = _eco_isatty(_eco_stderr_fd());
    }
    return succeedBool(tty);
}

} // anonymous namespace

uint64_t write(uint64_t handle, uint64_t content) {
    HPointer contentHP = Export::decode(content);
    Elm::StackRootGuard g(&contentHP);
    HPointer payload = Elm::alloc::tuple2(
        Elm::alloc::unboxedInt(static_cast<int64_t>(handle)),
        Elm::alloc::boxed(contentHP),
        /*unboxed_mask=*/0x1);
    return Export::encode(Eco::Kernel::makeBinding<writeBody>(payload));
}

uint64_t readLine() {
    // Registration happens when the Task is made, not when it runs.
    return Export::encode(makeRead(ReadKind::Line));
}

uint64_t readAll() {
    return Export::encode(makeRead(ReadKind::All));
}

uint64_t isTerminal(uint64_t handle) {
    HPointer payload = Elm::alloc::tuple2(
        Elm::alloc::unboxedInt(static_cast<int64_t>(handle)),
        Elm::alloc::boxed(Elm::alloc::unit()),
        /*unboxed_mask=*/0x1);
    return Export::encode(Eco::Kernel::makeBinding<isTerminalBody>(payload));
}

uint64_t log(uint64_t tag, uint64_t value) {
    // Not deferred to a binding: `log` returns no Task, only `value`, so there is no Task to run the write later.
    std::string msg = toString(tag);
    msg += '\n';
    // Written to the descriptor, not through `std::cerr`, so it is not held in a stream buffer. A failed write is
    // ignored: a trace point has nowhere to report it.
    (void)writeAll(_eco_stderr_fd(), msg.data(), msg.size());
    return value;
}

} // namespace Eco::Kernel::Console
