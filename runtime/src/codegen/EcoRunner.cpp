//===- EcoRunner.cpp - In-process execution engine for Eco MLIR -----------===//
//
// Implementation of the EcoRunner API for running Eco dialect MLIR code
// directly within a test process.
//
//===----------------------------------------------------------------------===//

#include "EcoRunner.hpp"

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
#include "mlir/IR/Verifier.h"

#include "mlir/IR/AsmState.h"
#include "mlir/Parser/Parser.h"
#include "mlir/Pass/PassManager.h"

#include "mlir/Target/LLVMIR/Dialect/Builtin/BuiltinToLLVMIRTranslation.h"
#include "mlir/Target/LLVMIR/Dialect/LLVMIR/LLVMToLLVMIRTranslation.h"

#include "mlir/Transforms/Passes.h"

#include "llvm/Support/TargetSelect.h"
#include "llvm/Support/SourceMgr.h"
#include "llvm/Support/MemoryBuffer.h"

#include "EcoDialect.h"
#include "EcoOps.h"
#include "Passes.h"
#include "EcoPipeline.h"
#include "RuntimeSymbols.h"

#include "../allocator/RuntimeExports.h"
#include "KernelExports.h"
#include "../allocator/Allocator.hpp"

#include <mutex>
#include <sstream>

using namespace mlir;

namespace eco {

//===----------------------------------------------------------------------===//
// Output Capture using RuntimeExports API
//===----------------------------------------------------------------------===//

namespace {

/// Thread-local capture buffer.
thread_local std::ostringstream tl_capture_buffer;
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

class EcoRunner::Impl {
public:
    Impl() {
        initializeLLVM();
    }

    ~Impl() = default;

    RunResult run(const std::string& source, const Options& options) {
        RunResult result;

        // Create MLIR context for this run
        DialectRegistry registry;
        eco::registerRequiredDialects(registry);

        MLIRContext context(registry);
        eco::loadRequiredDialects(context);
        context.allowUnregisteredDialects();

        // Parse MLIR source (without verification to allow fixups first)
        auto module = parseMLIR(context, source);
        if (!module) {
            result.errorMessage = "Failed to parse MLIR source";
            return result;
        }

        // Fix eco.call result type mismatches before verification
        fixCallResultTypes(*module);

        // Verify module
        if (failed(verify(*module))) {
            result.errorMessage = "Module verification failed";
            return result;
        }

        // Run the lowering pipeline
        if (!runPipeline(*module)) {
            result.errorMessage = "Lowering pipeline failed";
            return result;
        }

        // JIT execute
        return executeJIT(*module, options);
    }

    RunResult runFile(const std::string& filePath, const Options& options) {
        // Read file contents
        auto fileOrErr = llvm::MemoryBuffer::getFile(filePath);
        if (!fileOrErr) {
            RunResult result;
            result.errorMessage = "Cannot open file: " + filePath;
            return result;
        }

        return run((*fileOrErr)->getBuffer().str(), options);
    }

private:
    static std::once_flag llvmInitFlag_;

    static void initializeLLVM() {
        std::call_once(llvmInitFlag_, []() {
            llvm::InitializeNativeTarget();
            llvm::InitializeNativeTargetAsmPrinter();
        });
    }

    OwningOpRef<ModuleOp> parseMLIR(MLIRContext& context, const std::string& source) {
        llvm::SourceMgr sourceMgr;
        auto memBuffer = llvm::MemoryBuffer::getMemBuffer(source, "eco_runner_input");
        sourceMgr.AddNewSourceBuffer(std::move(memBuffer), llvm::SMLoc());
        // Parse without verification so we can fix eco.call type mismatches first
        ParserConfig config(&context, /*verifyAfterParse=*/false);
        return parseSourceFile<ModuleOp>(sourceMgr, config);
    }

