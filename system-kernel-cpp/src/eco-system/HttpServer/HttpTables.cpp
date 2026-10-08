//===- HttpTables.cpp - Main-thread tables and events of Http.Server ------===//
//
// See HttpTables.hpp (plans/eco-system-websockets.md §3.4, phase WS2). The
// queue is a leaky singleton (base plan §3.4): a late post from the reactor
// during std::exit never touches freed memory. The tables are main-thread
// only (no mutex) and reset on a new heap generation (F24): their reactor
// objects are closed first (listeners closed, connections aborted); their
// tokens and counts died with the heap.
//
// Templates used: T5 (generation-keyed tables), T8/G12 (via the manager),
// G10 (AsyncRelease: every count is released exactly once).
//
//===----------------------------------------------------------------------===//

#include "eco-system/HttpServer/HttpTables.hpp"

#include "eco-system/Core/AsyncRelease.hpp"
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

IoReactor& reactor() { return IoReactor::instance(); }

// --- Events --------------------------------------------------------------------

struct EventQueue {
    std::mutex m;
    std::deque<HttpEvent> q;
    std::atomic<size_t> count{0};
    std::atomic<bool> parkedReady{false};   // main thread sets, drain clears
    Scheduler* sched;

    EventQueue() : sched(&Scheduler::instance()) {}
};

// Constructed by ensureHttpTables() on the main thread before any reactor
// object of a server exists, so the reactor thread never binds the Scheduler.
EventQueue& queue() {
    static auto* q = new EventQueue();   // leaky (§3.4)
    return *q;
}

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

struct ServerEntry {
    std::shared_ptr<ListenerHandler> listener;
    std::shared_ptr<ServerReactorState> rstate;   // handed to reactor commands only
    std::shared_ptr<const ServerConfig> cfg;
    bool closed = false;                 // closeServer ran (its reactor part may be pending)
    bool counted = true;                 // holds the server's keep-alive count
    std::vector<uint64_t> closeTokens;   // closeServer tasks (one count each)
    std::deque<int64_t> parked;          // keys of requests nobody was subscribed for
    size_t parkedBytes = 0;
};

struct KeyEntry {
    int64_t serverId = 0;
    std::weak_ptr<Conn> conn;
    bool counted = false;                // holds one keep-alive count (§3.4)
    bool parked = false;
    size_t parkedSize = 0;
    RequestData req;                     // while parked; kept for upgrade requests (WS5)
};

struct Tables {
    std::unordered_map<int64_t, ServerEntry> servers;
    std::unordered_map<int64_t, KeyEntry> keys;
    uint64_t gen = 0;
    bool init = false;
};

uint64_t currentGen() { return Allocator::instance().heapGeneration(); }

HttpManagerHooks g_hooks;   // main thread only

bool httpManagerHasSubscriber(int64_t serverId) {
    return g_hooks.hasSubscriber != nullptr && g_hooks.hasSubscriber(serverId);
}

void httpManagerDeliver(int64_t serverId, int64_t key, const RequestData& req) {
    if (g_hooks.deliver != nullptr) g_hooks.deliver(serverId, key, req);
}

