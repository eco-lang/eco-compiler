//===- HttpUpgrade.cpp - Http.Server.upgradeRequest (HTTP/1.1) ------------===//
//
// plans/eco-system-websockets.md §3.4 "Upgrade and CONNECT", §3.6 "Handshake
// execution", Appendix B.2 `takeUpgrade` (phase WS5): the binding body of
// Eco.Kernel.HttpServer.takeUpgrade.
//
//   takeUpgrade key (S mode, Task FErr): hands a delivered HTTP/1.1 upgrade
//   request over to WebSocket. On the main thread httpTablesTakeUpgrade
//   consumes the key (its keep-alive count is released; a later
//   Response.send on it completes at once and writes nothing) and returns
//   the kept raw request; the connection becomes a WebSocket handshake id
//   (wsTablesAddServerHandshake: the id space of readUpgrade / dial), so
//   WebSocket.accept / reject / abandon (open / reject / abandon kernels)
//   work on it unchanged. A reactor command (submitted before any `open`,
//   so it runs first) ends HTTP/1.1 on the connection
//   (Http1Protocol::takeUpgradeHead: the bytes read past the request, e.g. a
//   frame the client sent right behind it) and parks it in a HoldProtocol
//   with those bytes. Nothing more is parsed as HTTP, and the 101 that
//   `open` writes follows every earlier pipelined response (one request in
//   flight: they were all queued before this request was delivered). A
//   connection that closed meanwhile stays an Http1Protocol (or is gone);
//   `open` then fails ECONNRESET "socket closed".
//   Result: ( hsId, ( method, target, version ), ( headers, isH2 = False,
//   remote ) ), the shape of WebSocket.readUpgrade (masks 0x1 / 0 / 0).
//   Errors: EINVAL (unknown key: answered, already taken, not an upgrade
//   request, or its connection closed), ECANCELED (the connection is gone).
//
// The upgraded connection stays registered with its server only for the
// heap-reset sweep; closeServer skips it (it is no Http1Protocol any more),
// so WebSockets outlive their server (Node's behaviour, §3.4).
//
// HTTP/2 (WS9, §3.9): an extended CONNECT stream (:protocol websocket,
// delivered on its HEADERS by Http2Protocol) stays with its connection; the
// handshake id holds an H2Upgrade (below), through which `open` answers 200
// without END_STREAM and binds the stream to the codec (an H2StreamPort
// over a ServerTunnel: DATA writes with backpressure, received bytes
// consumed into the stream window when the codec takes them, END_STREAM as
// the orderly close, RST_STREAM(CANCEL) as the abort), `reject` answers it
// like any request, and `abandon` resets it (CANCEL). Result: ( hsId,
// ( "CONNECT", path, "2" ), ( header fields, isH2 = True, remote ) ).
//
// Windows: fails ENOTSUP (no HTTP/1.1 protocol there, §1).
//
// Templates used: T1 (S body), G3 (copy-out), G10 (the key's count, via
// HttpTables).
//
//===----------------------------------------------------------------------===//

#include "eco-system/HttpServer/HttpServer.hpp"

#include "eco-system/Core/IoReactor.hpp"
#include "eco-system/HttpServer/Http1.hpp"
#include "eco-system/HttpServer/Http2.hpp"
#include "eco-system/HttpServer/HttpTables.hpp"
#include "eco-system/Socket/SocketTables.hpp"
#include "eco-system/WebSocket/H2StreamPort.hpp"
#include "eco-system/WebSocket/WsHandshake.hpp"
#include "eco-system/WebSocket/WsTables.hpp"

#include <memory>
#include <string>
#include <utility>

namespace Eco::System {

#ifndef _WIN32

namespace {

// The h2 connection's protocol, if `conn` is still alive and HTTP/2.
HttpSrv::Http2Protocol* h2Of(const std::weak_ptr<Conn>& weak, std::shared_ptr<Conn>& c) {
    c = weak.lock();
    if (!c || c->phase() != Conn::Phase::Open || c->aborted()) return nullptr;
    return dynamic_cast<HttpSrv::Http2Protocol*>(c->protocol());
}

// A bound tunnel: Http2Protocol's events go to the port, the port's writes to
// the stream. Owned by the stream (Http2Protocol destroys it later than its
// last event, Http2.cpp retireTunnel). Reactor thread.
class ServerTunnel final : public HttpSrv::H2StreamHandler, public H2Tunnel {
public:
    ServerTunnel(std::weak_ptr<Conn> conn, std::shared_ptr<H2StreamPort> port)
        : conn_(std::move(conn)), port_(std::move(port)) {}
    ~ServerTunnel() override { port_->streamReset(H2StreamPort::kCancel); }

    int32_t sid = 0;

    // H2StreamHandler.
    void onData(std::string_view bytes) override { port_->streamData(bytes); }
    void onEnd() override { port_->streamEnd(); }
    void onReset(uint32_t code) override { port_->streamReset(code); }
    void onWritable() override { port_->streamWritable(); }

    // H2Tunnel.
    bool tunnelWrite(std::string bytes) override {
        std::shared_ptr<Conn> c;
        auto* p = h2Of(conn_, c);
        return p && p->tunnelWrite(*c, sid, std::move(bytes));
    }
    size_t tunnelQueued() const override {
        std::shared_ptr<Conn> c;
        auto* p = h2Of(conn_, c);
        return p ? p->tunnelQueued(sid) : 0;
    }
    void tunnelConsume(size_t n) override {
        std::shared_ptr<Conn> c;
        if (auto* p = h2Of(conn_, c)) p->tunnelConsume(*c, sid, n);
    }
    void tunnelEnd() override {
        std::shared_ptr<Conn> c;
        if (auto* p = h2Of(conn_, c)) p->tunnelEnd(*c, sid);
    }
    void tunnelReset(uint32_t code) override {
        std::shared_ptr<Conn> c;
        if (auto* p = h2Of(conn_, c)) p->tunnelReset(*c, sid, code);
    }

private:
    std::weak_ptr<Conn> conn_;
    std::shared_ptr<H2StreamPort> port_;
};

// A taken extended CONNECT (the handshake id's H2PendingUpgrade).
class H2Upgrade final : public H2PendingUpgrade {
public:
    H2Upgrade(std::weak_ptr<Conn> conn, int64_t key) : conn_(std::move(conn)), key_(key) {}

