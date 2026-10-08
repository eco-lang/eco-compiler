//===- WsTables.cpp - Main-thread WebSocket tables ------------------------===//
//
// See WsTables.hpp (plans/eco-system-websockets.md §3.6, Appendix B.1).
// Main thread only.
//
// Counts (G10, §3.6), released here:
//   * Dialed / UpgradeRead / Opened / OpDone / PingDone: the R-mode
//     operation's own count (AsyncRelease), resumed or orphaned (an orphaned
//     handshake's connection is aborted; an orphaned open's WebSocket too).
//   * Closed: the close handshake's count (once) and one per parked `closed`.
//
// Templates used: T3 (header lists), T5 (generation-keyed tables), T9
// (completions), G10 (AsyncRelease), G12 (drain per resume, by the drain).
//
//===----------------------------------------------------------------------===//

#include "eco-system/WebSocket/WsTables.hpp"

#include "eco-system/Core/AsyncRelease.hpp"
#include "eco-system/Core/IoReactor.hpp"
#include "eco-system/Socket/SocketTables.hpp"
#include "eco-system/Stream/Stream.hpp"
#include "eco-system/WebSocket/WsChannel.hpp"
#include "eco-system/WebSocket/WsManager.hpp"

#include "allocator/RootedSlots.hpp"

#include <algorithm>
#include <utility>

