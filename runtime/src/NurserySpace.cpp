/**
 * NurserySpace Implementation.
 *
 * Thread-local nursery using Cheney's semi-space copying algorithm.
 *
 * Allocation: Bump pointer into from_space (O(1), no locking).
 *
 * Minor GC algorithm:
 *   1. Evacuate roots to to_space (or promote to old gen if aged).
 *   2. Cheney scan: walk to_space objects, evacuate their children.
 *   3. Process promoted objects (they may point back to nursery).
 *   4. Swap from_space and to_space.
 *
 * Key optimization: Elm's immutability means no old->young pointers exist,
 * so no write barrier or remembered set is needed.
 */

#include "NurserySpace.hpp"
#include "GarbageCollector.hpp"
#include <cassert>
#include <cstring>

namespace Elm {

NurserySpace::NurserySpace() :
    memory(nullptr), from_space(nullptr), to_space(nullptr), alloc_ptr(nullptr), scan_ptr(nullptr),
    promotion_tlab(nullptr) {
    // Initialization happens in initialize() method.
}

NurserySpace::~NurserySpace() {
    // Seal any active TLAB before destroying nursery.
    if (promotion_tlab) {
        GarbageCollector::instance().getOldGen().sealTLAB(promotion_tlab);
#if ENABLE_GC_STATS
        GC_STATS_TLAB_SEALED(stats);
#endif
        promotion_tlab = nullptr;
    }
    // No need to free memory - it's part of the main heap.
}

void NurserySpace::initialize(char *nursery_base, size_t size) {
    memory = nursery_base;
    from_space = memory;
    to_space = memory + (size / 2);
    alloc_ptr = from_space;
    scan_ptr = from_space;
}

void NurserySpace::reset(OldGenSpace &oldgen) {
    // Seal any active promotion TLAB.
    if (promotion_tlab) {
        oldgen.sealTLAB(promotion_tlab);
        promotion_tlab = nullptr;
    }

    // Reset allocation pointers to start of from_space.
    from_space = memory;
    to_space = memory + (NURSERY_SIZE / 2);
    alloc_ptr = from_space;
    scan_ptr = from_space;

    // Reset the thread-local root set.
    root_set.reset();

    // Note: We do NOT reset GC stats here - stats accumulate across runs.
}

void *NurserySpace::allocate(size_t size) {
    // Align to 8 bytes.
    size = (size + 7) & ~7;

    if (alloc_ptr + size > from_space + (NURSERY_SIZE / 2)) {
        return nullptr;  // Nursery full, trigger GC.
    }

    void *result = alloc_ptr;
    alloc_ptr += size;

    GC_STATS_MINOR_RECORD_ALLOC(stats, size);

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
 * to space, evacuating any object that it finds a pointer to. If more objects are evacuated into the to space,
 * this will bump up the allocation pointer and those objects will be created ahead of the scan pointer so will
 * also eventually be scanned. When the scan pointer catches up to the allocation pointer, there are no more live
 * objects left to consider.
 *
 * The from and to spaces are flipped over in their roles once all live objects have been removed.
 *
 * There is no "remembered set" of pointers from the old generation into the nursery to consider, since Elm
 * only creates acyclic structures on the heap and immutability means that younger object only point to older
 * ones and never the other way around. Therefore objects moved into the old generation during evacuation do
 * not need to be scanned by Cheney's algorithm.
 */
void NurserySpace::minorGC(OldGenSpace &oldgen) {
#if ENABLE_GC_STATS
    // Capture state before GC.
    size_t from_space_used = alloc_ptr - from_space;
    auto gc_start = GC_STATS_TIMER_START();
#endif

    // Reset allocation into the to_space.
    alloc_ptr = to_space;
    scan_ptr = to_space;
    char *alloc_end = to_space;

    // Buffer for promoted objects that need scanning.
    std::vector<void*> promoted_objects;

    // Phase 1a: Evacuate long-lived roots (may add to promoted_objects).
    for (HPointer *root: root_set.getRoots()) {
        evacuate(*root, oldgen, &promoted_objects);
    }

    // Phase 1b: Evacuate stack roots (temporary roots from current call stack).
    for (HPointer *root: root_set.getStackRoots()) {
        evacuate(*root, oldgen, &promoted_objects);
    }

    // Phase 2: Cheney's algorithm on to-space (may add to promoted_objects).
    alloc_end = alloc_ptr;
    while (scan_ptr < alloc_end) {
        void *obj = scan_ptr;
        scanObject(obj, oldgen, &promoted_objects);
        scan_ptr += getObjectSize(obj);
        alloc_end = alloc_ptr;  // Update in case scanObject caused evacuations.
    }

    // Phase 3: Process promoted objects until buffer is empty.
    // Use index-based loop since vector may grow during iteration.
    for (size_t i = 0; i < promoted_objects.size(); i++) {
        scanObject(promoted_objects[i], oldgen, &promoted_objects);
    }

    // Phase 4: Flip spaces.
    std::swap(from_space, to_space);
    // After swap: from_space = old to_space (has live objects).
    //             to_space = old from_space (empty).
    //             alloc_ptr already points to end of live objects in new from_space.
    scan_ptr = from_space;

#if ENABLE_GC_STATS
    // Calculate what happened during this GC.
    size_t to_space_used = alloc_ptr - from_space;
    size_t bytes_freed = from_space_used - to_space_used;
    uint64_t elapsed_ns = GC_STATS_TIMER_ELAPSED_NS(gc_start);

    GC_STATS_MINOR_RECORD_GC_END(stats, elapsed_ns, bytes_freed);
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
        return;  // It's a constant.

    void *obj = GarbageCollector::fromPointerRaw(ptr);
    if (!obj)
        return;

    // Assert pointer is within valid heap memory.
    char *heap_base = GarbageCollector::instance().getHeapBase();
    char *heap_end = heap_base + GarbageCollector::instance().getHeapReserved();
    assert(static_cast<char*>(obj) >= heap_base && "Pointer below heap base!");
    assert(static_cast<char*>(obj) < heap_end && "Pointer above heap end!");

    // First priority: Check if this location has a forward pointer.
    // This must happen BEFORE the from-space check so that pointers from
    // old-gen objects can be updated even when pointing to from-space.
    Header *hdr = getHeader(obj);

    // Assert tag is valid.
    assert(hdr->tag <= Tag_Forward && "Invalid tag value!");
    if (hdr->tag == Tag_Forward) {
        // Follow forward pointer and update ptr.
        Forward *fwd = static_cast<Forward *>(obj);
        uintptr_t byte_offset = static_cast<uintptr_t>(fwd->header.forward_ptr) << 3;
        ptr = GarbageCollector::toPointerRaw(heap_base + byte_offset);
        return;
    }

    // Second priority: Only evacuate if in from-space (not to-space!).
    // This prevents creating forwarding chains by re-evacuating already-moved objects.
    char *p = static_cast<char *>(obj);
    if (p < from_space || p >= from_space + (NURSERY_SIZE / 2))
        return;

    // Now proceed with evacuation (object is in from-space and not yet forwarded).

    size_t size = getObjectSize(obj);
    void *new_obj = nullptr;

    bool promoted = false;

    // Promote to old gen if age >= PROMOTION_AGE.
    if (hdr->age >= PROMOTION_AGE) {
        // Try TLAB allocation first (fast path, no lock).
        if (promotion_tlab && size <= TLAB_DEFAULT_SIZE) {
            new_obj = promotion_tlab->allocate(size);
        }

        // TLAB exhausted or doesn't exist.
        if (!new_obj) {
            // Check if current TLAB is exhausted.
            if (promotion_tlab && promotion_tlab->bytesRemaining() < size) {
                // Seal exhausted TLAB.
                oldgen.sealTLAB(promotion_tlab);
                GC_STATS_TLAB_SEALED(stats);
                promotion_tlab = nullptr;
            }

            // Try to get a new TLAB (lock-free CAS).
            if (!promotion_tlab && size <= TLAB_DEFAULT_SIZE) {
                promotion_tlab = oldgen.allocateTLAB(TLAB_DEFAULT_SIZE);
                if (promotion_tlab) {
                    GC_STATS_TLAB_ALLOCATED(stats);
                    new_obj = promotion_tlab->allocate(size);
                }
            }
        }

        if (new_obj) {
            // Save color set by oldgen.allocate before memcpy overwrites it.
            Header *new_hdr = getHeader(new_obj);
            u32 saved_color = new_hdr->color;

            std::memcpy(new_obj, obj, size);

            // Restore old-gen color and reset age.
            new_hdr = getHeader(new_obj);
            new_hdr->color = saved_color;
            new_hdr->age = 0;
            promoted = true;

            // Add to promoted objects buffer for later scanning.
            if (promoted_objects) {
                promoted_objects->push_back(new_obj);
            }

            GC_STATS_MINOR_INC_PROMOTED(stats);
        }
    }

    // Copy to to_space if not promoted.
    if (!new_obj) {
        // Allocate in to_space (size is already aligned from getObjectSize).
        new_obj = alloc_ptr;
        alloc_ptr += size;

        // Assert we haven't overflowed to_space.
        assert(alloc_ptr <= to_space + (NURSERY_SIZE / 2) && "To-space overflow during evacuation!");

        // Copy the object (size includes padding, but that's fine).
        std::memcpy(new_obj, obj, size);

        // Update age after copying (preserves all other fields).
        Header *new_hdr = getHeader(new_obj);
        new_hdr->age++;  // Increment age.

        GC_STATS_MINOR_INC_SURVIVORS(stats);
    }

    // Leave forwarding pointer (as logical offset).
    // IMPORTANT: Set this BEFORE evacuating children to prevent infinite recursion.
    Forward *fwd = static_cast<Forward *>(obj);
    fwd->header.tag = Tag_Forward;
    uintptr_t byte_offset = static_cast<char *>(new_obj) - heap_base;
    fwd->header.forward_ptr = byte_offset >> 3;  // Store as offset in 8-byte units.
    fwd->header.unused = 0;

    ptr = GarbageCollector::toPointerRaw(new_obj);
}

void NurserySpace::evacuateUnboxable(Unboxable &val, bool is_boxed, OldGenSpace &oldgen, std::vector<void*> *promoted_objects) {
    if (is_boxed) {
        evacuate(val.p, oldgen, promoted_objects);
    }
}

void NurserySpace::scanObject(void *obj, OldGenSpace &oldgen, std::vector<void*> *promoted_objects) {
    Header *hdr = getHeader(obj);

    // Process children based on tag.
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

} // namespace Elm
