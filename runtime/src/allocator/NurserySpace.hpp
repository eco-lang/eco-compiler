#ifndef ECO_NURSERYSPACE_H
#define ECO_NURSERYSPACE_H

#include <algorithm>
#include <cassert>
#include <cstddef>
#include <cstring>
#include <memory>
#include <mutex>
#include <vector>
#include "AllocatorCommon.hpp"
#include "MarkWork.hpp"
#include "MinorWork.hpp"
#include "NurseryRegions.hpp"
#include "P1Census.hpp"
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

    // W5 item 35: promoted-object work queue, retained across cycles so its
    // capacity is paid for once rather than re-grown inside every pause.
    std::vector<void*> promoted_buf_;

    // GC state (active only during minorGC execution).
    char* copy_ptr_;                // Bump pointer for copying into to-space.
    char* survivor_end_ = nullptr;  // threaded-gc-05a: bump_.ptr right after the last minor.
    // threaded-gc-06 HEAP_068: Tag_Free filler bytes inside the from-space
    // survivor prefix [fromBase(), survivor_end_) (LAB tails of a parallel
    // minor; always 0 after a serial one), and the same figure for the to-space
    // prefix being built by the running minor. Nursery policy counts OBJECT
    // bytes = prefix bytes - filler bytes.
    size_t filler_bytes_ = 0;
    size_t filler_bytes_to_ = 0;
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

    // W2 items 18/19/22: both are GC-invariant but were dereferenced through
    // config_ once per surviving object (promotion_age at three sites) and
    // once per Cons cell (use_hybrid_dfs). Refreshed in refreshCapacityCaches.
    Elm::u32 promotion_age_ = 1;
    bool use_hybrid_dfs_ = true;

    // W2 item 16: heap bounds are GC-invariant but were re-fetched through
    // allocator_ on every evacuate() call. Same refresh point.
    char* heap_base_ = nullptr;
    size_t heap_reserved_ = 0;

    // Cached from-space capacity in bytes (== slice_.capacity; both sides are
    // equal). Kept as a field so the threshold math and the validators don't
    // reach through the slice each time.
    size_t from_capacity_bytes_;
    uint64_t minor_seq_ = 0;   // minors run (minorSeq), counted at minorGC entry
