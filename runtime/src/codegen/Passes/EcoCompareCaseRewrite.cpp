//===- EcoCompareCaseRewrite.cpp - compare -> branch peephole -------------===//
//
// Deletes the Order round-trip at `compare` sites whose result is immediately
// scrutinized by a case on Order.
//
// The front end emits, for every `case compare a b of LT/EQ/GT` (elm/core's
// Dict.get / Dict.insertHelp above all):
//
//     %o   = eco.int.cmp_order %a, %b            // or string.cmp_order,
//            (or "eco.call" @Elm_Kernel_Utils_compare)  //  float/char, ...
//     %r:N = eco.case %o : !eco.value [0, 1, 2] {case_kind = "ctor"}
//              { LT }, { EQ }, { GT }
//
// Materializing an Order value only to branch on its constructor tag is pure
// waste: the primitive cmp_order lowering pays three gc-leaf `getOrder` calls
// plus two selects per execution, and the boxed kernel root pays a statepointed
// call into `Utils::cmp`'s tag dispatch. This pass rewrites the pair into
// direct comparisons feeding nested bool cases:
//
//     %isLt = <lt test>
//     %r:N  = eco.case %isLt : i1 [1, 0] {case_kind = "bool"}
//               { LT }
//               { %isGt = <gt test>
//                 %q:N  = eco.case %isGt : i1 [1, 0] {case_kind = "bool"}
//                           { GT }
//                           { EQ }
//                 eco.yield %q#0.. }
//
// EQ-as-final-else is load-bearing, not stylistic: for floats the tests are
// ORDERED (OLT/OGT), so NaN fails both and lands in EQ — bit-for-bit the
// routing today's `emitOrderSelect` produces (EcoToLLVMArith.cpp). An `isEq`
// (OEQ) second test would send NaN to GT instead.
//
// Placement: after EcoPAPSimplify (closure-mediated compares are direct calls
// by then) and before UndefinedFunction (which validates the declaration this
// pass may insert for Elm_Kernel_Utils_cmp3), hence before
// EcoControlFlowToSCF/EcoGCPrepare — `eco.case` is still present and GC root
// sets are computed on the final shape.
//
// v1 is deliberately narrow: single-use producer, 3-region ctor case whose
// tags are a permutation of [0,1,2], no aggregate results. Everything else is
// left alone and counted. Set ECO_CMPCASE (any value) for the census line;
// ECO_CMPCASE=0 disables the transform.
//
// See plans/string-cmp-order-intrinsic-and-postmono-compare-rewrite.md
//
//===----------------------------------------------------------------------===//

#include "mlir/Pass/Pass.h"
#include "mlir/IR/BuiltinOps.h"
#include "mlir/IR/Builders.h"
#include "mlir/Dialect/Func/IR/FuncOps.h"
#include "mlir/Dialect/Arith/IR/Arith.h"

#include "../EcoDialect.h"
#include "../EcoOps.h"
#include "../EcoTypes.h"
#include "../Passes.h"

#include "llvm/ADT/SmallVector.h"
#include "llvm/Support/raw_ostream.h"

#include <cstdlib>

using namespace mlir;
using namespace ::eco;

