/**
 * threaded-gc-02 Step 2 (plans/threaded-gc-02-bitmap-allocation.md): the
 * word-at-a-time bitmap scans agree with naive per-cell / per-bit references
 * for every class stride, density and start position.
 */

#include "BitmapScanTest.hpp"

#include <cstdint>
#include <random>
#include <vector>

#include "BitmapScan.hpp"
#include "TestHelpers.hpp"

using namespace Elm;

namespace {

constexpr size_t kBlockBytes = 512 * 1024;
constexpr size_t kBitmapBytes = kBlockBytes / 64;   // 8 KiB, whole words

uint32_t refNextFree(const std::vector<uint8_t>& b, uint32_t m,
                     uint32_t from, uint32_t n) {
    for (uint32_t k = from; k < n; ++k) {
        if (!bitscan::testBit(b.data(), static_cast<size_t>(k) * m)) return k;
    }
    return n;
}

size_t refNextSet(const std::vector<uint8_t>& b, size_t from, size_t end) {
    for (size_t i = from; i < end; ++i) {
        if (bitscan::testBit(b.data(), i)) return i;
    }
    return end;
}

}  // namespace

Testing::TestCase testBitmapNextFreeCellMatchesReference(
    "HEAP_054: nextFreeCell == per-cell reference (all strides, densities, starts)",
    []() {
        std::mt19937_64 rng(0xB17A);
        const uint32_t strides[] = {2, 3, 4, 5, 6, 7, 8, 12, 16, 24, 31, 32,
                                    64, 128, 1024};
        const int densities[] = {0, 10, 50, 90, 99, 100};
        for (uint32_t m : strides) {
            const uint32_t n = static_cast<uint32_t>((kBlockBytes / 8) / m);
            for (int d : densities) {
                std::vector<uint8_t> bits(kBitmapBytes, 0);
                // Set cell-start bits at density d; also sprinkle NON-cell-start
                // bits, which the scan must ignore (they never occur in a real
                // uniform block, but the mask must not depend on that).
                for (uint32_t k = 0; k < n; ++k) {
                    if (static_cast<int>(rng() % 100) < d) {
                        bitscan::setBit(bits.data(), static_cast<size_t>(k) * m);
                    }
                    if (m > 1 && (rng() % 7) == 0) {
                        bitscan::setBit(bits.data(),
                                        static_cast<size_t>(k) * m + 1 + rng() % (m - 1));
                    }
                }
                for (int t = 0; t < 1000; ++t) {
                    const uint32_t from = static_cast<uint32_t>(rng() % (n + 1));
                    TEST_ASSERT(bitscan::nextFreeCell(bits.data(), m, from, n) ==
                                refNextFree(bits, m, from, n));
                }
                // Edges.
                TEST_ASSERT(bitscan::nextFreeCell(bits.data(), m, n, n) == n);
                TEST_ASSERT(bitscan::nextFreeCell(bits.data(), m, n - 1, n) ==
                            refNextFree(bits, m, n - 1, n));
                TEST_ASSERT(bitscan::nextFreeCell(bits.data(), m, 0, n) ==
                            refNextFree(bits, m, 0, n));
            }
        }
        // A partial last word: num_cells not filling the bitmap.
        std::vector<uint8_t> bits(kBitmapBytes, 0xFF);
        bitscan::clearBit(bits.data(), 3 * 99);
        TEST_ASSERT(bitscan::nextFreeCell(bits.data(), 3, 0, 100) == 99);
        TEST_ASSERT(bitscan::nextFreeCell(bits.data(), 3, 0, 99) == 99);
    });

Testing::TestCase testBitmapNextSetBitMatchesReference(
    "HEAP_055: nextSetBit == per-bit reference",
    []() {
        std::mt19937_64 rng(0x5E7B);
        const size_t total = kBitmapBytes * 8;
        for (int d : {0, 1, 10, 50, 100}) {
            std::vector<uint8_t> bits(kBitmapBytes, 0);
            for (size_t i = 0; i < total; ++i) {
                if (static_cast<int>(rng() % 100) < d) bitscan::setBit(bits.data(), i);
            }
            for (int t = 0; t < 2000; ++t) {
                size_t a = rng() % (total + 1), b = rng() % (total + 1);
                if (a > b) std::swap(a, b);
                TEST_ASSERT(bitscan::nextSetBit(bits.data(), a, b) ==
                            refNextSet(bits, a, b));
            }
        }
    });
