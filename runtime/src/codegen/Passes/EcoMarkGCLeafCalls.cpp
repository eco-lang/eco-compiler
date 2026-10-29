//===- EcoMarkGCLeafCalls.cpp - Stamp call-local gc-leaf facts ------------===//
//
// A call to a kernel function that cannot run a GC need not be treated as a
// point where the heap may move. The compiler records that fact once per
// callee, as the unit attribute `eco.gc_leaf` on the kernel's func.func
// declaration (one also marked `is_kernel`). This pass copies the fact onto
// each call, so a reader can see it without looking up the callee: every
// direct, non-musttail `eco.call` of such a declaration gets the unit
// attribute `eco.callee_gc_leaf`.
//
// The attribute is advisory: a missing stamp costs only an optimisation. Two
// readers use it. EcoGCPrepare's merge census (`isHardMotionBarrier`) treats
// an unstamped `eco.call` as a barrier; BFToLLVM's `mayCollect` falls back to
// its own checks on the callee's name and LLVM declaration.
//
// Two environment switches make the pass stamp nothing. `ECO_KERNEL_GCLEAF=0`
// (read by `eco::detail::kernelGcLeafEnabled`) makes the whole backend ignore
// `eco.gc_leaf`, and this pass honours it. `ECO_GCLEAF_MARK=0` disables only
// this pass, leaving kernel declarations' gc-leaf marking in place.
// `ECO_GCLEAF_MARK_REPORT`, when set, prints how many declarations and call
// sites were found to stderr.
//
//===----------------------------------------------------------------------===//

#include "EcoToLLVMInternal.h" // kernelGcLeafEnabled()
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

/**
 * The module pass that stamps `eco.callee_gc_leaf` on direct calls of gc-leaf
 * kernel declarations, registered as `eco-mark-gc-leaf-calls`.
 */
struct EcoMarkGCLeafCallsPass
    : public PassWrapper<EcoMarkGCLeafCallsPass, OperationPass<ModuleOp>> {
    MLIR_DEFINE_EXPLICIT_INTERNAL_INLINE_TYPE_ID(EcoMarkGCLeafCallsPass)

    // Returns the pass's command-line name.
    StringRef getArgument() const override { return "eco-mark-gc-leaf-calls"; }
    // Returns the pass's one-line description.
    StringRef getDescription() const override {
        return "Stamp eco.callee_gc_leaf on eco.calls whose callee decl is eco.gc_leaf";
    }

    // Stamps every direct, non-musttail `eco.call` in the module whose callee
    // is a top-level func.func carrying both `is_kernel` and `eco.gc_leaf`.
    // Does nothing if `ECO_KERNEL_GCLEAF=0` or `ECO_GCLEAF_MARK=0` is set, or
    // if no such declaration exists.
    void runOnOperation() override {
        ModuleOp module = getOperation();
        auto *ctx = module.getContext();

        // ECO_KERNEL_GCLEAF=0 means the backend ignores eco.gc_leaf entirely,
        // so this pass must not act on it either.
        if (!eco::detail::kernelGcLeafEnabled())
            return;

        // A bisect switch for this pass alone: it stamps nothing but leaves the
        // gc-leaf-function passthrough on kernel declarations in place, which
        // ECO_KERNEL_GCLEAF=0 would also remove. Off only for exactly "0".
        static const bool markEnabled = [] {
            const char *e = ::getenv("ECO_GCLEAF_MARK");
            return !(e && e[0] == '0' && e[1] == '\0');
        }();
        if (!markEnabled)
            return;

        // func.func ops are direct children of the module body, so only the top
        // level is searched.
        llvm::DenseSet<StringAttr> leaf;
        for (auto funcOp : module.getBody()->getOps<func::FuncOp>())
            if (funcOp->hasAttr("is_kernel") && funcOp->hasAttr("eco.gc_leaf"))
                leaf.insert(funcOp.getSymNameAttr());
        if (leaf.empty())
            return;

        auto unit = UnitAttr::get(ctx);
        uint64_t stamped = 0;
        module.walk([&](eco::CallOp callOp) {
            auto calleeAttr = callOp.getCalleeAttr();
            if (!calleeAttr)
                return; // indirect call
            if (!leaf.contains(calleeAttr.getAttr()))
                return;
            auto musttail = callOp.getMusttail();
            if (musttail && *musttail)
                return; // a musttail call is not stamped
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
