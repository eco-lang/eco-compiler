//===- WsManager.cpp - The C++ effect manager of WebSocket ----------------===//
//
// plans/eco-system-websockets.md §3.6 "Manager", Appendix C.2; base plan
// Appendix C.0. Layout: WsManager.hpp.
//
//   * onEffects: the taggers are grouped by WebSocket id and kind (encoded
//     words in a T5 registry, with the router), then every id is
//     reconciled (no Elm calls from onEffects):
//       - OnMessage: the first subscriber attaches the subscription reader to
//         the readable (attachReader fails while a read is parked: retried on
//         the next onEffects); the last one detaches it, so later messages
//         wait on the readable again;
//       - keep-alive (§3.6): one pendingAsync count per subscribed
//         connection while it is open (OnMessage) or until its close was
//         delivered (OnClose); a count per subscription would only differ in
//         the number, not in liveness;
//       - a held close (the connection closed with no OnClose subscriber) is
//         delivered to the new subscribers from the WebSocket drain
//         (requestWsWork).
//   * The reader (readerFn) runs from the channel drain: it builds the
//     ( kind, text, bytes ) argument once (rooted) and hands it to every
//     OnMessage tagger in subscription order, sendToApp + drain() per
//     message (T8, G12). The taggers are snapshotted per message (an update
//     may change the subscriptions, G11; a detach stops the feed).
//   * Closed (wsManagerOnClosed): the ( code, reason, clean ) argument goes
//     to every OnClose tagger once, or is held. While the reader is attached
//     it waits for the readable's end to reach the reader, so every message
//     received before the close is delivered first (the queued chunks run
//     from a later channel drain); readerFn then delivers it.
//   * subMap composes the tagger (TimeEffectManager pattern) and keeps the
//     unboxed WebSocket id (mask 0x1). There are no commands.
//
// Templates used: T6 (rooted registration per G14), T5, T8/G12.
//
//===----------------------------------------------------------------------===//

#include "eco-system/WebSocket/WsManager.hpp"

#include "eco-system/Core/Core.hpp"
#include "eco-system/Core/Registry.hpp"
#include "eco-system/Stream/Stream.hpp"
#include "eco-system/WebSocket/WsEvents.hpp"
#include "eco-system/WebSocket/WsTables.hpp"

#include <cstring>
#include <map>
#include <set>
#include <utility>
#include <vector>

namespace Eco::System {

namespace {

using namespace WsManager;

struct Subs {
    std::vector<uint64_t> messages;   // encoded taggers, in subscription order
    std::vector<uint64_t> closes;
};

struct ManagerState {
    uint64_t routerEnc = 0;
    std::map<int64_t, Subs> subs;

