// Unit tests for the Phase 2 runtime prerequisites of eco/system
// (plans/eco-system-library.md §3.7, Phase 2 steps 2, 3, 5, 6). No Elm and no
// heap objects: the Scheduler is driven with an empty run queue, and timer
// tokens that have no registered resume closure (processReadyAsync then only
// decrements pendingAsync).

#include "PlatformServicesTest.hpp"
#include "../../runtime/src/allocator/RuntimeExports.h"
#include "../../runtime/src/platform/Scheduler.hpp"
#include "../../runtime/src/platform/TimerService.hpp"
#include "../../runtime/src/platform/WaitService.hpp"
#include "../allocator/TestHelpers.hpp"
#include "../TestSuite.hpp"

#include <cerrno>
#include <chrono>
#include <cstdint>
#include <functional>
#include <thread>

#if !defined(_WIN32)
#include <csignal>
#include <sys/types.h>
#include <sys/wait.h>
#include <unistd.h>
#endif

using Elm::Platform::Scheduler;
using Elm::Platform::TimerService;
using Elm::Platform::WaitLane;
using Elm::Platform::WaitService;

namespace {

// Polls `cond` every millisecond for up to `ms` milliseconds.
bool waitFor(const std::function<bool()>& cond, int ms = 5000) {
    auto deadline = std::chrono::steady_clock::now() + std::chrono::milliseconds(ms);
    while (std::chrono::steady_clock::now() < deadline) {
        if (cond()) return true;
        std::this_thread::sleep_for(std::chrono::milliseconds(1));
    }
    return cond();
}

// Heap for this (eco) thread, then the Scheduler, whose constructor registers
// its GC root scanner with this thread's heap. It must be constructed here,
// as the runtime always does on the eco thread: otherwise the first service
// worker that notifies it would construct it on a second mutator thread
// (HEAP_007 aborts).
void initRuntime() {
    initAllocator();
    (void)Scheduler::instance();
}

// Timer tokens never registered with Scheduler::registerPendingResume.
constexpr std::uint64_t kBogusTokenBase = 0xEC05'0000'0000'0000ull;

// ---- Scheduler quiescence hook (Phase 2 step 3) ----------------------------

int g_quiescenceCalls = 0;

// First call starts one async op (a 5 ms timer holding a pendingAsync ref),
// which re-arms the hook; the second call starts nothing, so the loop must
// exit at the next quiescence.
void listenerStartsAsyncOnce(void* /*ctx*/) {
    g_quiescenceCalls++;
    if (g_quiescenceCalls == 1) {
        Scheduler::instance().incrementPendingAsync();
        TimerService::instance().schedule(5.0, kBogusTokenBase + 1);
    }
}

void listenerCountsOnly(void* ctx) {
    (*static_cast<int*>(ctx))++;
}

void test_quiescence_fires_once_per_arming() {
    initRuntime();
    g_quiescenceCalls = 0;
    auto& sched = Scheduler::instance();
    sched.addQuiescenceListener(listenerStartsAsyncOnce, nullptr);
    sched.runEventLoop();
    TEST_ASSERT(g_quiescenceCalls == 2);
}

void test_quiescence_listener_without_async_exits() {
    initRuntime();
    int calls = 0;
    auto& sched = Scheduler::instance();
    sched.addQuiescenceListener(listenerCountsOnly, &calls);
    sched.runEventLoop();
    TEST_ASSERT(calls == 1);
    // A second run: the hook is disarmed (no incrementPendingAsync since it
    // fired), so the loop exits without calling the listener again.
    sched.runEventLoop();
    TEST_ASSERT(calls == 1);
    // incrementPendingAsync re-arms it.
    sched.incrementPendingAsync();
    sched.decrementPendingAsync();
    sched.runEventLoop();
    TEST_ASSERT(calls == 2);
}

void test_quiescence_never_in_embed_mode() {
    initRuntime();
    int calls = 0;
    auto& sched = Scheduler::instance();
    sched.setEmbedMode(true);
    sched.addQuiescenceListener(listenerCountsOnly, &calls);
    sched.runEventLoop();
    TEST_ASSERT(calls == 0);
}

// ---- TimerService::cancel (Phase 2 step 6) ----------------------------------

void test_timer_cancel_pending() {
    initRuntime();
    auto& timers = TimerService::instance();
    const std::uint64_t far = kBogusTokenBase + 10;
    timers.schedule(60000.0, far);
    TEST_ASSERT(timers.cancel(far));
    TEST_ASSERT(!timers.cancel(far));                     // already removed
    TEST_ASSERT(!timers.cancel(kBogusTokenBase + 11));    // never scheduled

    // A cancelled short timer is never delivered; an uncancelled one is.
    const std::uint64_t dropped = kBogusTokenBase + 12;
    const std::uint64_t kept = kBogusTokenBase + 13;
    timers.schedule(20.0, dropped);
    timers.schedule(40.0, kept);
    TEST_ASSERT(timers.cancel(dropped));
    TEST_ASSERT(waitFor([&] { return timers.hasReadyTokens(); }));
    std::uint64_t tok = 0;
    TEST_ASSERT(timers.tryPopReadyToken(tok));
    TEST_ASSERT(tok == kept);
    std::this_thread::sleep_for(std::chrono::milliseconds(50));
    TEST_ASSERT(!timers.hasReadyTokens());
}

void test_timer_cancel_after_fire_returns_false() {
    initRuntime();
    auto& timers = TimerService::instance();
    const std::uint64_t t = kBogusTokenBase + 20;
    timers.schedule(1.0, t);
    TEST_ASSERT(waitFor([&] { return timers.hasReadyTokens(); }));
    // Fired: the token is (or will be) delivered, so cancel must not claim
    // it — the consumer of tryPopReadyToken owns the decrement.
    TEST_ASSERT(!timers.cancel(t));
    std::uint64_t tok = 0;
    TEST_ASSERT(timers.tryPopReadyToken(tok));
    TEST_ASSERT(tok == t);
}

// ---- WaitService lanes (Phase 2 step 5) -------------------------------------

#if !defined(_WIN32)
pid_t forkExit(int code, int delayMs = 0) {
    pid_t pid = ::fork();
    if (pid == 0) {
        if (delayMs > 0) ::usleep(static_cast<useconds_t>(delayMs) * 1000);
        ::_exit(code);
    }
    return pid;
}

void test_wait_lanes_route_results() {
    initRuntime();
    auto& ws = WaitService::instance();
    pid_t a = forkExit(3);
    pid_t b = forkExit(4);
    TEST_ASSERT(a > 0 && b > 0);
    ws.submit(a, 101, WaitLane::EcoSystem);
    ws.submit(b, 102, WaitLane::EcoKernel);
    TEST_ASSERT(waitFor([&] {
        return ws.hasReady(WaitLane::EcoSystem) && ws.hasReady(WaitLane::EcoKernel);
    }));
    WaitService::Ready r{};
    TEST_ASSERT(ws.tryPopReady(WaitLane::EcoSystem, r));
    TEST_ASSERT(r.token == 101);
    TEST_ASSERT(r.exitCode == 3);
    TEST_ASSERT(WIFEXITED(r.rawStatus) && WEXITSTATUS(r.rawStatus) == 3);
    TEST_ASSERT(!ws.tryPopReady(WaitLane::EcoSystem, r));
    TEST_ASSERT(ws.tryPopReady(WaitLane::EcoKernel, r));
    TEST_ASSERT(r.token == 102);
    TEST_ASSERT(r.exitCode == 4);
    TEST_ASSERT(!ws.hasReady(WaitLane::EcoKernel));
}

void test_wait_signal_death_is_128_plus_sig() {
    initRuntime();
    auto& ws = WaitService::instance();
    pid_t pid = ::fork();
    if (pid == 0) {
        ::kill(::getpid(), SIGKILL);
        ::_exit(0);  // not reached
    }
    TEST_ASSERT(pid > 0);
    ws.submit(pid, 201, WaitLane::EcoSystem);
    TEST_ASSERT(waitFor([&] { return ws.hasReady(WaitLane::EcoSystem); }));
    WaitService::Ready r{};
    TEST_ASSERT(ws.tryPopReady(WaitLane::EcoSystem, r));
    TEST_ASSERT(r.token == 201);
    TEST_ASSERT(r.exitCode == 128 + SIGKILL);
    TEST_ASSERT(WIFSIGNALED(r.rawStatus) && WTERMSIG(r.rawStatus) == SIGKILL);
    TEST_ASSERT(WaitService::exitCodeFromStatus(r.rawStatus) == 137);
}

// A child that exits (and is reaped by the worker while it waits for another
// child) before its own submit is parked as unclaimed and delivered at submit.
void test_wait_reaped_before_submit_is_delivered() {
    initRuntime();
    auto& ws = WaitService::instance();
    pid_t slow = forkExit(5, /*delayMs=*/400);
    pid_t fast = forkExit(7);
    TEST_ASSERT(slow > 0 && fast > 0);
    ws.submit(slow, 301, WaitLane::EcoKernel);
    // The worker's waitpid(-1) reaps `fast` first; once reaped, the pid is
    // gone (kill(pid, 0) fails with ESRCH; a zombie still answers).
    TEST_ASSERT(waitFor([&] { return ::kill(fast, 0) == -1 && errno == ESRCH; }));
    ws.submit(fast, 302, WaitLane::EcoSystem);
    // Delivered by submit itself, without another waitpid.
    TEST_ASSERT(ws.hasReady(WaitLane::EcoSystem));
    WaitService::Ready r{};
    TEST_ASSERT(ws.tryPopReady(WaitLane::EcoSystem, r));
    TEST_ASSERT(r.token == 302);
    TEST_ASSERT(r.exitCode == 7);
    TEST_ASSERT(waitFor([&] { return ws.hasReady(WaitLane::EcoKernel); }));
    TEST_ASSERT(ws.tryPopReady(WaitLane::EcoKernel, r));
    TEST_ASSERT(r.token == 301);
    TEST_ASSERT(r.exitCode == 5);
}
#endif  // !_WIN32

// ---- exit code export (Phase 2 step 2) --------------------------------------

void test_exit_code_roundtrip() {
    TEST_ASSERT(eco_get_exit_code() == 0);
    eco_set_exit_code(42);
    TEST_ASSERT(eco_get_exit_code() == 42);
    eco_set_exit_code(0);
    TEST_ASSERT(eco_get_exit_code() == 0);
#if !defined(_WIN32)
    // Nothing recorded in the test binary: the calling thread is reported.
    TEST_ASSERT(pthread_equal(eco_process_main_thread(), pthread_self()));
    eco_set_process_main_thread(pthread_self());
    TEST_ASSERT(pthread_equal(eco_process_main_thread(), pthread_self()));
#endif
}

}  // namespace

