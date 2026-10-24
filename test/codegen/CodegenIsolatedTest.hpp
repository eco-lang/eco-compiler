#pragma once

// Driver for the codegen .mlir suite (test/codegen/*.mlir), run in-process from test/test. The
// bf-codegen suite (test/bf-codegen/BFCodegenTest.hpp) uses the same fixture runner.
//
// There is no lit config: this driver interprets the fixtures' `// RUN:` lines itself, and runs
// EVERY one of them. A RUN line has the form
//
//   // RUN: [not [--crash]] [env NAME=VALUE...] %ecoc %s [-emit=MODE] [ARGS...] [2>&1]
//   //        | %FileCheck %s [--check-prefix=P | --check-prefixes=P,Q]
//
// and anything else is a hard error, so a RUN line cannot silently assert less than it says.
// ARGS are passed to ecoc verbatim. The exit status is checked as lit does (SD-21): without
// `not` ecoc must exit 0; `not` needs a non-zero exit (a crash does not count); `not --crash`
// needs a crash (a fatal signal, e.g. the SIGABRT of LLVM's report_fatal_error). The output
// (stdout + stderr) must satisfy the directives of the line's FileCheck prefixes (default CHECK),
// matched by test/CheckPatterns.hpp in FileCheck order, not by FileCheck itself; a prefix with no
// directive in the file is an error, as in FileCheck.
//
// `-emit=jit` lines with no `not`, env or ARGS, in a fixture without `eco.crash`, run in-process
// (EcoRunner, on the region nursery); all other lines run ecoc as a subprocess. A fixture without
// any RUN line (the llvm_statepoint_struct_return_* probes, which their own script drives) is
// still parsed and lowered here: `%ecoc %s` must exit 0.

#include "../CheckPatterns.hpp"
#include "../IsolatedTestRunner.hpp"
#include "../TestSuite.hpp"
#include "../../runtime/src/codegen/EcoRunner.hpp"
#include "../RegionNurseryGuard.hpp"

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

