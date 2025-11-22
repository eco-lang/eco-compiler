#include "NurserySpaceTest.hpp"
#include <rapidcheck.h>
#include "HeapGenerators.hpp"
#include "HeapSnapshot.hpp"

using namespace Elm;

Testing::TestCase testMinorGCPreservesRoots("Minor GC preserves all reachable objects from roots", []() {
        rc::check([](const HeapGraphDesc &graph) {
            // Initialize GC for this thread and reset to clean state
            auto &gc = GarbageCollector::instance();
            gc.initThread();
            gc.reset();

            // Phase 1: Allocate heap from description (RapidCheck can shrink this!)
            std::vector<void *> allocated_objects = allocateHeapGraph(graph.nodes);
            RC_ASSERT(!allocated_objects.empty());

            // Phase 2: Set up roots from graph description
            std::vector<HPointer> root_storage;
            std::vector<HPointer *> root_ptrs;

            for (size_t idx: graph.root_indices) {
                if (idx < allocated_objects.size()) {
                    root_storage.push_back(toPointer(allocated_objects[idx]));
                }
            }

            for (auto &root: root_storage) {
                root_ptrs.push_back(&root);
                gc.getRootSet().addRoot(&root);
            }

            RC_ASSERT(!root_ptrs.empty());

            // Phase 3: Take snapshot before GC
            HeapSnapshot snapshot;
            snapshot.capture(allocated_objects, root_ptrs);

            // Phase 4: Perform minor GC
            gc.minorGC();

            // Phase 5: Verify all roots still intact and valid
            bool valid = snapshot.verify(root_ptrs);

            // Cleanup roots
            for (auto *root: root_ptrs) {
                gc.getRootSet().removeRoot(root);
            }

            RC_ASSERT(valid);
        });
});

Testing::TestCase testMultipleMinorGCCycles("Multiple minor GC cycles preserve roots correctly", []() {
        rc::check([]() {
            // Generate proper test parameters directly using custom generator
            // Size-scaled: num_cycles 2-5 at size 0, up to 2-15 at size 1000
            auto testGen = rc::gen::tuple(rc::gen::arbitrary<i64>(), // int_value
                                          rc::sizedRange<int>(2, 5, 0.01), // num_cycles
                                          rc::gen::arbitrary<std::vector<std::vector<HeapObjectDesc>>>());

            auto params = *testGen;
            auto [int_value, num_cycles, garbage_per_cycle] = params;

            auto &gc = GarbageCollector::instance();
            gc.initThread();
            gc.reset();

            // Create a long-lived Int object as root
            void *root_obj = gc.allocate(sizeof(ElmInt), Tag_Int);
            ElmInt *elm_int = static_cast<ElmInt *>(root_obj);
            elm_int->value = int_value;

            HPointer root_ptr = toPointer(root_obj);
            gc.getRootSet().addRoot(&root_ptr);

            i64 original_value = elm_int->value;

            // Run multiple GC cycles
            for (int i = 0; i < num_cycles; i++) {
                // Check value before GC
                void *current_obj = fromPointer(root_ptr);
                i64 before_value = static_cast<ElmInt *>(current_obj)->value;

                // Allocate garbage between cycles from generated descriptions
                if (i < static_cast<int>(garbage_per_cycle.size())) {
                    allocateHeapGraph(garbage_per_cycle[i]);
                }

                gc.minorGC();

                // Check value after GC
                void *after_obj = fromPointer(root_ptr);
                i64 after_value = static_cast<ElmInt *>(after_obj)->value;

                RC_ASSERT(before_value == after_value);
            }

            // Verify root still exists and has same value
            void *final_obj = fromPointer(root_ptr);
            RC_ASSERT(reinterpret_cast<uintptr_t>(final_obj) != 0);

            Header *hdr = getHeader(final_obj);
            RC_ASSERT(hdr->tag == Tag_Int);

            i64 final_value = static_cast<ElmInt *>(final_obj)->value;
            RC_ASSERT(original_value == final_value);

            gc.getRootSet().removeRoot(&root_ptr);
        });
});

Testing::TestCase testContinuousGarbageAllocation("Continuous garbage allocation triggers automatic GC and recycles space", []() {
        rc::check([](const HeapGraphDesc &graph) {
            auto &gc = GarbageCollector::instance();
            gc.initThread();
            gc.reset();
            auto *nursery = gc.getNursery();

            if (nursery == nullptr) {
                RC_DISCARD("Nursery not available");
            }

            // Get nursery capacity for calculating target
            size_t nursery_capacity = NURSERY_SIZE / 2;
            size_t target_allocation = nursery_capacity * 2;

            // Allocate initial rooted objects from graph description
            std::vector<void *> root_objects = allocateHeapGraph(graph.nodes);
            if (root_objects.empty()) {
                RC_DISCARD("No objects allocated");
            }

            std::vector<HPointer> root_storage;
            std::vector<HPointer *> root_ptrs;

            // Use graph's root indices to select roots
            for (size_t idx : graph.root_indices) {
                if (idx < root_objects.size()) {
                    root_storage.push_back(toPointer(root_objects[idx]));
                }
            }

            // If no valid roots from graph, use first object as root
            if (root_storage.empty()) {
                root_storage.push_back(toPointer(root_objects[0]));
            }

            for (auto &root : root_storage) {
                root_ptrs.push_back(&root);
                gc.getRootSet().addRoot(&root);
            }

            // Take snapshot of root objects before continuous allocation
            HeapSnapshot snapshot;
            snapshot.capture(root_objects, root_ptrs);

            // Continuously allocate garbage (unrooted objects) until we've allocated 2x the nursery capacity
            size_t total_allocated = 0;
            size_t allocation_count = 0;

            while (total_allocated < target_allocation) {
                // Allocate a garbage object (not added to roots)
                // Allocate proper ElmInt objects to avoid uninitialized memory issues
                size_t obj_size = sizeof(ElmInt);

                void *garbage = gc.allocate(obj_size, Tag_Int);
                if (garbage == nullptr) {
                    RC_FAIL("Allocation failed - automatic GC should prevent this");
                }

                // Initialize the object properly
                ElmInt *elm_int = static_cast<ElmInt *>(garbage);
                elm_int->value = allocation_count;

                total_allocated += obj_size;
                allocation_count++;
            }

            // Final verification: all roots still intact and values preserved
            bool valid = snapshot.verify(root_ptrs);

            // Cleanup roots
            for (auto *root : root_ptrs) {
                gc.getRootSet().removeRoot(root);
            }

            RC_ASSERT(valid);
        });
});
