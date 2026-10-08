//===- Socket.cpp - eco/system kernel module Socket: binding bodies -------===//
//
// plans/eco-system-sockets.md Appendix B.1, §3.3.6-§3.3.8, §D.2, §D.3, §D.5:
// the binding bodies of the stream-socket kernels of Eco.Kernel.Socket.
//
//   * lookup (P, T2): getaddrinfo on the SysWorkPool; "" fails ENOTFOUND
//     without a call; results in order, deduplicated, printed with
//     inet_ntop (+ "%ifname"); kill handle SysWorkPool::cancel (T7).
//   * tcpConnect / unixConnect (R): socketStartConnect: pendingAsync, a
//     client Conn submitted to the reactor, one Connected event; kill handle
//     cancelPendingConnect (T7: kill → abort; an orphaned success is
//     closed by the drain).
//   * tcpListen / unixListen (P, T2): tcpListenOn / unixListenOn on the
//     pool (RAII ListenFd in the result, N11), completeListen on the main
//     thread (the listener's pendingAsync count, §3.3.8).
//   * accept (A): a held connection at once (§3.4), else parked on the
//     listener entry with one credit; kill handle cancelParkedAccept
//     (returns the credit; no count of its own).
//   * closeListener (R): idempotent; parked accepts fail ECANCELED, held
//     connections are aborted, the task completes on ListenerClosed (after
//     the fd is closed and the Unix path unlinked).
//   * close / reset (S): submit abort; return at once.
//   * setNoDelay / setKeepAlive (R): Unix succeeds at once with no effect;
//     TCP setsockopt on the reactor, OpDone.
//   * peerCredentials (S): from the ConnEntry; non-Unix EINVAL.
//
// Every body follows G2/G3: copy the inputs out of the heap first, then act,
// then allocate. Error messages are "<syscall> <CODE>" plus the address or
// path (§D.5).
//
// Templates used: T1 (S bodies), T2 (pool bodies + completions), T3 (lookup
// list), T7 (kill handles), G10 (counts).
//
//===----------------------------------------------------------------------===//

#include "eco-system/Socket/Socket.hpp"

#include "eco-system/Core/SocketUtil.hpp"
#include "eco-system/Core/SysWorkPool.hpp"
#include "eco-system/Socket/SocketTables.hpp"

#include "allocator/RootedSlots.hpp"

#include <cerrno>
#include <cstring>
#include <utility>
#include <vector>

#ifndef _WIN32
#include <netdb.h>
#include <netinet/in.h>
#include <sys/socket.h>
#include <sys/stat.h>
#include <unistd.h>
#endif

