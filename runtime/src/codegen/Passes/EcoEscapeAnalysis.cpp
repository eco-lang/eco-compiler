//===- EcoEscapeAnalysis.cpp - Escape analysis for value aggregates -------===//
//
// Per-function escape analysis for small-aggregate `eco.construct.*` ops.
// Classifies each construct op's result as either `non_escaping` (every
// use is a known projection on the same value) or `escapes` (anything
// else — call, return, store, capture, case, etc.). The classification
// is recorded as a string attribute `eco.escape` on the construct op so
// the specialise pass can act on it without re-walking uses.
//
// Phase 1 covered Tuple2/Tuple3. Phase 2 extends the candidate set to
// records, customs, and list cons cells:
//   - eco.construct.tuple2  → eco.project.tuple2  (Phase 1)
//   - eco.construct.tuple3  → eco.project.tuple3  (Phase 1)
//   - eco.construct.record  → eco.project.record  (Phase 2)
//   - eco.construct.custom  → eco.project.custom  (Phase 2)
//   - eco.construct.list    → eco.project.list_head / list_tail (Phase 2)
//
// Conservative rules:
//   - A use is NON-escaping iff:
//       * user is the matching projection op, AND
//       * the operand position is the receiver (operand 0).
//   - Anything else is escaping. In particular:
//       * any other op (other eco.construct.*, eco.allocate_*, eco.box,
//         eco.store_global, eco.return, eco.yield, eco.case, eco.call,
//         eco.papCreate, eco.papExtend, eco.to_heap, ...);
//       * the construct op's result being a function return value;
//       * being passed as a projection operand at a non-receiver position
//         (defensive — shouldn't happen in well-typed IR).
//
// This pass must run BEFORE EcoGCPrepare so the construct op's operand
// list is just `[a, b, ... ]` (no GC roots appended yet).
//
// Phase 2's RS4GC FCA prerequisite is satisfied by addEcoGCPipeline, which
// now runs mem2reg + SROA + a tiny custom extractvalue/insertvalue fold
// before RewriteStatepointsForGC. Aggregates carrying ptr addrspace(1)
// fields are therefore safe to rewrite.
//
//===----------------------------------------------------------------------===//

#include "../EcoDialect.h"
#include "../EcoOps.h"
#include "../Passes.h"

#include "mlir/Dialect/Func/IR/FuncOps.h"
#include "mlir/IR/Builders.h"
#include "mlir/IR/BuiltinOps.h"
#include "mlir/Pass/Pass.h"

#include "llvm/ADT/Statistic.h"
#include "llvm/ADT/DenseMap.h"

#define DEBUG_TYPE "eco-escape-analysis"

using namespace mlir;

namespace {

constexpr llvm::StringLiteral kEscapeAttr     = "eco.escape";
constexpr llvm::StringLiteral kNonEscapingTag = "non_escaping";
constexpr llvm::StringLiteral kEscapesTag     = "escapes";

// Total constructs the pass classifies, and the verdict split.
ALWAYS_ENABLED_STATISTIC(ConstructAnalysed,
    "eco.construct.* ops walked by escape analysis");
ALWAYS_ENABLED_STATISTIC(ConstructNonEscaping,
    "eco.construct.* tagged non_escaping (eligible for specialise)");
ALWAYS_ENABLED_STATISTIC(ConstructEscapes,
    "eco.construct.* tagged escapes");

// Per-construct-kind split — tells us which families dominate the input
// and which families escape most often.
ALWAYS_ENABLED_STATISTIC(Tuple2Analysed,
    "eco.construct.tuple2 analysed");
ALWAYS_ENABLED_STATISTIC(Tuple2NonEscaping,
    "eco.construct.tuple2 tagged non_escaping");
ALWAYS_ENABLED_STATISTIC(Tuple3Analysed,
    "eco.construct.tuple3 analysed");
ALWAYS_ENABLED_STATISTIC(Tuple3NonEscaping,
    "eco.construct.tuple3 tagged non_escaping");
ALWAYS_ENABLED_STATISTIC(RecordAnalysed,
    "eco.construct.record analysed");
ALWAYS_ENABLED_STATISTIC(RecordNonEscaping,
    "eco.construct.record tagged non_escaping");
ALWAYS_ENABLED_STATISTIC(CustomAnalysed,
    "eco.construct.custom analysed");
ALWAYS_ENABLED_STATISTIC(CustomNonEscaping,
    "eco.construct.custom tagged non_escaping");
ALWAYS_ENABLED_STATISTIC(ListAnalysed,
    "eco.construct.list analysed");
ALWAYS_ENABLED_STATISTIC(ListNonEscaping,
    "eco.construct.list tagged non_escaping");

// Per-op-name DenseMap recording the FIRST escape-causing use op for
// every escapes-tagged construct. Tells us which consumers are blocking
// the largest share of escape-analysis wins.
static llvm::DenseMap<llvm::StringRef, uint64_t> &escapeCauseByOpName() {
    static llvm::DenseMap<llvm::StringRef, uint64_t> m;
    return m;
}

} // namespace (close anonymous so the dump entry point is externally visible)

