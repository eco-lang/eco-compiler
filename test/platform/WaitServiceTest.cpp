// Unit tests of the runtime's WaitService (runtime/src/platform/WaitService.cpp).
//
// result-keeps-pid-until-popped (PROC-02, killJob could signal a reused pid): the WaitService's POSIX wait
// thread reaped the child with `waitpid(pid, &status, 0)` the moment it exited (`submit`), and only then
// queued the `Ready`. Until the eco thread pops that result, the ChildProcess job still looks alive
// (`!exited`), so `killJob` may `kill()` a pid the kernel had already freed and may have handed to an
// unrelated process. The case checks the root cause deterministically: with a result queued but not yet
// popped, the pid must still be ours (a zombie `waitid(WNOWAIT)` can see). Before the fix it was already gone
// (ECHILD); now the wait thread waits with WNOWAIT and `tryPopReady` reaps. The pid reuse itself is not
// reproduced.

#include "WaitServiceTest.hpp"

#include "../TestSuite.hpp"
#include "../allocator/TestHelpers.hpp"

#include "../../runtime/src/platform/Scheduler.hpp"
#include "../../runtime/src/platform/Spawn.hpp"
#include "../../runtime/src/platform/WaitService.hpp"

#include <cerrno>
#include <chrono>
#include <cstring>
#include <functional>
#include <string>
#include <thread>

#if !defined(_WIN32)
#include <sys/types.h>
#include <sys/wait.h>
#include <unistd.h>
#endif

namespace {

#if !defined(_WIN32)
using Elm::Platform::Scheduler;
using Elm::Platform::WaitLane;
using Elm::Platform::WaitService;

// Polls `cond` every millisecond for up to `ms` milliseconds.
bool waitFor(const std::function<bool()>& cond, int ms = 5000) {
    auto deadline = std::chrono::steady_clock::now() + std::chrono::milliseconds(ms);
    while (std::chrono::steady_clock::now() < deadline) {
        if (cond()) return true;
        std::this_thread::sleep_for(std::chrono::milliseconds(1));
    }
    return cond();
}

// PROC-02: a child whose exit is queued but not yet popped must still be a zombie owned by this
// process, so that nothing can reuse its pid before the eco thread has seen the exit.
void testWaitResultKeepsPidUntilPopped() {
    // Heap for this (eco) thread, then the Scheduler, which the WaitService notifies
    // (as PlatformServicesTest's initRuntime does).
    initAllocator();
    (void)Scheduler::instance();
    auto& ws = WaitService::instance();

    Elm::platform::SpawnSpec spec;
    spec.program = "/bin/sh";
    spec.args = {"-c", "exit 0"};
    spec.shellKind = Elm::platform::kShellNone;
    auto c = Elm::platform::spawnChild(spec, Elm::platform::StdioMode::Null, /*newSession=*/false);
    if (c.err != 0) TEST_FAIL("PROC-02: spawnChild failed: " + std::string(std::strerror(c.err)));
    const pid_t pid = static_cast<pid_t>(c.pid);

    ws.submit(pid, 401, WaitLane::EcoSystem);
    if (!waitFor([&] { return ws.hasReady(WaitLane::EcoSystem); }))
        TEST_FAIL("PROC-02: no wait result within 5 s (precondition)");

    // The result is queued; the consumer has not popped it. Is the pid still ours?
    siginfo_t info{};
    errno = 0;
    const int rc = ::waitid(P_PID, static_cast<id_t>(pid), &info, WEXITED | WNOHANG | WNOWAIT);
    const int probeErr = errno;
    const bool stillZombie = rc == 0 && info.si_pid == pid;

    WaitService::Ready r{};
    TEST_ASSERT(ws.tryPopReady(WaitLane::EcoSystem, r));
    TEST_ASSERT(r.token == 401);
    TEST_ASSERT(r.error == 0);
    TEST_ASSERT(r.exitCode == 0);

    // After the pop the child must be reaped (no zombie leaks), whichever way the fix goes.
    siginfo_t after{};
    errno = 0;
    const int rc2 = ::waitid(P_PID, static_cast<id_t>(pid), &after, WEXITED | WNOHANG);
    TEST_ASSERT(rc2 == -1 && errno == ECHILD);

    if (!stillZombie)
        TEST_FAIL("PROC-02: the pid was freed with its exit queued but not popped: rc=" + std::to_string(rc) +
                  (rc != 0 ? std::string(" errno=") + std::strerror(probeErr) : std::string()) +
                  " si_pid=" + std::to_string(info.si_pid) +
                  " (ECHILD = the wait thread already freed the pid, so killJob could signal a reused pid)");
}
#endif

}  // namespace

void registerWaitServiceTests(IsolatedTestRunner::IsolatedTestCaseSuite& suite) {
#if !defined(_WIN32)
    // Initializes the allocator and the Scheduler and pops the EcoSystem wait lane: own process.
    suite.add(Testing::TestCase("wait-service/result-keeps-pid-until-popped", testWaitResultKeepsPidUntilPopped));
#else
    (void)suite;
#endif
}