    /// Fix eco.call ops whose result type doesn't match the callee's declared
    /// return type. This happens when the Elm compiler generates a call with
    /// the call-site's expected type (e.g. i64) but the callee function returns
    /// a different type (e.g. !eco.value for polymorphic kernel wrappers).
    void fixCallResultTypes(ModuleOp module) {
        module.walk([&](CallOp callOp) {
            auto calleeAttr = callOp.getCalleeAttr();
            if (!calleeAttr)
                return;  // Indirect call, skip

            // Look up the callee function
            auto *symbol = module.lookupSymbol(calleeAttr.getValue());
            if (!symbol)
                return;

            auto funcOp = dyn_cast<func::FuncOp>(symbol);
            if (!funcOp)
                return;

            auto funcType = funcOp.getFunctionType();
            if (funcType.getNumResults() == 0)
                return;

            Type calleeReturnType = funcType.getResult(0);
            if (callOp.getNumResults() == 0)
                return;

            Type callResultType = callOp.getResult(0).getType();
            if (callResultType == calleeReturnType)
                return;  // Types already match

            // Fix the result type by creating a new call with correct type
            // and adding an unbox/box to convert
            OpBuilder builder(callOp->getContext());
            builder.setInsertionPointAfter(callOp);

            // Update the call op's result type in-place
            callOp.getResult(0).setType(calleeReturnType);

            // If the callee returns !eco.value but call site expects a primitive,
            // insert an unbox after the call
            if (isa<ValueType>(calleeReturnType) && !isa<ValueType>(callResultType)) {
                auto unboxOp = builder.create<UnboxOp>(
                    callOp.getLoc(), callResultType, callOp.getResult(0));
                callOp.getResult(0).replaceAllUsesExcept(unboxOp.getResult(), unboxOp);
            }
            // If the callee returns a primitive but call site expects !eco.value,
            // insert a box after the call
            else if (!isa<ValueType>(calleeReturnType) && isa<ValueType>(callResultType)) {
                auto boxOp = builder.create<BoxOp>(
                    callOp.getLoc(), callResultType, callOp.getResult(0));
                callOp.getResult(0).replaceAllUsesExcept(boxOp.getResult(), boxOp);
            }
        });
    }

    bool runPipeline(ModuleOp module) {
        PassManager pm(module->getName());

        // Use the shared pipeline from EcoPipeline.cpp
        eco::buildEcoToLLVMPipeline(pm);

        return succeeded(pm.run(module));
    }

    RunResult executeJIT(ModuleOp module, const Options& options) {
        RunResult result;

        // Register translations
        registerBuiltinDialectTranslation(*module->getContext());
        registerLLVMDialectTranslation(*module->getContext());

        // Set up execution engine
        ExecutionEngineOptions engineOptions;
        engineOptions.transformer = options.enableOpt
            ? makeOptimizingTransformer(3, 0, nullptr)
            : makeOptimizingTransformer(0, 0, nullptr);

        auto maybeEngine = ExecutionEngine::create(module, engineOptions);
        if (!maybeEngine) {
            result.errorMessage = "Failed to create execution engine: " +
                                  llvm::toString(maybeEngine.takeError());
            return result;
        }

        auto& engine = maybeEngine.get();

        // Register runtime symbols
        eco::registerRuntimeSymbols(*engine);

        // Initialize runtime
        Elm::Allocator::instance().initialize();
        Elm::Allocator::instance().initThread();

        // Initialize globals if present
        auto initGlobalsSymbol = engine->lookup("__eco_init_globals");
        if (initGlobalsSymbol) {
            auto initGlobalsFn = reinterpret_cast<void(*)()>(initGlobalsSymbol.get());
            initGlobalsFn();
        } else {
            llvm::consumeError(initGlobalsSymbol.takeError());
        }

        // Register effect managers
        eco_register_all_effect_managers();

        // Start output capture if requested
        if (options.captureOutput) {
            startOutputCapture();
        }

        // Invoke main
        int64_t returnValue = 0;
        void* args[] = { &returnValue };
        auto error = engine->invokePacked("main", args);

        // Stop output capture
        if (options.captureOutput) {
            result.output = stopOutputCapture();
        }

        // Cleanup
        Elm::Allocator::instance().cleanupThread();

        if (error) {
            result.errorMessage = "JIT invocation failed: " + llvm::toString(std::move(error));
            return result;
        }

        result.success = true;
        result.returnValue = returnValue;
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
    // Reset the allocator to clean state
    Elm::AllocatorTestAccess::reset(Elm::Allocator::instance());
}

RunResult EcoRunner::run(const std::string& source) {
    return impl_->run(source, options_);
}

RunResult EcoRunner::runFile(const std::string& filePath) {
    return impl_->runFile(filePath, options_);
}

} // namespace eco
