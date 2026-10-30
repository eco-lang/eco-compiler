//===- ecoc.cpp - Eco dialect compiler driver -----------------------------===//
//
// A command-line tool for looking at the Eco lowering partway through, or
// running its result, one `.mlir` file at a time. Tests compare its output
// against expected text.
//
// Usage: ecoc <input.mlir> [-emit=<action>] [options]
//
// The tool parses and verifies the input, then lowers it with the pass
// pipelines of `EcoPipeline.h`. Those pipelines are nested, each a strict
// prefix of the next, so stopping after a shorter one shows the module exactly
// as the full lowering has it at that point. `-emit` chooses where to stop and
// what to do with the result:
//
//   mlir       the verified input, with no passes run.
//   mlir-eco   the module after `eco::buildEcoToEcoPipeline`.
//   mlir-opt   the module after `eco::buildEcoToOptPipeline`.
//   mlir-llvm  the module after `eco::buildEcoToLLVMPipeline` (the default).
//   llvm       LLVM IR after the full lowering, translation and RS4GC, on
//              standard output.
//   jit        the full lowering compiled by `eco::EcoJIT` and `main` run.
//
// The four MLIR actions print with `Operation::dump`, which writes to standard
// error. `-o`, `-verify-diagnostics` and `-dump-rs4gc-ir` with any action but
// `llvm` are accepted and have no effect.
//
// LLVM work goes through `eco::runEcoBackend`, as in the other drivers, but
// the target machine is the host's, not the one `eco::createEcoTargetMachine`
// pins for ahead-of-time output. Running `main` needs the runtime, so this
// executable also contains the allocator and the platform code.
//
//===----------------------------------------------------------------------===//

#include <cassert>

#include "mlir/Dialect/Arith/IR/Arith.h"
#include "mlir/Dialect/ControlFlow/IR/ControlFlow.h"
#include "mlir/Dialect/Func/IR/FuncOps.h"
#include "mlir/Dialect/Func/Extensions/AllExtensions.h"
#include "mlir/Dialect/LLVMIR/LLVMDialect.h"
#include "mlir/Dialect/LLVMIR/Transforms/InlinerInterfaceImpl.h"
#include "mlir/Dialect/SCF/IR/SCF.h"

#include "mlir/Conversion/ArithToLLVM/ArithToLLVM.h"
#include "mlir/Conversion/ControlFlowToLLVM/ControlFlowToLLVM.h"
#include "mlir/Conversion/FuncToLLVM/ConvertFuncToLLVM.h"
#include "mlir/Conversion/FuncToLLVM/ConvertFuncToLLVMPass.h"
#include "mlir/Conversion/LLVMCommon/ConversionTarget.h"
#include "mlir/Conversion/LLVMCommon/TypeConverter.h"
#include "mlir/Conversion/SCFToControlFlow/SCFToControlFlow.h"
#include "mlir/Conversion/ReconcileUnrealizedCasts/ReconcileUnrealizedCasts.h"

#include "mlir/ExecutionEngine/ExecutionEngine.h"
#include "mlir/ExecutionEngine/OptUtils.h"

#include "mlir/IR/AsmState.h"
#include "mlir/IR/BuiltinOps.h"
#include "mlir/IR/MLIRContext.h"
#include "mlir/IR/OwningOpRef.h"
#include "mlir/IR/Verifier.h"

#include "mlir/Parser/Parser.h"
#include "mlir/Pass/Pass.h"
#include "mlir/Pass/PassManager.h"

#include "mlir/Support/FileUtilities.h"

#include "mlir/Target/LLVMIR/Dialect/Builtin/BuiltinToLLVMIRTranslation.h"
#include "mlir/Target/LLVMIR/Dialect/LLVMIR/LLVMToLLVMIRTranslation.h"
#include "mlir/Target/LLVMIR/Export.h"

#include "mlir/Transforms/Passes.h"

#include "llvm/ExecutionEngine/Orc/JITTargetMachineBuilder.h"
#include "llvm/IR/Module.h"
#include "llvm/Support/CommandLine.h"
#include "llvm/Support/InitLLVM.h"
#include "llvm/Support/SourceMgr.h"
#include "llvm/Support/TargetSelect.h"
#include "llvm/Support/raw_ostream.h"

