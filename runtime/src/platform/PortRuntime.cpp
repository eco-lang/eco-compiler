//===- PortRuntime.cpp - Native Elm ports runtime ---------------------------===//
//
// Implements ports as pseudo effect managers (JS _Platform_incomingPort /
// _Platform_outgoingPort parity). See plans/native-ports-and-embedding.md.
//
// Value shapes (PORT_002):
//   outgoing `port foo : payload -> Cmd msg`:
//     foo p  ==>  Fx_Leaf{home="foo", value = encoder(p)}   (encoded at the
//     call site by generated code; the manager only stringifies + delivers)
//   incoming `port bar : (payload -> msg) -> Sub msg`:
//     bar tagger  ==>  Fx_Leaf{home="bar", value = tagger}
//
// Manager maps:
//   outgoing cmdMap = \taggers value -> value          (taggers dropped)
//   incoming subMap = \f g -> (\v -> f (g v))          (composition)
//
//===----------------------------------------------------------------------===//

#include "PortRuntime.hpp"
#include "PlatformRuntime.hpp"
#include "Scheduler.hpp"
#include "allocator/Allocator.hpp"
#include "allocator/HeapHelpers.hpp"
#include "allocator/RootSet.hpp"
#include "allocator/RuntimeExports.h"
#include "allocator/StringOps.hpp"
#include <cstdio>
#include <cstdlib>
#include <cstring>

using namespace Elm;
using namespace Elm::alloc;

// Json kernel entry points (elm-kernel-cpp). Declared locally to keep the
// runtime → kernel dependency at the linker level only; both archives are
// linked into every program (--start-group) and into the JIT symbol map.
extern "C" HPtr Elm_Kernel_Json_runOnString(HPtr decoder, HPtr jsonString);
extern "C" HPtr Elm_Kernel_Json_encode(int64_t indent, HPtr value);

