//===- FdChannel.hpp - ByteChannel over a file descriptor -----------------===//
//
// plans/eco-system-library.md §3.4. One FdChannel per fd-backed stream
// (stdio, child pipes, file streams, sockets). It owns a detached thread
// that polls {fd, wake pipe}; requests are queued POD; results go to the
// channel-results queue (ByteChannel.hpp).
//
// Ownership and fd safety:
//   * The channel takes ownership of `fd`. ONLY the channel thread closes it,
//     and only once it has finished (so no read/write can hit a reused fd
//     number). fds 0, 1 and 2 are never closed: closing a stdio channel only
//     stops polling.
//   * The wake pipe is O_CLOEXEC and non-blocking; it is closed when the
//     last reference to the shared state goes (handle and thread), so a
//     wake-up write can never reach a reused fd number.
//   * EINTR is retried everywhere. Writes to non-regular fds go in chunks of
//     at most PIPE_BUF after POLLOUT, so a write does not block shutdown().
//   * Destroying the handle: if close() was requested the thread finishes
//     the close; otherwise the destructor calls shutdown().
//
// Windows: a stub whose requests complete with ENOTSUP (§1).
//
// Templates used: none (POD only, G1).
//
//===----------------------------------------------------------------------===//

#ifndef ECO_SYSTEM_CORE_FD_CHANNEL_HPP
#define ECO_SYSTEM_CORE_FD_CHANNEL_HPP

#include "eco-system/Core/ByteChannel.hpp"

#include <memory>

namespace Eco::System {

class FdChannel final : public ByteChannel {
public:
    // Main thread. Takes ownership of `fd` (see above).
    explicit FdChannel(int fd);
    ~FdChannel() override;

    void requestRead(uint64_t token, size_t maxBytes) override;
    void requestWrite(uint64_t token, std::string bytes) override;
    void close(uint64_t token) override;
    void shutdown() override;

    int fd() const;

    struct State;   // shared with the channel thread

private:
    std::shared_ptr<State> st_;
};

// Creates a pipe whose ends are O_CLOEXEC (pipe2 on Linux; pipe + fcntl
// elsewhere, race-free because children are spawned from the main thread
// only, §3.4). Returns 0 or the errno. Not available on Windows (ENOTSUP).
int makeCloexecPipe(int fds[2], bool nonBlocking);

} // namespace Eco::System

#endif // ECO_SYSTEM_CORE_FD_CHANNEL_HPP
