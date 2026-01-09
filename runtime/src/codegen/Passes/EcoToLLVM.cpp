//===- EcoToLLVM.cpp - Eco dialect to LLVM dialect lowering ---------------===//
//
// This file implements the combined pass for lowering Eco dialect operations
// to LLVM dialect. It orchestrates pattern modules from:
//   - EcoToLLVMTypes.cpp: Constants and string literals
//   - EcoToLLVMHeap.cpp: Box, unbox, allocate, construct, project
//   - EcoToLLVMClosures.cpp: Closure operations
//   - EcoToLLVMControlFlow.cpp: Case, joinpoint, jump, return
//   - EcoToLLVMArith.cpp: Arithmetic, comparisons, bitwise, type conversions
//   - EcoToLLVMGlobals.cpp: Global variable operations
//   - EcoToLLVMErrorDebug.cpp: Safepoint, debug, crash, expect
//   - EcoToLLVMFunc.cpp: Kernel function declarations
//
//===----------------------------------------------------------------------===//

#include "EcoToLLVMInternal.h"
#include "../EcoDialect.h"
#include "../EcoOps.h"
#include "../Passes.h"

#include "mlir/Conversion/LLVMCommon/ConversionTarget.h"
#include "mlir/Conversion/FuncToLLVM/ConvertFuncToLLVM.h"
#include "mlir/Dialect/Arith/IR/Arith.h"
#include "mlir/Dialect/ControlFlow/IR/ControlFlow.h"
#include "mlir/Dialect/ControlFlow/IR/ControlFlowOps.h"
#include "mlir/Dialect/Func/IR/FuncOps.h"
#include "mlir/Dialect/Func/Transforms/FuncConversions.h"
#include "mlir/Dialect/SCF/IR/SCF.h"
#include "mlir/Dialect/SCF/Transforms/Patterns.h"
#include "mlir/Pass/Pass.h"
#include "mlir/Transforms/DialectConversion.h"

using namespace mlir;
using namespace eco;
using namespace eco::detail;

//===----------------------------------------------------------------------===//
// Pass Definition
//===----------------------------------------------------------------------===//

namespace {

struct EcoToLLVMPass : public PassWrapper<EcoToLLVMPass, OperationPass<ModuleOp>> {
    MLIR_DEFINE_EXPLICIT_INTERNAL_INLINE_TYPE_ID(EcoToLLVMPass)

    StringRef getArgument() const override { return "eco-to-llvm"; }

    StringRef getDescription() const override {
        return "Lower Eco dialect to LLVM dialect";
    }

    void getDependentDialects(DialectRegistry &registry) const override {
        registry.insert<LLVM::LLVMDialect, func::FuncDialect>();
    }

    void runOnOperation() override {
        ModuleOp module = getOperation();
        auto *ctx = &getContext();

        // Set up type converter for eco.value -> i64
        EcoTypeConverter typeConverter(ctx);

        // Set up conversion target
        ConversionTarget target(*ctx);
        target.addLegalDialect<LLVM::LLVMDialect>();
        target.addLegalDialect<arith::ArithDialect>();
        target.addLegalOp<ModuleOp>();

        // cf dialect is legal (branches will be type-converted if needed)
        target.addLegalDialect<cf::ControlFlowDialect>();

        // func dialect: convert to LLVM
        target.addIllegalOp<func::FuncOp>();
        target.addIllegalOp<func::CallOp>();
        target.addIllegalOp<func::ReturnOp>();

        // Mark all Eco dialect operations as illegal (to be lowered)
        target.addIllegalDialect<EcoDialect>();

        // Set up lowering patterns
        RewritePatternSet patterns(ctx);

        // Create runtime helper and control flow context
        EcoRuntime runtime(module);
        EcoCFContext cfCtx;
        cfCtx.clear();

        // Add kernel function lowering first (higher priority)
        populateEcoFuncPatterns(typeConverter, patterns);

        // Add func-to-llvm conversion patterns for non-kernel functions
        populateFuncToLLVMConversionPatterns(typeConverter, patterns);

        // Add call op conversion patterns
        populateCallOpTypeConversionPattern(patterns, typeConverter);

        // Add branch type conversion pattern
        populateBranchOpInterfaceTypeConversionPattern(patterns, typeConverter);

        // Add SCF structural type conversion patterns
        scf::populateSCFStructuralTypeConversionsAndLegality(typeConverter, patterns, target);

        // Add all ECO lowering patterns from modular files
        populateEcoTypePatterns(typeConverter, patterns, runtime);
        populateEcoHeapPatterns(typeConverter, patterns, runtime);
        populateEcoClosurePatterns(typeConverter, patterns, runtime);
        populateEcoControlFlowPatterns(typeConverter, patterns, runtime, cfCtx);
        populateEcoArithPatterns(typeConverter, patterns);
        populateEcoArithPatternsWithRuntime(typeConverter, patterns, runtime);
        populateEcoGlobalPatterns(typeConverter, patterns);
        populateEcoErrorDebugPatterns(typeConverter, patterns, runtime);

        // Apply the conversion patterns to the module
        if (failed(applyPartialConversion(module, target, std::move(patterns))))
            signalPassFailure();

        // Generate global root initialization function
        createGlobalRootInitFunction(module, runtime);
    }
};

} // namespace

//===----------------------------------------------------------------------===//
// Pass Registration
//===----------------------------------------------------------------------===//

std::unique_ptr<Pass> eco::createEcoToLLVMPass() {
    return std::make_unique<EcoToLLVMPass>();
}

std::unique_ptr<TypeConverter> eco::createEcoToLLVMTypeConverter(MLIRContext *ctx) {
    return std::make_unique<EcoTypeConverter>(ctx);
}

void eco::registerEcoPasses() {
    PassRegistration<EcoToLLVMPass>();
}
