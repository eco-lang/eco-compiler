//===- PortRuntime.cpp - Native Elm ports runtime ---------------------------===//
//
// The effect managers here depend on the values generated code puts in a
// port's effect leaves:
//   outgoing `port foo : payload -> Cmd msg`:
//     foo p  ==>  Fx_Leaf{home="foo", value = encoder(p)}
//     The payload is already a Json value; the manager only stringifies it.
//     A bytes port (PORT_008) has no encoder: the value is the Bytes p itself,
//     and the manager hands its bytes to the host as they are.
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
#include "allocator/RootedSlots.hpp"
#include "allocator/RuntimeExports.h"
#include "allocator/StringOps.hpp"
#include <cstdio>
#include <cstdlib>
#include <cstring>

using namespace Elm;
using namespace Elm::alloc;

// Json kernel functions, defined outside the runtime and resolved at link
// time. Declared here rather than included so that the runtime has no
// compile-time dependency on the kernel.
extern "C" HPtr Elm_Kernel_Json_runOnString(HPtr decoder, HPtr jsonString);
extern "C" HPtr Elm_Kernel_Json_encode(int64_t indent, HPtr value);
// Checks JSON text against a payload descriptor on any thread, without the Elm
// heap (JsonExports.cpp; PORT_009): 1 if it decodes, else 0 with a malloc'd
// message in `*problem`.
extern "C" int eco_json_check_payload(const char* schema, const char* json, char** problem);

namespace Elm::Platform {

namespace {

// Returns the 64-bit word that stores `h`.
inline uint64_t encodeHP(HPointer h) {
    union { HPointer hp; uint64_t val; } u;
    u.hp = h;
    return u.val;
}

// Returns the HPointer stored in the word `val`; the inverse of encodeHP.
inline HPointer decodeHP(uint64_t val) {
    union { HPointer hp; uint64_t val; } u;
    u.val = val;
    return u.hp;
}

// Returns the address of the heap object `h`, or null if `h` is an embedded
// constant.
inline void* resolveHP(HPointer h) {
    if (h.ptr_ind != 0) return nullptr;
    return Allocator::instance().resolve(h);
}

// Appends the elements of the boxed list `list` to `slots`, first to last. Does
// not allocate on the Elm heap.
void gatherList(HPointer list, Elm::alloc::RootedSlots& slots) {
    Elm::alloc::RootedListCursor cursor(list);
    Elm::Unboxable head;
    u8 kind;
    while (cursor.read(head, kind)) {
        slots.push(head.p);
        cursor.advance();
    }
}

// Returns a copy of the Elm string `s`; empty if `s` is an embedded constant.
std::string elmStringToStd(HPointer s) {
    void* ptr = resolveHP(s);
    if (!ptr) return std::string();
    return Elm::StringOps::toStdString(ptr);
}

// ---------------------------------------------------------------------------
// Port effect-manager evaluator closures
// ---------------------------------------------------------------------------

// Evaluates a port manager's init: returns a task that succeeds with the Empty
// constant, the state of every port manager.
void* portInitEvaluator(void* args[]) {
    (void)args;
    HPointer task = Scheduler::instance().taskSucceed(listNil());
    return reinterpret_cast<void*>(encodeHP(task));
}

// Evaluates a port manager's onSelfMsg (router, selfMsg, state): returns a
// task that succeeds with the state unchanged. Ports send no self messages.
void* portOnSelfMsgEvaluator(void* args[]) {
    uint64_t stateEnc = reinterpret_cast<uint64_t>(args[2]);
    HPointer task = Scheduler::instance().taskSucceed(decodeHP(stateEnc));
    return reinterpret_cast<void*>(encodeHP(task));
}

// Evaluates an outgoing port manager's onEffects: encodes each command's Json
// value as JSON text and passes it to deliverOutgoing, last first, then
// returns a task that succeeds with the state unchanged. Last first because
// Elm 0.19.1 hands a manager a batch's commands in reverse (PORT_005): its
// port delivers `Cmd.batch [ out 1, out 2 ]` as 2, then 1.
// Slot layout (1 capture + 4 call args):
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

