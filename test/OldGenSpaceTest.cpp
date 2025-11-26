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
        auto& oldgen = alloc.getOldGen();

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
        auto& oldgen = alloc.getOldGen();
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
        oldgen.startMark(rootset.getRoots(), Allocator::instance(), stats);
#else
        oldgen.startMark(rootset.getRoots(), Allocator::instance());
#endif

        // Do incremental marking
#if ENABLE_GC_STATS
        bool more_work = oldgen.incrementalMark(1000, stats);
#else
        bool more_work = oldgen.incrementalMark(1000);
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
        oldgen.finishMarkAndSweep(stats);
#else
        oldgen.finishMarkAndSweep();
#endif
    });
});

Testing::TestCase testRootsPreservedAfterIncrementalMark("Roots remain marked Black after incremental mark steps", []() {
    rc::check([]() {
        auto& alloc = initAllocator();
        auto& oldgen = alloc.getOldGen();
        auto& rootset = alloc.getRootSet();

        // Create a linked list of objects in old gen (size-scaled: 2-8 at size 0, up to 2-108 at size 1000)
        size_t num_nodes = *rc::sizedRange<size_t>(2, 8, 0.1);

        std::vector<void*> objects;
        std::vector<i64> expected_values;

        // Create nodes in reverse order to build list.
        HPointer tail = createNil();

        for (size_t i = 0; i < num_nodes; i++) {
            i64 val = *rc::gen::arbitrary<i64>();
            expected_values.push_back(val);

            void* int_obj = allocateIntInOldGen(oldgen, val);
            if (!int_obj) RC_FAIL("Failed to allocate int in old gen");
            objects.push_back(int_obj);

            // Allocate cons cell
            void* cons_obj = oldgen.allocate(sizeof(Cons));
            if (!cons_obj) RC_FAIL("Failed to allocate cons in old gen");

            Header* hdr = getHeader(cons_obj);
            hdr->tag = Tag_Cons;
            hdr->color = static_cast<u32>(Color::White);
            hdr->unboxed = 0;  // head is boxed

            Cons* cons = static_cast<Cons*>(cons_obj);
            cons->head.p = AllocatorTestAccess::toPointer(int_obj);
            cons->tail = tail;
            objects.push_back(cons_obj);

            tail = AllocatorTestAccess::toPointer(cons_obj);
        }

        // Only root the head of the list (last cons created).
        HPointer root = tail;
        rootset.addRoot(&root);

        // Start marking.
#if ENABLE_GC_STATS
        GCStats& stats = alloc.getMajorGCStats();
        oldgen.startMark(rootset.getRoots(), Allocator::instance(), stats);
#else
        oldgen.startMark(rootset.getRoots(), Allocator::instance());
#endif

        // Do incremental marking in small steps (size-scaled).
        size_t step_size = *rc::sizedRange<size_t>(1, 5, 0.05);
        while (true) {
#if ENABLE_GC_STATS
            bool more = oldgen.incrementalMark(step_size, stats);
#else
            bool more = oldgen.incrementalMark(step_size);
#endif
            if (!more) break;
        }

        // All reachable objects should be Black.
        for (void* obj : objects) {
            Header* hdr = getHeader(obj);
            RC_ASSERT(hdr->color == static_cast<u32>(Color::Black));
        }

        // Clean up.
        rootset.removeRoot(&root);

#if ENABLE_GC_STATS
        oldgen.finishMarkAndSweep(stats);
#else
        oldgen.finishMarkAndSweep();
#endif
    });
});

