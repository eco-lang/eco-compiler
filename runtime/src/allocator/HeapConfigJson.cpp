#include "HeapConfigJson.hpp"

#include <cctype>
#include <cstdint>
#include <cstdlib>
#include <fstream>
#include <stdexcept>
#include <string>

// The std::invalid_argument thrown here is caught by code built with exceptions; under
// _HAS_EXCEPTIONS=0 the MSVC STL gives std::exception another layout, and the catcher's
// destructor then frees the string-literal message (eco_drop_no_exceptions_define in
// runtime/src/codegen/CMakeLists.txt).
#if defined(_MSC_VER) && defined(_HAS_EXCEPTIONS) && !_HAS_EXCEPTIONS
#  error "HeapConfigJson.cpp throws std exceptions: build it without _HAS_EXCEPTIONS=0"
#endif

#if defined(__clang__)
#  pragma clang diagnostic push
#  pragma clang diagnostic ignored "-Wcovered-switch-default"
#elif defined(__GNUC__)
#  pragma GCC diagnostic push
#  pragma GCC diagnostic ignored "-Wcovered-switch-default"
#endif
#include "../../../elm-kernel-cpp/vendor/nlohmann/json.hpp"
#if defined(__clang__)
#  pragma clang diagnostic pop
#elif defined(__GNUC__)
#  pragma GCC diagnostic pop
#endif

