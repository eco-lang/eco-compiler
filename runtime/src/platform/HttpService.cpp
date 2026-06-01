#include "HttpService.hpp"
#include "Scheduler.hpp"

#include <curl/curl.h>
#include <chrono>
#include <cstdio>
#include <cstdlib>

#ifdef ECO_KERNEL_DEBUG
#define ECO_KLOG(tag, fmt, ...) \
    std::fprintf(stderr, "[eco-kernel:" tag "] " fmt "\n", ##__VA_ARGS__)
#else
#define ECO_KLOG(tag, fmt, ...) ((void)0)
#endif

namespace Elm::Platform {

// Leaky heap singleton, mirroring TimerService: `new`'d on first access and
// never destroyed; the detached worker thread runs until process exit.
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

size_t writeCb(void* contents, size_t size, size_t nmemb, void* userp) {
    size_t n = size * nmemb;
    static_cast<std::string*>(userp)->append(static_cast<char*>(contents), n);
    return n;
}

struct HeaderAccum {
    std::vector<std::pair<std::string, std::string>> headers;
};

// Context handed to the libcurl XFERINFO callback. Lives on the worker
// thread's stack for the duration of curl_easy_perform. Tracks the last-posted
// byte counts so unchanged ticks are not re-posted (curl fires the callback on
// a timer, often with identical values between actual transfers).
struct ProgressCtx {
    Elm::Platform::HttpService* service = nullptr;
    std::uint64_t token = 0;
    curl_off_t lastDl = -1;
    curl_off_t lastUl = -1;
    // pushProgress is private; ProgressCtx is befriended via a thin shim.
    void post(bool isUpload, curl_off_t now, curl_off_t total);
};

int xferInfoCb(void* clientp, curl_off_t dltotal, curl_off_t dlnow,
               curl_off_t ultotal, curl_off_t ulnow) {
    auto* ctx = static_cast<ProgressCtx*>(clientp);
    if (!ctx || !ctx->service) return 0;
    // Upload progress (POST/PUT bodies): emit a Sending tick when ulnow moves.
    if ((ultotal > 0 || ulnow > 0) && ulnow != ctx->lastUl) {
        ctx->lastUl = ulnow;
        ctx->post(/*isUpload=*/true, ulnow, ultotal);
    }
    // Download progress: emit a Receiving tick when dlnow moves. total==0 for
    // chunked / unknown-length responses (drives the Receiving.size=Nothing
    // branch on the main thread).
    if ((dltotal > 0 || dlnow > 0) && dlnow != ctx->lastDl) {
        ctx->lastDl = dlnow;
        ctx->post(/*isUpload=*/false, dlnow, dltotal);
    }
    return 0;  // 0 = continue (drop-delivery cancel; no curl-level abort)
}

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

    // Progress reporting (Http.track): the XFERINFO callback posts PODs to the
    // progress queue on the worker thread; the main thread turns them into Elm
    // Progress values. Always enabled — the main thread only routes ticks for
    // tracked tokens, so untracked requests just discard them cheaply.
    curl_easy_setopt(curl, CURLOPT_NOPROGRESS, 0L);
    curl_easy_setopt(curl, CURLOPT_XFERINFOFUNCTION, xferInfoCb);
    curl_easy_setopt(curl, CURLOPT_XFERINFODATA, &progressCtx);
    if (req.timeoutMs > 0) {
        curl_easy_setopt(curl, CURLOPT_TIMEOUT_MS, req.timeoutMs);
    }

    curl_easy_setopt(curl, CURLOPT_SSL_VERIFYPEER, req.verifyPeer ? 1L : 0L);
    curl_easy_setopt(curl, CURLOPT_SSL_VERIFYHOST, req.verifyPeer ? 2L : 0L);
    // CA bundle: explicit request override, else honor the conventional
    // CURL_CA_BUNDLE env var. (libcurl, unlike the curl CLI, does not read that
    // env itself, so we apply it here.)
    std::string caInfo = req.caInfo;
    if (caInfo.empty()) {
        if (const char* env = getenv("CURL_CA_BUNDLE")) caInfo = env;
    }
    if (!caInfo.empty()) {
        curl_easy_setopt(curl, CURLOPT_CAINFO, caInfo.c_str());
    }

    // Method + body. We always set CUSTOMREQUEST for the verb and supply body
    // via COPYPOSTFIELDS so libcurl owns a copy (the Request is freed after
    // submit returns on the main thread, but the worker keeps `req` alive for
    // the duration of perform()).
    if (!req.method.empty() && req.method != "GET") {
        curl_easy_setopt(curl, CURLOPT_CUSTOMREQUEST, req.method.c_str());
    }
    if (!req.body.empty()) {
        curl_easy_setopt(curl, CURLOPT_POSTFIELDSIZE, static_cast<long>(req.body.size()));
        curl_easy_setopt(curl, CURLOPT_COPYPOSTFIELDS, req.body.data());
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

    auto tookMs = std::chrono::duration_cast<std::chrono::milliseconds>(
        std::chrono::steady_clock::now() - t0).count();
    const char* curlErrMsg = curl_easy_strerror(res);
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