    bool describe(SockEndpoint& local, SockEndpoint& remote) override {
        std::shared_ptr<Conn> c;
        auto* p = h2Of(conn_, c);
        if (!p || !p->tunnelPending(key_)) return false;
        SocketEvent se;
        c->describe(se, std::string());
        local = se.local;
        remote = se.remote;
        return true;
    }

    bool accept(int status, const HeaderList& headers, const std::shared_ptr<H2StreamPort>& port) override {
        std::shared_ptr<Conn> c;
        auto* p = h2Of(conn_, c);
        if (!p || !p->tunnelPending(key_)) return false;
        HttpSrv::ResponseData head;
        head.status = status;
        head.headers = headers;
        auto t = std::make_unique<ServerTunnel>(conn_, port);
        ServerTunnel* tunnel = t.get();   // alive until a later reactor turn (retireTunnel)
        std::string buffered;
        int32_t sid = p->bindTunnel(*c, key_, std::move(head), std::move(t), buffered);
        if (sid == 0) return false;
        tunnel->sid = sid;
        port->bind(tunnel, std::move(buffered));
        return true;
    }

    void reject(int status, const HeaderList& headers, std::string body, std::function<void(int)> done) override {
        std::shared_ptr<Conn> c;
        auto* p = h2Of(conn_, c);
        HttpSrv::ResponseData r;
        r.status = status;
        r.headers = headers;
        r.body = std::move(body);
        if (!p || !p->respond(*c, key_, std::move(r), false, done)) {
            if (done) done(0);   // the stream is gone: nothing to answer
        }
    }

    void abandon() override {
        std::shared_ptr<Conn> c;
        if (auto* p = h2Of(conn_, c)) p->tunnelCancel(*c, key_);
    }

private:
    std::weak_ptr<Conn> conn_;
    int64_t key_;
};

// ( hsId, ( method, target, version ), ( headers, isH2, remote ) ), masks 0x1 / 0 / 0. Fresh.
HPointer upgradeResult(int64_t hsId, const HttpSrv::RequestData& req, const char* version, bool isH2) {
    HPointer task = alloc::listNil(), line = alloc::listNil(), rest = alloc::listNil();
    HPointer a = alloc::listNil(), b = alloc::listNil(), v = alloc::listNil();
    Elm::StackRootGuard g({&task, &line, &rest, &a, &b, &v});
    a = alloc::allocStringFromUTF8(req.method);
    b = alloc::allocStringFromUTF8(req.target);
    v = alloc::allocStringFromUTF8(version);
    line = alloc::tuple3(alloc::boxed(a), alloc::boxed(b), alloc::boxed(v), 0);
    a = buildHeaderList(req.headers);
    b = buildEndpoint(req.remote);
    rest = alloc::tuple3(alloc::boxed(a), alloc::boxed(isH2 ? alloc::elmTrue() : alloc::elmFalse()),
                         alloc::boxed(b), 0);
    task = alloc::tuple3(alloc::unboxedInt(hsId), alloc::boxed(line), alloc::boxed(rest), 0x1);
    return succeed(task);
}

} // namespace

#endif // !_WIN32

HPointer httpServerTakeUpgradeBody(HPointer captured) {
    ECO_SYSTEM_BODY_GUARD(FErr,
#ifdef _WIN32
        (void)captured;
        return failFErr("ENOTSUP", "eco/system: Http.Server is not supported on Windows yet");
#else
        int64_t key = static_cast<ElmInt*>(Allocator::instance().resolve(captured))->value;
        HttpSrv::ensureHttpTables();
        HttpSrv::RequestData req;
        std::weak_ptr<Conn> weak;
        if (!HttpSrv::httpTablesTakeUpgrade(key, req, weak)) {
            return failFErr("EINVAL",
                            "upgradeRequest EINVAL: the request was answered already or is not an upgrade request");
        }
        std::shared_ptr<Conn> c = weak.lock();
        if (!c) return failFErr("ECANCELED", "socket closed");
        ensureWsTables();
        if ((req.flags & 3) == 2) {
            // WS9: an HTTP/2 extended CONNECT; the stream stays with its connection.
            int64_t hsId = wsTablesAddServerH2Handshake(std::make_shared<H2Upgrade>(weak, key));
            return upgradeResult(hsId, req, "2", true);
        }
        int64_t hsId = wsTablesAddServerHandshake(c);
        IoReactor::instance().submit([c, key] {
            auto* p = dynamic_cast<HttpSrv::Http1Protocol*>(c->protocol());
            if (!p || !p->upgradePending(key)) return;   // closed meanwhile: open fails
            std::string head = p->takeUpgradeHead(*c, key);
            c->setProtocol(std::make_unique<HoldProtocol>(), std::move(head));   // retires p
        });
        // ( hsId, ( method, target, version ), ( headers, False, remote ) ).
        return upgradeResult(hsId, req, (req.flags & 3) == 0 ? "1.0" : "1.1", false);
#endif
    )
}

} // namespace Eco::System
