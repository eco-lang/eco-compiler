Below is a concrete, implementation‑ready design for converging the pipelines, organized along the phased plan we discussed. It tells you:
- Which files to create/modify.
- Exactly what structs/functions to add.
- Where to call them from each tool.
- How to sequence the work so tests keep passing as much as possible.

I’ll assume code lives under `runtime/src/codegen/` for backend logic, and the existing tools are:

- `runtime/src/codegen/ecoc.cpp` (CLI / IR dump / JIT)   
- `runtime/src/codegen/EcoRunner.cpp` (test JIT / EcoRunner)   
- `runtime/src/codegen/eco-boot.cpp` (bootstrap AOT compiler)   
- `runtime/src/codegen/EcoJIT.h/.cpp` (JIT engine, already provides `setupTargetTripleAndDataLayout`)   

The phases match the `converge-pipelines.md` plan that’s already in your repo.
---
## 0. Ground rules and invariants

Before touching code, cement these invariants in comments / doc (you already have them in converge-pipelines; I’d also put a short version in `EcoBackend.h`):
- All backends (ecoc, eco-boot, EcoRunner/EcoJIT) share:
  - The same RS4GC pipeline `addEcoGCPipeline` (already true structurally).   
  - The same “force `frame-pointer=all`” policy for any native execution (JIT + eco-boot), but not for pure IR dump.
- DataLayout will eventually be set **immediately after MLIR→LLVM translation**, before RS4GC, for all tools; but we’ll flip that ordering tool‑by‑tool later.

You’ve already verified everything passes under today’s split pipelines; that SHA is your rollback point.
---
## 1. Phase 1 – Centralize RS4GC + frame-pointer (no behavior change)
### 1.1 Create `runtime/src/codegen/EcoBackend.h`

New header to hold shared backend helpers:
```cpp
//===- EcoBackend.h - Shared Eco LLVM backend helpers ---------------------===//
//
// Shared RS4GC + frame-pointer utilities and backend driver types.
//
// Used by:
//   - ecoc (CLI compiler / IR dumper)
//   - eco-boot (AOT bootstrap compiler)
//   - EcoRunner / EcoJIT (in-process JIT for tests)
//
//===----------------------------------------------------------------------===//

#ifndef ECO_BACKEND_H
#define ECO_BACKEND_H

#include <string>

namespace llvm {
class Module;
class TargetMachine;
enum CodeGenOptLevel : int;
} // namespace llvm

namespace eco {

/// Configuration for running RS4GC and (optionally) forcing frame pointers.
struct RS4GCOptions {
    /// Dump IR before RS4GC if non-empty (eco-boot --dump-pre-rs4gc-ir).
    std::string preDumpPath;

    /// Dump IR after RS4GC if non-empty (ecoc/eco-boot --dump-rs4gc-ir).
    std::string postDumpPath;

    /// If true, add "frame-pointer=all" to all non-declaration functions.
    bool addFramePointerAttr = false;
};

/// Run Eco's RS4GC pipeline (addEcoGCPipeline) over the module, with
/// optional pre/post dumps and frame-pointer attributes.
///
/// This is a pure refactor of the RS4GC+FP code currently duplicated in:
///   - ecoc.cpp::dumpLLVMIR
///   - eco-boot.cpp (LLVM RS4GC pipeline + FP loop)
///   - EcoRunner.cpp (JIT transformer)
void runRS4GCAndMaybeFramePointers(llvm::Module &m,
                                   const RS4GCOptions &opts);

} // namespace eco

#endif // ECO_BACKEND_H
```
### 1.2 Create `runtime/src/codegen/EcoBackend.cpp`

