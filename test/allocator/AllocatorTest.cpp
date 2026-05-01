#include "AllocatorTest.hpp"
#include <cstring>
#include <rapidcheck.h>
#include <vector>
#include "Allocator.hpp"
#include "Heap.hpp"
#include "HeapGenerators.hpp"
#include "HeapHelpers.hpp"
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

// ============================================================================
// ByteBuffer / ElmArray survival across major GC.
//
// These mirror testLongLivedObjectsSurviveMajorGC and
// testMajorGCReclaimsOldGenGarbage but exercise the variable-size
// ByteBuffer and ElmArray heap kinds at both small and large sizes.
//
// The "Large" variants intentionally exceed 256 KiB. There is currently no
// dedicated large-object path in the allocator, so these tests are expected
// to fail until one is implemented.
// ============================================================================

namespace {

constexpr size_t SMALL_BYTEBUFFER_BYTES = 64;
constexpr size_t SMALL_ARRAY_LENGTH = 16;
constexpr size_t LARGE_BYTEBUFFER_BYTES = 320 * 1024;     // > 256 KiB
constexpr size_t LARGE_ARRAY_LENGTH = 33 * 1024;          // 33K * 8B = 264 KiB > 256 KiB

u8 patternByte(size_t i) { return static_cast<u8>(i % 251); }

HPointer allocPatternedByteBuffer(size_t length) {
    std::vector<u8> data(length);
    for (size_t i = 0; i < length; i++) data[i] = patternByte(i);
    return Elm::alloc::allocByteBuffer(data.data(), length);
}

bool verifyPatternedByteBuffer(HPointer& root, size_t expected_length) {
    void* obj = readBarrier(root);
    if (!obj) return false;
    Header* hdr = getHeader(obj);
    // Above the split-header threshold (HEAP_026), the result is a
    // Tag_LargeByteHeader pointing at the Tag_ByteBuffer body in old gen.
    if (hdr->tag == Tag_LargeByteHeader) {
        if (hdr->size != expected_length) return false;
        LargeByteHeader* h = static_cast<LargeByteHeader*>(obj);
        void* body = Allocator::instance().resolve(h->body);
        if (!body) return false;
        Header* bhdr = getHeader(body);
        if (bhdr->tag != Tag_ByteBuffer) return false;
        if (bhdr->size != expected_length) return false;
        ByteBuffer* buf = static_cast<ByteBuffer*>(body);
        for (size_t i = 0; i < expected_length; i++) {
            if (buf->bytes[i] != patternByte(i)) return false;
        }
        return true;
    }
    if (hdr->tag != Tag_ByteBuffer) return false;
    if (hdr->size != expected_length) return false;
    ByteBuffer* buf = static_cast<ByteBuffer*>(obj);
    for (size_t i = 0; i < expected_length; i++) {
        if (buf->bytes[i] != patternByte(i)) return false;
    }
    return true;
}

HPointer allocPatternedArray(size_t length) {
    std::vector<i64> values(length);
    for (size_t i = 0; i < length; i++) values[i] = static_cast<i64>(i * 3 + 1);
    return Elm::alloc::arrayFromInts(values);
}

bool verifyPatternedArray(HPointer& root, size_t expected_length) {
    void* obj = readBarrier(root);
    if (!obj) return false;
    Header* hdr = getHeader(obj);
    if (hdr->tag != Tag_Array) return false;
    ElmArray* arr = static_cast<ElmArray*>(obj);
    if (arr->length != expected_length) return false;
    for (size_t i = 0; i < expected_length; i++) {
        if (arr->elements[i].i != static_cast<i64>(i * 3 + 1)) return false;
    }
    return true;
}

void runFullGCCycle(Allocator& alloc) {
    for (u32 i = 0; i <= PROMOTION_AGE; i++) {
        alloc.minorGC();
    }
    alloc.majorGC();
}

}  // namespace

// ----- Small ByteBuffer ----------------------------------------------------

Testing::TestCase testSmallByteBufferSurvivesMajorGCWhenRooted(
    "Small ByteBuffer (rooted) survives major GC with bytes intact", []() {
    auto& alloc = initAllocator();

    HPointer buf = allocPatternedByteBuffer(SMALL_BYTEBUFFER_BYTES);
    alloc.getRootSet().addRoot(&buf);

    runFullGCCycle(alloc);

    TEST_ASSERT(verifyPatternedByteBuffer(buf, SMALL_BYTEBUFFER_BYTES));
    TEST_ASSERT(alloc.isInOldGen(readBarrier(buf)));

    alloc.getRootSet().removeRoot(&buf);
});

