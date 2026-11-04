//===- TimeEffectManager.cpp - Time effect manager implementation ----------===//
//
// The native effect manager for Elm's `Time` module: it is what makes a `Time.every` subscription deliver
// messages.
//
// `Time` has subscriptions and no commands. Each time the application's subscriptions change, `onEffects` is
// given the current list, and the manager keeps one entry per distinct interval in `g_intervals`: the
// interval's tagger (the `Posix -> msg` function), the router to send through, and a generation. An interval
// that stays subscribed keeps its entry, with its tagger and router replaced; one that is dropped is erased.
//
// Each entry drives a chain of one-shot timers, one *tick* at a time. A tick is a closure parked with
// `Scheduler::parkResume`, whose resume token is handed to `TimerService::schedule`. The timer worker thread
// only ever handles the deadline and the token; when the timer fires, the scheduler runs the tick on the eco
// thread. The tick builds a `Posix` for the current time, applies the tagger, sends the message with
// `PlatformRuntime::sendToApp`, and schedules the next tick.
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

/// Constructor tag of the `Time.every` subscription Custom: field 0 is the interval in milliseconds, field 1 the
/// tagger. The value must agree with the one `TimeExports.cpp` builds subscriptions with.
static constexpr u16 CTOR_TIME_EVERY = 0;

/// Returns the bits of `h` as a word, the form in which HPointers cross closure arguments and returns.
static inline uint64_t encodeHP(HPointer h) {
    union { HPointer hp; uint64_t val; } u;
    u.hp = h;
    return u.val;
}

/// Returns the HPointer whose bits are `val`; the inverse of `encodeHP`.
static inline HPointer decodeHP(uint64_t val) {
    union { HPointer hp; uint64_t val; } u;
    u.val = val;
    return u.hp;
}

/// The state of one subscribed interval, the value type of `g_intervals`.
///
/// Every access to an `IntervalState` in `g_intervals` is made holding `g_timerMutex`, and nothing that may
/// allocate is called while it is held: the root scanner takes the same mutex, and an allocation may run the
/// scanner on the same thread. Code copies the words it needs out, releases the mutex, then allocates.
struct IntervalState {
    double   intervalMs;
    uint64_t generation;  // The generation a tick must carry to act; fresh when the entry is created.
    uint64_t taggerEnc;   // Encoded HPointer to the `Posix -> msg` closure.
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

/// Registers, on the first call in the process, a root scanner named "time-effects" that passes the nonzero
/// `taggerEnc` and `routerEnc` words of every entry in `g_intervals` to the collector, holding `g_timerMutex`.
/// Later calls do nothing.
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
            }, "time-effects");
    });
}

static void* timerTickEvaluator(void* args[]);

/// Schedules one tick for the entry of `intervalMs` with generation `generation`, to run `intervalMs`
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
    TimerService::instance().schedule(intervalMs, token);

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
/// If the captured interval and generation resolve and the interval's entry still has this generation, applies
/// its tagger to a `Posix` for the current system time in milliseconds, sends the result with
/// `PlatformRuntime::sendToApp`, and schedules the next tick.
/// Otherwise it does nothing more, which ends the chain.
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
    if (intervalMs == 0.0) intervalMs = 0.0;  // Folds -0.0 to +0.0, as the map's keys are.

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
        return reinterpret_cast<void*>(encodeHP(succeedTask));
    }

    // The words copied out of the entry are decoded and rooted here, after the `taskSucceed` call above;
    // later uses re-encode the rooted HPointers rather than reuse taggerEnc and routerEnc.
    HPointer taggerHP = decodeHP(taggerEnc);
    HPointer routerHP = decodeHP(routerEnc);
    HPointer posixHP  = listNil();
    HPointer msgHP    = listNil();

    {
        Elm::StackRootGuard guard(
            { &taggerHP, &routerHP, &posixHP, &msgHP, &succeedTask });

        // `Posix` is `type Posix = Posix Int`: a Custom with constructor 0 and one unboxed Int field. The tagger
        // reads that field, so it must be given the Custom, not a bare boxed Int.
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

    // taggerHP and routerHP are no longer rooted, but nothing below uses them.
    scheduleTimerTick(intervalMs, generation);

    return reinterpret_cast<void*>(encodeHP(succeedTask));
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
    return reinterpret_cast<void*>(encodeHP(task));
}

