#pragma once

#include "../TestSuite.hpp"
#include "../../runtime/src/codegen/EcoRunner.hpp"

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

namespace CodegenTest {

// ============================================================================
// Helper Functions
// ============================================================================

/**
 * Execute a command and capture its output.
 * Returns a pair of (exit_code, output).
 * Used for non-JIT tests that need subprocess execution.
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
    return "mlir-llvm";  // Default
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
        // Look for // CHECK: patterns
        size_t pos = line.find("// CHECK:");
        if (pos != std::string::npos) {
            std::string pattern = line.substr(pos + 10);  // Skip "// CHECK: "
            // Trim leading whitespace
            size_t start = pattern.find_first_not_of(" \t");
            if (start != std::string::npos) {
                pattern = pattern.substr(start);
            }
            // Trim trailing whitespace
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

// ============================================================================
// EcoRunner-based Test Runner (In-Process)
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
 * This provides faster execution and direct output capture.
 */
inline void runJITTest(const std::string& testPath, const std::string& content) {
    auto& runner = getRunner();

    // Reset heap for test isolation
    runner.reset();

    // Run the test
    auto result = runner.runFile(testPath);

    // Extract patterns
    auto patterns = extractCheckPatterns(content);

    // Verify patterns in output
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

    // Check if test expects non-zero exit (e.g., crash.mlir, expect_fail.mlir)
    bool expectsFailure = (content.find("eco.crash") != std::string::npos) ||
                          (content.find("not %ecoc") != std::string::npos);

    if (!expectsFailure && !result.success) {
        std::ostringstream msg;
        msg << "Test failed: " << result.errorMessage << "\n";
        msg << "Output:\n" << result.output.substr(0, 500);
        throw std::runtime_error(msg.str());
    }
}

/**
 * Run a non-JIT test using subprocess (for MLIR/LLVM IR dump tests).
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

// ============================================================================
// Test Runner for a Single MLIR File
// ============================================================================

/**
 * Check if a test is expected to crash (uses eco.crash or similar).
 * Such tests must be run via subprocess to avoid killing the test runner.
 */
inline bool isExpectedCrash(const std::string& content) {
    return content.find("eco.crash") != std::string::npos ||
           content.find("not %ecoc") != std::string::npos;
}

/**
 * Run a single codegen test.
 * Uses EcoRunner for JIT tests (in-process), subprocess for others.
 * Tests that are expected to crash are always run via subprocess.
 * Throws std::runtime_error on failure.
 */
inline void runCodegenTest(const std::string& testPath) {
    // Read test file
    std::string content = readFile(testPath);

    // Check for XFAIL
    if (isExpectedFail(content)) {
        std::cout << "  (XFAIL - skipped)" << std::endl;
        return;
    }

    // Parse emit mode
    std::string emitMode = parseEmitMode(content);

    // Use in-process execution for JIT tests (unless they're expected to crash)
    // Tests with eco.crash must run via subprocess to avoid killing the test runner
    if (emitMode == "jit" && !isExpectedCrash(content)) {
        runJITTest(testPath, content);
    } else {
        runSubprocessTest(testPath, content, emitMode);
    }
}

// ============================================================================
// Test Suite Builder
// ============================================================================

/**
 * Discover all .mlir test files in the codegen test directory.
 */
inline std::vector<std::string> discoverTests(const std::string& testDir) {
    std::vector<std::string> tests;

    for (const auto& entry : std::filesystem::directory_iterator(testDir)) {
        if (entry.is_regular_file() && entry.path().extension() == ".mlir") {
            tests.push_back(entry.path().string());
        }
    }

    // Sort for consistent ordering
    std::sort(tests.begin(), tests.end());
    return tests;
}

/**
 * Create a UnitTest for a single .mlir file.
 */
inline Testing::UnitTest createCodegenTest(const std::string& testPath) {
    std::string testName = std::filesystem::path(testPath).filename().string();

    return Testing::UnitTest(
        "codegen/" + testName,
        [testPath]() {
            runCodegenTest(testPath);
        }
    );
}

/**
 * Build the complete codegen test suite.
 * Call this from main.cpp to integrate with the test framework.
 */
inline Testing::TestSuite buildCodegenTestSuite() {
    Testing::TestSuite suite("Codegen");

    // Find test directory - try common locations
    std::vector<std::string> testDirs = {
        "test/codegen",
        "../test/codegen",
        "../../test/codegen",
    };

    std::string testDir;
    for (const auto& dir : testDirs) {
        if (std::filesystem::exists(dir) && std::filesystem::is_directory(dir)) {
            testDir = dir;
            break;
        }
    }

    if (testDir.empty()) {
        std::cerr << "Warning: Could not find codegen test directory" << std::endl;
        return suite;
    }

    // Discover and add all tests
    auto testPaths = discoverTests(testDir);
    for (const auto& testPath : testPaths) {
        suite.add(createCodegenTest(testPath));
    }

    return suite;
}

/**
 * Build the codegen test suite from a specific directory.
 */
inline Testing::TestSuite buildCodegenTestSuite(const std::string& testDir) {
    Testing::TestSuite suite("Codegen");

    if (!std::filesystem::exists(testDir) || !std::filesystem::is_directory(testDir)) {
        std::cerr << "Warning: Codegen test directory not found: " << testDir << std::endl;
        return suite;
    }

    auto testPaths = discoverTests(testDir);
    for (const auto& testPath : testPaths) {
        suite.add(createCodegenTest(testPath));
    }

    return suite;
}

}  // namespace CodegenTest
