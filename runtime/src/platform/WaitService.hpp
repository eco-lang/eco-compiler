//===- WaitService.hpp - Child-process waits --------------------------------===//
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
// Each submitted child is waited for on a detached thread of its own, which
// waits for that one child and nothing else: `waitpid(pid)` on POSIX, the
// child's process handle on Windows. No other child of the process is ever
// reaped here, so other code (Spawn.hpp's `waitChild`, a host embedding eco)
// may wait for its own children. A wait that cannot be made, for a pid that
// is not a child of this process or was already reaped elsewhere, is answered
// at once as failed rather than left pending.
//
//===----------------------------------------------------------------------===//

#ifndef ECO_PLATFORM_WAIT_SERVICE_HPP
#define ECO_PLATFORM_WAIT_SERVICE_HPP

#include <cstdint>
#include <mutex>
#include <queue>

namespace Elm::Platform {

/**
 * The consumer a submitted wait belongs to. Each lane has its own ready queue,
 * and a result is queued only on the lane its submit named. The enumerator's
 * value indexes the per-lane queues, so the values must stay 0-based and
 * dense, and adding a lane means raising `kLaneCount`.
 */
enum class WaitLane { EcoKernel, EcoSystem };

/**
 * The process's one service for waiting on child processes.
 *
 * There is exactly one, obtained with `instance`. It is created on first use
 * and is never destroyed, so the reference
 * `instance` returns stays valid for the rest of the process.
 *
 * `submit`, `tryPopReady` and `hasReady` each take an internal mutex and may
 * be called from any thread.
 */
class WaitService {
public:
    // Returns the service, creating it on the first call.
    static WaitService& instance();

    /**
     * The result of one submitted wait: the child has exited, or the wait
     * failed (`error` non-zero).
     *
     * For an exit, `exitCode` is `exitCodeFromStatus(rawStatus)`. On POSIX
     * `rawStatus` is the status `waitpid` reported, which a consumer can test
     * with `WIFSIGNALED` and `WTERMSIG` to tell a signal death from an exit.
     * On Windows both members hold the process's exit code.
     */
    struct Ready {
        std::uint64_t  token; // The `resumeToken` given to `submit`.
        int            exitCode;
        int            rawStatus;
        // 0 when the child exited. Otherwise the wait failed and this is the
        // error (POSIX errno, Windows GetLastError); `exitCode` is then
        // `kWaitFailedExitCode` and `rawStatus` is 0.
        int            error = 0;
    };

    // The `exitCode` of a failed wait. No exit status or signal death maps to
    // it, so a consumer that only passes exit codes on still reports the
    // failure distinctly.
    static constexpr int kWaitFailedExitCode = -1;

    // Asks for a `Ready` carrying `resumeToken` to be queued on `lane` when
    // the child `pid` exits, and starts a thread that waits for it.
    //
    // `pid` should be a child of this process that nothing else, including
    // another submit, waits for. A child that has already exited but not been
    // reaped is answered at once. On Windows the wait uses the handle
    // `Elm::platform::takeProcessHandle` returns for `pid`, and otherwise a
    // handle opened by pid. A pid that cannot be waited for (not a child,
    // already reaped, a handle that cannot be opened, or no thread to wait
    // with) is answered with a failed `Ready`, without blocking.
    void submit(int64_t pid, std::uint64_t resumeToken, WaitLane lane);

    // Removes the oldest result queued on `lane` and writes it to `out`.
    // Returns false, leaving `out` unchanged, if `lane` has none.
    bool tryPopReady(WaitLane lane, Ready& out);
    // Returns whether `lane` has a result queued. It does not wait for one.
    bool hasReady(WaitLane lane) const;

    // Returns the exit code a raw status stands for.
    //
    // On POSIX that is the exit status for a child that exited, 128 plus the
    // signal number for one killed by a signal, and 1 for any other status.
    // On Windows it returns `rawStatus` unchanged.
    static int exitCodeFromStatus(int rawStatus);

private:
    WaitService() = default;
    ~WaitService() = default;

    // Queues `r` on `lane` and wakes the scheduler's event loop.
    void pushReady(WaitLane lane, const Ready& r);

    // The number of ready queues. Must equal the number of `WaitLane` values;
    // nothing checks this.
    static constexpr int kLaneCount = 2;
    // Returns the index of `lane`'s ready queue.
    static int laneIndex(WaitLane lane) { return static_cast<int>(lane); }

    // Guards ready_, which holds one queue per lane, indexed by laneIndex.
    // Mutable so that the const hasReady can lock it.
    mutable std::mutex          readyMutex_;
    std::queue<Ready>           ready_[kLaneCount];
};

} // namespace Elm::Platform

#endif // ECO_PLATFORM_WAIT_SERVICE_HPP
