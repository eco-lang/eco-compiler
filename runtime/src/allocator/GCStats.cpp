/**
 * GCStats Implementation.
 *
 * Tracks GC performance metrics including allocation counts, GC cycle timing,
 * and survival/promotion rates. Provides histogram visualization for latency
 * analysis. Zero overhead when ENABLE_GC_STATS is disabled.
 */

#include <algorithm>
#include <bit>
#include <iomanip>
#include <iostream>
#include <sstream>
#include "GCStats.hpp"

namespace Elm {

// Maps an allocation size in bytes to its power-of-two histogram bucket.
// Bucket k covers [8 << k, 8 << (k+1)); the last bucket absorbs anything
// at or above the histogram's upper bound.
static inline size_t allocSizeBucketIndex(size_t bytes, size_t num_buckets) {
    if (bytes < GCStats::ALLOC_HISTOGRAM_BASE) return 0;
    // floor(log2(bytes)); bit_width(x) returns 1 + floor(log2(x)) for x > 0.
    size_t log2_floor = static_cast<size_t>(std::bit_width(bytes)) - 1;
    // log2(8) = 3, so subtract 3 to make the [8,16) bucket index 0.
    size_t idx = (log2_floor >= 3) ? (log2_floor - 3) : 0;
    if (idx >= num_buckets - 1) return num_buckets - 1;
    return idx;
}

// Formats a byte size with appropriate units (B, KiB, MiB).
static std::string formatBytes(size_t bytes) {
    std::ostringstream oss;
    oss << std::fixed;
    if (bytes < 1024) {
        oss << bytes << " B";
    } else if (bytes < 1024 * 1024) {
        oss << std::setprecision(0) << (bytes / 1024.0) << " KiB";
    } else {
        oss << std::setprecision(0) << (bytes / (1024.0 * 1024.0)) << " MiB";
    }
    return oss.str();
}

// Helper to format nanoseconds with appropriate units.
// Returns a string like "123.45 ns", "1.23 µs", "45.67 ms", or "1.23 s"
static std::string formatTime(uint64_t ns) {
    std::ostringstream oss;
    oss << std::fixed;

    if (ns < 1000) {
        // Nanoseconds
        oss << std::setprecision(0) << ns << " ns";
    } else if (ns < 1000000) {
        // Microseconds
        oss << std::setprecision(2) << (ns / 1000.0) << " µs";
    } else if (ns < 1000000000) {
        // Milliseconds
        oss << std::setprecision(2) << (ns / 1000000.0) << " ms";
    } else {
        // Seconds
        oss << std::setprecision(2) << (ns / 1000000000.0) << " s";
    }
    return oss.str();
}

// Records a single allocation of the given size.
void GCStats::recordAllocation(size_t bytes) {
    objects_allocated++;
    bytes_allocated += bytes;

    size_t bucket = allocSizeBucketIndex(bytes, NURSERY_ALLOC_BUCKETS);
    nursery_alloc_size_histogram[bucket]++;
}

// Records a single old-generation allocation of the given size in the
// size-distribution histogram only.
void GCStats::recordOldGenAllocation(size_t bytes) {
    size_t bucket = allocSizeBucketIndex(bytes, OLDGEN_ALLOC_BUCKETS);
    oldgen_alloc_size_histogram[bucket]++;
}

// Records completion of a minor GC cycle with timing and reclaimed bytes.
void GCStats::recordMinorGCEnd(uint64_t elapsed_ns, size_t freed) {
    minor_gc_count++;
    total_minor_gc_time_ns += elapsed_ns;
    bytes_freed += freed;

    // Update min/max.
    min_minor_gc_time_ns = std::min(min_minor_gc_time_ns, elapsed_ns);
    max_minor_gc_time_ns = std::max(max_minor_gc_time_ns, elapsed_ns);

    // Record in histogram.
    size_t bucket = getMinorHistogramBucket(elapsed_ns);
    minor_time_histogram[bucket]++;
}

// Records completion of a major GC cycle with timing.
void GCStats::recordMajorGCEnd(uint64_t elapsed_ns) {
    major_gc_count++;
    total_major_gc_time_ns += elapsed_ns;

    // Update min/max.
    min_major_gc_time_ns = std::min(min_major_gc_time_ns, elapsed_ns);
    max_major_gc_time_ns = std::max(max_major_gc_time_ns, elapsed_ns);

    // Record in histogram.
    size_t bucket = getMajorHistogramBucket(elapsed_ns);
    major_time_histogram[bucket]++;
}

// Maps a minor GC duration to its histogram bucket index.
size_t GCStats::getMinorHistogramBucket(uint64_t ns) const {
    if (ns >= MINOR_HISTOGRAM_SECOND_RANGE) {
        return HISTOGRAM_BUCKETS - 1;  // Overflow bucket >1ms.
    }
    if (ns >= MINOR_HISTOGRAM_FIRST_RANGE) {
        // Second range: 100µs-1ms with 50µs buckets
        size_t offset = ns - MINOR_HISTOGRAM_FIRST_RANGE;
        return MINOR_BUCKETS_SMALL + (offset / MINOR_BUCKET_SIZE_LARGE);
    }
    // First range: 0-100µs with 5µs buckets
    return ns / MINOR_BUCKET_SIZE_SMALL;
}

// Maps a major GC duration to its histogram bucket index.
// Major GC uses millisecond scale buckets (5ms small, 50ms large).
size_t GCStats::getMajorHistogramBucket(uint64_t ns) const {
    // Bucket configuration:
    // - 20 buckets of 5ms each (0-100ms)
    // - 18 buckets of 50ms each (100ms-1000ms)
    // - 1 overflow bucket (>1000ms)
    static constexpr uint64_t MAJOR_FIRST_RANGE = 100000000;  // 100ms
    static constexpr uint64_t MAJOR_SECOND_RANGE = 1000000000; // 1000ms
    static constexpr uint64_t MAJOR_BUCKET_SMALL = 5000000;   // 5ms
    static constexpr uint64_t MAJOR_BUCKET_LARGE = 50000000;  // 50ms

    if (ns >= MAJOR_SECOND_RANGE) {
        return HISTOGRAM_BUCKETS - 1;  // Overflow bucket >1s.
    }
    if (ns >= MAJOR_FIRST_RANGE) {
        // Second range: 100ms-1s with 50ms buckets
        size_t offset = ns - MAJOR_FIRST_RANGE;
        return MINOR_BUCKETS_SMALL + (offset / MAJOR_BUCKET_LARGE);
    }
    // First range: 0-100ms with 5ms buckets
    return ns / MAJOR_BUCKET_SMALL;
}

// Merges statistics from another GCStats instance.
void GCStats::combine(const GCStats& other) {
    // Combine allocation stats.
    objects_allocated += other.objects_allocated;
    bytes_allocated += other.bytes_allocated;

    // Combine Minor GC event stats.
    minor_gc_count += other.minor_gc_count;
    objects_survived += other.objects_survived;
    objects_promoted += other.objects_promoted;
    bytes_freed += other.bytes_freed;

    // Combine Minor GC timing stats.
    total_minor_gc_time_ns += other.total_minor_gc_time_ns;
    if (other.min_minor_gc_time_ns < min_minor_gc_time_ns) {
        min_minor_gc_time_ns = other.min_minor_gc_time_ns;
    }
    if (other.max_minor_gc_time_ns > max_minor_gc_time_ns) {
        max_minor_gc_time_ns = other.max_minor_gc_time_ns;
    }

    // Combine Minor GC histogram.
    for (int i = 0; i < HISTOGRAM_BUCKETS; i++) {
        minor_time_histogram[i] += other.minor_time_histogram[i];
    }

    // Combine AllocBuffer stats.
    buffers_allocated += other.buffers_allocated;
    buffers_filled += other.buffers_filled;

    // Combine Major GC event stats.
    concurrent_marks_started += other.concurrent_marks_started;
    mark_sweeps_completed += other.mark_sweeps_completed;
    incremental_mark_calls += other.incremental_mark_calls;
    total_incremental_mark_work_units += other.total_incremental_mark_work_units;
    major_gc_occupancy_triggers += other.major_gc_occupancy_triggers;
    major_gc_alloc_failure_triggers += other.major_gc_alloc_failure_triggers;

    // Combine Major GC timing stats.
    major_gc_count += other.major_gc_count;
    total_major_gc_time_ns += other.total_major_gc_time_ns;
    if (other.min_major_gc_time_ns < min_major_gc_time_ns) {
        min_major_gc_time_ns = other.min_major_gc_time_ns;
    }
    if (other.max_major_gc_time_ns > max_major_gc_time_ns) {
        max_major_gc_time_ns = other.max_major_gc_time_ns;
    }

    // Combine Major GC histogram.
    for (int i = 0; i < HISTOGRAM_BUCKETS; i++) {
        major_time_histogram[i] += other.major_time_histogram[i];
    }

    // Combine allocation-size histograms.
    for (int i = 0; i < NURSERY_ALLOC_BUCKETS; i++) {
        nursery_alloc_size_histogram[i] += other.nursery_alloc_size_histogram[i];
    }
    for (int i = 0; i < OLDGEN_ALLOC_BUCKETS; i++) {
        oldgen_alloc_size_histogram[i] += other.oldgen_alloc_size_histogram[i];
    }
}

// Prints a formatted summary to stdout with histograms.
void GCStats::print() const {
    std::cout << "\n=== GC Statistics ===" << std::endl;
    std::cout << std::endl;

    // ========== Allocation Stats ==========
    std::cout << "Allocation:" << std::endl;
    std::cout << "  Objects allocated:     " << std::setw(12) << objects_allocated << std::endl;

    double bytes_mb = bytes_allocated / (1024.0 * 1024.0);
    std::cout << "  Bytes allocated:       " << std::setw(12) << std::fixed << std::setprecision(2)
              << bytes_mb << " MB" << std::endl;
    std::cout << std::endl;

    // ========== Minor GC Event Stats ==========
    std::cout << "Minor GC:" << std::endl;
    std::cout << "  Minor GC cycles:       " << std::setw(12) << minor_gc_count << std::endl;

    if (objects_allocated > 0) {
        double survival_rate = (objects_survived * 100.0) / objects_allocated;
        double promotion_rate = (objects_promoted * 100.0) / objects_allocated;

        std::cout << "  Objects survived:      " << std::setw(12) << objects_survived
                  << " (" << std::fixed << std::setprecision(1) << survival_rate << "%)" << std::endl;
        std::cout << "  Objects promoted:      " << std::setw(12) << objects_promoted
                  << " (" << std::fixed << std::setprecision(1) << promotion_rate << "%)" << std::endl;
    } else {
        std::cout << "  Objects survived:      " << std::setw(12) << objects_survived << std::endl;
        std::cout << "  Objects promoted:      " << std::setw(12) << objects_promoted << std::endl;
    }

    double freed_mb = bytes_freed / (1024.0 * 1024.0);
    std::cout << "  Bytes reclaimed:       " << std::setw(12) << std::fixed << std::setprecision(2)
              << freed_mb << " MB" << std::endl;
    std::cout << std::endl;

    // ========== Minor GC Timing Stats ==========
    if (minor_gc_count > 0) {
        std::cout << "\nMinor GC Timing:" << std::endl;

        std::cout << "  Total time:            " << std::setw(15) << formatTime(total_minor_gc_time_ns) << std::endl;

        uint64_t avg_ns = total_minor_gc_time_ns / minor_gc_count;
        std::cout << "  Average time:          " << std::setw(15) << formatTime(avg_ns) << std::endl;

        if (min_minor_gc_time_ns != UINT64_MAX) {
            std::cout << "  Min time:              " << std::setw(15) << formatTime(min_minor_gc_time_ns) << std::endl;
        }

        std::cout << "  Max time:              " << std::setw(15) << formatTime(max_minor_gc_time_ns) << std::endl;
        std::cout << std::endl;

        // ========== Minor GC Histogram ==========
        std::cout << "Minor GC Time Histogram:" << std::endl;

        // Find max count for scaling.
        uint64_t max_count = 0;
        for (int i = 0; i < HISTOGRAM_BUCKETS; i++) {
            max_count = std::max(max_count, minor_time_histogram[i]);
        }

        const int BAR_WIDTH = 40;

        for (int i = 0; i < HISTOGRAM_BUCKETS; i++) {
            if (minor_time_histogram[i] == 0) continue;  // Skip empty buckets.

            // Bucket range.
            if (i < HISTOGRAM_BUCKETS - 1) {
                uint64_t range_start, range_end;

                if (i < MINOR_BUCKETS_SMALL) {
                    // First range: 0-100µs with 5µs buckets
                    range_start = i * MINOR_BUCKET_SIZE_SMALL;
                    range_end = (i + 1) * MINOR_BUCKET_SIZE_SMALL;
                } else {
                    // Second range: 100µs-1ms with 50µs buckets
                    size_t offset = i - MINOR_BUCKETS_SMALL;
                    range_start = MINOR_HISTOGRAM_FIRST_RANGE + (offset * MINOR_BUCKET_SIZE_LARGE);
                    range_end = MINOR_HISTOGRAM_FIRST_RANGE + ((offset + 1) * MINOR_BUCKET_SIZE_LARGE);
                }

                std::cout << "  " << std::setw(10) << formatTime(range_start) << " - "
                          << std::setw(10) << formatTime(range_end) << ": ";
            } else {
                std::cout << "  > " << std::setw(10) << formatTime(MINOR_HISTOGRAM_SECOND_RANGE) << "     : ";
            }

            // Draw bar.
            int bar_len = max_count > 0 ? (minor_time_histogram[i] * BAR_WIDTH) / max_count : 0;
            for (int j = 0; j < bar_len; j++) {
                std::cout << "█";
            }

            // Show count and percentage.
            double percentage = (minor_time_histogram[i] * 100.0) / minor_gc_count;
            std::cout << " " << minor_time_histogram[i] << " (" << std::fixed << std::setprecision(1)
                      << percentage << "%)" << std::endl;
        }
    }

    // ========== AllocBuffer Stats ==========
    if (buffers_allocated > 0 || buffers_filled > 0) {
        std::cout << "\nAllocBuffer Statistics:" << std::endl;
        std::cout << "  Buffers allocated:     " << std::setw(12) << buffers_allocated << std::endl;
        std::cout << "  Buffers filled:        " << std::setw(12) << buffers_filled << std::endl;
    }

    // ========== Major GC Event Stats ==========
    // Always printed so a run with zero major GC activity is visible rather than omitted.
    std::cout << "\nMajor GC:" << std::endl;
    std::cout << "  Major GC cycles:       " << std::setw(12) << major_gc_count << std::endl;
    std::cout << "  Concurrent marks:      " << std::setw(12) << concurrent_marks_started << std::endl;
    std::cout << "  Mark-sweeps completed: " << std::setw(12) << mark_sweeps_completed << std::endl;
    std::cout << "  Incremental marks:     " << std::setw(12) << incremental_mark_calls << std::endl;
    std::cout << "  Total work units:      " << std::setw(12) << total_incremental_mark_work_units << std::endl;
    std::cout << "  Occupancy triggers:    " << std::setw(12) << major_gc_occupancy_triggers << std::endl;
    std::cout << "  Alloc-fail triggers:   " << std::setw(12) << major_gc_alloc_failure_triggers << std::endl;

    // ========== Major GC Timing Stats ==========
    if (major_gc_count > 0) {
        std::cout << "\nMajor GC Timing:" << std::endl;

        std::cout << "  Total time:            " << std::setw(15) << formatTime(total_major_gc_time_ns) << std::endl;

        uint64_t avg_ns = total_major_gc_time_ns / major_gc_count;
        std::cout << "  Average time:          " << std::setw(15) << formatTime(avg_ns) << std::endl;

        if (min_major_gc_time_ns != UINT64_MAX) {
            std::cout << "  Min time:              " << std::setw(15) << formatTime(min_major_gc_time_ns) << std::endl;
        }

        std::cout << "  Max time:              " << std::setw(15) << formatTime(max_major_gc_time_ns) << std::endl;
        std::cout << std::endl;

        // ========== Major GC Histogram ==========
        std::cout << "Major GC Time Histogram:" << std::endl;

        // Find max count for scaling.
        uint64_t max_count = 0;
        for (int i = 0; i < HISTOGRAM_BUCKETS; i++) {
            max_count = std::max(max_count, major_time_histogram[i]);
        }

        const int BAR_WIDTH = 40;

        // Use the same constants as in getMajorHistogramBucket
        static constexpr uint64_t MAJOR_FIRST_RANGE = 100000000;  // 100ms
        static constexpr uint64_t MAJOR_SECOND_RANGE = 1000000000; // 1000ms
        static constexpr uint64_t MAJOR_BUCKET_SMALL = 5000000;   // 5ms
        static constexpr uint64_t MAJOR_BUCKET_LARGE = 50000000;  // 50ms

        for (int i = 0; i < HISTOGRAM_BUCKETS; i++) {
            if (major_time_histogram[i] == 0) continue;  // Skip empty buckets.

            // Bucket range.
            if (i < HISTOGRAM_BUCKETS - 1) {
                uint64_t range_start, range_end;

                if (i < MINOR_BUCKETS_SMALL) {
                    // First range: 0-100ms with 5ms buckets
                    range_start = i * MAJOR_BUCKET_SMALL;
                    range_end = (i + 1) * MAJOR_BUCKET_SMALL;
                } else {
                    // Second range: 100ms-1s with 50ms buckets
                    size_t offset = i - MINOR_BUCKETS_SMALL;
                    range_start = MAJOR_FIRST_RANGE + (offset * MAJOR_BUCKET_LARGE);
                    range_end = MAJOR_FIRST_RANGE + ((offset + 1) * MAJOR_BUCKET_LARGE);
                }

                std::cout << "  " << std::setw(10) << formatTime(range_start) << " - "
                          << std::setw(10) << formatTime(range_end) << ": ";
            } else {
                std::cout << "  > " << std::setw(10) << formatTime(MAJOR_SECOND_RANGE) << "     : ";
            }

            // Draw bar.
            int bar_len = max_count > 0 ? (major_time_histogram[i] * BAR_WIDTH) / max_count : 0;
            for (int j = 0; j < bar_len; j++) {
                std::cout << "█";
            }

            // Show count and percentage.
            double percentage = (major_time_histogram[i] * 100.0) / major_gc_count;
            std::cout << " " << major_time_histogram[i] << " (" << std::fixed << std::setprecision(1)
                      << percentage << "%)" << std::endl;
        }
    }

    // ========== Allocation Size Histograms ==========
    auto printAllocHistogram = [](const char* title,
                                  const uint64_t* hist,
                                  int num_buckets) {
        uint64_t total = 0;
        uint64_t max_count = 0;
        for (int i = 0; i < num_buckets; i++) {
            total += hist[i];
            max_count = std::max(max_count, hist[i]);
        }
        if (total == 0) return;

        std::cout << "\n" << title << ":" << std::endl;
        const int BAR_WIDTH = 40;

        for (int i = 0; i < num_buckets; i++) {
            if (hist[i] == 0) continue;

            // Bucket k covers [BASE << k, BASE << (k+1)); the last bucket
            // is the overflow bucket for sizes at or above BASE << (n-1).
            size_t range_start = ALLOC_HISTOGRAM_BASE << i;
            if (i < num_buckets - 1) {
                size_t range_end = ALLOC_HISTOGRAM_BASE << (i + 1);
                std::cout << "  " << std::setw(8) << formatBytes(range_start)
                          << " - " << std::setw(8) << formatBytes(range_end) << ": ";
            } else {
                std::cout << "  >= " << std::setw(8) << formatBytes(range_start)
                          << "        : ";
            }

            int bar_len = max_count > 0
                ? static_cast<int>((hist[i] * BAR_WIDTH) / max_count)
                : 0;
            for (int j = 0; j < bar_len; j++) std::cout << "█";

            double percentage = (hist[i] * 100.0) / total;
            std::cout << " " << hist[i] << " (" << std::fixed
                      << std::setprecision(1) << percentage << "%)" << std::endl;
        }
    };

    printAllocHistogram("Nursery Allocation Size Histogram",
                        nursery_alloc_size_histogram,
                        NURSERY_ALLOC_BUCKETS);
    printAllocHistogram("Old-Gen Allocation Size Histogram",
                        oldgen_alloc_size_histogram,
                        OLDGEN_ALLOC_BUCKETS);

    std::cout << std::endl;
}

// Resets all statistics to zero.
void GCStats::reset() {
    // Reset allocation stats.
    objects_allocated = 0;
    bytes_allocated = 0;

    // Reset Minor GC stats.
    minor_gc_count = 0;
    objects_survived = 0;
    objects_promoted = 0;
    bytes_freed = 0;
    total_minor_gc_time_ns = 0;
    min_minor_gc_time_ns = UINT64_MAX;
    max_minor_gc_time_ns = 0;

    for (int i = 0; i < HISTOGRAM_BUCKETS; i++) {
        minor_time_histogram[i] = 0;
    }

    // Reset AllocBuffer stats.
    buffers_allocated = 0;
    buffers_filled = 0;

    // Reset Major GC stats.
    concurrent_marks_started = 0;
    mark_sweeps_completed = 0;
    incremental_mark_calls = 0;
    total_incremental_mark_work_units = 0;
    major_gc_occupancy_triggers = 0;
    major_gc_alloc_failure_triggers = 0;
    major_gc_count = 0;
    total_major_gc_time_ns = 0;
    min_major_gc_time_ns = UINT64_MAX;
    max_major_gc_time_ns = 0;

    for (int i = 0; i < HISTOGRAM_BUCKETS; i++) {
        major_time_histogram[i] = 0;
    }

    for (int i = 0; i < NURSERY_ALLOC_BUCKETS; i++) {
        nursery_alloc_size_histogram[i] = 0;
    }
    for (int i = 0; i < OLDGEN_ALLOC_BUCKETS; i++) {
        oldgen_alloc_size_histogram[i] = 0;
    }
}

} // namespace Elm
