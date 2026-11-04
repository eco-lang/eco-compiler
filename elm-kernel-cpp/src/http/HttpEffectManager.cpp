//===- HttpEffectManager.cpp - Http effect manager implementation ----------===//
//
// The stock elm/http package declares an effect manager, `Http`, and implements
// it in Elm. A native program cannot run that Elm code, so this file supplies
// the same manager as five closures (`init`, `onEffects`, `onSelfMsg`, `cmdMap`
// and `subMap`) and registers them with `PlatformRuntime` under the name
// `"Http"`.
//
// The manager rests on the stock package's value shapes, which this file reads
// directly. A command (`MyCmd msg`) is `Cancel tracker`, constructor 0, or
// `Request r`, constructor 1, where `r` is the Request record. A subscription
// (`MySub msg`) is `MySub tracker toMsg`, constructor 0. A *tracker* is the
// String a request is named by for `Http.track` and `Http.cancel`. The
// manager's State is the current subscription list.
//
// What happens to a request belongs to `http/HttpExports`. Here, `onEffects`
// asks it for the Task of each `Request` and spawns that Task, and passes each
// `Cancel` to it, which withdraws the latest request issued with that tracker,
// if still in flight. A withdrawn request's result is discarded instead of delivered (*drop-delivery*).
// Progress comes back as a self-message `(tracker, progress)`, which
// `onSelfMsg` hands to the subscriptions with a matching tracker.
//
// `cmdMap` and `subMap` do what the stock Elm code does for `Cmd.map` and
// `Sub.map`: a Request's `expect` is wrapped so the response reaches the app
// through the tagger, and a subscription's `toMsg` is composed with it.
//
// All of this runs on the eco thread, the thread that runs the Elm scheduler.
// Every evaluator allocates or runs Elm code, either of which may collect, so
// any heap value held across such a call is rooted.
//
//===----------------------------------------------------------------------===//

#include "../KernelExports.h"
#include "../ExportHelpers.hpp"
#include "HttpRequestLayout.hpp"
#include "allocator/Heap.hpp"
#include "allocator/HeapHelpers.hpp"
#include "allocator/Allocator.hpp"
#include "allocator/RuntimeExports.h"
#include "allocator/StringOps.hpp"
#include "platform/Scheduler.hpp"
#include "platform/PlatformRuntime.hpp"
#include <string>
#include <vector>

using namespace Elm;
using namespace Elm::alloc;
using namespace Elm::Platform;
namespace Export = Elm::Kernel::Export;
using namespace Elm::Kernel::HttpRequestLayout;

/// Defined and documented in `HttpExports.cpp`.
extern "C" void Eco_Http_cancelTracker(uint64_t trackerEnc);
/// Defined and documented in `HttpExports.cpp`.
extern "C" uint64_t Eco_Http_toTaskForSpawn(uint64_t routerEnc, uint64_t resultToTaskEnc,
                                            uint64_t requestEnc, uint64_t trackerEnc);

