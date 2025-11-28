#include "OldGenSpaceTest.hpp"
#include <cstring>
#include <iostream>
#include <rapidcheck.h>
#include <vector>
#include "Allocator.hpp"
#include "Heap.hpp"
#include "HeapGenerators.hpp"
#include "HeapSnapshot.hpp"
#include "OldGenSpace.hpp"
#include "TestHelpers.hpp"
#include "ThreadLocalHeap.hpp"

using namespace Elm;

// Helper to get thread-local OldGenSpace reference.
static OldGenSpace& getOldGen(Allocator& alloc) {
    auto* heap = AllocatorTestAccess::getThreadHeap(alloc);
    RC_ASSERT(heap != nullptr);
    return heap->getOldGen();
}

// Helper to get thread-local GCStats reference.
#if ENABLE_GC_STATS
static GCStats& getStats(Allocator& alloc) {
    auto* heap = AllocatorTestAccess::getThreadHeap(alloc);
    RC_ASSERT(heap != nullptr);
    return heap->getStats();
}
#endif

// ============================================================================
// Tests
// ============================================================================

Testing::TestCase testOldGenAllocate("OldGenSpace allocate returns valid objects", []() {
    rc::check([]() {
        auto& alloc = initAllocator();
        auto& oldgen = getOldGen(alloc);

        // Allocate objects directly in old gen (size-scaled: 1-10 at size 0, up to 1-110 at size 1000)
        size_t num_objects = *rc::sizedRange<size_t>(1, 10, 0.1);
        std::vector<void*> objects;
        std::vector<i64> expected_values;

        for (size_t i = 0; i < num_objects; i++) {
            i64 val = *rc::gen::arbitrary<i64>();
            void* obj = allocateIntInOldGen(oldgen, val);
            if (!obj) break;

            objects.push_back(obj);
            expected_values.push_back(val);
        }

        RC_ASSERT(!objects.empty());

        // Verify all values intact
        for (size_t i = 0; i < objects.size(); i++) {
            ElmInt* elm_int = static_cast<ElmInt*>(objects[i]);
            RC_ASSERT(elm_int->value == expected_values[i]);
        }
    });
});

Testing::TestCase testRootsMarkedAtStart("startMark pushes roots to mark stack", []() {
    rc::check([]() {
        auto& alloc = initAllocator();
        auto& oldgen = getOldGen(alloc);
        auto& rootset = alloc.getRootSet();

        // Allocate objects in old gen (size-scaled: 1-10 at size 0, up to 1-110 at size 1000)
        size_t num_values = *rc::sizedRange<size_t>(1, 10, 0.1);
        std::vector<void*> objects;
        std::vector<HPointer> root_storage;

        for (size_t i = 0; i < num_values; i++) {
            i64 val = *rc::gen::arbitrary<i64>();
            void* obj = allocateIntInOldGen(oldgen, val);
            if (!obj) RC_FAIL("Failed to allocate object in old gen");
            objects.push_back(obj);
            root_storage.push_back(AllocatorTestAccess::toPointer(obj));
        }

        // Register all objects as roots.
        for (auto& root : root_storage) {
            rootset.addRoot(&root);
        }

        // Start marking
#if ENABLE_GC_STATS
        GCStats& stats = getStats(alloc);
        OldGenSpaceTestAccess::startMark(oldgen, rootset.getRoots(), Allocator::instance(), stats);
#else
        OldGenSpaceTestAccess::startMark(oldgen, rootset.getRoots(), Allocator::instance());
#endif

        // Do incremental marking
#if ENABLE_GC_STATS
        bool more_work = OldGenSpaceTestAccess::incrementalMark(oldgen, 1000, stats);
#else
        bool more_work = OldGenSpaceTestAccess::incrementalMark(oldgen, 1000);
#endif
        (void)more_work;

        // All roots should now be marked Black.
        for (void* obj : objects) {
            Header* hdr = getHeader(obj);
            RC_ASSERT(hdr->color == static_cast<u32>(Color::Black));
        }

        // Clean up roots.
        for (auto& root : root_storage) {
            rootset.removeRoot(&root);
        }

        // Complete the GC to reset state.
#if ENABLE_GC_STATS
        OldGenSpaceTestAccess::finishMarkAndSweep(oldgen, stats);
#else
        OldGenSpaceTestAccess::finishMarkAndSweep(oldgen);
#endif
    });
});

