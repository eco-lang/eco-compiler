//===- Http2.cpp - HTTP/2 server connections on the IoReactor -------------===//
//
// See Http2.hpp (plans/eco-system-websockets.md §3.8, phase WS8). Reactor
// thread only; POSIX (nghttp2 is not built on Windows).
//
// Templates used: none (POD only, G1).
//
//===----------------------------------------------------------------------===//

#include "eco-system/HttpServer/Http2.hpp"

#include "eco-system/Core/IoReactor.hpp"
#include "eco-system/HttpServer/HttpTables.hpp"

#include <nghttp2/nghttp2.h>

#include <algorithm>
#include <cctype>
#include <cerrno>
#include <cstring>
#include <ctime>
#include <limits>
#include <utility>

namespace Eco::System::HttpSrv {

namespace {

IoReactor& reactor() { return IoReactor::instance(); }

int64_t after(int64_t ms) { return ms > 0 ? reactor().nowMs() + ms : 0; }

std::string lowerAscii(std::string_view s) {
    std::string out(s);
    for (char& c : out) c = static_cast<char>(std::tolower(static_cast<unsigned char>(c)));
    return out;
}

std::string trimmed(const std::string& s) {
    size_t a = 0, b = s.size();
    while (a < b && (s[a] == ' ' || s[a] == '\t')) ++a;
    while (b > a && (s[b - 1] == ' ' || s[b - 1] == '\t')) --b;
    return s.substr(a, b - a);
}

bool iequal(const std::string& a, const std::string& b) {
    if (a.size() != b.size()) return false;
    for (size_t i = 0; i < a.size(); ++i) {
        if (std::tolower(static_cast<unsigned char>(a[i])) !=
            std::tolower(static_cast<unsigned char>(b[i])))
            return false;
    }
    return true;
}

// RFC 9110 IMF-fixdate (as serializeH1).
std::string httpDate() {
    std::time_t t = std::time(nullptr);
    struct tm g;
    ::gmtime_r(&t, &g);
    char buf[64];
    std::strftime(buf, sizeof(buf), "%a, %d %b %Y %H:%M:%S GMT", &g);
    return buf;
}

// Connection-specific fields never sent over HTTP/2 (RFC 9113 §8.2.2), and
// the length the server writes itself.
bool droppedResponseField(const std::string& lower) {
    return lower == "connection" || lower == "keep-alive" || lower == "proxy-connection" ||
           lower == "transfer-encoding" || lower == "upgrade" || lower == "content-length";
}

} // namespace

// ---------------------------------------------------------------------------
// Stream state
// ---------------------------------------------------------------------------

struct Http2Protocol::Stream {
    enum class St : uint8_t { Headers, Body, Delivered, Responding, Tunnel };
    int32_t id = 0;
    St st = St::Headers;
    int64_t key = 0;
    // The request.
    std::string method, scheme, authority, path, protocol;
    std::vector<std::pair<std::string, std::string>> headers;
    int64_t cookieIndex = -1;   // the joined cookie field in `headers`
    size_t headerBytes = 0;
    bool tooLarge = false;
    std::string body;           // counted in buffered_
    bool isHead = false;
    bool connect = false;       // CONNECT, with or without :protocol
    int64_t deadline = 0;       // requestTimeout while Headers / Body
    // The response.
    bool rstAfterSend = false;  // RST_STREAM(NO_ERROR) after our END_STREAM
    std::string out;            // DATA still to frame (from outOff)
    size_t outOff = 0;
    bool outEnd = false;        // END_STREAM after `out`
    bool deferred = false;      // the data provider returned NGHTTP2_ERR_DEFERRED
    std::function<void(int)> done;
    // WS9 tunnels.
    std::unique_ptr<H2StreamHandler> tunnel;
    bool notifyWritable = false;   // `out` reached Conn::kLowWatermark: onWritable when it drains
    std::string tunnelIn;       // received before the tunnel was bound (counted in buffered_)
};

// ---------------------------------------------------------------------------
// nghttp2 callbacks
// ---------------------------------------------------------------------------

struct Http2Protocol::Cb {
    static Http2Protocol* self(void* ud) { return static_cast<Http2Protocol*>(ud); }

    static bool isRequestHeaders(const nghttp2_frame* f) {
        return f->hd.type == NGHTTP2_HEADERS && f->headers.cat == NGHTTP2_HCAT_REQUEST;
    }

    static int beginHeaders(nghttp2_session*, const nghttp2_frame* f, void* ud) {
        Http2Protocol* p = self(ud);
        if (p->done_ || !isRequestHeaders(f)) return 0;
        auto s = std::make_unique<Stream>();
        s->id = f->hd.stream_id;
        s->deadline = after(p->cfg_.requestMs);
        p->streams_[s->id] = std::move(s);
        return 0;
    }

