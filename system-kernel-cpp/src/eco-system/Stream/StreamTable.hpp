//===- StreamTable.hpp - The eco/system stream table ----------------------===//
//
// plans/eco-system-library.md §3.5. One main-thread-only table (a T5
// Registry) mapping an `int64_t` id to a StreamPair. A `Readable`,
// `Writable` or `Transformation` handle is the pair id; which side is meant
// follows from the Elm type and the kernel function called.
//
// Kinds:
//   * Identity      — in-memory transformation; values move writeQ → readQ
//                     in pump().
//   * ChannelSource — a readable over a ByteChannel (FdSource: an FdChannel).
//                     A parked read issues one channel read; nothing is
//                     prefetched, so readQ stays empty.
//   * ChannelSink   — a writable over a ByteChannel (FdSink). Each write is
//                     one channel write; writeQ holds the in-flight writes in
//                     channel order (valueEnc = 0: the bytes are off-heap).
//   * Custom        — in-memory transformation whose step calls the Elm
//                     action closure (customFnEnc) with the state
//                     (customStateEnc) and the value (G11).
//   * Codec         — in-memory transformation over a C++ engine
//                     (StreamCodec.hpp: zlib, UTF-8 encoder/decoder).
//   * MappedSource  — a readable over a ByteChannel of TAGGED chunks
//                     (plans/eco-system-websockets.md §3.3, W16). Unlike a
//                     ChannelSource it reads ahead one chunk (one channel
//                     read in flight while nothing is buffered; the chunk
//                     waits as POD in rawQ). A chunk becomes a value when a
//                     consumer takes it (a read, a parked read, a pipe):
//                     the Elm closure mapFnEnc (fromWire) is applied to
//                     ( tag, String, Bytes ) on the main thread (G11) and
//                     the result is the value. A subscription reader
//                     (attachReader) gets the chunks as POD instead, and
//                     reads fail Locked meanwhile. Read-ahead requests are
//                     uncounted (an idle source keeps nothing alive); a
//                     parked read holds its own count, a pipe makes the
//                     read in flight counted.
//   A ChannelSink with mapFnEnc != 0 is a MAPPED SINK: each accepted value
//   is passed to the closure (toWire : a -> ( Int, String, Bytes )) and
//   written with ByteChannel::requestWriteTagged.
//
// Pipes (pipeThrough / pipeTo, StreamPipe.cpp): a pipe owns the readable side
// of its source (pipedOut) and the writable side of its destination
// (pipedIn) until it finishes; both pairs are kept alive (pipeRefs) while it
// runs. Every state change of either pair re-runs the pipe.
//
// Every encoded word (queued values, Custom fn/state) is evacuated in place
// by the Registry scanner. Resume closures live in the Scheduler's
// pendingResumes_ (rooted there); the pair only holds their tokens.
//
// Lifetime: a pair is erased once both sides are Closed, nothing is parked or
// in flight and no pipe references it; a missing id then reads as Closed and writes as
// Cancelled "WritableStream is closed", which is what the erased pair would
// have answered. A pair with an Errored side is kept (queues emptied) so it
// keeps answering with its reason. The stdio pairs are pinned. Unreachable
// open pairs leak: the runtime has no finalizers (R3).
//
// Templates used: T5 (registry), T9 (parked operations).
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

enum class StreamKind : uint8_t { Identity, Custom, Codec, ChannelSource, ChannelSink, MappedSource };
enum class WState : uint8_t { Open, Closing, Closed, Errored };
enum class RState : uint8_t { Open, Closed, Errored };

// SErr kinds (B2): ( Int kind, String reason ).
constexpr int kSErrClosed = 0;
constexpr int kSErrCancelled = 1;
constexpr int kSErrLocked = 2;

struct PendingWrite {
    uint64_t token = 0;              // resume token; 0 = nothing to complete
    uint64_t valueEnc = 0;           // encoded value (0 for channel writes)
    bool completeOnTransform = true; // write: when it leaves writeQ; enqueue: on acceptance
    bool counted = false;            // holds one pendingAsync count (channel writes)
};

struct StreamPair {
    StreamKind kind = StreamKind::Identity;

    std::deque<PendingWrite> writeQ;   // accepted, not yet transformed / in flight
    std::deque<uint64_t> readQ;        // encoded values ready to read
    size_t writeCap = 1;
    size_t readCap = 1;

    WState w = WState::Open;
    RState r = RState::Open;
    std::string wReason, rReason;

    bool readLock = false;             // a read is parked
    bool writeLock = false;            // a write waits for room
    bool pipedOut = false;             // the readable side belongs to a pipe (lock)
    bool pipedIn = false;              // the writable side belongs to a pipe (lock)
    int64_t pipeOutId = 0;             // the pipe reading from this pair
    int64_t pipeInId = 0;              // the pipe writing into this pair
    int pipeRefs = 0;                  // live pipes naming this pair: never erased
    uint64_t parkedReadToken = 0;
    bool parkedReadCounted = false;
    std::deque<PendingWrite> waitingForRoom;

    uint64_t closeToken = 0;
    bool closeCounted = false;

    // Custom: the encoded action function and state.
    uint64_t customFnEnc = 0;
    uint64_t customStateEnc = 0;

    // Codec: the engine (zlib / UTF-8); off-heap.
    CodecPtr codec;

    // ChannelSource / ChannelSink / MappedSource.
    std::unique_ptr<ByteChannel> channel;

