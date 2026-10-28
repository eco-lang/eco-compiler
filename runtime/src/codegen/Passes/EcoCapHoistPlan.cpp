//===- EcoCapHoistPlan.cpp - Capacity-hoisting plan on the MLIR side ------===//
//
// Capacity-check hoisting (CGEN_074) needs whole-program facts: which functions
// have all their callers visible, and how many bytes each call can allocate.
// This pass computes them on the final llvm-dialect module, before translation
// to LLVM IR, and records them in the module, so that the backend can read a
// function's plan from the function itself. What a budget, top and covered mean,
// and how they are solved, is stated by `caphoist::Node` and `caphoist::solve`
// in EcoCapHoistCore.h.
//
// The pass has three phases:
//
// - Phase A scans each defined function, in parallel, for the facts the solver
//   needs: the constant sizes of its `__eco_alloc_inline` markers outside
//   loops (a non-constant size adds 0), its direct calls to defined
//   functions that are not interposable, itself included, whether it is
//   eligible, and whether anything in it forces it top. A block is inside a
//   loop when it lies on a cycle of the function's control-flow graph; an
//   allocation marker there makes the function top. The first reason set is
//   kept, so the reason is `Loop` only if none was set before.
// - Phases B and C are `caphoist::solve`.
//
// A function is eligible when it is not interposable, its address is not taken,
// and it is local. With `closedWorld` set, local means not one of `roots`, and
// only references from top-level operations that are not symbols, or from
// symbols reachable from the roots or from those operations' targets, count as
// taking an address. Otherwise local means Internal or Private linkage, and
// every reference counts.
//
// The results are written as passthrough attributes on every defined
// `llvm.func`: `["eco-cap-budget", "<N>"]` or `"eco-cap-top"`, plus
// `"eco-cap-covered"` when covered. The settings the plan was made under go in
// the `eco-cap-plan` module flag, encoded by `caphoist::encodePlanStamp`.
//
// Phase A classifies calls the way LLVM will see them after the backend has
// expanded the markers that precede hoisting, using `markers::hoistView` and
// the other predicates of EcoMarkerFacts.h, and resolves callees as
// `llvm::CallBase::getCalledFunction` would.
//
//===----------------------------------------------------------------------===//
#include "../Passes.h"
#include "EcoCapHoistCore.h"
#include "EcoMarkerFacts.h"
#include "EcoSymbolGraph.h"
#include "EcoParallel.h"

#include "mlir/Dialect/LLVMIR/LLVMDialect.h"
#include "mlir/IR/Builders.h"
#include "mlir/IR/SymbolTable.h"
#include "mlir/IR/Threading.h"
#include "mlir/Pass/Pass.h"

#include "llvm/ADT/DenseMap.h"
#include "llvm/ADT/DenseSet.h"
#include "llvm/Support/raw_ostream.h"

#include <chrono>
#include <cstdlib>
#include <string>
#include <vector>

using namespace mlir;

