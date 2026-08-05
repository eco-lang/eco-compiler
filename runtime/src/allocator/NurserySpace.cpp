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
#include "PermanentSpace.hpp"
#include "ThreadLocalHeap.hpp"
#include <algorithm>
#include <cassert>
#include <cstdio>
#include <cstring>
#if ECO_HEAP_VALIDATE
// Used by debugAssertValidNurseryPointer's diagnostic (prints a backtrace).
// musl (Stage B static build) ships no <execinfo.h>; stub as no-ops there.
#if defined(__has_include) && __has_include(<execinfo.h>)
#  include <execinfo.h>
#else
[[maybe_unused]] static inline int backtrace(void**, int) { return 0; }
[[maybe_unused]] static inline char** backtrace_symbols(void* const*, int) { return nullptr; }
[[maybe_unused]] static inline void backtrace_symbols_fd(void* const*, int, int) {}
#endif
#endif

#if ECO_HEAP_VALIDATE
// Track which heap object is currently being scanned during Cheney scan,
// so stale-pointer diagnostics can identify the parent object.
thread_local void* g_scan_parent = nullptr;
thread_local int g_scan_tag = -1;
thread_local Elm::u32 g_scan_size = 0;
#endif

namespace Elm {

NurserySpace::NurserySpace() :
    config_(nullptr), allocator_(nullptr), block_size_(0), from_is_low_(true),
    low_base_(nullptr), low_end_(nullptr), high_base_(nullptr), high_end_(nullptr),
    current_from_idx_(0), bump_{nullptr, nullptr},
    current_to_idx_(0), copy_ptr_(nullptr), copy_end_(nullptr),
    scan_block_idx_(0), scan_ptr_(nullptr),
    growth_threshold_(NURSERY_GROWTH_THRESHOLD),
    gc_threshold_(0.0f), from_capacity_bytes_(0), threshold_total_bytes_(0),
    thread_heap_(nullptr) {
    // Initialization happens in initialize() method.
}

NurserySpace::~NurserySpace() {
    // Return our blocks to the allocator's free-list so a subsequent
    // ThreadLocalHeap (e.g. a freshly-spawned task) can reuse the committed
    // address-space slots. Without this, each spawn grows
    // `nursery_{low,high}_committed_` monotonically and the nursery region
    // exhausts under spawn-heavy workloads (see Issue #40).
    if (allocator_) {
        for (char* block : low_blocks_) {
            allocator_->releaseNurseryBlockLow(block, block_size_);
        }
        for (char* block : high_blocks_) {
            allocator_->releaseNurseryBlockHigh(block, block_size_);
        }
    }
}

void NurserySpace::initialize(Allocator* allocator, const HeapConfig* config) {
    config_ = config;
    allocator_ = allocator;
    thread_heap_ = nullptr;  // Legacy single-threaded mode (not using ThreadLocalHeap).
    block_size_ = config->alloc_buffer_size;
    growth_threshold_ = config->nursery_growth_threshold;
    gc_threshold_ = config->nursery_gc_threshold;

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
    refreshCapacityCaches();
    bump_.ptr = low_blocks_[0];
    bump_.end = computeAllocEndForBlock(low_blocks_[0]);

#if ENABLE_GC_STATS
    stats.nursery_size_bytes =
        (low_blocks_.size() + high_blocks_.size()) * block_size_;
#endif
}

void NurserySpace::initialize(ThreadLocalHeap* heap, const HeapConfig* config) {
    config_ = config;
    thread_heap_ = heap;
    allocator_ = heap->getParent();  // Reference to Allocator for block acquisition during growth.
    block_size_ = config->alloc_buffer_size;
    growth_threshold_ = config->nursery_growth_threshold;
    gc_threshold_ = config->nursery_gc_threshold;

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
    refreshCapacityCaches();
    bump_.ptr = low_blocks_[0];
    bump_.end = computeAllocEndForBlock(low_blocks_[0]);

#if ENABLE_GC_STATS
    stats.nursery_size_bytes =
        (low_blocks_.size() + high_blocks_.size()) * block_size_;
#endif
}

void NurserySpace::reset(OldGenSpace &oldgen, const HeapConfig* new_config) {
    // Update config if provided.
    if (new_config) {
        config_ = new_config;
        block_size_ = new_config->alloc_buffer_size;
        gc_threshold_ = new_config->nursery_gc_threshold;
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
    refreshCapacityCaches();
    bump_.ptr = low_blocks_[0];
    bump_.end = computeAllocEndForBlock(low_blocks_[0]);

    // Reset the root set.
    root_set.reset();

#if ENABLE_GC_STATS
    // GC stats counters are intentionally preserved across reset() (they
    // accumulate over the process lifetime), but the live nursery_size_bytes
    // snapshot must follow the reconfigured block layout.
    stats.nursery_size_bytes =
        (low_blocks_.size() + high_blocks_.size()) * block_size_;
#endif

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

    // Fast path: fits in current block. No wall-clock timing here — the
    // bump-pointer body is too short for `clock_gettime` brackets to be
    // anything but pure overhead (~25% of total CPU on the Stage 7 profile).
    // Slow-path timing is done inside `allocateSlow` below.
    if (bump_.ptr + size <= bump_.end) {
        void* result = bump_.ptr;
        bump_.ptr += size;
        GC_STATS_MINOR_RECORD_ALLOC(stats, size);
        return result;
    }

    // Slow path: needs to advance to the next block (or return nullptr to
    // signal GC). Wall-clock the body so its cost lands in
    // total_nursery_alloc_in_mutator_ns rather than leaking into mutator
    // time. The mutator-only check is correct because nursery_.allocate is
    // never invoked from inside minorGC (promotions go to oldgen.allocate).
    return allocateSlow(size);
}

void* NurserySpace::allocateSlow(size_t size) {
#if ENABLE_GC_STATS
    auto t0 = GC_STATS_TIMER_START();
#endif

    void* result = nullptr;

    std::vector<char*>& from_blocks = from_is_low_ ? low_blocks_ : high_blocks_;

    // The fast path fell through (bump_.ptr + size > bump_.end).
    // `bump_.end` is the earlier of (block end, threshold trip point) —
    // see computeAllocEndForBlock. The disambiguator is `bump_.end <
    // block_end`: that means the threshold cap fired inside this block,
    // and the right action is to signal a minor GC (`result` stays null).
    // Otherwise the block is genuinely exhausted (bump_.end == block_end)
    // and we should advance to the next block.

    char* block_start = from_blocks[current_from_idx_];
    char* block_end = block_start + block_size_;

    if (bump_.end >= block_end) {
        // Block exhausted: try next block in from-space.
        ++current_from_idx_;
        if (current_from_idx_ < from_blocks.size()) {
            bump_.ptr = from_blocks[current_from_idx_];
            bump_.end = computeAllocEndForBlock(bump_.ptr);

            if (bump_.ptr + size <= bump_.end) {
                result = bump_.ptr;
                bump_.ptr += size;
                GC_STATS_MINOR_RECORD_ALLOC(stats, size);
            }
            // Else the new block is also threshold-clamped
            // (bump_.end <= bump_.ptr + size). Signal GC. Note:
            // computeAllocEndForBlock returns block_end once already_full
            // passes threshold_total_bytes_, so this can only happen when
            // the trip point falls exactly on a block boundary or earlier
            // — i.e. legitimately needs a GC.
        }
        // Else no more blocks: signal GC.
    }
    // Else threshold trip inside the current block: signal GC.

#if ENABLE_GC_STATS
    if (!g_in_minor_gc) {
        stats.total_nursery_alloc_in_mutator_ns +=
            GC_STATS_TIMER_ELAPSED_NS(t0);
    }
#endif

    return result;
}

// contains(), isInFromSpace(), isInToSpace() are now inline in the header.

size_t NurserySpace::bytesAllocated() const {
    const std::vector<char*>& from_blocks = from_is_low_ ? low_blocks_ : high_blocks_;
    size_t bytes = current_from_idx_ * block_size_;
    if (current_from_idx_ < from_blocks.size()) {
        bytes += static_cast<size_t>(bump_.ptr - from_blocks[current_from_idx_]);
    }
    return bytes;
}

void NurserySpace::refreshCapacityCaches() {
    const std::vector<char*>& from_blocks = from_is_low_ ? low_blocks_ : high_blocks_;
    from_capacity_bytes_ = from_blocks.size() * block_size_;
    threshold_total_bytes_ =
        static_cast<size_t>(static_cast<double>(from_capacity_bytes_) * gc_threshold_);
}

char* NurserySpace::computeAllocEndForBlock(char* block_start) const {
    char* block_end = block_start + block_size_;
    size_t already_full = current_from_idx_ * block_size_;
    if (already_full >= threshold_total_bytes_) {
        // The threshold has already been crossed by survivors of a prior
        // GC. Tripping the threshold again before this block fills cannot
        // free any new space (no allocations have happened since the GC
        // that produced these survivors), so re-engaging it would only
        // GC-loop. Fail soft: use the full block, and let the next
        // genuine block exhaustion drive the GC. This matches the
        // pre-fold semantics where wouldExceedThreshold was advisory.
        return block_end;
    }
    size_t remaining_to_threshold = threshold_total_bytes_ - already_full;
    if (remaining_to_threshold >= block_size_) {
        return block_end;
    }
    return block_start + remaining_to_threshold;
}

bool NurserySpace::wouldExceedThreshold(size_t size, float /*threshold*/) const {
    return bytesAllocated() + ((size + 7) & ~7) >= threshold_total_bytes_;
}

void* NurserySpace::copyToSpace(size_t size) {
    // Fast path: fits in current to-space block.
    if (copy_ptr_ + size <= copy_end_) {
        void* result = copy_ptr_;
        copy_ptr_ += size;
        return result;
    }

    std::vector<char*>& to_blocks = from_is_low_ ? high_blocks_ : low_blocks_;

    // Record end-of-objects for the block we're abandoning so the Cheney scan
    // can stop before the uninitialised tail gap. Without this, the scan
    // reads stale pre-GC bytes here as if they were a live object header.
    block_end_of_objects_[current_to_idx_] = copy_ptr_;

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

    // For blocks that copyToSpace has already abandoned, stop at the recorded
    // end-of-objects rather than block_end — the remainder is an untouched
    // tail gap that may still hold stale bytes from prior GCs.
    char* scan_block_end = (scan_block_idx_ < current_to_idx_)
        ? block_end_of_objects_[scan_block_idx_]
        : to_blocks[scan_block_idx_] + block_size_;

    if (scan_ptr_ >= scan_block_end) {
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

    // The configured hard cap (nursery_max_block_count) is the total over
    // both semi-spaces; per-side cap is half that. Bail if we've already
    // reached the cap.
    const size_t per_side_cap = config_->nursery_max_block_count / 2;
    const size_t per_side_now = to_blocks.size();  // == low_blocks_.size()
    if (per_side_now >= per_side_cap) {
        return;  // Already at the configured ceiling.
    }
    const size_t per_side_room = per_side_cap - per_side_now;

    // Default policy: grow by 50%. Truncate against per_side_room so the
    // last step before the cap fills the remaining room exactly rather than
    // overshooting (e.g. cap=512, total=500, room=6/side → add 6/side, not
    // the 50% ask of 125/side and not zero).
    size_t blocks_to_add = to_blocks.size() / 2;  // 50% growth.
    if (blocks_to_add < 1) blocks_to_add = 1;
    if (blocks_to_add > per_side_room) {
        blocks_to_add = per_side_room;
    }

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
        std::fprintf(stderr,
            "[grow-check] ABORT asymmetric: low_added=%zu high_added=%zu\n",
            low_added, high_added);
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

    // Both low and high block counts changed; refresh capacity caches so
    // the post-GC bump_.end reflects the new threshold. (from_is_low_ may
    // have just been flipped by the caller — refresh against whichever
    // side is now from-space.)
    refreshCapacityCaches();

#if ENABLE_GC_STATS
    stats.nursery_grow_events++;
    stats.nursery_size_bytes =
        (low_blocks_.size() + high_blocks_.size()) * block_size_;
#endif

    if (Allocator::heapTraceEnabled()) {
        std::fprintf(stderr,
            "[heap-trace] nursery grew: +%zu low blocks, +%zu high blocks "
            "(now %zu/%zu, block_size=%zu KB, semi-space=%.2f MB)\n",
            low_added, high_added, low_blocks_.size(), high_blocks_.size(),
            block_size_ / 1024,
            (low_blocks_.size() * block_size_) / (1024.0 * 1024.0));
    }
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
 * Note on old→young pointers: Elm's immutability guarantees no old→nursery
 * pointers can exist. An object can only reference values that already existed
 * when it was created, so any object's children are always at least as old as
 * the object itself. When a nursery object reaches promotion_age, all of its
 * transitively-reachable children must also have reached promotion_age and are
 * promoted together in the same phase-3 scan. The assertion in evacuate() enforces
 * this: if phase 3 ever encounters a from-space child whose age < promotion_age,
 * that is a bug (heap corruption), not a case to handle gracefully.
 */
void NurserySpace::minorGC(OldGenSpace &oldgen, const StackMapRoots& stackmap_roots) {
    // Set the cross-allocator in-minor-GC flag (always on, used by the
    // OldGenSpace::allocate inline-helper attribution counter).
    g_in_minor_gc = true;

    // Flip the split-header body color for this cycle. Every live header
    // scanned in to-space gets recorded with this color via markLargeBodySeen;
    // bodies whose recorded color doesn't match at the end are freed.
    minor_color_ = !minor_color_;

#if ECO_HEAP_VALIDATE
    // Used by stale-pointer detection in `debugAssertValidNurseryPointer`.
    in_minor_gc_ = true;
#endif
#if ECO_GC_DEBUG
    std::fprintf(stderr, "[gc] minorGC start from_is_low=%d\n", (int)from_is_low_);
#endif

#if ECO_HEAP_VALIDATE
    // Class 3: walk every header in from-space's allocated prefix and
    // assert tag/size sanity before evacuation begins. Catches mutator-side
    // header corruption that would otherwise propagate via memcpy.
    preEvacuationFromSpaceWalk();
#endif

#if ENABLE_GC_STATS
    // Capture state before GC.
    size_t from_space_used = bytesAllocated();
    auto gc_start = GC_STATS_TIMER_START();
    // Snapshot the old-gen-alloc-in-minor counter so we can subtract this
    // cycle's old-gen helper work from `elapsed_ns` before recording into
    // the histogram. OldGenSpace::allocate increments this counter every
    // time it runs while g_in_minor_gc is true (set above), regardless of
    // whether actual mark/sweep work happens in that call.
    uint64_t helper_ns_at_start = oldgen.getStats().total_oldgen_alloc_in_minor_ns;
#endif

    std::vector<char*>& to_blocks = from_is_low_ ? high_blocks_ : low_blocks_;

    // Reset to-space allocation - start at first block.
    current_to_idx_ = 0;
    copy_ptr_ = to_blocks[0];
    copy_end_ = to_blocks[0] + block_size_;

    // Reset scan pointers.
    scan_block_idx_ = 0;
    scan_ptr_ = to_blocks[0];

    // Default end-of-objects = block_end for each block. copyToSpace overwrites
    // [i] with the real end when it abandons block i to move to block i+1.
    block_end_of_objects_.resize(to_blocks.size());
    for (size_t i = 0; i < to_blocks.size(); ++i) {
        block_end_of_objects_[i] = to_blocks[i] + block_size_;
    }

    // Buffer for promoted objects that need scanning.
    std::vector<void*> promoted_objects;

    // Phase 1a: Evacuate long-lived roots (may add to promoted_objects).
#if ECO_GC_DEBUG
    std::fprintf(stderr, "[gc] phase 1a: %zu long-lived roots\n", root_set.getRoots().size());
#endif
    for (HPointer *root: root_set.getRoots()) {
        evacuate(*root, oldgen, &promoted_objects);
    }

    // Phase 1b: Evacuate stackmap-derived roots (discovered from LLVM StackMaps).
#if ECO_GC_DEBUG
    std::fprintf(stderr, "[gc] phase 1b: %zu stackmap roots\n", stackmap_roots.get().size());
#endif
    for (HPointer *root: stackmap_roots.get()) {
#if ECO_GC_DEBUG
        uint64_t rv; memcpy(&rv, root, sizeof(rv));
        if (rv == 0x20039995ULL)
            std::fprintf(stderr, "[gc-debug] phase1b: FOUND target 0x20039995 in stackmap root %p\n", (void*)root);
#endif
        evacuate(*root, oldgen, &promoted_objects);
    }

    // Phase 1c: Evacuate JIT roots (raw 64-bit pointers from JIT-compiled globals).
#if ECO_GC_DEBUG
    std::fprintf(stderr, "[gc] phase 1c: %zu jit roots\n", root_set.getJitRoots().size());
#endif
    for (uint64_t *root: root_set.getJitRoots()) {
        evacuateJitPtr(*root, oldgen, &promoted_objects);
    }

    // Phase 1e: Stack root ranges (alloca-backed args arrays from compiled code).
#if ECO_GC_DEBUG
    std::fprintf(stderr, "[gc] phase 1e: %zu stack root ranges\n", root_set.getStackRootRanges().size());
#endif
    for (const auto &range : root_set.getStackRootRanges()) {
        HPointer *base = range.base;
        uint64_t mask  = range.hpointer_mask;
        for (size_t i = 0; i < range.count; ++i) {
            if (mask & (1ULL << i)) {
#if ECO_GC_DEBUG
                uint64_t rv; memcpy(&rv, &base[i], sizeof(rv));
                if (rv == 0x20039995ULL)
                    std::fprintf(stderr, "[gc-debug] phase1e: FOUND target 0x20039995 in stack range %p idx %zu\n",
                                 (void*)base, i);
#endif
                evacuate(base[i], oldgen, &promoted_objects);
            }
        }
    }

    // Phase 1d: External root scanners (Scheduler run queue, PlatformRuntime state, etc.).
#if ECO_GC_DEBUG
    std::fprintf(stderr, "[gc] phase 1d: %zu external scanners\n", root_set.getExternalRootScanners().size());
#endif
    for (auto& scanner : root_set.getExternalRootScanners()) {
        scanner([this, &oldgen, &promoted_objects](uint64_t& ref) {
            evacuateValueSlot(ref, oldgen, &promoted_objects);
        });
    }

#if ECO_GC_DEBUG
    std::fprintf(stderr, "[gc] phase 2: Cheney scan starts\n");
#endif
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
    // By Elm's immutability invariant, every child of a promoted object must be
    // at least as old as the parent and therefore also qualify for promotion.
    // in_phase3_ arms the assertion in evacuate() that catches any violation.
    // Use index-based loop since vector may grow during iteration.
#if ECO_HEAP_VALIDATE
    in_phase3_ = true;
#endif
    // Drain alternately between to-space and the promoted-objects queue
    // until both are empty. Scanning a promoted object can copy YOUNG
    // children into to-space (when the child's age < promotion_age) —
    // Elm's immutability invariant is supposed to forbid this (children of
    // a promoted object should be at least as old as the parent), but
    // kernel-side mutation paths can violate it. Without re-draining,
    // those new to-space objects would never be scanned and their boxed
    // slots would remain pointing at from-space, surfacing as stale refs
    // at the next mutator read. Conversely, scanning a fresh to-space
    // object can promote an aged child, growing the queue further; hence
    // the alternation runs to mutual fixed point.
    size_t promoted_idx = 0;
    while (scanHasMore() || promoted_idx < promoted_objects.size()) {
        while (scanHasMore()) {
            void *obj = scan_ptr_;
            scanObject(obj, oldgen, &promoted_objects);
            scan_ptr_ += getObjectSize(obj);
            advanceScanIfNeeded();
        }
        while (promoted_idx < promoted_objects.size()) {
            scanObject(promoted_objects[promoted_idx++], oldgen, &promoted_objects);
        }
    }
#if ECO_HEAP_VALIDATE
    in_phase3_ = false;
#endif

    // Phase 4: Check occupancy and grow if needed.
    checkAndGrow();

    // Safety net: zero free to-space region to prevent ghost headers from
    // surviving into the next GC cycle. Load-bearing — disabling this
    // produces "Pointer above heap end!" aborts in evacuate when stale
    // bytes in the free tail decode as out-of-range raw pointers. Called
    // after checkAndGrow() so newly added blocks are also zeroed.
    clearToSpaceFreeRegion();

#if ECO_HEAP_VALIDATE
    // Post-GC heap integrity check: walk all surviving objects in to-space
    // and verify every boxed child pointer points outside from-space. A
    // child still in from-space at this point (without a Tag_Forward
    // header) means GC failed to forward it — diagnostic for stale-pointer
    // corruption that would surface as a poisoned-region read at the next
    // mutator phase.
    {
        std::vector<char*>& to = from_is_low_ ? high_blocks_ : low_blocks_;
        for (size_t blk = 0; blk <= current_to_idx_ && blk < to.size(); ++blk) {
            char* scan = to[blk];
            char* end = (blk < current_to_idx_) ? to[blk] + block_size_ : copy_ptr_;
            while (scan < end) {
                Header* h = getHeader(scan);
                auto checkChild = [&](HPointer &hp, const char* desc, int idx) {
                    if (hp.ptr_ind != 0 || hp.ptr == 0) return;
                    void* child = Allocator::fromPointerRaw(hp);
                    if (child && isInFromSpace(child)) {
                        Header* ch = getHeader(child);
                        if (ch->tag != Tag_Forward) {
                            uint64_t raw = 0;
                            memcpy(&raw, &hp, sizeof(raw));
                            std::fprintf(stderr,
                                "[gc-heap-check] STALE CHILD in to-space obj=%p tag=%u size=%u %s[%d] -> raw=0x%lx child=%p child_tag=%u\n",
                                (void*)scan, (unsigned)h->tag, (unsigned)h->size, desc, idx,
                                (unsigned long)raw, child, (unsigned)ch->tag);
                        }
                    }
                };
                switch (h->tag) {
                    case Tag_Cons: {
                        Cons* c = static_cast<Cons*>(static_cast<void*>(scan));
                        if (Elm::tupleFieldKind(h->unboxed, 0) == 0) checkChild(c->head.p, "head", 0);
                        checkChild(c->tail, "tail", 0);
                        break;
                    }
                    case Tag_ConsChunk: {
                        ConsChunk* cv = static_cast<ConsChunk*>(static_cast<void*>(scan));
                        checkChild(cv->backing, "backing", 0);
                        checkChild(cv->next, "next", 1);
                        break;
                    }
                    case Tag_ListBacking: {
                        ListBacking* lb = static_cast<ListBacking*>(static_cast<void*>(scan));
                        if ((h->unboxed & 0x3) == 0) {
                            for (u32 i = lb->hd; i < h->size; i++)
                                checkChild(lb->elems[i].p, "elem", static_cast<int>(i));
                        }
                        break;
                    }
                    case Tag_Tuple2: {
                        Tuple2* t = static_cast<Tuple2*>(static_cast<void*>(scan));
                        if (Elm::tupleFieldKind(h->unboxed, 0) == 0) checkChild(t->a.p, "a", 0);
                        if (Elm::tupleFieldKind(h->unboxed, 1) == 0) checkChild(t->b.p, "b", 1);
                        break;
                    }
                    case Tag_Tuple3: {
                        Tuple3* t = static_cast<Tuple3*>(static_cast<void*>(scan));
                        if (Elm::tupleFieldKind(h->unboxed, 0) == 0) checkChild(t->a.p, "a", 0);
                        if (Elm::tupleFieldKind(h->unboxed, 1) == 0) checkChild(t->b.p, "b", 1);
                        if (Elm::tupleFieldKind(h->unboxed, 2) == 0) checkChild(t->c.p, "c", 2);
                        break;
                    }
                    case Tag_Custom: {
                        Custom* c = static_cast<Custom*>(static_cast<void*>(scan));
                        for (u32 i = 0; i < h->size && i < 24; i++) {
                            if (Elm::fieldKind(c->unboxed, i) == 0)
                                checkChild(c->values[i].p, "custom", i);
                        }
                        break;
                    }
                    case Tag_Record: {
                        Record* r = static_cast<Record*>(static_cast<void*>(scan));
                        for (u32 i = 0; i < h->size && i < 32; i++) {
                            if (Elm::fieldKind(r->unboxed, i) == 0)
                                checkChild(r->values[i].p, "record", i);
                        }
                        break;
                    }
                    case Tag_Closure: {
                        Closure* cl = static_cast<Closure*>(static_cast<void*>(scan));
                        for (u32 i = 0; i < h->size; i++) {
                            if (Elm::fieldKind(cl->unboxed, i) == 0)
                                checkChild(cl->values[i].p, "closure", i);
                        }
                        break;
                    }
                    case Tag_DynRecord: {
                        DynRecord* dr = static_cast<DynRecord*>(static_cast<void*>(scan));
                        checkChild(dr->fieldgroup, "fieldgroup", 0);
                        for (u32 i = 0; i < h->size; i++)
                            checkChild(dr->values[i], "dynrec", i);
                        break;
                    }
                    case Tag_StringSlice: {
                        ElmStringSlice* slc = static_cast<ElmStringSlice*>(static_cast<void*>(scan));
                        checkChild(slc->base, "slice-base", 0);
                        break;
                    }
                    case Tag_StringUtf8View: {
                        ElmStringUtf8View* v = static_cast<ElmStringUtf8View*>(static_cast<void*>(scan));
                        checkChild(v->base, "utf8view-base", 0);
                        break;
                    }
                    case Tag_ByteBufferSlice: {
                        ElmByteBufferSlice* slc = static_cast<ElmByteBufferSlice*>(static_cast<void*>(scan));
                        checkChild(slc->base, "byte-slice-base", 0);
                        break;
                    }
                    case Tag_StringRope: {
                        ElmStringRope* r = static_cast<ElmStringRope*>(static_cast<void*>(scan));
                        checkChild(r->left, "rope-left", 0);
                        checkChild(r->right, "rope-right", 0);
                        break;
                    }
                    case Tag_Array: {
                        ElmArray* a = static_cast<ElmArray*>(static_cast<void*>(scan));
                        // Only walk when the array claims boxed elements.
                        // For an unboxed-tagged array we have no good way to
                        // tell whether random-looking element bits are real
                        // pointers (false positives), so we trust the kind
                        // tag here and rely on the GC-time kind-mismatch
                        // tripwire (case Tag_Array in evacuate) to flag
                        // arrays whose tag is lying.
                        if ((a->header.unboxed & 0x3) == 0) {
                            for (u32 i = 0; i < a->length; i++)
                                checkChild(a->elements[i].p, "array", static_cast<int>(i));
                        }
                        break;
                    }
                    default: break;
                }
                scan += getObjectSize(scan);
            }
        }
    }

    // Post-GC old-gen integrity check: scan every old-gen object and report
    // any boxed field that still points into (old) from-space.
    {
        // The GC has not yet flipped from_is_low_, so from-space is still the
        // space we just evacuated FROM.  Objects there are garbage / stale.
        auto isInCurrentFromSpace = [this](void* p) -> bool {
            return isInFromSpace(p);
        };

        auto checkOGChild = [&](HPointer &hp, void* parent, const char* field, int idx) {
            if (hp.ptr_ind != 0 || hp.ptr == 0) return;
            void* child = Allocator::fromPointerRaw(hp);
            if (!child) return;
            if (!isInCurrentFromSpace(child)) return;
            // child still points into old from-space — dangling old→nursery pointer
            uint64_t raw = 0;
            memcpy(&raw, &hp, sizeof(raw));
            std::fprintf(stderr,
                "[gc-old-check] OLD-GEN→NURSERY(stale): parent=%p %s[%d] raw=0x%016lx child=%p\n",
                parent, field, idx, (unsigned long)raw, child);
            Header* ph = getHeader(parent);
            Header* ch = getHeader(child);
            std::fprintf(stderr,
                "  parent tag=%u size=%u age=%u  child tag=%u size=%u age=%u\n",
                (unsigned)ph->tag, (unsigned)ph->size, (unsigned)ph->age,
                (unsigned)ch->tag, (unsigned)ch->size, (unsigned)ch->age);
            std::fflush(stderr);
        };

        for (const auto& blk : oldgen.blocks_) {
            char* scan = blk.start;
            char* end  = blk.end_of_objects;
            while (scan < end) {
                Header* h = getHeader(scan);
                if (h->tag == 0 || h->tag > Tag_Forward) {
                    // Uninitialized / swept / header sentinel — skip 8 bytes.
                    scan += 8;
                    continue;
                }
                if (h->tag == Tag_Forward) {
                    scan += 8;
                    continue;
                }
                size_t obj_size = getObjectSize(scan);
                switch (h->tag) {
                    case Tag_Closure: {
                        Closure* cl = static_cast<Closure*>(static_cast<void*>(scan));
                        for (u32 i = 0; i < h->size; i++) {
                            if (Elm::fieldKind(cl->unboxed, i) == 0)
                                checkOGChild(cl->values[i].p, scan, "capture", i);
                        }
                        break;
                    }
                    case Tag_Tuple2: {
                        Tuple2* t = static_cast<Tuple2*>(static_cast<void*>(scan));
                        if (Elm::tupleFieldKind(h->unboxed, 0) == 0) checkOGChild(t->a.p, scan, "a", 0);
                        if (Elm::tupleFieldKind(h->unboxed, 1) == 0) checkOGChild(t->b.p, scan, "b", 1);
                        break;
                    }
                    case Tag_Tuple3: {
                        Tuple3* t = static_cast<Tuple3*>(static_cast<void*>(scan));
                        if (Elm::tupleFieldKind(h->unboxed, 0) == 0) checkOGChild(t->a.p, scan, "a", 0);
                        if (Elm::tupleFieldKind(h->unboxed, 1) == 0) checkOGChild(t->b.p, scan, "b", 1);
                        if (Elm::tupleFieldKind(h->unboxed, 2) == 0) checkOGChild(t->c.p, scan, "c", 2);
                        break;
                    }
                    case Tag_Custom: {
                        Custom* c = static_cast<Custom*>(static_cast<void*>(scan));
                        for (u32 i = 0; i < h->size && i < 24; i++) {
                            if (Elm::fieldKind(c->unboxed, i) == 0)
                                checkOGChild(c->values[i].p, scan, "custom", i);
                        }
                        break;
                    }
                    case Tag_Record: {
                        Record* r = static_cast<Record*>(static_cast<void*>(scan));
                        for (u32 i = 0; i < h->size && i < 32; i++) {
                            if (Elm::fieldKind(r->unboxed, i) == 0)
                                checkOGChild(r->values[i].p, scan, "record", i);
                        }
                        break;
                    }
                    case Tag_Cons: {
                        Cons* c = static_cast<Cons*>(static_cast<void*>(scan));
                        if (Elm::tupleFieldKind(h->unboxed, 0) == 0) checkOGChild(c->head.p, scan, "head", 0);
                        checkOGChild(c->tail, scan, "tail", 0);
                        break;
                    }
                    case Tag_ConsChunk: {
                        ConsChunk* cv = static_cast<ConsChunk*>(static_cast<void*>(scan));
                        checkOGChild(cv->backing, scan, "backing", 0);
                        checkOGChild(cv->next, scan, "next", 1);
                        break;
                    }
                    case Tag_ListBacking: {
                        ListBacking* lb = static_cast<ListBacking*>(static_cast<void*>(scan));
                        if ((h->unboxed & 0x3) == 0) {
                            for (u32 i = lb->hd; i < h->size; i++)
                                checkOGChild(lb->elems[i].p, scan, "elem", static_cast<int>(i));
                        }
                        break;
                    }
                    case Tag_DynRecord: {
                        DynRecord* dr = static_cast<DynRecord*>(static_cast<void*>(scan));
                        checkOGChild(dr->fieldgroup, scan, "fieldgroup", 0);
                        for (u32 i = 0; i < h->size; i++)
                            checkOGChild(dr->values[i], scan, "dynrec", i);
                        break;
                    }
                    case Tag_StringSlice: {
                        ElmStringSlice* slc = static_cast<ElmStringSlice*>(static_cast<void*>(scan));
                        checkOGChild(slc->base, scan, "slice-base", 0);
                        break;
                    }
                    case Tag_StringUtf8View: {
                        ElmStringUtf8View* v = static_cast<ElmStringUtf8View*>(static_cast<void*>(scan));
                        checkOGChild(v->base, scan, "utf8view-base", 0);
                        break;
                    }
                    case Tag_ByteBufferSlice: {
                        ElmByteBufferSlice* slc = static_cast<ElmByteBufferSlice*>(static_cast<void*>(scan));
                        checkOGChild(slc->base, scan, "byte-slice-base", 0);
                        break;
                    }
                    case Tag_StringRope: {
                        ElmStringRope* r = static_cast<ElmStringRope*>(static_cast<void*>(scan));
                        checkOGChild(r->left, scan, "rope-left", 0);
                        checkOGChild(r->right, scan, "rope-right", 0);
                        break;
                    }
                    default: break;
                }
                scan += obj_size;
            }
        }
    }
#endif

#if ECO_HEAP_VALIDATE
    // Class 3: verify block_end_of_objects_ tracking matches a fresh
    // linear walk before the swap.
    verifyToSpaceBlockEndOfObjects();

    // Paired with the assignment at the start of minorGC.
    in_minor_gc_ = false;

    // Stale-pointer diagnostic aid: poison the just-evacuated from-space's
    // allocated bytes BEFORE the swap, so any stale mutator HPointer that
    // still references those bytes lands on recognisable poison (or trips
    // the detector). See poisonOldFromSpaceUsedRegion for details.
    poisonOldFromSpaceUsedRegion();
#endif

    // Phase 5: Swap spaces by flipping which is from/to.
    from_is_low_ = !from_is_low_;

    // The from-space changed; refresh capacity-derived caches before deriving
    // the new bump_.end. (Block counts of the two spaces are kept equal,
    // but we still want from_capacity_bytes_ recomputed against the
    // possibly-new from-blocks vector.)
    refreshCapacityCaches();

    // Reset from-space allocation to continue after survivors.
    // After swap: the old to_blocks (with survivors) is now from-space.
    std::vector<char*>& new_from = from_is_low_ ? low_blocks_ : high_blocks_;
    current_from_idx_ = current_to_idx_;
    bump_.ptr = copy_ptr_;
    if (current_from_idx_ < new_from.size()) {
        bump_.end = computeAllocEndForBlock(new_from[current_from_idx_]);
    }

#if ENABLE_GC_STATS
    // Calculate what happened during this GC.
    size_t to_space_used = 0;
    for (size_t i = 0; i < current_from_idx_ && i < new_from.size(); i++) {
        to_space_used += block_size_;
    }
    if (current_from_idx_ < new_from.size()) {
        to_space_used += (bump_.ptr - new_from[current_from_idx_]);
    }
    size_t bytes_freed = from_space_used > to_space_used ? from_space_used - to_space_used : 0;
    uint64_t elapsed_ns = GC_STATS_TIMER_ELAPSED_NS(gc_start);

    // Subtract the old-gen allocator work that ran during this minor
    // cycle so the histogram and per-cycle min/max/avg reflect pure
    // nursery-copy time. The aggregate is preserved via
    // GCStats::total_oldgen_alloc_in_minor_ns.
    uint64_t helper_ns_this_cycle =
        oldgen.getStats().total_oldgen_alloc_in_minor_ns - helper_ns_at_start;
    uint64_t pure_elapsed_ns = (elapsed_ns > helper_ns_this_cycle)
                                   ? elapsed_ns - helper_ns_this_cycle
                                   : 0;
    GC_STATS_MINOR_RECORD_GC_END(stats, pure_elapsed_ns, bytes_freed);
#endif

    // Reclaim split-header bodies whose nursery header did not survive this
    // cycle. Skipped if a major GC is mid-cycle (deferred until after major
    // completes). See OldGenSpace::sweepNurseryLargeBodies.
    oldgen.sweepNurseryLargeBodies(minor_color_);

    // Clear the cross-allocator in-minor-GC flag last, after the timer
    // has captured the full minor pause but before control returns to
    // ThreadLocalHeap::minorGC (which may then fire majorGC).
    g_in_minor_gc = false;
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
#if ECO_HEAP_VALIDATE
// U0.5 (borrow-inference Phase 0, plans/borrow-inference-phase0-measurement.md):
// the §16.2 header-preservation obligation. A minor-GC copy/promotion must carry
// the header word — INCLUDING `refcount` [16,30] — verbatim, editing ONLY `color`
// and `age` (D0.4: `pin` is memcpy-preserved, never GC-edited). If a future
// refactor replaces the `std::memcpy` with a field-wise header construction and
// forgets `refcount`, promoted survivors silently reset to refcount 0 =
// "untracked" and RC-1 dies for them. This assertion is that regression tripwire.
// Load-bearing once alloc-site count-init lands (B4); until then `refcount` is
// always 0 (unused) so it is trivially true.
static inline void assertHeaderPreservedAcrossCopy(const Header &src, const Header *dst) {
    assert(dst->tag == src.tag && dst->pin == src.pin &&
           dst->unboxed == src.unboxed && dst->refcount == src.refcount &&
           dst->builder == src.builder && dst->size == src.size &&
           "HEAP: minor-GC copy/promotion must preserve header modulo age/color (U0.5/§16.2)");
    // `color` and `age` are the ONLY fields GC legitimately edits on a copy (D0.4).
}
#endif

void NurserySpace::evacuate(HPointer &ptr, OldGenSpace &oldgen, std::vector<void*> *promoted_objects) {
    if (ptr.ptr_ind != 0)
        return;  // It's a constant.
    if (ptr.ptr == 0)
        return;  // Null/zero HPointer (e.g. unfilled closure capture slot).

    void *obj = Allocator::fromPointerRaw(ptr);
    if (!obj)
        return;

#if ECO_HEAP_VALIDATE
    if (contains(obj)) {
        debugAssertValidNurseryPointer(obj);
    }
#endif

    // Use cached allocator reference instead of repeated singleton lookup.
    // Non-heap addresses are legal since HEAP_036: permanent-space objects
    // (immortal, closed, GC-invisible) may be referenced from anywhere and
    // need no evacuation. The former hard bounds asserts survive as a
    // permanent-aware tripwire in validator builds (out-of-range garbage
    // still aborts there).
    char *heap_base = allocator_->getHeapBase();
    if (static_cast<char*>(obj) < heap_base ||
        static_cast<char*>(obj) >= heap_base + allocator_->getHeapReserved()) {
#if ECO_HEAP_VALIDATE
        if (!PermanentSpace::instance().contains(obj)) {
            std::fprintf(stderr,
                "[gc-debug] evacuate: pointer outside heap AND permanent "
                "space: %p\n", obj);
            std::abort();
        }
#endif
        return;
    }

    // First priority: Check if this location has a forward pointer.
    // This must happen BEFORE the from-space check so that pointers from
    // old-gen objects can be updated even when pointing to from-space.
    Header *hdr = getHeader(obj);

    // Assert tag is valid.
#if ECO_HEAP_VALIDATE
    if (hdr->tag > Tag_Forward) {
        uint64_t raw_hptr;
        memcpy(&raw_hptr, &ptr, sizeof(raw_hptr));
        std::fprintf(stderr,
            "[gc-debug] INVALID TAG in evacuate: obj=%p tag=%u (max=%u)\n"
            "  hptr raw=0x%016lx constant=%u\n"
            "  header raw=0x%016lx\n"
            "  obj in from-space=%d obj in nursery=%d\n",
            obj, (unsigned)hdr->tag, (unsigned)Tag_Forward,
            (unsigned long)raw_hptr, (unsigned)ptr.constant,
            (unsigned long)*(uint64_t*)((char*)obj - 8),
            (int)isInFromSpace(obj), (int)contains(obj));
        uint64_t* w = reinterpret_cast<uint64_t*>(obj);
        for (int i = -2; i < 6; i++) {
            std::fprintf(stderr, "  obj[%d] = 0x%016lx\n", i, w[i]);
        }
        std::fflush(stderr);
        void* bt[40];
        int n = backtrace(bt, 40);
        backtrace_symbols_fd(bt, n, fileno(stderr));
        if (g_scan_parent) {
            std::fprintf(stderr, "  SCAN PARENT: obj=%p tag=%d size=%u\n",
                         g_scan_parent, g_scan_tag, (unsigned)g_scan_size);
            uint64_t* pw = reinterpret_cast<uint64_t*>(g_scan_parent);
            for (int x = 0; x < (int)g_scan_size + 3 && x < 12; x++) {
                std::fprintf(stderr, "  parent[%d] = 0x%016lx\n", x, pw[x]);
            }
        }
    }
#endif
    assert(hdr->tag <= Tag_Forward && "Invalid tag value!");
    if (hdr->tag == Tag_Forward) {
        // Follow forward pointer and update ptr.
        Forward *fwd = static_cast<Forward *>(obj);
        char* tgt = decodeForwardPtr(fwd->header.forward_ptr, heap_base);
#if ECO_HEAP_VALIDATE
        // Class 3: forward-chain depth must be exactly 1. The target of a
        // Tag_Forward must itself be a real (not Tag_Forward) object —
        // otherwise we have a chain that indicates double evacuation or
        // corrupted forwarding.
        {
            assert(tgt >= heap_base &&
                   tgt < heap_base + allocator_->getHeapReserved() &&
                   "forward target outside heap");
            Header* tgthdr = getHeader(tgt);
            if (tgthdr->tag == Tag_Forward) {
                std::fprintf(stderr,
                    "[gc-debug] FORWARD CHAIN DEPTH > 1: obj=%p -> %p (tag=%u)\n",
                    obj, (void*)tgt, (unsigned)tgthdr->tag);
                std::fflush(stderr);
                std::abort();
            }
        }
#endif
        ptr = Allocator::toPointerRaw(tgt);
        return;
    }

    // Second priority: Only evacuate if in from-space (not to-space!).
    // This prevents creating forwarding chains by re-evacuating already-moved objects.
    if (!isInFromSpace(obj))
        return;

    // Now proceed with evacuation (object is in from-space and not yet forwarded).

    size_t size = getObjectSize(obj);
#if ECO_HEAP_VALIDATE
    // U0.5: snapshot the source header before any copy/mutation, so each copy
    // path can assert §16.2 header preservation at its tail.
    const Header srcHdr = *hdr;
#endif
    void *new_obj = nullptr;

    // Promote to old gen iff age has reached promotion_age AND neither pin
    // nor builder forbids it. `builder == 1` keeps in-construction objects
    // (e.g. JsArray result arrays under indexedMap/initialize) pinned to
    // the nursery so kernel slot writes never produce old-gen→young edges
    // (HEAP_BUILDER_001/002). `pin` is orthogonal: pin forbids relocation,
    // builder forbids promotion.
    if (hdr->age >= config_->promotion_age && !hdr->pin && !hdr->builder) {
        // Direct allocation to old gen (simplified - no TLAB buffering).
        new_obj = oldgen.allocate(size);
        assert(new_obj && "Failed to allocate in old gen during promotion");

        std::memcpy(new_obj, obj, size);

        Header *new_hdr = getHeader(new_obj);
        new_hdr->age = 0;
        // Defensive: major GC must not write into nursery headers (see
        // OldGenSpace::pushMarkRoot / incrementalMark), so the source cell's
        // color should already be White. Reset anyway to keep the promotion
        // path independent of that invariant.
        new_hdr->color = static_cast<u32>(Color::White);
#if ECO_HEAP_VALIDATE
        assertHeaderPreservedAcrossCopy(srcHdr, new_hdr);
#endif

        // Split-header forms transfer body ownership from nursery_owned to
        // major-GC-managed on promotion (HEAP_026).
        if (new_hdr->tag == Tag_LargeStringHeader) {
            LargeStringHeader* h = static_cast<LargeStringHeader*>(new_obj);
            oldgen.promoteLargeHeader(h->body);
        } else if (new_hdr->tag == Tag_LargeByteHeader) {
            LargeByteHeader* h = static_cast<LargeByteHeader*>(new_obj);
            oldgen.promoteLargeHeader(h->body);
        }

        if (promoted_objects) {
            promoted_objects->push_back(new_obj);
        }

        GC_STATS_MINOR_INC_PROMOTED(stats, new_hdr->tag, size, new_hdr->size);
    }

    // Copy to to_space if not promoted.
    if (!new_obj) {
#if ECO_HEAP_VALIDATE
        // Elm's immutability invariant: every child of a promoted object must be
        // at least as old as the parent, so it must also qualify for promotion.
        // If we reach here during phase 3 it means the invariant is violated.
        if (in_phase3_) {
            std::fprintf(stderr,
                "[gc-debug] INVARIANT VIOLATION: phase 3 child not old enough to promote!\n"
                "  child obj=%p tag=%u age=%u builder=%u promotion_age=%u\n",
                obj, (unsigned)hdr->tag, (unsigned)hdr->age,
                (unsigned)hdr->builder, (unsigned)config_->promotion_age);
            uint64_t raw_hptr;
            memcpy(&raw_hptr, &ptr, sizeof(raw_hptr));
            std::fprintf(stderr, "  child hptr raw=0x%016lx\n", (unsigned long)raw_hptr);
            if (g_scan_parent) {
                Header *phdr = getHeader(g_scan_parent);
                std::fprintf(stderr,
                    "  parent(old-gen) obj=%p tag=%u size=%u age=%u\n",
                    g_scan_parent, g_scan_tag, (unsigned)g_scan_size,
                    (unsigned)phdr->age);
                uint64_t *pw = reinterpret_cast<uint64_t*>(g_scan_parent);
                for (int x = -1; x < (int)g_scan_size + 2 && x < 10; x++) {
                    std::fprintf(stderr, "  parent[%d] = 0x%016lx\n", x, pw[x]);
                }
            }
            std::fflush(stderr);
            void *bt[40];
            int n = backtrace(bt, 40);
            backtrace_symbols_fd(bt, n, fileno(stderr));
            // A builder bit reaching this point means a kernel published a
            // builder object into a parent that was already old enough to
            // promote — HEAP_BUILDER_003 was violated.
            assert(!hdr->builder && "Elm invariant: builder object reached as child of promoted parent (HEAP_BUILDER_003)");
            assert(false && "Elm invariant: child of promoted object has age < promotion_age");
        }
#endif
        // Allocate in to_space.
        new_obj = copyToSpace(size);
        assert(new_obj && "Failed to copy to to-space during evacuation!");

        // Copy the object with its padding to maintain alignment.
        std::memcpy(new_obj, obj, size);

        Header *new_hdr = getHeader(new_obj);
        // HEAP_BUILDER_002: while builder == 1, age must remain 0. Skip the
        // increment so the invariant holds across minor cycles. Once the
        // kernel calls clear_builder, the cell ages from 0 like a fresh
        // allocation.
        if (!new_hdr->builder) {
            new_hdr->age++;
        }
        // Defensive (see promotion path above).
        new_hdr->color = static_cast<u32>(Color::White);
#if ECO_HEAP_VALIDATE
        assert(!(new_hdr->builder && new_hdr->age != 0) &&
               "HEAP_BUILDER_002: builder objects must have age == 0");
        assertHeaderPreservedAcrossCopy(srcHdr, new_hdr);
#endif

        GC_STATS_MINOR_INC_SURVIVORS(stats, new_hdr->tag, size, new_hdr->size);
    }

    // Leave forwarding pointer (as logical offset).
    // IMPORTANT: Set this BEFORE evacuating children to prevent infinite recursion.
    Forward *fwd = static_cast<Forward *>(obj);
    fwd->header.tag = Tag_Forward;
    fwd->header.forward_ptr = encodeForwardPtr(new_obj, heap_base);
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
    // Skip embedded constants (ptr_ind set); only real pointers are evacuated.
    if (isConstantBits(ptr)) {
        return;
    }

    // Treat as raw pointer.
    void *obj = reinterpret_cast<void*>(ptr);
    if (!obj)
        return;

#if ECO_HEAP_VALIDATE
    if (contains(obj)) {
        debugAssertValidNurseryPointer(obj);
    }
#endif

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
        ptr = reinterpret_cast<uint64_t>(decodeForwardPtr(fwd->header.forward_ptr, heap_base));
        return;
    }

    // Only evacuate if in from-space.
    if (!isInFromSpace(obj))
        return;

    size_t size = getObjectSize(obj);
#if ECO_HEAP_VALIDATE
    // U0.5: header-preservation tripwire also covers this JIT-root copier.
    const Header srcHdr = *hdr;
#endif
    void *new_obj = nullptr;

    // Promote to old gen iff aged AND not pinned/builder (HEAP_BUILDER_001).
    if (hdr->age >= config_->promotion_age && !hdr->pin && !hdr->builder) {
        new_obj = oldgen.allocate(size);
        assert(new_obj && "Failed to allocate in old gen during promotion");

        std::memcpy(new_obj, obj, size);

        Header *new_hdr = getHeader(new_obj);
        new_hdr->age = 0;
#if ECO_HEAP_VALIDATE
        assertHeaderPreservedAcrossCopy(srcHdr, new_hdr);
#endif

        if (promoted_objects) {
            promoted_objects->push_back(new_obj);
        }

        GC_STATS_MINOR_INC_PROMOTED(stats, new_hdr->tag, size, new_hdr->size);
    }

    // Copy to to_space if not promoted.
    if (!new_obj) {
        new_obj = copyToSpace(size);
        assert(new_obj && "Failed to copy to to-space during evacuation!");

        std::memcpy(new_obj, obj, size);

        Header *new_hdr = getHeader(new_obj);
        // HEAP_BUILDER_002: don't age builders.
        if (!new_hdr->builder) {
            new_hdr->age++;
        }
#if ECO_HEAP_VALIDATE
        assertHeaderPreservedAcrossCopy(srcHdr, new_hdr);
#endif

        GC_STATS_MINOR_INC_SURVIVORS(stats, new_hdr->tag, size, new_hdr->size);
    }

    // Leave forwarding pointer.
    Forward *fwd = static_cast<Forward *>(obj);
    fwd->header.tag = Tag_Forward;
    fwd->header.forward_ptr = encodeForwardPtr(new_obj, heap_base);
    fwd->header.unused = 0;

    // Update the root with the new raw pointer.
    ptr = reinterpret_cast<uint64_t>(new_obj);
}

void NurserySpace::evacuateValueSlot(uint64_t &encoded, OldGenSpace &oldgen,
                                     std::vector<void*> *promoted_objects) {
    HPointer &hp = reinterpret_cast<HPointer&>(encoded);
    // Constants (constant != 0) are non-heap per HEAP_010/014.
    if (hp.ptr_ind != 0) {
        return;
    }
    evacuate(hp, oldgen, promoted_objects);
    // evacuate updates hp in place; encoded now holds relocated HPointer bits.
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
#if ECO_HEAP_VALIDATE
// Class 2 bitmap-mismatch tripwire. Called per slot during scanObject for
// every bitmap-bearing container (Cons, Tuple2/3, Custom, Record, Closure,
// DynRecord). When the bitmap claims a slot is unboxed, the slot's bits
// must NOT decode to a live in-from-space-allocated address — that would
// mean the kind tag is lying and the GC will leave a real boxed pointer
// un-forwarded. Trip immediately with a backtrace naming the parent
// container so the mutator path that mis-tagged it can be identified.
//
// **Currently disabled.** Audit found a fundamental false-positive class:
// for any slot legitimately holding an Int (e.g. record field `c : Int`),
// random int32 values often have low-40-bit patterns that decode to
// addresses inside the live nursery. Filtering by target-header tag
// (must be > Tag_Char) reduces but does not eliminate the rate. Keeping
// the helper in source for future re-enable behind a stricter check
// (e.g. requiring the target object to also have plausible body bytes).
static inline void validateBitmapSlotKind(NurserySpace* /*self*/,
                                          char* /*heap_base*/,
                                          uintptr_t /*heap_reserved*/,
                                          Unboxable /*slot*/,
                                          bool /*is_boxed*/,
                                          void* /*parent*/,
                                          uint32_t /*parent_tag*/,
                                          const char* /*container*/,
                                          uint32_t /*idx*/) {
    return;  // disabled — see comment above
}

// Reference implementation, kept for documentation. Not invoked.
[[maybe_unused]] static inline void validateBitmapSlotKindStrict(
    NurserySpace* self,
    char* heap_base,
    uintptr_t heap_reserved,
    Unboxable slot,
    bool is_boxed,
    void* parent,
    uint32_t parent_tag,
    const char* container,
    uint32_t idx) {
    if (is_boxed) return;
    HPointer hp = slot.p;
    if (hp.ptr_ind != 0 || hp.ptr == 0) return;
    char* tgt = static_cast<char*>(hpToAddr(hp));
    if (tgt < heap_base || tgt >= heap_base + heap_reserved) return;
    if (!self->isInFromSpaceAllocatedRegion(tgt)) return;

    // Target-header sanity check: real HPointers point at an object whose
    // header has a plausible tag and non-zero size. We exclude Tag_Int /
    // Tag_Float / Tag_Char because primitive boxes are dense in the
    // nursery and an unboxed Int slot can easily land coincidentally on a
    // Tag_Int header — a confirmed false-positive case
    // (BytesRoundtripMixedRecord.elm Record[2] = `c: Int`). The remaining
    // tags (Cons, Tuple, Custom, Record, DynRecord, FieldGroup, Closure,
    // Process, Task, ByteBuffer, Array, StringRope/Slice, etc.) have
    // distinctive layouts that are much less likely to be hit by random
    // Int bit patterns, so a trip there is strong evidence of a real
    // wrong-bitmap bug.
    Header* tgt_hdr = getHeader(tgt);
    if (tgt_hdr->tag <= Tag_Char) return;          // primitive coincidence
    if (tgt_hdr->tag > Tag_Forward) return;
    if (tgt_hdr->size == 0) return;
    if (tgt_hdr->size > 0x10000) return;

    std::fprintf(stderr,
        "[gc-debug] %s KIND-MISMATCH at parent=%p tag=%u %s[%u]: "
        "slot tagged unboxed but bits decode to a live from-space "
        "target %p (tgt tag=%u size=%u) — element will not be "
        "forwarded.\n",
        container, parent, parent_tag, container, idx, tgt,
        (unsigned)tgt_hdr->tag, (unsigned)tgt_hdr->size);
    std::fflush(stderr);
    std::abort();
}
#endif

void NurserySpace::scanObject(void *obj, OldGenSpace &oldgen, std::vector<void*> *promoted_objects) {
    Header *hdr = getHeader(obj);
#if ECO_HEAP_VALIDATE
    g_scan_parent = obj;
    g_scan_tag = hdr->tag;
    g_scan_size = hdr->size;
    char* hbase = Allocator::instance().getHeapBase();
    uintptr_t hres = Allocator::instance().getHeapReserved();
#endif
    // Process children based on tag.
    switch (hdr->tag) {
        // ====== Wide structures: BFS (inline evacuation) ======
        // These have multiple fields accessed together; keep siblings contiguous.

        case Tag_Tuple2: {
            Tuple2 *t = static_cast<Tuple2 *>(obj);
            bool ka = Elm::tupleFieldKind(hdr->unboxed, 0) == 0;
            bool kb = Elm::tupleFieldKind(hdr->unboxed, 1) == 0;
#if ECO_HEAP_VALIDATE
            validateBitmapSlotKind(this, hbase, hres, t->a, ka, obj, hdr->tag, "Tuple2", 0);
            validateBitmapSlotKind(this, hbase, hres, t->b, kb, obj, hdr->tag, "Tuple2", 1);
#endif
            evacuateUnboxable(t->a, ka, oldgen, promoted_objects);
            evacuateUnboxable(t->b, kb, oldgen, promoted_objects);
            break;
        }
        case Tag_Tuple3: {
            Tuple3 *t = static_cast<Tuple3 *>(obj);
            bool ka = Elm::tupleFieldKind(hdr->unboxed, 0) == 0;
            bool kb = Elm::tupleFieldKind(hdr->unboxed, 1) == 0;
            bool kc = Elm::tupleFieldKind(hdr->unboxed, 2) == 0;
#if ECO_HEAP_VALIDATE
            validateBitmapSlotKind(this, hbase, hres, t->a, ka, obj, hdr->tag, "Tuple3", 0);
            validateBitmapSlotKind(this, hbase, hres, t->b, kb, obj, hdr->tag, "Tuple3", 1);
            validateBitmapSlotKind(this, hbase, hres, t->c, kc, obj, hdr->tag, "Tuple3", 2);
#endif
            evacuateUnboxable(t->a, ka, oldgen, promoted_objects);
            evacuateUnboxable(t->b, kb, oldgen, promoted_objects);
            evacuateUnboxable(t->c, kc, oldgen, promoted_objects);
            break;
        }
        case Tag_Custom: {
            Custom *c = static_cast<Custom *>(obj);
            for (u32 i = 0; i < hdr->size && i < 24; i++) {
                bool kib = Elm::fieldKind(c->unboxed, i) == 0;
#if ECO_HEAP_VALIDATE
                validateBitmapSlotKind(this, hbase, hres, c->values[i], kib, obj, hdr->tag, "Custom", i);
#endif
                evacuateUnboxable(c->values[i], kib, oldgen, promoted_objects);
            }
            break;
        }
        case Tag_Record: {
            Record *r = static_cast<Record *>(obj);
            for (u32 i = 0; i < hdr->size && i < 32; i++) {
                bool kib = Elm::fieldKind(r->unboxed, i) == 0;
#if ECO_HEAP_VALIDATE
                validateBitmapSlotKind(this, hbase, hres, r->values[i], kib, obj, hdr->tag, "Record", i);
#endif
                evacuateUnboxable(r->values[i], kib, oldgen, promoted_objects);
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
            for (u32 i = 0; i < hdr->size; i++) {
                bool is_boxed = Elm::fieldKind(cl->unboxed, i) == 0;
#if ECO_HEAP_VALIDATE
                validateBitmapSlotKind(this, hbase, hres, cl->values[i], is_boxed, obj, hdr->tag, "Closure", i);
#endif
#if ECO_GC_DEBUG
                if (!is_boxed) {
                    // Warn if a "unboxed" slot has a value that looks like a nursery HPointer
                    uint64_t raw; memcpy(&raw, &cl->values[i], sizeof(raw));
                    HPointer hp; memcpy(&hp, &raw, sizeof(hp));
                    if (hp.ptr_ind == 0 && hp.ptr != 0 && raw == 0x20039995ULL)
                        std::fprintf(stderr, "[gc-debug] closure scan: FOUND 0x20039995 in UNBOXED slot! closure=%p idx=%u kind=%llu unboxed=0x%llx\n",
                                     obj, i, (unsigned long long)Elm::fieldKind(cl->unboxed, i),
                                     (unsigned long long)cl->unboxed);
                } else {
                    uint64_t raw; memcpy(&raw, &cl->values[i], sizeof(raw));
                    if (raw == 0x20039995ULL)
                        std::fprintf(stderr, "[gc-debug] closure scan: FOUND 0x20039995 in BOXED slot (should be evacuated): closure=%p idx=%u\n",
                                     obj, i);
                }
#endif
                evacuateUnboxable(cl->values[i], is_boxed, oldgen, promoted_objects);
            }
            break;
        }

        // ====== Deep structures: Two-pass spine copying for locality ======
        // Lists form chains; copying spine first keeps cells contiguous.

        case Tag_Cons: {
            Cons *c = static_cast<Cons *>(obj);
            bool head_boxed = Elm::tupleFieldKind(hdr->unboxed, 0) == 0;
#if ECO_HEAP_VALIDATE
            validateBitmapSlotKind(this, hbase, hres, c->head, head_boxed, obj, hdr->tag, "Cons", 0);
#endif

            if (config_->use_hybrid_dfs) {
                // Two-pass list copying for optimal locality:
                // Pass 1: Copy the tail spine contiguously
                // Pass 2: Copy heads (only if needed)

                // First evacuate this cell's head
                evacuateUnboxable(c->head, head_boxed, oldgen, promoted_objects);

                // Then copy the tail spine if it's in from-space
                if (c->tail.ptr_ind == 0) {
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
                evacuateUnboxable(c->head, head_boxed, oldgen, promoted_objects);
                evacuate(c->tail, oldgen, promoted_objects);
            }
            break;
        }

        // Chunked-list forms (plans/chunked-list-representation.md §6):
        // a view traces its backing + spine continuation; a backing traces
        // its live element range [hd, capacity) only when the uniform kind
        // is boxed (scalar backings are pointer-free). Slots below hd are
        // uninitialized and must never be traced (v1: hd == 0 always).
        case Tag_ConsChunk: {
            ConsChunk *cv = static_cast<ConsChunk *>(obj);
            evacuate(cv->backing, oldgen, promoted_objects);
            evacuate(cv->next, oldgen, promoted_objects);
            break;
        }
        case Tag_ListBacking: {
            if ((hdr->unboxed & 0x3) == 0) {
                ListBacking *lb = static_cast<ListBacking *>(obj);
                for (u32 i = lb->hd; i < hdr->size; i++) {
                    evacuateUnboxable(lb->elems[i], /*is_boxed=*/true, oldgen,
                                      promoted_objects);
                }
            }
            break;
        }

        case Tag_Task: {
            Task *t = static_cast<Task *>(obj);
            // Skip t->value when it carries an unboxed primitive (slot 0 of
            // header.unboxed != 0); only the boxed-payload case has a child.
            if ((t->header.unboxed & 0x3) == 0) {
                evacuate(t->value.p, oldgen, promoted_objects);
            }
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
            bool is_boxed = (arr->header.unboxed & 0x3) == 0;
#if ECO_HEAP_VALIDATE
            // Kind-mismatch tripwire: if the array claims unboxed but its
            // element bit-patterns decode to in-from-space-allocated
            // addresses (real live objects we're about to evacuate), the
            // kind tag is lying — those elements are real boxed pointers
            // that we're about to leave un-forwarded, which is exactly
            // the bug pattern that produces stale-pointer reads after the
            // GC swap. Trip immediately so the GC's caller-frame backtrace
            // names the mutator path that mis-tagged this array.
            if (!is_boxed) {
                char* hbase = Allocator::instance().getHeapBase();
                uintptr_t hres = Allocator::instance().getHeapReserved();
                for (u32 i = 0; i < arr->length; i++) {
                    HPointer hp = arr->elements[i].p;
                    if (hp.ptr_ind != 0 || hp.ptr == 0) continue;
                    char* tgt = static_cast<char*>(hpToAddr(hp));
                    if (tgt < hbase || tgt >= hbase + hres) continue;
                    if (!isInFromSpaceAllocatedRegion(tgt)) continue;
                    // Target-header sanity check (see validateBitmapSlotKind).
                    Header* tgt_hdr = getHeader(tgt);
                    if (tgt_hdr->tag <= Tag_Char) continue;
                    if (tgt_hdr->tag > Tag_Forward) continue;
                    if (tgt_hdr->size == 0 || tgt_hdr->size > 0x10000) continue;
                    fprintf(stderr,
                        "[gc-debug] ARRAY KIND-MISMATCH at arr=%p "
                        "elements[%u]: header.unboxed=%u (claims "
                        "unboxed) but element bits decode to a live "
                        "from-space target %p (tgt tag=%u size=%u) — "
                        "element will not be forwarded.\n",
                        (void*)arr, i,
                        (unsigned)arr->header.unboxed, tgt,
                        (unsigned)tgt_hdr->tag, (unsigned)tgt_hdr->size);
                    std::abort();
                }
            }
#endif
            for (u32 i = 0; i < arr->length; i++) {
                evacuateUnboxable(arr->elements[i], is_boxed, oldgen, promoted_objects);
            }
            break;
        }

        case Tag_StringSlice: {
            ElmStringSlice *slc = static_cast<ElmStringSlice *>(obj);
            evacuate(slc->base, oldgen, promoted_objects);
            break;
        }

        case Tag_StringUtf8View: {
            // Same shape as Tag_StringSlice: the only boxed field is `base`.
            ElmStringUtf8View *v = static_cast<ElmStringUtf8View *>(obj);
            evacuate(v->base, oldgen, promoted_objects);
            break;
        }

        case Tag_ByteBufferSlice: {
            ElmByteBufferSlice *slc = static_cast<ElmByteBufferSlice *>(obj);
            evacuate(slc->base, oldgen, promoted_objects);
            break;
        }

        case Tag_StringRope: {
            ElmStringRope *r = static_cast<ElmStringRope *>(obj);
            evacuate(r->left, oldgen, promoted_objects);
            evacuate(r->right, oldgen, promoted_objects);
            break;
        }

        case Tag_LargeStringHeader: {
            // Body lives in old gen and is never copied. Record that the
            // header is still live for this minor cycle, then return without
            // touching the body HPointer (it stays as-is).
            LargeStringHeader *h = static_cast<LargeStringHeader *>(obj);
            oldgen.markLargeBodySeen(h->body, minor_color_);
            break;
        }

        case Tag_LargeByteHeader: {
            LargeByteHeader *h = static_cast<LargeByteHeader *>(obj);
            oldgen.markLargeBodySeen(h->body, minor_color_);
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

    if (ptr.ptr_ind != 0) {
        return nullptr;  // Nil or other constant - nothing to copy
    }

    void* first_copied = nullptr;
    void* prev_copied = nullptr;
    HPointer current = ptr;
    char* heap_base = allocator_->getHeapBase();

    while (current.ptr_ind == 0) {
        void* obj = Allocator::fromPointerRaw(current);
        if (!obj) break;

        Header* hdr = getHeader(obj);

        // Already forwarded? Update pointer and stop - rest of list already copied
        if (hdr->tag == Tag_Forward) {
            Forward* fwd = static_cast<Forward*>(obj);
            HPointer forwarded = Allocator::toPointerRaw(decodeForwardPtr(fwd->header.forward_ptr, heap_base));

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
        bool head_is_boxed = Elm::tupleFieldKind(hdr->unboxed, 0) == 0;
        if (head_is_boxed && cons->head.p.ptr_ind == 0) {
            needs_head_pass = true;
        }

        // Save tail before we overwrite the object with forwarding pointer
        HPointer next_tail = cons->tail;

        // Copy this Cons cell (may go to old gen if aged)
        size_t size = sizeof(Cons);
#if ECO_HEAP_VALIDATE
        // U0.5: header-preservation tripwire also covers the list-spine copier.
        const Header srcHdr = *hdr;
#endif
        void* new_obj = nullptr;

        // HEAP_BUILDER_001/002: defensively respect pin/builder on Cons,
        // even though no current kernel marks Cons cells as builders.
        if (hdr->age >= config_->promotion_age && !hdr->pin && !hdr->builder) {
            // Promote to old gen
            new_obj = oldgen.allocate(size);
            assert(new_obj && "Failed to allocate in old gen during list spine copy");
            std::memcpy(new_obj, obj, size);

            Header* new_hdr = getHeader(new_obj);
            new_hdr->age = 0;
#if ECO_HEAP_VALIDATE
            assertHeaderPreservedAcrossCopy(srcHdr, new_hdr);
#endif

            if (promoted_objects) {
                promoted_objects->push_back(new_obj);
            }
            GC_STATS_MINOR_INC_PROMOTED(stats, new_hdr->tag, size, new_hdr->size);
        } else {
            // Copy to to-space
            new_obj = copyToSpace(size);
            assert(new_obj && "Failed to copy Cons to to-space during spine copy");
            std::memcpy(new_obj, obj, size);

            Header* new_hdr = getHeader(new_obj);
            if (!new_hdr->builder) {
                new_hdr->age++;
            }
#if ECO_HEAP_VALIDATE
            assertHeaderPreservedAcrossCopy(srcHdr, new_hdr);
#endif
            GC_STATS_MINOR_INC_SURVIVORS(stats, new_hdr->tag, size, new_hdr->size);
        }

        // Leave forwarding pointer at original location
        Forward* fwd = static_cast<Forward*>(obj);
        fwd->header.tag = Tag_Forward;
        fwd->header.forward_ptr = encodeForwardPtr(new_obj, heap_base);
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
    if (prev_copied && current.ptr_ind != 0) {
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
        bool head_is_boxed = Elm::tupleFieldKind(hdr->unboxed, 0) == 0;
        if (head_is_boxed) {
            evacuate(cons->head.p, oldgen, promoted_objects);
        }

        // Move to next cell in spine
        if (cons->tail.ptr_ind != 0) {
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

// ============================================================================
// Ghost-data safety net: clear free to-space after minor GC
// ============================================================================

void NurserySpace::clearToSpaceFreeRegion() {
    std::vector<char*>& to_blocks = from_is_low_ ? high_blocks_ : low_blocks_;
    if (to_blocks.empty() || current_to_idx_ >= to_blocks.size())
        return;

    for (size_t i = current_to_idx_; i < to_blocks.size(); ++i) {
        char* block_start = to_blocks[i];
        char* block_end   = block_start + block_size_;
        char* start       = (i == current_to_idx_) ? copy_ptr_ : block_start;
        if (start < block_end) {
            std::memset(start, 0, static_cast<size_t>(block_end - start));
        }
    }
}

#if ECO_HEAP_VALIDATE
// Stale-pointer diagnostic aid: fill the just-evacuated from-space's
// allocated region with a recognisable poison byte so that any stale
// HPointer the mutator still holds either:
//   (a) trips the per-resolve detector in `debugAssertValidNurseryPointer`
//       (which classifies post-swap to-space as "free"), OR
//   (b) on a path that bypasses Allocator::resolve, dereferences as an
//       obviously-bogus header (tag = 29, > Tag_Forward) and trips the
//       `assert(hdr->tag <= Tag_Forward)` in evacuate.
//
// The 0xDD byte was picked so the resulting HPointer has constant=13
// (out of range for valid embedded constants 0-7) which makes
// NurserySpace::evacuate treat it as a constant and bail early — i.e.
// the poison itself never trips the GC walker on its own, only the
// stale references TO it produce useful diagnostics.
//
// Cost: O(bytes used by the previous mutator phase) per minor GC. Run
// only on the from-space *allocated* prefix, not the entire nursery.
// Compiled in only under ECO_HEAP_VALIDATE — see HeapHelpers.hpp for why.
void NurserySpace::poisonOldFromSpaceUsedRegion() {
    constexpr uint8_t kPoisonByte = 0xDD;
    std::vector<char*>& from_blocks = from_is_low_ ? low_blocks_ : high_blocks_;
    if (from_blocks.empty()) return;

    for (size_t i = 0; i <= current_from_idx_ && i < from_blocks.size(); ++i) {
        char* block_start = from_blocks[i];
        char* block_end   = block_start + block_size_;
        char* end         = (i == current_from_idx_) ? bump_.ptr : block_end;
        if (end > block_start) {
            std::memset(block_start, kPoisonByte,
                        static_cast<size_t>(end - block_start));
        }
    }
}

// ============================================================================
// Class 3 — From-space pre-evacuation walk
// ============================================================================
//
// Walks every header in from-space's allocated prefix at the start of
// minorGC. For each cell, asserts:
//   - tag <= Tag_Forward
//   - obj + getObjectSize(obj) does not overshoot the block-allocated end
// Catches mutator-side header corruption that would otherwise propagate
// into to-space via memcpy in evacuate.

void NurserySpace::preEvacuationFromSpaceWalk() {
    // Restricted to the current from-space block only: prior ("completed")
    // blocks may have tail gaps left by the allocator's slow-path
    // transition (bump_.ptr < bump_.end when an allocation overshoots
    // bump_.end). There's no block_end_of_objects_-style tracking for
    // from-space, so we can't safely linear-walk those tails. The current
    // block ends at bump_.ptr, so it's safe to walk.
    std::vector<char*>& from_blocks = from_is_low_ ? low_blocks_ : high_blocks_;
    if (from_blocks.empty() || current_from_idx_ >= from_blocks.size()) return;

    char* block_start = from_blocks[current_from_idx_];
    char* end = bump_.ptr;
    char* scan = block_start;
    while (scan < end) {
        Header* h = getHeader(scan);
        if (h->tag > Tag_Forward) {
            std::fprintf(stderr,
                "[heap-validate] from-space pre-walk: invalid tag %u at "
                "obj=%p current_block in [%p,%p), header_raw=0x%016lx\n",
                (unsigned)h->tag, (void*)scan,
                (void*)block_start, (void*)end,
                (unsigned long)*(uint64_t*)scan);
            std::fflush(stderr);
            std::abort();
        }
        size_t sz = getObjectSize(scan);
        if (sz == 0 || scan + sz > end) {
            std::fprintf(stderr,
                "[heap-validate] from-space pre-walk: bogus object size "
                "%zu at obj=%p tag=%u current_block in [%p,%p)\n",
                sz, (void*)scan, (unsigned)h->tag,
                (void*)block_start, (void*)end);
            std::fflush(stderr);
            std::abort();
        }
        scan += sz;
    }
}

// ============================================================================
// Class 3 — Block-end-of-objects post-condition audit
// ============================================================================
//
// After evacuation, the Cheney scanner relies on `block_end_of_objects_[i]`
// to know where to stop scanning each "completed" to-space block. Run a
// fresh linear walk and assert the recorded value matches.

void NurserySpace::verifyToSpaceBlockEndOfObjects() {
    std::vector<char*>& to_blocks = from_is_low_ ? high_blocks_ : low_blocks_;
    if (to_blocks.empty()) return;

    for (size_t i = 0; i < current_to_idx_ && i < to_blocks.size(); ++i) {
        char* block_start = to_blocks[i];
        char* recorded    = block_end_of_objects_[i];
        char* scan = block_start;
        char* last_end = block_start;
        while (scan < recorded) {
            Header* h = getHeader(scan);
            if (h->tag > Tag_Forward) {
                std::fprintf(stderr,
                    "[heap-validate] to-space block[%zu] post-walk: invalid "
                    "tag %u at obj=%p\n",
                    i, (unsigned)h->tag, (void*)scan);
                std::fflush(stderr);
                std::abort();
            }
            size_t sz = getObjectSize(scan);
            if (sz == 0) std::abort();
            last_end = scan + sz;
            scan = last_end;
        }
        if (last_end != recorded) {
            std::fprintf(stderr,
                "[heap-validate] to-space block[%zu] end-of-objects "
                "mismatch: recorded=%p actual=%p\n",
                i, (void*)recorded, (void*)last_end);
            std::fflush(stderr);
            std::abort();
        }
    }
}

// ============================================================================
// Stale nursery pointer detection (validator-only)
// ============================================================================

// Common O(log N) lookup over a sorted block list. Returns the index of the
// block containing `p`, or SIZE_MAX if `p` falls outside every block (i.e.
// in an inter-block gap or beyond the highest block). `from_blocks_` and
// `high_blocks_` are kept sorted by initialize()'s std::sort.
static inline size_t findBlockContaining(const std::vector<char*>& blocks,
                                          char* p, size_t block_size) {
    if (blocks.empty()) return SIZE_MAX;
    // upper_bound returns first block_start > p.
    auto it = std::upper_bound(blocks.begin(), blocks.end(), p);
    if (it == blocks.begin()) return SIZE_MAX;
    --it;
    size_t i = static_cast<size_t>(it - blocks.begin());
    char* block_start = blocks[i];
    if (p >= block_start + block_size) return SIZE_MAX;  // inter-block gap
    return i;
}

bool NurserySpace::isInFromSpaceAllocatedRegion(void* ptr) const {
    char* p = static_cast<char*>(ptr);
    const std::vector<char*>& from_blocks = from_is_low_ ? low_blocks_ : high_blocks_;

    // Hot-path fast check: most mutator pointers point at recently
    // allocated objects in the *current* from-space block. Cache-friendly
    // — single comparison resolves the common case before any scan.
    if (current_from_idx_ < from_blocks.size()) {
        char* cur_start = from_blocks[current_from_idx_];
        if (p >= cur_start && p < bump_.ptr) return true;
    }

    size_t i = findBlockContaining(from_blocks, p, block_size_);
    if (i == SIZE_MAX) return false;
    if (i < current_from_idx_) return true;     // Fully filled earlier block.
    if (i > current_from_idx_) return false;    // Block past current alloc.
    return p < bump_.ptr;                      // Current block: bump bound.
}

bool NurserySpace::isInToSpaceAllocatedRegion(void* ptr) const {
    char* p = static_cast<char*>(ptr);
    const std::vector<char*>& to_blocks = from_is_low_ ? high_blocks_ : low_blocks_;

    if (current_to_idx_ < to_blocks.size()) {
        char* cur_start = to_blocks[current_to_idx_];
        if (p >= cur_start && p < copy_ptr_) return true;
    }

    size_t i = findBlockContaining(to_blocks, p, block_size_);
    if (i == SIZE_MAX) return false;
    if (i < current_to_idx_) return true;
    if (i > current_to_idx_) return false;
    return p < copy_ptr_;
}

void NurserySpace::debugAssertValidNurseryPointer(void* ptr) const {
    assert(contains(ptr) && "debugAssertValidNurseryPointer called on non-nursery pointer");

    bool ok = false;
    if (!in_minor_gc_) {
        // Mutator phase: all live nursery objects must be in the allocated
        // prefix of from-space.
        ok = isInFromSpaceAllocatedRegion(ptr);
    } else {
        // GC phase: pointers may refer to from-space (not yet evacuated)
        // or to-space (already evacuated), but never to free regions.
        ok = isInFromSpaceAllocatedRegion(ptr) || isInToSpaceAllocatedRegion(ptr);
    }

    if (!ok) {
        // Compute the HPointer value from the physical address
        char* heap_base = allocator_->getHeapBase();
        uint64_t hptr_val = (reinterpret_cast<char*>(ptr) - heap_base) / 8;
        std::fprintf(stderr, "[gc-debug] STALE hptr value=0x%lx (physical %p, heap_base=%p)\n",
                     (unsigned long)hptr_val, ptr, (void*)heap_base);

        const std::vector<char*>& from_blocks = from_is_low_ ? low_blocks_ : high_blocks_;
        const std::vector<char*>& to_blocks   = from_is_low_ ? high_blocks_ : low_blocks_;
        std::fprintf(stderr,
            "[gc-debug] STALE nursery pointer: ptr=%p in_minor_gc=%d from_is_low=%d\n"
            "  from_space: current_from_idx=%zu alloc_ptr=%p (%zu blocks)\n"
            "  to_space:   current_to_idx=%zu   copy_ptr=%p  (%zu blocks)\n",
            ptr, (int)in_minor_gc_, (int)from_is_low_,
            current_from_idx_, (void*)bump_.ptr, from_blocks.size(),
            current_to_idx_,   (void*)copy_ptr_,  to_blocks.size());
        for (size_t i = 0; i < from_blocks.size(); ++i) {
            char* bs = from_blocks[i];
            char* be = bs + block_size_;
            const char* role = (i < current_from_idx_) ? "full"
                             : (i == current_from_idx_ ? "cur" : "free");
            std::fprintf(stderr, "  from[%zu]=%p..%p (%s)%s\n",
                         i, (void*)bs, (void*)be, role,
                         ((char*)ptr >= bs && (char*)ptr < be) ? " <-- PTR" : "");
        }
        for (size_t i = 0; i < to_blocks.size(); ++i) {
            char* bs = to_blocks[i];
            char* be = bs + block_size_;
            const char* role = (i < current_to_idx_) ? "full"
                             : (i == current_to_idx_ ? "cur" : "free");
            std::fprintf(stderr, "  to  [%zu]=%p..%p (%s)%s\n",
                         i, (void*)bs, (void*)be, role,
                         ((char*)ptr >= bs && (char*)ptr < be) ? " <-- PTR" : "");
        }
        uint64_t* w = reinterpret_cast<uint64_t*>(ptr);
        std::fprintf(stderr, "  *ptr   = 0x%016lx\n", w[0]);
        std::fprintf(stderr, "  ptr[1] = 0x%016lx\n", w[1]);
        std::fprintf(stderr, "  ptr[2] = 0x%016lx\n", w[2]);
        std::fprintf(stderr, "  ptr[3] = 0x%016lx\n", w[3]);
        std::fflush(stderr);
        void* bt[40];
        int n = backtrace(bt, 40);
        backtrace_symbols_fd(bt, n, fileno(stderr));

        // Scan parent tracking: if we crashed during scanObject, show
        // which heap object was being scanned.
        if (g_scan_parent) {
            std::fprintf(stderr, "  SCAN PARENT: obj=%p tag=%d size=%u\n",
                         g_scan_parent, g_scan_tag, (unsigned)g_scan_size);
            uint64_t* pw = reinterpret_cast<uint64_t*>(g_scan_parent);
            for (int x = 0; x < (int)g_scan_size + 3 && x < 12; x++) {
                std::fprintf(stderr, "  parent[%d] = 0x%016lx\n", x, pw[x]);
            }
        }
    }
    assert(ok && "HPointer into nursery free region (stale pointer into unallocated space)");
}
#endif // ECO_HEAP_VALIDATE

} // namespace Elm
