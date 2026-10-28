// GC telemetry: the counters, histograms, timings and logs that show what the collector did during
// a run, kept so that they never change what it does.
//
// The central type is `GCStats`, a plain record of numbers with public members. The collector keeps
// several per heap (its `NurserySpace`, its `OldGenSpace` and its `ThreadLocalHeap` each hold one by
// value). Nothing in a `GCStats` is synchronised: it is plain integers and vectors, so only one thread
// may write a given record at a time. Work spread over several threads counts into private records
// (`GCStats::MinorCopyCounts`, a worker's copy of the old-gen size histogram) that are merged into
// the owner's record afterwards. For a report, records are merged with `GCStats::combine` and the
// result is written to standard output by `GCStats::print`, the stats banner.
//
// Four facts shape the rest of the file.
//
// Instruments must never feed a GC decision (invariant GC_DET_001). A collection trigger, a promotion
// or a sizing choice must come out the same whether or not these counters exist, so no collector code
// may read a member of a `GCStats` to decide anything. Nothing here enforces that; it holds only as
// long as every reader is a report.
//
// Statistics are a compile-time choice. `ENABLE_GC_STATS` (0 when the build does not define it) turns
// the `GC_STATS_*` macros at the bottom of this file into calls or into nothing, and the collector
// guards its own stats code with the same switch. `ENABLE_GC_PHASE_TIMERS`, which requires
// `ENABLE_GC_STATS`, gates the collector's per-minor phase timings and pause log; in this component it
// gates only the banner blocks that print them, and the types are compiled either way.
//
// Members merge in one of three ways, and each sub-record's comment says which. Counts and totals
// add. Maxima and peaks take the larger. A few members describe the allocator as a whole rather than
// one heap (the old-gen walls, `page_supply`, `helper`). They merge by maximum (`helper` instead
// takes the first snapshot with a non-zero mode), and the code that builds a combined record is
// expected to fill them in itself.
//
// Times called "process-relative" are nanoseconds on the steady clock since the static
// initialisation of GCStats.cpp, the origin of `GCStats::nowSinceProcessStartNs`. That is close to,
// but not the same as, the start of the process.
//
// Most of this header is sub-records, one per collector feature (bitmap allocation, young large
// objects, parallel minor, region nursery, incremental, parallel and concurrent marking, page supply,
// helper threads), each with its own `combine` or `merge` and its own banner block. Two
// whole-run views need more vocabulary:
//
// - A *pause* is one contiguous stop of the mutator for collection work, including a minor that
//   runs a major inside it. `GCPhaseTotals` keeps a log of pauses, their distribution, and the
//   *minimum mutator utilisation* (MMU): for a window length w, the smallest fraction of any window
//   of length w in the run that was not spent paused.
// - The old-gen residency and free-list histograms are *snapshots* taken at the end of each major.
//   Each has cumulative arrays (every snapshot added up), *pending* arrays (the snapshot being
//   recorded) and *latest* arrays (the last snapshot completed). A begin call clears pending, each
//   record call adds to cumulative and pending, and the closing call copies pending into latest. A
//   print that runs between begin and close, such as one from a signal handler, therefore sees the
//   previous completed snapshot rather than a partial one.
//
// Separately from the banner, `ECO_GC_EVENT_LOG=<path>` makes the `gcEventLog*` functions write one
// tab-separated row per minor, major, pause, mark cycle, helper stall and helper job.

#ifndef ECO_GC_STATS_H
#define ECO_GC_STATS_H

#include <chrono>
#include <cstdint>
#include <vector>

#include "Heap.hpp"  // for Tag (per-kind allocation histogram).

// ============================================================================
// GC Statistics Configuration
// ============================================================================

// Whether GC statistics are compiled in: 1 for on, 0 for off. The build sets it from the CMake
// option `ECO_GC_STATS`; a translation unit compiled without a definition gets 0.
#ifndef ENABLE_GC_STATS
#define ENABLE_GC_STATS 0
#endif