    static int header(nghttp2_session*, const nghttp2_frame* f, const uint8_t* name, size_t nl,
                      const uint8_t* value, size_t vl, uint8_t, void* ud) {
        Http2Protocol* p = self(ud);
        if (!isRequestHeaders(f)) return 0;   // trailers are ignored
        Stream* s = p->find(f->hd.stream_id);
        if (!s || s->tooLarge) return 0;
        s->headerBytes += nl + vl + 32;
        if (static_cast<int64_t>(s->headerBytes) > p->cfg_.maxHeaderSize) {
            s->tooLarge = true;   // stop storing; 431 at the end of the block
            s->headers.clear();
            s->headers.shrink_to_fit();
            return 0;
        }
        std::string_view n(reinterpret_cast<const char*>(name), nl);
        std::string_view v(reinterpret_cast<const char*>(value), vl);
        if (!n.empty() && n[0] == ':') {
            if (n == ":method") s->method = v;
            else if (n == ":scheme") s->scheme = v;
            else if (n == ":authority") s->authority = v;
            else if (n == ":path") s->path = v;
            else if (n == ":protocol") s->protocol = v;
            return 0;
        }
        if (n == "cookie") {   // RFC 9113 §8.2.3: crumbs joined with "; "
            if (s->cookieIndex < 0) {
                s->cookieIndex = static_cast<int64_t>(s->headers.size());
                s->headers.emplace_back(std::string(n), std::string(v));
            } else {
                std::string& c = s->headers[static_cast<size_t>(s->cookieIndex)].second;
                c += "; ";
                c.append(v.data(), v.size());
            }
            return 0;
        }
        s->headers.emplace_back(std::string(n), std::string(v));
        return 0;
    }

    static int frameRecv(nghttp2_session*, const nghttp2_frame* f, void* ud) {
        Http2Protocol* p = self(ud);
        if (p->done_) return 0;
        bool end = (f->hd.flags & NGHTTP2_FLAG_END_STREAM) != 0;
        switch (f->hd.type) {
        case NGHTTP2_HEADERS: {
            Stream* s = p->find(f->hd.stream_id);
            if (!s) return 0;
            if (f->headers.cat == NGHTTP2_HCAT_REQUEST) p->endHeaders(*s);
            s = p->find(f->hd.stream_id);
            if (s && end) {
                if (s->st == Stream::St::Tunnel && s->tunnel) s->tunnel->onEnd();
                else p->requestComplete(*s);
            }
            return 0;
        }
        case NGHTTP2_DATA: {
            Stream* s = p->find(f->hd.stream_id);
            if (s && end) {
                if (s->st == Stream::St::Tunnel && s->tunnel) s->tunnel->onEnd();
                else p->requestComplete(*s);
            }
            return 0;
        }
        default:
            return 0;
        }
    }

    static int dataChunk(nghttp2_session* session, uint8_t, int32_t sid, const uint8_t* data,
                         size_t len, void* ud) {
        Http2Protocol* p = self(ud);
        Stream* s = p->find(sid);
        if (!s || p->done_) {
            (void)nghttp2_session_consume(session, sid, len);
            return 0;
        }
        switch (s->st) {
        case Stream::St::Headers:
        case Stream::St::Body:
            if (static_cast<int64_t>(s->body.size() + len) > p->cfg_.maxBodySize) {
                (void)nghttp2_session_consume(session, sid, len);
                p->ownResponse(*s, 413);
                return 0;
            }
            s->body.append(reinterpret_cast<const char*>(data), len);
            p->buffered_ += len;
            (void)nghttp2_session_consume_stream(session, sid, len);
            p->connPending_ += len;
            p->consumeConnection();
            return 0;
        case Stream::St::Delivered:
            if (s->connect) {
                // A CONNECT waiting for its answer: kept for a tunnel (WS9);
                // the stream window (64 KiB) bounds it.
                s->tunnelIn.append(reinterpret_cast<const char*>(data), len);
                p->buffered_ += len;
                p->connPending_ += len;
                p->consumeConnection();
                return 0;
            }
            (void)nghttp2_session_consume(session, sid, len);
            return 0;
        case Stream::St::Tunnel:
            (void)nghttp2_session_consume_connection(session, len);
            if (s->tunnel) {
                s->tunnel->onData(std::string_view(reinterpret_cast<const char*>(data), len));
            }
            return 0;
        default:
            (void)nghttp2_session_consume(session, sid, len);
            return 0;
        }
    }

    static int streamClose(nghttp2_session*, int32_t sid, uint32_t code, void* ud) {
        self(ud)->closeStream(sid, code);
        return 0;
    }

    static int frameSend(nghttp2_session* session, const nghttp2_frame* f, void* ud) {
        Http2Protocol* p = self(ud);
        if ((f->hd.type != NGHTTP2_HEADERS && f->hd.type != NGHTTP2_DATA) ||
            (f->hd.flags & NGHTTP2_FLAG_END_STREAM) == 0)
            return 0;
        Stream* s = p->find(f->hd.stream_id);
        if (!s) return 0;
        if (s->done) {
            p->sentDones_.push_back(std::move(s->done));
            s->done = nullptr;
        }
        if (s->rstAfterSend && nghttp2_session_get_stream_remote_close(session, s->id) == 0) {
            s->rstAfterSend = false;
            (void)nghttp2_submit_rst_stream(session, NGHTTP2_FLAG_NONE, s->id, NGHTTP2_NO_ERROR);
        }
        return 0;
    }

