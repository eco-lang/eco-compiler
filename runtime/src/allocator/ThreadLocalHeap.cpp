/**
 * ThreadLocalHeap Implementation.
 *
 * Implements the per-thread heap containing nursery, old gen, and GC stats.
 * Each thread has its own independent GC with no synchronization required.
 */

#include "ThreadLocalHeap.hpp"
#include "Allocator.hpp"
#include "StackMap.hpp"
#include <cassert>
#include <cstring>

namespace Elm {

// Initializes a freshly-allocated object header for the given tag.
// `size` is the total aligned byte size returned by the allocator. For
// variable-size types, hdr->size is overwritten with the per-type element
// count; for fixed-size types it stores the byte size.
//
// The header is zeroed first; callers may set additional fields (e.g. pin,
// color) after this returns.
static void initHeaderForTag(Header* hdr, Tag tag, size_t size) {
    std::memset(hdr, 0, sizeof(Header));
    hdr->tag = tag;

    switch (tag) {
        case Tag_String:
            hdr->size = (size - sizeof(ElmString)) / sizeof(u16);
            break;
        case Tag_Custom:
            hdr->size = (size - sizeof(Custom)) / sizeof(Unboxable);
            break;
        case Tag_Record:
            hdr->size = (size - sizeof(Record)) / sizeof(Unboxable);
            break;
        case Tag_DynRecord:
            hdr->size = (size - sizeof(DynRecord)) / sizeof(HPointer);
            break;
        case Tag_FieldGroup:
            hdr->size = (size - sizeof(FieldGroup)) / sizeof(u32);
            break;
        case Tag_Closure:
            hdr->size = (size - sizeof(Closure)) / sizeof(Unboxable);
            break;
        default:
            hdr->size = static_cast<u32>(size);
            break;
    }
}

ThreadLocalHeap::ThreadLocalHeap(Allocator* parent,
                                 char* nursery_base, size_t nursery_size,
                                 char* old_gen_base, size_t old_gen_initial_size,
                                 size_t old_gen_max_size,
                                 const HeapConfig* config)
    : parent_(parent)
    , config_(config)
    , nursery_()
    , old_gen_()
{
    assert(parent && "Parent allocator must not be null");
    assert(config && "Config must not be null");
    // Note: nursery_base and old_gen_base may be null if memory is allocated
    // on demand via acquireNurseryBlock/acquireAllocBuffer.

    // Initialize old gen with reference to parent Allocator (for buffer acquisition).
    old_gen_.initialize(parent_, config_);

    // Initialize nursery with reference to this heap for promotion.
    nursery_.initialize(this, config_);
}

void* ThreadLocalHeap::allocate(size_t size, Tag tag) {
    // Align to 8 bytes up front so the threshold comparison is meaningful
    // (matches the alignment performed inside nursery/oldgen allocators).
    size = (size + 7) & ~static_cast<size_t>(7);

    // Large-object path: bypass the nursery and allocate directly in old
    // gen, marking the object pinned so the compactor will not move it.
    if (size >= config_->large_object_threshold) {
        return allocateLargePinned(size, tag);
    }

    // Check if allocation would exceed threshold - trigger GC proactively.
    if (nursery_.wouldExceedThreshold(size, config_->nursery_gc_threshold)) {
        minorGC();
    }

    void* obj = nursery_.allocate(size);
    if (obj) {
        initHeaderForTag(getHeader(obj), tag, size);
        return obj;
    }

    // Nursery allocation failed - currently treated as fatal error.
    // Cannot fall back to old gen allocation: would create old-to-young pointers
    // when the object's fields are filled in, violating generational GC invariants.
    assert(false && "Failed to allocate to nursery, it is full.");
    return nullptr;
}

void* ThreadLocalHeap::allocateLargePinned(size_t size, Tag tag) {
    // size is already 8-byte aligned by the caller.
    void* obj = old_gen_.allocate(size);
    if (!obj) {
        // Try once after a major GC to reclaim space.
        majorGC();
        obj = old_gen_.allocate(size);
    }
    if (!obj) {
        assert(false && "Failed to allocate large pinned object in old gen.");
        return nullptr;
    }

    Header* hdr = getHeader(obj);
    // OldGenSpace::allocate already memset/colored the header. Re-init for
    // tag (this preserves the zero color and overwrites tag/size fields),
    // then set pin LAST so it survives any prior writes. Color was set by
    // OldGenSpace::allocate based on GC phase; preserve it.
    u32 saved_color = hdr->color;
    u32 saved_epoch = hdr->epoch;
    initHeaderForTag(hdr, tag, size);
    hdr->color = saved_color;
    hdr->epoch = saved_epoch;
    hdr->pin = 1;
    return obj;
}

void* ThreadLocalHeap::allocatePermanent(size_t size, Tag tag) {
    // Allocate directly in old generation - for permanent objects like string literals.
    size = (size + 7) & ~static_cast<size_t>(7);
    void* obj = old_gen_.allocate(size);
    if (obj) {
        Header* hdr = getHeader(obj);
        u32 saved_color = hdr->color;
        u32 saved_epoch = hdr->epoch;
        initHeaderForTag(hdr, tag, size);
        hdr->color = saved_color;
        hdr->epoch = saved_epoch;
        return obj;
    }

    assert(false && "Failed to allocate in old gen.");
    return nullptr;
}

void ThreadLocalHeap::minorGC() {
    collectStackRootsFromStackMap();
    nursery_.minorGC(old_gen_);
}

void ThreadLocalHeap::majorGC() {
#if ENABLE_GC_STATS
    auto gc_start = GC_STATS_TIMER_START();
#endif

    collectStackRootsFromStackMap();

    // Collect all roots from this thread.
    std::unordered_set<HPointer*> roots = collectRoots();
    const std::unordered_set<uint64_t*>& jit_roots = nursery_.getRootSet().getJitRoots();

    // Start marking phase.
#if ENABLE_GC_STATS
    old_gen_.startMark(roots, jit_roots, *parent_, stats_);
#else
    old_gen_.startMark(roots, jit_roots, *parent_);
#endif

    // Continue with marking and sweep.
#if ENABLE_GC_STATS
    old_gen_.finishMarkAndSweep(stats_);
#else
    old_gen_.finishMarkAndSweep();
#endif

#if ENABLE_GC_STATS
    uint64_t elapsed_ns = GC_STATS_TIMER_ELAPSED_NS(gc_start);
    GC_STATS_MAJOR_RECORD_GC_END(stats_, elapsed_ns);
#endif
}

bool ThreadLocalHeap::isNurseryNearFull(float threshold) const {
    size_t total_capacity = config_->nurserySize() / 2;
    size_t usage = nursery_.bytesAllocated();
    return usage >= static_cast<size_t>(total_capacity * threshold);
}

std::unordered_set<HPointer*> ThreadLocalHeap::collectRoots() {
    // Start with the long-lived roots (already an unordered_set).
    std::unordered_set<HPointer*> all_roots = nursery_.getRootSet().getRoots();

    // Add stack roots.
    const auto& stack_roots = nursery_.getRootSet().getStackRoots();
    all_roots.insert(stack_roots.begin(), stack_roots.end());

    return all_roots;
}

void ThreadLocalHeap::collectStackRootsFromStackMap() {
    auto& stackMap = globalStackMap();
    if (!stackMap.hasRecords())
        return;

    RootSet& roots = nursery_.getRootSet();
    // Clear previous stack roots from stack map walking
    roots.restoreStackRootPoint(0);

    // Walk the call stack using frame pointer chaining (x86-64).
    // Each frame: [saved_rbp | return_address | ... locals ...]
    //             ^rbp points here
    //
    // DWARF register 6 = RBP, register 7 = RSP on x86-64.

#if defined(__x86_64__) || defined(_M_X64)
    // Get current frame pointer
    void* rbp;
    __asm__ volatile ("mov %%rbp, %0" : "=r"(rbp));

    // Walk up the stack frames
    for (int depth = 0; depth < 256 && rbp != nullptr; depth++) {
        // Return address is at rbp + 8
        uint64_t* rbpPtr = reinterpret_cast<uint64_t*>(rbp);
        uint64_t returnAddr = rbpPtr[1];

        // Look up this return address in the stack map
        const StackMapRecord* record = stackMap.findRecord(returnAddr);
        if (record) {
            // For each location in this record, extract the GC root
            for (const auto& loc : record->locations) {
                if (loc.kind == StackMapLocation::Indirect) {
                    // Indirect: value at *(register + offset)
                    // DWARF reg 6 = RBP on x86-64
                    if (loc.dwarfRegNum == 6) {
                        auto* slotAddr = reinterpret_cast<HPointer*>(
                            reinterpret_cast<char*>(rbp) + loc.offset);
                        roots.pushStackRoot(slotAddr);
                    }
                    // DWARF reg 7 = RSP — less common but possible
                    // For now we only handle RBP-relative locations
                }
                // Other location kinds (Register, Direct, Constant, ConstantIndex)
                // are not expected for stack-spilled GC roots with gc.relocate.
#if ECO_DEBUG_STACKMAP
                if (loc.kind != StackMapLocation::Indirect) {
                    fprintf(stderr, "[eco-gc] WARNING: unsupported stackmap location kind=%u "
                        "reg=%u offset=%d at returnAddress=%p\n",
                        (unsigned)loc.kind, loc.dwarfRegNum, loc.offset,
                        (void*)returnAddress);
                }
#endif
            }
        }

        // Follow the frame pointer chain
        void* nextRbp = reinterpret_cast<void*>(rbpPtr[0]);

        // Sanity check: frame pointer should move up the stack
        if (nextRbp <= rbp)
            break;

        rbp = nextRbp;
    }
#endif
    // On non-x86-64 platforms, stack root collection from stack maps
    // is not yet implemented. The GC still works via explicit roots
    // (globals, platform state).
}

} // namespace Elm
