#pragma once

#include <chrono>
#include <optional>
#include <string>
#include <vector>
#include <functional>
#include <algorithm>

namespace Testing {

// ============================================================================
// Deadline - Global time limit for test runs.
// ============================================================================

/**
 * Global deadline for limiting test execution time.
 *
 * Set a deadline before running tests; tests will abort when time expires.
 */
class Deadline {
public:
    // Sets the deadline to now + duration.
    static void set(std::chrono::seconds duration) {
        deadline_ = std::chrono::steady_clock::now() + duration;
    }

    // Clears the deadline (no time limit).
    static void clear() {
        deadline_ = std::nullopt;
    }

    // Returns true if a deadline is set and has expired.
    static bool expired() {
        if (!deadline_.has_value()) {
            return false;
        }
        return std::chrono::steady_clock::now() >= deadline_.value();
    }

    // Returns true if no deadline is set or deadline has not expired.
    static bool ok() {
        return !expired();
    }

private:
    static inline std::optional<std::chrono::steady_clock::time_point> deadline_;
};

// ============================================================================
// Test Results
// ============================================================================

/**
 * Result of running a test suite.
 */
struct TestSuiteResult {
    size_t tests_run = 0;           // Number of tests executed.
    size_t tests_total = 0;         // Total tests that would have run.
    bool deadline_expired = false;  // True if stopped due to deadline.
    std::chrono::milliseconds elapsed{0};  // Total elapsed time.
};

// ============================================================================
// Test and TestSuite
// ============================================================================

/**
 * Represents a single property-based test with a name and test function.
 */
class Test {
public:
    Test(std::string name, std::function<void()> func)
        : name_(std::move(name)), testFunc_(std::move(func)) {}

    // Executes the test function.
    void run() const {
        testFunc_();
    }

    // Returns the test name/description.
    const std::string& getName() const {
        return name_;
    }

private:
    std::string name_;              // Test name/description.
    std::function<void()> testFunc_; // Test function to execute.
};

/**
 * A collection of tests that can be filtered and run together.
 */
class TestSuite {
public:
    // Adds a test to the suite.
    void add(Test test) {
        tests_.push_back(std::move(test));
    }

    // Returns a list of all test names.
    std::vector<std::string> listTests() const {
        std::vector<std::string> names;
        names.reserve(tests_.size());
        for (const auto& test : tests_) {
            names.push_back(test.getName());
        }
        return names;
    }

    // Returns tests whose names contain the given pattern.
    std::vector<Test> filter(const std::string& pattern) const {
        if (pattern.empty()) {
            return tests_;
        }

        std::vector<Test> filtered;
        for (const auto& test : tests_) {
            if (test.getName().find(pattern) != std::string::npos) {
                filtered.push_back(test);
            }
        }
        return filtered;
    }

    // Runs all tests, or only those matching the filter pattern.
    // Returns result with timing and deadline status.
    TestSuiteResult run(const std::string& filter = "") const {
        TestSuiteResult result;
        auto start_time = std::chrono::steady_clock::now();

        std::vector<Test> testsToRun = this->filter(filter);
        result.tests_total = testsToRun.size();

        for (const auto& test : testsToRun) {
            // Check deadline before each test.
            if (Deadline::expired()) {
                result.deadline_expired = true;
                break;
            }

            test.run();
            result.tests_run++;
        }

        auto end_time = std::chrono::steady_clock::now();
        result.elapsed = std::chrono::duration_cast<std::chrono::milliseconds>(
            end_time - start_time);

        return result;
    }

    // Returns the number of tests in the suite.
    size_t size() const {
        return tests_.size();
    }

private:
    std::vector<Test> tests_; // All registered tests.
};

}  // namespace Testing
