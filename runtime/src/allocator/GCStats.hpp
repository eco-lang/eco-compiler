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
    uint64_t bytes_freed = 0;  // Cumulative total across all GC cycles.

    // ========== Minor GC Timing Stats ==========
    uint64_t total_minor_gc_time_ns = 0;
    uint64_t min_minor_gc_time_ns = UINT64_MAX;
    uint64_t max_minor_gc_time_ns = 0;

    // Histogram with extended dynamic range:
    // - 20 buckets of 5us each (0-100us range)
    // - 18 buckets of 50us each (100us-1ms range)
    // - 1 overflow bucket (>1ms)
    static constexpr int HISTOGRAM_BUCKETS = 39;
    static constexpr uint64_t MINOR_HISTOGRAM_FIRST_RANGE = 100000;  // 100us (nanoseconds).
    static constexpr uint64_t MINOR_HISTOGRAM_SECOND_RANGE = 1000000; // 1ms (nanoseconds).
    static constexpr uint64_t MINOR_BUCKET_SIZE_SMALL = 5000;   // 5us bucket width (first range).
    static constexpr uint64_t MINOR_BUCKET_SIZE_LARGE = 50000;  // 50us bucket width (second range).
    static constexpr int MINOR_BUCKETS_SMALL = 20;  // Number of small buckets (0-100us).
    static constexpr int MINOR_BUCKETS_LARGE = 18;  // Number of large buckets (100us-1ms).

    uint64_t minor_time_histogram[HISTOGRAM_BUCKETS] = {0};

    // ========== AllocBuffer Stats ==========
    uint64_t buffers_allocated = 0;
    uint64_t buffers_filled = 0;

    // ========== Major GC Event Stats ==========
    uint64_t concurrent_marks_started = 0;
    uint64_t mark_sweeps_completed = 0;
    uint64_t incremental_mark_calls = 0;
    uint64_t total_incremental_mark_work_units = 0;

    // ========== Major GC Timing Stats ==========
    uint64_t major_gc_count = 0;
    uint64_t total_major_gc_time_ns = 0;
    uint64_t min_major_gc_time_ns = UINT64_MAX;
    uint64_t max_major_gc_time_ns = 0;

    // Major GC histogram using same bucket configuration as minor GC.
    uint64_t major_time_histogram[HISTOGRAM_BUCKETS] = {0};

    // ========== Methods ==========

    // Records an allocation event.
    void recordAllocation(size_t bytes);

    // Records completion of a minor GC cycle with timing and reclaimed bytes.
    void recordMinorGCEnd(uint64_t elapsed_ns, size_t freed);

    // Records completion of a major GC cycle with timing.
    void recordMajorGCEnd(uint64_t elapsed_ns);

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
