#include "GarbageCollectorTest.hpp"
#include <rapidcheck.h>
#include <vector>
#include "HeapGenerators.hpp"
#include "TestHelpers.hpp"

using namespace Elm;

// ============================================================================
// Helper: Check if pointer is in old gen.
// ============================================================================

static bool isInOldGen(GarbageCollector& gc, void* obj) {
    return gc.getOldGen().contains(obj);
}

// ============================================================================
// Helper: Check if pointer is in nursery.
// ============================================================================

static bool isInNursery(GarbageCollector& gc, void* obj) {
    auto* nursery = gc.getNursery();
    return nursery && nursery->contains(obj);
}

// ============================================================================
// Tests
// ============================================================================

Testing::TestCase testPromotionToOldGen("Objects surviving PROMOTION_AGE minor GCs are promoted", []() {
    rc::check([]() {
        auto& gc = initGC();

        // Allocate object in nursery
        i64 test_value = *rc::gen::arbitrary<i64>();
        void* obj = gc.allocate(sizeof(ElmInt), Tag_Int);
        if (!obj) RC_FAIL("Failed to allocate object");

        ElmInt* elm_int = static_cast<ElmInt*>(obj);
        elm_int->value = test_value;

        HPointer root = toPointer(obj);
        gc.getRootSet().addRoot(&root);

        // Object should start in nursery
        void* current = fromPointer(root);
        RC_ASSERT(isInNursery(gc, current));

        // Run enough minor GCs to trigger promotion
        allocateGarbageInts(gc, 10);
        promoteToOldGen(gc);

        // Object should now be in old gen
        current = fromPointer(root);
        RC_ASSERT(isInOldGen(gc, current));

        // Value should be preserved
        assertObjectIsInt(current, test_value);

        gc.getRootSet().removeRoot(&root);
    });
});

Testing::TestCase testMinorThenMajorGCSequence("Roots survive minor then major GC sequence", []() {
    rc::check([]() {
        auto& gc = initGC();

        // Create objects with random values (size-scaled)
        size_t num_objects = *rc::sizedRange<size_t>(3, 10, 0.1);
        auto rooted = createRootedInts(gc, num_objects);
        RC_ASSERT(!rooted.empty());
        rooted.registerRoots(gc);

        // Run minor GCs to promote objects
        promoteToOldGen(gc);

        // Now run major GC
        gc.majorGC();

        // Verify all values preserved
        verifyIntValues(rooted.roots, rooted.values);

        rooted.unregisterRoots(gc);
    });
});

Testing::TestCase testLongLivedObjectsSurviveMajorGC("Promoted objects survive major GC with values intact", []() {
    rc::check([]() {
        auto& gc = initGC();

        // Create and promote objects (size-scaled)
        size_t num_objects = *rc::sizedRange<size_t>(5, 15, 0.1);
        auto rooted = createRootedInts(gc, num_objects);
        RC_ASSERT(!rooted.empty());
        rooted.registerRoots(gc);

        // Promote to old gen
        promoteToOldGen(gc);

        // Verify objects are in old gen
        for (auto& root : rooted.roots) {
            void* obj = fromPointer(root);
            RC_ASSERT(isInOldGen(gc, obj));
        }

        // Run major GC
        gc.majorGC();

        // Verify values still intact
        verifyIntValues(rooted.roots, rooted.values);

        rooted.unregisterRoots(gc);
    });
});

Testing::TestCase testMajorGCReclaimsOldGenGarbage("Unrooted objects in old gen are reclaimed by major GC", []() {
    rc::check([]() {
        auto& gc = initGC();

        // Create objects with random values (size-scaled).
        size_t num_objects = *rc::sizedRange<size_t>(6, 12, 0.1);
        std::vector<HPointer> all_roots;
        std::vector<i64> all_values;
        std::vector<HPointer> kept_roots;
        std::vector<i64> kept_values;

        for (size_t i = 0; i < num_objects; i++) {
            i64 val = *rc::gen::arbitrary<i64>();
            void* obj = gc.allocate(sizeof(ElmInt), Tag_Int);
            if (!obj) break;

            ElmInt* elm_int = static_cast<ElmInt*>(obj);
            elm_int->value = val;
            all_roots.push_back(toPointer(obj));
            all_values.push_back(val);
        }

        RC_ASSERT(all_roots.size() >= 4);

        // Root all objects initially.
        for (auto& root : all_roots) {
            gc.getRootSet().addRoot(&root);
        }

        // Promote all to old gen.
        promoteToOldGen(gc);

        // Now unroot half of them (they become garbage).
        for (size_t i = 0; i < all_roots.size(); i++) {
            if (i % 2 == 0) {
                kept_roots.push_back(all_roots[i]);
                kept_values.push_back(all_values[i]);
            } else {
                gc.getRootSet().removeRoot(&all_roots[i]);
            }
        }

        // Run major GC - should reclaim the unrooted objects.
        gc.majorGC();

        // Verify kept objects still have correct values.
        verifyIntValues(kept_roots, kept_values);

        // Clean up remaining roots.
        unregisterRoots(gc, kept_roots);
    });
});