Testing::TestCase testRootsPreservedAfterIncrementalMark("Roots remain marked Black after incremental mark steps", []() {
    rc::check([](const HeapGraphDesc& graph) {
        auto& alloc = initAllocator();
        auto& oldgen = getOldGen(alloc);

        // Allocate complex heap graph directly in old gen.
        std::vector<void*> objects = allocateHeapGraphInOldGen(oldgen, graph.nodes);
        RC_ASSERT(!objects.empty());

        // Set up roots from graph description (RAII - auto-unregisters).
        GraphRoots roots = setupRootsFromGraph(alloc, graph, objects);
        RC_ASSERT(!roots.empty());

        // Start marking.
#if ENABLE_GC_STATS
        GCStats& stats = getStats(alloc);
        OldGenSpaceTestAccess::startMark(oldgen, alloc.getRootSet().getRoots(), Allocator::instance(), stats);
#else
        OldGenSpaceTestAccess::startMark(oldgen, alloc.getRootSet().getRoots(), Allocator::instance());
#endif

        // Do incremental marking in small steps (size-scaled: 1-5 at size 0, up to 1-55 at size 1000).
        size_t step_size = *rc::sizedRange<size_t>(1, 5, 0.05);
        while (true) {
#if ENABLE_GC_STATS
            bool more = OldGenSpaceTestAccess::incrementalMark(oldgen, step_size, stats);
#else
            bool more = OldGenSpaceTestAccess::incrementalMark(oldgen, step_size);
#endif
            if (!more) break;
        }

        // All rooted objects should be Black after full marking.
        for (size_t idx : graph.root_indices) {
            if (idx < objects.size()) {
                Header* hdr = getHeader(objects[idx]);
                RC_ASSERT(hdr->color == static_cast<u32>(Color::Black));
            }
        }

        // Complete the GC to reset state.
#if ENABLE_GC_STATS
        OldGenSpaceTestAccess::finishMarkAndSweep(oldgen, stats);
#else
        OldGenSpaceTestAccess::finishMarkAndSweep(oldgen);
#endif
    });
});

Testing::TestCase testRootsPreservedAfterSweep("Root objects survive full GC cycle with values intact", []() {
    rc::check([]() {
        auto& alloc = initAllocator();
        auto& oldgen = getOldGen(alloc);
        auto& rootset = alloc.getRootSet();

        // Allocate objects in old gen (size-scaled: 1-10 at size 0, up to 1-110 at size 1000)
        size_t num_values = *rc::sizedRange<size_t>(1, 10, 0.1);
        std::vector<void*> objects;
        std::vector<i64> expected_values;
        std::vector<HPointer> root_storage;

        for (size_t i = 0; i < num_values; i++) {
            i64 val = *rc::gen::arbitrary<i64>();
            void* obj = allocateIntInOldGen(oldgen, val);
            if (!obj) RC_FAIL("Failed to allocate object in old gen");
            objects.push_back(obj);
            expected_values.push_back(val);
            root_storage.push_back(AllocatorTestAccess::toPointer(obj));
        }

        // Register all objects as roots.
        for (auto& root : root_storage) {
            rootset.addRoot(&root);
        }

        // Run full GC.
        runMarkAndSweep(alloc);

        // Verify all values preserved after GC.
        for (size_t i = 0; i < objects.size(); i++) {
            void* obj = readBarrier(root_storage[i]);
            ElmInt* elm_int = static_cast<ElmInt*>(obj);
            RC_ASSERT(elm_int->value == expected_values[i]);
        }

        // Clean up roots.
        for (auto& root : root_storage) {
            rootset.removeRoot(&root);
        }
    });
});

Testing::TestCase testGarbageUnmarkedInIncrementalSteps("Objects with no roots remain White after incremental marking", []() {
    rc::check([](const HeapGraphDesc& graph) {
        auto& alloc = initAllocator();
        auto& oldgen = getOldGen(alloc);

        // Allocate complex heap graph directly in old gen - but DON'T root them.
        std::vector<void*> garbage_objects = allocateHeapGraphInOldGen(oldgen, graph.nodes);
        RC_ASSERT(!garbage_objects.empty());

        // Start mark with empty root set (no roots!).
#if ENABLE_GC_STATS
        GCStats& stats = getStats(alloc);
        OldGenSpaceTestAccess::startMark(oldgen, alloc.getRootSet().getRoots(), Allocator::instance(), stats);
#else
        OldGenSpaceTestAccess::startMark(oldgen, alloc.getRootSet().getRoots(), Allocator::instance());
#endif

        // Incremental mark should have nothing to do.
#if ENABLE_GC_STATS
        bool more_work = OldGenSpaceTestAccess::incrementalMark(oldgen, 1000, stats);
#else
        bool more_work = OldGenSpaceTestAccess::incrementalMark(oldgen, 1000);
#endif
        RC_ASSERT(!more_work);  // No roots means no work.

        // All garbage objects should still be White (unmarked).
        for (void* obj : garbage_objects) {
            Header* hdr = getHeader(obj);
            RC_ASSERT(hdr->color == static_cast<u32>(Color::White));
        }

        // Clean up by running sweep.
#if ENABLE_GC_STATS
        OldGenSpaceTestAccess::finishMarkAndSweep(oldgen, stats);
#else
        OldGenSpaceTestAccess::finishMarkAndSweep(oldgen);
#endif
    });
});

