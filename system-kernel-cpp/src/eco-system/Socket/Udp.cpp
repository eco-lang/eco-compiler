//===- Udp.cpp - UDP sockets on the IoReactor -----------------------------===//
//
// See Udp.hpp (plans/eco-system-sockets.md §3.3.5, §3.3.7, §3.3.8, §3.4,
// Appendix B.2, §D.4).
//
//   * udpBind (P, T2): udpBindOn on the SysWorkPool (socket, options, bind;
//     the result owns the fd through RAII, N11); the completion hands the
//     fd to a new UdpHandler, records the UdpEntry and takes the bound
//     socket's pendingAsync count (§3.3.8).
//   * udpSend / udpMembership (R): pendingAsync + submit + OpDone (released
//     by SocketTables.cpp's OpDone dispatcher).
//   * udpReceive (A): a held datagram at once (§3.4), else parked on the
//     entry with one credit; kill handle cancelParkedReceive (returns the
//     credit; no count of its own).
//   * udpClose (S): idempotent; marks the entry closed, fails the parked
//     receives ECANCELED, drops the held datagrams and submits close(); the
//     count is released by the UdpClosed drain.
//
// Every body follows G2/G3: copy the inputs out of the heap first, then act,
// then allocate. Error messages follow Node (§D.5): "bind <CODE> addr:port",
// "send <CODE> addr:port", "addMembership <CODE>", "dropMembership <CODE>";
// operations on a closed socket fail ECANCELED.
//
// Templates used: T1 (udpClose), T2 (bind + completion), T5 (table), T7
// (receive kill handle), T8 (delivery via UdpManager.cpp), T9/G10
// (completions, AsyncRelease), G12 (drain per delivery).
//
//===----------------------------------------------------------------------===//

#include "eco-system/Socket/Udp.hpp"

#include "eco-system/Core/AsyncRelease.hpp"
#include "eco-system/Core/SysWorkPool.hpp"
#include "eco-system/Socket/SocketTables.hpp"

#include <algorithm>
#include <cerrno>
#include <cstring>
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

IoReactor& reactor() { return IoReactor::instance(); }

void closeQuietly(int fd) {
#ifndef _WIN32
    if (fd >= 0) (void)::close(fd);
#else
    (void)fd;
#endif
}

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
    // Only reachable with an open fd if start() never ran (a registered
    // handler is kept alive by its reactor slot until close()).
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
    if (e != 0 && !backoff_) {   // cannot watch the fd now: retry later
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
            // EINTR, and ICMP errors some systems queue on a UDP socket: retry.
            if (e == EINTR || e == ECONNREFUSED || e == ECONNRESET || e == EHOSTUNREACH ||
                e == ENETUNREACH)
                continue;
            // Anything else (ENOMEM, ENOBUFS, ...): back off instead of
            // spinning on a level-triggered fd (N9).
            backoff_ = true;
            reactor().setTimer(key(), reactor().nowMs() + kBackoffMs);
            return;
        }
        if (mh.msg_flags & MSG_TRUNC) continue;   // larger than any datagram we accept: drop
        from.len = mh.msg_namelen;
        SocketEvent ev;
        ev.kind = SocketEvent::Kind::Datagram;
        ev.gen = gen_;
        ev.ownerId = socketId_;
        if (!sockaddrToInet(from, ev.remote.text, ev.remote.port)) {
            ev.remote.text = isV6_ ? "::" : "0.0.0.0";   // §3.2 fallback (should not happen)
            ev.remote.port = 0;
        }
        ev.data.assign(buf_.data(), static_cast<size_t>(n));
        if (credit_ > 0) --credit_;   // consumed (unlimited while subscribed)
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
            if (e == EAGAIN || e == EWOULDBLOCK) return;   // write interest (updateInterest)
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
        // §D.4: an IPv4 destination on an IPv6 socket goes to ::ffff:a.b.c.d
        // (an ipv6Only socket then fails as the kernel reports); an IPv6
        // destination on an IPv4 socket fails EAFNOSUPPORT.
        if (r.to.family() == AF_INET6 && !isV6_) e = EAFNOSUPPORT;
        else if (r.to.family() == AF_INET && isV6_) (void)mapIPv4ToIPv6(r.to);
    }
    if (e != 0) {
        postOpDone(token, e, "send", what);
        return;
    }
    bool idle = sendQ_.empty();
    sendQ_.push_back(std::move(r));
    if (idle) serviceSends();   // in order behind any send waiting for EAGAIN
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
        // The interface: the scope of the interface address (its address
        // bits are ignored, Appendix A), else the group's own scope, else 0.
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
    if (closed_) return;   // one UdpClosed per socket
    closed_ = true;
    std::deque<SendReq> q;
    q.swap(sendQ_);
    for (auto& r : q) postOpDone(r.token, ECANCELED, "send", r.what);
    if (key() != 0) reactor().remove(key());   // remove before close (rule 3)
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
        // Explicit: Linux's default comes from net.ipv6.bindv6only.
        int v6 = ipv6Only ? 1 : 0;
        (void)::setsockopt(r.fd, IPPROTO_IPV6, IPV6_V6ONLY, &v6, sizeof(v6));
    }
    // Buffer sizes >= 65 536 so a maximal datagram fits (macOS's default
    // maxdgram is 9 216, N15). Only ever raised.
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
// Main-thread table, values and delivery
// ---------------------------------------------------------------------------

