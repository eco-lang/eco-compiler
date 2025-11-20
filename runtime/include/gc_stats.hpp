#ifndef ECO_GC_STATS_H
#define ECO_GC_STATS_H

#include <chrono>
#include <cstdint>

// ============================================================================
// GC Statistics Configuration
// ============================================================================

// Global toggle: Set to 1 to enable stats, 0 to disable (zero overhead)
#define ENABLE_GC_STATS 1

namespace Elm {

// ============================================================================
// GC Statistics Class
// ============================================================================

class GCStats {
public:
    // ========== Allocation Stats ==========
    uint64_t objects_allocated = 0;
    uint64_t bytes_allocated = 0;

    // ========== GC Event Stats ==========
    uint64_t gc_count = 0;
    uint64_t objects_survived = 0;
    uint64_t objects_promoted = 0;
    uint64_t bytes_freed = 0;  // Running total across all GCs

    // ========== Timing Stats ==========
    uint64_t total_gc_time_ns = 0;
    uint64_t min_gc_time_ns = UINT64_MAX;
    uint64_t max_gc_time_ns = 0;

    // Histogram: 20 buckets of 5000ns each (0-100000), + 1 overflow bucket
    static constexpr int HISTOGRAM_BUCKETS = 21;
    static constexpr uint64_t HISTOGRAM_MAX_NS = 100000;
    static constexpr uint64_t BUCKET_SIZE_NS = HISTOGRAM_MAX_NS / (HISTOGRAM_BUCKETS - 1);

    uint64_t time_histogram[HISTOGRAM_BUCKETS] = {0};

    // ========== Methods ==========
    void recordAllocation(size_t bytes);
    void recordGCStart();
    void recordGCEnd(uint64_t elapsed_ns, size_t freed);
    void print() const;
    void reset();

private:
    std::chrono::high_resolution_clock::time_point gc_start_time;
    size_t getHistogramBucket(uint64_t ns) const;
};

// ============================================================================
// Zero-Overhead Macros
// ============================================================================

#if ENABLE_GC_STATS
    #define GC_STATS_RECORD_ALLOC(stats, bytes) \
        do { (stats).recordAllocation(bytes); } while(0)

    #define GC_STATS_RECORD_GC_END(stats, elapsed_ns, freed) \
        do { (stats).recordGCEnd(elapsed_ns, freed); } while(0)

    #define GC_STATS_INC_SURVIVORS(stats) \
        do { (stats).objects_survived++; } while(0)

    #define GC_STATS_INC_PROMOTED(stats) \
        do { (stats).objects_promoted++; } while(0)

    // Helper macro to capture timing scope
    #define GC_STATS_TIMER_START() \
        std::chrono::high_resolution_clock::now()

    #define GC_STATS_TIMER_ELAPSED_NS(start) \
        std::chrono::duration_cast<std::chrono::nanoseconds>( \
            std::chrono::high_resolution_clock::now() - (start)).count()

#else
    // Stats disabled - inject nothing (zero overhead)
    #define GC_STATS_RECORD_ALLOC(stats, bytes) do {} while(0)
    #define GC_STATS_RECORD_GC_END(stats, elapsed_ns, freed) do {} while(0)
    #define GC_STATS_INC_SURVIVORS(counter) do {} while(0)
    #define GC_STATS_INC_PROMOTED(counter) do {} while(0)
    #define GC_STATS_TIMER_START() 0
    #define GC_STATS_TIMER_ELAPSED_NS(start) 0
#endif

} // namespace Elm

#endif // ECO_GC_STATS_H
