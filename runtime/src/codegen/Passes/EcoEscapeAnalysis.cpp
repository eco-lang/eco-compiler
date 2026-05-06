//===- EcoEscapeAnalysis.cpp - Escape analysis for value aggregates -------===//
//
// Per-function escape analysis for small-aggregate `eco.construct.*` ops.
// Classifies each construct op's result as either `non_escaping` (every
// use is a known projection on the same value) or `escapes` (anything
// else — call, return, store, capture, case, etc.). The classification
// is recorded as a string attribute `eco.escape` on the construct op so
// the specialise pass can act on it without re-walking uses.
//
// Phase 1 covered Tuple2/Tuple3. Phase 2 extends the candidate set to
// records, customs, and list cons cells:
//   - eco.construct.tuple2  → eco.project.tuple2  (Phase 1)
//   - eco.construct.tuple3  → eco.project.tuple3  (Phase 1)
//   - eco.construct.record  → eco.project.record  (Phase 2)
//   - eco.construct.custom  → eco.project.custom  (Phase 2)
//   - eco.construct.list    → eco.project.list_head / list_tail (Phase 2)
//
// Conservative rules:
//   - A use is NON-escaping iff:
//       * user is the matching projection op, AND
//       * the operand position is the receiver (operand 0).
//   - Anything else is escaping. In particular:
//       * any other op (other eco.construct.*, eco.allocate_*, eco.box,
//         eco.store_global, eco.return, eco.yield, eco.case, eco.call,
//         eco.papCreate, eco.papExtend, eco.to_heap, ...);
//       * the construct op's result being a function return value;
//       * being passed as a projection operand at a non-receiver position
//         (defensive — shouldn't happen in well-typed IR).
//
// This pass must run BEFORE EcoGCPrepare so the construct op's operand
// list is just `[a, b, ... ]` (no GC roots appended yet).
//
// Phase 2's RS4GC FCA prerequisite is satisfied by addEcoGCPipeline, which
// now runs mem2reg + SROA + a tiny custom extractvalue/insertvalue fold
// before RewriteStatepointsForGC. Aggregates carrying ptr addrspace(1)
// fields are therefore safe to rewrite.
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

/// True iff `use` is a known projection of the construct op's result
/// in the receiver operand position. Each construct shape has its own
/// projection op(s); the receiver is always operand 0. Anything else
/// is treated as escaping.
static bool isNonEscapingUse(OpOperand &use) {
    Operation *user = use.getOwner();
    if (use.getOperandNumber() != 0) return false;
    return isa<eco::Tuple2ProjectOp,
               eco::Tuple3ProjectOp,
               eco::RecordProjectOp,
               eco::CustomProjectOp,
               eco::ListHeadOp,
               eco::ListTailOp>(user);
}

/// Classify a single tuple-construct op's result and tag it with the
/// `eco.escape` attribute. Returns true iff classified as non-escaping.
///
/// Phase 1 had an additional `allElementsPrimitive` guard here as a
/// workaround for LLVM's "FCA unimplemented" assertion when a struct
/// value carrying ptr addrspace(1) was live across a statepoint. The
/// guard is no longer needed: Phase 2 wires mem2reg + SROA into
/// addEcoGCPipeline so any FCA is scalarised before RS4GC sees it.
/// Boxed-element tuples are now first-class candidates.
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
            if (isa<eco::Tuple2ConstructOp,
                    eco::Tuple3ConstructOp,
                    eco::RecordConstructOp,
                    eco::CustomConstructOp,
                    eco::ListConstructOp>(op)) {
                classifyConstruct(op, builder);
            }
        });
    }
};

} // namespace

std::unique_ptr<Pass> eco::createEcoEscapeAnalysisPass() {
    return std::make_unique<EcoEscapeAnalysisPass>();
}
