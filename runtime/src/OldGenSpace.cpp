/**
 * OldGenSpace Implementation.
 *
 * Implements the old generation for long-lived objects using:
 *   - AllocBuffer-based bump-pointer allocation.
 *   - Tri-color mark-and-sweep collection.
 *
 * Each AllocBuffer is a contiguous region of memory obtained from the
 * Allocator. Objects are allocated by bumping a pointer within the
 * current buffer. When a buffer is exhausted, a new one is acquired.
 *
 * Single-threaded version.
 */

#include "OldGenSpace.hpp"
#include "Allocator.hpp"
#include <algorithm>
#include <cassert>
#include <cstring>

namespace Elm {

// Global heap base (defined in Allocator.cpp).
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
    config_(nullptr), allocator_(nullptr),
    current_buffer_(nullptr), allocated_bytes(0),
    current_epoch(0), marking_active(false), allocator_ref_(nullptr) {
    // Initialization happens in initialize() method.
}

OldGenSpace::~OldGenSpace() {
    // Delete all AllocBuffers.
    for (AllocBuffer* buffer : buffers_) {
        delete buffer;
    }
    buffers_.clear();
    current_buffer_ = nullptr;
}

void OldGenSpace::initialize(Allocator* allocator, const HeapConfig* config) {
    config_ = config;
    allocator_ = allocator;
    current_buffer_ = nullptr;
    allocated_bytes = 0;
}

void OldGenSpace::reset(const HeapConfig* new_config) {
    // Update config if provided.
    if (new_config) {
        config_ = new_config;
    }

    // Delete all AllocBuffers.
    for (AllocBuffer* buffer : buffers_) {
        delete buffer;
    }
    buffers_.clear();
    current_buffer_ = nullptr;

    // Reset state.
    allocated_bytes = 0;
    marking_active = false;
    current_epoch = 0;
    mark_stack.clear();
}

/**
 * Allocate memory in the old generation space using bump-pointer allocation.
 */
void *OldGenSpace::allocate(size_t size) {
    size = (size + 7) & ~7;  // Align to 8 bytes.

    // Try current buffer first.
    if (current_buffer_) {
        void* result = current_buffer_->allocate(size);
        if (result) {
            allocated_bytes += size;

            // Initialize header with white color for GC.
            Header* hdr = reinterpret_cast<Header*>(result);
            std::memset(hdr, 0, sizeof(Header));
            hdr->color = static_cast<u32>(Color::White);

            return result;
        }
    }

    // Current buffer exhausted or doesn't exist - acquire new one.
    assert(allocator_ && "OldGenSpace not initialized with Allocator");
    assert(size <= config_->alloc_buffer_size && "Object too large for AllocBuffer");

    current_buffer_ = allocator_->acquireAllocBuffer(config_->alloc_buffer_size);
    assert(current_buffer_ && "Failed to acquire AllocBuffer");

    buffers_.push_back(current_buffer_);

    void* result = current_buffer_->allocate(size);
    assert(result && "Failed to allocate from fresh AllocBuffer");

    allocated_bytes += size;

    // Initialize header with white color for GC.
    Header* hdr = reinterpret_cast<Header*>(result);
    std::memset(hdr, 0, sizeof(Header));
    hdr->color = static_cast<u32>(Color::White);

    return result;
}

/**
 * Start a marking phase.
 * Takes collected roots and Allocator reference for nursery checks.
 */
#if ENABLE_GC_STATS
void OldGenSpace::startMark(const std::vector<HPointer*> &roots, Allocator &alloc, GCStats &stats) {
#else
void OldGenSpace::startMark(const std::vector<HPointer*> &roots, Allocator &alloc) {
#endif
    if (marking_active)
        return;

    marking_active = true;
    current_epoch++;
    mark_stack.clear();

    // Store Allocator reference for nursery checks during marking.
    allocator_ref_ = &alloc;

    // Push ALL roots onto mark stack - including nursery objects.
    // Nursery objects will be marked (grey->black) like old gen objects.
    // This is harmless since minor GC uses forwarding pointers, not colors.
    for (HPointer *root: roots) {
        void *obj = Allocator::fromPointerRaw(*root);
        if (obj && (alloc.isInOldGen(obj) || alloc.isInNursery(obj))) {
            mark_stack.push_back(obj);
        }
    }

#if ENABLE_GC_STATS
    GC_STATS_MAJOR_INC_CONCURRENT_MARK(stats);
#endif
}

/**
 * Perform incremental marking work.
 * Returns true if more work remains, false if marking is complete.
 */
#if ENABLE_GC_STATS
bool OldGenSpace::incrementalMark(size_t work_units, GCStats &stats) {
#else
bool OldGenSpace::incrementalMark(size_t work_units) {
#endif
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

    void *obj = Allocator::fromPointerRaw(ptr);
    if (!obj)
        return;

    // Push both old gen and nursery objects onto mark stack.
    // Nursery objects will be marked grey->black like old gen objects.
    // This is harmless since minor GC uses forwarding pointers, not colors.
    if (allocator_ref_ && (allocator_ref_->isInOldGen(obj) || allocator_ref_->isInNursery(obj))) {
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
 * Sweep phase - reset colors of live objects.
 *
 * Note: In this simplified implementation, we don't actually reclaim
 * memory from dead objects within AllocBuffers. The buffers remain
 * allocated. Future work could return empty buffers to the Allocator.
 */
void OldGenSpace::sweep() {
    // Walk all buffers and reset colors of live objects.
    for (AllocBuffer* buffer : buffers_) {
        char* ptr = buffer->start;
        char* used_end = buffer->alloc_ptr;

        while (ptr < used_end) {
            Header* hdr = reinterpret_cast<Header*>(ptr);
            size_t obj_size = getObjectSize(ptr);

            // Reset color to white for next GC cycle.
            // Dead objects (still white) are not reclaimed in this version.
            if (hdr->color == static_cast<u32>(Color::Black)) {
                hdr->color = static_cast<u32>(Color::White);
            }
            // Objects that are still white are garbage, but we don't
            // reclaim them in this simplified implementation.

            ptr += obj_size;
        }
    }
}

} // namespace Elm
