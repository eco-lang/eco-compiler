// Unit tests for the Phase 2 runtime prerequisites of eco/system
// (plans/eco-system-library.md §3.7, Phase 2 steps 2, 3, 5, 6). No Elm and no
// heap objects: the Scheduler is driven with an empty run queue, and timer
// tokens that have no registered resume closure (processReadyAsync then only
// decrements pendingAsync).

#include "PlatformServicesTest.hpp"
#include "../../runtime/src/allocator/RuntimeExports.h"
#include "../../runtime/src/platform/PlatformRuntime.hpp"
#include "../../runtime/src/platform/Scheduler.hpp"
#include "../../runtime/src/platform/TaskBinding.hpp"
#include "../../runtime/src/platform/HttpService.hpp"
#include "../../runtime/src/platform/Spawn.hpp"
#include "../../runtime/src/platform/TimerService.hpp"
#include "../../runtime/src/platform/WaitService.hpp"
#include "../allocator/TestHelpers.hpp"
#include "../TestSuite.hpp"

#include <cerrno>
#include <chrono>
#include <cstdint>
#include <functional>
#include <string>
#include <thread>
#include <vector>

#if !defined(_WIN32)
#include <arpa/inet.h>
#include <csignal>
#include <netinet/in.h>
#include <sys/socket.h>
#include <sys/resource.h>
#include <sys/types.h>
#include <sys/wait.h>
#include <unistd.h>
#endif

using Elm::HPointer;
using Elm::u64;
using Elm::Platform::HoldKind;
using Elm::Platform::HoldRelease;
using Elm::Platform::HoldToken;
using Elm::Platform::HttpService;
using Elm::Platform::kNoHold;
using Elm::Platform::LivenessHold;
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

// ---- Scheduler quiescence hook (Phase 2 step 3; L-REARM) -------------------
//
// Since L-REARM (plans/program-liveness-rule.md §7, LIVE_005) the Scheduler
// keeps no armed bit: it asks every listener at each quiescent point and
// continues iff one returned true (delivered). Whether a listener is due is
// its own state (SystemManager's emptyLoopArmed), so these listeners return
// false once they have nothing to do and cannot spin.

// Registrations are process-wide: these tests need a fresh process each,
// which the Windows runner (in-process, serial) does not give. They also
// remove their listener at the end.
#if !defined(_WIN32)

int g_quiescenceCalls = 0;

// First call starts one async op (a 5 ms timer holding a free-standing
// hold, whose token is the timer token: processReadyAsync finds no resume
// for it and releases the hold) and reports a delivery; the second call
// starts nothing and returns false, so the loop exits at that quiescence.
bool listenerStartsAsyncOnce(void* /*ctx*/) {
    g_quiescenceCalls++;
    if (g_quiescenceCalls == 1) {
        HoldToken t = Scheduler::instance().acquireHold(HoldKind::Task, "PS1.timer");
        TimerService::instance().schedule(5.0, t);
        return true;
    }
    return false;
}

bool listenerCountsOnly(void* ctx) {
    (*static_cast<int*>(ctx))++;
    return false;
}

void test_quiescence_fires_once_per_arming() {
    initRuntime();
    g_quiescenceCalls = 0;
    auto& sched = Scheduler::instance();
    sched.addQuiescenceListener(listenerStartsAsyncOnce, nullptr);
    sched.runEventLoop();
    TEST_ASSERT(g_quiescenceCalls == 2);
    sched.removeQuiescenceListener(listenerStartsAsyncOnce, nullptr);
}

void test_quiescence_listener_without_async_exits() {
    initRuntime();
    int calls = 0;
    auto& sched = Scheduler::instance();
    sched.addQuiescenceListener(listenerCountsOnly, &calls);
    sched.runEventLoop();
    TEST_ASSERT(calls == 1);
    // A second run asks the listener once more: the Scheduler keeps no armed
    // bit, and a listener returning false lets the loop exit.
    sched.runEventLoop();
    TEST_ASSERT(calls == 2);
    // Acquiring and releasing a hold does not make the listener deliver.
    sched.releaseHold(sched.acquireHold(HoldKind::Task, "PS2"));
    sched.runEventLoop();
    TEST_ASSERT(calls == 3);
    // A removed listener is no longer asked.
    sched.removeQuiescenceListener(listenerCountsOnly, &calls);
    sched.runEventLoop();
    TEST_ASSERT(calls == 3);
}

