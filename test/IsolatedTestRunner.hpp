#pragma once

#include "TestSuite.hpp"

#include <algorithm>
#include <chrono>
#include <csignal>
#include <cstring>
#include <functional>
#include <iostream>
#include <sstream>
#include <string>
#include <unordered_map>
#include <vector>

#include "SpawnedChildren.hpp"

namespace IsolatedTestRunner {

// plans/spawn-not-fork.md Phase 3: every test runs in a SPAWNED child process
// (eco_test::runSpawnedChildren, SpawnedChildren.hpp) on every platform: a
// crash fails one test, a hung test is killed at its timeout, and nothing of
// this process (heap, GC threads, singletons) reaches the child. The child is
// this binary again, `--isolated-child <result> <kind> <args…>`, dispatched by
// main (runIsolatedChild).

constexpr int MAX_PARALLEL_TESTS = static_cast<int>(eco_test::kMaxParallelChildren);
constexpr int TEST_TIMEOUT_SECONDS = 60;

// Use Color from Testing namespace
namespace Color = Testing::Color;

/**
 * The result record a child writes into its shared result file.
 */
struct SharedTestResult {
    bool completed;          // Child finished execution (vs crashed mid-way)
    bool passed;             // Test passed
    char error[4096];        // Error message if failed
    char output[8192];       // Test output (stdout capture)
};

/**
 * Summary of parallel test execution.
 */
struct ParallelTestSummary {
    size_t passCount = 0;
    size_t failCount = 0;
    std::vector<std::string> failedTests;
};

inline void printTestResult(const std::string& name, const std::string& output, bool passed,
                            const std::string& error) {
    eco_test::printChildResult(name, output, passed, error);
}

/**
 * Optional callback run in the parent after a test completes, with the
 * child's result record (Elm tests accumulate GCStats from theirs).
 */
using PostTestCallback = std::function<void(const SharedTestResult* shared)>;

/**
 * Runs each (child kind, argument) test in a spawned child, up to
 * MAX_PARALLEL_TESTS at once, printing each as it ends.
 *
 * @param testArgs  per test, the child's `<kind> <args…>` (main's runIsolatedChild
 *                  dispatches them)
 * @param testNames the names to print, parallel to testArgs
 */
inline ParallelTestSummary runTestsParallel(
    const std::vector<std::vector<std::string>>& testArgs,
    const std::vector<std::string>& testNames,
    PostTestCallback postTest = nullptr)
{
    auto run = eco_test::runSpawnedChildren(
        testNames, sizeof(SharedTestResult),
        [&](size_t i) {
            eco_test::ChildJob job;
            job.args = testArgs[i];
            job.timeoutSeconds = TEST_TIMEOUT_SECONDS;
            return job;
        },
        [&](size_t, const eco_test::ChildOutcome& o) {
            eco_test::ChildVerdict v = eco_test::defaultVerdict<SharedTestResult>(o, TEST_TIMEOUT_SECONDS);
            if (postTest && !o.timedOut && !o.interrupted && !o.exit.signaled) {
                const SharedTestResult rec = eco_test::resultRecord<SharedTestResult>(o);
                if (rec.completed) postTest(&rec);
            }
            return v;
        });
    ParallelTestSummary summary;
    summary.passCount = run.passCount;
    summary.failCount = run.failCount;
    summary.failedTests = std::move(run.failedTests);
    return summary;
}

/**
 * The common case: one child kind, one path argument per test.
 */
inline ParallelTestSummary runTestsParallel(
    const std::vector<std::string>& testPaths,
    const std::vector<std::string>& testNames,
    const std::string& childKind,
    PostTestCallback postTest = nullptr)
{
    std::vector<std::vector<std::string>> args;
    args.reserve(testPaths.size());
    for (const auto& p : testPaths) args.push_back({childKind, p});
    return runTestsParallel(args, testNames, std::move(postTest));
}

/**
 * Child side of runTestsParallel: runs `body`, records the outcome in the
 * result file, and returns the child's exit status.
 */
inline int runChild(const std::string& resultPath, const std::function<void()>& body) {
    return eco_test::runChildBody<SharedTestResult>(resultPath, body);
}

// ============================================================================
// Base Test Entry Class
// ============================================================================

/**
 * A simple Test wrapper for listing purposes.
 * This is only used for collectTests() to support --list and --filter.
 */
class IsolatedTestEntry : public Testing::Test {
public:
    IsolatedTestEntry(std::string name, std::string path)
        : name_(std::move(name)), path_(std::move(path)) {}

