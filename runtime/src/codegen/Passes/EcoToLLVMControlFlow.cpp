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
        auto *ctx = rewriter.getContext();
        auto i64Ty = IntegerType::get(ctx, 64);
        auto i32Ty = IntegerType::get(ctx, 32);
        auto ptrTy = LLVM::LLVMPointerType::get(ctx);
        auto i8Ty = IntegerType::get(ctx, 8);

        Value value = adaptor.getValue();

        auto resolveFunc = runtime.getOrCreateResolveHPtr(rewriter);
        auto resolveCall = rewriter.create<LLVM::CallOp>(
            loc, resolveFunc, ValueRange{value});
        Value ptr = resolveCall.getResult();

        // Load ctor field at offset 8
        auto offset8 = rewriter.create<LLVM::ConstantOp>(loc, i64Ty, layout::CustomCtorOffset);
        auto ctorPtr = rewriter.create<LLVM::GEPOp>(loc, ptrTy, i8Ty, ptr,
                                                    ValueRange{offset8});
        auto ctorTag = rewriter.create<LLVM::LoadOp>(loc, i32Ty, ctorPtr);

        rewriter.replaceOp(op, ctorTag);
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

    LogicalResult
    matchAndRewrite(CaseOp op, OpAdaptor adaptor,
                    ConversionPatternRewriter &rewriter) const override {
        auto loc = op.getLoc();
        auto *ctx = rewriter.getContext();
        auto i64Ty = IntegerType::get(ctx, 64);
        auto i32Ty = IntegerType::get(ctx, 32);
        auto ptrTy = LLVM::LLVMPointerType::get(ctx);
        auto i8Ty = IntegerType::get(ctx, 8);

        Block *currentBlock = op->getBlock();
        Region *parentRegion = currentBlock->getParent();

        Value scrutinee = adaptor.getScrutinee();
        Value ctorTag;

        auto scrutineeType = scrutinee.getType();
        bool isI1Scrutinee = scrutineeType.isInteger(1);

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

        // Inline each alternative region
        for (size_t i = 0; i < alternatives.size(); ++i) {
            Region &altRegion = alternatives[i];
            Block *caseBlock = caseBlocks[i];

            if (altRegion.empty()) {
                rewriter.setInsertionPointToEnd(caseBlock);
                rewriter.create<cf::BranchOp>(loc, mergeBlock);
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

        // Fix terminators
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
