//===- EcoToLLVMControlFlow.cpp - Control flow lowering patterns ----------===//
//
// This file implements lowering patterns for ECO control flow operations:
// case, joinpoint, jump, return, and get_tag.
//
//===----------------------------------------------------------------------===//

#include "EcoToLLVMInternal.h"
#include "../EcoDialect.h"
#include "../EcoOps.h"
#include "../EcoTypes.h"

#include <atomic>
#include <cstdint>

#include "mlir/Dialect/ControlFlow/IR/ControlFlowOps.h"
#include "mlir/Dialect/Func/IR/FuncOps.h"
#include "mlir/Dialect/SCF/IR/SCF.h"
#include "mlir/IR/IRMapping.h"

using namespace mlir;
using namespace eco;
using namespace eco::detail;

// Defined below (before preMaterializeStringCases); forward-declared here so
// the string-case lowering inside the anonymous namespace can use it.
static bool isAsciiCasePattern(llvm::StringRef s);

namespace {

/// kernel-opt-03 P3.5. Identical copy of the predicate in
/// EcoControlFlowToSCF.cpp -- see the rationale there; both halves of the
/// synthesized string-case path MUST be switched together.
static bool valueEqStrCaseEnabled() {
    static const bool on = [] {
        // DEFAULT-ON since 2026-08-12 (wall -0.22%, FLAT; out.mlir identical).
        // ECO_VALUE_EQ_STRCASE=0 is the kill switch.
        const char *e = ::getenv("ECO_VALUE_EQ_STRCASE");
        return !(e && e[0] == '0' && e[1] == '\0');
    }();
    return on;
}

//===----------------------------------------------------------------------===//
// eco.return -> func.return
//===----------------------------------------------------------------------===//

struct ReturnOpLowering : public OpConversionPattern<ReturnOp> {
    using OpConversionPattern::OpConversionPattern;

    LogicalResult
    matchAndRewrite(ReturnOp op, OpAdaptor adaptor,
                    ConversionPatternRewriter &rewriter) const override {
        // U-T1.3.3 sret worker return (CGEN_067): a MULTI-operand eco.return
        // belongs to an sret worker — store each field into the caller's slot
        // (the function's leading !llvm.ptr argument, prepended by
        // SretFuncOpLowering) and return void. Emitting the stores AT the
        // return point makes the store-before-return discipline STRUCTURAL:
        // no statepoint or side effect can intervene between the first store
        // and the terminator, so the stored ptr addrspace(1) fields are the
        // callee's post-relocation forms and the slot (host stack memory,
        // invisible to the GC) never holds a stale pointer across a
        // collection (REP_AGG_001 / plans/opt-tier1-aggregate-promotion.md).
        if (adaptor.getResults().size() > 1) {
            auto parent = op->getParentOfType<LLVM::LLVMFuncOp>();
            if (!parent)
                return op.emitError("multi-operand eco.return outside llvm.func");
            auto loc = op.getLoc();
            auto *ctx = rewriter.getContext();
            Value slot = parent.getArgument(0);
            SmallVector<Type> fieldTys(adaptor.getResults().getTypes().begin(),
                                       adaptor.getResults().getTypes().end());
            auto structTy = LLVM::LLVMStructType::getLiteral(ctx, fieldTys);
            auto ptrTy = LLVM::LLVMPointerType::get(ctx);
            for (auto [i, v] : llvm::enumerate(adaptor.getResults())) {
                Value gep = rewriter.create<LLVM::GEPOp>(
                    loc, ptrTy, structTy, slot,
                    ArrayRef<LLVM::GEPArg>{0, static_cast<int32_t>(i)});
                rewriter.create<LLVM::StoreOp>(loc, v, gep);
            }
            rewriter.replaceOpWithNewOp<func::ReturnOp>(op);
            return success();
        }
        rewriter.replaceOpWithNewOp<func::ReturnOp>(op, adaptor.getResults());
        return success();
    }
};

//===----------------------------------------------------------------------===//
// eco.get_tag -> Extract constructor tag from ADT value
//===----------------------------------------------------------------------===//

struct GetTagOpLowering : public OpConversionPattern<GetTagOp> {
    const EcoRuntime &runtime;

    GetTagOpLowering(EcoTypeConverter &typeConverter, MLIRContext *ctx,
                     const EcoRuntime &runtime)
        : OpConversionPattern(typeConverter, ctx), runtime(runtime) {}

    LogicalResult
    matchAndRewrite(GetTagOp op, OpAdaptor adaptor,
                    ConversionPatternRewriter &rewriter) const override {
        auto loc = op.getLoc();

        Value value = adaptor.getValue();

        // (Chunked-list modules keep the inline marker: expandGetTagMarkers
        // extends the diamond's Cons test with Tag_ConsChunk when the module
        // enables chunk production — see EcoBackend.cpp.)
        if (!inlineDerefExtEnabled()) {
            // Out-of-line fallback (A/B leg): the runtime helper handles both
            // heap objects and embedded constants.
            auto getTagFunc = runtime.getOrCreateGetTag(rewriter);
            auto call = rewriter.create<LLVM::CallOp>(loc, getTagFunc, ValueRange{value});
            rewriter.replaceOp(op, call.getResult());
            return success();
        }

        // P2.5 R1b (plans/allocator-resolve-inlining.md): emit the
        // `__eco_get_tag_inline` MARKER call. eco.get_tag lives INSIDE
        // structured scf regions (loopified tail recursion — the hot Dict/Set
        // loops), where multi-block lowering is illegal, so the open-coded
        // emb/heap/Custom/Cons diamond is built at the LLVM-IR level instead
        // (expandGetTagMarkers, EcoBackend.cpp — the ExpandInlineDeref
        // architecture), where block structure is unconstrained. The marker
        // is gc-leaf and declare-only; it never survives to codegen.
        auto markerFunc = runtime.getOrCreateGetTagInlineMarker(rewriter);
        auto call = rewriter.create<LLVM::CallOp>(loc, markerFunc, ValueRange{value});
        rewriter.replaceOp(op, call.getResult());
        return success();
    }
};

//===----------------------------------------------------------------------===//
// eco.case -> cf.switch on constructor tag
//===----------------------------------------------------------------------===//

struct CaseOpLowering : public OpConversionPattern<CaseOp> {
    const EcoRuntime &runtime;

    CaseOpLowering(EcoTypeConverter &typeConverter, MLIRContext *ctx,
                   const EcoRuntime &runtime)
        : OpConversionPattern(typeConverter, ctx), runtime(runtime) {}

