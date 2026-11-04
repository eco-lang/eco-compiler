//===- TaskEffectManager.cpp - Task effect manager implementation ----------===//
//
// elm/core's `Task.perform` and `Task.attempt` produce commands, and commands are carried out by an effect
// manager. This file is the C++ effect manager for the `Task` home.
//
// A Task command is `Perform task`: a Custom with constructor 0 whose field 0 is a Task whose result is a
// message for the application. Carrying out the command means running `task |> andThen (sendToApp router)`
// as a new scheduler process. The manager has no subscriptions and no state of its own; its state is the
// Empty constant `[]`.
//
// Each manager function is an *evaluator*: the body of a closure, `void* (*)(void* args[])`, whose
// `args` are the closure's captured values followed by its call arguments, each an encoded HPointer
// word. `eco_register_task_effect_manager` wraps them in closures and hands them to
// `PlatformRuntime::registerManager`, which owns the meaning of each slot of `ManagerInfo`.
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

// Returns the word that encodes `h`.
static inline uint64_t encodeHP(HPointer h) {
    union { HPointer hp; uint64_t val; } u;
    u.hp = h;
    return u.val;
}

// Returns the HPointer encoded by `val`.
static inline HPointer decodeHP(uint64_t val) {
    union { HPointer hp; uint64_t val; } u;
    u.val = val;
    return u.hp;
}

// ============================================================================
// Effect Manager Closures
// ============================================================================

// Evaluates `init : Task Never State` with no arguments: returns a Task that succeeds with `[]`.
static void* taskInitEvaluator(void* args[]) {
    (void)args;
    HPointer nilState = listNil();
    HPointer task = Scheduler::instance().taskSucceed(nilState);
    return reinterpret_cast<void*>(encodeHP(task));
}

// Evaluates `\value -> sendToApp router value`, with the router captured in `args[0]` and the value in
// `args[1]`. Passes the value to `PlatformRuntime::sendToApp`, then returns a Task that succeeds with Unit.
static void* taskSendToAppEvaluator(void* args[]) {
    uint64_t routerEnc = reinterpret_cast<uint64_t>(args[0]);
    uint64_t valueEnc = reinterpret_cast<uint64_t>(args[1]);

    HPointer router = decodeHP(routerEnc);
    HPointer value = decodeHP(valueEnc);

    PlatformRuntime::instance().sendToApp(router, value);

    HPointer unitVal = Elm::alloc::unit();
    HPointer task = Scheduler::instance().taskSucceed(unitVal);
    return reinterpret_cast<void*>(encodeHP(task));
}

// Evaluates `onEffects : Router msg -> List (MyCmd msg) -> List (MySub msg) -> State -> Task Never State`
// with the four call arguments in `args[0..3]`. For each command `Perform task` in the list, in order, spawns a
// process running `task |> andThen (sendToApp router)`; the processes are enqueued, not run here. A command
// for which `resolve` returns null is skipped. Ignores the subscriptions and returns a Task that
// succeeds with the state from `args[3]`.
//
// The state word is read from `args` after the allocations below, which may collect; it is not rooted.
static void* taskOnEffectsEvaluator(void* args[]) {
    uint64_t routerEnc = reinterpret_cast<uint64_t>(args[0]);
    uint64_t cmdsEnc = reinterpret_cast<uint64_t>(args[1]);

    HPointer router = decodeHP(routerEnc);
    HPointer cmds = decodeHP(cmdsEnc);

    // Rooted before allocClosure, which may collect: otherwise closureCapture would store a stale router
    // and the walk below would start from a stale list.
    Elm::StackRootGuard argGuard(&router, &cmds);

    // Two slots: the captured router, then the value the Task succeeds with.
    HPointer sendToAppCl = allocClosure(taskSendToAppEvaluator, 2);
    void* clPtr = Allocator::instance().resolve(sendToAppCl);
    if (clPtr) {
        closureCapture(clPtr, boxed(router), true);
    }

    // `taskAndThen` and `rawSpawn` allocate and may collect. `sendToAppCl` is rooted, and RootedListCursor
    // keeps its list node rooted and resolves it afresh on every read and advance, so the walk never holds
    // a stale pointer across them.
    {
        Elm::StackRootGuard guard(&sendToAppCl);
        Elm::alloc::RootedListCursor cursor(cmds);
        Elm::Unboxable head;
        u8 kind;

        while (cursor.read(head, kind)) {
            HPointer cmdHP = head.p;

            void* cmdPtr = Allocator::instance().resolve(cmdHP);
            if (cmdPtr) {
                Custom* cmd = static_cast<Custom*>(cmdPtr);
                HPointer innerTask = cmd->values[0].p;

                HPointer chainedTask = Scheduler::instance().taskAndThen(sendToAppCl, innerTask);

                Scheduler::instance().rawSpawn(chainedTask);
            }

            cursor.advance();
        }
    }

    uint64_t stateEnc = reinterpret_cast<uint64_t>(args[3]);
    HPointer task = Scheduler::instance().taskSucceed(decodeHP(stateEnc));
    return reinterpret_cast<void*>(encodeHP(task));
}

