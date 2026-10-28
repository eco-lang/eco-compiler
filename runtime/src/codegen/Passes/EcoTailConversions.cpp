//===- EcoTailConversions.cpp - Chunked parallel tail conversions ---------===//
//
// After EcoToLLVM, LLVM-dialect function bodies can still hold scf, cf and arith ops, and unrealized casts left
// between the types of earlier conversions. This pass lowers those ops to the LLVM dialect and removes the casts.
// It does the work of the upstream SCFToControlFlow, ArithToLLVM, ControlFlowToLLVM and ReconcileUnrealizedCasts
// passes in one module pass. Only `llvm.func` bodies are converted; in other top-level ops only casts are
// reconciled.
//
// Each `llvm.func` with a body is converted on its own, and functions are split into chunks that run in parallel
// under MLIR's thread pool. A chunk builds its own type converter, pattern sets and conversion targets, and the
// pass struct has no data members, so no conversion state is shared between threads or kept between chunks.
//
// Per function there are three steps:
//   1. scf to cf, with the upstream SCFToControlFlow patterns and target. The patterns are applied directly by a
//      `PatternRewriter`, not by the conversion driver; see `lowerScfToCf` for why and for when it falls back.
//   2. arith and cf to LLVM, in one partial conversion under `LLVMConversionTarget` with the default
//      `LowerToLLVMOptions`.
//   3. Reconciliation of the function's unrealized casts. A cast's operands and results are SSA values, which do
//      not cross functions, so this is done per function. Casts in top-level ops that are not functions are
//      reconciled afterwards, serially.
//
// The cf patterns do not include the one for `cf.assert`, which needs a module-level global. A `cf.assert` is
// not legalized here and is left in place.
//
//===----------------------------------------------------------------------===//

#include "../Passes.h"

#include "mlir/Conversion/ArithToLLVM/ArithToLLVM.h"
#include "mlir/Conversion/ControlFlowToLLVM/ControlFlowToLLVM.h"
#include "mlir/Conversion/LLVMCommon/ConversionTarget.h"
#include "mlir/Conversion/LLVMCommon/TypeConverter.h"
#include "mlir/Conversion/SCFToControlFlow/SCFToControlFlow.h"
#include "mlir/Dialect/Arith/IR/Arith.h"
#include "mlir/Dialect/ControlFlow/IR/ControlFlow.h"
#include "mlir/Dialect/LLVMIR/LLVMDialect.h"
#include "mlir/Dialect/SCF/IR/SCF.h"
#include "mlir/IR/Threading.h"
#include "mlir/Pass/Pass.h"
#include "mlir/Rewrite/PatternApplicator.h"
#include "mlir/Transforms/DialectConversion.h"

#include <atomic>
#include <memory>

using namespace mlir;

