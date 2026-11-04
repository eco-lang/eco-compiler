//===- Listener.cpp - A listening stream socket on the IoReactor ----------===//

#include "eco-system/Socket/Listener.hpp"

#include "eco-system/Core/SocketUtil.hpp"

#include <algorithm>
#include <cerrno>
#include <utility>

#ifndef _WIN32
#include <unistd.h>
#endif

namespace Eco::System {

namespace {

/// Returns the shared reactor.
IoReactor& reactor() { return IoReactor::instance(); }

/// Closes `fd` if it is not negative, and unlinks `path` if `ownsPath` is set and `path` is not empty. Does nothing on
/// Windows.
void closeFdAndPath(int fd, bool ownsPath, const std::string& path) {
#ifndef _WIN32
    if (fd >= 0) (void)::close(fd);
    if (ownsPath && !path.empty()) (void)::unlink(path.c_str());
#else
    (void)fd; (void)ownsPath; (void)path;
#endif
}

} // namespace

ListenerHandler::ListenerHandler(int fd, int64_t listenerId, uint64_t gen, bool isUnix,
                                 std::string unixPath, bool ownsPath, TransportFactory factory)
    : fd_(fd), listenerId_(listenerId), gen_(gen), isUnix_(isUnix), unixPath_(std::move(unixPath)),
      ownsPath_(ownsPath), factory_(std::move(factory)) {}

ListenerHandler::~ListenerHandler() {
    // Only reachable with an open fd if the listener was never registered.
    if (fd_ >= 0 && key() == 0) closeFdAndPath(fd_, ownsPath_, unixPath_);
}

void ListenerHandler::start() {
    if (closed_ || key() != 0) return;
    auto self = std::static_pointer_cast<ListenerHandler>(shared_from_this());
    if (reactor().add(self, fd_) == 0) return;
    updateInterest();
}

void ListenerHandler::setCallbackMode(ProtocolFactory factory, int64_t maxConnections) {
    protocolFactory_ = std::move(factory);
    maxConnections_ = maxConnections;
}

bool ListenerHandler::canAccept() const {
    if (closed_ || backoff_ || handshaking_.size() >= static_cast<size_t>(kMaxHandshakes)) {
        return false;
    }
    if (protocolFactory_) return maxConnections_ < 0 || open_ < maxConnections_;
    return unlimited_ || credit_ > 0;
}

void ListenerHandler::connClosed() {
    if (open_ > 0) --open_;
    updateInterest();
}

void ListenerHandler::updateInterest() {
    if (key() == 0 || closed_) return;
    int e = reactor().setInterest(key(), canAccept(), false);
    if (e != 0 && !backoff_) {   // cannot watch the fd now: retry later
        backoff_ = true;
        reactor().setTimer(key(), reactor().nowMs() + kBackoffMs);
    }
}

void ListenerHandler::addCredit(int64_t n) {
    if (closed_) return;
    credit_ += n;
    if (credit_ < 0) credit_ = 0;
    updateInterest();
}

void ListenerHandler::setUnlimited(bool on) {
    if (closed_) return;
    unlimited_ = on;
    updateInterest();
}

void ListenerHandler::acceptLoop() {
#ifndef _WIN32
    while (canAccept()) {
        int err = 0;
        int cfd = acceptCloexec(fd_, /*nonBlocking=*/true, nullptr, nullptr, &err);
        if (cfd < 0) {
            if (err == EAGAIN || err == EWOULDBLOCK) return;
            if (err == ECONNABORTED || err == EINTR || err == EPROTO) continue;
            // EMFILE, ENFILE, ENOBUFS, ENOMEM, or anything unexpected: pause rather than spin on a
            // level-triggered fd that stays readable.
            backoff_ = true;
            reactor().setTimer(key(), reactor().nowMs() + kBackoffMs);
            return;
        }
        bool reserved = false;
        if (!protocolFactory_ && credit_ > 0) {
            --credit_;
            reserved = true;
        }
        std::unique_ptr<Transport> t = factory_ ? factory_(cfd, true) : nullptr;
        auto c = Conn::makeAccepted(cfd, isUnix_, std::move(t));   // owns cfd
        if (reactor().add(c, cfd) == 0) {
            if (reserved) ++credit_;
            continue;   // c's destructor closes cfd
        }
        handshaking_.push_back(Handshake{c, reserved});
        auto self = std::static_pointer_cast<ListenerHandler>(shared_from_this());
        if (protocolFactory_) {
            // Counted as open until the fd closes; a failed handshake closes it too.
            ++open_;
            std::weak_ptr<ListenerHandler> weak = self;
            c->addCloseHook([weak](Conn&) {
                if (auto l = weak.lock()) l->connClosed();
            });
        }
        int64_t deadline = factory_ ? reactor().nowMs() + kHandshakeTimeoutMs : 0;
        c->beginServer(deadline, [self](Conn& conn, bool ok) { self->established(conn, ok); });
    }
#endif
}

void ListenerHandler::established(Conn& c, bool ok) {
    auto it = std::find_if(handshaking_.begin(), handshaking_.end(),
                           [&c](const Handshake& h) { return h.conn.get() == &c; });
    if (it == handshaking_.end()) {   // closed meanwhile
        c.abort(false);
        return;
    }
    Handshake h = std::move(*it);
    handshaking_.erase(it);
    if (closed_) {
        c.abort(false);
        return;
    }
    if (!ok) {
        if (h.reserved) ++credit_;
        c.abort(false);
        updateInterest();
        return;
    }
    if (protocolFactory_) {
        std::unique_ptr<ConnProtocol> p = protocolFactory_(c);
        if (!p) {
            c.abort(false);
        } else {
            c.setProtocol(std::move(p), std::string());
        }
        updateInterest();
        return;
    }
    SocketEvent ev;
    ev.kind = SocketEvent::Kind::Accepted;
    ev.gen = gen_;
    ev.ownerId = listenerId_;
    ev.conn = h.conn;
    c.describe(ev, unixPath_);
    postSocketEvent(std::move(ev));
    updateInterest();
}

void ListenerHandler::onReady(bool, bool, bool) {
    if (closed_) return;
    acceptLoop();
    updateInterest();
}

void ListenerHandler::onTimer() {
    if (closed_) return;
    backoff_ = false;
    updateInterest();
}

void ListenerHandler::close() { closeNow(/*post=*/true); }

void ListenerHandler::onCloseAll() { closeNow(/*post=*/true); }

void ListenerHandler::closeNow(bool post) {
    if (!closed_) {
        closed_ = true;
        std::vector<Handshake> hs;
        hs.swap(handshaking_);
        for (auto& h : hs) h.conn->abort(false);
        if (key() != 0) reactor().remove(key());   // the reactor requires removal before the fd is closed
        closeFdAndPath(fd_, ownsPath_, unixPath_);
        fd_ = -1;
        ownsPath_ = false;
    }
    if (!post || protocolFactory_) return;
    // Posted only after the fd is closed and the path unlinked, so the address is free when it arrives.
    SocketEvent ev;
    ev.kind = SocketEvent::Kind::ListenerClosed;
    ev.gen = gen_;
    ev.ownerId = listenerId_;
    postSocketEvent(std::move(ev));
}

} // namespace Eco::System