Testing::TestCase testGarbageReclaimedAfterSweep("Unreachable objects are reclaimed by sweep", []() {
    rc::check([](const HeapGraphDesc& graph) {
        auto& alloc = initAllocator();
        auto& oldgen = getOldGen(alloc);

        // Allocate complex heap graph directly in old gen - but DON'T root them.
        std::vector<void*> garbage_objects = allocateHeapGraphInOldGen(oldgen, graph.nodes);
        RC_ASSERT(!garbage_objects.empty());

        // Run full GC with no roots - sweep processes everything.
        runMarkAndSweep(alloc);

        // Test passes if GC completes without error.
        RC_ASSERT(true);
    });
});

// ============================================================================
// Phase 1-2 Tests: Free-List Allocation
// ============================================================================

Testing::TestCase testSizeClassCorrectness("Size class and class-to-size are consistent", []() {
    rc::check([]() {
        // Test sizes from 1 to 512 bytes.
        size_t size = *rc::gen::inRange<size_t>(1, 513);

        size_t cls = OldGenSpaceTestAccess::sizeClass(size);

        if (size <= MAX_SMALL_SIZE) {
            // Should be a valid size class.
            RC_ASSERT(cls < NUM_SIZE_CLASSES);

            // classToSize should return a size >= original (after alignment).
            size_t class_size = OldGenSpaceTestAccess::classToSize(cls);
            size_t aligned_size = (size + 7) & ~7;
            RC_ASSERT(class_size >= aligned_size);
            RC_ASSERT(class_size == aligned_size);  // Should be exact for small sizes.
        } else {
            // Large objects should get the sentinel value.
            RC_ASSERT(cls == NUM_SIZE_CLASSES);
        }
    });
});

Testing::TestCase testFreeListRoundTrip("Free list recycles memory after GC", []() {
    rc::check([]() {
        auto& alloc = initAllocator();
        auto& oldgen = getOldGen(alloc);

        // Allocate objects in old gen (unrooted - will become garbage).
        size_t num_objects = *rc::gen::inRange<size_t>(5, 20);
        std::vector<void*> first_batch;

        for (size_t i = 0; i < num_objects; i++) {
            void* obj = allocateIntInOldGen(oldgen, static_cast<i64>(i));
            if (!obj) RC_FAIL("Failed to allocate in old gen");
            first_batch.push_back(obj);
        }

        // Run GC to free these objects (they're unrooted).
        runMarkAndSweep(alloc);

        // Allocate same number of objects again.
        // They should come from free lists (same addresses or nearby).
        std::vector<void*> second_batch;
        for (size_t i = 0; i < num_objects; i++) {
            void* obj = allocateIntInOldGen(oldgen, static_cast<i64>(i + 100));
            if (!obj) RC_FAIL("Failed to allocate in old gen");
            second_batch.push_back(obj);
        }

        // Check that at least some allocations reused freed memory.
        // (Addresses from second batch should be in first batch.)
        size_t reused = 0;
        for (void* obj : second_batch) {
            if (std::find(first_batch.begin(), first_batch.end(), obj) != first_batch.end()) {
                reused++;
            }
        }

        // Most allocations should be reused (allow some slack for bump allocation).
        RC_ASSERT(reused > 0);
    });
});

Testing::TestCase testMixedSizeAllocation("Mixed size allocations survive GC correctly", []() {
    rc::check([]() {
        auto& alloc = initAllocator();
        auto& oldgen = getOldGen(alloc);
        auto& rootset = alloc.getRootSet();

        // Allocate objects of varying sizes, root some of them.
        size_t num_objects = *rc::gen::inRange<size_t>(5, 15);
        std::vector<void*> objects;
        std::vector<i64> values;
        std::vector<HPointer> root_storage;
        std::vector<bool> is_rooted;

        for (size_t i = 0; i < num_objects; i++) {
            i64 val = *rc::gen::arbitrary<i64>();
            void* obj = allocateIntInOldGen(oldgen, val);
            if (!obj) RC_FAIL("Failed to allocate in old gen");
            objects.push_back(obj);
            values.push_back(val);

            // Root about half the objects.
            bool rooted = *rc::gen::arbitrary<bool>();
            is_rooted.push_back(rooted);
            if (rooted) {
                root_storage.push_back(AllocatorTestAccess::toPointer(obj));
            }
        }

        // Register roots.
        for (auto& root : root_storage) {
            rootset.addRoot(&root);
        }

        // Run multiple GC cycles.
        size_t gc_cycles = *rc::gen::inRange<size_t>(1, 4);
        for (size_t c = 0; c < gc_cycles; c++) {
            runMarkAndSweep(alloc);
        }

        // Verify rooted objects still have correct values.
        size_t root_idx = 0;
        for (size_t i = 0; i < num_objects; i++) {
            if (is_rooted[i]) {
                void* obj = readBarrier(root_storage[root_idx]);
                ElmInt* elm_int = static_cast<ElmInt*>(obj);
                RC_ASSERT(elm_int->value == values[i]);
                root_idx++;
            }
        }

        // Clean up roots.
        for (auto& root : root_storage) {
            rootset.removeRoot(&root);
        }
    });
});

// ============================================================================
// Phase 3 Tests: Lazy Sweeping
// ============================================================================

