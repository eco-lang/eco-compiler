//===- EcoUnboxedAggSpecialize.cpp - Phase 1+2 specialize ----------------===//
//
// Rewrite construct-op results that EcoEscapeAnalysisPass tagged as
// `eco.escape = "non_escaping"` into the corresponding eco.make.* value-
// aggregate ops:
//   - Tuple2ConstructOp  → Tuple2MakeOp
//   - Tuple3ConstructOp  → Tuple3MakeOp
//   - RecordConstructOp  → RecordMakeOp
//   - CustomConstructOp  → CustomMakeOp  (preserves the `tag` and
//                                          optional `constructor` attrs)
//   - ListConstructOp    → ConsMakeOp
//
// The Phase 0 plumbing widened the matching projection ops to accept
// either an !eco.value operand (heap path) or the aggregate type
// (value-level path), and the LLVM-side lowering dispatches on the
// converted operand type. So the rewrite here just changes the producer
// — projection users automatically migrate to the value-level path.
//
// Operand layout: this pass runs BEFORE EcoGCPrepare, so a construct op
// has only its plain field operands at this point — no GC roots have
// been appended yet. We therefore copy operands directly without having
// to split off a roots tail.
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

#include "llvm/ADT/Statistic.h"

#define DEBUG_TYPE "eco-unboxed-agg-specialize"

using namespace mlir;

namespace {

constexpr llvm::StringLiteral kEscapeAttr     = "eco.escape";
constexpr llvm::StringLiteral kNonEscapingTag = "non_escaping";

// One bump per construct → make rewrite, grouped by construct kind.
// Cross-checks against EcoEscapeAnalysis's ConstructNonEscaping totals;
// a divergence (e.g. fewer rewrites than non-escaping tags) would point
// at attribute-survival bugs between the two passes.
ALWAYS_ENABLED_STATISTIC(SpecialiseTotal,
    "construct → make rewrites applied (total)");
ALWAYS_ENABLED_STATISTIC(SpecialiseTuple2,
    "construct.tuple2 → make.tuple2 rewrites");
ALWAYS_ENABLED_STATISTIC(SpecialiseTuple3,
    "construct.tuple3 → make.tuple3 rewrites");
ALWAYS_ENABLED_STATISTIC(SpecialiseRecord,
    "construct.record → make.record rewrites");
ALWAYS_ENABLED_STATISTIC(SpecialiseCustom,
    "construct.custom → make.custom rewrites");
ALWAYS_ENABLED_STATISTIC(SpecialiseList,
    "construct.list → make.cons rewrites");

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
            if (!isa<eco::Tuple2ConstructOp,
                     eco::Tuple3ConstructOp,
                     eco::RecordConstructOp,
                     eco::CustomConstructOp,
                     eco::ListConstructOp>(op))
                return;
            auto attr = op->getAttrOfType<StringAttr>(kEscapeAttr);
            if (!attr || attr.getValue() != kNonEscapingTag)
                return;
            toRewrite.push_back(op);
        });

        for (Operation *op : toRewrite) {
            builder.setInsertionPoint(op);
            ++SpecialiseTotal;
            if (auto t2 = dyn_cast<eco::Tuple2ConstructOp>(op)) {
                ++SpecialiseTuple2;
                Type aggTy = eco::Tuple2Type::get(
                    ctx, t2.getA().getType(), t2.getB().getType());
                auto makeOp = builder.create<eco::Tuple2MakeOp>(
                    t2.getLoc(), aggTy, t2.getA(), t2.getB());
                t2.getResult().replaceAllUsesWith(makeOp.getResult());
                t2.erase();
            } else if (auto t3 = dyn_cast<eco::Tuple3ConstructOp>(op)) {
                ++SpecialiseTuple3;
                Type aggTy = eco::Tuple3Type::get(
                    ctx, t3.getA().getType(), t3.getB().getType(),
                    t3.getC().getType());
                auto makeOp = builder.create<eco::Tuple3MakeOp>(
                    t3.getLoc(), aggTy,
                    t3.getA(), t3.getB(), t3.getC());
                t3.getResult().replaceAllUsesWith(makeOp.getResult());
                t3.erase();
            } else if (auto rec = dyn_cast<eco::RecordConstructOp>(op)) {
                ++SpecialiseRecord;
                auto fields = rec.getFields();
                SmallVector<Type, 8> elementTypes;
                elementTypes.reserve(fields.size());
                for (Value f : fields) elementTypes.push_back(f.getType());
                Type aggTy = eco::RecordType::get(ctx, elementTypes);
                auto makeOp = builder.create<eco::RecordMakeOp>(
                    rec.getLoc(), aggTy, fields);
                rec.getResult().replaceAllUsesWith(makeOp.getResult());
                rec.erase();
            } else if (auto cus = dyn_cast<eco::CustomConstructOp>(op)) {
                ++SpecialiseCustom;
                auto fields = cus.getFields();
                SmallVector<Type, 8> elementTypes;
                elementTypes.reserve(fields.size());
                for (Value f : fields) elementTypes.push_back(f.getType());
                Type aggTy = eco::CustomType::get(ctx, elementTypes);
                auto makeOp = builder.create<eco::CustomMakeOp>(
                    cus.getLoc(), aggTy, fields,
                    builder.getI64IntegerAttr(cus.getTag()),
                    cus.getConstructorAttr());
                cus.getResult().replaceAllUsesWith(makeOp.getResult());
                cus.erase();
            } else if (auto lst = dyn_cast<eco::ListConstructOp>(op)) {
                ++SpecialiseList;
                Type aggTy = eco::ConsType::get(
                    ctx, lst.getHead().getType(), lst.getTail().getType());
                auto makeOp = builder.create<eco::ConsMakeOp>(
                    lst.getLoc(), aggTy, lst.getHead(), lst.getTail());
                lst.getResult().replaceAllUsesWith(makeOp.getResult());
                lst.erase();
            }
        }

        // Strip the eco.escape tag from any surviving construct ops; the
        // attribute was only used to communicate from the analysis pass
        // to this one, and leaving it on the heap-backed construct ops
        // would clutter the lowered IR.
        func.walk([&](Operation *op) {
            if (isa<eco::Tuple2ConstructOp,
                    eco::Tuple3ConstructOp,
                    eco::RecordConstructOp,
                    eco::CustomConstructOp,
                    eco::ListConstructOp>(op))
                op->removeAttr(kEscapeAttr);
        });
    }
};

} // namespace

std::unique_ptr<Pass> eco::createEcoUnboxedAggSpecializePass() {
    return std::make_unique<EcoUnboxedAggSpecializePass>();
}
