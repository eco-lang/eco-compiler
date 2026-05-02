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
//   "promotion_age"                  unsigned (0..3)
//   "nursery_gc_threshold"           number (0..1)
//   "nursery_growth_threshold"       number (0..1)
//   "major_gc_initiating_occupancy"  number (0..1)
//   "major_gc_target_utilization"    number (0..1)
//   "major_gc_garbage_fraction"      number [0..1)  (0 disables)
//   "use_hybrid_dfs"                 bool
//   "large_object_threshold"         size_t (bytes)
//   "decommit_on_oldgen_release"     bool
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

} // namespace Elm
