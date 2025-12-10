#ifndef ECO_NURSERYSPACE_H
#define ECO_NURSERYSPACE_H

#include <algorithm>
#include <vector>
#include "AllocatorCommon.hpp"
#include "GCStats.hpp"
#include "OldGenSpace.hpp"
#include "RootSet.hpp"

namespace Elm {

// Forward declarations.
class Allocator;
class ThreadLocalHeap;
class NurserySpaceTestAccess;

/**
 * Nursery with semi-space copying collector using Cheney's algorithm.
 *
 * The nursery consists of memory blocks organized into two sets: low_blocks_
 * and high_blocks_. One set serves as from-space (allocation target) and the
 * other as to-space (evacuation target), swapping roles after each GC.
 *
 * Objects are allocated via bump pointer within the current block. When a
 * block fills, we advance to the next block. When all from-space blocks are
 * full, minorGC evacuates live objects to to-space (or promotes to old gen),
 * then swaps the from-space and to-space designations.
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

    // Block management using two separate address regions for semi-space copying.
    // Low blocks come from lower addresses, high blocks from higher addresses.
    // This separation enables O(1) from-space vs to-space checks using address ranges.
    std::vector<char*> low_blocks_;   // Blocks from lower nursery region (sorted).
    std::vector<char*> high_blocks_;  // Blocks from upper nursery region (sorted).
    size_t block_size_;               // Size of each block in bytes.
    bool from_is_low_;                // True if from-space is currently low_blocks_.

    // Cached bounds for O(1) membership checks (updated when blocks change).
    char* low_base_;                  // Start of first low block (low_blocks_.front()).
    char* low_end_;                   // End of last low block (low_blocks_.back() + block_size_).
    char* high_base_;                 // Start of first high block (high_blocks_.front()).
    char* high_end_;                  // End of last high block (high_blocks_.back() + block_size_).

    // Current allocation state (bump pointer allocation).
    size_t current_from_idx_;         // Index of active from-space block.
    char* alloc_ptr_;                 // Bump pointer within current from-space block.
    char* alloc_end_;                 // End address of current from-space block.

    // GC state (active only during minorGC execution).
    size_t current_to_idx_;           // Index of active to-space block for evacuation.
    char* copy_ptr_;                  // Bump pointer for copying objects into to-space.
    char* copy_end_;                  // End address of current to-space block.
    size_t scan_block_idx_;           // Index of to-space block containing scan_ptr.
    char* scan_ptr_;                  // Cheney scan pointer (next object to process).

    // Growth tracking for adaptive nursery sizing.
    float growth_threshold_;          // Request more blocks when to-space exceeds this occupancy.

    RootSet root_set;                 // Root set for this nursery.

#if ENABLE_GC_STATS
    GCStats stats;                    // Performance statistics.
#endif

    ThreadLocalHeap* thread_heap_;    // Owner ThreadLocalHeap (for multi-threaded mode).

    // ========== Internal Methods ==========

    // Initializes this nursery by requesting blocks from the Allocator.
    // Legacy initialization path for backward compatibility with older tests.
    void initialize(Allocator* allocator, const HeapConfig* config);

    // Initializes this nursery with pre-allocated memory from ThreadLocalHeap.
    void initialize(ThreadLocalHeap* heap, const HeapConfig* config);

    // Performs minor GC, evacuating live objects to to_space or promoting to old gen.
    void minorGC(OldGenSpace &oldgen);

    // Returns true if the pointer is within this nursery's address ranges.
    // O(1) check using cached bounds (may include small gaps between blocks).
    // Inlined for performance as this is called frequently during GC.
    inline bool contains(void *ptr) const {
        char* p = static_cast<char*>(ptr);
        return (p >= low_base_ && p < low_end_) ||
               (p >= high_base_ && p < high_end_);
    }

    // Returns true if the pointer is in from-space (current allocation space).
    // O(1) check using cached bounds. Inlined for performance.
    inline bool isInFromSpace(void* ptr) const {
        char* p = static_cast<char*>(ptr);
        if (from_is_low_) {
            return p >= low_base_ && p < low_end_;
        } else {
            return p >= high_base_ && p < high_end_;
        }
    }

    // Returns true if the pointer is in to-space (evacuation target during GC).
    // O(1) check using cached bounds. Inlined for performance.
    inline bool isInToSpace(void* ptr) const {
        char* p = static_cast<char*>(ptr);
        if (from_is_low_) {
            return p >= high_base_ && p < high_end_;
        } else {
            return p >= low_base_ && p < low_end_;
        }
    }

    // Updates cached bounds after block changes.
    void updateBounds();

    // Returns the number of bytes currently allocated in the nursery.
    size_t bytesAllocated() const;

    // Returns true if allocating size bytes would exceed the occupancy threshold.
    bool wouldExceedThreshold(size_t size, float threshold) const;

    // Resets the nursery to initial state (clears all blocks and stats).
    // If new_config is provided, reconfigures with new parameters. Used for testing.
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
    void evacuateJitPtr(uint64_t &ptr, OldGenSpace &oldgen, std::vector<void*> *promoted_objects);
    void evacuateUnboxable(Unboxable &val, bool is_boxed, OldGenSpace &oldgen, std::vector<void*> *promoted_objects);
    void scanObject(void *obj, OldGenSpace &oldgen, std::vector<void*> *promoted_objects);

    // ========== List Locality Optimization ==========
    // Two-pass list copying for contiguous spine allocation (improves cache locality).

    /**
     * Copies a list spine (Cons cells only) contiguously in to-space.
     *
     * Pass 1 of two-pass list copying: Iterates through tail pointers, copying
     * each Cons cell sequentially. This allocates the entire spine contiguously,
     * improving cache locality during traversal.
     *
     * @param ptr          Pointer to first Cons cell to copy (updated to new location).
     * @param oldgen       Old generation space for promotion decisions.
     * @param promoted_objects  Vector to collect objects promoted to old gen.
     * @param needs_head_pass   Set to true if any head contains a boxed pointer.
     * @return Pointer to first copied Cons in to-space (nullptr if empty/error).
     */
    void* evacuateListSpine(HPointer &ptr, OldGenSpace &oldgen,
                            std::vector<void*> *promoted_objects,
                            bool &needs_head_pass);

    /**
     * Evacuates heads of a previously-copied list spine.
     *
     * Pass 2 of two-pass list copying: Iterates through the already-copied spine
     * in to-space and evacuates each head element that contains a boxed pointer.
     *
     * @param first_cons   Pointer to first Cons in to-space (from evacuateListSpine).
     * @param oldgen       Old generation space for promotion decisions.
     * @param promoted_objects  Vector to collect objects promoted to old gen.
     */
    void evacuateListHeads(void* first_cons, OldGenSpace &oldgen,
                           std::vector<void*> *promoted_objects);

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
