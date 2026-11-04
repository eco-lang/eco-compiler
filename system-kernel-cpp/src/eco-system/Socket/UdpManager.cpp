//===- UdpManager.cpp - The C++ effect manager of Socket.Udp --------------===//
//
// The manager's state is one `ManagerState` entry in a `Registry`, which keeps the router and the taggers as encoded
// words the collector updates, and empties itself on a heap reset; `state()` then makes a fresh entry.
//
// onEffects copies the subscriptions out of the list without allocating, replaces the state with them, and then
// calls `udpTablesSyncSubscriptions` so that each socket's receiving and hold follow the new subscriptions. It calls
// no tagger: datagrams held while a socket had no subscriber are delivered later, from the socket event drain.
//
// Delivery copies a socket's taggers into a vector rooted as a stack-root range before calling any of them, since
// sending a message to the application and running the scheduler may lead to onEffects replacing the state. Every
// tagger receives the same DgramT value.
//
//===----------------------------------------------------------------------===//

#include "eco-system/Socket/UdpManager.hpp"

#include "eco-system/Core/Core.hpp"
#include "eco-system/Core/Registry.hpp"
#include "eco-system/Socket/Udp.hpp"

#include <map>
#include <utility>
#include <vector>

namespace Eco::System {

namespace {

using namespace UdpManager;

/// The manager's state: the router of the last update and the taggers of its subscriptions.
struct ManagerState {
    uint64_t routerEnc = 0;
    std::map<int64_t, std::vector<uint64_t>> taggers;   ///< Encoded taggers by socket id, in subscription order.

