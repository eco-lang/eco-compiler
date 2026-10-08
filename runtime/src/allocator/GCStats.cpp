/**
 * GCStats Implementation.
 *
 * Tracks GC performance metrics including allocation counts, GC cycle timing,
 * and survival/promotion rates. Provides histogram visualization for latency
 * analysis. Zero overhead when ENABLE_GC_STATS is disabled.
 */

#include <algorithm>
#include <atomic>
#include <cmath>
#include <bit>
#include <cstdio>
#include <cstdlib>
#include <iomanip>
#include <iostream>
#include <mutex>
#include <sstream>
#include <string>
#include <thread>
#include "Allocator.hpp"
#include "GCStats.hpp"
#include "PermanentSpace.hpp"
#include "ThreadLocalHeap.hpp"

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

// Maps a Tag enum value to a short human-readable name for the per-kind
// allocation histogram. Unknown values fall back to "Tag_<n>" so a new tag
// added without updating this table still prints something sensible.
static const char* tagName(int t) {
    switch (t) {
        case Tag_Int:               return "Int";
        case Tag_Float:             return "Float";
        case Tag_Char:              return "Char";
        case Tag_String:            return "String";
        case Tag_Tuple2:            return "Tuple2";
        case Tag_Tuple3:            return "Tuple3";
        case Tag_Cons:              return "Cons";
        case Tag_Custom:            return "Custom";
        case Tag_Record:            return "Record";
        case Tag_DynRecord:         return "DynRecord";
        case Tag_FieldGroup:        return "FieldGroup";
        case Tag_Closure:           return "Closure";
        case Tag_Process:           return "Process";
        case Tag_Task:              return "Task";
        case Tag_ByteBuffer:        return "ByteBuffer";
        case Tag_Array:             return "Array";
        case Tag_StringRope:        return "StringRope";
        case Tag_StringSlice:       return "StringSlice";
        case Tag_ByteBufferSlice:   return "ByteBufferSlice";
        case Tag_LargeStringHeader: return "LargeStringHeader";
        case Tag_LargeByteHeader:   return "LargeByteHeader";
        case Tag_StringUtf8View:    return "StringUtf8View";
        case Tag_StringUtf8Leaf:    return "StringUtf8Leaf";
        case Tag_ConsChunk:         return "ConsChunk";
        case Tag_ListBacking:       return "ListBacking";
        case Tag_Free:              return "Free";
        case Tag_Forward:           return "Forward";
        default:                    return "<unknown>";
    }
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
    if (bytes >= 16 && bytes < 24) nursery_alloc_size_16_24_count++;
}

// Records a single old-generation allocation of the given size in the
// size-distribution histogram only.
size_t GCStats::oldGenAllocBucket(size_t bytes) {
    return allocSizeBucketIndex(bytes, OLDGEN_ALLOC_BUCKETS);
}

void GCStats::mergeOldGenAllocHistogram(const uint64_t* buckets, uint64_t c16_24) {
    for (int i = 0; i < OLDGEN_ALLOC_BUCKETS; ++i) oldgen_alloc_size_histogram[i] += buckets[i];
    oldgen_alloc_size_16_24_count += c16_24;
}

void GCStats::recordOldGenAllocation(size_t bytes) {
    size_t bucket = allocSizeBucketIndex(bytes, OLDGEN_ALLOC_BUCKETS);
    oldgen_alloc_size_histogram[bucket]++;
    if (bytes >= 16 && bytes < 24) oldgen_alloc_size_16_24_count++;
}

// Records a single String allocation by heap-object byte size. Called from
// HeapHelpers::allocString before its large/inline-leaf dispatch, so the
// bucket reflects the object size that would actually be reserved on the
// heap (header + chars[], 8B-aligned).
void GCStats::recordStringAllocation(size_t bytes) {
    size_t bucket = allocSizeBucketIndex(bytes, STRING_ALLOC_BUCKETS);
    string_alloc_size_histogram[bucket]++;
}

void GCStats::recordUtf8Widen(size_t units) {
    utf8_widen_calls++;
    utf8_widen_units += units;
}

void GCStats::recordUtf8WidenSite(int site, size_t units) {
    if (site < 0 || site >= UTF8_WIDEN_SITE_COUNT) return;
    utf8_widen_site_calls[site]++;
    utf8_widen_site_units[site] += units;
}

// Records a typed mutator allocation through the ThreadLocalHeap path.
// Called from initHeaderForTag, exactly once per successful mutator alloc.
void GCStats::recordTLHAllocation(size_t bytes, Tag tag) {
    int idx = static_cast<int>(tag);
    if (idx < 0 || idx >= NUM_ALLOC_TAGS) return;
    tlh_alloc_count_by_tag[idx]++;
    tlh_alloc_bytes_by_tag[idx] += bytes;
}

// LH1 (plans/live-heap-composition-census.md). Called from the minor-GC
// evacuation paths in NurserySpace once per surviving/promoted object.
// The scalar is bumped here rather than at the call site so the totals and
// the per-kind histograms are incremented by the same statement and cannot
// diverge; an out-of-range tag (defensive — a live object should never
// carry Tag_Forward) still counts toward the scalar so promotion rates stay
// comparable with pre-LH1 runs.
// W1: bucket a Custom by field count (Header::size), clamping into the
// overflow slot. Non-Custom tags never reach here.
// W5 item 55: customArityBucket moved to GCStats.hpp as a static member.

// W5 item 55: recordPromotion is now inline in GCStats.hpp.

// W5 item 55: recordSurvival is now inline in GCStats.hpp.

// Helper: routes a per-tag mutator allocation event from a free function
// (initHeaderForTag) to the calling thread's GCStats. Exposed via the
// GC_STATS_TLH_RECORD_ALLOC macro; in stats-disabled builds the macro
// expands to nothing and this body is dead code.
void recordTLHAllocOnCurrentThread(size_t bytes, Tag tag) noexcept {
#if ENABLE_GC_STATS
    ThreadLocalHeap* tlh = Allocator::instance().getCurrentThreadHeap();
    if (tlh) tlh->getStats().recordTLHAllocation(bytes, tag);
#else
    // Stats disabled: ThreadLocalHeap has no getStats()/stats_, so the body
    // compiles away. The symbol is still emitted to satisfy the unconditional
    // declaration in GCStats.hpp, but nothing references it (the macro is a
    // no-op in this configuration).
    (void)bytes;
    (void)tag;
#endif
}

// String-histogram trampoline: same shape as the per-tag helper above, but
// no Tag is in scope at the call site (allocString is the tag's chokepoint).
void recordStringAllocOnCurrentThread(size_t bytes) noexcept {
#if ENABLE_GC_STATS
    ThreadLocalHeap* tlh = Allocator::instance().getCurrentThreadHeap();
    if (tlh) tlh->getStats().recordStringAllocation(bytes);
#else
    // See recordTLHAllocOnCurrentThread above: body is dead in stats-disabled
    // builds where getStats() does not exist.
    (void)bytes;
#endif
}

// UTF-8 widen trampoline: same shape as the String-histogram helper.
void recordUtf8WidenOnCurrentThread(size_t units) noexcept {
#if ENABLE_GC_STATS
    ThreadLocalHeap* tlh = Allocator::instance().getCurrentThreadHeap();
    if (tlh) tlh->getStats().recordUtf8Widen(units);
#else
    (void)units;
#endif
}

void recordUtf8WidenSiteOnCurrentThread(int site, size_t units) noexcept {
#if ENABLE_GC_STATS
    ThreadLocalHeap* tlh = Allocator::instance().getCurrentThreadHeap();
    if (tlh) tlh->getStats().recordUtf8WidenSite(site, units);
#else
    (void)site;
    (void)units;
#endif
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

    // Accumulate into the staging buffer for the in-progress snapshot.
    // The visible `latest_*` mirror is only updated when
    // recordResidencySnapshot() commits this batch — so a SIGTERM
    // landing mid-snapshot leaves the prior completed snapshot intact.
    pending_residency_pages[bucket]++;
    pending_residency_page_bytes[bucket]    += total_bytes;
    pending_residency_live_bytes[bucket]    += live_bytes;
    pending_residency_garbage_bytes[bucket] += garbage_bytes;
    pending_residency_free_bytes[bucket]    += free_bytes;

    if (is_large) {
        residency_pinned_pages++;
        residency_pinned_page_bytes    += total_bytes;
        residency_pinned_live_bytes    += live_bytes;
        residency_pinned_garbage_bytes += garbage_bytes;
        residency_pinned_free_bytes    += free_bytes;

        pending_residency_pinned_pages++;
        pending_residency_pinned_page_bytes    += total_bytes;
        pending_residency_pinned_live_bytes    += live_bytes;
        pending_residency_pinned_garbage_bytes += garbage_bytes;
        pending_residency_pinned_free_bytes    += free_bytes;
    }
}

void GCStats::beginResidencySnapshot() {
    // Clear ONLY the staging buffer. `latest_*` keeps the prior
    // completed snapshot until recordResidencySnapshot() commits this
    // new one — see crash-forensics rationale in GCStats.hpp.
    for (int i = 0; i < RESIDENCY_BUCKETS; i++) {
        pending_residency_pages[i]         = 0;
        pending_residency_page_bytes[i]    = 0;
        pending_residency_live_bytes[i]    = 0;
        pending_residency_garbage_bytes[i] = 0;
        pending_residency_free_bytes[i]    = 0;
    }
    pending_residency_pinned_pages         = 0;
    pending_residency_pinned_page_bytes    = 0;
    pending_residency_pinned_live_bytes    = 0;
    pending_residency_pinned_garbage_bytes = 0;
    pending_residency_pinned_free_bytes    = 0;
}

void GCStats::recordResidencySnapshot() {
    residency_snapshots++;
    // Commit the staging buffer: pending_* -> latest_*.
    for (int i = 0; i < RESIDENCY_BUCKETS; i++) {
        latest_residency_pages[i]         = pending_residency_pages[i];
        latest_residency_page_bytes[i]    = pending_residency_page_bytes[i];
        latest_residency_live_bytes[i]    = pending_residency_live_bytes[i];
        latest_residency_garbage_bytes[i] = pending_residency_garbage_bytes[i];
        latest_residency_free_bytes[i]    = pending_residency_free_bytes[i];
    }
    latest_residency_pinned_pages         = pending_residency_pinned_pages;
    latest_residency_pinned_page_bytes    = pending_residency_pinned_page_bytes;
    latest_residency_pinned_live_bytes    = pending_residency_pinned_live_bytes;
    latest_residency_pinned_garbage_bytes = pending_residency_pinned_garbage_bytes;
    latest_residency_pinned_free_bytes    = pending_residency_pinned_free_bytes;
    latest_residency_snapshots = 1;
}

void GCStats::recordFreeListClass(size_t size_class,
                                  uint64_t cell_count,
                                  uint64_t cell_bytes) {
    if (size_class >= FREELIST_CLASS_BUCKETS) return;
    freelist_cells_by_class[size_class] += cell_count;
    freelist_bytes_by_class[size_class] += cell_bytes;
    pending_freelist_cells_by_class[size_class] += cell_count;
    pending_freelist_bytes_by_class[size_class] += cell_bytes;
}

void GCStats::recordFreeListLargeBlocks(uint64_t block_count,
                                        uint64_t total_bytes) {
    freelist_large_block_count += block_count;
    freelist_large_block_bytes += total_bytes;
    pending_freelist_large_block_count += block_count;
    pending_freelist_large_block_bytes += total_bytes;
}

void GCStats::beginFreeListSnapshot() {
    // Staging buffer only — latest_* retains the prior completed snapshot.
    for (int i = 0; i < FREELIST_CLASS_BUCKETS; i++) {
        pending_freelist_cells_by_class[i] = 0;
        pending_freelist_bytes_by_class[i] = 0;
    }
    pending_freelist_large_block_count = 0;
    pending_freelist_large_block_bytes = 0;
}

void GCStats::recordFreeListSnapshot() {
    freelist_snapshots++;
    for (int i = 0; i < FREELIST_CLASS_BUCKETS; i++) {
        latest_freelist_cells_by_class[i] = pending_freelist_cells_by_class[i];
        latest_freelist_bytes_by_class[i] = pending_freelist_bytes_by_class[i];
    }
    latest_freelist_large_block_count = pending_freelist_large_block_count;
    latest_freelist_large_block_bytes = pending_freelist_large_block_bytes;
    latest_freelist_snapshots = 1;
}

// Records completion of a major GC cycle with timing.
// Time origin for the major-GC event log. Initialised at static-init of this
// translation unit, i.e. effectively process start: every `start_ns` in the log
// is relative to this, so the timeline is readable without external clocks.
static const std::chrono::steady_clock::time_point g_process_start =
    std::chrono::steady_clock::now();

uint64_t GCStats::processStartSteadyNs() {
    return static_cast<uint64_t>(
        std::chrono::duration_cast<std::chrono::nanoseconds>(
            g_process_start.time_since_epoch()).count());
}

uint64_t GCStats::nowSinceProcessStartNs() {
    return static_cast<uint64_t>(
        std::chrono::duration_cast<std::chrono::nanoseconds>(
            std::chrono::steady_clock::now() - g_process_start)
            .count());
}

void GCStats::beginMajorGCEvent(MajorReason reason,
                                uint64_t oldgen_before_bytes,
                                uint64_t committed_bytes) {
    pending_major_start_ns     = nowSinceProcessStartNs();
    pending_major_before_bytes = oldgen_before_bytes;
    pending_major_committed    = committed_bytes;
    pending_major_reason       = reason;
}

void GCStats::recordMajorGCEvent(uint64_t total_ns,
                                 uint64_t root_scan_ns,
                                 uint64_t root_push_ns,
                                 uint64_t mark_ns,
                                 uint64_t sweep_ns,
                                 uint64_t capacity_ns,
                                 uint64_t oldgen_after_bytes,
                                 uint64_t live_bytes_after,
                                 uint64_t garbage_bytes,
                                 uint64_t alldead_bytes_released,
                                 uint64_t shrink_bytes_released,
                                 uint64_t mark_units,
                                 uint64_t mark_stack_peak,
                                 uint64_t blocks_scanned,
                                 uint64_t minor_count_now,
                                 uint64_t promoted_now) {
    if (major_gc_events_used >= MAJOR_GC_EVENT_CAP) {
        major_gc_events_dropped++;
        return;
    }
    MajorGCEvent& e = major_gc_events[major_gc_events_used++];
    e.seq                    = major_gc_count;  // already bumped by recordMajorGCEnd
    e.start_ns               = pending_major_start_ns;
    e.total_ns               = total_ns;
    e.root_scan_ns           = root_scan_ns;
    e.root_push_ns           = root_push_ns;
    e.mark_ns                = mark_ns;
    e.sweep_ns               = sweep_ns;
    e.capacity_ns            = capacity_ns;
    e.oldgen_before_bytes    = pending_major_before_bytes;
    e.oldgen_after_bytes     = oldgen_after_bytes;
    e.committed_bytes        = pending_major_committed;
    e.live_bytes_after       = live_bytes_after;
    e.garbage_bytes          = garbage_bytes;
    e.alldead_bytes_released = alldead_bytes_released;
    e.shrink_bytes_released  = shrink_bytes_released;
    e.mark_units             = mark_units;
    e.mark_stack_peak        = mark_stack_peak;
    e.blocks_scanned         = blocks_scanned;
    e.minors_since_prev      = minor_count_now - last_major_minor_count;
    e.promoted_since_prev    = promoted_now    - last_major_promoted;
    e.reason                 = pending_major_reason;

    last_major_minor_count = minor_count_now;
    last_major_promoted    = promoted_now;
}

