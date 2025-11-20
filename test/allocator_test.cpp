#include "allocator_test.hpp"
#include "heap_snapshot.hpp"
#include "generators.hpp"
#include <rapidcheck.h>

using namespace Elm;

Testing::Test testGCPreservesRoots("GC preserves all reachable objects from roots", []() {
        rc::check("GC preserves all reachable objects from roots", [](const HeapGraphDesc &graph) {
            // Initialize GC for this thread
            auto &gc = GarbageCollector::instance();
            gc.initThread();

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

Testing::Test testMultipleGCCycles("Multiple GC cycles preserve roots correctly", []() {
        rc::check("Multiple GC cycles preserve roots correctly", []() {
            // Generate proper test parameters directly using custom generator
            auto testGen = rc::gen::tuple(rc::gen::arbitrary<i64>(), // int_value
                                          rc::gen::inRange(2, 5), // num_cycles (2-4 inclusive)
                                          rc::gen::container<std::vector<std::vector<HeapObjectDesc>>>(
                                              4, // Generate exactly 10 garbage vectors (covers max cycles)
                                              rc::gen::arbitrary<std::vector<HeapObjectDesc>>()));

            auto params = *testGen;
            auto [int_value, num_cycles, garbage_per_cycle] = params;

            auto &gc = GarbageCollector::instance();
            gc.initThread();

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
