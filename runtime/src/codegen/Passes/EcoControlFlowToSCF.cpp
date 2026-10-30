//===- EcoControlFlowToSCF.cpp - Lower Eco control flow to SCF dialect ----===//
//
// Some later passes, such as EcoListTemplate, work on structured loops and branches (`scf.while`, `scf.if`), so this
// pass rewrites the eco control-flow ops that have a structured shape into the SCF dialect and leaves the rest alone.
//
// Two eco ops are involved. An `eco.case` dispatches on a scrutinee to one of several alternatives, each a region;
// its `tags` give the value each alternative matches, and the last alternative is the default, taken when no earlier
// tag matches. Its `case_kind` says what is compared: constructor tags (an `!eco.value`, or an `i1` Bool), `int`,
// `chr`, or `str` (whose patterns are the `string_patterns` literals). An `eco.joinpoint` is a local label with a
// body, entered by an `eco.jump` naming its id, and a continuation; `JoinpointNormalization` labels the ones shaped
// like loops with `scf_candidate` and `scf_case_loop`.
//
// A case is lowered only when every alternative ends in `eco.yield`, so each alternative is an expression yielding
// the case's results. Its alternatives are copied into the regions of the new op, and each `eco.yield` becomes an
// `scf.yield`. Nested cases are copied as they are and rewritten later by the same greedy driver. The patterns are:
//
// - `JoinpointToScfWhilePattern`: a joinpoint carrying both labels becomes an `scf.while`.
// - `CaseStringToScfIfChainPattern`: a `str` case that already sits inside an `scf.if`, `scf.index_switch` or
//   `scf.while` becomes a chain of `scf.if`, one string equality test per pattern.
// - `CaseToScfIfPattern`: a case with two alternatives becomes one `scf.if`.
// - `CaseToScfIndexSwitchPattern`: a case with more than two alternatives becomes an `scf.index_switch`, unless it is
//   a `str` case, has an `i1` scrutinee, or is an `int` case with a tag outside [0, INT32_MAX].
// - `CaseToScfIfChainPattern`: an `int` case with more than two alternatives and a tag outside [0, INT32_MAX]
//   becomes a chain of `scf.if`.
//
// Every case pattern declines a case inside an `eco.joinpoint` body and a case with a value-aggregate result type
// (tuple, record, custom, cons or closure-environment). The three non-string case patterns also decline a case that
// contains a `str` case: EcoToLLVM lowers an `eco.case` only when it has no `scf.if`, `scf.index_switch` or `scf.while`
// ancestor, so a string case moved inside one would be lowered only if `CaseStringToScfIfChainPattern` matched it. What
// no pattern takes stays an `eco.case` or `eco.joinpoint` and is left to EcoToLLVM.
//
// String equality is `eco.value.eq` by default. With the environment variable `ECO_VALUE_EQ_STRCASE` set to exactly
// `0` it is a call to `Elm_Kernel_Utils_equal` instead, which this pass then declares. EcoToLLVMControlFlow.cpp reads
// the same variable through its own copy of `valueEqStrCaseEnabled`, and the two copies must change together.
//
// The pass runs the greedy driver separately on each top-level op of the module that has a region and is isolated
// from above, in parallel chunks, unless a top-level op that is not isolated holds a case or joinpoint, in which case
// it runs once on the whole module.
//
//===----------------------------------------------------------------------===//

#include "mlir/Pass/Pass.h"
#include "mlir/IR/BuiltinOps.h"
#include "mlir/IR/PatternMatch.h"
#include "mlir/IR/Threading.h"
#include "mlir/Transforms/DialectConversion.h"
#include "mlir/Transforms/GreedyPatternRewriteDriver.h"

#include "mlir/Dialect/SCF/IR/SCF.h"
#include "mlir/Dialect/Arith/IR/Arith.h"
#include "mlir/Dialect/ControlFlow/IR/ControlFlowOps.h"
#include "mlir/Dialect/Func/IR/FuncOps.h"

#include "../EcoDialect.h"
#include "../EcoOps.h"
#include "../Passes.h"

#include "llvm/ADT/DenseSet.h"
#include "llvm/Support/Debug.h"

#include <cstdint>
#define DEBUG_TYPE "eco-cf-to-scf"

using namespace mlir;
using namespace ::eco;

namespace {

//===----------------------------------------------------------------------===//
// Helpers
//===----------------------------------------------------------------------===//

// Returns whether every alternative of `op` is non-empty and ends in `eco.yield`, which every case pattern requires.
bool hasPureYieldAlternatives(CaseOp op) {
    for (Region &alt : op.getAlternatives()) {
        if (alt.empty())
            return false;

        Block &block = alt.front();
        if (block.empty())
            return false;

        Operation *term = block.getTerminator();
        if (!isa<YieldOp>(term))
            return false;
    }
    return true;
}

// Returns the result types of `op`, which the replacing SCF op takes as its own.
SmallVector<Type> getCaseResultTypes(CaseOp op) {
    return SmallVector<Type>(op.getResultTypes().begin(), op.getResultTypes().end());
}

// Returns whether the scrutinee of `op` is an `i1`, an unboxed Bool.
bool hasI1Scrutinee(CaseOp op) {
    Type scrutineeType = op.getScrutinee().getType();
    if (auto intType = dyn_cast<IntegerType>(scrutineeType)) {
        return intType.getWidth() == 1;
    }
    return false;
}

// Returns whether `op` has `case_kind` `int`.
bool isIntegerCase(CaseOp op) {
    auto caseKindAttr = op.getCaseKindAttr();
    if (!caseKindAttr)
        return false;
    return caseKindAttr.getValue() == "int";
}

// Returns whether every tag of the `int` case `op` is in [0, INT32_MAX] (CGEN_048).
//
// Only such a case can become an `scf.index_switch`. The upstream SCF to CF lowering casts the selector and the case
// values to `i32` for `cf.switch`, so a larger tag would be truncated: 5000000000 would match 705032704. Any other
// `int` case goes to `CaseToScfIfChainPattern`, which compares in `i64`.
static bool intTagsFitI32Switch(CaseOp op) {
    for (int64_t tag : op.getTags())
        if (tag < 0 || tag > INT32_MAX)
            return false;
    return true;
}

// Returns whether `op` has `case_kind` `chr`.
bool isCharCase(CaseOp op) {
    auto caseKindAttr = op.getCaseKindAttr();
    if (!caseKindAttr)
        return false;
    return caseKindAttr.getValue() == "chr";
}

// Returns whether `op` has `case_kind` `str`.
bool isStringCase(CaseOp op) {
    auto caseKindAttr = op.getCaseKindAttr();
    if (!caseKindAttr)
        return false;
    return caseKindAttr.getValue() == "str";
}

// Returns whether any case nested at any depth inside `op`, other than `op` itself, is a `str` case.
//
// EcoToLLVM treats an `eco.case` inside an `scf.if`, `scf.index_switch` or `scf.while` as legal and does not lower
// it, so lowering `op` to SCF would
// leave such a nested string case to `CaseStringToScfIfChainPattern` alone.
bool computeContainsNestedStringCase(CaseOp op) {
    auto result = op.walk([&](CaseOp nested) -> WalkResult {
        if (nested != op && isStringCase(nested))
            return WalkResult::interrupt();
        return WalkResult::advance();
    });
    return result.wasInterrupted();
}

/**
 * A cache of `computeContainsNestedStringCase` answers, keyed by case op, that forgets an op when the rewriter erases
 * it.
 *
 * The greedy driver retries the patterns on an op whenever something near it changes, and without the cache each retry
 * would walk the op's whole subtree again. A cached false stays correct for as long as the op lives, because no
 * pattern creates a string case and a rewrite copies ops only to places under the same ancestors, so a string case
 * under an op stays under it. A cached true can go stale if a nested string case is removed, and then only a lowering
 * is skipped. Erased ops are evicted, through the listener the driver is given, so that a new op allocated at the same
 * address does not inherit an answer.
 *
 * One memo serves one chunk of the pass, on one thread.
 */
struct StringCaseMemo : public RewriterBase::Listener {
    DenseMap<Operation *, bool> cache;

