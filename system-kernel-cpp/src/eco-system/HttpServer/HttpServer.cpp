//===- HttpServer.cpp - eco/system kernel module HttpServer ---------------===//
//
// plans/eco-system-library.md Appendix B.6 and Phase 7 step 7.2: the binding
// bodies of Eco.Kernel.HttpServer.
//
//   * createServer (P mode, T2): the pool worker resolves the host and
//     opens the listening socket (HttpSrv::listenOn: socket, SO_REUSEADDR,
//     bind, listen). The main-thread completion starts the accept thread,
//     registers the module drain and takes ONE pendingAsync count that is
//     never released: a listening server keeps the program alive (§3.4,
//     Node semantics; there is no close in the v1 API). A failure is the
//     FErr tuple ( code, message ), e.g. ( "EADDRINUSE", "listen
//     EADDRINUSE: ..." ), which Elm turns into ServerError.
//   * respond (C mode): copies the response out of the heap (G3), registers
//     the resume, takes one pendingAsync count and hands the POD to the
//     connection thread waiting under the key. The task completes (from the
//     drain, HttpServerManager.cpp) once that thread has written the
//     response and closed the connection. An unknown or already answered
//     key completes at once: respond is a Task Never.
//
// Templates used: T2, T4 (copy-out), G3, G10.
//
//===----------------------------------------------------------------------===//

#include "eco-system/HttpServer/HttpServer.hpp"

#include "eco-system/Core/SysWorkPool.hpp"
#include "eco-system/HttpServer/HttpServerManager.hpp"
#include "eco-system/HttpServer/HttpServerService.hpp"

#include <string>
#include <utility>

namespace Eco::System {

namespace {

using HttpSrv::HttpServerService;
using HttpSrv::ListenResult;
using HttpSrv::ResponseData;

struct CreateRes {
    ListenResult listen;
    std::string host;
    int64_t port = 0;
};

// Main thread (the pool drain), resume already taken and rooted.
HPointer createComplete(PoolResult& pr) {
    auto& r = pr.as<CreateRes>();
    if (r.listen.fd < 0) return failFErr(r.listen.code, r.listen.message);
    int64_t id = HttpServerService::instance().startServer(r.listen.fd, r.host, r.port);
    ensureHttpServerDrain();
    // A listening server holds one pendingAsync forever (§3.4 keep-alive).
    Scheduler::instance().incrementPendingAsync();
    return succeedInt(id);
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
        HttpServerService::instance();   // bind the Scheduler on the main thread
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
                r.port = port;
                return PoolResult::of(std::move(r));
            },
            &createComplete, ErrShape::FErr);
        return alloc::unit();   // kill handle: unit (the job is short)
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
        auto& s = Scheduler::instance();
        token = s.registerPendingResume(resume);   // G10
        s.incrementPendingAsync();
        counted = true;
        if (!HttpServerService::instance().respond(key, token, std::move(data))) {
            // Unknown or already answered key: complete now.
            (void)s.takePendingResume(token);
            s.decrementPendingAsync();
            token = 0;
            counted = false;
            HPointer task = succeedUnit();
            Elm::StackRootGuard g(&task);
            Scheduler::callClosure1(resume, task);
        }
        return alloc::unit();
    )
}

} // namespace Eco::System
