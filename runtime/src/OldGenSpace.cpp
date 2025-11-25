/**
 * OldGenSpace Implementation.
 *
 * Implements the old generation for long-lived objects using:
 *   - Free-list allocation with first-fit strategy.
 *   - Concurrent tri-color mark-and-sweep collection.
 *   - Thread-local allocation buffers (TLABs) for lock-free promotion.
 *   - Optional compaction to reduce fragmentation.
 *
 * Memory layout:
 *   [0 .. max_size/2)     - Free-list region for general allocation.
 *   [max_size/2 .. end)   - TLAB region for nursery promotions.
 */

#include "OldGenSpace.hpp"
#include "GarbageCollector.hpp"
#include <algorithm>
#include <cstring>
#include <iostream>
#include <new>
#include <sys/mman.h>
#include <atomic>

namespace Elm {

// Global heap base (defined in GarbageCollector.cpp).
extern char* g_heap_base;

// Read barrier implementation - self-healing for forwarded objects.
void* readBarrier(HPointer& ptr) {
    // Null check (common case - embedded constants).
    if (ptr.constant != 0) {
        return nullptr;  // It's a constant, not a heap pointer.
    }

    // Convert logical pointer to physical address.
    void* obj = g_heap_base + (ptr.ptr << 3);

    // Read header (single load).
    Header* hdr = reinterpret_cast<Header*>(obj);

    // Fast path: not forwarded (common case).
    if (hdr->tag != Tag_Forward) {
        return obj;
    }

    // Slow path: follow forwarding pointer and self-heal.
    Forward* fwd = reinterpret_cast<Forward*>(obj);

    // Calculate new location from forward_ptr.
    void* new_location = g_heap_base + (fwd->header.forward_ptr << 3);

    // Self-heal: update the pointer for next access.
    ptr.ptr = fwd->header.forward_ptr;

    return new_location;
}

OldGenSpace::OldGenSpace() :
    config_(nullptr), region_base(nullptr), region_size(0), max_region_size(0), free_list(nullptr),
    current_epoch(0), marking_active(false), gc_ref(nullptr), tlab_region_start(nullptr),
    tlab_region_end(nullptr) {
    // Initialization happens in initialize() method.
}

OldGenSpace::~OldGenSpace() {
    // No need to free memory - it's part of the main heap.
}

void OldGenSpace::initialize(char *base, size_t initial_size, size_t max_size, const GCConfig* config) {
    config_ = config;
    region_base = base;
    region_size = initial_size;
    max_region_size = max_size;

    // Partition memory: 50% for free-list, 50% for TLABs.
    size_t free_list_size = max_size / 2;
    size_t tlab_region_size = max_size - free_list_size;

    // Set up TLAB region boundaries.
    tlab_region_start = base + free_list_size;
    tlab_region_end = base + max_size;

    // Initialize free-list with initial committed memory.
    // (TLAB region memory is committed on-demand.)
    size_t initial_free_list_size = std::min(initial_size, free_list_size);
    FreeBlock *block = reinterpret_cast<FreeBlock *>(region_base);
    block->size = initial_free_list_size;
    block->next = nullptr;
    free_list = block;

    // Initialize TLAB atomic bump pointer to start of TLAB region.
    tlab_bump_ptr.store(tlab_region_start, std::memory_order_relaxed);

    // Track the region as our first "chunk".
    chunks.push_back(region_base);
}

/**
 * Adds a new memory chunk to the old generation space.
 * REQUIRES: Caller must hold alloc_mutex to protect free_list and region_size.
 */
void OldGenSpace::addChunk(size_t size) {
    // Check if we can grow.
    if (region_size >= max_region_size) {
        throw std::bad_alloc();  // Can't grow beyond max.
    }

    // Calculate how much to grow (at least requested size, up to max).
    size_t min_growth = config_->min_old_gen_chunk_size;
    size_t growth = std::max(size * 2, min_growth);
    growth = std::min(growth, max_region_size - region_size);
    growth = std::max(growth, size);

    // Commit more memory.
    char *new_region = region_base + region_size;
    void *result = mmap(new_region, growth, PROT_READ | PROT_WRITE, MAP_PRIVATE | MAP_ANONYMOUS | MAP_FIXED, -1, 0);

    if (result == MAP_FAILED) {
        throw std::bad_alloc();
    }

    // Add new region to free list.
    FreeBlock *block = reinterpret_cast<FreeBlock *>(new_region);
    block->size = growth;
    block->next = free_list;
    free_list = block;

    region_size += growth;
}

/**
 * Allocate memory in the old generation space.
 * This is the public interface - handles locking internally.
 */
void *OldGenSpace::allocate(size_t size) {
    std::lock_guard<std::recursive_mutex> lock(alloc_mutex);
    return allocate_internal(size);
}

/**
 * Internal allocation implementation.
 * REQUIRES: Caller must hold alloc_mutex
 * This may call itself recursively if heap growth is needed.
 */
void *OldGenSpace::allocate_internal(size_t size) {
    size = (size + 7) & ~7;  // Align.
    size = std::max(size, sizeof(FreeBlock));  // Minimum size.

    // NOTE: Caller must hold alloc_mutex.

    FreeBlock **prev_ptr = &free_list;
    FreeBlock *curr = free_list;

    // First-fit allocation.
    while (curr) {
        if (curr->size >= size) {
            // Split block if large enough.
            if (curr->size >= size + sizeof(FreeBlock) + 64) {
                FreeBlock *remainder = reinterpret_cast<FreeBlock *>(reinterpret_cast<char *>(curr) + size);
                remainder->size = curr->size - size;
                remainder->next = curr->next;
                *prev_ptr = remainder;
            } else {
                // Use entire block.
                *prev_ptr = curr->next;
                size = curr->size;
            }

            // Initialize header.
            Header *hdr = reinterpret_cast<Header *>(curr);
            std::memset(hdr, 0, sizeof(Header));

            // Bug: if marking is in progress the object should be conservatively marked Black.
            hdr->color = static_cast<u32>(Color::White);

            // Track allocated bytes.
            allocated_bytes.fetch_add(size, std::memory_order_relaxed);

            return curr;
        }

        prev_ptr = &curr->next;
        curr = curr->next;
    }

    // No suitable block, allocate new chunk.
    size_t chunk_size = std::max(size * 2, config_->min_old_gen_chunk_size);
    addChunk(chunk_size);

    // Try again (recursive call to internal version, lock already held).
    return allocate_internal(size);
}

bool OldGenSpace::contains(void *ptr) const {
    char *p = static_cast<char *>(ptr);
    // Check both free-list allocation region and TLAB region.
    // Free-list: [region_base, region_base + region_size)
    // TLAB: [tlab_region_start, tlab_region_end)
    bool in_freelist = (p >= region_base && p < region_base + region_size);
    bool in_tlab = (p >= tlab_region_start && p < tlab_region_end);
    return in_freelist || in_tlab;
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
    // Ensure minimum size and alignment.
    size = std::max(size, config_->tlab_min_size);
    size = (size + 7) & ~7;  // 8-byte align.

    // Lock-free allocation using atomic CAS.
    char* current = tlab_bump_ptr.load(std::memory_order_relaxed);
    char* new_ptr;

    // CAS loop: try to claim [current, current+size).
    do {
        new_ptr = current + size;

        // Check if we have space in TLAB region.
        if (new_ptr > tlab_region_end) {
            // TLAB region exhausted - fall back to free-list.
            return nullptr;
        }

        // Try to atomically update bump pointer.
        // If successful: we claimed [current, new_ptr).
        // If failed: another thread claimed it, 'current' is updated, retry.
    } while (!tlab_bump_ptr.compare_exchange_weak(
        current,                    // Expected value (updated on failure).
        new_ptr,                    // New value if successful.
        std::memory_order_release,  // Success ordering (make writes visible).
        std::memory_order_relaxed   // Failure ordering (just retry).
    ));

    // Success! We claimed [current, new_ptr).
    // Check if we need to commit more memory.
    char* committed_end = region_base + region_size;
    if (new_ptr > committed_end) {
        // Need to commit more memory.
        size_t needed = new_ptr - committed_end;
        void* result = mmap(committed_end, needed,
                           PROT_READ | PROT_WRITE,
                           MAP_PRIVATE | MAP_ANONYMOUS | MAP_FIXED,
                           -1, 0);

        if (result == MAP_FAILED) {
            // Failed to commit - return nullptr and let caller fall back to free-list.
            return nullptr;
        }

        // Update region_size to reflect new committed memory.
        // Safe despite potential races: multiple threads may commit overlapping regions,
        // but mmap with MAP_FIXED is idempotent for already-mapped pages.
        region_size = new_ptr - region_base;
    }

    // Create and return TLAB.
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

    // If TLAB is completely empty, just delete it.
    if (tlab->isEmpty()) {
        delete tlab;
        return;
    }

    // Track bytes allocated into this TLAB.
    allocated_bytes.fetch_add(tlab->bytesUsed(), std::memory_order_relaxed);

    // Add to sealed list for sweeping.
    std::lock_guard<std::mutex> lock(sealed_tlabs_mutex);
    sealed_tlabs.push_back(tlab);
}

/**
 * Start a concurrent marking phase.
 * This is a public method that handles its own locking.
 * Takes collected roots from all threads and GC reference for nursery checks.
 */
#if ENABLE_GC_STATS
void OldGenSpace::startConcurrentMark(const std::vector<HPointer*> &roots, GarbageCollector &gc, GCStats &stats) {
#else
void OldGenSpace::startConcurrentMark(const std::vector<HPointer*> &roots, GarbageCollector &gc) {
#endif
    std::lock_guard<std::recursive_mutex> lock(mark_mutex);

    if (marking_active)
        return;

    marking_active = true;
    current_epoch++;
    mark_stack.clear();

    // Store GC reference for nursery checks during marking.
    gc_ref = &gc;

    // Initialize blocks for compaction tracking.
    if (blocks.empty()) {
        initializeBlocks();
    }

    // Reset block live info for new marking phase.
    for (auto& block : blocks) {
        block.live_bytes = 0;
        block.live_count = 0;
        block.is_evacuation_target = false;
        block.is_evacuation_dest = false;
    }

    // Push ALL roots onto mark stack - including nursery objects.
    // Nursery objects will be marked (grey->black) like old gen objects.
    // This is harmless since minor GC uses forwarding pointers, not colors.
    for (HPointer *root: roots) {
        void *obj = GarbageCollector::fromPointerRaw(*root);
        if (obj && (contains(obj) || gc_ref->isInNursery(obj))) {
            mark_stack.push_back(obj);
        }
    }

#if ENABLE_GC_STATS
    GC_STATS_MAJOR_INC_CONCURRENT_MARK(stats);
#endif
}

/**
 * Perform incremental marking work.
 * This is a public method that handles its own locking.
 * Returns true if more work remains, false if marking is complete.
 */
#if ENABLE_GC_STATS
bool OldGenSpace::incrementalMark(size_t work_units, GCStats &stats) {
#else
bool OldGenSpace::incrementalMark(size_t work_units) {
#endif
    std::lock_guard<std::recursive_mutex> lock(mark_mutex);

    if (!marking_active || mark_stack.empty()) {
        return false;  // No work to do.
    }

    size_t units_done = 0;

    while (!mark_stack.empty() && units_done < work_units) {
        void *obj = mark_stack.back();
        mark_stack.pop_back();

        Header *hdr = getHeader(obj);

        // Skip if already black.
        if (hdr->color == static_cast<u32>(Color::Black)) {
            continue;
        }

        // Mark grey first.
        hdr->color = static_cast<u32>(Color::Grey);

        // Process children.
        markChildren(obj);

        // Mark black.
        hdr->color = static_cast<u32>(Color::Black);
        hdr->epoch = current_epoch & 3;

        // Track block occupancy for compaction (old gen only).
        if (contains(obj)) {
            size_t obj_size = getObjectSize(obj);
            updateBlockLiveInfo(obj, obj_size);
        }

        units_done++;
    }

#if ENABLE_GC_STATS
    GC_STATS_MAJOR_INC_INCREMENTAL_MARK(stats, units_done);
#endif

    return !mark_stack.empty();
}

void OldGenSpace::markChildren(void *obj) {
    Header *hdr = getHeader(obj);

    switch (hdr->tag) {
        case Tag_Tuple2: {
            Tuple2 *t = static_cast<Tuple2 *>(obj);
            markUnboxable(t->a, !(hdr->unboxed & 1));
            markUnboxable(t->b, !(hdr->unboxed & 2));
            break;
        }
        case Tag_Tuple3: {
            Tuple3 *t = static_cast<Tuple3 *>(obj);
            markUnboxable(t->a, !(hdr->unboxed & 1));
            markUnboxable(t->b, !(hdr->unboxed & 2));
            markUnboxable(t->c, !(hdr->unboxed & 4));
            break;
        }
        case Tag_Cons: {
            Cons *c = static_cast<Cons *>(obj);
            markUnboxable(c->head, !(hdr->unboxed & 1));
            markHPointer(c->tail);
            break;
        }
        case Tag_Custom: {
            Custom *c = static_cast<Custom *>(obj);
            for (u32 i = 0; i < hdr->size && i < 48; i++) {
                markUnboxable(c->values[i], !(c->unboxed & (1ULL << i)));
            }
            break;
        }
        case Tag_Record: {
            Record *r = static_cast<Record *>(obj);
            for (u32 i = 0; i < hdr->size && i < 64; i++) {
                markUnboxable(r->values[i], !(r->unboxed & (1ULL << i)));
            }
            break;
        }
        case Tag_DynRecord: {
            DynRecord *dr = static_cast<DynRecord *>(obj);
            markHPointer(dr->fieldgroup);
            for (u32 i = 0; i < hdr->size; i++) {
                markHPointer(dr->values[i]);
            }
            break;
        }
        case Tag_Closure: {
            Closure *cl = static_cast<Closure *>(obj);
            for (u32 i = 0; i < cl->n_values; i++) {
                markUnboxable(cl->values[i], !(cl->unboxed & (1ULL << i)));
            }
            break;
        }
        case Tag_Process: {
            Process *p = static_cast<Process *>(obj);
            markHPointer(p->root);
            markHPointer(p->stack);
            markHPointer(p->mailbox);
            break;
        }
        case Tag_Task: {
            Task *t = static_cast<Task *>(obj);
            markHPointer(t->value);
            markHPointer(t->callback);
            markHPointer(t->kill);
            markHPointer(t->task);
            break;
        }
        default:
            break;
    }
}

void OldGenSpace::markHPointer(HPointer &ptr) {
    if (ptr.constant != 0)
        return;

    void *obj = GarbageCollector::fromPointerRaw(ptr);
    if (!obj)
        return;

    // Push both old gen and nursery objects onto mark stack.
    // Nursery objects will be marked grey->black like old gen objects.
    // This is harmless since minor GC uses forwarding pointers, not colors.
    if (contains(obj) || (gc_ref && gc_ref->isInNursery(obj))) {
        Header *hdr = getHeader(obj);
        if (hdr->color != static_cast<u32>(Color::Black)) {
            mark_stack.push_back(obj);
        }
    }
}

void OldGenSpace::markUnboxable(Unboxable &val, bool is_boxed) {
    if (is_boxed) {
        markHPointer(val.p);
    }
}

/**
 * Complete marking phase and perform sweep.
 * This is a public method. It calls incrementalMark() and sweep() which handle their own locking.
 */
#if ENABLE_GC_STATS
void OldGenSpace::finishMarkAndSweep(GCStats &stats) {
    // Complete any remaining marking.
    while (incrementalMark(1000, stats)) {
        // Keep marking.
    }

    sweep();

    marking_active = false;

    GC_STATS_MAJOR_INC_MARK_SWEEP(stats);
}
#else
void OldGenSpace::finishMarkAndSweep() {
    // Complete any remaining marking.
    while (incrementalMark(1000)) {
        // Keep marking.
    }

    sweep();

    marking_active = false;
}
#endif

/**
 * Sweep phase - reclaim unmarked (white) objects.
 * This is a private method but handles its own locking (alloc_mutex).
 * Called by finishMarkAndSweep() which doesn't hold any locks.
 */
void OldGenSpace::sweep() {
    std::lock_guard<std::recursive_mutex> lock(alloc_mutex);

    // Rebuild free list from white (unmarked) objects.
    FreeBlock *new_free_list = nullptr;

    // ========================================================================
    // Part 1: Sweep sealed TLABs.
    // ========================================================================
    {
        std::lock_guard<std::mutex> tlock(sealed_tlabs_mutex);

        for (TLAB* tlab : sealed_tlabs) {
            char* ptr = tlab->start;
            char* used_end = tlab->alloc_ptr;  // Only sweep used portion!

            // Walk objects in this TLAB.
            while (ptr < used_end) {
                Header* hdr = reinterpret_cast<Header*>(ptr);
                size_t obj_size = getObjectSize(ptr);

                if (hdr->color == static_cast<u32>(Color::White)) {
                    // Dead object - add to free list.
                    FreeBlock* block = reinterpret_cast<FreeBlock*>(ptr);
                    block->size = obj_size;
                    block->next = new_free_list;
                    new_free_list = block;
                } else {
                    // Live object - reset color for next GC cycle.
                    hdr->color = static_cast<u32>(Color::White);
                }

                ptr += obj_size;
            }

            // Delete TLAB metadata.
            delete tlab;
        }

        // Clear sealed TLABs list.
        sealed_tlabs.clear();
    }

    // ========================================================================
    // Part 2: Sweep free-list region.
    // ========================================================================

    // Only sweep up to where TLAB region starts.
    char *ptr = region_base;
    char *end = std::min(tlab_region_start, region_base + region_size);

    while (ptr < end) {
        Header *hdr = reinterpret_cast<Header *>(ptr);

        // Check if this is a valid object.
        if (hdr->tag >= Tag_Forward) {
            ptr += sizeof(Header);
            continue;
        }

        // Use getObjectSize() to correctly calculate size for all object types.
        size_t obj_size = getObjectSize(ptr);

        // Skip objects that would extend past the sweep boundary into TLAB region.
        // This can happen when garbage data near the boundary is interpreted as an object.
        if (ptr + obj_size > end) {
            break;
        }

        if (hdr->color == static_cast<u32>(Color::White)) {
            // Add to free list.
            FreeBlock *block = reinterpret_cast<FreeBlock *>(ptr);
            block->size = obj_size;
            block->next = new_free_list;
            new_free_list = block;
        } else {
            // Reset color to white for next cycle.
            hdr->color = static_cast<u32>(Color::White);
        }

        ptr += obj_size;
    }

    free_list = new_free_list;
}

void OldGenSpace::reset() {
    // Reset all state to initial.
    free_list = nullptr;
    marking_active = false;
    current_epoch = 0;
    mark_stack.clear();

    // Reset blocks.
    blocks.clear();
    compaction_in_progress = false;

    // Clear chunks (will be re-added by initialize()).
    chunks.clear();

    // Clear TLABs.
    {
        std::lock_guard<std::mutex> lock(sealed_tlabs_mutex);
        for (TLAB* tlab : sealed_tlabs) {
            delete tlab;
        }
        sealed_tlabs.clear();
    }

    {
        std::lock_guard<std::mutex> lock(available_tlabs_mutex);
        for (TLAB* tlab : available_tlabs) {
            delete tlab;
        }
        available_tlabs.clear();
    }

    // Re-initialize with original settings if needed.
    if (region_base && region_size > 0) {
        initialize(region_base, region_size, max_region_size, config_);
    }
}

// ============================================================================
// Compaction Implementation
// ============================================================================

void OldGenSpace::initializeBlocks() {
    // Divide the free-list region into fixed-size blocks.
    blocks.clear();

    char* ptr = region_base;
    char* end = tlab_region_start;  // Only up to TLAB region.
    size_t block_size = config_->block_size;

    while (ptr + block_size <= end) {
        BlockInfo block;
        block.start = ptr;
        block.end = ptr + block_size;
        block.block_size = block_size;
        block.live_bytes = 0;
        block.live_count = 0;
        block.is_evacuation_target = false;
        block.is_evacuation_dest = false;
        blocks.push_back(block);

        ptr += block_size;
    }

    // Handle any remaining space as a partial block.
    if (ptr < end) {
        BlockInfo block;
        block.start = ptr;
        block.end = end;
        block.block_size = end - ptr;
        block.live_bytes = 0;
        block.live_count = 0;
        block.is_evacuation_target = false;
        block.is_evacuation_dest = false;
        blocks.push_back(block);
    }
}

OldGenSpace::BlockInfo* OldGenSpace::getBlockForObject(void* obj) {
    char* addr = static_cast<char*>(obj);

    for (auto& block : blocks) {
        if (addr >= block.start && addr < block.end) {
            return &block;
        }
    }

    return nullptr;
}

void OldGenSpace::updateBlockLiveInfo(void* obj, size_t size) {
    BlockInfo* block = getBlockForObject(obj);
    if (block) {
        __atomic_add_fetch(&block->live_bytes, size, __ATOMIC_RELAXED);
        __atomic_add_fetch(&block->live_count, 1, __ATOMIC_RELAXED);
    }
}

void OldGenSpace::selectCompactionSet() {
    // Initialize blocks if not done.
    if (blocks.empty()) {
        initializeBlocks();
    }

    // Sort blocks by occupancy.
    std::vector<BlockInfo*> candidates;

    for (auto& block : blocks) {
        double occupancy = (double)block.live_bytes / block.block_size;

        if (occupancy < config_->evacuation_threshold && occupancy > 0) {
            block.is_evacuation_target = true;
            candidates.push_back(&block);
        } else if (occupancy < config_->evacuation_dest_threshold) {
            block.is_evacuation_dest = true;
        }
    }

    // Limit compaction work per cycle.
    size_t max_evac_bytes = static_cast<size_t>(region_size * config_->max_evacuation_ratio);
    size_t planned_bytes = 0;

    // Sort by live bytes (evacuate blocks with fewest live objects first).
    std::sort(candidates.begin(), candidates.end(),
              [](auto a, auto b) { return a->live_bytes < b->live_bytes; });

    for (auto* block : candidates) {
        if (planned_bytes + block->live_bytes > max_evac_bytes) {
            block->is_evacuation_target = false;
        } else {
            planned_bytes += block->live_bytes;
        }
    }
}

void* OldGenSpace::allocateForCompaction(size_t size) {
    // Try to allocate in a destination block.
    // For now, use regular allocation.
    return allocate_internal(size);
}

void OldGenSpace::evacuateObject(void* obj) {
    Header* hdr = getHeader(obj);
    size_t obj_size = getObjectSize(obj);

    // Allocate destination.
    void* new_location = allocateForCompaction(obj_size);
    if (!new_location) {
        // Cannot evacuate - out of space.
        return;
    }

    // Copy object to new location.
    memcpy(new_location, obj, obj_size);

    // Prepare forwarding header.
    Forward fwd;
    fwd.header.tag = Tag_Forward;

    // Calculate logical pointer offset.
    uintptr_t byte_offset = static_cast<char*>(new_location) - region_base;
    fwd.header.forward_ptr = byte_offset >> 3;  // Divide by 8.
    fwd.header.unused = 0;

    // Atomic 64-bit CAS to install forwarding pointer.
    u64 old_header_bits = *reinterpret_cast<u64*>(hdr);
    u64 new_forward_bits = *reinterpret_cast<u64*>(&fwd.header);

    std::atomic<u64>* atomic_hdr = reinterpret_cast<std::atomic<u64>*>(hdr);
    if (!atomic_hdr->compare_exchange_strong(old_header_bits, new_forward_bits)) {
        // Someone else evacuated it first, free our copy.
        // For now, we'll just leak it (will be reclaimed in next GC).
        // In a production system, we'd have a way to free this.
    }
}

void OldGenSpace::evacuateBlock(size_t block_index) {
    if (block_index >= blocks.size()) return;

    BlockInfo& block = blocks[block_index];
    if (!block.is_evacuation_target) return;

    char* scan = block.start;

    while (scan < block.end) {
        Header* hdr = reinterpret_cast<Header*>(scan);

        // Skip if already forwarded or not a valid object.
        if (hdr->tag == Tag_Forward || hdr->tag >= Tag_Forward) {
            scan += sizeof(Header);  // Minimum advance.
            continue;
        }

        size_t obj_size = getObjectSize(scan);

        // Only evacuate live objects.
        if (hdr->color == static_cast<u32>(Color::Black)) {
            evacuateObject(scan);
        }

        scan += obj_size;
    }
}

void OldGenSpace::performCompaction() {
    // Evacuate all selected blocks.
    for (size_t i = 0; i < blocks.size(); i++) {
        if (blocks[i].is_evacuation_target) {
            evacuateBlock(i);
        }
    }
}

void OldGenSpace::reclaimEvacuatedBlocks() {
    std::vector<TLAB*> new_tlabs;

    for (auto& block : blocks) {
        if (!block.is_evacuation_target) continue;

        // Verify block is fully evacuated.
        bool fully_evacuated = true;
        char* scan = block.start;

        while (scan < block.end) {
            Header* hdr = reinterpret_cast<Header*>(scan);

            // Check if this is not a forwarding pointer and is live.
            if (hdr->tag != Tag_Forward && hdr->color == static_cast<u32>(Color::Black)) {
                fully_evacuated = false;
                break;
            }

            // Advance by object size or minimum if it's a forward.
            if (hdr->tag == Tag_Forward) {
                scan += sizeof(Forward);
            } else {
                scan += getObjectSize(scan);
            }
        }

        if (fully_evacuated) {
            // Entire block is free - perfect for TLAB!
            TLAB* new_tlab = new TLAB(block.start, block.block_size);
            new_tlabs.push_back(new_tlab);

            // Clear the block (helps debugging).
            memset(block.start, 0, block.block_size);

            // Reset block metadata.
            block.live_bytes = 0;
            block.live_count = 0;
            block.is_evacuation_target = false;
            block.is_evacuation_dest = false;
        }
    }

    // Add reclaimed TLABs to available pool.
    std::lock_guard<std::mutex> lock(available_tlabs_mutex);
    for (TLAB* tlab : new_tlabs) {
        available_tlabs.push_back(tlab);
    }
}

} // namespace Elm
