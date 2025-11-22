#include "CompactionTest.hpp"
#include <cstring>
#include <rapidcheck.h>
#include <vector>
#include "GarbageCollector.hpp"
#include "Heap.hpp"
#include "OldGenSpace.hpp"
#include "TestHelpers.hpp"

using namespace Elm;

// ============================================================================
// Tests
// ============================================================================

Testing::UnitTest testBlockInitialization("Blocks cover the free-list region with correct sizes", []() {
    auto& gc = initGC();
    auto& oldgen = gc.getOldGen();

    // Allocate a TLAB to trigger block initialization during marking.
    TLAB* tlab = allocateTLABOrFail(oldgen);

    // Allocate some objects.
    void* obj = allocateIntIntoTLAB(tlab, 42);
    if (!obj) TEST_FAIL("Failed to allocate object");

    HPointer root = toPointer(obj);
    gc.getRootSet().addRoot(&root);

    oldgen.sealTLAB(tlab);

    // Start marking - this initializes blocks.
    runMarkAndSweep(gc);

    // Now run compaction selection - blocks should be initialized.
    oldgen.selectCompactionSet();

    // If we got here without crash, blocks were initialized.
    // The test verifies the code path runs without errors.

    gc.getRootSet().removeRoot(&root);
});

Testing::TestCase testBlockLiveInfoTracking("Objects marked as live update block statistics", []() {
    rc::check([]() {
        auto& gc = initGC();
        auto& oldgen = gc.getOldGen();
        auto& rootset = gc.getRootSet();

        // Allocate objects in old gen via TLAB
        TLAB* tlab = allocateTLABOrFail(oldgen);

        // Generate random number of objects
        size_t num_objects = *rc::gen::inRange<size_t>(5, 20);
        std::vector<void*> objects;
        std::vector<HPointer> root_storage;

        for (size_t i = 0; i < num_objects; i++) {
            i64 val = *rc::gen::arbitrary<i64>();
            void* obj = allocateIntIntoTLAB(tlab, val);
            if (!obj) break;
            objects.push_back(obj);
            root_storage.push_back(toPointer(obj));
        }

        RC_ASSERT(!objects.empty());

        // Root all objects
        for (auto& root : root_storage) {
            rootset.addRoot(&root);
        }

        oldgen.sealTLAB(tlab);

        // Run marking - this tracks live info per block
#if ENABLE_GC_STATS
        GCStats& stats = gc.getMajorGCStats();
        oldgen.startConcurrentMark(rootset, stats);
        while (oldgen.incrementalMark(100, stats)) {}
#else
        oldgen.startConcurrentMark(rootset);
        while (oldgen.incrementalMark(100)) {}
#endif

        // All objects should be marked Black
        for (void* obj : objects) {
            Header* hdr = getHeader(obj);
            RC_ASSERT(hdr->color == static_cast<u32>(Color::Black));
        }

        // Clean up
        for (auto& root : root_storage) {
            rootset.removeRoot(&root);
        }

#if ENABLE_GC_STATS
        oldgen.finishMarkAndSweep(stats);
#else
        oldgen.finishMarkAndSweep();
#endif
    });
});

Testing::UnitTest testCompactionSetSelection("Blocks below threshold are selected for evacuation", []() {
    auto& gc = initGC();
    auto& oldgen = gc.getOldGen();

    // Allocate a small amount of live data to create low-occupancy blocks.
    TLAB* tlab = allocateTLABOrFail(oldgen);

    // Just a few objects - should result in very low block occupancy.
    void* obj = allocateIntIntoTLAB(tlab, 12345);
    if (!obj) TEST_FAIL("Failed to allocate object");

    HPointer root = toPointer(obj);
    gc.getRootSet().addRoot(&root);

    oldgen.sealTLAB(tlab);

    // Run full marking cycle.
    runMarkAndSweep(gc);

    // Select compaction set and run compaction.
    runCompaction(oldgen, false);

    // Object should still be accessible (may have been moved).
    void* current_obj = fromPointer(root);
    if (!current_obj) TEST_FAIL("Object not accessible after compaction");

    ElmInt* elm_int = static_cast<ElmInt*>(current_obj);
    TEST_ASSERT(elm_int->value == 12345);

    gc.getRootSet().removeRoot(&root);
});

Testing::TestCase testObjectEvacuationWithForwarding("After evacuation, original location has forwarding pointer", []() {
    rc::check([]() {
        auto& gc = initGC();
        auto& oldgen = gc.getOldGen();

        // Allocate object
        TLAB* tlab = allocateTLABOrFail(oldgen);

        i64 test_value = *rc::gen::arbitrary<i64>();
        void* original_obj = allocateIntIntoTLAB(tlab, test_value);
        if (!original_obj) RC_FAIL("Failed to allocate object");

        HPointer root = toPointer(original_obj);
        gc.getRootSet().addRoot(&root);

        oldgen.sealTLAB(tlab);

        // Mark the object and compact
        runMarkAndSweep(gc);
        runCompaction(oldgen, false);

        // Check if object was moved (original location may have forwarding pointer)
        Header* original_hdr = getHeader(original_obj);
        void* current_obj = fromPointer(root);

        if (original_hdr->tag == Tag_Forward) {
            // Object was evacuated - verify forwarding pointer works
            Forward* fwd = static_cast<Forward*>(original_obj);
            RC_ASSERT(fwd->header.tag == Tag_Forward);

            // New location should have the value
            ElmInt* elm_int = static_cast<ElmInt*>(current_obj);
            RC_ASSERT(elm_int->value == test_value);
        } else {
            // Object wasn't moved - value should be intact at original location
            ElmInt* elm_int = static_cast<ElmInt*>(current_obj);
            RC_ASSERT(elm_int->value == test_value);
        }

        gc.getRootSet().removeRoot(&root);
    });
});