    /// Lower integer or character case expressions.
    /// For these, we unbox the scrutinee and compare against the tag values directly.
    /// The last alternative is treated as the default (wildcard).
    LogicalResult
    lowerIntegerOrCharCase(CaseOp op, OpAdaptor adaptor,
                           ConversionPatternRewriter &rewriter,
                           bool isIntCase) const {
        auto loc = op.getLoc();
        auto *ctx = rewriter.getContext();
        auto i64Ty = IntegerType::get(ctx, 64);
        auto i16Ty = IntegerType::get(ctx, 16);
        auto ptrTy = LLVM::LLVMPointerType::get(ctx);
        auto i8Ty = IntegerType::get(ctx, 8);

        Block *currentBlock = op->getBlock();
        Region *parentRegion = currentBlock->getParent();
        Block *originalOpBlock = op->getBlock();

        Value scrutinee = adaptor.getScrutinee();
        Value unboxedValue;

        // Check if scrutinee is already unboxed (i64 for int, i16 for char)
        Type scrutineeType = scrutinee.getType();
        if (scrutineeType.isInteger(64)) {
            // Already unboxed i64 - use directly
            unboxedValue = scrutinee;
            // For char case, truncate to i16
            if (!isIntCase) {
                unboxedValue = rewriter.create<LLVM::TruncOp>(loc, i16Ty, unboxedValue);
            }
        } else if (scrutineeType.isInteger(16)) {
            // Already unboxed i16 (char) - use directly
            unboxedValue = scrutinee;
            // For int case, extend to i64
            if (isIntCase) {
                unboxedValue = rewriter.create<LLVM::ZExtOp>(loc, i64Ty, unboxedValue);
            }
        } else {
            // Boxed eco.value - need to unbox from heap. A boxed Int/Char
            // scrutinee is ALWAYS a real heap box (only False/True/Empty are
            // embedded constants), so the inline forwarding-check marker
            // applies directly (P2.5 R2, plans/allocator-resolve-inlining.md).
            // The loaded payload is an unboxed WORD (the Int/Char value),
            // never a pointer — no REP_LLVM_002 barrier applies.
            if (inlineDerefExtEnabled()) {
                auto hptrTy = getHPtrLLVMType(*ctx);
                Value base = inlineResolvedBase(rewriter, loc, scrutinee, runtime);
                auto offset = rewriter.create<LLVM::ConstantOp>(loc, i64Ty, layout::HeaderSize);
                auto valuePtr = rewriter.create<LLVM::GEPOp>(loc, hptrTy, i8Ty, base, ValueRange{offset});
                unboxedValue = rewriter.create<LLVM::LoadOp>(loc, i64Ty, valuePtr, layout::Alignment);
            } else {
                // Out-of-line fallback (A/B leg).
                auto resolveFunc = runtime.getOrCreateResolveHPtr(rewriter);
                auto resolveCall = rewriter.create<LLVM::CallOp>(loc, resolveFunc, ValueRange{scrutinee});
                Value ptr = resolveCall.getResult();
                auto offset = rewriter.create<LLVM::ConstantOp>(loc, i64Ty, layout::HeaderSize);
                auto valuePtr = rewriter.create<LLVM::GEPOp>(loc, ptrTy, i8Ty, ptr, ValueRange{offset});
                unboxedValue = rewriter.create<LLVM::LoadOp>(loc, i64Ty, valuePtr);
            }

            // For char case, truncate to i16
            if (!isIntCase) {
                unboxedValue = rewriter.create<LLVM::TruncOp>(loc, i16Ty, unboxedValue);
            }
        }

        ArrayRef<int64_t> tags = op.getTags();
        auto alternatives = op.getAlternatives();

        // Create merge block with arguments for value-producing cases
        Block *mergeBlock = rewriter.createBlock(parentRegion);
        mergeBlock->moveBefore(currentBlock->getNextNode());

        // If eco.case produces results, add block arguments to merge block
        bool isValueProducing = op.getNumResults() > 0;
        SmallVector<Type> resultTypes;
        if (isValueProducing) {
            for (Type t : op.getResultTypes()) {
                Type converted = getTypeConverter()->convertType(t);
                resultTypes.push_back(converted);
                mergeBlock->addArgument(converted, loc);
            }
        }

        // Create case blocks for each alternative
        SmallVector<Block *> caseBlocks;
        for (size_t i = 0; i < alternatives.size(); ++i) {
            Block *caseBlock = rewriter.createBlock(parentRegion);
            caseBlock->moveBefore(mergeBlock);
            caseBlocks.push_back(caseBlock);
        }

        // Move operations after eco.case to merge block
        {
            auto opsToMove = llvm::make_early_inc_range(
                llvm::make_range(std::next(Block::iterator(op)), originalOpBlock->end()));
            for (Operation &opToMove : opsToMove) {
                opToMove.moveBefore(mergeBlock, mergeBlock->end());
            }
        }

        // The LAST alternative is the default (wildcard)
        // Build case values for all but the last alternative
        SmallVector<int64_t> caseValues;
        SmallVector<Block *> caseDests;
        for (size_t i = 0; i < alternatives.size() - 1; ++i) {
            caseValues.push_back(tags[i]);
            caseDests.push_back(caseBlocks[i]);
        }

        // Default block is the last alternative (wildcard)
        Block *defaultBlock = caseBlocks.back();

        rewriter.setInsertionPointToEnd(currentBlock);

        // Create cf.switch with the unboxed value
        SmallVector<ValueRange> caseOperands(caseDests.size(), ValueRange{});

        // cf::SwitchOp requires APInt case values
        unsigned bitWidth = isIntCase ? 64 : 16;
        SmallVector<llvm::APInt> caseValuesAPInt;
        for (int64_t v : caseValues) {
            caseValuesAPInt.push_back(llvm::APInt(bitWidth, v));
        }

        rewriter.create<cf::SwitchOp>(
            loc, unboxedValue, defaultBlock, ValueRange{},
            ArrayRef<llvm::APInt>(caseValuesAPInt),
            caseDests, caseOperands);

        Value originalScrutinee = op->getOperand(0);

        // Check if eco.case is in terminal position. This is true when:
        // 1. mergeBlock is empty (eco.case was the block terminator with nothing after it), OR
        // 2. mergeBlock has only an eco.return (old format, for compatibility)
        // In terminal position, alternatives' eco.return ops should remain as
        // function terminators, not be replaced with branches.
        bool isTerminalCase = mergeBlock->empty();
        if (!isTerminalCase && mergeBlock->getOperations().size() == 1 &&
            isa<ReturnOp>(&mergeBlock->front())) {
            isTerminalCase = true;
        }

        // Inline each alternative region
        for (size_t i = 0; i < alternatives.size(); ++i) {
            Region &altRegion = alternatives[i];
            Block *caseBlock = caseBlocks[i];

            if (altRegion.empty()) {
                rewriter.setInsertionPointToEnd(caseBlock);
                if (isTerminalCase) {
                    // Copy the return op from merge block
                    if (!mergeBlock->empty()) {
                        if (auto retOp = dyn_cast<ReturnOp>(&mergeBlock->front())) {
                            rewriter.clone(*retOp);
                        }
                    }
                } else {
                    rewriter.create<cf::BranchOp>(loc, mergeBlock);
                }
                continue;
            }

            Block &entryBlock = altRegion.front();
            rewriter.inlineBlockBefore(&entryBlock, caseBlock, caseBlock->end());
        }

        // Replace uses of original scrutinee
        for (Block *caseBlock : caseBlocks) {
            for (Operation &blockOp : *caseBlock) {
                blockOp.replaceUsesOfWith(originalScrutinee, scrutinee);
            }
        }

        // Fix terminators: handle both eco.return and eco.yield
        // For value-producing cases (with eco.yield), convert to branch with arguments
        if (!isTerminalCase || isValueProducing) {
            for (Block *caseBlock : caseBlocks) {
                if (caseBlock->empty())
                    continue;

                Operation *term = caseBlock->getTerminator();
                if (auto yieldOp = dyn_cast<YieldOp>(term)) {
                    // eco.yield -> cf.branch with yielded values as arguments
                    rewriter.setInsertionPoint(term);
                    SmallVector<Value> branchArgs;
                    for (Value v : yieldOp.getOperands()) {
                        // Convert type if needed
                        Type converted = getTypeConverter()->convertType(v.getType());
                        if (converted != v.getType()) {
                            v = rewriter.create<UnrealizedConversionCastOp>(
                                loc, converted, v).getResult(0);
                        }
                        branchArgs.push_back(v);
                    }
                    rewriter.create<cf::BranchOp>(loc, mergeBlock, branchArgs);
                    rewriter.eraseOp(term);
                } else if (isa<ReturnOp>(term)) {
                    rewriter.setInsertionPoint(term);
                    rewriter.create<cf::BranchOp>(loc, mergeBlock);
                    rewriter.eraseOp(term);
                }
            }
        }
        // For terminal cases without results, keep eco.return ops which will be
        // converted to func.return by the ReturnOpLowering pattern.

        // Erase the merge block if it's a terminal case with no results
        if (isTerminalCase && !isValueProducing) {
            rewriter.eraseBlock(mergeBlock);
        }

        // Replace uses of eco.case results with merge block arguments
        if (isValueProducing) {
            rewriter.replaceOp(op, mergeBlock->getArguments());
        } else {
            rewriter.eraseOp(op);
        }
        return success();
    }

