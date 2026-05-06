//===- TimeEffectManager.cpp - Time effect manager implementation ----------===//
//
// Manages Time.every subscriptions by chaining one-shot timers via
// Scheduler::pendingResumes_ + TimerService. All HPointer / GC interaction
// runs on the main scheduler thread; the TimerService worker thread only
// ever sees (deadline, uint64_t token) pairs.
// See plans/time-every-via-scheduler-timerservice.md.
//
//===----------------------------------------------------------------------===//

#include "../KernelExports.h"
#include "../ExportHelpers.hpp"
#include "allocator/Heap.hpp"
#include "allocator/HeapHelpers.hpp"
#include "allocator/Allocator.hpp"
#include "allocator/RootSet.hpp"
#include "allocator/RuntimeExports.h"
#include "platform/Scheduler.hpp"
#include "platform/PlatformRuntime.hpp"
#include "platform/TimerService.hpp"
#include <atomic>
#include <chrono>
#include <cmath>
#include <cstring>
#include <mutex>
#include <unordered_map>
#include <vector>

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

// Per-interval state. Lives only on the main scheduler thread.
//
// Invariant: ALL accesses to g_intervals (mutation, lookup, scanning) take
// g_timerMutex. We must NOT hold g_timerMutex across any Allocator call —
// the GC scanner re-enters this mutex during evacuation, and any allocation
// can trigger GC. Copy primitives out, drop the lock, then allocate.
struct IntervalState {
    double   intervalMs;
    uint64_t generation;  // bumped on (re)subscription; stale ticks self-cancel
    uint64_t taggerEnc;   // encoded HPointer to (Posix -> msg) closure
    uint64_t routerEnc;   // encoded HPointer to Router
};

static std::mutex g_timerMutex;
static std::unordered_map<double, IntervalState> g_intervals;
static std::atomic<uint64_t> g_nextGeneration{1};

// Register, exactly once, an external root scanner that walks every live
// IntervalState and evacuates its taggerEnc / routerEnc fields. The scanner
// runs on the main thread during GC (which is triggered by allocations).
//
// Invariant: no Allocator calls while holding g_timerMutex. If a thread
// held the mutex across an allocation, GC's scanner would deadlock on the
// same (non-recursive) mutex on the same thread.
static void timerRegisterScannerOnce() {
    static std::once_flag flag;
    std::call_once(flag, []() {
        Elm::Allocator::instance().getRootSet().addExternalRootScanner(
            [](Elm::RootSet::EvacuateFn evac) {
                std::lock_guard<std::mutex> lock(g_timerMutex);
                for (auto& [interval, state] : g_intervals) {
                    (void)interval;
                    if (state.taggerEnc) evac(state.taggerEnc);
                    if (state.routerEnc) evac(state.routerEnc);
                }
            });
    });
}

// Forward declaration: defined below.
static void* timerTickEvaluator(void* args[]);

// Schedule a single Time.every tick for (intervalMs, generation).
// Mirrors sleepBindingEvaluator (ProcessExports.cpp): registerPendingResume
// → incrementPendingAsync → TimerService::schedule.
static void scheduleTimerTick(double intervalMs, uint64_t generation) {
    // Box metadata as Elm values so they're GC-visible and travel through
    // the closure's captures.
    HPointer intervalHP = allocFloat(intervalMs);
    HPointer genHP      = allocInt(static_cast<i64>(generation));

    HPointer tickCl = listNil();
    {
        Elm::StackRootGuard guard({ &intervalHP, &genHP, &tickCl });
        tickCl = allocClosure(timerTickEvaluator, /*max_values=*/3);
        if (void* clPtr = Allocator::instance().resolve(tickCl)) {
            closureCapture(clPtr, boxed(intervalHP), /*is_boxed=*/true);
            closureCapture(clPtr, boxed(genHP),      /*is_boxed=*/true);
        }
    }

    auto& sched = Scheduler::instance();
    uint64_t token = sched.registerPendingResume(tickCl);
    sched.incrementPendingAsync();
    TimerService::instance().schedule(intervalMs, token);
}

