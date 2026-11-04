//===- Tls.cpp - eco/system kernel module Tls: binding bodies -------------===//
//
// The connect's stage-2 inputs wait in a table on the eco thread, keyed by an id that stage 2's payload carries,
// because a binding's payload is an Elm value and the inputs are C++ objects. The table holds no HPointers, and it
// is emptied when the heap generation changes, since its entries then belong to a heap that is gone. A stage-1 job
// whose Task is killed before it is completed never reaches the table. An entry whose stage 2 never runs stays
// until the heap generation changes.
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
// The FErr message of every Tls kernel on Windows.
constexpr const char* kWindows = "eco/system: TLS is not supported on Windows yet";
#endif

// --- Payload decoding (these three do not allocate) --------------------------------

// Returns whether `b` is the Elm `True` constant.
bool isElmTrue(HPointer b) { return ::Elm::hpBits(b) == ::Elm::hpBits(alloc::elmTrue()); }

// Returns the Int in slot `slot` of a tuple whose kind mask is `mask`, whether stored unboxed or boxed.
int64_t slotInt(const Unboxable& u, u32 mask, int slot) {
    if (Elm::tupleFieldKind(mask, slot) == 1) return u.i;
    return static_cast<ElmInt*>(Allocator::instance().resolve(u.p))->value;
}

// Returns the value of the boxed Elm Int `captured`.
int64_t payloadInt(HPointer captured) {
    return static_cast<ElmInt*>(Allocator::instance().resolve(captured))->value;
}

// --- Resuming at once -------------------------------------------------------------

// Resumes the Task with `task`, which replaces it before any work starts, and returns `()` as the body's kill handle.
HPointer resumeNow(HPointer& resume, HPointer task) {
    Elm::StackRootGuard g(&task);
    Scheduler::callClosure1(resume, task);
    return alloc::unit();
}

#ifndef _WIN32

// --- connect: stage 1 (pool) -------------------------------------------------------

// What a stage-1 job produces: the connect's inputs and its client configuration, or a failure.
struct ConnectPrep {
    ConnectSpec spec;
    std::shared_ptr<TlsClientConfig> cfg;
    std::string code, message;   // failure (code non-empty)
};

// Stage 2's inputs, kept on the eco thread between the stages.
struct PendingConnect {
    ConnectSpec spec;
    std::shared_ptr<TlsClientConfig> cfg;
};

// The stage-2 inputs waiting for their stage 2, by id, for heap generation `gen`.
struct PendingTable {
    std::unordered_map<int64_t, PendingConnect> m;
    int64_t next = 1;
    uint64_t gen = 0;
    bool init = false;
};

// Returns the table of stage-2 inputs, first emptying it if the heap generation has changed. Eco thread only.
PendingTable& pendingConnects() {
    static auto* t = new PendingTable();   // never destroyed
    uint64_t g = currentHeapGeneration();
    if (!t->init || t->gen != g) {   // a dead heap's entries are meaningless
        t->init = true;
        t->gen = g;
        t->m.clear();
    }
    return *t;
}

// Takes the stage-2 inputs whose id is the boxed Int `captured` and starts the connect with the TLS client factory,
// returning its kill handle. With no entry for the id, it resumes the Task at once with ECANCELED.
HPointer connectStage2Body(HPointer captured, HPointer resume) {
    uint64_t token = 0;
    bool counted = false;
    ECO_SYSTEM_ASYNC_GUARD(FErr, resume, token, counted,
        int64_t id = payloadInt(captured);
        auto& t = pendingConnects();
        auto it = t.m.find(id);
        if (it == t.m.end()) {   // a dead heap's binding, or the entry already taken
            return resumeNow(resume, failFErr("ECANCELED", "connect ECANCELED"));
        }
        PendingConnect p = std::move(it->second);
        t.m.erase(it);
        TransportFactory factory = makeTlsClientFactory(std::move(p.cfg));
        return socketStartConnect(std::move(p.spec), std::move(factory), resume, token, counted);
    )
}

// Completes stage 1: returns the FErr Task of a failed build, or else stores the inputs under a fresh id and returns
// the stage-2 binding for it.
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

// What the listen job produces: the server configuration and the listen outcome, or a configuration failure.
struct ListenPrep {
    std::shared_ptr<TlsServerConfig> cfg;
    ListenResult listen;           // owns the socket until completeListen takes it
    std::string code, message;     // context failure (code non-empty)
};

// Completes the listen: the FErr Task of a failed build, or `completeListen` of the outcome, with the TLS server
// factory when the socket was opened.
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
        {   // copy everything out; nothing in this scope allocates, so the raw pointers stay valid
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
        token = s.parkResume(resume, HoldKind::Task, "Tls.connect");
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
        {   // copy everything out, as in tlsConnectBody
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
        token = s.parkResume(resume, HoldKind::Task, "Tls.listen");
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
        return alloc::unit();   // no kill handle; a result never completed closes its socket
#endif
    )
}

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
        TlsInfo info = e->tls;   // copied, so nothing below reads through `e`
        HPointer protocol = alloc::listNil();
        HPointer alpn = alloc::listNil();
        HPointer cipher = alloc::listNil();
        Elm::StackRootGuard g({&protocol, &alpn, &cipher});
        protocol = alloc::allocStringFromUTF8(info.protocol);
        if (info.alpn.empty()) {
            alpn = alloc::nothing();
        } else {
            HPointer s = alloc::allocStringFromUTF8(info.alpn);
            alpn = alloc::just(alloc::boxed(s), true);   // fresh: the helper roots it
        }
        cipher = alloc::allocStringFromUTF8(info.cipher);
        return succeed(alloc::tuple3(alloc::boxed(protocol), alloc::boxed(alpn), alloc::boxed(cipher), 0));
#endif
    )
}

} // namespace Eco::System
