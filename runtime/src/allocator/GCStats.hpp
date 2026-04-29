/**
 * GC Statistics Tracking.
 *
 * Provides comprehensive telemetry for garbage collection performance analysis.
 * All tracking compiles to zero overhead when ENABLE_GC_STATS is set to 0.
 *
 * Tracks:
 *   - Allocation counts and bytes.
 *   - Minor/major GC cycle counts and timing histograms.
 *   - Object survival and promotion rates.
 *   - AllocBuffer usage.
 */

#ifndef ECO_GC_STATS_H
#define ECO_GC_STATS_H

#include <chrono>
#include <cstdint>

// ============================================================================
// GC Statistics Configuration
// ============================================================================

// Global toggle: set to 1 to enable stats, 0 to disable (zero overhead).
#define ENABLE_GC_STATS 1

namespace Elm {

// True only while the calling thread is inside NurserySpace::minorGC.
// Read by OldGenSpace::allocate to attribute its inline mark/sweep helper
// work to the GCStats::total_lazy_sweep_in_minor_ns counter when the
// allocation comes from a promotion (rather than a direct mutator alloc).
// Always-on (not gated on ECO_GC_DEBUG) because the stats path needs it.
extern thread_local bool g_in_minor_gc;

/**
 * Collects performance metrics for garbage collection.
 *
 * Tracks allocation counts, GC cycle counts, timing histograms, and
 * survival/promotion rates. Compiles to zero overhead when ENABLE_GC_STATS is 0.
 */
class GCStats {
public:
    // ========== Allocation Stats (Minor GC) ==========
    uint64_t objects_allocated = 0;
    uint64_t bytes_allocated = 0;

    // ========== Minor GC Event Stats ==========
    uint64_t minor_gc_count = 0;
    uint64_t objects_survived = 0;
    uint64_t objects_promoted = 0;
    uint64_t bytes_freed = 0;             // Cumulative total across all GC cycles.

    // ========== Minor GC Timing Stats ==========
    uint64_t total_minor_gc_time_ns = 0;
    uint64_t min_minor_gc_time_ns = UINT64_MAX;
    uint64_t max_minor_gc_time_ns = 0;

    // Histogram with extended dynamic range:
    //   - 20 buckets of 5us each (0-100us range).
    //   - 18 buckets of 50us each (100us-1ms range).
    //   - 1 overflow bucket (>1ms).
    static constexpr int HISTOGRAM_BUCKETS = 39;
    static constexpr uint64_t MINOR_HISTOGRAM_FIRST_RANGE = 100000;   // 100us in nanoseconds.
    static constexpr uint64_t MINOR_HISTOGRAM_SECOND_RANGE = 1000000; // 1ms in nanoseconds.
    static constexpr uint64_t MINOR_BUCKET_SIZE_SMALL = 5000;         // 5us bucket width.
    static constexpr uint64_t MINOR_BUCKET_SIZE_LARGE = 50000;        // 50us bucket width.
    static constexpr int MINOR_BUCKETS_SMALL = 20;  // Buckets for 0-100us range.
    static constexpr int MINOR_BUCKETS_LARGE = 18;  // Buckets for 100us-1ms range.

    uint64_t minor_time_histogram[HISTOGRAM_BUCKETS] = {0};

    // ========== Allocation Size Histograms ==========
    //
    // Power-of-two buckets keyed off the allocation size in bytes. Bucket k
    // covers [8 << k, 8 << (k+1)); the final bucket is an overflow bucket for
    // sizes at or above the histogram's upper bound.
    //
    // Nursery histogram covers 8 B up to the large-object threshold (8 KiB):
    //   buckets 0..9  => [8,16) [16,32) ... [4096,8192)
    //   bucket 10     => >= 8 KiB (objects this large bypass the nursery).
    //
    // Old-gen histogram covers 8 B up to 1 MiB:
    //   buckets 0..16 => [8,16) [16,32) ... [524288,1048576)
    //   bucket 17     => >= 1 MiB.
    static constexpr int NURSERY_ALLOC_BUCKETS = 11;
    static constexpr int OLDGEN_ALLOC_BUCKETS  = 18;
    static constexpr size_t ALLOC_HISTOGRAM_BASE = 8;  // bucket 0 starts here.