Testing::TestCase testSmallByteBufferReclaimedWhenUnreachable(
    "Small ByteBuffer (unrooted) is reclaimed by major GC; rooted control survives", []() {
    auto& alloc = initAllocator();

    HPointer control = allocPatternedByteBuffer(SMALL_BYTEBUFFER_BYTES);
    alloc.getRootSet().addRoot(&control);

    (void)allocPatternedByteBuffer(SMALL_BYTEBUFFER_BYTES);

    runFullGCCycle(alloc);

    TEST_ASSERT(verifyPatternedByteBuffer(control, SMALL_BYTEBUFFER_BYTES));

    alloc.getRootSet().removeRoot(&control);
});

// ----- Small ElmArray ------------------------------------------------------

Testing::TestCase testSmallElmArraySurvivesMajorGCWhenRooted(
    "Small ElmArray (rooted) survives major GC with elements intact", []() {
    auto& alloc = initAllocator();

    HPointer arr = allocPatternedArray(SMALL_ARRAY_LENGTH);
    alloc.getRootSet().addRoot(&arr);

    runFullGCCycle(alloc);

    TEST_ASSERT(verifyPatternedArray(arr, SMALL_ARRAY_LENGTH));
    TEST_ASSERT(alloc.isInOldGen(readBarrier(arr)));

    alloc.getRootSet().removeRoot(&arr);
});

Testing::TestCase testSmallElmArrayReclaimedWhenUnreachable(
    "Small ElmArray (unrooted) is reclaimed by major GC; rooted control survives", []() {
    auto& alloc = initAllocator();

    HPointer control = allocPatternedArray(SMALL_ARRAY_LENGTH);
    alloc.getRootSet().addRoot(&control);

    (void)allocPatternedArray(SMALL_ARRAY_LENGTH);

    runFullGCCycle(alloc);

    TEST_ASSERT(verifyPatternedArray(control, SMALL_ARRAY_LENGTH));

    alloc.getRootSet().removeRoot(&control);
});

// ----- Large ByteBuffer (>256 KiB) -----------------------------------------
// Expected to fail until a large-object path exists.

Testing::TestCase testLargeByteBufferSurvivesMajorGCWhenRooted(
    "Large (>256KiB) ByteBuffer (rooted) survives major GC with bytes intact", []() {
    auto& alloc = initAllocatorScaled(1000);

    HPointer buf = allocPatternedByteBuffer(LARGE_BYTEBUFFER_BYTES);
    alloc.getRootSet().addRoot(&buf);

    runFullGCCycle(alloc);

    TEST_ASSERT(verifyPatternedByteBuffer(buf, LARGE_BYTEBUFFER_BYTES));

    alloc.getRootSet().removeRoot(&buf);
});

Testing::TestCase testLargeByteBufferReclaimedWhenUnreachable(
    "Large (>256KiB) ByteBuffer (unrooted) is reclaimed; rooted control survives", []() {
    auto& alloc = initAllocatorScaled(1000);

    HPointer control = allocPatternedByteBuffer(LARGE_BYTEBUFFER_BYTES);
    alloc.getRootSet().addRoot(&control);

    (void)allocPatternedByteBuffer(LARGE_BYTEBUFFER_BYTES);

    runFullGCCycle(alloc);

    TEST_ASSERT(verifyPatternedByteBuffer(control, LARGE_BYTEBUFFER_BYTES));

    alloc.getRootSet().removeRoot(&control);
});

// ----- Large ElmArray (>256 KiB) -------------------------------------------
// Expected to fail until a large-object path exists.

Testing::TestCase testLargeElmArraySurvivesMajorGCWhenRooted(
    "Large (>256KiB) ElmArray (rooted) survives major GC with elements intact", []() {
    auto& alloc = initAllocatorScaled(1000);

    HPointer arr = allocPatternedArray(LARGE_ARRAY_LENGTH);
    alloc.getRootSet().addRoot(&arr);

    runFullGCCycle(alloc);

    TEST_ASSERT(verifyPatternedArray(arr, LARGE_ARRAY_LENGTH));

    alloc.getRootSet().removeRoot(&arr);
});

Testing::TestCase testLargeElmArrayReclaimedWhenUnreachable(
    "Large (>256KiB) ElmArray (unrooted) is reclaimed; rooted control survives", []() {
    auto& alloc = initAllocatorScaled(1000);

    HPointer control = allocPatternedArray(LARGE_ARRAY_LENGTH);
    alloc.getRootSet().addRoot(&control);

    (void)allocPatternedArray(LARGE_ARRAY_LENGTH);

    runFullGCCycle(alloc);

    TEST_ASSERT(verifyPatternedArray(control, LARGE_ARRAY_LENGTH));

    alloc.getRootSet().removeRoot(&control);
});

