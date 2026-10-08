//===- ConnChannel.cpp - The two stream faces of a connection -------------===//
//
// See ConnChannel.hpp (plans/eco-system-sockets.md §3.3.3 "Faces"). Main
// thread only; every operation is a reactor submit (POD + shared_ptr<Conn>,
// G1). shutdown() is idempotent (ByteChannel contract): the stream table may
// call it more than once.
//
// Templates used: T9 (requests).
//
//===----------------------------------------------------------------------===//

#include "eco-system/Socket/ConnChannel.hpp"

#include "eco-system/Socket/SocketTables.hpp"

#include <cerrno>
#include <utility>

namespace Eco::System {

namespace {

IoReactor& reactor() { return IoReactor::instance(); }

void postUnsupported(uint64_t channelId, uint64_t token, ChannelResult::Op op) {
    ChannelResult r;
    r.channelId = channelId;
    r.token = token;
    r.op = op;
    r.err = ENOTSUP;
    postChannelResult(std::move(r));
}

} // namespace

// --- Read face -------------------------------------------------------------------

ConnReadFace::ConnReadFace(std::shared_ptr<Conn> conn, int64_t connId)
    : conn_(std::move(conn)), connId_(connId) {}

ConnReadFace::~ConnReadFace() {
    if (!done_) shutdown();
    socketTablesFaceGone(connId_);
}

void ConnReadFace::requestRead(uint64_t token, size_t maxBytes) {
    auto c = conn_;
    uint64_t chan = id();
    reactor().submit([c, chan, token, maxBytes] { c->reqRead(chan, token, maxBytes); });
}

void ConnReadFace::requestWrite(uint64_t token, std::string) {
    postUnsupported(id(), token, ChannelResult::Op::Write);
}

void ConnReadFace::close(uint64_t token) {
    done_ = true;
    auto c = conn_;
    uint64_t chan = id();
    reactor().submit([c, chan, token] { c->reqCloseRead(chan, token); });
}

void ConnReadFace::shutdown() {
    if (done_) return;
    done_ = true;
    auto c = conn_;
    reactor().submit([c] { c->readFaceShutdown(); });
}

// --- Write face ------------------------------------------------------------------

ConnWriteFace::ConnWriteFace(std::shared_ptr<Conn> conn, int64_t connId)
    : conn_(std::move(conn)), connId_(connId) {}

ConnWriteFace::~ConnWriteFace() {
    if (!done_) shutdown();
    socketTablesFaceGone(connId_);
}

void ConnWriteFace::requestRead(uint64_t token, size_t) {
    postUnsupported(id(), token, ChannelResult::Op::Read);
}

void ConnWriteFace::requestWrite(uint64_t token, std::string bytes) {
    auto c = conn_;
    uint64_t chan = id();
    reactor().submit([c, chan, token, b = std::move(bytes)]() mutable {
        c->reqWrite(chan, token, std::move(b));
    });
}

void ConnWriteFace::close(uint64_t token) {
    done_ = true;
    auto c = conn_;
    uint64_t chan = id();
    reactor().submit([c, chan, token] { c->reqCloseWrite(chan, token); });
}

void ConnWriteFace::shutdown() {
    if (done_) return;
    done_ = true;
    auto c = conn_;
    reactor().submit([c] { c->writeFaceShutdown(); });
}

} // namespace Eco::System