    // Returns `computeContainsNestedStringCase(op)`, computing it only on the first call for `op`.
    bool contains(CaseOp op) {
        auto it = cache.find(op.getOperation());
        if (it != cache.end())
            return it->second;
        bool result = computeContainsNestedStringCase(op);
        cache[op.getOperation()] = result;
        return result;
    }

    // Forgets the cached answer for `op`, which the rewriter is erasing.
    void notifyOperationErased(Operation *op) override { cache.erase(op); }
};

//===----------------------------------------------------------------------===//
// Pattern: eco.case with pure yields -> scf.if (2-way case)
//===----------------------------------------------------------------------===//

// Returns whether any result of `op` has a value-aggregate type: a tuple, record, custom, cons or closure-environment
// type.
//
// Every case pattern declines such a case, which is left for EcoToLLVM's `eco.case` lowering, whose result types
// admit aggregates.
static bool hasAggregateResults(CaseOp op) {
    for (Type t : op.getResultTypes())
        if (isa<eco::Tuple2Type, eco::Tuple3Type, eco::RecordType,
                eco::CustomType, eco::ConsType, eco::ClosureEnvType>(t))
            return true;
    return false;
}

/**
 * A pattern that lowers an `eco.case` with exactly two alternatives to an `scf.if`.
 *
 * The condition is that the scrutinee matches `tags[1]`, so the second alternative becomes the then region and the
 * first the else region:
 *
 *     %result = eco.case %scrutinee [tag0, tag1] -> (T0) { case_kind = "ctor" } {
 *       ... eco.yield %v0 : T0
 *     }, {
 *       ... eco.yield %v1 : T0
 *     }
 *
 * becomes
 *
 *     %tag = eco.get_tag %scrutinee : !eco.value -> i32
 *     %cond = arith.cmpi eq, %tag, %c_tag1_i32 : i32
 *     %result = scf.if %cond -> (T0) {
 *       ... scf.yield %v1 : T0
 *     } else {
 *       ... scf.yield %v0 : T0
 *     }
 *
 * An `i1` scrutinee is the condition itself, inverted when `tags[1]` is not 1. An `int` or `chr` scrutinee is unboxed
 * to `i64` or `i32` if it is boxed and compared with `tags[1]`. Any other scrutinee is compared by its constructor
 * tag. A `str` case is declined: a String's constructor tag says nothing about its contents. One that
 * `CaseStringToScfIfChainPattern` did not take stays `eco.case`, and EcoToLLVM lowers it with string compares.
 */
struct CaseToScfIfPattern : public OpRewritePattern<CaseOp> {
    StringCaseMemo *stringCaseMemo; // Not owned; must outlive the pattern.

    // Creates the pattern with `benefit`, answering nested-string-case queries from `memo`.
    CaseToScfIfPattern(MLIRContext *ctx, StringCaseMemo *memo, PatternBenefit benefit)
        : OpRewritePattern(ctx, benefit), stringCaseMemo(memo) {}

