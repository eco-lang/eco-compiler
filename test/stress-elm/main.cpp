#include <chrono>
#include <cstring>
#include <getopt.h>
#include <iostream>
#include <optional>
#include <string>
#include <vector>

#include "Allocator.hpp"
#include "stress-elm/StressElmTest.hpp"
#include "TestSuite.hpp"

using namespace Elm;

// ============================================================================
// Configuration
// ============================================================================

struct StressConfig {
    bool verbose = false;
    bool list_tests = false;
    int repeat = 1;
    // Number of outer iterations per stress program (threaded to Elm as
    // StressFlags.numLoops).
    int num_test_loops = 100;
    // Secondary "size" knob for stress programs (threaded as StressFlags.maxSize).
    int max_size = 100;
    uint64_t seed = 0;
    std::optional<std::chrono::seconds> duration;
    std::optional<std::chrono::seconds> timeout;
    std::string filter = "";
};

// ============================================================================
// Helpers (duration parse/format mirror those in test/main.cpp)
// ============================================================================

static std::optional<std::chrono::seconds> parseDuration(const std::string& str) {
    if (str.empty()) return std::nullopt;

    size_t i = 0;
    while (i < str.length() && std::isdigit(str[i])) i++;
    if (i == 0 || i == str.length()) {
        std::cerr << "Error: Invalid duration. Expected <number><unit> (e.g. 30s, 5m).\n";
        return std::nullopt;
    }

    long long value = std::stoll(str.substr(0, i));
    std::string unit = str.substr(i);

    if (unit == "s" || unit == "sec" || unit == "seconds") return std::chrono::seconds(value);
    if (unit == "m" || unit == "min" || unit == "minutes") return std::chrono::seconds(value * 60);
    if (unit == "h" || unit == "hr"  || unit == "hours")   return std::chrono::seconds(value * 3600);
    if (unit == "d" || unit == "day" || unit == "days")    return std::chrono::seconds(value * 86400);

    std::cerr << "Error: Unknown time unit '" << unit << "'. Valid: s, m, h, d.\n";
    return std::nullopt;
}

static std::string formatDuration(std::chrono::seconds total) {
    long long s = total.count();
    if (s < 60)    return std::to_string(s) + "s";
    if (s < 3600)  return std::to_string(s / 60) + "m " + std::to_string(s % 60) + "s";
    if (s < 86400) return std::to_string(s / 3600) + "h " + std::to_string((s % 3600) / 60) + "m";
    return std::to_string(s / 86400) + "d " + std::to_string((s % 86400) / 3600) + "h";
}

static void printHelp(const char* prog) {
    std::cout << "Usage: " << prog << " [OPTIONS]\n\n"
              << "Eco Stress Test Runner (Elm E2E, larger/longer programs)\n\n"
              << "Options:\n"
              << "  -f, --filter <PAT>           Run only tests whose name contains PAT\n"
              << "  -r, --repeat <N>             Run the suite N times (default 1)\n"
              << "  -t, --duration <TIME>        Run repeatedly for TIME (e.g. 30s, 5m), then exit 0\n"
              << "      --timeout <TIME>         Fail if tests exceed TIME (e.g. 5m)\n"
              << "  -n, --num-test-loops <N>     Outer iteration count per stress program (default 100)\n"
              << "  -m, --max-size <M>           Secondary size knob (default 100)\n"
              << "  -s, --seed <SEED>            Seed (0 = time-based)\n"
              << "      --list                   List discovered tests and exit\n"
              << "  -v, --verbose                Verbose output\n"
              << "  -h, --help                   Show this help\n";
}

