//===- EcoEscapeAnalysis.cpp - Escape analysis for value aggregates -------===//
//
// Phase 1: per-function escape analysis for small-aggregate `eco.construct.*`
// ops (Tuple2/Tuple3 only in this phase). Classifies each construct op's
// result as either `non_escaping` (every use is a known projection on the
// same value) or `escapes` (anything else — call, return, store, capture,
// case, etc.). The classification is recorded as a string attribute
// `eco.escape` on the construct op so the specialise pass can act on it
// without re-walking uses.
//
// Conservative rules:
//   - A use is NON-escaping iff:
//       * user is eco.project.tuple2 / eco.project.tuple3, AND
//       * the operand position is the `tuple` operand (operand 0).
//   - Anything else is escaping. In particular:
//       * any other op (eco.construct.*, eco.allocate_*, eco.box,
//         eco.store_global, eco.return, eco.yield, eco.case, eco.call,
//         eco.papCreate, eco.papExtend, ...);
//       * the construct op's result being a function return value;
//       * being passed as an `eco.project.tuple2` operand at a position
//         other than `tuple` (defensive — shouldn't happen in well-typed
//         IR, but we don't want to silently misclassify).
//
// This pass must run BEFORE EcoGCPrepare so the construct op's operand
// list is just `[a, b, ... ]` (no GC roots appended yet).
//
//===----------------------------------------------------------------------===//

#include "../EcoDialect.h"
#include "../EcoOps.h"
#include "../Passes.h"

#include "mlir/Dialect/Func/IR/FuncOps.h"
#include "mlir/IR/Builders.h"
#include "mlir/IR/BuiltinOps.h"
#include "mlir/Pass/Pass.h"

using namespace mlir;

namespace {

constexpr llvm::StringLiteral kEscapeAttr     = "eco.escape";
constexpr llvm::StringLiteral kNonEscapingTag = "non_escaping";
constexpr llvm::StringLiteral kEscapesTag     = "escapes";

/// True iff `use` is a projection of the construct op's tuple via one of
/// the known tuple-projection ops, with the construct result occupying
/// the `tuple` operand position. Anything else is treated as escaping.
static bool isNonEscapingUse(OpOperand &use) {
    Operation *user = use.getOwner();
    if (auto p = dyn_cast<eco::Tuple2ProjectOp>(user)) {
        return use.getOperandNumber() == 0; // operand 0 is `$tuple`
    }
    if (auto p = dyn_cast<eco::Tuple3ProjectOp>(user)) {
        return use.getOperandNumber() == 0;
    }
    return false;
}

/// Classify a single tuple-construct op's result and tag it with the
/// `eco.escape` attribute. Returns true iff classified as non-escaping.
static bool classifyConstruct(Operation *op, OpBuilder &builder) {
    bool nonEscaping = true;
    for (OpOperand &use : op->getResult(0).getUses()) {
        if (!isNonEscapingUse(use)) {
            nonEscaping = false;
            break;
        }
    }
    op->setAttr(kEscapeAttr,
                builder.getStringAttr(nonEscaping ? kNonEscapingTag
                                                  : kEscapesTag));
    return nonEscaping;
}

struct EcoEscapeAnalysisPass
    : public PassWrapper<EcoEscapeAnalysisPass, OperationPass<func::FuncOp>> {
    MLIR_DEFINE_EXPLICIT_INTERNAL_INLINE_TYPE_ID(EcoEscapeAnalysisPass)

    StringRef getArgument() const override { return "eco-escape-analysis"; }
    StringRef getDescription() const override {
        return "Tag tuple-construct ops with eco.escape classification "
               "(Phase 1 escape analysis for value-level aggregates)";
    }

    void runOnOperation() override {
        func::FuncOp func = getOperation();
        OpBuilder builder(func.getContext());
        func.walk([&](Operation *op) {
            if (isa<eco::Tuple2ConstructOp, eco::Tuple3ConstructOp>(op)) {
                classifyConstruct(op, builder);
            }
        });
    }
};

} // namespace

std::unique_ptr<Pass> eco::createEcoEscapeAnalysisPass() {
    return std::make_unique<EcoEscapeAnalysisPass>();
}
