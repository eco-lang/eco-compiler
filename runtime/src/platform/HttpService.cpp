#include "HttpService.hpp"
#include "Scheduler.hpp"

#include <curl/curl.h>
#include <chrono>
#include <cstdio>
#include <cstdlib>

// Writes one line tagged `tag` to stderr, formatted as by `printf`, in builds that define `ECO_KERNEL_DEBUG`.
// Otherwise it expands to an expression that does nothing, and the arguments are not evaluated. `tag` must be a
// string literal, because it is pasted into the format.
#ifdef ECO_KERNEL_DEBUG
#define ECO_KLOG(tag, fmt, ...) \
    std::fprintf(stderr, "[eco-kernel:" tag "] " fmt "\n", ##__VA_ARGS__)
#else
#define ECO_KLOG(tag, fmt, ...) ((void)0)
#endif

namespace Elm::Platform {

// The service, once `instance` has created it. It is allocated with `new` and never deleted, because the
// detached worker thread uses it until the process exits. Nothing outside `instance` reads this variable;
// `instance` keeps its own copy.
static HttpService* s_instance = nullptr;

HttpService& HttpService::instance() {
    static HttpService* inst = []{
        s_instance = new HttpService();
        return s_instance;
    }();
    return *inst;
}

HttpService::HttpService() {
    std::thread([]{ instance().workerLoop(); }).detach();
}

void HttpService::submit(Request req) {
    {
        std::lock_guard<std::mutex> lk(requestsMutex_);
        requests_.push(std::move(req));
    }
    requestsCV_.notify_one();
}

bool HttpService::tryPopResult(Result& out) {
    std::lock_guard<std::mutex> lk(resultsMutex_);
    if (results_.empty()) return false;
    out = std::move(results_.front());
    results_.pop();
    return true;
}

bool HttpService::hasReadyResults() const {
    std::lock_guard<std::mutex> lk(resultsMutex_);
    return !results_.empty();
}

bool HttpService::tryPopResultEcoLane(Result& out) {
    std::lock_guard<std::mutex> lk(ecoResultsMutex_);
    if (ecoResults_.empty()) return false;
    out = std::move(ecoResults_.front());
    ecoResults_.pop();
    return true;
}

bool HttpService::hasReadyResultsEcoLane() const {
    std::lock_guard<std::mutex> lk(ecoResultsMutex_);
    return !ecoResults_.empty();
}

void HttpService::pushProgress(Progress p) {
    {
        std::lock_guard<std::mutex> lk(progressMutex_);
        progress_.push(p);
    }
    Scheduler::instance().notifyWorkAvailableFromAsync();
}

bool HttpService::tryPopProgress(Progress& out) {
    std::lock_guard<std::mutex> lk(progressMutex_);
    if (progress_.empty()) return false;
    out = progress_.front();
    progress_.pop();
    return true;
}

bool HttpService::hasProgress() const {
    std::lock_guard<std::mutex> lk(progressMutex_);
    return !progress_.empty();
}

namespace {

// Appends the `size * nmemb` bytes at `contents` to the `std::string` that `userp` points to, and returns that
// count. It is libcurl's write callback, receiving the response body.
size_t writeCb(void* contents, size_t size, size_t nmemb, void* userp) {
    size_t n = size * nmemb;
    static_cast<std::string*>(userp)->append(static_cast<char*>(contents), n);
    return n;
}

// The response headers collected by `headerCb` during one transfer.
struct HeaderAccum {
    std::vector<std::pair<std::string, std::string>> headers;
};

// What `xferInfoCb` needs to know about one transfer: where to post ticks, the request's abort control, and
// the byte counts last posted in each direction, so that a callback with unchanged counts posts nothing. It
// lives on the worker thread's stack for the duration of `perform`.
struct ProgressCtx {
    // The service ticks are posted to. Null means no ticks are posted.
    Elm::Platform::HttpService* service = nullptr;
    // The request's abort control, owned by the `Request` being performed. Null when the request has none.
    const Elm::Platform::HttpService::RequestControl* control = nullptr;
    std::uint64_t token = 0;
    curl_off_t lastDl = -1;
    curl_off_t lastUl = -1;
    // Posts a tick for this transfer's token, with negative counts clamped to zero. `service` must not be null.
    void post(bool isUpload, curl_off_t now, curl_off_t total);
};

// Receives a transfer's progress, as libcurl's XFERINFO callback. It returns non-zero, which makes libcurl
// stop the transfer with `CURLE_ABORTED_BY_CALLBACK`, when the request's control is in `AbortRequested`.
// Otherwise it posts a tick for each direction whose count has changed since its last tick, provided that the
// count or the expected total is non-zero, and returns zero. `clientp` points to a `ProgressCtx`.
int xferInfoCb(void* clientp, curl_off_t dltotal, curl_off_t dlnow,
               curl_off_t ultotal, curl_off_t ulnow) {
    auto* ctx = static_cast<ProgressCtx*>(clientp);
    if (!ctx) return 0;
    // libcurl calls this periodically, also while waiting for a response, so an abort is seen even when no
    // bytes are moving.
    if (ctx->control &&
        ctx->control->state.load() == HttpService::RequestControl::AbortRequested) {
        return 1;
    }
    if (!ctx->service) return 0;
    if ((ultotal > 0 || ulnow > 0) && ulnow != ctx->lastUl) {
        ctx->lastUl = ulnow;
        ctx->post(/*isUpload=*/true, ulnow, ultotal);
    }
    if ((dltotal > 0 || dlnow > 0) && dlnow != ctx->lastDl) {
        ctx->lastDl = dlnow;
        ctx->post(/*isUpload=*/false, dlnow, dltotal);
    }
    return 0;
}

// Adds one response header line to the `HeaderAccum` that `userdata` points to, and returns its length. It is
// libcurl's header callback. Status lines and the blank line ending a header block are skipped, and so is any
// line with no colon. The name is lower-cased and the value has leading blanks and the line ending removed.
// Nothing resets the list between responses, so with redirects it holds the headers of every response.
size_t headerCb(char* buffer, size_t size, size_t nitems, void* userdata) {
    size_t n = size * nitems;
    auto* acc = static_cast<HeaderAccum*>(userdata);
    std::string line(buffer, n);
    if (line.rfind("HTTP/", 0) == 0 || line == "\r\n" || line == "\n") {
        return n;
    }
    size_t colon = line.find(':');
    if (colon != std::string::npos) {
        std::string name = line.substr(0, colon);
        std::string value = line.substr(colon + 1);
        while (!value.empty() && (value.front() == ' ' || value.front() == '\t')) {
            value.erase(0, 1);
        }
        while (!value.empty() && (value.back() == '\r' || value.back() == '\n')) {
            value.pop_back();
        }
        for (auto& c : name) c = static_cast<char>(std::tolower(c));
        acc->headers.push_back({std::move(name), std::move(value)});
    }
    return n;
}

void ProgressCtx::post(bool isUpload, curl_off_t now, curl_off_t total) {
    Elm::Platform::HttpService::Progress p;
    p.token = token;
    p.isUpload = isUpload;
    p.now = static_cast<std::uint64_t>(now < 0 ? 0 : now);
    p.total = static_cast<std::uint64_t>(total < 0 ? 0 : total);
    service->pushProgress(p);
}

} // namespace

HttpService::Result HttpService::perform(const Request& req) {
    Result result;
    result.token = req.token;

    ECO_KLOG("http",
        "curl request method=%s url=%s headers=%zu body=%zuB lane=%s token=%lu",
        (req.method.empty() ? "GET" : req.method.c_str()),
        req.url.c_str(), req.headers.size(), req.body.size(),
        req.eco_lane ? "eco" : "elm",
        (unsigned long)req.token);

    ProgressCtx progressCtx;
    progressCtx.service = this;
    progressCtx.control = req.control.get();
    progressCtx.token = req.token;

    auto t0 = std::chrono::steady_clock::now();

    CURL* curl = curl_easy_init();
    if (!curl) {
        ECO_KLOG("http", "curl init-fail token=%lu",
                 (unsigned long)req.token);
        result.error = ErrorKind::NetworkError;
        return result;
    }

    std::string body;
    HeaderAccum headerAcc;

    curl_easy_setopt(curl, CURLOPT_URL, req.url.c_str());
    curl_easy_setopt(curl, CURLOPT_WRITEFUNCTION, writeCb);
    curl_easy_setopt(curl, CURLOPT_WRITEDATA, &body);
    curl_easy_setopt(curl, CURLOPT_HEADERFUNCTION, headerCb);
    curl_easy_setopt(curl, CURLOPT_HEADERDATA, &headerAcc);
    curl_easy_setopt(curl, CURLOPT_FOLLOWLOCATION, 1L);
    curl_easy_setopt(curl, CURLOPT_NOSIGNAL, 1L);
    // "" advertises every encoding this libcurl supports and has it decode the body before `writeCb` sees it.
    // Without it, a server that compresses the response, for example because the request carries its own
    // `Accept-Encoding` header, would hand back compressed bytes.
    curl_easy_setopt(curl, CURLOPT_ACCEPT_ENCODING, "");

    // Progress is on for every request, because the same callback is what notices an abort. A consumer that
    // does not want a request's ticks has to discard them.
    curl_easy_setopt(curl, CURLOPT_NOPROGRESS, 0L);
    curl_easy_setopt(curl, CURLOPT_XFERINFOFUNCTION, xferInfoCb);
    curl_easy_setopt(curl, CURLOPT_XFERINFODATA, &progressCtx);
    if (req.timeoutMs > 0) {
        curl_easy_setopt(curl, CURLOPT_TIMEOUT_MS, req.timeoutMs);
    }

    curl_easy_setopt(curl, CURLOPT_SSL_VERIFYPEER, req.verifyPeer ? 1L : 0L);
    curl_easy_setopt(curl, CURLOPT_SSL_VERIFYHOST, req.verifyPeer ? 2L : 0L);
    // libcurl does not read `CURL_CA_BUNDLE` itself (the curl command-line tool does), so it is applied here.
    std::string caInfo = req.caInfo;
    if (caInfo.empty()) {
        if (const char* env = getenv("CURL_CA_BUNDLE")) caInfo = env;
    }
    if (!caInfo.empty()) {
        curl_easy_setopt(curl, CURLOPT_CAINFO, caInfo.c_str());
    }

    // A body is given with `CURLOPT_COPYPOSTFIELDS`, which makes libcurl use `POST` unless a custom method is
    // set, and a custom method is set unless the method is empty or `GET`. So a `GET` or empty-method request
    // with a body goes out as a `POST`.
    if (!req.method.empty() && req.method != "GET") {
        curl_easy_setopt(curl, CURLOPT_CUSTOMREQUEST, req.method.c_str());
    }
    if (!req.body.empty()) {
        curl_easy_setopt(curl, CURLOPT_POSTFIELDSIZE, static_cast<long>(req.body.size()));
        curl_easy_setopt(curl, CURLOPT_COPYPOSTFIELDS, req.body.data());
    } else if (req.method == "POST" || req.method == "PUT" || req.method == "PATCH") {
        // With only `CURLOPT_CUSTOMREQUEST`, libcurl sends no body and no `Content-Length`. Setting a body of
        // size zero makes it send `Content-Length: 0`. The size must be set before the data, or libcurl takes
        // the length of the data string instead.
        curl_easy_setopt(curl, CURLOPT_POSTFIELDSIZE, 0L);
        curl_easy_setopt(curl, CURLOPT_COPYPOSTFIELDS, "");
    }

    struct curl_slist* headerList = nullptr;
    if (!req.contentType.empty()) {
        headerList = curl_slist_append(headerList,
            ("Content-Type: " + req.contentType).c_str());
    }
    for (const auto& h : req.headers) {
        headerList = curl_slist_append(headerList, (h.first + ": " + h.second).c_str());
    }
    if (headerList) {
        curl_easy_setopt(curl, CURLOPT_HTTPHEADER, headerList);
    }

    CURLcode res = curl_easy_perform(curl);

    long status = 0;
    curl_easy_getinfo(curl, CURLINFO_RESPONSE_CODE, &status);
    char* eff = nullptr;
    curl_easy_getinfo(curl, CURLINFO_EFFECTIVE_URL, &eff);

    [[maybe_unused]] auto tookMs = std::chrono::duration_cast<std::chrono::milliseconds>(
        std::chrono::steady_clock::now() - t0).count();
    [[maybe_unused]] const char* curlErrMsg = curl_easy_strerror(res);
    ECO_KLOG("http",
        "curl response status=%ld err=%d errMsg=%s body=%zuB took=%lldms "
        "finalUrl=%s token=%lu",
        status, (int)res, curlErrMsg, body.size(), (long long)tookMs,
        (eff ? eff : req.url.c_str()),
        (unsigned long)req.token);

    if (headerList) curl_slist_free_all(headerList);

    if (res == CURLE_OK) {
        result.error = ErrorKind::Ok;
        result.status = status;
        result.finalUrl = eff ? eff : req.url;
        result.headers = std::move(headerAcc.headers);
        result.body = std::move(body);
    } else if (res == CURLE_OPERATION_TIMEDOUT) {
        result.error = ErrorKind::Timeout;
    } else if (res == CURLE_URL_MALFORMAT) {
        result.error = ErrorKind::BadUrl;
    } else {
        result.error = ErrorKind::NetworkError;
    }

    curl_easy_cleanup(curl);
    return result;
}

void HttpService::workerLoop() {
    while (true) {
        Request req;
        {
            std::unique_lock<std::mutex> lk(requestsMutex_);
            requestsCV_.wait(lk, [this]{ return !requests_.empty(); });
            req = std::move(requests_.front());
            requests_.pop();
        }
        if (req.control) {
            // Aborted while queued: `RequestControl::abort` returned true, so the submitter expects nothing to
            // be posted for this request.
            std::uint8_t q = RequestControl::Queued;
            if (!req.control->state.compare_exchange_strong(q, RequestControl::Running)) {
                continue;
            }
        }

        bool ecoLane = req.eco_lane;
        Result result = perform(req);

        if (ecoLane) {
            std::lock_guard<std::mutex> lk(ecoResultsMutex_);
            ecoResults_.push(std::move(result));
        } else {
            std::lock_guard<std::mutex> lk(resultsMutex_);
            results_.push(std::move(result));
        }
        Scheduler::instance().notifyWorkAvailableFromAsync();
    }
}

} // namespace Elm::Platform
