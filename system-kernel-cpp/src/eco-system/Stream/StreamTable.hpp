//===- StreamTable.hpp - The eco/system stream table ----------------------===//
//
// Elm's `Stream` values are handles, and the state behind every handle lives in one table on the eco thread
// (the thread that runs the Elm scheduler). This header is that table's data model and the internal function
// surface that the stream implementation files and the few modules that inspect streams share.
//
// A *pair* is one table entry: a writable side, a readable side and whatever moves values from one to the
// other. A `Readable`, `Writable` or `Transformation` handle is the pair's `int64_t` id; which side is meant
// follows from the Elm type and the kernel function called. The table is a `Registry`, so the ids are that
// registry's and the heap values a pair holds are encoded words that the registry reports to the collector
// (`forEachWord`). Resume closures of parked tasks are not held here: they stay in the scheduler's pending
// resume table, and the pair keeps only their tokens.
//
// A pair is one of six kinds (`StreamKind`):
//   * Identity, Custom and Codec pairs are in memory. A value written is queued in `writeQ`, and a pump moves
//     it into `readQ`: unchanged, through the Elm action closure (Custom), or through a C++ codec engine such
//     as zlib or UTF-8 (Codec).
//   * A ChannelSource is a readable over a `ByteChannel`. It does not read ahead: a parked read issues one
//     channel read. Its `readQ` holds only chunks read for a pipe, or delivered by a withdrawn read (below)
//     with no read parked behind it.
//   * A ChannelSink is a writable over a `ByteChannel`. Each accepted write is one channel write, and `writeQ`
//     holds the writes in flight in channel order, with no heap value (the bytes are copied off the heap).
//     A ChannelSink with a mapping closure (`mapFnEnc`) is a *mapped sink*: each accepted value is passed to
//     the closure, which returns `( Int, String, Bytes )`, and the result is written as one tagged chunk.
//   * A MappedSource is a readable over a `ByteChannel` of tagged chunks. It reads ahead one chunk, which
//     waits in `rawQ` off the heap. When a consumer takes it (a read, a parked read or a pipe), the Elm
//     closure `mapFnEnc` is applied to `( tag, String, Bytes )` on the eco thread and its result is the value.
//     A *subscription reader* (`attachReader`) gets the raw chunks instead, and reads fail Locked meanwhile.
//
// A *withdrawn read* is a ChannelSource read whose parked task was killed. The channel request cannot be
// recalled, so it stays in flight (`chanReadTok`) and its result goes to the next read parked behind it, else
// into `readQ`, so no input is lost.
//
// A *pipe* (`pipeThrough`, `pipeTo`) owns the readable side of its source (`pipedOut`) and the writable side
// of its destination (`pipedIn`) until it finishes, and keeps both pairs from being erased (`pipeRefs`).
// Pumping a pair schedules the pipes that read from or write into it.
//
// Lifetime. A pair is erased when it is not pinned, no pipe names it, both sides are Closed, its queues are
// empty and nothing is parked or in flight. A missing id then reads as Closed and writes fail Cancelled with
// the reason "WritableStream is closed", which is what the erased pair would have answered. The stdio pairs
// are pinned.
//
//===----------------------------------------------------------------------===//

#ifndef ECO_SYSTEM_STREAM_STREAM_TABLE_HPP
#define ECO_SYSTEM_STREAM_STREAM_TABLE_HPP

#include "eco-system/Core/ByteChannel.hpp"
#include "eco-system/Core/Core.hpp"
#include "eco-system/Core/Registry.hpp"
#include "eco-system/Stream/Stream.hpp"
#include "eco-system/Stream/StreamCodec.hpp"

#include <cstdint>
#include <deque>
#include <memory>
#include <string>

