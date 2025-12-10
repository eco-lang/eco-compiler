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

// contains(), isInFromSpace(), isInToSpace() are now inline in the header.

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
 * Performs a minor garbage collection using Cheney's algorithm.
 *
 * Algorithm phases:
 *   1. Evacuate all roots (from root set) to to-space or old gen (if aged).
 *   2. Cheney scan: walk to-space objects breadth-first, evacuating children.
 *      When use_hybrid_dfs is enabled, list spines are copied contiguously.
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

    // Phase 1c: Evacuate JIT roots (raw 64-bit pointers from JIT-compiled globals).
    for (uint64_t *root: root_set.getJitRoots()) {
        evacuateJitPtr(*root, oldgen, &promoted_objects);
    }

    // Phase 2: Cheney's algorithm - scan to-space objects breadth-first.
    // When use_hybrid_dfs is enabled, list spine copying provides locality optimization
    // within scanObject() without requiring a separate DFS stack.
    while (scanHasMore()) {
        void *obj = scan_ptr_;
        scanObject(obj, oldgen, &promoted_objects);
        scan_ptr_ += getObjectSize(obj);
        advanceScanIfNeeded();
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

    // Use cached allocator reference instead of repeated singleton lookup.
    char *heap_base = allocator_->getHeapBase();
    assert(static_cast<char*>(obj) >= heap_base && "Pointer below heap base!");
    assert(static_cast<char*>(obj) < heap_base + allocator_->getHeapReserved() && "Pointer above heap end!");

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
 * Evacuates a JIT root containing a raw 64-bit heap pointer.
 *
 * In JIT mode, globals store full 64-bit heap pointers rather than
 * HPointer-encoded values. This function handles evacuation for such roots.
 *
 * Embedded constants are identified by having zero in the lower 40 bits
 * and a value 1-7 in bits 40-43.
 */
void NurserySpace::evacuateJitPtr(uint64_t &ptr, OldGenSpace &oldgen, std::vector<void*> *promoted_objects) {
    // Check for embedded constants: lower 40 bits = 0, bits 40-43 = 1-7.
    uint64_t ptr_part = ptr & 0xFFFFFFFFFFULL;  // Lower 40 bits.
    uint64_t const_part = (ptr >> 40) & 0xF;     // Bits 40-43.

    if (ptr_part == 0 && const_part >= 1 && const_part <= 7) {
        return;  // It's an embedded constant.
    }

    // Treat as raw pointer.
    void *obj = reinterpret_cast<void*>(ptr);
    if (!obj)
        return;

    char *heap_base = allocator_->getHeapBase();

    // Validate pointer is within heap bounds.
    if (static_cast<char*>(obj) < heap_base ||
        static_cast<char*>(obj) >= heap_base + allocator_->getHeapReserved()) {
        // Pointer is outside the heap - could be a foreign pointer or error.
        // For now, skip it to avoid crashes.
        return;
    }

    Header *hdr = getHeader(obj);

    // Check for forwarding pointer.
    if (hdr->tag == Tag_Forward) {
        Forward *fwd = static_cast<Forward *>(obj);
        uintptr_t byte_offset = static_cast<uintptr_t>(fwd->header.forward_ptr) << 3;
        ptr = reinterpret_cast<uint64_t>(heap_base + byte_offset);
        return;
    }

    // Only evacuate if in from-space.
    if (!isInFromSpace(obj))
        return;

    size_t size = getObjectSize(obj);
    void *new_obj = nullptr;

    // Promote to old gen if age >= promotion_age.
    if (hdr->age >= config_->promotion_age) {
        new_obj = oldgen.allocate(size);
        assert(new_obj && "Failed to allocate in old gen during promotion");

        std::memcpy(new_obj, obj, size);

        Header *new_hdr = getHeader(new_obj);
        new_hdr->age = 0;

        if (promoted_objects) {
            promoted_objects->push_back(new_obj);
        }

        GC_STATS_MINOR_INC_PROMOTED(stats);
    }

    // Copy to to_space if not promoted.
    if (!new_obj) {
        new_obj = copyToSpace(size);
        assert(new_obj && "Failed to copy to to-space during evacuation!");

        std::memcpy(new_obj, obj, size);

        Header *new_hdr = getHeader(new_obj);
        new_hdr->age++;

        GC_STATS_MINOR_INC_SURVIVORS(stats);
    }

    // Leave forwarding pointer.
    Forward *fwd = static_cast<Forward *>(obj);
    fwd->header.tag = Tag_Forward;
    uintptr_t byte_offset = static_cast<char *>(new_obj) - heap_base;
    fwd->header.forward_ptr = byte_offset >> 3;
    fwd->header.unused = 0;

    // Update the root with the new raw pointer.
    ptr = reinterpret_cast<uint64_t>(new_obj);
}

/**
 * Scans a heap object and evacuates all its children.
 *
 * Uses standard Cheney's BFS with a locality optimization for lists:
 *   - When use_hybrid_dfs is enabled and a Cons cell's tail is in from-space,
 *     the entire list spine is copied contiguously using two-pass copying.
 *   - Pass 1 (evacuateListSpine): Copies Cons cells by following tail pointers
 *   - Pass 2 (evacuateListHeads): Evacuates heads if any were boxed pointers
 *   - This creates contiguous list spines for better cache locality.
 *
 * All other types use standard BFS evacuation.
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

        // ====== Deep structures: Two-pass spine copying for locality ======
        // Lists form chains; copying spine first keeps cells contiguous.

        case Tag_Cons: {
            Cons *c = static_cast<Cons *>(obj);

            if (config_->use_hybrid_dfs) {
                // Two-pass list copying for optimal locality:
                // Pass 1: Copy the tail spine contiguously
                // Pass 2: Copy heads (only if needed)

                // First evacuate this cell's head
                evacuateUnboxable(c->head, !(hdr->unboxed & 1), oldgen, promoted_objects);

                // Then copy the tail spine if it's in from-space
                if (c->tail.constant == 0) {
                    void* tail_obj = Allocator::fromPointerRaw(c->tail);
                    if (tail_obj && isInFromSpace(tail_obj)) {
                        bool needs_head_pass = false;
                        void* spine_start = evacuateListSpine(c->tail, oldgen, promoted_objects, needs_head_pass);

                        if (needs_head_pass && spine_start) {
                            evacuateListHeads(spine_start, oldgen, promoted_objects);
                        }
                    } else {
                        // Tail not in from-space - just update the pointer if forwarded
                        evacuate(c->tail, oldgen, promoted_objects);
                    }
                }
                // If tail is Nil constant, nothing to do
            } else {
                // Standard BFS: evacuate head and tail normally
                evacuateUnboxable(c->head, !(hdr->unboxed & 1), oldgen, promoted_objects);
                evacuate(c->tail, oldgen, promoted_objects);
            }
            break;
        }

        case Tag_Task: {
            Task *t = static_cast<Task *>(obj);
            // Evacuate all children - no special handling needed.
            // Task chains will be processed via Cheney's BFS.
            evacuate(t->value, oldgen, promoted_objects);
            evacuate(t->callback, oldgen, promoted_objects);
            evacuate(t->kill, oldgen, promoted_objects);
            evacuate(t->task, oldgen, promoted_objects);
            break;
        }

        case Tag_Process: {
            Process *p = static_cast<Process *>(obj);
            // Evacuate all children - no special handling needed.
            // Process subgraphs will be processed via Cheney's BFS.
            evacuate(p->root, oldgen, promoted_objects);
            evacuate(p->stack, oldgen, promoted_objects);
            evacuate(p->mailbox, oldgen, promoted_objects);
            break;
        }

        case Tag_Array: {
            ElmArray *arr = static_cast<ElmArray *>(obj);
            // Scan only the used elements (length), not the full capacity.
            for (u32 i = 0; i < arr->length && i < 64; i++) {
                evacuateUnboxable(arr->elements[i], !(arr->unboxed & (1ULL << i)), oldgen, promoted_objects);
            }
            // Elements beyond index 63 are always treated as boxed pointers.
            for (u32 i = 64; i < arr->length; i++) {
                evacuate(arr->elements[i].p, oldgen, promoted_objects);
            }
            break;
        }

        // Tag_ByteBuffer: No pointers to scan (raw bytes only).
        // Tag_FieldGroup: No pointers to scan (field IDs only).
        // Tag_Int, Tag_Float, Tag_Char, Tag_String: No children.
        default:
            break;
    }
}

// ============================================================================
// List Locality Optimization - Two-Pass Spine Copying
// ============================================================================

/**
 * Copies a list spine (Cons cells only) contiguously in to-space.
 *
 * This function iterates through a linked list via tail pointers, copying
 * each Cons cell to create a contiguous spine in to-space. This provides
 * excellent cache locality when traversing the list later.
 *
 * The function handles:
 *   - Already-forwarded cells (follows the forward, stops copying)
 *   - Promotion to old gen (aged cells go to old gen)
 *   - Non-Cons tails (delegates to regular evacuate)
 *   - Nil terminator (stops iteration)
 *
 * @return Pointer to first copied Cons in to-space, or nullptr if list was empty
 */
void* NurserySpace::evacuateListSpine(HPointer &ptr, OldGenSpace &oldgen,
                                       std::vector<void*> *promoted_objects,
                                       bool &needs_head_pass) {
    needs_head_pass = false;

    if (ptr.constant != 0) {
        return nullptr;  // Nil or other constant - nothing to copy
    }

    void* first_copied = nullptr;
    void* prev_copied = nullptr;
    HPointer current = ptr;
    char* heap_base = allocator_->getHeapBase();

    while (current.constant == 0) {
        void* obj = Allocator::fromPointerRaw(current);
        if (!obj) break;

        Header* hdr = getHeader(obj);

        // Already forwarded? Update pointer and stop - rest of list already copied
        if (hdr->tag == Tag_Forward) {
            Forward* fwd = static_cast<Forward*>(obj);
            uintptr_t byte_offset = static_cast<uintptr_t>(fwd->header.forward_ptr) << 3;
            HPointer forwarded = Allocator::toPointerRaw(heap_base + byte_offset);

            if (prev_copied) {
                // Link previous copied cell to the forwarded location
                Cons* prev_cons = static_cast<Cons*>(prev_copied);
                prev_cons->tail = forwarded;
            } else {
                // First cell was already forwarded
                ptr = forwarded;
            }
            break;
        }

        // Not in from-space? Stop spine copying
        if (!isInFromSpace(obj)) {
            break;
        }

        // Not a Cons? Delegate to regular evacuate and stop
        if (hdr->tag != Tag_Cons) {
            if (prev_copied) {
                Cons* prev_cons = static_cast<Cons*>(prev_copied);
                evacuate(prev_cons->tail, oldgen, promoted_objects);
            } else {
                evacuate(ptr, oldgen, promoted_objects);
            }
            break;
        }

        Cons* cons = static_cast<Cons*>(obj);

        // Check if head needs evacuation (boxed pointer, not a constant)
        bool head_is_boxed = !(hdr->unboxed & 1);
        if (head_is_boxed && cons->head.p.constant == 0) {
            needs_head_pass = true;
        }

        // Save tail before we overwrite the object with forwarding pointer
        HPointer next_tail = cons->tail;

        // Copy this Cons cell (may go to old gen if aged)
        size_t size = sizeof(Cons);
        void* new_obj = nullptr;
        bool promoted = false;

        if (hdr->age >= config_->promotion_age) {
            // Promote to old gen
            new_obj = oldgen.allocate(size);
            assert(new_obj && "Failed to allocate in old gen during list spine copy");
            std::memcpy(new_obj, obj, size);

            Header* new_hdr = getHeader(new_obj);
            new_hdr->age = 0;
            promoted = true;

            if (promoted_objects) {
                promoted_objects->push_back(new_obj);
            }
            GC_STATS_MINOR_INC_PROMOTED(stats);
        } else {
            // Copy to to-space
            new_obj = copyToSpace(size);
            assert(new_obj && "Failed to copy Cons to to-space during spine copy");
            std::memcpy(new_obj, obj, size);

            Header* new_hdr = getHeader(new_obj);
            new_hdr->age++;
            GC_STATS_MINOR_INC_SURVIVORS(stats);
        }

        // Leave forwarding pointer at original location
        Forward* fwd = static_cast<Forward*>(obj);
        fwd->header.tag = Tag_Forward;
        fwd->header.forward_ptr = (static_cast<char*>(new_obj) - heap_base) >> 3;
        fwd->header.unused = 0;

        // Link previous cell to this new cell
        if (prev_copied) {
            Cons* prev_cons = static_cast<Cons*>(prev_copied);
            prev_cons->tail = Allocator::toPointerRaw(new_obj);
        } else {
            // This is the first cell - update the original pointer
            first_copied = new_obj;
            ptr = Allocator::toPointerRaw(new_obj);
        }

        prev_copied = new_obj;
        current = next_tail;
    }

    // Handle Nil terminator or end of list - update last cell's tail
    if (prev_copied && current.constant != 0) {
        Cons* prev_cons = static_cast<Cons*>(prev_copied);
        prev_cons->tail = current;  // Keep the Nil constant
    }

    return first_copied;
}

/**
 * Evacuates heads of a previously-copied list spine.
 *
 * This is Pass 2 of the two-pass list copying algorithm. It iterates through
 * the already-copied spine in to-space and evacuates each head that contains
 * a boxed pointer (not unboxed, not a constant).
 *
 * This function should only be called if evacuateListSpine() set needs_head_pass
 * to true, indicating that at least one head requires evacuation.
 */
void NurserySpace::evacuateListHeads(void* first_cons, OldGenSpace &oldgen,
                                      std::vector<void*> *promoted_objects) {
    if (!first_cons) return;

    void* current = first_cons;

    while (current) {
        // Verify we're still looking at a Cons cell in to-space or old gen
        Header* hdr = getHeader(current);
        if (hdr->tag != Tag_Cons) break;

        Cons* cons = static_cast<Cons*>(current);

        // Evacuate head if it's boxed
        bool head_is_boxed = !(hdr->unboxed & 1);
        if (head_is_boxed) {
            evacuate(cons->head.p, oldgen, promoted_objects);
        }

        // Move to next cell in spine
        if (cons->tail.constant != 0) {
            break;  // Reached Nil or other constant
        }

        void* next = Allocator::fromPointerRaw(cons->tail);

        // Stop if we've left the contiguous region we just copied
        // (tail might point to something copied earlier or in old gen)
        if (!next || (!isInToSpace(next) && !oldgen.contains(next))) {
            break;
        }

        current = next;
    }
}

} // namespace Elm
