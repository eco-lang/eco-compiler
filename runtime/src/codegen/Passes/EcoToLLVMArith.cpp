//===- EcoToLLVMArith.cpp - Arithmetic lowering patterns ------------------===//
//
// This file implements lowering patterns for ECO arithmetic, comparison,
// bitwise, boolean, character, and type conversion operations.
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
// Integer Arithmetic
//===----------------------------------------------------------------------===//

struct IntAddOpLowering : public OpConversionPattern<IntAddOp> {
    using OpConversionPattern::OpConversionPattern;

    LogicalResult
    matchAndRewrite(IntAddOp op, OpAdaptor adaptor,
                    ConversionPatternRewriter &rewriter) const override {
        rewriter.replaceOpWithNewOp<arith::AddIOp>(op, adaptor.getLhs(), adaptor.getRhs());
        return success();
    }
};

struct IntSubOpLowering : public OpConversionPattern<IntSubOp> {
    using OpConversionPattern::OpConversionPattern;

    LogicalResult
    matchAndRewrite(IntSubOp op, OpAdaptor adaptor,
                    ConversionPatternRewriter &rewriter) const override {
        rewriter.replaceOpWithNewOp<arith::SubIOp>(op, adaptor.getLhs(), adaptor.getRhs());
        return success();
    }
};

struct IntMulOpLowering : public OpConversionPattern<IntMulOp> {
    using OpConversionPattern::OpConversionPattern;

    LogicalResult
    matchAndRewrite(IntMulOp op, OpAdaptor adaptor,
                    ConversionPatternRewriter &rewriter) const override {
        rewriter.replaceOpWithNewOp<arith::MulIOp>(op, adaptor.getLhs(), adaptor.getRhs());
        return success();
    }
};

struct IntDivOpLowering : public OpConversionPattern<IntDivOp> {
    using OpConversionPattern::OpConversionPattern;

    LogicalResult
    matchAndRewrite(IntDivOp op, OpAdaptor adaptor,
                    ConversionPatternRewriter &rewriter) const override {
        auto loc = op.getLoc();
        auto *ctx = rewriter.getContext();
        auto i64Ty = IntegerType::get(ctx, 64);

        Value lhs = adaptor.getLhs();
        Value rhs = adaptor.getRhs();

        // Guard against division by zero: return 0 if rhs == 0
        auto zero = rewriter.create<arith::ConstantIntOp>(loc, 0, /*width=*/64);
        auto isZero = rewriter.create<arith::CmpIOp>(loc, arith::CmpIPredicate::eq,
                                                      rhs, zero);
        auto safeRhs = rewriter.create<arith::SelectOp>(loc, isZero,
            rewriter.create<arith::ConstantIntOp>(loc, 1, /*width=*/64), rhs);

        auto divResult = rewriter.create<arith::DivSIOp>(loc, lhs, safeRhs);
        auto result = rewriter.create<arith::SelectOp>(loc, isZero, zero, divResult);

        rewriter.replaceOp(op, result);
        return success();
    }
};

struct IntModByOpLowering : public OpConversionPattern<IntModByOp> {
    using OpConversionPattern::OpConversionPattern;

    LogicalResult
    matchAndRewrite(IntModByOp op, OpAdaptor adaptor,
                    ConversionPatternRewriter &rewriter) const override {
        auto loc = op.getLoc();
        auto *ctx = rewriter.getContext();
        auto i64Ty = IntegerType::get(ctx, 64);

        Value modulus = adaptor.getModulus();
        Value x = adaptor.getX();

        // Elm's modBy implements floored division modulo:
        // modBy b a = a - (floor(a/b)) * b
        //
        // This differs from C's % (truncated) for negative numbers.
        // Example: modBy 3 (-5) = 1 in Elm, but (-5) % 3 = -2 in C
        //
        // Implementation: r = a % b; if (r != 0 && (r ^ b) < 0) r += b;

        auto zero = rewriter.create<arith::ConstantIntOp>(loc, 0, /*width=*/64);

        // Guard against div by zero
        auto isZero = rewriter.create<arith::CmpIOp>(loc, arith::CmpIPredicate::eq,
                                                      modulus, zero);
        auto safeModulus = rewriter.create<arith::SelectOp>(loc, isZero,
            rewriter.create<arith::ConstantIntOp>(loc, 1, /*width=*/64), modulus);

        // Compute truncated remainder
        auto truncRem = rewriter.create<arith::RemSIOp>(loc, x, safeModulus);

        // Check if signs differ and remainder is non-zero
        auto remIsNonZero = rewriter.create<arith::CmpIOp>(loc, arith::CmpIPredicate::ne,
                                                            truncRem, zero);
        auto xorVal = rewriter.create<arith::XOrIOp>(loc, truncRem, safeModulus);
        auto signsDiffer = rewriter.create<arith::CmpIOp>(loc, arith::CmpIPredicate::slt,
                                                           xorVal, zero);
        auto needsAdjust = rewriter.create<arith::AndIOp>(loc, remIsNonZero, signsDiffer);

        // Adjust by adding modulus if needed
        auto adjusted = rewriter.create<arith::AddIOp>(loc, truncRem, safeModulus);
        auto flooredRem = rewriter.create<arith::SelectOp>(loc, needsAdjust, adjusted, truncRem);

        // Return 0 if modulus was 0
        auto result = rewriter.create<arith::SelectOp>(loc, isZero, zero, flooredRem);

        rewriter.replaceOp(op, result);
        return success();
    }
};