    void run() const override {
        // Should not be called directly - parallel suite handles execution
    }

    bool runWithResult() const override {
        // Should not be called directly - parallel suite handles execution
        return true;
    }

    const std::string& getName() const override { return name_; }
    const std::string& getPath() const { return path_; }
    size_t countTests() const override { return 1; }

    void collectTests(std::vector<const Testing::Test*>& out,
                      const std::string& pattern = "") const override {
        if (pattern.empty() || name_.find(pattern) != std::string::npos) {
            out.push_back(this);
        }
    }

private:
    std::string name_;
    std::string path_;
};

// ============================================================================
// IsolatedTestCaseSuite — Test-case suite with process-per-test isolation
// ============================================================================

/**
 * A Test container that runs each Testing::TestCase in a spawned child
 * (`--isolated-child <result> case <suite> <test>`; main rebuilds the isolated
 * suites and calls runCaseInChild).
 *
 * Drop-in replacement for Testing::TestSuite when individual cases may
 * crash the process (e.g. GC pressure tests that may SEGV/abort the
 * runtime). A crash in one case is reported as a single FAILED line and
 * the remaining cases still run.
 *
 * Caveat: per-process state mutated by a test (e.g. global allocator
 * statistics) is not visible to the parent — every test starts in a
 * pristine address space.
 */
class IsolatedTestCaseSuite : public Testing::Test {
public:
    explicit IsolatedTestCaseSuite(std::string name)
        : name_(std::move(name)) {}

    // Adds a property/unit-style test case. The function is extracted and
    // the case object is discarded — only name + body are retained.
    void add(const Testing::TestCase& test) {
        const std::string& testName = test.getName();
        funcs_.push_back(test.getFunc());
        entries_.push_back(std::make_unique<IsolatedTestEntry>(testName, ""));
    }

    void run() const override {
        runWithResult();
    }

    bool runWithResult() const override {
        return runFiltered(Testing::CurrentFilter::get());
    }

    const std::string& getName() const override {
        return name_;
    }

    size_t countTests() const override {
        return entries_.size();
    }

    void collectTests(std::vector<const Testing::Test*>& out,
                      const std::string& pattern = "") const override {
        for (const auto& entry : entries_) {
            entry->collectTests(out, pattern);
        }
    }

    bool runFiltered(const std::string& filter) const {
        std::vector<std::vector<std::string>> argsToRun;
        std::vector<std::string> namesToRun;
        for (size_t i = 0; i < entries_.size(); i++) {
            const std::string& n = entries_[i]->getName();
            if (filter.empty() || n.find(filter) != std::string::npos) {
                argsToRun.push_back({"case", name_, n});
                namesToRun.push_back(n);
            }
        }

        if (argsToRun.empty()) {
            lastPassCount_ = 0;
            lastFailCount_ = 0;
            lastFailedTests_.clear();
            return true;
        }

        // Match Testing::TestSuite::runHierarchical's suite header so output
        // looks the same as the in-process suite this replaces.
        if (!name_.empty()) {
            std::cout << Testing::Color::bold() << Testing::Color::cyan()
                      << "  === " << name_ << " ==="
                      << Testing::Color::reset() << std::endl;
        }

        auto summary = runTestsParallel(argsToRun, namesToRun);
        lastPassCount_ = summary.passCount;
        lastFailCount_ = summary.failCount;
        lastFailedTests_ = summary.failedTests;
        return lastFailCount_ == 0;
    }

    // Child side: runs the case named `testName` (exact name). Returns the
    // child's exit status; 2 when no case has that name.
    int runCaseInChild(const std::string& resultPath, const std::string& testName) const {
        for (size_t i = 0; i < entries_.size(); i++) {
            if (entries_[i]->getName() == testName) return runChild(resultPath, funcs_[i]);
        }
        std::cerr << "isolated child: no case named '" << testName << "' in " << name_ << std::endl;
        return 2;
    }

    bool hasDetailedResults() const override { return true; }
    size_t getLastPassCount() const override { return lastPassCount_; }
    size_t getLastFailCount() const override { return lastFailCount_; }
    const std::vector<std::string>& getLastFailedTests() const override {
        return lastFailedTests_;
    }

private:
    std::string name_;
    std::vector<std::function<void()>> funcs_;
    std::vector<std::unique_ptr<IsolatedTestEntry>> entries_;

    mutable size_t lastPassCount_ = 0;
    mutable size_t lastFailCount_ = 0;
    mutable std::vector<std::string> lastFailedTests_;
};

}  // namespace IsolatedTestRunner
