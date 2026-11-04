//===- HttpServer.cpp - eco/system kernel module HttpServer ---------------===//
//
// Each body that reads its payload does so in a block scope, through raw pointers, copying what it needs into C++
// values. Nothing in that scope allocates on the heap, so the pointers stay valid; only after the scope does the
// body allocate, park its resume closure or call out.
//
// An asynchronous body parks its resume under a token with `Scheduler::parkResume`, which also takes the hold that
// keeps the program running until the task completes. `token` and `counted` record that for
// `ECO_SYSTEM_ASYNC_GUARD`, so that in the FErr bodies an exception afterwards fails the task and releases the hold;
// in the `Never` bodies an exception is fatal. When nothing is left to wait for, `completeNow` resumes the task and
// releases the hold itself. The bodies return `()` as the kill handle, so killing a task cancels nothing.
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
#include "virtual-dom/HtmlWriter.hpp"

#include <cstring>
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

// The result of `createServer`'s pool job. It owns the listening fd in `listen.fd` until `createComplete` takes it
// by setting it to -1, and, except on Windows, closes the fd when destroyed still holding it, as when the result is
// dropped without completing. A move hands the fd over. `host` is the requested host name.
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

// Returns `host:port` as the URL authority used for requests that carry no Host header. A host containing ':'
// that is not already bracketed is bracketed as an IPv6 literal, and an empty host becomes "localhost".
std::string authorityOf(const std::string& host, int64_t port) {
    std::string h = host.empty() ? std::string("localhost") : host;
    if (h.find(':') != std::string::npos && h.front() != '[') h = "[" + h + "]";
    return h + ":" + std::to_string(port);
}

// Returns a Task that succeeds with `( id, address, port )`. The mask 0x11 marks slots 0 and 2 as unboxed Ints,
// at two bits per slot.
HPointer serverResult(int64_t id, const std::string& address, int64_t port) {
    HPointer text = alloc::allocStringFromUTF8(address);
    // `text` goes straight into `tuple3`, which roots its boxed arguments across its allocation.
    return succeed(alloc::tuple3(alloc::unboxedInt(id), alloc::boxed(text), alloc::unboxedInt(port), 0x11));
}

// Returns the Node-style message of the failed listen `r`: its `message`, or, for an errno failure,
// "syscall CODE: text where" with the C library's strerror as the text. Eco thread only: strerror is not
// synchronised, which is why the worker that ran `listenOn` leaves it to this function.
std::string listenFailureMessage(const HttpSrv::ListenResult& r) {
    if (r.sysErr == 0) return r.message;
    const char* m = std::strerror(r.sysErr);
    return r.syscall + " " + r.code + ": " + (m ? m : "") + " " + r.where;
}

// Builds `createServer`'s Task from its job's result on the eco thread: the FErr from listening, or the new
// server's result after the fd is handed to `httpTablesStartServer`.
HPointer createComplete(PoolResult& pr) {
    auto& r = pr.as<CreateRes>();
    if (r.listen.fd < 0) return failFErr(r.listen.code, listenFailureMessage(r.listen));
    auto cfg = std::make_shared<ServerConfig>();
    cfg->fallbackAuthority = authorityOf(r.host, r.listen.boundPort);
    int fd = r.listen.fd;
    r.listen.fd = -1;   // owned by the listener from here on
    int64_t id = HttpSrv::httpTablesStartServer(fd, cfg, -1);
    std::string address = r.listen.boundAddress;
    return serverResult(id, address, r.listen.boundPort);
}

// Returns the ALPN protocols a TLS server offers, in order of preference: "h2" when `http2`, then "http/1.1" when
// `http1`. It is unused on Windows, where no TLS server is built.
[[maybe_unused]] std::vector<std::string> httpServerAlpn(bool http1, bool http2) {
    std::vector<std::string> alpn;
    if (http2) alpn.push_back("h2");
    if (http1) alpn.push_back("http/1.1");
    return alpn;
}

// The options of `createServerWith`, copied out of the heap. `maxConnections` is negative for no limit, and the
// certificate chain and private key are empty without TLS.
struct WithSpec {
    std::string address;
    int64_t port = 0;
    int64_t maxConnections = -1;
    std::string certificateChain, privateKey;   // cfg.tls
    ServerConfig cfg;
};

