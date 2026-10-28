#ifndef ECO_BITMAPSCAN_H
#define ECO_BITMAPSCAN_H

// Scans over an old-generation block's mark bitmap, which let that bitmap also serve as the block's allocation map.
//
// The old-generation mark bitmap has one bit per 8-byte granule, and a bit is set at the start of a marked or allocated
// object. A uniform block holds cells of one size s bytes, so its cell starts fall every m = s / 8 bits; m is the
// *stride*, and the bit at k * m is cell k's *cell-start bit*. When a block is allocated from its bitmap, a clear
// cell-start bit is a free cell and setting it allocates the cell. The functions here find clear cell-start bits, find
// set bits, and count set cell-start bits, a 64-bit word at a time where they can.
//
// The functions depend only on their arguments (and `kStride`), so they can be tested without a heap. Bit b lives in
// byte b / 8 at position b % 8 (least significant first), and a 64-bit word is read in host byte order with
// `std::memcpy`, so word w holds bits 64w to 64w + 63 only on a little-endian host. The word-at-a-time scans read whole
// words, so the array must extend to the end of the 64-bit word holding the last bit they examine. Nothing here is
// atomic: `setBit` and `clearBit` are plain read-modify-writes of one byte, and the scans read plain words, so a caller
// must keep any other thread from writing the words concerned.
//
// The stride arithmetic is table-driven: rebuilding a stride mask or dividing by m on each allocation was measured to
// make bitmap allocation slower than popping a free list, so the masks, word-to-word steps and reciprocals are
// precomputed once in `kStride`.

#include <cstddef>
#include <cstdint>
#include <cstring>

namespace Elm {
namespace bitscan {

/// Returns the 64-bit word `w` of `bits`, that is, bytes 8w to 8w + 7 read in host byte order.
inline uint64_t loadWord(const uint8_t* bits, size_t w) {
    uint64_t v;
    std::memcpy(&v, bits + w * 8, sizeof(v));
    return v;
}

/// Returns whether bit `bit` of `bits` is set.
inline bool testBit(const uint8_t* bits, size_t bit) {
    return (bits[bit >> 3] >> (bit & 7)) & 1u;
}
/// Sets bit `bit` of `bits`. The write is a plain, non-atomic byte update.
inline void setBit(uint8_t* bits, size_t bit) {
    bits[bit >> 3] |= static_cast<uint8_t>(1u << (bit & 7));
}
/// Clears bit `bit` of `bits`. The write is a plain, non-atomic byte update.
inline void clearBit(uint8_t* bits, size_t bit) {
    bits[bit >> 3] &= static_cast<uint8_t>(~(1u << (bit & 7)));
}

/// Returns a word with bits 0, m, 2m, ... below 64 set: the cell-start bits of a word whose bit 0 is a cell start.
/// `m` must be at least 1.
constexpr uint64_t strideMask(uint32_t m) {
    uint64_t v = 0;
    for (uint32_t b = 0; b < 64; b += m) v |= uint64_t{1} << b;
    return v;
}

/// Precomputed constants for each stride m in [1, 63], indexed by m. Index 0 is unused and zero.
struct StrideTables {
    uint64_t pattern[64];   ///< `strideMask(m)`.
    uint32_t step[64];      ///< 64 % m: how far the cell-start phase moves from one word to the next.
    uint64_t inv[64];       ///< ceil(2^32 / m), the reciprocal `divStride` multiplies by.
};
/// Builds the `StrideTables` for every stride in [1, 63].
constexpr StrideTables makeStrideTables() {
    StrideTables t{};
    for (uint32_t m = 1; m < 64; ++m) {
        t.pattern[m] = strideMask(m);
        t.step[m] = 64 % m;
        t.inv[m] = ((uint64_t{1} << 32) + m - 1) / m;
    }
    return t;
}
/// The stride tables, computed at compile time.
inline constexpr StrideTables kStride = makeStrideTables();

/// Returns g / m, rounded down, by multiplying by a reciprocal instead of dividing.
///
/// `m` must be in [1, 63] and `g` below 2^16, which covers every bit of a 512 KiB block. Within that range the result
/// is exact: ceil(2^32 / m) exceeds 2^32 / m by less than 1, so the product overshoots g * 2^32 / m by less than
/// g < 2^16, which is less than 2^32 / m. It therefore cannot carry past the next multiple of 2^32, and the top 32
/// bits are g / m.
inline uint32_t divStride(uint64_t g, uint32_t m) {
    return static_cast<uint32_t>((g * kStride.inv[m]) >> 32);
}

/// Returns the first cell k with `from_cell` <= k < `num_cells` whose cell-start bit k * `m` is clear, or `num_cells`
/// if there is none.
///
/// `m` must be at least 1, and `bits` must extend to the end of the word holding bit (`num_cells` - 1) * `m`. For `m`
/// below 64, every cell start must be below 2^16 (see `divStride`).
///
/// For `m` of 64 or more a word holds at most one cell start, so each cell's bit is tested on its own. Otherwise the
/// scan goes a word at a time: the cell starts in word w are `strideMask(m)` shifted left by (m - r) % m, where
/// r = 64w % m. r is computed with one modulo on entry and then advanced by 64 % m per word, and the cell index of the
/// lowest clear start is found with `divStride`, so the loop does no division.
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

/// Returns the first set bit of `bits` in [`from_bit`, `end_bit`), or `end_bit` if there is none. It reads a word at
/// a time, so `bits` must extend to the end of the word holding bit `end_bit` - 1.
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

/// Returns how many of the cell-start bits k * `m`, for k < `num_cells`, are set. It tests one bit per cell.
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
