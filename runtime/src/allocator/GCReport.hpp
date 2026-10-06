/**
 * GCReport: what an explicit collection did (plans/frontend-heap-release.md §3.1, HEAP_076).
 *
 * Returned by Allocator::collectMinor() and Allocator::collectMajorAndRelease(), and rendered as
 * JSON by the Eco.GC kernel (eco-kernel-cpp/src/eco-kernel/GC.cpp, keys = the Elm field names of §4.1).
 * A plain struct with no allocator includes; every field is filled in every build, including
 * Release builds where ENABLE_GC_STATS = 0.
 *
 * rss_*, *_ns and trim_result are OBSERVATIONS: no GC policy and no Elm control flow may read
 * them (HEAP_076, GC_DET_001).
 */
#pragma once

#include <cstdint>

namespace Elm {

struct GCReport {
    enum class Kind : uint8_t { Minor, Major };
    Kind kind = Kind::Minor;

    // Wall-clock nanoseconds: the whole call, the collection, the sweep driven to Idle, the
    // forced shrink, the PageWork drain (discard of every Pending extent) and malloc_trim.
    uint64_t total_ns = 0, gc_ns = 0, sweep_ns = 0, shrink_ns = 0, discard_ns = 0, trim_ns = 0;

    uint64_t old_in_use_before = 0, old_in_use_after = 0;    // getOldGenCommittedBytes (acquired - released)
    uint64_t old_pending_before = 0, old_pending_after = 0;  // PageWork pending_bytes (released, still resident); 0 in mode 0
    uint64_t old_high_water = 0;                             // old_gen_committed (bump; never falls)
    uint64_t live_after_mark = 0;                            // OldGenSpace::majorLiveBytes (0 if no major ran)
    uint64_t released_bytes = 0;                             // delta of page_supply_.released_bytes
    uint64_t shrink_released_bytes = 0;                      // in-use drop across the forced shrink
    uint64_t discarded_bytes = 0;                            // delta of discard_posted_bytes (modes 1/2) or page_supply_.discarded_bytes (mode 0)
    uint64_t nursery_committed = 0;                          // nursery_low_committed_ + nursery_high_committed_
    uint64_t rss_before = 0, rss_after_discard = 0, rss_after = 0;  // 0 = unavailable
    int64_t trim_result = -1;                                // malloc_trim rc; -1 = not run
    uint64_t minor_count = 0;                                // NurserySpace::minorSeq after the call
    uint64_t major_count = 0;                                // OldGenSpace::majorEpoch after the call
    uint64_t majors_run = 0;                                 // majors that ran inside the call
};

} // namespace Elm
