#pragma once

#include "../TestSuite.hpp"
#include "../../runtime/src/codegen/EcoRunner.hpp"
#include "../../runtime/src/allocator/GCStats.hpp"
#include "../../runtime/src/allocator/Allocator.hpp"

#include <array>
#include <csignal>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <filesystem>
#include <fstream>
#include <iostream>
#include <memory>
#include <regex>
#include <sstream>
#include <stdexcept>
#include <string>
#include <sys/mman.h>
#include <sys/wait.h>
#include <unistd.h>
#include <vector>

namespace ElmTest {

// ============================================================================
// Fork-Based Test Isolation with Shared Memory
// ============================================================================

/**
 * Shared memory structure for parent-child communication.
 * Allocated via mmap(MAP_SHARED) before fork().
 */
struct SharedTestResult {
    // Status flags
    bool completed;          // Child finished execution (vs crashed mid-way)
    bool passed;             // Test passed

    // Error/output buffers (fixed size)
    char error[4096];        // Error message if failed
    char output[8192];       // Test output (stdout capture)

    // GCStats fields (copied from child's stats)
    uint64_t objects_allocated;
    uint64_t bytes_allocated;
    uint64_t minor_gc_count;
    uint64_t objects_survived;
    uint64_t objects_promoted;
    uint64_t bytes_freed;
    uint64_t total_minor_gc_time_ns;
    uint64_t major_gc_count;
    uint64_t total_major_gc_time_ns;
    uint64_t buffers_allocated;
    uint64_t buffers_filled;
    uint64_t concurrent_marks_started;
    uint64_t mark_sweeps_completed;
};

/**
 * Result of an isolated test execution.
 */
struct IsolatedTestResult {
    bool passed;
    bool crashed;
    int exitCode;
    int signal;              // Signal number if crashed (e.g., SIGSEGV=11)
    std::string error;
    std::string output;
};

/**
 * Global accumulated GCStats across all forked test processes.
 */
inline Elm::GCStats& getAccumulatedStats() {
    static Elm::GCStats accumulated;
    return accumulated;
}

/**
 * Convert signal number to human-readable name.
 */
inline std::string signalName(int sig) {
    switch (sig) {
        case SIGSEGV: return "SIGSEGV (Segmentation fault)";
        case SIGABRT: return "SIGABRT (Aborted)";
        case SIGFPE:  return "SIGFPE (Floating point exception)";
        case SIGBUS:  return "SIGBUS (Bus error)";
        case SIGILL:  return "SIGILL (Illegal instruction)";
        case SIGKILL: return "SIGKILL (Killed)";
        case SIGTERM: return "SIGTERM (Terminated)";
        default:      return "Signal " + std::to_string(sig);
    }
}

/**
 * Copy GCStats from the Allocator to shared memory (called in child process).
 */
inline void copyStatsToShared(SharedTestResult* shared) {
#if ENABLE_GC_STATS
    Elm::GCStats stats = Elm::Allocator::instance().getCombinedStats();
    shared->objects_allocated = stats.objects_allocated;
    shared->bytes_allocated = stats.bytes_allocated;
    shared->minor_gc_count = stats.minor_gc_count;
    shared->objects_survived = stats.objects_survived;
    shared->objects_promoted = stats.objects_promoted;
    shared->bytes_freed = stats.bytes_freed;
    shared->total_minor_gc_time_ns = stats.total_minor_gc_time_ns;
    shared->major_gc_count = stats.major_gc_count;
    shared->total_major_gc_time_ns = stats.total_major_gc_time_ns;
    shared->buffers_allocated = stats.buffers_allocated;
    shared->buffers_filled = stats.buffers_filled;
    shared->concurrent_marks_started = stats.concurrent_marks_started;
    shared->mark_sweeps_completed = stats.mark_sweeps_completed;
#endif
}

/**
 * Copy GCStats from shared memory to a GCStats object for accumulation.
 */
inline void accumulateFromShared(const SharedTestResult* shared) {
    Elm::GCStats childStats;
    childStats.objects_allocated = shared->objects_allocated;
    childStats.bytes_allocated = shared->bytes_allocated;
    childStats.minor_gc_count = shared->minor_gc_count;
    childStats.objects_survived = shared->objects_survived;
    childStats.objects_promoted = shared->objects_promoted;
    childStats.bytes_freed = shared->bytes_freed;
    childStats.total_minor_gc_time_ns = shared->total_minor_gc_time_ns;
    childStats.major_gc_count = shared->major_gc_count;
    childStats.total_major_gc_time_ns = shared->total_major_gc_time_ns;
    childStats.buffers_allocated = shared->buffers_allocated;
    childStats.buffers_filled = shared->buffers_filled;
    childStats.concurrent_marks_started = shared->concurrent_marks_started;
    childStats.mark_sweeps_completed = shared->mark_sweeps_completed;

    getAccumulatedStats().combine(childStats);
}

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