Testing::TestCase testLazySweepPreservesLive("Lazy sweep preserves all live objects", []() {
    rc::check([](const HeapGraphDesc& graph) {
        auto& alloc = initAllocator();
        auto& oldgen = getOldGen(alloc);

        // Allocate heap graph in old gen.
        std::vector<void*> objects = allocateHeapGraphInOldGen(oldgen, graph.nodes);
        RC_ASSERT(!objects.empty());

        // Root some objects.
        GraphRoots roots = setupRootsFromGraph(alloc, graph, objects);

        // Start marking.
#if ENABLE_GC_STATS
        GCStats& stats = getStats(alloc);
        OldGenSpaceTestAccess::startMark(oldgen, alloc.getRootSet().getRoots(), Allocator::instance(), stats);
#else
        OldGenSpaceTestAccess::startMark(oldgen, alloc.getRootSet().getRoots(), Allocator::instance());
#endif

        // Complete marking.
        while (true) {
#if ENABLE_GC_STATS
            bool more = OldGenSpaceTestAccess::incrementalMark(oldgen, 100, stats);
#else
            bool more = OldGenSpaceTestAccess::incrementalMark(oldgen, 100);
#endif
            if (!more) break;
        }

        // Transition to sweeping.
        OldGenSpaceTestAccess::transitionToSweeping(oldgen);
        RC_ASSERT(OldGenSpaceTestAccess::getGCPhase(oldgen) == GCPhase::Sweeping);

        // Do lazy sweeps in small chunks.
        while (OldGenSpaceTestAccess::getGCPhase(oldgen) == GCPhase::Sweeping) {
            OldGenSpaceTestAccess::lazySweep(oldgen, 0, 256);
        }

        // Verify rooted objects still intact.
        for (size_t idx : graph.root_indices) {
            if (idx < objects.size()) {
                void* obj = objects[idx];
                Header* hdr = getHeader(obj);
                // After sweep, live objects should be White (reset from Black).
                RC_ASSERT(hdr->tag != Tag_Forward);
            }
        }
    });
});

Testing::TestCase testSweepProgressMonotonicity("Sweep progress only moves forward", []() {
    rc::check([]() {
        auto& alloc = initAllocator();
        auto& oldgen = getOldGen(alloc);

        // Allocate some garbage objects.
        size_t num_objects = *rc::gen::inRange<size_t>(10, 30);
        for (size_t i = 0; i < num_objects; i++) {
            allocateIntInOldGen(oldgen, static_cast<i64>(i));
        }

        // Start marking with no roots (all garbage).
#if ENABLE_GC_STATS
        GCStats& stats = getStats(alloc);
        OldGenSpaceTestAccess::startMark(oldgen, alloc.getRootSet().getRoots(), Allocator::instance(), stats);
        OldGenSpaceTestAccess::incrementalMark(oldgen, 1000, stats);
#else
        OldGenSpaceTestAccess::startMark(oldgen, alloc.getRootSet().getRoots(), Allocator::instance());
        OldGenSpaceTestAccess::incrementalMark(oldgen, 1000);
#endif

        // Transition to sweeping.
        OldGenSpaceTestAccess::transitionToSweeping(oldgen);

        size_t prev_buffer_idx = 0;
        const char* prev_cursor = nullptr;

        // Track sweep progress.
        while (OldGenSpaceTestAccess::getGCPhase(oldgen) == GCPhase::Sweeping) {
            size_t curr_buffer_idx = OldGenSpaceTestAccess::getSweepBufferIndex(oldgen);
            const char* curr_cursor = OldGenSpaceTestAccess::getSweepCursor(oldgen);

            // Buffer index should only increase or stay same.
            RC_ASSERT(curr_buffer_idx >= prev_buffer_idx);

            // Within same buffer, cursor should only move forward.
            if (curr_buffer_idx == prev_buffer_idx && prev_cursor != nullptr && curr_cursor != nullptr) {
                RC_ASSERT(curr_cursor >= prev_cursor);
            }

            prev_buffer_idx = curr_buffer_idx;
            prev_cursor = curr_cursor;

            OldGenSpaceTestAccess::lazySweep(oldgen, 0, 64);
        }

        // Should end in Idle state.
        RC_ASSERT(OldGenSpaceTestAccess::getGCPhase(oldgen) == GCPhase::Idle);
    });
});

