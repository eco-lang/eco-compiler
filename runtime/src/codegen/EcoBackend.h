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
#include <vector>

#include "llvm/Support/CodeGen.h"
#include "llvm/Support/Error.h"

namespace llvm {
class Module;
class TargetMachine;
} // namespace llvm

namespace eco {

class LoweringStats;

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

/// Parallel-optimization tier for `EmitObjectFile` (executable output).
/// See design_docs/backend-parallel-optimization.md and
/// plans/parallel-llvm-opt-partitioning.md.
enum class ParallelOpt {
    /// Today's behaviour: whole-module `-O2` (serial), then codegen-only split.
    None,
    /// Dev/fast: cheap whole-module IPO prologue, then split, then a NO-INLINE
    /// per-partition function-simplification pipeline in parallel. Fast compile,
    /// lower-quality output (for iteration builds — never the shipped compiler).
    Dev,
    /// Release: cheap whole-module IPO prologue, then split, then FULL `-O2`
    /// per partition in parallel (keeps intra-partition inlining). Parallel
    /// compile, near-full quality. (Cross-partition inlining recovery — replica
    /// sets — is a later refinement; see Phase 4.)
    Cgu,
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

    /// Parallel object emission policy request (executable output only):
    ///   0 = auto (cores, gated at >= 4000 defined fns, ~1 part/2000),
    ///   1 = off (single-threaded emit to `objectFilePath`),
    ///   N = explicit partition count.
    /// The actual count is decided inside `runEcoBackend` via
    /// `choosePartitionCount`, which also mints any extra temp object files it
    /// needs and reports the produced set back through `EcoBackendResult`. This
    /// keeps the partition policy in the shared backend rather than each driver
    /// (see design_docs/backend-parallel-optimization.md §8.1).
    unsigned splitCodegen = 1;

    /// True only for plain executable output (not `-c`/.o, not .so/.node). The
    /// caller already computes this for `internalizeAndDCEForExecutable`.
    /// Splitting is gated on this: shared libs / object-only output never split.
    bool splitEligible = false;

    /// Parallel-optimization tier. `None` (default) keeps whole-module `-O2`
    /// then codegen-only split. `Dev`/`Cgu` move optimization into the
    /// per-partition workers (see ParallelOpt). Only honoured for
    /// `EmitObjectFile` with `optLevel != None` and `splitEligible`.
    ParallelOpt parallelOpt = ParallelOpt::None;

    /// Dev-tier only: override the CodeGen opt level used to CREATE each split
    /// worker's TargetMachine (object emission). `~0u` = follow `optLevel`.
    /// 0=None(FastISel/RegAllocFast), 1=Less, 2=Default. Only honoured on the
    /// per-partition split workers under ParallelOpt::Dev; the single-object
    /// inline path uses the driver-supplied `tm` and is unaffected.
    unsigned devEmitCodeGenLevel = ~0u;

    /// Dev-tier only: run the no-inline per-partition simplification pipeline
    /// at OptimizationLevel::O1 instead of the `optLevel`-derived level.
    bool devOptO1 = false;

    /// Optional timing collector for backend sub-phases (RS4GC, opt prologue,
    /// module split + bitcode serialization, parallel opt+emit region). Null =
    /// no recording. Thread-safe (LoweringStats::record is mutex-guarded), so
    /// per-partition workers may record too.
    LoweringStats *stats = nullptr;

    /// Use the lazy per-worker module extraction instead of llvm::SplitModule:
    /// externalize + serialize the whole module ONCE, then each worker
    /// lazy-loads the shared bitcode and materializes only its ~1/N functions
    /// (the ThinLTO-importer pattern). Collapses the serial N-clone + N-serialize
    /// cost of SplitModule to a single serialization. Only affects the
    /// partitioned `EmitObjectFile` path (numParts > 1); output is functionally
    /// equivalent to the SplitModule path.
    bool lazySplit = false;

    /// EXPERIMENTAL, off by default. Run RewriteStatepointsForGC AFTER the O2
    /// optimization pipeline instead of before it (upstream LLVM's intended
    /// ordering: the optimizer operates on abstract `ptr addrspace(1)` before
    /// statepoints exist). This lets O2 run faster (no statepoint plumbing to
    /// grind through) and can improve code quality, but risks REP_LLVM_001(a):
    /// opt may hoist a `ptrtoint ptr<1>->i64` (ADT tag extraction) across a
    /// to-be-statepoint call, leaving a stale tag after a collection. The
    /// release safety net (EcoPtrIntVerify) does not catch this, so this stays
    /// opt-in until validated under ECO_LOWERING_VALIDATION + GC stress. Only
    /// honoured for BackendKind::EmitObjectFile. The bundled SROA/FoldExtract
    /// light-cleanup and frame-pointer injection move with RS4GC automatically.
    bool rs4gcAfterOpt = false;
};

/// Result of an `EmitObjectFile` backend run: the object files that were
/// produced (to be handed to `linkExecutable`) and, separately, the subset the
/// backend itself created as temporaries (to be removed by the caller after
/// linking). For single-object output `objectFiles == { job.objectFilePath }`
/// and `ownedTempFiles` is empty (the caller owns that path's lifecycle).
struct EcoBackendResult {
    std::vector<std::string> objectFiles;
    std::vector<std::string> ownedTempFiles;
};

/// Run the Eco backend on an LLVM module according to `job`.
///
/// For `EmitObjectFile` this drives RS4GC + opt + (optionally partitioned)
/// object emission. When `job.splitEligible` and the partition policy
/// (`job.splitCodegen`) select N > 1 partitions, the module is split N ways
/// (llvm::SplitModule) and each part emitted on its own thread; the backend
/// uses `job.objectFilePath` as the first part and mints N-1 extra temp object
/// files, reporting the full set through `result`. `result` may be null for
/// callers that do not emit objects (`DumpLLVMText`, `JITInvokePacked`).
llvm::Error runEcoBackend(llvm::Module &m, const EcoBackendJob &job,
                          EcoBackendResult *result = nullptr);

/// Internalize + GlobalDCE for EXECUTABLE output only. Marks every generated
/// global internal EXCEPT the two symbols the C entry lib resolves by name
/// (`eco_main`, `__eco_init_globals`), then runs GlobalDCE so unreachable
/// generated functions/globals are dropped before RS4GC + opt + codegen see
/// them. Internal linkage also lets the optimizer/codegen treat all Elm code
/// as non-preemptible (better inlining, no PLT/GOT for internal calls).
///
/// MUST NOT be used for shared-library / .node output or for object-only
/// (`-c`) output: those need `__eco_root_module` / `napi_register_module_v1`
/// / `eco_app_*` to stay externally visible. Caller gates on
/// `!sharedLib && !emitObjOnly`. Must run BEFORE RS4GC so statepoints and the
/// stackmap only cover live functions.
void internalizeAndDCEForExecutable(llvm::Module &m);

} // namespace eco

#endif // ECO_BACKEND_H
