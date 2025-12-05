#include <chrono>
#include <cstring>
#include <getopt.h>
#include <iostream>
#include <optional>
#include <rapidcheck.h>
#include <set>
#include <sstream>
#include <unordered_set>
#include <vector>
#include "Allocator.hpp"
#include "allocator/AllocatorCommonTest.hpp"
#include "allocator/NurserySpaceTest.hpp"
#include "Heap.hpp"
#include "allocator/HeapGenerators.hpp"
#include "allocator/HeapSnapshot.hpp"
#include "allocator/ElmTest.hpp"
#include "allocator/AllocatorTest.hpp"
#include "allocator/OldGenSpaceTest.hpp"
#include "allocator/HeapHelpersTest.hpp"
#include "allocator/StringOpsTest.hpp"
#include "allocator/ListOpsTest.hpp"
#include "allocator/BytesOpsTest.hpp"
#include "TestSuite.hpp"

using namespace Elm;

// ============================================================================
// Test Configuration
// ============================================================================

/**
 * Configuration for the test runner.
 *
 * Populated from command line arguments.
 */
struct TestConfig {
    int num_tests = 5;                             // Number of test iterations per property.
    int max_size = 50;                             // Maximum size parameter for generators.
    int max_discard_ratio = 10;                    // Maximum ratio of discarded tests.
    std::optional<uint64_t> seed;                  // Random seed for reproducibility.
    bool verbose = false;                          // Enable verbose output.
    bool list_tests = false;                       // List tests without running.
    bool show_seed = true;                         // Display the seed being used.
    int repeat = 1;                                // Number of times to repeat the suite.
    std::optional<std::chrono::seconds> duration;  // Run repeatedly for this long.
    std::optional<std::chrono::seconds> timeout;   // Fail if tests exceed this.
    std::string filter = "";                       // Filter pattern for test names.
    bool no_shrink = false;                        // Disable test case shrinking.
    std::string reproduce = "";                    // Reproduction string for failing test.
    bool interactive = false;                      // Interactive test selection mode.
};

// ============================================================================
// Command Line Parsing and Helpers
// ============================================================================

// Parses a duration string like "30s", "5m", "2h", "1d".
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

// Formats a duration as a human-readable string.
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

// Prints usage information to stdout.
void printHelp(const char* program_name) {
    std::cout << "Usage: " << program_name << " [OPTIONS]\n\n";
    std::cout << "Eco Runtime GC Property-Based Test Suite\n\n";
    std::cout << "Options:\n";
    std::cout << "  -n, --num-tests <N>         Number of test iterations (default: 5)\n";
    std::cout << "  -s, --seed <SEED>           Random seed for reproducibility\n";
    std::cout << "      --max-size <N>          Maximum size parameter for generators (default: 50)\n";
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
    std::cout << "  -i, --interactive           Interactive mode: select tests/suites to run\n";
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


// Global seed used for test run (for summary reporting).
static uint64_t g_test_seed = 0;

// Generates a random seed based on current time.
static uint64_t generateRandomSeed() {
    auto now = std::chrono::high_resolution_clock::now();
    auto nanos = std::chrono::duration_cast<std::chrono::nanoseconds>(
        now.time_since_epoch()).count();
    return static_cast<uint64_t>(nanos);
}

// Configures RapidCheck via environment variables.
// Returns the seed being used.
uint64_t configureRapidCheck(const TestConfig& config) {
    // RapidCheck's configuration is tricky to modify programmatically.
    // We use the environment variable approach as a workaround.
    std::string rc_params = "";

    // Use provided seed or generate one.
    uint64_t seed = config.seed.has_value() ? config.seed.value() : generateRandomSeed();
    rc_params = "seed=" + std::to_string(seed);

    rc_params += " max_success=" + std::to_string(config.num_tests);
    rc_params += " max_size=" + std::to_string(config.max_size);
    rc_params += " max_discard_ratio=" + std::to_string(config.max_discard_ratio);

    // Set RC_PARAMS environment variable.
    setenv("RC_PARAMS", rc_params.c_str(), 1);

    // Store globally for summary reporting.
    g_test_seed = seed;

    // Note: RapidCheck will read RC_PARAMS when check() is called.
    return seed;
}

// Prints the test run summary.
void printTestSummary(const Testing::TestSuiteResult& result, uint64_t seed) {
    std::cout << std::endl;
    std::cout << "=== Test Summary ===" << std::endl;
    std::cout << std::endl;

    // Print pass/fail counts.
    std::cout << "Tests run:    " << result.tests_run << std::endl;
    std::cout << "Tests passed: " << result.tests_passed << std::endl;
    std::cout << "Tests failed: " << result.tests_failed << std::endl;

    // Print overall result.
    std::cout << std::endl;
    if (result.tests_failed == 0) {
        std::cout << "Result: PASSED" << std::endl;
    } else {
        std::cout << "Result: FAILED" << std::endl;
        std::cout << std::endl;

        // List failed tests.
        std::cout << "Failed tests:" << std::endl;
        for (const auto& failed : result.failed_tests) {
            std::cout << "  - " << failed.name << std::endl;
        }

        // Print seed for reproduction.
        std::cout << std::endl;
        std::cout << "To reproduce failures, run with: --seed " << seed << std::endl;
    }
}

// Parses command line arguments into a TestConfig.
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
        {"interactive",        no_argument,       0, 'i'},
        {"help",               no_argument,       0, 'h'},
        {0, 0, 0, 0}
    };

    int opt;
    int option_index = 0;

    while ((opt = getopt_long(argc, argv, "n:s:vhf:r:t:i", long_options, &option_index)) != -1) {
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
            case 'i':
                config.interactive = true;
                break;
            case 'h':
                printHelp(argv[0]);
                exit(0);
            case '?':
                // getopt_long already printed an error message.
                std::cerr << "Use -h or --help for usage information\n";
                exit(1);
            default:
                exit(1);
        }
    }

    // Validate that --repeat and --duration are not both specified.
    if (config.repeat > 1 && config.duration.has_value()) {
        std::cerr << "Error: --repeat and --duration cannot be used together\n";
        exit(1);
    }

    // --timeout can be combined with --repeat or used alone, but not with --duration.
    if (config.duration.has_value() && config.timeout.has_value()) {
        std::cerr << "Error: --duration and --timeout cannot be used together\n";
        exit(1);
    }

    return config;
}

