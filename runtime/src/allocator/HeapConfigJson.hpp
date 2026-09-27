#pragma once

#include "AllocatorCommon.hpp"

namespace Elm {

// Applies HeapConfig overrides from a JSON file on top of `cfg` (in place).
// Throws std::invalid_argument with a descriptive message if the file cannot
// be opened, parsed, or contains a value that fails type / range checks.
//
// Recognised keys (all optional; unknown keys are rejected):
//   "max_heap_size"                  size_t (bytes, may use suffix-string form)
//   "initial_old_gen_size"           size_t (bytes)
//   "alloc_buffer_size"              size_t (bytes)
//   "nursery_block_count"            size_t
//   "nursery_max_block_count"        size_t (must be >= nursery_block_count)
//   "promotion_age"                  unsigned (0..3)
//   "nursery_gc_threshold"           number (0..1)
//   "nursery_growth_threshold"       number (0..1)
//   "major_gc_initiating_occupancy"  number (0..1)
//   "major_gc_global_pressure_fraction" number (0..1)
//   "major_gc_target_utilization"    number (0..1)
//   "major_gc_garbage_fraction"      number [0..1)  (0 disables)
//   "use_hybrid_dfs"                 bool
//   "large_object_threshold"         size_t (bytes)
//   "large_ptr_nursery_divisor"      unsigned (0 = never nursery; threaded-gc-04b)
//   "large_ptr_nursery_max_size"     size_t (bytes, multiple of 8; 0 = no fixed bound)
//   "decommit_on_oldgen_release"     bool
//   "gc_thread_mode"                 unsigned (0 off, 1 sync, 2 concurrent; threaded-gc-03)
//   "gc_helper_threads"              unsigned (1..64)
//   "gc_helper_cpu"                  int (-1 = no pinning)
//   "decommit_delay_syncs"           unsigned (pause ends; 4294967295 = never)
//   "decommit_pending_max_bytes"     size_t (0 = no cap)
//   "decommit_delay_majors"          unsigned (0 = off)
//   "commit_ahead_bytes"             size_t (0 = off; OS-page multiple)
//   "conc_mark"                      unsigned (0 off, 1 sync, 2 concurrent; threaded-gc-05c)
//   "conc_mark_threads"              unsigned (0 = auto, <= 63)
//   "conc_mark_threads_cap"          unsigned (1..63)
//   "conc_mark_priority"             int (0 inherit, 1..19 nice, 20 SCHED_IDLE)
//   "conc_mark_assist_lag"           unsigned (cycle steps of grace)
//   "major_gc_headroom_margin"       double (0 = off; Headroom trigger)
//   "major_gc_live_budget_paced"     bool
//   "major_gc_garbage_backstop"      fraction (0 = off)
//   (the list above is partial; HeapConfigJson.cpp's kKnownKeys is complete)
//
// Environment overrides applied by Allocator::initialize AFTER this file
// (threaded-gc-03): ECO_GC_THREAD=0|1|2 sets gc_thread_mode;
// ECO_GC_HELPER_JITTER_US=<n> makes every helper sleep a random [0, n) us
// before each job (a determinism probe; GC_DET_001). Keep both values the
// same LENGTH across compared runs: the environment is a program input.
//
// Numeric byte sizes accept either a JSON integer (raw bytes) or a string
// with a unit suffix: "16K", "32M", "2G", "8KiB", "16 MB" (decimal +
// optional unit). Suffix-less strings are parsed as bytes.
//
// Caller is expected to call cfg.validate() afterwards.
void applyHeapConfigJsonFile(HeapConfig &cfg, const char *path);

// Convenience: if the ECO_HEAP_CONFIG environment variable is set and
// non-empty, calls applyHeapConfigJsonFile with its value. No-op otherwise.
// Same exception contract as applyHeapConfigJsonFile.
void applyHeapConfigFromEnv(HeapConfig &cfg);

// threaded-gc-03: applies ECO_GC_THREAD (exactly one of "0", "1", "2") to
// cfg.gc_thread_mode and parses ECO_GC_HELPER_JITTER_US (unsigned <= 100000,
// default 0) into jitter_us. Throws std::invalid_argument on a bad value.
// The 4-argument form takes the raw values (nullptr = unset) for tests.
void applyGcThreadEnv(HeapConfig &cfg, uint32_t &jitter_us);
// threaded-gc-05b: ECO_GC_MARK_THREADS; also applied by applyGcThreadEnv(cfg, jitter).
void applyMarkThreadsEnv(HeapConfig &cfg, const char *value);
// threaded-gc-05c: ECO_GC_CONC_MARK / ECO_GC_CONC_MARK_THREADS (nullptr = unset).
void applyConcMarkEnv(HeapConfig &cfg, const char *mode_value, const char *threads_value);
void applyGcThreadEnv(HeapConfig &cfg, uint32_t &jitter_us,
                      const char *mode_value, const char *jitter_value);

} // namespace Elm
