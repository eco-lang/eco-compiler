//===- FdChannel.hpp - ByteChannel over a file descriptor -----------------===//
//
// Many eco/system streams are a POSIX file descriptor underneath: the
// program's own stdio, the pipes to a child process, file streams and sockets.
// Reading and writing such an fd can block, and the eco thread (the thread that
// runs the Elm scheduler) must not, so this component gives each fd its own
// thread and presents it as a `ByteChannel`.
//
// An `FdChannel` owns one fd and one detached *channel thread*. The eco thread
// queues read and write requests under a mutex and wakes the thread through a
// non-blocking *wake pipe*. The thread polls the fd and the wake pipe, serves
// the oldest read and the oldest write as the fd becomes ready, and posts each
// answer with `postChannelResult`. Readiness from poll is what keeps a read
// from blocking. The fd is left in whatever blocking mode it was given unless
// `FdChannelOptions::nonBlocking` says the channel may change it; a socket is
// always written with a non-blocking `send`.
//
// The fd may be closed only once no read or write can still reach it, or an
// IO call could hit an unrelated fd that reused the number. So the channel
// thread closes it when it finishes, after its last IO call; the constructor
// closes it instead when the thread could not be started. fds 0, 1 and 2 are
// never closed: closing a stdio channel only stops serving it. The state the
// two threads share is reference counted, and the wake pipe is closed only
// when the last reference goes, so a wake-up never writes to a reused fd
// either. Destroying the handle therefore never waits for the thread.
//
// On Windows the channel is a stub: every request is answered with `ENOTSUP`,
// `shutdown` does nothing and the fd is never closed.
//
//===----------------------------------------------------------------------===//

#ifndef ECO_SYSTEM_CORE_FD_CHANNEL_HPP
#define ECO_SYSTEM_CORE_FD_CHANNEL_HPP

#include "eco-system/Core/ByteChannel.hpp"

#include <cstdint>
#include <memory>

namespace Eco::System {

/// The settings an `FdChannel` takes at construction. The defaults give a
/// channel with no read limit and nothing extra done on close.
struct FdChannelOptions {
    /// When 0 or more, the total number of bytes the channel will read; once
    /// that many have been read, every further read is answered with EOF.
    /// Negative means no limit.
    int64_t readLimit = -1;
    /// Whether `close` truncates the file to the fd's current offset before
    /// closing it. A failure becomes the Close result's error. Not done for
    /// fds 0 to 2, nor when `close` was never called.
    bool truncateOnClose = false;
    /// Whether `close` calls `fsync` on the fd before closing it, after any
    /// truncation. A failure becomes the Close result's error unless the
    /// truncation already failed. Not done for fds 0 to 2, nor when `close`
    /// was never called.
    bool syncOnClose = false;
    /// The origin, in the sense of `failureReason`, that the channel's
    /// `failureOrigin` returns. The channel keeps the pointer, so the string
    /// must outlive it; a string literal does.
    const char* origin = "file";
    /// Whether the fd's open file description belongs to this channel alone, as for a file the module opened
    /// or the parent's end of a pipe it created. The constructor then makes a pipe or terminal non-blocking, so
    /// a write cannot block the channel thread. Leave it false for a duplicate of an inherited fd (stdio):
    /// `O_NONBLOCK` is shared by every holder of the description, the parent shell included.
    bool nonBlocking = false;
};

/// A `ByteChannel` over one file descriptor, served by its own thread.
///
/// Reads are answered in request order, and so are writes; a read and a write
/// can be in progress at once. One Read result carries at most 1 MiB. A write
/// is answered once all of its bytes are written or a write fails, in which
/// case `written` counts the bytes that did go out. A non-regular fd is
/// written at most `PIPE_BUF` bytes per call, each after poll reports it
/// writable; for a pipe that is enough to keep the write from blocking. A
/// socket is written with `send(MSG_DONTWAIT)`, and a pipe or terminal made
/// non-blocking (`FdChannelOptions::nonBlocking`) cannot block either. A
/// blocking terminal or pipe shared with another process (an inherited stdio
/// fd) can still block the channel thread in `write` while the terminal's
/// buffer is full, and `shutdown` then takes effect only once it drains: a
/// known limitation, since making it non-blocking would change it for every
/// process that shares it.
///
/// If poll reports the fd invalid because it was closed behind the channel's
/// back, every pending and later read and write is answered with `EBADF`, and
/// the channel never uses the number again, not even to close it, since it may
/// already name another file. If the fd is open but neither poll nor select can
/// wait on it (macOS: a device poll rejects, numbered `FD_SETSIZE` or more),
/// pending requests are answered with `ENOTSUP`. If poll itself fails, they are
/// answered with its errno. In each case the channel goes on accepting requests.
///
/// When the channel finishes, after `shutdown` or after `close` once the
/// queued writes are done, the requests still pending are answered with
/// `ECANCELED`, and so is every later request. If the constructor could not
/// start the thread, every request is answered with that failure's errno
/// instead.
class FdChannel final : public ByteChannel {
public:
    /// Takes ownership of `fd` and starts the channel thread. Eco thread.
    ///
    /// Does not throw if the wake pipe or the thread cannot be created: the
    /// constructor closes `fd` (unless it is 0 to 2) and the channel answers
    /// every request with that errno.
    explicit FdChannel(int fd, FdChannelOptions opts = {});
    /// Calls `shutdown` unless `close` or `shutdown` was already called or the
    /// channel has finished. Does not wait for the channel thread, which
    /// finishes on its own; a requested close still completes.
    ~FdChannel() override;

