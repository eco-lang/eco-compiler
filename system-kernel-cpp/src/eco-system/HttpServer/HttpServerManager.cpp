//===- HttpServerManager.cpp - The C++ effect manager of Http.Server ------===//
//
// plans/eco-system-library.md §3.6, Appendix C.0 / C.5 and Phase 7 step
// 7.2. Layout: HttpServerManager.hpp.
//
//   * onEffects: the OnRequest taggers are grouped by server id (encoded
//     words in a T5 registry, with the router). Subscriptions hold no
//     pendingAsync: the listening server already does (§3.4).
//   * subMap composes the tagger (TimeEffectManager pattern) and keeps the
//     unboxed server id (mask 0x1). There are no commands.
//   * The module drain (one eco/system async source) first completes the
//     respond tasks whose responses were written (G10: take the resume,
//     resume with (), decrement exactly once), then delivers each POD
//     RequestEvent (T8/G12): build the tagger argument once (fully rooted,
//     G4/G6), snapshot the server's taggers into one rooted range, and for
//     each tagger: call it, sendToApp, drain().
//   * A request for a server nobody subscribes to (yet) is parked (POD,
//     main thread) and delivered by the drain once onEffects sees a
//     subscription for that server; the subscription normally follows
//     createServer within the same update, but nothing forces a program to
//     subscribe before the first client connects.
//   * Windows: an OnRequest subscription crashes with a clear message (§1).
//
// Templates used: T6 (rooted registration per G14), T5, T8/G12, G6, G10.
//
//===----------------------------------------------------------------------===//

#include "eco-system/HttpServer/HttpServerManager.hpp"

#include "eco-system/Core/AsyncRelease.hpp"
#include "eco-system/Core/AsyncSources.hpp"
#include "eco-system/Core/Core.hpp"
#include "eco-system/Core/Registry.hpp"
#include "eco-system/HttpServer/HttpServerService.hpp"

#include <atomic>
#include <cstring>
#include <deque>
#include <map>
#include <string>
#include <unordered_map>
#include <utility>
#include <vector>

namespace Eco::System {

namespace {

using namespace HttpServerManager;
using HttpSrv::HttpServerService;
using HttpSrv::RequestEvent;

struct ManagerState {
    uint64_t routerEnc = 0;
    std::map<int64_t, std::vector<uint64_t>> taggers;   // server id → encoded taggers

