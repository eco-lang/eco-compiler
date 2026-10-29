//===- EcoRunner.hpp - In-process execution engine for Eco MLIR -----------===//
//
// Runs a program written in Eco dialect MLIR inside the calling process, so that C++ code can run one and inspect
// what it printed and returned without starting a separate executable.
//
// An `EcoRunner` takes MLIR text, lowers it with the shared Eco-to-LLVM pass order
// (`buildEcoToLLVMPipeline`), compiles it with `EcoJIT`, and calls its `main`. The result is a `RunResult`.
//
// The compiled program runs on the process's runtime, not on a private copy of it. The heap is the one
// `Elm::Allocator` instance, the GC's stack map table is the one `Elm::globalStackMap`, and the exit code is the one
// `eco_set_exit_code` keeps. A run makes the calling thread the mutator for its duration, as
// `Elm::Allocator::initThread` describes. Two runs therefore must not overlap, from one runner or from several, and
// a run inherits whatever heap state earlier runs left unless `reset` is called between them. Only printed output is
// kept per thread: the capture functions below redirect the calling thread's print destination, which is set by
// `eco_set_output_stream`.
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

/// Starts collecting, in a buffer of the calling thread's, everything the runtime prints on that thread, instead of
/// writing it to stderr.
///
/// What counts as printed output is what `eco_set_output_stream` redirects. Any text the buffer already held is
/// discarded, and the thread's previous print destination is replaced, not saved.
void startOutputCapture();

/// Returns the calling thread's captured text and empties the buffer, and sends that thread's printed output to stderr
/// again.
///
/// Returns an empty string if `startOutputCapture` was not called on this thread since the buffer was last emptied.
std::string stopOutputCapture();

/// Returns whether the calling thread is between `startOutputCapture` and `stopOutputCapture`.
///
/// It reflects only those two functions: a destination set directly with `eco_set_output_stream` is not seen.
bool isCapturingOutput();

//===----------------------------------------------------------------------===//
// RunResult
//===----------------------------------------------------------------------===//

/// The outcome of one `EcoRunner::run` or `EcoRunner::runFile`: whether the program ran, and what it returned and
/// printed.
///
/// `success` is false when the source could not be read, parsed or lowered, the engine could not be built, or the
/// module has no `main` to call; `errorMessage` then says which. A program that calls `eco_crash` ends the
/// process instead of producing a result.
struct RunResult {
    bool success = false;
    int64_t returnValue = 0;           ///< What `main` wrote to the call's 64-bit result slot; 0 unless `success`.
    int exitCode = 0;                  ///< The exit code the program recorded, or 0; 0 unless `success`.
    std::string output;                ///< What this thread printed in `main` if `Options::captureOutput`; else empty.
    std::string errorMessage;          ///< Empty when `success`.

    /// Returns `success`.
    explicit operator bool() const { return success; }
};

//===----------------------------------------------------------------------===//
// EcoRunner
//===----------------------------------------------------------------------===//

/// A reusable driver that compiles Eco dialect MLIR and runs its `main` in this process.
///
/// Each run is independent at the compiler level: it parses into a fresh MLIR context and builds a fresh engine,
/// which is destroyed when the run returns. At the runtime level it is not, as the file comment says: runs share
/// the process heap, stack map table and exit code, must not overlap, and are isolated from one another only by
/// `reset`.
///
/// Constructing a runner initializes LLVM's native target, once per process, and outside Windows sets `SIGPIPE`
/// to be ignored for the whole process, so that a write to a closed pipe fails with an error instead of killing it.
///
/// A runner can be moved but not copied. A moved-from runner may only be assigned to or destroyed; `run` and
/// `runFile` on it dereference a null pointer.
///
/// @code
///     EcoRunner runner;
///     runner.reset();
///     auto result = runner.runFile("test.mlir");
///     if (result.success) {
///         // Check result.output, result.returnValue
///     }
/// @endcode
class EcoRunner {
public:
    /// The settings a runner applies to each run.
    struct Options {
        bool enableOpt = false;        ///< Compiles at LLVM's aggressive optimization level instead of none.
        bool captureOutput = true;     ///< Collects what `main` prints into `RunResult::output`.

        /// Creates the defaults: no optimization, output captured.
        Options() = default;
    };

    /// Creates a runner with the default `Options`.
    EcoRunner();
    /// Creates a runner that applies `options` to each run.
    explicit EcoRunner(const Options& options);
    ~EcoRunner();

    EcoRunner(const EcoRunner&) = delete;
    EcoRunner& operator=(const EcoRunner&) = delete;
    EcoRunner(EcoRunner&&) noexcept;
    EcoRunner& operator=(EcoRunner&&) noexcept;

    /// Discards the process heap and every thread's heap, and reconfigures the allocator with the configuration the
    /// environment gives: the defaults, overridden by `$ECO_HEAP_CONFIG` and the `ECO_GC_*` and `ECO_NURSERY_*`
    /// variables, as `Elm::Allocator::environmentConfig` describes.
    ///
    /// It affects the whole process, not only this runner, and must not be called while a run is in progress.
    /// Applying the environment's configuration, rather than keeping the current one, means that a run after
    /// `reset` sees the configuration a standalone program would, whatever some other code installed before.
    /// Throws what `Elm::Allocator::environmentConfig` throws for an invalid configuration.
    void reset();

    /// Parses `source` as an MLIR module, lowers and compiles it, and calls its `main` on the calling thread.
    ///
    /// `main` must take no arguments and return nothing wider than 64 bits; nothing checks this. Before calling it,
    /// the run initializes the allocator if nothing has, makes the calling thread the mutator, registers the
    /// kernel's GC roots and effect managers, calls `__eco_init_globals` if the module defines it, loads the
    /// compiled code's stack maps into `Elm::globalStackMap` (replacing what was there) when it has any, and sets
    /// the exit code to 0 so that a code recorded by an earlier run does not show through. Once the call to `main`
    /// returns, with or without an error, the calling thread's heap is destroyed.
    RunResult run(const std::string& source);

    /// Reads the file at `filePath` and runs its contents as `run` does. A file that cannot be read gives a
    /// result with `success` false.
    RunResult runFile(const std::string& filePath);

    /// Replaces the options applied to later runs.
    void setOptions(const Options& options) { options_ = options; }

    /// Returns the options applied to each run. The reference is valid until the runner is destroyed.
    const Options& getOptions() const { return options_; }

private:
    class Impl;
    std::unique_ptr<Impl> impl_;
    Options options_;
};

} // namespace eco

#endif // ECO_RUNNER_HPP
