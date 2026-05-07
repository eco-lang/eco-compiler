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
#include "platform/Scheduler.hpp"
#include "platform/PlatformRuntime.hpp"

using namespace Elm;
using namespace Elm::alloc;
using namespace Elm::Platform;

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

// ============================================================================
// Effect Manager Closures
// ============================================================================

// init : Task Never State
// State is just Nil (stateless effect manager)
static void* httpInitEvaluator(void* args[]) {
    (void)args;
    // Return Task.succeed(Nil)
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
// For Http: processes commands (HTTP requests), no subscriptions
static void* httpOnEffectsEvaluator(void* args[]) {
    // args[0] = router
    // args[1] = cmds (List of Http commands)
    // args[2] = subs (ignored - Http has no subscriptions)
    // args[3] = state

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
            if (header->tag == Tag_Task) {
                // It's directly a Task - spawn it with callback to send result.
                // Create andThen to handle success.
                HPointer successCl = allocClosure(httpSuccessHandler, 2);
                Elm::StackRootGuard clRoot(&successCl);
                void* clPtr = allocator.resolve(successCl);
                if (clPtr) {
                    closureCapture(clPtr, boxed(router), true);
                }

                // Wrap task with andThen for success handling.
                HPointer wrappedTask = sched.taskAndThen(successCl, cmdHP);

                // Spawn process for this command.
                sched.rawSpawn(wrappedTask);
            }
            // If it's not directly a Task, it might be a Cmd wrapper.
            // For now, skip non-Task commands.
        }

        current = nextCurrent;
    }

    // Return Task.succeed(state) - state unchanged. Read args[3] at the
    // point of use so we pick up the current (post-loop GCs) value from the
    // caller's rooted combined_args buffer.
    uint64_t stateEnc = reinterpret_cast<uint64_t>(args[3]);
    HPointer task = sched.taskSucceed(decodeHP(stateEnc));
    return reinterpret_cast<void*>(encodeHP(task));
}

// onSelfMsg : Router msg -> selfMsg -> State -> Task Never State
// Http doesn't use self messages
static void* httpOnSelfMsgEvaluator(void* args[]) {
    // Just return Task.succeed(state)
    uint64_t stateEnc = reinterpret_cast<uint64_t>(args[2]);
    HPointer task = Scheduler::instance().taskSucceed(decodeHP(stateEnc));
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
