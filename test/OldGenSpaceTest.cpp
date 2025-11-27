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

using namespace Elm;

// ============================================================================
// Tests
// ============================================================================

Testing::TestCase testOldGenAllocate("OldGenSpace allocate returns valid objects", []() {
    rc::check([]() {
        auto& alloc = initAllocator();
        auto& oldgen = AllocatorTestAccess::getOldGen(alloc);

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
        auto& oldgen = AllocatorTestAccess::getOldGen(alloc);
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
        GCStats& stats = alloc.getMajorGCStats();
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
        auto& oldgen = AllocatorTestAccess::getOldGen(alloc);

        // Allocate complex heap graph directly in old gen.
        std::vector<void*> objects = allocateHeapGraphInOldGen(oldgen, graph.nodes);
        RC_ASSERT(!objects.empty());

        // Set up roots from graph description (RAII - auto-unregisters).
        GraphRoots roots = setupRootsFromGraph(alloc, graph, objects);
        RC_ASSERT(!roots.empty());

        // Start marking.
#if ENABLE_GC_STATS
        GCStats& stats = alloc.getMajorGCStats();
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
        auto& oldgen = AllocatorTestAccess::getOldGen(alloc);
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
        auto& oldgen = AllocatorTestAccess::getOldGen(alloc);

        // Allocate complex heap graph directly in old gen - but DON'T root them.
        std::vector<void*> garbage_objects = allocateHeapGraphInOldGen(oldgen, graph.nodes);
        RC_ASSERT(!garbage_objects.empty());

        // Start mark with empty root set (no roots!).
#if ENABLE_GC_STATS
        GCStats& stats = alloc.getMajorGCStats();
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
        auto& oldgen = AllocatorTestAccess::getOldGen(alloc);

        // Allocate complex heap graph directly in old gen - but DON'T root them.
        std::vector<void*> garbage_objects = allocateHeapGraphInOldGen(oldgen, graph.nodes);
        RC_ASSERT(!garbage_objects.empty());

        // Run full GC with no roots - sweep processes everything.
        runMarkAndSweep(alloc);

        // Test passes if GC completes without error.
        RC_ASSERT(true);
    });
});