#include "EcoDialect.h"
#include "EcoOps.h"
#include "Passes.h"
#include "EcoBackend.h"
#include "EcoPipeline.h"
#include "RuntimeSymbols.h"
#include "EcoJIT.h"

#include "llvm/Analysis/TargetLibraryInfo.h"

// Does nothing; calling it keeps the "eco-gc" GC strategy registration from
// being dropped when it comes from a static library.
namespace eco { void linkEcoGCStrategy(); }
// A static object whose constructor calls `eco::linkEcoGCStrategy`, so that
// the object file holding the "eco-gc" strategy registration is linked in.
static struct EcoGCStrategyLinker {
    EcoGCStrategyLinker() { eco::linkEcoGCStrategy(); }
} ecoGCStrategyLinker;
#include "../allocator/StackMap.hpp"

#include "../allocator/Allocator.hpp"
#include "KernelExports.h"

// Registers the Eco kernel's GC roots; here, does nothing.
//
// The Eco kernel library, which defines the real function, is not linked
// into this tool. A weak reference to a missing symbol would be null on ELF
// but is refused by the macOS linker, so this weak empty definition stands in
// for it. A strong definition in the same link would replace it.
extern "C" __attribute__((weak)) void Eco_Kernel_register_all_gc_roots() {}
// Registers the GC roots of the Elm kernel's `Order` singletons, defined in the
// `ElmKernel` library this tool links. The declaration is weak except on
// Windows, where it is an ordinary declaration that the definition in
// `ElmKernel` satisfies.
#if defined(_WIN32)
extern "C" void Eco_Kernel_Order_register_gc_roots();
#else
extern "C" __attribute__((weak)) void Eco_Kernel_Order_register_gc_roots();
#endif

using namespace mlir;

namespace cl = llvm::cl;

//===----------------------------------------------------------------------===//
// Command Line Options
//===----------------------------------------------------------------------===//

// The input file, which must hold one MLIR module.
static cl::opt<std::string> inputFilename(
    cl::Positional,
    cl::desc("<input .mlir file>"),
    cl::Required);

// The `-o` option. It is parsed and never read: output goes to standard
// output or standard error as the file comment says.
static cl::opt<std::string> outputFilename(
    "o",
    cl::desc("Output filename (default: stdout)"),
    cl::value_desc("filename"),
    cl::init("-"));

namespace {
/**
 * What `-emit` asks for: where the lowering stops and what is done with the
 * result. The file comment lists what each value produces.
 */
enum Action {
    None, // Not a value `-emit` accepts.
    DumpMLIR,
    DumpMLIREco,
    DumpMLIROpt,
    DumpMLIRLLVM,
    DumpLLVMIR,
    RunJIT
};
} // namespace

// The `-emit` option, defaulting to `DumpMLIRLLVM`.
static cl::opt<enum Action> emitAction(
    "emit",
    cl::desc("Select the kind of output desired"),
    cl::values(
        clEnumValN(DumpMLIR, "mlir", "Dump input MLIR (no lowering)"),
        clEnumValN(DumpMLIREco, "mlir-eco", "Dump MLIR after eco-to-eco passes"),
        clEnumValN(DumpMLIROpt, "mlir-opt",
                   "Dump MLIR after the M4 slot (fold-project + CSE), before GC prep"),
        clEnumValN(DumpMLIRLLVM, "mlir-llvm", "Dump MLIR after LLVM lowering"),
        clEnumValN(DumpLLVMIR, "llvm", "Dump LLVM IR"),
        clEnumValN(RunJIT, "jit", "JIT compile and run")),
    cl::init(DumpMLIRLLVM));

// The `-opt` option. For `llvm` and `jit` it raises the backend job to
// `llvm::CodeGenOptLevel::Aggressive`, which also enables the `$cap` inline
// prepass, and for `llvm` it then runs LLVM's O3 optimization pipeline
// (`makeOptimizingTransformer`) on the module before printing.
static cl::opt<bool> enableOpt(
    "opt",
    cl::desc("Enable LLVM optimizations"),
    cl::init(false));

// The `-exe-reachability` option. It sets `EcoPipelineOptions::reachability`
// with the roots an executable has, `main` and `__eco_init_globals`, so the
// full lowering erases and internalizes as for an executable, unless
// `ECO_REACH_MLIR` is `0`. It is refused with `-emit=jit`. `capClosedWorld`
// stays false, as the backend here expects.
static cl::opt<bool> exeReachability(
    "exe-reachability",
    cl::desc("Erase what main/__eco_init_globals cannot reach and "
             "internalize the rest, as for an executable (not with -emit=jit)"),
    cl::init(false));

