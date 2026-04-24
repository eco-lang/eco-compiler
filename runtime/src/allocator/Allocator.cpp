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
#include "ThreadLocalHeap.hpp"
#include <cassert>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <new>
#include <sys/mman.h>

namespace Elm {

// Global heap base for pointer conversion (used by fromPointerRaw/toPointerRaw).
char* g_heap_base = nullptr;

namespace {

// Coarse milestone interval for heap-growth traces. Emitting one line per
// block acquire is prohibitively spammy (a 4 GB old-gen fill is ~32k blocks
// at 128 KB each); logging only when the committed counter crosses a
// multiple of this granularity gives a readable growth history.
constexpr size_t HEAP_TRACE_OLDGEN_INTERVAL   = 32 * 1024 * 1024;  // 32 MB.
constexpr size_t HEAP_TRACE_NURSERY_INTERVAL  = 16 * 1024 * 1024;  // 16 MB.

}  // namespace

bool Allocator::heapTraceEnabled() {
    static const bool enabled = []{
        const char* e = std::getenv("ECO_HEAP_TRACE");
        if (e == nullptr || e[0] == '\0') return false;
        // Treat "0" (single-char) as disabled, everything else as enabled.
        return !(e[0] == '0' && e[1] == '\0');
    }();
    return enabled;
}

void Allocator::dumpHeapState(const char* label, size_t pending_size) const {
    std::fprintf(stderr,
        "[heap-trace] %s oldgen_committed=%.2f MB nursery_low=%.2f MB "
        "nursery_high=%.2f MB (oldgen_cap=%.2f GB, heap_reserved=%.2f GB)",
        label,
        old_gen_committed / (1024.0 * 1024.0),
        nursery_low_committed_ / (1024.0 * 1024.0),
        nursery_high_committed_ / (1024.0 * 1024.0),
        nursery_offset / (1024.0 * 1024.0 * 1024.0),
        heap_reserved / (1024.0 * 1024.0 * 1024.0));

    if (pending_size != 0) {
        std::fprintf(stderr, " pending_size=%zu B (%.2f KB)",
                     pending_size, pending_size / 1024.0);
    }

    // Thread-local detail for the calling thread (other thread heaps exist
    // but walking them requires the mutex; the caller may already hold it,
    // so we stick to the cheap current-thread view).
    if (tl_heap_) {
        std::fprintf(stderr,
                     " tl.oldgen_allocated=%.2f MB",
                     tl_heap_->getOldGenAllocatedBytes() / (1024.0 * 1024.0));
    }
    std::fputc('\n', stderr);
}

// Thread-local heap pointer for fast access.
thread_local ThreadLocalHeap* Allocator::tl_heap_ = nullptr;

Allocator::Allocator() :
    heap_base(nullptr), heap_reserved(0), old_gen_committed(0), nursery_offset(0),
    nursery_low_committed_(0), nursery_high_committed_(0), initialized(false) {
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
#if ENABLE_GC_STATS
        // Accumulate stats from this thread heap before destroying it.
        accumulated_stats_.combine(it->second->getNursery().getStats());
        accumulated_stats_.combine(it->second->getStats());
#endif
        thread_heaps_.erase(it);
    }

    tl_heap_ = nullptr;
}

// Returns the thread-local root set, auto-initializing the thread if needed.
RootSet &Allocator::getRootSet() {
    if (!tl_heap_) {
        initThread();
    }
    return tl_heap_->getRootSet();
}

// Allocates a heap object of the given size with the specified tag.
void *Allocator::allocate(size_t size, Tag tag) {
    assert(tl_heap_ && "Thread not initialized - call initThread() first");
    return tl_heap_->allocate(size, tag);
}

// Fast-path: bump-pointer only, no GC.
void *Allocator::allocateFast(size_t size) {
    assert(tl_heap_ && "Thread not initialized - call initThread() first");
    return tl_heap_->allocateFast(size);
}

// Slow-path: may GC, always succeeds or aborts.
void *Allocator::allocateSlow(size_t size, Tag tag) {
    assert(tl_heap_ && "Thread not initialized - call initThread() first");
    return tl_heap_->allocateSlow(size, tag);
}

// Slow-path region: contiguous allocation, may GC.
void *Allocator::allocateRegionSlow(size_t total) {
    assert(tl_heap_ && "Thread not initialized - call initThread() first");
    return tl_heap_->allocateRegionSlow(total);
}

