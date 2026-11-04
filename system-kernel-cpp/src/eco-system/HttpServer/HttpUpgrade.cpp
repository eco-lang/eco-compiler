//===- HttpUpgrade.cpp - Http.Server.upgradeRequest hand-over -------------===//
//
// A request delivered by Http.Server can ask to become a WebSocket, and this file is the body of the kernel that hands
// it over: `httpServerTakeUpgradeBody`, whose contract is on its declaration in HttpServer.hpp. The request leaves the
// HTTP tables and becomes a *server handshake* in the WebSocket tables, an id in the same id space as the handshakes
// made by `dial` and `readUpgrade`, so the WebSocket kernels that answer a handshake (open, reject, abandon) work on
// it as on any other. The request's delivery hold moves with it and becomes the handshake's peer hold, owned as
// `wsTablesAddServerHandshake` describes.
//
// The two HTTP versions are handed over differently, because an upgrade means different things in each.
//
// On HTTP/1.1 the upgrade takes the whole connection. A command submitted to the reactor ends HTTP/1.1 on it with
// `Http1Protocol::takeUpgradeHead` and installs a `HoldProtocol` in watch mode, given the bytes read past the request
// (a frame the client sent right behind it, say). Nothing more on the connection is parsed as HTTP. The command is
// submitted before this body returns, and reactor commands run in the order submitted, so it runs before any command
// a later `open` submits. If the connection closed or stopped waiting on the request before the command ran, the
// command posts a `HandshakeGone` event instead, and `open` then finds no `HoldProtocol` and fails with ECONNRESET
// "socket closed". Closing the server finishes only connections still running Http1Protocol or Http2Protocol, so an
// upgraded connection is left open.
//
// On HTTP/2 the upgrade is one extended CONNECT stream, which stays with its connection. The handshake holds an
// `H2Upgrade`, the `H2PendingUpgrade` through which the WebSocket kernels answer the stream, and a successful `open`
// binds the stream to the codec through a `ServerTunnel`.
//
// On Windows the body fails with ENOTSUP: Http.Server is not supported there.
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

// Locks `weak` into `c` and returns its Http2Protocol, or null when the connection is gone, not open, aborted or not
// HTTP/2. The pointer is valid while `c` holds the connection and the protocol is not replaced. Reactor thread.
HttpSrv::Http2Protocol* h2Of(const std::weak_ptr<Conn>& weak, std::shared_ptr<Conn>& c) {
    c = weak.lock();
    if (!c || c->phase() != Conn::Phase::Open || c->aborted()) return nullptr;
    return dynamic_cast<HttpSrv::Http2Protocol*>(c->protocol());
}

// The join between an accepted HTTP/2 WebSocket stream and its `H2StreamPort`: the stream's events are passed to the
// port, and the port's writes, consumption, end and reset are passed to the stream.
//
// The `Http2Protocol` that owns the stream owns the tunnel, as `HttpSrv::H2StreamHandler` describes. The tunnel keeps
// only a weak reference to the connection, so each call into the stream does nothing (or returns false or 0) once the
// connection is gone, not open, or aborted. Destroying it reports CANCEL to the port. Reactor thread.
class ServerTunnel final : public HttpSrv::H2StreamHandler, public H2Tunnel {
public:
    ServerTunnel(std::weak_ptr<Conn> conn, std::shared_ptr<H2StreamPort> port)
        : conn_(std::move(conn)), port_(std::move(port)) {}
    ~ServerTunnel() override { port_->streamReset(H2StreamPort::kCancel); }

    int32_t sid = 0;   ///< The stream id, set once `bindTunnel` has returned it; 0 until then.

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

// The `H2PendingUpgrade` for an extended CONNECT taken from the HTTP tables: the connection, weakly, and the
// stream's response key. Every function treats a connection that is gone, not open, aborted or no longer HTTP/2 as a
// gone stream.
class H2Upgrade final : public H2PendingUpgrade {
public:
    // Creates the upgrade for the stream answered by response key `key` on `conn`.
    H2Upgrade(std::weak_ptr<Conn> conn, int64_t key) : conn_(std::move(conn)), key_(key) {}

    // Also returns false once the key is no longer a pending tunnel (`Http2Protocol::tunnelPending`).
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

    // Also returns false once the key is no longer a pending tunnel. On success the stream's bytes received so far
    // are handed to `port` with the binding.
    bool accept(int status, const HeaderList& headers, const std::shared_ptr<H2StreamPort>& port) override {
        std::shared_ptr<Conn> c;
        auto* p = h2Of(conn_, c);
        if (!p || !p->tunnelPending(key_)) return false;
        HttpSrv::ResponseData head;
        head.status = status;
        head.headers = headers;
        auto t = std::make_unique<ServerTunnel>(conn_, port);
        // Owned by the stream from here; destroyed by a later reactor command, or with the protocol if still bound.
        ServerTunnel* tunnel = t.get();
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

// Returns a Task that succeeds with `( hsId, ( method, target, version ), ( headers, isH2, remote ) )`, built from
// `req` and `version`. Only `hsId` is unboxed (outer mask 0x1). Allocates; eco thread.
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
        HoldToken peerHold = kNoHold;
        if (!HttpSrv::httpTablesTakeUpgrade(key, req, weak, peerHold)) {
            return failFErr("EINVAL",
                            "upgradeRequest EINVAL: the request was answered already or is not an upgrade request");
        }
        // Owned here until a handshake entry takes it; released on a throw, or on ECANCELED, when nobody is owed
        // an answer.
        LivenessHold hold = LivenessHold::adopt(peerHold);
        std::shared_ptr<Conn> c = weak.lock();
        if (!c) return failFErr("ECANCELED", "socket closed");
        ensureWsTables();
        if ((req.flags & 3) == 2) {
            int64_t hsId = wsTablesAddServerH2Handshake(std::make_shared<H2Upgrade>(weak, key), hold.detach());
            return upgradeResult(hsId, req, "2", true);
        }
        int64_t hsId = wsTablesAddServerHandshake(c, hold.detach());
        uint64_t gen = currentHeapGeneration();
        IoReactor::instance().submit([c, key, hsId, gen] {
            auto* p = dynamic_cast<HttpSrv::Http1Protocol*>(c->protocol());
            if (!p || !p->upgradePending(key)) {   // closed meanwhile: nobody is owed an answer
                WsEvent ev;
                ev.kind = WsEvent::Kind::HandshakeGone;
                ev.gen = gen;
                ev.wsId = hsId;
                postWsEvent(std::move(ev));
                return;
            }
            std::string head = p->takeUpgradeHead(*c, key);
            // Watch mode: the end of the connection ends the peer hold.
            auto gone = [hsId, gen] {
                WsEvent ev;
                ev.kind = WsEvent::Kind::HandshakeGone;
                ev.gen = gen;
                ev.wsId = hsId;
                postWsEvent(std::move(ev));
            };
            c->setProtocol(std::make_unique<HoldProtocol>(gone), std::move(head));   // retires p
        });
        return upgradeResult(hsId, req, (req.flags & 3) == 0 ? "1.0" : "1.1", false);
#endif
    )
}

} // namespace Eco::System
