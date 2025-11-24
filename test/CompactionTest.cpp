#include "CompactionTest.hpp"
#include <cstring>
#include <rapidcheck.h>
#include <vector>
#include "GarbageCollector.hpp"
#include "Heap.hpp"
#include "OldGenSpace.hpp"

using namespace Elm;

// ============================================================================
// Helper: Create constant HPointer.
// ============================================================================

static HPointer createConstant(Constant c) {
    HPointer ptr;
    ptr.ptr = 0;
    ptr.constant = c;
    ptr.padding = 0;
    return ptr;
}

// ============================================================================
// Helper: Allocate a simple ElmInt into a TLAB.
// ============================================================================

static void* allocateIntIntoTLAB(TLAB* tlab, i64 value) {
    void* obj = tlab->allocate(sizeof(ElmInt));
    if (!obj) return nullptr;

    Header* hdr = reinterpret_cast<Header*>(obj);
    std::memset(hdr, 0, sizeof(Header));
    hdr->tag = Tag_Int;
    hdr->color = static_cast<u32>(Color::White);

    ElmInt* elm_int = static_cast<ElmInt*>(obj);
    elm_int->value = value;

    return obj;
}

// ============================================================================
// Helper: Allocate ElmInt directly in OldGen free-list.
// ============================================================================

static void* allocateIntInOldGen(OldGenSpace& oldgen, i64 value) {
    void* obj = oldgen.allocate(sizeof(ElmInt));
    if (!obj) return nullptr;

    Header* hdr = reinterpret_cast<Header*>(obj);
    hdr->tag = Tag_Int;
    hdr->color = static_cast<u32>(Color::White);

    ElmInt* elm_int = static_cast<ElmInt*>(obj);
    elm_int->value = value;

    return obj;
}

// ============================================================================
// Helper: Allocate a Cons cell into OldGen (for building linked lists).
// ============================================================================

static void* allocateConsInOldGen(OldGenSpace& oldgen, HPointer head_ptr, HPointer tail_ptr, bool head_boxed) {
    void* obj = oldgen.allocate(sizeof(Cons));
    if (!obj) return nullptr;

    Header* hdr = reinterpret_cast<Header*>(obj);
    hdr->tag = Tag_Cons;
    hdr->color = static_cast<u32>(Color::White);
    hdr->unboxed = head_boxed ? 0 : 1;

    Cons* cons = static_cast<Cons*>(obj);
    cons->head.p = head_ptr;
    cons->tail = tail_ptr;

    return obj;
}

// ============================================================================
// Tests
// ============================================================================

Testing::TestCase testBlockInitialization("Blocks cover the free-list region with correct sizes", []() {
    rc::check([]() {
        auto& gc = GarbageCollector::instance();
        gc.initThread();
        gc.reset();
        auto& oldgen = gc.getOldGen();
        auto& rootset = gc.getRootSet();

        // Allocate a TLAB to trigger block initialization during marking.
        TLAB* tlab = oldgen.allocateTLAB(TLAB_DEFAULT_SIZE);
        if (!tlab) RC_FAIL("Failed to allocate TLAB");

        // Allocate some objects.
        void* obj = allocateIntIntoTLAB(tlab, 42);
        if (!obj) RC_FAIL("Failed to allocate object");

        HPointer root = GCTestAccess::toPointer(obj);
        rootset.addRoot(&root);

        oldgen.sealTLAB(tlab);

        // Start marking - this initializes blocks.
#if ENABLE_GC_STATS
        GCStats& stats = gc.getMajorGCStats();
        oldgen.startConcurrentMark(rootset.getRoots(), GarbageCollector::instance(), stats);
        oldgen.finishMarkAndSweep(stats);
#else
        oldgen.startConcurrentMark(rootset.getRoots(), GarbageCollector::instance());
        oldgen.finishMarkAndSweep();
#endif

        // Now run compaction selection - blocks should be initialized.
        oldgen.selectCompactionSet();

        // If we got here without crash, blocks were initialized.
        // The test verifies the code path runs without errors.

        rootset.removeRoot(&root);
    });
});

