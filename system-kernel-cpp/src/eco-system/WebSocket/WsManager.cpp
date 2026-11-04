//===- WsManager.cpp - The C++ effect manager of WebSocket ----------------===//
//
// The manager's state is in two tables. The taggers and the router, which are heap values, are kept as encoded words
// in the single entry of a `Registry`, grouped by WebSocket id and kind. Everything else about a subscribed WebSocket
// (whether a reader is attached, whether it has seen the end, the hold) is plain data in the `Aux` table, keyed on the
// heap generation.
//
// `onEffects` never calls Elm code: it stores the new subscriptions and then reconciles every id it has heard of,
// attaching or detaching the reader and taking or releasing the hold. Closes that a new `OnClose` subscription
// should receive are delivered from the WebSocket event drain, which `requestWsWork` asks to call
// `deliverHeldCloses`. Each delivery sends one message per tagger and runs the scheduler after each, and the taggers
// are read once per delivery, so a subscription change made while it runs does not affect the delivery under way.
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

// The encoded taggers of the subscriptions that name one WebSocket, by kind, each in the order of the subscription
// list `onEffects` was given.
struct Subs {
    std::vector<uint64_t> messages;
    std::vector<uint64_t> closes;
};

// The manager's heap-holding state: the router of the last `onEffects` (0 before the first) and the taggers of every
// subscribed WebSocket, by id.
struct ManagerState {
    uint64_t routerEnc = 0;
    std::map<int64_t, Subs> subs;

    // Calls `f` on every encoded word the state holds, for the registry's scanner.
    template <typename F>
    void forEachWord(F&& f) {
        f(routerEnc);
        for (auto& kv : subs) {
            for (auto& w : kv.second.messages) f(w);
            for (auto& w : kv.second.closes) f(w);
        }
    }
};

// Returns the registry that holds the manager's state. It is created on first use and never destroyed.
Registry<ManagerState>& registry() {
    static auto* r = new Registry<ManagerState>("eco-system-websocket-manager");   // leaky
    return *r;
}

// Returns the manager's state, creating an empty one on first use and after a heap reset, which empties the registry.
// The reference is valid until the next heap reset.
ManagerState& state() {
    static int64_t id = 0;
    auto& r = registry();
    if (ManagerState* s = r.find(id)) return *s;
    id = r.insert(ManagerState{});
    return *r.find(id);
}

// What the manager knows about one WebSocket beyond its taggers.
struct Aux {
    bool attached = false;      // The subscription reader is attached to `readableId`.
    int64_t readableId = 0;     // The readable the reader was attached to; meaningful only while `attached`.
    HoldToken hold = kNoHold;   // The WebSocket's hold, or `kNoHold` when none is taken.
    bool ended = false;         // The attached reader has seen the readable's end.
};

// The `Aux` entries, by WebSocket id, and the heap generation they belong to.
struct AuxTable {
    std::map<int64_t, Aux> m;
    uint64_t gen = 0;
    bool init = false;   // `gen` has been set from a first call of `aux`.
};

// Returns the `Aux` entries of the current heap generation, discarding all of them first if the generation has changed
// since the last call. The holds of discarded entries need no release: the scheduler voided every hold of the old heap
// at the reset.
std::map<int64_t, Aux>& aux() {
    static auto* t = new AuxTable();   // leaky
    uint64_t g = currentHeapGeneration();
    if (!t->init || t->gen != g) {
        t->init = true;
        t->gen = g;
        t->m.clear();
    }
    return t->m;
}

// Returns the taggers of WebSocket `wsId`, or null if no subscription names it. The pointer is valid until the next
// `onEffects` or heap reset, and running Elm code may cause either.
const Subs* subsOf(int64_t wsId) {
    ManagerState& st = state();
    auto it = st.subs.find(wsId);
    return it == st.subs.end() ? nullptr : &it->second;
}

// --- Delivery ---------------------------------------------------------------------

// Applies each close tagger (if `closes`) or each message tagger of WebSocket `wsId` to `arg`, sends the result to the
// program and runs the scheduler, one tagger at a time in subscription order. The taggers are those subscribed when
// the call starts. Does nothing before the first `onEffects`. `arg` must be rooted by the caller.
void deliver(int64_t wsId, bool closes, HPointer& arg) {
    std::vector<HPointer> taggers;
    HPointer router = alloc::listNil(), msg = alloc::listNil();
    Elm::StackRootGuard g(&router, &msg);
    {
        // Nothing allocates from here to the range push, so the decoded taggers stay valid.
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
        msg = Scheduler::callClosure1(taggers[i], arg);
        PlatformRuntime::instance().sendToApp(router, msg);
        Scheduler::instance().drain();
    }
    rs.restoreStackRangePoint(saved);
}

// Declared ahead of `readerFn`, which calls them; their comments are at their definitions.
void deliverClose(int64_t wsId);
bool reconcile(int64_t wsId);

// Returns whether a close of WebSocket `wsId` must wait for the reader: one is attached and has not yet seen the
// readable's end, so messages read before the close may still be queued for it.
bool closeWaitsForReader(int64_t wsId) {
    auto& table = aux();
    auto it = table.find(wsId);
    return it != table.end() && it->second.attached && !it->second.ended;
}

