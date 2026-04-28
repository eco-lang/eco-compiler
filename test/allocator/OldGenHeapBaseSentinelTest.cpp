#include "OldGenHeapBaseSentinelTest.hpp"

#include <cstring>
#include <vector>

#include "Allocator.hpp"
#include "Heap.hpp"
#include "OldGenSpace.hpp"
#include "TestHelpers.hpp"
#include "ThreadLocalHeap.hpp"

using namespace Elm;

namespace {

// HeapConfig matching the capacity tests' shape: a small heap whose first
// page sits at heap_base, so we can drain the bag and force the heap-base
// page to materialize within one test.
HeapConfig sentinelHeapConfig() {
    HeapConfig cfg;
    cfg.alloc_buffer_size       = 64 * 1024;
    cfg.nursery_block_count     = 4;
    cfg.initial_old_gen_size    = 256 * 1024;        // 4 pages.
    cfg.max_heap_size           = 64ULL * 1024 * 1024;
    cfg.large_object_threshold  = 64 * 1024;
    cfg.major_gc_initiating_occupancy = 0.75f;
    cfg.major_gc_target_utilization   = 0.50f;
    cfg.decommit_on_oldgen_release    = true;
    cfg.validate();
    return cfg;
}

OldGenSpace& getOldGen(Allocator& alloc) {
    auto* heap = AllocatorTestAccess::getThreadHeap(alloc);
    TEST_ASSERT(heap != nullptr);
    return heap->getOldGen();
}

}  // namespace

// 1. Every entry in unassigned_blocks_ post-initialize is exactly one full
//    page. This was the regression: pre-fix, page 0 had width
//    alloc_buffer_size - 8.
Testing::TestCase testInitialUnassignedBlocksAreFullPages(
    "Initial unassigned bag pages are all exactly alloc_buffer_size bytes",
    []() {
    auto cfg = sentinelHeapConfig();
    auto& alloc = initAllocator(cfg);
    auto& og = getOldGen(alloc);

    const auto& bag = OldGenSpaceTestAccess::getUnassignedBlocks(og);
    TEST_ASSERT(!bag.empty());
    for (const auto& extent : bag) {
        const size_t bytes =
            static_cast<size_t>(extent.second - extent.first);
        TEST_ASSERT(bytes == cfg.alloc_buffer_size);
    }
});

// 2. Stress-allocate enough to consume the heap-base page, and assert no
//    allocation hands out heap_base. The defense in initObjectHeaderWithSize
//    would also catch this, but we want a positive test that the sentinel
//    discipline keeps the address out of circulation.
Testing::TestCase testNoAllocationLandsAtHeapBase(
    "No old-gen allocation returns heap_base + 0", []() {
    auto cfg = sentinelHeapConfig();
    auto& alloc = initAllocator(cfg);
    auto& og = getOldGen(alloc);

    char* heap_base = AllocatorTestAccess::getHeapBase(alloc);

    // Drain a few full pages worth of small allocations. With 4 pages and
    // ~24-byte ElmInts, this is plenty to exercise multiple page pulls
    // including the heap-base page (LIFO drain orders it last).
    constexpr size_t COUNT = 4 * 1024;
    for (size_t i = 0; i < COUNT; ++i) {
        void* obj = allocateIntInOldGen(og, static_cast<i64>(i));
        if (!obj) break;
        TEST_ASSERT(reinterpret_cast<char*>(obj) != heap_base);
    }
});

// 3. Driving release cycles must keep old_gen_committed page-aligned. Pre-fix,
//    a heap-base block release would subtract (alloc_buffer_size - 8) bytes
//    and leave the committed counter misaligned.
Testing::TestCase testReleaseLeavesCommittedPageAligned(
    "Old-gen committed bytes stay page-aligned after release cycles", []() {
    auto cfg = sentinelHeapConfig();
    auto& alloc = initAllocator(cfg);

    // Allocate then drop. promoteToOldGen + majorGC drives the
    // release-from-meta path that subtracts block bytes from old_gen_committed.
    std::vector<i64> values(8);
    for (size_t i = 0; i < values.size(); ++i) values[i] = static_cast<i64>(i);
    auto rooted = createRootedIntsWithValues(alloc, values);
    rooted.registerRoots(alloc);
    promoteToOldGen(alloc);
    rooted.unregisterRoots(alloc);

    alloc.majorGC();
    alloc.majorGC();

    const size_t committed = alloc.getOldGenCommittedBytes();
    TEST_ASSERT(committed % cfg.alloc_buffer_size == 0);
});

// 4. Force the heap-base page to materialize, drive a major GC where it
//    becomes fully dead, and assert the block stays in blocks_ (the
//    permanent-pin guard in releaseBlockToAllocator must skip it).
Testing::TestCase testHeapBaseBlockNotReleasedOnAllDeadReclaim(
    "Heap-base block is never released even when its live_bytes goes to zero",
    []() {
    auto cfg = sentinelHeapConfig();
    auto& alloc = initAllocator(cfg);
    auto& og = getOldGen(alloc);

    char* heap_base = AllocatorTestAccess::getHeapBase(alloc);

    // Drain enough small allocations that the heap-base page is forced to
    // materialize (LIFO order means it goes last). We keep none of the
    // allocations rooted, so a subsequent major GC will see them all dead.
    constexpr size_t COUNT = 8 * 1024;
    for (size_t i = 0; i < COUNT; ++i) {
        if (allocateIntInOldGen(og, static_cast<i64>(i)) == nullptr) break;
    }

    alloc.majorGC();
    alloc.majorGC();

    // After the GCs, scan blocks_ for one starting at heap_base. The
    // heap-base block should still be there even if all its content died,
    // because releaseBlockToAllocator's guard prevents its release.
    bool found_heap_base_block = false;
    const auto& blocks = OldGenSpaceTestAccess::getBlocks(og);
    for (const auto& blk : blocks) {
        if (blk.start == heap_base) {
            found_heap_base_block = true;
            break;
        }
    }
    // The block may legitimately not be in blocks_ yet if the bag was
    // never fully drained — only assert the *invariant* (if the block was
    // ever materialized, it stays). Detect "never materialized" by checking
    // the bag still owns the heap-base extent.
    bool heap_base_in_bag = false;
    const auto& bag = OldGenSpaceTestAccess::getUnassignedBlocks(og);
    for (const auto& extent : bag) {
        if (extent.first == heap_base) {
            heap_base_in_bag = true;
            break;
        }
    }
    TEST_ASSERT(found_heap_base_block || heap_base_in_bag);

    // If the block was materialized, walk its first 8 bytes and confirm
    // the sentinel header is present (Tag_Free, size = 8, pin = 1).
    if (found_heap_base_block) {
        Header* hdr = reinterpret_cast<Header*>(heap_base);
        TEST_ASSERT(hdr->tag == Tag_Free);
        TEST_ASSERT(hdr->size == HEAP_BASE_SENTINEL_SIZE);
        TEST_ASSERT(hdr->pin == 1);
    }
});
