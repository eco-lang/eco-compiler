//===- EcoGCPrepare.cpp - GC preparation pass -----------------------------===//
//
// This pass runs before EcoToLLVM lowering and performs:
// 1. Groups adjacent allocation ops (stops at calls, terminators, safepoints).
// 2. Computes precise backward liveness of !eco.value SSA values at each group.
// 3. Attaches live roots as explicit operands on the first op of each group.
// 4. Marks subsequent ops in a group with eco.gc_group_member = true.
// 5. Recomputes live !eco.value sets at each eco.safepoint and replaces operands.
//
//===----------------------------------------------------------------------===//

#include "EcoToLLVMInternal.h"
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

//===----------------------------------------------------------------------===//
// GC Liveness Helpers (authoritative — lowering must NOT recompute)
//===----------------------------------------------------------------------===//

static bool isEcoValue(Value v) {
    return isa<eco::ValueType>(v.getType());
}

static SmallVector<Value, 8> computeLiveEcoValues(Operation *targetOp) {
    SmallVector<Value, 8> liveValues;
    llvm::DenseSet<Value> seen;

    Block *block = targetOp->getBlock();
    if (!block) return liveValues;

    auto checkAndAdd = [&](Value v) {
        if (!isEcoValue(v)) return;
        if (!seen.insert(v).second) return;

        for (auto &use : v.getUses()) {
            Operation *user = use.getOwner();
            if (user->getBlock() != block) {
                liveValues.push_back(v);
                return;
            }
            if (user == targetOp || targetOp->isBeforeInBlock(user)) {
                liveValues.push_back(v);
                return;
            }
        }
    };

    for (auto arg : block->getArguments())
        checkAndAdd(arg);

    for (auto &op : block->getOperations()) {
        if (&op == targetOp) break;
        for (auto result : op.getResults())
            checkAndAdd(result);
    }

    return liveValues;
}

/// Returns true if the operation may allocate heap memory.
static bool isMayAllocOp(Operation *op) {
    return isa<eco::AllocateCtorOp>(op) ||
           isa<eco::AllocateStringOp>(op) ||
           isa<eco::AllocateClosureOp>(op) ||
           isa<eco::ListConstructOp>(op) ||
           isa<eco::Tuple2ConstructOp>(op) ||
           isa<eco::Tuple3ConstructOp>(op) ||
           isa<eco::RecordConstructOp>(op) ||
           isa<eco::CustomConstructOp>(op) ||
           isa<eco::BoxOp>(op) ||
           isa<eco::AllocateOp>(op);
}

/// Returns true if the operation is a barrier for allocation grouping.
/// Barriers include calls, terminators, explicit safepoints, and PAP ops.
static bool isGroupBarrier(Operation *op) {
    if (op->hasTrait<OpTrait::IsTerminator>())
        return true;
    if (isa<eco::SafepointOp>(op))
        return true;
    if (isa<eco::PapCreateOp>(op) || isa<eco::PapExtendOp>(op))
        return true;
    // Any call-like op is a barrier (D3: conservative)
    if (isa<eco::CallOp>(op))
        return true;
    if (isa<func::CallOp>(op))
        return true;
    return false;
}

/// Set the live_roots operands on an allocation op via per-op dispatch.
/// Most ops have a dedicated $live_roots variadic. RecordConstructOp and
/// CustomConstructOp piggyback roots onto the $fields variadic (appended
/// after the actual fields) to avoid AttrSizedOperandSegments, which would
/// break Elm compiler bytecode that predates the new operand layout.
static void setLiveRoots(Operation *op, ArrayRef<Value> roots) {
    if (auto x = dyn_cast<eco::AllocateCtorOp>(op))
        { x.getLiveRootsMutable().clear(); x.getLiveRootsMutable().append(roots); }
    else if (auto x = dyn_cast<eco::AllocateStringOp>(op))
        { x.getLiveRootsMutable().clear(); x.getLiveRootsMutable().append(roots); }
    else if (auto x = dyn_cast<eco::AllocateClosureOp>(op))
        { x.getLiveRootsMutable().clear(); x.getLiveRootsMutable().append(roots); }
    else if (auto x = dyn_cast<eco::AllocateOp>(op))
        { x.getLiveRootsMutable().clear(); x.getLiveRootsMutable().append(roots); }
    else if (auto x = dyn_cast<eco::BoxOp>(op))
        { x.getLiveRootsMutable().clear(); x.getLiveRootsMutable().append(roots); }
    else if (auto x = dyn_cast<eco::ListConstructOp>(op))
        { x.getLiveRootsMutable().clear(); x.getLiveRootsMutable().append(roots); }
    else if (auto x = dyn_cast<eco::Tuple2ConstructOp>(op))
        { x.getLiveRootsMutable().clear(); x.getLiveRootsMutable().append(roots); }
    else if (auto x = dyn_cast<eco::Tuple3ConstructOp>(op))
        { x.getLiveRootsMutable().clear(); x.getLiveRootsMutable().append(roots); }
    else if (auto x = dyn_cast<eco::RecordConstructOp>(op))
        // Append roots after fields in the single variadic operand list.
        { x.getFieldsMutable().append(roots); }
    else if (auto x = dyn_cast<eco::CustomConstructOp>(op))
        // Append roots after fields in the single variadic operand list.
        { x.getFieldsMutable().append(roots); }
}

