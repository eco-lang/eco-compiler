#pragma once

#include "../IsolatedTestRunner.hpp"
#include "../TestSuite.hpp"
#include "../../runtime/src/codegen/EcoRunner.hpp"

#include <algorithm>
#include <array>
#include <cstdio>
#include <cstdlib>
#include <filesystem>
#include <fstream>
#include <iostream>
#include <memory>
#include <sstream>
#include <stdexcept>
#include <string>
#include <vector>

namespace BFCodegenTest {

// ============================================================================
// Helper Functions
// ============================================================================

/**
 * Execute a command and capture its output.
 * Returns a pair of (exit_code, output).
 */
inline std::pair<int, std::string> executeCommand(const std::string& cmd) {
    std::array<char, 4096> buffer;
    std::string result;

    std::string fullCmd = cmd + " 2>&1";
    std::unique_ptr<FILE, decltype(&pclose)> pipe(popen(fullCmd.c_str(), "r"), pclose);

    if (!pipe) {
        throw std::runtime_error("popen() failed for command: " + cmd);
    }

    while (fgets(buffer.data(), buffer.size(), pipe.get()) != nullptr) {
        result += buffer.data();
    }

    int status = pclose(pipe.release());
    int exitCode = WIFEXITED(status) ? WEXITSTATUS(status) : -1;

    return {exitCode, result};
}

/**
 * Read entire file contents.
 */
inline std::string readFile(const std::string& path) {
    std::ifstream file(path);
    if (!file.is_open()) {
        throw std::runtime_error("Cannot open file: " + path);
    }
    std::stringstream buffer;
    buffer << file.rdbuf();
    return buffer.str();
}

/**
 * Parse the // RUN: line from a test file.
 * Returns the emit mode (jit, mlir-llvm, llvm, mlir).
 */
inline std::string parseEmitMode(const std::string& content) {
    std::istringstream stream(content);
    std::string line;

    while (std::getline(stream, line)) {
        if (line.find("// RUN:") != std::string::npos) {
            if (line.find("-emit=jit") != std::string::npos) {
                return "jit";
            } else if (line.find("-emit=llvm") != std::string::npos &&
                       line.find("-emit=mlir-llvm") == std::string::npos) {
                return "llvm";
            } else if (line.find("-emit=mlir-llvm") != std::string::npos) {
                return "mlir-llvm";
            } else if (line.find("-emit=mlir") != std::string::npos) {
                return "mlir";
            }
        }
    }
    return "jit";  // Default for bf tests is JIT
}

/**
 * Check if the test is expected to fail (has XFAIL marker).
 */
inline bool isExpectedFail(const std::string& content) {
    return content.find("XFAIL:") != std::string::npos;
}

/**
 * Extract CHECK patterns from test file content.
 */
inline std::vector<std::string> extractCheckPatterns(const std::string& content) {
    std::vector<std::string> patterns;
    std::istringstream stream(content);
    std::string line;

    while (std::getline(stream, line)) {
        size_t pos = line.find("// CHECK:");
        if (pos != std::string::npos) {
            std::string pattern = line.substr(pos + 10);
            size_t start = pattern.find_first_not_of(" \t");
            if (start != std::string::npos) {
                pattern = pattern.substr(start);
            }
            size_t end = pattern.find_last_not_of(" \t\r\n");
            if (end != std::string::npos) {
                pattern = pattern.substr(0, end + 1);
            }
            if (!pattern.empty()) {
                patterns.push_back(pattern);
            }
        }
    }
    return patterns;
}

/**
 * Verify that output contains all CHECK patterns.
 * Returns empty string on success, error message on failure.
 */
inline std::string verifyPatterns(const std::string& output,
                                   const std::vector<std::string>& patterns) {
    for (const auto& pattern : patterns) {
        if (output.find(pattern) == std::string::npos) {
            return "Missing pattern: " + pattern;
        }
    }
    return "";
}

/**
 * Get path to ecoc binary.
 */
inline std::string getEcocPath() {
    std::vector<std::string> candidates = {
        "./build/runtime/src/codegen/ecoc",
        "../build/runtime/src/codegen/ecoc",
        "../../build/runtime/src/codegen/ecoc",
    };

    for (const auto& path : candidates) {
        if (std::filesystem::exists(path)) {
            return std::filesystem::absolute(path).string();
        }
    }

    return "build/runtime/src/codegen/ecoc";
}

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

// ============================================================================
// EcoRunner-based Test Execution
// ============================================================================

/**
 * Shared EcoRunner instance for all tests.
 * Thread-local to support parallel test execution.
 */
inline eco::EcoRunner& getRunner() {
    static thread_local eco::EcoRunner runner;
    return runner;
}

/**
 * Run a JIT test using EcoRunner (in-process).
 */
inline void runJITTest(const std::string& testPath, const std::string& content) {
    auto& runner = getRunner();

    runner.reset();

    auto result = runner.runFile(testPath);

    auto patterns = extractCheckPatterns(content);

    std::string error = verifyPatterns(result.output, patterns);
    if (!error.empty()) {
        std::ostringstream msg;
        msg << error << "\n";
        msg << "Output was:\n" << result.output.substr(0, 500);
        if (result.output.length() > 500) {
            msg << "\n... (truncated)";
        }
        throw std::runtime_error(msg.str());
    }

    if (!result.success) {
        std::ostringstream msg;
        msg << "Test failed: " << result.errorMessage << "\n";
        msg << "Output:\n" << result.output.substr(0, 500);
        throw std::runtime_error(msg.str());
    }
}

/**
 * Run a non-JIT test using subprocess.
 */
inline void runSubprocessTest(const std::string& testPath, const std::string& content,
                               const std::string& emitMode) {
    std::string ecocPath = getEcocPath();
    std::string cmd = ecocPath + " \"" + testPath + "\" -emit=" + emitMode;

    auto [exitCode, output] = executeCommand(cmd);

    auto patterns = extractCheckPatterns(content);
    std::string error = verifyPatterns(output, patterns);
    if (!error.empty()) {
        std::ostringstream msg;
        msg << error << "\n";
        msg << "Output was:\n" << output.substr(0, 500);
        if (output.length() > 500) {
            msg << "\n... (truncated)";
        }
        throw std::runtime_error(msg.str());
    }
}

/**
 * Run a single bf-codegen test.
 * Uses EcoRunner for JIT tests (in-process), subprocess for others.
 * Throws std::runtime_error on failure.
 */
inline void runBFCodegenTest(const std::string& testPath) {
    std::string content = readFile(testPath);

    if (isExpectedFail(content)) {
        std::cout << "  (XFAIL - skipped)" << std::endl;
        return;
    }

    std::string emitMode = parseEmitMode(content);

    if (emitMode == "jit") {
        runJITTest(testPath, content);
    } else {
        runSubprocessTest(testPath, content, emitMode);
    }
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
            [](const std::string& path) {
                runBFCodegenTest(path);
            }
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
