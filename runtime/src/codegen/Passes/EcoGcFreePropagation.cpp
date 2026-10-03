//===- EcoGcFreePropagation.cpp - GC-free leaf stamps on the MLIR side ----===//
//
// plans/mlir-split-backend-02-gc-leaf-propagation.md Part II Q4, CGEN_072.
//
// Stamps passthrough "gc-leaf-function" on every defined llvm.func that
// provably cannot reach a GC once the backend has expanded its markers, and
// records the module flag "eco-gcfree-plan" = "v1;veq=..;cov=..". The LLVM
// backend then trusts these stamps (it no longer runs its own fixpoint at the
// pre-RS4GC choke point except as a validate twin), so a later partition
// split needs no whole-program view to decide them.
//
// The classification replicates EcoBackend.cpp's propagateGcFreeLeafAttrs as
// it sees the module AFTER every pre-RS4GC expansion: markers are read through
// the shared table's final view (EcoMarkerFacts.h), and the one fact owed to
// capacity hoisting is eco-cap-covered (01): a covered function's markers are
// unchecked bumps (leaf); a non-covered function's markers keep a slow call or
// an ensure; a non-covered caller of a covered callee holds an ensure.
// Plan 00 SP3 measured an exact match with the LLVM fixpoint.
//
// MUST be the last pass that changes llvm-dialect bodies (plan 02 O8): a
// later rewrite could invalidate a stamp that no per-partition check sees.
//
//===----------------------------------------------------------------------===//
#include "../Passes.h"
#include "EcoCapHoistCore.h"
#include "EcoMarkerFacts.h"
#include "EcoParallel.h"

#include "mlir/Dialect/LLVMIR/LLVMDialect.h"
#include "mlir/IR/Builders.h"
#include "mlir/IR/SymbolTable.h"
#include "mlir/IR/Threading.h"
#include "mlir/Interfaces/CallInterfaces.h"
#include "mlir/Pass/Pass.h"

#include "llvm/ADT/DenseMap.h"
#include "llvm/IR/Intrinsics.h"
#include "llvm/Support/raw_ostream.h"

#include <chrono>
#include <string>
#include <vector>

using namespace mlir;