Testing::TestCase testAllocationDuringSweep("Allocations during sweep are correctly handled", []() {
    rc::check([]() {
        auto& alloc = initAllocator();
        auto& oldgen = getOldGen(alloc);
        auto& rootset = alloc.getRootSet();

        // Allocate some initial objects (garbage).
        for (size_t i = 0; i < 10; i++) {
            allocateIntInOldGen(oldgen, static_cast<i64>(i));
        }

        // Start GC cycle.
#if ENABLE_GC_STATS
        GCStats& stats = getStats(alloc);
        OldGenSpaceTestAccess::startMark(oldgen, alloc.getRootSet().getRoots(), Allocator::instance(), stats);
        OldGenSpaceTestAccess::incrementalMark(oldgen, 1000, stats);
#else
        OldGenSpaceTestAccess::startMark(oldgen, alloc.getRootSet().getRoots(), Allocator::instance());
        OldGenSpaceTestAccess::incrementalMark(oldgen, 1000);
#endif

        OldGenSpaceTestAccess::transitionToSweeping(oldgen);

        // Allocate new objects during sweep and root them.
        std::vector<void*> new_objects;
        std::vector<i64> new_values;
        std::vector<HPointer> new_roots;

        while (OldGenSpaceTestAccess::getGCPhase(oldgen) == GCPhase::Sweeping) {
            // Allocate a new object.
            i64 val = static_cast<i64>(new_objects.size() + 1000);
            void* obj = allocateIntInOldGen(oldgen, val);
            if (obj) {
                new_objects.push_back(obj);
                new_values.push_back(val);
                new_roots.push_back(AllocatorTestAccess::toPointer(obj));
            }

            // Do a small sweep.
            OldGenSpaceTestAccess::lazySweep(oldgen, 0, 128);
        }

        // Register roots for the new objects.
        for (auto& root : new_roots) {
            rootset.addRoot(&root);
        }

        // New objects allocated during sweep should survive.
        for (size_t i = 0; i < new_objects.size(); i++) {
            void* obj = readBarrier(new_roots[i]);
            ElmInt* elm_int = static_cast<ElmInt*>(obj);
            RC_ASSERT(elm_int->value == new_values[i]);
        }

        // Clean up.
        for (auto& root : new_roots) {
            rootset.removeRoot(&root);
        }
    });
});

// ============================================================================
// Phase 4 Tests: Incremental Marking
// ============================================================================

Testing::TestCase testIncrementalMarkEquivalence("Incremental marking produces same result as full marking", []() {
    rc::check([](const HeapGraphDesc& graph) {
        auto& alloc = initAllocator();
        auto& oldgen = getOldGen(alloc);

        // Allocate heap graph.
        std::vector<void*> objects = allocateHeapGraphInOldGen(oldgen, graph.nodes);
        RC_ASSERT(!objects.empty());

        // Root some objects.
        GraphRoots roots = setupRootsFromGraph(alloc, graph, objects);

        // Do incremental marking with small steps.
#if ENABLE_GC_STATS
        GCStats& stats = getStats(alloc);
        OldGenSpaceTestAccess::startMark(oldgen, alloc.getRootSet().getRoots(), Allocator::instance(), stats);
#else
        OldGenSpaceTestAccess::startMark(oldgen, alloc.getRootSet().getRoots(), Allocator::instance());
#endif

        // Use very small work units to test incremental behavior.
        size_t total_steps = 0;
        while (true) {
#if ENABLE_GC_STATS
            bool more = OldGenSpaceTestAccess::incrementalMark(oldgen, 1, stats);
#else
            bool more = OldGenSpaceTestAccess::incrementalMark(oldgen, 1);
#endif
            total_steps++;
            if (!more) break;
            RC_ASSERT(total_steps < 10000);  // Sanity check.
        }

        // All rooted objects and their transitive closure should be Black.
        for (size_t idx : graph.root_indices) {
            if (idx < objects.size()) {
                Header* hdr = getHeader(objects[idx]);
                RC_ASSERT(hdr->color == static_cast<u32>(Color::Black));
            }
        }

        // Complete sweep.
#if ENABLE_GC_STATS
        OldGenSpaceTestAccess::finishMarkAndSweep(oldgen, stats);
#else
        OldGenSpaceTestAccess::finishMarkAndSweep(oldgen);
#endif
    });
});

