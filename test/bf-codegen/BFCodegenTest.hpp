#pragma once

// Driver for the bf-codegen .mlir suite (test/bf-codegen/*.mlir: ByteFusion
// dialect fixtures). Each fixture runs through the codegen suite's fixture
// runner (CodegenIsolatedTest::runFixture), so the RUN-line, exit-status,
// FileCheck-prefix and CHECK-order rules, the region-nursery guard and the
// subprocess routing of crashing fixtures are the same in both suites; see
// the header comment of codegen/CodegenIsolatedTest.hpp.

#include "../codegen/CodegenIsolatedTest.hpp"
#include "../IsolatedTestRunner.hpp"
#include "../TestSuite.hpp"

#include <algorithm>
#include <filesystem>
#include <iostream>
#include <memory>
#include <string>
#include <vector>

namespace BFCodegenTest {

// ============================================================================
// Helper Functions
// ============================================================================

/**
 * Get the bf-codegen test directory path.
 */
inline std::string getBFCodegenTestDir() {
    std::vector<std::string> candidates = {
        "test/bf-codegen",
        "../test/bf-codegen",
        "../../test/bf-codegen",
    };

    for (const auto& dir : candidates) {
        if (std::filesystem::exists(dir) && std::filesystem::is_directory(dir)) {
            return std::filesystem::absolute(dir).string();
        }
    }

    return "/work/test/bf-codegen";
}

/**
 * Run a single bf-codegen test (every RUN line).
 * Throws std::runtime_error on failure.
 */
inline void runBFCodegenTest(const std::string& testPath) {
    CodegenIsolatedTest::runFixture(testPath);
}

// ============================================================================
// Test Discovery
// ============================================================================

/**
 * Discover all .mlir test files in the bf-codegen test directory.
 */
inline std::vector<std::string> discoverTests(const std::string& testDir) {
    std::vector<std::string> tests;

    if (!std::filesystem::exists(testDir) || !std::filesystem::is_directory(testDir)) {
        return tests;
    }

    for (const auto& entry : std::filesystem::directory_iterator(testDir)) {
        if (entry.is_regular_file() && entry.path().extension() == ".mlir") {
            tests.push_back(entry.path().string());
        }
    }

    std::sort(tests.begin(), tests.end());
    return tests;
}

// ============================================================================
// Test Entry for Listing
// ============================================================================

/**
 * A simple Test wrapper for listing purposes.
 */
class BFCodegenTestEntry : public Testing::Test {
public:
    BFCodegenTestEntry(std::string name, std::string path)
        : name_(std::move(name)), path_(std::move(path)) {}

    void run() const override {}

    bool runWithResult() const override { return true; }

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
// Parallel Test Suite
// ============================================================================

/**
 * Parallel test suite for bf-codegen tests.
 *
 * This suite runs all .mlir bf dialect tests in parallel and prints
 * results immediately as each test completes.
 *
 * Key features:
 * - Parallel execution with configurable worker count
 * - 60 second timeout per test
 * - Clean shutdown on SIGINT (Ctrl+C)
 * - Immediate output as tests complete
 * - Supports filtering via --filter
 * - Process isolation protects against crashes
 */
class BFCodegenParallelTestSuite : public Testing::Test {
public:
    explicit BFCodegenParallelTestSuite(const std::string& testDir) : name_("BF-Codegen") {
        auto testPaths = discoverTests(testDir);

        for (const auto& path : testPaths) {
            std::string filename = std::filesystem::path(path).filename().string();
            std::string testName = "codegen-bf/" + filename;
            testEntries_.push_back(std::make_unique<BFCodegenTestEntry>(testName, path));
        }
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
        return testEntries_.size();
    }

    void collectTests(std::vector<const Testing::Test*>& out,
                      const std::string& pattern = "") const override {
        for (const auto& entry : testEntries_) {
            entry->collectTests(out, pattern);
        }
    }

    /**
     * Run tests matching the filter pattern.
     */
    bool runFiltered(const std::string& filter) const {
        std::vector<std::string> pathsToRun;
        std::vector<std::string> namesToRun;

        for (const auto& entry : testEntries_) {
            const std::string& name = entry->getName();
            if (filter.empty() || name.find(filter) != std::string::npos) {
                pathsToRun.push_back(
                    static_cast<const BFCodegenTestEntry*>(entry.get())->getPath());
                namesToRun.push_back(name);
            }
        }

        if (pathsToRun.empty()) {
            lastPassCount_ = 0;
            lastFailCount_ = 0;
            lastFailedTests_.clear();
            return true;
        }

        auto summary = IsolatedTestRunner::runTestsParallel(
            pathsToRun,
            namesToRun,
            "bf-codegen"   // the child runs runBFCodegenTest(path) (main's runIsolatedChild)
        );

        lastPassCount_ = summary.passCount;
        lastFailCount_ = summary.failCount;
        lastFailedTests_ = summary.failedTests;

        return summary.failCount == 0;
    }

    const std::vector<std::unique_ptr<BFCodegenTestEntry>>& getEntries() const {
        return testEntries_;
    }

    bool hasDetailedResults() const override { return true; }
    size_t getLastPassCount() const override { return lastPassCount_; }
    size_t getLastFailCount() const override { return lastFailCount_; }
    const std::vector<std::string>& getLastFailedTests() const override { return lastFailedTests_; }

private:
    std::string name_;
    std::vector<std::unique_ptr<BFCodegenTestEntry>> testEntries_;

    mutable size_t lastPassCount_ = 0;
    mutable size_t lastFailCount_ = 0;
    mutable std::vector<std::string> lastFailedTests_;
};

/**
 * Build the complete bf-codegen test suite with parallel execution.
 * Call this from main.cpp to integrate with the test framework.
 */
inline std::unique_ptr<BFCodegenParallelTestSuite> buildBFCodegenTestSuite() {
    std::string testDir = getBFCodegenTestDir();

    if (!std::filesystem::exists(testDir) || !std::filesystem::is_directory(testDir)) {
        std::cerr << "Warning: Could not find bf-codegen test directory: " << testDir << std::endl;
    }

    return std::make_unique<BFCodegenParallelTestSuite>(testDir);
}

}  // namespace BFCodegenTest
