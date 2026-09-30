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
#include <vector>

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

// threaded-gc-01: the former thread_local g_in_minor_gc is now per-heap
// state, OldGenSpace::in_minor_gc_ / NurserySpace::minor_gc_running_
// (HEAP_053).

// ============================================================================
// threaded-gc-00: minor-GC phase breakdown and pause accounting
// ============================================================================
//
// Instruments only (plans/threaded-gc-00-measure-and-fix.md). Nothing here
// may feed a GC decision: GC counters must stay bit-identical with or
// without them. Populated only under ENABLE_GC_STATS.

// Compile-time switch for everything in this section: CMake option
// ECO_GC_PHASE_TIMERS (default OFF) defines ENABLE_GC_PHASE_TIMERS=1. It
// requires ECO_GC_STATS. Measured cost when compiled in: +1.52 s GC (+2.3 %)
// on the self-compile (benchmarks/gc-opt-loop.md entry T00), hence opt-in.
// The types and print-time helpers below are always compiled (cold code,
// and the unit tests use them); only the hot-path call sites are gated.
#ifndef ENABLE_GC_PHASE_TIMERS
#define ENABLE_GC_PHASE_TIMERS 0
#endif
#if ENABLE_GC_PHASE_TIMERS && !ENABLE_GC_STATS
#error "ENABLE_GC_PHASE_TIMERS (CMake ECO_GC_PHASE_TIMERS) requires ENABLE_GC_STATS (ECO_GC_STATS)"
#endif

// Deterministic 1-in-2^K sampler for per-object paths. Counter-based, no
// randomness, so it never perturbs anything compared across runs.
template <unsigned K>
struct SampledTimer {
    uint64_t calls = 0;
    uint64_t sampled_calls = 0;
    uint64_t sampled_ns = 0;
    bool shouldSample() noexcept {
        return ((calls++) & ((uint64_t{1} << K) - 1)) == 0;
    }
};

// Calibrated cost of one clock-read bracket with nothing inside it (the
// minimum of 2000 back-to-back reads, measured once per process).
uint64_t gcClockOverheadNs() noexcept;

// Scales a sampled time to all calls: sampled_ns * calls / sampled_calls,
// after subtracting the calibrated clock overhead of every sampled bracket.
inline uint64_t sampledEstimateNs(uint64_t d_sampled_ns, uint64_t d_calls,
                                  uint64_t d_sampled_calls) noexcept {
    if (d_sampled_calls == 0) return 0;
    const uint64_t ovh = gcClockOverheadNs() * d_sampled_calls;
    d_sampled_ns = d_sampled_ns > ovh ? d_sampled_ns - ovh : 0;
    return static_cast<uint64_t>(static_cast<double>(d_sampled_ns) *
                                 static_cast<double>(d_calls) /
                                 static_cast<double>(d_sampled_calls));
}

constexpr int GC_EXT_SCANNER_CAP = 16;

