// SD-1 (plans/review-bug-list-fixes.md): process ids are 16 bits wide (Heap.hpp ID_BITS,
// the u16 casts in Scheduler::rawSpawn / procWith*), are never recycled
// (Scheduler::nextProcId_ only counts up), and key the scheduler's tables
// (latestProc_, selfMsgHandlers_). After 65,536 spawns a new process gets the
// id of an older one and overwrites its registry entry, so:
//   - sendToSelf (latestProcessById + rawSend, PlatformRuntime::sendToSelf)
//     delivers an effect manager's self-message to the wrong process, where
//     it is dropped (SD1-a);
//   - Process.kill (killBindingBody) resolves the target by id and runs the
//     NEWER process's kill handle instead of the target's (SD1-b).
// Independently of the wrap, a process that has finished keeps its registry
// entry, so its final Process value (and the result value its root Task
// carries) stays rooted until its id is reused (SD1-c).
//
// These are the "Process-id wrap" test gap. They drive the Scheduler exactly
// as PlatformRuntime does (rawSpawn(taskReceive cb) + registerSelfProcess for a
// manager's self-process; latestProcessById + rawSend for sendToSelf). Each
// case runs in its own spawned child, so the id counter starts fresh.

#include "SchedulerPidTest.hpp"
#include "../../runtime/src/allocator/RuntimeExports.h"
#include "../../runtime/src/platform/Scheduler.hpp"
#include "../../runtime/src/platform/TaskBinding.hpp"
#include "../allocator/TestHelpers.hpp"
#include "../TestSuite.hpp"
#include "../XfailGuard.hpp"

#include <cstdint>
#include <string>
#include <vector>

using Elm::HPointer;
using Elm::Process;
using Elm::Task;
using Elm::u32;
using Elm::Platform::Scheduler;
using Elm::Platform::detail::decodeBits;
using Elm::Platform::detail::encodeBits;