namespace {

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
bool isGcLeaf(Operation *op) { return hasPassthrough(op, "gc-leaf-function"); }

bool envOn(const char *n) {
    const char *e = ::getenv(n);
    return e && *e && !(e[0] == '0' && e[1] == '\0');
}

// The intrinsic arm of llvm::callsGCLeafFunction: a RECOGNISED intrinsic other
// than the four that can take a safepoint.
bool isLeafIntrinsic(llvm::StringRef name) {
    if (!name.starts_with("llvm."))
        return false;
    llvm::Intrinsic::ID id = llvm::Intrinsic::lookupIntrinsicID(name);
    return id != llvm::Intrinsic::not_intrinsic &&
           id != llvm::Intrinsic::experimental_gc_statepoint &&
           id != llvm::Intrinsic::experimental_deoptimize &&
           id != llvm::Intrinsic::memcpy_element_unordered_atomic &&
           id != llvm::Intrinsic::memmove_element_unordered_atomic;
}

std::optional<llvm::StringRef> moduleFlag(ModuleOp module, llvm::StringRef key) {
    for (auto mf : module.getOps<LLVM::ModuleFlagsOp>())
        for (Attribute a : mf.getFlags())
            if (auto f = dyn_cast<LLVM::ModuleFlagAttr>(a))
                if (f.getKey().getValue() == key) {
                    if (auto s = dyn_cast<StringAttr>(f.getValue()))
                        return s.getValue();
                    return llvm::StringRef();
                }
    return std::nullopt;
}

struct SymNode {
    Operation *op = nullptr;
    bool isFunc = false, defined = false, interposable = false,
         covered = false;
};

struct EcoGcFreePropagationPass
    : public PassWrapper<EcoGcFreePropagationPass, OperationPass<ModuleOp>> {
    MLIR_DEFINE_EXPLICIT_INTERNAL_INLINE_TYPE_ID(EcoGcFreePropagationPass)

    StringRef getArgument() const final { return "eco-gcfree-propagation"; }
    StringRef getDescription() const final {
        return "GC-free leaf propagation on llvm-dialect MLIR (CGEN_072)";
    }

    void runOnOperation() override;
};

void EcoGcFreePropagationPass::runOnOperation() {
    using namespace eco;
    ModuleOp module = getOperation();
    MLIRContext *ctx = &getContext();
    auto T0 = std::chrono::steady_clock::now();

    // 1. Gate.
    if (gcFreeLeafMode() != GcFreeMode::Stamp || !gcFreeMlirEnabled())
        return;

    // 2. Pre-planned input (re-lowered dumps, fixtures).
    if (moduleFlag(module, gcfree::kPlanFlag))
        return;
    for (auto f : module.getOps<LLVM::LLVMFuncOp>())
        if (!f.isExternal() && isGcLeaf(f) &&
            !markers::isTrustedLeafDecl(f.getSymName())) {
            f.emitError("gc-leaf definition without a gc-free plan");
            return signalPassFailure();
        }

    // 3. Coverage source: only a capacity-hoisting plan makes markers of a
    //    covered function unchecked.
    std::optional<llvm::StringRef> capFlag =
        moduleFlag(module, caphoist::kPlanFlag);
    const bool cov = capFlag.has_value();
    if (!cov)
        for (auto f : module.getOps<LLVM::LLVMFuncOp>())
            if (hasPassthrough(f, caphoist::kAttrCovered)) {
                f.emitError("eco-cap-covered without a capacity-hoisting plan");
                return signalPassFailure();
            }

    // 5. Index.
    std::vector<SymNode> nodes;
    llvm::DenseMap<StringAttr, int> index;
    for (Operation &op : *module.getBody()) {
        auto nameAttr =
            op.getAttrOfType<StringAttr>(SymbolTable::getSymbolAttrName());
        if (!nameAttr)
            continue;
        SymNode n;
        n.op = &op;
        if (auto f = dyn_cast<LLVM::LLVMFuncOp>(op)) {
            n.isFunc = true;
            n.defined = !f.isExternal();
            auto l = f.getLinkage();
            n.interposable = l == LLVM::Linkage::Weak ||
                             l == LLVM::Linkage::Linkonce ||
                             l == LLVM::Linkage::ExternWeak ||
                             l == LLVM::Linkage::Common;
            n.covered = hasPassthrough(f, caphoist::kAttrCovered);
        }
        index[nameAttr] = (int)nodes.size();
        nodes.push_back(n);
    }
    auto lookup = [&](StringAttr s) {
        auto it = index.find(s);
        return it == index.end() ? -1 : it->second;
    };

    // 4. veq: the value-eq row (O5), identical to the capacity plan's.
    bool veq = valueEqGcLeafEnv();
    {
        int ue = lookup(StringAttr::get(ctx, "Elm_Kernel_Utils_equal"));
        if (ue >= 0 && isGcLeaf(nodes[ue].op))
            veq = true;
    }
    if (cov) {
        auto capStamp = caphoist::parsePlanStamp(*capFlag);
        if (!capStamp) {
            module.emitError("malformed capacity-hoisting plan stamp");
            return signalPassFailure();
        }
        if (capStamp->valueEqLeaf != veq) {
            module.emitError("value-eq leafness disagrees with the "
                             "capacity-hoisting plan stamp");
            return signalPassFailure();
        }
    }

    // 6. Per-function facts, in parallel.
    std::vector<int> defs;
    for (size_t i = 0; i < nodes.size(); ++i)
        if (nodes[i].isFunc && nodes[i].defined)
            defs.push_back((int)i);
    std::vector<char> poison(nodes.size(), 0);
    std::vector<std::vector<int>> callees(nodes.size());
    std::vector<std::string> noRow(nodes.size());

    auto scanFn = [&](int self) {
        SymNode &sn = nodes[self];
        auto fn = cast<LLVM::LLVMFuncOp>(sn.op);
        bool p = sn.interposable;
        llvm::DenseSet<int> seen;
        fn.walk([&](Operation *op) -> WalkResult {
            if (isa<LLVM::InvokeOp, LLVM::LandingpadOp, LLVM::InlineAsmOp>(op) ||
                (isa<CallOpInterface>(op) && !isa<LLVM::CallOp>(op))) {
                p = true;
                return WalkResult::interrupt();
            }
            auto call = dyn_cast<LLVM::CallOp>(op);
            if (!call)
                return WalkResult::advance();

            // Resolve as llvm::CallBase::getCalledFunction would.
            int ci = -1;
            bool direct = false, viaOperand = false;
            if (auto c = call.getCalleeAttr()) {
                ci = lookup(c.getAttr());
                direct = true;
            } else if (auto ao = call->getOperand(0)
                                     .getDefiningOp<LLVM::AddressOfOp>()) {
                ci = lookup(ao.getGlobalNameAttr().getAttr());
                auto gf = ci >= 0 ? dyn_cast<LLVM::LLVMFuncOp>(nodes[ci].op)
                                  : LLVM::LLVMFuncOp();
                if (gf && call.getCalleeFunctionType() == gf.getFunctionType())
                    direct = true;
                else
                    viaOperand = true;
            }

            if (!direct) {
                // callsGCLeafFunction reads the called operand's attributes
                // with no type check: a gc-leaf declaration stays leaf (E6).
                if (viaOperand && ci >= 0 && nodes[ci].isFunc &&
                    !nodes[ci].defined && isGcLeaf(nodes[ci].op))
                    return WalkResult::advance();
                p = true;
                return WalkResult::interrupt();
            }
            if (ci < 0 || !nodes[ci].isFunc) {
                p = true; // unresolved symbol: never expected
                return WalkResult::interrupt();
            }
            const SymNode &g = nodes[ci];
            // A non-covered caller of a covered callee holds an ensure (O3).
            if (g.covered && !sn.covered) {
                p = true;
                return WalkResult::interrupt();
            }
            if (g.defined) {
                if (g.interposable) {
                    p = true;
                    return WalkResult::interrupt();
                }
                if (seen.insert(ci).second)
                    callees[self].push_back(ci);
                return WalkResult::advance();
            }
            llvm::StringRef name = cast<LLVM::LLVMFuncOp>(g.op).getSymName();
            switch (markers::finalView(name)) {
            case markers::Final::Leaf:
                return WalkResult::advance();
            case markers::Final::Poison:
                p = true;
                return WalkResult::interrupt();
            case markers::Final::UnlessCovered:
                if (sn.covered)
                    return WalkResult::advance();
                p = true;
                return WalkResult::interrupt();
            case markers::Final::ValueEq:
                if (veq)
                    return WalkResult::advance();
                p = true;
                return WalkResult::interrupt();
            case markers::Final::FromDecl:
                break;
            }
            if (markers::isMarkerName(name)) {
                noRow[self] = name.str();
                p = true;
                return WalkResult::interrupt();
            }
            if (isGcLeaf(g.op) || markers::isLibmLeaf(name) ||
                isLeafIntrinsic(name))
                return WalkResult::advance();
            p = true;
            return WalkResult::interrupt();
        });
        poison[self] = p;
    };
    eco::forEachChunk(ctx, defs.size(), [&](size_t lo, size_t hi) {
        for (size_t k = lo; k < hi; ++k)
            scanFn(defs[k]);
    });

    for (int i : defs)
        if (!noRow[i].empty()) {
            nodes[i].op->emitError("call to marker '")
                << noRow[i] << "' without a table row (EcoMarkerFacts.h)";
            return signalPassFailure();
        }

    // 7. Fixpoint: poison flows callee -> caller.
    std::vector<std::vector<int>> callers(nodes.size());
    std::vector<int> wl;
    for (int i : defs) {
        for (int c : callees[i])
            callers[c].push_back(i);
        if (poison[i])
            wl.push_back(i);
    }
    while (!wl.empty()) {
        int c = wl.back();
        wl.pop_back();
        for (int caller : callers[c])
            if (!poison[caller]) {
                poison[caller] = 1;
                wl.push_back(caller);
            }
    }

    // 8. Stamp.
    unsigned nFree = 0;
    for (int i : defs) {
        if (poison[i])
            continue;
        ++nFree;
        Operation *op = nodes[i].op;
        if (isGcLeaf(op))
            continue;
        SmallVector<Attribute> pt;
        if (auto old = op->getAttrOfType<ArrayAttr>("passthrough"))
            pt.append(old.begin(), old.end());
        pt.push_back(StringAttr::get(ctx, "gc-leaf-function"));
        op->setAttr("passthrough", ArrayAttr::get(ctx, pt));
    }

    // 9. The plan flag.
    gcfree::Stamp stamp;
    stamp.valueEqLeaf = veq;
    stamp.covered = cov;
    auto flag = LLVM::ModuleFlagAttr::get(
        ctx, LLVM::ModFlagBehavior::Warning,
        StringAttr::get(ctx, gcfree::kPlanFlag),
        StringAttr::get(ctx, gcfree::encodeStamp(stamp)));
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

    // 10. Stats.
    if (envOn("ECO_GCFREE_PLAN_STATS"))
        llvm::errs() << "[gcfree-plan] defined=" << defs.size()
                     << " free=" << nFree << " cov=" << cov << " veq=" << veq
                     << " time="
                     << std::chrono::duration<double>(
                            std::chrono::steady_clock::now() - T0)
                            .count()
                     << "s\n";
}

} // namespace

namespace eco {
std::unique_ptr<mlir::Pass> createEcoGcFreePropagationPass() {
    return std::make_unique<EcoGcFreePropagationPass>();
}
} // namespace eco