namespace {

/// Returns the Elm String `hp` as UTF-8, or "" when `hp` is an embedded
/// constant (such as the empty String) or does not resolve to an object.
static std::string trackerToStd(HPointer hp) {
    // Checked before `resolve`, which asserts on a constant in validating
    // builds.
    if (hp.ptr_ind != 0) return "";
    void* ptr = Allocator::instance().resolve(hp);
    return Elm::StringOps::toStdString(ptr);
}

// ============================================================================
// Effect Manager Closures
// ============================================================================

/// Returns `Task.succeed []`: the manager's initial State, an empty
/// subscription list. Takes no arguments.
static void* httpInitEvaluator(void* args[]) {
    (void)args;
    HPointer nilState = listNil();
    HPointer task = Scheduler::instance().taskSucceed(nilState);
    return reinterpret_cast<void*>(Export::encode(task));
}

/// Sends `args[1]` to the app through router `args[0]`, and returns
/// `Task.succeed ()`.
///
/// This is the `resultToTask` a spawned request is built with, so `args[1]`
/// is the result of the request's expect, which is already a message of the
/// app's type: any `Cmd.map` tagger was applied to the expect by `cmdMap`.
static void* httpSuccessHandler(void* args[]) {
    uint64_t routerEnc = reinterpret_cast<uint64_t>(args[0]);
    uint64_t valueEnc = reinterpret_cast<uint64_t>(args[1]);

    HPointer router = Export::decode(routerEnc);
    HPointer value = Export::decode(valueEnc);

    PlatformRuntime::instance().sendToApp(router, value);

    return reinterpret_cast<void*>(Export::encode(
        Scheduler::instance().taskSucceed(unit())));
}

/// Returns `Task.succeed (mapper value)`, where `mapper` is `args[0]` and
/// `value` is `args[1]`. `cmdMap` uses it to map the result of a command that
/// is a Task.
static void* httpMapHandler(void* args[]) {
    uint64_t mapperEnc = reinterpret_cast<uint64_t>(args[0]);
    uint64_t valueEnc = reinterpret_cast<uint64_t>(args[1]);

    uint64_t mappedEnc = eco_apply_closure(HPtr::fromBits(mapperEnc), &valueEnc, 1).toBits();

    HPointer task = Scheduler::instance().taskSucceed(Export::decode(mappedEnc));
    return reinterpret_cast<void*>(Export::encode(task));
}

/// Carries out the commands in `args[1]` and returns `Task.succeed subs`,
/// making the subscription list `args[2]` the new State. `args[0]` is the
/// router; the previous State, `args[3]`, is not read.
///
/// A `Request` command's Task is built by `Eco_Http_toTaskForSpawn` and
/// spawned, so the request starts when the scheduler runs it, not here. Its
/// result is sent to the app through the router. A `Cancel` command withdraws
/// the latest request issued with its tracker, if still in flight. A command that is a Task rather than a
/// `MyCmd` value is spawned with its result sent to the app. Any other command
/// is ignored.
///
/// `args[2]` is read after the loop, whose allocations may collect, so the
/// caller must keep the `args` buffer rooted, as `eco_apply_closure` does.
static void* httpOnEffectsEvaluator(void* args[]) {
    auto& sched = Scheduler::instance();
    auto& allocator = Allocator::instance();

    // The loop body allocates (allocClosure, Eco_Http_toTaskForSpawn,
    // taskAndThen, rawSpawn), so `router` and the list position must be rooted
    // across it. The cursor keeps its spine node rooted and resolves it again
    // on each read and advance.
    HPointer router = Export::decode(reinterpret_cast<uint64_t>(args[0]));
    Elm::StackRootGuard outerRoots(&router);
    Elm::alloc::RootedListCursor cursor(
        Export::decode(reinterpret_cast<uint64_t>(args[1])));
    Elm::Unboxable cursorHead;
    u8 cursorKind;

    while (cursor.read(cursorHead, cursorKind)) {
        HPointer cmdHP = cursorHead.p;
        Elm::StackRootGuard iterRoots(&cmdHP);

        void* cmdPtr = alloc::resolveOrNull(cmdHP);
        if (cmdPtr) {
            Header* header = static_cast<Header*>(cmdPtr);
            u16 ctor = (header->tag == Tag_Custom)
                ? static_cast<u16>(static_cast<Custom*>(cmdPtr)->ctor)
                : 0xFFFF;
            if (header->tag == Tag_Custom && ctor == 1) {
                // Request r.
                HPointer req = static_cast<Custom*>(cmdPtr)->values[0].p;
                Elm::StackRootGuard reqRoot(&req);

                HPointer successCl = allocClosure(httpSuccessHandler, 2);
                Elm::StackRootGuard clRoot(&successCl);
                void* clPtr = allocator.resolve(successCl);
                closureCapture(clPtr, boxed(router), true);

                // The Request record's `tracker` is a `Maybe String`.
                // `Nothing` is an embedded constant, and `Just` a Custom whose
                // field 0 is the String. The word is read after the last
                // allocation above, and the call reads it before it allocates.
                uint64_t trackerEnc = 0;
                if (void* rp = allocator.resolve(req)) {
                    HPointer mt = static_cast<Record*>(rp)->values[REQ_TRACKER].p;
                    if (mt.ptr_ind == 0) {
                        if (void* mp = allocator.resolve(mt)) {
                            trackerEnc = Export::encode(static_cast<Custom*>(mp)->values[0].p);
                        }
                    }
                }
                uint64_t taskEnc = Eco_Http_toTaskForSpawn(
                    Export::encode(router), Export::encode(successCl), Export::encode(req), trackerEnc);
                HPointer taskHP = Export::decode(taskEnc);
                Elm::StackRootGuard taskRoot(&taskHP);
                sched.rawSpawn(taskHP);
            } else if (header->tag == Tag_Custom && ctor == 0) {
                // Cancel tracker. Neither reading the String nor the cancel
                // allocates, so nothing more needs rooting.
                HPointer tracker = static_cast<Custom*>(cmdPtr)->values[0].p;
                Eco_Http_cancelTracker(Export::encode(tracker));
            } else if (header->tag == Tag_Task) {
                HPointer successCl = allocClosure(httpSuccessHandler, 2);
                Elm::StackRootGuard clRoot(&successCl);
                void* clPtr = allocator.resolve(successCl);
                closureCapture(clPtr, boxed(router), true);
                HPointer wrappedTask = sched.taskAndThen(successCl, cmdHP);
                sched.rawSpawn(wrappedTask);
            }
        }

        cursor.advance();
    }

    uint64_t subsEnc = reinterpret_cast<uint64_t>(args[2]);
    HPointer task = sched.taskSucceed(Export::decode(subsEnc));
    return reinterpret_cast<void*>(Export::encode(task));
}

/// Delivers a progress report to the app and returns `Task.succeed state`,
/// leaving the State unchanged. `args[0]` is the router, `args[1]` the
/// self-message `(tracker, progress)` and `args[2]` the State, the
/// subscription list.
///
/// For each subscription `MySub subTracker toMsg` in the State whose tracker
/// has the same text as `tracker`, `toMsg progress` is sent to the app, in
/// list order. A self-message that does not resolve to an object delivers
/// nothing.
static void* httpOnSelfMsgEvaluator(void* args[]) {
    auto& sched = Scheduler::instance();
    auto& allocator = Allocator::instance();

    HPointer router  = Export::decode(reinterpret_cast<uint64_t>(args[0]));
    HPointer selfMsg = Export::decode(reinterpret_cast<uint64_t>(args[1]));
    HPointer state   = Export::decode(reinterpret_cast<uint64_t>(args[2]));
    Elm::StackRootGuard topRoots(&router, &selfMsg, &state);

    void* smPtr = alloc::resolveOrNull(selfMsg);
    if (smPtr) {
        Tuple2* sm = static_cast<Tuple2*>(smPtr);
        HPointer tracker  = sm->a.p;
        HPointer progress = sm->b.p;
        Elm::StackRootGuard msgRoots(&tracker, &progress);
        std::string wantTracker = trackerToStd(tracker);

        // `toMsg` and `sendToApp` run Elm code, which may collect; `router` (topRoots) and `progress`
        // (msgRoots) are already rooted across those calls.
        Elm::alloc::RootedListCursor cursor(state);
        Elm::Unboxable cursorHead;
        u8 cursorKind;
        while (cursor.read(cursorHead, cursorKind)) {
            HPointer subHP = cursorHead.p;
            Elm::StackRootGuard iterRoots(&subHP);

            void* subPtr = alloc::resolveOrNull(subHP);
            if (subPtr) {
                Custom* sub = static_cast<Custom*>(subPtr);
                HPointer subTracker = sub->values[0].p;
                HPointer toMsg = sub->values[1].p;
                if (trackerToStd(subTracker) == wantTracker) {
                    Elm::StackRootGuard sg(&toMsg);
                    HPointer msg = sched.callClosure1(toMsg, progress);
                    PlatformRuntime::instance().sendToApp(router, msg);
                }
            }
            cursor.advance();
        }
    }

    // `state` is rooted, so it holds the current address after the loop.
    HPointer task = sched.taskSucceed(state);
    return reinterpret_cast<void*>(Export::encode(task));
}

/// Returns the command `args[1]` with its message mapped by the function
/// `args[0]`, as stock elm/http's `cmdMap` does:
///
///     cmdMap func cmd =
///         case cmd of
///             Cancel tracker -> Cancel tracker
///             Request r -> Request { r | expect = Elm.Kernel.Http.mapExpect func r.expect }
///
/// Without this, the response would reach the app without the `Cmd.map`
/// tagger applied, as a value of the wrong message type. A `Request` gets a
/// new record that differs only in `expect`. A command that is a Task is
/// mapped with `taskAndThen` and `httpMapHandler`. Anything else, including a
/// `Cancel` and a `Request` whose field is not a record, is returned
/// unchanged.
static void* httpCmdMapEvaluator(void* args[]) {
    auto& allocator = Allocator::instance();

    // mapExpect, the new records and allocClosure / taskAndThen all allocate.
    HPointer mapper = Export::decode(reinterpret_cast<uint64_t>(args[0]));
    HPointer origCmd = Export::decode(reinterpret_cast<uint64_t>(args[1]));
    Elm::StackRootGuard guards(&mapper, &origCmd);

    void* cmdPtr = allocator.resolve(origCmd);

    Header* header = static_cast<Header*>(cmdPtr);
    if (header->tag == Tag_Custom) {
        Custom* cmd = static_cast<Custom*>(cmdPtr);
        if (cmd->ctor != 1) {
            return reinterpret_cast<void*>(Export::encode(origCmd));
        }
        HPointer reqHP = cmd->values[0].p;
        Elm::StackRootGuard reqRoot(&reqHP);
        void* reqPtr = allocator.resolve(reqHP);
        if (static_cast<Header*>(reqPtr)->tag != Tag_Record) {
            return reinterpret_cast<void*>(Export::encode(origCmd));
        }
        HPointer expect = static_cast<Record*>(reqPtr)->values[REQ_EXPECT].p;
        HPointer mappedExpect = Export::decode(Elm_Kernel_Http_mapExpect(
            HPtr::fromBits(Export::encode(mapper)), HPtr::fromBits(Export::encode(expect))).toBits());
        Elm::StackRootGuard expectRoot(&mappedExpect);

        // mapExpect allocated, so the record is resolved again.
        Record* req = static_cast<Record*>(allocator.resolve(reqHP));
        const u32 n = req->header.size;
        std::vector<Unboxable> fields(req->values, req->values + n);
        fields[REQ_EXPECT].p = mappedExpect;
        HPointer newReq = record(fields, req->unboxed);
        Elm::StackRootGuard newReqRoot(&newReq);

        std::vector<Unboxable> wrap(1);
        wrap[0].p = newReq;
        HPointer newCmd = custom(1, wrap, 0);
        return reinterpret_cast<void*>(Export::encode(newCmd));
    }
    if (header->tag != Tag_Task) {
        return reinterpret_cast<void*>(Export::encode(origCmd));
    }

    HPointer mapCl = allocClosure(httpMapHandler, 2);
    Elm::StackRootGuard mapClRoot(&mapCl);
    void* clPtr = allocator.resolve(mapCl);
    closureCapture(clPtr, boxed(mapper), true);

    HPointer mappedTask = Scheduler::instance().taskAndThen(mapCl, origCmd);
    return reinterpret_cast<void*>(Export::encode(mappedTask));
}

/// Returns `func (toMsg progress)`, where `func` is `args[0]`, `toMsg` is
/// `args[1]` and `progress` is `args[2]`. It is the `toMsg >> func` that
/// `subMap` builds, with the first two captured.
static void* httpSubComposeEvaluator(void* args[]) {
    HPointer func = Export::decode(reinterpret_cast<uint64_t>(args[0]));
    Elm::StackRootGuard funcRoot(&func);
    uint64_t progressEnc = reinterpret_cast<uint64_t>(args[2]);
    uint64_t msgEnc = eco_apply_closure(HPtr::fromBits(reinterpret_cast<uint64_t>(args[1])),
                                        &progressEnc, 1).toBits();
    HPtr res = eco_apply_closure(HPtr::fromBits(Export::encode(func)), &msgEnc, 1);
    return reinterpret_cast<void*>(res.toBits());
}

/// Returns the subscription `args[1]` with its message mapped by the function
/// `args[0]`, as stock elm/http's `subMap` does:
///
///     subMap func (MySub tracker toMsg) = MySub tracker (toMsg >> func)
///
/// Without this, the `Sub.map` taggers would be applied to the `MySub` value
/// itself, and progress under `Sub.map` would not reach the app. A
/// subscription that is not a Custom is returned unchanged.
static void* httpSubMapEvaluator(void* args[]) {
    auto& allocator = Allocator::instance();
    HPointer func = Export::decode(reinterpret_cast<uint64_t>(args[0]));
    HPointer sub = Export::decode(reinterpret_cast<uint64_t>(args[1]));
    Elm::StackRootGuard guards(&func, &sub);

    void* subPtr = allocator.resolve(sub);
    if (static_cast<Header*>(subPtr)->tag != Tag_Custom) {
        return reinterpret_cast<void*>(Export::encode(sub));
    }
    HPointer tracker = static_cast<Custom*>(subPtr)->values[0].p;
    HPointer toMsg = static_cast<Custom*>(subPtr)->values[1].p;
    Elm::StackRootGuard fieldRoots(&tracker, &toMsg);

    HPointer composed = allocClosure(httpSubComposeEvaluator, 3);
    Elm::StackRootGuard composedRoot(&composed);
    if (void* clPtr = allocator.resolve(composed)) {
        closureCapture(clPtr, boxed(func), true);
        closureCapture(clPtr, boxed(toMsg), true);
    }
    std::vector<Unboxable> fields(2);
    fields[0].p = tracker;
    fields[1].p = composed;
    HPointer mapped = custom(0, fields, 0);
    return reinterpret_cast<void*>(Export::encode(mapped));
}

} // anonymous namespace

