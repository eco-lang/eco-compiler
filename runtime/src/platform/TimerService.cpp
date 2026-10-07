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
        auto it = timers_.emplace(deadline, resumeToken);
        byToken_[resumeToken] = it;
    }
    timersCV_.notify_one();
}

bool TimerService::cancel(std::uint64_t token) {
    {
        std::lock_guard<std::mutex> lk(timersMutex_);
        auto it = byToken_.find(token);
        if (it == byToken_.end()) return false;
        timers_.erase(it->second);
        byToken_.erase(it);
    }
    // The worker may be sleeping until the removed deadline; let it
    // recompute its next wake-up.
    timersCV_.notify_one();
    return true;
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
        auto first = timers_.begin();
        TimePoint deadline = first->first;
        TimePoint now      = Clock::now();
        if (now < deadline) {
            timersCV_.wait_until(lk, deadline);
            continue;
        }
        std::uint64_t token = first->second;
        auto idx = byToken_.find(token);
        if (idx != byToken_.end() && idx->second == first) byToken_.erase(idx);
        timers_.erase(first);
        lk.unlock();

        {
            std::lock_guard<std::mutex> rlk(readyMutex_);
            readyTokens_.push(token);
        }
        Scheduler::instance().notifyWorkAvailableFromAsync();
    }
}

} // namespace Elm::Platform