Implementation: copy the existing RS4GC scaffold into a single helper. The body mirrors what you have in `ecoc.cpp`, `eco-boot.cpp` and `EcoRunner.cpp` for RS4GC and the FP loop.
```cpp
//===- EcoBackend.cpp - Shared Eco LLVM backend helpers -------------------===//

#include "EcoBackend.h"
#include "EcoPtrIntVerify.h"   // for addEcoGCPipeline
#include "llvm/IR/Module.h"
#include "llvm/IR/Function.h"
#include "llvm/IR/LLVMContext.h"
#include "llvm/Passes/PassBuilder.h"
#include "llvm/Support/raw_ostream.h"
#include "llvm/Support/FileSystem.h"

using namespace llvm;

namespace eco {

void runRS4GCAndMaybeFramePointers(Module &m, const RS4GCOptions &opts) {
    // Optional pre-RS4GC dump.
    if (!opts.preDumpPath.empty()) {
        std::error_code ec;
        raw_fd_ostream out(opts.preDumpPath, ec, sys::fs::OF_Text);
        if (!ec) {
            out << m;
            errs() << "[pre-rs4gc] Dumped pre-RS4GC IR to "
                   << opts.preDumpPath << "\n";
        } else {
            errs() << "[pre-rs4gc] Error: could not open "
                   << opts.preDumpPath << ": " << ec.message() << "\n";
        }
    }

    // RS4GC pipeline: identical to existing call sites.
    LoopAnalysisManager LAM;
    FunctionAnalysisManager FAM;
    CGSCCAnalysisManager CGAM;
    ModuleAnalysisManager MAM;
    PassBuilder PB;
    PB.registerModuleAnalyses(MAM);
    PB.registerCGSCCAnalyses(CGAM);
    PB.registerFunctionAnalyses(FAM);
    PB.registerLoopAnalyses(LAM);
    PB.crossRegisterProxies(LAM, FAM, CGAM, MAM);

    ModulePassManager MPM;
    addEcoGCPipeline(MPM);
    MPM.run(m, MAM);

    // Optional post-RS4GC dump.
    if (!opts.postDumpPath.empty()) {
        std::error_code ec;
        raw_fd_ostream out(opts.postDumpPath, ec, sys::fs::OF_Text);
        if (!ec) {
            out << m;
            errs() << "[rs4gc] Dumped post-RS4GC IR to "
                   << opts.postDumpPath << "\n";
        } else {
            errs() << "[rs4gc] Error: could not open "
                   << opts.postDumpPath << ": " << ec.message() << "\n";
        }
    }

    // Optional frame-pointer attribute injection.
    if (opts.addFramePointerAttr) {
        for (Function &F : m) {
            if (!F.isDeclaration())
                F.addFnAttr("frame-pointer", "all");
        }
    }
}

} // namespace eco
```

Add `EcoBackend.cpp` to the `ecoc` target in `runtime/src/codegen/CMakeLists.txt` (and any other target that needs it):
```cmake
add_llvm_executable(ecoc
    ecoc.cpp
    EcoPipeline.cpp
    EcoBackend.cpp       # NEW
    RuntimeSymbols.cpp
    ../jit/EcoJIT.cpp
    ...
)
```

Similarly, ensure `eco-boot` and any other backend tool link `EcoBackend.o`.
### 1.3 Wire callers to use `runRS4GCAndMaybeFramePointers`
#### 1.3.1 `ecoc.cpp::dumpLLVMIR`

Current code (simplified) runs RS4GC and then optionally dumps IR:
```cpp
// Convert MLIR -> LLVM IR ...
auto llvmModule = translateModuleToLLVMIR(...);

// Run RS4GC...
{
    LoopAnalysisManager LAM;
    ...
    ModulePassManager MPM;
    eco::addEcoGCPipeline(MPM);
    MPM.run(*llvmModule, MAM);
}

// Optionally dump LLVM IR after RS4GC ...
if (!dumpRS4GCIR.empty()) { ... }

// Init target, create TM, set DL, opt, print.
```

