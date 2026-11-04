// Unit tests of elm-kernel-cpp's time code (src/time/) in elm-kernel-time-test: the time effect
// manager's GC rooting. Run: build/elm-kernel-cpp/elm-kernel-time-test
//
// Both cases were GC-rooting defects (fixed: the tick roots its words before allocating, the registrar
// roots each closure) in elm-kernel-cpp/src/time/TimeEffectManager.cpp. Each test forces
// a minor collection at the one allocation the defect needs, and a one-shot external root scanner
// (registered after the "time-effects" scanner, so it runs after every legitimate root has been
// evacuated) overwrites the old copy of the object with 0xDD, as a later allocation into that space
// would (the GcSafetyReproTest.cpp trick). Code that still holds the old address then reads poison.
// Each scenario runs twice, in a fresh process: on the default (region) nursery and on the legacy
// semi-space nursery with a serial minor.
//
// - tick-tagger-across-minor (TIME-01): `timerTickEvaluator` copied the interval entry's encoded tagger
//   and router out of `g_intervals`, then called `taskSucceed(unit())`, which allocates, and only then
//   decoded and rooted them. When that allocation collected, the tagger it applied was the stale
//   pre-collection copy.
// - register-across-minor (TIME-NEW-1): `eco_register_time_effect_manager` kept the four closures it
//   allocates in unrooted locals, so a collection at the second `allocClosure` left `init` (already
//   allocated) stale in the registered ManagerInfo; `setupEffects` then called the stale closure.

#include "TimeKernelTest.hpp"

#include "KernelExports.h"
#include "allocator/Allocator.hpp"
#include "allocator/Heap.hpp"
#include "allocator/HeapHelpers.hpp"
#include "allocator/NurserySpace.hpp"
#include "allocator/RootSet.hpp"
#include "allocator/RuntimeExports.h"
#include "platform/PlatformRuntime.hpp"
#include "platform/Scheduler.hpp"
#include "platform/TestHooks.hpp"
#include "platform/TimerService.hpp"

#include <chrono>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <string>
#include <thread>

using namespace Elm;
using Elm::Platform::PlatformRuntime;
using Elm::Platform::Scheduler;
using Elm::Platform::TimerService;