namespace Elm {

// ============================================================================
// Minor-GC phase breakdown and pause accounting
// ============================================================================

// Whether the per-minor phase timers and the pause log are compiled in: 1 for on, 0 (the default)
// for off. The build sets it from the CMake option `ECO_GC_PHASE_TIMERS`, which is off by default
// because the timers cost measurable collection time. It requires `ENABLE_GC_STATS`, and the check
// below stops the build otherwise. The types and print helpers below are compiled either way.
#ifndef ENABLE_GC_PHASE_TIMERS
#define ENABLE_GC_PHASE_TIMERS 0
#endif
#if ENABLE_GC_PHASE_TIMERS && !ENABLE_GC_STATS
#error "ENABLE_GC_PHASE_TIMERS (CMake ECO_GC_PHASE_TIMERS) requires ENABLE_GC_STATS (ECO_GC_STATS)"
#endif

/// A counter that picks one call in every 2^`K` to be timed, for paths too hot to time every call.
///
/// The choice is made by counting, not at random, so the same sequence of calls is sampled on every
/// run. `shouldSample` counts the call in `calls`; the caller times the sampled ones itself and adds
/// to `sampled_calls` and `sampled_ns`. `sampledEstimateNs` turns the three into an estimate for all
/// calls.
template <unsigned K>
struct SampledTimer {
    uint64_t calls = 0;
    uint64_t sampled_calls = 0;
    uint64_t sampled_ns = 0;
    /// Counts one call and returns whether it is to be timed: true for the first call and every
    /// 2^`K`-th one after it.
    bool shouldSample() noexcept {
        return ((calls++) & ((uint64_t{1} << K) - 1)) == 0;
    }
};

/// Returns the cost in nanoseconds of one empty timing bracket: the smallest difference between two
/// back-to-back `GCStats::nowSinceProcessStartNs` reads over 2000 tries, measured on the first call
/// and returned unchanged after it.
uint64_t gcClockOverheadNs() noexcept;

/// Returns an estimate of the time spent in `d_calls` calls of which `d_sampled_calls` were timed,
/// taking `d_sampled_ns` in all: the timed total, less `gcClockOverheadNs` for each timed call
/// (floored at 0), scaled by `d_calls / d_sampled_calls`. Returns 0 when nothing was timed. The
/// arguments are usually differences of a `SampledTimer`'s fields over an interval.
inline uint64_t sampledEstimateNs(uint64_t d_sampled_ns, uint64_t d_calls,
                                  uint64_t d_sampled_calls) noexcept {
    if (d_sampled_calls == 0) return 0;
    const uint64_t ovh = gcClockOverheadNs() * d_sampled_calls;
    d_sampled_ns = d_sampled_ns > ovh ? d_sampled_ns - ovh : 0;
    return static_cast<uint64_t>(static_cast<double>(d_sampled_ns) *
                                 static_cast<double>(d_calls) /
                                 static_cast<double>(d_sampled_calls));
}

/// The number of external root scanners timed separately in one minor. Scanners past this share the
/// last slot.
constexpr int GC_EXT_SCANNER_CAP = 16;

/// The measurements of one minor collection, for the phase breakdown and the event log.
///
/// Times are nanoseconds. The root-phase times cover four groups of roots: long-lived and JIT roots,
/// stack-map roots, shadow-stack ranges and single slots, and external root scanners; each includes
/// copying the objects those roots reach directly. A record from a parallel or region-nursery minor
/// leaves the `drain_*` fields at 0 and fills the `par_*` fields instead, and a region-nursery minor
/// puts all of its root time in `roots_longlived_jit_ns`. The `rg_*` fields are 0 outside the region
/// nursery.
struct MinorGCRecord {
    uint64_t start_ns = 0;             ///< Process-relative time the minor started, at its stack walk.
    uint64_t stack_walk_ns = 0;
    uint64_t frames_walked = 0;
    uint64_t frames_matched = 0;
    uint64_t stack_slots = 0;
    uint64_t roots_longlived_jit_ns = 0;
    uint64_t roots_stackmap_ns = 0;
    uint64_t roots_ranges_ns = 0;      ///< Shadow-stack ranges and single slots.
    uint64_t roots_external_ns = 0;
    int      ext_count = 0;            ///< Entries used in `ext_ns` and `ext_slots`, at most the cap.
    uint64_t ext_ns[GC_EXT_SCANNER_CAP] = {0};      ///< Per external scanner, in registration order.
    uint64_t ext_slots[GC_EXT_SCANNER_CAP] = {0};
    uint64_t drain_tospace_ns = 0;
    uint64_t drain_promoted_ns = 0;
    uint64_t drain_rounds = 0;
    uint64_t tail_ns = 0;              ///< From the end of the drain to the end of `nursery_pause_ns`.
    uint64_t nursery_pause_ns = 0;     ///< The same per-minor time as `GCStats::total_minor_gc_time_ns` sums.
    uint64_t large_body_sweep_ns = 0;
    uint64_t lazy_sweep_calls = 0;
    uint64_t lazy_sweep_bytes = 0;
    uint64_t lazy_sweep_est_ns = 0;
    uint64_t promo_alloc_calls = 0;
    uint64_t promo_alloc_est_ns = 0;
    uint64_t survived = 0;
    uint64_t promoted = 0;
    uint64_t survived_bytes = 0;
    uint64_t promoted_bytes = 0;
    uint64_t minflt = 0;
    uint64_t majflt = 0;
    uint64_t pause_ns = 0;             ///< From `start_ns` to when the record is completed.
    // Parallel and region-nursery minors.
    uint64_t workers = 1;
    uint64_t par_sweep_ns = 0;         ///< The lazy-sweep slice run before the drain.
    uint64_t par_roots_ns = 0;         ///< The root phase, which one worker runs alone.
    uint64_t par_drain_ns = 0;         ///< The drain run by all workers together.
    uint64_t par_close_ns = 0;         ///< Closing the workers' allocation buffers and merging their counts.
    uint64_t filler_bytes = 0;
    uint64_t mutex_wait_ns = 0;        ///< Summed over workers: waits for the old gen's promotion lock.
    uint64_t imbalance_units = 0;      ///< Most minus fewest entries scanned by one worker.
    // Region nursery only.
    uint64_t rg_region = 0;
    uint64_t rg_merge_ns = 0;
    uint64_t rg_heal_slots = 0;
    uint64_t rg_zapped = 0, rg_zap_ns = 0;   ///< Not written to the event log.
    uint64_t rg_heal_ns = 0;
    uint64_t rg_wait_ns = 0;
    uint64_t rg_help_ns = 0;
    uint64_t rg_help_workers = 0;
    uint64_t rg_late = 0;   ///< 1 if this minor stopped its tenure job in the pause (`late`).
    uint64_t rg_tenured = 0;
    uint64_t rg_tenured_bytes = 0;
    uint64_t rg_busy_ns = 0;
    uint64_t rg_ylos_promoted = 0;
    uint64_t rg_ylos_freed = 0;
    uint64_t rg_lb_promoted = 0;
    uint64_t rg_starts = 0;
    uint64_t rg_heal_recorded = 0;
    uint64_t rg_resolved = 0;
    uint64_t rg_grant_blocks = 0;
    uint64_t rg_grant_cells = 0;
    uint64_t rg_grant_used = 0;
    uint64_t rg_fill_obj_bytes = 0;   ///< Bytes of survivors copied to the fill extent.
    uint64_t rg_bld_bytes = 0;        ///< Bytes of builder objects copied to the builder area.
    uint64_t rg_epoch_ns = 0;
};

/// One pause: a contiguous stop of the mutator for collection work, with a process-relative start.
struct PauseEvent {
    uint64_t start_ns;
    uint64_t dur_ns;
    /// What the pause contained: 0 a minor only, 1 a minor with a major inside it, 2 a major only,
    /// and, for a minor that also did mark-cycle work, 3 the cycle's start (t0), 4 a mark slice, 5
    /// the cycle's handoff. A value above 5 is not counted by kind.
    uint8_t  kind;
};

/// Counters of the old generation's bitmap allocation path, merged by adding. The banner leaves the
/// block out when `any` is false.
struct BitmapAllocStats {
    uint64_t bitmap_allocs = 0;
    uint64_t bitmap_alloc_bytes = 0;
    uint64_t cursor_refills = 0;
    uint64_t virgin_blocks = 0;
    uint64_t list_pops = 0;
    uint64_t split_allocs = 0;
    uint64_t sweep_on_demand_hits = 0;
    uint64_t gap_sweep_live_objects = 0;
    uint64_t gap_sweep_gaps = 0;
    uint64_t gap_sweep_bytes = 0;
    uint64_t uniform_cells_freed = 0;
    uint64_t blocks_classified_uniform = 0;
    uint64_t blocks_classified_large = 0;
    uint64_t blocks_classified_mixed = 0;
    /// Free bytes (cells times cell size, less live bytes) of the uniform blocks queued at each
    /// major's end, summed over majors. These cells are not on free lists, so the residency
    /// histogram counts them as garbage.
    uint64_t bitmap_free_bytes_at_major = 0;
    /// Lazy sweeps completed after the loop over blocks, the slice's budget having run out exactly
    /// at the last block's end.
    uint64_t sweep_tail_completions = 0;
    /// Those of `sweep_tail_completions` that happened during a parallel promotion.
    uint64_t sweep_tail_in_promotion = 0;
    /// Empty regular blocks taken whole as the block of one large object.
    uint64_t empty_block_flips = 0;
    /// Large-body index entries retired by those flips.
    uint64_t flip_index_retired = 0;
    /// Flips refused because a parallel minor with more than one worker was running.
    uint64_t flip_skipped_parallel = 0;
    /// Adds every counter of `o` to this one.
    void merge(const BitmapAllocStats& o) {
        bitmap_allocs += o.bitmap_allocs;
        bitmap_alloc_bytes += o.bitmap_alloc_bytes;
        cursor_refills += o.cursor_refills;
        virgin_blocks += o.virgin_blocks;
        list_pops += o.list_pops;
        split_allocs += o.split_allocs;
        sweep_on_demand_hits += o.sweep_on_demand_hits;
        gap_sweep_live_objects += o.gap_sweep_live_objects;
        gap_sweep_gaps += o.gap_sweep_gaps;
        gap_sweep_bytes += o.gap_sweep_bytes;
        uniform_cells_freed += o.uniform_cells_freed;
        blocks_classified_uniform += o.blocks_classified_uniform;
        blocks_classified_large += o.blocks_classified_large;
        blocks_classified_mixed += o.blocks_classified_mixed;
        bitmap_free_bytes_at_major += o.bitmap_free_bytes_at_major;
        sweep_tail_completions += o.sweep_tail_completions;
        sweep_tail_in_promotion += o.sweep_tail_in_promotion;
        empty_block_flips += o.empty_block_flips;
        flip_index_retired += o.flip_index_retired;
        flip_skipped_parallel += o.flip_skipped_parallel;
    }
    /// Returns whether any of the main allocation or classification counters is non-zero. The
    /// sweep-tail and flip counters are not consulted.
    bool any() const {
        return bitmap_allocs | virgin_blocks | cursor_refills |
               blocks_classified_uniform | blocks_classified_mixed |
               blocks_classified_large | gap_sweep_gaps;
    }
};

/// Large allocations (at or above the large-object threshold) by where they were placed, and the
/// life of objects in the young large-object space (YLOS). Merged by adding.
struct LargePtrStats {
    uint64_t nursery_allocs = 0, nursery_bytes = 0;     ///< Pointer-bearing, placed in the nursery.
    uint64_t ylos_allocs = 0, ylos_bytes = 0;           ///< Pointer-bearing, placed in the YLOS.
    uint64_t region_allocs = 0, region_bytes = 0;       ///< Large closure-group regions.
    uint64_t pointerfree_allocs = 0, pointerfree_bytes = 0;   ///< Pointer-free, placed in the old gen.
    uint64_t ylos_promoted_in_place = 0, ylos_freed_minor = 0, ylos_retired_major = 0;
    uint64_t ylos_reach_calls = 0, ylos_scans = 0;
    /// Returns whether any allocation was counted.
    bool any() const {
        return nursery_allocs | ylos_allocs | region_allocs | pointerfree_allocs;
    }
    /// Adds every counter of `o` to this one.
    void combine(const LargePtrStats& o) {
        nursery_allocs += o.nursery_allocs; nursery_bytes += o.nursery_bytes;
        ylos_allocs += o.ylos_allocs; ylos_bytes += o.ylos_bytes;
        region_allocs += o.region_allocs; region_bytes += o.region_bytes;
        pointerfree_allocs += o.pointerfree_allocs; pointerfree_bytes += o.pointerfree_bytes;
        ylos_promoted_in_place += o.ylos_promoted_in_place;
        ylos_freed_minor += o.ylos_freed_minor;
        ylos_retired_major += o.ylos_retired_major;
        ylos_reach_calls += o.ylos_reach_calls;
        ylos_scans += o.ylos_scans;
    }
};

/// Counters of the parallel minor collection (invariant HEAP_067) and of the nursery's object-byte
/// accounting (HEAP_068). Merged by adding, except `filler_bytes_max`, which takes the larger.
struct ParMinorStats {
    /// Minors run in parallel, and minors run serially because too few bytes had been allocated
    /// since the last one, or because to-space could not be shown to hold the worst case. In the
    /// region nursery both reasons count in `serial_small`, and `serial_space` stays 0.
    uint64_t minors_parallel = 0, serial_small = 0, serial_space = 0;
    uint64_t workers_sum = 0;
    uint64_t filler_bytes_total = 0, filler_bytes_max = 0;   ///< Max is for a single minor.
    uint64_t alloc_end_capped = 0;
    uint64_t lab_claims = 0, direct_claims = 0, claim_races = 0, busy_waits = 0;
    uint64_t spine_splits = 0, chunks = 0;
    uint64_t steals = 0, steal_aborts = 0, idle_spins = 0, idle_yields = 0, idle_sleeps = 0;
    uint64_t promo_mutex_acquires = 0, promo_mutex_wait_ns = 0;
    uint64_t imbalance_units_sum = 0;
    uint64_t drain_ns_sum = 0, sweep_ns_sum = 0;
    uint64_t member_cpu_ns = 0;             ///< CPU time of the helper workers, not the mutator.
    /// Returns whether any minor was counted, or `alloc_end_capped` is non-zero.
    bool any() const { return minors_parallel | serial_small | serial_space | alloc_end_capped; }
    /// Adds `o` to this one, as the type's comment describes.
    void combine(const ParMinorStats& o) {
        minors_parallel += o.minors_parallel; serial_small += o.serial_small;
        serial_space += o.serial_space; workers_sum += o.workers_sum;
        filler_bytes_total += o.filler_bytes_total;
        if (o.filler_bytes_max > filler_bytes_max) filler_bytes_max = o.filler_bytes_max;
        alloc_end_capped += o.alloc_end_capped;
        lab_claims += o.lab_claims; direct_claims += o.direct_claims;
        claim_races += o.claim_races; busy_waits += o.busy_waits;
        spine_splits += o.spine_splits; chunks += o.chunks;
        steals += o.steals; steal_aborts += o.steal_aborts; idle_spins += o.idle_spins;
        idle_yields += o.idle_yields; idle_sleeps += o.idle_sleeps;
        promo_mutex_acquires += o.promo_mutex_acquires;
        promo_mutex_wait_ns += o.promo_mutex_wait_ns;
        imbalance_units_sum += o.imbalance_units_sum;
        drain_ns_sum += o.drain_ns_sum; sweep_ns_sum += o.sweep_ns_sum;
        member_cpu_ns += o.member_cpu_ns;
    }
};

/// The scalar counters of the region nursery and its tenure jobs (invariants HEAP_069 and HEAP_070).
///
/// Merged by adding, except `max_nonfree`, `major_zap_ns_max` and `tenure_age`, which take the larger.
/// It holds only integers, so it can be copied as raw bytes; `RegionTenureStats` adds the part that
/// cannot.
struct RegionTenureCounters {
    uint64_t minors = 0, jobs = 0, merges = 0;
    uint64_t tenured = 0, tenured_bytes = 0, starts = 0, heal_slots = 0, resolved = 0;
    // `late`: tenure jobs stopped in a pause (`stopAndJoin`) rather than joined after they had
    // finished. `stops`: times tenure work was stopped unfinished, either an exact-engine drain
    // stopped by its stop flag or a pause that finished a parallel job's leftover work.
    uint64_t heal_ns = 0, merge_ns = 0, wait_ns = 0, help_ns = 0, late = 0, stops = 0;
    uint64_t help_workers_sum = 0;
    uint64_t busy_ns = 0, epoch_ns = 0, collector_cpu_ns = 0;
    // `grant_virgin`: never-used old-gen blocks materialised to fill tenure grants.
    uint64_t grant_blocks = 0, grant_cells = 0, grant_used = 0, grant_virgin = 0;
    uint64_t ylos_gen_promoted = 0, ylos_gen_freed = 0, lb_promoted = 0;
    uint64_t shadow_wraps = 0, eden_clear_ns = 0;
    uint64_t max_nonfree = 0;   ///< Most survivor extents in use at the end of a minor.
    uint64_t sync_parallel_jobs = 0;
    /// Current values when the record was filled, yet merged by adding.
    uint64_t survivor_hw_bytes = 0, shadow_committed_bytes = 0, eden_capacity_bytes = 0;
    // The parallel tenure engines: runs, entries scanned, the busiest worker's entries summed over
    // runs, steals and idle waits.
    uint64_t par_runs = 0, par_units = 0, par_units_max_sum = 0, par_steals = 0;
    uint64_t par_idle_spins = 0, par_idle_yields = 0, par_idle_sleeps = 0;
    /// Survivor copies smaller than 16 bytes, heals run on the mark gang, and grants that fell
    /// back because the old generation was near its cap.
    uint64_t copies_under16 = 0, heals_parallel = 0, grant_fallbacks = 0;
    // Tenure ages above 1: the ageing mark and the zap of dead survivors.
    uint64_t tenure_age = 1, age_starts = 0, age_marked = 0, age_marked_bytes = 0, age_heal = 0;
    uint64_t zapped = 0, zapped_bytes = 0, zap_ns = 0, age_forced_exact = 0, age_par_marks = 0;
    /// A stop-the-world major's zap of the unreached survivors of young extents (HEAP_074): passes,
    /// objects, bytes, total time and the slowest pass.
    uint64_t major_zaps = 0, major_zapped = 0, major_zapped_bytes = 0, major_zap_ns = 0, major_zap_ns_max = 0;
    /// Slots of dead ageing-generation YLOS objects cleared at a merge.
    uint64_t zapped_ylos = 0;
    /// Tenure-job launches refused while a fork held the collector.
    uint64_t fork_refusals = 0;
    /// Returns whether any region-nursery minor was counted.
    bool any() const { return minors != 0; }
    /// Adds `o` to this one, as the type's comment describes.
    void combine(const RegionTenureCounters& o) {
        minors += o.minors; jobs += o.jobs; merges += o.merges;
        tenured += o.tenured; tenured_bytes += o.tenured_bytes; starts += o.starts;
        heal_slots += o.heal_slots; resolved += o.resolved; heal_ns += o.heal_ns;
        merge_ns += o.merge_ns; wait_ns += o.wait_ns; help_ns += o.help_ns; late += o.late;
        stops += o.stops; help_workers_sum += o.help_workers_sum; busy_ns += o.busy_ns;
        epoch_ns += o.epoch_ns; collector_cpu_ns += o.collector_cpu_ns;
        grant_blocks += o.grant_blocks; grant_cells += o.grant_cells; grant_used += o.grant_used;
        grant_virgin += o.grant_virgin; ylos_gen_promoted += o.ylos_gen_promoted;
        ylos_gen_freed += o.ylos_gen_freed; lb_promoted += o.lb_promoted;
        shadow_wraps += o.shadow_wraps; eden_clear_ns += o.eden_clear_ns;
        if (o.max_nonfree > max_nonfree) max_nonfree = o.max_nonfree;
        sync_parallel_jobs += o.sync_parallel_jobs;
        survivor_hw_bytes += o.survivor_hw_bytes;
        shadow_committed_bytes += o.shadow_committed_bytes;
        eden_capacity_bytes += o.eden_capacity_bytes;
        par_runs += o.par_runs; par_units += o.par_units; par_units_max_sum += o.par_units_max_sum;
        par_steals += o.par_steals; par_idle_spins += o.par_idle_spins;
        par_idle_yields += o.par_idle_yields; par_idle_sleeps += o.par_idle_sleeps;
        copies_under16 += o.copies_under16; heals_parallel += o.heals_parallel;
        grant_fallbacks += o.grant_fallbacks;
        fork_refusals += o.fork_refusals;
        if (o.tenure_age > tenure_age) tenure_age = o.tenure_age;
        age_starts += o.age_starts; age_marked += o.age_marked;
        age_marked_bytes += o.age_marked_bytes; age_heal += o.age_heal;
        zapped += o.zapped; zapped_bytes += o.zapped_bytes; zap_ns += o.zap_ns;
        age_forced_exact += o.age_forced_exact; age_par_marks += o.age_par_marks;
        major_zaps += o.major_zaps; major_zapped += o.major_zapped;
        major_zapped_bytes += o.major_zapped_bytes; major_zap_ns += o.major_zap_ns;
        if (o.major_zap_ns_max > major_zap_ns_max) major_zap_ns_max = o.major_zap_ns_max;
        zapped_ylos += o.zapped_ylos;
    }
};
/// The region-nursery counters together with one utilisation sample per merged tenure job.
/// Merging adds the counters as `RegionTenureCounters` does and appends `o`'s samples.
struct RegionTenureStats : RegionTenureCounters {
    std::vector<uint32_t> util_ppm;    ///< Per merged job: busy time over epoch time, in millionths.
    /// Merges `o` into this one, as the type's comment describes.
    void combine(const RegionTenureStats& o) {
        RegionTenureCounters::combine(o);
        util_ppm.insert(util_ppm.end(), o.util_ppm.begin(), o.util_ppm.end());
    }
};

/// Counters of the incremental mark cycle (invariant HEAP_063): a major spread over several minor
/// pauses, starting at t0, marking in slices and ending at the handoff. Merged by adding, except the
/// `_max` fields, which take the larger.
struct IncrMarkStats {
    uint64_t cycles = 0, slices = 0, slice_units = 0, closing_units = 0;
    uint64_t closing_units_max = 0;
    /// Cycles ended for each `OldGenSpace::CycleFinish` reason: Schedule, Pressure and Join.
    uint64_t finish_schedule = 0, finish_pressure = 0, finish_join = 0;
    uint64_t black_bytes = 0, traced_live_bytes = 0;
    uint64_t deferred_frees = 0, deferred_free_bytes = 0;
    uint64_t t0_survivors = 0, t0_survivor_bytes = 0, t0_ylos = 0;
    uint64_t t0_ns_total = 0, t0_ns_max = 0;
    /// The part of the t0 times spent finishing the lazy sweep and clearing mark bits.
    uint64_t t0_prep_ns_total = 0, t0_prep_ns_max = 0;
    uint64_t slice_ns_total = 0, slice_ns_max = 0;
    uint64_t handoff_ns_total = 0, handoff_ns_max = 0;
    /// Returns whether any cycle or slice was counted.
    bool any() const { return cycles != 0 || slices != 0; }
    /// Adds `o` to this one, as the type's comment describes.
    void combine(const IncrMarkStats& o) {
        cycles += o.cycles; slices += o.slices; slice_units += o.slice_units;
        closing_units += o.closing_units;
        if (o.closing_units_max > closing_units_max) closing_units_max = o.closing_units_max;
        finish_schedule += o.finish_schedule; finish_pressure += o.finish_pressure;
        finish_join += o.finish_join;
        black_bytes += o.black_bytes; traced_live_bytes += o.traced_live_bytes;
        deferred_frees += o.deferred_frees; deferred_free_bytes += o.deferred_free_bytes;
        t0_survivors += o.t0_survivors; t0_survivor_bytes += o.t0_survivor_bytes;
        t0_ylos += o.t0_ylos;
        t0_ns_total += o.t0_ns_total; slice_ns_total += o.slice_ns_total;
        t0_prep_ns_total += o.t0_prep_ns_total;
        if (o.t0_prep_ns_max > t0_prep_ns_max) t0_prep_ns_max = o.t0_prep_ns_max;
        handoff_ns_total += o.handoff_ns_total;
        if (o.t0_ns_max > t0_ns_max) t0_ns_max = o.t0_ns_max;
        if (o.slice_ns_max > slice_ns_max) slice_ns_max = o.slice_ns_max;
        if (o.handoff_ns_max > handoff_ns_max) handoff_ns_max = o.handoff_ns_max;
    }
};

/// Counters of the parallel marker. Merged by adding, except `members_max`, `imbalance_milli_max`,
/// `run_ns_max` and `deque_peak_entries`, which take the larger.
struct ParMarkStats {
    uint64_t runs = 0, members_max = 0, units = 0;
    uint64_t steals = 0, steal_aborts = 0, steal_empty = 0;
    uint64_t idle_spins = 0, idle_yields = 0, idle_sleeps = 0;
    /// A run's imbalance: the busiest member's units over the mean, times 1000.
    uint64_t imbalance_milli_sum = 0, imbalance_milli_max = 0;
    uint64_t member_cpu_ns = 0, run_ns_total = 0, run_ns_max = 0;
    uint64_t deque_grows = 0, deque_peak_entries = 0, chunks_pushed = 0;
    /// Returns whether any run or pushed chunk was counted.
    bool any() const { return runs != 0 || chunks_pushed != 0; }
    /// Adds `o` to this one, as the type's comment describes.
    void combine(const ParMarkStats& o) {
        runs += o.runs; units += o.units;
        if (o.members_max > members_max) members_max = o.members_max;
        steals += o.steals; steal_aborts += o.steal_aborts; steal_empty += o.steal_empty;
        idle_spins += o.idle_spins; idle_yields += o.idle_yields; idle_sleeps += o.idle_sleeps;
        imbalance_milli_sum += o.imbalance_milli_sum;
        if (o.imbalance_milli_max > imbalance_milli_max) imbalance_milli_max = o.imbalance_milli_max;
        member_cpu_ns += o.member_cpu_ns; run_ns_total += o.run_ns_total;
        if (o.run_ns_max > run_ns_max) run_ns_max = o.run_ns_max;
        deque_grows += o.deque_grows;
        if (o.deque_peak_entries > deque_peak_entries) deque_peak_entries = o.deque_peak_entries;
        chunks_pushed += o.chunks_pushed;
    }
};

/// Counters of concurrent marking, where background markers mark during *episodes* that run
/// between pauses. Merged by adding, except the `_max` fields, which take the larger.
///
/// These count progress, which depends on how far background threads got, so two runs of the same
/// program can give different values.
struct ConcMarkStats {
    uint64_t episodes_launched = 0, episodes_relaunched = 0, episodes_stopped = 0;
    uint64_t episodes_refused = 0;   ///< Launches refused while a fork held the collector.
    uint64_t bg_units = 0;
    uint64_t assists = 0, assist_units = 0, assist_ns_total = 0, assist_ns_max = 0;
    uint64_t closings_with_work = 0, closing_units = 0, closing_ns_total = 0, closing_ns_max = 0;
    /// Cycles whose background marking finished by slice T/4, T/2, 3T/4 and T of a cycle of T
    /// slices, and last, cycles whose closing pause still had work or that recorded no finishing
    /// slice.
    uint64_t done_k_hist[5] = {0, 0, 0, 0, 0};
    uint64_t bg_cpu_ns = 0, bg_wall_ns_total = 0;
    uint64_t stop_wait_ns_max = 0, join_wait_ns_max = 0;
    /// The mutator thread's CPU time at its last pause end, and the part of it spent in pauses.
    /// The first is a reading of a clock, not a sum, yet `combine` adds it.
    uint64_t mutator_cpu_ns = 0, mutator_pause_cpu_ns = 0;
    /// Returns whether any episode, assist or closing with work was counted.
    bool any() const { return episodes_launched != 0 || assists != 0 || closings_with_work != 0; }
    /// Adds `o` to this one, as the type's comment describes.
    void combine(const ConcMarkStats& o) {
        episodes_launched += o.episodes_launched; episodes_relaunched += o.episodes_relaunched;
        episodes_stopped += o.episodes_stopped; bg_units += o.bg_units;
        episodes_refused += o.episodes_refused;
        assists += o.assists; assist_units += o.assist_units;
        assist_ns_total += o.assist_ns_total;
        if (o.assist_ns_max > assist_ns_max) assist_ns_max = o.assist_ns_max;
        closings_with_work += o.closings_with_work; closing_units += o.closing_units;
        closing_ns_total += o.closing_ns_total;
        if (o.closing_ns_max > closing_ns_max) closing_ns_max = o.closing_ns_max;
        for (int i = 0; i < 5; ++i) done_k_hist[i] += o.done_k_hist[i];
        bg_cpu_ns += o.bg_cpu_ns; bg_wall_ns_total += o.bg_wall_ns_total;
        if (o.stop_wait_ns_max > stop_wait_ns_max) stop_wait_ns_max = o.stop_wait_ns_max;
        if (o.join_wait_ns_max > join_wait_ns_max) join_wait_ns_max = o.join_wait_ns_max;
        mutator_cpu_ns += o.mutator_cpu_ns; mutator_pause_cpu_ns += o.mutator_pause_cpu_ns;
    }
};

/// Where the old generation's pages came from and went to, for the whole allocator rather than one
/// heap. Merged by taking the larger of each field (`mergeMax`).
struct PageSupplyStats {
    uint64_t released_bytes = 0, released_extents = 0;
    uint64_t discarded_bytes = 0, discarded_extents = 0;
    uint64_t discard_inline_ns = 0;          ///< Time spent discarding pages on the calling thread.
    uint64_t reuse_resident_bytes = 0;       ///< Reused while still resident: discard cancelled or not done.
    uint64_t reuse_after_discard_bytes = 0;  ///< Reused after a discard, so the pages fault in again.
    uint64_t fresh_bytes = 0;                ///< Committed fresh at the commit high-water mark.
    uint64_t fresh_ahead_hit_bytes = 0, fresh_ahead_miss_bytes = 0;
    uint64_t pending_peak_bytes = 0;
    /// Returns whether any page was released, reused or freshly committed.
    bool any() const { return released_bytes | reuse_resident_bytes |
                              reuse_after_discard_bytes | fresh_bytes; }
    /// Sets each field to the larger of its value and `o`'s.
    void mergeMax(const PageSupplyStats& o);
};

/// A copy of the GC helper pool's and the page-work counters and settings, taken when a combined
/// record is built. `mode` 0 means the helper pool is off, and the banner then leaves the block out.
struct HelperStatsSnapshot {
    uint32_t mode = 0, threads = 0, jitter_us = 0;
    int32_t  pin_cpu = -1;                   ///< Negative when the helpers are not pinned to a CPU.
    /// The number of helper-job clients; must equal `gc::HelperClient::kCount`, which nothing checks.
    static constexpr int kClients = 3;
    uint64_t jobs[kClients] = {0}, bytes[kClients] = {0};   ///< Indexed by `gc::HelperClient`.
    uint64_t cpu_ns[kClients] = {0}, inline_cpu_ns[kClients] = {0};
    uint64_t posts = 0;
    uint64_t stall_count = 0, stall_ns = 0, stall_max_ns = 0;
    uint64_t stall_outside_pause = 0, stall_outside_pause_ns = 0;
    uint64_t reuse_waits = 0, release_waits = 0, slot_full_waits = 0;
    uint64_t cancelled_bytes = 0, cancelled_extents = 0;
    uint64_t discard_jobs = 0, discard_failures = 0;
    uint64_t populate_jobs = 0, populate_bytes = 0, populate_failures = 0;
    uint64_t window_commit_failures = 0;
    bool     populate_supported = false;
    uint64_t commit_ahead_bytes = 0, decommit_delay = 0, pending_cap = 0;
    uint64_t decommit_delay_majors = 0;
    uint64_t process_cpu_ns = 0;             ///< The process's CPU time when the copy was taken.
    /// Replaces this snapshot with `o` when this one's `mode` is 0 and `o`'s is not; otherwise does
    /// nothing.
    void mergeMax(const HelperStatsSnapshot& o);
};

/// Whole-run totals of the minor phase records and the pause log, with the arithmetic for their
/// banner blocks.
///
/// The minor totals add up `MinorGCRecord`s (keeping maxima for a few), and external root scanners
/// are matched by name. The pause log keeps up to `PAUSE_EVENT_CAP` pauses and helper stalls in
/// order of recording, counting the rest as dropped; the counts and histogram cover every pause.
/// Merging adds, takes maxima, and appends the other record's events up to the cap.
struct GCPhaseTotals {
    // ----- minor phase totals (summed over recorded minors) -----
    uint64_t minor_records = 0;         ///< The number of `MinorGCRecord`s added.
    uint64_t stack_walk_ns = 0, stack_walk_ns_max = 0;
    uint64_t frames_walked = 0, frames_walked_max = 0;
    uint64_t frames_matched = 0;
    uint64_t stack_slots = 0, stack_slots_max = 0;
    uint64_t roots_longlived_jit_ns = 0, roots_stackmap_ns = 0;
    uint64_t roots_ranges_ns = 0, roots_external_ns = 0;
    uint64_t drain_tospace_ns = 0, drain_promoted_ns = 0;
    uint64_t drain_rounds = 0, drain_rounds_max = 0;
    uint64_t tail_ns = 0, nursery_pause_ns = 0, large_body_sweep_ns = 0;
    uint64_t lazy_sweep_calls = 0, lazy_sweep_bytes = 0, lazy_sweep_est_ns = 0;
    uint64_t promo_alloc_calls = 0, promo_alloc_est_ns = 0;
    uint64_t survived = 0, promoted = 0, survived_bytes = 0, promoted_bytes = 0;
    uint64_t minflt = 0, majflt = 0;
    uint64_t minor_pause_ns = 0;        ///< Sum of the records' `pause_ns`.