// One minor collection's measurements. Filled by ThreadLocalHeap (stack
// walk, pause) and NurserySpace (everything inside the nursery pause), then
// recorded once by ThreadLocalHeap::recordMinorPhases.
struct MinorGCRecord {
    uint64_t start_ns = 0;             // process-relative, at the stack-walk start
    uint64_t stack_walk_ns = 0;
    uint64_t frames_walked = 0;
    uint64_t frames_matched = 0;
    uint64_t stack_slots = 0;
    uint64_t roots_longlived_jit_ns = 0;   // phases 1a + 1c
    uint64_t roots_stackmap_ns = 0;        // phase 1b
    uint64_t roots_ranges_ns = 0;          // phases 1e + 1e'
    uint64_t roots_external_ns = 0;        // phase 1d
    int      ext_count = 0;
    uint64_t ext_ns[GC_EXT_SCANNER_CAP] = {0};
    uint64_t ext_slots[GC_EXT_SCANNER_CAP] = {0};
    uint64_t drain_tospace_ns = 0;
    uint64_t drain_promoted_ns = 0;
    uint64_t drain_rounds = 0;
    uint64_t tail_ns = 0;              // drain exit -> end of the nursery timer
    uint64_t nursery_pause_ns = 0;     // == the existing "Minor GC Timing" per-cycle value
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
    uint64_t pause_ns = 0;             // whole ThreadLocalHeap::minorGC, excl. a nested major
    // threaded-gc-06 (P§3.12): a parallel minor (workers > 1, or the forced
    // one-worker engine). drain_tospace/promoted stay 0 on such a minor.
    uint64_t workers = 1;
    uint64_t par_sweep_ns = 0;         // the pre-drain sweep slice (P§3.8.5)
    uint64_t par_roots_ns = 0;         // the serial root phase
    uint64_t par_drain_ns = 0;         // the gang run
    uint64_t par_close_ns = 0;         // LAB close + merge + cursor return
    uint64_t filler_bytes = 0;
    uint64_t mutex_wait_ns = 0;
    uint64_t imbalance_units = 0;      // max - min entries scanned per worker
    // threaded-gc-07 (P§3.20): region-nursery columns (zero in legacy mode).
    uint64_t rg_region = 0;
    uint64_t rg_merge_ns = 0;
    uint64_t rg_heal_slots = 0;
    uint64_t rg_zapped = 0, rg_zap_ns = 0;   // threaded-gc-07b
    uint64_t rg_heal_ns = 0;
    uint64_t rg_wait_ns = 0;
    uint64_t rg_help_ns = 0;
    uint64_t rg_help_workers = 0;
    uint64_t rg_late = 0;
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
    uint64_t rg_fill_obj_bytes = 0;
    uint64_t rg_bld_bytes = 0;
    uint64_t rg_epoch_ns = 0;
};

// One contiguous mutator stop on one thread.
struct PauseEvent {
    uint64_t start_ns;
    uint64_t dur_ns;
    uint8_t  kind;   // 0 = minor only, 1 = minor + nested major, 2 = major only,
                     // 3 = minor + t0, 4 = minor + slice, 5 = minor + handoff (05a)
};

// Run totals for the records above. Kept as one struct so combine()/reset()
// cannot silently miss a field (a missed merge prints as zero, not a crash).
// threaded-gc-02 (plans/threaded-gc-02-bitmap-allocation.md Step 8): counters
// of the bitmap-allocation path. All zero with old_gen_bitmap_alloc off, and
// then the banner block is not printed (the flag-off banner is unchanged).
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
    // Free bytes (cells x cell - live) of the uniform blocks queued at each
    // major-GC end, cumulative. These cells are no longer on free lists, so
    // the residency histogram counts them as garbage in bitmap mode.
    uint64_t bitmap_free_bytes_at_major = 0;
    // Register CR-014 (plans/threaded-gc-register-repros-impl.md Step 28): the
    // lazy sweep's TAIL completion (the slice's budget ran out exactly at the
    // last block's end; onSweepComplete runs in lazySweep), and those of them
    // inside a parallel promotion (on a worker, under promo_mu_).
    uint64_t sweep_tail_completions = 0;
    uint64_t sweep_tail_in_promotion = 0;
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
    }
    bool any() const {
        return bitmap_allocs | virgin_blocks | cursor_refills |
               blocks_classified_uniform | blocks_classified_mixed |
               blocks_classified_large | gap_sweep_gaps;
    }
};

