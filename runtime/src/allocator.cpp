#include "allocator.hpp"
#include <algorithm>
#include <cstring>
#include <iostream>
#include <new>
#include <sys/mman.h>

namespace Elm {

// ============================================================================
// NurserySpace Implementation
// ============================================================================

NurserySpace::NurserySpace() :
    memory(nullptr), from_space(nullptr), to_space(nullptr), alloc_ptr(nullptr), scan_ptr(nullptr),
    promotion_tlab(nullptr) {
    // Initialization happens in initialize() method
}

NurserySpace::~NurserySpace() {
    // Seal any active TLAB before destroying nursery
    if (promotion_tlab) {
        GarbageCollector::instance().getOldGen().sealTLAB(promotion_tlab);
        promotion_tlab = nullptr;
    }
    // No need to free memory - it's part of the main heap
}

void NurserySpace::initialize(char *nursery_base, size_t size) {
    memory = nursery_base;
    from_space = memory;
    to_space = memory + (size / 2);
    alloc_ptr = from_space;
    scan_ptr = from_space;
}

void *NurserySpace::allocate(size_t size) {
    // Align to 8 bytes
    size = (size + 7) & ~7;

    if (alloc_ptr + size > from_space + (NURSERY_SIZE / 2)) {
        return nullptr; // Nursery full, trigger GC
    }

    void *result = alloc_ptr;
    alloc_ptr += size;

    GC_STATS_RECORD_ALLOC(stats, size);

    return result;
}

bool NurserySpace::contains(void *ptr) const {
    char *p = static_cast<char *>(ptr);
    return (p >= memory && p < memory + NURSERY_SIZE);
}

/**
 * Performs a minor garbage collection by evacuating all live objects out of the nursery "from space" and
 * into new locations in either the nursery "to space" or the old generation space.
 *
 * All known roots and current stack roots are evacuated first. This may create an initial set of objects
 * allocated in the to space.
 *
 * A scan pointer is set to the start of the to space, and is stepped over every object it encounters in the
 * to space, evacuating any object that it finds a pointer to. If more objects are evecuated into the to space,
 * this will bump up the allocation pointer and those objects will be created ahead of the scan pointer so will
 * also evantually be scanned. When the scan pointer catches up to the allocation pointer, there are no more live
 * objects left to consider.
 *
 * The from and to spaces are flipped over in their roles once all live objects have been removed.
 *
 * There is no "remembered set" of pointers from the old generation into the nursery to consider, since Elm
 * only creates acyclic structures on the heap and immutability means that younger object only point to older
 * ones and never the other way around. Therefore objects moved into the old generation during evacuation do
 * not need to be scanned by Cheneys algorithm.
 */
void NurserySpace::minorGC(RootSet &roots, OldGenSpace &oldgen) {
#if ENABLE_GC_STATS
    // Capture state before GC
    size_t from_space_used = alloc_ptr - from_space;
    auto gc_start = GC_STATS_TIMER_START();
#endif

    // Reset allocation into the to_space
    alloc_ptr = to_space;
    scan_ptr = to_space;
    char *alloc_end = to_space;

    // Buffer for promoted objects that need scanning
    std::vector<void*> promoted_objects;

    // Phase 1: Evacuate roots (may add to promoted_objects)
    for (HPointer *root: roots.getRoots()) {
        evacuate(*root, oldgen, &promoted_objects);
    }

    // TODO: This part needs linking into LLVM to get the stack roots.
    // Evacuate any stack roots also.
    for (auto &[stack_ptr, size]: roots.getStackRoots()) {
        HPointer *ptrs = static_cast<HPointer *>(stack_ptr);
        size_t count = size / sizeof(HPointer);
        for (size_t i = 0; i < count; i++) {
            evacuate(ptrs[i], oldgen, &promoted_objects);
        }
    }

    // Phase 2: Cheney's algorithm on to-space (may add to promoted_objects)
    alloc_end = alloc_ptr;
    while (scan_ptr < alloc_end) {
        void *obj = scan_ptr;
        scanObject(obj, oldgen, &promoted_objects);
        scan_ptr += getObjectSize(obj);
        alloc_end = alloc_ptr; // Update in case scanObject caused evacuations
    }

    // Phase 3: Process promoted objects until buffer is empty
    // Use index-based loop since vector may grow during iteration
    for (size_t i = 0; i < promoted_objects.size(); i++) {
        scanObject(promoted_objects[i], oldgen, &promoted_objects);
    }

    // Phase 4: Flip spaces
    std::swap(from_space, to_space);
    // After swap: from_space = old to_space (has live objects)
    //             to_space = old from_space (empty)
    //             alloc_ptr already points to end of live objects in new from_space
    scan_ptr = from_space;

#if ENABLE_GC_STATS
    // Calculate what happened during this GC
    size_t to_space_used = alloc_ptr - from_space;
    size_t bytes_freed = from_space_used - to_space_used;
    uint64_t elapsed_ns = GC_STATS_TIMER_ELAPSED_NS(gc_start);

    GC_STATS_RECORD_GC_END(stats, elapsed_ns, bytes_freed);
#endif
}

/**
 * Updates a pointer into the nursery space to a new location at which that object will located after
 * a garbage collection cycle. The pointer MUST point to a live object that should not be garbage
 * collected.
 *
 *     - If the object has already been moved, it will leave behing a forwarding pointer, and the
 *       pointer requested will be updated to this new location.
 *     - If the object has not already been moved, it will be copied to its new location, and the
 *       pointer requested will be updated to this new location.
 *
 * If the object has reached promotion age by surviving a number of garbage collection moves, it is moved
 * into the old generation. Otherwise, it is moved to the nursery "to space" and its age is incremented by
 * one.
 *
 * The original object in the nursery "from space" is replaced with a Tag_Forward and its forwarding address
 * in either the old generation or the nursery to space, so that subsequent requests to evacuate the same
 * pointer can be updated to its new location without repeating the move.
 */
void NurserySpace::evacuate(HPointer &ptr, OldGenSpace &oldgen, std::vector<void*> *promoted_objects) {
    if (ptr.constant != 0)
        return; // It's a constant

    void *obj = fromPointer(ptr);
    if (!obj)
        return;

    // First priority: Check if this location has a forward pointer
    // This must happen BEFORE the from-space check so that pointers from
    // old-gen objects can be updated even when pointing to from-space
    Header *hdr = getHeader(obj);
    if (hdr->tag == Tag_Forward) {
        // Follow forward pointer and update ptr
        Forward *fwd = static_cast<Forward *>(obj);
        char *heap_base = GarbageCollector::instance().getHeapBase();
        uintptr_t byte_offset = static_cast<uintptr_t>(fwd->pointer) << 3;
        ptr = toPointer(heap_base + byte_offset);
        return;
    }

    // Second priority: Only evacuate if in from-space (not to-space!)
    // This prevents creating forwarding chains by re-evacuating already-moved objects
    char *p = static_cast<char *>(obj);
    if (p < from_space || p >= from_space + (NURSERY_SIZE / 2))
        return;

    // Now proceed with evacuation (object is in from-space and not yet forwarded)

    size_t size = getObjectSize(obj);
    void *new_obj = nullptr;

    bool promoted = false;

    // Promote to old gen if age >= PROMOTION_AGE
    if (hdr->age >= PROMOTION_AGE) {
        // Try TLAB allocation first (fast path, no lock!)
        if (promotion_tlab && size <= OldGenSpace::TLAB_DEFAULT_SIZE) {
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
            if (!promotion_tlab && size <= OldGenSpace::TLAB_DEFAULT_SIZE) {
                promotion_tlab = oldgen.allocateTLAB(OldGenSpace::TLAB_DEFAULT_SIZE);
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
            // Save color set by oldgen.allocate before memcpy overwrites it
            Header *new_hdr = getHeader(new_obj);
            u32 saved_color = new_hdr->color;

            std::memcpy(new_obj, obj, size);

            // Restore old-gen color and reset age
            new_hdr = getHeader(new_obj);
            new_hdr->color = saved_color;
            new_hdr->age = 0;
            promoted = true;

            // Add to promoted objects buffer for later scanning
            if (promoted_objects) {
                promoted_objects->push_back(new_obj);
            }

            GC_STATS_INC_PROMOTED(stats);
        }
    }

    // Copy to to_space if not promoted
    if (!new_obj) {
        // Allocate in to_space (size is already aligned from getObjectSize)
        new_obj = alloc_ptr;
        alloc_ptr += size;

        // Copy the object (size includes padding, but that's fine)
        std::memcpy(new_obj, obj, size);

        // Update age after copying (preserves all other fields)
        Header *new_hdr = getHeader(new_obj);
        new_hdr->age++; // Increment age

        GC_STATS_INC_SURVIVORS(stats);
    }

    // Leave forwarding pointer (as logical offset)
    // IMPORTANT: Set this BEFORE evacuating children to prevent infinite recursion
    Forward *fwd = static_cast<Forward *>(obj);
    fwd->header.tag = Tag_Forward;
    char *heap_base = GarbageCollector::instance().getHeapBase();
    uintptr_t byte_offset = static_cast<char *>(new_obj) - heap_base;
    fwd->pointer = byte_offset >> 3; // Store as offset in 8-byte units

    ptr = toPointer(new_obj);
}

void NurserySpace::evacuateUnboxable(Unboxable &val, bool is_boxed, OldGenSpace &oldgen, std::vector<void*> *promoted_objects) {
    if (is_boxed) {
        evacuate(val.p, oldgen, promoted_objects);
    }
}

void NurserySpace::scanObject(void *obj, OldGenSpace &oldgen, std::vector<void*> *promoted_objects) {
    Header *hdr = getHeader(obj);

    // Process children based on tag
    switch (hdr->tag) {
        case Tag_Tuple2: {
            Tuple2 *t = static_cast<Tuple2 *>(obj);
            evacuateUnboxable(t->a, !(hdr->unboxed & 1), oldgen, promoted_objects);
            evacuateUnboxable(t->b, !(hdr->unboxed & 2), oldgen, promoted_objects);
            break;
        }
        case Tag_Tuple3: {
            Tuple3 *t = static_cast<Tuple3 *>(obj);
            evacuateUnboxable(t->a, !(hdr->unboxed & 1), oldgen, promoted_objects);
            evacuateUnboxable(t->b, !(hdr->unboxed & 2), oldgen, promoted_objects);
            evacuateUnboxable(t->c, !(hdr->unboxed & 4), oldgen, promoted_objects);
            break;
        }
        case Tag_Cons: {
            Cons *c = static_cast<Cons *>(obj);
            evacuateUnboxable(c->head, !(hdr->unboxed & 1), oldgen, promoted_objects);
            evacuate(c->tail, oldgen, promoted_objects);
            break;
        }
        case Tag_Custom: {
            Custom *c = static_cast<Custom *>(obj);
            for (u32 i = 0; i < hdr->size && i < 48; i++) {
                evacuateUnboxable(c->values[i], !(c->unboxed & (1ULL << i)), oldgen, promoted_objects);
            }
            break;
        }
        case Tag_Record: {
            Record *r = static_cast<Record *>(obj);
            for (u32 i = 0; i < hdr->size && i < 64; i++) {
                evacuateUnboxable(r->values[i], !(r->unboxed & (1ULL << i)), oldgen, promoted_objects);
            }
            break;
        }
        case Tag_DynRecord: {
            DynRecord *dr = static_cast<DynRecord *>(obj);
            evacuate(dr->fieldgroup, oldgen, promoted_objects);
            for (u32 i = 0; i < hdr->size; i++) {
                evacuate(dr->values[i], oldgen, promoted_objects);
            }
            break;
        }
        case Tag_Closure: {
            Closure *cl = static_cast<Closure *>(obj);
            for (u32 i = 0; i < cl->n_values; i++) {
                evacuateUnboxable(cl->values[i], !(cl->unboxed & (1ULL << i)), oldgen, promoted_objects);
            }
            break;
        }
        case Tag_Process: {
            Process *p = static_cast<Process *>(obj);
            evacuate(p->root, oldgen, promoted_objects);
            evacuate(p->stack, oldgen, promoted_objects);
            evacuate(p->mailbox, oldgen, promoted_objects);
            break;
        }
        case Tag_Task: {
            Task *t = static_cast<Task *>(obj);
            evacuate(t->value, oldgen, promoted_objects);
            evacuate(t->callback, oldgen, promoted_objects);
            evacuate(t->kill, oldgen, promoted_objects);
            evacuate(t->task, oldgen, promoted_objects);
            break;
        }
        default:
            break;
    }
}

// ============================================================================
// OldGenSpace Implementation
// ============================================================================

OldGenSpace::OldGenSpace() :
    region_base(nullptr), region_size(0), max_region_size(0), free_list(nullptr), current_epoch(0),
    marking_active(false) {
    // Initialization happens in initialize() method
}

OldGenSpace::~OldGenSpace() {
    // No need to free memory - it's part of the main heap
}

void OldGenSpace::initialize(char *base, size_t initial_size, size_t max_size) {
    region_base = base;
    region_size = initial_size;
    max_region_size = max_size;

    // Partition memory: 50% for free-list, 50% for TLABs
    size_t free_list_size = max_size / 2;
    size_t tlab_region_size = max_size - free_list_size;

    // Set up TLAB region boundaries
    tlab_region_start = base + free_list_size;
    tlab_region_end = base + max_size;

    // Initialize free-list with initial committed memory
    // (TLAB region memory is committed on-demand)
    size_t initial_free_list_size = std::min(initial_size, free_list_size);
    FreeBlock *block = reinterpret_cast<FreeBlock *>(region_base);
    block->size = initial_free_list_size;
    block->next = nullptr;
    free_list = block;

    // Initialize TLAB atomic bump pointer to start of TLAB region
    tlab_bump_ptr.store(tlab_region_start, std::memory_order_relaxed);

    // Track the region as our first "chunk"
    chunks.push_back(region_base);
}

/**
 * Add a new memory chunk to the old generation space.
 * REQUIRES: Caller must hold alloc_mutex (modifies free_list and region_size)
 */
void OldGenSpace::addChunk(size_t size) {
    // Check if we can grow
    if (region_size >= max_region_size) {
        throw std::bad_alloc(); // Can't grow beyond max
    }

    // Calculate how much to grow (at least requested size, up to max)
    size_t growth = std::min(size * 2, max_region_size - region_size);
    growth = std::max(growth, size);

    // Commit more memory
    char *new_region = region_base + region_size;
    void *result = mmap(new_region, growth, PROT_READ | PROT_WRITE, MAP_PRIVATE | MAP_ANONYMOUS | MAP_FIXED, -1, 0);

    if (result == MAP_FAILED) {
        throw std::bad_alloc();
    }

    // Add new region to free list
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
    size = (size + 7) & ~7; // Align
    size = std::max(size, sizeof(FreeBlock)); // Minimum size

    // NOTE: Caller must hold alloc_mutex

    FreeBlock **prev_ptr = &free_list;
    FreeBlock *curr = free_list;

    // First-fit allocation
    while (curr) {
        if (curr->size >= size) {
            // Split block if large enough
            if (curr->size >= size + sizeof(FreeBlock) + 64) {
                FreeBlock *remainder = reinterpret_cast<FreeBlock *>(reinterpret_cast<char *>(curr) + size);
                remainder->size = curr->size - size;
                remainder->next = curr->next;
                *prev_ptr = remainder;
            } else {
                // Use entire block
                *prev_ptr = curr->next;
                size = curr->size;
            }

            // Initialize header
            Header *hdr = reinterpret_cast<Header *>(curr);
            std::memset(hdr, 0, sizeof(Header));

            // Bug - if marking is in progres the object should be conservatively marked Black.
            hdr->color = static_cast<u32>(Color::White);

            return curr;
        }

        prev_ptr = &curr->next;
        curr = curr->next;
    }

    // No suitable block, allocate new chunk
    size_t chunk_size = std::max(size * 2, (long unsigned int) 1024 * 1024);
    addChunk(chunk_size);

    // Try again (recursive call to internal version, lock already held)
    return allocate_internal(size);
}

bool OldGenSpace::contains(void *ptr) const {
    char *p = static_cast<char *>(ptr);
    return (p >= region_base && p < region_base + region_size);
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
            // TLAB region exhausted - fall back to free-list
            return nullptr;
        }

        // Try to atomically update bump pointer
        // If successful: we claimed [current, new_ptr)
        // If failed: another thread claimed it, 'current' is updated, retry
    } while (!tlab_bump_ptr.compare_exchange_weak(
        current,                    // Expected value (updated on failure)
        new_ptr,                    // New value if successful
        std::memory_order_release,  // Success ordering (make writes visible)
        std::memory_order_relaxed   // Failure ordering (just retry)
    ));

