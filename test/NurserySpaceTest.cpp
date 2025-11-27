#include "NurserySpaceTest.hpp"
#include <rapidcheck.h>
#include "HeapGenerators.hpp"
#include "HeapSnapshot.hpp"
#include "TestHelpers.hpp"

using namespace Elm;

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
            size_t nursery_capacity = config.nursery_size / 2;
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
