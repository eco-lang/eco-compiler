//===- EcoReachability.cpp - Closed-world reachability on the MLIR side ---===//
//
// plans/mlir-split-backend-03-reachability.md Part II R3, CGEN_081.
//
// For closed-world output (an executable, or an object with
// --internalize-keep) this does in MLIR what internalizeAndDCE did on the
// translated LLVM module: every symbol op not reachable from the roots is
// erased (definitions, globals and declarations — GlobalDCE semantics), and
// every reached definition other than a root becomes Internal. Translation
// then sees ~23 % fewer functions, and the result is recorded as the module
// flag "eco-reach" = "v1" so the backend only sweeps dead constant users
// instead of re-running internalize + GlobalDCE.
//
// Edges come from EcoSymbolGraph, which mirrors LLVM's view (an unused
// addressof is no use). Plan 00 SP4 measured the reached set equal to the
// LLVM GlobalDCE survivors on the self-compile.
//
//===----------------------------------------------------------------------===//
#include "../Passes.h"
#include "EcoSymbolGraph.h"

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

bool envOn(const char *n) {
    const char *e = ::getenv(n);
    return e && *e && !(e[0] == '0' && e[1] == '\0');
}

struct EcoReachabilityPass
    : public PassWrapper<EcoReachabilityPass, OperationPass<ModuleOp>> {
    MLIR_DEFINE_EXPLICIT_INTERNAL_INLINE_TYPE_ID(EcoReachabilityPass)

    EcoReachabilityPass() = default;
    explicit EcoReachabilityPass(std::vector<std::string> roots)
        : roots(std::move(roots)) {}
    EcoReachabilityPass(const EcoReachabilityPass &o)
        : PassWrapper(o), roots(o.roots) {}

    StringRef getArgument() const final { return "eco-reachability"; }
    StringRef getDescription() const final {
        return "Closed-world reachability + internalization (CGEN_081)";
    }

    std::vector<std::string> roots;

    void runOnOperation() override;
};

void EcoReachabilityPass::runOnOperation() {
    ModuleOp module = getOperation();
    MLIRContext *ctx = &getContext();
    auto T0 = std::chrono::steady_clock::now();
    if (roots.empty())
        return;

    eco::symgraph::Graph g = eco::symgraph::build(module);

    // 1. Roots. None present (library-shaped input): change nothing, so the
    //    link fails exactly as it does today.
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

    // 2. BFS.
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

    // 3. Linkage asserts on reached definitions: internalize (and CGEN_074's
    //    isInterposable) assume nothing but external/internal/private.
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

    // 4. Erase the unreached symbol ops: drop bodies in parallel (isolated
    //    regions, no cross-op SSA), then unlink serially in module order.
    std::vector<Operation *> dead;
    for (size_t i = 0; i < g.nodes.size(); ++i)
        if (!reached[i])
            dead.push_back(g.nodes[i].op);
    parallelForEach(ctx, dead, [](Operation *op) {
        for (Region &r : op->getRegions()) {
            r.dropAllReferences();
            r.getBlocks().clear();
        }
    });
    for (Operation *op : dead)
        op->erase();

    // 5. Internalize reached non-root definitions.
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

    // 6. The stamp.
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
