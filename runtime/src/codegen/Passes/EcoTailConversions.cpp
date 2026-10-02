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
#include "mlir/Transforms/DialectConversion.h"

#include <atomic>
#include <memory>

using namespace mlir;

namespace {

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

            SmallVector<UnrealizedConversionCastOp> casts;
            for (size_t i = lo; i < hi; ++i) {
                Operation *f = funcs[i];
                if (failed(applyPartialConversion(f, scfTarget, scfFrozen)) ||
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
