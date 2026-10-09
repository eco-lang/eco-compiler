#include "WaitService.hpp"
#include "Scheduler.hpp"
#include <cerrno>
#include <chrono>
#include <thread>
#include <vector>
#if defined(_WIN32)
#define WIN32_LEAN_AND_MEAN
#ifndef NOMINMAX
#define NOMINMAX
#endif
#include <windows.h>
#include "Spawn.hpp"
#else
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
// Windows (plans/spawn-not-fork.md Phase 1): no SIGCHLD / waitpid. Each
// submitted child gets a waiter thread that blocks on its process handle (the
// one platform::spawnChild kept, or one opened by pid), reads the exit code
// and routes it to the submit's lane, as the POSIX worker does. The exit
// code is the raw status (exitCodeFromStatus is the identity here).
void WaitService::workerLoop() {
    while (true) {
        std::vector<Pending> batch;
        {
            std::unique_lock<std::mutex> lk(pendingMutex_);
            pendingCV_.wait(lk, [this] { return !pending_.empty(); });
            batch.swap(pending_);
        }
        for (const Pending& p : batch) {
            HANDLE h = static_cast<HANDLE>(Elm::platform::takeProcessHandle(p.pid));
            if (!h) {
                h = OpenProcess(SYNCHRONIZE | PROCESS_QUERY_LIMITED_INFORMATION, FALSE,
                                static_cast<DWORD>(p.pid));
            }
            std::thread([this, h, p] {
                DWORD code = 1;
                if (h) {
                    WaitForSingleObject(h, INFINITE);
                    if (!GetExitCodeProcess(h, &code)) code = 1;
                    CloseHandle(h);
                }
                pushReady(p.lane, Ready{p.token, exitCodeFromStatus(static_cast<int>(code)),
                                        static_cast<int>(code)});
            }).detach();
        }
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