    // Json_encode allocates; the values sit in rooted slots across it.
    Elm::StackRootGuard loopGuard(&state);
    Elm::alloc::RootedSlots values;
    gatherList(cmdList, values);
    for (size_t i = values.size(); i > 0; --i) {
        HPtr jsonStr = Elm_Kernel_Json_encode(
            0, HPtr::fromBits(encodeHP(values[i - 1])));
        std::string json = elmStringToStd(decodeHP(jsonStr.toBits()));
        PortRuntime::instance().deliverOutgoing(name, json);
    }

    HPointer task = Scheduler::instance().taskSucceed(state);
    return reinterpret_cast<void*>(encodeHP(task));
}

// Evaluates an outgoing bytes port manager's onEffects: passes the bytes of
// each command's Bytes value to deliverOutgoingBytes, last first, then
// returns a task that succeeds with the state unchanged. The slot layout is
// that of portOutgoingOnEffectsEvaluator.
//
// Nothing between taking a view of a value's bytes and the return of
// deliverOutgoingBytes allocates on the Elm heap, so no collection runs and
// the subscribers get a pointer into the value itself (PORT_008).
void* portOutgoingBytesOnEffectsEvaluator(void* args[]) {
    HPointer nameHP = decodeHP(reinterpret_cast<uint64_t>(args[0]));
    HPointer cmdList = decodeHP(reinterpret_cast<uint64_t>(args[2]));
    HPointer state = decodeHP(reinterpret_cast<uint64_t>(args[4]));

    std::string name = elmStringToStd(nameHP);

    Elm::StackRootGuard loopGuard(&state);
    Elm::alloc::RootedSlots values;
    gatherList(cmdList, values);
    for (size_t i = values.size(); i > 0; --i) {
        ByteBufferView view = byteBufferView(resolveBytesOrNull(values[i - 1]));
        PortRuntime::instance().deliverOutgoingBytes(name, view.data, view.length);
    }

    HPointer task = Scheduler::instance().taskSucceed(state);
    return reinterpret_cast<void*>(encodeHP(task));
}

// Evaluates an incoming port manager's onEffects: makes subList the port's
// subscriptions with setIncomingSubs, then returns a task that succeeds with
// the state unchanged.
// Slot layout (1 capture + 4 call args):
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

// Evaluates an outgoing port's cmdMap (taggers, value): returns `value`. A
// port command produces no message, so mapping it changes nothing.
void* outgoingPortMapEvaluator(void* args[]) {
    return args[1];
}

// Evaluates a composed tagger: with captures f and g and argument v
// (args[0], args[1], args[2]), returns f (g v).
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

// Evaluates an incoming port's subMap (f, g): returns a new closure that
// computes f (g v) for its argument v.
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

// Returns whether `result`, a Result from the Json kernel, is Ok. The Json
// kernel builds Ok with constructor 0 and Err with constructor 1.
bool resultIsOk(HPointer result) {
    void* ptr = resolveHP(result);
    if (!ptr) return false;
    return static_cast<Custom*>(ptr)->ctor == 0;
}

// Builds the effect-manager closures for the port `name`, incoming or
// outgoing, a bytes port if `bytes`. The map a port kind does not use (cmdMap
// for an incoming port, subMap for an outgoing one) is the Empty constant.
// Allocates, so it may collect.
PlatformRuntime::ManagerInfo buildPortManager(const std::string& name,
                                              bool incoming, bool bytes) {
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
                               : bytes  ? portOutgoingBytesOnEffectsEvaluator
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

// Prints `message` to stderr and aborts the process.
[[noreturn]] void portCrash(const std::string& message) {
    std::fprintf(stderr, "eco ports: %s\n", message.c_str());
    std::fflush(stderr);
    std::abort();
}

// Calls a lent bytes payload's release function, if it has one, once: at
// `fire`, or when it goes out of scope.
struct ReleaseOnExit {
    EcoPortRelease release;
    void* ctx;
    void fire() {
        if (release) release(ctx);
        release = nullptr;
    }
    ~ReleaseOnExit() { fire(); }
};

}  // namespace

// ---------------------------------------------------------------------------
// PortRuntime
// ---------------------------------------------------------------------------

PortRuntime& PortRuntime::instance() {
    // Leaked on purpose, so that it outlives any static destructor or thread
    // that might still use it at exit.
    static PortRuntime* runtime = new PortRuntime();
    return *runtime;
}

PortRuntime::PortRuntime() = default;

void PortRuntime::ensureRuntimeHooks() {
    // Called only on the eco thread, so plain members suffice.
    if (!hooksInstalled_) {
        hooksInstalled_ = true;
        Scheduler::instance().registerAsyncSource(
            []() { PortRuntime::instance().drainPendingSends(); },
            []() { return PortRuntime::instance().hasPendingSends(); });
    }

    // The slow form gives the thread a heap if it has none, which may start the first generation.
    RootSet& roots = Allocator::instance().getRootSetSlow();
    const uint64_t gen = Allocator::instance().heapGeneration();
    if (scannerGeneration_ == gen) return;
    if (scannerGeneration_ != 0) {
        // A heap reset (tests only): the decoders and tagger lists are values of the dead heap, and the ports
        // belong to the program that made them. A port keeps its host subscribers and its place in the
        // registration order, and may be registered again.
        std::lock_guard<std::mutex> lock(portsMutex_);
        for (auto& [name, info] : ports_) {
            (void)name;
            info.registered = false;
            info.decoder = 0;
            info.subs = 0;
        }
    }
    scannerGeneration_ = gen;
    roots.addExternalRootScanner(
        [this](RootSet::EvacuateFn evacuate) {
            std::lock_guard<std::mutex> lock(portsMutex_);
            for (auto& [name, info] : ports_) {
                (void)name;
                if (info.decoder) evacuate(info.decoder);
                if (info.subs) evacuate(info.subs);
            }
        }, "port-runtime");
}

void PortRuntime::noteRegistered(const std::string& name) {
    for (const std::string& n : registrationOrder_) {
        if (n == name) return;
    }
    registrationOrder_.push_back(name);
}

void PortRuntime::registerIncoming(const std::string& name,
                                   HPointer decoder, const std::string& schema) {
    ensureRuntimeHooks();

    // The port name is the effect-manager registry key, so a port named like
    // another manager would replace it. This check also catches a second
    // registration of the same port, whose manager is already registered.
    if (PlatformRuntime::instance().hasManager(name)) {
        portCrash("port name '" + name +
                  "' collides with an existing effect manager");
    }

    Elm::StackRootGuard decoderGuard(&decoder);
    PlatformRuntime::ManagerInfo info =
        buildPortManager(name, /*incoming=*/true, /*bytes=*/false);

    {
        std::lock_guard<std::mutex> lock(portsMutex_);
        PortInfo& p = ports_[name];
        if (p.registered) {
            portCrash("duplicate port name '" + name +
                      "' (port names must be unique per program)");
        }
        p.registered = true;
        p.incoming = true;
        p.bytes = false;
        p.decoder = encodeHP(decoder);
        p.schema = schema;
        noteRegistered(name);
    }

    PlatformRuntime::instance().registerManager(name, info);
}

void PortRuntime::registerIncomingBytes(const std::string& name) {
    ensureRuntimeHooks();

    if (PlatformRuntime::instance().hasManager(name)) {
        portCrash("port name '" + name +
                  "' collides with an existing effect manager");
    }

    PlatformRuntime::ManagerInfo info =
        buildPortManager(name, /*incoming=*/true, /*bytes=*/true);

    {
        std::lock_guard<std::mutex> lock(portsMutex_);
        PortInfo& p = ports_[name];
        if (p.registered) {
            portCrash("duplicate port name '" + name +
                      "' (port names must be unique per program)");
        }
        p.registered = true;
        p.incoming = true;
        p.bytes = true;
        p.decoder = 0;
        noteRegistered(name);
    }

    PlatformRuntime::instance().registerManager(name, info);
}

void PortRuntime::registerOutgoing(const std::string& name, bool bytes) {
    ensureRuntimeHooks();

    if (PlatformRuntime::instance().hasManager(name)) {
        portCrash("port name '" + name +
                  "' collides with an existing effect manager");
    }

    PlatformRuntime::ManagerInfo info =
        buildPortManager(name, /*incoming=*/false, bytes);

    {
        std::lock_guard<std::mutex> lock(portsMutex_);
        PortInfo& p = ports_[name];
        if (p.registered) {
            portCrash("duplicate port name '" + name +
                      "' (port names must be unique per program)");
        }
        p.registered = true;
        p.incoming = false;
        p.bytes = bytes;
        noteRegistered(name);
    }

    PlatformRuntime::instance().registerManager(name, info);
}

void PortRuntime::setIncomingSubs(const std::string& name,
                                  HPointer subsList) {
    ensureRuntimeHooks();   // the word stored below needs this generation's scanner
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
                // Buffering stops after the first subscriber, so a port
                // whose subscribers have all left does not grow without
                // bound.
                it->second.buffered.push_back(json);
            }
            return;
        }
        sinksCopy = it->second.sinks;
    }
    // Called outside the lock, because a callback may call back into this
    // registry.
    for (auto& [cb, user] : sinksCopy) {
        cb(json.c_str(), user);
    }
}

