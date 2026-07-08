//===- EcoToLLVMTypes.cpp - Type and constant lowering patterns -----------===//
//
// This file implements lowering patterns for ECO constants and string literals.
//
//===----------------------------------------------------------------------===//

#include "EcoToLLVMInternal.h"
#include "../EcoDialect.h"
#include "../EcoOps.h"

#include "mlir/Dialect/Arith/IR/Arith.h"

using namespace mlir;
using namespace eco;
using namespace eco::detail;

namespace {

//===----------------------------------------------------------------------===//
// eco.constant -> i64 constant with embedded tag
//===----------------------------------------------------------------------===//

struct ConstantOpLowering : public OpConversionPattern<ConstantOp> {
    using OpConversionPattern::OpConversionPattern;

    LogicalResult
    matchAndRewrite(ConstantOp op, OpAdaptor adaptor,
                    ConversionPatternRewriter &rewriter) const override {
        auto loc = op.getLoc();
        auto *ctx = rewriter.getContext();
        auto i64Ty = IntegerType::get(ctx, 64);
        auto hptrTy = getHPtrLLVMType(*ctx);

        // Get the constant kind and encode it in the HPointer format.
        int64_t kindValue = static_cast<int64_t>(op.getKind());
        int64_t encoded = value_enc::encodeConstant(kindValue);

        Value i64Val = rewriter.create<LLVM::ConstantOp>(loc, i64Ty, encoded);
        Value result = rewriter.create<LLVM::IntToPtrOp>(loc, hptrTy, i64Val);
        rewriter.replaceOp(op, result);
        return success();
    }
};

//===----------------------------------------------------------------------===//
// eco.string_literal -> call eco_alloc_string_literal
//===----------------------------------------------------------------------===//

// A literal is all-ASCII iff every byte is < 0x80. Such literals are emitted as
// [N x i8] globals and constructed as inline UTF-8 leaves (half the memory, no
// transcode); non-ASCII literals stay [N x i16] UTF-16. This predicate is pure
// in the literal's bytes, so pre-materialization and lowering agree without a
// side map. Kept in sync with EcoToLLVMControlFlow.cpp's copy for string cases.
static bool isAsciiLiteral(llvm::StringRef s) {
    for (char c : s)
        if (static_cast<unsigned char>(c) & 0x80) return false;
    return true;
}

struct StringLiteralOpLowering : public OpConversionPattern<StringLiteralOp> {
    const EcoRuntime &runtime;

    StringLiteralOpLowering(EcoTypeConverter &typeConverter, MLIRContext *ctx,
                            const EcoRuntime &runtime)
        : OpConversionPattern(typeConverter, ctx), runtime(runtime) {}

    LogicalResult
    matchAndRewrite(StringLiteralOp op, OpAdaptor adaptor,
                    ConversionPatternRewriter &rewriter) const override {
        auto loc = op.getLoc();
        auto *ctx = rewriter.getContext();
        auto i64Ty = IntegerType::get(ctx, 64);
        auto i32Ty = IntegerType::get(ctx, 32);
        auto i16Ty = IntegerType::get(ctx, 16);
        auto ptrTy = LLVM::LLVMPointerType::get(ctx);

        StringRef value = op.getValue();
        (void)i16Ty;

        auto hptrTy = getHPtrLLVMType(*ctx);

        // Empty string -> use embedded constant
        if (value.empty()) {
            int64_t encoded = value_enc::encodeConstant(value_enc::Empty);
            Value i64Val = rewriter.create<LLVM::ConstantOp>(loc, i64Ty, encoded);
            Value result = rewriter.create<LLVM::IntToPtrOp>(loc, hptrTy, i64Val);
            rewriter.replaceOp(op, result);
            return success();
        }

        // Global was pre-created (preMaterializeStringLiterals); read its index
        // from the side map and take its address (no create, no counter bump —
        // the symbol table is read-only during the body stage).
        auto idxIt = runtime.stringLiteralIndexForOp.find(op.getOperation());
        assert(idxIt != runtime.stringLiteralIndexForOp.end() &&
               "string-literal global not pre-materialized");
        std::string globalName = "__eco_str_" + std::to_string(idxIt->second);
        auto addrOf = rewriter.create<LLVM::AddressOfOp>(loc, ptrTy, globalName);

        // ASCII: [N x i8] global -> inline UTF-8 leaf. byteLen == char count.
        if (isAsciiLiteral(value)) {
            auto func = runtime.getOrCreateAllocStringLiteralUtf8(rewriter);
            auto lenVal = rewriter.create<LLVM::ConstantOp>(loc, i32Ty,
                static_cast<int32_t>(value.size()));
            auto call = rewriter.create<LLVM::CallOp>(loc, func,
                ValueRange{addrOf, lenVal});
            rewriter.replaceOp(op, call.getResult());
            return success();
        }

        // Non-ASCII: [N x i16] global -> UTF-16 leaf. length is the unit count.
        std::vector<uint16_t> utf16 = utf8ToUtf16(value);
        size_t length = utf16.size();
        auto func = runtime.getOrCreateAllocStringLiteral(rewriter);
        auto lengthVal = rewriter.create<LLVM::ConstantOp>(loc, i32Ty,
            static_cast<int32_t>(length));
        auto call = rewriter.create<LLVM::CallOp>(loc, func,
            ValueRange{addrOf, lengthVal});

        rewriter.replaceOp(op, call.getResult());
        return success();
    }
};

} // namespace