// The subscription reader (`ReaderFn`) of WebSocket `ctx`'s readable. It delivers each chunk as a
// `( tag, text, bytes )` message. At the readable's end or failure it records that the end was seen, delivers the
// close if the WebSocket has ended, its close is undelivered and some `OnClose` subscription names it, and
// reconciles the WebSocket.
void readerFn(int64_t, ChannelResult& r, void* ctx) {
    int64_t wsId = static_cast<int64_t>(reinterpret_cast<intptr_t>(ctx));
    if (r.eof || r.err != 0) {
        aux()[wsId].ended = true;
        WsEntry* e = findWs(wsId);
        const Subs* s = subsOf(wsId);
        if (e && e->closed && !e->closeDelivered && s && !s->closes.empty()) deliverClose(wsId);
        (void)reconcile(wsId);
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
            std::memcpy(bb.bytes, r.bytes.data(), r.bytes.size());
            bytes = bb.hp;
        }
    }
    arg = alloc::tuple3(alloc::unboxedInt(r.tag), alloc::boxed(str), alloc::boxed(bytes), MESSAGE_ARG_MASK);
    deliver(wsId, /*closes=*/false, arg);
}

// Returns whether a delivery to the close taggers of WebSocket `wsId` would run any: an `OnClose` subscription names
// it and `onEffects` has run.
bool hasCloseTaggers(int64_t wsId) {
    const Subs* s = subsOf(wsId);
    return s && !s->closes.empty() && state().routerEnc != 0;
}

// Delivers `info` to the close taggers of WebSocket `wsId` as `( code, reason, clean )`.
void deliverCloseInfo(int64_t wsId, const WsCloseInfo& info) {
    HPointer reason = alloc::listNil(), arg = alloc::listNil();
    Elm::StackRootGuard g(&reason, &arg);
    reason = alloc::allocStringFromUTF8(info.reason);
    arg = alloc::tuple3(alloc::unboxedInt(info.code), alloc::boxed(reason),
                        alloc::boxed(info.clean ? alloc::elmTrue() : alloc::elmFalse()), CLOSE_ARG_MASK);
    deliver(wsId, /*closes=*/true, arg);
}

// Delivers the end of WebSocket `wsId` to its close taggers, and marks it delivered, unless it has not ended, was
// already delivered, or no tagger would run (a subscription dropped by an earlier delivery's Elm code leaves the close
// held for a later subscriber). It is marked delivered before any tagger runs, so that a delivery started from
// inside one does not deliver it again.
void deliverClose(int64_t wsId) {
    WsEntry* e = findWs(wsId);
    if (!e || !e->closed || e->closeDelivered || !hasCloseTaggers(wsId)) return;
    e->closeDelivered = true;
    WsCloseInfo info = e->info;   // Copied: the entry may be erased once Elm code runs.
    deliverCloseInfo(wsId, info);
}

// As `deliverClose`, for a WebSocket whose entry has been erased: delivers the close kept in its recently closed
// record, if that has not been delivered, and marks the record delivered.
void deliverRecentClose(int64_t wsId) {
    if (findWs(wsId)) return;
    WsRecentClose* r = wsRecentClose(wsId);
    if (!r || r->delivered || !hasCloseTaggers(wsId)) return;
    r->delivered = true;
    WsCloseInfo info = r->info;   // Copied: the record may be dropped once Elm code runs.
    deliverCloseInfo(wsId, info);
}

// Returns whether WebSocket `wsId` has no entry but an undelivered close in its recently closed record.
bool recentCloseHeld(int64_t wsId) {
    if (findWs(wsId)) return false;
    const WsRecentClose* r = wsRecentClose(wsId);
    return r && !r->delivered;
}

// Brings WebSocket `wsId` in line with its subscriptions, without calling Elm code: attaches the reader if a message
// subscription names it and none is attached, detaches it if none does, and takes or releases the hold as the file
// comment of the header describes. Once nothing is left for the WebSocket, erases its `Aux` entry and asks
// `wsTablesRetire` to erase its table entry if nothing else still needs it. Returns whether a close subscription is
// waiting for a close that can be delivered now.
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
    bool waiting = a.attached && !a.ended;
    // A retired WebSocket's close not yet delivered is held for a close subscription as an entry's is.
    bool recentHeld = hasClose && !e && recentCloseHeld(wsId);
    bool want = (hasMsg && e && (!e->closed || waiting)) ||
                (hasClose && e && !(e->closed && e->closeDelivered)) || recentHeld;
    if (want && a.hold == kNoHold) {
        a.hold = Scheduler::instance().acquireHold(HoldKind::Subscription, "WebSocket.subscription");
    } else if (!want && a.hold != kNoHold) {
        Scheduler::instance().releaseHold(a.hold);
        a.hold = kNoHold;
    }
    bool held = (hasClose && e && e->closed && !e->closeDelivered && !waiting) || recentHeld;
    if (!hasMsg && !hasClose && !a.attached && a.hold == kNoHold) {
        table.erase(wsId);
        wsTablesRetire(wsId);
    }
    return held;
}