void PortRuntime::deliverOutgoingBytes(const std::string& name,
                                       const uint8_t* data, size_t length) {
    std::vector<std::pair<EcoPortBytesCallback, void*>> sinksCopy;
    {
        std::lock_guard<std::mutex> lock(portsMutex_);
        auto it = ports_.find(name);
        if (it == ports_.end()) return;
        if (it->second.byteSinks.empty()) {
            // As in deliverOutgoing. The buffer holds a copy, since the bytes
            // are valid only until the eco thread next allocates.
            if (!it->second.everSubscribedBytes) {
                it->second.bufferedBytes.emplace_back(data, data + length);
            }
            return;
        }
        sinksCopy = it->second.byteSinks;
    }
    for (auto& [cb, user] : sinksCopy) {
        cb(data, length, user);
    }
}

bool PortRuntime::hasPendingSends() {
    std::lock_guard<std::mutex> lock(pendingMutex_);
    return !pendingSends_.empty();
}

void PortRuntime::drainPendingSends() {
    while (true) {
        PendingSend item;
        {
            std::lock_guard<std::mutex> lock(pendingMutex_);
            if (pendingSends_.empty()) return;
            item = std::move(pendingSends_.front());
            pendingSends_.pop_front();
        }
        const std::string& name = item.name;

        HoldRelease release(item.hold);
        // A lent bytes payload goes back to the host however this item ends.
        ReleaseOnExit lent{item.release, item.ctx};

        uint64_t decoderEnc = 0;
        uint64_t subsEnc = 0;
        {
            std::lock_guard<std::mutex> lock(portsMutex_);
            auto it = ports_.find(name);
            // A port not registered in this heap generation is dropped, as is
            // a payload of the other kind (the port registered again as the
            // other kind after a heap reset).
            if (it == ports_.end() || !it->second.registered || !it->second.incoming ||
                it->second.bytes != item.bytes)
                continue;
            decoderEnc = it->second.decoder;
            subsEnc = it->second.subs;
        }

        HPointer decoder = decodeHP(decoderEnc);
        HPointer subs = (subsEnc == 0) ? listNil() : decodeHP(subsEnc);
        HPointer payload = listNil();
        Elm::StackRootGuard guard({ &decoder, &subs, &payload });

        if (item.bytes) {
            // The one copy of an incoming bytes payload (PORT_008).
            const uint8_t* data = item.release ? item.data : item.copy.data();
            payload = allocByteBuffer(data, item.length);
            lent.fire();
        } else {
            HPointer jsonStr = allocStringFromUTF8(item.json);
            Elm::StackRootGuard strGuard(&jsonStr);
            HPtr result = Elm_Kernel_Json_runOnString(
                HPtr::fromBits(encodeHP(decoder)),
                HPtr::fromBits(encodeHP(jsonStr)));
            HPointer resultHP = decodeHP(result.toBits());
            if (!resultIsOk(resultHP)) {
                portCrash("trying to send an unexpected value through port '" +
                          name + "': " + item.json);
            }
            // The Ok's field may hold an unboxed Int, Float or Char, as its
            // slot kind says. Taggers take boxed arguments, so box it.
            void* okPtr = resolveHP(resultHP);
            Custom* ok = static_cast<Custom*>(okPtr);
            const u32 payloadKind = ok->unboxed & 0x3;
            payload = Elm::alloc::boxElement(ok->values[0], payloadKind);
        }

        // The taggers last first, as Elm 0.19.1 applies a batch's
        // subscriptions to one port (PORT_005).
        Elm::alloc::RootedSlots taggers;
        gatherList(subs, taggers);
        for (size_t i = taggers.size(); i > 0; --i) {
            HPointer msg = Scheduler::callClosure1(taggers[i - 1], payload);
            Elm::StackRootGuard msgGuard(&msg);
            PlatformRuntime::instance().deliverToApp(msg);
        }
    }
}

