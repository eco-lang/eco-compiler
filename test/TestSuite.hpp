#pragma once

#include <chrono>
#include <functional>
#include <iostream>
#include <memory>
#include <optional>
#include <string>
#include <vector>

namespace Testing {

// ============================================================================
// CurrentFilter - Thread-local filter for parallel test containers.
// ============================================================================

/**
 * Thread-local storage for the current filter string.
 * Used by parallel test containers (like ElmParallelTestSuite) to know
 * which tests to run when runWithResult() is called.
 */
class CurrentFilter {
public:
    static void set(const std::string& filter) {
        filter_ = filter;
    }

    static const std::string& get() {
        return filter_;
    }

    static void clear() {
        filter_.clear();
    }

private:
    static inline thread_local std::string filter_;
};

// ============================================================================
// Deadline - Global time limit for test runs.
// ============================================================================

/**
 * Global time limits for test execution.
 *
 * Supports two modes:
 * - Duration: Run tests repeatedly until time expires (graceful stop).
 * - Timeout: Maximum allowed time; exceeding is a failure.
 */
class Deadline {
public:
    // Sets the duration limit (graceful stop when expired).
    static void setDuration(std::chrono::seconds duration) {
        duration_ = std::chrono::steady_clock::now() + duration;
    }

    // Sets the timeout limit (failure if exceeded).
    static void setTimeout(std::chrono::seconds timeout) {
        timeout_ = std::chrono::steady_clock::now() + timeout;
    }

    // Clears all time limits.
    static void clear() {
        duration_ = std::nullopt;
        timeout_ = std::nullopt;
    }

    // Returns true if duration limit has expired.
    static bool durationExpired() {
        if (!duration_.has_value()) {
            return false;
        }
        return std::chrono::steady_clock::now() >= duration_.value();
    }

    // Returns true if timeout limit has expired.
    static bool timeoutExpired() {
        if (!timeout_.has_value()) {
            return false;
        }
        return std::chrono::steady_clock::now() >= timeout_.value();
    }

    // Returns true if either limit has expired.
    static bool expired() {
        return durationExpired() || timeoutExpired();
    }

    // Returns true if no limits have expired.
    static bool ok() {
        return !expired();
    }

private:
    static inline std::optional<std::chrono::steady_clock::time_point> duration_;
    static inline std::optional<std::chrono::steady_clock::time_point> timeout_;
};

// ============================================================================
// Test Results
// ============================================================================

/**
 * Information about a failed test.
 */
struct FailedTest {
    std::string name;  // Name of the failed test.
};

/**
 * Result of running a test suite.
 */
struct TestSuiteResult {
    size_t tests_run = 0;           // Number of tests executed.
    size_t tests_passed = 0;        // Number of tests that passed.
    size_t tests_failed = 0;        // Number of tests that failed.
    size_t tests_total = 0;         // Total tests that would have run.
    bool duration_expired = false;  // True if stopped due to --duration limit.
    bool timeout_expired = false;   // True if stopped due to --timeout limit.
    std::chrono::milliseconds elapsed{0};  // Total elapsed time.
    std::vector<FailedTest> failed_tests;  // List of failed test names.
};

// ============================================================================
// Test (Abstract Base), TestCase, and TestSuite
// ============================================================================

/**
 * Abstract base class for all test types.
 *
 * Supports composite pattern: TestSuite extends Test, allowing nested suites.
 */
class Test {
public:
    virtual ~Test() = default;

    // Executes the test or suite (legacy interface for interactive mode).
    virtual void run() const = 0;

    // Executes the test or suite with result tracking.
    // Returns true if the test passed, false if it failed.
    virtual bool runWithResult() const = 0;

    // Returns the test/suite name.
    virtual const std::string& getName() const = 0;

    // Returns the number of leaf tests (1 for TestCase, sum for TestSuite).
    virtual size_t countTests() const = 0;

    // Collects all leaf test names, optionally filtered by pattern.
    virtual void collectTests(std::vector<const Test*>& out,
                              const std::string& pattern = "") const = 0;

    // For containers that track individual test results:
    // Returns true if this test provides detailed per-test results.
    virtual bool hasDetailedResults() const { return false; }

    // Get pass/fail counts from last run (only valid if hasDetailedResults() is true)
    virtual size_t getLastPassCount() const { return 0; }
    virtual size_t getLastFailCount() const { return 0; }

