/**
 * GC Statistics Tracking.
 *
 * Provides comprehensive telemetry for garbage collection performance analysis.
 * All tracking compiles to zero overhead when ENABLE_GC_STATS is set to 0.
 *
 * Tracks:
 *   - Allocation counts and bytes.
 *   - Minor/major GC cycle counts and timing histograms.
 *   - Object survival and promotion rates.
 *   - AllocBuffer usage.
 */

#ifndef ECO_GC_STATS_H
#define ECO_GC_STATS_H

#include <chrono>
#include <cstdint>

#include "Heap.hpp"  // for Tag (per-kind allocation histogram).

// ============================================================================
// GC Statistics Configuration
// ============================================================================

// Global toggle: set to 1 to enable stats, 0 to disable (zero overhead).
// Controlled by the top-level CMake option ECO_GC_STATS (default ON for
// non-Release builds, OFF for Release). If neither the CMake build nor a
// hand-defined ENABLE_GC_STATS is present, default to OFF — safer for any
// out-of-tree consumer that doesn't drive the flag explicitly.
#ifndef ENABLE_GC_STATS
#define ENABLE_GC_STATS 0
#endif

namespace Elm {

// True only while the calling thread is inside NurserySpace::minorGC.
// Read by OldGenSpace::allocate to attribute its body wall-time to the
// GCStats::total_oldgen_alloc_in_minor_ns counter when the allocation
// comes from a promotion (rather than a direct mutator alloc).
// Always-on (not gated on ECO_GC_DEBUG) because the stats path needs it.
extern thread_local bool g_in_minor_gc;

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
    uint64_t bytes_freed = 0;             // Cumulative total across all GC cycles.

    // ========== Nursery Sizing ==========
    //
    // Cumulative count of successful NurserySpace::checkAndGrow events: each
    // increment reflects one post-minor-GC growth where to-space occupancy
    // exceeded `nursery_growth_threshold` and both semi-spaces were able to
    // acquire equal block counts from the allocator.
    uint64_t nursery_grow_events = 0;
    // Largest total committed nursery size observed in bytes (sum of
    // low_blocks_.size() + high_blocks_.size() times block_size_, sampled
    // by NurserySpace after initialize / successful grow / reset). Combined
    // across threads by max, so the printed value is the largest single
    // per-thread nursery rather than the sum across independent threads.
    uint64_t nursery_size_bytes = 0;

    // ========== Minor GC Timing Stats ==========
    uint64_t total_minor_gc_time_ns = 0;
    uint64_t min_minor_gc_time_ns = UINT64_MAX;
    uint64_t max_minor_gc_time_ns = 0;

    // Histogram with extended dynamic range:
    //   - 20 buckets of 5us each (0-100us range).
    //   - 18 buckets of 50us each (100us-1ms range).
    //   - 1 overflow bucket (>1ms).
    static constexpr int HISTOGRAM_BUCKETS = 39;
    static constexpr uint64_t MINOR_HISTOGRAM_FIRST_RANGE = 100000;   // 100us in nanoseconds.
    static constexpr uint64_t MINOR_HISTOGRAM_SECOND_RANGE = 1000000; // 1ms in nanoseconds.
    static constexpr uint64_t MINOR_BUCKET_SIZE_SMALL = 5000;         // 5us bucket width.
    static constexpr uint64_t MINOR_BUCKET_SIZE_LARGE = 50000;        // 50us bucket width.
    static constexpr int MINOR_BUCKETS_SMALL = 20;  // Buckets for 0-100us range.
    static constexpr int MINOR_BUCKETS_LARGE = 18;  // Buckets for 100us-1ms range.

    uint64_t minor_time_histogram[HISTOGRAM_BUCKETS] = {0};

    // ========== Allocation Size Histograms ==========
    //
    // Power-of-two buckets keyed off the allocation size in bytes. Bucket k
    // covers [8 << k, 8 << (k+1)); the final bucket is an overflow bucket for
    // sizes at or above the histogram's upper bound.
    //
    // Nursery histogram covers 8 B up to the large-object threshold (8 KiB):
    //   buckets 0..9  => [8,16) [16,32) ... [4096,8192)
    //   bucket 10     => >= 8 KiB (objects this large bypass the nursery).
    //
    // Old-gen histogram covers 8 B up to 1 MiB:
    //   buckets 0..16 => [8,16) [16,32) ... [524288,1048576)
    //   bucket 17     => >= 1 MiB.
    //
    // The [16,32) bucket (index 1) is the only one we split for display: a
    // parallel `_16_24_count` tallies allocations in [16,24) so the printer
    // can show [16,24) and [24,32) on separate rows. This pulls apart boxed
    // primitives (Int/Float/Char @ ~24B) from small constructors (Tuple2,
    // Cons, small custom types @ ~32B). The full bucket value remains the
    // sum [16,32); the sub-counter is a strict subset of bucket[1].
    static constexpr int NURSERY_ALLOC_BUCKETS = 11;
    static constexpr int OLDGEN_ALLOC_BUCKETS  = 18;
    static constexpr size_t ALLOC_HISTOGRAM_BASE = 8;  // bucket 0 starts here.