// Per-tick evaluator. Runs entirely on the main scheduler thread, fired by
// Scheduler::processReadyAsync via callClosure1(tickCl, taskSucceed(unit)).
//
//   args[0] = intervalHP   (boxed ElmFloat capture)
//   args[1] = genHP        (boxed ElmInt capture)
//   args[2] = Task succeed unit  (applied by processReadyAsync; ignored here)
static void* timerTickEvaluator(void* args[]) {
    HPointer intervalHP = decodeHP(reinterpret_cast<uint64_t>(args[0]));
    HPointer genHP      = decodeHP(reinterpret_cast<uint64_t>(args[1]));
    (void)args[2];

    auto& allocator = Allocator::instance();
    void* intervalPtr = allocator.resolve(intervalHP);
    void* genPtr      = allocator.resolve(genHP);
    if (!intervalPtr || !genPtr) {
        return reinterpret_cast<void*>(
            encodeHP(Scheduler::instance().taskSucceed(unit())));
    }
    double   intervalMs = static_cast<ElmFloat*>(intervalPtr)->value;
    uint64_t generation = static_cast<uint64_t>(
                              static_cast<ElmInt*>(genPtr)->value);
    if (intervalMs == 0.0) intervalMs = 0.0;  // fold -0.0 to +0.0 (Q6)

    // Snapshot encodings under the mutex; drop it before any allocation.
    uint64_t taggerEnc = 0, routerEnc = 0;
    bool active = false;
    {
        std::lock_guard<std::mutex> lock(g_timerMutex);
        auto it = g_intervals.find(intervalMs);
        if (it != g_intervals.end() && it->second.generation == generation) {
            taggerEnc = it->second.taggerEnc;
            routerEnc = it->second.routerEnc;
            active = true;
        }
    }

    HPointer succeedTask = Scheduler::instance().taskSucceed(unit());
    if (!active) {
        // Interval was unsubscribed (or re-created with a new generation).
        // processReadyAsync decrements pendingAsync_ for us; just return.
        return reinterpret_cast<void*>(encodeHP(succeedTask));
    }

    // Per Q2: decode immediately, root before any allocation, and re-encode
    // from the rooted HPointers at every use site. Do NOT reuse taggerEnc /
    // routerEnc after allocations — the encodings would be stale if GC ran.
    HPointer taggerHP = decodeHP(taggerEnc);
    HPointer routerHP = decodeHP(routerEnc);
    HPointer posixHP  = listNil();
    HPointer msgHP    = listNil();

    {
        Elm::StackRootGuard guard(
            { &taggerHP, &routerHP, &posixHP, &msgHP, &succeedTask });

        // Q1 — build the Posix Custom directly. Posix is
        // `type Posix = Posix Int` (CtorTag.elm: ctor index 0, single
        // unboxed Int field). Passing a raw Tag_Int would alias the
        // tagger/posixToMillis pattern match's offset-16 read past the
        // end of the ElmInt — same heap-layout-punning bug we fixed in
        // Time.now.
        std::vector<Unboxable> vals(1);
        vals[0].i = static_cast<i64>(
            std::chrono::duration_cast<std::chrono::milliseconds>(
                std::chrono::system_clock::now().time_since_epoch()).count());
        posixHP = custom(/*ctor=*/0, vals, /*kind_bitmap=*/0b01);

        uint64_t posixArg = encodeHP(posixHP);
        uint64_t msgEnc = eco_apply_closure(
            HPtr::fromBits(encodeHP(taggerHP)), &posixArg, 1).toBits();
        msgHP = decodeHP(msgEnc);

        PlatformRuntime::instance().sendToApp(routerHP, msgHP);
    }

    // Chain the next tick. scheduleTimerTick allocates; the previous
    // guard has been released, but we no longer need taggerHP/routerHP
    // alive past sendToApp.
    scheduleTimerTick(intervalMs, generation);

    return reinterpret_cast<void*>(encodeHP(succeedTask));
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

    // Q6: fold -0.0 to +0.0 so the double map key is stable across
    // subscription/lookup paths. Skip NaN intervals — nonsensical and would
    // never match in the lookup map anyway.
    auto normalize = [](double d) -> double {
        return d == 0.0 ? 0.0 : d;
    };

    std::unordered_map<double, uint64_t> normalizedRequested;
    for (auto& [interval, taggerEnc] : requestedIntervals) {
        if (std::isnan(interval)) continue;
        normalizedRequested[normalize(interval)] = taggerEnc;
    }

    timerRegisterScannerOnce();

    struct PendingStart {
        double   intervalMs;
        uint64_t generation;
    };
    std::vector<PendingStart> toStart;

    // Update g_intervals under the mutex; do NOT allocate while holding it.
    {
        std::lock_guard<std::mutex> lock(g_timerMutex);

        // Erase intervals that are no longer requested. In-flight ticks
        // for those intervals will see the missing entry and self-cancel
        // via the generation check.
        for (auto it = g_intervals.begin(); it != g_intervals.end(); ) {
            if (normalizedRequested.find(it->first) == normalizedRequested.end()) {
                it = g_intervals.erase(it);
            } else {
                ++it;
            }
        }

        // Insert new intervals or update existing ones in place.
        for (auto& [intervalMs, taggerEnc] : normalizedRequested) {
            auto it = g_intervals.find(intervalMs);
            if (it == g_intervals.end()) {
                uint64_t gen = g_nextGeneration.fetch_add(1);
                g_intervals.emplace(intervalMs, IntervalState{
                    intervalMs, gen, taggerEnc, routerEnc
                });
                toStart.push_back({ intervalMs, gen });
            } else {
                // Q7: in-place mutation is safe under the Q2 rooting
                // discipline. Old encodings lose their root the moment we
                // overwrite, but any in-flight tick that already
                // snapshotted them has rooted the decoded HPointers on
                // its stack, so the old closures stay alive until that
                // tick returns.
                it->second.taggerEnc = taggerEnc;
                it->second.routerEnc = routerEnc;
            }
        }
    }

    // Allocations only AFTER releasing g_timerMutex.
    for (const auto& ps : toStart) {
        scheduleTimerTick(ps.intervalMs, ps.generation);
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

    // Root the mapper across the first eco_apply_closure (origTagger): the
    // tagger body may GC and move the mapper, leaving `mapperEnc` stale.
    HPointer mapperHP = decodeHP(mapperEnc);
    Elm::StackRootGuard mapperRoot(&mapperHP);

    // Call origTagger(time)
    uint64_t msgEnc = eco_apply_closure(HPtr::fromBits(taggerEnc), &timeEnc, 1).toBits();

    // Call mapper(msg). Root the freshly-produced msg over the mapper call.
    HPointer msgHP = decodeHP(msgEnc);
    Elm::StackRootGuard msgRoot(&msgHP);
    HPtr mapperCl = HPtr::fromBits(encodeHP(mapperHP));
    uint64_t msgArg = encodeHP(msgHP);
    uint64_t resultEnc = eco_apply_closure(mapperCl, &msgArg, 1).toBits();

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
    info.init = encodeHP(initCl);
    info.onEffects = encodeHP(onEffectsCl);
    info.onSelfMsg = encodeHP(onSelfMsgCl);
    info.cmdMap = encodeHP(listNil());  // No commands
    info.subMap = encodeHP(subMapCl);

    PlatformRuntime::instance().registerManager("Time", info);
}

} // extern "C"
