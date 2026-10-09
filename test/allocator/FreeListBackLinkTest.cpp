/**
 * threaded-gc-01 Step 2 (plans/threaded-gc-01-stable-metadata.md P§3.7,
 * HEAP_052): a Tier-M free cell's class-list back-link is its predecessor's
 * ADDRESS >> 3 in 40 bits (32 in FreeCellMid::prev_lo, 8 in the cell's own
 * Header.refcount), with refcount bit 8 marking the list head. This replaced
 * the {16-bit block index, offset} CellHandle, which capped Tier-M threading
 * at 65,535 blocks.
 */

#include "FreeListBackLinkTest.hpp"

#include <cstdint>
#include <cstring>
#include <vector>

#include "Allocator.hpp"
#include "Heap.hpp"
#include "OldGenSpace.hpp"
#include "TestHelpers.hpp"
#include "ThreadLocalHeap.hpp"

using namespace Elm;
using namespace Elm::TestHelpers;

Testing::TestCase testFreeListBackLinkEncodeRoundTrip(
    "HEAP_052: back-link encode/decode round-trips across the 2^43 address range",
    []() {
        // Encoding is pure arithmetic on the address; the cell we write into
        // is a local buffer, the "predecessor" addresses are never
        // dereferenced.
        alignas(8) unsigned char buf[sizeof(FreeCellMid)];
        std::memset(buf, 0, sizeof(buf));
        FreeCellMid* m = reinterpret_cast<FreeCellMid*>(buf);
        m->header.tag = Tag_Free;
        m->header.size = 24;
        m->header.age = 1;  // on-free-list sentinel bit must survive

        const uint64_t probes[] = {
            0x8ull,
            (1ull << 35) - 8,    // top of the low-32-bit window
            (1ull << 35),        // first address needing a high byte
            (1ull << 42) + 0x1238,
            (1ull << 43) - 24,   // last 24-B cell below the 8 TB limit
        };
        for (uint64_t a : probes) {
            const FreeCell* pred = reinterpret_cast<const FreeCell*>(
                static_cast<uintptr_t>(a));
            setPrev(m, pred);
            TEST_ASSERT(getPrev(m) == pred);
            TEST_ASSERT(m->header.tag == Tag_Free);
            TEST_ASSERT(m->header.size == 24);
            TEST_ASSERT(m->header.age == 1);

            alignas(8) unsigned char buf2[sizeof(FreeCellMid)];
            std::memset(buf2, 0, sizeof(buf2));
            FreeCellMid* d = reinterpret_cast<FreeCellMid*>(buf2);
            copyPrev(d, m);
            TEST_ASSERT(getPrev(d) == pred);
        }
        setPrevHead(m);
        TEST_ASSERT(getPrev(m) == nullptr);
        TEST_ASSERT(m->header.age == 1);
    });

Testing::TestCase testFreeListBackLinksConsistentAfterChurn(
    "HEAP_052: back-links match the actual class-list order after pop/split/sweep churn",
    []() {
        HeapConfig cfg;
        cfg.alloc_buffer_size       = 32 * 1024;
        cfg.nursery_block_count     = 4;
        cfg.nursery_max_block_count = cfg.nursery_block_count;   // a region heap slot fits (plans/region-nursery-everywhere.md)
        cfg.initial_old_gen_size    = 256 * 1024;
        cfg.max_heap_size           = 64ULL * 1024 * 1024;
        cfg.large_object_threshold  = 8 * 1024;
        cfg.decommit_on_oldgen_release = false;
        cfg.validate();
        auto& alloc = initAllocator(cfg);
        auto* heap = AllocatorTestAccess::getThreadHeap(alloc);
        TEST_ASSERT(heap != nullptr);
        OldGenSpace& og = heap->getOldGen();

        // Mixed sizes (Tier-S 16 B and several Tier-M classes), half rooted.
        std::vector<HPointer> roots;
        roots.reserve(4096);
        for (size_t i = 0; i < 8192; ++i) {
            const size_t words = 2 + (i % 7);  // 16..64 B objects
            void* obj = og.allocate(words * 8);
            TEST_ASSERT(obj != nullptr);
            Header* h = reinterpret_cast<Header*>(obj);
            h->tag = Tag_Int;
            h->size = 0;
            // Only ElmInt-shaped objects are safe to root; keep 16-B ones.
            if (words == 2 && (i & 1) == 0) {
                ElmInt* e = reinterpret_cast<ElmInt*>(obj);
                e->value = static_cast<i64>(i);
                roots.push_back(AllocatorTestAccess::toPointer(obj));
            }
        }
        for (auto& r : roots) alloc.getRootSet().addRoot(&r);
        runMarkAndSweep(alloc);
        // Drive the lazy sweep to completion and pop cells back off the lists.
        for (size_t i = 0; i < 4096; ++i) {
            TEST_ASSERT(og.allocate((2 + (i % 5)) * 8) != nullptr);
        }
        TEST_ASSERT(OldGenSpaceTestAccess::freeListBackLinksConsistent(og));
        for (auto& r : roots) alloc.getRootSet().removeRoot(&r);
    });