    // Get names of failed tests from last run
    virtual const std::vector<std::string>& getLastFailedTests() const {
        static const std::vector<std::string> empty;
        return empty;
    }
};

/**
 * A single test case with a name and test function.
 *
 * This is typically a property-based test that uses rc::check() internally.
 * The number of iterations is controlled by the -n parameter.
 */
class TestCase : public Test {
public:
    TestCase(std::string name, std::function<void()> func)
        : name_(std::move(name)), testFunc_(std::move(func)) {}

    // Executes the test function, printing the test name first.
    void run() const override {
        std::cout << "- " << name_ << std::endl;
        testFunc_();
    }

    // Executes the test with result tracking.
    // Returns true if passed, false if failed.
    bool runWithResult() const override {
        std::cout << "- " << name_ << std::endl;
        try {
            testFunc_();
            return true;
        } catch (const std::exception& e) {
            // RapidCheck throws on failure - error already printed
            return false;
        } catch (...) {
            std::cerr << "Unknown exception in test: " << name_ << std::endl;
            return false;
        }
    }

    // Returns the test name/description.
    const std::string& getName() const override {
        return name_;
    }

    // A single test case counts as 1.
    size_t countTests() const override {
        return 1;
    }

    // Adds self to output if name matches pattern.
    void collectTests(std::vector<const Test*>& out,
                      const std::string& pattern = "") const override {
        if (pattern.empty() || name_.find(pattern) != std::string::npos) {
            out.push_back(this);
        }
    }

private:
    std::string name_;               // Test name/description.
    std::function<void()> testFunc_; // Test function to execute.
};

/**
 * A unit test that always runs exactly once.
 *
 * Unlike TestCase (which wraps rc::check()), UnitTest ignores the -n parameter
 * and runs its test function a single time. Use this for tests that don't
 * benefit from property-based testing (fixed inputs, code path verification).
 *
 * Still respects --repeat and --duration (suite-level repetition).
 */
class UnitTest : public Test {
public:
    UnitTest(std::string name, std::function<void()> func)
        : name_(std::move(name)), testFunc_(std::move(func)) {}

    // Executes the test function once, printing result.
    void run() const override {
        std::cout << "- " << name_ << std::endl;
        testFunc_();
        std::cout << "OK" << std::endl;
    }

    // Executes the test with result tracking.
    // Returns true if passed, false if failed.
    bool runWithResult() const override {
        std::cout << "- " << name_ << std::endl;
        try {
            testFunc_();
            std::cout << "OK" << std::endl;
            return true;
        } catch (const std::exception& e) {
            std::cerr << "FAILED: " << e.what() << std::endl;
            return false;
        } catch (...) {
            std::cerr << "FAILED: Unknown exception" << std::endl;
            return false;
        }
    }

    // Returns the test name/description.
    const std::string& getName() const override {
        return name_;
    }

    // A unit test counts as 1.
    size_t countTests() const override {
        return 1;
    }

    // Adds self to output if name matches pattern.
    void collectTests(std::vector<const Test*>& out,
                      const std::string& pattern = "") const override {
        if (pattern.empty() || name_.find(pattern) != std::string::npos) {
            out.push_back(this);
        }
    }

private:
    std::string name_;               // Test name/description.
    std::function<void()> testFunc_; // Test function to execute.
};

/**
 * A collection of tests that can be filtered and run together.
 *
 * Extends Test, so suites can contain other suites (composite pattern).
 */
class TestSuite : public Test {
public:
    explicit TestSuite(std::string name) : name_(std::move(name)) {}

    // Adds a property-based test case to the suite.
    void add(TestCase test) {
        children_.push_back(std::make_unique<TestCase>(std::move(test)));
    }

    // Adds a unit test to the suite.
    void add(UnitTest test) {
        children_.push_back(std::make_unique<UnitTest>(std::move(test)));
    }

    // Adds a sub-suite to the suite.
    void add(TestSuite suite) {
        children_.push_back(std::make_unique<TestSuite>(std::move(suite)));
    }

    // Adds any test by unique_ptr.
    void add(std::unique_ptr<Test> test) {
        children_.push_back(std::move(test));
    }

    // Returns the suite name.
    const std::string& getName() const override {
        return name_;
    }

    // Returns total count of leaf tests in this suite and all sub-suites.
    size_t countTests() const override {
        size_t count = 0;
        for (const auto& child : children_) {
            count += child->countTests();
        }
        return count;
    }

    // Collects all matching leaf tests recursively.
    void collectTests(std::vector<const Test*>& out,
                      const std::string& pattern = "") const override {
        for (const auto& child : children_) {
            child->collectTests(out, pattern);
        }
    }

