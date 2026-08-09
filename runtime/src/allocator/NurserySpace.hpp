#ifndef ECO_NURSERYSPACE_H
#define ECO_NURSERYSPACE_H

#include <algorithm>
#include <cstddef>
#include <vector>
#include "AllocatorCommon.hpp"
#include "GCStats.hpp"
#include "OldGenSpace.hpp"
#include "RootSet.hpp"
#include "StackMapRoots.hpp"

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

    // Current bump-allocation state. These ARE the allocator's working fields
    // (not a mirror): every update site — init/reset, block advance,
    // post-minor-GC — keeps the exported view coherent by construction.
    // The layout (ptr at +0, end at +8) is ABI for the compiled-code inline
    // allocation fast path (HEAP_034, plans/inline-nursery-allocation.md):
    // eco_bump_state() exports this struct's address and the expandInlineAllocs
    // backend pass emits `load ptr/end; bump; compare; store` against it.
    // `end` is pre-clamped to min(block end, proactive-GC threshold trip) by
    // computeAllocEndForBlock, so the single compare preserves all GC-trigger
    // semantics.
    struct NurseryBump {
        char* ptr;   // Bump pointer within current from-space block.
        char* end;   // End address of current from-space block (clamped).
    };
    static_assert(offsetof(NurseryBump, ptr) == 0 && offsetof(NurseryBump, end) == 8,
                  "NurseryBump layout is ABI for the inline-alloc expansion");

    // Address of the bump state (thread-stable; consumed by eco_bump_state).
    NurseryBump* bumpState() { return &bump_; }

    // Allocates memory in the nursery using bump pointer. Returns nullptr if full.
    void *allocate(size_t size);

    // Returns the root set for this nursery.
    RootSet& getRootSet() { return root_set; }

#if ENABLE_GC_STATS
    // Returns the GC statistics for this nursery.
    const GCStats& getStats() const { return stats; }
    GCStats& getStats() { return stats; }
#endif

#if ECO_HEAP_VALIDATE
    // Public when ECO_HEAP_VALIDATE is on so validator helpers in the .cpp
    // (e.g. validateBitmapSlotKind, the kind-mismatch tripwire) can call
    // these from free-function context. Behaviour is unchanged otherwise.
    bool isInFromSpaceAllocatedRegion(void* ptr) const;
    bool isInToSpaceAllocatedRegion(void* ptr) const;
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
    NurseryBump bump_;                // {ptr, end} — see the public NurseryBump doc.

    // GC state (active only during minorGC execution).
    size_t current_to_idx_;           // Index of active to-space block for evacuation.
    char* copy_ptr_;                  // Bump pointer for copying objects into to-space.
    char* copy_end_;                  // End address of current to-space block.
    size_t scan_block_idx_;           // Index of to-space block containing scan_ptr.
    char* scan_ptr_;                  // Cheney scan pointer (next object to process).

    // Recorded copy_ptr_ at the moment copyToSpace abandoned a to-space block.
    // Valid only for block indices < current_to_idx_; used by the Cheney scan
    // to skip the untouched tail gap that `copyToSpace` leaves behind when an
    // object doesn't fit in the remaining space of the current block.
    // Unused entry value = corresponding block_end (= block_start + block_size_).
    std::vector<char*> block_end_of_objects_;

    // Growth tracking for adaptive nursery sizing. Mirrors
    // HeapConfig::nursery_growth_threshold; cached in initialize() so the
    // hot post-minor-GC growth check doesn't dereference config_ each call.
    float growth_threshold_;

    // Cached `nursery_gc_threshold` from HeapConfig (the proactive minor-GC
    // trigger fraction). Read once at init/reset, then consumed at block
    // transitions to derive `alloc_end_`; never touched on the alloc fast
    // path.
    float gc_threshold_;

    // Cached total from-space capacity in bytes
    // (= from_blocks.size() * block_size_). Updated whenever blocks are
    // added/swapped so wouldExceedThreshold avoids the per-allocation
    // multiply.
    size_t from_capacity_bytes_;

    // Pre-computed `from_capacity_bytes_ * gc_threshold_`. The proactive-GC
    // trip point in absolute bytes-allocated terms. Recomputed only when
    // capacity or threshold changes.
    size_t threshold_total_bytes_;

    RootSet root_set;                 // Root set for this nursery.