// Allocates directly in old generation (bypasses nursery).
void *Allocator::allocatePermanent(size_t size, Tag tag) {
    assert(tl_heap_ && "Thread not initialized - call initThread() first");
    return tl_heap_->allocatePermanent(size, tag);
}

// Triggers a minor GC on the thread-local nursery.
void Allocator::minorGC() {
    assert(tl_heap_ && "Thread not initialized - call initThread() first");
    tl_heap_->minorGC();
}

// Triggers a major GC on the thread-local old gen.
void Allocator::majorGC() {
    assert(tl_heap_ && "Thread not initialized - call initThread() first");
    tl_heap_->majorGC();
}

bool Allocator::shouldCollectAtSafepoint() {
    return tl_heap_ && tl_heap_->shouldCollectAtSafepoint();
}

void Allocator::collectAtSafepoint() {
    assert(tl_heap_ && "Thread not initialized - call initThread() first");
    tl_heap_->collectAtSafepoint();
}

// Returns true if the thread-local nursery usage exceeds the threshold.
bool Allocator::isNurseryNearFull(float threshold) {
    if (tl_heap_) {
        return tl_heap_->isNurseryNearFull(threshold);
    }
    return false;
}

// Returns true if the pointer is in the calling thread's nursery.
bool Allocator::isInNursery(void *ptr) {
    return tl_heap_ && tl_heap_->isInNursery(ptr);
}

// Returns true if the pointer is in the calling thread's old gen.
bool Allocator::isInOldGen(void *ptr) {
    return tl_heap_ && tl_heap_->isInOldGen(ptr);
}

// Returns the current allocated bytes in thread-local old gen.
size_t Allocator::getOldGenAllocatedBytes() const {
    if (tl_heap_) {
        return tl_heap_->getOldGenAllocatedBytes();
    }
    return 0;
}

// ============================================================================
// Region Allocation (for NurserySpace growth)
// ============================================================================

// Acquires a block from the low nursery region.
// Thread-safe: acquires thread_mutex_ to update shared committed counters.
char* Allocator::acquireNurseryBlockLow(size_t size) {
    std::lock_guard<std::recursive_mutex> lock(thread_mutex_);

    // Align size to 8 bytes.
    size = (size + 7) & ~7;

    // Reuse a previously-released block of the same size before growing.
    for (auto it = nursery_low_freelist_.begin();
         it != nursery_low_freelist_.end(); ++it) {
        if (it->second == size) {
            char* block = it->first;
            nursery_low_freelist_.erase(it);
            return block;
        }
    }

    // Nursery is split into two halves: low and high.
    // Low region: [nursery_offset .. nursery_offset + nursery_space/2)
    size_t nursery_space = heap_reserved - nursery_offset;
    size_t low_region_size = nursery_space / 2;

    // Check if we have space in low region.
    if (nursery_low_committed_ + size > low_region_size) {
        if (heapTraceEnabled()) {
            dumpHeapState("acquireNurseryBlockLow OUT OF SPACE", size);
        }
        return nullptr;  // Out of low region address space.
    }

    // Commit physical memory for this block.
    char* block_base = heap_base + nursery_offset + nursery_low_committed_;
    void* result = mmap(block_base, size, PROT_READ | PROT_WRITE,
                        MAP_PRIVATE | MAP_ANONYMOUS | MAP_FIXED, -1, 0);

    if (result == MAP_FAILED) {
        return nullptr;
    }

    size_t before = nursery_low_committed_;
    nursery_low_committed_ += size;

    // Log every time the low-region commit counter crosses a milestone so
    // the trace captures monotonic nursery growth without line-per-block noise.
    if (heapTraceEnabled() &&
        before / HEAP_TRACE_NURSERY_INTERVAL !=
            nursery_low_committed_ / HEAP_TRACE_NURSERY_INTERVAL) {
        dumpHeapState("nursery-low grew", size);
    }

    return block_base;
}

void Allocator::releaseNurseryBlockLow(char* block, size_t size) {
    std::lock_guard<std::recursive_mutex> lock(thread_mutex_);
    size = (size + 7) & ~7;
    nursery_low_freelist_.emplace_back(block, size);
}

