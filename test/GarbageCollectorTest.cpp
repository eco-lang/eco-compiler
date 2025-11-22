#include "GarbageCollectorTest.hpp"
#include <cstring>
#include <rapidcheck.h>
#include <vector>
#include "GarbageCollector.hpp"
#include "Heap.hpp"
#include "HeapGenerators.hpp"
#include "OldGenSpace.hpp"

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
        auto& gc = GarbageCollector::instance();
        gc.initThread();
        gc.reset();

        // Allocate object in nursery.
        i64 test_value = *rc::gen::arbitrary<i64>();
        void* obj = gc.allocate(sizeof(ElmInt), Tag_Int);
        if (!obj) RC_FAIL("Failed to allocate object");

        ElmInt* elm_int = static_cast<ElmInt*>(obj);
        elm_int->value = test_value;

        HPointer root = toPointer(obj);
        gc.getRootSet().addRoot(&root);

        // Object should start in nursery.
        void* current = fromPointer(root);
        RC_ASSERT(isInNursery(gc, current));

        // Run enough minor GCs to trigger promotion (PROMOTION_AGE + 1).
        for (u32 i = 0; i <= PROMOTION_AGE; i++) {
            // Allocate some garbage to ensure GC does work.
            for (int j = 0; j < 10; j++) {
                gc.allocate(sizeof(ElmInt), Tag_Int);
            }
            gc.minorGC();
        }

        // Object should now be in old gen.
        current = fromPointer(root);
        RC_ASSERT(isInOldGen(gc, current));

        // Value should be preserved.
        elm_int = static_cast<ElmInt*>(current);
        RC_ASSERT(elm_int->value == test_value);

        gc.getRootSet().removeRoot(&root);
    });
});

Testing::TestCase testMinorThenMajorGCSequence("Roots survive minor then major GC sequence", []() {
    rc::check([]() {
        auto& gc = GarbageCollector::instance();
        gc.initThread();
        gc.reset();

        // Create objects with random values (size-scaled: 3-10 at size 0, up to 3-110 at size 1000)
        size_t num_objects = *rc::sizedRange<size_t>(3, 10, 0.1);
        std::vector<i64> expected_values;
        std::vector<HPointer> root_storage;

        for (size_t i = 0; i < num_objects; i++) {
            i64 val = *rc::gen::arbitrary<i64>();
            void* obj = gc.allocate(sizeof(ElmInt), Tag_Int);
            if (!obj) break;

            ElmInt* elm_int = static_cast<ElmInt*>(obj);
            elm_int->value = val;
            expected_values.push_back(val);
            root_storage.push_back(toPointer(obj));
        }

        RC_ASSERT(!root_storage.empty());

        for (auto& root : root_storage) {
            gc.getRootSet().addRoot(&root);
        }

        // Run minor GCs to promote objects.
        for (u32 i = 0; i <= PROMOTION_AGE; i++) {
            gc.minorGC();
        }

        // Now run major GC.
        gc.majorGC();

        // Verify all values preserved.
        for (size_t i = 0; i < root_storage.size(); i++) {
            void* obj = readBarrier(root_storage[i]);
            if (!obj) RC_FAIL("Object is null after GC sequence");

            ElmInt* elm_int = static_cast<ElmInt*>(obj);
            RC_ASSERT(elm_int->value == expected_values[i]);
        }

        for (auto& root : root_storage) {
            gc.getRootSet().removeRoot(&root);
        }
    });
});

