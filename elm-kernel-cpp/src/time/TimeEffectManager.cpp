//===- TimeEffectManager.cpp - Time effect manager implementation ----------===//
//
// Manages Time.every subscriptions by maintaining timer threads that periodically
// send time updates to the Elm application.
//
//===----------------------------------------------------------------------===//

#include "../KernelExports.h"
#include "../ExportHelpers.hpp"
#include "allocator/Heap.hpp"
#include "allocator/HeapHelpers.hpp"
#include "allocator/Allocator.hpp"
#include "allocator/RuntimeExports.h"
#include "platform/Scheduler.hpp"
#include "platform/PlatformRuntime.hpp"
#include <chrono>
#include <thread>
#include <mutex>
#include <unordered_map>
#include <atomic>
#include <cstring>

using namespace Elm;
using namespace Elm::alloc;
using namespace Elm::Platform;

namespace {

// Ctor for Time.Every subscription (must match TimeExports.cpp)
static constexpr u16 CTOR_TIME_EVERY = 0;

// Encode/decode helpers
static inline uint64_t encodeHP(HPointer h) {
    union { HPointer hp; uint64_t val; } u;
    u.hp = h;
    return u.val;
}

static inline HPointer decodeHP(uint64_t val) {
    union { HPointer hp; uint64_t val; } u;
    u.val = val;
    return u.hp;
}

// Timer thread management
struct TimerState {
    std::atomic<bool> running{true};
    double intervalMs;
    uint64_t taggerEnc;  // Encoded closure
    uint64_t routerEnc;  // Encoded router for sendToApp
};

// Global timer state (keyed by interval for deduplication)
static std::mutex g_timerMutex;
static std::unordered_map<double, std::unique_ptr<TimerState>> g_activeTimers;
static std::unordered_map<double, std::thread> g_timerThreads;

// Timer thread function
void timerWorker(double intervalMs) {
    TimerState* state = nullptr;
    {
        std::lock_guard<std::mutex> lock(g_timerMutex);
        auto it = g_activeTimers.find(intervalMs);
        if (it == g_activeTimers.end()) {
            Scheduler::instance().decrementPendingAsync();
            return;
        }
        state = it->second.get();
    }

    // Init GC for this thread so we can allocate heap objects
    Allocator::instance().initThread();

    auto interval = std::chrono::milliseconds(static_cast<int64_t>(intervalMs));

    while (state->running.load()) {
        std::this_thread::sleep_for(interval);

        if (!state->running.load()) break;

        // Get current time
        auto now = std::chrono::system_clock::now();
        auto ms = std::chrono::duration_cast<std::chrono::milliseconds>(
            now.time_since_epoch()
        ).count();

        // Create Posix value (Int)
        HPointer posix = allocInt(ms);

        // Call tagger(posix) to get the message
        uint64_t posixEnc = encodeHP(posix);
        uint64_t msgEnc = eco_apply_closure(state->taggerEnc, &posixEnc, 1);

        // Send to app via router
        HPointer router = decodeHP(state->routerEnc);
        HPointer msg = decodeHP(msgEnc);
        PlatformRuntime::instance().sendToApp(router, msg);
    }

    Allocator::instance().cleanupThread();
    Scheduler::instance().decrementPendingAsync();
}

// Stop all timers for given intervals
void stopTimers(const std::vector<double>& intervals) {
    std::lock_guard<std::mutex> lock(g_timerMutex);
    for (double interval : intervals) {
        auto it = g_activeTimers.find(interval);
        if (it != g_activeTimers.end()) {
            it->second->running.store(false);
        }
        auto threadIt = g_timerThreads.find(interval);
        if (threadIt != g_timerThreads.end()) {
            if (threadIt->second.joinable()) {
                threadIt->second.detach();  // Don't block, just let it finish
            }
            g_timerThreads.erase(threadIt);
        }
        g_activeTimers.erase(interval);
    }
}

// Start a timer for given interval
void startTimer(double intervalMs, uint64_t taggerEnc, uint64_t routerEnc) {
    std::lock_guard<std::mutex> lock(g_timerMutex);

    // Check if already running with same interval
    auto it = g_activeTimers.find(intervalMs);
    if (it != g_activeTimers.end()) {
        // Update tagger if interval already exists
        it->second->taggerEnc = taggerEnc;
        it->second->routerEnc = routerEnc;
        return;
    }

    // Create new timer state
    auto state = std::make_unique<TimerState>();
    state->intervalMs = intervalMs;
    state->taggerEnc = taggerEnc;
    state->routerEnc = routerEnc;

    g_activeTimers[intervalMs] = std::move(state);

    // Track pending async work before spawning thread
    Scheduler::instance().incrementPendingAsync();

    // Start timer thread
    g_timerThreads[intervalMs] = std::thread(timerWorker, intervalMs);
}

// ============================================================================
// Effect Manager Closures
// ============================================================================

// init : Task Never State
// State is just Nil (we track state in C++ globals)
static void* timeInitEvaluator(void* args[]) {
    (void)args;
    // Return Task.succeed(Nil)
    HPointer nilState = listNil();
    HPointer task = Scheduler::instance().taskSucceed(nilState);
    return reinterpret_cast<void*>(encodeHP(task));
}

// onEffects : Router msg -> List (MyCmd msg) -> List (MySub msg) -> State -> Task Never State
// For Time: no commands, only subscriptions (Time.every)
static void* timeOnEffectsEvaluator(void* args[]) {
    // args[0] = router (captured)
    // args[1] = cmds (arg - ignored, Time has no cmds)
    // args[2] = subs
    // args[3] = state (arg - ignored, we use C++ state)

    uint64_t routerEnc = reinterpret_cast<uint64_t>(args[0]);

    // Wait for all 4 arguments to be applied
    // When partially applied, we return ourselves
    // This is called with 4 args: router, cmds, subs, state
    uint64_t subsEnc = reinterpret_cast<uint64_t>(args[2]);
    HPointer subs = decodeHP(subsEnc);

    // Collect all requested intervals from subscriptions
    std::unordered_map<double, uint64_t> requestedIntervals;  // interval -> tagger

    HPointer current = subs;
    while (!isNil(current)) {
        void* cellPtr = Allocator::instance().resolve(current);
        if (!cellPtr) break;

        Cons* cell = static_cast<Cons*>(cellPtr);
        HPointer subHP = cell->head.p;

        void* subPtr = Allocator::instance().resolve(subHP);
        if (subPtr) {
            Custom* sub = static_cast<Custom*>(subPtr);
            if (sub->ctor == CTOR_TIME_EVERY) {
                // values[0] = interval (unboxed Float)
                // values[1] = tagger (boxed Closure)
                double interval = sub->values[0].f;
                uint64_t taggerEnc = encodeHP(sub->values[1].p);
                requestedIntervals[interval] = taggerEnc;
            }
        }

        current = cell->tail;
    }

    // Find intervals to stop (in g_activeTimers but not in requestedIntervals)
    std::vector<double> toStop;
    {
        std::lock_guard<std::mutex> lock(g_timerMutex);
        for (auto& [interval, _] : g_activeTimers) {
            if (requestedIntervals.find(interval) == requestedIntervals.end()) {
                toStop.push_back(interval);
            }
        }
    }

    // Stop unused timers
    if (!toStop.empty()) {
        stopTimers(toStop);
    }

    // Start/update needed timers
    for (auto& [interval, taggerEnc] : requestedIntervals) {
        startTimer(interval, taggerEnc, routerEnc);
    }

    // Return Task.succeed(Nil) - state unchanged
    HPointer newState = listNil();
    HPointer task = Scheduler::instance().taskSucceed(newState);
    return reinterpret_cast<void*>(encodeHP(task));
}

// onSelfMsg : Router msg -> selfMsg -> State -> Task Never State
// Time doesn't use self messages (timer threads directly call sendToApp)
static void* timeOnSelfMsgEvaluator(void* args[]) {
    // args[0] = router (captured, ignored)
    // args[1] = selfMsg (arg, ignored)
    // args[2] = state (arg)

    // Just return Task.succeed(state)
    uint64_t stateEnc = reinterpret_cast<uint64_t>(args[2]);
    HPointer task = Scheduler::instance().taskSucceed(decodeHP(stateEnc));
    return reinterpret_cast<void*>(encodeHP(task));
}

// Helper: Composed tagger evaluator for subMap
// args[0] = mapper, args[1] = origTagger, args[2] = time
static void* composedTaggerEvaluator(void* args[]) {
    uint64_t mapperEnc = reinterpret_cast<uint64_t>(args[0]);
    uint64_t taggerEnc = reinterpret_cast<uint64_t>(args[1]);
    uint64_t timeEnc = reinterpret_cast<uint64_t>(args[2]);

    // Call origTagger(time)
    uint64_t msgEnc = eco_apply_closure(taggerEnc, &timeEnc, 1);

    // Call mapper(msg)
    uint64_t resultEnc = eco_apply_closure(mapperEnc, &msgEnc, 1);

    return reinterpret_cast<void*>(resultEnc);
}

// subMap : (a -> b) -> MySub a -> MySub b
// Maps over the tagger in Time.every subscription
static void* timeSubMapEvaluator(void* args[]) {
    // args[0] = mapper function
    // args[1] = original sub

    uint64_t mapperEnc = reinterpret_cast<uint64_t>(args[0]);
    uint64_t subEnc = reinterpret_cast<uint64_t>(args[1]);

    HPointer mapper = decodeHP(mapperEnc);
    HPointer origSub = decodeHP(subEnc);

    void* subPtr = Allocator::instance().resolve(origSub);
    if (!subPtr) {
        return reinterpret_cast<void*>(subEnc);  // Return unchanged
    }

    Custom* sub = static_cast<Custom*>(subPtr);
    if (sub->ctor != CTOR_TIME_EVERY) {
        return reinterpret_cast<void*>(subEnc);  // Not our sub type
    }

    // Get original interval and tagger
    double interval = sub->values[0].f;
    HPointer origTagger = sub->values[1].p;

    // Create composed tagger: mapper . origTagger
    // composedTagger = \time -> mapper (origTagger time)
    HPointer composedTagger = allocClosure(composedTaggerEvaluator, 3);
    void* clPtr = Allocator::instance().resolve(composedTagger);
    if (clPtr) {
        closureCapture(clPtr, boxed(mapper), true);
        closureCapture(clPtr, boxed(origTagger), true);
    }

    // Create new subscription with composed tagger
    std::vector<Unboxable> values(2);
    values[0].f = interval;
    values[1].p = composedTagger;

    HPointer newSub = custom(CTOR_TIME_EVERY, values, 0b01);  // interval unboxed
    return reinterpret_cast<void*>(encodeHP(newSub));
}

} // anonymous namespace

// ============================================================================
// Registration function (called from runtime initialization)
// ============================================================================

extern "C" {

void eco_register_time_effect_manager() {
    // Create init closure
    HPointer initCl = allocClosure(timeInitEvaluator, 0);

    // Create onEffects closure (4-arg curried)
    HPointer onEffectsCl = allocClosure(timeOnEffectsEvaluator, 4);

    // Create onSelfMsg closure (3-arg curried)
    HPointer onSelfMsgCl = allocClosure(timeOnSelfMsgEvaluator, 3);

    // Create subMap closure (2-arg)
    HPointer subMapCl = allocClosure(timeSubMapEvaluator, 2);

    // Register with PlatformRuntime
    PlatformRuntime::ManagerInfo info;
    info.init = initCl;
    info.onEffects = onEffectsCl;
    info.onSelfMsg = onSelfMsgCl;
    info.cmdMap = listNil();  // No commands
    info.subMap = subMapCl;

    PlatformRuntime::instance().registerManager("Time", info);
}

} // extern "C"
