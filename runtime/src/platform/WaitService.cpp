#include "WaitService.hpp"
#include "Scheduler.hpp"
#include <cerrno>
#include <system_error>
#include <thread>
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

WaitService& WaitService::instance() {
    // Never destroyed: a waiting thread may still queue a result while the process exits.
    static WaitService* inst = new WaitService();
    return *inst;
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

// Waits for the child `pid` on a detached thread of its own and queues the
// result on `lane`. Each thread waits for its one pid only, so no other child
// of the process is ever reaped here.
void WaitService::submit(int64_t pid, std::uint64_t resumeToken, WaitLane lane) {
#if defined(_WIN32)
    HANDLE h = static_cast<HANDLE>(Elm::platform::takeProcessHandle(pid));
    if (!h) {
        h = OpenProcess(SYNCHRONIZE | PROCESS_QUERY_LIMITED_INFORMATION, FALSE,
                        static_cast<DWORD>(pid));
    }
    if (!h) {
        pushReady(lane, Ready{resumeToken, kWaitFailedExitCode, 0,
                              static_cast<int>(GetLastError())});
        return;
    }
    auto wait = [this, h, resumeToken, lane] {
        WaitForSingleObject(h, INFINITE);
        DWORD code = 0;
        Ready r{resumeToken, 0, 0, 0};
        if (GetExitCodeProcess(h, &code)) {
            r.exitCode = exitCodeFromStatus(static_cast<int>(code));
            r.rawStatus = static_cast<int>(code);
        } else {
            r.exitCode = kWaitFailedExitCode;
            r.error = static_cast<int>(GetLastError());
        }
        CloseHandle(h);
        pushReady(lane, r);
    };
#else
    auto wait = [this, pid, resumeToken, lane] {
        int status = 0;
        pid_t r;
        do {
            r = ::waitpid(static_cast<pid_t>(pid), &status, 0);
        } while (r < 0 && errno == EINTR);
        if (r < 0) {
            // ECHILD: not a child of this process, or already reaped by other code.
            pushReady(lane, Ready{resumeToken, kWaitFailedExitCode, 0, errno});
        } else {
            pushReady(lane, Ready{resumeToken, exitCodeFromStatus(status), status, 0});
        }
    };
#endif
    try {
        std::thread(std::move(wait)).detach();
    } catch (const std::system_error& e) {
        // No thread to wait with: answered as failed, so the waiter is not left pending. The child is not
        // reaped.
#if defined(_WIN32)
        CloseHandle(h);
#endif
        pushReady(lane, Ready{resumeToken, kWaitFailedExitCode, 0, e.code().value()});
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

} // namespace Elm::Platform
