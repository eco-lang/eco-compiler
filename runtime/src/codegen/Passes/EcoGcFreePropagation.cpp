//===- EcoGcFreePropagation.cpp - GC-free leaf stamps on the MLIR side ----===//
//
// RS4GC places a statepoint at every call that is not to a gc-leaf function,
// so a generated function that can never reach a collection should carry the
// gc-leaf mark, and its callers then need no statepoint for it. This pass
// decides which generated functions qualify, on the final llvm-dialect
// module, and stamps them (CGEN_072).
//
// A function is GC-free when nothing it can call, directly or through other
// defined functions, can start a collection, as far as the pass can tell.
// The opposite is "poisoned". The pass decides this as the module will look
// after the backend has expanded every `__eco_*` marker, which it cannot see
// yet; how each marker counts after expansion is read from
// `eco::markers::finalView`, which owns that table. One fact comes from
// capacity hoisting: a function stamped `eco-cap-covered` has its allocation
// markers expanded as unchecked bumps, while a function that is not covered
// keeps a check that can collect, and so does a function that is not covered
// when it calls one that is.
//
// The product is the passthrough `"gc-leaf-function"` on each GC-free
// definition, and the module flag `eco-gcfree-plan`, an encoded
// `eco::gcfree::Stamp` recording whether a capacity-hoisting plan was taken
// into account and whether `Elm_Kernel_Utils_equal` counted as gc-leaf. A
// stamp must stay true, so this has to be the last pass that changes
// llvm-dialect bodies.
//
// The work is in two parts. Each defined function is scanned on its own, in
// parallel, for calls that poison it and for the defined functions it calls.
// Poison then flows from callee to caller over that call graph, serially,
// until nothing changes.
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

// Returns whether `op` has a `passthrough` entry named `key`, either as a
// bare string or as the key of a key-value pair.
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
// Returns whether `op` carries the passthrough `"gc-leaf-function"`.
bool isGcLeaf(Operation *op) { return hasPassthrough(op, "gc-leaf-function"); }

// Returns whether the environment variable `n` is set to anything other than
// an empty string or `"0"`. It is read on every call.
bool envOn(const char *n) {
    const char *e = ::getenv(n);
    return e && *e && !(e[0] == '0' && e[1] == '\0');
}

// Returns whether `name` is an LLVM intrinsic that LLVM's RS4GC treats as
// gc-leaf: any intrinsic LLVM recognises, except the four that can take a
// safepoint. An `llvm.` name LLVM does not recognise is not leaf.
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

// Returns the value of the module flag `key`, or `std::nullopt` if no
// `llvm.module_flags` op in `module` has it. A flag whose value is not a
// string gives an empty string. The returned reference points into the
// context's attribute storage.
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

/**
 * What the pass needs to know about one top-level symbol of the module.
 * Fields other than `op` are set only for an `llvm.func`.
 */
struct SymNode {
    Operation *op = nullptr; // The symbol op; it belongs to the module.
    // `interposable` means weak, linkonce, extern-weak or common linkage,
    // where the definition seen here may not be the one called at run time.
    // `covered` means the function has the `eco-cap-covered` passthrough.
    bool isFunc = false, defined = false, interposable = false,
         covered = false;
};

/**
 * The pass that stamps GC-free definitions and records the plan flag.
 *
 * It does nothing unless `eco::gcFreeLeafMode()` is `Stamp` and
 * `eco::gcFreeMlirEnabled()` holds, and it leaves a module that already has
 * an `eco-gcfree-plan` flag unchanged. It fails on a gc-leaf definition
 * whose name `eco::markers::isTrustedLeafDecl` does not accept, on
 * `eco-cap-covered` with no capacity-hoisting plan flag, on a malformed
 * capacity-hoisting plan, on a value-eq setting that differs from the one
 * the capacity-hoisting plan recorded, and on an `__eco_` call with no
 * `finalView` row when that call is the first poisoning call its function's
 * scan reaches. With `ECO_GCFREE_PLAN_STATS` non-empty and not "0" it prints
 * counts and the time taken to stderr.
 */
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

    if (gcFreeLeafMode() != GcFreeMode::Stamp || !gcFreeMlirEnabled())
        return;

    // A module that already has a plan keeps it.
    if (moduleFlag(module, gcfree::kPlanFlag))
        return;
    for (auto f : module.getOps<LLVM::LLVMFuncOp>())
        if (!f.isExternal() && isGcLeaf(f) &&
            !markers::isTrustedLeafDecl(f.getSymName())) {
            f.emitError("gc-leaf definition without a gc-free plan");
            return signalPassFailure();
        }

    // Only a capacity-hoisting plan makes a covered function's markers
    // unchecked, so `eco-cap-covered` without one is an error.
    std::optional<llvm::StringRef> capFlag =
        moduleFlag(module, caphoist::kPlanFlag);
    const bool cov = capFlag.has_value();
    if (!cov)
        for (auto f : module.getOps<LLVM::LLVMFuncOp>())
            if (hasPassthrough(f, caphoist::kAttrCovered)) {
                f.emitError("eco-cap-covered without a capacity-hoisting plan");
                return signalPassFailure();
            }

    // Index every top-level symbol by name.
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

    // Whether `__eco_value_eq` counts as leaf. It must agree with the value
    // the capacity-hoisting plan recorded.
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

    // Per-function scan, in parallel. A worker writes only the entries of
    // `poison`, `callees` and `noRow` at the index it scans. The walk stops
    // at the first call that poisons the function.
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

            // Resolve as llvm::CallBase::getCalledFunction would: a direct
            // callee, or the address of a function whose type matches the
            // call's.
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
                // LLVM's callsGCLeafFunction reads the called operand's
                // attributes with no type check, so a call through the
                // address of a gc-leaf declaration stays leaf.
                if (viaOperand && ci >= 0 && nodes[ci].isFunc &&
                    !nodes[ci].defined && isGcLeaf(nodes[ci].op))
                    return WalkResult::advance();
                p = true;
                return WalkResult::interrupt();
            }
            if (ci < 0 || !nodes[ci].isFunc) {
                p = true; // An unresolved symbol, or one that is not a function.
                return WalkResult::interrupt();
            }
            const SymNode &g = nodes[ci];
            // A caller that is not covered keeps a capacity check before a
            // covered callee, and the check can collect.
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

    // Poison flows from callee to caller until nothing changes.
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

    // Stamp. A definition that already carries gc-leaf keeps it, poisoned
    // or not; only a trusted name can reach here with one.
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

    // Append the plan flag to the last module-flags op, or create one.
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