namespace {

void initRuntime() {
    initAllocator();
    (void)Scheduler::instance();
}

u32 procIdOf(HPointer proc) {
    void* p = Elm::Allocator::instance().resolve(proc);
    return static_cast<u32>(static_cast<Process*>(p)->id);
}

// Spawns `n` processes that finish at once (the onEffects / onSelfMsg state
// processes PlatformRuntime spawns on every update), draining as it goes.
void spawnFinishedProcesses(u32 n) {
    auto& s = Scheduler::instance();
    for (u32 i = 0; i < n; ++i) {
        (void)s.rawSpawn(s.taskSucceed(Elm::alloc::unit()));
        if ((i & 4095) == 4095) s.drain();
    }
    s.drain();
}

// One past the number of distinct 16-bit ids: the spawn this many after a
// process P gets P's id while the ids are 16 bits wide.
constexpr u32 kWrap = 65536;

// ---- SD1-a: self-message misdelivered after the wrap ------------------------

int g_selfMsgs = 0;

void* sd1RecvCallback(void* /*args*/[]) {
    // Only reached if the self handler were not registered.
    return reinterpret_cast<void*>(
        encodeBits(Scheduler::instance().taskSucceed(Elm::alloc::unit())));
}

void test_sd1_self_message_after_pid_wrap() {
    initRuntime();
    auto& s = Scheduler::instance();

    // The manager's self-process, as PlatformRuntime::setupEffects builds it.
    HPointer cb = Elm::alloc::allocClosure(sd1RecvCallback, 1);
    Elm::StackRootGuard g1(&cb);
    HPointer selfProc = s.rawSpawn(s.taskReceive(cb));
    u32 selfId = procIdOf(selfProc);
    s.registerSelfProcess(selfId, [](HPointer) { g_selfMsgs++; });
    s.drain();                                     // blocks in Task_Receive

    // Control: before the wrap, sendToSelf reaches the self-process.
    {
        HPointer latest = s.latestProcessById(selfId);
        TEST_ASSERT(!Elm::alloc::isNil(latest));
        s.rawSend(latest, Elm::alloc::unit());
        s.drain();
        TEST_ASSERT(g_selfMsgs == 1);
    }

    // ~22,000 updates of a three-manager program: 65,536 short-lived spawns.
    spawnFinishedProcesses(kWrap);

    // sendToSelf after the wrap: the id must still name the self-process.
    HPointer latest = s.latestProcessById(selfId);
    TEST_ASSERT(!Elm::alloc::isNil(latest));
    {
        void* p = Elm::Allocator::instance().resolve(latest);
        Process* proc = static_cast<Process*>(p);
        Task* root = static_cast<Task*>(Elm::Allocator::instance().resolve(proc->root));
        // SD-1: fails today: the registry entry for selfId is a finished
        // filler process (root Task_Succeed), not the self-process.
        TEST_ASSERT(root != nullptr && root->ctor == Elm::alloc::Task_Receive);
    }
    s.rawSend(latest, Elm::alloc::unit());
    s.drain();
    // SD-1: fails today (g_selfMsgs stays 1): the message went to the filler's
    // mailbox and was dropped.
    TEST_ASSERT(g_selfMsgs == 2);
}

// ---- SD1-b: Process.kill runs another process's kill handle -----------------

int g_killB = 0;
int g_killC = 0;

void* sd1KillB(void* /*args*/[]) {
    g_killB++;
    return reinterpret_cast<void*>(encodeBits(Elm::alloc::unit()));
}
void* sd1KillC(void* /*args*/[]) {
    g_killC++;
    return reinterpret_cast<void*>(encodeBits(Elm::alloc::unit()));
}
// Binding callbacks: park forever (never call resume), return the kill handle.
void* sd1BindB(void* /*args*/[]) {
    return reinterpret_cast<void*>(encodeBits(Elm::alloc::allocClosure(sd1KillB, 1)));
}
void* sd1BindC(void* /*args*/[]) {
    return reinterpret_cast<void*>(encodeBits(Elm::alloc::allocClosure(sd1KillC, 1)));
}

HPointer parkedBinding(Elm::EvalFunction bind) {
    HPointer cb = Elm::alloc::allocClosure(bind, 1);
    Elm::StackRootGuard g(&cb);
    HPointer nil = Elm::alloc::listNil();
    return Elm::alloc::allocTask(Elm::alloc::Task_Binding, nil, cb, nil, nil);
}

void test_sd1_kill_after_pid_wrap() {
    initRuntime();
    auto& s = Scheduler::instance();

    // B: a Process.spawn'd task parked in a binding with a kill handle. The
    // HPointer Elm holds is the snapshot rawSpawn returned.
    HPointer procB = s.rawSpawn(parkedBinding(sd1BindB));
    Elm::StackRootGuard gB(&procB);
    s.drain();

    spawnFinishedProcesses(kWrap - 1);

    // C: the 65,536th spawn after B, also parked with a kill handle.
    HPointer procC = s.rawSpawn(parkedBinding(sd1BindC));
    Elm::StackRootGuard gC(&procC);
    s.drain();

    // Process.kill B.
    HPointer killTask = s.killTask(procB);
    (void)s.rawSpawn(killTask);
    s.drain();

    // SD-1: fails today with g_killB == 0, g_killC == 1: killBindingBody
    // resolved B's id through latestProc_ and found C.
    TEST_ASSERT(g_killC == 0);
    TEST_ASSERT(g_killB == 1);
}

// ---- SD1-c: a finished process stays rooted ---------------------------------
//
// latestProc_ entries are only ever overwritten (registerLatestProcess), never
// erased, so the external root scanner keeps every finished process's last
// Process value, and the result its root Task_Succeed carries, alive until the
// 16-bit id comes round again (up to 65,535 dead processes). A fix that keeps
// PlatformRuntime's "drain, then read the finished process by id" pattern must
// hand that result over another way (or erase after the read); this case
// checks a plain spawned process that nobody reads back.
void test_sd1_finished_process_not_rooted() {
    initRuntime();
    auto& s = Scheduler::instance();
    HPointer big = Elm::alloc::allocFloat(42.0);   // stands for a large result
    Elm::StackRootGuard g(&big);
    HPointer proc = s.rawSpawn(s.taskSucceed(big));
    u32 id = procIdOf(proc);
    s.drain();                                     // runs to completion
    // SD-1: fails today: the finished process is still registered (rooted).
    TEST_ASSERT(Elm::alloc::isNil(s.latestProcessById(id)));
}

// ---- RB-448: two self-messages sent before one drain ----------------------
//
// cpp-review-bugs.md "Scheduler rawSend uses the caller's possibly stale snapshot": each rawSend
// enqueues a new version of the receiving process (its mailbox grown by one), and drain steps every
// queued version with no check that it is still the latest. Two sends before a drain queue
// P1 = [m1] and P2 = [m1, m2], so the self handler sees m1, m1, m2: m1 is delivered twice.
// HttpExports.cpp works around it by draining after every progress tick. Expected-fail guard
// (test/XfailGuard.hpp).

std::vector<int64_t> g_rb448Got;

void test_rb448_two_sends_one_drain() {
    initRuntime();
    auto& s = Scheduler::instance();
    HPointer cb = Elm::alloc::allocClosure(sd1RecvCallback, 1);
    Elm::StackRootGuard g1(&cb);
    u32 id = procIdOf(s.rawSpawn(s.taskReceive(cb)));
    s.registerSelfProcess(id, [](HPointer m) {
        g_rb448Got.push_back(static_cast<Elm::ElmInt*>(Elm::Allocator::instance().resolve(m))->value);
    });
    s.drain();                                     // blocks in Task_Receive

    HPointer m1 = Elm::alloc::allocInt(1);
    Elm::StackRootGuard r1(&m1);
    s.rawSend(s.latestProcessById(id), m1);
    HPointer m2 = Elm::alloc::allocInt(2);
    Elm::StackRootGuard r2(&m2);
    s.rawSend(s.latestProcessById(id), m2);
    s.drain();

    std::string got;
    for (int64_t v : g_rb448Got) got += (got.empty() ? "" : ",") + std::to_string(v);
    const bool correct = got == "1,2";
    XfailGuard::report("RB-448", !correct, "the self handler received [" + got + "] (correct: [1,2])");
}

}  // namespace

void registerSchedulerPidTests(IsolatedTestRunner::IsolatedTestCaseSuite& suite) {
    suite.add(Testing::TestCase("platform-services/SD-1 self-message after process-id wrap", test_sd1_self_message_after_pid_wrap));
    suite.add(Testing::TestCase("platform-services/SD-1 kill after process-id wrap", test_sd1_kill_after_pid_wrap));
    suite.add(Testing::TestCase("platform-services/SD-1 finished process not rooted", test_sd1_finished_process_not_rooted));
    suite.add(Testing::TestCase("platform-services/[xfail RB-448] two self-messages sent before one drain are each delivered once", test_rb448_two_sends_one_drain));
}