namespace {

uint64_t enc(HPointer h) {
    union { HPointer hp; uint64_t v; } u;
    u.hp = h;
    return u.v;
}
HPointer dec(uint64_t v) {
    union { HPointer hp; uint64_t v; } u;
    u.v = v;
    return u.hp;
}

// Initializes the runtime for a scenario: the default heap, or with ECO_TIME_TEST_LEGACY=1 the legacy
// semi-space nursery with one minor thread (the serial core).
void initScenarioRuntime() {
    const char* legacy = std::getenv("ECO_TIME_TEST_LEGACY");
    if (legacy && std::strcmp(legacy, "1") == 0) {
        HeapConfig cfg;
        cfg.nursery_regions = 0;
        cfg.gc_minor_threads = 1;
        auto& a = Allocator::instance();
        a.initialize(cfg);
        a.initThread();
        (void)Scheduler::instance();
    } else {
        initTimeRuntime();
    }
}

// Exit statuses of the scenarios. kPrecondition means the test did not reach the buggy code (no
// collection at the intended point, the object did not move); the parent counts it as a test failure,
// never as "defect absent".
constexpr int kOk = 0;
constexpr int kDefect = 3;
constexpr int kPrecondition = 4;

// One-shot poison scanner state (static: the scanner outlives the registering frame's locals only in
// the sense that it stays registered until the process exits).
void* g_poisonAddr = nullptr;
size_t g_poisonBytes = 0;
bool g_poisonArmed = false;
bool g_poisonFired = false;

void registerPoisonScanner(const char* name) {
    Allocator::instance().getRootSet().addExternalRootScanner(
        [](RootSet::EvacuateFn) {
            if (!g_poisonArmed) return;
            g_poisonArmed = false;
            g_poisonFired = true;
            std::memset(g_poisonAddr, 0xDD, g_poisonBytes);
        },
        name);
}

// ---- TIME-01 ---------------------------------------------------------------

int g_taggerCalls = 0;
int g_appMsgs = 0;

// The `Posix -> msg` tagger: counts its calls and returns the Posix as the message.
void* countingTagger(void* args[]) {
    ++g_taggerCalls;
    return args[0];
}

// The program's sendToApp closure: counts the messages it is given.
void* recordingSendToApp(void* args[]) {
    (void)args;
    ++g_appMsgs;
    return reinterpret_cast<void*>(enc(alloc::unit()));
}

// Subscribes `Time.every 50 tagger`, takes the first tick's closure from the scheduler before it runs,
// makes a minor collection due, and runs the tick by hand. The first allocation in the tick is its
// `taskSucceed(unit())`, made after the tagger's word is copied out of `g_intervals` and before it is
// decoded and rooted.
int scenarioTickTaggerAcrossMinor() {
    initScenarioRuntime();
    auto& a = Allocator::instance();
    auto& sched = Scheduler::instance();
    auto& pr = PlatformRuntime::instance();
    NurserySpace* nursery = AllocatorTestAccess::getNursery(a);

    eco_register_time_effect_manager();
    HPointer sendToApp = alloc::allocClosure(recordingSendToApp, 1);
    (void)pr.setupEffects(sendToApp);
    sched.drain();

    // The tagger, and the subscription bag `Time.every 50 tagger` as the compiled program builds it.
    // The test keeps its own root on the tagger only to check, afterwards, that the collection moved it.
    HPointer tagger = alloc::allocClosure(countingTagger, 1);
    a.getRootSet().addRoot(&tagger);
    {
        HPointer home = alloc::allocStringFromUTF8("Time");
        StackRootGuard hg(&home);
        HPointer sub = dec(Elm_Kernel_Time_setInterval(50.0, HPtr::fromBits(enc(tagger))).toBits());
        HPointer leaf = dec(Elm_Kernel_Platform_leaf(HPtr::fromBits(enc(home)), HPtr::fromBits(enc(sub))).toBits());
        pr.enqueueEffects(alloc::listNil(), leaf);
    }
    sched.drain();

    // Wait for the first tick's timer and take its closure, so the tick runs here and not in an event
    // loop.
    uint64_t token = 0;
    bool popped = false;
    for (int i = 0; i < 400 && !popped; ++i) {
        popped = TimerService::instance().tryPopReadyToken(token);
        if (!popped) std::this_thread::sleep_for(std::chrono::milliseconds(5));
    }
    if (!popped) {
        std::fprintf(stderr, "precondition: no tick timer fired within 2 s\n");
        return kPrecondition;
    }
    HPointer tick = sched.takePendingResume(token);
    if (alloc::isNil(tick)) {
        std::fprintf(stderr, "precondition: no closure parked under the tick's token\n");
        return kPrecondition;
    }
    StackRootGuard tg(&tick);

    void* orig = a.resolve(tagger);
    if (!orig || !NurserySpaceTestAccess::contains(*nursery, orig)) {
        std::fprintf(stderr, "precondition: the tagger is not in the nursery before the tick\n");
        return kPrecondition;
    }
    g_poisonAddr = orig;
    g_poisonBytes = sizeof(Closure) + sizeof(Unboxable);
    g_poisonArmed = true;
    registerPoisonScanner("TIME-01.poison");

    const uint64_t seq0 = nursery->minorSeq();
    if (!nursery->requestMinor()) {
        std::fprintf(stderr, "precondition: requestMinor refused\n");
        return kPrecondition;
    }
    uint64_t arg = enc(alloc::unit());
    (void)eco_apply_closure(HPtr::fromBits(enc(tick)), &arg, 1);

    const uint64_t minors = nursery->minorSeq() - seq0;
    const bool moved = a.resolve(tagger) != orig;
    std::printf("TIME-01 tick: minors %llu, tagger moved %d, poisoned %d, tagger calls %d, app messages %d\n",
                static_cast<unsigned long long>(minors), moved ? 1 : 0, g_poisonFired ? 1 : 0,
                g_taggerCalls, g_appMsgs);
    std::fflush(stdout);
    a.getRootSet().removeRoot(&tagger);
    if (minors < 1 || !moved || !g_poisonFired) {
        std::fprintf(stderr, "precondition: the forced minor did not run inside the tick or did not move the tagger\n");
        return kPrecondition;
    }
    return (g_taggerCalls == 1 && g_appMsgs == 1) ? kOk : kDefect;
}

// ---- TIME-NEW-1 ------------------------------------------------------------

// Lowers the nursery's allocation end so that exactly one arity-0 closure fits: `initCl`, the first
// closure `eco_register_time_effect_manager` allocates, lands at the bump pointer, and the second
// (`onEffectsCl`) collects. The poison scanner overwrites `initCl`'s pre-collection copy. Then
// checks whether the registered `init` word still names that copy, and starts the manager, which calls
// `init`.
int scenarioRegisterAcrossMinor() {
    initScenarioRuntime();
    auto& a = Allocator::instance();
    auto& pr = PlatformRuntime::instance();
    NurserySpace* nursery = AllocatorTestAccess::getNursery(a);

    // An arity-0 kernel closure: the header fields and no value slots.
    const size_t initBytes = (sizeof(Closure) + 7) & ~size_t(7);
    NurserySpace::NurseryBump* bump = nursery->bumpState();
    char* orig = bump->ptr;
    if (bump->end < bump->ptr + 4 * initBytes) {
        std::fprintf(stderr, "precondition: nursery nearly full at start\n");
        return kPrecondition;
    }
    g_poisonAddr = orig;
    g_poisonBytes = initBytes;
    g_poisonArmed = true;
    registerPoisonScanner("TIME-NEW-1.poison");

    const uint64_t seq0 = nursery->minorSeq();
    bump->end = bump->ptr + initBytes;
    eco_register_time_effect_manager();
    const uint64_t minors = nursery->minorSeq() - seq0;

#if ECO_TEST_HOOKS
    const PlatformRuntime::ManagerInfo* info = pr.findManagerForTest("Time");
    if (!info) {
        std::fprintf(stderr, "precondition: no Time manager registered\n");
        return kPrecondition;
    }
    void* initAddr = AllocatorTestAccess::fromPointer(dec(info->init));
    const bool stale = initAddr == orig;
    std::printf("TIME-NEW-1 register: minors %llu, poisoned %d, init at bump start %d\n",
                static_cast<unsigned long long>(minors), g_poisonFired ? 1 : 0, stale ? 1 : 0);
    std::fflush(stdout);
    if (minors != 1 || !g_poisonFired) {
        std::fprintf(stderr, "precondition: registration did not run exactly one minor (ran %llu)\n",
                     static_cast<unsigned long long>(minors));
        return kPrecondition;
    }
    // Starting the manager calls `init`; with the stale word that is the poisoned copy.
    HPointer sendToApp = alloc::allocClosure(recordingSendToApp, 1);
    (void)pr.setupEffects(sendToApp);
    Scheduler::instance().drain();
    std::printf("TIME-NEW-1 setupEffects returned\n");
    return stale ? kDefect : kOk;
#else
    (void)pr;
    (void)minors;
    std::fprintf(stderr, "precondition: built without ECO_TEST_HOOKS (findManagerForTest)\n");
    return kPrecondition;
#endif
}

// ---- Parent-side checks ----------------------------------------------------

void runGuard(const char* id, const char* scenario, bool legacy) {
    std::printf("%s (%s nursery)\n", scenario, legacy ? "legacy" : "default");
    std::fflush(stdout);
    ChildScenario::ChildRun r = legacy ? ChildScenario::runChildScenario(scenario, {{"ECO_TIME_TEST_LEGACY", "1"}}, 30000)
                        : ChildScenario::runChildScenario(scenario, {}, 30000);
    const std::string how = r.describe() + "; stdout: " + r.out + "; stderr: " + r.err;
    CHECK_MSG(r.started, how);
    CHECK_MSG(!(r.exited && r.exitCode == kPrecondition), "did not reach the buggy code: " + how);
    CHECK_MSG(!(r.exited && r.exitCode != kOk && r.exitCode != kDefect && r.exitCode != kPrecondition),
              "unexpected exit: " + how);
    if (r.exited && r.exitCode == kPrecondition) return;
    const bool defect = r.crashed() || (r.exited && r.exitCode == kDefect);
    CHECK_MSG(!defect, std::string(id) + ": " + how);
}

void testTickTaggerAcrossMinor() {
    runGuard("TIME-01", "time/tick-tagger-across-minor", false);
    runGuard("TIME-01", "time/tick-tagger-across-minor", true);
}

void testRegisterAcrossMinor() {
    runGuard("TIME-NEW-1", "time/register-across-minor", false);
    runGuard("TIME-NEW-1", "time/register-across-minor", true);
}

}  // namespace

void runTimeKernelTests() {
    testTickTaggerAcrossMinor();
    testRegisterAcrossMinor();
}

void registerTimeKernelScenarios() {
    ChildScenario::add("time/tick-tagger-across-minor", scenarioTickTaggerAcrossMinor);
    ChildScenario::add("time/register-across-minor", scenarioRegisterAcrossMinor);
}
