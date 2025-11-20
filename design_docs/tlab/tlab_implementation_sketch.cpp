// TLAB Implementation Sketch - Key code changes
//
// This shows the specific implementation of TLAB methods

#include "allocator.hpp"
#include <algorithm>

namespace Elm {

// ============================================================================
// OldGenSpace TLAB Methods
// ============================================================================

/**
 * Initialize the OldGenSpace with TLAB support.
 *
 * Memory layout after initialization:
 *   [=== Free-list region ===][=== TLAB region ===]
 *   ^                         ^                    ^
 *   region_base          tlab_region_start   tlab_region_end
 *
 * Free-list region: For large objects and legacy allocations
 * TLAB region: Lock-free TLAB allocation via atomic bump pointer
 */
void OldGenSpace::initialize(char *base, size_t initial_size, size_t max_size) {
    region_base = base;
    region_size = initial_size;
    max_region_size = max_size;

    // Partition memory: 50% for free-list, 50% for TLABs
    // This ratio can be tuned based on workload
    size_t free_list_size = max_size / 2;
    size_t tlab_region_size = max_size - free_list_size;

    // Set up TLAB region boundaries
    tlab_region_start = base + free_list_size;
    tlab_region_end = base + max_size;

    // Initialize free-list with initial committed memory
    // (TLAB region memory is committed on-demand)
    FreeBlock *block = reinterpret_cast<FreeBlock*>(region_base);
    block->size = std::min(initial_size, free_list_size);
    block->next = nullptr;
    free_list = block;

    // Initialize TLAB atomic bump pointer to start of TLAB region
    tlab_bump_ptr.store(tlab_region_start, std::memory_order_relaxed);

    chunks.push_back(region_base);
}

/**
 * Allocate a new TLAB using lock-free atomic CAS.
 *
 * This method can be called concurrently by multiple threads.
 * The atomic compare-exchange ensures only one thread gets each TLAB.
 *
 * @param size Size of TLAB to allocate (default 128KB)
 * @return Pointer to new TLAB, or nullptr if TLAB region exhausted
 */
TLAB* OldGenSpace::allocateTLAB(size_t size) {
    // Ensure minimum size and alignment
    size = std::max(size, TLAB_MIN_SIZE);
    size = (size + 7) & ~7; // 8-byte align

    // Lock-free allocation using atomic CAS
    char* current = tlab_bump_ptr.load(std::memory_order_relaxed);
    char* new_ptr;

    // CAS loop: try to claim [current, current+size)
    do {
        new_ptr = current + size;

        // Check if we have space in TLAB region
        if (new_ptr > tlab_region_end) {
            // TLAB region exhausted
            // Could trigger TLAB region growth here, but for simplicity
            // we return nullptr and let caller fall back to free-list
            return nullptr;
        }

        // Try to atomically update bump pointer
        // If successful: we claimed [current, new_ptr)
        // If failed: another thread claimed it, 'current' is updated, retry
    } while (!tlab_bump_ptr.compare_exchange_weak(
        current,              // Expected value (updated on failure)
        new_ptr,              // New value if successful
        std::memory_order_release,  // Success ordering (make writes visible)
        std::memory_order_relaxed   // Failure ordering (just retry)
    ));

    // Success! We claimed [current, new_ptr)
    // Need to ensure this memory is committed (may be in reserved but uncommitted space)

    // Check if we need to commit more memory
    char* committed_end = region_base + region_size;
    if (new_ptr > committed_end) {
        // Need to commit more memory
        // This is the only point where we might need synchronization
        // But mmap with MAP_FIXED is typically safe for concurrent commits
        // of non-overlapping regions

        size_t needed = new_ptr - committed_end;
        void* result = mmap(committed_end, needed,
                           PROT_READ | PROT_WRITE,
                           MAP_PRIVATE | MAP_ANONYMOUS | MAP_FIXED,
                           -1, 0);

        if (result == MAP_FAILED) {
            // Failed to commit - back out our CAS
            // This is tricky - we'd need to handle this atomically
            // For simplicity, just leak this space and return nullptr
            return nullptr;
        }

        // Update region_size atomically (or use a mutex if needed)
        // For now, assume region_size updates are rare and benign if racy
        region_size = new_ptr - region_base;
    }

    // Create and return TLAB
    return new TLAB(current, size);
}

/**
 * Seal a TLAB that is no longer being used.
 *
 * Sealed TLABs are added to the sealed_tlabs list and will be
 * swept during the next major GC cycle.
 *
 * @param tlab TLAB to seal (can be nullptr)
 */
void OldGenSpace::sealTLAB(TLAB* tlab) {
    if (!tlab) {
        return;
    }

    // If TLAB is completely empty, just delete it
    if (tlab->isEmpty()) {
        delete tlab;
        return;
    }

    // Add to sealed list for sweeping
    std::lock_guard<std::mutex> lock(sealed_tlabs_mutex);
    sealed_tlabs.push_back(tlab);
}

/**
 * Modified sweep to handle both free-list region and sealed TLABs.
 */
void OldGenSpace::sweep() {
    std::lock_guard<std::recursive_mutex> lock(alloc_mutex);

    FreeBlock *new_free_list = nullptr;

    // ========================================================================
    // Part 1: Sweep sealed TLABs
    // ========================================================================
    {
        std::lock_guard<std::mutex> tlock(sealed_tlabs_mutex);

        for (TLAB* tlab : sealed_tlabs) {
            char* ptr = tlab->start;
            char* used_end = tlab->alloc_ptr; // Only sweep used portion!

            // Walk objects in this TLAB
            while (ptr < used_end) {
                Header* hdr = reinterpret_cast<Header*>(ptr);
                size_t obj_size = getObjectSize(ptr);

                if (hdr->color == static_cast<u32>(Color::White)) {
                    // Dead object - add to free list
                    FreeBlock* block = reinterpret_cast<FreeBlock*>(ptr);
                    block->size = obj_size;
                    block->next = new_free_list;
                    new_free_list = block;
                } else {
                    // Live object - reset color for next GC cycle
                    hdr->color = static_cast<u32>(Color::White);
                }

                ptr += obj_size;
            }

            // Delete TLAB metadata
            delete tlab;
        }

        // Clear sealed TLABs list
        sealed_tlabs.clear();
    }

    // ========================================================================
    // Part 2: Sweep free-list region (existing code, slightly modified)
    // ========================================================================

    // Only sweep up to where TLAB region starts
    char* ptr = region_base;
    char* end = std::min(tlab_region_start, region_base + region_size);

    while (ptr < end) {
        Header* hdr = reinterpret_cast<Header*>(ptr);

        // Skip invalid tags
        if (hdr->tag >= Tag_Forward) {
            ptr += sizeof(Header);
            continue;
        }

        size_t obj_size = getObjectSize(ptr);

        if (hdr->color == static_cast<u32>(Color::White)) {
            // Dead object - add to free list
            FreeBlock* block = reinterpret_cast<FreeBlock*>(ptr);
            block->size = obj_size;
            block->next = new_free_list;
            new_free_list = block;
        } else {
            // Live object - reset color
            hdr->color = static_cast<u32>(Color::White);
        }

        ptr += obj_size;
    }

    free_list = new_free_list;
}

// ============================================================================
// NurserySpace TLAB Integration
// ============================================================================

/**
 * Constructor - initialize promotion_tlab to nullptr.
 */
NurserySpace::NurserySpace() :
    memory(nullptr), from_space(nullptr), to_space(nullptr),
    alloc_ptr(nullptr), scan_ptr(nullptr),
    promotion_tlab(nullptr) {  // NEW: Initialize TLAB pointer
    // Rest of initialization in initialize() method
}

/**
 * Destructor - seal any active TLAB.
 */
NurserySpace::~NurserySpace() {
    // NEW: Seal TLAB if we have one
    if (promotion_tlab) {
        GarbageCollector::instance().getOldGen().sealTLAB(promotion_tlab);
        promotion_tlab = nullptr;
    }
    // No need to free memory - it's part of the main heap
}

/**
 * Modified evacuate() to use TLAB for promotions.
 *
 * Allocation priority:
 * 1. Try TLAB (fast path, no lock)
 * 2. If TLAB full, seal and get new TLAB (lock-free CAS)
 * 3. If TLAB region exhausted or object too large, use free-list (mutex)
 */
void NurserySpace::evacuate(HPointer &ptr, OldGenSpace &oldgen, std::vector<void*> *promoted_objects) {
    if (ptr.constant != 0)
        return; // It's a constant

    void *obj = fromPointer(ptr);
    if (!obj)
        return;

    // Check for forwarding pointer (existing code)
    Header *hdr = getHeader(obj);
    if (hdr->tag == Tag_Forward) {
        Forward *fwd = static_cast<Forward *>(obj);
        char *heap_base = GarbageCollector::instance().getHeapBase();
        uintptr_t byte_offset = static_cast<uintptr_t>(fwd->pointer) << 3;
        ptr = toPointer(heap_base + byte_offset);
        return;
    }

    // Only evacuate from from-space (existing code)
    char *p = static_cast<char *>(obj);
    if (p < from_space || p >= from_space + (NURSERY_SIZE / 2))
        return;

    size_t size = getObjectSize(obj);
    void *new_obj = nullptr;
    bool promoted = false;

    // ========================================================================
    // MODIFIED: Promotion logic with TLAB
    // ========================================================================

    if (hdr->age >= PROMOTION_AGE) {
        // Fast path: Try TLAB allocation
        if (promotion_tlab && size <= TLAB::TLAB_DEFAULT_SIZE) {
            new_obj = promotion_tlab->allocate(size);
        }

        // TLAB exhausted or doesn't exist?
        if (!new_obj) {
            // Check if current TLAB is exhausted
            if (promotion_tlab && promotion_tlab->bytesRemaining() < size) {
                // Seal exhausted TLAB
                oldgen.sealTLAB(promotion_tlab);
                promotion_tlab = nullptr;
            }

            // Try to get a new TLAB (lock-free CAS)
            if (!promotion_tlab && size <= TLAB::TLAB_DEFAULT_SIZE) {
                promotion_tlab = oldgen.allocateTLAB();
                if (promotion_tlab) {
                    new_obj = promotion_tlab->allocate(size);
                }
            }
        }

        // Fallback: Use free-list allocation (for large objects or TLAB exhaustion)
        if (!new_obj) {
            new_obj = oldgen.allocate(size); // Takes mutex
        }

        if (new_obj) {
            // Save color, copy object, restore color (existing code)
            Header *new_hdr = getHeader(new_obj);
            u32 saved_color = new_hdr->color;
            std::memcpy(new_obj, obj, size);
            new_hdr = getHeader(new_obj);
            new_hdr->color = saved_color;
            new_hdr->age = 0;
            promoted = true;

            // Add to promoted objects for scanning
            if (promoted_objects) {
                promoted_objects->push_back(new_obj);
            }

            GC_STATS_INC_PROMOTED(stats);
        }
    }

    // ========================================================================
    // Rest of evacuate() unchanged
    // ========================================================================

    // Copy to to_space if not promoted (existing code)
    if (!new_obj) {
        new_obj = alloc_ptr;
        alloc_ptr += size;
        std::memcpy(new_obj, obj, size);
        Header *new_hdr = getHeader(new_obj);
        new_hdr->age++;
        GC_STATS_INC_SURVIVORS(stats);
    }

    // Leave forwarding pointer (existing code)
    Forward *fwd = static_cast<Forward *>(obj);
    fwd->header.tag = Tag_Forward;
    char *heap_base = GarbageCollector::instance().getHeapBase();
    uintptr_t byte_offset = static_cast<char *>(new_obj) - heap_base;
    fwd->pointer = byte_offset >> 3;

    ptr = toPointer(new_obj);
}

} // namespace Elm
