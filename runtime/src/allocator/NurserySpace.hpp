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
 * Each semi-space is ONE CONTIGUOUS EXTENT (HEAP_042): the logical prefix of
 * a fixed-size slice of the low or high nursery region, both slices at the
 * same slot index and always the same length. One extent is from-space
 * (allocation target), the other to-space (evacuation target); they swap
 * roles after each GC.
 *
 * Because the extent is contiguous, allocation is a single bump against a
 * limit that spans the WHOLE from-space: there is no block advance, no
 * object that cannot straddle an internal boundary, and no abandoned tail
 * gap. A bump miss therefore has exactly one meaning — the proactive-GC
 * threshold tripped (or, under the already-full fail-soft, the space is
 * exhausted) — and exactly one response: run a minor GC. Evacuation is the
 * same single bump into to-space, so the Cheney scan is the textbook
 * two-pointer loop.
 */
class NurserySpace {
public:
    NurserySpace();
    ~NurserySpace();

    // Current bump-allocation state. These ARE the allocator's working fields
    // (not a mirror): every update site — init/reset, post-minor-GC — keeps
    // the exported view coherent by construction.
    // The layout (ptr at +0, end at +8) is ABI for the compiled-code inline
    // allocation fast path (HEAP_034, plans/inline-nursery-allocation.md):
    // eco_bump_state() exports this struct's address and the expandInlineAllocs
    // backend pass emits `load ptr/end; bump; compare; store` against it.
    // `end` is pre-clamped to min(from-space extent end, proactive-GC
    // threshold trip) by computeAllocEnd, so the single compare preserves all
    // GC-trigger semantics.
    struct NurseryBump {
        char* ptr;   // Bump pointer within the from-space extent.
        char* end;   // Clamped limit (see computeAllocEnd).
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
    Allocator* allocator_;          // Back-reference for slice acquire/grow.

    // This heap's nursery address estate (HEAP_042). `slice_.capacity` is the
    // logical extent length of EACH side — one value, so the two semi-spaces
    // are equal in size by construction rather than by assertion.
    NurserySlicePair slice_;
    bool from_is_low_;              // True if from-space is the low extent.

    // Per-heap growth ceiling: min(the allocator's slice size, the config's
    // per-side max). Cached at initialize/reset.
    size_t growth_ceiling_bytes_;

    // Exact extent bounds, used for the O(1) membership checks below. Unlike
    // the block design's front()/back() span, these have no interior gaps and
    // never cover another heap's memory.
    char* low_base_;                // Low slice base.
    char* low_end_;                 // low_base_ + capacity.
    char* high_base_;               // High slice base.
    char* high_end_;                // high_base_ + capacity.

    // Current allocation state (bump pointer allocation).
    NurseryBump bump_;              // {ptr, end} — see the public doc.

    // GC state (active only during minorGC execution).
    char* copy_ptr_;                // Bump pointer for copying into to-space.
    char* copy_end_;                // To-space extent end.
    char* scan_ptr_;                // Cheney scan pointer.

    // Growth tracking for adaptive nursery sizing. Mirrors
    // HeapConfig::nursery_growth_threshold; cached in initialize() so the
    // hot post-minor-GC growth check doesn't dereference config_ each call.
    float growth_threshold_;

    // Cached `nursery_gc_threshold` from HeapConfig (the proactive minor-GC
    // trigger fraction). Read once at init/reset, then consumed by
    // computeAllocEnd; never touched on the alloc fast path.
    float gc_threshold_;

    // Cached from-space capacity in bytes (== slice_.capacity; both sides are
    // equal). Kept as a field so the threshold math and the validators don't
    // reach through the slice each time.
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

    // Initializes this nursery by acquiring a slice pair from the Allocator.
    // Legacy initialization path for backward compatibility with older tests.
    void initialize(Allocator* allocator, const HeapConfig* config);

    // Initializes this nursery with a slice pair, driven by ThreadLocalHeap.
    void initialize(ThreadLocalHeap* heap, const HeapConfig* config);

    // Shared body of the two initialize() overloads: acquires the slice pair
    // and seats every derived cache. `allocator_` must already be set.
    void initializeFromConfig();

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
    // corruption before it propagates into to-space via memcpy. Under the
    // contiguous design this covers the ENTIRE prefix (the block design
    // could only walk the current block — earlier blocks had untracked tail
    // gaps), so it is a strictly stronger check.
    void preEvacuationFromSpaceWalk();

    // Stale-pointer tripwire (validator-only; see Allocator::resolve and the
    // per-arg validation in eco_apply_closure / eco_apply_segmentation_unknown
    // / eco_closure_call_saturated). Reports + aborts when an HPointer
    // resolves to a free region of the nursery (i.e. post-swap to-space-free,
    // i.e. a stale pre-GC pointer that was never evacuated).
    // (isInFromSpaceAllocatedRegion / isInToSpaceAllocatedRegion declared
    // public above for free-helper access in the .cpp.)
    void debugAssertValidNurseryPointer(void* ptr) const;
#endif

    // Base of the current from-/to-space extent.
    inline char* fromBase() const { return from_is_low_ ? low_base_ : high_base_; }
    inline char* toBase()   const { return from_is_low_ ? high_base_ : low_base_; }

    // Returns true if the pointer is within this nursery's address ranges.
    // O(1) and EXACT — the extents are contiguous, so unlike the block
    // design's cached span this admits no interior gaps.
    // Inlined for performance as this is called frequently during GC.
    inline bool contains(void *ptr) const {
        char* p = static_cast<char*>(ptr);
        return (p >= low_base_ && p < low_end_) ||
               (p >= high_base_ && p < high_end_);
    }

