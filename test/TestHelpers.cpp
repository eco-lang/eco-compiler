#include "TestHelpers.hpp"
#include <cstring>
#include <rapidcheck.h>

namespace Elm {
namespace TestHelpers {

// ============================================================================
// 1. GC Initialization
// ============================================================================

GarbageCollector& initGC() {
    auto& gc = GarbageCollector::instance();
    gc.initThread();
    gc.reset();
    return gc;
}

// ============================================================================
// 2. Create and Root Multiple ElmInts
// ============================================================================

void RootedInts::registerRoots(GarbageCollector& gc) {
    for (auto& root : roots) {
        gc.getRootSet().addRoot(&root);
    }
}

void RootedInts::unregisterRoots(GarbageCollector& gc) {
    for (auto& root : roots) {
        gc.getRootSet().removeRoot(&root);
    }
}

RootedInts createRootedInts(GarbageCollector& gc, size_t count) {
    RootedInts result;
    result.values.reserve(count);
    result.roots.reserve(count);

    for (size_t i = 0; i < count; i++) {
        i64 val = *rc::gen::arbitrary<i64>();
        void* obj = gc.allocate(sizeof(ElmInt), Tag_Int);
        if (!obj) break;

        ElmInt* elm_int = static_cast<ElmInt*>(obj);
        elm_int->value = val;
        result.values.push_back(val);
        result.roots.push_back(toPointer(obj));
    }

    return result;
}

RootedInts createRootedIntsWithValues(GarbageCollector& gc, const std::vector<i64>& values) {
    RootedInts result;
    result.values.reserve(values.size());
    result.roots.reserve(values.size());

    for (i64 val : values) {
        void* obj = gc.allocate(sizeof(ElmInt), Tag_Int);
        if (!obj) break;

        ElmInt* elm_int = static_cast<ElmInt*>(obj);
        elm_int->value = val;
        result.values.push_back(val);
        result.roots.push_back(toPointer(obj));
    }

    return result;
}

// ============================================================================
// 3. Unregister Roots
// ============================================================================

void unregisterRoots(GarbageCollector& gc, std::vector<HPointer>& roots) {
    for (auto& root : roots) {
        gc.getRootSet().removeRoot(&root);
    }
}

// ============================================================================
// 4. Promote Objects to Old Gen
// ============================================================================

void promoteToOldGen(GarbageCollector& gc) {
    for (u32 i = 0; i <= PROMOTION_AGE; i++) {
        gc.minorGC();
    }
}

// ============================================================================
// 5. Verify ElmInt Values
// ============================================================================

void verifyIntValues(const std::vector<HPointer>& roots,
                     const std::vector<i64>& expected) {
    RC_ASSERT(roots.size() == expected.size());

    for (size_t i = 0; i < roots.size(); i++) {
        HPointer ptr = roots[i];  // Make mutable copy for readBarrier
        void* obj = readBarrier(ptr);
        if (!obj) RC_FAIL("Object is null");

        Header* hdr = getHeader(obj);
        RC_ASSERT(hdr->tag == Tag_Int);

        ElmInt* elm_int = static_cast<ElmInt*>(obj);
        RC_ASSERT(elm_int->value == expected[i]);
    }
}

// ============================================================================
// 6. Create Constant HPointer
// ============================================================================

HPointer createConstant(Constant c) {
    HPointer ptr;
    ptr.ptr = 0;
    ptr.constant = c;
    ptr.padding = 0;
    return ptr;
}

// ============================================================================
// 7. Allocate ElmInt into TLAB
// ============================================================================

void* allocateIntIntoTLAB(TLAB* tlab, i64 value) {
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
// 8. Run Mark-and-Sweep (Stats-Aware)
// ============================================================================

void runMarkAndSweep(GarbageCollector& gc) {
    auto& oldgen = gc.getOldGen();
    auto& rootset = gc.getRootSet();

#if ENABLE_GC_STATS
    GCStats& stats = gc.getMajorGCStats();
    oldgen.startConcurrentMark(rootset, GarbageCollector::instance(), stats);
    oldgen.finishMarkAndSweep(stats);
#else
    oldgen.startConcurrentMark(rootset, GarbageCollector::instance());
    oldgen.finishMarkAndSweep();
#endif
}

// ============================================================================
// 9. Run Compaction Sequence
// ============================================================================

void runCompaction(OldGenSpace& oldgen, bool reclaimBlocks) {
    oldgen.selectCompactionSet();
    oldgen.setCompactionInProgress(true);
    oldgen.performCompaction();
    if (reclaimBlocks) {
        oldgen.reclaimEvacuatedBlocks();
    }
    oldgen.setCompactionInProgress(false);
}

// ============================================================================
// 10. Setup Roots from HeapGraphDesc
// ============================================================================

GraphRoots::~GraphRoots() {
    if (gc) {
        for (auto& root : storage) {
            gc->getRootSet().removeRoot(&root);
        }
    }
}

GraphRoots::GraphRoots(GraphRoots&& other) noexcept
    : gc(other.gc), storage(std::move(other.storage)), ptrs(std::move(other.ptrs)) {
    other.gc = nullptr;
}

GraphRoots& GraphRoots::operator=(GraphRoots&& other) noexcept {
    if (this != &other) {
        // Clean up existing
        if (gc) {
            for (auto& root : storage) {
                gc->getRootSet().removeRoot(&root);
            }
        }
        // Move from other
        gc = other.gc;
        storage = std::move(other.storage);
        ptrs = std::move(other.ptrs);
        other.gc = nullptr;
    }
    return *this;
}

GraphRoots setupRootsFromGraph(GarbageCollector& gc,
                                const HeapGraphDesc& graph,
                                const std::vector<void*>& allocated_objects) {
    GraphRoots result;
    result.gc = &gc;

    for (size_t idx : graph.root_indices) {
        if (idx < allocated_objects.size()) {
            result.storage.push_back(toPointer(allocated_objects[idx]));
        }
    }

    // If no valid roots from graph, use first object as root
    if (result.storage.empty() && !allocated_objects.empty()) {
        result.storage.push_back(toPointer(allocated_objects[0]));
    }

    for (auto& root : result.storage) {
        result.ptrs.push_back(&root);
        gc.getRootSet().addRoot(&root);
    }

    return result;
}

// ============================================================================
// 11. Allocate Garbage Ints
// ============================================================================

void allocateGarbageInts(GarbageCollector& gc, size_t count) {
    for (size_t j = 0; j < count; j++) {
        void* garbage = gc.allocate(sizeof(ElmInt), Tag_Int);
        if (garbage) {
            static_cast<ElmInt*>(garbage)->value = static_cast<i64>(j);
        }
    }
}

// ============================================================================
// 12. Allocate TLAB with Assertion
// ============================================================================

TLAB* allocateTLABOrFail(OldGenSpace& oldgen, size_t size) {
    TLAB* tlab = oldgen.allocateTLAB(size);
    if (!tlab) RC_FAIL("Failed to allocate TLAB");
    return tlab;
}

// ============================================================================
// 13. Build Linked List
// ============================================================================

LinkedList buildLinkedList(GarbageCollector& gc, size_t length) {
    LinkedList result;
    result.head = createNil();

    for (size_t i = 0; i < length; i++) {
        i64 val = *rc::gen::arbitrary<i64>();
        result.values.push_back(val);

        // Allocate Int
        void* int_obj = gc.allocate(sizeof(ElmInt), Tag_Int);
        if (!int_obj) RC_FAIL("Failed to allocate int");
        static_cast<ElmInt*>(int_obj)->value = val;

        // Allocate Cons
        void* cons_obj = gc.allocate(sizeof(Cons), Tag_Cons);
        if (!cons_obj) RC_FAIL("Failed to allocate cons");

        Cons* cons = static_cast<Cons*>(cons_obj);
        cons->head.p = toPointer(int_obj);
        cons->tail = result.head;

        result.head = toPointer(cons_obj);
    }

    // Reverse values so they match traversal order
    std::reverse(result.values.begin(), result.values.end());

    return result;
}

LinkedList buildLinkedListInTLAB(TLAB* tlab, size_t length) {
    LinkedList result;
    result.head = createNil();

    for (size_t i = 0; i < length; i++) {
        i64 val = *rc::gen::arbitrary<i64>();
        result.values.push_back(val);

        void* int_obj = allocateIntIntoTLAB(tlab, val);
        if (!int_obj) RC_FAIL("Failed to allocate int into TLAB");

        HPointer head_ptr = toPointer(int_obj);
        void* cons_obj = allocateConsIntoTLAB(tlab, head_ptr, result.head, true);
        if (!cons_obj) RC_FAIL("Failed to allocate cons into TLAB");

        result.head = toPointer(cons_obj);
    }

    // Reverse values so they match traversal order
    std::reverse(result.values.begin(), result.values.end());

    return result;
}

// ============================================================================
// 14. Verify Linked List
// ============================================================================

void verifyLinkedList(HPointer head, const std::vector<i64>& expected) {
    HPointer current = head;
    size_t idx = 0;

    while (current.constant == 0) {
        void* obj = readBarrier(current);
        if (!obj) break;

        Header* hdr = getHeader(obj);
        if (hdr->tag != Tag_Cons) break;

        Cons* cons = static_cast<Cons*>(obj);

        // Get head value
        void* head_obj = readBarrier(cons->head.p);
        if (head_obj && getHeader(head_obj)->tag == Tag_Int) {
            RC_ASSERT(idx < expected.size());
            ElmInt* elm_int = static_cast<ElmInt*>(head_obj);
            RC_ASSERT(elm_int->value == expected[idx]);
            idx++;
        }

        current = cons->tail;
    }

    RC_ASSERT(idx == expected.size());
}

// ============================================================================
// 15. Assert Object is Int with Value
// ============================================================================

void assertObjectIsInt(void* obj, i64 expected) {
    if (!obj) RC_FAIL("Object is null");

    Header* hdr = getHeader(obj);
    RC_ASSERT(hdr->tag == Tag_Int);

    ElmInt* elm_int = static_cast<ElmInt*>(obj);
    RC_ASSERT(elm_int->value == expected);
}

void assertObjectIsInt(HPointer ptr, i64 expected) {
    void* obj = readBarrier(ptr);
    assertObjectIsInt(obj, expected);
}

// ============================================================================
// Additional Utilities
// ============================================================================

void* allocateConsIntoTLAB(TLAB* tlab, HPointer head_ptr, HPointer tail_ptr, bool head_boxed) {
    void* obj = tlab->allocate(sizeof(Cons));
    if (!obj) return nullptr;

    Header* hdr = reinterpret_cast<Header*>(obj);
    std::memset(hdr, 0, sizeof(Header));
    hdr->tag = Tag_Cons;
    hdr->color = static_cast<u32>(Color::White);
    hdr->unboxed = head_boxed ? 0 : 1;  // bit 0 = head unboxed flag

    Cons* cons = static_cast<Cons*>(obj);
    cons->head.p = head_ptr;
    cons->tail = tail_ptr;

    return obj;
}

void* allocateIntInOldGen(OldGenSpace& oldgen, i64 value) {
    void* obj = oldgen.allocate(sizeof(ElmInt));
    if (!obj) return nullptr;

    Header* hdr = reinterpret_cast<Header*>(obj);
    hdr->tag = Tag_Int;
    hdr->color = static_cast<u32>(Color::White);

    ElmInt* elm_int = static_cast<ElmInt*>(obj);
    elm_int->value = value;

    return obj;
}

} // namespace TestHelpers
} // namespace Elm
