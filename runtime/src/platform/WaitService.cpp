#include "WaitService.hpp"
#include "Scheduler.hpp"
#include <cerrno>
#include <chrono>
#if !defined(_WIN32)
#include <sys/wait.h>
#endif

namespace Elm::Platform {

// Leaky heap singleton + detached worker thread. Mirrors TimerService.
static WaitService* s_instance = nullptr;

WaitService& WaitService::instance() {
    static WaitService* inst = [] {
        s_instance = new WaitService();
        return s_instance;
    }();
    return *inst;
}

WaitService::WaitService() {
    std::thread([] { instance().workerLoop(); }).detach();
}

int WaitService::exitCodeFromStatus(int rawStatus) {
#if defined(_WIN32)
    return rawStatus;
#else
    if (WIFEXITED(rawStatus)) return WEXITSTATUS(rawStatus);
    if (WIFSIGNALED(rawStatus)) return 128 + WTERMSIG(rawStatus);
    return 1;
#endif
}

void WaitService::pushReady(WaitLane lane, const Ready& r) {
    {
        std::lock_guard<std::mutex> lk(readyMutex_);
        ready_[laneIndex(lane)].push(r);
    }
    Scheduler::instance().notifyWorkAvailableFromAsync();
}

void WaitService::submit(int64_t pid, std::uint64_t resumeToken, WaitLane lane) {
    bool alreadyReaped = false;
    int rawStatus = 0;
    {
        std::lock_guard<std::mutex> lk(pendingMutex_);
        auto it = unclaimed_.find(pid);
        if (it != unclaimed_.end()) {
            // Reap-before-submit race: the worker already collected this
            // child while waiting for another one.
            rawStatus = it->second;
            unclaimed_.erase(it);
            alreadyReaped = true;
        } else {
            pending_.push_back(Pending{pid, resumeToken, lane});
        }
    }
    if (alreadyReaped) {
        pushReady(lane, Ready{resumeToken, exitCodeFromStatus(rawStatus), rawStatus});
    } else {
        pendingCV_.notify_one();
    }
}

bool WaitService::tryPopReady(WaitLane lane, Ready& out) {
    std::lock_guard<std::mutex> lk(readyMutex_);
    auto& q = ready_[laneIndex(lane)];
    if (q.empty()) return false;
    out = q.front();
    q.pop();
    return true;
}

bool WaitService::hasReady(WaitLane lane) const {
    std::lock_guard<std::mutex> lk(readyMutex_);
    return !ready_[laneIndex(lane)].empty();
}

#if defined(_WIN32)
// Windows v1: process-spawning is not yet implemented in Process.cpp, so
// no children ever get submit()'d here in practice. We still keep the
// worker thread alive so `pending_` is drained if a future Process.cpp
// path does start submitting; the worker simply parks on the CV until
// a Windows-native implementation (per-child RegisterWaitForSingleObject
// or a thread-per-child join) is wired in. See plans/build-on-windows.md
// items 7 & 9.
void WaitService::workerLoop() {
    while (true) {
        std::unique_lock<std::mutex> lk(pendingMutex_);
        pendingCV_.wait(lk, [this] { return !pending_.empty(); });
        // Pop and drop — no reaping yet. The Elm-side Process.wait task
        // will never complete; this matches the documented v1 limitation.
        pending_.clear();
    }
}
#else
void WaitService::workerLoop() {
    while (true) {
        // Wait until at least one pending registration exists. Without
        // this, `waitpid(-1, …, 0)` would return ECHILD immediately and we
        // would burn CPU spinning.
        {
            std::unique_lock<std::mutex> lk(pendingMutex_);
            pendingCV_.wait(lk, [this] { return !pending_.empty(); });
        }

        int status = 0;
        pid_t pid = ::waitpid(-1, &status, 0);
        if (pid < 0) {
            if (errno == EINTR) continue;
            // ECHILD: pending is non-empty but this process has no children
            // left (a registered pid was reaped elsewhere, or was never our
            // child). Back off instead of spinning; a later spawn makes
            // waitpid block again.
            std::this_thread::sleep_for(std::chrono::milliseconds(10));
            continue;
        }

        // Match against the pending registry. A child nobody has submitted
        // yet is parked in unclaimed_ so a later submit finds it (reap-
        // before-submit race, review R1.5).
        Pending match{};
        bool found = false;
        {
            std::lock_guard<std::mutex> lk(pendingMutex_);
            for (auto it = pending_.begin(); it != pending_.end(); ++it) {
                if (it->pid == pid) {
                    match = *it;
                    pending_.erase(it);
                    found = true;
                    break;
                }
            }
            if (!found) {
                unclaimed_[pid] = status;
            }
        }

        if (found) {
            pushReady(match.lane, Ready{match.token, exitCodeFromStatus(status), status});
        }
    }
}
#endif // !_WIN32

} // namespace Elm::Platform
