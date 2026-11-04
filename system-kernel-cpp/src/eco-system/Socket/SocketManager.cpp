//===- SocketManager.cpp - The C++ effect manager of Socket ---------------===//
//
// The manager's state is one `Registry` entry holding the router and, for each listener id, its taggers, all as
// encoded words, so the registry's scanner keeps them alive and updates them when the collector moves them. A heap
// reset makes the registry drop its entries on its next use, so `state()` then creates a fresh, empty entry.
//
// `onEffects` copies the subscriptions into the state and then calls `socketTablesSyncSubscriptions`; it calls no
// Elm code itself. Elm code runs only during delivery, where each tagger is called and its message sent to the
// application, with the Scheduler drained after each one. Draining can run `onEffects` again, which replaces the
// tagger lists, so delivery works from a rooted copy of them taken before the first call.
//
// On Windows, `onEffects` ends the process through `Eco::Kernel::reportFatal` as soon as any `OnConnection`
// subscription exists.
//
//===----------------------------------------------------------------------===//

#include "eco-system/Socket/SocketManager.hpp"

#include "eco-system/Core/Core.hpp"
#include "eco-system/Core/Registry.hpp"
#include "eco-system/Socket/SocketTables.hpp"

#include <map>
#include <utility>
#include <vector>

namespace Eco::System {

namespace {

using namespace SocketManager;

// The manager's state: the router of the last `onEffects`, and the taggers of the current subscriptions grouped by
// listener id, in subscription order. All are encoded HPointer words; a zero `routerEnc` means `onEffects` has not
// run since the state was created.
struct ManagerState {
    uint64_t routerEnc = 0;
    std::map<int64_t, std::vector<uint64_t>> taggers;   // listener id → encoded taggers

