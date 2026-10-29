// A program may ask for a collection explicitly, and wants to know afterwards what it achieved. GCReport is the answer:
// a record of one explicit collection, built by `Allocator::collectMinor` or `Allocator::collectMajorAndRelease` and
// rendered as JSON by the Eco.GC kernel. It is plain data with no allocator includes, and no field depends on
// `ENABLE_GC_STATS`.
//
// Most fields are snapshots of allocator counters taken before and after the call, or the difference between two.
// Three terms recur:
// - *in use*: old-generation bytes acquired and not yet released (`Allocator::getOldGenCommittedBytes`);
// - *pending*: released bytes that `PageWork` has not yet discarded, so they are still resident;
// - *mode 0*: the `gc_thread_mode` with no `PageWork`, where nothing is ever pending.
//
// The `rss_*`, `*_ns` and `trim_result` fields are observations (HEAP_076, GC_DET_001): they vary from run to run, and
// no GC policy and no Elm control flow may read them.
#pragma once

#include <cstdint>

namespace Elm {

/**
 * What one explicit collection did, as counter snapshots and timings.
 *
 * A field the call's kind does not produce keeps its default. A `Minor` report has zero `sweep_ns`, `shrink_ns`,
 * `discard_ns`, `trim_ns` and `shrink_released_bytes`, `trim_result` -1, and `rss_after_discard` equal to
 * `rss_after`.
 */
struct GCReport {
    /**
     * Which explicit collection produced the report. `Minor` is `collectMinor`: one minor collection, which may
     * itself run majors (see `majors_run`). `Major` is `collectMajorAndRelease`: a major, the sweep, a forced shrink,
     * a discard of pending pages, and `malloc_trim` where glibc provides it.
     */
    enum class Kind : uint8_t { Minor, Major };
    Kind kind = Kind::Minor;

    // Elapsed nanoseconds on the steady clock: the whole call, the collection, the sweep run to completion, the forced
    // shrink, the discard of every pending extent, and `malloc_trim`.
    uint64_t total_ns = 0, gc_ns = 0, sweep_ns = 0, shrink_ns = 0, discard_ns = 0, trim_ns = 0;

    uint64_t old_in_use_before = 0, old_in_use_after = 0;    // In-use old-generation bytes.
    uint64_t old_pending_before = 0, old_pending_after = 0;  // Pending bytes; always 0 in mode 0.
    uint64_t old_high_water = 0;  // Old-generation bytes ever committed (`old_gen_committed`); never falls.
    uint64_t live_after_mark = 0; // Live bytes found by the last major's mark; 0 if no major ran in the call.
    uint64_t released_bytes = 0;  // Old-generation bytes released during the call.
    uint64_t shrink_released_bytes = 0;  // Drop in in-use bytes across the forced shrink.
    uint64_t discarded_bytes = 0;  // Bytes posted for discard (outside mode 0) or discarded (mode 0) in the call.
    uint64_t nursery_committed = 0;  // Committed bytes of both nursery regions, after the call.
    uint64_t rss_before = 0, rss_after_discard = 0, rss_after = 0;  // Resident set size; 0 means unavailable.
    int64_t trim_result = -1;      // Return value of `malloc_trim`; -1 means it was not run.
    uint64_t minor_count = 0;      // Minor collections so far, read after the call.
    uint64_t major_count = 0;      // Major marks completed so far (`OldGenSpace::majorEpoch`), read after the call.
    uint64_t majors_run = 0;       // Majors that ran during the call.
};

} // namespace Elm
