//===- EcoRunner.cpp - In-process execution engine for Eco MLIR -----------===//
//===----------------------------------------------------------------------===//

#include "EcoRunner.hpp"

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
#include "mlir/Conversion/SCFToControlFlow/SCFToControlFlow.h"

#include "mlir/ExecutionEngine/ExecutionEngine.h"
#include "mlir/ExecutionEngine/OptUtils.h"

#include "mlir/IR/BuiltinOps.h"
#include "mlir/IR/MLIRContext.h"
#include "mlir/IR/OwningOpRef.h"
#include "mlir/IR/AsmState.h"
#include "mlir/Parser/Parser.h"
#include "mlir/Pass/PassManager.h"

#include "mlir/Target/LLVMIR/Dialect/Builtin/BuiltinToLLVMIRTranslation.h"
#include "mlir/Target/LLVMIR/Dialect/LLVMIR/LLVMToLLVMIRTranslation.h"

#include "mlir/Transforms/Passes.h"

#include "llvm/Support/TargetSelect.h"
#include "llvm/Support/SourceMgr.h"
#include "llvm/Support/MemoryBuffer.h"

// The kernels' GC-root registration hooks, which a run calls if they are defined. Outside Windows they are weak, so
// a binary without the kernel that defines one links, and the address tested before the call is null.
//
// On Windows clang-cl turns a weak function declaration into a COMDAT weak external, and /WHOLEARCHIVE then reports
// a duplicate for every translation unit that declares it, so these are plain declarations there. Only
// `Eco_Kernel_Order_register_gc_roots` has a fallback, the /alternatename default in eco_order_weak_stub_win32.cpp;
// `Eco_Kernel_register_all_gc_roots` must be defined by something linked in.
#if defined(_WIN32)
extern "C" void Eco_Kernel_register_all_gc_roots();
extern "C" void Eco_Kernel_Order_register_gc_roots();
#else
extern "C" __attribute__((weak)) void Eco_Kernel_register_all_gc_roots();
extern "C" __attribute__((weak)) void Eco_Kernel_Order_register_gc_roots();
#endif

#include "EcoDialect.h"
#include "Passes.h"
#include "EcoBackend.h"
#include "EcoPipeline.h"
#include "RuntimeSymbols.h"
#include "EcoJIT.h"

#include "llvm/Analysis/TargetLibraryInfo.h"

namespace eco { void linkEcoGCStrategy(); }
// A static object whose constructor calls `eco::linkEcoGCStrategy`, so that the file registering Eco's GC strategy
// with LLVM is linked into any binary that contains this one, even from a static library.
static struct EcoGCStrategyLinker {
    EcoGCStrategyLinker() { eco::linkEcoGCStrategy(); }
} ecoGCStrategyLinker;
#include "../allocator/StackMap.hpp"

#include "../allocator/RuntimeExports.h"
#include "KernelExports.h"
#include "../allocator/Allocator.hpp"

#include <csignal>
#include <mutex>
#include <sstream>

using namespace mlir;

namespace eco {

//===----------------------------------------------------------------------===//
// Output Capture using RuntimeExports API
//===----------------------------------------------------------------------===//

namespace {

// The calling thread's capture buffer, which is that thread's print destination while it captures.
thread_local std::ostringstream tl_capture_buffer;
// Whether the calling thread is between `startOutputCapture` and `stopOutputCapture`.
thread_local bool tl_capturing = false;

} // namespace

void startOutputCapture() {
    tl_capture_buffer.str("");
    tl_capture_buffer.clear();
    tl_capturing = true;
    eco_set_output_stream(&tl_capture_buffer);
}

std::string stopOutputCapture() {
    eco_set_output_stream(nullptr);
    tl_capturing = false;
    std::string result = tl_capture_buffer.str();
    tl_capture_buffer.str("");
    tl_capture_buffer.clear();
    return result;
}

bool isCapturingOutput() {
    return tl_capturing;
}

//===----------------------------------------------------------------------===//
// EcoRunner Implementation
//===----------------------------------------------------------------------===//

/**
 * The work of an `EcoRunner`, kept out of the header so that it need not include MLIR or LLVM. It holds no state of
 * its own; each run takes the runner's options as an argument.
 */
class EcoRunner::Impl {
public:
    // Initializes LLVM's native target if nothing has, and outside Windows sets `SIGPIPE` to be ignored.
    Impl() {
        initializeLLVM();
#if !defined(_WIN32)
        // A write to a closed pipe must fail with EPIPE in the kernel's write path, not kill the process.
        std::signal(SIGPIPE, SIG_IGN);
#endif
    }

