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

// Definition for the in-minor-GC flag declared in GCStats.hpp.
thread_local bool g_in_minor_gc = false;

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

// ---------------------------------------------------------------------------
// Histogram printing helpers
// ---------------------------------------------------------------------------
//
// Both helpers are parameterised by the histogram arrays so the same
// formatting code emits the cumulative ("over N major-GC end snapshots")
// and the most-recent ("at last major-GC end") variants. `header_label`
// distinguishes the two sections in the printed output.

static void printResidencyHistogramBlock(
    const char* header_label,
    const uint64_t residency_pages[GCStats::RESIDENCY_BUCKETS],
    const uint64_t residency_page_bytes[GCStats::RESIDENCY_BUCKETS],
    const uint64_t residency_live_bytes[GCStats::RESIDENCY_BUCKETS],
    const uint64_t residency_garbage_bytes[GCStats::RESIDENCY_BUCKETS],
    const uint64_t residency_free_bytes[GCStats::RESIDENCY_BUCKETS],
    uint64_t residency_pinned_pages,
    uint64_t residency_pinned_page_bytes,
    uint64_t residency_pinned_live_bytes,
    uint64_t residency_pinned_garbage_bytes,
    uint64_t residency_pinned_free_bytes,
    uint64_t residency_snapshots,
    bool include_per_major_avg) {
    if (residency_snapshots == 0) return;

    static const char* RESIDENCY_LABELS[GCStats::RESIDENCY_BUCKETS] = {
        "  0.00      ",
        "(0.00, 0.01]",
        "(0.01, 0.05]",
        "(0.05, 0.10]",
        "(0.10, 0.25]",
        "(0.25, 0.50]",
        "(0.50, 0.75]",
        "(0.75, 1.00]",
    };

    uint64_t total_pages  = 0;
    uint64_t total_pbytes = 0;
    uint64_t total_lbytes = 0;
    uint64_t max_pages_b  = 0;
    for (int i = 0; i < GCStats::RESIDENCY_BUCKETS; i++) {
        total_pages  += residency_pages[i];
        total_pbytes += residency_page_bytes[i];
        total_lbytes += residency_live_bytes[i];
        max_pages_b   = std::max(max_pages_b, residency_pages[i]);
    }

    std::cout << "\nOld-Gen Page Residency Histogram (" << header_label
              << "):" << std::endl;
    std::cout << "  Each row shows live / free / garbage MB inside the\n"
                 "  blocks of that liveness band. free = bytes already\n"
                 "  on per-class free lists from the previous lazy\n"
                 "  sweep (allocatable). garbage = dead bytes the\n"
                 "  previous sweep never reached (still unswept). The\n"
                 "  live% column is live_MB / page_MB; free% and garb%\n"
                 "  are over the same total." << std::endl;
    std::cout << "  live_frac        pages    page_MB    live_MB    "
                 "free_MB    garb_MB   live%   free%   garb%"
              << std::endl;

    const int BAR_WIDTH = 30;
    const double MB = 1024.0 * 1024.0;
    uint64_t total_garb = 0;
    uint64_t total_free = 0;
    for (int i = 0; i < GCStats::RESIDENCY_BUCKETS; i++) {
        total_garb += residency_garbage_bytes[i];
        total_free += residency_free_bytes[i];
    }
    for (int i = 0; i < GCStats::RESIDENCY_BUCKETS; i++) {
        if (residency_pages[i] == 0) continue;

        const double page_mb = residency_page_bytes[i] / MB;
        const double live_mb = residency_live_bytes[i] / MB;
        const double free_mb = residency_free_bytes[i] / MB;
        const double garb_mb = residency_garbage_bytes[i] / MB;
        const double inv_pb  = residency_page_bytes[i] > 0
            ? 100.0 / residency_page_bytes[i] : 0.0;
        const double live_pct = residency_live_bytes[i]    * inv_pb;
        const double free_pct = residency_free_bytes[i]    * inv_pb;
        const double garb_pct = residency_garbage_bytes[i] * inv_pb;

        std::cout << "  " << RESIDENCY_LABELS[i] << " "
                  << std::setw(8)  << residency_pages[i] << " "
                  << std::setw(10) << std::fixed << std::setprecision(2)
                  << page_mb << " "
                  << std::setw(10) << std::fixed << std::setprecision(2)
                  << live_mb << " "
                  << std::setw(10) << std::fixed << std::setprecision(2)
                  << free_mb << " "
                  << std::setw(10) << std::fixed << std::setprecision(2)
                  << garb_mb << "  "
                  << std::setw(5) << std::fixed << std::setprecision(1)
                  << live_pct << "%  "
                  << std::setw(5) << std::fixed << std::setprecision(1)
                  << free_pct << "%  "
                  << std::setw(5) << std::fixed << std::setprecision(1)
                  << garb_pct << "%  ";

        int bar_len = max_pages_b > 0
            ? static_cast<int>((residency_pages[i] * BAR_WIDTH) / max_pages_b)
            : 0;
        for (int j = 0; j < bar_len; j++) std::cout << "█";
        std::cout << std::endl;
    }

    const double total_page_mb = total_pbytes / MB;
    const double total_live_mb = total_lbytes / MB;
    const double total_free_mb = total_free  / MB;
    const double total_garb_mb = total_garb  / MB;
    const double total_inv_pb  = total_pbytes > 0
        ? 100.0 / total_pbytes : 0.0;
    std::cout << "  total        " << std::setw(8) << total_pages << " "
              << std::setw(10) << std::fixed << std::setprecision(2)
              << total_page_mb << " "
              << std::setw(10) << std::fixed << std::setprecision(2)
              << total_live_mb << " "
              << std::setw(10) << std::fixed << std::setprecision(2)
              << total_free_mb << " "
              << std::setw(10) << std::fixed << std::setprecision(2)
              << total_garb_mb << "  "
              << std::setw(5) << std::fixed << std::setprecision(1)
              << (total_lbytes * total_inv_pb) << "%  "
              << std::setw(5) << std::fixed << std::setprecision(1)
              << (total_free  * total_inv_pb) << "%  "
              << std::setw(5) << std::fixed << std::setprecision(1)
              << (total_garb  * total_inv_pb) << "%"
              << std::endl;

    if (residency_pinned_pages > 0) {
        const double pin_page_mb = residency_pinned_page_bytes    / MB;
        const double pin_live_mb = residency_pinned_live_bytes    / MB;
        const double pin_free_mb = residency_pinned_free_bytes    / MB;
        const double pin_garb_mb = residency_pinned_garbage_bytes / MB;
        const double pin_inv_pb  = residency_pinned_page_bytes > 0
            ? 100.0 / residency_pinned_page_bytes : 0.0;
        std::cout << "  pinned       "
                  << std::setw(8) << residency_pinned_pages << " "
                  << std::setw(10) << std::fixed << std::setprecision(2)
                  << pin_page_mb << " "
                  << std::setw(10) << std::fixed << std::setprecision(2)
                  << pin_live_mb << " "
                  << std::setw(10) << std::fixed << std::setprecision(2)
                  << pin_free_mb << " "
                  << std::setw(10) << std::fixed << std::setprecision(2)
                  << pin_garb_mb << "  "
                  << std::setw(5) << std::fixed << std::setprecision(1)
                  << (residency_pinned_live_bytes    * pin_inv_pb) << "%  "
                  << std::setw(5) << std::fixed << std::setprecision(1)
                  << (residency_pinned_free_bytes    * pin_inv_pb) << "%  "
                  << std::setw(5) << std::fixed << std::setprecision(1)
                  << (residency_pinned_garbage_bytes * pin_inv_pb)
                  << "%   (subset; cannot be sweep-released)"
                  << std::endl;
    }

    if (include_per_major_avg && residency_snapshots > 0) {
        double avg_pages_per_major =
            static_cast<double>(total_pages) / residency_snapshots;
        double avg_committed_mb_per_major = total_page_mb / residency_snapshots;
        double avg_live_mb_per_major      = total_live_mb / residency_snapshots;
        double avg_free_mb_per_major      = total_free_mb / residency_snapshots;
        double avg_garb_mb_per_major      = total_garb_mb / residency_snapshots;
        std::cout << "  per-major avg: "
                  << std::fixed << std::setprecision(1)
                  << avg_pages_per_major << " pages, "
                  << std::fixed << std::setprecision(2)
                  << avg_committed_mb_per_major << " committed MB, "
                  << std::fixed << std::setprecision(2)
                  << avg_live_mb_per_major << " live MB, "
                  << std::fixed << std::setprecision(2)
                  << avg_free_mb_per_major << " free MB, "
                  << std::fixed << std::setprecision(2)
                  << avg_garb_mb_per_major << " garb MB"
                  << std::endl;
    }
}

