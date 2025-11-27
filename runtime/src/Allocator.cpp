/**
 * Allocator Implementation.
 *
 * This file implements the central allocator that manages:
 *   - Unified heap address space (reserved via mmap, committed on demand).
 *   - Single nursery for fast allocation.
 *   - Old generation for long-lived objects.
 *   - Minor GC (copying collection in nursery).
 *   - Major GC (mark-sweep in old gen).
 *
 * Memory layout:
 *   [0 .. heap_reserved/2)      - Old generation (AllocBuffers allocated here).
 *   [heap_reserved/2 .. end)    - Nursery.
 */

#include "Allocator.hpp"
#include "AllocBuffer.hpp"
#include <cassert>
#include <cstring>
#include <new>
#include <sys/mman.h>

namespace Elm {

// Global heap base for read barrier (used by fromPointer/toPointer).
char* g_heap_base = nullptr;

Allocator::Allocator() :
    heap_base(nullptr), heap_reserved(0), old_gen_committed(0), nursery_offset(0),
    nursery_committed_(0), initialized(false) {
    // Initialization happens in initialize() method.
}

Allocator::~Allocator() {
    if (heap_base) {
        munmap(heap_base, heap_reserved);
    }
}

// Initializes the allocator with the given configuration.
// Validates config and reserves address space. Physical memory committed lazily.
void Allocator::initialize(const HeapConfig& config) {
    if (initialized) {
        return;
    }

    // Validate configuration before proceeding.
    config.validate();
    config_ = config;

    heap_reserved = config_.max_heap_size;

    // Reserve address space without committing physical memory.
    // PROT_NONE means no access until we commit regions with mmap(MAP_FIXED).
    heap_base = static_cast<char *>(mmap(nullptr, heap_reserved,
                                         PROT_NONE,
                                         MAP_PRIVATE | MAP_ANONYMOUS | MAP_NORESERVE, -1, 0));

    if (heap_base == MAP_FAILED) {
        throw std::bad_alloc();
    }

    // Set global heap_base for read barrier.
    g_heap_base = heap_base;

    // Nursery starts at halfway point.
    nursery_offset = heap_reserved / 2;

    // Initialize old gen with reference back to this allocator.
    old_gen.initialize(this, &config_);

    initialized = true;
}

// Commits physical memory for the nursery.
void Allocator::commitNursery(char *nursery_base, size_t size) {
    void *result = mmap(nursery_base, size, PROT_READ | PROT_WRITE, MAP_PRIVATE | MAP_ANONYMOUS | MAP_FIXED, -1, 0);

    if (result == MAP_FAILED) {
        throw std::bad_alloc();
    }
}

// Returns the singleton Allocator instance.
Allocator &Allocator::instance() {
    static Allocator alloc;
    return alloc;
}

// Initializes allocator state, creating the nursery.
// Must be called before allocation.
void Allocator::initThread() {
    // Ensure allocator is initialized.
    if (!initialized) {
        initialize();
    }

    if (!nursery) {
        // Reset nursery committed tracking.
        nursery_committed_ = 0;

        nursery = std::make_unique<NurserySpace>();
        nursery->initialize(this, &config_);
    }
}

NurserySpace *Allocator::getNursery() {
    return nursery.get();
}

RootSet &Allocator::getRootSet() {
    if (!nursery) {
        // Auto-initialize for convenience.
        initThread();
    }
    return nursery->getRootSet();
}

std::vector<HPointer*> Allocator::collectAllRoots() {
    std::vector<HPointer*> all_roots;
    if (nursery) {
        // Collect long-lived roots.
        const auto& roots = nursery->getRootSet().getRoots();
        all_roots.insert(all_roots.end(), roots.begin(), roots.end());
        // Collect stack roots.
        const auto& stack_roots = nursery->getRootSet().getStackRoots();
        all_roots.insert(all_roots.end(), stack_roots.begin(), stack_roots.end());
    }
    return all_roots;
}

// Allocates a heap object of the given size with the specified tag.
// Tries nursery first (fast path).
// May trigger minor GC if nursery usage exceeds threshold.
void *Allocator::allocate(size_t size, Tag tag) {
    if (nursery) {
        // Check if allocation would exceed threshold - trigger GC proactively.
        if (nursery->wouldExceedThreshold(size, config_.nursery_gc_threshold)) {
            minorGC();
        }

        void *obj = nursery->allocate(size);
        if (obj) {
            Header *hdr = getHeader(obj);
            std::memset(hdr, 0, sizeof(Header));
            hdr->tag = tag;
            // For variable-sized types, hdr->size stores element count.
            // For fixed-size types, hdr->size stores total byte size.
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
                    hdr->size = size;
                    break;
            }
            return obj;
        }
    }

    // Nursery allocation failed - currently treated as fatal error.
    // Cannot fall back to old gen allocation: would create old-to-young pointers
    // when the object's fields are filled in, violating generational GC invariants.
    // Solution: Configure larger nursery_size or trigger GC more aggressively.
    assert(false && "Failed to allocate to nursery, it is full.");
    return nullptr;
}

// Triggers a minor GC on the nursery.
// Uses Cheney's copying algorithm to evacuate live objects to to-space
// or promote them to old gen if they've survived enough collections.
void Allocator::minorGC() {
    if (nursery) {
        nursery->minorGC(old_gen);
    }
}

