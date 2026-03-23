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

        // Get the constant kind and encode it in the HPointer format.
        // The ConstantKind enum values are 1-based, matching the HPointer encoding.
        int64_t kindValue = static_cast<int64_t>(op.getKind());
        int64_t encoded = value_enc::encodeConstant(kindValue);

        auto result = rewriter.create<LLVM::ConstantOp>(loc, i64Ty, encoded);
        rewriter.replaceOp(op, result);
        return success();
    }
};

//===----------------------------------------------------------------------===//
// eco.string_literal -> call eco_alloc_string_literal
//===----------------------------------------------------------------------===//

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

        // Empty string -> use embedded constant
        if (value.empty()) {
            int64_t encoded = value_enc::encodeConstant(value_enc::EmptyString);
            auto result = rewriter.create<LLVM::ConstantOp>(loc, i64Ty, encoded);
            rewriter.replaceOp(op, result);
            return success();
        }

        // Convert UTF-8 to UTF-16
        std::vector<uint16_t> utf16 = utf8ToUtf16(value);
        size_t length = utf16.size();

        // Create global array of UTF-16 characters
        auto arrayTy = LLVM::LLVMArrayType::get(i16Ty, length);

        // Generate unique global name
        static int stringCounter = 0;
        std::string globalName = "__eco_str_" + std::to_string(stringCounter++);

        // Create the global constant for the UTF-16 characters
        {
            OpBuilder::InsertionGuard guard(rewriter);
            rewriter.setInsertionPointToStart(runtime.module.getBody());

            auto globalOp = rewriter.create<LLVM::GlobalOp>(
                loc, arrayTy, /*isConstant=*/true,
                LLVM::Linkage::Internal, globalName,
                Attribute{});

            // Initialize with array value
            Block *initBlock = rewriter.createBlock(&globalOp.getInitializerRegion());
            rewriter.setInsertionPointToStart(initBlock);

            SmallVector<int16_t> charValues;
            for (uint16_t c : utf16) {
                charValues.push_back(static_cast<int16_t>(c));
            }
            auto denseAttr = DenseElementsAttr::get(
                RankedTensorType::get({static_cast<int64_t>(length)}, i16Ty),
                ArrayRef<int16_t>(charValues));
            Value arrayVal = rewriter.create<LLVM::ConstantOp>(loc, arrayTy, denseAttr);

            rewriter.create<LLVM::ReturnOp>(loc, arrayVal);
        }

        // Get address of global chars array
        auto addrOf = rewriter.create<LLVM::AddressOfOp>(loc, ptrTy, globalName);

        // Call eco_alloc_string_literal(chars, length) -> HPointer
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
