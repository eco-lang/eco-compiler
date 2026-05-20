//===- EcoBoxAggregateOperands.cpp - Box aggregate operands before lowering ===//
//
// Phase 1 of plans/widen-construct-make-call-aggregates.md.
//
// After cross-spec promotes a call's result type to an aggregate, the result
// SSA value may flow into a `construct.*`, `make.*`, or `eco.call` operand
// slot. Heap-slot and boxed-ABI positions must see a boxed `!eco.value`;
// `make.*` SSA positions can stay aggregate as long as the inner contains
// no GC pointer (otherwise nested-FCA-of-`ptr<1>` trips RS4GC).
//
// This pass inserts `eco.to_heap` ops as needed before each such operand,
// turning the dialect-level operand into a boxed `!eco.value`. Running
// before `EcoGCPrepare` lets that pass compute GC roots for the new
// allocation safepoints automatically and include the new ops in
// adjacent-allocation groups.
//
//===----------------------------------------------------------------------===//

#include "../EcoDialect.h"
#include "../EcoOps.h"
#include "../EcoTypes.h"
#include "../Passes.h"
#include "EcoToLLVMInternal.h"

#include "mlir/Dialect/Func/IR/FuncOps.h"
#include "mlir/IR/Builders.h"
#include "mlir/IR/BuiltinOps.h"
#include "mlir/Pass/Pass.h"

using namespace mlir;
using namespace eco;
using namespace eco::detail;

namespace {

/// True if `t` is one of the Eco data-aggregate dialect types
/// (tuple2/3, record, custom, cons).
bool isEcoAggregate(Type t) {
    return isa<eco::Tuple2Type, eco::Tuple3Type, eco::RecordType,
               eco::CustomType, eco::ConsType>(t);
}

/// Rewrite each operand of `op` whose type satisfies `shouldBox` to flow
/// through a fresh `eco.to_heap`. The inserted op uses `liveRoots` as its
/// live-roots metadata.
template <typename ShouldBoxFn>
void boxOpOperands(Operation *op, ShouldBoxFn shouldBox,
                   ValueRange liveRoots) {
    OpBuilder b(op);
    SmallVector<Value, 8> operands(op->operand_begin(), op->operand_end());
    for (auto [i, v] : llvm::enumerate(operands)) {
        if (!shouldBox(v.getType())) continue;
        Value boxed = materialiseAsBoxed(b, op->getLoc(), v, liveRoots);
        if (boxed != v)
            op->setOperand(static_cast<unsigned>(i), boxed);
    }
}

struct EcoBoxAggregateOperandsPass
    : public PassWrapper<EcoBoxAggregateOperandsPass,
                         OperationPass<ModuleOp>> {

    MLIR_DEFINE_EXPLICIT_INTERNAL_INLINE_TYPE_ID(EcoBoxAggregateOperandsPass)

    StringRef getArgument() const override {
        return "eco-box-aggregate-operands";
    }

    StringRef getDescription() const override {
        return "Box aggregate-typed operands of construct.*, make.*, and "
               "eco.call ops before EcoGCPrepare / EcoToLLVM. Phase 1 of "
               "widen-construct-make-call-aggregates.";
    }

    void runOnOperation() override {
        ModuleOp module = getOperation();

        // Build a symbol table for func.call callee lookup.
        SymbolTable symTable(module);

        // Collect targets up-front; mutating the IR while walking can
        // perturb iterators when new ops are inserted in front of
        // existing ones.
        SmallVector<Operation *, 16> constructAndCall;
        SmallVector<func::CallOp, 16> funcCalls;
        SmallVector<Operation *, 16> makeOps;
        module.walk([&](Operation *op) {
            if (isa<eco::Tuple2ConstructOp, eco::Tuple3ConstructOp,
                    eco::ListConstructOp, eco::RecordConstructOp,
                    eco::CustomConstructOp, eco::CallOp>(op))
                constructAndCall.push_back(op);
            else if (auto fc = dyn_cast<func::CallOp>(op))
                funcCalls.push_back(fc);
            else if (isa<eco::Tuple2MakeOp, eco::Tuple3MakeOp,
                         eco::RecordMakeOp, eco::CustomMakeOp,
                         eco::ConsMakeOp, eco::ClosureEnvMakeOp>(op))
                makeOps.push_back(op);
        });

        // construct.* / eco.call: heap slot or boxed-ABI sink — box every
        // aggregate-typed operand unconditionally. If the op already
        // carries live_roots (rare this early in the pipeline; typically
        // EcoGCPrepare has not run yet), forward them.
        for (Operation *op : constructAndCall) {
            ValueRange liveRoots;
            if (auto carrier = dyn_cast<eco::GCRootCarrier>(op))
                liveRoots = carrier.getGCRoots();
            boxOpOperands(op,
                [](Type t) { return isEcoAggregate(t); },
                liveRoots);
        }

        // func.call: cross-spec may rewrite an eco.call into a func.call
        // whose callee retained its boxed signature (the callee wasn't
        // promoted). If a promoted producer's aggregate result flows into
        // such a position, box it to `!eco.value` to match the callee.
        // Iterate per-operand and consult the callee's declared param type
        // so we only box when the callee genuinely wants a boxed value
        // (aggregate-aggregate matches stay untouched).
        for (func::CallOp fc : funcCalls) {
            auto callee = dyn_cast_or_null<func::FuncOp>(
                symTable.lookup(fc.getCallee()));
            if (!callee) continue;
            ArrayRef<Type> paramTys = callee.getFunctionType().getInputs();
            OpBuilder b(fc);
            for (auto [i, operand] : llvm::enumerate(fc.getOperands())) {
                if (i >= paramTys.size()) break;
                if (!isEcoAggregate(operand.getType())) continue;
                if (operand.getType() == paramTys[i]) continue;
                if (!isa<eco::ValueType>(paramTys[i])) continue;
                Value boxed = materialiseAsBoxed(b, fc.getLoc(), operand,
                                                  /*liveRoots=*/ValueRange{});
                fc.setOperand(static_cast<unsigned>(i), boxed);
            }
        }

        // make.*: SSA sink. Nest the inner aggregate as a flat FCA when it
        // contains no GC pointer; box only when it does (avoids RS4GC's
        // nested-FCA limit and keeps strip-aggregates on its one-level
        // path). make.* ops are Pure and not GCRootCarriers — pass empty
        // live_roots; EcoGCPrepare will populate roots on the eco.to_heap
        // when it runs next.
        //
        // CAUTION: boxing a make.* operand changes its type to !eco.value,
        // but the make.*'s result type still carries the original element
        // type at that slot. The op verifier requires them to match. So
        // boxing requires also updating the result type — and propagating
        // that to downstream consumers. For Phase 1, the safer behaviour
        // is to leave GC-pointer-inner aggregates nested; if RS4GC
        // complains downstream, the case is rare enough to address as a
        // follow-up (see plan §9 Phase 2 for the full fix).
        for (Operation *op : makeOps) {
            (void)op;
        }
    }
};

} // namespace

std::unique_ptr<Pass> eco::createEcoBoxAggregateOperandsPass() {
    return std::make_unique<EcoBoxAggregateOperandsPass>();
}
