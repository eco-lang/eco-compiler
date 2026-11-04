// Core service unit tests of eco-system-core-test (system-kernel-cpp/src/eco-system/Core/): the work pool,
// the reactor's start-up, and the async-failure helpers of the kernel guards.
//
// The CORE-* bugs below are fixed; each check is now a plain CHECK that guards against a regression.
//
//   CORE-01  SysWorkPool's constructor lets `std::system_error` escape when a later worker cannot be
//            started, after an earlier worker already runs on `this` (use-after-free), and a second
//            `instance()` constructs the pool again. Child scenario "work-pool/partial-start", with the
//            worker-start hook failing the second start.
//   CORE-07  `detail::failureFor(RunErr, what)` builds `failRun(0, "EIO", -1, "", "")`, dropping the
//            exception message. In process: stderr of the RunErr failure is empty today.
//   CORE-08  `detail::asyncFailure` resumes the task again (and releases a counted hold again) when the
//            body had already completed the task before it threw. Variant A in process (uncounted
//            park: two resumes), variant B in child "core/async-failure-counted-park" (counted park: the hold census
//            aborts on the second release, or pendingAsync drops by two).
//   CORE-14  `IoReactor::Impl::backendInit` (epoll) returns false on an `eventfd` failure without
//            closing the epoll fd it has opened. Child "io-reactor/init-failure-fd-leak", with
//            RLIMIT_NOFILE leaving room for exactly one new descriptor.
//   CORE-18  `SysWorkPool::workerLoop` builds `PoolException{e.what()}` inside its `catch`; when that
//            allocation throws `std::bad_alloc` the exception leaves the thread function and the
//            process terminates. Child "work-pool/oom-in-exception-handler", with a replacement
//            `operator new` (below) armed to fail once on the worker.

#include "EcoSystemCoreTest.hpp"

#include "eco-system/Core/Core.hpp"
#include "eco-system/Core/IoReactor.hpp"
#include "eco-system/Core/SysWorkPool.hpp"
#include "eco-system/Stream/StreamTable.hpp"

#include <atomic>
#include <cerrno>
#include <chrono>
#include <csignal>
#include <cstdio>
#include <cstdlib>
#include <new>
#include <stdexcept>
#include <string>
#include <system_error>
#include <thread>

#if !defined(_WIN32)
#include <fcntl.h>
#include <sys/resource.h>
#include <unistd.h>
#endif

using namespace Eco::System;

// ---------------------------------------------------------------------------
// CORE-18: a replacement global `operator new`, armed per thread to fail.
//
// While `g_core18FailNews` is above 0 on the calling thread, `operator new(size_t)` decrements it and
// throws `std::bad_alloc`; otherwise it allocates with `malloc`, which the library's `operator delete`
// frees. The array and nothrow forms of the library call this one. Nothing in the binary arms it but
// the CORE-18 scenario, so every other test sees an ordinary allocator. It is weak so that another
// replacement elsewhere in this binary does not clash at link time; `g_core18HookFired` lets the
// scenario tell whether this definition is the one in use.
namespace {
thread_local int g_core18FailNews = 0;
std::atomic<int> g_core18HookFired{0};
}  // namespace

__attribute__((weak)) void* operator new(std::size_t n) {
    if (g_core18FailNews > 0) {
        --g_core18FailNews;
        g_core18HookFired.fetch_add(1, std::memory_order_relaxed);
        throw std::bad_alloc();
    }
    void* p = std::malloc(n ? n : 1);
    if (!p) throw std::bad_alloc();
    return p;
}