// ============================================================================
// Interactive Mode
// ============================================================================

// Parses user input for selections: numbers, ranges (1..5), or 'A' for all.
// Returns empty set on parse error or quit.
std::set<size_t> parseSelections(const std::string& input, size_t max_val) {
    std::set<size_t> selections;
    std::istringstream iss(input);
    std::string token;

    while (iss >> token) {
        // Check for 'A' or 'a' (all).
        if (token == "A" || token == "a") {
            for (size_t i = 1; i <= max_val; i++) {
                selections.insert(i);
            }
            return selections;
        }

        // Check for 'Q' or 'q' (quit). Returns special empty marker.
        if (token == "Q" || token == "q") {
            return {};
        }

        // Check for range (e.g., "1..5").
        size_t dot_pos = token.find("..");
        if (dot_pos != std::string::npos) {
            try {
                size_t start = std::stoul(token.substr(0, dot_pos));
                size_t end = std::stoul(token.substr(dot_pos + 2));
                if (start < 1 || end > max_val || start > end) {
                    return {};
                }
                for (size_t i = start; i <= end; i++) {
                    selections.insert(i);
                }
            } catch (...) {
                return {};
            }
        } else {
            // Single number.
            try {
                size_t num = std::stoul(token);
                if (num < 1 || num > max_val) {
                    return {};
                }
                selections.insert(num);
            } catch (...) {
                return {};
            }
        }
    }

    return selections;
}

// Prints help for interactive mode commands.
void printInteractiveHelp() {
    std::cout << "\nUsage:\n";
    std::cout << "  A         - Run all tests in current suite\n";
    std::cout << "  <num>     - Select item by number (e.g., 3)\n";
    std::cout << "  <nums>    - Select multiple items (e.g., 1 3 5)\n";
    std::cout << "  <range>   - Select range (e.g., 1..5)\n";
    std::cout << "  <mixed>   - Combine any of above (e.g., 1..3 5 7..9)\n";
    std::cout << "  Q         - Quit / go back\n";
    std::cout << std::endl;
}