// Acquires a block from the high nursery region.
// Thread-safe: acquires thread_mutex_ to update shared committed counters.
char* Allocator::acquireNurseryBlockHigh(size_t size) {
    std::lock_guard<std::recursive_mutex> lock(thread_mutex_);

    // Align size to 8 bytes.
    size = (size + 7) & ~7;

    // Reuse a previously-released block of the same size before growing.
    for (auto it = nursery_high_freelist_.begin();
         it != nursery_high_freelist_.end(); ++it) {
        if (it->second == size) {
            char* block = it->first;
            nursery_high_freelist_.erase(it);
            return block;
        }
    }

    // Nursery is split into two halves: low and high.
    // High region: [nursery_offset + nursery_space/2 .. heap_reserved)
    size_t nursery_space = heap_reserved - nursery_offset;
    size_t high_region_start = nursery_space / 2;
    size_t high_region_size = nursery_space - high_region_start;

    // Check if we have space in high region.
    if (nursery_high_committed_ + size > high_region_size) {
        if (heapTraceEnabled()) {
            dumpHeapState("acquireNurseryBlockHigh OUT OF SPACE", size);
        }
        return nullptr;  // Out of high region address space.
    }

    // Commit physical memory for this block.
    char* block_base = heap_base + nursery_offset + high_region_start + nursery_high_committed_;
    void* result = mmap(block_base, size, PROT_READ | PROT_WRITE,
                        MAP_PRIVATE | MAP_ANONYMOUS | MAP_FIXED, -1, 0);

    if (result == MAP_FAILED) {
        return nullptr;
    }

    size_t before = nursery_high_committed_;
    nursery_high_committed_ += size;

    if (heapTraceEnabled() &&
        before / HEAP_TRACE_NURSERY_INTERVAL !=
            nursery_high_committed_ / HEAP_TRACE_NURSERY_INTERVAL) {
        dumpHeapState("nursery-high grew", size);
    }

    return block_base;
}

void Allocator::releaseNurseryBlockHigh(char* block, size_t size) {
    std::lock_guard<std::recursive_mutex> lock(thread_mutex_);
    size = (size + 7) & ~7;
    nursery_high_freelist_.emplace_back(block, size);
}

// Acquires a block from the old gen region.
// Thread-safe: acquires thread_mutex_ to update shared committed counters.
char* Allocator::acquireOldGenBlock(size_t size) {
    std::lock_guard<std::recursive_mutex> lock(thread_mutex_);

    // Align size to 8 bytes.
    size = (size + 7) & ~7;

    // Check if we have space in old gen region.
    if (old_gen_committed + size > nursery_offset) {
        // Always log the exhaustion: this is the failure path that triggers
        // the OldGenSpace::bumpAllocate assertion further up the stack.
        dumpHeapState("acquireOldGenBlock OUT OF SPACE (returning nullptr)", size);
        return nullptr;  // Out of old gen address space.
    }

    char* block_base = heap_base + old_gen_committed;

    // Commit physical memory for this block.
    void* result = mmap(block_base, size, PROT_READ | PROT_WRITE,
                        MAP_PRIVATE | MAP_ANONYMOUS | MAP_FIXED, -1, 0);

    if (result == MAP_FAILED) {
        if (heapTraceEnabled()) {
            dumpHeapState("acquireOldGenBlock MAP_FAILED", size);
        }
        return nullptr;
    }

    size_t before = old_gen_committed;
    old_gen_committed += size;

    // Milestone-based growth log so we can see the committed counter
    // climbing through the available old-gen region.
    if (heapTraceEnabled() &&
        before / HEAP_TRACE_OLDGEN_INTERVAL !=
            old_gen_committed / HEAP_TRACE_OLDGEN_INTERVAL) {
        dumpHeapState("oldgen grew", size);
    }

    return block_base;
}

bool Allocator::shouldTriggerMajorGC() const {
    if (nursery_offset == 0) return false;
    if (old_gen_committed <= old_gen_committed_major_gc_watermark_) return false;
    return static_cast<double>(old_gen_committed) / nursery_offset
           >= config_.major_gc_initiating_occupancy;
}

void Allocator::notifyMajorGCComplete() {
    // Watermark is the committed size at the instant the major GC
    // finished. `shouldTriggerMajorGC` requires further growth beyond
    // this mark before re-firing, preventing back-to-back majors when
    // `old_gen_committed` (monotonic) sits slightly above the 75% line.
    old_gen_committed_major_gc_watermark_ = old_gen_committed;
}

