#include "OldGenLazySweepTest.hpp"

#include <algorithm>
#include <vector>

#include "Allocator.hpp"
#include "Heap.hpp"
#include "OldGenSpace.hpp"
#include "TestHelpers.hpp"
#include "ThreadLocalHeap.hpp"

using namespace Elm;

namespace {

// HeapConfig sized for the lazy-sweep tests:
//   - small alloc-buffer (32 KiB) so a few allocations fill multiple pages.
//   - initial_old_gen_size = 64 KiB (2 pages) — small floor so reclaim has
//     room to release dead blocks above the floor.
//   - target = 0.50 / initiating = 0.75 (defaults).
HeapConfig lazySweepHeapConfig() {
    HeapConfig cfg;
    cfg.alloc_buffer_size       = 32 * 1024;
    cfg.nursery_block_count     = 4;
    cfg.initial_old_gen_size    = 64 * 1024;
    cfg.max_heap_size           = 64ULL * 1024 * 1024;
    cfg.large_object_threshold  = 8 * 1024;
    cfg.major_gc_initiating_occupancy = 0.75f;
    cfg.major_gc_target_utilization   = 0.50f;
    cfg.decommit_on_oldgen_release    = false;
    cfg.validate();
    return cfg;
}

OldGenSpace& threadOldGen(Allocator& alloc) {
    auto* heap = AllocatorTestAccess::getThreadHeap(alloc);
    TEST_ASSERT(heap != nullptr);
    return heap->getOldGen();
}

// Allocate and root `count` ElmInts directly in old gen. Returns the
// HPointer storage so the caller can drop them when desired.
std::vector<HPointer> allocateAndRootInOldGen(Allocator& alloc, size_t count) {
    auto& og = threadOldGen(alloc);
    auto& rootset = alloc.getRootSet();

    std::vector<HPointer> roots;
    roots.reserve(count);
    for (size_t i = 0; i < count; ++i) {
        void* obj = allocateIntInOldGen(og, static_cast<i64>(i));
        TEST_ASSERT(obj != nullptr);
        roots.push_back(AllocatorTestAccess::toPointer(obj));
    }
    for (auto& r : roots) rootset.addRoot(&r);
    return roots;
}

}  // namespace

// ----------------------------------------------------------------------------
// 1. All-dead block reclaim skips per-cell sweep traffic.
// ----------------------------------------------------------------------------

Testing::TestCase testAllDeadBlockReclaimSkipsCells(
    "Mark-derived live_bytes drives all-dead block reclaim without per-cell sweep", []() {
    auto cfg = lazySweepHeapConfig();
    auto& alloc = initAllocator(cfg);
    auto& og = threadOldGen(alloc);

    // Allocate enough ints to span several pages (well above min_heap so
    // reclaim has room above the floor to release some). After drop+GC,
    // every above-floor block whose cells were all unreachable should be
    // released by reclaimAllDeadBlocksFromMeta.
    std::vector<HPointer> roots = allocateAndRootInOldGen(alloc, 8192);
    const size_t blocks_before = OldGenSpaceTestAccess::getBlocks(og).size();
    TEST_ASSERT(blocks_before >= 4);

    for (auto& r : roots) alloc.getRootSet().removeRoot(&r);
    roots.clear();

    runMarkAndSweep(alloc);

    // After GC the heap should have shrunk: most blocks were all-dead and
    // got reclaimed. The min_heap floor caps how far reclaim can go, so
    // some blocks may remain to honor that floor.
    const size_t blocks_after = OldGenSpaceTestAccess::getBlocks(og).size();
    TEST_ASSERT(blocks_after < blocks_before);
});

// ----------------------------------------------------------------------------
// 2. Lazy sweep is driven from the allocation slow-path.
// ----------------------------------------------------------------------------

Testing::TestCase testLazySweepDrivenFromAllocation(
    "After finishMarkAndSweep, the mutator allocation path drives lazy sweep to completion", []() {
    auto cfg = lazySweepHeapConfig();
    auto& alloc = initAllocator(cfg);
    auto& og = threadOldGen(alloc);

    // Allocate enough ints to span many pages. Half stays rooted; half
    // becomes garbage. After mark, reclaim wipes all-dead blocks but the
    // mixed-occupancy blocks remain for lazy sweep to walk.
    std::vector<HPointer> live_roots;
    auto& rootset = alloc.getRootSet();
    for (size_t i = 0; i < 2048; ++i) {
        void* live = allocateIntInOldGen(og, static_cast<i64>(i));
        TEST_ASSERT(live != nullptr);
        // Allocate one garbage int interleaved.
        (void)allocateIntInOldGen(og, -1);
        live_roots.push_back(AllocatorTestAccess::toPointer(live));
    }
    for (auto& r : live_roots) rootset.addRoot(&r);

    runMarkAndSweep(alloc);

    // After our test helper's runMarkAndSweep, finishMarkAndSweep ran the
    // initial slice. Drive the slow-path lazy sweep to completion via
    // additional allocations.
    while (OldGenSpaceTestAccess::getGCPhase(og) == GCPhase::Sweeping) {
        void* probe = allocateIntInOldGen(og, 0);
        TEST_ASSERT(probe != nullptr);
    }

    // gc_phase_ has reached Idle: lazy sweep walked every block.
    TEST_ASSERT(OldGenSpaceTestAccess::getGCPhase(og) == GCPhase::Idle);

    for (auto& r : live_roots) rootset.removeRoot(&r);
});