namespace Eco::System {

namespace {

constexpr size_t kRecentlyClosed = 4096;

IoReactor& reactor() { return IoReactor::instance(); }

void abortConn(const std::shared_ptr<Conn>& c) {
    if (!c) return;
    std::shared_ptr<Conn> cc = c;
    reactor().submit([cc] { cc->abort(false); });
}

void abortCore(const std::shared_ptr<WsCore>& k) {
    if (!k) return;
    std::shared_ptr<WsCore> kk = k;
    reactor().submit([kk] { kk->abortNow(); });
}

// A dead heap's entries: close their reactor objects (their counts and
// tokens died with the heap).
void resetTables(WsTables& t) {
    for (auto& kv : t.handshakes) {
        abortConn(kv.second.conn);
        if (std::shared_ptr<H2PendingUpgrade> h2 = kv.second.h2) reactor().submit([h2] { h2->abandon(); });
    }
    for (auto& kv : t.sockets) {
        if (!kv.second.closed) abortCore(kv.second.core);
    }
    for (auto& kv : t.pendingDials) (void)kv.second->cancel();
    t.handshakes.clear();
    t.sockets.clear();
    t.pendingDials.clear();
    t.recentlyClosed.clear();
}

// Takes `token`'s resume, rooted by the caller's guard. Nil: killed.
HPointer takeResume(uint64_t token) { return Scheduler::instance().takePendingResume(token); }

// ( Int, String, Int ) EpT (sockets plan §3.2). Fresh.
HPointer endpointOf(const SockEndpoint& ep) { return buildEndpoint(ep); }

// Erases a WebSocket whose faces are gone and that is Closed, keeping its
// CloseInfo in the bounded FIFO.
void maybeRetire(int64_t wsId) {
    auto& t = wsTables();
    auto it = t.sockets.find(wsId);
    if (it == t.sockets.end()) return;
    WsEntry& e = it->second;
    if (!e.closed || e.facesAlive > 0 || !e.closedWaiters.empty()) return;
    if (wsManagerHasSubscribers(wsId)) return;   // its held close may still be delivered
    t.recentlyClosed.emplace_back(wsId, e.info);
    while (t.recentlyClosed.size() > kRecentlyClosed) t.recentlyClosed.pop_front();
    t.sockets.erase(it);
}

// --- Event dispatchers (WsEvents.cpp drain) --------------------------------------

// dial → ( hsId, ( status, isH2 ), List ( String, List String ) ), masks 0x1 / 0x1.
bool onDialed(WsEvent& ev) {
    AsyncRelease release;   // the dial's count
    wsTables().pendingDials.erase(ev.token);
    HPointer resume = takeResume(ev.token);
    if (alloc::isNil(resume)) {
        abortConn(ev.conn);   // an orphaned handshake is closed
        return false;
    }
    HPointer task = alloc::listNil(), headers = alloc::listNil(), status = alloc::listNil();
    Elm::StackRootGuard g({&resume, &task, &headers, &status});
    if (ev.failed) {
        task = failFErr(ev.code, ev.message);
    } else {
        auto& t = wsTables();
        int64_t hsId = t.nextHsId++;
        t.handshakes.emplace(hsId, WsHandshakeEntry{ev.conn, false});
        headers = buildHeaderList(ev.headers);
        status = alloc::tuple2(alloc::unboxedInt(ev.status),
                               alloc::boxed(ev.isH2 ? alloc::elmTrue() : alloc::elmFalse()), 0x1);
        task = alloc::tuple3(alloc::unboxedInt(hsId), alloc::boxed(status), alloc::boxed(headers), 0x1);
        task = succeed(task);
    }
    Scheduler::callClosure1(resume, task);
    return true;
}

// readUpgrade → ( upId, ( method, target, version ), ( headers, isH2, remoteEpT ) ),
// masks 0x1 / 0 / 0.
bool onUpgradeRead(WsEvent& ev) {
    AsyncRelease release;
    HPointer resume = takeResume(ev.token);
    if (alloc::isNil(resume)) {
        abortConn(ev.conn);
        return false;
    }
    HPointer task = alloc::listNil(), line = alloc::listNil(), rest = alloc::listNil();
    HPointer a = alloc::listNil(), b = alloc::listNil(), c = alloc::listNil();
    Elm::StackRootGuard g({&resume, &task, &line, &rest, &a, &b, &c});
    if (ev.failed) {
        task = failFErr(ev.code, ev.message);
    } else {
        auto& t = wsTables();
        int64_t upId = t.nextHsId++;
        t.handshakes.emplace(upId, WsHandshakeEntry{ev.conn, true});
        a = alloc::allocStringFromUTF8(ev.method);
        b = alloc::allocStringFromUTF8(ev.target);
        c = alloc::allocStringFromUTF8(ev.version);
        line = alloc::tuple3(alloc::boxed(a), alloc::boxed(b), alloc::boxed(c), 0);
        a = buildHeaderList(ev.headers);
        b = endpointOf(ev.remote);
        rest = alloc::tuple3(alloc::boxed(a), alloc::boxed(alloc::elmFalse()), alloc::boxed(b), 0);
        task = alloc::tuple3(alloc::unboxedInt(upId), alloc::boxed(line), alloc::boxed(rest), 0x1);
        task = succeed(task);
    }
    Scheduler::callClosure1(resume, task);
    return true;
}

// open → ( wsId, ( readableId, writableId ), ( localEpT, remoteEpT ) ), masks 0x1 / 0x5 / 0.
bool onOpened(WsEvent& ev) {
    AsyncRelease release;
    HPointer resume = takeResume(ev.token);
    WsEntry* e = findWs(ev.wsId);
    if (alloc::isNil(resume)) {
        if (e && !ev.failed) abortCore(e->core);   // killed: nobody gets the WebSocket
        return false;
    }
    int64_t rid = e ? e->readableId : 0, wid = e ? e->writableId : 0;
    HPointer task = alloc::listNil(), ids = alloc::listNil(), local = alloc::listNil();
    HPointer remote = alloc::listNil(), eps = alloc::listNil();
    Elm::StackRootGuard g({&resume, &task, &ids, &local, &remote, &eps});
    if (ev.failed) {
        task = failFErr(ev.code, ev.message);
    } else {
        ids = alloc::tuple2(alloc::unboxedInt(rid), alloc::unboxedInt(wid), 0x5);
        local = endpointOf(ev.local);
        remote = endpointOf(ev.remote);
        eps = alloc::tuple2(alloc::boxed(local), alloc::boxed(remote), 0);
        task = alloc::tuple3(alloc::unboxedInt(ev.wsId), alloc::boxed(ids), alloc::boxed(eps), 0x1);
        task = succeed(task);
    }
    Scheduler::callClosure1(resume, task);
    return true;
}

bool onOpDone(WsEvent& ev) {
    AsyncRelease release;
    HPointer resume = takeResume(ev.token);
    if (alloc::isNil(resume)) return false;
    HPointer task = alloc::listNil();
    Elm::StackRootGuard g(&resume, &task);
    task = ev.failed ? failFErr(ev.code, ev.message) : succeedUnit();
    Scheduler::callClosure1(resume, task);
    return true;
}

bool onPingDone(WsEvent& ev) {
    AsyncRelease release;
    HPointer resume = takeResume(ev.token);
    if (alloc::isNil(resume)) return false;
    HPointer task = alloc::listNil();
    Elm::StackRootGuard g(&resume, &task);
    task = ev.failed ? failFErr(ev.code, ev.message) : succeedInt(ev.rtt);
    Scheduler::callClosure1(resume, task);
    return true;
}

bool onClosed(WsEvent& ev) {
    WsEntry* e = findWs(ev.wsId);
    if (!e || e->closed) return false;
    e->closed = true;
    e->info = WsCloseInfo{ev.closeCode, ev.reason, ev.clean};
    AsyncRelease handshakeCount(e->closeCounted);   // the close handshake's count, once
    e->closeCounted = false;
    std::vector<uint64_t> waiters;
    waiters.swap(e->closedWaiters);
    WsCloseInfo info = e->info;
    bool resumed = false;
    for (uint64_t token : waiters) {
        AsyncRelease waiterCount;
        HPointer resume = takeResume(token);
        if (alloc::isNil(resume)) continue;
        HPointer reason = alloc::listNil(), task = alloc::listNil();
        Elm::StackRootGuard g(&resume, &reason, &task);
        reason = alloc::allocStringFromUTF8(info.reason);
        task = alloc::tuple3(alloc::unboxedInt(info.code), alloc::boxed(reason),
                             alloc::boxed(info.clean ? alloc::elmTrue() : alloc::elmFalse()), 0x1);
        task = succeed(task);
        Scheduler::callClosure1(resume, task);
        Scheduler::instance().drain();   // G12: once per resumed task
        resumed = true;
    }
    // onClose subscribers (C.2): delivered now, or held for the first one.
    wsManagerOnClosed(ev.wsId);
    maybeRetire(ev.wsId);
    (void)resumed;
    return false;   // drained per resume above
}

// WS6: a streamed message started: its body's pair (a plain channel source
// over a WsBodyChannel; text bodies yield Strings), whose id the core
// announces on the readable. A WebSocket gone from the tables gets none.
bool onBodyNeeded(WsEvent& ev) {
    WsEntry* e = findWs(ev.wsId);
    if (!e || !e->core) return false;
    std::shared_ptr<WsCore> core = e->core;
    uint64_t seq = ev.bodySeq;
    int64_t pid = createChannelSource(new WsBodyChannel(core, seq));
    reactor().submit([core, seq, pid] { core->bodyReady(seq, pid); });
    return false;
}

bool onBodyDispose(WsEvent& ev) {
    discardReadable(ev.pairId);
    return true;   // it may have completed parked tasks
}

} // namespace

// ---------------------------------------------------------------------------
// Tables
// ---------------------------------------------------------------------------

WsTables& wsTables() {
    static auto* t = new WsTables();   // leaky (§3.4)
    uint64_t g = currentHeapGeneration();
    if (!t->init || t->gen != g) {
        if (t->init) resetTables(*t);
        t->init = true;
        t->gen = g;
    }
    return *t;
}

WsEntry* findWs(int64_t wsId) {
    auto& m = wsTables().sockets;
    auto it = m.find(wsId);
    return it == m.end() ? nullptr : &it->second;
}

void ensureWsTables() {
    ensureWsEvents();
    ensureSocketTables();
    static bool done = false;   // main thread only
    if (done) return;
    done = true;
    setWsEventDispatch(WsEvent::Kind::Dialed, &onDialed);
    setWsEventDispatch(WsEvent::Kind::UpgradeRead, &onUpgradeRead);
    setWsEventDispatch(WsEvent::Kind::Opened, &onOpened);
    setWsEventDispatch(WsEvent::Kind::OpDone, &onOpDone);
    setWsEventDispatch(WsEvent::Kind::PingDone, &onPingDone);
    setWsEventDispatch(WsEvent::Kind::Closed, &onClosed);
    setWsEventDispatch(WsEvent::Kind::BodyNeeded, &onBodyNeeded);
    setWsEventDispatch(WsEvent::Kind::BodyDispose, &onBodyDispose);
}

int64_t wsTablesAddServerHandshake(std::shared_ptr<Conn> conn) {
    auto& t = wsTables();
    int64_t id = t.nextHsId++;
    t.handshakes.emplace(id, WsHandshakeEntry{std::move(conn), true});
    return id;
}

int64_t wsTablesAddServerH2Handshake(std::shared_ptr<H2PendingUpgrade> h2) {
    auto& t = wsTables();
    int64_t id = t.nextHsId++;
    WsHandshakeEntry e;
    e.server = true;
    e.h2 = std::move(h2);
    t.handshakes.emplace(id, std::move(e));
    return id;
}

WsCloseInfo wsRecentCloseInfo(int64_t wsId) {
    for (const auto& [id, info] : wsTables().recentlyClosed) {
        if (id == wsId) return info;
    }
    return WsCloseInfo{};
}

void wsTablesCloseStarted(int64_t wsId) {
    WsEntry* e = findWs(wsId);
    if (!e || e->closed || e->closeCounted) return;
    e->closeCounted = true;
    Scheduler::instance().incrementPendingAsync();
}

void wsTablesFaceGone(int64_t wsId) {
    WsEntry* e = findWs(wsId);
    if (!e) return;
    --e->facesAlive;
    maybeRetire(wsId);
}

void wsTablesRetire(int64_t wsId) { maybeRetire(wsId); }

bool cancelPendingDial(uint64_t token) {
    auto& m = wsTables().pendingDials;
    auto it = m.find(token);
    if (it == m.end()) return false;   // its Dialed event is queued: the drain decrements
    std::shared_ptr<DialJob> job = it->second;
    m.erase(it);
    return job->cancel();
}

bool cancelClosedWaiter(uint64_t token) {
    for (auto& kv : wsTables().sockets) {
        auto& w = kv.second.closedWaiters;
        auto it = std::find(w.begin(), w.end(), token);
        if (it == w.end()) continue;
        w.erase(it);
        return true;   // it held a count: the kill handle releases it
    }
    return false;
}

HPointer buildHeaderList(const HeaderList& headers) {
    alloc::RootedSlots slots(headers.size());
    for (const auto& [name, value] : headers) {
        HPointer n = alloc::listNil(), v = alloc::listNil(), vs = alloc::listNil();
        Elm::StackRootGuard g({&n, &v, &vs});
        n = alloc::allocStringFromUTF8(name);
        v = alloc::allocStringFromUTF8(value);
        vs = alloc::cons(alloc::boxed(v), alloc::listNil(), static_cast<u8>(0));
        slots.push(alloc::tuple2(alloc::boxed(n), alloc::boxed(vs), 0));
    }
    return alloc::listFromPointers(slots);
}

} // namespace Eco::System
