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
#include "../BF/BFOps.h"
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

#include "llvm/Support/raw_ostream.h"

#include <chrono>
#include <cstdlib>

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

        // Env-gated sub-phase timers (ECO_ECO2LLVM_STATS). Passes have no
        // LoweringStats handle, so time the five serial stages of this pass
        // with steady_clock and print to llvm::errs(). Each ecoStageReport()
        // call measures wall time since the previous report (or since here)
        // and then resets the clock. Zero overhead when the env var is unset.
        const bool ecoStatsEnabled = ::getenv("ECO_ECO2LLVM_STATS") != nullptr;
        auto ecoStageClock = std::chrono::steady_clock::now();
        auto ecoStageReport = [&](const char *stageName) {
            if (!ecoStatsEnabled) return;
            auto now = std::chrono::steady_clock::now();
            double ms = std::chrono::duration<double, std::milli>(
                            now - ecoStageClock).count();
            llvm::errs() << "[eco-to-llvm] " << stageName << ": " << ms
                         << " ms\n";
            ecoStageClock = now;
        };


        // Set up type converter for eco.value -> i64
        EcoTypeConverter typeConverter(ctx);

        // Set up conversion target
        ConversionTarget target(*ctx);
        target.addLegalDialect<LLVM::LLVMDialect>();
        target.addLegalDialect<cf::ControlFlowDialect>();  // CF ops handled by later pass
        target.addLegalOp<ModuleOp>();
        target.addLegalOp<UnrealizedConversionCastOp>();  // Resolved by reconcile pass

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
                op->getParentOfType<scf::IndexSwitchOp>() ||
                op->getParentOfType<scf::WhileOp>()) {
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
                    caseOp->getParentOfType<scf::IndexSwitchOp>() ||
                    caseOp->getParentOfType<scf::WhileOp>()) {
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

        // Pre-scan all func::FuncOps to save original types before conversion.
        // This is needed because getOrCreateWrapper must distinguish primitive
        // params (Int i64) from !eco.value params (HPointer i64), but after
        // conversion both become LLVM i64 and the func::FuncOp is gone.
        // Also collect functions marked with eco.shadow_roots for the
        // post-conversion shadow root frame installation.
        llvm::DenseSet<llvm::StringRef> shadowRootFuncs;
        module.walk([&](func::FuncOp funcOp) {
            runtime.origFuncTypes[funcOp.getSymName()] = funcOp.getFunctionType();
            if (funcOp->hasAttr("eco.shadow_roots"))
                shadowRootFuncs.insert(funcOp.getSymName());
        });

        // NOTE: The papCreate/papExtend type-inference scan that was here
        // (Bug 8 fix) has been removed. It inferred kernel parameter types from
        // captured operand types and papExtend new-arg types for functions without
        // func::FuncOp declarations. This is no longer needed because:
        //
        // 1. The Elm compiler's registerKernelCall + generateKernelDecl pipeline
        //    emits func.func is_kernel declarations for ALL kernel functions,
        //    so origFuncTypes is populated from the func::FuncOp pre-scan above.
        //
        // 2. Hand-crafted test MLIR files that define evaluator functions as
        //    llvm.func (args-array convention) are handled by getOrCreateWrapper's
        //    usesArgsArrayConvention() check, which returns the function directly
        //    without consulting origFuncTypes.
        //
        // See: CGEN_057 invariant (Kernel Declaration Completeness).

        // Add kernel function lowering first (higher priority)
        populateEcoFuncPatterns(typeConverter, patterns, runtime);

        // Add func-to-llvm conversion patterns for non-kernel functions.
        // NOTE: MLIR's CallOpLowering does an O(N) symbol lookup per func.call
        // to check for the llvm.bareptr attribute. Since Eco never uses bare
        // pointer calling convention (no memref types), we can't pass a
        // SymbolTableCollection (it asserts on duplicate names during
        // applyFullConversion). Instead, we'll add our own call lowering below.
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
        // Phase 0 escape-analysis plumbing: value-level aggregate ops
        // (eco.make.*, eco.to_heap, eco.make.closure) and a parallel
        // higher-benefit project.closure pattern for !eco.closure_env.
        populateEcoValueAggPatterns(typeConverter, patterns, runtime);
        populateEcoControlFlowPatterns(typeConverter, patterns, runtime, cfCtx);
        populateEcoArithPatterns(typeConverter, patterns);
        populateEcoArithPatternsWithRuntime(typeConverter, patterns, runtime);
        populateEcoGlobalPatterns(typeConverter, patterns);
        populateEcoErrorDebugPatterns(typeConverter, patterns, runtime);

        ecoStageReport("1. pattern population/setup");

        // Lower allocation groups (eco.gc_group_size > 1) into fast/slow/merge
        // CFG before the per-op conversion patterns run. Group member ops are
        // erased; remaining singleton alloc ops are lowered by patterns below.
        lowerAllocGroups(module, runtime);
        ecoStageReport("2. lowerAllocGroups");

        // Apply the conversion patterns to the module
        // Use applyFullConversion to ensure all operations are legalized.
        // This is important because dynamic legality for CaseOp depends on
        // structural context that changes during conversion.
        if (failed(applyFullConversion(module, target, std::move(patterns))))
            signalPassFailure();
        ecoStageReport("3. applyFullConversion");

        // Single post-conversion walk over all LLVM functions: (1) set the GC
        // strategy so statepoint intrinsics are recognized, and (2) install
        // shadow-root frames for functions marked eco.shadow_roots. Fused from
        // two separate module.walk sweeps over the ~85k functions. The leading
        // external early-return covers both concerns exactly as before (walk 1
        // also gated on !isExternal; newly-created runtime decls are external
        // and were skipped by walk 2's guard too).
        module.walk([&](LLVM::LLVMFuncOp func) {
            if (func.isExternal())
                return;
            if (!func.getGarbageCollector())
                func.setGarbageCollector("eco-gc");
            if (!shadowRootFuncs.empty() &&
                shadowRootFuncs.contains(func.getSymName())) {
                OpBuilder builder(func.getContext());
                auto frame = installShadowRootPrologue(func, builder, runtime);
                if (frame.basePtr) {
                    for (auto &entry : frame.slotForArg)
                        rewriteUsesViaShadowSlot(frame, entry.first, builder);
                    emitShadowRootEpilogues(frame, func, builder, runtime);
                }
            }
        });

        ecoStageReport("4. GC-strategy + shadow-root walks");

        // Generate global root initialization function
        createGlobalRootInitFunction(module, runtime);
        ecoStageReport("5. createGlobalRootInitFunction");
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