    /// Lower string case expressions using equality comparison chain.
    /// For each string pattern, we call Elm_Kernel_Utils_equal to compare
    /// the scrutinee against the literal. The last alternative is the default.
    LogicalResult
    lowerStringCase(CaseOp op, OpAdaptor adaptor,
                    ConversionPatternRewriter &rewriter) const {
        auto loc = op.getLoc();
        auto *ctx = rewriter.getContext();
        auto i64Ty = IntegerType::get(ctx, 64);
        auto i32Ty = IntegerType::get(ctx, 32);
        auto i16Ty = IntegerType::get(ctx, 16);
        auto ptrTy = LLVM::LLVMPointerType::get(ctx);

        Block *currentBlock = op->getBlock();
        Region *parentRegion = currentBlock->getParent();
        Block *originalOpBlock = op->getBlock();

        Value scrutinee = adaptor.getScrutinee();
        auto alternatives = op.getAlternatives();

        // Get string patterns
        auto stringPatternsAttr = op.getStringPatternsAttr();
        if (!stringPatternsAttr) {
            return op.emitOpError("string case missing string_patterns attribute");
        }

        // Create merge block with arguments for value-producing cases
        Block *mergeBlock = rewriter.createBlock(parentRegion);
        mergeBlock->moveBefore(currentBlock->getNextNode());

        // If eco.case produces results, add block arguments to merge block
        bool isValueProducing = op.getNumResults() > 0;
        SmallVector<Type> resultTypes;
        if (isValueProducing) {
            for (Type t : op.getResultTypes()) {
                Type converted = getTypeConverter()->convertType(t);
                resultTypes.push_back(converted);
                mergeBlock->addArgument(converted, loc);
            }
        }

        // Create case blocks for each alternative
        SmallVector<Block *> caseBlocks;
        for (size_t i = 0; i < alternatives.size(); ++i) {
            Block *caseBlock = rewriter.createBlock(parentRegion);
            caseBlock->moveBefore(mergeBlock);
            caseBlocks.push_back(caseBlock);
        }

        // Move operations after eco.case to merge block
        {
            auto opsToMove = llvm::make_early_inc_range(
                llvm::make_range(std::next(Block::iterator(op)), originalOpBlock->end()));
            for (Operation &opToMove : opsToMove) {
                opToMove.moveBefore(mergeBlock, mergeBlock->end());
            }
        }

        // kernel-opt-03 P3.5: under ECO_VALUE_EQ_STRCASE the boxed call + True-word
        // decode collapses to one __eco_value_eq marker whose i1 result IS
        // isEqual. Same expansion then covers these sites as every other
        // eco.value.eq. The predicate is duplicated in EcoControlFlowToSCF.cpp,
        // which handles the SCF half of this path; both MUST be switched together.
        auto equalFunc = valueEqStrCaseEnabled()
                             ? runtime.getOrCreateValueEqMarker(rewriter)
                             : runtime.getOrCreateUtilsEqual(rewriter);

        // Generate comparison chain
        // For each pattern (except the last which is default), create:
        //   1. Create string literal
        //   2. Compare with scrutinee
        //   3. Branch to case block if equal, else continue to next check
        rewriter.setInsertionPointToEnd(currentBlock);

        size_t numPatterns = stringPatternsAttr.size();

        // caseId assigned deterministically in preMaterializeStringCases; its
        // per-pattern "__eco_str_case_<caseId>_<i>" globals already exist. Read
        // from the side map (no counter, no create — read-only during Stage 2).
        auto caseIdIt = runtime.caseIdForOp.find(op.getOperation());
        assert(caseIdIt != runtime.caseIdForOp.end() &&
               "string-case globals not pre-materialized");
        const uint64_t caseId = caseIdIt->second;

        for (size_t i = 0; i < numPatterns; ++i) {
            auto patternAttr = cast<StringAttr>(stringPatternsAttr[i]);
            StringRef pattern = patternAttr.getValue();

            // Create string literal for this pattern
            Value patternValue;
            if (pattern.empty()) {
                // Empty string is an embedded HPointer constant. Wrap the
                // encoded i64 in an inttoptr so it has the `ptr<1>` type
                // Elm_Kernel_Utils_equal expects for both operands.
                int64_t emptyStringVal = value_enc::encodeConstant(value_enc::Empty);
                auto hptrTy = getHPtrLLVMType(*ctx);
                Value emptyI64 = rewriter.create<LLVM::ConstantOp>(loc, i64Ty, emptyStringVal);
                patternValue = rewriter.create<LLVM::IntToPtrOp>(loc, hptrTy, emptyI64);
            } else {
                // Global pre-created in preMaterializeStringCases; take its
                // address. ASCII patterns are [N x i8] built as UTF-8 leaves;
                // others are [N x i16] UTF-16. The ASCII decision is recomputed
                // (pure in the bytes) so it matches pre-materialization.
                llvm::SmallString<48> globalName;
                {
                    llvm::raw_svector_ostream os(globalName);
                    os << "__eco_str_case_" << caseId << "_" << i;
                }
                auto addrOf = rewriter.create<LLVM::AddressOfOp>(loc, ptrTy, globalName);

                if (isAsciiCasePattern(pattern)) {
                    auto allocFunc = runtime.getOrCreateAllocStringLiteralUtf8(rewriter);
                    auto lenVal = rewriter.create<LLVM::ConstantOp>(loc, i32Ty,
                        static_cast<int32_t>(pattern.size()));
                    auto allocCall = rewriter.create<LLVM::CallOp>(loc, allocFunc,
                        ValueRange{addrOf, lenVal});
                    patternValue = allocCall.getResult();
                } else {
                    std::vector<uint16_t> utf16 = utf8ToUtf16(pattern);
                    size_t length = utf16.size();
                    auto allocFunc = runtime.getOrCreateAllocStringLiteral(rewriter);
                    auto lengthVal = rewriter.create<LLVM::ConstantOp>(loc, i32Ty,
                        static_cast<int32_t>(length));
                    auto allocCall = rewriter.create<LLVM::CallOp>(loc, allocFunc,
                        ValueRange{addrOf, lengthVal});
                    patternValue = allocCall.getResult();
                }
            }

            // Compare scrutinee against the pattern. Under ECO_VALUE_EQ_STRCASE
            // the marker returns i1 directly; otherwise the kernel returns a
            // boxed Bool that must be decoded against the True word.
            auto cmpCall = rewriter.create<LLVM::CallOp>(loc, equalFunc,
                ValueRange{scrutinee, patternValue});
            Value isEqual;
            if (valueEqStrCaseEnabled()) {
                isEqual = cmpCall.getResult();
            } else {
                Value boxedResult = cmpCall.getResult();
                auto hptrTy = getHPtrLLVMType(*ctx);
                Value trueI64 = rewriter.create<LLVM::ConstantOp>(
                    loc, i64Ty, value_enc::encodeConstant(value_enc::True));
                Value trueConst =
                    rewriter.create<LLVM::IntToPtrOp>(loc, hptrTy, trueI64);
                isEqual = rewriter.create<LLVM::ICmpOp>(
                    loc, LLVM::ICmpPredicate::eq, boxedResult, trueConst);
            }

            // Save the current block (where comparison was built) before creating new blocks
            Block *compareBlock = rewriter.getInsertionBlock();

            // Determine the else block
            Block *elseBlock;
            if (i + 1 < numPatterns) {
                // More patterns to check - create a new check block
                // Note: createBlock changes insertion point, so we saved compareBlock above
                elseBlock = rewriter.createBlock(parentRegion);
                elseBlock->moveBefore(mergeBlock);
            } else {
                // Last pattern's else goes to default (last alternative)
                elseBlock = caseBlocks.back();
            }

            // Branch must be in compareBlock (not elseBlock)
            rewriter.setInsertionPointToEnd(compareBlock);
            rewriter.create<cf::CondBranchOp>(loc, isEqual,
                caseBlocks[i], ValueRange{}, elseBlock, ValueRange{});

            // Continue building from else block for next pattern
            if (i + 1 < numPatterns) {
                rewriter.setInsertionPointToEnd(elseBlock);
            }
        }

        // If there are no patterns, branch directly to default
        if (numPatterns == 0) {
            rewriter.create<cf::BranchOp>(loc, caseBlocks.back());
        }

        Value originalScrutinee = op->getOperand(0);

        // Check if eco.case is in terminal position. This is true when:
        // 1. mergeBlock is empty (eco.case was the block terminator), OR
        // 2. mergeBlock has only an eco.return (old format, for compatibility)
        bool isTerminalCase = mergeBlock->empty();
        if (!isTerminalCase && mergeBlock->getOperations().size() == 1 &&
            isa<ReturnOp>(&mergeBlock->front())) {
            isTerminalCase = true;
        }

        // Inline each alternative region
        for (size_t i = 0; i < alternatives.size(); ++i) {
            Region &altRegion = alternatives[i];
            Block *caseBlock = caseBlocks[i];

            if (altRegion.empty()) {
                rewriter.setInsertionPointToEnd(caseBlock);
                if (isTerminalCase) {
                    if (!mergeBlock->empty()) {
                        if (auto retOp = dyn_cast<ReturnOp>(&mergeBlock->front())) {
                            rewriter.clone(*retOp);
                        }
                    }
                } else {
                    rewriter.create<cf::BranchOp>(loc, mergeBlock);
                }
                continue;
            }

            Block &entryBlock = altRegion.front();
            rewriter.inlineBlockBefore(&entryBlock, caseBlock, caseBlock->end());
        }

        // Replace uses of original scrutinee
        for (Block *caseBlock : caseBlocks) {
            for (Operation &blockOp : *caseBlock) {
                blockOp.replaceUsesOfWith(originalScrutinee, scrutinee);
            }
        }

        // Fix terminators: handle both eco.return and eco.yield
        // For value-producing cases (with eco.yield), convert to branch with arguments
        if (!isTerminalCase || isValueProducing) {
            for (Block *caseBlock : caseBlocks) {
                if (caseBlock->empty())
                    continue;

                Operation *term = caseBlock->getTerminator();
                if (auto yieldOp = dyn_cast<YieldOp>(term)) {
                    // eco.yield -> cf.branch with yielded values as arguments
                    rewriter.setInsertionPoint(term);
                    SmallVector<Value> branchArgs;
                    for (Value v : yieldOp.getOperands()) {
                        // Convert type if needed
                        Type converted = getTypeConverter()->convertType(v.getType());
                        if (converted != v.getType()) {
                            v = rewriter.create<UnrealizedConversionCastOp>(
                                loc, converted, v).getResult(0);
                        }
                        branchArgs.push_back(v);
                    }
                    rewriter.create<cf::BranchOp>(loc, mergeBlock, branchArgs);
                    rewriter.eraseOp(term);
                } else if (isa<ReturnOp>(term)) {
                    rewriter.setInsertionPoint(term);
                    rewriter.create<cf::BranchOp>(loc, mergeBlock);
                    rewriter.eraseOp(term);
                }
            }
        }

        // Erase the merge block if it's a terminal case with no results
        if (isTerminalCase && !isValueProducing) {
            rewriter.eraseBlock(mergeBlock);
        }

        // Replace uses of eco.case results with merge block arguments
        if (isValueProducing) {
            rewriter.replaceOp(op, mergeBlock->getArguments());
        } else {
            rewriter.eraseOp(op);
        }
        return success();
    }

