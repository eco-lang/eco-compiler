//===- EcoSymbolGraph.h - Symbol reference graph of an llvm-dialect module -===//
//
// One definition of "who references whom, and how" for the final llvm-dialect
// module, shared by EcoReachability (plan 03), EcoCapHoistPlan (plan 01) and
// the reachability validate cross-check. It mirrors what LLVM will see after
// translation:
//   - an `llvm.mlir.addressof` with no uses produces no LLVM use: no edge;
//   - an `addressof @f` whose every use is the callee operand of an indirect
//     `llvm.call` with f's exact function type becomes a DIRECT call in LLVM
//     (Call); if some such call has a different type it is an indirect call
//     and the function's address is taken (CallMismatch); any other use takes
//     the address (Address);
//   - every other SymbolRefAttr: `llvm.call`'s callee is a Call, anything
//     else an Address.
// plans/mlir-split-backend-03-reachability.md Part II R2.
//
// A C++ object, never IR: rebuilt by each consumer, so it can never be stale.
//
//===----------------------------------------------------------------------===//
#ifndef ECO_SYMBOL_GRAPH_H
#define ECO_SYMBOL_GRAPH_H

#include "mlir/IR/BuiltinOps.h"

#include "llvm/ADT/DenseMap.h"
#include "llvm/ADT/StringMap.h"

#include <cstdint>
#include <vector>

namespace eco::symgraph {

enum EdgeKind : uint8_t { Call = 1, CallMismatch = 2, Address = 4 };

/// Edge kinds that make LLVM's Function::hasAddressTaken() true.
inline bool takesAddress(uint8_t kind) {
    return (kind & (CallMismatch | Address)) != 0;
}

struct Node {
    mlir::Operation *op = nullptr;
    mlir::StringAttr name;
    bool isFunc = false, isGlobal = false, isDef = false,
         interposable = false;
};

struct Graph {
    std::vector<Node> nodes; // top-level symbol ops, module order
    llvm::DenseMap<mlir::StringAttr, uint32_t> index;
    // CSR out-edges: targets of node i are outTarget[outBegin[i] ..
    // outBegin[i+1]), each with the OR of its EdgeKinds in outKind.
    std::vector<uint32_t> outBegin, outTarget;
    std::vector<uint8_t> outKind;
    // References held by top-level ops that are NOT symbols (none are
    // emitted today; LLVM treats e.g. global_ctors as roots).
    std::vector<uint32_t> extraRoots;
    std::vector<uint32_t> extraTakes; // the address-taking subset

    int lookup(mlir::StringAttr s) const {
        auto it = index.find(s);
        return it == index.end() ? -1 : (int)it->second;
    }
};

/// Builds the graph; per-op collection runs in parallel.
Graph build(mlir::ModuleOp module);

/// Validate support (plan 03 R5): every defined function's name mapped to
/// whether LLVM's Function::hasAddressTaken() must be true after translation
/// (some edge into it takes the address). Computed on a module in which every
/// symbol is reached (i.e. after EcoReachability).
llvm::StringMap<bool> addressTakenByName(mlir::ModuleOp module);

} // namespace eco::symgraph

#endif // ECO_SYMBOL_GRAPH_H