    LogicalResult matchAndRewrite(CaseOp op,
                                  PatternRewriter &rewriter) const override {
        if (hasAggregateResults(op))
            return failure();
        LLVM_DEBUG(llvm::dbgs() << "CaseToScfIfPattern: trying to match eco.case at "
                                 << op.getLoc() << "\n");

        auto alts = op.getAlternatives();
        if (alts.size() != 2) {
            LLVM_DEBUG(llvm::dbgs() << "  -> rejected: " << alts.size() << " alternatives (need 2)\n");
            return failure();
        }

        if (isStringCase(op)) {
            LLVM_DEBUG(llvm::dbgs() << "  -> rejected: string case (compared by contents, not tag)\n");
            return failure();
        }

        if (!hasPureYieldAlternatives(op)) {
            LLVM_DEBUG(llvm::dbgs() << "  -> rejected: not all alternatives end with eco.yield\n");
            return failure();
        }

        if (op->getParentOfType<JoinpointOp>())
            return failure();

        if (stringCaseMemo->contains(op))
            return failure();

        // A case nested in another case or in an `scf` op is lowered too, to a nested scf op.
        auto resultTypes = getCaseResultTypes(op);

        LLVM_DEBUG(llvm::dbgs() << "  -> MATCHED! Converting to scf.if\n");

        auto loc = op.getLoc();
        auto tags = op.getTags();

        Value cond;
        if (hasI1Scrutinee(op)) {
            // Any tags[1] other than 1 is taken to be 0.
            if (tags[1] == 1) {
                cond = op.getScrutinee();
            } else {
                auto trueConst = rewriter.create<arith::ConstantOp>(
                    loc, rewriter.getI1Type(), rewriter.getIntegerAttr(rewriter.getI1Type(), 1));
                cond = rewriter.create<arith::XOrIOp>(loc, op.getScrutinee(), trueConst);
            }
        } else if (isIntegerCase(op)) {
            auto i64Ty = rewriter.getI64Type();
            Value scrutinee = op.getScrutinee();
            Value intVal;
            if (scrutinee.getType() == i64Ty) {
                intVal = scrutinee;
            } else {
                intVal = rewriter.create<UnboxOp>(loc, i64Ty, scrutinee);
            }

            auto tagConstant = rewriter.create<arith::ConstantOp>(
                loc, rewriter.getI64IntegerAttr(tags[1]));
            cond = rewriter.create<arith::CmpIOp>(
                loc, arith::CmpIPredicate::eq, intVal, tagConstant);
        } else if (isCharCase(op)) {
            auto charTy = eco::getEcoCharType(rewriter.getContext());
            Value scrutinee = op.getScrutinee();
            Value charVal;
            if (eco::isEcoCharType(scrutinee.getType())) {
                charVal = scrutinee;
            } else {
                charVal = rewriter.create<UnboxOp>(loc, charTy, scrutinee);
            }

            // A tag is a code point, at most 0x10FFFF, so it fits in `i32` unchanged.
            auto tagConstant = rewriter.create<arith::ConstantOp>(
                loc, rewriter.getIntegerAttr(charTy, tags[1]));
            cond = rewriter.create<arith::CmpIOp>(
                loc, arith::CmpIPredicate::eq, charVal, tagConstant);
        } else {
            auto tag = rewriter.create<GetTagOp>(loc, rewriter.getI32Type(),
                                                 op.getScrutinee());

            auto tagConstant = rewriter.create<arith::ConstantOp>(
                loc, rewriter.getI32IntegerAttr(tags[1]));
            cond = rewriter.create<arith::CmpIOp>(
                loc, arith::CmpIPredicate::eq, tag, tagConstant);
        }

        auto ifOp = rewriter.create<scf::IfOp>(loc, resultTypes, cond,
                                               /*withElseRegion=*/true);

        {
            Region &thenRegion = ifOp.getThenRegion();
            Block *thenBlock = &thenRegion.front();

            // The builder may have added a default scf.yield; the alternative supplies its own.
            if (!thenBlock->empty()) {
                if (auto existingYield = dyn_cast<scf::YieldOp>(thenBlock->getTerminator())) {
                    rewriter.eraseOp(existingYield);
                }
            }

            rewriter.setInsertionPointToStart(thenBlock);

            IRMapping mapping;

            Region &alt1 = alts[1];
            Block &alt1Block = alt1.front();

            for (Operation &bodyOp : alt1Block.getOperations()) {
                if (auto yieldOp = dyn_cast<YieldOp>(&bodyOp)) {
                    SmallVector<Value> yieldOperands;
                    for (Value operand : yieldOp.getOperands())
                        yieldOperands.push_back(mapping.lookupOrDefault(operand));
                    rewriter.create<scf::YieldOp>(loc, yieldOperands);
                    break;  // YieldOp is last
                }
                rewriter.clone(bodyOp, mapping);  // includes nested eco.case
            }
        }

        {
            Region &elseRegion = ifOp.getElseRegion();
            Block *elseBlock = &elseRegion.front();

            if (!elseBlock->empty()) {
                if (auto existingYield = dyn_cast<scf::YieldOp>(elseBlock->getTerminator())) {
                    rewriter.eraseOp(existingYield);
                }
            }

            rewriter.setInsertionPointToStart(elseBlock);

            IRMapping mapping;

            Region &alt0 = alts[0];
            Block &alt0Block = alt0.front();

            for (Operation &bodyOp : alt0Block.getOperations()) {
                if (auto yieldOp = dyn_cast<YieldOp>(&bodyOp)) {
                    SmallVector<Value> yieldOperands;
                    for (Value operand : yieldOp.getOperands())
                        yieldOperands.push_back(mapping.lookupOrDefault(operand));
                    rewriter.create<scf::YieldOp>(loc, yieldOperands);
                    break;  // YieldOp is last
                }
                rewriter.clone(bodyOp, mapping);  // includes nested eco.case
            }
        }

        rewriter.replaceOp(op, ifOp.getResults());
        return success();
    }
};

//===----------------------------------------------------------------------===//
// Pattern: eco.case with pure yields -> scf.index_switch (multi-way case)
//===----------------------------------------------------------------------===//

/**
 * A pattern that lowers an `eco.case` with more than two alternatives to an `scf.index_switch`.
 *
 * The switch's cases are the first N-1 tags and alternatives, and the last alternative is its default region. The
 * index is the unboxed `chr` or `int` value, or the constructor tag for any other case. `str` cases, `i1` scrutinees
 * and `int` cases with a tag outside [0, INT32_MAX] are declined, the last for `CaseToScfIfChainPattern`.
 */
struct CaseToScfIndexSwitchPattern : public OpRewritePattern<CaseOp> {
    StringCaseMemo *stringCaseMemo; // Not owned; must outlive the pattern.

    // Creates the pattern with `benefit`, answering nested-string-case queries from `memo`.
    CaseToScfIndexSwitchPattern(MLIRContext *ctx, StringCaseMemo *memo, PatternBenefit benefit)
        : OpRewritePattern(ctx, benefit), stringCaseMemo(memo) {}