    // ----- per external root scanner (merged by name) -----
    int         ext_count = 0;
    /// Scanner names, kept as pointers: each string must outlive these totals.
    const char* ext_name[GC_EXT_SCANNER_CAP] = {nullptr};
    uint64_t    ext_ns[GC_EXT_SCANNER_CAP] = {0};
    uint64_t    ext_slots[GC_EXT_SCANNER_CAP] = {0};
    uint64_t    ext_slots_max[GC_EXT_SCANNER_CAP] = {0};

    // ----- pause accounting -----
    /// The most pauses, and separately the most stalls, whose events are kept; later ones are only
    /// counted.
    static constexpr size_t PAUSE_EVENT_CAP = size_t{1} << 18;
    /// The number of buckets in `pause_log2_hist`. Bucket b holds pauses of [2^b, 2^(b+1))
    /// microseconds, except that bucket 0 holds everything under 2 us and the last bucket everything
    /// from 2^31 us up.
    static constexpr int PAUSE_LOG2_BUCKETS = 32;
    std::vector<PauseEvent> pause_events;   ///< In order of recording, not sorted.
    uint64_t pause_events_dropped = 0;
    uint64_t pause_count = 0;
    uint64_t pause_total_ns = 0;
    uint64_t pause_max_ns = 0;
    uint64_t pause_count_by_kind[6] = {0, 0, 0, 0, 0, 0};   ///< Indexed by `PauseEvent::kind`.
    uint64_t pause_log2_hist[PAUSE_LOG2_BUCKETS] = {0};