// Delivers every close that a close subscription is waiting for and that no reader holds back, the closes kept for
// retired WebSockets included, and reconciles each
// WebSocket a close subscription names. It is the work `onEffects` asks the WebSocket event drain for.
void deliverHeldCloses() {
    std::vector<int64_t> ids;
    for (auto& kv : state().subs) {
        if (!kv.second.closes.empty()) ids.push_back(kv.first);
    }
    for (int64_t id : ids) {
        WsEntry* e = findWs(id);
        if (!e) {
            deliverRecentClose(id);
        } else if (e->closed && !e->closeDelivered && !closeWaitsForReader(id)) {
            deliverClose(id);
        }
        (void)reconcile(id);
    }
}

// --- Manager closures --------------------------------------------------------------

// The evaluator of `init : Task Never ()`. Returns a Task that succeeds with Unit.
void* initEval(void*[]) {
    return reinterpret_cast<void*>(enc(Scheduler::instance().taskSucceed(alloc::unit())));
}

// The evaluator of `onEffects : Router -> List (MyCmd msg) -> List (MySub msg) -> () -> Task Never ()`. Replaces the
// stored router and subscriptions with `args[0]` and `args[2]`, reconciles every WebSocket that was or is subscribed or
// has an `Aux` entry, and asks the WebSocket event drain to deliver held closes if any are now due. Ignores the
// commands and the state, and returns a Task that succeeds with Unit. A list element whose constructor tag is neither
// `MySub` constructor's is skipped.
void* onEffectsEval(void* args[]) {
    HPointer router = dec(args[0]);
    HPointer subs = dec(args[2]);
    Elm::StackRootGuard g(&router, &subs);

    // Nothing allocates during the walk, so the resolved objects stay valid while their fields are copied out.
    std::map<int64_t, Subs> wanted;
    for (alloc::ListCursor c(subs); !c.done(); c.next()) {
        void* obj = Allocator::instance().resolve(c.current().p);
        Custom* sub = static_cast<Custom*>(obj);
        if (sub->ctor != CTOR_ON_MESSAGE && sub->ctor != CTOR_ON_CLOSE) continue;
        Subs& s = wanted[sub->values[SUB_WS_FIELD].i];
        uint64_t w = enc(sub->values[SUB_TAGGER_FIELD].p);
        (sub->ctor == CTOR_ON_MESSAGE ? s.messages : s.closes).push_back(w);
    }

    std::set<int64_t> ids;
    {
        // Nothing allocates while `st` is in use.
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
    if (held) requestWsWork(&deliverHeldCloses);

    return reinterpret_cast<void*>(enc(Scheduler::instance().taskSucceed(alloc::unit())));
}

// The evaluator of `onSelfMsg : Router -> Never -> () -> Task Never ()`. Returns a Task that succeeds with the state,
// `args[2]`. No self message is ever sent.
void* onSelfMsgEval(void* args[]) {
    return reinterpret_cast<void*>(enc(Scheduler::instance().taskSucceed(dec(args[2]))));
}

// The evaluator of the tagger `subMap` builds, with `f` and the old tagger captured as `args[0]` and `args[1]`.
// Returns `f (old x)` for the argument `x`, `args[2]`.
void* composedTaggerEval(void* args[]) {
    HPointer f = dec(args[0]);
    HPointer old = dec(args[1]);
    HPointer x = dec(args[2]);
    HPointer mid = alloc::listNil();
    Elm::StackRootGuard g({&f, &old, &x, &mid});
    mid = Scheduler::callClosure1(old, x);
    return reinterpret_cast<void*>(enc(Scheduler::callClosure1(f, mid)));
}

// The evaluator of `subMap : (a -> b) -> MySub a -> MySub b`. Returns a subscription with the same constructor and
// WebSocket id whose tagger applies `f` to what the old tagger returns. A value whose constructor tag is neither
// `MySub` constructor's is returned unchanged.
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
        if (s->ctor != CTOR_ON_MESSAGE && s->ctor != CTOR_ON_CLOSE)
            return reinterpret_cast<void*>(enc(sub));
        ctor = s->ctor;
        wsId = s->values[SUB_WS_FIELD].i;
        old = s->values[SUB_TAGGER_FIELD].p;
    }
    composed = alloc::allocClosure(&composedTaggerEval, 3);
    {
        // Nothing allocates between resolving the closure and the captures.
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
    (void)reconcile(wsId);
}

bool wsManagerHasSubscribers(int64_t wsId) {
    const Subs* s = subsOf(wsId);
    return s && (!s->messages.empty() || !s->closes.empty());
}

} // namespace Eco::System

using namespace Eco::System;

namespace {

// Allocates the manager's closures, keeping them rooted until all are allocated, and registers them under
// "WebSocket". The cmdMap is the empty list, since the manager has no commands.
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
    PlatformRuntime::instance().registerManager("WebSocket", info);   // Nothing allocates after the words are encoded.
}

} // namespace

extern "C" uint64_t Eco_System_registerManager_WebSocket() {
    ECO_KERNEL_GUARD(
        registerWsManager();
        return enc(alloc::unit());
    )
}
