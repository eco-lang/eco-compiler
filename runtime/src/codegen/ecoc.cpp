//===- ecoc.cpp - Eco dialect compiler driver -----------------------------===//
//
// This is the main entry point for the Eco compiler. It parses an MLIR file
// containing the Eco dialect, runs the lowering pipeline, and optionally
// JIT-compiles and executes the result.
//
// Usage: ecoc <input.mlir> [options]
//
// Options:
//   -emit=<action>  : What to output
//     mlir          : Dump the input MLIR (no lowering)
//     mlir-eco      : Dump MLIR after eco-to-eco passes
//     mlir-llvm     : Dump MLIR after full lowering to LLVM dialect
//     llvm          : Dump LLVM IR
//     jit           : JIT compile and execute
//
//===----------------------------------------------------------------------===//

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

// Include runtime exports for JIT symbol registration.
#include "../allocator/RuntimeExports.h"
#include "../allocator/Allocator.hpp"

// Include kernel exports for JIT symbol registration.
#include "KernelExports.h"

using namespace mlir;

namespace cl = llvm::cl;

//===----------------------------------------------------------------------===//
// Command Line Options
//===----------------------------------------------------------------------===//

static cl::opt<std::string> inputFilename(
    cl::Positional,
    cl::desc("<input .mlir file>"),
    cl::Required);

static cl::opt<std::string> outputFilename(
    "o",
    cl::desc("Output filename (default: stdout)"),
    cl::value_desc("filename"),
    cl::init("-"));

namespace {
enum Action {
    None,
    DumpMLIR,
    DumpMLIREco,
    DumpMLIRLLVM,
    DumpLLVMIR,
    RunJIT
};
} // namespace

static cl::opt<enum Action> emitAction(
    "emit",
    cl::desc("Select the kind of output desired"),
    cl::values(
        clEnumValN(DumpMLIR, "mlir", "Dump input MLIR (no lowering)"),
        clEnumValN(DumpMLIREco, "mlir-eco", "Dump MLIR after eco-to-eco passes"),
        clEnumValN(DumpMLIRLLVM, "mlir-llvm", "Dump MLIR after LLVM lowering"),
        clEnumValN(DumpLLVMIR, "llvm", "Dump LLVM IR"),
        clEnumValN(RunJIT, "jit", "JIT compile and run")),
    cl::init(DumpMLIRLLVM));

static cl::opt<bool> enableOpt(
    "opt",
    cl::desc("Enable LLVM optimizations"),
    cl::init(false));

static cl::opt<bool> verifyDiagnostics(
    "verify-diagnostics",
    cl::desc("Check that emitted diagnostics match expected"),
    cl::init(false));

//===----------------------------------------------------------------------===//
// MLIR Loading
//===----------------------------------------------------------------------===//

static OwningOpRef<ModuleOp> loadMLIR(MLIRContext &context,
                                       llvm::SourceMgr &sourceMgr) {
    auto module = parseSourceFile<ModuleOp>(sourceMgr, &context);
    if (!module) {
        llvm::errs() << "Error: Failed to parse MLIR file\n";
        return nullptr;
    }
    return module;
}

//===----------------------------------------------------------------------===//
// Pass Pipeline Construction
//===----------------------------------------------------------------------===//

