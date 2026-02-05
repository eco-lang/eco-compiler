#pragma once

#include "../IsolatedTestRunner.hpp"
#include "../TestSuite.hpp"
#include "../../runtime/src/codegen/EcoRunner.hpp"
#include "../../runtime/src/allocator/GCStats.hpp"
#include "../../runtime/src/allocator/Allocator.hpp"

#include <algorithm>
#include <array>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <filesystem>
#include <fstream>
#include <future>
#include <iomanip>
#include <iostream>
#include <memory>
#include <regex>
#include <sstream>
#include <stdexcept>
#include <string>
#include <sys/mman.h>
#include <thread>
#include <unistd.h>
#include <vector>

namespace ElmBytesTest {

// ============================================================================
// Parallel Compilation Constants
// ============================================================================

// Maximum number of concurrent Elm compilations to avoid RAM exhaustion.
// Each guida process can use significant memory during compilation.
// Defaults to the number of CPU cores, or 4 if detection fails.
inline size_t getMaxParallelCompilations() {
    unsigned int cores = std::thread::hardware_concurrency();
    return cores > 0 ? static_cast<size_t>(cores) : 4;
}

// ============================================================================
// Elm-Specific Shared Memory Extension
// ============================================================================

/**
 * Extended shared memory structure for Elm tests.
 * Includes GCStats fields for accumulation across forked processes.
 */
struct ElmSharedTestResult {
    // Base fields (matching IsolatedTestRunner::SharedTestResult)
    bool completed;
    bool passed;
    char error[4096];
    char output[8192];

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
 * Global accumulated GCStats across all forked test processes.
 */
inline Elm::GCStats& getAccumulatedStats() {
    static Elm::GCStats accumulated;
    return accumulated;
}

/**
 * Copy GCStats from the Allocator to shared memory (called in child process).
 */
inline void copyStatsToShared(ElmSharedTestResult* shared) {
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
inline void accumulateFromShared(const ElmSharedTestResult* shared) {
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
 * Get the test/elm-bytes directory path.
 */
inline std::string getElmBytesTestDir() {
    std::vector<std::string> candidates = {
        "test/elm-bytes",
        "../test/elm-bytes",
        "../../test/elm-bytes",
    };

    for (const auto& dir : candidates) {
        if (std::filesystem::exists(dir) && std::filesystem::is_directory(dir)) {
            return std::filesystem::absolute(dir).string();
        }
    }

    return "/work/test/elm-bytes";
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
// Two-Phase Compilation Support
// ============================================================================

/**
 * Result of compiling a single Elm file to MLIR.
 */
struct CompileResult {
    std::string elmPath;
    std::string mlirPath;
    bool success;
    std::string errorMessage;
};

/**
 * Check if an Elm file needs recompilation.
 * Returns true if .mlir doesn't exist or .elm is newer than .mlir.
 */
inline bool needsRecompile(const std::string& elmPath, const std::string& mlirPath) {
    if (!std::filesystem::exists(mlirPath)) {
        return true;
    }
    auto elmTime = std::filesystem::last_write_time(elmPath);
    auto mlirTime = std::filesystem::last_write_time(mlirPath);
    return elmTime > mlirTime;
}

/**
 * Get the MLIR output path for an Elm source file.
 * MLIR files are stored in guida-stuff/mlir/ relative to elm.json root.
 */
inline std::string getMlirPath(const std::string& elmPath) {
    std::string testDir = getElmBytesTestDir();
    std::string filename = std::filesystem::path(elmPath).stem().string();
    return testDir + "/guida-stuff/mlir/" + filename + ".mlir";
}

/**
 * Ensure the MLIR output directory exists.
 */
inline void ensureMlirDirExists() {
    std::string testDir = getElmBytesTestDir();
    std::string mlirDir = testDir + "/guida-stuff/mlir";
    std::filesystem::create_directories(mlirDir);
}

/**
 * Compile a single Elm file to MLIR.
 * Returns a CompileResult with success status and paths.
 *
 * @param elmPath Path to the .elm source file
 * @param buildDir Optional build directory name for parallel compilation
 *                 (uses --builddir flag to isolate build artifacts)
 */
inline CompileResult compileElmToMlir(const std::string& elmPath, const std::string& buildDir = "") {
    CompileResult result;
    result.elmPath = elmPath;
    result.mlirPath = getMlirPath(elmPath);
    result.success = false;

    // Check for incremental compilation
    if (!needsRecompile(elmPath, result.mlirPath)) {
        result.success = true;
        return result;
    }

    std::string guidaPath = getGuidaPath();
    std::string testDir = getElmBytesTestDir();

    // Compile Elm to MLIR using guida
    // Include --builddir flag when buildDir is specified for parallel compilation
    std::string compileCmd = "cd \"" + testDir + "\" && node \"" + guidaPath +
                             "\" make \"" + elmPath + "\" --output=\"" + result.mlirPath + "\"";
    if (!buildDir.empty()) {
        compileCmd += " --builddir=\"" + buildDir + "\"";
    }

    auto [exitCode, output] = executeCommand(compileCmd);

    if (exitCode != 0) {
        // Clean up partial MLIR file if it exists
        std::filesystem::remove(result.mlirPath);

        std::ostringstream msg;
        msg << "Guida compilation failed (exit code " << exitCode << ")\n";
        msg << "Command: " << compileCmd << "\n";
        msg << "Output:\n" << output.substr(0, 1000);
        result.errorMessage = msg.str();
        return result;
    }

    // Verify MLIR was generated
    if (!std::filesystem::exists(result.mlirPath)) {
        std::ostringstream msg;
        msg << "MLIR file not generated: " << result.mlirPath << "\n";
        msg << "Compiler output:\n" << output;
        result.errorMessage = msg.str();
        return result;
    }

    result.success = true;
    return result;
}

/**
 * Compile all Elm test files to MLIR using parallel compilation.
 * Uses --builddir flag to isolate build artifacts for each test, allowing
 * parallel compilation without d.dat race conditions.
 *
 * Strategy:
 * 1. First compile runs with its own builddir - populates shared package cache
 * 2. Remaining compiles run in parallel, each with their own builddir
 *
 * Supports incremental compilation - skips files where .mlir is up-to-date.
 *
 * @param elmPaths List of .elm file paths to compile
 * @return Vector of CompileResults (one per input file)
 */
inline std::vector<CompileResult> compileAllElmTests(const std::vector<std::string>& elmPaths) {
    std::vector<CompileResult> results;
    results.resize(elmPaths.size());

    // Ensure output directory exists
    ensureMlirDirExists();

    size_t total = elmPaths.size();
    size_t compiled = 0;
    size_t skipped = 0;
    size_t failed = 0;

    std::cout << "Compiling " << total << " Elm Bytes tests (parallel with --builddir)..." << std::endl;

    // Separate into cached and needs-compile lists
    std::vector<size_t> needsCompile;
    for (size_t i = 0; i < elmPaths.size(); i++) {
        const auto& elmPath = elmPaths[i];
        std::string mlirPath = getMlirPath(elmPath);

        if (!needsRecompile(elmPath, mlirPath)) {
            // Already up to date
            skipped++;
            CompileResult result;
            result.elmPath = elmPath;
            result.mlirPath = mlirPath;
            result.success = true;
            results[i] = result;
        } else {
            needsCompile.push_back(i);
        }
    }

    if (needsCompile.empty()) {
        std::cout << "  All " << skipped << " tests cached, nothing to compile" << std::endl;
        return results;
    }

    std::cout << "  " << skipped << " cached, " << needsCompile.size() << " to compile" << std::endl;

    // First compile without parallelism to populate package cache
    if (!needsCompile.empty()) {
        size_t firstIdx = needsCompile[0];
        const auto& firstPath = elmPaths[firstIdx];
        std::string filename = std::filesystem::path(firstPath).stem().string();

        std::cout << "  [1/" << total << "] " << filename << " (initial)" << std::flush;
        auto result = compileElmToMlir(firstPath, filename);
        results[firstIdx] = result;

        if (result.success) {
            std::cout << " ok" << std::endl;
            compiled++;
        } else {
            std::cout << " FAILED" << std::endl;
            failed++;
        }
    }

    // Compile remaining tests in parallel using --builddir
    // Uses sliding window: always keep getMaxParallelCompilations() active
    if (needsCompile.size() > 1) {
        std::cout << "  Compiling remaining " << (needsCompile.size() - 1)
                  << " tests (max " << getMaxParallelCompilations() << " parallel)..." << std::endl;

        // Track active compilations: (future, result index, filename)
        struct ActiveCompile {
            std::future<CompileResult> future;
            size_t resultIdx;
            std::string filename;
        };
        std::vector<ActiveCompile> active;

        size_t nextToStart = 1;  // Start after the first (already compiled)
        size_t progressCount = 2;

        // Helper to start a new compilation
        auto startNext = [&]() {
            if (nextToStart < needsCompile.size()) {
                size_t idx = needsCompile[nextToStart];
                const auto& elmPath = elmPaths[idx];
                std::string filename = std::filesystem::path(elmPath).stem().string();

                active.push_back({
                    std::async(std::launch::async, [elmPath, filename]() {
                        return compileElmToMlir(elmPath, filename);
                    }),
                    idx,
                    filename
                });
                nextToStart++;
            }
        };

        // Fill initial slots
        while (active.size() < getMaxParallelCompilations() && nextToStart < needsCompile.size()) {
            startNext();
        }

        // Process until all complete
        while (!active.empty()) {
            // Find a completed future
            size_t completedIdx = 0;
            while (true) {
                for (size_t i = 0; i < active.size(); i++) {
                    if (active[i].future.wait_for(std::chrono::milliseconds(0)) == std::future_status::ready) {
                        completedIdx = i;
                        goto found;
                    }
                }
                // None ready, wait a bit
                std::this_thread::sleep_for(std::chrono::milliseconds(10));
            }
            found:

            // Get the result
            auto& done = active[completedIdx];
            auto result = done.future.get();
            results[done.resultIdx] = result;

            std::cout << "  [" << progressCount << "/" << total << "] " << done.filename;
            if (result.success) {
                std::cout << " ok" << std::endl;
                compiled++;
            } else {
                std::cout << " FAILED" << std::endl;
                failed++;
            }
            progressCount++;

            // Remove completed and start next
            active.erase(active.begin() + completedIdx);
            startNext();
        }
    }

    std::cout << "Compilation complete: " << compiled << " compiled, "
              << skipped << " cached, " << failed << " failed" << std::endl;

    return results;
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
 * Run a single Elm test from a pre-compiled MLIR file (Phase 2).
 *
 * This function assumes the MLIR file already exists (compiled in Phase 1).
 * It reads CHECK patterns from the original Elm source, runs the MLIR
 * through EcoRunner, and verifies the output.
 *
 * @param mlirPath Path to the pre-compiled .mlir file
 * @param elmPath Path to the original .elm source (for CHECK patterns)
 */
inline void runElmTestFromMlir(const std::string& mlirPath, const std::string& elmPath) {
    // Read Elm source for expected patterns
    std::string elmContent = readFile(elmPath);
    auto checkPatterns = extractCheckPatterns(elmContent);
    std::string expectedOutput = extractExpectedOutput(elmContent);

    // If no CHECK patterns and there's an expected output, use that
    if (checkPatterns.empty() && !expectedOutput.empty()) {
        checkPatterns.push_back(expectedOutput);
    }

    // Verify MLIR file exists (should have been compiled in Phase 1)
    if (!std::filesystem::exists(mlirPath)) {
        throw std::runtime_error("MLIR file not found: " + mlirPath +
                                 " (should have been compiled in Phase 1)");
    }

    // Run MLIR through EcoRunner (in-process)
    auto& runner = getRunner();
    runner.reset();

    auto result = runner.runFile(mlirPath);

    // Check for execution failure
    if (!result.success) {
        std::ostringstream msg;
        msg << "JIT execution failed: " << result.errorMessage << "\n";
        msg << "Output:\n" << result.output.substr(0, 500);
        throw std::runtime_error(msg.str());
    }

    // Verify output patterns
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

// ============================================================================
// Parallel Test Execution with GCStats
// ============================================================================

/**
 * Run multiple MLIR tests in parallel with GCStats accumulation (Phase 2).
 *
 * This function runs pre-compiled MLIR files through EcoRunner in parallel.
 * It assumes all MLIR files have already been compiled (Phase 1).
 */
inline IsolatedTestRunner::ParallelTestSummary runMlirTestsParallel(
    const std::vector<std::string>& mlirPaths,
    const std::vector<std::string>& elmPaths,
    const std::vector<std::string>& testNames)
{
    using namespace IsolatedTestRunner;

    const size_t numTests = mlirPaths.size();
    if (numTests == 0) {
        return {};
    }

    // Summary to track results
    ParallelTestSummary summary;

    // Elm-specific contexts with extended shared memory
    struct ElmTestContext {
        size_t index;
        std::string mlirPath;   // Pre-compiled MLIR file
        std::string elmPath;    // Original Elm source (for CHECK patterns)
        std::string name;
        ElmSharedTestResult* shared;
        pid_t pid;
        int outputPipe[2];
        std::chrono::steady_clock::time_point startTime;
        IsolatedTestResult result;
        bool completed;
        std::string capturedOutput;
    };

    std::vector<ElmTestContext> contexts(numTests);
    for (size_t i = 0; i < numTests; i++) {
        contexts[i].index = i;
        contexts[i].mlirPath = mlirPaths[i];
        contexts[i].elmPath = elmPaths[i];
        contexts[i].name = testNames[i];
        contexts[i].shared = nullptr;
        contexts[i].pid = 0;
        contexts[i].completed = false;
    }

    // Pre-allocate shared memory for all tests (with GCStats)
    for (auto& ctx : contexts) {
        ctx.shared = static_cast<ElmSharedTestResult*>(mmap(
            nullptr,
            sizeof(ElmSharedTestResult),
            PROT_READ | PROT_WRITE,
            MAP_SHARED | MAP_ANONYMOUS,
            -1, 0
        ));

        if (ctx.shared == MAP_FAILED) {
            for (auto& c : contexts) {
                if (c.shared && c.shared != MAP_FAILED) {
                    munmap(c.shared, sizeof(ElmSharedTestResult));
                }
            }
            for (const auto& name : testNames) {
                printTestResult(name, "", false, "Failed to allocate shared memory");
                summary.failCount++;
                summary.failedTests.push_back(name);
            }
            return summary;
        }
        std::memset(ctx.shared, 0, sizeof(ElmSharedTestResult));
    }

    // Track active child PIDs for SIGINT handler
    std::vector<pid_t> activeChildren;
    std::unordered_map<pid_t, size_t> pidToIndex;

    installSigintHandler(&activeChildren);

    size_t nextToFork = 0;
    size_t testsCompleted = 0;

    while (testsCompleted < numTests && !g_interrupted) {
        while (activeChildren.size() < MAX_PARALLEL_TESTS &&
               nextToFork < numTests &&
               !g_interrupted) {

            auto& ctx = contexts[nextToFork];

            if (pipe(ctx.outputPipe) < 0) {
                ctx.result.passed = false;
                ctx.result.crashed = false;
                ctx.result.error = "Pipe failed: " + std::string(strerror(errno));
                ctx.completed = true;
                testsCompleted++;
                nextToFork++;
                continue;
            }

            pid_t pid = fork();

            if (pid < 0) {
                close(ctx.outputPipe[0]);
                close(ctx.outputPipe[1]);
                ctx.result.passed = false;
                ctx.result.crashed = false;
                ctx.result.error = "Fork failed: " + std::string(strerror(errno));
                ctx.completed = true;
                testsCompleted++;
            } else if (pid == 0) {
                // ============ CHILD PROCESS ============
                close(ctx.outputPipe[0]);
                dup2(ctx.outputPipe[1], STDOUT_FILENO);
                dup2(ctx.outputPipe[1], STDERR_FILENO);
                close(ctx.outputPipe[1]);

                try {
                    // Run pre-compiled MLIR (no compilation in child process)
                    runElmTestFromMlir(ctx.mlirPath, ctx.elmPath);
                    ctx.shared->passed = true;
                    ctx.shared->completed = true;
                } catch (const std::exception& e) {
                    ctx.shared->passed = false;
                    ctx.shared->completed = true;
                    std::strncpy(ctx.shared->error, e.what(), sizeof(ctx.shared->error) - 1);
                    ctx.shared->error[sizeof(ctx.shared->error) - 1] = '\0';
                } catch (...) {
                    ctx.shared->passed = false;
                    ctx.shared->completed = true;
                    std::strncpy(ctx.shared->error, "Unknown exception", sizeof(ctx.shared->error) - 1);
                }

                // Copy GCStats to shared memory
                copyStatsToShared(ctx.shared);
                _exit(ctx.shared->passed ? 0 : 1);
            } else {
                // ============ PARENT PROCESS ============
                close(ctx.outputPipe[1]);
                ctx.pid = pid;
                ctx.startTime = std::chrono::steady_clock::now();
                activeChildren.push_back(pid);
                pidToIndex[pid] = nextToFork;
            }

            nextToFork++;
        }

        if (activeChildren.empty()) {
            break;
        }

        int status;
        pid_t finished = waitpid(-1, &status, WNOHANG);

        if (finished > 0) {
            auto it = pidToIndex.find(finished);
            if (it != pidToIndex.end()) {
                size_t idx = it->second;
                auto& ctx = contexts[idx];

                activeChildren.erase(
                    std::remove(activeChildren.begin(), activeChildren.end(), finished),
                    activeChildren.end()
                );
                pidToIndex.erase(it);

                ctx.capturedOutput = readAllFromFd(ctx.outputPipe[0]);
                close(ctx.outputPipe[0]);

                if (WIFSIGNALED(status)) {
                    ctx.result.passed = false;
                    ctx.result.crashed = true;
                    ctx.result.signal = WTERMSIG(status);
                    ctx.result.error = "Test crashed: " + signalName(ctx.result.signal);
                } else if (WIFEXITED(status)) {
                    ctx.result.exitCode = WEXITSTATUS(status);

                    if (ctx.shared->completed) {
                        ctx.result.passed = ctx.shared->passed;
                        ctx.result.crashed = false;
                        ctx.result.error = ctx.shared->error;
                        ctx.result.output = ctx.shared->output;

                        // Accumulate GCStats
                        accumulateFromShared(ctx.shared);
                    } else {
                        ctx.result.passed = false;
                        ctx.result.crashed = true;
                        ctx.result.error = "Test exited unexpectedly (exit code " +
                                           std::to_string(ctx.result.exitCode) + ")";
                    }
                } else {
                    ctx.result.passed = false;
                    ctx.result.crashed = true;
                    ctx.result.error = "Unknown wait status";
                }

                printTestResult(ctx.name, ctx.capturedOutput,
                                ctx.result.passed, ctx.result.error);

                if (ctx.result.passed) {
                    summary.passCount++;
                } else {
                    summary.failCount++;
                    summary.failedTests.push_back(ctx.name);
                }

                ctx.completed = true;
                testsCompleted++;
            }
        } else if (finished == 0) {
            auto now = std::chrono::steady_clock::now();

            for (auto& ctx : contexts) {
                if (ctx.pid > 0 && !ctx.completed) {
                    auto elapsed = std::chrono::duration_cast<std::chrono::seconds>(
                        now - ctx.startTime).count();

                    if (elapsed >= TEST_TIMEOUT_SECONDS) {
                        kill(ctx.pid, SIGKILL);

                        int status;
                        waitpid(ctx.pid, &status, 0);

                        ctx.capturedOutput = readAllFromFd(ctx.outputPipe[0]);
                        close(ctx.outputPipe[0]);

                        activeChildren.erase(
                            std::remove(activeChildren.begin(), activeChildren.end(), ctx.pid),
                            activeChildren.end()
                        );
                        pidToIndex.erase(ctx.pid);

                        ctx.result.passed = false;
                        ctx.result.crashed = true;
                        ctx.result.error = "Test timed out after " +
                                           std::to_string(TEST_TIMEOUT_SECONDS) + " seconds";

                        printTestResult(ctx.name, ctx.capturedOutput,
                                        ctx.result.passed, ctx.result.error);

                        summary.failCount++;
                        summary.failedTests.push_back(ctx.name);

                        ctx.completed = true;
                        testsCompleted++;
                    }
                }
            }

            usleep(10000);  // 10ms
        } else if (finished == -1 && errno != ECHILD) {
            break;
        }
    }

    if (g_interrupted) {
        for (pid_t pid : activeChildren) {
            kill(pid, SIGKILL);
            int status;
            waitpid(pid, &status, 0);
        }

        for (auto& ctx : contexts) {
            if (!ctx.completed) {
                if (ctx.pid > 0) {
                    ctx.capturedOutput = readAllFromFd(ctx.outputPipe[0]);
                    close(ctx.outputPipe[0]);
                }
                ctx.result.passed = false;
                ctx.result.crashed = true;
                ctx.result.error = "Test interrupted by user";

                printTestResult(ctx.name, ctx.capturedOutput,
                                ctx.result.passed, ctx.result.error);

                summary.failCount++;
                summary.failedTests.push_back(ctx.name);

                ctx.completed = true;
            }
        }
    }

    restoreSigintHandler();

    for (auto& ctx : contexts) {
        if (ctx.shared && ctx.shared != MAP_FAILED) {
            munmap(ctx.shared, sizeof(ElmSharedTestResult));
        }
    }

    return summary;
}

// ============================================================================
// Test Suite Builder
// ============================================================================

/**
 * Discover all .elm test files in the elm-bytes test directory.
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
 * A simple Test wrapper for listing purposes.
 * This is only used for collectTests() to support --list and --filter.
 */
class ElmBytesTestEntry : public Testing::Test {
public:
    ElmBytesTestEntry(std::string name, std::string path)
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

/**
 * Parallel test suite for Elm Bytes E2E tests.
 *
 * This suite runs all Elm Bytes tests in parallel (up to MAX_PARALLEL_TESTS at a time)
 * and prints results immediately as each test completes.
 */
class ElmBytesParallelTestSuite : public Testing::Test {
public:
    explicit ElmBytesParallelTestSuite(const std::string& testDir) : name_("Elm Bytes E2E") {
        // Discover all test files
        auto testPaths = discoverTests(testDir);

        for (const auto& path : testPaths) {
            std::string filename = std::filesystem::path(path).filename().string();
            std::string testName = "elm-bytes/" + filename;
            testEntries_.push_back(std::make_unique<ElmBytesTestEntry>(testName, path));
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
     *
     * Two-phase approach to avoid d.dat race condition:
     * - Phase 1: Compile all Elm -> MLIR sequentially (single process)
     * - Phase 2: Run MLIR tests in parallel (isolated processes)
     */
    bool runFiltered(const std::string& filter) const {
        // Collect tests matching the filter
        std::vector<std::string> pathsToRun;
        std::vector<std::string> namesToRun;

        for (const auto& entry : testEntries_) {
            const std::string& name = entry->getName();
            if (filter.empty() || name.find(filter) != std::string::npos) {
                pathsToRun.push_back(
                    static_cast<const ElmBytesTestEntry*>(entry.get())->getPath());
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

        // Clear previous results
        lastPassCount_ = 0;
        lastFailCount_ = 0;
        lastFailedTests_.clear();

        // ================================================================
        // PHASE 1: Compile all Elm files to MLIR (sequential, single process)
        // ================================================================
        auto compileResults = compileAllElmTests(pathsToRun);

        // Separate successful compilations from failures
        std::vector<std::string> mlirPaths;
        std::vector<std::string> elmPaths;
        std::vector<std::string> testNames;
        size_t compileFailed = 0;

        for (size_t i = 0; i < compileResults.size(); i++) {
            const auto& result = compileResults[i];
            if (result.success) {
                mlirPaths.push_back(result.mlirPath);
                elmPaths.push_back(result.elmPath);
                testNames.push_back(namesToRun[i]);
            } else {
                // Report compilation failure immediately
                IsolatedTestRunner::printTestResult(namesToRun[i], "",
                    false, result.errorMessage);
                lastFailedTests_.push_back(namesToRun[i]);
                compileFailed++;
            }
        }

        // ================================================================
        // PHASE 2: Run MLIR tests in parallel (no Guida compiler involved)
        // ================================================================
        std::cout << "\nRunning " << mlirPaths.size() << " MLIR tests in parallel...\n";

        IsolatedTestRunner::ParallelTestSummary summary;
        if (!mlirPaths.empty()) {
            summary = runMlirTestsParallel(mlirPaths, elmPaths, testNames);
        }

        // Combine compilation failures with runtime failures
        lastPassCount_ = summary.passCount;
        lastFailCount_ = summary.failCount + compileFailed;
        lastFailedTests_.insert(lastFailedTests_.end(),
            summary.failedTests.begin(), summary.failedTests.end());

        return lastFailCount_ == 0;
    }

    /**
     * Get the test paths for external use (e.g., filtering).
     */
    const std::vector<std::unique_ptr<ElmBytesTestEntry>>& getEntries() const {
        return testEntries_;
    }

    // Override Test methods for detailed result tracking
    bool hasDetailedResults() const override { return true; }
    size_t getLastPassCount() const override { return lastPassCount_; }
    size_t getLastFailCount() const override { return lastFailCount_; }
    const std::vector<std::string>& getLastFailedTests() const override { return lastFailedTests_; }

private:
    std::string name_;
    std::vector<std::unique_ptr<ElmBytesTestEntry>> testEntries_;

    // Results from last run (mutable since runFiltered is const)
    mutable size_t lastPassCount_ = 0;
    mutable size_t lastFailCount_ = 0;
    mutable std::vector<std::string> lastFailedTests_;
};

/**
 * Build the complete Elm Bytes test suite with parallel execution.
 * Call this from main.cpp to integrate with the test framework.
 */
inline std::unique_ptr<ElmBytesParallelTestSuite> buildElmBytesTestSuite() {
    std::string testDir = getElmBytesTestDir();

    if (!std::filesystem::exists(testDir) || !std::filesystem::is_directory(testDir)) {
        std::cerr << "Warning: Could not find Elm Bytes test directory: " << testDir << std::endl;
    }

    return std::make_unique<ElmBytesParallelTestSuite>(testDir);
}

}  // namespace ElmBytesTest
