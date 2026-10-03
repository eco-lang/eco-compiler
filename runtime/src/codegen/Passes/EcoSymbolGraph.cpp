//===- EcoSymbolGraph.cpp - Symbol reference graph of an llvm-dialect module ===//
//
// See EcoSymbolGraph.h.
//
//===----------------------------------------------------------------------===//
#include "EcoSymbolGraph.h"
#include "EcoParallel.h"

#include "mlir/Dialect/LLVMIR/LLVMDialect.h"
#include "mlir/IR/SymbolTable.h"
#include "mlir/IR/Threading.h"

#include <algorithm>
#include <cstdlib>
#include <utility>

using namespace mlir;

namespace eco::symgraph {

namespace {

using EdgeList = std::vector<std::pair<uint32_t, uint8_t>>;

/// Attribute kinds that never contain a symbol reference: skipped instead of
/// walked (an Attribute::walk allocates its visited set).
bool isSymbolFreeLeaf(Attribute a) {
    return isa<IntegerAttr, FloatAttr, StringAttr, TypeAttr, UnitAttr,
               DenseArrayAttr, DenseIntOrFPElementsAttr, LLVM::LinkageAttr,
               LLVM::CConvAttr, LLVM::FastmathFlagsAttr>(a);
}

void visitAttr(Attribute a, bool isCallee,
               llvm::function_ref<void(SymbolRefAttr, bool)> fn) {
    if (!a || isSymbolFreeLeaf(a))
        return;
    if (auto r = dyn_cast<SymbolRefAttr>(a)) {
        fn(r, isCallee);
        return;
    }
    a.walk([&](SymbolRefAttr r) { fn(r, isCallee); });
}

enum class RefMode { Fast, Dictionary };

void forEachRef(Operation *op, RefMode mode,
                llvm::function_ref<void(SymbolRefAttr, bool)> fn) {
    const bool isCall = isa<LLVM::CallOp>(op);
    if (mode == RefMode::Dictionary) {
        // The pre-plan-07 semantics, kept for the validate twin.
        for (NamedAttribute na : op->getAttrDictionary())
            na.getValue().walk([&](SymbolRefAttr r) {
                fn(r, isCall && na.getName().getValue() == "callee");
            });
        return;
    }
    if (auto call = dyn_cast<LLVM::CallOp>(op)) {
        // llvm.call's only symbol-carrying inherent attribute is `callee`;
        // populating the rest would unique e.g. its operandSegmentSizes.
        if (auto callee = call.getCalleeAttr())
            fn(callee, true);
        for (NamedAttribute na : op->getRawDictionaryAttrs())
            visitAttr(na.getValue(), false, fn);
        return;
    }
    if (op->getPropertiesStorage()) {
        NamedAttrList inherent;
        op->getName().populateInherentAttrs(op, inherent);
        for (NamedAttribute na : inherent)
            visitAttr(na.getValue(), false, fn);
    }
    // With properties the raw dictionary holds only the discardable
    // attributes; without, it holds them all (== getAttrDictionary()).
    for (NamedAttribute na : op->getRawDictionaryAttrs())
        visitAttr(na.getValue(), false, fn);
}

void collect(Operation *root, const Graph &g, EdgeList &out,
             bool keepUnusedAddressOf, RefMode mode = RefMode::Fast) {
    auto add = [&](StringAttr s, uint8_t kind) {
        int t = g.lookup(s);
        if (t >= 0)
            out.push_back({(uint32_t)t, kind});
    };
    root->walk([&](Operation *op) {
        if (auto ao = dyn_cast<LLVM::AddressOfOp>(op)) {
            if (ao->use_empty()) {
                if (keepUnusedAddressOf)
                    add(ao.getGlobalNameAttr().getAttr(), Address);
                return; // no LLVM use after translation
            }
            StringAttr name = ao.getGlobalNameAttr().getAttr();
            int t = g.lookup(name);
            if (t < 0)
                return;
            auto fn = dyn_cast<LLVM::LLVMFuncOp>(g.nodes[t].op);
            bool allCallee = true, mismatch = false;
            for (OpOperand &use : ao->getUses()) {
                auto call = dyn_cast<LLVM::CallOp>(use.getOwner());
                if (!fn || !call || call.getCallee() ||
                    use.getOperandNumber() != 0) {
                    allCallee = false;
                    break;
                }
                if (call.getCalleeFunctionType() != fn.getFunctionType())
                    mismatch = true;
            }
            add(name, !allCallee ? Address : mismatch ? CallMismatch : Call);
            return;
        }
        forEachRef(op, mode, [&](SymbolRefAttr r, bool isCallee) {
            add(r.getRootReference(), isCallee ? Call : Address);
        });
    });
    // Dedup per target, OR-ing the kinds.
    std::sort(out.begin(), out.end());
    size_t w = 0;
    for (size_t r = 0; r < out.size(); ++r) {
        if (w > 0 && out[w - 1].first == out[r].first)
            out[w - 1].second |= out[r].second;
        else
            out[w++] = out[r];
    }
    out.resize(w);
}

bool symrefValidate() {
    static const bool on = [] {
        const char *e = ::getenv("ECO_SYMREF_VALIDATE");
        return e && *e && *e != '0';
    }();
    return on;
}

} // namespace

Graph build(ModuleOp module, bool keepUnusedAddressOf) {
    Graph g;
    std::vector<Operation *> nonSymbol;
    for (Operation &op : *module.getBody()) {
        auto nameAttr =
            op.getAttrOfType<StringAttr>(SymbolTable::getSymbolAttrName());
        if (!nameAttr) {
            nonSymbol.push_back(&op);
            continue;
        }
        Node n;
        n.op = &op;
        n.name = nameAttr;
        if (auto f = dyn_cast<LLVM::LLVMFuncOp>(op)) {
            n.isFunc = true;
            n.isDef = !f.isExternal();
            auto l = f.getLinkage();
            n.interposable = l == LLVM::Linkage::Weak ||
                             l == LLVM::Linkage::Linkonce ||
                             l == LLVM::Linkage::ExternWeak ||
                             l == LLVM::Linkage::Common;
        } else if (auto gv = dyn_cast<LLVM::GlobalOp>(op)) {
            n.isGlobal = true;
            n.isDef = gv.getValueAttr() || !gv.getInitializerRegion().empty();
        }
        g.index[nameAttr] = (uint32_t)g.nodes.size();
        g.nodes.push_back(n);
    }

    std::vector<EdgeList> lists(g.nodes.size());
    eco::forEachChunk(module.getContext(), g.nodes.size(),
                      [&](size_t lo, size_t hi) {
                          for (size_t i = lo; i < hi; ++i)
                              collect(g.nodes[i].op, g, lists[i],
                                      keepUnusedAddressOf);
                      });
    if (symrefValidate()) {
        // Twin: the dictionary walk must find exactly the same edges.
        for (size_t i = 0; i < g.nodes.size(); ++i) {
            EdgeList ref;
            collect(g.nodes[i].op, g, ref, keepUnusedAddressOf,
                    RefMode::Dictionary);
            if (ref != lists[i]) {
                llvm::errs() << "ECO_SYMREF_VALIDATE: edge mismatch in @"
                             << g.nodes[i].name.getValue() << " (fast "
                             << lists[i].size() << " edges, dictionary "
                             << ref.size() << ")\n";
                ::abort();
            }
        }
    }

    g.outBegin.resize(g.nodes.size() + 1, 0);
    size_t total = 0;
    for (size_t i = 0; i < lists.size(); ++i) {
        g.outBegin[i] = (uint32_t)total;
        total += lists[i].size();
    }
    g.outBegin[lists.size()] = (uint32_t)total;
    g.outTarget.reserve(total);
    g.outKind.reserve(total);
    for (auto &l : lists)
        for (auto &e : l) {
            g.outTarget.push_back(e.first);
            g.outKind.push_back(e.second);
        }

    for (Operation *op : nonSymbol) {
        EdgeList l;
        collect(op, g, l, keepUnusedAddressOf);
        for (auto &e : l) {
            g.extraRoots.push_back(e.first);
            if (takesAddress(e.second))
                g.extraTakes.push_back(e.first);
        }
    }
    return g;
}

void forEachSymbolRef(Operation *op,
                      llvm::function_ref<void(SymbolRefAttr, bool)> fn) {
    forEachRef(op, RefMode::Fast, fn);
}

llvm::StringMap<bool> addressTakenByName(ModuleOp module) {
    Graph g = build(module);
    std::vector<char> taken(g.nodes.size(), 0);
    for (size_t i = 0; i < g.outTarget.size(); ++i)
        if (takesAddress(g.outKind[i]))
            taken[g.outTarget[i]] = 1;
    for (uint32_t t : g.extraTakes)
        taken[t] = 1;
    llvm::StringMap<bool> out;
    for (size_t i = 0; i < g.nodes.size(); ++i)
        if (g.nodes[i].isFunc && g.nodes[i].isDef)
            out[g.nodes[i].name.getValue()] = taken[i];
    return out;
}

} // namespace eco::symgraph