namespace Elm::Platform {

namespace {

inline uint64_t encodeHP(HPointer h) {
    union { HPointer hp; uint64_t val; } u;
    u.hp = h;
    return u.val;
}

inline HPointer decodeHP(uint64_t val) {
    union { HPointer hp; uint64_t val; } u;
    u.val = val;
    return u.hp;
}

inline void* resolveHP(HPointer h) {
    if (h.ptr_ind != 0) return nullptr;
    return Allocator::instance().resolve(h);
}

std::string elmStringToStd(HPointer s) {
    void* ptr = resolveHP(s);
    if (!ptr) return std::string();
    return Elm::StringOps::toStdString(ptr);
}

// ---------------------------------------------------------------------------
// Port effect-manager evaluator closures
// ---------------------------------------------------------------------------

// init thunk: 0-arg closure producing the manager's init Task.
// Port managers keep no Elm-side state; Nil throughout.
void* portInitEvaluator(void* args[]) {
    (void)args;
    HPointer task = Scheduler::instance().taskSucceed(listNil());
    return reinterpret_cast<void*>(encodeHP(task));
}

// onSelfMsg : Router -> selfMsg -> State -> Task Never State.
// Ports never use self messages; return the state unchanged.
void* portOnSelfMsgEvaluator(void* args[]) {
    uint64_t stateEnc = reinterpret_cast<uint64_t>(args[2]);
    HPointer task = Scheduler::instance().taskSucceed(decodeHP(stateEnc));
    return reinterpret_cast<void*>(encodeHP(task));
}

// Outgoing onEffects. Slot layout (1 capture + 4 call args):
//   args[0] = port name (captured ElmString)
//   args[1] = router (unused)
//   args[2] = cmdList — each element is an already-encoded Json value
//   args[3] = subList (unused; outgoing ports have no subscriptions)
//   args[4] = state
void* portOutgoingOnEffectsEvaluator(void* args[]) {
    HPointer nameHP = decodeHP(reinterpret_cast<uint64_t>(args[0]));
    HPointer cmdList = decodeHP(reinterpret_cast<uint64_t>(args[2]));
    HPointer state = decodeHP(reinterpret_cast<uint64_t>(args[4]));

    std::string name = elmStringToStd(nameHP);

    HPointer current = cmdList;
    Elm::StackRootGuard loopGuard(&current, &state);
    while (!alloc::isNil(current)) {
        void* cellPtr = resolveHP(current);
        if (!cellPtr) break;
        Cons* cell = static_cast<Cons*>(cellPtr);
        HPointer value = cell->head.p;
        // Snapshot the tail before Json_encode — `cell` is stale after any
        // GC the stringify allocation may trigger.
        HPointer next = cell->tail;
        {
            Elm::StackRootGuard itemGuard(&value, &next);
            HPtr jsonStr = Elm_Kernel_Json_encode(
                0, HPtr::fromBits(encodeHP(value)));
            std::string json = elmStringToStd(decodeHP(jsonStr.toBits()));
            PortRuntime::instance().deliverOutgoing(name, json);
            current = next;
        }
    }

    HPointer task = Scheduler::instance().taskSucceed(state);
    return reinterpret_cast<void*>(encodeHP(task));
}

// Incoming onEffects. Slot layout (1 capture + 4 call args):
//   args[0] = port name (captured ElmString)
//   args[1] = router (unused)
//   args[2] = cmdList (unused; incoming ports have no commands)
//   args[3] = subList — current composed taggers (one per active Sub)
//   args[4] = state
void* portIncomingOnEffectsEvaluator(void* args[]) {
    HPointer nameHP = decodeHP(reinterpret_cast<uint64_t>(args[0]));
    HPointer subList = decodeHP(reinterpret_cast<uint64_t>(args[3]));
    HPointer state = decodeHP(reinterpret_cast<uint64_t>(args[4]));

    std::string name = elmStringToStd(nameHP);
    PortRuntime::instance().setIncomingSubs(name, subList);

    HPointer task = Scheduler::instance().taskSucceed(state);
    return reinterpret_cast<void*>(encodeHP(task));
}

// Outgoing cmdMap: \taggers value -> value. Port commands carry no msg, so
// Cmd.map over them is identity on the payload (JS _Platform_outgoingPortMap).
void* outgoingPortMapEvaluator(void* args[]) {
    return args[1];
}

// Composed tagger body: args[0] = f (capture), args[1] = g (capture),
// args[2] = v  ==>  f (g v). Mirrors TimeEffectManager's
// composedTaggerEvaluator rooting discipline.
void* portComposedTaggerEvaluator(void* args[]) {
    uint64_t fEnc = reinterpret_cast<uint64_t>(args[0]);
    uint64_t gEnc = reinterpret_cast<uint64_t>(args[1]);
    uint64_t vEnc = reinterpret_cast<uint64_t>(args[2]);

    HPointer fHP = decodeHP(fEnc);
    Elm::StackRootGuard fRoot(&fHP);

    uint64_t innerEnc =
        eco_apply_closure(HPtr::fromBits(gEnc), &vEnc, 1).toBits();

    HPointer innerHP = decodeHP(innerEnc);
    Elm::StackRootGuard innerRoot(&innerHP);
    uint64_t innerArg = encodeHP(innerHP);
    uint64_t resultEnc =
        eco_apply_closure(HPtr::fromBits(encodeHP(fHP)), &innerArg, 1)
            .toBits();
    return reinterpret_cast<void*>(resultEnc);
}

// Incoming subMap: \f g -> (\v -> f (g v))  (JS _Platform_incomingPortMap).
void* incomingPortMapEvaluator(void* args[]) {
    HPointer f = decodeHP(reinterpret_cast<uint64_t>(args[0]));
    HPointer g = decodeHP(reinterpret_cast<uint64_t>(args[1]));
    Elm::StackRootGuard guard(&f, &g);

    HPointer composed = allocClosure(portComposedTaggerEvaluator, 3);
    Elm::StackRootGuard composedRoot(&composed);
    void* clPtr = resolveHP(composed);
    if (clPtr) {
        closureCapture(clPtr, boxed(f), true);
        clPtr = resolveHP(composed);
        closureCapture(clPtr, boxed(g), true);
    }
    return reinterpret_cast<void*>(encodeHP(composed));
}

// Result customs produced by the Json kernel: ctor 0 = Ok, 1 = Err
// (see JsonExports.cpp makeErr/isOk).
bool resultIsOk(HPointer result) {
    void* ptr = resolveHP(result);
    if (!ptr) return false;
    return static_cast<Custom*>(ptr)->ctor == 0;
}

// Build the ManagerInfo for one port. Allocates several closures; every
// intermediate HPointer is rooted so any of the allocations may GC.
PlatformRuntime::ManagerInfo buildPortManager(const std::string& name,
                                              bool incoming) {
    HPointer nameStr = listNil();
    HPointer initCl = listNil();
    HPointer onEffectsCl = listNil();
    HPointer onSelfMsgCl = listNil();
    HPointer mapCl = listNil();
    Elm::StackRootGuard guard(
        { &nameStr, &initCl, &onEffectsCl, &onSelfMsgCl, &mapCl });

    nameStr = allocStringFromUTF8(name);
    initCl = allocClosure(portInitEvaluator, 0);
    onSelfMsgCl = allocClosure(portOnSelfMsgEvaluator, 3);

    // onEffects: 1 captured slot (port name) + 4 call args.
    onEffectsCl = allocClosure(incoming ? portIncomingOnEffectsEvaluator
                                        : portOutgoingOnEffectsEvaluator,
                               5);
    if (void* clPtr = resolveHP(onEffectsCl)) {
        closureCapture(clPtr, boxed(nameStr), true);
    }

    mapCl = allocClosure(incoming ? incomingPortMapEvaluator
                                  : outgoingPortMapEvaluator,
                         2);

    PlatformRuntime::ManagerInfo info;
    info.init = encodeHP(initCl);
    info.onEffects = encodeHP(onEffectsCl);
    info.onSelfMsg = encodeHP(onSelfMsgCl);
    info.cmdMap = incoming ? encodeHP(listNil()) : encodeHP(mapCl);
    info.subMap = incoming ? encodeHP(mapCl) : encodeHP(listNil());
    return info;
}

[[noreturn]] void portCrash(const std::string& message) {
    std::fprintf(stderr, "eco ports: %s\n", message.c_str());
    std::fflush(stderr);
    std::abort();
}

}  // namespace

// ---------------------------------------------------------------------------
// PortRuntime
// ---------------------------------------------------------------------------

PortRuntime& PortRuntime::instance() {
    // Intentionally leaked — see Scheduler::instance().
    static PortRuntime* runtime = new PortRuntime();
    return *runtime;
}

PortRuntime::PortRuntime() = default;

void PortRuntime::ensureRuntimeHooks() {
    // Called on the eco thread during registration (before Platform.worker
    // starts the event loop), so plain-bool idempotence is sufficient.
    if (hooksInstalled_) return;
    hooksInstalled_ = true;

    // GC root scanner for the decoder/subs handles (PORT_004). Takes
    // portsMutex_, so the eco thread must never hold that mutex across a
    // GC allocation.
    Allocator::instance().getRootSetSlow().addExternalRootScanner(
        [this](RootSet::EvacuateFn evacuate) {
            std::lock_guard<std::mutex> lock(portsMutex_);
            for (auto& [name, info] : ports_) {
                (void)name;
                if (info.decoder) evacuate(info.decoder);
                if (info.subs) evacuate(info.subs);
            }
        });

    // Incoming sends are drained on the eco thread via the scheduler's
    // asyncSource mechanism (same pattern as the HTTP worker).
    Scheduler::instance().registerAsyncSource(
        []() { PortRuntime::instance().drainPendingSends(); },
        []() { return PortRuntime::instance().hasPendingSends(); });
}

void PortRuntime::registerIncoming(const std::string& name,
                                   HPointer decoder) {
    ensureRuntimeHooks();

    // PORT_001: the bare port name is the effect-manager registry key; a
    // port shadowing a real manager (e.g. "Time") would clobber it.
    if (PlatformRuntime::instance().hasManager(name)) {
        portCrash("port name '" + name +
                  "' collides with an existing effect manager");
    }

    Elm::StackRootGuard decoderGuard(&decoder);
    PlatformRuntime::ManagerInfo info =
        buildPortManager(name, /*incoming=*/true);

    {
        std::lock_guard<std::mutex> lock(portsMutex_);
        PortInfo& p = ports_[name];
        if (p.registered) {
            portCrash("duplicate port name '" + name +
                      "' (port names must be unique per program)");
        }
        p.registered = true;
        p.incoming = true;
        p.decoder = encodeHP(decoder);
        registrationOrder_.push_back(name);
    }

    PlatformRuntime::instance().registerManager(name, info);
}

void PortRuntime::registerOutgoing(const std::string& name) {
    ensureRuntimeHooks();

    if (PlatformRuntime::instance().hasManager(name)) {
        portCrash("port name '" + name +
                  "' collides with an existing effect manager");
    }

    PlatformRuntime::ManagerInfo info =
        buildPortManager(name, /*incoming=*/false);

    {
        std::lock_guard<std::mutex> lock(portsMutex_);
        PortInfo& p = ports_[name];
        if (p.registered) {
            portCrash("duplicate port name '" + name +
                      "' (port names must be unique per program)");
        }
        p.registered = true;
        p.incoming = false;
        registrationOrder_.push_back(name);
    }

    PlatformRuntime::instance().registerManager(name, info);
}

void PortRuntime::setIncomingSubs(const std::string& name,
                                  HPointer subsList) {
    std::lock_guard<std::mutex> lock(portsMutex_);
    auto it = ports_.find(name);
    if (it == ports_.end() || !it->second.incoming) return;
    it->second.subs = encodeHP(subsList);
}

void PortRuntime::deliverOutgoing(const std::string& name,
                                  const std::string& json) {
    std::vector<std::pair<EcoPortCallback, void*>> sinksCopy;
    {
        std::lock_guard<std::mutex> lock(portsMutex_);
        auto it = ports_.find(name);
        if (it == ports_.end()) return;
        if (it->second.sinks.empty()) {
            if (!it->second.everSubscribed) {
                // Buffer-until-FIRST-subscribe (plan Q4): hosts that
                // attach after startup still see init-time messages, in
                // order. Once a subscriber has existed, zero-sink
                // delivery drops the message (JS parity; no unbounded
                // growth after unsubscribe).
                it->second.buffered.push_back(json);
            }
            return;
        }
        sinksCopy = it->second.sinks;
    }
    // Invoke outside the lock: callbacks may re-enter via eco_port_send
    // or (from another thread) subscribe. A callback racing a concurrent
    // unsubscribe on another thread may still be invoked once after
    // unsubscribe returns (documented host contract).
    for (auto& [cb, user] : sinksCopy) {
        cb(json.c_str(), user);
    }
}

bool PortRuntime::hasPendingSends() {
    std::lock_guard<std::mutex> lock(pendingMutex_);
    return !pendingSends_.empty();
}

void PortRuntime::drainPendingSends() {
    while (true) {
        std::string name;
        std::string json;
        {
            std::lock_guard<std::mutex> lock(pendingMutex_);
            if (pendingSends_.empty()) return;
            name = std::move(pendingSends_.front().first);
            json = std::move(pendingSends_.front().second);
            pendingSends_.pop_front();
        }

        // Each queued send holds one pendingAsync ref (taken in
        // sendIncoming); release it once this item is processed,
        // whatever the outcome.
        struct AsyncRelease {
            ~AsyncRelease() { Scheduler::instance().decrementPendingAsync(); }
        } release;

        uint64_t decoderEnc = 0;
        uint64_t subsEnc = 0;
        {
            std::lock_guard<std::mutex> lock(portsMutex_);
            auto it = ports_.find(name);
            if (it == ports_.end() || !it->second.incoming) continue;
            decoderEnc = it->second.decoder;
            subsEnc = it->second.subs;
        }

        HPointer decoder = decodeHP(decoderEnc);
        HPointer subs = (subsEnc == 0) ? listNil() : decodeHP(subsEnc);
        HPointer payload = listNil();
        Elm::StackRootGuard guard({ &decoder, &subs, &payload });

        // Parse + decode on the eco thread. Decode failure is a hard crash
        // naming the port (JS Debug.crash 4 parity, plan Q5).
        HPointer jsonStr = allocStringFromUTF8(json);
        Elm::StackRootGuard strGuard(&jsonStr);
        HPtr result = Elm_Kernel_Json_runOnString(
            HPtr::fromBits(encodeHP(decoder)),
            HPtr::fromBits(encodeHP(jsonStr)));
        HPointer resultHP = decodeHP(result.toBits());
        if (!resultIsOk(resultHP)) {
            portCrash("trying to send an unexpected value through port '" +
                      name + "': " + json);
        }
        {
            void* okPtr = resolveHP(resultHP);
            payload = static_cast<Custom*>(okPtr)->values[0].p;
        }

        // Apply each subscribed (composed) tagger to the decoded payload
        // and push the message through the app's update cycle.
        HPointer current = subs;
        Elm::StackRootGuard loopGuard(&current);
        while (!alloc::isNil(current)) {
            void* cellPtr = resolveHP(current);
            if (!cellPtr) break;
            Cons* cell = static_cast<Cons*>(cellPtr);
            HPointer tagger = cell->head.p;
            HPointer next = cell->tail;
            Elm::StackRootGuard itemGuard(&tagger, &next);

            HPointer msg = Scheduler::callClosure1(tagger, payload);
            {
                Elm::StackRootGuard msgGuard(&msg);
                PlatformRuntime::instance().deliverToApp(msg);
            }
            current = next;
        }
    }
}

bool PortRuntime::sendIncoming(const char* name, const char* json) {
    if (name == nullptr || json == nullptr) return false;
    {
        std::lock_guard<std::mutex> lock(portsMutex_);
        auto it = ports_.find(name);
        if (it == ports_.end() || !it->second.registered ||
            !it->second.incoming) {
            return false;
        }
    }
    // Hold a pendingAsync ref per queued item BEFORE publishing it, so the
    // event loop cannot observe an empty queue + zero refs and exit while
    // a send is in flight.
    Scheduler::instance().incrementPendingAsync();
    {
        std::lock_guard<std::mutex> lock(pendingMutex_);
        pendingSends_.emplace_back(std::string(name), std::string(json));
    }
    Scheduler::instance().notifyWorkAvailableFromAsync();
    return true;
}

bool PortRuntime::subscribeOutgoing(const char* name, EcoPortCallback cb,
                                    void* user) {
    if (name == nullptr || cb == nullptr) return false;
    // First-subscriber flush: drain the pre-subscribe buffer COMPLETELY
    // before installing the sink. Concurrent deliveries keep appending to
    // the buffer while we drain (sinks is still empty), so the subscriber
    // observes strict FIFO order and is never invoked from two threads at
    // once during the handover.
    while (true) {
        std::vector<std::string> batch;
        {
            std::lock_guard<std::mutex> lock(portsMutex_);
            // Creates a placeholder entry for not-yet-registered ports so
            // hosts may subscribe before the program starts.
            PortInfo& info = ports_[name];
            if (info.everSubscribed || info.buffered.empty()) {
                info.sinks.emplace_back(cb, user);
                info.everSubscribed = true;
                return true;
            }
            batch.swap(info.buffered);
        }
        for (auto& json : batch) {
            cb(json.c_str(), user);
        }
    }
}

bool PortRuntime::unsubscribeOutgoing(const char* name, EcoPortCallback cb,
                                      void* user) {
    if (name == nullptr) return false;
    std::lock_guard<std::mutex> lock(portsMutex_);
    auto it = ports_.find(name);
    if (it == ports_.end()) return false;
    auto& sinks = it->second.sinks;
    for (auto sIt = sinks.begin(); sIt != sinks.end(); ++sIt) {
        if (sIt->first == cb && sIt->second == user) {
            sinks.erase(sIt);
            return true;
        }
    }
    return false;
}

int PortRuntime::portCount() {
    std::lock_guard<std::mutex> lock(portsMutex_);
    return static_cast<int>(registrationOrder_.size());
}

const char* PortRuntime::portName(int i) {
    std::lock_guard<std::mutex> lock(portsMutex_);
    if (i < 0 || i >= static_cast<int>(registrationOrder_.size())) {
        return nullptr;
    }
    // deque elements have stable addresses; the runtime never erases
    // registrations, so the returned pointer stays valid for the process
    // lifetime.
    return registrationOrder_[static_cast<size_t>(i)].c_str();
}

int PortRuntime::isIncoming(const char* name) {
    if (name == nullptr) return -1;
    std::lock_guard<std::mutex> lock(portsMutex_);
    auto it = ports_.find(name);
    if (it == ports_.end() || !it->second.registered) return -1;
    return it->second.incoming ? 1 : 0;
}

}  // namespace Elm::Platform