namespace Elm {

namespace {

using json = nlohmann::json;

// Parses a byte size from either a JSON number (raw bytes) or a string with
// an optional unit suffix (K/M/G, optional "iB" or "B"). All units are
// power-of-two (1K = 1024, 1M = 1024*1024, 1G = 1024*1024*1024).
size_t parseByteSize(const json &value, const char *key) {
    if (value.is_number_integer() || value.is_number_unsigned()) {
        const auto raw = value.get<int64_t>();
        if (raw < 0) {
            throw std::invalid_argument(std::string("HeapConfig key '") + key +
                                        "' must be non-negative");
        }
        return static_cast<size_t>(raw);
    }
    if (!value.is_string()) {
        throw std::invalid_argument(std::string("HeapConfig key '") + key +
                                    "' must be a number or a string with a "
                                    "unit suffix (e.g. \"16M\")");
    }

    const std::string s = value.get<std::string>();
    size_t i = 0;
    while (i < s.size() && std::isspace(static_cast<unsigned char>(s[i]))) ++i;

    size_t digit_start = i;
    while (i < s.size() && std::isdigit(static_cast<unsigned char>(s[i]))) ++i;
    if (i == digit_start) {
        throw std::invalid_argument(std::string("HeapConfig key '") + key +
                                    "': expected leading digits in \"" + s + "\"");
    }
    const uint64_t magnitude = std::stoull(s.substr(digit_start, i - digit_start));

    while (i < s.size() && std::isspace(static_cast<unsigned char>(s[i]))) ++i;

    uint64_t multiplier = 1;
    if (i < s.size()) {
        const char unit = static_cast<char>(
            std::toupper(static_cast<unsigned char>(s[i++])));
        switch (unit) {
            case 'K': multiplier = 1024ULL; break;
            case 'M': multiplier = 1024ULL * 1024; break;
            case 'G': multiplier = 1024ULL * 1024 * 1024; break;
            case 'B': /* bytes, multiplier stays 1 */ break;
            default:
                throw std::invalid_argument(std::string("HeapConfig key '") + key +
                                            "': unknown size unit '" + unit + "'");
        }
        // Allow trailing "iB" or "B" after K/M/G ("16KiB", "32MB").
        if (multiplier != 1 && i < s.size()) {
            const char c1 = static_cast<char>(
                std::toupper(static_cast<unsigned char>(s[i])));
            if (c1 == 'I' && i + 1 < s.size() &&
                std::toupper(static_cast<unsigned char>(s[i + 1])) == 'B') {
                i += 2;
            } else if (c1 == 'B') {
                i += 1;
            }
        }
        while (i < s.size() && std::isspace(static_cast<unsigned char>(s[i]))) ++i;
        if (i != s.size()) {
            throw std::invalid_argument(std::string("HeapConfig key '") + key +
                                        "': trailing characters in \"" + s + "\"");
        }
    }
    return static_cast<size_t>(magnitude * multiplier);
}

float parseFraction(const json &value, const char *key) {
    if (!value.is_number()) {
        throw std::invalid_argument(std::string("HeapConfig key '") + key +
                                    "' must be a number in [0, 1]");
    }
    const double d = value.get<double>();
    if (d < 0.0 || d > 1.0) {
        throw std::invalid_argument(std::string("HeapConfig key '") + key +
                                    "' must be in [0, 1]");
    }
    return static_cast<float>(d);
}

// Parses any JSON number into a double. Range checks are deferred to
// HeapConfig::validate(); this helper just enforces "is a number".
double parseDouble(const json &value, const char *key) {
    if (!value.is_number()) {
        throw std::invalid_argument(std::string("HeapConfig key '") + key +
                                    "' must be a number");
    }
    return value.get<double>();
}

bool parseBool(const json &value, const char *key) {
    if (!value.is_boolean()) {
        throw std::invalid_argument(std::string("HeapConfig key '") + key +
                                    "' must be true or false");
    }
    return value.get<bool>();
}

uint32_t parseU32(const json &value, const char *key) {
    if (!value.is_number_integer() && !value.is_number_unsigned()) {
        throw std::invalid_argument(std::string("HeapConfig key '") + key +
                                    "' must be an integer");
    }
    const auto raw = value.get<int64_t>();
    if (raw < 0 || raw > UINT32_MAX) {
        throw std::invalid_argument(std::string("HeapConfig key '") + key +
                                    "' is out of uint32_t range");
    }
    return static_cast<uint32_t>(raw);
}

int32_t parseI32(const json &value, const char *key) {
    if (!value.is_number_integer() && !value.is_number_unsigned()) {
        throw std::invalid_argument(std::string("HeapConfig key '") + key +
                                    "' must be an integer");
    }
    const auto raw = value.get<int64_t>();
    if (raw < INT32_MIN || raw > INT32_MAX) {
        throw std::invalid_argument(std::string("HeapConfig key '") + key +
                                    "' is out of int32_t range");
    }
    return static_cast<int32_t>(raw);
}

} // namespace

void applyHeapConfigJsonFile(HeapConfig &cfg, const char *path) {
    std::ifstream in(path);
    if (!in.is_open()) {
        throw std::invalid_argument(std::string("HeapConfig: cannot open '") +
                                    path + "'");
    }

    json doc;
    try {
        in >> doc;
    } catch (const std::exception &e) {
        throw std::invalid_argument(std::string("HeapConfig: parse error in '") +
                                    path + "': " + e.what());
    }

    if (!doc.is_object()) {
        throw std::invalid_argument(std::string("HeapConfig: '") + path +
                                    "' must contain a JSON object at top level");
    }

    static constexpr const char *kKnownKeys[] = {
        "max_heap_size",
        "nursery_region_bytes",
        "initial_old_gen_size",
        "alloc_buffer_size",
        "nursery_block_count",
        "nursery_max_block_count",
        "promotion_age",
        "nursery_gc_threshold",
        "nursery_growth_threshold",
        "major_gc_initiating_occupancy",
        "major_gc_global_pressure_fraction",
        "major_gc_target_utilization",
        "major_gc_garbage_fraction",
        "direct_alloc_minor_budget",
        "los_empty_keep",
        "use_hybrid_dfs",
        "large_object_threshold",
        "large_ptr_nursery_divisor",
        "large_ptr_nursery_max_size",
        "decommit_on_oldgen_release",
        "gc_thread_mode",
        "gc_helper_threads",
        "gc_helper_cpu",
        "decommit_delay_syncs",
        "decommit_pending_max_bytes",
        "decommit_delay_majors",
        "commit_ahead_bytes",
        "old_gen_bitmap_alloc",
        "incremental_mark",
        "gc_mark_threads",
        "gc_mark_threads_cap",
        "gc_minor_threads",
        "gc_minor_threads_cap",
        "minor_lab_bytes",
        "minor_parallel_min_bytes",
        "minor_prefetch_children",
        "minor_fifo_order",
        "nursery_regions",
        "nursery_region_eden_flip",
        "tenure_mode",
        "tenure_sync_threads",
        "tenure_help",
        "tenure_help_threads",
        "tenure_priority",
        "heal_parallel_min",
        "shadow_granule_log2",
        "tenure_collector_threads",
        "tenure_fifo_order",
        "conc_mark",
        "conc_mark_threads",
        "conc_mark_threads_cap",
        "conc_mark_priority",
        "conc_mark_assist_lag",
        "major_gc_headroom_margin",
        "major_gc_live_budget_paced",
        "major_gc_garbage_backstop",
        "incremental_mark_slices",
        "incremental_mark_min_slice_units",
        "incremental_mark_predict_growth",
        "incremental_mark_finish_fraction",
        "demote_live_fraction",
        "garbage_denom_cap",
        "major_gc_live_budget",
        "live_growth_bound",
        "small_class_heap_budget_bytes",
        "small_class_cell_max_bytes",
        "string_flatten_limit",
        "string_tiny_slice_limit",
        "utf8_view_min_len",
        "utf8_strings_enabled",
        "rope_max_height",
        "rope_leaf_count_limit",
        "rope_min_leaf_size",
        "sweep_work_budget",
        "minor_sweep_divisor",
        "initial_sweep_budget",
        "mark_work_ratio",
        "sweep_bytes_per_alloc_byte",
        "max_sweep_bytes_per_alloc",
        "max_sweep_bytes_hard",
        "sweep_cap_ratio_low",
        "sweep_cap_ratio_medium",
        "sweep_cap_ratio_high",
        "sweep_scale_low",
        "sweep_scale_medium",
        "sweep_scale_high",
        "sweep_scale_crit",
        "sweep_unswept_ratio_boost",
        "sweep_unswept_scale",
        "panic_sweep_slice_bytes",
    };

    for (auto it = doc.begin(); it != doc.end(); ++it) {
        const std::string &key = it.key();
        bool known = false;
        for (const char *k : kKnownKeys) {
            if (key == k) { known = true; break; }
        }
        if (!known) {
            throw std::invalid_argument(
                "HeapConfig: unknown key '" + key + "' in " + path);
        }
    }

    if (auto it = doc.find("max_heap_size"); it != doc.end())
        cfg.max_heap_size = parseByteSize(*it, "max_heap_size");
    if (auto it = doc.find("nursery_region_bytes"); it != doc.end())
        cfg.nursery_region_bytes = parseByteSize(*it, "nursery_region_bytes");
    if (auto it = doc.find("initial_old_gen_size"); it != doc.end())
        cfg.initial_old_gen_size = parseByteSize(*it, "initial_old_gen_size");
    if (auto it = doc.find("alloc_buffer_size"); it != doc.end())
        cfg.alloc_buffer_size = parseByteSize(*it, "alloc_buffer_size");
    if (auto it = doc.find("nursery_block_count"); it != doc.end())
        cfg.nursery_block_count = parseByteSize(*it, "nursery_block_count");
    if (auto it = doc.find("nursery_max_block_count"); it != doc.end())
        cfg.nursery_max_block_count =
            parseByteSize(*it, "nursery_max_block_count");
    if (auto it = doc.find("promotion_age"); it != doc.end())
        cfg.promotion_age = parseU32(*it, "promotion_age");
    if (auto it = doc.find("nursery_gc_threshold"); it != doc.end())
        cfg.nursery_gc_threshold = parseFraction(*it, "nursery_gc_threshold");
    if (auto it = doc.find("nursery_growth_threshold"); it != doc.end())
        cfg.nursery_growth_threshold =
            parseFraction(*it, "nursery_growth_threshold");
    if (auto it = doc.find("major_gc_initiating_occupancy"); it != doc.end())
        cfg.major_gc_initiating_occupancy =
            parseFraction(*it, "major_gc_initiating_occupancy");
    if (auto it = doc.find("major_gc_global_pressure_fraction"); it != doc.end())
        cfg.major_gc_global_pressure_fraction =
            parseFraction(*it, "major_gc_global_pressure_fraction");
    if (auto it = doc.find("major_gc_target_utilization"); it != doc.end())
        cfg.major_gc_target_utilization =
            parseFraction(*it, "major_gc_target_utilization");
    if (auto it = doc.find("major_gc_garbage_fraction"); it != doc.end())
        cfg.major_gc_garbage_fraction =
            parseFraction(*it, "major_gc_garbage_fraction");
    // A multiplier, not a fraction (parseFraction rejects > 1); validate() checks the range.
    if (auto it = doc.find("direct_alloc_minor_budget"); it != doc.end())
        cfg.direct_alloc_minor_budget = parseDouble(*it, "direct_alloc_minor_budget");
    if (auto it = doc.find("los_empty_keep"); it != doc.end())
        cfg.los_empty_keep = parseByteSize(*it, "los_empty_keep");
    if (auto it = doc.find("use_hybrid_dfs"); it != doc.end())
        cfg.use_hybrid_dfs = parseBool(*it, "use_hybrid_dfs");
    if (auto it = doc.find("large_object_threshold"); it != doc.end())
        cfg.large_object_threshold =
            parseByteSize(*it, "large_object_threshold");
    if (auto it = doc.find("large_ptr_nursery_divisor"); it != doc.end())
        cfg.large_ptr_nursery_divisor =
            parseU32(*it, "large_ptr_nursery_divisor");
    if (auto it = doc.find("large_ptr_nursery_max_size"); it != doc.end())
        cfg.large_ptr_nursery_max_size =
            parseByteSize(*it, "large_ptr_nursery_max_size");
    if (auto it = doc.find("decommit_on_oldgen_release"); it != doc.end())
        cfg.decommit_on_oldgen_release =
            parseBool(*it, "decommit_on_oldgen_release");
    if (auto it = doc.find("gc_thread_mode"); it != doc.end())
        cfg.gc_thread_mode = parseU32(*it, "gc_thread_mode");
    if (auto it = doc.find("gc_helper_threads"); it != doc.end())
        cfg.gc_helper_threads = parseU32(*it, "gc_helper_threads");
    if (auto it = doc.find("gc_helper_cpu"); it != doc.end())
        cfg.gc_helper_cpu = parseI32(*it, "gc_helper_cpu");
    if (auto it = doc.find("decommit_delay_syncs"); it != doc.end())
        cfg.decommit_delay_syncs = parseU32(*it, "decommit_delay_syncs");
    if (auto it = doc.find("decommit_pending_max_bytes"); it != doc.end())
        cfg.decommit_pending_max_bytes =
            parseByteSize(*it, "decommit_pending_max_bytes");
    if (auto it = doc.find("decommit_delay_majors"); it != doc.end())
        cfg.decommit_delay_majors = parseU32(*it, "decommit_delay_majors");
    if (auto it = doc.find("commit_ahead_bytes"); it != doc.end())
        cfg.commit_ahead_bytes = parseByteSize(*it, "commit_ahead_bytes");
    if (auto it = doc.find("old_gen_bitmap_alloc"); it != doc.end())
        cfg.old_gen_bitmap_alloc = parseBool(*it, "old_gen_bitmap_alloc");
    if (auto it = doc.find("gc_mark_threads"); it != doc.end())
        cfg.gc_mark_threads = parseU32(*it, "gc_mark_threads");
    if (auto it = doc.find("gc_mark_threads_cap"); it != doc.end())
        cfg.gc_mark_threads_cap = parseU32(*it, "gc_mark_threads_cap");
    // threaded-gc-06
    if (auto it = doc.find("gc_minor_threads"); it != doc.end())
        cfg.gc_minor_threads = parseU32(*it, "gc_minor_threads");
    if (auto it = doc.find("gc_minor_threads_cap"); it != doc.end())
        cfg.gc_minor_threads_cap = parseU32(*it, "gc_minor_threads_cap");
    if (auto it = doc.find("minor_lab_bytes"); it != doc.end())
        cfg.minor_lab_bytes = parseByteSize(*it, "minor_lab_bytes");
    if (auto it = doc.find("minor_parallel_min_bytes"); it != doc.end())
        cfg.minor_parallel_min_bytes = parseByteSize(*it, "minor_parallel_min_bytes");
    if (auto it = doc.find("minor_prefetch_children"); it != doc.end())
        cfg.minor_prefetch_children = parseBool(*it, "minor_prefetch_children");
    if (auto it = doc.find("minor_fifo_order"); it != doc.end())
        cfg.minor_fifo_order = parseBool(*it, "minor_fifo_order");
    // threaded-gc-07
    if (auto it = doc.find("nursery_regions"); it != doc.end())
        cfg.nursery_regions = parseU32(*it, "nursery_regions");
    if (auto it = doc.find("nursery_region_eden_flip"); it != doc.end())
        cfg.nursery_region_eden_flip = parseI32(*it, "nursery_region_eden_flip");
    if (auto it = doc.find("tenure_mode"); it != doc.end())
        cfg.tenure_mode = parseU32(*it, "tenure_mode");
    if (auto it = doc.find("tenure_sync_threads"); it != doc.end())
        cfg.tenure_sync_threads = parseU32(*it, "tenure_sync_threads");
    if (auto it = doc.find("tenure_help"); it != doc.end())
        cfg.tenure_help = parseU32(*it, "tenure_help");
    if (auto it = doc.find("tenure_help_threads"); it != doc.end())
        cfg.tenure_help_threads = parseU32(*it, "tenure_help_threads");
    if (auto it = doc.find("tenure_priority"); it != doc.end())
        cfg.tenure_priority = parseI32(*it, "tenure_priority");
    if (auto it = doc.find("heal_parallel_min"); it != doc.end())
        cfg.heal_parallel_min = parseByteSize(*it, "heal_parallel_min");
    if (auto it = doc.find("shadow_granule_log2"); it != doc.end())
        cfg.shadow_granule_log2 = parseU32(*it, "shadow_granule_log2");
    if (auto it = doc.find("tenure_collector_threads"); it != doc.end())
        cfg.tenure_collector_threads = parseU32(*it, "tenure_collector_threads");
    if (auto it = doc.find("tenure_fifo_order"); it != doc.end())
        cfg.tenure_fifo_order = parseBool(*it, "tenure_fifo_order");
    // threaded-gc-05c
    if (auto it = doc.find("conc_mark"); it != doc.end())
        cfg.conc_mark = parseU32(*it, "conc_mark");
    if (auto it = doc.find("conc_mark_threads"); it != doc.end())
        cfg.conc_mark_threads = parseU32(*it, "conc_mark_threads");
    if (auto it = doc.find("conc_mark_threads_cap"); it != doc.end())
        cfg.conc_mark_threads_cap = parseU32(*it, "conc_mark_threads_cap");
    if (auto it = doc.find("conc_mark_priority"); it != doc.end())
        cfg.conc_mark_priority = parseI32(*it, "conc_mark_priority");
    if (auto it = doc.find("conc_mark_assist_lag"); it != doc.end())
        cfg.conc_mark_assist_lag = parseU32(*it, "conc_mark_assist_lag");
    if (auto it = doc.find("major_gc_headroom_margin"); it != doc.end())
        cfg.major_gc_headroom_margin = parseDouble(*it, "major_gc_headroom_margin");
    if (auto it = doc.find("major_gc_live_budget_paced"); it != doc.end())
        cfg.major_gc_live_budget_paced = parseBool(*it, "major_gc_live_budget_paced");
    if (auto it = doc.find("major_gc_garbage_backstop"); it != doc.end())
        cfg.major_gc_garbage_backstop = parseFraction(*it, "major_gc_garbage_backstop");
    if (auto it = doc.find("incremental_mark"); it != doc.end())
        cfg.incremental_mark = parseBool(*it, "incremental_mark");
    if (auto it = doc.find("incremental_mark_slices"); it != doc.end())
        cfg.incremental_mark_slices = parseU32(*it, "incremental_mark_slices");
    if (auto it = doc.find("incremental_mark_min_slice_units"); it != doc.end())
        cfg.incremental_mark_min_slice_units =
            parseByteSize(*it, "incremental_mark_min_slice_units");
    if (auto it = doc.find("incremental_mark_predict_growth"); it != doc.end())
        cfg.incremental_mark_predict_growth =
            parseDouble(*it, "incremental_mark_predict_growth");
    if (auto it = doc.find("incremental_mark_finish_fraction"); it != doc.end())
        cfg.incremental_mark_finish_fraction =
            parseDouble(*it, "incremental_mark_finish_fraction");
    if (auto it = doc.find("demote_live_fraction"); it != doc.end())
        // parseDouble, not parseFraction: the field is a double, and a float
        // round-trip turns 0.3 into 0.30000001 (validate() checks [0, 1]).
        cfg.demote_live_fraction =
            parseDouble(*it, "demote_live_fraction");
    if (auto it = doc.find("garbage_denom_cap"); it != doc.end())
        cfg.garbage_denom_cap = parseDouble(*it, "garbage_denom_cap");
    if (auto it = doc.find("major_gc_live_budget"); it != doc.end())
        cfg.major_gc_live_budget = parseDouble(*it, "major_gc_live_budget");
    if (auto it = doc.find("live_growth_bound"); it != doc.end())
        cfg.live_growth_bound = parseDouble(*it, "live_growth_bound");
    if (auto it = doc.find("small_class_heap_budget_bytes"); it != doc.end())
        cfg.small_class_heap_budget_bytes =
            parseByteSize(*it, "small_class_heap_budget_bytes");
    if (auto it = doc.find("small_class_cell_max_bytes"); it != doc.end())
        cfg.small_class_cell_max_bytes =
            parseByteSize(*it, "small_class_cell_max_bytes");
    if (auto it = doc.find("string_flatten_limit"); it != doc.end())
        cfg.string_flatten_limit =
            parseByteSize(*it, "string_flatten_limit");
    if (auto it = doc.find("string_tiny_slice_limit"); it != doc.end())
        cfg.string_tiny_slice_limit =
            parseByteSize(*it, "string_tiny_slice_limit");
    if (auto it = doc.find("utf8_view_min_len"); it != doc.end())
        cfg.utf8_view_min_len = parseByteSize(*it, "utf8_view_min_len");
    if (auto it = doc.find("utf8_strings_enabled"); it != doc.end())
        cfg.utf8_strings_enabled = parseBool(*it, "utf8_strings_enabled");
    if (auto it = doc.find("rope_max_height"); it != doc.end())
        cfg.rope_max_height = parseU32(*it, "rope_max_height");
    if (auto it = doc.find("rope_leaf_count_limit"); it != doc.end())
        cfg.rope_leaf_count_limit = parseU32(*it, "rope_leaf_count_limit");
    if (auto it = doc.find("rope_min_leaf_size"); it != doc.end())
        cfg.rope_min_leaf_size = parseU32(*it, "rope_min_leaf_size");
    if (auto it = doc.find("sweep_work_budget"); it != doc.end())
        cfg.sweep_work_budget = parseByteSize(*it, "sweep_work_budget");
    if (auto it = doc.find("minor_sweep_divisor"); it != doc.end())
        cfg.minor_sweep_divisor = parseByteSize(*it, "minor_sweep_divisor");
    if (auto it = doc.find("initial_sweep_budget"); it != doc.end())
        cfg.initial_sweep_budget = parseByteSize(*it, "initial_sweep_budget");
    if (auto it = doc.find("mark_work_ratio"); it != doc.end())
        cfg.mark_work_ratio = parseByteSize(*it, "mark_work_ratio");
    if (auto it = doc.find("sweep_bytes_per_alloc_byte"); it != doc.end())
        cfg.sweep_bytes_per_alloc_byte =
            parseDouble(*it, "sweep_bytes_per_alloc_byte");
    if (auto it = doc.find("max_sweep_bytes_per_alloc"); it != doc.end())
        cfg.max_sweep_bytes_per_alloc =
            parseByteSize(*it, "max_sweep_bytes_per_alloc");
    if (auto it = doc.find("max_sweep_bytes_hard"); it != doc.end())
        cfg.max_sweep_bytes_hard =
            parseByteSize(*it, "max_sweep_bytes_hard");
    if (auto it = doc.find("sweep_cap_ratio_low"); it != doc.end())
        cfg.sweep_cap_ratio_low =
            parseDouble(*it, "sweep_cap_ratio_low");
    if (auto it = doc.find("sweep_cap_ratio_medium"); it != doc.end())
        cfg.sweep_cap_ratio_medium =
            parseDouble(*it, "sweep_cap_ratio_medium");
    if (auto it = doc.find("sweep_cap_ratio_high"); it != doc.end())
        cfg.sweep_cap_ratio_high =
            parseDouble(*it, "sweep_cap_ratio_high");
    if (auto it = doc.find("sweep_scale_low"); it != doc.end())
        cfg.sweep_scale_low = parseDouble(*it, "sweep_scale_low");
    if (auto it = doc.find("sweep_scale_medium"); it != doc.end())
        cfg.sweep_scale_medium = parseDouble(*it, "sweep_scale_medium");
    if (auto it = doc.find("sweep_scale_high"); it != doc.end())
        cfg.sweep_scale_high = parseDouble(*it, "sweep_scale_high");
    if (auto it = doc.find("sweep_scale_crit"); it != doc.end())
        cfg.sweep_scale_crit = parseDouble(*it, "sweep_scale_crit");
    if (auto it = doc.find("sweep_unswept_ratio_boost"); it != doc.end())
        cfg.sweep_unswept_ratio_boost =
            parseDouble(*it, "sweep_unswept_ratio_boost");
    if (auto it = doc.find("sweep_unswept_scale"); it != doc.end())
        cfg.sweep_unswept_scale = parseDouble(*it, "sweep_unswept_scale");
    if (auto it = doc.find("panic_sweep_slice_bytes"); it != doc.end())
        cfg.panic_sweep_slice_bytes =
            parseByteSize(*it, "panic_sweep_slice_bytes");
}

void applyHeapConfigFromEnv(HeapConfig &cfg) {
    const char *path = std::getenv("ECO_HEAP_CONFIG");
    if (path == nullptr || path[0] == '\0') return;
    applyHeapConfigJsonFile(cfg, path);
}

void applyGcThreadEnv(HeapConfig &cfg, uint32_t &jitter_us,
                      const char *mode_value, const char *jitter_value) {
    if (mode_value != nullptr && mode_value[0] != '\0') {
        if (mode_value[1] != '\0' || mode_value[0] < '0' || mode_value[0] > '2') {
            throw std::invalid_argument("ECO_GC_THREAD must be 0, 1 or 2");
        }
        cfg.gc_thread_mode = static_cast<uint32_t>(mode_value[0] - '0');
    }
    jitter_us = 0;
    if (jitter_value != nullptr && jitter_value[0] != '\0') {
        uint64_t v = 0;
        for (const char *p = jitter_value; *p; ++p) {
            if (*p < '0' || *p > '9' || v > 100000) {
                throw std::invalid_argument(
                    "ECO_GC_HELPER_JITTER_US must be an unsigned decimal <= 100000");
            }
            v = v * 10 + static_cast<uint64_t>(*p - '0');
        }
        if (v > 100000) {
            throw std::invalid_argument(
                "ECO_GC_HELPER_JITTER_US must be an unsigned decimal <= 100000");
        }
        jitter_us = static_cast<uint32_t>(v);
    }
}

// threaded-gc-05b: ECO_GC_MARK_THREADS (decimal 0..64) wins over JSON.
void applyMarkThreadsEnv(HeapConfig &cfg, const char *value) {
    if (value == nullptr || value[0] == '\0') return;
    uint64_t v = 0;
    for (const char *p = value; *p; ++p) {
        if (*p < '0' || *p > '9' || v > 64) {
            throw std::invalid_argument("ECO_GC_MARK_THREADS must be an unsigned decimal <= 64");
        }
        v = v * 10 + static_cast<uint64_t>(*p - '0');
    }
    if (v > 64) throw std::invalid_argument("ECO_GC_MARK_THREADS must be <= 64");
    cfg.gc_mark_threads = static_cast<uint32_t>(v);
}

// threaded-gc-06: ECO_GC_MINOR_THREADS (decimal 0..64) wins over JSON.
void applyMinorThreadsEnv(HeapConfig &cfg, const char *value) {
    if (value == nullptr || value[0] == '\0') return;
    uint64_t v = 0;
    for (const char *p = value; *p; ++p) {
        if (*p < '0' || *p > '9' || v > 64) {
            throw std::invalid_argument("ECO_GC_MINOR_THREADS must be an unsigned decimal <= 64");
        }
        v = v * 10 + static_cast<uint64_t>(*p - '0');
    }
    if (v > 64) throw std::invalid_argument("ECO_GC_MINOR_THREADS must be <= 64");
    cfg.gc_minor_threads = static_cast<uint32_t>(v);
}

// threaded-gc-05c: ECO_GC_CONC_MARK (exactly one of "0", "1", "2") and
// ECO_GC_CONC_MARK_THREADS (decimal 0..63) win over JSON.
void applyConcMarkEnv(HeapConfig &cfg, const char *mode_value, const char *threads_value) {
    if (mode_value != nullptr && mode_value[0] != '\0') {
        if (mode_value[1] != '\0' || mode_value[0] < '0' || mode_value[0] > '2') {
            throw std::invalid_argument("ECO_GC_CONC_MARK must be 0, 1 or 2");
        }
        cfg.conc_mark = static_cast<uint32_t>(mode_value[0] - '0');
    }
    if (threads_value != nullptr && threads_value[0] != '\0') {
        uint64_t v = 0;
        for (const char *p = threads_value; *p; ++p) {
            if (*p < '0' || *p > '9' || v > 63) {
                throw std::invalid_argument(
                    "ECO_GC_CONC_MARK_THREADS must be an unsigned decimal <= 63");
            }
            v = v * 10 + static_cast<uint64_t>(*p - '0');
        }
        if (v > 63) throw std::invalid_argument("ECO_GC_CONC_MARK_THREADS must be <= 63");
        cfg.conc_mark_threads = static_cast<uint32_t>(v);
    }
}

// threaded-gc-07: ECO_NURSERY_REGIONS ("0"/"1"/"2" = auto), ECO_TENURE_MODE ("1"/"2")
// and ECO_NURSERY_EDEN_FLIP ("-1"/"0"/"1") win over JSON (nullptr = unset).
void applyRegionEnv(HeapConfig &cfg, const char *regions_value, const char *mode_value,
                    const char *flip_value) {
    if (regions_value != nullptr && regions_value[0] != '\0') {
        if (regions_value[1] != '\0' || regions_value[0] < '0' || regions_value[0] > '2')
            throw std::invalid_argument("ECO_NURSERY_REGIONS must be 0, 1 or 2 (auto)");
        cfg.nursery_regions = static_cast<uint32_t>(regions_value[0] - '0');
    }
    if (mode_value != nullptr && mode_value[0] != '\0') {
        if (mode_value[1] != '\0' || (mode_value[0] != '1' && mode_value[0] != '2'))
            throw std::invalid_argument("ECO_TENURE_MODE must be 1 or 2");
        cfg.tenure_mode = static_cast<uint32_t>(mode_value[0] - '0');
    }
    if (flip_value != nullptr && flip_value[0] != '\0') {
        const std::string f(flip_value);
        if (f == "-1") cfg.nursery_region_eden_flip = -1;
        else if (f == "0") cfg.nursery_region_eden_flip = 0;
        else if (f == "1") cfg.nursery_region_eden_flip = 1;
        else throw std::invalid_argument("ECO_NURSERY_EDEN_FLIP must be -1, 0 or 1");
    }
}

void applyGcThreadEnv(HeapConfig &cfg, uint32_t &jitter_us) {
    applyGcThreadEnv(cfg, jitter_us, std::getenv("ECO_GC_THREAD"),
                     std::getenv("ECO_GC_HELPER_JITTER_US"));
    applyMarkThreadsEnv(cfg, std::getenv("ECO_GC_MARK_THREADS"));
    applyMinorThreadsEnv(cfg, std::getenv("ECO_GC_MINOR_THREADS"));
    applyConcMarkEnv(cfg, std::getenv("ECO_GC_CONC_MARK"),
                     std::getenv("ECO_GC_CONC_MARK_THREADS"));
    applyRegionEnv(cfg, std::getenv("ECO_NURSERY_REGIONS"), std::getenv("ECO_TENURE_MODE"),
                   std::getenv("ECO_NURSERY_EDEN_FLIP"));
    if (const char* e = std::getenv("ECO_TENURE_COLLECTORS"); e != nullptr && e[0] != '\0') {
        char* end = nullptr;
        const unsigned long v = std::strtoul(e, &end, 10);
        if (end == e || *end != '\0' || v < 1 || v > 32)
            throw std::invalid_argument("ECO_TENURE_COLLECTORS must be a decimal in [1, 32]");
        cfg.tenure_collector_threads = static_cast<uint32_t>(v);
    }
    if (const char* e = std::getenv("ECO_TENURE_FIFO"); e != nullptr && e[0] != '\0') {
        if (e[1] != '\0' || (e[0] != '0' && e[0] != '1'))
            throw std::invalid_argument("ECO_TENURE_FIFO must be 0 or 1");
        cfg.tenure_fifo_order = e[0] == '1';
    }
}

} // namespace Elm