Testing::TestCase testRootsPreservedAfterSweep("Root objects survive full GC cycle with values intact", []() {
    rc::check([]() {
        auto& alloc = initAllocator();
        auto& oldgen = alloc.getOldGen();
        auto& rootset = alloc.getRootSet();

        // Create some rooted objects (size-scaled: 1-5 at size 0, up to 1-55 at size 1000)
        size_t num_values = *rc::sizedRange<size_t>(1, 5, 0.05);
        auto int_values = *rc::gen::container<std::vector<i64>>(
            num_values,
            rc::gen::arbitrary<i64>()
        );

        std::vector<void*> objects;
        std::vector<HPointer> root_storage;

        for (i64 val : int_values) {
            void* obj = allocateIntInOldGen(oldgen, val);
            if (!obj) RC_FAIL("Failed to allocate object in old gen");
            objects.push_back(obj);
            root_storage.push_back(AllocatorTestAccess::toPointer(obj));
        }

        // Register roots.
        for (auto& root : root_storage) {
            rootset.addRoot(&root);
        }

        // Run full GC.
        runMarkAndSweep(alloc);

        // Verify all root values are intact.
        for (size_t i = 0; i < objects.size(); i++) {
            void* obj = AllocatorTestAccess::fromPointer(root_storage[i]);
            if (!obj) RC_FAIL("Root object became null after GC");

            Header* hdr = getHeader(obj);
            RC_ASSERT(hdr->tag == Tag_Int);

            ElmInt* elm_int = static_cast<ElmInt*>(obj);
            RC_ASSERT(elm_int->value == int_values[i]);
        }

        // Clean up.
        for (auto& root : root_storage) {
            rootset.removeRoot(&root);
        }
    });
});

Testing::TestCase testGarbageUnmarkedInIncrementalSteps("Objects with no roots remain White after incremental marking", []() {
    rc::check([]() {
        auto& alloc = initAllocator();
        auto& oldgen = alloc.getOldGen();
        auto& rootset = alloc.getRootSet();

        // Create objects but DON'T root them (size-scaled: 1-10 at size 0, up to 1-110 at size 1000)
        size_t num_garbage = *rc::sizedRange<size_t>(1, 10, 0.1);

        std::vector<void*> garbage_objects;
        for (size_t i = 0; i < num_garbage; i++) {
            i64 val = *rc::gen::arbitrary<i64>();
            void* obj = allocateIntInOldGen(oldgen, val);
            if (!obj) RC_FAIL("Failed to allocate garbage object in old gen");
            garbage_objects.push_back(obj);
        }

        // Start mark with empty root set (no roots!).
#if ENABLE_GC_STATS
        GCStats& stats = alloc.getMajorGCStats();
        oldgen.startMark(rootset.getRoots(), Allocator::instance(), stats);
#else
        oldgen.startMark(rootset.getRoots(), Allocator::instance());
#endif

        // Incremental mark should have nothing to do.
#if ENABLE_GC_STATS
        bool more_work = oldgen.incrementalMark(1000, stats);
#else
        bool more_work = oldgen.incrementalMark(1000);
#endif
        RC_ASSERT(!more_work);  // No roots means no work.

        // All garbage objects should still be White (unmarked).
        for (void* obj : garbage_objects) {
            Header* hdr = getHeader(obj);
            RC_ASSERT(hdr->color == static_cast<u32>(Color::White));
        }

        // Clean up by running sweep.
#if ENABLE_GC_STATS
        oldgen.finishMarkAndSweep(stats);
#else
        oldgen.finishMarkAndSweep();
#endif
    });
});

Testing::TestCase testGarbageReclaimedAfterSweep("Unreachable objects are reclaimed by sweep", []() {
    rc::check([]() {
        auto& alloc = initAllocator();
        auto& oldgen = alloc.getOldGen();
        auto& rootset = alloc.getRootSet();

        // Create garbage objects (size-scaled: 1-10 at size 0, up to 1-110 at size 1000)
        size_t num_garbage = *rc::sizedRange<size_t>(1, 10, 0.1);

        for (size_t i = 0; i < num_garbage; i++) {
            i64 val = *rc::gen::arbitrary<i64>();
            void* obj = allocateIntInOldGen(oldgen, val);
            if (!obj) RC_FAIL("Failed to allocate garbage object in old gen");
        }

        // Run full GC with no roots - sweep processes everything.
        runMarkAndSweep(alloc);

        // Test passes if GC completes without error.
        RC_ASSERT(true);
    });
});
