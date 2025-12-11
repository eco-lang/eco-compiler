//===- EcoRunner.hpp - In-process execution engine for Eco MLIR -----------===//
//
// This file declares the EcoRunner API for running Eco dialect MLIR code
// directly within a test process. It reuses the lowering pipeline from ecoc
// but provides programmatic control and output capture.
//
//===----------------------------------------------------------------------===//

#ifndef ECO_RUNNER_HPP
#define ECO_RUNNER_HPP

#include <cstdint>
#include <functional>
#include <memory>
#include <optional>
#include <string>
#include <vector>

namespace eco {

//===----------------------------------------------------------------------===//
// Output Capture API
//===----------------------------------------------------------------------===//

/// Starts capturing eco_dbg_print output for the current thread.
/// All subsequent eco_dbg_print calls will append to an internal buffer
/// instead of writing to stderr.
void startOutputCapture();

/// Stops capturing and returns all captured output.
/// Clears the internal buffer.
std::string stopOutputCapture();

/// Returns true if output capture is currently active for this thread.
bool isCapturingOutput();

//===----------------------------------------------------------------------===//
// RunResult
//===----------------------------------------------------------------------===//

/// Result of running an Eco program.
struct RunResult {
    bool success = false;              ///< True if execution completed without errors
    int64_t returnValue = 0;           ///< Return value from main()
    std::string output;                ///< Captured eco.dbg output
    std::string errorMessage;          ///< Error message if !success

    /// Returns true if this result represents a successful execution.
    explicit operator bool() const { return success; }
};

//===----------------------------------------------------------------------===//
// EcoRunner
//===----------------------------------------------------------------------===//

/// In-process execution engine for Eco dialect MLIR.
///
/// This class provides the ability to parse, lower, and JIT-execute Eco MLIR
/// code directly within a test process, enabling:
///   - Direct access to execution output
///   - Integration with C++ test frameworks
///   - Faster test execution (no subprocess overhead)
///
/// Usage:
/// @code
///     EcoRunner runner;
///     runner.reset();  // Reset heap for isolation
///     auto result = runner.runFile("test.mlir");
///     if (result.success) {
///         // Check result.output, result.returnValue
///     }
/// @endcode
///
/// Thread Safety:
///   - Each test should call reset() before running to ensure isolation
///   - Output capture is thread-local
///
class EcoRunner {
public:
    /// Configuration options for the runner.
    struct Options {
        bool enableOpt = false;        ///< Enable LLVM optimizations
        bool captureOutput = true;     ///< Capture eco.dbg output

        Options() = default;
    };

    EcoRunner();
    explicit EcoRunner(const Options& options);
    ~EcoRunner();

    // Non-copyable, movable
    EcoRunner(const EcoRunner&) = delete;
    EcoRunner& operator=(const EcoRunner&) = delete;
    EcoRunner(EcoRunner&&) noexcept;
    EcoRunner& operator=(EcoRunner&&) noexcept;

    /// Resets the heap and GC state for test isolation.
    /// Should be called before each test to ensure clean state.
    void reset();

    /// Runs MLIR source code.
    /// @param source MLIR source code string
    /// @return Result containing success status, return value, and output
    RunResult run(const std::string& source);

    /// Runs MLIR from a file.
    /// @param filePath Path to the .mlir file
    /// @return Result containing success status, return value, and output
    RunResult runFile(const std::string& filePath);

    /// Sets the options for this runner.
    void setOptions(const Options& options) { options_ = options; }

    /// Returns the current options.
    const Options& getOptions() const { return options_; }

private:
    class Impl;
    std::unique_ptr<Impl> impl_;
    Options options_;
};

} // namespace eco

#endif // ECO_RUNNER_HPP
