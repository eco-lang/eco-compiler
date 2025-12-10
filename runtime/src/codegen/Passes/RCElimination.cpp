//===- RCElimination.cpp - Remove reference counting placeholders ---------===//
//
// This pass removes or errors on reference counting placeholder operations
// (incref, decref, free, reset, reset_ref). These operations are not used in
// tracing GC mode and should not appear in the IR after this pass.
//
//===----------------------------------------------------------------------===//

#include "mlir/Pass/Pass.h"
#include "mlir/IR/BuiltinOps.h"
#include "mlir/IR/PatternMatch.h"
#include "mlir/Transforms/DialectConversion.h"

#include "../EcoDialect.h"
#include "../EcoOps.h"
#include "../Passes.h"

using namespace mlir;
using namespace ::eco;

namespace {

struct RCEliminationPass
    : public PassWrapper<RCEliminationPass, OperationPass<ModuleOp>> {
    MLIR_DEFINE_EXPLICIT_INTERNAL_INLINE_TYPE_ID(RCEliminationPass)

    StringRef getArgument() const override { return "eco-rc-elimination"; }

    StringRef getDescription() const override {
        return "Remove reference counting placeholder operations";
    }

    void runOnOperation() override {
        ModuleOp module = getOperation();
        bool hasErrors = false;

        // Walk the module and check for reference counting operations.
        // These should not appear in IR that targets tracing GC.
        module.walk([&](Operation *op) {
            if (isa<IncrefOp>(op)) {
                op->emitError("eco.incref is not supported in tracing GC mode");
                hasErrors = true;
            } else if (isa<DecrefOp>(op)) {
                op->emitError("eco.decref is not supported in tracing GC mode");
                hasErrors = true;
            } else if (isa<DecrefShallowOp>(op)) {
                op->emitError("eco.decref_shallow is not supported in tracing GC mode");
                hasErrors = true;
            } else if (isa<FreeOp>(op)) {
                op->emitError("eco.free is not supported in tracing GC mode");
                hasErrors = true;
            } else if (isa<ResetOp>(op)) {
                op->emitError("eco.reset is not supported in tracing GC mode");
                hasErrors = true;
            } else if (isa<ResetRefOp>(op)) {
                op->emitError("eco.reset_ref is not supported in tracing GC mode");
                hasErrors = true;
            }
        });

        if (hasErrors)
            signalPassFailure();
    }
};

} // namespace

std::unique_ptr<Pass> eco::createRCEliminationPass() {
    return std::make_unique<RCEliminationPass>();
}
