#include "TimerService.hpp"
#include "Scheduler.hpp"

namespace Elm::Platform {

// Leaky heap singleton: `new`'d on first access and never destroyed. The
// detached worker thread runs until the process exits. This mirrors the
// posture the old ProcessExports::sleepBindingEvaluator had (detached
// std::thread, never joined) and eliminates any destruction-ordering
// interaction with Scheduler::instance().
static TimerService* s_instance = nullptr;

TimerService& TimerService::instance() {
    static TimerService* inst = []{
        s_instance = new TimerService();
        return s_instance;
    }();
    return *inst;
}

TimerService::TimerService() {
    std::thread([]{ instance().workerLoop(); }).detach();
}

void TimerService::schedule(double millis, std::uint64_t resumeToken) {
    auto delay    = std::chrono::duration<double, std::milli>(millis);
    auto deadline = Clock::now() +
        std::chrono::duration_cast<Clock::duration>(delay);
    {
        std::lock_guard<std::mutex> lk(timersMutex_);
        timers_.push(TimerEntry{deadline, resumeToken});
    }
    timersCV_.notify_one();
}

bool TimerService::tryPopReadyToken(std::uint64_t& outToken) {
    std::lock_guard<std::mutex> lk(readyMutex_);
    if (readyTokens_.empty()) return false;
    outToken = readyTokens_.front();
    readyTokens_.pop();
    return true;
}

bool TimerService::hasReadyTokens() const {
    std::lock_guard<std::mutex> lk(readyMutex_);
    return !readyTokens_.empty();
}

void TimerService::workerLoop() {
    while (true) {
        std::unique_lock<std::mutex> lk(timersMutex_);
        if (timers_.empty()) {
            timersCV_.wait(lk, [this]{ return !timers_.empty(); });
        }
        TimePoint deadline = timers_.top().deadline;
        TimePoint now      = Clock::now();
        if (now < deadline) {
            timersCV_.wait_until(lk, deadline);
            continue;
        }
        std::uint64_t token = timers_.top().token;
        timers_.pop();
        lk.unlock();

        {
            std::lock_guard<std::mutex> rlk(readyMutex_);
            readyTokens_.push(token);
        }
        Scheduler::instance().notifyWorkAvailableFromAsync();
    }
}

} // namespace Elm::Platform