Replace the RS4GC block and the explicit post‑dump with a call to the shared helper:
```cpp
#include "EcoBackend.h"  // at top

static int dumpLLVMIR(ModuleOp module) {
    ...
    auto llvmModule = translateModuleToLLVMIR(module, llvmContext);
    if (!llvmModule) { ... }

    // Run RS4GC + optional dump, no frame-pointer attributes for pure IR dump.
    eco::RS4GCOptions rs4gcOpts;
    rs4gcOpts.postDumpPath = dumpRS4GCIR;
    rs4gcOpts.addFramePointerAttr = false;
    eco::runRS4GCAndMaybeFramePointers(*llvmModule, rs4gcOpts);

    // Remainder (target init, DL, opt, print) unchanged for Phase 1.
    ...
}
```

This preserves ordering (RS4GC still runs before DL is set) but deduplicates the logic.
#### 1.3.2 `eco-boot.cpp`: RS4GC + dumps + FP loop

Current sequence:
- Optional pre‑RS4GC dump.
- RS4GC pass pipeline.
- Optional post‑RS4GC dump.
- Later: create TargetMachine → opt → frame‑pointer loop → emit. 

Replace that whole RS4GC + FP code with a helper call:
```cpp
#include "EcoBackend.h" // at top

...

// After MLIR -> LLVM IR translation:
llvmModule = translateToLLVMIR(*module, llvmContext);
if (!llvmModule) { ... }

// Replace the hand-coded RS4GC + dumps + FP with:
eco::RS4GCOptions rs4gcOpts;
rs4gcOpts.preDumpPath  = dumpPreRS4GCIR;
rs4gcOpts.postDumpPath = dumpRS4GCIR;
rs4gcOpts.addFramePointerAttr = true;
{
    eco::LoweringStats::Scope scope(stats, "LLVM RS4GC pipeline");
    eco::runRS4GCAndMaybeFramePointers(*llvmModule, rs4gcOpts);
}

// Remove the old RS4GC block and the explicit FP loop.
// Keep the rest (createTargetMachine, opt, emit) as-is for now.
```

Ensure you delete the old RS4GC `PassBuilder` block and the FP loop at the bottom of the function to avoid double‑running.
#### 1.3.3 `EcoRunner.cpp` JIT transformer

Current transformer in `executeJIT`:
```cpp
jitOptions.transformer = [baseTransformer](llvm::Module *m) -> llvm::Error {
    // Build PB, analyses...
    eco::addEcoGCPipeline(MPM);
    MPM.run(*m, MAM);

    // Frame pointers
    for (auto &F : *m) {
        if (!F.isDeclaration())
            F.addFnAttr("frame-pointer", "all");
    }

    auto err = baseTransformer(m);
    if (err) return err;
    return llvm::Error::success();
};
```

Replace RS4GC + FP with a call to `runRS4GCAndMaybeFramePointers`:
```cpp
#include "EcoBackend.h" // at top

...

jitOptions.transformer = [baseTransformer](llvm::Module *m) -> llvm::Error {
    eco::RS4GCOptions rs4gcOpts;
    rs4gcOpts.addFramePointerAttr = true;
    eco::runRS4GCAndMaybeFramePointers(*m, rs4gcOpts);

    auto err = baseTransformer(m);
    if (err) return err;
    return llvm::Error::success();
};
```

Same change should be mirrored in `ecoc.cpp::runJIT` if that’s still present and using a similar transformer.
**After Phase 1:** No semantic changes; all you’ve done is centralize RS4GC + FP logic.
---
## 2. Phase 2 – Introduce a shared backend driver (`EcoBackendJob`)

Next, add a job descriptor + driver as a façade over existing behavior. Initially we’ll use it only for AOT and IR‑dump; JIT will still call `runRS4GCAndMaybeFramePointers` directly until Phase 4.
### 2.1 Extend `EcoBackend.h`