    ~Impl() = default;

    // Does `EcoRunner::run` for `source` with `options`.
    RunResult run(const std::string& source, const Options& options) {
        RunResult result;

        DialectRegistry registry;
        eco::registerRequiredDialects(registry);

        MLIRContext context(registry);
        eco::loadRequiredDialects(context);
        context.allowUnregisteredDialects();

        auto module = parseMLIR(context, source);
        if (!module) {
            result.errorMessage = "Failed to parse or verify MLIR source";
            return result;
        }

        if (!runPipeline(*module, options)) {
            result.errorMessage = "Lowering pipeline failed";
            return result;
        }

        return executeJIT(*module, options);
    }

    // Does `EcoRunner::runFile` for `filePath` with `options`.
    RunResult runFile(const std::string& filePath, const Options& options) {
        auto fileOrErr = llvm::MemoryBuffer::getFile(filePath);
        if (!fileOrErr) {
            RunResult result;
            result.errorMessage = "Cannot open file: " + filePath;
            return result;
        }

        return run((*fileOrErr)->getBuffer().str(), options);
    }

private:
    // Set once LLVM's native target has been initialized in this process.
    static std::once_flag llvmInitFlag_;

    // Initializes LLVM's native target and its assembly printer, once per process.
    static void initializeLLVM() {
        std::call_once(llvmInitFlag_, []() {
            llvm::InitializeNativeTarget();
            llvm::InitializeNativeTargetAsmPrinter();
        });
    }

    // Parses and verifies `source` as a module in `context`, and returns it, or null if it is not a valid module.
    // Parse errors are reported through `context`'s diagnostic handler.
    OwningOpRef<ModuleOp> parseMLIR(MLIRContext& context, const std::string& source) {
        llvm::SourceMgr sourceMgr;
        auto memBuffer = llvm::MemoryBuffer::getMemBuffer(source, "eco_runner_input");
        sourceMgr.AddNewSourceBuffer(std::move(memBuffer), llvm::SMLoc());
        return parseSourceFile<ModuleOp>(sourceMgr, &context);
    }

    // Lowers `module` in place to the LLVM dialect, and returns whether every pass succeeded. `options` does not
    // affect the lowering.
    bool runPipeline(ModuleOp module, const Options& options) {
        (void)options;
        PassManager pm(module->getName());

        // Default pipeline options: open world, so no reachability pass and no closed-world capacity planning.
        eco::EcoPipelineOptions pipeOpts;
        eco::buildEcoToLLVMPipeline(pm, pipeOpts);

        return succeeded(pm.run(module));
    }

