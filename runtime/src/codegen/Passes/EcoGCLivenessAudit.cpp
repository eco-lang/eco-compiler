//===- EcoGCLivenessAudit.cpp - Post-EcoGCPrepare purity audit pass -------===//
//
// The pipeline runs this pass directly after EcoGCPrepare, with no pass
// between, so an `eco.call` still carrying `eco.cse_safe` here means
// EcoGCPrepare failed to strip it. No other pass has run yet to add it back.
// The pass checks nothing about liveness, despite its name.
//
//===----------------------------------------------------------------------===//

#include "../EcoDialect.h"
#include "../EcoOps.h"
#include "../Passes.h"

#include "mlir/Dialect/Func/IR/FuncOps.h"
#include "mlir/IR/BuiltinOps.h"
#include "mlir/Pass/Pass.h"

using namespace mlir;

namespace {

/**
 * The per-function pass that reports each `eco.call` still carrying
 * `eco.cse_safe` as an error and then fails.
 */
struct EcoGCLivenessAuditPass
    : public PassWrapper<EcoGCLivenessAuditPass, OperationPass<func::FuncOp>> {

    MLIR_DEFINE_EXPLICIT_INTERNAL_INLINE_TYPE_ID(EcoGCLivenessAuditPass)

    StringRef getArgument() const override { return "eco-gc-liveness-audit"; }
    StringRef getDescription() const override {
        return "Verify that EcoGCPrepare stripped every eco.cse_safe "
               "purity attr (debug-only)";
    }

    // Skips external functions. Without `ECO_LOWERING_VALIDATION` it returns
    // at once.
    void runOnOperation() override {
#ifndef ECO_LOWERING_VALIDATION
        return;
#else
        auto func = getOperation();
        if (func.isExternal()) return;

        bool hadError = false;

        func.walk([&](eco::CallOp call) {
            if (call->hasAttr(eco::kCseSafeAttrName)) {
                call->emitError("[gc-purity] 'eco.cse_safe' survived "
                                "EcoGCPrepare — a purity consumer is "
                                "mis-ordered in the pipeline");
                hadError = true;
            }
        });

        if (hadError) signalPassFailure();
#endif
    }
};

} // namespace

//===----------------------------------------------------------------------===//
// Pass Creation
//===----------------------------------------------------------------------===//

std::unique_ptr<Pass> eco::createEcoGCLivenessAuditPass() {
    return std::make_unique<EcoGCLivenessAuditPass>();
}
