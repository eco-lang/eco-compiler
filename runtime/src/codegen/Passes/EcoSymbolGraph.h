//===- EcoSymbolGraph.h - Symbol reference graph of an llvm-dialect module -===//
//
// Deciding which functions of an llvm-dialect module are used, called, or have
// their address taken needs to know which top-level symbols refer to which
// others, and how, in the form LLVM will see once the module is translated. This
// component computes that as a graph, with one set of rules for every user.
//
// The graph's nodes are the module's top-level symbol operations (those with a
// `sym_name`), in module order. An edge from node A to node B means that A, or an
// operation nested anywhere inside A, refers to B. Each edge carries a set of
// edge kinds, combined with `|` when A refers to B more than once:
//   - `Call`: B is called directly.
//   - `CallMismatch`: B's address is the callee of an indirect `llvm.call` whose
//     function type differs from B's.
//   - `Address`: any other reference.
// LLVM counts a function's address as taken (`Function::hasAddressTaken()`) for
// the last two, and `takesAddress` tests for them.
//
// The kinds model the module after translation, which differs from the MLIR in
// how `llvm.mlir.addressof` turns out:
//   - An `addressof` with no uses becomes nothing in LLVM, so it adds no edge
//     unless `build` is asked to keep it.
//   - An `addressof @f` whose every use is the callee operand of an indirect
//     `llvm.call` is treated as a direct call: `Call` when every such call has
//     f's function type, `CallMismatch` when one does not.
//   - Any other use of an `addressof`, or an `addressof` of a symbol that is not
//     a function, is `Address`.
// Every other symbol reference held in an operation's attributes is `Call` when
// it is the `callee` of an `llvm.call`, and `Address` otherwise (an `llvm.call`'s
// other inherent attributes are not examined). A nested symbol
// reference counts as a reference to its root symbol. A reference to a name that
// is not a top-level symbol of the module adds no edge.
//
// Top-level operations that are not symbols can hold references too. Those
// belong to no node, so `Graph` lists their targets separately.
//
// A `Graph` is a C++ object built from the module on demand, never stored in the
// IR. It holds pointers into the module and is valid only until the module is
// next changed, so code that needs one builds its own.
//
//===----------------------------------------------------------------------===//
#ifndef ECO_SYMBOL_GRAPH_H
#define ECO_SYMBOL_GRAPH_H

#include "mlir/IR/BuiltinOps.h"

#include "llvm/ADT/DenseMap.h"
#include "llvm/ADT/STLFunctionalExtras.h"
#include "llvm/ADT/StringMap.h"

#include <cstdint>
#include <vector>

namespace eco::symgraph {

/// The ways one symbol can refer to another, as set out in the file comment.
///
/// The values are bit flags. An edge's kind is the `|` of every way its source
/// refers to its target, held in a `uint8_t`.
enum EdgeKind : uint8_t { Call = 1, CallMismatch = 2, Address = 4 };

/// Returns whether an edge whose kinds are `kind` takes its target's address,
/// that is, whether it includes `CallMismatch` or `Address`.
inline bool takesAddress(uint8_t kind) {
    return (kind & (CallMismatch | Address)) != 0;
}

/// One top-level symbol operation of the module.
///
/// `isFunc` is set for an `llvm.func` and `isGlobal` for an `llvm.mlir.global`;
/// any other symbol operation has neither.
struct Node {
    /// The symbol operation, owned by the module. Non-null in a graph from `build`.
    mlir::Operation *op = nullptr;
    mlir::StringAttr name;
    /// `isDef`: for a function, whether it has a body; for a global, whether it
    /// has an initial value or an initializer region; false for any other
    /// symbol. `interposable`: whether a function has `weak`, `linkonce`,
    /// `extern_weak` or `common` linkage; false for anything else.
    bool isFunc = false, isGlobal = false, isDef = false,
         interposable = false;
};

/// The symbol reference graph of one module, as set out in the file comment.
///
/// Get one from `build`. Nodes are identified by their index in `nodes`. The
/// rules stated on the members below are what `build` produces; the members
/// are public and nothing enforces the rules afterwards. The graph keeps the
/// module's operations by pointer, so it is valid only until the module is
/// next changed.
struct Graph {
    std::vector<Node> nodes; ///< Top-level symbol operations, in module order.
    /// Maps each node's name to its index in `nodes`.
    llvm::DenseMap<mlir::StringAttr, uint32_t> index;
    /// Out-edges in compressed sparse row form. The targets of node `i` are
    /// `outTarget[j]` for `outBegin[i] <= j < outBegin[i + 1]`, in ascending
    /// order with no target twice. `outKind` holds each edge's kinds at the same
    /// position. `outBegin` has one more entry than `nodes`.
    std::vector<uint32_t> outBegin, outTarget;
    std::vector<uint8_t> outKind;
    /// Targets of the references held by top-level operations that are not
    /// symbols. A target appears once per operation that refers to it.
    std::vector<uint32_t> extraRoots;
    /// The entries of `extraRoots` whose reference takes the target's address.
    std::vector<uint32_t> extraTakes;

    /// Returns the index of the node named `s`, or -1 if no top-level symbol
    /// has that name.
    int lookup(mlir::StringAttr s) const {
        auto it = index.find(s);
        return it == index.end() ? -1 : (int)it->second;
    }
};

/// Builds the symbol reference graph of `module`.
///
/// With `keepUnusedAddressOf`, an `llvm.mlir.addressof` with no uses still adds
/// an `Address` edge, so the graph covers every symbol the module's operations
/// name, used or not, rather than only what LLVM will use.
///
/// The edges of the symbol nodes may be collected in parallel on the module's
/// context thread pool; the collection reads the IR and does not change it.
/// When the environment variable `ECO_SYMREF_VALIDATE` is set to a value that is not
/// empty and does not start with `0`, each node's edges are collected a second
/// time through `getAttrDictionary()`, and the process prints the first node
/// whose edges differ and aborts. The variable is read once per process.
Graph build(mlir::ModuleOp module, bool keepUnusedAddressOf = false);

/// Calls `fn(ref, isCallee)` for every symbol reference held in `op`'s own
/// attributes, inherent and discardable, but not in the operations nested
/// inside it. `isCallee` is true only for the `callee` of an `llvm.call`.
///
/// It finds the references a walk of `op->getAttrDictionary()` would find,
/// except in an `llvm.call`'s inherent attributes other than `callee`, which
/// are not examined. Unlike that walk, it builds no `DictionaryAttr` for an op
/// whose inherent attributes are stored as properties. `fn` is not kept after
/// the call.
void forEachSymbolRef(mlir::Operation *op,
                      llvm::function_ref<void(mlir::SymbolRefAttr, bool)> fn);

/// Returns, for every function `module` defines, keyed by name, whether LLVM's
/// `Function::hasAddressTaken()` is expected to be true for it after
/// translation: whether any edge into it in `build(module)`, or any reference
/// to it from a top-level non-symbol operation, takes its address.
llvm::StringMap<bool> addressTakenByName(mlir::ModuleOp module);

} // namespace eco::symgraph

#endif // ECO_SYMBOL_GRAPH_H