    /// Calls `f` on the router word and every tagger word, for the registry's scanner.
    template <typename F>
    void forEachWord(F&& f) {
        f(routerEnc);
        for (auto& kv : taggers)
            for (auto& w : kv.second) f(w);
    }
};

/// Returns the registry holding the manager's state, created on first use and never deleted.
Registry<ManagerState>& registry() {
    static auto* r = new Registry<ManagerState>("eco-system-socket-udp-manager");   // leaky
    return *r;
}

/// Returns the manager's state entry, making a new, empty one when there is none, as after a heap reset. The
/// reference is valid until the registry next discards its entries on a heap reset.
ManagerState& state() {
    static int64_t id = 0;
    auto& r = registry();
    if (ManagerState* s = r.find(id)) return *s;
    id = r.insert(ManagerState{});
    return *r.find(id);
}

// --- Manager closures ------------------------------------------------------------

/// Evaluates `init : Task Never ()`, a closure of no arguments: returns a Task that succeeds with unit.
void* initEval(void*[]) {
    return reinterpret_cast<void*>(enc(Scheduler::instance().taskSucceed(alloc::unit())));
}

/// Evaluates `onEffects : Router -> List (MyCmd msg) -> List (MySub msg) -> () -> Task Never ()`: replaces the
/// router and the taggers with those of `args[0]` and `args[2]`, brings the UDP sockets in line with them, and returns
/// a Task that succeeds with unit. List elements for which `resolve` returns null, or with another constructor, are
/// skipped.
void* onEffectsEval(void* args[]) {
    HPointer router = dec(args[0]);
    HPointer subs = dec(args[2]);
    Elm::StackRootGuard g(&router, &subs);

    // Nothing allocates during the walk, so the raw `sub` pointers stay valid.
    std::map<int64_t, std::vector<uint64_t>> wanted;
    for (alloc::ListCursor c(subs); !c.done(); c.next()) {
        void* obj = Allocator::instance().resolve(c.current().p);
        Custom* sub = static_cast<Custom*>(obj);
        if (sub->ctor != CTOR_ON_MESSAGE) continue;
        wanted[sub->values[ON_MESSAGE_SOCKET_FIELD].i].push_back(
            enc(sub->values[ON_MESSAGE_TAGGER_FIELD].p));
    }

#if defined(_WIN32)
    // A Sub cannot fail, so an unsupported one is fatal.
    if (!wanted.empty())
        ::Eco::Kernel::reportFatal("eco/system: Socket.Udp.onMessage is not supported on Windows yet");
#endif

    // Registry update: POD only, no heap allocation while `st` is live.
    {
        ManagerState& st = state();
        st.routerEnc = enc(router);
        st.taggers = std::move(wanted);
    }
    ensureUdpTables();
    udpTablesSyncSubscriptions();

    return reinterpret_cast<void*>(enc(Scheduler::instance().taskSucceed(alloc::unit())));
}

/// Evaluates `onSelfMsg : Router -> Never -> () -> Task Never ()`: returns a Task that succeeds with the state
/// `args[2]`. No self message is ever sent.
void* onSelfMsgEval(void* args[]) {
    return reinterpret_cast<void*>(enc(Scheduler::instance().taskSucceed(dec(args[2]))));
}

/// Evaluates the tagger `subMap` builds, whose captures are `f` in `args[0]` and the original tagger in `args[1]`:
/// returns `f (old args[2])` for the DgramT in `args[2]`.
void* composedTaggerEval(void* args[]) {
    HPointer f = dec(args[0]);
    HPointer old = dec(args[1]);
    HPointer x = dec(args[2]);
    HPointer mid = alloc::listNil();
    Elm::StackRootGuard g({&f, &old, &x, &mid});
    mid = Scheduler::callClosure1(old, x);
    return reinterpret_cast<void*>(enc(Scheduler::callClosure1(f, mid)));
}

/// Evaluates `subMap : (a -> b) -> MySub a -> MySub b`: returns a new `OnMessage` with the same socket id whose
/// tagger applies `args[0]` after the old one. A value that is not an `OnMessage` heap object is returned unchanged.
void* subMapEval(void* args[]) {
    HPointer f = dec(args[0]);
    HPointer sub = dec(args[1]);
    HPointer old = alloc::listNil();
    HPointer composed = alloc::listNil();
    int64_t socketId = 0;
    Elm::StackRootGuard g({&f, &sub, &old, &composed});
    {
        Custom* s = static_cast<Custom*>(Allocator::instance().resolve(sub));   // no allocation in scope
        if (s->ctor != CTOR_ON_MESSAGE) return reinterpret_cast<void*>(enc(sub));
        socketId = s->values[ON_MESSAGE_SOCKET_FIELD].i;
        old = s->values[ON_MESSAGE_TAGGER_FIELD].p;
    }
    composed = alloc::allocClosure(&composedTaggerEval, 3);
    {
        // `p` is raw, so both captures follow the allocation with nothing allocated in between.
        void* p = Allocator::instance().resolve(composed);
        alloc::closureCapture(p, alloc::boxed(f), PK_Boxed);
        alloc::closureCapture(p, alloc::boxed(old), PK_Boxed);
    }
    std::vector<Unboxable> fields{alloc::unboxedInt(socketId), alloc::boxed(composed)};
    return reinterpret_cast<void*>(enc(alloc::custom(CTOR_ON_MESSAGE, fields, ON_MESSAGE_MASK)));
}

} // namespace

bool udpManagerHasSubscribers(int64_t socketId) {
    ManagerState& st = state();
    if (st.routerEnc == 0) return false;
    auto it = st.taggers.find(socketId);
    return it != st.taggers.end() && !it->second.empty();
}

void udpManagerDeliver(int64_t socketId, HPointer& dgramT) {
    if (!udpManagerHasSubscribers(socketId)) return;
    HPointer router = alloc::listNil();
    HPointer msg = alloc::listNil();
    Elm::StackRootGuard g(&router, &msg);
    // Sending a message and running the scheduler may replace the taggers, so deliver from a rooted copy. Nothing
    // allocates from the decodes to the range push.
    ManagerState& st = state();
    const std::vector<uint64_t>& words = st.taggers[socketId];
    std::vector<HPointer> taggers;
    taggers.reserve(words.size());
    for (uint64_t w : words) taggers.push_back(dec(w));
    router = dec(st.routerEnc);
    auto& rs = Allocator::instance().getRootSet();
    size_t saved = rs.stackRangePoint();
    rs.pushStackRootRange(taggers.data(), taggers.size(), ~0ULL);
    for (size_t i = 0; i < taggers.size(); ++i) {
        msg = Scheduler::callClosure1(taggers[i], dgramT);
        PlatformRuntime::instance().sendToApp(router, msg);
        Scheduler::instance().drain();
    }
    rs.restoreStackRangePoint(saved);
}

} // namespace Eco::System

using namespace Eco::System;

namespace {

/// Allocates the manager's closures, rooted until they are encoded, and registers them under "Socket.Udp". There
/// are no commands, so the `cmdMap` slot holds the Nil constant rather than a closure.
void registerUdpManager() {
    HPointer initCl = alloc::listNil();
    HPointer effCl = alloc::listNil();
    HPointer selfCl = alloc::listNil();
    HPointer cmdMapCl = alloc::listNil();
    HPointer subMapCl = alloc::listNil();
    Elm::StackRootGuard g({&initCl, &effCl, &selfCl, &cmdMapCl, &subMapCl});
    initCl = alloc::allocClosure(&initEval, 0);
    effCl = alloc::allocClosure(&onEffectsEval, 4);
    selfCl = alloc::allocClosure(&onSelfMsgEval, 3);
    subMapCl = alloc::allocClosure(&subMapEval, 2);
    PlatformRuntime::ManagerInfo info{enc(initCl), enc(effCl), enc(selfCl),
                                      enc(cmdMapCl), enc(subMapCl)};
    PlatformRuntime::instance().registerManager("Socket.Udp", info);   // no allocation after encode
}

} // namespace

extern "C" uint64_t Eco_System_registerManager_Socket_Udp() {
    ECO_KERNEL_GUARD(
        registerUdpManager();
        return enc(alloc::unit());
    )
}