// ============================================================================
// Registration
// ============================================================================

extern "C" {

/// Registers the `Http` effect manager's closures with `PlatformRuntime`,
/// replacing any manager already registered under that name.
///
/// It allocates on the heap, so it must run on the eco thread once the
/// thread's heap exists. It is called by `eco_register_all_effect_managers`.
void eco_register_http_effect_manager() {
    // Each closure stays rooted across the later allocations.
    HPointer initCl = allocClosure(httpInitEvaluator, 0);
    Elm::StackRootGuard initRoot(&initCl);

    HPointer onEffectsCl = allocClosure(httpOnEffectsEvaluator, 4);
    Elm::StackRootGuard onEffectsRoot(&onEffectsCl);
    HPointer onSelfMsgCl = allocClosure(httpOnSelfMsgEvaluator, 3);
    Elm::StackRootGuard onSelfMsgRoot(&onSelfMsgCl);
    HPointer cmdMapCl = allocClosure(httpCmdMapEvaluator, 2);
    Elm::StackRootGuard cmdMapRoot(&cmdMapCl);

    HPointer subMapCl = allocClosure(httpSubMapEvaluator, 2);
    Elm::StackRootGuard subMapRoot(&subMapCl);

    PlatformRuntime::ManagerInfo info;
    info.init = Export::encode(initCl);
    info.onEffects = Export::encode(onEffectsCl);
    info.onSelfMsg = Export::encode(onSelfMsgCl);
    info.cmdMap = Export::encode(cmdMapCl);
    info.subMap = Export::encode(subMapCl);

    PlatformRuntime::instance().registerManager("Http", info);
}

} // extern "C"
