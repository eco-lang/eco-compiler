#include <chrono>
#include <cstring>
#include <getopt.h>
#include <iostream>
#include <optional>
#include <rapidcheck.h>
#include <unordered_set>
#include <vector>
#include "GarbageCollector.hpp"
#include "GarbageCollectorTest.hpp"
#include "Heap.hpp"
#include "HeapGenerators.hpp"
#include "HeapSnapshot.hpp"
#include "CompactionTest.hpp"
#include "OldGenSpaceTest.hpp"
#include "TestSuite.hpp"
#include "TLABTest.hpp"

using namespace Elm;

// ============================================================================
// Test Configuration
// ============================================================================

struct TestConfig {
    int num_tests = 100;
    int max_size = 100;
    int max_discard_ratio = 10;
    std::optional<uint64_t> seed;
    bool verbose = false;
    bool list_tests = false;
    bool show_seed = true;
    int repeat = 1;
    std::optional<std::chrono::seconds> duration;
    std::string filter = "";
    bool no_shrink = false;
    std::string reproduce = "";
};

// ============================================================================
// Command Line Parsing and Helpers
// ============================================================================

// Parse duration string like "30s", "5m", "2h", "1d"
std::optional<std::chrono::seconds> parseDuration(const std::string& str) {
    if (str.empty()) {
        return std::nullopt;
    }

    size_t i = 0;
    while (i < str.length() && std::isdigit(str[i])) {
        i++;
    }

    if (i == 0 || i == str.length()) {
        std::cerr << "Error: Invalid duration format. Expected format: <number><unit> (e.g., 30s, 5m, 2h, 1d)\n";
        return std::nullopt;
    }

    long long value = std::stoll(str.substr(0, i));
    std::string unit = str.substr(i);

    if (unit == "s" || unit == "sec" || unit == "seconds") {
        return std::chrono::seconds(value);
    } else if (unit == "m" || unit == "min" || unit == "minutes") {
        return std::chrono::seconds(value * 60);
    } else if (unit == "h" || unit == "hr" || unit == "hours") {
        return std::chrono::seconds(value * 3600);
    } else if (unit == "d" || unit == "day" || unit == "days") {
        return std::chrono::seconds(value * 86400);
    } else {
        std::cerr << "Error: Unknown time unit '" << unit << "'. Valid units: s, m, h, d\n";
        return std::nullopt;
    }
}

std::string formatDuration(std::chrono::seconds total_seconds) {
    long long seconds = total_seconds.count();

    if (seconds < 60) {
        return std::to_string(seconds) + "s";
    } else if (seconds < 3600) {
        long long minutes = seconds / 60;
        long long secs = seconds % 60;
        if (secs == 0) {
            return std::to_string(minutes) + "m";
        }
        return std::to_string(minutes) + "m " + std::to_string(secs) + "s";
    } else if (seconds < 86400) {
        long long hours = seconds / 3600;
        long long mins = (seconds % 3600) / 60;
        if (mins == 0) {
            return std::to_string(hours) + "h";
        }
        return std::to_string(hours) + "h " + std::to_string(mins) + "m";
    } else {
        long long days = seconds / 86400;
        long long hours = (seconds % 86400) / 3600;
        if (hours == 0) {
            return std::to_string(days) + "d";
        }
        return std::to_string(days) + "d " + std::to_string(hours) + "h";
    }
}

void printHelp(const char* program_name) {
    std::cout << "Usage: " << program_name << " [OPTIONS]\n\n";
    std::cout << "Eco Runtime GC Property-Based Test Suite\n\n";
    std::cout << "Options:\n";
    std::cout << "  -n, --num-tests <N>         Number of test iterations (default: 100)\n";
    std::cout << "  -s, --seed <SEED>           Random seed for reproducibility\n";
    std::cout << "      --max-size <N>          Maximum size parameter for generators (default: 100)\n";
    std::cout << "      --max-discard-ratio <N> Maximum ratio of discarded tests (default: 10)\n";
    std::cout << "  -v, --verbose               Verbose output with statistics\n";
    std::cout << "      --list                  List available tests without running\n";
    std::cout << "      --filter <PATTERN>      Run only tests matching pattern\n";
    std::cout << "      --repeat <N>            Run entire test suite N times (default: 1)\n";
    std::cout << "  -t, --duration <TIME>       Run tests for specified duration (e.g., 30s, 5m, 2h, 1d)\n";
    std::cout << "                              Units: s (seconds), m (minutes), h (hours), d (days)\n";
    std::cout << "      --no-shrink             Disable test case shrinking on failure\n";
    std::cout << "      --reproduce <STRING>    Reproduce specific failing case\n";
    std::cout << "      --no-show-seed          Don't display the seed being used\n";
    std::cout << "  -h, --help                  Display this help message\n";
    std::cout << "\nExamples:\n";
    std::cout << "  " << program_name << " -n 1000              # Run 1000 tests\n";
    std::cout << "  " << program_name << " --seed 42            # Use specific seed\n";
    std::cout << "  " << program_name << " --filter preserve    # Run only 'preserve' tests\n";
    std::cout << "  " << program_name << " -n 500 --repeat 10   # Stress test (10 iterations)\n";
    std::cout << "  " << program_name << " --duration 30s       # Run tests for 30 seconds\n";
    std::cout << "  " << program_name << " --duration 2h        # Run tests for 2 hours\n";
    std::cout << std::endl;
}