// Evaluates `onSelfMsg : Router msg -> selfMsg -> State -> Task Never State` with the call arguments in
// `args[0..2]`: ignores the message and returns a Task that succeeds with the state from `args[2]`.
static void* taskOnSelfMsgEvaluator(void* args[]) {
    uint64_t stateEnc = reinterpret_cast<uint64_t>(args[2]);
    HPointer task = Scheduler::instance().taskSucceed(decodeHP(stateEnc));
    return reinterpret_cast<void*>(encodeHP(task));
}

// Evaluates `\v -> Task.succeed (f v)`, the continuation `taskCmdMapEvaluator` chains onto a command's
// Task, with `f` captured in `args[0]` and `v` in `args[1]`. Calls `f` with `v` and returns a Task that
// succeeds with the result.
static void* taskMapContinuationEvaluator(void* args[]) {
    uint64_t mapperEnc = reinterpret_cast<uint64_t>(args[0]);
    uint64_t valueEnc = reinterpret_cast<uint64_t>(args[1]);

    uint64_t mappedEnc =
        eco_apply_closure(HPtr::fromBits(mapperEnc), &valueEnc, 1).toBits();

    HPointer task = Scheduler::instance().taskSucceed(decodeHP(mappedEnc));
    return reinterpret_cast<void*>(encodeHP(task));
}

// Evaluates `cmdMap : (a -> b) -> MyCmd a -> MyCmd b` with the function in `args[0]` and the command in
// `args[1]`: given `Perform task`, returns a new `Perform (Task.map f task)`. A command for which
// `resolve` returns null is returned unchanged.
static void* taskCmdMapEvaluator(void* args[]) {
    uint64_t cmdEnc = reinterpret_cast<uint64_t>(args[1]);

    // Rooted across allocClosure, taskAndThen and custom, which may collect.
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

    HPointer continuation = allocClosure(taskMapContinuationEvaluator, 2);
    Elm::StackRootGuard contGuard(&continuation);
    if (void* clPtr = Allocator::instance().resolve(continuation)) {
        closureCapture(clPtr, boxed(mapper), true);
    }

    HPointer mappedTask =
        Scheduler::instance().taskAndThen(continuation, innerTask);
    Elm::StackRootGuard taskGuard(&mappedTask);

    std::vector<Unboxable> values(1);
    values[0].p = mappedTask;
    HPointer newCmd = custom(0, values, 0);  // tag 0 = Perform
    return reinterpret_cast<void*>(encodeHP(newCmd));
}

} // anonymous namespace

// ============================================================================
// Registration
// ============================================================================

extern "C" {

// The four closures have no captures; their arities are the evaluators' argument counts. They are held in
// unrooted locals across the later allocClosure calls, each of which may collect.
void eco_register_task_effect_manager() {
    HPointer initCl = allocClosure(taskInitEvaluator, 0);

    HPointer onEffectsCl = allocClosure(taskOnEffectsEvaluator, 4);

    HPointer onSelfMsgCl = allocClosure(taskOnSelfMsgEvaluator, 3);

    HPointer cmdMapCl = allocClosure(taskCmdMapEvaluator, 2);

    PlatformRuntime::ManagerInfo info;
    info.init = encodeHP(initCl);
    info.onEffects = encodeHP(onEffectsCl);
    info.onSelfMsg = encodeHP(onSelfMsgCl);
    info.cmdMap = encodeHP(cmdMapCl);
    info.subMap = encodeHP(listNil());  // No subscriptions, so no subMap.

    PlatformRuntime::instance().registerManager("Task", info);
}

} // extern "C"
