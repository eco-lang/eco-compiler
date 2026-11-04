//===- TimeEffectManager.cpp - Time effect manager implementation ----------===//
//
// The native effect manager for Elm's `Time` module: it is what makes a `Time.every` subscription deliver
// messages.
//
// `Time` has subscriptions and no commands. Each time the application's subscriptions change, `onEffects` is
// given the current list, and the manager keeps one entry per distinct interval in `g_intervals`: the
// interval's taggers (the `Posix -> msg` functions of every subscription with that interval, as elm/time keeps
// a list of them per interval), the router to send through, and a generation. An interval that stays
// subscribed keeps its entry, with its taggers and router replaced; one that is dropped is erased.
//
// Each entry drives a chain of one-shot timers, one *tick* at a time. A tick is a closure parked with
// `Scheduler::parkResume`, whose resume token is handed to `TimerService::schedule`. The timer worker thread
// only ever handles the deadline and the token; when the timer fires, the scheduler runs the tick on the eco
// thread. The tick builds one `Posix` for the current time, applies each tagger to it, sends each message with
// `PlatformRuntime::sendToApp`, and schedules the next tick. A tick is scheduled `max(1, interval)`
// milliseconds ahead (`tickDelayMs`), as Node's `setInterval` clamps its delay.
//
// A tick knows only its interval and generation. The *generation* is a number given to an entry when it is
// created; a tick whose interval has no entry, or an entry with another generation, does nothing and ends its
// chain. When an interval is dropped, its recorded tick is also withdrawn with `withdrawParkedTimer`, which releases
// its hold on the scheduler.
//
// The taggers and routers are heap values held only as encoded words in this C++ map, so a root scanner
// registered with the allocator updates them when a collection moves them. That scanner takes `g_timerMutex`,
// which is the rule for the rest of the file: no allocation while holding that mutex.
//
//===----------------------------------------------------------------------===//

#include "../KernelExports.h"
#include "../ExportHelpers.hpp"
#include "TimeCtors.hpp"
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
namespace Export = Elm::Kernel::Export;
using Elm::Kernel::Time::CTOR_TIME_EVERY;