// The result of `createServerWith`'s pool job. `listen.owned` closes the fd unless `createWithComplete` takes it.
// `spec` has its certificate chain and private key cleared.
struct WithRes {
    ListenResult listen;
    WithSpec spec;
    std::shared_ptr<TlsServerConfig> tls;   // null without TLS, or when building the context failed
    std::string code, message;              // the TLS context failure when `code` is not empty
};

// Builds `createServerWith`'s Task from its job's result on the eco thread: the TLS failure, the listen failure,
// or the new server's result after the fd is handed to `httpTablesStartServer`.
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
    std::string address = r.listen.bound.text;
    return serverResult(id, address, r.listen.bound.port);
}

// Completes the task parked under `token` with `()` now: discards the parked closure, calls `resume`, and then
// releases the hold and clears `token` and `counted`. The hold is released only after the resume has run, so the
// program cannot be judged finished in between.
void completeNow(HPointer& resume, uint64_t& token, bool& counted) {
    auto& s = Scheduler::instance();
    (void)s.takePendingResume(token);
    HPointer task = succeedUnit();
    Elm::StackRootGuard g(&task);
    Scheduler::callClosure1(resume, task);
    s.releaseHold(token);
    token = 0;
    counted = false;
}

// Appends to `data.headers` one `( name, value )` line for each value of each `( name, values )` pair in the list
// `headers`. It does not allocate on the heap, so it may run inside a body's copy-out scope.
void copyHeaders(HPointer headers, ResponseData& data) {
    for (alloc::ListCursor c(headers); !c.done(); c.next()) {
        Tuple2* h = asTuple2(c.current().p);
        std::string name = toStdString(h->a.p);
        for (alloc::ListCursor v(h->b.p); !v.done(); v.next())
            data.headers.emplace_back(name, toStdString(v.current().p));
    }
}

// Parks `resume` with its hold, recording that in `token` and `counted`, and asks `httpTablesRespond` to send
// `data` for `key`, completing the task at once when the key is not in the table. Returns `()` as the kill handle.
HPointer submitResponse(int64_t key, ResponseData data, HPointer resume, uint64_t& token,
                        bool& counted);

} // namespace

HPointer httpServerCreateServerBody(HPointer captured, HPointer resume) {
    uint64_t token = 0;
    bool counted = false;
    ECO_SYSTEM_ASYNC_GUARD(FErr, resume, token, counted,
        std::string host;
        int64_t port = 0;
        {   // no heap allocation in this scope
            Tuple2* t = asTuple2(captured);
            host = toStdString(t->a.p);
            port = t->b.i;
        }
        HttpSrv::ensureHttpTables();
        auto& s = Scheduler::instance();
        token = s.parkResume(resume, HoldKind::Task, "Http.Server.createServer");
        counted = true;
        SysWorkPool::instance().submit(
            token,
            [host = std::move(host), port]() -> PoolResult {   // runs on a worker: no heap access
                CreateRes r;
                r.listen = HttpSrv::listenOn(host, port);
                r.host = host;
                return PoolResult::of(std::move(r));
            },
            &createComplete, ErrShape::FErr);
        return alloc::unit();
    )
}

