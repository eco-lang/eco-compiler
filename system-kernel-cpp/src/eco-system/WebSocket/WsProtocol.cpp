//===- WsProtocol.cpp - The WebSocket codec as a connection protocol ------===//
//
// See WsProtocol.hpp (plans/eco-system-websockets.md §3.6, Appendix D.1-D.6,
// D.8, D.9). Reactor thread only (G1): results leave as POD ChannelResults
// and WsEvents.
//
// Re-entrancy: a port call (a write, updateInterest) may run IO at once
// and call back into the core (portData, portWritable). Every entry point
// therefore finishes its state changes before it calls the port, input
// that arrives while the decoder runs is queued (pendingIn_), and the
// write pump does not nest.
//
// Templates used: none (POD only, G1); T9 completion side (ChannelResult).
//
//===----------------------------------------------------------------------===//

#include "eco-system/WebSocket/WsProtocol.hpp"

#include "eco-system/Core/Core.hpp"
#include "eco-system/Core/IoReactor.hpp"
#include "eco-system/WebSocket/WsEvents.hpp"
#include "eco-system/WebSocket/WsHandshake.hpp"

#include <algorithm>
#include <cerrno>
#include <cstdlib>
#include <cstring>
#include <utility>

namespace Eco::System {

namespace {

constexpr const char* kSocketClosed = "socket closed";
constexpr int64_t kDefaultPingTimeoutMs = 30000;

int64_t nowMs() { return IoReactor::instance().nowMs(); }

// A masking key from a pooled RAND_bytes buffer (D.8). Reactor thread.
void nextMask(unsigned char out[4]) {
    thread_local unsigned char pool[4096];
    thread_local size_t at = sizeof pool;
    if (at + 4 > sizeof pool) {
        wsRandomBytes(pool, sizeof pool);
        at = 0;
    }
    std::memcpy(out, pool + at, 4);
    at += 4;
}

// D.9: the readable's failure reason for a close code we failed with.
std::string reasonFor(int code, const std::string& text) {
    switch (code) {
    case ws::kCloseInvalidData:
        return "ERR_WS_INVALID_DATA: " + text;
    case ws::kCloseMessageTooBig:
        return "ERR_WS_MESSAGE_TOO_BIG";
    case ws::kCloseInternalError:
        return "ERR_WS_INTERNAL_ERROR: " + text;
    default:
        return "ERR_WS_PROTOCOL: " + text;
    }
}

int errnoFor(int code) { return code == ws::kCloseMessageTooBig ? EMSGSIZE : EPROTO; }

std::string pingPayload(uint64_t n) {
    std::string p(8, '\0');
    for (int i = 7; i >= 0; --i) {
        p[static_cast<size_t>(i)] = static_cast<char>(n & 0xFF);
        n >>= 8;
    }
    return p;
}

} // namespace

// ---------------------------------------------------------------------------
// WsCore
// ---------------------------------------------------------------------------

WsCore::WsCore(WsConfig cfg)
    : cfg_(cfg), decoder_(cfg.server, cfg.streamed ? UINT64_MAX : cfg.maxMessage) {
    decoder_.setRawData(cfg_.streamed || cfg_.deflate);
    decoder_.setAllowRsv1(cfg_.deflate);
}

WsCore::~WsCore() = default;

void WsCore::attach(WsPort* port) {
    port_ = port;
    attached_ = true;
    lastRxMs_ = nowMs();
    if (cfg_.heartbeatInterval > 0) armHeartbeat(lastRxMs_ + cfg_.heartbeatInterval);
    pumpWrites();
}

void WsCore::detachPort(WsPort* port) {
    if (port_ == port) port_ = nullptr;
    transportGone_ = true;
}

bool WsCore::wantsRead() const {
    return attached_ && !transportGone_ && (!paused_ || inputDone_);
}

void WsCore::updateInterest() {
    if (port_ && !transportGone_) port_->portUpdateInterest();
}

// --- Input ---------------------------------------------------------------------------

void WsCore::portData(const char* data, size_t n) {
    rxBytes_ += n;
    lastRxMs_ = nowMs();
    if (inputDone_) return;
    if (processing_ || held_ || !pendingIn_.empty()) {
        pendingIn_.append(data, n);
        processInput();
        return;
    }
    // Fast path: decode straight from the transport's buffer.
    processing_ = true;
    size_t used = decoder_.feed(data, n, *this);
    if (used < n && !inputDone_ && !decoder_.failed()) {
        // Stopped after a message (held, WS6): the rest waits.
        std::string rest(data + used, n - used);
        rest.append(pendingIn_);
        pendingIn_.swap(rest);
    }
    processing_ = false;
    processInput();
}

// Decodes the queued input (bytes that arrived re-entrantly, or held after a
// streamed message) until it is used up, the input is held, or it ends.
void WsCore::processInput() {
    if (processing_) return;
    processing_ = true;
    while (!inputDone_ && !decoder_.failed() && !held_ && !pendingIn_.empty()) {
        std::string chunk;
        chunk.swap(pendingIn_);
        size_t used = decoder_.feed(chunk.data(), chunk.size(), *this);
        if (used < chunk.size() && !inputDone_ && !decoder_.failed()) {
            chunk.erase(0, used);
            chunk.append(pendingIn_);
            pendingIn_.swap(chunk);
        }
    }
    if (inputDone_ || decoder_.failed()) pendingIn_.clear();
    processing_ = false;
    if (decoder_.failed() && !failed_) failConnection(decoder_.failCode(), decoder_.failText());
}

void WsCore::onMessage(uint8_t opcode, std::string&& payload) {
    if (inputDone_ || readShut_) return;
    msgQBytes_ += payload.size();
    InMsg m;
    m.tag = opcode == ws::kOpText ? 1 : 2;
    m.data = std::move(payload);
    msgQ_.push_back(std::move(m));
    deliverReads();
}

void WsCore::onControl(uint8_t opcode, std::string&& payload) {
    if (inputDone_) return;
    switch (opcode) {
    case ws::kOpPing:
        // Answered ahead of queued data; never after our Close (D.6).
        if (!closeQueued_) writeControl(ws::kOpPong, payload, nullptr);
        return;
    case ws::kOpPong: {
        int64_t t = nowMs();
        if (hbPingSent_ && payload.size() == 8 && (static_cast<unsigned char>(payload[0]) & 0x80)) {
            hbPingSent_ = false;
            hbDeadline_ = 0;
            if (cfg_.heartbeatInterval > 0) armHeartbeat(t + cfg_.heartbeatInterval);
        }
        // A pong answers its ping and every earlier one; unsolicited pongs are ignored.
        auto it = std::find_if(pings_.begin(), pings_.end(),
                               [&](const Ping& p) { return p.payload == payload; });
        if (it != pings_.end()) {
            std::vector<Ping> done(pings_.begin(), it + 1);
            pings_.erase(pings_.begin(), it + 1);
            for (const Ping& p : done) postPing(p.token, true, t - p.sentMs, std::string(), std::string());
        }
        armPongTimer();
        return;
    }
    case ws::kOpClose: {
        closeReceived_ = true;
        inputDone_ = true;
        decoder_.stop();
        int code = 0;
        std::string reason, failText;
        int failCode = 0;
        if (!ws::parseClose(payload, code, reason, failCode, failText)) {
            failConnection(failCode, failText);
            return;
        }
        setCloseInfo(code, reason, true);
        if (rxActive_ && !rxEndPending_) {
            // A Close in the middle of a message (WS6): its body fails, the
            // readable ends cleanly. (A message that arrived whole and is
            // still inflating completes.)
            if (body_ && !body_->messageDone) bodyFail(ECANCELED, kSocketClosed);
            abandonRx();
        }
        endReadable(ReadEnd::Eof, 0, std::string());
        if (!closeQueued_) {
            // Echo once, with its code (an empty payload echoed empty, D.5);
            // queued data is not sent after it.
            closeQueued_ = true;
            writeClosed_ = true;
            failQueued(kSocketClosed);
            if (port_ && !transportGone_) {
                port_->portSetDeadline(Conn::kTimerCloseHandshake, nowMs() + cfg_.closeTimeout);
            }
            std::string echo = code == ws::kCloseNoStatus ? std::string() : ws::closePayload(code, "");
            auto self = shared_from_this();
            writeControl(ws::kOpClose, echo, [self](int err) { self->closeFrameWritten(err); });
        }
        finishIfDone();
        return;
    }
    default:
        return;
    }
}

void WsCore::portEof() {
    if (closeReceived_ || failed_) {
        // The peer's FIN after the close handshake (client), or after we
        // failed the connection: close our side too.
        if (!tcpClosing_ && port_) {
            tcpClosing_ = true;
            port_->portCloseGraceful(kDrainMs);
        }
        return;
    }
    ended(ECONNRESET, kSocketClosed, false);
    if (!tcpClosing_ && port_) {
        tcpClosing_ = true;
        port_->portCloseGraceful(kDrainMs);
    }
}

void WsCore::portError(int err, const std::string& reason) {
    ended(err != 0 ? err : EIO, reason, true);
    if (port_) port_->portAbort();
}

void WsCore::portClosed() {
    transportGone_ = true;
    ended(ECANCELED, kSocketClosed, true);
}

// --- Raw data mode (streamed messages, permessage-deflate) --------------------------------

void WsCore::onDataStart(uint8_t opcode, bool compressed) {
    if (inputDone_) return;
    rxActive_ = true;
    rxOpcode_ = opcode;
    rxCompressed_ = compressed;
    rxEndPending_ = false;
    rxSize_ = 0;
    rxBuf_.clear();
    rxUtf8_.reset();
    if (compressed && !inflater_) inflater_ = std::make_unique<ws::Inflater>(cfg_.peerNoContext);
    if (cfg_.streamed) startBody(opcode);
}

void WsCore::onDataChunk(const char* data, size_t n) {
    if (inputDone_ || !rxActive_) return;
    if (rxCompressed_) {
        inflater_->push(data, n);
        pumpInflate();
    } else {
        deliverData(data, n);
    }
}

void WsCore::onDataEnd() {
    if (inputDone_ || !rxActive_) return;
    if (cfg_.streamed) {
        if (discardAfterMessage_) {
            // The readable was cancelled during this message: later messages
            // are discarded, so nothing needs to wait for this body.
            discardAfterMessage_ = false;
            decoder_.setDiscardData(true);
        } else {
            // WS6: the next message waits until this body is finished.
            held_ = true;
            decoder_.stop();
        }
    }
    if (rxCompressed_) {
        inflater_->finish();
        rxEndPending_ = true;
        pumpInflate();
    } else {
        messageComplete();
    }
    checkPause();
}

// Payload bytes of the current message (inflated if it is compressed).
void WsCore::deliverData(const char* p, size_t n) {
    // A message that arrived whole may still be inflating after a Close.
    if (!rxActive_ || failed_ || (inputDone_ && !rxEndPending_)) return;
    if (rxOpcode_ == ws::kOpText &&
        !rxUtf8_.feed(reinterpret_cast<const unsigned char*>(p), n)) {
        failConnection(ws::kCloseInvalidData, "invalid UTF-8 in a text message");
        return;
    }
    if (!cfg_.streamed) {
        rxSize_ += n;
        if (rxSize_ > cfg_.maxMessage) {
            failConnection(ws::kCloseMessageTooBig, "the message is larger than maxMessageSize");
            return;
        }
        if (!readShut_) rxBuf_.append(p, n);
        return;
    }
    Body* b = body_.get();
    if (!b || b->cancelled || b->end != ReadEnd::None) return;   // skipped: validated only
    if (b->text) {
        b->partial.append(p, n);
        size_t k = ws::utf8CompletePrefix(b->partial.data(), b->partial.size());
        if (k == 0) return;
        if (k == b->partial.size()) {
            b->qBytes += k;
            b->q.push_back(std::move(b->partial));
            b->partial.clear();
        } else {
            b->qBytes += k;
            b->q.push_back(b->partial.substr(0, k));
            b->partial.erase(0, k);
        }
    } else {
        b->qBytes += n;
        b->q.emplace_back(p, n);
    }
    deliverBody();
}

// Inflates the current compressed message in steps of at most 64 KiB (§3.7).
// Streamed: pauses while the body holds kReadHighBytes (deliverBody resumes).
void WsCore::pumpInflate() {
    if (pumpingInflate_) return;
    pumpingInflate_ = true;
    while (rxActive_ && rxCompressed_ && inflater_ && !failed_ && (!inputDone_ || rxEndPending_)) {
        if (cfg_.streamed && body_ && !body_->cancelled && body_->end == ReadEnd::None &&
            body_->qBytes >= kReadHighBytes) {
            break;
        }
        inflateOut_.clear();
        ws::Inflater::Step st = inflater_->step(inflateOut_, ws::kInflateStep);
        if (st == ws::Inflater::Step::Output) {
            deliverData(inflateOut_.data(), inflateOut_.size());
            continue;
        }
        if (st == ws::Inflater::Step::NeedInput) break;
        if (st == ws::Inflater::Step::Done) {
            messageComplete();
            break;
        }
        failConnection(ws::kCloseInvalidData, "invalid compressed data: " + inflater_->error());
        break;
    }
    if (inflateOut_.capacity() > 2 * ws::kInflateStep) std::string().swap(inflateOut_);
    pumpingInflate_ = false;
    checkPause();
}

// The current message's input is complete (and inflated).
void WsCore::messageComplete() {
    if (!rxActive_) return;
    rxActive_ = false;
    rxEndPending_ = false;
    if (rxOpcode_ == ws::kOpText && !rxUtf8_.complete()) {
        failConnection(ws::kCloseInvalidData, "invalid UTF-8 in a text message");
        return;
    }
    if (!cfg_.streamed) {
        std::string payload;
        payload.swap(rxBuf_);
        if (readShut_) return;
        onMessage(rxOpcode_, std::move(payload));
        return;
    }
    if (Body* b = body_.get()) {
        b->messageDone = true;
        if (b->end == ReadEnd::None) b->end = ReadEnd::Eof;
        deliverBody();
        maybeFinishBody();
    }
}

// The message in progress will never complete (a failure, our Close, a
// cancelled readable): forget its partial state.
void WsCore::abandonRx() {
    rxActive_ = false;
    rxEndPending_ = false;
    rxBuf_.clear();
    rxBuf_.shrink_to_fit();
    if (inflater_) inflater_->abandonMessage();
}

// --- Streamed bodies (WS6) ----------------------------------------------------------------

void WsCore::startBody(uint8_t opcode) {
    body_ = std::make_unique<Body>();
    body_->seq = ++bodySeq_;
    body_->text = opcode == ws::kOpText;
    InMsg m;
    m.tag = body_->text ? 3 : 4;
    m.ready = false;
    m.bodySeq = body_->seq;
    msgQ_.push_back(std::move(m));
    // The body's stream pair is created on the main thread (bodyReady).
    WsEvent ev;
    ev.kind = WsEvent::Kind::BodyNeeded;
    ev.gen = cfg_.gen;
    ev.wsId = cfg_.wsId;
    ev.bodySeq = body_->seq;
    ev.bodyText = body_->text;
    postWsEvent(std::move(ev));
}

void WsCore::bodyReady(uint64_t seq, int64_t pairId) {
    bool found = false;
    for (InMsg& m : msgQ_) {
        if (!m.ready && m.bodySeq == seq) {
            m.ready = true;
            m.data = std::to_string(pairId);
            found = true;
            break;
        }
    }
    if (found && body_ && body_->seq == seq) body_->pairId = pairId;
    if (!found) {
        // Nobody can receive this body any more (the readable was cancelled
        // or failed): let the main thread drop its pair.
        WsEvent ev;
        ev.kind = WsEvent::Kind::BodyDispose;
        ev.gen = cfg_.gen;
        ev.wsId = cfg_.wsId;
        ev.pairId = pairId;
        postWsEvent(std::move(ev));
        return;
    }
    deliverReads();
}

void WsCore::bodyReqRead(uint64_t seq, uint64_t chan, uint64_t token) {
    if (!body_ || body_->seq != seq || body_->cancelled) {
        ChannelResult r;
        r.channelId = chan;
        r.token = token;
        r.op = ChannelResult::Op::Read;
        r.err = ECANCELED;
        postChannelResult(std::move(r));
        return;
    }
    body_->reads.push_back(ReadReq{chan, token});
    deliverBody();
}

void WsCore::bodyClose(uint64_t chan, uint64_t token) {
    if (token == 0) return;   // a source releasing itself after its end: nothing to post
    ChannelResult r;
    r.channelId = chan;
    r.token = token;
    r.op = ChannelResult::Op::Close;
    postChannelResult(std::move(r));
}

void WsCore::bodyCancel(uint64_t seq) {
    Body* b = body_.get();
    if (!b || b->seq != seq || b->cancelled) return;
    b->cancelled = true;
    b->q.clear();
    b->qBytes = 0;
    b->partial.clear();
    std::deque<ReadReq> reqs;
    reqs.swap(b->reads);
    for (const ReadReq& rq : reqs) {
        ChannelResult r;
        r.channelId = rq.chan;
        r.token = rq.token;
        r.op = ChannelResult::Op::Read;
        r.err = ECANCELED;
        postChannelResult(std::move(r));
    }
    // The rest of the message is still inflated and validated, then dropped.
    if (rxActive_ && rxCompressed_) pumpInflate();
    maybeFinishBody();
    checkPause();
}

void WsCore::deliverBody() {
    Body* b = body_.get();
    if (!b) return;
    while (!b->reads.empty()) {
        ReadReq rq = b->reads.front();
        ChannelResult r;
        r.channelId = rq.chan;
        r.token = rq.token;
        r.op = ChannelResult::Op::Read;
        if (!b->q.empty()) {
            r.text = b->text;
            r.bytes = std::move(b->q.front());
            b->q.pop_front();
            while (!b->q.empty() && r.bytes.size() + b->q.front().size() <= kBodyChunk) {
                r.bytes += b->q.front();
                b->q.pop_front();
            }
            b->qBytes -= r.bytes.size();
        } else if (b->end == ReadEnd::Eof) {
            r.eof = true;
            b->endDelivered = true;
        } else if (b->end == ReadEnd::Error) {
            r.err = b->err != 0 ? b->err : EIO;
            r.reason = b->reason;
            b->endDelivered = true;
        } else {
            break;
        }
        b->reads.pop_front();
        postChannelResult(std::move(r));
        if (b->endDelivered) break;
    }
    // Room in the body: inflating may continue.
    if (rxActive_ && rxCompressed_ && inflater_ && (inflater_->hasInput() || rxEndPending_)) pumpInflate();
    checkPause();
    maybeFinishBody();
}

void WsCore::bodyFail(int err, const std::string& reason) {
    Body* b = body_.get();
    if (!b) return;
    if (b->end == ReadEnd::None) {
        // What already arrived stays readable, then the failure (as messages
        // received before a failure stay readable on the readable).
        b->end = ReadEnd::Error;
        b->err = err;
        b->reason = reason;
        b->partial.clear();
    }
    b->messageDone = true;
    deliverBody();
}

// A body is finished once its end was read (or it was cancelled and its
// message is over): the held input continues with the next message.
void WsCore::maybeFinishBody() {
    Body* b = body_.get();
    if (!b) return;
    bool over = b->messageDone || b->end == ReadEnd::Error;
    if (!(b->endDelivered || (b->cancelled && over))) return;
    body_.reset();
    releaseHold();
}

void WsCore::releaseHold() {
    if (!held_) return;
    held_ = false;
    checkPause();
    processInput();
    updateInterest();
}

// --- The readable ------------------------------------------------------------------------

void WsCore::reqRead(uint64_t chan, uint64_t token) {
    if (readShut_) {
        ChannelResult r;
        r.channelId = chan;
        r.token = token;
        r.op = ChannelResult::Op::Read;
        r.err = ECANCELED;
        postChannelResult(std::move(r));
        return;
    }
    readReqs_.push_back(ReadReq{chan, token});
    deliverReads();
}

void WsCore::deliverReads() {
    while (!readReqs_.empty()) {
        ReadReq rq = readReqs_.front();
        ChannelResult r;
        r.channelId = rq.chan;
        r.token = rq.token;
        r.op = ChannelResult::Op::Read;
        if (!msgQ_.empty()) {
            InMsg& m = msgQ_.front();
            if (!m.ready) break;   // a streamed body's pair is being created
            msgQBytes_ -= m.tag <= 2 ? m.data.size() : 0;
            r.tag = m.tag;
            r.text = m.tag != 2;
            r.bytes = std::move(m.data);
            msgQ_.pop_front();
        } else if (readEnd_ == ReadEnd::Eof) {
            r.eof = true;
        } else if (readEnd_ == ReadEnd::Error) {
            r.err = readErr_ != 0 ? readErr_ : EIO;
            r.reason = readReason_;
        } else {
            break;
        }
        readReqs_.pop_front();
        postChannelResult(std::move(r));
    }
    checkPause();
}

void WsCore::endReadable(ReadEnd how, int err, const std::string& reason) {
    if (readEnd_ != ReadEnd::None) return;
    readEnd_ = how;
    readErr_ = err;
    readReason_ = reason;
    deliverReads();
}

void WsCore::readClose(uint64_t chan, uint64_t token) {
    ChannelResult r;
    r.channelId = chan;
    r.token = token;
    r.op = ChannelResult::Op::Close;
    postChannelResult(std::move(r));
}

void WsCore::readShutdown() {
    readShut_ = true;
    if (cfg_.streamed && decoder_.inMessage()) {
        // A body is being received: it continues to its end; later messages
        // are discarded (WS6).
        discardAfterMessage_ = true;
    } else {
        decoder_.setDiscardData(true);
        // Whole mode: the message in progress is dropped. Streamed: a body
        // whose message arrived whole (still inflating) completes.
        if (rxActive_ && !cfg_.streamed) abandonRx();
    }
    // Announced bodies nobody will read are disposed when their pair exists.
    std::deque<InMsg> q;
    q.swap(msgQ_);
    for (InMsg& m : q) {
        if (m.tag >= 3 && m.ready) {
            WsEvent ev;
            ev.kind = WsEvent::Kind::BodyDispose;
            ev.gen = cfg_.gen;
            ev.wsId = cfg_.wsId;
            ev.pairId = std::strtoll(m.data.c_str(), nullptr, 10);
            postWsEvent(std::move(ev));
        }
    }
    msgQBytes_ = 0;
    std::deque<ReadReq> reqs;
    reqs.swap(readReqs_);
    for (const ReadReq& rq : reqs) {
        ChannelResult r;
        r.channelId = rq.chan;
        r.token = rq.token;
        r.op = ChannelResult::Op::Read;
        r.err = ECANCELED;
        postChannelResult(std::move(r));
    }
    // A finished message whose body nobody announced any more: nothing to
    // wait for (later messages are discarded).
    if (held_ && body_ && body_->pairId == 0) {
        body_->cancelled = true;
        maybeFinishBody();
    }
    if (held_) releaseHold();
    checkPause();
}

// Backpressure (W5): pause reading while Elm has not taken enough; the
// heartbeat and the pong deadlines are suspended meanwhile.
void WsCore::checkPause() {
    bool high = msgQBytes_ >= kReadHighBytes || msgQ_.size() >= kReadHighCount || held_ ||
                (body_ && body_->qBytes >= kReadHighBytes) ||
                (rxActive_ && rxCompressed_ && inflater_ && inflater_->hasInput());
    if (high && !paused_) {
        paused_ = true;
        if (port_ && !transportGone_) {
            port_->portSetDeadline(Conn::kTimerHeartbeat, 0);
            port_->portSetDeadline(Conn::kTimerPong, 0);
        }
        return;
    }
    if (!high && paused_) {
        paused_ = false;
        int64_t t = nowMs();
        lastRxMs_ = t;
        if (hbPingSent_) hbDeadline_ = t + cfg_.heartbeatTimeout;
        else if (cfg_.heartbeatInterval > 0) armHeartbeat(t + cfg_.heartbeatInterval);
        int64_t pingTimeout = cfg_.heartbeatTimeout > 0 ? cfg_.heartbeatTimeout : kDefaultPingTimeoutMs;
        for (Ping& p : pings_) p.deadline = t + pingTimeout;
        armPongTimer();
        updateInterest();
    }
}

// --- The writable ------------------------------------------------------------------------

std::string WsCore::buildFrame(bool fin, uint8_t opcode, const char* p, size_t n, bool rsv1) {
    if (cfg_.server) return ws::encodeFrame(fin, opcode, rsv1, p, n, nullptr);
    unsigned char mask[4];
    nextMask(mask);
    return ws::encodeFrame(fin, opcode, rsv1, p, n, mask);
}

void WsCore::writeControl(uint8_t opcode, const std::string& payload, std::function<void(int)> done) {
    if (!port_ || transportGone_) {
        if (done) done(ECANCELED);
        return;
    }
    port_->portWrite(buildFrame(true, opcode, payload.data(), payload.size()), std::move(done));
}

void WsCore::reqWrite(uint64_t chan, uint64_t token, int64_t tag, bool, std::string bytes) {
    if (writeClosed_ || transportGone_) {
        postWriteResult(chan, token, ECANCELED, kSocketClosed, 0);
        return;
    }
    queueMessage(tag == 1 ? ws::kOpText : ws::kOpBinary, std::move(bytes), chan, token);
    pumpWrites();
}

void WsCore::queueMessage(uint8_t opcode, std::string bytes, uint64_t chan, uint64_t token) {
    OutItem it;
    it.size = bytes.size();
    it.frame = std::move(bytes);   // the payload; compressed and fragmented lazily by pumpWrites
    it.chan = chan;
    it.token = token;
    it.opcode = opcode;
    outQ_.push_back(std::move(it));
}

void WsCore::pumpWrites() {
    if (pumping_ || !port_ || transportGone_) return;
    pumping_ = true;
    auto self = shared_from_this();
    while (!outQ_.empty() && port_ && !transportGone_ && port_->portOutbound() < kWriteHighBytes) {
        OutItem& it = outQ_.front();
        if (it.isClose) {
            std::string frame = std::move(it.frame);
            outQ_.pop_front();
            port_->portWrite(std::move(frame), [self](int err) { self->closeFrameWritten(err); });
            continue;
        }
        if (it.streamSeq != 0) {
            // An outgoing stream (WS6): its chunks as non-FIN fragments, then
            // the FIN frame; everything behind it waits.
            auto sit = outStreams_.find(it.streamSeq);
            if (sit == outStreams_.end()) {
                outQ_.pop_front();
                continue;
            }
            OutStream& st = sit->second;
            if (!st.chunks.empty()) {
                OutItem& c = st.chunks.front();
                if (!c.prepared) {
                    c.prepared = true;
                    if (st.compress) {
                        if (!deflater_) deflater_ = std::make_unique<ws::Deflater>(cfg_.ourBits, cfg_.ourNoContext);
                        std::string z;
                        if (!deflater_->chunk(c.frame.data(), c.frame.size(), z)) {
                            pumping_ = false;
                            failConnection(ws::kCloseInternalError, "compression failed");
                            return;
                        }
                        c.frame.swap(z);
                    }
                }
                size_t n = std::min(kFragment, c.frame.size() - c.offset);
                bool first = !st.started;
                st.started = true;
                std::string frame = buildFrame(false, first ? st.opcode : ws::kOpContinuation,
                                               c.frame.data() + c.offset, n, first && st.compress);
                c.offset += n;
                if (c.offset < c.frame.size()) {
                    port_->portWrite(std::move(frame), nullptr);
                    continue;
                }
                uint64_t chan = c.chan, token = c.token;
                size_t size = c.size;
                st.chunks.pop_front();
                port_->portWrite(std::move(frame), [self, chan, token, size](int err) {
                    if (err == 0) self->postWriteResult(chan, token, 0, std::string(), size);
                    else self->postWriteResult(chan, token, err, err == ECANCELED ? std::string(kSocketClosed)
                                                                                   : "write " + std::string(errnoName(err)), 0);
                });
                continue;
            }
            if (!st.closing) break;   // waiting for the stream's next chunk
            // The end of the message: a FIN frame (with the opcode when nothing
            // was sent: an empty message, never compressed). A compressed one
            // carries 0x00, the header of an empty stored block that the
            // receiver's appended 00 00 ff ff completes (RFC 7692 §7.2.3.6);
            // with an empty payload those 4 bytes would open a block that never
            // ends, breaking the next message under context takeover.
            bool first = !st.started;
            bool compressedEnd = st.compress && st.started;
            std::string frame = buildFrame(true, first ? st.opcode : ws::kOpContinuation,
                                           compressedEnd ? "\0" : "", compressedEnd ? 1 : 0, false);
            if (st.compress && st.started && deflater_) deflater_->endMessage();
            uint64_t chan = st.closeChan, token = st.closeToken;
            outStreams_.erase(sit);
            outQ_.pop_front();
            port_->portWrite(std::move(frame), [chan, token](int err) {
                ChannelResult r;
                r.channelId = chan;
                r.token = token;
                r.op = ChannelResult::Op::Close;
                if (err != 0) {
                    r.err = err;
                    r.reason = kSocketClosed;
                }
                postChannelResult(std::move(r));
            });
            continue;
        }
        if (!it.prepared) {
            // permessage-deflate (WS7): whole messages of at least `threshold`
            // bytes are compressed (RSV1 on the first fragment).
            it.prepared = true;
            if (cfg_.deflate && static_cast<int64_t>(it.frame.size()) >= cfg_.threshold) {
                if (!deflater_) deflater_ = std::make_unique<ws::Deflater>(cfg_.ourBits, cfg_.ourNoContext);
                std::string z;
                if (!deflater_->message(it.frame.data(), it.frame.size(), z)) {
                    pumping_ = false;
                    failConnection(ws::kCloseInternalError, "compression failed");
                    return;
                }
                it.frame.swap(z);
                it.compressed = true;
            }
        }
        // The next fragment of the message (D.1: the opcode on the first,
        // continuations after; FIN on the last).
        size_t n = std::min(kFragment, it.frame.size() - it.offset);
        bool first = it.offset == 0;
        bool fin = it.offset + n >= it.frame.size();
        std::string frame = buildFrame(fin, first ? it.opcode : ws::kOpContinuation,
                                       it.frame.data() + it.offset, n, first && it.compressed);
        it.offset += n;
        if (!fin) {
            port_->portWrite(std::move(frame), nullptr);
            continue;
        }
        uint64_t chan = it.chan, token = it.token;
        size_t size = it.size;
        outQ_.pop_front();
        port_->portWrite(std::move(frame), [self, chan, token, size](int err) {
            if (err == 0) self->postWriteResult(chan, token, 0, std::string(), size);
            else self->postWriteResult(chan, token, err, err == ECANCELED ? std::string(kSocketClosed)
                                                                           : "write " + std::string(errnoName(err)), 0);
        });
    }
    pumping_ = false;
}

// --- Outgoing streams (WS6) --------------------------------------------------------------

void WsCore::openOutgoing(uint64_t seq, uint8_t opcode) {
    OutStream st;
    st.opcode = opcode;
    st.compress = cfg_.deflate;
    if (writeClosed_ || transportGone_) {
        st.dead = true;   // writes fail; nothing is queued
        outStreams_.emplace(seq, std::move(st));
        return;
    }
    outStreams_.emplace(seq, std::move(st));
    OutItem it;
    it.streamSeq = seq;
    outQ_.push_back(std::move(it));
    pumpWrites();
}

void WsCore::outWrite(uint64_t seq, uint64_t chan, uint64_t token, std::string bytes) {
    auto sit = outStreams_.find(seq);
    if (sit == outStreams_.end() || sit->second.dead || sit->second.closing || transportGone_) {
        postWriteResult(chan, token, ECANCELED, kSocketClosed, 0);
        return;
    }
    if (bytes.empty()) {   // nothing to send: no zero-length fragment
        postWriteResult(chan, token, 0, std::string(), 0);
        return;
    }
    OutItem c;
    c.size = bytes.size();
    c.frame = std::move(bytes);
    c.chan = chan;
    c.token = token;
    sit->second.chunks.push_back(std::move(c));
    pumpWrites();
}

void WsCore::outClose(uint64_t seq, uint64_t chan, uint64_t token) {
    auto sit = outStreams_.find(seq);
    if (sit == outStreams_.end() || sit->second.dead || sit->second.closing || transportGone_) {
        if (sit != outStreams_.end() && sit->second.dead) outStreams_.erase(sit);
        ChannelResult r;
        r.channelId = chan;
        r.token = token;
        r.op = ChannelResult::Op::Close;
        r.err = ECANCELED;
        r.reason = kSocketClosed;
        postChannelResult(std::move(r));
        return;
    }
    sit->second.closing = true;
    sit->second.closeChan = chan;
    sit->second.closeToken = token;
    pumpWrites();
}

void WsCore::outAbort(uint64_t seq) {
    auto sit = outStreams_.find(seq);
    if (sit == outStreams_.end()) return;   // finished (FIN sent) or failed already
    if (sit->second.started && !failed_ && !closedPosted_ && !transportGone_) {
        // A message cut off in the middle cannot be completed (WS6).
        failConnection(ws::kCloseInternalError, "an outgoing message stream was cancelled");
        return;
    }
    // Nothing went out yet: drop the stream quietly.
    failStream(sit->second, "the message was cancelled");
    outStreams_.erase(sit);
    for (auto it = outQ_.begin(); it != outQ_.end(); ++it) {
        if (it->streamSeq == seq) {
            outQ_.erase(it);
            break;
        }
    }
    pumpWrites();
}

// Fails a stream's pending chunk writes and its FIN close.
void WsCore::failStream(OutStream& st, const std::string& reason) {
    for (const OutItem& c : st.chunks) postWriteResult(c.chan, c.token, ECANCELED, reason, 0);
    st.chunks.clear();
    if (st.closing && st.closeToken != 0) {
        ChannelResult r;
        r.channelId = st.closeChan;
        r.token = st.closeToken;
        r.op = ChannelResult::Op::Close;
        r.err = ECANCELED;
        r.reason = reason;
        postChannelResult(std::move(r));
        st.closeToken = 0;
    }
    st.dead = true;
}

void WsCore::portWritable() { pumpWrites(); }

void WsCore::postWriteResult(uint64_t chan, uint64_t token, int err, const std::string& reason,
                             size_t n) {
    ChannelResult r;
    r.channelId = chan;
    r.token = token;
    r.op = ChannelResult::Op::Write;
    r.err = err;
    r.reason = reason;
    r.written = n;
    postChannelResult(std::move(r));
}

// Fails every queued data message (not yet given to the port). A queued
// graceful Close is dropped too (its waiters complete with the Close that
// replaces it, or when the connection ends).
void WsCore::failQueued(const std::string& reason) {
    std::deque<OutItem> q;
    q.swap(outQ_);
    for (const OutItem& it : q) {
        if (it.streamSeq != 0) continue;
        if (!it.isClose) postWriteResult(it.chan, it.token, ECANCELED, reason, 0);
    }
    // Outgoing streams: their pending writes and closes fail; later ones too.
    for (auto& kv : outStreams_) failStream(kv.second, reason);
}

void WsCore::writeClose(uint64_t chan, uint64_t token) {
    if (closeWritten_ || closedPosted_ || transportGone_) {
        ChannelResult r;
        r.channelId = chan;
        r.token = token;
        r.op = ChannelResult::Op::Close;
        if (!clean_ && !closeWritten_) {
            r.err = ECANCELED;
            r.reason = kSocketClosed;
        }
        postChannelResult(std::move(r));
        return;
    }
    closeWaiters_.emplace_back(chan, token);
    queueGracefulClose(ws::kCloseNormal, std::string());
}

void WsCore::writeShutdown() {
    // cancelWritable fails the connection (D.5); a writable that failed
    // because the WebSocket is closing (or closed) does not fail it again.
    if (writeClosed_ || failed_ || closedPosted_ || transportGone_) return;
    failConnection(ws::kCloseInternalError, "the writable was cancelled");
}

void WsCore::startClose(int code, const std::string& reason, uint64_t token) {
    if (closeWritten_ || closedPosted_ || transportGone_) {
        postOpDone(token);
        return;
    }
    closeOps_.push_back(token);
    queueGracefulClose(code, reason);
}

// Our Close, behind the queued data (D.5): data frames are discarded from now
// on, later writes fail, the close timeout runs.
void WsCore::queueGracefulClose(int code, const std::string& reason) {
    if (closeQueued_) return;
    closeQueued_ = true;
    writeClosed_ = true;
    decoder_.setDiscardData(true);
    if (rxActive_ && !rxEndPending_) {
        // Data after our Close is discarded: a body in progress fails (WS6)
        // (one that arrived whole and is still inflating completes).
        if (body_ && !body_->messageDone) bodyFail(ECANCELED, kSocketClosed);
        abandonRx();
    }
    // Nothing needs to wait behind a finished body any more (later data
    // messages are discarded): keep handling control frames.
    releaseHold();
    std::string payload = ws::closePayload(code, reason);
    OutItem it;
    it.isClose = true;
    it.frame = buildFrame(true, ws::kOpClose, payload.data(), payload.size());
    outQ_.push_back(std::move(it));
    if (port_ && !transportGone_) {
        port_->portSetDeadline(Conn::kTimerCloseHandshake, nowMs() + cfg_.closeTimeout);
    }
    pumpWrites();
}

void WsCore::closeFrameWritten(int) {
    closeWritten_ = true;
    std::vector<uint64_t> ops;
    ops.swap(closeOps_);
    for (uint64_t t : ops) postOpDone(t);
    std::vector<std::pair<uint64_t, uint64_t>> waiters;
    waiters.swap(closeWaiters_);
    for (const auto& [chan, token] : waiters) {
        ChannelResult r;
        r.channelId = chan;
        r.token = token;
        r.op = ChannelResult::Op::Close;
        postChannelResult(std::move(r));
    }
    finishIfDone();
}

// Both Close frames are through: the WebSocket is Closed. The server closes
// TCP; the client waits for the server's FIN (portEof), bounded by the close
// timeout.
void WsCore::finishIfDone() {
    if (!closeWritten_ || !closeReceived_ || failed_) return;
    postClosed();
    if (cfg_.server && !tcpClosing_ && port_ && !transportGone_) {
        tcpClosing_ = true;
        port_->portCloseGraceful(kDrainMs);
    }
}

// --- Failing and ending ------------------------------------------------------------------

void WsCore::failConnection(int code, const std::string& text) {
    failWith(code, text, code, text, errnoFor(code), reasonFor(code, text));
}

// Fail the connection: send Close(frameCode, frameText) unless ours is out
// already, stop processing input, end the readable with the failure, close.
void WsCore::failWith(int frameCode, const std::string& frameText, int infoCode,
                      const std::string& infoReason, int readErr, const std::string& readReason) {
    if (failed_ || closedPosted_) return;
    failed_ = true;
    inputDone_ = true;
    decoder_.stop();
    setCloseInfo(infoCode, ws::truncateUtf8(infoReason, ws::kMaxControlPayload - 2), false);
    if (body_ && !body_->messageDone) bodyFail(readErr, readReason);
    abandonRx();
    endReadable(ReadEnd::Error, readErr, readReason);
    writeClosed_ = true;
    failQueued(kSocketClosed);
    if (!closeWritten_) {
        closeQueued_ = true;
        auto self = shared_from_this();
        writeControl(ws::kOpClose, ws::closePayload(frameCode, frameText),
                     [self](int err) { self->closeFrameWritten(err); });
    }
    postClosed();
    if (!tcpClosing_ && port_ && !transportGone_) {
        tcpClosing_ = true;
        port_->portCloseGraceful(kDrainMs);
    }
}

void WsCore::heartbeatTimeout() {
    // W5: Close 1001 best effort, reported Abnormal.
    failWith(ws::kCloseGoingAway, std::string(), ws::kCloseAbnormal, std::string(), ETIMEDOUT,
             "heartbeat ETIMEDOUT");
}

// The transport ended (EOF without a Close, an error, an abort, the close
// timeout). Everything still pending completes.
void WsCore::ended(int err, const std::string& reason, bool) {
    setCloseInfo(ws::kCloseAbnormal, std::string(), false);
    if (body_ && !body_->messageDone) bodyFail(err, reason);
    if (rxActive_) abandonRx();
    endReadable(ReadEnd::Error, err, reason);
    writeClosed_ = true;
    failQueued(kSocketClosed);
    if (!closeWritten_ && (!closeOps_.empty() || !closeWaiters_.empty())) {
        // Our Close never got out: its waiters complete (close is idempotent).
        closeWritten_ = true;
        std::vector<uint64_t> ops;
        ops.swap(closeOps_);
        for (uint64_t t : ops) postOpDone(t);
        std::vector<std::pair<uint64_t, uint64_t>> waiters;
        waiters.swap(closeWaiters_);
        for (const auto& [chan, token] : waiters) {
            ChannelResult r;
            r.channelId = chan;
            r.token = token;
            r.op = ChannelResult::Op::Close;
            r.err = ECANCELED;
            r.reason = kSocketClosed;
            postChannelResult(std::move(r));
        }
    }
    postClosed();
}

void WsCore::abortNow() {
    if (port_ && !transportGone_) {
        port_->portAbort();
        return;
    }
    portClosed();
}

void WsCore::setCloseInfo(int code, const std::string& reason, bool clean) {
    if (infoSet_) return;
    infoSet_ = true;
    closeCode_ = code;
    closeReason_ = reason;
    clean_ = clean;
}

void WsCore::postClosed() {
    if (closedPosted_) return;
    closedPosted_ = true;
    setCloseInfo(ws::kCloseAbnormal, std::string(), false);
    std::vector<Ping> ps;
    ps.swap(pings_);
    for (const Ping& p : ps) postPing(p.token, false, 0, "ECANCELED", "ping ECANCELED: the WebSocket closed");
    if (port_ && !transportGone_) {
        port_->portSetDeadline(Conn::kTimerHeartbeat, 0);
        port_->portSetDeadline(Conn::kTimerPong, 0);
    }
    hbPingSent_ = false;
    WsEvent ev;
    ev.kind = WsEvent::Kind::Closed;
    ev.gen = cfg_.gen;
    ev.wsId = cfg_.wsId;
    ev.closeCode = closeCode_;
    ev.reason = closeReason_;
    ev.clean = clean_;
    postWsEvent(std::move(ev));
}

void WsCore::postOpDone(uint64_t token) {
    if (token == 0) return;
    WsEvent ev;
    ev.kind = WsEvent::Kind::OpDone;
    ev.gen = cfg_.gen;
    ev.token = token;
    ev.wsId = cfg_.wsId;
    postWsEvent(std::move(ev));
}

void WsCore::postPing(uint64_t token, bool ok, int64_t rtt, const std::string& code,
                      const std::string& msg) {
    WsEvent ev;
    ev.kind = WsEvent::Kind::PingDone;
    ev.gen = cfg_.gen;
    ev.token = token;
    ev.wsId = cfg_.wsId;
    ev.rtt = rtt;
    ev.failed = !ok;
    ev.code = code;
    ev.message = msg;
    postWsEvent(std::move(ev));
}

// --- Ping / heartbeat --------------------------------------------------------------------

void WsCore::startPing(uint64_t token) {
    if (closeQueued_ || closedPosted_ || transportGone_ || failed_) {
        postPing(token, false, 0, "ECANCELED", "ping ECANCELED: the WebSocket is closing");
        return;
    }
    int64_t t = nowMs();
    int64_t timeout = cfg_.heartbeatTimeout > 0 ? cfg_.heartbeatTimeout : kDefaultPingTimeoutMs;
    Ping p{pingPayload(++pingCounter_ & 0x7FFFFFFFFFFFFFFFULL), token, t, paused_ ? 0 : t + timeout};
    std::string payload = p.payload;
    pings_.push_back(std::move(p));
    armPongTimer();
    writeControl(ws::kOpPing, payload, nullptr);
}

void WsCore::armHeartbeat(int64_t at) {
    if (cfg_.heartbeatInterval > 0 && port_ && !transportGone_) {
        port_->portSetDeadline(Conn::kTimerHeartbeat, at);
    }
}

void WsCore::armPongTimer() {
    if (!port_ || transportGone_) return;
    int64_t earliest = hbPingSent_ ? hbDeadline_ : 0;
    for (const Ping& p : pings_) {
        if (p.deadline > 0 && (earliest == 0 || p.deadline < earliest)) earliest = p.deadline;
    }
    port_->portSetDeadline(Conn::kTimerPong, earliest);
}

void WsCore::portTimer(int timerId) {
    int64_t t = nowMs();
    switch (timerId) {
    case Conn::kTimerHeartbeat: {
        if (cfg_.heartbeatInterval <= 0 || closeQueued_ || closeReceived_ || failed_ || paused_ ||
            hbPingSent_) {
            return;
        }
        if (t - lastRxMs_ < cfg_.heartbeatInterval) {
            armHeartbeat(lastRxMs_ + cfg_.heartbeatInterval);
            return;
        }
        hbPingSent_ = true;
        rxAtPing_ = rxBytes_;
        hbDeadline_ = t + (cfg_.heartbeatTimeout > 0 ? cfg_.heartbeatTimeout : kDefaultPingTimeoutMs);
        armPongTimer();
        writeControl(ws::kOpPing, pingPayload((++pingCounter_ & 0x7FFFFFFFFFFFFFFFULL) | (1ULL << 63)),
                     nullptr);
        return;
    }
    case Conn::kTimerPong: {
        if (paused_) return;
        std::vector<Ping> expired;
        for (auto it = pings_.begin(); it != pings_.end();) {
            if (it->deadline > 0 && it->deadline <= t) {
                expired.push_back(*it);
                it = pings_.erase(it);
            } else {
                ++it;
            }
        }
        for (const Ping& p : expired) postPing(p.token, false, 0, "ETIMEDOUT", "ping ETIMEDOUT");
        if (hbPingSent_ && hbDeadline_ > 0 && hbDeadline_ <= t) {
            if (rxBytes_ > rxAtPing_) {   // liveness is counted in bytes (W5)
                hbPingSent_ = false;
                hbDeadline_ = 0;
                armHeartbeat(std::max(t, lastRxMs_ + cfg_.heartbeatInterval));
            } else {
                heartbeatTimeout();
                return;
            }
        }
        armPongTimer();
        return;
    }
    case Conn::kTimerCloseHandshake:
        // The close handshake (or the client's wait for the server's FIN)
        // took too long: abort (D.5).
        ended(ETIMEDOUT, kSocketClosed, true);
        if (port_ && !transportGone_) port_->portAbort();
        return;
    default:
        return;
    }
}

// ---------------------------------------------------------------------------
// WsProtocol (the core over a Conn)
// ---------------------------------------------------------------------------

WsProtocol::~WsProtocol() { core_->detachPort(this); }

void WsProtocol::onOpen(Conn& c) {
    conn_ = &c;
    std::weak_ptr<WsCore> weak = core_;
    c.addCloseHook([weak](Conn&) {
        if (auto k = weak.lock()) k->portClosed();
    });
    core_->attach(this);
}

void WsProtocol::onData(Conn&, std::string_view bytes) { core_->portData(bytes.data(), bytes.size()); }

void WsProtocol::onEof(Conn&) { core_->portEof(); }

void WsProtocol::onError(Conn&, int err, const std::string& code) { core_->portError(err, code); }

void WsProtocol::onWritable(Conn&) { core_->portWritable(); }

void WsProtocol::onTimer(Conn&, int timerId) { core_->portTimer(timerId); }

void WsProtocol::onCloseAll(Conn&) { core_->portClosed(); }

bool WsProtocol::wantsRead() const { return core_->wantsRead(); }

void WsProtocol::portWrite(std::string bytes, std::function<void(int)> done) {
    if (!conn_) {
        if (done) done(ECANCELED);
        return;
    }
    conn_->write(std::move(bytes), std::move(done));
}

size_t WsProtocol::portOutbound() const { return conn_ ? conn_->outbound() : 0; }

void WsProtocol::portSetDeadline(int timerId, int64_t monoMs) {
    if (conn_) conn_->setDeadline(timerId, monoMs);
}

void WsProtocol::portUpdateInterest() {
    if (conn_) conn_->updateInterest();
}

void WsProtocol::portCloseGraceful(int64_t drainMs) {
    if (conn_) conn_->closeGraceful(drainMs);
}

void WsProtocol::portAbort() {
    if (conn_) conn_->abort(false);
}

} // namespace Eco::System
