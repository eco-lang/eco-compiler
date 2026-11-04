//===- H2StreamPort.cpp - A WebSocket over an HTTP/2 stream (RFC 8441) ----===//
//
// Re-entrancy: every tunnel call may run the h2 session at once and call back
// into this port (streamData, streamWritable, streamReset) and from there
// into the core. Entry points keep the port alive (shared_from_this) across
// such calls, input that arrives while the core runs is appended to in_ and
// delivered by the running loop, and once the stream is gone (gone_) no
// tunnel call is made.
//
//===----------------------------------------------------------------------===//

#include "eco-system/WebSocket/H2StreamPort.hpp"

#include "eco-system/Core/IoReactor.hpp"

#include <cassert>
#include <cerrno>

namespace Eco::System {

namespace {

/// Returns the process's reactor.
IoReactor& reactor() { return IoReactor::instance(); }

} // namespace

/// It refers to its port weakly, so a timer that fires after the port has been destroyed does nothing.
struct H2StreamPort::Timer final : IoHandler {
    std::weak_ptr<H2StreamPort> port;
    void onReady(bool, bool, bool) override {}
    void onTimer() override {
        if (auto p = port.lock()) p->fire();
    }
    void onCloseAll() override {
        if (key() != 0) reactor().remove(key());
    }
};

H2StreamPort::~H2StreamPort() {
    if (timer_ && timer_->key() != 0) reactor().remove(timer_->key());
    core_->detachPort(this);
    if (bound_ && !gone_) core_->portClosed();
}

void H2StreamPort::bind(H2Tunnel* tunnel, std::string buffered) {
    auto self = shared_from_this();
    if (!gone_ && tunnel) tunnel_ = tunnel;
    if (!tunnel) gone_ = true;
    in_.insert(0, buffered);
    bound_ = true;
    core_->attach(this);
    if (gone_) {
        in_.clear();
        core_->portClosed();
        return;
    }
    deliver();
}

// What a paused codec does not take stays in in_, unconsumed, which is what holds the peer back.
void H2StreamPort::deliver() {
    if (delivering_ || !bound_ || gone_) return;
    delivering_ = true;
    auto self = shared_from_this();
    while (!gone_ && !in_.empty() && core_->wantsRead()) {
        std::string chunk;
        chunk.swap(in_);
        core_->portData(chunk.data(), chunk.size());
        if (tunnel_ && !gone_) tunnel_->tunnelConsume(chunk.size());
    }
    if (!gone_ && in_.empty() && endPending_ && !eofGiven_) {
        eofGiven_ = true;
        core_->portEof();
    }
    delivering_ = false;
}

void H2StreamPort::streamData(std::string_view bytes) {
    if (gone_ || bytes.empty()) return;
    in_.append(bytes.data(), bytes.size());
    deliver();
}

void H2StreamPort::streamEnd() {
    if (gone_) return;
    endPending_ = true;
    deliver();
}

void H2StreamPort::streamReset(uint32_t code) {
    if (gone_) return;
    auto self = shared_from_this();
    if (code == 0) deliver();
    gone_ = true;
    tunnel_ = nullptr;
    in_.clear();
    for (int64_t& d : deadlines_) d = 0;
    if (timer_ && timer_->key() != 0) reactor().setTimer(timer_->key(), 0);
    if (bound_) core_->portClosed();
}

void H2StreamPort::streamWritable() {
    if (gone_ || !bound_) return;
    auto self = shared_from_this();
    core_->portWritable();
}

// --- WsPort --------------------------------------------------------------------------

void H2StreamPort::portWrite(std::string bytes, std::function<void(int)> done) {
    if (gone_ || ending_ || !tunnel_) {
        if (done) done(ECANCELED);
        return;
    }
    auto self = shared_from_this();
    bool ok = tunnel_->tunnelWrite(std::move(bytes));
    if (done) done(ok ? 0 : ECANCELED);
}

size_t H2StreamPort::portOutbound() const { return tunnel_ && !gone_ ? tunnel_->tunnelQueued() : 0; }

void H2StreamPort::portSetDeadline(int timerId, int64_t monoMs) {
    if (timerId < 0 || timerId >= Conn::kMaxTimers || timerId == Conn::kTimerDrain) return;
    if (gone_ && monoMs != 0) return;
    deadlines_[timerId] = monoMs > 0 ? monoMs : 0;
    armTimer();
}

void H2StreamPort::portUpdateInterest() { deliver(); }

void H2StreamPort::portCloseGraceful(int64_t drainMs) {
    if (gone_ || ending_) return;
    auto self = shared_from_this();
    ending_ = true;
    if (tunnel_) tunnel_->tunnelEnd();
    if (gone_) return;
    // Every caller passes WsCore::kDrainMs; the fallback only keeps a stray 0 from ending the drain at once.
    assert(drainMs > 0 && "portCloseGraceful: callers pass WsCore::kDrainMs");
    deadlines_[Conn::kTimerDrain] = reactor().nowMs() + (drainMs > 0 ? drainMs : WsCore::kDrainMs);
    armTimer();
}

void H2StreamPort::portAbort() {
    if (gone_) return;
    auto self = shared_from_this();
    if (H2Tunnel* t = tunnel_) t->tunnelReset(kCancel);
    streamReset(kCancel);   // does nothing if tunnelReset already reported the reset
}

// --- Timers -------------------------------------------------------------------------------

void H2StreamPort::armTimer() {
    int64_t earliest = 0;
    for (int64_t d : deadlines_) {
        if (d > 0 && (earliest == 0 || d < earliest)) earliest = d;
    }
    if (!timer_) {
        if (earliest == 0 || gone_) return;
        timer_ = std::make_shared<Timer>();
        timer_->port = weak_from_this();
        if (reactor().add(timer_, -1) == 0) {
            timer_.reset();
            return;
        }
    }
    if (timer_->key() != 0) reactor().setTimer(timer_->key(), earliest);
}

// Handles expired ids in deadline order, one per round, clearing each before it is handled. An id that an earlier
// handler re-arms for a later time is not handled in this call. The round limit bounds the loop if handlers keep
// re-arming ids that have already passed.
void H2StreamPort::fire() {
    auto self = shared_from_this();
    int64_t now = reactor().nowMs();
    for (int round = 0; round < 2 * Conn::kMaxTimers; ++round) {
        int id = -1;
        for (int i = 0; i < Conn::kMaxTimers; ++i) {
            if (deadlines_[i] > 0 && deadlines_[i] <= now && (id < 0 || deadlines_[i] < deadlines_[id])) id = i;
        }
        if (id < 0) break;
        deadlines_[id] = 0;
        if (gone_) continue;
        if (id == Conn::kTimerDrain) {
            // The stream was not closed within the drain time.
            portAbort();
        } else {
            core_->portTimer(id);
        }
    }
    if (!gone_) armTimer();
}

} // namespace Eco::System