namespace {

/// The state of one subscribed interval, the value type of `g_intervals`.
///
/// Every access to an `IntervalState` in `g_intervals` is made holding `g_timerMutex`, and nothing that may
/// allocate is called while it is held: the root scanner takes the same mutex, and an allocation may run the
/// scanner on the same thread. Code copies the words it needs out, releases the mutex, then allocates.
struct IntervalState {
    double   intervalMs;
    uint64_t generation;  // The generation a tick must carry to act; fresh when the entry is created.
    // Encoded HPointers to the `Posix -> msg` closures of the interval's subscriptions, in subscription order,
    // which is the order each tick sends in.
    std::vector<uint64_t> taggerEncs;
    uint64_t routerEnc;   // Encoded HPointer to the manager's router.
    // Resume token of the most recently scheduled tick, or 0 if none has been recorded. It is withdrawn when the
    // interval is dropped.
    uint64_t tickToken = 0;
};

/// Guards `g_intervals`.
static std::mutex g_timerMutex;
/// The subscribed intervals, keyed by interval in milliseconds with -0.0 folded to +0.0.
static std::unordered_map<double, IntervalState> g_intervals;
/// The next generation to give a new entry; generations start at 1.
static std::atomic<uint64_t> g_nextGeneration{1};

/// The heap generation `g_intervals` and the root scanner belong to; 0 before the first `onEffects`. Eco thread
/// only.
static uint64_t g_heapGeneration = 0;

/// Makes the manager's state belong to the current heap generation. On the first call in a generation it
/// registers, with the current root set, a root scanner named "time-effects" that passes the nonzero `taggerEncs`
/// and `routerEnc` words of every entry in `g_intervals` to the collector, holding `g_timerMutex`. If state from an
/// earlier generation is left (a heap reset, which only tests make), it is dropped first: every entry is erased
/// and its recorded tick withdrawn, so its timer is cancelled and its parked closure, a value of the dead heap, is
/// never called. Later calls in the same generation do nothing.
static void timerSyncHeapGeneration() {
    const uint64_t gen = Elm::Allocator::instance().heapGeneration();
    if (g_heapGeneration == gen) return;
    std::vector<uint64_t> staleTicks;
    {
        std::lock_guard<std::mutex> lock(g_timerMutex);
        for (auto& [interval, state] : g_intervals) {
            (void)interval;
            if (state.tickToken != 0) staleTicks.push_back(state.tickToken);
        }
        g_intervals.clear();
    }
    // After the mutex is released, as in onEffects. The scheduler voided these holds at the reset, so the
    // withdrawal only cancels the timers.
    for (uint64_t t : staleTicks) withdrawParkedTimer(t);
    g_heapGeneration = gen;
    Elm::Allocator::instance().getRootSet().addExternalRootScanner(
        [](Elm::RootSet::EvacuateFn evac) {
            std::lock_guard<std::mutex> lock(g_timerMutex);
            for (auto& [interval, state] : g_intervals) {
                (void)interval;
                for (uint64_t& taggerEnc : state.taggerEncs) {
                    if (taggerEnc) evac(taggerEnc);
                }
                if (state.routerEnc) evac(state.routerEnc);
            }
        }, "time-effects");
}

static void* timerTickEvaluator(void* args[]);

/// Returns the delay, in milliseconds, between two ticks of a `Time.every intervalMs` subscription: Node's
/// `setInterval` rule (decision D30 of plans/kernel-lib-bug-fixes.md), under which a NaN, infinite or huge
/// interval (`TimerService::sanitizeDelayMs`) and one below 1 ms all tick every millisecond. Without the clamp
/// a zero or negative interval would tick as fast as the scheduler can run.
static double tickDelayMs(double intervalMs) {
    double d = TimerService::sanitizeDelayMs(intervalMs);
    return d < 1.0 ? 1.0 : d;
}

/// Schedules one tick for the entry of `intervalMs` with generation `generation`, to run `tickDelayMs(intervalMs)`
/// milliseconds from now. The tick closure captures the interval and generation as a boxed Float and Int; it is
/// parked with a hold of kind `Task`, and its resume token is passed to `TimerService::schedule`. The token is
/// recorded as the entry's `tickToken` if the entry still has that generation. Allocates.
static void scheduleTimerTick(double intervalMs, uint64_t generation) {
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
    uint64_t token = sched.parkResume(tickCl, Elm::Platform::HoldKind::Task, "Time.every");
    TimerService::instance().schedule(tickDelayMs(intervalMs), token);

    // Ticks run on this thread, the eco thread, so this tick cannot have run before its token is recorded.
    std::lock_guard<std::mutex> lock(g_timerMutex);
    auto it = g_intervals.find(intervalMs);
    if (it != g_intervals.end() && it->second.generation == generation) {
        it->second.tickToken = token;
    }
}

/// Runs one tick and returns `Task.succeed ()`. `args[0]` and `args[1]` are the boxed interval and generation
/// captured by `scheduleTimerTick`; `args[2]`, the value the scheduler resumes the closure with, is ignored.
///
/// If the captured interval and generation resolve and the interval's entry still has this generation, builds one
/// `Posix` for the current system time in milliseconds, applies each of the entry's taggers to it in order and
/// sends each result with `PlatformRuntime::sendToApp`, as elm/time's `onSelfMsg` sends one `Time.now` to every
/// tagger of the interval; then schedules the next tick. Otherwise it does nothing more, which ends the chain.
static void* timerTickEvaluator(void* args[]) {
    HPointer intervalHP = Export::decode(reinterpret_cast<uint64_t>(args[0]));
    HPointer genHP      = Export::decode(reinterpret_cast<uint64_t>(args[1]));
    (void)args[2];

    auto& allocator = Allocator::instance();
    void* intervalPtr = allocator.resolve(intervalHP);
    void* genPtr      = allocator.resolve(genHP);
    if (!intervalPtr || !genPtr) {
        return reinterpret_cast<void*>(
            Export::encode(Scheduler::instance().taskSucceed(unit())));
    }
    double   intervalMs = static_cast<ElmFloat*>(intervalPtr)->value;
    uint64_t generation = static_cast<uint64_t>(
                              static_cast<ElmInt*>(genPtr)->value);
    if (intervalMs == 0.0) intervalMs = 0.0;  // Folds -0.0 to +0.0, as the map's keys are.

    // The entry's words are only valid until the next allocation (the map's scanner updates the map, not a
    // copy), so they are decoded into rooted slots before anything allocates: slot 0 is the router, the rest
    // the taggers in order. One record roots them all, however many there are.
    Elm::alloc::RootedSlots rooted;
    {
        std::lock_guard<std::mutex> lock(g_timerMutex);
        auto it = g_intervals.find(intervalMs);
        if (it != g_intervals.end() && it->second.generation == generation) {
            rooted.push(Export::decode(it->second.routerEnc));
            for (uint64_t taggerEnc : it->second.taggerEncs) rooted.push(Export::decode(taggerEnc));
        }
    }
    const bool active = !rooted.empty();

    HPointer succeedTask = listNil();
    HPointer posixHP     = listNil();
    HPointer msgHP       = listNil();
    {
        Elm::StackRootGuard guard({ &succeedTask, &posixHP, &msgHP });
        succeedTask = Scheduler::instance().taskSucceed(unit());
        if (!active) {
            return reinterpret_cast<void*>(Export::encode(succeedTask));
        }

        // `Posix` is `type Posix = Posix Int`: a Custom with constructor 0 and one unboxed Int field. The tagger
        // reads that field, so it must be given the Custom, not a bare boxed Int.
        std::vector<Unboxable> vals(1);
        vals[0].i = static_cast<i64>(
            std::chrono::duration_cast<std::chrono::milliseconds>(
                std::chrono::system_clock::now().time_since_epoch()).count());
        posixHP = custom(/*ctor=*/0, vals, /*kind_bitmap=*/0b01);

        // Each slot is read afresh on each iteration, since the previous one may have collected.
        for (size_t i = 1; i < rooted.size(); ++i) {
            uint64_t posixArg = Export::encode(posixHP);
            uint64_t msgEnc = eco_apply_closure(
                HPtr::fromBits(Export::encode(rooted[i])), &posixArg, 1).toBits();
            msgHP = Export::decode(msgEnc);
            PlatformRuntime::instance().sendToApp(rooted[0], msgHP);
        }

        scheduleTimerTick(intervalMs, generation);
    }

    return reinterpret_cast<void*>(Export::encode(succeedTask));
}

// ============================================================================
// Effect Manager Closures
// ============================================================================

/// The manager's `init`: returns `Task.succeed []`. The manager's Elm state is always `[]`; its real state is
/// `g_intervals`.
static void* timeInitEvaluator(void* args[]) {
    (void)args;
    HPointer nilState = listNil();
    HPointer task = Scheduler::instance().taskSucceed(nilState);
    return reinterpret_cast<void*>(Export::encode(task));
}

/// The manager's `onEffects`, given the router, the commands (ignored), the subscriptions and the state
/// (ignored), in `args[0]` to `args[3]`. Returns `Task.succeed []`.
///
/// Makes `g_intervals` match the `Time.every` subscriptions in the list. Elements with another constructor are
/// skipped, as are NaN intervals; several subscriptions with the same interval share one entry, which keeps all
/// their taggers in list order, as elm/time keeps a list of taggers per interval. A dropped interval's entry is
/// erased and its recorded tick withdrawn. A new interval gets an entry with a fresh generation and its first
/// tick is scheduled. An interval already present keeps its generation and its tick chain, with its taggers and
/// router replaced by this call's. Also registers the root scanner on the first call of a heap generation, first
/// dropping the state of an earlier one (`timerSyncHeapGeneration`).
static void* timeOnEffectsEvaluator(void* args[]) {
    uint64_t routerEnc = reinterpret_cast<uint64_t>(args[0]);

    uint64_t subsEnc = reinterpret_cast<uint64_t>(args[2]);
    HPointer subs = Export::decode(subsEnc);

    // Interval, with -0.0 folded to +0.0, to its encoded taggers in list order. A NaN key would never be found
    // again, since NaN compares unequal to itself, so NaN intervals are skipped.
    std::unordered_map<double, std::vector<uint64_t>> normalizedRequested;

    // Nothing in this walk allocates on the heap, so the encoded taggers stay valid until they are stored.
    for (Elm::alloc::ListCursor l(subs); !l.done(); l.next()) {
        void* subPtr = alloc::resolveOrNull(l.current().p);
        if (subPtr) {
            Custom* sub = static_cast<Custom*>(subPtr);
            if (sub->ctor == CTOR_TIME_EVERY) {
                double interval = sub->values[0].f;
                if (std::isnan(interval)) continue;
                if (interval == 0.0) interval = 0.0;
                normalizedRequested[interval].push_back(Export::encode(sub->values[1].p));
            }
        }
    }

    timerSyncHeapGeneration();

    struct PendingStart {
        double   intervalMs;
        uint64_t generation;
    };
    std::vector<PendingStart> toStart;
    std::vector<uint64_t> toCancel;

    {
        std::lock_guard<std::mutex> lock(g_timerMutex);

        // A dropped interval's tick is withdrawn below, after the mutex is released. The generation check in
        // timerTickEvaluator still stops a tick whose token was not recorded.
        for (auto it = g_intervals.begin(); it != g_intervals.end(); ) {
            if (normalizedRequested.find(it->first) == normalizedRequested.end()) {
                if (it->second.tickToken != 0) toCancel.push_back(it->second.tickToken);
                it = g_intervals.erase(it);
            } else {
                ++it;
            }
        }

        for (auto& [intervalMs, taggerEncs] : normalizedRequested) {
            auto it = g_intervals.find(intervalMs);
            if (it == g_intervals.end()) {
                uint64_t gen = g_nextGeneration.fetch_add(1);
                g_intervals.emplace(intervalMs, IntervalState{
                    intervalMs, gen, std::move(taggerEncs), routerEnc, /*tickToken=*/0
                });
                toStart.push_back({ intervalMs, gen });
            } else {
                // Overwriting drops this map's roots for the old taggers and router.
                it->second.taggerEncs = std::move(taggerEncs);
                it->second.routerEnc = routerEnc;
            }
        }
    }

    // Done after g_timerMutex is released, since withdrawParkedTimer may release a scheduler hold.
    for (uint64_t t : toCancel) {
        withdrawParkedTimer(t);
    }

    for (const auto& ps : toStart) {
        scheduleTimerTick(ps.intervalMs, ps.generation);
    }

    HPointer newState = listNil();
    HPointer task = Scheduler::instance().taskSucceed(newState);
    return reinterpret_cast<void*>(Export::encode(task));
}

/// The manager's `onSelfMsg`, given the router, a self-message and the state in `args[0]` to `args[2]`. Returns
/// `Task.succeed state`. The manager never sends itself messages; ticks call `sendToApp` themselves.
static void* timeOnSelfMsgEvaluator(void* args[]) {
    uint64_t stateEnc = reinterpret_cast<uint64_t>(args[2]);
    HPointer task = Scheduler::instance().taskSucceed(Export::decode(stateEnc));
    return reinterpret_cast<void*>(Export::encode(task));
}

/// The tagger `subMap` builds: given the mapper, the original tagger and a `Posix` in `args[0]` to `args[2]`,
/// returns `mapper (origTagger posix)`.
static void* composedTaggerEvaluator(void* args[]) {
    uint64_t mapperEnc = reinterpret_cast<uint64_t>(args[0]);
    uint64_t taggerEnc = reinterpret_cast<uint64_t>(args[1]);
    uint64_t timeEnc = reinterpret_cast<uint64_t>(args[2]);

    // The tagger may allocate and move the mapper, so the mapper is rooted across that call.
    HPointer mapperHP = Export::decode(mapperEnc);
    Elm::StackRootGuard mapperRoot(&mapperHP);

    uint64_t msgEnc = eco_apply_closure(HPtr::fromBits(taggerEnc), &timeEnc, 1).toBits();

    HPointer msgHP = Export::decode(msgEnc);
    Elm::StackRootGuard msgRoot(&msgHP);
    HPtr mapperCl = HPtr::fromBits(Export::encode(mapperHP));
    uint64_t msgArg = Export::encode(msgHP);
    uint64_t resultEnc = eco_apply_closure(mapperCl, &msgArg, 1).toBits();

    return reinterpret_cast<void*>(resultEnc);
}

/// The manager's `subMap`, given a mapper and a subscription in `args[0]` and `args[1]`. For a `Time.every`
/// subscription, returns a new one with the same interval whose tagger is `composedTaggerEvaluator` over the
/// mapper and the original tagger. Returns the subscription unchanged if it is not a heap object or has another
/// constructor.
///
/// The new subscription is built with kind bitmap `0b10`, which makes the interval slot a Float and the tagger
/// slot boxed.
static void* timeSubMapEvaluator(void* args[]) {
    auto& allocator = Allocator::instance();

    // Every allocation below may move these values, so all three are rooted; origTagger is filled in from
    // origSub.
    HPointer mapper = Export::decode(reinterpret_cast<uint64_t>(args[0]));
    HPointer origSub = Export::decode(reinterpret_cast<uint64_t>(args[1]));
    HPointer origTagger = listNil();
    Elm::StackRootGuard guards(&mapper, &origSub, &origTagger);

    void* subPtr = allocator.resolve(origSub);

    Custom* sub = static_cast<Custom*>(subPtr);
    if (sub->ctor != CTOR_TIME_EVERY) {
        return reinterpret_cast<void*>(Export::encode(origSub));
    }

    // `sub` is read before the first allocation; it may be stale after it.
    double interval = sub->values[0].f;
    origTagger = sub->values[1].p;

    HPointer composedTagger = allocClosure(composedTaggerEvaluator, 3);
    Elm::StackRootGuard ctRoot(&composedTagger);
    void* clPtr = allocator.resolve(composedTagger);
    closureCapture(clPtr, boxed(mapper), true);
    // Re-resolved in case the first capture allocated and moved the closure.
    clPtr = allocator.resolve(composedTagger);
    closureCapture(clPtr, boxed(origTagger), true);

    std::vector<Unboxable> values(2);
    values[0].f = interval;
    values[1].p = composedTagger;

    HPointer newSub = custom(CTOR_TIME_EVERY, values, 0b10);
    return reinterpret_cast<void*>(Export::encode(newSub));
}

} // anonymous namespace

