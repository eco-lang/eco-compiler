#include "NurserySpaceTest.hpp"
#include <rapidcheck.h>
#include <cmath>
#include "HeapGenerators.hpp"
#include "HeapSnapshot.hpp"
#include "TestHelpers.hpp"

using namespace Elm;

// ============================================================================
// Helper: Build a list with unboxed integer heads (more realistic for locality tests)
// ============================================================================

struct UnboxedList {
    HPointer head;
    std::vector<i64> values;
};

// Build a cons list with unboxed integer heads (no separate ElmInt objects).
// This is the common case in Elm and best demonstrates locality benefits.
UnboxedList buildUnboxedList(Allocator& alloc, size_t length) {
    UnboxedList result;
    result.head = createNil();
    result.values.reserve(length);

    for (size_t i = 0; i < length; i++) {
        i64 val = static_cast<i64>(i);  // Use sequential values for easy verification
        result.values.push_back(val);

        // Allocate Cons with unboxed head
        void* cons_obj = alloc.allocate(sizeof(Cons), Tag_Cons);
        if (!cons_obj) RC_FAIL("Failed to allocate cons");

        Cons* cons = static_cast<Cons*>(cons_obj);
        cons->header.unboxed = 1;  // Mark head as unboxed
        cons->head.i = val;        // Store value directly
        cons->tail = result.head;

        result.head = AllocatorTestAccess::toPointer(cons_obj);
    }

    // Reverse values so they match traversal order
    std::reverse(result.values.begin(), result.values.end());

    return result;
}

// Verify an unboxed list has correct values
void verifyUnboxedList(HPointer head, const std::vector<i64>& expected) {
    HPointer current = head;
    size_t idx = 0;

    while (current.constant == 0) {
        void* obj = readBarrier(current);
        if (!obj) break;

        Header* hdr = getHeader(obj);
        if (hdr->tag != Tag_Cons) break;

        Cons* cons = static_cast<Cons*>(obj);

        // Head is unboxed - read value directly
        RC_ASSERT(idx < expected.size());
        RC_ASSERT(cons->head.i == expected[idx]);
        idx++;

        current = cons->tail;
    }

    RC_ASSERT(idx == expected.size());
}

// Measure average address gap between consecutive Cons cells in a list
size_t measureListLocality(HPointer head) {
    std::vector<uintptr_t> addresses;
    HPointer current = head;

    while (current.constant == 0) {
        void* obj = readBarrier(current);
        if (!obj) break;

        Header* hdr = getHeader(obj);
        if (hdr->tag != Tag_Cons) break;

        addresses.push_back(reinterpret_cast<uintptr_t>(obj));
        Cons* cons = static_cast<Cons*>(obj);
        current = cons->tail;
    }

    if (addresses.size() < 2) return 0;

    size_t total_gap = 0;
    for (size_t i = 1; i < addresses.size(); i++) {
        // Use absolute difference (cells may be in ascending or descending order)
        long diff = static_cast<long>(addresses[i]) - static_cast<long>(addresses[i-1]);
        total_gap += static_cast<size_t>(std::abs(diff));
    }

    return total_gap / (addresses.size() - 1);
}

Testing::TestCase testMinorGCPreservesRoots("Minor GC preserves all reachable objects from roots", []() {
        rc::check([](const HeapGraphDesc &graph) {
            auto &alloc = initAllocator();

            // Allocate heap from description (RapidCheck can shrink this!)
            std::vector<void *> allocated_objects = allocateHeapGraph(graph.nodes);
            RC_ASSERT(!allocated_objects.empty());

            // Set up roots from graph description (RAII - auto-unregisters)
            GraphRoots roots = setupRootsFromGraph(alloc, graph, allocated_objects);
            RC_ASSERT(!roots.empty());

            // Take snapshot before GC
            HeapSnapshot snapshot;
            snapshot.capture(allocated_objects, roots.ptrs);

            // Perform minor GC
            alloc.minorGC();

            // Verify all roots still intact and valid
            bool valid = snapshot.verify(roots.ptrs);
            RC_ASSERT(valid);
        });
});