void test_quiescence_never_in_embed_mode() {
    initRuntime();
    int calls = 0;
    auto& sched = Scheduler::instance();
    sched.setEmbedMode(true);
    sched.addQuiescenceListener(listenerCountsOnly, &calls);
    sched.runEventLoop();
    TEST_ASSERT(calls == 0);
    sched.removeQuiescenceListener(listenerCountsOnly, &calls);
}

#endif  // !_WIN32

// ---- TimerService::cancel (Phase 2 step 6) ----------------------------------

void test_timer_cancel_pending() {
    initRuntime();
    auto& timers = TimerService::instance();
    const std::uint64_t later = kBogusTokenBase + 10;
    timers.schedule(60000.0, later);
    TEST_ASSERT(timers.cancel(later));
    TEST_ASSERT(!timers.cancel(later));                   // already removed
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
// A child that exits with `code` after `delayMs`, or kills itself with
// SIGKILL: a spawned /bin/sh (plans/spawn-not-fork.md: the harness does not
// fork). Returns its pid, or -1.
pid_t spawnShell(const std::string& script) {
    Elm::platform::SpawnSpec spec;
    spec.program = "/bin/sh";
    spec.args = {"-c", script};
    spec.shellKind = Elm::platform::kShellNone;
    auto c = Elm::platform::spawnChild(spec, Elm::platform::StdioMode::Null, /*newSession=*/false);
    return c.err == 0 ? static_cast<pid_t>(c.pid) : -1;
}

pid_t spawnExit(int code, int delayMs = 0) {
    std::string script;
    if (delayMs > 0) script = "sleep " + std::to_string(delayMs / 1000.0) + "; ";
    return spawnShell(script + "exit " + std::to_string(code));
}

void test_wait_lanes_route_results() {
    initRuntime();
    auto& ws = WaitService::instance();
    pid_t a = spawnExit(3);
    pid_t b = spawnExit(4);
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
    pid_t pid = spawnShell("kill -9 $$");
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

// A child that has exited before its own submit (still a zombie: nothing
// reaps a child nobody has submitted) is delivered once submitted.
void test_wait_exited_before_submit_is_delivered() {
    initRuntime();
    auto& ws = WaitService::instance();
    pid_t fast = spawnExit(7);
    TEST_ASSERT(fast > 0);
    // Wait for the exit without reaping it.
    siginfo_t info{};
    TEST_ASSERT(::waitid(P_PID, static_cast<id_t>(fast), &info, WEXITED | WNOWAIT) == 0);
    ws.submit(fast, 302, WaitLane::EcoSystem);
    TEST_ASSERT(waitFor([&] { return ws.hasReady(WaitLane::EcoSystem); }));
    WaitService::Ready r{};
    TEST_ASSERT(ws.tryPopReady(WaitLane::EcoSystem, r));
    TEST_ASSERT(r.token == 302);
    TEST_ASSERT(r.exitCode == 7);
    TEST_ASSERT(r.error == 0);
}

// A wait in progress reaps only its own child: a child other code started
// (here Spawn.hpp's own spawnChild / waitChild, as a host embedding eco
// would) keeps its status for its own waiter. Before the per-child waits, the
// worker's waitpid(-1) reaped it and waitChild failed with ECHILD.
void test_wait_leaves_other_children_alone() {
    initRuntime();
    auto& ws = WaitService::instance();
    pid_t slow = spawnExit(5, /*delayMs=*/600);
    TEST_ASSERT(slow > 0);
    ws.submit(slow, 401, WaitLane::EcoKernel);

    Elm::platform::SpawnSpec spec;
    spec.program = "/bin/sh";
    spec.args = {"-c", "exit 9"};
    spec.shellKind = Elm::platform::kShellNone;
    auto other = Elm::platform::spawnChild(spec, Elm::platform::StdioMode::Null, /*newSession=*/false);
    TEST_ASSERT(other.err == 0);
    // Let `other` exit while the wait for `slow` is in progress.
    siginfo_t info{};
    TEST_ASSERT(::waitid(P_PID, static_cast<id_t>(other.pid), &info, WEXITED | WNOWAIT) == 0);
    std::this_thread::sleep_for(std::chrono::milliseconds(100));
    Elm::platform::ChildExit ex = Elm::platform::waitChild(other);
    TEST_ASSERT(ex.exited);
    TEST_ASSERT(ex.code == 9);

    TEST_ASSERT(waitFor([&] { return ws.hasReady(WaitLane::EcoKernel); }));
    WaitService::Ready r{};
    TEST_ASSERT(ws.tryPopReady(WaitLane::EcoKernel, r));
    TEST_ASSERT(r.token == 401);
    TEST_ASSERT(r.exitCode == 5);
}

// A pid that is not a child of this process is answered at once as a failed
// wait (error set, exit code kWaitFailedExitCode), not left pending while the
// worker polls forever.
void test_wait_for_non_child_fails_promptly() {
    initRuntime();
    auto& ws = WaitService::instance();
    pid_t notOurs = ::getppid();
    ws.submit(notOurs, 501, WaitLane::EcoSystem);
    TEST_ASSERT(waitFor([&] { return ws.hasReady(WaitLane::EcoSystem); }, 2000));
    WaitService::Ready r{};
    TEST_ASSERT(ws.tryPopReady(WaitLane::EcoSystem, r));
    TEST_ASSERT(r.token == 501);
    TEST_ASSERT(r.error == ECHILD);
    TEST_ASSERT(r.exitCode == WaitService::kWaitFailedExitCode);
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

// ---- Liveness holds (plans/program-liveness-rule.md §5.1, §11.2 PS4-PS9) ----

// PS4: LivenessHold acquire / move / release; move-assign releases the old one.
void test_liveness_hold_raii() {
    initRuntime();
    auto& s = Scheduler::instance();
    TEST_ASSERT(s.pendingAsync() == 0);
    {
        LivenessHold a = LivenessHold::acquire(HoldKind::Task, "ps4.a");
        TEST_ASSERT(a);
        TEST_ASSERT((a.token() & Elm::Platform::kFreeHoldBit) != 0);
        TEST_ASSERT(s.pendingAsync() == 1);
        LivenessHold b(std::move(a));                  // move: still one hold
        TEST_ASSERT(!a && b);
        TEST_ASSERT(s.pendingAsync() == 1);
        LivenessHold c = LivenessHold::acquire(HoldKind::Item, "ps4.c");
        TEST_ASSERT(s.pendingAsync() == 2);
        HoldToken bt = b.token();
        c = std::move(b);                              // releases c's own hold
        TEST_ASSERT(s.pendingAsync() == 1);
        TEST_ASSERT(c.token() == bt);
        c.release();
        c.release();                                   // idempotent
        TEST_ASSERT(s.pendingAsync() == 0);
        LivenessHold d = LivenessHold::acquire(HoldKind::Subscription, "ps4.d");
        HoldToken dt = d.detach();
        TEST_ASSERT(!d && s.pendingAsync() == 1);
        LivenessHold e = LivenessHold::adopt(dt);
        TEST_ASSERT(s.pendingAsync() == 1);
        // e released by its destructor
    }
    TEST_ASSERT(s.pendingAsync() == 0);
    {
        HoldToken t = s.acquireHold(HoldKind::Item, "ps4.hr");
        HoldRelease r(t);
        TEST_ASSERT(s.pendingAsync() == 1);
    }
    TEST_ASSERT(s.pendingAsync() == 0);
    if (s.holdCensusEnabled()) TEST_ASSERT(s.liveHoldCount() == 0);
}

#if !defined(_WIN32)
// Runs `f` in a forked child (no core dump) with stderr captured.
template <class F> int runDeathChild(F f, std::string& err) {
    int fds[2];
    if (pipe(fds) != 0) return -1;
    pid_t pid = fork();
    if (pid == 0) {
        struct rlimit rl{0, 0};
        setrlimit(RLIMIT_CORE, &rl);
        close(fds[0]);
        dup2(fds[1], 2);
        close(fds[1]);
        f();
        _exit(0);
    }
    close(fds[1]);
    char buf[4096];
    ssize_t r;
    while ((r = read(fds[0], buf, sizeof buf)) > 0) err.append(buf, static_cast<size_t>(r));
    close(fds[0]);
    int st = 0;
    waitpid(pid, &st, 0);
    return st;
}

// PS5: a second releaseHold aborts and names the acquiring site (census
// builds); so does releasing an unknown token.
void test_liveness_double_release_aborts() {
    if (!Scheduler::instance().holdCensusEnabled()) return;   // release build: no census
    std::string err;
    int st = runDeathChild([] {
        initRuntime();
        auto& s = Scheduler::instance();
        HoldToken t = s.acquireHold(HoldKind::Task, "ps5.site");
        s.releaseHold(t);
        s.releaseHold(t);
    }, err);
    TEST_ASSERT(WIFSIGNALED(st) && WTERMSIG(st) == SIGABRT);
    TEST_ASSERT(err.find("second release") != std::string::npos);
    TEST_ASSERT(err.find("ps5.site") != std::string::npos);

    std::string err2;
    st = runDeathChild([] {
        initRuntime();
        Scheduler::instance().releaseHold(kBogusTokenBase + 99);
    }, err2);
    TEST_ASSERT(WIFSIGNALED(st) && WTERMSIG(st) == SIGABRT);
    TEST_ASSERT(err2.find("unknown hold") != std::string::npos);

    std::string err3;
    st = runDeathChild([] {
        initRuntime();
        Scheduler::instance().releaseHold(kNoHold);
    }, err3);
    TEST_ASSERT(WIFSIGNALED(st) && WTERMSIG(st) == SIGABRT);
}
#endif

// PS6: parkResume's token is the resume token; releaseHold(token) balances.
void test_liveness_park_resume_token() {
    initRuntime();
    auto& s = Scheduler::instance();
    HPointer resume = Elm::alloc::allocFloat(1.5);   // any heap value
    Elm::StackRootGuard rg(&resume);
    u64 t = s.parkResume(resume, HoldKind::Task, "ps6.park");
    TEST_ASSERT(t != 0);
    TEST_ASSERT((t & Elm::Platform::kFreeHoldBit) == 0);
    TEST_ASSERT(s.pendingAsync() == 1);
    if (s.holdCensusEnabled()) TEST_ASSERT(s.holdIsLive(t));
    HPointer back = s.takePendingResume(t);            // registered under the same token
    TEST_ASSERT(!Elm::alloc::isNil(back));
    s.releaseHold(t);
    TEST_ASSERT(s.pendingAsync() == 0);
    if (s.holdCensusEnabled()) TEST_ASSERT(!s.holdIsLive(t));

    // The timer path: processReadyAsync releases the parked token's hold
    // (its resume was taken above, so it finds Nil and only releases).
    u64 t2 = s.parkResume(resume, HoldKind::Task, "ps6.timer");
    (void)s.takePendingResume(t2);
    TimerService::instance().schedule(1.0, t2);
    s.runEventLoop();
    TEST_ASSERT(s.pendingAsync() == 0);
}

// PS7: host threads acquire/release concurrently while the eco loop waits.
// The loop must see 0 at the end and exit (no lost wakeup).
void test_liveness_concurrent_host_threads() {
    initRuntime();
    auto& s = Scheduler::instance();
    HoldToken gate = s.acquireHold(HoldKind::Task, "ps7.gate");
    std::vector<std::thread> threads;
    for (int k = 0; k < 4; ++k) {
        threads.emplace_back([&s] {
            for (int i = 0; i < 10000; ++i) {
                HoldToken t = s.acquireHold(HoldKind::Port, "ps7.thread");
                s.releaseHold(t);
            }
        });
    }
    std::thread closer([&] {
        for (auto& th : threads) th.join();
        s.releaseHold(gate);
    });
    s.runEventLoop();              // returns once every hold is released
    closer.join();
    TEST_ASSERT(s.pendingAsync() == 0);
    if (s.holdCensusEnabled()) TEST_ASSERT(s.liveHoldCount() == 0);
}

#if !defined(_WIN32)
// PS8: the census report lists a live hold's kind and site.
void test_liveness_census_report() {
    initRuntime();
    auto& s = Scheduler::instance();
    if (!s.holdCensusEnabled()) return;
    std::string err;
    int st = runDeathChild([] {
        initRuntime();
        auto& s2 = Scheduler::instance();
        HoldToken t = s2.acquireHold(HoldKind::Subscription, "ps8.census.site");
        s2.reportHolds("ps8");
        s2.releaseHold(t);
        s2.reportHolds("ps8-after");
    }, err);
    TEST_ASSERT(WIFEXITED(st) && WEXITSTATUS(st) == 0);
    auto first = err.find("liveness report (ps8)");
    auto after = err.find("liveness report (ps8-after)");
    TEST_ASSERT(first != std::string::npos && after != std::string::npos);
    std::string live = err.substr(first, after - first);
    TEST_ASSERT(live.find("Subscription") != std::string::npos);
    TEST_ASSERT(live.find("ps8.census.site") != std::string::npos);
    TEST_ASSERT(err.substr(after).find("ps8.census.site") == std::string::npos);
}
#endif

// PS9 (LIVE_004): a manager's onEffects runs inside the drain that ran the
// update which produced the effects, before that drain returns.
int g_ps9EffectsDepth = -1;
int g_ps9BodyDepth = -1;
bool g_ps9OuterDrainReturned = false;
bool g_ps9EffectsBeforeReturn = false;

void* ps9OnEffects(void* args[]) {
    // args: router, cmds, subs, state
    g_ps9EffectsDepth = Scheduler::instance().drainDepth();
    g_ps9EffectsBeforeReturn = !g_ps9OuterDrainReturned;
    HPointer state = Elm::Platform::detail::decodeBits(reinterpret_cast<uint64_t>(args[3]));
    return reinterpret_cast<void*>(Elm::Platform::detail::encodeBits(
        Scheduler::instance().taskSucceed(state)));
}

void* ps9OnSelfMsg(void* args[]) {
    HPointer state = Elm::Platform::detail::decodeBits(reinterpret_cast<uint64_t>(args[2]));
    return reinterpret_cast<void*>(Elm::Platform::detail::encodeBits(
        Scheduler::instance().taskSucceed(state)));
}

void* ps9SendToApp(void* /*args*/[]) {
    return reinterpret_cast<void*>(Elm::Platform::detail::encodeBits(Elm::alloc::unit()));
}

HPointer ps9UpdateBody(HPointer /*captured*/) {
    g_ps9BodyDepth = Scheduler::instance().drainDepth();
    Elm::Platform::PlatformRuntime::instance().enqueueEffects(Elm::alloc::listNil(),
                                                              Elm::alloc::listNil());
    return Scheduler::instance().taskSucceed(Elm::alloc::unit());
}

void test_liveness_effects_inside_update_drain() {
    initRuntime();
    auto& s = Scheduler::instance();
    auto& pr = Elm::Platform::PlatformRuntime::instance();
    using Elm::Platform::detail::encodeBits;
    HPointer init = s.taskSucceed(Elm::alloc::unit());
    Elm::StackRootGuard g1(&init);
    HPointer onEffects = Elm::alloc::allocClosure(ps9OnEffects, 4);
    Elm::StackRootGuard g2(&onEffects);
    HPointer onSelf = Elm::alloc::allocClosure(ps9OnSelfMsg, 3);
    Elm::StackRootGuard g3(&onSelf);
    Elm::Platform::PlatformRuntime::ManagerInfo info{
        encodeBits(init), encodeBits(onEffects), encodeBits(onSelf),
        encodeBits(Elm::alloc::listNil()), encodeBits(Elm::alloc::listNil())};
    pr.registerManager("PS9", info);
    HPointer sendToApp = Elm::alloc::allocClosure(ps9SendToApp, 2);
    (void)pr.setupEffects(sendToApp);
    s.drain();

    HPointer task = Elm::Platform::makeBinding<ps9UpdateBody>(Elm::alloc::unit());
    (void)s.rawSpawn(task);
    s.drain();                                         // the "update's drain"
    g_ps9OuterDrainReturned = true;
    TEST_ASSERT(g_ps9BodyDepth == 1);
    TEST_ASSERT(g_ps9EffectsDepth >= 1);
    TEST_ASSERT(g_ps9EffectsBeforeReturn);
    TEST_ASSERT(s.drainDepth() == 0);
}

// ---- Withdrawal (plans/program-liveness-rule.md §5.3, phase 3) -------------

// PS10: a sleep's kill (withdrawParkedTimer, as the Process.sleep kill handle
// runs it) racing the timer's firing: schedule(0 ms) then withdraw at once,
// 1,000 times. Whichever side wins, exactly one release happens (a double
// release aborts in census builds) and pendingAsync returns to 0.
void test_liveness_sleep_kill_races_fire() {
    initRuntime();
    auto& s = Scheduler::instance();
    HPointer resume = Elm::alloc::allocFloat(2.5);   // any heap value
    Elm::StackRootGuard rg(&resume);
    for (int i = 0; i < 1000; ++i) {
        u64 t = s.parkResume(resume, HoldKind::Task, "ps10.sleep");
        TimerService::instance().schedule(0.0, t);
        if (i % 2 == 1) std::this_thread::yield();   // vary the interleaving
        Elm::Platform::withdrawParkedTimer(t);
        s.runEventLoop();          // drains a fired token (Nil resume: release only)
        TEST_ASSERT(s.pendingAsync() == 0);
        TEST_ASSERT(Elm::alloc::isNil(s.takePendingResume(t)));
        if (s.holdCensusEnabled()) TEST_ASSERT(!s.holdIsLive(t));
    }
    TEST_ASSERT(!TimerService::instance().hasReadyTokens());
}

#if !defined(_WIN32)
// A loopback TCP listener that never accepts: the kernel completes the
// handshake from the backlog, so a request to it waits for a response forever.
struct SilentListener {
    int fd = -1;
    int port = 0;
    SilentListener() {
        fd = ::socket(AF_INET, SOCK_STREAM, 0);
        sockaddr_in a{};
        a.sin_family = AF_INET;
        a.sin_addr.s_addr = htonl(INADDR_LOOPBACK);
        a.sin_port = 0;
        if (fd < 0 || ::bind(fd, reinterpret_cast<sockaddr*>(&a), sizeof a) != 0 ||
            ::listen(fd, 8) != 0) {
            return;
        }
        socklen_t len = sizeof a;
        ::getsockname(fd, reinterpret_cast<sockaddr*>(&a), &len);
        port = ntohs(a.sin_port);
    }
    ~SilentListener() { if (fd >= 0) ::close(fd); }
};

// PS11: RequestControl on the HTTP worker (single, serial). Request A blocks
// the worker; B queues behind it. abort(B) claims it (true) and the worker
// never posts a result for B. abort(A) while running is false and stops curl:
// A's result arrives as a NetworkError.
void test_liveness_http_abort_queued_and_running() {
    initRuntime();
    SilentListener srv;
    TEST_ASSERT(srv.port != 0);
    std::string url = "http://127.0.0.1:" + std::to_string(srv.port) + "/";
    auto& http = HttpService::instance();
    using RC = HttpService::RequestControl;

    auto ca = std::make_shared<RC>();
    auto cb = std::make_shared<RC>();
    HttpService::Request a;
    a.token = kBogusTokenBase + 1101;
    a.method = "GET";
    a.url = url;
    a.control = ca;
    HttpService::Request b = a;
    b.token = kBogusTokenBase + 1102;
    b.control = cb;
    http.submit(std::move(a));
    http.submit(std::move(b));

    TEST_ASSERT(waitFor([&] { return ca->state.load() == RC::Running; }));
    TEST_ASSERT(cb->state.load() == RC::Queued);
    TEST_ASSERT(cb->abort());                          // claimed while queued
    TEST_ASSERT(cb->state.load() == RC::Aborted);
    TEST_ASSERT(!cb->abort());                         // already claimed

    TEST_ASSERT(!ca->abort());                         // running: told to stop
    TEST_ASSERT(ca->state.load() == RC::AbortRequested);
    HttpService::Result r;
    TEST_ASSERT(waitFor([&] { return http.tryPopResult(r); }, 10000));
    TEST_ASSERT(r.token == kBogusTokenBase + 1101);
    TEST_ASSERT(r.error == HttpService::ErrorKind::NetworkError);

    // The worker pops B next and skips it: nothing is ever posted for B.
    std::this_thread::sleep_for(std::chrono::milliseconds(300));
    TEST_ASSERT(!http.hasReadyResults());
    TEST_ASSERT(cb->state.load() == RC::Aborted);
}
#endif

// PS12: dropping a Time.every withdraws its stored tick. TimeEffectManager's
// unsubscribe path withdraws the interval's recorded tick token with
// withdrawParkedTimer (the test binary does not link elm-kernel-cpp, so the
// manager itself is covered by the E2E test LiveTimeEveryDropTest): the hold
// is gone at once, and the event loop ends without waiting for the interval.
void test_liveness_time_every_drop_cancels_tick() {
    initRuntime();
    auto& s = Scheduler::instance();
    HPointer tick = Elm::alloc::allocFloat(3.5);   // stands for the tick closure
    Elm::StackRootGuard rg(&tick);
    u64 t = s.parkResume(tick, HoldKind::Task, "ps12.every");
    TimerService::instance().schedule(120000.0, t);
    TEST_ASSERT(s.pendingAsync() == 1);
    Elm::Platform::withdrawParkedTimer(t);
    TEST_ASSERT(s.pendingAsync() == 0);                // dropped at once
    auto t0 = std::chrono::steady_clock::now();
    s.runEventLoop();
    auto took = std::chrono::steady_clock::now() - t0;
    TEST_ASSERT(took < std::chrono::seconds(5));
    TEST_ASSERT(!TimerService::instance().cancel(t));  // no timer left
}

}  // namespace

void registerPlatformServicesTests(IsolatedTestRunner::IsolatedTestCaseSuite& suite) {
#if !defined(_WIN32)
    suite.add(Testing::TestCase("platform-services/PS1 quiescence continues only while a listener delivers", test_quiescence_fires_once_per_arming));
    suite.add(Testing::TestCase("platform-services/PS2 quiescence listener returning false exits", test_quiescence_listener_without_async_exits));
    suite.add(Testing::TestCase("platform-services/PS3 quiescence never in embed mode", test_quiescence_never_in_embed_mode));
#endif
    suite.add(Testing::TestCase("platform-services/PS4 timer cancel pending", test_timer_cancel_pending));
    suite.add(Testing::TestCase("platform-services/PS5 timer cancel after fire", test_timer_cancel_after_fire_returns_false));
#if !defined(_WIN32)
    suite.add(Testing::TestCase("platform-services/PS6 wait lanes route results", test_wait_lanes_route_results));
    suite.add(Testing::TestCase("platform-services/PS7 wait signal death 128+sig", test_wait_signal_death_is_128_plus_sig));
    suite.add(Testing::TestCase("platform-services/PS8 wait exited before submit", test_wait_exited_before_submit_is_delivered));
    suite.add(Testing::TestCase("platform-services/PS8b wait leaves other children alone", test_wait_leaves_other_children_alone));
    suite.add(Testing::TestCase("platform-services/PS8c wait for a non-child fails promptly", test_wait_for_non_child_fails_promptly));
#endif
    suite.add(Testing::TestCase("platform-services/PS9 exit code roundtrip", test_exit_code_roundtrip));
    // plans/program-liveness-rule.md §11.2 PS4-PS9 (prefixed "liveness": the
    // PS4-PS9 numbers above predate the plan).
    suite.add(Testing::TestCase("platform-services/liveness PS4 LivenessHold acquire move release", test_liveness_hold_raii));
#if !defined(_WIN32)
    suite.add(Testing::TestCase("platform-services/liveness PS5 double release aborts", test_liveness_double_release_aborts));
#endif
    suite.add(Testing::TestCase("platform-services/liveness PS6 parkResume token", test_liveness_park_resume_token));
    suite.add(Testing::TestCase("platform-services/liveness PS7 concurrent host threads", test_liveness_concurrent_host_threads));
#if !defined(_WIN32)
    suite.add(Testing::TestCase("platform-services/liveness PS8 census report", test_liveness_census_report));
#endif
    suite.add(Testing::TestCase("platform-services/liveness PS9 onEffects inside update drain", test_liveness_effects_inside_update_drain));
    suite.add(Testing::TestCase("platform-services/liveness PS10 sleep kill races fire", test_liveness_sleep_kill_races_fire));
#if !defined(_WIN32)
    suite.add(Testing::TestCase("platform-services/liveness PS11 http abort queued and running", test_liveness_http_abort_queued_and_running));
#endif
    suite.add(Testing::TestCase("platform-services/liveness PS12 Time.every drop cancels tick", test_liveness_time_every_drop_cancels_tick));
}
