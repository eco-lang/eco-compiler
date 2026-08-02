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

// Json kernel entry point (elm-kernel-cpp). Declared locally to keep the
// runtime -> kernel dependency at the linker level only (same pattern as
// PortRuntime.cpp).
extern "C" HPtr Elm_Kernel_Json_runOnString(HPtr decoder, HPtr jsonString);

namespace Elm::Platform {

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

static inline bool hpIsConstant(HPointer h) {
    return h.ptr_ind != 0;
}

static inline void* resolveHP(HPointer h) {
    if (hpIsConstant(h)) return nullptr;
    return Allocator::instance().resolve(h);
}

// Convert any String form (leaf or slice) to a UTF-8 std::string by
// delegating to Elm::StringOps::toStdString, the canonical interop path.
static std::string elmStringToStd(void* ptr) {
    return Elm::StringOps::toStdString(ptr);
}

// ============================================================================
// applyTaggers-as-closure support (PORT_005 / JS _Platform_toEffect parity)
// ============================================================================
//
// gatherEffects hands the accumulated Fx_Map tagger chain to the owning
// manager's cmdMap/subMap as a callable closure, mirroring the JS kernel:
//
//     effect = A2(map, applyTaggers, value)
//
// The map function decides how the tagger chain applies to the leaf value
// (Time/Task rebuild their payload customs with a composed tagger; outgoing
// ports drop it; incoming ports compose it over the subscription tagger).

// 2-slot closure: args[0] = captured taggers list, args[1] = value.
static void* applyTaggersEvaluator(void* args[]) {
    HPointer taggers = decodeHP(reinterpret_cast<uint64_t>(args[0]));
    HPointer value = decodeHP(reinterpret_cast<uint64_t>(args[1]));
    HPointer result =
        PlatformRuntime::instance().applyTaggers(taggers, value);
    return reinterpret_cast<void*>(encodeHP(result));
}

// Build a 1-arg closure that applies `taggers` innermost-first to its
// argument. Callers must not pass an empty chain (gatherEffects routes
// leaf values with no taggers straight through, both as a fast path and
// to keep unmapped effects byte-identical to the pre-ports behaviour).
// The result is a fresh allocation; callers must root it before any
// further allocation.
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
    // Intentionally leaked — see Scheduler::instance().
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

            // Flags decoder (registered by the startup preamble)
            if (flagsDecoder_ != 0)
                evacuate(flagsDecoder_);

