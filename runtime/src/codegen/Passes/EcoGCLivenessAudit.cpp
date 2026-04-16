//===- EcoGCLivenessAudit.cpp - GC root set verification pass -------------===//
//
// Debug-only verification pass that recomputes SSA liveness of !eco.value
// values inside each function and, for every op implementing
// eco::GCRootCarrier, diagnoses any value that is semantically live across
// the op but missing from the op's attached GC root set.
//
// Positioned in the pipeline immediately after EcoGCPrepare, before
// EcoToLLVM. Acts as a backstop verifying that EcoGCPrepare's root sets
// correctly reflect SSA liveness.
//
//===----------------------------------------------------------------------===//

#include "EcoGCLiveness.h"
#include "../EcoDialect.h"
#include "../EcoOps.h"
#include "../EcoTypes.h"
#include "../Passes.h"

#include "mlir/Analysis/Liveness.h"
#include "mlir/Dialect/Func/IR/FuncOps.h"
#include "mlir/IR/BuiltinOps.h"
#include "mlir/Pass/Pass.h"

#include "llvm/ADT/DenseSet.h"

using namespace mlir;

namespace {

struct EcoGCLivenessAuditPass
    : public PassWrapper<EcoGCLivenessAuditPass, OperationPass<func::FuncOp>> {

    MLIR_DEFINE_EXPLICIT_INTERNAL_INLINE_TYPE_ID(EcoGCLivenessAuditPass)

    StringRef getArgument() const override { return "eco-gc-liveness-audit"; }
    StringRef getDescription() const override {
        return "Verify GC root sets attached by EcoGCPrepare against SSA "
               "liveness of !eco.value values (debug-only)";
    }

    void runOnOperation() override {
#ifndef ECO_GC_DEBUG_LIVENESS
        return;
#else
        auto func = getOperation();
        if (func.isExternal()) return;
        Liveness liveness(func);

        bool hadError = false;
        func.walk([&](Operation *op) {
            auto carrier = dyn_cast<eco::GCRootCarrier>(op);
            if (!carrier) return;

            // Skip ops inside nested regions (scf.while/scf.if bodies).
            // EcoGCPrepare's per-block Liveness is blind to cross-iteration
            // uses of values captured into nested regions, and it works
            // around this by unioning the front-end's operand list — a
            // workaround the audit cannot replicate. Avoid false positives.
            // TODO: future region-aware coverage.
            if (op->getParentRegion() != &func.getBody())
                return;

            // Recompute what should be live at this op (mirrors
            // EcoGCPrepare::computeLiveRoots).
            auto shouldBeLive = eco::computeLiveRoots(liveness, op);

            // Union with op's own !eco.value operands — required for ops
            // whose lowering expands into alloc + separate field stores
            // (construct.record/custom). EcoGCPrepare does this same union
            // for alloc group leaders; we must do it here for parity.
            {
                llvm::DenseSet<Value> already(shouldBeLive.begin(),
                                              shouldBeLive.end());
                for (Value v : op->getOperands()) {
                    if (eco::isEcoValue(v) && already.insert(v).second)
                        shouldBeLive.push_back(v);
                }
            }

            // Compare against attached roots.
            ValueRange roots = carrier.getGCRoots();
            llvm::DenseSet<Value> rootSet(roots.begin(), roots.end());

            // Collect missing values first, then emit one diagnostic per op.
            SmallVector<Value, 4> missing;
            for (Value v : shouldBeLive) {
                if (!rootSet.count(v))
                    missing.push_back(v);
            }
            if (missing.empty()) return;

            auto funcOp = op->getParentOfType<func::FuncOp>();
            llvm::errs() << "[gc-liveness-audit] FAIL in func="
                         << (funcOp ? funcOp.getName() : StringRef("?"))
                         << " op=" << op->getName()
                         << " at " << op->getLoc()
                         << " — " << missing.size()
                         << " missing root(s) out of "
                         << shouldBeLive.size() << " expected\n";
            for (Value v : missing) {
                llvm::errs() << "  MISSING: " << v << "\n";
            }
            llvm::errs() << "  ATTACHED (" << roots.size() << "):";
            for (Value r : roots)
                llvm::errs() << " " << r;
            llvm::errs() << "\n";

            op->emitError("[gc-liveness-audit] value live across this GC "
                          "root carrier but missing from its GC root set");
            hadError = true;
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