    uint64_t nursery_alloc_size_histogram[NURSERY_ALLOC_BUCKETS] = {0};
    uint64_t oldgen_alloc_size_histogram[OLDGEN_ALLOC_BUCKETS]   = {0};

    // ========== Old-Gen Page Residency Histogram ==========
    //
    // Snapshot taken once per major after finalizeMetaAfterMark and before
    // transitionToSweeping clears free_lists_. Each surviving old-gen block
    // is bucketed by live_bytes / totalBytes, and within the bucket we
    // accumulate a four-way byte breakdown:
    //
    //   live    — bytes the mark phase reached (mark-derived live_bytes)
    //   free    — bytes already parked on per-class free lists from the
    //             previous major's lazy sweep (allocatable, "good" non-live)
    //   garbage — dead bytes the previous lazy sweep never reached (still
    //             unswept; the new major must walk these again)
    //   (implicit) unallocated tail = total - live - free - garbage
    //
    // The free vs garbage split is the diagnostic question:
    //   - free dominates → fragmentation (unused space is allocatable but
    //     in the wrong size class for current demand)
    //   - garbage dominates → the lazy sweep is falling behind (we cannot
    //     even reclaim the dead bytes fast enough to put them on free lists)
    //
    // Counts accumulate across all majors for the lifetime of this GCStats.
    // Buckets are non-overlapping. The first matches live_bytes == 0
    // exactly (block fully empty); the rest are upper-inclusive ranges:
    //   0 : live_frac == 0           (fully empty after mark)
    //   1 : (0.00, 0.01]
    //   2 : (0.01, 0.05]
    //   3 : (0.05, 0.10]
    //   4 : (0.10, 0.25]
    //   5 : (0.25, 0.50]
    //   6 : (0.50, 0.75]
    //   7 : (0.75, 1.00]
    static constexpr int RESIDENCY_BUCKETS = 8;

    uint64_t residency_pages[RESIDENCY_BUCKETS]         = {0};
    uint64_t residency_page_bytes[RESIDENCY_BUCKETS]    = {0};
    uint64_t residency_live_bytes[RESIDENCY_BUCKETS]    = {0};
    uint64_t residency_garbage_bytes[RESIDENCY_BUCKETS] = {0};
    uint64_t residency_free_bytes[RESIDENCY_BUCKETS]    = {0};

    // Pinned (is_large) blocks are also recorded into the buckets above,
    // but additionally tracked here so the printer can highlight how much
    // of the residency is structurally locked (large blocks cannot be
    // released by sweep until their single object dies).
    uint64_t residency_pinned_pages         = 0;
    uint64_t residency_pinned_page_bytes    = 0;
    uint64_t residency_pinned_live_bytes    = 0;
    uint64_t residency_pinned_garbage_bytes = 0;
    uint64_t residency_pinned_free_bytes    = 0;

    // Number of major-GC end snapshots that contributed to the histogram.
    // Equal to the count of recordResidencySnapshot() calls. Used by the
    // printer to derive "average pages per major" alongside the totals.
    uint64_t residency_snapshots = 0;

    // ---- Latest-only snapshot (most recent major-GC end) ----
    //
    // Mirrors the residency arrays above but holds only the contributions
    // from the most recent major-GC end snapshot. Cleared on
    // beginResidencySnapshot() and re-populated by recordBlockResidency()
    // before recordResidencySnapshot() bumps `latest_residency_snapshots`
    // to 1. The printer surfaces this separately from the cumulative
    // histogram so the final state at program end can be inspected
    // unmerged from earlier majors.
    uint64_t latest_residency_pages[RESIDENCY_BUCKETS]         = {0};
    uint64_t latest_residency_page_bytes[RESIDENCY_BUCKETS]    = {0};
    uint64_t latest_residency_live_bytes[RESIDENCY_BUCKETS]    = {0};
    uint64_t latest_residency_garbage_bytes[RESIDENCY_BUCKETS] = {0};
    uint64_t latest_residency_free_bytes[RESIDENCY_BUCKETS]    = {0};
    uint64_t latest_residency_pinned_pages         = 0;
    uint64_t latest_residency_pinned_page_bytes    = 0;
    uint64_t latest_residency_pinned_live_bytes    = 0;
    uint64_t latest_residency_pinned_garbage_bytes = 0;
    uint64_t latest_residency_pinned_free_bytes    = 0;
    uint64_t latest_residency_snapshots            = 0;

