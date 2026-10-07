//===- HttpTransfer.hpp - HttpStreamService and HttpTransferChannel -------===//
//
// plans/eco-system-library.md §3.4 (HttpStreamService), §3.5 (byte channels)
// and Phase 8 step 8.2. POD only (G1): nothing here touches the Eco heap.
//
// One streaming transfer = one HttpTransfer (shared state, guarded by its
// mutex) + one detached thread running its own curl easy handle inside a
// private curl multi handle (so the thread can be woken at once by an abort,
// and the header deadline is exact). Streaming transfers never go through
// the shared elm/http HttpService worker, which runs requests one at a time.
//
//   * Request body (bodyKind 2): pulled by CURLOPT_READFUNCTION from the
//     upload side, which the main thread fills through an
//     HttpTransferChannel (Upload) — a ChannelSink in the stream table that
//     the eco Readable is piped into.
//   * Response body: pushed by CURLOPT_WRITEFUNCTION into the download side,
//     read by an HttpTransferChannel (Download) — a ChannelSource handed to
//     Elm as the body stream.
//   * Both sides are bounded at 4 chunks of 64 KiB; the curl callbacks block
//     on a full download buffer or an empty upload buffer, and wake on abort.
//   * When the final response's headers end, the thread posts one
//     HttpEvent (Headers); if the transfer ends before that, one HttpEvent
//     (BadUrl / Timeout / NetworkError). Exactly one event per transfer
//     resolves the Elm task (it carries the task's pendingAsync count),
//     unless the task was killed first (T7: cancel() then owns the count).
//
// Lock order: HttpTransfer::m → channel-results queue → Scheduler mutex.
// HttpTransfer::m is never taken while holding either of the others.
//
// Templates used: T7 (CancelFn side), T9 (channel results).
//
//===----------------------------------------------------------------------===//

#ifndef ECO_SYSTEM_HTTP_STREAM_HTTP_TRANSFER_HPP
#define ECO_SYSTEM_HTTP_STREAM_HTTP_TRANSFER_HPP

#include "eco-system/Core/ByteChannel.hpp"

#include <cstdint>
#include <memory>
#include <string>
#include <utility>
#include <vector>

namespace Eco::System {

using HttpHeaderList = std::vector<std::pair<std::string, std::string>>;

// The request, copied out of the heap by the `send` body (G3).
struct HttpRequestSpec {
    std::string method;
    std::string url;
    int64_t timeoutMs = 0;       // 0 = no timeout (only until the headers)
    HttpHeaderList headers;      // request headers, as given
    int bodyKind = 0;            // 0 empty, 1 bytes, 2 stream
    std::string contentType;
    std::string bytes;           // bodyKind 1
    bool discardNon2xx = false;  // expectStream: drop non-2xx bodies
};

// B.7 result kinds.
enum class HttpOutcome : uint8_t { BadUrl = 0, Timeout = 1, NetworkError = 2, BadStatus = 3, GoodStatus = 4 };

struct HttpTransfer;   // HttpTransfer.cpp

// The one event that resolves a transfer's Elm task (POD, G1).
struct HttpEvent {
    uint64_t token = 0;                      // the task's resume token
    HttpOutcome kind = HttpOutcome::NetworkError;
    std::string badUrl;                      // BadUrl: the URL
    long status = 0;
    std::string statusText;
    std::string url;                         // final URL after redirects
    HttpHeaderList headers;                  // lower-cased names, arrival order
    std::shared_ptr<HttpTransfer> transfer;  // Bad/GoodStatus: the body source
};

class HttpStreamService {
public:
    // Leaky singleton (§3.4). First call on the main thread.
    static HttpStreamService& instance();

    // A new transfer for resume token `token` (not started).
    std::shared_ptr<HttpTransfer> create(uint64_t token, HttpRequestSpec spec);
    // Starts its detached thread. False if no thread could be started; the
    // transfer has then posted its NetworkError event itself.
    bool start(const std::shared_ptr<HttpTransfer>& t);

    // T7 CancelFn: aborts the transfer of `token`. True only if its event had
    // not been posted yet (the kill handle then releases the count).
    static bool cancel(uint64_t token);
    // Aborts `t` (no result accounting). Any thread.
    static void abort(HttpTransfer& t);

    // Event queue (any thread posts; the main-thread drain pops).
    void post(HttpEvent ev);
    bool tryPop(HttpEvent& out);
    bool ready() const;

    // Transfers still running (tests).
    size_t liveTransfers();

    struct Impl;

private:
    HttpStreamService();
    Impl* impl_;
};

// A ByteChannel over one side of a transfer. Upload: requestWrite /
// close (end of body) / shutdown (abort the transfer). Download:
// requestRead / close (release) / shutdown (abort the transfer). The other
// side's operations complete with ENOTSUP. Created on the main thread.
class HttpTransferChannel final : public ByteChannel {
public:
    enum class Dir : uint8_t { Upload, Download };

    HttpTransferChannel(std::shared_ptr<HttpTransfer> t, Dir dir);
    ~HttpTransferChannel() override;

    void requestRead(uint64_t token, size_t maxBytes) override;
    void requestWrite(uint64_t token, std::string bytes) override;
    void close(uint64_t token) override;
    void shutdown() override;

private:
    std::shared_ptr<HttpTransfer> t_;
    Dir dir_;
    bool closeRequested_ = false;   // main thread only
};

} // namespace Eco::System

#endif // ECO_SYSTEM_HTTP_STREAM_HTTP_TRANSFER_HPP
