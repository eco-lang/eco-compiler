//===- ByteChannel.hpp - Abstract byte channel + the channel-results queue ===//
//
// plans/eco-system-library.md §3.5 "Byte channels": ChannelSource /
// ChannelSink stream pairs work over this interface. FdChannel (§3.4) is one
// implementation, HttpTransferChannel (Phase 8) another.
//
// Contract:
//   * Requests are made on the main thread. Each request carries the
//     scheduler resume token of the parked Elm task (T9) and produces
//     EXACTLY ONE ChannelResult with that token: data / EOF / errno for a
//     read, bytes written / errno for a write, close status for a close.
//     Requests still pending at shutdown(), or made after it, complete with
//     err = ECANCELED.
//   * Results are POD (G1). Channel threads post them to one process-wide
//     channel-results queue; the main-thread ChannelDrain pops them and
//     dispatches each to the callback registered with setChannelDispatch
//     (the StreamTable, Phase 3), so Core does not depend on Stream. After
//     dispatching, the drain calls Scheduler::drain() once (T9): the
//     callback completes parked tokens but does not drain itself.
//   * pendingAsync accounting belongs to the requester (keep-alive rule,
//     §3.4): one count per parked fd read/write, released by whoever
//     completes the token.
//
// Templates used: T9 (completion side).
//
//===----------------------------------------------------------------------===//

#ifndef ECO_SYSTEM_CORE_BYTE_CHANNEL_HPP
#define ECO_SYSTEM_CORE_BYTE_CHANNEL_HPP

#include <cstddef>
#include <cstdint>
#include <string>

namespace Eco::System {

struct ChannelResult {
    enum class Op : uint8_t { Read, Write, Close };
    uint64_t channelId = 0;
    uint64_t token = 0;
    Op op = Op::Read;
    int err = 0;            // 0, or the errno (ECANCELED after shutdown)
    bool eof = false;       // Read: end of input (bytes empty)
    std::string bytes;      // Read: the data (non-empty unless eof or err)
    size_t written = 0;     // Write: bytes written (all of them on success)
};

class ByteChannel {
public:
    virtual ~ByteChannel() = default;

    ByteChannel(const ByteChannel&) = delete;
    ByteChannel& operator=(const ByteChannel&) = delete;

    // Process-unique id, echoed in every result (ChannelResult::channelId).
    uint64_t id() const { return id_; }

    // Read at most `maxBytes` (> 0) bytes. Requests complete in order.
    virtual void requestRead(uint64_t token, size_t maxBytes) = 0;
    // Write all of `bytes`. Requests complete in order.
    virtual void requestWrite(uint64_t token, std::string bytes) = 0;
    // Graceful close: after every queued write has completed, release the
    // underlying resource and post a Close result (err = 0 or errno). Pending
    // reads complete with ECANCELED. `token` may be 0 (still posted).
    virtual void close(uint64_t token) = 0;
    // Immediate stop: wake the channel thread, complete every pending
    // request with ECANCELED and release the resource. Idempotent.
    virtual void shutdown() = 0;

protected:
    ByteChannel();   // main thread: assigns the id, ensures the drain source

private:
    uint64_t id_;
};

// --- The channel-results queue (ChannelDrain.cpp) --------------------------

// Any thread. Queues `r` and wakes the scheduler loop.
void postChannelResult(ChannelResult r);

// Main thread (the drain, or a test). Non-blocking.
bool tryPopChannelResult(ChannelResult& out);
bool channelResultsReady();

// Main thread. The callback the drain dispatches each result to (nullptr
// clears it; results are then dropped).
using ChannelDispatchFn = void (*)(ChannelResult& r);
void setChannelDispatch(ChannelDispatchFn fn);

// Main thread: the channel drain (runs from the eco/system async source).
void channelDrain();

} // namespace Eco::System

#endif // ECO_SYSTEM_CORE_BYTE_CHANNEL_HPP