    /// Times the mutator waited for a helper job outside a pause. A wait inside a pause is already
    /// pause time. These are kept apart from `pause_events`, and only the second MMU table uses them.
    std::vector<PauseEvent> stall_events;
    uint64_t stall_events_dropped = 0;
    /// Appends a stall of `dur_ns` starting at process-relative `start_ns` to `stall_events`, or
    /// counts it as dropped once the list holds `PAUSE_EVENT_CAP`. The event's `kind` is 3, which
    /// nothing reads for a stall.
    void addStall(uint64_t start_ns, uint64_t dur_ns);

    /// Adds `r` to the minor totals. `names[i]` names `r`'s external scanner i; a scanner with no
    /// name (an index at or past `n_names`, or a null `names`) is recorded as "unnamed". The names
    /// are kept by pointer, as `ext_name` says.
    void addMinor(const MinorGCRecord& r, const char* const* names, size_t n_names);
    /// Counts a pause of `dur_ns` starting at process-relative `start_ns`, with `kind` as in
    /// `PauseEvent`, and keeps its event unless `PAUSE_EVENT_CAP` events are already kept.
    void addPause(uint64_t start_ns, uint64_t dur_ns, uint8_t kind);
    /// Returns the index of the scanner named `name` (compared by pointer, then by contents),
    /// adding it if new. A null `name` means "unnamed". When all `GC_EXT_SCANNER_CAP` entries are
    /// taken, a new name gets the last index and shares it.
    int scannerIndex(const char* name);
    /// Adds `other` into this one, as the type's comment describes. Scanners are matched by name.
    void merge(const GCPhaseTotals& other);

    // ----- print-time helpers (static so tests can call them) -----
    /// Returns the nearest-rank `q` quantile of `sorted`, which must be in ascending order, for `q`
    /// in (0, 1]. Returns 0 for an empty vector.
    static uint64_t percentile(const std::vector<uint64_t>& sorted, double q);
    /// Returns the minimum mutator utilisation for windows of `w_ns` within [0, `wall_ns`]: the
    /// smallest fraction of any such window not covered by a pause in `sorted`, from 0 to 1.
    ///
    /// `sorted` must be in order of start time; overlapping pauses are merged first. Returns 1 when
    /// `w_ns` is 0 or longer than `wall_ns`, or when there are no pauses. Only windows that start or
    /// end at a pause boundary are examined, which is where the minimum lies.
    static double mmu(const std::vector<PauseEvent>& sorted, uint64_t wall_ns,
                      uint64_t w_ns);
    /// Returns the `pause_log2_hist` bucket of a pause lasting `dur_ns`.
    static int pauseBucket(uint64_t dur_ns);
};

// ----------------------------------------------------------------------------
// Event log
// ----------------------------------------------------------------------------
//
// When the environment variable `ECO_GC_EVENT_LOG` names a path, the functions below write one
// tab-separated row per event to that file. The variable is read once, on the first call to any of
// them. The file is created and truncated at the first row, and its header names every column; a
// write that cannot open it is dropped, as is every later one. Rows of every kind share the columns
// of a minor row and put "-" in the ones they do not use, and the columns some kinds reuse for
// other quantities are listed with each function. Writes are serialised by a mutex, so the functions
// may be called from any thread, and each row's `tid` column is a small number given to the calling
// thread at its first row. Numbers are written as given; times are expected to be process-relative
// nanoseconds. `reason`, `client` and `finish` must not be null; `names` may be null, and a null
// name is written as "unnamed". Strings are copied.

struct MinorGCRecord;
/// Returns whether `ECO_GC_EVENT_LOG` is set to a non-empty path. It does not say whether the file
/// could be opened.
bool gcEventLogEnabled() noexcept;
/// Writes a "minor" row for `r`, the minor numbered `seq`. `names[i]` names `r`'s external scanner i.
///
/// The external-scanner columns are fixed by the first row written: the header gets a pair of
/// columns for each name passed then, and a later scanner whose name is not among them (or every
/// scanner, if the first row was not a minor) is added into the trailing `ext:late` pair. `r`'s
/// `rg_zapped` and `rg_zap_ns` are not written.
void gcEventLogMinor(const MinorGCRecord& r, uint64_t seq, const char* const* names,
                     size_t n_names);
/// Writes a "major" row for major number `seq`, with its total, mark, sweep and root times and
/// `reason`.
void gcEventLogMajor(uint64_t seq, uint64_t start_ns, uint64_t total_ns, uint64_t mark_ns,
                     uint64_t sweep_ns, uint64_t roots_ns, const char* reason);
/// Writes a "pause" row: `dur_ns` goes in `pause_ns`, and `kind` (as in `PauseEvent`) is named in
/// the `major_reason` column, or written as "?" above 5.
void gcEventLogPause(uint64_t seq, uint64_t start_ns, uint64_t dur_ns, uint8_t kind);
/// Writes a "cycle" row for one incremental mark cycle: `t0_ns` in `start_ns`, `span_ns` (t0 to
/// handoff) in `pause_ns`, `span_minors` in `nursery_pause_ns`, `units` in `stack_walk_ns`, and
/// "cycle:" followed by `finish` in `major_reason`.
void gcEventLogCycle(uint64_t seq, uint64_t t0_ns, uint64_t span_ns, uint32_t span_minors,
                     uint64_t units, const char* finish);
/// Writes a "stall" row for a wait of `dur_ns` on a helper job of `client`: `seq` is 0, `dur_ns` is
/// in `pause_ns`, and `major_reason` holds "stall:" and `client`, with ":pause" added when
/// `in_pause`.
void gcEventLogStall(uint64_t start_ns, uint64_t dur_ns, const char* client, bool in_pause);
/// Writes a "job" row for a finished helper job of `client`: `seq` is 0, `post_ns` is in
/// `start_ns`, the queueing delay (`start_ns` - `post_ns`) in `pause_ns`, the run time (`end_ns` -
/// `start_ns`) in `nursery_pause_ns`, `bytes` in `stack_walk_ns`, and "job:" and `client` in
/// `major_reason`. A negative difference is written as 0.
void gcEventLogJob(uint64_t post_ns, uint64_t start_ns, uint64_t end_ns, uint64_t bytes,
                   const char* client);
/// Flushes the log file's buffer, if the file is open. Opening the file also registers this flush
/// to run at normal exit.
void gcEventLogFlush() noexcept;

/// One record of GC statistics: counters, histograms, snapshots and logs for a heap, a part of a
/// heap, or several heaps merged.
///
/// Every member is public and the class keeps no invariant beyond the conventions stated on its
/// members, which any code can break. A default-constructed record is empty (minimum times start at
/// `UINT64_MAX`, meaning none recorded). Copying makes an independent record; the fixed arrays make it
/// large. `combine` merges another record into this one, `print` writes the banner, and `reset`
/// empties it.
///
/// Which members a record fills depends on the code that owns it. Minor counts, for example, can
/// build up in one record while the major event log is kept in another, which is why
/// `recordMajorGCEvent` is handed the minor-side counts rather than reading them from `this`.
class GCStats {
public:
    // ========== Allocation Stats (Minor GC) ==========
    /// Nursery allocations, plus old-gen allocations counted by `recordOldGenDirectAllocation`.
    uint64_t objects_allocated = 0;
    uint64_t bytes_allocated = 0;

