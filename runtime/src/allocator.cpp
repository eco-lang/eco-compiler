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
        memory(nullptr), from_space(nullptr), to_space(nullptr), alloc_ptr(nullptr), scan_ptr(nullptr) {
        // Initialization happens in initialize() method
    }

    NurserySpace::~NurserySpace() {
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
        return result;
    }

    bool NurserySpace::contains(void *ptr) const {
        char *p = static_cast<char *>(ptr);
        return (p >= memory && p < memory + NURSERY_SIZE);
    }

    void NurserySpace::minorGC(RootSet &roots, OldGenSpace &oldgen) {
        // Reset to_space allocation
        alloc_ptr = to_space; // CRITICAL: Reset alloc_ptr to start of to_space
        scan_ptr = to_space;
        char *alloc_end = to_space;

        // Evacuate roots
        for (HPointer *root: roots.getRoots()) {
            evacuate(*root, oldgen);
        }

        // Process stack roots (conservative scanning)
        for (auto &[stack_ptr, size]: roots.getStackRoots()) {
            HPointer *ptrs = static_cast<HPointer *>(stack_ptr);
            size_t count = size / sizeof(HPointer);
            for (size_t i = 0; i < count; i++) {
                evacuate(ptrs[i], oldgen);
            }
        }

        // No remembered set needed! Elm's immutable, acyclic heap means
        // old generation objects can never point to young generation objects
        // due to time stratification (objects only point backwards in time)

        // Cheney's algorithm: scan copied objects
        // Update alloc_end to reflect objects copied during root evacuation
        alloc_end = alloc_ptr;

        while (scan_ptr < alloc_end) {
            void *obj = scan_ptr;
            Header *hdr = getHeader(obj);

            // Process children based on tag
            switch (hdr->tag) {
                case Tag_Tuple2: {
                    Tuple2 *t = static_cast<Tuple2 *>(obj);
                    evacuateUnboxable(t->a, !(hdr->unboxed & 1), oldgen);
                    evacuateUnboxable(t->b, !(hdr->unboxed & 2), oldgen);
                    break;
                }
                case Tag_Tuple3: {
                    Tuple3 *t = static_cast<Tuple3 *>(obj);
                    evacuateUnboxable(t->a, !(hdr->unboxed & 1), oldgen);
                    evacuateUnboxable(t->b, !(hdr->unboxed & 2), oldgen);
                    evacuateUnboxable(t->c, !(hdr->unboxed & 4), oldgen);
                    break;
                }
                case Tag_Cons: {
                    Cons *c = static_cast<Cons *>(obj);
                    evacuateUnboxable(c->head, !(hdr->unboxed & 1), oldgen);
                    evacuate(c->tail, oldgen);
                    break;
                }
                case Tag_Custom: {
                    Custom *c = static_cast<Custom *>(obj);
                    for (u32 i = 0; i < hdr->size; i++) {
                        evacuateUnboxable(c->values[i], !(c->unboxed & (1ULL << i)), oldgen);
                    }
                    break;
                }
                case Tag_Record: {
                    Record *r = static_cast<Record *>(obj);
                    for (u32 i = 0; i < hdr->size; i++) {
                        evacuateUnboxable(r->values[i], !(r->unboxed & (1ULL << i)), oldgen);
                    }
                    break;
                }
                case Tag_DynRecord: {
                    DynRecord *dr = static_cast<DynRecord *>(obj);
                    evacuate(dr->fieldgroup, oldgen);
                    for (u32 i = 0; i < hdr->size; i++) {
                        evacuate(dr->values[i], oldgen);
                    }
                    break;
                }
                case Tag_Closure: {
                    Closure *cl = static_cast<Closure *>(obj);
                    for (u32 i = 0; i < cl->n_values; i++) {
                        evacuateUnboxable(cl->values[i], !(cl->unboxed & (1ULL << i)), oldgen);
                    }
                    break;
                }
                case Tag_Process: {
                    Process *p = static_cast<Process *>(obj);
                    evacuate(p->root, oldgen);
                    evacuate(p->stack, oldgen);
                    evacuate(p->mailbox, oldgen);
                    break;
                }
                case Tag_Task: {
                    Task *t = static_cast<Task *>(obj);
                    evacuate(t->value, oldgen);
                    evacuate(t->callback, oldgen);
                    evacuate(t->kill, oldgen);
                    evacuate(t->task, oldgen);
                    break;
                }
                default:
                    break;
            }

            scan_ptr += getObjectSize(obj);
            alloc_end = alloc_ptr; // Update end in case evacuate allocated more
        }

        // Flip spaces
        flipSpaces();
    }

    void *NurserySpace::copy(void *obj, OldGenSpace &oldgen) {
        if (!obj)
            return nullptr;

        Header *hdr = getHeader(obj);

        // Check if already forwarded
        if (hdr->tag == Tag_Forward) {
            Forward *fwd = static_cast<Forward *>(obj);
            // fwd->pointer is a logical offset in 8-byte units
            char *heap_base = GarbageCollector::instance().getHeapBase();
            uintptr_t byte_offset = static_cast<uintptr_t>(fwd->pointer) << 3;
            return heap_base + byte_offset;
        }

        size_t size = getObjectSize(obj);
        void *new_obj = nullptr;

        // Promote to old gen if age >= PROMOTION_AGE
        if (hdr->age >= PROMOTION_AGE) {
            std::lock_guard<std::mutex> lock(oldgen.getMutex());
            new_obj = oldgen.allocate(size);
            if (new_obj) {
                std::memcpy(new_obj, obj, size);
                Header *new_hdr = getHeader(new_obj);
                new_hdr->age = 0; // Reset age in old gen
            }
        }

        // Copy to to_space if not promoted
        if (!new_obj) {
            // Allocate in to_space
            size = (size + 7) & ~7; // Align
            new_obj = alloc_ptr;
            alloc_ptr += size;

            // Copy the object
            std::memcpy(new_obj, obj, size);

            // Update age after copying (preserves all other fields)
            Header *new_hdr = getHeader(new_obj);
            new_hdr->age++; // Increment age
        }

        // Leave forwarding pointer (as logical offset)
        Forward *fwd = static_cast<Forward *>(obj);
        fwd->header.tag = Tag_Forward;
        char *heap_base = GarbageCollector::instance().getHeapBase();
        uintptr_t byte_offset = static_cast<char *>(new_obj) - heap_base;
        fwd->pointer = byte_offset >> 3; // Store as offset in 8-byte units

        return new_obj;
    }

    void *NurserySpace::forward(void *obj) {
        if (!obj)
            return nullptr;

        Header *hdr = getHeader(obj);
        if (hdr->tag == Tag_Forward) {
            Forward *fwd = static_cast<Forward *>(obj);
            return reinterpret_cast<void *>(static_cast<uintptr_t>(fwd->pointer));
        }

        return obj;
    }

    void NurserySpace::evacuate(HPointer &ptr, OldGenSpace &oldgen) {
        if (ptr.constant != 0)
            return; // It's a constant

        void *obj = fromPointer(ptr);
        if (!obj)
            return;

        // Only evacuate if in nursery
        if (contains(obj)) {
            void *new_obj = copy(obj, oldgen);
            ptr = toPointer(new_obj);
        }
    }

    void NurserySpace::evacuateUnboxable(Unboxable &val, bool is_boxed, OldGenSpace &oldgen) {
        if (is_boxed) {
            evacuate(val.p, oldgen);
        }
    }

    void NurserySpace::flipSpaces() {
        std::swap(from_space, to_space);
        // Don't reset alloc_ptr! It already points to the end of live objects
        // which are now in from_space after the swap
        // alloc_ptr stays at its current location (end of live objects in new from_space)
        scan_ptr = from_space;
    }

    // ============================================================================
    // OldGenSpace Implementation
    // ============================================================================

    OldGenSpace::OldGenSpace() :
        region_base(nullptr), region_size(0), max_region_size(0),
        free_list(nullptr), current_epoch(0), marking_active(false) {
        // Initialization happens in initialize() method
    }

    OldGenSpace::~OldGenSpace() {
        // No need to free memory - it's part of the main heap
    }

    void OldGenSpace::initialize(char *base, size_t initial_size, size_t max_size) {
        region_base = base;
        region_size = initial_size;
        max_region_size = max_size;

        // Initialize free list with committed region
        FreeBlock *block = reinterpret_cast<FreeBlock *>(region_base);
        block->size = region_size;
        block->next = nullptr;
        free_list = block;

        // Track the region as our first "chunk"
        chunks.push_back(region_base);
    }

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
        void *result = mmap(
            new_region,
            growth,
            PROT_READ | PROT_WRITE,
            MAP_PRIVATE | MAP_ANONYMOUS | MAP_FIXED,
            -1, 0
        );

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

    void *OldGenSpace::allocate(size_t size) {
        size = (size + 7) & ~7; // Align
        size = std::max(size, sizeof(FreeBlock)); // Minimum size

        std::lock_guard<std::mutex> lock(alloc_mutex);

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
                hdr->color = static_cast<u32>(Color::White);
                hdr->size = size - sizeof(Header);

                return curr;
            }

            prev_ptr = &curr->next;
            curr = curr->next;
        }

        // No suitable block, allocate new chunk
        size_t chunk_size = std::max(size * 2, (long unsigned int) 1024 * 1024);
        addChunk(chunk_size);

        // Try again
        return allocate(size);
    }

    bool OldGenSpace::contains(void *ptr) const {
        char *p = static_cast<char *>(ptr);
        return (p >= region_base && p < region_base + region_size);
    }

    void OldGenSpace::startConcurrentMark(RootSet &roots) {
        std::lock_guard<std::mutex> lock(mark_mutex);

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

    bool OldGenSpace::incrementalMark(size_t work_units) {
        std::lock_guard<std::mutex> lock(mark_mutex);

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
                for (u32 i = 0; i < hdr->size; i++) {
                    markUnboxable(c->values[i], !(c->unboxed & (1ULL << i)));
                }
                break;
            }
            case Tag_Record: {
                Record *r = static_cast<Record *>(obj);
                for (u32 i = 0; i < hdr->size; i++) {
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

    void OldGenSpace::finishMarkAndSweep() {
        // Complete any remaining marking
        while (incrementalMark(1000)) {
            // Keep marking
        }

        sweep();

        marking_active = false;
    }

    void OldGenSpace::sweep() {
        std::lock_guard<std::mutex> lock(alloc_mutex);

        // Rebuild free list from white (unmarked) objects
        FreeBlock *new_free_list = nullptr;

        char *ptr = region_base;
        char *end = region_base + region_size;

        while (ptr < end) {
            Header *hdr = reinterpret_cast<Header *>(ptr);

            // Check if this is a valid object
            if (hdr->tag >= Tag_Forward) {
                ptr += sizeof(Header);
                continue;
            }

            size_t obj_size = sizeof(Header) + hdr->size;
            obj_size = (obj_size + 7) & ~7;

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
        heap_base(nullptr), heap_reserved(0), old_gen_committed(0),
        nursery_offset(0), next_nursery_offset(0), initialized(false) {
        // Initialization happens in initialize() method
    }

    GarbageCollector::~GarbageCollector() {
        if (heap_base) {
            munmap(heap_base, heap_reserved);
        }
    }

    void GarbageCollector::initialize(size_t max_heap_size) {
        if (initialized) return;

        heap_reserved = max_heap_size;

        // Reserve address space without committing physical memory
        heap_base = static_cast<char *>(mmap(
            nullptr,
            heap_reserved,
            PROT_NONE,  // No access initially
            MAP_PRIVATE | MAP_ANONYMOUS | MAP_NORESERVE,
            -1, 0
        ));

        if (heap_base == MAP_FAILED) {
            throw std::bad_alloc();
        }

        // Nurseries start at halfway point
        nursery_offset = heap_reserved / 2;
        next_nursery_offset = nursery_offset;

        // Old gen starts at offset 0, can grow up to halfway point
        // Commit initial 1MB for old gen
        size_t initial_old_gen = 1 * 1024 * 1024;  // 1MB
        size_t max_old_gen = nursery_offset;       // Can grow to halfway point
        growOldGen(initial_old_gen);
        old_gen.initialize(heap_base, old_gen_committed, max_old_gen);

        initialized = true;
    }

    void GarbageCollector::growOldGen(size_t additional_size) {
        // Commit more memory for old gen
        char *new_region = heap_base + old_gen_committed;

        void *result = mmap(
            new_region,
            additional_size,
            PROT_READ | PROT_WRITE,
            MAP_PRIVATE | MAP_ANONYMOUS | MAP_FIXED,
            -1, 0
        );

        if (result == MAP_FAILED) {
            throw std::bad_alloc();
        }

        old_gen_committed += additional_size;
    }

    void GarbageCollector::commitNursery(char *nursery_base, size_t size) {
        // Commit memory for a nursery
        void *result = mmap(
            nursery_base,
            size,
            PROT_READ | PROT_WRITE,
            MAP_PRIVATE | MAP_ANONYMOUS | MAP_FIXED,
            -1, 0
        );

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
                return obj;
            }
        }

        // Allocate in old gen
        void *obj = old_gen.allocate(size);
        if (obj) {
            Header *hdr = getHeader(obj);
            hdr->tag = tag;
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