namespace {

/// Returns whether `op` is one of the scf ops that step 1 lowers to cf.
bool isScfToLower(Operation *op) {
    return isa<scf::ForallOp, scf::ForOp, scf::IfOp, scf::IndexSwitchOp,
               scf::ParallelOp, scf::WhileOp, scf::ExecuteRegionOp>(op);
}

/// Appends to `out` every scf op to lower that is nested anywhere under `op`, not including `op` itself.
///
/// A parent comes before the ops nested in it, and ops in the same block come last first. `lowerScfToCf` relies
/// on that order.
void collectScfOps(Operation *op, SmallVectorImpl<Operation *> &out) {
    for (Region &r : op->getRegions())
        for (Block &b : r)
            for (Operation &o : llvm::reverse(b)) {
                if (isScfToLower(&o))
                    out.push_back(&o);
                if (o.getNumRegions())
                    collectScfOps(&o, out);
            }
}

/// Lowers every scf op in function `f` to cf, and returns failure if one could not be lowered.
///
/// `applicator` must hold `frozen`, the SCFToControlFlow patterns, and `rewriter` must have no listener. `target`
/// and `frozen` are what the conversion driver uses when this falls back to it. `ops` is scratch storage and is
/// overwritten.
///
/// The patterns are applied without the conversion driver because its rewriter always has a listener, and with
/// a listener each block split moves the ops after the split point one at a time. A listener-free split is a
/// single list splice. Each lowering splits the op's block at the op and inlines its regions before the
/// continuation, so the pointers collected up front stay valid. Parents are lowered before their children
/// because a parent's pattern may expect its regions' blocks to still end in `scf.yield`. Siblings are lowered
/// last first so that each split moves only the ops up to the next sibling, which is already lowered.
///
/// The function is handed to `applyPartialConversion` instead in two cases: a fold that replaces an op, which
/// would erase nested ops still on the list, and scf ops left after the pass over the list, such as ones a
/// pattern created.
LogicalResult lowerScfToCf(Operation *f, PatternApplicator &applicator,
                           PatternRewriter &rewriter,
                           SmallVectorImpl<Operation *> &ops,
                           const ConversionTarget &target,
                           const FrozenRewritePatternSet &frozen) {
    ops.clear();
    collectScfOps(f, ops);
    if (ops.empty())
        return success();
    SmallVector<OpFoldResult> folded;
    for (Operation *op : ops) {
        // Fold first, as the conversion driver does before applying patterns: scf.if's folder rewrites
        // `if (xor c, true)` into `if c` in place. Repeat while it folds in place.
        for (unsigned n = 0; n < 8; ++n) {
            folded.clear();
            if (failed(op->fold(folded)))
                break;
            if (!folded.empty())
                return applyPartialConversion(f, target, frozen);
        }
        rewriter.setInsertionPoint(op);
        if (failed(applicator.matchAndRewrite(op, rewriter)))
            return op->emitError("eco-tail-conversions: no scf->cf lowering");
    }
    bool remaining = false;
    f->walk([&](Operation *op) {
        if (isScfToLower(op)) {
            remaining = true;
            return WalkResult::interrupt();
        }
        return WalkResult::advance();
    });
    if (remaining)
        return applyPartialConversion(f, target, frozen);
    return success();
}

/// The pass created by `createEcoTailConversionsPass`, registered as `eco-tail-conversions`.
struct EcoTailConversionsPass
    : public PassWrapper<EcoTailConversionsPass, OperationPass<ModuleOp>> {
    MLIR_DEFINE_EXPLICIT_INTERNAL_INLINE_TYPE_ID(EcoTailConversionsPass)

    StringRef getArgument() const final { return "eco-tail-conversions"; }
    StringRef getDescription() const final {
        return "Chunked parallel scf->cf, then arith+cf->llvm, per function";
    }

    void getDependentDialects(DialectRegistry &registry) const override {
        registry.insert<LLVM::LLVMDialect, cf::ControlFlowDialect>();
    }

    void runOnOperation() override {
        ModuleOp module = getOperation();
        MLIRContext *ctx = &getContext();

        SmallVector<LLVM::LLVMFuncOp> funcs;
        for (LLVM::LLVMFuncOp f : module.getOps<LLVM::LLVMFuncOp>())
            if (!f.isExternal())
                funcs.push_back(f);
        if (funcs.empty())
            return;

        // Several chunks per thread: function sizes vary widely, so many
        // small chunks keep the pool busy until the end.
        const size_t nChunks = std::max<size_t>(
            1, std::min<size_t>(funcs.size(), 8 * ctx->getNumThreads()));
        std::atomic<bool> failedAny{false};

        auto convertChunk = [&](size_t c) {
            size_t lo = funcs.size() * c / nChunks;
            size_t hi = funcs.size() * (c + 1) / nChunks;

            // Step 1 state: the target and patterns of the upstream SCFToControlFlow pass.
            RewritePatternSet scfPatterns(ctx);
            populateSCFToControlFlowConversionPatterns(scfPatterns);
            FrozenRewritePatternSet scfFrozen(std::move(scfPatterns));
            ConversionTarget scfTarget(*ctx);
            scfTarget.addIllegalOp<scf::ForallOp, scf::ForOp, scf::IfOp,
                                   scf::IndexSwitchOp, scf::ParallelOp,
                                   scf::WhileOp, scf::ExecuteRegionOp>();
            scfTarget.markUnknownOpDynamicallyLegal(
                [](Operation *) { return true; });

            // Step 2 state: no index-bitwidth override, as in both upstream passes.
            LowerToLLVMOptions options(ctx);
            LLVMTypeConverter converter(ctx, options);
            RewritePatternSet llvmPatterns(ctx);
            arith::populateArithToLLVMConversionPatterns(converter,
                                                         llvmPatterns);
            cf::populateControlFlowToLLVMConversionPatterns(converter,
                                                            llvmPatterns);
            FrozenRewritePatternSet llvmFrozen(std::move(llvmPatterns));
            LLVMConversionTarget llvmTarget(*ctx);

            PatternApplicator scfApplicator(scfFrozen);
            scfApplicator.applyDefaultCostModel();
            PatternRewriter scfRewriter(ctx);
            SmallVector<Operation *> scfOps;

            SmallVector<UnrealizedConversionCastOp> casts;
            for (size_t i = lo; i < hi; ++i) {
                Operation *f = funcs[i];
                if (failed(lowerScfToCf(f, scfApplicator, scfRewriter, scfOps,
                                        scfTarget, scfFrozen)) ||
                    failed(applyPartialConversion(f, llvmTarget, llvmFrozen))) {
                    failedAny = true;
                    return;
                }
                // Cast chains are SSA values, so they do not cross functions.
                casts.clear();
                f->walk([&](UnrealizedConversionCastOp c) { casts.push_back(c); });
                if (!casts.empty())
                    reconcileUnrealizedCasts(casts);
            }
        };

        if (ctx->isMultithreadingEnabled()) {
            parallelFor(ctx, 0, nChunks, convertChunk);
        } else {
            for (size_t c = 0; c < nChunks; ++c)
                convertChunk(c);
        }
        if (failedAny) {
            signalPassFailure();
            return;
        }

        // Casts outside function bodies, such as in global initializers.
        SmallVector<UnrealizedConversionCastOp> rest;
        for (Operation &top : *module.getBody())
            if (!isa<LLVM::LLVMFuncOp>(top))
                top.walk([&](UnrealizedConversionCastOp c) { rest.push_back(c); });
        if (!rest.empty())
            reconcileUnrealizedCasts(rest);
    }
};

} // namespace

namespace eco {

std::unique_ptr<mlir::Pass> createEcoTailConversionsPass() {
    return std::make_unique<EcoTailConversionsPass>();
}

} // namespace eco
