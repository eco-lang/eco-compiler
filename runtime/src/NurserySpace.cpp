/**
 * NurserySpace Implementation.
 *
 * Block-based nursery using Cheney's semi-space copying algorithm.
 *
 * The nursery is composed of blocks from two separate address space regions:
 *   - low_blocks_: Blocks from the low half of nursery address space
 *   - high_blocks_: Blocks from the high half of nursery address space
 *
 * This split guarantees: all low block addresses < all high block addresses.
 * This enables O(1) membership checks using simple range comparisons.
 *
 * One set of blocks is the "from-space" (allocation), the other is "to-space"
 * (copy target during GC). After GC, the roles swap.
 *
 * Allocation: Bump pointer into current from-space block (O(1)).
 *
 * Minor GC algorithm:
 *   1. Evacuate roots to to_space blocks (or promote to old gen if aged).
 *   2. Cheney scan: walk to_space blocks, evacuate their children.
 *   3. Process promoted objects (they may point back to nursery).
 *   4. Check occupancy and grow if needed.
 *   5. Swap from/to roles by flipping from_is_low_.
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
    config_(nullptr), allocator_(nullptr), block_size_(0), from_is_low_(true),
    low_base_(nullptr), low_end_(nullptr), high_base_(nullptr), high_end_(nullptr),
    current_from_idx_(0), alloc_ptr_(nullptr), alloc_end_(nullptr),
    current_to_idx_(0), copy_ptr_(nullptr), copy_end_(nullptr),
    scan_block_idx_(0), scan_ptr_(nullptr),
    growth_threshold_(0.75f), thread_heap_(nullptr) {
    // Initialization happens in initialize() method.
}

NurserySpace::~NurserySpace() {
    // No need to free memory - blocks are part of the main heap.
}

void NurserySpace::initialize(Allocator* allocator, const HeapConfig* config) {
    config_ = config;
    allocator_ = allocator;
    thread_heap_ = nullptr;  // Legacy single-threaded mode (not using ThreadLocalHeap).
    block_size_ = config->alloc_buffer_size;
    growth_threshold_ = 0.75f;  // Grow when to-space exceeds 75% full after GC.

    size_t blocks_per_space = config->nursery_block_count / 2;

    // Request blocks from low region.
    for (size_t i = 0; i < blocks_per_space; i++) {
        char* block = allocator->acquireNurseryBlockLow(block_size_);
        assert(block && "Failed to acquire nursery block from low region");
        low_blocks_.push_back(block);
    }

    // Request blocks from high region.
    for (size_t i = 0; i < blocks_per_space; i++) {
        char* block = allocator->acquireNurseryBlockHigh(block_size_);
        assert(block && "Failed to acquire nursery block from high region");
        high_blocks_.push_back(block);
    }

    // Sort blocks by address (should already be sorted from sequential allocation,
    // but sort anyway for safety in case of future block recycling).
    std::sort(low_blocks_.begin(), low_blocks_.end());
    std::sort(high_blocks_.begin(), high_blocks_.end());

    // Compute cached bounds.
    updateBounds();

    // Start with low as from-space.
    from_is_low_ = true;
    current_from_idx_ = 0;
    alloc_ptr_ = low_blocks_[0];
    alloc_end_ = low_blocks_[0] + block_size_;
}

void NurserySpace::initialize(ThreadLocalHeap* heap, const HeapConfig* config) {
    config_ = config;
    thread_heap_ = heap;
    allocator_ = heap->getParent();  // Reference to Allocator for block acquisition during growth.
    block_size_ = config->alloc_buffer_size;
    growth_threshold_ = 0.75f;  // Grow when to-space exceeds 75% full after GC.

    size_t blocks_per_space = config->nursery_block_count / 2;

    // Request blocks from low region.
    for (size_t i = 0; i < blocks_per_space; i++) {
        char* block = allocator_->acquireNurseryBlockLow(block_size_);
        assert(block && "Failed to acquire nursery block from low region");
        low_blocks_.push_back(block);
    }

    // Request blocks from high region.
    for (size_t i = 0; i < blocks_per_space; i++) {
        char* block = allocator_->acquireNurseryBlockHigh(block_size_);
        assert(block && "Failed to acquire nursery block from high region");
        high_blocks_.push_back(block);
    }

    // Sort blocks by address.
    std::sort(low_blocks_.begin(), low_blocks_.end());
    std::sort(high_blocks_.begin(), high_blocks_.end());

    // Compute cached bounds.
    updateBounds();

    // Start with low as from-space.
    from_is_low_ = true;
    current_from_idx_ = 0;
    alloc_ptr_ = low_blocks_[0];
    alloc_end_ = low_blocks_[0] + block_size_;
}

void NurserySpace::reset(OldGenSpace &oldgen, const HeapConfig* new_config) {
    // Update config if provided.
    if (new_config) {
        config_ = new_config;
        block_size_ = new_config->alloc_buffer_size;
    }

    // Clear existing blocks (memory will be recommitted on next init).
    low_blocks_.clear();
    high_blocks_.clear();

    // Re-initialize with current config.
    size_t blocks_per_space = config_->nursery_block_count / 2;

    for (size_t i = 0; i < blocks_per_space; i++) {
        char* block = allocator_->acquireNurseryBlockLow(block_size_);
        assert(block && "Failed to acquire nursery block from low region");
        low_blocks_.push_back(block);
    }
    for (size_t i = 0; i < blocks_per_space; i++) {
        char* block = allocator_->acquireNurseryBlockHigh(block_size_);
        assert(block && "Failed to acquire nursery block from high region");
        high_blocks_.push_back(block);
    }

    // Sort blocks by address.
    std::sort(low_blocks_.begin(), low_blocks_.end());
    std::sort(high_blocks_.begin(), high_blocks_.end());

    // Compute cached bounds.
    updateBounds();

    // Reset allocation state.
    from_is_low_ = true;
    current_from_idx_ = 0;
    alloc_ptr_ = low_blocks_[0];
    alloc_end_ = low_blocks_[0] + block_size_;

    // Reset the root set.
    root_set.reset();

    // Note: GC stats are not reset here - they accumulate across multiple runs.
}

void NurserySpace::updateBounds() {
    if (!low_blocks_.empty()) {
        low_base_ = low_blocks_.front();
        low_end_ = low_blocks_.back() + block_size_;
    } else {
        low_base_ = nullptr;
        low_end_ = nullptr;
    }

    if (!high_blocks_.empty()) {
        high_base_ = high_blocks_.front();
        high_end_ = high_blocks_.back() + block_size_;
    } else {
        high_base_ = nullptr;
        high_end_ = nullptr;
    }
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
    std::vector<char*>& from_blocks = from_is_low_ ? low_blocks_ : high_blocks_;

    // Try next block in from-space.
    ++current_from_idx_;
    if (current_from_idx_ < from_blocks.size()) {
        alloc_ptr_ = from_blocks[current_from_idx_];
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
    char* p = static_cast<char*>(ptr);
    return (p >= low_base_ && p < low_end_) ||
           (p >= high_base_ && p < high_end_);
}

bool NurserySpace::isInFromSpace(void* ptr) const {
    char* p = static_cast<char*>(ptr);
    if (from_is_low_) {
        return p >= low_base_ && p < low_end_;
    } else {
        return p >= high_base_ && p < high_end_;
    }
}

bool NurserySpace::isInToSpace(void* ptr) const {
    char* p = static_cast<char*>(ptr);
    if (from_is_low_) {
        return p >= high_base_ && p < high_end_;
    } else {
        return p >= low_base_ && p < low_end_;
    }
}

size_t NurserySpace::bytesAllocated() const {
    const std::vector<char*>& from_blocks = from_is_low_ ? low_blocks_ : high_blocks_;

    size_t bytes = 0;

    // Count full blocks before current.
    for (size_t i = 0; i < current_from_idx_ && i < from_blocks.size(); i++) {
        bytes += block_size_;
    }

    // Add partial current block.
    if (current_from_idx_ < from_blocks.size()) {
        bytes += (alloc_ptr_ - from_blocks[current_from_idx_]);
    }

    return bytes;
}

bool NurserySpace::wouldExceedThreshold(size_t size, float threshold) const {
    const std::vector<char*>& from_blocks = from_is_low_ ? low_blocks_ : high_blocks_;

    size_t aligned_size = (size + 7) & ~7;
    size_t total_capacity = from_blocks.size() * block_size_;
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

    std::vector<char*>& to_blocks = from_is_low_ ? high_blocks_ : low_blocks_;

    // Slow path: advance to next block.
    ++current_to_idx_;
    if (current_to_idx_ < to_blocks.size()) {
        copy_ptr_ = to_blocks[current_to_idx_];
        copy_end_ = copy_ptr_ + block_size_;

        void* result = copy_ptr_;
        copy_ptr_ += size;
        return result;
    }

    // Out of to-space blocks - should not happen with equal-sized spaces.
    assert(false && "To-space overflow - should not happen with equal-sized spaces");
    return nullptr;
}

bool NurserySpace::scanHasMore() const {
    // Check if scan pointer has caught up to copy pointer.
    if (scan_block_idx_ < current_to_idx_) {
        return true;
    }
    if (scan_block_idx_ == current_to_idx_) {
        return scan_ptr_ < copy_ptr_;
    }
    return false;
}

void NurserySpace::advanceScanIfNeeded() {
    const std::vector<char*>& to_blocks = from_is_low_ ? high_blocks_ : low_blocks_;

    // If scan_ptr reached end of current block, move to next.
    char* block_end = to_blocks[scan_block_idx_] + block_size_;
    if (scan_ptr_ >= block_end) {
        ++scan_block_idx_;
        if (scan_block_idx_ < to_blocks.size()) {
            scan_ptr_ = to_blocks[scan_block_idx_];
        }
    }
}

void NurserySpace::checkAndGrow() {
    std::vector<char*>& to_blocks = from_is_low_ ? high_blocks_ : low_blocks_;

    // Calculate to-space occupancy after copying.
    size_t bytes_used = 0;
    for (size_t i = 0; i < current_to_idx_ && i < to_blocks.size(); i++) {
        bytes_used += block_size_;  // Count full blocks before current.
    }
    if (current_to_idx_ < to_blocks.size()) {
        bytes_used += (copy_ptr_ - to_blocks[current_to_idx_]);  // Add partial current block.
    }

    size_t total_to_capacity = to_blocks.size() * block_size_;
    float occupancy = static_cast<float>(bytes_used) / total_to_capacity;

    if (occupancy <= growth_threshold_) {
        return;  // No growth needed.
    }

    // Grow by adding blocks to both spaces.
    size_t blocks_to_add = to_blocks.size() / 2;  // Grow by 50%.
    if (blocks_to_add < 1) blocks_to_add = 1;
    if (blocks_to_add % 2 != 0) blocks_to_add++;  // Keep even for symmetry.

    // Track how many we successfully add to each space.
    size_t low_added = 0;
    size_t high_added = 0;

    // First, try to add blocks to both spaces.
    std::vector<char*> new_low_blocks;
    std::vector<char*> new_high_blocks;

    for (size_t i = 0; i < blocks_to_add; i++) {
        char* block = allocator_->acquireNurseryBlockLow(block_size_);
        if (block) {
            new_low_blocks.push_back(block);
            low_added++;
        }
    }

    for (size_t i = 0; i < blocks_to_add; i++) {
        char* block = allocator_->acquireNurseryBlockHigh(block_size_);
        if (block) {
            new_high_blocks.push_back(block);
            high_added++;
        }
    }

    // Only proceed if we got equal blocks for both (keep spaces balanced).
    if (low_added != high_added || low_added == 0) {
        // Failed to grow symmetrically - don't add any blocks.
        // Note: The blocks we did acquire are lost (minor leak), but this
        // is acceptable for the rare case of asymmetric growth failure.
        return;
    }

    // Insert new blocks in sorted order.
    for (char* block : new_low_blocks) {
        auto it = std::lower_bound(low_blocks_.begin(), low_blocks_.end(), block);
        low_blocks_.insert(it, block);
    }

    for (char* block : new_high_blocks) {
        auto it = std::lower_bound(high_blocks_.begin(), high_blocks_.end(), block);
        high_blocks_.insert(it, block);
    }

    // Update cached bounds.
    updateBounds();
}

/**
 * Performs a minor garbage collection using Cheney's algorithm with hybrid DFS/BFS traversal.
 *
 * Algorithm phases:
 *   1. Evacuate all roots (from root set) to to-space or old gen (if aged).
 *   2. Hybrid traversal: drain DFS stack for deep structures, fall back to
 *      Cheney's scan pointer for breadth-first when stack is empty.
 *   3. Process promoted objects (scan their children, may add more promoted objects).
 *   4. Check occupancy and grow nursery if needed.
 *   5. Swap from-space and to-space.
 *
 * Key optimization: Elm's immutability guarantees no old-to-young pointers,
 * so no remembered set or write barriers are needed.
 */
