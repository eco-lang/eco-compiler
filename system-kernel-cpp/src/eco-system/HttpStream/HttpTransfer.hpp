//===- HttpTransfer.hpp - HttpStreamService and HttpTransferChannel -------===//
//
// A streaming HTTP request sends its body while it is still being produced and
// hands over the response body as it arrives, so it cannot be one blocking call.
// This component runs such requests on libcurl, outside the Eco heap: nothing
// here reads or writes GC heap values, and every type here is plain C++ data.
//
// A *transfer* is one request and its response. Each has its own detached
// thread, which drives one curl easy handle inside a private curl multi handle,
// so that an abort can wake the thread with `curl_multi_wakeup`. This component
// does not use the runtime's `HttpService`.
//
// A transfer has two sides, each exposed as a `ByteChannel`:
//
//   * The *upload side* carries a stream request body (`bodyKind` 2). Writes on
//     an `HttpTransferChannel` of direction `Upload` queue bytes, and curl's read
//     callback takes them off the queue and sends them, chunked.
//   * The *download side* carries the response body. Curl's write callback
//     queues the bytes it receives, and reads on an `HttpTransferChannel` of
//     direction `Download` take them off.
//
// Each side is bounded at 4 chunks of 64 KiB. Curl's callbacks wait while the
// download side is full or the upload side is empty, and an abort wakes them.
//
// Each transfer posts at most one `HttpEvent`, the one that answers the request:
// a status event when the headers of the final response have arrived. If the
// transfer ends before that, it is a status event when curl finished cleanly
// with a status (with the last header block's head if its status is that one,
// and otherwise an empty head; its body has already ended), and otherwise a
// BadUrl, Timeout or NetworkError event. The transfer is *resolved* once that event is posted or
// `HttpStreamService::cancel` has claimed it; after that no event is posted.
// Events are taken off the service's queue with `HttpStreamService::tryPop`.
//
// The timeout of a request applies only until the final headers arrive (the
// *header deadline*); after that, the body may take as long as it takes.
//
// Locks: each transfer has its own mutex, and the service has one for its event
// queue and its map of live transfers. While holding a transfer's mutex this
// component takes the service's mutex (to post an event), calls
// `postChannelResult`, and wakes the scheduler. It never takes a transfer's mutex
// while holding the service's.
//
//===----------------------------------------------------------------------===//

#ifndef ECO_SYSTEM_HTTP_STREAM_HTTP_TRANSFER_HPP
#define ECO_SYSTEM_HTTP_STREAM_HTTP_TRANSFER_HPP

#include "eco-system/Core/ByteChannel.hpp"
#include "eco-system/Core/Core.hpp"

#include <cerrno>
#include <cstdint>
#include <memory>
#include <string>
#include <utility>
#include <vector>

namespace Eco::System {

/// A list of HTTP header fields as (name, value) pairs, in order.
///
/// This is another name for a vector of string pairs, not a new type: nothing
/// checks the names or values. Duplicate names are allowed.
using HttpHeaderList = std::vector<std::pair<std::string, std::string>>;

/// One HTTP request, as plain C++ data.
struct HttpRequestSpec {
    /// The method, an RFC 9110 token (`httpStreamSendBody` rejects any other
    /// before a transfer is made). Without a body, "POST" and "HEAD" are sent as
    /// libcurl's own verbs, "GET" as a GET, and any other as a custom request.
    /// With a body, "POST" is sent as a POST and any other method, including
    /// "GET", as a POST with that method as its custom request; "HEAD" sends no
    /// body.
    std::string method;
    std::string url;
    /// The timeout in milliseconds, or 0 (or less) for none. It is the connect
    /// timeout and also a deadline, counted from when the transfer is created,
    /// by which the final response's headers must have arrived. It does not
    /// limit the body.
    int64_t timeoutMs = 0;
    /// Header fields to send, in order. A field whose name is empty or contains
    /// CR, LF or ':', or whose value contains CR or LF, is not sent.
    HttpHeaderList headers;
    int bodyKind = 0;            ///< 0: no body. 1: `bytes`. 2: a stream, fed through the upload side.
    /// Sent as the Content-Type header when `bodyKind` is not 0 and this is not
    /// empty.
    std::string contentType;
    std::string bytes;           ///< The body when `bodyKind` is 1; ignored otherwise.
    /// Whether the body of a response whose status is not 2xx is dropped: the
    /// transfer is stopped once its headers are posted, and reads of the
    /// download side then see the end of the input.
    bool discardNon2xx = false;
};

/// How a request ended, as far as the task that made it is concerned.
///
/// The values are explicit because they are handed on as integers, so they
/// must not be renumbered.
enum class HttpOutcome : uint8_t { BadUrl = 0, Timeout = 1, NetworkError = 2, BadStatus = 3, GoodStatus = 4 };

/// The shared state of one transfer. Opaque outside `HttpTransfer.cpp`; it is
/// held through `std::shared_ptr` and passed back to this component.
struct HttpTransfer;

/// The event that answers one request: its outcome and, when a response
/// arrived, the response's head and the transfer that carries its body.
///
/// `kind` is BadStatus when the status is outside 200-299 and GoodStatus
/// inside it. For BadUrl, Timeout and NetworkError only `token`, `kind` and,
/// for BadUrl, `badUrl` are set.
struct HttpEvent {
    uint64_t token = 0;                      ///< The token the transfer was created with.
    HttpOutcome kind = HttpOutcome::NetworkError;
    std::string badUrl;                      ///< BadUrl: the request's URL.
    long status = 0;
    /// The reason phrase of the status line, or empty, as for a response
    /// whose header block was not recognised before the transfer ended.
    std::string statusText;
    std::string url;                         ///< The URL after redirects.
    /// The final response's header fields in arrival order, names lower-cased.
    /// Empty in the same case as `statusText`.
    HttpHeaderList headers;
    /// Bad/GoodStatus: the transfer, to build the download side's channel on.
    /// Null for the other outcomes.
    std::shared_ptr<HttpTransfer> transfer;
};

/// The process's runner of streaming HTTP transfers, and the queue of the
/// events that answer them.
///
/// There is one, made on first use and never destroyed. Events are posted
/// from transfer threads (and from `start` when it fails) and popped with
/// `tryPop`; posting wakes the scheduler bound when the service was made.
class HttpStreamService {
public:
    /// Returns the service, making it on first call. The first call must be on
    /// the eco thread: it calls `Scheduler::instance()`, which has that
    /// requirement, and `curl_global_init`.
    static HttpStreamService& instance();

