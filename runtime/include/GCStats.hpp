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

/**
 * Collects performance metrics for garbage collection.
 *
 * Tracks allocation counts, GC cycle counts, timing histograms, and
 * survival/promotion rates. Zero overhead when ENABLE_GC_STATS is 0.
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
    uint64_t bytes_freed = 0;  // Running total across all GCs.

    // ========== Minor GC Timing Stats ==========
    uint64_t total_minor_gc_time_ns = 0;
    uint64_t min_minor_gc_time_ns = UINT64_MAX;
    uint64_t max_minor_gc_time_ns = 0;

    // Histogram: Extended dynamic range
    // - 20 buckets of 5000ns each (0-100000ns)
    // - 18 buckets of 50000ns each (100000ns-1000000ns)
    // - 1 overflow bucket (>1000000ns)
    static constexpr int HISTOGRAM_BUCKETS = 39;
    static constexpr uint64_t MINOR_HISTOGRAM_FIRST_RANGE = 100000;  // 100µs
    static constexpr uint64_t MINOR_HISTOGRAM_SECOND_RANGE = 1000000; // 1ms
    static constexpr uint64_t MINOR_BUCKET_SIZE_SMALL = 5000;   // 5µs for first range
    static constexpr uint64_t MINOR_BUCKET_SIZE_LARGE = 50000;  // 50µs for second range
    static constexpr int MINOR_BUCKETS_SMALL = 20;  // 0-100µs
    static constexpr int MINOR_BUCKETS_LARGE = 18;  // 100µs-1ms

    uint64_t minor_time_histogram[HISTOGRAM_BUCKETS] = {0};

    // ========== TLAB Stats (Thread-Local) ==========
    uint64_t tlabs_allocated = 0;
    uint64_t tlabs_sealed = 0;

    // ========== Major GC Event Stats (Global Collector Thread) ==========
    uint64_t concurrent_marks_started = 0;
    uint64_t mark_sweeps_completed = 0;
    uint64_t incremental_mark_calls = 0;
    uint64_t total_incremental_mark_work_units = 0;

    // ========== Major GC Timing Stats ==========
    uint64_t major_gc_count = 0;
    uint64_t total_major_gc_time_ns = 0;
    uint64_t min_major_gc_time_ns = UINT64_MAX;
    uint64_t max_major_gc_time_ns = 0;

    // Major GC histogram: Using same bucket count as minor GC
    uint64_t major_time_histogram[HISTOGRAM_BUCKETS] = {0};

    // ========== Methods ==========

    // Records an allocation of the given size.
    void recordAllocation(size_t bytes);

    // Records completion of a minor GC cycle.
    void recordMinorGCEnd(uint64_t elapsed_ns, size_t freed);

    // Records completion of a major GC cycle.
    void recordMajorGCEnd(uint64_t elapsed_ns);

    // Merges statistics from another GCStats instance.
    void combine(const GCStats& other);

    // Prints a formatted summary to stdout.
    void print() const;

    // Resets all statistics to initial values.
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

    // ========== TLAB Macros ==========
    #define GC_STATS_TLAB_ALLOCATED(stats) \
        do { (stats).tlabs_allocated++; } while(0)

    #define GC_STATS_TLAB_SEALED(stats) \
        do { (stats).tlabs_sealed++; } while(0)

    // ========== Helper Macros ==========
    #define GC_STATS_TIMER_START() \
        std::chrono::high_resolution_clock::now()

    #define GC_STATS_TIMER_ELAPSED_NS(start) \
        std::chrono::duration_cast<std::chrono::nanoseconds>( \
            std::chrono::high_resolution_clock::now() - (start)).count()

#else
    // Stats disabled: all macros expand to nothing (zero overhead).
    #define GC_STATS_MINOR_RECORD_ALLOC(stats, bytes) do {} while(0)
    #define GC_STATS_MINOR_RECORD_GC_END(stats, elapsed_ns, freed) do {} while(0)
    #define GC_STATS_MINOR_INC_SURVIVORS(stats) do {} while(0)
    #define GC_STATS_MINOR_INC_PROMOTED(stats) do {} while(0)
    #define GC_STATS_MAJOR_RECORD_GC_END(stats, elapsed_ns) do {} while(0)
    #define GC_STATS_MAJOR_INC_CONCURRENT_MARK(stats) do {} while(0)
    #define GC_STATS_MAJOR_INC_MARK_SWEEP(stats) do {} while(0)
    #define GC_STATS_MAJOR_INC_INCREMENTAL_MARK(stats, work_units) do {} while(0)
    #define GC_STATS_TLAB_ALLOCATED(stats) do {} while(0)
    #define GC_STATS_TLAB_SEALED(stats) do {} while(0)
    #define GC_STATS_TIMER_START() 0
    #define GC_STATS_TIMER_ELAPSED_NS(start) 0
#endif

} // namespace Elm

#endif // ECO_GC_STATS_H