    LogicalResult
    matchAndRewrite(CaseOp op, OpAdaptor adaptor,
                    ConversionPatternRewriter &rewriter) const override {
        // Note: Dynamic legality in EcoToLLVM.cpp ensures this pattern is only
        // invoked when eco.case is NOT nested under SCF regions. The conversion
        // framework defers CaseOp conversion until SCF-to-CF has run.
        auto loc = op.getLoc();
        auto *ctx = rewriter.getContext();
        auto i64Ty = IntegerType::get(ctx, 64);
        auto i32Ty = IntegerType::get(ctx, 32);
        auto ptrTy = LLVM::LLVMPointerType::get(ctx);
        auto i8Ty = IntegerType::get(ctx, 8);

        Block *currentBlock = op->getBlock();
        Region *parentRegion = currentBlock->getParent();

        Value scrutinee = adaptor.getScrutinee();

        auto scrutineeType = scrutinee.getType();
        bool isI1Scrutinee = scrutineeType.isInteger(1);

        // Check if this is an integer case
        auto caseKindAttr = op.getCaseKindAttr();
        bool isIntCase = caseKindAttr && caseKindAttr.getValue() == "int";
        bool isChrCase = caseKindAttr && caseKindAttr.getValue() == "chr";
        bool isStrCase = caseKindAttr && caseKindAttr.getValue() == "str";

        // Handle integer/char cases: unbox and switch on actual value
        if (isIntCase || isChrCase) {
            return lowerIntegerOrCharCase(op, adaptor, rewriter, isIntCase);
        }

        // Handle string cases: compare against string patterns using equality
        if (isStrCase) {
            return lowerStringCase(op, adaptor, rewriter);
        }

        Value ctorTag;

        Value isConstant;
        Block *embConstBlock = nullptr;
        Block *embHeapBlock = nullptr;

        if (isI1Scrutinee) {
            ctorTag = rewriter.create<LLVM::ZExtOp>(loc, i32Ty, scrutinee);
        } else {
            // Convert ptr<1> scrutinee to i64 for ADT tag bit-tests.
            // Result stays in this basic block: lshr → and → icmp chain only.
            Value scrutineeI64 = caseScrutineeToI64(rewriter, loc, scrutinee);

            // Check for embedded constant: ptr_ind (bit 2) distinguishes a
            // constant from a heap pointer; the constant field is bits 0-1.
            auto ptrIndShift = rewriter.create<LLVM::ConstantOp>(loc, i64Ty, value_enc::PtrIndBit);
            auto ptrIndShifted = rewriter.create<LLVM::LShrOp>(loc, scrutineeI64, ptrIndShift);
            auto one64 = rewriter.create<LLVM::ConstantOp>(loc, i64Ty, 1);
            auto ptrIndBit = rewriter.create<LLVM::AndOp>(loc, ptrIndShifted, one64);
            auto maskF = rewriter.create<LLVM::ConstantOp>(loc, i64Ty, value_enc::ConstFieldMask);
            auto constField = rewriter.create<LLVM::AndOp>(loc, scrutineeI64, maskF);
            auto zero64 = rewriter.create<LLVM::ConstantOp>(loc, i64Ty, 0);
            isConstant = rewriter.create<LLVM::ICmpOp>(loc, LLVM::ICmpPredicate::ne,
                                                             ptrIndBit, zero64);

            embConstBlock = rewriter.createBlock(parentRegion);
            embHeapBlock = rewriter.createBlock(parentRegion);
            Block *tagMergeBlock = rewriter.createBlock(parentRegion);
            tagMergeBlock->addArgument(i32Ty, loc);

            // Constant case: derive the ctor tag without the scrutinee's type
            // (see plan D9). An "empty" constant (anything but a Bool) maps to
            // the reserved CONSTANT_TAG; a Bool constant maps to its i1 value
            // (0 = False, 1 = True). `constField` here is non-zero (this block is
            // only reached when isConstant), so "empty" = "not True and not
            // False".
            rewriter.setInsertionPointToStart(embConstBlock);
            auto trueConst = rewriter.create<LLVM::ConstantOp>(loc, i64Ty, value_enc::True);
            auto falseConst = rewriter.create<LLVM::ConstantOp>(loc, i64Ty, value_enc::False);
            auto isTrue = rewriter.create<LLVM::ICmpOp>(loc, LLVM::ICmpPredicate::eq,
                                                        constField, trueConst);
            auto isFalse = rewriter.create<LLVM::ICmpOp>(loc, LLVM::ICmpPredicate::eq,
                                                         constField, falseConst);
            auto isBool = rewriter.create<LLVM::OrOp>(loc, isTrue, isFalse);
            auto boolTag64 = rewriter.create<LLVM::ZExtOp>(loc, i64Ty, isTrue);
            auto constantTagC = rewriter.create<LLVM::ConstantOp>(loc, i64Ty, value_enc::ConstantTag);
            auto constTag64 = rewriter.create<LLVM::SelectOp>(loc, isBool, boolTag64, constantTagC);
            auto constTag = rewriter.create<LLVM::TruncOp>(loc, i32Ty, constTag64);
            rewriter.create<cf::BranchOp>(loc, tagMergeBlock, ValueRange{constTag});

            // Heap case: load ctor from offset 8. The emb/heap split above
            // guarantees this arm only sees real heap pointers, so the
            // inline forwarding-check marker applies (P2.5 R1a,
            // plans/allocator-resolve-inlining.md) — this is the hot
            // per-compare tag fetch in Dict/Set case loops.
            rewriter.setInsertionPointToStart(embHeapBlock);

            Value ptr;
            Type ctorGepTy;
            if (inlineDerefExtEnabled()) {
                ptr = inlineResolvedBase(rewriter, loc, scrutinee, runtime);
                ctorGepTy = getHPtrLLVMType(*ctx);
            } else {
                // Out-of-line fallback (A/B leg).
                auto resolveFunc = runtime.getOrCreateResolveHPtr(rewriter);
                auto resolveCall = rewriter.create<LLVM::CallOp>(
                    loc, resolveFunc, ValueRange{scrutinee});
                ptr = resolveCall.getResult();
                ctorGepTy = ptrTy;
            }

            auto offset8 = rewriter.create<LLVM::ConstantOp>(loc, i64Ty, layout::CustomCtorOffset);
            auto ctorPtr = rewriter.create<LLVM::GEPOp>(loc, ctorGepTy, i8Ty, ptr,
                                                        ValueRange{offset8});
            // Custom layout packs `u16 ctor : 16` with `u64 unboxed : 48` into one
            // 8-byte word at offset 8 (Heap.hpp). Loading i32 here would mix the
            // lower 16 bits of the unboxed bitmap into the discriminator, sending
            // ctors whose object happens to have any unboxed slot to the default
            // arm. Load just the 16-bit ctor and zero-extend.
            auto i16Ty = IntegerType::get(ctx, 16);
            auto ctorI16 = rewriter.create<LLVM::LoadOp>(loc, i16Ty, ctorPtr);
            auto ctorFromHeap = rewriter.create<LLVM::ZExtOp>(loc, i32Ty, ctorI16);
            rewriter.create<cf::BranchOp>(loc, tagMergeBlock, ValueRange{ctorFromHeap});

            rewriter.setInsertionPointToStart(tagMergeBlock);
            ctorTag = tagMergeBlock->getArgument(0);
            currentBlock = tagMergeBlock;
        }

        Block *originalOpBlock = op->getBlock();

        // Create merge block with arguments for value-producing cases
        Block *mergeBlock = rewriter.createBlock(parentRegion);
        mergeBlock->moveBefore(currentBlock->getNextNode());

        // If eco.case produces results, add block arguments to merge block
        bool isValueProducing = op.getNumResults() > 0;
        SmallVector<Type> resultTypes;
        if (isValueProducing) {
            for (Type t : op.getResultTypes()) {
                Type converted = getTypeConverter()->convertType(t);
                resultTypes.push_back(converted);
                mergeBlock->addArgument(converted, loc);
            }
        }

        ArrayRef<int64_t> tags = op.getTags();
        auto alternatives = op.getAlternatives();

        SmallVector<int64_t> caseValues;
        SmallVector<Block *> caseBlocks;

        for (size_t i = 0; i < alternatives.size(); ++i) {
            Block *caseBlock = rewriter.createBlock(parentRegion);
            caseBlock->moveBefore(mergeBlock);
            caseValues.push_back(tags[i]);
            caseBlocks.push_back(caseBlock);
        }

        // Move operations after eco.case to merge block
        {
            auto opsToMove = llvm::make_early_inc_range(
                llvm::make_range(std::next(Block::iterator(op)), originalOpBlock->end()));
            for (Operation &opToMove : opsToMove) {
                opToMove.moveBefore(mergeBlock, mergeBlock->end());
            }
        }

        // Create CondBranchOp for embedded constant handling
        if (!isI1Scrutinee) {
            rewriter.setInsertionPointToEnd(originalOpBlock);
            rewriter.create<cf::CondBranchOp>(loc, isConstant, embConstBlock, embHeapBlock);
        }

        rewriter.setInsertionPointToEnd(currentBlock);

        // Use last case block as the default destination (same pattern as
        // lowerIntegerOrCharCase). Elm cases are exhaustive, so the default
        // is just the last alternative. Using mergeBlock as default would
        // require passing block arguments that match mergeBlock's signature.
        Block *defaultBlock = caseBlocks.back();
        SmallVector<int32_t> switchCaseValues;
        SmallVector<Block *> switchCaseDests;
        for (size_t i = 0; i < caseBlocks.size() - 1; ++i) {
            switchCaseValues.push_back(static_cast<int32_t>(caseValues[i]));
            switchCaseDests.push_back(caseBlocks[i]);
        }

        SmallVector<ValueRange> caseOperands(switchCaseDests.size(), ValueRange{});

        rewriter.create<cf::SwitchOp>(
            loc, ctorTag, defaultBlock, ValueRange{},
            ArrayRef<int32_t>(switchCaseValues),
            switchCaseDests, caseOperands);

        Value originalScrutinee = op->getOperand(0);

        // Check if eco.case is in terminal position. This is true when:
        // 1. mergeBlock is empty (eco.case was the block terminator), OR
        // 2. mergeBlock has only an eco.return (old format, for compatibility)
        bool isTerminalCase = mergeBlock->empty();
        if (!isTerminalCase && mergeBlock->getOperations().size() == 1 &&
            isa<ReturnOp>(&mergeBlock->front())) {
            isTerminalCase = true;
        }

        // Inline each alternative region
        for (size_t i = 0; i < alternatives.size(); ++i) {
            Region &altRegion = alternatives[i];
            Block *caseBlock = caseBlocks[i];

            if (altRegion.empty()) {
                rewriter.setInsertionPointToEnd(caseBlock);
                if (isTerminalCase) {
                    if (!mergeBlock->empty()) {
                        if (auto retOp = dyn_cast<ReturnOp>(&mergeBlock->front())) {
                            rewriter.clone(*retOp);
                        }
                    }
                } else {
                    rewriter.create<cf::BranchOp>(loc, mergeBlock);
                }
                continue;
            }

            Block &entryBlock = altRegion.front();
            rewriter.inlineBlockBefore(&entryBlock, caseBlock, caseBlock->end());
        }

        // Replace uses of original scrutinee in all blocks between case start and merge.
        // After nested case lowering, alternatives may span multiple blocks.
        {
            bool inCaseRegion = false;
            for (Block &block : *parentRegion) {
                if (&block == caseBlocks.front())
                    inCaseRegion = true;
                if (&block == mergeBlock)
                    break;
                if (inCaseRegion) {
                    for (Operation &op : block) {
                        op.replaceUsesOfWith(originalScrutinee, scrutinee);
                    }
                }
            }
        }

        // Fix terminators: handle both eco.return and eco.yield.
        // After nested case lowering, an alternative may span multiple blocks.
        // Walk all blocks between case start and merge to find yield/return terminators.
        if (!isTerminalCase || isValueProducing) {
            bool inCaseRegion = false;
            for (Block &block : *parentRegion) {
                if (&block == caseBlocks.front())
                    inCaseRegion = true;
                if (&block == mergeBlock)
                    break;
                if (!inCaseRegion || block.empty())
                    continue;

                Operation *term = block.getTerminator();
                if (auto yieldOp = dyn_cast<YieldOp>(term)) {
                    // eco.yield -> cf.branch with yielded values as arguments
                    rewriter.setInsertionPoint(term);
                    SmallVector<Value> branchArgs;
                    for (Value v : yieldOp.getOperands()) {
                        // Convert type if needed
                        Type converted = getTypeConverter()->convertType(v.getType());
                        if (converted != v.getType()) {
                            v = rewriter.create<UnrealizedConversionCastOp>(
                                loc, converted, v).getResult(0);
                        }
                        branchArgs.push_back(v);
                    }
                    rewriter.create<cf::BranchOp>(loc, mergeBlock, branchArgs);
                    rewriter.eraseOp(term);
                } else if (isa<ReturnOp>(term)) {
                    rewriter.setInsertionPoint(term);
                    rewriter.create<cf::BranchOp>(loc, mergeBlock);
                    rewriter.eraseOp(term);
                }
            }
        }
        // For terminal cases without results, keep eco.return ops which will be
        // converted to func.return by the ReturnOpLowering pattern.

        // For terminal cases with empty mergeBlock and no results, add llvm.unreachable.
        // We can't erase mergeBlock because cf.switch references it as default.
        // Since Elm case expressions are exhaustive, this default is unreachable.
        if (isTerminalCase && !isValueProducing && mergeBlock->empty()) {
            rewriter.setInsertionPointToEnd(mergeBlock);
            rewriter.create<LLVM::UnreachableOp>(loc);
        }

        // Replace uses of eco.case results with merge block arguments
        if (isValueProducing) {
            rewriter.replaceOp(op, mergeBlock->getArguments());
        } else {
            rewriter.eraseOp(op);
        }
        return success();
    }
};

//===----------------------------------------------------------------------===//
// Joinpoint/Jump lowering with EcoCFContext
//===----------------------------------------------------------------------===//

// Forward declaration
static void lowerJoinpointRegion(
    Block &sourceBlock, Block *targetBlock, Block *exitBlock,
    IRMapping &mapping, ConversionPatternRewriter &rewriter,
    const TypeConverter *typeConverter, EcoCFContext &cfCtx, bool isBodyRegion);

static void lowerNestedJoinpoint(
    JoinpointOp nestedJP, Block *outerExitBlock,
    IRMapping &mapping, ConversionPatternRewriter &rewriter,
    const TypeConverter *typeConverter, EcoCFContext &cfCtx) {

    auto loc = nestedJP.getLoc();
    int64_t jpId = nestedJP.getId();
    Operation *parentFunc = nestedJP->getParentOfType<func::FuncOp>();

    Block *insertBlock = rewriter.getInsertionBlock();
    Region *parentRegion = insertBlock->getParent();

    Block *nestedExitBlock = rewriter.createBlock(parentRegion);
    Block *jpBlock = rewriter.createBlock(parentRegion);
    jpBlock->moveBefore(nestedExitBlock);

    Region &bodyRegion = nestedJP.getBody();
    Block &bodyEntry = bodyRegion.front();
    for (BlockArgument arg : bodyEntry.getArguments()) {
        Type convertedType = typeConverter->convertType(arg.getType());
        jpBlock->addArgument(convertedType, loc);
    }

    cfCtx.joinpointBlocks[{parentFunc, jpId}] = jpBlock;

    Block *contBlock = rewriter.createBlock(parentRegion);
    contBlock->moveBefore(jpBlock);

    rewriter.setInsertionPointToEnd(insertBlock);
    rewriter.create<cf::BranchOp>(loc, contBlock);

    IRMapping bodyMapping(mapping);
    for (auto [oldArg, newArg] : llvm::zip(bodyEntry.getArguments(),
                                            jpBlock->getArguments())) {
        bodyMapping.map(oldArg, newArg);
    }

    rewriter.setInsertionPointToEnd(jpBlock);
    lowerJoinpointRegion(bodyEntry, jpBlock, nestedExitBlock, bodyMapping,
                         rewriter, typeConverter, cfCtx, /*isBodyRegion=*/true);

    rewriter.setInsertionPointToEnd(contBlock);
    Region &contRegion = nestedJP.getContinuation();
    if (!contRegion.empty()) {
        Block &contEntry = contRegion.front();
        IRMapping contMapping(mapping);
        lowerJoinpointRegion(contEntry, contBlock, nestedExitBlock, contMapping,
                             rewriter, typeConverter, cfCtx, /*isBodyRegion=*/false);
    }

    rewriter.setInsertionPointToEnd(nestedExitBlock);
}

static void lowerJoinpointRegion(
    Block &sourceBlock, Block *targetBlock, Block *exitBlock,
    IRMapping &mapping, ConversionPatternRewriter &rewriter,
    const TypeConverter *typeConverter, EcoCFContext &cfCtx, bool isBodyRegion) {

    auto loc = sourceBlock.getParentOp()->getLoc();

    for (Operation &innerOp : llvm::make_early_inc_range(sourceBlock)) {
        if (isa<ReturnOp>(&innerOp)) {
            rewriter.create<cf::BranchOp>(loc, exitBlock);
        } else if (isa<JumpOp>(&innerOp)) {
            rewriter.clone(innerOp, mapping);
        } else if (auto nestedJP = dyn_cast<JoinpointOp>(&innerOp)) {
            lowerNestedJoinpoint(nestedJP, exitBlock, mapping, rewriter, typeConverter, cfCtx);
        } else {
            Operation *cloned = rewriter.clone(innerOp, mapping);
            for (auto [oldResult, newResult] :
                 llvm::zip(innerOp.getResults(), cloned->getResults())) {
                mapping.map(oldResult, newResult);
            }
        }
    }
}

struct JoinpointOpLowering : public OpConversionPattern<JoinpointOp> {
    EcoCFContext &cfCtx;

