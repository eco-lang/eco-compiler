//===- EcoToLLVMArith.cpp - Arithmetic lowering patterns ------------------===//
//
// Elm's scalar operations are mostly single machine instructions, and this file turns the eco
// dialect's scalar operations into those instructions, as conversion patterns of the `eco-to-llvm`
// pass.
//
// A scalar here is an unboxed Int (i64), Float (f64), Char (i32, a code point) or Bool (i1).
// Most operations become one arith or LLVM dialect op. The patterns that do more exist because the
// Elm operation is defined where the LLVM instruction is not, or means something different:
//
// - Integer division and remainder are total (CGEN_084). LLVM's `sdiv` and `srem` are undefined for
//   a divisor of 0 and for the minimum Int divided by -1, so a divisor of 0 or -1 is replaced by 1
//   before the instruction and the result is chosen afterwards. `modBy` is floored division modulo:
//   a non-zero result takes the sign of the modulus, where `srem`'s takes the sign of the dividend.
// - A shift count is taken modulo 64 (CGEN_085), because an LLVM shift by 64 or more is poison.
// - Chars are ordered by unsigned comparison of their code points, and an Int outside 0..0x10FFFF
//   converted to a Char becomes U+FFFD.
// - Float comparisons use ordered predicates, so each one is false when either operand is NaN.
//
// The comparisons that produce an Elm `Order` (`LT`, `EQ` or `GT`) return a boxed `!eco.value`. For
// Int, Float and Char the comparison is done inline and a runtime function only supplies the
// `Order` value (CGEN_075); for String one runtime function compares and returns it.
// `eco.value.eq` becomes a call to the `__eco_value_eq` marker, a declaration with no definition
// that the backend later replaces with inline code (CGEN_076).
//
// The patterns are added by `populateEcoArithPatterns`, and those that call a runtime function by
// `populateEcoArithPatternsWithRuntime`. Every runtime function they call is declared gc-leaf by
// `EcoRuntime`.
//
//===----------------------------------------------------------------------===//

#include <cstdint>
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

/**
 * Lowers `eco.int.add` to a wrapping 64-bit `arith.addi`.
 */
struct IntAddOpLowering : public OpConversionPattern<IntAddOp> {
    using OpConversionPattern::OpConversionPattern;

    LogicalResult
    matchAndRewrite(IntAddOp op, OpAdaptor adaptor,
                    ConversionPatternRewriter &rewriter) const override {
        rewriter.replaceOpWithNewOp<arith::AddIOp>(op, adaptor.getLhs(), adaptor.getRhs());
        return success();
    }
};

/**
 * Lowers `eco.int.sub` to a wrapping 64-bit `arith.subi`.
 */
struct IntSubOpLowering : public OpConversionPattern<IntSubOp> {
    using OpConversionPattern::OpConversionPattern;

    LogicalResult
    matchAndRewrite(IntSubOp op, OpAdaptor adaptor,
                    ConversionPatternRewriter &rewriter) const override {
        rewriter.replaceOpWithNewOp<arith::SubIOp>(op, adaptor.getLhs(), adaptor.getRhs());
        return success();
    }
};

/**
 * Lowers `eco.int.mul` to a wrapping 64-bit `arith.muli`.
 */
struct IntMulOpLowering : public OpConversionPattern<IntMulOp> {
    using OpConversionPattern::OpConversionPattern;

    LogicalResult
    matchAndRewrite(IntMulOp op, OpAdaptor adaptor,
                    ConversionPatternRewriter &rewriter) const override {
        rewriter.replaceOpWithNewOp<arith::MulIOp>(op, adaptor.getLhs(), adaptor.getRhs());
        return success();
    }
};

/**
 * Lowers Int division `//`, which truncates toward zero and is total: `x // 0` is 0 and `x // -1` is
 * the wrapping negation of `x`, so the minimum Int divided by -1 is the minimum Int (CGEN_084).
 */
struct IntDivOpLowering : public OpConversionPattern<IntDivOp> {
    using OpConversionPattern::OpConversionPattern;

    LogicalResult
    matchAndRewrite(IntDivOp op, OpAdaptor adaptor,
                    ConversionPatternRewriter &rewriter) const override {
        auto loc = op.getLoc();

        Value lhs = adaptor.getLhs();
        Value rhs = adaptor.getRhs();

        // `sdiv` by 0, or of the minimum Int by -1, is undefined, so a divisor in {-1, 0} (tested with
        // one unsigned compare, rhs + 1 <=u 1) divides by 1 instead, and the result is rhs * lhs,
        // which is 0 or the wrapping negation.
        auto one = rewriter.create<arith::ConstantIntOp>(loc, 1, /*width=*/64);
        auto rhsPlus1 = rewriter.create<arith::AddIOp>(loc, rhs, one);
        auto isSpecial = rewriter.create<arith::CmpIOp>(loc, arith::CmpIPredicate::ule,
                                                         rhsPlus1, one);
        auto safeRhs = rewriter.create<arith::SelectOp>(loc, isSpecial, one, rhs);

        auto divResult = rewriter.create<arith::DivSIOp>(loc, lhs, safeRhs);
        auto specialResult = rewriter.create<arith::MulIOp>(loc, rhs, lhs);
        auto result = rewriter.create<arith::SelectOp>(loc, isSpecial, specialResult,
                                                       divResult);

        rewriter.replaceOp(op, result);
        return success();
    }
};

/**
 * Lowers `modBy`, the floored remainder: `modBy 3 (-5)` is 1 where `srem` gives -2. A modulus of 0
 * or -1 gives 0 (CGEN_084).
 */
struct IntModByOpLowering : public OpConversionPattern<IntModByOp> {
    using OpConversionPattern::OpConversionPattern;