void configureRapidCheck(const TestConfig& config) {
    // RapidCheck's configuration is tricky to modify programmatically
    // We'll use environment variable approach as a workaround
    std::string rc_params = "";

    if (config.seed.has_value()) {
        rc_params = "seed=" + std::to_string(config.seed.value());
    }

    rc_params += " max_success=" + std::to_string(config.num_tests);
    rc_params += " max_size=" + std::to_string(config.max_size);
    rc_params += " max_discard_ratio=" + std::to_string(config.max_discard_ratio);

    // Set RC_PARAMS environment variable
    setenv("RC_PARAMS", rc_params.c_str(), 1);

    // Note: RapidCheck will read RC_PARAMS when check() is called
}

TestConfig parseCommandLine(int argc, char* argv[]) {
    TestConfig config;

    static struct option long_options[] = {
        {"num-tests",          required_argument, 0, 'n'},
        {"seed",               required_argument, 0, 's'},
        {"max-size",           required_argument, 0, 'M'},
        {"max-discard-ratio",  required_argument, 0, 'D'},
        {"verbose",            no_argument,       0, 'v'},
        {"list",               no_argument,       0, 'L'},
        {"filter",             required_argument, 0, 'f'},
        {"repeat",             required_argument, 0, 'r'},
        {"duration",           required_argument, 0, 't'},
        {"no-shrink",          no_argument,       0, 'N'},
        {"reproduce",          required_argument, 0, 'R'},
        {"no-show-seed",       no_argument,       0, 'S'},
        {"help",               no_argument,       0, 'h'},
        {0, 0, 0, 0}
    };

    int opt;
    int option_index = 0;

    while ((opt = getopt_long(argc, argv, "n:s:vhf:r:t:", long_options, &option_index)) != -1) {
        switch (opt) {
            case 'n':
                config.num_tests = std::atoi(optarg);
                if (config.num_tests <= 0) {
                    std::cerr << "Error: num-tests must be positive\n";
                    exit(1);
                }
                break;
            case 's':
                config.seed = std::stoull(optarg);
                break;
            case 'M':
                config.max_size = std::atoi(optarg);
                if (config.max_size <= 0) {
                    std::cerr << "Error: max-size must be positive\n";
                    exit(1);
                }
                break;
            case 'D':
                config.max_discard_ratio = std::atoi(optarg);
                if (config.max_discard_ratio <= 0) {
                    std::cerr << "Error: max-discard-ratio must be positive\n";
                    exit(1);
                }
                break;
            case 'v':
                config.verbose = true;
                break;
            case 'L':
                config.list_tests = true;
                break;
            case 'f':
                config.filter = optarg;
                break;
            case 'r':
                config.repeat = std::atoi(optarg);
                if (config.repeat <= 0) {
                    std::cerr << "Error: repeat must be positive\n";
                    exit(1);
                }
                break;
            case 't': {
                auto duration = parseDuration(optarg);
                if (!duration.has_value()) {
                    exit(1);
                }
                config.duration = duration;
                break;
            }
            case 'N':
                config.no_shrink = true;
                break;
            case 'R':
                config.reproduce = optarg;
                break;
            case 'S':
                config.show_seed = false;
                break;
            case 'h':
                printHelp(argv[0]);
                exit(0);
            case '?':
                // getopt_long already printed an error message
                std::cerr << "Use -h or --help for usage information\n";
                exit(1);
            default:
                exit(1);
        }
    }

    // Validate that --repeat and --duration are not both specified
    if (config.repeat > 1 && config.duration.has_value()) {
        std::cerr << "Error: --repeat and --duration cannot be used together\n";
        exit(1);
    }

    return config;
}

// ============================================================================
// Property Tests
// ============================================================================

