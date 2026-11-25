//===- Crc32c.hpp - CRC32C over String units, with composition --------------===//
//
// The raw String hash of value-hash.md definition v4: CRC32C (Castagnoli, reflected polynomial
// 0x82F63B78) over a String's UTF-16 units read as little-endian byte pairs, from the initial register
// 0xFFFFFFFF, without the final inversion. A UTF-8 form's bytes are its units, each widened to a pair
// (byte, 0). A String's raw state can be continued over further units (`update16`, `update8`), and the
// raw states of two Strings give that of their concatenation (`combine`), so a String built from parts
// gets its hash from theirs without reading them (plans/hash-reuse-explicit-vs-cached.md §4.1.5).
//
// On x86-64 CPUs with SSE4.2 and PCLMULQDQ (checked once, at first use) long runs are folded 64 bytes per
// step with carry-less multiplies and short ones go through three interleaved crc32 instruction streams
// (crc32c-fold128, design_docs/string-hash-algorithm.md). Elsewhere a table-driven implementation gives
// the same numbers. Nothing here allocates.
//
//===----------------------------------------------------------------------===//

#pragma once

#include <cstddef>
#include <cstdint>

namespace Elm::crc32c {

// The raw state of no units: the initial register. combine(a, kEmpty, 0) == a.
constexpr uint32_t kEmpty = 0xFFFFFFFFu;

// Continues the raw state `state` over `n` UTF-16 units.
uint32_t update16(uint32_t state, const uint16_t* units, size_t n);

// Continues the raw state `state` over `n` units given as bytes (a UTF-8 form's ASCII bytes).
uint32_t update8(uint32_t state, const uint8_t* bytes, size_t n);

// The raw state of x ++ y, given raw(x) = `a`, raw(y) = `b` and y's length `nb` in units.
uint32_t combine(uint32_t a, uint32_t b, uint64_t nb);

// Whether the SSE4.2 + PCLMULQDQ paths are in use on this CPU.
bool hardware();

// The table-driven implementations, which the hardware paths must agree with (tests).
uint32_t update16Portable(uint32_t state, const uint16_t* units, size_t n);
uint32_t update8Portable(uint32_t state, const uint8_t* bytes, size_t n);
uint32_t combinePortable(uint32_t a, uint32_t b, uint64_t nb);

} // namespace Elm::crc32c