// threaded-gc-04b (plans/threaded-gc-04b-young-large-objects.md P§3.6): large
// (>= large_object_threshold) allocations by placement, and the young
// large-object space (YLOS) life cycle. Per-heap; combine() sums.
struct LargePtrStats {
    uint64_t nursery_allocs = 0, nursery_bytes = 0;     // pointer-bearing, in the nursery
    uint64_t ylos_allocs = 0, ylos_bytes = 0;           // pointer-bearing, young large object
    uint64_t region_allocs = 0, region_bytes = 0;       // large closure-group regions
    uint64_t pointerfree_allocs = 0, pointerfree_bytes = 0;   // strings/bytes/scalars, old pinned
    uint64_t ylos_promoted_in_place = 0, ylos_freed_minor = 0, ylos_retired_major = 0;
    uint64_t ylos_reach_calls = 0, ylos_scans = 0;
    bool any() const {
        return nursery_allocs | ylos_allocs | region_allocs | pointerfree_allocs;
    }
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

// threaded-gc-06 (plans/threaded-gc-06-parallel-minor.md P§3.12): parallel
// minor GC (HEAP_067) and the object-byte nursery accounting (HEAP_068).
// Per-heap (the nursery's GCStats); combine() sums, maxes the maxima.
struct ParMinorStats {
    uint64_t minors_parallel = 0, serial_small = 0, serial_space = 0;
    uint64_t workers_sum = 0;
    uint64_t filler_bytes_total = 0, filler_bytes_max = 0;
    uint64_t alloc_end_capped = 0;          // HEAP_068: must stay 0 on gate runs
    uint64_t lab_claims = 0, direct_claims = 0, claim_races = 0, busy_waits = 0;
    uint64_t spine_splits = 0, chunks = 0;
    uint64_t steals = 0, steal_aborts = 0, idle_spins = 0, idle_yields = 0, idle_sleeps = 0;
    uint64_t promo_mutex_acquires = 0, promo_mutex_wait_ns = 0;
    uint64_t imbalance_units_sum = 0;
    uint64_t drain_ns_sum = 0, sweep_ns_sum = 0;
    uint64_t member_cpu_ns = 0;             // GCMarkGang member CPU spent in minors
    bool any() const { return minors_parallel | serial_small | serial_space | alloc_end_capped; }
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

// threaded-gc-07 (plans/threaded-gc-07-concurrent-tenuring.md P§3.20): the
// region nursery and its tenure jobs (HEAP_069/HEAP_070). Per-heap (the
// nursery's GCStats, mirrored from its RegionState at every merge); combine()
// sums counters, maxes the maxima and concatenates the utilisation samples.
// The scalar part (POD: the E2E / stress runners copy it through shared
// memory from forked children).
struct RegionTenureCounters {
    uint64_t minors = 0, jobs = 0, merges = 0;
    uint64_t tenured = 0, tenured_bytes = 0, starts = 0, heal_slots = 0, resolved = 0;
    uint64_t heal_ns = 0, merge_ns = 0, wait_ns = 0, help_ns = 0, late = 0, stops = 0;
    uint64_t help_workers_sum = 0;
    uint64_t busy_ns = 0, epoch_ns = 0, collector_cpu_ns = 0;
    uint64_t grant_blocks = 0, grant_cells = 0, grant_used = 0, grant_virgin = 0;
    uint64_t ylos_gen_promoted = 0, ylos_gen_freed = 0, lb_promoted = 0;
    uint64_t shadow_wraps = 0, eden_clear_ns = 0;
    uint64_t max_nonfree = 0;
    uint64_t sync_parallel_jobs = 0;
    uint64_t survivor_hw_bytes = 0, shadow_committed_bytes = 0, eden_capacity_bytes = 0;
    // Parallel tenure engines (pause and L3): entries scanned, the busiest
    // worker's share, steals, idle waits.
    uint64_t par_runs = 0, par_units = 0, par_units_max_sum = 0, par_steals = 0;
    uint64_t par_idle_spins = 0, par_idle_yields = 0, par_idle_sleeps = 0;
    // Step 0 item 9 / lever L6: survivor copies smaller than 16 bytes (a
    // 16-byte shadow granule needs zero), and heals run on the gang.
    uint64_t copies_under16 = 0, heals_parallel = 0, grant_fallbacks = 0;
    // threaded-gc-07b (tenure age k > 1): the ageing mark and the zap.
    uint64_t tenure_age = 1, age_starts = 0, age_marked = 0, age_marked_bytes = 0, age_heal = 0;
    uint64_t zapped = 0, zapped_bytes = 0, zap_ns = 0, age_forced_exact = 0, age_par_marks = 0;
    bool any() const { return minors != 0; }
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
        if (o.tenure_age > tenure_age) tenure_age = o.tenure_age;
        age_starts += o.age_starts; age_marked += o.age_marked;
        age_marked_bytes += o.age_marked_bytes; age_heal += o.age_heal;
        zapped += o.zapped; zapped_bytes += o.zapped_bytes; zap_ns += o.zap_ns;
        age_forced_exact += o.age_forced_exact; age_par_marks += o.age_par_marks;
    }
};
struct RegionTenureStats : RegionTenureCounters {
    std::vector<uint32_t> util_ppm;    // per merged job: busy / epoch (ppm)
    void combine(const RegionTenureStats& o) {
        RegionTenureCounters::combine(o);
        util_ppm.insert(util_ppm.end(), o.util_ppm.begin(), o.util_ppm.end());
    }
};

// threaded-gc-05a (plans/threaded-gc-05a-incremental-marking.md P§3.12): the
// incremental mark cycle (HEAP_063). Per-heap (OldGenSpace's alloc_stats_);
// combine() sums counters and maxes the per-pause maxima.
struct IncrMarkStats {
    uint64_t cycles = 0, slices = 0, slice_units = 0, closing_units = 0;
    uint64_t closing_units_max = 0;
    uint64_t finish_schedule = 0, finish_pressure = 0, finish_join = 0;
    uint64_t black_bytes = 0, traced_live_bytes = 0;
    uint64_t deferred_frees = 0, deferred_free_bytes = 0;
    uint64_t t0_survivors = 0, t0_survivor_bytes = 0, t0_ylos = 0;
    uint64_t t0_ns_total = 0, t0_ns_max = 0;
    uint64_t t0_prep_ns_total = 0, t0_prep_ns_max = 0;   // of which: sweep drain + clear
    uint64_t slice_ns_total = 0, slice_ns_max = 0;
    uint64_t handoff_ns_total = 0, handoff_ns_max = 0;
    bool any() const { return cycles != 0 || slices != 0; }
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

// threaded-gc-05b (plans/threaded-gc-05b-parallel-marking.md P§3.10): the
// parallel marker. Per-heap (old gen's alloc_stats_); combine() sums, maxes.
struct ParMarkStats {
    uint64_t runs = 0, members_max = 0, units = 0;
    uint64_t steals = 0, steal_aborts = 0, steal_empty = 0;
    uint64_t idle_spins = 0, idle_yields = 0, idle_sleeps = 0;
    uint64_t imbalance_milli_sum = 0, imbalance_milli_max = 0;   // max/mean units x 1000
    uint64_t member_cpu_ns = 0, run_ns_total = 0, run_ns_max = 0;
    uint64_t deque_grows = 0, deque_peak_entries = 0, chunks_pushed = 0;
    bool any() const { return runs != 0 || chunks_pushed != 0; }
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

// threaded-gc-05c (plans/threaded-gc-05c-concurrent-marking.md P§3.13):
// concurrent marking. Per-heap (old gen's alloc_stats_); combine() sums, maxes.
// PROGRESS counters: they may differ across conc_mark modes (P§3.10).
struct ConcMarkStats {
    uint64_t episodes_launched = 0, episodes_relaunched = 0, episodes_stopped = 0;
    uint64_t bg_units = 0;
    uint64_t assists = 0, assist_units = 0, assist_ns_total = 0, assist_ns_max = 0;
    uint64_t closings_with_work = 0, closing_units = 0, closing_ns_total = 0, closing_ns_max = 0;
    uint64_t done_k_hist[5] = {0, 0, 0, 0, 0};   // by T/4, T/2, 3T/4, T, not before closing
    uint64_t bg_cpu_ns = 0, bg_wall_ns_total = 0;
    uint64_t stop_wait_ns_max = 0, join_wait_ns_max = 0;
    uint64_t mutator_cpu_ns = 0, mutator_pause_cpu_ns = 0;
    bool any() const { return episodes_launched != 0 || assists != 0 || closings_with_work != 0; }
    void combine(const ConcMarkStats& o) {
        episodes_launched += o.episodes_launched; episodes_relaunched += o.episodes_relaunched;
        episodes_stopped += o.episodes_stopped; bg_units += o.bg_units;
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

// threaded-gc-03 (plans/threaded-gc-03-helper-threads.md P§3.9): where old-gen
// pages come from and go to. Allocator-global (filled by getCombinedStats from
// the live allocator), so combine() merges by max like the old-gen walls.
struct PageSupplyStats {
    uint64_t released_bytes = 0, released_extents = 0;
    uint64_t discarded_bytes = 0, discarded_extents = 0;
    uint64_t discard_inline_ns = 0;          // mode 0: the inline madvise, timed
    uint64_t reuse_resident_bytes = 0;       // reuse whose discard was cancelled / never done
    uint64_t reuse_after_discard_bytes = 0;  // reuse of discarded pages (they refault)
    uint64_t fresh_bytes = 0;                // bump commits
    uint64_t fresh_ahead_hit_bytes = 0, fresh_ahead_miss_bytes = 0;
    uint64_t pending_peak_bytes = 0;
    bool any() const { return released_bytes | reuse_resident_bytes |
                              reuse_after_discard_bytes | fresh_bytes; }
    void mergeMax(const PageSupplyStats& o);
};

// threaded-gc-03: a snapshot of the GC helper pool + PageWork (mode != 0).
struct HelperStatsSnapshot {
    uint32_t mode = 0, threads = 0, jitter_us = 0;
    int32_t  pin_cpu = -1;
    static constexpr int kClients = 3;       // gc::HelperClient::kCount
    uint64_t jobs[kClients] = {0}, bytes[kClients] = {0};
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
    uint64_t process_cpu_ns = 0;             // CLOCK_PROCESS_CPUTIME_ID at print
    void mergeMax(const HelperStatsSnapshot& o);
};

struct GCPhaseTotals {
    // ----- minor phase totals (summed over recorded minors) -----
    uint64_t minor_records = 0;
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
    uint64_t minor_pause_ns = 0;

    // ----- per external root scanner (merged by name) -----
    int         ext_count = 0;
    const char* ext_name[GC_EXT_SCANNER_CAP] = {nullptr};
    uint64_t    ext_ns[GC_EXT_SCANNER_CAP] = {0};
    uint64_t    ext_slots[GC_EXT_SCANNER_CAP] = {0};
    uint64_t    ext_slots_max[GC_EXT_SCANNER_CAP] = {0};

    // ----- pause accounting (always on in stats builds) -----
    static constexpr size_t PAUSE_EVENT_CAP = size_t{1} << 18;
    static constexpr int PAUSE_LOG2_BUCKETS = 32;  // bucket b: [2^b, 2^(b+1)) us; b=0 is < 2 us
    std::vector<PauseEvent> pause_events;
    uint64_t pause_events_dropped = 0;
    uint64_t pause_count = 0;
    uint64_t pause_total_ns = 0;
    uint64_t pause_max_ns = 0;
    // 0 minor only, 1 minor + major, 2 major only; threaded-gc-05a: 3 minor +
    // t0 snapshot, 4 minor + mark slice, 5 minor + cycle handoff.
    uint64_t pause_count_by_kind[6] = {0, 0, 0, 0, 0, 0};
    uint64_t pause_log2_hist[PAUSE_LOG2_BUCKETS] = {0};

    // threaded-gc-03: helper stalls OUTSIDE a pause (a stall inside a pause is
    // already pause time). Kept apart from pause_events so the existing pause
    // lines are unchanged; the MMU line "incl. helper stalls" uses both.
    std::vector<PauseEvent> stall_events;
    uint64_t stall_events_dropped = 0;
    void addStall(uint64_t start_ns, uint64_t dur_ns);

    // Adds one minor's record. `names` resolves scanner index -> name.
    void addMinor(const MinorGCRecord& r, const char* const* names, size_t n_names);
    // Adds one pause.
    void addPause(uint64_t start_ns, uint64_t dur_ns, uint8_t kind);
    // Returns the index for scanner `name`, appending it if new (or -1 if full).
    int scannerIndex(const char* name);
    void merge(const GCPhaseTotals& other);

    // ----- print-time helpers (static so unit tests can call them) -----
    // Nearest-rank percentile of `sorted` (ascending); q in (0, 1].
    static uint64_t percentile(const std::vector<uint64_t>& sorted, double q);
    // Minimum mutator utilisation over [0, wall_ns] for window w_ns, given
    // pauses sorted by start. Returns a fraction in [0, 1].
    static double mmu(const std::vector<PauseEvent>& sorted, uint64_t wall_ns,
                      uint64_t w_ns);
    static int pauseBucket(uint64_t dur_ns);
};

// Per-collection event log (ECO_GC_EVENT_LOG=<path>): see GCStats.cpp.
struct MinorGCRecord;
bool gcEventLogEnabled() noexcept;
void gcEventLogMinor(const MinorGCRecord& r, uint64_t seq, const char* const* names,
                     size_t n_names);
void gcEventLogMajor(uint64_t seq, uint64_t start_ns, uint64_t total_ns, uint64_t mark_ns,
                     uint64_t sweep_ns, uint64_t roots_ns, const char* reason);
void gcEventLogPause(uint64_t seq, uint64_t start_ns, uint64_t dur_ns, uint8_t kind);
// threaded-gc-05a: one row per incremental mark cycle, at its handoff.
void gcEventLogCycle(uint64_t seq, uint64_t t0_ns, uint64_t span_ns, uint32_t span_minors,
                     uint64_t units, const char* finish);
// threaded-gc-03 rows: a helper stall (start, dur, client name) and a finished
// helper job (post/start/end process-relative ns, bytes, client name).
void gcEventLogStall(uint64_t start_ns, uint64_t dur_ns, const char* client, bool in_pause);
void gcEventLogJob(uint64_t post_ns, uint64_t start_ns, uint64_t end_ns, uint64_t bytes,
                   const char* client);
void gcEventLogFlush() noexcept;

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
    // exceeded `nursery_growth_threshold` and the allocator was able to
    // extend both semi-space extents.
    uint64_t nursery_grow_events = 0;
    // Largest total committed nursery size observed in bytes (both extents:
    // 2 * slice capacity, sampled by NurserySpace after initialize /
    // successful grow / reset). Combined
    // across threads by max, so the printed value is the largest single
    // per-thread nursery rather than the sum across independent threads.
    uint64_t nursery_size_bytes = 0;

    // ========== Capacity-check hoisting (HEAP_041) ==========
    //
    // Cold-edge invocations of eco_ensure_nursery_slow: an ensure diamond
    // whose inline compare missed. Under the contiguous nursery (HEAP_042) a
    // miss means a GC trigger, so this counts the ensure diamonds that drove
    // a minor GC and its natural magnitude is minor_gc_count, not a block
    // transition count (the block design's `nursery_block_advances`, which
    // fired ~360x more often than GC required, no longer exists).
    uint64_t ensure_slow_calls = 0;

    // ========== Old-gen address-space walls ==========
    //
    // Allocator-GLOBAL peaks, populated by Allocator::getCombinedStats (not
    // per-thread; combine() merges them by max, then getCombinedStats
    // overwrites from the live allocator). They gate DIFFERENT walls and
    // both matter when sizing the old-gen/nursery address split (HEAP_043):
    //   - inuse peak: the GlobalPressure major-GC trigger's numerator
    //     (releases decrement it), compared against getOldGenMaxBytes().
    //   - hiwater: the monotonic commit bump acquireOldGenBlock tests
    //     against the cap — the hard alloc-failure wall. Never rewinds.
    uint64_t oldgen_inuse_peak_bytes = 0;
    uint64_t oldgen_hiwater_bytes = 0;

    // ========== Minor GC Timing Stats ==========
    // The per-cycle time is NurserySpace::minorGC's own bracket: it EXCLUDES
    // the stack walk (run before it, in ThreadLocalHeap::minorGC) and the
    // split-header large-body sweep (run after it). Both are counted as
    // mutator time by "Allocator Timings". The threaded-gc-00 pause blocks
    // (GCPhaseTotals) measure the whole contiguous stop instead.
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
    // cascade. None of that is mutator user code. This counter brackets the
    // whole function WHEN THE CALLER IS THE MUTATOR; promotion calls
    // (g_in_minor_gc == true) are not timed at all, because they are already
    // inside the minor-GC bracket and the clock reads dominated them:
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

    // ========== Per-major-GC event log ==========
    //
    // The aggregate counters above answer "how many and how long in total";
    // they cannot answer "WHEN did majors happen, what tripped each one, and
    // how much did each recover" — which is what you need to tell a
    // deterministic occupancy step (benchmarks/lss-opt.md Run R) from code
    // that genuinely got slower. This log records one row per COMPLETED major
    // GC and is dumped at process end alongside the rest of the stats.
    //
    // Bounded and allocation-free: a fixed array, no growth inside a GC pause.
    // Overflow past the cap is counted, never silently dropped.
    static constexpr size_t MAJOR_GC_EVENT_CAP = 512;

    // Why each major GC ran. Mirrors OldGenSpace::MajorGCTriggerReason plus
    // the two causes that never pass through evaluateMajorGCTrigger: a hard
    // allocation failure in the old-gen slow path, and an explicit/forced
    // collection (eco_entry teardown, RuntimeExports, main.cpp).
    enum class MajorReason : uint8_t {
        Unknown        = 0,
        Occupancy      = 1,
        GlobalPressure = 2,
        GarbageFraction = 3,
        AllocFailure   = 4,
        Forced         = 5,
        LiveBudget     = 6,  // threaded-gc-02 trigger experiment
        Headroom       = 7,  // threaded-gc-05c Part B (P§3.11)
    };

    struct MajorGCEvent {
        uint64_t seq              = 0;  // 1-based collection number
        uint64_t start_ns         = 0;  // relative to process start
        uint64_t total_ns         = 0;  // whole pause, matches the histogram
        uint64_t root_scan_ns     = 0;
        uint64_t root_push_ns     = 0;
        uint64_t mark_ns          = 0;
        uint64_t sweep_ns         = 0;
        uint64_t capacity_ns      = 0;
        // Allocator's own view either side of the pause. NOTE the sweep is
        // LAZY: `after` is what the allocator believes immediately at the end
        // of the pause, so `before - after` UNDERSTATES what the collection
        // ultimately reclaims. The mark-derived live/garbage pair below is the
        // honest measure of what the heap actually contained.
        uint64_t oldgen_before_bytes = 0;
        uint64_t oldgen_after_bytes  = 0;
        uint64_t committed_bytes     = 0;  // old-gen commit at entry
        // Mark-derived, from MajorGCPhaseProfile.
        uint64_t live_bytes_after    = 0;
        uint64_t garbage_bytes       = 0;
        uint64_t alldead_bytes_released = 0;
        uint64_t shrink_bytes_released  = 0;
        // Work done.
        uint64_t mark_units       = 0;
        uint64_t mark_stack_peak  = 0;
        uint64_t blocks_scanned   = 0;
        // Pacing: what the mutator did since the PREVIOUS major.
        uint64_t minors_since_prev   = 0;
        uint64_t promoted_since_prev = 0;
        MajorReason reason = MajorReason::Unknown;
    };

    MajorGCEvent major_gc_events[MAJOR_GC_EVENT_CAP];
    size_t   major_gc_events_used = 0;
    uint64_t major_gc_events_dropped = 0;

    // Snapshots taken at the START of the current major GC, consumed when it
    // completes. Set by ThreadLocalHeap::majorGC.
    uint64_t pending_major_start_ns      = 0;
    uint64_t pending_major_before_bytes  = 0;
    uint64_t pending_major_committed     = 0;
    MajorReason pending_major_reason     = MajorReason::Unknown;
    // Counter values at the previous major's completion, for the pacing deltas.
    uint64_t last_major_minor_count      = 0;
    uint64_t last_major_promoted         = 0;

    // ========== threaded-gc-00 phase breakdown + pauses ==========
    GCPhaseTotals tg;

    // ========== threaded-gc-02 bitmap-allocation counters ==========
    BitmapAllocStats bm;
    void printBitmapAllocBlock() const;

    // ========== threaded-gc-03 page supply + helper threads ==========
    PageSupplyStats page_supply;
    HelperStatsSnapshot helper;
    // threaded-gc-04b: large allocations by placement + YLOS life cycle.
    LargePtrStats lp;
    ParMinorStats pmin;   // threaded-gc-06
    RegionTenureStats rg;   // threaded-gc-07
    void printRegionBlock() const;
    IncrMarkStats im;   // threaded-gc-05a
    ParMarkStats pm;    // threaded-gc-05b
    ConcMarkStats cm;   // threaded-gc-05c
    void printLargePtrBlock() const;
    void printParMinorBlock() const;   // threaded-gc-06
    void printConcMarkBlock() const;
    void printIncrMarkBlock() const;
    void printParMarkBlock() const;
    void printPageSupplyBlock() const;
    void printHelperBlock() const;

    // Prints the three threaded-gc-00 banner blocks (pause distribution,
    // minor phase breakdown, external root scanners).
    void printThreadedGcBlocks() const;

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
    // threaded-gc-06: the histogram bucket of recordOldGenAllocation, and a
    // merge of a worker's private counts (parallel promotions, P§3.8.1).
    static size_t oldGenAllocBucket(size_t bytes);
    void mergeOldGenAllocHistogram(const uint64_t* buckets, uint64_t c16_24);

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
    // W5 item 55: bucketing helper, moved here with the two inlined recorders
    // below (it was file-static in GCStats.cpp). Non-Custom tags never reach it.
    static int customArityBucket(uint32_t nfields) {
        return nfields >= static_cast<uint32_t>(CUSTOM_ARITY_BUCKETS)
            ? CUSTOM_ARITY_BUCKETS - 1
            : static_cast<int>(nfields);
    }

    // W5 item 55: these run once per SURVIVING and once per PROMOTED object —
    // 744M + 676M = ~1.42 BILLION calls per self-compile — and each was an
    // out-of-line call for a bounds check and two or three increments. Inlined
    // here; deliberately NOT deleted, since objects_promoted and the per-tag
    // retention histogram are what the whole Tier-2 promotion work is ranked on.
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
    inline void recordSurvival(Tag tag, size_t bytes, uint32_t nfields) {
        objects_survived++;
        int idx = static_cast<int>(tag);
        if (idx < 0 || idx >= NUM_ALLOC_TAGS) return;
        survived_count_by_tag[idx]++;
        survived_bytes_by_tag[idx] += bytes;
        if (tag == Tag_Custom)
            custom_survived_by_nfields[customArityBucket(nfields)]++;
    }

    // threaded-gc-06 (P§3.12): one parallel minor worker's copy counters --
    // the fields recordSurvival / recordPromotion write -- kept privately by
    // the worker and merged in worker order after the join.
    struct MinorCopyCounts {
        uint64_t survived = 0, promoted = 0;
        uint64_t survived_count[NUM_ALLOC_TAGS] = {0};
        uint64_t survived_bytes[NUM_ALLOC_TAGS] = {0};
        uint64_t promoted_count[NUM_ALLOC_TAGS] = {0};
        uint64_t promoted_bytes[NUM_ALLOC_TAGS] = {0};
        uint64_t custom_promoted[CUSTOM_ARITY_BUCKETS] = {0};
        uint64_t custom_promoted_bytes[CUSTOM_ARITY_BUCKETS] = {0};
        uint64_t custom_survived[CUSTOM_ARITY_BUCKETS] = {0};
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
        inline void survival(Tag tag, size_t bytes, uint32_t nfields) {
            survived++;
            const int idx = static_cast<int>(tag);
            if (idx < 0 || idx >= NUM_ALLOC_TAGS) return;
            survived_count[idx]++;
            survived_bytes[idx] += bytes;
            if (tag == Tag_Custom) custom_survived[customArityBucket(nfields)]++;
        }
        void reset() { *this = MinorCopyCounts{}; }
        void add(const MinorCopyCounts& o) {   // threaded-gc-07: merge worker counts
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

    // Nanoseconds since process start (the event log's time origin).
    static uint64_t nowSinceProcessStartNs();
    // steady_clock time_since_epoch ns of the process-start anchor above
    // (converts GCHelperPool::nowNs() stamps to process-relative time).
    static uint64_t processStartSteadyNs();

    // Opens an event: call at major-GC entry with the cause and the old-gen
    // state before the pause. Pairs with recordMajorGCEvent below.
    void beginMajorGCEvent(MajorReason reason,
                           uint64_t oldgen_before_bytes,
                           uint64_t committed_bytes);

    // Closes the event opened by beginMajorGCEvent and appends it to the log.
    // Call once per completed major GC, after finishMarkAndSweep.
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
                            // NurserySpace keeps its OWN GCStats (merged only
                            // at print time), so the minor-side counters have
                            // to be handed in — reading them off `this` yields
                            // zero. Trap paid for on first light.
                            uint64_t minor_count_now,
                            uint64_t promoted_now);

    // Prints the per-major-GC event log (one row per collection).
    void printMajorGCEventLog() const;

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

// Human-readable major-GC reason (shared by the banner and the event log).
const char* gcMajorReasonName(GCStats::MajorReason r);

// Human-readable heap Tag name (shared by the banner and diagnostics).
const char* gcTagName(int tag);

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

    // Capacity-check hoisting (HEAP_041): a cold-edge ensure call. Cold-path
    // — counting is free.
    #define GC_STATS_ENSURE_SLOW_CALL(stats) \
        do { (stats).ensure_slow_calls++; } while(0)

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