namespace CodegenIsolatedTest {

// ============================================================================
// Helper Functions
// ============================================================================

/// How a subprocess ended.
struct CommandResult {
    int exitCode = 0;   ///< exit status of a normal exit
    int signal = 0;     ///< the fatal signal, or 0 for a normal exit
    std::string output; ///< stdout + stderr
};

/**
 * Execute a command and capture its output (stdout and stderr).
 * Used for the RUN lines that run ecoc as a subprocess.
 */
inline CommandResult executeCommand(const std::string& cmd) {
    std::array<char, 4096> buffer;
    std::string result;

#if defined(_WIN32)
#  define _eco_popen  ::_popen
#  define _eco_pclose ::_pclose
#else
#  define _eco_popen  ::popen
#  define _eco_pclose ::pclose
#endif

    // Use popen to run command and capture output
    std::string fullCmd = cmd + " 2>&1";
    std::unique_ptr<FILE, decltype(&_eco_pclose)> pipe(_eco_popen(fullCmd.c_str(), "r"), _eco_pclose);

    if (!pipe) {
        throw std::runtime_error("popen() failed for command: " + cmd);
    }

    while (fgets(buffer.data(), buffer.size(), pipe.get()) != nullptr) {
        result += buffer.data();
    }

    // Get exit status
    int status = _eco_pclose(pipe.release());
#undef _eco_popen
#undef _eco_pclose
    CommandResult r;
    r.output = std::move(result);
#if defined(_WIN32)
    // _pclose returns the child's raw exit code on Windows (or -1 on
    // wait failure) — no WIFEXITED wrapper.
    r.exitCode = status;
#else
    if (WIFSIGNALED(status)) {
        r.signal = WTERMSIG(status);
    } else if (WIFEXITED(status)) {
        r.exitCode = WEXITSTATUS(status);
        // A shell that did not exec its last command reports a fatal
        // signal as 128 + signal.
        if (r.exitCode > 128 && r.exitCode < 128 + 32) {
            r.signal = r.exitCode - 128;
            r.exitCode = 0;
        }
    } else {
        r.exitCode = -1;
    }
#endif
    return r;
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

/// One `// RUN:` line (see the header comment).
struct RunLine {
    std::string text;                   ///< the line as written, for diagnostics
    bool expectFail = false;            ///< `not`: ecoc must exit non-zero (no crash)
    bool expectCrash = false;           ///< `not --crash`: ecoc must die from a signal
    std::vector<std::string> env;       ///< NAME=VALUE pairs of a leading `env`
    std::string emitMode;               ///< the `-emit=` mode
    std::vector<std::string> ecocArgs;  ///< further ecoc arguments, verbatim
    std::vector<std::string> prefixes;  ///< FileCheck prefixes
};

/// ecoc's -emit mode when the command line names none (ecoc.cpp).
inline constexpr const char* kEcocDefaultEmit = "mlir-llvm";

/**
 * Parse every `// RUN:` line of a fixture. Throws on anything the harness
 * cannot honour. A fixture without RUN lines yields `%ecoc %s` with no
 * FileCheck (prefixes empty).
 */
inline std::vector<RunLine> parseRunLines(const std::string& content) {
    std::vector<RunLine> runs;
    std::istringstream stream(content);
    std::string line;
    const std::string tag = "// RUN:";
    while (std::getline(stream, line)) {
        if (!line.empty() && line.back() == '\r') line.pop_back();
        size_t start = line.find_first_not_of(" \t");
        if (start == std::string::npos || line.compare(start, tag.size(), tag) != 0)
            continue;
        RunLine run;
        run.text = line.substr(start);
        run.emitMode = kEcocDefaultEmit;
        auto fail = [&](const std::string& why) {
            throw std::runtime_error("unsupported RUN line (" + why + "): " + run.text);
        };
        std::string body = line.substr(start + tag.size());
        size_t bar = body.find('|');
        if (bar == std::string::npos) fail("no `| %FileCheck %s`");
        if (body.find('|', bar + 1) != std::string::npos) fail("more than one pipe");

        std::istringstream left(body.substr(0, bar));
        std::vector<std::string> toks;
        for (std::string t; left >> t;) toks.push_back(t);
        size_t i = 0;
        if (i < toks.size() && toks[i] == "not") {
            run.expectFail = true;
            ++i;
            if (i < toks.size() && toks[i] == "--crash") {
                run.expectCrash = true;
                ++i;
            }
        }
        if (i < toks.size() && toks[i] == "env") {
            for (++i; i < toks.size() && toks[i].find('=') != std::string::npos &&
                      toks[i][0] != '-' && toks[i][0] != '%';
                 ++i)
                run.env.push_back(toks[i]);
        }
        if (i >= toks.size() || toks[i] != "%ecoc") fail("expected %ecoc");
        bool sawInput = false;
        for (++i; i < toks.size(); ++i) {
            const std::string& t = toks[i];
            if (t == "%s") sawInput = true;
            else if (t == "2>&1") continue;
            else if (t.rfind("-emit=", 0) == 0) run.emitMode = t.substr(6);
            else if (t[0] == '%' || t[0] == '<' || t[0] == '>' || t.find('>') != std::string::npos)
                fail("unknown token `" + t + "`");
            else run.ecocArgs.push_back(t);
        }
        if (!sawInput) fail("ecoc input is not %s");

        std::istringstream right(body.substr(bar + 1));
        std::vector<std::string> fc;
        for (std::string t; right >> t;) fc.push_back(t);
        if (fc.size() < 2 || fc[0] != "%FileCheck" || fc[1] != "%s")
            fail("expected `%FileCheck %s`");
        for (size_t j = 2; j < fc.size(); ++j) {
            const std::string& t = fc[j];
            std::string list;
            if (t.rfind("--check-prefix=", 0) == 0) list = t.substr(15);
            else if (t.rfind("--check-prefixes=", 0) == 0) list = t.substr(17);
            else fail("unsupported FileCheck option `" + t + "`");
            std::istringstream names(list);
            for (std::string n; std::getline(names, n, ',');) {
                if (n.empty()) fail("empty check prefix");
                run.prefixes.push_back(n);
            }
        }
        if (run.prefixes.empty()) run.prefixes.push_back("CHECK");
        runs.push_back(std::move(run));
    }
    if (runs.empty()) {
        RunLine run;
        run.text = "(no RUN line: %ecoc %s must exit 0)";
        run.emitMode = kEcocDefaultEmit;
        runs.push_back(std::move(run));
    }
    return runs;
}

/**
 * Check if the test is expected to fail (has XFAIL marker).
 */
inline bool isExpectedFail(const std::string& content) {
    return content.find("XFAIL:") != std::string::npos;
}

// CheckPattern / extractCheckPatterns / verifyPatterns / patternMatches
// live in /work/test/CheckPatterns.hpp now. Re-export the names into
// this namespace so existing call sites keep compiling unchanged.
using eco_test::CheckPattern;
using eco_test::trimCheckPattern;
using eco_test::extractCheckPatterns;
using eco_test::patternMatches;
using eco_test::verifyPatterns;

/**
 * Get path to ecoc binary relative to test directory.
 * Used for non-JIT tests that need subprocess execution.
 */
inline std::string getEcocPath() {
    // Try common locations
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

    // Fallback: assume it's in PATH or use relative path
    return "build/runtime/src/codegen/ecoc";
}

/**
 * Get the codegen test directory path.
 */
inline std::string getCodegenTestDir() {
    std::vector<std::string> candidates = {
        "test/codegen",
        "../test/codegen",
        "../../test/codegen",
    };

    for (const auto& dir : candidates) {
        if (std::filesystem::exists(dir) && std::filesystem::is_directory(dir)) {
            return std::filesystem::absolute(dir).string();
        }
    }

    return "/work/test/codegen";
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

/// The `// UNSETENV: NAME...` names: ecoc runs without them, for fixtures
/// that must not inherit a gate-wide setting (e.g. forged cap-hoist plans,
/// which ECO_CAPHOIST_VALIDATE=1 would reject by design).
inline std::vector<std::string> unsetEnvNames(const std::string& content) {
    std::vector<std::string> out;
    std::istringstream lines(content);
    std::string line;
    const std::string tag = "// UNSETENV:";
    while (std::getline(lines, line)) {
        auto pos = line.find(tag);
        if (pos == std::string::npos)
            continue;
        std::istringstream names(line.substr(pos + tag.size()));
        for (std::string name; names >> name;)
            out.push_back(name);
    }
    return out;
}

/// Check `output` against the RUN line's FileCheck directives; throws on failure.
inline void checkRunOutput(const RunLine& run, const std::string& content,
                           const std::string& output, const std::string& status) {
    if (run.prefixes.empty()) return;  // the implicit no-RUN-line run
    auto patterns = eco_test::extractCheckPatternsForPrefixes(content, run.prefixes);
    std::string error;
    if (patterns.empty()) {
        error = "no directive for check prefix(es) of this RUN line";
    } else {
        error = verifyPatterns(output, patterns);
    }
    if (!error.empty()) {
        std::ostringstream msg;
        msg << run.text << "\n" << error << "\n";
        if (!status.empty()) msg << status << "\n";
        msg << "Output was:\n" << output.substr(0, 500);
        if (output.length() > 500) {
            msg << "\n... (truncated)";
        }
        throw std::runtime_error(msg.str());
    }
}

/// Should this RUN line run in-process (EcoRunner) rather than as an ecoc subprocess?
inline bool runsInProcess(const RunLine& run, const std::string& content) {
    // eco.crash and `not` fixtures exit the process: never in-process.
    return run.emitMode == "jit" && !run.expectFail && run.env.empty() &&
           run.ecocArgs.empty() && unsetEnvNames(content).empty() &&
           content.find("eco.crash") == std::string::npos;
}

/**
 * Run a JIT RUN line using EcoRunner (in-process).
 * This provides faster execution and direct output capture.
 */
inline void runJITTest(const std::string& testPath, const std::string& content,
                       const RunLine& run) {
    auto& runner = getRunner();

    // Reset heap for test isolation
    runner.reset();
    eco_test::requireRegionNursery();

    auto result = runner.runFile(testPath);

    checkRunOutput(run, content, result.output, "");

    if (!result.success) {
        std::ostringstream msg;
        msg << run.text << "\n";
        msg << "Test failed: " << result.errorMessage << "\n";
        msg << "Output:\n" << result.output.substr(0, 500);
        throw std::runtime_error(msg.str());
    }
}

/**
 * Run a RUN line as an ecoc subprocess and check its exit status (SD-21) and output.
 */
inline void runSubprocessTest(const std::string& testPath, const std::string& content,
                              const RunLine& run) {
    std::string cmd = getEcocPath() + " \"" + testPath + "\" -emit=" + run.emitMode;
    for (const auto& arg : run.ecocArgs)
        cmd += " " + arg;
#ifndef _WIN32
    if (!run.env.empty()) {
        std::string assigns;
        for (const auto& kv : run.env)
            assigns += " " + kv;
        cmd = "env" + assigns + " " + cmd;
    }
    for (const auto& name : unsetEnvNames(content))
        cmd = "env -u " + name + " " + cmd;
#else
    if (!run.env.empty())
        throw std::runtime_error("RUN-line env is not supported on Windows: " + run.text);
#endif

    CommandResult r = executeCommand(cmd);
    std::string status = r.signal ? "ecoc died from signal " + std::to_string(r.signal)
                                  : "ecoc exited with status " + std::to_string(r.exitCode);

    std::string exitError;
    if (run.expectCrash) {
        if (!r.signal) exitError = "`not --crash` expects ecoc to crash";
    } else if (r.signal) {
        exitError = run.expectFail
            ? "`not` expects a non-zero exit, not a crash (use `not --crash` if a crash is "
              "the designed failure mode)"
            : "ecoc crashed";
    } else if (run.expectFail && r.exitCode == 0) {
        exitError = "`not` expects a non-zero exit";
    } else if (!run.expectFail && r.exitCode != 0) {
        exitError = "ecoc failed (add `not` if the fixture expects an error)";
    }
    if (!exitError.empty()) {
        std::ostringstream msg;
        msg << run.text << "\n" << exitError << "; " << status << "\n";
        msg << "Output was:\n" << r.output.substr(0, 500);
        if (r.output.length() > 500) {
            msg << "\n... (truncated)";
        }
        throw std::runtime_error(msg.str());
    }

    checkRunOutput(run, content, r.output, status);
}

/**
 * Run every RUN line of one fixture (codegen and bf-codegen suites).
 * Throws std::runtime_error on the first failing line.
 */
inline void runFixture(const std::string& testPath) {
    std::string content = readFile(testPath);

    if (isExpectedFail(content)) {
        std::cout << "  (XFAIL - skipped)" << std::endl;
        return;
    }

    for (const RunLine& run : parseRunLines(content)) {
        if (runsInProcess(run, content)) {
            runJITTest(testPath, content, run);
        } else {
            runSubprocessTest(testPath, content, run);
        }
    }
}

/**
 * Run a single codegen test. Throws std::runtime_error on failure.
 */
inline void runCodegenTest(const std::string& testPath) {
    runFixture(testPath);
}


// ============================================================================
// Test Discovery
// ============================================================================

/**
 * Discover all .mlir test files in the codegen test directory.
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

    // Sort for consistent ordering
    std::sort(tests.begin(), tests.end());
    return tests;
}

// ============================================================================
// Test Entry for Listing
// ============================================================================

/**
 * A simple Test wrapper for listing purposes.
 * This is only used for collectTests() to support --list and --filter.
 */
class CodegenTestEntry : public Testing::Test {
public:
    CodegenTestEntry(std::string name, std::string path)
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
// Parallel Test Suite
// ============================================================================

/**
 * Parallel test suite for codegen tests.
 *
 * This suite runs all .mlir codegen tests in parallel (up to MAX_PARALLEL_TESTS
 * at a time) and prints results immediately as each test completes.
 *
 * Key features:
 * - Parallel execution with configurable worker count
 * - 60 second timeout per test
 * - Clean shutdown on SIGINT (Ctrl+C)
 * - Immediate output as tests complete (completion order)
 * - Supports filtering via --filter
 * - Process isolation protects against crashes
 */
class CodegenParallelTestSuite : public Testing::Test {
public:
    explicit CodegenParallelTestSuite(const std::string& testDir) : name_("Codegen") {
        // Discover all test files
        auto testPaths = discoverTests(testDir);

        for (const auto& path : testPaths) {
            std::string filename = std::filesystem::path(path).filename().string();
            std::string testName = "codegen/" + filename;
            testEntries_.push_back(std::make_unique<CodegenTestEntry>(testName, path));
        }
    }

    void run() const override {
        runWithResult();
    }

    bool runWithResult() const override {
        // Use the thread-local filter set by TestSuite
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
     * This is the main execution entry point.
     */
    bool runFiltered(const std::string& filter) const {
        // Collect tests matching the filter
        std::vector<std::string> pathsToRun;
        std::vector<std::string> namesToRun;

        for (const auto& entry : testEntries_) {
            const std::string& name = entry->getName();
            if (filter.empty() || name.find(filter) != std::string::npos) {
                pathsToRun.push_back(
                    static_cast<const CodegenTestEntry*>(entry.get())->getPath());
                namesToRun.push_back(name);
            }
        }

        if (pathsToRun.empty()) {
            // Clear previous results
            lastPassCount_ = 0;
            lastFailCount_ = 0;
            lastFailedTests_.clear();
            return true;  // No tests to run
        }

        // Run tests in parallel using the generic runner
        auto summary = IsolatedTestRunner::runTestsParallel(
            pathsToRun,
            namesToRun,
            "codegen"   // the child runs runCodegenTest(path) (main's runIsolatedChild)
        );

        // Store results for TestSuite integration
        lastPassCount_ = summary.passCount;
        lastFailCount_ = summary.failCount;
        lastFailedTests_ = summary.failedTests;

        return summary.failCount == 0;
    }

    /**
     * Get the test entries for external use (e.g., filtering).
     */
    const std::vector<std::unique_ptr<CodegenTestEntry>>& getEntries() const {
        return testEntries_;
    }

    // Override Test methods for detailed result tracking
    bool hasDetailedResults() const override { return true; }
    size_t getLastPassCount() const override { return lastPassCount_; }
    size_t getLastFailCount() const override { return lastFailCount_; }
    const std::vector<std::string>& getLastFailedTests() const override { return lastFailedTests_; }

private:
    std::string name_;
    std::vector<std::unique_ptr<CodegenTestEntry>> testEntries_;

    // Results from last run (mutable since runFiltered is const)
    mutable size_t lastPassCount_ = 0;
    mutable size_t lastFailCount_ = 0;
    mutable std::vector<std::string> lastFailedTests_;
};

/**
 * Build the complete codegen test suite with parallel execution.
 * Call this from main.cpp to integrate with the test framework.
 */
inline std::unique_ptr<CodegenParallelTestSuite> buildCodegenTestSuite() {
    std::string testDir = getCodegenTestDir();

    if (!std::filesystem::exists(testDir) || !std::filesystem::is_directory(testDir)) {
        std::cerr << "Warning: Could not find codegen test directory: " << testDir << std::endl;
    }

    return std::make_unique<CodegenParallelTestSuite>(testDir);
}

}  // namespace CodegenIsolatedTest