// Triggers a major GC cycle: mark-sweep on old generation.
void Allocator::majorGC() {
#if ENABLE_GC_STATS
    auto gc_start = GC_STATS_TIMER_START();
#endif

    // Collect all roots.
    std::vector<HPointer*> all_roots = collectAllRoots();

    // Start marking phase - traces through ALL objects including nursery.
#if ENABLE_GC_STATS
    old_gen.startMark(all_roots, *this, major_gc_stats);
#else
    old_gen.startMark(all_roots, *this);
#endif

    // Continue with marking and sweep.
#if ENABLE_GC_STATS
    old_gen.finishMarkAndSweep(major_gc_stats);
#else
    old_gen.finishMarkAndSweep();
#endif

#if ENABLE_GC_STATS
    uint64_t elapsed_ns = GC_STATS_TIMER_ELAPSED_NS(gc_start);
    GC_STATS_MAJOR_RECORD_GC_END(major_gc_stats, elapsed_ns);
#endif
}

bool Allocator::isInNursery(void *ptr) {
    return nursery && nursery->contains(ptr);
}

bool Allocator::isInOldGen(void *ptr) {
    char* p = static_cast<char*>(ptr);
    return p >= heap_base && p < heap_base + nursery_offset;
}

// ============================================================================
// AllocBuffer Management
// ============================================================================

AllocBuffer* Allocator::acquireAllocBuffer(size_t size) {
    // Align size to 8 bytes.
    size = (size + 7) & ~7;

    // Check if we have space in old gen region.
    if (old_gen_committed + size > nursery_offset) {
        return nullptr;  // Out of old gen address space.
    }

    // Commit physical memory for this buffer.
    char* buffer_base = heap_base + old_gen_committed;
    void* result = mmap(buffer_base, size, PROT_READ | PROT_WRITE,
                        MAP_PRIVATE | MAP_ANONYMOUS | MAP_FIXED, -1, 0);

    if (result == MAP_FAILED) {
        return nullptr;
    }

    old_gen_committed += size;

    // Create and return the AllocBuffer.
    return new AllocBuffer(buffer_base, size);
}

char* Allocator::acquireNurseryBlock(size_t size) {
    // Align size to 8 bytes.
    size = (size + 7) & ~7;

    // Nursery region is [nursery_offset .. heap_reserved).
    size_t nursery_space = heap_reserved - nursery_offset;

    // Check if we have space in nursery region.
    if (nursery_committed_ + size > nursery_space) {
        return nullptr;  // Out of nursery address space.
    }

    // Commit physical memory for this block.
    char* block_base = heap_base + nursery_offset + nursery_committed_;
    void* result = mmap(block_base, size, PROT_READ | PROT_WRITE,
                        MAP_PRIVATE | MAP_ANONYMOUS | MAP_FIXED, -1, 0);

    if (result == MAP_FAILED) {
        return nullptr;
    }

    nursery_committed_ += size;
    return block_base;
}

void Allocator::reset(const HeapConfig* new_config) {
    // Update config if provided.
    if (new_config) {
        new_config->validate();
        config_ = *new_config;
    }

    // Reset nursery (resets its own root set).
    // Pass config pointer so nursery can reconfigure.
    if (nursery) {
        nursery->reset(old_gen, new_config ? &config_ : nullptr);
    }

    // Reset old gen.
    // Pass config pointer so old gen can reconfigure.
    old_gen.reset(new_config ? &config_ : nullptr);

    // Reset committed memory tracking for old gen and nursery.
    // Note: We keep the address space reserved but will recommit as needed.
    old_gen_committed = 0;
    nursery_committed_ = 0;

    // Note: We do NOT reset GC stats here - stats accumulate across runs.
}

// ============================================================================
// Safe Public Pointer API
// ============================================================================

void* Allocator::resolve(HPointer ptr) {
    if (ptr.constant != 0) {
        return nullptr;  // Embedded constant (Nil, True, False, Unit)
    }

    void* obj = fromPointerRaw(ptr);
    assert(obj && "Null pointer from valid HPointer");

    // Validate pointer is within allocated heap address space.
    assert(static_cast<char*>(obj) >= heap_base && "Pointer below heap base");
    assert(static_cast<char*>(obj) < heap_base + heap_reserved && "Pointer above heap end");

    // Follow forwarding chain to final location
    Header* hdr = getHeader(obj);
    while (hdr->tag == Tag_Forward) {
        Forward* fwd = static_cast<Forward*>(obj);
        uintptr_t byte_offset = static_cast<uintptr_t>(fwd->header.forward_ptr) << 3;
        obj = heap_base + byte_offset;
        hdr = getHeader(obj);
    }

    assert(hdr->tag < Tag_Forward && "Invalid tag after forward resolution");
    return obj;
}

HPointer Allocator::wrap(void* obj) {
    return toPointerRaw(obj);
}

#if ENABLE_GC_STATS
GCStats Allocator::getCombinedStats() const {
    GCStats combined;
    if (nursery) {
        combined.combine(nursery->getStats());
    }
    combined.combine(major_gc_stats);
    return combined;
}
#endif

} // namespace Elm
