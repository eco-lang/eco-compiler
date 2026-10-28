//===- JoinpointNormalization.cpp - Classify joinpoints for SCF lowering --===//
//
// EcoControlFlowToSCF turns an `eco.joinpoint` into an `scf.while` only when the joinpoint has the shape of a
// loop, and this pass decides which ones do. It only labels: it changes no control flow, despite its name.
//
// An `eco.joinpoint` is a local label with an id. It has two regions: the body, entered by an `eco.jump` naming that
// id, whose entry-block arguments are the jump's arguments; and the continuation, the code after the joinpoint. A
// joinpoint is a candidate when all of these hold:
//
// - it loops: some `eco.jump` nested anywhere in its body names its own id;
// - its continuation is normalized: the first op of the continuation's entry block is an `eco.jump` to its id;
// - its body is either a simple case dispatch or single-exit (both defined at the predicates below).
//
// A candidate gets the unit attribute `scf_candidate`, and a candidate that is a simple case dispatch also gets
// `scf_case_loop`. Nothing else is written, and no attribute is removed.
//
// Jumps are matched to joinpoints by comparing ids alone. That is sound because a jump targets an enclosing
// joinpoint with its id (invariant CGEN_030) and ids are unique within a function (CGEN_031).
//
//===----------------------------------------------------------------------===//

#include "mlir/Pass/Pass.h"
#include "mlir/IR/BuiltinOps.h"
#include "mlir/IR/Dominance.h"
#include "mlir/Dialect/Func/IR/FuncOps.h"

#include "../EcoDialect.h"
#include "../EcoOps.h"
#include "../Passes.h"

using namespace mlir;
using namespace ::eco;

namespace {

/// Returns whether any `eco.jump` nested anywhere in `op`'s body targets `op`'s own id.
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

/// Returns whether `op`'s body contains exactly one `eco.return`.
///
/// Every `eco.return` nested anywhere in the body is counted, including those inside case alternatives and nested
/// joinpoints, whether or not it is reachable. Returns in the continuation are not counted.
bool isSingleExitJoinpoint(JoinpointOp op) {
    int returnCount = 0;

    op.getBody().walk([&](ReturnOp ret) {
        returnCount++;
        if (returnCount > 1)
            return WalkResult::interrupt();
        return WalkResult::advance();
    });

    return returnCount == 1;
}

/// Returns whether the first op of the entry block of `op`'s continuation is an `eco.jump` to `op`'s id. An empty
/// continuation or entry block is not normalized.
bool hasNormalizedContinuation(JoinpointOp op) {
    Region &cont = op.getContinuation();

    if (cont.empty())
        return false;

    Block &entryBlock = cont.front();
    if (entryBlock.empty())
        return false;

    Operation *firstOp = &entryBlock.front();
    if (auto jump = dyn_cast<JumpOp>(firstOp)) {
        return jump.getTarget() == op.getId();
    }

    return false;
}

/// Returns whether `op`'s body is a simple case dispatch: the entry block holds an `eco.case`, before any terminator,
/// and among that case's alternatives at least one ends in `eco.return` and at least one ends in an `eco.jump` to
/// `op`'s id.
///
/// Only the first `eco.case` of the entry block is examined, and only the terminator of each alternative's first
/// block. Other alternatives, such as ones ending in a jump to another joinpoint, do not disqualify the body.
bool hasSimpleCaseDispatch(JoinpointOp op) {
    Region &body = op.getBody();

    if (body.empty())
        return false;

    Block &entryBlock = body.front();
    if (entryBlock.empty())
        return false;

    // Ops before the case, such as constants and projections, are skipped.
    CaseOp topLevelCase = nullptr;
    for (Operation &bodyOp : entryBlock) {
        if (auto caseOp = dyn_cast<CaseOp>(&bodyOp)) {
            topLevelCase = caseOp;
            break;
        }
        if (bodyOp.hasTrait<OpTrait::IsTerminator>())
            break;
    }

    if (!topLevelCase)
        return false;

    bool hasExitBranch = false;
    bool hasLoopBranch = false;
    auto jpId = op.getId();

    for (Region &alt : topLevelCase.getAlternatives()) {
        if (alt.empty())
            continue;

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

/// The module pass that labels every `eco.joinpoint` in the module, nested ones included.
struct JoinpointNormalizationPass
    : public PassWrapper<JoinpointNormalizationPass, OperationPass<ModuleOp>> {
    MLIR_DEFINE_EXPLICIT_INTERNAL_INLINE_TYPE_ID(JoinpointNormalizationPass)

    StringRef getArgument() const override { return "eco-joinpoint-normalization"; }

    StringRef getDescription() const override {
        return "Classify joinpoints for SCF lowering eligibility";
    }

    /// Adds `scf_candidate`, and `scf_case_loop` where it applies, to each candidate joinpoint in the module.
    void runOnOperation() override {
        ModuleOp module = getOperation();
        auto *ctx = module.getContext();

        module.walk([&](JoinpointOp op) {
            bool looping = isLoopingJoinpoint(op);
            bool singleExit = isSingleExitJoinpoint(op);
            bool normalizedCont = hasNormalizedContinuation(op);
            bool simpleCaseDispatch = hasSimpleCaseDispatch(op);

            // A case dispatch exits through its own alternatives, so it needs no single-exit check.
            bool isCandidate = looping && normalizedCont &&
                               (simpleCaseDispatch || singleExit);

            if (isCandidate) {
                op->setAttr("scf_candidate", UnitAttr::get(ctx));

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
