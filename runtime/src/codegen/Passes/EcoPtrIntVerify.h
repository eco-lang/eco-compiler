//===- EcoPtrIntVerify.h - Eco's statepoint-rewriting pipeline -----------===//
//
// LLVM's statepoint rewriter (RewriteStatepointsForGC, RS4GC) is what lets the
// collector find and move heap pointers held by generated code, and it cannot
// be run on Eco's IR as it stands. This component owns the one sequence of
// passes that prepares the IR for RS4GC, runs it, and cleans up after it.
//
// Two facts about the IR shape that sequence. First, the sequence assumes
// RS4GC cannot handle a first-class aggregate (an LLVM struct or array value
// held in a register) that contains a `ptr addrspace(1)`, the type of a
// GC-tracked pointer, so it breaks such aggregates into their scalar fields
// beforehand. Second, unless `ECO_SLOT_CAST_BARRIERS` is `0`, a boxed slot (a
// 64-bit word holding a heap pointer) crosses to and from `ptr addrspace(1)`
// through the barrier calls that `EcoSlotCastBarriers.h` names, so that
// nothing folds the crossing before RS4GC; once RS4GC has run the barriers
// must become plain casts again.
//
// In validation builds (`ECO_LOWERING_VALIDATION`) the sequence ends with a
// verifier over the conversions between `ptr addrspace(1)` and integers that
// remain after RS4GC.
//
//===----------------------------------------------------------------------===//

#ifndef ECO_PTR_INT_VERIFY_H
#define ECO_PTR_INT_VERIFY_H

#include "llvm/IR/PassManager.h"

namespace eco {

#ifdef ECO_LOWERING_VALIDATION

/**
 * A check, run after RS4GC, of every `ptrtoint` from and `inttoptr` to
 * `ptr addrspace(1)` in a function.
 *
 * It stops the process with `llvm::report_fatal_error` when it finds a
 * conversion it does not accept, and changes nothing. It accepts almost every
 * shape, so passing it shows little. A `ptrtoint` is rejected only for a use
 * that is not a store of it, a call to a gc-leaf, `eco_`-prefixed or intrinsic
 * callee, an `lshr`, `and`, `icmp`, `select`, `trunc`, `zext`, `or` or `xor`
 * in the same block, an `inttoptr` or a phi. An `inttoptr` is rejected only
 * when its operand is none of: the False, True or Empty constant word, a
 * load, a `ptrtoint`, a call or invoke, an `extractvalue`, or a phi or select
 * built from the first three.
 */
struct EcoPtrIntVerifyPass : public llvm::PassInfoMixin<EcoPtrIntVerifyPass> {
    // Checks every conversion in `F`, and does nothing for a declaration.
    llvm::PreservedAnalyses run(llvm::Function &F,
                                llvm::FunctionAnalysisManager &FAM);
};

#endif // ECO_LOWERING_VALIDATION

// Appends to `MPM` the passes that run RS4GC on a module, in this order:
// mem2reg and SROA, a fold of `extractvalue` through `insertvalue` chains,
// an aggregate scan that does nothing unless `ECO_FCA_SCAN` is set, RS4GC,
// the replacement of slot-cast barrier calls by plain casts, and, in
// validation builds only, `EcoPtrIntVerifyPass`.
//
// Adding `RewriteStatepointsForGC` on its own instead would leave the barrier
// calls in place and the aggregates unfolded.
//
// When a barrier symbol has a use other than a direct call, or a use survives
// the replacement, running the passes stops the process with `llvm::report_fatal_error`, in every build.
void addEcoGCPipeline(llvm::ModulePassManager &MPM);

} // namespace eco

#endif // ECO_PTR_INT_VERIFY_H