    // Returns true if the pointer is in from-space (current allocation space).
    // O(1) check using the extent bounds. Inlined for performance.
    inline bool isInFromSpace(void* ptr) const {
        char* p = static_cast<char*>(ptr);
        if (from_is_low_) {
            return p >= low_base_ && p < low_end_;
        } else {
            return p >= high_base_ && p < high_end_;
        }
    }

    // Returns true if the pointer is in to-space (evacuation target during GC).
    // O(1) check using the extent bounds. Inlined for performance.
    inline bool isInToSpace(void* ptr) const {
        char* p = static_cast<char*>(ptr);
        if (from_is_low_) {
            return p >= high_base_ && p < high_end_;
        } else {
            return p >= low_base_ && p < low_end_;
        }
    }

    // Re-derives the cached extent bounds from the slice base + capacity.
    // MUST be called after every capacity change — growth is the only
    // mid-life one, and stale bounds would make the next minor GC treat
    // objects in the grown region as non-nursery and skip evacuating them.
    void updateBounds();

    // Returns the number of bytes currently allocated in the nursery.
    size_t bytesAllocated() const;

    // Recomputes capacity-derived caches (`from_capacity_bytes_`,
    // `threshold_total_bytes_`) from the slice capacity. Call after any
    // capacity change or space swap.
    void refreshCapacityCaches();

    // Returns the address at which `bump_.end` should be capped so a single
    // `bump_.ptr + size <= bump_.end` test enforces both extent-fit and
    // proactive-GC threshold-fit. Allocation that would push total
    // bytesAllocated past `threshold_total_bytes_` falls through to the slow
    // path and triggers `minorGC`.
    char* computeAllocEnd() const;

    // Resets the nursery to initial state (releases and re-acquires the
    // slice). If new_config is provided, reconfigures with new parameters.
    // Used for testing.
    void reset(OldGenSpace &oldgen, const HeapConfig* new_config = nullptr);

    // Allocation slow path. Under the contiguous design a fast-path miss can
    // only mean "GC now", so this exists to keep the stats bracket and the
    // already-full fail-soft in one place.
    void* allocateSlow(size_t size);

    // Capacity guarantee for hoisted allocation checks (HEAP_041,
    // plans/capacity-check-hoisting.md). Establishes
    // `bump_.end - bump_.ptr >= n` for this thread WITHOUT allocating.
    // Returns false when the caller must run a minor GC and retry.
    bool ensureHeadroom(size_t n);

    // Fail-soft escape for the tiny-config corner where the CLAMPED end sits
    // below n (threshold_total_bytes_ < n; unreachable at default config,
    // reachable in small test heaps) — without it, ensureNursery would
    // GC-loop. Unclamps to the full from-space extent.
    void failSoftUnclamp();

    // Allocates space in to-space during GC copying.
    void* copyToSpace(size_t size);

    // Returns true if scan pointer has more to process.
    bool scanHasMore() const;

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

    static void clearToSpaceFreeRegion(NurserySpace& nursery) {
        nursery.clearToSpaceFreeRegion();
    }

    // ---- Contiguous extents (HEAP_042) ----

    // Per-side capacity in bytes (equal for both semi-spaces).
    static size_t capacity(const NurserySpace& nursery) {
        return nursery.from_capacity_bytes_;
    }

    static char* fromBase(const NurserySpace& nursery) { return nursery.fromBase(); }
    static char* toBase(const NurserySpace& nursery)   { return nursery.toBase(); }

    static char* fromEnd(const NurserySpace& nursery) {
        return nursery.fromBase() + nursery.from_capacity_bytes_;
    }

    static size_t growthCeiling(const NurserySpace& nursery) {
        return nursery.growth_ceiling_bytes_;
    }

    static size_t sliceSlot(const NurserySpace& nursery) {
        return nursery.slice_.slot;
    }

    static bool fromIsLow(const NurserySpace& nursery) { return nursery.from_is_low_; }

    static void checkAndGrow(NurserySpace& nursery) { nursery.checkAndGrow(); }

    // ---- Capacity-check hoisting (HEAP_041) ----

    static bool ensureHeadroom(NurserySpace& nursery, size_t n) {
        return nursery.ensureHeadroom(n);
    }

    static void failSoftUnclamp(NurserySpace& nursery) {
        nursery.failSoftUnclamp();
    }

    // Bytes between the bump pointer and the CLAMPED end — exactly the
    // quantity ensureHeadroom guarantees.
    static size_t headroom(const NurserySpace& nursery) {
        return static_cast<size_t>(nursery.bump_.end - nursery.bump_.ptr);
    }

    static char* bumpPtr(const NurserySpace& nursery) { return nursery.bump_.ptr; }
    static char* bumpEnd(const NurserySpace& nursery) { return nursery.bump_.end; }

    // Consumes headroom without going through allocate() so a test can park
    // the bump pointer at an exact offset inside the extent.
    static void bumpBy(NurserySpace& nursery, size_t bytes) {
        nursery.bump_.ptr += bytes;
    }

    // Forces the proactive-GC clamp to fire inside the extent, i.e. the
    // state ensureHeadroom must NOT advance past.
    static void clampEnd(NurserySpace& nursery, size_t headroom) {
        nursery.bump_.end = nursery.bump_.ptr + headroom;
    }
};

} // namespace Elm

#endif // ECO_NURSERYSPACE_H
