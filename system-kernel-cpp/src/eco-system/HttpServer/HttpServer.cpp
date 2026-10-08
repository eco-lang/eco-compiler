//===- HttpServer.cpp - eco/system kernel module HttpServer ---------------===//
//
// plans/eco-system-library.md Appendix B.6 / Phase 7 and
// plans/eco-system-websockets.md §3.4 / Appendix B.2 (phase WS2): the
// binding bodies of Eco.Kernel.HttpServer. Connections run on the IoReactor
// (Http1.cpp); the main-thread state is in HttpTables.cpp.
//
//   * createServer (P mode, T2): the pool worker resolves the host and
//     opens the listening socket (HttpSrv::listenOn: IPv4 first, socket,
//     SO_REUSEADDR, bind, listen; non-blocking). The main-thread completion
//     hands it to HttpTables (a ListenerHandler in callback mode), which
//     takes the server's keep-alive count (released when closeServer is
//     done). Result: ( serverId, boundPort ) — the port the system picked
//     for port 0. A failure is the FErr tuple ( code, message ), e.g.
//     ( "EADDRINUSE", "listen EADDRINUSE: ..." ).
//   * createServerWith (P mode, T2): the same over Socket's tcpListenOn
//     (an Address, Socket.Address text), with the §7 / A.2 options; http2
//     without tls fails EINVAL (Elm checks it first). With tls (WS3,
//     websockets plan §3.5) the same pool job first builds the TLS server
//     context (buildTlsServerConfig: certificate chain and key; failures are
//     its ERR_SSL_* codes) in alpnFallback = NoAck mode with the server's own
//     ALPN list (httpServerAlpn; the user's alpn is not passed down), and,
//     with http2, the RFC 9113 TLS 1.2 cipher restriction. The listener then
//     wraps every accepted connection in a TlsTransport and installs its
//     protocol after the handshake (Http1.cpp makeServerProtocol: ALPN
//     dispatch); requests carry flags bit 2 and https:// URLs. With http2
//     (WS8, §3.8) the server also offers "h2": such connections run
//     Http2Protocol (Http2.cpp, nghttp2), with maxConcurrentStreams.
//   * respond (R mode): copies the response out of the heap (G3), registers
//     the resume, takes one count, and hands the POD to HttpTables, which
//     erases the key (releasing the request's count) and submits it to the
//     reactor; the task completes when the transport took the bytes
//     (RespondDone). An unknown, answered or dead key completes at once:
//     respond is a Task Never.
//   * closeServer (R mode): HttpTables closes the listener and starts the
//     graceful close on the reactor; the task completes on ServerClosed. An
//     unknown or fully closed server completes at once.
//   * takeUpgrade (S mode): HttpUpgrade.cpp (phase WS5).
//
// Templates used: T2, T4 (copy-out), G3, G10.
//
//===----------------------------------------------------------------------===//

#include "eco-system/HttpServer/HttpServer.hpp"

#include "eco-system/Core/SysWorkPool.hpp"
#include "eco-system/HttpServer/Http1.hpp"
#include "eco-system/HttpServer/HttpServerService.hpp"
#include "eco-system/HttpServer/HttpTables.hpp"
#include "eco-system/Socket/Socket.hpp"
#include "eco-system/Tls/TlsContext.hpp"
#include "eco-system/Tls/TlsTransport.hpp"

#include <string>
#include <utility>
#include <vector>

#ifndef _WIN32
#include <unistd.h>
#endif

namespace Eco::System {

namespace {

using HttpSrv::ResponseData;
using HttpSrv::ServerConfig;

// Owns the listening fd until the completion takes it (a killed task's
// orphaned result closes it, N11).
struct CreateRes {
    HttpSrv::ListenResult listen;
    std::string host;