Add the job struct + driver prototype:
```cpp
namespace eco {

enum class BackendKind {
    DumpLLVMText,  ///< Print final LLVM IR to stdout or file.
    EmitObjectFile ///< Emit object file and optionally link an exe.
    // JITInvokePacked will be wired later in Phase 4.
};

struct EcoBackendJob {
    BackendKind kind;

    /// TargetMachine for AOT; may be null for pure text dump.
    llvm::TargetMachine *tm = nullptr;

    /// Requested optimization level.
    llvm::CodeGenOptLevel optLevel;

    /// Whether to add frame-pointer attributes.
    bool needsFramePointerAttr = false;

    /// Optional pre/post RS4GC dumps.
    std::string preRS4GCDumpPath;
    std::string postRS4GCDumpPath;

    /// Output paths for AOT.
    std::string objectFilePath; ///< For kind == EmitObjectFile.
    std::string exeFilePath;    ///< Optional; non-empty means link exe.
};

/// Run the Eco backend on an LLVM module according to `job`.
///
/// Phase 2 implementation is a thin wrapper over existing behavior:
/// - Calls runRS4GCAndMaybeFramePointers with the given dump/FP settings
/// - For DumpLLVMText: prints IR, no extra opt/emit
/// - For EmitObjectFile: defers to caller's existing emit logic (Phase 2),
///   expanded in Phase 3.
llvm::Error runEcoBackend(llvm::Module &m, const EcoBackendJob &job);

} // namespace eco
```
### 2.2 Implement `runEcoBackend` (thin wrapper, Phase 2)

In `EcoBackend.cpp`:
```cpp
#include "mlir/ExecutionEngine/OptUtils.h" // for makeOptimizingTransformer
#include "llvm/Support/Error.h"
#include "llvm/Support/raw_ostream.h"

namespace eco {

llvm::Error runEcoBackend(Module &m, const EcoBackendJob &job) {
    // Step 1: RS4GC + dumps + frame-pointer.
    RS4GCOptions rs4gcOpts;
    rs4gcOpts.preDumpPath       = job.preRS4GCDumpPath;
    rs4gcOpts.postDumpPath      = job.postRS4GCDumpPath;
    rs4gcOpts.addFramePointerAttr = job.needsFramePointerAttr;
    runRS4GCAndMaybeFramePointers(m, rs4gcOpts);

    // Step 2: Dispatch by kind.
    switch (job.kind) {
    case BackendKind::DumpLLVMText:
        // Phase 2: no extra optimization here (matches ecoc behavior).
        // Caller will handle printing (we’ll wire this in Phase 3).
        return llvm::Error::success();

    case BackendKind::EmitObjectFile:
        // Phase 2: emit logic is still in eco-boot.cpp; we just
        // signal that RS4GC has been done successfully.
        return llvm::Error::success();
    }

    llvm_unreachable("Unknown BackendKind");
}

} // namespace eco
```

At this phase, you’re *not yet* moving target machine creation, DL setup, or optimization into `runEcoBackend`. It’s just a common “RS4GC front‑end” that you can call from tools.
---
## 3. Phase 3 – Flip DataLayout ordering (DL early), tool by tool

Now we start changing semantics: DataLayout should be set **immediately after MLIR→LLVM translation**, before RS4GC, first in `ecoc`, then in `eco-boot`.
We’ll also extend `runEcoBackend` to own more of the emission logic so that future changes are centralized.
### 3.1 `ecoc -emit=llvm`: DL early + `runEcoBackend` use
#### 3.1.1 Update `dumpLLVMIR` in `ecoc.cpp`

