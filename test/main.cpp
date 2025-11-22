#include <chrono>
#include <cstring>
#include <getopt.h>
#include <iostream>
#include <optional>
#include <rapidcheck.h>
#include <unordered_set>
#include <vector>
#include "GarbageCollector.hpp"
#include "NurserySpaceTest.hpp"
#include "Heap.hpp"
#include "HeapGenerators.hpp"
#include "HeapSnapshot.hpp"
#include "CompactionTest.hpp"
#include "GarbageCollectorTest.hpp"
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
    std::optional<std::chrono::seconds> duration;  // Run repeatedly for this long.
    std::optional<std::chrono::seconds> timeout;   // Fail if tests exceed this.
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
    std::cout << "  -t, --duration <TIME>       Run tests repeatedly for specified duration (e.g., 30s, 5m, 2h)\n";
    std::cout << "                              Tests cycle until time expires, then exit successfully\n";
    std::cout << "      --timeout <TIME>        Maximum allowed time for test run (e.g., 5m, 1h)\n";
    std::cout << "                              Exit with failure if tests exceed this time\n";
    std::cout << "                              Time units: s (seconds), m (minutes), h (hours), d (days)\n";
    std::cout << "      --no-shrink             Disable test case shrinking on failure\n";
    std::cout << "      --reproduce <STRING>    Reproduce specific failing case\n";
    std::cout << "      --no-show-seed          Don't display the seed being used\n";
    std::cout << "  -h, --help                  Display this help message\n";
    std::cout << "\nExamples:\n";
    std::cout << "  " << program_name << " -n 1000              # Run 1000 tests\n";
    std::cout << "  " << program_name << " --seed 42            # Use specific seed\n";
    std::cout << "  " << program_name << " --filter preserve    # Run only 'preserve' tests\n";
    std::cout << "  " << program_name << " -n 500 --repeat 10   # Stress test (10 iterations)\n";
    std::cout << "  " << program_name << " --duration 30s       # Run tests repeatedly for 30 seconds\n";
    std::cout << "  " << program_name << " --timeout 5m         # Fail if tests take longer than 5 minutes\n";
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
        {"timeout",            required_argument, 0, 'T'},
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
            case 'T': {
                auto timeout = parseDuration(optarg);
                if (!timeout.has_value()) {
                    exit(1);
                }
                config.timeout = timeout;
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

    // --timeout can be combined with --repeat or used alone, but not with --duration
    if (config.duration.has_value() && config.timeout.has_value()) {
        std::cerr << "Error: --duration and --timeout cannot be used together\n";
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

    // NurserySpace (Minor GC) Tests
    suite.add(testMinorGCPreservesRoots);
    suite.add(testMultipleMinorGCCycles);
    suite.add(testContinuousGarbageAllocation);

    // TLAB Tests
    suite.add(testTLABMetricsOnEmpty);
    suite.add(testTLABMetricsAfterAllocation);
    suite.add(testTLABAllocationFillsCorrectly);
    suite.add(testTLABFillAndSeal);

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

    // Full GarbageCollector Tests (Minor + Major GC)
    suite.add(testPromotionToOldGen);
    suite.add(testMinorThenMajorGCSequence);
    suite.add(testLongLivedObjectsSurviveMajorGC);
    suite.add(testMajorGCReclaimsOldGenGarbage);
    suite.add(testFullGCCycleWithCompaction);
    suite.add(testMixedAllocationWorkload);
    suite.add(testObjectGraphSpanningPromotions);
    suite.add(testMultipleMajorGCCycles);
    suite.add(testStressTestBothGenerations);

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
        if (config.timeout.has_value()) {
            std::cout << "  Timeout: " << formatDuration(config.timeout.value()) << std::endl;
        }
        if (!config.filter.empty()) {
            std::cout << "  Filter: \"" << config.filter << "\"" << std::endl;
        }
    }

    std::cout << std::endl;

    // Run tests (potentially multiple times or for a duration)
    int exit_code = 0;

    if (config.duration.has_value()) {
        // Duration mode: run tests repeatedly until time expires, then exit successfully
        Testing::Deadline::setDuration(config.duration.value());
        auto start_time = std::chrono::steady_clock::now();
        int iteration = 1;
        size_t total_tests_run = 0;

        std::cout << "Running tests for " << formatDuration(config.duration.value()) << "..." << std::endl;
        std::cout << std::endl;

        while (!Testing::Deadline::durationExpired()) {
            auto current_time = std::chrono::steady_clock::now();
            auto elapsed = std::chrono::duration_cast<std::chrono::seconds>(current_time - start_time);
            auto remaining = config.duration.value() - elapsed;
            if (remaining.count() < 0) remaining = std::chrono::seconds(0);

            std::cout << "=== Iteration " << iteration
                      << " (Elapsed: " << formatDuration(elapsed)
                      << ", Remaining: " << formatDuration(remaining) << ") ===" << std::endl;
            std::cout << std::endl;

            // Run all tests (or filtered subset)
            auto result = suite.run(config.filter);
            total_tests_run += result.tests_run;

            if (result.duration_expired) {
                // Duration expired mid-suite - this is fine, just stop
                break;
            }

            iteration++;

            // Check if we still have time for another iteration
            if (!Testing::Deadline::durationExpired()) {
                std::cout << std::endl;
            }
        }

        auto total_elapsed = std::chrono::duration_cast<std::chrono::seconds>(
            std::chrono::steady_clock::now() - start_time);
        std::cout << std::endl;
        std::cout << "Completed " << total_tests_run << " tests across "
                  << iteration << " iteration(s) in "
                  << formatDuration(total_elapsed) << std::endl;

        Testing::Deadline::clear();
        // exit_code stays 0 - duration expiring is success
    } else {
        // Iteration-based test execution (with optional timeout)
        if (config.timeout.has_value()) {
            Testing::Deadline::setTimeout(config.timeout.value());
        }

        for (int iteration = 1; iteration <= config.repeat; iteration++) {
            if (config.repeat > 1) {
                std::cout << "=== Iteration " << iteration << " of " << config.repeat << " ===" << std::endl;
                std::cout << std::endl;
            }

            // Run all tests (or filtered subset)
            auto result = suite.run(config.filter);

            if (result.timeout_expired) {
                std::cerr << std::endl;
                std::cerr << "TIMEOUT: Tests exceeded " << formatDuration(config.timeout.value())
                          << " limit after " << result.tests_run << " of "
                          << result.tests_total << " tests in iteration " << iteration << std::endl;
                exit_code = 1;
                break;
            }

            if (config.repeat > 1 && iteration < config.repeat) {
                std::cout << std::endl;
            }
        }

        Testing::Deadline::clear();
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

    return exit_code;
}
