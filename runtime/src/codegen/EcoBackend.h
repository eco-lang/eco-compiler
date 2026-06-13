//===- EcoBackend.h - Shared Eco LLVM backend helpers ---------------------===//
//
// Shared RS4GC + frame-pointer utilities and backend driver types.
//
// Used by:
//   - ecoc (CLI compiler / IR dumper / JIT)
//   - eco-boot (AOT bootstrap compiler)
//   - EcoRunner / EcoJIT (in-process JIT for tests)
//
//===----------------------------------------------------------------------===//

#ifndef ECO_BACKEND_H
#define ECO_BACKEND_H

#include <memory>
#include <string>

#include "llvm/Support/CodeGen.h"
#include "llvm/Support/Error.h"

namespace llvm {
class Module;
class TargetMachine;
} // namespace llvm

namespace eco {

//===----------------------------------------------------------------------===//
// Target machine configuration
//
// Single source of truth for the CPU / feature level eco's AOT native backend
// targets. Consumed by eco-boot.cpp and EcoNativeDriver.cpp (and any future
// AOT path) so the setting lives in exactly one place.
//===----------------------------------------------------------------------===//

/// Microarchitecture level for every native binary eco emits — its own
/// bootstrapped self (compiler/CMakeLists.txt stages 6–9) and user `eco make`
/// output alike.
///
/// Pinned per platform for portable, reproducible output:
///   - x86-64 (Linux / Darwin): x86-64-v3 — SSE4.2 + AVX2 + BMI2 + FMA, no
///     AVX-512. Deliberately NOT host detection: deriving the target from
///     llvm::sys::getHostCPUName()/getHostCPUFeatures() baked the build host's
///     ISA — including AVX-512 — into every emitted binary, so binaries
///     bootstrapped on an AVX-512 machine SIGILL'd on plain x86-64-v3 CPUs.
///     Keep in lockstep with the clang `-march=x86-64-v3` flag in
///     CMakePresets.json and docker/llvm-alpine.Dockerfile.
///   - aarch64 (Darwin arm64 / Apple Silicon): apple-m1 — the minimum CPU
///     for the OS-supported Apple Silicon family. Passing x86-64-v3 through
///     to LLVM on this target emits the "'x86-64-v3' is not a recognized
///     processor for this target (ignoring processor)" warning and falls
///     back to generic; pinning to apple-m1 avoids that and gets us the
///     NEON+CRC+AES baseline of the M-series chips.
#if defined(__aarch64__) || defined(__arm64__)
inline constexpr const char *kEcoTargetCPU = "apple-m1";
#else
inline constexpr const char *kEcoTargetCPU = "x86-64-v3";
#endif

/// Extra subtarget features appended to kEcoTargetCPU. Empty by design: the v3
/// level already implies the desired feature set and we add nothing
/// host-specific.
inline constexpr const char *kEcoTargetFeatures = "";

/// Create the LLVM TargetMachine used for AOT object emission, pinned to
/// kEcoTargetCPU / kEcoTargetFeatures. Sets `module`'s target triple and data
/// layout. `optLevel` is clamped to [0,3] and maps to the CodeGen opt level
/// (load-bearing for -O0..-O3 AOT codegen). Returns nullptr after printing a
/// diagnostic to llvm::errs() on failure.
std::unique_ptr<llvm::TargetMachine>
createEcoTargetMachine(llvm::Module &module, unsigned optLevel);

/// Options for running RS4GC and (optionally) forcing frame pointers.
struct RS4GCOptions {
    /// Dump LLVM IR before RS4GC if non-empty (eco-boot --dump-pre-rs4gc-ir).
    std::string preDumpPath;

    /// Dump LLVM IR after RS4GC if non-empty (ecoc/eco-boot --dump-rs4gc-ir).
    std::string postDumpPath;

    /// If true, add `frame-pointer=all` to every non-declaration function so
    /// libunwind can walk JIT/AOT frames during GC root discovery.
    bool addFramePointerAttr = false;
};

/// Run Eco's RS4GC pipeline (`addEcoGCPipeline`) over the module, with
/// optional pre/post IR dumps and frame-pointer attribute injection.
///
/// Centralises the RS4GC + FP logic previously duplicated in ecoc.cpp,
/// eco-boot.cpp, and EcoRunner.cpp.
void runRS4GCAndMaybeFramePointers(llvm::Module &m,
                                   const RS4GCOptions &opts);

/// What flavour of backend work `runEcoBackend` should perform.
enum class BackendKind {
    /// Run RS4GC + optional FP; caller handles text-IR printing.
    DumpLLVMText,

    /// Run RS4GC + optional FP; caller currently still owns opt + emit.
    /// Phase 3.3 expands this to drive opt + object emission + exe link.
    EmitObjectFile,

    /// JIT consumer: RS4GC + FP + `makeOptimizingTransformer` against the
    /// module's TargetMachine. Wired in Phase 4 — `runEcoBackend` returns
    /// `llvm_unreachable` for this kind before Phase 4 lands.
    JITInvokePacked,
};

/// Backend job descriptor. Currently a thin façade over
/// `runRS4GCAndMaybeFramePointers`; gains opt/emit/link fields in Phase 3.3
/// and JIT-specific fields in Phase 4.
struct EcoBackendJob {
    BackendKind kind = BackendKind::DumpLLVMText;

    /// Target machine. Required for `EmitObjectFile` and `JITInvokePacked`
    /// once those phases land; may be null for `DumpLLVMText`.
    llvm::TargetMachine *tm = nullptr;

    /// Requested LLVM codegen optimisation level.
    llvm::CodeGenOptLevel optLevel = llvm::CodeGenOptLevel::None;

    /// If true, add `frame-pointer=all` to every non-declaration function.
    bool needsFramePointerAttr = false;

    /// Optional pre/post RS4GC IR dumps.
    std::string preRS4GCDumpPath;
    std::string postRS4GCDumpPath;

    /// Output path for object file emission. Required for `EmitObjectFile`
    /// when actual emission is desired; if empty, `runEcoBackend` runs
    /// RS4GC + opt but does not emit (used by intermediate-state callers).
    std::string objectFilePath;
};

/// Run the Eco backend on an LLVM module according to `job`.
///
/// Phase 2 implementation is a thin wrapper over `runRS4GCAndMaybeFramePointers`.
/// `DumpLLVMText` and `EmitObjectFile` return success after RS4GC + FP;
/// emission and optimisation remain at the call site until Phase 3.3.
/// `JITInvokePacked` is reserved for Phase 4 and is not yet exposed.
llvm::Error runEcoBackend(llvm::Module &m, const EcoBackendJob &job);

} // namespace eco

#endif // ECO_BACKEND_H