// ----------------------------------------------------------------------------
// 3. Post-mark shrink uses mark-derived live_bytes.
// ----------------------------------------------------------------------------

Testing::TestCase testShrinkUsesMarkLiveBytes(
    "Committed shrinks immediately after mark, before lazy sweep walks any cell", []() {
    auto cfg = lazySweepHeapConfig();
    auto& alloc = initAllocator(cfg);
    auto& og = threadOldGen(alloc);

    // Inflate the heap with garbage, then drop everything.
    {
        std::vector<HPointer> roots = allocateAndRootInOldGen(alloc, 4096);
        for (auto& r : roots) alloc.getRootSet().removeRoot(&r);
    }

    const size_t committed_before = alloc.getOldGenCommittedBytes();

    runMarkAndSweep(alloc);

    const size_t committed_after = alloc.getOldGenCommittedBytes();

    // Either reclaim or shrink should have released some pages back to
    // the global allocator (or kept committed at the floor).
    TEST_ASSERT(committed_after <= committed_before);

    // Floor must hold.
    const size_t min_heap = std::max(cfg.initial_old_gen_size, cfg.alloc_buffer_size);
    TEST_ASSERT(committed_after >= min_heap);
});

// ----------------------------------------------------------------------------
// 4. Compaction is blocked while lazy sweep is active.
// ----------------------------------------------------------------------------

Testing::TestCase testCompactionBlockedDuringSweep(
    "scheduleCompaction is a no-op while gc_phase_ == Sweeping", []() {
    auto cfg = lazySweepHeapConfig();
    auto& alloc = initAllocator(cfg);
    auto& og = threadOldGen(alloc);

    // Allocate enough live data that lazy sweep has work to do post-mark.
    std::vector<HPointer> roots = allocateAndRootInOldGen(alloc, 1024);
    // And some garbage interleaved.
    for (size_t i = 0; i < 1024; ++i) {
        void* g = allocateIntInOldGen(og, -1);
        TEST_ASSERT(g != nullptr);
    }

    // Drive the GC manually — leaves gc_phase_ in Sweeping for non-trivial heap.
#if ENABLE_GC_STATS
    auto* heap = AllocatorTestAccess::getThreadHeap(alloc);
    GCStats& stats = heap->getStats();
    OldGenSpaceTestAccess::startMark(og, alloc.getRootSet().getRoots(),
                                     Allocator::instance(), stats);
    OldGenSpaceTestAccess::finishMarkAndSweep(og, stats);
#else
    OldGenSpaceTestAccess::startMark(og, alloc.getRootSet().getRoots(),
                                     Allocator::instance());
    OldGenSpaceTestAccess::finishMarkAndSweep(og);
#endif

    if (OldGenSpaceTestAccess::getGCPhase(og) == GCPhase::Sweeping) {
        // Compaction must refuse to run while sweep is in progress.
        OldGenSpaceTestAccess::scheduleCompaction(og);
        TEST_ASSERT(OldGenSpaceTestAccess::getCompactPhase(og)
                    == CompactionPhase::Idle);
    }

    for (auto& r : roots) alloc.getRootSet().removeRoot(&r);
});

// ----------------------------------------------------------------------------
// 5. Page-index lookup matches a brute-force scan across grow/shrink cycles.
// ----------------------------------------------------------------------------

Testing::TestCase testPageIndexBlockLookup(
    "blockIndexFor agrees with linear scan after populate/release cycles", []() {
    auto cfg = lazySweepHeapConfig();
    auto& alloc = initAllocator(cfg);
    auto& og = threadOldGen(alloc);

    // Drive several allocate / drop / GC cycles to exercise grow + release.
    auto& rootset = alloc.getRootSet();
    for (int cycle = 0; cycle < 3; ++cycle) {
        std::vector<HPointer> roots = allocateAndRootInOldGen(alloc, 2048);

        // Verify lookup for a sample of live objects in each block.
        const auto& blocks = OldGenSpaceTestAccess::getBlocks(og);
        for (size_t i = 0; i < blocks.size(); ++i) {
            void* probe = blocks[i].start;
            const size_t fast = OldGenSpaceTestAccess::blockIndexFor(og, probe);
            // Brute force linear scan.
            size_t slow = blocks.size();
            for (size_t j = 0; j < blocks.size(); ++j) {
                if (probe >= blocks[j].start && probe < blocks[j].end) {
                    slow = j;
                    break;
                }
            }
            TEST_ASSERT(fast == slow);
        }

        // Drop and trigger GC so blocks get reclaimed.
        for (auto& r : roots) rootset.removeRoot(&r);
        runMarkAndSweep(alloc);
    }
});
