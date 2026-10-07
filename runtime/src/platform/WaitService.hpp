//===- WaitService.hpp - Child-process-wait worker -------------------------===//
//
// Mirror of TimerService / HttpService for `Eco.Process.wait`. The worker
// thread blocks in `waitpid(-1, …, 0)`; main-thread submission registers a
// (pid, token, lane) tuple. When a child exits, the worker matches its pid
// against the registry and queues a `(token, exitCode, rawStatus)` result on
// that lane's ready queue for the lane's main-thread drain to resolve.
// Children reaped before their submit are parked in an unclaimed map.
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
#include <unordered_map>
#include <vector>

namespace Elm::Platform {

// Which consumer a wait registration belongs to. Each lane has its own ready
// queue, so eco/kernel's `Eco.Process.wait` drain and eco/system's
// ChildProcess drain never pop each other's results (plans/eco-system-library.md
// F18, Phase 2 step 5).
enum class WaitLane { EcoKernel, EcoSystem };

class WaitService {
public:
    static WaitService& instance();

    // A reaped child, routed to the lane its submit named.
    //   exitCode:  WEXITSTATUS for a normal exit; 128 + signal number for a
    //              signal death (shell convention).
    //   rawStatus: the raw waitpid status, for consumers that need to tell an
    //              exit from a signal death (WIFSIGNALED/WTERMSIG).
    struct Ready {
        std::uint64_t  token;
        int            exitCode;
        int            rawStatus;
    };

    // Main-thread submission. The caller has already spawned the child and
    // holds its pid; this records (pid, token, lane) so the worker's eventual
    // waitpid routes the result to that lane's ready queue. If the worker
    // already reaped the child before this call (a child that exits before
    // submit), its status is waiting in the unclaimed map and is queued as
    // ready immediately.
    void submit(int64_t pid, std::uint64_t resumeToken, WaitLane lane);

    // Main-thread consumer API, per lane. tryPopReady returns true and writes
    // the next result of `lane` into `out`. hasReady is the event-loop
    // predicate for that lane's drain (non-blocking).
    bool tryPopReady(WaitLane lane, Ready& out);
    bool hasReady(WaitLane lane) const;

    // Maps a raw waitpid status to the exit code reported in Ready::exitCode.
    static int exitCodeFromStatus(int rawStatus);

private:
    WaitService();
    ~WaitService() = default;

    void workerLoop();
    void pushReady(WaitLane lane, const Ready& r);

    static constexpr int kLaneCount = 2;
    static int laneIndex(WaitLane lane) { return static_cast<int>(lane); }

    struct Pending {
        int64_t        pid;
        std::uint64_t  token;
        WaitLane       lane;
    };

    // pending_ and unclaimed_ are guarded by pendingMutex_.
    mutable std::mutex          pendingMutex_;
    std::condition_variable     pendingCV_;
    std::vector<Pending>        pending_;
    // Children the worker reaped before anyone submitted their pid:
    // pid -> raw status. Checked (and consumed) by submit. Known limit: an
    // entry for a child that is never submitted stays here, and if the OS
    // later recycles that pid for a new child, a submit for the new child
    // consumes the stale status. Reaping happens only while some submit is
    // pending, so this needs an unwaited child to exit during another wait
    // and its pid to be recycled before the process ends.
    std::unordered_map<int64_t, int> unclaimed_;

    mutable std::mutex          readyMutex_;
    std::queue<Ready>           ready_[kLaneCount];
};

} // namespace Elm::Platform

#endif // ECO_PLATFORM_WAIT_SERVICE_HPP
