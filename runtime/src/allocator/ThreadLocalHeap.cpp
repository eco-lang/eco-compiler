/**
 * ThreadLocalHeap Implementation.
 *
 * Implements the per-thread heap containing nursery, old gen, and GC stats.
 * Each thread has its own independent GC with no synchronization required.
 */

#include "ThreadLocalHeap.hpp"
#include "Allocator.hpp"
#include "StackMap.hpp"
#include "StackUnwind.hpp"
#include <cassert>
#include <cstring>
#include <execinfo.h>
#include <execinfo.h>

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

void* ThreadLocalHeap::allocateFast(size_t size) {
    // Pure bump-pointer: no GC, no threshold check, no header init.
    // Returns nullptr when nursery has insufficient space.
    size = (size + 7) & ~static_cast<size_t>(7);
    return nursery_.allocate(size);
}

void* ThreadLocalHeap::allocateSlow(size_t size, Tag tag) {
    // Slow path: GC then allocate. Called after allocateFast returns nullptr.
    size = (size + 7) & ~static_cast<size_t>(7);

    if (size >= config_->large_object_threshold) {
        return allocateLargePinned(size, tag);
    }

    minorGC();

    void* obj = nursery_.allocate(size);
    if (obj) {
        initHeaderForTag(getHeader(obj), tag, size);
        return obj;
    }

    assert(false && "Failed to allocate after GC in slow path.");
    return nullptr;
}

void* ThreadLocalHeap::allocateRegionSlow(size_t total) {
    // Slow path for contiguous region allocation. May GC.
    // Caller handles header init for each sub-object.
    total = (total + 7) & ~static_cast<size_t>(7);

    if (total >= config_->large_object_threshold) {
        // Large regions go to old gen directly.
        void* obj = old_gen_.allocate(total);
        if (!obj) {
            assert(false && "Failed to allocate large region in old gen.");
            return nullptr;
        }
        return obj;
    }

    if (total >= config_->large_object_threshold) {
        // Large regions go to old gen directly.
        void* obj = old_gen_.allocate(total);
        if (!obj) {
            majorGC();
            obj = old_gen_.allocate(total);
        }
        if (!obj) {
            assert(false && "Failed to allocate large region in old gen.");
            return nullptr;
        }
        return obj;
    }

    minorGC();

    void* obj = nursery_.allocate(total);
    if (obj) return obj;

    assert(false && "Failed to allocate region after GC.");
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

bool ThreadLocalHeap::shouldCollectAtSafepoint() const {
    if (force_gc_)
        return true;
    return isNurseryNearFull(config_->nursery_gc_threshold);
}

void ThreadLocalHeap::collectAtSafepoint() {
    force_gc_ = false;
    minorGC();
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

    // Stack root ranges (alloca-backed args arrays).
    for (const auto &range : nursery_.getRootSet().getStackRootRanges()) {
        HPointer *base = range.base;
        uint64_t mask  = range.hpointer_mask;
        for (size_t i = 0; i < range.count; ++i) {
            if (mask & (1ULL << i)) {
                all_roots.insert(&base[i]);
            }
        }
    }

    return all_roots;
}

void ThreadLocalHeap::collectStackRootsFromStackMap() {
#if ECO_GC_DEBUG
    {
        void *bt[64];
        int n = backtrace(bt, 64);
        fprintf(stderr, "[gc-backtrace] %d frames\n", n);
    }
#endif
    StackMap& sm = globalStackMap();
    if (!sm.hasRecords()) {
#if ECO_GC_DEBUG
        static bool warned = false;
        if (!warned) {
            fprintf(stderr, "[gc-stackmap] WARNING: no stack map records found! Stack roots will NOT be tracked.\n");
            warned = true;
        }
#endif
        return;
    }

    RootSet& roots = nursery_.getRootSet();
    // Clear previous stack roots from stack map walking
    roots.restoreStackRootPoint(0);

    // Walk the call stack using libunwind.
    // For each frame, look up the IP in the stack map and process
    // Indirect locations (GC roots spilled to the stack).
    //
    // The unwinder's IP for a non-top frame is the return address,
    // which matches the key used by StackMap::findRecord().
    // Bias is 0 on x86-64 Linux (verified empirically).
    static constexpr int kIpToReturnAddressBias = 0;

    using namespace StackUnwind;
    Context ctx;
    Cursor cur(ctx);

    do {
        uintptr_t ip = cur.ip();
        const StackMapRecord* rec = sm.findRecord(ip + kIpToReturnAddressBias);
        if (!rec) {
            continue;
        }

        for (size_t locIdx = 0; locIdx < rec->locations.size(); ++locIdx) {
            const StackMapLocation& loc = rec->locations[locIdx];
#if ECO_GC_DEBUG
            if (loc.kind != StackMapLocation::Indirect) {
                fprintf(stderr, "[gc-stackmap]   loc[%zu] kind=%u reg=%u off=%d size=%u (NOT Indirect — SKIPPED)\n",
                        locIdx, (unsigned)loc.kind, (unsigned)loc.dwarfRegNum,
                        (int)loc.offset, (unsigned)loc.sizeInBytes);
            }
#endif
            if (loc.kind == StackMapLocation::Indirect) {
                uintptr_t base = 0;
                if (!cur.getRegister(loc.dwarfRegNum, base)) {
                    continue;
                }
                uintptr_t addr = base + static_cast<int32_t>(loc.offset);
                auto* slot = reinterpret_cast<HPointer*>(addr);

                Allocator& alloc = Allocator::instance();
                HPointer potential = *slot;
                // Embedded-constant HPointers (Unit/True/False/Nil/etc.) are not
                // heap-allocated and do not need GC. Skip them before calling
                // resolve(), which asserts constant == 0.
                if (potential.constant != 0) {
                    continue;
                }
                void* phys = alloc.resolve(potential);
                if (phys != nullptr && alloc.isInHeap(phys)) {
                    roots.pushStackRoot(slot);
                }
            }
        }
    } while (cur.step());

#if ECO_GC_DEBUG
    fprintf(stderr, "[gc-stackmap-summary] stack roots pushed: %zu\n",
            roots.getStackRoots().size());
#endif
}

} // namespace Elm
