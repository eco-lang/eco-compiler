//===- EcoGCLivenessAudit.cpp - Post-EcoGCPrepare purity audit pass -------===//
//
// Debug-only verification pass, positioned in the pipeline immediately after
// EcoGCPrepare, before EcoToLLVM. It checks that no eco.call still carries
// the kernel-opt-12 purity attr (`eco.cse_safe`), which EcoGCPrepare strips.
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

struct EcoGCLivenessAuditPass
    : public PassWrapper<EcoGCLivenessAuditPass, OperationPass<func::FuncOp>> {

    MLIR_DEFINE_EXPLICIT_INTERNAL_INLINE_TYPE_ID(EcoGCLivenessAuditPass)

    StringRef getArgument() const override { return "eco-gc-liveness-audit"; }
    StringRef getDescription() const override {
        return "Verify that EcoGCPrepare stripped every eco.cse_safe "
               "purity attr (debug-only)";
    }

    void runOnOperation() override {
#ifndef ECO_LOWERING_VALIDATION
        return;
#else
        auto func = getOperation();
        if (func.isExternal()) return;

        bool hadError = false;

        // kernel-opt-12: purity attrs must not survive EcoGCPrepare. If one
        // does, a purity consumer has been ordered after the strip.
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