    uint64_t nursery_alloc_size_histogram[NURSERY_ALLOC_BUCKETS] = {0};
    uint64_t oldgen_alloc_size_histogram[OLDGEN_ALLOC_BUCKETS]   = {0};

    // Sub-counters for the [16,24) lower half of bucket 1 (whose full range
    // is [16,32)). Always <= bucket[1]; the upper half [24,32) is derived as
    // bucket[1] - this counter at print time.
    uint64_t nursery_alloc_size_16_24_count = 0;
    uint64_t oldgen_alloc_size_16_24_count  = 0;

    // ========== String Allocation Size Histogram ==========
    //
    // Same power-of-two bucket layout as oldgen_alloc_size_histogram (covers
    // 8 B through 1 MiB+ in 18 buckets) so the same printer helper can render
    // it. Populated only from HeapHelpers::allocString(const u16*, size_t) —
    // i.e. every fresh-leaf String allocation, regardless of whether it ends
    // up on the inline-leaf path or the split-header (large) path. The byte
    // count recorded is the heap-object size (header + chars[], 8B-aligned)
    // before any large-object dispatch, so the histogram is directly
    // comparable to the size buckets in the nursery / oldgen histograms.
    //
    // Not split at bucket 1: the [16,24) vs [24,32) distinction is only
    // useful for boxed primitives vs small constructors; for strings, both
    // halves are just "tiny String".
    static constexpr int STRING_ALLOC_BUCKETS = 18;
    uint64_t string_alloc_size_histogram[STRING_ALLOC_BUCKETS] = {0};

    // ========== UTF-8 -> UTF-16 Widen Events ==========
    //
    // A UTF-8 (all-ASCII) String form (Tag_StringUtf8View / Tag_StringUtf8Leaf)
    // widened back to UTF-16 — either into a fresh Tag_String leaf
    // (maybeFlattenOrRebalance's UTF-8 arm, the ensureFlat backstop) or into a
    // transient std::u16string (toStdU16String's UTF-8 arm, the snapshot path
    // feeding foldl/split/lines/... fallbacks). Counted at those two
    // chokepoints only; the forEachSegment 512-unit chunk-widen is a known,
    // accepted blind spot. Near zero during a UTF-8-clean parse/self-compile;
    // a large residual names a conservative-widening consumer that still decays
    // UTF-8 -> UTF-16. See plans/utf8-string-pipeline-wiring.md (W0/W5).
    uint64_t utf8_widen_calls = 0;
    uint64_t utf8_widen_units = 0;

    // Per-site attribution for the widen counter above. Sites TRIM..B64HEX are
    // the exhaustive set of toStdU16String callers that can receive a UTF-8
    // form (their sum should equal utf8_widen_calls; a residual means a new
    // caller appeared). ROPE_CHILD and SEGMENT_CHUNK are the two known blind
    // spots NOT included in utf8_widen_calls: UTF-8 children widened inside
    // toStdU16String's rope DFS, and the forEachSegment wrapper's chunked
    // widen of UTF-8 segments. See plans/utf8-string-pipeline-wiring.md (W7).
    static constexpr int UTF8_WIDEN_SITE_COUNT = 9;
    uint64_t utf8_widen_site_calls[UTF8_WIDEN_SITE_COUNT] = {0};
    uint64_t utf8_widen_site_units[UTF8_WIDEN_SITE_COUNT] = {0};

    // ========== Per-Kind Mutator Allocation Histogram ==========
    //
    // Counts ThreadLocalHeap-level mutator allocations grouped by Tag,
    // populated from initHeaderForTag (the single chokepoint that runs on
    // every successful mutator allocation with both size and tag in scope).
    //
    // Excludes:
    //   - GC promotion paths (NurserySpace::evacuate memcpys the source
    //     header instead of calling initHeaderForTag).
    //   - Region carve-outs from allocateRegionSlow (caller installs
    //     per-sub-object headers afterward; no single kind to attribute).
    //   - Large body allocations from allocateLargeBody (payload buffers,
    //     not logical objects).
    //
    // Indexed by Tag enum value; the array is sized for the full enum so
    // an out-of-range cast (defensive) cannot overflow.
    static constexpr int NUM_ALLOC_TAGS = static_cast<int>(Tag_Forward) + 1;

    uint64_t tlh_alloc_count_by_tag[NUM_ALLOC_TAGS] = {0};
    uint64_t tlh_alloc_bytes_by_tag[NUM_ALLOC_TAGS] = {0};

