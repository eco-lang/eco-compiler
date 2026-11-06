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
// Each manager's onEffects captures its port's handle, the PortInfo*, as an
// unboxed Int (PORT_011), so dispatch never looks a port up by name.
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
#include <cstddef>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <new>

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

// A refcounted, immutable copy of a payload's bytes (PORT_010): one malloc'd
// block, freed by the last `eco_owned_unref`. It never touches the Elm heap, so
// it may be used and released on any thread.
struct eco_owned_bytes {
    std::atomic<size_t> refs;
    size_t size;
    uint8_t bytes[1];  // `size` bytes; at least one is allocated.
};

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

// Returns the PortKindCode that a registration with these flags gives.
int kindCode(bool registered, bool incoming, bool bytes) {
    if (!registered) return kPortUnregistered;
    if (incoming) return bytes ? kPortInBytes : kPortInJson;
    return bytes ? kPortOutBytes : kPortOutJson;
}

// Sets `p.kind` from its flags. Requires `portsMutex_`.
void publishKind(PortInfo& p) {
    p.kind.store(kindCode(p.registered, p.incoming, p.bytes), std::memory_order_release);
}

// Set while deliverOutgoing or deliverOutgoingBytes calls subscribers on the eco
// thread, the one place an emit may write straight into the heap (PORT_010).
thread_local bool t_inHostCallback = false;
// Set while a fill function runs, so that an emit inside one is refused.
thread_local bool t_inFill = false;

// The scope in which the eco thread calls subscribers: marks the thread as in
// a host callback, and forbids collections (HEAP_083).
class HostCallbackScope {
public:
    HostCallbackScope() : saved_(t_inHostCallback) { t_inHostCallback = true; }
    ~HostCallbackScope() { t_inHostCallback = saved_; }
    HostCallbackScope(const HostCallbackScope&) = delete;
    HostCallbackScope& operator=(const HostCallbackScope&) = delete;
private:
    bool saved_;
    NoCollectScope noCollect_;
};

// Marks the thread as running a fill function for its lifetime.
class FillScope {
public:
    FillScope() { t_inFill = true; }
    ~FillScope() { t_inFill = false; }
    FillScope(const FillScope&) = delete;
    FillScope& operator=(const FillScope&) = delete;
};

