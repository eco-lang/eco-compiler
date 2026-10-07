//===- HttpTransfer.cpp - Streaming HTTP transfers over libcurl -----------===//
//
// See HttpTransfer.hpp. Everything here is POD and runs on the transfer
// threads or, for the channel requests and cancel, on the main thread
// (G1): no Eco heap access, no Elm calls, no allocation on the Eco heap.
//
// Curl setup (Phase 8 step 8.2):
//   * CURLOPT_PROTOCOLS_STR / CURLOPT_REDIR_PROTOCOLS_STR "http,https",
//     CURLOPT_FOLLOWLOCATION 1 (at most 20 redirects).
//   * The header callback resets the header list on every `HTTP/` status
//     line (only the final hop's headers are kept), parses the status code
//     and statusText, lower-cases names, and posts the Headers event at the
//     end of the first block that is neither interim (1xx) nor a followed
//     redirect (3xx with Location).
//   * Timeout: CURLOPT_CONNECTTIMEOUT_MS plus a header deadline enforced by
//     the multi loop (and by a blocked upload read). It stops once the
//     headers have arrived (E.6).
//   * expectStream (discardNon2xx) on a non-2xx status: the body is never
//     delivered, so the transfer is aborted as soon as the headers are
//     posted (no bytes are downloaded only to be dropped); the body stream
//     reads EOF.
//   * Upload writes/closes that can no longer complete fail with a reason
//     ("network error: …", "the HTTP request was aborted", …), which the
//     stream table uses as the Cancelled reason.
//   * Stream bodies are sent with chunked transfer encoding (no
//     Content-Length, E.6); `Expect: 100-continue` is disabled.
//   * No CURLOPT_ACCEPT_ENCODING: the body stream carries the bytes as sent
//     (a program that asks for gzip can pipe through Stream.decompressor).
//
// Templates used: T7 (cancel), T9 (channel results; POD side).
//
//===----------------------------------------------------------------------===//

#include "eco-system/HttpStream/HttpTransfer.hpp"
#include "eco-system/Core/Core.hpp"

#include <curl/curl.h>

#include <algorithm>
#include <atomic>
#include <cctype>
#include <cerrno>
#include <chrono>
#include <condition_variable>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <deque>
#include <mutex>
#include <system_error>
#include <thread>
#include <unordered_map>

namespace Eco::System {

namespace {

constexpr size_t kChunk = 64 * 1024;
constexpr size_t kCap = 4 * kChunk;   // both directions: 4 chunks of 64 KiB
constexpr long kMaxRedirs = 20;

using Clock = std::chrono::steady_clock;

} // namespace

// ---------------------------------------------------------------------------
// Shared transfer state
// ---------------------------------------------------------------------------

struct HttpTransfer : std::enable_shared_from_this<HttpTransfer> {
    HttpTransfer(uint64_t tok, HttpRequestSpec s) : token(tok), spec(std::move(s)) {
        if (spec.timeoutMs > 0) {
            hasDeadline = true;
            deadline = Clock::now() + std::chrono::milliseconds(spec.timeoutMs);
        }
    }

    const uint64_t token;
    const HttpRequestSpec spec;
    bool hasDeadline = false;
    Clock::time_point deadline;

    std::mutex m;
    std::condition_variable cv;

    // --- Guarded by m ---
    CURLM* multi = nullptr;      // set while the thread drives curl (wakeup target)
    bool resolved = false;       // the task's event was posted, or the task was killed
    bool abort = false;
    bool timedOut = false;
    bool headersPosted = false;
    bool discardBody = false;
    bool finished = false;
    int curlCode = 0;
    std::string errReason;       // "network error: …" once finished with an error

    // Upload side.
    struct UpChunk {
        std::string bytes;
        size_t off = 0;
        uint64_t token = 0;
        bool acked = false;
    };
    std::deque<UpChunk> up;
    size_t upBytes = 0;          // unread bytes in `up`
    uint64_t upChannel = 0;
    bool upCloseRequested = false;
    uint64_t upCloseToken = 0;
    bool upClosePosted = false;
    bool upEofSent = false;      // the read callback returned 0
    bool upShut = false;