    LogicalResult matchAndRewrite(CaseOp op,
                                  PatternRewriter &rewriter) const override {
        if (hasAggregateResults(op))
            return failure();
        auto alts = op.getAlternatives();

        if (alts.size() <= 2)
            return failure();

        if (!hasPureYieldAlternatives(op))
            return failure();

        if (hasI1Scrutinee(op))
            return failure();

        if (isStringCase(op))
            return failure();

        if (isIntegerCase(op) && !intTagsFitI32Switch(op))
            return failure();
        // Char tags are code points, which always fit.

        if (op->getParentOfType<JoinpointOp>())
            return failure();

        if (stringCaseMemo->contains(op))
            return failure();

        auto resultTypes = getCaseResultTypes(op);

        auto loc = op.getLoc();
        auto tags = op.getTags();

        Value indexTag;
        Value scrutinee = op.getScrutinee();
        Type scrutineeType = scrutinee.getType();

        if (isCharCase(op)) {
            // A Char is an unsigned code point, so it is zero-extended to the index (`index_castui`).
            auto charTy = eco::getEcoCharType(rewriter.getContext());
            Value charVal;
            if (eco::isEcoCharType(scrutineeType)) {
                charVal = scrutinee;
            } else {
                charVal = rewriter.create<UnboxOp>(loc, charTy, scrutinee);
            }
            indexTag = rewriter.create<arith::IndexCastUIOp>(
                loc, rewriter.getIndexType(), charVal);
        } else if (isIntegerCase(op)) {
            auto i64Ty = rewriter.getI64Type();
            Value intVal;
            if (scrutineeType == i64Ty) {
                intVal = scrutinee;
            } else {
                intVal = rewriter.create<UnboxOp>(loc, i64Ty, scrutinee);
            }
            // The SCF->CF lowering truncates the selector to i32, so a
            // scrutinee outside [0, INT32_MAX] (2^32 + 7, or a negative one)
            // could alias a case value. Clamp such a scrutinee to a sentinel
            // that is no case value, so it reaches the default region. The
            // sentinel is the least non-negative value not among the
            // non-default tags: at most tags.size() - 1, so within range.
            int64_t sentinel = 0;
            {
                llvm::SmallDenseSet<int64_t> caseTags(tags.begin(),
                                                      tags.end() - 1);
                while (caseTags.contains(sentinel))
                    ++sentinel;
            }
            auto maxC = rewriter.create<arith::ConstantOp>(
                loc, rewriter.getI64IntegerAttr(INT32_MAX));
            // Unsigned compare: negative scrutinees are out of range too.
            auto inRange = rewriter.create<arith::CmpIOp>(
                loc, arith::CmpIPredicate::ule, intVal, maxC);
            auto sentC = rewriter.create<arith::ConstantOp>(
                loc, rewriter.getI64IntegerAttr(sentinel));
            Value clamped = rewriter.create<arith::SelectOp>(
                loc, inRange, intVal, sentC);
            indexTag = rewriter.create<arith::IndexCastOp>(
                loc, rewriter.getIndexType(), clamped);
        } else {
            auto tag = rewriter.create<GetTagOp>(loc, rewriter.getI32Type(),
                                                 scrutinee);
            indexTag = rewriter.create<arith::IndexCastOp>(
                loc, rewriter.getIndexType(), tag);
        }

        // The last tag is not a switch case: its alternative is the default region.
        SmallVector<int64_t> caseValues;
        for (size_t i = 0; i < tags.size() - 1; ++i) {
            caseValues.push_back(tags[i]);
        }

        auto switchOp = rewriter.create<scf::IndexSwitchOp>(
            loc, resultTypes, indexTag, caseValues, caseValues.size());

        for (size_t i = 0; i < alts.size() - 1; ++i) {
            Region &caseRegion = switchOp.getCaseRegions()[i];
            Block *caseBlock = &caseRegion.emplaceBlock();
            rewriter.setInsertionPointToStart(caseBlock);

            IRMapping mapping;
            Region &alt = alts[i];
            Block &altBlock = alt.front();

            for (Operation &bodyOp : altBlock.getOperations()) {
                if (auto yieldOp = dyn_cast<YieldOp>(&bodyOp)) {
                    SmallVector<Value> yieldOperands;
                    for (Value operand : yieldOp.getOperands())
                        yieldOperands.push_back(mapping.lookupOrDefault(operand));
                    rewriter.create<scf::YieldOp>(loc, yieldOperands);
                    break;  // YieldOp is last
                }
                rewriter.clone(bodyOp, mapping);  // includes nested eco.case
            }
        }

        {
            Region &defaultRegion = switchOp.getDefaultRegion();
            Block *defaultBlock = &defaultRegion.emplaceBlock();
            rewriter.setInsertionPointToStart(defaultBlock);

            IRMapping mapping;
            Region &lastAlt = alts[alts.size() - 1];
            Block &lastAltBlock = lastAlt.front();

            for (Operation &bodyOp : lastAltBlock.getOperations()) {
                if (auto yieldOp = dyn_cast<YieldOp>(&bodyOp)) {
                    SmallVector<Value> yieldOperands;
                    for (Value operand : yieldOp.getOperands())
                        yieldOperands.push_back(mapping.lookupOrDefault(operand));
                    rewriter.create<scf::YieldOp>(loc, yieldOperands);
                    break;  // YieldOp is last
                }
                rewriter.clone(bodyOp, mapping);  // includes nested eco.case
            }
        }

        rewriter.replaceOp(op, switchOp.getResults());
        return success();
    }
};

//===----------------------------------------------------------------------===//
// Pattern: eco.case -> nested scf.if chain (int cases with a tag outside [0, INT32_MAX])
//===----------------------------------------------------------------------===//

// Copies the ops of `alt`'s entry block to the rewriter's insertion point, up to and including its first `eco.yield`,
// which is written as an `scf.yield` of the same operands. Values are remapped through `mapping`, which receives the
// results of every copied op.
static void cloneAlternativeWithScfYield(Region &alt, PatternRewriter &rewriter,
                                         Location loc, IRMapping &mapping) {
    Block &altBlock = alt.front();
    for (Operation &bodyOp : altBlock.getOperations()) {
        if (auto yieldOp = dyn_cast<YieldOp>(&bodyOp)) {
            SmallVector<Value> yieldOperands;
            for (Value operand : yieldOp.getOperands())
                yieldOperands.push_back(mapping.lookupOrDefault(operand));
            rewriter.create<scf::YieldOp>(loc, yieldOperands);
            break;  // YieldOp is last
        }
        Operation *cloned = rewriter.clone(bodyOp, mapping);
        for (auto [oldRes, newRes] : llvm::zip(bodyOp.getResults(), cloned->getResults()))
            mapping.map(oldRes, newRes);
    }
}

/**
 * A pattern that lowers an `int` `eco.case` with more than two alternatives, at least one tag outside [0, INT32_MAX]
 * (negative, or 2^31 and above), to a chain of `scf.if` comparing in `i64`.
 *
 * Each alternative but the last becomes `if (value == tag) { alternative } else { next test }`, and the last, the
 * default, is the innermost else. `CaseToScfIndexSwitchPattern` declines these cases because such a tag would not
 * survive the `i32` switch.
 */
struct CaseToScfIfChainPattern : public OpRewritePattern<CaseOp> {
    StringCaseMemo *stringCaseMemo; // Not owned; must outlive the pattern.

    // Creates the pattern with `benefit`, answering nested-string-case queries from `memo`.
    CaseToScfIfChainPattern(MLIRContext *ctx, StringCaseMemo *memo, PatternBenefit benefit)
        : OpRewritePattern(ctx, benefit), stringCaseMemo(memo) {}

