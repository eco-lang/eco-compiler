#include "AllocatorTest.hpp"
#include <cstring>
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

Testing::TestCase testPromotionToOldGen("Objects surviving PROMOTION_AGE minor GCs are promoted", []() {
    rc::check([](const HeapGraphDesc& graph) {
        auto& alloc = initAllocator();

        // Allocate complex heap graph in nursery.
        std::vector<void*> objects = allocateHeapGraph(graph.nodes);
        RC_ASSERT(!objects.empty());

        // Set up roots from graph description (RAII - auto-unregisters).
        GraphRoots roots = setupRootsFromGraph(alloc, graph, objects);
        RC_ASSERT(!roots.empty());

        // Take snapshot before promotion.
        HeapSnapshot snapshot;
        snapshot.capture(objects, roots.ptrs);

        // All rooted objects should start in nursery.
        for (auto* root_ptr : roots.ptrs) {
            void* obj = AllocatorTestAccess::fromPointer(*root_ptr);
            RC_ASSERT(alloc.isInNursery(obj));
        }

        // Run enough minor GCs to trigger promotion (PROMOTION_AGE + 1).
        for (u32 i = 0; i <= PROMOTION_AGE; i++) {
            // Allocate some garbage to ensure GC does work.
            allocateGarbageInts(alloc, 10);
            alloc.minorGC();
        }

        // All rooted objects should now be in old gen.
        for (auto* root_ptr : roots.ptrs) {
            void* obj = readBarrier(*root_ptr);
            RC_ASSERT(alloc.isInOldGen(obj));
        }

        // Verify all roots still intact and values preserved.
        bool valid = snapshot.verify(roots.ptrs);
        RC_ASSERT(valid);
    });
});

Testing::TestCase testMinorThenMajorGCSequence("Roots survive minor then major GC sequence", []() {
    rc::check([](const HeapGraphDesc& graph) {
        auto& alloc = initAllocator();

        // Allocate complex heap graph in nursery.
        std::vector<void*> objects = allocateHeapGraph(graph.nodes);
        RC_ASSERT(!objects.empty());

        // Set up roots from graph description (RAII - auto-unregisters).
        GraphRoots roots = setupRootsFromGraph(alloc, graph, objects);
        RC_ASSERT(!roots.empty());

        // Take snapshot before GC sequence.
        HeapSnapshot snapshot;
        snapshot.capture(objects, roots.ptrs);

        // Run minor GCs to promote objects.
        for (u32 i = 0; i <= PROMOTION_AGE; i++) {
            alloc.minorGC();
        }

        // Now run major GC.
        alloc.majorGC();

        // Verify all roots still intact and values preserved.
        bool valid = snapshot.verify(roots.ptrs);
        RC_ASSERT(valid);
    });
});

Testing::TestCase testLongLivedObjectsSurviveMajorGC("Promoted objects survive major GC with values intact", []() {
    rc::check([](const HeapGraphDesc& graph) {
        auto& alloc = initAllocator();

        // Allocate complex heap graph in nursery.
        std::vector<void*> objects = allocateHeapGraph(graph.nodes);
        RC_ASSERT(!objects.empty());

        // Set up roots from graph description (RAII - auto-unregisters).
        GraphRoots roots = setupRootsFromGraph(alloc, graph, objects);
        RC_ASSERT(!roots.empty());

        // Take snapshot before promotion.
        HeapSnapshot snapshot;
        snapshot.capture(objects, roots.ptrs);

        // Promote to old gen.
        for (u32 i = 0; i <= PROMOTION_AGE; i++) {
            alloc.minorGC();
        }

        // Verify rooted objects are in old gen.
        for (auto* root_ptr : roots.ptrs) {
            void* obj = readBarrier(*root_ptr);
            RC_ASSERT(alloc.isInOldGen(obj));
        }

        // Run major GC.
        alloc.majorGC();

        // Verify all roots still intact and values preserved.
        bool valid = snapshot.verify(roots.ptrs);
        RC_ASSERT(valid);
    });
});

