#include "HttpService.hpp"
#include "Scheduler.hpp"

#include <curl/curl.h>
#include <cstdlib>

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

namespace {

size_t writeCb(void* contents, size_t size, size_t nmemb, void* userp) {
    size_t n = size * nmemb;
    static_cast<std::string*>(userp)->append(static_cast<char*>(contents), n);
    return n;
}

struct HeaderAccum {
    std::vector<std::pair<std::string, std::string>> headers;
};

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

} // namespace

HttpService::Result HttpService::perform(const Request& req) {
    Result result;
    result.token = req.token;

    CURL* curl = curl_easy_init();
    if (!curl) {
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

        Result result = perform(req);

        {
            std::lock_guard<std::mutex> lk(resultsMutex_);
            results_.push(std::move(result));
        }
        Scheduler::instance().notifyWorkAvailableFromAsync();
    }
}

} // namespace Elm::Platform
