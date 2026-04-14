//===- EcoGCPrepare.cpp - GC preparation pass -----------------------------===//
//
// This pass runs before EcoToLLVM lowering and performs:
// 1. Groups adjacent allocation ops (stops at calls, terminators, safepoints).
// 2. Computes precise SSA liveness of !eco.value values at each GCRootCarrier
//    op using MLIR's Liveness analysis (inter-block dataflow).
// 3. Attaches live roots as explicit operands on the first op of each group.
// 4. Marks subsequent ops in a group with eco.gc_group_member = true.
// 5. Recomputes live !eco.value sets at each eco.safepoint and replaces operands.
// 6. Computes and attaches live roots on call-like safepoints (eco.call,
//    eco.papExtend, eco.papCreate) via the GCRootCarrier interface.
//
//===----------------------------------------------------------------------===//

#include "EcoToLLVMInternal.h"
#include "../EcoDialect.h"
#include "../EcoOps.h"
#include "../EcoTypes.h"
#include "../Passes.h"

#include "mlir/Analysis/Liveness.h"
#include "mlir/Dialect/Func/IR/FuncOps.h"
#include "mlir/IR/Builders.h"
#include "mlir/IR/BuiltinOps.h"
#include "mlir/Pass/Pass.h"

#include "llvm/Support/Debug.h"

#define DEBUG_TYPE "eco-gc-prepare"

using namespace mlir;

namespace {

//===----------------------------------------------------------------------===//
// GC Liveness Helpers (authoritative — lowering must NOT recompute)
//===----------------------------------------------------------------------===//

static bool isEcoValue(Value v) {
    return isa<eco::ValueType>(v.getType());
}

/// Compute the set of live !eco.value SSA values after `targetOp` using
/// MLIR's Liveness analysis. The candidate set is:
///   - values live-in to the block (cross-block liveness),
///   - block arguments of the current block,
///   - results of ops defined before targetOp in the block.
/// Filtered by: isEcoValue(v) && !liveness.isDeadAfter(v, targetOp).
static SmallVector<Value, 8> computeLiveRoots(Liveness &liveness,
                                               Operation *targetOp) {
    SmallVector<Value, 8> roots;
    llvm::DenseSet<Value> seen;
    Block *block = targetOp->getBlock();
    if (!block) return roots;

    auto consider = [&](Value v) {
        if (!isEcoValue(v)) return;
        if (!seen.insert(v).second) return;
        if (!liveness.isDeadAfter(v, targetOp))
            roots.push_back(v);
    };

    // Candidate set 1: values live-in to this block (cross-block liveness).
    const auto &liveIn = liveness.getLiveIn(block);
    for (Value v : liveIn)
        consider(v);

    // Candidate set 2: block arguments of the current block.
    for (auto arg : block->getArguments())
        consider(arg);

    // Candidate set 3: results of ops defined before targetOp in this block.
    for (auto &op : block->getOperations()) {
        if (&op == targetOp) break;
        for (auto result : op.getResults())
            consider(result);
    }

    return roots;
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

/// Returns true if this is a call-like safepoint that needs independent roots.
/// musttail calls are excluded — they are non-safepoints per design.
static bool isCallSafepoint(Operation *op) {
    if (auto callOp = dyn_cast<eco::CallOp>(op)) {
        // musttail calls are non-safepoints
        auto musttail = callOp.getMusttail();
        if (musttail && *musttail)
            return false;
        return true;
    }
    if (isa<eco::PapExtendOp>(op))
        return true;
    if (isa<eco::PapCreateOp>(op))
        return true;
    return false;
}

//===----------------------------------------------------------------------===//
// EcoGCPreparePass
//===----------------------------------------------------------------------===//

struct EcoGCPreparePass
    : public PassWrapper<EcoGCPreparePass, OperationPass<ModuleOp>> {

    MLIR_DEFINE_EXPLICIT_INTERNAL_INLINE_TYPE_ID(EcoGCPreparePass)

    StringRef getArgument() const override { return "eco-gc-prepare"; }
    StringRef getDescription() const override {
        return "Compute GC root sets via SSA liveness and group adjacent allocations";
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

        // Build liveness analysis once per function.
        Liveness liveness(func);

        LLVM_DEBUG(llvm::dbgs() << "EcoGCPrepare: processing function "
                                << func.getName() << "\n");

        // Walk ALL blocks in the function, including those nested inside
        // regions of ops like scf.while/scf.if. Previously only top-level
        // blocks were visited, which caused papExtend/eco.call ops inside
        // loops to have no GC roots attached — leading to missing
        // statepoints, stale HPointer captures after GC, and crashes.
        func.walk([&](Block *block) {
            processBlock(*block, liveness);
        });
    }

    void processBlock(Block &block, Liveness &liveness) {
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

        // Step 2: For each alloc group, compute liveness and attach via interface.
        auto *ctx = block.getParentOp()->getContext();
        for (auto &group : groups) {
            if (group.empty()) continue;

            SmallVector<Value, 8> liveRoots = computeLiveRoots(liveness, group.front());

            LLVM_DEBUG({
                llvm::dbgs() << "EcoGCPrepare: alloc group leader "
                             << group.front()->getName()
                             << " at " << group.front()->getLoc()
                             << " — " << liveRoots.size() << " roots\n";
            });

            // Use GCRootCarrier interface to set roots on the group leader.
            if (auto carrier = dyn_cast<eco::GCRootCarrier>(group.front()))
                carrier.setGCRoots(liveRoots);

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

        // Step 3: Recompute roots for explicit eco.safepoint ops.
        // UNION with the front-end's original operands — do not shrink.
        // MLIR's per-block Liveness is blind to cross-iteration uses of
        // values captured into nested regions (e.g. scf.while body). If
        // we replace operands with only the liveness-computed set, values
        // like a `callback` function arg that is referenced once per
        // iteration end up stripped. Worse: Step 4 then runs its own
        // liveness query, which now sees a reduced use-def graph and
        // misses those values as call-safepoint roots. The front-end's
        // explicit operand list is authoritative for cross-region
        // liveness; we only grow the set.
        for (auto &op : block) {
            auto safepointOp = dyn_cast<eco::SafepointOp>(&op);
            if (!safepointOp) continue;

            SmallVector<Value, 8> liveRoots = computeLiveRoots(liveness, safepointOp);

            llvm::DenseSet<Value> already(liveRoots.begin(), liveRoots.end());
            for (Value v : safepointOp.getLiveRoots()) {
                if (isEcoValue(v) && already.insert(v).second)
                    liveRoots.push_back(v);
            }

            LLVM_DEBUG({
                llvm::dbgs() << "EcoGCPrepare: safepoint at "
                             << safepointOp->getLoc()
                             << " — " << liveRoots.size() << " roots: [";
                for (auto v : liveRoots)
                    llvm::dbgs() << " " << v;
                llvm::dbgs() << " ]\n";
            });

            safepointOp.setGCRoots(liveRoots);
        }

        // Step 4: Compute and attach roots on call-like safepoints.
        // Each call/papExtend/papCreate gets independent roots.
        for (auto &op : block) {
            if (!isCallSafepoint(&op)) continue;

            SmallVector<Value, 8> liveRoots = computeLiveRoots(liveness, &op);

            LLVM_DEBUG({
                llvm::dbgs() << "EcoGCPrepare: call safepoint "
                             << op.getName()
                             << " at " << op.getLoc()
                             << " — " << liveRoots.size() << " roots\n";
            });

            if (auto carrier = dyn_cast<eco::GCRootCarrier>(&op))
                carrier.setGCRoots(liveRoots);
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
