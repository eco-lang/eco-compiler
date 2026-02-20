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
    uint64_t mappedEnc = eco_apply_closure(mapperEnc, &valueEnc, 1);

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

    uint64_t routerEnc = reinterpret_cast<uint64_t>(args[0]);
    uint64_t cmdsEnc = reinterpret_cast<uint64_t>(args[1]);

    HPointer router = decodeHP(routerEnc);
    HPointer cmds = decodeHP(cmdsEnc);

    auto& sched = Scheduler::instance();

    // Process each command
    // Each Http command is a record: { request : Request msg, toMsg : Result Error a -> msg }
    // Or it might be the raw Task already wrapped in a Cmd structure

    HPointer current = cmds;
    while (!isNil(current)) {
        void* cellPtr = Allocator::instance().resolve(current);
        if (!cellPtr) break;

        Cons* cell = static_cast<Cons*>(cellPtr);
        HPointer cmdHP = cell->head.p;

        // The command structure depends on how Http.request builds it
        // In Elm's Http module, commands wrap a Task and a tagger
        // The command is: { task : Task Error a, toMsg : Result Error a -> msg }

        void* cmdPtr = Allocator::instance().resolve(cmdHP);
        if (cmdPtr) {
            // Check if this is a record with task and toMsg fields
            // Fields in canonical order: task=0, toMsg=1 (alphabetically: task, toMsg)
            // Actually the ordering depends on the exact field names used in Http.elm
            // Let's assume the Cmd carries: { request, toMsg } or similar

            // For the basic case, HTTP commands might just be the Task directly
            // with the tagger pre-applied (the result already goes to the right msg type)

            // Check the type - if it's a Task, spawn it directly
            // If it's a Custom/Record, extract the task and spawn it

            Record* cmd = static_cast<Record*>(cmdPtr);

            // Try to handle it as having a task field
            // For now, assume the command IS the task (simplest case)
            // The actual structure depends on how Platform.Cmd.map wraps things

            // Spawn the task
            // When the task completes, its result needs to be sent to app via router

            // Create a continuation that sends result to app
            auto resultHandler = [](void* innerArgs[]) -> void* {
                uint64_t routerEnc = reinterpret_cast<uint64_t>(innerArgs[0]);
                uint64_t taggerEnc = reinterpret_cast<uint64_t>(innerArgs[1]);
                uint64_t resultEnc = reinterpret_cast<uint64_t>(innerArgs[2]);

                HPointer router = decodeHP(routerEnc);
                HPointer result = decodeHP(resultEnc);

                // Call tagger(result) to get the message
                uint64_t msgEnc = eco_apply_closure(taggerEnc, &resultEnc, 1);
                HPointer msg = decodeHP(msgEnc);

                // Send to app
                PlatformRuntime::instance().sendToApp(router, msg);

                return reinterpret_cast<void*>(encodeHP(unit()));
            };

            // For now, if the cmd is a Record, try to extract task field
            // This is a simplified approach - real implementation would need
            // to match Elm's actual Cmd structure

            // The Elm Http module typically wraps commands as:
            // Platform.Cmd.map toMsg (Http.toTask request)
            // Which means the tagger is already applied by Cmd.map

            // In that case, we just need to spawn the task and send result to app
            // Let's check if it looks like a task (has Task tag)

            Header* header = static_cast<Header*>(cmdPtr);
            if (header->tag == Tag_Task) {
                // It's directly a Task - spawn it with callback to send result
                Task* taskObj = static_cast<Task*>(cmdPtr);

                // Create andThen to handle success
                HPointer successCl = allocClosure(httpSuccessHandler, 2);
                void* clPtr = Allocator::instance().resolve(successCl);
                if (clPtr) {
                    closureCapture(clPtr, boxed(router), true);
                }

                // Wrap task with andThen for success handling
                HPointer wrappedTask = sched.taskAndThen(successCl, cmdHP);

                // Spawn process for this command
                sched.rawSpawn(wrappedTask);
            }
            // If it's not directly a Task, it might be a Cmd wrapper
            // For now, skip non-Task commands
        }

        current = cell->tail;
    }

    // Return Task.succeed(state) - state unchanged
    uint64_t stateEnc = reinterpret_cast<uint64_t>(args[3]);
    HPointer task = Scheduler::instance().taskSucceed(decodeHP(stateEnc));
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

    uint64_t mapperEnc = reinterpret_cast<uint64_t>(args[0]);
    uint64_t cmdEnc = reinterpret_cast<uint64_t>(args[1]);

    HPointer mapper = decodeHP(mapperEnc);
    HPointer origCmd = decodeHP(cmdEnc);

    // If the command is a Task, wrap it with map/andThen
    void* cmdPtr = Allocator::instance().resolve(origCmd);
    if (!cmdPtr) {
        return reinterpret_cast<void*>(cmdEnc);
    }

    Header* header = static_cast<Header*>(cmdPtr);
    if (header->tag != Tag_Task) {
        return reinterpret_cast<void*>(cmdEnc);
    }

    // Create andThen callback that applies mapper to result
    HPointer mapCl = allocClosure(httpMapHandler, 2);
    void* clPtr = Allocator::instance().resolve(mapCl);
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
    info.init = initCl;
    info.onEffects = onEffectsCl;
    info.onSelfMsg = onSelfMsgCl;
    info.cmdMap = cmdMapCl;
    info.subMap = listNil();  // No subscriptions

    PlatformRuntime::instance().registerManager("Http", info);
}

} // extern "C"