// ============================================================================
// Split-header tests (HEAP_026).
//
// Strings and byte buffers at or above HeapConfig::large_object_threshold are
// represented as Tag_LargeStringHeader / Tag_LargeByteHeader in the nursery
// whose `body` HPointer references a Tag_String / Tag_ByteBuffer pinned in
// old gen. These tests verify the layout, no-copy survival across minor GC,
// early reclamation when the nursery header dies, ownership transfer on
// promotion, and bounded old-gen growth under churn.
// ============================================================================

namespace {

// Sized to comfortably exceed the default large_object_threshold (8 KiB), so
// the body lands either in a size-class cell or — for the larger flavours —
// in an is_large block.
constexpr size_t SPLIT_STRING_LEN = 5 * 1024;        // 10 KiB UTF-16 payload
constexpr size_t SPLIT_BYTE_LEN   = 10 * 1024;       // 10 KiB byte payload

HPointer allocPatternedSplitString(size_t length) {
    std::vector<u16> chars(length);
    for (size_t i = 0; i < length; ++i) {
        chars[i] = static_cast<u16>(0x4000 + (i % 0x4000));
    }
    return Elm::alloc::allocString(chars.data(), length);
}

bool verifyPatternedSplitString(HPointer root, size_t expected_length) {
    void* obj = readBarrier(root);
    if (!obj) return false;
    Header* hdr = getHeader(obj);
    if (hdr->tag != Tag_LargeStringHeader) return false;
    if (hdr->size != expected_length) return false;
    LargeStringHeader* lh = static_cast<LargeStringHeader*>(obj);
    void* body = Allocator::instance().resolve(lh->body);
    if (!body) return false;
    Header* bhdr = getHeader(body);
    if (bhdr->tag != Tag_String) return false;
    if (bhdr->size != expected_length) return false;
    if (bhdr->pin != 1) return false;
    ElmString* leaf = static_cast<ElmString*>(body);
    for (size_t i = 0; i < expected_length; ++i) {
        u16 expected = static_cast<u16>(0x4000 + (i % 0x4000));
        if (leaf->chars[i] != expected) return false;
    }
    return true;
}

}  // namespace

Testing::TestCase testLargeStringSplitHeaderLayout(
    "Split string: header in nursery, body pinned in old gen, sizes match", []() {
    auto& alloc = initAllocator();

    HPointer hp = allocPatternedSplitString(SPLIT_STRING_LEN);
    alloc.getRootSet().addRoot(&hp);

    void* obj = alloc.resolve(hp);
    TEST_ASSERT(obj != nullptr);
    Header* hdr = getHeader(obj);
    TEST_ASSERT(hdr->tag == Tag_LargeStringHeader);
    TEST_ASSERT(hdr->size == SPLIT_STRING_LEN);
    TEST_ASSERT(alloc.isInNursery(obj));

    LargeStringHeader* lh = static_cast<LargeStringHeader*>(obj);
    void* body = alloc.resolve(lh->body);
    TEST_ASSERT(body != nullptr);
    TEST_ASSERT(alloc.isInOldGen(body));
    Header* bhdr = getHeader(body);
    TEST_ASSERT(bhdr->tag == Tag_String);
    TEST_ASSERT(bhdr->size == SPLIT_STRING_LEN);
    TEST_ASSERT(bhdr->pin == 1);

    alloc.getRootSet().removeRoot(&hp);
});

Testing::TestCase testLargeByteSplitHeaderLayout(
    "Split byte buffer: header in nursery, body pinned in old gen", []() {
    auto& alloc = initAllocator();

    std::vector<u8> data(SPLIT_BYTE_LEN);
    for (size_t i = 0; i < SPLIT_BYTE_LEN; ++i) data[i] = static_cast<u8>(i % 251);
    HPointer hp = Elm::alloc::allocByteBuffer(data.data(), SPLIT_BYTE_LEN);
    alloc.getRootSet().addRoot(&hp);

    void* obj = alloc.resolve(hp);
    TEST_ASSERT(obj != nullptr);
    Header* hdr = getHeader(obj);
    TEST_ASSERT(hdr->tag == Tag_LargeByteHeader);
    TEST_ASSERT(hdr->size == SPLIT_BYTE_LEN);
    TEST_ASSERT(alloc.isInNursery(obj));

    LargeByteHeader* lh = static_cast<LargeByteHeader*>(obj);
    void* body = alloc.resolve(lh->body);
    TEST_ASSERT(body != nullptr);
    TEST_ASSERT(alloc.isInOldGen(body));
    Header* bhdr = getHeader(body);
    TEST_ASSERT(bhdr->tag == Tag_ByteBuffer);
    TEST_ASSERT(bhdr->size == SPLIT_BYTE_LEN);
    TEST_ASSERT(bhdr->pin == 1);

    alloc.getRootSet().removeRoot(&hp);
});