Testing::TestCase testMajorGCReclaimsOldGenGarbage("Unrooted objects in old gen are reclaimed by major GC", []() {
    rc::check([](const HeapGraphDesc& graph) {
        auto& alloc = initAllocator();

        // Allocate complex heap graph in nursery.
        std::vector<void*> objects = allocateHeapGraph(graph.nodes);
        RC_ASSERT(!objects.empty());

        // Set up roots from graph description (RAII - auto-unregisters).
        // This roots only the designated roots, not all objects.
        GraphRoots roots = setupRootsFromGraph(alloc, graph, objects);
        RC_ASSERT(!roots.empty());

        // Take snapshot of rooted objects before promotion.
        HeapSnapshot snapshot;
        snapshot.capture(objects, roots.ptrs);

        // Promote all to old gen.
        for (u32 i = 0; i <= PROMOTION_AGE; i++) {
            alloc.minorGC();
        }

        // Now allocate MORE garbage (unrooted) directly in the heap.
        // This garbage will be promoted and then collected.
        allocateGarbageInts(alloc, 50);

        // Promote garbage to old gen.
        for (u32 i = 0; i <= PROMOTION_AGE; i++) {
            alloc.minorGC();
        }

        // Run major GC - should reclaim the unrooted garbage.
        alloc.majorGC();

        // Verify rooted objects still intact.
        bool valid = snapshot.verify(roots.ptrs);
        RC_ASSERT(valid);
    });
});

Testing::TestCase testFullGCCycle("Objects survive full GC cycle", []() {
    rc::check([](const HeapGraphDesc& graph) {
        auto& alloc = initAllocator();

        // Allocate complex heap graph in nursery.
        std::vector<void*> objects = allocateHeapGraph(graph.nodes);
        RC_ASSERT(!objects.empty());

        // Set up roots from graph description (RAII - auto-unregisters).
        GraphRoots roots = setupRootsFromGraph(alloc, graph, objects);
        RC_ASSERT(!roots.empty());

        // Take snapshot before GC cycle.
        HeapSnapshot snapshot;
        snapshot.capture(objects, roots.ptrs);

        // Promote to old gen.
        for (u32 i = 0; i <= PROMOTION_AGE; i++) {
            alloc.minorGC();
        }

        // Run major GC.
        alloc.majorGC();

        // Verify all roots still intact and values preserved.
        bool valid = snapshot.verify(roots.ptrs);
        RC_ASSERT(valid);
    });
});

Testing::TestCase testMixedAllocationWorkload("Roots survive mixed minor and major GC workload", []() {
    rc::check([](const HeapGraphDesc& graph) {
        // Use heap scaled to RapidCheck size to handle larger test inputs.
        int rc_size = *rc::currentSize();
        auto& alloc = initAllocatorScaled(rc_size);

        // Allocate complex heap graph in nursery.
        std::vector<void*> objects = allocateHeapGraph(graph.nodes);
        RC_ASSERT(!objects.empty());

        // Set up roots from graph description (RAII - auto-unregisters).
        GraphRoots roots = setupRootsFromGraph(alloc, graph, objects);
        RC_ASSERT(!roots.empty());

        // Take snapshot before workload.
        HeapSnapshot snapshot;
        snapshot.capture(objects, roots.ptrs);

        // Mixed workload: allocate garbage, trigger minor GCs, occasionally major GC.
        // Size-scaled: 5-15 at size 0, up to 5-115 at size 1000.
        size_t num_iterations = *rc::sizedRange<size_t>(5, 15, 0.1);

        for (size_t iter = 0; iter < num_iterations; iter++) {
            // Allocate some garbage.
            allocateGarbageInts(alloc, 100);

            // Minor GC happens automatically, but let's also trigger explicitly sometimes.
            if (iter % 3 == 0) {
                alloc.minorGC();
            }

            // Occasionally run major GC.
            if (iter % 5 == 0) {
                alloc.majorGC();
            }
        }

        // Final major GC.
        alloc.majorGC();

        // Verify all roots still intact and values preserved.
        bool valid = snapshot.verify(roots.ptrs);
        RC_ASSERT(valid);
    });
});