    JoinpointOpLowering(EcoTypeConverter &typeConverter, MLIRContext *ctx,
                        EcoCFContext &cfCtx)
        : OpConversionPattern(typeConverter, ctx), cfCtx(cfCtx) {}

    LogicalResult
    matchAndRewrite(JoinpointOp op, OpAdaptor adaptor,
                    ConversionPatternRewriter &rewriter) const override {
        auto loc = op.getLoc();
        int64_t jpId = op.getId();
        Operation *parentFunc = op->getParentOfType<func::FuncOp>();

        Block *currentBlock = op->getBlock();
        Region *parentRegion = currentBlock->getParent();

        Region &bodyRegion = op.getBody();
        Block &bodyEntry = bodyRegion.front();

        Block *exitBlock = rewriter.createBlock(parentRegion);
        exitBlock->moveBefore(currentBlock->getNextNode());

        // Move operations after eco.joinpoint to exit block
        {
            auto opsToMove = llvm::make_early_inc_range(
                llvm::make_range(std::next(Block::iterator(op)), currentBlock->end()));
            for (Operation &opToMove : opsToMove) {
                opToMove.moveBefore(exitBlock, exitBlock->end());
            }
        }

        Block *jpBlock = rewriter.createBlock(parentRegion);
        jpBlock->moveBefore(exitBlock);

        for (BlockArgument arg : bodyEntry.getArguments()) {
            Type convertedType = getTypeConverter()->convertType(arg.getType());
            jpBlock->addArgument(convertedType, loc);
        }

        cfCtx.joinpointBlocks[{parentFunc, jpId}] = jpBlock;

        Block *contBlock = rewriter.createBlock(parentRegion);
        contBlock->moveBefore(jpBlock);

        rewriter.setInsertionPointToEnd(currentBlock);
        rewriter.create<cf::BranchOp>(loc, contBlock);

        IRMapping mapping;
        for (auto [oldArg, newArg] : llvm::zip(bodyEntry.getArguments(),
                                                jpBlock->getArguments())) {
            mapping.map(oldArg, newArg);
        }

        rewriter.setInsertionPointToEnd(jpBlock);
        lowerJoinpointRegion(bodyEntry, jpBlock, exitBlock, mapping,
                             rewriter, getTypeConverter(), cfCtx, /*isBodyRegion=*/true);

        rewriter.setInsertionPointToEnd(contBlock);
        Region &contRegion = op.getContinuation();
        if (!contRegion.empty()) {
            Block &contEntry = contRegion.front();
            IRMapping contMapping;
            lowerJoinpointRegion(contEntry, contBlock, exitBlock, contMapping,
                                 rewriter, getTypeConverter(), cfCtx, /*isBodyRegion=*/false);
        }

        rewriter.eraseOp(op);
        return success();
    }
};

//===----------------------------------------------------------------------===//
// YieldOp Safety Net (should have been lowered by SCF pass)
//===----------------------------------------------------------------------===//

/// Safety net pattern: emits a clear error if eco.yield survives to LLVM lowering.
/// eco.yield should always be lowered to scf.yield by EcoControlFlowToSCF, or
/// converted to cf.branch by CaseOpLowering. If it reaches here, something is wrong.
struct YieldOpLowering : public OpConversionPattern<YieldOp> {
    using OpConversionPattern::OpConversionPattern;