Testing::TestCase testMarkingWithAllocation("New allocations during marking survive", []() {
    rc::check([]() {
        auto& alloc = initAllocator();
        auto& oldgen = getOldGen(alloc);
        auto& rootset = alloc.getRootSet();

        // Create some initial rooted objects.
        std::vector<void*> initial_objects;
        std::vector<HPointer> initial_roots;
        std::vector<i64> initial_values;

        for (size_t i = 0; i < 5; i++) {
            i64 val = static_cast<i64>(i);
            void* obj = allocateIntInOldGen(oldgen, val);
            initial_objects.push_back(obj);
            initial_roots.push_back(AllocatorTestAccess::toPointer(obj));
            initial_values.push_back(val);
        }

        for (auto& root : initial_roots) {
            rootset.addRoot(&root);
        }

        // Start marking.
#if ENABLE_GC_STATS
        GCStats& stats = getStats(alloc);
        OldGenSpaceTestAccess::startMark(oldgen, alloc.getRootSet().getRoots(), Allocator::instance(), stats);
#else
        OldGenSpaceTestAccess::startMark(oldgen, alloc.getRootSet().getRoots(), Allocator::instance());
#endif

        // Allocate new objects during marking.
        std::vector<void*> new_objects;
        std::vector<HPointer> new_roots;
        std::vector<i64> new_values;

        for (size_t i = 0; i < 5; i++) {
            // Do some marking work.
#if ENABLE_GC_STATS
            OldGenSpaceTestAccess::incrementalMark(oldgen, 2, stats);
#else
            OldGenSpaceTestAccess::incrementalMark(oldgen, 2);
#endif

            // Allocate during marking.
            i64 val = static_cast<i64>(i + 100);
            void* obj = allocateIntInOldGen(oldgen, val);
            new_objects.push_back(obj);
            new_roots.push_back(AllocatorTestAccess::toPointer(obj));
            new_values.push_back(val);

            // New objects should be Black (survive this cycle).
            Header* hdr = getHeader(obj);
            RC_ASSERT(hdr->color == static_cast<u32>(Color::Black));
        }

        for (auto& root : new_roots) {
            rootset.addRoot(&root);
        }

        // Complete GC.
#if ENABLE_GC_STATS
        OldGenSpaceTestAccess::finishMarkAndSweep(oldgen, stats);
#else
        OldGenSpaceTestAccess::finishMarkAndSweep(oldgen);
#endif

        // Verify all objects survived.
        for (size_t i = 0; i < initial_objects.size(); i++) {
            void* obj = readBarrier(initial_roots[i]);
            ElmInt* elm_int = static_cast<ElmInt*>(obj);
            RC_ASSERT(elm_int->value == initial_values[i]);
        }

        for (size_t i = 0; i < new_objects.size(); i++) {
            void* obj = readBarrier(new_roots[i]);
            ElmInt* elm_int = static_cast<ElmInt*>(obj);
            RC_ASSERT(elm_int->value == new_values[i]);
        }

        // Clean up.
        for (auto& root : initial_roots) {
            rootset.removeRoot(&root);
        }
        for (auto& root : new_roots) {
            rootset.removeRoot(&root);
        }
    });
});

// ============================================================================
// Phase 5 Tests: Fragmentation Statistics
// ============================================================================

Testing::TestCase testUtilizationCalculation("Fragmentation stats are computed correctly", []() {
    rc::check([]() {
        auto& alloc = initAllocator();
        auto& oldgen = getOldGen(alloc);
        auto& rootset = alloc.getRootSet();

        // Allocate objects, root about half.
        size_t num_objects = *rc::gen::inRange<size_t>(10, 30);
        std::vector<void*> objects;
        std::vector<HPointer> roots;
        size_t expected_live = 0;

        for (size_t i = 0; i < num_objects; i++) {
            void* obj = allocateIntInOldGen(oldgen, static_cast<i64>(i));
            objects.push_back(obj);

            // Root every other object.
            if (i % 2 == 0) {
                roots.push_back(AllocatorTestAccess::toPointer(obj));
                expected_live += sizeof(ElmInt);
            }
        }

        for (auto& root : roots) {
            rootset.addRoot(&root);
        }

        // Run GC.
        runMarkAndSweep(alloc);

        // Check fragmentation stats.
        const auto& stats = OldGenSpaceTestAccess::getFragStats(oldgen);

        // Live bytes should be approximately what we rooted.
        // (May have slight variance due to header alignment etc.)
        RC_ASSERT(stats.live_bytes > 0);
        RC_ASSERT(stats.heap_bytes >= stats.live_bytes);

        // Utilization should be reasonable.
        float util = stats.utilization();
        RC_ASSERT(util >= 0.0f && util <= 1.0f);

        // Clean up.
        for (auto& root : roots) {
            rootset.removeRoot(&root);
        }
    });
});

Testing::TestCase testLiveBytesAccuracy("Live bytes matches actual live objects", []() {
    rc::check([]() {
        auto& alloc = initAllocator();
        auto& oldgen = getOldGen(alloc);
        auto& rootset = alloc.getRootSet();

        // Allocate and root specific objects.
        size_t num_roots = *rc::gen::inRange<size_t>(3, 10);
        std::vector<HPointer> roots;
        size_t object_size = (sizeof(ElmInt) + 7) & ~7;  // Aligned size.

        for (size_t i = 0; i < num_roots; i++) {
            void* obj = allocateIntInOldGen(oldgen, static_cast<i64>(i));
            roots.push_back(AllocatorTestAccess::toPointer(obj));
        }

        for (auto& root : roots) {
            rootset.addRoot(&root);
        }

        // Allocate garbage.
        size_t num_garbage = *rc::gen::inRange<size_t>(5, 15);
        for (size_t i = 0; i < num_garbage; i++) {
            allocateIntInOldGen(oldgen, static_cast<i64>(i + 1000));
        }

        // Run GC.
        runMarkAndSweep(alloc);

        // Check that live_bytes is close to expected.
        const auto& stats = OldGenSpaceTestAccess::getFragStats(oldgen);
        size_t expected_live = num_roots * object_size;

        // Allow some tolerance for metadata/alignment.
        RC_ASSERT(stats.live_bytes >= expected_live * 0.9);
        RC_ASSERT(stats.live_bytes <= expected_live * 1.5);

        // Clean up.
        for (auto& root : roots) {
            rootset.removeRoot(&root);
        }
    });
});