int main(int argc, char* argv[]) {
    TestConfig config = parseCommandLine(argc, argv);

    // Create test suite and add tests
    Testing::TestSuite suite;

    // GC Tests
    suite.add(testGCPreservesRoots);
    suite.add(testMultipleGCCycles);
    suite.add(testContinuousGarbageAllocation);

    // TLAB Tests
    suite.add(testTLABMetricsOnEmpty);
    suite.add(testTLABMetricsAfterAllocation);
    suite.add(testTLABAllocationFillsCorrectly);

    // OldGenSpace Tests
    suite.add(testAllocateTLAB);
    suite.add(testRootsMarkedAtStart);
    suite.add(testRootsPreservedAfterIncrementalMark);
    suite.add(testRootsPreservedAfterSweep);
    suite.add(testGarbageUnmarkedInIncrementalSteps);
    suite.add(testGarbageFreeListedAfterSweep);

    // Compaction Tests
    suite.add(testBlockInitialization);
    suite.add(testBlockLiveInfoTracking);
    suite.add(testCompactionSetSelection);
    suite.add(testObjectEvacuationWithForwarding);
    suite.add(testReadBarrierSelfHealing);
    suite.add(testBlockEvacuation);
    suite.add(testBlockReclaimToTLABs);
    suite.add(testCompactionPreservesValues);
    suite.add(testRootPointerUpdatesAfterCompaction);
    suite.add(testFragmentationDefragmentation);

    // Handle --list option
    if (config.list_tests) {
        std::cout << "Available tests:\n";
        auto test_names = suite.listTests();
        for (size_t i = 0; i < test_names.size(); i++) {
            std::cout << "  " << (i + 1) << ". " << test_names[i] << "\n";
        }
        return 0;
    }

    // Configure RapidCheck with command line parameters
    configureRapidCheck(config);

    std::cout << "=== Eco Runtime GC Property-Based Tests ===" << std::endl;

    if (config.show_seed && config.seed.has_value()) {
        std::cout << "Using configuration: seed=" << config.seed.value() << std::endl;
    }

    if (config.verbose) {
        std::cout << "Configuration:" << std::endl;
        std::cout << "  Tests per suite: " << config.num_tests << std::endl;
        std::cout << "  Max size: " << config.max_size << std::endl;
        std::cout << "  Max discard ratio: " << config.max_discard_ratio << std::endl;
        if (config.duration.has_value()) {
            std::cout << "  Duration: " << formatDuration(config.duration.value()) << std::endl;
        } else {
            std::cout << "  Repeat: " << config.repeat << std::endl;
        }
        if (!config.filter.empty()) {
            std::cout << "  Filter: \"" << config.filter << "\"" << std::endl;
        }
    }

    std::cout << std::endl;

    // Run tests (potentially multiple times or for a duration)
    if (config.duration.has_value()) {
        // Time-based test execution
        auto start_time = std::chrono::steady_clock::now();
        auto end_time = start_time + config.duration.value();
        int iteration = 1;

        std::cout << "Running tests for " << formatDuration(config.duration.value()) << "..." << std::endl;
        std::cout << std::endl;

        while (std::chrono::steady_clock::now() < end_time) {
            auto current_time = std::chrono::steady_clock::now();
            auto elapsed = std::chrono::duration_cast<std::chrono::seconds>(current_time - start_time);
            auto remaining = std::chrono::duration_cast<std::chrono::seconds>(end_time - current_time);

            std::cout << "=== Iteration " << iteration
                      << " (Elapsed: " << formatDuration(elapsed)
                      << ", Remaining: " << formatDuration(remaining) << ") ===" << std::endl;
            std::cout << std::endl;

            // Run all tests (or filtered subset)
            suite.run(config.filter);

            iteration++;

            // Check if we still have time for another iteration
            if (std::chrono::steady_clock::now() < end_time) {
                std::cout << std::endl;
            }
        }

        auto total_elapsed = std::chrono::duration_cast<std::chrono::seconds>(
            std::chrono::steady_clock::now() - start_time);
        std::cout << std::endl;
        std::cout << "Completed " << (iteration - 1) << " iterations in "
                  << formatDuration(total_elapsed) << std::endl;
    } else {
        // Iteration-based test execution
        for (int iteration = 1; iteration <= config.repeat; iteration++) {
            if (config.repeat > 1) {
                std::cout << "=== Iteration " << iteration << " of " << config.repeat << " ===" << std::endl;
                std::cout << std::endl;
            }

            // Run all tests (or filtered subset)
            suite.run(config.filter);

            if (config.repeat > 1 && iteration < config.repeat) {
                std::cout << std::endl;
            }
        }
    }

#if ENABLE_GC_STATS
    // Print GC statistics after all tests complete
    // Combine thread-local nursery stats with global major GC stats
    auto &gc = GarbageCollector::instance();
    auto *nursery = gc.getNursery();
    if (nursery) {
        // Start with a copy of the nursery stats (Minor GC + TLAB)
        GCStats combined_stats = nursery->getStats();

        // Combine with global Major GC stats
        combined_stats.combine(gc.getMajorGCStats());

        // Print the combined statistics
        combined_stats.print();
    }
#endif

    return 0;
}
