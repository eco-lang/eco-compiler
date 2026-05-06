//===- EcoUnboxedAggSpecialize.cpp - Phase 1 specialize ------------------===//
//
// Phase 1: rewrite Tuple2ConstructOp / Tuple3ConstructOp results that
// EcoEscapeAnalysisPass tagged as `eco.escape = "non_escaping"` into the
// corresponding eco.make.tuple2 / eco.make.tuple3 value-aggregate ops.
//
// The Phase 0 plumbing widened eco.project.tuple2 / eco.project.tuple3
// to accept either an !eco.value operand (heap path) or the matching
// aggregate type (value-level path). The lowering dispatches on the
// converted operand type. So the rewrite here just changes the producer
// — projection users automatically migrate to the value-level path.
//
// Operand layout: this pass runs BEFORE EcoGCPrepare, so a construct op
// has only its plain `a`/`b`/`c` operands at this point — no GC roots
// have been appended yet. We therefore copy operands directly without
// having to split off a roots tail.
//
//===----------------------------------------------------------------------===//

#include "../EcoDialect.h"
#include "../EcoOps.h"
#include "../EcoTypes.h"
#include "../Passes.h"

#include "mlir/Dialect/Func/IR/FuncOps.h"
#include "mlir/IR/Builders.h"
#include "mlir/IR/BuiltinOps.h"
#include "mlir/Pass/Pass.h"

using namespace mlir;

namespace {

constexpr llvm::StringLiteral kEscapeAttr     = "eco.escape";
constexpr llvm::StringLiteral kNonEscapingTag = "non_escaping";

struct EcoUnboxedAggSpecializePass
    : public PassWrapper<EcoUnboxedAggSpecializePass,
                         OperationPass<func::FuncOp>> {
    MLIR_DEFINE_EXPLICIT_INTERNAL_INLINE_TYPE_ID(EcoUnboxedAggSpecializePass)

    StringRef getArgument() const override {
        return "eco-unboxed-agg-specialize";
    }
    StringRef getDescription() const override {
        return "Rewrite non-escaping eco.construct.tuple2 / tuple3 to "
               "eco.make.tuple2 / tuple3 value-level aggregates";
    }

    void runOnOperation() override {
        func::FuncOp func = getOperation();
        MLIRContext *ctx = func.getContext();
        OpBuilder builder(ctx);

        // Collect candidates first so we can mutate freely without
        // invalidating the walk iterator.
        SmallVector<Operation *, 16> toRewrite;
        func.walk([&](Operation *op) {
            if (!isa<eco::Tuple2ConstructOp, eco::Tuple3ConstructOp>(op))
                return;
            auto attr = op->getAttrOfType<StringAttr>(kEscapeAttr);
            if (!attr || attr.getValue() != kNonEscapingTag)
                return;
            toRewrite.push_back(op);
        });

        for (Operation *op : toRewrite) {
            builder.setInsertionPoint(op);
            if (auto t2 = dyn_cast<eco::Tuple2ConstructOp>(op)) {
                Type aggTy = eco::Tuple2Type::get(
                    ctx, t2.getA().getType(), t2.getB().getType());
                auto makeOp = builder.create<eco::Tuple2MakeOp>(
                    t2.getLoc(), aggTy, t2.getA(), t2.getB());
                t2.getResult().replaceAllUsesWith(makeOp.getResult());
                t2.erase();
            } else if (auto t3 = dyn_cast<eco::Tuple3ConstructOp>(op)) {
                Type aggTy = eco::Tuple3Type::get(
                    ctx, t3.getA().getType(), t3.getB().getType(),
                    t3.getC().getType());
                auto makeOp = builder.create<eco::Tuple3MakeOp>(
                    t3.getLoc(), aggTy,
                    t3.getA(), t3.getB(), t3.getC());
                t3.getResult().replaceAllUsesWith(makeOp.getResult());
                t3.erase();
            }
        }

        // Strip the eco.escape tag from any surviving construct ops; the
        // attribute was only used to communicate from the analysis pass
        // to this one, and leaving it on the heap-backed construct ops
        // would clutter the lowered IR.
        func.walk([&](Operation *op) {
            if (isa<eco::Tuple2ConstructOp, eco::Tuple3ConstructOp>(op))
                op->removeAttr(kEscapeAttr);
        });
    }
};

} // namespace

std::unique_ptr<Pass> eco::createEcoUnboxedAggSpecializePass() {
    return std::make_unique<EcoUnboxedAggSpecializePass>();
}
