//===- HttpTransfer.cpp - Streaming HTTP transfers over libcurl -----------===//
//
// A transfer's thread runs curl and its callbacks, which post events. The eco
// thread runs channel requests, `start` (whose failure path posts an event),
// `cancel`, and `abort` (called only from the event drain in HttpStream.cpp).
// Nothing here touches the GC heap.
// All of a transfer's mutable state is guarded by its mutex `m`, and the curl
// callbacks wait on its `cv`.
//
// `serviceLocked` answers whatever channel requests the state allows. The
// operations here call it under `m` after changing the state, so the results it
// posts for one side are in the order the requests were made. Some requests are
// answered at once instead: an empty upload write, a write after `close`, and a
// second `close`.
//
// Curl setup:
//   * Only http and https, for the request and for redirects, which are
//     followed up to 20 times.
//   * The header callback starts the header list again on every `HTTP/` status
//     line, so only the last response's fields are kept. The event is posted at
//     the end of the first header block that is neither interim (1xx) nor a
//     redirect that curl follows (3xx other than 304, with a non-empty Location
//     field). Body bytes that arrive before that are dropped.
//   * The header deadline is checked by the multi loop, which polls for at most
//     a second, or until just past the deadline, and by an upload read that is
//     waiting for data.
//   * Stream bodies are sent with chunked transfer encoding, and `Expect:` is
//     sent empty so that curl does not wait for a 100-continue. A HEAD request
//     sends no body: its stream body is accepted and dropped as it is written
//     (`upDiscard`), and neither header is sent.
//   * A proxy's answer to CONNECT is not passed to the header callback
//     (CURLOPT_SUPPRESS_CONNECT_HEADERS), so it is never taken for the
//     response.
//   * No `CURLOPT_ACCEPT_ENCODING`: the response body is delivered as sent,
//     still encoded if the server encoded it.
//   * Peer and host are verified, and a non-empty `CURL_CA_BUNDLE` in the
//     environment names the CA file.
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

/// The size in bytes of one buffer chunk, and the largest piece curl is asked
/// to hand the write callback at once.
constexpr size_t kChunk = 64 * 1024;
/// The bound, in bytes, on each side's buffer: 4 chunks.
constexpr size_t kCap = 4 * kChunk;
/// The most redirects curl follows for one request.
constexpr long kMaxRedirs = 20;

/// The clock the header deadline is measured on.
using Clock = std::chrono::steady_clock;

} // namespace

// ---------------------------------------------------------------------------
// Shared transfer state
// ---------------------------------------------------------------------------

/// The state of one transfer, shared by its thread, its channels and its event,
/// and kept alive by whichever of them holds it last; the service refers to it
/// weakly.
///
/// `token`, `spec`, `upDiscard`, `hasDeadline` and `deadline` are fixed at construction.
/// Everything else is guarded by `m`.
struct HttpTransfer : std::enable_shared_from_this<HttpTransfer> {
    /// Makes the state for `s`, whose event will carry `tok`, and starts the
    /// header deadline if `s` has a timeout.
    HttpTransfer(uint64_t tok, HttpRequestSpec s)
        : token(tok), spec(std::move(s)), upDiscard(spec.bodyKind == 2 && spec.method == "HEAD") {
        if (spec.timeoutMs > 0) {
            hasDeadline = true;
            deadline = Clock::now() + std::chrono::milliseconds(spec.timeoutMs);
        }
    }

    const uint64_t token;
    const HttpRequestSpec spec;
    /// A HEAD request with a stream body: curl sends no body, so upload writes
    /// are acknowledged and dropped at once and a close succeeds at once.
    const bool upDiscard;
    bool hasDeadline = false;
    Clock::time_point deadline;

    std::mutex m;
    /// Notified when the callbacks may be able to go on: data, room, the end of
    /// the body, an abort, or the end of the transfer.
    std::condition_variable cv;

    // --- Guarded by m ---
    /// The transfer's multi handle, owned by its thread, for `curl_multi_wakeup`.
    /// Null before the thread has set it up and once it stops driving curl.
    CURLM* multi = nullptr;
    bool resolved = false;       ///< The event was posted, or `cancel` claimed the transfer.
    bool abort = false;
    bool timedOut = false;
    bool headersPosted = false;
    bool discardBody = false;    ///< `discardNon2xx` applies: the status was not 2xx.
    bool finished = false;
    int curlCode = 0;            ///< The `CURLcode` the transfer finished with.
    /// "network error: " and curl's message, once finished with an error.
    std::string errReason;