std::string& PortRuntime::lastError() {
    thread_local std::string message;
    return message;
}

PortRuntime::SendResult PortRuntime::sendIncoming(const char* name, const char* json) {
    if (name == nullptr || json == nullptr) return SendResult::NotAPort;
    std::string schema;
    {
        std::lock_guard<std::mutex> lock(portsMutex_);
        auto it = ports_.find(name);
        if (it == ports_.end() || !it->second.registered ||
            !it->second.incoming || it->second.bytes) {
            return SendResult::NotAPort;
        }
        schema = it->second.schema;
    }
    // Checked here, on the sending thread, so that a host learns of a bad
    // value from this call rather than from the eco thread's abort (PORT_009).
    if (!schema.empty()) {
        char* problem = nullptr;
        if (!eco_json_check_payload(schema.c_str(), json, &problem)) {
            lastError() = std::string("Trying to send an unexpected type of value through port `") + name +
                          "`:\n" + (problem ? problem : "");
            std::free(problem);
            return SendResult::Rejected;
        }
    }
    PendingSend item;
    item.name = name;
    item.json = json;
    enqueueSend(std::move(item));
    return SendResult::Queued;
}

bool PortRuntime::sendIncomingBytes(const char* name, const uint8_t* data,
                                    size_t length, EcoPortRelease release,
                                    void* ctx) {
    if (name == nullptr || (data == nullptr && length != 0)) return false;
    {
        std::lock_guard<std::mutex> lock(portsMutex_);
        auto it = ports_.find(name);
        if (it == ports_.end() || !it->second.registered ||
            !it->second.incoming || !it->second.bytes) {
            return false;
        }
    }
    PendingSend item;
    item.name = name;
    item.bytes = true;
    item.length = length;
    if (release) {
        item.data = data;
        item.release = release;
        item.ctx = ctx;
    } else {
        item.copy.assign(data, data + length);
    }
    enqueueSend(std::move(item));
    return true;
}

