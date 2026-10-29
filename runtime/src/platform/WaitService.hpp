//===- WaitService.hpp - Child-process-wait worker -------------------------===//
//
// A process learns that a child has exited by waiting for it, and the wait
// blocks. This component does that waiting on threads of its own, so the
// thread that asks never waits for the child, and hands each exit back as a
// queued result that the asker collects later.
//
// A caller that has started a child submits the child's pid together with a
// token and a lane. The token is an opaque number the caller chooses to
// recognise the result by. The lane says which consumer the result is for:
// each lane has its own ready queue, so a consumer that pops only its own lane
// never takes another consumer's results. When the child exits, a `Ready`
// carrying the token and the child's exit status is queued on that lane and
// the `Scheduler` event loop is woken with
// `Scheduler::notifyWorkAvailableFromAsync`. WaitService registers nothing
// with the scheduler; a consumer polls its lane with `hasReady` and drains it
// with `tryPopReady`.
//
// How the waiting is done differs by platform.
//
// On POSIX one worker thread calls `waitpid(-1, ...)`, which reaps whichever
// child of the process exits next, and does so only while at least one submit
// is outstanding. A child may therefore be reaped before its own submit
// arrives, or it may be a child nobody will ever submit. Its status is then
// kept in an unclaimed map, keyed by pid, and a later submit for that pid
// takes it from there and is ready at once.
//
// On Windows the worker thread starts one further thread per submitted child,
// which blocks on that child's process handle, if one can be had. There is no
// unclaimed map, because each wait is for one named process.
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

/// The consumer a submitted wait belongs to. Each lane has its own ready queue,
/// and a result is queued only on the lane its submit named. The enumerator's
/// value indexes the per-lane queues, so the values must stay 0-based and
/// dense, and adding a lane means raising `kLaneCount`.
enum class WaitLane { EcoKernel, EcoSystem };

/// The process's one service for waiting on child processes.
///
/// There is exactly one, obtained with `instance`. It is created on first use,
/// starts its worker thread then, and is never destroyed, so the reference
/// `instance` returns stays valid for the rest of the process.
///
/// `submit`, `tryPopReady` and `hasReady` each take an internal mutex and may
/// be called from any thread.
class WaitService {
public:
    /// Returns the service, creating it and starting its worker thread on the
    /// first call.
    static WaitService& instance();

    /// The result of one submitted wait: the child has exited.
    ///
    /// `exitCode` is `exitCodeFromStatus(rawStatus)`. On POSIX `rawStatus` is
    /// the status `waitpid` reported, which a consumer can test with
    /// `WIFSIGNALED` and `WTERMSIG` to tell a signal death from an exit. On
    /// Windows both members hold the process's exit code, or 1 if the process
    /// could not be opened or its exit code could not be read.
    struct Ready {
        std::uint64_t  token; ///< The `resumeToken` given to `submit`.
        int            exitCode;
        int            rawStatus;
    };

    /// Asks for a `Ready` carrying `resumeToken` to be queued on `lane` when
    /// the child `pid` exits.
    ///
    /// `pid` must be a child of this process that nothing else, including another submit, waits for. On
    /// POSIX, if the child has already been reaped, its kept status is used
    /// and the result is queued before `submit` returns. On Windows the wait
    /// uses the handle `Elm::platform::takeProcessHandle` returns for `pid`,
    /// and otherwise a handle opened by pid.
    ///
    /// On POSIX, a pid that is not a child, or one already reaped by other
    /// code, leaves a wait that is not answered unless a later child gets that
    /// pid. While any wait is pending, every child of the process is reaped
    /// here, so nothing else in the process may wait for any child.
    void submit(int64_t pid, std::uint64_t resumeToken, WaitLane lane);

    /// Removes the oldest result queued on `lane` and writes it to `out`.
    /// Returns false, leaving `out` unchanged, if `lane` has none.
    bool tryPopReady(WaitLane lane, Ready& out);
    /// Returns whether `lane` has a result queued. It does not wait for one.
    bool hasReady(WaitLane lane) const;

    /// Returns the exit code a raw status stands for.
    ///
    /// On POSIX that is the exit status for a child that exited, 128 plus the
    /// signal number for one killed by a signal, and 1 for any other status.
    /// On Windows it returns `rawStatus` unchanged.
    static int exitCodeFromStatus(int rawStatus);

private:
    /// Starts the detached worker thread, which runs `workerLoop`.
    WaitService();
    ~WaitService() = default;

    /// Runs the worker thread, waiting for submitted children and queueing
    /// their results. It never returns.
    void workerLoop();
    /// Queues `r` on `lane` and wakes the scheduler's event loop.
    void pushReady(WaitLane lane, const Ready& r);

    /// The number of ready queues. Must equal the number of `WaitLane` values;
    /// nothing checks this.
    static constexpr int kLaneCount = 2;
    /// Returns the index of `lane`'s ready queue.
    static int laneIndex(WaitLane lane) { return static_cast<int>(lane); }

    /// A submitted wait: the child it is for and where its result goes.
    struct Pending {
        int64_t        pid;
        std::uint64_t  token;
        WaitLane       lane;
    };

    // pending_ and unclaimed_ are guarded by pendingMutex_. The worker waits on
    // pendingCV_ until pending_ is non-empty. No const member function locks
    // pendingMutex_, so its `mutable` is unused.
    mutable std::mutex          pendingMutex_;
    std::condition_variable     pendingCV_;
    std::vector<Pending>        pending_;
    // POSIX only: children the worker reaped with no pending wait for their
    // pid, mapped to the raw status. submit takes and erases an entry. An entry
    // for a child that is never submitted stays for the life of the process,
    // and if the pid is later reused for a new child, a submit for the new
    // child takes the old status. Reaping happens only while some wait is
    // pending, so this needs an unsubmitted child to exit during another wait
    // and its pid to be reused before the process ends.
    std::unordered_map<int64_t, int> unclaimed_;

    // Guards ready_, which holds one queue per lane, indexed by laneIndex.
    // Mutable so that the const hasReady can lock it.
    mutable std::mutex          readyMutex_;
    std::queue<Ready>           ready_[kLaneCount];
};

} // namespace Elm::Platform

#endif // ECO_PLATFORM_WAIT_SERVICE_HPP
