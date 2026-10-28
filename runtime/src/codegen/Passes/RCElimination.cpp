//===- RCElimination.cpp - Reject reference counting operations -----------===//
//
// The eco dialect has reference-counting ops (`eco.incref`, `eco.decref`,
// `eco.decref_shallow`, `eco.free`, `eco.reset`, `eco.reset_ref`), but the
// backend manages memory with a tracing garbage collector and lowers none of
// them. This pass is the check that none reaches it. Despite its name, it
// changes nothing in the IR.
//
//===----------------------------------------------------------------------===//

#include "mlir/Pass/Pass.h"
#include "mlir/IR/BuiltinOps.h"
#include "mlir/IR/PatternMatch.h"
#include "mlir/Transforms/DialectConversion.h"
#include "mlir/Dialect/Func/IR/FuncOps.h"

#include "../EcoDialect.h"
#include "../EcoOps.h"
#include "../Passes.h"

using namespace mlir;
using namespace ::eco;

namespace {

/// The `eco-rc-elimination` module pass, whose contract is on
/// `eco::createRCEliminationPass` in `Passes.h`.
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

        // The variadic isa<> rejects the common non-RC op before the per-op
        // message dispatch.
        module.walk([&](Operation *op) {
            if (!isa<IncrefOp, DecrefOp, DecrefShallowOp, FreeOp, ResetOp,
                     ResetRefOp>(op))
                return;
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
