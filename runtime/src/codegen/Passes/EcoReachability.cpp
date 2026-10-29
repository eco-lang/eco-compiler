//===- EcoReachability.cpp - Closed-world reachability on the MLIR side ---===//
//
// When the output is closed-world, every symbol that matters is reachable from
// a known set of roots, so anything else can go and anything reached that is
// not a root can stop being visible outside the module. This pass does that on
// the llvm-dialect module, before translation to LLVM IR; the contract is on
// `eco::createEcoReachabilityPass` in Passes.h.
//
// Reachability is a breadth-first search over `eco::symgraph::Graph`, whose
// edges model the module as LLVM will see it (an `llvm.mlir.addressof` with no
// uses is no edge). The search starts from the named roots that exist, plus the
// targets of references held by top-level operations that are not symbols.
//
//===----------------------------------------------------------------------===//
#include "../Passes.h"
#include "EcoSymbolGraph.h"
#include "EcoParallel.h"

#include "mlir/Dialect/LLVMIR/LLVMDialect.h"
#include "mlir/IR/Builders.h"
#include "mlir/IR/Threading.h"
#include "mlir/Pass/Pass.h"

#include "llvm/Support/raw_ostream.h"

#include <chrono>
#include <string>
#include <vector>

using namespace mlir;

namespace {

// Returns whether the environment variable `n` is set to a value other than
// the empty string and "0".
bool envOn(const char *n) {
    const char *e = ::getenv(n);
    return e && *e && !(e[0] == '0' && e[1] == '\0');
}

/**
 * The closed-world reachability pass, holding the names of its roots.
 */
struct EcoReachabilityPass
    : public PassWrapper<EcoReachabilityPass, OperationPass<ModuleOp>> {
    MLIR_DEFINE_EXPLICIT_INTERNAL_INLINE_TYPE_ID(EcoReachabilityPass)

    // Creates a pass with no roots, which changes nothing.
    EcoReachabilityPass() = default;
    // Creates a pass whose roots are the symbols named in `roots`.
    explicit EcoReachabilityPass(std::vector<std::string> roots)
        : roots(std::move(roots)) {}
    // Creates a copy with the same roots, as MLIR does when it clones a pass.
    EcoReachabilityPass(const EcoReachabilityPass &o)
        : PassWrapper(o), roots(o.roots) {}

    StringRef getArgument() const final { return "eco-reachability"; }
    StringRef getDescription() const final {
        return "Closed-world reachability + internalization (CGEN_081)";
    }

    // Names of the root symbols, by their MLIR names. A name with no
    // top-level symbol is ignored.
    std::vector<std::string> roots;

    // Fails, after emitting an error, if a reached LLVM function or global
    // definition has a linkage other than External, Internal or Private, or a
    // non-default visibility; nothing has been changed at that point.
    void runOnOperation() override;
};

void EcoReachabilityPass::runOnOperation() {
    ModuleOp module = getOperation();
    MLIRContext *ctx = &getContext();
    auto T0 = std::chrono::steady_clock::now();
    if (roots.empty())
        return;

    eco::symgraph::Graph g = eco::symgraph::build(module);

    // If none of the named roots exists, the module is left unchanged.
    std::vector<char> isRoot(g.nodes.size(), 0), reached(g.nodes.size(), 0);
    std::vector<uint32_t> q;
    for (const std::string &r : roots) {
        int i = g.lookup(StringAttr::get(ctx, r));
        if (i >= 0 && !isRoot[i]) {
            isRoot[i] = 1;
            reached[i] = 1;
            q.push_back((uint32_t)i);
        }
    }
    if (q.empty())
        return;
    for (uint32_t i : g.extraRoots)
        if (!reached[i]) {
            reached[i] = 1;
            q.push_back(i);
        }

    for (size_t h = 0; h < q.size(); ++h) {
        uint32_t n = q[h];
        for (uint32_t e = g.outBegin[n]; e < g.outBegin[n + 1]; ++e) {
            uint32_t t = g.outTarget[e];
            if (!reached[t]) {
                reached[t] = 1;
                q.push_back(t);
            }
        }
    }

    // Reject linkages and visibilities the internalization below does not
    // handle, before anything has been changed.
    for (size_t i = 0; i < g.nodes.size(); ++i) {
        if (!reached[i] || !g.nodes[i].isDef)
            continue;
        Operation *op = g.nodes[i].op;
        LLVM::Linkage l;
        LLVM::Visibility vis;
        if (auto f = dyn_cast<LLVM::LLVMFuncOp>(op)) {
            l = f.getLinkage();
            vis = f.getVisibility_();
        } else if (auto gv = dyn_cast<LLVM::GlobalOp>(op)) {
            l = gv.getLinkage();
            vis = gv.getVisibility_();
        } else {
            continue;
        }
        if (l != LLVM::Linkage::External && l != LLVM::Linkage::Internal &&
            l != LLVM::Linkage::Private) {
            op->emitError("reachability: unsupported linkage on a reached "
                          "definition");
            return signalPassFailure();
        }
        if (vis != LLVM::Visibility::Default) {
            op->emitError("reachability: non-default visibility on a "
                          "reached definition");
            return signalPassFailure();
        }
    }

    // Bodies are dropped in parallel, which is safe because each symbol op's
    // regions are isolated and no SSA value crosses between them. Unlinking
    // from the module is serial, in module order.
    std::vector<Operation *> dead;
    for (size_t i = 0; i < g.nodes.size(); ++i)
        if (!reached[i])
            dead.push_back(g.nodes[i].op);
    eco::forEachChunk(ctx, dead.size(), [&](size_t lo, size_t hi) {
        for (size_t i = lo; i < hi; ++i)
            for (Region &r : dead[i]->getRegions()) {
                r.dropAllReferences();
                r.getBlocks().clear();
            }
    });
    for (Operation *op : dead)
        op->erase();

    unsigned nInternalized = 0;
    for (size_t i = 0; i < g.nodes.size(); ++i) {
        if (!reached[i] || isRoot[i] || !g.nodes[i].isDef)
            continue;
        Operation *op = g.nodes[i].op;
        if (auto f = dyn_cast<LLVM::LLVMFuncOp>(op)) {
            if (f.getLinkage() == LLVM::Linkage::External) {
                f.setLinkage(LLVM::Linkage::Internal);
                ++nInternalized;
            }
        } else if (auto gv = dyn_cast<LLVM::GlobalOp>(op)) {
            if (gv.getLinkage() == LLVM::Linkage::External) {
                gv.setLinkage(LLVM::Linkage::Internal);
                ++nInternalized;
            }
        }
    }

    // Appended to the last existing module-flags op, or to a new one.
    auto flag = LLVM::ModuleFlagAttr::get(
        ctx, LLVM::ModFlagBehavior::Warning, StringAttr::get(ctx, "eco-reach"),
        StringAttr::get(ctx, "v1"));
    LLVM::ModuleFlagsOp existing;
    for (auto mf : module.getOps<LLVM::ModuleFlagsOp>())
        existing = mf;
    if (existing) {
        SmallVector<Attribute> flags(existing.getFlags().begin(),
                                     existing.getFlags().end());
        flags.push_back(flag);
        existing.setFlagsAttr(ArrayAttr::get(ctx, flags));
    } else {
        OpBuilder b = OpBuilder::atBlockEnd(module.getBody());
        b.create<LLVM::ModuleFlagsOp>(module.getLoc(),
                                      ArrayAttr::get(ctx, {flag}));
    }

    if (envOn("ECO_REACH_STATS"))
        llvm::errs() << "[reach] nodes=" << g.nodes.size()
                     << " reached=" << g.nodes.size() - dead.size()
                     << " erased=" << dead.size()
                     << " internalized=" << nInternalized << " time="
                     << std::chrono::duration<double>(
                            std::chrono::steady_clock::now() - T0)
                            .count()
                     << "s\n";
}

} // namespace

namespace eco {
std::unique_ptr<mlir::Pass>
createEcoReachabilityPass(std::vector<std::string> roots) {
    return std::make_unique<EcoReachabilityPass>(std::move(roots));
}
} // namespace eco
