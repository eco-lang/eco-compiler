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

    // Create a sendToApp closure that captures the router
    // Arity = 2: 1 capture (router) + 1 arg (value)
    HPointer sendToAppCl = allocClosure(taskSendToAppEvaluator, 2);
    void* clPtr = Allocator::instance().resolve(sendToAppCl);
    if (clPtr) {
        closureCapture(clPtr, boxed(router), true);
    }

    // Iterate over the commands list
    HPointer current = cmds;
    while (!isNil(current)) {
        void* cellPtr = Allocator::instance().resolve(current);
        if (!cellPtr) break;

        Cons* cell = static_cast<Cons*>(cellPtr);
        HPointer cmdHP = cell->head.p;

        // Each cmd is a Perform(task) Custom with values[0] = the task
        void* cmdPtr = Allocator::instance().resolve(cmdHP);
        if (cmdPtr) {
            Custom* cmd = static_cast<Custom*>(cmdPtr);
            HPointer innerTask = cmd->values[0].p;

            // Re-resolve sendToAppCl after any potential GC from previous iteration
            sendToAppCl = decodeHP(encodeHP(sendToAppCl));

            // Chain: innerTask |> andThen(\value -> sendToApp(router, value))
            HPointer chainedTask = Scheduler::instance().taskAndThen(sendToAppCl, innerTask);

            // Spawn the chained task as a process
            Scheduler::instance().rawSpawn(chainedTask);
        }

        current = cell->tail;
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

// cmdMap : (a -> b) -> MyCmd a -> MyCmd b
// Maps over the tagger in a Perform command
static void* taskCmdMapEvaluator(void* args[]) {
    // args[0] = mapper function (a -> b)
    // args[1] = original cmd (Perform(task))

    uint64_t mapperEnc = reinterpret_cast<uint64_t>(args[0]);
    uint64_t cmdEnc = reinterpret_cast<uint64_t>(args[1]);

    HPointer origCmd = decodeHP(cmdEnc);

    void* cmdPtr = Allocator::instance().resolve(origCmd);
    if (!cmdPtr) {
        return reinterpret_cast<void*>(cmdEnc);
    }

    Custom* cmd = static_cast<Custom*>(cmdPtr);
    HPointer innerTask = cmd->values[0].p;

    // Map the task: Task.map mapper innerTask
    // This is taskAndThen(\val -> taskSucceed(mapper(val)), innerTask)
    HPointer mappedTask = Scheduler::instance().taskAndThen(
        decodeHP(mapperEnc), innerTask);

    // Create new Perform with mapped task
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
    info.init = initCl;
    info.onEffects = onEffectsCl;
    info.onSelfMsg = onSelfMsgCl;
    info.cmdMap = cmdMapCl;
    info.subMap = listNil();  // No subscriptions

    PlatformRuntime::instance().registerManager("Task", info);
}

} // extern "C"
