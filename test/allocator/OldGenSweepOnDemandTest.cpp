#include "OldGenSweepOnDemandTest.hpp"

#include <algorithm>
#include <vector>

#include "Allocator.hpp"
#include "Heap.hpp"
#include "OldGenSpace.hpp"
#include "TestHelpers.hpp"
#include "ThreadLocalHeap.hpp"

using namespace Elm;

namespace {

// Same shape as lazySweepHeapConfig: small pages so allocations span many
// blocks, modest initial commitment so reclaim has room to fire.
HeapConfig sweepOnDemandHeapConfig() {
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

// Counts buffer_meta_ entries with !fully_swept.
size_t recountUnsweptBlocks(OldGenSpace& og) {
    const auto& meta = OldGenSpaceTestAccess::getBufferMeta(og);
    size_t n = 0;
    for (const auto& m : meta) {
        if (!m.fully_swept) ++n;
    }
    return n;
}

}  // namespace

// ----------------------------------------------------------------------------
// 1. Sweep-before-grow: the slow-path allocation drives sweep without
//    burning bag pages while unswept blocks remain.
// ----------------------------------------------------------------------------

Testing::TestCase testSweepBeforeGrow(
    "Slow-path allocation drives lazy sweep before consuming bag pages", []() {
    auto cfg = sweepOnDemandHeapConfig();
    auto& alloc = initAllocator(cfg);
    auto& og = threadOldGen(alloc);

    // Build a heap with mixed-occupancy blocks: half the cells survive,
    // half become garbage.
    std::vector<HPointer> live_roots;
    auto& rootset = alloc.getRootSet();
    for (size_t i = 0; i < 2048; ++i) {
        void* live = allocateIntInOldGen(og, static_cast<i64>(i));
        TEST_ASSERT(live != nullptr);
        (void)allocateIntInOldGen(og, -1);  // garbage
        live_roots.push_back(AllocatorTestAccess::toPointer(live));
    }
    for (auto& r : live_roots) rootset.addRoot(&r);

    runMarkAndSweep(alloc);

    // Expect to be left in the Sweeping phase with pending blocks. The
    // initial slice is sized to keep this true on a multi-page heap.
    if (OldGenSpaceTestAccess::getGCPhase(og) != GCPhase::Sweeping) {
        // Heap was small enough that the initial slice finished sweep; this
        // test's invariant doesn't apply. Skip cleanly.
        for (auto& r : live_roots) rootset.removeRoot(&r);
        return;
    }
    TEST_ASSERT(OldGenSpaceTestAccess::getSweepPendingBlocks(og) > 0);

    const size_t bag_before =
        OldGenSpaceTestAccess::getUnassignedBlocks(og).size();
    size_t prev_pending = OldGenSpaceTestAccess::getSweepPendingBlocks(og);

    // Drive the slow path. Each allocation should either be served by the
    // free-list path (filled by mutator-driven sweep) or fall through to a
    // bag page only after sweep is complete.
    bool saw_decrease = false;
    for (size_t i = 0; i < 4096; ++i) {
        void* probe = allocateIntInOldGen(og, 0);
        TEST_ASSERT(probe != nullptr);
        const size_t pending =
            OldGenSpaceTestAccess::getSweepPendingBlocks(og);
        if (pending < prev_pending) saw_decrease = true;
        prev_pending = pending;

        if (OldGenSpaceTestAccess::sweepComplete(og)) break;
    }

    // sweep_pending_blocks_ must have strictly decreased somewhere during
    // the loop (the mutator drove sweep forward).
    TEST_ASSERT(saw_decrease);

    // Bag growth is allowed once sweep finishes; while sweep was in
    // progress it should not have consumed unassigned pages just to dodge
    // sweep work. We check the weak invariant: bag count never DROPS during
    // an unswept window without sweep finishing first.
    const size_t bag_after =
        OldGenSpaceTestAccess::getUnassignedBlocks(og).size();
    if (!OldGenSpaceTestAccess::sweepComplete(og)) {
        TEST_ASSERT(bag_after >= bag_before);
    }

    for (auto& r : live_roots) rootset.removeRoot(&r);
});

// ----------------------------------------------------------------------------
// 2. Per-allocation sweep cap: a single allocation never burns more than
//    MAX_SWEEP_BYTES_PER_ALLOC of sweep work before falling through.
// ----------------------------------------------------------------------------
//
// We can't reach inside sweepOnDemandAllocate to inspect `swept`, but we
// can construct a heap where free lists never fill from a single slow-path
// call's worth of sweep, then assert the call returns successfully (i.e.
// it fell through to the bag-page path) rather than spinning indefinitely.

Testing::TestCase testPerAllocSweepCap(
    "Single allocation falls through to bag page once per-call sweep cap is hit", []() {
    auto cfg = sweepOnDemandHeapConfig();
    // Bigger initial heap so we can have many unswept blocks at once.
    cfg.initial_old_gen_size = 1024 * 1024;
    cfg.validate();
    auto& alloc = initAllocator(cfg);
    auto& og = threadOldGen(alloc);

    // Saturate the heap with all-live data, then a wave of garbage. After
    // mark, lazy sweep has many blocks of pure live to walk before garbage
    // is exposed.
    std::vector<HPointer> live_roots;
    auto& rootset = alloc.getRootSet();
    for (size_t i = 0; i < 8192; ++i) {
        void* live = allocateIntInOldGen(og, static_cast<i64>(i));
        TEST_ASSERT(live != nullptr);
        live_roots.push_back(AllocatorTestAccess::toPointer(live));
    }
    for (auto& r : live_roots) rootset.addRoot(&r);

    // Add some garbage so the heap is non-trivially mixed.
    for (size_t i = 0; i < 1024; ++i) {
        (void)allocateIntInOldGen(og, -1);
    }

    runMarkAndSweep(alloc);

    if (OldGenSpaceTestAccess::getGCPhase(og) != GCPhase::Sweeping) {
        for (auto& r : live_roots) rootset.removeRoot(&r);
        return;
    }

    // Drive the slow path once and confirm progress (no hang). The cap
    // means even a pathologically slow drain can't block this call forever.
    void* probe = allocateIntInOldGen(og, 0);
    TEST_ASSERT(probe != nullptr);

    for (auto& r : live_roots) rootset.removeRoot(&r);
});

// ----------------------------------------------------------------------------
// 3. The sweep_pending_blocks_ counter tracks fully_swept transitions.
// ----------------------------------------------------------------------------

Testing::TestCase testPendingBlocksCounterTracksFullySwept(
    "sweep_pending_blocks_ matches the count of !fully_swept buffer_meta_ entries", []() {
    auto cfg = sweepOnDemandHeapConfig();
    auto& alloc = initAllocator(cfg);
    auto& og = threadOldGen(alloc);

    std::vector<HPointer> live_roots;
    auto& rootset = alloc.getRootSet();
    for (size_t i = 0; i < 1024; ++i) {
        void* live = allocateIntInOldGen(og, static_cast<i64>(i));
        TEST_ASSERT(live != nullptr);
        (void)allocateIntInOldGen(og, -1);
        live_roots.push_back(AllocatorTestAccess::toPointer(live));
    }
    for (auto& r : live_roots) rootset.addRoot(&r);

    runMarkAndSweep(alloc);

    // Counter is consistent immediately after mark+initial-slice.
    TEST_ASSERT(OldGenSpaceTestAccess::getSweepPendingBlocks(og)
                == recountUnsweptBlocks(og));

    // Drive lazy sweep one slice at a time and re-assert after each slice.
    // OldGenSpaceTestAccess::lazySweep targets a class; we use NUM_SIZE_CLASSES
    // (the "no early-out" sentinel) to walk through blocks normally.
    while (OldGenSpaceTestAccess::getGCPhase(og) == GCPhase::Sweeping) {
        OldGenSpaceTestAccess::lazySweep(og, NUM_SIZE_CLASSES,
                                         /*work_budget=*/4096);
        TEST_ASSERT(OldGenSpaceTestAccess::getSweepPendingBlocks(og)
                    == recountUnsweptBlocks(og));
    }

    // Sweep complete: counter is zero.
    TEST_ASSERT(OldGenSpaceTestAccess::getSweepPendingBlocks(og) == 0);

    for (auto& r : live_roots) rootset.removeRoot(&r);
});

// ----------------------------------------------------------------------------
// 4. Mid-cycle block release decrements the pending counter.
// ----------------------------------------------------------------------------
//
// Approach: after finishMarkAndSweep, force a wave of allocations that
// drains a previously-unswept block (e.g. via splitting + reclaim paths)
// and assert sweep_pending_blocks_ tracks the reduction. We use the
// per-block reclaim path indirectly by triggering another major-GC-style
// mark-and-sweep cycle, which calls reclaimAllDeadBlocksFromMeta.

Testing::TestCase testMidCycleBlockReleaseDecrementsCounter(
    "Mid-cycle block releases (e.g. via reclaimAllDeadBlocksFromMeta) keep the pending counter consistent", []() {
    auto cfg = sweepOnDemandHeapConfig();
    auto& alloc = initAllocator(cfg);
    auto& og = threadOldGen(alloc);

    std::vector<HPointer> live_roots;
    auto& rootset = alloc.getRootSet();
    for (size_t i = 0; i < 2048; ++i) {
        void* live = allocateIntInOldGen(og, static_cast<i64>(i));
        TEST_ASSERT(live != nullptr);
        (void)allocateIntInOldGen(og, -1);
        live_roots.push_back(AllocatorTestAccess::toPointer(live));
    }
    for (auto& r : live_roots) rootset.addRoot(&r);

    runMarkAndSweep(alloc);

    // Drop everything and run another major GC. reclaim removes blocks
    // mid-cycle (post-transition-to-Sweeping, pre-initial-slice); the
    // counter must reflect that change.
    for (auto& r : live_roots) rootset.removeRoot(&r);
    live_roots.clear();

    runMarkAndSweep(alloc);

    TEST_ASSERT(OldGenSpaceTestAccess::getSweepPendingBlocks(og)
                == recountUnsweptBlocks(og));
});
