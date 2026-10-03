//===- EcoTailConversions.cpp - Chunked parallel tail conversions ---------===//
//
// The conversion tail of the eco pipeline. It runs after EcoToLLVM and
// EcoListCursor, replacing three upstream passes:
//   - SCFToControlFlowPass and ArithToLLVMConversionPass, which used to be
//     nested on llvm.func;
//   - ConvertControlFlowToLLVMPass, which used to be module-anchored and
//     serial.
// See plans/backend-lowering-optimization.md step B2.
//
// Why this exists:
//   - The nested form cost about 98k x 2 pass-manager invocations. Each one
//     rebuilt a type converter, a pattern set and a conversion target, and
//     about 40 % of them ran on wrappers or declarations.
//   - cf->llvm ran serially over the whole module.
//
// This pass is ModuleOp-anchored and does the same per-function work as
// those three passes, IN PARALLEL over chunks of functions:
//   - Each chunk builds ONE LLVMTypeConverter and frozen pattern sets on its
//     own stack. No conversion state outlives its chunk or is shared between
//     threads.
//   - Per function, step 1 is SCF -> CF, using exactly the upstream
//     SCFToControlFlowPass target and patterns.
//   - Per function, step 2 is Arith + CF -> LLVM in ONE partial conversion,
//     using the upstream patterns under LLVMConversionTarget. Both sets are
//     1:1 op conversions.
//
// HISTORY, read before changing:
//   - A previous version of this file fused all three conversions into a
//     single applyPartialConversion. It kept its converter per pass CLONE.
//   - It corrupted memory, Heisenbug-style, even single-threaded, and was
//     parked. That design is gone.
//   - What is different here: SCF->CF is a separate conversion; nothing lives
//     in pass members; state is scoped to the chunk lambda.
//
// cf.assert is NOT lowered: its pattern needs a module-level global. Eco
// never emits cf.assert (audited for the July tuning work). If one ever
// appears it stays illegal and fails the module verifier loudly.
//
// Casts are reconciled here too: per function inside the chunks, then
// serially for any non-function top-level op (ReconcileUnrealizedCastsPass is
// no longer in the pipeline).
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

bool isScfToLower(Operation *op) {
    return isa<scf::ForallOp, scf::ForOp, scf::IfOp, scf::IndexSwitchOp,
               scf::ParallelOp, scf::WhileOp, scf::ExecuteRegionOp>(op);
}

/// SCF -> CF for one function with the upstream SCFToControlFlow patterns,
/// applied by a listener-free rewriter (see the loop for the order). Each
/// pattern is a plain OpRewritePattern that only splits the op's block and
/// inlines its regions, so the pointers collected up front stay valid. Patterns
/// that would create NEW scf ops (forall/parallel lowering) are not expected
/// in eco output; if any remains, the function falls back to the conversion
/// driver, which handles it as it always did.
/// Parents before children (a parent pattern may expect its regions' front
/// block to still end in scf.yield), but siblings in one block LAST-FIRST.
/// Each lowering is local — split the op's block at the op, inline its
/// regions before the continuation — so sibling order does not change the
/// final block layout (byte-identical output, checked), but a split then
/// moves only the ops up to the next, already-lowered sibling: linear
/// instead of O(#ifs x block length) parent-pointer updates (the 0.4 s
/// single-thread tail left after the listener fix).
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
        // Fold first, as the conversion driver legalizes an illegal op
        // (DialectConversionFoldingMode::BeforePatterns): scf.if's folder
        // swaps `if (xor c, true)` into `if c` IN PLACE. Repeat while it
        // folds in place. A replacing fold (none is expected for these ops)
        // would erase nested ops still on the list, so hand the rest of the
        // function to the conversion driver instead.
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

            // Step 1 state: exactly SCFToControlFlowPass's target + patterns.
            RewritePatternSet scfPatterns(ctx);
            populateSCFToControlFlowConversionPatterns(scfPatterns);
            FrozenRewritePatternSet scfFrozen(std::move(scfPatterns));
            ConversionTarget scfTarget(*ctx);
            scfTarget.addIllegalOp<scf::ForallOp, scf::ForOp, scf::IfOp,
                                   scf::IndexSwitchOp, scf::ParallelOp,
                                   scf::WhileOp, scf::ExecuteRegionOp>();
            scfTarget.markUnknownOpDynamicallyLegal(
                [](Operation *) { return true; });

            // Step 2 state: Arith + CF -> LLVM under LLVMConversionTarget,
            // with the default LowerToLLVMOptions (same as both upstream
            // passes with no index-bitwidth override).
            LowerToLLVMOptions options(ctx);
            LLVMTypeConverter converter(ctx, options);
            RewritePatternSet llvmPatterns(ctx);
            arith::populateArithToLLVMConversionPatterns(converter,
                                                         llvmPatterns);
            cf::populateControlFlowToLLVMConversionPatterns(converter,
                                                            llvmPatterns);
            FrozenRewritePatternSet llvmFrozen(std::move(llvmPatterns));
            LLVMConversionTarget llvmTarget(*ctx);

            // Plan 07 P4: step 1 applies the SAME patterns without the
            // conversion driver. A ConversionPatternRewriter always has a
            // listener, so every splitBlock moved the rest of the block one
            // op at a time and recorded each move; a block with k scf.ifs and
            // n ops cost O(k*n) recorded moves (~1,000 string-literal
            // diamonds in one 34k-op block = a 1.4 s single-thread tail).
            // A listener-free PatternRewriter splits with one ilist splice.
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
                // Reconcile this function's casts here, in parallel: cast
                // chains are SSA values, so they never cross functions
                // (replaces the serial ReconcileUnrealizedCastsPass sweep).
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

        // Casts outside function bodies (global initializers), serially.
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
