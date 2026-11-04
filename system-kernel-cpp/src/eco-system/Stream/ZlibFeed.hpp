//===- ZlibFeed.hpp - Feeding zlib input of any size in slices ------------===//
//
// zlib's `avail_in` is a 32-bit `uInt`, so an input of 4 GiB or more cannot be handed to it in one go: a plain
// `static_cast<uInt>(n)` would silently drop all but `n` modulo 2^32 bytes. Every zlib loop of eco/system (the
// WebSocket permessage-deflate engine and the Codec streams) therefore gives zlib its input in slices of at most
// `kZlibMaxSlice` bytes, through `zlibRefill`, and treats the input as consumed only when zlib has consumed its
// slice and no slice is left.
//
//===----------------------------------------------------------------------===//

#ifndef ECO_SYSTEM_STREAM_ZLIB_FEED_HPP
#define ECO_SYSTEM_STREAM_ZLIB_FEED_HPP

#include "platform/TestHooks.hpp"

#include <zlib.h>

#include <algorithm>
#include <atomic>
#include <cstddef>

namespace Eco::System {

/// The most input bytes zlib is given at once: 1 GiB, well inside `uInt`.
inline constexpr size_t kZlibMaxSlice = size_t{1} << 30;

#if ECO_TEST_HOOKS
/// Test-only (ZLIB-01): the slice size `zlibSlice` returns instead of `kZlibMaxSlice`, or 0 for the default. A
/// unit test sets a tiny slice so that ordinary inputs take the many-slice paths.
inline std::atomic<size_t>& zlibSliceForTest() {
    static std::atomic<size_t> v{0};
    return v;
}
/// Returns the slice size in use: `kZlibMaxSlice`, unless a test has set another.
inline size_t zlibSlice() {
    const size_t v = zlibSliceForTest().load(std::memory_order_relaxed);
    return v != 0 ? v : kZlibMaxSlice;
}
#else
/// Returns the slice size in use: `kZlibMaxSlice`.
inline constexpr size_t zlibSlice() { return kZlibMaxSlice; }
#endif

/// Hands `s` its next input slice: when zlib has consumed all it was given (`avail_in == 0`) and `left` bytes
/// remain at `p`, points `next_in` at up to `zlibSlice()` of them and advances `p` and `left` past them.
/// Otherwise it does nothing. The input is all consumed once `s.avail_in == 0 && left == 0`.
inline void zlibRefill(z_stream& s, const char*& p, size_t& left) {
    if (s.avail_in != 0 || left == 0) return;
    const size_t n = std::min(left, zlibSlice());
    s.next_in = reinterpret_cast<Bytef*>(const_cast<char*>(p));
    s.avail_in = static_cast<uInt>(n);
    p += n;
    left -= n;
}

} // namespace Eco::System

#endif // ECO_SYSTEM_STREAM_ZLIB_FEED_HPP
