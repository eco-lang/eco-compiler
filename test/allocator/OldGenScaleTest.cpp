/**
 * threaded-gc-01 Step 10 (plans/threaded-gc-01-stable-metadata.md P§3.3).
 *
 * The exit criterion of the master plan's phase 1: the old-gen metadata must
 * scale to a multi-TB heap reservation without committing memory up front.
 *
 *  1. OldGenSpace::geometryFor is the arithmetic initialize() uses; check it
 *     at 8 TB with 512 KiB pages.
 *  2. Reserve every table at that geometry and materialize three blocks with
 *     fake extents near 7 TB. Address space is reserved, memory is not.
 *
 * (More than 65,536 live blocks on a REAL heap would need tens of GB of old
 * gen; the BlockTable-level test testBlockTableBeyond65536 covers the id
 * space, and the free-list back-link no longer depends on the block count —
 * HEAP_052, testFreeListBackLinkEncodeRoundTrip.)
 */

#include "OldGenScaleTest.hpp"

#include <cstdint>
#include <cstdio>
#include <fstream>
#include <string>

#include "BlockTable.hpp"
#include "OldGenSpace.hpp"
#include "ReservedArray.hpp"
#include "TestHelpers.hpp"

using namespace Elm;

namespace {
long rssKiB() {
#ifdef __linux__
    std::ifstream f("/proc/self/status");
    std::string line;
    while (std::getline(f, line)) {
        if (line.rfind("VmRSS:", 0) == 0) return std::stol(line.substr(6));
    }
#endif
    return -1;
}
constexpr size_t kTB = size_t{1} << 40;
constexpr size_t kPage = size_t{512} * 1024;
}  // namespace

Testing::TestCase testOldGenGeometryAt8TB(
    "HEAP_048: metadata geometry for an 8 TB reservation at 512 KiB pages",
    []() {
        const auto g = OldGenSpace::geometryFor(8 * kTB, kPage);
        TEST_ASSERT(g.max_blocks == 16777217);          // 2^24 + 1
        TEST_ASSERT(g.index_slots == 16777218);         // 2^24 + 2
        TEST_ASSERT(g.stride == 8192);                  // 512 KiB / 64
        TEST_ASSERT(g.mark_arena_bytes == size_t{16777217} * 8192);
        // Default 24 GiB heap: ~49K ids.
        const auto d = OldGenSpace::geometryFor(24ull << 30, kPage);
        TEST_ASSERT(d.max_blocks == 49153);
        // Smallest page (4 KiB): the stride is still a 64-byte multiple.
        const auto m = OldGenSpace::geometryFor(1ull << 30, 4096);
        TEST_ASSERT(m.stride == 64);
    });

Testing::TestCase testOldGenMetadataReserve8TBIsCheap(
    "HEAP_048: 8 TB metadata costs address space and < 16 MiB of memory",
    []() {
#ifdef __linux__
        const auto g = OldGenSpace::geometryFor(8 * kTB, kPage);
        const long rss0 = rssKiB();
        {
            BlockTable table;
            MarkBitArena arena;
            LiveBytesAccumulator acc;
            ReservedArray<uint64_t> index;
            if (!table.reserve(g.max_blocks) ||
                !arena.reserve(g.max_blocks, g.stride) ||
                !acc.reserve(g.max_blocks) || !index.reserve(g.index_slots)) {
                std::printf("  SKIP: VA reservation refused (restricted VA)\n");
                return;
            }
            for (uint64_t k = 0; k < 3; ++k) {
                BlockInfo bi{};
                bi.start = reinterpret_cast<char*>(7 * kTB + k * kPage);
                bi.end = bi.start + kPage;
                bi.end_of_objects = bi.end;
                bi.size_class = 0;
                bi.is_large = false;
                const BlockId id = table.add(bi, BufferMetadata{0, 0, false});
                arena.assign(id, static_cast<uint32_t>(g.stride));
                acc.commitThrough(id);
                acc.add(id, 64);
                arena.slot(id)[17] |= 0x4;
                // The page slot of a block at 7 TB is far from 0: the index
                // commits a prefix through it (8 B per slot, 14 Mi slots ->
                // 112 MiB of index VA committed but untouched except here).
                const size_t slot = (7 * kTB + k * kPage) / kPage;
                index.ensureCommitted(slot + 1);
                index[slot] = id.v + 1;
            }
            acc.mergeInto(table);
            TEST_ASSERT(table.meta(table.idAt(2)).live_bytes == 64);
            const long rss1 = rssKiB();
            std::printf("  8 TB metadata: RSS +%ld KiB\n", rss1 - rss0);
            TEST_ASSERT(rss1 - rss0 < 16 * 1024);
        }
#else
        std::printf("  SKIP: RSS check is Linux-only\n");
#endif
    });