    // Success! We claimed [current, new_ptr)
    // Check if we need to commit more memory
    char* committed_end = region_base + region_size;
    if (new_ptr > committed_end) {
        // Need to commit more memory
        size_t needed = new_ptr - committed_end;
        void* result = mmap(committed_end, needed,
                           PROT_READ | PROT_WRITE,
                           MAP_PRIVATE | MAP_ANONYMOUS | MAP_FIXED,
                           -1, 0);

        if (result == MAP_FAILED) {
            // Failed to commit - return nullptr and let caller fall back to free-list
            return nullptr;
        }

        // Update region_size
        // This is benign even if racy - worst case is we commit slightly more than needed
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
 * Start a concurrent marking phase.
 * This is a public method that handles its own locking.
 */
void OldGenSpace::startConcurrentMark(RootSet &roots) {
    std::lock_guard<std::recursive_mutex> lock(mark_mutex);

    if (marking_active)
        return;

    marking_active = true;
    current_epoch++;
    mark_stack.clear();

    // Push roots onto mark stack
    for (HPointer *root: roots.getRoots()) {
        void *obj = fromPointer(*root);
        if (obj && contains(obj)) {
            mark_stack.push_back(obj);
        }
    }
}

/**
 * Perform incremental marking work.
 * This is a public method that handles its own locking.
 * Returns true if more work remains, false if marking is complete.
 */
bool OldGenSpace::incrementalMark(size_t work_units) {
    std::lock_guard<std::recursive_mutex> lock(mark_mutex);

    if (!marking_active || mark_stack.empty()) {
        return false; // No work to do
    }

    size_t units_done = 0;

    while (!mark_stack.empty() && units_done < work_units) {
        void *obj = mark_stack.back();
        mark_stack.pop_back();

        Header *hdr = getHeader(obj);

        // Skip if already black
        if (hdr->color == static_cast<u32>(Color::Black)) {
            continue;
        }

        // Mark grey first
        hdr->color = static_cast<u32>(Color::Grey);

        // Process children
        markChildren(obj);

        // Mark black
        hdr->color = static_cast<u32>(Color::Black);
        hdr->epoch = current_epoch & 3;

        units_done++;
    }

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

    void *obj = fromPointer(ptr);
    if (obj && contains(obj)) {
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
void OldGenSpace::finishMarkAndSweep() {
    // Complete any remaining marking
    while (incrementalMark(1000)) {
        // Keep marking
    }

    sweep();

    marking_active = false;
}

/**
 * Sweep phase - reclaim unmarked (white) objects.
 * This is a private method but handles its own locking (alloc_mutex).
 * Called by finishMarkAndSweep() which doesn't hold any locks.
 */
void OldGenSpace::sweep() {
    std::lock_guard<std::recursive_mutex> lock(alloc_mutex);

    // Rebuild free list from white (unmarked) objects
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
    // Part 2: Sweep free-list region
    // ========================================================================

    // Only sweep up to where TLAB region starts
    char *ptr = region_base;
    char *end = std::min(tlab_region_start, region_base + region_size);

    while (ptr < end) {
        Header *hdr = reinterpret_cast<Header *>(ptr);

        // Check if this is a valid object
        if (hdr->tag >= Tag_Forward) {
            ptr += sizeof(Header);
            continue;
        }

        // Use getObjectSize() to correctly calculate size for all object types
        size_t obj_size = getObjectSize(ptr);

        if (hdr->color == static_cast<u32>(Color::White)) {
            // Add to free list
            FreeBlock *block = reinterpret_cast<FreeBlock *>(ptr);
            block->size = obj_size;
            block->next = new_free_list;
            new_free_list = block;
        } else {
            // Reset color to white for next cycle
            hdr->color = static_cast<u32>(Color::White);
        }

        ptr += obj_size;
    }

    free_list = new_free_list;
}

// ============================================================================
// RootSet Implementation
// ============================================================================

void RootSet::addRoot(HPointer *root) {
    std::lock_guard<std::mutex> lock(mutex);
    roots.push_back(root);
}

void RootSet::removeRoot(HPointer *root) {
    std::lock_guard<std::mutex> lock(mutex);
    roots.erase(std::remove(roots.begin(), roots.end(), root), roots.end());
}

void RootSet::addStackRoot(void *stack_ptr, size_t size) {
    std::lock_guard<std::mutex> lock(mutex);
    stack_roots.push_back({stack_ptr, size});
}

void RootSet::clearStackRoots() {
    std::lock_guard<std::mutex> lock(mutex);
    stack_roots.clear();
}

// ============================================================================
// GarbageCollector Implementation
// ============================================================================

GarbageCollector::GarbageCollector() :
    heap_base(nullptr), heap_reserved(0), old_gen_committed(0), nursery_offset(0), next_nursery_offset(0),
    initialized(false) {
    // Initialization happens in initialize() method
}

GarbageCollector::~GarbageCollector() {
    if (heap_base) {
        munmap(heap_base, heap_reserved);
    }
}

void GarbageCollector::initialize(size_t max_heap_size) {
    if (initialized)
        return;

    heap_reserved = max_heap_size;

    // Reserve address space without committing physical memory
    heap_base = static_cast<char *>(mmap(nullptr, heap_reserved,
                                         PROT_NONE, // No access initially
                                         MAP_PRIVATE | MAP_ANONYMOUS | MAP_NORESERVE, -1, 0));

    if (heap_base == MAP_FAILED) {
        throw std::bad_alloc();
    }

    // Nurseries start at halfway point
    nursery_offset = heap_reserved / 2;
    next_nursery_offset = nursery_offset;

    // Old gen starts at offset 0, can grow up to halfway point
    // Commit initial 1MB for old gen
    size_t initial_old_gen = 1 * 1024 * 1024; // 1MB
    size_t max_old_gen = nursery_offset; // Can grow to halfway point
    growOldGen(initial_old_gen);
    old_gen.initialize(heap_base, old_gen_committed, max_old_gen);

    initialized = true;
}

void GarbageCollector::growOldGen(size_t additional_size) {
    // Commit more memory for old gen
    char *new_region = heap_base + old_gen_committed;

    void *result =
        mmap(new_region, additional_size, PROT_READ | PROT_WRITE, MAP_PRIVATE | MAP_ANONYMOUS | MAP_FIXED, -1, 0);

    if (result == MAP_FAILED) {
        throw std::bad_alloc();
    }

    old_gen_committed += additional_size;
}

void GarbageCollector::commitNursery(char *nursery_base, size_t size) {
    // Commit memory for a nursery
    void *result = mmap(nursery_base, size, PROT_READ | PROT_WRITE, MAP_PRIVATE | MAP_ANONYMOUS | MAP_FIXED, -1, 0);

    if (result == MAP_FAILED) {
        throw std::bad_alloc();
    }
}

GarbageCollector &GarbageCollector::instance() {
    static GarbageCollector gc;
    return gc;
}

void GarbageCollector::initThread() {
    // Ensure GC is initialized
    if (!initialized) {
        initialize();
    }

    std::lock_guard<std::mutex> lock(nursery_mutex);
    auto tid = std::this_thread::get_id();
    if (nurseries.find(tid) == nurseries.end()) {
        // Allocate nursery from the main heap
        char *nursery_base = heap_base + next_nursery_offset;

        // Check we have space in reserved address space
        if (next_nursery_offset + NURSERY_SIZE > heap_reserved) {
            throw std::bad_alloc(); // Out of heap space
        }

        // Commit physical memory for this nursery
        commitNursery(nursery_base, NURSERY_SIZE);

        auto nursery = std::make_unique<NurserySpace>();
        nursery->initialize(nursery_base, NURSERY_SIZE);
        nurseries[tid] = std::move(nursery);

        next_nursery_offset += NURSERY_SIZE;
    }
}

NurserySpace *GarbageCollector::getNursery() {
    auto tid = std::this_thread::get_id();
    std::lock_guard<std::mutex> lock(nursery_mutex);
    auto it = nurseries.find(tid);
    if (it != nurseries.end()) {
        return it->second.get();
    }
    return nullptr;
}

void *GarbageCollector::allocate(size_t size, Tag tag) {
    NurserySpace *nursery = getNursery();

    if (nursery) {
        void *obj = nursery->allocate(size);
        if (obj) {
            Header *hdr = getHeader(obj);
            std::memset(hdr, 0, sizeof(Header));
            hdr->tag = tag;
            // For variable-sized types, hdr->size stores the element count
            // For fixed-size types, it's unused (but set to total size for consistency)
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

        // Nursery full, trigger minor GC
        minorGC();

        // Try again
        obj = nursery->allocate(size);
        if (obj) {
            Header *hdr = getHeader(obj);
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
                    hdr->size = size;
                    break;
            }
            return obj;
        }
    }

    // Allocate in old gen
    void *obj = old_gen.allocate(size);
    if (obj) {
        Header *hdr = getHeader(obj);
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
                hdr->size = size;
                break;
        }
    }
    return obj;
}

void GarbageCollector::minorGC() {
    NurserySpace *nursery = getNursery();
    if (nursery) {
        nursery->minorGC(root_set, old_gen);
    }
}

void GarbageCollector::majorGC() {
    old_gen.startConcurrentMark(root_set);
    old_gen.finishMarkAndSweep();
}

} // namespace Elm