struct IntRemainderByOpLowering : public OpConversionPattern<IntRemainderByOp> {
    using OpConversionPattern::OpConversionPattern;

    LogicalResult
    matchAndRewrite(IntRemainderByOp op, OpAdaptor adaptor,
                    ConversionPatternRewriter &rewriter) const override {
        auto loc = op.getLoc();

        Value divisor = adaptor.getDivisor();
        Value x = adaptor.getX();

        // Guard against division by zero
        auto zero = rewriter.create<arith::ConstantIntOp>(loc, 0, /*width=*/64);
        auto isZero = rewriter.create<arith::CmpIOp>(loc, arith::CmpIPredicate::eq,
                                                      divisor, zero);
        auto safeDivisor = rewriter.create<arith::SelectOp>(loc, isZero,
            rewriter.create<arith::ConstantIntOp>(loc, 1, /*width=*/64), divisor);

        auto remResult = rewriter.create<arith::RemSIOp>(loc, x, safeDivisor);
        auto result = rewriter.create<arith::SelectOp>(loc, isZero, zero, remResult);

        rewriter.replaceOp(op, result);
        return success();
    }
};

struct IntNegateOpLowering : public OpConversionPattern<IntNegateOp> {
    using OpConversionPattern::OpConversionPattern;

    LogicalResult
    matchAndRewrite(IntNegateOp op, OpAdaptor adaptor,
                    ConversionPatternRewriter &rewriter) const override {
        auto loc = op.getLoc();
        auto zero = rewriter.create<arith::ConstantIntOp>(loc, 0, /*width=*/64);
        rewriter.replaceOpWithNewOp<arith::SubIOp>(op, zero, adaptor.getValue());
        return success();
    }
};

struct IntAbsOpLowering : public OpConversionPattern<IntAbsOp> {
    using OpConversionPattern::OpConversionPattern;

    LogicalResult
    matchAndRewrite(IntAbsOp op, OpAdaptor adaptor,
                    ConversionPatternRewriter &rewriter) const override {
        auto loc = op.getLoc();
        Value x = adaptor.getValue();

        auto zero = rewriter.create<arith::ConstantIntOp>(loc, 0, /*width=*/64);
        auto isNeg = rewriter.create<arith::CmpIOp>(loc, arith::CmpIPredicate::slt, x, zero);
        auto negX = rewriter.create<arith::SubIOp>(loc, zero, x);
        rewriter.replaceOpWithNewOp<arith::SelectOp>(op, isNeg, negX, x);
        return success();
    }
};

struct IntPowOpLowering : public OpConversionPattern<IntPowOp> {
    EcoRuntime runtime;

    IntPowOpLowering(EcoTypeConverter &typeConverter, MLIRContext *ctx,
                     EcoRuntime runtime)
        : OpConversionPattern(typeConverter, ctx), runtime(runtime) {}

    LogicalResult
    matchAndRewrite(IntPowOp op, OpAdaptor adaptor,
                    ConversionPatternRewriter &rewriter) const override {
        auto loc = op.getLoc();
        auto *ctx = rewriter.getContext();
        auto i64Ty = IntegerType::get(ctx, 64);

        auto func = runtime.getOrCreateIntPow(rewriter);
        auto call = rewriter.create<LLVM::CallOp>(loc, func,
            ValueRange{adaptor.getBase(), adaptor.getExp()});
        rewriter.replaceOp(op, call.getResult());
        return success();
    }
};

//===----------------------------------------------------------------------===//
// Float Arithmetic
//===----------------------------------------------------------------------===//

struct FloatAddOpLowering : public OpConversionPattern<FloatAddOp> {
    using OpConversionPattern::OpConversionPattern;

    LogicalResult
    matchAndRewrite(FloatAddOp op, OpAdaptor adaptor,
                    ConversionPatternRewriter &rewriter) const override {
        rewriter.replaceOpWithNewOp<arith::AddFOp>(op, adaptor.getLhs(), adaptor.getRhs());
        return success();
    }
};

struct FloatSubOpLowering : public OpConversionPattern<FloatSubOp> {
    using OpConversionPattern::OpConversionPattern;

    LogicalResult
    matchAndRewrite(FloatSubOp op, OpAdaptor adaptor,
                    ConversionPatternRewriter &rewriter) const override {
        rewriter.replaceOpWithNewOp<arith::SubFOp>(op, adaptor.getLhs(), adaptor.getRhs());
        return success();
    }
};

struct FloatMulOpLowering : public OpConversionPattern<FloatMulOp> {
    using OpConversionPattern::OpConversionPattern;

    LogicalResult
    matchAndRewrite(FloatMulOp op, OpAdaptor adaptor,
                    ConversionPatternRewriter &rewriter) const override {
        rewriter.replaceOpWithNewOp<arith::MulFOp>(op, adaptor.getLhs(), adaptor.getRhs());
        return success();
    }
};

