//===- Tls.cpp - eco/system kernel module Tls: binding bodies -------------===//
//
// A connect's configuration job and its socket connect run under one resume token: the job's hand-off
// (`SysWorkPool::HandoffFn`) starts the connect on the eco thread under the token the job was submitted with, so no
// Task runs between the two steps and nothing waits in a table for one to run (TLS-10). The only table is the set of
// tokens whose configuration job is in flight, which tells the kill handle which step to cancel and the hand-off
// whether the Task was killed meanwhile. It holds no HPointers, each entry is erased when its job's result is drained
// or its job cancelled, and it is emptied when the heap generation changes.
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

// --- connect (pool, then the socket connect) ----------------------------------------

// What a configuration job produces: the connect's inputs and its client configuration, or a failure.
struct ConnectPrep {
    ConnectSpec spec;
    std::shared_ptr<TlsClientConfig> cfg;
    std::string code, message;   // failure (code non-empty)
};

// The tokens of connects whose configuration job is in flight, each mapped to whether its Task was killed meanwhile,
// for heap generation `gen`.
struct InflightTable {
    std::unordered_map<uint64_t, bool> killed;
    uint64_t gen = 0;
    bool init = false;
};

// Returns the table of in-flight configuration jobs, first emptying it if the heap generation has changed. Eco thread
// only.
InflightTable& inflightConnects() {
    static auto* t = new InflightTable();   // never destroyed
    uint64_t g = currentHeapGeneration();
    if (!t->init || t->gen != g) {   // a dead heap's tokens are meaningless
        t->init = true;
        t->gen = g;
        t->killed.clear();
    }
    return *t;
}

// The kill handle's cancel for a TLS connect under `token`, as `CancelFn` defines it: removes the configuration job if
// no worker has started it; else, while the job is in flight, records the kill for the hand-off and returns false (the
// drain releases the hold); else cancels the socket connect the hand-off started.
bool cancelTlsConnect(uint64_t token) {
    auto& t = inflightConnects();
    auto it = t.killed.find(token);
    if (it != t.killed.end()) {
        if (SysWorkPool::cancel(token)) {
            t.killed.erase(it);
            return true;
        }
        it->second = true;
        return false;
    }
    return cancelPendingConnect(token);
}

// The configuration job's hand-off: unless the Task was killed or the job failed, starts the connect with the TLS
// client factory under the job's token and returns true. Otherwise returns false, and the drain finishes the job with
// `connectPrepared` (or releases only, for a killed Task).
bool connectHandoff(uint64_t token, PoolResult& pr) {
    auto& t = inflightConnects();
    auto it = t.killed.find(token);
    bool killed = it == t.killed.end() || it->second;   // absent: a dead heap's job
    if (it != t.killed.end()) t.killed.erase(it);
    if (killed || !pr.holds<ConnectPrep>()) return false;
    auto& r = pr.as<ConnectPrep>();
    if (!r.code.empty()) return false;
    socketContinueConnect(std::move(r.spec), makeTlsClientFactory(std::move(r.cfg)), token);
    return true;
}

// Completes a configuration job the hand-off did not take: returns the FErr Task of the failed build.
HPointer connectPrepared(PoolResult& pr) {
    auto& r = pr.as<ConnectPrep>();
    if (!r.code.empty()) return failFErr(r.code, r.message);
    // Not reached: a successful build is always handed off, unless the Task was killed, which never completes it.
    return failFErr("ECANCELED", "connect ECANCELED");
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

#if ECO_TEST_HOOKS && !defined(_WIN32)
namespace TlsTesting {

size_t inflightConnectCount() { return inflightConnects().killed.size(); }

} // namespace TlsTesting
#endif

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
        ensureSocketTables();
        if (!socketIoAvailable()) return resumeNow(resume, socketIoUnavailable("connect"));
        ensureTlsInit();
        auto& s = Scheduler::instance();
        token = s.parkResume(resume, HoldKind::Task, "Tls.connect");
        counted = true;
        // The kill handle first: it allocates, and a throw must leave neither a queued job nor a table entry.
        HPointer kill = makeKillHandle(token, &cancelTlsConnect);
        Elm::StackRootGuard g(&kill);
        auto& inflight = inflightConnects().killed;
        inflight.emplace(token, false);
        try {
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
                &connectPrepared, ErrShape::FErr, &connectHandoff);
        } catch (...) {
            inflight.erase(token);
            throw;
        }
        return kill;
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
