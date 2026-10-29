// HTTP requests for the runtime, carried out on a thread of their own so that a transfer never blocks the eco
// thread, the thread that runs Elm code.
//
// A transfer is made with libcurl, whose `curl_easy_perform` blocks until the response has arrived or the
// transfer has failed. The service therefore owns one worker thread, which takes requests from a queue and
// performs them one at a time, in the order they were submitted. A slow request delays every request queued
// behind it.
//
// Only the eco thread may touch the GC heap, as `Scheduler` states, so everything that crosses to the worker and
// back is plain data: a `Request` going in, and a `Result` and any number of `Progress` ticks coming out. Each
// carries a token, an opaque `std::uint64_t` the submitter chooses, which is how the submitter matches what
// comes out to what went in. The service never interprets the token. Building Elm values from a result is the
// consumer's work, done on the eco thread.
//
// Results come out on two lanes, which are two separate result queues fed by the same worker. A request's
// `eco_lane` flag picks the lane, so two consumers can each drain their own results without taking each
// other's. Progress ticks for both lanes go to a single progress queue. Every queue has its own mutex. After
// pushing a result or a tick the worker wakes the event loop with `Scheduler::notifyWorkAvailableFromAsync`,
// which makes the loop recheck its ready async sources.
//
// A request may also carry a `RequestControl`, which lets the submitter abort it, whether it is still queued
// or already running.

#ifndef ECO_PLATFORM_HTTP_SERVICE_HPP
#define ECO_PLATFORM_HTTP_SERVICE_HPP

#include <atomic>
#include <condition_variable>
#include <cstdint>
#include <memory>
#include <mutex>
#include <queue>
#include <string>
#include <thread>
#include <utility>
#include <vector>

namespace Elm::Platform {

/// The process's HTTP worker: a request queue, the thread that performs requests from it, and the queues that
/// results and progress ticks come back on.
///
/// It is obtained only from `instance`, and is never destroyed: the worker thread is detached and runs until
/// the process exits. It never touches the GC heap or Elm values. Each queue is guarded by its own mutex,
/// so every public function may be called from any thread. `pushProgress` and the worker, after each result,
/// take the scheduler's lock briefly to wake the event loop.
class HttpService {
public:
    /// Returns the service, creating it and starting its worker thread on first use.
    static HttpService& instance();

    /// The abort state of one request, shared between the submitter and the worker.
    ///
    /// The state starts at `Queued`. The worker moves it to `Running` when it takes the request from the queue,
    /// and skips a request whose state is anything other than `Queued` at that moment. `abort` moves `Queued`
    /// to `Aborted` and `Running` to `AbortRequested`. While a transfer runs, the worker checks for
    /// `AbortRequested` whenever libcurl reports progress, and stops the transfer when it sees it. Nothing moves
    /// the state on when a request finishes, so a finished request keeps whatever state it had.
    struct RequestControl {
        enum : std::uint8_t { Queued, Running, AbortRequested, Aborted };
        std::atomic<std::uint8_t> state{Queued};

        /// Asks for the request to be aborted, and returns whether it was claimed while still queued.
        ///
        /// True means the worker will skip the request and post no result for it, so anything the submitter
        /// meant to do when the result arrived, such as releasing a liveness hold, it must now do itself. False
        /// means the request is running and has been told to stop, or has finished; a running request that
        /// stops posts a `Result` with `ErrorKind::NetworkError`. False is also returned when the request was
        /// already `Aborted`, in which case no result is coming.
        bool abort() noexcept {
            std::uint8_t q = Queued;
            if (state.compare_exchange_strong(q, Aborted)) return true;
            std::uint8_t r = Running;
            (void)state.compare_exchange_strong(r, AbortRequested);
            return false;
        }
    };

    /// One HTTP request, as plain data handed to the worker.
    ///
    /// The worker sends `method` to `url` with `headers`, following redirects, and asks for any content
    /// encoding libcurl supports, decoding the response body before it is returned. An empty `method` means
    /// `GET`, but a request whose method is empty or `GET` and whose `body` is not empty is sent by libcurl as
    /// a `POST`. A `POST`, `PUT` or `PATCH` with an empty body is sent with a `Content-Length` of zero.
    struct Request {
        std::uint64_t token = 0;     ///< Copied into the `Result` and every `Progress` tick for this request.
        std::string   method;
        std::string   url;
        std::vector<std::pair<std::string, std::string>> headers;
        std::string   body;
        std::string   contentType;   ///< Sent as a `Content-Type` header unless empty.
        long          timeoutMs = 0; ///< Limit on the whole transfer. Zero or less means no limit.
        /// A CA bundle file to verify the server against. When empty, the `CURL_CA_BUNDLE` environment variable
        /// names the file if it is set, and libcurl's default is used otherwise.
        std::string   caInfo;
        /// False turns off verification of both the server's certificate and its host name.
        bool          verifyPeer = true;
        /// Selects the lane: true puts the result on the eco lane (`tryPopResultEcoLane`), false on the default
        /// lane (`tryPopResult`).
        bool          eco_lane = false;
        /// Lets the submitter abort the request. Null means it cannot be aborted. A non-null control must be in
        /// state `Queued` when the request is submitted, or the worker skips the request.
        std::shared_ptr<RequestControl> control;
    };

