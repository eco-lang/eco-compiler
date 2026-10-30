//===- EcoCompareCaseRewrite.cpp - compare -> branch peephole -------------===//
//
// A pass that removes the `Order` value at sites where a comparison's result is
// only branched on, so the value is never built.
//
// Elm's `case compare a b of LT -> ...; EQ -> ...; GT -> ...` reaches this pass
// as a three-way compare that produces an `Order` (`eco.int.cmp_order`,
// `eco.float.cmp_order`, `eco.char.cmp_order`, `eco.string.cmp_order`, or a
// call to `Elm_Kernel_Utils_compare` for boxed values), followed by an
// `eco.case` of kind "ctor" on that value:
//
//     %o   = eco.int.cmp_order %a, %b
//     %r:N = eco.case %o : !eco.value [0, 1, 2] {case_kind = "ctor"}
//              { LT }, { EQ }, { GT }
//
// Building the `Order` costs a runtime call (`eco_order_from_sign`, from
// `emitOrderSelect` in EcoToLLVMArith, for Int, Float and Char;
// `eco_string_cmp_order` for strings; the boxed compare is itself a kernel
// call), and the case then reads its tag back.
// This pass replaces the pair with two tests feeding nested Bool cases:
//
//     %isLt = <lt test>
//     %r:N  = eco.case %isLt : i1 [1, 0] {case_kind = "bool"}
//               { LT }
//               { %isGt = <gt test>
//                 %q:N  = eco.case %isGt : i1 [1, 0] {case_kind = "bool"}
//                           { GT }
//                           { EQ }
//                 eco.yield %q }
//
// The tag numbers are LT = 0, EQ = 1, GT = 2. Nothing in this file checks them;
// they must agree with the constructor ids the compiler gives `Basics.Order`
// and with the `Order` constants in elm-kernel-cpp's Utils.cpp.
//
// EQ is the final else, not a third test. For Float the tests are Float's total
// order (CGEN_086), as `eco.float.cmp_order`'s lowering computes it: LT is `a < b`
// or (`b` NaN and `a` not), GT is `a > b` or (`a` NaN and `b` not), so two NaNs,
// like two equal numbers, take the EQ branch. The two must change together.
//
// Strings and boxed values are tested by sign: `eco.string.cmp3` or a call to
// `Elm_Kernel_Utils_cmp3` returns an i64 whose sign is the order, and the tests
// are `< 0` and `> 0`, never a comparison with -1 or 1. The pass declares
// `Elm_Kernel_Utils_cmp3` itself when it first needs it, so it must run before
// the pass from `createUndefinedFunctionPass`, which rejects calls to
// undeclared functions.
//
// A site is rewritten only when the producer's result has a single use, that
// use is operand 0 of a "ctor" case with three alternatives whose tags are a
// permutation of 0, 1 and 2, and every result type of the case is
// `!eco.value`, an integer, an index or a float. Every other producer is left
// alone. `ECO_CMPCASE` set to exactly `0` disables the pass; any other
// non-empty value prints one census line to stderr with the counts of
// rewritten and skipped producers.
//
//===----------------------------------------------------------------------===//

#include "mlir/Pass/Pass.h"
#include "mlir/IR/BuiltinOps.h"
#include "mlir/IR/Builders.h"
#include "mlir/Dialect/Func/IR/FuncOps.h"
#include "mlir/Dialect/Arith/IR/Arith.h"

#include "../EcoDialect.h"
#include "../EcoOps.h"
#include "../Passes.h"

#include "llvm/ADT/SmallVector.h"
#include "llvm/Support/raw_ostream.h"

#include <cstdlib>

using namespace mlir;
using namespace ::eco;

