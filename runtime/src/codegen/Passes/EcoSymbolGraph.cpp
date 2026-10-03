//===- EcoSymbolGraph.cpp - Symbol reference graph of an llvm-dialect module ===//
//
// See EcoSymbolGraph.h.
//
//===----------------------------------------------------------------------===//
#include "EcoSymbolGraph.h"

#include "mlir/Dialect/LLVMIR/LLVMDialect.h"
#include "mlir/IR/SymbolTable.h"
#include "mlir/IR/Threading.h"

#include <algorithm>
#include <utility>

using namespace mlir;

namespace eco::symgraph {

namespace {

using EdgeList = std::vector<std::pair<uint32_t, uint8_t>>;

void collect(Operation *root, const Graph &g, EdgeList &out,
             bool keepUnusedAddressOf) {
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
        const bool isCall = isa<LLVM::CallOp>(op);
        for (NamedAttribute na : op->getAttrDictionary()) {
            const uint8_t kind =
                isCall && na.getName().getValue() == "callee" ? Call : Address;
            na.getValue().walk(
                [&](SymbolRefAttr r) { add(r.getRootReference(), kind); });
        }
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
    std::vector<uint32_t> idx(g.nodes.size());
    for (uint32_t i = 0; i < idx.size(); ++i)
        idx[i] = i;
    parallelForEach(module.getContext(), idx,
                    [&](uint32_t i) {
                        collect(g.nodes[i].op, g, lists[i], keepUnusedAddressOf);
                    });

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
