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

#include <string>

#include "llvm/Support/CodeGen.h"
#include "llvm/Support/Error.h"

namespace llvm {
class Module;
class TargetMachine;
} // namespace llvm

namespace eco {

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