namespace Eco::System {

namespace {

// --- Stubs (Socket.hpp) ----------------------------------------------------------

HPointer notImplementedBody(HPointer /*captured*/) {
    ECO_SYSTEM_BODY_GUARD(FErr,
        return failFErr("ENOTSUP", "not implemented yet");
    )
}

HPointer doneBody(HPointer /*captured*/) {
    ECO_SYSTEM_BODY_GUARD(Never,
        return succeedUnit();
    )
}

// --- Payload decoding (no allocation, G5) ----------------------------------------

bool isElmTrue(HPointer b) { return ::Elm::hpBits(b) == ::Elm::hpBits(alloc::elmTrue()); }

// An Int tuple slot: unboxed (the normal case, HEAP_046) or boxed.
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

#ifdef _WIN32
HPointer unsupported(HPointer& resume) {
    return resumeNow(resume, failFErr("ENOTSUP", "eco/system: sockets are not supported on Windows yet"));
}
#endif

std::string codeMessage(const char* syscall, const std::string& code, const std::string& what) {
    std::string m = std::string(syscall) + " " + code;
    if (!what.empty()) m += " " + what;
    return m;
}

IoReactor& reactor() { return IoReactor::instance(); }

// --- lookup (§3.3.6) ---------------------------------------------------------------

struct LookupRes {
    std::vector<std::string> addresses;
    std::string code, message;
};

LookupRes lookupWork(const std::string& name) {
    LookupRes r;
    if (name.empty()) {   // as Node: without calling the resolver
        r.code = "ENOTFOUND";
        r.message = "getaddrinfo ENOTFOUND " + name;
        return r;
    }
#ifndef _WIN32
    struct addrinfo hints;
    std::memset(&hints, 0, sizeof(hints));
    hints.ai_family = AF_UNSPEC;
    hints.ai_socktype = SOCK_STREAM;
    hints.ai_flags = 0;
    struct addrinfo* res = nullptr;
    int rc = ::getaddrinfo(name.c_str(), nullptr, &hints, &res);
    int sysErr = errno;   // EAI_SYSTEM (G3: right after the call)
    if (rc != 0) {
        r.code = gaiCode(rc, sysErr);
        r.message = "getaddrinfo " + r.code + " " + name;
        return r;
    }
    for (struct addrinfo* p = res; p != nullptr; p = p->ai_next) {
        std::string text;
        int64_t port = 0;
        if (!sockaddrToInet(p->ai_addr, p->ai_addrlen, text, port)) continue;
        bool dup = false;
        for (const auto& a : r.addresses) {
            if (a == text) { dup = true; break; }
        }
        if (!dup) r.addresses.push_back(std::move(text));
    }
    ::freeaddrinfo(res);
    if (r.addresses.empty()) {
        r.code = "ENOTFOUND";
        r.message = "getaddrinfo ENOTFOUND " + name;
    }
#else
    r.code = "ENOTSUP";
    r.message = "eco/system: sockets are not supported on Windows yet";
#endif
    return r;
}

// List String (T3: one rooted range).
HPointer lookupComplete(PoolResult& pr) {
    auto& r = pr.as<LookupRes>();
    if (!r.code.empty()) return failFErr(r.code, r.message);
    alloc::RootedSlots slots(r.addresses.size());
    for (const auto& a : r.addresses) slots.push(alloc::allocStringFromUTF8(a));
    HPointer list = alloc::listFromPointers(slots);
    return succeed(list);
}

// --- listen (§3.3.7) ---------------------------------------------------------------

void closeQuietly(int fd) {
#ifndef _WIN32
    if (fd >= 0) (void)::close(fd);
#else
    (void)fd;
#endif
}

ListenResult listenFailure(const std::string& code, const std::string& what) {
    ListenResult r;
    r.code = code;
    r.message = codeMessage("listen", code, what);
    return r;
}

HPointer listenComplete(PoolResult& pr) { return completeListen(pr.as<ListenResult>(), nullptr); }

} // namespace

// ---------------------------------------------------------------------------
// Socket.hpp helpers
// ---------------------------------------------------------------------------

HPointer socketNotImplementedTask() { return makeBinding<notImplementedBody>(alloc::unit()); }

HPointer socketDoneTask() { return makeBinding<doneBody>(alloc::unit()); }

ListenFd::ListenFd(ListenFd&& o) noexcept : fd(o.fd), createdPath(std::move(o.createdPath)) {
    o.fd = -1;
    o.createdPath.clear();
}

ListenFd& ListenFd::operator=(ListenFd&& o) noexcept {
    if (this != &o) {
        reset();
        fd = o.fd;
        createdPath = std::move(o.createdPath);
        o.fd = -1;
        o.createdPath.clear();
    }
    return *this;
}

ListenFd::~ListenFd() { reset(); }

void ListenFd::reset() {
    closeQuietly(fd);
    fd = -1;
#ifndef _WIN32
    if (!createdPath.empty()) (void)::unlink(createdPath.c_str());
#endif
    createdPath.clear();
}

ListenResult tcpListenOn(const std::string& address, int64_t port, int64_t backlog, bool ipv6Only) {
    std::string what = address + ":" + std::to_string(port);
#ifndef _WIN32
    SockAddr sa;
    int e = inetToSockaddr(address, port, sa);
    if (e != 0) return listenFailure(errnoName(e), what);
    ListenResult r;
    r.owned.fd = socketCloexec(sa.family(), SOCK_STREAM, 0, /*nonBlocking=*/true, &e);
    if (r.owned.fd < 0) return listenFailure(errnoName(e), what);
    int one = 1;
    (void)::setsockopt(r.owned.fd, SOL_SOCKET, SO_REUSEADDR, &one, sizeof(one));
    if (sa.family() == AF_INET6) {
        // Explicit: Linux's default comes from net.ipv6.bindv6only.
        int v6 = ipv6Only ? 1 : 0;
        (void)::setsockopt(r.owned.fd, IPPROTO_IPV6, IPV6_V6ONLY, &v6, sizeof(v6));
    }
    if (::bind(r.owned.fd, sa.get(), sa.len) < 0) {
        e = errno;
        return listenFailure(errnoName(e), what);   // r.owned closes the fd
    }
    int bl = backlog < 1 ? 1 : (backlog > 65535 ? 65535 : static_cast<int>(backlog));
    if (::listen(r.owned.fd, bl) < 0) {
        e = errno;
        return listenFailure(errnoName(e), what);
    }
    SockAddr bound;
    bound.len = sizeof(bound.ss);
    r.bound.kind = 0;
    if (::getsockname(r.owned.fd, bound.get(), &bound.len) < 0 ||
        !sockaddrToInet(bound, r.bound.text, r.bound.port)) {
        r.bound.text = address;
        r.bound.port = port;
    }
    return r;
#else
    (void)backlog; (void)ipv6Only;
    return listenFailure("ENOTSUP", what);
#endif
}

ListenResult unixListenOn(const std::string& path, bool removeExisting, int64_t mode) {
#ifndef _WIN32
    SockAddr sa;
    int e = unixSockaddr(path, sa);   // ENAMETOOLONG before any syscall (§D.3)
    if (e != 0) return listenFailure(errnoName(e), path);
    struct stat st;
    if (::lstat(path.c_str(), &st) == 0) {
        // §D.3: an existing path fails EADDRINUSE unless removeExisting, which
        // removes only a socket.
        if (!removeExisting || !S_ISSOCK(st.st_mode)) return listenFailure("EADDRINUSE", path);
        if (::unlink(path.c_str()) < 0 && errno != ENOENT) {
            e = errno;
            return listenFailure(errnoName(e), path);
        }
    }
    ListenResult r;
    r.isUnix = true;
    r.owned.fd = socketCloexec(AF_UNIX, SOCK_STREAM, 0, /*nonBlocking=*/true, &e);
    if (r.owned.fd < 0) return listenFailure(errnoName(e), path);
    if (::bind(r.owned.fd, sa.get(), sa.len) < 0) {
        e = errno;
        return listenFailure(errnoName(e), path);
    }
    r.owned.createdPath = path;   // from here on, a failure (or a kill) unlinks it
    // Order (§D.3): bind → chmod → listen, so no client connects before the
    // mode is set.
    if (mode >= 0 && ::chmod(path.c_str(), static_cast<mode_t>(mode & 07777)) < 0) {
        e = errno;
        return listenFailure(errnoName(e), path);
    }
    if (::listen(r.owned.fd, 511) < 0) {
        e = errno;
        return listenFailure(errnoName(e), path);
    }
    r.bound = SockEndpoint{1, path, 0};
    return r;
#else
    (void)removeExisting; (void)mode;
    return listenFailure("ENOTSUP", path);
#endif
}

HPointer completeListen(ListenResult& r, TransportFactory factory) {
    if (!r.code.empty()) return failFErr(r.code, r.message);
    ensureSocketTables();
    auto& t = socketTables();
    int64_t id = t.nextListenerId++;
    bool ownsPath = !r.owned.createdPath.empty();
    std::string listenPath = r.isUnix ? r.bound.text : std::string();
    int fd = r.owned.fd;
    r.owned.fd = -1;                 // released to the handler
    r.owned.createdPath.clear();
    auto h = std::make_shared<ListenerHandler>(fd, id, currentHeapGeneration(), r.isUnix,
                                               listenPath, ownsPath, std::move(factory));
    ListenerEntry e;
    e.handler = h;
    e.bound = r.bound;
    e.counted = true;
    t.listeners.emplace(id, std::move(e));
    // An open listener keeps the program alive until closed (§3.3.8).
    Scheduler::instance().incrementPendingAsync();
    reactor().submit([h] { h->start(); });
    // A subscription may already name this id (it cannot: ids are fresh),
    // so only an accept or a later onEffects gives it demand.
    HPointer lt = buildListenT(id, r.bound);
    return succeed(lt);
}

HPointer socketStartConnect(ConnectSpec spec, TransportFactory factory, HPointer& resume,
                            uint64_t& token, bool& counted) {
    ensureSocketTables();
    auto& sched = Scheduler::instance();
    token = sched.registerPendingResume(resume);   // G10
    sched.incrementPendingAsync();
    counted = true;
    auto c = Conn::makeClient(std::move(spec), std::move(factory), token, currentHeapGeneration());
    socketTables().pendingConnects[token] = c;
    reactor().submit([c] { c->startConnect(); });
    return makeKillHandle(token, &cancelPendingConnect);
}

// ---------------------------------------------------------------------------
// Kernel bodies
// ---------------------------------------------------------------------------

// lookup : String -> Task FErr (List String) — payload: the name.
HPointer socketLookupBody(HPointer captured, HPointer resume) {
    uint64_t token = 0;
    bool counted = false;
    ECO_SYSTEM_ASYNC_GUARD(FErr, resume, token, counted,
        std::string name = toStdString(captured);   // G3
        auto& s = Scheduler::instance();
        token = s.registerPendingResume(resume);
        s.incrementPendingAsync();
        counted = true;
        SysWorkPool::instance().submit(
            token,
            [name = std::move(name)]() -> PoolResult { return PoolResult::of(lookupWork(name)); },
            &lookupComplete, ErrShape::FErr);
        return makeKillHandle(token, &SysWorkPool::cancel);
    )
}

#ifdef _WIN32

// tcpConnect / unixConnect: not supported on Windows yet (§1).
HPointer socketTcpConnectBody(HPointer /*captured*/, HPointer resume) {
    uint64_t token = 0;
    bool counted = false;
    ECO_SYSTEM_ASYNC_GUARD(FErr, resume, token, counted,
        return unsupported(resume);
    )
}

HPointer socketUnixConnectBody(HPointer /*captured*/, HPointer resume) {
    uint64_t token = 0;
    bool counted = false;
    ECO_SYSTEM_ASYNC_GUARD(FErr, resume, token, counted,
        return unsupported(resume);
    )
}

#else

// tcpConnect : ( String, Int, Int ) -> ( Bool, Int ) -> Task FErr ConnT
// payload tuple2( boxed target, boxed settings ), mask 0.
HPointer socketTcpConnectBody(HPointer captured, HPointer resume) {
    uint64_t token = 0;
    bool counted = false;
    ECO_SYSTEM_ASYNC_GUARD(FErr, resume, token, counted,
        ConnectSpec spec;
        {   // G3/G5: no allocation in this scope
            Tuple2* p = asTuple2(captured);
            HPointer target = p->a.p;
            HPointer settings = p->b.p;
            Tuple3* t = asTuple3(target);
            u32 tm = t->header.unboxed;
            HPointer addr = t->a.p;
            spec.port = slotInt(t->b, tm, 1);
            spec.timeoutMs = slotInt(t->c, tm, 2);
            spec.address = toStdString(addr);
            Tuple2* st = asTuple2(settings);
            spec.noDelay = isElmTrue(st->a.p);
            spec.keepAliveSec = slotInt(st->b, st->header.unboxed, 1);
        }
        if (spec.timeoutMs < 0) spec.timeoutMs = 0;
        spec.isUnix = false;
        return socketStartConnect(std::move(spec), nullptr, resume, token, counted);
    )
}

// unixConnect : String -> Task FErr ConnT — payload: the path.
HPointer socketUnixConnectBody(HPointer captured, HPointer resume) {
    uint64_t token = 0;
    bool counted = false;
    ECO_SYSTEM_ASYNC_GUARD(FErr, resume, token, counted,
        ConnectSpec spec;
        spec.isUnix = true;
        spec.address = toStdString(captured);   // G3
        return socketStartConnect(std::move(spec), nullptr, resume, token, counted);
    )
}

#endif

// tcpListen : ( String, Int ) -> ( Int, Bool ) -> Task FErr ListenT
// payload tuple2( boxed target, boxed settings ), mask 0.
HPointer socketTcpListenBody(HPointer captured, HPointer resume) {
    uint64_t token = 0;
    bool counted = false;
    ECO_SYSTEM_ASYNC_GUARD(FErr, resume, token, counted,
        std::string address;
        int64_t port = 0, backlog = 511;
        bool ipv6Only = false;
        {   // G3/G5
            Tuple2* p = asTuple2(captured);
            HPointer target = p->a.p;
            HPointer settings = p->b.p;
            Tuple2* t = asTuple2(target);
            HPointer addr = t->a.p;
            port = slotInt(t->b, t->header.unboxed, 1);
            address = toStdString(addr);
            Tuple2* st = asTuple2(settings);
            backlog = slotInt(st->a, st->header.unboxed, 0);
            ipv6Only = isElmTrue(st->b.p);
        }
        ensureSocketTables();
        auto& s = Scheduler::instance();
        token = s.registerPendingResume(resume);
        s.incrementPendingAsync();
        counted = true;
        SysWorkPool::instance().submit(
            token,
            [address = std::move(address), port, backlog, ipv6Only]() -> PoolResult {
                return PoolResult::of(tcpListenOn(address, port, backlog, ipv6Only));
            },
            &listenComplete, ErrShape::FErr);
        return alloc::unit();   // short job; an orphaned result closes its fd (RAII)
    )
}

// unixListen : String -> ( Bool, Int ) -> Task FErr ListenT
// payload tuple2( boxed path, boxed settings ), mask 0.
HPointer socketUnixListenBody(HPointer captured, HPointer resume) {
    uint64_t token = 0;
    bool counted = false;
    ECO_SYSTEM_ASYNC_GUARD(FErr, resume, token, counted,
        std::string path;
        bool removeExisting = false;
        int64_t mode = -1;
        {   // G3/G5
            Tuple2* p = asTuple2(captured);
            HPointer pathHP = p->a.p;
            HPointer settings = p->b.p;
            path = toStdString(pathHP);
            Tuple2* st = asTuple2(settings);
            removeExisting = isElmTrue(st->a.p);
            mode = slotInt(st->b, st->header.unboxed, 1);
        }
        ensureSocketTables();
        auto& s = Scheduler::instance();
        token = s.registerPendingResume(resume);
        s.incrementPendingAsync();
        counted = true;
        SysWorkPool::instance().submit(
            token,
            [path = std::move(path), removeExisting, mode]() -> PoolResult {
                return PoolResult::of(unixListenOn(path, removeExisting, mode));
            },
            &listenComplete, ErrShape::FErr);
        return alloc::unit();
    )
}

// accept : Int -> Task FErr ConnT — payload: boxed listener id.
HPointer socketAcceptBody(HPointer captured, HPointer resume) {
    uint64_t token = 0;
    bool counted = false;
    ECO_SYSTEM_ASYNC_GUARD(FErr, resume, token, counted,
        int64_t id = payloadInt(captured);
        ensureSocketTables();
        ListenerEntry* e = findListener(id);
        if (!e || e->closing) return resumeNow(resume, failFErr("ECANCELED", "accept ECANCELED"));
        if (!e->held.empty()) {   // held items first (§3.4)
            SocketEvent ev = std::move(e->held.front());
            e->held.pop_front();
            int64_t connId = materializeConnection(ev);   // no allocation
            HPointer task = alloc::listNil();
            Elm::StackRootGuard g(&task);
            task = buildConnT(connId, ev);
            task = succeed(task);
            return resumeNow(resume, task);
        }
        token = Scheduler::instance().registerPendingResume(resume);
        e->parkedAccepts.push_back(token);
        auto h = e->handler;
        if (h) reactor().submit([h] { h->addCredit(1); });
        return makeKillHandle(token, &cancelParkedAccept);
    )
}

// closeListener : Int -> Task FErr () — payload: boxed listener id.
HPointer socketCloseListenerBody(HPointer captured, HPointer resume) {
    uint64_t token = 0;
    bool counted = false;
    ECO_SYSTEM_ASYNC_GUARD(FErr, resume, token, counted,
        int64_t id = payloadInt(captured);
        ensureSocketTables();
        ListenerEntry* e = findListener(id);
        if (!e) return resumeNow(resume, succeedUnit());   // closed already: idempotent
        auto& s = Scheduler::instance();
        token = s.registerPendingResume(resume);
        s.incrementPendingAsync();
        counted = true;
        e->closeTokens.push_back(token);   // completed by ListenerClosed
        if (e->closing) return alloc::unit();
        e->closing = true;
        std::deque<uint64_t> parked;
        parked.swap(e->parkedAccepts);
        std::deque<SocketEvent> held;
        held.swap(e->held);
        auto h = e->handler;
        for (auto& ev : held) {
            if (ev.conn) {
                auto c = ev.conn;
                reactor().submit([c] { c->abort(false); });
            }
        }
        if (h) reactor().submit([h] { h->close(); });
        // Parked accepts fail now (they hold no count). Allocates: `e` is dead.
        for (uint64_t t : parked) {
            HPointer r = s.takePendingResume(t);
            if (alloc::isNil(r)) continue;
            HPointer task = alloc::listNil();
            Elm::StackRootGuard g(&r, &task);
            task = failFErr("ECANCELED", "accept ECANCELED");
            Scheduler::callClosure1(r, task);
        }
        return alloc::unit();
    )
}

namespace {

void abortConnection(int64_t connId, bool reset) {
    ensureSocketTables();
    ConnEntry* e = findConn(connId);
    if (!e || !e->conn) return;
    auto c = e->conn;
    reactor().submit([c, reset] { c->abort(reset); });
}

// R-mode socket option: Unix succeeds at once (§D.3); TCP runs `fn` on the
// reactor and posts OpDone.
HPointer optionBody(int64_t connId, HPointer& resume, uint64_t& token, bool& counted,
                    std::function<int(Conn&)> fn) {
    ensureSocketTables();
    ConnEntry* e = findConn(connId);
    if (!e || !e->conn || e->isUnix) return resumeNow(resume, succeedUnit());
    auto c = e->conn;
    auto& s = Scheduler::instance();
    token = s.registerPendingResume(resume);
    s.incrementPendingAsync();
    counted = true;
    uint64_t tok = token;
    uint64_t gen = currentHeapGeneration();
    reactor().submit([c, tok, gen, fn = std::move(fn)] {
        int err = fn(*c);
        SocketEvent ev;
        ev.kind = SocketEvent::Kind::OpDone;
        ev.gen = gen;
        ev.token = tok;
        if (err != 0) {
            ev.failed = true;
            ev.code = errnoName(err);
            ev.message = codeMessage("setsockopt", ev.code, std::string());
        }
        postSocketEvent(std::move(ev));
    });
    return alloc::unit();
}

} // namespace

// close : Int -> Task Never () — payload: boxed connection id.
HPointer socketCloseBody(HPointer captured) {
    ECO_SYSTEM_BODY_GUARD(Never,
        abortConnection(payloadInt(captured), /*reset=*/false);
        return succeedUnit();
    )
}

// reset : Int -> Task Never () — payload: boxed connection id.
HPointer socketResetBody(HPointer captured) {
    ECO_SYSTEM_BODY_GUARD(Never,
        abortConnection(payloadInt(captured), /*reset=*/true);
        return succeedUnit();
    )
}

// setNoDelay : Bool -> Int -> Task FErr () — payload tuple2( boxed Bool, Int id ), mask 0x4.
HPointer socketSetNoDelayBody(HPointer captured, HPointer resume) {
    uint64_t token = 0;
    bool counted = false;
    ECO_SYSTEM_ASYNC_GUARD(FErr, resume, token, counted,
        bool on = false;
        int64_t id = 0;
        {
            Tuple2* t = asTuple2(captured);
            on = isElmTrue(t->a.p);
            id = slotInt(t->b, t->header.unboxed, 1);
        }
        return optionBody(id, resume, token, counted, [on](Conn& c) { return c.setNoDelay(on); });
    )
}

// setKeepAlive : Int -> Int -> Task FErr () — payload tuple2( Int seconds, Int id ), mask 0x5.
HPointer socketSetKeepAliveBody(HPointer captured, HPointer resume) {
    uint64_t token = 0;
    bool counted = false;
    ECO_SYSTEM_ASYNC_GUARD(FErr, resume, token, counted,
        int64_t seconds = 0, id = 0;
        {
            Tuple2* t = asTuple2(captured);
            seconds = slotInt(t->a, t->header.unboxed, 0);
            id = slotInt(t->b, t->header.unboxed, 1);
        }
        return optionBody(id, resume, token, counted,
                          [seconds](Conn& c) { return c.setKeepAlive(seconds); });
    )
}

// peerCredentials : Int -> Task FErr ( Int, Int, Int ) — payload: boxed connection id.
HPointer socketPeerCredentialsBody(HPointer captured) {
    ECO_SYSTEM_BODY_GUARD(FErr,
        int64_t id = payloadInt(captured);
        ensureSocketTables();
        ConnEntry* e = findConn(id);
        if (!e || !e->isUnix) return failFErr("EINVAL", "peerCredentials EINVAL");
        if (!e->hasCred) return failFErr("ENOTSUP", "peerCredentials ENOTSUP");
        Cred c = e->cred;
        HPointer t = alloc::tuple3(alloc::unboxedInt(c.pid), alloc::unboxedInt(c.uid),
                                   alloc::unboxedInt(c.gid), 0x15);
        return succeed(t);
    )
}

} // namespace Eco::System