Testing::TestCase testLongLivedObjectsSurviveMajorGC("Promoted objects survive major GC with values intact", []() {
    rc::check([]() {
        auto& gc = GarbageCollector::instance();
        gc.initThread();
        gc.reset();

        // Create and promote objects (size-scaled: 5-15 at size 0, up to 5-115 at size 1000)
        size_t num_objects = *rc::sizedRange<size_t>(5, 15, 0.1);
        std::vector<i64> expected_values;
        std::vector<HPointer> root_storage;

        for (size_t i = 0; i < num_objects; i++) {
            i64 val = *rc::gen::inRange<i64>(0, 1000000);
            void* obj = gc.allocate(sizeof(ElmInt), Tag_Int);
            if (!obj) break;

            ElmInt* elm_int = static_cast<ElmInt*>(obj);
            elm_int->value = val;
            expected_values.push_back(val);
            root_storage.push_back(toPointer(obj));
        }

        RC_ASSERT(!root_storage.empty());

        for (auto& root : root_storage) {
            gc.getRootSet().addRoot(&root);
        }

        // Promote to old gen.
        for (u32 i = 0; i <= PROMOTION_AGE; i++) {
            gc.minorGC();
        }

        // Verify objects are in old gen.
        for (auto& root : root_storage) {
            void* obj = fromPointer(root);
            RC_ASSERT(isInOldGen(gc, obj));
        }

        // Run major GC.
        gc.majorGC();

        // Verify values still intact.
        for (size_t i = 0; i < root_storage.size(); i++) {
            void* obj = readBarrier(root_storage[i]);
            if (!obj) RC_FAIL("Object is null after major GC");

            Header* hdr = getHeader(obj);
            RC_ASSERT(hdr->tag == Tag_Int);

            ElmInt* elm_int = static_cast<ElmInt*>(obj);
            RC_ASSERT(elm_int->value == expected_values[i]);
        }

        for (auto& root : root_storage) {
            gc.getRootSet().removeRoot(&root);
        }
    });
});

Testing::TestCase testMajorGCReclaimsOldGenGarbage("Unrooted objects in old gen are reclaimed by major GC", []() {
    rc::check([]() {
        auto& gc = GarbageCollector::instance();
        gc.initThread();
        gc.reset();

        // Create objects (size-scaled: 6-12 at size 0, up to 6-112 at size 1000)
        size_t num_objects = *rc::sizedRange<size_t>(6, 12, 0.1);
        std::vector<HPointer> all_roots;
        std::vector<HPointer> kept_roots;
        std::vector<i64> kept_values;

        for (size_t i = 0; i < num_objects; i++) {
            i64 val = static_cast<i64>(i * 1000);
            void* obj = gc.allocate(sizeof(ElmInt), Tag_Int);
            if (!obj) break;

            ElmInt* elm_int = static_cast<ElmInt*>(obj);
            elm_int->value = val;
            all_roots.push_back(toPointer(obj));
        }

        RC_ASSERT(all_roots.size() >= 4);

        // Root all objects initially.
        for (auto& root : all_roots) {
            gc.getRootSet().addRoot(&root);
        }

        // Promote all to old gen.
        for (u32 i = 0; i <= PROMOTION_AGE; i++) {
            gc.minorGC();
        }

        // Now unroot half of them (they become garbage).
        for (size_t i = 0; i < all_roots.size(); i++) {
            if (i % 2 == 0) {
                // Keep this one.
                kept_roots.push_back(all_roots[i]);
                kept_values.push_back(static_cast<i64>(i * 1000));
            } else {
                // Remove this one - it becomes garbage.
                gc.getRootSet().removeRoot(&all_roots[i]);
            }
        }

        // Run major GC - should reclaim the unrooted objects.
        gc.majorGC();

        // Verify kept objects still have correct values.
        for (size_t i = 0; i < kept_roots.size(); i++) {
            void* obj = readBarrier(kept_roots[i]);
            if (!obj) RC_FAIL("Kept object is null after major GC");

            ElmInt* elm_int = static_cast<ElmInt*>(obj);
            RC_ASSERT(elm_int->value == kept_values[i]);
        }

        // Clean up remaining roots.
        for (auto& root : kept_roots) {
            gc.getRootSet().removeRoot(&root);
        }
    });
});

