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

#include "mlir/Dialect/ControlFlow/IR/ControlFlowOps.h"
#include "mlir/Dialect/Func/IR/FuncOps.h"
#include "mlir/Dialect/SCF/IR/SCF.h"
#include "mlir/IR/IRMapping.h"

using namespace mlir;
using namespace eco;
using namespace eco::detail;

namespace {

//===----------------------------------------------------------------------===//
// eco.return -> func.return
//===----------------------------------------------------------------------===//

struct ReturnOpLowering : public OpConversionPattern<ReturnOp> {
    using OpConversionPattern::OpConversionPattern;

    LogicalResult
    matchAndRewrite(ReturnOp op, OpAdaptor adaptor,
                    ConversionPatternRewriter &rewriter) const override {
        rewriter.replaceOpWithNewOp<func::ReturnOp>(op, adaptor.getResults());
        return success();
    }
};

//===----------------------------------------------------------------------===//
// eco.get_tag -> Extract constructor tag from ADT value
//===----------------------------------------------------------------------===//

struct GetTagOpLowering : public OpConversionPattern<GetTagOp> {
    EcoRuntime runtime;

    GetTagOpLowering(EcoTypeConverter &typeConverter, MLIRContext *ctx,
                     EcoRuntime runtime)
        : OpConversionPattern(typeConverter, ctx), runtime(runtime) {}

    LogicalResult
    matchAndRewrite(GetTagOp op, OpAdaptor adaptor,
                    ConversionPatternRewriter &rewriter) const override {
        auto loc = op.getLoc();
        auto i32Ty = IntegerType::get(rewriter.getContext(), 32);

        Value value = adaptor.getValue();

        // Use runtime helper that handles both heap objects and embedded constants.
        auto getTagFunc = runtime.getOrCreateGetTag(rewriter);
        auto call = rewriter.create<LLVM::CallOp>(loc, getTagFunc, ValueRange{value});
        rewriter.replaceOp(op, call.getResult());
        return success();
    }
};

//===----------------------------------------------------------------------===//
// eco.case -> cf.switch on constructor tag
//===----------------------------------------------------------------------===//

struct CaseOpLowering : public OpConversionPattern<CaseOp> {
    EcoRuntime runtime;

    CaseOpLowering(EcoTypeConverter &typeConverter, MLIRContext *ctx,
                   EcoRuntime runtime)
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
            // Boxed eco.value - need to unbox from heap
            // 1. Resolve HPointer to raw pointer
            auto resolveFunc = runtime.getOrCreateResolveHPtr(rewriter);
            auto resolveCall = rewriter.create<LLVM::CallOp>(loc, resolveFunc, ValueRange{scrutinee});
            Value ptr = resolveCall.getResult();

            // 2. Offset past header (8 bytes) to get to value field
            auto offset = rewriter.create<LLVM::ConstantOp>(loc, i64Ty, layout::HeaderSize);
            auto valuePtr = rewriter.create<LLVM::GEPOp>(loc, ptrTy, i8Ty, ptr, ValueRange{offset});

            // 3. Load the unboxed value (always i64 for Int, then truncate for Char)
            unboxedValue = rewriter.create<LLVM::LoadOp>(loc, i64Ty, valuePtr);

            // For char case, truncate to i16
            if (!isIntCase) {
                unboxedValue = rewriter.create<LLVM::TruncOp>(loc, i16Ty, unboxedValue);
            }
        }

        ArrayRef<int64_t> tags = op.getTags();
        auto alternatives = op.getAlternatives();

        // Create merge block
        Block *mergeBlock = rewriter.createBlock(parentRegion);
        mergeBlock->moveBefore(currentBlock->getNextNode());

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

        // Fix terminators only for non-terminal cases
        if (!isTerminalCase) {
            for (Block *caseBlock : caseBlocks) {
                if (caseBlock->empty())
                    continue;

                Operation *term = caseBlock->getTerminator();
                if (isa<ReturnOp>(term)) {
                    rewriter.setInsertionPoint(term);
                    rewriter.create<cf::BranchOp>(loc, mergeBlock);
                    rewriter.eraseOp(term);
                }
            }
        }
        // For terminal cases, keep eco.return ops which will be converted
        // to func.return by the ReturnOpLowering pattern.

        // Erase the merge block if it's a terminal case (no code needs to follow)
        if (isTerminalCase) {
            rewriter.eraseBlock(mergeBlock);
        }

        rewriter.eraseOp(op);
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

        // Create merge block
        Block *mergeBlock = rewriter.createBlock(parentRegion);
        mergeBlock->moveBefore(currentBlock->getNextNode());

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

        // Get the equality function
        auto equalFunc = runtime.getOrCreateUtilsEqual(rewriter);

        // Generate comparison chain
        // For each pattern (except the last which is default), create:
        //   1. Create string literal
        //   2. Compare with scrutinee
        //   3. Branch to case block if equal, else continue to next check
        rewriter.setInsertionPointToEnd(currentBlock);

