/**
 * NurserySpace Implementation.
 *
 * Block-based nursery using Cheney's semi-space copying algorithm.
 *
 * The nursery is composed of blocks (same size as AllocBuffer). Blocks are
 * organized into two sets: from_blocks_ (allocation space) and to_blocks_
 * (copy target during GC).
 *
 * Allocation: Bump pointer into current from-space block (O(1)).
 *
 * Minor GC algorithm:
 *   1. Evacuate roots to to_space blocks (or promote to old gen if aged).
 *   2. Cheney scan: walk to_space blocks, evacuate their children.
 *   3. Process promoted objects (they may point back to nursery).
 *   4. Check occupancy and grow if needed.
 *   5. Swap from_blocks_ and to_blocks_.
 *
 * Key optimization: Elm's immutability means no old->young pointers exist,
 * so no write barrier or remembered set is needed.
 */

#include "NurserySpace.hpp"
#include "Allocator.hpp"
#include "ThreadLocalHeap.hpp"
#include <cassert>
#include <cstring>

namespace Elm {

NurserySpace::NurserySpace() :
    config_(nullptr), allocator_(nullptr), block_size_(0),
    alloc_ptr_(nullptr), alloc_end_(nullptr),
    copy_ptr_(nullptr), copy_end_(nullptr), scan_ptr_(nullptr),
    growth_threshold_(0.75f), thread_heap_(nullptr) {
    // Initialization happens in initialize() method.
}

NurserySpace::~NurserySpace() {
    // No need to free memory - blocks are part of the main heap.
}

void NurserySpace::initialize(Allocator* allocator, const HeapConfig* config) {
    config_ = config;
    allocator_ = allocator;
    thread_heap_ = nullptr;  // Not using ThreadLocalHeap mode.
    block_size_ = config->alloc_buffer_size;
    growth_threshold_ = 0.75f;  // Grow when 75% full after GC.

    size_t blocks_per_space = config->nursery_block_count / 2;

    // Request initial blocks from Allocator.
    for (size_t i = 0; i < blocks_per_space; i++) {
        char* block = allocator->acquireNurseryBlock(block_size_);
        assert(block && "Failed to acquire nursery block for from-space");
        from_blocks_.insert(block);
    }
    for (size_t i = 0; i < blocks_per_space; i++) {
        char* block = allocator->acquireNurseryBlock(block_size_);
        assert(block && "Failed to acquire nursery block for to-space");
        to_blocks_.insert(block);
    }

    // Initialize allocation state - start at first (lowest address) block.
    current_from_it_ = from_blocks_.begin();
    alloc_ptr_ = *current_from_it_;
    alloc_end_ = *current_from_it_ + block_size_;
}

void NurserySpace::initialize(ThreadLocalHeap* heap, const HeapConfig* config) {
    config_ = config;
    thread_heap_ = heap;
    allocator_ = heap->getParent();  // Get Allocator for block acquisition during growth.
    block_size_ = config->alloc_buffer_size;
    growth_threshold_ = 0.75f;  // Grow when 75% full after GC.

    size_t blocks_per_space = config->nursery_block_count / 2;

    // Request initial blocks from Allocator (through parent).
    for (size_t i = 0; i < blocks_per_space; i++) {
        char* block = allocator_->acquireNurseryBlock(block_size_);
        assert(block && "Failed to acquire nursery block for from-space");
        from_blocks_.insert(block);
    }
    for (size_t i = 0; i < blocks_per_space; i++) {
        char* block = allocator_->acquireNurseryBlock(block_size_);
        assert(block && "Failed to acquire nursery block for to-space");
        to_blocks_.insert(block);
    }

    // Initialize allocation state - start at first (lowest address) block.
    current_from_it_ = from_blocks_.begin();
    alloc_ptr_ = *current_from_it_;
    alloc_end_ = *current_from_it_ + block_size_;
}

void NurserySpace::reset(OldGenSpace &oldgen, const HeapConfig* new_config) {
    // Update config if provided.
    if (new_config) {
        config_ = new_config;
        block_size_ = new_config->alloc_buffer_size;
    }

    // Clear existing blocks (memory will be recommitted on next init).
    from_blocks_.clear();
    to_blocks_.clear();

    // Re-initialize with current config.
    size_t blocks_per_space = config_->nursery_block_count / 2;

    for (size_t i = 0; i < blocks_per_space; i++) {
        char* block = allocator_->acquireNurseryBlock(block_size_);
        assert(block && "Failed to acquire nursery block for from-space");
        from_blocks_.insert(block);
    }
    for (size_t i = 0; i < blocks_per_space; i++) {
        char* block = allocator_->acquireNurseryBlock(block_size_);
        assert(block && "Failed to acquire nursery block for to-space");
        to_blocks_.insert(block);
    }

    // Reset allocation state.
    current_from_it_ = from_blocks_.begin();
    alloc_ptr_ = *current_from_it_;
    alloc_end_ = *current_from_it_ + block_size_;

    // Reset the root set.
    root_set.reset();

    // Note: We do NOT reset GC stats here - stats accumulate across runs.
}

void *NurserySpace::allocate(size_t size) {
    // Align to 8 bytes.
    size = (size + 7) & ~7;

    // Fast path: fits in current block.
    if (alloc_ptr_ + size <= alloc_end_) {
        void *result = alloc_ptr_;
        alloc_ptr_ += size;
        GC_STATS_MINOR_RECORD_ALLOC(stats, size);
        return result;
    }

    // Slow path: need next block.
    return allocateSlow(size);
}

void* NurserySpace::allocateSlow(size_t size) {
    // Try next block in from-space.
    ++current_from_it_;
    if (current_from_it_ != from_blocks_.end()) {
        alloc_ptr_ = *current_from_it_;
        alloc_end_ = alloc_ptr_ + block_size_;

        if (alloc_ptr_ + size <= alloc_end_) {
            void* result = alloc_ptr_;
            alloc_ptr_ += size;
            GC_STATS_MINOR_RECORD_ALLOC(stats, size);
            return result;
        }
    }

    // No more blocks - return nullptr to trigger GC.
    return nullptr;
}

bool NurserySpace::contains(void *ptr) const {
    return isInFromSpace(ptr) || isInToSpace(ptr);
}

bool NurserySpace::isInFromSpace(void* ptr) const {
    char* p = static_cast<char*>(ptr);

    // Find first block with start > p.
    auto it = from_blocks_.upper_bound(p);

    // If it's the first element, p is before all blocks.
    if (it == from_blocks_.begin())
        return false;

    // Check the previous block (last one with start <= p).
    --it;
    return p < (*it + block_size_);
}

bool NurserySpace::isInToSpace(void* ptr) const {
    char* p = static_cast<char*>(ptr);

    auto it = to_blocks_.upper_bound(p);
    if (it == to_blocks_.begin())
        return false;

    --it;
    return p < (*it + block_size_);
}

size_t NurserySpace::bytesAllocated() const {
    size_t bytes = 0;

    // Count full blocks before current.
    for (auto it = from_blocks_.begin(); it != current_from_it_; ++it) {
        bytes += block_size_;
    }

    // Add partial current block.
    if (current_from_it_ != from_blocks_.end()) {
        bytes += (alloc_ptr_ - *current_from_it_);
    }

    return bytes;
}

bool NurserySpace::wouldExceedThreshold(size_t size, float threshold) const {
    size_t aligned_size = (size + 7) & ~7;
    size_t total_capacity = from_blocks_.size() * block_size_;
    size_t usage_after = bytesAllocated() + aligned_size;
    return usage_after >= (size_t)(total_capacity * threshold);
}

void* NurserySpace::copyToSpace(size_t size) {
    // Fast path: fits in current to-space block.
    if (copy_ptr_ + size <= copy_end_) {
        void* result = copy_ptr_;
        copy_ptr_ += size;
        return result;
    }

    // Need next block.
    ++current_to_it_;
    if (current_to_it_ != to_blocks_.end()) {
        copy_ptr_ = *current_to_it_;
        copy_end_ = copy_ptr_ + block_size_;

        void* result = copy_ptr_;
        copy_ptr_ += size;
        return result;
    }

    // Out of to-space blocks - this shouldn't happen if spaces are equal size.
    assert(false && "To-space overflow - should not happen with equal-sized spaces");
    return nullptr;
}

bool NurserySpace::scanHasMore() const {
    // Check if scan pointer has caught up to copy pointer.
    // Compare block iterators first, then pointers within same block.
    if (scan_block_it_ != current_to_it_) {
        // Different blocks - scan is behind if its block address is less.
        return *scan_block_it_ < *current_to_it_;
    }
    // Same block - compare pointers.
    return scan_ptr_ < copy_ptr_;
}

void NurserySpace::advanceScanIfNeeded() {
    // If scan_ptr reached end of current block, move to next.
    char* block_end = *scan_block_it_ + block_size_;
    if (scan_ptr_ >= block_end) {
        ++scan_block_it_;
        if (scan_block_it_ != to_blocks_.end()) {
            scan_ptr_ = *scan_block_it_;
        }
    }
}

void NurserySpace::checkAndGrow() {
    // Calculate how full to-space is after copying.
    size_t bytes_used = 0;
    for (auto it = to_blocks_.begin(); it != current_to_it_; ++it) {
        bytes_used += block_size_;  // Full blocks before current.
    }
    if (current_to_it_ != to_blocks_.end()) {
        bytes_used += (copy_ptr_ - *current_to_it_);  // Partial current block.
    }

    size_t total_to_capacity = to_blocks_.size() * block_size_;
    float occupancy = static_cast<float>(bytes_used) / total_to_capacity;

    if (occupancy > growth_threshold_) {
        // Request more blocks for both spaces.
        size_t blocks_to_add = to_blocks_.size() / 2;  // Grow by 50%.
        if (blocks_to_add < 1) blocks_to_add = 1;

        for (size_t i = 0; i < blocks_to_add; i++) {
            char* block = allocator_->acquireNurseryBlock(block_size_);
            if (block) {
                from_blocks_.insert(block);
            }
        }
        for (size_t i = 0; i < blocks_to_add; i++) {
            char* block = allocator_->acquireNurseryBlock(block_size_);
            if (block) {
                to_blocks_.insert(block);
            }
        }
    }
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
 * only creates acyclic structures on the heap and immutability means that younger objects only point to older
 * ones and never the other way around. Therefore objects moved into the old generation during evacuation do
 * not need to be scanned by Cheney's algorithm.
 */
void NurserySpace::minorGC(OldGenSpace &oldgen) {
#if ENABLE_GC_STATS
    // Capture state before GC.
    size_t from_space_used = bytesAllocated();
    auto gc_start = GC_STATS_TIMER_START();
#endif

    // Reset to-space allocation - start at first block.
    current_to_it_ = to_blocks_.begin();
    copy_ptr_ = *current_to_it_;
    copy_end_ = *current_to_it_ + block_size_;

    // Reset scan pointers.
    scan_block_it_ = to_blocks_.begin();
    scan_ptr_ = *scan_block_it_;

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

    // Clear DFS stack before starting hybrid traversal.
    dfs_stack_.clear();

    // Phase 2: Hybrid Cheney/DFS algorithm (may add to promoted_objects).
    // - DFS stack provides depth-first bias for deep structures (lists, task chains)
    // - Cheney's scanPtr provides BFS fallback and guarantees completion
    while (scanHasMore() || !dfs_stack_.empty()) {
        // Priority 1: Drain DFS stack (depth-first for lists/chains).
        // This clusters related objects together for better cache locality.
        while (!dfs_stack_.empty()) {
            void* obj = dfs_stack_.pop();
            // Only scan if object is in to-space (already evacuated there).
            // Objects may have been pushed but already processed via scanPtr.
            if (isInToSpace(obj)) {
                scanObject(obj, oldgen, &promoted_objects);
            }
        }

        // Priority 2: Cheney scan (BFS fallback, handles stack overflow).
        if (scanHasMore()) {
            void *obj = scan_ptr_;
            scanObject(obj, oldgen, &promoted_objects);
            scan_ptr_ += getObjectSize(obj);
            advanceScanIfNeeded();
        }
    }

    // Phase 3: Process promoted objects until buffer is empty.
    // Use index-based loop since vector may grow during iteration.
    for (size_t i = 0; i < promoted_objects.size(); i++) {
        scanObject(promoted_objects[i], oldgen, &promoted_objects);
    }

    // Phase 4: Check occupancy and grow if needed.
    checkAndGrow();

    // Phase 5: Swap spaces.
    std::swap(from_blocks_, to_blocks_);

    // Reset from-space allocation to continue after survivors.
    // After swap: from_blocks_ contains the old to_blocks_ (with survivors).
    //             current_to_it_ now points into from_blocks_.
    current_from_it_ = current_to_it_;  // Iterator still valid after swap.
    alloc_ptr_ = copy_ptr_;             // Continue from where copying ended.
    if (current_from_it_ != from_blocks_.end()) {
        alloc_end_ = *current_from_it_ + block_size_;
    }

#if ENABLE_GC_STATS
    // Calculate what happened during this GC.
    size_t to_space_used = 0;
    for (auto it = from_blocks_.begin(); it != current_from_it_; ++it) {
        to_space_used += block_size_;
    }
    if (current_from_it_ != from_blocks_.end()) {
        to_space_used += (alloc_ptr_ - *current_from_it_);
    }
    size_t bytes_freed = from_space_used > to_space_used ? from_space_used - to_space_used : 0;
    uint64_t elapsed_ns = GC_STATS_TIMER_ELAPSED_NS(gc_start);

    GC_STATS_MINOR_RECORD_GC_END(stats, elapsed_ns, bytes_freed);
#endif
}

/**
 * Updates a pointer into the nursery space to a new location at which that object will be located after
 * a garbage collection cycle. The pointer MUST point to a live object that should not be garbage
 * collected.
 *
 *     - If the object has already been moved, it will leave behind a forwarding pointer, and the
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

    void *obj = Allocator::fromPointerRaw(ptr);
    if (!obj)
        return;

    // Assert pointer is within valid heap memory.
    char *heap_base = Allocator::instance().getHeapBase();
    char *heap_end = heap_base + Allocator::instance().getHeapReserved();
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
        ptr = Allocator::toPointerRaw(heap_base + byte_offset);
        return;
    }

    // Second priority: Only evacuate if in from-space (not to-space!).
    // This prevents creating forwarding chains by re-evacuating already-moved objects.
    if (!isInFromSpace(obj))
        return;

    // Now proceed with evacuation (object is in from-space and not yet forwarded).

    size_t size = getObjectSize(obj);
    void *new_obj = nullptr;

    bool promoted = false;

    // Promote to old gen if age >= config_->promotion_age.
    if (hdr->age >= config_->promotion_age) {
        // Direct allocation to old gen (simplified - no TLAB buffering).
        new_obj = oldgen.allocate(size);
        assert(new_obj && "Failed to allocate in old gen during promotion");

        std::memcpy(new_obj, obj, size);

        // Reset age for promoted object.
        Header *new_hdr = getHeader(new_obj);
        new_hdr->age = 0;
        promoted = true;

        // Add to promoted objects buffer for later scanning.
        if (promoted_objects) {
            promoted_objects->push_back(new_obj);
        }

        GC_STATS_MINOR_INC_PROMOTED(stats);
    }

    // Copy to to_space if not promoted.
    if (!new_obj) {
        // Allocate in to_space.
        new_obj = copyToSpace(size);
        assert(new_obj && "Failed to copy to to-space during evacuation!");

        // Copy the object with its padding to maintain alignment.
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

    ptr = Allocator::toPointerRaw(new_obj);
}

void NurserySpace::evacuateUnboxable(Unboxable &val, bool is_boxed, OldGenSpace &oldgen, std::vector<void*> *promoted_objects) {
    if (is_boxed) {
        evacuate(val.p, oldgen, promoted_objects);
    }
}

/**
 * Scans a heap object and evacuates all its children.
 *
 * This implements a hybrid DFS/BFS traversal strategy:
 *   - Deep structures (Cons lists, Task chains): Push tails onto DFS stack
 *     for depth-first traversal, which clusters list cells contiguously.
 *   - Wide structures (Tuple, Record, Closure): Evacuate inline for BFS,
 *     which keeps sibling fields together (accessed as a group).
 *
 * The DFS stack has bounded size; when full, objects fall through to
 * Cheney's scanPtr for BFS processing.
 */
void NurserySpace::scanObject(void *obj, OldGenSpace &oldgen, std::vector<void*> *promoted_objects) {
    Header *hdr = getHeader(obj);

    // Process children based on tag.
    switch (hdr->tag) {
        // ====== Wide structures: BFS (inline evacuation) ======
        // These have multiple fields accessed together; keep siblings contiguous.

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

        // ====== Deep structures: DFS (push tail onto stack) ======
        // These form chains; depth-first keeps the chain contiguous.

        case Tag_Cons: {
            Cons *c = static_cast<Cons *>(obj);
            // Head is "wide" direction - evacuate inline.
            evacuateUnboxable(c->head, !(hdr->unboxed & 1), oldgen, promoted_objects);

            // Tail is "deep" direction - use DFS for list locality.
            if (config_->use_hybrid_dfs) {
                // Evacuate tail first (updates c->tail to new location).
                evacuate(c->tail, oldgen, promoted_objects);

                // Push evacuated tail onto DFS stack for immediate processing.
                // This ensures the next Cons cell is copied right after this one.
                if (c->tail.constant == 0) {
                    void* tail_obj = Allocator::fromPointerRaw(c->tail);
                    if (tail_obj && isInToSpace(tail_obj) && !dfs_stack_.full()) {
                        dfs_stack_.push(tail_obj);
                    }
                }
            } else {
                evacuate(c->tail, oldgen, promoted_objects);
            }
            break;
        }

        case Tag_Task: {
            Task *t = static_cast<Task *>(obj);
            // value, callback, kill are "wide" - evacuate inline.
            evacuate(t->value, oldgen, promoted_objects);
            evacuate(t->callback, oldgen, promoted_objects);
            evacuate(t->kill, oldgen, promoted_objects);

            // task pointer can form chains - use DFS.
            if (config_->use_hybrid_dfs) {
                evacuate(t->task, oldgen, promoted_objects);

                if (t->task.constant == 0) {
                    void* task_obj = Allocator::fromPointerRaw(t->task);
                    if (task_obj && isInToSpace(task_obj) && !dfs_stack_.full()) {
                        dfs_stack_.push(task_obj);
                    }
                }
            } else {
                evacuate(t->task, oldgen, promoted_objects);
            }
            break;
        }

        case Tag_Process: {
            Process *p = static_cast<Process *>(obj);

            if (config_->use_hybrid_dfs) {
                // Evacuate all three subgraphs.
                evacuate(p->root, oldgen, promoted_objects);
                evacuate(p->stack, oldgen, promoted_objects);
                evacuate(p->mailbox, oldgen, promoted_objects);

                // Push in reverse order so root is processed first (LIFO).
                // This clusters each subgraph together.
                if (p->mailbox.constant == 0) {
                    void* mailbox_obj = Allocator::fromPointerRaw(p->mailbox);
                    if (mailbox_obj && isInToSpace(mailbox_obj) && !dfs_stack_.full()) {
                        dfs_stack_.push(mailbox_obj);
                    }
                }
                if (p->stack.constant == 0) {
                    void* stack_obj = Allocator::fromPointerRaw(p->stack);
                    if (stack_obj && isInToSpace(stack_obj) && !dfs_stack_.full()) {
                        dfs_stack_.push(stack_obj);
                    }
                }
                if (p->root.constant == 0) {
                    void* root_obj = Allocator::fromPointerRaw(p->root);
                    if (root_obj && isInToSpace(root_obj) && !dfs_stack_.full()) {
                        dfs_stack_.push(root_obj);
                    }
                }
            } else {
                evacuate(p->root, oldgen, promoted_objects);
                evacuate(p->stack, oldgen, promoted_objects);
                evacuate(p->mailbox, oldgen, promoted_objects);
            }
            break;
        }

        default:
            break;
    }
}

} // namespace Elm