struct FloatDivOpLowering : public OpConversionPattern<FloatDivOp> {
    using OpConversionPattern::OpConversionPattern;

    LogicalResult
    matchAndRewrite(FloatDivOp op, OpAdaptor adaptor,
                    ConversionPatternRewriter &rewriter) const override {
        // IEEE 754 handles div by zero (returns Inf or NaN)
        rewriter.replaceOpWithNewOp<arith::DivFOp>(op, adaptor.getLhs(), adaptor.getRhs());
        return success();
    }
};

struct FloatNegateOpLowering : public OpConversionPattern<FloatNegateOp> {
    using OpConversionPattern::OpConversionPattern;

    LogicalResult
    matchAndRewrite(FloatNegateOp op, OpAdaptor adaptor,
                    ConversionPatternRewriter &rewriter) const override {
        rewriter.replaceOpWithNewOp<arith::NegFOp>(op, adaptor.getValue());
        return success();
    }
};

struct FloatAbsOpLowering : public OpConversionPattern<FloatAbsOp> {
    using OpConversionPattern::OpConversionPattern;

    LogicalResult
    matchAndRewrite(FloatAbsOp op, OpAdaptor adaptor,
                    ConversionPatternRewriter &rewriter) const override {
        rewriter.replaceOpWithNewOp<LLVM::FAbsOp>(op, adaptor.getValue());
        return success();
    }
};

struct FloatPowOpLowering : public OpConversionPattern<FloatPowOp> {
    using OpConversionPattern::OpConversionPattern;

    LogicalResult
    matchAndRewrite(FloatPowOp op, OpAdaptor adaptor,
                    ConversionPatternRewriter &rewriter) const override {
        rewriter.replaceOpWithNewOp<LLVM::PowOp>(op, adaptor.getBase(), adaptor.getExp());
        return success();
    }
};

struct FloatSqrtOpLowering : public OpConversionPattern<FloatSqrtOp> {
    using OpConversionPattern::OpConversionPattern;

    LogicalResult
    matchAndRewrite(FloatSqrtOp op, OpAdaptor adaptor,
                    ConversionPatternRewriter &rewriter) const override {
        rewriter.replaceOpWithNewOp<LLVM::SqrtOp>(op, adaptor.getValue());
        return success();
    }
};

struct FloatSinOpLowering : public OpConversionPattern<FloatSinOp> {
    using OpConversionPattern::OpConversionPattern;

    LogicalResult
    matchAndRewrite(FloatSinOp op, OpAdaptor adaptor,
                    ConversionPatternRewriter &rewriter) const override {
        rewriter.replaceOpWithNewOp<LLVM::SinOp>(op, adaptor.getValue());
        return success();
    }
};

struct FloatCosOpLowering : public OpConversionPattern<FloatCosOp> {
    using OpConversionPattern::OpConversionPattern;

    LogicalResult
    matchAndRewrite(FloatCosOp op, OpAdaptor adaptor,
                    ConversionPatternRewriter &rewriter) const override {
        rewriter.replaceOpWithNewOp<LLVM::CosOp>(op, adaptor.getValue());
        return success();
    }
};

struct FloatTanOpLowering : public OpConversionPattern<FloatTanOp> {
    using OpConversionPattern::OpConversionPattern;

    LogicalResult
    matchAndRewrite(FloatTanOp op, OpAdaptor adaptor,
                    ConversionPatternRewriter &rewriter) const override {
        auto loc = op.getLoc();
        Value x = adaptor.getValue();
        auto sinX = rewriter.create<LLVM::SinOp>(loc, x);
        auto cosX = rewriter.create<LLVM::CosOp>(loc, x);
        rewriter.replaceOpWithNewOp<arith::DivFOp>(op, sinX, cosX);
        return success();
    }
};

struct FloatAsinOpLowering : public OpConversionPattern<FloatAsinOp> {
    EcoRuntime runtime;

    FloatAsinOpLowering(EcoTypeConverter &typeConverter, MLIRContext *ctx,
                        EcoRuntime runtime)
        : OpConversionPattern(typeConverter, ctx), runtime(runtime) {}

    LogicalResult
    matchAndRewrite(FloatAsinOp op, OpAdaptor adaptor,
                    ConversionPatternRewriter &rewriter) const override {
        auto loc = op.getLoc();
        auto func = runtime.getOrCreateAsin(rewriter);
        auto call = rewriter.create<LLVM::CallOp>(loc, func, ValueRange{adaptor.getValue()});
        rewriter.replaceOp(op, call.getResult());
        return success();
    }
};

struct FloatAcosOpLowering : public OpConversionPattern<FloatAcosOp> {
    EcoRuntime runtime;

    FloatAcosOpLowering(EcoTypeConverter &typeConverter, MLIRContext *ctx,
                        EcoRuntime runtime)
        : OpConversionPattern(typeConverter, ctx), runtime(runtime) {}

    LogicalResult
    matchAndRewrite(FloatAcosOp op, OpAdaptor adaptor,
                    ConversionPatternRewriter &rewriter) const override {
        auto loc = op.getLoc();
        auto func = runtime.getOrCreateAcos(rewriter);
        auto call = rewriter.create<LLVM::CallOp>(loc, func, ValueRange{adaptor.getValue()});
        rewriter.replaceOp(op, call.getResult());
        return success();
    }
};

