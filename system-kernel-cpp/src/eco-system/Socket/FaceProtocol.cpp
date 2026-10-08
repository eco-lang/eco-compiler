//===- FaceProtocol.cpp - The stream faces as a Conn protocol -------------===//
//
// See FaceProtocol.hpp (plans/eco-system-websockets.md §3.2; the rules are
// those of plans/eco-system-sockets.md §3.3.3 and §D.2, moved here from
// Conn.cpp unchanged). Reactor thread only.
//
// Templates used: none (POD only, G1); T9 completion side (ChannelResult).
//
//===----------------------------------------------------------------------===//

#include "eco-system/Socket/FaceProtocol.hpp"

#include <cerrno>
#include <utility>

namespace Eco::System {

namespace {

constexpr const char* kSocketClosed = "socket closed";

void postRead(uint64_t channelId, uint64_t token, ChannelResult res) {
    res.channelId = channelId;
    res.token = token;
    res.op = ChannelResult::Op::Read;
    postChannelResult(std::move(res));
}

void postClose(uint64_t channelId, uint64_t token, int err, const std::string& reason) {
    ChannelResult res;
    res.channelId = channelId;
    res.token = token;
    res.op = ChannelResult::Op::Close;
    res.err = err;
    res.reason = reason;
    postChannelResult(std::move(res));
}

// A read requested after reading ended.
void lateRead(const Conn& c, ChannelResult& r) {
    if (c.eofSeen()) {
        r.eof = true;
    } else if (c.readError() != 0) {
        r.err = c.readError();
        r.reason = c.readErrorReason();
    } else {
        r.err = ECANCELED;
        r.reason = kSocketClosed;
    }
}

// A write (or close) requested after writing ended.
void lateWrite(const Conn& c, ChannelResult& r) {
    if (c.writeError() != 0 && !c.aborted()) {
        r.err = c.writeError();
        r.reason = c.writeErrorReason();
    } else {
        r.err = ECANCELED;
        r.reason = kSocketClosed;
    }
}

} // namespace

// --- Read face -------------------------------------------------------------------

void FaceProtocol::reqRead(Conn& c, uint64_t channelId, uint64_t token, size_t maxBytes) {
    if (!buffered_.empty()) {   // bytes already read: served first, in order
        readReqs_.push_back(ReadReq{channelId, token, maxBytes});
        serveBuffered();
        return;
    }
    if (c.phase() != Conn::Phase::Open || readDone_) {
        ChannelResult r;
        lateRead(c, r);
        postRead(channelId, token, std::move(r));
        return;
    }
    readReqs_.push_back(ReadReq{channelId, token, maxBytes});
    // Attempted at once: most reads find data (and TLS may hold decrypted
    // bytes that no fd event announces, N6).
    c.updateInterest();
}

void FaceProtocol::serveBuffered() {
    while (!readReqs_.empty() && !buffered_.empty()) {
        ReadReq rq = readReqs_.front();
        readReqs_.pop_front();
        size_t cap = rq.max == 0 ? 1 : rq.max;
        size_t n = buffered_.size() < cap ? buffered_.size() : cap;
        ChannelResult res;
        res.bytes = buffered_.substr(0, n);
        buffered_.erase(0, n);
        postRead(rq.channelId, rq.token, std::move(res));
    }
}

void FaceProtocol::onData(Conn&, std::string_view bytes) {
    if (bytes.empty()) return;
    if (buffered_.empty() && !readReqs_.empty()) {
        size_t cap = readReqs_.front().max == 0 ? 1 : readReqs_.front().max;
        if (bytes.size() <= cap) {   // the usual case: one read, one result
            ReadReq rq = readReqs_.front();
            readReqs_.pop_front();
            ChannelResult res;
            res.bytes.assign(bytes.data(), bytes.size());
            postRead(rq.channelId, rq.token, std::move(res));
            return;
        }
    }
    buffered_.append(bytes.data(), bytes.size());
    serveBuffered();
}

void FaceProtocol::onEof(Conn& c) {
    // End of input: every queued read gets it (buffered bytes, if any, are
    // still served first by later requests).
    readDone_ = true;
    std::deque<ReadReq> reqs;
    reqs.swap(readReqs_);
    for (const ReadReq& r : reqs) {
        ChannelResult res;
        res.eof = true;
        postRead(r.channelId, r.token, std::move(res));
    }
    checkDone(c);
}

void FaceProtocol::onError(Conn& c, int err, const std::string& code) {
    if (code.rfind("write ", 0) == 0) {   // the writes already failed through `done`
        checkDone(c);
        return;
    }
    readDone_ = true;
    failReads(err, code);
    checkDone(c);
}

void FaceProtocol::failReads(int err, const std::string& reason) {
    std::deque<ReadReq> reqs;
    reqs.swap(readReqs_);
    for (const ReadReq& r : reqs) {
        ChannelResult res;
        res.err = err;
        res.reason = reason;
        postRead(r.channelId, r.token, std::move(res));
    }
}

void FaceProtocol::reqCloseRead(Conn& c, uint64_t channelId, uint64_t token) {
    if (!readDone_) {
        // Closed before EOF (not done by the stream table, which closes a
        // source only after EOF): reading is abandoned (the final close
        // discards, N8).
        readDone_ = true;
        failReads(ECANCELED, std::string());
    }
    buffered_.clear();
    postClose(channelId, token, 0, std::string());
    checkDone(c);
    c.updateInterest();
}

void FaceProtocol::readFaceShutdown(Conn& c) {
    failReads(ECANCELED, c.aborted() ? std::string(kSocketClosed) : std::string());
    readDone_ = true;   // before EOF: abandoned, no SHUT_RD (N8)
    buffered_.clear();
    checkDone(c);
    c.updateInterest();
}

std::string FaceProtocol::takeBuffered() {
    return std::exchange(buffered_, std::string());
}

// --- Write face ------------------------------------------------------------------

void FaceProtocol::reqWrite(Conn& c, uint64_t channelId, uint64_t token, std::string bytes) {
    if (c.phase() != Conn::Phase::Open || writeOver(c) || closePending_) {
        ChannelResult r;
        r.channelId = channelId;
        r.token = token;
        r.op = ChannelResult::Op::Write;
        lateWrite(c, r);
        postChannelResult(std::move(r));
        return;
    }
    ++writesInFlight_;
    size_t n = bytes.size();
    Conn* cp = &c;   // the Conn owns this protocol (and keeps it while writes are queued)
    c.write(std::move(bytes), [this, cp, channelId, token, n](int err) {
        writeDone(*cp, channelId, token, n, err);
    });
}

void FaceProtocol::writeDone(Conn& c, uint64_t channelId, uint64_t token, size_t size, int err) {
    --writesInFlight_;
    ChannelResult res;
    res.channelId = channelId;
    res.token = token;
    res.op = ChannelResult::Op::Write;
    if (err == 0) {
        res.written = size;
    } else {
        res.err = err;
        if (cancelling_) res.reason = cancelReason_;
        else if (c.aborted()) res.reason = kSocketClosed;
        else res.reason = c.writeErrorReason();
    }
    postChannelResult(std::move(res));
    checkDone(c);
}

void FaceProtocol::reqCloseWrite(Conn& c, uint64_t channelId, uint64_t token) {
    if (c.phase() != Conn::Phase::Open || writeOver(c) || closePending_) {
        ChannelResult r;
        lateWrite(c, r);
        postClose(channelId, token, r.err, r.reason);
        return;
    }
    closePending_ = true;
    closeChannel_ = channelId;
    closeToken_ = token;
    Conn* cp = &c;
    c.shutdownWrite([this, cp](int err) { closeDone(*cp, err); });
}

void FaceProtocol::closeDone(Conn& c, int err) {
    if (!closePending_) return;
    closePending_ = false;
    writeFaceDone_ = true;
    if (err == 0 || c.aborted()) {
        postClose(closeChannel_, closeToken_, 0, std::string());   // §D.2: completes on abort
    } else if (cancelling_) {
        postClose(closeChannel_, closeToken_, ECANCELED, std::string());
    } else {
        postClose(closeChannel_, closeToken_, err, c.writeErrorReason());
    }
    checkDone(c);
}

void FaceProtocol::writeFaceShutdown(Conn& c) {
    cancelling_ = true;
    cancelReason_ = c.aborted() ? kSocketClosed : "";
    c.cancelWrites(ECANCELED);   // the queued writes, then a pending close
    cancelling_ = false;
    if (closePending_) {   // not queued in the Conn any more (defensive)
        closePending_ = false;
        postClose(closeChannel_, closeToken_, ECANCELED, std::string());
    }
    writeFaceDone_ = true;
    if (c.phase() == Conn::Phase::Open) c.shutdownWrite();   // FIN, best effort
    checkDone(c);
    c.updateInterest();
}

// --- Both ------------------------------------------------------------------------

void FaceProtocol::onCloseAll(Conn& c) {
    failReads(ECANCELED, kSocketClosed);
    readDone_ = true;
    buffered_.clear();
    cancelling_ = true;
    cancelReason_ = kSocketClosed;
    c.cancelWrites(ECANCELED);   // writes "socket closed"; a pending close completes (err 0)
    cancelling_ = false;
    if (closePending_) {
        closePending_ = false;
        postClose(closeChannel_, closeToken_, 0, std::string());
    }
    writeFaceDone_ = true;
}

void FaceProtocol::checkDone(Conn& c) {
    if (cancelling_) return;
    if (readDone_ && writeOver(c) && readReqs_.empty() && writesInFlight_ == 0 && !closePending_) {
        // Both directions are done: close. If reading was abandoned before
        // EOF, input is discarded first (N8); what the transport still holds
        // (a TLS close_notify, its SHUT_WR) is flushed. At most 2 s.
        c.closeGraceful(Conn::kFaceDrainMs);
    }
}

} // namespace Eco::System
