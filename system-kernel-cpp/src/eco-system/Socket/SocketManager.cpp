//===- SocketManager.cpp - The C++ effect manager of Socket ---------------===//
//
// plans/eco-system-sockets.md §3.5, base plan Appendix C.0 / sockets plan
// C.1. Layout: SocketManager.hpp.
//
//   * onEffects: the OnConnection taggers are grouped by listener id
//     (encoded words in a T5 registry, with the router). Subscriptions hold
//     no pendingAsync: an open listener already does (§3.3.8). After the
//     update the socket tables are synchronised (SocketTables.cpp): a
//     listener whose tagger list became non-empty gets setUnlimited(true)
//     and its held FIFO is delivered (from the socket drain, never from
//     inside onEffects); one whose list became empty gets
//     setUnlimited(false).
//   * Delivery (T8, §3.4): socketManagerDeliver builds nothing itself: the
//     ConnT is built once by the caller (rooted); the taggers are
//     snapshotted into one rooted range, and for each: call it, sendToApp,
//     drain() (G11, G12). Every subscriber gets the same Connection (R5).
//   * subMap composes the tagger (TimeEffectManager pattern) and keeps the
//     unboxed listener id (mask 0x1). There are no commands.
//   * Windows: an OnConnection subscription crashes with a clear message
//     (§1).
//
// Templates used: T6 (rooted registration per G14), T5, T8/G12.
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

struct ManagerState {
    uint64_t routerEnc = 0;
    std::map<int64_t, std::vector<uint64_t>> taggers;   // listener id → encoded taggers

    template <typename F>
    void forEachWord(F&& f) {
        f(routerEnc);
        for (auto& kv : taggers)
            for (auto& w : kv.second) f(w);
    }
};

Registry<ManagerState>& registry() {
    static auto* r = new Registry<ManagerState>("eco-system-socket-manager");   // leaky
    return *r;
}

// The single state entry (re-created after a heap reset, F24).
ManagerState& state() {
    static int64_t id = 0;
    auto& r = registry();
    if (ManagerState* s = r.find(id)) return *s;
    id = r.insert(ManagerState{});
    return *r.find(id);
}

// --- Manager closures (C.0) ------------------------------------------------------

// init : Task Never ()  (a 0-arity thunk, forced by setupEffects)
void* initEval(void*[]) {
    return reinterpret_cast<void*>(enc(Scheduler::instance().taskSucceed(alloc::unit())));
}

// onEffects : Router -> List (MyCmd msg) -> List (MySub msg) -> () -> Task Never ()
void* onEffectsEval(void* args[]) {
    HPointer router = dec(args[0]);
    HPointer subs = dec(args[2]);
    Elm::StackRootGuard g(&router, &subs);

    // A non-allocating walk (G5): copy every field out.
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
    // A Sub is infallible: crash with a clear message (§1).
    if (!wanted.empty())
        ::Eco::Kernel::reportFatal("eco/system: Socket.onConnection is not supported on Windows yet");
#endif

    // Registry update: POD only, no heap allocation while `st` is live.
    {
        ManagerState& st = state();
        st.routerEnc = enc(router);
        st.taggers = std::move(wanted);
    }
    // §3.4: listener demand follows the subscriptions; held connections are
    // delivered from the socket drain (no Elm calls from here).
    ensureSocketTables();
    socketTablesSyncSubscriptions();

    return reinterpret_cast<void*>(enc(Scheduler::instance().taskSucceed(alloc::unit())));
}

// onSelfMsg : Router -> Never -> () -> Task Never ()  (never sent)
void* onSelfMsgEval(void* args[]) {
    return reinterpret_cast<void*>(enc(Scheduler::instance().taskSucceed(dec(args[2]))));
}

// The composed tagger of subMap: args[0] = f, args[1] = old tagger,
// args[2] = the ConnT tuple. Result: f (old conn).
void* composedTaggerEval(void* args[]) {
    HPointer f = dec(args[0]);
    HPointer old = dec(args[1]);
    HPointer x = dec(args[2]);
    HPointer mid = alloc::listNil();
    Elm::StackRootGuard g({&f, &old, &x, &mid});
    mid = Scheduler::callClosure1(old, x);   // Elm call (G11)
    return reinterpret_cast<void*>(enc(Scheduler::callClosure1(f, mid)));
}

// subMap : (a -> b) -> MySub a -> MySub b — compose the tagger, keep the id.
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
        // Both captures right after the allocation, nothing allocated in between (G8).
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
    // Snapshot the taggers: update may change the subscriptions while we
    // deliver (G11). No allocation from the decodes to the range push.
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
        msg = Scheduler::callClosure1(taggers[i], connT);   // Elm call (G11)
        PlatformRuntime::instance().sendToApp(router, msg);
        Scheduler::instance().drain();                      // once per message (G12)
    }
    rs.restoreStackRangePoint(saved);
}

} // namespace Eco::System

using namespace Eco::System;

namespace {

// Allocates the manager closures in the rooted PortRuntime form (G14) and
// registers them under "Socket". Subscriptions only: no cmdMap.
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