    // ========== Per-Kind Retention Histograms (LH1) ==========
    //
    // plans/live-heap-composition-census.md LH1. The promotion/survival
    // analogue of the allocation histogram above: which KINDS of object
    // survive a minor GC, and which get promoted into old gen.
    //
    // Motivation (plan §0): a copying nursery charges for SURVIVORS, not
    // for allocation volume, and three separate tracks have now measured
    // wall following retention while allocation moved the other way (K6:
    // +0.02% objects allocated, -7.04% promotion, -5.07% wall). Allocation
    // counts alone cannot rank an optimization.
    //
    // IMPORTANT — these counters do NOT share the allocation counters'
    // blind spot. tlh_alloc_*_by_tag is fed from initHeaderForTag, which
    // the HEAP_034 inline-allocation fast path bypasses (~6-10x undercount
    // unless lowered with ECO_INLINE_ALLOC=0). Promotion and survival are
    // counted inside the COLLECTOR, which no mutator fast path can skip,
    // so these figures are exact in the standard binary.
    //
    // Consequence: any ratio taken against tlh_alloc_*_by_tag (the
    // "surv/alloc" column in the dump) is only meaningful on a
    // census-lowered binary. The absolute counts always are.
    uint64_t promoted_count_by_tag[NUM_ALLOC_TAGS] = {0};
    uint64_t promoted_bytes_by_tag[NUM_ALLOC_TAGS] = {0};
    uint64_t survived_count_by_tag[NUM_ALLOC_TAGS] = {0};
    uint64_t survived_bytes_by_tag[NUM_ALLOC_TAGS] = {0};

    // ========== Custom Arity Breakdown (W1) ==========
    //
    // plans/sum-type-wrapper-unboxing.md W1. LH1 established that Tag_Custom
    // is ~61% of everything promoted; this splits that pool by FIELD COUNT
    // (Custom's Header.size is exactly the field count — AllocatorCommon.hpp
    // sizes it as sizeof(Custom) + size * sizeof(Unboxable)).
    //
    // Why field count is the right gate: the plan targets multi-constructor
    // unions whose constructors each carry ONE field. A promoted 1-field
    // Custom is a necessary condition for that shape, so the nfields==1
    // share is an exact UPPER BOUND on the addressable population. If it is
    // small the plan closes without the static census; only if it is large
    // does the expensive shape classification need to run.
    //
    // Note single-ctor single-field unions cannot appear here at all: they
    // are already Can.Unbox (Local.elm toOpts) and never allocate a Custom.
    static constexpr int CUSTOM_ARITY_BUCKETS = 17;  // 0..15 fields, [16] = 16+

    uint64_t custom_promoted_by_nfields[CUSTOM_ARITY_BUCKETS] = {0};
    uint64_t custom_promoted_bytes_by_nfields[CUSTOM_ARITY_BUCKETS] = {0};
    uint64_t custom_survived_by_nfields[CUSTOM_ARITY_BUCKETS] = {0};

    // ========== Old-Gen Page Residency Histogram ==========
    //
    // Snapshot taken once per major after finalizeMetaAfterMark and before
    // transitionToSweeping clears free_lists_. Each surviving old-gen block
    // is bucketed by live_bytes / totalBytes, and within the bucket we
    // accumulate a four-way byte breakdown:
    //
    //   live    — bytes the mark phase reached (mark-derived live_bytes)
    //   free    — bytes already parked on per-class free lists from the
    //             previous major's lazy sweep (allocatable, "good" non-live)
    //   garbage — dead bytes the previous lazy sweep never reached (still
    //             unswept; the new major must walk these again)
    //   (implicit) unallocated tail = total - live - free - garbage
    //
    // The free vs garbage split is the diagnostic question:
    //   - free dominates → fragmentation (unused space is allocatable but
    //     in the wrong size class for current demand)
    //   - garbage dominates → the lazy sweep is falling behind (we cannot
    //     even reclaim the dead bytes fast enough to put them on free lists)
    //
    // Counts accumulate across all majors for the lifetime of this GCStats.
    // Buckets are non-overlapping. The first matches live_bytes == 0
    // exactly (block fully empty); the rest are upper-inclusive ranges:
    //   0 : live_frac == 0           (fully empty after mark)
    //   1 : (0.00, 0.01]
    //   2 : (0.01, 0.05]
    //   3 : (0.05, 0.10]
    //   4 : (0.10, 0.25]
    //   5 : (0.25, 0.50]
    //   6 : (0.50, 0.75]
    //   7 : (0.75, 1.00]
    static constexpr int RESIDENCY_BUCKETS = 8;

    uint64_t residency_pages[RESIDENCY_BUCKETS]         = {0};
    uint64_t residency_page_bytes[RESIDENCY_BUCKETS]    = {0};
    uint64_t residency_live_bytes[RESIDENCY_BUCKETS]    = {0};
    uint64_t residency_garbage_bytes[RESIDENCY_BUCKETS] = {0};
    uint64_t residency_free_bytes[RESIDENCY_BUCKETS]    = {0};