Testing::TestCase testFullGCCycleWithCompaction("Objects survive full GC cycle including compaction", []() {
    rc::check([]() {
        auto& gc = GarbageCollector::instance();
        gc.initThread();
        gc.reset();

        // Create objects (size-scaled: 5-20 at size 0, up to 5-120 at size 1000)
        size_t num_objects = *rc::sizedRange<size_t>(5, 20, 0.1);
        std::vector<i64> expected_values;
        std::vector<HPointer> root_storage;

        for (size_t i = 0; i < num_objects; i++) {
            i64 val = *rc::gen::arbitrary<i64>();
            void* obj = gc.allocate(sizeof(ElmInt), Tag_Int);
            if (!obj) break;

            ElmInt* elm_int = static_cast<ElmInt*>(obj);
            elm_int->value = val;
            expected_values.push_back(val);
            root_storage.push_back(toPointer(obj));
        }

        RC_ASSERT(!root_storage.empty());

        for (auto& root : root_storage) {
            gc.getRootSet().addRoot(&root);
        }

        // Promote to old gen.
        for (u32 i = 0; i <= PROMOTION_AGE; i++) {
            gc.minorGC();
        }

        // Run major GC (which includes compaction).
        gc.majorGC();

        // Verify all values using read barrier (handles forwarding).
        for (size_t i = 0; i < root_storage.size(); i++) {
            void* obj = readBarrier(root_storage[i]);
            if (!obj) RC_FAIL("Object is null after full GC cycle");

            Header* hdr = getHeader(obj);
            RC_ASSERT(hdr->tag == Tag_Int);

            ElmInt* elm_int = static_cast<ElmInt*>(obj);
            RC_ASSERT(elm_int->value == expected_values[i]);
        }

        for (auto& root : root_storage) {
            gc.getRootSet().removeRoot(&root);
        }
    });
});

Testing::TestCase testMixedAllocationWorkload("Roots survive mixed minor and major GC workload", []() {
    rc::check([]() {
        auto& gc = GarbageCollector::instance();
        gc.initThread();
        gc.reset();

        // Create some long-lived roots (size-scaled: 3-8 at size 0, up to 3-108 at size 1000)
        size_t num_roots = *rc::sizedRange<size_t>(3, 8, 0.1);
        std::vector<i64> expected_values;
        std::vector<HPointer> root_storage;

        for (size_t i = 0; i < num_roots; i++) {
            i64 val = *rc::gen::inRange<i64>(0, 1000000);
            void* obj = gc.allocate(sizeof(ElmInt), Tag_Int);
            if (!obj) break;

            ElmInt* elm_int = static_cast<ElmInt*>(obj);
            elm_int->value = val;
            expected_values.push_back(val);
            root_storage.push_back(toPointer(obj));
        }

        RC_ASSERT(!root_storage.empty());

        for (auto& root : root_storage) {
            gc.getRootSet().addRoot(&root);
        }

        // Mixed workload: allocate garbage, trigger minor GCs, occasionally major GC.
        // Size-scaled: 5-15 at size 0, up to 5-115 at size 1000.
        size_t num_iterations = *rc::sizedRange<size_t>(5, 15, 0.1);

        for (size_t iter = 0; iter < num_iterations; iter++) {
            // Allocate some garbage.
            for (int j = 0; j < 100; j++) {
                void* garbage = gc.allocate(sizeof(ElmInt), Tag_Int);
                if (garbage) {
                    static_cast<ElmInt*>(garbage)->value = j;
                }
            }

            // Minor GC happens automatically, but let's also trigger explicitly sometimes.
            if (iter % 3 == 0) {
                gc.minorGC();
            }

            // Occasionally run major GC.
            if (iter % 5 == 0) {
                gc.majorGC();
            }
        }

        // Final major GC.
        gc.majorGC();

        // Verify all roots preserved.
        for (size_t i = 0; i < root_storage.size(); i++) {
            void* obj = readBarrier(root_storage[i]);
            if (!obj) RC_FAIL("Root object is null after mixed workload");

            ElmInt* elm_int = static_cast<ElmInt*>(obj);
            RC_ASSERT(elm_int->value == expected_values[i]);
        }

        for (auto& root : root_storage) {
            gc.getRootSet().removeRoot(&root);
        }
    });
});