static StressConfig parseCommandLine(int argc, char* argv[]) {
    StressConfig config;

    static struct option long_options[] = {
        {"filter",          required_argument, 0, 'f'},
        {"repeat",          required_argument, 0, 'r'},
        {"duration",        required_argument, 0, 't'},
        {"timeout",         required_argument, 0, 'T'},
        {"num-test-loops",  required_argument, 0, 'n'},
        {"max-size",        required_argument, 0, 'm'},
        {"seed",            required_argument, 0, 's'},
        {"list",            no_argument,       0, 'L'},
        {"verbose",         no_argument,       0, 'v'},
        {"help",            no_argument,       0, 'h'},
        {0, 0, 0, 0}
    };

    int opt, idx = 0;
    while ((opt = getopt_long(argc, argv, "f:r:t:n:m:s:vh", long_options, &idx)) != -1) {
        switch (opt) {
            case 'f': config.filter = optarg; break;
            case 'r':
                config.repeat = std::atoi(optarg);
                if (config.repeat <= 0) { std::cerr << "Error: --repeat must be positive\n"; exit(1); }
                break;
            case 't': {
                auto d = parseDuration(optarg);
                if (!d) exit(1);
                config.duration = d;
                break;
            }
            case 'T': {
                auto d = parseDuration(optarg);
                if (!d) exit(1);
                config.timeout = d;
                break;
            }
            case 'n':
                config.num_test_loops = std::atoi(optarg);
                if (config.num_test_loops <= 0) {
                    std::cerr << "Error: --num-test-loops must be positive\n"; exit(1);
                }
                break;
            case 'm':
                config.max_size = std::atoi(optarg);
                if (config.max_size <= 0) {
                    std::cerr << "Error: --max-size must be positive\n"; exit(1);
                }
                break;
            case 's':
                config.seed = std::stoull(optarg);
                break;
            case 'L': config.list_tests = true; break;
            case 'v': config.verbose = true; break;
            case 'h': printHelp(argv[0]); exit(0);
            case '?': std::cerr << "Use -h or --help.\n"; exit(1);
            default:  exit(1);
        }
    }

    if (config.repeat > 1 && config.duration.has_value()) {
        std::cerr << "Error: --repeat and --duration cannot be combined\n"; exit(1);
    }
    if (config.duration.has_value() && config.timeout.has_value()) {
        std::cerr << "Error: --duration and --timeout cannot be combined\n"; exit(1);
    }

    return config;
}

static void printSummary(const Testing::TestSuiteResult& r) {
    std::cout << "\n" << Testing::Color::bold() << Testing::Color::cyan()
              << "=== Stress Test Summary ===" << Testing::Color::reset() << "\n\n"
              << "Tests run:    " << r.tests_run << "\n"
              << "Tests passed: " << Testing::Color::green() << r.tests_passed
              << Testing::Color::reset() << "\n"
              << "Tests failed: " << Testing::Color::red() << r.tests_failed
              << Testing::Color::reset() << "\n\n"
              << "Result: "
              << (r.tests_failed == 0
                  ? (std::string(Testing::Color::bold()) + Testing::Color::green() + "PASSED")
                  : (std::string(Testing::Color::bold()) + Testing::Color::red()  + "FAILED"))
              << Testing::Color::reset() << std::endl;
}

// ============================================================================
// Main
// ============================================================================