    LogicalResult
    matchAndRewrite(IntModByOp op, OpAdaptor adaptor,
                    ConversionPatternRewriter &rewriter) const override {
        auto loc = op.getLoc();

        Value modulus = adaptor.getModulus();
        Value x = adaptor.getX();

        // r = x srem m; a non-zero r whose sign differs from m's ((r ^ m) < 0) has m added.

        auto zero = rewriter.create<arith::ConstantIntOp>(loc, 0, /*width=*/64);

        // `srem` by 0, or of the minimum Int by -1, is undefined, so a modulus in {-1, 0} (m + 1 <=u 1)
        // is replaced by 1. The floored remainder by 1 is 0 for every x, so no final select is needed.
        auto one = rewriter.create<arith::ConstantIntOp>(loc, 1, /*width=*/64);
        auto modPlus1 = rewriter.create<arith::AddIOp>(loc, modulus, one);
        auto isSpecial = rewriter.create<arith::CmpIOp>(loc, arith::CmpIPredicate::ule,
                                                         modPlus1, one);
        auto safeModulus = rewriter.create<arith::SelectOp>(loc, isSpecial, one, modulus);

        auto truncRem = rewriter.create<arith::RemSIOp>(loc, x, safeModulus);

        auto remIsNonZero = rewriter.create<arith::CmpIOp>(loc, arith::CmpIPredicate::ne,
                                                            truncRem, zero);
        auto xorVal = rewriter.create<arith::XOrIOp>(loc, truncRem, safeModulus);
        auto signsDiffer = rewriter.create<arith::CmpIOp>(loc, arith::CmpIPredicate::slt,
                                                           xorVal, zero);
        auto needsAdjust = rewriter.create<arith::AndIOp>(loc, remIsNonZero, signsDiffer);

        auto adjusted = rewriter.create<arith::AddIOp>(loc, truncRem, safeModulus);
        auto result = rewriter.create<arith::SelectOp>(loc, needsAdjust, adjusted, truncRem);

        rewriter.replaceOp(op, result);
        return success();
    }
};

/**
 * Lowers `remainderBy`, the truncated remainder, which takes the sign of the dividend. A divisor
 * of 0 or -1 gives 0 (CGEN_084).
 */
struct IntRemainderByOpLowering : public OpConversionPattern<IntRemainderByOp> {
    using OpConversionPattern::OpConversionPattern;

    LogicalResult
    matchAndRewrite(IntRemainderByOp op, OpAdaptor adaptor,
                    ConversionPatternRewriter &rewriter) const override {
        auto loc = op.getLoc();

        Value divisor = adaptor.getDivisor();
        Value x = adaptor.getX();

        // `srem` by 0, or of the minimum Int by -1, is undefined, so a divisor in {-1, 0} (d + 1 <=u 1)
        // is replaced by 1, whose remainder is 0 for every x.
        auto one = rewriter.create<arith::ConstantIntOp>(loc, 1, /*width=*/64);
        auto divPlus1 = rewriter.create<arith::AddIOp>(loc, divisor, one);
        auto isSpecial = rewriter.create<arith::CmpIOp>(loc, arith::CmpIPredicate::ule,
                                                         divPlus1, one);
        auto safeDivisor = rewriter.create<arith::SelectOp>(loc, isSpecial, one, divisor);

        auto result = rewriter.create<arith::RemSIOp>(loc, x, safeDivisor);

        rewriter.replaceOp(op, result);
        return success();
    }
};

/**
 * Lowers Int negation to `0 - x`, which wraps for the minimum Int.
 */
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

/**
 * Lowers Int `abs` to a select of `x` and `0 - x`; the minimum Int is returned unchanged.
 */
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

/**
 * Lowers Int `^` to a call to the runtime function `eco_int_pow`.
 */
struct IntPowOpLowering : public OpConversionPattern<IntPowOp> {
    // Declares the runtime functions this pattern calls.
    const EcoRuntime &runtime;

    // Creates the pattern. It keeps references to `typeConverter` and `runtime`, which must outlive it.
    IntPowOpLowering(EcoTypeConverter &typeConverter, MLIRContext *ctx,
                     const EcoRuntime &runtime)
        : OpConversionPattern(typeConverter, ctx), runtime(runtime) {}