void Allocator::ensureOldGenCapacityFor(OldGenSpace& space,
                                        size_t new_capacity_bytes) {
    std::lock_guard<std::recursive_mutex> lock(thread_mutex_);

    auto currentCapacity = [&]() -> size_t {
        if (space.region_base_ == nullptr || space.region_end_ == nullptr) {
            return 0;
        }
        return static_cast<size_t>(space.region_end_ - space.region_base_);
    };

    if (new_capacity_bytes <= currentCapacity()) return;

    // Grow by acquiring fresh old-gen blocks. `acquireOldGenBlock` enforces
    // the global `nursery_offset` cap, so we just loop until we hit the
    // requested capacity or the allocator refuses.
    const size_t block_size = config_.alloc_buffer_size;

    while (currentCapacity() < new_capacity_bytes) {
        char* block_base = acquireOldGenBlock(block_size);
        if (block_base == nullptr) {
            // Hit the global old-gen cap — stop, caller tolerates partial grow.
            break;
        }

        BlockInfo new_block;
        new_block.start = block_base;
        new_block.end = block_base + block_size;
        new_block.alloc_ptr = block_base;  // Empty: sweep/alloc paths will fill.

        space.blocks_.push_back(new_block);
        space.buffer_meta_.push_back(
            {space.blocks_.size() - 1, 0, 0, false});

        if (space.region_base_ == nullptr || block_base < space.region_base_) {
            space.region_base_ = block_base;
        }
        if (block_base + block_size > space.region_end_) {
            space.region_end_ = block_base + block_size;
        }
    }
}

// Reserves a region for old gen with initial commit and growth capacity.
// Pre-condition: caller must hold thread_mutex_.
char* Allocator::acquireOldGenRegion(size_t initial_size, size_t max_size) {
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

// Resets the allocator to initial state, optionally with a new configuration.
// Accumulates stats from all thread heaps before destroying them.
void Allocator::reset(const HeapConfig* new_config) {
    std::lock_guard<std::recursive_mutex> lock(thread_mutex_);

    // Update config if provided.
    if (new_config) {
        new_config->validate();
        config_ = *new_config;
    }

#if ENABLE_GC_STATS
    // Accumulate stats from all thread heaps before destroying them.
    for (const auto& [thread_id, heap] : thread_heaps_) {
        accumulated_stats_.combine(heap->getNursery().getStats());
        accumulated_stats_.combine(heap->getStats());
    }
#endif

    // Clear all thread heaps.
    thread_heaps_.clear();
    tl_heap_ = nullptr;

    // Reset committed memory tracking.
    old_gen_committed = 0;
    nursery_low_committed_ = 0;
    nursery_high_committed_ = 0;

    // Free-lists refer to blocks in the old committed range; they are no
    // longer usable once we reset the bump pointers to 0.
    nursery_low_freelist_.clear();
    nursery_high_freelist_.clear();
}

// ============================================================================
// Safe Public Pointer API
// ============================================================================

// Resolves an HPointer to its physical address, following forwarding pointers.
void* Allocator::resolve(HPointer ptr) {
    assert(ptr.constant == 0 && "Cannot resolve HPointer with constant field set (embedded constant)");

    void* obj = fromPointerRaw(ptr);
    assert(obj && "Null pointer from valid HPointer");

#if ECO_GC_DEBUG
    {
        ThreadLocalHeap* heap = getThreadHeap();
        if (heap != nullptr && heap->isInNursery(obj)) {
            heap->debugAssertValidNurseryPointer(obj);
        }
    }
#endif

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

// Wraps a physical address as an HPointer.
HPointer Allocator::wrap(void* obj) {
    assert(obj && "Cannot wrap null pointer - Elm never produces null pointers");
    assert((reinterpret_cast<uintptr_t>(obj) & 7) == 0 && "Pointer must be 8-byte aligned");
    assert(isInHeap(obj) && "Pointer must be within heap");
    return toPointerRaw(obj);
}

#if ENABLE_GC_STATS
// Returns combined statistics from all thread heaps.
GCStats Allocator::getCombinedStats() const {
    std::lock_guard<std::recursive_mutex> lock(thread_mutex_);

    // Start with accumulated stats from destroyed thread heaps.
    GCStats combined = accumulated_stats_;

    // Add stats from current thread heaps.
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

// Returns the thread-local nursery for testing.
NurserySpace* AllocatorTestAccess::getNursery(Allocator& alloc) {
    ThreadLocalHeap* heap = alloc.getThreadHeap();
    return heap ? &heap->getNursery() : nullptr;
}

// Returns the thread-local old gen for testing.
OldGenSpace* AllocatorTestAccess::getOldGen(Allocator& alloc) {
    ThreadLocalHeap* heap = alloc.getThreadHeap();
    return heap ? &heap->getOldGen() : nullptr;
}

} // namespace Elm