    LogicalResult
    matchAndRewrite(YieldOp op, OpAdaptor adaptor,
                    ConversionPatternRewriter &rewriter) const override {
        return op.emitError("eco.yield should have been lowered by EcoControlFlowToSCF "
                           "or converted by CaseOpLowering; this indicates a missing "
                           "pattern for the parent eco.case");
    }
};

struct JumpOpLowering : public OpConversionPattern<JumpOp> {
    EcoCFContext &cfCtx;

    JumpOpLowering(EcoTypeConverter &typeConverter, MLIRContext *ctx,
                   EcoCFContext &cfCtx)
        : OpConversionPattern(typeConverter, ctx), cfCtx(cfCtx) {}

    LogicalResult
    matchAndRewrite(JumpOp op, OpAdaptor adaptor,
                    ConversionPatternRewriter &rewriter) const override {
        int64_t targetId = op.getTarget();
        Operation *parentFunc = op->getParentOfType<func::FuncOp>();

        auto it = cfCtx.joinpointBlocks.find({parentFunc, targetId});
        if (it == cfCtx.joinpointBlocks.end()) {
            return op.emitError("jump to unknown joinpoint id ") << targetId;
        }

        Block *targetBlock = it->second;
        rewriter.replaceOpWithNewOp<cf::BranchOp>(op, targetBlock, adaptor.getArgs());
        return success();
    }
};

} // namespace

