//===- Http2Client.cpp - The WebSocket client over HTTP/2 (RFC 8441) ------===//
//
// See Http2Client.hpp (plans/eco-system-websockets.md §3.9, phase WS9).
// Reactor thread only; POSIX (nghttp2 is not built on Windows).
//
// Re-entrancy (as Http2.cpp): nghttp2 is never re-entered. Tunnel calls made
// from inside a session callback (the codec answering a ping while DATA is
// being received) only queue; the IO step that is running frames them
// (afterIo's second flush), and a call made while a flush runs makes it loop
// once more.
//
// Templates used: none (POD only, G1).
//
//===----------------------------------------------------------------------===//

#include "eco-system/WebSocket/Http2Client.hpp"

#ifndef _WIN32

#include <nghttp2/nghttp2.h>

#include <algorithm>
#include <cerrno>
#include <cstring>
#include <utility>
#include <vector>

namespace Eco::System {

namespace {

// "read ECONNRESET" → "ECONNRESET".
std::string codeOfReason(const std::string& reason) {
    size_t sp = reason.find(' ');
    return sp == std::string::npos ? reason : reason.substr(sp + 1);
}

} // namespace

// ---------------------------------------------------------------------------
// nghttp2 callbacks
// ---------------------------------------------------------------------------

struct Http2ClientProtocol::Cb {
    static Http2ClientProtocol* self(void* ud) { return static_cast<Http2ClientProtocol*>(ud); }

    static int beginHeaders(nghttp2_session*, const nghttp2_frame* f, void* ud) {
        Http2ClientProtocol* p = self(ud);
        if (f->hd.type == NGHTTP2_HEADERS && f->hd.stream_id == p->sid_ && p->phase_ == Phase::Requested) {
            p->status_ = 0;
            p->headers_.clear();
        }
        return 0;
    }

    static int header(nghttp2_session*, const nghttp2_frame* f, const uint8_t* name, size_t nl,
                      const uint8_t* value, size_t vl, uint8_t, void* ud) {
        Http2ClientProtocol* p = self(ud);
        if (f->hd.type != NGHTTP2_HEADERS || f->hd.stream_id != p->sid_ || p->phase_ != Phase::Requested)
            return 0;   // trailers are ignored
        std::string_view n(reinterpret_cast<const char*>(name), nl);
        std::string_view v(reinterpret_cast<const char*>(value), vl);
        if (n == ":status") {
            int st = 0;
            for (char ch : v) {
                if (ch < '0' || ch > '9') return 0;
                st = st * 10 + (ch - '0');
                if (st > 999) return 0;
            }
            p->status_ = st;
            return 0;
        }
        if (!n.empty() && n[0] == ':') return 0;
        p->headers_.emplace_back(std::string(n), std::string(v));
        return 0;
    }

    static int frameRecv(nghttp2_session* session, const nghttp2_frame* f, void* ud) {
        Http2ClientProtocol* p = self(ud);
        if (p->done_) return 0;
        bool end = (f->hd.flags & NGHTTP2_FLAG_END_STREAM) != 0;
        switch (f->hd.type) {
        case NGHTTP2_SETTINGS:
            if ((f->hd.flags & NGHTTP2_FLAG_ACK) == 0 && p->phase_ == Phase::Settings) {
                // RFC 8441 §3: only a server that sent ENABLE_CONNECT_PROTOCOL = 1
                // takes an extended CONNECT; nghttp2 leaves that check to us (WF3).
                if (nghttp2_session_get_remote_settings(session, NGHTTP2_SETTINGS_ENABLE_CONNECT_PROTOCOL) == 1) {
                    p->submitRequest();
                } else {
                    p->phase_ = Phase::Done;
                    p->fallback_ = true;
                    (void)nghttp2_session_terminate_session(session, NGHTTP2_NO_ERROR);
                }
            }
            return 0;
        case NGHTTP2_HEADERS:
            if (f->hd.stream_id != p->sid_) return 0;
            if (p->phase_ == Phase::Requested) {
                if (p->status_ >= 100 && p->status_ < 200 && !end) return 0;   // informational
                if (p->status_ == 0) {
                    p->failDial("ERR_WS_HANDSHAKE", "invalid HTTP/2 response: no :status");
                    return 0;
                }
                p->phase_ = Phase::Held;
                p->heldEnd_ = end;
                if (p->conn_) {
                    p->conn_->setDeadline(Conn::kTimerHeaders, 0);
                    p->job_->h2HeadDone(*p->conn_, p->status_, std::move(p->headers_));
                }
                p->headers_.clear();
                return 0;
            }
            if (end) p->endOfStream();
            return 0;
        case NGHTTP2_DATA:
            if (f->hd.stream_id == p->sid_ && end) p->endOfStream();
            return 0;
        default:
            return 0;
        }
    }