    // Use popen to run command and capture output
    std::string fullCmd = cmd + " 2>&1";
    std::unique_ptr<FILE, decltype(&pclose)> pipe(popen(fullCmd.c_str(), "r"), pclose);

    if (!pipe) {
        throw std::runtime_error("popen() failed for command: " + cmd);
    }

    while (fgets(buffer.data(), buffer.size(), pipe.get()) != nullptr) {
        result += buffer.data();
    }

    // Get exit status
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
 * Get the guida compiler path.
 */
inline std::string getGuidaPath() {
    // Try common locations relative to test execution directory
    std::vector<std::string> candidates = {
        "compiler/bin/index.js",
        "../compiler/bin/index.js",
        "../../compiler/bin/index.js",
    };

    for (const auto& path : candidates) {
        if (std::filesystem::exists(path)) {
            return std::filesystem::absolute(path).string();
        }
    }

    // Fallback to absolute path
    return "/work/compiler/bin/index.js";
}

/**
 * Get the test/elm directory path.
 */
inline std::string getElmTestDir() {
    std::vector<std::string> candidates = {
        "test/elm",
        "../test/elm",
        "../../test/elm",
    };

    for (const auto& dir : candidates) {
        if (std::filesystem::exists(dir) && std::filesystem::is_directory(dir)) {
            return std::filesystem::absolute(dir).string();
        }
    }

    return "/work/test/elm";
}

/**
 * Extract expected output from Elm source file.
 * Looks for pattern: Expected output: "..."
 */
inline std::string extractExpectedOutput(const std::string& content) {
    std::regex pattern(R"(Expected output:\s*\"([^\"]+)\")");
    std::smatch match;
    if (std::regex_search(content, match, pattern)) {
        return match[1].str();
    }
    return "";
}

/**
 * Extract CHECK patterns from Elm file comments.
 * Looks for: -- CHECK: <pattern>
 */
inline std::vector<std::string> extractCheckPatterns(const std::string& content) {
    std::vector<std::string> patterns;
    std::istringstream stream(content);
    std::string line;

    while (std::getline(stream, line)) {
        // Look for -- CHECK: patterns
        size_t pos = line.find("-- CHECK:");
        if (pos != std::string::npos) {
            std::string pattern = line.substr(pos + 10);  // Skip "-- CHECK: "
            // Trim whitespace
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
    return "";  // Success
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
 * Run a single Elm test.
 *
 * 1. Compile .elm file to .mlir using guida compiler (exec)
 * 2. Run .mlir through EcoRunner (in-process JIT)
 * 3. Verify output matches expected patterns
 */
inline void runElmTest(const std::string& elmPath) {
    // Get paths
    std::string guidaPath = getGuidaPath();
    std::string elmTestDir = getElmTestDir();
    std::string filename = std::filesystem::path(elmPath).stem().string();

    // MLIR output goes to the elm test directory
    std::string mlirPath = elmTestDir + "/" + filename + ".mlir";

    // Read Elm source for expected patterns
    std::string elmContent = readFile(elmPath);
    auto checkPatterns = extractCheckPatterns(elmContent);
    std::string expectedOutput = extractExpectedOutput(elmContent);

    // If no CHECK patterns and there's an expected output, use that
    if (checkPatterns.empty() && !expectedOutput.empty()) {
        checkPatterns.push_back(expectedOutput);
    }

    // Step 1: Compile Elm to MLIR using guida
    // Must run from directory containing elm.json
    std::string compileCmd = "cd \"" + elmTestDir + "\" && node \"" + guidaPath +
                             "\" make \"" + elmPath + "\" --output=\"" + mlirPath + "\"";

    auto [compileExitCode, compileOutput] = executeCommand(compileCmd);

    if (compileExitCode != 0) {
        // Clean up partial MLIR file if it exists
        std::filesystem::remove(mlirPath);

        std::ostringstream msg;
        msg << "Guida compilation failed (exit code " << compileExitCode << ")\n";
        msg << "Command: " << compileCmd << "\n";
        msg << "Output:\n" << compileOutput.substr(0, 1000);
        throw std::runtime_error(msg.str());
    }

    // Verify MLIR was generated
    if (!std::filesystem::exists(mlirPath)) {
        std::ostringstream msg;
        msg << "MLIR file not generated: " << mlirPath << "\n";
        msg << "Compiler output:\n" << compileOutput;
        throw std::runtime_error(msg.str());
    }

    // Step 2: Run MLIR through EcoRunner (in-process)
    auto& runner = getRunner();
    runner.reset();

    auto result = runner.runFile(mlirPath);

    // Clean up MLIR file -- temporarily disabled for debugging
    // std::filesystem::remove(mlirPath);

    // Check for execution failure
    if (!result.success) {
        std::ostringstream msg;
        msg << "JIT execution failed: " << result.errorMessage << "\n";
        msg << "Output:\n" << result.output.substr(0, 500);
        throw std::runtime_error(msg.str());
    }

    // Step 3: Verify output patterns
    if (!checkPatterns.empty()) {
        std::string error = verifyPatterns(result.output, checkPatterns);
        if (!error.empty()) {
            std::ostringstream msg;
            msg << error << "\n";
            msg << "Actual output:\n" << result.output.substr(0, 500);
            if (result.output.length() > 500) {
                msg << "\n... (truncated)";
            }
            throw std::runtime_error(msg.str());
        }
    }
}

/**
 * Run a single Elm test in an isolated forked process.
 *
 * Uses mmap(MAP_SHARED) for parent-child communication:
 * - Child process runs the test
 * - Results and GCStats are written to shared memory
 * - Parent waits and reads results, protected from crashes
 */
inline IsolatedTestResult runElmTestIsolated(const std::string& elmPath) {
    // Allocate shared memory for parent-child communication
    SharedTestResult* shared = static_cast<SharedTestResult*>(mmap(
        nullptr,
        sizeof(SharedTestResult),
        PROT_READ | PROT_WRITE,
        MAP_SHARED | MAP_ANONYMOUS,
        -1, 0
    ));

    if (shared == MAP_FAILED) {
        IsolatedTestResult result;
        result.passed = false;
        result.crashed = false;
        result.error = "Failed to allocate shared memory: " + std::string(strerror(errno));
        return result;
    }

    // Initialize shared memory
    std::memset(shared, 0, sizeof(SharedTestResult));

    // Fork child process
    pid_t pid = fork();

    if (pid < 0) {
        // Fork failed
        munmap(shared, sizeof(SharedTestResult));
        IsolatedTestResult result;
        result.passed = false;
        result.crashed = false;
        result.error = "Fork failed: " + std::string(strerror(errno));
        return result;
    }

    if (pid == 0) {
        // ============ CHILD PROCESS ============
        try {
            runElmTest(elmPath);

            // Test passed - write success to shared memory
            shared->passed = true;
            shared->completed = true;

        } catch (const std::exception& e) {
            // Test failed with exception
            shared->passed = false;
            shared->completed = true;
            std::strncpy(shared->error, e.what(), sizeof(shared->error) - 1);
            shared->error[sizeof(shared->error) - 1] = '\0';
        } catch (...) {
            // Unknown exception
            shared->passed = false;
            shared->completed = true;
            std::strncpy(shared->error, "Unknown exception", sizeof(shared->error) - 1);
        }

        // Copy GCStats from allocator to shared memory
        copyStatsToShared(shared);

        // Exit child process
        _exit(shared->passed ? 0 : 1);
    }

    // ============ PARENT PROCESS ============
    int status;
    waitpid(pid, &status, 0);

    IsolatedTestResult result;

    if (WIFSIGNALED(status)) {
        // Child was killed by a signal (crashed)
        result.passed = false;
        result.crashed = true;
        result.signal = WTERMSIG(status);
        result.error = "Test crashed: " + signalName(result.signal);

    } else if (WIFEXITED(status)) {
        result.exitCode = WEXITSTATUS(status);

        if (shared->completed) {
            // Child completed normally
            result.passed = shared->passed;
            result.crashed = false;
            result.error = shared->error;
            result.output = shared->output;

            // Accumulate GCStats from child
            accumulateFromShared(shared);

        } else {
            // Child exited without setting completed flag (shouldn't happen)
            result.passed = false;
            result.crashed = true;
            result.error = "Test exited unexpectedly (exit code " +
                           std::to_string(result.exitCode) + ")";
        }
    } else {
        // Unknown status
        result.passed = false;
        result.crashed = true;
        result.error = "Unknown wait status";
    }

    // Clean up shared memory
    munmap(shared, sizeof(SharedTestResult));

    return result;
}

// ============================================================================
// Test Suite Builder
// ============================================================================

/**
 * Discover all .elm test files in the elm test directory.
 */
inline std::vector<std::string> discoverTests(const std::string& testDir) {
    std::vector<std::string> tests;

    std::string srcDir = testDir + "/src";
    if (!std::filesystem::exists(srcDir) || !std::filesystem::is_directory(srcDir)) {
        return tests;
    }

    for (const auto& entry : std::filesystem::directory_iterator(srcDir)) {
        if (entry.is_regular_file() && entry.path().extension() == ".elm") {
            tests.push_back(entry.path().string());
        }
    }

    // Sort for consistent ordering
    std::sort(tests.begin(), tests.end());
    return tests;
}

/**
 * Create a UnitTest for a single .elm file.
 * Uses fork-based isolation to protect against crashes.
 */
inline Testing::UnitTest createElmTest(const std::string& testPath) {
    std::string testName = std::filesystem::path(testPath).filename().string();

    return Testing::UnitTest(
        "elm/" + testName,
        [testPath]() {
            auto result = runElmTestIsolated(testPath);

            if (result.crashed) {
                throw std::runtime_error(result.error);
            }
            if (!result.passed) {
                throw std::runtime_error(result.error);
            }
            // Test passed
        }
    );
}

/**
 * Build the complete Elm test suite.
 * Call this from main.cpp to integrate with the test framework.
 */
inline Testing::TestSuite buildElmTestSuite() {
    Testing::TestSuite suite("Elm E2E");

    std::string testDir = getElmTestDir();

    if (!std::filesystem::exists(testDir) || !std::filesystem::is_directory(testDir)) {
        std::cerr << "Warning: Could not find Elm test directory: " << testDir << std::endl;
        return suite;
    }

    // Discover and add all tests
    auto testPaths = discoverTests(testDir);
    for (const auto& testPath : testPaths) {
        suite.add(createElmTest(testPath));
    }

    return suite;
}

}  // namespace ElmTest
