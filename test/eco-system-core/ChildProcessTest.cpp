// ChildProcess unit tests of eco-system-core-test (system-kernel-cpp/src/eco-system/ChildProcess/).
//
// PROC-06: exception after parkResume leaks the job's hold. `childProcessRunBody`
//   (system-kernel-cpp/src/eco-system/ChildProcess/ChildProcess.cpp) inserts the job, parks the
//   resume and gives its hold to the job, then starts the collector, arms the runDuration timer and
//   submits the wait. An exception in that window (OOM in the timer closure, the wait thread) goes
//   to ECO_SYSTEM_ASYNC_GUARD, which fails the Task but, with `counted` false, leaves the hold to a
//   job nothing will ever complete: the job, its hold (and an armed timer's hold) stay forever and
//   keep the program alive. The test throws std::bad_alloc from the test-only run fault hook at both
//   sites (child scenario "child-process/run-fault-after-park") and checks the job table and the pending-hold
//   count are back where they were. Fixed: an exception before the wait is submitted abandons the
//   job (child killed and reaped, timer withdrawn) and the guard releases the run hold.
//   The effect manager's spawn (`handleSpawn`, ChildProcessManager.cpp) had the same shape: a throw
//   after the job and its hold were in the table left both, and a running, unreaped child. Child
//   scenario "child-process/spawn-fault" faults a `Spawn` command's `startJobWatch` (the BeforeWaitSubmit
//   site, with a runDuration timer armed), for an Integrated and an External connection, and checks
//   the job table, the pending-hold count and the open fds are back where they were and the child is
//   reaped. Fixed (X2 follow-up): the start is undone (abandonJob, hold released, streams discarded).

#include "EcoSystemCoreTest.hpp"

#include "eco-system/ChildProcess/ChildProcess.hpp"
#include "eco-system/ChildProcess/ChildProcessManager.hpp"
#include "eco-system/Core/Core.hpp"
#include "eco-system/Core/SignalService.hpp"

#include <atomic>
#include <cerrno>
#include <chrono>
#include <csignal>
#include <cstdio>
#include <cstring>
#include <new>
#include <string>
#include <thread>
#include <vector>

#include <dirent.h>
#include <signal.h>
#include <sys/resource.h>
#include <sys/wait.h>
#include <unistd.h>

using namespace Eco::System;

