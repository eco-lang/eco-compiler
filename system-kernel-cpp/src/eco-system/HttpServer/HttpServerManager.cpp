//===- HttpServerManager.cpp - The C++ effect manager of Http.Server ------===//
//
// The manager's state, the router and every server's taggers, is one entry of a `Registry`, so the collector keeps
// those values alive and updates their encoded words when it moves them. Each function decodes the words it needs,
// or writes new ones, with no allocation in between, so the decoded pointers are current until they are rooted.
//
//===----------------------------------------------------------------------===//

#include "eco-system/HttpServer/HttpServerManager.hpp"

#include "eco-system/Core/Core.hpp"
#include "eco-system/Core/Registry.hpp"
#include "eco-system/HttpServer/HttpTables.hpp"

#include <cstring>
#include <map>
#include <string>
#include <utility>
#include <vector>

namespace Eco::System {

namespace {

using namespace HttpServerManager;
using HttpSrv::RequestData;

/// The manager's state: the router of the last `onEffects`, and the taggers of the current subscriptions grouped by
/// server id, in subscription order. All are encoded HPointer words; `routerEnc` is 0 until the first `onEffects`.
struct ManagerState {
    uint64_t routerEnc = 0;
    std::map<int64_t, std::vector<uint64_t>> taggers;

