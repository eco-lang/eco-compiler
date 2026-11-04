// FdChannel unit tests of eco-system-core-test (system-kernel-cpp/src/eco-system/Core/FdChannel.cpp), next
// to the ones in EcoSystemCoreTest.cpp.
//
// FD-01: when poll answered POLLNVAL for the channel's fd and fcntl said the fd was closed (someone
//   closed it behind the channel's back), FdChannel failed the pending requests with EBADF but
//   kept `st.fd`; its finish block later ::close()d that number, which by then may name an
//   unrelated file. The test reuses the number deterministically with dup2 and checks that the
//   channel's close leaves it open. Fixed: the channel forgets the fd.
// FD-03: doWrite caps a non-regular write at PIPE_BUF so a write "cannot block", but a blocking
//   pty slave reports POLLOUT whenever any room is left (Linux has no chars_in_buffer for ptys),
//   so a PIPE_BUF write blocked inside write() once the buffer was nearly full. The channel thread
//   then never saw its wake pipe, and shutdown() cancelled nothing. Linux only. Fixed (D26): a
//   channel that owns its fd's description (`FdChannelOptions::nonBlocking`, as FileSystem streams
//   and child pipes do) makes a pipe or terminal non-blocking; the test's fd is such an fd.
// FD-05 (macOS only) has no test here: Linux poll never answers POLLNVAL for an open fd.

#include "EcoSystemCoreTest.hpp"

#include "eco-system/Core/ByteChannel.hpp"
#include "eco-system/Core/FdChannel.hpp"

#include <atomic>
#include <cerrno>
#include <chrono>
#include <cstdio>
#include <cstdlib>
#include <string>
#include <thread>
#include <vector>

#include <fcntl.h>
#include <poll.h>
#include <termios.h>
#include <unistd.h>

using namespace Eco::System;

