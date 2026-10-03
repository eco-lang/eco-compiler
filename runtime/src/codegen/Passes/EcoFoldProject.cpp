//===- EcoFoldProject.cpp - Fold eco.project.*/get_tag of eco.construct.* -===//
//
// kernel-opt-10 Phase 2. Applies the projection folders (EcoOps.cpp
// "Projection Folders" section): a projection of a dominating construct
// becomes the constructed field operand, and a get_tag of a construct.custom
// becomes the constant ctor tag.
//
// Why a dedicated pass: MLIR's CSE pass does not run folders, and re-adding
// the canonicalizer at the M4 slot is precisely the measured ~0.5 s M4
// regression the pipeline removed. This is one linear walk.
//
// Runs at the M4 slot (module pass, functions in parallel chunks; plan 07 P1),
// BEFORE EcoGCPrepare — after that pass the
// construct's operand list carries appended root operands, and (worse) the
// projections this pass deletes would already be baked into root sets.
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

bool foldEnabled() {
    static const bool on = [] {
        const char *e = ::getenv("ECO_MLIR_FOLD");
        if (!e || !*e)
            return true; // DEFAULT-ON since 2026-08-13 (Run Q): counters bit-equal to off, -2,381 ops, no compile-time cost
        return !(e[0] == '0' && e[1] == '\0');
    }();
    return on;
}

bool foldCensus() {
    const char *e = ::getenv("ECO_MLIR_FOLD");
    return e && llvm::StringRef(e) == "census";
}

bool blockLocalOnly() {
    const char *e = ::getenv("ECO_MLIR_FOLD_BLOCK_LOCAL");
    return e && *e && !(e[0] == '0' && e[1] == '\0');
}

struct FoldCounts {
    unsigned folded = 0, tagFolded = 0, skippedNonLocal = 0;
};

/// The per-function fold (unchanged from the func-nested pass). Function-local:
/// RAUW + erase inside `func`, and the only creation is an arith.constant in
/// the same block.
void foldFunction(func::FuncOp func, FoldCounts &c) {
    SmallVector<Operation *> dead;

    // walk() visits ops in program order within a block, so a chain
    // `%b = project(%a); %c = project(%b)` sees %b already RAUW'd when %c
    // is visited and collapses in one sweep. Erasure is deferred so the
    // walk is never invalidated; RAUW mid-walk only rewrites operands of
    // not-yet-visited ops.
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
        // Attribute result: get_tag's constant ctor tag. A fold may not
        // build IR, but this driver may — materialize the arith.constant
        // right where the op sits.
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

/// Plan 07 P1: a MODULE pass that folds the functions in parallel chunks.
/// It used to be func-nested: ~57k adaptor invocations, each under MLIR's
/// global PassInstrumentor mutex plus the stats mutex, and the banner summed
/// per-function times across threads (CPU time, not wall). Timed once here.
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
