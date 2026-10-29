#include "PlatformRuntime.hpp"
#include "Scheduler.hpp"
#include "allocator/Allocator.hpp"
#include "allocator/HeapHelpers.hpp"
#include "allocator/RuntimeExports.h"
#include "allocator/StringOps.hpp"
#include <cstring>
#include <cstdio>
#include <cstdlib>
#include <cassert>

using namespace Elm;
using namespace Elm::alloc;

// Json kernel entry point (elm-kernel-cpp). Declared here rather than
// included, so the runtime depends on the kernel only at link time.
extern "C" HPtr Elm_Kernel_Json_runOnString(HPtr decoder, HPtr jsonString);

namespace Elm::Platform {

// Returns the 64-bit word of `h`, the form every heap value is stored in here.
static inline uint64_t encodeHP(HPointer h) {
    union { HPointer hp; uint64_t val; } u;
    u.hp = h;
    return u.val;
}

// Returns the HPointer whose word is `val`.
static inline HPointer decodeHP(uint64_t val) {
    union { HPointer hp; uint64_t val; } u;
    u.val = val;
    return u.hp;
}

// Returns whether `h` is an embedded constant (its `ptr_ind` bit is set).
static inline bool hpIsConstant(HPointer h) {
    return h.ptr_ind != 0;
}

// Returns the address of the object `h` refers to, or null for an embedded
// constant.
static inline void* resolveHP(HPointer h) {
    if (hpIsConstant(h)) return nullptr;
    return Allocator::instance().resolve(h);
}

// Returns the String at `ptr`, in any of its forms, as UTF-8.
static std::string elmStringToStd(void* ptr) {
    return Elm::StringOps::toStdString(ptr);
}

// ============================================================================
// applyTaggers-as-closure support
// ============================================================================
//
// gatherEffects hands the Fx_Map functions collected above a leaf to the
// owning manager's cmdMap/subMap as one closure:
//
//     effect = A2(map, applyTaggers, value)
//
// The map closure decides how the functions apply to the leaf value; a
// manager may apply them, keep them inside its value, or drop them.

// Evaluates an applyTaggers closure: args[0] is the captured taggers list
// and args[1] the value; returns `applyTaggers(taggers, value)`, encoded.
static void* applyTaggersEvaluator(void* args[]) {
    HPointer taggers = decodeHP(reinterpret_cast<uint64_t>(args[0]));
    HPointer value = decodeHP(reinterpret_cast<uint64_t>(args[1]));
    HPointer result =
        PlatformRuntime::instance().applyTaggers(taggers, value);
    return reinterpret_cast<void*>(encodeHP(result));
}

// Returns a new closure of one argument that applies `taggers`, innermost
// first, to it. gatherEffects calls this only for a non-empty list. The
// result is unrooted; the caller must root it before allocating again.
static HPointer makeApplyTaggersClosure(HPointer taggers) {
    Elm::StackRootGuard guard(&taggers);
    HPointer cl = allocClosure(applyTaggersEvaluator, 2);
    if (void* clPtr = Allocator::instance().resolve(cl)) {
        closureCapture(clPtr, boxed(taggers), true);
    }
    return cl;
}

// ============================================================================
// Singleton
// ============================================================================

PlatformRuntime& PlatformRuntime::instance() {
    static PlatformRuntime* runtime = new PlatformRuntime();
    return *runtime;
}

PlatformRuntime::PlatformRuntime() {
    // Register external root scanner so the GC can trace our state.
    // Use the slow form: the constructor may run before the calling thread
    // has been registered with `initThread()`.
    Allocator::instance().getRootSetSlow().addExternalRootScanner(
        [this](RootSet::EvacuateFn evacuate) {
            // sendToApp closure
            if (sendToAppClosure_ != 0)
                evacuate(sendToAppClosure_);

            // Flags decoder
            if (flagsDecoder_ != 0)
                evacuate(flagsDecoder_);

            // Model storage (also a value root, but double-evacuating is safe)
            if (modelStorage_ != 0)
                evacuate(modelStorage_);

            // Per-manager registered closures (init/onEffects/onSelfMsg/
            // cmdMap/subMap). Stored as encoded HPointers so they can be
            // rewritten here across GC.
            for (auto& [home, info] : managers_) {
                evacuate(info.init);
                evacuate(info.onEffects);
                evacuate(info.onSelfMsg);
                evacuate(info.cmdMap);
                evacuate(info.subMap);
            }

            // Per-manager state: selfProcess, router, and current state
            for (auto& [home, ms] : managerStates_) {
                evacuate(ms.selfProcess);
                evacuate(ms.router);
                evacuate(ms.state);
            }

            // Effects queue
            for (auto& batch : effectsQueue_) {
                evacuate(batch.cmdBag);
                evacuate(batch.subBag);
            }

            // Currently-dispatching batch + per-manager scratch, live only
            // while dispatchEffects is on the stack. Keeping them here
            // avoids having to root every intermediate HPointer produced
            // by gatherEffects or held across callClosure4 / drain().
            if (dispatchActive_) {
                evacuate(activeBatch_.cmdBag);
                evacuate(activeBatch_.subBag);
                for (auto& [home, per] : effectsScratch_) {
                    for (auto& enc : per.cmdHPs) evacuate(enc);
                    for (auto& enc : per.subHPs) evacuate(enc);
                }
            }
        }, "platform-runtime");
}

// ============================================================================
// Manager Registry
// ============================================================================

void PlatformRuntime::registerManager(const std::string& home, const ManagerInfo& info) {
    managers_[home] = info;
}

// ============================================================================
// Setup Effects
// ============================================================================

HPointer PlatformRuntime::setupEffects(HPointer sendToAppClosure) {
    sendToAppClosure_ = encodeHP(sendToAppClosure);

    auto& sched = Scheduler::instance();

    for (auto& [home, info] : managers_) {
        // Create the manager's self-process
        // The self-process runs a Receive loop that handles onSelfMsg.
        // sendToAppClosure and selfProc must survive each subsequent
        // allocation (taskReceive, rawSpawn, custom) — any of those can
        // trigger a GC that moves the values stored in our local copies.
        HPointer recvCallback = decodeHP(info.onSelfMsg);
        Elm::StackRootGuard cb_guard(&recvCallback, &sendToAppClosure);
        HPointer selfProc = sched.rawSpawn(
            sched.taskReceive(recvCallback));
        Elm::StackRootGuard self_guard(&selfProc);

        // The self-process id is stable across steps (Process is immutable;
        // each step allocates a new value with the same id). sendToSelf and the
        // dedicated self-process step both resolve the live version by this id.
        u64 selfProcId = static_cast<Process*>(resolveHP(selfProc))->id;

        // Create router: Custom with ctor=CTOR_Router.
        // field[0] = sendToApp closure (boxed, kind 00)
        // field[1] = self-process id  (unboxed Int, kind 01), so that
        //   sendToSelf finds the latest version through latestProcessById.
        //   In this file only sendToApp (field 0) and sendToSelf (field 1)
        //   read it. Slot 1 kind 01 lives in bits [2,3] → mask 0b0100.
        std::vector<Unboxable> routerFields(2);
        routerFields[0] = boxed(sendToAppClosure);
        routerFields[1] = unboxedInt(static_cast<i64>(selfProcId));
        HPointer router = custom(CTOR_Router, routerFields, 0x4);
        // Root router: it is held across the init-thunk force / rawSpawn /
        // drain GC points below and only consumed at encodeHP() at the end
        // of this iteration (mirrors self_guard for selfProc).
        Elm::StackRootGuard router_guard(&router);

        // Register the self-process message handler. When this process
        // receives a mailbox message, the scheduler's dedicated step invokes
        // this handler with the message, which runs onSelfMsg + threads state.
        std::string homeCopy = home;
        sched.registerSelfProcess(selfProcId,
            [this, homeCopy](HPointer msg) { handleSelfMsg(homeCopy, msg); });

        // Run the init task to get initial manager state.
        //
        // A manager may register `init` as a 0-arg closure that *produces*
        // the init Task, not as a Task. Detect that case and call the
        // closure first; handed to rawSpawn, a Closure would be read as a
        // Task and the init effect silently dropped.
        HPointer initTask = decodeHP(info.init);
        HPointer initialState = listNil();  // fallback
        if (!alloc::isNil(initTask) && !hpIsConstant(initTask)) {
            void* initPtr = resolveHP(initTask);
            if (initPtr && static_cast<Header*>(initPtr)->tag == Tag_Closure) {
                // eco_apply_closure with no arguments returns the closure
                // unchanged, so it cannot force a 0-arity thunk.
                // eco_closure_call_saturated calls the evaluator even with
                // no arguments.
                HPtr closureHPtr = HPtr::fromBits(encodeHP(initTask));
                HPtr result = eco_closure_call_saturated(closureHPtr, nullptr,
                                                         0, nullptr);
                initTask = decodeHP(result.toBits());
            }
        }

        if (!alloc::isNil(initTask) && !hpIsConstant(initTask)) {
            // Spawn a process to run the init task.
            HPointer initProc = sched.rawSpawn(initTask);
            // Capture the id BEFORE drain — Process is logically immutable so
            // `initProc` becomes stale as soon as stepProcess produces new
            // values. The id is stable; the scheduler hands the finished
            // process over by it (a finished process leaves the registry).
            u64 procId = static_cast<Process*>(resolveHP(initProc))->id;
            sched.keepResultOnFinish(procId);
            sched.drain();

            HPointer latestProc = sched.takeFinishedProcess(procId);
            void* procPtr = resolveHP(latestProc);
            if (procPtr) {
                Process* proc = static_cast<Process*>(procPtr);
                void* rootPtr = resolveHP(proc->root);
                if (rootPtr) {
                    Task* rootTask = static_cast<Task*>(rootPtr);
                    // The spawned init process must have reduced to a Task.
                    // If `proc->root` is anything else (e.g. an unforced
                    // init thunk Closure), reading `value.p` below would
                    // mis-decode a non-heap word (the closure's evaluator
                    // code pointer) as the initial state. Guard the tag
                    // before trusting the Task layout.
                    assert(rootTask->header.tag == Tag_Task
                           && "effect-manager init process root must be a Task");
                    if (rootTask->ctor == Task_Succeed) {
                        // Effect-manager init state must be a boxed HPointer
                        // (asserted).
                        assert((rootTask->header.unboxed & 0x3) == 0
                               && "effect-manager init state must be boxed");
                        initialState = rootTask->value.p;
                    }
                }
            }
        }

        ManagerState ms;
        ms.selfProcess = encodeHP(selfProc);
        ms.router = encodeHP(router);
        ms.state = encodeHP(initialState);
        managerStates_[home] = ms;
    }

    // Ports need nothing here: each port is registered as an effect manager
    // and was set up by the loop above like any other manager.
    return emptyRecord();
}

// ============================================================================
// Effect Dispatch
// ============================================================================

void PlatformRuntime::enqueueEffects(HPointer cmdBag, HPointer subBag) {
    effectsQueue_.push_back({encodeHP(cmdBag), encodeHP(subBag)});

    if (effectsActive_) return;
    effectsActive_ = true;

    while (!effectsQueue_.empty()) {
        // Move the front batch into activeBatch_ *before* erasing it from
        // the queue, so at least one GC-rooted copy of the bag HPointers
        // exists at every point during dispatch. dispatchActive_ tells the
        // external root scanner to include activeBatch_ + effectsScratch_.
        activeBatch_ = effectsQueue_.front();
        effectsQueue_.erase(effectsQueue_.begin());

        dispatchActive_ = true;
        dispatchEffects();
        dispatchActive_ = false;

        effectsScratch_.clear();
        activeBatch_ = FxBatch{0, 0};
    }

    effectsActive_ = false;
}

// Returns the Elm list of the encoded HPointers in `encoded`, in order. A GC
// point. listFromPointers roots its own copy; `encoded` is expected to be
// scanned too (effectsScratch_ during a dispatch), so both stay current.
static HPointer listFromEncoded(const std::vector<uint64_t>& encoded) {
    std::vector<HPointer> decoded;
    decoded.reserve(encoded.size());
    for (uint64_t e : encoded) decoded.push_back(decodeHP(e));
    return alloc::listFromPointers(decoded);
}

void PlatformRuntime::dispatchEffects() {
    if (managers_.empty()) return;

    // Each bag is decoded right before its gather: gathering the cmd bag
    // calls the managers' cmdMap closures, which may GC, so a
    // subBag decoded up front would be stale by the second gather.
    // activeBatch_ (scanned while dispatchActive_) holds the current words.

    // Initialize empty entries for every registered manager so gatherEffects
    // can find the slot for any home it encounters.
    effectsScratch_.clear();
    for (auto& [home, _] : managers_) {
        effectsScratch_[home];
    }

    HPointer nilTaggers = listNil();
    gatherEffects(true,  decodeHP(activeBatch_.cmdBag), effectsScratch_, nilTaggers);
    gatherEffects(false, decodeHP(activeBatch_.subBag), effectsScratch_, nilTaggers);

    auto& sched = Scheduler::instance();
    for (auto& [home, per] : effectsScratch_) {
        auto msIt = managerStates_.find(home);
        if (msIt == managerStates_.end()) continue;
        auto miIt = managers_.find(home);
        if (miIt == managers_.end()) continue;

        HPointer onEffectsFn = decodeHP(miIt->second.onEffects);
        if (alloc::isNil(onEffectsFn) || hpIsConstant(onEffectsFn)) continue;

        HPointer cmdList = listFromEncoded(per.cmdHPs);
        // Root cmdList across the subList build: listFromEncoded conses (a
        // GC point) and cmdList's fresh spine is reachable only from this
        // local until call_guard takes over below.
        Elm::StackRootGuard cmd_guard(&cmdList);
        HPointer subList = listFromEncoded(per.subHPs);

        // Re-read router / state / fn from the rooted maps after list
        // construction: any GC inside listFromEncoded could have moved
        // them, but managers_/managerStates_ are both scanned.
        ManagerState& ms = msIt->second;
        HPointer router = decodeHP(ms.router);
        HPointer state  = decodeHP(ms.state);
        HPointer fn     = decodeHP(miIt->second.onEffects);

        // Pin all four arguments to callClosure4 across the call: although
        // callClosure4 encodes its args internally, the caller's locals
        // (router, cmdList, subList, state, fn) live in this stack frame and
        // would otherwise be invisible to the GC during the closure body.
        Elm::StackRootGuard call_guard({&router, &cmdList, &subList, &state, &fn});
        HPointer newStateTask = Scheduler::callClosure4(
            fn, router, cmdList, subList, state);

        // Run the returned Task to get the new state.
        HPointer effectProc = sched.rawSpawn(newStateTask);
        // Capture the id BEFORE drain — Process is logically immutable so
        // effectProc becomes stale as soon as stepProcess produces new
        // values. The id is stable; the scheduler hands the finished
        // process over by it (a finished process leaves the registry).
        u64 procId = static_cast<Process*>(resolveHP(effectProc))->id;
        sched.keepResultOnFinish(procId);
        sched.drain();

        HPointer latestProc = sched.takeFinishedProcess(procId);
        void* procPtr = resolveHP(latestProc);
        if (procPtr) {
            Process* proc = static_cast<Process*>(procPtr);
            void* rootPtr = resolveHP(proc->root);
            if (rootPtr) {
                Task* rootTask = static_cast<Task*>(rootPtr);
                assert(rootTask->header.tag == Tag_Task
                       && "effect-manager onEffects process root must be a Task");
                if (rootTask->ctor == Task_Succeed) {
                    assert((rootTask->header.unboxed & 0x3) == 0
                           && "effect-manager state must be boxed");
                    ms.state = encodeHP(rootTask->value.p);
                }
            }
        }
    }
}

void PlatformRuntime::gatherEffects(
    bool isCmd,
    HPointer bag,
    std::unordered_map<std::string, PerManagerEffects>& effects,
    HPointer taggers)
{
    if (alloc::isNil(bag) || hpIsConstant(bag)) return;

    void* bagPtr = resolveHP(bag);
    if (!bagPtr) return;

    Custom* custom = static_cast<Custom*>(bagPtr);
    u16 ctor = static_cast<u16>(custom->ctor);

    if (ctor == Fx_Leaf) {
        // Leaf: values[0] = home (ElmString), values[1] = value
        HPointer homeHP = custom->values[0].p;
        HPointer value = custom->values[1].p;

        // Resolve and extract the home string
        void* homePtr = resolveHP(homeHP);
        if (!homePtr) return;
        std::string home = elmStringToStd(homePtr);

        // If manager not registered, silently drop the effect.
        auto it = effects.find(home);
        if (it == effects.end()) return;

        HPointer effect;
        if (alloc::isNil(taggers)) {
            // No Fx_Map above the leaf: the value passes through unchanged,
            // without calling the manager's map closure.
            effect = value;
        } else {
            // Hand the tagger chain to the manager's cmdMap/subMap as a
            // closure and let the map decide how it applies. A manager
            // whose map is Empty gets the functions applied to the value
            // directly.
            HPointer mapFn = listNil();
            {
                auto miIt = managers_.find(home);
                if (miIt != managers_.end()) {
                    mapFn = decodeHP(isCmd ? miIt->second.cmdMap
                                           : miIt->second.subMap);
                }
            }

            if (alloc::isNil(mapFn) || hpIsConstant(mapFn)) {
                effect = applyTaggers(taggers, value);
            } else {
                // Root value + mapFn + the taggers chain across the closure
                // allocation and the map call (both may GC). `custom` is
                // stale past this point; all leaf fields were snapshot above.
                HPointer taggersLocal = taggers;
                Elm::StackRootGuard guard({ &mapFn, &value, &taggersLocal });
                HPointer applyFn = makeApplyTaggersClosure(taggersLocal);
                Elm::StackRootGuard applyGuard(&applyFn);
                effect = Scheduler::callClosure2(mapFn, applyFn, value);
            }
        }

        // Add to the appropriate effects list (cmd or sub). The iterator
        // stays valid across the map call: closures may GC but never
        // mutate the effects map, and encoded entries are evacuated by
        // the external root scanner while dispatchActive_ is set.
        if (isCmd) {
            it->second.cmdHPs.push_back(encodeHP(effect));
        } else {
            it->second.subHPs.push_back(encodeHP(effect));
        }
    }
    else if (ctor == Fx_Node) {
        // Node: values[0] = list of bags. The recursive gather can allocate
        // (Fx_Map cons, applyTaggers closures, manager map evaluators) and
        // therefore GC: snapshot the tail BEFORE recursing and keep the
        // loop cursor + taggers chain rooted so iteration 2+ reads
        // GC-current values (`cell` is stale after any allocation).
        // Hybrid spines: the batch list is user Elm (e.g. Cmd.batch of a
        // mapped list) and may be a chunk spine. RootedListCursor keeps the
        // spine node rooted across the recursive gatherEffects GC points.
        HPointer taggersLocal = taggers;
        Elm::StackRootGuard loopGuard(&taggersLocal);
        Elm::alloc::RootedListCursor cursor(custom->values[0].p);
        Elm::Unboxable bagHead;
        u8 bagKind;
        while (cursor.read(bagHead, bagKind)) {
            gatherEffects(isCmd, bagHead.p, effects, taggersLocal);
            cursor.advance();
        }
    }
    else if (ctor == Fx_Map) {
        // Map: values[0] = tagger function, values[1] = inner bag.
        // Root both across the cons allocation, and the new chain across
        // the recursion, which takes it by value and cannot update this
        // frame's copy.
        HPointer tagger = custom->values[0].p;
        HPointer innerBag = custom->values[1].p;
        Elm::StackRootGuard guard(&tagger, &innerBag);
        HPointer newTaggers = cons(boxed(tagger), taggers, true);
        Elm::StackRootGuard taggersGuard(&newTaggers);
        gatherEffects(isCmd, innerBag, effects, newTaggers);
    }
}

HPointer PlatformRuntime::applyTaggers(HPointer taggers, HPointer value) {
    HPointer result = value;
    // result, and the cursor over the list, must survive each callClosure1,
    // which runs Elm code that may GC.
    Elm::StackRootGuard guard(&result);
    Elm::alloc::RootedListCursor cursor(taggers);
    Elm::Unboxable tagHead;
    u8 tagKind;
    while (cursor.read(tagHead, tagKind)) {
        result = Scheduler::callClosure1(tagHead.p, result);
        cursor.advance();
    }
    return result;
}

// ============================================================================
// Routing
// ============================================================================

void PlatformRuntime::sendToApp(HPointer router, HPointer msg) {
    // Extract sendToApp closure from router
    void* routerPtr = resolveHP(router);
    if (!routerPtr) return;

    Custom* routerObj = static_cast<Custom*>(routerPtr);
    HPointer sendToAppFn = routerObj->values[0].p;

    // Call sendToApp(msg)
    Scheduler::callClosure1(sendToAppFn, msg);
}

void PlatformRuntime::deliverToApp(HPointer msg) {
    if (sendToAppClosure_ == 0) return;
    HPointer sendToAppFn = decodeHP(sendToAppClosure_);
    Scheduler::callClosure1(sendToAppFn, msg);
}

HPointer PlatformRuntime::sendToSelf(HPointer router, HPointer msg) {
    // Router field 1 is the self-process id (unboxed Int); the process is
    // looked up by it because every step makes a new Process version.
    void* routerPtr = resolveHP(router);
    if (!routerPtr) return Scheduler::instance().taskSucceed(unit());

    Custom* routerObj = static_cast<Custom*>(routerPtr);
    u64 selfProcId = static_cast<u64>(routerObj->values[1].i);

    auto& sched = Scheduler::instance();
    HPointer selfProcess = sched.latestProcessById(selfProcId);
    if (!alloc::isNil(selfProcess)) {
        // rawSend allocates (mailbox cons); root msg across it.
        Elm::StackRootGuard guard(&msg);
        sched.rawSend(selfProcess, msg);
    }

    return sched.taskSucceed(unit());
}

// ============================================================================
// Self-message handling (effect-manager onSelfMsg loop)
// ============================================================================

void PlatformRuntime::handleSelfMsg(const std::string& home, HPointer msg) {
    auto msIt = managerStates_.find(home);
    if (msIt == managerStates_.end()) return;
    auto miIt = managers_.find(home);
    if (miIt == managers_.end()) return;

    HPointer onSelfMsgFn = decodeHP(miIt->second.onSelfMsg);
    if (alloc::isNil(onSelfMsgFn) || hpIsConstant(onSelfMsgFn)) return;

    // Snapshot router / state / fn from the rooted maps before the call.
    ManagerState& ms = msIt->second;
    HPointer router = decodeHP(ms.router);
    HPointer state  = decodeHP(ms.state);
    HPointer fn     = onSelfMsgFn;

    // onSelfMsg(router, selfMsg, state) -> Task Never State. Pin all four
    // arguments across the closure call: callClosure3 encodes them internally,
    // but the caller's locals must remain GC-visible during the closure body.
    Elm::StackRootGuard call_guard({&msg, &router, &state, &fn});
    HPointer newStateTask = Scheduler::callClosure3(fn, router, msg, state);

    // Run the returned Task to get the new state (mirror dispatchEffects).
    auto& sched = Scheduler::instance();
    HPointer effectProc = sched.rawSpawn(newStateTask);
    u64 procId = static_cast<Process*>(resolveHP(effectProc))->id;
    sched.keepResultOnFinish(procId);
    sched.drain();

    HPointer latestProc = sched.takeFinishedProcess(procId);
    void* procPtr = resolveHP(latestProc);
    if (procPtr) {
        Process* proc = static_cast<Process*>(procPtr);
        void* rootPtr = resolveHP(proc->root);
        if (rootPtr) {
            Task* rootTask = static_cast<Task*>(rootPtr);
            assert(rootTask->header.tag == Tag_Task
                   && "effect-manager onSelfMsg process root must be a Task");
            if (rootTask->ctor == Task_Succeed) {
                assert((rootTask->header.unboxed & 0x3) == 0
                       && "effect-manager state must be boxed");
                HPointer newState = rootTask->value.p;
                // Only write back if onSelfMsg actually changed the state.
                // sendToApp inside onSelfMsg runs the app's update cycle
                // synchronously, which can re-enter onEffects and update
                // managerStates_[home].state already; writing back an onSelfMsg
                // result equal to the `state` it was given would clobber that.
                // `state` is rooted by call_guard, so its bits are GC-current.
                if (encodeHP(newState) != encodeHP(state)) {
                    auto writeIt = managerStates_.find(home);
                    if (writeIt != managerStates_.end()) {
                        writeIt->second.state = encodeHP(newState);
                    }
                }
            }
        }
    }
}

// ============================================================================
// Platform.worker Initialization
// ============================================================================

// Evaluates the worker's sendToApp closure, which runs one update cycle:
// `update msg model` gives the new model and a command, the model is stored,
// and the command is enqueued with `subscriptions newModel`. rawArgs[0] is
// the captured impl record and rawArgs[1] the message, both encoded. Returns
// `()`, encoded; if impl or update's result is not a heap object it returns
// at once, with the model unchanged.
static void* workerSendToAppEvaluator(void* rawArgs[]) {
    uint64_t implEnc = reinterpret_cast<uint64_t>(rawArgs[0]);
    uint64_t msgEnc = reinterpret_cast<uint64_t>(rawArgs[1]);

    HPointer impl = decodeHP(implEnc);
    HPointer msg = decodeHP(msgEnc);

    // Access model storage via the PlatformRuntime singleton
    auto& runtime = PlatformRuntime::instance();
    HPointer currentModel = decodeHP(runtime.getModelStorage());

    // Access impl fields. impl is a Record with fields in canonical order:
    // For Platform.worker's impl: { init, subscriptions, update }
    // Canonical alphabetical order: init=0, subscriptions=1, update=2
    void* implPtr = resolveHP(impl);
    if (!implPtr) return reinterpret_cast<void*>(encodeHP(Elm::alloc::unit()));
    Record* implRec = static_cast<Record*>(implPtr);

    HPointer updateFn = implRec->values[2].p;       // update
    HPointer subscriptionsFn = implRec->values[1].p; // subscriptions

    // subscriptionsFn must survive the update closure (callClosure2 below);
    // newCmd and newModel must survive the subscriptions closure call.
    Elm::StackRootGuard subs_guard(&subscriptionsFn);

    // Call update(msg, model) -> (newModel, cmd)
    HPointer pair = Scheduler::callClosure2(updateFn, msg, currentModel);

    // Extract tuple fields
    void* pairPtr = resolveHP(pair);
    if (!pairPtr) return reinterpret_cast<void*>(encodeHP(Elm::alloc::unit()));
    // Same unboxed-slot hazard as `initWorker`'s init tuple — see the comment
    // there. `update : Msg -> Model -> ( Model, Cmd Msg )` returns the model in
    // slot a, and for an unboxed model type that slot is a raw scalar.
    Tuple2* tuple = static_cast<Tuple2*>(pairPtr);
    const u32 updModelKind = tuple->header.unboxed & 0x3;
    const u32 updCmdKind = (tuple->header.unboxed >> 2) & 0x3;
    Elm::Unboxable updModelSlot = tuple->a;
    HPointer newModel = Elm::alloc::boxElement(updModelSlot, updModelKind);

    pairPtr = resolveHP(pair);
    if (!pairPtr) return reinterpret_cast<void*>(encodeHP(Elm::alloc::unit()));
    tuple = static_cast<Tuple2*>(pairPtr);
    HPointer newCmd = Elm::alloc::boxElement(tuple->b, updCmdKind);

    // Update model storage
    runtime.setModelStorage(encodeHP(newModel));

    // Get new subscriptions. newCmd survives across this call.
    Elm::StackRootGuard cmd_guard(&newCmd);
    HPointer newSubs = Scheduler::callClosure1(subscriptionsFn, newModel);

    // Enqueue effects
    runtime.enqueueEffects(newCmd, newSubs);

    return reinterpret_cast<void*>(encodeHP(Elm::alloc::unit()));
}

void PlatformRuntime::setFlagsDecoder(HPointer decoder) {
    flagsDecoder_ = encodeHP(decoder);
}

// Every HPointer local is rooted across the parse and decode allocations.
HPointer PlatformRuntime::decodeFlags(const std::string& json) {
    HPointer decoder = decodeHP(flagsDecoder_);
    HPointer flags = listNil();
    Elm::StackRootGuard guard(&decoder, &flags);

    HPointer jsonStr = allocStringFromUTF8(json);
    Elm::StackRootGuard strGuard(&jsonStr);
    HPtr result = Elm_Kernel_Json_runOnString(
        HPtr::fromBits(encodeHP(decoder)),
        HPtr::fromBits(encodeHP(jsonStr)));
    HPointer resultHP = decodeHP(result.toBits());

    // Result customs from the Json kernel: ctor 0 = Ok, 1 = Err.
    void* ptr = resolveHP(resultHP);
    if (!ptr || static_cast<Custom*>(ptr)->ctor != 0) {
        std::fprintf(stderr,
                     "eco: problem with the flags given to this program: "
                     "%s\n",
                     json.c_str());
        std::fflush(stderr);
        std::abort();
    }
    // The Json kernel rewraps the escaping Ok so a primitive payload sits
    // UNBOXED in the slot; the flags value continues to `init` through a
    // boxed closure call, so re-box per the slot's 2-bit kind.
    {
        Custom* ok = static_cast<Custom*>(ptr);
        const u32 flagsKind = ok->unboxed & 0x3;
        flags = Elm::alloc::boxElement(ok->values[0], flagsKind);
    }
    return flags;
}

HPointer PlatformRuntime::initWorker(HPointer impl) {
    // With a decoder, absent flags decode as `null`; without one, init gets
    // `()`.
    HPointer flags = unit();
    // Root `impl` across the decode, which allocates. The caller's
    // statepoint relocation does not update this frame's by-value copy.
    Elm::StackRootGuard implGuard(&impl);
    if (flagsDecoder_ != 0) {
        flags = decodeFlags(hasPendingFlagsJson_ ? pendingFlagsJson_
                                                 : std::string("null"));
    } else if (hasPendingFlagsJson_ && pendingFlagsJson_ != "null") {
        // Flags were given but the program registered no decoder. Fail
        // rather than hand init `()`. A bare `null` is accepted as no flags.
        std::fprintf(stderr,
                     "eco: flags were provided but this program has no "
                     "flags decoder (recompile it with a current eco)\n");
        std::fflush(stderr);
        std::abort();
    }

    // Root `impl` and `flags` across callClosure1: the closure body may
    // collect, which moves heap objects, and an unrooted local would keep
    // the old address.
    uint64_t impl_bits = encodeHP(impl);
    uint64_t flags_bits = encodeHP(flags);
    Elm::EcoRootMark saved_range = Elm::ecoRootMark();
    Elm::ecoRoot1Push(reinterpret_cast<Elm::HPointer*>(&impl_bits));
    Elm::ecoRoot1Push(reinterpret_cast<Elm::HPointer*>(&flags_bits));

    void* implPtr = resolveHP(impl);
    if (!implPtr) { Elm::ecoRootRelease(saved_range); return emptyRecord(); }
    Record* implRec = static_cast<Record*>(implPtr);

    // impl fields in canonical order: init=0, subscriptions=1, update=2
    HPointer initFn = implRec->values[0].p;

    HPointer initPair = Scheduler::callClosure1(initFn, decodeHP(flags_bits));

    // Re-read impl from the rooted slot (callClosure1 may have moved it).
    impl  = decodeHP(impl_bits);
    flags = decodeHP(flags_bits);
    Elm::ecoRootRelease(saved_range);

    // Re-resolve impl after closure call
    implPtr = resolveHP(impl);
    if (!implPtr) return emptyRecord();

    // Extract (model, cmd) from the init result. cmd0 must remain rooted
    // across allocClosure / setupEffects / callClosure1 below — the GC will
    // move it during any of those allocations and our local copy would
    // otherwise become stale by the time we hand it to enqueueEffects.
    void* pairPtr = resolveHP(initPair);
    if (!pairPtr) return emptyRecord();

    // The model slot may be UNBOXED. `( Int, Cmd msg )` stores a raw i64 in
    // slot a and says so in `header.unboxed` (2 bits per slot, 00=boxed HPointer,
    // 01=Int, 10=Float, 11=Char). Reading `.p` unconditionally reinterprets
    // that scalar as a pointer: for `init _ = ( 0, … )` the word is 0, and
    // the first resolve of it dereferences null.
    //
    // Box it: the platform boundary is all-boxed both ways — `callClosure1/2`
    // hand the model back to Elm through the all-boxed arg layout, and a
    // root slot must not hold a raw scalar, which `modelStorage_` becomes
    // below.
    //
    // `boxElement` ALLOCATES for an unboxed kind, which can move `initTuple`,
    // so `initPair` is re-resolved before slot b is read.
    Tuple2* initTuple = static_cast<Tuple2*>(pairPtr);
    const u32 initModelKind = initTuple->header.unboxed & 0x3;
    const u32 initCmdKind = (initTuple->header.unboxed >> 2) & 0x3;
    Elm::Unboxable initModelSlot = initTuple->a;
    HPointer model = Elm::alloc::boxElement(initModelSlot, initModelKind);

    pairPtr = resolveHP(initPair);
    if (!pairPtr) return emptyRecord();
    initTuple = static_cast<Tuple2*>(pairPtr);
    HPointer cmd0 = Elm::alloc::boxElement(initTuple->b, initCmdKind);

    modelStorage_ = encodeHP(model);
    if (!modelRooted_) {
        eco_gc_add_value_root(&modelStorage_);
        modelRooted_ = true;
    }

    // Root impl, cmd0, and sendToAppCl across the remaining allocations.
    HPointer sendToAppCl = listNil();
    Elm::StackRootGuard live_guard(&impl, &cmd0, &sendToAppCl);

    // Create a closure that captures impl; model is accessed via PlatformRuntime singleton
    sendToAppCl = allocClosure(
        reinterpret_cast<EvalFunction>(workerSendToAppEvaluator), 2);
    void* clPtr = resolveHP(sendToAppCl);
    if (clPtr) {
        closureCapture(clPtr, boxed(impl), true);  // captured[0] = impl
    }

    HPointer ports = setupEffects(sendToAppCl);

    // Re-resolve impl from the rooted slot
    implPtr = resolveHP(impl);
    if (implPtr) {
        implRec = static_cast<Record*>(implPtr);
        HPointer subscriptionsFn = implRec->values[1].p;
        HPointer currentModel = decodeHP(modelStorage_);
        HPointer subs0 = Scheduler::callClosure1(subscriptionsFn, currentModel);
        enqueueEffects(cmd0, subs0);
    }

    // Embedding ready handshake: the program is initialized and its init
    // effects have fully dispatched; signal the host before blocking.
    if (readyHook_) {
        readyHook_(readyHookUser_);
    }

    // Returns on stop or quiescence.
    Scheduler::instance().runEventLoop();

    return ports;
}

} // namespace Elm::Platform