//===----------------------------------------------------------------------===//
// Pattern Population
//===----------------------------------------------------------------------===//

void eco::detail::populateEcoTypePatterns(
    EcoTypeConverter &typeConverter,
    RewritePatternSet &patterns,
    const EcoRuntime &runtime) {

    auto *ctx = patterns.getContext();
    patterns.add<ConstantOpLowering>(typeConverter, ctx);
    patterns.add<StringLiteralOpLowering>(typeConverter, ctx, runtime);
}

// Phase-2 pre-materialization: walk StringLiteralOps in module program order,
// assign each a deterministic index N (matching the legacy on-demand counter
// sequence), create its __eco_str_N global, and record the index in the side
// map read by StringLiteralOpLowering during the (parallel) body stage.
void eco::detail::preMaterializeStringLiterals(
    OpBuilder &builder, const EcoRuntime &runtime,
    llvm::ArrayRef<LLVM::LLVMFuncOp> funcs) {
    auto *ctx = builder.getContext();
    auto i16Ty = IntegerType::get(ctx, 16);
    auto i8Ty = IntegerType::get(ctx, 8);
    for (LLVM::LLVMFuncOp func : funcs) {
        func.walk([&](StringLiteralOp op) {
            StringRef value = op.getValue();
            if (value.empty())
                return;  // empty string is an embedded constant; no global
            uint64_t index = runtime.stringLiteralCounter++;  // sole bump site
            runtime.stringLiteralIndexForOp[op.getOperation()] = index;
            std::string globalName = "__eco_str_" + std::to_string(index);
            OpBuilder::InsertionGuard guard(builder);
            builder.setInsertionPointToStart(runtime.module.getBody());

            if (isAsciiLiteral(value)) {
                // ASCII -> [N x i8] of the raw bytes (consumed as a UTF-8 leaf).
                size_t byteLen = value.size();
                auto arrayTy = LLVM::LLVMArrayType::get(i8Ty, byteLen);
                auto globalOp = builder.create<LLVM::GlobalOp>(
                    op.getLoc(), arrayTy, /*isConstant=*/true,
                    LLVM::Linkage::Internal, globalName, Attribute{});
                Block *initBlock =
                    builder.createBlock(&globalOp.getInitializerRegion());
                builder.setInsertionPointToStart(initBlock);
                SmallVector<int8_t> byteValues;
                for (char c : value) byteValues.push_back(static_cast<int8_t>(c));
                auto denseAttr = DenseElementsAttr::get(
                    RankedTensorType::get({static_cast<int64_t>(byteLen)}, i8Ty),
                    ArrayRef<int8_t>(byteValues));
                Value arrayVal = builder.create<LLVM::ConstantOp>(
                    op.getLoc(), arrayTy, denseAttr);
                builder.create<LLVM::ReturnOp>(op.getLoc(), arrayVal);
                return;
            }

            std::vector<uint16_t> utf16 = utf8ToUtf16(value);
            size_t length = utf16.size();
            auto arrayTy = LLVM::LLVMArrayType::get(i16Ty, length);
            auto globalOp = builder.create<LLVM::GlobalOp>(
                op.getLoc(), arrayTy, /*isConstant=*/true,
                LLVM::Linkage::Internal, globalName, Attribute{});
            Block *initBlock =
                builder.createBlock(&globalOp.getInitializerRegion());
            builder.setInsertionPointToStart(initBlock);
            SmallVector<int16_t> charValues;
            for (uint16_t c : utf16) charValues.push_back(static_cast<int16_t>(c));
            auto denseAttr = DenseElementsAttr::get(
                RankedTensorType::get({static_cast<int64_t>(length)}, i16Ty),
                ArrayRef<int16_t>(charValues));
            Value arrayVal =
                builder.create<LLVM::ConstantOp>(op.getLoc(), arrayTy, denseAttr);
            builder.create<LLVM::ReturnOp>(op.getLoc(), arrayVal);
        });
    }
}