namespace Eco::System {

/// What a pair is built on, and so how values reach its readable side. The file comment describes each kind.
enum class StreamKind : uint8_t { Identity, Custom, Codec, ChannelSource, ChannelSink, MappedSource };
/// Where a pair's writable side is. `Closing` means a close was requested and waits for the queued writes.
/// `Errored` keeps the reason in `wReason`, and later writes fail with it.
enum class WState : uint8_t { Open, Closing, Closed, Errored };
/// Where a pair's readable side is. `Closed` means the end was reached or the side was cancelled; `Errored`
/// keeps the reason in `rReason`, and later reads fail with it.
enum class RState : uint8_t { Open, Closed, Errored };

// The `kind` of an SErr, the `( Int kind, String reason )` failure a stream task fails with (`failSErr`).
/// The kind of an SErr for a stream that has ended; the reason is usually empty.
constexpr int kSErrClosed = 0;
/// The kind of an SErr for a stream that was cancelled or failed; the reason says why.
constexpr int kSErrCancelled = 1;
/// The kind of an SErr for a side already in use by a parked operation, a pipe or a subscription reader.
constexpr int kSErrLocked = 2;

/// One write a pair has accepted, or is holding until there is room, and the task to complete for it.
struct PendingWrite {
    uint64_t token = 0;              ///< The parked task's token; 0 when there is nothing to complete.
    uint64_t valueEnc = 0;           ///< The encoded value; 0 for a channel write, whose bytes are off the heap.
    /// True for a write, completed when its value leaves `writeQ`; false for an enqueue, completed on acceptance.
    bool completeOnTransform = true;
    bool counted = false;            ///< `token` is also a liveness hold, released when the write completes.
};

/// One stream: a writable side, a readable side, and the state of whatever moves values between them.
///
/// The members are plain data shared by the stream implementation files; the rules between them are kept by
/// that code, not by this type. A pointer to a pair is valid until the pair is erased. That can happen in any
/// `pumpStream` and in any call into Elm, which may re-enter a kernel that pumps, so code looks a pair up
/// again by id after either.
struct StreamPair {
    StreamKind kind = StreamKind::Identity;

    // The queues and their capacities.
    std::deque<PendingWrite> writeQ;   ///< Accepted writes not yet transformed; a ChannelSink's writes in flight.
    std::deque<uint64_t> readQ;        ///< Encoded values ready to read.
    size_t writeCap = 1;
    size_t readCap = 1;

    WState w = WState::Open;
    RState r = RState::Open;
    // The reasons an Errored side answers with.
    std::string wReason, rReason;

    // Locks and pipes. A locked side refuses other readers or writers with `kSErrLocked`.
    bool readLock = false;             ///< A read is parked.
    bool writeLock = false;            ///< A write waits for room.
    bool pipedOut = false;             ///< The readable side belongs to a pipe.
    bool pipedIn = false;              ///< The writable side belongs to a pipe.
    int64_t pipeOutId = 0;             ///< The pipe reading from this pair; 0 for none.
    int64_t pipeInId = 0;              ///< The pipe writing into this pair; 0 for none.
    int pipeRefs = 0;                  ///< Running pipes naming this pair; the pair is not erased while positive.
    uint64_t parkedReadToken = 0;      ///< The parked read's token, or a pipe's read request; 0 for none.
    bool parkedReadCounted = false;    ///< `parkedReadToken` is also a liveness hold.
    // ChannelSource: the request id of the channel read in flight, 0 for none. Usually it is the parked read's
    // or the pipe's own token. For a withdrawn read it is the killed read's token, whose hold the kill handle
    // has released; a read parked behind it issues no request of its own and takes its result.
    uint64_t chanReadTok = 0;
    /// Writes refused room in `writeQ`, waiting for it in order.
    std::deque<PendingWrite> waitingForRoom;

    uint64_t closeToken = 0;           ///< The parked close's token, or a pipe's close request; 0 for none.
    bool closeCounted = false;         ///< `closeToken` is also a liveness hold.

    // Custom: the encoded action closure and its current state.
    uint64_t customFnEnc = 0;
    uint64_t customStateEnc = 0;

    // Codec: the engine, off the heap.
    CodecPtr codec;

    // ChannelSource, ChannelSink and MappedSource: the channel, owned by the pair.
    std::unique_ptr<ByteChannel> channel;

    /// The encoded mapping closure: a MappedSource's `fromWire`, a mapped sink's `toWire`; 0 for a plain sink.
    uint64_t mapFnEnc = 0;
    // MappedSource: chunks read but not mapped yet, off the heap and never scanned.
    std::deque<ChannelResult> rawQ;
    uint64_t readInFlight = 0;         ///< The read-ahead request in flight, an uncounted token; 0 for none.
    /// The hold a waiting pipe gave the read-ahead request; `kNoHold` for none. Released by the read's result.
    HoldToken readInFlightHold = kNoHold;
    int rErrno = 0;                    ///< The errno of a failed read, reported to a subscription reader at the end.
    // MappedSource: the subscription reader, if one is attached. `readerCtx` is passed back to `reader` and is
    // not owned by the pair; whoever attached it keeps it valid until it detaches.
    ReaderFn reader = nullptr;
    void* readerCtx = nullptr;
    /// A request posted through the channel queue to hand the reader its queued chunks or the end; 0 for none.
    uint64_t readerKick = 0;
    bool readerEndSent = false;