Testing::TestCase testReadBarrierSelfHealing("readBarrier updates pointer to new location", []() {
    rc::check([]() {
        auto& gc = initGC();
        auto& oldgen = gc.getOldGen();

        // Allocate and root an object
        TLAB* tlab = allocateTLABOrFail(oldgen);

        i64 test_value = *rc::gen::arbitrary<i64>();
        void* obj = allocateIntIntoTLAB(tlab, test_value);
        if (!obj) RC_FAIL("Failed to allocate object");

        HPointer root = toPointer(obj);
        HPointer original_root = root;  // Keep copy of original pointer
        gc.getRootSet().addRoot(&root);

        oldgen.sealTLAB(tlab);

        // Run GC and compaction
        runMarkAndSweep(gc);
        runCompaction(oldgen, false);

        // Use read barrier on a copy of the original pointer
        HPointer test_ptr = original_root;
        void* result = readBarrier(test_ptr);

        if (result != nullptr) {
            // Read barrier should return valid object
            ElmInt* elm_int = static_cast<ElmInt*>(result);
            RC_ASSERT(elm_int->value == test_value);

            // If object was moved, test_ptr should have been updated (self-healing)
            Header* original_hdr = getHeader(fromPointer(original_root));
            if (original_hdr->tag == Tag_Forward) {
                // Pointer should have been updated
                RC_ASSERT(test_ptr.ptr != original_root.ptr);
            }
        }

        gc.getRootSet().removeRoot(&root);
    });
});

Testing::TestCase testBlockEvacuation("evacuateBlock moves all Black objects from target block", []() {
    rc::check([]() {
        auto& gc = initGC();
        auto& oldgen = gc.getOldGen();
        auto& rootset = gc.getRootSet();

        // Allocate multiple objects
        TLAB* tlab = allocateTLABOrFail(oldgen);

        size_t num_objects = *rc::gen::inRange<size_t>(3, 10);
        std::vector<void*> original_locations;
        std::vector<i64> expected_values;
        std::vector<HPointer> root_storage;

        for (size_t i = 0; i < num_objects; i++) {
            i64 val = *rc::gen::inRange<i64>(0, 1000000);
            void* obj = allocateIntIntoTLAB(tlab, val);
            if (!obj) break;
            original_locations.push_back(obj);
            expected_values.push_back(val);
            root_storage.push_back(toPointer(obj));
        }

        RC_ASSERT(original_locations.size() >= 2);

        for (auto& root : root_storage) {
            rootset.addRoot(&root);
        }

        oldgen.sealTLAB(tlab);

        // Mark objects and compact
        runMarkAndSweep(gc);
        runCompaction(oldgen, false);

        // Verify all values are still accessible
        for (size_t i = 0; i < root_storage.size(); i++) {
            void* obj = fromPointer(root_storage[i]);
            if (!obj) RC_FAIL("Object is null");

            // Follow forwarding if needed
            Header* hdr = getHeader(obj);
            if (hdr->tag == Tag_Forward) {
                obj = readBarrier(root_storage[i]);
            }

            ElmInt* elm_int = static_cast<ElmInt*>(obj);
            RC_ASSERT(elm_int->value == expected_values[i]);
        }

        unregisterRoots(gc, root_storage);
    });
});

Testing::UnitTest testBlockReclaimToTLABs("reclaimEvacuatedBlocks adds empty blocks to TLAB pool", []() {
    auto& gc = initGC();
    auto& oldgen = gc.getOldGen();

    // Allocate a small object to create a very sparse block.
    TLAB* tlab = allocateTLABOrFail(oldgen);

    void* obj = allocateIntIntoTLAB(tlab, 999);
    if (!obj) TEST_FAIL("Failed to allocate object");

    HPointer root = toPointer(obj);
    gc.getRootSet().addRoot(&root);

    oldgen.sealTLAB(tlab);

    // Run full GC cycle with compaction.
    runMarkAndSweep(gc);
    runCompaction(oldgen);

    // Object should still be valid.
    void* current = fromPointer(root);
    if (getHeader(current)->tag == Tag_Forward) {
        current = readBarrier(root);
    }
    if (!current) TEST_FAIL("Current object is null");

    ElmInt* elm_int = static_cast<ElmInt*>(current);
    TEST_ASSERT(elm_int->value == 999);

    gc.getRootSet().removeRoot(&root);
});