Currently: translate → RS4GC → DL/opt → print.
We want: translate → **create TM + DL** → `runEcoBackend` (RS4GC) → opt → print.
Modify `dumpLLVMIR`:
```cpp
#include "EcoBackend.h"
#include "jit/EcoJIT.h" // for EcoJIT::setupTargetTripleAndDataLayout

static int dumpLLVMIR(ModuleOp module) {
    registerBuiltinDialectTranslation(*module->getContext());
    registerLLVMDialectTranslation(*module->getContext());

    llvm::LLVMContext llvmContext;
    auto llvmModule = translateModuleToLLVMIR(module, llvmContext);
    if (!llvmModule) {
        llvm::errs() << "Failed to emit LLVM IR\n";
        return 1;
    }

    // Initialize targets.
    llvm::InitializeNativeTarget();
    llvm::InitializeNativeTargetAsmPrinter();

    // Create target machine (unchanged, just moved earlier).
    auto tmBuilderOrError =
        llvm::orc::JITTargetMachineBuilder::detectHost();
    if (!tmBuilderOrError) { ... }

    auto tmOrError = tmBuilderOrError->createTargetMachine();
    if (!tmOrError) { ... }

    std::unique_ptr<llvm::TargetMachine> tm = std::move(tmOrError.get());

    // Set triple + DataLayout BEFORE RS4GC.
    eco::EcoJIT::setupTargetTripleAndDataLayout(
        llvmModule.get(), tm.get());

    // Run RS4GC via shared backend driver (no FP for plain dump).
    eco::EcoBackendJob job;
    job.kind                 = eco::BackendKind::DumpLLVMText;
    job.tm                   = tm.get();
    job.optLevel             = enableOpt
        ? llvm::CodeGenOptLevel::Aggressive
        : llvm::CodeGenOptLevel::None;
    job.needsFramePointerAttr = false;
    job.preRS4GCDumpPath     = "";               // ecoc has no pre-RS4GC CLI flag
    job.postRS4GCDumpPath    = dumpRS4GCIR;      // existing flag
    if (auto err = eco::runEcoBackend(*llvmModule, job)) {
        llvm::errs() << "RS4GC failed: " << err << "\n";
        return 1;
    }

    // Optional LLVM optimization (unchanged).
    if (enableOpt) {
        auto optPipeline = makeOptimizingTransformer(3, 0, nullptr);
        if (auto err = optPipeline(llvmModule.get())) {
            llvm::errs() << "Failed to optimize LLVM IR: " << err << "\n";
            return 1;
        }
    }

    // Finally, print LLVM IR.
    llvm::outs() << *llvmModule << "\n";
    return 0;
}
```

You’re now:
- Creating TM and setting DL *before* RS4GC (DL‑early).
- Using `runEcoBackend` for RS4GC + dumps.
#### 3.1.2 Extend `runEcoBackend` to own dump printing (optional)

If you’d like `runEcoBackend` to also own text emission (to reduce future divergence), you could change `DumpLLVMText` to print there; but to keep this phase minimally invasive, leaving printing in `ecoc.cpp` is fine.
### 3.2 `eco-boot.cpp`: DL early + `runEcoBackend` use

Currently, eco-boot:
- Translates MLIR→LLVM.
- Does pre‑RS4GC dump.
- Runs RS4GC.
- Does post‑RS4GC dump.
- Only then creates TM and runs opt.    

We want:

- Translate → create TM + DL → `runEcoBackend` (pre/post dumps + FP) → opt/emit.

Modify the body after translation:
```cpp
#include "EcoBackend.h"
#include "jit/EcoJIT.h"

...

// After Step 4: translateToLLVMIR(*module, llvmContext)
llvmModule = translateToLLVMIR(*module, llvmContext);
if (!llvmModule) { ... }

// Step 5 (new position): Create target machine and set DL.
std::unique_ptr<llvm::TargetMachine> tm;
{
    eco::LoweringStats::Scope scope(stats, "TargetMachine init");
    tm = createTargetMachine(*llvmModule);
    if (!tm)
        return 1;
}

// Set triple + DataLayout BEFORE RS4GC.
eco::EcoJIT::setupTargetTripleAndDataLayout(llvmModule.get(), tm.get());

// Step 6: RS4GC + dumps + FP via shared helper.
{
    eco::LoweringStats::Scope scope(stats, "LLVM RS4GC pipeline");
    eco::EcoBackendJob job;
    job.kind                  = eco::BackendKind::EmitObjectFile;
    job.tm                    = tm.get();
    job.optLevel              = optLevel > 0
        ? static_cast<llvm::CodeGenOptLevel>(optLevel)
        : llvm::CodeGenOptLevel::None;
    job.needsFramePointerAttr = true;
    job.preRS4GCDumpPath      = dumpPreRS4GCIR;
    job.postRS4GCDumpPath     = dumpRS4GCIR;
    // We'll use job.objectFilePath/exeFilePath later; for now just run RS4GC.
    if (auto err = eco::runEcoBackend(*llvmModule, job)) {
        llvm::errs() << "Error: RS4GC failed: " << err << "\n";
        return 1;
    }
}

// Existing opt + emit logic (Step 6/7/8) can stay as-is for now,
// but remove the old RS4GC+dump block and the FP loop.
```