namespace {

using Clock = std::chrono::steady_clock;

bool contains(const std::string& s, const char* needle) { return s.find(needle) != std::string::npos; }

// ---------------------------------------------------------------------------
// CORE-07: failureFor(RunErr) drops the message.

HPointer throwingRunErrBody(HPointer) {
    ECO_SYSTEM_BODY_GUARD(RunErr,
        throw std::runtime_error("spawn table full");
    )
}

void testRunErrKeepsMessage() {
    std::printf("core/failure-for-run-err-keeps-the-exception-message\n");
    HPointer t = throwingRunErrBody(alloc::unit());
    Elm::StackRootGuard g(&t);
    auto* task = static_cast<Elm::Task*>(Allocator::instance().resolve(t));
    CHECK(task->ctor == Elm::alloc::Task_Fail);
    if (task->ctor != Elm::alloc::Task_Fail) return;
    Tuple3* outer = asTuple3(task->value.p);
    CHECK(outer->a.i == 0);
    CHECK(toStdString(outer->b.p) == "EIO");
    Tuple3* inner = asTuple3(outer->c.p);
    CHECK(inner->a.i == -1);
    const std::string err = toStdBytes(inner->c.p);
    CHECK_MSG(err == "spawn table full",
              "CORE-07: RunErr stderr field is \"" + err + "\", expected \"spawn table full\"");
}

// ---------------------------------------------------------------------------
// CORE-08: asyncFailure completes a Task twice.

int g_core08Calls = 0;
uint16_t g_core08LastCtor = 0xFFFF;
uint16_t g_core08FirstCtor = 0xFFFF;

void* core08RecordResumeEval(void* args[]) {
    HPointer task = dec(args[0]);
    auto* t = static_cast<Elm::Task*>(Allocator::instance().resolve(task));
    if (g_core08Calls == 0) g_core08FirstCtor = static_cast<uint16_t>(t->ctor);
    g_core08LastCtor = static_cast<uint16_t>(t->ctor);
    ++g_core08Calls;
    return reinterpret_cast<void*>(enc(alloc::unit()));
}

// An async body that parks `resume`, completes its Task synchronously the way `pumpStream` does
// (`streamCompleteOk`), and then throws. With `countedPark` the park also acquires the token's hold.
HPointer completesThenThrowsBody(HPointer resume, bool countedPark) {
    uint64_t token = 0;
    bool counted = false;
    ECO_SYSTEM_ASYNC_GUARD(FErr, resume, token, counted,
        auto& sched = Scheduler::instance();
        if (countedPark) {
            token = sched.parkResume(resume, HoldKind::Task, "test.core08");
            counted = true;
        } else {
            token = sched.registerPendingResume(resume);
        }
        streamCompleteOk(token, counted, alloc::unit());
        throw std::runtime_error("late");
    )
}

void runCompletesThenThrows(bool countedPark) {
    g_core08Calls = 0;
    g_core08FirstCtor = g_core08LastCtor = 0xFFFF;
    HPointer resume = alloc::allocClosureK(&core08RecordResumeEval, 1, PK_Boxed);
    Elm::StackRootGuard g(&resume);
    (void)completesThenThrowsBody(resume, countedPark);
}

void testAsyncFailureUncounted() {
    std::printf("core/async-failure-after-a-synchronous-completion (uncounted park)\n");
    runCompletesThenThrows(false);
    CHECK_MSG(g_core08Calls >= 1 && g_core08FirstCtor == Elm::alloc::Task_Succeed,
              "precondition: the body's own completion resumed with Task_Succeed (calls " +
                  std::to_string(g_core08Calls) + ")");
    CHECK_MSG(g_core08Calls == 1, "CORE-08: resume called " + std::to_string(g_core08Calls) +
                                      " times, last ctor " + std::to_string(g_core08LastCtor) +
                                      " (1 = Task_Fail \"late\")");
}

// Child: the counted variant. Exit 0 when the Task was completed once and the hold count is back where
// it was; 1 when resume ran twice or the hold count moved. A census build aborts inside the second
// releaseHold ("second release of a hold").
int scenarioCore08Counted() {
    initCoreRuntime();
    auto& sched = Scheduler::instance();
    const int before = sched.pendingAsync();
    runCompletesThenThrows(true);
    const int after = sched.pendingAsync();
    std::printf("core08-counted: calls %d first %u last %u pendingAsync %d -> %d census %d\n", g_core08Calls,
                g_core08FirstCtor, g_core08LastCtor, before, after, sched.holdCensusEnabled() ? 1 : 0);
    std::fflush(stdout);
    if (g_core08Calls < 1 || g_core08FirstCtor != Elm::alloc::Task_Succeed) return 3;   // precondition
    return (g_core08Calls == 1 && after == before) ? 0 : 1;
}

void testAsyncFailureCounted() {
    std::printf("core/async-failure-after-a-synchronous-completion (counted park, child)\n");
    auto r = ChildScenario::runChildScenario("core/async-failure-counted-park", {}, 30000);
    CHECK_MSG(r.started && r.ok(), "core/async-failure-counted-park: " + r.describe() + "; stdout: " + r.out +
                                       "; stderr: " + r.err);
}

#if !defined(_WIN32)

// ---------------------------------------------------------------------------
// CORE-01: SysWorkPool partial thread start.

#if ECO_TEST_HOOKS
std::atomic<int> g_core01Starts{0};

// Starts the first worker normally and fails the second start, as std::thread does when the system
// cannot create a thread; any later start succeeds.
void core01Starter(std::function<void()> body) {
    const int n = g_core01Starts.fetch_add(1) + 1;
    if (n == 2) throw std::system_error(EAGAIN, std::generic_category(), "test: cannot start thread");
    std::thread(std::move(body)).detach();
}

PoolResult core01Work() { return PoolResult::of(int64_t{42}); }
HPointer core01Complete(PoolResult&) { return succeedUnit(); }

// Exit 0: no exception escaped, one worker counted, the constructor ran once, and a job completes.
// Exit 1: the defect (first instance() threw, or a second instance() constructed the pool again).
// Exit 3: the precondition failed (the hook was not called a second time).
int scenarioCore01PartialStart() {
    initCoreRuntime();
    SysWorkPool::setWorkerStarterForTest(&core01Starter);
    bool firstThrew = false;
    bool secondThrew = false;
    SysWorkPool* p = nullptr;
    try {
        p = &SysWorkPool::instance();
    } catch (const std::system_error& e) {
        firstThrew = true;
        std::printf("core01: first instance() threw: %s\n", e.what());
        std::fflush(stdout);
    }
    const int startsAfterFirst = g_core01Starts.load();
    if (startsAfterFirst < 2) {
        std::printf("core01: precondition: starter called %d times (hardware_concurrency %u)\n",
                    startsAfterFirst, std::thread::hardware_concurrency());
        return 3;
    }
    try {
        p = &SysWorkPool::instance();
    } catch (const std::system_error& e) {
        secondThrew = true;
        std::printf("core01: second instance() threw: %s\n", e.what());
    }
    const int startsAfterSecond = g_core01Starts.load();
    std::printf("core01: starter calls %d after first, %d after second; threadCount %zu\n", startsAfterFirst,
                startsAfterSecond, p ? p->threadCount() : size_t(0));
    std::fflush(stdout);
    if (firstThrew || secondThrew || startsAfterSecond != startsAfterFirst) return 1;
    if (p->threadCount() != 1) {
        std::printf("core01: threadCount %zu, expected 1\n", p->threadCount());
        return 1;
    }
    auto& sched = Scheduler::instance();
    const uint64_t token = sched.parkResume(alloc::unit(), HoldKind::Task, "test.core01");
    p->submit(token, &core01Work, &core01Complete);
    SysWorkPool::Item item;
    bool popped = false;
    const auto deadline = Clock::now() + std::chrono::seconds(10);
    while (!(popped = p->tryPop(item)) && Clock::now() < deadline) {
        std::this_thread::sleep_for(std::chrono::milliseconds(1));
    }
    (void)sched.takePendingResume(token);
    sched.releaseHold(token);
    std::printf("core01: job %s\n", popped ? "completed" : "did not complete");
    return popped && item.result.holds<int64_t>() ? 0 : 1;
}
#endif

void testPoolPartialStart() {
    std::printf("work-pool/survives-a-worker-that-cannot-be-started (child)\n");
#if ECO_TEST_HOOKS
    if (std::thread::hardware_concurrency() < 2) {
        std::printf("  skipped: hardware_concurrency < 2, the pool starts one worker only\n");
        return;
    }
    auto r = ChildScenario::runChildScenario("work-pool/partial-start", {}, 30000);
    CHECK_MSG(r.started && r.ok(), "work-pool/partial-start: " + r.describe() + "; stdout: " + r.out +
                                       "; stderr: " + r.err);
#else
    std::printf("  skipped: no test hooks in this build\n");
#endif
}

// ---------------------------------------------------------------------------
// CORE-14: backendInit partial failure leaks the epoll fd.

#if defined(__linux__)
bool fdOpen(int fd) { return ::fcntl(fd, F_GETFD) != -1 || errno != EBADF; }

std::string fdTarget(int fd) {
    char path[64], buf[256];
    std::snprintf(path, sizeof path, "/proc/self/fd/%d", fd);
    ssize_t n = ::readlink(path, buf, sizeof buf - 1);
    if (n < 0) return "(closed)";
    buf[n] = '\0';
    return buf;
}

// Exit 0: the epoll fd was closed. Exit 1: it is still open (leak). Exit 3: precondition failed.
int scenarioCore14ReactorInitFdLeak() {
    int f0 = 0;
    while (fdOpen(f0)) ++f0;
    int f1 = f0 + 1;
    while (fdOpen(f1)) ++f1;
    struct rlimit old {};
    if (::getrlimit(RLIMIT_NOFILE, &old) != 0) return 3;
    struct rlimit lim = old;
    lim.rlim_cur = static_cast<rlim_t>(f1);   // only f0 can be opened
    if (::setrlimit(RLIMIT_NOFILE, &lim) != 0) return 3;
    (void)IoReactor::instance();   // epoll_create1 takes f0, eventfd fails with EMFILE
    ::setrlimit(RLIMIT_NOFILE, &old);
    const std::string target = fdTarget(f0);
    const bool open = fdOpen(f0);
    std::printf("core14: f0 %d f1 %d; after IoReactor::instance() f0 is %s (%s)\n", f0, f1,
                open ? "open" : "closed", target.c_str());
    std::fflush(stdout);
    if (open && target.find("eventpoll") == std::string::npos) return 3;   // something else took f0
    return open ? 1 : 0;
}
#endif

void testReactorInitFdLeak() {
    std::printf("io-reactor/backend-init-failure-closes-what-it-opened (child)\n");
#if defined(__linux__)
    auto r = ChildScenario::runChildScenario("io-reactor/init-failure-fd-leak", {}, 30000);
    CHECK_MSG(contains(r.err, "cannot create the event loop"),
              "precondition: the reactor reported the init failure; stderr: " + r.err);
    CHECK_MSG(r.started && r.ok(),
              "CORE-14 child: " + r.describe() + "; stdout: " + r.out + "; stderr: " + r.err);
#else
    std::printf("  skipped: epoll only\n");
#endif
}

// ---------------------------------------------------------------------------
// CORE-18: PoolResult::of throwing inside the worker's catch.

HPointer core18Complete(PoolResult&) { return succeedUnit(); }

// Exit 0: the job's result is a PoolException. Exit 1: some other result. Exit 3: no result arrived.
// Exit 4: the operator new hook never fired (another replacement is in use). Before the fix the worker
// terminated the process (SIGABRT).
int scenarioCore18PoolOomInHandler() {
    initCoreRuntime();
    auto& pool = SysWorkPool::instance();
    auto& sched = Scheduler::instance();
    const uint64_t token = sched.parkResume(alloc::unit(), HoldKind::Task, "test.core18");
    pool.submit(token,
                []() -> PoolResult {
                    std::runtime_error e(std::string(100, 'x'));   // longer than any SSO buffer
                    g_core18FailNews = 1;                           // the catch's string allocation fails
                    throw e;
                },
                &core18Complete);
    SysWorkPool::Item item;
    bool popped = false;
    const auto deadline = Clock::now() + std::chrono::seconds(10);
    while (!(popped = pool.tryPop(item)) && Clock::now() < deadline) {
        std::this_thread::sleep_for(std::chrono::milliseconds(1));
    }
    (void)sched.takePendingResume(token);
    sched.releaseHold(token);
    const int fired = g_core18HookFired.load();
    std::printf("core18: popped %d, hook fired %d, PoolException %d\n", popped ? 1 : 0, fired,
                popped && item.result.holds<PoolException>() ? 1 : 0);
    std::fflush(stdout);
    if (fired == 0) return 4;
    if (!popped) return 3;
    return item.result.holds<PoolException>() ? 0 : 1;
}

void testPoolOomInHandler() {
    std::printf("work-pool/worker-survives-bad-alloc-while-recording-an-exception (child)\n");
    auto r = ChildScenario::runChildScenario("work-pool/oom-in-exception-handler", {}, 30000);
    CHECK_MSG(r.started && r.ok(),
              "CORE-18 child: " + r.describe() + "; stdout: " + r.out + "; stderr: " + r.err);
}

#endif  // !_WIN32

}  // namespace

void runCoreServicesTests() {
    testRunErrKeepsMessage();
    testAsyncFailureUncounted();
    testAsyncFailureCounted();
#if !defined(_WIN32)
    testPoolPartialStart();
    testReactorInitFdLeak();
    testPoolOomInHandler();
#endif
}

void registerCoreServicesScenarios() {
    ChildScenario::add("core/async-failure-counted-park", scenarioCore08Counted);
#if !defined(_WIN32)
#if ECO_TEST_HOOKS
    ChildScenario::add("work-pool/partial-start", scenarioCore01PartialStart);
#endif
#if defined(__linux__)
    ChildScenario::add("io-reactor/init-failure-fd-leak", scenarioCore14ReactorInitFdLeak);
#endif
    ChildScenario::add("work-pool/oom-in-exception-handler", scenarioCore18PoolOomInHandler);
#endif
}
