#include "PlatformRuntime.hpp"
#include "Scheduler.hpp"
#include "allocator/Allocator.hpp"
#include "allocator/HeapHelpers.hpp"
#include "allocator/RuntimeExports.h"
#include <cstring>
#include <cassert>

using namespace Elm;
using namespace Elm::alloc;

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
    return h.constant != 0;
}

static inline void* resolveHP(HPointer h) {
    if (hpIsConstant(h)) return nullptr;
    return Allocator::instance().resolve(h);
}

// ============================================================================
// Singleton
// ============================================================================

PlatformRuntime& PlatformRuntime::instance() {
    static PlatformRuntime runtime;
    return runtime;
}

PlatformRuntime::PlatformRuntime() {}

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
        // The self-process runs a Receive loop that handles onSelfMsg
        HPointer recvCallback = info.onSelfMsg;  // will be wrapped later
        // For now, create a simple process with a null root
        HPointer nilHP = listNil();
        HPointer selfProc = sched.rawSpawn(
            sched.taskReceive(recvCallback));

        // Create router: Custom with ctor=CTOR_Router, 2 boxed fields
        // fields[0] = sendToApp closure, fields[1] = selfProcess
        std::vector<Unboxable> routerFields(2);
        routerFields[0].p = sendToAppClosure;
        routerFields[1].p = selfProc;
        HPointer router = custom(CTOR_Router, routerFields, 0);

        // Run the init task to get initial manager state
        // For now, just store nil as initial state
        // Full implementation would run the init Task through the scheduler

        ManagerState ms;
        ms.selfProcess = encodeHP(selfProc);
        ms.router = encodeHP(router);
        ms.state = encodeHP(nilHP);
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
        FxBatch batch = effectsQueue_.front();
        effectsQueue_.erase(effectsQueue_.begin());
        dispatchEffects(decodeHP(batch.cmdBag), decodeHP(batch.subBag));
    }

    effectsActive_ = false;
}

void PlatformRuntime::dispatchEffects(HPointer cmdBag, HPointer subBag) {
    // Gather effects per manager home
    // For now, this is a simplified implementation
    // Full version would walk the bag trees and call onEffects for each manager

    // If no managers registered, nothing to do
    if (managers_.empty()) return;

    // Gather cmd and sub effects
    std::unordered_map<std::string, std::pair<std::vector<uint64_t>, std::vector<uint64_t>>> effects;

    // Initialize empty lists for all managers
    for (auto& [home, _] : managers_) {
        effects[home] = {{}, {}};
    }

    HPointer nilTaggers = listNil();
    gatherEffects(true, cmdBag, effects, nilTaggers);
    gatherEffects(false, subBag, effects, nilTaggers);

    // Dispatch to each manager
    auto& sched = Scheduler::instance();
    for (auto& [home, efx] : effects) {
        auto it = managerStates_.find(home);
        if (it == managerStates_.end()) continue;
        auto& ms = it->second;
        auto managerIt = managers_.find(home);
        if (managerIt == managers_.end()) continue;

        // Build Elm lists of cmd effects and sub effects
        HPointer cmdList = listNil();
        for (auto rit = efx.first.rbegin(); rit != efx.first.rend(); ++rit) {
            cmdList = cons(boxed(decodeHP(*rit)), cmdList, true);
        }

        HPointer subList = listNil();
        for (auto rit = efx.second.rbegin(); rit != efx.second.rend(); ++rit) {
            subList = cons(boxed(decodeHP(*rit)), subList, true);
        }

        // TODO: Call onEffects(router, cmdList, subList, state) -> Task state
        // For now, just skip the actual onEffects call
        // This would be:
        //   HPointer router = decodeHP(ms.router);
        //   HPointer state = decodeHP(ms.state);
        //   HPointer newStateTask = Scheduler::callClosure4(
        //       managerIt->second.onEffects, router, cmdList, subList, state);
        //   ... run the task and update ms.state
    }
}

void PlatformRuntime::gatherEffects(
    bool isCmd,
    HPointer bag,
    std::unordered_map<std::string, std::pair<std::vector<uint64_t>, std::vector<uint64_t>>>& effects,
    HPointer taggers)
{
    if (alloc::isNil(bag) || hpIsConstant(bag)) return;

    void* bagPtr = resolveHP(bag);
    if (!bagPtr) return;

    Custom* custom = static_cast<Custom*>(bagPtr);
    u16 ctor = static_cast<u16>(custom->ctor);

    if (ctor == Fx_Leaf) {
        // Leaf: values[0] = home (String), values[1] = value
        // For now, we don't have a way to extract the home string from
        // a boxed ElmString easily, so skip actual gathering
        // TODO: Extract home string and apply taggers to value
    }
    else if (ctor == Fx_Node) {
        // Node: values[0] = list of bags
        HPointer bagList = custom->values[0].p;
        HPointer current = bagList;
        while (!alloc::isNil(current)) {
            void* cellPtr = resolveHP(current);
            if (!cellPtr) break;
            Cons* cell = static_cast<Cons*>(cellPtr);
            HPointer innerBag = cell->head.p;
            gatherEffects(isCmd, innerBag, effects, taggers);
            current = cell->tail;
        }
    }
    else if (ctor == Fx_Map) {
        // Map: values[0] = tagger function, values[1] = inner bag
        HPointer tagger = custom->values[0].p;
        HPointer innerBag = custom->values[1].p;
        // Prepend tagger to taggers list
        HPointer newTaggers = cons(boxed(tagger), taggers, true);
        gatherEffects(isCmd, innerBag, effects, newTaggers);
    }
}

