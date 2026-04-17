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

#include "EcoGCLiveness.h"
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

// GC Liveness helpers are in EcoGCLiveness.h (shared with EcoGCLivenessAudit).
using eco::isEcoValue;
using eco::computeLiveRoots;

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

/// Returns true if the operation has a statically known fixed allocation size.
/// Only ops that return true here can be grouped for coalesced allocation.
/// AllocateClosureOp, AllocateOp, and non-scalar BoxOp are excluded (V1 scope).
static bool hasFixedAllocSize(Operation *op) {
    if (auto boxOp = dyn_cast<eco::BoxOp>(op)) {
        Type inputType = boxOp.getValue().getType();
        return inputType.isInteger(64) || inputType.isF64() || inputType.isInteger(16);
    }
    return isa<eco::AllocateCtorOp>(op) ||
           isa<eco::AllocateStringOp>(op) ||
           isa<eco::ListConstructOp>(op) ||
           isa<eco::Tuple2ConstructOp>(op) ||
           isa<eco::Tuple3ConstructOp>(op) ||
           isa<eco::RecordConstructOp>(op) ||
           isa<eco::CustomConstructOp>(op);
}

/// Compute the aligned allocation size for a given Eco allocation op.
/// Must agree with computeAllocSize in EcoToLLVMHeap.cpp.
static int64_t getFixedAllocSizeForGrouping(Operation *op) {
    constexpr int64_t HeaderSize = 8;
    constexpr int64_t UnboxableSize = 8;

    if (auto allocCtor = dyn_cast<eco::AllocateCtorOp>(op)) {
        int64_t size = HeaderSize + 8 + allocCtor.getSize() * UnboxableSize +
                       allocCtor.getScalarBytes();
        return (size + 7) & ~7;
    }
    if (auto allocStr = dyn_cast<eco::AllocateStringOp>(op)) {
        int64_t size = HeaderSize + allocStr.getLength() * 2;
        return (size + 7) & ~7;
    }
    if (isa<eco::ListConstructOp>(op)) return 24;
    if (isa<eco::Tuple2ConstructOp>(op)) return 24;
    if (isa<eco::Tuple3ConstructOp>(op)) return 32;
    if (auto recOp = dyn_cast<eco::RecordConstructOp>(op)) {
        int64_t size = HeaderSize + 8 + recOp.getFieldCount() * UnboxableSize;
        return (size + 7) & ~7;
    }
    if (auto customOp = dyn_cast<eco::CustomConstructOp>(op)) {
        int64_t size = HeaderSize + 8 + customOp.getSize() * UnboxableSize;
        return (size + 7) & ~7;
    }
    if (auto boxOp = dyn_cast<eco::BoxOp>(op)) {
        Type inputType = boxOp.getValue().getType();
        if (inputType.isInteger(64) || inputType.isF64() || inputType.isInteger(16))
            return 16;
    }
    return 0;
}

