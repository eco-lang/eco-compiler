#include <algorithm>
#include <iomanip>
#include <iostream>
#include "GCStats.hpp"

namespace Elm {

void GCStats::recordAllocation(size_t bytes) {
    objects_allocated++;
    bytes_allocated += bytes;
}

void GCStats::recordGCStart() {
    gc_count++;
    gc_start_time = std::chrono::high_resolution_clock::now();
}

void GCStats::recordGCEnd(uint64_t elapsed_ns, size_t freed) {
    gc_count++;
    total_gc_time_ns += elapsed_ns;
    bytes_freed += freed;

    // Update min/max
    min_gc_time_ns = std::min(min_gc_time_ns, elapsed_ns);
    max_gc_time_ns = std::max(max_gc_time_ns, elapsed_ns);

    // Record in histogram
    size_t bucket = getHistogramBucket(elapsed_ns);
    time_histogram[bucket]++;
}

size_t GCStats::getHistogramBucket(uint64_t ns) const {
    if (ns >= HISTOGRAM_MAX_NS) {
        return HISTOGRAM_BUCKETS - 1;  // Overflow bucket
    }
    return ns / BUCKET_SIZE_NS;
}

void GCStats::print() const {
    std::cout << "\n=== GC Statistics (Thread-Local) ===" << std::endl;
    std::cout << std::endl;

    // ========== Allocation Stats ==========
    std::cout << "Allocation:" << std::endl;
    std::cout << "  Objects allocated:     " << std::setw(12) << objects_allocated << std::endl;

    double bytes_mb = bytes_allocated / (1024.0 * 1024.0);
    std::cout << "  Bytes allocated:       " << std::setw(12) << std::fixed << std::setprecision(2)
              << bytes_mb << " MB" << std::endl;
    std::cout << std::endl;

    // ========== GC Event Stats ==========
    std::cout << "Garbage Collection:" << std::endl;
    std::cout << "  GC cycles:             " << std::setw(12) << gc_count << std::endl;

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

    // ========== Timing Stats ==========
    if (gc_count > 0) {
        std::cout << "Timing:" << std::endl;

        double total_ms = total_gc_time_ns / 1000000.0;
        std::cout << "  Total GC time:         " << std::setw(12) << std::fixed << std::setprecision(3)
                  << total_ms << " ms" << std::endl;

        uint64_t avg_ns = total_gc_time_ns / gc_count;
        double avg_us = avg_ns / 1000.0;
        std::cout << "  Average GC time:       " << std::setw(12) << std::fixed << std::setprecision(2)
                  << avg_us << " µs" << std::endl;

        if (min_gc_time_ns != UINT64_MAX) {
            double min_us = min_gc_time_ns / 1000.0;
            std::cout << "  Min GC time:           " << std::setw(12) << std::fixed << std::setprecision(2)
                      << min_us << " µs" << std::endl;
        }

        double max_us = max_gc_time_ns / 1000.0;
        std::cout << "  Max GC time:           " << std::setw(12) << std::fixed << std::setprecision(2)
                  << max_us << " µs" << std::endl;
        std::cout << std::endl;

        // ========== Histogram ==========
        std::cout << "GC Time Histogram (nanoseconds):" << std::endl;

        // Find max count for scaling
        uint64_t max_count = 0;
        for (int i = 0; i < HISTOGRAM_BUCKETS; i++) {
            max_count = std::max(max_count, time_histogram[i]);
        }

        const int BAR_WIDTH = 40;

        for (int i = 0; i < HISTOGRAM_BUCKETS; i++) {
            if (time_histogram[i] == 0) continue;  // Skip empty buckets

            // Bucket range
            if (i < HISTOGRAM_BUCKETS - 1) {
                uint64_t range_start = i * BUCKET_SIZE_NS;
                uint64_t range_end = (i + 1) * BUCKET_SIZE_NS;
                std::cout << "  " << std::setw(6) << range_start << " - "
                          << std::setw(6) << range_end << " ns: ";
            } else {
                std::cout << "  > " << std::setw(6) << HISTOGRAM_MAX_NS << " ns: ";
            }

            // Draw bar
            int bar_len = max_count > 0 ? (time_histogram[i] * BAR_WIDTH) / max_count : 0;
            for (int j = 0; j < bar_len; j++) {
                std::cout << "█";
            }

            // Show count and percentage
            double percentage = (time_histogram[i] * 100.0) / gc_count;
            std::cout << " " << time_histogram[i] << " (" << std::fixed << std::setprecision(1)
                      << percentage << "%)" << std::endl;
        }
    }

    std::cout << std::endl;
}

void GCStats::reset() {
    objects_allocated = 0;
    bytes_allocated = 0;
    gc_count = 0;
    objects_survived = 0;
    objects_promoted = 0;
    bytes_freed = 0;
    total_gc_time_ns = 0;
    min_gc_time_ns = UINT64_MAX;
    max_gc_time_ns = 0;

    for (int i = 0; i < HISTOGRAM_BUCKETS; i++) {
        time_histogram[i] = 0;
    }
}

} // namespace Elm