struct FloatAtanOpLowering : public OpConversionPattern<FloatAtanOp> {
    EcoRuntime runtime;

    FloatAtanOpLowering(EcoTypeConverter &typeConverter, MLIRContext *ctx,
                        EcoRuntime runtime)
        : OpConversionPattern(typeConverter, ctx), runtime(runtime) {}

    LogicalResult
    matchAndRewrite(FloatAtanOp op, OpAdaptor adaptor,
                    ConversionPatternRewriter &rewriter) const override {
        auto loc = op.getLoc();
        auto func = runtime.getOrCreateAtan(rewriter);
        auto call = rewriter.create<LLVM::CallOp>(loc, func, ValueRange{adaptor.getValue()});
        rewriter.replaceOp(op, call.getResult());
        return success();
    }
};

struct FloatAtan2OpLowering : public OpConversionPattern<FloatAtan2Op> {
    EcoRuntime runtime;

    FloatAtan2OpLowering(EcoTypeConverter &typeConverter, MLIRContext *ctx,
                         EcoRuntime runtime)
        : OpConversionPattern(typeConverter, ctx), runtime(runtime) {}

    LogicalResult
    matchAndRewrite(FloatAtan2Op op, OpAdaptor adaptor,
                    ConversionPatternRewriter &rewriter) const override {
        auto loc = op.getLoc();
        auto func = runtime.getOrCreateAtan2(rewriter);
        auto call = rewriter.create<LLVM::CallOp>(loc, func,
            ValueRange{adaptor.getY(), adaptor.getX()});
        rewriter.replaceOp(op, call.getResult());
        return success();
    }
};

struct FloatLogOpLowering : public OpConversionPattern<FloatLogOp> {
    using OpConversionPattern::OpConversionPattern;

    LogicalResult
    matchAndRewrite(FloatLogOp op, OpAdaptor adaptor,
                    ConversionPatternRewriter &rewriter) const override {
        rewriter.replaceOpWithNewOp<LLVM::LogOp>(op, adaptor.getValue());
        return success();
    }
};

struct FloatIsNaNOpLowering : public OpConversionPattern<FloatIsNaNOp> {
    using OpConversionPattern::OpConversionPattern;

    LogicalResult
    matchAndRewrite(FloatIsNaNOp op, OpAdaptor adaptor,
                    ConversionPatternRewriter &rewriter) const override {
        // x != x is true only for NaN
        rewriter.replaceOpWithNewOp<arith::CmpFOp>(op, arith::CmpFPredicate::UNO,
                                                    adaptor.getValue(), adaptor.getValue());
        return success();
    }
};

struct FloatIsInfiniteOpLowering : public OpConversionPattern<FloatIsInfiniteOp> {
    using OpConversionPattern::OpConversionPattern;

    LogicalResult
    matchAndRewrite(FloatIsInfiniteOp op, OpAdaptor adaptor,
                    ConversionPatternRewriter &rewriter) const override {
        auto loc = op.getLoc();
        auto *ctx = rewriter.getContext();
        auto f64Ty = Float64Type::get(ctx);

        Value x = adaptor.getValue();
        auto absX = rewriter.create<LLVM::FAbsOp>(loc, x);
        auto inf = rewriter.create<arith::ConstantOp>(loc, f64Ty,
            rewriter.getF64FloatAttr(std::numeric_limits<double>::infinity()));
        rewriter.replaceOpWithNewOp<arith::CmpFOp>(op, arith::CmpFPredicate::OEQ, absX, inf);
        return success();
    }
};

//===----------------------------------------------------------------------===//
// Type Conversions
//===----------------------------------------------------------------------===//

struct IntToFloatOpLowering : public OpConversionPattern<IntToFloatOp> {
    using OpConversionPattern::OpConversionPattern;

    LogicalResult
    matchAndRewrite(IntToFloatOp op, OpAdaptor adaptor,
                    ConversionPatternRewriter &rewriter) const override {
        auto *ctx = rewriter.getContext();
        auto f64Ty = Float64Type::get(ctx);
        rewriter.replaceOpWithNewOp<arith::SIToFPOp>(op, f64Ty, adaptor.getValue());
        return success();
    }
};

struct FloatRoundOpLowering : public OpConversionPattern<FloatRoundOp> {
    using OpConversionPattern::OpConversionPattern;

    LogicalResult
    matchAndRewrite(FloatRoundOp op, OpAdaptor adaptor,
                    ConversionPatternRewriter &rewriter) const override {
        auto loc = op.getLoc();
        auto *ctx = rewriter.getContext();
        auto i64Ty = IntegerType::get(ctx, 64);

        auto rounded = rewriter.create<LLVM::RoundOp>(loc, adaptor.getValue());
        rewriter.replaceOpWithNewOp<arith::FPToSIOp>(op, i64Ty, rounded);
        return success();
    }
};

struct FloatFloorOpLowering : public OpConversionPattern<FloatFloorOp> {
    using OpConversionPattern::OpConversionPattern;

