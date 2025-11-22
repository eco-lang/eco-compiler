#include <algorithm>
#include <iomanip>
#include <iostream>
#include "GCStats.hpp"

namespace Elm {

void GCStats::recordAllocation(size_t bytes) {
    objects_allocated++;
    bytes_allocated += bytes;
}

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

size_t GCStats::getMinorHistogramBucket(uint64_t ns) const {
    if (ns >= MINOR_HISTOGRAM_MAX_NS) {
        return HISTOGRAM_BUCKETS - 1;  // Overflow bucket.
    }
    return ns / MINOR_BUCKET_SIZE_NS;
}

size_t GCStats::getMajorHistogramBucket(uint64_t ns) const {
    if (ns >= MAJOR_HISTOGRAM_MAX_NS) {
        return HISTOGRAM_BUCKETS - 1;  // Overflow bucket.
    }
    return ns / MAJOR_BUCKET_SIZE_NS;
}

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

    // Combine TLAB stats.
    tlabs_allocated += other.tlabs_allocated;
    tlabs_sealed += other.tlabs_sealed;

    // Combine Major GC event stats.
    concurrent_marks_started += other.concurrent_marks_started;
    mark_sweeps_completed += other.mark_sweeps_completed;
    incremental_mark_calls += other.incremental_mark_calls;
    total_incremental_mark_work_units += other.total_incremental_mark_work_units;

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
}

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

        double total_ms = total_minor_gc_time_ns / 1000000.0;
        std::cout << "  Total time:            " << std::setw(12) << std::fixed << std::setprecision(3)
                  << total_ms << " ms" << std::endl;

        uint64_t avg_ns = total_minor_gc_time_ns / minor_gc_count;
        double avg_us = avg_ns / 1000.0;
        std::cout << "  Average time:          " << std::setw(12) << std::fixed << std::setprecision(2)
                  << avg_us << " µs" << std::endl;

        if (min_minor_gc_time_ns != UINT64_MAX) {
            double min_us = min_minor_gc_time_ns / 1000.0;
            std::cout << "  Min time:              " << std::setw(12) << std::fixed << std::setprecision(2)
                      << min_us << " µs" << std::endl;
        }

        double max_us = max_minor_gc_time_ns / 1000.0;
        std::cout << "  Max time:              " << std::setw(12) << std::fixed << std::setprecision(2)
                  << max_us << " µs" << std::endl;
        std::cout << std::endl;

        // ========== Minor GC Histogram ==========
        std::cout << "Minor GC Time Histogram (nanoseconds):" << std::endl;

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
                uint64_t range_start = i * MINOR_BUCKET_SIZE_NS;
                uint64_t range_end = (i + 1) * MINOR_BUCKET_SIZE_NS;
                std::cout << "  " << std::setw(6) << range_start << " - "
                          << std::setw(6) << range_end << " ns: ";
            } else {
                std::cout << "  > " << std::setw(6) << MINOR_HISTOGRAM_MAX_NS << " ns: ";
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

    // ========== TLAB Stats ==========
    if (tlabs_allocated > 0 || tlabs_sealed > 0) {
        std::cout << "\nTLAB Statistics:" << std::endl;
        std::cout << "  TLABs allocated:       " << std::setw(12) << tlabs_allocated << std::endl;
        std::cout << "  TLABs sealed:          " << std::setw(12) << tlabs_sealed << std::endl;
    }

    // ========== Major GC Event Stats ==========
    if (major_gc_count > 0 || concurrent_marks_started > 0) {
        std::cout << "\nMajor GC:" << std::endl;
        std::cout << "  Major GC cycles:       " << std::setw(12) << major_gc_count << std::endl;
        std::cout << "  Concurrent marks:      " << std::setw(12) << concurrent_marks_started << std::endl;
        std::cout << "  Mark-sweeps completed: " << std::setw(12) << mark_sweeps_completed << std::endl;
        std::cout << "  Incremental marks:     " << std::setw(12) << incremental_mark_calls << std::endl;
        std::cout << "  Total work units:      " << std::setw(12) << total_incremental_mark_work_units << std::endl;
    }

    // ========== Major GC Timing Stats ==========
    if (major_gc_count > 0) {
        std::cout << "\nMajor GC Timing:" << std::endl;

        double total_ms = total_major_gc_time_ns / 1000000.0;
        std::cout << "  Total time:            " << std::setw(12) << std::fixed << std::setprecision(3)
                  << total_ms << " ms" << std::endl;

        uint64_t avg_ns = total_major_gc_time_ns / major_gc_count;
        double avg_ms = avg_ns / 1000000.0;
        std::cout << "  Average time:          " << std::setw(12) << std::fixed << std::setprecision(3)
                  << avg_ms << " ms" << std::endl;

        if (min_major_gc_time_ns != UINT64_MAX) {
            double min_ms = min_major_gc_time_ns / 1000000.0;
            std::cout << "  Min time:              " << std::setw(12) << std::fixed << std::setprecision(3)
                      << min_ms << " ms" << std::endl;
        }

        double max_ms = max_major_gc_time_ns / 1000000.0;
        std::cout << "  Max time:              " << std::setw(12) << std::fixed << std::setprecision(3)
                  << max_ms << " ms" << std::endl;
        std::cout << std::endl;

        // ========== Major GC Histogram ==========
        std::cout << "Major GC Time Histogram (milliseconds):" << std::endl;

        // Find max count for scaling.
        uint64_t max_count = 0;
        for (int i = 0; i < HISTOGRAM_BUCKETS; i++) {
            max_count = std::max(max_count, major_time_histogram[i]);
        }

        const int BAR_WIDTH = 40;

        for (int i = 0; i < HISTOGRAM_BUCKETS; i++) {
            if (major_time_histogram[i] == 0) continue;  // Skip empty buckets.

            // Bucket range (convert to milliseconds for display).
            if (i < HISTOGRAM_BUCKETS - 1) {
                double range_start = (i * MAJOR_BUCKET_SIZE_NS) / 1000000.0;
                double range_end = ((i + 1) * MAJOR_BUCKET_SIZE_NS) / 1000000.0;
                std::cout << "  " << std::setw(6) << std::fixed << std::setprecision(1) << range_start << " - "
                          << std::setw(6) << std::fixed << std::setprecision(1) << range_end << " ms: ";
            } else {
                double max_ms = MAJOR_HISTOGRAM_MAX_NS / 1000000.0;
                std::cout << "  > " << std::setw(6) << std::fixed << std::setprecision(1) << max_ms << " ms: ";
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

    std::cout << std::endl;
}

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

    // Reset TLAB stats.
    tlabs_allocated = 0;
    tlabs_sealed = 0;

    // Reset Major GC stats.
    concurrent_marks_started = 0;
    mark_sweeps_completed = 0;
    incremental_mark_calls = 0;
    total_incremental_mark_work_units = 0;
    major_gc_count = 0;
    total_major_gc_time_ns = 0;
    min_major_gc_time_ns = UINT64_MAX;
    max_major_gc_time_ns = 0;

    for (int i = 0; i < HISTOGRAM_BUCKETS; i++) {
        major_time_histogram[i] = 0;
    }
}

} // namespace Elm
