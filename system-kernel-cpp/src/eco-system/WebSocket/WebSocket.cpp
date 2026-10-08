//===- WebSocket.cpp - eco/system kernel module WebSocket -----------------===//
//
// plans/eco-system-websockets.md Appendix B.1, §3.6 (phase WS4): see
// WebSocket.hpp. Every body follows G2/G3: copy the inputs out of the heap
// first, then act (reactor submits, pool jobs), then allocate.
//
// Payload layouts (WebSocketExports.cpp):
//   dial         tuple3( boxed target, boxed tls, boxed request ), mask 0
//                  target  ( List String addresses, Int port, Int timeoutMs )
//                  tls     ( ( Bool tls, String serverName ), ( Int verification,
//                            String pem ), ( Bool http2, Bool ) )
//                  request ( String target, List ( String, String ) headers )
//   readUpgrade  tuple2( Int connId, Int timeoutMs ), mask 0x5
//   open         tuple3( boxed ( Int id, ( Int status, List ( String, String ) ) ),
//                        boxed params, boxed ( fromWire, toWire ) ), mask 0
//   reject       tuple2( Int id, boxed ( Int status, List ( String, String ), String ) ), mask 0x1
//   close        tuple3( Int wsId, Int code, boxed String reason ), mask 0x5
//   closed / ping / abandon: the boxed Int id.
//
// Templates used: T1, T2 (dial stage 1 + completion), T7 (kill handles:
// dial, closed), T9/G10 (R and A bodies).
//
//===----------------------------------------------------------------------===//

#include "eco-system/WebSocket/WebSocket.hpp"

#include "eco-system/Core/IoReactor.hpp"
#include "eco-system/Core/SysWorkPool.hpp"
#include "eco-system/Socket/FaceProtocol.hpp"
#include "eco-system/Socket/SocketTables.hpp"
#include "eco-system/Stream/Stream.hpp"
#include "eco-system/Tls/TlsContext.hpp"
#include "eco-system/Tls/TlsTransport.hpp"
#include "eco-system/WebSocket/H2StreamPort.hpp"
#include "eco-system/WebSocket/Http2Client.hpp"
#include "eco-system/WebSocket/WsChannel.hpp"
#include "eco-system/WebSocket/WsHandshake.hpp"
#include "eco-system/WebSocket/WsProtocol.hpp"
#include "eco-system/WebSocket/WsTables.hpp"

#include <cstring>
#include <stdexcept>
#include <unordered_map>
#include <utility>
#include <vector>