void NurserySpace::minorGC(OldGenSpace &oldgen) {
#if ENABLE_GC_STATS
    // Capture state before GC.
    size_t from_space_used = bytesAllocated();
    auto gc_start = GC_STATS_TIMER_START();
#endif

    std::vector<char*>& to_blocks = from_is_low_ ? high_blocks_ : low_blocks_;

    // Reset to-space allocation - start at first block.
    current_to_idx_ = 0;
    copy_ptr_ = to_blocks[0];
    copy_end_ = to_blocks[0] + block_size_;

    // Reset scan pointers.
    scan_block_idx_ = 0;
    scan_ptr_ = to_blocks[0];

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

    // Phase 5: Swap spaces by flipping which is from/to.
    from_is_low_ = !from_is_low_;

    // Reset from-space allocation to continue after survivors.
    // After swap: the old to_blocks (with survivors) is now from-space.
    std::vector<char*>& new_from = from_is_low_ ? low_blocks_ : high_blocks_;
    current_from_idx_ = current_to_idx_;
    alloc_ptr_ = copy_ptr_;
    if (current_from_idx_ < new_from.size()) {
        alloc_end_ = new_from[current_from_idx_] + block_size_;
    }

#if ENABLE_GC_STATS
    // Calculate what happened during this GC.
    size_t to_space_used = 0;
    for (size_t i = 0; i < current_from_idx_ && i < new_from.size(); i++) {
        to_space_used += block_size_;
    }
    if (current_from_idx_ < new_from.size()) {
        to_space_used += (alloc_ptr_ - new_from[current_from_idx_]);
    }
    size_t bytes_freed = from_space_used > to_space_used ? from_space_used - to_space_used : 0;
    uint64_t elapsed_ns = GC_STATS_TIMER_ELAPSED_NS(gc_start);

    GC_STATS_MINOR_RECORD_GC_END(stats, elapsed_ns, bytes_freed);
#endif
}

/**
 * Evacuates an object from from-space to to-space or old gen.
 *
 * Behavior:
 *   - If already forwarded: updates ptr to forwarding target and returns.
 *   - If not in from-space: returns (already evacuated or in old gen).
 *   - Otherwise: copies object to to-space (or promotes to old gen if aged),
 *     leaves forwarding pointer, and updates ptr to new location.
 *
 * Promotion: Objects with age >= promotion_age are copied to old gen and
 * added to promoted_objects for later scanning. Otherwise, they are copied
 * to to-space with age incremented.
 *
 * The original object is replaced with a forwarding pointer (Tag_Forward)
 * to prevent redundant copying if multiple pointers reference it.
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