// The `-verify-diagnostics` option. It is parsed and never read.
static cl::opt<bool> verifyDiagnostics(
    "verify-diagnostics",
    cl::desc("Check that emitted diagnostics match expected"),
    cl::init(false));

// The `-dump-rs4gc-ir` option: a file to which `-emit=llvm` writes the
// module as text IR right after RS4GC. Empty for none.
static cl::opt<std::string> dumpRS4GCIR(
    "dump-rs4gc-ir",
    cl::desc("Dump LLVM IR to file after RS4GC pass (for GC diagnostics)"),
    cl::value_desc("filename"),
    cl::init(""));

//===----------------------------------------------------------------------===//
// MLIR Loading
//===----------------------------------------------------------------------===//

// The `-no-verify-parse` option: parse without the verifier. `main` verifies
// the module straight after parsing whatever this says, so invalid IR is
// still refused.
static llvm::cl::opt<bool> noVerifyParse(
    "no-verify-parse",
    llvm::cl::desc("Parse the input without running the verifier (diagnostic "
                   "dumps of invalid IR, e.g. with --emit=mlir)"),
    llvm::cl::init(false));

// Parses the module in `sourceMgr` into `context`, verifying it unless
// `-no-verify-parse` is given. Returns null after printing a message if
// parsing fails.
static OwningOpRef<ModuleOp> loadMLIR(MLIRContext &context,
                                       llvm::SourceMgr &sourceMgr) {
    ParserConfig config(&context, /*verifyAfterParse=*/!noVerifyParse);
    auto module = parseSourceFile<ModuleOp>(sourceMgr, config);
    if (!module) {
        llvm::errs() << "Error: Failed to parse MLIR file\n";
        return nullptr;
    }
    return module;
}

//===----------------------------------------------------------------------===//
// Pass Pipeline Construction
//===----------------------------------------------------------------------===//



// Lowers `module` in place with the pipeline `action` stops after: the
// eco-to-eco stage (`eco::buildEcoToEcoPipeline`) for `DumpMLIREco`, through
// the M4 slot for `DumpMLIROpt`, and the full lowering to the LLVM dialect
// for every other action.
//
// Returns 0 on success and 1 if the pass manager options or a pass fail, or
// if `-exe-reachability` is combined with `RunJIT`.
static int runPipeline(ModuleOp module, Action action) {
    PassManager pm(module->getName());

    if (failed(applyPassManagerCLOptions(pm)))
        return 1;

    eco::EcoPipelineOptions pipeOpts;
    if (exeReachability) {
        // The JIT gives packed wrappers only to functions without local
        // linkage, so internalizing would hide functions from it.
        if (action == RunJIT) {
            llvm::errs() << "Error: --exe-reachability cannot be used with "
                            "-emit=jit\n";
            return 1;
        }
        pipeOpts.reachability = true;
        pipeOpts.capRoots = {"main", "__eco_init_globals"};
    }
    if (action == DumpMLIREco) {
        eco::buildEcoToEcoPipeline(pm, pipeOpts);
    } else if (action == DumpMLIROpt) {
        eco::buildEcoToOptPipeline(pm, pipeOpts);
    } else {
        eco::buildEcoToLLVMPipeline(pm, pipeOpts);
    }

    if (failed(pm.run(module)))
        return 1;

    return 0;
}

//===----------------------------------------------------------------------===//
// LLVM IR Emission
//===----------------------------------------------------------------------===//