    // ========== Free-List Size-Class Histogram ==========
    //
    // Snapshot of the per-class free-list contents at every major-GC end
    // (sampled at the same instant as the residency histogram, just before
    // transitionToSweeping clears the free lists). Counts accumulate across
    // every major for the lifetime of this GCStats.
    //
    // FREELIST_CLASS_BUCKETS must equal OldGenSpace::NUM_SIZE_CLASSES. We
    // do not include OldGenSpace.hpp here to avoid a header cycle; a
    // static_assert in OldGenSpace.cpp keeps the two values in sync.
    //
    // The histogram shows whether unused old-gen bytes are concentrated in
    // small cells (8B..256B; chronic small-object churn left the heap full
    // of slivers too small to satisfy larger requests) or in medium/large
    // cells (allocatable but the program isn't asking for sizes that fit).
    static constexpr int FREELIST_CLASS_BUCKETS = 40;  // 32 small + 8 medium
    uint64_t freelist_cells_by_class[FREELIST_CLASS_BUCKETS] = {0};
    uint64_t freelist_bytes_by_class[FREELIST_CLASS_BUCKETS] = {0};
    // Bytes parked in `free_large_blocks_` (whole-block free entries that
    // bypass the size-class lists). Recorded as one aggregate counter
    // because they don't have a size class.
    uint64_t freelist_large_block_bytes  = 0;
    uint64_t freelist_large_block_count  = 0;
    uint64_t freelist_snapshots          = 0;

    // ---- Latest-only snapshot (most recent major-GC end) ----
    //
    // Mirrors the free-list histogram fields above but holds only the
    // contributions from the most recent major-GC end snapshot. Cleared
    // on beginFreeListSnapshot() and re-populated by recordFreeListClass /
    // recordFreeListLargeBlocks before recordFreeListSnapshot() bumps
    // `latest_freelist_snapshots` to 1.
    uint64_t latest_freelist_cells_by_class[FREELIST_CLASS_BUCKETS] = {0};
    uint64_t latest_freelist_bytes_by_class[FREELIST_CLASS_BUCKETS] = {0};
    uint64_t latest_freelist_large_block_bytes  = 0;
    uint64_t latest_freelist_large_block_count  = 0;
    uint64_t latest_freelist_snapshots          = 0;

    // ========== AllocBuffer Stats ==========
    uint64_t buffers_allocated = 0;
    uint64_t buffers_filled = 0;

    // ========== Major GC Event Stats ==========
    uint64_t concurrent_marks_started = 0;
    uint64_t mark_sweeps_completed = 0;
    uint64_t incremental_mark_calls = 0;
    uint64_t total_incremental_mark_work_units = 0;

    // Distinguishes *why* a major GC ran: the 75% occupancy-initiating
    // trigger (soft, scheduled at a safepoint) vs. an allocation hitting
    // the old-gen cap (hard, inline in the alloc slow path).
    uint64_t major_gc_occupancy_triggers    = 0;
    uint64_t major_gc_alloc_failure_triggers = 0;

    // ========== Inline GC-helper attribution ==========
    //
    // OldGenSpace::allocate runs allocation-paced incremental mark and lazy
    // sweep work as a side effect. This is conceptually major-GC work but
    // it runs inline on the allocation hot path, so it doesn't show up in
    // the major-GC timer. Two counters split the wall-clock attribution by
    // calling context:
    //
    //   total_lazy_sweep_in_minor_ns
    //     Helper time accumulated while the calling thread is mid-minorGC
    //     (g_in_minor_gc == true), i.e. via promotion → oldgen.allocate.
    //     NurserySpace::minorGC subtracts this per-cycle from elapsed_ns
    //     before recording, so the minor histogram/min/max/avg reflect
    //     pure nursery-copy time.
    //
    //   total_lazy_sweep_in_mutator_ns
    //     Helper time accumulated when the mutator (not a minor GC) is
    //     calling oldgen.allocate (large-pinned, permanent, large region).
    //     Without this counter, this helper time is silently included in
    //     mutator_s; with it, the printout / parser can split it out so
    //     wall_s = minor + major + helper_in_minor + helper_in_mutator +
    //              mutator (all five buckets sum to wall clock).
    uint64_t total_lazy_sweep_in_minor_ns = 0;
    uint64_t total_lazy_sweep_in_mutator_ns = 0;