namespace Eco::System {

namespace {

[[maybe_unused]] constexpr const char* kWindows = "eco/system: WebSockets are not supported on Windows yet";

IoReactor& reactor() { return IoReactor::instance(); }

// --- Payload decoding (no allocation, G5) ----------------------------------------

bool isElmTrue(HPointer b) { return ::Elm::hpBits(b) == ::Elm::hpBits(alloc::elmTrue()); }

int64_t slotInt(const Unboxable& u, u32 mask, int slot) {
    if (Elm::tupleFieldKind(mask, slot) == 1) return u.i;
    return static_cast<ElmInt*>(Allocator::instance().resolve(u.p))->value;
}

int64_t payloadInt(HPointer captured) {
    return static_cast<ElmInt*>(Allocator::instance().resolve(captured))->value;
}

// List ( String, String ) → HeaderList. No allocation.
HeaderList headerPairs(HPointer list) {
    HeaderList out;
    for (alloc::ListCursor c(list); !c.done(); c.next()) {
        Tuple2* t = asTuple2(c.current().p);
        HPointer n = t->a.p;
        HPointer v = t->b.p;
        out.emplace_back(toStdString(n), toStdString(v));
    }
    return out;
}

HPointer resumeNow(HPointer& resume, HPointer task) {
    Elm::StackRootGuard g(&task);
    Scheduler::callClosure1(resume, task);
    return alloc::unit();
}

// --- dial ---------------------------------------------------------------------------

struct DialArgs {
    std::vector<std::string> addresses;
    int64_t port = 0;
    int64_t timeoutMs = 0;
    bool tls = false;
    std::string serverName;
    int64_t verification = 0;
    std::string pem;
    std::string request;
    // WS9: RFC 8441 first (wss only); the extended CONNECT's fields.
    bool http2 = false;
    std::string target, authority;
    HeaderList h2Headers;
};

// The extended CONNECT's fields from the HTTP/1.1 request headers Elm built
// (D.2): Host becomes :authority; Upgrade, Connection, the key and other
// connection-specific fields are not sent over HTTP/2 (RFC 8441 §4, RFC 9113
// §8.2.2); names lower-case.
void h2RequestFields(const HeaderList& headers, std::string& authority, HeaderList& out) {
    for (const auto& [name, value] : headers) {
        std::string n = name;
        for (char& ch : n) {
            if (ch >= 'A' && ch <= 'Z') ch = static_cast<char>(ch + 32);
        }
        if (n == "host") {
            authority = value;
            continue;
        }
        if (n == "upgrade" || n == "connection" || n == "sec-websocket-key" || n == "keep-alive" ||
            n == "proxy-connection" || n == "transfer-encoding" || n == "te" || n.empty() || n[0] == ':')
            continue;
        if (!httpHeaderValid(name, value)) continue;
        out.emplace_back(std::move(n), value);
    }
}

#ifndef _WIN32

// Stage 2's inputs (TLS), parked on the main thread between the stages.
struct PendingDial {
    DialArgs args;
    std::shared_ptr<TlsClientConfig> cfg;
    std::shared_ptr<TlsClientConfig> cfgH1;   // WS9: ALPN http/1.1 only (the redial)
};

struct PendingTable {
    std::unordered_map<int64_t, PendingDial> m;
    int64_t next = 1;
    uint64_t gen = 0;
    bool init = false;
};

PendingTable& pendingTable() {
    static auto* t = new PendingTable();   // leaky (§3.4); main thread only
    uint64_t g = currentHeapGeneration();
    if (!t->init || t->gen != g) {
        t->init = true;
        t->gen = g;
        t->m.clear();
    }
    return *t;
}

// Registers the task, takes the dial's count and starts the DialJob.
HPointer startDial(DialArgs a, TransportFactory factory, TransportFactory h1Factory, HPointer& resume,
                   uint64_t& token, bool& counted) {
    ensureWsTables();
    auto& s = Scheduler::instance();
    token = s.registerPendingResume(resume);   // G10
    s.incrementPendingAsync();
    counted = true;
    DialSpec spec;
    spec.addresses = std::move(a.addresses);
    spec.port = a.port;
    spec.deadlineMs = a.timeoutMs > 0 ? reactor().nowMs() + a.timeoutMs : 0;
    spec.factory = std::move(factory);
    spec.isTls = a.tls;
    spec.request = std::move(a.request);
    spec.http2 = a.http2 && a.tls && h1Factory != nullptr;
    spec.h1Factory = std::move(h1Factory);
    spec.target = std::move(a.target);
    spec.authority = std::move(a.authority);
    spec.h2Headers = std::move(a.h2Headers);
    spec.token = token;
    spec.gen = currentHeapGeneration();
    auto job = std::make_shared<DialJob>(std::move(spec));
    wsTables().pendingDials[token] = job;
    reactor().submit([job] { job->start(); });
    return makeKillHandle(token, &cancelPendingDial);
}

// Stage 2 (R): payload = the boxed PendingTable id.
HPointer dialStage2Body(HPointer captured, HPointer resume) {
    uint64_t token = 0;
    bool counted = false;
    ECO_SYSTEM_ASYNC_GUARD(FErr, resume, token, counted,
        int64_t id = payloadInt(captured);
        auto& t = pendingTable();
        auto it = t.m.find(id);
        if (it == t.m.end()) return resumeNow(resume, failFErr("ECANCELED", "connect ECANCELED"));
        PendingDial p = std::move(it->second);
        t.m.erase(it);
        TransportFactory factory = makeTlsClientFactory(std::move(p.cfg));
        TransportFactory h1 = p.cfgH1 ? makeTlsClientFactory(std::move(p.cfgH1)) : TransportFactory();
        return startDial(std::move(p.args), std::move(factory), std::move(h1), resume, token, counted);
    )
}

struct DialPrep {
    DialArgs args;
    std::shared_ptr<TlsClientConfig> cfg, cfgH1;
    std::string code, message;
};

// Stage 1 completion (main thread): the failure, or the stage-2 binding.
HPointer dialPrepared(PoolResult& pr) {
    auto& r = pr.as<DialPrep>();
    if (!r.code.empty()) return failFErr(r.code, r.message);
    auto& t = pendingTable();
    int64_t id = t.next++;
    t.m.emplace(id, PendingDial{std::move(r.args), std::move(r.cfg), std::move(r.cfgH1)});
    HPointer payload = alloc::allocInt(id);
    return makeAsyncBinding<dialStage2Body>(payload);   // fresh: the helper roots it
}

#endif // !_WIN32

// ( code, reason, clean ), mask 0x1. Fresh.
HPointer closeInfoTuple(const WsCloseInfo& info) {
    HPointer reason = alloc::allocStringFromUTF8(info.reason);
    return alloc::tuple3(alloc::unboxedInt(info.code), alloc::boxed(reason),
                         alloc::boxed(info.clean ? alloc::elmTrue() : alloc::elmFalse()), 0x1);
}

} // namespace

// ---------------------------------------------------------------------------
// Kernel bodies
// ---------------------------------------------------------------------------

HPointer wsNotImplementedBody(HPointer /*captured*/) {
    ECO_SYSTEM_BODY_GUARD(FErr,
        return failFErr("ENOTSUP", "not implemented yet");
    )
}

HPointer wsHandshakeKeyBody(HPointer /*captured*/) {
    ECO_SYSTEM_BODY_GUARD(Never,
        std::string key = wsNewKey();
        std::string accept = wsAcceptFor(key);
        HPointer k = alloc::allocStringFromUTF8(key);
        HPointer a = alloc::listNil();
        HPointer pair = alloc::listNil();
        Elm::StackRootGuard g({&k, &a, &pair});
        a = alloc::allocStringFromUTF8(accept);
        pair = alloc::tuple2(alloc::boxed(k), alloc::boxed(a), 0);
        return succeed(pair);
    )
}

HPointer wsDialBody(HPointer captured, HPointer resume) {
    uint64_t token = 0;
    bool counted = false;
    ECO_SYSTEM_ASYNC_GUARD(FErr, resume, token, counted,
#ifdef _WIN32
        (void)captured;
        return resumeNow(resume, failFErr("ENOTSUP", kWindows));
#else
        DialArgs a;
        {   // G3/G5: copy everything out; no allocation in this scope
            Tuple3* p = asTuple3(captured);
            HPointer target = p->a.p;
            HPointer tls = p->b.p;
            HPointer request = p->c.p;
            Tuple3* t = asTuple3(target);
            u32 tm = t->header.unboxed;
            HPointer addrs = t->a.p;
            a.port = slotInt(t->b, tm, 1);
            a.timeoutMs = slotInt(t->c, tm, 2);
            a.addresses = ::Eco::Kernel::listToStringVector(enc(addrs));
            Tuple3* tt = asTuple3(tls);
            HPointer first = tt->a.p;
            HPointer verif = tt->b.p;
            Tuple2* ft = asTuple2(first);
            a.tls = isElmTrue(ft->a.p);
            a.serverName = toStdString(ft->b.p);
            Tuple2* vt = asTuple2(verif);
            a.verification = slotInt(vt->a, vt->header.unboxed, 0);
            a.pem = toStdString(vt->b.p);
            Tuple2* ht = asTuple2(tt->c.p);
            a.http2 = isElmTrue(ht->a.p);
            Tuple2* rt = asTuple2(request);
            HPointer path = rt->a.p;
            HPointer headers = rt->b.p;
            a.target = toStdString(path);
            HeaderList pairs = headerPairs(headers);
            a.request = serializeRequest(a.target, pairs);
            if (a.http2) h2RequestFields(pairs, a.authority, a.h2Headers);
        }
        if (a.timeoutMs < 0) a.timeoutMs = 0;
        ensureWsTables();
        if (a.addresses.empty()) return resumeNow(resume, failFErr("ENOTFOUND", "connect ENOTFOUND"));
        if (!a.tls) {
            a.http2 = false;
            return startDial(std::move(a), nullptr, nullptr, resume, token, counted);
        }
        // wss: the client context first, on the pool (CA files, §3.6 of the
        // sockets plan). ALPN offers http/1.1, or h2 first with `http2`
        // (WS9; then a second context with http/1.1 only for the redial).
        ensureTlsInit();
        auto& s = Scheduler::instance();
        token = s.registerPendingResume(resume);
        s.incrementPendingAsync();
        counted = true;
        SysWorkPool::instance().submit(
            token,
            [a = std::move(a)]() mutable -> PoolResult {
                DialPrep r;
                TlsError err;
                std::vector<std::string> h1{"http/1.1"};
                r.cfg = buildTlsClientConfig(a.verification, a.pem, a.serverName,
                                             a.http2 ? std::vector<std::string>{"h2", "http/1.1"} : h1, err);
                if (r.cfg && a.http2) r.cfgH1 = buildTlsClientConfig(a.verification, a.pem, a.serverName, h1, err);
                if (!r.cfg || (a.http2 && !r.cfgH1)) {
                    r.cfg.reset();
                    r.code = err.code.empty() ? "ERR_SSL_UNKNOWN" : err.code;
                    r.message = err.message;
                }
                r.args = std::move(a);
                return PoolResult::of(std::move(r));
            },
            &dialPrepared, ErrShape::FErr);
        return makeKillHandle(token, &SysWorkPool::cancel);
#endif
    )
}

HPointer wsReadUpgradeBody(HPointer captured, HPointer resume) {
    uint64_t token = 0;
    bool counted = false;
    ECO_SYSTEM_ASYNC_GUARD(FErr, resume, token, counted,
#ifdef _WIN32
        (void)captured;
        return resumeNow(resume, failFErr("ENOTSUP", kWindows));
#else
        int64_t connId = 0, timeoutMs = 0;
        {
            Tuple2* t = asTuple2(captured);
            connId = slotInt(t->a, t->header.unboxed, 0);
            timeoutMs = slotInt(t->b, t->header.unboxed, 1);
        }
        ensureWsTables();
        ConnEntry* ce = findConn(connId);
        if (!ce || !ce->conn) return resumeNow(resume, failFErr("ECANCELED", "socket closed"));
        std::shared_ptr<Conn> c = ce->conn;
        auto& s = Scheduler::instance();
        token = s.registerPendingResume(resume);
        s.incrementPendingAsync();
        counted = true;
        uint64_t tok = token, gen = currentHeapGeneration();
        reactor().submit([c, tok, gen, timeoutMs] {
            auto failNow = [&](const char* code, const char* message) {
                WsEvent ev;
                ev.kind = WsEvent::Kind::UpgradeRead;
                ev.gen = gen;
                ev.token = tok;
                ev.failed = true;
                ev.code = code;
                ev.message = message;
                postWsEvent(std::move(ev));
            };
            if (c->phase() != Conn::Phase::Open || c->closing() || c->aborted() || c->writeEnded()) {
                failNow("ECANCELED", "socket closed");
                return;
            }
            FaceProtocol* f = c->face();
            if (!f) {
                failNow("EBUSY", "upgradeRequest EBUSY: the connection was taken over already");
                return;
            }
            // §3.2: no operation may be in flight on the faces.
            if (!f->idle()) {
                failNow("EBUSY", "upgradeRequest EBUSY: the connection has a read, write or close in progress");
                return;
            }
            c->setFaceDetachedReason("upgraded to WebSocket");
            std::string left = f->takeBuffered();
            c->setProtocol(std::make_unique<UpgradeReadProtocol>(tok, gen, timeoutMs), std::move(left));
        });
        return alloc::unit();
#endif
    )
}

HPointer wsOpenBody(HPointer captured, HPointer resume) {
    uint64_t token = 0;
    bool counted = false;
    ECO_SYSTEM_ASYNC_GUARD(FErr, resume, token, counted,
#ifdef _WIN32
        (void)captured;
        return resumeNow(resume, failFErr("ENOTSUP", kWindows));
#else
        int64_t id = 0, status = 0, role = 0, mode = 0, maxMsg = 0;
        int64_t hbInterval = 0, hbTimeout = 0, closeTimeout = 0;
        int64_t threshold = -1, ourBits = 15, peerBits = 15;
        bool ourNoCtx = false, peerNoCtx = false;
        HeaderList headers;
        HPointer fromWire = alloc::listNil(), toWire = alloc::listNil();
        Elm::StackRootGuard closures(&fromWire, &toWire);
        {   // G3/G5: no allocation in this scope
            Tuple3* p = asTuple3(captured);
            HPointer first = p->a.p;
            HPointer params = p->b.p;
            HPointer fns = p->c.p;
            Tuple2* ft = asTuple2(first);
            id = slotInt(ft->a, ft->header.unboxed, 0);
            Tuple2* rt = asTuple2(ft->b.p);
            status = slotInt(rt->a, rt->header.unboxed, 0);
            headers = headerPairs(rt->b.p);
            Tuple3* pt = asTuple3(params);
            HPointer p1 = pt->a.p;
            HPointer p2 = pt->b.p;
            HPointer p3 = pt->c.p;
            Tuple3* t1 = asTuple3(p1);
            role = slotInt(t1->a, t1->header.unboxed, 0);
            mode = slotInt(t1->b, t1->header.unboxed, 1);
            maxMsg = slotInt(t1->c, t1->header.unboxed, 2);
            Tuple3* t2 = asTuple3(p2);
            hbInterval = slotInt(t2->a, t2->header.unboxed, 0);
            hbTimeout = slotInt(t2->b, t2->header.unboxed, 1);
            closeTimeout = slotInt(t2->c, t2->header.unboxed, 2);
            // ( threshold (-1: no deflate), ( ourNoContext, ourBits ), ( peerNoContext, peerBits ) )
            Tuple3* t3 = asTuple3(p3);
            threshold = slotInt(t3->a, t3->header.unboxed, 0);
            Tuple2* ours = asTuple2(t3->b.p);
            ourNoCtx = isElmTrue(ours->a.p);
            ourBits = slotInt(ours->b, ours->header.unboxed, 1);
            Tuple2* peers = asTuple2(t3->c.p);
            peerNoCtx = isElmTrue(peers->a.p);
            peerBits = slotInt(peers->b, peers->header.unboxed, 1);
            Tuple2* fw = asTuple2(fns);
            fromWire = fw->a.p;
            toWire = fw->b.p;
        }
        ensureWsTables();
        auto& t = wsTables();
        auto it = t.handshakes.find(id);
        if (it == t.handshakes.end()) {
            return resumeNow(resume, failFErr("EINVAL", "open EINVAL: the handshake was answered already"));
        }
        if (mode != 1 && mode != 2) return resumeNow(resume, failFErr("EINVAL", "open EINVAL: unknown mode"));
        std::shared_ptr<Conn> c = std::move(it->second.conn);
        std::shared_ptr<H2PendingUpgrade> h2 = std::move(it->second.h2);
        t.handshakes.erase(it);
        std::string response = role == 1 && !h2 ? serializeResponse(static_cast<int>(status), headers, false,
                                                                    std::string())
                                                : std::string();
        WsConfig cfg;
        cfg.server = role == 1;
        cfg.maxMessage = maxMsg > 0 ? static_cast<uint64_t>(maxMsg) : 0;
        cfg.heartbeatInterval = hbInterval > 0 ? hbInterval : 0;
        cfg.heartbeatTimeout = hbTimeout > 0 ? hbTimeout : 0;
        cfg.closeTimeout = closeTimeout > 0 ? closeTimeout : 30000;
        cfg.streamed = mode == 2;
        cfg.deflate = threshold >= 0;
        cfg.threshold = threshold >= 0 ? threshold : 0;
        cfg.ourNoContext = ourNoCtx;
        cfg.ourBits = static_cast<int>(ourBits >= 8 && ourBits <= 15 ? ourBits : 15);
        cfg.peerNoContext = peerNoCtx;
        cfg.peerBits = static_cast<int>(peerBits >= 8 && peerBits <= 15 ? peerBits : 15);
        cfg.wsId = t.nextWsId++;
        cfg.gen = currentHeapGeneration();
        int64_t wsId = cfg.wsId;
        auto core = std::make_shared<WsCore>(cfg);
        auto& s = Scheduler::instance();
        token = s.registerPendingResume(resume);
        s.incrementPendingAsync();
        counted = true;
        WsEntry entry;
        entry.core = core;
        t.sockets.emplace(wsId, std::move(entry));
        uint64_t tok = token, gen = cfg.gen;
        if (h2) {
            // WS9 server: 200 on the extended CONNECT stream (no END_STREAM),
            // the stream bound to the codec through an H2StreamPort.
            int st = static_cast<int>(status);
            reactor().submit([h2, core, st, headers = std::move(headers), tok, gen, wsId] {
                WsEvent ev;
                ev.kind = WsEvent::Kind::Opened;
                ev.gen = gen;
                ev.token = tok;
                ev.wsId = wsId;
                if (!h2->describe(ev.local, ev.remote)) {
                    core->portClosed();
                    ev.failed = true;
                    ev.code = "ECONNRESET";
                    ev.message = "socket closed";
                    postWsEvent(std::move(ev));
                    return;
                }
                postWsEvent(std::move(ev));
                auto port = std::make_shared<H2StreamPort>(core);
                if (!h2->accept(st, headers, port)) port->bind(nullptr, std::string());   // closes the core
            });
        }
        // Install the codec first (reactor commands run in order: the stream
        // requests created below reach an installed core).
        if (!h2) reactor().submit([c, core, response = std::move(response), tok, gen, wsId]() mutable {
            HoldProtocol* hold = c ? dynamic_cast<HoldProtocol*>(c->protocol()) : nullptr;
            // WS9 client: an answered extended CONNECT parked in its session.
            Http2ClientProtocol* h2c = c && !hold ? dynamic_cast<Http2ClientProtocol*>(c->protocol()) : nullptr;
            WsEvent ev;
            ev.kind = WsEvent::Kind::Opened;
            ev.gen = gen;
            ev.token = tok;
            ev.wsId = wsId;
            if ((!hold && !h2c) || c->phase() != Conn::Phase::Open || c->closing() || c->aborted()) {
                core->portClosed();
                ev.failed = true;
                ev.code = "ECONNRESET";
                ev.message = "socket closed";
                postWsEvent(std::move(ev));
                return;
            }
            if (h2c) {
                SocketEvent se;
                c->describe(se, std::string());
                ev.local = se.local;
                ev.remote = se.remote;
                postWsEvent(std::move(ev));
                auto port = std::make_shared<H2StreamPort>(core);
                if (!h2c->bindPort(port)) port->bind(nullptr, std::string());   // closes the core
                return;
            }
            std::string left = hold->takeLeftover();
            (void)c->setNoDelay(true);   // small frames (pongs, pings) go out at once
            if (!response.empty()) c->write(std::move(response), nullptr);
            SocketEvent se;
            c->describe(se, std::string());
            ev.local = se.local;
            ev.remote = se.remote;
            postWsEvent(std::move(ev));
            c->setProtocol(std::make_unique<WsProtocol>(core), std::move(left));
        });
        // The stream pair (W16): fromWire / toWire are stored in the pairs
        // (scanned) with no allocation since they were read.
        int64_t rid = createMappedSource(new WsReadChannel(core, wsId), enc(fromWire));
        int64_t wid = createMappedSink(new WsWriteChannel(core, wsId), enc(toWire));
        if (WsEntry* e = findWs(wsId)) {
            e->readableId = rid;
            e->writableId = wid;
        }
        return alloc::unit();
#endif
    )
}

HPointer wsRejectBody(HPointer captured, HPointer resume) {
    uint64_t token = 0;
    bool counted = false;
    ECO_SYSTEM_ASYNC_GUARD(Never, resume, token, counted,
#ifdef _WIN32
        (void)captured;
        return resumeNow(resume, succeedUnit());
#else
        int64_t id = 0, status = 0;
        HeaderList headers;
        std::string body;
        {
            Tuple2* p = asTuple2(captured);
            id = slotInt(p->a, p->header.unboxed, 0);
            Tuple3* r = asTuple3(p->b.p);
            status = slotInt(r->a, r->header.unboxed, 0);
            headers = headerPairs(r->b.p);
            body = toStdString(r->c.p);
        }
        ensureWsTables();
        auto& t = wsTables();
        auto it = t.handshakes.find(id);
        if (it == t.handshakes.end()) return resumeNow(resume, succeedUnit());   // answered already
        std::shared_ptr<Conn> c = std::move(it->second.conn);
        std::shared_ptr<H2PendingUpgrade> h2 = std::move(it->second.h2);
        t.handshakes.erase(it);
        if (status < 100 || status > 999) status = 400;
        auto& s = Scheduler::instance();
        token = s.registerPendingResume(resume);
        s.incrementPendingAsync();
        counted = true;
        uint64_t tok = token, gen = currentHeapGeneration();
        if (h2) {
            // WS9: an ordinary HTTP/2 response on the extended CONNECT stream.
            int st = static_cast<int>(status);
            reactor().submit([h2, st, headers = std::move(headers), body = std::move(body), tok, gen]() mutable {
                h2->reject(st, headers, std::move(body), [tok, gen](int) {
                    WsEvent ev;
                    ev.kind = WsEvent::Kind::OpDone;
                    ev.gen = gen;
                    ev.token = tok;
                    postWsEvent(std::move(ev));
                });
            });
            return alloc::unit();
        }
        std::string bytes = serializeResponse(static_cast<int>(status), headers, true, body);
        reactor().submit([c, bytes = std::move(bytes), tok, gen]() mutable {
            auto done = [tok, gen](int) {
                WsEvent ev;
                ev.kind = WsEvent::Kind::OpDone;
                ev.gen = gen;
                ev.token = tok;
                postWsEvent(std::move(ev));
            };
            if (!c || c->phase() != Conn::Phase::Open || c->closing() || c->aborted()) {
                done(0);
                return;
            }
            c->write(std::move(bytes), done);
            c->closeGraceful(Conn::kFaceDrainMs);
        });
        return alloc::unit();
#endif
    )
}

HPointer wsAbandonBody(HPointer captured) {
    ECO_SYSTEM_BODY_GUARD(Never,
        int64_t id = payloadInt(captured);
        ensureWsTables();
        auto& t = wsTables();
        auto it = t.handshakes.find(id);
        if (it != t.handshakes.end()) {
            std::shared_ptr<Conn> c = std::move(it->second.conn);
            std::shared_ptr<H2PendingUpgrade> h2 = std::move(it->second.h2);
            t.handshakes.erase(it);
            if (c) reactor().submit([c] { c->abort(false); });
            if (h2) reactor().submit([h2] { h2->abandon(); });
        }
        return succeedUnit();
    )
}

HPointer wsCloseBody(HPointer captured, HPointer resume) {
    uint64_t token = 0;
    bool counted = false;
    ECO_SYSTEM_ASYNC_GUARD(Never, resume, token, counted,
        int64_t wsId = 0, code = 0;
        std::string reason;
        {
            Tuple3* p = asTuple3(captured);
            wsId = slotInt(p->a, p->header.unboxed, 0);
            code = slotInt(p->b, p->header.unboxed, 1);
            reason = toStdString(p->c.p);
        }
        ensureWsTables();
        WsEntry* e = findWs(wsId);
        if (!e || e->closed || !e->core) return resumeNow(resume, succeedUnit());   // idempotent
        std::shared_ptr<WsCore> core = e->core;
        wsTablesCloseStarted(wsId);   // the close handshake keeps the program alive
        auto& s = Scheduler::instance();
        token = s.registerPendingResume(resume);
        s.incrementPendingAsync();
        counted = true;
        uint64_t tok = token;
        int c = static_cast<int>(code);
        reactor().submit([core, c, reason = std::move(reason), tok] { core->startClose(c, reason, tok); });
        return alloc::unit();
    )
}

HPointer wsClosedBody(HPointer captured, HPointer resume) {
    uint64_t token = 0;
    bool counted = false;
    ECO_SYSTEM_ASYNC_GUARD(Never, resume, token, counted,
        int64_t wsId = payloadInt(captured);
        ensureWsTables();
        WsEntry* e = findWs(wsId);
        if (!e || e->closed) {
            WsCloseInfo info = e ? e->info : wsRecentCloseInfo(wsId);
            HPointer task = alloc::listNil();
            Elm::StackRootGuard g(&task);
            task = closeInfoTuple(info);
            task = succeed(task);
            return resumeNow(resume, task);
        }
        auto& s = Scheduler::instance();
        token = s.registerPendingResume(resume);
        s.incrementPendingAsync();   // a parked `closed` keeps the program alive (§3.6)
        counted = true;
        e->closedWaiters.push_back(token);
        return makeKillHandle(token, &cancelClosedWaiter);
    )
}

// openOutgoing (S, WS6): a writable for one message sent as a stream. The
// stream's place in the data FIFO is taken now (the reactor command runs
// before any write made through the returned pair). Payload tuple2( Int wsId,
// Int kind ), mask 0x5; kind 1 text (a writable of Strings), 2 binary.
HPointer wsOpenOutgoingBody(HPointer captured) {
    ECO_SYSTEM_BODY_GUARD(FErr,
        int64_t wsId = 0, kind = 0;
        {
            Tuple2* t = asTuple2(captured);
            wsId = slotInt(t->a, t->header.unboxed, 0);
            kind = slotInt(t->b, t->header.unboxed, 1);
        }
        ensureWsTables();
        WsEntry* e = findWs(wsId);
        if (!e || e->closed || !e->core) return failFErr("ECANCELED", "socket closed");
        std::shared_ptr<WsCore> core = e->core;
        uint64_t seq = ++e->outSeq;
        uint8_t opcode = kind == 1 ? ws::kOpText : ws::kOpBinary;
        reactor().submit([core, seq, opcode] { core->openOutgoing(seq, opcode); });
        auto* ch = new WsOutChannel(core, seq);
        int64_t pid = kind == 1 ? createTextChannelSink(ch) : createChannelSink(ch);
        return succeedInt(pid);
    )
}

HPointer wsPingBody(HPointer captured, HPointer resume) {
    uint64_t token = 0;
    bool counted = false;
    ECO_SYSTEM_ASYNC_GUARD(FErr, resume, token, counted,
        int64_t wsId = payloadInt(captured);
        ensureWsTables();
        WsEntry* e = findWs(wsId);
        if (!e || e->closed || !e->core) {
            return resumeNow(resume, failFErr("ECANCELED", "ping ECANCELED: the WebSocket is closed"));
        }
        std::shared_ptr<WsCore> core = e->core;
        auto& s = Scheduler::instance();
        token = s.registerPendingResume(resume);
        s.incrementPendingAsync();
        counted = true;
        uint64_t tok = token;
        reactor().submit([core, tok] { core->startPing(tok); });
        return alloc::unit();
    )
}

} // namespace Eco::System