    // Stream.readLine: bytes read past the last line handed out, off the heap and never scanned. `carryPos` is
    // the start of the unread part; the consumed prefix is erased once it passes half the buffer. `read`
    // hands the unread part out before anything else.
    std::string carry;
    size_t carryPos = 0;

    bool pinned = false;               ///< Never erased (the stdio pairs).
    bool textSink = false;             ///< A ChannelSink whose values are Strings rather than Bytes.

    /// Calls `f` on every encoded heap word the pair holds, so the registry can report them to the collector.
    /// `rawQ`, `carry` and the codec are off the heap and are not visited.
    template <typename F>
    void forEachWord(F&& f) {
        for (auto& v : readQ) f(v);
        for (auto& pw : writeQ) f(pw.valueEnc);
        for (auto& pw : waitingForRoom) f(pw.valueEnc);
        f(customFnEnc);
        f(customStateEnc);
        f(mapFnEnc);
    }
};

/// Returns the stream table, created on the first call and never destroyed. The first call also installs the
/// dispatch that routes channel results to their pairs. Eco thread only.
Registry<StreamPair>& streamTable();

/// Brings pair `id` up to date: moves values from the writable side to the readable side, completes parked
/// reads, writes and closes that can now complete, schedules the pipes that read from or write into the pair,
/// and erases the pair if the file comment's erasure rule allows. A missing id does nothing.
///
/// Pumps run from one work list. A call made while a pump is already running, from a pipe or from Elm code
/// re-entering a kernel, only adds the pair to the list, and the running pump reaches it before returning.
/// Completing a task, a Custom step and a MappedSource's mapping call Elm, and the pair may be erased, so any
/// `StreamPair*` held across this call must be looked up again. If a step throws, the work list is cleared
/// and the exception propagates.
/// Eco thread only.
void pumpStream(int64_t id);

// --- Internal helpers shared by Stream.cpp and StreamPipe.cpp --------------

/// Returns whether the readable side of `p` is in use: a read is parked, a pipe owns it, or a subscription
/// reader is attached. `p` must not be null.
inline bool streamReadLocked(const StreamPair* p) {
    return p->readLock || p->pipedOut || p->reader != nullptr;
}
/// Returns whether the writable side of `p` is in use: a write waits for room or a pipe owns it. `p` must not
/// be null.
inline bool streamWriteLocked(const StreamPair* p) { return p->writeLock || p->pipedIn; }

/// Completes the task parked under `token` with `Task.succeed value`, then releases the hold `token` names if
/// `counted`. A counted token is its own hold id (from `Scheduler::parkResume` or `streamHeldToken`). If no
/// resume is parked under `token`, only the hold is released. Calls Elm and allocates; `value` is rooted here.
void streamCompleteOk(uint64_t token, bool counted, HPointer value);
/// Completes the task parked under `token` with `Task.fail ( kind, reason )`, otherwise as `streamCompleteOk`.
void streamCompleteErr(uint64_t token, bool counted, int kind, const std::string& reason);

/// Cancels the readable side of pair `id` without checking its lock, for callers that own the lock, such as a
/// pipe. The readable side becomes Closed and its buffered values are dropped. A writable side still Open or
/// Closing becomes Errored with `reason`, and the writes and close parked on it fail with `reason`. A channel
/// source's channel is shut down. The pair is then pumped. A missing id does nothing. Allocates and calls Elm.
void streamCancelReadableNow(int64_t id, const std::string& reason);
/// Cancels the writable side of pair `id` without checking its lock. Unless the writable side is already
/// Closed or Errored, both sides become Errored with `reason`, the queued values are dropped, the parked
/// operations fail with `reason`, and a ChannelSink's channel is shut down. The pair is then pumped. A missing
/// id does nothing. Allocates and calls Elm.
void streamCancelWritableNow(int64_t id, const std::string& reason);

/// Returns a new request id for a channel request that has no parked task of its own, such as an enqueue on a
/// sink or a pipe's read, write or close. The id is itself a liveness hold of kind Task, counted under `site`
/// (`Scheduler::acquireHold`), which keeps the program alive until the request's result releases it. It is
/// never a resume token, so looking a resume up under it finds nothing.
uint64_t streamHeldToken(const char* site);
/// Returns a new request id that holds nothing, for a MappedSource's read-ahead and a subscription reader's
/// requests. These ids lie in a range of their own, apart from resume tokens and held tokens.
uint64_t streamUncountedToken();
/// Returns whether `token` is in the range `streamUncountedToken` draws from.
bool streamIsUncountedToken(uint64_t token);

/// Issues the read-ahead request for MappedSource `id` if one is due: the readable side is Open, nothing is
/// buffered or in flight, and no request to a subscription reader is pending. The request holds the program
/// alive only if a pipe reads from the pair. Does nothing for a missing id or another kind. No heap allocation.
void streamMappedMaybeRead(int64_t id);
/// Applies the mapped sink's closure `toWireEnc` to `value` and copies the `( tag, String, Bytes )` result
/// out: `tag` is the Int, and if the String is non-empty `text` is set and `bytes` is its UTF-8, otherwise
/// `text` is cleared and `bytes` holds the Bytes. `value` must be rooted by the caller. Calls Elm, so a
/// `StreamPair*` held across this call must be looked up again.
void streamMapForSink(uint64_t toWireEnc, HPointer value, int64_t& tag, bool& text,
                      std::string& bytes);

// Pipes.
/// Returns whether a pipe reads from `src` and its destination could take a value now. Such a pipe counts as
/// a waiting reader, so a pump moves a value to `src`'s readable side even when `readQ` is at its capacity.
/// `src` must not be null.
bool streamPipeDemand(const StreamPair* src);
/// Moves values through pipe `pipeId` as far as its source and destination allow. Called by the pump driver.
void streamRunPipe(int64_t pipeId);
/// Adds pipe `pipeId` to the pump work list and runs the pumps, as `pumpStream` does for a pair.
void streamSchedulePipe(int64_t pipeId);

// The bodies of the `Stream` kernel functions, bound to their exports elsewhere. Each takes the kernel's
// payload as `captured`; those with a `resume` start a task that may park until the stream can answer.
HPointer streamIdentityBody(HPointer captured); ///< Creates an Identity pair.
HPointer streamReadBody(HPointer captured, HPointer resume); ///< Reads the next value, the unread line carry first.
HPointer streamReadChunkBody(HPointer captured, HPointer resume); ///< Reads the next value, ignoring the carry.
HPointer streamCarryLineBody(HPointer captured); ///< Takes the next line from the carry.
HPointer streamCarryAppendBody(HPointer captured); ///< Appends bytes to the carry.
HPointer streamWriteBody(HPointer captured, HPointer resume); ///< Writes a value; waits until it is consumed.
HPointer streamEnqueueBody(HPointer captured, HPointer resume); ///< Writes a value; completes once it is accepted.
HPointer streamCloseWritableBody(HPointer captured, HPointer resume); ///< Closes the writable side.
HPointer streamCancelReadableBody(HPointer captured); ///< Cancels the readable side; fails Locked if in use.
HPointer streamCancelWritableBody(HPointer captured); ///< Cancels the writable side; fails Locked if in use.
HPointer streamCustomBody(HPointer captured); ///< Creates a Custom pair over an Elm action.
HPointer streamTextEncoderBody(HPointer captured); ///< Creates a Codec pair encoding Strings as UTF-8.
HPointer streamTextDecoderBody(HPointer captured); ///< Creates a Codec pair decoding UTF-8 into Strings.
HPointer streamCompressorBody(HPointer captured); ///< Creates a compressing Codec pair.
HPointer streamDecompressorBody(HPointer captured); ///< Creates a decompressing Codec pair.
HPointer streamPipeThroughBody(HPointer captured); ///< Pipes a readable through a transformation.
HPointer streamPipeToBody(HPointer captured, HPointer resume); ///< Pipes a readable into a writable.

/// Returns whether `s` is well-formed UTF-8: no overlong forms, no surrogates, nothing above U+10FFFF and no
/// truncated sequence.
bool isValidUtf8(const std::string& s);

} // namespace Eco::System

#endif // ECO_SYSTEM_STREAM_STREAM_TABLE_HPP