// Translates `module`, which must already be in the LLVM dialect, to LLVM
// IR, runs `eco::runEcoBackend` on it as a `DumpLLVMText` job, and prints the
// result to standard output.
//
// The target machine is detected from the host. The job adds no
// frame-pointer attributes, and writes the post-RS4GC dump `-dump-rs4gc-ir`
// names. With `-opt`, the module is optimized at O3 after the backend and
// before printing. Returns 0 on success, or 1 after printing a message.
static int dumpLLVMIR(ModuleOp module) {
    registerBuiltinDialectTranslation(*module->getContext());
    registerLLVMDialectTranslation(*module->getContext());

    // The LLVM verifier on the translation output runs only in
    // ECO_LOWERING_VALIDATION builds.
    llvm::LLVMContext llvmContext;
#ifdef ECO_LOWERING_VALIDATION
    constexpr bool kDisableLLVMVerify = false;
#else
    constexpr bool kDisableLLVMVerify = true;
#endif
    auto llvmModule = translateModuleToLLVMIR(
        module, llvmContext, "LLVMDialectModule", kDisableLLVMVerify);
    if (!llvmModule) {
        llvm::errs() << "Failed to emit LLVM IR\n";
        return 1;
    }

    // The target machine is made before the backend runs, because RS4GC
    // needs the module's data layout.
    llvm::InitializeNativeTarget();
    llvm::InitializeNativeTargetAsmPrinter();

    auto tmBuilderOrError = llvm::orc::JITTargetMachineBuilder::detectHost();
    if (!tmBuilderOrError) {
        llvm::errs() << "Could not create JITTargetMachineBuilder\n";
        return 1;
    }

    auto tmOrError = tmBuilderOrError->createTargetMachine();
    if (!tmOrError) {
        llvm::errs() << "Could not create TargetMachine\n";
        return 1;
    }

    std::unique_ptr<llvm::TargetMachine> tm = std::move(tmOrError.get());
    eco::EcoJIT::setupTargetTripleAndDataLayout(llvmModule.get(), tm.get());

    {
        eco::EcoBackendJob job;
        job.kind = eco::BackendKind::DumpLLVMText;
        job.tm = tm.get();
        job.optLevel = enableOpt ? llvm::CodeGenOptLevel::Aggressive
                                 : llvm::CodeGenOptLevel::None;
        job.needsFramePointerAttr = false;
        job.postRS4GCDumpPath = dumpRS4GCIR;
        if (auto err = eco::runEcoBackend(*llvmModule, job)) {
            llvm::errs() << "RS4GC failed: " << llvm::toString(std::move(err)) << "\n";
            return 1;
        }
    }

    if (enableOpt) {
        auto optPipeline = makeOptimizingTransformer(3, 0, nullptr);
        if (auto err = optPipeline(llvmModule.get())) {
            llvm::errs() << "Failed to optimize LLVM IR: " << llvm::toString(std::move(err)) << "\n";
            return 1;
        }
    }

    llvm::outs() << *llvmModule << "\n";
    return 0;
}

//===----------------------------------------------------------------------===//
// JIT Execution
//===----------------------------------------------------------------------===//

