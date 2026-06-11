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

namespace eco {

class LoweringStats;

struct EcoNativeOptions {
    // LLVM optimization level (0-3). Matches the -O option on eco-boot-native.
    unsigned optLevel = 2;

    // Echo subcommand lines (link step) to stderr.
    bool verbose = false;

    // Diagnostic IR dumps. Empty = no dump.
    std::string preRS4GCDumpPath;
    std::string postRS4GCDumpPath;

    // Optional timing collector. The library appends scopes here; callers print.
    LoweringStats *stats = nullptr;
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

} // namespace eco

#endif // ECO_NATIVE_DRIVER_H