int main(int argc, char* argv[]) {
    StressConfig config = parseCommandLine(argc, argv);

    // Translate CLI config into the StressFlags record passed to
    // Platform.worker-based stress programs. startMs is refreshed per-run
    // inside ElmE2EParallelTestSuite.
    Elm::Platform::StressFlags stressFlags{};
    stressFlags.numLoops  = config.num_test_loops;
    stressFlags.maxSize   = config.max_size;
    stressFlags.timeoutMs = config.timeout.has_value()
        ? static_cast<int64_t>(config.timeout->count()) * 1000
        : 0;
    stressFlags.seed      = static_cast<int64_t>(config.seed);
    stressFlags.startMs   = 0;
    stressFlags.verbose   = config.verbose;

    auto stressTests = StressElmTest::buildStressElmTestSuite(stressFlags);

    Testing::TestSuite suite("Stress Tests");
    suite.add(std::move(stressTests));

    if (config.list_tests) {
        std::cout << "Available stress tests:\n";
        auto names = suite.listTests();
        for (size_t i = 0; i < names.size(); i++) {
            std::cout << "  " << (i + 1) << ". " << names[i] << "\n";
        }
        return 0;
    }

    std::cout << Testing::Color::bold() << Testing::Color::cyan()
              << "=== Eco Stress Tests ===" << Testing::Color::reset() << std::endl;

    if (config.verbose) {
        std::cout << "Configuration:\n";
        std::cout << "  num_test_loops: " << config.num_test_loops << "\n";
        std::cout << "  max_size:       " << config.max_size << "\n";
        std::cout << "  seed:           " << config.seed << "\n";
        if (config.duration.has_value()) {
            std::cout << "  Duration: " << formatDuration(*config.duration) << "\n";
        } else {
            std::cout << "  Repeat: " << config.repeat << "\n";
        }
        if (config.timeout.has_value()) {
            std::cout << "  Timeout: " << formatDuration(*config.timeout) << "\n";
        }
        if (!config.filter.empty()) std::cout << "  Filter: \"" << config.filter << "\"\n";
    }
    std::cout << std::endl;

    Testing::TestSuiteResult total;
    int exit_code = 0;

    if (config.duration.has_value()) {
        Testing::Deadline::setDuration(*config.duration);
        auto start = std::chrono::steady_clock::now();
        int iter = 1;

        std::cout << "Running stress tests for " << formatDuration(*config.duration) << "...\n\n";

        while (!Testing::Deadline::durationExpired()) {
            auto elapsed = std::chrono::duration_cast<std::chrono::seconds>(
                std::chrono::steady_clock::now() - start);
            auto remaining = *config.duration - elapsed;
            if (remaining.count() < 0) remaining = std::chrono::seconds(0);

            std::cout << Testing::Color::bold() << Testing::Color::cyan()
                      << "=== Iteration " << iter
                      << " (Elapsed: " << formatDuration(elapsed)
                      << ", Remaining: " << formatDuration(remaining) << ") ==="
                      << Testing::Color::reset() << "\n\n";

            auto r = suite.run(config.filter);
            total.tests_run    += r.tests_run;
            total.tests_passed += r.tests_passed;
            total.tests_failed += r.tests_failed;
            total.tests_total  += r.tests_total;
            for (const auto& f : r.failed_tests) total.failed_tests.push_back(f);

            if (r.duration_expired) break;
            iter++;
        }
        Testing::Deadline::clear();
        if (total.tests_failed > 0) exit_code = 1;
    } else {
        if (config.timeout.has_value()) Testing::Deadline::setTimeout(*config.timeout);

        for (int iter = 1; iter <= config.repeat; iter++) {
            if (config.repeat > 1) {
                std::cout << Testing::Color::bold() << Testing::Color::cyan()
                          << "=== Iteration " << iter << " of " << config.repeat << " ==="
                          << Testing::Color::reset() << "\n\n";
            }

            auto r = suite.run(config.filter);
            total.tests_run    += r.tests_run;
            total.tests_passed += r.tests_passed;
            total.tests_failed += r.tests_failed;
            total.tests_total  += r.tests_total;
            for (const auto& f : r.failed_tests) total.failed_tests.push_back(f);

            if (r.timeout_expired) {
                std::cerr << "\nTIMEOUT: stress tests exceeded "
                          << formatDuration(*config.timeout) << std::endl;
                total.timeout_expired = true;
                exit_code = 1;
                break;
            }
        }
        Testing::Deadline::clear();
        if (total.tests_failed > 0) exit_code = 1;
    }

#if ENABLE_GC_STATS
    // Combine in-process stats with forked-child stats accumulated via shared memory.
    auto& alloc = Allocator::instance();
    GCStats combined = alloc.getCombinedStats();
    combined.combine(ElmE2EBase::getAccumulatedStats());
    combined.print();
#endif

    printSummary(total);
    return exit_code;
}