    // MappedSource: fromWire; mapped ChannelSink: toWire (0: a plain sink).
    uint64_t mapFnEnc = 0;
    // MappedSource: chunks read but not mapped yet (POD, at most one unless
    // the end arrived behind it), the outstanding read-ahead request
    // (synthetic token, 0 none) and whether it holds a pendingAsync count.
    std::deque<ChannelResult> rawQ;
    uint64_t readInFlight = 0;
    bool readInFlightCounted = false;
    int rErrno = 0;                    // the errno of a failed read (reader end result)
    // MappedSource: the subscription reader (attachReader), a kick posted
    // through the channel queue to hand it queued chunks / the end, and
    // whether it has been told about the end.
    ReaderFn reader = nullptr;
    void* readerCtx = nullptr;
    uint64_t readerKick = 0;
    bool readerEndSent = false;

    bool pinned = false;               // stdio pairs: never erased
    bool textSink = false;             // ChannelSink of Strings (createTextChannelSink)

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

// The table (main thread only, G1/G9). Lazily (re)registers its scanner and
// the channel dispatch callback.
Registry<StreamPair>& streamTable();

// Pumps pair `id` (§3.5 pump()): moves values through the transform,
// completes parked tokens, finishes closes, runs the pipes touching the
// pair, then erases the pair if it is done. Never blocks; calls Elm only for
// Custom pairs (G11). Pumps are driven from one work list: a pumpStream()
// issued while a pump is running (from a pipe, or from Elm re-entering a
// kernel) only marks the pair dirty, and the running driver picks it up.
// Main thread.
void pumpStream(int64_t id);

// --- Internal helpers shared by Stream.cpp and StreamPipe.cpp --------------

inline bool streamReadLocked(const StreamPair* p) {
    return p->readLock || p->pipedOut || p->reader != nullptr;
}
inline bool streamWriteLocked(const StreamPair* p) { return p->writeLock || p->pipedIn; }

// Completes parked `token` (T9) with Task.succeed `value` / Task.fail
// ( kind, reason ), releasing its pendingAsync count if `counted`. An
// orphaned token only releases its count.
void streamCompleteOk(uint64_t token, bool counted, HPointer value);
void streamCompleteErr(uint64_t token, bool counted, int kind, const std::string& reason);

// cancelReadable / cancelWritable without the lock check (pipes own the
// locks). Fail the affected tokens and pump the pair.
void streamCancelReadableNow(int64_t id, const std::string& reason);
void streamCancelWritableNow(int64_t id, const std::string& reason);

// Request ids for channel requests that have no resume of their own
// (enqueue on a sink, pipe reads/writes/closes). Disjoint from Scheduler
// resume tokens; takePendingResume on one is a harmless miss.
uint64_t streamSyntheticToken();
// Request ids that never hold a pendingAsync count (MappedSource
// read-ahead, reader kicks): the channel dispatch releases nothing for an
// orphaned one. Disjoint from both resume and synthetic tokens.
uint64_t streamUncountedToken();
bool streamIsUncountedToken(uint64_t token);

// MappedSource: issues the read-ahead request if one is due (r Open,
// nothing buffered or in flight, no reader kick pending). Counted iff a
// pipe reads from the pair. No heap allocation.
void streamMappedMaybeRead(int64_t id);
// Mapped sink: applies toWire to `value` (rooted by the caller) and copies
// the ( tag, String, Bytes ) result out (text = the String is non-empty;
// `bytes` is then its UTF-8, else the Bytes). Calls Elm (G11): re-fetch
// pairs afterwards.
void streamMapForSink(uint64_t toWireEnc, HPointer value, int64_t& tag, bool& text,
                      std::string& bytes);

// Pipes (StreamPipe.cpp).
// True if the pipe reading from `src` could take a value right now (a pipe
// is a waiting reader: it opens the readCap gate like a parked read).
bool streamPipeDemand(const StreamPair* src);
// Runs pipe `pipeId` (called by the pump driver).
void streamRunPipe(int64_t pipeId);
// Schedules pipe `pipeId` on the pump driver.
void streamSchedulePipe(int64_t pipeId);

// Stream kernel bodies (Stream.cpp), bound by StreamExports.cpp.
HPointer streamIdentityBody(HPointer captured);
HPointer streamReadBody(HPointer captured, HPointer resume);
HPointer streamWriteBody(HPointer captured, HPointer resume);
HPointer streamEnqueueBody(HPointer captured, HPointer resume);
HPointer streamCloseWritableBody(HPointer captured, HPointer resume);
HPointer streamCancelReadableBody(HPointer captured);
HPointer streamCancelWritableBody(HPointer captured);
HPointer streamCustomBody(HPointer captured);
HPointer streamTextEncoderBody(HPointer captured);
HPointer streamTextDecoderBody(HPointer captured);
HPointer streamCompressorBody(HPointer captured);
HPointer streamDecompressorBody(HPointer captured);
HPointer streamPipeThroughBody(HPointer captured);
HPointer streamPipeToBody(HPointer captured, HPointer resume);

// Strict UTF-8 validation (B5): true iff `s` is well-formed UTF-8 (no
// overlongs, no surrogates, nothing above U+10FFFF, no truncation).
bool isValidUtf8(const std::string& s);

} // namespace Eco::System

#endif // ECO_SYSTEM_STREAM_STREAM_TABLE_HPP