/// Large-object threshold for group formation (must match runtime default).
/// Groups whose combined size would reach or exceed this are split.
static constexpr int64_t GroupLargeObjectThreshold = 32 * 1024; // 32 KiB

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
        // Only ops with statically known sizes can be grouped.
        // Groups are capped at the large-object threshold to avoid
        // pushing a pile of small allocs into old-gen.
        SmallVector<SmallVector<Operation*, 4>> groups;
        SmallVector<Operation*, 4> currentGroup;
        int64_t runningSize = 0;

        for (auto &op : block) {
            if (isMayAllocOp(&op)) {
                if (!hasFixedAllocSize(&op)) {
                    // Non-fixed-size op: close current group, add as singleton
                    if (!currentGroup.empty()) {
                        groups.push_back(std::move(currentGroup));
                        currentGroup = {};
                        runningSize = 0;
                    }
                    groups.push_back(SmallVector<Operation*, 4>{&op});
                    continue;
                }
                int64_t opSize = getFixedAllocSizeForGrouping(&op);
                if (!currentGroup.empty() &&
                    runningSize + opSize >= GroupLargeObjectThreshold) {
                    // Adding this op would exceed threshold: close group first
                    groups.push_back(std::move(currentGroup));
                    currentGroup = {};
                    runningSize = 0;
                }
                currentGroup.push_back(&op);
                runningSize += opSize;
            } else {
                if (!currentGroup.empty()) {
                    groups.push_back(std::move(currentGroup));
                    currentGroup = {};
                    runningSize = 0;
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

            // Union with the group leader's own !eco.value operands.
            // computeLiveRoots() filters by !isDeadAfter(v, op), which
            // excludes operands whose only use IS this op. But construct
            // ops (eco.construct.custom, eco.construct.record, etc.)
            // expand during lowering into an allocation call followed by
            // separate field stores. The field operands must survive across
            // the allocation's GC safepoint even though they appear "dead
            // after" the single Eco-level op. Without this union, GC at
            // the allocation statepoint doesn't relocate these values,
            // producing stale HPointers that corrupt heap fields.
            {
                llvm::DenseSet<Value> already(liveRoots.begin(), liveRoots.end());
                for (Value v : group.front()->getOperands()) {
                    if (isEcoValue(v) && !v.getDefiningOp<eco::ConstantOp>() &&
                        already.insert(v).second)
                        liveRoots.push_back(v);
                }
            }

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

            // Emit eco.alloc_size_bytes on every grouped op (leader + members)
            for (auto *memberOp : group) {
                int64_t sz = getFixedAllocSizeForGrouping(memberOp);
                if (sz > 0) {
                    memberOp->setAttr("eco.alloc_size_bytes",
                        IntegerAttr::get(IntegerType::get(ctx, 64), sz));
                }
            }

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
                if (isEcoValue(v) && !v.getDefiningOp<eco::ConstantOp>() &&
                    already.insert(v).second)
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
        //
        // UNION with the op's own !eco.value operands — do not shrink.
        // computeLiveRoots() filters by !isDeadAfter(v, op), which
        // excludes operands whose only use IS this op. But during
        // lowering, the op expands to multiple LLVM IR operations
        // with internal GC points (boxing calls in emitRootedBoxedArgsArray,
        // emitInlineClosureCall, etc.). Values like closureI64 that are
        // operands of the op are needed AFTER those internal GC points
        // but BEFORE the final runtime call. Without the union, GC at
        // an internal statepoint doesn't update these values, producing
        // stale HPointers that corrupt heap objects.
        for (auto &op : block) {
            if (!isCallSafepoint(&op)) continue;

            SmallVector<Value, 8> liveRoots = computeLiveRoots(liveness, &op);

            // Union with the op's own !eco.value operands.
            // Skip embedded constants — not heap objects, don't need GC tracking.
            llvm::DenseSet<Value> already(liveRoots.begin(), liveRoots.end());
            for (Value v : op.getOperands()) {
                if (isEcoValue(v) && !v.getDefiningOp<eco::ConstantOp>() &&
                    already.insert(v).second)
                    liveRoots.push_back(v);
            }

            LLVM_DEBUG({
                llvm::dbgs() << "EcoGCPrepare: call safepoint "
                             << op.getName()
                             << " at " << op.getLoc()
                             << " — " << liveRoots.size() << " roots\n";
            });

            if (auto carrier = dyn_cast<eco::GCRootCarrier>(&op))
                carrier.setGCRoots(liveRoots);
        }

#if ECO_GC_DEBUG
        // Dump all GCRootCarrier ops in this block with their final roots.
        for (auto &op : block) {
            auto carrier = dyn_cast<eco::GCRootCarrier>(&op);
            if (!carrier) continue;
            auto funcOp = op.getParentOfType<func::FuncOp>();
            auto roots = carrier.getGCRoots();
            llvm::errs() << "[gc-liveness] func="
                         << (funcOp ? funcOp.getName() : StringRef("?"))
                         << " op=" << op.getName()
                         << " loc=" << op.getLoc() << "\n";
            llvm::errs() << "  eco.value operands:";
            for (Value v : op.getOperands())
                if (isEcoValue(v))
                    llvm::errs() << " " << v;
            llvm::errs() << "\n  attached roots (" << roots.size() << "):";
            for (Value r : roots)
                llvm::errs() << " " << r;
            llvm::errs() << "\n";
        }
#endif
    }
};

} // namespace

//===----------------------------------------------------------------------===//
// Pass Creation
//===----------------------------------------------------------------------===//

std::unique_ptr<Pass> eco::createEcoGCPreparePass() {
    return std::make_unique<EcoGCPreparePass>();
}