void PortRuntime::enqueueSend(PendingSend item) {
    // Acquired before the item is queued, so the event loop never sees an
    // empty queue and no hold while a send is in flight.
    item.hold = Scheduler::instance().acquireHold(HoldKind::Port, "port.in");
    {
        std::lock_guard<std::mutex> lock(pendingMutex_);
        pendingSends_.push_back(std::move(item));
    }
    Scheduler::instance().notifyWorkAvailableFromAsync();
}

bool PortRuntime::subscribeOutgoing(const char* name, EcoPortCallback cb,
                                    void* user) {
    if (name == nullptr || cb == nullptr) return false;
    // The subscription is installed only when the buffer is found empty.
    // Until then deliveries on the eco thread keep appending to the buffer,
    // so this loop hands them over too, in order, and the eco thread does not
    // call cb while the flush runs.
    while (true) {
        std::vector<std::string> batch;
        {
            std::lock_guard<std::mutex> lock(portsMutex_);
            // Creates an unregistered entry for a port not registered yet.
            PortInfo& info = ports_[name];
            if (info.registered && info.bytes) return false;
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

bool PortRuntime::subscribeOutgoingBytes(const char* name,
                                         EcoPortBytesCallback cb, void* user) {
    if (name == nullptr || cb == nullptr) return false;
    // As subscribeOutgoing.
    while (true) {
        std::vector<std::vector<uint8_t>> batch;
        {
            std::lock_guard<std::mutex> lock(portsMutex_);
            PortInfo& info = ports_[name];
            if (info.registered && !info.bytes) return false;
            if (info.everSubscribedBytes || info.bufferedBytes.empty()) {
                info.byteSinks.emplace_back(cb, user);
                info.everSubscribedBytes = true;
                return true;
            }
            batch.swap(info.bufferedBytes);
        }
        for (auto& bytes : batch) {
            cb(bytes.data(), bytes.size(), user);
        }
    }
}

bool PortRuntime::unsubscribeOutgoingBytes(const char* name,
                                           EcoPortBytesCallback cb,
                                           void* user) {
    if (name == nullptr) return false;
    std::lock_guard<std::mutex> lock(portsMutex_);
    auto it = ports_.find(name);
    if (it == ports_.end()) return false;
    auto& sinks = it->second.byteSinks;
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
    // Valid for the rest of the process: registrations are never removed and
    // the deque does not move its elements as it grows.
    return registrationOrder_[static_cast<size_t>(i)].c_str();
}

int PortRuntime::isIncoming(const char* name) {
    if (name == nullptr) return -1;
    std::lock_guard<std::mutex> lock(portsMutex_);
    auto it = ports_.find(name);
    if (it == ports_.end() || !it->second.registered) return -1;
    return it->second.incoming ? 1 : 0;
}

int PortRuntime::isBytes(const char* name) {
    if (name == nullptr) return -1;
    std::lock_guard<std::mutex> lock(portsMutex_);
    auto it = ports_.find(name);
    if (it == ports_.end() || !it->second.registered) return -1;
    return it->second.bytes ? 1 : 0;
}

}  // namespace Elm::Platform

// ---------------------------------------------------------------------------
// C ABI
// ---------------------------------------------------------------------------
//
// These wrappers are defined here for programs that link this file without
// embed/eco_embed.cpp, and again, as strong definitions, in
// embed/eco_embed.cpp. A shared-library link hides EcoRuntimeStatic's symbols
// from the dynamic symbol table with --exclude-libs, so only the copies in
// EcoEmbedStatic can be exported to a C host. Marking these weak lets those
// strong copies win wherever both are linked, with no duplicate-symbol error.
// On Windows they are not weak: eco_embed.cpp defines no copies there.

// The attribute that makes the C ABI definitions below weak, or nothing.
#if defined(_WIN32)
#  define ECO_PORT_ABI_WEAK
#else
#  define ECO_PORT_ABI_WEAK __attribute__((weak))
#endif

using Elm::Platform::PortRuntime;

extern "C" {

ECO_PORT_ABI_WEAK int eco_port_send(const char* port, const char* json_utf8) {
    switch (PortRuntime::instance().sendIncoming(port, json_utf8)) {
        case PortRuntime::SendResult::Queued: return 0;
        case PortRuntime::SendResult::Rejected: return 2;
        default: return 1;
    }
}

ECO_PORT_ABI_WEAK const char* eco_last_error(void) {
    return PortRuntime::lastError().c_str();
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

ECO_PORT_ABI_WEAK int eco_port_send_bytes(const char* port,
                                          const uint8_t* data, size_t length,
                                          Elm::Platform::EcoPortRelease release,
                                          void* ctx) {
    return PortRuntime::instance().sendIncomingBytes(port, data, length,
                                                     release, ctx)
               ? 0
               : 1;
}

ECO_PORT_ABI_WEAK int eco_port_subscribe_bytes(
    const char* port, Elm::Platform::EcoPortBytesCallback cb, void* user) {
    return PortRuntime::instance().subscribeOutgoingBytes(port, cb, user) ? 0
                                                                          : 1;
}

ECO_PORT_ABI_WEAK int eco_port_unsubscribe_bytes(
    const char* port, Elm::Platform::EcoPortBytesCallback cb, void* user) {
    return PortRuntime::instance().unsubscribeOutgoingBytes(port, cb, user)
               ? 0
               : 1;
}

ECO_PORT_ABI_WEAK int eco_port_is_bytes(const char* port) {
    return PortRuntime::instance().isBytes(port);
}

}  // extern "C"