    LogicalResult matchAndRewrite(CaseOp op,
                                  PatternRewriter &rewriter) const override {
        if (hasAggregateResults(op))
            return failure();
        auto alts = op.getAlternatives();

        if (alts.size() <= 2)
            return failure();

        if (!isIntegerCase(op))
            return failure();

        if (intTagsFitI32Switch(op))
            return failure();

        if (!hasPureYieldAlternatives(op))
            return failure();

        if (op->getParentOfType<JoinpointOp>())
            return failure();

        if (stringCaseMemo->contains(op))
            return failure();

        auto loc = op.getLoc();
        auto resultTypes = getCaseResultTypes(op);

        return lowerIntCaseToIfChain(op, rewriter, loc, resultTypes);
    }

private:
    // Replaces `op` with the results of the `scf.if` chain built by `buildIntIfChain`, unboxing the scrutinee to
    // `i64` first if it is boxed.
    LogicalResult lowerIntCaseToIfChain(CaseOp op, PatternRewriter &rewriter,
                                        Location loc,
                                        SmallVector<Type> &resultTypes) const {
        auto alts = op.getAlternatives();
        auto tags = op.getTags();
        auto i64Ty = rewriter.getI64Type();

        Value scrutinee = op.getScrutinee();
        Value unboxed;
        if (scrutinee.getType() == i64Ty) {
            unboxed = scrutinee;
        } else {
            unboxed = rewriter.create<UnboxOp>(loc, i64Ty, scrutinee);
        }

        size_t numAlts = alts.size();
        ValueRange results = buildIntIfChain(rewriter, loc, unboxed, tags, alts,
                                             resultTypes, 0, numAlts);

        rewriter.replaceOp(op, results);
        return success();
    }

    // Builds, at the insertion point, the `scf.if` that tests `unboxed` against `tags[altIdx]`, and returns its
    // results. `altIdx` must be below `numAlts - 1`. The else region holds the rest of the chain, or, when `altIdx` is
    // the second to last, the last alternative, the default, itself.
    ValueRange buildIntIfChain(PatternRewriter &rewriter, Location loc,
                               Value unboxed, ArrayRef<int64_t> tags,
                               MutableArrayRef<Region> alts,
                               SmallVector<Type> &resultTypes,
                               size_t altIdx, size_t numAlts) const {
        auto tagConst = rewriter.create<arith::ConstantOp>(
            loc, rewriter.getI64IntegerAttr(tags[altIdx]));
        auto cond = rewriter.create<arith::CmpIOp>(
            loc, arith::CmpIPredicate::eq, unboxed, tagConst);

        auto ifOp = rewriter.create<scf::IfOp>(loc, resultTypes, cond,
                                               /*withElseRegion=*/true);

        {
            Block *thenBlock = &ifOp.getThenRegion().front();
            if (!thenBlock->empty()) {
                if (auto existingYield = dyn_cast<scf::YieldOp>(thenBlock->getTerminator()))
                    rewriter.eraseOp(existingYield);
            }
            rewriter.setInsertionPointToStart(thenBlock);
            IRMapping mapping;
            cloneAlternativeWithScfYield(alts[altIdx], rewriter, loc, mapping);
        }

        {
            Block *elseBlock = &ifOp.getElseRegion().front();
            if (!elseBlock->empty()) {
                if (auto existingYield = dyn_cast<scf::YieldOp>(elseBlock->getTerminator()))
                    rewriter.eraseOp(existingYield);
            }
            rewriter.setInsertionPointToStart(elseBlock);
            if (altIdx + 2 == numAlts) {
                IRMapping mapping;
                cloneAlternativeWithScfYield(alts[altIdx + 1], rewriter, loc, mapping);
            } else {
                ValueRange inner = buildIntIfChain(rewriter, loc, unboxed, tags, alts,
                                                   resultTypes, altIdx + 1, numAlts);
                // The recursive call moved the insertion point into its own
                // regions; the yield belongs after the inner scf.if.
                rewriter.setInsertionPointToEnd(elseBlock);
                rewriter.create<scf::YieldOp>(loc, inner);
            }
        }

        return ifOp.getResults();
    }
};

//===----------------------------------------------------------------------===//
// Pattern: eco.case with case_kind="str" -> nested scf.if chain
//===----------------------------------------------------------------------===//

// Returns whether string cases compare with `eco.value.eq`, which is so unless `ECO_VALUE_EQ_STRCASE` is exactly `0`.
// The variable is read once per process.
//
// EcoToLLVMControlFlow.cpp has an identical copy for the string cases it lowers, and the two must change together.
static bool valueEqStrCaseEnabled() {
    static const bool on = [] {
        const char *e = ::getenv("ECO_VALUE_EQ_STRCASE");
        return !(e && e[0] == '0' && e[1] == '\0');
    }();
    return on;
}


/**
 * A pattern that lowers a `str` `eco.case` inside an `scf.if`, `scf.index_switch` or `scf.while` to a chain of
 * `scf.if`.
 *
 * EcoToLLVM lowers string cases with no `scf.if`, `scf.index_switch` or `scf.while` ancestor and leaves the others
 * alone, so this pattern is what lowers the latter. Each alternative but the last becomes
 * `if (scrutinee == pattern) { alternative } else { next test }`, the pattern being the matching
 * `string_patterns` entry made into an `eco.string_literal`, and the last alternative is the innermost else.
 * The equality is `eco.value.eq`, or a call to `Elm_Kernel_Utils_equal` whose result is unboxed to `i1` when
 * `valueEqStrCaseEnabled` is false. A case with no `string_patterns` is declined.
 */
struct CaseStringToScfIfChainPattern : public OpRewritePattern<CaseOp> {
    using OpRewritePattern::OpRewritePattern;

    LogicalResult matchAndRewrite(CaseOp op,
                                  PatternRewriter &rewriter) const override {
        if (hasAggregateResults(op))
            return failure();
        if (!isStringCase(op))
            return failure();

        auto alts = op.getAlternatives();
        if (alts.size() < 2)
            return failure();

        if (!hasPureYieldAlternatives(op))
            return failure();

        if (op->getParentOfType<JoinpointOp>())
            return failure();

        if (!op->getParentOfType<scf::IfOp>() &&
            !op->getParentOfType<scf::IndexSwitchOp>() &&
            !op->getParentOfType<scf::WhileOp>())
            return failure();

        auto stringPatternsAttr = op.getStringPatternsAttr();
        if (!stringPatternsAttr)
            return failure();

        auto loc = op.getLoc();
        auto resultTypes = getCaseResultTypes(op);
        Value scrutinee = op.getScrutinee();

        // With eco.value.eq no call is emitted, so nothing is declared.
        if (!valueEqStrCaseEnabled()) {
            auto module = op->getParentOfType<ModuleOp>();
            ensureEqualDeclared(rewriter, module, loc);
        }

        auto ifOp = buildStringIfChain(rewriter, loc, scrutinee, alts,
                                        stringPatternsAttr, resultTypes,
                                        0, alts.size());

        rewriter.replaceOp(op, ifOp->getResults());
        return success();
    }

private:
    // Declares `Elm_Kernel_Utils_equal` as a private `func.func` from two `!eco.value` to one, at the start of
    // `module`, unless `module` already has a symbol of that name.
    //
    // The pass declares it before the parallel phase, so in a pass run this only finds it.
    void ensureEqualDeclared(PatternRewriter &rewriter,
                             ModuleOp module, Location loc) const {
        if (module.lookupSymbol("Elm_Kernel_Utils_equal"))
            return;
        auto savedInsertPoint = rewriter.saveInsertionPoint();
        rewriter.setInsertionPointToStart(module.getBody());
        auto ecoValueTy = eco::ValueType::get(rewriter.getContext());
        auto funcTy = rewriter.getFunctionType({ecoValueTy, ecoValueTy}, {ecoValueTy});
        auto funcOp = rewriter.create<func::FuncOp>(loc, "Elm_Kernel_Utils_equal", funcTy);
        funcOp.setPrivate();
        rewriter.restoreInsertionPoint(savedInsertPoint);
    }