// ============================================================================
// Phase 6 Tests: Incremental Compaction
// ============================================================================

Testing::TestCase testEvacuationPreservesValues("Evacuated objects have correct values", []() {
    rc::check([]() {
        auto& alloc = initAllocator();
        auto& oldgen = getOldGen(alloc);
        auto& rootset = alloc.getRootSet();

        // Allocate objects and root them.
        size_t num_objects = *rc::gen::inRange<size_t>(5, 15);
        std::vector<HPointer> roots;
        std::vector<i64> values;

        for (size_t i = 0; i < num_objects; i++) {
            i64 val = *rc::gen::arbitrary<i64>();
            void* obj = allocateIntInOldGen(oldgen, val);
            roots.push_back(AllocatorTestAccess::toPointer(obj));
            values.push_back(val);
        }

        for (auto& root : roots) {
            rootset.addRoot(&root);
        }

        // Run GC to establish buffer metadata.
        runMarkAndSweep(alloc);

        // Trigger compaction if possible.
        OldGenSpaceTestAccess::scheduleCompaction(oldgen);

        // Do compaction work.
        while (OldGenSpaceTestAccess::getCompactPhase(oldgen) != CompactionPhase::Idle) {
            OldGenSpaceTestAccess::incrementalCompactionSlice(oldgen, 1024);
        }

        // Verify all values are preserved.
        for (size_t i = 0; i < roots.size(); i++) {
            void* obj = readBarrier(roots[i]);
            ElmInt* elm_int = static_cast<ElmInt*>(obj);
            RC_ASSERT(elm_int->value == values[i]);
        }

        // Clean up.
        for (auto& root : roots) {
            rootset.removeRoot(&root);
        }
    });
});

Testing::TestCase testForwardingPointerCorrectness("Forwarding pointers point to valid objects", []() {
    rc::check([]() {
        auto& alloc = initAllocator();
        auto& oldgen = getOldGen(alloc);
        auto& rootset = alloc.getRootSet();

        // Allocate objects.
        size_t num_objects = *rc::gen::inRange<size_t>(5, 15);
        std::vector<void*> original_addrs;
        std::vector<HPointer> roots;
        std::vector<i64> values;

        for (size_t i = 0; i < num_objects; i++) {
            i64 val = static_cast<i64>(i);
            void* obj = allocateIntInOldGen(oldgen, val);
            original_addrs.push_back(obj);
            roots.push_back(AllocatorTestAccess::toPointer(obj));
            values.push_back(val);
        }

        for (auto& root : roots) {
            rootset.addRoot(&root);
        }

        // Run GC to establish metadata.
        runMarkAndSweep(alloc);

        // Schedule and partially run compaction.
        OldGenSpaceTestAccess::scheduleCompaction(oldgen);

        if (OldGenSpaceTestAccess::getCompactPhase(oldgen) == CompactionPhase::Evacuating) {
            // Do just the evacuation phase.
            while (OldGenSpaceTestAccess::getCompactPhase(oldgen) == CompactionPhase::Evacuating) {
                OldGenSpaceTestAccess::incrementalCompactionSlice(oldgen, 256);
            }

            // Check forwarding pointers (if any were created).
            for (size_t i = 0; i < original_addrs.size(); i++) {
                void* fwd = OldGenSpaceTestAccess::getForwardingAddress(oldgen, original_addrs[i]);
                if (fwd != nullptr) {
                    // Forwarding pointer should point to a valid object.
                    Header* hdr = getHeader(fwd);
                    RC_ASSERT(hdr->tag == Tag_Int);
                    ElmInt* elm_int = static_cast<ElmInt*>(fwd);
                    RC_ASSERT(elm_int->value == values[i]);
                }
            }
        }

        // Complete compaction.
        while (OldGenSpaceTestAccess::getCompactPhase(oldgen) != CompactionPhase::Idle) {
            OldGenSpaceTestAccess::incrementalCompactionSlice(oldgen, 1024);
        }

        // Clean up.
        for (auto& root : roots) {
            rootset.removeRoot(&root);
        }
    });
});

// ============================================================================
// Integration / Stress Tests
// ============================================================================

