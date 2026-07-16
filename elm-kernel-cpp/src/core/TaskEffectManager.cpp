//===- TaskEffectManager.cpp - Task effect manager implementation ----------===//
//
// Manages Task.perform and Task.attempt commands by spawning each task and
// routing the result back to the Elm application via sendToApp.
//
// The Task module is a Cmd-only effect manager (no subscriptions).
//
//===----------------------------------------------------------------------===//

#include "../KernelExports.h"
#include "../ExportHelpers.hpp"
#include "allocator/Heap.hpp"
#include "allocator/HeapHelpers.hpp"
#include "allocator/Allocator.hpp"
#include "platform/Scheduler.hpp"
#include "platform/PlatformRuntime.hpp"

using namespace Elm;
using namespace Elm::alloc;
using namespace Elm::Platform;

namespace {

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
// State is Nil (Task manager has no persistent state)
static void* taskInitEvaluator(void* args[]) {
    (void)args;
    HPointer nilState = listNil();
    HPointer task = Scheduler::instance().taskSucceed(nilState);
    return reinterpret_cast<void*>(encodeHP(task));
}

// sendToApp callback: \value -> sendToApp(router, value)
// Captures router in args[0], receives value in args[1]
static void* taskSendToAppEvaluator(void* args[]) {
    uint64_t routerEnc = reinterpret_cast<uint64_t>(args[0]);
    uint64_t valueEnc = reinterpret_cast<uint64_t>(args[1]);

    HPointer router = decodeHP(routerEnc);
    HPointer value = decodeHP(valueEnc);

    // sendToApp triggers the Elm update cycle
    PlatformRuntime::instance().sendToApp(router, value);

    // Return Task.succeed(Unit)
    HPointer unitVal = Elm::alloc::unit();
    HPointer task = Scheduler::instance().taskSucceed(unitVal);
    return reinterpret_cast<void*>(encodeHP(task));
}

// onEffects : Router msg -> List (MyCmd msg) -> List (MySub msg) -> State -> Task Never State
// For Task: process commands (Perform values), ignore subs
static void* taskOnEffectsEvaluator(void* args[]) {
    // args[0] = router (captured)
    // args[1] = cmds
    // args[2] = subs (ignored, Task has no subs)
    // args[3] = state

    uint64_t routerEnc = reinterpret_cast<uint64_t>(args[0]);
    uint64_t cmdsEnc = reinterpret_cast<uint64_t>(args[1]);

    HPointer router = decodeHP(routerEnc);
    HPointer cmds = decodeHP(cmdsEnc);

    // Root router + cmds BEFORE allocClosure: the allocation may GC, and
    // closureCapture would otherwise bake pre-GC router bits into the
    // sendToApp closure (and the loop below would seed from stale cmds).
    Elm::StackRootGuard argGuard(&router, &cmds);

    // Create a sendToApp closure that captures the router
    // Arity = 2: 1 capture (router) + 1 arg (value)
    HPointer sendToAppCl = allocClosure(taskSendToAppEvaluator, 2);
    void* clPtr = Allocator::instance().resolve(sendToAppCl);
    if (clPtr) {
        closureCapture(clPtr, boxed(router), true);
    }

    // Iterate over the commands list.
    //
    // `current` (the list cursor) and `sendToAppCl` both survive across
    // `taskAndThen` / `rawSpawn`, which allocate and may GC; without
    // rooting, their raw C++ locals would become stale. Root both via
    // StackRootGuard so GC updates them in place.
    //
    // NB: reading `cell->tail` *after* the allocations (via a cached
    // `Cons*`) is unsafe — the old Cons location gets a Forward header
    // after evacuation and its payload bytes are cleared the next time
    // `clearToSpaceFreeRegion` runs. Snapshot the tail HP *before* any
    // allocation, so the loop never dereferences a stale pointer.
    HPointer current = cmds;
    // `nextTail` (the per-iteration tail snapshot) is the loop's advance
    // value: it crosses the taskAndThen/rawSpawn GC points below, so it must
    // be rooted alongside the cursor (mirrors httpOnEffectsEvaluator).
    HPointer nextTail = listNil();
    {
        Elm::StackRootGuard guard(&current, &sendToAppCl, &nextTail);

        while (!isNil(current)) {
            void* cellPtr = Allocator::instance().resolve(current);
            if (!cellPtr) break;

            // Snapshot tail and cmd HP before any allocation can move the Cons.
            Cons* cell = static_cast<Cons*>(cellPtr);
            nextTail = cell->tail;
            HPointer cmdHP = cell->head.p;

            // Each cmd is a Perform(task) Custom with values[0] = the task.
            void* cmdPtr = Allocator::instance().resolve(cmdHP);
            if (cmdPtr) {
                Custom* cmd = static_cast<Custom*>(cmdPtr);
                HPointer innerTask = cmd->values[0].p;

                // Chain: innerTask |> andThen(\value -> sendToApp(router, value))
                HPointer chainedTask = Scheduler::instance().taskAndThen(sendToAppCl, innerTask);

                // Spawn the chained task as a process
                Scheduler::instance().rawSpawn(chainedTask);
            }

            current = nextTail;
        }
    }

    // Return Task.succeed(state)
    uint64_t stateEnc = reinterpret_cast<uint64_t>(args[3]);
    HPointer task = Scheduler::instance().taskSucceed(decodeHP(stateEnc));
    return reinterpret_cast<void*>(encodeHP(task));
}

// onSelfMsg : Router msg -> selfMsg -> State -> Task Never State
// Task doesn't use self messages
static void* taskOnSelfMsgEvaluator(void* args[]) {
    // Just return Task.succeed(state)
    uint64_t stateEnc = reinterpret_cast<uint64_t>(args[2]);
    HPointer task = Scheduler::instance().taskSucceed(decodeHP(stateEnc));
    return reinterpret_cast<void*>(encodeHP(task));
}

// Helper: continuation for taskCmdMapEvaluator.
// args[0] = mapper (captured), args[1] = task result value.
// Returns Task.succeed(mapper(value)) — i.e. the `\v -> succeed (f v)`
// body of `Task.map f task = andThen (\v -> succeed (f v)) task`.
static void* taskMapContinuationEvaluator(void* args[]) {
    uint64_t mapperEnc = reinterpret_cast<uint64_t>(args[0]);
    uint64_t valueEnc = reinterpret_cast<uint64_t>(args[1]);

    uint64_t mappedEnc =
        eco_apply_closure(HPtr::fromBits(mapperEnc), &valueEnc, 1).toBits();

    HPointer task = Scheduler::instance().taskSucceed(decodeHP(mappedEnc));
    return reinterpret_cast<void*>(encodeHP(task));
}

// cmdMap : (a -> b) -> MyCmd a -> MyCmd b
// Maps over the result of a Perform command's task.
static void* taskCmdMapEvaluator(void* args[]) {
    // args[0] = mapper function (a -> b)
    // args[1] = original cmd (Perform(task))

    uint64_t cmdEnc = reinterpret_cast<uint64_t>(args[1]);

    // Root mapper/origCmd/innerTask across the allocations below
    // (allocClosure / closureCapture / taskAndThen / custom).
    HPointer mapper = decodeHP(reinterpret_cast<uint64_t>(args[0]));
    HPointer origCmd = decodeHP(cmdEnc);
    HPointer innerTask = listNil();
    Elm::StackRootGuard guard(&mapper, &origCmd, &innerTask);

    void* cmdPtr = Allocator::instance().resolve(origCmd);
    if (!cmdPtr) {
        return reinterpret_cast<void*>(cmdEnc);
    }

    Custom* cmd = static_cast<Custom*>(cmdPtr);
    innerTask = cmd->values[0].p;
    // `cmd`/`cmdPtr` are stale-on-GC from here; do not re-use them.

    // continuation = \v -> Task.succeed (mapper v)
    HPointer continuation = allocClosure(taskMapContinuationEvaluator, 2);
    Elm::StackRootGuard contGuard(&continuation);
    if (void* clPtr = Allocator::instance().resolve(continuation)) {
        closureCapture(clPtr, boxed(mapper), true);
    }

    // Task.map mapper innerTask = andThen continuation innerTask
    HPointer mappedTask =
        Scheduler::instance().taskAndThen(continuation, innerTask);
    Elm::StackRootGuard taskGuard(&mappedTask);

    // Create new Perform with the mapped task
    std::vector<Unboxable> values(1);
    values[0].p = mappedTask;
    HPointer newCmd = custom(0, values, 0);  // tag 0 = Perform
    return reinterpret_cast<void*>(encodeHP(newCmd));
}

} // anonymous namespace

// ============================================================================
// Registration function (called from runtime initialization)
// ============================================================================

extern "C" {

void eco_register_task_effect_manager() {
    // Create init closure (0-arg)
    HPointer initCl = allocClosure(taskInitEvaluator, 0);

    // Create onEffects closure (4-arg curried)
    HPointer onEffectsCl = allocClosure(taskOnEffectsEvaluator, 4);

    // Create onSelfMsg closure (3-arg curried)
    HPointer onSelfMsgCl = allocClosure(taskOnSelfMsgEvaluator, 3);

    // Create cmdMap closure (2-arg)
    HPointer cmdMapCl = allocClosure(taskCmdMapEvaluator, 2);

    // Register with PlatformRuntime
    PlatformRuntime::ManagerInfo info;
    info.init = encodeHP(initCl);
    info.onEffects = encodeHP(onEffectsCl);
    info.onSelfMsg = encodeHP(onSelfMsgCl);
    info.cmdMap = encodeHP(cmdMapCl);
    info.subMap = encodeHP(listNil());  // No subscriptions

    PlatformRuntime::instance().registerManager("Task", info);
}

} // extern "C"
