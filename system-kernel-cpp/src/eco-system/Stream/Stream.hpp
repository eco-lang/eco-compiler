//===- Stream.hpp - C++ API of the eco/system stream table ----------------===//
//
// plans/eco-system-library.md Appendix B.2 ("C++ API"): the functions other
// eco/system modules use to hand a byte channel to Elm as a stream. The
// returned id is wrapped in Elm by `Stream.Internal.Readable` /
// `Stream.Internal.Writable` (B3).
//
// All functions run on the main thread (G1) and allocate nothing on the
// heap, so they may be called from inside a binding body before or after
// any allocation.
//
// Templates used: T5 (the table behind them).
//
//===----------------------------------------------------------------------===//

#ifndef ECO_SYSTEM_STREAM_STREAM_HPP
#define ECO_SYSTEM_STREAM_STREAM_HPP

#include "eco-system/Core/ByteChannel.hpp"

#include <cstdint>

namespace Eco::System {

// A readable stream of Bytes over `channel`. The table takes ownership of
// the channel (it is destroyed when the pair is erased).
int64_t createChannelSource(ByteChannel* channel);

// A writable stream of Bytes over `channel`. Takes ownership as above.
int64_t createChannelSink(ByteChannel* channel);

// Text channels (plans/eco-system-websockets.md WS6): a channel source whose
// read results have ChannelResult::text set yields Strings (the UTF-8 of
// `bytes`, which must be whole characters) instead of Bytes — the same
// createChannelSource. A TEXT channel sink is a writable of Strings: each
// value's UTF-8 is written with requestWrite.
int64_t createTextChannelSink(ByteChannel* channel);

// Cancels the readable side of pair `id` with no reason (a source that never
// reached Elm, e.g. a WebSocket body nobody can receive): it is erased once
// its channel released. Allocates (it may complete parked tasks); main
// thread, outside the stream table's own callbacks.
void discardReadable(int64_t id);

// FdSource / FdSink: a ChannelSource / ChannelSink over an FdChannel.
// `owns` = the stream owns `fd` and closes it when it is closed. With
// `owns == false` the caller keeps `fd`: the channel works on a duplicate
// (fds 0–2 are never closed or duplicated, §3.4). Returns 0 on failure
// (only possible when duplicating fails).
int64_t createFdSource(int fd, bool owns);
int64_t createFdSink(int fd, bool owns);

// --- Value-mapped channel pairs (plans/eco-system-websockets.md §3.3, W16) ---
//
// They carry values the kernels cannot build (B1: e.g. WebSocket.Message)
// across the boundary: the channel speaks tagged POD chunks
// (ChannelResult::tag/text/bytes), Elm closures convert.

// A readable whose values are fromWire ( tag, text ? String : "",
// text ? empty : Bytes ) for each chunk the channel reads. `fromWireEnc` is
// the encoded closure (enc(closure)), stored in the (scanned) pair before
// any allocation; the closure is applied on the main thread when a consumer
// takes the chunk (a read, a parked read, a pipe) — G11. Reads ahead one
// chunk (the first request is issued here). Takes ownership of `channel`.
int64_t createMappedSource(ByteChannel* channel, uint64_t fromWireEnc);

// A writable whose accepted values are passed to toWire
// (a -> ( Int, String, Bytes )) and written with requestWriteTagged; a
// write completes when the channel completes it (as a ChannelSink).
int64_t createMappedSink(ByteChannel* channel, uint64_t toWireEnc);

// Subscription reader of a mapped source: while attached, chunks bypass
// readQ and fromWire and go to `fn` as POD (data, then once the end: eof,
// or err/reason), read-ahead continues as fast as `fn` returns, and reads,
// pipes and cancelReadable fail Locked. `fn` runs on the main thread from
// the channel drain (never inside attachReader; it may call Elm, G11/G12:
// the drain calls Scheduler::drain() afterwards). attachReader returns
// false (doing nothing) while a read is parked, the pair is piped, a
// reader is already attached, or the id is not a mapped source; chunks
// already read are handed to `fn` first, in order. detachReader returns
// the pair to normal reading (later chunks queue as usual); no-op if
// nothing is attached.
using ReaderFn = void (*)(int64_t pairId, ChannelResult& r, void* ctx);
bool attachReader(int64_t pairId, ReaderFn fn, void* ctx);
void detachReader(int64_t pairId);

// Pins pair `id` (it is never erased; the stdio pairs, §3.7).
void pinStream(int64_t id);

// An internal pipeTo with no Elm task (Http.Stream's upload pump, Phase 8):
// moves the readable side of `src` into the writable side of `dst` with the
// pipeTo propagation rules (§3.5), holding both locks until it finishes.
// Returns false, doing nothing, if `src` is read-locked or `dst` is
// write-locked. Unlike the functions above it may complete parked Elm tasks
// (it pumps both pairs), so it allocates: call it from a binding body.
bool pipeStreams(int64_t src, int64_t dst);

} // namespace Eco::System

#endif // ECO_SYSTEM_STREAM_STREAM_HPP
