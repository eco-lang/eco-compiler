//===- EcoTailConversions.cpp - Parallel per-function tail conversions ----===//
//
// STATUS: PARKED — NOT IN THE PIPELINE. Enabling this fused conversion caused
// memory corruption that surfaced as garbage reads in the JIT path (garbage
// std::function capture bytes in ecoc's runJIT; 176/288 codegen failures) even
// single-threaded, and the failure was Heisenbug-sensitive to unrelated stack
// layout. The safe subset shipped instead: EcoPipeline.cpp nests the STOCK
// SCFToControlFlow + ArithToLLVM passes on LLVM::LLVMFuncOp (verified: results
// byte-match the stock module-anchored pipeline on the codegen suite) and
// keeps cf->llvm module-anchored. Root-cause this before reviving (suspects:
// LLVMTypeConverter lifetime vs FrozenRewritePatternSet, or the combined
// pattern set's recursive legalization).
//
// Function-anchored replacement for the module-anchored conversion tail
// (SCFToControlFlow -> ControlFlowToLLVM -> ArithToLLVM). Anchoring on
// LLVM::LLVMFuncOp lets the pass manager run the whole conversion in parallel
// across the ~64k functions of a self-host module (OpToOpPassAdaptor sweeps
// anchor ops via the context thread pool), where the stock passes serialize on
// ModuleOp / whole-module anchors.
//
// Why a custom pass instead of nesting the stock ones:
//   - ConvertControlFlowToLLVMPass is ModuleOp-anchored ONLY because of its
//     cf.assert lowering (which inserts a module-level format-string global).
//     Eco never emits cf.assert, and MLIR deliberately exposes an assert-free
//     pattern set (cf::populateControlFlowToLLVMConversionPatterns) for exactly
//     this situation, so a function-anchored conversion is race-free.
//   - Fusing all three conversions into ONE applyPartialConversion per function
//     avoids two extra per-function pass invocations; the dialect-conversion
//     driver converts pattern-produced illegal ops recursively (scf.if ->
//     cf.cond_br -> llvm.cond_br in a single application).
//   - The LLVMTypeConverter + FrozenRewritePatternSet are built lazily ONCE
//     PER PASS CLONE (the pass manager clones the pipeline per worker thread;
//     each clone then runs single-threaded over many functions). The copy
//     constructor deliberately does NOT copy the built state: LLVMTypeConverter
//     mutates internal caches during conversion and is not thread-safe to
//     share, so a clone must never inherit the original's converter. (This is
//     unlike the Canonicalizer, whose shared FrozenRewritePatternSet is
//     immutable — sharing a *converter* across clones corrupts the heap.)
//
// A module-level ReconcileUnrealizedCastsPass still runs after this pass (see
// EcoPipeline.cpp): materialized casts are function-local, but reconcile also
// sweeps any module-scope regions for safety.
//
//===----------------------------------------------------------------------===//

#include "../Passes.h"

#include "mlir/Conversion/ArithToLLVM/ArithToLLVM.h"
#include "mlir/Conversion/ControlFlowToLLVM/ControlFlowToLLVM.h"
#include "mlir/Conversion/LLVMCommon/TypeConverter.h"
#include "mlir/Conversion/SCFToControlFlow/SCFToControlFlow.h"
#include "mlir/Dialect/Arith/IR/Arith.h"
#include "mlir/Dialect/ControlFlow/IR/ControlFlow.h"
#include "mlir/Dialect/LLVMIR/LLVMDialect.h"
#include "mlir/Dialect/SCF/IR/SCF.h"
#include "mlir/Pass/Pass.h"
#include "mlir/Transforms/DialectConversion.h"

#include <memory>

using namespace mlir;

namespace {

struct EcoTailConversionsPass
    : public PassWrapper<EcoTailConversionsPass,
                         OperationPass<LLVM::LLVMFuncOp>> {
    MLIR_DEFINE_EXPLICIT_INTERNAL_INLINE_TYPE_ID(EcoTailConversionsPass)

    EcoTailConversionsPass() = default;
    // Clones must NOT inherit the converter/patterns: the pass manager clones
    // this pass once per worker thread, and LLVMTypeConverter's internal
    // caches are mutated during conversion (not thread-safe to share). Each
    // clone lazily builds its own state on first use instead.
    EcoTailConversionsPass(const EcoTailConversionsPass &other)
        : PassWrapper(other) {}

    StringRef getArgument() const final { return "eco-tail-conversions"; }
    StringRef getDescription() const final {
        return "Per-function scf->cf->llvm + arith->llvm conversion "
               "(parallel across functions; assert-free cf lowering)";
    }

    void getDependentDialects(DialectRegistry &registry) const override {
        registry.insert<LLVM::LLVMDialect, cf::ControlFlowDialect>();
    }

    void runOnOperation() override {
        // Lazy per-clone state: this clone is only ever run by one thread at
        // a time (the adaptor gives each worker thread its own clone), so a
        // plain member build-once is race-free and amortizes converter +
        // pattern construction across the many functions this clone visits.
        if (!frozen) {
            MLIRContext *ctx = &getContext();
            converter = std::make_unique<LLVMTypeConverter>(ctx);
            RewritePatternSet patterns(ctx);
            populateSCFToControlFlowConversionPatterns(patterns);
            cf::populateControlFlowToLLVMConversionPatterns(*converter,
                                                            patterns);
            arith::populateArithToLLVMConversionPatterns(*converter, patterns);
            frozen =
                std::make_unique<FrozenRewritePatternSet>(std::move(patterns));
        }

        ConversionTarget target(getContext());
        target.addLegalDialect<LLVM::LLVMDialect>();
        target.addLegalOp<UnrealizedConversionCastOp>();
        target.addIllegalDialect<scf::SCFDialect>();
        target.addIllegalDialect<cf::ControlFlowDialect>();
        target.addIllegalDialect<arith::ArithDialect>();
        if (failed(applyPartialConversion(getOperation(), target, *frozen)))
            signalPassFailure();
    }

    std::unique_ptr<LLVMTypeConverter> converter;
    std::unique_ptr<FrozenRewritePatternSet> frozen;
};

} // namespace

namespace eco {

std::unique_ptr<mlir::Pass> createEcoTailConversionsPass() {
    return std::make_unique<EcoTailConversionsPass>();
}

} // namespace eco