//===----------------------------------------------------------------------===//
// EcoGCPreparePass
//===----------------------------------------------------------------------===//

struct EcoGCPreparePass
    : public PassWrapper<EcoGCPreparePass, OperationPass<ModuleOp>> {

    MLIR_DEFINE_EXPLICIT_INTERNAL_INLINE_TYPE_ID(EcoGCPreparePass)

    StringRef getArgument() const override { return "eco-gc-prepare"; }
    StringRef getDescription() const override {
        return "Compute GC root sets and group adjacent allocations";
    }

    void runOnOperation() override {
        ModuleOp module = getOperation();

        module.walk([&](func::FuncOp func) {
            processFunction(func);
        });
    }

private:
    void processFunction(func::FuncOp func) {
        if (func.isExternal()) return;

        for (Block &block : func.getBody()) {
            processBlock(block);
        }
    }

    void processBlock(Block &block) {
        // Step 1: Identify groups of adjacent allocation ops.
        SmallVector<SmallVector<Operation*, 4>> groups;
        SmallVector<Operation*, 4> currentGroup;

        for (auto &op : block) {
            if (isMayAllocOp(&op)) {
                currentGroup.push_back(&op);
            } else {
                if (!currentGroup.empty()) {
                    groups.push_back(std::move(currentGroup));
                    currentGroup = {};
                }
                if (isGroupBarrier(&op)) {
                    // Barrier - any pending group already flushed above
                }
            }
        }
        if (!currentGroup.empty())
            groups.push_back(std::move(currentGroup));

        // Step 2: For each group, compute liveness and attach as explicit operands.
        auto *ctx = block.getParentOp()->getContext();
        for (auto &group : groups) {
            if (group.empty()) continue;

            // Compute live !eco.value values at group entry (before first op)
            SmallVector<Value, 8> liveRoots = computeLiveEcoValues(group.front());

            // Attach roots as explicit operands on the group leader.
            setLiveRoots(group.front(), liveRoots);

            // Keep count attribute as a debug sanity check.
            group.front()->setAttr("eco.gc_roots_count",
                IntegerAttr::get(IntegerType::get(ctx, 64), liveRoots.size()));
            group.front()->setAttr("eco.gc_group_size",
                IntegerAttr::get(IntegerType::get(ctx, 64), group.size()));

            // Mark subsequent ops in the group
            for (size_t i = 1; i < group.size(); i++) {
                group[i]->setAttr("eco.gc_group_member",
                    BoolAttr::get(ctx, true));
            }
        }

        // Step 3: Recompute roots for explicit eco.safepoint ops (D9).
        for (auto &op : block) {
            auto safepointOp = dyn_cast<eco::SafepointOp>(&op);
            if (!safepointOp) continue;

            SmallVector<Value, 8> liveRoots = computeLiveEcoValues(safepointOp);

            // Replace the safepoint's operand list with the computed set.
            // The SafepointOp takes variadic !eco.value operands as live_roots.
            safepointOp.getLiveRootsMutable().clear();
            safepointOp.getLiveRootsMutable().append(liveRoots);
        }
    }
};

} // namespace

//===----------------------------------------------------------------------===//
// Pass Creation
//===----------------------------------------------------------------------===//

std::unique_ptr<Pass> eco::createEcoGCPreparePass() {
    return std::make_unique<EcoGCPreparePass>();
}