    // Builds, at the insertion point, the `scf.if` chain that tests `scrutinee` against `stringPatterns[altIdx]`
    // onwards, and returns its outermost `scf.if`.
    //
    // `altIdx` must be less than `numAlts - 1`. Each `stringPatterns` entry used must be a `StringAttr`; nothing
    // checks that there is one per non-default alternative.
    scf::IfOp buildStringIfChain(PatternRewriter &rewriter, Location loc,
                             Value scrutinee, MutableArrayRef<Region> alts,
                             ArrayAttr stringPatterns,
                             SmallVector<Type> &resultTypes,
                             size_t altIdx, size_t numAlts) const {
        if (altIdx == numAlts - 1) {
            llvm_unreachable("base case should not be reached directly");
        }

        // The last test: its else region is the default alternative.
        if (altIdx == numAlts - 2) {
            auto patternStr = cast<StringAttr>(stringPatterns[altIdx]).getValue();
            auto strLitOp = rewriter.create<StringLiteralOp>(loc,
                eco::ValueType::get(rewriter.getContext()), patternStr);
            auto ecoValueTy = eco::ValueType::get(rewriter.getContext());
            Value cond;
            if (valueEqStrCaseEnabled()) {
                cond = rewriter.create<eco::ValueEqOp>(
                    loc, rewriter.getI1Type(), scrutinee, strLitOp);
            } else {
                auto callOp = rewriter.create<func::CallOp>(
                    loc, "Elm_Kernel_Utils_equal",
                    TypeRange{ecoValueTy},
                    ValueRange{scrutinee, strLitOp});
                cond = rewriter.create<UnboxOp>(loc, rewriter.getI1Type(),
                                                callOp.getResult(0));
            }

            auto ifOp = rewriter.create<scf::IfOp>(loc, resultTypes, cond,
                                                    /*withElseRegion=*/true);
            {
                Block *thenBlock = &ifOp.getThenRegion().front();
                if (!thenBlock->empty())
                    if (auto y = dyn_cast<scf::YieldOp>(thenBlock->getTerminator()))
                        rewriter.eraseOp(y);
                rewriter.setInsertionPointToStart(thenBlock);
                IRMapping mapping;
                cloneAlternativeWithScfYield(alts[altIdx], rewriter, loc, mapping);
            }
            {
                Block *elseBlock = &ifOp.getElseRegion().front();
                if (!elseBlock->empty())
                    if (auto y = dyn_cast<scf::YieldOp>(elseBlock->getTerminator()))
                        rewriter.eraseOp(y);
                rewriter.setInsertionPointToStart(elseBlock);
                IRMapping mapping;
                cloneAlternativeWithScfYield(alts[numAlts - 1], rewriter, loc, mapping);
            }
            return ifOp;
        }

        auto patternStr = cast<StringAttr>(stringPatterns[altIdx]).getValue();
        auto strLitOp = rewriter.create<StringLiteralOp>(loc,
            eco::ValueType::get(rewriter.getContext()), patternStr);

        auto ecoValueTy = eco::ValueType::get(rewriter.getContext());
        auto i1Ty = rewriter.getI1Type();
        Value cond;
        if (valueEqStrCaseEnabled()) {
            cond = rewriter.create<eco::ValueEqOp>(loc, i1Ty, scrutinee, strLitOp);
        } else {
            auto callOp = rewriter.create<func::CallOp>(
                loc, "Elm_Kernel_Utils_equal",
                TypeRange{ecoValueTy},
                ValueRange{scrutinee, strLitOp});
            cond = rewriter.create<UnboxOp>(loc, i1Ty, callOp.getResult(0));
        }

        auto ifOp = rewriter.create<scf::IfOp>(loc, resultTypes, cond,
                                                /*withElseRegion=*/true);

        {
            Block *thenBlock = &ifOp.getThenRegion().front();
            if (!thenBlock->empty())
                if (auto existingYield = dyn_cast<scf::YieldOp>(thenBlock->getTerminator()))
                    rewriter.eraseOp(existingYield);
            rewriter.setInsertionPointToStart(thenBlock);
            IRMapping mapping;
            cloneAlternativeWithScfYield(alts[altIdx], rewriter, loc, mapping);
        }

        {
            Block *elseBlock = &ifOp.getElseRegion().front();
            if (!elseBlock->empty()) {
                if (auto existingYield = dyn_cast<scf::YieldOp>(elseBlock->getTerminator()))
                    rewriter.eraseOp(existingYield);
            }
            rewriter.setInsertionPointToStart(elseBlock);
            auto innerIfOp = buildStringIfChain(rewriter, loc, scrutinee, alts,
                                                   stringPatterns, resultTypes,
                                                   altIdx + 1, numAlts);
            // The recursive call leaves the insertion point inside the inner scf.if.
            rewriter.setInsertionPointToEnd(elseBlock);
            rewriter.create<scf::YieldOp>(loc, innerIfOp->getResults());
        }

        return ifOp;
    }
};

//===----------------------------------------------------------------------===//
// Pattern: SCF-candidate joinpoint -> scf.while
//===----------------------------------------------------------------------===//

// Returns the first `eco.case` directly in the entry block of `op`'s body, or null if there is none.
static CaseOp findTopLevelCase(JoinpointOp op) {
    Region &body = op.getBody();
    if (body.empty())
        return nullptr;

    Block &entryBlock = body.front();
    for (Operation &bodyOp : entryBlock) {
        if (auto caseOp = dyn_cast<CaseOp>(&bodyOp))
            return caseOp;
    }
    return nullptr;
}

// Returns the indices of the exit and loop alternatives of `caseOp`, and the exit alternative's tag, or `(-1, -1, 0)`
// when either is missing.
//
// An exit alternative ends in `eco.return`, and a loop alternative in an `eco.jump` to `jpId`. Where several qualify,
// the last of each is taken.
static std::tuple<int, int, int64_t> analyzeCaseAlternatives(CaseOp caseOp, int64_t jpId) {
    auto alts = caseOp.getAlternatives();
    auto tags = caseOp.getTags();

    int exitIdx = -1;
    int loopIdx = -1;

    for (size_t i = 0; i < alts.size(); ++i) {
        Region &alt = alts[i];
        if (alt.empty())
            continue;

        Block &block = alt.front();
        if (block.empty())
            continue;

        Operation *term = block.getTerminator();
        if (isa<ReturnOp>(term)) {
            exitIdx = i;
        } else if (auto jump = dyn_cast<JumpOp>(term)) {
            if (jump.getTarget() == static_cast<uint64_t>(jpId)) {
                loopIdx = i;
            }
        }
    }

    if (exitIdx >= 0 && loopIdx >= 0) {
        return {exitIdx, loopIdx, tags[exitIdx]};
    }
    return {-1, -1, 0};
}

// Returns the first `eco.jump` to `op`'s own id directly in the entry block of `op`'s continuation, or null if there
// is none. Its arguments are the loop's initial values.
static JumpOp getInitialJump(JoinpointOp op) {
    Region &cont = op.getContinuation();
    if (cont.empty())
        return nullptr;

    Block &entryBlock = cont.front();
    for (Operation &contOp : entryBlock) {
        if (auto jump = dyn_cast<JumpOp>(&contOp)) {
            if (jump.getTarget() == op.getId())
                return jump;
        }
    }
    return nullptr;
}

/**
 * A pattern that lowers an `eco.joinpoint` carrying both `scf_candidate` and `scf_case_loop` to an `scf.while`.
 *
 * It expects a body whose entry block holds an `eco.case` with an alternative ending in `eco.return` (the exit) and
 * one ending in an `eco.jump` back to the joinpoint (the loop), and a continuation with a jump to the joinpoint that
 * gives the initial values:
 *
 *     eco.joinpoint id(%val: !eco.value) {
 *       eco.case %val [exit_tag, loop_tag] {
 *         eco.return
 *       }, {
 *         %next = eco.project %val[1]
 *         eco.jump id(%next : !eco.value)
 *       }
 *     } continuation {
 *       eco.jump id(%initial : !eco.value)
 *     }
 *
 * becomes
 *
 *     %final = scf.while (%arg = %initial) : (!eco.value) -> !eco.value {
 *       %tag = eco.get_tag %arg
 *       %continue = arith.cmpi ne, %tag, %exit_tag_i32
 *       scf.condition(%continue) %arg : !eco.value
 *     } do {
 *     ^bb0(%arg : !eco.value):
 *       %next = eco.project %arg[1]
 *       scf.yield %next : !eco.value
 *     }
 *     // the exit alternative's ops, using %final
 *
 * The loop continues while the scrutinee's constructor tag differs from the exit tag, whatever the case's
 * `case_kind`. The loop alternative's ops, without its jump, become the loop body, and the jump's arguments its
 * yield. The exit alternative's ops, without its `eco.return`, are placed after the loop with the joinpoint's
 * arguments replaced by the loop's results. Nothing else in the body or the continuation is copied, and the
 * `eco.return` is dropped, whatever its operands. A joinpoint with no arguments is declined.
 */
struct JoinpointToScfWhilePattern : public OpRewritePattern<JoinpointOp> {
    using OpRewritePattern::OpRewritePattern;

