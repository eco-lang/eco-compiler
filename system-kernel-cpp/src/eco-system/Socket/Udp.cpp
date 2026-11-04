//===- Udp.cpp - UDP sockets on the IoReactor -----------------------------===//
//
// The kernel bodies read the payload in two phases. First they copy everything they need out of the heap into C++
// values, without allocating, so the raw pointers they read through stay valid; only then do they act and allocate.
// The value builders likewise root each value they have made, or pass it straight to a helper that roots it,
// before making the next.
//
//===----------------------------------------------------------------------===//

#include "eco-system/Socket/Udp.hpp"

#include "eco-system/Core/IoReactor.hpp"
#include "eco-system/Core/SysWorkPool.hpp"
#include "eco-system/Socket/Socket.hpp"
#include "eco-system/Socket/SocketTables.hpp"
#include "eco-system/Socket/UdpManager.hpp"

#include <algorithm>
#include <cerrno>
#include <cstring>
#include <stdexcept>
#include <utility>

#ifndef _WIN32
#include <arpa/inet.h>
#include <netinet/in.h>
#include <sys/socket.h>
#include <sys/uio.h>
#include <unistd.h>
#endif

namespace Eco::System {

namespace {

/// Returns the reactor.
IoReactor& reactor() { return IoReactor::instance(); }

/// Closes `fd` if it is not negative, ignoring any error.
void closeQuietly(int fd) {
#ifndef _WIN32
    if (fd >= 0) (void)::close(fd);
#else
    (void)fd;
#endif
}

/// Returns "address:port", the form error messages quote a destination in.
std::string hostPort(const std::string& address, int64_t port) {
    return address + ":" + std::to_string(port);
}

} // namespace

// ---------------------------------------------------------------------------
// UdpHandler (reactor thread)
// ---------------------------------------------------------------------------

UdpHandler::UdpHandler(int fd, int64_t socketId, uint64_t gen, bool isV6)
    : fd_(fd), socketId_(socketId), gen_(gen), isV6_(isV6) {}

UdpHandler::~UdpHandler() {
    // A registered handler is kept alive by the reactor until close() removes it, so an open fd here means the
    // handler was never registered.
    if (fd_ >= 0 && key() == 0) closeQuietly(fd_);
}

void UdpHandler::start() {
    if (closed_ || key() != 0) return;
    auto self = std::static_pointer_cast<UdpHandler>(shared_from_this());
    if (reactor().add(self, fd_) == 0) return;
    updateInterest();
}

bool UdpHandler::canReceive() const {
    return !closed_ && !backoff_ && (unlimited_ || credit_ > 0);
}

void UdpHandler::updateInterest() {
    if (key() == 0 || closed_) return;
    int e = reactor().setInterest(key(), canReceive(), !sendQ_.empty());
    if (e != 0 && !backoff_) {
        backoff_ = true;
        reactor().setTimer(key(), reactor().nowMs() + kBackoffMs);
    }
}

void UdpHandler::addCredit(int64_t n) {
    if (closed_) return;
    credit_ += n;
    if (credit_ < 0) credit_ = 0;
    updateInterest();
}

void UdpHandler::setUnlimited(bool on) {
    if (closed_) return;
    unlimited_ = on;
    updateInterest();
}

void UdpHandler::postOpDone(uint64_t token, int err, const char* syscall, const std::string& what) {
    SocketEvent ev;
    ev.kind = SocketEvent::Kind::OpDone;
    ev.gen = gen_;
    ev.token = token;
    if (err != 0) {
        ev.failed = true;
        ev.code = errnoName(err);
        ev.message = std::string(syscall) + " " + ev.code;
        if (!what.empty()) ev.message += " " + what;
    }
    postSocketEvent(std::move(ev));
}

void UdpHandler::receiveLoop() {
#ifndef _WIN32
    if (buf_.size() < kMaxDatagram) buf_.resize(kMaxDatagram);
    while (canReceive()) {
        SockAddr from;
        struct iovec iov;
        iov.iov_base = buf_.data();
        iov.iov_len = buf_.size();
        struct msghdr mh;
        std::memset(&mh, 0, sizeof(mh));
        mh.msg_name = from.get();
        mh.msg_namelen = sizeof(from.ss);
        mh.msg_iov = &iov;
        mh.msg_iovlen = 1;
        ssize_t n = ::recvmsg(fd_, &mh, 0);
        if (n < 0) {
            int e = errno;
            if (e == EAGAIN || e == EWOULDBLOCK) return;
            // EINTR, and the errors an ICMP report can leave pending on a datagram socket: try again.
            if (e == EINTR || e == ECONNREFUSED || e == ECONNRESET || e == EHOSTUNREACH ||
                e == ENETUNREACH)
                continue;
            // Anything else (ENOMEM, ENOBUFS, ...): back off instead of spinning on a level-triggered fd.
            backoff_ = true;
            reactor().setTimer(key(), reactor().nowMs() + kBackoffMs);
            return;
        }
        if (mh.msg_flags & MSG_TRUNC) continue;   // longer than the buffer: dropped
        from.len = mh.msg_namelen;
        SocketEvent ev;
        ev.kind = SocketEvent::Kind::Datagram;
        ev.gen = gen_;
        ev.ownerId = socketId_;
        if (!sockaddrToInet(from, ev.remote.text, ev.remote.port)) {
            ev.remote.text = isV6_ ? "::" : "0.0.0.0";
            ev.remote.port = 0;
        }
        ev.data.assign(buf_.data(), static_cast<size_t>(n));
        if (credit_ > 0) --credit_;   // taken even when unlimited
        postSocketEvent(std::move(ev));
    }
#endif
}

void UdpHandler::serviceSends() {
#ifndef _WIN32
    while (!sendQ_.empty()) {
        SendReq& r = sendQ_.front();
        ssize_t n = ::sendto(fd_, r.data.data(), r.data.size(), kSendFlags, r.to.get(), r.to.len);
        if (n < 0) {
            int e = errno;
            if (e == EINTR) continue;
            if (e == EAGAIN || e == EWOULDBLOCK) return;   // the caller watches for writability
            postOpDone(r.token, e, "send", r.what);
        } else {
            postOpDone(r.token, 0, "send", r.what);
        }
        sendQ_.pop_front();
    }
#endif
}

void UdpHandler::send(uint64_t token, std::string address, int64_t port, std::string data) {
    std::string what = hostPort(address, port);
    if (closed_) {
        postOpDone(token, ECANCELED, "send", what);
        return;
    }
#ifndef _WIN32
    SendReq r{token, SockAddr(), std::move(data), what};
    int e = inetToSockaddr(address, port, r.to);
    if (e == 0) {
        // On an IPv6-only socket the mapped address fails in sendto, with whatever error the system reports.
        if (r.to.family() == AF_INET6 && !isV6_) e = EAFNOSUPPORT;
        else if (r.to.family() == AF_INET && isV6_) (void)mapIPv4ToIPv6(r.to);
    }
    if (e != 0) {
        postOpDone(token, e, "send", what);
        return;
    }
    bool idle = sendQ_.empty();
    sendQ_.push_back(std::move(r));
    if (idle) serviceSends();   // otherwise it waits behind the sends already queued
    updateInterest();
#else
    (void)data;
    postOpDone(token, ENOTSUP, "send", what);
#endif
}

void UdpHandler::membership(uint64_t token, bool join, std::string group, std::string iface) {
    const char* syscall = join ? "addMembership" : "dropMembership";
    if (closed_) {
        postOpDone(token, ECANCELED, syscall, std::string());
        return;
    }
#ifndef _WIN32
    SockAddr g;
    int e = inetToSockaddr(group, 0, g);
    if (e == 0 && g.family() == AF_INET) {
        struct ip_mreq mr;
        std::memset(&mr, 0, sizeof(mr));
        mr.imr_multiaddr = reinterpret_cast<const struct sockaddr_in*>(g.get())->sin_addr;
        mr.imr_interface.s_addr = htonl(INADDR_ANY);
        if (!iface.empty() && ::inet_pton(AF_INET, iface.c_str(), &mr.imr_interface) != 1) e = EINVAL;
        if (e == 0 &&
            ::setsockopt(fd_, IPPROTO_IP, join ? IP_ADD_MEMBERSHIP : IP_DROP_MEMBERSHIP, &mr,
                         sizeof(mr)) < 0)
            e = errno;
    } else if (e == 0) {
        struct ipv6_mreq mr;
        std::memset(&mr, 0, sizeof(mr));
        const auto* g6 = reinterpret_cast<const struct sockaddr_in6*>(g.get());
        mr.ipv6mr_multiaddr = g6->sin6_addr;
        // The address bits of `iface` are ignored; only its scope names the interface.
        uint32_t index = g6->sin6_scope_id;
        if (!iface.empty()) {
            SockAddr i;
            e = inetToSockaddr(iface, 0, i);
            if (e == 0 && i.family() != AF_INET6) e = EINVAL;
            if (e == 0) index = reinterpret_cast<const struct sockaddr_in6*>(i.get())->sin6_scope_id;
        }
        mr.ipv6mr_interface = index;
        if (e == 0 &&
            ::setsockopt(fd_, IPPROTO_IPV6, join ? IPV6_JOIN_GROUP : IPV6_LEAVE_GROUP, &mr,
                         sizeof(mr)) < 0)
            e = errno;
    }
    postOpDone(token, e, syscall, std::string());
#else
    (void)join; (void)group; (void)iface;
    postOpDone(token, ENOTSUP, syscall, std::string());
#endif
}

void UdpHandler::close() {
    if (closed_) return;
    closed_ = true;
    std::deque<SendReq> q;
    q.swap(sendQ_);
    for (auto& r : q) postOpDone(r.token, ECANCELED, "send", r.what);
    if (key() != 0) reactor().remove(key());   // the reactor requires removal before the fd is closed
    closeQuietly(fd_);
    fd_ = -1;
    SocketEvent ev;
    ev.kind = SocketEvent::Kind::UdpClosed;
    ev.gen = gen_;
    ev.ownerId = socketId_;
    postSocketEvent(std::move(ev));
}

void UdpHandler::onReady(bool readable, bool writable, bool errorOrHangup) {
    if (closed_) return;
    if (writable || errorOrHangup) serviceSends();
    if (readable || errorOrHangup) receiveLoop();
    updateInterest();
}

void UdpHandler::onTimer() {
    if (closed_) return;
    backoff_ = false;
    updateInterest();
}

void UdpHandler::onCloseAll() { close(); }

// ---------------------------------------------------------------------------
// Bind (pool worker)
// ---------------------------------------------------------------------------

UdpBindResult::UdpBindResult(UdpBindResult&& o) noexcept
    : fd(o.fd), isV6(o.isV6), bound(std::move(o.bound)), code(std::move(o.code)),
      message(std::move(o.message)) {
    o.fd = -1;
}

UdpBindResult& UdpBindResult::operator=(UdpBindResult&& o) noexcept {
    if (this != &o) {
        closeQuietly(fd);
        fd = o.fd;
        isV6 = o.isV6;
        bound = std::move(o.bound);
        code = std::move(o.code);
        message = std::move(o.message);
        o.fd = -1;
    }
    return *this;
}

UdpBindResult::~UdpBindResult() { closeQuietly(fd); }

namespace {

/// Returns `r` turned into the failure for errno `err`, closing its fd; `what` is the "address:port" the message
/// quotes.
UdpBindResult bindFailure(UdpBindResult r, int err, const std::string& what) {
    closeQuietly(r.fd);
    r.fd = -1;
    r.code = errnoName(err);
    r.message = "bind " + r.code + " " + what;
    return r;
}

} // namespace

UdpBindResult udpBindOn(const std::string& address, int64_t port, bool reuseAddress,
                        bool broadcast, bool ipv6Only) {
    std::string what = hostPort(address, port);
    UdpBindResult r;
#ifndef _WIN32
    SockAddr sa;
    int e = inetToSockaddr(address, port, sa);
    if (e != 0) return bindFailure(std::move(r), e, what);
    r.isV6 = sa.family() == AF_INET6;
    r.fd = socketCloexec(sa.family(), SOCK_DGRAM, 0, /*nonBlocking=*/true, &e);
    if (r.fd < 0) return bindFailure(std::move(r), e, what);
    int one = 1;
    if (reuseAddress) {
        (void)::setsockopt(r.fd, SOL_SOCKET, SO_REUSEADDR, &one, sizeof(one));
#if defined(__APPLE__) && defined(SO_REUSEPORT)
        (void)::setsockopt(r.fd, SOL_SOCKET, SO_REUSEPORT, &one, sizeof(one));
#endif
    }
    if (broadcast && ::setsockopt(r.fd, SOL_SOCKET, SO_BROADCAST, &one, sizeof(one)) < 0) {
        e = errno;
        return bindFailure(std::move(r), e, what);
    }
    if (r.isV6) {
        // Set either way, so the result does not depend on the system's default.
        int v6 = ipv6Only ? 1 : 0;
        (void)::setsockopt(r.fd, IPPROTO_IPV6, IPV6_V6ONLY, &v6, sizeof(v6));
    }
    // Each buffer is raised to kMaxDatagram if it is smaller, never lowered; a failure is ignored.
    for (int opt : {SO_SNDBUF, SO_RCVBUF}) {
        int cur = 0;
        socklen_t len = sizeof(cur);
        if (::getsockopt(r.fd, SOL_SOCKET, opt, &cur, &len) < 0 ||
            cur < static_cast<int>(UdpHandler::kMaxDatagram)) {
            int want = static_cast<int>(UdpHandler::kMaxDatagram);
            (void)::setsockopt(r.fd, SOL_SOCKET, opt, &want, sizeof(want));
        }
    }
    if (::bind(r.fd, sa.get(), sa.len) < 0) {
        e = errno;
        return bindFailure(std::move(r), e, what);
    }
    SockAddr bound;
    bound.len = sizeof(bound.ss);
    r.bound.kind = 0;
    if (::getsockname(r.fd, bound.get(), &bound.len) < 0 ||
        !sockaddrToInet(bound, r.bound.text, r.bound.port)) {
        r.bound.text = address;
        r.bound.port = port;
    }
    return r;
#else
    (void)reuseAddress; (void)broadcast; (void)ipv6Only;
    r.code = "ENOTSUP";
    r.message = "eco/system: sockets are not supported on Windows yet";
    return r;
#endif
}

// ---------------------------------------------------------------------------
// Eco-thread table, values and delivery
// ---------------------------------------------------------------------------

namespace {

/// Closes every handler in `t`, releases the subscription holds and the holds of the parked receives, whose tasks
/// are never resumed, and empties the table. The `UdpClosed` events that follow belong to the old heap generation
/// and are not dispatched.
void resetTables(UdpTables& t) {
    auto& sched = Scheduler::instance();
    for (auto& kv : t.sockets) {
        if (auto h = kv.second.handler) reactor().submit([h] { h->close(); });
        HoldRelease subHold(kv.second.subHold);
        for (uint64_t token : kv.second.parkedReceives) {
            (void)sched.takePendingResume(token);
            sched.releaseHold(token);
        }
    }
    t.sockets.clear();
}

/// Returns the Elm value `( id, ( address, port ) )` for socket `id` bound to `ep`, with both Ints unboxed.
HPointer buildUdpT(int64_t id, const SockEndpoint& ep) {
    HPointer inner = alloc::listNil();
    Elm::StackRootGuard g(&inner);
    HPointer text = alloc::allocStringFromUTF8(ep.text);
    // `text` is passed straight to tuple2, which roots its arguments.
    inner = alloc::tuple2(alloc::boxed(text), alloc::unboxedInt(ep.port), 0x4);
    return alloc::tuple2(alloc::unboxedInt(id), alloc::boxed(inner), 0x1);
}

/// Returns the Elm value `( data, ( fromAddress, fromPort ) )` for the datagram `ev`, with the port unboxed.
HPointer buildDgramT(const SocketEvent& ev) {
    HPointer data = alloc::listNil();
    HPointer from = alloc::listNil();
    Elm::StackRootGuard g(&data, &from);
    {
        // Filled before anything else allocates; an empty payload gives the empty-Bytes constant.
        alloc::BlankByteBuffer bb = alloc::allocByteBufferBlank(ev.data.size());
        if (!ev.data.empty()) std::memcpy(bb.bytes, ev.data.data(), ev.data.size());
        data = bb.hp;
    }
    HPointer text = alloc::allocStringFromUTF8(ev.remote.text);
    from = alloc::tuple2(alloc::boxed(text), alloc::unboxedInt(ev.remote.port), UdpManager::DGRAM_FROM_MASK);
    return alloc::tuple2(alloc::boxed(data), alloc::boxed(from), UdpManager::DGRAM_T_MASK);
}

/// Fails the task parked under `token` with the FErr `( code, message )` and returns true, or returns false if
/// nothing is parked under it. Releases no hold.
bool resumeFail(uint64_t token, const std::string& code, const std::string& message) {
    HPointer task = alloc::listNil();
    Elm::StackRootGuard g(&task);
    HPointer resume = Scheduler::instance().takePendingResume(token);
    if (alloc::isNil(resume)) return false;
    Elm::StackRootGuard g2(&resume);
    task = failFErr(code, message);
    Scheduler::callClosure1(resume, task);
    return true;
}

/// Delivers the held datagrams of socket `id` from the front, as the header's file comment describes, until none is
/// held, no one takes them, or the socket closes. Runs the scheduler after each delivery.
void serveHeld(int64_t id) {
    auto& sched = Scheduler::instance();
    for (;;) {
        UdpEntry* e = findUdp(id);
        if (!e || e->closed || e->held.empty()) return;
        if (!e->parkedReceives.empty()) {
            uint64_t token = e->parkedReceives.front();
            e->parkedReceives.pop_front();
            HPointer resume = sched.takePendingResume(token);
            if (alloc::isNil(resume)) continue;   // already completed; whoever did released its hold
            HoldRelease release(token);   // released after the resume
            SocketEvent ev = std::move(e->held.front());
            e->held.pop_front();
            HPointer task = alloc::listNil();
            Elm::StackRootGuard g(&resume, &task);
            task = buildDgramT(ev);
            task = succeed(task);
            Scheduler::callClosure1(resume, task);
            sched.drain();
            continue;
        }
        if (!udpManagerHasSubscribers(id)) return;
        SocketEvent ev = std::move(e->held.front());
        e->held.pop_front();
        HPointer dgram = alloc::listNil();
        Elm::StackRootGuard g(&dgram);
        dgram = buildDgramT(ev);
        udpManagerDeliver(id, dgram);
    }
}

/// Serves the held datagrams of every socket, in socket id order; the work `udpTablesSyncSubscriptions` requests.
void serveAllHeld() {
    std::vector<int64_t> ids;
    for (auto& kv : udpTables().sockets) {
        if (!kv.second.held.empty()) ids.push_back(kv.first);
    }
    std::sort(ids.begin(), ids.end());
    for (int64_t id : ids) serveHeld(id);
}

// --- Event dispatchers ------------------------------

/// Holds the datagram `ev` and serves the socket's held FIFO, or drops it if the socket is closed or unknown.
/// Returns false: `serveHeld` already ran the scheduler after each delivery.
bool onDatagram(SocketEvent& ev) {
    UdpEntry* e = findUdp(ev.ownerId);
    if (!e || e->closed) return false;   // closed: dropped
    int64_t id = ev.ownerId;
    e->held.push_back(std::move(ev));
    while (e->held.size() > kMaxHeldDatagrams) e->held.pop_front();
    serveHeld(id);
    return false;
}

/// Erases the closed socket, releases its subscription hold and fails its parked receives with ECANCELED. Returns
/// whether any task was resumed.
bool onUdpClosed(SocketEvent& ev) {
    UdpEntry* e = findUdp(ev.ownerId);
    if (!e) return false;
    // Moved out before any task resumes, since Elm code can change the table.
    UdpEntry entry = std::move(*e);
    udpTables().sockets.erase(ev.ownerId);
    HoldRelease subHold(entry.subHold);   // the subscription's hold, if any
    bool resumed = false;
    // Parked receives remain only when the socket closed without `udpClose`, which fails them itself.
    for (uint64_t token : entry.parkedReceives) {
        HoldRelease receiveHold(token);
        resumed |= resumeFail(token, "ECANCELED", "receive ECANCELED");
    }
    return resumed;
}

/// Completes a bind on the eco thread: returns the failure Task, or adds the bound socket to the table, starts its
/// handler and returns the Task that succeeds with its `( id, ( address, port ) )`.
HPointer udpBindComplete(PoolResult& pr) {
    auto& r = pr.as<UdpBindResult>();
    if (!r.code.empty()) return failFErr(r.code, r.message);
    ensureUdpTables();
    auto& t = udpTables();
    int64_t id = t.nextId++;
    int fd = r.fd;
    r.fd = -1;   // released to the handler
    auto h = std::make_shared<UdpHandler>(fd, id, currentHeapGeneration(), r.isV6);
    UdpEntry e;
    e.handler = h;
    e.bound = r.bound;
    t.sockets.emplace(id, std::move(e));
    reactor().submit([h] { h->start(); });
    HPointer ut = buildUdpT(id, r.bound);
    return succeed(ut);
}

// --- Payload decoding (no allocation) ----------------------------------------

/// Returns whether `b` is the Elm `True` constant.
bool isElmTrue(HPointer b) { return ::Elm::hpBits(b) == ::Elm::hpBits(alloc::elmTrue()); }

/// Returns the Int in slot `slot` of a tuple whose kind mask is `mask`, whether the slot holds it unboxed or boxed.
int64_t slotInt(const Unboxable& u, u32 mask, int slot) {
    if (Elm::tupleFieldKind(mask, slot) == 1) return u.i;
    return static_cast<ElmInt*>(Allocator::instance().resolve(u.p))->value;
}

/// Returns the value of `captured`, a boxed Int.
int64_t payloadInt(HPointer captured) {
    return static_cast<ElmInt*>(Allocator::instance().resolve(captured))->value;
}

/// Completes the body's Task at once by passing `task` to `resume`, and returns `()` as the kill handle.
HPointer resumeNow(HPointer& resume, HPointer task) {
    Elm::StackRootGuard g(&task);
    Scheduler::callClosure1(resume, task);
    return alloc::unit();
}

/// Reads `address` and `port` from `tuple`, an Elm `( String, Int )`.
void readHostPort(HPointer tuple, std::string& address, int64_t& port) {
    Tuple2* t = asTuple2(tuple);
    HPointer addr = t->a.p;
    port = slotInt(t->b, t->header.unboxed, 1);
    address = toStdString(addr);
}

/// Parks `resume`, taking a hold named `site`, and returns the token, which it also stores in `token`; sets
/// `counted`. The caller then submits the work whose `OpDone` completes it.
uint64_t startOp(HPointer& resume, uint64_t& token, bool& counted, const char* site) {
    auto& s = Scheduler::instance();
    token = s.parkResume(resume, HoldKind::Task, site);
    counted = true;
    return token;
}

} // namespace

UdpTables& udpTables() {
    static auto* t = new UdpTables();   // never freed
    uint64_t g = currentHeapGeneration();
    if (!t->init || t->gen != g) {
        if (t->init) resetTables(*t);
        t->init = true;
        t->gen = g;
    }
    return *t;
}

UdpEntry* findUdp(int64_t id) {
    auto& m = udpTables().sockets;
    auto it = m.find(id);
    return it == m.end() ? nullptr : &it->second;
}

void ensureUdpTables() {
    ensureSocketTables();
    static bool done = false;
    if (done) return;
    done = true;
    setSocketEventDispatch(SocketEvent::Kind::Datagram, &onDatagram);
    setSocketEventDispatch(SocketEvent::Kind::UdpClosed, &onUdpClosed);
}

void udpTablesSyncSubscriptions() {
    auto& sched = Scheduler::instance();
    bool heldWaiting = false;
    for (auto& kv : udpTables().sockets) {
        UdpEntry& e = kv.second;
        bool wantHold = !e.closed && e.handler && udpManagerHasSubscribers(kv.first);
        if (wantHold && !e.subHold) e.subHold = sched.acquireHold(HoldKind::Subscription, "Udp.onMessage");
        if (!wantHold && e.subHold) {
            sched.releaseHold(e.subHold);
            e.subHold = kNoHold;
        }
        if (e.closed || !e.handler) continue;
        bool on = udpManagerHasSubscribers(kv.first);
        if (on != e.subscribed) {
            e.subscribed = on;
            auto h = e.handler;
            reactor().submit([h, on] { h->setUnlimited(on); });
        }
        if (on && !e.held.empty()) heldWaiting = true;
    }
    if (heldWaiting) requestSocketWork(&serveAllHeld);
}

bool cancelParkedReceive(uint64_t token) {
    for (auto& kv : udpTables().sockets) {
        auto& q = kv.second.parkedReceives;
        auto it = std::find(q.begin(), q.end(), token);
        if (it == q.end()) continue;
        q.erase(it);
        if (kv.second.handler && !kv.second.closed) {
            auto h = kv.second.handler;
            reactor().submit([h] { h->addCredit(-1); });
        }
        return true;
    }
    return false;
}

// ---------------------------------------------------------------------------
// Kernel bodies
// ---------------------------------------------------------------------------

// udpBind : ( String, Int ) -> ( Bool, Bool, Bool ) -> Task FErr UdpT
// Payload: tuple2( boxed ( address, port ), boxed ( reuseAddress, broadcast, ipv6Only ) ), mask 0.
HPointer udpBindBody(HPointer captured, HPointer resume) {
    uint64_t token = 0;
    bool counted = false;
    ECO_SYSTEM_ASYNC_GUARD(FErr, resume, token, counted,
        std::string address;
        int64_t port = 0;
        bool reuseAddress = false, broadcast = false, ipv6Only = false;
        {   // no allocation in this scope
            Tuple2* p = asTuple2(captured);
            HPointer target = p->a.p;
            HPointer settings = p->b.p;
            readHostPort(target, address, port);
            Tuple3* st = asTuple3(settings);
            reuseAddress = isElmTrue(st->a.p);
            broadcast = isElmTrue(st->b.p);
            ipv6Only = isElmTrue(st->c.p);
        }
        ensureUdpTables();
        // Without the reactor the socket's handler would never run: a receive would park for ever (SOCK-15).
        if (!socketIoAvailable()) return resumeNow(resume, socketIoUnavailable("bind"));
        auto& s = Scheduler::instance();
        token = s.parkResume(resume, HoldKind::Task, "Udp.bind");
        counted = true;
        SysWorkPool::instance().submit(
            token,
            [address = std::move(address), port, reuseAddress, broadcast, ipv6Only]() -> PoolResult {
                return PoolResult::of(udpBindOn(address, port, reuseAddress, broadcast, ipv6Only));
            },
            &udpBindComplete, ErrShape::FErr);
        return alloc::unit();
    )
}

// udpSend : ( String, Int ) -> Bytes -> Int -> Task FErr ()
// Payload: tuple3( boxed to, boxed data, Int socketId ), mask 0x10 (slot 2 unboxed).
HPointer udpSendBody(HPointer captured, HPointer resume) {
    uint64_t token = 0;
    bool counted = false;
    ECO_SYSTEM_ASYNC_GUARD(FErr, resume, token, counted,
        std::string address, data;
        int64_t port = 0, id = 0;
        {   // no allocation in this scope
            Tuple3* p = asTuple3(captured);
            HPointer to = p->a.p;
            HPointer bytes = p->b.p;
            id = slotInt(p->c, p->header.unboxed, 2);
            readHostPort(to, address, port);
            data = toStdBytes(bytes);
        }
        ensureUdpTables();
        UdpEntry* e = findUdp(id);
        if (!e || e->closed || !e->handler)
            return resumeNow(resume, failFErr("ECANCELED", "send ECANCELED " + hostPort(address, port)));
        auto h = e->handler;
        uint64_t tok = startOp(resume, token, counted, "Udp.send");
        bool queued = reactor().submit([h, tok, address = std::move(address), port, data = std::move(data)]() mutable {
            h->send(tok, std::move(address), port, std::move(data));
        });
        if (!queued) throw std::runtime_error("send: socket IO unavailable");   // the guard fails the Task
        return alloc::unit();
    )
}

// udpReceive : Int -> Task FErr DgramT. Payload: the boxed socket id.
HPointer udpReceiveBody(HPointer captured, HPointer resume) {
    uint64_t token = 0;
    bool counted = false;
    ECO_SYSTEM_ASYNC_GUARD(FErr, resume, token, counted,
        int64_t id = payloadInt(captured);
        ensureUdpTables();
        UdpEntry* e = findUdp(id);
        if (!e || e->closed) return resumeNow(resume, failFErr("ECANCELED", "receive ECANCELED"));
        if (!e->held.empty()) {
            SocketEvent ev = std::move(e->held.front());
            e->held.pop_front();
            HPointer task = alloc::listNil();
            Elm::StackRootGuard g(&task);
            task = buildDgramT(ev);
            task = succeed(task);
            return resumeNow(resume, task);
        }
        token = Scheduler::instance().parkResume(resume, HoldKind::Task, "Udp.receive");
        counted = true;
        // The kill handle is made before the token is queued: it allocates, and if it throws, the token
        // asyncFailure completes is not left in the queue.
        HPointer kill = makeKillHandle(token, &cancelParkedReceive);
        e = findUdp(id);
        e->parkedReceives.push_back(token);
        auto h = e->handler;
        if (h) reactor().submit([h] { h->addCredit(1); });
        return kill;
    )
}

// udpClose : Int -> Task Never (). Payload: the boxed socket id.
HPointer udpCloseBody(HPointer captured) {
    ECO_SYSTEM_BODY_GUARD(Never,
        int64_t id = payloadInt(captured);
        ensureUdpTables();
        UdpEntry* e = findUdp(id);
        if (!e || e->closed) return succeedUnit();
        e->closed = true;
        std::deque<uint64_t> parked;
        parked.swap(e->parkedReceives);
        e->held.clear();
        if (auto h = e->handler) reactor().submit([h] { h->close(); });   // the subscription hold is released later
        // `e` is not used past here: the resumes below can run Elm code, which may change the table.
        auto& s = Scheduler::instance();
        for (uint64_t t : parked) {
            HoldRelease receiveHold(t);
            HPointer r = s.takePendingResume(t);
            if (alloc::isNil(r)) continue;
            HPointer task = alloc::listNil();
            Elm::StackRootGuard g(&r, &task);
            task = failFErr("ECANCELED", "receive ECANCELED");
            Scheduler::callClosure1(r, task);
        }
        return succeedUnit();
    )
}

// udpMembership : Bool -> String -> String -> Int -> Task FErr ()
// Payload: tuple2( boxed ( join, group, iface ), Int socketId ), mask 0x4 (slot 1 unboxed).
HPointer udpMembershipBody(HPointer captured, HPointer resume) {
    uint64_t token = 0;
    bool counted = false;
    ECO_SYSTEM_ASYNC_GUARD(FErr, resume, token, counted,
        bool join = false;
        std::string group, iface;
        int64_t id = 0;
        {   // no allocation in this scope
            Tuple2* p = asTuple2(captured);
            HPointer args = p->a.p;
            id = slotInt(p->b, p->header.unboxed, 1);
            Tuple3* a = asTuple3(args);
            join = isElmTrue(a->a.p);
            HPointer g = a->b.p;
            HPointer i = a->c.p;
            group = toStdString(g);
            iface = toStdString(i);
        }
        ensureUdpTables();
        UdpEntry* e = findUdp(id);
        if (!e || e->closed || !e->handler) {
            std::string code = "ECANCELED";
            return resumeNow(resume, failFErr(code, std::string(join ? "addMembership " : "dropMembership ") + code));
        }
        auto h = e->handler;
        uint64_t tok = startOp(resume, token, counted, "Udp.membership");
        bool queued = reactor().submit([h, tok, join, group = std::move(group), iface = std::move(iface)]() mutable {
            h->membership(tok, join, std::move(group), std::move(iface));
        });
        if (!queued) throw std::runtime_error("membership: socket IO unavailable");   // the guard fails the Task
        return alloc::unit();
    )
}

} // namespace Eco::System