// Runs the interactive test selection loop.
void runInteractive(const Testing::TestSuite& suite, const std::string& path = "") {
    while (true) {
        // Build display path.
        std::string display_path = path.empty() ? suite.getName() : path;

        const auto& children = suite.getChildren();
        if (children.empty()) {
            std::cout << "(No tests in this suite)\n";
            return;
        }

        std::cout << "\n=== " << display_path << " ===\n\n";

        // Display children with type indicators.
        for (size_t i = 0; i < children.size(); i++) {
            const auto& child = children[i];
            bool is_suite = dynamic_cast<const Testing::TestSuite*>(child.get()) != nullptr;
            std::cout << "  " << (i + 1) << ". ";
            if (is_suite) {
                std::cout << "[Suite] ";
            }
            std::cout << child->getName();
            if (is_suite) {
                auto* sub = static_cast<const Testing::TestSuite*>(child.get());
                std::cout << " (" << sub->countTests() << " tests)";
            }
            std::cout << "\n";
        }
        std::cout << "\n";

        // Prompt for input.
        std::cout << "Select (A=all, Q=back, ?=help): ";
        std::string input;
        if (!std::getline(std::cin, input)) {
            return;
        }

        // Trim whitespace.
        size_t start = input.find_first_not_of(" \t");
        if (start == std::string::npos) {
            continue;
        }
        input = input.substr(start);

        // Check for help.
        if (input == "?" || input == "help") {
            printInteractiveHelp();
            continue;
        }

        // Check for quit/back.
        if (input == "Q" || input == "q") {
            return;
        }

        // Parse selections.
        auto selections = parseSelections(input, children.size());
        if (selections.empty()) {
            std::cout << "Invalid input. Type '?' for help.\n";
            continue;
        }

        // Process selections.
        // If single selection and it's a suite, step into it.
        if (selections.size() == 1) {
            size_t idx = *selections.begin() - 1;
            const auto& child = children[idx];
            if (auto* sub_suite = dynamic_cast<const Testing::TestSuite*>(child.get())) {
                // Step into sub-suite.
                std::string new_path = display_path + " > " + sub_suite->getName();
                runInteractive(*sub_suite, new_path);
                continue;
            }
        }

        // Run selected tests/suites.
        std::cout << "\nRunning " << selections.size() << " item(s)...\n\n";
        for (size_t idx : selections) {
            const auto& child = children[idx - 1];
            if (auto* sub_suite = dynamic_cast<const Testing::TestSuite*>(child.get())) {
                std::cout << "=== " << sub_suite->getName() << " ===\n";
                sub_suite->run("");
            } else {
                child->run();
            }
        }
        std::cout << "\nDone. Press Enter to continue...";
        std::string dummy;
        std::getline(std::cin, dummy);
    }
}

// ============================================================================
// Main Entry Point
// ============================================================================