// ============================================================================
// Registration
// ============================================================================

extern "C" {

/// Registers this file's closures with `PlatformRuntime` as the effect manager "Time", replacing any manager
/// registered under that name: `init`, `onEffects`, `onSelfMsg` and `subMap` as above, and `[]` as `cmdMap`,
/// since Time has no commands.
void eco_register_time_effect_manager() {
    // Each closure stays rooted across the later allocations, any of which may collect.
    HPointer initCl = allocClosure(timeInitEvaluator, 0);
    Elm::StackRootGuard initRoot(&initCl);

    HPointer onEffectsCl = allocClosure(timeOnEffectsEvaluator, 4);
    Elm::StackRootGuard onEffectsRoot(&onEffectsCl);

    HPointer onSelfMsgCl = allocClosure(timeOnSelfMsgEvaluator, 3);
    Elm::StackRootGuard onSelfMsgRoot(&onSelfMsgCl);

    HPointer subMapCl = allocClosure(timeSubMapEvaluator, 2);
    Elm::StackRootGuard subMapRoot(&subMapCl);

    PlatformRuntime::ManagerInfo info;
    info.init = Export::encode(initCl);
    info.onEffects = Export::encode(onEffectsCl);
    info.onSelfMsg = Export::encode(onSelfMsgCl);
    info.cmdMap = Export::encode(listNil());
    info.subMap = Export::encode(subMapCl);

    PlatformRuntime::instance().registerManager("Time", info);
}

} // extern "C"