void registerPlatformServicesTests(IsolatedTestRunner::IsolatedTestCaseSuite& suite) {
    suite.add(Testing::TestCase("platform-services/PS1 quiescence fires once per arming", test_quiescence_fires_once_per_arming));
    suite.add(Testing::TestCase("platform-services/PS2 quiescence listener without async exits", test_quiescence_listener_without_async_exits));
    suite.add(Testing::TestCase("platform-services/PS3 quiescence never in embed mode", test_quiescence_never_in_embed_mode));
    suite.add(Testing::TestCase("platform-services/PS4 timer cancel pending", test_timer_cancel_pending));
    suite.add(Testing::TestCase("platform-services/PS5 timer cancel after fire", test_timer_cancel_after_fire_returns_false));
#if !defined(_WIN32)
    suite.add(Testing::TestCase("platform-services/PS6 wait lanes route results", test_wait_lanes_route_results));
    suite.add(Testing::TestCase("platform-services/PS7 wait signal death 128+sig", test_wait_signal_death_is_128_plus_sig));
    suite.add(Testing::TestCase("platform-services/PS8 wait reaped before submit", test_wait_reaped_before_submit_is_delivered));
#endif
    suite.add(Testing::TestCase("platform-services/PS9 exit code roundtrip", test_exit_code_roundtrip));
}