    // Download side.
    std::deque<std::string> down;
    size_t downBytes = 0;
    struct PendingRead {
        uint64_t token;
        size_t max;
    };
    std::deque<PendingRead> reads;
    uint64_t downChannel = 0;
    bool downShut = false;
};

namespace {

ChannelResult makeResult(uint64_t channel, uint64_t token, ChannelResult::Op op) {
    ChannelResult r;
    r.channelId = channel;
    r.token = token;
    r.op = op;
    return r;
}

// Why the upload side can take no more (an upload write or close fails).
std::string uploadFailure(const HttpTransfer& t) {
    if (t.abort || t.upShut) return "the HTTP request was aborted";   // kill / cancel
    if (!t.errReason.empty()) return t.errReason;                     // curl error
    return "the HTTP response ended before the request body was sent";
}

// Completes whatever the current state allows: pending reads, upload write
// acknowledgements, the upload close. Posts the results while holding t.m,
// so results of one channel are queued in request order (lock order:
// t.m → channel-results queue → Scheduler mutex).
void serviceLocked(HttpTransfer& t) {
    // --- Download: pending reads ---
    while (!t.reads.empty()) {
        HttpTransfer::PendingRead rd = t.reads.front();
        ChannelResult r = makeResult(t.downChannel, rd.token, ChannelResult::Op::Read);
        if (t.downShut) {
            r.err = ECANCELED;
        } else if (t.downBytes > 0) {
            size_t want = std::max<size_t>(1, rd.max);
            while (!t.down.empty() && r.bytes.size() < want) {
                std::string& c = t.down.front();
                size_t take = std::min(c.size(), want - r.bytes.size());
                r.bytes.append(c, 0, take);
                if (take == c.size()) {
                    t.down.pop_front();
                } else {
                    c.erase(0, take);
                }
                t.downBytes -= take;
            }
        } else if (t.discardBody && t.headersPosted) {
            r.eof = true;
        } else if (t.finished) {
            if (t.curlCode == CURLE_OK) {
                r.eof = true;
            } else {
                r.err = EIO;
                r.reason = t.errReason;
            }
        } else {
            break;   // wait for data
        }
        t.reads.pop_front();
        postChannelResult(std::move(r));
    }

    // --- Upload: acknowledge writes that fit the buffer, fail the rest ---
    bool upDead = t.finished || t.abort || t.upShut;
    size_t ahead = 0;
    for (auto it = t.up.begin(); it != t.up.end();) {
        size_t left = it->bytes.size() - it->off;
        if (!it->acked && upDead) {
            ChannelResult r = makeResult(t.upChannel, it->token, ChannelResult::Op::Write);
            r.err = ECANCELED;
            r.reason = uploadFailure(t);
            postChannelResult(std::move(r));
            t.upBytes -= left;
            it = t.up.erase(it);
            continue;
        }
        if (!it->acked && ahead < kCap) {
            ChannelResult r = makeResult(t.upChannel, it->token, ChannelResult::Op::Write);
            r.written = it->bytes.size();
            postChannelResult(std::move(r));
            it->acked = true;
        }
        ahead += left;
        ++it;
    }
    if (upDead) {
        t.up.clear();
        t.upBytes = 0;
    }
    if (t.upCloseRequested && !t.upClosePosted && (t.upEofSent || upDead)) {
        // Clean once curl has taken the end of the body; ECANCELED if the
        // transfer ended (or was aborted) before that.
        ChannelResult r = makeResult(t.upChannel, t.upCloseToken, ChannelResult::Op::Close);
        if (!t.upEofSent) {
            r.err = ECANCELED;
            r.reason = uploadFailure(t);
        }
        t.upClosePosted = true;
        postChannelResult(std::move(r));
    }
}

void abortLocked(HttpTransfer& t) {
    t.abort = true;
    t.cv.notify_all();
    if (t.multi) curl_multi_wakeup(t.multi);
    serviceLocked(t);
}

// ---------------------------------------------------------------------------
// Curl callbacks (transfer thread)
// ---------------------------------------------------------------------------

struct HeaderState {
    HttpTransfer* t = nullptr;
    CURL* easy = nullptr;
    long status = 0;
    std::string statusText;
    bool sawLocation = false;
    HttpHeaderList headers;
};

std::string lowerAscii(std::string s) {
    for (auto& c : s) c = static_cast<char>(std::tolower(static_cast<unsigned char>(c)));
    return s;
}

std::string trimHttp(const std::string& s) {
    size_t b = 0, e = s.size();
    while (b < e && (s[b] == ' ' || s[b] == '\t' || s[b] == '\r' || s[b] == '\n')) ++b;
    while (e > b && (s[e - 1] == ' ' || s[e - 1] == '\t' || s[e - 1] == '\r' || s[e - 1] == '\n')) --e;
    return s.substr(b, e - b);
}

bool isFollowedRedirect(long status, bool sawLocation) {
    return sawLocation && status >= 300 && status < 400 && status != 304;
}

// The end of the final response's header block: resolve the task.
void postHeaders(HeaderState& hs) {
    HttpTransfer& t = *hs.t;
    const char* eff = nullptr;
    curl_easy_getinfo(hs.easy, CURLINFO_EFFECTIVE_URL, &eff);
    std::lock_guard<std::mutex> lk(t.m);
    if (t.headersPosted) return;
    t.headersPosted = true;
    bool ok2xx = hs.status >= 200 && hs.status < 300;
    t.discardBody = t.spec.discardNon2xx && !ok2xx;
    if (t.resolved) return;   // killed: nobody resumes; the abort ends the transfer
    t.resolved = true;
    HttpEvent ev;
    ev.token = t.token;
    ev.kind = ok2xx ? HttpOutcome::GoodStatus : HttpOutcome::BadStatus;
    ev.status = hs.status;
    ev.statusText = hs.statusText;
    ev.url = eff ? eff : t.spec.url;
    ev.headers = std::move(hs.headers);
    ev.transfer = t.shared_from_this();
    hs.headers.clear();
    HttpStreamService::instance().post(std::move(ev));
    if (t.discardBody) {
        // expectStream, non-2xx: the body is never delivered, so stop the
        // transfer now instead of downloading it; reads answer EOF.
        abortLocked(t);
    } else {
        serviceLocked(t);
    }
}

size_t headerCb(char* buffer, size_t size, size_t nitems, void* userdata) {
    size_t n = size * nitems;
    auto* hs = static_cast<HeaderState*>(userdata);
    {
        std::lock_guard<std::mutex> lk(hs->t->m);
        if (hs->t->abort) return 0;              // stop the transfer
        if (hs->t->headersPosted) return n;      // trailers: ignored
    }
    std::string line(buffer, n);
    while (!line.empty() && (line.back() == '\r' || line.back() == '\n')) line.pop_back();

    if (line.rfind("HTTP/", 0) == 0) {
        // A new response (redirect hop or interim): reset (only the final
        // hop's headers are kept).
        hs->headers.clear();
        hs->sawLocation = false;
        hs->status = 0;
        hs->statusText.clear();
        size_t sp = line.find(' ');
        if (sp != std::string::npos) {
            size_t codeStart = sp + 1;
            size_t codeEnd = line.find(' ', codeStart);
            std::string code = line.substr(codeStart, codeEnd == std::string::npos
                                                          ? std::string::npos
                                                          : codeEnd - codeStart);
            hs->status = std::strtol(code.c_str(), nullptr, 10);
            if (codeEnd != std::string::npos) hs->statusText = trimHttp(line.substr(codeEnd + 1));
        }
        return n;
    }
    if (line.empty()) {
        bool interim = hs->status >= 100 && hs->status < 200;
        if (!interim && !isFollowedRedirect(hs->status, hs->sawLocation) && hs->status != 0) {
            postHeaders(*hs);
        }
        return n;
    }
    if ((line[0] == ' ' || line[0] == '\t') && !hs->headers.empty()) {
        // obs-fold continuation line.
        std::string more = trimHttp(line);
        if (!more.empty()) hs->headers.back().second += " " + more;
        return n;
    }
    size_t colon = line.find(':');
    if (colon == std::string::npos) return n;
    std::string name = lowerAscii(trimHttp(line.substr(0, colon)));
    std::string value = trimHttp(line.substr(colon + 1));
    if (name.empty()) return n;
    if (name == "location") hs->sawLocation = true;
    hs->headers.emplace_back(std::move(name), std::move(value));
    return n;
}

size_t writeCb(char* ptr, size_t size, size_t nmemb, void* userdata) {
    size_t n = size * nmemb;
    auto* t = static_cast<HttpTransfer*>(userdata);
    std::unique_lock<std::mutex> lk(t->m);
    if (t->abort || t->downShut) return 0;   // CURLE_WRITE_ERROR: ends the transfer
    if (!t->headersPosted) return n;          // a body we do not deliver
    if (t->discardBody) return n;             // expectStream, non-2xx: drop
    t->cv.wait(lk, [t, n] {
        return t->abort || t->downShut || t->downBytes == 0 || t->downBytes + n <= kCap;
    });
    if (t->abort || t->downShut) return 0;
    if (n == 0) return 0;
    t->down.emplace_back(ptr, n);
    t->downBytes += n;
    serviceLocked(*t);
    return n;
}

size_t readCb(char* buffer, size_t size, size_t nitems, void* userdata) {
    size_t max = size * nitems;
    auto* t = static_cast<HttpTransfer*>(userdata);
    std::unique_lock<std::mutex> lk(t->m);
    for (;;) {
        if (t->abort || t->upShut) return CURL_READFUNC_ABORT;
        if (t->upBytes > 0) break;
        if (t->upCloseRequested) {
            t->upEofSent = true;
            serviceLocked(*t);
            return 0;   // end of the chunked body
        }
        if (t->hasDeadline && !t->headersPosted) {
            if (Clock::now() >= t->deadline) {
                t->timedOut = true;
                return CURL_READFUNC_ABORT;
            }
            t->cv.wait_until(lk, t->deadline);
        } else {
            t->cv.wait(lk);
        }
    }
    size_t copied = 0;
    while (copied < max && !t->up.empty()) {
        auto& c = t->up.front();
        size_t take = std::min(max - copied, c.bytes.size() - c.off);
        std::memcpy(buffer + copied, c.bytes.data() + c.off, take);
        c.off += take;
        copied += take;
        t->upBytes -= take;
        if (c.off == c.bytes.size()) {
            if (!c.acked) {
                ChannelResult r = makeResult(t->upChannel, c.token, ChannelResult::Op::Write);
                r.written = c.bytes.size();
                postChannelResult(std::move(r));
            }
            t->up.pop_front();
        }
    }
    serviceLocked(*t);
    return copied;
}

bool isBadUrlCode(CURLcode c) {
    return c == CURLE_URL_MALFORMAT || c == CURLE_UNSUPPORTED_PROTOCOL;
}

// ---------------------------------------------------------------------------
// The transfer thread
// ---------------------------------------------------------------------------

curl_slist* buildHeaderList(const HttpRequestSpec& spec) {
    curl_slist* list = nullptr;
    auto add = [&list](const std::string& name, const std::string& value) {
        // A CR or LF would inject a header line: such a header is dropped.
        if (name.find_first_of("\r\n:") != std::string::npos || name.empty()) return;
        if (value.find_first_of("\r\n") != std::string::npos) return;
        // "Name;" sends an empty value ("Name:" would remove the header).
        std::string line = value.empty() ? name + ";" : name + ": " + value;
        list = curl_slist_append(list, line.c_str());
    };
    if (spec.bodyKind != 0 && !spec.contentType.empty()) add("Content-Type", spec.contentType);
    for (const auto& h : spec.headers) add(h.first, h.second);
    if (spec.bodyKind == 2) {
        list = curl_slist_append(list, "Transfer-Encoding: chunked");
        list = curl_slist_append(list, "Expect:");   // no 100-continue round trip
    }
    return list;
}

void configure(CURL* easy, HttpTransfer& t, HeaderState& hs, char* errbuf) {
    const HttpRequestSpec& spec = t.spec;
    curl_easy_setopt(easy, CURLOPT_URL, spec.url.c_str());
    curl_easy_setopt(easy, CURLOPT_NOSIGNAL, 1L);
    curl_easy_setopt(easy, CURLOPT_ERRORBUFFER, errbuf);
#if LIBCURL_VERSION_NUM >= 0x075500
    curl_easy_setopt(easy, CURLOPT_PROTOCOLS_STR, "http,https");
    curl_easy_setopt(easy, CURLOPT_REDIR_PROTOCOLS_STR, "http,https");
#else
    curl_easy_setopt(easy, CURLOPT_PROTOCOLS, long(CURLPROTO_HTTP | CURLPROTO_HTTPS));
    curl_easy_setopt(easy, CURLOPT_REDIR_PROTOCOLS, long(CURLPROTO_HTTP | CURLPROTO_HTTPS));
#endif
    curl_easy_setopt(easy, CURLOPT_FOLLOWLOCATION, 1L);
    curl_easy_setopt(easy, CURLOPT_MAXREDIRS, kMaxRedirs);
    curl_easy_setopt(easy, CURLOPT_BUFFERSIZE, static_cast<long>(kChunk));
    curl_easy_setopt(easy, CURLOPT_HEADERFUNCTION, headerCb);
    curl_easy_setopt(easy, CURLOPT_HEADERDATA, &hs);
    curl_easy_setopt(easy, CURLOPT_WRITEFUNCTION, writeCb);
    curl_easy_setopt(easy, CURLOPT_WRITEDATA, &t);
    if (spec.timeoutMs > 0) curl_easy_setopt(easy, CURLOPT_CONNECTTIMEOUT_MS, static_cast<long>(spec.timeoutMs));

    // TLS: verify the peer; honour CURL_CA_BUNDLE like elm/http's native
    // kernel (libcurl does not read it itself).
    curl_easy_setopt(easy, CURLOPT_SSL_VERIFYPEER, 1L);
    curl_easy_setopt(easy, CURLOPT_SSL_VERIFYHOST, 2L);
    if (const char* ca = std::getenv("CURL_CA_BUNDLE")) {
        if (*ca) curl_easy_setopt(easy, CURLOPT_CAINFO, ca);
    }

    // Method and body. GET/POST/HEAD use curl's own verbs, so a 301/302/303
    // after a POST is followed with a GET as browsers do; any other method
    // (or a GET with a body) is a custom request.
    const std::string& m = spec.method;
    bool hasBody = spec.bodyKind != 0;
    if (m == "HEAD") {
        curl_easy_setopt(easy, CURLOPT_NOBODY, 1L);
    } else if (hasBody || m == "POST") {
        if (spec.bodyKind == 2) {
            curl_easy_setopt(easy, CURLOPT_POST, 1L);
            curl_easy_setopt(easy, CURLOPT_READFUNCTION, readCb);
            curl_easy_setopt(easy, CURLOPT_READDATA, &t);
        } else {
            curl_easy_setopt(easy, CURLOPT_POSTFIELDSIZE_LARGE,
                             static_cast<curl_off_t>(spec.bytes.size()));
            curl_easy_setopt(easy, CURLOPT_COPYPOSTFIELDS, spec.bytes.data());
        }
        if (m != "POST") curl_easy_setopt(easy, CURLOPT_CUSTOMREQUEST, m.c_str());
    } else if (m != "GET" && !m.empty()) {
        curl_easy_setopt(easy, CURLOPT_CUSTOMREQUEST, m.c_str());
    }
}

// The end of the transfer: record the result, resolve the task if nothing
// did yet, and complete what the channels are waiting for.
void finishTransfer(HttpTransfer& t, CURLcode code, const char* errbuf, long status,
                    const char* effUrl) {
    std::lock_guard<std::mutex> lk(t.m);
    t.finished = true;
    t.multi = nullptr;
    t.curlCode = static_cast<int>(code);
    if (code != CURLE_OK) {
        std::string msg = (errbuf && *errbuf) ? std::string(errbuf) : curl_easy_strerror(code);
        t.errReason = "network error: " + msg;
    }
    if (!t.resolved) {
        t.resolved = true;
        HttpEvent ev;
        ev.token = t.token;
        if (code == CURLE_OK && status > 0) {
            // The response ended without a header block we recognised as
            // final (unusual): deliver it now, with an already-finished body.
            t.headersPosted = true;
            bool ok2xx = status >= 200 && status < 300;
            t.discardBody = t.spec.discardNon2xx && !ok2xx;
            ev.kind = ok2xx ? HttpOutcome::GoodStatus : HttpOutcome::BadStatus;
            ev.status = status;
            ev.url = effUrl ? effUrl : t.spec.url;
            ev.transfer = t.shared_from_this();
        } else if (t.timedOut || code == CURLE_OPERATION_TIMEDOUT) {
            ev.kind = HttpOutcome::Timeout;
        } else if (isBadUrlCode(code)) {
            ev.kind = HttpOutcome::BadUrl;
            ev.badUrl = t.spec.url;
        } else {
            ev.kind = HttpOutcome::NetworkError;
        }
        HttpStreamService::instance().post(std::move(ev));
    }
    t.cv.notify_all();
    serviceLocked(t);
}

void runTransfer(std::shared_ptr<HttpTransfer> tp) {
    HttpTransfer& t = *tp;
    char errbuf[CURL_ERROR_SIZE];
    errbuf[0] = '\0';
    HeaderState hs;
    hs.t = &t;

    CURL* easy = curl_easy_init();
    CURLM* multi = easy ? curl_multi_init() : nullptr;
    if (!easy || !multi) {
        if (easy) curl_easy_cleanup(easy);
        finishTransfer(t, CURLE_FAILED_INIT, "curl initialisation failed", 0, nullptr);
        return;
    }
    hs.easy = easy;
    configure(easy, t, hs, errbuf);
    curl_slist* headers = buildHeaderList(t.spec);
    if (headers) curl_easy_setopt(easy, CURLOPT_HTTPHEADER, headers);
    curl_multi_add_handle(multi, easy);
    {
        std::lock_guard<std::mutex> lk(t.m);
        t.multi = multi;
    }

    CURLcode result = CURLE_OK;
    bool done = false;
    while (!done) {
        int running = 0;
        CURLMcode mc = curl_multi_perform(multi, &running);
        int queued = 0;
        while (CURLMsg* msg = curl_multi_info_read(multi, &queued)) {
            if (msg->msg == CURLMSG_DONE) {
                result = msg->data.result;
                done = true;
            }
        }
        if (done) break;
        if (mc != CURLM_OK) {
            result = CURLE_FAILED_INIT;
            std::snprintf(errbuf, sizeof errbuf, "%s", curl_multi_strerror(mc));
            break;
        }
        if (running == 0) break;   // no DONE message: treat as finished
        int waitMs = 1000;
        {
            std::lock_guard<std::mutex> lk(t.m);
            if (t.abort) {
                result = CURLE_ABORTED_BY_CALLBACK;
                break;
            }
            if (t.hasDeadline && !t.headersPosted) {
                auto now = Clock::now();
                if (now >= t.deadline) {
                    t.timedOut = true;
                    result = CURLE_OPERATION_TIMEDOUT;
                    break;
                }
                auto left = std::chrono::duration_cast<std::chrono::milliseconds>(t.deadline - now).count() + 1;
                if (left < waitMs) waitMs = static_cast<int>(left);
            }
        }
        curl_multi_poll(multi, nullptr, 0, waitMs, nullptr);
    }
    {
        std::lock_guard<std::mutex> lk(t.m);
        t.multi = nullptr;   // no wakeups after this point
        if (t.timedOut && result != CURLE_OK) result = CURLE_OPERATION_TIMEDOUT;
    }

    long status = 0;
    curl_easy_getinfo(easy, CURLINFO_RESPONSE_CODE, &status);
    const char* eff = nullptr;
    curl_easy_getinfo(easy, CURLINFO_EFFECTIVE_URL, &eff);
    std::string effUrl = eff ? eff : "";
    curl_multi_remove_handle(multi, easy);
    curl_easy_cleanup(easy);
    curl_multi_cleanup(multi);
    if (headers) curl_slist_free_all(headers);

    finishTransfer(t, result, errbuf, status, effUrl.empty() ? nullptr : effUrl.c_str());
}

} // namespace

// ---------------------------------------------------------------------------
// HttpStreamService
// ---------------------------------------------------------------------------

struct HttpStreamService::Impl {
    std::mutex m;   // guards `live` and `events`
    std::unordered_map<uint64_t, std::weak_ptr<HttpTransfer>> live;
    std::deque<HttpEvent> events;
    std::atomic<size_t> count{0};
    Scheduler* sched = nullptr;
};

HttpStreamService::HttpStreamService() : impl_(new Impl()) {
    impl_->sched = &Scheduler::instance();   // bound on the main thread
    curl_global_init(CURL_GLOBAL_DEFAULT);
}

HttpStreamService& HttpStreamService::instance() {
    static auto* s = new HttpStreamService();   // leaky (§3.4)
    return *s;
}

std::shared_ptr<HttpTransfer> HttpStreamService::create(uint64_t token, HttpRequestSpec spec) {
    return std::make_shared<HttpTransfer>(token, std::move(spec));
}

bool HttpStreamService::start(const std::shared_ptr<HttpTransfer>& t) {
    {
        std::lock_guard<std::mutex> lk(impl_->m);
        impl_->live[t->token] = t;
    }
    try {
        std::thread([t, this] {
            runTransfer(t);
            std::lock_guard<std::mutex> lk(impl_->m);
            impl_->live.erase(t->token);
        }).detach();
        return true;
    } catch (const std::system_error&) {
        {
            std::lock_guard<std::mutex> lk(impl_->m);
            impl_->live.erase(t->token);
        }
        finishTransfer(*t, CURLE_FAILED_INIT, "could not start the transfer thread", 0, nullptr);
        return false;
    }
}

bool HttpStreamService::cancel(uint64_t token) {
    auto& self = instance();
    std::shared_ptr<HttpTransfer> t;
    {
        std::lock_guard<std::mutex> lk(self.impl_->m);
        auto it = self.impl_->live.find(token);
        if (it != self.impl_->live.end()) t = it->second.lock();
    }
    if (!t) return false;   // finished: its event is queued (the drain decrements)
    std::lock_guard<std::mutex> lk(t->m);
    bool removed = !t->resolved;
    t->resolved = true;
    abortLocked(*t);
    return removed;
}

void HttpStreamService::abort(HttpTransfer& t) {
    std::lock_guard<std::mutex> lk(t.m);
    if (!t.finished) abortLocked(t);
}

void HttpStreamService::post(HttpEvent ev) {
    {
        std::lock_guard<std::mutex> lk(impl_->m);
        impl_->events.push_back(std::move(ev));
        impl_->count.fetch_add(1, std::memory_order_acq_rel);
    }
    impl_->sched->notifyWorkAvailableFromAsync();
}

bool HttpStreamService::tryPop(HttpEvent& out) {
    std::lock_guard<std::mutex> lk(impl_->m);
    if (impl_->events.empty()) return false;
    out = std::move(impl_->events.front());
    impl_->events.pop_front();
    impl_->count.fetch_sub(1, std::memory_order_acq_rel);
    return true;
}

bool HttpStreamService::ready() const {
    return impl_->count.load(std::memory_order_acquire) > 0;
}

size_t HttpStreamService::liveTransfers() {
    std::lock_guard<std::mutex> lk(impl_->m);
    return impl_->live.size();
}

// ---------------------------------------------------------------------------
// HttpTransferChannel
// ---------------------------------------------------------------------------

HttpTransferChannel::HttpTransferChannel(std::shared_ptr<HttpTransfer> t, Dir dir)
    : t_(std::move(t)), dir_(dir) {
    std::lock_guard<std::mutex> lk(t_->m);
    if (dir_ == Dir::Upload) {
        t_->upChannel = id();
    } else {
        t_->downChannel = id();
    }
}

HttpTransferChannel::~HttpTransferChannel() {
    // Dropped without a graceful close (a heap reset, or an erased pair
    // that never closed): stop the transfer.
    if (!closeRequested_) shutdown();
}

void HttpTransferChannel::requestRead(uint64_t token, size_t maxBytes) {
    std::lock_guard<std::mutex> lk(t_->m);
    if (dir_ != Dir::Download) {
        ChannelResult r = makeResult(id(), token, ChannelResult::Op::Read);
        r.err = ENOTSUP;
        postChannelResult(std::move(r));
        return;
    }
    t_->reads.push_back({token, maxBytes});
    serviceLocked(*t_);
    t_->cv.notify_all();   // room in the download buffer
}

void HttpTransferChannel::requestWrite(uint64_t token, std::string bytes) {
    std::lock_guard<std::mutex> lk(t_->m);
    if (dir_ != Dir::Upload || t_->upCloseRequested) {
        ChannelResult r = makeResult(id(), token, ChannelResult::Op::Write);
        r.err = dir_ != Dir::Upload ? ENOTSUP : ECANCELED;
        postChannelResult(std::move(r));
        return;
    }
    if (bytes.empty()) {
        ChannelResult r = makeResult(id(), token, ChannelResult::Op::Write);
        bool dead = t_->finished || t_->abort || t_->upShut;
        if (dead) {
            r.err = ECANCELED;
            r.reason = uploadFailure(*t_);
        }
        postChannelResult(std::move(r));
        return;
    }
    size_t n = bytes.size();
    t_->up.push_back(HttpTransfer::UpChunk{std::move(bytes), 0, token, false});
    t_->upBytes += n;
    serviceLocked(*t_);
    t_->cv.notify_all();   // data for the read callback
}

void HttpTransferChannel::close(uint64_t token) {
    closeRequested_ = true;
    std::lock_guard<std::mutex> lk(t_->m);
    if (dir_ == Dir::Upload) {
        if (!t_->upCloseRequested) {
            t_->upCloseRequested = true;
            t_->upCloseToken = token;
            serviceLocked(*t_);
            t_->cv.notify_all();   // the read callback sends the end of the body
            return;
        }
        ChannelResult r = makeResult(id(), token, ChannelResult::Op::Close);
        r.err = ECANCELED;
        postChannelResult(std::move(r));
        return;
    }
    // Download: the reader is done (EOF or error seen). Pending reads (none
    // in practice) complete with ECANCELED.
    t_->downShut = true;
    serviceLocked(*t_);
    t_->cv.notify_all();
    ChannelResult r = makeResult(id(), token, ChannelResult::Op::Close);
    postChannelResult(std::move(r));
}

void HttpTransferChannel::shutdown() {
    closeRequested_ = true;
    std::lock_guard<std::mutex> lk(t_->m);
    if (dir_ == Dir::Upload) {
        t_->upShut = true;
    } else {
        t_->downShut = true;
    }
    if (!t_->finished) {
        abortLocked(*t_);   // a cancelled body stream ends the transfer
    } else {
        serviceLocked(*t_);
    }
}

} // namespace Eco::System