HPointer PlatformRuntime::applyTaggers(HPointer taggers, HPointer value) {
    HPointer result = value;
    // taggers is a list of functions to apply (innermost first)
    // Walk the list and apply each
    HPointer current = taggers;
    while (!alloc::isNil(current)) {
        void* ptr = resolveHP(current);
        if (!ptr) break;
        Cons* cell = static_cast<Cons*>(ptr);
        HPointer tagger = cell->head.p;
        result = Scheduler::callClosure1(tagger, result);
        current = cell->tail;
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

HPointer PlatformRuntime::sendToSelf(HPointer router, HPointer msg) {
    // Extract selfProcess from router
    void* routerPtr = resolveHP(router);
    if (!routerPtr) return Scheduler::instance().taskSucceed(unit());

    Custom* routerObj = static_cast<Custom*>(routerPtr);
    HPointer selfProcess = routerObj->values[1].p;

    // Send message to the self process
    Scheduler::instance().rawSend(selfProcess, msg);

    return Scheduler::instance().taskSucceed(unit());
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

    uint64_t implEnc = reinterpret_cast<uint64_t>(rawArgs[0]);
    uint64_t modelPtrEnc = reinterpret_cast<uint64_t>(rawArgs[1]);
    uint64_t msgEnc = reinterpret_cast<uint64_t>(rawArgs[2]);

    HPointer impl = decodeHP(implEnc);
    HPointer msg = decodeHP(msgEnc);

    // Read current model from the model storage location
    uint64_t* modelStoragePtr = reinterpret_cast<uint64_t*>(modelPtrEnc);
    HPointer currentModel = decodeHP(*modelStoragePtr);

    // Access impl fields. impl is a Record with fields in canonical order:
    // For Platform.worker's impl: { init, subscriptions, update }
    // Canonical alphabetical order: init=0, subscriptions=1, update=2
    void* implPtr = resolveHP(impl);
    if (!implPtr) return reinterpret_cast<void*>(encodeHP(Elm::alloc::unit()));
    Record* implRec = static_cast<Record*>(implPtr);

    HPointer updateFn = implRec->values[2].p;       // update
    HPointer subscriptionsFn = implRec->values[1].p; // subscriptions

    // Call update(msg, model) -> (newModel, cmd)
    HPointer pair = Scheduler::callClosure2(updateFn, msg, currentModel);

    // Extract tuple fields
    void* pairPtr = resolveHP(pair);
    if (!pairPtr) return reinterpret_cast<void*>(encodeHP(Elm::alloc::unit()));
    Tuple2* tuple = static_cast<Tuple2*>(pairPtr);
    HPointer newModel = tuple->a.p;
    HPointer newCmd = tuple->b.p;

    // Update model storage
    *modelStoragePtr = encodeHP(newModel);

    // Get new subscriptions
    HPointer newSubs = Scheduler::callClosure1(subscriptionsFn, newModel);

    // Enqueue effects
    PlatformRuntime::instance().enqueueEffects(newCmd, newSubs);

    return reinterpret_cast<void*>(encodeHP(Elm::alloc::unit()));
}

HPointer PlatformRuntime::initWorker(HPointer impl) {
    // Phase 1: Decode flags (minimal path: use Unit)
    HPointer flags = unit();

    // Phase 2: Call init
    void* implPtr = resolveHP(impl);
    if (!implPtr) return emptyRecord();
    Record* implRec = static_cast<Record*>(implPtr);

    // impl fields in canonical order: init=0, subscriptions=1, update=2
    HPointer initFn = implRec->values[0].p;

    HPointer initPair = Scheduler::callClosure1(initFn, flags);

    // Re-resolve impl after closure call
    implPtr = resolveHP(impl);
    if (!implPtr) return emptyRecord();

    // Extract (model, cmd) from the init result
    void* pairPtr = resolveHP(initPair);
    if (!pairPtr) return emptyRecord();
    Tuple2* initTuple = static_cast<Tuple2*>(pairPtr);
    HPointer model = initTuple->a.p;
    HPointer cmd0 = initTuple->b.p;

    // Phase 3: Set up model storage as a GC root
    modelStorage_ = encodeHP(model);
    if (!modelRooted_) {
        eco_gc_add_root(&modelStorage_);
        modelRooted_ = true;
    }

    // Phase 4: Build sendToApp closure
    // Create a closure that captures impl and a pointer to modelStorage_
    HPointer sendToAppCl = allocClosure(
        reinterpret_cast<EvalFunction>(workerSendToAppEvaluator), 3);
    void* clPtr = resolveHP(sendToAppCl);
    if (clPtr) {
        closureCapture(clPtr, boxed(impl), true);  // captured[0] = impl
        // Store the address of modelStorage_ as an unboxed integer
        Unboxable modelPtrVal;
        modelPtrVal.i = reinterpret_cast<int64_t>(&modelStorage_);
        closureCapture(clPtr, modelPtrVal, false);  // captured[1] = &modelStorage_ (unboxed)
    }

    // Phase 5: Setup effect managers
    HPointer ports = setupEffects(sendToAppCl);

    // Phase 6: Get initial subscriptions and enqueue initial effects
    // Re-resolve impl
    implPtr = resolveHP(impl);
    if (implPtr) {
        implRec = static_cast<Record*>(implPtr);
        HPointer subscriptionsFn = implRec->values[1].p;
        HPointer currentModel = decodeHP(modelStorage_);
        HPointer subs0 = Scheduler::callClosure1(subscriptionsFn, currentModel);
        enqueueEffects(cmd0, subs0);
    }

    // Phase 7: Drain the scheduler to process initial effects
    Scheduler::instance().drain();

    return ports;
}

} // namespace Elm::Platform