    LogicalResult
    matchAndRewrite(FloatFloorOp op, OpAdaptor adaptor,
                    ConversionPatternRewriter &rewriter) const override {
        auto loc = op.getLoc();
        auto *ctx = rewriter.getContext();
        auto i64Ty = IntegerType::get(ctx, 64);

        auto floored = rewriter.create<LLVM::FFloorOp>(loc, adaptor.getValue());
        rewriter.replaceOpWithNewOp<arith::FPToSIOp>(op, i64Ty, floored);
        return success();
    }
};

struct FloatCeilingOpLowering : public OpConversionPattern<FloatCeilingOp> {
    using OpConversionPattern::OpConversionPattern;

    LogicalResult
    matchAndRewrite(FloatCeilingOp op, OpAdaptor adaptor,
                    ConversionPatternRewriter &rewriter) const override {
        auto loc = op.getLoc();
        auto *ctx = rewriter.getContext();
        auto i64Ty = IntegerType::get(ctx, 64);

        auto ceiled = rewriter.create<LLVM::FCeilOp>(loc, adaptor.getValue());
        rewriter.replaceOpWithNewOp<arith::FPToSIOp>(op, i64Ty, ceiled);
        return success();
    }
};

struct FloatTruncateOpLowering : public OpConversionPattern<FloatTruncateOp> {
    using OpConversionPattern::OpConversionPattern;

    LogicalResult
    matchAndRewrite(FloatTruncateOp op, OpAdaptor adaptor,
                    ConversionPatternRewriter &rewriter) const override {
        auto *ctx = rewriter.getContext();
        auto i64Ty = IntegerType::get(ctx, 64);
        // FPToSIOp inherently truncates toward zero
        rewriter.replaceOpWithNewOp<arith::FPToSIOp>(op, i64Ty, adaptor.getValue());
        return success();
    }
};

//===----------------------------------------------------------------------===//
// Integer Comparisons
//===----------------------------------------------------------------------===//

struct IntLtOpLowering : public OpConversionPattern<IntLtOp> {
    using OpConversionPattern::OpConversionPattern;

    LogicalResult
    matchAndRewrite(IntLtOp op, OpAdaptor adaptor,
                    ConversionPatternRewriter &rewriter) const override {
        rewriter.replaceOpWithNewOp<arith::CmpIOp>(
            op, arith::CmpIPredicate::slt, adaptor.getLhs(), adaptor.getRhs());
        return success();
    }
};

struct IntLeOpLowering : public OpConversionPattern<IntLeOp> {
    using OpConversionPattern::OpConversionPattern;

    LogicalResult
    matchAndRewrite(IntLeOp op, OpAdaptor adaptor,
                    ConversionPatternRewriter &rewriter) const override {
        rewriter.replaceOpWithNewOp<arith::CmpIOp>(
            op, arith::CmpIPredicate::sle, adaptor.getLhs(), adaptor.getRhs());
        return success();
    }
};

struct IntGtOpLowering : public OpConversionPattern<IntGtOp> {
    using OpConversionPattern::OpConversionPattern;

    LogicalResult
    matchAndRewrite(IntGtOp op, OpAdaptor adaptor,
                    ConversionPatternRewriter &rewriter) const override {
        rewriter.replaceOpWithNewOp<arith::CmpIOp>(
            op, arith::CmpIPredicate::sgt, adaptor.getLhs(), adaptor.getRhs());
        return success();
    }
};

struct IntGeOpLowering : public OpConversionPattern<IntGeOp> {
    using OpConversionPattern::OpConversionPattern;

    LogicalResult
    matchAndRewrite(IntGeOp op, OpAdaptor adaptor,
                    ConversionPatternRewriter &rewriter) const override {
        rewriter.replaceOpWithNewOp<arith::CmpIOp>(
            op, arith::CmpIPredicate::sge, adaptor.getLhs(), adaptor.getRhs());
        return success();
    }
};

struct IntEqOpLowering : public OpConversionPattern<IntEqOp> {
    using OpConversionPattern::OpConversionPattern;

    LogicalResult
    matchAndRewrite(IntEqOp op, OpAdaptor adaptor,
                    ConversionPatternRewriter &rewriter) const override {
        rewriter.replaceOpWithNewOp<arith::CmpIOp>(
            op, arith::CmpIPredicate::eq, adaptor.getLhs(), adaptor.getRhs());
        return success();
    }
};

struct IntNeOpLowering : public OpConversionPattern<IntNeOp> {
    using OpConversionPattern::OpConversionPattern;

    LogicalResult
    matchAndRewrite(IntNeOp op, OpAdaptor adaptor,
                    ConversionPatternRewriter &rewriter) const override {
        rewriter.replaceOpWithNewOp<arith::CmpIOp>(
            op, arith::CmpIPredicate::ne, adaptor.getLhs(), adaptor.getRhs());
        return success();
    }
};

//===----------------------------------------------------------------------===//
// Float Comparisons
//===----------------------------------------------------------------------===//

struct FloatLtOpLowering : public OpConversionPattern<FloatLtOp> {
    using OpConversionPattern::OpConversionPattern;

    LogicalResult
    matchAndRewrite(FloatLtOp op, OpAdaptor adaptor,
                    ConversionPatternRewriter &rewriter) const override {
        rewriter.replaceOpWithNewOp<arith::CmpFOp>(
            op, arith::CmpFPredicate::OLT, adaptor.getLhs(), adaptor.getRhs());
        return success();
    }
};