int main(int argc, char* argv[]) {
    TestConfig config = parseCommandLine(argc, argv);

    // Create test suites organized by component.
    Testing::TestSuite nurseryTests("NurserySpace");
    nurseryTests.add(testMinorGCPreservesRoots);
    nurseryTests.add(testMultipleMinorGCCycles);
    nurseryTests.add(testContinuousGarbageAllocation);
    // Hybrid DFS/BFS list tests
    nurseryTests.add(testListSurvivesGCWithHybridDFS);
    nurseryTests.add(testListSurvivesGCWithBFS);
    nurseryTests.add(testMultipleListsSurviveGCWithHybridDFS);
    nurseryTests.add(testMultipleListsSurviveGCWithBFS);
    nurseryTests.add(testListLocalityImprovedByHybridDFS);
    nurseryTests.add(testListSurvivesMultipleGCCyclesWithHybridDFS);
    nurseryTests.add(testListSurvivesMultipleGCCyclesWithBFS);
    nurseryTests.add(testDeepListLocalityCopying);

    Testing::TestSuite oldGenTests("OldGenSpace");
    oldGenTests.add(testOldGenAllocate);
    oldGenTests.add(testRootsMarkedAtStart);
    oldGenTests.add(testRootsPreservedAfterIncrementalMark);
    oldGenTests.add(testRootsPreservedAfterSweep);
    oldGenTests.add(testGarbageUnmarkedInIncrementalSteps);
    oldGenTests.add(testGarbageReclaimedAfterSweep);
    // Phase 1-2: Free-list allocation
    oldGenTests.add(testSizeClassCorrectness);
    oldGenTests.add(testFreeListRoundTrip);
    oldGenTests.add(testMixedSizeAllocation);
    // Phase 3: Lazy sweeping
    oldGenTests.add(testLazySweepPreservesLive);
    oldGenTests.add(testSweepProgressMonotonicity);
    oldGenTests.add(testAllocationDuringSweep);
    // Phase 4: Incremental marking
    oldGenTests.add(testIncrementalMarkEquivalence);
    oldGenTests.add(testMarkingWithAllocation);
    // Phase 5: Fragmentation statistics
    oldGenTests.add(testUtilizationCalculation);
    oldGenTests.add(testLiveBytesAccuracy);
    // Phase 6: Incremental compaction
    oldGenTests.add(testEvacuationPreservesValues);
    oldGenTests.add(testForwardingPointerCorrectness);
    // Integration / Stress tests
    oldGenTests.add(testMultipleCycleStability);
    oldGenTests.add(testHeaderConsistency);
    oldGenTests.add(testEmptyHeapBehavior);
    oldGenTests.add(testAllGarbageHeap);
    oldGenTests.add(testAllLiveHeap);

    Testing::TestSuite allocatorTests("Allocator");
    allocatorTests.add(testPromotionToOldGen);
    allocatorTests.add(testMinorThenMajorGCSequence);
    allocatorTests.add(testLongLivedObjectsSurviveMajorGC);
    allocatorTests.add(testMajorGCReclaimsOldGenGarbage);
    allocatorTests.add(testFullGCCycle);
    allocatorTests.add(testMixedAllocationWorkload);
    allocatorTests.add(testObjectGraphSpanningPromotions);
    allocatorTests.add(testMultipleMajorGCCycles);
    allocatorTests.add(testStressTestBothGenerations);

    Testing::TestSuite elmTests("Elm");
    elmTests.add(testElmNilConstant);
    elmTests.add(testElmConsAllocation);
    elmTests.add(testElmListFromInts);
    elmTests.add(testElmReverseEmpty);
    elmTests.add(testElmReverseSingle);
    elmTests.add(testElmReverseMultiple);
    elmTests.add(testElmReverseSurvivesGC);
    elmTests.add(testElmReverseLargeList);

    // Unit tests for AllocatorCommon.hpp (getObjectSize, etc.)
    Testing::TestSuite allocatorCommonTests("AllocatorCommon");
    // Fixed-size object tests
    allocatorCommonTests.add(testGetObjectSizeInt);
    allocatorCommonTests.add(testGetObjectSizeFloat);
    allocatorCommonTests.add(testGetObjectSizeChar);
    allocatorCommonTests.add(testGetObjectSizeTuple2);
    allocatorCommonTests.add(testGetObjectSizeTuple3);
    allocatorCommonTests.add(testGetObjectSizeCons);
    allocatorCommonTests.add(testGetObjectSizeProcess);
    allocatorCommonTests.add(testGetObjectSizeTask);
    allocatorCommonTests.add(testGetObjectSizeForward);
    // Variable-size object tests
    allocatorCommonTests.add(testGetObjectSizeString);
    allocatorCommonTests.add(testGetObjectSizeStringEdgeCases);
    allocatorCommonTests.add(testGetObjectSizeCustom);
    allocatorCommonTests.add(testGetObjectSizeCustomEdgeCases);
    allocatorCommonTests.add(testGetObjectSizeRecord);
    allocatorCommonTests.add(testGetObjectSizeRecordEdgeCases);
    allocatorCommonTests.add(testGetObjectSizeDynRecord);
    allocatorCommonTests.add(testGetObjectSizeDynRecordEdgeCases);
    allocatorCommonTests.add(testGetObjectSizeFieldGroup);
    allocatorCommonTests.add(testGetObjectSizeFieldGroupEdgeCases);
    // Closure tests
    allocatorCommonTests.add(testGetObjectSizeClosure);
    allocatorCommonTests.add(testGetObjectSizeClosureEdgeCases);
    // Alignment and edge case tests
    allocatorCommonTests.add(testGetObjectSizeAlwaysAligned);
    allocatorCommonTests.add(testGetObjectSizeUnknownTag);
    allocatorCommonTests.add(testGetObjectSizeAllTagsExhaustive);

    // Heap helpers tests
    Testing::TestSuite heapHelpersTests("HeapHelpers");
    registerHeapHelpersTests(heapHelpersTests);

    // String operations tests
    Testing::TestSuite stringOpsTests("StringOps");
    registerStringOpsTests(stringOpsTests);

    // List operations tests
    Testing::TestSuite listOpsTests("ListOps");
    registerListOpsTests(listOpsTests);

    // Bytes operations tests
    Testing::TestSuite bytesOpsTests("BytesOps");
    registerBytesOpsTests(bytesOpsTests);

    // Root suite containing all sub-suites.
    Testing::TestSuite suite("All Tests");
    suite.add(std::move(nurseryTests));
    suite.add(std::move(oldGenTests));
    suite.add(std::move(allocatorTests));
    suite.add(std::move(elmTests));
    suite.add(std::move(allocatorCommonTests));
    suite.add(std::move(heapHelpersTests));
    suite.add(std::move(stringOpsTests));
    suite.add(std::move(listOpsTests));
    suite.add(std::move(bytesOpsTests));

    // Handle --list option.
    if (config.list_tests) {
        std::cout << "Available tests:\n";
        auto test_names = suite.listTests();
        for (size_t i = 0; i < test_names.size(); i++) {
            std::cout << "  " << (i + 1) << ". " << test_names[i] << "\n";
        }
        return 0;
    }

    // Handle --interactive option.
    if (config.interactive) {
        configureRapidCheck(config);
        std::cout << "=== Eco Runtime GC Tests - Interactive Mode ===" << std::endl;
        runInteractive(suite);
        return 0;
    }

    // Configure RapidCheck with command line parameters.
    uint64_t seed = configureRapidCheck(config);

    std::cout << "=== Eco Runtime GC Property-Based Tests ===" << std::endl;

    if (config.show_seed) {
        std::cout << "Using seed: " << seed << std::endl;
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

    // Run tests (potentially multiple times or for a duration).
    int exit_code = 0;

    // Track total results across all iterations.
    Testing::TestSuiteResult total_result;

    if (config.duration.has_value()) {
        // Duration mode: run tests repeatedly until time expires, then exit successfully.
        Testing::Deadline::setDuration(config.duration.value());
        auto start_time = std::chrono::steady_clock::now();
        int iteration = 1;

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

            // Run all tests (or filtered subset).
            auto result = suite.run(config.filter);

            // Accumulate results.
            total_result.tests_run += result.tests_run;
            total_result.tests_passed += result.tests_passed;
            total_result.tests_failed += result.tests_failed;
            total_result.tests_total += result.tests_total;
            for (const auto& failed : result.failed_tests) {
                total_result.failed_tests.push_back(failed);
            }

            if (result.duration_expired) {
                // Duration expired mid-suite - this is fine, just stop.
                break;
            }

            iteration++;

            // Check if we still have time for another iteration.
            if (!Testing::Deadline::durationExpired()) {
                std::cout << std::endl;
            }
        }

        auto total_elapsed = std::chrono::duration_cast<std::chrono::seconds>(
            std::chrono::steady_clock::now() - start_time);
        std::cout << std::endl;
        std::cout << "Completed " << total_result.tests_run << " tests across "
                  << iteration << " iteration(s) in "
                  << formatDuration(total_elapsed) << std::endl;

        Testing::Deadline::clear();
        // Set exit code based on failures.
        if (total_result.tests_failed > 0) {
            exit_code = 1;
        }
    } else {
        // Iteration-based test execution (with optional timeout).
        if (config.timeout.has_value()) {
            Testing::Deadline::setTimeout(config.timeout.value());
        }

        for (int iteration = 1; iteration <= config.repeat; iteration++) {
            if (config.repeat > 1) {
                std::cout << "=== Iteration " << iteration << " of " << config.repeat << " ===" << std::endl;
                std::cout << std::endl;
            }

            // Run all tests (or filtered subset).
            auto result = suite.run(config.filter);

            // Accumulate results.
            total_result.tests_run += result.tests_run;
            total_result.tests_passed += result.tests_passed;
            total_result.tests_failed += result.tests_failed;
            total_result.tests_total += result.tests_total;
            for (const auto& failed : result.failed_tests) {
                total_result.failed_tests.push_back(failed);
            }

            if (result.timeout_expired) {
                std::cerr << std::endl;
                std::cerr << "TIMEOUT: Tests exceeded " << formatDuration(config.timeout.value())
                          << " limit after " << result.tests_run << " of "
                          << result.tests_total << " tests in iteration " << iteration << std::endl;
                total_result.timeout_expired = true;
                exit_code = 1;
                break;
            }

            if (config.repeat > 1 && iteration < config.repeat) {
                std::cout << std::endl;
            }
        }

        Testing::Deadline::clear();

        // Set exit code based on failures.
        if (total_result.tests_failed > 0) {
            exit_code = 1;
        }
    }

#if ENABLE_GC_STATS
    // Print GC statistics after all tests complete.
    // Print combined stats from all thread heaps.
    auto &alloc = Allocator::instance();
    GCStats combined_stats = alloc.getCombinedStats();
    combined_stats.print();
#endif

    // Print test summary.
    printTestSummary(total_result, seed);

    return exit_code;
}