void ecoDumpEscapeAnalysisStats() {
    auto &m = escapeCauseByOpName();
    if (m.empty()) return;
    llvm::SmallVector<std::pair<llvm::StringRef, uint64_t>, 32>
        rows(m.begin(), m.end());
    llvm::sort(rows, [](const auto &a, const auto &b) {
        return a.second > b.second;
    });
    auto pad = [](uint64_t v) {
        std::string s = std::to_string(v);
        while (s.size() < 10) s = " " + s;
        return s;
    };
    uint64_t total = 0;
    for (auto &r : rows) total += r.second;
    llvm::errs()
        << "\n=== eco-escape-analysis: first escape-causing op (by name) ===\n";
    for (auto &r : rows)
        llvm::errs() << pad(r.second) << "  " << r.first << "\n";
    llvm::errs() << pad(total) << "  TOTAL\n";
}

namespace {

/// True iff `use` is a known projection of the construct op's result
/// in the receiver operand position. Each construct shape has its own
/// projection op(s); the receiver is always operand 0. Anything else
/// is treated as escaping.
static bool isNonEscapingUse(OpOperand &use) {
    Operation *user = use.getOwner();
    if (use.getOperandNumber() != 0) return false;
    return isa<eco::Tuple2ProjectOp,
               eco::Tuple3ProjectOp,
               eco::RecordProjectOp,
               eco::CustomProjectOp,
               eco::ListHeadOp,
               eco::ListTailOp>(user);
}

/// Classify a single tuple-construct op's result and tag it with the
/// `eco.escape` attribute. Returns true iff classified as non-escaping.
///
/// Phase 1 had an additional `allElementsPrimitive` guard here as a
/// workaround for LLVM's "FCA unimplemented" assertion when a struct
/// value carrying ptr addrspace(1) was live across a statepoint. The
/// guard is no longer needed: Phase 2 wires mem2reg + SROA into
/// addEcoGCPipeline so any FCA is scalarised before RS4GC sees it.
/// Boxed-element tuples are now first-class candidates.
static bool classifyConstruct(Operation *op, OpBuilder &builder) {
    ++ConstructAnalysed;
    // Per-kind bookkeeping (analysed and non-escaping totals).
    auto bumpKindAnalysed = [&]() {
        if (isa<eco::Tuple2ConstructOp>(op)) ++Tuple2Analysed;
        else if (isa<eco::Tuple3ConstructOp>(op)) ++Tuple3Analysed;
        else if (isa<eco::RecordConstructOp>(op)) ++RecordAnalysed;
        else if (isa<eco::CustomConstructOp>(op)) ++CustomAnalysed;
        else if (isa<eco::ListConstructOp>(op)) ++ListAnalysed;
    };
    auto bumpKindNonEscaping = [&]() {
        if (isa<eco::Tuple2ConstructOp>(op)) ++Tuple2NonEscaping;
        else if (isa<eco::Tuple3ConstructOp>(op)) ++Tuple3NonEscaping;
        else if (isa<eco::RecordConstructOp>(op)) ++RecordNonEscaping;
        else if (isa<eco::CustomConstructOp>(op)) ++CustomNonEscaping;
        else if (isa<eco::ListConstructOp>(op)) ++ListNonEscaping;
    };
    bumpKindAnalysed();

    bool nonEscaping = true;
    for (OpOperand &use : op->getResult(0).getUses()) {
        if (!isNonEscapingUse(use)) {
            nonEscaping = false;
            ++escapeCauseByOpName()[use.getOwner()->getName().getStringRef()];
            break;
        }
    }
    op->setAttr(kEscapeAttr,
                builder.getStringAttr(nonEscaping ? kNonEscapingTag
                                                  : kEscapesTag));
    if (nonEscaping) { ++ConstructNonEscaping; bumpKindNonEscaping(); }
    else ++ConstructEscapes;
    return nonEscaping;
}

struct EcoEscapeAnalysisPass
    : public PassWrapper<EcoEscapeAnalysisPass, OperationPass<func::FuncOp>> {
    MLIR_DEFINE_EXPLICIT_INTERNAL_INLINE_TYPE_ID(EcoEscapeAnalysisPass)

    StringRef getArgument() const override { return "eco-escape-analysis"; }
    StringRef getDescription() const override {
        return "Tag tuple-construct ops with eco.escape classification "
               "(Phase 1 escape analysis for value-level aggregates)";
    }

    void runOnOperation() override {
        func::FuncOp func = getOperation();
        OpBuilder builder(func.getContext());
        func.walk([&](Operation *op) {
            if (isa<eco::Tuple2ConstructOp,
                    eco::Tuple3ConstructOp,
                    eco::RecordConstructOp,
                    eco::CustomConstructOp,
                    eco::ListConstructOp>(op)) {
                classifyConstruct(op, builder);
            }
        });
    }
};

} // namespace

std::unique_ptr<Pass> eco::createEcoEscapeAnalysisPass() {
    return std::make_unique<EcoEscapeAnalysisPass>();
}
