//===- EcoControlFlowToSCF.cpp - Lower Eco control flow to SCF dialect ----===//
//
// This pass lowers eligible eco.case and eco.joinpoint operations to the SCF
// dialect (scf.if, scf.index_switch, scf.while).
//
// Lowering patterns:
// 1. eco.case with pure returns -> scf.if (2-way) or scf.index_switch (multi-way)
// 2. SCF-candidate eco.joinpoint -> scf.while
//
// Non-eligible operations are left for createControlFlowLoweringPass to handle.
//
//===----------------------------------------------------------------------===//

#include "mlir/Pass/Pass.h"
#include "mlir/IR/BuiltinOps.h"
#include "mlir/IR/PatternMatch.h"
#include "mlir/Transforms/DialectConversion.h"
#include "mlir/Transforms/GreedyPatternRewriteDriver.h"

#include "mlir/Dialect/SCF/IR/SCF.h"
#include "mlir/Dialect/Arith/IR/Arith.h"
#include "mlir/Dialect/ControlFlow/IR/ControlFlowOps.h"

#include "../EcoDialect.h"
#include "../EcoOps.h"
#include "../Passes.h"

#include "llvm/Support/Debug.h"
#define DEBUG_TYPE "eco-cf-to-scf"

using namespace mlir;
using namespace ::eco;

namespace {

//===----------------------------------------------------------------------===//
// Helpers
//===----------------------------------------------------------------------===//

/// Check if all alternatives in a case op end with eco.yield.
/// eco.case alternatives must terminate with eco.yield (not eco.return).
/// This is required for lowering to scf.if/scf.index_switch.
bool hasPureYieldAlternatives(CaseOp op) {
    for (Region &alt : op.getAlternatives()) {
        if (alt.empty())
            return false;

        Block &block = alt.front();
        if (block.empty())
            return false;

        Operation *term = block.getTerminator();
        // All alternatives must end with eco.yield
        if (!isa<YieldOp>(term))
            return false;
    }
    return true;
}

/// Get the result types from eco.case's explicit results.
/// eco.case is now a value-producing expression with explicit result types.
SmallVector<Type> getCaseResultTypes(CaseOp op) {
    return SmallVector<Type>(op.getResultTypes().begin(), op.getResultTypes().end());
}

/// Check if the case op has an i1 (Bool) scrutinee.
bool hasI1Scrutinee(CaseOp op) {
    Type scrutineeType = op.getScrutinee().getType();
    if (auto intType = dyn_cast<IntegerType>(scrutineeType)) {
        return intType.getWidth() == 1;
    }
    return false;
}

/// Check if this is an integer case (case_kind = "int").
bool isIntegerCase(CaseOp op) {
    auto caseKindAttr = op.getCaseKindAttr();
    if (!caseKindAttr)
        return false;
    return caseKindAttr.getValue() == "int";
}

/// Check if this is a character case (case_kind = "chr").
bool isCharCase(CaseOp op) {
    auto caseKindAttr = op.getCaseKindAttr();
    if (!caseKindAttr)
        return false;
    return caseKindAttr.getValue() == "chr";
}

/// Check if this is a string case (case_kind = "str").
bool isStringCase(CaseOp op) {
    auto caseKindAttr = op.getCaseKindAttr();
    if (!caseKindAttr)
        return false;
    return caseKindAttr.getValue() == "str";
}

//===----------------------------------------------------------------------===//
// Pattern: eco.case with pure yields -> scf.if (2-way case)
//===----------------------------------------------------------------------===//

/// Lowers eco.case with exactly 2 alternatives (both ending with eco.yield) to scf.if.
///
/// %result = eco.case %scrutinee [tag0, tag1] -> (T0) { case_kind = "ctor" } {
///   ... eco.yield %v0 : T0
/// }, {
///   ... eco.yield %v1 : T0
/// }
///
/// becomes:
///
/// %tag = eco.get_tag %scrutinee : !eco.value -> i32
/// %cond = arith.cmpi eq, %tag, %c_tag1_i32 : i32
/// %result = scf.if %cond -> (T0) {
///   ... scf.yield %v1 : T0
/// } else {
///   ... scf.yield %v0 : T0
/// }
struct CaseToScfIfPattern : public OpRewritePattern<CaseOp> {
    using OpRewritePattern::OpRewritePattern;