namespace {

/**
 * The constructor tags of `Basics.Order`. They must match the compiler's
 * constructor ids and Utils.cpp's `Order` constants; nothing here checks that.
 */
enum : int64_t { kOrderLT = 0, kOrderEQ = 1, kOrderGT = 2 };

// Returns whether the pass runs: true unless `ECO_CMPCASE` is exactly `0`.
// The variable is read once per process.
bool cmpCaseEnabled() {
    static const bool on = [] {
        const char *e = ::getenv("ECO_CMPCASE");
        return !(e && e[0] == '0' && e[1] == '\0');
    }();
    return on;
}

// Returns whether `ECO_CMPCASE` is set to a non-empty value, which asks for
// the census line. The variable is read on every call.
bool cmpCaseNamed() {
    const char *e = ::getenv("ECO_CMPCASE");
    return e && *e;
}

/**
 * The kind of comparison that produced an `Order` value, which decides the
 * tests that replace it.
 */
enum class ProducerKind { Int, Float, Char, String, BoxedKernel };

/**
 * An `Order`-producing op matched by `matchProducer`, with its two operands.
 *
 * `op` points into the module and is valid until the op is erased.
 */
struct Producer {
    Operation *op;
    Value lhs;
    Value rhs;
    ProducerKind kind;
};

// Returns whether `op` produces an `Order` this pass can replace, and if so
// writes it to `out`; `out` is unchanged otherwise. The producers are the four
// `cmp_order` ops and an `eco.call` to `Elm_Kernel_Utils_compare` with two
// operands and one result.
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

// Adds a private `func.func` declaration of `Elm_Kernel_Utils_cmp3`, taking
// two `!eco.value` and returning i64, at the end of `m`, unless a `func.func`
// of that name is already in the module body. The declaration is marked
// `is_kernel`, and its function type is the kernel ABI, which later passes
// take as given (KERN_006). It also carries `eco.logical_param_types` and
// `eco.logical_result_types`.
void ensureUtilsCmp3Decl(ModuleOp m) {
    // Scanned from the end: this runs once per rewritten boxed site, and the
    // declaration it creates is appended at the end, so after the first call
    // the search stops almost at once. Symbol names are unique, so the
    // direction does not change the answer.
    for (Operation &op : llvm::reverse(*m.getBody()))
        if (auto f = dyn_cast<func::FuncOp>(op))
            if (f.getSymName() == "Elm_Kernel_Utils_cmp3")
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

// Emits, at `b`'s insertion point, the i1 values "lhs < rhs" and "lhs > rhs"
// for the comparison `p` made, and returns them in that order. For a string or
// boxed producer it also emits the three-way compare whose sign they test, so
// that compare now runs where the tests are placed rather than where `p.op`
// was; for a boxed producer it may add the `Elm_Kernel_Utils_cmp3` declaration
// to `module`.
std::pair<Value, Value> emitTests(OpBuilder &b, Location loc,
                                  const Producer &p, ModuleOp module) {
    Type i1Ty = b.getI1Type();
    switch (p.kind) {
    case ProducerKind::Int:
        return {b.create<IntLtOp>(loc, i1Ty, p.lhs, p.rhs),
                b.create<IntGtOp>(loc, i1Ty, p.lhs, p.rhs)};
    case ProducerKind::Float: {
        // Float's total order: NaN equals NaN and is above every number.
        Value t = b.create<arith::ConstantOp>(loc, b.getBoolAttr(true));
        Value aNaN = b.create<FloatIsNaNOp>(loc, i1Ty, p.lhs);
        Value bNaN = b.create<FloatIsNaNOp>(loc, i1Ty, p.rhs);
        Value aNum = b.create<arith::XOrIOp>(loc, aNaN, t);
        Value bNum = b.create<arith::XOrIOp>(loc, bNaN, t);
        Value lt = b.create<arith::OrIOp>(loc, b.create<FloatLtOp>(loc, i1Ty, p.lhs, p.rhs),
                                          b.create<arith::AndIOp>(loc, bNaN, aNum));
        Value gt = b.create<arith::OrIOp>(loc, b.create<FloatGtOp>(loc, i1Ty, p.lhs, p.rhs),
                                          b.create<arith::AndIOp>(loc, aNaN, bNum));
        return {lt, gt};
    }
    case ProducerKind::Char:
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
        // The sign is not clamped to -1/0/1, so test against 0.
        Value zero = b.create<arith::ConstantOp>(loc, b.getI64IntegerAttr(0));
        return {b.create<IntLtOp>(loc, i1Ty, sign, zero),
                b.create<IntGtOp>(loc, i1Ty, sign, zero)};
    }
    }
    llvm_unreachable("unhandled ProducerKind");
}

// Replaces `prodOp` and the case on its result with the nested Bool cases
// described in the file comment, and returns whether it did. On false the IR
// is unchanged. On true both `prodOp` and the original case are erased, and
// the original case's regions have been moved into the new cases.
bool tryRewrite(Operation *prodOp, ModuleOp module) {
    Producer p;
    if (!matchProducer(prodOp, p))
        return false;

    Value ord = prodOp->getResult(0);
    if (!ord.hasOneUse())
        return false;

    // A use inside a region would be a second use, so the moved regions
    // cannot refer to the producer that is erased below.
    OpOperand &use = *ord.getUses().begin();
    auto caseOp = dyn_cast<CaseOp>(use.getOwner());
    if (!caseOp || use.getOperandNumber() != 0)
        return false;
    if (caseOp.getCaseKind() != "ctor")
        return false;

    auto tags = caseOp.getTags();
    if (tags.size() != 3 || caseOp.getAlternatives().size() != 3)
        return false;

    // Region i handles tags[i]; region order need not be tag order.
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

    // Cases with aggregate results (CGEN_064) are left alone.
    for (Type t : caseOp.getResultTypes())
        if (!isa<ValueType>(t) && !t.isIntOrIndexOrFloat())
            return false;

    OpBuilder b(caseOp);
    Location loc = caseOp.getLoc();
    TypeRange resultTypes = caseOp.getResultTypes();

    // The new ops go immediately before the case, which need not be in the
    // producer's block. The producer's operands dominate the producer, which
    // dominates the case, so they may be used here.
    auto [isLt, isGt] = emitTests(b, loc, p, module);

    auto outer = b.create<CaseOp>(loc, resultTypes, isLt,
                                  b.getDenseI64ArrayAttr({1, 0}),
                                  b.getStringAttr("bool"),
                                  /*string_patterns=*/nullptr,
                                  /*alternativesCount=*/2);

    // Region 0 is tag 1 (True). The moved LT region's eco.yield now yields
    // `outer`'s results, which have the same types.
    outer.getAlternatives()[0].takeBody(caseOp.getAlternatives()[ltIdx]);

    // Region 1 is tag 0 (False): a new block holding the inner case.
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

/**
 * The module pass that applies `tryRewrite` to every `Order` producer.
 */
struct EcoCompareCaseRewritePass
    : public PassWrapper<EcoCompareCaseRewritePass, OperationPass<ModuleOp>> {
    MLIR_DEFINE_EXPLICIT_INTERNAL_INLINE_TYPE_ID(EcoCompareCaseRewritePass)

    // Returns the pass's command-line name.
    StringRef getArgument() const override { return "eco-compare-case-rewrite"; }

    // Returns the pass's one-line help text.
    StringRef getDescription() const override {
        return "Rewrite compare + case-on-Order into direct comparisons "
               "(deletes the Order round-trip)";
    }

    // Rewrites every eligible site in the module, unless `ECO_CMPCASE` is
    // `0`, and prints the census when `ECO_CMPCASE` is set.
    void runOnOperation() override {
        if (!cmpCaseEnabled())
            return;

        ModuleOp module = getOperation();

        // Producers are collected before any rewrite because a rewrite
        // erases ops, which the walk must not see.
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