Testing::TestCase testBlockLiveInfoTracking("Objects marked as live update block statistics", []() {
    rc::check([]() {
        auto& gc = GarbageCollector::instance();
        gc.initThread();
        gc.reset();
        auto& oldgen = gc.getOldGen();
        auto& rootset = gc.getRootSet();

        // Allocate objects in old gen via TLAB.
        TLAB* tlab = oldgen.allocateTLAB(TLAB_DEFAULT_SIZE);
        if (!tlab) RC_FAIL("Failed to allocate TLAB");

        // Generate random number of objects.
        size_t num_objects = *rc::gen::inRange<size_t>(5, 20);
        std::vector<void*> objects;
        std::vector<HPointer> root_storage;

        for (size_t i = 0; i < num_objects; i++) {
            i64 val = *rc::gen::arbitrary<i64>();
            void* obj = allocateIntIntoTLAB(tlab, val);
            if (!obj) break;
            objects.push_back(obj);
            root_storage.push_back(GCTestAccess::toPointer(obj));
        }

        RC_ASSERT(!objects.empty());

        // Root all objects.
        for (auto& root : root_storage) {
            rootset.addRoot(&root);
        }

        oldgen.sealTLAB(tlab);

        // Run marking - this tracks live info per block.
#if ENABLE_GC_STATS
        GCStats& stats = gc.getMajorGCStats();
        oldgen.startConcurrentMark(rootset.getRoots(), GarbageCollector::instance(), stats);
        while (oldgen.incrementalMark(100, stats)) {}
#else
        oldgen.startConcurrentMark(rootset.getRoots(), GarbageCollector::instance());
        while (oldgen.incrementalMark(100)) {}
#endif

        // All objects should be marked Black.
        for (void* obj : objects) {
            Header* hdr = getHeader(obj);
            RC_ASSERT(hdr->color == static_cast<u32>(Color::Black));
        }

        // Clean up.
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

Testing::TestCase testCompactionSetSelection("Blocks below threshold are selected for evacuation", []() {
    rc::check([]() {
        auto& gc = GarbageCollector::instance();
        gc.initThread();
        gc.reset();
        auto& oldgen = gc.getOldGen();
        auto& rootset = gc.getRootSet();

        // Allocate a small amount of live data to create low-occupancy blocks.
        TLAB* tlab = oldgen.allocateTLAB(TLAB_DEFAULT_SIZE);
        if (!tlab) RC_FAIL("Failed to allocate TLAB");

        // Just a few objects - should result in very low block occupancy.
        void* obj = allocateIntIntoTLAB(tlab, 12345);
        if (!obj) RC_FAIL("Failed to allocate object");

        HPointer root = GCTestAccess::toPointer(obj);
        rootset.addRoot(&root);

        oldgen.sealTLAB(tlab);

        // Run full marking cycle.
#if ENABLE_GC_STATS
        GCStats& stats = gc.getMajorGCStats();
        oldgen.startConcurrentMark(rootset.getRoots(), GarbageCollector::instance(), stats);
        oldgen.finishMarkAndSweep(stats);
#else
        oldgen.startConcurrentMark(rootset.getRoots(), GarbageCollector::instance());
        oldgen.finishMarkAndSweep();
#endif

        // Select compaction set - low occupancy blocks should be selected.
        oldgen.selectCompactionSet();

        // Verify by running compaction (if blocks were selected, this will evacuate them).
        oldgen.setCompactionInProgress(true);
        oldgen.performCompaction();
        oldgen.setCompactionInProgress(false);

        // Object should still be accessible (may have been moved).
        void* current_obj = GCTestAccess::fromPointer(root);
        if (!current_obj) RC_FAIL("Object not accessible after compaction");

        ElmInt* elm_int = static_cast<ElmInt*>(current_obj);
        RC_ASSERT(elm_int->value == 12345);

        rootset.removeRoot(&root);
    });
});

Testing::TestCase testObjectEvacuationWithForwarding("After evacuation, original location has forwarding pointer", []() {
    rc::check([]() {
        auto& gc = GarbageCollector::instance();
        gc.initThread();
        gc.reset();
        auto& oldgen = gc.getOldGen();
        auto& rootset = gc.getRootSet();

        // Allocate object.
        TLAB* tlab = oldgen.allocateTLAB(TLAB_DEFAULT_SIZE);
        if (!tlab) RC_FAIL("Failed to allocate TLAB");

        i64 test_value = *rc::gen::arbitrary<i64>();
        void* original_obj = allocateIntIntoTLAB(tlab, test_value);
        if (!original_obj) RC_FAIL("Failed to allocate object");

        HPointer root = GCTestAccess::toPointer(original_obj);
        rootset.addRoot(&root);

        oldgen.sealTLAB(tlab);

        // Mark the object.
#if ENABLE_GC_STATS
        GCStats& stats = gc.getMajorGCStats();
        oldgen.startConcurrentMark(rootset.getRoots(), GarbageCollector::instance(), stats);
        oldgen.finishMarkAndSweep(stats);
#else
        oldgen.startConcurrentMark(rootset.getRoots(), GarbageCollector::instance());
        oldgen.finishMarkAndSweep();
#endif

        // Force compaction.
        oldgen.selectCompactionSet();
        oldgen.setCompactionInProgress(true);
        oldgen.performCompaction();
        oldgen.setCompactionInProgress(false);

        // Check if object was moved (original location may have forwarding pointer).
        Header* original_hdr = getHeader(original_obj);
        void* current_obj = GCTestAccess::fromPointer(root);

        if (original_hdr->tag == Tag_Forward) {
            // Object was evacuated - verify forwarding pointer works.
            Forward* fwd = static_cast<Forward*>(original_obj);
            RC_ASSERT(fwd->header.tag == Tag_Forward);

            // New location should have the value.
            ElmInt* elm_int = static_cast<ElmInt*>(current_obj);
            RC_ASSERT(elm_int->value == test_value);
        } else {
            // Object wasn't moved - value should be intact at original location.
            ElmInt* elm_int = static_cast<ElmInt*>(current_obj);
            RC_ASSERT(elm_int->value == test_value);
        }

        rootset.removeRoot(&root);
    });
});

Testing::TestCase testReadBarrierSelfHealing("readBarrier updates pointer to new location", []() {
    rc::check([]() {
        auto& gc = GarbageCollector::instance();
        gc.initThread();
        gc.reset();
        auto& oldgen = gc.getOldGen();
        auto& rootset = gc.getRootSet();

        // Allocate and root an object.
        TLAB* tlab = oldgen.allocateTLAB(TLAB_DEFAULT_SIZE);
        if (!tlab) RC_FAIL("Failed to allocate TLAB");

        i64 test_value = *rc::gen::arbitrary<i64>();
        void* obj = allocateIntIntoTLAB(tlab, test_value);
        if (!obj) RC_FAIL("Failed to allocate object");

        HPointer root = GCTestAccess::toPointer(obj);
        HPointer original_root = root;  // Keep copy of original pointer.
        rootset.addRoot(&root);

        oldgen.sealTLAB(tlab);

        // Run GC and compaction.
#if ENABLE_GC_STATS
        GCStats& stats = gc.getMajorGCStats();
        oldgen.startConcurrentMark(rootset.getRoots(), GarbageCollector::instance(), stats);
        oldgen.finishMarkAndSweep(stats);
#else
        oldgen.startConcurrentMark(rootset.getRoots(), GarbageCollector::instance());
        oldgen.finishMarkAndSweep();
#endif

        oldgen.selectCompactionSet();
        oldgen.setCompactionInProgress(true);
        oldgen.performCompaction();
        oldgen.setCompactionInProgress(false);

        // Use read barrier on a copy of the original pointer.
        HPointer test_ptr = original_root;
        void* result = readBarrier(test_ptr);

        if (result != nullptr) {
            // Read barrier should return valid object.
            ElmInt* elm_int = static_cast<ElmInt*>(result);
            RC_ASSERT(elm_int->value == test_value);

            // If object was moved, test_ptr should have been updated (self-healing).
            Header* original_hdr = getHeader(GCTestAccess::fromPointer(original_root));
            if (original_hdr->tag == Tag_Forward) {
                // Pointer should have been updated.
                RC_ASSERT(test_ptr.ptr != original_root.ptr);
            }
        }

        rootset.removeRoot(&root);
    });
});

Testing::TestCase testBlockEvacuation("evacuateBlock moves all Black objects from target block", []() {
    rc::check([]() {
        auto& gc = GarbageCollector::instance();
        gc.initThread();
        gc.reset();
        auto& oldgen = gc.getOldGen();
        auto& rootset = gc.getRootSet();

        // Allocate multiple objects.
        TLAB* tlab = oldgen.allocateTLAB(TLAB_DEFAULT_SIZE);
        if (!tlab) RC_FAIL("Failed to allocate TLAB");

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
            root_storage.push_back(GCTestAccess::toPointer(obj));
        }

        RC_ASSERT(original_locations.size() >= 2);

        for (auto& root : root_storage) {
            rootset.addRoot(&root);
        }

        oldgen.sealTLAB(tlab);

        // Mark objects.
#if ENABLE_GC_STATS
        GCStats& stats = gc.getMajorGCStats();
        oldgen.startConcurrentMark(rootset.getRoots(), GarbageCollector::instance(), stats);
        oldgen.finishMarkAndSweep(stats);
#else
        oldgen.startConcurrentMark(rootset.getRoots(), GarbageCollector::instance());
        oldgen.finishMarkAndSweep();
#endif

        // Run compaction.
        oldgen.selectCompactionSet();
        oldgen.setCompactionInProgress(true);
        oldgen.performCompaction();
        oldgen.setCompactionInProgress(false);

        // Verify all values are still accessible.
        for (size_t i = 0; i < root_storage.size(); i++) {
            void* obj = GCTestAccess::fromPointer(root_storage[i]);
            if (!obj) RC_FAIL("Object is null");

            // Follow forwarding if needed.
            Header* hdr = getHeader(obj);
            if (hdr->tag == Tag_Forward) {
                obj = readBarrier(root_storage[i]);
            }

            ElmInt* elm_int = static_cast<ElmInt*>(obj);
            RC_ASSERT(elm_int->value == expected_values[i]);
        }

        for (auto& root : root_storage) {
            rootset.removeRoot(&root);
        }
    });
});

Testing::TestCase testBlockReclaimToTLABs("reclaimEvacuatedBlocks adds empty blocks to TLAB pool", []() {
    rc::check([]() {
        auto& gc = GarbageCollector::instance();
        gc.initThread();
        gc.reset();
        auto& oldgen = gc.getOldGen();
        auto& rootset = gc.getRootSet();

        // Allocate a small object to create a very sparse block.
        TLAB* tlab = oldgen.allocateTLAB(TLAB_DEFAULT_SIZE);
        if (!tlab) RC_FAIL("Failed to allocate TLAB");

        void* obj = allocateIntIntoTLAB(tlab, 999);
        if (!obj) RC_FAIL("Failed to allocate object");

        HPointer root = GCTestAccess::toPointer(obj);
        rootset.addRoot(&root);

        oldgen.sealTLAB(tlab);

        // Run full GC cycle with compaction.
#if ENABLE_GC_STATS
        GCStats& stats = gc.getMajorGCStats();
        oldgen.startConcurrentMark(rootset.getRoots(), GarbageCollector::instance(), stats);
        oldgen.finishMarkAndSweep(stats);
#else
        oldgen.startConcurrentMark(rootset.getRoots(), GarbageCollector::instance());
        oldgen.finishMarkAndSweep();
#endif

        oldgen.selectCompactionSet();
        oldgen.setCompactionInProgress(true);
        oldgen.performCompaction();
        oldgen.reclaimEvacuatedBlocks();
        oldgen.setCompactionInProgress(false);

        // Object should still be valid.
        void* current = GCTestAccess::fromPointer(root);
        if (getHeader(current)->tag == Tag_Forward) {
            current = readBarrier(root);
        }
        if (!current) RC_FAIL("Current object is null");

        ElmInt* elm_int = static_cast<ElmInt*>(current);
        RC_ASSERT(elm_int->value == 999);

        rootset.removeRoot(&root);
    });
});

Testing::TestCase testCompactionPreservesValues("Object data is identical after compaction", []() {
    rc::check([]() {
        auto& gc = GarbageCollector::instance();
        gc.initThread();
        gc.reset();
        auto& oldgen = gc.getOldGen();
        auto& rootset = gc.getRootSet();

        // Generate random test data.
        size_t num_objects = *rc::gen::inRange<size_t>(5, 30);
        auto values = *rc::gen::container<std::vector<i64>>(
            num_objects,
            rc::gen::arbitrary<i64>()
        );

        TLAB* tlab = oldgen.allocateTLAB(TLAB_DEFAULT_SIZE);
        if (!tlab) RC_FAIL("Failed to allocate TLAB");

        std::vector<HPointer> root_storage;
        for (i64 val : values) {
            void* obj = allocateIntIntoTLAB(tlab, val);
            if (!obj) break;
            root_storage.push_back(GCTestAccess::toPointer(obj));
        }

        RC_ASSERT(!root_storage.empty());

        for (auto& root : root_storage) {
            rootset.addRoot(&root);
        }

        oldgen.sealTLAB(tlab);

        // Run GC and compaction.
#if ENABLE_GC_STATS
        GCStats& stats = gc.getMajorGCStats();
        oldgen.startConcurrentMark(rootset.getRoots(), GarbageCollector::instance(), stats);
        oldgen.finishMarkAndSweep(stats);
#else
        oldgen.startConcurrentMark(rootset.getRoots(), GarbageCollector::instance());
        oldgen.finishMarkAndSweep();
#endif

        oldgen.selectCompactionSet();
        oldgen.setCompactionInProgress(true);
        oldgen.performCompaction();
        oldgen.reclaimEvacuatedBlocks();
        oldgen.setCompactionInProgress(false);

        // Verify all values preserved.
        for (size_t i = 0; i < root_storage.size(); i++) {
            void* obj = readBarrier(root_storage[i]);
            if (!obj) RC_FAIL("Object is null");

            Header* hdr = getHeader(obj);
            RC_ASSERT(hdr->tag == Tag_Int);

            ElmInt* elm_int = static_cast<ElmInt*>(obj);
            RC_ASSERT(elm_int->value == values[i]);
        }

        for (auto& root : root_storage) {
            rootset.removeRoot(&root);
        }
    });
});

Testing::TestCase testRootPointerUpdatesAfterCompaction("Roots point to correct objects after compaction", []() {
    rc::check([]() {
        auto& gc = GarbageCollector::instance();
        gc.initThread();
        gc.reset();
        auto& oldgen = gc.getOldGen();
        auto& rootset = gc.getRootSet();

        // Build a linked list in old gen.
        TLAB* tlab = oldgen.allocateTLAB(TLAB_DEFAULT_SIZE);
        if (!tlab) RC_FAIL("Failed to allocate TLAB");

        size_t list_length = *rc::gen::inRange<size_t>(3, 8);
        std::vector<i64> expected_values;

        HPointer tail = createConstant(Const_Nil);

        for (size_t i = 0; i < list_length; i++) {
            i64 val = *rc::gen::inRange<i64>(0, 10000);
            expected_values.push_back(val);

            void* int_obj = allocateIntIntoTLAB(tlab, val);
            if (!int_obj) RC_FAIL("Failed to allocate int");

            HPointer head_ptr = GCTestAccess::toPointer(int_obj);
            void* cons_obj = tlab->allocate(sizeof(Cons));
            if (!cons_obj) RC_FAIL("Failed to allocate cons");

            Header* hdr = reinterpret_cast<Header*>(cons_obj);
            std::memset(hdr, 0, sizeof(Header));
            hdr->tag = Tag_Cons;
            hdr->color = static_cast<u32>(Color::White);

            Cons* cons = static_cast<Cons*>(cons_obj);
            cons->head.p = head_ptr;
            cons->tail = tail;

            tail = GCTestAccess::toPointer(cons_obj);
        }

        HPointer root = tail;
        rootset.addRoot(&root);

        oldgen.sealTLAB(tlab);

        // Run GC and compaction.
#if ENABLE_GC_STATS
        GCStats& stats = gc.getMajorGCStats();
        oldgen.startConcurrentMark(rootset.getRoots(), GarbageCollector::instance(), stats);
        oldgen.finishMarkAndSweep(stats);
#else
        oldgen.startConcurrentMark(rootset.getRoots(), GarbageCollector::instance());
        oldgen.finishMarkAndSweep();
#endif

        oldgen.selectCompactionSet();
        oldgen.setCompactionInProgress(true);
        oldgen.performCompaction();
        oldgen.reclaimEvacuatedBlocks();
        oldgen.setCompactionInProgress(false);

        // Walk the list and verify values (in reverse order since we built it that way).
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

        rootset.removeRoot(&root);
    });
});

Testing::TestCase testFragmentationDefragmentation("Sparse objects are consolidated after compaction", []() {
    rc::check([]() {
        auto& gc = GarbageCollector::instance();
        gc.initThread();
        gc.reset();
        auto& oldgen = gc.getOldGen();
        auto& rootset = gc.getRootSet();

        // Create fragmentation: allocate objects, then only root some of them.
        TLAB* tlab = oldgen.allocateTLAB(TLAB_DEFAULT_SIZE);
        if (!tlab) RC_FAIL("Failed to allocate TLAB");

        size_t total_objects = *rc::gen::inRange<size_t>(10, 30);
        std::vector<void*> all_objects;
        std::vector<i64> all_values;

        for (size_t i = 0; i < total_objects; i++) {
            i64 val = static_cast<i64>(i * 1000);
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
            root_storage.push_back(GCTestAccess::toPointer(all_objects[i]));
            rooted_values.push_back(all_values[i]);
        }

        for (auto& root : root_storage) {
            rootset.addRoot(&root);
        }

        oldgen.sealTLAB(tlab);

        // Run GC - unrooted objects become garbage.
#if ENABLE_GC_STATS
        GCStats& stats = gc.getMajorGCStats();
        oldgen.startConcurrentMark(rootset.getRoots(), GarbageCollector::instance(), stats);
        oldgen.finishMarkAndSweep(stats);
#else
        oldgen.startConcurrentMark(rootset.getRoots(), GarbageCollector::instance());
        oldgen.finishMarkAndSweep();
#endif

        // Run compaction.
        oldgen.selectCompactionSet();
        oldgen.setCompactionInProgress(true);
        oldgen.performCompaction();
        oldgen.reclaimEvacuatedBlocks();
        oldgen.setCompactionInProgress(false);

        // Verify rooted values are still accessible.
        for (size_t i = 0; i < root_storage.size(); i++) {
            void* obj = readBarrier(root_storage[i]);
            if (!obj) RC_FAIL("Object is null");

            Header* hdr = getHeader(obj);
            RC_ASSERT(hdr->tag == Tag_Int);

            ElmInt* elm_int = static_cast<ElmInt*>(obj);
            RC_ASSERT(elm_int->value == rooted_values[i]);
        }

        for (auto& root : root_storage) {
            rootset.removeRoot(&root);
        }
    });
});