//===----------------------------------------------------------------------===//
// Pattern Population
//===----------------------------------------------------------------------===//

void eco::detail::populateEcoControlFlowPatterns(
    EcoTypeConverter &typeConverter,
    RewritePatternSet &patterns,
    const EcoRuntime &runtime,
    EcoCFContext &cfCtx) {

    auto *ctx = patterns.getContext();
    patterns.add<ReturnOpLowering>(typeConverter, ctx);
    patterns.add<GetTagOpLowering>(typeConverter, ctx, runtime);
    patterns.add<CaseOpLowering>(typeConverter, ctx, runtime);
    patterns.add<YieldOpLowering>(typeConverter, ctx);  // Safety net for unlowered yields
    patterns.add<JoinpointOpLowering>(typeConverter, ctx, cfCtx);
    patterns.add<JumpOpLowering>(typeConverter, ctx, cfCtx);
}

// Phase-2 pre-materialization: walk string-kind eco.case ops in module program
// order, assign each a deterministic caseId (a per-module counter, replacing the
// old file-static atomic — same input + same order => same ids => deterministic
// output), create its per-pattern __eco_str_case_<caseId>_<i> globals, and
// record the caseId in the side map read by lowerStringCase during Stage 2.
// A string-case pattern is all-ASCII iff every byte is < 0x80. ASCII patterns
// are emitted as [N x i8] globals and constructed as inline UTF-8 leaves,
// matching EcoToLLVMTypes.cpp's literal handling. Pure in the bytes, so
// pre-materialization and lowering agree without a side map.
static bool isAsciiCasePattern(llvm::StringRef s) {
    for (char c : s)
        if (static_cast<unsigned char>(c) & 0x80) return false;
    return true;
}

