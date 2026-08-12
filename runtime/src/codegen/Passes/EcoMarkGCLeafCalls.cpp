//===- EcoMarkGCLeafCalls.cpp - Stamp call-local gc-leaf facts ------------===//
//
// Copies the per-callee cannot-GC fact from the kernel func.func declaration
// (`eco.gc_leaf`, emitted by the compiler from the kernel-opt-07 facts table
// under kernel-opt-08's `kernelGcLeaf` flag) onto each DIRECT eco.call as the
// call-local unit attr `eco.callee_gc_leaf`.
//
// Why a separate module pass rather than a lookup inside EcoGCPrepare: that
// pass's mirror consumer, EcoGCLivenessAudit, is a NESTED func::FuncOp pass and
// must not inspect sibling func.func ops. One module walk here gives both
// consumers a call-local bit they can read without leaving their anchor op,
// which is also what keeps the two from drifting apart — a validator build that
// disagreed with the transform build would fail with false positives.
//
// The attr is advisory: nothing downstream is REQUIRED to honour it, and every
// consumer is independently gated. Whitelist discipline — a call the pass does
// not stamp keeps exactly today's behaviour.
//
//===----------------------------------------------------------------------===//

#include "EcoToLLVMInternal.h" // kernelGcLeafEnabled() — kernel-opt-08's kill switch
#include "../EcoDialect.h"
#include "../EcoOps.h"
#include "../Passes.h"

#include "mlir/Dialect/Func/IR/FuncOps.h"
#include "mlir/IR/BuiltinOps.h"
#include "mlir/Pass/Pass.h"

#include "llvm/ADT/DenseSet.h"

#include <cstdlib>

using namespace mlir;

namespace {

struct EcoMarkGCLeafCallsPass
    : public PassWrapper<EcoMarkGCLeafCallsPass, OperationPass<ModuleOp>> {
    MLIR_DEFINE_EXPLICIT_INTERNAL_INLINE_TYPE_ID(EcoMarkGCLeafCallsPass)

    StringRef getArgument() const override { return "eco-mark-gc-leaf-calls"; }
    StringRef getDescription() const override {
        return "Stamp eco.callee_gc_leaf on eco.calls whose callee decl is eco.gc_leaf";
    }

    void runOnOperation() override {
        ModuleOp module = getOperation();
        auto *ctx = module.getContext();

        // CROSS-PLAN CONTRACT with kernel-opt-08: ECO_KERNEL_GCLEAF=0 means
        // "the backend ignores eco.gc_leaf ENTIRELY without recompiling the
        // .mlir". Honouring it here is what keeps that switch whole — otherwise
        // 08 would stop attaching gc-leaf-function while 09's consumers kept
        // de-safepointing off the same fact.
        if (!eco::detail::kernelGcLeafEnabled())
            return;

        // Local bisect handle, independent of kernel-opt-08's switch: stamps
        // nothing while leaving 08's gc-leaf-function passthrough alone. This is
        // what makes the "Phase 0 is inert" acceptance test possible at all —
        // ECO_KERNEL_GCLEAF=0 would also disable 08 and change the binary for a
        // completely different reason.
        static const bool markEnabled = [] {
            const char *e = ::getenv("ECO_GCLEAF_MARK");
            return !(e && e[0] == '0' && e[1] == '\0');
        }();
        if (!markEnabled)
            return;

        // func.func ops are direct children of the module body; iterate the top
        // level rather than a recursive walk (UndefinedFunction.cpp idiom).
        llvm::DenseSet<StringAttr> leaf;
        for (auto funcOp : module.getBody()->getOps<func::FuncOp>())
            if (funcOp->hasAttr("is_kernel") && funcOp->hasAttr("eco.gc_leaf"))
                leaf.insert(funcOp.getSymNameAttr());
        if (leaf.empty())
            return; // nothing stamped upstream => this pass is a no-op

        auto unit = UnitAttr::get(ctx);
        uint64_t stamped = 0;
        module.walk([&](eco::CallOp callOp) {
            auto calleeAttr = callOp.getCalleeAttr();
            if (!calleeAttr)
                return; // indirect call: never stamped
            if (!leaf.contains(calleeAttr.getAttr()))
                return;
            auto musttail = callOp.getMusttail();
            if (musttail && *musttail)
                return; // already a non-safepoint; stamping adds nothing
            callOp->setAttr("eco.callee_gc_leaf", unit);
            ++stamped;
        });

        if (::getenv("ECO_GCLEAF_MARK_REPORT"))
            llvm::errs() << "[gcleaf-mark] " << leaf.size() << " gc-leaf decls, "
                         << stamped << " eco.call sites stamped\n";
    }
};

} // namespace

std::unique_ptr<Pass> eco::createEcoMarkGCLeafCallsPass() {
    return std::make_unique<EcoMarkGCLeafCallsPass>();
}