public:
    // threaded-gc-04: per-side capacity (bounds builder-built chunk chains).
    size_t capacityBytes() const { return from_capacity_bytes_; }
    // Minors run so far on this nursery, in every build and both nursery
    // modes; GCReport::minor_count (HEAP_076). (census_minor_seq_ exists only
    // in P1 census builds, so this is its own always-on counter.)
    uint64_t minorSeq() const { return minor_seq_; }
    // threaded-gc-05a (P§3.2, IM7): walks the survivor prefix
    // [fromBase(), bump_.ptr) left by the last minor GC, calling f(obj) for
    // every object. Valid only before the mutator allocates again; asserts
    // bump_.ptr == survivor_end_ (in every build) and that the walk ends
    // exactly at bump_.ptr. Returns the number of objects visited.
    // TLA-REGION(NSH.forEachSurvivor) begin
    template <typename F> size_t forEachSurvivor(F&& f, size_t* bytes_out = nullptr) {
        assert(bump_.ptr == survivor_end_ &&
               "IM7: nursery allocated since the last minor; the survivor prefix is not exact");
        char* p = fromBase();
        char* const end = bump_.ptr;
        size_t n = 0;
        size_t fillers = 0;
        while (p < end) {
            const size_t sz = getObjectSize(p);
#if ECO_HEAP_VALIDATE
            if (getHeader(p)->tag > Tag_Forward || sz == 0 || p + sz > end) {
                std::fprintf(stderr, "[heap-validate] IM7: bad survivor at %p (tag %u, size %zu)\n",
                             static_cast<void*>(p), (unsigned)getHeader(p)->tag, sz);
                std::fflush(stderr);
                std::abort();
            }
#endif
            if (getHeader(p)->tag == Tag_Free) {   // threaded-gc-06: a LAB-tail filler
                fillers += sz;
            } else {
                f(static_cast<void*>(p));
                ++n;
            }
            p += sz;
        }
        assert(p == end && "IM7: survivor walk overran bump_.ptr");
        assert(fillers == filler_bytes_ && "HEAP_068: survivor-prefix fillers != filler_bytes_");
        if (bytes_out) *bytes_out = static_cast<size_t>(end - fromBase()) - fillers;
        return n;
    }
    // TLA-REGION(NSH.forEachSurvivor) end
    // True when no nursery allocation happened since the last minor GC.
    bool survivorPrefixExact() const {
        if (rg_) return bump_.ptr == rg_->eden_base;   // threaded-gc-07 IM7: eden is empty
        return bump_.ptr == survivor_end_;
    }

    // ========== threaded-gc-07: the region nursery (HEAP_069/HEAP_070) ==========
    bool regionMode() const { return rg_ != nullptr; }
    RegionState* regionState() { return rg_.get(); }
    const RegionState* regionState() const { return rg_.get(); }
    // P§3.16 t0 young walk: every object (fillers skipped) of the Fresh
    // extent's survivor part and builder area and the Tenuring extent's
    // survivor part. Valid right after a minor (IM7: eden is empty).
    // Legacy mode: forEachSurvivor.
    template <typename F> size_t forEachYoung(F&& f, size_t* bytes_out = nullptr);
    // P§3.15: joins the running or pending tenure job and MERGES it (heal,
    // bodies, YLOS promotions, grant return, stats). `why`: 0 = minor start,
    // 1 = STW major, 2 = teardown (stats-only merge: no heal).
    void tenureJoin(OldGenSpace& oldgen, int why, MinorGCRecord* rec = nullptr);
    // P§3.15: builds job m at the end of minor m (after the cycle decision)
    // and runs it (mode 1) or launches it on the tenure collector (mode 2).
    void tenureLaunch(OldGenSpace& oldgen);
    // Heap teardown: stop / finish / stats-merge the last job, stop the gang.
    void tenureTeardown(OldGenSpace& oldgen);
    // P§3.16 STW major rule: a Tenuring object whose job is Merged -> its
    // copy (TV1 aborts on a miss); anything else -> obj.
    void* majorRedirect(void* obj) const;
    // CR-017 / HEAP_074: after a STW major's mark (before the mutator resumes),
    // every survivor-part object of every Young extent the major did not reach
    // (OldGenSpace::majorReachedNursery) becomes a Tag_Free filler. Never the
    // Tenuring extent, builder areas or eden; never inside a minor.
    void zapDeadAfterMajor(OldGenSpace& og);
    // The effective large-pointer nursery cap in region mode (P§3.13).
    size_t regionLargeCap() const { return region_large_cap_; }
    // Test hooks (P§3.19 negative controls; written only between minors).
    uint64_t test_tenure_skip_start_every_ = 0;
    bool test_heal_skip_one_ = false;
    bool test_skip_zap_ = false;              // threaded-gc-07b negative control
    bool test_no_body_remark_ = false;
    uint64_t test_tenure_force_stop_after_ = 0;
    uint64_t test_tenure_sleep_us_ = 0;
    // Old-gen placement of every copy of the last merged jobs (tests:
    // testTenureStopResumeSameLayout). Recorded only when enabled.
    bool test_record_layout_ = false;
    std::vector<uintptr_t> test_layout_;
private:
    std::vector<uintptr_t> J_layout_;   // the running job's placements (job-private)
    std::unique_ptr<RegionState> rg_;
    size_t region_large_cap_ = SIZE_MAX;
    void initRegions();
    void releaseRegions();
    void minorGCRegion(OldGenSpace& oldgen, const StackMapRoots& stackmap_roots,
                       MinorGCRecord* rec);
    friend struct RegionEnvAccess;
private:

    // Pre-computed `from_capacity_bytes_ * gc_threshold_`. The proactive-GC
    // trip point in absolute bytes-allocated terms. Recomputed only when
    // capacity or threshold changes.
    size_t threshold_total_bytes_;

    RootSet root_set;                 // Root set for this nursery.

