//===- Tls.cpp - eco/system kernel module Tls: binding bodies -------------===//
//
// See Tls.hpp (plans/eco-system-sockets.md §3.6, Appendix B.3, §D.5).
//
// Payload layouts (TlsExports.cpp): connect and listen get
// tuple3( boxed target, boxed settings, boxed tls ), mask 0, where
//   connect: target   ( String address, Int port, Int timeoutMs )
//            settings ( Bool noDelay, Int keepAliveSec )
//            tls      ( String serverName, ( Int verification, String pem ), List String alpn )
//   listen:  target   ( String address, Int port )
//            settings ( Int backlog, Bool ipv6Only )
//            tls      ( String certificateChain, String privateKey, List String alpn )
// info gets the boxed connection id.
//
// Stage 2 of connect: the pool completion (main thread) parks the built
// configuration in a main-thread table (heap-generation keyed; no
// HPointers) under a fresh id and returns makeAsyncBinding<stage2>(id). The
// pool drain resumes the task with that binding, so the scheduler steps
// into it at once and installs its kill handle. A killed stage-1 job never
// completes (SysWorkPool skips orphans, SF12); an entry whose stage 2 never
// runs (a kill between the two stages) stays until the heap is reset.
//
// Templates used: T1 (info), T2 (pool bodies + completions), T7, G3, G10.
//
//===----------------------------------------------------------------------===//

#include "eco-system/Tls/Tls.hpp"

#include "eco-system/Core/SysWorkPool.hpp"
#include "eco-system/Socket/Socket.hpp"
#include "eco-system/Socket/SocketTables.hpp"
#include "eco-system/Tls/TlsContext.hpp"
#include "eco-system/Tls/TlsTransport.hpp"

#include <string>
#include <unordered_map>
#include <utility>
#include <vector>