    LogicalResult matchAndRewrite(JoinpointOp op,
                                  PatternRewriter &rewriter) const override {
        if (!op->hasAttr("scf_candidate"))
            return failure();

        if (!op->hasAttr("scf_case_loop"))
            return failure();

        auto loc = op.getLoc();

        CaseOp topCase = findTopLevelCase(op);
        if (!topCase)
            return failure();

        auto [exitIdx, loopIdx, exitTag] = analyzeCaseAlternatives(topCase, op.getId());
        if (exitIdx < 0 || loopIdx < 0)
            return failure();

        JumpOp initialJump = getInitialJump(op);
        if (!initialJump)
            return failure();

        Block &bodyEntry = op.getBody().front();
        SmallVector<Type> loopStateTypes;
        SmallVector<Value> initialValues;

        for (BlockArgument arg : bodyEntry.getArguments()) {
            loopStateTypes.push_back(arg.getType());
        }
        for (Value arg : initialJump.getArgs()) {
            initialValues.push_back(arg);
        }

        if (loopStateTypes.empty())
            return failure();

        auto whileOp = rewriter.create<scf::WhileOp>(
            loc, loopStateTypes, initialValues);

        // The before region: the exit test.
        {
            Block *beforeBlock = rewriter.createBlock(
                &whileOp.getBefore(), {}, loopStateTypes,
                SmallVector<Location>(loopStateTypes.size(), loc));

            rewriter.setInsertionPointToStart(beforeBlock);

            IRMapping condMapping;
            for (size_t i = 0; i < bodyEntry.getArguments().size(); ++i) {
                condMapping.map(bodyEntry.getArgument(i), beforeBlock->getArgument(i));
            }

            // Only the joinpoint's arguments are remapped; a scrutinee defined by another op is used as it is.
            Value scrutinee = topCase.getScrutinee();
            Value mappedScrutinee = condMapping.lookupOrDefault(scrutinee);

            auto tag = rewriter.create<GetTagOp>(loc, rewriter.getI32Type(), mappedScrutinee);

            auto exitTagConst = rewriter.create<arith::ConstantOp>(
                loc, rewriter.getI32IntegerAttr(exitTag));
            auto continueLoop = rewriter.create<arith::CmpIOp>(
                loc, arith::CmpIPredicate::ne, tag, exitTagConst);

            SmallVector<Value> condArgs;
            for (auto arg : beforeBlock->getArguments())
                condArgs.push_back(arg);

            rewriter.create<scf::ConditionOp>(loc, continueLoop, condArgs);
        }

        // The after region: the loop alternative.
        {
            Block *afterBlock = rewriter.createBlock(
                &whileOp.getAfter(), {}, loopStateTypes,
                SmallVector<Location>(loopStateTypes.size(), loc));

            rewriter.setInsertionPointToStart(afterBlock);

            IRMapping bodyMapping;
            for (size_t i = 0; i < bodyEntry.getArguments().size(); ++i) {
                bodyMapping.map(bodyEntry.getArgument(i), afterBlock->getArgument(i));
            }

            Region &loopAlt = topCase.getAlternatives()[loopIdx];
            Block &loopBlock = loopAlt.front();

            for (Operation &bodyOp : loopBlock.without_terminator()) {
                rewriter.clone(bodyOp, bodyMapping);
            }

            auto loopJump = cast<JumpOp>(loopBlock.getTerminator());
            SmallVector<Value> yieldValues;
            for (Value arg : loopJump.getArgs()) {
                yieldValues.push_back(bodyMapping.lookupOrDefault(arg));
            }

            rewriter.create<scf::YieldOp>(loc, yieldValues);
        }

        rewriter.setInsertionPointAfter(whileOp);

        IRMapping exitMapping;
        for (size_t i = 0; i < bodyEntry.getArguments().size(); ++i) {
            exitMapping.map(bodyEntry.getArgument(i), whileOp.getResult(i));
        }

        Region &exitAlt = topCase.getAlternatives()[exitIdx];
        Block &exitBlock = exitAlt.front();

        for (Operation &exitOp : exitBlock.without_terminator()) {
            rewriter.clone(exitOp, exitMapping);
        }

        // The exit alternative's eco.return is not copied, whatever its operands.
        rewriter.eraseOp(op);
        return success();
    }
};

//===----------------------------------------------------------------------===//
// Pass Definition
//===----------------------------------------------------------------------===//

/**
 * The module pass `eco-cf-to-scf`, which applies the patterns above to each top-level op.
 */
struct EcoControlFlowToSCFPass
    : public PassWrapper<EcoControlFlowToSCFPass, OperationPass<ModuleOp>> {
    MLIR_DEFINE_EXPLICIT_INTERNAL_INLINE_TYPE_ID(EcoControlFlowToSCFPass)

    StringRef getArgument() const override { return "eco-cf-to-scf"; }

    StringRef getDescription() const override {
        return "Lower eligible Eco control flow ops to SCF dialect";
    }

    // Lowers the eligible case and joinpoint ops of the module.
    //
    // The greedy driver is run on each top-level op that has a non-empty region and is isolated from above, in
    // chunks of consecutive ops, no more chunks than eight times the context's thread count, run in parallel when the
    // context is multithreaded. Each chunk builds its own patterns and `StringCaseMemo`. The driver's result is
    // ignored: what is not lowered is left for EcoToLLVM.
    //
    // Apart from rewriting inside top-level ops, the only change to the module is a symbol: when
    // `valueEqStrCaseEnabled` is false and the module has a `str` case, `Elm_Kernel_Utils_equal` is declared at the
    // start of the module before the parallel phase, so that the pattern's own declaration step only finds it there;
    // the declaration is made even if no pattern uses it. If a top-level op that is not isolated from above contains
    // an `eco.case` or `eco.joinpoint`, the driver is instead run once, serially, on the whole module.
    void runOnOperation() override {
        ModuleOp module = getOperation();
        auto *ctx = module.getContext();

        if (!valueEqStrCaseEnabled() &&
            !module.lookupSymbol("Elm_Kernel_Utils_equal")) {
            std::optional<Location> firstLoc;
            module.walk([&](CaseOp op) {
                if (isStringCase(op)) {
                    firstLoc = op.getLoc();
                    return WalkResult::interrupt();
                }
                return WalkResult::advance();
            });
            if (firstLoc) {
                OpBuilder b = OpBuilder::atBlockBegin(module.getBody());
                auto ecoValueTy = eco::ValueType::get(ctx);
                auto funcTy =
                    b.getFunctionType({ecoValueTy, ecoValueTy}, {ecoValueTy});
                auto funcOp = b.create<func::FuncOp>(
                    *firstLoc, "Elm_Kernel_Utils_equal", funcTy);
                funcOp.setPrivate();
            }
        }

        // The greedy driver needs a root that is isolated from above.
        SmallVector<Operation *> tops;
        bool needModuleFallback = false;
        for (Operation &op : *module.getBody()) {
            if (op.getNumRegions() == 0 ||
                llvm::none_of(op.getRegions(),
                              [](Region &r) { return !r.empty(); }))
                continue;
            if (op.hasTrait<OpTrait::IsIsolatedFromAbove>()) {
                tops.push_back(&op);
                continue;
            }
            op.walk([&](Operation *inner) {
                if (isa<CaseOp, JoinpointOp>(inner)) {
                    needModuleFallback = true;
                    return WalkResult::interrupt();
                }
                return WalkResult::advance();
            });
        }
        if (needModuleFallback)
            tops.assign(1, module.getOperation());
        if (tops.empty())
            return;

        const size_t nChunks = std::max<size_t>(
            1, std::min<size_t>(tops.size(), 8 * ctx->getNumThreads()));
        auto runChunk = [&](size_t c) {
            size_t lo = tops.size() * c / nChunks;
            size_t hi = tops.size() * (c + 1) / nChunks;

            // Benefits order the patterns when several match the same op; the case patterns already decline cases
            // inside a joinpoint body.
            StringCaseMemo stringCaseMemo;
            RewritePatternSet patterns(ctx);
            patterns.add<JoinpointToScfWhilePattern>(ctx, /*benefit=*/10);
            patterns.add<CaseStringToScfIfChainPattern>(ctx, /*benefit=*/6);
            patterns.add<CaseToScfIfPattern>(ctx, &stringCaseMemo, /*benefit=*/5);
            patterns.add<CaseToScfIndexSwitchPattern>(ctx, &stringCaseMemo,
                                                      /*benefit=*/5);
            patterns.add<CaseToScfIfChainPattern>(ctx, &stringCaseMemo,
                                                  /*benefit=*/4);
            FrozenRewritePatternSet frozen(std::move(patterns));

            GreedyRewriteConfig config;
            config.enableFolding(false);
            config.setListener(&stringCaseMemo);
            for (size_t i = lo; i < hi; ++i) {
                (void)applyPatternsGreedily(tops[i], frozen, config);
            }
        };
        if (ctx->isMultithreadingEnabled()) {
            parallelFor(ctx, 0, nChunks, runChunk);
        } else {
            for (size_t c = 0; c < nChunks; ++c)
                runChunk(c);
        }
    }
};

} // namespace

std::unique_ptr<Pass> eco::createEcoControlFlowToSCFPass() {
    return std::make_unique<EcoControlFlowToSCFPass>();
}
