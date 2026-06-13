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

#if defined(_WIN32)
// Windows v1: no fork-per-test isolation. Tests run sequentially in-process
// — a crash terminates the suite. The fork/pipe/mmap-based parallel runner
// below is gated behind !_WIN32; the Windows code path (also below) is a
// simple serial loop. A future port can layer CreateProcessW + named pipes
// + CreateFileMapping on top of the same TestRunnerCallback contract.
#define WIN32_LEAN_AND_MEAN
#include <windows.h>
// Define POSIX signal numbers Win32 doesn't have, so signalName() compiles.
#ifndef SIGBUS
#define SIGBUS  10
#endif
#ifndef SIGKILL
#define SIGKILL 9
#endif
// Stub pid_t so the existing structures compile (unused on Windows).
using pid_t = int;
#else
#include <fcntl.h>
#include <sys/mman.h>
#include <sys/wait.h>
#include <unistd.h>
#endif

namespace IsolatedTestRunner {

// ============================================================================
// Parallel Execution Constants
// ============================================================================

constexpr int MAX_PARALLEL_TESTS = 8;
constexpr int TEST_TIMEOUT_SECONDS = 60;

// Use Color from Testing namespace
namespace Color = Testing::Color;

// ============================================================================
// Shared Memory Structure for Parent-Child Communication
// ============================================================================

/**
 * Shared memory structure for parent-child communication.
 * Allocated via mmap(MAP_SHARED) before fork().
 *
 * This is the generic version without GCStats - specific test types
 * (like Elm tests) can extend this with their own shared data.
 */
struct SharedTestResult {
    bool completed;          // Child finished execution (vs crashed mid-way)
    bool passed;             // Test passed
    char error[4096];        // Error message if failed
    char output[8192];       // Test output (stdout capture)
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
    std::string output;      // Captured stdout/stderr from the test
};

/**
 * Summary of parallel test execution.
 */
struct ParallelTestSummary {
    size_t passCount = 0;
    size_t failCount = 0;
    std::vector<std::string> failedTests;
};

// ============================================================================
// Helper Functions
// ============================================================================

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
 * Read all available data from a file descriptor (non-blocking).
 * POSIX-only; the Windows test runner never spawns a child process so this
 * helper is unreachable there. Stubbed out behind _WIN32 to keep TUs that
 * include this header happy without dragging fcntl/read into MSVC.
 */
#if !defined(_WIN32)
inline std::string readAllFromFd(int fd) {
    std::string result;
    char buffer[4096];

    // Set non-blocking mode
    int flags = fcntl(fd, F_GETFL, 0);
    fcntl(fd, F_SETFL, flags | O_NONBLOCK);

    while (true) {
        ssize_t n = read(fd, buffer, sizeof(buffer));
        if (n > 0) {
            result.append(buffer, n);
        } else if (n == 0) {
            // EOF
            break;
        } else {
            // EAGAIN/EWOULDBLOCK means no more data available
            if (errno == EAGAIN || errno == EWOULDBLOCK) {
                break;
            }
            // Other error
            break;
        }
    }

    return result;
}
#else
inline std::string readAllFromFd(int /*fd*/) { return {}; }
#endif

/**
 * Print a test result atomically (name, output, and status together).
 * Uses a stringstream to build the complete output, then prints it
 * in a single write to avoid interleaving with other output.
 */
inline void printTestResult(const std::string& name,
                            const std::string& output,
                            bool passed,
                            const std::string& error) {
    std::ostringstream oss;

    // Test name in bold
    oss << "- " << Color::bold() << name << Color::reset() << "\n";

    // Include captured output (dimmed)
    if (!output.empty()) {
        oss << Color::dim() << output << Color::reset();
        if (output.back() != '\n') {
            oss << "\n";
        }
    }

    // Result status with color
    if (passed) {
        oss << Color::bold() << Color::green() << "OK" << Color::reset() << "\n";
    } else {
        oss << Color::bold() << Color::red() << "FAILED" << Color::reset()
            << ": " << Color::red() << error << Color::reset() << "\n";
    }

    // Print atomically
    std::cout << oss.str() << std::flush;
}

// ============================================================================
// SIGINT Handler for Clean Shutdown
// ============================================================================

/**
 * Global state for SIGINT handler.
 * Allows clean shutdown of all child processes on Ctrl+C.
 */
inline std::vector<pid_t>* g_activeChildren = nullptr;
inline volatile sig_atomic_t g_interrupted = 0;
#if !defined(_WIN32)
inline struct sigaction g_oldSigintAction;

/**
 * SIGINT handler that kills all active child processes.
 */
inline void parallelSigintHandler(int sig) {
    g_interrupted = 1;
    if (g_activeChildren) {
        for (pid_t pid : *g_activeChildren) {
            if (pid > 0) {
                kill(pid, SIGKILL);
            }
        }
    }
    // Don't re-raise - let the main loop handle cleanup
}
#endif

/**
 * Install our SIGINT handler, saving the old one.
 */
inline void installSigintHandler(std::vector<pid_t>* activeChildren) {
    g_activeChildren = activeChildren;
    g_interrupted = 0;
#if defined(_WIN32)
    // No-op: Win32 v1 uses the default Ctrl+C handler. The serial runner
    // terminates the process on a test crash anyway.
    return;
#else

    struct sigaction sa;
    sa.sa_handler = parallelSigintHandler;
    sigemptyset(&sa.sa_mask);
    sa.sa_flags = 0;
    sigaction(SIGINT, &sa, &g_oldSigintAction);
#endif
}

/**
 * Restore the original SIGINT handler.
 */
inline void restoreSigintHandler() {
#if defined(_WIN32)
    g_activeChildren = nullptr;
    g_interrupted = 0;
#else
    sigaction(SIGINT, &g_oldSigintAction, nullptr);
    g_activeChildren = nullptr;
    g_interrupted = 0;
#endif
}

// ============================================================================
// Test Runner Callback Type
// ============================================================================

/**
 * Callback type for running a single test.
 *
 * The callback receives the test path and should:
 * - Run the test
 * - Return normally on success
 * - Throw std::exception (or derived) on failure with error message
 *
 * The callback is executed in a forked child process, so crashes
 * are isolated and won't affect the parent.
 */
using TestRunnerCallback = std::function<void(const std::string& path)>;

/**
 * Optional callback to run after a test completes (in parent process).
 * Receives the shared memory pointer for custom data extraction.
 * Used by Elm tests to accumulate GCStats.
 */
using PostTestCallback = std::function<void(const SharedTestResult* shared)>;

// ============================================================================
// Parallel Test Context
// ============================================================================

/**
 * Context for a test being executed in parallel.
 */
struct ParallelTestContext {
    size_t index;                   // Position in discovery order
    std::string path;               // Path to test file
    std::string name;               // Test name for display
    SharedTestResult* shared;       // Shared memory for this test
    pid_t pid;                      // Child PID (0 if not started)
    int outputPipe[2];              // Pipe for capturing stdout/stderr [read, write]
    std::chrono::steady_clock::time_point startTime;
    IsolatedTestResult result;      // Result after completion
    bool completed;                 // True when result is available
    std::string capturedOutput;     // Captured stdout/stderr from child
};

// ============================================================================
// Parallel Test Execution
// ============================================================================

/**
 * Run multiple tests in parallel with up to MAX_PARALLEL_TESTS workers.
 *
 * Tests are forked in parallel and results are printed immediately as each
 * test completes (in completion order, not discovery order). Output is
 * printed atomically - each test's name and output are printed together
 * before moving to the next test.
 *
 * Features:
 * - Up to MAX_PARALLEL_TESTS concurrent child processes
 * - 60 second timeout per test
 * - Clean shutdown on SIGINT (Ctrl+C)
 * - Immediate output as tests complete
 *
 * @param testPaths List of test file paths
 * @param testNames List of test names for display (parallel to testPaths)
 * @param runTest Callback to execute a single test
 * @param postTest Optional callback to run after each test (for custom data extraction)
 * @return Summary with pass/fail counts and failed test names
 */
inline ParallelTestSummary runTestsParallel(
    const std::vector<std::string>& testPaths,
    const std::vector<std::string>& testNames,
    TestRunnerCallback runTest,
    PostTestCallback postTest = nullptr)
{
#if defined(_WIN32)
    // Windows v1: serial in-process fallback. No fork-per-test sandboxing —
    // a SIGSEGV / std::terminate inside any test kills the suite. The
    // contract for runTest is "throws std::exception on failure, returns
    // normally on success", which translates straight to try/catch here.
    ParallelTestSummary summary;
    for (size_t i = 0; i < testPaths.size(); i++) {
        std::string err;
        bool passed = true;
        try {
            runTest(testPaths[i]);
        } catch (const std::exception& e) {
            err = e.what();
            passed = false;
        } catch (...) {
            err = "non-std::exception thrown";
            passed = false;
        }
        printTestResult(testNames[i], passed ? "" : err, passed, "");
        if (passed) {
            summary.passCount++;
        } else {
            summary.failCount++;
            summary.failedTests.push_back(testNames[i]);
        }
        if (postTest) {
            // postTest expects a SharedTestResult*; on Windows we make one
            // on the stack with the result fields populated so the existing
            // accumulation paths (GCStats etc.) get the success signal.
            SharedTestResult shared{};
            shared.completed = true;
            shared.passed = passed;
            if (!err.empty()) {
                std::strncpy(shared.error, err.c_str(), sizeof(shared.error) - 1);
            }
            postTest(&shared);
        }
    }
    return summary;
#else
    const size_t numTests = testPaths.size();
    if (numTests == 0) {
        return {};
    }

    // Summary to track results
    ParallelTestSummary summary;

    // Initialize test contexts
    std::vector<ParallelTestContext> contexts(numTests);
    for (size_t i = 0; i < numTests; i++) {
        contexts[i].index = i;
        contexts[i].path = testPaths[i];
        contexts[i].name = testNames[i];
        contexts[i].shared = nullptr;
        contexts[i].pid = 0;
        contexts[i].completed = false;
    }

    // Pre-allocate shared memory for all tests
    for (auto& ctx : contexts) {
        ctx.shared = static_cast<SharedTestResult*>(mmap(
            nullptr,
            sizeof(SharedTestResult),
            PROT_READ | PROT_WRITE,
            MAP_SHARED | MAP_ANONYMOUS,
            -1, 0
        ));

        if (ctx.shared == MAP_FAILED) {
            // Clean up already allocated shared memory
            for (auto& c : contexts) {
                if (c.shared && c.shared != MAP_FAILED) {
                    munmap(c.shared, sizeof(SharedTestResult));
                }
            }
            // Print error for all tests and return
            for (const auto& name : testNames) {
                printTestResult(name, "", false, "Failed to allocate shared memory");
                summary.failCount++;
                summary.failedTests.push_back(name);
            }
            return summary;
        }
        std::memset(ctx.shared, 0, sizeof(SharedTestResult));
    }

    // Track active child PIDs for SIGINT handler
    std::vector<pid_t> activeChildren;
    std::unordered_map<pid_t, size_t> pidToIndex;

    // Install our SIGINT handler
    installSigintHandler(&activeChildren);

    size_t nextToFork = 0;      // Next test index to start
    size_t testsCompleted = 0;  // Number of tests finished

    // Main execution loop
    while (testsCompleted < numTests && !g_interrupted) {
        // Fork new tests while we have capacity
        while (activeChildren.size() < MAX_PARALLEL_TESTS &&
               nextToFork < numTests &&
               !g_interrupted) {

            auto& ctx = contexts[nextToFork];

            // Create pipe to capture child's stdout/stderr
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
                // Fork failed - close pipe
                close(ctx.outputPipe[0]);
                close(ctx.outputPipe[1]);
                ctx.result.passed = false;
                ctx.result.crashed = false;
                ctx.result.error = "Fork failed: " + std::string(strerror(errno));
                ctx.completed = true;
                testsCompleted++;
            } else if (pid == 0) {
                // ============ CHILD PROCESS ============
                // Redirect stdout and stderr to the pipe
                close(ctx.outputPipe[0]);  // Close read end
                dup2(ctx.outputPipe[1], STDOUT_FILENO);
                dup2(ctx.outputPipe[1], STDERR_FILENO);
                close(ctx.outputPipe[1]);  // Close after dup

                try {
                    runTest(ctx.path);
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

                _exit(ctx.shared->passed ? 0 : 1);
            } else {
                // ============ PARENT PROCESS ============
                close(ctx.outputPipe[1]);  // Close write end in parent
                ctx.pid = pid;
                ctx.startTime = std::chrono::steady_clock::now();
                activeChildren.push_back(pid);
                pidToIndex[pid] = nextToFork;
            }

            nextToFork++;
        }

        if (activeChildren.empty()) {
            // No active children and no more to fork
            break;
        }

        // Wait for any child to complete (non-blocking poll with short sleep)
        int status;
        pid_t finished = waitpid(-1, &status, WNOHANG);

        if (finished > 0) {
            // A child finished - find its context
            auto it = pidToIndex.find(finished);
            if (it != pidToIndex.end()) {
                size_t idx = it->second;
                auto& ctx = contexts[idx];

                // Remove from active set
                activeChildren.erase(
                    std::remove(activeChildren.begin(), activeChildren.end(), finished),
                    activeChildren.end()
                );
                pidToIndex.erase(it);

                // Read captured output from pipe
                ctx.capturedOutput = readAllFromFd(ctx.outputPipe[0]);
                close(ctx.outputPipe[0]);

                // Collect result
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

                        // Call post-test callback if provided
                        if (postTest) {
                            postTest(ctx.shared);
                        }
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

                // Print result immediately
                printTestResult(ctx.name, ctx.capturedOutput,
                                ctx.result.passed, ctx.result.error);

                // Update summary
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
            // No child finished yet - check for timeouts
            auto now = std::chrono::steady_clock::now();

            for (auto& ctx : contexts) {
                if (ctx.pid > 0 && !ctx.completed) {
                    auto elapsed = std::chrono::duration_cast<std::chrono::seconds>(
                        now - ctx.startTime).count();

                    if (elapsed >= TEST_TIMEOUT_SECONDS) {
                        // Kill the timed-out child
                        kill(ctx.pid, SIGKILL);

                        // Wait for it to be reaped
                        int status;
                        waitpid(ctx.pid, &status, 0);

                        // Read captured output and close pipe
                        ctx.capturedOutput = readAllFromFd(ctx.outputPipe[0]);
                        close(ctx.outputPipe[0]);

                        // Remove from active set
                        activeChildren.erase(
                            std::remove(activeChildren.begin(), activeChildren.end(), ctx.pid),
                            activeChildren.end()
                        );
                        pidToIndex.erase(ctx.pid);

                        // Record timeout
                        ctx.result.passed = false;
                        ctx.result.crashed = true;
                        ctx.result.error = "Test timed out after " +
                                           std::to_string(TEST_TIMEOUT_SECONDS) + " seconds";

                        // Print result immediately
                        printTestResult(ctx.name, ctx.capturedOutput,
                                        ctx.result.passed, ctx.result.error);

                        // Update summary
                        summary.failCount++;
                        summary.failedTests.push_back(ctx.name);

                        ctx.completed = true;
                        testsCompleted++;
                    }
                }
            }

            // Small sleep to avoid busy-waiting
            usleep(10000);  // 10ms
        } else if (finished == -1 && errno != ECHILD) {
            // Unexpected error
            break;
        }
    }

    // Handle interruption - kill remaining children
    if (g_interrupted) {
        for (pid_t pid : activeChildren) {
            kill(pid, SIGKILL);
            int status;
            waitpid(pid, &status, 0);
        }

        // Mark remaining tests as interrupted, print, and clean up pipes
        for (auto& ctx : contexts) {
            if (!ctx.completed) {
                // Read any output and close pipe if it was started
                if (ctx.pid > 0) {
                    ctx.capturedOutput = readAllFromFd(ctx.outputPipe[0]);
                    close(ctx.outputPipe[0]);
                }
                ctx.result.passed = false;
                ctx.result.crashed = true;
                ctx.result.error = "Test interrupted by user";

                // Print result
                printTestResult(ctx.name, ctx.capturedOutput,
                                ctx.result.passed, ctx.result.error);

                // Update summary
                summary.failCount++;
                summary.failedTests.push_back(ctx.name);

                ctx.completed = true;
            }
        }
    }

    // Restore original SIGINT handler
    restoreSigintHandler();

    // Clean up shared memory
    for (auto& ctx : contexts) {
        if (ctx.shared && ctx.shared != MAP_FAILED) {
            munmap(ctx.shared, sizeof(SharedTestResult));
        }
    }

    return summary;
#endif  // !_WIN32
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
// Parallel Test-Case Runner (no file paths)
// ============================================================================

/**
 * Run a list of in-process test functions in parallel-forked children.
 *
 * Sibling of runTestsParallel for callers that already have the test bodies
 * as std::function<void()> (e.g. Testing::TestCase) rather than file paths.
 * Each function runs in its own forked child, so a SIGSEGV/abort in one
 * test only fails that test instead of taking down the entire test binary.
 *
 * Implementation note: piggybacks on runTestsParallel by encoding each
 * test's index as the "path" string and looking it up in the closure.
 * The forked child inherits the captured vector via copy-on-write.
 */
inline ParallelTestSummary runTestCasesParallel(
    const std::vector<std::function<void()>>& testFuncs,
    const std::vector<std::string>& testNames)
{
    if (testFuncs.size() != testNames.size() || testFuncs.empty()) {
        return {};
    }

    std::vector<std::string> indices;
    indices.reserve(testFuncs.size());
    for (size_t i = 0; i < testFuncs.size(); i++) {
        indices.push_back(std::to_string(i));
    }

    auto runTest = [&testFuncs](const std::string& path) {
        size_t idx = static_cast<size_t>(std::stoul(path));
        testFuncs[idx]();
    };

    return runTestsParallel(indices, testNames, runTest);
}

// ============================================================================
// IsolatedTestCaseSuite — Test-case suite with fork-per-test isolation
// ============================================================================

/**
 * A Test container that runs each Testing::TestCase in a forked child.
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
        std::vector<std::function<void()>> funcsToRun;
        std::vector<std::string> namesToRun;
        for (size_t i = 0; i < entries_.size(); i++) {
            const std::string& n = entries_[i]->getName();
            if (filter.empty() || n.find(filter) != std::string::npos) {
                funcsToRun.push_back(funcs_[i]);
                namesToRun.push_back(n);
            }
        }

        if (funcsToRun.empty()) {
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

        auto summary = runTestCasesParallel(funcsToRun, namesToRun);
        lastPassCount_ = summary.passCount;
        lastFailCount_ = summary.failCount;
        lastFailedTests_ = summary.failedTests;
        return lastFailCount_ == 0;
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