    // Pinned (is_large) blocks are also recorded into the buckets above,
    // but additionally tracked here so the printer can highlight how much
    // of the residency is structurally locked (large blocks cannot be
    // released by sweep until their single object dies).
    uint64_t residency_pinned_pages         = 0;
    uint64_t residency_pinned_page_bytes    = 0;
    uint64_t residency_pinned_live_bytes    = 0;
    uint64_t residency_pinned_garbage_bytes = 0;
    uint64_t residency_pinned_free_bytes    = 0;

    // Number of major-GC end snapshots that contributed to the histogram.
    // Equal to the count of recordResidencySnapshot() calls. Used by the
    // printer to derive "average pages per major" alongside the totals.
    uint64_t residency_snapshots = 0;

    // ---- Latest-only snapshot (most recent COMPLETED major-GC end) ----
    //
    // Holds the most recent fully-recorded snapshot. Per-record events
    // accumulate into the `pending_*` mirrors; on
    // recordResidencySnapshot() we atomically swap pending_* into
    // latest_* and reset pending_* to zero. This guarantees that if
    // SIGTERM lands mid-snapshot (after beginResidencySnapshot() but
    // before recordResidencySnapshot()), the printer still sees the
    // PRIOR completed snapshot rather than an empty / partially-filled
    // mirror — important for crash forensics where the last completed
    // major's heap shape pins down what the runtime was doing.
    uint64_t latest_residency_pages[RESIDENCY_BUCKETS]         = {0};
    uint64_t latest_residency_page_bytes[RESIDENCY_BUCKETS]    = {0};
    uint64_t latest_residency_live_bytes[RESIDENCY_BUCKETS]    = {0};
    uint64_t latest_residency_garbage_bytes[RESIDENCY_BUCKETS] = {0};
    uint64_t latest_residency_free_bytes[RESIDENCY_BUCKETS]    = {0};
    uint64_t latest_residency_pinned_pages         = 0;
    uint64_t latest_residency_pinned_page_bytes    = 0;
    uint64_t latest_residency_pinned_live_bytes    = 0;
    uint64_t latest_residency_pinned_garbage_bytes = 0;
    uint64_t latest_residency_pinned_free_bytes    = 0;
    uint64_t latest_residency_snapshots            = 0;

    // ---- Staging buffer for the in-progress residency snapshot ----
    //
    // beginResidencySnapshot() zeroes these (NOT latest_*). Per-block
    // recordBlockResidency() calls accumulate here. recordResidencySnapshot()
    // copies pending_* into latest_*, then zeroes pending_*.
    uint64_t pending_residency_pages[RESIDENCY_BUCKETS]         = {0};
    uint64_t pending_residency_page_bytes[RESIDENCY_BUCKETS]    = {0};
    uint64_t pending_residency_live_bytes[RESIDENCY_BUCKETS]    = {0};
    uint64_t pending_residency_garbage_bytes[RESIDENCY_BUCKETS] = {0};
    uint64_t pending_residency_free_bytes[RESIDENCY_BUCKETS]    = {0};
    uint64_t pending_residency_pinned_pages         = 0;
    uint64_t pending_residency_pinned_page_bytes    = 0;
    uint64_t pending_residency_pinned_live_bytes    = 0;
    uint64_t pending_residency_pinned_garbage_bytes = 0;
    uint64_t pending_residency_pinned_free_bytes    = 0;

    // ========== Free-List Size-Class Histogram ==========
    //
    // Snapshot of the per-class free-list contents at every major-GC end
    // (sampled at the same instant as the residency histogram, just before
    // transitionToSweeping clears the free lists). Counts accumulate across
    // every major for the lifetime of this GCStats.
    //
    // FREELIST_CLASS_BUCKETS must equal OldGenSpace::NUM_SIZE_CLASSES. We
    // do not include OldGenSpace.hpp here to avoid a header cycle; a
    // static_assert in OldGenSpace.cpp keeps the two values in sync.
    //
    // The histogram shows whether unused old-gen bytes are concentrated in
    // small cells (8B..256B; chronic small-object churn left the heap full
    // of slivers too small to satisfy larger requests) or in medium/large
    // cells (allocatable but the program isn't asking for sizes that fit).
    static constexpr int FREELIST_CLASS_BUCKETS = 40;  // 32 small + 8 medium
    uint64_t freelist_cells_by_class[FREELIST_CLASS_BUCKETS] = {0};
    uint64_t freelist_bytes_by_class[FREELIST_CLASS_BUCKETS] = {0};
    // Bytes parked in `free_large_blocks_` (whole-block free entries that
    // bypass the size-class lists). Recorded as one aggregate counter
    // because they don't have a size class.
    uint64_t freelist_large_block_bytes  = 0;
    uint64_t freelist_large_block_count  = 0;
    uint64_t freelist_snapshots          = 0;