    // ========== Minor GC Event Stats ==========
    uint64_t minor_gc_count = 0;
    /// Bytes allocated directly in the old generation that counted toward requesting a minor, and
    /// the minors so requested.
    uint64_t direct_debt_bytes_total = 0;
    uint64_t minor_gc_debt_requests = 0;
    /// Minors and majors run to retry a large-body allocation that failed.
    uint64_t large_body_recover_minors = 0;
    uint64_t large_body_recover_majors = 0;
    /// Counters of a large-object space. A heap's record leaves them at 0; they are expected to be
    /// filled from each heap's `LargeObjectSpace` when a combined record is built.
    struct LosStats {
        uint64_t allocs = 0, frees = 0;
        uint64_t alloc_bytes = 0, free_bytes = 0;   ///< In whole granules.
        uint64_t object_bytes = 0;                  ///< As requested.
        uint64_t blocks_added = 0, blocks_removed = 0;
        uint64_t fit_misses = 0, aligned_allocs = 0;
        uint64_t blocks_now = 0, used_bytes_now = 0;   ///< Current values, yet merged by adding.
    };
    LosStats los;
    uint64_t objects_survived = 0;
    uint64_t objects_promoted = 0;
    uint64_t bytes_freed = 0;             ///< Reclaimed by minors, summed.

    // ========== Nursery Sizing ==========
    /// Times the nursery grew.
    uint64_t nursery_grow_events = 0;
    /// The committed size of the nursery in bytes, both semi-spaces together, as last set by its
    /// owner. Merged by maximum, so a combined record shows the largest single nursery.
    uint64_t nursery_size_bytes = 0;

    // ========== Capacity-check hoisting (HEAP_041) ==========
    /// Calls of the slow path of a hoisted nursery capacity check: a check whose inline compare
    /// failed, so that the nursery must make room or collect.
    uint64_t ensure_slow_calls = 0;

    // ========== Old-gen address-space walls ==========
    //
    // Two figures for the whole allocator, not one heap, which the banner shows against
    // `Allocator::getOldGenMaxBytes` (the address split is HEAP_043). Merged by maximum; the code
    // that builds a combined record is expected to set both.
    /// The peak of the old generation's in-use bytes, a figure that falls when blocks are released.
    uint64_t oldgen_inuse_peak_bytes = 0;
    /// The old generation's commit high-water mark, which never falls.
    uint64_t oldgen_hiwater_bytes = 0;

    // ========== Minor GC Timing Stats ==========
    /// Summed minor times, as passed to `recordMinorGCEnd`. The time for one minor is expected to
    /// be the nursery's own collection, without the stack walk before it or the large-body sweep
    /// after it; `tg` measures whole pauses instead.
    uint64_t total_minor_gc_time_ns = 0;
    uint64_t min_minor_gc_time_ns = UINT64_MAX;   ///< `UINT64_MAX` until a minor is recorded.
    uint64_t max_minor_gc_time_ns = 0;

    /// The number of buckets in each GC time histogram: `MINOR_BUCKETS_SMALL` narrow ones, then
    /// `MINOR_BUCKETS_LARGE` wide ones, then one for everything longer. For minors the buckets are
    /// 5 us wide up to 100 us, then 50 us wide up to 1 ms. Majors use the same layout scaled to
    /// 5 ms, 100 ms, 50 ms and 1 s.
    static constexpr int HISTOGRAM_BUCKETS = 39;
    /// The end of the minor histogram's narrow buckets, in nanoseconds (100 us).
    static constexpr uint64_t MINOR_HISTOGRAM_FIRST_RANGE = 100000;
    /// The end of the minor histogram's wide buckets, in nanoseconds (1 ms).
    static constexpr uint64_t MINOR_HISTOGRAM_SECOND_RANGE = 1000000;
    /// The width of a narrow minor bucket, in nanoseconds (5 us).
    static constexpr uint64_t MINOR_BUCKET_SIZE_SMALL = 5000;
    /// The width of a wide minor bucket, in nanoseconds (50 us).
    static constexpr uint64_t MINOR_BUCKET_SIZE_LARGE = 50000;
    /// The number of narrow buckets, in both time histograms.
    static constexpr int MINOR_BUCKETS_SMALL = 20;
    /// The number of wide buckets, in both time histograms.
    static constexpr int MINOR_BUCKETS_LARGE = 18;

    uint64_t minor_time_histogram[HISTOGRAM_BUCKETS] = {0};

    // ========== Allocation Size Histograms ==========
    //
    // Power-of-two buckets by allocation size in bytes: bucket k counts sizes in [8 << k, 8 << (k+1)),
    // bucket 0 also counts sizes under 8, and the last bucket counts everything from its lower bound
    // up. Bucket 1, [16, 32), has a sub-counter for [16, 24) so that the banner can print [16, 24)
    // and [24, 32) as separate rows, the first being where a boxed Int, Float or Char falls.
    //
    // The nursery histogram counts only allocations that go through the runtime's nursery allocate
    // call. Compiled code that allocates inline in the nursery is not counted, unless it was built
    // with `ECO_INLINE_ALLOC=0`.
    /// The number of nursery histogram buckets: [8, 16) up to [4096, 8192), then 8 KiB and over.
    static constexpr int NURSERY_ALLOC_BUCKETS = 11;
    /// The number of old-gen histogram buckets: [8, 16) up to [512 KiB, 1 MiB), then 1 MiB and over.
    static constexpr int OLDGEN_ALLOC_BUCKETS  = 18;
    /// The lowest size of bucket 0, in bytes.
    static constexpr size_t ALLOC_HISTOGRAM_BASE = 8;

    uint64_t nursery_alloc_size_histogram[NURSERY_ALLOC_BUCKETS] = {0};
    uint64_t oldgen_alloc_size_histogram[OLDGEN_ALLOC_BUCKETS]   = {0};

    // The [16, 24) part of bucket 1. Recorded at the same time as bucket 1, so it should not exceed
    // it; the banner clamps it in case merged records disagree.
    uint64_t nursery_alloc_size_16_24_count = 0;
    uint64_t oldgen_alloc_size_16_24_count  = 0;

    // ========== String Allocation Size Histogram ==========
    //
    // String allocations by heap-object size (header and characters, rounded to 8 bytes), in the
    // same buckets as the old-gen histogram, whatever storage the String then gets. The banner does
    // not split bucket 1 for it.
    /// The number of String histogram buckets, the same as `OLDGEN_ALLOC_BUCKETS`.
    static constexpr int STRING_ALLOC_BUCKETS = 18;
    uint64_t string_alloc_size_histogram[STRING_ALLOC_BUCKETS] = {0};

    // ========== UTF-8 -> UTF-16 Widen Events ==========
    //
    // A *widen* is the conversion of a String held as UTF-8 back to UTF-16. `utf8_widen_calls` and
    // `utf8_widen_units` count the widens reported through `GC_STATS_UTF8_WIDEN`, and the per-site
    // arrays count those reported through `GC_STATS_UTF8_WIDEN_SITE`, indexed by `Utf8WidenSite`.
    // The two are recorded separately: the sites before `UTF8_WIDEN_ROPE_CHILD` are expected to add
    // up to `utf8_widen_calls`, and the banner prints any excess of `utf8_widen_calls` over their
    // sum as unattributed. The last two sites are widens that `utf8_widen_calls` does not count.
    uint64_t utf8_widen_calls = 0;
    uint64_t utf8_widen_units = 0;      ///< In UTF-16 code units.

    /// The number of `Utf8WidenSite` values.
    static constexpr int UTF8_WIDEN_SITE_COUNT = 9;
    uint64_t utf8_widen_site_calls[UTF8_WIDEN_SITE_COUNT] = {0};
    uint64_t utf8_widen_site_units[UTF8_WIDEN_SITE_COUNT] = {0};

    // ========== Per-Kind Mutator Allocation Histogram ==========
    //
    // Mutator allocations by object tag, as reported through `GC_STATS_TLH_RECORD_ALLOC` when a
    // heap object's header is initialised for its tag. Objects whose headers are written another
    // way are not counted, such as copies made by the collector. Like the nursery histogram, this
    // misses inline allocation by compiled code unless it was built with `ECO_INLINE_ALLOC=0`.
    /// The number of `Tag` values, which index the per-tag arrays.
    static constexpr int NUM_ALLOC_TAGS = static_cast<int>(Tag_Forward) + 1;

    uint64_t tlh_alloc_count_by_tag[NUM_ALLOC_TAGS] = {0};
    uint64_t tlh_alloc_bytes_by_tag[NUM_ALLOC_TAGS] = {0};

    // ========== Per-Kind Retention Histograms ==========
    //
    // Objects copied by minors, by tag: *promoted* into the old generation, or *survived* (copied
    // within the nursery). They are counted by the collector as it copies, so inline allocation does
    // not affect them. A ratio of these to `tlh_alloc_count_by_tag` means something only for code
    // built with `ECO_INLINE_ALLOC=0`.
    uint64_t promoted_count_by_tag[NUM_ALLOC_TAGS] = {0};
    uint64_t promoted_bytes_by_tag[NUM_ALLOC_TAGS] = {0};
    uint64_t survived_count_by_tag[NUM_ALLOC_TAGS] = {0};
    uint64_t survived_bytes_by_tag[NUM_ALLOC_TAGS] = {0};

    // ========== Custom Arity Breakdown ==========
    //
    // Copied `Tag_Custom` objects by field count, which for a Custom is its header's `size`.
    /// The number of field-count buckets: 0 to 15 fields, then 16 or more.
    static constexpr int CUSTOM_ARITY_BUCKETS = 17;

    uint64_t custom_promoted_by_nfields[CUSTOM_ARITY_BUCKETS] = {0};
    uint64_t custom_promoted_bytes_by_nfields[CUSTOM_ARITY_BUCKETS] = {0};
    uint64_t custom_survived_by_nfields[CUSTOM_ARITY_BUCKETS] = {0};

    // ========== Old-Gen Page Residency Histogram ==========
    //
    // A snapshot at the end of each major of the old-gen blocks, each bucketed by its live fraction
    // (live bytes over the block's size). Each bucket adds up the blocks' sizes and splits them into
    // *live* bytes (reached by the mark), *free* bytes (on free lists left by the previous sweep) and
    // *garbage* (the rest: dead bytes the previous lazy sweep had not reached). Much free space
    // suggests fragmentation; much garbage, a sweep falling behind.
    //
    // The cumulative arrays add up every snapshot; the latest and pending arrays are the two halves
    // of the snapshot scheme the file comment describes.
    /// The number of live-fraction buckets: exactly 0, then (0, 0.01], (0.01, 0.05], (0.05, 0.10],
    /// (0.10, 0.25], (0.25, 0.50], (0.50, 0.75] and (0.75, 1].
    static constexpr int RESIDENCY_BUCKETS = 8;

    uint64_t residency_pages[RESIDENCY_BUCKETS]         = {0};   ///< Blocks, despite the name.
    uint64_t residency_page_bytes[RESIDENCY_BUCKETS]    = {0};
    uint64_t residency_live_bytes[RESIDENCY_BUCKETS]    = {0};
    uint64_t residency_garbage_bytes[RESIDENCY_BUCKETS] = {0};
    uint64_t residency_free_bytes[RESIDENCY_BUCKETS]    = {0};

