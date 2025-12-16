//===- JoinpointNormalization.cpp - Classify joinpoints for SCF lowering --===//
//
// This pass analyzes and classifies joinpoints for SCF lowering eligibility.
// It marks looping, single-exit joinpoints with normalized continuations as
// SCF-candidates by adding a unit attribute "scf_candidate".
//
// Classification:
// 1. Looping vs non-looping: Does the joinpoint body contain a jump back to itself?
// 2. Single-exit vs multi-exit: Does the joinpoint have exactly one exit path?
// 3. Normalized continuation: Does the continuation start with a jump to this joinpoint?
//
// Only joinpoints that are looping, single-exit, and have normalized continuation
// are marked as SCF-candidates.
//
//===----------------------------------------------------------------------===//

#include "mlir/Pass/Pass.h"
#include "mlir/IR/BuiltinOps.h"
#include "mlir/IR/Dominance.h"

#include "../EcoDialect.h"
#include "../EcoOps.h"
#include "../Passes.h"

using namespace mlir;
using namespace ::eco;

namespace {

/// Check if a joinpoint is looping (has a self-jump in its body).
/// Algorithm from the design doc: walk the body and look for eco.jump
/// with target == joinpoint id.
bool isLoopingJoinpoint(JoinpointOp op) {
    auto jpId = op.getId();
    bool hasLoopingJump = false;

    op.getBody().walk([&](JumpOp jump) {
        if (jump.getTarget() == jpId) {
            hasLoopingJump = true;
            return WalkResult::interrupt();
        }
        return WalkResult::advance();
    });

    return hasLoopingJump;
}

/// Check if a joinpoint is single-exit (has exactly one reachable eco.return).
/// This is a simplified check - we just count return ops in the body region.
bool isSingleExitJoinpoint(JoinpointOp op) {
    int returnCount = 0;

    op.getBody().walk([&](ReturnOp ret) {
        returnCount++;
        // If we've seen more than one, we can stop
        if (returnCount > 1)
            return WalkResult::interrupt();
        return WalkResult::advance();
    });

    // Single exit means exactly one return in the body
    // (The continuation may also have returns, but they come after the joinpoint)
    return returnCount == 1;
}

/// Check if the continuation is normalized - starts with a single eco.jump
/// to the current joinpoint.
bool hasNormalizedContinuation(JoinpointOp op) {
    Region &cont = op.getContinuation();

    if (cont.empty())
        return false;

    Block &entryBlock = cont.front();
    if (entryBlock.empty())
        return false;

    // The first operation should be eco.jump to this joinpoint
    Operation *firstOp = &entryBlock.front();
    if (auto jump = dyn_cast<JumpOp>(firstOp)) {
        return jump.getTarget() == op.getId();
    }

    return false;
}

/// Check if a joinpoint's body is a simple case dispatch pattern:
/// - Top-level eco.case on a loop variable
/// - One alternative exits (eco.return)
/// - Other alternatives loop back (eco.jump to same joinpoint)
///
/// This is the canonical loop pattern that maps well to scf.while.
bool hasSimpleCaseDispatch(JoinpointOp op) {
    Region &body = op.getBody();

    if (body.empty())
        return false;

    Block &entryBlock = body.front();
    if (entryBlock.empty())
        return false;

    // Look for a single eco.case at the top of the body
    // (may have some setup ops before it, but the main control flow should be case)
    CaseOp topLevelCase = nullptr;
    for (Operation &bodyOp : entryBlock) {
        if (auto caseOp = dyn_cast<CaseOp>(&bodyOp)) {
            topLevelCase = caseOp;
            break;
        }
        // Skip pure operations (arith.constant, eco.project, etc.)
        // but not control flow
        if (bodyOp.hasTrait<OpTrait::IsTerminator>())
            break;
    }

    if (!topLevelCase)
        return false;

    // Check the case alternatives:
    // - At least one should exit (eco.return)
    // - At least one should loop (eco.jump to same joinpoint)
    bool hasExitBranch = false;
    bool hasLoopBranch = false;
    auto jpId = op.getId();

    for (Region &alt : topLevelCase.getAlternatives()) {
        if (alt.empty())
            continue;

        // Look at the terminator
        Block &altBlock = alt.front();
        if (altBlock.empty())
            continue;

        Operation *term = altBlock.getTerminator();
        if (isa<ReturnOp>(term)) {
            hasExitBranch = true;
        } else if (auto jump = dyn_cast<JumpOp>(term)) {
            if (jump.getTarget() == jpId) {
                hasLoopBranch = true;
            }
        }
    }

    return hasExitBranch && hasLoopBranch;
}

struct JoinpointNormalizationPass
    : public PassWrapper<JoinpointNormalizationPass, OperationPass<ModuleOp>> {
    MLIR_DEFINE_EXPLICIT_INTERNAL_INLINE_TYPE_ID(JoinpointNormalizationPass)

    StringRef getArgument() const override { return "eco-joinpoint-normalization"; }

    StringRef getDescription() const override {
        return "Classify joinpoints for SCF lowering eligibility";
    }

    void runOnOperation() override {
        ModuleOp module = getOperation();
        auto *ctx = module.getContext();

        // Walk all joinpoints and classify them
        module.walk([&](JoinpointOp op) {
            // Check classification criteria
            bool looping = isLoopingJoinpoint(op);
            bool singleExit = isSingleExitJoinpoint(op);
            bool normalizedCont = hasNormalizedContinuation(op);
            bool simpleCaseDispatch = hasSimpleCaseDispatch(op);

            // A joinpoint is SCF-candidate if:
            // - It is looping (has a self-jump)
            // - Its continuation is normalized (starts with jump to self)
            // - AND either:
            //   (a) It has a simple case dispatch pattern (exit/loop branches), OR
            //   (b) It is single-exit
            //
            // For case dispatch patterns, the exit is handled by the case,
            // so we don't need the single-exit check.
            bool isCandidate = looping && normalizedCont &&
                               (simpleCaseDispatch || singleExit);

            if (isCandidate) {
                // Mark as SCF candidate with unit attribute
                op->setAttr("scf_candidate", UnitAttr::get(ctx));

                // If it has the simple case dispatch pattern, mark that too
                if (simpleCaseDispatch) {
                    op->setAttr("scf_case_loop", UnitAttr::get(ctx));
                }
            }
        });
    }
};

} // namespace

std::unique_ptr<Pass> eco::createJoinpointNormalizationPass() {
    return std::make_unique<JoinpointNormalizationPass>();
}