// A dead heap's servers: close their reactor objects (counts and tokens
// died with the heap).
void resetTables(Tables& t) {
    for (auto& kv : t.servers) {
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

Tables& tables() {
    static auto* t = new Tables();   // leaky (§3.4)
    uint64_t g = currentGen();
    if (!t->init || t->gen != g) {
        if (t->init) resetTables(*t);
        t->init = true;
        t->gen = g;
    }
    return *t;
}

ServerEntry* findServer(int64_t id) {
    auto& m = tables().servers;
    auto it = m.find(id);
    return it == m.end() ? nullptr : &it->second;
}

KeyEntry* findKey(int64_t key) {
    auto& m = tables().keys;
    auto it = m.find(key);
    return it == m.end() ? nullptr : &it->second;
}

int64_t nextServerId() {
    static int64_t next = 1;   // main thread only; never reused across heap generations
    return next++;
}

// Erases `key`, releasing its count; a parked key leaves its server's FIFO.
void eraseKey(int64_t key) {
    auto& t = tables();
    auto it = t.keys.find(key);
    if (it == t.keys.end()) return;
    AsyncRelease release(it->second.counted);
    if (it->second.parked) {
        if (ServerEntry* s = findServer(it->second.serverId)) {
            auto& p = s->parked;
            p.erase(std::remove(p.begin(), p.end(), key), p.end());
            s->parkedBytes -= std::min(s->parkedBytes, it->second.parkedSize);
        }
    }
    t.keys.erase(it);
}

// Hands a response to the reactor. `token` (0: none) completes through
// RespondDone whatever happens to the connection.
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

// Answers `key` 503 + Connection: close and erases it (closeServer's parked
// requests, a full park budget, a request nobody can ever see).
void respond503(int64_t key) {
    KeyEntry* k = findKey(key);
    if (!k) return;
    std::weak_ptr<Conn> conn = k->conn;
    eraseKey(key);
    ResponseData r;
    r.status = 503;
    submitResponse(std::move(conn), key, std::move(r), /*forceClose=*/true, 0);
}

size_t requestSize(const RequestData& r) {
    size_t n = r.method.size() + r.url.size() + r.body.size() + 64;
    for (const auto& h : r.headers) n += h.first.size() + h.second.size() + 4;
    return n;
}

// --- Event handlers (main thread) ------------------------------------------------

void onRequest(HttpEvent& ev) {
    auto& sched = Scheduler::instance();
    int64_t id = ev.serverId;
    int64_t key = ev.key;
    {
        KeyEntry k;
        k.serverId = id;
        k.conn = ev.conn;
        k.counted = true;
        if (!ev.req.upgrade.empty()) k.req = ev.req;   // the raw request for WS5's takeUpgrade
        sched.incrementPendingAsync();                 // released when the key is erased
        tables().keys[key] = std::move(k);
    }
    bool subscribed = httpManagerHasSubscriber(id);
    ServerEntry* s = findServer(id);
    if (!subscribed && (s == nullptr || s->closed)) {
        respond503(key);   // the server is closed and nobody listens: nobody ever will
        return;
    }
    if (subscribed && (s == nullptr || s->parked.empty())) {
        httpManagerDeliver(id, key, ev.req);   // may run Elm (G11): nothing cached past here
        return;
    }
    // Park it (behind earlier parked requests, in order), within the budget.
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

// Delivers the parked requests of every server that has a subscriber now,
// oldest first.
void deliverParked() {
    std::vector<int64_t> ids;
    for (auto& kv : tables().servers) {
        if (!kv.second.parked.empty() && httpManagerHasSubscriber(kv.first)) ids.push_back(kv.first);
    }
    std::sort(ids.begin(), ids.end());
    for (int64_t id : ids) {
        for (;;) {
            ServerEntry* s = findServer(id);   // again after every Elm call (G11)
            if (!s || s->parked.empty() || !httpManagerHasSubscriber(id)) break;
            int64_t key = s->parked.front();
            s->parked.pop_front();
            KeyEntry* k = findKey(key);
            if (!k) continue;
            s->parkedBytes -= std::min(s->parkedBytes, k->parkedSize);
            k->parked = false;
            k->parkedSize = 0;
            RequestData req = k->req;
            if (req.upgrade.empty()) k->req = RequestData{};
            httpManagerDeliver(id, key, req);
        }
    }
}

bool resumeUnit(uint64_t token) {
    HPointer resume = Scheduler::instance().takePendingResume(token);
    if (alloc::isNil(resume)) return false;   // the task was killed
    HPointer task = alloc::listNil();
    Elm::StackRootGuard g(&resume, &task);
    task = succeedUnit();
    Scheduler::callClosure1(resume, task);
    return true;
}

void onServerClosed(int64_t id) {
    ServerEntry* s = findServer(id);
    if (!s) return;
    ServerEntry e = std::move(*s);
    tables().servers.erase(id);
    AsyncRelease serverCount(e.counted);   // the server's own count, once
    for (int64_t key : e.parked) respond503(key);   // parked after closeServer started
    for (uint64_t token : e.closeTokens) {
        AsyncRelease opCount;
        if (resumeUnit(token)) Scheduler::instance().drain();   // G12
    }
}

void httpDrain() {
    try {
        auto& q = queue();
        if (q.parkedReady.exchange(false, std::memory_order_acq_rel)) deliverParked();
        HttpEvent ev;
        while (tryPop(ev)) {
            if (ev.gen != currentGen()) continue;   // a dead heap's event: nothing to release
            switch (ev.kind) {
            case HttpEvent::Kind::Request:
                onRequest(ev);
                break;
            case HttpEvent::Kind::RespondDone: {
                AsyncRelease release;   // the respond task's count
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
        ::Eco::Kernel::reportFatal(e.what());   // never unwind into the loop (F21)
    } catch (...) {
        ::Eco::Kernel::reportFatal("unknown native exception in the Http.Server drain");
    }
}

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
    // Outside q.m (lock order, sockets plan §3.3.1 rule 6).
    q.sched->notifyWorkAvailableFromAsync();
}

void ensureHttpTables() {
    (void)queue();
    static bool done = false;   // main thread only
    if (done) return;
    done = true;
    // The socket stop hook (embed stop closes every reactor handler) and the
    // reactor itself, started from the main thread.
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
    // A listening server keeps the program alive until closed (§3.4).
    Scheduler::instance().incrementPendingAsync();
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
    if (s->closed) return true;   // completes with the first close
    s->closed = true;
    // Requests nobody was subscribed for: 503 + close (§3.4).
    std::deque<int64_t> parked;
    parked.swap(s->parked);
    s->parkedBytes = 0;
    for (int64_t key : parked) {
        if (KeyEntry* k = findKey(key)) k->parked = false;
        respond503(key);
    }
    s = findServer(serverId);
    auto listener = s->listener;
    auto rstate = s->rstate;
    uint64_t gen = s->cfg->gen;
    int64_t ms = deadlineMs < 0 ? 0 : deadlineMs;
    reactor().submit([listener, rstate, ms, serverId, gen] {
        listener->close();   // the port is free from here on
        http1ServerClosing(rstate, reactor().nowMs() + ms);
        HttpEvent ev;
        ev.kind = HttpEvent::Kind::ServerClosed;
        ev.gen = gen;
        ev.serverId = serverId;
        postHttpEvent(std::move(ev));
    });
    return true;
}

bool httpTablesTakeUpgrade(int64_t key, RequestData& out, std::weak_ptr<Conn>& conn) {
    KeyEntry* k = findKey(key);
    if (!k || k->parked || k->req.upgrade.empty()) return false;
    out = std::move(k->req);
    conn = k->conn;
    eraseKey(key);
    return true;
}

bool httpTablesPopEventForTest(HttpEvent& out) { return tryPop(out); }

void setHttpManagerHooks(HttpManagerHooks hooks) { g_hooks = hooks; }

void httpTablesSubscriptionsChanged() {
    ensureHttpTables();
    for (auto& kv : tables().servers) {
        if (!kv.second.parked.empty() && httpManagerHasSubscriber(kv.first)) {
            queue().parkedReady.store(true, std::memory_order_release);
            return;
        }
    }
}

} // namespace Eco::System::HttpSrv
