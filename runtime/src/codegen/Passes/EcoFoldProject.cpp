//===- EcoFoldProject.cpp - Fold eco.project.*/get_tag of eco.construct.* -===//
//
// A field read of an object built in the same function can often be answered without reading the object: when
// the operand of `eco.project.*` (or of `eco.list.head`/`eco.list.tail`) is defined directly by an
// `eco.construct.*`, the result is the operand that was stored, and when the operand of `eco.get_tag` is defined
// directly by an `eco.construct.custom`, the result is that construct's constant tag. The ops' own `fold()` hooks in
// EcoOps.cpp decide each such fold and its conditions (equal SSA types; the list folds only with
// `ECO_MLIR_FOLD_LIST` set to a non-empty value other than `0`). This pass applies them.
//
// It exists because nothing else at its point in the pipeline would: MLIR's CSE does not call `fold()`, and no
// canonicalizer runs there. It is one walk over each function, in program order.
//
// A value result replaces every use of the folded op. An attribute result, the tag, is materialized as an
// `arith.constant` just before the folded op. Folded ops are erased only after the walk. Every change is confined to
// the function being folded, so functions are folded in parallel chunks with `eco::forEachChunk`.
//
// Environment: `ECO_MLIR_FOLD` set to exactly `0` makes the pass do nothing, and set to `census` makes it print its
// totals to stderr. `ECO_MLIR_FOLD_BLOCK_LOCAL` set to a non-empty value other than `0` limits folding to ops whose
// operand is defined in the same block.
//
//===----------------------------------------------------------------------===//

#include "../EcoDialect.h"
#include "../EcoOps.h"
#include "../Passes.h"
#include "EcoParallel.h"

#include "mlir/Dialect/Arith/IR/Arith.h"
#include "mlir/Dialect/Func/IR/FuncOps.h"
#include "mlir/IR/BuiltinOps.h"
#include "mlir/Pass/Pass.h"

#include "llvm/ADT/SmallVector.h"
#include "llvm/Support/raw_ostream.h"

#include <atomic>
#include <cstdlib>

using namespace mlir;
using namespace ::eco;

namespace {

// Returns whether the pass folds anything: false only when `ECO_MLIR_FOLD` is exactly `0`. The variable is read
// once per process.
bool foldEnabled() {
    static const bool on = [] {
        const char *e = ::getenv("ECO_MLIR_FOLD");
        if (!e || !*e)
            return true;
        return !(e[0] == '0' && e[1] == '\0');
    }();
    return on;
}

// Returns whether `ECO_MLIR_FOLD` is `census`, which asks for the fold totals on stderr. Read on every call.
bool foldCensus() {
    const char *e = ::getenv("ECO_MLIR_FOLD");
    return e && llvm::StringRef(e) == "census";
}

// Returns whether folding is limited to ops whose operand is defined in their own block: true when
// `ECO_MLIR_FOLD_BLOCK_LOCAL` is set to a non-empty value other than `0`. Read on every call.
bool blockLocalOnly() {
    const char *e = ::getenv("ECO_MLIR_FOLD_BLOCK_LOCAL");
    return e && *e && !(e[0] == '0' && e[1] == '\0');
}

/**
 * The number of folds made, and of candidate ops skipped by the block-local limit, over the functions of one
 * chunk.
 */
struct FoldCounts {
    unsigned folded = 0, tagFolded = 0, skippedNonLocal = 0;
};

// Folds the projections, list heads and tails, and `eco.get_tag` ops in `func` whose `fold()` succeeds with one
// result, except those skipped by the block-local limit, and adds the folds and skips to `c`.
//
// Every change stays inside `func`: uses are replaced, folded ops are erased, and the only op created is an
// `arith.constant` in the folded op's block. An attribute result that is not a `TypedAttr` is not applied.
void foldFunction(func::FuncOp func, FoldCounts &c) {
    SmallVector<Operation *> dead;

    // walk() visits ops in program order within a block, so in a chain
    // `%b = project(%a); %c = project(%b)` the uses of %b have already been
    // replaced when %c is visited, and the chain collapses in one walk.
    // Erasure is deferred so that the walk is not invalidated.
    func.walk([&](Operation *op) {
        if (!isa<CustomProjectOp, RecordProjectOp, Tuple2ProjectOp,
                 Tuple3ProjectOp, ListHeadOp, ListTailOp, GetTagOp>(op))
            return;
        if (blockLocalOnly()) {
            Operation *def = op->getOperand(0).getDefiningOp();
            if (!def || def->getBlock() != op->getBlock()) {
                ++c.skippedNonLocal;
                return;
            }
        }
        SmallVector<OpFoldResult, 1> results;
        if (failed(op->fold(results)) || results.size() != 1)
            return;
        if (auto v = dyn_cast_if_present<Value>(results[0])) {
            op->getResult(0).replaceAllUsesWith(v);
            dead.push_back(op);
            ++c.folded;
            return;
        }
        // A fold hook may not create ops, so an attribute result is
        // materialized here, as an arith.constant just before the op.
        if (auto attr = dyn_cast_if_present<Attribute>(results[0])) {
            auto typed = dyn_cast<TypedAttr>(attr);
            if (!typed)
                return;
            OpBuilder b(op);
            Value cst = b.create<arith::ConstantOp>(op->getLoc(), typed);
            op->getResult(0).replaceAllUsesWith(cst);
            dead.push_back(op);
            ++c.tagFolded;
        }
    });

    for (Operation *op : dead)
        op->erase();
}

/**
 * The `eco-fold-project` pass: a module pass that folds every function with a body, in parallel chunks.
 *
 * It is a module pass rather than one nested on functions so that the pass manager runs it once per module instead
 * of once per function.
 */
struct EcoFoldProjectPass
    : public PassWrapper<EcoFoldProjectPass, OperationPass<ModuleOp>> {
    MLIR_DEFINE_EXPLICIT_INTERNAL_INLINE_TYPE_ID(EcoFoldProjectPass)

    StringRef getArgument() const override { return "eco-fold-project"; }
    StringRef getDescription() const override {
        return "Fold eco.project.*/eco.get_tag of a dominating "
               "eco.construct.* to the field operand / constant tag";
    }

    void runOnOperation() override {
        if (!foldEnabled())
            return;
        SmallVector<func::FuncOp> funcs;
        for (func::FuncOp f : getOperation().getOps<func::FuncOp>())
            if (!f.isExternal())
                funcs.push_back(f);

        std::atomic<uint64_t> folded{0}, tagFolded{0}, skippedNonLocal{0};
        eco::forEachChunk(&getContext(), funcs.size(),
                          [&](size_t lo, size_t hi) {
                              FoldCounts c;
                              for (size_t i = lo; i < hi; ++i)
                                  foldFunction(funcs[i], c);
                              folded += c.folded;
                              tagFolded += c.tagFolded;
                              skippedNonLocal += c.skippedNonLocal;
                          });

        if (foldCensus())
            llvm::errs() << "[eco-fold-project] total folded=" << folded.load()
                         << " tag_folded=" << tagFolded.load()
                         << " skipped_nonlocal=" << skippedNonLocal.load()
                         << "\n";
    }
};

} // namespace

std::unique_ptr<Pass> eco::createEcoFoldProjectPass() {
    return std::make_unique<EcoFoldProjectPass>();
}