    // Compiles the lowered `module`, prepares the runtime, and calls `main`, as `EcoRunner::run` describes.
    RunResult executeJIT(ModuleOp module, const Options& options) {
        RunResult result;

        registerBuiltinDialectTranslation(*module->getContext());
        registerLLVMDialectTranslation(*module->getContext());

        // The transformer runs the module through `runEcoBackend` as a JIT job, with frame-pointer attributes. It
        // must own what it captures, because `create` calls it after this statement ends.
        eco::EcoJITOptions jitOptions;
        bool enableOpt = options.enableOpt;
        jitOptions.transformer = [enableOpt](llvm::Module *m) -> llvm::Error {
            eco::EcoBackendJob job;
            job.kind = eco::BackendKind::JITInvokePacked;
            job.tm = nullptr;
            job.optLevel = enableOpt ? llvm::CodeGenOptLevel::Aggressive
                                     : llvm::CodeGenOptLevel::None;
            job.needsFramePointerAttr = true;
            return eco::runEcoBackend(*m, job);
        };

        auto maybeEngine = eco::EcoJIT::create(module, jitOptions);
        if (!maybeEngine) {
            result.errorMessage = "Failed to create execution engine: " +
                                  llvm::toString(maybeEngine.takeError());
            return result;
        }

        auto& engine = maybeEngine.get();

        eco::registerRuntimeSymbols(*engine);

        Elm::Allocator::instance().initialize();
        Elm::Allocator::instance().initThread();

        // Always true on Windows, where the declaration is not weak.
        if (Eco_Kernel_register_all_gc_roots)
            Eco_Kernel_register_all_gc_roots();

        // A separate hook, so that these roots are registered even when the hook above is absent. When both are
        // linked, the hook above has already called this one, so it runs twice.
        if (Eco_Kernel_Order_register_gc_roots)
            Eco_Kernel_Order_register_gc_roots();

        // A raw lookup, so this runs before the module's initializers, which `invokePacked` runs first.
        auto initGlobalsSymbol = engine->lookup("__eco_init_globals");
        if (initGlobalsSymbol) {
            auto initGlobalsFn = reinterpret_cast<void(*)()>(initGlobalsSymbol.get());
            initGlobalsFn();
        } else {
            llvm::consumeError(initGlobalsSymbol.takeError());
        }

        eco_register_all_effect_managers();

        // Looking up `main` compiles the module, so its stack maps can be read after it.
        {
            auto mainLookup = engine->lookup("main");
            if (mainLookup) {
                const auto& smData = engine->getStackMapData();
                if (!smData.empty()) {
                    Elm::globalStackMap().parse(smData.data(), smData.size());
                }
            } else {
                llvm::consumeError(mainLookup.takeError());
            }
        }

        if (options.captureOutput) {
            startOutputCapture();
        }

        eco_set_exit_code(0);

        int64_t returnValue = 0;
        void* args[] = { &returnValue };
        auto error = engine->invokePacked("main", args);

        if (options.captureOutput) {
            result.output = stopOutputCapture();
        }

        Elm::Allocator::instance().cleanupThread();

        if (error) {
            result.errorMessage = "JIT invocation failed: " + llvm::toString(std::move(error));
            return result;
        }

        result.success = true;
        result.returnValue = returnValue;
        result.exitCode = eco_get_exit_code();
        return result;
    }
};

std::once_flag EcoRunner::Impl::llvmInitFlag_;

//===----------------------------------------------------------------------===//
// EcoRunner Public Interface
//===----------------------------------------------------------------------===//

EcoRunner::EcoRunner() : impl_(std::make_unique<Impl>()) {}

EcoRunner::EcoRunner(const Options& options)
    : impl_(std::make_unique<Impl>()), options_(options) {}

EcoRunner::~EcoRunner() = default;

EcoRunner::EcoRunner(EcoRunner&&) noexcept = default;
EcoRunner& EcoRunner::operator=(EcoRunner&&) noexcept = default;

void EcoRunner::reset() {
    // Pass a configuration: without one the allocator keeps the current one. The helper jitter is not used here.
    uint32_t jitter = 0;
    const Elm::HeapConfig cfg = Elm::Allocator::environmentConfig(Elm::HeapConfig(), jitter);
    Elm::AllocatorTestAccess::reset(Elm::Allocator::instance(), &cfg);
}

RunResult EcoRunner::run(const std::string& source) {
    return impl_->run(source, options_);
}

RunResult EcoRunner::runFile(const std::string& filePath) {
    return impl_->runFile(filePath, options_);
}

} // namespace eco
