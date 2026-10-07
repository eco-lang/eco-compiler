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

// Dumb timer worker: holds only POD state (deadlines, tokens, stl queues).
// Never touches HPointer, the allocator, or any GC-managed data. Timer
// expirations are delivered as plain uint64_t tokens to the main scheduler
// thread, which is the sole owner of all GC interactions (see
// Scheduler::processReadyAsync).
class TimerService {
public:
    static TimerService& instance();

    // Schedule a one-shot timer; `millis` is a relative delay. `resumeToken`
    // is the opaque id produced by Scheduler::registerPendingResume and is
    // echoed back via tryPopReadyToken when the timer fires. Zero and
    // negative delays go through the same deadline-ordered path as positive
    // ones (no fast path).
    // Tokens must be unique among scheduled timers (Scheduler resume tokens
    // are).
    void schedule(double millis, std::uint64_t resumeToken);

    // Removes a scheduled, not yet fired timer. Returns true when the entry
    // was removed: its token will never be delivered, so the caller owns the
    // pendingAsync reference it took for the timer and must call
    // Scheduler::decrementPendingAsync() (plans/eco-system-library.md Phase 2
    // step 6). Returns false when the token is unknown or has already fired
    // (it is then, or will be, delivered through tryPopReadyToken, whose
    // consumer decrements as usual). Safe to call from any thread.
    bool cancel(std::uint64_t token);

    // Main-thread-only consumer API. tryPopReadyToken returns true and
    // writes the next expired token into `outToken`, or false when the
    // ready queue is empty. hasReadyTokens is a predicate for the event
    // loop's wait condition — it must not block.
    bool tryPopReadyToken(std::uint64_t& outToken);
    bool hasReadyTokens() const;

private:
    TimerService();
    ~TimerService() = default;

    void workerLoop();

    using Clock     = std::chrono::steady_clock;
    using TimePoint = Clock::time_point;

    // Scheduled timers ordered by deadline (ties fire in schedule order),
    // plus a token index so cancel() can remove an entry in O(log n). Both
    // guarded by timersMutex_.
    using TimerMap = std::multimap<TimePoint, std::uint64_t>;

    mutable std::mutex              timersMutex_;
    std::condition_variable         timersCV_;
    TimerMap                        timers_;
    std::unordered_map<std::uint64_t, TimerMap::iterator> byToken_;

    mutable std::mutex              readyMutex_;
    std::queue<std::uint64_t>       readyTokens_;
};

} // namespace Elm::Platform

#endif // ECO_PLATFORM_TIMER_SERVICE_HPP
