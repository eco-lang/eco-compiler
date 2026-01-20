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
#include "mlir/Conversion/SCFToControlFlow/SCFToControlFlow.h"
#include "mlir/Pass/Pass.h"
#include "mlir/Transforms/DialectConversion.h"

using namespace mlir;
using namespace eco;
using namespace eco::detail;

//===----------------------------------------------------------------------===//
// Arith Type Conversion Patterns
//===----------------------------------------------------------------------===//

namespace {

/// Pattern to type-convert arith.select operations.
/// This is needed when scf.if is lowered to arith.select but the types
/// still contain eco.value.
struct SelectOpTypeConversion : public OpConversionPattern<arith::SelectOp> {
    using OpConversionPattern::OpConversionPattern;

    LogicalResult
    matchAndRewrite(arith::SelectOp op, OpAdaptor adaptor,
                    ConversionPatternRewriter &rewriter) const override {
        // Get the converted result type
        Type resultType = getTypeConverter()->convertType(op.getResult().getType());
        if (!resultType)
            return failure();

        // Create a new select with converted types
        rewriter.replaceOpWithNewOp<arith::SelectOp>(
            op, resultType, adaptor.getCondition(),
            adaptor.getTrueValue(), adaptor.getFalseValue());
        return success();
    }
};

/// Pattern to type-convert scf.index_switch operations.
/// This handles the case where scf.index_switch has eco.value result types.
struct IndexSwitchOpTypeConversion : public OpConversionPattern<scf::IndexSwitchOp> {
    using OpConversionPattern::OpConversionPattern;

    LogicalResult
    matchAndRewrite(scf::IndexSwitchOp op, OpAdaptor adaptor,
                    ConversionPatternRewriter &rewriter) const override {
        // Convert result types
        SmallVector<Type> convertedTypes;
        if (failed(getTypeConverter()->convertTypes(op.getResultTypes(), convertedTypes)))
            return failure();

        // If types are already converted, no work to do
        if (convertedTypes == SmallVector<Type>(op.getResultTypes().begin(), op.getResultTypes().end()))
            return failure();

        auto loc = op.getLoc();

        // Create new index_switch with converted result types
        // Note: Use original arg (not adaptor) because scf.index_switch requires index type
        auto newOp = rewriter.create<scf::IndexSwitchOp>(
            loc, convertedTypes, op.getArg(), op.getCases(), op.getCases().size());

        // Move the case regions from old op to new op
        for (auto [oldRegion, newRegion] : llvm::zip(op.getCaseRegions(), newOp.getCaseRegions())) {
            rewriter.inlineRegionBefore(oldRegion, newRegion, newRegion.end());
        }

        // Move the default region
        rewriter.inlineRegionBefore(op.getDefaultRegion(), newOp.getDefaultRegion(),
                                    newOp.getDefaultRegion().end());

        // Replace uses with converted results
        rewriter.replaceOp(op, newOp.getResults());
        return success();
    }
};

/// Pattern to type-convert scf.yield operations inside index_switch.
struct YieldOpTypeConversion : public OpConversionPattern<scf::YieldOp> {
    using OpConversionPattern::OpConversionPattern;

