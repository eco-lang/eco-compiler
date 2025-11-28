#ifndef ECO_NURSERYSPACE_H
#define ECO_NURSERYSPACE_H

#include <algorithm>
#include <vector>
#include "AllocatorCommon.hpp"
#include "GCStats.hpp"
#include "OldGenSpace.hpp"
#include "RootSet.hpp"

namespace Elm {

// ============================================================================
// DFS Stack for Hybrid Traversal
// ============================================================================

/**
 * Bounded stack for approximate depth-first traversal during GC.
 *
 * Used by the hybrid DFS/BFS copying collector to prioritize depth-first
 * traversal for deep structures (Cons lists, Task chains) while falling
 * back to Cheney's BFS when the stack is full.
 *
 * Benefits:
 *   - Lists: Cons cells copied contiguously (better cache locality)
 *   - Tasks: Task chains clustered together
 *   - Processes: Each subgraph (root, stack, mailbox) clustered
 *
 * When the stack is full, objects fall through to Cheney's scanPtr,
 * which provides BFS traversal as a fallback. This bounds memory usage
 * while still improving locality for typical workloads.
 */
struct DfsStack {
    static constexpr size_t MAX_DEPTH = 256;  // Tunable: 128-512 typical.
    void* data[MAX_DEPTH];
    size_t top = 0;

    bool empty() const { return top == 0; }
    bool full() const { return top == MAX_DEPTH; }
    void push(void* obj) { if (!full()) data[top++] = obj; }
    void* pop() { return data[--top]; }
    void clear() { top = 0; }
};

// Forward declarations.
class Allocator;
class ThreadLocalHeap;
class NurserySpaceTestAccess;

/**
 * Nursery with semi-space copying collector (Cheney's algorithm).
 *
 * The nursery is composed of blocks (same size as AllocBuffer). Blocks are
 * organized into two sets: from_blocks_ (allocation space) and to_blocks_
 * (copy target during GC).
 *
 * Objects are allocated via bump pointer within the current block. When a
 * block is exhausted, we move to the next block. When all from-space blocks
 * are full, minorGC evacuates live objects to to-space blocks (or promotes
 * to old gen), then swaps spaces.
 */
class NurserySpace {
public:
    NurserySpace();
    ~NurserySpace();

    // Allocates memory in the nursery using bump pointer. Returns nullptr if full.
    void *allocate(size_t size);

    // Returns the root set for this nursery.
    RootSet& getRootSet() { return root_set; }

#if ENABLE_GC_STATS
    // Returns the GC statistics for this nursery.
    const GCStats& getStats() const { return stats; }
    GCStats& getStats() { return stats; }
#endif

private:
    const HeapConfig* config_;      // Heap configuration parameters.
    Allocator* allocator_;          // Back-reference for requesting new blocks.

    // Block management - two vectors for O(1) membership checks.
    // Low and high blocks are from separate address space regions.
    // All low block addresses < all high block addresses.
    std::vector<char*> low_blocks_;   // Blocks from low nursery region, sorted.
    std::vector<char*> high_blocks_;  // Blocks from high nursery region, sorted.
    size_t block_size_;               // Size of each block in bytes.
    bool from_is_low_;                // True if from-space is low_blocks_.

    // Cached bounds for O(1) membership checks.
    char* low_base_;                  // low_blocks_.front()
    char* low_end_;                   // low_blocks_.back() + block_size_
    char* high_base_;                 // high_blocks_.front()
    char* high_end_;                  // high_blocks_.back() + block_size_

    // Current allocation state.
    size_t current_from_idx_;         // Index into current from-space vector.
    char* alloc_ptr_;                 // Bump pointer in current block.
    char* alloc_end_;                 // End of current block.

    // GC state (during minorGC).
    size_t current_to_idx_;           // Index into current to-space vector.
    char* copy_ptr_;                  // Bump pointer for copying in to-space.
    char* copy_end_;                  // End of current to-space block.
    size_t scan_block_idx_;           // Which to-space block scan_ptr is in.
    char* scan_ptr_;                  // Cheney scan pointer.