    /// Queues a read of at most `maxBytes` bytes (a `maxBytes` of 0 is read
    /// as 1). Answered at once with `ECANCELED` after `close` or `shutdown`.
    void requestRead(uint64_t token, size_t maxBytes) override;
    /// Queues a write of `bytes`. Answered at once with `ECANCELED` after
    /// `close` or `shutdown`.
    void requestWrite(uint64_t token, std::string bytes) override;
    /// Asks the thread to finish once the queued writes are done: pending
    /// reads are then answered with `ECANCELED`, the options' truncation and
    /// sync are applied, and the fd is closed (unless it is 0 to 2). The
    /// Close result's error is the first of those steps to fail, or 0. A
    /// second `close`, or one after `shutdown`, is answered with `ECANCELED`.
    void close(uint64_t token) override;
    /// Asks the thread to finish at once, answering every pending request
    /// with `ECANCELED` and closing the fd (unless it is 0 to 2); if no `close`
    /// was requested, it does not truncate or sync. Returns without waiting
    /// for the thread; a read or write call already under way is let finish
    /// first.
    void shutdown() override;

    /// Returns the fd the channel was given, or -1 once it was found closed
    /// behind the channel's back. Once the channel has finished it may already
    /// be closed, and the number reused.
    int fd() const;
    const char* failureOrigin() const override { return origin_; }

    /// The queues and flags shared by the handle and the channel thread,
    /// which keep it alive between them.
    struct State;

private:
    std::shared_ptr<State> st_;
    const char* origin_;   ///< `FdChannelOptions::origin`; not owned.
};

/// Creates a pipe whose two ends are close-on-exec, and non-blocking if
/// `nonBlocking`, storing the read end in `fds[0]` and the write end in
/// `fds[1]`. Returns 0, or the errno of the failure.
///
/// Outside Linux the flags are set after the pipe is made, so a child
/// spawned in between by another thread would inherit both ends; the
/// pipe is close-on-exec for every child only if children are spawned from the
/// calling thread. On Windows it returns `ENOTSUP`.
int makeCloexecPipe(int fds[2], bool nonBlocking);

} // namespace Eco::System

#endif // ECO_SYSTEM_CORE_FD_CHANNEL_HPP