    // The blocks recorded as holding one large object, also counted in the buckets above. Such a
    // block is not released by a sweep until its object dies.
    uint64_t residency_pinned_pages         = 0;
    uint64_t residency_pinned_page_bytes    = 0;
    uint64_t residency_pinned_live_bytes    = 0;
    uint64_t residency_pinned_garbage_bytes = 0;
    uint64_t residency_pinned_free_bytes    = 0;

    /// The number of completed snapshots, one per `recordResidencySnapshot`.
    uint64_t residency_snapshots = 0;

    // ---- The last completed snapshot ----
    //
    // Written only by `recordResidencySnapshot`, as a plain copy of the pending arrays.
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
    /// 1 once a snapshot is complete, 0 before. In a combined record, the number of records that
    /// had one, since `combine` adds the latest arrays of every record.
    uint64_t latest_residency_snapshots            = 0;

    // ---- The snapshot being recorded ----
    //
    // Cleared by `beginResidencySnapshot` and added to by `recordBlockResidency`. Not merged by
    // `combine`.
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
    // A snapshot of the old generation's free lists at the end of each major, by size class, with
    // the same cumulative, latest and pending parts as the residency histogram. It shows whether
    // unused old-gen bytes sit in small cells or in large ones.
    /// The number of size classes: 32 small classes of 8 to 256 bytes in steps of 8, then 8 medium
    /// classes of 512 bytes doubling. It must be at least `OldGenSpace`'s number of size classes, and
    /// a `static_assert` in OldGenSpace.cpp checks that; the banner computes each class's cell size
    /// from this layout.
    static constexpr int FREELIST_CLASS_BUCKETS = 40;
    uint64_t freelist_cells_by_class[FREELIST_CLASS_BUCKETS] = {0};
    uint64_t freelist_bytes_by_class[FREELIST_CLASS_BUCKETS] = {0};
    // Free whole blocks, which have no size class.
    uint64_t freelist_large_block_bytes  = 0;
    uint64_t freelist_large_block_count  = 0;
    /// The number of completed snapshots, one per `recordFreeListSnapshot`.
    uint64_t freelist_snapshots          = 0;

    // ---- The last completed snapshot, as for the residency histogram ----
    uint64_t latest_freelist_cells_by_class[FREELIST_CLASS_BUCKETS] = {0};
    uint64_t latest_freelist_bytes_by_class[FREELIST_CLASS_BUCKETS] = {0};
    uint64_t latest_freelist_large_block_bytes  = 0;
    uint64_t latest_freelist_large_block_count  = 0;
    /// 1 once a snapshot is complete; in a combined record, the number of records that had one.
    uint64_t latest_freelist_snapshots          = 0;

    // ---- The snapshot being recorded; not merged by `combine` ----
    uint64_t pending_freelist_cells_by_class[FREELIST_CLASS_BUCKETS] = {0};
    uint64_t pending_freelist_bytes_by_class[FREELIST_CLASS_BUCKETS] = {0};
    uint64_t pending_freelist_large_block_bytes  = 0;
    uint64_t pending_freelist_large_block_count  = 0;

    // ========== AllocBuffer Stats ==========
    // Counted by `GC_STATS_BUFFER_ALLOCATED` and `GC_STATS_BUFFER_FILLED`; the banner prints them
    // only when one is non-zero.
    uint64_t buffers_allocated = 0;
    uint64_t buffers_filled = 0;

    // ========== Major GC Event Stats ==========
    uint64_t concurrent_marks_started = 0;
    uint64_t mark_sweeps_completed = 0;
    uint64_t incremental_mark_calls = 0;
    uint64_t total_incremental_mark_work_units = 0;

    // Majors counted by what triggered them. The occupancy, garbage and global-pressure counters
    // are meant for the triggers the old generation evaluates, and the alloc-failure counter for an
    // allocation that could not be satisfied. Which reasons share a counter is the caller's choice.
    uint64_t major_gc_occupancy_triggers     = 0;
    uint64_t major_gc_alloc_failure_triggers = 0;
    uint64_t major_gc_garbage_triggers       = 0;
    uint64_t major_gc_global_pressure_triggers = 0;

    // ========== Allocator time in the mutator ==========
    //
    // Allocator work done on the mutator's behalf outside a collection, so that the banner can
    // split it from the mutator's own time. The banner's "Allocator Timings" block treats these as
    // parts of the run's wall time that do not overlap:
    //
    //   wall = minor + major + old-gen alloc in mutator + nursery alloc in mutator + true mutator
    //
    // The shrink and post-sweep times are nested inside those parts, so the banner shows them apart
    // and does not add them: it labels a heavy shrink pass as part of a major, a light one as part of
    // a post-sweep shrink, and a post-sweep shrink as part of old-gen allocation.
    /// Time in old-gen allocation called from the mutator, not from a minor's promotions.
    uint64_t total_oldgen_alloc_in_mutator_ns = 0;
    /// Time in the work run when a lazy sweep completes.
    uint64_t total_post_sweep_shrink_ns       = 0;
    uint64_t total_maybe_shrink_heavy_ns      = 0;
    uint64_t total_maybe_shrink_light_ns      = 0;
    /// Time in the forced shrink pass of an explicit release (HEAP_076), inside that release's pause.
    uint64_t total_maybe_shrink_forced_ns     = 0;

    /// Time in the nursery's allocation slow path called from the mutator.
    uint64_t total_nursery_alloc_in_mutator_ns = 0;

    /// The run's wall time in nanoseconds, for the banner's "True mutator" line and the MMU table.
    /// 0 means not set, and the banner then leaves those out. `combine` and `reset` leave it alone;
    /// the code that builds a combined record is expected to set it.
    uint64_t wall_time_ns = 0;

    // ========== Lazy-sweep pacing (bytes) ==========
    /// Bytes of sweeping requested by the allocation slow path, summed: what was asked for, not
    /// what was swept.
    uint64_t total_lazy_sweep_bytes_in_mutator = 0;
    /// Bytes of sweeping requested by the old generation's last-resort path, run when an allocation
    /// can get no more space any other way.
    uint64_t total_panic_sweep_bytes = 0;

    // ========== Split-Header Large-Body Minor-Reclaim Stats ==========
    //
    // At the end of each minor, the old generation frees the bodies of large Strings and Bytes whose
    // nursery headers died. It skips that sweep while a compaction is running, and those bodies wait
    // for a later minor.
    uint64_t large_body_minor_sweep_runs        = 0;
    /// Minors whose large-body sweep was skipped because a compaction was running.
    uint64_t large_body_minor_sweep_skips       = 0;
    /// Cell bytes freed by the sweeps that ran.
    uint64_t large_body_minor_freed_bytes       = 0;
    /// Cell bytes a skipped sweep would have freed. They wait for a later minor, not for a major,
    /// whatever the name says; a body still dead at the next skip is counted again.
    uint64_t large_body_deferred_to_major_bytes = 0;

    // ========== Major GC Timing Stats ==========
    uint64_t major_gc_count = 0;
    uint64_t total_major_gc_time_ns = 0;
    uint64_t min_major_gc_time_ns = UINT64_MAX;   ///< `UINT64_MAX` until a major is recorded.
    uint64_t max_major_gc_time_ns = 0;

    /// Major times, in the layout `HISTOGRAM_BUCKETS` describes.
    uint64_t major_time_histogram[HISTOGRAM_BUCKETS] = {0};

    // ========== Per-major-GC event log ==========
    //
    // One entry per completed major, in a fixed array so that recording one allocates nothing.
    /// The most majors kept in `major_gc_events`; later ones are only counted in
    /// `major_gc_events_dropped`.
    static constexpr size_t MAJOR_GC_EVENT_CAP = 512;

    /// Why a major collection ran: the triggers of `OldGenSpace::MajorGCTriggerReason` with the same
    /// names, and the causes that are not triggers. The values are stored in `MajorGCEvent`, and
    /// `gcMajorReasonName` gives each a name.
    enum class MajorReason : uint8_t {
        Unknown        = 0,   ///< Not recorded, or a trigger with no matching value.
        Occupancy      = 1,
        GlobalPressure = 2,
        GarbageFraction = 3,
        AllocFailure   = 4,   ///< An allocation failed and the collection is its retry.
        Forced         = 5,   ///< Requested directly rather than by a trigger.
        LiveBudget     = 6,
        Headroom       = 7,
        Explicit       = 8,   ///< An explicit collect-and-release (HEAP_076).
    };

    /// One completed major. Times are nanoseconds, sizes bytes.
    struct MajorGCEvent {
        uint64_t seq              = 0;  ///< `major_gc_count` when it was recorded.
        uint64_t start_ns         = 0;  ///< Process-relative.
        uint64_t total_ns         = 0;
        uint64_t root_scan_ns     = 0;
        uint64_t root_push_ns     = 0;
        uint64_t mark_ns          = 0;
        uint64_t sweep_ns         = 0;
        uint64_t capacity_ns      = 0;
        // The old generation's allocated bytes either side of the major. The sweep is lazy, so
        // `before - after` understates what the major found dead; `garbage_bytes` is that figure.
        uint64_t oldgen_before_bytes = 0;
        uint64_t oldgen_after_bytes  = 0;
        uint64_t committed_bytes     = 0;  ///< As passed to `beginMajorGCEvent`.
        // What the mark found, and what was released at once.
        uint64_t live_bytes_after    = 0;
        uint64_t garbage_bytes       = 0;
        uint64_t alldead_bytes_released = 0;
        uint64_t shrink_bytes_released  = 0;
        // Work done.
        uint64_t mark_units       = 0;
        uint64_t mark_stack_peak  = 0;
        uint64_t blocks_scanned   = 0;
        // Minors and promoted objects since the previous recorded major.
        uint64_t minors_since_prev   = 0;
        uint64_t promoted_since_prev = 0;
        MajorReason reason = MajorReason::Unknown;
    };

    MajorGCEvent major_gc_events[MAJOR_GC_EVENT_CAP];
    size_t   major_gc_events_used = 0;
    uint64_t major_gc_events_dropped = 0;

    // The open major, set by `beginMajorGCEvent` and read by `recordMajorGCEvent`.
    uint64_t pending_major_start_ns      = 0;
    uint64_t pending_major_before_bytes  = 0;
    uint64_t pending_major_committed     = 0;
    MajorReason pending_major_reason     = MajorReason::Unknown;
    // The counts passed to the last `recordMajorGCEvent`, from which the next computes its deltas.
    uint64_t last_major_minor_count      = 0;
    uint64_t last_major_promoted         = 0;

    // ========== Sub-records ==========
    GCPhaseTotals tg;   ///< Minor phase totals and the pause log.

    BitmapAllocStats bm;
    /// Prints the bitmap allocation block, unless `bm.any()` is false. The sweep-tail and flip
    /// counters are not printed.
    void printBitmapAllocBlock() const;

    PageSupplyStats page_supply;
    HelperStatsSnapshot helper;
    LargePtrStats lp;
    ParMinorStats pmin;
    RegionTenureStats rg;
    /// Prints the region nursery block, unless `rg.any()` is false.
    void printRegionBlock() const;
    IncrMarkStats im;
    ParMarkStats pm;
    ConcMarkStats cm;
    /// Prints the large-allocation block, unless `lp.any()` is false.
    void printLargePtrBlock() const;
    /// Prints the parallel minor block, unless `pmin.any()` is false.
    void printParMinorBlock() const;
    /// Prints the concurrent mark block, unless `cm.any()` is false and `cm.mutator_cpu_ns` is 0.
    void printConcMarkBlock() const;
    /// Prints the incremental mark block, unless `im.any()` is false.
    void printIncrMarkBlock() const;
    /// Prints the parallel mark block, unless `pm.any()` is false.
    void printParMarkBlock() const;
    /// Prints the page supply block, unless `page_supply.any()` is false.
    void printPageSupplyBlock() const;
    /// Prints the helper thread block, unless `helper.mode` is 0.
    void printHelperBlock() const;

