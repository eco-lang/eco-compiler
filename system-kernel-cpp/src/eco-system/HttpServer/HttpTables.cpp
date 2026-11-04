//===- HttpTables.cpp - Eco-thread tables and events of Http.Server -------===//
//
// The event queue and the tables are allocated once and never freed, so that a post from the reactor while the
// process exits never touches freed memory. The tables have no mutex: only the eco thread touches them.
//
// Any call into Elm, which `httpManagerDeliver` and `resumeUnit` make, can change the tables, so a pointer from
// `findServer` or `findKey` is looked up again after one. Erasing an entry, or a heap reset, which `tables` notices,
// also invalidates such a pointer.
//
//===----------------------------------------------------------------------===//

#include "eco-system/HttpServer/HttpTables.hpp"

#include "eco-system/Core/AsyncSources.hpp"
#include "eco-system/Core/Core.hpp"
#include "eco-system/Core/IoReactor.hpp"
#include "eco-system/HttpServer/Http1.hpp"
#include "eco-system/Socket/Listener.hpp"

#include <algorithm>
#include <atomic>
#include <cerrno>
#include <deque>
#include <exception>
#include <mutex>
#include <unordered_map>
#include <utility>
#include <vector>

namespace Eco::System::HttpSrv {

namespace {

/// Returns the shared reactor.
IoReactor& reactor() { return IoReactor::instance(); }

// --- Events --------------------------------------------------------------------

/// The queue of events from any thread to the drain, and the flag that asks the drain to deliver parked requests.
struct EventQueue {
    std::mutex m;                            ///< Guards `q`.
    std::deque<HttpEvent> q;
    std::atomic<size_t> count{0};            ///< The size of `q`, readable without `m` by the ready predicate.
    std::atomic<bool> parkedReady{false};   ///< Set on the eco thread, cleared by the drain.
    Scheduler* sched;                        ///< The process's one Scheduler, woken by every post.

