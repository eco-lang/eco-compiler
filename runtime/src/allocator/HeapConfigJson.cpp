#include "HeapConfigJson.hpp"

#include <cctype>
#include <cstdint>
#include <cstdlib>
#include <fstream>
#include <stdexcept>
#include <string>

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
        "initial_old_gen_size",
        "alloc_buffer_size",
        "nursery_block_count",
        "nursery_max_block_count",
        "promotion_age",
        "nursery_gc_threshold",
        "nursery_growth_threshold",
        "major_gc_initiating_occupancy",
        "major_gc_target_utilization",
        "major_gc_garbage_fraction",
        "use_hybrid_dfs",
        "large_object_threshold",
        "decommit_on_oldgen_release",
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
    if (auto it = doc.find("major_gc_target_utilization"); it != doc.end())
        cfg.major_gc_target_utilization =
            parseFraction(*it, "major_gc_target_utilization");
    if (auto it = doc.find("major_gc_garbage_fraction"); it != doc.end())
        cfg.major_gc_garbage_fraction =
            parseFraction(*it, "major_gc_garbage_fraction");
    if (auto it = doc.find("use_hybrid_dfs"); it != doc.end())
        cfg.use_hybrid_dfs = parseBool(*it, "use_hybrid_dfs");
    if (auto it = doc.find("large_object_threshold"); it != doc.end())
        cfg.large_object_threshold =
            parseByteSize(*it, "large_object_threshold");
    if (auto it = doc.find("decommit_on_oldgen_release"); it != doc.end())
        cfg.decommit_on_oldgen_release =
            parseBool(*it, "decommit_on_oldgen_release");
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

} // namespace Elm