Testing::TestCase testMultipleMinorGCCycles("Multiple minor GC cycles preserve roots correctly", []() {
        rc::check([](const HeapGraphDesc &graph) {
            // Size-scaled: num_cycles 2-5 at size 0, up to 2-15 at size 1000
            int num_cycles = *rc::sizedRange<int>(2, 5, 0.01);

            auto &alloc = initAllocator();

            // Allocate complex heap graph as long-lived roots.
            std::vector<void *> allocated_objects = allocateHeapGraph(graph.nodes);
            RC_ASSERT(!allocated_objects.empty());

            // Set up roots from graph description (RAII - auto-unregisters)
            GraphRoots roots = setupRootsFromGraph(alloc, graph, allocated_objects);
            RC_ASSERT(!roots.empty());

            // Take snapshot before GC cycles
            HeapSnapshot snapshot;
            snapshot.capture(allocated_objects, roots.ptrs);

            // Run multiple GC cycles with garbage allocation between them.
            for (int i = 0; i < num_cycles; i++) {
                // Allocate some garbage between cycles.
                allocateGarbageInts(alloc, 50);

                alloc.minorGC();

                // Verify roots still valid after each cycle.
                bool valid = snapshot.verify(roots.ptrs);
                RC_ASSERT(valid);
            }
        });
});

Testing::TestCase testContinuousGarbageAllocation("Continuous garbage allocation triggers automatic GC and recycles space", []() {
        rc::check([](const HeapGraphDesc &graph) {
            // Use heap size scaled to RapidCheck size to handle larger test inputs.
            int rc_size = *rc::currentSize();
            auto& alloc = initAllocatorScaled(rc_size);
            auto *nursery = AllocatorTestAccess::getNursery(alloc);

            if (nursery == nullptr) {
                RC_DISCARD("Nursery not available");
            }

            // Get scaled config to calculate target allocation.
            HeapConfig config = scaledHeapConfig(rc_size);
            size_t nursery_capacity = config.nurserySize() / 2;
            size_t target_allocation = nursery_capacity * 2;

            // Allocate complex heap graph in nursery.
            std::vector<void*> objects = allocateHeapGraph(graph.nodes);
            RC_ASSERT(!objects.empty());

            // Set up roots from graph description (RAII - auto-unregisters).
            GraphRoots roots = setupRootsFromGraph(alloc, graph, objects);
            RC_ASSERT(!roots.empty());

            // Take snapshot of root objects before continuous allocation.
            HeapSnapshot snapshot;
            snapshot.capture(objects, roots.ptrs);

            // Continuously allocate garbage (unrooted objects) until we've allocated 2x the nursery capacity.
            size_t total_allocated = 0;
            size_t allocation_count = 0;

            while (total_allocated < target_allocation) {
                // Allocate a garbage object (not added to roots).
                // Allocate proper ElmInt objects to avoid uninitialized memory issues.
                size_t obj_size = sizeof(ElmInt);

                void *garbage = alloc.allocate(obj_size, Tag_Int);
                if (garbage == nullptr) {
                    RC_FAIL("Allocation failed - automatic GC should prevent this");
                }

                // Initialize the object properly.
                ElmInt *elm_int = static_cast<ElmInt *>(garbage);
                elm_int->value = allocation_count;

                total_allocated += obj_size;
                allocation_count++;
            }

            // Final verification: all roots still intact and values preserved.
            bool valid = snapshot.verify(roots.ptrs);
            RC_ASSERT(valid);
        });
});

// ============================================================================
// Hybrid DFS/BFS List Tests
// ============================================================================

Testing::TestCase testListSurvivesGCWithHybridDFS("List survives minor GC with hybrid DFS enabled", []() {
    rc::check([]() {
        // Size-scaled list length: 10-50 at size 0, up to 10-500 at size 1000
        size_t list_length = *rc::sizedRange<size_t>(10, 50, 0.45);

        // Initialize with hybrid DFS enabled (default)
        HeapConfig config;
        config.use_hybrid_dfs = true;
        auto& alloc = initAllocator(config);

        // Build a list
        UnboxedList list = buildUnboxedList(alloc, list_length);

        // Register as root
        alloc.getRootSet().addRoot(&list.head);

        // Allocate some garbage to interleave with
        allocateGarbageInts(alloc, 50);

        // Trigger GC
        alloc.minorGC();

        // Verify list is intact
        verifyUnboxedList(list.head, list.values);

        // Clean up
        alloc.getRootSet().removeRoot(&list.head);
    });
});