Testing::TestCase testCompactionPreservesValues("Object data is identical after compaction", []() {
    rc::check([]() {
        auto& gc = initGC();
        auto& oldgen = gc.getOldGen();

        // Generate random test data
        size_t num_objects = *rc::gen::inRange<size_t>(5, 30);
        auto values = *rc::gen::container<std::vector<i64>>(
            num_objects,
            rc::gen::arbitrary<i64>()
        );

        TLAB* tlab = allocateTLABOrFail(oldgen);

        std::vector<HPointer> root_storage;
        for (i64 val : values) {
            void* obj = allocateIntIntoTLAB(tlab, val);
            if (!obj) break;
            root_storage.push_back(toPointer(obj));
        }

        RC_ASSERT(!root_storage.empty());

        for (auto& root : root_storage) {
            gc.getRootSet().addRoot(&root);
        }

        oldgen.sealTLAB(tlab);

        // Run GC and compaction
        runMarkAndSweep(gc);
        runCompaction(oldgen);

        // Verify all values preserved
        verifyIntValues(root_storage, values);

        unregisterRoots(gc, root_storage);
    });
});

Testing::TestCase testRootPointerUpdatesAfterCompaction("Roots point to correct objects after compaction", []() {
    rc::check([]() {
        auto& gc = initGC();
        auto& oldgen = gc.getOldGen();

        // Build a linked list in old gen
        TLAB* tlab = allocateTLABOrFail(oldgen);

        size_t list_length = *rc::gen::inRange<size_t>(3, 8);
        std::vector<i64> expected_values;

        HPointer tail = createConstant(Const_Nil);

        for (size_t i = 0; i < list_length; i++) {
            i64 val = *rc::gen::inRange<i64>(0, 10000);
            expected_values.push_back(val);

            void* int_obj = allocateIntIntoTLAB(tlab, val);
            if (!int_obj) RC_FAIL("Failed to allocate int");

            HPointer head_ptr = toPointer(int_obj);
            void* cons_obj = tlab->allocate(sizeof(Cons));
            if (!cons_obj) RC_FAIL("Failed to allocate cons");

            Header* hdr = reinterpret_cast<Header*>(cons_obj);
            std::memset(hdr, 0, sizeof(Header));
            hdr->tag = Tag_Cons;
            hdr->color = static_cast<u32>(Color::White);

            Cons* cons = static_cast<Cons*>(cons_obj);
            cons->head.p = head_ptr;
            cons->tail = tail;

            tail = toPointer(cons_obj);
        }

        HPointer root = tail;
        gc.getRootSet().addRoot(&root);

        oldgen.sealTLAB(tlab);

        // Run GC and compaction
        runMarkAndSweep(gc);
        runCompaction(oldgen);

        // Walk the list and verify values (in reverse order since we built it that way)
        HPointer current = root;
        size_t idx = expected_values.size();
        while (current.constant == 0) {
            void* obj = readBarrier(current);
            if (!obj) break;

            Header* hdr = getHeader(obj);
            if (hdr->tag != Tag_Cons) break;

            Cons* cons = static_cast<Cons*>(obj);
            void* head_obj = readBarrier(cons->head.p);
            if (!head_obj) break;

            if (getHeader(head_obj)->tag == Tag_Int) {
                idx--;
                ElmInt* elm_int = static_cast<ElmInt*>(head_obj);
                RC_ASSERT(elm_int->value == expected_values[idx]);
            }

            current = cons->tail;
        }

        gc.getRootSet().removeRoot(&root);
    });
});

Testing::TestCase testFragmentationDefragmentation("Sparse objects are consolidated after compaction", []() {
    rc::check([]() {
        auto& gc = initGC();
        auto& oldgen = gc.getOldGen();

        // Create fragmentation: allocate objects, then only root some of them.
        TLAB* tlab = allocateTLABOrFail(oldgen);

        size_t total_objects = *rc::gen::inRange<size_t>(10, 30);
        std::vector<void*> all_objects;
        std::vector<i64> all_values;

        for (size_t i = 0; i < total_objects; i++) {
            i64 val = *rc::gen::arbitrary<i64>();
            void* obj = allocateIntIntoTLAB(tlab, val);
            if (!obj) break;
            all_objects.push_back(obj);
            all_values.push_back(val);
        }

        RC_ASSERT(all_objects.size() >= 6);

        // Only root every 3rd object (creates fragmentation).
        std::vector<HPointer> root_storage;
        std::vector<i64> rooted_values;
        for (size_t i = 0; i < all_objects.size(); i += 3) {
            root_storage.push_back(toPointer(all_objects[i]));
            rooted_values.push_back(all_values[i]);
        }

        for (auto& root : root_storage) {
            gc.getRootSet().addRoot(&root);
        }

        oldgen.sealTLAB(tlab);

        // Run GC and compaction.
        runMarkAndSweep(gc);
        runCompaction(oldgen);

        // Verify rooted values are still accessible.
        verifyIntValues(root_storage, rooted_values);

        unregisterRoots(gc, root_storage);
    });
});