#if ENABLE_GC_STATS
    GCStats stats;                    // Performance statistics.
#endif

    ThreadLocalHeap* thread_heap_;    // Owner ThreadLocalHeap (for multi-threaded mode).

#if ECO_HEAP_VALIDATE
    // True only during minorGC execution. Consumed by the stale-pointer
    // detector (`debugAssertValidNurseryPointer`) to decide whether the
    // legal regions are {from-allocated} only or also include
    // {to-allocated} (mid-GC).
    bool in_minor_gc_ = false;
    bool in_phase3_   = false;        // True only during phase 3 (promoted-object scan).
#endif

    // Per-minor-GC 1-bit color for split-header bodies (HEAP_026). Flipped at
    // the start of every minor GC; the to-space scan calls
    // OldGenSpace::markLargeBodySeen with this color for every live header,
    // and the end-of-cycle sweep frees bodies whose color does not match.
    bool minor_color_ = false;

    // ========== Internal Methods ==========

    // Initializes this nursery by requesting blocks from the Allocator.
    // Legacy initialization path for backward compatibility with older tests.
    void initialize(Allocator* allocator, const HeapConfig* config);

    // Initializes this nursery with pre-allocated memory from ThreadLocalHeap.
    void initialize(ThreadLocalHeap* heap, const HeapConfig* config);

    // Performs minor GC, evacuating live objects to to_space or promoting to old gen.
    void minorGC(OldGenSpace &oldgen, const StackMapRoots& stackmap_roots);

    // Zeros the free region of to-space after evacuation completes.
    // Prevents ghost headers from surviving into the next GC cycle.
    // Unconditional (not debug-gated) — this is a safety net.
    void clearToSpaceFreeRegion();

#if ECO_HEAP_VALIDATE
    // Stale-pointer diagnostic aid: writes a poison byte over the allocated
    // prefix of the just-evacuated from-space so that stale HPointers held
    // by the mutator land on obviously-bogus data after the swap. See impl
    // for the rationale and the chosen byte's properties.
    void poisonOldFromSpaceUsedRegion();

    // From-space pre-evacuation walk (Class 3). Walks every header in the
    // allocated prefix of from-space at the start of minorGC and asserts
    // tag <= Tag_Forward and size sane. Catches mutator-side header
    // corruption before it propagates into to-space via memcpy.
    void preEvacuationFromSpaceWalk();

    // block_end_of_objects_ post-condition (Class 3). At end of minorGC,
    // walk every "completed" to-space block and verify the recorded
    // end-of-objects matches a fresh linear scan. Detects tail-gap
    // tracking bugs that would otherwise only manifest as ghost-header
    // reads in the next cycle.
    void verifyToSpaceBlockEndOfObjects();

    // Stale-pointer tripwire (validator-only; see Allocator::resolve and the
    // per-arg validation in eco_apply_closure / eco_apply_segmentation_unknown
    // / eco_closure_call_saturated). Reports + aborts when an HPointer
    // resolves to a free region of the nursery (i.e. post-swap to-space-free,
    // i.e. a stale pre-GC pointer that was never evacuated).
    // (isInFromSpaceAllocatedRegion / isInToSpaceAllocatedRegion declared
    // public above for free-helper access in the .cpp.)
    void debugAssertValidNurseryPointer(void* ptr) const;