    static int frameNotSend(nghttp2_session*, const nghttp2_frame* f, int, void* ud) {
        Http2Protocol* p = self(ud);
        if (f->hd.type != NGHTTP2_HEADERS && f->hd.type != NGHTTP2_DATA) return 0;
        Stream* s = p->find(f->hd.stream_id);
        if (s && s->done) {
            auto d = std::move(s->done);
            s->done = nullptr;
            d(ECANCELED);
        }
        return 0;
    }

    static nghttp2_ssize readData(nghttp2_session*, int32_t sid, uint8_t* buf, size_t len,
                                  uint32_t* flags, nghttp2_data_source*, void* ud) {
        Http2Protocol* p = self(ud);
        Stream* s = p->find(sid);
        if (!s) return NGHTTP2_ERR_TEMPORAL_CALLBACK_FAILURE;
        size_t avail = s->out.size() - s->outOff;
        size_t n = std::min(len, avail);
        if (n > 0) std::memcpy(buf, s->out.data() + s->outOff, n);
        s->outOff += n;
        if (s->outOff == s->out.size()) {
            s->out.clear();
            s->outOff = 0;
            if (s->outEnd) {
                *flags |= NGHTTP2_DATA_FLAG_EOF;
            } else if (n == 0) {
                s->deferred = true;   // a tunnel with nothing queued (tunnelWrite resumes)
                return NGHTTP2_ERR_DEFERRED;
            }
        }
        return static_cast<nghttp2_ssize>(n);
    }
};

// ---------------------------------------------------------------------------
// The protocol
// ---------------------------------------------------------------------------

Http2Protocol::Http2Protocol(std::shared_ptr<ServerReactorState> srv, std::shared_ptr<H2Shared> sh)
    : srv_(std::move(srv)), sh_(std::move(sh)), cfg_(*srv_->cfg) {}

Http2Protocol::~Http2Protocol() {
    done_ = true;
    streams_.clear();
    if (session_) nghttp2_session_del(session_);
}

Http2Protocol::Stream* Http2Protocol::find(int32_t id) {
    auto it = streams_.find(id);
    return it == streams_.end() ? nullptr : it->second.get();
}

bool Http2Protocol::capped() const {
    return cfg_.maxConcurrentStreams > 0 &&
           static_cast<int64_t>(keyStream_.size()) >= cfg_.maxConcurrentStreams;
}

void Http2Protocol::onOpen(Conn& c) {
    conn_ = &c;
    nghttp2_session_callbacks* cbs = nullptr;
    nghttp2_option* opt = nullptr;
    if (nghttp2_session_callbacks_new(&cbs) != 0 || nghttp2_option_new(&opt) != 0) {
        if (cbs) nghttp2_session_callbacks_del(cbs);
        done_ = true;
        c.abort(false);
        return;
    }
    nghttp2_session_callbacks_set_on_begin_headers_callback(cbs, &Cb::beginHeaders);
    nghttp2_session_callbacks_set_on_header_callback(cbs, &Cb::header);
    nghttp2_session_callbacks_set_on_frame_recv_callback(cbs, &Cb::frameRecv);
    nghttp2_session_callbacks_set_on_data_chunk_recv_callback(cbs, &Cb::dataChunk);
    nghttp2_session_callbacks_set_on_stream_close_callback(cbs, &Cb::streamClose);
    nghttp2_session_callbacks_set_on_frame_send_callback(cbs, &Cb::frameSend);
    nghttp2_session_callbacks_set_on_frame_not_send_callback(cbs, &Cb::frameNotSend);

    nghttp2_option_set_no_auto_window_update(opt, 1);
    nghttp2_option_set_max_continuations(opt, 8);
    nghttp2_option_set_stream_reset_rate_limit(opt, 1000, 33);
    nghttp2_option_set_max_outbound_ack(opt, 1000);
    nghttp2_option_set_max_settings(opt, 32);

    int rv = nghttp2_session_server_new2(&session_, cbs, this, opt);
    nghttp2_session_callbacks_del(cbs);
    nghttp2_option_del(opt);
    if (rv != 0) {
        session_ = nullptr;
        done_ = true;
        c.abort(false);
        return;
    }

    std::vector<nghttp2_settings_entry> iv;
    if (cfg_.maxConcurrentStreams >= 0) {   // only when set (W19)
        iv.push_back({NGHTTP2_SETTINGS_MAX_CONCURRENT_STREAMS,
                      static_cast<uint32_t>(std::min<int64_t>(cfg_.maxConcurrentStreams,
                                                              std::numeric_limits<int32_t>::max()))});
    }
    iv.push_back({NGHTTP2_SETTINGS_MAX_HEADER_LIST_SIZE,
                  static_cast<uint32_t>(std::clamp<int64_t>(cfg_.maxHeaderSize, 0,
                                                            std::numeric_limits<uint32_t>::max()))});
    iv.push_back({NGHTTP2_SETTINGS_ENABLE_PUSH, 0});
    iv.push_back({NGHTTP2_SETTINGS_ENABLE_CONNECT_PROTOCOL, 1});
    iv.push_back({NGHTTP2_SETTINGS_INITIAL_WINDOW_SIZE, static_cast<uint32_t>(kInitialWindow)});
    iv.push_back({NGHTTP2_SETTINGS_NO_RFC7540_PRIORITIES, 1});
    (void)nghttp2_submit_settings(session_, NGHTTP2_FLAG_NONE, iv.data(), iv.size());

    if (srv_->closing) {
        closing_ = true;
        (void)nghttp2_session_terminate_session(session_, NGHTTP2_NO_ERROR);
    } else {
        c.setDeadline(Conn::kTimerIdle, after(cfg_.headersMs));   // the first bytes (slowloris)
    }
    afterIo(c);
}

bool Http2Protocol::wantsRead() const {
    if (done_ || peerEof_ || outHigh_ || !session_) return false;
    if (in_.size() - inOff_ >= kInBuffer) return false;
    return nghttp2_session_want_read(session_) != 0;
}

void Http2Protocol::onData(Conn& c, std::string_view bytes) {
    if (done_) return;
    if (!bytes.empty()) sawData_ = true;
    in_.append(bytes.data(), bytes.size());
    afterIo(c);
}

void Http2Protocol::process(Conn& c) {
    if (processing_ || done_) return;
    processing_ = true;
    while (!done_ && inOff_ < in_.size()) {
        size_t avail = in_.size() - inOff_;
        size_t take = 0;
        if (prefaceLeft_ > 0) {
            take = std::min(avail, prefaceLeft_);
            prefaceLeft_ -= take;
        } else if (frameLeft_ > 0) {
            take = std::min(avail, frameLeft_);
            frameLeft_ -= take;
        } else {
            // A frame boundary: one frame at a time, so the outstanding cap
            // (maxConcurrentStreams) stops exactly at a frame.
            if (capped()) break;
            if (avail < 9) break;
            const auto* h = reinterpret_cast<const unsigned char*>(in_.data() + inOff_);
            size_t total = 9 + ((static_cast<size_t>(h[0]) << 16) | (static_cast<size_t>(h[1]) << 8) |
                                static_cast<size_t>(h[2]));
            take = std::min(avail, total);
            frameLeft_ = total - take;
        }
        nghttp2_ssize rv = nghttp2_session_mem_recv2(
            session_, reinterpret_cast<const uint8_t*>(in_.data() + inOff_), take);
        if (rv < 0 || static_cast<size_t>(rv) != take) {
            processing_ = false;
            fatal(c);
            return;
        }
        inOff_ += take;
    }
    if (inOff_ == in_.size()) {
        in_.clear();
        inOff_ = 0;
    } else if (inOff_ >= kInBuffer) {
        in_.erase(0, inOff_);
        inOff_ = 0;
    }
    processing_ = false;
}

void Http2Protocol::flush(Conn& c) {
    if (done_ || !session_) return;
    if (flushing_) {
        flushAgain_ = true;
        return;
    }
    flushing_ = true;
    do {
        flushAgain_ = false;
        while (!done_ && c.outbound() < Conn::kLowWatermark) {
            std::string buf;
            bool more = true;
            while (buf.size() < Conn::kLowWatermark) {
                const uint8_t* data = nullptr;
                nghttp2_ssize n = nghttp2_session_mem_send2(session_, &data);
                if (n < 0) {
                    flushing_ = false;
                    if (!buf.empty()) c.write(std::move(buf), nullptr);
                    fatal(c);
                    return;
                }
                if (n == 0) {
                    more = false;
                    break;
                }
                buf.append(reinterpret_cast<const char*>(data), static_cast<size_t>(n));
            }
            if (buf.empty() && sentDones_.empty()) break;
            std::function<void(int)> d;
            if (!sentDones_.empty()) {
                std::vector<std::function<void(int)>> dones;
                dones.swap(sentDones_);
                d = [dones = std::move(dones)](int err) {
                    for (const auto& f : dones) {
                        if (f) f(err);
                    }
                };
            }
            c.write(std::move(buf), std::move(d));
            if (!more) break;
        }
    } while (flushAgain_ && !done_);
    flushing_ = false;
    if (c.outbound() >= Conn::kLowWatermark) outHigh_ = true;
}

void Http2Protocol::afterIo(Conn& c) {
    if (done_ || !session_) return;
    // WS9: a tunnel call made from inside nghttp2 (DATA handed to the codec,
    // which answers a ping) or while frames are written only queues: the
    // running step frames it (nghttp2 is never re-entered).
    if (processing_) return;
    if (flushing_) {
        flushAgain_ = true;
        return;
    }
    // Frame what is queued first (answered streams close when their
    // END_STREAM is out, so input held back by the cap then finds them
    // closed), then the input, then its answers (SETTINGS ACK, ...).
    flush(c);
    if (done_) return;
    process(c);
    if (done_) return;
    flush(c);
    if (done_) return;
    if (writableWaiters_) notifyWritable();
    if (done_) return;
    updateTimers(c);
    maybeClose(c);
    if (!done_) c.updateInterest();
}

// WS9: tunnels whose queue drained below the watermark may write again.
void Http2Protocol::notifyWritable() {
    writableWaiters_ = false;
    std::vector<int32_t> ids;
    for (const auto& kv : streams_) {
        const Stream& s = *kv.second;
        if (!s.notifyWritable) continue;
        if (s.out.size() - s.outOff < Conn::kLowWatermark) ids.push_back(kv.first);
        else writableWaiters_ = true;
    }
    for (int32_t id : ids) {
        Stream* s = find(id);
        if (!s || !s->notifyWritable) continue;
        s->notifyWritable = false;
        if (s->tunnel) s->tunnel->onWritable();
        if (done_) return;
    }
}

// A tunnel's handler is destroyed later, on the reactor thread: the stream
// may end inside a call the handler itself made (a reset framed by its own
// tunnelReset).
void Http2Protocol::retireTunnel(std::unique_ptr<H2StreamHandler> t, uint32_t code) {
    if (!t) return;
    std::shared_ptr<H2StreamHandler> sp(std::move(t));
    sp->onReset(code);
    reactor().submit([sp] {});
}

void Http2Protocol::maybeClose(Conn& c) {
    if (done_) return;
    bool wantRead = nghttp2_session_want_read(session_) != 0;
    bool wantWrite = nghttp2_session_want_write(session_) != 0;
    bool live = false;
    for (const auto& kv : streams_) {
        Stream::St st = kv.second->st;
        // A request still arriving can complete unless the peer half-closed.
        bool arriving = !peerEof_ && (st == Stream::St::Headers || st == Stream::St::Body);
        if (arriving || st == Stream::St::Delivered || st == Stream::St::Responding ||
            st == Stream::St::Tunnel) {
            live = true;
            break;
        }
    }
    bool finished = !wantRead && !wantWrite;
    bool drained = (peerEof_ || closing_) && !live && !wantWrite;
    if (!finished && !drained) return;
    // Everything framed is queued on the Conn: close after it (FIN, drain).
    done_ = true;
    for (auto& kv : streams_) {
        Stream& s = *kv.second;
        if (s.done) {
            auto d = std::move(s.done);
            s.done = nullptr;
            d(ECANCELED);
        }
        if (s.tunnel) s.tunnel->onReset(NGHTTP2_CANCEL);
    }
    c.setDeadline(Conn::kTimerIdle, 0);
    c.setDeadline(Conn::kTimerRequest, 0);
    c.closeGraceful(kCloseDrainMs);
}

void Http2Protocol::fatal(Conn& c) {
    // A connection error: nghttp2 has usually queued a GOAWAY; send what is
    // framed, then close.
    if (done_) return;
    if (session_) {
        for (int i = 0; i < 4; ++i) {   // bounded: the GOAWAY and little else
            const uint8_t* data = nullptr;
            nghttp2_ssize n = nghttp2_session_mem_send2(session_, &data);
            if (n <= 0) break;
            c.write(std::string(reinterpret_cast<const char*>(data), static_cast<size_t>(n)), nullptr);
        }
    }
    done_ = true;
    std::vector<std::function<void(int)>> dones;
    dones.swap(sentDones_);
    for (auto& d : dones) d(ECANCELED);
    for (auto& kv : streams_) {
        Stream& s = *kv.second;
        if (s.done) {
            auto d = std::move(s.done);
            s.done = nullptr;
            d(ECANCELED);
        }
        if (s.tunnel) s.tunnel->onReset(NGHTTP2_CANCEL);
    }
    c.setDeadline(Conn::kTimerIdle, 0);
    c.setDeadline(Conn::kTimerRequest, 0);
    c.closeGraceful(kCloseDrainMs);
}

void Http2Protocol::updateTimers(Conn& c) {
    if (done_) return;
    if (closing_) {
        c.setDeadline(Conn::kTimerIdle, srv_->closeDeadline);
    } else if (sawData_) {
        if (streams_.empty() && keyStream_.empty()) {
            c.setDeadline(Conn::kTimerIdle, after(cfg_.keepAliveMs));
        } else {
            c.setDeadline(Conn::kTimerIdle, 0);
        }
    }
    int64_t earliest = 0;
    for (const auto& kv : streams_) {
        const Stream& s = *kv.second;
        if ((s.st == Stream::St::Headers || s.st == Stream::St::Body) && s.deadline > 0 &&
            (earliest == 0 || s.deadline < earliest))
            earliest = s.deadline;
    }
    c.setDeadline(Conn::kTimerRequest, earliest);
}

void Http2Protocol::onEof(Conn& c) {
    peerEof_ = true;
    afterIo(c);
}

void Http2Protocol::onError(Conn& c, int /*err*/, const std::string& /*code*/) {
    if (!c.aborted()) c.abort(false);   // onCloseAll fails what is pending
}

void Http2Protocol::onWritable(Conn& c) {
    outHigh_ = false;
    afterIo(c);
}

void Http2Protocol::onTimer(Conn& c, int timerId) {
    if (done_) return;
    if (timerId == Conn::kTimerIdle) {
        if (closing_) {
            c.abort(false);   // closeServer's deadline
            return;
        }
        // Idle (or no first bytes): GOAWAY(NO_ERROR); the session then ends.
        (void)nghttp2_session_terminate_session(session_, NGHTTP2_NO_ERROR);
        afterIo(c);
        return;
    }
    if (timerId == Conn::kTimerRequest) {
        int64_t now = reactor().nowMs();
        std::vector<int32_t> expired;
        for (const auto& kv : streams_) {
            const Stream& s = *kv.second;
            if ((s.st == Stream::St::Headers || s.st == Stream::St::Body) && s.deadline > 0 &&
                s.deadline <= now)
                expired.push_back(s.id);
        }
        for (int32_t id : expired) {
            if (Stream* s = find(id)) ownResponse(*s, 408);
        }
        afterIo(c);
    }
}

void Http2Protocol::onCloseAll(Conn& /*c*/) {
    done_ = true;
    std::vector<std::function<void(int)>> dones;
    dones.swap(sentDones_);
    for (auto& d : dones) d(ECANCELED);
    for (auto& kv : streams_) {
        Stream& s = *kv.second;
        if (s.done) {
            auto d = std::move(s.done);
            s.done = nullptr;
            d(ECANCELED);
        }
        if (s.tunnel) retireTunnel(std::move(s.tunnel), NGHTTP2_CANCEL);
    }
    // The keys stay in sh_->keys: the close hook reports them (ConnGone).
}

// --- Requests ------------------------------------------------------------------

void Http2Protocol::endHeaders(Stream& s) {
    if (s.st != Stream::St::Headers) return;
    if (s.tooLarge) {
        ownResponse(s, 431);
        return;
    }
    s.st = Stream::St::Body;
    s.isHead = s.method == "HEAD";
    // :authority and Host must agree (§3.8); Host alone gives the authority.
    // A Content-Length over maxBodySize is answered before any body (413).
    for (const auto& h : s.headers) {
        if (h.first == "content-length") {
            std::string v = trimmed(h.second);
            bool digits = !v.empty() && v.size() <= 18 &&
                          std::all_of(v.begin(), v.end(), [](char ch) { return ch >= '0' && ch <= '9'; });
            if (digits && std::stoll(v) > cfg_.maxBodySize) {
                ownResponse(s, 413);
                return;
            }
            continue;
        }
        if (h.first != "host") continue;
        std::string host = trimmed(h.second);
        if (s.authority.empty()) {
            s.authority = host;
        } else if (!iequal(host, s.authority)) {
            ownResponse(s, 400);
            return;
        }
    }
    if (s.method == "CONNECT") {
        s.connect = true;
        if (!s.protocol.empty() && lowerAscii(s.protocol) != "websocket") {
            ownResponse(s, 501);   // RFC 9220 §3: an unknown :protocol
            return;
        }
        deliver(s);   // on HEADERS: a CONNECT never ends
    }
}

void Http2Protocol::requestComplete(Stream& s) {
    if (s.st == Stream::St::Body) deliver(s);
}

void Http2Protocol::deliver(Stream& s) {
    int64_t key = nextResponseKey();
    HttpEvent ev;
    ev.kind = HttpEvent::Kind::Request;
    ev.gen = cfg_.gen;
    ev.serverId = cfg_.serverId;
    ev.key = key;
    if (conn_) ev.conn = std::static_pointer_cast<Conn>(conn_->shared_from_this());
    RequestData& r = ev.req;
    r.method = s.method;
    r.target = s.path.empty() ? s.authority : s.path;
    std::string scheme = (s.scheme == "http" || s.scheme == "https") ? s.scheme
                         : (cfg_.tls ? "https" : "http");
    std::string authority = s.authority.empty() ? cfg_.fallbackAuthority : s.authority;
    std::string path;
    if (s.path.empty() || s.path == "*") path = "/";
    else if (s.path[0] == '/') path = s.path;
    else path = "/" + s.path;
    r.url = scheme + "://" + authority + path;
    r.headers = std::move(s.headers);
    s.headers.clear();
    buffered_ -= std::min(buffered_, s.body.size());
    r.body = std::move(s.body);
    s.body.clear();
    r.flags = 2 | (cfg_.tls ? 4 : 0);
    if (s.connect && !s.protocol.empty()) r.upgrade = "websocket";
    r.isHead = s.isHead;
    r.remote = sh_->remote;
    s.key = key;
    s.st = Stream::St::Delivered;
    s.deadline = 0;
    keyStream_[key] = s.id;
    sh_->keys.insert(key);
    postHttpEvent(std::move(ev));
    consumeConnection();
}

void Http2Protocol::releaseBody(Stream& s) {
    buffered_ -= std::min(buffered_, s.body.size() + s.tunnelIn.size());
    s.body.clear();
    s.body.shrink_to_fit();
    s.tunnelIn.clear();
    consumeConnection();
}

void Http2Protocol::consumeConnection() {
    if (connPending_ == 0 || !session_) return;
    size_t budget = static_cast<size_t>(
        std::max<int64_t>(cfg_.maxBodySize * 2, static_cast<int64_t>(kInitialWindow)));
    if (buffered_ > budget) return;   // released when bodies are delivered or dropped
    (void)nghttp2_session_consume_connection(session_, connPending_);
    connPending_ = 0;
}

void Http2Protocol::ownResponse(Stream& s, int64_t status) {
    releaseBody(s);
    s.headers.clear();
    s.st = Stream::St::Responding;
    s.deadline = 0;
    s.rstAfterSend = true;   // RST_STREAM(NO_ERROR) if the request is still open
    ResponseData r;
    r.status = status;
    if (!submitResponse(s, r, false)) {
        (void)nghttp2_submit_rst_stream(session_, NGHTTP2_FLAG_NONE, s.id, NGHTTP2_INTERNAL_ERROR);
    }
}

bool Http2Protocol::submitResponse(Stream& s, const ResponseData& r, bool tunnelHead) {
    int64_t status = (r.status < 200 || r.status > 999) ? 500 : r.status;   // 1xx / 101 → 500
    bool noBody = status == 204 || status == 304;
    std::vector<std::pair<std::string, std::string>> fields;
    fields.reserve(r.headers.size() + 3);
    fields.emplace_back(":status", std::to_string(status));
    bool hasDate = false;
    for (const auto& h : r.headers) {
        if (h.first.empty() || h.first[0] == ':') continue;
        std::string name = lowerAscii(h.first);
        if (droppedResponseField(name)) continue;
        if (name == "te" && lowerAscii(trimmed(h.second)) != "trailers") continue;
        if (!nghttp2_check_header_name(reinterpret_cast<const uint8_t*>(name.data()), name.size()) ||
            !nghttp2_check_header_value(reinterpret_cast<const uint8_t*>(h.second.data()),
                                        h.second.size()))
            continue;
        if (name == "date") hasDate = true;
        fields.emplace_back(std::move(name), h.second);
    }
    if (!hasDate) fields.emplace_back("date", httpDate());
    if (!noBody && !tunnelHead) fields.emplace_back("content-length", std::to_string(r.body.size()));
    std::vector<nghttp2_nv> nva;
    nva.reserve(fields.size());
    for (auto& f : fields) {
        nva.push_back({reinterpret_cast<uint8_t*>(f.first.data()),
                       reinterpret_cast<uint8_t*>(f.second.data()), f.first.size(), f.second.size(),
                       NGHTTP2_NV_FLAG_NONE});
    }
    bool data = tunnelHead || (!noBody && !s.isHead && !r.body.empty());
    int rv;
    if (data) {
        s.out = tunnelHead ? std::string() : r.body;
        s.outOff = 0;
        s.outEnd = !tunnelHead;
        s.deferred = false;
        nghttp2_data_provider2 prov;
        prov.source.ptr = nullptr;
        prov.read_callback = &Cb::readData;
        rv = nghttp2_submit_response2(session_, s.id, nva.data(), nva.size(), &prov);
    } else {
        rv = nghttp2_submit_response2(session_, s.id, nva.data(), nva.size(), nullptr);
    }
    return rv == 0;
}

void Http2Protocol::retireKey(int64_t key) {
    keyStream_.erase(key);
    sh_->keys.erase(key);
}

void Http2Protocol::closeStream(int32_t id, uint32_t code) {
    auto it = streams_.find(id);
    if (it == streams_.end()) return;
    std::unique_ptr<Stream> s = std::move(it->second);
    streams_.erase(it);
    buffered_ -= std::min(buffered_, s->body.size() + s->tunnelIn.size());
    if (s->done) {
        auto d = std::move(s->done);
        s->done = nullptr;
        d(ECANCELED);
    }
    if (s->tunnel) retireTunnel(std::move(s->tunnel), code);
    // A delivered, unanswered key stays outstanding (keyStream_) until the
    // program answers it or the connection closes (§3.8 rapid reset).
    consumeConnection();
}

bool Http2Protocol::respond(Conn& c, int64_t key, ResponseData r, bool /*forceClose*/,
                            std::function<void(int)>& done) {
    if (key == 0 || done_ || !session_) return false;
    auto it = keyStream_.find(key);
    if (it == keyStream_.end()) return false;
    int32_t sid = it->second;
    retireKey(key);
    Stream* s = find(sid);
    if (!s || s->st != Stream::St::Delivered) {
        afterIo(c);   // a reset stream: the cap may have freed
        return false;
    }
    s->key = 0;
    s->st = Stream::St::Responding;
    if (s->connect) {
        // A CONNECT not handed off: the request side is still open.
        buffered_ -= std::min(buffered_, s->tunnelIn.size());
        s->tunnelIn.clear();
        s->rstAfterSend = true;
    }
    if (!submitResponse(*s, r, false)) {
        (void)nghttp2_submit_rst_stream(session_, NGHTTP2_FLAG_NONE, sid, NGHTTP2_INTERNAL_ERROR);
        afterIo(c);
        return false;
    }
    s->done = std::move(done);
    done = nullptr;
    afterIo(c);
    return true;
}

void Http2Protocol::serverClosing(Conn& c) {
    if (done_ || !session_ || closing_) return;
    closing_ = true;
    (void)nghttp2_submit_goaway(session_, NGHTTP2_FLAG_NONE,
                                nghttp2_session_get_last_proc_stream_id(session_), NGHTTP2_NO_ERROR,
                                nullptr, 0);
    afterIo(c);
}

// --- WS9 hooks ------------------------------------------------------------------

bool Http2Protocol::tunnelPending(int64_t key) const {
    auto it = keyStream_.find(key);
    if (it == keyStream_.end()) return false;
    auto st = streams_.find(it->second);
    if (st == streams_.end()) return false;
    const Stream& s = *st->second;
    return s.st == Stream::St::Delivered && s.connect && !s.protocol.empty();
}

int32_t Http2Protocol::bindTunnel(Conn& c, int64_t key, ResponseData head,
                                  std::unique_ptr<H2StreamHandler> h, std::string& buffered) {
    if (done_ || !tunnelPending(key)) return 0;
    int32_t sid = keyStream_[key];
    retireKey(key);
    Stream* s = find(sid);
    s->key = 0;
    s->st = Stream::St::Tunnel;
    s->tunnel = std::move(h);
    buffered_ -= std::min(buffered_, s->tunnelIn.size());
    buffered = std::move(s->tunnelIn);
    s->tunnelIn.clear();
    if (!submitResponse(*s, head, true)) {
        (void)nghttp2_submit_rst_stream(session_, NGHTTP2_FLAG_NONE, sid, NGHTTP2_INTERNAL_ERROR);
    }
    afterIo(c);
    return sid;
}

void Http2Protocol::tunnelConsume(Conn& c, int32_t streamId, size_t n) {
    if (done_ || n == 0) return;
    (void)nghttp2_session_consume_stream(session_, streamId, n);
    afterIo(c);
}

bool Http2Protocol::tunnelWrite(Conn& c, int32_t streamId, std::string bytes) {
    Stream* s = find(streamId);
    if (done_ || !s || s->st != Stream::St::Tunnel || s->outEnd) return false;
    if (s->outOff > 0) {
        s->out.erase(0, s->outOff);
        s->outOff = 0;
    }
    s->out += bytes;
    if (s->out.size() >= Conn::kLowWatermark) {
        s->notifyWritable = true;
        writableWaiters_ = true;
    }
    if (s->deferred) {
        s->deferred = false;
        (void)nghttp2_session_resume_data(session_, streamId);
    }
    afterIo(c);
    return true;
}

void Http2Protocol::tunnelEnd(Conn& c, int32_t streamId) {
    Stream* s = find(streamId);
    if (done_ || !s || s->st != Stream::St::Tunnel || s->outEnd) return;
    s->outEnd = true;
    if (s->deferred) {
        s->deferred = false;
        (void)nghttp2_session_resume_data(session_, streamId);
    }
    afterIo(c);
}

void Http2Protocol::tunnelReset(Conn& c, int32_t streamId, uint32_t code) {
    if (done_ || !find(streamId)) return;
    (void)nghttp2_submit_rst_stream(session_, NGHTTP2_FLAG_NONE, streamId, code);
    afterIo(c);
}

void Http2Protocol::tunnelCancel(Conn& c, int64_t key) {
    if (done_ || !session_) return;
    auto it = keyStream_.find(key);
    if (it == keyStream_.end()) return;
    int32_t sid = it->second;
    retireKey(key);
    Stream* s = find(sid);
    if (s && s->st == Stream::St::Delivered) {
        s->key = 0;
        s->st = Stream::St::Responding;
        releaseBody(*s);
        (void)nghttp2_submit_rst_stream(session_, NGHTTP2_FLAG_NONE, sid, NGHTTP2_CANCEL);
    }
    afterIo(c);
}

size_t Http2Protocol::tunnelQueued(int32_t streamId) const {
    auto it = streams_.find(streamId);
    if (it == streams_.end()) return 0;
    return it->second->out.size() - it->second->outOff;
}

// ---------------------------------------------------------------------------
// The factory
// ---------------------------------------------------------------------------

std::unique_ptr<ConnProtocol> makeHttp2Protocol(Conn& c,
                                                const std::shared_ptr<ServerReactorState>& srv) {
    auto sh = std::make_shared<H2Shared>();
    {
        SocketEvent tmp;
        c.describe(tmp, std::string());
        sh->remote = tmp.remote;
    }
    (void)c.setNoDelay(true);
    srv->conns[&c] = std::static_pointer_cast<Conn>(c.shared_from_this());
    std::weak_ptr<ServerReactorState> weak = srv;
    uint64_t gen = srv->cfg->gen;
    int64_t serverId = srv->cfg->serverId;
    c.addCloseHook([weak, sh, gen, serverId](Conn& conn) {
        if (auto s = weak.lock()) s->conns.erase(&conn);
        std::vector<int64_t> keys(sh->keys.begin(), sh->keys.end());
        sh->keys.clear();
        std::sort(keys.begin(), keys.end());
        for (int64_t key : keys) {
            HttpEvent ev;
            ev.kind = HttpEvent::Kind::ConnGone;
            ev.gen = gen;
            ev.serverId = serverId;
            ev.key = key;
            postHttpEvent(std::move(ev));
        }
    });
    return std::make_unique<Http2Protocol>(srv, sh);
}

} // namespace Eco::System::HttpSrv