    // ---- Latest-only snapshot (most recent COMPLETED major-GC end) ----
    //
    // Holds the most recent fully-recorded snapshot. See the
    // residency latest/pending comment above for the rationale —
    // mid-snapshot SIGTERM keeps the previous completed mirror visible.
    uint64_t latest_freelist_cells_by_class[FREELIST_CLASS_BUCKETS] = {0};
    uint64_t latest_freelist_bytes_by_class[FREELIST_CLASS_BUCKETS] = {0};
    uint64_t latest_freelist_large_block_bytes  = 0;
    uint64_t latest_freelist_large_block_count  = 0;
    uint64_t latest_freelist_snapshots          = 0;

    // ---- Staging buffer for the in-progress free-list snapshot ----
    uint64_t pending_freelist_cells_by_class[FREELIST_CLASS_BUCKETS] = {0};
    uint64_t pending_freelist_bytes_by_class[FREELIST_CLASS_BUCKETS] = {0};
    uint64_t pending_freelist_large_block_bytes  = 0;
    uint64_t pending_freelist_large_block_count  = 0;

    // ========== AllocBuffer Stats ==========
    uint64_t buffers_allocated = 0;
    uint64_t buffers_filled = 0;

    // ========== Major GC Event Stats ==========
    uint64_t concurrent_marks_started = 0;
    uint64_t mark_sweeps_completed = 0;
    uint64_t incremental_mark_calls = 0;
    uint64_t total_incremental_mark_work_units = 0;

    // Distinguishes *why* a major GC ran: the 75% occupancy-initiating
    // trigger (soft, scheduled at a safepoint), an allocation hitting the
    // old-gen cap (hard, inline in the alloc slow path), or the
    // garbage-fraction trigger (soft, fires on long-running compiles whose
    // live working set sits well below committed).
    uint64_t major_gc_occupancy_triggers     = 0;
    uint64_t major_gc_alloc_failure_triggers = 0;
    uint64_t major_gc_garbage_triggers       = 0;
    // Global-pressure trigger: reported separately from the per-thread
    // occupancy trigger so a heap that's small per-thread but big globally
    // doesn't masquerade as either of the simpler reasons.
    uint64_t major_gc_global_pressure_triggers = 0;

    // ========== Old-gen allocator-helper attribution ==========
    //
    // The body of OldGenSpace::allocate is wholly allocator/GC work — even
    // when gc_phase_ == Idle the dispatch tail can walk free lists, split
    // larger cells, pull a fresh BBoP page, or — via lazySweep →
    // onSweepComplete — drive a maybeShrinkCapacity → releaseBlockToAllocator
    // cascade. None of that is mutator user code. These counters bracket
    // the whole function unconditionally and split by calling context:
    //
    //   total_oldgen_alloc_in_minor_ns
    //     Time accumulated while the calling thread is mid-minorGC
    //     (g_in_minor_gc == true), i.e. via promotion → oldgen.allocate.
    //     NurserySpace::minorGC subtracts this per-cycle from elapsed_ns
    //     before recording, so the minor histogram/min/max/avg reflect
    //     pure nursery-copy time.
    //
    //   total_oldgen_alloc_in_mutator_ns
    //     Time accumulated when the mutator (not a minor GC) is calling
    //     oldgen.allocate (large-pinned, permanent, large region). Without
    //     this counter, this allocator time was silently included in
    //     mutator_s; with it, the printout / parser can split it out.
    //
    // Sub-counters (nested inside the above; subtract when summing buckets
    // to avoid double counting):
    //   total_post_sweep_shrink_ns
    //     Time spent inside onSweepComplete (light-pass shrink) when fired
    //     from inside lazySweep on the allocation hot path. Captures the
    //     post-sweep page-release cascade explicitly.
    //   total_maybe_shrink_heavy_ns / total_maybe_shrink_light_ns
    //     Time spent inside maybeShrinkCapacity, split by pass kind. The
    //     heavy-pass case nests inside major_s (called from
    //     adjustCapacityAfterMajorGC); the light-pass case nests inside
    //     total_oldgen_alloc_in_mutator_ns or total_post_sweep_shrink_ns.
    //
    // Identity (after subtracting nested counters):
    //   wall_s = minor + major + nursery_alloc_in_mutator
    //          + oldgen_alloc_in_mutator + true_mutator
    uint64_t total_oldgen_alloc_in_minor_ns   = 0;
    uint64_t total_oldgen_alloc_in_mutator_ns = 0;
    uint64_t total_post_sweep_shrink_ns       = 0;
    uint64_t total_maybe_shrink_heavy_ns      = 0;
    uint64_t total_maybe_shrink_light_ns      = 0;

    // ========== Nursery-side allocator attribution ==========
    //
    // Mirrors the old-gen counter for the nursery fast/slow paths
    // (NurserySpace::allocate). Captures bump-pointer + block-rotation
    // overhead as allocator time rather than letting it leak into mutator_s.
    uint64_t total_nursery_alloc_in_mutator_ns = 0;

    // Total wall time of the runtime instance, stamped by the caller
    // (Allocator::getCombinedStats) just before print(). Zero means the
    // caller did not stamp it and the Allocator Timings block will fall
    // back to printing only the bracket totals (no True mutator line).
    uint64_t wall_time_ns = 0;