struct FloatLeOpLowering : public OpConversionPattern<FloatLeOp> {
    using OpConversionPattern::OpConversionPattern;

    LogicalResult
    matchAndRewrite(FloatLeOp op, OpAdaptor adaptor,
                    ConversionPatternRewriter &rewriter) const override {
        rewriter.replaceOpWithNewOp<arith::CmpFOp>(
            op, arith::CmpFPredicate::OLE, adaptor.getLhs(), adaptor.getRhs());
        return success();
    }
};

struct FloatGtOpLowering : public OpConversionPattern<FloatGtOp> {
    using OpConversionPattern::OpConversionPattern;

    LogicalResult
    matchAndRewrite(FloatGtOp op, OpAdaptor adaptor,
                    ConversionPatternRewriter &rewriter) const override {
        rewriter.replaceOpWithNewOp<arith::CmpFOp>(
            op, arith::CmpFPredicate::OGT, adaptor.getLhs(), adaptor.getRhs());
        return success();
    }
};

struct FloatGeOpLowering : public OpConversionPattern<FloatGeOp> {
    using OpConversionPattern::OpConversionPattern;

    LogicalResult
    matchAndRewrite(FloatGeOp op, OpAdaptor adaptor,
                    ConversionPatternRewriter &rewriter) const override {
        rewriter.replaceOpWithNewOp<arith::CmpFOp>(
            op, arith::CmpFPredicate::OGE, adaptor.getLhs(), adaptor.getRhs());
        return success();
    }
};

struct FloatEqOpLowering : public OpConversionPattern<FloatEqOp> {
    using OpConversionPattern::OpConversionPattern;

    LogicalResult
    matchAndRewrite(FloatEqOp op, OpAdaptor adaptor,
                    ConversionPatternRewriter &rewriter) const override {
        rewriter.replaceOpWithNewOp<arith::CmpFOp>(
            op, arith::CmpFPredicate::OEQ, adaptor.getLhs(), adaptor.getRhs());
        return success();
    }
};

struct FloatNeOpLowering : public OpConversionPattern<FloatNeOp> {
    using OpConversionPattern::OpConversionPattern;

    LogicalResult
    matchAndRewrite(FloatNeOp op, OpAdaptor adaptor,
                    ConversionPatternRewriter &rewriter) const override {
        rewriter.replaceOpWithNewOp<arith::CmpFOp>(
            op, arith::CmpFPredicate::ONE, adaptor.getLhs(), adaptor.getRhs());
        return success();
    }
};

//===----------------------------------------------------------------------===//
// Min/Max Operations
//===----------------------------------------------------------------------===//

struct IntMinOpLowering : public OpConversionPattern<IntMinOp> {
    using OpConversionPattern::OpConversionPattern;

    LogicalResult
    matchAndRewrite(IntMinOp op, OpAdaptor adaptor,
                    ConversionPatternRewriter &rewriter) const override {
        rewriter.replaceOpWithNewOp<arith::MinSIOp>(op, adaptor.getLhs(), adaptor.getRhs());
        return success();
    }
};

struct IntMaxOpLowering : public OpConversionPattern<IntMaxOp> {
    using OpConversionPattern::OpConversionPattern;

    LogicalResult
    matchAndRewrite(IntMaxOp op, OpAdaptor adaptor,
                    ConversionPatternRewriter &rewriter) const override {
        rewriter.replaceOpWithNewOp<arith::MaxSIOp>(op, adaptor.getLhs(), adaptor.getRhs());
        return success();
    }
};

struct FloatMinOpLowering : public OpConversionPattern<FloatMinOp> {
    using OpConversionPattern::OpConversionPattern;

    LogicalResult
    matchAndRewrite(FloatMinOp op, OpAdaptor adaptor,
                    ConversionPatternRewriter &rewriter) const override {
        rewriter.replaceOpWithNewOp<LLVM::MinNumOp>(op, adaptor.getLhs(), adaptor.getRhs());
        return success();
    }
};

struct FloatMaxOpLowering : public OpConversionPattern<FloatMaxOp> {
    using OpConversionPattern::OpConversionPattern;

    LogicalResult
    matchAndRewrite(FloatMaxOp op, OpAdaptor adaptor,
                    ConversionPatternRewriter &rewriter) const override {
        rewriter.replaceOpWithNewOp<LLVM::MaxNumOp>(op, adaptor.getLhs(), adaptor.getRhs());
        return success();
    }
};

//===----------------------------------------------------------------------===//
// Bitwise Operations
//===----------------------------------------------------------------------===//

struct IntAndOpLowering : public OpConversionPattern<IntAndOp> {
    using OpConversionPattern::OpConversionPattern;

    LogicalResult
    matchAndRewrite(IntAndOp op, OpAdaptor adaptor,
                    ConversionPatternRewriter &rewriter) const override {
        rewriter.replaceOpWithNewOp<arith::AndIOp>(op, adaptor.getLhs(), adaptor.getRhs());
        return success();
    }
};