// Returns the port handle an onEffects closure captured as an unboxed Int.
inline PortInfo* capturedPort(void* arg) {
    return reinterpret_cast<PortInfo*>(arg);
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
//   args[0] = the port's handle (captured unboxed Int)
//   args[1] = router (unused)
//   args[2] = cmdList — each element is an already-encoded Json value
//   args[3] = subList (unused; outgoing ports have no subscriptions)
//   args[4] = state
void* portOutgoingOnEffectsEvaluator(void* args[]) {
    PortInfo* port = capturedPort(args[0]);
    HPointer cmdList = decodeHP(reinterpret_cast<uint64_t>(args[2]));
    HPointer state = decodeHP(reinterpret_cast<uint64_t>(args[4]));

    // Json_encode allocates; the values sit in rooted slots across it.
    Elm::StackRootGuard loopGuard(&state);
    Elm::alloc::RootedSlots values;
    gatherList(cmdList, values);
    for (size_t i = values.size(); i > 0; --i) {
        HPtr jsonStr = Elm_Kernel_Json_encode(
            0, HPtr::fromBits(encodeHP(values[i - 1])));
        std::string json = elmStringToStd(decodeHP(jsonStr.toBits()));
        PortRuntime::instance().deliverOutgoing(port, json);
    }

    HPointer task = Scheduler::instance().taskSucceed(state);
    return reinterpret_cast<void*>(encodeHP(task));
}

// Evaluates an outgoing bytes port manager's onEffects: passes the bytes of
// each command's Bytes value to deliverOutgoingBytes, last first, then
// returns a task that succeeds with the state unchanged. The slot layout is
// that of portOutgoingOnEffectsEvaluator.
//
// Nothing collects between taking a view of a value's bytes and the return of
// deliverOutgoingBytes (HEAP_083; an emit made by a subscriber allocates
// without collecting), so the subscribers get a pointer into the value itself
// (PORT_008).
void* portOutgoingBytesOnEffectsEvaluator(void* args[]) {
    PortInfo* port = capturedPort(args[0]);
    HPointer cmdList = decodeHP(reinterpret_cast<uint64_t>(args[2]));
    HPointer state = decodeHP(reinterpret_cast<uint64_t>(args[4]));

    Elm::StackRootGuard loopGuard(&state);
    Elm::alloc::RootedSlots values;
    gatherList(cmdList, values);
    for (size_t i = values.size(); i > 0; --i) {
        ByteBufferView view = byteBufferView(resolveBytesOrNull(values[i - 1]));
        PortRuntime::instance().deliverOutgoingBytes(port, view.data, view.length);
    }

    HPointer task = Scheduler::instance().taskSucceed(state);
    return reinterpret_cast<void*>(encodeHP(task));
}

// Evaluates an incoming port manager's onEffects: makes subList the port's
// subscriptions with setIncomingSubs, then returns a task that succeeds with
// the state unchanged.
// Slot layout (1 capture + 4 call args):
//   args[0] = the port's handle (captured unboxed Int)
//   args[1] = router (unused)
//   args[2] = cmdList (unused; incoming ports have no commands)
//   args[3] = subList — current composed taggers (one per active Sub)
//   args[4] = state
void* portIncomingOnEffectsEvaluator(void* args[]) {
    PortInfo* port = capturedPort(args[0]);
    HPointer subList = decodeHP(reinterpret_cast<uint64_t>(args[3]));
    HPointer state = decodeHP(reinterpret_cast<uint64_t>(args[4]));

    PortRuntime::instance().setIncomingSubs(port, subList);

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

// Builds the effect-manager closures for `port`, incoming or outgoing, a bytes
// port if `bytes`. The map a port kind does not use (cmdMap for an incoming
// port, subMap for an outgoing one) is the Empty constant. Allocates, so it may
// collect.
PlatformRuntime::ManagerInfo buildPortManager(PortInfo* port,
                                              bool incoming, bool bytes) {
    HPointer initCl = listNil();
    HPointer onEffectsCl = listNil();
    HPointer onSelfMsgCl = listNil();
    HPointer mapCl = listNil();
    Elm::StackRootGuard guard(
        { &initCl, &onEffectsCl, &onSelfMsgCl, &mapCl });

    initCl = allocClosure(portInitEvaluator, 0);
    onSelfMsgCl = allocClosure(portOnSelfMsgEvaluator, 3);

    // onEffects: 1 captured slot (the port's handle) + 4 call args.
    onEffectsCl = allocClosure(incoming ? portIncomingOnEffectsEvaluator
                               : bytes  ? portOutgoingBytesOnEffectsEvaluator
                                        : portOutgoingOnEffectsEvaluator,
                               5);
    if (void* clPtr = resolveHP(onEffectsCl)) {
        closureCapture(clPtr, unboxedInt(static_cast<i64>(reinterpret_cast<intptr_t>(port))),
                       Elm::PK_Int);
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

// The release function of the buffers an emit fills off the heap.
void freeRelease(void* p) {
    std::free(p);
}

// Returns whether a Bytes value of `length` bytes takes the large form
// (HEAP_026), as `alloc::allocByteBuffer` decides.
bool isLargeLength(size_t length) {
    const size_t total = (sizeof(ByteBuffer) + length + 7) & ~static_cast<size_t>(7);
    return total >= Allocator::instance().getLargeObjectThreshold();
}

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

PortInfo& PortRuntime::entryLocked(const std::string& name) {
    PortInfo& p = ports_[name];
    if (p.name.empty()) p.name = name;
    return p;
}

void PortRuntime::ensureRuntimeHooks() {
    // Called only on the eco thread, so plain members suffice.
    if (!hooksInstalled_) {
        hooksInstalled_ = true;
        Scheduler::instance().registerAsyncSource(
            []() { PortRuntime::instance().drainPendingSends(); },
            []() { return PortRuntime::instance().hasPendingSends(); });
        Scheduler::instance().addStopHook(&PortRuntime::dropPendingAtStop);
    }

    // The slow form gives the thread a heap if it has none, which may start the first generation.
    RootSet& roots = Allocator::instance().getRootSetSlow();
    const uint64_t gen = Allocator::instance().heapGeneration();
    if (scannerGeneration_ == gen) return;
    if (scannerGeneration_ != 0) {
        // A heap reset (tests only): the decoders and tagger lists are values of the dead heap, and the ports
        // belong to the program that made them. A port keeps its host subscribers, its handle and its place in
        // the registration order, and may be registered again. Queued values an emit built are skipped by the
        // drain and the scanner, which compare generations.
        std::lock_guard<std::mutex> lock(portsMutex_);
        for (auto& [name, info] : ports_) {
            (void)name;
            info.registered = false;
            info.decoder = 0;
            info.subs = 0;
            publishKind(info);
        }
    }
    scannerGeneration_ = gen;
    roots.addExternalRootScanner(
        [this](RootSet::EvacuateFn evacuate) {
            {
                std::lock_guard<std::mutex> lock(portsMutex_);
                for (auto& [name, info] : ports_) {
                    (void)name;
                    if (info.decoder) evacuate(info.decoder);
                    if (info.subs) evacuate(info.subs);
                }
            }
            // Not nested in portsMutex_ (PORT_010).
            std::lock_guard<std::mutex> lock(pendingMutex_);
            const uint64_t g = Allocator::instance().heapGeneration();
            for (PendingSend& item : pendingSends_) {
                if (item.kind == PendingSend::Kind::Heap && item.generation == g) evacuate(item.value);
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
    reopenQueue();

    // The port name is the effect-manager registry key, so a port named like
    // another manager would replace it. This check also catches a second
    // registration of the same port, whose manager is already registered.
    if (PlatformRuntime::instance().hasManager(name)) {
        portCrash("port name '" + name +
                  "' collides with an existing effect manager");
    }

    PortInfo* port = get(name.c_str());
    Elm::StackRootGuard decoderGuard(&decoder);
    PlatformRuntime::ManagerInfo info =
        buildPortManager(port, /*incoming=*/true, /*bytes=*/false);

    {
        std::lock_guard<std::mutex> lock(portsMutex_);
        PortInfo& p = *port;
        if (p.registered) {
            portCrash("duplicate port name '" + name +
                      "' (port names must be unique per program)");
        }
        p.registered = true;
        p.incoming = true;
        p.bytes = false;
        p.decoder = encodeHP(decoder);
        p.schema = schema;
        publishKind(p);
        noteRegistered(name);
    }

    PlatformRuntime::instance().registerManager(name, info);
}

void PortRuntime::registerIncomingBytes(const std::string& name) {
    ensureRuntimeHooks();
    reopenQueue();

    if (PlatformRuntime::instance().hasManager(name)) {
        portCrash("port name '" + name +
                  "' collides with an existing effect manager");
    }

    PortInfo* port = get(name.c_str());
    PlatformRuntime::ManagerInfo info =
        buildPortManager(port, /*incoming=*/true, /*bytes=*/true);

    {
        std::lock_guard<std::mutex> lock(portsMutex_);
        PortInfo& p = *port;
        if (p.registered) {
            portCrash("duplicate port name '" + name +
                      "' (port names must be unique per program)");
        }
        p.registered = true;
        p.incoming = true;
        p.bytes = true;
        p.decoder = 0;
        publishKind(p);
        noteRegistered(name);
    }

    PlatformRuntime::instance().registerManager(name, info);
}

void PortRuntime::registerOutgoing(const std::string& name, bool bytes) {
    ensureRuntimeHooks();
    reopenQueue();

    if (PlatformRuntime::instance().hasManager(name)) {
        portCrash("port name '" + name +
                  "' collides with an existing effect manager");
    }

    PortInfo* port = get(name.c_str());
    PlatformRuntime::ManagerInfo info =
        buildPortManager(port, /*incoming=*/false, bytes);

    {
        std::lock_guard<std::mutex> lock(portsMutex_);
        PortInfo& p = *port;
        if (p.registered) {
            portCrash("duplicate port name '" + name +
                      "' (port names must be unique per program)");
        }
        p.registered = true;
        p.incoming = false;
        p.bytes = bytes;
        publishKind(p);
        noteRegistered(name);
    }

    PlatformRuntime::instance().registerManager(name, info);
}

void PortRuntime::setIncomingSubs(PortInfo* port, HPointer subsList) {
    ensureRuntimeHooks();   // the word stored below needs this generation's scanner
    std::lock_guard<std::mutex> lock(portsMutex_);
    if (!port || !port->incoming) return;
    port->subs = encodeHP(subsList);
}

void PortRuntime::deliverOutgoing(PortInfo* port, const std::string& json) {
    // Declared first, so that the references it holds, and any `destroy` they
    // run, go after the callback scope below has ended.
    std::vector<std::shared_ptr<PortSink>> sinksCopy;
    {
        std::lock_guard<std::mutex> lock(portsMutex_);
        if (port->sinks.empty()) {
            if (!port->everSubscribed) {
                // Buffering stops after the first subscriber, so a port
                // whose subscribers have all left does not grow without
                // bound.
                port->buffered.push_back(json);
            }
            return;
        }
        sinksCopy = port->sinks;
    }
    // Called outside the lock, because a callback may call back into this
    // registry, and with no collection allowed (HEAP_083).
    HostCallbackScope scope;
    for (const auto& sink : sinksCopy) {
        sink->json(json.c_str(), sink->user);
    }
}

void PortRuntime::deliverOutgoingBytes(PortInfo* port, const uint8_t* data, size_t length) {
    std::vector<std::shared_ptr<PortSink>> sinksCopy;
    {
        std::lock_guard<std::mutex> lock(portsMutex_);
        if (port->byteSinks.empty()) {
            // As in deliverOutgoing. The buffer holds a copy, since the bytes
            // are valid only until the eco thread next collects.
            if (!port->everSubscribedBytes) {
                port->bufferedBytes.emplace_back(data, data + length);
            }
            return;
        }
        sinksCopy = port->byteSinks;
    }
    HostCallbackScope scope;
    const eco_borrowed_bytes borrowed{length ? data : nullptr, length};
    for (const auto& sink : sinksCopy) {
        if (sink->kind == PortSink::Borrowed) {
            sink->borrowed(&borrowed, sink->user);
        } else {
            sink->interim(data, length, sink->user);
        }
    }
}

bool PortRuntime::hasPendingSends() {
    std::lock_guard<std::mutex> lock(pendingMutex_);
    return !pendingSends_.empty();
}

void PortRuntime::drainPendingSends() {
    if (testCollectAtDrain_.exchange(false)) {
        uint64_t before = 0;
        {
            std::lock_guard<std::mutex> lock(pendingMutex_);
            for (const PendingSend& item : pendingSends_) {
                if (item.kind == PendingSend::Kind::Heap) {
                    before = item.value;
                    break;
                }
            }
        }
        Allocator::instance().minorGC();
        Allocator::instance().majorGC();
        uint64_t after = 0;
        {
            std::lock_guard<std::mutex> lock(pendingMutex_);
            for (const PendingSend& item : pendingSends_) {
                if (item.kind == PendingSend::Kind::Heap) {
                    after = item.value;
                    break;
                }
            }
        }
        if (before == 0 || before == after) {
            portCrash("port test: queued heap value did not move");
        }
    }

    // Only what is queued now: an item queued while these run waits for the
    // next call, so that a port ping-pong cannot keep the event loop here.
    size_t budget;
    {
        std::lock_guard<std::mutex> lock(pendingMutex_);
        budget = pendingSends_.size();
    }
    while (budget-- > 0) {
        PendingSend item;
        {
            std::lock_guard<std::mutex> lock(pendingMutex_);
            if (pendingSends_.empty()) return;
            item = std::move(pendingSends_.front());
            pendingSends_.pop_front();
        }
        PortInfo* port = item.port;

        HoldRelease release(item.hold);
        // A lent bytes payload goes back to the host however this item ends.
        ReleaseOnExit lent{item.release, item.ctx};

        const bool wantBytes = item.kind != PendingSend::Kind::Json;
        uint64_t decoderEnc = 0;
        uint64_t subsEnc = 0;
        {
            std::lock_guard<std::mutex> lock(portsMutex_);
            // A port not registered in this heap generation is dropped, as is
            // a payload of the other kind (the port registered again as the
            // other kind after a heap reset).
            if (!port->registered || !port->incoming || port->bytes != wantBytes)
                continue;
            decoderEnc = port->decoder;
            subsEnc = port->subs;
        }
        if (item.kind == PendingSend::Kind::Heap &&
            item.generation != Allocator::instance().heapGeneration())
            continue;

        HPointer decoder = decodeHP(decoderEnc);
        HPointer subs = (subsEnc == 0) ? listNil() : decodeHP(subsEnc);
        HPointer payload = listNil();
        Elm::StackRootGuard guard({ &decoder, &subs, &payload });

        if (item.kind == PendingSend::Kind::Heap) {
            // The value an emit built (PORT_010). It left the scanner's view
            // when it was popped, and is rooted from here on; nothing has
            // allocated since.
            payload = decodeHP(item.value);
        } else if (item.kind == PendingSend::Kind::Bytes) {
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
                          port->name + "': " + item.json);
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
    // What was queued meanwhile is processed on the event loop's next turn.
    if (hasPendingSends()) Scheduler::instance().notifyWorkAvailableFromAsync();
}

void PortRuntime::reopenQueue() {
    std::lock_guard<std::mutex> lock(pendingMutex_);
    stopped_ = false;
}

void PortRuntime::dropPendingAtStop() {
    PortRuntime& self = instance();
    std::deque<PendingSend> dropped;
    {
        // From here on nothing is queued (enqueueSend), so nothing can be left behind unreleased.
        std::lock_guard<std::mutex> lock(self.pendingMutex_);
        self.stopped_ = true;
        dropped.swap(self.pendingSends_);
    }
    for (PendingSend& item : dropped) {
        HoldRelease release(item.hold);
        ReleaseOnExit lent{item.release, item.ctx};
    }
}

std::string& PortRuntime::lastError() {
    thread_local std::string message;
    return message;
}

PortInfo* PortRuntime::get(const char* name) {
    if (name == nullptr) return nullptr;
    std::lock_guard<std::mutex> lock(portsMutex_);
    return &entryLocked(name);
}

int PortRuntime::kindOf(const PortInfo* port) {
    return port ? port->kind.load(std::memory_order_acquire) : -1;
}

PortRuntime::SendResult PortRuntime::sendIncoming(PortInfo* port, const char* json) {
    if (port == nullptr || json == nullptr) return SendResult::NotAPort;
    if (kindOf(port) != kPortInJson) return SendResult::NotAPort;
    std::string schema;
    {
        std::lock_guard<std::mutex> lock(portsMutex_);
        schema = port->schema;
    }
    // Checked here, on the sending thread, so that a host learns of a bad
    // value from this call rather than from the eco thread's abort (PORT_009).
    if (!schema.empty()) {
        char* problem = nullptr;
        if (!eco_json_check_payload(schema.c_str(), json, &problem)) {
            lastError() = std::string("Trying to send an unexpected type of value through port `") +
                          port->name + "`:\n" + (problem ? problem : "");
            std::free(problem);
            return SendResult::Rejected;
        }
    }
    PendingSend item;
    item.kind = PendingSend::Kind::Json;
    item.port = port;
    item.json = json;
    return enqueueSend(std::move(item)) ? SendResult::Queued : SendResult::NotAPort;
}

PortRuntime::SendResult PortRuntime::sendIncoming(const char* name, const char* json) {
    if (name == nullptr || json == nullptr) return SendResult::NotAPort;
    return sendIncoming(get(name), json);
}

bool PortRuntime::sendIncomingBytes(PortInfo* port, const uint8_t* data,
                                    size_t length, EcoPortRelease release,
                                    void* ctx) {
    if (port == nullptr || (data == nullptr && length != 0)) return false;
    if (kindOf(port) != kPortInBytes) return false;
    PendingSend item;
    item.kind = PendingSend::Kind::Bytes;
    item.port = port;
    item.length = length;
    if (release) {
        item.data = data;
        item.release = release;
        item.ctx = ctx;
    } else {
        item.copy.assign(data, data + length);
    }
    return enqueueSend(std::move(item));
}

bool PortRuntime::sendIncomingBytes(const char* name, const uint8_t* data,
                                    size_t length, EcoPortRelease release,
                                    void* ctx) {
    if (name == nullptr) return false;
    return sendIncomingBytes(get(name), data, length, release, ctx);
}

int PortRuntime::emit(PortInfo* port, size_t capacity, EcoBytesFill fill, void* user) {
    if (port == nullptr || fill == nullptr || capacity > UINT32_MAX) return kEmitNotAPort;
    if (t_inFill) return kEmitNested;
    if (kindOf(port) != kPortInBytes) return kEmitNotAPort;

    // The bytes to queue off the heap: a malloc'd buffer of at least `n` bytes,
    // which `sendIncomingBytes` lends and the eco thread copies in.
    auto queueOffHeap = [&](uint8_t* buf, size_t n, bool fellBack) -> int {
        if (!sendIncomingBytes(port, buf, n, &freeRelease, buf)) {
            // Only when the program stopped, or (tests only) its heap was reset, since the check above.
            std::free(buf);
            return kEmitNotAPort;
        }
        (fellBack ? emitStats_.fallback : emitStats_.offHeap).fetch_add(1, std::memory_order_relaxed);
        return kEmitQueued;
    };

    bool fellBack = false;
    // The thread-local is set only on the eco thread; the heap check is a backstop for a delivery made on a
    // thread with no heap (tests), where only the off-heap path is possible.
    if (t_inHostCallback && Allocator::instance().getCurrentThreadHeap() != nullptr) {
        // The direct path (PORT_010): the bytes are written into a new Bytes
        // value allocated without collecting, and nothing collects until the
        // value is queued, so it stays where it is.
        const bool forced = testForceOffHeap_.load();
        NoCollectBytes blank{hpFromBits(0), nullptr};
        if (capacity > 0 && !forced) {
            blank = Allocator::instance().tryAllocByteBufferNoCollect(capacity);
        }
        if (!forced && (capacity == 0 || blank.bytes != nullptr)) {
            size_t n;
            {
                FillScope filling;
                n = fill(blank.bytes, capacity, user);
            }
            if (n == kFillCancel) return kEmitCancelled;
            if (n > capacity) {
#if ECO_HEAP_VALIDATE
                portCrash("a fill function reported " + std::to_string(n) + " bytes written into " +
                          std::to_string(capacity) + " on port '" + port->name + "'");
#endif
                return kEmitOverrun;
            }

            // The form allocByteBuffer(n) would give the value.
            HPointer value = emptyBytes();
            if (n == capacity && n > 0) {
                value = blank.hp;
            } else if (n > 0) {
                if (isLargeLength(capacity) && isLargeLength(n) && 2 * n >= capacity) {
                    // A large header's size is only the logical length; the
                    // header has not survived a collection, so it may change.
                    static_cast<LargeByteHeader*>(Allocator::instance().resolve(blank.hp))
                        ->header.size = static_cast<u32>(n);
                    value = blank.hp;
                    emitStats_.shrunk.fetch_add(1, std::memory_order_relaxed);
                } else {
                    NoCollectBytes exact = Allocator::instance().tryAllocByteBufferNoCollect(n);
                    if (exact.bytes == nullptr) {
                        uint8_t* buf = static_cast<uint8_t*>(std::malloc(n));
                        if (!buf) return kEmitNoMemory;
                        std::memcpy(buf, blank.bytes, n);
                        return queueOffHeap(buf, n, /*fellBack=*/true);
                    }
                    std::memcpy(exact.bytes, blank.bytes, n);
                    value = exact.hp;
                }
            }

            PendingSend item;
            item.kind = PendingSend::Kind::Heap;
            item.port = port;
            item.value = encodeHP(value);
            item.generation = Allocator::instance().heapGeneration();
            // Refused only once the program has stopped; the value is then garbage.
            if (!enqueueSend(std::move(item))) return kEmitNotAPort;
            emitStats_.direct.fetch_add(1, std::memory_order_relaxed);
            return kEmitQueued;
        }
        fellBack = true;
    }

    // The off-heap path.
    uint8_t* buf = static_cast<uint8_t*>(std::malloc(capacity > 0 ? capacity : 1));
    if (!buf) return kEmitNoMemory;
    size_t n;
    {
        FillScope filling;
        n = fill(capacity > 0 ? buf : nullptr, capacity, user);
    }
    if (n == kFillCancel) {
        std::free(buf);
        return kEmitCancelled;
    }
    if (n > capacity) {
        std::free(buf);
#if ECO_HEAP_VALIDATE
        portCrash("a fill function reported " + std::to_string(n) + " bytes written into " +
                  std::to_string(capacity) + " on port '" + port->name + "'");
#endif
        return kEmitOverrun;
    }
    return queueOffHeap(buf, n, fellBack);
}

bool PortRuntime::enqueueSend(PendingSend item) {
    // Acquired before the item is queued, so the event loop never sees an
    // empty queue and no hold while a send is in flight.
    item.hold = Scheduler::instance().acquireHold(HoldKind::Port, "port.in");
    {
        std::lock_guard<std::mutex> lock(pendingMutex_);
        if (!stopped_) {
            pendingSends_.push_back(std::move(item));
            item.hold = kNoHold;
        }
    }
    if (item.hold != kNoHold) {
        // Refused: the program has stopped (dropPendingAtStop). Nothing was queued, and a lent buffer stays
        // with the caller.
        Scheduler::instance().releaseHold(item.hold);
        return false;
    }
    Scheduler::instance().notifyWorkAvailableFromAsync();
    return true;
}

bool PortRuntime::subscribeOutgoing(PortInfo* port, EcoPortCallback cb, void* user,
                                    EcoDestroyFn destroy) {
    if (port == nullptr || cb == nullptr) return false;
    auto sink = std::make_shared<PortSink>();
    sink->kind = PortSink::Json;
    sink->json = cb;
    sink->user = user;
    // The subscription is installed only when the buffer is found empty.
    // Until then deliveries on the eco thread keep appending to the buffer,
    // so this loop hands them over too, in order, and the eco thread does not
    // call cb while the flush runs.
    while (true) {
        std::vector<std::string> batch;
        {
            std::lock_guard<std::mutex> lock(portsMutex_);
            PortInfo& info = *port;
            if (info.registered && info.bytes) return false;
            if (info.everSubscribed || info.buffered.empty()) {
                sink->destroy = destroy;
                info.sinks.push_back(std::move(sink));
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

bool PortRuntime::subscribeOutgoing(const char* name, EcoPortCallback cb, void* user) {
    if (name == nullptr) return false;
    return subscribeOutgoing(get(name), cb, user, nullptr);
}

bool PortRuntime::unsubscribeOutgoing(PortInfo* port, EcoPortCallback cb, void* user) {
    if (port == nullptr) return false;
    // Dropped after the lock, so that its `destroy` runs with no lock held.
    std::shared_ptr<PortSink> victim;
    {
        std::lock_guard<std::mutex> lock(portsMutex_);
        auto& sinks = port->sinks;
        for (auto it = sinks.begin(); it != sinks.end(); ++it) {
            if ((*it)->json == cb && (*it)->user == user) {
                victim = std::move(*it);
                sinks.erase(it);
                break;
            }
        }
    }
    return victim != nullptr;
}

bool PortRuntime::unsubscribeOutgoing(const char* name, EcoPortCallback cb, void* user) {
    if (name == nullptr) return false;
    return unsubscribeOutgoing(get(name), cb, user);
}

bool PortRuntime::subscribeBytesSink(PortInfo* port, std::shared_ptr<PortSink> sink,
                                     EcoDestroyFn destroy) {
    // As subscribeOutgoing.
    while (true) {
        std::vector<std::vector<uint8_t>> batch;
        {
            std::lock_guard<std::mutex> lock(portsMutex_);
            PortInfo& info = *port;
            if (info.registered && !info.bytes) return false;
            if (info.everSubscribedBytes || info.bufferedBytes.empty()) {
                sink->destroy = destroy;
                info.byteSinks.push_back(std::move(sink));
                info.everSubscribedBytes = true;
                return true;
            }
            batch.swap(info.bufferedBytes);
        }
        // A flush runs on the subscribing thread, never as a host callback of
        // the eco thread, so an emit made here takes the off-heap path.
        for (auto& bytes : batch) {
            if (sink->kind == PortSink::Borrowed) {
                const eco_borrowed_bytes borrowed{bytes.empty() ? nullptr : bytes.data(), bytes.size()};
                sink->borrowed(&borrowed, sink->user);
            } else {
                sink->interim(bytes.data(), bytes.size(), sink->user);
            }
        }
    }
}

bool PortRuntime::unsubscribeBytesSink(PortInfo* port, PortSink::Kind kind, const void* cb, void* user) {
    if (port == nullptr) return false;
    std::shared_ptr<PortSink> victim;
    {
        std::lock_guard<std::mutex> lock(portsMutex_);
        auto& sinks = port->byteSinks;
        for (auto it = sinks.begin(); it != sinks.end(); ++it) {
            const PortSink& s = **it;
            const void* scb = s.kind == PortSink::Borrowed ? reinterpret_cast<const void*>(s.borrowed)
                                                            : reinterpret_cast<const void*>(s.interim);
            if (s.kind == kind && scb == cb && s.user == user) {
                victim = std::move(*it);
                sinks.erase(it);
                break;
            }
        }
    }
    return victim != nullptr;
}

bool PortRuntime::subscribeOutgoingBytes(const char* name,
                                         EcoPortBytesCallback cb, void* user) {
    if (name == nullptr || cb == nullptr) return false;
    auto sink = std::make_shared<PortSink>();
    sink->kind = PortSink::Interim;
    sink->interim = cb;
    sink->user = user;
    return subscribeBytesSink(get(name), std::move(sink), nullptr);
}

bool PortRuntime::unsubscribeOutgoingBytes(const char* name,
                                           EcoPortBytesCallback cb,
                                           void* user) {
    if (name == nullptr) return false;
    return unsubscribeBytesSink(get(name), PortSink::Interim, reinterpret_cast<const void*>(cb), user);
}

bool PortRuntime::subscribeOutgoingBorrowed(PortInfo* port, EcoPortBorrowedCallback cb, void* user,
                                            EcoDestroyFn destroy) {
    if (port == nullptr || cb == nullptr) return false;
    auto sink = std::make_shared<PortSink>();
    sink->kind = PortSink::Borrowed;
    sink->borrowed = cb;
    sink->user = user;
    return subscribeBytesSink(port, std::move(sink), destroy);
}

bool PortRuntime::unsubscribeOutgoingBorrowed(PortInfo* port, EcoPortBorrowedCallback cb, void* user) {
    return unsubscribeBytesSink(port, PortSink::Borrowed, reinterpret_cast<const void*>(cb), user);
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

namespace Elm::Platform::embed_detail {

// The bodies of the borrowed and owned bytes functions, shared by the weak
// definitions here and the strong ones in eco_embed.cpp. They touch no
// PortRuntime state.

const uint8_t* borrowedData(const eco_borrowed_bytes* b) {
    return (b && b->length) ? b->data : nullptr;
}

size_t borrowedSize(const eco_borrowed_bytes* b) {
    return b ? b->length : 0;
}

eco_owned_bytes* retain(const eco_borrowed_bytes* b) {
    const size_t size = b ? b->length : 0;
    void* mem = std::malloc(offsetof(eco_owned_bytes, bytes) + (size > 0 ? size : 1));
    if (!mem) return nullptr;
    eco_owned_bytes* o = static_cast<eco_owned_bytes*>(mem);
    new (&o->refs) std::atomic<size_t>(1);
    o->size = size;
    if (size > 0) std::memcpy(o->bytes, b->data, size);
    return o;
}

const uint8_t* ownedData(const eco_owned_bytes* o) {
    return (o && o->size) ? o->bytes : nullptr;
}

size_t ownedSize(const eco_owned_bytes* o) {
    return o ? o->size : 0;
}

void ownedRef(eco_owned_bytes* o) {
    if (o) o->refs.fetch_add(1, std::memory_order_relaxed);
}

void ownedUnref(eco_owned_bytes* o) {
    if (o && o->refs.fetch_sub(1, std::memory_order_acq_rel) == 1) {
        o->refs.~atomic();
        std::free(o);
    }
}

}  // namespace Elm::Platform::embed_detail

namespace ed = Elm::Platform::embed_detail;

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

ECO_PORT_ABI_WEAK eco_port* eco_port_get(const char* name) {
    return PortRuntime::instance().get(name);
}

ECO_PORT_ABI_WEAK int eco_port_kind(const eco_port* port) {
    return PortRuntime::kindOf(port);
}

ECO_PORT_ABI_WEAK const char* eco_port_get_name(const eco_port* port) {
    return port ? port->name.c_str() : nullptr;
}

ECO_PORT_ABI_WEAK int eco_port_send_json(eco_port* port, const char* json_utf8) {
    switch (PortRuntime::instance().sendIncoming(port, json_utf8)) {
        case PortRuntime::SendResult::Queued: return 0;
        case PortRuntime::SendResult::Rejected: return 2;
        default: return 1;
    }
}

ECO_PORT_ABI_WEAK int eco_port_send_buffer(eco_port* port, const uint8_t* data, size_t length,
                                           Elm::Platform::EcoPortRelease release, void* ctx) {
    return PortRuntime::instance().sendIncomingBytes(port, data, length, release, ctx) ? 0 : 1;
}

ECO_PORT_ABI_WEAK int eco_port_subscribe_json(eco_port* port, Elm::Platform::EcoPortCallback cb,
                                              void* user, Elm::Platform::EcoDestroyFn destroy) {
    return PortRuntime::instance().subscribeOutgoing(port, cb, user, destroy) ? 0 : 1;
}

ECO_PORT_ABI_WEAK int eco_port_unsubscribe_json(eco_port* port, Elm::Platform::EcoPortCallback cb,
                                                void* user) {
    return PortRuntime::instance().unsubscribeOutgoing(port, cb, user) ? 0 : 1;
}

ECO_PORT_ABI_WEAK int eco_port_subscribe_borrowed(eco_port* port,
                                                  Elm::Platform::EcoPortBorrowedCallback cb,
                                                  void* user, Elm::Platform::EcoDestroyFn destroy) {
    return PortRuntime::instance().subscribeOutgoingBorrowed(port, cb, user, destroy) ? 0 : 1;
}

ECO_PORT_ABI_WEAK int eco_port_unsubscribe_borrowed(eco_port* port,
                                                    Elm::Platform::EcoPortBorrowedCallback cb,
                                                    void* user) {
    return PortRuntime::instance().unsubscribeOutgoingBorrowed(port, cb, user) ? 0 : 1;
}

ECO_PORT_ABI_WEAK const uint8_t* eco_borrowed_data(const eco_borrowed_bytes* bytes) {
    return ed::borrowedData(bytes);
}

ECO_PORT_ABI_WEAK size_t eco_borrowed_size(const eco_borrowed_bytes* bytes) {
    return ed::borrowedSize(bytes);
}

ECO_PORT_ABI_WEAK eco_owned_bytes* eco_borrowed_retain(const eco_borrowed_bytes* bytes) {
    return ed::retain(bytes);
}

ECO_PORT_ABI_WEAK const uint8_t* eco_owned_data(const eco_owned_bytes* owned) {
    return ed::ownedData(owned);
}

ECO_PORT_ABI_WEAK size_t eco_owned_size(const eco_owned_bytes* owned) {
    return ed::ownedSize(owned);
}

ECO_PORT_ABI_WEAK void eco_owned_ref(eco_owned_bytes* owned) {
    ed::ownedRef(owned);
}

ECO_PORT_ABI_WEAK void eco_owned_unref(eco_owned_bytes* owned) {
    ed::ownedUnref(owned);
}

ECO_PORT_ABI_WEAK int eco_port_emit(eco_port* port, size_t capacity,
                                    Elm::Platform::EcoBytesFill fill, void* user) {
    return PortRuntime::instance().emit(port, capacity, fill, user);
}

}  // extern "C"