#if ENABLE_GC_STATS
    GCStats stats;                    // Performance statistics.
#endif

    ThreadLocalHeap* thread_heap_;    // Owner ThreadLocalHeap (for multi-threaded mode).

    // True from the start to the end of minorGC's collection bracket (the
    // former thread_local g_in_minor_gc, HEAP_053: GC state is per-heap, never
    // the calling thread's TLS). Set and cleared together with
    // OldGenSpace::in_minor_gc_. Distinct from the validate-only in_minor_gc_
    // below, whose bracket is narrower.
    bool minor_gc_running_ = false;

#if ECO_HEAP_VALIDATE
    // True only during minorGC execution. Consumed by the stale-pointer
    // detector (`debugAssertValidNurseryPointer`) to decide whether the
    // legal regions are {from-allocated} only or also include
    // {to-allocated} (mid-GC).
    bool in_minor_gc_ = false;
    bool in_phase3_   = false;        // True only during phase 3 (promoted-object scan).
#endif

#if P1_CENSUS_COMPILED
    // threaded-gc-00 Step 11, moved to the P1 census by threaded-gc-04
    // (detector N; P1Census.hpp): survivor-write census.
    // At the end of each minor GC every survivor in [fromBase, bump_.ptr) is
    // hashed; at the start of the next minor GC each is re-hashed. A mismatch
    // is a write into an object that had already survived a GC (P1,
    // design_docs/parallel-gc.md §7.4.3). Mode 1 counts; mode 2 aborts.
    struct CensusEntry {
        uint32_t offset_q;    // (obj - census_base_) >> 3
        uint32_t size;        // bytes
        uint64_t hash;
        uint32_t copy_off;    // word offset into census_copy_, or UINT32_MAX
        uint8_t  builder;     // builder bit at record time (writes allowed)
    };
    std::vector<CensusEntry> census_;
    std::vector<uint64_t>    census_copy_;   // bytes of survivors <= 128 B
    char* census_base_ = nullptr;
    int   census_forced_ = -1;               // test override: -1 p1::mode, 0 off, 1 on
    uint64_t census_minor_seq_ = 0;          // minors seen (P1 periodic verify)
    // threaded-gc-04b: YLOS objects that stayed young this minor (they never
    // move: recorded by address), dropped if a major ran in between.
    struct CensusYlosEntry {
        void*    obj;
        uint32_t size;
        uint64_t hash;
    };
    std::vector<CensusYlosEntry> census_ylos_;
    uint64_t census_ylos_epoch_ = 0;
    bool  censusEnabled() const;
    void  censusRecord(OldGenSpace& oldgen);
    void  censusCheck(OldGenSpace& oldgen);
#endif

    // Per-minor-GC 1-bit color for split-header bodies (HEAP_026). Flipped at
    // the start of every minor GC; the to-space scan calls
    // OldGenSpace::markLargeBodySeen with this color for every live header,
    // and the end-of-cycle sweep frees bodies whose color does not match.
    bool minor_color_ = false;

    // threaded-gc-04b HEAP_062: YLOS objects reached this minor that stay
    // young. The drain loop scans them in place (young children are normal).
    // Cleared at the start of each minor.
    std::vector<void*> young_large_scan_;

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
    // `rec` (threaded-gc-00): when non-null, the per-phase measurements of
    // this collection are written into it. Null = no phase timing.
    void minorGC(OldGenSpace &oldgen, const StackMapRoots& stackmap_roots,
                 MinorGCRecord* rec = nullptr);

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
    void regionAssertValidPointer(void* ptr) const;   // threaded-gc-07 TV7
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
public:
    // threaded-gc-06 HEAP_068: bytesAllocated() minus the survivor-prefix
    // fillers. Every nursery policy input reads this, never bytesAllocated().
    size_t objectBytesAllocated() const { return bytesAllocated() - filler_bytes_; }
    size_t fillerBytes() const { return filler_bytes_; }