    /// Prints the pause distribution (with the MMU tables when `wall_time_ns` is set), the minor
    /// phase breakdown and the external root scanner block, each only when `tg` has data for it.
    /// `print` calls it only when `ENABLE_GC_PHASE_TIMERS` is on.
    void printThreadedGcBlocks() const;

    // ========== Methods ==========

    /// Counts a nursery allocation of `bytes`: in `objects_allocated`, `bytes_allocated` and the
    /// nursery size histogram.
    void recordAllocation(size_t bytes);

    /// Counts an old-gen allocation of `bytes` in the old-gen size histogram only. It does not
    /// count it in `objects_allocated` or `bytes_allocated`, nor say where the allocation came
    /// from; `recordOldGenDirectAllocation` counts the totals.
    void recordOldGenAllocation(size_t bytes);
    /// Returns the old-gen size-histogram bucket of `bytes`, for a worker that counts allocations
    /// in a private array.
    static size_t oldGenAllocBucket(size_t bytes);
    /// Adds a private old-gen histogram to this record. `buckets` must hold `OLDGEN_ALLOC_BUCKETS`
    /// counts; `c16_24` is its [16, 24) count.
    void mergeOldGenAllocHistogram(const uint64_t* buckets, uint64_t c16_24);

    /// Counts an allocation of `bytes` made directly in the old generation for the mutator, in
    /// `objects_allocated` and `bytes_allocated`, so that those totals include allocations that do
    /// not go through the nursery. It does not touch the old-gen size histogram, which
    /// `recordOldGenAllocation` feeds.
    void recordOldGenDirectAllocation(size_t bytes);

    /// Counts a mutator allocation of `bytes` with tag `tag` in the per-tag arrays. A tag outside
    /// [0, `NUM_ALLOC_TAGS`) is ignored.
    void recordTLHAllocation(size_t bytes, Tag tag);

    /// Returns the field-count bucket for a Custom with `nfields` fields: `nfields`, or the last
    /// bucket for 16 or more.
    static int customArityBucket(uint32_t nfields) {
        return nfields >= static_cast<uint32_t>(CUSTOM_ARITY_BUCKETS)
            ? CUSTOM_ARITY_BUCKETS - 1
            : static_cast<int>(nfields);
    }

    /// Counts one object of `tag` and `bytes` promoted by a minor: in `objects_promoted` always,
    /// and in the per-tag arrays when `tag` is in range. For a `Tag_Custom`, `nfields` is its field
    /// count and also feeds the field-count arrays; for other tags it is ignored. Defined here so
    /// that the collector's per-object copy paths can inline it.
    inline void recordPromotion(Tag tag, size_t bytes, uint32_t nfields) {
        objects_promoted++;
        int idx = static_cast<int>(tag);
        if (idx < 0 || idx >= NUM_ALLOC_TAGS) return;
        promoted_count_by_tag[idx]++;
        promoted_bytes_by_tag[idx] += bytes;
        if (tag == Tag_Custom) {
            int b = customArityBucket(nfields);
            custom_promoted_by_nfields[b]++;
            custom_promoted_bytes_by_nfields[b] += bytes;
        }
    }
    /// Counts one object copied within the nursery by a minor, as `recordPromotion` does for a
    /// promoted one. Only the count, not the bytes, goes into the field-count array.
    inline void recordSurvival(Tag tag, size_t bytes, uint32_t nfields) {
        objects_survived++;
        int idx = static_cast<int>(tag);
        if (idx < 0 || idx >= NUM_ALLOC_TAGS) return;
        survived_count_by_tag[idx]++;
        survived_bytes_by_tag[idx] += bytes;
        if (tag == Tag_Custom)
            custom_survived_by_nfields[customArityBucket(nfields)]++;
    }

    /// One worker's private copy of the counters `recordPromotion` and `recordSurvival` write, so
    /// that several threads copying objects at once each count without sharing a `GCStats`. The
    /// owner adds the workers' counts into its record with `mergeCopyCounts` once they have
    /// stopped.
    struct MinorCopyCounts {
        uint64_t survived = 0, promoted = 0;
        uint64_t survived_count[NUM_ALLOC_TAGS] = {0};
        uint64_t survived_bytes[NUM_ALLOC_TAGS] = {0};
        uint64_t promoted_count[NUM_ALLOC_TAGS] = {0};
        uint64_t promoted_bytes[NUM_ALLOC_TAGS] = {0};
        uint64_t custom_promoted[CUSTOM_ARITY_BUCKETS] = {0};
        uint64_t custom_promoted_bytes[CUSTOM_ARITY_BUCKETS] = {0};
        uint64_t custom_survived[CUSTOM_ARITY_BUCKETS] = {0};
        /// Counts a promoted object, as `GCStats::recordPromotion` does.
        inline void promotion(Tag tag, size_t bytes, uint32_t nfields) {
            promoted++;
            const int idx = static_cast<int>(tag);
            if (idx < 0 || idx >= NUM_ALLOC_TAGS) return;
            promoted_count[idx]++;
            promoted_bytes[idx] += bytes;
            if (tag == Tag_Custom) {
                const int b = customArityBucket(nfields);
                custom_promoted[b]++;
                custom_promoted_bytes[b] += bytes;
            }
        }
        /// Counts a surviving object, as `GCStats::recordSurvival` does.
        inline void survival(Tag tag, size_t bytes, uint32_t nfields) {
            survived++;
            const int idx = static_cast<int>(tag);
            if (idx < 0 || idx >= NUM_ALLOC_TAGS) return;
            survived_count[idx]++;
            survived_bytes[idx] += bytes;
            if (tag == Tag_Custom) custom_survived[customArityBucket(nfields)]++;
        }
        /// Sets every count to 0.
        void reset() { *this = MinorCopyCounts{}; }
        /// Adds every count of `o` to this one.
        void add(const MinorCopyCounts& o) {
            survived += o.survived;
            promoted += o.promoted;
            for (int i = 0; i < NUM_ALLOC_TAGS; ++i) {
                survived_count[i] += o.survived_count[i];
                survived_bytes[i] += o.survived_bytes[i];
                promoted_count[i] += o.promoted_count[i];
                promoted_bytes[i] += o.promoted_bytes[i];
            }
            for (int b = 0; b < CUSTOM_ARITY_BUCKETS; ++b) {
                custom_promoted[b] += o.custom_promoted[b];
                custom_promoted_bytes[b] += o.custom_promoted_bytes[b];
                custom_survived[b] += o.custom_survived[b];
            }
        }
    };
    /// Adds a worker's copy counts `c` into this record's totals, per-tag and field-count arrays.
    void mergeCopyCounts(const MinorCopyCounts& c) {
        objects_survived += c.survived;
        objects_promoted += c.promoted;
        for (int i = 0; i < NUM_ALLOC_TAGS; ++i) {
            survived_count_by_tag[i] += c.survived_count[i];
            survived_bytes_by_tag[i] += c.survived_bytes[i];
            promoted_count_by_tag[i] += c.promoted_count[i];
            promoted_bytes_by_tag[i] += c.promoted_bytes[i];
        }
        for (int b = 0; b < CUSTOM_ARITY_BUCKETS; ++b) {
            custom_promoted_by_nfields[b] += c.custom_promoted[b];
            custom_promoted_bytes_by_nfields[b] += c.custom_promoted_bytes[b];
            custom_survived_by_nfields[b] += c.custom_survived[b];
        }
    }

    /// Counts a String allocation whose heap object is `bytes` long in the String size histogram.
    void recordStringAllocation(size_t bytes);

    /// Counts one widen of `units` UTF-16 code units in `utf8_widen_calls` and `utf8_widen_units`.
    void recordUtf8Widen(size_t units);

    /// Counts one widen of `units` code units at `site`, a `Utf8WidenSite`. A `site` out of range
    /// is ignored. It does not touch `utf8_widen_calls`.
    void recordUtf8WidenSite(int site, size_t units);

    /// Counts one minor that took `elapsed_ns` and reclaimed `freed` bytes: in `minor_gc_count`,
    /// the minor time total, minimum, maximum and histogram, and `bytes_freed`.
    void recordMinorGCEnd(uint64_t elapsed_ns, size_t freed);

    /// Counts one major that took `elapsed_ns`: in `major_gc_count` and the major time total,
    /// minimum, maximum and histogram.
    void recordMajorGCEnd(uint64_t elapsed_ns);

    /// Returns the steady-clock nanoseconds since the static initialisation of GCStats.cpp: the
    /// origin of every process-relative time in this component.
    static uint64_t nowSinceProcessStartNs();
    /// Returns that origin as a steady-clock time since the clock's epoch, in nanoseconds, so that a
    /// steady-clock reading taken elsewhere can be made process-relative by subtracting it.
    static uint64_t processStartSteadyNs();

    /// Opens a major's event-log entry, recording the current process-relative time, `reason`, and
    /// the old generation's allocated bytes and committed bytes before the major. A second call
    /// before `recordMajorGCEvent` replaces the first.
    void beginMajorGCEvent(MajorReason reason,
                           uint64_t oldgen_before_bytes,
                           uint64_t committed_bytes);

    /// Closes the entry opened by `beginMajorGCEvent` and appends it to `major_gc_events`, or counts
    /// it in `major_gc_events_dropped` when the array is full.
    ///
    /// The entry's `seq` is `major_gc_count`, so `recordMajorGCEnd` should be called first.
    /// `minor_count_now` and `promoted_now` are the current minor count and promoted-object count
    /// of whichever record holds them; the entry stores their increase since the previous call
    /// (or since the record was created or reset), and they become the base for the next. A
    /// dropped entry does not move that base.
    void recordMajorGCEvent(uint64_t total_ns,
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
                            uint64_t promoted_now);

    /// Prints `major_gc_events` as a table, one row per major, or a line saying there are none.
    void printMajorGCEventLog() const;

    /// Adds one old-gen block of `total_bytes`, of which `live_bytes` were reached by the mark and
    /// `free_bytes` are on free lists, to the cumulative and pending residency arrays, and to the
    /// pinned totals when `is_large`. The rest of the block counts as garbage. `live_bytes` is
    /// clamped to `total_bytes` and `free_bytes` to what is left after it; a block of 0 bytes is
    /// ignored.
    void recordBlockResidency(size_t total_bytes,
                              size_t live_bytes,
                              size_t free_bytes,
                              bool   is_large);

    /// Starts a residency snapshot by clearing the pending arrays. The latest and cumulative arrays
    /// are left as they are.
    void beginResidencySnapshot();

    /// Completes a residency snapshot: copies the pending arrays into the latest ones, sets
    /// `latest_residency_snapshots` to 1 and adds one to `residency_snapshots`. The pending arrays
    /// keep their values until the next `beginResidencySnapshot`.
    void recordResidencySnapshot();

    /// Adds `cell_count` free cells of `cell_bytes` bytes in all, in size class `size_class`, to the
    /// cumulative and pending free-list arrays. A class at or past `FREELIST_CLASS_BUCKETS` is
    /// ignored.
    void recordFreeListClass(size_t size_class,
                             uint64_t cell_count,
                             uint64_t cell_bytes);

    /// Adds `block_count` free whole blocks of `total_bytes` bytes in all to the cumulative and
    /// pending free-list totals.
    void recordFreeListLargeBlocks(uint64_t block_count,
                                   uint64_t total_bytes);