    // ========== Major GC Timing Stats ==========
    uint64_t major_gc_count = 0;
    uint64_t total_major_gc_time_ns = 0;
    uint64_t min_major_gc_time_ns = UINT64_MAX;
    uint64_t max_major_gc_time_ns = 0;

    // Major GC histogram using same bucket configuration as minor GC.
    uint64_t major_time_histogram[HISTOGRAM_BUCKETS] = {0};

    // ========== Methods ==========

    // Records a nursery allocation event (count, bytes, size histogram).
    void recordAllocation(size_t bytes);

    // Records an old-generation allocation event into the size histogram.
    // Called for EVERY old-gen allocation regardless of source (mutator
    // direct, promotion during minor GC, evacuation during compaction);
    // distinguishing them on this hot path would cost a branch per alloc.
    // Bytes/object totals are NOT incremented here — those are only updated
    // for mutator-initiated allocations via recordOldGenDirectAllocation.
    void recordOldGenAllocation(size_t bytes);

    // Records a mutator-initiated direct old-gen allocation (large objects,
    // permanent strings, large regions). Increments the cross-generation
    // bytes_allocated/objects_allocated totals so MBps-style metrics
    // include allocations that bypass the nursery. The size histogram is
    // already bumped by recordOldGenAllocation inside OldGenSpace::allocate,
    // so this method does NOT touch the histogram (avoids double-counting).
    void recordOldGenDirectAllocation(size_t bytes);

    // Records completion of a minor GC cycle with timing and reclaimed bytes.
    void recordMinorGCEnd(uint64_t elapsed_ns, size_t freed);

    // Records completion of a major GC cycle with timing.
    void recordMajorGCEnd(uint64_t elapsed_ns);

    // Adds one block's contribution to the residency histogram. Called
    // once per surviving old-gen block at major-GC end (sampled BEFORE
    // transitionToSweeping clears free lists, so `free_bytes` carries
    // the previous-major free-list residual for this block).
    //   total_bytes — block's full committed size (includes any tail).
    //   live_bytes  — mark-derived live size for this block.
    //   free_bytes  — bytes inside this block that are linked into a
    //                 per-class free list or `free_large_blocks_`.
    //   is_large    — flags pinned large-object blocks.
    // garbage_bytes is derived as max(0, total - live - free), i.e.
    // dead bytes that the previous lazy sweep didn't get to.
    void recordBlockResidency(size_t total_bytes,
                              size_t live_bytes,
                              size_t free_bytes,
                              bool   is_large);

    // Clears the latest_residency_* arrays so the next round of
    // recordBlockResidency() calls populates a fresh "most recent major"
    // snapshot. Call once per major-GC end BEFORE the per-block
    // recordBlockResidency() calls. Cumulative arrays are left untouched.
    void beginResidencySnapshot();

    // Increments residency_snapshots and sets latest_residency_snapshots
    // to 1; call once per major-GC end after every block has been
    // recorded.
    void recordResidencySnapshot();

    // Records the contents of one per-class free list into the size-class
    // histogram. `cell_count` and `cell_bytes` are the totals across the
    // sampled list at major-GC end. Call once per non-empty class per
    // snapshot (empty classes can be skipped with no effect).
    void recordFreeListClass(size_t size_class,
                             uint64_t cell_count,
                             uint64_t cell_bytes);

    // Records aggregate `free_large_blocks_` contribution at major-GC end.
    // These are whole-block free entries that bypass the size-class lists.
    void recordFreeListLargeBlocks(uint64_t block_count,
                                   uint64_t total_bytes);

    // Clears the latest_freelist_* arrays so the next round of
    // recordFreeListClass / recordFreeListLargeBlocks calls populates a
    // fresh "most recent major" snapshot. Call once per major-GC end
    // BEFORE the per-class recordFreeListClass calls.
    void beginFreeListSnapshot();

    // Increments freelist_snapshots and sets latest_freelist_snapshots
    // to 1; call once per major-GC end after every per-class entry has
    // been recorded.
    void recordFreeListSnapshot();

    // Merges statistics from another GCStats instance (for combining thread stats).
    void combine(const GCStats& other);