static void printFreelistHistogramBlock(
    const char* header_label,
    const uint64_t freelist_cells_by_class[GCStats::FREELIST_CLASS_BUCKETS],
    const uint64_t freelist_bytes_by_class[GCStats::FREELIST_CLASS_BUCKETS],
    uint64_t freelist_large_block_count,
    uint64_t freelist_large_block_bytes,
    uint64_t freelist_snapshots,
    bool include_per_major_avg) {
    if (freelist_snapshots == 0) return;

    uint64_t total_cells = 0;
    uint64_t total_bytes = 0;
    uint64_t max_cells   = 0;
    for (int i = 0; i < GCStats::FREELIST_CLASS_BUCKETS; i++) {
        total_cells += freelist_cells_by_class[i];
        total_bytes += freelist_bytes_by_class[i];
        max_cells    = std::max(max_cells, freelist_cells_by_class[i]);
    }
    const uint64_t total_with_large = total_bytes + freelist_large_block_bytes;

    std::cout << "\nOld-Gen Free-List Size-Class Histogram ("
              << header_label << "):" << std::endl;
    std::cout << "  Cells parked on per-class free lists at each\n"
                 "  sample, just before the next major's transition\n"
                 "  clears them. cell_size is the exact byte size of\n"
                 "  every cell on that class. Concentration in tiny\n"
                 "  classes (8B..256B) means the heap is full of\n"
                 "  slivers that can't satisfy bigger requests."
              << std::endl;
    std::cout << "  cell_size       cells       bytes     bytes_MB    %bytes"
              << std::endl;

    const int BAR_WIDTH = 30;
    const double MB = 1024.0 * 1024.0;
    constexpr int NUM_SMALL = 32;
    constexpr int MEDIUM_BASE = 512;
    for (int i = 0; i < GCStats::FREELIST_CLASS_BUCKETS; i++) {
        if (freelist_cells_by_class[i] == 0) continue;

        const size_t cell_size = (i < NUM_SMALL)
            ? static_cast<size_t>((i + 1) * 8)
            : static_cast<size_t>(MEDIUM_BASE) << (i - NUM_SMALL);
        const double bytes_mb = freelist_bytes_by_class[i] / MB;
        const double bytes_pct = total_with_large > 0
            ? (freelist_bytes_by_class[i] * 100.0) / total_with_large
            : 0.0;

        std::cout << "  " << std::setw(8) << formatBytes(cell_size)
                  << "   " << std::setw(10)
                  << freelist_cells_by_class[i] << " "
                  << std::setw(11) << freelist_bytes_by_class[i] << " "
                  << std::setw(10) << std::fixed << std::setprecision(2)
                  << bytes_mb << "  "
                  << std::setw(5) << std::fixed << std::setprecision(1)
                  << bytes_pct << "%  ";

        int bar_len = max_cells > 0
            ? static_cast<int>((freelist_cells_by_class[i] * BAR_WIDTH)
                               / max_cells)
            : 0;
        for (int j = 0; j < bar_len; j++) std::cout << "█";
        std::cout << std::endl;
    }

    if (freelist_large_block_count > 0) {
        const double lb_mb  = freelist_large_block_bytes / MB;
        const double lb_pct = total_with_large > 0
            ? (freelist_large_block_bytes * 100.0) / total_with_large
            : 0.0;
        std::cout << "  large-blk    " << std::setw(10)
                  << freelist_large_block_count << " "
                  << std::setw(11) << freelist_large_block_bytes << " "
                  << std::setw(10) << std::fixed << std::setprecision(2)
                  << lb_mb << "  "
                  << std::setw(5) << std::fixed << std::setprecision(1)
                  << lb_pct << "%   (whole-block free entries)"
                  << std::endl;
    }

    const double total_bytes_mb = total_with_large / MB;
    std::cout << "  total        " << std::setw(10) << total_cells << " "
              << std::setw(11) << total_with_large << " "
              << std::setw(10) << std::fixed << std::setprecision(2)
              << total_bytes_mb << "  100.0%" << std::endl;

    if (include_per_major_avg) {
        const double avg_cells_per_major =
            static_cast<double>(total_cells) / freelist_snapshots;
        const double avg_bytes_mb_per_major =
            total_bytes_mb / freelist_snapshots;
        std::cout << "  per-major avg: "
                  << std::fixed << std::setprecision(1)
                  << avg_cells_per_major << " cells, "
                  << std::fixed << std::setprecision(2)
                  << avg_bytes_mb_per_major << " MB on free lists"
                  << std::endl;
    }
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

// Mutator-direct old-gen allocation: counted toward the cross-generation
// totals so the printed "Bytes allocated" line reflects all mutator
// allocations, not just nursery. Histogram is not touched here — that's
// already done by recordOldGenAllocation inside OldGenSpace::allocate.
void GCStats::recordOldGenDirectAllocation(size_t bytes) {
    objects_allocated++;
    bytes_allocated += bytes;
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

// Maps a per-block live fraction to its residency-histogram bucket.
// Buckets match the documentation in GCStats.hpp.
static inline int residencyBucket(double live_frac) {
    if (live_frac <= 0.0)  return 0;   // Fully empty.
    if (live_frac <= 0.01) return 1;
    if (live_frac <= 0.05) return 2;
    if (live_frac <= 0.10) return 3;
    if (live_frac <= 0.25) return 4;
    if (live_frac <= 0.50) return 5;
    if (live_frac <= 0.75) return 6;
    return 7;                          // (0.75, 1.00].
}

// Buckets a single block's residency by live fraction. Accumulates
// pages, committed bytes, and the live/free/garbage three-way byte
// breakdown per bucket so the printed histogram can surface shape,
// mass, and waste together. Garbage is derived as the residual
// (total - live - free), clamped to >= 0 in case rounding or partial
// sweep state pushes the sum slightly past total.
void GCStats::recordBlockResidency(size_t total_bytes,
                                   size_t live_bytes,
                                   size_t free_bytes,
                                   bool   is_large) {
    if (total_bytes == 0) return;
    if (live_bytes > total_bytes) live_bytes = total_bytes;
    if (free_bytes > total_bytes - live_bytes)
        free_bytes = total_bytes - live_bytes;
    const size_t garbage_bytes = total_bytes - live_bytes - free_bytes;

    const double live_frac = static_cast<double>(live_bytes) /
                             static_cast<double>(total_bytes);
    const int bucket = residencyBucket(live_frac);

    residency_pages[bucket]++;
    residency_page_bytes[bucket]    += total_bytes;
    residency_live_bytes[bucket]    += live_bytes;
    residency_garbage_bytes[bucket] += garbage_bytes;
    residency_free_bytes[bucket]    += free_bytes;

    latest_residency_pages[bucket]++;
    latest_residency_page_bytes[bucket]    += total_bytes;
    latest_residency_live_bytes[bucket]    += live_bytes;
    latest_residency_garbage_bytes[bucket] += garbage_bytes;
    latest_residency_free_bytes[bucket]    += free_bytes;

    if (is_large) {
        residency_pinned_pages++;
        residency_pinned_page_bytes    += total_bytes;
        residency_pinned_live_bytes    += live_bytes;
        residency_pinned_garbage_bytes += garbage_bytes;
        residency_pinned_free_bytes    += free_bytes;

        latest_residency_pinned_pages++;
        latest_residency_pinned_page_bytes    += total_bytes;
        latest_residency_pinned_live_bytes    += live_bytes;
        latest_residency_pinned_garbage_bytes += garbage_bytes;
        latest_residency_pinned_free_bytes    += free_bytes;
    }
}

void GCStats::beginResidencySnapshot() {
    for (int i = 0; i < RESIDENCY_BUCKETS; i++) {
        latest_residency_pages[i]         = 0;
        latest_residency_page_bytes[i]    = 0;
        latest_residency_live_bytes[i]    = 0;
        latest_residency_garbage_bytes[i] = 0;
        latest_residency_free_bytes[i]    = 0;
    }
    latest_residency_pinned_pages         = 0;
    latest_residency_pinned_page_bytes    = 0;
    latest_residency_pinned_live_bytes    = 0;
    latest_residency_pinned_garbage_bytes = 0;
    latest_residency_pinned_free_bytes    = 0;
    latest_residency_snapshots            = 0;
}

void GCStats::recordResidencySnapshot() {
    residency_snapshots++;
    latest_residency_snapshots = 1;
}

void GCStats::recordFreeListClass(size_t size_class,
                                  uint64_t cell_count,
                                  uint64_t cell_bytes) {
    if (size_class >= FREELIST_CLASS_BUCKETS) return;
    freelist_cells_by_class[size_class] += cell_count;
    freelist_bytes_by_class[size_class] += cell_bytes;
    latest_freelist_cells_by_class[size_class] += cell_count;
    latest_freelist_bytes_by_class[size_class] += cell_bytes;
}

void GCStats::recordFreeListLargeBlocks(uint64_t block_count,
                                        uint64_t total_bytes) {
    freelist_large_block_count += block_count;
    freelist_large_block_bytes += total_bytes;
    latest_freelist_large_block_count += block_count;
    latest_freelist_large_block_bytes += total_bytes;
}

void GCStats::beginFreeListSnapshot() {
    for (int i = 0; i < FREELIST_CLASS_BUCKETS; i++) {
        latest_freelist_cells_by_class[i] = 0;
        latest_freelist_bytes_by_class[i] = 0;
    }
    latest_freelist_large_block_count = 0;
    latest_freelist_large_block_bytes = 0;
    latest_freelist_snapshots         = 0;
}

void GCStats::recordFreeListSnapshot() {
    freelist_snapshots++;
    latest_freelist_snapshots = 1;
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

    // Combine inline-helper attribution.
    total_lazy_sweep_in_minor_ns += other.total_lazy_sweep_in_minor_ns;
    total_lazy_sweep_in_mutator_ns += other.total_lazy_sweep_in_mutator_ns;

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

    // Combine page residency histogram.
    for (int i = 0; i < RESIDENCY_BUCKETS; i++) {
        residency_pages[i]         += other.residency_pages[i];
        residency_page_bytes[i]    += other.residency_page_bytes[i];
        residency_live_bytes[i]    += other.residency_live_bytes[i];
        residency_garbage_bytes[i] += other.residency_garbage_bytes[i];
        residency_free_bytes[i]    += other.residency_free_bytes[i];
    }
    residency_pinned_pages         += other.residency_pinned_pages;
    residency_pinned_page_bytes    += other.residency_pinned_page_bytes;
    residency_pinned_live_bytes    += other.residency_pinned_live_bytes;
    residency_pinned_garbage_bytes += other.residency_pinned_garbage_bytes;
    residency_pinned_free_bytes    += other.residency_pinned_free_bytes;
    residency_snapshots            += other.residency_snapshots;

    // Combine latest residency snapshot. Each per-thread `latest_*` block
    // holds that thread's most recent major-GC end snapshot; summing
    // produces the union of those latest snapshots across threads, which
    // is what the printer reports as "Latest Major GC End".
    for (int i = 0; i < RESIDENCY_BUCKETS; i++) {
        latest_residency_pages[i]         += other.latest_residency_pages[i];
        latest_residency_page_bytes[i]    += other.latest_residency_page_bytes[i];
        latest_residency_live_bytes[i]    += other.latest_residency_live_bytes[i];
        latest_residency_garbage_bytes[i] += other.latest_residency_garbage_bytes[i];
        latest_residency_free_bytes[i]    += other.latest_residency_free_bytes[i];
    }
    latest_residency_pinned_pages         += other.latest_residency_pinned_pages;
    latest_residency_pinned_page_bytes    += other.latest_residency_pinned_page_bytes;
    latest_residency_pinned_live_bytes    += other.latest_residency_pinned_live_bytes;
    latest_residency_pinned_garbage_bytes += other.latest_residency_pinned_garbage_bytes;
    latest_residency_pinned_free_bytes    += other.latest_residency_pinned_free_bytes;
    latest_residency_snapshots            += other.latest_residency_snapshots;

    // Combine free-list size-class histogram.
    for (int i = 0; i < FREELIST_CLASS_BUCKETS; i++) {
        freelist_cells_by_class[i] += other.freelist_cells_by_class[i];
        freelist_bytes_by_class[i] += other.freelist_bytes_by_class[i];
    }
    freelist_large_block_count += other.freelist_large_block_count;
    freelist_large_block_bytes += other.freelist_large_block_bytes;
    freelist_snapshots         += other.freelist_snapshots;

    // Combine latest free-list snapshot (same union-of-latest semantics).
    for (int i = 0; i < FREELIST_CLASS_BUCKETS; i++) {
        latest_freelist_cells_by_class[i] += other.latest_freelist_cells_by_class[i];
        latest_freelist_bytes_by_class[i] += other.latest_freelist_bytes_by_class[i];
    }
    latest_freelist_large_block_count += other.latest_freelist_large_block_count;
    latest_freelist_large_block_bytes += other.latest_freelist_large_block_bytes;
    latest_freelist_snapshots         += other.latest_freelist_snapshots;
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

        // total_minor_gc_time_ns is the PURE nursery-copy time per cycle:
        // NurserySpace::minorGC subtracts the inline-helper time
        // (incremental mark + lazy sweep run via promotion → oldgen.allocate)
        // before recording. The histogram/min/max/avg below all reflect the
        // same pure-cycle accounting.
        std::cout << "  Total time:            " << std::setw(15) << formatTime(total_minor_gc_time_ns)
                  << "  (pure nursery-copy)" << std::endl;

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

    // ========== Inline GC Helper Time ==========
    //
    // Allocation-paced incremental mark + lazy sweep work that runs as a
    // side effect of OldGenSpace::allocate. This is GC work but doesn't
    // appear in the major-GC timer (it's incremental, not stop-the-world)
    // and is split into two buckets by calling context. Together with
    // minor + major above, the four GC buckets sum to the total GC wall
    // time; the remainder of wall_clock is mutator time.
    if (total_lazy_sweep_in_minor_ns > 0 ||
        total_lazy_sweep_in_mutator_ns > 0) {
        std::cout << "\nInline GC Helper Time:" << std::endl;
        std::cout << "  In minor pauses:       " << std::setw(15)
                  << formatTime(total_lazy_sweep_in_minor_ns)
                  << "  (subtracted from minor histogram)" << std::endl;
        std::cout << "  In mutator alloc:      " << std::setw(15)
                  << formatTime(total_lazy_sweep_in_mutator_ns)
                  << "  (subtract from mutator wall when accounting)"
                  << std::endl;
        std::cout << "  Total:                 " << std::setw(15)
                  << formatTime(total_lazy_sweep_in_minor_ns +
                                total_lazy_sweep_in_mutator_ns) << std::endl;
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

    // ========== Old-Gen Page Residency Histogram ==========
    //
    // Two flavours:
    //   - Cumulative: every major-GC end snapshot recorded over the run,
    //     with per-major averages.
    //   - Latest only: the final state at the most recent major-GC end
    //     (i.e. the heap at the moment the program is about to print).
    if (residency_snapshots > 0) {
        std::ostringstream cum_label;
        cum_label << "cumulative over " << residency_snapshots
                  << " major-GC end snapshots";
        printResidencyHistogramBlock(
            cum_label.str().c_str(),
            residency_pages, residency_page_bytes, residency_live_bytes,
            residency_garbage_bytes, residency_free_bytes,
            residency_pinned_pages, residency_pinned_page_bytes,
            residency_pinned_live_bytes, residency_pinned_garbage_bytes,
            residency_pinned_free_bytes, residency_snapshots,
            /*include_per_major_avg=*/true);
    }
    if (latest_residency_snapshots > 0) {
        printResidencyHistogramBlock(
            "latest: most recent major-GC end",
            latest_residency_pages, latest_residency_page_bytes,
            latest_residency_live_bytes, latest_residency_garbage_bytes,
            latest_residency_free_bytes,
            latest_residency_pinned_pages, latest_residency_pinned_page_bytes,
            latest_residency_pinned_live_bytes,
            latest_residency_pinned_garbage_bytes,
            latest_residency_pinned_free_bytes, latest_residency_snapshots,
            /*include_per_major_avg=*/false);
    }

    // ========== Free-List Size-Class Histogram ==========
    //
    // Cumulative across every major-GC end (with per-major averages),
    // followed by the latest snapshot (state of free lists at the most
    // recent major-GC end).
    if (freelist_snapshots > 0) {
        std::ostringstream cum_label;
        cum_label << "cumulative over " << freelist_snapshots
                  << " major-GC end snapshots";
        printFreelistHistogramBlock(
            cum_label.str().c_str(),
            freelist_cells_by_class, freelist_bytes_by_class,
            freelist_large_block_count, freelist_large_block_bytes,
            freelist_snapshots,
            /*include_per_major_avg=*/true);
    }
    if (latest_freelist_snapshots > 0) {
        printFreelistHistogramBlock(
            "latest: most recent major-GC end",
            latest_freelist_cells_by_class, latest_freelist_bytes_by_class,
            latest_freelist_large_block_count,
            latest_freelist_large_block_bytes,
            latest_freelist_snapshots,
            /*include_per_major_avg=*/false);
    }

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
    total_lazy_sweep_in_minor_ns = 0;
    total_lazy_sweep_in_mutator_ns = 0;
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

    // Reset page residency histogram.
    for (int i = 0; i < RESIDENCY_BUCKETS; i++) {
        residency_pages[i]         = 0;
        residency_page_bytes[i]    = 0;
        residency_live_bytes[i]    = 0;
        residency_garbage_bytes[i] = 0;
        residency_free_bytes[i]    = 0;
    }
    residency_pinned_pages         = 0;
    residency_pinned_page_bytes    = 0;
    residency_pinned_live_bytes    = 0;
    residency_pinned_garbage_bytes = 0;
    residency_pinned_free_bytes    = 0;
    residency_snapshots            = 0;

    // Reset latest residency snapshot (most recent major-GC end).
    for (int i = 0; i < RESIDENCY_BUCKETS; i++) {
        latest_residency_pages[i]         = 0;
        latest_residency_page_bytes[i]    = 0;
        latest_residency_live_bytes[i]    = 0;
        latest_residency_garbage_bytes[i] = 0;
        latest_residency_free_bytes[i]    = 0;
    }
    latest_residency_pinned_pages         = 0;
    latest_residency_pinned_page_bytes    = 0;
    latest_residency_pinned_live_bytes    = 0;
    latest_residency_pinned_garbage_bytes = 0;
    latest_residency_pinned_free_bytes    = 0;
    latest_residency_snapshots            = 0;

    // Reset free-list size-class histogram.
    for (int i = 0; i < FREELIST_CLASS_BUCKETS; i++) {
        freelist_cells_by_class[i] = 0;
        freelist_bytes_by_class[i] = 0;
    }
    freelist_large_block_count = 0;
    freelist_large_block_bytes = 0;
    freelist_snapshots         = 0;

    // Reset latest free-list snapshot (most recent major-GC end).
    for (int i = 0; i < FREELIST_CLASS_BUCKETS; i++) {
        latest_freelist_cells_by_class[i] = 0;
        latest_freelist_bytes_by_class[i] = 0;
    }
    latest_freelist_large_block_count = 0;
    latest_freelist_large_block_bytes = 0;
    latest_freelist_snapshots         = 0;
}

} // namespace Elm