    /// Returns a new transfer for `spec`, not yet started, whose event will
    /// carry `token`. The header deadline starts counting now.
    std::shared_ptr<HttpTransfer> create(uint64_t token, HttpRequestSpec spec);
    /// Starts `t` on a new detached thread, which keeps `t` alive until the
    /// transfer ends. Returns false if the thread could not be started; `t` is
    /// then finished, and its NetworkError event has been posted unless it was
    /// already resolved. Call it at most once for a transfer.
    bool start(const std::shared_ptr<HttpTransfer>& t);

    /// Aborts the running transfer created with `token`, and returns whether
    /// this call resolved it, meaning no event will be posted for it.
    ///
    /// It returns false, and changes nothing, when no started transfer with
    /// that token has a thread that has not yet ended. A transfer whose event
    /// was already posted is still aborted, and the call returns false.
    static bool cancel(uint64_t token);
    /// Aborts `t` unless it has finished, without resolving it. Any thread.
    static void abort(HttpTransfer& t);

    /// Appends `ev` to the event queue and wakes the scheduler. Any thread.
    void post(HttpEvent ev);
    /// Moves the oldest queued event into `out` and returns true, or returns
    /// false and leaves `out` alone when the queue is empty.
    bool tryPop(HttpEvent& out);
    /// Returns whether the event queue holds any event. Reads an atomic count
    /// and takes no lock.
    bool ready() const;

    /// Returns how many started transfers have a thread that has not yet
    /// ended.
    size_t liveTransfers();

    /// The service's state, defined in `HttpTransfer.cpp`.
    struct Impl;

private:
    /// Makes the service; see `instance`.
    HttpStreamService();
    Impl* impl_;   ///< Owned and never freed, like the service itself.
};

/// A `ByteChannel` over one side of a transfer, chosen by `Dir`.
///
/// An `Upload` channel accepts writes. A write is acknowledged once fewer than
/// 256 KiB of earlier writes are still waiting to be sent, or once curl has
/// taken all of it, and fails with `ECANCELED` if the transfer ends or is
/// aborted first; an empty write is answered at once. Its `close` ends the
/// request body, and is answered once curl has taken the end of the body, or
/// with `ECANCELED` if the transfer ends first; writes and closes after a
/// `close` fail with `ECANCELED`. For a HEAD request, which sends no body, a
/// write is acknowledged and dropped at once and a `close` succeeds at once
/// while the transfer is alive. A `Download` channel answers reads from the
/// response body, possibly with fewer bytes than asked for; at the end of the
/// body a read sees the end of the input, or `EIO` with the curl error as its
/// reason. Its `close` answers pending reads with
/// `ECANCELED` and makes curl's next delivery of body data fail, which ends the
/// transfer. On either channel, `shutdown` aborts the transfer if it has not
/// finished. A read on an `Upload` channel and a write on a `Download` channel
/// are answered with `ENOTSUP`.
///
/// The channel shares ownership of the transfer. Destroying it without a call
/// to `close` or `shutdown` calls `shutdown`. Requests must be made on the eco
/// thread; results may be posted from the transfer thread.
class HttpTransferChannel final : public ByteChannel {
public:
    /// Which side of the transfer a channel is over.
    enum class Dir : uint8_t { Upload, Download };

    /// Makes the channel over side `dir` of `t`, and records the channel's id
    /// in `t` so that results for that side carry it. At most one channel per
    /// side: a second replaces the first's id.
    HttpTransferChannel(std::shared_ptr<HttpTransfer> t, Dir dir);
    ~HttpTransferChannel() override;

    void requestRead(uint64_t token, size_t maxBytes) override;
    void requestWrite(uint64_t token, std::string bytes) override;
    void close(uint64_t token) override;
    void shutdown() override;
    /// Returns `reason` if it is already marked, and otherwise a reason with
    /// origin "http" and code "NETWORK" whose message is `reason`, or, when
    /// `reason` is empty, "network error: " and the errno name of `err` (of
    /// `EIO` when `err` is 0).
    std::string encodeFailure(int err, const std::string& reason) const override {
        if (isMarkedReason(reason)) return reason;
        return failureReason("http", "NETWORK",
                             reason.empty() ? std::string("network error: ") + errnoName(err != 0 ? err : EIO)
                                            : reason);
    }
    /// Returns "http".
    const char* failureOrigin() const override { return "http"; }

private:
    std::shared_ptr<HttpTransfer> t_;
    Dir dir_;
    /// Whether `close` or `shutdown` has been called. Eco thread only.
    bool closeRequested_ = false;
};

} // namespace Eco::System

#endif // ECO_SYSTEM_HTTP_STREAM_HTTP_TRANSFER_HPP
