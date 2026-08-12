//===- EcoGCLiveness.h - Shared GC liveness helpers -----------------------===//
//
// Shared helpers for GC root computation used by both EcoGCPrepare and
// EcoGCLivenessAudit. These are the authoritative definitions; neither
// pass should have local copies.
//
//===----------------------------------------------------------------------===//

#ifndef ECO_GC_LIVENESS_H
#define ECO_GC_LIVENESS_H

#include "../EcoOps.h"
#include "../EcoTypes.h"
#include "mlir/Analysis/Liveness.h"
#include "mlir/IR/Value.h"
#include "llvm/ADT/DenseSet.h"
#include "llvm/ADT/SmallVector.h"

#include <cstdlib>

namespace eco {

/// kernel-opt-09 Phase 3. `ECO_GCPREPARE_LEAF_SAFEPOINT=0` restores treating
/// eco.calls stamped `eco.callee_gc_leaf` as call safepoints with full root
/// operand lists. Default ON.
///
/// This lives HERE rather than in either .cpp because EcoGCPrepare's
/// `isCallSafepoint` and EcoGCLivenessAudit's skip list must agree bit-for-bit:
/// if the audit still expects roots on a call the transform stopped rooting,
/// a validator build fails with false positives on correct IR.
///
/// Sound because the root operands are the MLIR-level list only. They are split
/// off at lowering by `splitAdaptedRoots` and handed to `emitSafepointMarker`,
/// which is a no-op — RS4GC inserts the real statepoints from LLVM's own
/// liveness. Dropping them cannot perturb any OTHER call's root set either: the
/// `Liveness` analysis is built once per function BEFORE any operand is
/// appended, so `isDeadAfter` answers from a snapshot that this change does not
/// touch.
inline bool gcLeafSafepointRelaxed() {
    static const bool on = [] {
        const char *e = ::getenv("ECO_GCPREPARE_LEAF_SAFEPOINT");
        return !(e && e[0] == '0' && e[1] == '\0');
    }();
    return on;
}

/// Returns true if a value has !eco.value type.
inline bool isEcoValue(mlir::Value v) {
    return mlir::isa<eco::ValueType>(v.getType());
}

/// Compute the set of live !eco.value SSA values after `targetOp` using
/// MLIR's Liveness analysis. The candidate set is:
///   - values live-in to the block (cross-block liveness),
///   - block arguments of the current block,
///   - results of ops defined before targetOp in the block.
/// Filtered by: isEcoValue(v) && !liveness.isDeadAfter(v, targetOp).
inline llvm::SmallVector<mlir::Value, 8>
computeLiveRoots(mlir::Liveness &liveness, mlir::Operation *targetOp) {
    llvm::SmallVector<mlir::Value, 8> roots;
    llvm::DenseSet<mlir::Value> seen;
    mlir::Block *block = targetOp->getBlock();
    if (!block) return roots;

    auto consider = [&](mlir::Value v) {
        if (!isEcoValue(v)) return;
        // Skip embedded constants — they are not heap objects (HEAP_014)
        // and never need GC relocation.
        if (v.getDefiningOp<eco::ConstantOp>()) return;
        if (!seen.insert(v).second) return;
        if (!liveness.isDeadAfter(v, targetOp))
            roots.push_back(v);
    };

    // Candidate set 1: values live-in to this block (cross-block liveness).
    const auto &liveIn = liveness.getLiveIn(block);
    for (mlir::Value v : liveIn)
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

} // namespace eco

#endif // ECO_GC_LIVENESS_H
