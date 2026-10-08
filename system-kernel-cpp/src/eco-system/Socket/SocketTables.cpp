//===- SocketTables.cpp - Main-thread socket tables and delivery ----------===//
//
// See SocketTables.hpp (plans/eco-system-sockets.md §3.3.4, §3.3.8, §3.3.9,
// §3.4). Main thread only.
//
// Counts (§3.3.8, G10), released here:
//   * Connected: the connect's count (AsyncRelease), resumed or orphaned
//     (an orphaned success is aborted: "an orphaned success is closed").
//   * OpDone: the R-mode operation's count.
//   * ListenerClosed: the listener's own count (once) and one count per
//     closeListener task.
//   * Accepted: none (parked accepts hold no count; the listener does).
//
// Templates used: T5 (generation-keyed tables), T8 (via the manager), T9
// (completions), G10 (AsyncRelease), G12 (drain per delivery).
//
//===----------------------------------------------------------------------===//

#include "eco-system/Socket/SocketTables.hpp"

#include "eco-system/Core/AsyncRelease.hpp"
#include "eco-system/Socket/ConnChannel.hpp"
#include "eco-system/Stream/Stream.hpp"
#include "eco-system/Stream/StreamTable.hpp"

#include <algorithm>
#include <utility>

namespace Eco::System {

namespace {

IoReactor& reactor() { return IoReactor::instance(); }

void abortConn(const std::shared_ptr<Conn>& c) {
    if (!c) return;
    std::shared_ptr<Conn> cc = c;
    reactor().submit([cc] { cc->abort(false); });
}

// A dead heap's entries: close their reactor objects (their counts and
// tokens died with the heap).
void resetTables(SocketTables& t) {
    for (auto& kv : t.listeners) {
        ListenerEntry& e = kv.second;
        for (auto& ev : e.held) abortConn(ev.conn);
        if (e.handler) {
            auto h = e.handler;
            reactor().submit([h] { h->close(); });   // its ListenerClosed is a dead heap's: dropped
        }
    }
    for (auto& kv : t.conns) abortConn(kv.second.conn);
    for (auto& kv : t.pendingConnects) (void)kv.second->cancelConnect();
    t.listeners.clear();
    t.conns.clear();
    t.pendingConnects.clear();
}

// Resumes `token` with `task` (rooted by the caller). False if the task is
// gone (killed).
bool resumeToken(uint64_t token, HPointer& task) {
    HPointer resume = Scheduler::instance().takePendingResume(token);
    if (alloc::isNil(resume)) return false;
    Elm::StackRootGuard g(&resume);
    Scheduler::callClosure1(resume, task);
    return true;
}

bool resumeOk(uint64_t token) {
    HPointer task = alloc::listNil();
    Elm::StackRootGuard g(&task);
    HPointer resume = Scheduler::instance().takePendingResume(token);
    if (alloc::isNil(resume)) return false;
    Elm::StackRootGuard g2(&resume);
    task = succeedUnit();
    Scheduler::callClosure1(resume, task);
    return true;
}

bool resumeFail(uint64_t token, const std::string& code, const std::string& message) {
    HPointer task = alloc::listNil();
    Elm::StackRootGuard g(&task);
    HPointer resume = Scheduler::instance().takePendingResume(token);
    if (alloc::isNil(resume)) return false;
    Elm::StackRootGuard g2(&resume);
    task = failFErr(code, message);
    Scheduler::callClosure1(resume, task);
    return true;
}

// Serves the held FIFO of listener `id` while it has a consumer (§3.4):
// oldest parked accept first, else the subscribers. Each delivery resumes
// or sends, then drains (G12).
void serveHeld(int64_t id) {
    auto& sched = Scheduler::instance();
    for (;;) {
        ListenerEntry* e = findListener(id);
        if (!e || e->closing || e->held.empty()) return;
        if (!e->parkedAccepts.empty()) {
            uint64_t token = e->parkedAccepts.front();
            e->parkedAccepts.pop_front();
            HPointer resume = sched.takePendingResume(token);
            if (alloc::isNil(resume)) continue;   // killed (its cancel already ran)
            SocketEvent ev = std::move(e->held.front());
            e->held.pop_front();
            HPointer task = alloc::listNil();
            Elm::StackRootGuard g(&resume, &task);
            int64_t connId = materializeConnection(ev);   // no allocation
            task = buildConnT(connId, ev);
            task = succeed(task);
            Scheduler::callClosure1(resume, task);
            sched.drain();
            continue;
        }
        if (!socketManagerHasSubscribers(id)) return;
        SocketEvent ev = std::move(e->held.front());
        e->held.pop_front();
        HPointer connT = alloc::listNil();
        Elm::StackRootGuard g(&connT);
        int64_t connId = materializeConnection(ev);
        connT = buildConnT(connId, ev);
        socketManagerDeliver(id, connT);   // sendToApp + drain per tagger
    }
}

// Deferred work (requestSocketWork): serve every listener's held FIFO.
void serveAllHeld() {
    std::vector<int64_t> ids;
    for (auto& kv : socketTables().listeners) {
        if (!kv.second.held.empty()) ids.push_back(kv.first);
    }
    std::sort(ids.begin(), ids.end());   // listener ids are POD (G15 is about HPointers)
    for (int64_t id : ids) serveHeld(id);
}

// --- Event dispatchers (SocketEvents.cpp drain) ------------------------------

bool onConnected(SocketEvent& ev) {
    AsyncRelease release;   // the connect's count (§3.3.8)
    socketTables().pendingConnects.erase(ev.token);
    HPointer resume = Scheduler::instance().takePendingResume(ev.token);
    if (alloc::isNil(resume)) {
        if (!ev.failed) abortConn(ev.conn);   // an orphaned success is closed
        return false;
    }
    HPointer task = alloc::listNil();
    Elm::StackRootGuard g(&resume, &task);
    if (ev.failed) {
        task = failFErr(ev.code, ev.message);
    } else {
        int64_t connId = materializeConnection(ev);
        task = buildConnT(connId, ev);
        task = succeed(task);
    }
    Scheduler::callClosure1(resume, task);
    return true;
}

bool onAccepted(SocketEvent& ev) {
    ListenerEntry* e = findListener(ev.ownerId);
    if (!e || e->closing) {
        abortConn(ev.conn);
        return false;
    }
    int64_t id = ev.ownerId;
    e->held.push_back(std::move(ev));   // in order behind anything held earlier
    serveHeld(id);                      // drains per delivery itself
    return false;
}

bool onOpDone(SocketEvent& ev) {
    AsyncRelease release;   // the operation's count
    if (ev.failed) return resumeFail(ev.token, ev.code, ev.message);
    return resumeOk(ev.token);
}

bool onListenerClosed(SocketEvent& ev) {
    ListenerEntry* e = findListener(ev.ownerId);
    if (!e) return false;
    ListenerEntry entry = std::move(*e);
    socketTables().listeners.erase(ev.ownerId);
    AsyncRelease listenerCount(entry.counted);   // the open listener's count, once
    for (auto& h : entry.held) abortConn(h.conn);
    bool resumed = false;
    for (uint64_t token : entry.parkedAccepts) {   // closeAll path: nobody failed them yet
        resumed |= resumeFail(token, "ECANCELED", "accept ECANCELED");
    }
    for (uint64_t token : entry.closeTokens) {
        AsyncRelease opCount;
        resumed |= resumeOk(token);
    }
    return resumed;
}

} // namespace

// ---------------------------------------------------------------------------
// Tables
// ---------------------------------------------------------------------------

SocketTables& socketTables() {
    static auto* t = new SocketTables();   // leaky (§3.4)
    uint64_t g = currentHeapGeneration();
    if (!t->init || t->gen != g) {
        if (t->init) resetTables(*t);
        t->init = true;
        t->gen = g;
    }
    return *t;
}

ListenerEntry* findListener(int64_t id) {
    auto& m = socketTables().listeners;
    auto it = m.find(id);
    return it == m.end() ? nullptr : &it->second;
}

ConnEntry* findConn(int64_t id) {
    auto& m = socketTables().conns;
    auto it = m.find(id);
    return it == m.end() ? nullptr : &it->second;
}

void ensureSocketTables() {
    ensureSocketEvents();
    static bool done = false;   // main thread only
    if (done) return;
    done = true;
    setSocketEventDispatch(SocketEvent::Kind::Connected, &onConnected);
    setSocketEventDispatch(SocketEvent::Kind::Accepted, &onAccepted);
    setSocketEventDispatch(SocketEvent::Kind::OpDone, &onOpDone);
    setSocketEventDispatch(SocketEvent::Kind::ListenerClosed, &onListenerClosed);
}

int64_t materializeConnection(SocketEvent& ev) {
    (void)streamTable();   // the channel dispatch exists before the channels
    auto& t = socketTables();
    int64_t connId = t.nextConnId++;
    ConnEntry ce;
    ce.conn = ev.conn;
    ce.cred = ev.cred;
    ce.hasCred = ev.hasCred;
    ce.tls = ev.tls;
    ce.isTls = ev.hasTls;
    ce.isUnix = ev.isUnix;
    ce.facesAlive = 2;
    t.conns.emplace(connId, std::move(ce));
    int64_t rid = createChannelSource(new ConnReadFace(ev.conn, connId));
    int64_t wid = createChannelSink(new ConnWriteFace(ev.conn, connId));
    if (ConnEntry* e = findConn(connId)) {
        e->readableId = rid;
        e->writableId = wid;
    }
    return connId;
}

HPointer buildEndpoint(const SockEndpoint& ep) {
    HPointer text = alloc::allocStringFromUTF8(ep.text);
    // Fresh result passed directly into the helper (it roots its arguments, G4).
    return alloc::tuple3(alloc::unboxedInt(ep.kind), alloc::boxed(text), alloc::unboxedInt(ep.port),
                         0x11);
}

// ( connId, ( readableId, writableId ), ( localEpT, remoteEpT ) ), masks 0x1 / 0x5 / 0.
HPointer buildConnT(int64_t connId, const SocketEvent& ev) {
    int64_t rid = 0, wid = 0;
    if (ConnEntry* e = findConn(connId)) {
        rid = e->readableId;
        wid = e->writableId;
    }
    HPointer ids = alloc::listNil();
    HPointer local = alloc::listNil();
    HPointer remote = alloc::listNil();
    HPointer eps = alloc::listNil();
    Elm::StackRootGuard g({&ids, &local, &remote, &eps});
    ids = alloc::tuple2(alloc::unboxedInt(rid), alloc::unboxedInt(wid), 0x5);
    local = buildEndpoint(ev.local);
    remote = buildEndpoint(ev.remote);
    eps = alloc::tuple2(alloc::boxed(local), alloc::boxed(remote), 0);
    return alloc::tuple3(alloc::unboxedInt(connId), alloc::boxed(ids), alloc::boxed(eps), 0x1);
}

// ( listenerId, EpT ), mask 0x1.
HPointer buildListenT(int64_t listenerId, const SockEndpoint& bound) {
    HPointer ep = alloc::listNil();
    Elm::StackRootGuard g(&ep);
    ep = buildEndpoint(bound);
    return alloc::tuple2(alloc::unboxedInt(listenerId), alloc::boxed(ep), 0x1);
}

void socketTablesFaceGone(int64_t connId) {
    ConnEntry* e = findConn(connId);
    if (!e) return;
    if (--e->facesAlive <= 0) socketTables().conns.erase(connId);
}

void socketTablesSyncSubscriptions() {
    bool heldWaiting = false;
    for (auto& kv : socketTables().listeners) {
        ListenerEntry& e = kv.second;
        if (e.closing || !e.handler) continue;
        bool on = socketManagerHasSubscribers(kv.first);
        if (on != e.subscribed) {
            e.subscribed = on;
            auto h = e.handler;
            reactor().submit([h, on] { h->setUnlimited(on); });
        }
        if (on && !e.held.empty()) heldWaiting = true;
    }
    if (heldWaiting) requestSocketWork(&serveAllHeld);
}

bool cancelPendingConnect(uint64_t token) {
    auto& m = socketTables().pendingConnects;
    auto it = m.find(token);
    if (it == m.end()) return false;   // its Connected event is queued: the drain decrements
    std::shared_ptr<Conn> c = it->second;
    m.erase(it);
    return c->cancelConnect();
}

bool cancelParkedAccept(uint64_t token) {
    for (auto& kv : socketTables().listeners) {
        auto& q = kv.second.parkedAccepts;
        auto it = std::find(q.begin(), q.end(), token);
        if (it == q.end()) continue;
        q.erase(it);
        if (kv.second.handler && !kv.second.closing) {
            auto h = kv.second.handler;
            reactor().submit([h] { h->addCredit(-1); });   // return the credit
        }
        break;
    }
    return false;   // A mode: no count of its own (§3.3.8)
}

} // namespace Eco::System