        size_t numPatterns = stringPatternsAttr.size();

        for (size_t i = 0; i < numPatterns; ++i) {
            auto patternAttr = cast<StringAttr>(stringPatternsAttr[i]);
            StringRef pattern = patternAttr.getValue();

            // Create string literal for this pattern
            Value patternValue;
            if (pattern.empty()) {
                // Empty string is an embedded constant
                int64_t emptyStringVal = static_cast<int64_t>(value_enc::EmptyString) << value_enc::ConstFieldShift;
                patternValue = rewriter.create<LLVM::ConstantOp>(loc, i64Ty, emptyStringVal);
            } else {
                // Create global for non-empty string
                // Convert UTF-8 to UTF-16
                std::vector<uint16_t> utf16 = utf8ToUtf16(pattern);
                size_t length = utf16.size();

                // Create unique global name
                std::string globalName = "__eco_str_case_" + std::to_string(
                    reinterpret_cast<uintptr_t>(op.getOperation())) + "_" + std::to_string(i);

                auto arrayTy = LLVM::LLVMArrayType::get(i16Ty, length);

                // Create global with initializer
                {
                    OpBuilder::InsertionGuard guard(rewriter);
                    rewriter.setInsertionPointToStart(runtime.module.getBody());

                    auto globalOp = rewriter.create<LLVM::GlobalOp>(
                        loc, arrayTy, /*isConstant=*/true, LLVM::Linkage::Internal,
                        globalName, /*value=*/Attribute{});

                    Block *initBlock = rewriter.createBlock(&globalOp.getInitializerRegion());
                    rewriter.setInsertionPointToStart(initBlock);

                    SmallVector<int16_t> charValues;
                    for (uint16_t c : utf16) {
                        charValues.push_back(static_cast<int16_t>(c));
                    }
                    auto denseAttr = DenseElementsAttr::get(
                        RankedTensorType::get({static_cast<int64_t>(length)}, i16Ty),
                        ArrayRef<int16_t>(charValues));
                    auto initValue = rewriter.create<LLVM::ConstantOp>(loc, arrayTy, denseAttr);
                    rewriter.create<LLVM::ReturnOp>(loc, initValue.getResult());
                }

                // Get address of global chars array
                auto addrOf = rewriter.create<LLVM::AddressOfOp>(loc, ptrTy, globalName);

                // Call eco_alloc_string_literal(chars, length) -> HPointer
                auto allocFunc = runtime.getOrCreateAllocStringLiteral(rewriter);
                auto lengthVal = rewriter.create<LLVM::ConstantOp>(loc, i32Ty,
                    static_cast<int32_t>(length));
                auto allocCall = rewriter.create<LLVM::CallOp>(loc, allocFunc,
                    ValueRange{addrOf, lengthVal});
                patternValue = allocCall.getResult();
            }

            // Call Elm_Kernel_Utils_equal(scrutinee, patternValue) -> i1
            auto cmpCall = rewriter.create<LLVM::CallOp>(loc, equalFunc,
                ValueRange{scrutinee, patternValue});
            Value isEqual = cmpCall.getResult();

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

        // Fix terminators only for non-terminal cases
        if (!isTerminalCase) {
            for (Block *caseBlock : caseBlocks) {
                if (caseBlock->empty())
                    continue;

                Operation *term = caseBlock->getTerminator();
                if (isa<ReturnOp>(term)) {
                    rewriter.setInsertionPoint(term);
                    rewriter.create<cf::BranchOp>(loc, mergeBlock);
                    rewriter.eraseOp(term);
                }
            }
        }

        // Erase the merge block if it's a terminal case
        if (isTerminalCase) {
            rewriter.eraseBlock(mergeBlock);
        }

        rewriter.eraseOp(op);
        return success();
    }

