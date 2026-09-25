/**
 * threaded-gc-01 (plans/threaded-gc-01-stable-metadata.md) Steps 3 and 4:
 *
 *  - ReservedArray<T>: VA-reserved, committed on demand, and its data pointer
 *    NEVER changes (HEAP_048). Fresh elements read zero; discard() zeroes.
 *  - BlockTable: a stable BlockId per block, plus an iteration ORDER whose
 *    semantics equal the former std::vector<BlockInfo> exactly (push_back,
 *    swap-remove, order-preserving erase). The order-equivalence test is the
 *    key one: it is what keeps GC counters bit-identical across the change.
 */

#include "ReservedArrayTest.hpp"

#include <array>
#include <cstdint>
#include <cstdio>
#include <cstring>
#include <fstream>
#include <random>
#include <string>
#include <vector>

#include "BlockTable.hpp"
#include "ReservedArray.hpp"
#include "TestHelpers.hpp"

using namespace Elm;

namespace {

// Resident set size of this process in KiB (Linux), or -1 elsewhere.
long rssKiB() {
#ifdef __linux__
    std::ifstream f("/proc/self/status");
    std::string line;
    while (std::getline(f, line)) {
        if (line.rfind("VmRSS:", 0) == 0) {
            return std::stol(line.substr(6));
        }
    }
#endif
    return -1;
}

BlockInfo fakeInfo(uint64_t serial) {
    BlockInfo bi{};
    bi.start = reinterpret_cast<char*>(static_cast<uintptr_t>(serial << 20));
    bi.end = bi.start + 4096;
    bi.end_of_objects = bi.end;
    bi.size_class = 0;
    bi.is_large = false;
    return bi;
}

}  // namespace

Testing::TestCase testReservedArrayStableAndZeroed(
    "HEAP_048: ReservedArray data() never moves across growth; new elements are zero",
    []() {
        ReservedArray<uint64_t> a;
        TEST_ASSERT(a.reserve(1u << 20));
        const uint64_t* base = a.data();
        for (size_t n = 1; n <= 1000; ++n) {
            a.ensureCommitted(n * 97);
            TEST_ASSERT(a.data() == base);
            TEST_ASSERT(a[n * 97 - 1] == 0);
            a[n * 97 - 1] = n;
        }
        for (size_t n = 1; n <= 1000; ++n) TEST_ASSERT(a[n * 97 - 1] == n);
    });

Testing::TestCase testReservedArrayDiscardZeroes(
    "ReservedArray::discard zeroes a page-straddling range and keeps neighbours",
    []() {
        ReservedArray<uint8_t> a;
        TEST_ASSERT(a.reserve(64 * 4096));
        a.ensureCommitted(64 * 4096);
        std::memset(a.data(), 0xAB, 64 * 4096);
        const size_t first = 4096 + 100, count = 5 * 4096 + 7;
        a.discard(first, count);
        for (size_t i = 0; i < 64 * 4096; ++i) {
            const bool inside = i >= first && i < first + count;
            TEST_ASSERT(a[i] == (inside ? 0 : 0xAB));
        }
        a[first] = 1;  // still writable
        TEST_ASSERT(a[first] == 1);
    });

Testing::TestCase testReservedArrayHugeGranule(
    "ReservedArray huge granule: 2 MiB-aligned base; discard keeps partial huge pages",
    []() {
        constexpr size_t kHuge = ReservedArray<uint8_t>::kHugePageBytes;
        ReservedArray<uint8_t> a;
        TEST_ASSERT(a.reserve(8 * kHuge, kHuge));
        TEST_ASSERT((reinterpret_cast<uintptr_t>(a.data()) & (kHuge - 1)) == 0);
        a.ensureCommitted(1);
        TEST_ASSERT(a.committed() == kHuge);    // whole granules only
        a.ensureCommitted(3 * kHuge + 5);
        TEST_ASSERT(a.committed() == 4 * kHuge);
        std::memset(a.data(), 0x5A, 4 * kHuge);
        a.discard(kHuge / 2, 2 * kHuge);        // covers exactly one whole granule
        for (size_t i = 0; i < 4 * kHuge; i += 4096) {
            const bool inside = i >= kHuge / 2 && i < kHuge / 2 + 2 * kHuge;
            TEST_ASSERT(a[i] == (inside ? 0 : 0x5A));
        }
    });

Testing::TestCase testReservedArrayScaleReserveIsCheap(
    "HEAP_048: 8 TB-scale metadata reservations cost address space, not memory",
    []() {
#ifdef __linux__
        const long rss0 = rssKiB();
        {
            ReservedArray<uint8_t> arena;                    // 8 TB / 64
            ReservedArray<std::array<uint8_t, 80>> table;    // 16.8 M ids
            if (!arena.reserve(size_t{1} << 37) ||
                !table.reserve(16777217)) {
                std::printf("  SKIP: VA reservation refused (restricted VA)\n");
                return;
            }
            // Ids are handed out densely from 0 (BlockTable LIFO reuse), so
            // storage is committed as a PREFIX: only the used ids cost
            // memory. Touch three blocks' worth (8 KiB mark slot, 80 B row).
            arena.ensureCommitted(3 * 8192);
            for (size_t i = 0; i < 3 * 8192; i += 4096) arena[i] = 1;
            table.ensureCommitted(3);
            table[0][0] = 1;
            table[1][0] = 1;
            table[2][0] = 1;
            const long rss1 = rssKiB();
            TEST_ASSERT(rss1 - rss0 < 16 * 1024);
        }
#else
        std::printf("  SKIP: RSS check is Linux-only\n");
#endif
    });

