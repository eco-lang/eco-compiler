#include "OldGenSmallClassBudgetTest.hpp"

#include <vector>

#include "Allocator.hpp"
#include "Heap.hpp"
#include "OldGenSpace.hpp"
#include "TestHelpers.hpp"
#include "ThreadLocalHeap.hpp"

using namespace Elm;

namespace {

// Modest pages so a small budget covers only a handful, but each page is
// big enough to host many size-class cells; large_object_threshold defaults
// from alloc_buffer_size so the size-class fast path is exercised.
HeapConfig smallClassBudgetConfig(size_t budget_bytes,
                                  size_t cell_max_bytes = 8 * 1024) {
    HeapConfig cfg;
    cfg.alloc_buffer_size       = 32 * 1024;
    cfg.nursery_block_count     = 4;
    cfg.initial_old_gen_size    = 256 * 1024;
    cfg.max_heap_size           = 64ULL * 1024 * 1024;
    cfg.large_object_threshold  = 8 * 1024;
    cfg.major_gc_initiating_occupancy = 0.75f;
    cfg.major_gc_target_utilization   = 0.50f;
    cfg.decommit_on_oldgen_release    = false;
    cfg.small_class_heap_budget_bytes = budget_bytes;
    cfg.small_class_cell_max_bytes    = cell_max_bytes;
    cfg.validate();
    return cfg;
}

OldGenSpace& threadOldGen(Allocator& alloc) {
    auto* heap = AllocatorTestAccess::getThreadHeap(alloc);
    TEST_ASSERT(heap != nullptr);
    return heap->getOldGen();
}

// Counts blocks in `blocks_` whose size_class equals `cls`. Excludes
// is_large blocks and mixed blocks (size_class == NUM_SIZE_CLASSES).
size_t countBlocksOfClass(const OldGenSpace& og, size_t cls) {
    const auto& blocks = OldGenSpaceTestAccess::getBlocks(og);
    size_t n = 0;
    for (const auto& blk : blocks) {
        if (!blk.is_large && blk.size_class == cls) ++n;
    }
    return n;
}

}  // namespace

// ----------------------------------------------------------------------------
// 1. Budget under cap: small-class allocations pull fresh uniform pages
//    instead of splitting larger free cells.
// ----------------------------------------------------------------------------

Testing::TestCase testSmallClassBudgetUnderCapPullsFreshPages(
    "Under the small-class budget, allocations pull fresh uniform pages", []() {
    constexpr size_t kPage = 32 * 1024;
    auto& alloc = initAllocator(smallClassBudgetConfig(/*budget=*/4 * kPage));
    auto& og = threadOldGen(alloc);

    constexpr size_t kAllocSize = sizeof(ElmInt);  // small class
    const size_t cls = OldGenSpaceTestAccess::sizeClass(kAllocSize);
    TEST_ASSERT(OldGenSpaceTestAccess::shouldPreferBagForSmallClass(og, cls));

    // The very first allocation forces a uniform page for `cls`. After
    // that, the per-class free list should drain monotonically until we
    // fall through to a fresh page.
    size_t pages_before = countBlocksOfClass(og, cls);
    size_t pages_observed = 0;
    for (size_t i = 0; i < 4; ++i) {
        size_t prev = countBlocksOfClass(og, cls);
        // Drain whatever the current page provides, plus one more to force
        // the next page pull. We don't know exact cell counts here without
        // duplicating math, so allocate generously and look for the page
        // count to grow at least once.
        for (size_t j = 0; j < 8 * 1024; ++j) {
            void* obj = allocateIntInOldGen(og, static_cast<i64>(j));
            TEST_ASSERT(obj != nullptr);
            const size_t now = countBlocksOfClass(og, cls);
            if (now > prev) {
                pages_observed += (now - prev);
                prev = now;
                break;
            }
        }
    }

    // We saw the budget bag-first policy materialise at least a couple of
    // fresh uniform pages while the budget was open.
    TEST_ASSERT(pages_observed >= 2);
    TEST_ASSERT(countBlocksOfClass(og, cls) > pages_before);
});

// ----------------------------------------------------------------------------
// 2. Budget exhausted: once small_class_bytes_ >= budget, the heuristic
//    stops preferring bag pages.
// ----------------------------------------------------------------------------