namespace {
const char* majorReasonName(GCStats::MajorReason r) {
    switch (r) {
        case GCStats::MajorReason::Occupancy:       return "occupancy";
        case GCStats::MajorReason::GlobalPressure:  return "global-pressure";
        case GCStats::MajorReason::GarbageFraction: return "garbage-frac";
        case GCStats::MajorReason::AllocFailure:    return "alloc-failure";
        case GCStats::MajorReason::Forced:          return "forced";
        case GCStats::MajorReason::LiveBudget:      return "live-budget";
        case GCStats::MajorReason::Headroom:        return "headroom";
        case GCStats::MajorReason::Explicit:        return "explicit";
        case GCStats::MajorReason::Unknown:         break;
    }
    return "unknown";
}
}  // namespace

void GCStats::printMajorGCEventLog() const {
    if (major_gc_events_used == 0) {
        std::cout << "\n  (no major GC events recorded)" << std::endl;
        return;
    }

    std::cout << "\nMajor GC Event Log (one row per collection):" << std::endl;
    std::cout
        << "     at(s)   total   mark  sweep  roots    reason"
        << "        before      after    garbage   recovered"
        << "   minors    promoted    markunits"
        << std::endl;

    const double MB = 1024.0 * 1024.0;
    for (size_t i = 0; i < major_gc_events_used; ++i) {
        const MajorGCEvent& e = major_gc_events[i];
        // Recovered is the mark-derived garbage the collection identified,
        // which is the honest "how much did this one find" figure — the
        // allocator-visible before/after understates it because the sweep is
        // lazy (see the MajorGCEvent comment).
        std::cout << "  " << std::fixed << std::setprecision(2)
                  << std::setw(8) << (e.start_ns / 1.0e9)
                  << std::setprecision(1)
                  << std::setw(7) << (e.total_ns / 1.0e6)
                  << std::setw(7) << (e.mark_ns / 1.0e6)
                  << std::setw(7) << (e.sweep_ns / 1.0e6)
                  << std::setw(7) << ((e.root_scan_ns + e.root_push_ns) / 1.0e6)
                  << "  " << std::setw(15) << std::left
                  << majorReasonName(e.reason) << std::right
                  << std::setprecision(1)
                  << std::setw(9) << (e.oldgen_before_bytes / MB)
                  << std::setw(11) << (e.oldgen_after_bytes / MB)
                  << std::setw(11) << (e.garbage_bytes / MB)
                  << std::setw(12) << ((e.alldead_bytes_released
                                        + e.shrink_bytes_released) / MB)
                  << std::setw(9) << e.minors_since_prev
                  << std::setw(12) << e.promoted_since_prev
                  << std::setw(13) << e.mark_units
                  << std::endl;
    }
    std::cout << "  (times ms; sizes MB; 'roots' = root scan + push; "
                 "'after' is post-sweep live; 'recovered' = all-dead + shrink\n"
                 "   released to the allocator this pause; 'markunits' = objects "
                 "popped from the mark stack)"
              << std::endl;
    if (major_gc_events_dropped > 0) {
        std::cout << "  NOTE: " << major_gc_events_dropped
                  << " further majors not logged (cap "
                  << MAJOR_GC_EVENT_CAP << ")" << std::endl;
    }
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
    direct_debt_bytes_total += other.direct_debt_bytes_total;
    minor_gc_debt_requests += other.minor_gc_debt_requests;
    large_body_recover_minors += other.large_body_recover_minors;
    large_body_recover_majors += other.large_body_recover_majors;
    objects_survived += other.objects_survived;
    objects_promoted += other.objects_promoted;
    bytes_freed += other.bytes_freed;

    // Combine nursery sizing stats. nursery_size_bytes is reduced by max so
    // the merged value reports the largest individual per-thread nursery
    // observed (rather than summing independent per-thread nurseries, which
    // would conflate fan-out with growth).
    nursery_grow_events += other.nursery_grow_events;
    if (other.nursery_size_bytes > nursery_size_bytes) {
        nursery_size_bytes = other.nursery_size_bytes;
    }

    // Capacity-check hoisting counter (HEAP_041): a plain sum.
    ensure_slow_calls += other.ensure_slow_calls;

    // Old-gen walls are allocator-global: every contributor carries the same
    // process-wide value, so merge by max (getCombinedStats then overwrites
    // both from the live allocator).
    if (other.oldgen_inuse_peak_bytes > oldgen_inuse_peak_bytes) {
        oldgen_inuse_peak_bytes = other.oldgen_inuse_peak_bytes;
    }
    if (other.oldgen_hiwater_bytes > oldgen_hiwater_bytes) {
        oldgen_hiwater_bytes = other.oldgen_hiwater_bytes;
    }
    // threaded-gc-03: allocator-global like the walls above.
    page_supply.mergeMax(other.page_supply);
    helper.mergeMax(other.helper);
    lp.combine(other.lp);
    pmin.combine(other.pmin);
    rg.combine(other.rg);
    im.combine(other.im);
    pm.combine(other.pm);
    cm.combine(other.cm);

    // Combine allocator-helper attribution.
    total_oldgen_alloc_in_mutator_ns  += other.total_oldgen_alloc_in_mutator_ns;
    total_post_sweep_shrink_ns        += other.total_post_sweep_shrink_ns;
    total_maybe_shrink_heavy_ns       += other.total_maybe_shrink_heavy_ns;
    total_maybe_shrink_light_ns       += other.total_maybe_shrink_light_ns;
    total_maybe_shrink_forced_ns      += other.total_maybe_shrink_forced_ns;
    total_nursery_alloc_in_mutator_ns += other.total_nursery_alloc_in_mutator_ns;
    total_lazy_sweep_bytes_in_mutator += other.total_lazy_sweep_bytes_in_mutator;
    total_panic_sweep_bytes           += other.total_panic_sweep_bytes;

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
    // Event log: append, then the printer's rows stay in per-thread order.
    // (Single-mutator compiles never hit this; kept correct for completeness.)
    for (size_t i = 0; i < other.major_gc_events_used; ++i) {
        if (major_gc_events_used >= MAJOR_GC_EVENT_CAP) {
            major_gc_events_dropped++;
            continue;
        }
        major_gc_events[major_gc_events_used++] = other.major_gc_events[i];
    }
    major_gc_events_dropped += other.major_gc_events_dropped;

    major_gc_occupancy_triggers += other.major_gc_occupancy_triggers;
    major_gc_alloc_failure_triggers += other.major_gc_alloc_failure_triggers;
    major_gc_garbage_triggers += other.major_gc_garbage_triggers;
    major_gc_global_pressure_triggers += other.major_gc_global_pressure_triggers;

    // Combine split-header large-body minor-reclaim stats.
    large_body_minor_sweep_runs        += other.large_body_minor_sweep_runs;
    large_body_minor_sweep_skips       += other.large_body_minor_sweep_skips;
    large_body_minor_freed_bytes       += other.large_body_minor_freed_bytes;
    large_body_deferred_to_major_bytes += other.large_body_deferred_to_major_bytes;

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
    nursery_alloc_size_16_24_count += other.nursery_alloc_size_16_24_count;
    oldgen_alloc_size_16_24_count  += other.oldgen_alloc_size_16_24_count;

    for (int i = 0; i < STRING_ALLOC_BUCKETS; i++) {
        string_alloc_size_histogram[i] += other.string_alloc_size_histogram[i];
    }

    utf8_widen_calls += other.utf8_widen_calls;
    utf8_widen_units += other.utf8_widen_units;
    for (int i = 0; i < UTF8_WIDEN_SITE_COUNT; i++) {
        utf8_widen_site_calls[i] += other.utf8_widen_site_calls[i];
        utf8_widen_site_units[i] += other.utf8_widen_site_units[i];
    }

    // Combine per-kind ThreadLocalHeap allocation counters, and the LH1
    // retention histograms alongside them.
    for (int i = 0; i < NUM_ALLOC_TAGS; i++) {
        tlh_alloc_count_by_tag[i] += other.tlh_alloc_count_by_tag[i];
        tlh_alloc_bytes_by_tag[i] += other.tlh_alloc_bytes_by_tag[i];
        promoted_count_by_tag[i]  += other.promoted_count_by_tag[i];
        promoted_bytes_by_tag[i]  += other.promoted_bytes_by_tag[i];
        survived_count_by_tag[i]  += other.survived_count_by_tag[i];
        survived_bytes_by_tag[i]  += other.survived_bytes_by_tag[i];
    }
    for (int i = 0; i < CUSTOM_ARITY_BUCKETS; i++) {
        custom_promoted_by_nfields[i]       += other.custom_promoted_by_nfields[i];
        custom_promoted_bytes_by_nfields[i] += other.custom_promoted_bytes_by_nfields[i];
        custom_survived_by_nfields[i]       += other.custom_survived_by_nfields[i];
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
    // Pending residency staging: not exposed by the printer, so combining
    // would leak partial in-progress snapshots into the merged view. Leave
    // pending_* on `this` untouched.

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
    // Pending free-list staging: not exposed by the printer; left untouched.
    // threaded-gc-00 phase totals and pause log.
    tg.merge(other.tg);
    bm.merge(other.bm);
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
    std::cout << "  Direct old-gen bytes:  " << std::setw(12) << std::fixed << std::setprecision(2)
              << (direct_debt_bytes_total / (1024.0 * 1024.0)) << " MB" << std::endl;
    std::cout << "  Debt minor requests:   " << std::setw(12) << minor_gc_debt_requests << std::endl;
    std::cout << "  Lg-body recover minor: " << std::setw(12) << large_body_recover_minors << std::endl;
    std::cout << "  Lg-body recover major: " << std::setw(12) << large_body_recover_majors << std::endl;

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

    double nursery_mb = nursery_size_bytes / (1024.0 * 1024.0);
    std::cout << "  Nursery grow events:   " << std::setw(12) << nursery_grow_events << std::endl;
    std::cout << "  Ensure slow calls:     " << std::setw(12) << ensure_slow_calls << std::endl;
    std::cout << "  Maximum nursery size:  " << std::setw(12) << std::fixed << std::setprecision(2)
              << nursery_mb << " MB" << std::endl;
    std::cout << std::endl;

    // ========== Minor GC Timing Stats ==========
    if (minor_gc_count > 0) {
        std::cout << "\nMinor GC Timing:" << std::endl;

        // total_minor_gc_time_ns is the WHOLE minor pause per cycle,
        // promotion allocation included. Promotions are not timed
        // individually any more (OldGenSpace::allocate skips the clock while
        // g_in_minor_gc), so nothing is subtracted from the pause. The
        // histogram/min/max/avg below all reflect the same whole-pause
        // accounting. It excludes the stack walk and the large-body sweep;
        // see "GC Pause Distribution (threaded-gc-00)" for whole pauses.
        std::cout << "  Total time:            " << std::setw(15) << formatTime(total_minor_gc_time_ns)
                  << "  (incl. promotion alloc)" << std::endl;

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
    std::cout << "  Global-pressure trig.: " << std::setw(12) << major_gc_global_pressure_triggers << std::endl;
    std::cout << "  Garbage-frac triggers: " << std::setw(12) << major_gc_garbage_triggers << std::endl;

    printMajorGCEventLog();

    // Old-gen address-space walls (HEAP_043). Two different quantities: the
    // in-use peak is what the GlobalPressure trigger compares against the
    // cap; the high-water commit bump is what the hard alloc-failure wall
    // trips on. Both are printed in MB against the live cap so an operator
    // can tell "this workload needs a bigger old-gen share" from "this
    // workload is nowhere near the cap".
    {
        const size_t cap = Allocator::instance().getOldGenMaxBytes();
        const double mb = 1024.0 * 1024.0;
        std::cout << "  Old-gen in-use peak:   " << std::setw(12)
                  << std::fixed << std::setprecision(2)
                  << (oldgen_inuse_peak_bytes / mb) << " MB";
        if (cap > 0) {
            std::cout << "  (" << std::setprecision(1)
                      << (100.0 * oldgen_inuse_peak_bytes / cap) << "% of cap)";
        }
        std::cout << std::endl;
        std::cout << "  Old-gen commit hiwtr:  " << std::setw(12)
                  << std::fixed << std::setprecision(2)
                  << (oldgen_hiwater_bytes / mb) << " MB";
        if (cap > 0) {
            std::cout << "  (cap " << std::setprecision(2) << (cap / mb) << " MB)";
        }
        std::cout << std::endl;
    }

    // Split-header large-body minor-reclaim stats. Each minor GC tries to
    // free Tag_LargeStringHeader / Tag_LargeByteHeader bodies whose
    // nursery header died this cycle by routing them straight back to
    // the per-class free lists / free_large_blocks_, bypassing the major
    // GC's per-cell sweep walk. The fast path is skipped if a major GC or
    // compaction is in flight; those bodies wait for a future minor that
    // fires while major is idle (or for major-GC's slow sweep to reach
    // them). Skip-rate and deferred bytes quantify how much of this
    // fast-path reclamation is being lost to in-flight major GCs.
    {
        const uint64_t total_attempts =
            large_body_minor_sweep_runs + large_body_minor_sweep_skips;
        const uint64_t total_lb_bytes =
            large_body_minor_freed_bytes + large_body_deferred_to_major_bytes;
        const double freed_mb =
            large_body_minor_freed_bytes / (1024.0 * 1024.0);
        const double deferred_mb =
            large_body_deferred_to_major_bytes / (1024.0 * 1024.0);
        const double skip_pct = total_attempts > 0
            ? (large_body_minor_sweep_skips * 100.0) / total_attempts
            : 0.0;
        const double deferred_pct = total_lb_bytes > 0
            ? (large_body_deferred_to_major_bytes * 100.0) / total_lb_bytes
            : 0.0;
        std::cout << "  Lg-body sweep runs:    " << std::setw(12)
                  << large_body_minor_sweep_runs << std::endl;
        std::cout << "  Lg-body sweep skips:   " << std::setw(12)
                  << large_body_minor_sweep_skips
                  << "  ("
                  << std::fixed << std::setprecision(1) << skip_pct
                  << "% of attempts; major/compact in flight)"
                  << std::endl;
        std::cout << "  Lg-body freed (minor): " << std::setw(12)
                  << std::fixed << std::setprecision(2)
                  << freed_mb << " MB" << std::endl;
        std::cout << "  Lg-body deferred:      " << std::setw(12)
                  << std::fixed << std::setprecision(2)
                  << deferred_mb << " MB"
                  << "  ("
                  << std::fixed << std::setprecision(1) << deferred_pct
                  << "% of attempts left to major GC)"
                  << std::endl;
    }

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

    // ========== Allocator Timings ==========
    //
    // Top-level mutually-exclusive buckets. With the wall-time stamp from
    // Allocator::getCombinedStats, these partition wall together with
    // "true mutator". Identity:
    //   wall = minor + major + oldgen_alloc_in_mutator
    //        + nursery_alloc_in_mutator + true_mutator
    if (total_minor_gc_time_ns > 0 ||
        total_major_gc_time_ns > 0 ||
        total_oldgen_alloc_in_mutator_ns > 0 ||
        total_nursery_alloc_in_mutator_ns > 0) {
        std::cout << "\nAllocator Timings:" << std::endl;
        std::cout << "  Minor GC (incl. promotion alloc):" << std::setw(13)
                  << formatTime(total_minor_gc_time_ns) << std::endl;
        std::cout << "  Major GC:                      " << std::setw(15)
                  << formatTime(total_major_gc_time_ns) << std::endl;
        std::cout << "  Old-gen alloc in mutator:      " << std::setw(15)
                  << formatTime(total_oldgen_alloc_in_mutator_ns) << std::endl;
        std::cout << "  Nursery alloc in mutator:      " << std::setw(15)
                  << formatTime(total_nursery_alloc_in_mutator_ns) << std::endl;

        const uint64_t bracket_sum_ns =
            total_minor_gc_time_ns + total_major_gc_time_ns
            + total_oldgen_alloc_in_mutator_ns
            + total_nursery_alloc_in_mutator_ns;
        std::cout << "  Total GC/Alloc time:           " << std::setw(15)
                  << formatTime(bracket_sum_ns) << std::endl;

        if (wall_time_ns > 0 && wall_time_ns >= bracket_sum_ns) {
            const uint64_t mutator_ns = wall_time_ns - bracket_sum_ns;
            const double mutator_pct = (100.0 * mutator_ns) / wall_time_ns;
            const double wall_s      = wall_time_ns / 1e9;
            std::cout << "  True mutator (wall - sum):     " << std::setw(15)
                      << formatTime(mutator_ns)
                      << "   (" << std::fixed << std::setprecision(1)
                      << mutator_pct << "% of "
                      << std::fixed << std::setprecision(2) << wall_s
                      << " s wall)" << std::endl;
        }
    }

    // ========== Allocator Nested Timings ==========
    //
    // Sub-counters of the buckets above. Reported only to show where time
    // inside a parent bucket was spent — DO NOT add to the totals.
    if (total_post_sweep_shrink_ns > 0 ||
        total_maybe_shrink_heavy_ns > 0 ||
        total_maybe_shrink_light_ns > 0 ||
        total_maybe_shrink_forced_ns > 0) {
        std::cout << "\nAllocator Nested Timings (Already included in "
                     "Allocator Timings):" << std::endl;
        std::cout << "  Post-sweep shrink (nested in Old-gen alloc in mutator):  "
                  << std::setw(15)
                  << formatTime(total_post_sweep_shrink_ns) << std::endl;
        std::cout << "  maybeShrink heavy (nested in Major GC):                  "
                  << std::setw(15)
                  << formatTime(total_maybe_shrink_heavy_ns) << std::endl;
        std::cout << "  maybeShrink light (nested in Post-sweep shrink):         "
                  << std::setw(15)
                  << formatTime(total_maybe_shrink_light_ns) << std::endl;
        if (total_maybe_shrink_forced_ns > 0) {
            std::cout << "  maybeShrink forced (explicit release, HEAP_076):         "
                      << std::setw(15)
                      << formatTime(total_maybe_shrink_forced_ns) << std::endl;
        }
    }

    // ========== Adaptive Lazy-Sweep Pacing ==========
    //
    // Bytes asked of the sweeper from the dynamic per-allocation budget
    // (`OldGenSpace::sweepOnDemandAllocate`) and from the panic path
    // (`OldGenSpace::panicSweepAndRetryAllocation`). Non-zero panic bytes
    // indicate the old gen reached its cap and the panic path drove sweep
    // to completion to avoid OOM.
    if (total_lazy_sweep_bytes_in_mutator > 0 ||
        total_panic_sweep_bytes > 0) {
        std::cout << "\nAdaptive Lazy-Sweep Bytes:" << std::endl;
        std::cout << "  Mutator slow-path:     " << std::setw(15)
                  << total_lazy_sweep_bytes_in_mutator
                  << "  bytes requested" << std::endl;
        std::cout << "  Panic path:            " << std::setw(15)
                  << total_panic_sweep_bytes
                  << "  bytes requested" << std::endl;
    }

    // ========== threaded-gc-00 blocks (additive; appended) ==========
#if ENABLE_GC_PHASE_TIMERS
    printThreadedGcBlocks();
#endif
    // threaded-gc-02 block (additive; printed only in bitmap mode).
    printBitmapAllocBlock();
    // threaded-gc-03 blocks (additive): page supply always, helpers in mode != 0.
    printPageSupplyBlock();
    printHelperBlock();
    printLargePtrBlock();   // threaded-gc-04b (only when non-zero)
    printParMinorBlock();   // threaded-gc-06 (only when non-zero)
    printRegionBlock();     // threaded-gc-07 (only when region mode ran)
    printIncrMarkBlock();   // threaded-gc-05a (only when non-zero)
    printParMarkBlock();    // threaded-gc-05b (only when non-zero)
    printConcMarkBlock();   // threaded-gc-05c (only when non-zero)

    // ========== Allocation Size Histograms ==========
    //
    // Bucket 1 ([16,32)) is split for display into [16,24) and [24,32) using
    // the parallel `*_16_24_count` sub-counter, which separates boxed
    // primitives (Int/Float/Char @ 24 B incl. header) from small constructors
    // (Tuple2, Cons, small custom types @ 24-32 B). All other buckets are
    // emitted unchanged on power-of-two boundaries.
    auto printAllocHistogram = [](const char* title,
                                  const uint64_t* hist,
                                  int num_buckets,
                                  uint64_t fine_16_24_count,
                                  bool split_bucket_1 = true) {
        // Clamp the sub-counter against the parent bucket so the upper half
        // can never go negative if instances were merged out of lock-step.
        // When split_bucket_1 is false the sub-counter is ignored entirely.
        uint64_t lower_16_24 = std::min<uint64_t>(fine_16_24_count, hist[1]);
        uint64_t upper_24_32 = hist[1] - lower_16_24;

        uint64_t total = 0;
        uint64_t max_count = 0;
        for (int i = 0; i < num_buckets; i++) {
            total += hist[i];
            if (i == 1 && split_bucket_1) {
                // The split halves drive bar scaling, not the parent bucket.
                max_count = std::max({max_count, lower_16_24, upper_24_32});
            } else {
                max_count = std::max(max_count, hist[i]);
            }
        }
        if (total == 0) return;

        std::cout << "\n" << title << ":" << std::endl;
        const int BAR_WIDTH = 40;

        auto printRow = [&](size_t lo, size_t hi, uint64_t count, bool overflow) {
            if (count == 0) return;
            if (!overflow) {
                std::cout << "  " << std::setw(8) << formatBytes(lo)
                          << " - " << std::setw(8) << formatBytes(hi) << ": ";
            } else {
                std::cout << "  >= " << std::setw(8) << formatBytes(lo)
                          << "        : ";
            }
            int bar_len = max_count > 0
                ? static_cast<int>((count * BAR_WIDTH) / max_count)
                : 0;
            for (int j = 0; j < bar_len; j++) std::cout << "█";
            double percentage = (count * 100.0) / total;
            std::cout << " " << count << " (" << std::fixed
                      << std::setprecision(1) << percentage << "%)" << std::endl;
        };

        for (int i = 0; i < num_buckets; i++) {
            // Bucket k covers [BASE << k, BASE << (k+1)); the last bucket
            // is the overflow bucket for sizes at or above BASE << (n-1).
            if (i == 1 && split_bucket_1) {
                printRow(16, 24, lower_16_24, /*overflow=*/false);
                printRow(24, 32, upper_24_32, /*overflow=*/false);
                continue;
            }
            size_t range_start = ALLOC_HISTOGRAM_BASE << i;
            if (i < num_buckets - 1) {
                size_t range_end = ALLOC_HISTOGRAM_BASE << (i + 1);
                printRow(range_start, range_end, hist[i], /*overflow=*/false);
            } else {
                printRow(range_start, 0, hist[i], /*overflow=*/true);
            }
        }
    };

    printAllocHistogram("Nursery Allocation Size Histogram",
                        nursery_alloc_size_histogram,
                        NURSERY_ALLOC_BUCKETS,
                        nursery_alloc_size_16_24_count);

    // ========== Per-Kind Mutator Allocation Histogram ==========
    //
    // Sourced from initHeaderForTag (every successful mutator allocation
    // through the typed ThreadLocalHeap path). Sorted by count descending
    // so the dominant kinds float to the top. We also report total bytes
    // and average size per kind, which is more useful than count alone for
    // variable-width tags (Custom, Record, Closure, String, Array).
    {
        struct Row { int tag; uint64_t count; uint64_t bytes; };
        Row rows[NUM_ALLOC_TAGS];
        int n_rows = 0;
        uint64_t total_count = 0;
        uint64_t max_count = 0;
        for (int i = 0; i < NUM_ALLOC_TAGS; i++) {
            uint64_t c = tlh_alloc_count_by_tag[i];
            if (c == 0) continue;
            rows[n_rows++] = {i, c, tlh_alloc_bytes_by_tag[i]};
            total_count += c;
            max_count = std::max(max_count, c);
        }
        if (total_count > 0) {
            std::sort(rows, rows + n_rows, [](const Row& a, const Row& b) {
                return a.count > b.count;
            });

            std::cout << "\nMutator Allocations by Object Kind:" << std::endl;
            const int BAR_WIDTH = 40;
            for (int r = 0; r < n_rows; r++) {
                const Row& row = rows[r];
                double avg = static_cast<double>(row.bytes)
                             / static_cast<double>(row.count);
                double pct = (row.count * 100.0) / total_count;
                int bar_len = max_count > 0
                    ? static_cast<int>((row.count * BAR_WIDTH) / max_count)
                    : 0;

                std::cout << "  " << std::setw(18) << std::left
                          << tagName(row.tag) << std::right << ": ";
                for (int j = 0; j < bar_len; j++) std::cout << "█";
                std::cout << " " << row.count << " ("
                          << std::fixed << std::setprecision(1) << pct << "%, "
                          << formatBytes(row.bytes) << " total, "
                          << std::setprecision(1) << avg << " B avg)"
                          << std::endl;
            }
        }
    }

    // ========== Per-Kind Retention Histogram (LH1) ==========
    //
    // plans/live-heap-composition-census.md LH1. The retention analogue of
    // the allocation histogram above, and the number that should rank
    // optimization work: a copying nursery charges for SURVIVORS, not for
    // allocation volume.
    //
    // Counted inside the collector, so unlike the allocation figures these
    // are exact in the standard binary (the HEAP_034 inline-allocation
    // fast path bypasses initHeaderForTag, never the evacuator). The only
    // inline-alloc-sensitive column is surv%, whose DENOMINATOR is the
    // mutator counter — it is flagged rather than silently wrong.
    {
        struct Row {
            int tag;
            uint64_t prom_c, prom_b, surv_c, surv_b, alloc_c;
        };
        Row rows[NUM_ALLOC_TAGS];
        int n_rows = 0;
        uint64_t tot_prom = 0, tot_surv = 0, tot_prom_b = 0;
        uint64_t max_prom = 0;
        for (int i = 0; i < NUM_ALLOC_TAGS; i++) {
            uint64_t p = promoted_count_by_tag[i];
            uint64_t s = survived_count_by_tag[i];
            if (p == 0 && s == 0) continue;
            rows[n_rows++] = {i, p, promoted_bytes_by_tag[i],
                              s, survived_bytes_by_tag[i],
                              tlh_alloc_count_by_tag[i]};
            tot_prom += p;
            tot_surv += s;
            tot_prom_b += promoted_bytes_by_tag[i];
            max_prom = std::max(max_prom, p);
        }
        if (tot_prom > 0 || tot_surv > 0) {
            std::sort(rows, rows + n_rows, [](const Row& a, const Row& b) {
                return a.prom_c > b.prom_c;
            });

            std::cout << "\nRetention by Object Kind"
                      << " (promoted = survived a minor GC into old gen):"
                      << std::endl;
            std::cout << "  totals: promoted " << tot_prom << " ("
                      << formatBytes(tot_prom_b) << "), copied-in-nursery "
                      << tot_surv << std::endl;
            std::cout << "  surv% = promoted/allocated; only meaningful "
                         "under ECO_INLINE_ALLOC=0 (see LH1 note)"
                      << std::endl;

            const int BAR_WIDTH = 40;
            for (int r = 0; r < n_rows; r++) {
                const Row& row = rows[r];
                double pct = (row.prom_c * 100.0) / (tot_prom ? tot_prom : 1);
                double avg = row.prom_c
                    ? static_cast<double>(row.prom_b) / row.prom_c : 0.0;
                int bar_len = max_prom > 0
                    ? static_cast<int>((row.prom_c * BAR_WIDTH) / max_prom)
                    : 0;

                std::cout << "  " << std::setw(18) << std::left
                          << tagName(row.tag) << std::right << ": ";
                for (int j = 0; j < bar_len; j++) std::cout << "█";
                std::cout << " " << row.prom_c << " ("
                          << std::fixed << std::setprecision(1) << pct
                          << "% of promo, " << formatBytes(row.prom_b)
                          << ", " << std::setprecision(1) << avg << " B avg"
                          << ", copied " << row.surv_c;
                if (row.alloc_c > 0) {
                    double sr = (row.prom_c * 100.0) / row.alloc_c;
                    std::cout << ", surv " << std::setprecision(2) << sr << "%";
                    if (row.prom_c > row.alloc_c)
                        std::cout << "!";  // inline-alloc-blind denominator
                } else {
                    std::cout << ", surv n/a";
                }
                std::cout << ")" << std::endl;
            }
        }
    }

    // ========== Custom Arity Breakdown (W1) ==========
    //
    // plans/sum-type-wrapper-unboxing.md W1. Splits the promoted Tag_Custom
    // pool by field count. nfields==1 is an exact upper bound on the
    // population that plan can address (single-ctor single-field unions are
    // already Can.Unbox and never allocate a Custom at all).
    {
        uint64_t tot = 0, tot_b = 0;
        for (int i = 0; i < CUSTOM_ARITY_BUCKETS; i++) {
            tot += custom_promoted_by_nfields[i];
            tot_b += custom_promoted_bytes_by_nfields[i];
        }
        if (tot > 0) {
            std::cout << "\nPromoted Custom by Field Count (W1):" << std::endl;
            uint64_t mx = 0;
            for (int i = 0; i < CUSTOM_ARITY_BUCKETS; i++)
                mx = std::max(mx, custom_promoted_by_nfields[i]);
            const int BAR_WIDTH = 40;
            for (int i = 0; i < CUSTOM_ARITY_BUCKETS; i++) {
                uint64_t c = custom_promoted_by_nfields[i];
                if (c == 0) continue;
                double pct = (c * 100.0) / tot;
                int bar_len = mx > 0
                    ? static_cast<int>((c * BAR_WIDTH) / mx) : 0;
                std::cout << "  " << std::setw(2) << i
                          << (i == CUSTOM_ARITY_BUCKETS - 1 ? "+" : " ")
                          << " field" << (i == 1 ? " " : "s")
                          << std::setw(12) << std::right << ": ";
                for (int j = 0; j < bar_len; j++) std::cout << "█";
                std::cout << " " << c << " ("
                          << std::fixed << std::setprecision(1) << pct
                          << "% of promoted Custom, "
                          << formatBytes(custom_promoted_bytes_by_nfields[i])
                          << ", copied " << custom_survived_by_nfields[i]
                          << ")" << std::endl;
            }
            std::cout << "  total promoted Custom: " << tot << " ("
                      << formatBytes(tot_b) << ")" << std::endl;
        }
    }

    printAllocHistogram("Old-Gen Allocation Size Histogram",
                        oldgen_alloc_size_histogram,
                        OLDGEN_ALLOC_BUCKETS,
                        oldgen_alloc_size_16_24_count);

    // String-specific histogram: counts every fresh-leaf allocation that
    // flowed through HeapHelpers::allocString. Bucket 1 is NOT split — the
    // boxed-primitive vs small-constructor distinction it captures for the
    // nursery/oldgen views doesn't apply to Strings.
    printAllocHistogram("String Allocation Size Histogram",
                        string_alloc_size_histogram,
                        STRING_ALLOC_BUCKETS,
                        /*fine_16_24_count=*/0,
                        /*split_bucket_1=*/false);

    // UTF-8 -> UTF-16 widen events (see plans/utf8-string-pipeline-wiring.md).
    // Near zero on a UTF-8-clean workload; a large residual means a String op
    // is still decaying UTF-8 to UTF-16 on the hot path.
    std::cout << "\nUTF-8 -> UTF-16 widen events:" << std::endl;
    std::cout << "  Widen calls:           " << std::setw(15) << utf8_widen_calls << std::endl;
    std::cout << "  Widened code units:    " << std::setw(15) << utf8_widen_units << std::endl;
    {
        // Per-site attribution. TRIM..B64HEX partition utf8_widen_calls; the
        // two [blind] rows are additional widens outside that counter.
        static const char* kWidenSiteNames[UTF8_WIDEN_SITE_COUNT] = {
            "trim/trimLeft/trimRight",
            "toList",
            "indexes (needle+haystack)",
            "split (mixed encodings)",
            "append (mixed encodings)",
            "ensureFlat/flattenToLeaf",
            "fromBase64/fromHex",
            "[blind] rope-child widen",
            "[blind] segment-chunk widen",
        };
        uint64_t attributed = 0;
        for (int i = 0; i < UTF8_WIDEN_SITE_COUNT; i++) {
            if (i < UTF8_WIDEN_ROPE_CHILD) attributed += utf8_widen_site_calls[i];
            if (utf8_widen_site_calls[i] == 0) continue;
            std::cout << "    " << std::left << std::setw(28) << kWidenSiteNames[i]
                      << std::right << std::setw(12) << utf8_widen_site_calls[i]
                      << " calls " << std::setw(14) << utf8_widen_site_units[i]
                      << " units" << std::endl;
        }
        if (utf8_widen_calls > attributed) {
            std::cout << "    " << std::left << std::setw(28) << "(unattributed)"
                      << std::right << std::setw(12) << (utf8_widen_calls - attributed)
                      << " calls" << std::endl;
        }
    }
    std::cout << std::endl;

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

    // ========== CAF Permanent Space (default-on; ECO_CAF_PERMANENT=0) ====
    {
        const PermanentSpace::Stats &ps = PermanentSpace::instance().stats;
        const uint64_t promoted = ps.values_promoted.load();
        const uint64_t constant = ps.values_constant.load();
        const uint64_t declined = ps.values_declined.load();
        const uint64_t interned = ps.interned_objects.load();
        if (promoted + constant + declined + interned > 0) {
            std::cout << "\n[caf-permanent] promoted=" << promoted
                      << " constant=" << constant
                      << " declined=" << declined
                      << " objects=" << ps.objects_copied.load()
                      << " KB=" << (ps.bytes_copied.load() / 1024)
                      << " abandonedKB=" << (ps.bytes_abandoned.load() / 1024)
                      << " slotsRooted=" << ps.slots_rooted.load()
                      << " interned=" << interned
                      << " internKB=" << (ps.interned_bytes.load() / 1024)
                      << std::endl;
        }
        // Root-set population at print time (validates the no-pre-rooting
        // work: jit == declined slots only, longLived == transients +
        // old-gen intern fallbacks). Guarded: atexit may run after
        // cleanupThread or on a foreign thread, where the TL heap is gone.
        if (Allocator::instance().getCurrentThreadHeap() != nullptr) {
            RootSet &rs = Allocator::instance().getRootSet();
            std::cout << "[gc-roots] longLived=" << rs.getRoots().size()
                      << " jit=" << rs.getJitRoots().size()
                      << " stackRanges=" << rs.getStackRootRanges().size()
                      << std::endl;
        }
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
    direct_debt_bytes_total = 0;
    minor_gc_debt_requests = 0;
    large_body_recover_minors = 0;
    large_body_recover_majors = 0;
    objects_survived = 0;
    objects_promoted = 0;
    bytes_freed = 0;
    nursery_grow_events = 0;
    nursery_size_bytes = 0;
    ensure_slow_calls = 0;
    oldgen_inuse_peak_bytes = 0;
    oldgen_hiwater_bytes    = 0;
    page_supply = PageSupplyStats{};
    helper = HelperStatsSnapshot{};
    lp = LargePtrStats{};
    pmin = ParMinorStats{};
    rg = RegionTenureStats{};
    im = IncrMarkStats{};
    pm = ParMarkStats{};
    cm = ConcMarkStats{};
    total_oldgen_alloc_in_mutator_ns  = 0;
    total_post_sweep_shrink_ns        = 0;
    total_maybe_shrink_heavy_ns       = 0;
    total_maybe_shrink_light_ns       = 0;
    total_maybe_shrink_forced_ns      = 0;
    total_nursery_alloc_in_mutator_ns = 0;
    total_lazy_sweep_bytes_in_mutator = 0;
    total_panic_sweep_bytes           = 0;
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
    major_gc_events_used = 0;
    major_gc_events_dropped = 0;
    pending_major_start_ns = 0;
    pending_major_before_bytes = 0;
    pending_major_committed = 0;
    pending_major_reason = MajorReason::Unknown;
    last_major_minor_count = 0;
    last_major_promoted = 0;
    major_gc_occupancy_triggers = 0;
    major_gc_alloc_failure_triggers = 0;
    major_gc_garbage_triggers = 0;
    major_gc_global_pressure_triggers = 0;
    large_body_minor_sweep_runs        = 0;
    large_body_minor_sweep_skips       = 0;
    large_body_minor_freed_bytes       = 0;
    large_body_deferred_to_major_bytes = 0;
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
    nursery_alloc_size_16_24_count = 0;
    oldgen_alloc_size_16_24_count  = 0;

    for (int i = 0; i < STRING_ALLOC_BUCKETS; i++) {
        string_alloc_size_histogram[i] = 0;
    }

    utf8_widen_calls = 0;
    utf8_widen_units = 0;
    for (int i = 0; i < UTF8_WIDEN_SITE_COUNT; i++) {
        utf8_widen_site_calls[i] = 0;
        utf8_widen_site_units[i] = 0;
    }

    for (int i = 0; i < NUM_ALLOC_TAGS; i++) {
        tlh_alloc_count_by_tag[i] = 0;
        tlh_alloc_bytes_by_tag[i] = 0;
        promoted_count_by_tag[i]  = 0;
        promoted_bytes_by_tag[i]  = 0;
        survived_count_by_tag[i]  = 0;
        survived_bytes_by_tag[i]  = 0;
    }
    for (int i = 0; i < CUSTOM_ARITY_BUCKETS; i++) {
        custom_promoted_by_nfields[i]       = 0;
        custom_promoted_bytes_by_nfields[i] = 0;
        custom_survived_by_nfields[i]       = 0;
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
        pending_residency_pages[i]         = 0;
        pending_residency_page_bytes[i]    = 0;
        pending_residency_live_bytes[i]    = 0;
        pending_residency_garbage_bytes[i] = 0;
        pending_residency_free_bytes[i]    = 0;
    }
    latest_residency_pinned_pages         = 0;
    latest_residency_pinned_page_bytes    = 0;
    latest_residency_pinned_live_bytes    = 0;
    latest_residency_pinned_garbage_bytes = 0;
    latest_residency_pinned_free_bytes    = 0;
    latest_residency_snapshots            = 0;
    pending_residency_pinned_pages         = 0;
    pending_residency_pinned_page_bytes    = 0;
    pending_residency_pinned_live_bytes    = 0;
    pending_residency_pinned_garbage_bytes = 0;
    pending_residency_pinned_free_bytes    = 0;

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
        pending_freelist_cells_by_class[i] = 0;
        pending_freelist_bytes_by_class[i] = 0;
    }
    latest_freelist_large_block_count = 0;
    latest_freelist_large_block_bytes = 0;
    latest_freelist_snapshots         = 0;
    pending_freelist_large_block_count = 0;
    pending_freelist_large_block_bytes = 0;

    // threaded-gc-00 phase totals and pause log.
    tg = GCPhaseTotals{};
    bm = BitmapAllocStats{};
}


// ============================================================================
// threaded-gc-00: phase totals, pause statistics, banner blocks, event log
// ============================================================================

uint64_t gcClockOverheadNs() noexcept {
    // Minimum back-to-back difference of two process-clock reads: the part of
    // a sampled bracket that is clock, not work. Calibrated once.
    static const uint64_t ovh = [] {
        uint64_t best = UINT64_MAX;
        for (int i = 0; i < 2000; ++i) {
            const uint64_t a = GCStats::nowSinceProcessStartNs();
            const uint64_t b = GCStats::nowSinceProcessStartNs();
            if (b - a < best) best = b - a;
        }
        return best == UINT64_MAX ? 0 : best;
    }();
    return ovh;
}

int GCPhaseTotals::scannerIndex(const char* name) {
    if (!name) name = "unnamed";
    for (int i = 0; i < ext_count; ++i) {
        if (ext_name[i] == name || std::string(ext_name[i]) == name) return i;
    }
    if (ext_count >= GC_EXT_SCANNER_CAP) return GC_EXT_SCANNER_CAP - 1;
    ext_name[ext_count] = name;
    return ext_count++;
}

void GCPhaseTotals::addMinor(const MinorGCRecord& r, const char* const* names,
                             size_t n_names) {
    minor_records++;
    stack_walk_ns += r.stack_walk_ns;
    stack_walk_ns_max = std::max(stack_walk_ns_max, r.stack_walk_ns);
    frames_walked += r.frames_walked;
    frames_walked_max = std::max(frames_walked_max, r.frames_walked);
    frames_matched += r.frames_matched;
    stack_slots += r.stack_slots;
    stack_slots_max = std::max(stack_slots_max, r.stack_slots);
    roots_longlived_jit_ns += r.roots_longlived_jit_ns;
    roots_stackmap_ns += r.roots_stackmap_ns;
    roots_ranges_ns += r.roots_ranges_ns;
    roots_external_ns += r.roots_external_ns;
    drain_tospace_ns += r.drain_tospace_ns;
    drain_promoted_ns += r.drain_promoted_ns;
    drain_rounds += r.drain_rounds;
    drain_rounds_max = std::max(drain_rounds_max, r.drain_rounds);
    tail_ns += r.tail_ns;
    nursery_pause_ns += r.nursery_pause_ns;
    large_body_sweep_ns += r.large_body_sweep_ns;
    lazy_sweep_calls += r.lazy_sweep_calls;
    lazy_sweep_bytes += r.lazy_sweep_bytes;
    lazy_sweep_est_ns += r.lazy_sweep_est_ns;
    promo_alloc_calls += r.promo_alloc_calls;
    promo_alloc_est_ns += r.promo_alloc_est_ns;
    survived += r.survived;
    promoted += r.promoted;
    survived_bytes += r.survived_bytes;
    promoted_bytes += r.promoted_bytes;
    minflt += r.minflt;
    majflt += r.majflt;
    minor_pause_ns += r.pause_ns;
    for (int i = 0; i < r.ext_count; ++i) {
        const char* nm = (static_cast<size_t>(i) < n_names && names) ? names[i] : "unnamed";
        int j = scannerIndex(nm);
        ext_ns[j] += r.ext_ns[i];
        ext_slots[j] += r.ext_slots[i];
        ext_slots_max[j] = std::max(ext_slots_max[j], r.ext_slots[i]);
    }
}

int GCPhaseTotals::pauseBucket(uint64_t dur_ns) {
    const uint64_t us = dur_ns / 1000;
    if (us < 2) return 0;
    int b = static_cast<int>(std::bit_width(us)) - 1;   // floor(log2(us))
    return std::min(b, PAUSE_LOG2_BUCKETS - 1);
}

void GCPhaseTotals::addPause(uint64_t start_ns, uint64_t dur_ns, uint8_t kind) {
    pause_count++;
    pause_total_ns += dur_ns;
    pause_max_ns = std::max(pause_max_ns, dur_ns);
    if (kind < 6) pause_count_by_kind[kind]++;
    pause_log2_hist[pauseBucket(dur_ns)]++;
    if (pause_events.size() >= PAUSE_EVENT_CAP) {
        pause_events_dropped++;
        return;
    }
    if (pause_events.capacity() == 0) pause_events.reserve(4096);
    pause_events.push_back(PauseEvent{start_ns, dur_ns, kind});
}

void GCPhaseTotals::addStall(uint64_t start_ns, uint64_t dur_ns) {
    if (stall_events.size() >= PAUSE_EVENT_CAP) {
        stall_events_dropped++;
        return;
    }
    stall_events.push_back(PauseEvent{start_ns, dur_ns, 3});
}

void GCPhaseTotals::merge(const GCPhaseTotals& o) {
    minor_records += o.minor_records;
    stack_walk_ns += o.stack_walk_ns;
    stack_walk_ns_max = std::max(stack_walk_ns_max, o.stack_walk_ns_max);
    frames_walked += o.frames_walked;
    frames_walked_max = std::max(frames_walked_max, o.frames_walked_max);
    frames_matched += o.frames_matched;
    stack_slots += o.stack_slots;
    stack_slots_max = std::max(stack_slots_max, o.stack_slots_max);
    roots_longlived_jit_ns += o.roots_longlived_jit_ns;
    roots_stackmap_ns += o.roots_stackmap_ns;
    roots_ranges_ns += o.roots_ranges_ns;
    roots_external_ns += o.roots_external_ns;
    drain_tospace_ns += o.drain_tospace_ns;
    drain_promoted_ns += o.drain_promoted_ns;
    drain_rounds += o.drain_rounds;
    drain_rounds_max = std::max(drain_rounds_max, o.drain_rounds_max);
    tail_ns += o.tail_ns;
    nursery_pause_ns += o.nursery_pause_ns;
    large_body_sweep_ns += o.large_body_sweep_ns;
    lazy_sweep_calls += o.lazy_sweep_calls;
    lazy_sweep_bytes += o.lazy_sweep_bytes;
    lazy_sweep_est_ns += o.lazy_sweep_est_ns;
    promo_alloc_calls += o.promo_alloc_calls;
    promo_alloc_est_ns += o.promo_alloc_est_ns;
    survived += o.survived;
    promoted += o.promoted;
    survived_bytes += o.survived_bytes;
    promoted_bytes += o.promoted_bytes;
    minflt += o.minflt;
    majflt += o.majflt;
    minor_pause_ns += o.minor_pause_ns;
    for (int i = 0; i < o.ext_count; ++i) {
        int j = scannerIndex(o.ext_name[i]);
        ext_ns[j] += o.ext_ns[i];
        ext_slots[j] += o.ext_slots[i];
        ext_slots_max[j] = std::max(ext_slots_max[j], o.ext_slots_max[i]);
    }
    for (const PauseEvent& e : o.pause_events) {
        if (pause_events.size() >= PAUSE_EVENT_CAP) { pause_events_dropped++; continue; }
        pause_events.push_back(e);
    }
    pause_events_dropped += o.pause_events_dropped;
    pause_count += o.pause_count;
    pause_total_ns += o.pause_total_ns;
    pause_max_ns = std::max(pause_max_ns, o.pause_max_ns);
    for (int k = 0; k < 6; ++k) pause_count_by_kind[k] += o.pause_count_by_kind[k];
    for (const PauseEvent& e : o.stall_events) {
        if (stall_events.size() >= PAUSE_EVENT_CAP) { stall_events_dropped++; continue; }
        stall_events.push_back(e);
    }
    stall_events_dropped += o.stall_events_dropped;
    for (int b = 0; b < PAUSE_LOG2_BUCKETS; ++b) pause_log2_hist[b] += o.pause_log2_hist[b];
}

uint64_t GCPhaseTotals::percentile(const std::vector<uint64_t>& sorted, double q) {
    if (sorted.empty()) return 0;
    const double n = static_cast<double>(sorted.size());
    size_t rank = static_cast<size_t>(std::ceil(q * n));   // nearest rank, 1-based
    if (rank < 1) rank = 1;
    if (rank > sorted.size()) rank = sorted.size();
    return sorted[rank - 1];
}

double GCPhaseTotals::mmu(const std::vector<PauseEvent>& sorted_in, uint64_t wall_ns,
                          uint64_t w_ns) {
    if (w_ns == 0 || w_ns > wall_ns) return 1.0;
    // Union overlapping intervals (pauses from several threads may overlap).
    std::vector<std::pair<uint64_t, uint64_t>> iv;   // [start, end)
    iv.reserve(sorted_in.size());
    for (const PauseEvent& e : sorted_in) {
        uint64_t s = e.start_ns, t = e.start_ns + e.dur_ns;
        if (!iv.empty() && s <= iv.back().second) {
            iv.back().second = std::max(iv.back().second, t);
        } else {
            iv.emplace_back(s, t);
        }
    }
    if (iv.empty()) return 1.0;
    std::vector<uint64_t> prefix(iv.size() + 1, 0);
    for (size_t i = 0; i < iv.size(); ++i)
        prefix[i + 1] = prefix[i] + (iv[i].second - iv[i].first);

    auto gcIn = [&](uint64_t a, uint64_t b) -> uint64_t {
        // First interval with end > a.
        size_t i0 = static_cast<size_t>(
            std::upper_bound(iv.begin(), iv.end(), a,
                [](uint64_t v, const std::pair<uint64_t, uint64_t>& x) { return v < x.second; })
            - iv.begin());
        // First interval with start >= b.
        size_t i1 = static_cast<size_t>(
            std::lower_bound(iv.begin(), iv.end(), b,
                [](const std::pair<uint64_t, uint64_t>& x, uint64_t v) { return x.first < v; })
            - iv.begin());
        if (i0 >= i1) return 0;
        uint64_t sum = prefix[i1] - prefix[i0];
        if (iv[i0].first < a) sum -= (a - iv[i0].first);
        if (iv[i1 - 1].second > b) sum -= (iv[i1 - 1].second - b);
        return sum;
    };

    const uint64_t t_max = wall_ns - w_ns;
    double worst = 1.0;
    auto consider = [&](int64_t t) {
        uint64_t tt = t < 0 ? 0 : static_cast<uint64_t>(t);
        if (tt > t_max) tt = t_max;
        uint64_t g = gcIn(tt, tt + w_ns);
        if (g > w_ns) g = w_ns;
        double u = static_cast<double>(w_ns - g) / static_cast<double>(w_ns);
        worst = std::min(worst, u);
    };
    for (const auto& x : iv) {
        consider(static_cast<int64_t>(x.first));
        consider(static_cast<int64_t>(x.second) - static_cast<int64_t>(w_ns));
    }
    return worst;
}

namespace {

std::string fmtMs(uint64_t ns) {
    char buf[64];
    std::snprintf(buf, sizeof buf, "%.3f ms", ns / 1.0e6);
    return buf;
}

std::string fmtS(uint64_t ns) {
    char buf[64];
    std::snprintf(buf, sizeof buf, "%.3f s", ns / 1.0e9);
    return buf;
}

void printPauseLine(const char* label, std::vector<uint64_t> d) {
    std::sort(d.begin(), d.end());
    if (d.empty()) {
        std::cout << "  " << label << ": none" << std::endl;
        return;
    }
    uint64_t total = 0;
    for (uint64_t v : d) total += v;
    char buf[512];
    std::snprintf(buf, sizeof buf,
        "  %-26s n=%-8zu total=%-12s p50=%-12s p90=%-12s p99=%-12s p99.9=%-12s max=%s",
        label, d.size(), fmtS(total).c_str(),
        fmtMs(GCPhaseTotals::percentile(d, 0.50)).c_str(),
        fmtMs(GCPhaseTotals::percentile(d, 0.90)).c_str(),
        fmtMs(GCPhaseTotals::percentile(d, 0.99)).c_str(),
        fmtMs(GCPhaseTotals::percentile(d, 0.999)).c_str(),
        fmtMs(d.back()).c_str());
    std::cout << buf << std::endl;
}

}  // namespace

void GCStats::printThreadedGcBlocks() const {
    const GCPhaseTotals& t = tg;

    // ---------------- Block 1: pause distribution ----------------
    if (t.pause_count > 0) {
        std::cout << "\nGC Pause Distribution (threaded-gc-00):" << std::endl;
        std::cout << "  (pause = one contiguous mutator stop; includes the stack walk and "
                     "the large-body sweep,\n   which \"Minor GC Timing\" excludes; a minor "
                     "that triggers a major is ONE pause)" << std::endl;
        std::vector<PauseEvent> ev = t.pause_events;
        std::sort(ev.begin(), ev.end(),
                  [](const PauseEvent& a, const PauseEvent& b) { return a.start_ns < b.start_ns; });
        std::vector<uint64_t> all, minor_only, with_major, k_t0, k_slice, k_handoff;
        for (const PauseEvent& e : ev) {
            all.push_back(e.dur_ns);
            if (e.kind == 0) minor_only.push_back(e.dur_ns);
            else if (e.kind == 3) k_t0.push_back(e.dur_ns);
            else if (e.kind == 4) k_slice.push_back(e.dur_ns);
            else if (e.kind == 5) k_handoff.push_back(e.dur_ns);
            else with_major.push_back(e.dur_ns);
        }
        char buf[256];
        std::snprintf(buf, sizeof buf,
            "  pauses: %llu (minor-only %llu, minor+major %llu, major-only %llu, "
            "minor+t0 %llu, minor+slice %llu, minor+handoff %llu)",
            (unsigned long long)t.pause_count,
            (unsigned long long)t.pause_count_by_kind[0],
            (unsigned long long)t.pause_count_by_kind[1],
            (unsigned long long)t.pause_count_by_kind[2],
            (unsigned long long)t.pause_count_by_kind[3],
            (unsigned long long)t.pause_count_by_kind[4],
            (unsigned long long)t.pause_count_by_kind[5]);
        std::cout << buf << std::endl;
        printPauseLine("all pauses", all);
        printPauseLine("minor-only pauses", minor_only);
        printPauseLine("pauses containing a major", with_major);
        // threaded-gc-05a: the incremental cycle's pause kinds.
        if (!k_t0.empty()) printPauseLine("minor + cycle t0 snapshot", k_t0);
        if (!k_slice.empty()) printPauseLine("minor + mark slice", k_slice);
        if (!k_handoff.empty()) printPauseLine("minor + cycle handoff", k_handoff);
        if (t.pause_events_dropped > 0) {
            std::cout << "  WARNING: " << t.pause_events_dropped
                      << " pauses beyond the event cap; percentiles/MMU cover the first "
                      << GCPhaseTotals::PAUSE_EVENT_CAP << " only" << std::endl;
        }

        std::cout << "  Pause log2 histogram:" << std::endl;
        uint64_t hmax = 0;
        for (int b = 0; b < GCPhaseTotals::PAUSE_LOG2_BUCKETS; ++b)
            hmax = std::max(hmax, t.pause_log2_hist[b]);
        for (int b = 0; b < GCPhaseTotals::PAUSE_LOG2_BUCKETS; ++b) {
            if (t.pause_log2_hist[b] == 0) continue;
            const uint64_t lo_us = b == 0 ? 0 : (uint64_t{1} << b);
            const uint64_t hi_us = uint64_t{1} << (b + 1);
            std::snprintf(buf, sizeof buf, "    [%10.3f ms, %10.3f ms): ",
                          lo_us / 1000.0, hi_us / 1000.0);
            std::cout << buf;
            int bar = hmax ? static_cast<int>((t.pause_log2_hist[b] * 40) / hmax) : 0;
            for (int j = 0; j < bar; ++j) std::cout << "█";
            std::cout << " " << t.pause_log2_hist[b] << std::endl;
        }

        if (wall_time_ns == 0) {
            std::cout << "  MMU: skipped (wall time not stamped)" << std::endl;
        } else {
            static const uint64_t kWindowsMs[] = {1, 2, 5, 10, 20, 50, 100, 200, 500,
                                                  1000, 2000, 5000, 10000};
            std::cout << "  Minimum mutator utilisation (MMU):" << std::endl;
            for (uint64_t w_ms : kWindowsMs) {
                const uint64_t w_ns = w_ms * 1000000ull;
                if (w_ns > wall_time_ns) break;
                double u = GCPhaseTotals::mmu(ev, wall_time_ns, w_ns);
                std::snprintf(buf, sizeof buf, "    MMU %6llu ms: %6.2f%%",
                              (unsigned long long)w_ms, 100.0 * u);
                std::cout << buf << std::endl;
            }
            // threaded-gc-03: the same windows over pauses + outside-pause
            // helper stalls (printed only when a stall happened).
            if (!t.stall_events.empty()) {
                std::vector<PauseEvent> both = ev;
                both.insert(both.end(), t.stall_events.begin(), t.stall_events.end());
                std::sort(both.begin(), both.end(),
                          [](const PauseEvent& a, const PauseEvent& b) {
                              return a.start_ns < b.start_ns; });
                std::cout << "  MMU incl. helper stalls (" << t.stall_events.size()
                          << " outside-pause stalls):" << std::endl;
                for (uint64_t w_ms : kWindowsMs) {
                    const uint64_t w_ns = w_ms * 1000000ull;
                    if (w_ns > wall_time_ns) break;
                    double u = GCPhaseTotals::mmu(both, wall_time_ns, w_ns);
                    std::snprintf(buf, sizeof buf, "    MMU %6llu ms: %6.2f%%",
                                  (unsigned long long)w_ms, 100.0 * u);
                    std::cout << buf << std::endl;
                }
            }
        }
        std::cout << "  GC work outside the minor timer: stack walk "
                  << fmtS(t.stack_walk_ns) << ", large-body sweep "
                  << fmtS(t.large_body_sweep_ns)
                  << " (counted as mutator in \"Allocator Timings\")" << std::endl;
    }

    // ---------------- Block 2: minor phase breakdown ----------------
    if (t.minor_records > 0) {
        std::cout << "\nMinor GC Phase Breakdown (threaded-gc-00):" << std::endl;
        const double n = static_cast<double>(t.minor_records);
        const uint64_t denom = t.minor_pause_ns ? t.minor_pause_ns : 1;
        const uint64_t accounted = t.stack_walk_ns + t.roots_longlived_jit_ns +
            t.roots_stackmap_ns + t.roots_ranges_ns + t.roots_external_ns +
            t.drain_tospace_ns + t.drain_promoted_ns + t.tail_ns + t.large_body_sweep_ns;
        const int64_t unaccounted = static_cast<int64_t>(t.minor_pause_ns) -
                                    static_cast<int64_t>(accounted);
        struct Row { const char* name; int64_t ns; };
        const Row rows[] = {
            {"stack walk", (int64_t)t.stack_walk_ns},
            {"roots: long-lived + JIT", (int64_t)t.roots_longlived_jit_ns},
            {"roots: stackmap", (int64_t)t.roots_stackmap_ns},
            {"roots: ranges + singles", (int64_t)t.roots_ranges_ns},
            {"roots: external scanners", (int64_t)t.roots_external_ns},
            {"drain: to-space (Cheney)", (int64_t)t.drain_tospace_ns},
            {"drain: promoted objects", (int64_t)t.drain_promoted_ns},
            {"tail (grow/clear/swap)", (int64_t)t.tail_ns},
            {"large-body sweep", (int64_t)t.large_body_sweep_ns},
            {"unaccounted", unaccounted},
        };
        char buf[256];
        std::snprintf(buf, sizeof buf, "  minors recorded: %llu, summed minor pause %s",
                      (unsigned long long)t.minor_records, fmtS(t.minor_pause_ns).c_str());
        std::cout << buf << std::endl;
        for (const Row& r : rows) {
            std::snprintf(buf, sizeof buf, "  %-28s %12.3f s  %6.2f%%  %9.3f ms/minor",
                          r.name, r.ns / 1.0e9, 100.0 * r.ns / static_cast<double>(denom),
                          r.ns / 1.0e6 / n);
            std::cout << buf << std::endl;
        }
        std::cout << "  (each root phase includes copying/promoting the objects it reaches "
                     "directly; their children are copied in the drain)" << std::endl;
        std::snprintf(buf, sizeof buf,
            "  stack frames walked: mean %.1f, max %llu; matched mean %.1f; slots mean %.1f, max %llu",
            t.frames_walked / n, (unsigned long long)t.frames_walked_max,
            t.frames_matched / n, t.stack_slots / n, (unsigned long long)t.stack_slots_max);
        std::cout << buf << std::endl;
        std::snprintf(buf, sizeof buf, "  stack walk: mean %.3f ms, max %s",
                      t.stack_walk_ns / 1.0e6 / n, fmtMs(t.stack_walk_ns_max).c_str());
        std::cout << buf << std::endl;
        std::snprintf(buf, sizeof buf, "  drain rounds: mean %.2f, max %llu",
                      t.drain_rounds / n, (unsigned long long)t.drain_rounds_max);
        std::cout << buf << std::endl;
        std::snprintf(buf, sizeof buf,
            "  objects per minor: survived %.0f (%.2f MB), promoted %.0f (%.2f MB)",
            t.survived / n, t.survived_bytes / n / 1048576.0,
            t.promoted / n, t.promoted_bytes / n / 1048576.0);
        std::cout << buf << std::endl;
        std::snprintf(buf, sizeof buf,
            "  in-pause lazy sweep: %llu calls, %.3f GB, est. %s (1-in-16 sample, clock overhead removed)",
            (unsigned long long)t.lazy_sweep_calls, t.lazy_sweep_bytes / 1.0e9,
            fmtS(t.lazy_sweep_est_ns).c_str());
        std::cout << buf << std::endl;
        std::snprintf(buf, sizeof buf,
            "  promotion allocator: %llu calls, est. %s, %.1f ns/call (1-in-256 sample; "
            "clock overhead removed)",
            (unsigned long long)t.promo_alloc_calls, fmtS(t.promo_alloc_est_ns).c_str(),
            t.promo_alloc_calls ? (double)t.promo_alloc_est_ns / t.promo_alloc_calls : 0.0);
        std::cout << buf << std::endl;
        std::snprintf(buf, sizeof buf, "  page faults inside minors: minor %llu, major %llu",
                      (unsigned long long)t.minflt, (unsigned long long)t.majflt);
        std::cout << buf << std::endl;
        std::snprintf(buf, sizeof buf, "  calibrated clock-read overhead: %llu ns per bracket",
                      (unsigned long long)gcClockOverheadNs());
        std::cout << buf << std::endl;
    }

    // ---------------- Block 3: external root scanners ----------------
    if (t.minor_records > 0 && t.ext_count > 0) {
        std::cout << "\nExternal Root Scanners (threaded-gc-00):" << std::endl;
        const double n = static_cast<double>(t.minor_records);
        char buf[256];
        for (int i = 0; i < t.ext_count; ++i) {
            std::snprintf(buf, sizeof buf,
                "  %-18s total %10.3f ms  mean %9.3f us/minor  slots %14llu  max slots/minor %llu",
                t.ext_name[i] ? t.ext_name[i] : "unnamed", t.ext_ns[i] / 1.0e6,
                t.ext_ns[i] / 1.0e3 / n, (unsigned long long)t.ext_slots[i],
                (unsigned long long)t.ext_slots_max[i]);
            std::cout << buf << std::endl;
        }
    }
}

// ---------------------------------------------------------------------------
// Per-collection event log (ECO_GC_EVENT_LOG=<path>), tab-separated.
// ---------------------------------------------------------------------------

namespace {

class GCEventLogImpl {
public:
    static GCEventLogImpl& instance() {
        static GCEventLogImpl inst;
        return inst;
    }
    bool enabled() const { return path_ != nullptr; }

    void writeMinor(const MinorGCRecord& r, uint64_t seq, const char* const* names,
                    size_t n_names) {
        std::lock_guard<std::mutex> lock(mu_);
        if (!open(names, n_names)) return;
        std::string line;
        line.reserve(512);
        addField(line, "minor"); addNum(line, tid()); addNum(line, seq);
        addNum(line, r.start_ns); addNum(line, r.pause_ns); addNum(line, r.nursery_pause_ns);
        addNum(line, r.stack_walk_ns); addNum(line, r.frames_walked);
        addNum(line, r.frames_matched); addNum(line, r.stack_slots);
        addNum(line, r.roots_longlived_jit_ns); addNum(line, r.roots_stackmap_ns);
        addNum(line, r.roots_ranges_ns); addNum(line, r.roots_external_ns);
        addNum(line, r.drain_tospace_ns); addNum(line, r.drain_promoted_ns);
        addNum(line, r.drain_rounds); addNum(line, r.tail_ns);
        addNum(line, r.large_body_sweep_ns); addNum(line, r.lazy_sweep_calls);
        addNum(line, r.lazy_sweep_bytes); addNum(line, r.lazy_sweep_est_ns);
        addNum(line, r.promo_alloc_calls); addNum(line, r.promo_alloc_est_ns);
        addNum(line, r.survived); addNum(line, r.promoted);
        addNum(line, r.survived_bytes); addNum(line, r.promoted_bytes);
        addNum(line, r.minflt); addNum(line, r.majflt);
        // External scanner columns in header order; unknown names -> ext:late.
        std::vector<uint64_t> ns(ext_cols_.size() + 1, 0), sl(ext_cols_.size() + 1, 0);
        for (int i = 0; i < r.ext_count; ++i) {
            const char* nm = (names && static_cast<size_t>(i) < n_names) ? names[i] : "unnamed";
            size_t col = ext_cols_.size();
            for (size_t c = 0; c < ext_cols_.size(); ++c)
                if (ext_cols_[c] == nm) { col = c; break; }
            ns[col] += r.ext_ns[i];
            sl[col] += r.ext_slots[i];
        }
        for (size_t c = 0; c <= ext_cols_.size(); ++c) { addNum(line, ns[c]); addNum(line, sl[c]); }
        for (int k = 0; k < 5; ++k) addField(line, "-");
        // threaded-gc-06 (P§3.12): parallel-minor columns.
        addNum(line, r.workers); addNum(line, r.par_sweep_ns); addNum(line, r.par_roots_ns);
        addNum(line, r.par_drain_ns); addNum(line, r.par_close_ns); addNum(line, r.filler_bytes);
        addNum(line, r.mutex_wait_ns); addNum(line, r.imbalance_units);
        // threaded-gc-07 (P§3.20): region-nursery columns (zero in legacy mode).
        const uint64_t rgc[kRegionCols] = {
            r.rg_region, r.rg_merge_ns, r.rg_heal_slots, r.rg_heal_ns, r.rg_wait_ns, r.rg_help_ns,
            r.rg_help_workers, r.rg_late, r.rg_tenured, r.rg_tenured_bytes, r.rg_busy_ns,
            r.rg_ylos_promoted, r.rg_ylos_freed, r.rg_lb_promoted, r.rg_starts, r.rg_heal_recorded,
            r.rg_resolved, r.rg_grant_blocks, r.rg_grant_cells, r.rg_grant_used,
            r.rg_fill_obj_bytes, r.rg_bld_bytes, r.rg_epoch_ns};
        for (uint64_t v : rgc) addNum(line, v);
        finish(line);
    }

    void writeMajor(uint64_t seq, uint64_t start_ns, uint64_t total_ns, uint64_t mark_ns,
                    uint64_t sweep_ns, uint64_t roots_ns, const char* reason) {
        std::lock_guard<std::mutex> lock(mu_);
        if (!open(nullptr, 0)) return;
        std::string line;
        addField(line, "major"); addNum(line, tid()); addNum(line, seq);
        addNum(line, start_ns);
        dashes(line, kMinorNumericCols - 1);  // pause_ns .. majflt
        dashes(line, 2 * (ext_cols_.size() + 1));
        addNum(line, total_ns); addNum(line, mark_ns); addNum(line, sweep_ns);
        addNum(line, roots_ns); addField(line, reason);
        dashes(line, kParCols);   // threaded-gc-06
        dashes(line, kRegionCols);   // threaded-gc-07
        finish(line);
    }

    void writePause(uint64_t seq, uint64_t start_ns, uint64_t dur_ns, uint8_t kind) {
        std::lock_guard<std::mutex> lock(mu_);
        if (!open(nullptr, 0)) return;
        std::string line;
        addField(line, "pause"); addNum(line, tid()); addNum(line, seq);
        addNum(line, start_ns); addNum(line, dur_ns);
        dashes(line, kMinorNumericCols - 2);
        dashes(line, 2 * (ext_cols_.size() + 1));
        dashes(line, 4);
        static const char* const kKind[] = {"minor", "minor+major", "major",
                                            "minor+t0", "minor+slice", "minor+handoff"};
        addField(line, kind < 6 ? kKind[kind] : "?");
        dashes(line, kParCols);   // threaded-gc-06
        dashes(line, kRegionCols);   // threaded-gc-07
        finish(line);
    }

    // threaded-gc-03: start_ns/pause_ns carry the stall; the reason column
    // carries "stall:<client>[:pause]".
    void writeStall(uint64_t start_ns, uint64_t dur_ns, const char* client, bool in_pause) {
        std::lock_guard<std::mutex> lock(mu_);
        if (!open(nullptr, 0)) return;
        std::string line;
        addField(line, "stall"); addNum(line, tid()); addNum(line, 0);
        addNum(line, start_ns); addNum(line, dur_ns);
        dashes(line, kMinorNumericCols - 2);
        dashes(line, 2 * (ext_cols_.size() + 1));
        dashes(line, 4);
        std::string r = std::string("stall:") + client + (in_pause ? ":pause" : "");
        addField(line, r.c_str());
        dashes(line, kParCols);   // threaded-gc-06
        dashes(line, kRegionCols);   // threaded-gc-07
        finish(line);
    }

    // threaded-gc-03: a finished helper job. start_ns = post time,
    // pause_ns = queueing delay (start - post), nursery_pause_ns = run time
    // (end - start), stack_walk_ns = bytes; reason column = "job:<client>".
    void writeJob(uint64_t post_ns, uint64_t start_ns, uint64_t end_ns, uint64_t bytes,
                  const char* client) {
        std::lock_guard<std::mutex> lock(mu_);
        if (!open(nullptr, 0)) return;
        std::string line;
        addField(line, "job"); addNum(line, tid()); addNum(line, 0);
        addNum(line, post_ns);
        addNum(line, start_ns >= post_ns ? start_ns - post_ns : 0);
        addNum(line, end_ns >= start_ns ? end_ns - start_ns : 0);
        addNum(line, bytes);
        dashes(line, kMinorNumericCols - 4);
        dashes(line, 2 * (ext_cols_.size() + 1));
        dashes(line, 4);
        std::string r = std::string("job:") + client;
        addField(line, r.c_str());
        dashes(line, kParCols);   // threaded-gc-06
        dashes(line, kRegionCols);   // threaded-gc-07
        finish(line);
    }

    // threaded-gc-05a: one incremental mark cycle. start_ns = t0,
    // pause_ns = span (t0 -> handoff wall), nursery_pause_ns = span in minors,
    // stack_walk_ns = mark units; reason column = "cycle:<finish>".
    void writeCycle(uint64_t seq, uint64_t t0_ns, uint64_t span_ns, uint32_t span_minors,
                    uint64_t units, const char* finish_reason) {
        std::lock_guard<std::mutex> lock(mu_);
        if (!open(nullptr, 0)) return;
        std::string line;
        addField(line, "cycle"); addNum(line, tid()); addNum(line, seq);
        addNum(line, t0_ns); addNum(line, span_ns);
        addNum(line, span_minors); addNum(line, units);
        dashes(line, kMinorNumericCols - 4);
        dashes(line, 2 * (ext_cols_.size() + 1));
        dashes(line, 4);
        std::string r = std::string("cycle:") + finish_reason;
        addField(line, r.c_str());
        dashes(line, kParCols);   // threaded-gc-06
        dashes(line, kRegionCols);   // threaded-gc-07
        finish(line);
    }

    void flush() {
        std::lock_guard<std::mutex> lock(mu_);
        if (file_) std::fflush(file_);
    }

private:
    // Numeric columns of a minor row after (kind, tid, seq): start_ns .. majflt.
    static constexpr int kMinorNumericCols = 27;
    // threaded-gc-06: parallel-minor columns after major_reason.
    static constexpr int kParCols = 8;
    static constexpr int kRegionCols = 23;

    GCEventLogImpl() {
        const char* p = std::getenv("ECO_GC_EVENT_LOG");
        if (p && *p) path_ = p;
    }

    bool open(const char* const* names, size_t n_names) {
        if (!path_) return false;
        if (file_) return true;
        if (failed_) return false;
        file_ = std::fopen(path_, "w");
        if (!file_) { failed_ = true; return false; }
        std::atexit([] { GCEventLogImpl::instance().flush(); });
        for (size_t i = 0; names && i < n_names; ++i) ext_cols_.push_back(names[i] ? names[i] : "unnamed");
        std::string h =
            "kind\ttid\tseq\tstart_ns\tpause_ns\tnursery_pause_ns\tstack_walk_ns\t"
            "frames_walked\tframes_matched\tstack_slots\troots_longlived_jit_ns\t"
            "roots_stackmap_ns\troots_ranges_ns\troots_external_ns\tdrain_tospace_ns\t"
            "drain_promoted_ns\tdrain_rounds\ttail_ns\tlarge_body_sweep_ns\t"
            "lazy_sweep_calls\tlazy_sweep_bytes\tlazy_sweep_est_ns\tpromo_alloc_calls\t"
            "promo_alloc_est_ns\tsurvived\tpromoted\tsurvived_bytes\tpromoted_bytes\t"
            "minflt\tmajflt";
        for (const std::string& c : ext_cols_) h += "\text:" + c + "_ns\text:" + c + "_slots";
        h += "\text:late_ns\text:late_slots";
        h += "\tmajor_total_ns\tmajor_mark_ns\tmajor_sweep_ns\tmajor_roots_ns\tmajor_reason";
        h += "\tpar_workers\tpar_sweep_ns\tpar_roots_ns\tpar_drain_ns\tpar_close_ns"
             "\tpar_filler_bytes\tpar_mutex_wait_ns\tpar_imbalance_units"
             "\trg_region\trg_merge_ns\trg_heal_slots\trg_heal_ns\trg_wait_ns\trg_help_ns"
             "\trg_help_workers\trg_late\trg_tenured\trg_tenured_bytes\trg_busy_ns"
             "\trg_ylos_promoted\trg_ylos_freed\trg_lb_promoted\trg_starts\trg_heal_recorded"
             "\trg_resolved\trg_grant_blocks\trg_grant_cells\trg_grant_used\trg_fill_obj_bytes"
             "\trg_bld_bytes\trg_epoch_ns\n";
        std::fputs(h.c_str(), file_);
        return true;
    }

    static uint64_t tid() {
        static std::atomic<uint64_t> next{0};
        thread_local uint64_t id = next++;
        return id;
    }
    static void addField(std::string& l, const char* v) {
        if (!l.empty()) l += '\t';
        l += v;
    }
    static void addNum(std::string& l, uint64_t v) {
        if (!l.empty()) l += '\t';
        l += std::to_string(v);
    }
    static void dashes(std::string& l, size_t n) {
        for (size_t i = 0; i < n; ++i) addField(l, "-");
    }
    void finish(std::string& l) {
        l += '\n';
        std::fputs(l.c_str(), file_);
    }

    const char* path_ = nullptr;
    FILE* file_ = nullptr;
    bool failed_ = false;
    std::mutex mu_;
    std::vector<std::string> ext_cols_;
};

}  // namespace

bool gcEventLogEnabled() noexcept { return GCEventLogImpl::instance().enabled(); }

void gcEventLogMinor(const MinorGCRecord& r, uint64_t seq, const char* const* names,
                     size_t n_names) {
    GCEventLogImpl::instance().writeMinor(r, seq, names, n_names);
}

void gcEventLogMajor(uint64_t seq, uint64_t start_ns, uint64_t total_ns, uint64_t mark_ns,
                     uint64_t sweep_ns, uint64_t roots_ns, const char* reason) {
    GCEventLogImpl::instance().writeMajor(seq, start_ns, total_ns, mark_ns, sweep_ns,
                                          roots_ns, reason);
}

void gcEventLogStall(uint64_t start_ns, uint64_t dur_ns, const char* client, bool in_pause) {
    GCEventLogImpl::instance().writeStall(start_ns, dur_ns, client, in_pause);
}

void gcEventLogJob(uint64_t post_ns, uint64_t start_ns, uint64_t end_ns, uint64_t bytes,
                   const char* client) {
    GCEventLogImpl::instance().writeJob(post_ns, start_ns, end_ns, bytes, client);
}

void gcEventLogPause(uint64_t seq, uint64_t start_ns, uint64_t dur_ns, uint8_t kind) {
    GCEventLogImpl::instance().writePause(seq, start_ns, dur_ns, kind);
}

void gcEventLogCycle(uint64_t seq, uint64_t t0_ns, uint64_t span_ns, uint32_t span_minors,
                     uint64_t units, const char* finish) {
    GCEventLogImpl::instance().writeCycle(seq, t0_ns, span_ns, span_minors, units, finish);
}

void gcEventLogFlush() noexcept { GCEventLogImpl::instance().flush(); }

const char* gcMajorReasonName(GCStats::MajorReason r) { return majorReasonName(r); }

const char* gcTagName(int tag) { return tagName(tag); }

void GCStats::printBitmapAllocBlock() const {
    if (!bm.any()) return;
    std::cout << "\nOld-gen Bitmap Allocation (threaded-gc-02):" << std::endl;
    auto row = [](const char* k, uint64_t v) {
        char buf[160];
        std::snprintf(buf, sizeof buf, "  %-30s %16llu", k, (unsigned long long)v);
        std::cout << buf << std::endl;
    };
    row("cursor allocations", bm.bitmap_allocs);
    row("cursor allocated bytes", bm.bitmap_alloc_bytes);
    row("partial-queue refills", bm.cursor_refills);
    row("virgin blocks", bm.virgin_blocks);
    row("free-list pops (mixed cells)", bm.list_pops);
    row("split allocations", bm.split_allocs);
    row("sweep-on-demand hits", bm.sweep_on_demand_hits);
    row("gap-sweep live objects", bm.gap_sweep_live_objects);
    row("gap-sweep gaps", bm.gap_sweep_gaps);
    row("gap-sweep bytes covered", bm.gap_sweep_bytes);
    row("uniform cells freed (bodies)", bm.uniform_cells_freed);
    row("blocks classified uniform", bm.blocks_classified_uniform);
    row("blocks classified large", bm.blocks_classified_large);
    row("blocks classified mixed", bm.blocks_classified_mixed);
    row("bitmap-free bytes at majors", bm.bitmap_free_bytes_at_major);
}

// ---------------------------------------------------------------------------
// threaded-gc-03 (plans/threaded-gc-03-helper-threads.md P§3.9)
// ---------------------------------------------------------------------------

void PageSupplyStats::mergeMax(const PageSupplyStats& o) {
    auto mx = [](uint64_t& a, uint64_t b) { if (b > a) a = b; };
    mx(released_bytes, o.released_bytes);
    mx(released_extents, o.released_extents);
    mx(discarded_bytes, o.discarded_bytes);
    mx(discarded_extents, o.discarded_extents);
    mx(discard_inline_ns, o.discard_inline_ns);
    mx(reuse_resident_bytes, o.reuse_resident_bytes);
    mx(reuse_after_discard_bytes, o.reuse_after_discard_bytes);
    mx(fresh_bytes, o.fresh_bytes);
    mx(fresh_ahead_hit_bytes, o.fresh_ahead_hit_bytes);
    mx(fresh_ahead_miss_bytes, o.fresh_ahead_miss_bytes);
    mx(pending_peak_bytes, o.pending_peak_bytes);
}

void HelperStatsSnapshot::mergeMax(const HelperStatsSnapshot& o) {
    // Only the combined (allocator-filled) object is non-zero; take it whole.
    if (o.mode != 0 && mode == 0) *this = o;
}

namespace {
std::string fmtMB3(uint64_t b) {
    char buf[64];
    std::snprintf(buf, sizeof buf, "%.2f MB", b / (1024.0 * 1024.0));
    return buf;
}
std::string fmtMs3(uint64_t ns) {
    char buf[64];
    std::snprintf(buf, sizeof buf, "%.3f ms", ns / 1.0e6);
    return buf;
}
}  // namespace

void GCStats::printPageSupplyBlock() const {
    const PageSupplyStats& p = page_supply;
    if (!p.any()) return;
    std::cout << "\nOld-gen Page Supply (threaded-gc-03):" << std::endl;
    char buf[256];
    std::snprintf(buf, sizeof buf, "  released:              %14s  (%llu extents)",
                  fmtMB3(p.released_bytes).c_str(), (unsigned long long)p.released_extents);
    std::cout << buf << std::endl;
    std::snprintf(buf, sizeof buf,
                  "  discarded:             %14s  (%llu extents; inline madvise %s)",
                  fmtMB3(p.discarded_bytes).c_str(), (unsigned long long)p.discarded_extents,
                  fmtMs3(p.discard_inline_ns).c_str());
    std::cout << buf << std::endl;
    std::snprintf(buf, sizeof buf, "  reuse: resident        %14s", fmtMB3(p.reuse_resident_bytes).c_str());
    std::cout << buf << std::endl;
    std::snprintf(buf, sizeof buf, "  reuse: after discard   %14s", fmtMB3(p.reuse_after_discard_bytes).c_str());
    std::cout << buf << std::endl;
    std::snprintf(buf, sizeof buf, "  fresh commit:          %14s  (ahead-hit %s, ahead-miss %s)",
                  fmtMB3(p.fresh_bytes).c_str(), fmtMB3(p.fresh_ahead_hit_bytes).c_str(),
                  fmtMB3(p.fresh_ahead_miss_bytes).c_str());
    std::cout << buf << std::endl;
    std::snprintf(buf, sizeof buf, "  pending peak:          %14s", fmtMB3(p.pending_peak_bytes).c_str());
    std::cout << buf << std::endl;
}

void GCStats::printLargePtrBlock() const {
    if (!lp.any()) return;
    std::cout << "\nLarge Pointer Objects (threaded-gc-04b):" << std::endl;
    auto row = [](const char* k, uint64_t n, uint64_t b) {
        char buf[160];
        std::snprintf(buf, sizeof buf, "  %-28s %12llu  %14.2f MB", k, (unsigned long long)n,
                      b / (1024.0 * 1024.0));
        std::cout << buf << std::endl;
    };
    row("nursery (pointer-bearing)", lp.nursery_allocs, lp.nursery_bytes);
    row("young large objects (YLOS)", lp.ylos_allocs, lp.ylos_bytes);
    row("closure-group regions", lp.region_allocs, lp.region_bytes);
    row("pointer-free, old pinned", lp.pointerfree_allocs, lp.pointerfree_bytes);
    char buf[200];
    std::snprintf(buf, sizeof buf,
                  "  YLOS: promoted in place %llu, freed at minor %llu, retired at major %llu, "
                  "reach calls %llu, scans %llu",
                  (unsigned long long)lp.ylos_promoted_in_place,
                  (unsigned long long)lp.ylos_freed_minor,
                  (unsigned long long)lp.ylos_retired_major,
                  (unsigned long long)lp.ylos_reach_calls, (unsigned long long)lp.ylos_scans);
    std::cout << buf << std::endl;
}

void GCStats::printParMinorBlock() const {
    if (!pmin.any()) return;
    const ParMinorStats& p = pmin;
    std::cout << "\nParallel Minor GC (threaded-gc-06):" << std::endl;
    char buf[320];
    std::snprintf(buf, sizeof buf,
                  "  minors: parallel %llu (mean workers %.2f), serial small %llu, serial space %llu, alloc-end capped %llu",
                  (unsigned long long)p.minors_parallel,
                  p.minors_parallel ? (double)p.workers_sum / (double)p.minors_parallel : 0.0,
                  (unsigned long long)p.serial_small, (unsigned long long)p.serial_space,
                  (unsigned long long)p.alloc_end_capped);
    std::cout << buf << std::endl;
    std::snprintf(buf, sizeof buf,
                  "  to-space: LAB claims %llu, direct claims %llu, fillers %.2f MB (max %.2f MB in one minor)",
                  (unsigned long long)p.lab_claims, (unsigned long long)p.direct_claims,
                  p.filler_bytes_total / (1024.0 * 1024.0), p.filler_bytes_max / (1024.0 * 1024.0));
    std::cout << buf << std::endl;
    std::snprintf(buf, sizeof buf,
                  "  claims: races %llu, busy waits %llu; spine splits %llu, chunks %llu",
                  (unsigned long long)p.claim_races, (unsigned long long)p.busy_waits,
                  (unsigned long long)p.spine_splits, (unsigned long long)p.chunks);
    std::cout << buf << std::endl;
    std::snprintf(buf, sizeof buf,
                  "  work: steals %llu (aborts %llu), idle spins %llu yields %llu sleeps %llu",
                  (unsigned long long)p.steals, (unsigned long long)p.steal_aborts,
                  (unsigned long long)p.idle_spins, (unsigned long long)p.idle_yields,
                  (unsigned long long)p.idle_sleeps);
    std::cout << buf << std::endl;
    std::snprintf(buf, sizeof buf,
                  "  promo mutex: acquires %llu, wait %.3f s; drain %.3f s, pre-drain sweep %.3f s, "
                  "imbalance %llu units, member CPU %.3f s",
                  (unsigned long long)p.promo_mutex_acquires, p.promo_mutex_wait_ns / 1e9,
                  p.drain_ns_sum / 1e9, p.sweep_ns_sum / 1e9, (unsigned long long)p.imbalance_units_sum,
                  p.member_cpu_ns / 1e9);
    std::cout << buf << std::endl;
}

void GCStats::printRegionBlock() const {
    if (!rg.any()) return;
    const RegionTenureStats& r = rg;
    std::cout << "\nRegion nursery / tenuring (threaded-gc-07):" << std::endl;
    char buf[400];
    std::snprintf(buf, sizeof buf,
                  "  minors %llu, jobs %llu, merges %llu; tenured %llu objects, %.2f MB; starts %llu, "
                  "heal slots %llu, resolved refs %llu",
                  (unsigned long long)r.minors, (unsigned long long)r.jobs, (unsigned long long)r.merges,
                  (unsigned long long)r.tenured, r.tenured_bytes / (1024.0 * 1024.0),
                  (unsigned long long)r.starts, (unsigned long long)r.heal_slots,
                  (unsigned long long)r.resolved);
    std::cout << buf << std::endl;
    std::snprintf(buf, sizeof buf,
                  "  pause: merge %.3f s (heal %.3f s), wait %.3f s, help %.3f s (late minors %llu, "
                  "stops %llu, help workers %llu, fork refusals %llu), eden clear %.3f s",
                  r.merge_ns / 1e9, r.heal_ns / 1e9, r.wait_ns / 1e9, r.help_ns / 1e9,
                  (unsigned long long)r.late, (unsigned long long)r.stops,
                  (unsigned long long)r.help_workers_sum, (unsigned long long)r.fork_refusals,
                  r.eden_clear_ns / 1e9);
    std::cout << buf << std::endl;
    std::vector<uint32_t> u = r.util_ppm;
    std::sort(u.begin(), u.end());
    auto pct = [&](double q) -> double {
        if (u.empty()) return 0.0;
        size_t i = static_cast<size_t>(q * static_cast<double>(u.size() - 1));
        return u[i] / 1e6;
    };
    std::snprintf(buf, sizeof buf,
                  "  collector: busy %.3f s over epochs %.3f s (utilization %.3f; per job p50 %.3f "
                  "p99 %.3f max %.3f), CPU %.3f s; sync parallel jobs %llu",
                  r.busy_ns / 1e9, r.epoch_ns / 1e9,
                  r.epoch_ns ? (double)r.busy_ns / (double)r.epoch_ns : 0.0, pct(0.5), pct(0.99),
                  u.empty() ? 0.0 : u.back() / 1e6, r.collector_cpu_ns / 1e9,
                  (unsigned long long)r.sync_parallel_jobs);
    std::cout << buf << std::endl;
    std::snprintf(buf, sizeof buf,
                  "  grants: blocks %llu (virgin %llu), cells %llu, used %llu; YLOS generation "
                  "promoted %llu freed %llu; bodies transferred %llu; shadow wraps %llu",
                  (unsigned long long)r.grant_blocks, (unsigned long long)r.grant_virgin,
                  (unsigned long long)r.grant_cells, (unsigned long long)r.grant_used,
                  (unsigned long long)r.ylos_gen_promoted, (unsigned long long)r.ylos_gen_freed,
                  (unsigned long long)r.lb_promoted, (unsigned long long)r.shadow_wraps);
    std::cout << buf << std::endl;
    if (r.par_runs != 0) {
        std::snprintf(buf, sizeof buf,
                      "  parallel engines: runs %llu, entries %llu (busiest worker %.1f %%), steals %llu, "
                      "idle spins %llu yields %llu sleeps %llu",
                      (unsigned long long)r.par_runs, (unsigned long long)r.par_units,
                      r.par_units ? 100.0 * (double)r.par_units_max_sum / (double)r.par_units : 0.0,
                      (unsigned long long)r.par_steals, (unsigned long long)r.par_idle_spins,
                      (unsigned long long)r.par_idle_yields, (unsigned long long)r.par_idle_sleeps);
        std::cout << buf << std::endl;
    }
    if (r.tenure_age > 1) {
        std::snprintf(buf, sizeof buf,
                      "  ageing (threaded-gc-07b): tenure age %llu; age starts %llu, marked %llu objects "
                      "(%.2f MB), heal slots from the mark %llu; zap spans %llu (%.2f MB, %.3f s in "
                      "pauses); L3 forced exact %llu; parallel marks in pauses %llu",
                      (unsigned long long)r.tenure_age, (unsigned long long)r.age_starts,
                      (unsigned long long)r.age_marked, r.age_marked_bytes / (1024.0 * 1024.0),
                      (unsigned long long)r.age_heal, (unsigned long long)r.zapped,
                      r.zapped_bytes / (1024.0 * 1024.0), r.zap_ns / 1e9,
                      (unsigned long long)r.age_forced_exact, (unsigned long long)r.age_par_marks);
        std::cout << buf << std::endl;
        std::snprintf(buf, sizeof buf, "  dead ageing-generation YLOS slots cleared at the merge (CR-038): %llu",
                      (unsigned long long)r.zapped_ylos);
        std::cout << buf << std::endl;
    }
    if (r.major_zaps > 0) {
        std::snprintf(buf, sizeof buf,
                      "  STW major zap (HEAP_074, CR-017): %llu passes, %llu dead survivors (%.2f MB), "
                      "%.3f ms total, %.3f ms mean, %.3f ms max per major",
                      (unsigned long long)r.major_zaps, (unsigned long long)r.major_zapped,
                      r.major_zapped_bytes / (1024.0 * 1024.0), r.major_zap_ns / 1e6,
                      r.major_zap_ns / 1e6 / (double)r.major_zaps, r.major_zap_ns_max / 1e6);
        std::cout << buf << std::endl;
    }
    std::snprintf(buf, sizeof buf, "  survivor copies < 16 B: %llu; parallel heals: %llu; grant fallbacks (old gen near its cap): %llu",
                  (unsigned long long)r.copies_under16, (unsigned long long)r.heals_parallel,
                  (unsigned long long)r.grant_fallbacks);
    std::cout << buf << std::endl;
    std::snprintf(buf, sizeof buf,
                  "  retention: max non-Free survivor extents between minors %llu (+1 fill in a "
                  "minor); nursery RSS estimate %.1f MB (eden %.1f + survivor high-water %.1f + "
                  "shadow %.1f)",
                  (unsigned long long)r.max_nonfree,
                  (r.eden_capacity_bytes + r.survivor_hw_bytes + r.shadow_committed_bytes) / (1024.0 * 1024.0),
                  r.eden_capacity_bytes / (1024.0 * 1024.0), r.survivor_hw_bytes / (1024.0 * 1024.0),
                  r.shadow_committed_bytes / (1024.0 * 1024.0));
    std::cout << buf << std::endl;
}

void GCStats::printIncrMarkBlock() const {
    if (!im.any()) return;
    std::cout << "\nIncremental Mark (threaded-gc-05a):" << std::endl;
    char buf[256];
    std::snprintf(buf, sizeof buf,
                  "  incremental: cycles %llu, slices %llu, slice units %llu, closing units %llu (max %llu)",
                  (unsigned long long)im.cycles, (unsigned long long)im.slices,
                  (unsigned long long)im.slice_units, (unsigned long long)im.closing_units,
                  (unsigned long long)im.closing_units_max);
    std::cout << buf << std::endl;
    std::snprintf(buf, sizeof buf,
                  "  finishes: schedule %llu, pressure %llu, join %llu",
                  (unsigned long long)im.finish_schedule, (unsigned long long)im.finish_pressure,
                  (unsigned long long)im.finish_join);
    std::cout << buf << std::endl;
    std::snprintf(buf, sizeof buf,
                  "  black %.2f MB, traced live %.2f MB, deferred frees %llu (%.2f MB)",
                  im.black_bytes / (1024.0 * 1024.0), im.traced_live_bytes / (1024.0 * 1024.0),
                  (unsigned long long)im.deferred_frees, im.deferred_free_bytes / (1024.0 * 1024.0));
    std::cout << buf << std::endl;
    std::snprintf(buf, sizeof buf,
                  "  t0 snapshot: survivors %llu (%.2f MB), ylos %llu",
                  (unsigned long long)im.t0_survivors, im.t0_survivor_bytes / (1024.0 * 1024.0),
                  (unsigned long long)im.t0_ylos);
    std::cout << buf << std::endl;
    std::snprintf(buf, sizeof buf,
                  "  in-pause ms: t0 total %.3f max %.3f; slices total %.3f max %.3f; handoff total %.3f max %.3f",
                  im.t0_ns_total / 1e6, im.t0_ns_max / 1e6, im.slice_ns_total / 1e6,
                  im.slice_ns_max / 1e6, im.handoff_ns_total / 1e6, im.handoff_ns_max / 1e6);
    std::cout << buf << std::endl;
    std::snprintf(buf, sizeof buf,
                  "  t0 of which prepare (lazy-sweep drain + bitmap clear): total %.3f max %.3f ms",
                  im.t0_prep_ns_total / 1e6, im.t0_prep_ns_max / 1e6);
    std::cout << buf << std::endl;
}

void GCStats::printParMarkBlock() const {
    if (!pm.any()) return;
    std::cout << "\nParallel Mark (threaded-gc-05b):" << std::endl;
    char buf[256];
    std::snprintf(buf, sizeof buf,
                  "  runs %llu, members %llu, units %llu, chunks pushed %llu",
                  (unsigned long long)pm.runs, (unsigned long long)pm.members_max,
                  (unsigned long long)pm.units, (unsigned long long)pm.chunks_pushed);
    std::cout << buf << std::endl;
    std::snprintf(buf, sizeof buf,
                  "  steals %llu (aborts %llu, empty %llu); idle spins %llu, yields %llu, sleeps %llu",
                  (unsigned long long)pm.steals, (unsigned long long)pm.steal_aborts,
                  (unsigned long long)pm.steal_empty, (unsigned long long)pm.idle_spins,
                  (unsigned long long)pm.idle_yields, (unsigned long long)pm.idle_sleeps);
    std::cout << buf << std::endl;
    std::snprintf(buf, sizeof buf,
                  "  imbalance (max/mean units): mean %.3f, max %.3f",
                  pm.runs ? pm.imbalance_milli_sum / 1000.0 / pm.runs : 0.0,
                  pm.imbalance_milli_max / 1000.0);
    std::cout << buf << std::endl;
    std::snprintf(buf, sizeof buf,
                  "  run ms total %.3f max %.3f; gang (collector) CPU %.3f s; deque grows %llu, peak %llu",
                  pm.run_ns_total / 1e6, pm.run_ns_max / 1e6, pm.member_cpu_ns / 1e9,
                  (unsigned long long)pm.deque_grows, (unsigned long long)pm.deque_peak_entries);
    std::cout << buf << std::endl;
}

void GCStats::printConcMarkBlock() const {
    if (!cm.any() && cm.mutator_cpu_ns == 0) return;
    std::cout << "\nConcurrent Mark (threaded-gc-05c):" << std::endl;
    char buf[320];
    std::snprintf(buf, sizeof buf,
                  "  episodes %llu (relaunched %llu, stopped %llu, refused %llu); background units %llu",
                  (unsigned long long)cm.episodes_launched, (unsigned long long)cm.episodes_relaunched,
                  (unsigned long long)cm.episodes_stopped, (unsigned long long)cm.episodes_refused,
                  (unsigned long long)cm.bg_units);
    std::cout << buf << std::endl;
    std::snprintf(buf, sizeof buf,
                  "  assists %llu (units %llu, ms total %.3f max %.3f); closings with work %llu "
                  "(units %llu, ms total %.3f max %.3f)",
                  (unsigned long long)cm.assists, (unsigned long long)cm.assist_units,
                  cm.assist_ns_total / 1e6, cm.assist_ns_max / 1e6,
                  (unsigned long long)cm.closings_with_work, (unsigned long long)cm.closing_units,
                  cm.closing_ns_total / 1e6, cm.closing_ns_max / 1e6);
    std::cout << buf << std::endl;
    std::snprintf(buf, sizeof buf,
                  "  background done by k<=T/4 %llu, <=T/2 %llu, <=3T/4 %llu, <=T %llu, at closing %llu",
                  (unsigned long long)cm.done_k_hist[0], (unsigned long long)cm.done_k_hist[1],
                  (unsigned long long)cm.done_k_hist[2], (unsigned long long)cm.done_k_hist[3],
                  (unsigned long long)cm.done_k_hist[4]);
    std::cout << buf << std::endl;
    std::snprintf(buf, sizeof buf,
                  "  background CPU %.3f s, episode wall %.3f s; join wait max %.3f ms, stop wait max %.3f ms",
                  cm.bg_cpu_ns / 1e9, cm.bg_wall_ns_total / 1e9, cm.join_wait_ns_max / 1e6,
                  cm.stop_wait_ns_max / 1e6);
    std::cout << buf << std::endl;
    std::snprintf(buf, sizeof buf,
                  "  mutator CPU %.3f s, of which in pauses %.3f s; outside pauses %.3f s",
                  cm.mutator_cpu_ns / 1e9, cm.mutator_pause_cpu_ns / 1e9,
                  (cm.mutator_cpu_ns - std::min(cm.mutator_cpu_ns, cm.mutator_pause_cpu_ns)) / 1e9);
    std::cout << buf << std::endl;
}

void GCStats::printHelperBlock() const {
    const HelperStatsSnapshot& h = helper;
    if (h.mode == 0) return;
    std::cout << "\nGC Helper Threads (threaded-gc-03):" << std::endl;
    char buf[256];
    std::snprintf(buf, sizeof buf,
                  "  mode %u (%s), threads %u, pin cpu %d, jitter %u us",
                  h.mode, h.mode == 1 ? "sync" : "concurrent", h.threads, h.pin_cpu,
                  h.jitter_us);
    std::cout << buf << std::endl;
    std::snprintf(buf, sizeof buf,
                  "  config: decommit delay %llu syncs / %llu majors, pending cap %s, commit-ahead %s%s",
                  (unsigned long long)h.decommit_delay,
                  (unsigned long long)h.decommit_delay_majors, fmtMB3(h.pending_cap).c_str(),
                  fmtMB3(h.commit_ahead_bytes).c_str(),
                  (h.commit_ahead_bytes > 0 && !h.populate_supported)
                      ? " (unsupported: no MADV_POPULATE_WRITE)" : "");
    std::cout << buf << std::endl;
    static const char* kNames[] = {"decommit", "populate", "test"};
    uint64_t helper_cpu = 0;
    for (int c = 0; c < HelperStatsSnapshot::kClients; ++c) {
        helper_cpu += h.cpu_ns[c];
        if (h.jobs[c] == 0) continue;
        std::snprintf(buf, sizeof buf,
                      "  %-9s jobs %8llu  bytes %14s  helper cpu %12s  inline cpu %12s",
                      kNames[c], (unsigned long long)h.jobs[c], fmtMB3(h.bytes[c]).c_str(),
                      fmtMs3(h.cpu_ns[c]).c_str(), fmtMs3(h.inline_cpu_ns[c]).c_str());
        std::cout << buf << std::endl;
    }
    std::snprintf(buf, sizeof buf,
                  "  stalls: %llu, total %s, max %s; outside a pause %llu (%s)",
                  (unsigned long long)h.stall_count, fmtMs3(h.stall_ns).c_str(),
                  fmtMs3(h.stall_max_ns).c_str(), (unsigned long long)h.stall_outside_pause,
                  fmtMs3(h.stall_outside_pause_ns).c_str());
    std::cout << buf << std::endl;
    std::snprintf(buf, sizeof buf,
                  "  waits: reuse %llu, release %llu, slot-full %llu",
                  (unsigned long long)h.reuse_waits, (unsigned long long)h.release_waits,
                  (unsigned long long)h.slot_full_waits);
    std::cout << buf << std::endl;
    std::snprintf(buf, sizeof buf,
                  "  decommit: cancelled %s (%llu extents), jobs %llu, failures %llu",
                  fmtMB3(h.cancelled_bytes).c_str(), (unsigned long long)h.cancelled_extents,
                  (unsigned long long)h.discard_jobs, (unsigned long long)h.discard_failures);
    std::cout << buf << std::endl;
    std::snprintf(buf, sizeof buf,
                  "  populate: jobs %llu, bytes %s, failures %llu, window commit failures %llu",
                  (unsigned long long)h.populate_jobs, fmtMB3(h.populate_bytes).c_str(),
                  (unsigned long long)h.populate_failures,
                  (unsigned long long)h.window_commit_failures);
    std::cout << buf << std::endl;
    std::snprintf(buf, sizeof buf,
                  "  process cpu %.3f s, helper cpu %.3f s, non-helper cpu %.3f s",
                  h.process_cpu_ns / 1.0e9, helper_cpu / 1.0e9,
                  (h.process_cpu_ns > helper_cpu ? h.process_cpu_ns - helper_cpu : 0) / 1.0e9);
    std::cout << buf << std::endl;
}

} // namespace Elm