    // Calls `f` on the router word and on every tagger word, as `Registry` requires.
    template <typename F>
    void forEachWord(F&& f) {
        f(routerEnc);
        for (auto& kv : taggers)
            for (auto& w : kv.second) f(w);
    }
};

// Returns the registry holding the manager's state. It is allocated once and never deleted, as `Registry` requires.
Registry<ManagerState>& registry() {
    static auto* r = new Registry<ManagerState>("eco-system-socket-manager");   // leaky
    return *r;
}

// Returns the manager's single state entry, creating an empty one on first use and after a heap reset. The reference
// is valid until the next heap reset; nothing else in this file inserts or erases entries.
ManagerState& state() {
    static int64_t id = 0;
    auto& r = registry();
    if (ManagerState* s = r.find(id)) return *s;
    id = r.insert(ManagerState{});
    return *r.find(id);
}

// --- Manager closures ------------------------------------------------------------

// Returns the manager's initial task, `Task.succeed ()`. It is the body of a closure of arity 0.
// init : Task Never ()
void* initEval(void*[]) {
    return reinterpret_cast<void*>(enc(Scheduler::instance().taskSucceed(alloc::unit())));
}

// Replaces the manager's state with the router `args[0]` and the taggers of the subscriptions `args[2]`, brings the
// socket tables in line with them, and returns `Task.succeed ()`. The commands `args[1]` and the state `args[3]` are
// ignored; a subscription whose constructor is not `OnConnection` is skipped.
// onEffects : Router -> List (MyCmd msg) -> List (MySub msg) -> () -> Task Never ()
void* onEffectsEval(void* args[]) {
    HPointer router = dec(args[0]);
    HPointer subs = dec(args[2]);
    Elm::StackRootGuard g(&router, &subs);

    // The walk allocates nothing, so the resolved pointers stay valid while the fields are copied out.
    std::map<int64_t, std::vector<uint64_t>> wanted;
    for (alloc::ListCursor c(subs); !c.done(); c.next()) {
        void* obj = Allocator::instance().resolve(c.current().p);
        if (!obj) continue;
        Custom* sub = static_cast<Custom*>(obj);
        if (sub->ctor != CTOR_ON_CONNECTION) continue;
        wanted[sub->values[ON_CONNECTION_LISTENER_FIELD].i].push_back(
            enc(sub->values[ON_CONNECTION_TAGGER_FIELD].p));
    }

#if defined(_WIN32)
    // A Sub cannot fail, so the unsupported case ends the process instead.
    if (!wanted.empty())
        ::Eco::Kernel::reportFatal("eco/system: Socket.onConnection is not supported on Windows yet");
#endif

    // Registry update: POD only, no heap allocation while `st` is live.
    {
        ManagerState& st = state();
        st.routerEnc = enc(router);
        st.taggers = std::move(wanted);
    }
    ensureSocketTables();
    socketTablesSyncSubscriptions();

    return reinterpret_cast<void*>(enc(Scheduler::instance().taskSucceed(alloc::unit())));
}

// Returns `Task.succeed` of the state `args[2]`. The manager sends itself no messages.
// onSelfMsg : Router -> Never -> () -> Task Never ()
void* onSelfMsgEval(void* args[]) {
    return reinterpret_cast<void*>(enc(Scheduler::instance().taskSucceed(dec(args[2]))));
}

// Returns `f (old x)`, the body of the tagger `subMapEval` builds: `f` and the old tagger `old` are its captures,
// `args[0]` and `args[1]`, and `x`, the ConnT, is its argument `args[2]`.
void* composedTaggerEval(void* args[]) {
    HPointer f = dec(args[0]);
    HPointer old = dec(args[1]);
    HPointer x = dec(args[2]);
    HPointer mid = alloc::listNil();
    Elm::StackRootGuard g({&f, &old, &x, &mid});
    mid = Scheduler::callClosure1(old, x);
    return reinterpret_cast<void*>(enc(Scheduler::callClosure1(f, mid)));
}

// Returns an `OnConnection` for the same listener id as `args[1]` whose tagger applies `args[0]` to the result of the
// old one. Anything other than an `OnConnection` is returned unchanged.
// subMap : (a -> b) -> MySub a -> MySub b
void* subMapEval(void* args[]) {
    HPointer f = dec(args[0]);
    HPointer sub = dec(args[1]);
    HPointer old = alloc::listNil();
    HPointer composed = alloc::listNil();
    int64_t listenerId = 0;
    Elm::StackRootGuard g({&f, &sub, &old, &composed});
    {
        Custom* s = static_cast<Custom*>(Allocator::instance().resolve(sub));   // no allocation in scope
        if (!s || s->ctor != CTOR_ON_CONNECTION) return reinterpret_cast<void*>(enc(sub));
        listenerId = s->values[ON_CONNECTION_LISTENER_FIELD].i;
        old = s->values[ON_CONNECTION_TAGGER_FIELD].p;
    }
    composed = alloc::allocClosure(&composedTaggerEval, 3);
    {
        // Nothing allocates between resolving `composed` and storing both captures, so `p` stays valid.
        void* p = Allocator::instance().resolve(composed);
        alloc::closureCapture(p, alloc::boxed(f), PK_Boxed);
        alloc::closureCapture(p, alloc::boxed(old), PK_Boxed);
    }
    std::vector<Unboxable> fields{alloc::unboxedInt(listenerId), alloc::boxed(composed)};
    return reinterpret_cast<void*>(enc(alloc::custom(CTOR_ON_CONNECTION, fields, ON_CONNECTION_MASK)));
}

} // namespace

bool socketManagerHasSubscribers(int64_t listenerId) {
    ManagerState& st = state();
    if (st.routerEnc == 0) return false;
    auto it = st.taggers.find(listenerId);
    return it != st.taggers.end() && !it->second.empty();
}

void socketManagerDeliver(int64_t listenerId, HPointer& connT) {
    if (!socketManagerHasSubscribers(listenerId)) return;
    HPointer router = alloc::listNil();
    HPointer msg = alloc::listNil();
    Elm::StackRootGuard g(&router, &msg);
    // Snapshot the taggers: draining after a message can run onEffects, which replaces st.taggers. Nothing may
    // allocate between the decodes and the range push, or the decoded words would be unrooted across a collection.
    ManagerState& st = state();
    const std::vector<uint64_t>& words = st.taggers[listenerId];
    std::vector<HPointer> taggers;
    taggers.reserve(words.size());
    for (uint64_t w : words) taggers.push_back(dec(w));
    router = dec(st.routerEnc);
    auto& rs = Allocator::instance().getRootSet();
    size_t saved = rs.stackRangePoint();
    rs.pushStackRootRange(taggers.data(), taggers.size(), ~0ULL);
    for (size_t i = 0; i < taggers.size(); ++i) {
        msg = Scheduler::callClosure1(taggers[i], connT);
        PlatformRuntime::instance().sendToApp(router, msg);
        Scheduler::instance().drain();
    }
    rs.restoreStackRangePoint(saved);
}

} // namespace Eco::System

using namespace Eco::System;

namespace {

// Allocates the manager's closures, rooted until they are encoded, and registers them under "Socket". The cmdMap
// slot is the empty list, since the manager has no commands.
void registerSocketManager() {
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
    PlatformRuntime::instance().registerManager("Socket", info);   // no allocation after encode
}

} // namespace

extern "C" uint64_t Eco_System_registerManager_Socket() {
    ECO_KERNEL_GUARD(
        registerSocketManager();
        return enc(alloc::unit());
    )
}