Testing::TestCase testObjectGraphSpanningPromotions("Linked list survives with nodes in different generations", []() {
    rc::check([]() {
        auto& alloc = initAllocator();

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
            void* int_obj = alloc.allocate(sizeof(ElmInt), Tag_Int);
            if (!int_obj) RC_FAIL("Failed to allocate int");
            static_cast<ElmInt*>(int_obj)->value = val;

            // Allocate Cons.
            void* cons_obj = alloc.allocate(sizeof(Cons), Tag_Cons);
            if (!cons_obj) RC_FAIL("Failed to allocate cons");

            Cons* cons = static_cast<Cons*>(cons_obj);
            cons->head.p = AllocatorTestAccess::toPointer(int_obj);
            cons->tail = list_head;

            list_head = AllocatorTestAccess::toPointer(cons_obj);

            // Run minor GC partway through to create mixed generations.
            if (i == list_length / 2) {
                // Temporarily root the list.
                alloc.getRootSet().addRoot(&list_head);
                for (u32 j = 0; j <= PROMOTION_AGE; j++) {
                    alloc.minorGC();
                }
                alloc.getRootSet().removeRoot(&list_head);
            }
        }

        // Root the final list.
        alloc.getRootSet().addRoot(&list_head);

        // Run more GCs.
        alloc.minorGC();
        alloc.majorGC();

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

        alloc.getRootSet().removeRoot(&list_head);
    });
});

Testing::TestCase testMultipleMajorGCCycles("Long-lived roots survive multiple major GC cycles", []() {
    rc::check([](const HeapGraphDesc& graph) {
        auto& alloc = initAllocator();

        // Allocate complex heap graph in nursery.
        std::vector<void*> objects = allocateHeapGraph(graph.nodes);
        RC_ASSERT(!objects.empty());

        // Set up roots from graph description (RAII - auto-unregisters).
        GraphRoots roots = setupRootsFromGraph(alloc, graph, objects);
        RC_ASSERT(!roots.empty());

        // Take snapshot before GC cycles.
        HeapSnapshot snapshot;
        snapshot.capture(objects, roots.ptrs);

        // Promote to old gen.
        for (u32 i = 0; i <= PROMOTION_AGE; i++) {
            alloc.minorGC();
        }

        // Run multiple major GC cycles (size-scaled: 3-7 at size 0, up to 3-17 at size 1000).
        size_t num_cycles = *rc::sizedRange<size_t>(3, 7, 0.01);

        for (size_t cycle = 0; cycle < num_cycles; cycle++) {
            // Allocate some garbage between cycles.
            allocateGarbageInts(alloc, 50);

            // Promote garbage to old gen.
            for (u32 i = 0; i <= PROMOTION_AGE; i++) {
                alloc.minorGC();
            }

            // Major GC.
            alloc.majorGC();

            // Verify values after each cycle.
            bool valid = snapshot.verify(roots.ptrs);
            RC_ASSERT(valid);
        }
    });
});

Testing::TestCase testStressTestBothGenerations("High allocation rate with both minor and major GCs", []() {
    rc::check([](const HeapGraphDesc& graph) {
        // Use heap scaled to RapidCheck size to handle larger test inputs.
        int rc_size = *rc::currentSize();
        auto& alloc = initAllocatorScaled(rc_size);

        // Allocate complex heap graph in nursery.
        std::vector<void*> objects = allocateHeapGraph(graph.nodes);
        RC_ASSERT(!objects.empty());

        // Set up roots from graph description (RAII - auto-unregisters).
        GraphRoots roots = setupRootsFromGraph(alloc, graph, objects);
        RC_ASSERT(!roots.empty());

        // Take snapshot before stress test.
        HeapSnapshot snapshot;
        snapshot.capture(objects, roots.ptrs);

        // Stress test: lots of allocation forcing many GCs.
        // Size-scaled: 500-2000 at size 0, up to 500-5000 at size 1000.
        size_t total_allocations = *rc::sizedRange<size_t>(500, 2000, 3.0);
        // Size-scaled: 100-300 at size 0, up to 100-500 at size 1000.
        size_t major_gc_interval = *rc::sizedRange<size_t>(100, 300, 0.2);

        for (size_t i = 0; i < total_allocations; i++) {
            void* obj = alloc.allocate(sizeof(ElmInt), Tag_Int);
            if (obj) {
                static_cast<ElmInt*>(obj)->value = static_cast<i64>(i);
            }

            // Periodically trigger major GC.
            if (i > 0 && i % major_gc_interval == 0) {
                alloc.majorGC();
            }
        }

        // Final GC cycle.
        alloc.minorGC();
        alloc.majorGC();

        // Verify all roots still intact and values preserved.
        bool valid = snapshot.verify(roots.ptrs);
        RC_ASSERT(valid);
    });
});