Testing::TestCase testSmallClassBudgetExhaustedResumesSplitting(
    "Budget exhaustion stops bag-first preference", []() {
    constexpr size_t kPage = 32 * 1024;
    auto& alloc = initAllocator(smallClassBudgetConfig(/*budget=*/2 * kPage));
    auto& og = threadOldGen(alloc);

    constexpr size_t kAllocSize = sizeof(ElmInt);
    const size_t cls = OldGenSpaceTestAccess::sizeClass(kAllocSize);
    TEST_ASSERT(OldGenSpaceTestAccess::shouldPreferBagForSmallClass(og, cls));

    // Allocate enough to drive small_class_bytes_ to or above the budget.
    for (size_t i = 0; i < 16 * 1024; ++i) {
        void* obj = allocateIntInOldGen(og, static_cast<i64>(i));
        TEST_ASSERT(obj != nullptr);
        if (!OldGenSpaceTestAccess::shouldPreferBagForSmallClass(og, cls)) {
            break;
        }
    }

    TEST_ASSERT(!OldGenSpaceTestAccess::shouldPreferBagForSmallClass(og, cls));
    const size_t budget = 2 * kPage;
    TEST_ASSERT(OldGenSpaceTestAccess::getSmallClassBytes(og) >= budget);
});

// ----------------------------------------------------------------------------
// 3. Above-cap classes are unaffected.
// ----------------------------------------------------------------------------

Testing::TestCase testSmallClassAboveCapClassesUnaffected(
    "Classes above small_class_cell_max_bytes are not budgeted", []() {
    // cell_max=16: only classes cls=0 (cellSize=8) and cls=1 (cellSize=16)
    // qualify as small. Allocations in cls >= 2 (cellSize >= 24) are
    // unaffected by the budget.
    auto& alloc =
        initAllocator(smallClassBudgetConfig(/*budget=*/256 * 1024,
                                             /*cell_max=*/16));
    auto& og = threadOldGen(alloc);

    TEST_ASSERT(OldGenSpaceTestAccess::shouldPreferBagForSmallClass(og, 0));
    TEST_ASSERT(OldGenSpaceTestAccess::shouldPreferBagForSmallClass(og, 1));
    TEST_ASSERT(!OldGenSpaceTestAccess::shouldPreferBagForSmallClass(og, 2));
    TEST_ASSERT(OldGenSpaceTestAccess::getSmallClassIndexLimit(og) == 2);

    // Allocate Tuple3-sized objects (40 B → cls=4, cellSize=40). cls=4 is
    // above the budget cap, so populateFromBlock for this class must not
    // bump small_class_bytes_.
    const size_t before = OldGenSpaceTestAccess::getSmallClassBytes(og);
    for (size_t i = 0; i < 1024; ++i) {
        void* obj = og.allocate(40);
        TEST_ASSERT(obj != nullptr);
        Header* hdr = reinterpret_cast<Header*>(obj);
        hdr->tag = Tag_Tuple3;
    }
    TEST_ASSERT(OldGenSpaceTestAccess::getSmallClassBytes(og) == before);
});

// ----------------------------------------------------------------------------
// 4. Heuristic disabled (budget = 0).
// ----------------------------------------------------------------------------

Testing::TestCase testSmallClassBudgetDisabledMatchesLegacy(
    "small_class_heap_budget_bytes=0 disables the heuristic", []() {
    auto& alloc = initAllocator(smallClassBudgetConfig(/*budget=*/0));
    auto& og = threadOldGen(alloc);

    TEST_ASSERT(OldGenSpaceTestAccess::getSmallClassIndexLimit(og) == 0);

    // No class is small; the predicate returns false everywhere.
    for (size_t cls = 0; cls < NUM_SIZE_CLASSES; ++cls) {
        TEST_ASSERT(!OldGenSpaceTestAccess::shouldPreferBagForSmallClass(og,
                                                                          cls));
    }

    // small_class_bytes_ never increments even after many allocations.
    for (size_t i = 0; i < 4096; ++i) {
        void* obj = allocateIntInOldGen(og, static_cast<i64>(i));
        TEST_ASSERT(obj != nullptr);
    }
    TEST_ASSERT(OldGenSpaceTestAccess::getSmallClassBytes(og) == 0);
});