    LogicalResult
    matchAndRewrite(CaseOp op, OpAdaptor adaptor,
                    ConversionPatternRewriter &rewriter) const override {
        // Note: Dynamic legality in EcoToLLVM.cpp ensures this pattern is only
        // invoked when eco.case is NOT nested under SCF regions. The conversion
        // framework defers CaseOp conversion until SCF-to-CF has run.
#ifndef NDEBUG
        if (op->getParentOfType<scf::IfOp>() ||
            op->getParentOfType<scf::IndexSwitchOp>()) {
            llvm_unreachable("CaseOpLowering invoked while nested under SCF; "
                             "dynamic legality should have prevented this");
        }
#endif

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
            // Check for embedded constant
            auto shift40 = rewriter.create<LLVM::ConstantOp>(loc, i64Ty, value_enc::ConstFieldShift);
            auto shifted = rewriter.create<LLVM::LShrOp>(loc, scrutinee, shift40);
            auto maskF = rewriter.create<LLVM::ConstantOp>(loc, i64Ty, value_enc::ConstFieldMask);
            auto constField = rewriter.create<LLVM::AndOp>(loc, shifted, maskF);
            auto zero64 = rewriter.create<LLVM::ConstantOp>(loc, i64Ty, 0);
            isConstant = rewriter.create<LLVM::ICmpOp>(loc, LLVM::ICmpPredicate::ne,
                                                             constField, zero64);

            embConstBlock = rewriter.createBlock(parentRegion);
            embHeapBlock = rewriter.createBlock(parentRegion);
            Block *tagMergeBlock = rewriter.createBlock(parentRegion);
            tagMergeBlock->addArgument(i32Ty, loc);

            // Constant case: map Nil (5) to tag 0
            rewriter.setInsertionPointToStart(embConstBlock);
            auto nilConst = rewriter.create<LLVM::ConstantOp>(loc, i64Ty, value_enc::Nil);
            auto isNil = rewriter.create<LLVM::ICmpOp>(loc, LLVM::ICmpPredicate::eq,
                                                        constField, nilConst);
            auto tag0_64 = rewriter.create<LLVM::ConstantOp>(loc, i64Ty, 0);
            auto constTag64 = rewriter.create<LLVM::SelectOp>(loc, isNil, tag0_64, constField);
            auto constTag = rewriter.create<LLVM::TruncOp>(loc, i32Ty, constTag64);
            rewriter.create<cf::BranchOp>(loc, tagMergeBlock, ValueRange{constTag});

            // Heap case: load ctor from offset 8
            rewriter.setInsertionPointToStart(embHeapBlock);

            auto resolveFunc = runtime.getOrCreateResolveHPtr(rewriter);
            auto resolveCall = rewriter.create<LLVM::CallOp>(
                loc, resolveFunc, ValueRange{scrutinee});
            Value ptr = resolveCall.getResult();

            auto offset8 = rewriter.create<LLVM::ConstantOp>(loc, i64Ty, layout::CustomCtorOffset);
            auto ctorPtr = rewriter.create<LLVM::GEPOp>(loc, ptrTy, i8Ty, ptr,
                                                        ValueRange{offset8});
            auto ctorFromHeap = rewriter.create<LLVM::LoadOp>(loc, i32Ty, ctorPtr);
            rewriter.create<cf::BranchOp>(loc, tagMergeBlock, ValueRange{ctorFromHeap});

            rewriter.setInsertionPointToStart(tagMergeBlock);
            ctorTag = tagMergeBlock->getArgument(0);
            currentBlock = tagMergeBlock;
        }

        Block *originalOpBlock = op->getBlock();

        Block *mergeBlock = rewriter.createBlock(parentRegion);
        mergeBlock->moveBefore(currentBlock->getNextNode());

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

        SmallVector<int32_t> caseValuesI32;
        for (int64_t v : caseValues) {
            caseValuesI32.push_back(static_cast<int32_t>(v));
        }

        SmallVector<ValueRange> caseOperands(caseBlocks.size(), ValueRange{});

        rewriter.create<cf::SwitchOp>(
            loc, ctorTag, mergeBlock, ValueRange{},
            ArrayRef<int32_t>(caseValuesI32),
            caseBlocks, caseOperands);

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
            for (Operation &op : *caseBlock) {
                op.replaceUsesOfWith(originalScrutinee, scrutinee);
            }
        }

        // Fix terminators only for non-terminal cases
        if (!isTerminalCase) {
            for (Block *caseBlock : caseBlocks) {
                if (caseBlock->empty())
                    continue;

                Operation *term = caseBlock->getTerminator();
                if (isa<ReturnOp>(term)) {
                    rewriter.setInsertionPoint(term);
                    rewriter.create<cf::BranchOp>(loc, mergeBlock);
                    rewriter.eraseOp(term);
                }
            }
        }
        // For terminal cases, keep eco.return ops which will be converted
        // to func.return by the ReturnOpLowering pattern.

        // For terminal cases with empty mergeBlock, add llvm.unreachable.
        // We can't erase mergeBlock because cf.switch references it as default.
        // Since Elm case expressions are exhaustive, this default is unreachable.
        if (isTerminalCase && mergeBlock->empty()) {
            rewriter.setInsertionPointToEnd(mergeBlock);
            rewriter.create<LLVM::UnreachableOp>(loc);
        }

        rewriter.eraseOp(op);
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
    EcoRuntime runtime,
    EcoCFContext &cfCtx) {

    auto *ctx = patterns.getContext();
    patterns.add<ReturnOpLowering>(typeConverter, ctx);
    patterns.add<GetTagOpLowering>(typeConverter, ctx, runtime);
    patterns.add<CaseOpLowering>(typeConverter, ctx, runtime);
    patterns.add<JoinpointOpLowering>(typeConverter, ctx, cfCtx);
    patterns.add<JumpOpLowering>(typeConverter, ctx, cfCtx);
}