    LogicalResult
    matchAndRewrite(IntPowOp op, OpAdaptor adaptor,
                    ConversionPatternRewriter &rewriter) const override {
        auto loc = op.getLoc();

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

/**
 * Lowers Float addition to `arith.addf`.
 */
struct FloatAddOpLowering : public OpConversionPattern<FloatAddOp> {
    using OpConversionPattern::OpConversionPattern;

    LogicalResult
    matchAndRewrite(FloatAddOp op, OpAdaptor adaptor,
                    ConversionPatternRewriter &rewriter) const override {
        rewriter.replaceOpWithNewOp<arith::AddFOp>(op, adaptor.getLhs(), adaptor.getRhs());
        return success();
    }
};

/**
 * Lowers Float subtraction to `arith.subf`.
 */
struct FloatSubOpLowering : public OpConversionPattern<FloatSubOp> {
    using OpConversionPattern::OpConversionPattern;

    LogicalResult
    matchAndRewrite(FloatSubOp op, OpAdaptor adaptor,
                    ConversionPatternRewriter &rewriter) const override {
        rewriter.replaceOpWithNewOp<arith::SubFOp>(op, adaptor.getLhs(), adaptor.getRhs());
        return success();
    }
};

/**
 * Lowers Float multiplication to `arith.mulf`.
 */
struct FloatMulOpLowering : public OpConversionPattern<FloatMulOp> {
    using OpConversionPattern::OpConversionPattern;

    LogicalResult
    matchAndRewrite(FloatMulOp op, OpAdaptor adaptor,
                    ConversionPatternRewriter &rewriter) const override {
        rewriter.replaceOpWithNewOp<arith::MulFOp>(op, adaptor.getLhs(), adaptor.getRhs());
        return success();
    }
};

/**
 * Lowers Float division `/` to `arith.divf`; division by zero gives an infinity or NaN.
 */
struct FloatDivOpLowering : public OpConversionPattern<FloatDivOp> {
    using OpConversionPattern::OpConversionPattern;

    LogicalResult
    matchAndRewrite(FloatDivOp op, OpAdaptor adaptor,
                    ConversionPatternRewriter &rewriter) const override {
        rewriter.replaceOpWithNewOp<arith::DivFOp>(op, adaptor.getLhs(), adaptor.getRhs());
        return success();
    }
};

/**
 * Lowers Float negation to `llvm.fneg`.
 */
struct FloatNegateOpLowering : public OpConversionPattern<FloatNegateOp> {
    using OpConversionPattern::OpConversionPattern;

    LogicalResult
    matchAndRewrite(FloatNegateOp op, OpAdaptor adaptor,
                    ConversionPatternRewriter &rewriter) const override {
        rewriter.replaceOpWithNewOp<arith::NegFOp>(op, adaptor.getValue());
        return success();
    }
};

/**
 * Lowers Float `abs` to `llvm.intr.fabs`.
 */
struct FloatAbsOpLowering : public OpConversionPattern<FloatAbsOp> {
    using OpConversionPattern::OpConversionPattern;

    LogicalResult
    matchAndRewrite(FloatAbsOp op, OpAdaptor adaptor,
                    ConversionPatternRewriter &rewriter) const override {
        rewriter.replaceOpWithNewOp<LLVM::FAbsOp>(op, adaptor.getValue());
        return success();
    }
};

/**
 * Lowers Float `^` to `llvm.intr.pow`.
 */
struct FloatPowOpLowering : public OpConversionPattern<FloatPowOp> {
    using OpConversionPattern::OpConversionPattern;

    LogicalResult
    matchAndRewrite(FloatPowOp op, OpAdaptor adaptor,
                    ConversionPatternRewriter &rewriter) const override {
        rewriter.replaceOpWithNewOp<LLVM::PowOp>(op, adaptor.getBase(), adaptor.getExp());
        return success();
    }
};

/**
 * Lowers `sqrt` to `llvm.intr.sqrt`.
 */
struct FloatSqrtOpLowering : public OpConversionPattern<FloatSqrtOp> {
    using OpConversionPattern::OpConversionPattern;

    LogicalResult
    matchAndRewrite(FloatSqrtOp op, OpAdaptor adaptor,
                    ConversionPatternRewriter &rewriter) const override {
        rewriter.replaceOpWithNewOp<LLVM::SqrtOp>(op, adaptor.getValue());
        return success();
    }
};

/**
 * Lowers `sin` to `llvm.intr.sin`.
 */
struct FloatSinOpLowering : public OpConversionPattern<FloatSinOp> {
    using OpConversionPattern::OpConversionPattern;

    LogicalResult
    matchAndRewrite(FloatSinOp op, OpAdaptor adaptor,
                    ConversionPatternRewriter &rewriter) const override {
        rewriter.replaceOpWithNewOp<LLVM::SinOp>(op, adaptor.getValue());
        return success();
    }
};

/**
 * Lowers `cos` to `llvm.intr.cos`.
 */
struct FloatCosOpLowering : public OpConversionPattern<FloatCosOp> {
    using OpConversionPattern::OpConversionPattern;

    LogicalResult
    matchAndRewrite(FloatCosOp op, OpAdaptor adaptor,
                    ConversionPatternRewriter &rewriter) const override {
        rewriter.replaceOpWithNewOp<LLVM::CosOp>(op, adaptor.getValue());
        return success();
    }
};

/**
 * Lowers `tan` to `sin x / cos x`, computed with the LLVM sine and cosine intrinsics.
 */
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

/**
 * Lowers `asin` to a call to the C library function `asin`.
 */
struct FloatAsinOpLowering : public OpConversionPattern<FloatAsinOp> {
    // Declares the runtime functions this pattern calls.
    const EcoRuntime &runtime;

    // Creates the pattern. It keeps references to `typeConverter` and `runtime`, which must outlive it.
    FloatAsinOpLowering(EcoTypeConverter &typeConverter, MLIRContext *ctx,
                        const EcoRuntime &runtime)
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

/**
 * Lowers `acos` to a call to the C library function `acos`.
 */
struct FloatAcosOpLowering : public OpConversionPattern<FloatAcosOp> {
    // Declares the runtime functions this pattern calls.
    const EcoRuntime &runtime;

    // Creates the pattern. It keeps references to `typeConverter` and `runtime`, which must outlive it.
    FloatAcosOpLowering(EcoTypeConverter &typeConverter, MLIRContext *ctx,
                        const EcoRuntime &runtime)
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

/**
 * Lowers `atan` to a call to the C library function `atan`.
 */
struct FloatAtanOpLowering : public OpConversionPattern<FloatAtanOp> {
    // Declares the runtime functions this pattern calls.
    const EcoRuntime &runtime;

    // Creates the pattern. It keeps references to `typeConverter` and `runtime`, which must outlive it.
    FloatAtanOpLowering(EcoTypeConverter &typeConverter, MLIRContext *ctx,
                        const EcoRuntime &runtime)
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

/**
 * Lowers `atan2 y x` to a call to the C library function `atan2(y, x)`.
 */
struct FloatAtan2OpLowering : public OpConversionPattern<FloatAtan2Op> {
    // Declares the runtime functions this pattern calls.
    const EcoRuntime &runtime;

    // Creates the pattern. It keeps references to `typeConverter` and `runtime`, which must outlive it.
    FloatAtan2OpLowering(EcoTypeConverter &typeConverter, MLIRContext *ctx,
                         const EcoRuntime &runtime)
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

/**
 * Lowers the natural logarithm to `llvm.intr.log`.
 */
struct FloatLogOpLowering : public OpConversionPattern<FloatLogOp> {
    using OpConversionPattern::OpConversionPattern;

    LogicalResult
    matchAndRewrite(FloatLogOp op, OpAdaptor adaptor,
                    ConversionPatternRewriter &rewriter) const override {
        rewriter.replaceOpWithNewOp<LLVM::LogOp>(op, adaptor.getValue());
        return success();
    }
};

/**
 * Lowers `isNaN` to an unordered self-comparison, which is true only for NaN.
 */
struct FloatIsNaNOpLowering : public OpConversionPattern<FloatIsNaNOp> {
    using OpConversionPattern::OpConversionPattern;

    LogicalResult
    matchAndRewrite(FloatIsNaNOp op, OpAdaptor adaptor,
                    ConversionPatternRewriter &rewriter) const override {
        rewriter.replaceOpWithNewOp<arith::CmpFOp>(op, arith::CmpFPredicate::UNO,
                                                    adaptor.getValue(), adaptor.getValue());
        return success();
    }
};

/**
 * Lowers `isInfinite` to a test that the absolute value equals positive infinity.
 */
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

/**
 * Lowers `toFloat` to a signed integer-to-float conversion.
 */
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

/**
 * Emits the saturating conversion of `x`, an f64, to i64 (CGEN_086): NaN gives 0, a value at or
 * above 2^63 gives INT64_MAX, a value below -2^63 gives INT64_MIN, and any other value is truncated
 * toward zero. `fptosi` alone is poison outside the Int range; `select` passes its poison on only
 * when it picks it, so it can be computed unconditionally.
 */
static Value emitSatFPToSI(Location loc, Value x, ConversionPatternRewriter &rewriter) {
    auto i64Ty = rewriter.getIntegerType(64);
    auto f64Ty = rewriter.getF64Type();
    auto fconst = [&](double v) -> Value {
        return rewriter.create<arith::ConstantOp>(loc, rewriter.getFloatAttr(f64Ty, v));
    };
    auto iconst = [&](int64_t v) -> Value {
        return rewriter.create<arith::ConstantOp>(loc, rewriter.getI64IntegerAttr(v));
    };
    Value conv = rewriter.create<arith::FPToSIOp>(loc, i64Ty, x);
    Value isNaN = rewriter.create<arith::CmpFOp>(loc, arith::CmpFPredicate::UNO, x, x);
    Value tooHigh = rewriter.create<arith::CmpFOp>(loc, arith::CmpFPredicate::OGE, x, fconst(9223372036854775808.0));
    Value tooLow = rewriter.create<arith::CmpFOp>(loc, arith::CmpFPredicate::OLT, x, fconst(-9223372036854775808.0));
    Value v = rewriter.create<arith::SelectOp>(loc, isNaN, iconst(0), conv);
    v = rewriter.create<arith::SelectOp>(loc, tooLow, iconst(INT64_MIN), v);
    return rewriter.create<arith::SelectOp>(loc, tooHigh, iconst(INT64_MAX), v);
}

/**
 * Lowers `round` to JS `Math.round` (ties toward +infinity) followed by the saturating conversion to
 * Int (`emitSatFPToSI`).
 */
struct FloatRoundOpLowering : public OpConversionPattern<FloatRoundOp> {
    using OpConversionPattern::OpConversionPattern;

    LogicalResult
    matchAndRewrite(FloatRoundOp op, OpAdaptor adaptor,
                    ConversionPatternRewriter &rewriter) const override {
        auto loc = op.getLoc();
        auto *ctx = rewriter.getContext();
        auto i64Ty = IntegerType::get(ctx, 64);

        // JS Math.round, which Elm's `round` is: floor(x), plus 1 when x - floor(x) >= 0.5, so ties go
        // toward +infinity (llvm.round ties away from zero). x - floor(x) is exact for a double.
        auto f64Ty = rewriter.getF64Type();
        Value x = adaptor.getValue();
        Value fl = rewriter.create<LLVM::FFloorOp>(loc, x);
        Value frac = rewriter.create<arith::SubFOp>(loc, x, fl);
        Value half = rewriter.create<arith::ConstantOp>(loc, rewriter.getFloatAttr(f64Ty, 0.5));
        Value one = rewriter.create<arith::ConstantOp>(loc, rewriter.getFloatAttr(f64Ty, 1.0));
        Value up = rewriter.create<arith::CmpFOp>(loc, arith::CmpFPredicate::OGE, frac, half);
        Value next = rewriter.create<arith::AddFOp>(loc, fl, one);
        Value rounded = rewriter.create<arith::SelectOp>(loc, up, next, fl);
        rewriter.replaceOp(op, emitSatFPToSI(loc, rounded, rewriter));
        return success();
    }
};

/**
 * Lowers `floor` to `llvm.intr.floor` and the saturating conversion to Int (`emitSatFPToSI`).
 */
struct FloatFloorOpLowering : public OpConversionPattern<FloatFloorOp> {
    using OpConversionPattern::OpConversionPattern;

    LogicalResult
    matchAndRewrite(FloatFloorOp op, OpAdaptor adaptor,
                    ConversionPatternRewriter &rewriter) const override {
        auto loc = op.getLoc();
        auto *ctx = rewriter.getContext();
        auto i64Ty = IntegerType::get(ctx, 64);

        auto floored = rewriter.create<LLVM::FFloorOp>(loc, adaptor.getValue());
        rewriter.replaceOp(op, emitSatFPToSI(loc, floored, rewriter));
        return success();
    }
};

/**
 * Lowers `ceiling` to `llvm.intr.ceil` and the saturating conversion to Int (`emitSatFPToSI`).
 */
struct FloatCeilingOpLowering : public OpConversionPattern<FloatCeilingOp> {
    using OpConversionPattern::OpConversionPattern;

    LogicalResult
    matchAndRewrite(FloatCeilingOp op, OpAdaptor adaptor,
                    ConversionPatternRewriter &rewriter) const override {
        auto loc = op.getLoc();
        auto *ctx = rewriter.getContext();
        auto i64Ty = IntegerType::get(ctx, 64);

        auto ceiled = rewriter.create<LLVM::FCeilOp>(loc, adaptor.getValue());
        rewriter.replaceOp(op, emitSatFPToSI(loc, ceiled, rewriter));
        return success();
    }
};

/**
 * Lowers `truncate` to the saturating float-to-Int conversion (`emitSatFPToSI`), which rounds toward zero.
 */
struct FloatTruncateOpLowering : public OpConversionPattern<FloatTruncateOp> {
    using OpConversionPattern::OpConversionPattern;

    LogicalResult
    matchAndRewrite(FloatTruncateOp op, OpAdaptor adaptor,
                    ConversionPatternRewriter &rewriter) const override {
        auto *ctx = rewriter.getContext();
        auto i64Ty = IntegerType::get(ctx, 64);
        rewriter.replaceOp(op, emitSatFPToSI(op.getLoc(), adaptor.getValue(), rewriter));
        return success();
    }
};

//===----------------------------------------------------------------------===//
// Integer Comparisons
//===----------------------------------------------------------------------===//

/**
 * Lowers Int `<` to a signed comparison.
 */
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

/**
 * Lowers Int `<=` to a signed comparison.
 */
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

/**
 * Lowers Int `>` to a signed comparison.
 */
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

/**
 * Lowers Int `>=` to a signed comparison.
 */
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

/**
 * Lowers Int `==` to an integer equality comparison.
 */
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

/**
 * Lowers Int `/=` to an integer inequality comparison.
 */
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

/**
 * Lowers Float `<` to the ordered comparison `olt`.
 */
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

/**
 * Lowers Float `<=` to the ordered comparison `ole`.
 */
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

/**
 * Lowers Float `>` to the ordered comparison `ogt`.
 */
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

/**
 * Lowers Float `>=` to the ordered comparison `oge`.
 */
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

/**
 * Lowers Float `==` to the ordered comparison `oeq`.
 */
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

/**
 * Lowers Float `/=` to the unordered comparison `une`, which is true when either operand is NaN: the
 * negation of `==`, as IEEE 754 defines not-equal and Elm (JS `!==`) behaves.
 */
struct FloatNeOpLowering : public OpConversionPattern<FloatNeOp> {
    using OpConversionPattern::OpConversionPattern;

    LogicalResult
    matchAndRewrite(FloatNeOp op, OpAdaptor adaptor,
                    ConversionPatternRewriter &rewriter) const override {
        rewriter.replaceOpWithNewOp<arith::CmpFOp>(
            op, arith::CmpFPredicate::UNE, adaptor.getLhs(), adaptor.getRhs());
        return success();
    }
};

//===----------------------------------------------------------------------===//
// Min/Max Operations
//===----------------------------------------------------------------------===//

/**
 * Lowers Int `min` to a signed minimum.
 */
struct IntMinOpLowering : public OpConversionPattern<IntMinOp> {
    using OpConversionPattern::OpConversionPattern;

    LogicalResult
    matchAndRewrite(IntMinOp op, OpAdaptor adaptor,
                    ConversionPatternRewriter &rewriter) const override {
        rewriter.replaceOpWithNewOp<arith::MinSIOp>(op, adaptor.getLhs(), adaptor.getRhs());
        return success();
    }
};

/**
 * Lowers Int `max` to a signed maximum.
 */
struct IntMaxOpLowering : public OpConversionPattern<IntMaxOp> {
    using OpConversionPattern::OpConversionPattern;

    LogicalResult
    matchAndRewrite(IntMaxOp op, OpAdaptor adaptor,
                    ConversionPatternRewriter &rewriter) const override {
        rewriter.replaceOpWithNewOp<arith::MaxSIOp>(op, adaptor.getLhs(), adaptor.getRhs());
        return success();
    }
};

/**
 * Lowers Float `min` to `llvm.intr.minimum`, IEEE 754-2019 minimum (CGEN_086): NaN in either
 * operand gives NaN, and -0 is below +0.
 */
struct FloatMinOpLowering : public OpConversionPattern<FloatMinOp> {
    using OpConversionPattern::OpConversionPattern;

    LogicalResult
    matchAndRewrite(FloatMinOp op, OpAdaptor adaptor,
                    ConversionPatternRewriter &rewriter) const override {
        rewriter.replaceOpWithNewOp<LLVM::MinimumOp>(op, adaptor.getLhs(), adaptor.getRhs());
        return success();
    }
};

/**
 * Lowers Float `max` to `llvm.intr.maximum`, IEEE 754-2019 maximum (CGEN_086): NaN in either
 * operand gives NaN, and +0 is above -0.
 */
struct FloatMaxOpLowering : public OpConversionPattern<FloatMaxOp> {
    using OpConversionPattern::OpConversionPattern;

    LogicalResult
    matchAndRewrite(FloatMaxOp op, OpAdaptor adaptor,
                    ConversionPatternRewriter &rewriter) const override {
        rewriter.replaceOpWithNewOp<LLVM::MaximumOp>(op, adaptor.getLhs(), adaptor.getRhs());
        return success();
    }
};

//===----------------------------------------------------------------------===//
// Bitwise Operations
//===----------------------------------------------------------------------===//

/**
 * Lowers `Bitwise.and` to `arith.andi`.
 */
struct IntAndOpLowering : public OpConversionPattern<IntAndOp> {
    using OpConversionPattern::OpConversionPattern;

    LogicalResult
    matchAndRewrite(IntAndOp op, OpAdaptor adaptor,
                    ConversionPatternRewriter &rewriter) const override {
        rewriter.replaceOpWithNewOp<arith::AndIOp>(op, adaptor.getLhs(), adaptor.getRhs());
        return success();
    }
};

/**
 * Lowers `Bitwise.or` to `arith.ori`.
 */
struct IntOrOpLowering : public OpConversionPattern<IntOrOp> {
    using OpConversionPattern::OpConversionPattern;

    LogicalResult
    matchAndRewrite(IntOrOp op, OpAdaptor adaptor,
                    ConversionPatternRewriter &rewriter) const override {
        rewriter.replaceOpWithNewOp<arith::OrIOp>(op, adaptor.getLhs(), adaptor.getRhs());
        return success();
    }
};

/**
 * Lowers `Bitwise.xor` to `arith.xori`.
 */
struct IntXorOpLowering : public OpConversionPattern<IntXorOp> {
    using OpConversionPattern::OpConversionPattern;

    LogicalResult
    matchAndRewrite(IntXorOp op, OpAdaptor adaptor,
                    ConversionPatternRewriter &rewriter) const override {
        rewriter.replaceOpWithNewOp<arith::XOrIOp>(op, adaptor.getLhs(), adaptor.getRhs());
        return success();
    }
};

/**
 * Lowers `Bitwise.complement` to an exclusive or with all bits set.
 */
struct IntComplementOpLowering : public OpConversionPattern<IntComplementOp> {
    using OpConversionPattern::OpConversionPattern;

    LogicalResult
    matchAndRewrite(IntComplementOp op, OpAdaptor adaptor,
                    ConversionPatternRewriter &rewriter) const override {
        auto loc = op.getLoc();

        auto allOnes = rewriter.create<arith::ConstantIntOp>(loc, -1, /*width=*/64);
        rewriter.replaceOpWithNewOp<arith::XOrIOp>(op, adaptor.getValue(), allOnes);
        return success();
    }
};

// Returns `amount & 63`, the shift count modulo 64, with negative counts wrapping too (CGEN_085). An
// LLVM shift by 64 or more is poison, so every shift here takes its count through this function.
static Value shiftAmountMod64(ConversionPatternRewriter &rewriter, Location loc,
                              Value amount) {
    auto mask = rewriter.create<arith::ConstantIntOp>(loc, 63, /*width=*/64);
    return rewriter.create<arith::AndIOp>(loc, amount, mask);
}

/**
 * Lowers `eco.int.shl` to a left shift by the count modulo 64.
 */
struct IntShiftLeftOpLowering : public OpConversionPattern<IntShiftLeftOp> {
    using OpConversionPattern::OpConversionPattern;

    LogicalResult
    matchAndRewrite(IntShiftLeftOp op, OpAdaptor adaptor,
                    ConversionPatternRewriter &rewriter) const override {
        rewriter.replaceOpWithNewOp<arith::ShLIOp>(op, adaptor.getValue(),
            shiftAmountMod64(rewriter, op.getLoc(), adaptor.getAmount()));
        return success();
    }
};

/**
 * Lowers `eco.int.shr` to an arithmetic (sign-filling) right shift by the count modulo 64.
 */
struct IntShiftRightOpLowering : public OpConversionPattern<IntShiftRightOp> {
    using OpConversionPattern::OpConversionPattern;

    LogicalResult
    matchAndRewrite(IntShiftRightOp op, OpAdaptor adaptor,
                    ConversionPatternRewriter &rewriter) const override {
        rewriter.replaceOpWithNewOp<arith::ShRSIOp>(op, adaptor.getValue(),
            shiftAmountMod64(rewriter, op.getLoc(), adaptor.getAmount()));
        return success();
    }
};

/**
 * Lowers `eco.int.shru` to a logical (zero-filling) right shift by the count modulo 64.
 */
struct IntShiftRightZfOpLowering : public OpConversionPattern<IntShiftRightZfOp> {
    using OpConversionPattern::OpConversionPattern;

    LogicalResult
    matchAndRewrite(IntShiftRightZfOp op, OpAdaptor adaptor,
                    ConversionPatternRewriter &rewriter) const override {
        rewriter.replaceOpWithNewOp<arith::ShRUIOp>(op, adaptor.getValue(),
            shiftAmountMod64(rewriter, op.getLoc(), adaptor.getAmount()));
        return success();
    }
};

//===----------------------------------------------------------------------===//
// Boolean Operations
//===----------------------------------------------------------------------===//

/**
 * Lowers Bool `not` to an exclusive or with 1.
 */
struct BoolNotOpLowering : public OpConversionPattern<BoolNotOp> {
    using OpConversionPattern::OpConversionPattern;

    LogicalResult
    matchAndRewrite(BoolNotOp op, OpAdaptor adaptor,
                    ConversionPatternRewriter &rewriter) const override {
        auto loc = op.getLoc();
        auto one = rewriter.create<arith::ConstantIntOp>(loc, 1, /*width=*/1);
        rewriter.replaceOpWithNewOp<arith::XOrIOp>(op, adaptor.getValue(), one);
        return success();
    }
};

/**
 * Lowers Bool `&&` on i1 values to `arith.andi`; both operands are already evaluated.
 */
struct BoolAndOpLowering : public OpConversionPattern<BoolAndOp> {
    using OpConversionPattern::OpConversionPattern;

    LogicalResult
    matchAndRewrite(BoolAndOp op, OpAdaptor adaptor,
                    ConversionPatternRewriter &rewriter) const override {
        rewriter.replaceOpWithNewOp<arith::AndIOp>(op, adaptor.getLhs(), adaptor.getRhs());
        return success();
    }
};

/**
 * Lowers Bool `||` on i1 values to `arith.ori`; both operands are already evaluated.
 */
struct BoolOrOpLowering : public OpConversionPattern<BoolOrOp> {
    using OpConversionPattern::OpConversionPattern;

    LogicalResult
    matchAndRewrite(BoolOrOp op, OpAdaptor adaptor,
                    ConversionPatternRewriter &rewriter) const override {
        rewriter.replaceOpWithNewOp<arith::OrIOp>(op, adaptor.getLhs(), adaptor.getRhs());
        return success();
    }
};

/**
 * Lowers Bool `xor` to `arith.xori`.
 */
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

/**
 * Lowers `Char.toCode` to the code point, zero-extended from i32 to i64.
 */
struct CharToIntOpLowering : public OpConversionPattern<CharToIntOp> {
    using OpConversionPattern::OpConversionPattern;

    LogicalResult
    matchAndRewrite(CharToIntOp op, OpAdaptor adaptor,
                    ConversionPatternRewriter &rewriter) const override {
        auto i64Ty = IntegerType::get(rewriter.getContext(), 64);
        rewriter.replaceOpWithNewOp<arith::ExtUIOp>(op, i64Ty, adaptor.getValue());
        return success();
    }
};

/**
 * Lowers `Char.fromCode` to a truncation of the Int to i32 when it is in 0..0x10FFFF (surrogates
 * included), and to U+FFFD otherwise.
 */
struct CharFromIntOpLowering : public OpConversionPattern<CharFromIntOp> {
    using OpConversionPattern::OpConversionPattern;

    LogicalResult
    matchAndRewrite(CharFromIntOp op, OpAdaptor adaptor,
                    ConversionPatternRewriter &rewriter) const override {
        auto loc = op.getLoc();
        auto charTy = eco::getEcoCharType(rewriter.getContext());

        Value input = adaptor.getValue();

        // One unsigned compare checks both ends: a negative Int is a huge
        // unsigned value.
        Value limit = rewriter.create<arith::ConstantIntOp>(loc, 0x110000, /*width=*/64);
        Value inRange = rewriter.create<arith::CmpIOp>(
            loc, arith::CmpIPredicate::ult, input, limit);
        Value truncated = rewriter.create<arith::TruncIOp>(loc, charTy, input);
        Value replacement =
            rewriter.create<arith::ConstantIntOp>(loc, 0xFFFD, /*width=*/eco::kEcoCharBits);
        rewriter.replaceOpWithNewOp<arith::SelectOp>(op, inRange, truncated, replacement);
        return success();
    }
};

//===----------------------------------------------------------------------===//
// Char Comparisons
//===----------------------------------------------------------------------===//

/**
 * Lowers Char `<` to an unsigned comparison of the code points (KERN_008).
 */
struct CharLtOpLowering : public OpConversionPattern<CharLtOp> {
    using OpConversionPattern::OpConversionPattern;

    LogicalResult
    matchAndRewrite(CharLtOp op, OpAdaptor adaptor,
                    ConversionPatternRewriter &rewriter) const override {
        rewriter.replaceOpWithNewOp<arith::CmpIOp>(
            op, arith::CmpIPredicate::ult,
            adaptor.getLhs(), adaptor.getRhs());
        return success();
    }
};

/**
 * Lowers Char `<=` to an unsigned comparison of the code points.
 */
struct CharLeOpLowering : public OpConversionPattern<CharLeOp> {
    using OpConversionPattern::OpConversionPattern;

    LogicalResult
    matchAndRewrite(CharLeOp op, OpAdaptor adaptor,
                    ConversionPatternRewriter &rewriter) const override {
        rewriter.replaceOpWithNewOp<arith::CmpIOp>(
            op, arith::CmpIPredicate::ule,
            adaptor.getLhs(), adaptor.getRhs());
        return success();
    }
};

/**
 * Lowers Char `>` to an unsigned comparison of the code points.
 */
struct CharGtOpLowering : public OpConversionPattern<CharGtOp> {
    using OpConversionPattern::OpConversionPattern;

    LogicalResult
    matchAndRewrite(CharGtOp op, OpAdaptor adaptor,
                    ConversionPatternRewriter &rewriter) const override {
        rewriter.replaceOpWithNewOp<arith::CmpIOp>(
            op, arith::CmpIPredicate::ugt,
            adaptor.getLhs(), adaptor.getRhs());
        return success();
    }
};

/**
 * Lowers Char `>=` to an unsigned comparison of the code points.
 */
struct CharGeOpLowering : public OpConversionPattern<CharGeOp> {
    using OpConversionPattern::OpConversionPattern;

    LogicalResult
    matchAndRewrite(CharGeOp op, OpAdaptor adaptor,
                    ConversionPatternRewriter &rewriter) const override {
        rewriter.replaceOpWithNewOp<arith::CmpIOp>(
            op, arith::CmpIPredicate::uge,
            adaptor.getLhs(), adaptor.getRhs());
        return success();
    }
};

/**
 * Lowers Char `==` to an integer equality comparison.
 */
struct CharEqOpLowering : public OpConversionPattern<CharEqOp> {
    using OpConversionPattern::OpConversionPattern;

    LogicalResult
    matchAndRewrite(CharEqOp op, OpAdaptor adaptor,
                    ConversionPatternRewriter &rewriter) const override {
        rewriter.replaceOpWithNewOp<arith::CmpIOp>(
            op, arith::CmpIPredicate::eq, adaptor.getLhs(), adaptor.getRhs());
        return success();
    }
};

/**
 * Lowers Char `/=` to an integer inequality comparison.
 */
struct CharNeOpLowering : public OpConversionPattern<CharNeOp> {
    using OpConversionPattern::OpConversionPattern;

    LogicalResult
    matchAndRewrite(CharNeOp op, OpAdaptor adaptor,
                    ConversionPatternRewriter &rewriter) const override {
        rewriter.replaceOpWithNewOp<arith::CmpIOp>(
            op, arith::CmpIPredicate::ne, adaptor.getLhs(), adaptor.getRhs());
        return success();
    }
};

//===----------------------------------------------------------------------===//
// Compare-to-Order (Int/Float/Char/String)
//===----------------------------------------------------------------------===//

namespace {

// Returns whether an `Order` is chosen by one call to `eco_order_from_sign`. It is true unless
// `ECO_ORDER_FROM_SIGN` is exactly `0`; the variable is read once per process.
static bool orderFromSignEnabled() {
    static const bool on = [] {
        const char *e = ::getenv("ECO_ORDER_FROM_SIGN");
        return !(e && e[0] == '0' && e[1] == '\0');
    }();
    return on;
}

// Emits the `Order` value for a comparison whose results are `isLt` and `isGt`: `LT` when `isLt`
// holds, else `GT` when `isGt` holds, else `EQ`, so `isLt` wins if both hold.
//
// By default the two flags become a sign of -1, 0 or 1 in i64 and one call to `eco_order_from_sign`
// returns the value (CGEN_075). When `orderFromSignEnabled` is false, the three `Order` values are
// fetched by calls to `Eco_Runtime_getOrderLT`, `Eco_Runtime_getOrderEQ` and `Eco_Runtime_getOrderGT`
// and selected between.
static Value emitOrderSelect(Location loc, Value isLt, Value isGt,
                              const EcoRuntime &runtime,
                              ConversionPatternRewriter &rewriter) {
    if (orderFromSignEnabled()) {
        auto i64Ty = rewriter.getIntegerType(64);
        Value neg1 = rewriter.create<LLVM::ConstantOp>(
            loc, i64Ty, rewriter.getI64IntegerAttr(-1));
        Value zero = rewriter.create<LLVM::ConstantOp>(
            loc, i64Ty, rewriter.getI64IntegerAttr(0));
        Value one = rewriter.create<LLVM::ConstantOp>(
            loc, i64Ty, rewriter.getI64IntegerAttr(1));
        Value gtOrEq = rewriter.create<LLVM::SelectOp>(loc, isGt, one, zero);
        Value sign = rewriter.create<LLVM::SelectOp>(loc, isLt, neg1, gtOrEq);
        auto fn = runtime.getOrCreateOrderFromSign(rewriter);
        return rewriter.create<LLVM::CallOp>(loc, fn, ValueRange{sign})
            .getResult();
    }
    auto ltFn = runtime.getOrCreateGetOrderLT(rewriter);
    auto eqFn = runtime.getOrCreateGetOrderEQ(rewriter);
    auto gtFn = runtime.getOrCreateGetOrderGT(rewriter);
    Value lt = rewriter.create<LLVM::CallOp>(loc, ltFn, ValueRange{}).getResult();
    Value eq = rewriter.create<LLVM::CallOp>(loc, eqFn, ValueRange{}).getResult();
    Value gt = rewriter.create<LLVM::CallOp>(loc, gtFn, ValueRange{}).getResult();
    Value gtOrEq = rewriter.create<LLVM::SelectOp>(loc, isGt, gt, eq);
    return rewriter.create<LLVM::SelectOp>(loc, isLt, lt, gtOrEq);
}

} // namespace

/**
 * Lowers `eco.int.cmp_order` to signed comparisons and `emitOrderSelect`.
 */
struct IntCmpOrderOpLowering : public OpConversionPattern<IntCmpOrderOp> {
    // Declares the runtime functions this pattern calls.
    const EcoRuntime &runtime;

    // Creates the pattern. It keeps references to `typeConverter` and `runtime`, which must outlive it.
    IntCmpOrderOpLowering(EcoTypeConverter &typeConverter, MLIRContext *ctx,
                          const EcoRuntime &runtime)
        : OpConversionPattern(typeConverter, ctx), runtime(runtime) {}

    LogicalResult
    matchAndRewrite(IntCmpOrderOp op, OpAdaptor adaptor,
                    ConversionPatternRewriter &rewriter) const override {
        auto loc = op.getLoc();
        Value isLt = rewriter.create<arith::CmpIOp>(
            loc, arith::CmpIPredicate::slt, adaptor.getLhs(), adaptor.getRhs());
        Value isGt = rewriter.create<arith::CmpIOp>(
            loc, arith::CmpIPredicate::sgt, adaptor.getLhs(), adaptor.getRhs());
        rewriter.replaceOp(op, emitOrderSelect(loc, isLt, isGt, runtime, rewriter));
        return success();
    }
};

/**
 * Lowers `eco.float.cmp_order` to comparisons and `emitOrderSelect`, as Float's total order
 * (CGEN_086): NaN equals NaN and is above every number, -0 equals +0. LT is `a < b`, or `b` NaN and
 * `a` not; GT is `a > b`, or `a` NaN and `b` not; EQ is the rest (equal, or both NaN). These tests
 * are repeated in the `EcoCompareCaseRewrite` pass and must change with it.
 */
struct FloatCmpOrderOpLowering : public OpConversionPattern<FloatCmpOrderOp> {
    // Declares the runtime functions this pattern calls.
    const EcoRuntime &runtime;

    // Creates the pattern. It keeps references to `typeConverter` and `runtime`, which must outlive it.
    FloatCmpOrderOpLowering(EcoTypeConverter &typeConverter, MLIRContext *ctx,
                            const EcoRuntime &runtime)
        : OpConversionPattern(typeConverter, ctx), runtime(runtime) {}

    LogicalResult
    matchAndRewrite(FloatCmpOrderOp op, OpAdaptor adaptor,
                    ConversionPatternRewriter &rewriter) const override {
        auto loc = op.getLoc();
        Value a = adaptor.getLhs(), b = adaptor.getRhs();
        auto cmp = [&](arith::CmpFPredicate p, Value x, Value y) -> Value {
            return rewriter.create<arith::CmpFOp>(loc, p, x, y);
        };
        Value aNaN = cmp(arith::CmpFPredicate::UNO, a, a);
        Value bNaN = cmp(arith::CmpFPredicate::UNO, b, b);
        Value aNum = cmp(arith::CmpFPredicate::ORD, a, a);
        Value bNum = cmp(arith::CmpFPredicate::ORD, b, b);
        Value isLt = rewriter.create<arith::OrIOp>(
            loc, cmp(arith::CmpFPredicate::OLT, a, b), rewriter.create<arith::AndIOp>(loc, bNaN, aNum));
        Value isGt = rewriter.create<arith::OrIOp>(
            loc, cmp(arith::CmpFPredicate::OGT, a, b), rewriter.create<arith::AndIOp>(loc, aNaN, bNum));
        rewriter.replaceOp(op, emitOrderSelect(loc, isLt, isGt, runtime, rewriter));
        return success();
    }
};

/**
 * Lowers `eco.char.cmp_order` to unsigned comparisons of the code points and `emitOrderSelect`.
 */
struct CharCmpOrderOpLowering : public OpConversionPattern<CharCmpOrderOp> {
    // Declares the runtime functions this pattern calls.
    const EcoRuntime &runtime;

    // Creates the pattern. It keeps references to `typeConverter` and `runtime`, which must outlive it.
    CharCmpOrderOpLowering(EcoTypeConverter &typeConverter, MLIRContext *ctx,
                           const EcoRuntime &runtime)
        : OpConversionPattern(typeConverter, ctx), runtime(runtime) {}

    LogicalResult
    matchAndRewrite(CharCmpOrderOp op, OpAdaptor adaptor,
                    ConversionPatternRewriter &rewriter) const override {
        auto loc = op.getLoc();
        Value lhs = adaptor.getLhs();
        Value rhs = adaptor.getRhs();
        Value isLt = rewriter.create<arith::CmpIOp>(
            loc, arith::CmpIPredicate::ult, lhs, rhs);
        Value isGt = rewriter.create<arith::CmpIOp>(
            loc, arith::CmpIPredicate::ugt, lhs, rhs);
        rewriter.replaceOp(op, emitOrderSelect(loc, isLt, isGt, runtime, rewriter));
        return success();
    }
};

// String compares do not use emitOrderSelect: the comparison is already a runtime call, and having
// that call return the `Order` value as well needs no second call.
/**
 * Lowers `eco.string.cmp_order` to one call to `eco_string_cmp_order`, which compares the strings
 * and returns the `Order` value.
 */
struct StringCmpOrderOpLowering : public OpConversionPattern<StringCmpOrderOp> {
    // Declares the runtime functions this pattern calls.
    const EcoRuntime &runtime;

    // Creates the pattern. It keeps references to `typeConverter` and `runtime`, which must outlive it.
    StringCmpOrderOpLowering(EcoTypeConverter &typeConverter, MLIRContext *ctx,
                             const EcoRuntime &runtime)
        : OpConversionPattern(typeConverter, ctx), runtime(runtime) {}

    LogicalResult
    matchAndRewrite(StringCmpOrderOp op, OpAdaptor adaptor,
                    ConversionPatternRewriter &rewriter) const override {
        auto fn = runtime.getOrCreateStringCmpOrder(rewriter);
        rewriter.replaceOpWithNewOp<LLVM::CallOp>(
            op, fn, ValueRange{adaptor.getLhs(), adaptor.getRhs()});
        return success();
    }
};

// The fast and slow paths of value equality need new blocks, which cannot be built inside a
// region that the dialect conversion is still converting; a marker expanded later at LLVM IR level
// avoids that.
/**
 * Lowers `eco.value.eq` to a call to the marker `__eco_value_eq`, which the backend replaces with
 * inline equality code before RS4GC (CGEN_076).
 */
struct ValueEqOpLowering : public OpConversionPattern<ValueEqOp> {
    // Declares the `__eco_value_eq` marker this pattern calls.
    const EcoRuntime &runtime;

    // Creates the pattern. It keeps references to `typeConverter` and `runtime`, which must outlive it.
    ValueEqOpLowering(EcoTypeConverter &typeConverter, MLIRContext *ctx,
                      const EcoRuntime &runtime)
        : OpConversionPattern(typeConverter, ctx), runtime(runtime) {}

    LogicalResult
    matchAndRewrite(ValueEqOp op, OpAdaptor adaptor,
                    ConversionPatternRewriter &rewriter) const override {
        auto fn = runtime.getOrCreateValueEqMarker(rewriter);
        rewriter.replaceOpWithNewOp<LLVM::CallOp>(
            op, fn, ValueRange{adaptor.getLhs(), adaptor.getRhs()});
        return success();
    }
};

/**
 * Lowers `eco.string.cmp3` to a call to `eco_string_cmp3`, whose i64 result has the sign of the
 * comparison; its magnitude means nothing.
 */
struct StringCmp3OpLowering : public OpConversionPattern<StringCmp3Op> {
    // Declares the runtime functions this pattern calls.
    const EcoRuntime &runtime;

    // Creates the pattern. It keeps references to `typeConverter` and `runtime`, which must outlive it.
    StringCmp3OpLowering(EcoTypeConverter &typeConverter, MLIRContext *ctx,
                         const EcoRuntime &runtime)
        : OpConversionPattern(typeConverter, ctx), runtime(runtime) {}

    LogicalResult
    matchAndRewrite(StringCmp3Op op, OpAdaptor adaptor,
                    ConversionPatternRewriter &rewriter) const override {
        auto fn = runtime.getOrCreateStringCmp3(rewriter);
        rewriter.replaceOpWithNewOp<LLVM::CallOp>(
            op, fn, ValueRange{adaptor.getLhs(), adaptor.getRhs()});
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
        CharFromIntOpLowering,
        CharLtOpLowering,
        CharLeOpLowering,
        CharGtOpLowering,
        CharGeOpLowering,
        CharEqOpLowering,
        CharNeOpLowering
    >(typeConverter, ctx);
}

void eco::detail::populateEcoArithPatternsWithRuntime(
    EcoTypeConverter &typeConverter,
    RewritePatternSet &patterns,
    const EcoRuntime &runtime) {

    auto *ctx = patterns.getContext();
    patterns.add<IntPowOpLowering>(typeConverter, ctx, runtime);
    patterns.add<FloatAsinOpLowering>(typeConverter, ctx, runtime);
    patterns.add<FloatAcosOpLowering>(typeConverter, ctx, runtime);
    patterns.add<FloatAtanOpLowering>(typeConverter, ctx, runtime);
    patterns.add<FloatAtan2OpLowering>(typeConverter, ctx, runtime);
    patterns.add<IntCmpOrderOpLowering>(typeConverter, ctx, runtime);
    patterns.add<FloatCmpOrderOpLowering>(typeConverter, ctx, runtime);
    patterns.add<CharCmpOrderOpLowering>(typeConverter, ctx, runtime);
    patterns.add<StringCmpOrderOpLowering>(typeConverter, ctx, runtime);
    patterns.add<StringCmp3OpLowering>(typeConverter, ctx, runtime);
    patterns.add<ValueEqOpLowering>(typeConverter, ctx, runtime);
}