HPointer httpServerCreateServerWithBody(HPointer captured, HPointer resume) {
    uint64_t token = 0;
    bool counted = false;
    ECO_SYSTEM_ASYNC_GUARD(FErr, resume, token, counted,
        WithSpec spec;
        int64_t protocols = 0;
        bool hasTls = false;
        {   // no heap allocation in this scope
            Tuple3* t = asTuple3(captured);
            HPointer targetHP = t->a.p;
            HPointer tlsHP = t->b.p;
            HPointer limitsHP = t->c.p;
            Tuple2* target = asTuple2(targetHP);
            Tuple2* ap = asTuple2(target->a.p);
            Tuple2* hm = asTuple2(target->b.p);
            spec.address = toStdString(ap->a.p);
            spec.port = ap->b.i;
            protocols = hm->a.i;   // bit 0 HTTP/1.x, bit 1 HTTP/2
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
            spec.cfg.maxConcurrentStreams = sizes->c.i;   // HTTP/2 only
        }
        spec.cfg.tls = hasTls;
        spec.cfg.http1 = (protocols & 1) != 0;
        spec.cfg.http2 = (protocols & 2) != 0;
        HttpSrv::ensureHttpTables();
#ifdef _WIN32
        if (hasTls) {   // no OpenSSL on Windows
            HPointer task = failFErr("ENOTSUP", "createServerWith: tls is not supported on Windows yet");
            Elm::StackRootGuard g(&task);
            Scheduler::callClosure1(resume, task);
            return alloc::unit();
        }
#endif
        if (!spec.cfg.http1 && !spec.cfg.http2) {
            HPointer task = failFErr("EINVAL", "listen: no protocols");
            Elm::StackRootGuard g(&task);
            Scheduler::callClosure1(resume, task);
            return alloc::unit();
        }
        if (spec.cfg.http2 && !hasTls) {
            HPointer task = failFErr("EINVAL", "listen: http2 requires tls");
            Elm::StackRootGuard g(&task);
            Scheduler::callClosure1(resume, task);
            return alloc::unit();
        }
        if (hasTls) ensureTlsInit();   // on the eco thread, before the worker uses OpenSSL
        auto& s = Scheduler::instance();
        token = s.parkResume(resume, HoldKind::Task, "Http.Server.createServerWith");
        counted = true;
        SysWorkPool::instance().submit(
            token,
            [spec = std::move(spec)]() -> PoolResult {   // runs on a worker: no heap access
                WithRes r;
#ifndef _WIN32
                if (spec.cfg.tls) {   // the context first, so that a bad certificate opens no socket
                    TlsError err;
                    TlsServerMode mode;
                    mode.alpnNoAck = spec.cfg.http1;  // a client offering no ALPN match is served HTTP/1.1
                    mode.h2Ciphers = spec.cfg.http2;  // HTTP/2's TLS 1.2 cipher restriction (RFC 9113)
                    r.tls = buildTlsServerConfig(spec.certificateChain, spec.privateKey,
                                                 httpServerAlpn(spec.cfg.http1, spec.cfg.http2),
                                                 err, mode);
                    if (!r.tls) {
                        r.code = err.code.empty() ? "ERR_SSL_UNKNOWN" : err.code;
                        r.message = err.message;
                        return PoolResult::of(std::move(r));
                    }
                }
#endif
                r.listen = tcpListenOn(spec.address, spec.port, 511, /*ipv6Only=*/false);
                r.spec = spec;
                r.spec.certificateChain.clear();   // the result does not carry the key material
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
        {   // no heap allocation in this scope
            Tuple2* outer = asTuple2(captured);
            HPointer ksHP = outer->a.p;
            HPointer hbHP = outer->b.p;
            Tuple2* ks = asTuple2(ksHP);
            key = ks->a.i;
            data.status = ks->b.i;
            Tuple2* hb = asTuple2(hbHP);
            copyHeaders(hb->a.p, data);
            data.body = toStdBytes(hb->b.p);
        }
        return submitResponse(key, std::move(data), resume, token, counted);
    )
}

HPointer httpServerRespondHtmlBody(HPointer captured, HPointer resume) {
    uint64_t token = 0;
    bool counted = false;
    ECO_SYSTEM_ASYNC_GUARD(Never, resume, token, counted,
        int64_t key = 0;
        ResponseData data;
        {   // no heap allocation in this scope
            Tuple2* outer = asTuple2(captured);
            Tuple2* ks = asTuple2(outer->a.p);
            key = ks->a.i;
            data.status = ks->b.i;
            Tuple3* hdn = asTuple3(outer->b.p);
            copyHeaders(hdn->a.p, data);
            if (::Elm::hpBits(hdn->b.p) == ::Elm::hpBits(alloc::elmTrue()))   // Bool: a constant
                data.body = "<!DOCTYPE html>";
            // writeHtml neither allocates on the heap nor calls Elm, so `hdn` stays valid across the walk.
            ::Elm::Kernel::VirtualDom::writeHtml(enc(hdn->c.p), data.body);
        }
        return submitResponse(key, std::move(data), resume, token, counted);
    )
}

namespace {

HPointer submitResponse(int64_t key, ResponseData data, HPointer resume, uint64_t& token,
                        bool& counted) {
    HttpSrv::ensureHttpTables();
    auto& s = Scheduler::instance();
    token = s.parkResume(resume, HoldKind::Task, "Http.Server.respond");
    counted = true;
    if (!HttpSrv::httpTablesRespond(key, token, std::move(data))) {
        completeNow(resume, token, counted);
    }
    return alloc::unit();
}

} // namespace

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
        token = s.parkResume(resume, HoldKind::Task, "Http.Server.closeServer");
        counted = true;
        if (!HttpSrv::httpTablesCloseServer(id, deadlineMs, token)) {
            completeNow(resume, token, counted);
        }
        return alloc::unit();
    )
}

} // namespace Eco::System
