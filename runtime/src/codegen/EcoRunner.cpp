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

#include "../allocator/RuntimeExports.h"
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
        func::registerAllExtensions(registry);
        LLVM::registerInlinerInterface(registry);

        MLIRContext context(registry);
        context.getOrLoadDialect<eco::EcoDialect>();
        context.getOrLoadDialect<func::FuncDialect>();
        context.getOrLoadDialect<cf::ControlFlowDialect>();
        context.getOrLoadDialect<arith::ArithDialect>();
        context.getOrLoadDialect<scf::SCFDialect>();
        context.getOrLoadDialect<LLVM::LLVMDialect>();
        context.allowUnregisteredDialects();

        // Parse MLIR source
        auto module = parseMLIR(context, source);
        if (!module) {
            result.errorMessage = "Failed to parse MLIR source";
            return result;
        }

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
        return parseSourceFile<ModuleOp>(sourceMgr, &context);
    }

    bool runPipeline(ModuleOp module) {
        PassManager pm(module->getName());

        // Stage 1: Eco -> Eco transformations
        pm.addPass(eco::createRCEliminationPass());

        // Stage 2: Eco -> Standard MLIR

        // Classify joinpoints for SCF lowering eligibility.
        pm.addPass(eco::createJoinpointNormalizationPass());

        // Lower eligible eco.case/joinpoint to SCF dialect.
        // Non-eligible ops are left for the CF path in EcoToLLVM.
        pm.addPass(eco::createEcoControlFlowToSCFPass());

        pm.addNestedPass<func::FuncOp>(createCanonicalizerPass());

        // Convert SCF to CF before EcoToLLVM.
        // This creates cf.br/cf.cond_br with !eco.value types, which
        // EcoToLLVM will then convert to LLVM types.
        pm.addPass(createSCFToControlFlowPass());

        // Stage 3: Eco -> LLVM Dialect
        // This also handles remaining eco control flow ops (case/joinpoint/jump)
        // that weren't lowered to SCF.
        pm.addPass(eco::createEcoToLLVMPass());

        // Standard MLIR dialect conversions to LLVM
        pm.addPass(createConvertFuncToLLVMPass());
        pm.addPass(createConvertControlFlowToLLVMPass());
        pm.addPass(createArithToLLVMConversionPass());

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
        registerRuntimeSymbols(*engine);

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

    void registerRuntimeSymbols(ExecutionEngine& engine) {
        engine.registerSymbols([](llvm::orc::MangleAndInterner interner) {
            llvm::orc::SymbolMap symbolMap;

            // Heap allocation functions
            symbolMap[interner("eco_alloc_custom")] =
                llvm::orc::ExecutorSymbolDef(
                    llvm::orc::ExecutorAddr::fromPtr(&eco_alloc_custom),
                    llvm::JITSymbolFlags::Exported);
            symbolMap[interner("eco_alloc_cons")] =
                llvm::orc::ExecutorSymbolDef(
                    llvm::orc::ExecutorAddr::fromPtr(&eco_alloc_cons),
                    llvm::JITSymbolFlags::Exported);
            symbolMap[interner("eco_alloc_tuple2")] =
                llvm::orc::ExecutorSymbolDef(
                    llvm::orc::ExecutorAddr::fromPtr(&eco_alloc_tuple2),
                    llvm::JITSymbolFlags::Exported);
            symbolMap[interner("eco_alloc_tuple3")] =
                llvm::orc::ExecutorSymbolDef(
                    llvm::orc::ExecutorAddr::fromPtr(&eco_alloc_tuple3),
                    llvm::JITSymbolFlags::Exported);
            symbolMap[interner("eco_alloc_string")] =
                llvm::orc::ExecutorSymbolDef(
                    llvm::orc::ExecutorAddr::fromPtr(&eco_alloc_string),
                    llvm::JITSymbolFlags::Exported);
            symbolMap[interner("eco_alloc_closure")] =
                llvm::orc::ExecutorSymbolDef(
                    llvm::orc::ExecutorAddr::fromPtr(&eco_alloc_closure),
                    llvm::JITSymbolFlags::Exported);
            symbolMap[interner("eco_alloc_int")] =
                llvm::orc::ExecutorSymbolDef(
                    llvm::orc::ExecutorAddr::fromPtr(&eco_alloc_int),
                    llvm::JITSymbolFlags::Exported);
            symbolMap[interner("eco_alloc_float")] =
                llvm::orc::ExecutorSymbolDef(
                    llvm::orc::ExecutorAddr::fromPtr(&eco_alloc_float),
                    llvm::JITSymbolFlags::Exported);
            symbolMap[interner("eco_alloc_char")] =
                llvm::orc::ExecutorSymbolDef(
                    llvm::orc::ExecutorAddr::fromPtr(&eco_alloc_char),
                    llvm::JITSymbolFlags::Exported);
            symbolMap[interner("eco_allocate")] =
                llvm::orc::ExecutorSymbolDef(
                    llvm::orc::ExecutorAddr::fromPtr(&eco_allocate),
                    llvm::JITSymbolFlags::Exported);

            // Field store functions
            symbolMap[interner("eco_store_field")] =
                llvm::orc::ExecutorSymbolDef(
                    llvm::orc::ExecutorAddr::fromPtr(&eco_store_field),
                    llvm::JITSymbolFlags::Exported);
            symbolMap[interner("eco_store_field_i64")] =
                llvm::orc::ExecutorSymbolDef(
                    llvm::orc::ExecutorAddr::fromPtr(&eco_store_field_i64),
                    llvm::JITSymbolFlags::Exported);
            symbolMap[interner("eco_store_field_f64")] =
                llvm::orc::ExecutorSymbolDef(
                    llvm::orc::ExecutorAddr::fromPtr(&eco_store_field_f64),
                    llvm::JITSymbolFlags::Exported);
            symbolMap[interner("eco_set_unboxed")] =
                llvm::orc::ExecutorSymbolDef(
                    llvm::orc::ExecutorAddr::fromPtr(&eco_set_unboxed),
                    llvm::JITSymbolFlags::Exported);

            // Closure operations
            symbolMap[interner("eco_apply_closure")] =
                llvm::orc::ExecutorSymbolDef(
                    llvm::orc::ExecutorAddr::fromPtr(&eco_apply_closure),
                    llvm::JITSymbolFlags::Exported);
            symbolMap[interner("eco_pap_extend")] =
                llvm::orc::ExecutorSymbolDef(
                    llvm::orc::ExecutorAddr::fromPtr(&eco_pap_extend),
                    llvm::JITSymbolFlags::Exported);
            symbolMap[interner("eco_closure_call_saturated")] =
                llvm::orc::ExecutorSymbolDef(
                    llvm::orc::ExecutorAddr::fromPtr(&eco_closure_call_saturated),
                    llvm::JITSymbolFlags::Exported);

            // Runtime utilities
            symbolMap[interner("eco_crash")] =
                llvm::orc::ExecutorSymbolDef(
                    llvm::orc::ExecutorAddr::fromPtr(&eco_crash),
                    llvm::JITSymbolFlags::Exported);
            symbolMap[interner("eco_dbg_print")] =
                llvm::orc::ExecutorSymbolDef(
                    llvm::orc::ExecutorAddr::fromPtr(&eco_dbg_print),
                    llvm::JITSymbolFlags::Exported);
            symbolMap[interner("eco_dbg_print_int")] =
                llvm::orc::ExecutorSymbolDef(
                    llvm::orc::ExecutorAddr::fromPtr(&eco_dbg_print_int),
                    llvm::JITSymbolFlags::Exported);
            symbolMap[interner("eco_dbg_print_float")] =
                llvm::orc::ExecutorSymbolDef(
                    llvm::orc::ExecutorAddr::fromPtr(&eco_dbg_print_float),
                    llvm::JITSymbolFlags::Exported);
            symbolMap[interner("eco_dbg_print_char")] =
                llvm::orc::ExecutorSymbolDef(
                    llvm::orc::ExecutorAddr::fromPtr(&eco_dbg_print_char),
                    llvm::JITSymbolFlags::Exported);

            // GC interface
            symbolMap[interner("eco_safepoint")] =
                llvm::orc::ExecutorSymbolDef(
                    llvm::orc::ExecutorAddr::fromPtr(&eco_safepoint),
                    llvm::JITSymbolFlags::Exported);
            symbolMap[interner("eco_minor_gc")] =
                llvm::orc::ExecutorSymbolDef(
                    llvm::orc::ExecutorAddr::fromPtr(&eco_minor_gc),
                    llvm::JITSymbolFlags::Exported);
            symbolMap[interner("eco_major_gc")] =
                llvm::orc::ExecutorSymbolDef(
                    llvm::orc::ExecutorAddr::fromPtr(&eco_major_gc),
                    llvm::JITSymbolFlags::Exported);
            symbolMap[interner("eco_gc_add_root")] =
                llvm::orc::ExecutorSymbolDef(
                    llvm::orc::ExecutorAddr::fromPtr(&eco_gc_add_root),
                    llvm::JITSymbolFlags::Exported);
            symbolMap[interner("eco_gc_remove_root")] =
                llvm::orc::ExecutorSymbolDef(
                    llvm::orc::ExecutorAddr::fromPtr(&eco_gc_remove_root),
                    llvm::JITSymbolFlags::Exported);
            symbolMap[interner("eco_gc_jit_root_count")] =
                llvm::orc::ExecutorSymbolDef(
                    llvm::orc::ExecutorAddr::fromPtr(&eco_gc_jit_root_count),
                    llvm::JITSymbolFlags::Exported);

            // Tag extraction
            symbolMap[interner("eco_get_header_tag")] =
                llvm::orc::ExecutorSymbolDef(
                    llvm::orc::ExecutorAddr::fromPtr(&eco_get_header_tag),
                    llvm::JITSymbolFlags::Exported);
            symbolMap[interner("eco_get_custom_ctor")] =
                llvm::orc::ExecutorSymbolDef(
                    llvm::orc::ExecutorAddr::fromPtr(&eco_get_custom_ctor),
                    llvm::JITSymbolFlags::Exported);

            // Arithmetic helpers
            symbolMap[interner("eco_int_pow")] =
                llvm::orc::ExecutorSymbolDef(
                    llvm::orc::ExecutorAddr::fromPtr(&eco_int_pow),
                    llvm::JITSymbolFlags::Exported);

            return symbolMap;
        });
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