// ----------------------------------------------------------------------------
// 5. Release accounting: post-major-GC reclaim debits small_class_bytes_.
// ----------------------------------------------------------------------------

Testing::TestCase testSmallClassBudgetDebitsOnRelease(
    "Block release debits small_class_bytes_", []() {
    constexpr size_t kPage = 32 * 1024;
    // Tighter initial heap (one page) so the reclaim floor doesn't keep
    // every dedicated small-class page after major GC. With initial=1 page,
    // post-GC reclaim can release any extra pages dedicated to size classes.
    HeapConfig cfg;
    cfg.alloc_buffer_size       = kPage;
    cfg.nursery_block_count     = 4;
    cfg.initial_old_gen_size    = kPage;          // floor = 1 page.
    cfg.max_heap_size           = 64ULL * 1024 * 1024;
    cfg.large_object_threshold  = 8 * 1024;
    cfg.major_gc_initiating_occupancy = 0.75f;
    cfg.major_gc_target_utilization   = 0.50f;
    cfg.decommit_on_oldgen_release    = false;
    cfg.small_class_heap_budget_bytes = 8 * kPage;
    cfg.small_class_cell_max_bytes    = 8 * 1024;
    cfg.validate();
    auto& alloc = initAllocator(cfg);
    auto& og = threadOldGen(alloc);

    // Allocate enough unrooted ints to dedicate several small-class pages
    // beyond the floor.
    for (size_t i = 0; i < 8 * 1024; ++i) {
        void* obj = allocateIntInOldGen(og, static_cast<i64>(i));
        TEST_ASSERT(obj != nullptr);
    }

    const size_t before = OldGenSpaceTestAccess::getSmallClassBytes(og);
    TEST_ASSERT(before > 0);

    runMarkAndSweep(alloc);

    // After mark+initial-sweep, all-dead reclaim has run; some uniform
    // small-class pages are released and their bytes drop from
    // small_class_bytes_.
    const size_t after = OldGenSpaceTestAccess::getSmallClassBytes(og);
    TEST_ASSERT(after < before);
});

// ----------------------------------------------------------------------------
// 6. small_class_bytes_ accounting: only uniform small-class blocks are
//    credited; mixed and non-small blocks contribute zero. (The heap-base
//    page is now an ordinary page — the former heap-base sentinel/mixed-block
//    detour was removed once HPointers became absolute addresses, D5.)
// ----------------------------------------------------------------------------

Testing::TestCase testSmallClassBudgetIgnoresHeapBasePage(
    "small_class_bytes only credits uniform small-class blocks", []() {
    auto& alloc = initAllocator(smallClassBudgetConfig(/*budget=*/256 * 1024));
    auto& og = threadOldGen(alloc);

    // Drive several small-class allocations. With the budget open,
    // populateFromBlock materialises uniform small-class pages.
    for (size_t i = 0; i < 64; ++i) {
        void* obj = allocateIntInOldGen(og, static_cast<i64>(i));
        TEST_ASSERT(obj != nullptr);
    }

    // Walk blocks_ and confirm: every credited byte corresponds to a uniform
    // small-class page; mixed blocks contribute zero.
    const auto& blocks = OldGenSpaceTestAccess::getBlocks(og);
    const size_t limit = OldGenSpaceTestAccess::getSmallClassIndexLimit(og);
    size_t expected = 0;
    bool saw_mixed = false;
    for (const auto& blk : blocks) {
        if (blk.is_large) continue;
        if (blk.size_class >= limit) {
            // Includes both NUM_SIZE_CLASSES (mixed) and any non-small class.
            if (blk.size_class >= NUM_SIZE_CLASSES) saw_mixed = true;
            continue;
        }
        expected += blk.totalBytes();
    }
    TEST_ASSERT(OldGenSpaceTestAccess::getSmallClassBytes(og) == expected);
    // The heap-base page is always materialised as mixed when first hit;
    // if our 64 allocations crossed it, this assert proves we excluded it.
    // (When the heap-base page is never touched in such a small workload,
    // saw_mixed may legitimately be false; the equality above is the real
    // invariant.)
    (void)saw_mixed;
});