static int runPipeline(ModuleOp module, bool lowerToLLVM) {
    PassManager pm(module->getName());

    // Apply any generic pass manager command line options.
    if (failed(applyPassManagerCLOptions(pm)))
        return 1;

    if (emitAction >= DumpMLIREco) {
        // Stage 1: Eco -> Eco transformations.
        // TODO: Add construct lowering pass.
        // pm.addPass(eco::createConstructLoweringPass());
        pm.addPass(eco::createRCEliminationPass());

        // Generate external declarations for undefined functions (kernel functions, etc.)
        pm.addPass(eco::createUndefinedFunctionStubPass());
    }

    if (lowerToLLVM) {
        // Stage 2: Eco -> Standard MLIR (func/cf/arith).

        // Infer result_types for eco.case ops based on eco.return operands.
        pm.addPass(eco::createResultTypesInferencePass());

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

        // Stage 3: Eco -> LLVM Dialect.
        // This also handles remaining eco control flow ops (case/joinpoint/jump)
        // that weren't lowered to SCF. Also includes func-to-llvm conversion.
        pm.addPass(eco::createEcoToLLVMPass());

        // Standard MLIR dialect conversions to LLVM.
        // Note: func-to-llvm is now part of EcoToLLVM to ensure functions are
        // converted before eco.papCreate tries to reference them.
        pm.addPass(createConvertControlFlowToLLVMPass());
        pm.addPass(createArithToLLVMConversionPass());
    }

    if (failed(pm.run(module)))
        return 1;

    return 0;
}

//===----------------------------------------------------------------------===//
// LLVM IR Emission
//===----------------------------------------------------------------------===//

static int dumpLLVMIR(ModuleOp module) {
    // Register the translation from MLIR to LLVM IR.
    registerBuiltinDialectTranslation(*module->getContext());
    registerLLVMDialectTranslation(*module->getContext());

    // Convert MLIR module to LLVM IR.
    llvm::LLVMContext llvmContext;
    auto llvmModule = translateModuleToLLVMIR(module, llvmContext);
    if (!llvmModule) {
        llvm::errs() << "Failed to emit LLVM IR\n";
        return 1;
    }

    // Initialize LLVM targets for the host platform.
    llvm::InitializeNativeTarget();
    llvm::InitializeNativeTargetAsmPrinter();

    // Create target machine for the host.
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

    ExecutionEngine::setupTargetTripleAndDataLayout(llvmModule.get(),
                                                     tmOrError.get().get());

    // Optionally run LLVM optimization passes.
    if (enableOpt) {
        auto optPipeline = makeOptimizingTransformer(3, 0, nullptr);
        if (auto err = optPipeline(llvmModule.get())) {
            llvm::errs() << "Failed to optimize LLVM IR: " << err << "\n";
            return 1;
        }
    }

    llvm::outs() << *llvmModule << "\n";
    return 0;
}

//===----------------------------------------------------------------------===//
// JIT Execution
//===----------------------------------------------------------------------===//