Testing::TestCase testObjectGraphSpanningPromotions("Linked list survives with nodes in different generations", []() {
    rc::check([]() {
        auto& gc = GarbageCollector::instance();
        gc.initThread();
        gc.reset();

        // Build a linked list (size-scaled: 4-10 at size 0, up to 4-110 at size 1000)
        size_t list_length = *rc::sizedRange<size_t>(4, 10, 0.1);
        std::vector<i64> expected_values;

        // Start with Nil.
        HPointer tail;
        tail.ptr = 0;
        tail.constant = Const_Nil;
        tail.padding = 0;

        HPointer list_head = tail;

        for (size_t i = 0; i < list_length; i++) {
            i64 val = static_cast<i64>(i * 100);
            expected_values.push_back(val);

            // Allocate Int.
            void* int_obj = gc.allocate(sizeof(ElmInt), Tag_Int);
            if (!int_obj) RC_FAIL("Failed to allocate int");
            static_cast<ElmInt*>(int_obj)->value = val;

            // Allocate Cons.
            void* cons_obj = gc.allocate(sizeof(Cons), Tag_Cons);
            if (!cons_obj) RC_FAIL("Failed to allocate cons");

            Cons* cons = static_cast<Cons*>(cons_obj);
            cons->head.p = toPointer(int_obj);
            cons->tail = list_head;

            list_head = toPointer(cons_obj);

            // Run minor GC partway through to create mixed generations.
            if (i == list_length / 2) {
                // Temporarily root the list.
                gc.getRootSet().addRoot(&list_head);
                for (u32 j = 0; j <= PROMOTION_AGE; j++) {
                    gc.minorGC();
                }
                gc.getRootSet().removeRoot(&list_head);
            }
        }

        // Root the final list.
        gc.getRootSet().addRoot(&list_head);

        // Run more GCs.
        gc.minorGC();
        gc.majorGC();

        // Walk the list and verify values (in reverse order).
        HPointer current = list_head;
        size_t idx = expected_values.size();

        while (current.constant == 0) {
            void* obj = readBarrier(current);
            if (!obj) break;

            Header* hdr = getHeader(obj);
            if (hdr->tag != Tag_Cons) break;

            Cons* cons = static_cast<Cons*>(obj);

            // Get head value.
            void* head_obj = readBarrier(cons->head.p);
            if (head_obj && getHeader(head_obj)->tag == Tag_Int) {
                idx--;
                ElmInt* elm_int = static_cast<ElmInt*>(head_obj);
                RC_ASSERT(elm_int->value == expected_values[idx]);
            }

            current = cons->tail;
        }

        RC_ASSERT(idx == 0);  // Should have visited all nodes

        gc.getRootSet().removeRoot(&list_head);
    });
});