Testing::TestCase testListSurvivesGCWithBFS("List survives minor GC with BFS only (hybrid DFS disabled)", []() {
    rc::check([]() {
        // Size-scaled list length
        size_t list_length = *rc::sizedRange<size_t>(10, 50, 0.45);

        // Initialize with hybrid DFS disabled
        HeapConfig config;
        config.use_hybrid_dfs = false;
        auto& alloc = initAllocator(config);

        // Build a list
        UnboxedList list = buildUnboxedList(alloc, list_length);

        // Register as root
        alloc.getRootSet().addRoot(&list.head);

        // Allocate some garbage to interleave with
        allocateGarbageInts(alloc, 50);

        // Trigger GC
        alloc.minorGC();

        // Verify list is intact
        verifyUnboxedList(list.head, list.values);

        // Clean up
        alloc.getRootSet().removeRoot(&list.head);
    });
});

Testing::TestCase testMultipleListsSurviveGCWithHybridDFS("Multiple lists survive minor GC with hybrid DFS", []() {
    rc::check([]() {
        // Size-scaled: 2-5 lists at size 0, up to 2-20 at size 1000
        size_t num_lists = *rc::sizedRange<size_t>(2, 5, 0.015);
        size_t list_length = *rc::sizedRange<size_t>(5, 20, 0.05);

        HeapConfig config;
        config.use_hybrid_dfs = true;
        auto& alloc = initAllocator(config);

        // Build multiple lists - reserve space first to avoid reallocation
        // invalidating root pointers
        std::vector<UnboxedList> lists;
        lists.reserve(num_lists);

        for (size_t i = 0; i < num_lists; i++) {
            lists.push_back(buildUnboxedList(alloc, list_length));
        }

        // Register roots after all lists are built (vector won't reallocate)
        for (auto& list : lists) {
            alloc.getRootSet().addRoot(&list.head);
        }

        // Interleave with garbage
        allocateGarbageInts(alloc, 100);

        // Trigger GC
        alloc.minorGC();

        // Verify all lists intact
        for (size_t i = 0; i < lists.size(); i++) {
            verifyUnboxedList(lists[i].head, lists[i].values);
        }

        // Clean up
        for (auto& list : lists) {
            alloc.getRootSet().removeRoot(&list.head);
        }
    });
});

Testing::TestCase testMultipleListsSurviveGCWithBFS("Multiple lists survive minor GC with BFS only", []() {
    rc::check([]() {
        size_t num_lists = *rc::sizedRange<size_t>(2, 5, 0.015);
        size_t list_length = *rc::sizedRange<size_t>(5, 20, 0.05);

        HeapConfig config;
        config.use_hybrid_dfs = false;
        auto& alloc = initAllocator(config);

        // Build multiple lists - reserve space first to avoid reallocation
        // invalidating root pointers
        std::vector<UnboxedList> lists;
        lists.reserve(num_lists);

        for (size_t i = 0; i < num_lists; i++) {
            lists.push_back(buildUnboxedList(alloc, list_length));
        }

        // Register roots after all lists are built (vector won't reallocate)
        for (auto& list : lists) {
            alloc.getRootSet().addRoot(&list.head);
        }

        // Interleave with garbage
        allocateGarbageInts(alloc, 100);

        // Trigger GC
        alloc.minorGC();

        // Verify all lists intact
        for (size_t i = 0; i < lists.size(); i++) {
            verifyUnboxedList(lists[i].head, lists[i].values);
        }

        // Clean up
        for (auto& list : lists) {
            alloc.getRootSet().removeRoot(&list.head);
        }
    });
});

