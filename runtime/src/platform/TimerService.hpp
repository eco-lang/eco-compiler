#ifndef ECO_PLATFORM_TIMER_SERVICE_HPP
#define ECO_PLATFORM_TIMER_SERVICE_HPP

#include <chrono>
#include <condition_variable>
#include <cstdint>
#include <mutex>
#include <queue>
#include <thread>
#include <vector>

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
    // negative delays go through the same priority-queue path as positive
    // ones (no fast path).
    void schedule(double millis, std::uint64_t resumeToken);

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

    struct TimerEntry {
        TimePoint    deadline;
        std::uint64_t token;
    };
    struct TimerCompare {
        bool operator()(const TimerEntry& a, const TimerEntry& b) const {
            return a.deadline > b.deadline;
        }
    };

    mutable std::mutex              timersMutex_;
    std::condition_variable         timersCV_;
    std::priority_queue<TimerEntry,
                        std::vector<TimerEntry>,
                        TimerCompare>       timers_;

    mutable std::mutex              readyMutex_;
    std::queue<std::uint64_t>       readyTokens_;
};

} // namespace Elm::Platform

#endif // ECO_PLATFORM_TIMER_SERVICE_HPP
