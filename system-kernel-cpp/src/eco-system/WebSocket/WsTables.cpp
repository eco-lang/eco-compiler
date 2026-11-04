//===- WsTables.cpp - Eco-thread WebSocket tables -------------------------===//
//
// Every hold a dispatch function releases is released by a `HoldRelease` declared before the resume, so it is
// released at scope end, after the task has been resumed.
//
//===----------------------------------------------------------------------===//

#include "eco-system/WebSocket/WsTables.hpp"

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

/// The most `WsCloseInfo` entries kept for erased WebSockets.
constexpr size_t kRecentlyClosed = 4096;

/// Returns the reactor that WebSocket connections run on.
IoReactor& reactor() { return IoReactor::instance(); }

/// Asks the reactor to abort `c`, if it is not null.
void abortConn(const std::shared_ptr<Conn>& c) {
    if (!c) return;
    std::shared_ptr<Conn> cc = c;
    reactor().submit([cc] { cc->abort(false); });
}

/// Asks the reactor to abandon WebSocket `k` at once, if it is not null.
void abortCore(const std::shared_ptr<WsCore>& k) {
    if (!k) return;
    std::shared_ptr<WsCore> kk = k;
    reactor().submit([kk] { kk->abortNow(); });
}

/// Empties `t` for a new heap generation, as the header's file comment describes.
void resetTables(WsTables& t) {
    for (auto& kv : t.handshakes) {
        HoldRelease peerHold(kv.second.peerHold);
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

/// Takes the resume closure parked under `token`, or nil if its task was killed. The result is not rooted.
HPointer takeResume(uint64_t token) { return Scheduler::instance().takePendingResume(token); }

/// Builds the Elm value of endpoint `ep`, as `buildEndpoint` does. The result is not rooted.
HPointer endpointOf(const SockEndpoint& ep) { return buildEndpoint(ep); }

/// Erases the entry of WebSocket `wsId` if it has ended, both faces are gone, no `closed` task is parked on it and
/// no subscription names it, keeping its `WsCloseInfo` in `recentlyClosed` and dropping the oldest beyond
/// `kRecentlyClosed`.
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

// --- Event dispatchers --------------------------------------------------------------

/// Resumes a `dial` task with `( hsId, ( status, isH2 ), headers )`, registering the connection as a client
/// handshake, or with the failure. Returns whether a task was resumed. Unboxed-field masks: 0x1 and 0x1.
bool onDialed(WsEvent& ev) {
    HoldRelease release(ev.token);
    wsTables().pendingDials.erase(ev.token);
    HPointer resume = takeResume(ev.token);
    if (alloc::isNil(resume)) {
        abortConn(ev.conn);
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

/// Resumes a `readUpgrade` task with `( upId, ( method, target, version ), ( headers, isH2, remote ) )`,
/// registering the connection as a server handshake, or with the failure. `isH2` is always False. Returns whether a
/// task was resumed. Unboxed-field masks: 0x1, 0 and 0.
bool onUpgradeRead(WsEvent& ev) {
    HoldRelease release(ev.token);
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

/// Resumes an `open` task with `( wsId, ( readableId, writableId ), ( local, remote ) )`, or with the failure. The
/// stream ids are 0 if the WebSocket has no entry. Returns whether a task was resumed. Unboxed-field masks: 0x1,
/// 0x5 and 0.
bool onOpened(WsEvent& ev) {
    HoldRelease release(ev.token);
    HPointer resume = takeResume(ev.token);
    WsEntry* e = findWs(ev.wsId);
    if (alloc::isNil(resume)) {
        if (e && !ev.failed) abortCore(e->core);
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

/// Resumes a close or reject task with unit, or with the failure. Returns whether a task was resumed.
bool onOpDone(WsEvent& ev) {
    HoldRelease release(ev.token);
    HPointer resume = takeResume(ev.token);
    if (alloc::isNil(resume)) return false;
    HPointer task = alloc::listNil();
    Elm::StackRootGuard g(&resume, &task);
    task = ev.failed ? failFErr(ev.code, ev.message) : succeedUnit();
    Scheduler::callClosure1(resume, task);
    return true;
}

/// Resumes a `ping` task with the round-trip time, or with the failure. Returns whether a task was resumed.
bool onPingDone(WsEvent& ev) {
    HoldRelease release(ev.token);
    HPointer resume = takeResume(ev.token);
    if (alloc::isNil(resume)) return false;
    HPointer task = alloc::listNil();
    Elm::StackRootGuard g(&resume, &task);
    task = ev.failed ? failFErr(ev.code, ev.message) : succeedInt(ev.rtt);
    Scheduler::callClosure1(resume, task);
    return true;
}

/// Records the end of a WebSocket, as the header's file comment describes, and erases the entry if that leaves it
/// ready to be erased. Does nothing for a WebSocket with no entry or one already ended. Returns false, because it
/// drains the Scheduler after each task it resumes.
bool onClosed(WsEvent& ev) {
    WsEntry* e = findWs(ev.wsId);
    if (!e || e->closed) return false;
    e->closed = true;
    e->info = WsCloseInfo{ev.closeCode, ev.reason, ev.clean};
    HoldRelease handshakeHold(e->closeHold);
    e->closeHold = kNoHold;
    std::vector<uint64_t> waiters;
    waiters.swap(e->closedWaiters);
    WsCloseInfo info = e->info;
    bool resumed = false;
    for (uint64_t token : waiters) {
        HoldRelease waiterHold(token);
        HPointer resume = takeResume(token);
        if (alloc::isNil(resume)) continue;
        HPointer reason = alloc::listNil(), task = alloc::listNil();
        Elm::StackRootGuard g(&resume, &reason, &task);
        reason = alloc::allocStringFromUTF8(info.reason);
        task = alloc::tuple3(alloc::unboxedInt(info.code), alloc::boxed(reason),
                             alloc::boxed(info.clean ? alloc::elmTrue() : alloc::elmFalse()), 0x1);
        task = succeed(task);
        Scheduler::callClosure1(resume, task);
        Scheduler::instance().drain();
        resumed = true;
    }
    wsManagerOnClosed(ev.wsId);
    maybeRetire(ev.wsId);
    (void)resumed;
    return false;
}

/// Creates the stream pair of a streamed message's body, a channel source over a `WsBodyChannel`, and hands its id
/// to the WebSocket's core on the reactor. Does nothing for a WebSocket with no entry or no core. Returns false.
bool onBodyNeeded(WsEvent& ev) {
    WsEntry* e = findWs(ev.wsId);
    if (!e || !e->core) return false;
    std::shared_ptr<WsCore> core = e->core;
    uint64_t seq = ev.bodySeq;
    int64_t pid = createChannelSource(new WsBodyChannel(core, seq));
    reactor().submit([core, seq, pid] { core->bodyReady(seq, pid); });
    return false;
}

/// Discards the stream pair `ev.pairId`. Returns true.
bool onBodyDispose(WsEvent& ev) {
    discardReadable(ev.pairId);
    return true;   // it may have completed parked tasks
}

/// Releases the peer hold of handshake `ev.wsId`, whose connection has gone before the handshake was answered. The
/// entry stays in the table. Returns false.
bool onHandshakeGone(WsEvent& ev) {
    auto& t = wsTables();
    auto it = t.handshakes.find(ev.wsId);
    if (it == t.handshakes.end() || !it->second.peerHold) return false;
    HoldRelease release(it->second.peerHold);
    it->second.peerHold = kNoHold;
    return false;
}

} // namespace

// ---------------------------------------------------------------------------
// Tables
// ---------------------------------------------------------------------------

WsTables& wsTables() {
    static auto* t = new WsTables();
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
    static bool done = false;   // eco thread only
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
    setWsEventDispatch(WsEvent::Kind::HandshakeGone, &onHandshakeGone);
}

int64_t wsTablesAddServerHandshake(std::shared_ptr<Conn> conn, HoldToken peerHold) {
    auto& t = wsTables();
    int64_t id = t.nextHsId++;
    WsHandshakeEntry e;
    e.conn = std::move(conn);
    e.server = true;
    e.peerHold = peerHold;
    t.handshakes.emplace(id, std::move(e));
    return id;
}

int64_t wsTablesAddServerH2Handshake(std::shared_ptr<H2PendingUpgrade> h2, HoldToken peerHold) {
    auto& t = wsTables();
    int64_t id = t.nextHsId++;
    WsHandshakeEntry e;
    e.server = true;
    e.h2 = std::move(h2);
    e.peerHold = peerHold;
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
    if (!e || e->closed || e->closeHold != kNoHold) return;
    e->closeHold = Scheduler::instance().acquireHold(HoldKind::Task, "WebSocket.closeHandshake");
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
    if (it == m.end()) return false;   // already dispatched, or the tables were reset
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
        return true;
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