struct IntOrOpLowering : public OpConversionPattern<IntOrOp> {
    using OpConversionPattern::OpConversionPattern;

    LogicalResult
    matchAndRewrite(IntOrOp op, OpAdaptor adaptor,
                    ConversionPatternRewriter &rewriter) const override {
        rewriter.replaceOpWithNewOp<arith::OrIOp>(op, adaptor.getLhs(), adaptor.getRhs());
        return success();
    }
};

struct IntXorOpLowering : public OpConversionPattern<IntXorOp> {
    using OpConversionPattern::OpConversionPattern;

    LogicalResult
    matchAndRewrite(IntXorOp op, OpAdaptor adaptor,
                    ConversionPatternRewriter &rewriter) const override {
        rewriter.replaceOpWithNewOp<arith::XOrIOp>(op, adaptor.getLhs(), adaptor.getRhs());
        return success();
    }
};

struct IntComplementOpLowering : public OpConversionPattern<IntComplementOp> {
    using OpConversionPattern::OpConversionPattern;

    LogicalResult
    matchAndRewrite(IntComplementOp op, OpAdaptor adaptor,
                    ConversionPatternRewriter &rewriter) const override {
        auto loc = op.getLoc();
        auto *ctx = rewriter.getContext();
        auto i64Ty = IntegerType::get(ctx, 64);

        // complement(x) = x XOR -1 (all bits set)
        auto allOnes = rewriter.create<arith::ConstantIntOp>(loc, -1, /*width=*/64);
        rewriter.replaceOpWithNewOp<arith::XOrIOp>(op, adaptor.getValue(), allOnes);
        return success();
    }
};

struct IntShiftLeftOpLowering : public OpConversionPattern<IntShiftLeftOp> {
    using OpConversionPattern::OpConversionPattern;

    LogicalResult
    matchAndRewrite(IntShiftLeftOp op, OpAdaptor adaptor,
                    ConversionPatternRewriter &rewriter) const override {
        rewriter.replaceOpWithNewOp<arith::ShLIOp>(op, adaptor.getValue(), adaptor.getAmount());
        return success();
    }
};

struct IntShiftRightOpLowering : public OpConversionPattern<IntShiftRightOp> {
    using OpConversionPattern::OpConversionPattern;

    LogicalResult
    matchAndRewrite(IntShiftRightOp op, OpAdaptor adaptor,
                    ConversionPatternRewriter &rewriter) const override {
        // Arithmetic shift right (preserves sign)
        rewriter.replaceOpWithNewOp<arith::ShRSIOp>(op, adaptor.getValue(), adaptor.getAmount());
        return success();
    }
};

struct IntShiftRightZfOpLowering : public OpConversionPattern<IntShiftRightZfOp> {
    using OpConversionPattern::OpConversionPattern;

    LogicalResult
    matchAndRewrite(IntShiftRightZfOp op, OpAdaptor adaptor,
                    ConversionPatternRewriter &rewriter) const override {
        // Logical shift right (zero fill)
        rewriter.replaceOpWithNewOp<arith::ShRUIOp>(op, adaptor.getValue(), adaptor.getAmount());
        return success();
    }
};

//===----------------------------------------------------------------------===//
// Boolean Operations
//===----------------------------------------------------------------------===//

struct BoolNotOpLowering : public OpConversionPattern<BoolNotOp> {
    using OpConversionPattern::OpConversionPattern;

    LogicalResult
    matchAndRewrite(BoolNotOp op, OpAdaptor adaptor,
                    ConversionPatternRewriter &rewriter) const override {
        auto loc = op.getLoc();
        auto *ctx = rewriter.getContext();
        auto i1Ty = IntegerType::get(ctx, 1);
        auto one = rewriter.create<arith::ConstantIntOp>(loc, 1, /*width=*/1);
        rewriter.replaceOpWithNewOp<arith::XOrIOp>(op, adaptor.getValue(), one);
        return success();
    }
};

struct BoolAndOpLowering : public OpConversionPattern<BoolAndOp> {
    using OpConversionPattern::OpConversionPattern;

    LogicalResult
    matchAndRewrite(BoolAndOp op, OpAdaptor adaptor,
                    ConversionPatternRewriter &rewriter) const override {
        rewriter.replaceOpWithNewOp<arith::AndIOp>(op, adaptor.getLhs(), adaptor.getRhs());
        return success();
    }
};

struct BoolOrOpLowering : public OpConversionPattern<BoolOrOp> {
    using OpConversionPattern::OpConversionPattern;

    LogicalResult
    matchAndRewrite(BoolOrOp op, OpAdaptor adaptor,
                    ConversionPatternRewriter &rewriter) const override {
        rewriter.replaceOpWithNewOp<arith::OrIOp>(op, adaptor.getLhs(), adaptor.getRhs());
        return success();
    }
};

struct BoolXorOpLowering : public OpConversionPattern<BoolXorOp> {
    using OpConversionPattern::OpConversionPattern;

    LogicalResult
    matchAndRewrite(BoolXorOp op, OpAdaptor adaptor,
                    ConversionPatternRewriter &rewriter) const override {
        rewriter.replaceOpWithNewOp<arith::XOrIOp>(op, adaptor.getLhs(), adaptor.getRhs());
        return success();
    }
};