namespace {

// Order constructor tags, pinned on both sides: Utils.cpp's ORDER_LT/EQ/GT
// constants and the compiler's declaration-order ctor ids for Basics.Order.
enum : int64_t { kOrderLT = 0, kOrderEQ = 1, kOrderGT = 2 };

bool cmpCaseEnabled() {
    static const bool on = [] {
        const char *e = ::getenv("ECO_CMPCASE");
        return !(e && e[0] == '0' && e[1] == '\0');
    }();
    return on;
}

bool cmpCaseNamed() {
    const char *e = ::getenv("ECO_CMPCASE");
    return e && *e;
}

/// What kind of comparison produced the Order value, and how to test its sign.
enum class ProducerKind { Int, Float, Char, String, BoxedKernel };

/// A matched producer: the op, its two operands, and its kind.
struct Producer {
    Operation *op;
    Value lhs;
    Value rhs;
    ProducerKind kind;
};

/// Recognize an Order-producing op. Returns false for anything else.
bool matchProducer(Operation *op, Producer &out) {
    if (auto c = dyn_cast<IntCmpOrderOp>(op)) {
        out = {op, c.getLhs(), c.getRhs(), ProducerKind::Int};
        return true;
    }
    if (auto c = dyn_cast<FloatCmpOrderOp>(op)) {
        out = {op, c.getLhs(), c.getRhs(), ProducerKind::Float};
        return true;
    }
    if (auto c = dyn_cast<CharCmpOrderOp>(op)) {
        out = {op, c.getLhs(), c.getRhs(), ProducerKind::Char};
        return true;
    }
    if (auto c = dyn_cast<StringCmpOrderOp>(op)) {
        out = {op, c.getLhs(), c.getRhs(), ProducerKind::String};
        return true;
    }
    // The boxed root: a direct call to the generic kernel compare.
    if (auto call = dyn_cast<eco::CallOp>(op)) {
        auto callee = call.getCallee();
        if (!callee || *callee != "Elm_Kernel_Utils_compare")
            return false;
        if (call.getOperands().size() != 2 || call.getResults().size() != 1)
            return false;
        out = {op, call.getOperands()[0], call.getOperands()[1],
               ProducerKind::BoxedKernel};
        return true;
    }
    return false;
}

/// Ensure the `Elm_Kernel_Utils_cmp3` declaration exists. UndefinedFunction
/// (CGEN_011) runs after this pass and would fail the build without it.
/// KERN_006: the types are authored here and reflected verbatim downstream.
void ensureUtilsCmp3Decl(ModuleOp m) {
    if (m.lookupSymbol<func::FuncOp>("Elm_Kernel_Utils_cmp3"))
        return;
    OpBuilder b(m.getContext());
    b.setInsertionPointToEnd(m.getBody());
    auto valueTy = ValueType::get(m.getContext());
    auto i64Ty = b.getIntegerType(64);
    auto ft = b.getFunctionType({valueTy, valueTy}, {i64Ty});
    auto f = b.create<func::FuncOp>(m.getLoc(), "Elm_Kernel_Utils_cmp3", ft);
    f.setPrivate();
    f->setAttr("is_kernel", b.getBoolAttr(true));
    f->setAttr("eco.logical_param_types", b.getStrArrayAttr({"value", "value"}));
    f->setAttr("eco.logical_result_types", b.getStrArrayAttr({"int"}));
}

/// Emit the (isLt, isGt) test pair for a producer at the builder's insertion
/// point. For String/BoxedKernel this emits the three-way compare and two
/// integer sign tests; the compare is thereby SUNK to the case's position,
/// which is safe (pure, total) and can only reduce execution count.
std::pair<Value, Value> emitTests(OpBuilder &b, Location loc,
                                  const Producer &p, ModuleOp module) {
    Type i1Ty = b.getI1Type();
    switch (p.kind) {
    case ProducerKind::Int:
        return {b.create<IntLtOp>(loc, i1Ty, p.lhs, p.rhs),
                b.create<IntGtOp>(loc, i1Ty, p.lhs, p.rhs)};
    case ProducerKind::Float:
        // ORDERED comparisons: NaN fails both and falls through to EQ.
        return {b.create<FloatLtOp>(loc, i1Ty, p.lhs, p.rhs),
                b.create<FloatGtOp>(loc, i1Ty, p.lhs, p.rhs)};
    case ProducerKind::Char:
        // Char compares are unsigned (mirrors eco.char.lt).
        return {b.create<CharLtOp>(loc, i1Ty, p.lhs, p.rhs),
                b.create<CharGtOp>(loc, i1Ty, p.lhs, p.rhs)};
    case ProducerKind::String:
    case ProducerKind::BoxedKernel: {
        auto i64Ty = b.getIntegerType(64);
        Value sign;
        if (p.kind == ProducerKind::String) {
            sign = b.create<StringCmp3Op>(loc, i64Ty, p.lhs, p.rhs);
        } else {
            ensureUtilsCmp3Decl(module);
            auto call = b.create<eco::CallOp>(
                loc, TypeRange{i64Ty}, ValueRange{p.lhs, p.rhs},
                FlatSymbolRefAttr::get(b.getContext(), "Elm_Kernel_Utils_cmp3"),
                /*musttail=*/nullptr, /*remaining_arity=*/nullptr);
            sign = call.getResult(0);
        }
        // UNCLAMPED sign: test <0 / >0, never against +/-1.
        Value zero = b.create<arith::ConstantOp>(loc, b.getI64IntegerAttr(0));
        return {b.create<IntLtOp>(loc, i1Ty, sign, zero),
                b.create<IntGtOp>(loc, i1Ty, sign, zero)};
    }
    }
    llvm_unreachable("unhandled ProducerKind");
}

/// Try to rewrite one producer + its Order case. Returns true on success.
bool tryRewrite(Operation *prodOp, ModuleOp module) {
    Producer p;
    if (!matchProducer(prodOp, p))
        return false;

    Value ord = prodOp->getResult(0);
    if (!ord.hasOneUse())
        return false;

    // The single use must be the scrutinee of a 3-arm ctor case. (A use inside
    // a region would be a second use, so the single-use gate already
    // guarantees the moved regions never reference the erased producer.)
    OpOperand &use = *ord.getUses().begin();
    auto caseOp = dyn_cast<CaseOp>(use.getOwner());
    if (!caseOp || use.getOperandNumber() != 0)
        return false;
    if (caseOp.getCaseKind() != "ctor")
        return false;

    auto tags = caseOp.getTags();
    if (tags.size() != 3 || caseOp.getAlternatives().size() != 3)
        return false;

    // Region i handles tags[i] — never assume region order equals tag order.
    int ltIdx = -1, eqIdx = -1, gtIdx = -1;
    for (unsigned i = 0; i < 3; ++i) {
        switch (tags[i]) {
        case kOrderLT: ltIdx = i; break;
        case kOrderEQ: eqIdx = i; break;
        case kOrderGT: gtIdx = i; break;
        default: return false;  // not a permutation of [0,1,2]
        }
    }
    if (ltIdx < 0 || eqIdx < 0 || gtIdx < 0)
        return false;

    // Aggregate-typed results are CGEN_064 territory (CaseToScfIfPattern bails
    // on them too); leave those cases alone.
    for (Type t : caseOp.getResultTypes())
        if (!isa<ValueType>(t) && !t.isIntOrIndexOrFloat())
            return false;

    OpBuilder b(caseOp);
    Location loc = caseOp.getLoc();
    TypeRange resultTypes = caseOp.getResultTypes();

    // All new ops go immediately before the case. Single-use does NOT imply
    // adjacency (or even the same block): the producer may live in an ancestor
    // region. Dominance is transitive — the producer's operands dominate the
    // producer, which dominates the case — so they are legal here.
    auto [isLt, isGt] = emitTests(b, loc, p, module);

    // Outer: if isLt then LT else <inner>.
    auto outer = b.create<CaseOp>(loc, resultTypes, isLt,
                                  b.getDenseI64ArrayAttr({1, 0}),
                                  b.getStringAttr("bool"),
                                  /*string_patterns=*/nullptr,
                                  /*alternativesCount=*/2);

    // Region 0 (tag 1 = True) takes the original LT region verbatim; its
    // eco.yield rebinds to `outer`, whose result types are identical.
    outer.getAlternatives()[0].takeBody(caseOp.getAlternatives()[ltIdx]);

    // Region 1 (tag 0 = False) is fresh: it computes isGt and nests the second
    // case, then yields its results.
    Block *elseBlk = &outer.getAlternatives()[1].emplaceBlock();
    {
        OpBuilder eb(b.getContext());
        eb.setInsertionPointToEnd(elseBlk);
        auto inner = eb.create<CaseOp>(loc, resultTypes, isGt,
                                       eb.getDenseI64ArrayAttr({1, 0}),
                                       eb.getStringAttr("bool"),
                                       /*string_patterns=*/nullptr,
                                       /*alternativesCount=*/2);
        inner.getAlternatives()[0].takeBody(caseOp.getAlternatives()[gtIdx]);
        inner.getAlternatives()[1].takeBody(caseOp.getAlternatives()[eqIdx]);
        eb.create<YieldOp>(loc, inner.getResults());
    }

    caseOp.replaceAllUsesWith(outer.getResults());
    caseOp.erase();
    prodOp->erase();
    return true;
}

struct EcoCompareCaseRewritePass
    : public PassWrapper<EcoCompareCaseRewritePass, OperationPass<ModuleOp>> {
    MLIR_DEFINE_EXPLICIT_INTERNAL_INLINE_TYPE_ID(EcoCompareCaseRewritePass)

    StringRef getArgument() const override { return "eco-compare-case-rewrite"; }

    StringRef getDescription() const override {
        return "Rewrite compare + case-on-Order into direct comparisons "
               "(deletes the Order round-trip)";
    }

    void runOnOperation() override {
        if (!cmpCaseEnabled())
            return;

        ModuleOp module = getOperation();

        // Collect candidate producers first: the rewrite erases ops, so we
        // must not mutate while walking. Seeded collection also keeps the cost
        // proportional to compare sites rather than to the whole module.
        SmallVector<Operation *> seeds;
        module.walk([&](Operation *op) {
            Producer p;
            if (matchProducer(op, p))
                seeds.push_back(op);
        });

        unsigned rewritten = 0;
        for (Operation *op : seeds)
            if (tryRewrite(op, module))
                ++rewritten;

        if (cmpCaseNamed())
            llvm::errs() << "[cmpcase] rewritten=" << rewritten
                         << " skipped=" << (seeds.size() - rewritten) << "\n";
    }
};

} // namespace

std::unique_ptr<Pass> eco::createEcoCompareCaseRewritePass() {
    return std::make_unique<EcoCompareCaseRewritePass>();
}