namespace {

// A dead heap's entries: close their handlers (their counts and tokens died
// with the heap; the UdpClosed events are a dead heap's and are dropped).
void resetTables(UdpTables& t) {
    for (auto& kv : t.sockets) {
        if (auto h = kv.second.handler) reactor().submit([h] { h->close(); });
    }
    t.sockets.clear();
}

// UdpT ( socketId, ( address, port ) ), masks 0x1 / 0x4.
HPointer buildUdpT(int64_t id, const SockEndpoint& ep) {
    HPointer inner = alloc::listNil();
    Elm::StackRootGuard g(&inner);
    HPointer text = alloc::allocStringFromUTF8(ep.text);
    // Fresh result passed directly into the helper (it roots its arguments, G4).
    inner = alloc::tuple2(alloc::boxed(text), alloc::unboxedInt(ep.port), 0x4);
    return alloc::tuple2(alloc::unboxedInt(id), alloc::boxed(inner), 0x1);
}

// DgramT ( data, ( fromAddress, fromPort ) ), masks 0 / 0x4.
HPointer buildDgramT(const SocketEvent& ev) {
    HPointer data = alloc::listNil();
    HPointer from = alloc::listNil();
    Elm::StackRootGuard g(&data, &from);
    {
        // T4/G8: fill right after the allocation (n == 0 gives emptyBytes()).
        alloc::BlankByteBuffer bb = alloc::allocByteBufferBlank(ev.data.size());
        if (!ev.data.empty()) std::memcpy(bb.bytes, ev.data.data(), ev.data.size());
        data = bb.hp;
    }
    HPointer text = alloc::allocStringFromUTF8(ev.remote.text);
    from = alloc::tuple2(alloc::boxed(text), alloc::unboxedInt(ev.remote.port), 0x4);
    return alloc::tuple2(alloc::boxed(data), alloc::boxed(from), 0);
}

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

// Serves the held FIFO of socket `id` while it has a consumer (§3.4): the
// oldest parked receive first, else the subscribers. Each delivery resumes
// or sends, then drains (G12).
void serveHeld(int64_t id) {
    auto& sched = Scheduler::instance();
    for (;;) {
        UdpEntry* e = findUdp(id);
        if (!e || e->closed || e->held.empty()) return;
        if (!e->parkedReceives.empty()) {
            uint64_t token = e->parkedReceives.front();
            e->parkedReceives.pop_front();
            HPointer resume = sched.takePendingResume(token);
            if (alloc::isNil(resume)) continue;   // killed (its cancel already ran)
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
        udpManagerDeliver(id, dgram);   // sendToApp + drain per tagger
    }
}

// Deferred work (requestSocketWork): serve every socket's held FIFO.
void serveAllHeld() {
    std::vector<int64_t> ids;
    for (auto& kv : udpTables().sockets) {
        if (!kv.second.held.empty()) ids.push_back(kv.first);
    }
    std::sort(ids.begin(), ids.end());   // POD ids (G15 is about HPointers)
    for (int64_t id : ids) serveHeld(id);
}

// --- Event dispatchers (SocketEvents.cpp drain) ------------------------------

bool onDatagram(SocketEvent& ev) {
    UdpEntry* e = findUdp(ev.ownerId);
    if (!e || e->closed) return false;   // closed: dropped
    int64_t id = ev.ownerId;
    e->held.push_back(std::move(ev));    // in order behind anything held earlier
    while (e->held.size() > kMaxHeldDatagrams) e->held.pop_front();   // drop the oldest
    serveHeld(id);                       // drains per delivery itself
    return false;
}

bool onUdpClosed(SocketEvent& ev) {
    UdpEntry* e = findUdp(ev.ownerId);
    if (!e) return false;
    UdpEntry entry = std::move(*e);
    udpTables().sockets.erase(ev.ownerId);
    AsyncRelease socketCount(entry.counted);   // the bound socket's count, once
    bool resumed = false;
    for (uint64_t token : entry.parkedReceives) {   // closeAll path: nobody failed them yet
        resumed |= resumeFail(token, "ECANCELED", "receive ECANCELED");
    }
    return resumed;
}

// T2 completion (main thread).
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
    e.counted = true;
    t.sockets.emplace(id, std::move(e));
    // A bound socket keeps the program alive until closed (§3.3.8).
    Scheduler::instance().incrementPendingAsync();
    reactor().submit([h] { h->start(); });
    HPointer ut = buildUdpT(id, r.bound);
    return succeed(ut);
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

// ( address, port ) from an Elm tuple2 (String, Int).
void readHostPort(HPointer tuple, std::string& address, int64_t& port) {
    Tuple2* t = asTuple2(tuple);
    HPointer addr = t->a.p;
    port = slotInt(t->b, t->header.unboxed, 1);
    address = toStdString(addr);
}

// R mode: registers `resume`, takes the operation's count and returns the
// token (G10). The caller submits the work.
uint64_t startOp(HPointer& resume, uint64_t& token, bool& counted) {
    auto& s = Scheduler::instance();
    token = s.registerPendingResume(resume);
    s.incrementPendingAsync();
    counted = true;
    return token;
}

} // namespace

UdpTables& udpTables() {
    static auto* t = new UdpTables();   // leaky (§3.4)
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
    ensureSocketTables();   // the OpDone dispatcher and the event queue
    static bool done = false;   // main thread only
    if (done) return;
    done = true;
    setSocketEventDispatch(SocketEvent::Kind::Datagram, &onDatagram);
    setSocketEventDispatch(SocketEvent::Kind::UdpClosed, &onUdpClosed);
}

void udpTablesSyncSubscriptions() {
    bool heldWaiting = false;
    for (auto& kv : udpTables().sockets) {
        UdpEntry& e = kv.second;
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
            reactor().submit([h] { h->addCredit(-1); });   // return the credit
        }
        break;
    }
    return false;   // A mode: no count of its own (§3.3.8)
}