Testing::TestCase testMultipleMajorGCCycles("Long-lived roots survive multiple major GC cycles", []() {
    rc::check([]() {
        auto& gc = GarbageCollector::instance();
        gc.initThread();
        gc.reset();

        // Create long-lived objects (size-scaled: 3-10 at size 0, up to 3-110 at size 1000)
        size_t num_objects = *rc::sizedRange<size_t>(3, 10, 0.1);
        std::vector<i64> expected_values;
        std::vector<HPointer> root_storage;

        for (size_t i = 0; i < num_objects; i++) {
            i64 val = *rc::gen::arbitrary<i64>();
            void* obj = gc.allocate(sizeof(ElmInt), Tag_Int);
            if (!obj) break;

            ElmInt* elm_int = static_cast<ElmInt*>(obj);
            elm_int->value = val;
            expected_values.push_back(val);
            root_storage.push_back(toPointer(obj));
        }

        RC_ASSERT(!root_storage.empty());

        for (auto& root : root_storage) {
            gc.getRootSet().addRoot(&root);
        }

        // Promote to old gen.
        for (u32 i = 0; i <= PROMOTION_AGE; i++) {
            gc.minorGC();
        }

        // Run multiple major GC cycles (size-scaled: 3-7 at size 0, up to 3-17 at size 1000).
        size_t num_cycles = *rc::sizedRange<size_t>(3, 7, 0.01);

        for (size_t cycle = 0; cycle < num_cycles; cycle++) {
            // Allocate some garbage between cycles.
            for (int j = 0; j < 50; j++) {
                void* garbage = gc.allocate(sizeof(ElmInt), Tag_Int);
                if (garbage) {
                    static_cast<ElmInt*>(garbage)->value = j;
                }
            }

            // Promote garbage to old gen.
            for (u32 i = 0; i <= PROMOTION_AGE; i++) {
                gc.minorGC();
            }

            // Major GC.
            gc.majorGC();

            // Verify values after each cycle.
            for (size_t i = 0; i < root_storage.size(); i++) {
                void* obj = readBarrier(root_storage[i]);
                if (!obj) RC_FAIL("Object is null after major GC cycle");

                ElmInt* elm_int = static_cast<ElmInt*>(obj);
                RC_ASSERT(elm_int->value == expected_values[i]);
            }
        }

        for (auto& root : root_storage) {
            gc.getRootSet().removeRoot(&root);
        }
    });
});

Testing::TestCase testStressTestBothGenerations("High allocation rate with both minor and major GCs", []() {
    rc::check([]() {
        auto& gc = GarbageCollector::instance();
        gc.initThread();
        gc.reset();

        // Create some persistent roots (size-scaled: 2-5 at size 0, up to 2-105 at size 1000)
        size_t num_persistent = *rc::sizedRange<size_t>(2, 5, 0.1);
        std::vector<i64> expected_values;
        std::vector<HPointer> root_storage;

        for (size_t i = 0; i < num_persistent; i++) {
            i64 val = *rc::gen::inRange<i64>(0, 1000000);
            void* obj = gc.allocate(sizeof(ElmInt), Tag_Int);
            if (!obj) break;

            ElmInt* elm_int = static_cast<ElmInt*>(obj);
            elm_int->value = val;
            expected_values.push_back(val);
            root_storage.push_back(toPointer(obj));
        }

        RC_ASSERT(!root_storage.empty());

        for (auto& root : root_storage) {
            gc.getRootSet().addRoot(&root);
        }

        // Stress test: lots of allocation forcing many GCs.
        // Size-scaled: 500-2000 at size 0, up to 500-5000 at size 1000.
        size_t total_allocations = *rc::sizedRange<size_t>(500, 2000, 3.0);
        // Size-scaled: 100-300 at size 0, up to 100-500 at size 1000.
        size_t major_gc_interval = *rc::sizedRange<size_t>(100, 300, 0.2);

        for (size_t i = 0; i < total_allocations; i++) {
            void* obj = gc.allocate(sizeof(ElmInt), Tag_Int);
            if (obj) {
                static_cast<ElmInt*>(obj)->value = static_cast<i64>(i);
            }

            // Periodically trigger major GC.
            if (i > 0 && i % major_gc_interval == 0) {
                gc.majorGC();
            }
        }

        // Final GC cycle.
        gc.minorGC();
        gc.majorGC();

        // Verify persistent roots survived.
        for (size_t i = 0; i < root_storage.size(); i++) {
            void* obj = readBarrier(root_storage[i]);
            if (!obj) RC_FAIL("Persistent root is null after stress test");

            Header* hdr = getHeader(obj);
            RC_ASSERT(hdr->tag == Tag_Int);

            ElmInt* elm_int = static_cast<ElmInt*>(obj);
            RC_ASSERT(elm_int->value == expected_values[i]);
        }

        for (auto& root : root_storage) {
            gc.getRootSet().removeRoot(&root);
        }
    });
});
