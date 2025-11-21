#include "OldGenSpace.hpp"
#include <algorithm>
#include <cstring>
#include <new>
#include <sys/mman.h>

namespace Elm {

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

} // namespace Elm