/// The manager's `onEffects`, given the router, the commands (ignored), the subscriptions and the state
/// (ignored), in `args[0]` to `args[3]`. Returns `Task.succeed []`.
///
/// Makes `g_intervals` match the `Time.every` subscriptions in the list. Elements with another constructor are
/// skipped, as are NaN intervals; of several subscriptions with the same interval, one tagger is kept. A
/// dropped interval's entry is erased and its recorded tick withdrawn. A new interval gets an entry with a
/// fresh generation and its first tick is scheduled. An interval already present keeps its generation and its
/// tick chain, with its tagger and router replaced by this call's. Also registers the root scanner on the first
/// call.
static void* timeOnEffectsEvaluator(void* args[]) {
    uint64_t routerEnc = reinterpret_cast<uint64_t>(args[0]);

    uint64_t subsEnc = reinterpret_cast<uint64_t>(args[2]);
    HPointer subs = decodeHP(subsEnc);

    std::unordered_map<double, uint64_t> requestedIntervals;  // Interval to encoded tagger.

    // Nothing in this walk allocates, so the encoded taggers stay valid until they are stored.
    for (Elm::alloc::ListCursor l(subs); !l.done(); l.next()) {
        void* subPtr = Allocator::instance().resolve(l.current().p);
        if (subPtr) {
            Custom* sub = static_cast<Custom*>(subPtr);
            if (sub->ctor == CTOR_TIME_EVERY) {
                double interval = sub->values[0].f;
                uint64_t taggerEnc = encodeHP(sub->values[1].p);
                requestedIntervals[interval] = taggerEnc;
            }
        }
    }

    // A NaN key would never be found again, since NaN compares unequal to itself.
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

        for (auto& [intervalMs, taggerEnc] : normalizedRequested) {
            auto it = g_intervals.find(intervalMs);
            if (it == g_intervals.end()) {
                uint64_t gen = g_nextGeneration.fetch_add(1);
                g_intervals.emplace(intervalMs, IntervalState{
                    intervalMs, gen, taggerEnc, routerEnc, /*tickToken=*/0
                });
                toStart.push_back({ intervalMs, gen });
            } else {
                // Overwriting drops this map's root for the old tagger and router.
                it->second.taggerEnc = taggerEnc;
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
    return reinterpret_cast<void*>(encodeHP(task));
}

/// The manager's `onSelfMsg`, given the router, a self-message and the state in `args[0]` to `args[2]`. Returns
/// `Task.succeed state`. The manager never sends itself messages; ticks call `sendToApp` themselves.
static void* timeOnSelfMsgEvaluator(void* args[]) {
    uint64_t stateEnc = reinterpret_cast<uint64_t>(args[2]);
    HPointer task = Scheduler::instance().taskSucceed(decodeHP(stateEnc));
    return reinterpret_cast<void*>(encodeHP(task));
}

/// The tagger `subMap` builds: given the mapper, the original tagger and a `Posix` in `args[0]` to `args[2]`,
/// returns `mapper (origTagger posix)`.
static void* composedTaggerEvaluator(void* args[]) {
    uint64_t mapperEnc = reinterpret_cast<uint64_t>(args[0]);
    uint64_t taggerEnc = reinterpret_cast<uint64_t>(args[1]);
    uint64_t timeEnc = reinterpret_cast<uint64_t>(args[2]);

    // The tagger may allocate and move the mapper, so the mapper is rooted across that call.
    HPointer mapperHP = decodeHP(mapperEnc);
    Elm::StackRootGuard mapperRoot(&mapperHP);

    uint64_t msgEnc = eco_apply_closure(HPtr::fromBits(taggerEnc), &timeEnc, 1).toBits();

    HPointer msgHP = decodeHP(msgEnc);
    Elm::StackRootGuard msgRoot(&msgHP);
    HPtr mapperCl = HPtr::fromBits(encodeHP(mapperHP));
    uint64_t msgArg = encodeHP(msgHP);
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
    HPointer mapper = decodeHP(reinterpret_cast<uint64_t>(args[0]));
    HPointer origSub = decodeHP(reinterpret_cast<uint64_t>(args[1]));
    HPointer origTagger = listNil();
    Elm::StackRootGuard guards(&mapper, &origSub, &origTagger);

    void* subPtr = allocator.resolve(origSub);
    if (!subPtr) {
        return reinterpret_cast<void*>(encodeHP(origSub));
    }

    Custom* sub = static_cast<Custom*>(subPtr);
    if (sub->ctor != CTOR_TIME_EVERY) {
        return reinterpret_cast<void*>(encodeHP(origSub));
    }

    // `sub` is read before the first allocation; it may be stale after it.
    double interval = sub->values[0].f;
    origTagger = sub->values[1].p;

    HPointer composedTagger = allocClosure(composedTaggerEvaluator, 3);
    Elm::StackRootGuard ctRoot(&composedTagger);
    void* clPtr = allocator.resolve(composedTagger);
    if (clPtr) {
        closureCapture(clPtr, boxed(mapper), true);
        // Re-resolved in case the first capture allocated and moved the closure.
        clPtr = allocator.resolve(composedTagger);
        closureCapture(clPtr, boxed(origTagger), true);
    }

    std::vector<Unboxable> values(2);
    values[0].f = interval;
    values[1].p = composedTagger;

    HPointer newSub = custom(CTOR_TIME_EVERY, values, 0b10);
    return reinterpret_cast<void*>(encodeHP(newSub));
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
    HPointer initCl = allocClosure(timeInitEvaluator, 0);

    HPointer onEffectsCl = allocClosure(timeOnEffectsEvaluator, 4);

    HPointer onSelfMsgCl = allocClosure(timeOnSelfMsgEvaluator, 3);

    HPointer subMapCl = allocClosure(timeSubMapEvaluator, 2);

    PlatformRuntime::ManagerInfo info;
    info.init = encodeHP(initCl);
    info.onEffects = encodeHP(onEffectsCl);
    info.onSelfMsg = encodeHP(onSelfMsgCl);
    info.cmdMap = encodeHP(listNil());
    info.subMap = encodeHP(subMapCl);

    PlatformRuntime::instance().registerManager("Time", info);
}

} // extern "C"
