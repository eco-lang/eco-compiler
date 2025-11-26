#include "TestHelpers.hpp"
#include <cstring>
#include <rapidcheck.h>

namespace Elm {
namespace TestHelpers {

// ============================================================================
// 1. Allocator Initialization
// ============================================================================

Allocator& initAllocator(const HeapConfig& config) {
    auto& alloc = Allocator::instance();
    alloc.initThread();
    alloc.reset(&config);
    return alloc;
}

// ============================================================================
// 2. Create and Root Multiple ElmInts
// ============================================================================

void RootedInts::registerRoots(Allocator& alloc) {
    for (auto& root : roots) {
        alloc.getRootSet().addRoot(&root);
    }
}

void RootedInts::unregisterRoots(Allocator& alloc) {
    for (auto& root : roots) {
        alloc.getRootSet().removeRoot(&root);
    }
}

RootedInts createRootedInts(Allocator& alloc, size_t count) {
    RootedInts result;
    result.values.reserve(count);
    result.roots.reserve(count);

    for (size_t i = 0; i < count; i++) {
        i64 val = *rc::gen::arbitrary<i64>();
        void* obj = alloc.allocate(sizeof(ElmInt), Tag_Int);
        if (!obj) break;

        ElmInt* elm_int = static_cast<ElmInt*>(obj);
        elm_int->value = val;
        result.values.push_back(val);
        result.roots.push_back(AllocatorTestAccess::toPointer(obj));
    }

    return result;
}

RootedInts createRootedIntsWithValues(Allocator& alloc, const std::vector<i64>& values) {
    RootedInts result;
    result.values.reserve(values.size());
    result.roots.reserve(values.size());

    for (i64 val : values) {
        void* obj = alloc.allocate(sizeof(ElmInt), Tag_Int);
        if (!obj) break;

        ElmInt* elm_int = static_cast<ElmInt*>(obj);
        elm_int->value = val;
        result.values.push_back(val);
        result.roots.push_back(AllocatorTestAccess::toPointer(obj));
    }

    return result;
}

// ============================================================================
// 3. Unregister Roots
// ============================================================================

void unregisterRoots(Allocator& alloc, std::vector<HPointer>& roots) {
    for (auto& root : roots) {
        alloc.getRootSet().removeRoot(&root);
    }
}

// ============================================================================
// 4. Promote Objects to Old Gen
// ============================================================================

void promoteToOldGen(Allocator& alloc) {
    for (u32 i = 0; i <= PROMOTION_AGE; i++) {
        alloc.minorGC();
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
// 7. Run Mark-and-Sweep (Stats-Aware)
// ============================================================================

void runMarkAndSweep(Allocator& alloc) {
    auto& oldgen = alloc.getOldGen();
    auto& rootset = alloc.getRootSet();

#if ENABLE_GC_STATS
    GCStats& stats = alloc.getMajorGCStats();
    oldgen.startMark(rootset.getRoots(), Allocator::instance(), stats);
    oldgen.finishMarkAndSweep(stats);
#else
    oldgen.startMark(rootset.getRoots(), Allocator::instance());
    oldgen.finishMarkAndSweep();
#endif
}

// ============================================================================
// 8. Setup Roots from HeapGraphDesc
// ============================================================================

GraphRoots::~GraphRoots() {
    if (alloc) {
        for (auto& root : storage) {
            alloc->getRootSet().removeRoot(&root);
        }
    }
}

GraphRoots::GraphRoots(GraphRoots&& other) noexcept
    : alloc(other.alloc), storage(std::move(other.storage)), ptrs(std::move(other.ptrs)) {
    other.alloc = nullptr;
}

GraphRoots& GraphRoots::operator=(GraphRoots&& other) noexcept {
    if (this != &other) {
        // Clean up existing
        if (alloc) {
            for (auto& root : storage) {
                alloc->getRootSet().removeRoot(&root);
            }
        }
        // Move from other
        alloc = other.alloc;
        storage = std::move(other.storage);
        ptrs = std::move(other.ptrs);
        other.alloc = nullptr;
    }
    return *this;
}

GraphRoots setupRootsFromGraph(Allocator& alloc,
                                const HeapGraphDesc& graph,
                                const std::vector<void*>& allocated_objects) {
    GraphRoots result;
    result.alloc = &alloc;

    for (size_t idx : graph.root_indices) {
        if (idx < allocated_objects.size()) {
            result.storage.push_back(AllocatorTestAccess::toPointer(allocated_objects[idx]));
        }
    }

    // If no valid roots from graph, use first object as root
    if (result.storage.empty() && !allocated_objects.empty()) {
        result.storage.push_back(AllocatorTestAccess::toPointer(allocated_objects[0]));
    }

    for (auto& root : result.storage) {
        result.ptrs.push_back(&root);
        alloc.getRootSet().addRoot(&root);
    }

    return result;
}

// ============================================================================
// 9. Allocate Garbage Ints
// ============================================================================

void allocateGarbageInts(Allocator& alloc, size_t count) {
    for (size_t j = 0; j < count; j++) {
        void* garbage = alloc.allocate(sizeof(ElmInt), Tag_Int);
        if (garbage) {
            static_cast<ElmInt*>(garbage)->value = static_cast<i64>(j);
        }
    }
}

// ============================================================================
// 10. Build Linked List
// ============================================================================

LinkedList buildLinkedList(Allocator& alloc, size_t length) {
    LinkedList result;
    result.head = createNil();

    for (size_t i = 0; i < length; i++) {
        i64 val = *rc::gen::arbitrary<i64>();
        result.values.push_back(val);

        // Allocate Int
        void* int_obj = alloc.allocate(sizeof(ElmInt), Tag_Int);
        if (!int_obj) RC_FAIL("Failed to allocate int");
        static_cast<ElmInt*>(int_obj)->value = val;

        // Allocate Cons
        void* cons_obj = alloc.allocate(sizeof(Cons), Tag_Cons);
        if (!cons_obj) RC_FAIL("Failed to allocate cons");

        Cons* cons = static_cast<Cons*>(cons_obj);
        cons->head.p = AllocatorTestAccess::toPointer(int_obj);
        cons->tail = result.head;

        result.head = AllocatorTestAccess::toPointer(cons_obj);
    }

    // Reverse values so they match traversal order
    std::reverse(result.values.begin(), result.values.end());

    return result;
}

// ============================================================================
// 11. Verify Linked List
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
// 12. Assert Object is Int with Value
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