    LogicalResult matchAndRewrite(CaseOp op,
                                  PatternRewriter &rewriter) const override {
        LLVM_DEBUG(llvm::dbgs() << "CaseToScfIfPattern: trying to match eco.case at "
                                 << op.getLoc() << "\n");

        // Only handle 2-alternative cases
        auto alts = op.getAlternatives();
        if (alts.size() != 2) {
            LLVM_DEBUG(llvm::dbgs() << "  -> rejected: " << alts.size() << " alternatives (need 2)\n");
            return failure();
        }

        // All alternatives must end with eco.yield
        if (!hasPureYieldAlternatives(op)) {
            LLVM_DEBUG(llvm::dbgs() << "  -> rejected: not all alternatives end with eco.yield\n");
            return failure();
        }

        // Skip cases inside joinpoint bodies - these may have different control
        // flow requirements and should be handled by joinpoint-specific patterns.
        if (op->getParentOfType<JoinpointOp>())
            return failure();

        // NOTE: We intentionally do NOT skip cases nested inside other eco.case
        // alternatives or inside scf.if/scf.index_switch regions. Nested cases
        // should be lowered to nested SCF operations. The greedy pattern rewriter
        // will apply patterns until fixpoint, handling nested structures correctly.

        // Get result types from eco.case's explicit results
        auto resultTypes = getCaseResultTypes(op);

        LLVM_DEBUG(llvm::dbgs() << "  -> MATCHED! Converting to scf.if\n");

        auto loc = op.getLoc();
        auto tags = op.getTags();

        // Compute condition based on scrutinee type
        Value cond;
        if (hasI1Scrutinee(op)) {
            // For i1 scrutinee: use the value directly as condition
            // Convention: tag 1 = True goes to alt1 (then), tag 0 = False goes to alt0 (else)
            // If tags[1] == 1, condition is the scrutinee directly
            // If tags[1] == 0, condition is negated
            if (tags[1] == 1) {
                cond = op.getScrutinee();
            } else {
                // tags[1] == 0: negate the condition (XOR with 1)
                auto trueConst = rewriter.create<arith::ConstantOp>(
                    loc, rewriter.getI1Type(), rewriter.getIntegerAttr(rewriter.getI1Type(), 1));
                cond = rewriter.create<arith::XOrIOp>(loc, op.getScrutinee(), trueConst);
            }
        } else if (isIntegerCase(op)) {
            // For integer case: compare directly (unbox if needed)
            auto i64Ty = rewriter.getI64Type();
            Value scrutinee = op.getScrutinee();
            Value intVal;
            if (scrutinee.getType() == i64Ty) {
                // Already unboxed i64
                intVal = scrutinee;
            } else {
                // Boxed eco.value - unbox to i64
                intVal = rewriter.create<UnboxOp>(loc, i64Ty, scrutinee);
            }

            // Create comparison: value == tags[1] (second alternative)
            // We compare against tag1 so "true" branch is alt1, "else" is alt0
            auto tagConstant = rewriter.create<arith::ConstantOp>(
                loc, rewriter.getI64IntegerAttr(tags[1]));
            cond = rewriter.create<arith::CmpIOp>(
                loc, arith::CmpIPredicate::eq, intVal, tagConstant);
        } else if (isCharCase(op)) {
            // For char case: compare directly (unbox if needed)
            auto i16Ty = rewriter.getIntegerType(16);
            Value scrutinee = op.getScrutinee();
            Value charVal;
            if (scrutinee.getType() == i16Ty) {
                // Already unboxed i16
                charVal = scrutinee;
            } else {
                // Boxed eco.value - unbox to i16
                charVal = rewriter.create<UnboxOp>(loc, i16Ty, scrutinee);
            }

            // Create comparison: value == tags[1] (second alternative)
            auto tagConstant = rewriter.create<arith::ConstantOp>(
                loc, rewriter.getIntegerAttr(i16Ty, tags[1]));
            cond = rewriter.create<arith::CmpIOp>(
                loc, arith::CmpIPredicate::eq, charVal, tagConstant);
        } else {
            // For eco.value scrutinee (ADT constructor): extract tag and compare
            auto tag = rewriter.create<GetTagOp>(loc, rewriter.getI32Type(),
                                                 op.getScrutinee());

            // Create comparison: tag == tags[1] (second alternative)
            // We compare against tag1 so "true" branch is alt1, "else" is alt0
            auto tagConstant = rewriter.create<arith::ConstantOp>(
                loc, rewriter.getI32IntegerAttr(tags[1]));
            cond = rewriter.create<arith::CmpIOp>(
                loc, arith::CmpIPredicate::eq, tag, tagConstant);
        }

        // Create scf.if
        auto ifOp = rewriter.create<scf::IfOp>(loc, resultTypes, cond,
                                               /*withElseRegion=*/true);

        // Clone alt1 (true branch) into the 'then' region
        {
            Region &thenRegion = ifOp.getThenRegion();
            Block *thenBlock = &thenRegion.front();

            // scf.if creates default yield terminators - remove the existing one
            // before we populate the block with our content
            if (!thenBlock->empty()) {
                if (auto existingYield = dyn_cast<scf::YieldOp>(thenBlock->getTerminator())) {
                    rewriter.eraseOp(existingYield);
                }
            }

            rewriter.setInsertionPointToStart(thenBlock);

            IRMapping mapping;

            // Clone all operations from alt1 into then block.
            // Convert eco.yield to scf.yield.
            // Clone nested eco.case as-is (greedy driver rewrites it later).
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

        // Clone alt0 (false branch) into the 'else' region
        {
            Region &elseRegion = ifOp.getElseRegion();
            Block *elseBlock = &elseRegion.front();

            // Remove default yield terminator
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

        // eco.case is now a value-producing expression. Replace its uses with
        // the scf.if results and erase the original eco.case.
        rewriter.replaceOp(op, ifOp.getResults());
        return success();
    }
};

//===----------------------------------------------------------------------===//
// Pattern: eco.case with pure yields -> scf.index_switch (multi-way case)
//===----------------------------------------------------------------------===//

/// Lowers eco.case with >2 alternatives (all ending with eco.yield) to scf.index_switch.
struct CaseToScfIndexSwitchPattern : public OpRewritePattern<CaseOp> {
    using OpRewritePattern::OpRewritePattern;

    LogicalResult matchAndRewrite(CaseOp op,
                                  PatternRewriter &rewriter) const override {
        auto alts = op.getAlternatives();

        // Only handle >2 alternatives
        if (alts.size() <= 2)
            return failure();

        // All alternatives must end with eco.yield
        if (!hasPureYieldAlternatives(op))
            return failure();

        // i1 scrutinee should use the 2-way pattern (scf.if), not index_switch
        if (hasI1Scrutinee(op))
            return failure();

        // String cases need comparison chain, not index_switch
        if (isStringCase(op))
            return failure();

        // Int cases: only use index_switch if all tags are non-negative
        // (negative values can't be cast to index type safely)
        if (isIntegerCase(op)) {
            ArrayRef<int64_t> tags = op.getTags();
            for (int64_t tag : tags) {
                if (tag < 0)
                    return failure();  // Fall through to comparison chain pattern
            }
        }
        // Char cases: always OK (Unicode codepoints are non-negative)

        // Skip cases inside joinpoint bodies - these may have different control
        // flow requirements and should be handled by joinpoint-specific patterns.
        if (op->getParentOfType<JoinpointOp>())
            return failure();

        // NOTE: We intentionally do NOT skip cases nested inside other eco.case
        // alternatives or inside scf.if/scf.index_switch regions. Nested cases
        // should be lowered to nested SCF operations.

        auto resultTypes = getCaseResultTypes(op);

        auto loc = op.getLoc();
        auto tags = op.getTags();

        // Compute the index selector based on case kind
        Value indexTag;
        Value scrutinee = op.getScrutinee();
        Type scrutineeType = scrutinee.getType();

        if (isCharCase(op)) {
            // Char case: need i16 value, then cast to index
            auto i16Ty = rewriter.getIntegerType(16);
            Value charVal;
            if (scrutineeType == i16Ty) {
                // Already unboxed i16
                charVal = scrutinee;
            } else {
                // Boxed eco.value - unbox to i16
                charVal = rewriter.create<UnboxOp>(loc, i16Ty, scrutinee);
            }
            indexTag = rewriter.create<arith::IndexCastOp>(
                loc, rewriter.getIndexType(), charVal);
        } else if (isIntegerCase(op)) {
            // Int case: need i64 value, then cast to index
            auto i64Ty = rewriter.getI64Type();
            Value intVal;
            if (scrutineeType == i64Ty) {
                // Already unboxed i64
                intVal = scrutinee;
            } else {
                // Boxed eco.value - unbox to i64
                intVal = rewriter.create<UnboxOp>(loc, i64Ty, scrutinee);
            }
            indexTag = rewriter.create<arith::IndexCastOp>(
                loc, rewriter.getIndexType(), intVal);
        } else {
            // ADT case: extract constructor tag and cast to index
            auto tag = rewriter.create<GetTagOp>(loc, rewriter.getI32Type(),
                                                 scrutinee);
            indexTag = rewriter.create<arith::IndexCastOp>(
                loc, rewriter.getIndexType(), tag);
        }

        // Build case values (excluding LAST one which becomes default).
        // Elm puts wildcards LAST, so the last alternative is the default.
        SmallVector<int64_t> caseValues;
        for (size_t i = 0; i < tags.size() - 1; ++i) {
            caseValues.push_back(tags[i]);
        }

        // Create scf.index_switch
        auto switchOp = rewriter.create<scf::IndexSwitchOp>(
            loc, resultTypes, indexTag, caseValues, caseValues.size());

        // Fill in each case region (alts[0..N-2] map to scf cases)
        // Clone all ops. Convert eco.yield to scf.yield.
        // Clone nested eco.case as-is (greedy driver rewrites it later).
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

        // Fill in default region (maps to last alternative - the wildcard)
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

        // eco.case is now a value-producing expression. Replace its uses with
        // the scf.index_switch results and erase the original eco.case.
        rewriter.replaceOp(op, switchOp.getResults());
        return success();
    }
};

//===----------------------------------------------------------------------===//
// Pattern: eco.case -> nested scf.if chain (for string/negative-int cases)
//===----------------------------------------------------------------------===//

/// Helper to clone an alternative's body, converting eco.yield to scf.yield.
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

/// Lowers eco.case to nested scf.if chain for int cases with negative tags.
/// Each alternative (except the last default) becomes an equality comparison:
/// if (val == tag) { alt } else { next check... }
///
/// Note: String cases are NOT handled here - they require runtime string
/// comparison which is only available at the LLVM lowering level.
struct CaseToScfIfChainPattern : public OpRewritePattern<CaseOp> {
    using OpRewritePattern::OpRewritePattern;

    LogicalResult matchAndRewrite(CaseOp op,
                                  PatternRewriter &rewriter) const override {
        auto alts = op.getAlternatives();

        // Need >2 alternatives (2-way handled by CaseToScfIfPattern)
        if (alts.size() <= 2)
            return failure();

        // Only handle int cases with negative tags
        // (String cases are handled by CF lowering since they need runtime calls)
        if (!isIntegerCase(op))
            return failure();

        bool hasNegativeTag = false;
        for (int64_t tag : op.getTags()) {
            if (tag < 0) {
                hasNegativeTag = true;
                break;
            }
        }
        if (!hasNegativeTag)
            return failure();  // Non-negative int cases use index_switch

        // All alternatives must end with eco.yield
        if (!hasPureYieldAlternatives(op))
            return failure();

        // Skip cases inside joinpoint bodies
        if (op->getParentOfType<JoinpointOp>())
            return failure();

        auto loc = op.getLoc();
        auto resultTypes = getCaseResultTypes(op);

        return lowerIntCaseToIfChain(op, rewriter, loc, resultTypes);
    }

private:
    /// Build nested scf.if chain for int case with negative tags.
    LogicalResult lowerIntCaseToIfChain(CaseOp op, PatternRewriter &rewriter,
                                        Location loc,
                                        SmallVector<Type> &resultTypes) const {
        auto alts = op.getAlternatives();
        auto tags = op.getTags();
        auto i64Ty = rewriter.getI64Type();

        // Get or unbox scrutinee to i64
        Value scrutinee = op.getScrutinee();
        Value unboxed;
        if (scrutinee.getType() == i64Ty) {
            // Already unboxed i64
            unboxed = scrutinee;
        } else {
            // Boxed eco.value - unbox to i64
            unboxed = rewriter.create<UnboxOp>(loc, i64Ty, scrutinee);
        }

        // Build chain from back to front: last alternative is default (else)
        // Work backwards: start with default, then wrap each preceding alt
        size_t numAlts = alts.size();

        // Start with the default (last) alternative - this becomes innermost else
        // We'll build this as we construct the chain
        Value result = buildIntIfChain(rewriter, loc, unboxed, tags, alts,
                                       resultTypes, 0, numAlts);

        rewriter.replaceOp(op, result);
        return success();
    }

    /// Recursively build the if-chain for int cases.
    /// altIdx is the current alternative being processed.
    Value buildIntIfChain(PatternRewriter &rewriter, Location loc,
                          Value unboxed, ArrayRef<int64_t> tags,
                          MutableArrayRef<Region> alts,
                          SmallVector<Type> &resultTypes,
                          size_t altIdx, size_t numAlts) const {
        // Base case: last alternative is the default (no condition check)
        if (altIdx == numAlts - 1) {
            // Create a dummy scf.if that always takes the then branch,
            // or just inline the default. For simplicity, wrap in scf.if with true.
            auto trueConst = rewriter.create<arith::ConstantOp>(
                loc, rewriter.getI1Type(), rewriter.getBoolAttr(true));
            auto ifOp = rewriter.create<scf::IfOp>(loc, resultTypes, trueConst,
                                                   /*withElseRegion=*/false);
            // Fill then region with default alternative
            {
                Block *thenBlock = &ifOp.getThenRegion().front();
                rewriter.setInsertionPointToStart(thenBlock);
                IRMapping mapping;
                cloneAlternativeWithScfYield(alts[altIdx], rewriter, loc, mapping);
            }
            return ifOp.getResult(0);
        }

        // Create comparison: unboxed == tags[altIdx]
        auto tagConst = rewriter.create<arith::ConstantOp>(
            loc, rewriter.getI64IntegerAttr(tags[altIdx]));
        auto cond = rewriter.create<arith::CmpIOp>(
            loc, arith::CmpIPredicate::eq, unboxed, tagConst);

        // Create scf.if
        auto ifOp = rewriter.create<scf::IfOp>(loc, resultTypes, cond,
                                               /*withElseRegion=*/true);

        // Fill then region with current alternative
        {
            Block *thenBlock = &ifOp.getThenRegion().front();
            // Remove default yield if present
            if (!thenBlock->empty()) {
                if (auto existingYield = dyn_cast<scf::YieldOp>(thenBlock->getTerminator()))
                    rewriter.eraseOp(existingYield);
            }
            rewriter.setInsertionPointToStart(thenBlock);
            IRMapping mapping;
            cloneAlternativeWithScfYield(alts[altIdx], rewriter, loc, mapping);
        }

        // Fill else region with recursive chain
        {
            Block *elseBlock = &ifOp.getElseRegion().front();
            if (!elseBlock->empty()) {
                if (auto existingYield = dyn_cast<scf::YieldOp>(elseBlock->getTerminator()))
                    rewriter.eraseOp(existingYield);
            }
            rewriter.setInsertionPointToStart(elseBlock);
            Value innerResult = buildIntIfChain(rewriter, loc, unboxed, tags, alts,
                                                resultTypes, altIdx + 1, numAlts);
            rewriter.create<scf::YieldOp>(loc, innerResult);
        }

        return ifOp.getResult(0);
    }
};

//===----------------------------------------------------------------------===//
// Pattern: SCF-candidate joinpoint -> scf.while
//===----------------------------------------------------------------------===//

/// Helper: Find the top-level CaseOp in a joinpoint body
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

/// Helper: Analyze case alternatives to find exit and loop branches
/// Returns (exitIndex, loopIndex, exitTag) or (-1, -1, 0) if not a valid pattern
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

/// Helper: Get initial values from continuation's first jump
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

/// Lowers SCF-candidate joinpoints (marked by JoinpointNormalizationPass)
/// to scf.while loops.
///
/// This pattern handles the canonical loop structure:
/// eco.joinpoint id(%val: !eco.value) {
///   eco.case %val [exit_tag, loop_tag] {
///     eco.return                         // exit path (void)
///   }, {
///     %next = eco.project %val[1]
///     eco.jump id(%next : !eco.value)    // loop path
///   }
/// } continuation {
///   eco.jump id(%initial : !eco.value)
/// }
///
/// becomes:
///
/// %final = scf.while (%arg = %initial) : (!eco.value) -> !eco.value {
///   %tag = eco.get_tag %arg
///   %continue = arith.cmpi ne, %tag, %exit_tag_i32
///   scf.condition(%continue) %arg : !eco.value
/// } do {
/// ^bb0(%arg : !eco.value):
///   %next = eco.project %arg[1]
///   scf.yield %next : !eco.value
/// }
/// // exit path code here (using %final)
struct JoinpointToScfWhilePattern : public OpRewritePattern<JoinpointOp> {
    using OpRewritePattern::OpRewritePattern;

    LogicalResult matchAndRewrite(JoinpointOp op,
                                  PatternRewriter &rewriter) const override {
        // Only handle SCF-candidate joinpoints
        if (!op->hasAttr("scf_candidate"))
            return failure();

        // For now, only handle the simple case-loop pattern
        if (!op->hasAttr("scf_case_loop"))
            return failure();

        auto loc = op.getLoc();

        // Step 1: Find the top-level case in the body
        CaseOp topCase = findTopLevelCase(op);
        if (!topCase)
            return failure();

        // Step 2: Analyze case alternatives to find exit and loop branches
        auto [exitIdx, loopIdx, exitTag] = analyzeCaseAlternatives(topCase, op.getId());
        if (exitIdx < 0 || loopIdx < 0)
            return failure();

        // Step 3: Get initial values from continuation
        JumpOp initialJump = getInitialJump(op);
        if (!initialJump)
            return failure();

        // Get loop-carried state types from joinpoint parameters
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
            return failure(); // Need at least one loop variable

        // Step 4: Create scf.while
        auto whileOp = rewriter.create<scf::WhileOp>(
            loc, loopStateTypes, initialValues);

        // Step 5: Build the "before" region (condition check)
        {
            Block *beforeBlock = rewriter.createBlock(
                &whileOp.getBefore(), {}, loopStateTypes,
                SmallVector<Location>(loopStateTypes.size(), loc));

            rewriter.setInsertionPointToStart(beforeBlock);

            // Map joinpoint args to before block args
            IRMapping condMapping;
            for (size_t i = 0; i < bodyEntry.getArguments().size(); ++i) {
                condMapping.map(bodyEntry.getArgument(i), beforeBlock->getArgument(i));
            }

            // Extract tag from the scrutinee (first argument typically)
            Value scrutinee = topCase.getScrutinee();
            Value mappedScrutinee = condMapping.lookupOrDefault(scrutinee);

            auto tag = rewriter.create<GetTagOp>(loc, rewriter.getI32Type(), mappedScrutinee);

            // Compare: continue if tag != exit_tag
            auto exitTagConst = rewriter.create<arith::ConstantOp>(
                loc, rewriter.getI32IntegerAttr(exitTag));
            auto continueLoop = rewriter.create<arith::CmpIOp>(
                loc, arith::CmpIPredicate::ne, tag, exitTagConst);

            // Pass through loop state to condition
            SmallVector<Value> condArgs;
            for (auto arg : beforeBlock->getArguments())
                condArgs.push_back(arg);

            rewriter.create<scf::ConditionOp>(loc, continueLoop, condArgs);
        }

        // Step 6: Build the "after" region (loop body)
        {
            Block *afterBlock = rewriter.createBlock(
                &whileOp.getAfter(), {}, loopStateTypes,
                SmallVector<Location>(loopStateTypes.size(), loc));

            rewriter.setInsertionPointToStart(afterBlock);

            // Map joinpoint args to after block args
            IRMapping bodyMapping;
            for (size_t i = 0; i < bodyEntry.getArguments().size(); ++i) {
                bodyMapping.map(bodyEntry.getArgument(i), afterBlock->getArgument(i));
            }

            // Clone the loop alternative's body (excluding terminator)
            Region &loopAlt = topCase.getAlternatives()[loopIdx];
            Block &loopBlock = loopAlt.front();

            for (Operation &bodyOp : loopBlock.without_terminator()) {
                rewriter.clone(bodyOp, bodyMapping);
            }

            // Get the yield values from the eco.jump
            auto loopJump = cast<JumpOp>(loopBlock.getTerminator());
            SmallVector<Value> yieldValues;
            for (Value arg : loopJump.getArgs()) {
                yieldValues.push_back(bodyMapping.lookupOrDefault(arg));
            }

            rewriter.create<scf::YieldOp>(loc, yieldValues);
        }

        // Step 7: After the while loop, handle the exit path
        // The while results are the final loop state at exit
        rewriter.setInsertionPointAfter(whileOp);

        // Map joinpoint args to while results for exit path
        IRMapping exitMapping;
        for (size_t i = 0; i < bodyEntry.getArguments().size(); ++i) {
            exitMapping.map(bodyEntry.getArgument(i), whileOp.getResult(i));
        }

        // Clone the exit alternative's body (excluding terminator)
        Region &exitAlt = topCase.getAlternatives()[exitIdx];
        Block &exitBlock = exitAlt.front();

        for (Operation &exitOp : exitBlock.without_terminator()) {
            rewriter.clone(exitOp, exitMapping);
        }

        // Handle the eco.return in the exit path
        // For void returns, we just fall through
        // For returns with values, we'd need to handle result propagation
        // (This is handled by the existing EcoToLLVM pass for remaining eco.return ops)

        // Erase the original joinpoint
        rewriter.eraseOp(op);
        return success();
    }
};

//===----------------------------------------------------------------------===//
// Pass Definition
//===----------------------------------------------------------------------===//

struct EcoControlFlowToSCFPass
    : public PassWrapper<EcoControlFlowToSCFPass, OperationPass<ModuleOp>> {
    MLIR_DEFINE_EXPLICIT_INTERNAL_INLINE_TYPE_ID(EcoControlFlowToSCFPass)

    StringRef getArgument() const override { return "eco-cf-to-scf"; }

    StringRef getDescription() const override {
        return "Lower eligible Eco control flow ops to SCF dialect";
    }

    void runOnOperation() override {
        ModuleOp module = getOperation();
        auto *ctx = module.getContext();

        // Set up patterns
        RewritePatternSet patterns(ctx);

        // Add patterns in priority order:
        // 1. Joinpoint patterns first (higher benefit to consume case+joinpoint together)
        // 2. Then case patterns for remaining cases
        // 3. If-chain pattern last (fallback for int cases with negative tags)
        patterns.add<JoinpointToScfWhilePattern>(ctx, /*benefit=*/10);
        patterns.add<CaseToScfIfPattern>(ctx, /*benefit=*/5);
        patterns.add<CaseToScfIndexSwitchPattern>(ctx, /*benefit=*/5);
        patterns.add<CaseToScfIfChainPattern>(ctx, /*benefit=*/4);

        // Apply patterns greedily (with folding disabled to prevent DCE)
        GreedyRewriteConfig config;
        config.enableFolding(false);

        if (failed(applyPatternsGreedily(module, std::move(patterns), config))) {
            // Note: This may not be a hard error - some patterns might not match
            // which is fine, as remaining ops will be handled by CF lowering
        }
    }
};

} // namespace

std::unique_ptr<Pass> eco::createEcoControlFlowToSCFPass() {
    return std::make_unique<EcoControlFlowToSCFPass>();
}
