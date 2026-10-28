#pragma once

#include "AllocatorCommon.hpp"

namespace Elm {

// Configures a heap from outside the program. A `HeapConfig` (`AllocatorCommon.hpp`) starts from compiled-in
// defaults; this component overwrites fields of one from two sources, a JSON file and a set of environment
// variables, so that a run can be tuned without rebuilding.
//
// The JSON file is named by `ECO_HEAP_CONFIG`. Its top level is an object whose keys are `HeapConfig` field names,
// each with the field's value. Every key is optional and a key not named in the file leaves its field unchanged.
// A key that is not one of the field names these functions can set is an error, so a misspelt key cannot be silently
// ignored.
//
// Each key's value is checked only for its JSON type and for fitting the field: a byte size, a count (`uint32_t`
// or `int32_t` range), a boolean, a fraction in [0, 1], or any number. A byte size is a non-negative JSON integer
// or a string of decimal digits with an optional unit: `K`, `M` or `G`, in either case, optionally followed by
// `B` or `iB`, or `B` alone. Every unit is binary, so "16K", "16KB" and "16KiB" are all 16384, and spaces may
// surround the digits and the unit. Some count fields are read as byte sizes too, `nursery_block_count` and
// `nursery_max_block_count` among them, so "16K" is accepted there as 16384 blocks. Range checks and the rules
// relating one field to another are left to `HeapConfig::validate`, which these functions do not call.
//
// Each `apply*Env` function below handles a few environment variables, and its comment says what an unset or
// empty variable does. The environment values take precedence over the JSON file only if the caller applies
// them after it.
//
// These functions report a bad file, key or value by throwing `std::invalid_argument` with a message that names
// it, apart from the one case `applyHeapConfigJsonFile` notes. The fields are written one at a time as they are
// read, so when one throws, the fields applied before the failure have already been changed in `cfg`.

// Applies the JSON object in the file at `path` to `cfg`, key by key. `path` must not be null.
//
// Throws `std::invalid_argument` if the file cannot be opened or parsed, if its top level is not an object, if
// it holds an unknown key, or if a value has the wrong type or does not fit its field. Unknown keys are found
// before any field is written. A digit string too long for 64 bits throws `std::out_of_range` instead, and a
// size whose unit makes it overflow 64 bits is not detected.
void applyHeapConfigJsonFile(HeapConfig &cfg, const char *path);

// Applies the JSON file named by `ECO_HEAP_CONFIG` to `cfg`, as `applyHeapConfigJsonFile` does, or does nothing
// if the variable is unset or empty.
void applyHeapConfigFromEnv(HeapConfig &cfg);

// Applies the GC, nursery and tenure environment variables listed later in this comment to `cfg`, and sets
// `jitter_us` from `ECO_GC_HELPER_JITTER_US`.
//
// It reads them all from the process environment and applies them as the functions below describe:
// `ECO_GC_THREAD` and `ECO_GC_HELPER_JITTER_US` as the four-argument overload does, then `ECO_GC_MARK_THREADS`,
// `ECO_GC_MINOR_THREADS`, `ECO_GC_CONC_MARK`, `ECO_GC_CONC_MARK_THREADS`, `ECO_NURSERY_REGIONS`, `ECO_TENURE_MODE`
// and `ECO_NURSERY_EDEN_FLIP`. Two variables are handled only here: `ECO_TENURE_COLLECTORS`, a decimal number
// in [1, 32] read with `strtoul`, sets `tenure_collector_threads`, and
// `ECO_TENURE_FIFO`, "0" or "1", sets `tenure_fifo_order`.
void applyGcThreadEnv(HeapConfig &cfg, uint32_t &jitter_us);

// Sets `gc_mark_threads` from `value`, the value of `ECO_GC_MARK_THREADS`, which must be decimal digits for a
// number no greater than 64. A null or empty `value` changes nothing.
void applyMarkThreadsEnv(HeapConfig &cfg, const char *value);

// Sets `gc_minor_threads` from `value`, the value of `ECO_GC_MINOR_THREADS`, which must be decimal digits for a
// number no greater than 64. A null or empty `value` changes nothing.
void applyMinorThreadsEnv(HeapConfig &cfg, const char *value);

// Sets `conc_mark` from `mode_value`, the value of `ECO_GC_CONC_MARK`, which must be "0", "1" or "2", and
// `conc_mark_threads` from `threads_value`, the value of `ECO_GC_CONC_MARK_THREADS`, which must be decimal digits
// for a number no greater than 63. A null or empty value leaves its field unchanged.
void applyConcMarkEnv(HeapConfig &cfg, const char *mode_value, const char *threads_value);

// Sets `nursery_regions` from `regions_value` (`ECO_NURSERY_REGIONS`: "0", "1" or "2"), `tenure_mode` from
// `mode_value` (`ECO_TENURE_MODE`: "1" or "2") and `nursery_region_eden_flip` from `flip_value`
// (`ECO_NURSERY_EDEN_FLIP`: "-1", "0" or "1"). A null or empty value leaves its field unchanged.
void applyRegionEnv(HeapConfig &cfg, const char *regions_value, const char *mode_value,
                    const char *flip_value);

// Sets `gc_thread_mode` from `mode_value`, the value of `ECO_GC_THREAD`, which must be "0", "1" or "2", and sets
// `jitter_us` from `jitter_value`, the value of `ECO_GC_HELPER_JITTER_US`, which must be decimal digits for a
// number no greater than 100000. A null or empty `mode_value` leaves `gc_thread_mode` unchanged, but a null or
// empty `jitter_value` sets `jitter_us` to 0.
void applyGcThreadEnv(HeapConfig &cfg, uint32_t &jitter_us,
                      const char *mode_value, const char *jitter_value);

} // namespace Elm