    // ========== Adaptive Lazy-Sweep Pacing (bytes) ==========
    //
    // Cumulative bytes the dynamic lazy-sweep pacer asked the sweeper to
    // do on the mutator allocation slow path. Counts requested slice bytes
    // (not actual swept bytes — see "requested slice == accounted bytes"
    // in OldGenSpace::sweepOnDemandAllocate). Survives without
    // ECO_GC_PHASE_PROFILE; merged via existing Allocator::getCombinedStats.
    uint64_t total_lazy_sweep_bytes_in_mutator = 0;
    // Cumulative bytes asked of the sweeper from
    // OldGenSpace::panicSweepAndRetryAllocation, i.e. the slow path that
    // fires only when bag-page acquisition has failed and growth is
    // impossible. A non-zero value here means the heap was at the cap and
    // the panic path successfully (or unsuccessfully) tried to recover by
    // finishing the sweep.
    uint64_t total_panic_sweep_bytes = 0;

    // ========== Split-Header Large-Body Minor-Reclaim Stats ==========
    //
    // sweepNurseryLargeBodies runs at the end of each minor GC to free
    // bodies of Tag_LargeStringHeader / Tag_LargeByteHeader headers that
    // did not survive the minor cycle. The sweep early-returns ONLY while
    // compaction is in flight — during major-GC mark/sweep it runs as
    // normal, with freeLargeBodyCell installing the on-free-list sentinel
    // (Header.age & 0b01 = 1) on the resulting Tag_Free cells so the
    // in-progress lazy sweep treats them as hard run boundaries instead of
    // coalescing across them.
    //
    // - large_body_minor_sweep_runs: number of times the sweep actually
    //   ran (took the full pass).
    // - large_body_minor_sweep_skips: number of times it early-returned
    //   because compaction was in flight.
    // - large_body_minor_freed_bytes: total cell bytes freed straight back
    //   to free lists / free_large_blocks_ via the minor-GC fast path.
    // - large_body_deferred_to_major_bytes: total cell bytes that *would*
    //   have been freed by the minor-GC fast path but were left on
    //   nursery_owned_bodies_ because compaction blocked the sweep. The
    //   bytes are drained on the next minor that fires once compaction
    //   completes. (Field name retained for stat-printer compatibility;
    //   it now means "deferred until compaction completes".)
    uint64_t large_body_minor_sweep_runs        = 0;
    uint64_t large_body_minor_sweep_skips       = 0;
    uint64_t large_body_minor_freed_bytes       = 0;
    uint64_t large_body_deferred_to_major_bytes = 0;

    // ========== Major GC Timing Stats ==========
    uint64_t major_gc_count = 0;
    uint64_t total_major_gc_time_ns = 0;
    uint64_t min_major_gc_time_ns = UINT64_MAX;
    uint64_t max_major_gc_time_ns = 0;

    // Major GC histogram using same bucket configuration as minor GC.
    uint64_t major_time_histogram[HISTOGRAM_BUCKETS] = {0};

    // ========== Methods ==========

    // Records a nursery allocation event (count, bytes, size histogram).
    void recordAllocation(size_t bytes);

    // Records an old-generation allocation event into the size histogram.
    // Called for EVERY old-gen allocation regardless of source (mutator
    // direct, promotion during minor GC, evacuation during compaction);
    // distinguishing them on this hot path would cost a branch per alloc.
    // Bytes/object totals are NOT incremented here — those are only updated
    // for mutator-initiated allocations via recordOldGenDirectAllocation.
    void recordOldGenAllocation(size_t bytes);

    // Records a mutator-initiated direct old-gen allocation (large objects,
    // permanent strings, large regions). Increments the cross-generation
    // bytes_allocated/objects_allocated totals so MBps-style metrics
    // include allocations that bypass the nursery. The size histogram is
    // already bumped by recordOldGenAllocation inside OldGenSpace::allocate,
    // so this method does NOT touch the histogram (avoids double-counting).
    void recordOldGenDirectAllocation(size_t bytes);

    // Records a typed mutator allocation through the ThreadLocalHeap path,
    // bumping the per-tag count and byte totals. Driven from
    // initHeaderForTag, the single chokepoint that sees every successful
    // mutator allocation with its tag. Out-of-range tags (defensive) are
    // dropped silently.
    void recordTLHAllocation(size_t bytes, Tag tag);

    // LH1: one promoted / surviving object of `tag` occupying `bytes`.
    // Each also bumps the matching scalar (objects_promoted /
    // objects_survived) so the totals cannot drift from the histograms.
    // `nfields` is Header::size, meaningful only for Tag_Custom (W1); other
    // tags pass it harmlessly and it is ignored.
    void recordPromotion(Tag tag, size_t bytes, uint32_t nfields);
    void recordSurvival(Tag tag, size_t bytes, uint32_t nfields);

