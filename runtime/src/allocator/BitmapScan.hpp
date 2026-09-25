#ifndef ECO_BITMAPSCAN_H
#define ECO_BITMAPSCAN_H

// Bitmap scan primitives for old-gen bitmap allocation (threaded-gc-02,
// plans/threaded-gc-02-bitmap-allocation.md P§4 Step 2, HEAP_054/055).
//
// The old-gen mark bitmap has 1 bit per 8-byte granule, set at object starts.
// In a uniform block of cell size s the cell starts are every m = s/8 bits,
// and with bitmap allocation a clear cell-start bit is a free cell. These are
// pure functions over a byte array (little-endian bit order: bit b lives in
// byte b/8 at position b%8 — the MarkBitArena layout), so they are unit
// tested without a heap.
//
// Words are read with memcpy: MarkBitArena slots are 64-byte aligned
// (stride is a multiple of 64), so every 8-byte word is aligned, and a slot is
// always a whole number of words.

#include <cstddef>
#include <cstdint>
#include <cstring>

namespace Elm {
namespace bitscan {

inline uint64_t loadWord(const uint8_t* bits, size_t w) {
    uint64_t v;
    std::memcpy(&v, bits + w * 8, sizeof(v));
    return v;
}

inline bool testBit(const uint8_t* bits, size_t bit) {
    return (bits[bit >> 3] >> (bit & 7)) & 1u;
}
inline void setBit(uint8_t* bits, size_t bit) {
    bits[bit >> 3] |= static_cast<uint8_t>(1u << (bit & 7));
}
inline void clearBit(uint8_t* bits, size_t bit) {
    bits[bit >> 3] &= static_cast<uint8_t>(~(1u << (bit & 7)));
}

// Bits at 0, m, 2m, ... below 64 (m in [1, 63]).
constexpr uint64_t strideMask(uint32_t m) {
    uint64_t v = 0;
    for (uint32_t b = 0; b < 64; b += m) v |= uint64_t{1} << b;
    return v;
}

// Per-stride constants for m in [1, 63], so the scan never recomputes a mask
// or divides on its hot path (measured: rebuilding strideMask in a loop and
// four `div`s per allocation made the bitmap path SLOWER than the legacy
// free-list pop — the W3/W4 rule).
struct StrideTables {
    uint64_t pattern[64];   // strideMask(m)
    uint32_t step[64];      // 64 % m
    uint64_t inv[64];       // ceil(2^32 / m): g / m == (g * inv) >> 32 for g < 2^16
};
constexpr StrideTables makeStrideTables() {
    StrideTables t{};
    for (uint32_t m = 1; m < 64; ++m) {
        t.pattern[m] = strideMask(m);
        t.step[m] = 64 % m;
        t.inv[m] = ((uint64_t{1} << 32) + m - 1) / m;
    }
    return t;
}
inline constexpr StrideTables kStride = makeStrideTables();

// Exact g / m for m in [1, 63] and g < 2^16 (a 512 KiB block has 2^16 bits),
// via the reciprocal: the error of ceil(2^32/m) is < g / 2^32 < 1/m.
inline uint32_t divStride(uint64_t g, uint32_t m) {
    return static_cast<uint32_t>((g * kStride.inv[m]) >> 32);
}

// First cell k >= from_cell whose start bit k*m is CLEAR, or num_cells.
//
// m < 64: word at a time. For word w the cell-start positions are the bits b
// with (w*64 + b) % m == 0; with r = (w*64) % m that is b = (m - r) % m + j*m,
// i.e. pattern(m) << ((m - r) % m). r is computed ONCE on entry (one modulo)
// and then advanced by step(m) per word. The cell index is a reciprocal
// multiply, not a division. Callers try the next cell's bit directly first
// (OldGenSpace::cursorAllocate), so this runs only on a miss.
//
// m >= 64: at most one cell start per word; test each cell's byte directly.
inline uint32_t nextFreeCell(const uint8_t* bits, uint32_t m,
                             uint32_t from_cell, uint32_t num_cells) {
    if (from_cell >= num_cells) return num_cells;
    if (m >= 64) {
        for (uint32_t k = from_cell; k < num_cells; ++k) {
            if (!testBit(bits, static_cast<size_t>(k) * m)) return k;
        }
        return num_cells;
    }
    const uint64_t g0 = static_cast<uint64_t>(from_cell) * m;
    const uint64_t last_bit = static_cast<uint64_t>(num_cells - 1) * m;
    const size_t last_w = static_cast<size_t>(last_bit >> 6);
    size_t w = static_cast<size_t>(g0 >> 6);
    uint32_t r = static_cast<uint32_t>((static_cast<uint64_t>(w) * 64) % m);
    const uint64_t pattern = kStride.pattern[m];
    const uint32_t step = kStride.step[m];
    uint64_t mask = (pattern << (r ? m - r : 0)) & (~uint64_t{0} << (g0 & 63));
    for (;;) {
        const uint64_t free = ~loadWord(bits, w) & mask;
        if (free != 0) {
            const uint64_t g = (static_cast<uint64_t>(w) << 6) +
                               static_cast<uint64_t>(__builtin_ctzll(free));
            const uint32_t k = divStride(g, m);
            return k < num_cells ? k : num_cells;
        }
        if (w >= last_w) return num_cells;
        ++w;
        r += step;
        if (r >= m) r -= m;
        mask = pattern << (r ? m - r : 0);
    }
}

// First SET bit in [from_bit, end_bit), or end_bit. Word at a time.
inline size_t nextSetBit(const uint8_t* bits, size_t from_bit, size_t end_bit) {
    if (from_bit >= end_bit) return end_bit;
    size_t w = from_bit >> 6;
    uint64_t word = loadWord(bits, w) & (~uint64_t{0} << (from_bit & 63));
    const size_t last_w = (end_bit - 1) >> 6;
    for (;;) {
        if (word != 0) {
            const size_t b = (w << 6) + static_cast<size_t>(__builtin_ctzll(word));
            return b < end_bit ? b : end_bit;
        }
        if (w >= last_w) return end_bit;
        ++w;
        word = loadWord(bits, w);
    }
}

// Number of set bits at cell starts k*m, k < num_cells (validator V8).
inline uint64_t popcountCellStarts(const uint8_t* bits, uint32_t m,
                                   uint32_t num_cells) {
    uint64_t n = 0;
    for (uint32_t k = 0; k < num_cells; ++k) {
        n += testBit(bits, static_cast<size_t>(k) * m) ? 1 : 0;
    }
    return n;
}

}  // namespace bitscan
}  // namespace Elm

#endif  // ECO_BITMAPSCAN_H