This flips DL ordering for eco-boot to match JIT and ecoc.
At this point you can choose whether to move optimization + object emission into `runEcoBackend` (see next).
### 3.3 Extend `runEcoBackend` to own AOT optimization and emission (optional now, required for full convergence)

Once you’re comfortable, you can expand `runEcoBackend` so that for `EmitObjectFile` it:
- Uses `makeOptimizingTransformer(job.optLevel, 0, job.tm)` to run the generic optimization pipeline.
- Calls an `emitObjectFile` helper (currently in eco-boot) with `job.objectFilePath`.
- Optionally links an executable if `job.exeFilePath` is non‑empty.

You’ll then adjust eco-boot to fill in `job.objectFilePath`/`exeFilePath` and let `runEcoBackend` drive the rest. That’s a mechanical refactor; I’ll focus the detailed code on RS4GC/DL, since that’s where the subtle bugs are.
---
## 4. Phase 4 – Bring EcoRunner/EcoJIT onto the shared driver

Now that ecoc and eco-boot use `runEcoBackend` with DL‑early, we can give JIT the same treatment.
### 4.1 Extend `BackendKind` and `EcoBackendJob` for JIT

In `EcoBackend.h`:
```cpp
enum class BackendKind {
    DumpLLVMText,
    EmitObjectFile,
    JITInvokePacked  ///< Run full RS4GC + opt pipeline for JIT consumption.
};
```

Add a flag for packed wrappers if you need it (depending on where you generate `_mlir_main(void**)`):
```cpp
struct EcoBackendJob {
    BackendKind kind;
    llvm::TargetMachine *tm = nullptr;
    llvm::CodeGenOptLevel optLevel;
    bool needsFramePointerAttr = false;
    bool needsPackedInvokeWrappers = false; // if you decide to generate wrappers here
    ...
};
```

Update `runEcoBackend` to handle `JITInvokePacked`:
```cpp
llvm::Error runEcoBackend(Module &m, const EcoBackendJob &job) {
    // For JIT or AOT, we assume TM/DL have already been set up by caller
    // or by a separate setup helper.

    // (Optional) packFunctionArguments if job.needsPackedInvokeWrappers.
    // This depends on where that logic currently lives; if it's in EcoJIT,
    // you may keep it there and leave needsPackedInvokeWrappers unused.

    RS4GCOptions rs4gcOpts;
    rs4gcOpts.preDumpPath       = job.preRS4GCDumpPath;
    rs4gcOpts.postDumpPath      = job.postRS4GCDumpPath;
    rs4gcOpts.addFramePointerAttr = job.needsFramePointerAttr;

    runRS4GCAndMaybeFramePointers(m, rs4gcOpts);

    switch (job.kind) {
    case BackendKind::DumpLLVMText:
        // (same as Phase 3)
        return llvm::Error::success();

    case BackendKind::EmitObjectFile:
        // (opt + emit, once you move that here)
        return llvm::Error::success();

    case BackendKind::JITInvokePacked: {
        // JIT pipeline: run MLIR's makeOptimizingTransformer with TM or nullptr.
        auto optPipeline = makeOptimizingTransformer(
            /*optLevel=*/job.optLevel,
            /*sizeLevel=*/0,
            /*targetMachine=*/job.tm);
        if (auto err = optPipeline(&m))
            return err;

        return llvm::Error::success();
    }
    }

    llvm_unreachable("Unknown BackendKind");
}
```
### 4.2 Change EcoRunner’s transformer to call `runEcoBackend`

In `EcoRunner.cpp::executeJIT`, replace the current lambda:
```cpp
auto baseTransformer = options.enableOpt
    ? makeOptimizingTransformer(3, 0, nullptr)
    : makeOptimizingTransformer(0, 0, nullptr);
jitOptions.transformer = [baseTransformer](llvm::Module *m) -> llvm::Error {
    // RS4GC + FP...
    // baseTransformer(m)...
};
```