// ---------------------------------------------------------------------------
// Kernel bodies
// ---------------------------------------------------------------------------

// udpBind : ( String, Int ) -> ( Bool, Bool, Bool ) -> Task FErr UdpT
// payload tuple2( boxed target, boxed settings ), mask 0.
HPointer udpBindBody(HPointer captured, HPointer resume) {
    uint64_t token = 0;
    bool counted = false;
    ECO_SYSTEM_ASYNC_GUARD(FErr, resume, token, counted,
        std::string address;
        int64_t port = 0;
        bool reuseAddress = false, broadcast = false, ipv6Only = false;
        {   // G3/G5: no allocation in this scope
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
        auto& s = Scheduler::instance();
        token = s.registerPendingResume(resume);
        s.incrementPendingAsync();
        counted = true;
        SysWorkPool::instance().submit(
            token,
            [address = std::move(address), port, reuseAddress, broadcast, ipv6Only]() -> PoolResult {
                return PoolResult::of(udpBindOn(address, port, reuseAddress, broadcast, ipv6Only));
            },
            &udpBindComplete, ErrShape::FErr);
        return alloc::unit();   // short job; an orphaned result closes its fd (RAII)
    )
}

// udpSend : ( String, Int ) -> Bytes -> Int -> Task FErr ()
// payload tuple3( boxed to, boxed data, Int socketId ), mask 0x10.
HPointer udpSendBody(HPointer captured, HPointer resume) {
    uint64_t token = 0;
    bool counted = false;
    ECO_SYSTEM_ASYNC_GUARD(FErr, resume, token, counted,
        std::string address, data;
        int64_t port = 0, id = 0;
        {   // G3/G5
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
        uint64_t tok = startOp(resume, token, counted);
        reactor().submit([h, tok, address = std::move(address), port, data = std::move(data)]() mutable {
            h->send(tok, std::move(address), port, std::move(data));
        });
        return alloc::unit();
    )
}

// udpReceive : Int -> Task FErr DgramT — payload: boxed socket id.
HPointer udpReceiveBody(HPointer captured, HPointer resume) {
    uint64_t token = 0;
    bool counted = false;
    ECO_SYSTEM_ASYNC_GUARD(FErr, resume, token, counted,
        int64_t id = payloadInt(captured);
        ensureUdpTables();
        UdpEntry* e = findUdp(id);
        if (!e || e->closed) return resumeNow(resume, failFErr("ECANCELED", "receive ECANCELED"));
        if (!e->held.empty()) {   // held items first (§3.4)
            SocketEvent ev = std::move(e->held.front());
            e->held.pop_front();
            HPointer task = alloc::listNil();
            Elm::StackRootGuard g(&task);
            task = buildDgramT(ev);
            task = succeed(task);
            return resumeNow(resume, task);
        }
        token = Scheduler::instance().registerPendingResume(resume);
        e->parkedReceives.push_back(token);
        auto h = e->handler;
        if (h) reactor().submit([h] { h->addCredit(1); });
        return makeKillHandle(token, &cancelParkedReceive);
    )
}

// udpClose : Int -> Task Never () — payload: boxed socket id.
HPointer udpCloseBody(HPointer captured) {
    ECO_SYSTEM_BODY_GUARD(Never,
        int64_t id = payloadInt(captured);
        ensureUdpTables();
        UdpEntry* e = findUdp(id);
        if (!e || e->closed) return succeedUnit();   // closed already: idempotent
        e->closed = true;
        std::deque<uint64_t> parked;
        parked.swap(e->parkedReceives);
        e->held.clear();   // undelivered datagrams are dropped
        if (auto h = e->handler) reactor().submit([h] { h->close(); });   // UdpClosed releases the count
        // Parked receives fail now (they hold no count). Allocates: `e` is dead.
        auto& s = Scheduler::instance();
        for (uint64_t t : parked) {
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
// payload tuple2( boxed ( join, group, iface ), Int socketId ), mask 0x4.
HPointer udpMembershipBody(HPointer captured, HPointer resume) {
    uint64_t token = 0;
    bool counted = false;
    ECO_SYSTEM_ASYNC_GUARD(FErr, resume, token, counted,
        bool join = false;
        std::string group, iface;
        int64_t id = 0;
        {   // G3/G5
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
        uint64_t tok = startOp(resume, token, counted);
        reactor().submit([h, tok, join, group = std::move(group), iface = std::move(iface)]() mutable {
            h->membership(tok, join, std::move(group), std::move(iface));
        });
        return alloc::unit();
    )
}

} // namespace Eco::System