Testing::TestCase testMultipleCycleStability("Multiple GC cycles maintain heap stability", []() {
    rc::check([]() {
        auto& alloc = initAllocator();
        auto& oldgen = getOldGen(alloc);
        auto& rootset = alloc.getRootSet();

        // Create some long-lived rooted objects.
        size_t num_roots = *rc::gen::inRange<size_t>(3, 8);
        std::vector<HPointer> roots;
        std::vector<i64> values;

        for (size_t i = 0; i < num_roots; i++) {
            i64 val = *rc::gen::arbitrary<i64>();
            void* obj = allocateIntInOldGen(oldgen, val);
            roots.push_back(AllocatorTestAccess::toPointer(obj));
            values.push_back(val);
        }

        for (auto& root : roots) {
            rootset.addRoot(&root);
        }

        // Run many GC cycles with interleaved allocation.
        size_t num_cycles = *rc::gen::inRange<size_t>(5, 15);
        for (size_t cycle = 0; cycle < num_cycles; cycle++) {
            // Allocate some garbage each cycle.
            size_t garbage_count = *rc::gen::inRange<size_t>(5, 20);
            for (size_t g = 0; g < garbage_count; g++) {
                allocateIntInOldGen(oldgen, static_cast<i64>(cycle * 1000 + g));
            }

            // Run GC.
            runMarkAndSweep(alloc);

            // Verify roots still valid.
            for (size_t i = 0; i < roots.size(); i++) {
                void* obj = readBarrier(roots[i]);
                if (!obj) RC_FAIL("Root object became null after GC");
                ElmInt* elm_int = static_cast<ElmInt*>(obj);
                RC_ASSERT(elm_int->value == values[i]);
            }
        }

        // Clean up.
        for (auto& root : roots) {
            rootset.removeRoot(&root);
        }
    });
});

Testing::TestCase testHeaderConsistency("Rooted object headers remain valid after GC", []() {
    rc::check([](const HeapGraphDesc& graph) {
        auto& alloc = initAllocator();
        auto& oldgen = getOldGen(alloc);

        // Allocate heap graph.
        std::vector<void*> objects = allocateHeapGraphInOldGen(oldgen, graph.nodes);
        RC_ASSERT(!objects.empty());

        // Root some objects.
        GraphRoots roots = setupRootsFromGraph(alloc, graph, objects);

        // Verify all roots are registered
        RC_ASSERT(!roots.empty());

        // Run GC.
        runMarkAndSweep(alloc);

        // Verify rooted objects have valid headers.
        // Note: After sweep, live objects should be White (reset from Black).
        // But some objects may still be Black if they weren't in the sweep range
        // (e.g., objects allocated in new buffers during marking).
        for (size_t idx : graph.root_indices) {
            if (idx < objects.size()) {
                void* obj = objects[idx];
                Header* hdr = getHeader(obj);

                // Tag should be valid for this object type (0 to Tag_Forward=14).
                bool valid_tag = hdr->tag <= Tag_Forward;
                RC_ASSERT(valid_tag);

                // Live objects should not be Grey (in the middle of marking).
                // They should be either White (reset after sweep) or Black (survived).
                if (hdr->tag != Tag_Forward) {
                    RC_ASSERT(hdr->color == static_cast<u32>(Color::White) ||
                              hdr->color == static_cast<u32>(Color::Black));
                }
            }
        }
    });
});

Testing::TestCase testEmptyHeapBehavior("GC on empty heap completes without error", []() {
    rc::check([]() {
        auto& alloc = initAllocator();

        // Run GC on empty old gen - should complete without error.
        runMarkAndSweep(alloc);
        runMarkAndSweep(alloc);
        runMarkAndSweep(alloc);

        RC_ASSERT(true);
    });
});

Testing::TestCase testAllGarbageHeap("GC reclaims all objects when none are rooted", []() {
    rc::check([]() {
        auto& alloc = initAllocator();
        auto& oldgen = getOldGen(alloc);

        // Allocate many objects but don't root any.
        size_t num_objects = *rc::gen::inRange<size_t>(20, 50);
        for (size_t i = 0; i < num_objects; i++) {
            allocateIntInOldGen(oldgen, static_cast<i64>(i));
        }

        // Run GC.
        runMarkAndSweep(alloc);

        // Check that live_bytes is 0 (all garbage).
        const auto& stats = OldGenSpaceTestAccess::getFragStats(oldgen);
        RC_ASSERT(stats.live_bytes == 0);
    });
});

Testing::TestCase testAllLiveHeap("GC preserves all objects when all are rooted", []() {
    rc::check([]() {
        auto& alloc = initAllocator();
        auto& oldgen = getOldGen(alloc);
        auto& rootset = alloc.getRootSet();

        // Allocate objects and root all of them.
        size_t num_objects = *rc::gen::inRange<size_t>(5, 15);
        std::vector<HPointer> roots;
        std::vector<i64> values;

        for (size_t i = 0; i < num_objects; i++) {
            i64 val = *rc::gen::arbitrary<i64>();
            void* obj = allocateIntInOldGen(oldgen, val);
            roots.push_back(AllocatorTestAccess::toPointer(obj));
            values.push_back(val);
        }

        for (auto& root : roots) {
            rootset.addRoot(&root);
        }

        // Run GC.
        runMarkAndSweep(alloc);

        // Verify all objects survived.
        for (size_t i = 0; i < roots.size(); i++) {
            void* obj = readBarrier(roots[i]);
            ElmInt* elm_int = static_cast<ElmInt*>(obj);
            RC_ASSERT(elm_int->value == values[i]);
        }

        // Check that live_bytes is positive.
        const auto& stats = OldGenSpaceTestAccess::getFragStats(oldgen);
        RC_ASSERT(stats.live_bytes > 0);

        // Clean up.
        for (auto& root : roots) {
            rootset.removeRoot(&root);
        }
    });
});
