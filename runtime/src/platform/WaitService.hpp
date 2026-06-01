//===- WaitService.hpp - Child-process-wait worker -------------------------===//
//
// Mirror of TimerService / HttpService for `Eco.Process.wait`. The worker
// thread blocks in `waitpid(-1, …, 0)`; main-thread submission registers a
// (pid, token) tuple. When a child exits, the worker matches its pid against
// the registry and queues a `(token, exitCode)` pair for the main-thread
// drain to resolve.
//
// The drain registers itself as an async source on the Scheduler (see
// `Scheduler::registerAsyncSource`) and runs inside `processReadyAsync` so
// HPointer / GC interaction stays single-threaded.
//
// Owned by `Eco.Process.wait` in eco-kernel-cpp; placed in runtime/ so the
// Scheduler integration shares the same layering as TimerService and
// HttpService.
//
//===----------------------------------------------------------------------===//

#ifndef ECO_PLATFORM_WAIT_SERVICE_HPP
#define ECO_PLATFORM_WAIT_SERVICE_HPP

#include <atomic>
#include <condition_variable>
#include <cstdint>
#include <mutex>
#include <queue>
#include <thread>
#include <vector>

namespace Elm::Platform {

class WaitService {
public:
    static WaitService& instance();

    // Main-thread submission. The caller has already forked the child and
    // holds the kernel-supplied pid; this records (pid, token) so the
    // worker's eventual waitpid can route the exit code to the right
    // pending-resume token.
    void submit(int64_t pid, std::uint64_t resumeToken);

    // Main-thread consumer API. tryPopResult returns true and writes the
    // next available (token, exitCode) into the out params. hasReady is the
    // event-loop predicate.
    bool tryPopResult(std::uint64_t& outToken, int& outExitCode);
    bool hasReady() const;

private:
    WaitService();
    ~WaitService() = default;

    void workerLoop();

    struct Pending {
        int64_t        pid;
        std::uint64_t  token;
    };
    struct Ready {
        std::uint64_t  token;
        int            exitCode;
    };

    mutable std::mutex          pendingMutex_;
    std::condition_variable     pendingCV_;
    std::vector<Pending>        pending_;

    mutable std::mutex          readyMutex_;
    std::queue<Ready>           ready_;
};

} // namespace Elm::Platform

#endif // ECO_PLATFORM_WAIT_SERVICE_HPP