    /// Creates an empty queue.
    EventQueue() : sched(&Scheduler::instance()) {}
};

/// Returns the event queue, creating it on the first call. `ensureHttpTables` makes that first call on the eco
/// thread before any server exists.
EventQueue& queue() {
    static auto* q = new EventQueue();   // never freed: see the file comment
    return *q;
}

/// Moves the oldest queued event into `out`, or returns false when the queue is empty. Any thread.
bool tryPop(HttpEvent& out) {
    auto& q = queue();
    std::lock_guard<std::mutex> lk(q.m);
    if (q.q.empty()) return false;
    out = std::move(q.q.front());
    q.q.pop_front();
    q.count.fetch_sub(1, std::memory_order_acq_rel);
    return true;
}

// --- Tables --------------------------------------------------------------------

/// One server, from `httpTablesStartServer` until its ServerClosed is drained or the heap is reset.
struct ServerEntry {
    std::shared_ptr<ListenerHandler> listener;
    /// After start, read and written only by closures run on the reactor.
    std::shared_ptr<ServerReactorState> rstate;
    std::shared_ptr<const ServerConfig> cfg;
    bool closed = false;                 ///< closeServer has run; its ServerClosed may still be to come.
    HoldToken subHold = kNoHold;         ///< The subscription hold, or `kNoHold` when none is held.
    std::vector<uint64_t> closeTokens;   ///< The resume tokens of the closeServer tasks waiting, each naming a hold.
    std::deque<int64_t> parked;          ///< The keys of the parked requests, oldest first.
    size_t parkedBytes = 0;              ///< The sum of the parked keys' `parkedSize`.
};

/// One request still owed an answer, from its Request event until its key is erased.
struct KeyEntry {
    int64_t serverId = 0;
    std::weak_ptr<Conn> conn;
    HoldToken hold = kNoHold;            ///< The delivery hold, or `kNoHold` before delivery.
    bool parked = false;
    size_t parkedSize = 0;               ///< The request's `requestSize` while parked, else 0.
    RequestData req;                     ///< The request while parked, and after delivery only for an upgrade.
};

/// The server and key tables of one heap generation.
struct Tables {
    std::unordered_map<int64_t, ServerEntry> servers;
    std::unordered_map<int64_t, KeyEntry> keys;
    uint64_t gen = 0;      ///< The heap generation the entries belong to.
    bool init = false;     ///< False until `tables` has first set `gen`.
};

/// Returns the allocator's current heap generation.
uint64_t currentGen() { return Allocator::instance().heapGeneration(); }

/// The installed manager hooks. Eco thread only.
HttpManagerHooks g_hooks;

/// Returns whether a subscription names `serverId`, false when no hook is installed.
bool httpManagerHasSubscriber(int64_t serverId) {
    return g_hooks.hasSubscriber != nullptr && g_hooks.hasSubscriber(serverId);
}

/// Delivers `req` to the subscribers of `serverId` through the hook, if one is installed. May run Elm code.
void httpManagerDeliver(int64_t serverId, int64_t key, const RequestData& req) {
    if (g_hooks.deliver != nullptr) g_hooks.deliver(serverId, key, req);
}

/// Empties `t`, which holds an earlier heap's entries: it releases every key's hold and server's subscription hold,
/// and asks the reactor to close each server's listener and abort its open connections. The holds of waiting
/// closeServer tasks, and of respond tasks whose RespondDone is still to come, are not released.
void resetTables(Tables& t) {
    for (auto& kv : t.keys) HoldRelease release(kv.second.hold);
    for (auto& kv : t.servers) {
        HoldRelease subHold(kv.second.subHold);
        auto l = kv.second.listener;
        auto rs = kv.second.rstate;
        reactor().submit([l, rs] {
            if (l) l->close();
            std::vector<std::shared_ptr<Conn>> live;
            for (auto& c : rs->conns) {
                if (auto p = c.second.lock()) live.push_back(std::move(p));
            }
            for (auto& c : live) c->abort(false);
        });
    }
    t.servers.clear();
    t.keys.clear();
}

/// Returns the tables, first emptying them with `resetTables` if the heap generation has changed since they were
/// last used.
Tables& tables() {
    static auto* t = new Tables();   // never freed: see the file comment
    uint64_t g = currentGen();
    if (!t->init || t->gen != g) {
        if (t->init) resetTables(*t);
        t->init = true;
        t->gen = g;
    }
    return *t;
}

/// Returns the entry of server `id`, or null if there is none.
ServerEntry* findServer(int64_t id) {
    auto& m = tables().servers;
    auto it = m.find(id);
    return it == m.end() ? nullptr : &it->second;
}

/// Returns the entry of `key`, or null if there is none.
KeyEntry* findKey(int64_t key) {
    auto& m = tables().keys;
    auto it = m.find(key);
    return it == m.end() ? nullptr : &it->second;
}

/// Returns a server id not returned before in this process, counting from 1. Eco thread only.
int64_t nextServerId() {
    static int64_t next = 1;
    return next++;
}

/// Erases `key`, if present, releasing its hold; a parked key also leaves its server's parked queue and budget.
void eraseKey(int64_t key) {
    auto& t = tables();
    auto it = t.keys.find(key);
    if (it == t.keys.end()) return;
    HoldRelease release(it->second.hold);
    if (it->second.parked) {
        if (ServerEntry* s = findServer(it->second.serverId)) {
            auto& p = s->parked;
            p.erase(std::remove(p.begin(), p.end(), key), p.end());
            s->parkedBytes -= std::min(s->parkedBytes, it->second.parkedSize);
        }
    }
    t.keys.erase(it);
}

/// Asks the reactor to answer `key` on `conn` with `r`, asking for the connection to be closed
/// afterwards when `forceClose` is set, which an HTTP/2 connection ignores.
/// Unless `token` is 0, a RespondDone carrying it is posted once the response is sent, fails, or cannot be given to
/// the connection, such as when the connection is gone.
void submitResponse(std::weak_ptr<Conn> conn, int64_t key, ResponseData r, bool forceClose,
                    uint64_t token) {
    uint64_t gen = currentGen();
    reactor().submit([conn, key, r = std::move(r), forceClose, token, gen]() mutable {
        std::function<void(int)> done;
        if (token != 0) {
            done = [token, gen](int) {
                HttpEvent ev;
                ev.kind = HttpEvent::Kind::RespondDone;
                ev.gen = gen;
                ev.token = token;
                postHttpEvent(std::move(ev));
            };
        }
        std::shared_ptr<Conn> c = conn.lock();
        if (!http1Respond(c, key, std::move(r), forceClose, done) && done) done(ECANCELED);
    });
}

/// Erases `key` and answers it with an empty 503, asking for the connection to be closed afterwards. Does nothing
/// for an unknown key.
void respond503(int64_t key) {
    KeyEntry* k = findKey(key);
    if (!k) return;
    std::weak_ptr<Conn> conn = k->conn;
    eraseKey(key);
    ResponseData r;
    r.status = 503;
    submitResponse(std::move(conn), key, std::move(r), /*forceClose=*/true, 0);
}

/// Returns the bytes `r` is counted as against the parking bound: its method, URL, body and header names and
/// values, plus 4 per header and 64 in all.
size_t requestSize(const RequestData& r) {
    size_t n = r.method.size() + r.url.size() + r.body.size() + 64;
    for (const auto& h : r.headers) n += h.first.size() + h.second.size() + 4;
    return n;
}

// --- Event handlers (eco thread) -------------------------------------------------

/// Handles a Request event: adds its key, then answers it 503 when its server is missing or closed and has no
/// subscriber, delivers it when the server has a subscriber and nothing parked, and otherwise parks it, behind the
/// earlier parked requests and within the bound. May run Elm code. `ev.req` may be moved from.
void onRequest(HttpEvent& ev) {
    auto& sched = Scheduler::instance();
    int64_t id = ev.serverId;
    int64_t key = ev.key;
    {
        KeyEntry k;
        k.serverId = id;
        k.conn = ev.conn;
        if (!ev.req.upgrade.empty()) k.req = ev.req;   // kept for httpTablesTakeUpgrade
        tables().keys[key] = std::move(k);
    }
    bool subscribed = httpManagerHasSubscriber(id);
    ServerEntry* s = findServer(id);
    if (!subscribed && (s == nullptr || s->closed)) {
        respond503(key);   // nobody listens and, the server being closed, nobody will
        return;
    }
    if (subscribed && (s == nullptr || s->parked.empty())) {
        findKey(key)->hold = sched.acquireHold(HoldKind::Item, "Http.Server.request");
        httpManagerDeliver(id, key, ev.req);   // may run Elm: nothing is used past here
        return;
    }
    // Parking: s is not null here, since both branches above cover a missing server.
    size_t size = requestSize(ev.req);
    size_t budget = static_cast<size_t>(std::max<int64_t>(s->cfg->maxBodySize, 0)) * 4;
    if (s->parkedBytes + size > budget && !s->parked.empty()) {
        respond503(key);
        return;
    }
    KeyEntry* k = findKey(key);
    k->parked = true;
    k->parkedSize = size;
    k->req = std::move(ev.req);
    s->parked.push_back(key);
    s->parkedBytes += size;
    if (subscribed) queue().parkedReady.store(true, std::memory_order_release);
}

/// Delivers the parked requests of every server that has a subscriber, in order of server id and, within a server,
/// oldest first, stopping for a server once it has no subscriber. Runs Elm code.
void deliverParked() {
    std::vector<int64_t> ids;
    for (auto& kv : tables().servers) {
        if (!kv.second.parked.empty() && httpManagerHasSubscriber(kv.first)) ids.push_back(kv.first);
    }
    std::sort(ids.begin(), ids.end());
    for (int64_t id : ids) {
        for (;;) {
            ServerEntry* s = findServer(id);   // again after every Elm call
            if (!s || s->parked.empty() || !httpManagerHasSubscriber(id)) break;
            int64_t key = s->parked.front();
            s->parked.pop_front();
            KeyEntry* k = findKey(key);
            if (!k) continue;
            s->parkedBytes -= std::min(s->parkedBytes, k->parkedSize);
            k->parked = false;
            k->parkedSize = 0;
            k->hold = Scheduler::instance().acquireHold(HoldKind::Item, "Http.Server.request");
            RequestData req = k->req;
            if (req.upgrade.empty()) k->req = RequestData{};
            httpManagerDeliver(id, key, req);
        }
    }
}

/// Resumes the task parked under `token` with Unit, and returns false when it was killed and nothing is resumed.
/// Runs Elm code.
bool resumeUnit(uint64_t token) {
    HPointer resume = Scheduler::instance().takePendingResume(token);
    if (alloc::isNil(resume)) return false;   // the task was killed
    HPointer task = alloc::listNil();
    Elm::StackRootGuard g(&resume, &task);
    task = succeedUnit();
    Scheduler::callClosure1(resume, task);
    return true;
}

/// Handles a ServerClosed event for server `id`: erases the server, releases its subscription hold, answers any
/// request still parked 503, and releases the hold of every waiting closeServer task, resuming those not killed.
void onServerClosed(int64_t id) {
    ServerEntry* s = findServer(id);
    if (!s) return;
    ServerEntry e = std::move(*s);
    tables().servers.erase(id);
    HoldRelease subHold(e.subHold);
    for (int64_t key : e.parked) respond503(key);
    for (uint64_t token : e.closeTokens) {
        HoldRelease opHold(token);
        if (resumeUnit(token)) Scheduler::instance().drain();
    }
}

/// Runs one drain pass: delivers parked requests when asked to, then handles every queued event of the current
/// heap generation, delivering parked requests again after each. Eco thread only. An exception is reported as fatal
/// rather than passed to the scheduler loop.
void httpDrain() {
    try {
        auto& q = queue();
        if (q.parkedReady.exchange(false, std::memory_order_acq_rel)) deliverParked();
        HttpEvent ev;
        while (tryPop(ev)) {
            if (ev.gen != currentGen()) continue;
            switch (ev.kind) {
            case HttpEvent::Kind::Request:
                onRequest(ev);
                break;
            case HttpEvent::Kind::RespondDone: {
                HoldRelease release(ev.token);
                if (resumeUnit(ev.token)) Scheduler::instance().drain();
                break;
            }
            case HttpEvent::Kind::ConnGone:
                eraseKey(ev.key);
                break;
            case HttpEvent::Kind::ServerClosed:
                onServerClosed(ev.serverId);
                break;
            }
            if (q.parkedReady.exchange(false, std::memory_order_acq_rel)) deliverParked();
        }
    } catch (const std::exception& e) {
        ::Eco::Kernel::reportFatal(e.what());
    } catch (...) {
        ::Eco::Kernel::reportFatal("unknown native exception in the Http.Server drain");
    }
}

/// Returns whether the drain has work: a queued event, or parked requests to deliver.
bool httpReady() {
    auto& q = queue();
    return q.count.load(std::memory_order_acquire) > 0 ||
           q.parkedReady.load(std::memory_order_acquire);
}

} // namespace

// ---------------------------------------------------------------------------
// API
// ---------------------------------------------------------------------------

void postHttpEvent(HttpEvent ev) {
    auto& q = queue();
    {
        std::lock_guard<std::mutex> lk(q.m);
        q.q.push_back(std::move(ev));
        q.count.fetch_add(1, std::memory_order_acq_rel);
    }
    // Outside q.m, so that no lock is taken while it is held.
    q.sched->notifyWorkAvailableFromAsync();
}

void ensureHttpTables() {
    (void)queue();
    static bool done = false;   // eco thread only
    if (done) return;
    done = true;
    ensureSocketEvents();
    addDrainSource(&httpDrain, &httpReady);
}

int64_t httpTablesStartServer(int fd, std::shared_ptr<ServerConfig> cfg, int64_t maxConnections,
                              TransportFactory transport) {
    ensureHttpTables();
    auto& t = tables();
    int64_t id = nextServerId();
    cfg->serverId = id;
    cfg->gen = t.gen;
    auto rstate = std::make_shared<ServerReactorState>();
    rstate->cfg = cfg;
    auto h = std::make_shared<ListenerHandler>(fd, id, t.gen, /*isUnix=*/false, std::string(),
                                               /*ownsPath=*/false, std::move(transport));
    h->setCallbackMode([rstate](Conn& c) { return makeServerProtocol(c, rstate); },
                       maxConnections < 0 ? -1 : maxConnections);
    ServerEntry e;
    e.listener = h;
    e.rstate = rstate;
    e.cfg = cfg;
    t.servers.emplace(id, std::move(e));
    reactor().submit([h] { h->start(); });
    return id;
}

bool httpTablesRespond(int64_t key, uint64_t token, ResponseData resp) {
    KeyEntry* k = findKey(key);
    if (!k) return false;
    std::weak_ptr<Conn> conn = k->conn;
    eraseKey(key);
    submitResponse(std::move(conn), key, std::move(resp), /*forceClose=*/false, token);
    return true;
}

bool httpTablesCloseServer(int64_t serverId, int64_t deadlineMs, uint64_t token) {
    ServerEntry* s = findServer(serverId);
    if (!s) return false;
    s->closeTokens.push_back(token);
    if (s->closed) return true;
    s->closed = true;
    if (s->subHold) {
        Scheduler::instance().releaseHold(s->subHold);
        s->subHold = kNoHold;
    }
    std::deque<int64_t> parked;
    parked.swap(s->parked);
    s->parkedBytes = 0;
    for (int64_t key : parked) {
        // Already out of s->parked, so eraseKey must not look for it there.
        if (KeyEntry* k = findKey(key)) k->parked = false;
        respond503(key);
    }
    s = findServer(serverId);
    auto listener = s->listener;
    auto rstate = s->rstate;
    uint64_t gen = s->cfg->gen;
    int64_t ms = deadlineMs < 0 ? 0 : deadlineMs;
    reactor().submit([listener, rstate, ms, serverId, gen] {
        listener->close();
        http1ServerClosing(rstate, reactor().nowMs() + ms);
        HttpEvent ev;
        ev.kind = HttpEvent::Kind::ServerClosed;
        ev.gen = gen;
        ev.serverId = serverId;
        postHttpEvent(std::move(ev));
    });
    return true;
}

bool httpTablesTakeUpgrade(int64_t key, RequestData& out, std::weak_ptr<Conn>& conn, HoldToken& hold) {
    KeyEntry* k = findKey(key);
    if (!k || k->parked || k->req.upgrade.empty()) return false;
    out = std::move(k->req);
    conn = k->conn;
    // The hold moves to the caller, so eraseKey must not release it.
    hold = k->hold;
    k->hold = kNoHold;
    eraseKey(key);
    return true;
}

bool httpTablesPopEventForTest(HttpEvent& out) { return tryPop(out); }

void setHttpManagerHooks(HttpManagerHooks hooks) { g_hooks = hooks; }

namespace {

/// Acquires the subscription hold of every open server a subscription names that has none, and releases it for
/// every server that is closed or named by none.
void httpTablesSyncSubscriptionHolds() {
    auto& sched = Scheduler::instance();
    for (auto& kv : tables().servers) {
        ServerEntry& e = kv.second;
        bool want = !e.closed && httpManagerHasSubscriber(kv.first);
        if (want && !e.subHold) e.subHold = sched.acquireHold(HoldKind::Subscription, "Http.Server.onRequest");
        if (!want && e.subHold) {
            sched.releaseHold(e.subHold);
            e.subHold = kNoHold;
        }
    }
}

} // namespace

void httpTablesSubscriptionsChanged() {
    ensureHttpTables();
    httpTablesSyncSubscriptionHolds();
    for (auto& kv : tables().servers) {
        if (!kv.second.parked.empty() && httpManagerHasSubscriber(kv.first)) {
            queue().parkedReady.store(true, std::memory_order_release);
            return;
        }
    }
}

} // namespace Eco::System::HttpSrv