void eco::detail::preMaterializeStringCases(
    OpBuilder &builder, const EcoRuntime &runtime,
    llvm::ArrayRef<LLVM::LLVMFuncOp> funcs) {
    auto *ctx = builder.getContext();
    auto i16Ty = IntegerType::get(ctx, 16);
    auto i8Ty = IntegerType::get(ctx, 8);
    uint64_t caseCounter = 0;
    for (LLVM::LLVMFuncOp func : funcs) {
        func.walk([&](CaseOp op) {
            auto ck = op.getCaseKindAttr();
            if (!(ck && ck.getValue() == "str")) return;
            auto pats = op.getStringPatternsAttr();
            if (!pats) return;
            uint64_t caseId = caseCounter++;
            runtime.caseIdForOp[op.getOperation()] = caseId;
            for (size_t i = 0; i < pats.size(); ++i) {
                StringRef pattern = cast<StringAttr>(pats[i]).getValue();
                if (pattern.empty()) continue;  // embedded empty-string const
                llvm::SmallString<48> globalName;
                {
                    llvm::raw_svector_ostream os(globalName);
                    os << "__eco_str_case_" << caseId << "_" << i;
                }
                OpBuilder::InsertionGuard guard(builder);
                builder.setInsertionPointToStart(runtime.module.getBody());

                if (isAsciiCasePattern(pattern)) {
                    size_t byteLen = pattern.size();
                    auto arrayTy = LLVM::LLVMArrayType::get(i8Ty, byteLen);
                    auto globalOp = builder.create<LLVM::GlobalOp>(
                        op.getLoc(), arrayTy, /*isConstant=*/true,
                        LLVM::Linkage::Internal, globalName, /*value=*/Attribute{});
                    Block *initBlock =
                        builder.createBlock(&globalOp.getInitializerRegion());
                    builder.setInsertionPointToStart(initBlock);
                    SmallVector<int8_t> byteValues;
                    for (char c : pattern)
                        byteValues.push_back(static_cast<int8_t>(c));
                    auto denseAttr = DenseElementsAttr::get(
                        RankedTensorType::get({static_cast<int64_t>(byteLen)}, i8Ty),
                        ArrayRef<int8_t>(byteValues));
                    auto initValue = builder.create<LLVM::ConstantOp>(
                        op.getLoc(), arrayTy, denseAttr);
                    builder.create<LLVM::ReturnOp>(op.getLoc(), initValue.getResult());
                    continue;
                }

                std::vector<uint16_t> utf16 = utf8ToUtf16(pattern);
                size_t length = utf16.size();
                auto arrayTy = LLVM::LLVMArrayType::get(i16Ty, length);
                auto globalOp = builder.create<LLVM::GlobalOp>(
                    op.getLoc(), arrayTy, /*isConstant=*/true,
                    LLVM::Linkage::Internal, globalName, /*value=*/Attribute{});
                Block *initBlock =
                    builder.createBlock(&globalOp.getInitializerRegion());
                builder.setInsertionPointToStart(initBlock);
                SmallVector<int16_t> charValues;
                for (uint16_t c : utf16)
                    charValues.push_back(static_cast<int16_t>(c));
                auto denseAttr = DenseElementsAttr::get(
                    RankedTensorType::get({static_cast<int64_t>(length)}, i16Ty),
                    ArrayRef<int16_t>(charValues));
                auto initValue =
                    builder.create<LLVM::ConstantOp>(op.getLoc(), arrayTy, denseAttr);
                builder.create<LLVM::ReturnOp>(op.getLoc(), initValue.getResult());
            }
        });
    }
}