private:

    // Recomputes capacity-derived caches (`from_capacity_bytes_`,
    // `threshold_total_bytes_`) from the slice capacity. Call after any
    // capacity change or space swap.
    void refreshCapacityCaches();

    // Returns the address at which `bump_.end` should be capped so a single
    // `bump_.ptr + size <= bump_.end` test enforces both extent-fit and
    // proactive-GC threshold-fit. Allocation that would push total
    // bytesAllocated past `threshold_total_bytes_` falls through to the slow
    // path and triggers `minorGC`.
    char* computeAllocEnd();   // non-const: counts alloc_end_capped (threaded-gc-06)

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
    // W2 item 21: the body is `if (is_boxed) evacuate(...)`. Out-of-line it
    // cost a call per unboxed slot for nothing; defined here so the unboxed
    // case folds away at the call site.
    inline void evacuateUnboxable(Unboxable &val, bool is_boxed, OldGenSpace &oldgen,
                                  std::vector<void*> *promoted_objects) {
        if (is_boxed) evacuate(val.p, oldgen, promoted_objects);
    }

    // threaded-gc-06 Step 4: the serial copiers' promotion allocation. The
    // identity switch (stats builds) routes it through a promotion context.
    inline void* promoteAllocate(OldGenSpace& oldgen, size_t size) {
#if ENABLE_GC_STATS
        if (__builtin_expect(promo_w0_ != nullptr, 0))
            return oldgen.allocatePromotion(*promo_w0_, size, /*per_alloc_sweep=*/true);
#endif
        return oldgen.allocate(size);
    }
#if ENABLE_GC_STATS
    OldGenSpace::PromoWorker* promo_w0_ = nullptr;
#endif
public:
    // threaded-gc-06 test switches (stats builds; written only between minors).
    bool test_serial_promo_via_ctx_ = false;   // Step 4 identity switch
    // Runs every minor through the parallel engine, even with one worker and
    // below minor_parallel_min_bytes (tests; ECO_TEST_MINOR_ENGINE=P).
    bool test_force_parallel_engine_ = false;
    // Negative controls (P§3.13): every k-th claim winner copies again (PM1
    // must fire); one retired LAB tail is left unformatted (PM3/IM7 must fire).
    uint64_t test_minor_double_copy_every_ = 0;
    bool test_minor_skip_filler_ = false;