Testing::TestCase testBlockTableOrderMatchesVectorModel(
    "HEAP_048: BlockTable order == std::vector push/swap-remove/erase order (200k random ops)",
    []() {
        BlockTable t;
        TEST_ASSERT(t.reserve(1 << 16));
        std::vector<uint64_t> model;   // serials, in vector order
        std::mt19937_64 rng(0x7C01);
        uint64_t next_serial = 1;
        for (int op = 0; op < 200000; ++op) {
            const unsigned r = static_cast<unsigned>(rng() % 100);
            if (model.empty() || (r < 55 && model.size() + 1 < t.capacity())) {
                const uint64_t s = next_serial++;
                t.add(fakeInfo(s), BufferMetadata{s, 0, false});
                model.push_back(s);
            } else {
                const size_t pos = static_cast<size_t>(rng() % model.size());
                const BlockId id = t.idAt(pos);
                if (r < 95) {
                    // vector swap-remove, as releaseBlockToAllocator did
                    model[pos] = model.back();
                    model.pop_back();
                    t.swapRemove(id);
                } else {
                    model.erase(model.begin() + static_cast<long>(pos));
                    t.eraseOrdered(id);
                }
                TEST_ASSERT(!t.isLive(id));
            }
            TEST_ASSERT(t.size() == model.size());
            if ((op & 1023) == 0 || op == 199999) {
                for (size_t p = 0; p < model.size(); ++p) {
                    const BlockId id = t.idAt(p);
                    TEST_ASSERT(t.isLive(id));
                    TEST_ASSERT(t.posOf(id) == p);
                    TEST_ASSERT(t.meta(id).live_bytes == model[p]);
                    TEST_ASSERT(t.info(id).start ==
                                fakeInfo(model[p]).start);
                }
                TEST_ASSERT(t.size() + t.freeCount() == t.highWater());
            }
        }
    });

Testing::TestCase testBlockTableIdsStable(
    "HEAP_048: a live block's id and metadata address never change",
    []() {
        BlockTable t;
        TEST_ASSERT(t.reserve(4096));
        std::vector<BlockId> ids;
        std::vector<const BlockInfo*> addrs;
        for (uint64_t s = 1; s <= 1000; ++s) {
            ids.push_back(t.add(fakeInfo(s), BufferMetadata{s, 0, false}));
            addrs.push_back(&t.info(ids.back()));
        }
        // Remove every third block (swap-remove moves positions, not ids).
        for (size_t k = 0; k < ids.size(); k += 3) t.swapRemove(ids[k]);
        for (size_t k = 0; k < ids.size(); ++k) {
            if (k % 3 == 0) continue;
            TEST_ASSERT(t.isLive(ids[k]));
            TEST_ASSERT(&t.info(ids[k]) == addrs[k]);
            TEST_ASSERT(t.meta(ids[k]).live_bytes == k + 1);
            TEST_ASSERT(t.idAt(t.posOf(ids[k])) == ids[k]);
        }
        // Freed ids are reused LIFO.
        const BlockId reused = t.add(fakeInfo(5000), BufferMetadata{5000, 0, false});
        TEST_ASSERT(reused == ids[999 - (999 % 3)]);
    });

Testing::TestCase testBlockTableBeyond65536(
    "HEAP_048: more than 65,536 simultaneously live block ids",
    []() {
        BlockTable t;
        TEST_ASSERT(t.reserve(70000));
        for (uint64_t s = 0; s < 70000; ++s) {
            const BlockId id = t.add(fakeInfo(s + 1), BufferMetadata{s, 0, false});
            TEST_ASSERT(id.v == s);
        }
        TEST_ASSERT(t.size() == 70000);
        TEST_ASSERT(t.meta(BlockId{69999}).live_bytes == 69999);
        TEST_ASSERT(t.meta(t.idAt(65536)).live_bytes == 65536);
    });

Testing::TestCase testBlockTableClearRestartsIds(
    "BlockTable::clear resets the high-water mark; the next id is 0",
    []() {
        BlockTable t;
        TEST_ASSERT(t.reserve(64));
        for (uint64_t s = 1; s <= 10; ++s) t.add(fakeInfo(s), BufferMetadata{s, 0, false});
        t.swapRemove(BlockId{3});
        t.clear();
        TEST_ASSERT(t.size() == 0 && t.highWater() == 0 && t.freeCount() == 0);
        TEST_ASSERT(!t.isLive(BlockId{0}));
        TEST_ASSERT(t.add(fakeInfo(1), BufferMetadata{1, 0, false}).v == 0);
    });