    // Upload side.
    /// One write on the upload side: its bytes, how many curl has taken, and
    /// whether its result has been posted.
    struct UpChunk {
        std::string bytes;
        size_t off = 0;
        uint64_t token = 0;
        bool acked = false;
    };
    std::deque<UpChunk> up;
    size_t upBytes = 0;          ///< Bytes in `up` that curl has not taken.
    uint64_t upChannel = 0;      ///< The upload channel's id, or 0 before one is made.
    bool upCloseRequested = false;
    uint64_t upCloseToken = 0;
    bool upClosePosted = false;
    bool upEofSent = false;      ///< The read callback has returned 0, ending the body.
    bool upShut = false;         ///< The upload channel was shut down.

    // Download side.
    std::deque<std::string> down;
    size_t downBytes = 0;        ///< Bytes in `down`.
    /// A read request not yet answered.
    struct PendingRead {
        uint64_t token;
        size_t max;
    };
    std::deque<PendingRead> reads;
    uint64_t downChannel = 0;    ///< The download channel's id, or 0 before one is made.
    bool downShut = false;       ///< The download channel was closed or shut down.
};

namespace {

/// Returns an empty, successful result of kind `op` for request `token` on
/// channel `channel`.
ChannelResult makeResult(uint64_t channel, uint64_t token, ChannelResult::Op op) {
    ChannelResult r;
    r.channelId = channel;
    r.token = token;
    r.op = op;
    return r;
}

/// Returns the reason an upload write or close fails with: an abort, the curl
/// error, or the response having ended before the body was sent. Requires `t.m`.
std::string uploadFailure(const HttpTransfer& t) {
    if (t.abort || t.upShut) return "the HTTP request was aborted";
    if (!t.errReason.empty()) return t.errReason;
    return "the HTTP response ended before the request body was sent";
}

/// Answers what the state of `t` allows, under `t.m`, which the caller must
/// hold. Pending reads are answered, in order, with buffered bytes, the end of
/// the input or an error, until one has to wait for data. Upload writes are
/// acknowledged while fewer than `kCap` bytes are queued ahead of them, and all
/// unacknowledged ones fail once the transfer is finished, aborted or shut, which
/// also empties the upload queue. A requested upload close is answered once the
/// end of the body has been sent or the transfer is dead. Under `upDiscard`
/// (HEAD) a live transfer acknowledges and drops every write at once, and
/// answers a close with success at once.
///
/// Results are posted while `t.m` is held, so that a later call cannot post a
/// result for a later request first.
void serviceLocked(HttpTransfer& t) {
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
        if (t.upDiscard) {
            if (!it->acked) {
                ChannelResult r = makeResult(t.upChannel, it->token, ChannelResult::Op::Write);
                r.written = it->bytes.size();
                postChannelResult(std::move(r));
            }
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
    if (t.upDiscard && t.upCloseRequested && !upDead) t.upEofSent = true;   // nothing to send
    if (t.upCloseRequested && !t.upClosePosted && (t.upEofSent || upDead)) {
        ChannelResult r = makeResult(t.upChannel, t.upCloseToken, ChannelResult::Op::Close);
        if (!t.upEofSent) {
            r.err = ECANCELED;
            r.reason = uploadFailure(t);
        }
        t.upClosePosted = true;
        postChannelResult(std::move(r));
    }
}

/// Marks `t` aborted, wakes its callbacks and its multi loop, and answers what
/// the abort allows. The caller must hold `t.m`.
void abortLocked(HttpTransfer& t) {
    t.abort = true;
    t.cv.notify_all();
    if (t.multi) curl_multi_wakeup(t.multi);
    serviceLocked(t);
}

// ---------------------------------------------------------------------------
// Curl callbacks (transfer thread)
// ---------------------------------------------------------------------------

/// The response head being parsed by the header callback, on the transfer
/// thread. It belongs to `runTransfer`'s frame, and `t` and `easy` point at
/// that call's transfer and easy handle.
struct HeaderState {
    HttpTransfer* t = nullptr;
    CURL* easy = nullptr;
    long status = 0;
    std::string statusText;
    bool sawLocation = false;   ///< The block has a Location field with a non-empty value.
    HttpHeaderList headers;
};

/// Returns `s` with ASCII letters lower-cased.
std::string lowerAscii(std::string s) {
    for (auto& c : s) c = static_cast<char>(std::tolower(static_cast<unsigned char>(c)));
    return s;
}

/// Returns `s` without leading and trailing spaces, tabs, CRs and LFs.
std::string trimHttp(const std::string& s) {
    size_t b = 0, e = s.size();
    while (b < e && (s[b] == ' ' || s[b] == '\t' || s[b] == '\r' || s[b] == '\n')) ++b;
    while (e > b && (s[e - 1] == ' ' || s[e - 1] == '\t' || s[e - 1] == '\r' || s[e - 1] == '\n')) --e;
    return s.substr(b, e - b);
}

/// Returns whether a response with `status`, and with a non-empty Location
/// field if `sawLocation`, is a redirect that curl follows rather than a final
/// response. Curl ignores an empty Location, so it is not counted.
bool isFollowedRedirect(long status, bool sawLocation) {
    return sawLocation && status >= 300 && status < 400 && status != 304;
}

/// Records that the final response's headers have arrived and, unless the
/// transfer is already resolved, posts its status event with the parsed head.
/// With `discardNon2xx` and a status that is not 2xx it then aborts the
/// transfer, whose reads see the end of the input. Takes `t.m`.
void postHeaders(HeaderState& hs) {
    HttpTransfer& t = *hs.t;
    const char* eff = nullptr;
    curl_easy_getinfo(hs.easy, CURLINFO_EFFECTIVE_URL, &eff);
    std::lock_guard<std::mutex> lk(t.m);
    if (t.headersPosted) return;
    t.headersPosted = true;
    bool ok2xx = hs.status >= 200 && hs.status < 300;
    t.discardBody = t.spec.discardNon2xx && !ok2xx;
    if (t.resolved) return;   // cancelled: the abort `cancel` made ends the transfer
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
        abortLocked(t);
    } else {
        serviceLocked(t);
    }
}

/// Curl's header callback: parses one header line into `userdata`, a
/// `HeaderState`, and posts the event at the end of the final header block.
/// Returns 0, which fails the transfer, once it is aborted; lines after the
/// event (trailers) are ignored.
size_t headerCb(char* buffer, size_t size, size_t nitems, void* userdata) {
    size_t n = size * nitems;
    auto* hs = static_cast<HeaderState*>(userdata);
    {
        std::lock_guard<std::mutex> lk(hs->t->m);
        if (hs->t->abort) return 0;
        if (hs->t->headersPosted) return n;
    }
    std::string line(buffer, n);
    while (!line.empty() && (line.back() == '\r' || line.back() == '\n')) line.pop_back();

    if (line.rfind("HTTP/", 0) == 0) {
        // A new response (a redirect hop or an interim one) starts over.
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
    if (name == "location" && !value.empty()) hs->sawLocation = true;
    hs->headers.emplace_back(std::move(name), std::move(value));
    return n;
}

/// Curl's write callback: queues the body bytes for the download side of
/// `userdata`, a `HttpTransfer`, waiting while that would take it past `kCap`
/// (a piece is always taken into an empty buffer). Bytes before the event,
/// and all bytes under `discardBody`, are dropped. Returns 0, which fails the
/// transfer, once it is aborted or the download side is shut.
size_t writeCb(char* ptr, size_t size, size_t nmemb, void* userdata) {
    size_t n = size * nmemb;
    auto* t = static_cast<HttpTransfer*>(userdata);
    std::unique_lock<std::mutex> lk(t->m);
    if (t->abort || t->downShut) return 0;
    if (!t->headersPosted) return n;          // an interim or redirect body
    if (t->discardBody) return n;
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

/// Curl's read callback: copies up to `size * nitems` queued upload bytes of
/// `userdata`, a `HttpTransfer`, into `buffer`, waiting while there are none.
/// Returns 0, ending the body, once the upload close is requested and the
/// queue is empty, and aborts the transfer once it is aborted, the upload side
/// is shut, or the header deadline passes while it waits. A write whose bytes
/// are all taken has its result posted if it was not acknowledged already.
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
            return 0;
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

/// Returns whether `c` is reported as BadUrl: a malformed URL, or a scheme other
/// than http/https, including one reached by a redirect.
bool isBadUrlCode(CURLcode c) {
    return c == CURLE_URL_MALFORMAT || c == CURLE_UNSUPPORTED_PROTOCOL;
}

// ---------------------------------------------------------------------------
// The transfer thread
// ---------------------------------------------------------------------------

/// Builds the request's header list: Content-Type, then `spec.headers`, then,
/// for a stream body that is sent (not under HEAD), chunked transfer encoding and
/// an empty `Expect:`. A field
/// that could inject a header line is left out. Returns null for an empty list;
/// otherwise the caller frees it with `curl_slist_free_all`.
curl_slist* buildHeaderList(const HttpRequestSpec& spec) {
    curl_slist* list = nullptr;
    auto add = [&list](const std::string& name, const std::string& value) {
        if (name.find_first_of("\r\n:") != std::string::npos || name.empty()) return;
        if (value.find_first_of("\r\n") != std::string::npos) return;
        // "Name;" sends an empty value ("Name:" would remove the header).
        std::string line = value.empty() ? name + ";" : name + ": " + value;
        list = curl_slist_append(list, line.c_str());
    };
    if (spec.bodyKind != 0 && !spec.contentType.empty()) add("Content-Type", spec.contentType);
    for (const auto& h : spec.headers) add(h.first, h.second);
    if (spec.bodyKind == 2 && spec.method != "HEAD") {
        list = curl_slist_append(list, "Transfer-Encoding: chunked");
        list = curl_slist_append(list, "Expect:");
    }
    return list;
}

/// Sets every option of `easy` for `t`'s request. `t`, `hs` and `errbuf` are kept
/// by curl for the handle's life; `errbuf` must hold `CURL_ERROR_SIZE` bytes.
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
#if LIBCURL_VERSION_NUM >= 0x073600
    // A proxy's "200 Connection established" is not the response.
    curl_easy_setopt(easy, CURLOPT_SUPPRESS_CONNECT_HEADERS, 1L);
#endif

    // libcurl does not read CURL_CA_BUNDLE itself.
    curl_easy_setopt(easy, CURLOPT_SSL_VERIFYPEER, 1L);
    curl_easy_setopt(easy, CURLOPT_SSL_VERIFYHOST, 2L);
    if (const char* ca = std::getenv("CURL_CA_BUNDLE")) {
        if (*ca) curl_easy_setopt(easy, CURLOPT_CAINFO, ca);
    }

    // POST and HEAD use curl's own verbs, so curl's redirect handling for those
    // verbs applies. Any other method is sent with CURLOPT_CUSTOMREQUEST, except
    // a GET without a body. HEAD sends no body even if one is given.
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

/// Records that `t` has finished with `code` (with `errbuf` as the message if
/// not empty), posts its event if it is not yet resolved, and answers what the
/// channels wait for. A clean finish with a `status` but no posted head posts a
/// status event with `effUrl` as its URL and a body that has already ended; its
/// status text and headers are those of `hs`, the last header block parsed, when
/// that block has the same status, and empty otherwise. Takes `t.m`.
void finishTransfer(HttpTransfer& t, CURLcode code, const char* errbuf, long status,
                    const char* effUrl, HeaderState* hs = nullptr) {
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
            t.headersPosted = true;
            bool ok2xx = status >= 200 && status < 300;
            t.discardBody = t.spec.discardNon2xx && !ok2xx;
            ev.kind = ok2xx ? HttpOutcome::GoodStatus : HttpOutcome::BadStatus;
            ev.status = status;
            if (hs && hs->status == status) {
                // A block the header callback did not take as final (curl's rule
                // for following differed): it is the response after all.
                ev.statusText = hs->statusText;
                ev.headers = std::move(hs->headers);
                hs->headers.clear();
            }
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

/// Runs `tp`'s transfer to its end on the calling thread, then finishes it with
/// curl's result, the response code and the effective URL. Hitting the header
/// deadline or an abort stops the loop with a timeout or abort code.
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
        if (running == 0) break;   // no DONE message: finished with CURLE_OK
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
        t.multi = nullptr;   // before the handle is cleaned up below
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

    finishTransfer(t, result, errbuf, status, effUrl.empty() ? nullptr : effUrl.c_str(), &hs);
}

} // namespace

// ---------------------------------------------------------------------------
// HttpStreamService
// ---------------------------------------------------------------------------

/// The service's state.
struct HttpStreamService::Impl {
    std::mutex m;   ///< Guards `live` and `events`.
    /// Started transfers whose thread has not ended, by token. Not owning.
    std::unordered_map<uint64_t, std::weak_ptr<HttpTransfer>> live;
    std::deque<HttpEvent> events;
    std::atomic<size_t> count{0};   ///< The size of `events`, readable without `m`.
    /// The scheduler `post` wakes, bound by the constructor. Leaky, like the service.
    Scheduler* sched = nullptr;
};

HttpStreamService::HttpStreamService() : impl_(new Impl()) {
    impl_->sched = &Scheduler::instance();
    curl_global_init(CURL_GLOBAL_DEFAULT);
}

HttpStreamService& HttpStreamService::instance() {
    static auto* s = new HttpStreamService();   // never destroyed
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
    if (!t) return false;
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
    t_->cv.notify_all();   // the read may have made room for the write callback
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
    t_->cv.notify_all();
}

void HttpTransferChannel::close(uint64_t token) {
    closeRequested_ = true;
    std::lock_guard<std::mutex> lk(t_->m);
    if (dir_ == Dir::Upload) {
        if (!t_->upCloseRequested) {
            t_->upCloseRequested = true;
            t_->upCloseToken = token;
            serviceLocked(*t_);
            t_->cv.notify_all();
            return;
        }
        ChannelResult r = makeResult(id(), token, ChannelResult::Op::Close);
        r.err = ECANCELED;
        postChannelResult(std::move(r));
        return;
    }
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
        abortLocked(*t_);
    } else {
        serviceLocked(*t_);
    }
}

} // namespace Eco::System