    // Records a single String allocation by heap-object byte size into the
    // String size-distribution histogram. Called from the allocString
    // helper before its large/inline-leaf dispatch, so each call lands in
    // exactly one histogram bucket regardless of which storage path is
    // taken.
    void recordStringAllocation(size_t bytes);

    // Records a single UTF-8 -> UTF-16 widen event of `units` code units.
    void recordUtf8Widen(size_t units);

    // Records a widen event attributed to a specific call site (see the
    // Utf8WidenSite enum at namespace scope).
    void recordUtf8WidenSite(int site, size_t units);

    // Records completion of a minor GC cycle with timing and reclaimed bytes.
    void recordMinorGCEnd(uint64_t elapsed_ns, size_t freed);

    // Records completion of a major GC cycle with timing.
    void recordMajorGCEnd(uint64_t elapsed_ns);

    // Adds one block's contribution to the residency histogram. Called
    // once per surviving old-gen block at major-GC end (sampled BEFORE
    // transitionToSweeping clears free lists, so `free_bytes` carries
    // the previous-major free-list residual for this block).
    //   total_bytes — block's full committed size (includes any tail).
    //   live_bytes  — mark-derived live size for this block.
    //   free_bytes  — bytes inside this block that are linked into a
    //                 per-class free list or `free_large_blocks_`.
    //   is_large    — flags pinned large-object blocks.
    // garbage_bytes is derived as max(0, total - live - free), i.e.
    // dead bytes that the previous lazy sweep didn't get to.
    void recordBlockResidency(size_t total_bytes,
                              size_t live_bytes,
                              size_t free_bytes,
                              bool   is_large);

    // Clears the latest_residency_* arrays so the next round of
    // recordBlockResidency() calls populates a fresh "most recent major"
    // snapshot. Call once per major-GC end BEFORE the per-block
    // recordBlockResidency() calls. Cumulative arrays are left untouched.
    void beginResidencySnapshot();

    // Increments residency_snapshots and sets latest_residency_snapshots
    // to 1; call once per major-GC end after every block has been
    // recorded.
    void recordResidencySnapshot();

    // Records the contents of one per-class free list into the size-class
    // histogram. `cell_count` and `cell_bytes` are the totals across the
    // sampled list at major-GC end. Call once per non-empty class per
    // snapshot (empty classes can be skipped with no effect).
    void recordFreeListClass(size_t size_class,
                             uint64_t cell_count,
                             uint64_t cell_bytes);

    // Records aggregate `free_large_blocks_` contribution at major-GC end.
    // These are whole-block free entries that bypass the size-class lists.
    void recordFreeListLargeBlocks(uint64_t block_count,
                                   uint64_t total_bytes);

    // Clears the latest_freelist_* arrays so the next round of
    // recordFreeListClass / recordFreeListLargeBlocks calls populates a
    // fresh "most recent major" snapshot. Call once per major-GC end
    // BEFORE the per-class recordFreeListClass calls.
    void beginFreeListSnapshot();

    // Increments freelist_snapshots and sets latest_freelist_snapshots
    // to 1; call once per major-GC end after every per-class entry has
    // been recorded.
    void recordFreeListSnapshot();

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
// Per-Thread Stats Lookup Helper
// ============================================================================
//
// The TLH per-kind histogram is recorded from `initHeaderForTag`, a free
// function that doesn't have a `GCStats&` in scope. Rather than thread one
// through (and force every call site to pay for it), we route through this
// helper. Definition lives in GCStats.cpp where Allocator.hpp can be
// included without creating a header cycle (Allocator.hpp transitively
// pulls in GCStats.hpp via NurserySpace/OldGenSpace).
//
// Declared unconditionally so the symbol exists either way; the helper is
// only ever called from the stats-on branch of GC_STATS_TLH_RECORD_ALLOC,
// so when ENABLE_GC_STATS=0 it is unused and compiles away.
void recordTLHAllocOnCurrentThread(size_t bytes, Tag tag) noexcept;

// Per-thread routing helper for the String-allocation histogram. allocString
// (in HeapHelpers.hpp) cannot reach a GCStats& directly without dragging in
// Allocator.hpp, so this trampoline lives in GCStats.cpp where the lookup is
// already available. Declared unconditionally; the body is only ever invoked
// from the stats-on branch of GC_STATS_STRING_RECORD_ALLOC.
void recordStringAllocOnCurrentThread(size_t bytes) noexcept;

// Per-thread routing helper for the UTF-8 widen counter. Same shape as the
// String-histogram trampoline: the widen sites (StringOps) have no GCStats&
// in scope, so route through the current thread's heap here.
void recordUtf8WidenOnCurrentThread(size_t units) noexcept;

// Which String operation widened a UTF-8 form. TRIM..B64HEX cover every
// toStdU16String caller that can receive a UTF-8 input; ROPE_CHILD and
// SEGMENT_CHUNK are blind spots outside utf8_widen_calls (see the field docs).
enum Utf8WidenSite : int {
    UTF8_WIDEN_TRIM = 0,       // trim / trimLeft / trimRight scan
    UTF8_WIDEN_TO_LIST,        // String.toList
    UTF8_WIDEN_INDEXES,        // String.indexes (needle and haystack each)
    UTF8_WIDEN_SPLIT_MIXED,    // String.split with mixed encodings
    UTF8_WIDEN_APPEND_MIXED,   // (++) with mixed encodings (UTF-8 side only)
    UTF8_WIDEN_ENSURE_FLAT,    // ensureFlat/flattenToLeaf backstop
    UTF8_WIDEN_B64HEX,         // BytesOps fromBase64 / fromHex
    UTF8_WIDEN_ROPE_CHILD,     // [blind spot] UTF-8 child in rope DFS widen
    UTF8_WIDEN_SEGMENT_CHUNK,  // [blind spot] forEachSegment chunked widen
};

// Per-thread routing helper for the per-site widen attribution.
void recordUtf8WidenSiteOnCurrentThread(int site, size_t units) noexcept;

// ============================================================================
// Zero-Overhead Macros
// ============================================================================

#if ENABLE_GC_STATS
    // ========== Minor GC Macros ==========

