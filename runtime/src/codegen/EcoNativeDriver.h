//===- EcoNativeDriver.h - Library API for MLIR-to-ELF lowering ----------===//
//
// Extracted from eco-boot.cpp so the same pipeline can be used by:
//   1. eco-boot-native binary (CLI tool)
//   2. The unified `eco` binary (via the Eco_Kernel_NativeDriver_lowerAndLink
//      kernel intrinsic, which forwards through EcoNativeAPI.h)
//
// The library does not own LLVM target init, MLIR context creation, or stats
// printing — callers handle those, then call compileMlirFileToExecutable() to
// run the pipeline.
//
//===----------------------------------------------------------------------===//

#ifndef ECO_NATIVE_DRIVER_H
#define ECO_NATIVE_DRIVER_H

#include <string>
#include <vector>

namespace eco {

class LoweringStats;

struct EcoNativeOptions {
    // LLVM optimization level (0-3). Matches the -O option on eco-boot-native.
    unsigned optLevel = 2;

    // Parallel object-emission partition policy (executable output only):
    // 0 = auto (min(cores,16), gated >= 4000 fns), 1 = off, N = explicit.
    // Decided in the shared backend (choosePartitionCount). Auto by default so
    // the unified `eco` path — which builds a default EcoNativeOptions in the C
    // ABI entry points — gets the parallel-emission win without Elm changes.
    unsigned splitCodegen = 0;

    // Parallel-optimization tier (executable output only), mapped to
    // eco::ParallelOpt in the driver: 0 = none (whole-module -O2 then
    // codegen-only split — default), 1 = dev (no-inline per-partition), 2 = cgu
    // (full -O2 per partition). Kept as unsigned so this header stays LLVM-free.
    unsigned parallelOpt = 0;

    // Echo subcommand lines (link step) to stderr.
    bool verbose = false;

    // Diagnostic IR dumps. Empty = no dump.
    std::string preRS4GCDumpPath;
    std::string postRS4GCDumpPath;

    // Root module name baked into the program as the `__eco_root_module`
    // symbol. The N-API addon (eco_node_addon.cpp) reads it to name the
    // `Elm.<RootModule>` export so host JS uses the same module path as the
    // JS target. Empty = omit the symbol; the addon falls back to "Main".
    std::string rootModule;

    // Optional timing collector. The library appends scopes here; callers print.
    LoweringStats *stats = nullptr;

    // Opt-in: add `--gc-sections` to the executable link (Linux only) to trim
    // dead sections from the linked runtime/kernel archives. Requires the
    // .llvm_stackmaps section to be explicitly KEEP'd (done automatically when
    // this is set) — nothing relocates into it, so a plain --gc-sections would
    // strip it and silently break GC root scanning. Binary-size win only (does
    // not speed compilation); OFF by default until broadly validated.
    bool gcSections = false;
};

// Initialize the native LLVM target + asm printer + asm parser. Idempotent
// across calls; safe to invoke from main() of a host that already did this.
void initializeLLVMNativeTarget();

// MLIR text file → linked ELF executable. Returns 0 on success, nonzero on
// failure (with diagnostics on stderr). Steps:
//   1. Parse MLIR with the Eco dialect registry.
//   2. Run the Eco→LLVM pass pipeline.
//   3. Translate to LLVM IR (with main→eco_main rename).
//   4. Create TargetMachine, run RS4GC + opt + object emission.
//   5. Link via clang++ driver with the runtime/kernel static libraries.
int compileMlirFileToExecutable(const std::string &mlirPath,
                                const std::string &outputPath,
                                const EcoNativeOptions &opts);

// MLIR text in memory → linked ELF executable. Phase 2 entry point — used by
// the unified `eco` binary's in-memory MLIR transport. Same pipeline as the
// file variant, just sourced from a buffer.
int compileMlirBytesToExecutable(const char *mlirBytes, size_t mlirLen,
                                  const std::string &outputPath,
                                  const EcoNativeOptions &opts);

// Link an already-emitted object file into an ELF executable. Exposed so the
// eco-boot-native `--emit=obj` + re-link fast path can reuse the link step.
// sharedLib: link a shared library (-shared, embed entry, no main())
// instead of a PIE executable. Used for .so/.node output targets.
int linkExecutable(const std::string &objectFile,
                   const std::string &outputPath,
                   const EcoNativeOptions &opts,
                   bool sharedLib = false);

// Multi-object variant: link N object files (one per parallel-codegen
// partition — see EcoBackendJob::splitCodegen) into one executable/shared lib.
int linkExecutable(const std::vector<std::string> &objectFiles,
                   const std::string &outputPath,
                   const EcoNativeOptions &opts,
                   bool sharedLib = false);

} // namespace eco

#endif // ECO_NATIVE_DRIVER_H
