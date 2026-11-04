//===- ByteChannel.hpp - Abstract byte channel + the channel-results queue ===//
//
// Streams of bytes in eco/system are served by blocking or event-driven work
// on threads other than the eco thread (the thread that runs the Elm
// scheduler), and the answers have to come back to that thread. This
// component is the interface those transports implement and the queue their
// answers travel back on.
//
// A *channel* (`ByteChannel`) is one bidirectional byte transport, such as a
// file descriptor or an HTTP transfer. The eco thread makes *requests* on it:
// read, write, close. Each request carries a *token*, the scheduler resume
// token of the Elm task waiting for it, and an implementation must answer it
// with exactly one `ChannelResult` quoting that token. Results never hold GC
// heap values, so any thread can build and post one.
//
// Results from every channel go into one process-wide queue. `channelDrain`,
// which runs on the eco thread as an async source, pops them, hands each to
// the callback set with `setChannelDispatch`, and then calls
// `Scheduler::drain()` once, so a callback that completes tokens need not
// drain the scheduler itself. Going through a callback keeps this component
// independent of whatever turns results into stream state.
//
// Keeping the program alive while a request is outstanding is the requester's
// business, not the channel's: whoever completes the token releases whatever
// hold the requester took.
//
//===----------------------------------------------------------------------===//

#ifndef ECO_SYSTEM_CORE_BYTE_CHANNEL_HPP
#define ECO_SYSTEM_CORE_BYTE_CHANNEL_HPP

#include <cstddef>
#include <cstdint>
#include <string>

namespace Eco::System {

/// The answer to one channel request, addressed by the channel's id and the
/// request's token.
///
/// It holds no GC heap values, so it can be built and posted on any thread. Which
/// members mean something depends on `op`; the others keep their defaults.
struct ChannelResult {
    /// Which kind of request this answers.
    enum class Op : uint8_t { Read, Write, Close };
    uint64_t channelId = 0;
    uint64_t token = 0;
    Op op = Op::Read;
    int err = 0;            ///< 0 on success, otherwise an errno value.
    bool eof = false;       ///< Read: the input has ended, and `bytes` is empty.
    std::string bytes;      ///< Read: the data read.
    size_t written = 0;     ///< Write: how many bytes were written.
    /// When `err` is nonzero, a description of the failure that the channel
    /// prefers to the errno text, or empty when it has none. See `encodeFailure`.
    std::string reason;
    /// Read, from a channel that labels its chunks: an integer label for the
    /// chunk, chosen by the channel. 0 for a channel that does not label them.
    int64_t tag = 0;
    /// Read: whether the channel reports `bytes` as UTF-8 text rather than
    /// binary data. False when the channel does not say.
    bool text = false;
};

/// A bidirectional byte transport whose requests are made on the eco thread
/// and answered asynchronously through the channel-results queue.
///
/// A channel has identity: it cannot be copied, and its id is quoted in every
/// result it posts. An implementation must post exactly one `ChannelResult`
/// for each request, with the request's token, from whichever thread it likes,
/// using `postChannelResult`. Reads must be answered in the order they were
/// requested, and so must writes. A request made after `shutdown` or `close`
/// still gets its one result, with an error the implementation chooses.
class ByteChannel {
public:
    virtual ~ByteChannel() = default;

    ByteChannel(const ByteChannel&) = delete;
    ByteChannel& operator=(const ByteChannel&) = delete;

    /// Returns the id this channel was given at construction, unique in the
    /// process.
    uint64_t id() const { return id_; }

    /// Asks for at most `maxBytes` bytes, answered by one Read result. Eco
    /// thread. `maxBytes` must be greater than 0.
    virtual void requestRead(uint64_t token, size_t maxBytes) = 0;
    /// Asks for all of `bytes` to be written, answered by one Write result.
    /// Eco thread.
    virtual void requestWrite(uint64_t token, std::string bytes) = 0;
    /// Asks for `bytes` to be written as a chunk labelled `tag`, with `text`
    /// saying whether `bytes` is UTF-8 text. Answered like `requestWrite`.
    ///
    /// The default treats a `tag` of 0 as an ordinary `requestWrite`, ignoring
    /// `text`, and answers any other `tag` with a Write result whose `err` is
    /// `ENOTSUP`.
    virtual void requestWriteTagged(uint64_t token, int64_t tag, bool text, std::string bytes);
    /// Asks for the channel to be closed once the writes already requested
    /// have completed, answered by one Close result carrying `token`, which may
    /// be 0. Eco thread. An implementation must release the underlying resource
    /// and answer every read still pending, with an error result.
    virtual void close(uint64_t token) = 0;
    /// Stops the channel at once: an implementation must answer every
    /// pending request with an error result and release the resource. Calling
    /// it again must do nothing more.
    virtual void shutdown() = 0;

    /// Returns the marked stream failure reason, as `failureReason` builds
    /// it, for a failed result's `err` and `reason`. Eco thread.
    ///
    /// The default returns `reason` unchanged if `isMarkedReason` accepts it.
    /// An empty `reason` gives `errnoFailureReason` for `err`, or for `EIO`
    /// when `err` is 0. Any other `reason` becomes the message, with the
    /// errno name of `err` (empty when `err` is 0) as the code. The origin is
    /// `failureOrigin()` in the last two cases.
    virtual std::string encodeFailure(int err, const std::string& reason) const;
    /// Returns the origin, in the sense of `failureReason`, under which a
    /// failure of this channel's resource is reported. The default is
    /// `"stream"`.
    virtual const char* failureOrigin() const { return "stream"; }

protected:
    /// Gives the channel the next process-wide id, and on first use registers
    /// `channelDrain` as an async source. Eco thread: the first call binds the
    /// results queue to `Scheduler::instance()`, the one process-wide scheduler.
    ByteChannel();

private:
    uint64_t id_;
};

// --- The channel-results queue ----------------------------------------------

/// Appends `r` to the channel-results queue and wakes the scheduler. Any thread.
void postChannelResult(ChannelResult r);

/// Moves the oldest queued result into `out` and returns true, or returns
/// false and leaves `out` alone when the queue is empty. Does not block.
bool tryPopChannelResult(ChannelResult& out);
/// Returns whether the channel-results queue holds any result. Any thread;
/// it reads an atomic count and takes no lock.
bool channelResultsReady();

/// A function that `channelDrain` calls on the eco thread with each result it
/// pops, once per result. It may change the registered callback; the drain
/// reads it again before each result. An exception it throws is reported as
/// fatal through `Eco::Kernel::reportFatal`.
using ChannelDispatchFn = void (*)(ChannelResult& r);
/// Makes `fn` the callback `channelDrain` hands results to. Eco thread. With
/// `nullptr`, popped results are discarded, and their tokens are never
/// completed.
void setChannelDispatch(ChannelDispatchFn fn);

/// Pops every queued result and hands each to the registered callback, then
/// calls `Scheduler::drain()` once if any result was handed over. Eco thread;
/// registered as an async source by the first `ByteChannel` constructed.
void channelDrain();

} // namespace Eco::System

#endif // ECO_SYSTEM_CORE_BYTE_CHANNEL_HPP