    // Prints a formatted summary to stdout with histograms.
    void print() const;

    // Resets all statistics to zero (clears all counters and histograms).
    void reset();

private:
    size_t getMinorHistogramBucket(uint64_t ns) const;
    size_t getMajorHistogramBucket(uint64_t ns) const;
};

// ============================================================================
// Zero-Overhead Macros
// ============================================================================

#if ENABLE_GC_STATS
    // ========== Minor GC Macros ==========

    #define GC_STATS_MINOR_RECORD_ALLOC(stats, bytes) \
        do { (stats).recordAllocation(bytes); } while(0)

    #define GC_STATS_OLDGEN_RECORD_ALLOC(stats, bytes) \
        do { (stats).recordOldGenAllocation(bytes); } while(0)

    #define GC_STATS_OLDGEN_DIRECT_RECORD_ALLOC(stats, bytes) \
        do { (stats).recordOldGenDirectAllocation(bytes); } while(0)

    #define GC_STATS_MINOR_RECORD_GC_END(stats, elapsed_ns, freed) \
        do { (stats).recordMinorGCEnd(elapsed_ns, freed); } while(0)

    #define GC_STATS_MINOR_INC_SURVIVORS(stats) \
        do { (stats).objects_survived++; } while(0)

    #define GC_STATS_MINOR_INC_PROMOTED(stats) \
        do { (stats).objects_promoted++; } while(0)

    // ========== Major GC Macros ==========
    #define GC_STATS_MAJOR_RECORD_GC_END(stats, elapsed_ns) \
        do { (stats).recordMajorGCEnd(elapsed_ns); } while(0)

    #define GC_STATS_MAJOR_INC_CONCURRENT_MARK(stats) \
        do { (stats).concurrent_marks_started++; } while(0)

    #define GC_STATS_MAJOR_INC_MARK_SWEEP(stats) \
        do { (stats).mark_sweeps_completed++; } while(0)

    #define GC_STATS_MAJOR_INC_INCREMENTAL_MARK(stats, work_units) \
        do { \
            (stats).incremental_mark_calls++; \
            (stats).total_incremental_mark_work_units += (work_units); \
        } while(0)

    // ========== AllocBuffer Macros ==========
    #define GC_STATS_BUFFER_ALLOCATED(stats) \
        do { (stats).buffers_allocated++; } while(0)

    #define GC_STATS_BUFFER_FILLED(stats) \
        do { (stats).buffers_filled++; } while(0)

    // ========== Helper Macros ==========
    #define GC_STATS_TIMER_START() \
        std::chrono::high_resolution_clock::now()

    #define GC_STATS_TIMER_ELAPSED_NS(start) \
        std::chrono::duration_cast<std::chrono::nanoseconds>( \
            std::chrono::high_resolution_clock::now() - (start)).count()

#else
    // Stats disabled - all macros expand to nothing (zero overhead).
    #define GC_STATS_MINOR_RECORD_ALLOC(stats, bytes) do {} while(0)
    #define GC_STATS_OLDGEN_RECORD_ALLOC(stats, bytes) do {} while(0)
    #define GC_STATS_OLDGEN_DIRECT_RECORD_ALLOC(stats, bytes) do {} while(0)
    #define GC_STATS_MINOR_RECORD_GC_END(stats, elapsed_ns, freed) do {} while(0)
    #define GC_STATS_MINOR_INC_SURVIVORS(stats) do {} while(0)
    #define GC_STATS_MINOR_INC_PROMOTED(stats) do {} while(0)
    #define GC_STATS_MAJOR_RECORD_GC_END(stats, elapsed_ns) do {} while(0)
    #define GC_STATS_MAJOR_INC_CONCURRENT_MARK(stats) do {} while(0)
    #define GC_STATS_MAJOR_INC_MARK_SWEEP(stats) do {} while(0)
    #define GC_STATS_MAJOR_INC_INCREMENTAL_MARK(stats, work_units) do {} while(0)
    #define GC_STATS_BUFFER_ALLOCATED(stats) do {} while(0)
    #define GC_STATS_BUFFER_FILLED(stats) do {} while(0)
    #define GC_STATS_TIMER_START() 0
    #define GC_STATS_TIMER_ELAPSED_NS(start) 0
#endif

} // namespace Elm

#endif // ECO_GC_STATS_H