// ---------------------------------------------------------------------------
// C ABI
// ---------------------------------------------------------------------------
//
// These host-facing wrappers are defined here (so ecoc / EcoRunner / the test
// harness, which compile this file directly, resolve them) AND as strong
// definitions in embed/eco_embed.cpp. The duplication is deliberate: eco_port_*
// otherwise live only in EcoRuntimeStatic, which the Stage-D shared link hides
// from .dynsym via --exclude-libs, so a C host linking a produced .so/.node
// cannot resolve them (eco_app_* avoid this by living in the whole-archived,
// non-excluded EcoEmbedStatic). The embed-lib copies are the exported ones; we
// mark THESE weak so the strong embed definitions win wherever both archives
// are linked (the .so/.node link; eco-boot-native, which links both) with no
// duplicate-symbol error, while a lone weak definition still serves the
// compile-this-file-directly consumers. Not weak on Windows (no .so/.node
// there, so the two never coexist, and COFF weak support is limited).
#if defined(_WIN32)
#  define ECO_PORT_ABI_WEAK
#else
#  define ECO_PORT_ABI_WEAK __attribute__((weak))
#endif

using Elm::Platform::PortRuntime;

extern "C" {

ECO_PORT_ABI_WEAK int eco_port_send(const char* port, const char* json_utf8) {
    return PortRuntime::instance().sendIncoming(port, json_utf8) ? 0 : 1;
}

ECO_PORT_ABI_WEAK int eco_port_subscribe(const char* port,
                                         Elm::Platform::EcoPortCallback cb,
                                         void* user) {
    return PortRuntime::instance().subscribeOutgoing(port, cb, user) ? 0 : 1;
}

ECO_PORT_ABI_WEAK int eco_port_unsubscribe(const char* port,
                                           Elm::Platform::EcoPortCallback cb,
                                           void* user) {
    return PortRuntime::instance().unsubscribeOutgoing(port, cb, user) ? 0
                                                                       : 1;
}

ECO_PORT_ABI_WEAK int eco_port_count(void) {
    return PortRuntime::instance().portCount();
}

ECO_PORT_ABI_WEAK const char* eco_port_name(int i) {
    return PortRuntime::instance().portName(i);
}

ECO_PORT_ABI_WEAK int eco_port_is_incoming(const char* port) {
    return PortRuntime::instance().isIncoming(port);
}

}  // extern "C"