    #define GC_STATS_MINOR_RECORD_ALLOC(stats, bytes) \
        do { (stats).recordAllocation(bytes); } while(0)

    #define GC_STATS_OLDGEN_RECORD_ALLOC(stats, bytes) \
        do { (stats).recordOldGenAllocation(bytes); } while(0)

    #define GC_STATS_OLDGEN_DIRECT_RECORD_ALLOC(stats, bytes) \
        do { (stats).recordOldGenDirectAllocation(bytes); } while(0)

    // Per-kind ThreadLocalHeap allocation hook. Called from initHeaderForTag,
    // which has both size and tag in scope but no GCStats reference; the
    // helper does the thread-local lookup. Disabled-build expands to nothing
    // so allocateFast keeps its `(size_t)` signature with no extra arg.
    #define GC_STATS_TLH_RECORD_ALLOC(bytes, tag) \
        do { ::Elm::recordTLHAllocOnCurrentThread((bytes), (tag)); } while(0)

    // Per-allocString hook: records the heap-object size of a fresh String
    // leaf into the current thread's String size histogram.
    #define GC_STATS_STRING_RECORD_ALLOC(bytes) \
        do { ::Elm::recordStringAllocOnCurrentThread((bytes)); } while(0)

    // Per-widen hook: a UTF-8 form was widened to UTF-16 (`units` code units).
    #define GC_STATS_UTF8_WIDEN(units) \
        do { ::Elm::recordUtf8WidenOnCurrentThread((units)); } while(0)

    // Site-attributed widen hook (see Utf8WidenSite).
    #define GC_STATS_UTF8_WIDEN_SITE(site, units) \
        do { ::Elm::recordUtf8WidenSiteOnCurrentThread((site), (units)); } while(0)

    #define GC_STATS_MINOR_RECORD_GC_END(stats, elapsed_ns, freed) \
        do { (stats).recordMinorGCEnd(elapsed_ns, freed); } while(0)

    // LH1: survival/promotion are recorded WITH their tag and size, so the
    // per-kind retention histograms cannot go stale relative to the
    // scalars. Every caller sits in the collector and has both in scope.
    // `tag` is read from Header::tag, a u32 bitfield, so the cast lives
    // here rather than at each of the six collector call sites. `nfields`
    // is Header::size (W1: the Custom arity split).
    #define GC_STATS_MINOR_INC_SURVIVORS(stats, tag, bytes, nfields) \
        do { (stats).recordSurvival(static_cast<Tag>(tag), (bytes), (nfields)); } while(0)

    #define GC_STATS_MINOR_INC_PROMOTED(stats, tag, bytes, nfields) \
        do { (stats).recordPromotion(static_cast<Tag>(tag), (bytes), (nfields)); } while(0)

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
    #define GC_STATS_OLDGEN_RECORD_ALLOC(stats, bytes) do {} while(0)
    #define GC_STATS_OLDGEN_DIRECT_RECORD_ALLOC(stats, bytes) do {} while(0)
    #define GC_STATS_TLH_RECORD_ALLOC(bytes, tag) do {} while(0)
    #define GC_STATS_STRING_RECORD_ALLOC(bytes) do {} while(0)
    #define GC_STATS_UTF8_WIDEN(units) do {} while(0)
    #define GC_STATS_UTF8_WIDEN_SITE(site, units) do {} while(0)
    #define GC_STATS_MINOR_RECORD_GC_END(stats, elapsed_ns, freed) do {} while(0)
    #define GC_STATS_MINOR_INC_SURVIVORS(stats, tag, bytes, nfields) do {} while(0)
    #define GC_STATS_MINOR_INC_PROMOTED(stats, tag, bytes, nfields) do {} while(0)
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