    /// Starts a free-list snapshot by clearing the pending free-list arrays. The latest and
    /// cumulative arrays are left as they are.
    void beginFreeListSnapshot();

    /// Completes a free-list snapshot: copies the pending arrays into the latest ones, sets
    /// `latest_freelist_snapshots` to 1 and adds one to `freelist_snapshots`.
    void recordFreeListSnapshot();

    /// Merges `other` into this record: counts and histograms add, minima and maxima take the
    /// smaller or larger, the sub-records merge as their own comments say, and `other`'s major
    /// events are appended up to the cap. The pending snapshot arrays, the open major
    /// (`pending_major_*`), `last_major_*` and `wall_time_ns` are left as they are.
    void combine(const GCStats& other);

    /// Writes the stats banner to standard output.
    ///
    /// Besides this record, it reads `Allocator::getOldGenMaxBytes` for the old-gen lines, the
    /// `PermanentSpace` counters, and, when the calling thread has a heap, the sizes of the
    /// allocator's root set. Which blocks appear depends on what was recorded; the phase-timer blocks
    /// appear only when `ENABLE_GC_PHASE_TIMERS` is on.
    void print() const;

    /// Empties the record, as if newly constructed, except that `wall_time_ns` keeps its value and
    /// the entries of `major_gc_events` are not cleared (only `major_gc_events_used` is).
    void reset();

private:
    /// Returns the `minor_time_histogram` bucket of a minor lasting `ns`.
    size_t getMinorHistogramBucket(uint64_t ns) const;
    /// Returns the `major_time_histogram` bucket of a major lasting `ns`.
    size_t getMajorHistogramBucket(uint64_t ns) const;
};

// ============================================================================
// Per-Thread Stats Lookup Helper
// ============================================================================
//
// Some allocation and String code has no `GCStats` at hand. These functions find the calling
// thread's heap through the `Allocator` singleton and record into that heap's own `GCStats`; on a
// thread with no heap they do nothing. They are defined in GCStats.cpp, where `Allocator.hpp` can be
// included without an include cycle. They are declared, and compiled, whatever `ENABLE_GC_STATS`
// is; with statistics off their bodies do nothing.

/// Records a mutator allocation of `bytes` with tag `tag` in the calling thread's heap, as
/// `GCStats::recordTLHAllocation` does.
void recordTLHAllocOnCurrentThread(size_t bytes, Tag tag) noexcept;

/// Records a String allocation of `bytes` in the calling thread's heap, as
/// `GCStats::recordStringAllocation` does.
void recordStringAllocOnCurrentThread(size_t bytes) noexcept;

/// Records a widen of `units` code units in the calling thread's heap, as
/// `GCStats::recordUtf8Widen` does.
void recordUtf8WidenOnCurrentThread(size_t units) noexcept;

/// The String operations that report a widen of a UTF-8 String to UTF-16, which index the per-site
/// widen counters. The values are array indices and must stay dense from 0, with
/// `GCStats::UTF8_WIDEN_SITE_COUNT` equal to their number.
///
/// The sites before `UTF8_WIDEN_ROPE_CHILD` widen whole Strings, and each such widen is also
/// expected to be counted in `GCStats::utf8_widen_calls`. The last two are widens that counter does
/// not include.
enum Utf8WidenSite : int {
    UTF8_WIDEN_TRIM = 0,       ///< `trim`, `trimLeft` and `trimRight`.
    UTF8_WIDEN_TO_LIST,        ///< `String.toList`.
    UTF8_WIDEN_INDEXES,        ///< `String.indexes`, counted for the needle and the haystack each.
    UTF8_WIDEN_SPLIT_MIXED,    ///< `String.split` with operands in different encodings.
    UTF8_WIDEN_APPEND_MIXED,   ///< Appending Strings in different encodings; the UTF-8 side only.
    UTF8_WIDEN_ENSURE_FLAT,    ///< Flattening a String into one UTF-16 leaf.
    UTF8_WIDEN_B64HEX,         ///< Decoding Bytes from Base64 or hex text.
    UTF8_WIDEN_ROPE_CHILD,     ///< A UTF-8 child widened while a rope is converted.
    UTF8_WIDEN_SEGMENT_CHUNK,  ///< A UTF-8 segment widened in chunks while segments are visited.
};

/// Records a widen of `units` code units at `site` in the calling thread's heap, as
/// `GCStats::recordUtf8WidenSite` does.
void recordUtf8WidenSiteOnCurrentThread(int site, size_t units) noexcept;

/// Returns the lower-case name of `r` used in the banner and the event log, such as "occupancy" or
/// "alloc-failure"; "unknown" for `MajorReason::Unknown` or a value outside the enumeration. The
/// string is a literal.
const char* gcMajorReasonName(GCStats::MajorReason r);

/// Returns the short name of heap tag `tag`, such as "Custom" for `Tag_Custom`, or "<unknown>" for
/// a value that is not a tag. The string is a literal.
const char* gcTagName(int tag);

// ============================================================================
// Recording macros
// ============================================================================
//
// The collector records through these macros so that a build without statistics has no recording
// code at all. With `ENABLE_GC_STATS` on, each expands to the call or increment its name describes,
// as one statement; with it off, each recording macro expands to an empty statement and does not
// evaluate its arguments, and the two timer macros expand to 0. Arguments are evaluated once, except
// `stats` in `GC_STATS_MAJOR_INC_INCREMENTAL_MARK`, which is evaluated twice; pass an lvalue with no
// side effects.

#if ENABLE_GC_STATS
    // ========== Minor GC Macros ==========

    /// Calls `GCStats::recordAllocation` on `stats`.
    #define GC_STATS_MINOR_RECORD_ALLOC(stats, bytes) \
        do { (stats).recordAllocation(bytes); } while(0)

    /// Calls `GCStats::recordOldGenAllocation` on `stats`.
    #define GC_STATS_OLDGEN_RECORD_ALLOC(stats, bytes) \
        do { (stats).recordOldGenAllocation(bytes); } while(0)

    /// Calls `GCStats::recordOldGenDirectAllocation` on `stats`.
    #define GC_STATS_OLDGEN_DIRECT_RECORD_ALLOC(stats, bytes) \
        do { (stats).recordOldGenDirectAllocation(bytes); } while(0)

    /// Records a mutator allocation by tag in the calling thread's heap, through
    /// `recordTLHAllocOnCurrentThread`, for code with no `GCStats` at hand.
    #define GC_STATS_TLH_RECORD_ALLOC(bytes, tag) \
        do { ::Elm::recordTLHAllocOnCurrentThread((bytes), (tag)); } while(0)

    /// Records a String allocation in the calling thread's heap, through
    /// `recordStringAllocOnCurrentThread`.
    #define GC_STATS_STRING_RECORD_ALLOC(bytes) \
        do { ::Elm::recordStringAllocOnCurrentThread((bytes)); } while(0)

    /// Records a widen of `units` UTF-16 code units in the calling thread's heap, through
    /// `recordUtf8WidenOnCurrentThread`.
    #define GC_STATS_UTF8_WIDEN(units) \
        do { ::Elm::recordUtf8WidenOnCurrentThread((units)); } while(0)

    /// Records a widen at `site`, a `Utf8WidenSite`, in the calling thread's heap, through
    /// `recordUtf8WidenSiteOnCurrentThread`.
    #define GC_STATS_UTF8_WIDEN_SITE(site, units) \
        do { ::Elm::recordUtf8WidenSiteOnCurrentThread((site), (units)); } while(0)

    /// Adds one to `stats.ensure_slow_calls` (HEAP_041).
    #define GC_STATS_ENSURE_SLOW_CALL(stats) \
        do { (stats).ensure_slow_calls++; } while(0)

    /// Calls `GCStats::recordMinorGCEnd` on `stats`.
    #define GC_STATS_MINOR_RECORD_GC_END(stats, elapsed_ns, freed) \
        do { (stats).recordMinorGCEnd(elapsed_ns, freed); } while(0)

    /// Calls `GCStats::recordSurvival` on `stats`. `tag` may be any integer type, such as a header's
    /// tag bit-field, and is cast to `Tag` here; `nfields` is the object header's `size`.
    #define GC_STATS_MINOR_INC_SURVIVORS(stats, tag, bytes, nfields) \
        do { (stats).recordSurvival(static_cast<Tag>(tag), (bytes), (nfields)); } while(0)

    /// Calls `GCStats::recordPromotion` on `stats`, with `tag` and `nfields` as for
    /// `GC_STATS_MINOR_INC_SURVIVORS`.
    #define GC_STATS_MINOR_INC_PROMOTED(stats, tag, bytes, nfields) \
        do { (stats).recordPromotion(static_cast<Tag>(tag), (bytes), (nfields)); } while(0)

    // ========== Major GC Macros ==========
    /// Calls `GCStats::recordMajorGCEnd` on `stats`.
    #define GC_STATS_MAJOR_RECORD_GC_END(stats, elapsed_ns) \
        do { (stats).recordMajorGCEnd(elapsed_ns); } while(0)

    /// Adds one to `stats.concurrent_marks_started`.
    #define GC_STATS_MAJOR_INC_CONCURRENT_MARK(stats) \
        do { (stats).concurrent_marks_started++; } while(0)

    /// Adds one to `stats.mark_sweeps_completed`.
    #define GC_STATS_MAJOR_INC_MARK_SWEEP(stats) \
        do { (stats).mark_sweeps_completed++; } while(0)

    /// Counts one incremental mark step that did `work_units` units of work.
    #define GC_STATS_MAJOR_INC_INCREMENTAL_MARK(stats, work_units) \
        do { \
            (stats).incremental_mark_calls++; \
            (stats).total_incremental_mark_work_units += (work_units); \
        } while(0)

    // ========== AllocBuffer Macros ==========
    /// Adds one to `stats.buffers_allocated`.
    #define GC_STATS_BUFFER_ALLOCATED(stats) \
        do { (stats).buffers_allocated++; } while(0)

    /// Adds one to `stats.buffers_filled`.
    #define GC_STATS_BUFFER_FILLED(stats) \
        do { (stats).buffers_filled++; } while(0)

    // ========== Helper Macros ==========
    /// Reads `std::chrono::high_resolution_clock`, as the start of an interval for
    /// `GC_STATS_TIMER_ELAPSED_NS`. Unlike the other macros it is an expression.
    #define GC_STATS_TIMER_START() \
        std::chrono::high_resolution_clock::now()

    /// Returns the nanoseconds since `start`, a value from `GC_STATS_TIMER_START`, as an expression.
    #define GC_STATS_TIMER_ELAPSED_NS(start) \
        std::chrono::duration_cast<std::chrono::nanoseconds>( \
            std::chrono::high_resolution_clock::now() - (start)).count()

#else
    // Statistics off: every recording macro is an empty statement, and the timer macros are 0.
    #define GC_STATS_MINOR_RECORD_ALLOC(stats, bytes) do {} while(0)
    #define GC_STATS_OLDGEN_RECORD_ALLOC(stats, bytes) do {} while(0)
    #define GC_STATS_OLDGEN_DIRECT_RECORD_ALLOC(stats, bytes) do {} while(0)
    #define GC_STATS_TLH_RECORD_ALLOC(bytes, tag) do {} while(0)
    #define GC_STATS_STRING_RECORD_ALLOC(bytes) do {} while(0)
    #define GC_STATS_UTF8_WIDEN(units) do {} while(0)
    #define GC_STATS_UTF8_WIDEN_SITE(site, units) do {} while(0)
    #define GC_STATS_ENSURE_SLOW_CALL(stats) do {} while(0)
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
