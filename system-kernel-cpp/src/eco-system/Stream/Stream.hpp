//===- Stream.hpp - C++ API of the eco/system stream table ----------------===//
//
// Other eco/system modules produce and consume bytes through their own transports (files, child processes,
// sockets, HTTP transfers, WebSockets), and Elm reads and writes them as `Stream` values. This header is how
// such a module hands a transport to Elm as a stream.
//
// A transport is a `ByteChannel`. Each function here makes a *pair*, an entry in the stream table
// (`streamTable`, whose header describes pairs, their kinds and when one is erased), and returns its id. That
// id is what Elm wraps as a `Readable` or `Writable` handle. A pair made from a channel takes ownership of it,
// and the channel is destroyed when the pair is.
//
// Two families of pair can be made, and one of them can also be read without Elm:
//   * A *channel source* or *channel sink* carries the channel's bytes as Bytes values, or as Strings for a
//     text channel.
//   * A *mapped source* or *mapped sink* carries values the kernel cannot build itself, such as a WebSocket
//     message. The channel speaks in chunks labelled with an integer tag, and an Elm closure converts each
//     chunk into a value, or each value into a chunk.
//   * A *subscription reader* can take a mapped source's chunks directly in C++, bypassing Elm reads.
//
// Every function must be called on the eco thread, the thread that runs the Elm scheduler. All of them
// except `discardReadable`, `discardWritable` and `pipeStreams` make no allocation on the GC heap and call no
// Elm code, so they may be called from a binding body before or after its allocations. Those three complete
// parked Elm tasks, and so allocate and call Elm.
//
//===----------------------------------------------------------------------===//

#ifndef ECO_SYSTEM_STREAM_STREAM_HPP
#define ECO_SYSTEM_STREAM_STREAM_HPP

#include "eco-system/Core/ByteChannel.hpp"

#include <cstdint>

