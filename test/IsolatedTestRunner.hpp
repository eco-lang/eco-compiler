#pragma once

#include "TestSuite.hpp"

#include <algorithm>
#include <chrono>
#include <csignal>
#include <cstring>
#include <fcntl.h>
#include <functional>
#include <iostream>
#include <sstream>
#include <string>
#include <sys/mman.h>
#include <sys/wait.h>
#include <unistd.h>
#include <unordered_map>
#include <vector>

namespace IsolatedTestRunner {

// ============================================================================
// Parallel Execution Constants
// ============================================================================

constexpr int MAX_PARALLEL_TESTS = 8;
constexpr int TEST_TIMEOUT_SECONDS = 60;

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
 */
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
    oss << "- " << name << "\n";

    // Include captured output
    if (!output.empty()) {
        oss << output;
        if (output.back() != '\n') {
            oss << "\n";
        }
    }

    if (passed) {
        oss << "OK\n";
    } else {
        oss << "FAILED: " << error << "\n";
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

/**
 * Install our SIGINT handler, saving the old one.
 */
inline void installSigintHandler(std::vector<pid_t>* activeChildren) {
    g_activeChildren = activeChildren;
    g_interrupted = 0;

    struct sigaction sa;
    sa.sa_handler = parallelSigintHandler;
    sigemptyset(&sa.sa_mask);
    sa.sa_flags = 0;
    sigaction(SIGINT, &sa, &g_oldSigintAction);
}

/**
 * Restore the original SIGINT handler.
 */
inline void restoreSigintHandler() {
    sigaction(SIGINT, &g_oldSigintAction, nullptr);
    g_activeChildren = nullptr;
    g_interrupted = 0;
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

}  // namespace IsolatedTestRunner
