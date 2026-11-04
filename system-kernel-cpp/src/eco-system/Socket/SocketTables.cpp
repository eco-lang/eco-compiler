//===- SocketTables.cpp - Eco-thread socket tables and delivery -----------===//
//
// Which hold each event dispatcher releases:
//   * Connected: the connect's, whether the task is resumed or has been killed. A successful connect whose task is
//     gone is aborted.
//   * OpDone: the operation's.
//   * ListenerClosed: the subscription hold, if taken, the hold of every parked accept it fails, and that of every
//     close token it completes.
//   * Accepted: none directly. Serving the held FIFO releases the hold of each parked accept a connection is handed
//     to; a connection handed to the subscribers, or left held, involves no hold.
// Each `HoldRelease` lives to the end of its scope, so a hold is released after its task has been resumed.
//
//===----------------------------------------------------------------------===//

#include "eco-system/Socket/SocketTables.hpp"

#include "eco-system/Socket/ConnChannel.hpp"
#include "eco-system/Socket/SocketManager.hpp"
#include "eco-system/Stream/Stream.hpp"
#include "eco-system/Stream/StreamTable.hpp"

#include <algorithm>
#include <utility>

namespace Eco::System {

namespace {

// Returns the process-wide reactor that runs the socket objects.
IoReactor& reactor() { return IoReactor::instance(); }

// Asks the reactor to abort connection `c` without a TCP reset. Does nothing for null.
void abortConn(const std::shared_ptr<Conn>& c) {
    if (!c) return;
    std::shared_ptr<Conn> cc = c;
    reactor().submit([cc] { cc->abort(false); });
}

// Empties `t`, which belongs to a heap that no longer exists: aborts every held, materialized and pending
// connection and closes every listener. The scheduler voided every hold of the old heap at the reset (D21 of
// plans/kernel-lib-bug-fixes.md), so the releases below do nothing; they are kept so that each hold the tables
// own still has one release.
void resetTables(SocketTables& t) {
    auto& sched = Scheduler::instance();
    for (auto& kv : t.listeners) {
        ListenerEntry& e = kv.second;
        HoldRelease subHold(e.subHold);
        for (uint64_t token : e.parkedAccepts) {
            (void)sched.takePendingResume(token);
            sched.releaseHold(token);
        }
        for (auto& ev : e.held) abortConn(ev.conn);
        if (e.handler) {
            auto h = e.handler;
            reactor().submit([h] { h->close(); });   // its ListenerClosed is not dispatched
        }
    }
    for (auto& kv : t.conns) abortConn(kv.second.conn);
    for (auto& kv : t.pendingConnects) (void)kv.second->cancelConnect();
    t.listeners.clear();
    t.conns.clear();
    t.pendingConnects.clear();
}

// Resumes the task parked under `token` with success and unit. Returns false if the task is gone. Releases no hold.
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

// Resumes the task parked under `token` with failure `( code, message )`. Returns false if the task is gone.
// Releases no hold.
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

// Delivers the held connections of listener `id`, oldest first, while it has a consumer: the oldest parked accept,
// whose hold is released, or else the subscribers. Stops at an unknown or closing listener. Drains the Scheduler
// after each delivery. A parked accept whose task is gone is dropped from the queue.
void serveHeld(int64_t id) {
    auto& sched = Scheduler::instance();
    for (;;) {
        ListenerEntry* e = findListener(id);
        if (!e || e->closing || e->held.empty()) return;
        if (!e->parkedAccepts.empty()) {
            uint64_t token = e->parkedAccepts.front();
            e->parkedAccepts.pop_front();
            HPointer resume = sched.takePendingResume(token);
            if (alloc::isNil(resume)) continue;   // the task is gone; its hold is not released here
            HoldRelease release(token);
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
        socketManagerDeliver(id, connT);
    }
}

// Serves the held FIFO of every listener that has one, in listener id order. Requested as socket work by
// `socketTablesSyncSubscriptions`.
void serveAllHeld() {
    std::vector<int64_t> ids;
    for (auto& kv : socketTables().listeners) {
        if (!kv.second.held.empty()) ids.push_back(kv.first);
    }
    std::sort(ids.begin(), ids.end());
    for (int64_t id : ids) serveHeld(id);
}

// --- Event dispatchers -------------------------------------------------------

// Completes a connect: resumes its task with the connection, materialized, or with the failure. Returns whether a
// task was resumed.
bool onConnected(SocketEvent& ev) {
    HoldRelease release(ev.token);
    socketTables().pendingConnects.erase(ev.token);
    HPointer resume = Scheduler::instance().takePendingResume(ev.token);
    if (alloc::isNil(resume)) {
        if (!ev.failed) abortConn(ev.conn);
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

// Appends the accepted connection to its listener's held FIFO and serves the FIFO, or aborts the connection if
// the listener is unknown or closing. Returns false: serving drains after each delivery itself.
bool onAccepted(SocketEvent& ev) {
    ListenerEntry* e = findListener(ev.ownerId);
    if (!e || e->closing) {
        abortConn(ev.conn);
        return false;
    }
    int64_t id = ev.ownerId;
    e->held.push_back(std::move(ev));
    serveHeld(id);
    return false;
}

// Completes an operation's task with success or its failure. Returns whether the task was resumed.
bool onOpDone(SocketEvent& ev) {
    HoldRelease release(ev.token);
    if (ev.failed) return resumeFail(ev.token, ev.code, ev.message);
    return resumeOk(ev.token);
}

// Erases the closed listener, aborts its held connections, fails its parked accepts with ECANCELED and completes
// its close tokens. Returns whether any task was resumed.
bool onListenerClosed(SocketEvent& ev) {
    ListenerEntry* e = findListener(ev.ownerId);
    if (!e) return false;
    // Moved out before any task resumes, since Elm code can change the table.
    ListenerEntry entry = std::move(*e);
    socketTables().listeners.erase(ev.ownerId);
    HoldRelease subHold(entry.subHold);
    for (auto& h : entry.held) abortConn(h.conn);
    bool resumed = false;
    // Parked accepts remain only when the listener closed without `closeListener`, which fails them itself.
    for (uint64_t token : entry.parkedAccepts) {
        HoldRelease acceptHold(token);
        resumed |= resumeFail(token, "ECANCELED", "accept ECANCELED");
    }
    for (uint64_t token : entry.closeTokens) {
        HoldRelease opHold(token);
        resumed |= resumeOk(token);
    }
    return resumed;
}

} // namespace

// ---------------------------------------------------------------------------
// Tables
// ---------------------------------------------------------------------------

SocketTables& socketTables() {
    static auto* t = new SocketTables();   // never freed
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
    static bool done = false;
    if (done) return;
    done = true;
    setSocketEventDispatch(SocketEvent::Kind::Connected, &onConnected);
    setSocketEventDispatch(SocketEvent::Kind::Accepted, &onAccepted);
    setSocketEventDispatch(SocketEvent::Kind::OpDone, &onOpDone);
    setSocketEventDispatch(SocketEvent::Kind::ListenerClosed, &onListenerClosed);
}

int64_t materializeConnection(SocketEvent& ev) {
    (void)streamTable();   // installs the channel result dispatch before the channels exist
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
    // `text` is passed straight to `tuple3`, which roots its boxed fields across its own allocation.
    return alloc::tuple3(alloc::unboxedInt(ep.kind), alloc::boxed(text), alloc::unboxedInt(ep.port),
                         SocketManager::EP_T_MASK);
}

// The masks are the ConnT layout constants of SocketManager.hpp, which the Socket effect manager's taggers share.
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
    ids = alloc::tuple2(alloc::unboxedInt(rid), alloc::unboxedInt(wid), SocketManager::CONN_IDS_MASK);
    local = buildEndpoint(ev.local);
    remote = buildEndpoint(ev.remote);
    eps = alloc::tuple2(alloc::boxed(local), alloc::boxed(remote), SocketManager::CONN_ENDPOINTS_MASK);
    return alloc::tuple3(alloc::unboxedInt(connId), alloc::boxed(ids), alloc::boxed(eps), SocketManager::CONN_T_MASK);
}

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
    auto& sched = Scheduler::instance();
    bool heldWaiting = false;
    for (auto& kv : socketTables().listeners) {
        ListenerEntry& e = kv.second;
        // A closing listener's close tokens hold until ListenerClosed, so it needs no subscription hold.
        bool wantHold = !e.closing && e.handler && socketManagerHasSubscribers(kv.first);
        if (wantHold && !e.subHold) e.subHold = sched.acquireHold(HoldKind::Subscription, "Socket.onConnection");
        if (!wantHold && e.subHold) {
            sched.releaseHold(e.subHold);
            e.subHold = kNoHold;
        }
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
    if (it == m.end()) return false;   // already handled by onConnected, which released the hold
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
            reactor().submit([h] { h->addCredit(-1); });
        }
        return true;
    }
    return false;
}

} // namespace Eco::System