namespace {

bool contains(const std::string& hay, const std::string& needle) {
    return hay.find(needle) != std::string::npos;
}

// ---------------------------------------------------------------------------
// PROC-06
// ---------------------------------------------------------------------------

#if ECO_TEST_HOOKS
// The site the hook faults at, and how often it fired there. Eco thread only (the child's main).
RunFaultSite g_faultSite = RunFaultSite::BeforeJobWatch;
int g_faultHits = 0;
void throwAtSite(RunFaultSite site) {
    if (site != g_faultSite) return;
    ++g_faultHits;
    throw std::bad_alloc();
}

// The resume closure: records whether it got a failed Task.
int g_resumeCalls = 0;
bool g_resumeFailed = false;
void* recordRunResume(void* args[]) {
    HPointer task = dec(args[0]);
    auto* t = static_cast<Elm::Task*>(Allocator::instance().resolve(task));
    ++g_resumeCalls;
    g_resumeFailed = t->ctor == Elm::alloc::Task_Fail;
    return reinterpret_cast<void*>(enc(alloc::unit()));
}

// `( ( "sh", [ "-c", "sleep 1" ] ), ( ( NoShell, "" ), ( True, "" ) ), ( ( Inherit, [] ), ( 0, runMs ) ) )`,
// the `captured` of `childProcessRunBody`.
HPointer runCaptured(int64_t runMs) {
    HPointer a = alloc::listNil(), b = alloc::listNil(), c = alloc::listNil(), d = alloc::listNil();
    Elm::StackRootGuard g(&a, &b, &c, &d);
    // prog = ( "sh", [ "-c", "sleep 1" ] )
    a = alloc::allocStringFromUTF8("sleep 1");
    a = alloc::cons(alloc::boxed(a), alloc::listNil(), true);
    b = alloc::allocStringFromUTF8("-c");
    a = alloc::cons(alloc::boxed(b), a, true);
    b = alloc::allocStringFromUTF8("sh");
    a = alloc::tuple2(alloc::boxed(b), alloc::boxed(a), 0);              // a = prog
    // opts = ( ( NoShell, "" ), ( True, "" ) )
    b = alloc::tuple2(alloc::unboxedInt(kShellNone), alloc::boxed(alloc::emptyString()), 0x1);
    c = alloc::tuple2(alloc::boxed(alloc::elmTrue()), alloc::boxed(alloc::emptyString()), 0);
    b = alloc::tuple2(alloc::boxed(b), alloc::boxed(c), 0);              // b = opts
    // envLim = ( ( Inherit, [] ), ( maxBytes 0, runMs ) )
    c = alloc::tuple2(alloc::unboxedInt(kEnvInherit), alloc::boxed(alloc::listNil()), 0x1);
    d = alloc::tuple2(alloc::unboxedInt(0), alloc::unboxedInt(runMs), 0x5);
    c = alloc::tuple2(alloc::boxed(c), alloc::boxed(d), 0);              // c = envLim
    return alloc::tuple3(alloc::boxed(a), alloc::boxed(b), alloc::boxed(c), 0);
}

// Faults one run at `site`; prints one line "PROC-06 <name> fired=.. resumeFailed=.. jobs=a->b holds=a->b".
void faultOneRun(RunFaultSite site, const char* name) {
    auto& s = Scheduler::instance();
    g_faultSite = site;
    g_faultHits = 0;
    g_resumeCalls = 0;
    g_resumeFailed = false;
    const size_t jobsBefore = childJobs().size();
    const int holdsBefore = s.pendingAsync();
    {
        HPointer captured = alloc::listNil(), resume = alloc::listNil();
        Elm::StackRootGuard g(&captured, &resume);
        captured = runCaptured(/*runMs=*/500);   // runDuration > 0 also arms the timer
        resume = alloc::allocClosureK(&recordRunResume, 1, PK_Boxed);
        RunFaultHook prev = setRunFaultHookForTest(&throwAtSite);
        (void)childProcessRunBody(captured, resume);
        setRunFaultHookForTest(prev);
    }
    const size_t jobsAfter = childJobs().size();
    const int holdsAfter = s.pendingAsync();
    std::printf("PROC-06 %s fired=%d resumeFailed=%d jobs=%zu->%zu holds=%d->%d\n", name, g_faultHits,
                (g_resumeCalls == 1 && g_resumeFailed) ? 1 : 0, jobsBefore, jobsAfter, holdsBefore, holdsAfter);
}

// The onInit / onExit tagger of the spawn below; never called, since the spawn faults first.
void* unitTagger(void*[]) { return reinterpret_cast<void*>(enc(alloc::unit())); }

// The `Spawn` command `Spawn spec onInit onExit` for `sh -c "sleep 1"` with connection `conn` and a runDuration of
// `runMs`, as ChildProcess.elm builds it (ChildProcessManager.hpp).
HPointer spawnCommand(int64_t conn, int64_t runMs) {
    HPointer a = alloc::listNil(), b = alloc::listNil(), c = alloc::listNil(), d = alloc::listNil();
    Elm::StackRootGuard g(&a, &b, &c, &d);
    a = alloc::allocStringFromUTF8("sleep 1");
    a = alloc::cons(alloc::boxed(a), alloc::listNil(), true);
    b = alloc::allocStringFromUTF8("-c");
    a = alloc::cons(alloc::boxed(b), a, true);
    b = alloc::allocStringFromUTF8("sh");
    a = alloc::tuple2(alloc::boxed(b), alloc::boxed(a), 0);              // a = prog
    b = alloc::tuple2(alloc::unboxedInt(kShellNone), alloc::boxed(alloc::emptyString()), 0x1);
    c = alloc::tuple2(alloc::boxed(alloc::elmTrue()), alloc::boxed(alloc::emptyString()), 0);
    b = alloc::tuple2(alloc::boxed(b), alloc::boxed(c), 0);              // b = opts
    c = alloc::tuple2(alloc::unboxedInt(kEnvInherit), alloc::boxed(alloc::listNil()), 0x1);
    c = alloc::tuple3(alloc::boxed(c), alloc::unboxedInt(runMs), alloc::unboxedInt(conn),
                      ChildProcessManager::SPEC_TRIPLE_MASK);           // c = ( env, runMs, conn )
    a = alloc::tuple3(alloc::boxed(a), alloc::boxed(b), alloc::boxed(c), 0);   // a = spec
    b = alloc::allocClosure(&unitTagger, 1);
    c = alloc::allocClosure(&unitTagger, 1);
    std::vector<Unboxable> fields{alloc::boxed(a), alloc::boxed(b), alloc::boxed(c)};
    return alloc::custom(ChildProcessManager::CTOR_SPAWN, fields, 0);
}

// The number of open fds of this process.
int openFdCount() {
    DIR* d = ::opendir("/proc/self/fd");
    if (!d) return -1;
    int n = 0;
    while (::readdir(d)) ++n;
    ::closedir(d);
    return n - 3;   // ".", ".." and the directory's own fd
}

// Faults one `Spawn` with connection `conn` at BeforeWaitSubmit; prints one line
// "PROC-06 spawn-<name> fired=.. threw=.. unreaped=.. jobs=a->b holds=a->b fds=a->b".
void faultOneSpawn(int64_t conn, const char* name) {
    auto& s = Scheduler::instance();
    const auto* info = PlatformRuntime::instance().findManagerForTest("ChildProcess");
    CHECK_MSG(info != nullptr, "no ChildProcess manager");
    if (!info) return;
    g_faultSite = RunFaultSite::BeforeWaitSubmit;
    g_faultHits = 0;
    const size_t jobsBefore = childJobs().size();
    const int holdsBefore = s.pendingAsync();
    const int fdsBefore = openFdCount();
    bool threw = false;
    {
        HPointer cmds = alloc::listNil();
        Elm::StackRootGuard g(&cmds);
        cmds = spawnCommand(conn, /*runMs=*/500);   // runDuration > 0 also arms the timer
        cmds = alloc::cons(alloc::boxed(cmds), alloc::listNil(), true);
        RunFaultHook prev = setRunFaultHookForTest(&throwAtSite);
        try {
            (void)Scheduler::callClosure4(dec(info->onEffects), alloc::unit(), cmds, alloc::listNil(),
                                          alloc::unit());
        } catch (const std::bad_alloc&) {
            threw = true;
        }
        setRunFaultHookForTest(prev);
    }
    int st = 0;
    const bool unreaped = ::waitpid(-1, &st, WNOHANG) >= 0;   // a child still there (running or a zombie)
    // A discarded stream's channel closes its fd on its own thread, so give it a moment.
    for (int i = 0; i < 200 && openFdCount() != fdsBefore; i++) {
        std::this_thread::sleep_for(std::chrono::milliseconds(10));
    }
    std::printf("PROC-06 spawn-%s fired=%d threw=%d unreaped=%d jobs=%zu->%zu holds=%d->%d fds=%d->%d\n", name,
                g_faultHits, threw ? 1 : 0, unreaped ? 1 : 0, jobsBefore, childJobs().size(), holdsBefore,
                s.pendingAsync(), fdsBefore, openFdCount());
    if (unreaped) {   // leave no child for the next case (`sleep 1` ends by itself)
        while (::waitpid(-1, &st, 0) > 0) {}
    }
}

int scenarioSpawnFault() {
    initCoreRuntime();
    (void)Eco_System_registerManager_ChildProcess();
    faultOneSpawn(ChildProcessManager::CONN_INTEGRATED, "integrated");
    faultOneSpawn(ChildProcessManager::CONN_EXTERNAL, "external");
    std::fflush(stdout);
    return 0;
}

int scenarioRunFaultAfterPark() {
    initCoreRuntime();
    faultOneRun(RunFaultSite::BeforeJobWatch, "BeforeJobWatch");
    faultOneRun(RunFaultSite::BeforeWaitSubmit, "BeforeWaitSubmit");
    std::fflush(stdout);
    return 0;
}
#endif

void testRunFaultAfterPark() {
    std::printf("child-process/run-exception-after-park-leaks-no-job-or-hold\n");
#if !ECO_TEST_HOOKS
    CHECK_MSG(false, "PROC-06 needs ECO_TEST_HOOKS (the run fault hook)");
#else
    auto r = ChildScenario::runChildScenario("child-process/run-fault-after-park", {}, 30000);
    CHECK_MSG(r.ok(), r.describe() + "; stderr: " + r.err);
    if (!r.ok()) return;
    bool defect = false;
    for (const char* site : {"BeforeJobWatch", "BeforeWaitSubmit"}) {
        const std::string tag = std::string("PROC-06 ") + site + " ";
        const size_t at = r.out.find(tag);
        CHECK_MSG(at != std::string::npos, std::string("no line for ") + site + "; stdout: " + r.out);
        if (at == std::string::npos) return;
        const std::string line = r.out.substr(at, r.out.find('\n', at) - at);
        // Preconditions: the hook fired once, and the guard failed the Task through the resume.
        CHECK_MSG(contains(line, "fired=1 ") && contains(line, "resumeFailed=1 "), line);
        int j0 = 0, j1 = 0, h0 = 0, h1 = 0;
        const char* p = std::strstr(line.c_str(), "jobs=");
        CHECK_MSG(p && std::sscanf(p, "jobs=%d->%d holds=%d->%d", &j0, &j1, &h0, &h1) == 4, line);
        if (j1 != j0 || h1 != h0) defect = true;
    }
    std::string how = r.out;
    while (!how.empty() && how.back() == '\n') how.pop_back();
    for (auto& ch : how) if (ch == '\n') ch = ';';
    CHECK_MSG(!defect, "PROC-06 " + how + " (a job / hold left behind = leaked)");
#endif
}

void testSpawnFault() {
    std::printf("child-process/spawn-exception-after-the-hold-leaks-nothing\n");
#if !ECO_TEST_HOOKS
    CHECK_MSG(false, "PROC-06 needs ECO_TEST_HOOKS (the run fault hook)");
#else
    auto r = ChildScenario::runChildScenario("child-process/spawn-fault", {}, 30000);
    CHECK_MSG(r.ok(), r.describe() + "; stderr: " + r.err);
    if (!r.ok()) return;
    for (const char* name : {"integrated", "external"}) {
        const std::string tag = std::string("PROC-06 spawn-") + name + " ";
        const size_t at = r.out.find(tag);
        CHECK_MSG(at != std::string::npos, std::string("no line for ") + name + "; stdout: " + r.out);
        if (at == std::string::npos) return;
        const std::string line = r.out.substr(at, r.out.find('\n', at) - at);
        // Preconditions: the hook fired once and the exception came out of onEffects.
        CHECK_MSG(contains(line, "fired=1 ") && contains(line, "threw=1 "), line);
        int j0 = 0, j1 = 0, h0 = 0, h1 = 0, f0 = 0, f1 = 0;
        const char* p = std::strstr(line.c_str(), "jobs=");
        CHECK_MSG(p && std::sscanf(p, "jobs=%d->%d holds=%d->%d fds=%d->%d", &j0, &j1, &h0, &h1, &f0, &f1) == 6,
                  line);
        CHECK_MSG(contains(line, "unreaped=0 ") && j1 == j0 && h1 == h0 && f1 == f0,
                  line + " (a child, job, hold or fd left behind = leaked)");
    }
#endif
}

}  // namespace

void runChildProcessTests() {
    testRunFaultAfterPark();
    testSpawnFault();
}

void registerChildProcessScenarios() {
#if ECO_TEST_HOOKS
    ChildScenario::add("child-process/run-fault-after-park", scenarioRunFaultAfterPark);
    ChildScenario::add("child-process/spawn-fault", scenarioSpawnFault);
#endif
}
