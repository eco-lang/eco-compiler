//===- WsChannel.cpp - The two stream faces of a WebSocket ----------------===//
//
// See WsChannel.hpp (plans/eco-system-websockets.md §3.3, §3.6). Main thread
// only; every operation is a reactor submit (POD + shared_ptr<WsCore>, G1).
// shutdown() is idempotent (ByteChannel contract).
//
// Templates used: T9 (requests).
//
//===----------------------------------------------------------------------===//

#include "eco-system/WebSocket/WsChannel.hpp"

#include "eco-system/Core/IoReactor.hpp"
#include "eco-system/WebSocket/WsTables.hpp"

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

WsReadChannel::WsReadChannel(std::shared_ptr<WsCore> core, int64_t wsId)
    : core_(std::move(core)), wsId_(wsId) {}

WsReadChannel::~WsReadChannel() {
    if (!done_) shutdown();
    wsTablesFaceGone(wsId_);
}

void WsReadChannel::requestRead(uint64_t token, size_t) {
    auto k = core_;
    uint64_t chan = id();
    reactor().submit([k, chan, token] { k->reqRead(chan, token); });
}

void WsReadChannel::requestWrite(uint64_t token, std::string) {
    postUnsupported(id(), token, ChannelResult::Op::Write);
}

void WsReadChannel::close(uint64_t token) {
    done_ = true;
    auto k = core_;
    uint64_t chan = id();
    reactor().submit([k, chan, token] { k->readClose(chan, token); });
}

void WsReadChannel::shutdown() {
    if (done_) return;
    done_ = true;
    auto k = core_;
    reactor().submit([k] { k->readShutdown(); });
}

// --- Write face ------------------------------------------------------------------

WsWriteChannel::WsWriteChannel(std::shared_ptr<WsCore> core, int64_t wsId)
    : core_(std::move(core)), wsId_(wsId) {}

WsWriteChannel::~WsWriteChannel() { wsTablesFaceGone(wsId_); }

void WsWriteChannel::requestRead(uint64_t token, size_t) {
    postUnsupported(id(), token, ChannelResult::Op::Read);
}

void WsWriteChannel::requestWrite(uint64_t token, std::string bytes) {
    requestWriteTagged(token, 2, false, std::move(bytes));
}

void WsWriteChannel::requestWriteTagged(uint64_t token, int64_t tag, bool text, std::string bytes) {
    auto k = core_;
    uint64_t chan = id();
    reactor().submit([k, chan, token, tag, text, b = std::move(bytes)]() mutable {
        k->reqWrite(chan, token, tag, text, std::move(b));
    });
}

void WsWriteChannel::close(uint64_t token) {
    done_ = true;
    wsTablesCloseStarted(wsId_);
    auto k = core_;
    uint64_t chan = id();
    reactor().submit([k, chan, token] { k->writeClose(chan, token); });
}

void WsWriteChannel::shutdown() {
    if (done_) return;
    done_ = true;
    wsTablesCloseStarted(wsId_);   // released by Closed (no-op if it is closed already)
    auto k = core_;
    reactor().submit([k] { k->writeShutdown(); });
}

// --- A streamed message's body (WS6) ---------------------------------------------

WsBodyChannel::WsBodyChannel(std::shared_ptr<WsCore> core, uint64_t seq)
    : core_(std::move(core)), seq_(seq) {}

void WsBodyChannel::requestRead(uint64_t token, size_t) {
    auto k = core_;
    uint64_t chan = id(), seq = seq_;
    reactor().submit([k, seq, chan, token] { k->bodyReqRead(seq, chan, token); });
}

void WsBodyChannel::requestWrite(uint64_t token, std::string) {
    postUnsupported(id(), token, ChannelResult::Op::Write);
}

void WsBodyChannel::close(uint64_t token) {
    done_ = true;
    auto k = core_;
    uint64_t chan = id();
    reactor().submit([k, chan, token] { k->bodyClose(chan, token); });
}

void WsBodyChannel::shutdown() {
    if (done_) return;
    done_ = true;
    auto k = core_;
    uint64_t seq = seq_;
    reactor().submit([k, seq] { k->bodyCancel(seq); });
}

// --- An outgoing message stream (WS6) -----------------------------------------------

WsOutChannel::WsOutChannel(std::shared_ptr<WsCore> core, uint64_t seq)
    : core_(std::move(core)), seq_(seq) {}

WsOutChannel::~WsOutChannel() {
    // A stream dropped without close or shutdown (its pair erased): abort it,
    // so the messages behind it are not blocked forever.
    if (!done_) shutdown();
}

void WsOutChannel::requestRead(uint64_t token, size_t) {
    postUnsupported(id(), token, ChannelResult::Op::Read);
}

void WsOutChannel::requestWrite(uint64_t token, std::string bytes) {
    auto k = core_;
    uint64_t chan = id(), seq = seq_;
    reactor().submit([k, seq, chan, token, b = std::move(bytes)]() mutable {
        k->outWrite(seq, chan, token, std::move(b));
    });
}

void WsOutChannel::close(uint64_t token) {
    done_ = true;
    auto k = core_;
    uint64_t chan = id(), seq = seq_;
    reactor().submit([k, seq, chan, token] { k->outClose(seq, chan, token); });
}

void WsOutChannel::shutdown() {
    if (done_) return;
    done_ = true;
    auto k = core_;
    uint64_t seq = seq_;
    reactor().submit([k, seq] { k->outAbort(seq); });
}

} // namespace Eco::System