private:

    // ========== Parallel minor GC (threaded-gc-06, HEAP_067) ==========
    struct MinorWorker {
        unsigned index = 0;                     // == its PromoWorker in the context
        // Private grey work (owner-only): stack[head, size). LIFO pops from the
        // back; FIFO (fifo_order_) pops at head, the serial Cheney's order.
        std::vector<uint64_t> stack;
        size_t head = 0;
        std::atomic<uint64_t> priv{0};          // pending private entries
        uint64_t pops = 0;
        markwork::WorkStealingDeque deque{10};
        markwork::MarkerCounters ctr;
        minorwork::Lab lab;
        minorwork::LabCounters lc;
        GCStats::MinorCopyCounts copies;
        uint64_t n_surv = 0, b_surv = 0, n_prom = 0, n_ylos_prom = 0;   // every build
        uint64_t claim_races = 0, busy_waits = 0, spine_splits = 0, chunks = 0;
        uint64_t ylos_reach_calls = 0, ylos_scans = 0;
        uint64_t busy_ns = 0;
        uint64_t claims_won = 0;                // negative-control counter
        std::vector<HPointer> lb_seen, lb_promoted;   // deferred large-body ops (P§3.9)
        std::vector<void*> ylos_young;          // YLOS objects that stay young (census)
#if ECO_HEAP_VALIDATE || P1_CENSUS_COMPILED
        std::vector<void*> promoted_log;
#endif
        void resetRun();
    };
    struct MinorEnv;
    friend struct MinorEnv;
    struct RegionEnv;
    friend struct RegionEnv;
    struct TenureHeapEnv;
    friend struct TenureHeapEnv;
    struct TenureParEnv;
    friend struct TenureParEnv;
    // threaded-gc-07 region drain (NurseryRegion.cpp).
    enum : uint32_t { kColSurv = 0, kColYoungYlos = 1, kColBuilder = 2, kColHandYlos = 3, kColRoot = 4 };
    void evacuateR(MinorWorker& w, region::RegionWorker& rw, HPointer& slot, uint32_t col);
    void* copyClaimedR(MinorWorker& w, region::RegionWorker& rw, void* obj, uint64_t hw);
    void scanEntryR(MinorWorker& w, uint64_t e);
    void spineRunR(MinorWorker& w, region::RegionWorker& rw, Cons* prev, uint32_t col);
    void reachYoungLargeR(MinorWorker& w, region::RegionWorker& rw, void* obj);
    void* resolveRetire(void* t, region::RegionWorker* rw);
    static void regionWorkerEntry(void* ctx, unsigned member);
    void mergeJob(OldGenSpace& oldgen, bool heal, MinorGCRecord* rec);
    void runJobExact(OldGenSpace& oldgen, const std::atomic<bool>* stop);
    // threaded-gc-07b: the mark and sweep phases, serially (n = 1) or on the
    // minor's gang in a pause (help, fallback).
    void finishJobMarkPhases(OldGenSpace& oldgen, unsigned n = 1);
    struct AgeParEnv;
    friend struct AgeParEnv;
    static void ageParEntry(void* ctx, unsigned member);
    void runJobParallel(OldGenSpace& oldgen, unsigned n);
    static void tenureEntry(void* ctx, unsigned member);
    static void tenureParEntry(void* ctx, unsigned member);
    static void tenureConcEntry(void* ctx, unsigned member);
    void tenureParSetup(std::unique_ptr<MinorWorker>* ws, unsigned n);
    void tenureParSetupExtra(unsigned B, unsigned V);
    void tenureParDistribute(std::unique_ptr<MinorWorker>* ws, unsigned n);
    void tenureParCollect(std::unique_ptr<MinorWorker>* ws, unsigned n);
    void tenureConcLaunch(OldGenSpace& oldgen, unsigned B);
    void tenureConcFinish(OldGenSpace& oldgen, unsigned help_n, bool on_this_thread);
    // Lever L3: the collector members' worker slots, grant cursors, control.
    std::unique_ptr<MinorWorker> tenure_workers_[OldGenSpace::kMaxMinorWorkers];
    std::vector<OldGenSpace::TenureMemberCursor> tenure_mcs_;
    std::unique_ptr<markwork::SliceControl> tenure_ctl_;
    unsigned tenure_par_n_ = 0;
    void regionCheckAndGrow();
    void syncRegionStats();
    void regionEndMinorValidate(OldGenSpace& oldgen);
#if P1_CENSUS_COMPILED
    void censusRecordRegion(OldGenSpace& oldgen);
    void censusCheckRegion(OldGenSpace& oldgen);
