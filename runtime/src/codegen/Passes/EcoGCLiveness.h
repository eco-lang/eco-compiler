//===- EcoGCLiveness.h - Shared GC liveness helpers -----------------------===//
//
// Shared helpers for GC root computation used by both EcoGCPrepare and
// EcoGCLivenessAudit. These are the authoritative definitions; neither
// pass should have local copies.
//
//===----------------------------------------------------------------------===//

#ifndef ECO_GC_LIVENESS_H
#define ECO_GC_LIVENESS_H

#include "../EcoTypes.h"
#include "mlir/Analysis/Liveness.h"
#include "mlir/IR/Value.h"
#include "llvm/ADT/DenseSet.h"
#include "llvm/ADT/SmallVector.h"

namespace eco {

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