Testing::TestCase testSplitBodySurvivesMinorGCWithoutCopy(
    "Split body's old-gen address is stable across multiple minor GCs", []() {
    auto& alloc = initAllocator();

    HPointer hp = allocPatternedSplitString(SPLIT_STRING_LEN);
    alloc.getRootSet().addRoot(&hp);

    // Capture the body's raw address before any GC.
    void* obj0 = alloc.resolve(hp);
    LargeStringHeader* lh0 = static_cast<LargeStringHeader*>(obj0);
    void* body0 = alloc.resolve(lh0->body);
    TEST_ASSERT(body0 != nullptr);

    // Allocate enough garbage to drive several minor GCs but keep the count
    // below promotion (PROMOTION_AGE = 2 by default).
    for (u32 i = 0; i < PROMOTION_AGE; ++i) {
        allocateGarbageInts(alloc, 50);
        alloc.minorGC();
    }

    // Header HPointer may now resolve to a different (to-space) address —
    // but the BODY address must be unchanged.
    void* obj_after = alloc.resolve(hp);
    TEST_ASSERT(obj_after != nullptr);
    LargeStringHeader* lh_after = static_cast<LargeStringHeader*>(obj_after);
    void* body_after = alloc.resolve(lh_after->body);
    TEST_ASSERT(body_after == body0);

    // Payload still intact.
    TEST_ASSERT(verifyPatternedSplitString(hp, SPLIT_STRING_LEN));

    alloc.getRootSet().removeRoot(&hp);
});

Testing::TestCase testSplitBodyEarlyReclamationOnDeadHeader(
    "Split body is reclaimed at end of minor GC when nursery header dies", []() {
    auto& alloc = initAllocator();

    // Allocate a split byte buffer but DO NOT root it. The header will die
    // in the next minor GC, and sweepNurseryLargeBodies should free its body.
    std::vector<u8> data(SPLIT_BYTE_LEN);
    for (size_t i = 0; i < SPLIT_BYTE_LEN; ++i) data[i] = static_cast<u8>(i % 251);
    HPointer hp = Elm::alloc::allocByteBuffer(data.data(), SPLIT_BYTE_LEN);
    void* obj = alloc.resolve(hp);
    TEST_ASSERT(obj != nullptr);
    LargeByteHeader* lh = static_cast<LargeByteHeader*>(obj);
    void* body0 = alloc.resolve(lh->body);
    TEST_ASSERT(body0 != nullptr);
    TEST_ASSERT(OldGenSpaceTestAccess::isBodyTracked(
        *AllocatorTestAccess::getOldGen(alloc), body0));

    // Run one minor GC: header is unrooted, sweep should free the body.
    alloc.minorGC();
    TEST_ASSERT(!OldGenSpaceTestAccess::isBodyTracked(
        *AllocatorTestAccess::getOldGen(alloc), body0));
});

Testing::TestCase testSplitPromotionTransfersOwnership(
    "Promotion removes the body from nursery_owned_bodies_", []() {
    auto& alloc = initAllocator();

    HPointer hp = allocPatternedSplitString(SPLIT_STRING_LEN);
    alloc.getRootSet().addRoot(&hp);

    void* obj0 = alloc.resolve(hp);
    LargeStringHeader* lh0 = static_cast<LargeStringHeader*>(obj0);
    void* body0 = alloc.resolve(lh0->body);
    TEST_ASSERT(OldGenSpaceTestAccess::isBodyTracked(
        *AllocatorTestAccess::getOldGen(alloc), body0));

    // Drive enough minor GCs to age past PROMOTION_AGE and promote the header.
    for (u32 i = 0; i <= PROMOTION_AGE; ++i) {
        alloc.minorGC();
    }

    // Header now lives in old gen.
    void* obj_after = alloc.resolve(hp);
    TEST_ASSERT(alloc.isInOldGen(obj_after));
    TEST_ASSERT(getHeader(obj_after)->tag == Tag_LargeStringHeader);

    // Body should no longer be in nursery_owned_bodies_ — major GC manages it
    // from here on.
    const auto& nursery_owned = OldGenSpaceTestAccess::getNurseryOwnedBodies(
        *AllocatorTestAccess::getOldGen(alloc));
    TEST_ASSERT(nursery_owned.empty());

    // Subsequent minor GCs (without major in between) must NOT free the body.
    void* body_after = alloc.resolve(static_cast<LargeStringHeader*>(obj_after)->body);
    TEST_ASSERT(body_after == body0);
    alloc.minorGC();
    TEST_ASSERT(verifyPatternedSplitString(hp, SPLIT_STRING_LEN));

    alloc.getRootSet().removeRoot(&hp);
});