#endif
    std::unique_ptr<MinorWorker> minor_workers_[OldGenSpace::kMaxMinorWorkers];
    minorwork::ToSpace tospace_;
    OldGenSpace* par_oldgen_ = nullptr;
    OldGenSpace::PromoCtx* par_ctx_ = nullptr;
    unsigned par_n_ = 0;
    std::mutex ylos_mu_;
    // Promoted objects of the previous minor (an object count: identical at
    // every worker count). Sizes the pre-drain sweep slice (P§3.8.5).
    size_t last_minor_promoted_ = 0;
    bool prefetch_children_ = false;
    bool fifo_order_ = false;        // grey order: see MinorWorker

    unsigned chooseMinorWorkers(OldGenSpace& oldgen);
    // Roots + drain + LAB close + merge of a parallel minor (P§3.1 steps 1-8).
    void minorGCParallel(OldGenSpace& oldgen, const StackMapRoots& stackmap_roots,
                         MinorGCRecord* rec, unsigned n);
    static void minorWorkerEntry(void* ctx, unsigned member);
    void evacuateP(MinorWorker& w, HPointer& slot, bool parent_old);
    void evacuateRawP(MinorWorker& w, uint64_t& raw);
    void* copyClaimed(MinorWorker& w, void* obj, uint64_t hw, bool parent_old);
    uint64_t waitPublishedP(MinorWorker& w, void* obj);
    void scanEntryP(MinorWorker& w, uint64_t e);
    void spineRunP(MinorWorker& w, Cons* prev);
    void reachYoungLargeP(MinorWorker& w, void* obj, bool parent_old);
    void pushGreyP(MinorWorker& w, uint64_t e);
    void publishHalfP(MinorWorker& w);
    void publishAllP(MinorWorker& w);
    static void writeFiller(char* p, size_t bytes);

    // W2 item 22: the same three-term test appeared verbatim at three sites.
    inline bool shouldPromote(const Header* hdr) const {
        return hdr->age >= promotion_age_ && !hdr->pin && !hdr->builder;
    }
    void scanObject(void *obj, OldGenSpace &oldgen, std::vector<void*> *promoted_objects);

    // threaded-gc-04b HEAP_062: a copier met a pointer inside the YLOS
    // bounding box. If `obj` is a young large object, reach it — record the
    // minor color, then promote it in place (queued on promoted_objects) at
    // promotion age, else age it and queue it on young_large_scan_ — and
    // return true: the pointer is unchanged (YLOS objects never move).
    // Returns false for any other object (the copier carries on).
    bool reachYoungLarge(void* obj, OldGenSpace& oldgen,
                         std::vector<void*>* promoted_objects);
#if ECO_HEAP_VALIDATE
    // V1 / V2 (plans/threaded-gc-04b-young-large-objects.md P§3.8).
    void validateYoungLarge(OldGenSpace& oldgen) const;
    void validatePromotedHaveNoYoungChildren(OldGenSpace& oldgen,
                                             const std::vector<void*>& promoted) const;
#endif

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
    friend class OldGenSpace;     // HEAP_053: mark path asks contains() directly
    friend class NurserySpaceTestAccess;
};

// ============================================================================
// Test Access Helper
// ============================================================================

// For test code only - provides privileged access to NurserySpace internals.
class NurserySpaceTestAccess {
public:
    // ---- threaded-gc-07 region nursery ----
    // Joins and merges the pending tenure job now (tests: run totals then
    // equal the legacy nursery's promoted totals, P§3.18).
    static void tenureFlush(NurserySpace& nursery, OldGenSpace& oldgen) {
        nursery.tenureJoin(oldgen, 0, nullptr);
    }
    static RegionState* region(NurserySpace& nursery) { return nursery.rg_.get(); }

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
    // 0 when end < ptr (a clamp below the bump pointer means "must collect").
    static size_t headroom(const NurserySpace& nursery) {
        const uintptr_t p = reinterpret_cast<uintptr_t>(nursery.bump_.ptr);
        const uintptr_t e = reinterpret_cast<uintptr_t>(nursery.bump_.end);
        return e >= p ? static_cast<size_t>(e - p) : 0;
    }

    static char* bumpPtr(const NurserySpace& nursery) { return nursery.bump_.ptr; }
    static char* bumpEnd(const NurserySpace& nursery) { return nursery.bump_.end; }
    static void setBumpEnd(NurserySpace& nursery, char* end) { nursery.bump_.end = end; }
#if P1_CENSUS_COMPILED
    // threaded-gc-00 Step 11: census control + readout for tests.
    static void setSurvivorWriteCensus(NurserySpace& nursery, bool on) {
        nursery.census_forced_ = on ? 1 : 0;
    }
    struct CensusCounts { uint64_t checked, mismatched, skipped_builder, ylos_checked; };
    static CensusCounts survivorWriteCensusCounts();
    static uint64_t survivorWriteCensusHits(int tag, uint32_t sub, uint16_t word);
    static void resetSurvivorWriteCensus();
#endif

    // Consumes headroom without going through allocate() so a test can park
    // the bump pointer at an exact offset inside the extent.
    static void bumpBy(NurserySpace& nursery, size_t bytes) {
        nursery.bump_.ptr += bytes;
    }