//===----------------------------------------------------------------------===//
// Character Operations
//===----------------------------------------------------------------------===//

struct CharToIntOpLowering : public OpConversionPattern<CharToIntOp> {
    using OpConversionPattern::OpConversionPattern;

    LogicalResult
    matchAndRewrite(CharToIntOp op, OpAdaptor adaptor,
                    ConversionPatternRewriter &rewriter) const override {
        auto i64Ty = IntegerType::get(rewriter.getContext(), 64);
        // Zero-extend i16 to i64 (char codes are always non-negative)
        rewriter.replaceOpWithNewOp<arith::ExtUIOp>(op, i64Ty, adaptor.getValue());
        return success();
    }
};

struct CharFromIntOpLowering : public OpConversionPattern<CharFromIntOp> {
    using OpConversionPattern::OpConversionPattern;

    LogicalResult
    matchAndRewrite(CharFromIntOp op, OpAdaptor adaptor,
                    ConversionPatternRewriter &rewriter) const override {
        auto loc = op.getLoc();
        auto *ctx = rewriter.getContext();
        auto i16Ty = IntegerType::get(ctx, 16);

        Value input = adaptor.getValue();

        // Clamp to valid range [0, 0xFFFF]
        Value zero = rewriter.create<arith::ConstantIntOp>(loc, 0, /*width=*/64);
        Value maxChar = rewriter.create<arith::ConstantIntOp>(loc, 0xFFFF, /*width=*/64);

        // clamp: max(0, min(input, 0xFFFF))
        Value clampedLow = rewriter.create<arith::MaxSIOp>(loc, input, zero);
        Value clamped = rewriter.create<arith::MinSIOp>(loc, clampedLow, maxChar);

        // Truncate to i16
        rewriter.replaceOpWithNewOp<arith::TruncIOp>(op, i16Ty, clamped);
        return success();
    }
};

} // namespace

//===----------------------------------------------------------------------===//
// Pattern Population
//===----------------------------------------------------------------------===//

void eco::detail::populateEcoArithPatterns(
    EcoTypeConverter &typeConverter,
    RewritePatternSet &patterns) {

    auto *ctx = patterns.getContext();

    // Get runtime for patterns that need it
    // Note: For arith patterns that need runtime (IntPow, trig), we use a
    // separate overload. Most arith patterns don't need runtime.
    patterns.add<
        // Integer arithmetic
        IntAddOpLowering,
        IntSubOpLowering,
        IntMulOpLowering,
        IntDivOpLowering,
        IntModByOpLowering,
        IntRemainderByOpLowering,
        IntNegateOpLowering,
        IntAbsOpLowering,
        // Float arithmetic (basic)
        FloatAddOpLowering,
        FloatSubOpLowering,
        FloatMulOpLowering,
        FloatDivOpLowering,
        FloatNegateOpLowering,
        FloatAbsOpLowering,
        FloatPowOpLowering,
        FloatSqrtOpLowering,
        FloatSinOpLowering,
        FloatCosOpLowering,
        FloatTanOpLowering,
        FloatLogOpLowering,
        FloatIsNaNOpLowering,
        FloatIsInfiniteOpLowering,
        // Type conversions
        IntToFloatOpLowering,
        FloatRoundOpLowering,
        FloatFloorOpLowering,
        FloatCeilingOpLowering,
        FloatTruncateOpLowering,
        // Integer comparisons
        IntLtOpLowering,
        IntLeOpLowering,
        IntGtOpLowering,
        IntGeOpLowering,
        IntEqOpLowering,
        IntNeOpLowering,
        // Float comparisons
        FloatLtOpLowering,
        FloatLeOpLowering,
        FloatGtOpLowering,
        FloatGeOpLowering,
        FloatEqOpLowering,
        FloatNeOpLowering,
        // Min/Max
        IntMinOpLowering,
        IntMaxOpLowering,
        FloatMinOpLowering,
        FloatMaxOpLowering,
        // Bitwise
        IntAndOpLowering,
        IntOrOpLowering,
        IntXorOpLowering,
        IntComplementOpLowering,
        IntShiftLeftOpLowering,
        IntShiftRightOpLowering,
        IntShiftRightZfOpLowering,
        // Boolean
        BoolNotOpLowering,
        BoolAndOpLowering,
        BoolOrOpLowering,
        BoolXorOpLowering,
        // Character
        CharToIntOpLowering,
        CharFromIntOpLowering
    >(typeConverter, ctx);
}

// Separate function for patterns that need EcoRuntime
void eco::detail::populateEcoArithPatternsWithRuntime(
    EcoTypeConverter &typeConverter,
    RewritePatternSet &patterns,
    EcoRuntime runtime) {

    auto *ctx = patterns.getContext();
    patterns.add<IntPowOpLowering>(typeConverter, ctx, runtime);
    patterns.add<FloatAsinOpLowering>(typeConverter, ctx, runtime);
    patterns.add<FloatAcosOpLowering>(typeConverter, ctx, runtime);
    patterns.add<FloatAtanOpLowering>(typeConverter, ctx, runtime);
    patterns.add<FloatAtan2OpLowering>(typeConverter, ctx, runtime);
}
