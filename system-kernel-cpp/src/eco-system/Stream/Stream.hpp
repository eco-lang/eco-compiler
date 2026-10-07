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

// FdSource / FdSink: a ChannelSource / ChannelSink over an FdChannel.
// `owns` = the stream owns `fd` and closes it when it is closed. With
// `owns == false` the caller keeps `fd`: the channel works on a duplicate
// (fds 0–2 are never closed or duplicated, §3.4). Returns 0 on failure
// (only possible when duplicating fails).
int64_t createFdSource(int fd, bool owns);
int64_t createFdSink(int fd, bool owns);

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