namespace Eco::System {

namespace {

#ifdef _WIN32
constexpr const char* kWindows = "eco/system: TLS is not supported on Windows yet";
#endif

// --- Payload decoding (no allocation, G5) ----------------------------------------

bool isElmTrue(HPointer b) { return ::Elm::hpBits(b) == ::Elm::hpBits(alloc::elmTrue()); }

int64_t slotInt(const Unboxable& u, u32 mask, int slot) {
    if (Elm::tupleFieldKind(mask, slot) == 1) return u.i;
    return static_cast<ElmInt*>(Allocator::instance().resolve(u.p))->value;
}

int64_t payloadInt(HPointer captured) {
    return static_cast<ElmInt*>(Allocator::instance().resolve(captured))->value;
}

HPointer resumeNow(HPointer& resume, HPointer task) {
    Elm::StackRootGuard g(&task);
    Scheduler::callClosure1(resume, task);
    return alloc::unit();
}

#ifndef _WIN32

// --- connect: stage 1 (pool) -------------------------------------------------------

struct ConnectPrep {
    ConnectSpec spec;
    std::shared_ptr<TlsClientConfig> cfg;
    std::string code, message;   // failure (code non-empty)
};

// Stage 2's inputs, parked on the main thread between the stages.
struct PendingConnect {
    ConnectSpec spec;
    std::shared_ptr<TlsClientConfig> cfg;
};

struct PendingTable {
    std::unordered_map<int64_t, PendingConnect> m;
    int64_t next = 1;
    uint64_t gen = 0;
    bool init = false;
};

PendingTable& pendingConnects() {
    static auto* t = new PendingTable();   // leaky (§3.4); main thread only
    uint64_t g = currentHeapGeneration();
    if (!t->init || t->gen != g) {   // a dead heap's entries are meaningless
        t->init = true;
        t->gen = g;
        t->m.clear();
    }
    return *t;
}

// Stage 2 (R): payload = the boxed PendingTable id.
HPointer connectStage2Body(HPointer captured, HPointer resume) {
    uint64_t token = 0;
    bool counted = false;
    ECO_SYSTEM_ASYNC_GUARD(FErr, resume, token, counted,
        int64_t id = payloadInt(captured);
        auto& t = pendingConnects();
        auto it = t.m.find(id);
        if (it == t.m.end()) {   // a dead heap's binding, or run twice
            return resumeNow(resume, failFErr("ECANCELED", "connect ECANCELED"));
        }
        PendingConnect p = std::move(it->second);
        t.m.erase(it);
        TransportFactory factory = makeTlsClientFactory(std::move(p.cfg));
        return socketStartConnect(std::move(p.spec), std::move(factory), resume, token, counted);
    )
}

// Stage 1 completion (main thread): the failure, or the stage-2 binding.
HPointer connectPrepared(PoolResult& pr) {
    auto& r = pr.as<ConnectPrep>();
    if (!r.code.empty()) return failFErr(r.code, r.message);
    auto& t = pendingConnects();
    int64_t id = t.next++;
    t.m.emplace(id, PendingConnect{std::move(r.spec), std::move(r.cfg)});
    HPointer payload = alloc::allocInt(id);
    return makeAsyncBinding<connectStage2Body>(payload);   // fresh: the helper roots it
}

// --- listen (pool) -------------------------------------------------------------------

struct ListenPrep {
    std::shared_ptr<TlsServerConfig> cfg;
    ListenResult listen;           // owns the fd (RAII, N11)
    std::string code, message;     // context failure (code non-empty)
};

HPointer listenPrepared(PoolResult& pr) {
    auto& r = pr.as<ListenPrep>();
    if (!r.code.empty()) return failFErr(r.code, r.message);
    TransportFactory factory = r.listen.code.empty() ? makeTlsServerFactory(r.cfg) : nullptr;
    return completeListen(r.listen, std::move(factory));
}

#endif // !_WIN32

} // namespace

// ---------------------------------------------------------------------------
// Kernel bodies
// ---------------------------------------------------------------------------

HPointer tlsConnectBody(HPointer captured, HPointer resume) {
    uint64_t token = 0;
    bool counted = false;
    ECO_SYSTEM_ASYNC_GUARD(FErr, resume, token, counted,
#ifdef _WIN32
        (void)captured;
        return resumeNow(resume, failFErr("ENOTSUP", kWindows));
#else
        ConnectSpec spec;
        std::string serverName, pem;
        int64_t mode = 0;
        std::vector<std::string> alpn;
        {   // G3/G5: copy everything out; no allocation in this scope
            Tuple3* p = asTuple3(captured);
            HPointer target = p->a.p;
            HPointer settings = p->b.p;
            HPointer tls = p->c.p;
            Tuple3* t = asTuple3(target);
            u32 tm = t->header.unboxed;
            HPointer addr = t->a.p;
            spec.port = slotInt(t->b, tm, 1);
            spec.timeoutMs = slotInt(t->c, tm, 2);
            spec.address = toStdString(addr);
            Tuple2* st = asTuple2(settings);
            spec.noDelay = isElmTrue(st->a.p);
            spec.keepAliveSec = slotInt(st->b, st->header.unboxed, 1);
            Tuple3* tt = asTuple3(tls);
            HPointer name = tt->a.p;
            HPointer verification = tt->b.p;
            HPointer alpnList = tt->c.p;
            serverName = toStdString(name);
            Tuple2* vt = asTuple2(verification);
            mode = slotInt(vt->a, vt->header.unboxed, 0);
            pem = toStdString(vt->b.p);
            alpn = ::Eco::Kernel::listToStringVector(enc(alpnList));
        }
        if (spec.timeoutMs < 0) spec.timeoutMs = 0;
        spec.isUnix = false;
        spec.isTls = true;
        ensureTlsInit();
        ensureSocketTables();
        auto& s = Scheduler::instance();
        token = s.registerPendingResume(resume);
        s.incrementPendingAsync();
        counted = true;
        SysWorkPool::instance().submit(
            token,
            [spec = std::move(spec), mode, pem = std::move(pem), serverName = std::move(serverName),
             alpn = std::move(alpn)]() -> PoolResult {
                ConnectPrep r;
                TlsError err;
                r.cfg = buildTlsClientConfig(mode, pem, serverName, alpn, err);
                if (!r.cfg) {
                    r.code = err.code.empty() ? "ERR_SSL_UNKNOWN" : err.code;
                    r.message = err.message;
                }
                r.spec = spec;
                return PoolResult::of(std::move(r));
            },
            &connectPrepared, ErrShape::FErr);
        return makeKillHandle(token, &SysWorkPool::cancel);
#endif
    )
}

HPointer tlsListenBody(HPointer captured, HPointer resume) {
    uint64_t token = 0;
    bool counted = false;
    ECO_SYSTEM_ASYNC_GUARD(FErr, resume, token, counted,
#ifdef _WIN32
        (void)captured;
        return resumeNow(resume, failFErr("ENOTSUP", kWindows));
#else
        std::string address, chain, key;
        int64_t port = 0, backlog = 511;
        bool ipv6Only = false;
        std::vector<std::string> alpn;
        {   // G3/G5
            Tuple3* p = asTuple3(captured);
            HPointer target = p->a.p;
            HPointer settings = p->b.p;
            HPointer tls = p->c.p;
            Tuple2* t = asTuple2(target);
            HPointer addr = t->a.p;
            port = slotInt(t->b, t->header.unboxed, 1);
            address = toStdString(addr);
            Tuple2* st = asTuple2(settings);
            backlog = slotInt(st->a, st->header.unboxed, 0);
            ipv6Only = isElmTrue(st->b.p);
            Tuple3* tt = asTuple3(tls);
            HPointer chainHP = tt->a.p;
            HPointer keyHP = tt->b.p;
            HPointer alpnList = tt->c.p;
            chain = toStdString(chainHP);
            key = toStdString(keyHP);
            alpn = ::Eco::Kernel::listToStringVector(enc(alpnList));
        }
        ensureTlsInit();
        ensureSocketTables();
        auto& s = Scheduler::instance();
        token = s.registerPendingResume(resume);
        s.incrementPendingAsync();
        counted = true;
        SysWorkPool::instance().submit(
            token,
            [address = std::move(address), port, backlog, ipv6Only, chain = std::move(chain),
             key = std::move(key), alpn = std::move(alpn)]() -> PoolResult {
                ListenPrep r;
                TlsError err;
                r.cfg = buildTlsServerConfig(chain, key, alpn, err);
                if (!r.cfg) {
                    r.code = err.code.empty() ? "ERR_SSL_UNKNOWN" : err.code;
                    r.message = err.message;
                    return PoolResult::of(std::move(r));
                }
                r.listen = tcpListenOn(address, port, backlog, ipv6Only);
                return PoolResult::of(std::move(r));
            },
            &listenPrepared, ErrShape::FErr);
        return alloc::unit();   // short job; an orphaned result closes its fd (RAII)
#endif
    )
}

// info : Int -> Task FErr ( String, Maybe String, String ) — payload: boxed connection id.
HPointer tlsInfoBody(HPointer captured) {
    ECO_SYSTEM_BODY_GUARD(FErr,
#ifdef _WIN32
        (void)captured;
        return failFErr("ENOTSUP", kWindows);
#else
        int64_t id = payloadInt(captured);
        ensureSocketTables();
        ConnEntry* e = findConn(id);
        if (!e || !e->isTls) return failFErr("EINVAL", "info EINVAL: not a TLS connection");
        TlsInfo info = e->tls;   // G3: copy before allocating (e may move)
        HPointer protocol = alloc::listNil();
        HPointer alpn = alloc::listNil();
        HPointer cipher = alloc::listNil();
        Elm::StackRootGuard g({&protocol, &alpn, &cipher});
        protocol = alloc::allocStringFromUTF8(info.protocol);
        if (info.alpn.empty()) {
            alpn = alloc::nothing();
        } else {
            HPointer s = alloc::allocStringFromUTF8(info.alpn);
            alpn = alloc::just(alloc::boxed(s), true);   // fresh: the helper roots it (G4)
        }
        cipher = alloc::allocStringFromUTF8(info.cipher);
        return succeed(alloc::tuple3(alloc::boxed(protocol), alloc::boxed(alpn), alloc::boxed(cipher), 0));
#endif
    )
}

} // namespace Eco::System
