#include "WaitService.hpp"
#include "Scheduler.hpp"
#include <cerrno>
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

void WaitService::submit(int64_t pid, std::uint64_t resumeToken) {
    {
        std::lock_guard<std::mutex> lk(pendingMutex_);
        pending_.push_back(Pending{pid, resumeToken});
    }
    pendingCV_.notify_one();
}

bool WaitService::tryPopResult(std::uint64_t& outToken, int& outExitCode) {
    std::lock_guard<std::mutex> lk(readyMutex_);
    if (ready_.empty()) return false;
    Ready r = ready_.front();
    ready_.pop();
    outToken = r.token;
    outExitCode = r.exitCode;
    return true;
}

bool WaitService::hasReady() const {
    std::lock_guard<std::mutex> lk(readyMutex_);
    return !ready_.empty();
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
            // ECHILD: race window — pending was non-empty when we checked
            // but the child has already been reaped elsewhere (shouldn't
            // happen in normal Eco use, but be defensive). Drop back to
            // the wait.
            if (errno == ECHILD) continue;
            continue;
        }

        int exitCode = WIFEXITED(status) ? WEXITSTATUS(status) : 1;

        // Match against the pending registry. If the child wasn't one we
        // were tracking, silently drop the result — keeps the worker
        // tolerant of children spawned outside of Eco.Process.spawn.
        std::uint64_t token = 0;
        bool found = false;
        {
            std::lock_guard<std::mutex> lk(pendingMutex_);
            for (auto it = pending_.begin(); it != pending_.end(); ++it) {
                if (it->pid == pid) {
                    token = it->token;
                    pending_.erase(it);
                    found = true;
                    break;
                }
            }
        }

        if (found) {
            {
                std::lock_guard<std::mutex> lk(readyMutex_);
                ready_.push(Ready{token, exitCode});
            }
            Scheduler::instance().notifyWorkAvailableFromAsync();
        }
    }
}
#endif // !_WIN32

} // namespace Elm::Platform