    /// Calls `f` on every encoded word the state holds, as `Registry` requires.
    template <typename F>
    void forEachWord(F&& f) {
        f(routerEnc);
        for (auto& kv : taggers)
            for (auto& w : kv.second) f(w);
    }
};

/// Returns the registry that holds the manager's state. It is created on the first call and never deleted, as
/// `Registry` requires.
Registry<ManagerState>& registry() {
    static auto* r = new Registry<ManagerState>("eco-system-http-server-manager");
    return *r;
}

/// Returns the manager's single state entry, creating an empty one on the first call and after a heap reset has
/// discarded the registry's entries. The reference is invalidated when a heap reset discards the entry.
ManagerState& state() {
    static int64_t id = 0;
    auto& r = registry();
    if (ManagerState* s = r.find(id)) return *s;
    id = r.insert(ManagerState{});
    return *r.find(id);
}

/// Returns whether any current `OnRequest` subscription names `serverId`; false before the first `onEffects`.
/// Installed as `HttpManagerHooks::hasSubscriber`.
bool hasSubscriber(int64_t serverId) {
    ManagerState& st = state();
    if (st.routerEnc == 0) return false;
    auto it = st.taggers.find(serverId);
    return it != st.taggers.end() && !it->second.empty();
}

// --- Delivery -------------------------------------------------------------------

/// Returns a new `Bytes` value holding a copy of `b`, or the shared empty `Bytes` constant when `b` is empty. A GC
/// point when `b` is not empty.
HPointer makeBytes(const std::string& b) {
    if (b.empty()) return alloc::emptyBytes();
    alloc::BlankByteBuffer bb = alloc::allocByteBufferBlank(b.size());
    std::memcpy(bb.bytes, b.data(), b.size());
    return bb.hp;
}

/// Builds the tagger argument for request `key` of `serverId` from `ev`, then, for each tagger of `serverId` as the
/// subscriptions stood on entry, calls it on that argument, sends the result to the program and drains the
/// scheduler once. Calls nothing when the server has no taggers. Installed as
/// `HttpManagerHooks::deliver`; runs Elm code, which may change the subscriptions.
void deliver(int64_t serverId, int64_t key, const RequestData& ev) {
    HPointer router = alloc::listNil();
    HPointer arg = alloc::listNil();
    HPointer msg = alloc::listNil();
    HPointer hdrs = alloc::listNil();
    HPointer body = alloc::listNil();
    HPointer mu = alloc::listNil();
    HPointer hb = alloc::listNil();
    HPointer name = alloc::listNil();
    HPointer value = alloc::listNil();
    HPointer values = alloc::listNil();
    HPointer kfu = alloc::listNil();
    Elm::StackRootGuard g({&router, &arg, &msg, &hdrs, &body, &mu, &hb, &name, &value, &values, &kfu});
    auto& rs = Allocator::instance().getRootSet();

    // The header pairs are collected in a rooted range and turned into a list in one call.
    {
        std::vector<HPointer> ptrs(ev.headers.size(), alloc::listNil());
        size_t saved = rs.stackRangePoint();
        rs.pushStackRootRange(ptrs.data(), ptrs.size(), ~0ULL);
        for (size_t i = 0; i < ev.headers.size(); ++i) {
            name = alloc::allocStringFromUTF8(ev.headers[i].first);
            value = alloc::allocStringFromUTF8(ev.headers[i].second);
            values = alloc::cons(alloc::boxed(value), alloc::listNil(), true);
            ptrs[i] = alloc::tuple2(alloc::boxed(name), alloc::boxed(values), 0);
        }
        hdrs = alloc::listFromPointers(ptrs);
        rs.restoreStackRangePoint(saved);
    }
    body = makeBytes(ev.body);
    hb = alloc::tuple2(alloc::boxed(hdrs), alloc::boxed(body), 0);
    name = alloc::allocStringFromUTF8(ev.method);
    value = alloc::allocStringFromUTF8(ev.url);
    mu = alloc::tuple2(alloc::boxed(name), alloc::boxed(value), 0);
    name = alloc::allocStringFromUTF8(ev.upgrade);
    kfu = alloc::tuple3(alloc::unboxedInt(key), alloc::unboxedInt(ev.flags), alloc::boxed(name),
                        TAGGER_KEY_MASK);
    arg = alloc::tuple3(alloc::boxed(mu), alloc::boxed(hb), alloc::boxed(kfu), TAGGER_ARG_MASK);

    // Snapshot the taggers, since a tagger or the drain may run onEffects and replace them. Nothing allocates
    // between the decodes and the range push, so the decoded pointers are current when they become roots.
    ManagerState& st = state();
    const std::vector<uint64_t>& words = st.taggers[serverId];
    std::vector<HPointer> taggers;
    taggers.reserve(words.size());
    for (uint64_t w : words) taggers.push_back(dec(w));
    router = dec(st.routerEnc);
    size_t saved = rs.stackRangePoint();
    rs.pushStackRootRange(taggers.data(), taggers.size(), ~0ULL);
    for (size_t i = 0; i < taggers.size(); ++i) {
        msg = Scheduler::callClosure1(taggers[i], arg);
        PlatformRuntime::instance().sendToApp(router, msg);
        Scheduler::instance().drain();
    }
    rs.restoreStackRangePoint(saved);
}

// --- Manager closures -----------------------------------------------------------

/// Evaluates `init`: returns a task that succeeds with `()`, the manager's unused Elm state.
void* initEval(void*[]) {
    return reinterpret_cast<void*>(enc(Scheduler::instance().taskSucceed(alloc::unit())));
}

/// Evaluates `onEffects router cmds subs ()`. Replaces the stored router and taggers with those of `subs` and tells
/// `HttpTables` the subscriptions changed. Then spawns the task of every `Respond` in `cmds` and, if there was
/// any, drains the scheduler. Returns a task that succeeds with `()`. On Windows, any `OnRequest` subscription is
/// a fatal error.
void* onEffectsEval(void* args[]) {
    HPointer router = dec(args[0]);
    HPointer cmds = dec(args[1]);
    HPointer subs = dec(args[2]);
    Elm::StackRootGuard g(&router, &cmds, &subs);

    // Nothing allocates in this walk, so `subs` and the resolved objects stay current.
    std::map<int64_t, std::vector<uint64_t>> wanted;
    for (alloc::ListCursor c(subs); !c.done(); c.next()) {
        void* obj = Allocator::instance().resolve(c.current().p);
        if (!obj) continue;
        Custom* sub = static_cast<Custom*>(obj);
        if (sub->ctor != CTOR_ON_REQUEST) continue;
        wanted[sub->values[ON_REQUEST_SERVER_FIELD].i].push_back(
            enc(sub->values[ON_REQUEST_TAGGER_FIELD].p));
    }

#if defined(_WIN32)
    // A subscription has no way to report failure.
    if (!wanted.empty())
        ::Eco::Kernel::reportFatal("eco/system: Http.Server.onRequest is not supported on Windows yet");
#endif

    {
        ManagerState& st = state();
        st.routerEnc = enc(router);
        st.taggers = std::move(wanted);
    }
    HttpSrv::httpTablesSubscriptionsChanged();

    // Spawning allocates, so the list is walked with a rooted cursor.
    bool spawned = false;
    {
        alloc::RootedListCursor c(cmds);
        Unboxable head;
        u8 kind;
        while (c.read(head, kind)) {
            HPointer task;
            {
                Custom* cmd = static_cast<Custom*>(Allocator::instance().resolve(head.p));
                task = cmd->values[RESPOND_TASK_FIELD].p;   // no allocation in scope
            }
            Scheduler::instance().rawSpawn(task);           // allocProcess roots `task`
            spawned = true;
            c.advance();
        }
    }
    if (spawned) Scheduler::instance().drain();

    return reinterpret_cast<void*>(enc(Scheduler::instance().taskSucceed(alloc::unit())));
}

/// Evaluates `onSelfMsg router msg state`: returns a task that succeeds with `state`. The manager sends itself
/// no messages.
void* onSelfMsgEval(void* args[]) {
    return reinterpret_cast<void*>(enc(Scheduler::instance().taskSucceed(dec(args[2]))));
}

/// Evaluates `cmdMap f cmd`: returns `cmd` unchanged, since `Respond` produces no message.
void* cmdMapEval(void* args[]) {
    return args[1];
}

/// Evaluates the tagger `subMap` builds, with captures `f` and `old` in `args[0]` and `args[1]` and the tagger
/// argument in `args[2]`: returns `f (old arg)`.
void* composedTaggerEval(void* args[]) {
    HPointer f = dec(args[0]);
    HPointer old = dec(args[1]);
    HPointer x = dec(args[2]);
    HPointer mid = alloc::listNil();
    Elm::StackRootGuard g({&f, &old, &x, &mid});
    mid = Scheduler::callClosure1(old, x);
    return reinterpret_cast<void*>(enc(Scheduler::callClosure1(f, mid)));
}

/// Evaluates `subMap f sub`: returns an `OnRequest` with the same server id whose tagger applies the old tagger and
/// then `f`. Returns `sub` unchanged if it is not an `OnRequest`, or `resolve` returns null for it.
void* subMapEval(void* args[]) {
    HPointer f = dec(args[0]);
    HPointer sub = dec(args[1]);
    HPointer old = alloc::listNil();
    HPointer composed = alloc::listNil();
    int64_t serverId = 0;
    Elm::StackRootGuard g({&f, &sub, &old, &composed});
    {
        Custom* s = static_cast<Custom*>(Allocator::instance().resolve(sub));   // no allocation in scope
        if (!s || s->ctor != CTOR_ON_REQUEST) return reinterpret_cast<void*>(enc(sub));
        serverId = s->values[ON_REQUEST_SERVER_FIELD].i;
        old = s->values[ON_REQUEST_TAGGER_FIELD].p;
    }
    composed = alloc::allocClosure(&composedTaggerEval, 3);
    {
        // Nothing allocates between the closure's allocation and the captures, so `p` stays current.
        void* p = Allocator::instance().resolve(composed);
        alloc::closureCapture(p, alloc::boxed(f), PK_Boxed);
        alloc::closureCapture(p, alloc::boxed(old), PK_Boxed);
    }
    std::vector<Unboxable> fields{alloc::unboxedInt(serverId), alloc::boxed(composed)};
    return reinterpret_cast<void*>(enc(alloc::custom(CTOR_ON_REQUEST, fields, ON_REQUEST_MASK)));
}

} // namespace


} // namespace Eco::System