namespace Eco::System {

/// Creates a readable pair over `channel` and returns its id. The pair takes ownership of `channel`, which
/// must not be null. Each chunk the channel reads becomes one value: a String decoded from its bytes when the
/// result has `ChannelResult::text` set, otherwise Bytes. A text chunk becomes a String on its own, so a
/// channel that sets `text` should deliver whole UTF-8 characters in each chunk. Nothing is read until a
/// reader or a pipe asks.
int64_t createChannelSource(ByteChannel* channel);

/// Creates a writable pair of Bytes over `channel` and returns its id. The pair takes ownership of
/// `channel`, which must not be null. Each accepted value is one channel write, and a write completes when
/// the channel answers it.
int64_t createChannelSink(ByteChannel* channel);

/// Creates a writable pair of Strings over `channel` and returns its id. As `createChannelSink`, except that
/// each value is written as the UTF-8 of the String.
int64_t createTextChannelSink(ByteChannel* channel);

/// Cancels the readable side of pair `id` with an empty reason, for a source that never reached Elm code
/// able to read it. Its buffered values are dropped and the channel of a channel or mapped source is shut
/// down; an unpinned channel or mapped source is then erased once nothing is left in flight, while a pair
/// with a live writable side is left errored. Any tasks parked on the pair are completed with an error,
/// which allocates and calls Elm. A missing id does nothing.
void discardReadable(int64_t id);

/// Closes the writable side of pair `id`, for a sink that never reached Elm code able to write to it, so that
/// the pair can be erased. Its queued writes, if any, are dropped and fail with an empty reason, and the
/// channel of a channel or mapped sink is shut down; the pair is then erased once nothing is left in flight.
/// Any tasks parked on the pair are completed with an error, which allocates and calls Elm. A missing id, or
/// a writable side already Closed or Errored, does nothing.
void discardWritable(int64_t id);

/// Creates a channel source over the file descriptor `fd` and returns its id, or 0 if `fd` is negative or
/// cannot be duplicated.
///
/// With `owns`, the stream takes `fd` and it is closed when the channel finishes; the fd's open file description
/// must then be the stream's alone, since a pipe or terminal is made non-blocking (`FdChannelOptions::nonBlocking`).
/// Otherwise the caller keeps `fd`, and the channel works on a close-on-exec duplicate numbered 3 or above, left in
/// its blocking mode. fds 0 to 2 are never
/// duplicated and never closed. On Windows `fd` is used as given in both cases. `origin` names the resource
/// in failure reasons (`FdChannelOptions::origin`); the channel keeps the pointer, so the string must
/// outlive the stream, as a string literal does.
int64_t createFdSource(int fd, bool owns, const char* origin);
/// Creates a channel sink over the file descriptor `fd` and returns its id, or 0 on failure. `fd`, `owns`
/// and `origin` mean what they do for `createFdSource`.
int64_t createFdSink(int fd, bool owns, const char* origin);

// --- Value-mapped pairs ----------------------------------------------------

/// Creates a mapped source over `channel` and returns its id. The pair takes ownership of `channel`, which
/// must not be null.
///
/// `fromWireEnc` is the encoded Elm closure that turns a chunk into a value. The word must be current when
/// this is called, with no allocation since it was encoded; the pair keeps it where the collector updates
/// it. Each chunk the channel reads waits off the heap until a consumer takes it (a read, a parked read or a
/// pipe), and then the closure is applied on the eco thread to `( tag, text, bytes )`. For a chunk with
/// `ChannelResult::text` set, `text` is its UTF-8 decoded as a String and `bytes` is empty; otherwise `text`
/// is "" and `bytes` holds the data.
///
/// The pair reads ahead one chunk, and the first read is requested here. A read-ahead requested while a
/// pipe reads from the pair keeps the program alive until it answers; a parked read holds the program
/// alive itself.
int64_t createMappedSource(ByteChannel* channel, uint64_t fromWireEnc);

/// Creates a mapped sink over `channel` and returns its id. The pair takes ownership of `channel`, which
/// must not be null.
///
/// `toWireEnc` is the encoded Elm closure of type `a -> ( Int, String, Bytes )`, with the same currency
/// requirement as `fromWireEnc`. Each accepted value is passed to it, and the result is written as one
/// chunk with `requestWriteTagged`: the Int is the tag, and a non-empty String is written as text, otherwise
/// the Bytes are written. A write completes when the channel answers it.
int64_t createMappedSink(ByteChannel* channel, uint64_t toWireEnc);

/// A subscription reader: the callback that receives a mapped source's chunks in C++ while attached.
///
/// It is called with the pair's id, a chunk, and the `ctx` given to `attachReader`. A chunk with data comes
/// as a Read result. The end comes once, as a result with `eof` set, or with `err` (the errno, `EIO` when
/// none is known) and `reason` set to the pair's failure reason. `r` is valid only during the call. It is
/// called on the eco thread from the channel drain, never from inside `attachReader`, and it may call Elm,
/// since the drain runs the scheduler afterwards.
using ReaderFn = void (*)(int64_t pairId, ChannelResult& r, void* ctx);

/// Attaches `fn` as the subscription reader of mapped source `pairId` and returns whether it did.
///
/// While attached, chunks go to `fn` instead of waiting to be mapped. Reading ahead continues as fast as
/// `fn` returns. Reads, pipes and `cancelReadable` on the pair fail as Locked. Chunks read before the call
/// are handed to `fn` first, in order. The pair keeps `ctx` without owning it, and it must stay valid until
/// `detachReader` or until the pair is erased.
///
/// Returns false, doing nothing, if `fn` is null, the id is not a mapped source, a reader is already
/// attached, a read is parked, a pipe reads from the pair, or mapped values are waiting to be read.
bool attachReader(int64_t pairId, ReaderFn fn, void* ctx);
/// Detaches the subscription reader of pair `pairId`, returning the pair to normal reading: later chunks
/// wait for a consumer as usual. Does nothing if no reader is attached.
void detachReader(int64_t pairId);

/// Pins pair `id`, so that it is never erased. A missing id does nothing.
void pinStream(int64_t id);

/// Pipes the readable side of pair `src` into the writable side of pair `dst` with no Elm task to report
/// the outcome, and returns whether the pipe was started.
///
/// The pipe owns both sides until it finishes. When `src` has ended and been drained, `dst` is closed; when
/// `src` has failed, `dst` is cancelled with its reason; when `dst` is closed or has failed, `src` is
/// cancelled. A missing `src` counts as an ended one, and a missing `dst` as a closed one, so an unknown id
/// still starts a pipe and returns true. Returns false,
/// doing nothing, if `src`'s readable side is in use (a parked read, a pipe or a subscription reader) or
/// `dst`'s writable side is (a write waiting for room or a pipe). Runs the pumps of both pairs, which may
/// complete parked tasks, so it allocates and calls Elm.
bool pipeStreams(int64_t src, int64_t dst);

} // namespace Eco::System

#endif // ECO_SYSTEM_STREAM_STREAM_HPP
