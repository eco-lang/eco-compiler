//===- HttpEffectManager.cpp - Http effect manager implementation ----------===//
//
// Manages Http.get/post/request commands by executing the HTTP tasks and
// routing responses back to the Elm application.
//
//===----------------------------------------------------------------------===//

#include "../KernelExports.h"
#include "../ExportHelpers.hpp"
#include "allocator/Heap.hpp"
#include "allocator/HeapHelpers.hpp"
#include "allocator/Allocator.hpp"
#include "allocator/RuntimeExports.h"
#include "allocator/StringOps.hpp"
#include "platform/Scheduler.hpp"
#include "platform/PlatformRuntime.hpp"
#include <string>

using namespace Elm;
using namespace Elm::alloc;
using namespace Elm::Platform;

// Defined in HttpExports.cpp: mark a tracked request cancelled by its tracker
// string (drop-delivery). The Cancel command branch calls this.
extern "C" void Eco_Http_cancelTracker(uint64_t trackerEnc);

namespace {

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

// Convert an Elm String HPointer to UTF-8 std::string. Returns "" for the
// embedded EmptyString constant (resolve would assert on it).
static std::string trackerToStd(HPointer hp) {
    if (hp.ptr_ind != 0) return "";
    void* ptr = Allocator::instance().resolve(hp);
    if (!ptr) return "";
    return Elm::StringOps::toStdString(ptr);
}

// ============================================================================
// Effect Manager Closures
// ============================================================================

// init : Task Never State
// State = List (MySub msg) (the active progress subscriptions); starts empty.
static void* httpInitEvaluator(void* args[]) {
    (void)args;
    // Return Task.succeed([])
    HPointer nilState = listNil();
    HPointer task = Scheduler::instance().taskSucceed(nilState);
    return reinterpret_cast<void*>(encodeHP(task));
}

// Helper: Success handler for spawned HTTP tasks
// args[0] = router, args[1] = value (result from task)
static void* httpSuccessHandler(void* args[]) {
    uint64_t routerEnc = reinterpret_cast<uint64_t>(args[0]);
    uint64_t valueEnc = reinterpret_cast<uint64_t>(args[1]);

    HPointer router = decodeHP(routerEnc);
    HPointer value = decodeHP(valueEnc);

    // Send value directly as message to app
    // (assuming tagger was pre-applied via Cmd.map)
    PlatformRuntime::instance().sendToApp(router, value);

    return reinterpret_cast<void*>(encodeHP(
        Scheduler::instance().taskSucceed(unit())));
}

// Helper: Map handler for cmdMap
// args[0] = mapper, args[1] = value
static void* httpMapHandler(void* args[]) {
    uint64_t mapperEnc = reinterpret_cast<uint64_t>(args[0]);
    uint64_t valueEnc = reinterpret_cast<uint64_t>(args[1]);

    // Apply mapper to value
    uint64_t mappedEnc = eco_apply_closure(HPtr::fromBits(mapperEnc), &valueEnc, 1).toBits();

    // Return Task.succeed(mappedValue)
    HPointer task = Scheduler::instance().taskSucceed(decodeHP(mappedEnc));
    return reinterpret_cast<void*>(encodeHP(task));
}

// onEffects : Router msg -> List (MyCmd msg) -> List (MySub msg) -> State -> Task Never State
// Processes commands (Request spawns the HTTP task; Cancel marks a tracked
// request for drop-delivery) and stores the current subscriptions as the new
// State so onSelfMsg can route progress to them.
static void* httpOnEffectsEvaluator(void* args[]) {
    // args[0] = router
    // args[1] = cmds (List (MyCmd msg))
    // args[2] = subs (List (MySub msg)) — becomes the new State
    // args[3] = state (previous subscription list; not needed)

    auto& sched = Scheduler::instance();
    auto& allocator = Allocator::instance();

    // `router` and the list cursor `current` must survive every alloc inside
    // the loop body (allocClosure / closureCapture / taskAndThen / rawSpawn);
    // by-value HPointer locals would otherwise become stale across the GC.
    HPointer router = decodeHP(reinterpret_cast<uint64_t>(args[0]));
    HPointer current = decodeHP(reinterpret_cast<uint64_t>(args[1]));
    Elm::StackRootGuard outerRoots(&router, &current);

    while (!isNil(current)) {
        void* cellPtr = allocator.resolve(current);
        if (!cellPtr) break;

        Cons* cell = static_cast<Cons*>(cellPtr);
        // Snapshot head/tail BEFORE any subsequent alloc; cell becomes a stale
        // raw pointer the moment the next allocation runs.
        HPointer cmdHP = cell->head.p;
        HPointer nextCurrent = cell->tail;
        Elm::StackRootGuard iterRoots(&cmdHP, &nextCurrent);

        void* cmdPtr = allocator.resolve(cmdHP);
        if (cmdPtr) {
            Header* header = static_cast<Header*>(cmdPtr);
            // Stock elm/http command: `MyCmd msg = Cancel String | Request {...}`
            // (Cancel=ctor 0, Request=ctor 1).
            u16 ctor = (header->tag == Tag_Custom)
                ? static_cast<u16>(static_cast<Custom*>(cmdPtr)->ctor)
                : 0xFFFF;
            if (header->tag == Tag_Custom && ctor == 1) {
                // Request: call the stock kernel contract
                // `toTask router (sendToApp router) req` to build the HTTP task,
                // then spawn it. toTask also wires up progress tracking when the
                // request carries `tracker = Just _`.
                HPointer req = static_cast<Custom*>(cmdPtr)->values[0].p;
                Elm::StackRootGuard reqRoot(&req);

                // sendToApp closure (resultToTask): httpSuccessHandler sends the
                // produced msg to the app and returns Task.succeed(unit).
                HPointer successCl = allocClosure(httpSuccessHandler, 2);
                Elm::StackRootGuard clRoot(&successCl);
                void* clPtr = allocator.resolve(successCl);
                if (clPtr) {
                    closureCapture(clPtr, boxed(router), true);
                }

                HPtr task = Elm_Kernel_Http_toTask(
                    HPtr::fromBits(encodeHP(router)),
                    HPtr::fromBits(encodeHP(successCl)),
                    HPtr::fromBits(encodeHP(req)));
                HPointer taskHP = decodeHP(task.toBits());
                Elm::StackRootGuard taskRoot(&taskHP);
                sched.rawSpawn(taskHP);
            } else if (header->tag == Tag_Custom && ctor == 0) {
                // Cancel tracker: mark the tracked request for drop-delivery.
                // Reading the tracker String and calling the cancel hook do not
                // allocate, so no extra rooting is needed here.
                HPointer tracker = static_cast<Custom*>(cmdPtr)->values[0].p;
                Eco_Http_cancelTracker(encodeHP(tracker));
            } else if (header->tag == Tag_Task) {
                // Fallback: a command that is already a Task — spawn directly.
                HPointer successCl = allocClosure(httpSuccessHandler, 2);
                Elm::StackRootGuard clRoot(&successCl);
                void* clPtr = allocator.resolve(successCl);
                if (clPtr) {
                    closureCapture(clPtr, boxed(router), true);
                }
                HPointer wrappedTask = sched.taskAndThen(successCl, cmdHP);
                sched.rawSpawn(wrappedTask);
            }
        }

        current = nextCurrent;
    }

    // The manager State is the current subscription list (List (MySub msg));
    // onSelfMsg iterates it to route progress. Return Task.succeed(subs) so the
    // latest subscriptions (args[2]) become the new state. Read args[2] at the
    // point of use to pick up the post-loop-GC value from the caller's rooted
    // combined_args buffer.
    uint64_t subsEnc = reinterpret_cast<uint64_t>(args[2]);
    HPointer task = sched.taskSucceed(decodeHP(subsEnc));
    return reinterpret_cast<void*>(encodeHP(task));
}

// onSelfMsg : Router msg -> SelfMsg -> State -> Task Never State
// SelfMsg = (tracker : String, progress : Progress). State = List (MySub msg).
// For each subscription `MySub subTracker toMsg` whose subTracker matches the
// progress tracker, deliver `toMsg progress` to the app via sendToApp (mirrors
// stock Http.onSelfMsg / maybeSend). Returns Task.succeed(state) unchanged.
static void* httpOnSelfMsgEvaluator(void* args[]) {
    auto& sched = Scheduler::instance();
    auto& allocator = Allocator::instance();

    HPointer router  = decodeHP(reinterpret_cast<uint64_t>(args[0]));
    HPointer selfMsg = decodeHP(reinterpret_cast<uint64_t>(args[1]));
    HPointer state   = decodeHP(reinterpret_cast<uint64_t>(args[2]));
    Elm::StackRootGuard topRoots(&router, &selfMsg, &state);

    // selfMsg = Tuple2(tracker, progress).
    void* smPtr = allocator.resolve(selfMsg);
    if (smPtr) {
        Tuple2* sm = static_cast<Tuple2*>(smPtr);
        HPointer tracker  = sm->a.p;
        HPointer progress = sm->b.p;
        Elm::StackRootGuard msgRoots(&tracker, &progress);
        std::string wantTracker = trackerToStd(tracker);

        // Walk the subscription list (state). router and progress must survive
        // each toMsg / sendToApp call (both run Elm code that may GC).
        HPointer current = state;
        Elm::StackRootGuard walkRoots(&current, &router, &progress);
        while (!isNil(current)) {
            void* cellPtr = allocator.resolve(current);
            if (!cellPtr) break;
            Cons* cell = static_cast<Cons*>(cellPtr);
            HPointer subHP = cell->head.p;
            HPointer nextCurrent = cell->tail;
            Elm::StackRootGuard iterRoots(&subHP, &nextCurrent);

            void* subPtr = allocator.resolve(subHP);
            if (subPtr) {
                // MySub tracker toMsg — Custom ctor 0, [tracker(String), toMsg].
                Custom* sub = static_cast<Custom*>(subPtr);
                HPointer subTracker = sub->values[0].p;
                HPointer toMsg = sub->values[1].p;
                if (trackerToStd(subTracker) == wantTracker) {
                    Elm::StackRootGuard sg(&toMsg);
                    HPointer msg = sched.callClosure1(toMsg, progress);
                    PlatformRuntime::instance().sendToApp(router, msg);
                }
            }
            current = nextCurrent;
        }
    }

    // Return Task.succeed(state); re-read from the rooted local (GC may have
    // moved it during the loop).
    HPointer task = sched.taskSucceed(state);
    return reinterpret_cast<void*>(encodeHP(task));
}

// cmdMap : (a -> b) -> MyCmd a -> MyCmd b
// Maps over the message type in Http commands
static void* httpCmdMapEvaluator(void* args[]) {
    // args[0] = mapper function
    // args[1] = original cmd

    auto& allocator = Allocator::instance();

    // Root mapper and origCmd across allocClosure / closureCapture /
    // taskAndThen — each is a GC point that would otherwise leave the
    // by-value HPointer locals pointing at the pre-swap location.
    HPointer mapper = decodeHP(reinterpret_cast<uint64_t>(args[0]));
    HPointer origCmd = decodeHP(reinterpret_cast<uint64_t>(args[1]));
    Elm::StackRootGuard guards(&mapper, &origCmd);

    // If the command is a Task, wrap it with map/andThen
    void* cmdPtr = allocator.resolve(origCmd);
    if (!cmdPtr) {
        return reinterpret_cast<void*>(encodeHP(origCmd));
    }

    Header* header = static_cast<Header*>(cmdPtr);
    if (header->tag != Tag_Task) {
        return reinterpret_cast<void*>(encodeHP(origCmd));
    }

    // Create andThen callback that applies mapper to result
    HPointer mapCl = allocClosure(httpMapHandler, 2);
    Elm::StackRootGuard mapClRoot(&mapCl);
    void* clPtr = allocator.resolve(mapCl);
    if (clPtr) {
        closureCapture(clPtr, boxed(mapper), true);
    }

    // Create mapped task
    HPointer mappedTask = Scheduler::instance().taskAndThen(mapCl, origCmd);
    return reinterpret_cast<void*>(encodeHP(mappedTask));
}

} // anonymous namespace

// ============================================================================
// Registration function (called from runtime initialization)
// ============================================================================

extern "C" {

void eco_register_http_effect_manager() {
    // Create init closure
    HPointer initCl = allocClosure(httpInitEvaluator, 0);

    // Create onEffects closure (4-arg curried)
    HPointer onEffectsCl = allocClosure(httpOnEffectsEvaluator, 4);

    // Create onSelfMsg closure (3-arg curried)
    HPointer onSelfMsgCl = allocClosure(httpOnSelfMsgEvaluator, 3);

    // Create cmdMap closure (2-arg)
    HPointer cmdMapCl = allocClosure(httpCmdMapEvaluator, 2);

    // Register with PlatformRuntime
    PlatformRuntime::ManagerInfo info;
    info.init = encodeHP(initCl);
    info.onEffects = encodeHP(onEffectsCl);
    info.onSelfMsg = encodeHP(onSelfMsgCl);
    info.cmdMap = encodeHP(cmdMapCl);
    info.subMap = encodeHP(listNil());  // No subscriptions

    PlatformRuntime::instance().registerManager("Http", info);
}

} // extern "C"