with a call into `runEcoBackend`:
```cpp
#include "EcoBackend.h"
#include "jit/EcoJIT.h"

...

bool enableOpt = options.enableOpt;

jitOptions.transformer = [enableOpt](llvm::Module *m) -> llvm::Error {
    // Initialize target + DL the same way ecoc does.
    llvm::InitializeNativeTarget();
    llvm::InitializeNativeTargetAsmPrinter();

    auto tmBuilderOrError =
        llvm::orc::JITTargetMachineBuilder::detectHost();
    if (!tmBuilderOrError)
        return tmBuilderOrError.takeError();

    auto tmOrError = tmBuilderOrError->createTargetMachine();
    if (!tmOrError)
        return tmOrError.takeError();

    std::unique_ptr<llvm::TargetMachine> tm = std::move(tmOrError.get());

    eco::EcoJIT::setupTargetTripleAndDataLayout(m, tm.get());

    eco::EcoBackendJob job;
    job.kind                  = eco::BackendKind::JITInvokePacked;
    job.tm                    = tm.get();
    job.optLevel              = enableOpt
        ? llvm::CodeGenOptLevel::Aggressive
        : llvm::CodeGenOptLevel::None;
    job.needsFramePointerAttr = true;
    job.needsPackedInvokeWrappers = false; // or true if you move wrapper gen here

    if (auto err = eco::runEcoBackend(*m, job))
        return err;

    return llvm::Error::success();
};
```

This:
- Ensures DL is set before RS4GC (matching AOT and ecoc).
- Uses the exact same RS4GC + FP + opt logic.

You can similarly adjust `ecoc.cpp::runJIT` to call `runEcoBackend` in its transformer, or simply rely on EcoRunner as your sole JIT entrypoint for tests (which is already the case for MLIR codegen tests and Elm E2E tests).
---
## 5. Phase 5 – Expand E2E harness across JIT/AOT (optional in this write‑up)

This is more about test code than backend plumbing, but for completeness:
- In `test/ElmE2ETest.cpp` / `test/elm/ElmTest.hpp` (described in PLAN as the Elm E2E runner) :
  - Introduce an enum:

    ```cpp
    enum class BackendMode { JIT, AOT };
    ```

  - For each test, allow specifying `BackendMode`.
  - For `JIT`, keep the existing flow: Elm → MLIR → EcoRunner JIT (which now uses `runEcoBackend`).
  - For `AOT`:
    - Write MLIR to a temp file.
    - Call `eco-boot` with `--emit=exe` / `--emit=obj` to compile that MLIR using the converged backend (`runEcoBackend` with `EmitObjectFile`).   
    - Spawn the resulting executable and compare its stdout against the `-- CHECK:` patterns in the E2E test definitions.   

This step doesn’t change the backend; it just exercises both the EcoRunner and eco-boot faces of the shared pipeline.
---
## Summary

If you implement the steps above in order:
1. **Phase 1:** Introduce `EcoBackend.{h,cpp}` with `runRS4GCAndMaybeFramePointers`, and wire ecoc, eco-boot, and EcoRunner to use it without changing ordering.
2. **Phase 2:** Add `EcoBackendJob` + `runEcoBackend` as a thin façade around RS4GC/FP.
3. **Phase 3:** Move target machine creation + DL setup to *immediately after translation* in `ecoc` and `eco-boot`, and call `runEcoBackend` there.
4. **Phase 4:** Update EcoRunner/EcoJIT to run through `runEcoBackend` with DL‑early and a consistent RS4GC + FP + opt pipeline.
5. **Phase 5 (tests):** Extend the E2E harness to also run programs through the AOT path, so any future drift between JIT and AOT is caught immediately.

Each phase is localized enough that if tests regress, you know exactly which change to inspect, and the final result is a single, explicit backend driver that all three tools build on.