    CreateRes() = default;
    CreateRes(CreateRes&& o) noexcept : listen(std::move(o.listen)), host(std::move(o.host)) {
        o.listen.fd = -1;
    }
    CreateRes& operator=(CreateRes&&) = delete;
    CreateRes(const CreateRes&) = delete;
    ~CreateRes() {
#ifndef _WIN32
        if (listen.fd >= 0) (void)::close(listen.fd);
#endif
    }
};

// The authority of request URLs without a Host header (E.5): IPv6 literals
// bracketed, an empty host is "localhost".
std::string authorityOf(const std::string& host, int64_t port) {
    std::string h = host.empty() ? std::string("localhost") : host;
    if (h.find(':') != std::string::npos && h.front() != '[') h = "[" + h + "]";
    return h + ":" + std::to_string(port);
}

HPointer serverResult(int64_t id, int64_t port) {
    return succeed(alloc::tuple2(alloc::unboxedInt(id), alloc::unboxedInt(port), 0x5));
}

// Main thread (the pool drain), resume already taken and rooted.
HPointer createComplete(PoolResult& pr) {
    auto& r = pr.as<CreateRes>();
    if (r.listen.fd < 0) return failFErr(r.listen.code, r.listen.message);
    auto cfg = std::make_shared<ServerConfig>();
    cfg->fallbackAuthority = authorityOf(r.host, r.listen.boundPort);
    int fd = r.listen.fd;
    r.listen.fd = -1;   // owned by the listener from here on
    int64_t id = HttpSrv::httpTablesStartServer(fd, cfg, -1);
    return serverResult(id, r.listen.boundPort);
}

// The ALPN protocols an https server offers (§3.5): its own list, never the
// user's Socket.Tls.ServerOptions.alpn: ["h2", "http/1.1"] with http2 (WS8,
// Http2Protocol), else ["http/1.1"]. A client offering neither still
// connects without ALPN (NoAck) and is served HTTP/1.1.
[[maybe_unused]] std::vector<std::string> httpServerAlpn(bool http2) {
    if (http2) return {"h2", "http/1.1"};
    return {"http/1.1"};
}

// createServerWith's options, copied out of the heap.
struct WithSpec {
    std::string address;
    int64_t port = 0;
    int64_t maxConnections = -1;
    std::string certificateChain, privateKey;   // cfg.tls
    ServerConfig cfg;
};

struct WithRes {
    ListenResult listen;   // Socket.hpp: RAII ListenFd
    WithSpec spec;
    std::shared_ptr<TlsServerConfig> tls;   // cfg.tls: the context (null on failure)
    std::string code, message;              // context failure (code non-empty)
};

HPointer createWithComplete(PoolResult& pr) {
    auto& r = pr.as<WithRes>();
    if (!r.code.empty()) return failFErr(r.code, r.message);
    if (!r.listen.code.empty()) return failFErr(r.listen.code, r.listen.message);
    auto cfg = std::make_shared<ServerConfig>(r.spec.cfg);
    cfg->fallbackAuthority = authorityOf(r.listen.bound.text, r.listen.bound.port);
    TransportFactory transport = r.tls ? makeTlsServerFactory(r.tls) : nullptr;
    int fd = r.listen.owned.fd;
    r.listen.owned.fd = -1;   // owned by the listener from here on
    int64_t id = HttpSrv::httpTablesStartServer(fd, cfg, r.spec.maxConnections, std::move(transport));
    return serverResult(id, r.listen.bound.port);
}

// Resumes `resume` with () now (an R-mode task that needs no reactor work).
void completeNow(HPointer& resume, uint64_t& token, bool& counted) {
    auto& s = Scheduler::instance();
    (void)s.takePendingResume(token);
    s.decrementPendingAsync();
    token = 0;
    counted = false;
    HPointer task = succeedUnit();
    Elm::StackRootGuard g(&task);
    Scheduler::callClosure1(resume, task);
}

} // namespace

HPointer httpServerCreateServerBody(HPointer captured, HPointer resume) {
    uint64_t token = 0;
    bool counted = false;
    ECO_SYSTEM_ASYNC_GUARD(FErr, resume, token, counted,
        std::string host;
        int64_t port = 0;
        {   // G3: read first; no allocation in this scope
            Tuple2* t = asTuple2(captured);
            host = toStdString(t->a.p);
            port = t->b.i;
        }
        HttpSrv::ensureHttpTables();   // bind the Scheduler on the main thread
        auto& s = Scheduler::instance();
        token = s.registerPendingResume(resume);   // G10
        s.incrementPendingAsync();
        counted = true;
        SysWorkPool::instance().submit(
            token,
            [host = std::move(host), port]() -> PoolResult {   // worker: POD only (G1)
                CreateRes r;
                r.listen = HttpSrv::listenOn(host, port);
                r.host = host;
                return PoolResult::of(std::move(r));
            },
            &createComplete, ErrShape::FErr);
        return alloc::unit();   // kill handle: unit (the job is short)
    )
}

HPointer httpServerCreateServerWithBody(HPointer captured, HPointer resume) {
    uint64_t token = 0;
    bool counted = false;
    ECO_SYSTEM_ASYNC_GUARD(FErr, resume, token, counted,
        WithSpec spec;
        bool http2 = false;
        bool hasTls = false;
        {   // G3: read first; no allocation in this scope
            Tuple3* t = asTuple3(captured);
            HPointer targetHP = t->a.p;
            HPointer tlsHP = t->b.p;
            HPointer limitsHP = t->c.p;
            Tuple2* target = asTuple2(targetHP);
            Tuple2* ap = asTuple2(target->a.p);
            Tuple2* hm = asTuple2(target->b.p);
            spec.address = toStdString(ap->a.p);
            spec.port = ap->b.i;
            http2 = ::Elm::hpBits(hm->a.p) == ::Elm::hpBits(alloc::elmTrue());   // Bool: a constant
            spec.maxConnections = hm->b.i;
            hasTls = !alloc::isConstant(tlsHP);   // Nothing is an embedded constant
            if (hasTls) {
                // Just ( certificateChain, privateKey ): ctor 0, one boxed value.
                auto* just = static_cast<Custom*>(Allocator::instance().resolve(tlsHP));
                Tuple2* pair = asTuple2(just->values[0].p);
                spec.certificateChain = toStdString(pair->a.p);
                spec.privateKey = toStdString(pair->b.p);
            }
            Tuple2* limits = asTuple2(limitsHP);
            Tuple3* times = asTuple3(limits->a.p);
            Tuple3* sizes = asTuple3(limits->b.p);
            spec.cfg.keepAliveMs = times->a.i;
            spec.cfg.headersMs = times->b.i;
            spec.cfg.requestMs = times->c.i;
            spec.cfg.maxBodySize = sizes->a.i;
            spec.cfg.maxHeaderSize = sizes->b.i;
            spec.cfg.maxConcurrentStreams = sizes->c.i;   // HTTP/2 (WS8); -1 unlimited
        }
        spec.cfg.tls = hasTls;
        spec.cfg.http2 = http2;
        HttpSrv::ensureHttpTables();
#ifdef _WIN32
        if (hasTls) {   // no OpenSSL on Windows (§1)
            HPointer task = failFErr("ENOTSUP", "createServerWith: tls is not supported on Windows yet");
            Elm::StackRootGuard g(&task);
            Scheduler::callClosure1(resume, task);
            return alloc::unit();
        }
#endif
        if (http2 && !hasTls) {
            HPointer task = failFErr("EINVAL", "createServerWith: http2 requires tls");
            Elm::StackRootGuard g(&task);
            Scheduler::callClosure1(resume, task);
            return alloc::unit();
        }
        if (hasTls) ensureTlsInit();   // main thread, before any OpenSSL use (N13)
        auto& s = Scheduler::instance();
        token = s.registerPendingResume(resume);   // G10
        s.incrementPendingAsync();
        counted = true;
        SysWorkPool::instance().submit(
            token,
            [spec = std::move(spec)]() -> PoolResult {   // worker: POD only (G1)
                WithRes r;
#ifndef _WIN32
                if (spec.cfg.tls) {   // the context first, as Socket.Tls.listen (PEM work)
                    TlsError err;
                    TlsServerMode mode;
                    mode.alpnNoAck = true;            // §3.5 alpnFallback = NoAck
                    mode.h2Ciphers = spec.cfg.http2;  // RFC 9113 §9.2.2
                    r.tls = buildTlsServerConfig(spec.certificateChain, spec.privateKey,
                                                 httpServerAlpn(spec.cfg.http2), err, mode);
                    if (!r.tls) {
                        r.code = err.code.empty() ? "ERR_SSL_UNKNOWN" : err.code;
                        r.message = err.message;
                        return PoolResult::of(std::move(r));
                    }
                }
#endif
                r.listen = tcpListenOn(spec.address, spec.port, 511, /*ipv6Only=*/false);
                r.spec = spec;
                r.spec.certificateChain.clear();   // not kept beyond the context
                r.spec.privateKey.clear();
                return PoolResult::of(std::move(r));
            },
            &createWithComplete, ErrShape::FErr);
        return alloc::unit();
    )
}

HPointer httpServerRespondBody(HPointer captured, HPointer resume) {
    uint64_t token = 0;
    bool counted = false;
    ECO_SYSTEM_ASYNC_GUARD(Never, resume, token, counted,
        int64_t key = 0;
        ResponseData data;
        {   // G3: copy everything out; no allocation in this scope (G5)
            Tuple2* outer = asTuple2(captured);
            HPointer ksHP = outer->a.p;
            HPointer hbHP = outer->b.p;
            Tuple2* ks = asTuple2(ksHP);
            key = ks->a.i;
            data.status = ks->b.i;
            Tuple2* hb = asTuple2(hbHP);
            HPointer headers = hb->a.p;
            HPointer body = hb->b.p;
            for (alloc::ListCursor c(headers); !c.done(); c.next()) {
                Tuple2* h = asTuple2(c.current().p);
                std::string name = toStdString(h->a.p);
                for (alloc::ListCursor v(h->b.p); !v.done(); v.next())
                    data.headers.emplace_back(name, toStdString(v.current().p));
            }
            data.body = toStdBytes(body);
        }
        HttpSrv::ensureHttpTables();
        auto& s = Scheduler::instance();
        token = s.registerPendingResume(resume);   // G10
        s.incrementPendingAsync();
        counted = true;
        if (!HttpSrv::httpTablesRespond(key, token, std::move(data))) {
            completeNow(resume, token, counted);   // unknown, answered or gone: at once
        }
        return alloc::unit();
    )
}

HPointer httpServerCloseServerBody(HPointer captured, HPointer resume) {
    uint64_t token = 0;
    bool counted = false;
    ECO_SYSTEM_ASYNC_GUARD(Never, resume, token, counted,
        int64_t id = 0, deadlineMs = 0;
        {
            Tuple2* t = asTuple2(captured);
            id = t->a.i;
            deadlineMs = t->b.i;
        }
        HttpSrv::ensureHttpTables();
        auto& s = Scheduler::instance();
        token = s.registerPendingResume(resume);   // G10
        s.incrementPendingAsync();
        counted = true;
        if (!HttpSrv::httpTablesCloseServer(id, deadlineMs, token)) {
            completeNow(resume, token, counted);   // unknown or closed: at once
        }
        return alloc::unit();
    )
}

HPointer httpServerNotImplementedBody(HPointer /*captured*/) {
    ECO_SYSTEM_BODY_GUARD(FErr,
        return failFErr("ENOTSUP", "not implemented yet");
    )
}

} // namespace Eco::System