    // Growth tracking.
    float growth_threshold_;          // Trigger growth when to-space exceeds this fraction full.

    RootSet root_set;                 // Root set for this nursery.

#if ENABLE_GC_STATS
    GCStats stats;                    // Performance statistics.
#endif

    ThreadLocalHeap* thread_heap_;    // Owner ThreadLocalHeap (for multi-threaded mode).

    DfsStack dfs_stack_;              // Stack for hybrid DFS/BFS traversal.

    // ========== Internal Methods ==========

    // Initializes this nursery by requesting blocks from the Allocator.
    // Used for backward compatibility with single-threaded tests.
    void initialize(Allocator* allocator, const HeapConfig* config);

    // Initializes this nursery with pre-allocated memory from ThreadLocalHeap.
    void initialize(ThreadLocalHeap* heap, const HeapConfig* config);

    // Performs minor GC, evacuating live objects to to_space or promoting to old gen.
    void minorGC(OldGenSpace &oldgen);

    // Returns true if the pointer points into any of this nursery's blocks.
    // O(1) using cached bounds (approximate - includes gaps between blocks).
    bool contains(void *ptr) const;

    // Returns true if the pointer is in from-space.
    // O(1) using cached bounds.
    bool isInFromSpace(void* ptr) const;

    // Returns true if the pointer is in to-space.
    // O(1) using cached bounds.
    bool isInToSpace(void* ptr) const;

    // Updates cached bounds after block changes.
    void updateBounds();

    // Returns the number of bytes currently allocated in the nursery.
    size_t bytesAllocated() const;

    // Returns true if the given allocation would push usage above the threshold.
    bool wouldExceedThreshold(size_t size, float threshold) const;

    // Resets the nursery to initial state. Used for testing.
    // If new_config is provided, reconfigures with new parameters.
    void reset(OldGenSpace &oldgen, const HeapConfig* new_config = nullptr);

    // Allocation slow path - advances to next block or returns nullptr.
    void* allocateSlow(size_t size);

    // Allocates space in to-space during GC copying.
    void* copyToSpace(size_t size);

    // Returns true if scan pointer has more to process.
    bool scanHasMore() const;

    // Advances scan pointer to next block if needed.
    void advanceScanIfNeeded();

    // Checks occupancy after GC and grows if needed.
    void checkAndGrow();

    void evacuate(HPointer &ptr, OldGenSpace &oldgen, std::vector<void*> *promoted_objects);
    void evacuateUnboxable(Unboxable &val, bool is_boxed, OldGenSpace &oldgen, std::vector<void*> *promoted_objects);
    void scanObject(void *obj, OldGenSpace &oldgen, std::vector<void*> *promoted_objects);

    friend class Allocator;
    friend class ThreadLocalHeap;
    friend class NurserySpaceTestAccess;
};

// ============================================================================
// Test Access Helper
// ============================================================================

// For test code only - provides privileged access to NurserySpace internals.
class NurserySpaceTestAccess {
public:
    static bool contains(const NurserySpace& nursery, void* ptr) {
        return nursery.contains(ptr);
    }

    static size_t bytesAllocated(const NurserySpace& nursery) {
        return nursery.bytesAllocated();
    }

    static bool isInFromSpace(const NurserySpace& nursery, void* ptr) {
        return nursery.isInFromSpace(ptr);
    }

    static bool isInToSpace(const NurserySpace& nursery, void* ptr) {
        return nursery.isInToSpace(ptr);
    }

    static size_t fromBlockCount(const NurserySpace& nursery) {
        return nursery.from_is_low_ ? nursery.low_blocks_.size() : nursery.high_blocks_.size();
    }

    static size_t toBlockCount(const NurserySpace& nursery) {
        return nursery.from_is_low_ ? nursery.high_blocks_.size() : nursery.low_blocks_.size();
    }

    static size_t lowBlockCount(const NurserySpace& nursery) {
        return nursery.low_blocks_.size();
    }

    static size_t highBlockCount(const NurserySpace& nursery) {
        return nursery.high_blocks_.size();
    }
};

} // namespace Elm

#endif // ECO_NURSERYSPACE_H