    // Returns true if this suite has any tests matching the pattern.
    bool hasMatchingTests(const std::string& pattern) const {
        std::vector<const Test*> matches;
        collectTests(matches, pattern);
        return !matches.empty();
    }

    // Returns a list of all leaf test names.
    std::vector<std::string> listTests() const {
        std::vector<const Test*> tests;
        collectTests(tests);
        std::vector<std::string> names;
        names.reserve(tests.size());
        for (const auto* test : tests) {
            names.push_back(test->getName());
        }
        return names;
    }

    // Runs the suite itself (all children, no filtering).
    void run() const override {
        for (const auto& child : children_) {
            child->run();
        }
    }

    // Runs the suite with result tracking (for composite pattern).
    bool runWithResult() const override {
        bool all_passed = true;
        for (const auto& child : children_) {
            if (!child->runWithResult()) {
                all_passed = false;
            }
        }
        return all_passed;
    }

    // Runs all tests matching the filter, with hierarchical output.
    // Returns result with timing and deadline status.
    TestSuiteResult run(const std::string& filter) const {
        TestSuiteResult result;
        auto start_time = std::chrono::steady_clock::now();

        // Count total matching tests.
        std::vector<const Test*> allMatching;
        collectTests(allMatching, filter);
        result.tests_total = allMatching.size();

        // Run hierarchically with output.
        runHierarchical(filter, result, 0);

        auto end_time = std::chrono::steady_clock::now();
        result.elapsed = std::chrono::duration_cast<std::chrono::milliseconds>(
            end_time - start_time);

        return result;
    }

    // Returns the number of direct children.
    size_t size() const {
        return children_.size();
    }

    // Returns references to direct children (for interactive mode).
    const std::vector<std::unique_ptr<Test>>& getChildren() const {
        return children_;
    }

private:
    std::string name_;                            // Suite name.
    std::vector<std::unique_ptr<Test>> children_; // Child tests and sub-suites.

    // Runs children hierarchically, printing suite names.
    void runHierarchical(const std::string& filter, TestSuiteResult& result,
                         int depth) const {
        // Check if this suite has any matching tests.
        if (!hasMatchingTests(filter)) {
            return;
        }

        // Print suite header (skip for root/unnamed suites).
        if (!name_.empty()) {
            std::string indent(depth * 2, ' ');
            std::cout << indent << "=== " << name_ << " ===" << std::endl;
        }

        for (const auto& child : children_) {
            // Check deadlines before each child.
            if (Deadline::timeoutExpired()) {
                result.timeout_expired = true;
                return;
            }
            if (Deadline::durationExpired()) {
                result.duration_expired = true;
                return;
            }

            // Check if child is a TestSuite (has children) or TestCase.
            if (auto* suite = dynamic_cast<const TestSuite*>(child.get())) {
                suite->runHierarchical(filter, result, depth + 1);
            } else {
                // It's a TestCase or a container like ElmParallelTestSuite.
                // Check if it has matching sub-tests (for containers) or if name matches.
                std::vector<const Test*> matchingTests;
                child->collectTests(matchingTests, filter);

                if (!matchingTests.empty()) {
                    // Check if this is a simple single test or a container.
                    bool isSimpleTest = (matchingTests.size() == 1 &&
                                         matchingTests[0] == child.get());

                    if (isSimpleTest) {
                        // Simple single test - original behavior.
                        bool passed = child->runWithResult();
                        result.tests_run++;
                        if (passed) {
                            result.tests_passed++;
                        } else {
                            result.tests_failed++;
                            result.failed_tests.push_back({child->getName()});
                        }
                    } else {
                        // Container with multiple sub-tests (e.g., ElmParallelTestSuite).
                        // Run the container - it handles its own output and filtering.

                        // Set the current filter so container can use it.
                        CurrentFilter::set(filter);
                        child->runWithResult();
                        CurrentFilter::clear();

                        // Check if container provides detailed results
                        if (child->hasDetailedResults()) {
                            // Use the container's tracked results
                            result.tests_run += child->getLastPassCount() + child->getLastFailCount();
                            result.tests_passed += child->getLastPassCount();
                            result.tests_failed += child->getLastFailCount();

                            // Add individual failed test names
                            for (const auto& name : child->getLastFailedTests()) {
                                result.failed_tests.push_back({name});
                            }
                        } else {
                            // Fallback for containers without detailed tracking
                            size_t numTests = matchingTests.size();
                            result.tests_run += numTests;
                            result.tests_passed += numTests;  // Assume all passed
                        }
                    }
                }
            }
        }
    }
};

}  // namespace Testing