static int runJIT(ModuleOp module) {
    // Initialize LLVM targets for the host platform.
    llvm::InitializeNativeTarget();
    llvm::InitializeNativeTargetAsmPrinter();

    // Register translation from MLIR to LLVM IR.
    registerBuiltinDialectTranslation(*module->getContext());
    registerLLVMDialectTranslation(*module->getContext());

    // Set up execution engine options with optional optimization.
    ExecutionEngineOptions options;
    options.transformer = enableOpt
        ? makeOptimizingTransformer(3, 0, nullptr)
        : makeOptimizingTransformer(0, 0, nullptr);

    // Create the JIT execution engine.
    auto maybeEngine = ExecutionEngine::create(module, options);
    if (!maybeEngine) {
        llvm::errs() << "Failed to create execution engine: "
                     << llvm::toString(maybeEngine.takeError()) << "\n";
        return 1;
    }

    auto &engine = maybeEngine.get();

    // Register runtime function symbols for JIT linking.
    engine->registerSymbols([](llvm::orc::MangleAndInterner interner) {
        llvm::orc::SymbolMap symbolMap;

        // Heap allocation functions.
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

        // Field store functions.
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

        // Closure operations.
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

        // Runtime utilities.
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

        // GC interface.
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

        // Tag extraction.
        symbolMap[interner("eco_get_header_tag")] =
            llvm::orc::ExecutorSymbolDef(
                llvm::orc::ExecutorAddr::fromPtr(&eco_get_header_tag),
                llvm::JITSymbolFlags::Exported);
        symbolMap[interner("eco_get_custom_ctor")] =
            llvm::orc::ExecutorSymbolDef(
                llvm::orc::ExecutorAddr::fromPtr(&eco_get_custom_ctor),
                llvm::JITSymbolFlags::Exported);

        // Arithmetic helpers.
        symbolMap[interner("eco_int_pow")] =
            llvm::orc::ExecutorSymbolDef(
                llvm::orc::ExecutorAddr::fromPtr(&eco_int_pow),
                llvm::JITSymbolFlags::Exported);

        // =================================================================
        // Elm Kernel Function Symbols
        // =================================================================

        // Helper macro for registering kernel symbols.
        #define KERNEL_SYM(name) \
            symbolMap[interner(#name)] = \
                llvm::orc::ExecutorSymbolDef( \
                    llvm::orc::ExecutorAddr::fromPtr(&name), \
                    llvm::JITSymbolFlags::Exported);

        // Basics module
        KERNEL_SYM(Elm_Kernel_Basics_acos)
        KERNEL_SYM(Elm_Kernel_Basics_asin)
        KERNEL_SYM(Elm_Kernel_Basics_atan)
        KERNEL_SYM(Elm_Kernel_Basics_atan2)
        KERNEL_SYM(Elm_Kernel_Basics_cos)
        KERNEL_SYM(Elm_Kernel_Basics_sin)
        KERNEL_SYM(Elm_Kernel_Basics_tan)
        KERNEL_SYM(Elm_Kernel_Basics_sqrt)
        KERNEL_SYM(Elm_Kernel_Basics_log)
        KERNEL_SYM(Elm_Kernel_Basics_pow)
        KERNEL_SYM(Elm_Kernel_Basics_e)
        KERNEL_SYM(Elm_Kernel_Basics_pi)
        KERNEL_SYM(Elm_Kernel_Basics_add)
        KERNEL_SYM(Elm_Kernel_Basics_sub)
        KERNEL_SYM(Elm_Kernel_Basics_mul)
        KERNEL_SYM(Elm_Kernel_Basics_fdiv)
        KERNEL_SYM(Elm_Kernel_Basics_idiv)
        KERNEL_SYM(Elm_Kernel_Basics_modBy)
        KERNEL_SYM(Elm_Kernel_Basics_remainderBy)
        KERNEL_SYM(Elm_Kernel_Basics_ceiling)
        KERNEL_SYM(Elm_Kernel_Basics_floor)
        KERNEL_SYM(Elm_Kernel_Basics_round)
        KERNEL_SYM(Elm_Kernel_Basics_truncate)
        KERNEL_SYM(Elm_Kernel_Basics_toFloat)
        KERNEL_SYM(Elm_Kernel_Basics_isInfinite)
        KERNEL_SYM(Elm_Kernel_Basics_isNaN)
        KERNEL_SYM(Elm_Kernel_Basics_and)
        KERNEL_SYM(Elm_Kernel_Basics_or)
        KERNEL_SYM(Elm_Kernel_Basics_xor)
        KERNEL_SYM(Elm_Kernel_Basics_not)

        // Bitwise module
        KERNEL_SYM(Elm_Kernel_Bitwise_and)
        KERNEL_SYM(Elm_Kernel_Bitwise_or)
        KERNEL_SYM(Elm_Kernel_Bitwise_xor)
        KERNEL_SYM(Elm_Kernel_Bitwise_complement)
        KERNEL_SYM(Elm_Kernel_Bitwise_shiftLeftBy)
        KERNEL_SYM(Elm_Kernel_Bitwise_shiftRightBy)
        KERNEL_SYM(Elm_Kernel_Bitwise_shiftRightZfBy)

        // Char module
        KERNEL_SYM(Elm_Kernel_Char_fromCode)
        KERNEL_SYM(Elm_Kernel_Char_toCode)
        KERNEL_SYM(Elm_Kernel_Char_toLower)
        KERNEL_SYM(Elm_Kernel_Char_toUpper)
        KERNEL_SYM(Elm_Kernel_Char_toLocaleLower)
        KERNEL_SYM(Elm_Kernel_Char_toLocaleUpper)

        // String module
        KERNEL_SYM(Elm_Kernel_String_length)
        KERNEL_SYM(Elm_Kernel_String_append)
        KERNEL_SYM(Elm_Kernel_String_join)
        KERNEL_SYM(Elm_Kernel_String_cons)
        KERNEL_SYM(Elm_Kernel_String_uncons)
        KERNEL_SYM(Elm_Kernel_String_fromList)
        KERNEL_SYM(Elm_Kernel_String_slice)
        KERNEL_SYM(Elm_Kernel_String_split)
        KERNEL_SYM(Elm_Kernel_String_lines)
        KERNEL_SYM(Elm_Kernel_String_words)
        KERNEL_SYM(Elm_Kernel_String_reverse)
        KERNEL_SYM(Elm_Kernel_String_toUpper)
        KERNEL_SYM(Elm_Kernel_String_toLower)
        KERNEL_SYM(Elm_Kernel_String_trim)
        KERNEL_SYM(Elm_Kernel_String_trimLeft)
        KERNEL_SYM(Elm_Kernel_String_trimRight)
        KERNEL_SYM(Elm_Kernel_String_startsWith)
        KERNEL_SYM(Elm_Kernel_String_endsWith)
        KERNEL_SYM(Elm_Kernel_String_contains)
        KERNEL_SYM(Elm_Kernel_String_indexes)
        KERNEL_SYM(Elm_Kernel_String_toInt)
        KERNEL_SYM(Elm_Kernel_String_toFloat)
        KERNEL_SYM(Elm_Kernel_String_fromNumber)

        // List module
        KERNEL_SYM(Elm_Kernel_List_cons)

        // Utils module
        KERNEL_SYM(Elm_Kernel_Utils_compare)
        KERNEL_SYM(Elm_Kernel_Utils_equal)
        KERNEL_SYM(Elm_Kernel_Utils_notEqual)
        KERNEL_SYM(Elm_Kernel_Utils_lt)
        KERNEL_SYM(Elm_Kernel_Utils_le)
        KERNEL_SYM(Elm_Kernel_Utils_gt)
        KERNEL_SYM(Elm_Kernel_Utils_ge)
        KERNEL_SYM(Elm_Kernel_Utils_append)

        // JsArray module
        KERNEL_SYM(Elm_Kernel_JsArray_empty)
        KERNEL_SYM(Elm_Kernel_JsArray_singleton)
        KERNEL_SYM(Elm_Kernel_JsArray_length)
        KERNEL_SYM(Elm_Kernel_JsArray_unsafeGet)
        KERNEL_SYM(Elm_Kernel_JsArray_unsafeSet)
        KERNEL_SYM(Elm_Kernel_JsArray_push)
        KERNEL_SYM(Elm_Kernel_JsArray_slice)
        KERNEL_SYM(Elm_Kernel_JsArray_appendN)

        // VirtualDom module
        KERNEL_SYM(Elm_Kernel_VirtualDom_text)
        KERNEL_SYM(Elm_Kernel_VirtualDom_node)
        KERNEL_SYM(Elm_Kernel_VirtualDom_nodeNS)
        KERNEL_SYM(Elm_Kernel_VirtualDom_keyedNode)
        KERNEL_SYM(Elm_Kernel_VirtualDom_keyedNodeNS)
        KERNEL_SYM(Elm_Kernel_VirtualDom_attribute)
        KERNEL_SYM(Elm_Kernel_VirtualDom_attributeNS)
        KERNEL_SYM(Elm_Kernel_VirtualDom_property)
        KERNEL_SYM(Elm_Kernel_VirtualDom_style)

        // Debug module
        KERNEL_SYM(Elm_Kernel_Debug_log)
        KERNEL_SYM(Elm_Kernel_Debug_todo)
        KERNEL_SYM(Elm_Kernel_Debug_toString)

        // Scheduler module
        KERNEL_SYM(Elm_Kernel_Scheduler_succeed)
        KERNEL_SYM(Elm_Kernel_Scheduler_fail)

        #undef KERNEL_SYM

        return symbolMap;
    });

    // Initialize the runtime GC and thread-local allocator.
    Elm::Allocator::instance().initialize();
    Elm::Allocator::instance().initThread();

    // Call __eco_init_globals if it exists to register globals as GC roots.
    // This function is generated by the EcoToLLVM pass when eco.global ops are present.
    auto initGlobalsSymbol = engine->lookup("__eco_init_globals");
    if (initGlobalsSymbol) {
        auto initGlobalsFn = reinterpret_cast<void(*)()>(initGlobalsSymbol.get());
        initGlobalsFn();
    } else {
        // Symbol not found - this is expected for modules without eco.global.
        // Consume the error to avoid assertion failure on destruction.
        llvm::consumeError(initGlobalsSymbol.takeError());
    }

    // Invoke the main function with packed calling convention.
    // invokePacked expects pointers to result storage followed by argument values.
    int64_t result = 0;
    void *args[] = { &result };
    auto error = engine->invokePacked("main", args);
    if (error) {
        llvm::errs() << "JIT invocation failed: " << error << "\n";
        Elm::Allocator::instance().cleanupThread();
        return 1;
    }
    llvm::outs() << "main() returned: " << result << "\n";

    // Cleanup thread-local allocator state.
    Elm::Allocator::instance().cleanupThread();

    llvm::outs() << "JIT execution completed successfully\n";
    return 0;
}

//===----------------------------------------------------------------------===//
// Main
//===----------------------------------------------------------------------===//

int main(int argc, char **argv) {
    // Initialize LLVM infrastructure.
    llvm::InitLLVM initLLVM(argc, argv);

    // Register command line options.
    registerAsmPrinterCLOptions();
    registerMLIRContextCLOptions();
    registerPassManagerCLOptions();

    cl::ParseCommandLineOptions(argc, argv, "Eco dialect compiler\n\n"
        "This tool compiles MLIR files containing the Eco dialect,\n"
        "lowering them to LLVM IR and optionally JIT-executing them.\n");

    // Set up MLIR context with required dialect extensions.
    DialectRegistry registry;
    func::registerAllExtensions(registry);
    LLVM::registerInlinerInterface(registry);

    MLIRContext context(registry);

    // Load required dialects.
    context.getOrLoadDialect<eco::EcoDialect>();
    context.getOrLoadDialect<func::FuncDialect>();
    context.getOrLoadDialect<cf::ControlFlowDialect>();
    context.getOrLoadDialect<arith::ArithDialect>();
    context.getOrLoadDialect<scf::SCFDialect>();
    context.getOrLoadDialect<LLVM::LLVMDialect>();

    // Allow unregistered dialects for flexibility during development.
    context.allowUnregisteredDialects();

    // Load input file.
    std::string errorMessage;
    auto inputFile = openInputFile(inputFilename, &errorMessage);
    if (!inputFile) {
        llvm::errs() << "Error: " << errorMessage << "\n";
        return 1;
    }

    llvm::SourceMgr sourceMgr;
    sourceMgr.AddNewSourceBuffer(std::move(inputFile), llvm::SMLoc());

    // Parse the MLIR input file.
    auto module = loadMLIR(context, sourceMgr);
    if (!module)
        return 1;

    // Verify the module structure.
    if (failed(verify(*module))) {
        llvm::errs() << "Error: Module verification failed\n";
        return 1;
    }

    // Dump input MLIR without any lowering if requested.
    if (emitAction == DumpMLIR) {
        module->dump();
        return 0;
    }

    // Run the lowering pipeline.
    bool lowerToLLVM = emitAction >= DumpMLIRLLVM;
    if (runPipeline(*module, lowerToLLVM) != 0)
        return 1;

    // Handle different output modes.
    if (emitAction == DumpMLIREco || emitAction == DumpMLIRLLVM) {
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