    template <typename F>
    void forEachWord(F&& f) {
        f(routerEnc);
        for (auto& kv : subs) {
            for (auto& w : kv.second.messages) f(w);
            for (auto& w : kv.second.closes) f(w);
        }
    }
};

Registry<ManagerState>& registry() {
    static auto* r = new Registry<ManagerState>("eco-system-websocket-manager");   // leaky
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

// POD bookkeeping per subscribed id (no heap words), keyed on the heap
// generation like the tables.
struct Aux {
    bool attached = false;
    int64_t readableId = 0;
    bool counted = false;
    bool ended = false;   // the attached reader saw the readable's end
};

struct AuxTable {
    std::map<int64_t, Aux> m;
    uint64_t gen = 0;
    bool init = false;
};

std::map<int64_t, Aux>& aux() {
    static auto* t = new AuxTable();   // leaky
    uint64_t g = currentHeapGeneration();
    if (!t->init || t->gen != g) {   // a dead heap's counts died with it
        t->init = true;
        t->gen = g;
        t->m.clear();
    }
    return t->m;
}

const Subs* subsOf(int64_t wsId) {
    ManagerState& st = state();
    auto it = st.subs.find(wsId);
    return it == st.subs.end() ? nullptr : &it->second;
}

// --- Delivery (T8, G12) ------------------------------------------------------------

// Calls every tagger of kind `closes` / messages of `wsId` with `arg`
// (rooted by the caller): sendToApp + drain per message.
void deliver(int64_t wsId, bool closes, HPointer& arg) {
    std::vector<HPointer> taggers;
    HPointer router = alloc::listNil(), msg = alloc::listNil();
    Elm::StackRootGuard g(&router, &msg);
    {
        // Snapshot (no allocation from the decodes to the range push, G5).
        const Subs* s = subsOf(wsId);
        if (!s || state().routerEnc == 0) return;
        const std::vector<uint64_t>& words = closes ? s->closes : s->messages;
        taggers.reserve(words.size());
        for (uint64_t w : words) taggers.push_back(dec(w));
        router = dec(state().routerEnc);
    }
    auto& rs = Allocator::instance().getRootSet();
    size_t saved = rs.stackRangePoint();
    rs.pushStackRootRange(taggers.data(), taggers.size(), ~0ULL);
    for (size_t i = 0; i < taggers.size(); ++i) {
        msg = Scheduler::callClosure1(taggers[i], arg);   // Elm call (G11)
        PlatformRuntime::instance().sendToApp(router, msg);
        Scheduler::instance().drain();                    // once per message (G12)
    }
    rs.restoreStackRangePoint(saved);
}

void deliverClose(int64_t wsId);
bool reconcile(int64_t wsId);

// True while the close must wait: the reader is attached and the readable's
// end has not reached it (messages received before the close are queued).
bool closeWaitsForReader(int64_t wsId) {
    auto& table = aux();
    auto it = table.find(wsId);
    return it != table.end() && it->second.attached && !it->second.ended;
}

// The subscription reader of a readable (Stream.hpp ReaderFn): data chunks
// become ( kind, text, bytes ) for the OnMessage taggers. The end of the
// readable is reported through Closed instead, which waits for it.
void readerFn(int64_t, ChannelResult& r, void* ctx) {
    int64_t wsId = static_cast<int64_t>(reinterpret_cast<intptr_t>(ctx));
    if (r.eof || r.err != 0) {
        aux()[wsId].ended = true;
        WsEntry* e = findWs(wsId);
        const Subs* s = subsOf(wsId);
        if (e && e->closed && !e->closeDelivered && s && !s->closes.empty()) deliverClose(wsId);
        (void)reconcile(wsId);   // a close seen before the end released nothing yet
        return;
    }
    HPointer str = alloc::listNil(), bytes = alloc::listNil(), arg = alloc::listNil();
    Elm::StackRootGuard g({&str, &bytes, &arg});
    if (r.text) {
        str = alloc::allocStringFromUTF8(r.bytes);
        bytes = alloc::emptyBytes();
    } else {
        str = alloc::emptyString();
        if (r.bytes.empty()) {
            bytes = alloc::emptyBytes();
        } else {
            alloc::BlankByteBuffer bb = alloc::allocByteBufferBlank(r.bytes.size());
            std::memcpy(bb.bytes, r.bytes.data(), r.bytes.size());   // no allocation in between (G8)
            bytes = bb.hp;
        }
    }
    arg = alloc::tuple3(alloc::unboxedInt(r.tag), alloc::boxed(str), alloc::boxed(bytes), MESSAGE_ARG_MASK);
    deliver(wsId, /*closes=*/false, arg);
}

void deliverClose(int64_t wsId) {
    WsEntry* e = findWs(wsId);
    if (!e || !e->closed || e->closeDelivered) return;
    e->closeDelivered = true;
    WsCloseInfo info = e->info;   // G3: copy before allocating
    HPointer reason = alloc::listNil(), arg = alloc::listNil();
    Elm::StackRootGuard g(&reason, &arg);
    reason = alloc::allocStringFromUTF8(info.reason);
    arg = alloc::tuple3(alloc::unboxedInt(info.code), alloc::boxed(reason),
                        alloc::boxed(info.clean ? alloc::elmTrue() : alloc::elmFalse()), CLOSE_ARG_MASK);
    deliver(wsId, /*closes=*/true, arg);
}

// Attach / detach the reader, adjust the count, note a held close. No Elm
// calls. Returns true if a held close waits for delivery.
bool reconcile(int64_t wsId) {
    const Subs* s = subsOf(wsId);
    bool hasMsg = s && !s->messages.empty();
    bool hasClose = s && !s->closes.empty();
    auto& table = aux();
    Aux& a = table[wsId];
    WsEntry* e = findWs(wsId);
    if (hasMsg && !a.attached && e && e->readableId != 0) {
        a.attached = attachReader(e->readableId, &readerFn,
                                  reinterpret_cast<void*>(static_cast<intptr_t>(wsId)));
        if (a.attached) {
            a.readableId = e->readableId;
            a.ended = false;
        }
    } else if (!hasMsg && a.attached) {
        detachReader(a.readableId);
        a.attached = false;
    }
    bool waiting = a.attached && !a.ended;   // queued messages still to deliver
    bool want = (hasMsg && e && (!e->closed || waiting)) ||
                (hasClose && e && !(e->closed && e->closeDelivered));
    if (want != a.counted) {
        if (want) Scheduler::instance().incrementPendingAsync();
        else Scheduler::instance().decrementPendingAsync();
        a.counted = want;
    }
    bool held = hasClose && e && e->closed && !e->closeDelivered && !waiting;
    if (!hasMsg && !hasClose && !a.attached && !a.counted) {
        table.erase(wsId);
        wsTablesRetire(wsId);
    }
    return held;
}

void deliverHeldCloses() {
    std::vector<int64_t> ids;
    for (auto& kv : state().subs) {
        if (!kv.second.closes.empty()) ids.push_back(kv.first);
    }
    for (int64_t id : ids) {
        WsEntry* e = findWs(id);
        if (e && e->closed && !e->closeDelivered && !closeWaitsForReader(id)) deliverClose(id);
        (void)reconcile(id);
    }
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

    // A non-allocating walk (G5): copy every field out. The native runtime
    // lists the subscriptions in declaration order (listFromEncoded).
    std::map<int64_t, Subs> wanted;
    for (alloc::ListCursor c(subs); !c.done(); c.next()) {
        void* obj = Allocator::instance().resolve(c.current().p);
        if (!obj) continue;
        Custom* sub = static_cast<Custom*>(obj);
        if (sub->ctor != CTOR_ON_MESSAGE && sub->ctor != CTOR_ON_CLOSE) continue;
        Subs& s = wanted[sub->values[SUB_WS_FIELD].i];
        uint64_t w = enc(sub->values[SUB_TAGGER_FIELD].p);
        (sub->ctor == CTOR_ON_MESSAGE ? s.messages : s.closes).push_back(w);
    }

    std::set<int64_t> ids;
    {
        // Registry update: POD only, no heap allocation while `st` is live.
        ManagerState& st = state();
        for (auto& kv : st.subs) ids.insert(kv.first);
        st.routerEnc = enc(router);
        st.subs = std::move(wanted);
        for (auto& kv : st.subs) ids.insert(kv.first);
    }
    ensureWsTables();
    for (auto& kv : aux()) ids.insert(kv.first);
    bool held = false;
    for (int64_t id : ids) held = reconcile(id) || held;
    if (held) requestWsWork(&deliverHeldCloses);   // delivered from the drain, not from here

    return reinterpret_cast<void*>(enc(Scheduler::instance().taskSucceed(alloc::unit())));
}

// onSelfMsg : Router -> Never -> () -> Task Never ()  (never sent)
void* onSelfMsgEval(void* args[]) {
    return reinterpret_cast<void*>(enc(Scheduler::instance().taskSucceed(dec(args[2]))));
}

// The composed tagger of subMap: args[0] = f, args[1] = old tagger,
// args[2] = the event tuple. Result: f (old event).
void* composedTaggerEval(void* args[]) {
    HPointer f = dec(args[0]);
    HPointer old = dec(args[1]);
    HPointer x = dec(args[2]);
    HPointer mid = alloc::listNil();
    Elm::StackRootGuard g({&f, &old, &x, &mid});
    mid = Scheduler::callClosure1(old, x);   // Elm call (G11)
    return reinterpret_cast<void*>(enc(Scheduler::callClosure1(f, mid)));
}

// subMap : (a -> b) -> MySub a -> MySub b — compose the tagger, keep the
// constructor and the id.
void* subMapEval(void* args[]) {
    HPointer f = dec(args[0]);
    HPointer sub = dec(args[1]);
    HPointer old = alloc::listNil();
    HPointer composed = alloc::listNil();
    int64_t wsId = 0;
    uint16_t ctor = 0;
    Elm::StackRootGuard g({&f, &sub, &old, &composed});
    {
        Custom* s = static_cast<Custom*>(Allocator::instance().resolve(sub));   // no allocation in scope
        if (!s || (s->ctor != CTOR_ON_MESSAGE && s->ctor != CTOR_ON_CLOSE))
            return reinterpret_cast<void*>(enc(sub));
        ctor = s->ctor;
        wsId = s->values[SUB_WS_FIELD].i;
        old = s->values[SUB_TAGGER_FIELD].p;
    }
    composed = alloc::allocClosure(&composedTaggerEval, 3);
    {
        // Both captures right after the allocation, nothing allocated in between (G8).
        void* p = Allocator::instance().resolve(composed);
        alloc::closureCapture(p, alloc::boxed(f), PK_Boxed);
        alloc::closureCapture(p, alloc::boxed(old), PK_Boxed);
    }
    std::vector<Unboxable> fields{alloc::unboxedInt(wsId), alloc::boxed(composed)};
    return reinterpret_cast<void*>(enc(alloc::custom(ctor, fields, SUB_MASK)));
}

} // namespace

void wsManagerOnClosed(int64_t wsId) {
    const Subs* s = subsOf(wsId);
    if (s && !s->closes.empty() && !closeWaitsForReader(wsId)) deliverClose(wsId);
    (void)reconcile(wsId);   // releases the count; a later subscriber gets a held close
}

bool wsManagerHasSubscribers(int64_t wsId) {
    const Subs* s = subsOf(wsId);
    return s && (!s->messages.empty() || !s->closes.empty());
}

} // namespace Eco::System

using namespace Eco::System;

namespace {

// Allocates the manager closures in the rooted PortRuntime form (G14) and
// registers them under "WebSocket". Subscriptions only: no cmdMap.
void registerWsManager() {
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
    PlatformRuntime::instance().registerManager("WebSocket", info);   // no allocation after encode
}

} // namespace

extern "C" uint64_t Eco_System_registerManager_WebSocket() {
    ECO_KERNEL_GUARD(
        registerWsManager();
        return enc(alloc::unit());
    )
}