    /// How a request ended, as far as the transfer goes.
    enum class ErrorKind : int {
        Ok = 0,           ///< A response arrived, whatever its HTTP status.
        Timeout = 1,      ///< libcurl reported a timeout, including the request's own `timeoutMs`.
        NetworkError = 2, ///< Any other failure, including an aborted transfer and a failure to start libcurl.
        BadUrl = 3,       ///< libcurl rejected the URL as malformed.
    };

    /// The outcome of one request, as plain data handed back by the worker.
    ///
    /// When `error` is not `ErrorKind::Ok`, only `token` and `error` are filled in.
    struct Result {
        std::uint64_t token = 0;
        ErrorKind     error = ErrorKind::Ok;
        long          status = 0;
        std::string   statusText;   ///< Never filled in by the worker; always empty.
        std::string   finalUrl;     ///< The URL of the last response, after any redirects.
        /// Response headers in the order received, names lower-cased, from every response on the way, so a
        /// redirected request includes the redirect's headers too.
        std::vector<std::pair<std::string, std::string>> headers;
        std::string   body;
    };

    /// One report of how far a request's upload or download has got.
    ///
    /// A tick is posted only when the byte count has changed since the last tick in the same direction. All of a
    /// request's ticks are queued before its `Result` is, but the two go to different queues.
    struct Progress {
        std::uint64_t token = 0;
        bool          isUpload = false; ///< True for the request body being sent, false for the response body.
        std::uint64_t now = 0;          ///< Bytes transferred so far.
        std::uint64_t total = 0;        ///< Bytes expected in all, or zero when the length is not known.
    };

    /// Queues `req` for the worker. The result arrives on the lane `req.eco_lane` selects.
    void submit(Request req);

    /// Moves the oldest result on the default lane into `out` and returns true, or returns false, leaving `out`
    /// unchanged, if there is none.
    bool tryPopResult(Result& out);
    /// Returns whether the default lane holds a result. It does not block beyond taking the queue's mutex.
    bool hasReadyResults() const;
    /// Does what `tryPopResult` does, for the eco lane.
    bool tryPopResultEcoLane(Result& out);
    /// Does what `hasReadyResults` does, for the eco lane.
    bool hasReadyResultsEcoLane() const;

    /// Moves the oldest progress tick, from either lane, into `out` and returns true, or returns false, leaving
    /// `out` unchanged, if there is none.
    bool tryPopProgress(Progress& out);
    /// Returns whether a progress tick is queued.
    bool hasProgress() const;

    /// Queues the progress tick `p` and wakes the event loop. The worker calls this while a transfer runs.
    void pushProgress(Progress p);

private:
    /// Starts the detached worker thread.
    HttpService();
    ~HttpService() = default;

    /// Runs on the worker thread for the life of the process: takes each request in turn, skips one that was
    /// aborted while queued, performs it, posts its result to its lane, and wakes the event loop.
    void workerLoop();
    /// Carries out `req` with libcurl, posting progress ticks as it goes, and returns its result. Blocks until
    /// the transfer ends.
    Result perform(const Request& req);

    std::mutex                 requestsMutex_;
    std::condition_variable    requestsCV_;
    /// Guarded by `requestsMutex_`.
    std::queue<Request>        requests_;

    // The three mutexes below are `mutable` because the const `has...` functions lock them.
    mutable std::mutex         resultsMutex_;
    /// Guarded by `resultsMutex_`.
    std::queue<Result>         results_;

    mutable std::mutex         ecoResultsMutex_;
    /// Guarded by `ecoResultsMutex_`.
    std::queue<Result>         ecoResults_;

    mutable std::mutex         progressMutex_;
    /// Guarded by `progressMutex_`.
    std::queue<Progress>       progress_;
};

} // namespace Elm::Platform

#endif // ECO_PLATFORM_HTTP_SERVICE_HPP