#endif

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

    // Returns true if allocating size bytes would exceed the occupancy
    // threshold. Retained for diagnostic call sites; the hot allocation
    // path no longer invokes this — the threshold is folded into
    // `alloc_end_` at block transitions instead. The `threshold` parameter
    // is ignored; the cached `gc_threshold_` is used.
    bool wouldExceedThreshold(size_t size, float threshold) const;

    // Recomputes capacity-derived caches (`from_capacity_bytes_`,
    // `threshold_total_bytes_`) from the current from-space block count.
    // Call after any operation that adds, removes, or swaps from-space
    // blocks.
    void refreshCapacityCaches();

    // Returns the address at which `alloc_end_` should be capped for the
    // current from-space block (`block_start`) so a single
    // `alloc_ptr_ + size <= alloc_end_` test enforces both block-fit and
    // proactive-GC threshold-fit. Allocation that would push total
    // bytesAllocated past `threshold_total_bytes_` will fall through to
    // the slow path and trigger `minorGC`.
    char* computeAllocEndForBlock(char* block_start) const;

    // Resets the nursery to initial state (clears all blocks and stats).
    // If new_config is provided, reconfigures with new parameters. Used for testing.
    void reset(OldGenSpace &oldgen, const HeapConfig* new_config = nullptr);

    // Allocation slow path - advances to next block or returns nullptr.
    void* allocateSlow(size_t size);

    // Capacity guarantee for hoisted allocation checks (HEAP_041,
    // plans/capacity-check-hoisting.md). Establishes
    // `bump_.end - bump_.ptr >= n` for this thread WITHOUT allocating, by
    // advancing from-space blocks on GENUINE exhaustion only. Returns false
    // when the caller must run a minor GC and retry.
    //
    // The `bump_.end < block_end` guard is load-bearing and mirrors
    // allocateSlow's clamp-vs-exhaustion disambiguator: a clamped end means
    // the proactive-GC threshold tripped INSIDE the current block, and the
    // correct action is to signal GC. Advancing past a mid-block trip would
    // land every subsequent block in computeAllocEndForBlock's already-full
    // fail-soft clause (full block ends), silently disabling the proactive
    // trigger for the rest of the nursery cycle.
    bool ensureHeadroom(size_t n);

    // Fail-soft escape for the tiny-config corner where a fresh block's
    // CLAMPED end sits below n (threshold_total_bytes_ < n; unreachable at
    // default config, reachable in small test heaps) — without it,
    // ensureNursery would GC-loop. Unclamps the CURRENT block only, after
    // rewinding current_from_idx_ to the block actually containing
    // bump_.ptr (a false ensureHeadroom return may leave the index one past
    // the end, the same transient allocateSlow leaves behind).
    void failSoftUnclampCurrentBlock();

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
    void evacuateValueSlot(uint64_t &encoded, OldGenSpace &oldgen, std::vector<void*> *promoted_objects);
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

    static void clearToSpaceFreeRegion(NurserySpace& nursery) {
        nursery.clearToSpaceFreeRegion();
    }

    // ---- Capacity-check hoisting (HEAP_041) ----

    static bool ensureHeadroom(NurserySpace& nursery, size_t n) {
        return nursery.ensureHeadroom(n);
    }

    static void failSoftUnclampCurrentBlock(NurserySpace& nursery) {
        nursery.failSoftUnclampCurrentBlock();
    }

    // Bytes between the bump pointer and the CLAMPED end — exactly the
    // quantity ensureHeadroom guarantees.
    static size_t headroom(const NurserySpace& nursery) {
        return static_cast<size_t>(nursery.bump_.end - nursery.bump_.ptr);
    }

    static char* bumpPtr(const NurserySpace& nursery) { return nursery.bump_.ptr; }
    static char* bumpEnd(const NurserySpace& nursery) { return nursery.bump_.end; }

    static size_t currentFromIdx(const NurserySpace& nursery) {
        return nursery.current_from_idx_;
    }

    static size_t blockSize(const NurserySpace& nursery) {
        return nursery.block_size_;
    }

    static char* fromBlockAt(const NurserySpace& nursery, size_t i) {
        const std::vector<char*>& from_blocks =
            nursery.from_is_low_ ? nursery.low_blocks_ : nursery.high_blocks_;
        return i < from_blocks.size() ? from_blocks[i] : nullptr;
    }

    // Consumes headroom without going through allocate() so a test can park
    // the bump pointer at an exact offset inside the current block.
    static void bumpBy(NurserySpace& nursery, size_t bytes) {
        nursery.bump_.ptr += bytes;
    }

    // Forces the proactive-GC clamp to fire inside the current block, i.e.
    // the state ensureHeadroom must NOT advance past.
    static void clampCurrentBlockEnd(NurserySpace& nursery, size_t headroom) {
        nursery.bump_.end = nursery.bump_.ptr + headroom;
    }
};

} // namespace Elm

#endif // ECO_NURSERYSPACE_H