using namespace Eco::System;

namespace {

/// Allocates the five manager closures, registers them under "Http.Server", and installs `hasSubscriber` and
/// `deliver` as the `HttpTables` hooks.
void registerHttpServerManager() {
    HPointer initCl = alloc::listNil();
    HPointer effCl = alloc::listNil();
    HPointer selfCl = alloc::listNil();
    HPointer cmdMapCl = alloc::listNil();
    HPointer subMapCl = alloc::listNil();
    Elm::StackRootGuard g({&initCl, &effCl, &selfCl, &cmdMapCl, &subMapCl});
    initCl = alloc::allocClosure(&initEval, 0);
    effCl = alloc::allocClosure(&onEffectsEval, 4);
    selfCl = alloc::allocClosure(&onSelfMsgEval, 3);
    cmdMapCl = alloc::allocClosure(&cmdMapEval, 2);
    subMapCl = alloc::allocClosure(&subMapEval, 2);
    PlatformRuntime::ManagerInfo info{enc(initCl), enc(effCl), enc(selfCl),
                                      enc(cmdMapCl), enc(subMapCl)};
    PlatformRuntime::instance().registerManager("Http.Server", info);
    HttpSrv::HttpManagerHooks hooks;
    hooks.hasSubscriber = &hasSubscriber;
    hooks.deliver = &deliver;
    HttpSrv::setHttpManagerHooks(hooks);
}

} // namespace

extern "C" uint64_t Eco_System_registerManager_Http_Server() {
    ECO_KERNEL_GUARD(
        registerHttpServerManager();
        return enc(alloc::unit());
    )
}