Testing::TestCase testListLocalityImprovedByHybridDFS("Hybrid DFS improves list locality after GC", []() {
    rc::check([]() {
        const size_t LIST_LENGTH = 100;

        // Test with hybrid DFS enabled
        HeapConfig config_dfs;
        config_dfs.use_hybrid_dfs = true;
        auto& alloc_dfs = initAllocator(config_dfs);

        UnboxedList list_dfs = buildUnboxedList(alloc_dfs, LIST_LENGTH);
        alloc_dfs.getRootSet().addRoot(&list_dfs.head);

        // Allocate garbage to force interleaving in BFS mode
        allocateGarbageInts(alloc_dfs, 50);

        alloc_dfs.minorGC();

        size_t gap_dfs = measureListLocality(list_dfs.head);
        verifyUnboxedList(list_dfs.head, list_dfs.values);
        alloc_dfs.getRootSet().removeRoot(&list_dfs.head);

        // Test with hybrid DFS disabled (pure BFS)
        HeapConfig config_bfs;
        config_bfs.use_hybrid_dfs = false;
        auto& alloc_bfs = initAllocator(config_bfs);

        UnboxedList list_bfs = buildUnboxedList(alloc_bfs, LIST_LENGTH);
        alloc_bfs.getRootSet().addRoot(&list_bfs.head);

        // Same garbage pattern
        allocateGarbageInts(alloc_bfs, 50);

        alloc_bfs.minorGC();

        size_t gap_bfs = measureListLocality(list_bfs.head);
        verifyUnboxedList(list_bfs.head, list_bfs.values);
        alloc_bfs.getRootSet().removeRoot(&list_bfs.head);

        // Log the gaps for visibility
        RC_LOG() << "List locality - DFS gap: " << gap_dfs << " bytes, BFS gap: " << gap_bfs << " bytes";

        // With hybrid DFS, gap should be approximately sizeof(Cons) = 24 bytes
        // (cells are copied contiguously).
        // With BFS, gap may be larger due to interleaving with garbage.
        // We verify DFS produces good locality (close to optimal).
        size_t cons_size = (sizeof(Cons) + 7) & ~7;  // 8-byte aligned
        RC_ASSERT(gap_dfs <= cons_size * 2);  // Allow some slack for alignment
    });
});

Testing::TestCase testListSurvivesMultipleGCCyclesWithHybridDFS("List survives multiple GC cycles with hybrid DFS", []() {
    rc::check([]() {
        size_t list_length = *rc::sizedRange<size_t>(20, 50, 0.1);
        int num_cycles = *rc::sizedRange<int>(2, 5, 0.01);

        HeapConfig config;
        config.use_hybrid_dfs = true;
        auto& alloc = initAllocator(config);

        UnboxedList list = buildUnboxedList(alloc, list_length);
        alloc.getRootSet().addRoot(&list.head);

        for (int i = 0; i < num_cycles; i++) {
            // Allocate garbage between cycles
            allocateGarbageInts(alloc, 30);

            alloc.minorGC();

            // Verify list after each cycle
            verifyUnboxedList(list.head, list.values);
        }

        alloc.getRootSet().removeRoot(&list.head);
    });
});

Testing::TestCase testListSurvivesMultipleGCCyclesWithBFS("List survives multiple GC cycles with BFS only", []() {
    rc::check([]() {
        size_t list_length = *rc::sizedRange<size_t>(20, 50, 0.1);
        int num_cycles = *rc::sizedRange<int>(2, 5, 0.01);

        HeapConfig config;
        config.use_hybrid_dfs = false;
        auto& alloc = initAllocator(config);

        UnboxedList list = buildUnboxedList(alloc, list_length);
        alloc.getRootSet().addRoot(&list.head);

        for (int i = 0; i < num_cycles; i++) {
            // Allocate garbage between cycles
            allocateGarbageInts(alloc, 30);

            alloc.minorGC();

            // Verify list after each cycle
            verifyUnboxedList(list.head, list.values);
        }

        alloc.getRootSet().removeRoot(&list.head);
    });
});

Testing::TestCase testDeepListExceedsDFSStack("Deep list exceeding DFS stack size still works correctly", []() {
    rc::check([]() {
        // Create a list longer than DfsStack::MAX_DEPTH (256) to test fallback to BFS
        const size_t LIST_LENGTH = 300;

        HeapConfig config;
        config.use_hybrid_dfs = true;
        auto& alloc = initAllocator(config);

        UnboxedList list = buildUnboxedList(alloc, LIST_LENGTH);
        alloc.getRootSet().addRoot(&list.head);

        // Add garbage
        allocateGarbageInts(alloc, 50);

        // GC should handle the overflow gracefully
        alloc.minorGC();

        // Verify entire list is intact
        verifyUnboxedList(list.head, list.values);

        alloc.getRootSet().removeRoot(&list.head);
    });
});