    template <typename F>
    void forEachWord(F&& f) {
        f(routerEnc);
        for (auto& kv : taggers)
            for (auto& w : kv.second) f(w);
    }
};

Registry<ManagerState>& registry() {
    static auto* r = new Registry<ManagerState>("eco-system-http-server-manager");   // leaky
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

// Requests that arrived while their server had no subscriber. POD, main
// thread only (no scanner needed).
std::unordered_map<int64_t, std::deque<RequestEvent>>& parked() {
    static auto* m = new std::unordered_map<int64_t, std::deque<RequestEvent>>();   // leaky
    return *m;
}

// Set by onEffects when a parked server gained a subscriber; read by the
// ready predicate and the drain (both on the main thread).
std::atomic<bool> g_parkedReady{false};

bool hasSubscriber(int64_t serverId) {
    ManagerState& st = state();
    if (st.routerEnc == 0) return false;
    auto it = st.taggers.find(serverId);
    return it != st.taggers.end() && !it->second.empty();
}

// --- Delivery (T8) -------------------------------------------------------------

// A Bytes value holding `b` (T4); empty → the embedded constant (HEAP_071).
HPointer makeBytes(const std::string& b) {
    if (b.empty()) return alloc::emptyBytes();
    alloc::BlankByteBuffer bb = alloc::allocByteBufferBlank(b.size());
    std::memcpy(bb.bytes, b.data(), b.size());   // no allocation in between (G8)
    return bb.hp;
}

void deliver(const RequestEvent& ev) {
    if (!hasSubscriber(ev.serverId)) {
        parked()[ev.serverId].push_back(ev);
        return;
    }

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
    Elm::StackRootGuard g({&router, &arg, &msg, &hdrs, &body, &mu, &hb, &name, &value, &values});
    auto& rs = Allocator::instance().getRootSet();

    // ( name, [ value ] ) per header occurrence (T3: one rooted range).
    {
        std::vector<HPointer> ptrs(ev.headers.size(), alloc::listNil());
        size_t saved = rs.stackRangePoint();
        rs.pushStackRootRange(ptrs.data(), ptrs.size(), ~0ULL);
        for (size_t i = 0; i < ev.headers.size(); ++i) {
            name = alloc::allocStringFromUTF8(ev.headers[i].first);
            value = alloc::allocStringFromUTF8(ev.headers[i].second);
            // A one-element list: a single cons, not a list-building loop (G6).
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
    arg = alloc::tuple3(alloc::boxed(mu), alloc::boxed(hb), alloc::unboxedInt(ev.key), TAGGER_ARG_MASK);

    // Snapshot the taggers: update may change the subscriptions while we
    // deliver (G11). No allocation from the decodes to the range push.
    ManagerState& st = state();
    const std::vector<uint64_t>& words = st.taggers[ev.serverId];
    std::vector<HPointer> taggers;
    taggers.reserve(words.size());
    for (uint64_t w : words) taggers.push_back(dec(w));
    router = dec(st.routerEnc);
    size_t saved = rs.stackRangePoint();
    rs.pushStackRootRange(taggers.data(), taggers.size(), ~0ULL);
    for (size_t i = 0; i < taggers.size(); ++i) {
        msg = Scheduler::callClosure1(taggers[i], arg);   // Elm call (G11)
        PlatformRuntime::instance().sendToApp(router, msg);
        Scheduler::instance().drain();                    // once per message (G12)
    }
    rs.restoreStackRangePoint(saved);
}

// Respond completions (G10): exactly one decrement per token.
void completeResponses(std::vector<uint64_t>& tokens) {
    if (tokens.empty()) return;
    auto& s = Scheduler::instance();
    for (uint64_t token : tokens) {
        AsyncRelease release;   // decrements on every path
        HPointer resume = s.takePendingResume(token);
        if (alloc::isNil(resume)) continue;   // the task was killed
        HPointer task = alloc::listNil();
        Elm::StackRootGuard g(&resume, &task);
        task = succeedUnit();
        Scheduler::callClosure1(resume, task);
    }
    s.drain();
}

void httpServerDrain() {
    try {
        std::vector<uint64_t> done;
        HttpServerService::instance().drainDone(done);
        completeResponses(done);

        std::vector<RequestEvent> evs;
        if (g_parkedReady.exchange(false)) {
            // Parked requests of servers that now have a subscriber go first:
            // they arrived earlier.
            auto& p = parked();
            for (auto it = p.begin(); it != p.end();) {
                if (hasSubscriber(it->first)) {
                    for (auto& ev : it->second) evs.push_back(std::move(ev));
                    it = p.erase(it);
                } else {
                    ++it;
                }
            }
        }
        HttpServerService::instance().drainRequests(evs);
        for (const auto& ev : evs) deliver(ev);
    } catch (const std::exception& e) {
        ::Eco::Kernel::reportFatal(e.what());   // never unwind into the loop (F21)
    } catch (...) {
        ::Eco::Kernel::reportFatal("unknown native exception in Http.Server request delivery");
    }
}

bool httpServerReady() {
    return HttpServerService::instance().hasEvents() || g_parkedReady.load();
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
        if (sub->ctor != CTOR_ON_REQUEST) continue;
        wanted[sub->values[ON_REQUEST_SERVER_FIELD].i].push_back(
            enc(sub->values[ON_REQUEST_TAGGER_FIELD].p));
    }

#if defined(_WIN32)
    // A Sub is infallible: crash with a clear message (§1).
    if (!wanted.empty())
        ::Eco::Kernel::reportFatal("eco/system: Http.Server.onRequest is not supported on Windows yet");
#endif

    // Registry update: POD only, no heap allocation while `st` is live.
    {
        ManagerState& st = state();
        st.routerEnc = enc(router);
        st.taggers = std::move(wanted);
        for (const auto& kv : parked()) {
            if (!kv.second.empty() && hasSubscriber(kv.first)) {
                g_parkedReady.store(true);   // the drain delivers them
                ensureHttpServerDrain();
                break;
            }
        }
    }

    return reinterpret_cast<void*>(enc(Scheduler::instance().taskSucceed(alloc::unit())));
}

// onSelfMsg : Router -> Never -> () -> Task Never ()  (never sent)
void* onSelfMsgEval(void* args[]) {
    return reinterpret_cast<void*>(enc(Scheduler::instance().taskSucceed(dec(args[2]))));
}

// The composed tagger of subMap: args[0] = f, args[1] = old tagger,
// args[2] = the request tuple. Result: f (old request).
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
        // Both captures right after the allocation, nothing allocated in between (G8).
        void* p = Allocator::instance().resolve(composed);
        alloc::closureCapture(p, alloc::boxed(f), PK_Boxed);
        alloc::closureCapture(p, alloc::boxed(old), PK_Boxed);
    }
    std::vector<Unboxable> fields{alloc::unboxedInt(serverId), alloc::boxed(composed)};
    return reinterpret_cast<void*>(enc(alloc::custom(CTOR_ON_REQUEST, fields, ON_REQUEST_MASK)));
}

} // namespace

void ensureHttpServerDrain() {
    addDrainSource(&httpServerDrain, &httpServerReady);   // idempotent
}

} // namespace Eco::System

using namespace Eco::System;

namespace {

// Allocates the manager closures in the rooted PortRuntime form (G14) and
// registers them under "Http.Server". Subscriptions only: no cmdMap.
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
    subMapCl = alloc::allocClosure(&subMapEval, 2);
    PlatformRuntime::ManagerInfo info{enc(initCl), enc(effCl), enc(selfCl),
                                      enc(cmdMapCl), enc(subMapCl)};
    PlatformRuntime::instance().registerManager("Http.Server", info);   // no allocation after encode
}

} // namespace

extern "C" uint64_t Eco_System_registerManager_Http_Server() {
    ECO_KERNEL_GUARD(
        registerHttpServerManager();
        return enc(alloc::unit());
    )
}