namespace {

/// Returns whether `op`'s `passthrough` attribute holds `key`, either as a
/// bare string or as the first element of a key-value pair.
bool hasPassthrough(Operation *op, llvm::StringRef key) {
    auto pt = op->getAttrOfType<ArrayAttr>("passthrough");
    if (!pt)
        return false;
    for (Attribute a : pt) {
        if (auto s = dyn_cast<StringAttr>(a)) {
            if (s.getValue() == key)
                return true;
        } else if (auto kv = dyn_cast<ArrayAttr>(a)) {
            if (kv.size() >= 1)
                if (auto k = dyn_cast<StringAttr>(kv[0]))
                    if (k.getValue() == key)
                        return true;
        }
    }
    return false;
}
/// Returns whether `op` carries the passthrough `gc-leaf-function`.
bool isGcLeaf(Operation *op) { return hasPassthrough(op, "gc-leaf-function"); }
/// Returns whether `op` carries any of the `eco-cap-*` function attributes.
bool hasCapAttr(Operation *op) {
    return hasPassthrough(op, eco::caphoist::kAttrBudget) ||
           hasPassthrough(op, eco::caphoist::kAttrTop) ||
           hasPassthrough(op, eco::caphoist::kAttrCovered);
}
/// Returns whether environment variable `n` is set to anything other than an
/// empty string or `"0"`. It is read on every call.
bool envOn(const char *n) {
    const char *e = ::getenv(n);
    return e && *e && !(e[0] == '0' && e[1] == '\0');
}

/// One top-level symbol of the module, with its outgoing references, as this
/// pass uses them.
///
/// Elements are indexed as the nodes of the `symgraph::Graph` they are copied
/// from. `defined` is set only for a function with a body.
struct SymNode {
    /// The symbol operation, owned by the module.
    Operation *op = nullptr;
    bool isFunc = false, defined = false, interposable = false;
    std::vector<int> refs;     // every symbol referenced (reachability)
    std::vector<int> addrRefs; // references that take the address
    /// Index into the solver's node vector; -1 for a symbol that is not a defined function.
    int defIdx = -1;
};

/// The pass returned by `eco::createEcoCapHoistPlanPass`, registered as
/// `eco-cap-hoist-plan`.
struct EcoCapHoistPlanPass
    : public PassWrapper<EcoCapHoistPlanPass, OperationPass<ModuleOp>> {
    MLIR_DEFINE_EXPLICIT_INTERNAL_INLINE_TYPE_ID(EcoCapHoistPlanPass)

    /// Creates a pass with an open world and no roots.
    EcoCapHoistPlanPass() = default;
    /// Creates a pass that plans with `closedWorld`, treating `roots` as the
    /// externally visible entry points, named as in MLIR.
    EcoCapHoistPlanPass(bool closedWorld, std::vector<std::string> roots)
        : closedWorld(closedWorld), roots(std::move(roots)) {}
    /// Creates a copy of `o` with the same options, as MLIR does when it
    /// clones a pass.
    EcoCapHoistPlanPass(const EcoCapHoistPlanPass &o)
        : PassWrapper(o), closedWorld(o.closedWorld), roots(o.roots) {}

    StringRef getArgument() const final { return "eco-cap-hoist-plan"; }
    StringRef getDescription() const final {
        return "Capacity hoisting Phases A-C on llvm-dialect MLIR (CGEN_074)";
    }

    bool closedWorld = false;
    std::vector<std::string> roots;

    void runOnOperation() override;
};

void EcoCapHoistPlanPass::runOnOperation() {
    using namespace eco;
    ModuleOp module = getOperation();
    MLIRContext *ctx = &getContext();
    auto T0 = std::chrono::steady_clock::now();

    // Unless hoisting is on and GC-free stamping is selected, the module is
    // left unplanned.
    if (capHoistMode() != CapHoistMode::On ||
        gcFreeLeafMode() != GcFreeMode::Stamp)
        return;

    // A module that already has a plan flag is kept as it is.
    bool hasStamp = false;
    for (auto mf : module.getOps<LLVM::ModuleFlagsOp>())
        for (Attribute a : mf.getFlags())
            if (auto f = dyn_cast<LLVM::ModuleFlagAttr>(a))
                if (f.getKey().getValue() == caphoist::kPlanFlag)
                    hasStamp = true;
    if (hasStamp)
        return;
    for (auto f : module.getOps<LLVM::LLVMFuncOp>())
        if (hasCapAttr(f)) {
            f.emitError("eco-cap attributes without a plan stamp");
            return signalPassFailure();
        }

    // A definition that is already gc-leaf would be treated by Phase A as a
    // call that cannot allocate, so only the trusted names may be one here.
    for (auto f : module.getOps<LLVM::LLVMFuncOp>())
        if (!f.isExternal() && isGcLeaf(f) &&
            !markers::isTrustedLeafDecl(f.getSymName())) {
            f.emitError("defined function already gc-leaf before capacity "
                        "hoisting planning (R2)");
            return signalPassFailure();
        }

    symgraph::Graph sg = symgraph::build(module);
    std::vector<SymNode> nodes(sg.nodes.size());
    for (size_t i = 0; i < nodes.size(); ++i) {
        const symgraph::Node &gn = sg.nodes[i];
        SymNode &n = nodes[i];
        n.op = gn.op;
        n.isFunc = gn.isFunc;
        n.defined = gn.isFunc && gn.isDef;
        n.interposable = gn.interposable;
        for (uint32_t e = sg.outBegin[i]; e < sg.outBegin[i + 1]; ++e) {
            n.refs.push_back((int)sg.outTarget[e]);
            if (symgraph::takesAddress(sg.outKind[e]))
                n.addrRefs.push_back((int)sg.outTarget[e]);
        }
    }
    auto lookup = [&](StringAttr s) { return sg.lookup(s); };
    auto funcOf = [&](int i) -> LLVM::LLVMFuncOp {
        return i >= 0 ? dyn_cast<LLVM::LLVMFuncOp>(nodes[i].op)
                      : LLVM::LLVMFuncOp();
    };

    // `__eco_value_eq` counts as leaf when the environment says so, or when
    // the module itself marks `Elm_Kernel_Utils_equal` gc-leaf.
    bool valueEqLeaf = valueEqGcLeafEnv();
    {
        int ue = lookup(StringAttr::get(ctx, "Elm_Kernel_Utils_equal"));
        if (ue >= 0 && isGcLeaf(nodes[ue].op))
            valueEqLeaf = true;
    }
    std::vector<std::vector<int>> nonSymRefs(1), nonSymTakes(1);
    for (uint32_t r : sg.extraRoots)
        nonSymRefs[0].push_back((int)r);
    for (uint32_t t : sg.extraTakes)
        nonSymTakes[0].push_back((int)t);

    std::vector<char> isRoot(nodes.size(), 0), reached(nodes.size(), 0),
        addrTaken(nodes.size(), 0);
    for (const std::string &r : roots) {
        int i = lookup(StringAttr::get(ctx, r));
        if (i >= 0)
            isRoot[i] = 1;
    }
    if (closedWorld) {
        std::vector<int> q;
        auto push = [&](int i) {
            if (i >= 0 && !reached[i]) {
                reached[i] = 1;
                q.push_back(i);
            }
        };
        for (size_t i = 0; i < nodes.size(); ++i)
            if (isRoot[i])
                push((int)i);
        for (auto &v : nonSymRefs)
            for (int i : v)
                push(i);
        for (size_t h = 0; h < q.size(); ++h)
            for (int r : nodes[q[h]].refs)
                push(r);
    }
    for (size_t i = 0; i < nodes.size(); ++i)
        if (!closedWorld || reached[i])
            for (int g : nodes[i].addrRefs)
                addrTaken[g] = 1;
    for (auto &v : nonSymTakes)
        for (int g : v)
            addrTaken[g] = 1;

    // Phase A. Each call writes only its own `cn` entry.
    std::vector<int> defs;
    for (size_t i = 0; i < nodes.size(); ++i)
        if (nodes[i].isFunc && nodes[i].defined) {
            nodes[i].defIdx = (int)defs.size();
            defs.push_back((int)i);
        }
    std::vector<caphoist::Node> cn(defs.size());
    auto phaseA = [&](int self) {
        SymNode &sn = nodes[self];
        caphoist::Node &nd = cn[sn.defIdx];
        auto fn = cast<LLVM::LLVMFuncOp>(sn.op);
        auto setTop = [&](caphoist::Reason r) {
            nd.top = true;
            if (nd.reason == caphoist::Reason::None)
                nd.reason = r;
        };
        bool local;
        if (closedWorld) {
            local = !isRoot[self];
        } else {
            auto l = fn.getLinkage();
            local = l == LLVM::Linkage::Internal || l == LLVM::Linkage::Private;
        }
        nd.eligible = !sn.interposable && !addrTaken[self] && local;
        if (sn.interposable)
            setTop(caphoist::Reason::Other);

        // An iterative Tarjan walk from the entry block finds the blocks that
        // lie on a CFG cycle. Blocks unreachable from the entry are never
        // visited, so they never count as in a loop.
        Region &body = fn.getBody();
        llvm::DenseSet<Block *> inCycle;
        {
            llvm::DenseMap<Block *, unsigned> idx, low;
            llvm::DenseSet<Block *> onStack;
            std::vector<Block *> stk;
            unsigned next = 0;
            struct Fr {
                Block *b;
                unsigned i;
            };
            std::vector<Fr> work;
            Block *entry = &body.front();
            idx[entry] = low[entry] = next++;
            onStack.insert(entry);
            stk.push_back(entry);
            work.push_back({entry, 0});
            while (!work.empty()) {
                Block *b = work.back().b;
                unsigned i = work.back().i;
                if (i < b->getNumSuccessors()) {
                    work.back().i = i + 1;
                    Block *s = b->getSuccessor(i);
                    if (!idx.count(s)) {
                        idx[s] = low[s] = next++;
                        onStack.insert(s);
                        stk.push_back(s);
                        work.push_back({s, 0});
                    } else if (onStack.count(s)) {
                        low[b] = std::min(low[b], idx[s]);
                    }
                    continue;
                }
                work.pop_back();
                if (!work.empty())
                    low[work.back().b] = std::min(low[work.back().b], low[b]);
                if (low[b] != idx[b])
                    continue;
                std::vector<Block *> scc;
                for (;;) {
                    Block *w = stk.back();
                    stk.pop_back();
                    onStack.erase(w);
                    scc.push_back(w);
                    if (w == b)
                        break;
                }
                bool cyc = scc.size() > 1;
                if (!cyc)
                    for (Block *s : scc[0]->getSuccessors())
                        if (s == scc[0])
                            cyc = true;
                if (cyc)
                    for (Block *w : scc)
                        inCycle.insert(w);
            }
        }

        fn.walk([&](LLVM::CallOp call) {
            // A call in a nested region is placed at its ancestor in the body.
            Block *blk = call->getBlock();
            while (blk && blk->getParent() != &body)
                blk = blk->getParentOp() ? blk->getParentOp()->getBlock()
                                         : nullptr;
            const bool inLoop = blk && inCycle.count(blk);

            // Resolve the callee as llvm::CallBase::getCalledFunction does: an
            // indirect call through an addressof of a function of the same type
            // counts as direct.
            StringRef cname;
            int ci = -1;
            bool direct = false, viaOperand = false;
            if (auto c = call.getCallee()) {
                cname = *c;
                ci = lookup(StringAttr::get(ctx, cname));
                direct = true;
            } else if (auto ao = call->getOperand(0)
                                     .getDefiningOp<LLVM::AddressOfOp>()) {
                cname = ao.getGlobalName();
                ci = lookup(ao.getGlobalNameAttr().getAttr());
                LLVM::LLVMFuncOp gf = funcOf(ci);
                if (gf && call.getCalleeFunctionType() == gf.getFunctionType())
                    direct = true;
                else
                    viaOperand = true;
            }

            if (direct && cname == "__eco_alloc_inline") {
                uint64_t sz = 0;
                if (auto cst = call->getOperand(0)
                                   .getDefiningOp<LLVM::ConstantOp>())
                    if (auto ia = dyn_cast<IntegerAttr>(cst.getValue()))
                        sz = ia.getValue().getZExtValue();
                if (inLoop)
                    setTop(caphoist::Reason::Loop);
                else
                    nd.ownBytes += sz;
                return;
            }
            if (direct && markers::isHeadroomBreaker(cname)) {
                setTop(caphoist::Reason::Other);
                return;
            }
            if (direct) {
                markers::Hoist h = markers::hoistView(cname, valueEqLeaf);
                if (h == markers::Hoist::Leaf)
                    return;
                if (h == markers::Hoist::NotLeaf) {
                    setTop(caphoist::Reason::Other);
                    return;
                }
                if (ci >= 0 && isGcLeaf(nodes[ci].op))
                    return; // the callee's own gc-leaf attribute
                if (ci >= 0 && !nodes[ci].defined &&
                    markers::isLibmLeaf(cname))
                    return; // a libm function LLVM knows cannot collect
                if (ci >= 0 && nodes[ci].isFunc && nodes[ci].defined &&
                    !nodes[ci].interposable) {
                    nd.callees.push_back({(uint32_t)nodes[ci].defIdx, inLoop});
                    if (ci == self)
                        nd.selfEdge = true;
                    return;
                }
                setTop(caphoist::Reason::Other);
                return;
            }
            // An indirect call through a gc-leaf function of a different type
            // is still leaf; its type is not checked.
            if (viaOperand && ci >= 0 && isGcLeaf(nodes[ci].op))
                return;
            setTop(caphoist::Reason::Other);
        });
    };
    eco::forEachChunk(ctx, defs.size(), [&](size_t lo, size_t hi) {
        for (size_t k = lo; k < hi; ++k)
            phaseA(defs[k]);
    });

    // Phases B and C.
    const unsigned K = capHoistMaxBytes();
    caphoist::solve(cn, K);

    // The stamps are appended to any existing passthrough entries.
    unsigned nCovered = 0, nTop = 0, nZero = 0;
    for (size_t k = 0; k < defs.size(); ++k) {
        auto fn = cast<LLVM::LLVMFuncOp>(nodes[defs[k]].op);
        const caphoist::Node &nd = cn[k];
        SmallVector<Attribute> pt;
        if (auto old = fn->getAttrOfType<ArrayAttr>("passthrough"))
            pt.append(old.begin(), old.end());
        if (nd.top) {
            pt.push_back(StringAttr::get(ctx, caphoist::kAttrTop));
            ++nTop;
        } else {
            pt.push_back(ArrayAttr::get(
                ctx, {StringAttr::get(ctx, caphoist::kAttrBudget),
                      StringAttr::get(ctx, std::to_string(nd.budget))}));
            if (nd.budget == 0)
                ++nZero;
        }
        if (nd.covered) {
            pt.push_back(StringAttr::get(ctx, caphoist::kAttrCovered));
            ++nCovered;
        }
        fn->setAttr("passthrough", ArrayAttr::get(ctx, pt));
    }

    // The flag is appended to the last module-flags op, or to a new one.
    caphoist::PlanStamp stamp;
    stamp.K = K;
    stamp.m2 = capHoistFoldOwnMarkers();
    stamp.closedWorld = closedWorld;
    stamp.valueEqLeaf = valueEqLeaf;
    auto flag = LLVM::ModuleFlagAttr::get(
        ctx, LLVM::ModFlagBehavior::Warning,
        StringAttr::get(ctx, caphoist::kPlanFlag),
        StringAttr::get(ctx, caphoist::encodePlanStamp(stamp)));
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

    if (envOn("ECO_CAPHOIST_PLAN_STATS"))
        llvm::errs() << "[caphoist-plan] defined=" << defs.size()
                     << " covered=" << nCovered << " top=" << nTop
                     << " budget0=" << nZero << " closed_world=" << closedWorld
                     << " value_eq_leaf=" << valueEqLeaf << " time="
                     << std::chrono::duration<double>(
                            std::chrono::steady_clock::now() - T0)
                            .count()
                     << "s\n";
}

} // namespace

namespace eco {
std::unique_ptr<mlir::Pass>
createEcoCapHoistPlanPass(bool closedWorld, std::vector<std::string> roots) {
    return std::make_unique<EcoCapHoistPlanPass>(closedWorld, std::move(roots));
}
} // namespace eco