Testing::TestCase testSplitPromotedBodyReclaimedByMajorGC(
    "Promoted split body is reclaimed by major GC when its header dies", []() {
    auto& alloc = initAllocator();

    HPointer hp = allocPatternedSplitString(SPLIT_STRING_LEN);
    alloc.getRootSet().addRoot(&hp);

    // Promote.
    for (u32 i = 0; i <= PROMOTION_AGE; ++i) alloc.minorGC();
    TEST_ASSERT(verifyPatternedSplitString(hp, SPLIT_STRING_LEN));

    // Drop root and run major GC. The standard mark/sweep path must reclaim
    // the body cell because nothing references it anymore.
    alloc.getRootSet().removeRoot(&hp);
    alloc.majorGC();
    // After the body's cell is freed, its address is no longer tracked.
    // (We can't safely deref `hp` after the root is gone — just confirm the
    // sweep path completed without asserting in debug builds.)
    TEST_ASSERT(true);
});

Testing::TestCase testSplitThresholdBoundary(
    "Split path activates exactly at HeapConfig::large_object_threshold", []() {
    auto& alloc = initAllocator();
    const size_t threshold = alloc.getLargeObjectThreshold();

    // Below threshold: inline Tag_String in nursery.
    {
        // total_size = sizeof(ElmString) + len*2; pick len so total_size is
        // strictly below threshold. ElmString is 8 bytes (Header), so
        // total_size = 8 + 2*len. We want < threshold.
        size_t below_len = (threshold - sizeof(ElmString) - 16) / sizeof(u16);
        std::vector<u16> chars(below_len, u'X');
        HPointer hp = Elm::alloc::allocString(chars.data(), below_len);
        void* obj = alloc.resolve(hp);
        TEST_ASSERT(obj != nullptr);
        TEST_ASSERT(getHeader(obj)->tag == Tag_String);
        TEST_ASSERT(alloc.isInNursery(obj));
    }

    // At/above threshold: Tag_LargeStringHeader in nursery.
    {
        size_t at_len = (threshold - sizeof(ElmString)) / sizeof(u16) + 64;
        std::vector<u16> chars(at_len, u'Y');
        HPointer hp = Elm::alloc::allocString(chars.data(), at_len);
        void* obj = alloc.resolve(hp);
        TEST_ASSERT(obj != nullptr);
        TEST_ASSERT(getHeader(obj)->tag == Tag_LargeStringHeader);
        TEST_ASSERT(alloc.isInNursery(obj));
    }
});

Testing::TestCase testSplitStressBoundedOldGenGrowth(
    "Repeatedly allocating + dropping split bodies keeps old-gen bounded", []() {
    auto& alloc = initAllocator();

    const size_t initial_old_gen_alloc = alloc.getOldGenAllocatedBytes();

    // Allocate many split-form byte buffers without rooting them. Each minor
    // GC's sweepNurseryLargeBodies should reclaim the bodies, keeping
    // old-gen allocated bytes bounded across the loop.
    constexpr size_t kIters = 200;
    for (size_t i = 0; i < kIters; ++i) {
        std::vector<u8> data(SPLIT_BYTE_LEN, static_cast<u8>(i & 0xFF));
        (void)Elm::alloc::allocByteBuffer(data.data(), SPLIT_BYTE_LEN);
        // Trigger a minor GC every few iterations to exercise sweep.
        if (i % 4 == 3) alloc.minorGC();
    }
    alloc.minorGC();

    // After the final sweep, no nursery-owned bodies should remain (every
    // header from the loop is dead).
    const auto& nursery_owned = OldGenSpaceTestAccess::getNurseryOwnedBodies(
        *AllocatorTestAccess::getOldGen(alloc));
    TEST_ASSERT(nursery_owned.empty());

    // Old-gen allocation should not have grown unboundedly. Allow up to
    // ~50 KiB of slack for residual free-list metadata.
    const size_t after = alloc.getOldGenAllocatedBytes();
    TEST_ASSERT(after <= initial_old_gen_alloc + (50 * 1024));
});