    LogicalResult
    matchAndRewrite(scf::YieldOp op, OpAdaptor adaptor,
                    ConversionPatternRewriter &rewriter) const override {
        // Only convert yields inside index_switch
        if (!op->getParentOfType<scf::IndexSwitchOp>())
            return failure();

        // If operands are already converted (through adaptor), just create new yield
        rewriter.replaceOpWithNewOp<scf::YieldOp>(op, adaptor.getOperands());
        return success();
    }
};

} // namespace

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
        target.addLegalDialect<cf::ControlFlowDialect>();  // CF ops handled by later pass
        target.addLegalOp<ModuleOp>();

        // Arith ops are dynamically legal: only if they don't contain eco.value types.
        // This ensures arith.select gets type-converted.
        target.addDynamicallyLegalDialect<arith::ArithDialect>(
            [&](Operation *op) {
                for (auto operand : op->getOperands()) {
                    if (isa<eco::ValueType>(operand.getType()))
                        return false;
                }
                for (auto result : op->getResults()) {
                    if (isa<eco::ValueType>(result.getType()))
                        return false;
                }
                return true;
            });

        // CF ops are dynamically legal: only if they don't contain eco.value types.
        // This ensures the branch type conversion patterns convert CF ops with eco types.
        target.addDynamicallyLegalDialect<cf::ControlFlowDialect>(
            [&](Operation *op) {
                // Check if any operand or result has eco.value type
                for (auto operand : op->getOperands()) {
                    if (isa<eco::ValueType>(operand.getType()))
                        return false;
                }
                for (auto result : op->getResults()) {
                    if (isa<eco::ValueType>(result.getType()))
                        return false;
                }
                // Check block argument types for branch ops
                if (auto branchOp = dyn_cast<BranchOpInterface>(op)) {
                    for (auto successorIdx : llvm::seq<unsigned>(0, op->getNumSuccessors())) {
                        Block *successor = op->getSuccessor(successorIdx);
                        for (auto arg : successor->getArguments()) {
                            if (isa<eco::ValueType>(arg.getType()))
                                return false;
                        }
                    }
                }
                return true;
            });

        // func dialect: convert to LLVM
        target.addIllegalOp<func::FuncOp>();
        target.addIllegalOp<func::CallOp>();
        target.addIllegalOp<func::ReturnOp>();

        // Mark all Eco dialect operations as illegal (to be lowered)
        target.addIllegalDialect<EcoDialect>();

        // Override for CaseOp: temporarily legal when nested under SCF.
        // This defers CaseOpLowering until SCF regions are converted to CF,
        // preventing the creation of multiple blocks inside SCF single-block regions.
        target.addDynamicallyLegalOp<CaseOp>([](CaseOp op) {
            // If nested under SCF, treat as temporarily legal (don't convert yet)
            if (op->getParentOfType<scf::IfOp>() ||
                op->getParentOfType<scf::IndexSwitchOp>()) {
                return true;
            }
            // Otherwise, require conversion (illegal)
            return false;
        });

        // Also defer ReturnOp conversion when inside a CaseOp that's inside SCF.
        // This prevents eco.return from being converted to llvm.return while the
        // parent eco.case is still temporarily legal (which would cause a verifier error).
        target.addDynamicallyLegalOp<ReturnOp>([](ReturnOp op) {
            // Check if we're inside a CaseOp that's inside SCF
            if (auto caseOp = op->getParentOfType<CaseOp>()) {
                if (caseOp->getParentOfType<scf::IfOp>() ||
                    caseOp->getParentOfType<scf::IndexSwitchOp>()) {
                    return true;  // Legal for now
                }
            }
            // Otherwise, require conversion (illegal)
            return false;
        });

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
        // This adds patterns to convert SCF ops' types and marks SCF ops as dynamically legal.
        scf::populateSCFStructuralTypeConversionsAndLegality(typeConverter, patterns, target);

        // Override: SCF must be fully eliminated, not just type-converted.
        // This ensures SCF-to-CF patterns run to completion.
        target.addIllegalDialect<scf::SCFDialect>();

        // scf.index_switch is dynamically legal: legal only when its result types
        // are already converted (not !eco.value). This allows the type conversion
        // patterns to run first, converting the yield types inside.
        target.addDynamicallyLegalOp<scf::IndexSwitchOp>([](scf::IndexSwitchOp op) {
            // Legal if no result types are eco.value
            for (Type t : op.getResultTypes()) {
                if (isa<eco::ValueType>(t))
                    return false;
            }
            return true;
        });

        // scf.yield is dynamically legal based on its operand types
        target.addDynamicallyLegalOp<scf::YieldOp>([](scf::YieldOp op) {
            for (Value operand : op.getOperands()) {
                if (isa<eco::ValueType>(operand.getType()))
                    return false;
            }
            return true;
        });

        // Add SCF-to-CF lowering patterns (for scf.if, scf.while, etc.)
        // Note: scf.index_switch is intentionally NOT lowered here.
        populateSCFToControlFlowConversionPatterns(patterns);

        // Add arith type conversion pattern for select ops
        // (needed when scf.if is lowered to arith.select with eco.value types)
        patterns.add<SelectOpTypeConversion>(typeConverter, ctx);

        // Add SCF type conversion patterns for index_switch
        // (needed because scf::populateSCFStructuralTypeConversionsAndLegality
        // doesn't handle index_switch type conversion)
        patterns.add<IndexSwitchOpTypeConversion>(typeConverter, ctx);
        patterns.add<YieldOpTypeConversion>(typeConverter, ctx);

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
        // Use applyFullConversion to ensure all operations are legalized.
        // This is important because dynamic legality for CaseOp depends on
        // structural context that changes during conversion.
        if (failed(applyFullConversion(module, target, std::move(patterns))))
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
