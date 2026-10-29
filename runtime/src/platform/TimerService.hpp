#ifndef ECO_PLATFORM_TIMER_SERVICE_HPP
#define ECO_PLATFORM_TIMER_SERVICE_HPP

#include <chrono>
#include <condition_variable>
#include <cstdint>
#include <map>
#include <mutex>
#include <queue>
#include <thread>
#include <unordered_map>

namespace Elm::Platform {

// One-shot timers for the scheduler, kept on a thread of their own so that waiting for a deadline never
// blocks the eco thread, the thread that runs Elm code.
//
// A timer here is a deadline and a token, an opaque `std::uint64_t` the caller chooses. When the deadline
// passes, the timer fires: its token is moved to the ready queue and the scheduler is woken with
// `Scheduler::notifyWorkAvailableFromAsync`. The scheduler pops ready tokens on the eco thread
// (`Scheduler::processReadyAsync` owns what a fired token then does). Because a timer is only numbers, the
// worker thread never touches an Elm value or the garbage-collected heap, and whatever a token stands for
// stays on the eco thread.
//
// `withdrawParkedTimer` is the one function that joins the two sides: it withdraws a timer whose token is a
// parked resume token, so that its hold is released exactly once whether or not the timer has fired.

/**
 * The process-wide timer worker: a set of scheduled timers, a queue of fired tokens, and the thread that moves
 * one to the other.
 *
 * The only object is the one `instance` returns. It is created on first use, which starts its worker thread,
 * and it is never destroyed; the thread runs until the process exits. It cannot be copied or moved.
 */
class TimerService {
public:
    // Returns the timer service, creating it and starting its worker thread on the first call.
    static TimerService& instance();

    // Schedules a timer that fires `millis` milliseconds from now, after which, unless it is cancelled first,
    // `tryPopReadyToken` yields `resumeToken`. Timers fire in deadline order, and timers with equal deadlines
    // in the order they were scheduled. A zero or negative delay is not special: the timer fires as soon as
    // the worker sees it, still through the ready queue.
    //
    // `millis` must be finite and small enough that the deadline fits `Clock`. `resumeToken` must not be the
    // token of another timer that has not yet fired. May be called from any thread.
    void schedule(double millis, std::uint64_t resumeToken);

    // Removes the timer with token `token` if it has not fired, and returns whether it did. After a true
    // result the token is never delivered, so anything its delivery would have done, such as releasing a
    // hold, is left to the caller; `withdrawParkedTimer` does that for a parked resume token. A false result
    // means no timer with this token is waiting: it is unknown, or has fired. May be called from any thread.
    bool cancel(std::uint64_t token);

    // Takes the oldest fired token from the ready queue, writes it to `outToken` and returns true, or returns
    // false, leaving `outToken` unchanged, when the queue is empty. Tokens come out in the order they fired.
    bool tryPopReadyToken(std::uint64_t& outToken);
    // Returns whether the ready queue holds a fired token. It takes only the ready queue's lock, which is held
    // for no more than a push or pop.
    bool hasReadyTokens() const;

private:
    // Starts the worker thread, detached.
    TimerService();
    ~TimerService() = default;

    // Runs on the worker thread for the rest of the process: sleeps until the earliest deadline or a change
    // to the timers, then moves each timer whose deadline has passed to the ready queue and wakes the
    // scheduler.
    void workerLoop();

    // The clock deadlines are measured on, which never goes backwards.
    using Clock     = std::chrono::steady_clock;
    // A deadline on `Clock`.
    using TimePoint = Clock::time_point;

    // Scheduled timers as deadline-to-token entries. A multimap keeps entries with equal deadlines in
    // insertion order, which is what makes ties fire in schedule order.
    using TimerMap = std::multimap<TimePoint, std::uint64_t>;

    // The scheduled timers. `timersMutex_` guards `timers_` and `byToken_`; `timersCV_` wakes the worker when
    // either changes. `byToken_` maps each waiting token to its entry in `timers_`, so `cancel` need not search.
    // `timersMutex_` is `mutable`, but no const member function locks it.
    mutable std::mutex              timersMutex_;
    std::condition_variable         timersCV_;
    TimerMap                        timers_;
    std::unordered_map<std::uint64_t, TimerMap::iterator> byToken_;

    // The fired tokens, oldest first, guarded by `readyMutex_`, which is mutable so that `hasReadyTokens`
    // can lock it.
    mutable std::mutex              readyMutex_;
    std::queue<std::uint64_t>       readyTokens_;
};

// Withdraws the timer for `token`, a resume token from `Scheduler::parkResume` that was passed to
// `TimerService::schedule`: the parked resume, if it has not already run, is discarded, and the token's hold is
// released once. The release happens here if the timer had not fired; otherwise it is left to
// `Scheduler::processReadyAsync`, which releases the hold of a popped token whose resume is gone.
//
// Must be called on the eco thread, since parked resumes are taken there, and not while holding a lock that
// `Scheduler::releaseHold` takes, since it may call that function. Calling it twice for one token, or for a token
// whose resume has already run, releases nothing here but is not checked.
void withdrawParkedTimer(std::uint64_t token);

} // namespace Elm::Platform

#endif // ECO_PLATFORM_TIMER_SERVICE_HPP