            // Model storage (also registered as JIT root, but double-evacuating is safe)
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
        });
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

        // The self-process id is stable across re-arms (Process is immutable;
        // each step allocates a new value with the same id). sendToSelf and the
        // dedicated self-process step both resolve the live version by this id.
        u32 selfProcId =
            static_cast<u32>(static_cast<Process*>(resolveHP(selfProc))->id);

        // Create router: Custom with ctor=CTOR_Router.
        // field[0] = sendToApp closure (boxed, kind 00)
        // field[1] = self-process id  (unboxed Int, kind 01) — Q-I Option 2:
        //   store the *id* not a Process snapshot, so sendToSelf can resolve the
        //   live (immutable, advancing) self-process via latestProcessById and
        //   never delivers to a stale snapshot. Router is kernel-internal: only
        //   sendToApp (field 0) and sendToSelf (field 1) read it; Elm never
        //   introspects it. Slot 1 kind 01 lives in bits [2,3] → mask 0b0100.
        std::vector<Unboxable> routerFields(2);
        routerFields[0] = boxed(sendToAppClosure);
        routerFields[1] = unboxedInt(static_cast<i64>(selfProcId));
        HPointer router = custom(CTOR_Router, routerFields, 0x4);
        // Root router: it is held across the init-thunk force / rawSpawn /
        // drain GC points below and only consumed at encodeHP() at the end
        // of this iteration (mirrors self_guard for selfProc).
        Elm::StackRootGuard router_guard(&router);

        // Register the self-process message handler (Q-H). When this process
        // receives a mailbox message, the scheduler's dedicated step invokes
        // this handler with the message, which runs onSelfMsg + threads state.
        std::string homeCopy = home;
        sched.registerSelfProcess(selfProcId,
            [this, homeCopy](HPointer msg) { handleSelfMsg(homeCopy, msg); });

        // Run the init task to get initial manager state.
        //
        // Effect-manager kernels (e.g. eco_register_task_effect_manager in
        // elm-kernel-cpp/src/core/TaskEffectManager.cpp) register `init` as a
        // 0-arg closure that *produces* the init Task when applied — not as
        // an already-evaluated Task value. Detect that case and apply the
        // closure first to obtain the actual Task; otherwise we'd hand a
        // Closure to rawSpawn and the scheduler would treat its bytes as a
        // Task header, silently dropping the init effect.
        HPointer initTask = decodeHP(info.init);
        HPointer initialState = listNil();  // fallback
        if (!alloc::isNil(initTask) && !hpIsConstant(initTask)) {
            void* initPtr = resolveHP(initTask);
            if (initPtr && static_cast<Header*>(initPtr)->tag == Tag_Closure) {
                // The kernel registers `init` as a 0-arity thunk closure
                // (allocClosure(...InitEvaluator, 0)) that *produces* the
                // init Task when forced. eco_apply_closure(_, nullptr, 0)
                // is a no-op (num_args==0 returns the closure unchanged,
                // see RuntimeExports.cpp eco_apply_closure_eval), so it must
                // NOT be used to force a thunk. eco_closure_call_saturated
                // has no 0-arg short-circuit and dispatches straight to the
                // evaluator, which is exactly the "force a saturated thunk"
                // operation needed here.
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
            // values. The id is stable; use it to look up the latest version
            // after drain.
            u32 procId = static_cast<u32>(static_cast<Process*>(resolveHP(initProc))->id);
            sched.drain();

            HPointer latestProc = sched.latestProcessById(procId);
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
                        // Effect-manager init state is structural — never a
                        // primitive — so the value is always a boxed HPointer.
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

    // Return empty record (no ports for now)
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

// Decode a vector of encoded HPointers and build an Elm list via the
// GC-safe listFromPointers helper. The caller's uint64_t vector remains
// reachable through the external root scanner, so if GC fires inside
// listFromPointers both copies are evacuated consistently.
static HPointer listFromEncoded(const std::vector<uint64_t>& encoded) {
    std::vector<HPointer> decoded;
    decoded.reserve(encoded.size());
    for (uint64_t e : encoded) decoded.push_back(decodeHP(e));
    return alloc::listFromPointers(decoded);
}

void PlatformRuntime::dispatchEffects() {
    if (managers_.empty()) return;

    HPointer cmdBag = decodeHP(activeBatch_.cmdBag);
    HPointer subBag = decodeHP(activeBatch_.subBag);

    // Initialize empty entries for every registered manager so gatherEffects
    // can find the slot for any home it encounters.
    effectsScratch_.clear();
    for (auto& [home, _] : managers_) {
        effectsScratch_[home];  // default-construct PerManagerEffects
    }

    HPointer nilTaggers = listNil();
    gatherEffects(true,  cmdBag, effectsScratch_, nilTaggers);
    gatherEffects(false, subBag, effectsScratch_, nilTaggers);

    auto& sched = Scheduler::instance();
    for (auto& [home, per] : effectsScratch_) {
        auto msIt = managerStates_.find(home);
        if (msIt == managerStates_.end()) continue;
        auto miIt = managers_.find(home);
        if (miIt == managers_.end()) continue;

        HPointer onEffectsFn = decodeHP(miIt->second.onEffects);
        if (alloc::isNil(onEffectsFn) || hpIsConstant(onEffectsFn)) continue;

        // Build cmd/sub Elm lists via the GC-safe helper. Replaces the
        // old manual cons() loop whose accumulator + un-consumed HPointers
        // were unrooted across each cons allocation.
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
        // values. The id is stable; use it to look up the latest version
        // after drain.
        u32 procId = static_cast<u32>(static_cast<Process*>(resolveHP(effectProc))->id);
        sched.drain();

        HPointer latestProc = sched.latestProcessById(procId);
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
            // No Fx_Map wrappers: the value passes through unchanged.
            // (`map(applyTaggers, value)` with an empty chain is identity
            // for every well-formed manager; skipping the call keeps
            // unmapped effects on the exact pre-ports path.)
            effect = value;
        } else {
            // JS parity (_Platform_toEffect): hand the tagger chain to the
            // manager's cmdMap/subMap as a callable and let the map decide
            // how it applies to the leaf value (PORT_005). Managers without
            // a map function (registered as Nil) get the legacy direct
            // application.
            HPointer mapFn = listNil();
            {
                auto miIt = managers_.find(home);
                if (miIt != managers_.end()) {
                    mapFn = decodeHP(isCmd ? miIt->second.cmdMap
                                           : miIt->second.subMap);
                }
            }

            if (alloc::isNil(mapFn) || hpIsConstant(mapFn)) {
                // Legacy fallback: apply taggers directly to the leaf value.
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
        // Root innerBag across the cons allocation (it would otherwise go
        // stale before the recursive call), and newTaggers across the
        // recursion is the callee's responsibility via its parameter...
        // which is a C++ local — so root it here too for the duration.
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
    // taggers is a list of functions to apply (innermost first).
    // Walk the list and apply each. result, current and the next-tail must
    // survive each callClosure1 (which runs Elm code that may GC).
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
    // Extract the self-process id from router field 1 (unboxed Int, Q-I) and
    // resolve the live (latest) Process version. The Router only holds the id
    // because Process is immutable — a stored snapshot would go stale on the
    // first step of the self-process.
    void* routerPtr = resolveHP(router);
    if (!routerPtr) return Scheduler::instance().taskSucceed(unit());

    Custom* routerObj = static_cast<Custom*>(routerPtr);
    u32 selfProcId = static_cast<u32>(routerObj->values[1].i);

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
    u32 procId =
        static_cast<u32>(static_cast<Process*>(resolveHP(effectProc))->id);
    sched.drain();

    HPointer latestProc = sched.latestProcessById(procId);
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
                // managerStates_[home].state already; writing back an unchanged
                // onSelfMsg result (it returns the same `state` it received —
                // the common case, e.g. Http only sends) would clobber that.
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

// sendToApp evaluator for Platform.worker
// Captured values: args[0] = impl (record), args[1] = model storage pointer (as uint64_t)
// Argument: args[2] = msg
static void* workerSendToAppEvaluator(void* rawArgs[]) {
    // This is the update cycle:
    // 1. pair = update(msg, model)
    // 2. model = pair.a
    // 3. newCmd = pair.b
    // 4. subs = subscriptions(model)
    // 5. enqueueEffects(newCmd, subs)

    // Captured: args[0] = impl (boxed HPointer)
    // Argument: args[1] = msg (boxed HPointer)
    uint64_t implEnc = reinterpret_cast<uint64_t>(rawArgs[0]);
    uint64_t msgEnc = reinterpret_cast<uint64_t>(rawArgs[1]);

    HPointer impl = decodeHP(implEnc);
    HPointer msg = decodeHP(msgEnc);

    // Access model storage via the PlatformRuntime singleton
    // (Can't pass raw pointer through closure because buildEvaluatorArgs boxes unboxed captures)
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
    Tuple2* tuple = static_cast<Tuple2*>(pairPtr);
    HPointer newModel = tuple->a.p;
    HPointer newCmd = tuple->b.p;

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

// Decode the host-supplied flags JSON with the program's registered flags
// decoder. Mirrors PortRuntime::drainPendingSends' decode discipline: every
// HPointer local is rooted across the parse/decode allocations, and a
// decode failure is a hard crash naming the problem (the native analogue
// of JS Debug.crash 2, "Problem with the flags given to your Elm program").
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
    flags = static_cast<Custom*>(ptr)->values[0].p;
    return flags;
}

HPointer PlatformRuntime::initWorker(HPointer impl) {
    // Phase 1: Decode flags through the program's registered flags decoder
    // (compiled from the root main's `Program flags model msg` type and
    // registered by the generated @__eco_register_ports preamble). The
    // host-supplied JSON comes from setPendingFlagsJson (eco_app_start /
    // the test harness); absent flags decode as `null`, matching the JS
    // kernel running the flags decoder on `undefined`. This path has no
    // special cases: every flags source — embedding hosts, the Node glue,
    // the stress harness — is arbitrary JSON through the same decoder.
    HPointer flags = unit();
    // Root `impl` across the decode: decodeFlags allocates (the JSON heap
    // string, the parse tree, every decoder intermediate), and a GC during
    // any of that would move the impl record out from under this frame's
    // by-value copy (the caller's statepoint relocation does not update
    // callee copies). The guard rewrites `impl` in place on GC.
    Elm::StackRootGuard implGuard(&impl);
    if (flagsDecoder_ != 0) {
        flags = decodeFlags(hasPendingFlagsJson_ ? pendingFlagsJson_
                                                 : std::string("null"));
    } else if (hasPendingFlagsJson_ && pendingFlagsJson_ != "null") {
        // The host passed real flags but the program registered no decoder
        // (an artifact compiled before flags support). Fail loudly rather
        // than silently handing init a Unit. Bare `null` is tolerated —
        // `flags: null` is the universal host idiom for flagless programs.
        std::fprintf(stderr,
                     "eco: flags were provided but this program has no "
                     "flags decoder (recompile it with a current eco)\n");
        std::fflush(stderr);
        std::abort();
    }

    // Phase 2: Call init
    // Root `impl` (and `flags`) across callClosure1: the closure body may
    // trigger minor/major GC, which moves heap objects. Without rooting,
    // the local HPointer encoding in our register/stack frame would point
    // at the previous from-space (now to-space) of the nursery.
    uint64_t impl_bits = encodeHP(impl);
    uint64_t flags_bits = encodeHP(flags);
    size_t saved_range = eco_gc_stack_range_point();
    eco_gc_push_stack_range(&impl_bits, 1, 1);
    eco_gc_push_stack_range(&flags_bits, 1, 1);

    void* implPtr = resolveHP(impl);
    if (!implPtr) { eco_gc_restore_stack_range_point(saved_range); return emptyRecord(); }
    Record* implRec = static_cast<Record*>(implPtr);

    // impl fields in canonical order: init=0, subscriptions=1, update=2
    HPointer initFn = implRec->values[0].p;

    HPointer initPair = Scheduler::callClosure1(initFn, decodeHP(flags_bits));

    // Re-read impl from the rooted slot (callClosure1 may have moved it).
    impl  = decodeHP(impl_bits);
    flags = decodeHP(flags_bits);
    eco_gc_restore_stack_range_point(saved_range);

    // Re-resolve impl after closure call
    implPtr = resolveHP(impl);
    if (!implPtr) return emptyRecord();

    // Extract (model, cmd) from the init result. cmd0 must remain rooted
    // across allocClosure / setupEffects / callClosure1 below — the GC will
    // move it during any of those allocations and our local copy would
    // otherwise become stale by the time we hand it to enqueueEffects.
    void* pairPtr = resolveHP(initPair);
    if (!pairPtr) return emptyRecord();
    Tuple2* initTuple = static_cast<Tuple2*>(pairPtr);
    HPointer model = initTuple->a.p;
    HPointer cmd0 = initTuple->b.p;

    // Phase 3: Set up model storage as a GC root
    modelStorage_ = encodeHP(model);
    if (!modelRooted_) {
        eco_gc_add_value_root(&modelStorage_);
        modelRooted_ = true;
    }

    // Root impl, cmd0, and sendToAppCl across the remaining allocations.
    HPointer sendToAppCl = listNil();
    Elm::StackRootGuard live_guard(&impl, &cmd0, &sendToAppCl);

    // Phase 4: Build sendToApp closure
    // Create a closure that captures impl; model is accessed via PlatformRuntime singleton
    sendToAppCl = allocClosure(
        reinterpret_cast<EvalFunction>(workerSendToAppEvaluator), 2);
    void* clPtr = resolveHP(sendToAppCl);
    if (clPtr) {
        closureCapture(clPtr, boxed(impl), true);  // captured[0] = impl
    }

    // Phase 5: Setup effect managers
    HPointer ports = setupEffects(sendToAppCl);

    // Phase 6: Get initial subscriptions and enqueue initial effects
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

    // Phase 7: Run the event loop (blocks until program is idle)
    Scheduler::instance().runEventLoop();

    return ports;
}

} // namespace Elm::Platform
