//===- EcoPtrIntVerify.h - Post-RS4GC ptr<1>↔i64 boundary verifier -------===//
//
// Declares createEcoPtrIntVerifyPass(), a post-RS4GC LLVM FunctionPass that
// rejects any ptrtoint ptr<1> / inttoptr → ptr<1> that escapes the
// allow-listed boundary patterns. Gated by ECO_LOWERING_VALIDATION.
//
//===----------------------------------------------------------------------===//

#ifndef ECO_PTR_INT_VERIFY_H
#define ECO_PTR_INT_VERIFY_H

#include "llvm/IR/PassManager.h"

namespace eco {

#ifdef ECO_LOWERING_VALIDATION

/// Post-RS4GC verifier: scans for ptrtoint/inttoptr involving ptr addrspace(1)
/// and rejects any that escape the allowed boundary patterns.
struct EcoPtrIntVerifyPass : public llvm::PassInfoMixin<EcoPtrIntVerifyPass> {
    llvm::PreservedAnalyses run(llvm::Function &F,
                                llvm::FunctionAnalysisManager &FAM);
};

#endif // ECO_LOWERING_VALIDATION

/// Add RS4GC (and, under ECO_LOWERING_VALIDATION, EcoPtrIntVerify) to MPM.
/// All call sites that previously did MPM.addPass(RewriteStatepointsForGC())
/// should call this instead.
void addEcoGCPipeline(llvm::ModulePassManager &MPM);

} // namespace eco

#endif // ECO_PTR_INT_VERIFY_H
