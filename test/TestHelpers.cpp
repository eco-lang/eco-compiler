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
    AllocatorTestAccess::reset(alloc, &config);
    return alloc;
}

HeapConfig scaledHeapConfig(int rc_size) {
    HeapConfig config;

    // Nursery is now defined in terms of block count.
    // At size 0-100: minimum 2 blocks (1 per semi-space) = 256KB total.
    // At size 1000: 10 blocks = 1.25MB total.
    // At size 5000: 50 blocks = 6.25MB total.
    //
    // The scaling is: base + (size / 100) blocks
    // This ensures we have enough space for the objects generated at that size.

    constexpr size_t MIN_BLOCKS = 2;               // Minimum 2 blocks (1 per semi-space)
    constexpr size_t MAX_BLOCKS = 512;             // Maximum 512 blocks = 64MB

    size_t scaled_blocks = MIN_BLOCKS + (static_cast<size_t>(rc_size) / 100);
    config.nursery_block_count = std::min(scaled_blocks, MAX_BLOCKS);

    // Ensure block count is even (split into from-space and to-space).
    config.nursery_block_count = (config.nursery_block_count / 2) * 2;
    if (config.nursery_block_count < MIN_BLOCKS) {
        config.nursery_block_count = MIN_BLOCKS;
    }

    // Scale old gen initial size similarly (less aggressively since old gen grows on demand).
    constexpr size_t MIN_OLD_GEN = 1 * 1024 * 1024;   // 1MB minimum
    constexpr size_t OLD_GEN_SCALE = 512 * 1024;      // 512KB per 100 size units
    constexpr size_t MAX_OLD_GEN = 64 * 1024 * 1024;  // 64MB maximum

    size_t scaled_old_gen = MIN_OLD_GEN + (static_cast<size_t>(rc_size) / 100) * OLD_GEN_SCALE;
    config.initial_old_gen_size = std::min(scaled_old_gen, MAX_OLD_GEN);

    return config;
}

Allocator& initAllocatorScaled(int rc_size) {
    return initAllocator(scaledHeapConfig(rc_size));
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
    auto& oldgen = AllocatorTestAccess::getOldGen(alloc);
    auto& rootset = alloc.getRootSet();

#if ENABLE_GC_STATS
    GCStats& stats = alloc.getMajorGCStats();
    OldGenSpaceTestAccess::startMark(oldgen, rootset.getRoots(), Allocator::instance(), stats);
    OldGenSpaceTestAccess::finishMarkAndSweep(oldgen, stats);
#else
    OldGenSpaceTestAccess::startMark(oldgen, rootset.getRoots(), Allocator::instance());
    OldGenSpaceTestAccess::finishMarkAndSweep(oldgen);
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