    static int dataChunk(nghttp2_session* session, uint8_t, int32_t sid, const uint8_t* data,
                         size_t len, void* ud) {
        Http2ClientProtocol* p = self(ud);
        (void)nghttp2_session_consume_connection(session, len);
        if (sid != p->sid_ || p->done_ || p->phase_ == Phase::Requested) {
            (void)nghttp2_session_consume_stream(session, sid, len);
            return 0;
        }
        std::string_view bytes(reinterpret_cast<const char*>(data), len);
        if (p->port_) {
            std::shared_ptr<H2StreamPort> port = p->port_;
            port->streamData(bytes);   // consumed into the window as the codec takes it
        } else {
            p->held_.append(bytes.data(), bytes.size());   // the stream window (64 KiB) bounds it
        }
        return 0;
    }

    static int streamClose(nghttp2_session*, int32_t sid, uint32_t code, void* ud) {
        Http2ClientProtocol* p = self(ud);
        if (sid == p->sid_) p->streamGone(code);
        return 0;
    }

    static nghttp2_ssize readData(nghttp2_session*, int32_t, uint8_t* buf, size_t len, uint32_t* flags,
                                  nghttp2_data_source*, void* ud) {
        Http2ClientProtocol* p = self(ud);
        size_t avail = p->out_.size() - p->outOff_;
        size_t n = std::min(len, avail);
        if (n > 0) std::memcpy(buf, p->out_.data() + p->outOff_, n);
        p->outOff_ += n;
        if (p->outOff_ == p->out_.size()) {
            p->out_.clear();
            p->outOff_ = 0;
            if (p->outEnd_) {
                *flags |= NGHTTP2_DATA_FLAG_EOF;
            } else if (n == 0) {
                p->deferred_ = true;   // tunnelWrite / tunnelEnd resume
                return NGHTTP2_ERR_DEFERRED;
            }
        }
        return static_cast<nghttp2_ssize>(n);
    }
};

// ---------------------------------------------------------------------------
// The protocol
// ---------------------------------------------------------------------------

std::unique_ptr<ConnProtocol> makeHttp2ClientProtocol(std::shared_ptr<DialJob> job) {
    return std::make_unique<Http2ClientProtocol>(std::move(job));
}

Http2ClientProtocol::~Http2ClientProtocol() {
    done_ = true;
    if (port_) {
        std::shared_ptr<H2StreamPort> port = std::move(port_);
        port->streamReset(H2StreamPort::kCancel);   // never a dangling tunnel
    }
    if (session_) nghttp2_session_del(session_);
}

void Http2ClientProtocol::onOpen(Conn& c) {
    conn_ = &c;
    nghttp2_session_callbacks* cbs = nullptr;
    nghttp2_option* opt = nullptr;
    if (nghttp2_session_callbacks_new(&cbs) != 0 || nghttp2_option_new(&opt) != 0) {
        if (cbs) nghttp2_session_callbacks_del(cbs);
        failDial("ENOMEM", "HTTP/2 session ENOMEM " + job_->target());
        return;
    }
    nghttp2_session_callbacks_set_on_begin_headers_callback(cbs, &Cb::beginHeaders);
    nghttp2_session_callbacks_set_on_header_callback(cbs, &Cb::header);
    nghttp2_session_callbacks_set_on_frame_recv_callback(cbs, &Cb::frameRecv);
    nghttp2_session_callbacks_set_on_data_chunk_recv_callback(cbs, &Cb::dataChunk);
    nghttp2_session_callbacks_set_on_stream_close_callback(cbs, &Cb::streamClose);
    nghttp2_option_set_no_auto_window_update(opt, 1);
    nghttp2_option_set_max_continuations(opt, 8);
    nghttp2_option_set_max_settings(opt, 32);
    int rv = nghttp2_session_client_new2(&session_, cbs, this, opt);
    nghttp2_session_callbacks_del(cbs);
    nghttp2_option_del(opt);
    if (rv != 0) {
        session_ = nullptr;
        failDial("ENOMEM", "HTTP/2 session ENOMEM " + job_->target());
        return;
    }
    nghttp2_settings_entry iv[] = {
        {NGHTTP2_SETTINGS_ENABLE_PUSH, 0},
        {NGHTTP2_SETTINGS_INITIAL_WINDOW_SIZE, static_cast<uint32_t>(kInitialWindow)},
    };
    (void)nghttp2_submit_settings(session_, NGHTTP2_FLAG_NONE, iv, sizeof iv / sizeof iv[0]);
    if (job_->deadline() > 0) c.setDeadline(Conn::kTimerHeaders, job_->deadline());
    (void)c.setNoDelay(true);
    afterIo();
}

bool Http2ClientProtocol::wantsRead() const {
    if (done_ || !session_ || outHigh_) return false;
    return nghttp2_session_want_read(session_) != 0;
}

void Http2ClientProtocol::onData(Conn&, std::string_view bytes) {
    if (done_) return;
    in_.append(bytes.data(), bytes.size());
    afterIo();
}

void Http2ClientProtocol::process() {
    if (processing_ || done_ || in_.empty()) return;
    processing_ = true;
    std::string chunk;
    chunk.swap(in_);
    nghttp2_ssize rv = nghttp2_session_mem_recv2(session_, reinterpret_cast<const uint8_t*>(chunk.data()),
                                                 chunk.size());
    processing_ = false;
    if (done_) return;
    if (rv < 0) {
        if (phase_ == Phase::Settings || phase_ == Phase::Requested) {
            failDial("ERR_WS_HANDSHAKE",
                     std::string("invalid HTTP/2 from the server: ") + nghttp2_strerror(static_cast<int>(rv)));
            return;
        }
        // A connection error after the answer: nghttp2 queued a GOAWAY.
        streamGone(H2StreamPort::kCancel);
        ending_ = true;
    }
}

void Http2ClientProtocol::flush() {
    if (done_ || !session_ || !conn_) return;
    if (flushing_) {
        flushAgain_ = true;
        return;
    }
    flushing_ = true;
    do {
        flushAgain_ = false;
        while (!done_ && conn_->outbound() < Conn::kLowWatermark) {
            std::string buf;
            bool more = true;
            while (buf.size() < Conn::kLowWatermark) {
                const uint8_t* data = nullptr;
                nghttp2_ssize n = nghttp2_session_mem_send2(session_, &data);
                if (n < 0) {
                    more = false;
                    ending_ = true;   // a fatal session error: close after what is framed
                    streamGone(H2StreamPort::kCancel);
                    break;
                }
                if (n == 0) {
                    more = false;
                    break;
                }
                buf.append(reinterpret_cast<const char*>(data), static_cast<size_t>(n));
            }
            if (!buf.empty()) conn_->write(std::move(buf), nullptr);
            if (!more) break;
        }
    } while (flushAgain_ && !done_);
    flushing_ = false;
    if (conn_->outbound() >= Conn::kLowWatermark) outHigh_ = true;
}

void Http2ClientProtocol::afterIo() {
    if (done_ || !session_ || !conn_) return;
    if (processing_) return;   // the running step frames it after the input
    if (flushing_) {
        flushAgain_ = true;
        return;
    }
    flush();
    if (done_) return;
    process();
    if (done_) return;
    flush();
    if (done_) return;
    if (fallback_) {
        // The GOAWAY is queued: close, and dial the same address again over
        // HTTP/1.1 (W12).
        fallback_ = false;
        done_ = true;
        conn_->setDeadline(Conn::kTimerHeaders, 0);
        conn_->closeGraceful(kCloseDrainMs);
        std::shared_ptr<DialJob> job = job_;
        job->redialHttp1();
        return;
    }
    if (notifyWritable_ && port_ && tunnelQueued() < Conn::kLowWatermark) {
        notifyWritable_ = false;
        std::shared_ptr<H2StreamPort> port = port_;
        port->streamWritable();
        if (done_) return;
    }
    bool wantRead = nghttp2_session_want_read(session_) != 0;
    bool wantWrite = nghttp2_session_want_write(session_) != 0;
    if (!wantRead && !wantWrite) {
        // The session is over (the server's GOAWAY with no stream left, or ours).
        if (phase_ == Phase::Settings || phase_ == Phase::Requested) {
            failDial("ERR_WS_HANDSHAKE", "the server closed the HTTP/2 session during the opening handshake");
            return;
        }
        streamGone(H2StreamPort::kCancel);
        ending_ = true;
    }
    if (ending_ && !wantWrite) {
        done_ = true;
        conn_->setDeadline(Conn::kTimerHeaders, 0);
        conn_->closeGraceful(kCloseDrainMs);
        return;
    }
    conn_->updateInterest();
}

void Http2ClientProtocol::submitRequest() {
    const DialSpec& sp = job_->spec();
    std::vector<std::pair<std::string, std::string>> fields = {
        {":method", "CONNECT"},
        {":protocol", "websocket"},
        {":scheme", "https"},
        {":path", sp.target.empty() ? std::string("/") : sp.target},
        {":authority", sp.authority},
    };
    for (const auto& h : sp.h2Headers) fields.push_back(h);
    std::vector<nghttp2_nv> nva;
    nva.reserve(fields.size());
    for (auto& f : fields) {
        nva.push_back({reinterpret_cast<uint8_t*>(f.first.data()), reinterpret_cast<uint8_t*>(f.second.data()),
                       f.first.size(), f.second.size(), NGHTTP2_NV_FLAG_NONE});
    }
    nghttp2_data_provider2 prov;
    prov.source.ptr = nullptr;
    prov.read_callback = &Cb::readData;
    int32_t id = nghttp2_submit_request2(session_, nullptr, nva.data(), nva.size(), &prov, nullptr);
    if (id < 0) {
        failDial("ERR_WS_HANDSHAKE", std::string("extended CONNECT refused: ") + nghttp2_strerror(id));
        return;
    }
    sid_ = id;
    phase_ = Phase::Requested;
}

void Http2ClientProtocol::endOfStream() {
    if (port_) {
        std::shared_ptr<H2StreamPort> port = port_;
        port->streamEnd();
    } else {
        heldEnd_ = true;
    }
}

void Http2ClientProtocol::streamGone(uint32_t code) {
    if (streamClosed_) return;
    streamClosed_ = true;
    closeCode_ = code;
    if (phase_ == Phase::Settings || phase_ == Phase::Requested) {
        failDial("ERR_WS_HANDSHAKE", "the server reset the opening stream");
        return;
    }
    if (port_) {
        std::shared_ptr<H2StreamPort> port = port_;
        port->streamReset(code);
    }
    // One WebSocket per connection (W12): the session ends with its stream.
    endSession();
}

void Http2ClientProtocol::endSession() {
    if (ending_ || !session_) return;
    ending_ = true;
    (void)nghttp2_session_terminate_session(session_, NGHTTP2_NO_ERROR);
}

void Http2ClientProtocol::failDial(const std::string& code, const std::string& message) {
    if (done_) return;
    done_ = true;
    job_->failed(code, message);
    if (conn_) conn_->abort(false);
}

void Http2ClientProtocol::onEof(Conn&) {
    if (done_) return;
    if (phase_ == Phase::Settings || phase_ == Phase::Requested) {
        failDial("ERR_WS_HANDSHAKE", "the server closed the connection during the opening handshake");
        return;
    }
    streamGone(H2StreamPort::kCancel);
    done_ = true;
    if (conn_) conn_->closeGraceful(kCloseDrainMs);
}

void Http2ClientProtocol::onError(Conn& c, int, const std::string& code) {
    if (done_) {
        if (!c.aborted()) c.abort(false);
        return;
    }
    if (phase_ == Phase::Settings || phase_ == Phase::Requested) {
        failDial(codeOfReason(code), code + " " + job_->target());
        return;
    }
    streamGone(H2StreamPort::kCancel);
    done_ = true;
    if (!c.aborted()) c.abort(false);
}

void Http2ClientProtocol::onWritable(Conn&) {
    outHigh_ = false;
    afterIo();
}

void Http2ClientProtocol::onTimer(Conn&, int timerId) {
    if (timerId != Conn::kTimerHeaders || done_) return;
    if (phase_ == Phase::Settings || phase_ == Phase::Requested) {
        failDial("ETIMEDOUT", "WebSocket handshake ETIMEDOUT " + job_->target());
    }
}

void Http2ClientProtocol::onCloseAll(Conn&) {
    bool handshaking = phase_ == Phase::Settings || phase_ == Phase::Requested;
    bool wasDone = done_;
    done_ = true;
    if (handshaking && !wasDone) {
        job_->failed("ECANCELED", "connect ECANCELED " + job_->target());
        return;
    }
    if (!streamClosed_) {
        streamClosed_ = true;
        closeCode_ = H2StreamPort::kCancel;
        if (port_) {
            std::shared_ptr<H2StreamPort> port = port_;
            port->streamReset(H2StreamPort::kCancel);
        }
    }
}

bool Http2ClientProtocol::bindPort(std::shared_ptr<H2StreamPort> port) {
    if (phase_ != Phase::Held || port_) return false;
    phase_ = Phase::Bound;
    port_ = port;
    std::string held = std::exchange(held_, std::string());
    port->bind(streamClosed_ || done_ ? nullptr : this, std::move(held));
    if (heldEnd_ && !streamClosed_) port->streamEnd();
    afterIo();
    return true;
}

// --- H2Tunnel -------------------------------------------------------------------------

bool Http2ClientProtocol::tunnelWrite(std::string bytes) {
    if (done_ || streamClosed_ || outEnd_ || sid_ < 0) return false;
    if (outOff_ > 0) {
        out_.erase(0, outOff_);
        outOff_ = 0;
    }
    out_ += bytes;
    if (out_.size() >= Conn::kLowWatermark) notifyWritable_ = true;
    if (deferred_) {
        deferred_ = false;
        (void)nghttp2_session_resume_data(session_, sid_);
    }
    afterIo();
    return true;
}

size_t Http2ClientProtocol::tunnelQueued() const { return out_.size() - outOff_; }

void Http2ClientProtocol::tunnelConsume(size_t n) {
    if (done_ || streamClosed_ || n == 0) return;
    (void)nghttp2_session_consume_stream(session_, sid_, n);
    afterIo();
}

void Http2ClientProtocol::tunnelEnd() {
    if (done_ || streamClosed_ || outEnd_) return;
    outEnd_ = true;
    if (deferred_) {
        deferred_ = false;
        (void)nghttp2_session_resume_data(session_, sid_);
    }
    afterIo();
}

void Http2ClientProtocol::tunnelReset(uint32_t code) {
    if (done_ || streamClosed_) return;
    (void)nghttp2_submit_rst_stream(session_, NGHTTP2_FLAG_NONE, sid_, code);
    afterIo();
}

} // namespace Eco::System

#else // _WIN32

namespace Eco::System {

std::unique_ptr<ConnProtocol> makeHttp2ClientProtocol(std::shared_ptr<DialJob>) { return nullptr; }

} // namespace Eco::System

#endif // _WIN32
