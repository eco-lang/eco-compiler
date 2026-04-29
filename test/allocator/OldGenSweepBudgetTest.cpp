#include "OldGenSweepBudgetTest.hpp"

#include <vector>

#include "Allocator.hpp"
#include "Heap.hpp"
#include "OldGenSpace.hpp"
#include "TestHelpers.hpp"
#include "ThreadLocalHeap.hpp"

using namespace Elm;

namespace {

// Sized so committedToCapRatio's denominator (max_heap_size / 2) is small
// enough that allocations meaningfully drive the ratio without burning huge
// resources, but large enough that the BBoP fits multiple pages.
HeapConfig sweepBudgetConfig(size_t max_heap_size_bytes) {
    HeapConfig cfg;
    cfg.alloc_buffer_size       = 32 * 1024;
    cfg.nursery_block_count     = 4;
    cfg.initial_old_gen_size    = 64 * 1024;
    cfg.max_heap_size           = max_heap_size_bytes;
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

// Allocates and roots `count` ElmInts in the old gen, returning the roots.
std::vector<HPointer> growOldGen(Allocator& alloc, size_t count) {
    auto& og = threadOldGen(alloc);
    auto& rootset = alloc.getRootSet();
    std::vector<HPointer> roots;
    roots.reserve(count);
    for (size_t i = 0; i < count; ++i) {
        void* obj = allocateIntInOldGen(og, static_cast<i64>(i));
        if (obj == nullptr) break;
        roots.push_back(AllocatorTestAccess::toPointer(obj));
    }
    for (auto& r : roots) rootset.addRoot(&r);
    return roots;
}

}  // namespace

// ----------------------------------------------------------------------------
// Budget grows monotonically as committed/cap pressure rises.
// ----------------------------------------------------------------------------

Testing::TestCase testSweepBudgetMonotonicByPressure(
    "computeSweepBudgetForAlloc grows with committed/cap pressure", []() {
    // 8 MiB max → cap proxy = 4 MiB.
    auto& alloc = initAllocator(sweepBudgetConfig(8ULL * 1024 * 1024));
    auto& og = threadOldGen(alloc);

    constexpr size_t kReq = 256;  // Small alloc — pressure scaling dominates.

    const double r0 = OldGenSpaceTestAccess::committedToCapRatio(og);
    const size_t b0 =
        OldGenSpaceTestAccess::computeSweepBudgetForAlloc(og, kReq);

    // Drive committed up by allocating until pressure exceeds ~0.50.
    auto roots = growOldGen(alloc, 4096);
    const double r1 = OldGenSpaceTestAccess::committedToCapRatio(og);
    const size_t b1 =
        OldGenSpaceTestAccess::computeSweepBudgetForAlloc(og, kReq);

    // More allocations push deeper into the high band.
    auto more = growOldGen(alloc, 4096);
    const double r2 = OldGenSpaceTestAccess::committedToCapRatio(og);
    const size_t b2 =
        OldGenSpaceTestAccess::computeSweepBudgetForAlloc(og, kReq);

    TEST_ASSERT(r0 <= r1);
    TEST_ASSERT(r1 <= r2);
    TEST_ASSERT(b0 <= b1);
    TEST_ASSERT(b1 <= b2);
    TEST_ASSERT(b0 >= SWEEP_WORK_BUDGET);
    TEST_ASSERT(b2 <= MAX_SWEEP_BYTES_HARD);

    auto& rootset = alloc.getRootSet();
    for (auto& r : roots) rootset.removeRoot(&r);
    for (auto& r : more) rootset.removeRoot(&r);
});

// ----------------------------------------------------------------------------
// Unswept-fraction boost: when most blocks are still pending, the budget
// jumps by SWEEP_UNSWEPT_SCALE.
// ----------------------------------------------------------------------------

Testing::TestCase testSweepBudgetUnsweptRatioBoost(
    "computeSweepBudgetForAlloc applies SWEEP_UNSWEPT_SCALE when pending fraction is high", []() {
    auto& alloc = initAllocator(sweepBudgetConfig(8ULL * 1024 * 1024));
    auto& og = threadOldGen(alloc);

    // Build mixed-occupancy heap, then run mark+initial-sweep.
    auto roots = growOldGen(alloc, 2048);
    for (size_t i = 0; i < 2048; ++i) {
        (void)allocateIntInOldGen(og, -1);  // garbage
    }
    runMarkAndSweep(alloc);

    // If the initial slice already drained sweep, the test invariant doesn't
    // apply on this configuration. Skip cleanly.
    if (OldGenSpaceTestAccess::sweepComplete(og)) {
        auto& rs = alloc.getRootSet();
        for (auto& r : roots) rs.removeRoot(&r);
        return;
    }

    const size_t total = OldGenSpaceTestAccess::getSweepTotalBlocks(og);
    const size_t pending =
        OldGenSpaceTestAccess::getSweepPendingBlocks(og);
    TEST_ASSERT(total > 0);
    TEST_ASSERT(pending <= total);

    constexpr size_t kReq = 256;
    const size_t budget_with_pending =
        OldGenSpaceTestAccess::computeSweepBudgetForAlloc(og, kReq);

    // Drive sweep to completion to remove the boost.
    while (!OldGenSpaceTestAccess::sweepComplete(og)) {
        OldGenSpaceTestAccess::lazySweep(og, NUM_SIZE_CLASSES,
                                         /*work_budget=*/4096);
    }
    const size_t budget_after_sweep =
        OldGenSpaceTestAccess::computeSweepBudgetForAlloc(og, kReq);

    // With pending fraction high, budget includes the boost; once sweep is
    // complete (sweep_total_blocks_ == 0), the boost no longer applies.
    if (static_cast<double>(pending) / static_cast<double>(total) >
        SWEEP_UNSWEPT_RATIO_BOOST) {
        TEST_ASSERT(budget_with_pending >= budget_after_sweep);
    }

    auto& rs = alloc.getRootSet();
    for (auto& r : roots) rs.removeRoot(&r);
});

// ----------------------------------------------------------------------------
// Budget never falls below SWEEP_WORK_BUDGET, even for tiny allocations.
// ----------------------------------------------------------------------------

Testing::TestCase testSweepBudgetMinimumIsSweepWorkBudget(
    "computeSweepBudgetForAlloc clamps to >= SWEEP_WORK_BUDGET", []() {
    auto& alloc = initAllocator(sweepBudgetConfig(8ULL * 1024 * 1024));
    auto& og = threadOldGen(alloc);

    // 8 byte requested size — base = 16, far below SWEEP_WORK_BUDGET.
    const size_t b = OldGenSpaceTestAccess::computeSweepBudgetForAlloc(og, 8);
    TEST_ASSERT(b >= SWEEP_WORK_BUDGET);
});

// ----------------------------------------------------------------------------
// Budget is hard-capped at MAX_SWEEP_BYTES_HARD even at full pressure +
// boost + huge requested_size.
// ----------------------------------------------------------------------------

Testing::TestCase testSweepBudgetClampedToHardCap(
    "computeSweepBudgetForAlloc never exceeds MAX_SWEEP_BYTES_HARD", []() {
    auto& alloc = initAllocator(sweepBudgetConfig(8ULL * 1024 * 1024));
    auto& og = threadOldGen(alloc);

    // Request larger than MAX_SWEEP_BYTES_PER_ALLOC * 8 — the base would be
    // huge but is clamped to MAX_SWEEP_BYTES_PER_ALLOC. Pressure scaling +
    // unswept boost cannot push the result above MAX_SWEEP_BYTES_HARD.
    const size_t b = OldGenSpaceTestAccess::computeSweepBudgetForAlloc(
        og, MAX_SWEEP_BYTES_PER_ALLOC * 8);
    TEST_ASSERT(b <= MAX_SWEEP_BYTES_HARD);
});