namespace {

using Clock = std::chrono::steady_clock;

// Pops up to `n` results of channel `chanId` within `timeoutMs` (results of other channels are
// dropped: nothing else runs while an area check runs).
std::vector<ChannelResult> popFor(uint64_t chanId, size_t n, int timeoutMs) {
    std::vector<ChannelResult> out;
    auto deadline = Clock::now() + std::chrono::milliseconds(timeoutMs);
    while (out.size() < n && Clock::now() < deadline) {
        ChannelResult r;
        if (tryPopChannelResult(r)) {
            if (r.channelId == chanId) out.push_back(std::move(r));
        } else {
            std::this_thread::sleep_for(std::chrono::milliseconds(1));
        }
    }
    return out;
}

// FD-01: after POLLNVAL on a closed fd, the channel must not close the fd number again.
void testFdChannelReusedFdNotClosed() {
    std::printf("fd-channel/does-not-close-a-reused-fd-number-after-pollnval\n");
    int p[2];
    CHECK(makeCloexecPipe(p, false) == 0);
    const int oldFd = p[0];
    auto* r = new FdChannel(oldFd);
    const uint64_t cid = r->id();
    r->requestRead(70, 10);   // no data: the channel thread blocks in poll on oldFd
    std::this_thread::sleep_for(std::chrono::milliseconds(50));

    ::close(oldFd);           // behind the channel's back
    r->requestRead(71, 10);   // wakes the thread: re-poll gives POLLNVAL, fcntl gives EBADF
    auto failed = popFor(cid, 2, 2000);
    CHECK_MSG(failed.size() == 2, "FD-01 precondition: both reads fail after the close, got " +
                                      std::to_string(failed.size()));
    for (auto& x : failed) CHECK_MSG(x.err == EBADF, "FD-01 read err " + std::to_string(x.err));

    // Reuse the number for an unrelated file.
    // The lowest free number is usually oldFd itself, so the open may already reuse it; dup2 only otherwise
    // (dup2 onto itself and closing `dn` would close the reused number again).
    int dn = ::open("/dev/null", O_RDONLY | O_CLOEXEC);
    CHECK(dn >= 0);
    if (dn != oldFd) {
        CHECK(::dup2(dn, oldFd) == oldFd);
        ::close(dn);
    }

    r->close(72);
    auto closed = popFor(cid, 1, 2000);
    CHECK_MSG(closed.size() == 1 && closed[0].op == ChannelResult::Op::Close,
              "FD-01 precondition: the Close result arrives");
    std::this_thread::sleep_for(std::chrono::milliseconds(20));

    errno = 0;
    const bool stillOpen = ::fcntl(oldFd, F_GETFD) != -1;
    CHECK_MSG(stillOpen, std::string("FD-01: after the channel's close, fd ") + std::to_string(oldFd) +
                             " (reused for /dev/null) is closed (errno " + std::to_string(errno) + ")");
    if (stillOpen) ::close(oldFd);
    ::close(p[1]);
    delete r;
}

#if defined(__linux__)
// FD-03: a PIPE_BUF write to a blocking pty slave blocks in write(), so shutdown() is not seen.
void testFdChannelTtyWriteDoesNotStall() {
    std::printf("fd-channel/write-to-a-full-blocking-pty-shutdown-still-cancels\n");
    int master = ::posix_openpt(O_RDWR | O_NOCTTY | O_CLOEXEC);
    CHECK(master >= 0);
    if (master < 0) return;
    CHECK(::grantpt(master) == 0 && ::unlockpt(master) == 0);
    const char* name = ::ptsname(master);
    CHECK(name != nullptr);
    if (name == nullptr) { ::close(master); return; }
    int slave = ::open(name, O_RDWR | O_NOCTTY | O_CLOEXEC);
    CHECK(slave >= 0);
    if (slave < 0) { ::close(master); return; }
    struct termios tio;
    if (::tcgetattr(slave, &tio) == 0) {
        ::cfmakeraw(&tio);
        ::tcsetattr(slave, TCSANOW, &tio);
    }

    // A description of the channel's own (reopened from the slave's name), as a FileSystem stream has; the
    // test's own `slave` fd keeps its blocking description.
    FdChannelOptions own;
    own.nonBlocking = true;
    auto* w = new FdChannel(::open(name, O_RDWR | O_NOCTTY | O_CLOEXEC), own);
    const uint64_t cid = w->id();
    w->requestWrite(80, std::string(1 << 20, 'x'));   // nobody reads the master
    std::this_thread::sleep_for(std::chrono::milliseconds(300));

    // Precondition: the write started (the master has data) and has not finished.
    struct pollfd mp{master, POLLIN, 0};
    CHECK_MSG(::poll(&mp, 1, 0) == 1 && (mp.revents & POLLIN), "FD-03 precondition: data reached the pty");
    ChannelResult early;
    bool earlyDone = false;
    while (tryPopChannelResult(early)) {
        if (early.channelId == cid) earlyDone = true;
    }
    CHECK_MSG(!earlyDone, "FD-03 precondition: the 1 MiB write cannot complete unread");

    auto t0 = Clock::now();
    w->shutdown();
    auto res = popFor(cid, 1, 2000);
    auto ms = std::chrono::duration_cast<std::chrono::milliseconds>(Clock::now() - t0).count();
    const bool defect = res.empty();
    CHECK_MSG(!defect, defect ? std::string("FD-03: no result 2000 ms after shutdown(): the channel thread is "
                                            "blocked in write() on the full pty")
                              : "write result (err " + std::to_string(res[0].err) + ", written " +
                                    std::to_string(res[0].written) + ") after " + std::to_string(ms) + " ms");

    // Unblock the channel thread in either outcome: drain the master until its result arrives.
    if (defect) {
        std::atomic<bool> stopDrain{false};
        std::thread drain([&] {
            char buf[65536];
            while (!stopDrain.load()) {
                struct pollfd d{master, POLLIN, 0};
                if (::poll(&d, 1, 20) == 1 && (d.revents & POLLIN)) {
                    if (::read(master, buf, sizeof buf) <= 0) break;
                }
            }
        });
        auto late = popFor(cid, 1, 20000);
        stopDrain = true;
        drain.join();
        CHECK_MSG(late.size() == 1, "FD-03: the write result arrives once the pty is drained");
        if (late.empty()) {
            std::fprintf(stderr, "FD-03: channel thread still blocked; leaking the channel\n");
            return;
        }
    }
    delete w;
    ::close(slave);
    ::close(master);
}
#endif

}  // namespace

void runFdChannelTests() {
    testFdChannelReusedFdNotClosed();
#if defined(__linux__)
    testFdChannelTtyWriteDoesNotStall();
#endif
}

void registerFdChannelScenarios() {}
