#ifndef ECO_PLATFORM_HTTP_SERVICE_HPP
#define ECO_PLATFORM_HTTP_SERVICE_HPP

#include <condition_variable>
#include <cstdint>
#include <mutex>
#include <queue>
#include <string>
#include <thread>
#include <utility>
#include <vector>

namespace Elm::Platform {

// Dumb HTTP worker: holds only POD state (request/result structs, std queues).
// Never touches HPointer, the allocator, or any GC-managed data — mirrors
// TimerService. The main scheduler thread is the sole owner of all GC
// interactions: it reads completed results via tryPopResult and builds the Elm
// Response/Task values there (see the HTTP async-source drain registered in
// elm-kernel-cpp/src/http/HttpExports.cpp).
class HttpService {
public:
    static HttpService& instance();

    // POD request handed to the worker. `token` is the opaque id minted by
    // Scheduler::registerPendingResume on the main thread and echoed back in
    // the matching Result so the main thread can resume the right binding.
    struct Request {
        std::uint64_t token = 0;
        std::string   method;
        std::string   url;
        std::vector<std::pair<std::string, std::string>> headers;
        std::string   body;
        std::string   contentType;   // empty => no Content-Type header
        long          timeoutMs = 0; // 0 => no timeout
        // TLS: when caInfo is non-empty libcurl verifies the peer against that
        // CA bundle file; otherwise it uses the system default. verifyPeer=false
        // disables verification (test-only; avoid in production).
        std::string   caInfo;
        bool          verifyPeer = true;
    };

    enum class ErrorKind : int {
        Ok = 0,
        Timeout = 1,
        NetworkError = 2,
        BadUrl = 3,
    };

    struct Result {
        std::uint64_t token = 0;
        ErrorKind     error = ErrorKind::Ok;
        long          status = 0;
        std::string   statusText;
        std::string   finalUrl;
        std::vector<std::pair<std::string, std::string>> headers;
        std::string   body;
    };

    // Main-thread producer: enqueue a request for the worker pool.
    void submit(Request req);

    // Main-thread-only consumer API. tryPopResult returns true and moves the
    // next completed result into `out`, or false when the ready queue is
    // empty. hasReadyResults is a non-blocking predicate for the event loop's
    // wait condition.
    bool tryPopResult(Result& out);
    bool hasReadyResults() const;

private:
    HttpService();
    ~HttpService() = default;

    void workerLoop();
    static Result perform(const Request& req);

    std::mutex                 requestsMutex_;
    std::condition_variable    requestsCV_;
    std::queue<Request>        requests_;

    mutable std::mutex         resultsMutex_;
    std::queue<Result>         results_;
};

} // namespace Elm::Platform

#endif // ECO_PLATFORM_HTTP_SERVICE_HPP
