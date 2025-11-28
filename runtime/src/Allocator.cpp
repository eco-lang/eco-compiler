/**
 * Allocator Implementation.
 *
 * This file implements the central allocator that manages:
 *   - Unified heap address space (reserved via mmap, committed on demand).
 *   - Thread-local heaps for each thread (nursery + old gen + stats).
 *   - Delegation to thread-local heaps for allocation and GC.
 *
 * Memory layout:
 *   [0 .. heap_reserved/2)      - Old generation region (carved up per-thread).
 *   [heap_reserved/2 .. end)    - Nursery region (carved up per-thread).
 */

#include "Allocator.hpp"
#include "AllocBuffer.hpp"
#include "ThreadLocalHeap.hpp"
#include <cassert>
#include <cstring>
#include <new>
#include <sys/mman.h>

namespace Elm {

// Global heap base for pointer conversion (used by fromPointerRaw/toPointerRaw).
char* g_heap_base = nullptr;

// Thread-local heap pointer for fast access.
thread_local ThreadLocalHeap* Allocator::tl_heap_ = nullptr;

Allocator::Allocator() :
    heap_base(nullptr), heap_reserved(0), old_gen_committed(0), nursery_offset(0),
    nursery_committed_(0), initialized(false) {
    // Initialization happens in initialize() method.
}

Allocator::~Allocator() {
    // Clean up all thread heaps.
    {
        std::lock_guard<std::recursive_mutex> lock(thread_mutex_);
        thread_heaps_.clear();
    }

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

    // Set global heap_base for pointer conversion.
    g_heap_base = heap_base;

    // Nursery region starts at halfway point.
    nursery_offset = heap_reserved / 2;

    initialized = true;
}

// Commits physical memory for a nursery region.
void Allocator::commitNursery(char *nursery_base, size_t size) {
    void *result = mmap(nursery_base, size, PROT_READ | PROT_WRITE,
                        MAP_PRIVATE | MAP_ANONYMOUS | MAP_FIXED, -1, 0);

    if (result == MAP_FAILED) {
        throw std::bad_alloc();
    }
}

// Returns the singleton Allocator instance.
Allocator &Allocator::instance() {
    static Allocator alloc;
    return alloc;
}

// Initializes the calling thread's heap space.
void Allocator::initThread() {
    // Ensure allocator is initialized.
    if (!initialized) {
        initialize();
    }

    // Check if this thread already has a heap.
    if (tl_heap_ != nullptr) {
        return;  // Already initialized.
    }

    std::lock_guard<std::recursive_mutex> lock(thread_mutex_);

    // Double-check after acquiring lock.
    auto thread_id = std::this_thread::get_id();
    if (thread_heaps_.find(thread_id) != thread_heaps_.end()) {
        tl_heap_ = thread_heaps_[thread_id].get();
        return;
    }

    // Create ThreadLocalHeap.
    // Memory is allocated on demand by NurserySpace (via acquireNurseryBlock)
    // and OldGenSpace (via acquireAllocBuffer).
    auto heap = std::make_unique<ThreadLocalHeap>(
        this,
        nullptr, 0,    // Nursery base/size - allocated on demand
        nullptr, 0, 0, // Old gen base/initial/max - allocated on demand
        &config_
    );

    tl_heap_ = heap.get();
    thread_heaps_[thread_id] = std::move(heap);
}

// Cleans up the calling thread's heap space.
void Allocator::cleanupThread() {
    if (tl_heap_ == nullptr) {
        return;  // Nothing to clean up.
    }

    std::lock_guard<std::recursive_mutex> lock(thread_mutex_);

    auto thread_id = std::this_thread::get_id();
    auto it = thread_heaps_.find(thread_id);
    if (it != thread_heaps_.end()) {
        thread_heaps_.erase(it);
    }

    tl_heap_ = nullptr;
}

RootSet &Allocator::getRootSet() {
    if (!tl_heap_) {
        // Auto-initialize for convenience.
        initThread();
    }
    return tl_heap_->getRootSet();
}

// Allocates a heap object of the given size with the specified tag.
void *Allocator::allocate(size_t size, Tag tag) {
    assert(tl_heap_ && "Thread not initialized - call initThread() first");
    return tl_heap_->allocate(size, tag);
}

// Triggers a minor GC on the thread-local nursery.
void Allocator::minorGC() {
    if (tl_heap_) {
        tl_heap_->minorGC();
    }
}

// Triggers a major GC on the thread-local old gen.
void Allocator::majorGC() {
    if (tl_heap_) {
        tl_heap_->majorGC();
    }
}

bool Allocator::isNurseryNearFull(float threshold) {
    if (tl_heap_) {
        return tl_heap_->isNurseryNearFull(threshold);
    }
    return false;
}

bool Allocator::isInNursery(void *ptr) {
    return tl_heap_ && tl_heap_->isInNursery(ptr);
}

bool Allocator::isInOldGen(void *ptr) {
    return tl_heap_ && tl_heap_->isInOldGen(ptr);
}

size_t Allocator::getOldGenAllocatedBytes() const {
    if (tl_heap_) {
        return tl_heap_->getOldGenAllocatedBytes();
    }
    return 0;
}

// ============================================================================
// Region Allocation (for NurserySpace growth)
// ============================================================================

char* Allocator::acquireNurseryBlock(size_t size) {
    // Called by NurserySpace during initialization or growth.
    // Thread-safe: acquires thread_mutex_ to update shared nursery_committed_ counter.
    std::lock_guard<std::recursive_mutex> lock(thread_mutex_);

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

AllocBuffer* Allocator::acquireAllocBuffer(size_t size) {
    std::lock_guard<std::recursive_mutex> lock(thread_mutex_);

    // Align size to 8 bytes.
    size = (size + 7) & ~7;

    // Check if we have space in old gen region.
    if (old_gen_committed + size > nursery_offset) {
        return nullptr;  // Out of old gen address space.
    }

    char* buffer_base = heap_base + old_gen_committed;

    // Commit physical memory for this buffer.
    void* result = mmap(buffer_base, size, PROT_READ | PROT_WRITE,
                        MAP_PRIVATE | MAP_ANONYMOUS | MAP_FIXED, -1, 0);

    if (result == MAP_FAILED) {
        return nullptr;
    }

    old_gen_committed += size;
    return new AllocBuffer(buffer_base, size);
}

char* Allocator::acquireOldGenRegion(size_t initial_size, size_t max_size) {
    // Note: Caller must hold thread_mutex_.
    // Align sizes to 8 bytes.
    initial_size = (initial_size + 7) & ~7;
    max_size = (max_size + 7) & ~7;

    // Check if we have space in old gen region.
    if (old_gen_committed + max_size > nursery_offset) {
        return nullptr;  // Out of old gen address space.
    }

    char* region_base = heap_base + old_gen_committed;

    // Commit initial physical memory.
    void* result = mmap(region_base, initial_size, PROT_READ | PROT_WRITE,
                        MAP_PRIVATE | MAP_ANONYMOUS | MAP_FIXED, -1, 0);

    if (result == MAP_FAILED) {
        return nullptr;
    }

    old_gen_committed += max_size;  // Reserve the full max size.
    return region_base;
}

void Allocator::reset(const HeapConfig* new_config) {
    std::lock_guard<std::recursive_mutex> lock(thread_mutex_);

    // Update config if provided.
    if (new_config) {
        new_config->validate();
        config_ = *new_config;
    }

    // Clear all thread heaps.
    thread_heaps_.clear();
    tl_heap_ = nullptr;

    // Reset committed memory tracking.
    old_gen_committed = 0;
    nursery_committed_ = 0;
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

    // Validate pointer is within the reserved heap address space.
    assert(static_cast<char*>(obj) >= heap_base && "Pointer below heap base");
    assert(static_cast<char*>(obj) < heap_base + heap_reserved && "Pointer above heap end");

    // Follow forwarding chain to final location.
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
    std::lock_guard<std::recursive_mutex> lock(thread_mutex_);

    GCStats combined;
    for (const auto& [thread_id, heap] : thread_heaps_) {
        // Combine both nursery stats and thread-local heap stats.
        combined.combine(heap->getNursery().getStats());
        combined.combine(heap->getStats());
    }
    return combined;
}
#endif

// ============================================================================
// Test Access Helper
// ============================================================================

NurserySpace* AllocatorTestAccess::getNursery(Allocator& alloc) {
    ThreadLocalHeap* heap = alloc.getThreadHeap();
    return heap ? &heap->getNursery() : nullptr;
}

OldGenSpace* AllocatorTestAccess::getOldGen(Allocator& alloc) {
    ThreadLocalHeap* heap = alloc.getThreadHeap();
    return heap ? &heap->getOldGen() : nullptr;
}

} // namespace Elm