// Compiles `module`, which must already be in the LLVM dialect, with
// `eco::EcoJIT`, starts the runtime on the calling thread, and calls `main`
// through its packed wrapper.
//
// Before `main` runs, the kernel GC roots are registered, `__eco_init_globals`
// is called if the module defines it, the effect managers are registered,
// and the stack maps of the compiled code are parsed into the global stack
// map. The module is lowered by `eco::runEcoBackend` as a `JITInvokePacked`
// job with frame-pointer attributes, at `Aggressive` with `-opt` and `None`
// otherwise.
//
// Prints `main() returned: ` and the 64-bit result, the stack map size when
// there is one, and a completion line, all to standard output. Returns 0
// then, or 1 after printing a message if the engine cannot be created or
// `main` cannot be found or called.
static int runJIT(ModuleOp module) {
    llvm::InitializeNativeTarget();
    llvm::InitializeNativeTargetAsmPrinter();

    registerBuiltinDialectTranslation(*module->getContext());
    registerLLVMDialectTranslation(*module->getContext());

    eco::EcoJITOptions options;
    bool enableOptCapture = enableOpt;
    options.transformer = [enableOptCapture](llvm::Module *m) -> llvm::Error {
        eco::EcoBackendJob job;
        job.kind = eco::BackendKind::JITInvokePacked;
        job.tm = nullptr;
        job.optLevel = enableOptCapture ? llvm::CodeGenOptLevel::Aggressive
                                        : llvm::CodeGenOptLevel::None;
        job.needsFramePointerAttr = true;
        return eco::runEcoBackend(*m, job);
    };

    auto maybeEngine = eco::EcoJIT::create(module, options);
    if (!maybeEngine) {
        llvm::errs() << "Failed to create execution engine: "
                     << llvm::toString(maybeEngine.takeError()) << "\n";
        return 1;
    }

    auto &engine = maybeEngine.get();

    // Before the first lookup, which is what compiles the module.
    if (llvm::Error err = eco::registerRuntimeSymbols(*engine)) {
        llvm::errs() << "Failed to register runtime symbols: "
                     << llvm::toString(std::move(err)) << "\n";
        return 1;
    }

    Elm::Allocator::instance().initialize();
    Elm::Allocator::instance().initThread();

    if (Eco_Kernel_register_all_gc_roots)
        Eco_Kernel_register_all_gc_roots();

    if (Eco_Kernel_Order_register_gc_roots)
        Eco_Kernel_Order_register_gc_roots();

    // A module with no GC-root globals and no type graph has no __eco_init_globals.
    auto initGlobalsSymbol = engine->lookup("__eco_init_globals");
    if (initGlobalsSymbol) {
        auto initGlobalsFn = reinterpret_cast<void(*)()>(initGlobalsSymbol.get());
        initGlobalsFn();
    } else {
        llvm::consumeError(initGlobalsSymbol.takeError());
    }

    eco_register_all_effect_managers();

    // The stack map bytes exist only once a lookup has compiled the module
    // (the __eco_init_globals lookup above, if it succeeded, otherwise this
    // one), so they are parsed here, before main runs.
    {
        auto mainLookup = engine->lookup("main");
        if (!mainLookup) {
            llvm::errs() << "Failed to look up main: "
                         << llvm::toString(mainLookup.takeError()) << "\n";
            Elm::Allocator::instance().cleanupThread();
            return 1;
        }
        const auto& smData = engine->getStackMapData();
        if (!smData.empty()) {
            Elm::globalStackMap().parse(smData.data(), smData.size());
        }
    }

    int64_t result = 0;
    void *args[] = { &result };
    auto error = engine->invokePacked("main", args);
    if (error) {
        llvm::errs() << "JIT invocation failed: " << error << "\n";
        Elm::Allocator::instance().cleanupThread();
        return 1;
    }
    llvm::outs() << "main() returned: " << result << "\n";

    const auto &stackMap = engine->getStackMapData();
    if (!stackMap.empty()) {
        llvm::outs() << "Stack map: " << stackMap.size() << " bytes\n";
    }

    Elm::Allocator::instance().cleanupThread();

    llvm::outs() << "JIT execution completed successfully\n";
    return 0;
}

//===----------------------------------------------------------------------===//
// Main
//===----------------------------------------------------------------------===//

// Parses the options, then loads, verifies and lowers the input as `-emit`
// asks. Returns 0 on success and 1 on any failure, after printing a message
// for most of them.
int main(int argc, char **argv) {
    llvm::InitLLVM initLLVM(argc, argv);

    registerAsmPrinterCLOptions();
    registerMLIRContextCLOptions();
    registerPassManagerCLOptions();

    cl::ParseCommandLineOptions(argc, argv, "Eco dialect compiler\n\n"
        "This tool compiles MLIR files containing the Eco dialect,\n"
        "lowering them to LLVM IR and optionally JIT-executing them.\n");

    DialectRegistry registry;
    eco::registerRequiredDialects(registry);

    MLIRContext context(registry);

    eco::loadRequiredDialects(context);

    // Ops of dialects that are not loaded are parsed and kept, not refused.
    context.allowUnregisteredDialects();

    std::string errorMessage;
    auto inputFile = openInputFile(inputFilename, &errorMessage);
    if (!inputFile) {
        llvm::errs() << "Error: " << errorMessage << "\n";
        return 1;
    }

    llvm::SourceMgr sourceMgr;
    sourceMgr.AddNewSourceBuffer(std::move(inputFile), llvm::SMLoc());

    auto module = loadMLIR(context, sourceMgr);
    if (!module)
        return 1;

    // Runs even with -no-verify-parse.
    if (failed(verify(*module))) {
        llvm::errs() << "Error: Module verification failed\n";
        return 1;
    }

    if (emitAction == DumpMLIR) {
        module->dump();
        return 0;
    }

    if (runPipeline(*module, emitAction) != 0)
        return 1;

    if (emitAction == DumpMLIREco || emitAction == DumpMLIROpt ||
        emitAction == DumpMLIRLLVM) {
        module->dump();
        return 0;
    }

    if (emitAction == DumpLLVMIR)
        return dumpLLVMIR(*module);

    if (emitAction == RunJIT)
        return runJIT(*module);

    llvm::errs() << "No action specified, use -emit=<action>\n";
    return 1;
}