    // ---- threaded-gc-06 HEAP_068: fillers and object bytes ----

    // Simulates a parallel minor's LAB-tail filler: right after a minor GC
    // (the survivor prefix is exact), appends a Tag_Free filler of `bytes`
    // (multiple of 8, >= 8) to the survivor prefix and re-derives bump_.end.
    static void appendFillerAfterMinor(NurserySpace& nursery, size_t bytes) {
        assert(nursery.bump_.ptr == nursery.survivor_end_ && bytes >= 8 && bytes % 8 == 0);
        Header* h = reinterpret_cast<Header*>(nursery.bump_.ptr);
        std::memset(h, 0, sizeof(Header));
        h->tag = Tag_Free;
        h->size = static_cast<u32>(bytes);
        nursery.bump_.ptr += bytes;
        nursery.survivor_end_ = nursery.bump_.ptr;
        nursery.filler_bytes_ += bytes;
        nursery.bump_.end = nursery.computeAllocEnd();
    }
    static size_t fillerBytes(const NurserySpace& nursery) { return nursery.filler_bytes_; }
    static size_t objectBytesAllocated(const NurserySpace& nursery) {
        return nursery.objectBytesAllocated();
    }
    // Runs checkAndGrow as if a minor had copied `raw` bytes into to-space of
    // which `fillers` are Tag_Free fillers.
    static void checkAndGrowAt(NurserySpace& nursery, size_t raw, size_t fillers) {
        nursery.copy_ptr_ = nursery.toBase() + raw;
        nursery.filler_bytes_to_ = fillers;
        nursery.checkAndGrow();
        nursery.filler_bytes_to_ = 0;
    }

    // Forces the proactive-GC clamp to fire inside the extent, i.e. the
    // state ensureHeadroom must NOT advance past.
    static void clampEnd(NurserySpace& nursery, size_t headroom) {
        nursery.bump_.end = nursery.bump_.ptr + headroom;
    }
};

// threaded-gc-07 P§3.16: the t0 young walk. Legacy mode: the survivor prefix.
// TLA-REGION(NSH.forEachYoung) begin
template <typename F>
size_t NurserySpace::forEachYoung(F&& f, size_t* bytes_out) {
    if (!rg_) return forEachSurvivor(f, bytes_out);
    assert(bump_.ptr == rg_->eden_base && "IM7: eden is not empty; the young walk is not exact");
    size_t n = 0, bytes = 0;
    auto walk = [&](char* lo, char* hi) {
        for (char* p = lo; p < hi;) {
            const size_t sz = getObjectSize(p);
#if ECO_HEAP_VALIDATE
            if (getHeader(p)->tag > Tag_Forward || sz == 0 || p + sz > hi) {
                std::fprintf(stderr, "[heap-validate] IM7: bad young object at %p (tag %u, size %zu)\n",
                             static_cast<void*>(p), (unsigned)getHeader(p)->tag, sz);
                std::fflush(stderr);
                std::abort();
            }
#endif
            if (getHeader(p)->tag != Tag_Free) {
                f(static_cast<void*>(p));
                ++n;
                bytes += sz;
            }
            p += sz;
        }
    };
    // threaded-gc-07b: every Young extent (ageing ones included) and Tenuring;
    // dead objects are zapped fillers (07b merge; HEAP_074 STW major); only the
    // Fresh builder area is live.
    for (unsigned i = 0; i < rg_->n_surv; ++i) {
        region::Extent& X = rg_->x[i];
        if (X.state == region::XState::Young) {
            walk(X.base, X.surv_top);
            if (X.age == 1) walk(X.bld_lo, X.bld_hi);
        } else if (X.state == region::XState::Tenuring) {
            walk(X.base, X.surv_top);
        }
    }
    if (bytes_out) *bytes_out = bytes;
    return n;
}
// TLA-REGION(NSH.forEachYoung) end

} // namespace Elm

#endif // ECO_NURSERYSPACE_H