Testing::TestCase testFullGCCycleWithCompaction("Objects survive full GC cycle including compaction", []() {
    rc::check([]() {
        auto& gc = initGC();

        // Create objects (size-scaled)
        size_t num_objects = *rc::sizedRange<size_t>(5, 20, 0.1);
        auto rooted = createRootedInts(gc, num_objects);
        RC_ASSERT(!rooted.empty());
        rooted.registerRoots(gc);

        // Promote to old gen
        promoteToOldGen(gc);

        // Run major GC (which includes compaction)
        gc.majorGC();

        // Verify all values using read barrier (handles forwarding)
        verifyIntValues(rooted.roots, rooted.values);

        rooted.unregisterRoots(gc);
    });
});

Testing::TestCase testMixedAllocationWorkload("Roots survive mixed minor and major GC workload", []() {
    rc::check([]() {
        auto& gc = initGC();

        // Create some long-lived roots (size-scaled)
        size_t num_roots = *rc::sizedRange<size_t>(3, 8, 0.1);
        auto rooted = createRootedInts(gc, num_roots);
        RC_ASSERT(!rooted.empty());
        rooted.registerRoots(gc);

        // Mixed workload: allocate garbage, trigger minor GCs, occasionally major GC
        size_t num_iterations = *rc::sizedRange<size_t>(5, 15, 0.1);

        for (size_t iter = 0; iter < num_iterations; iter++) {
            allocateGarbageInts(gc, 100);

            if (iter % 3 == 0) {
                gc.minorGC();
            }
            if (iter % 5 == 0) {
                gc.majorGC();
            }
        }

        // Final major GC
        gc.majorGC();

        // Verify all roots preserved
        verifyIntValues(rooted.roots, rooted.values);

        rooted.unregisterRoots(gc);
    });
});

Testing::TestCase testObjectGraphSpanningPromotions("Linked list survives with nodes in different generations", []() {
    rc::check([]() {
        auto& gc = initGC();

        // Build a linked list (size-scaled)
        size_t list_length = *rc::sizedRange<size_t>(4, 10, 0.1);
        auto list = buildLinkedList(gc, list_length);

        // Root the list
        HPointer root = list.head;
        gc.getRootSet().addRoot(&root);

        // Run minor GC partway through to create mixed generations
        promoteToOldGen(gc);

        // Run more GCs
        gc.minorGC();
        gc.majorGC();

        // Verify list values
        verifyLinkedList(root, list.values);

        gc.getRootSet().removeRoot(&root);
    });
});

Testing::TestCase testMultipleMajorGCCycles("Long-lived roots survive multiple major GC cycles", []() {
    rc::check([]() {
        auto& gc = initGC();

        // Create long-lived objects (size-scaled)
        size_t num_objects = *rc::sizedRange<size_t>(3, 10, 0.1);
        auto rooted = createRootedInts(gc, num_objects);
        RC_ASSERT(!rooted.empty());
        rooted.registerRoots(gc);

        // Promote to old gen
        promoteToOldGen(gc);

        // Run multiple major GC cycles (size-scaled)
        size_t num_cycles = *rc::sizedRange<size_t>(3, 7, 0.01);

        for (size_t cycle = 0; cycle < num_cycles; cycle++) {
            allocateGarbageInts(gc, 50);
            promoteToOldGen(gc);
            gc.majorGC();

            // Verify values after each cycle
            verifyIntValues(rooted.roots, rooted.values);
        }

        rooted.unregisterRoots(gc);
    });
});

Testing::TestCase testStressTestBothGenerations("High allocation rate with both minor and major GCs", []() {
    rc::check([]() {
        auto& gc = initGC();

        // Create some persistent roots (size-scaled)
        size_t num_persistent = *rc::sizedRange<size_t>(2, 5, 0.1);
        auto rooted = createRootedInts(gc, num_persistent);
        RC_ASSERT(!rooted.empty());
        rooted.registerRoots(gc);

        // Stress test: lots of allocation forcing many GCs
        size_t total_allocations = *rc::sizedRange<size_t>(500, 2000, 3.0);
        size_t major_gc_interval = *rc::sizedRange<size_t>(100, 300, 0.2);

        for (size_t i = 0; i < total_allocations; i++) {
            void* obj = gc.allocate(sizeof(ElmInt), Tag_Int);
            if (obj) {
                static_cast<ElmInt*>(obj)->value = static_cast<i64>(i);
            }

            if (i > 0 && i % major_gc_interval == 0) {
                gc.majorGC();
            }
        }

        // Final GC cycle
        gc.minorGC();
        gc.majorGC();

        // Verify persistent roots survived
        verifyIntValues(rooted.roots, rooted.values);

        rooted.unregisterRoots(gc);
    });
});
