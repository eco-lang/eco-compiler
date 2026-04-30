//===- EcoToLLVMHeap.cpp - Heap operation lowering patterns ---------------===//
//
// This file implements lowering patterns for ECO heap operations:
// box, unbox, allocate, construct, and project operations.
//
// Allocation ops are lowered to calls to runtime C ABI functions (eco_alloc_*).
// These functions may trigger GC. GC root tracking is handled by LLVM's
// RewriteStatepointsForGC (RS4GC) pass, which automatically inserts
// gc.statepoint/gc.relocate around calls to non-gc-leaf functions in
// functions with gc "eco-gc". GC pointers are identified as ptr addrspace(1).
//
// Fast/slow allocation splitting is available in the runtime (eco_alloc_*_fast/slow)
// but is not yet used in codegen — allocation calls use the unified functions
// that handle GC internally. The fast/slow split will be enabled once the
// statepoint-based approach is validated.
//
//===----------------------------------------------------------------------===//

#include "EcoToLLVMInternal.h"
#include "../EcoDialect.h"
#include "../EcoOps.h"
#include "../EcoTypes.h"

#include "mlir/Dialect/ControlFlow/IR/ControlFlowOps.h"
#include "mlir/Dialect/Func/IR/FuncOps.h"

using namespace mlir;
using namespace eco;
using namespace eco::detail;

namespace {

//===----------------------------------------------------------------------===//
// Allocation coalescing helpers (Phase 4 infrastructure)
//===----------------------------------------------------------------------===//

/// Compute the aligned allocation size for a given Eco allocation op.
/// Returns 0 if the size cannot be statically determined.
static int64_t computeAllocSize(Operation *op) {
    constexpr int64_t HeaderSize = 8;
    constexpr int64_t UnboxableSize = 8;

    if (auto allocCtor = dyn_cast<eco::AllocateCtorOp>(op)) {
        int64_t size = HeaderSize + 8 + allocCtor.getSize() * UnboxableSize +
                       allocCtor.getScalarBytes();
        return (size + 7) & ~7;
    }
    if (auto allocStr = dyn_cast<eco::AllocateStringOp>(op)) {
        int64_t size = HeaderSize + allocStr.getLength() * 2;
        return (size + 7) & ~7;
    }
    if (isa<eco::ListConstructOp>(op)) return 24;
    if (isa<eco::Tuple2ConstructOp>(op)) return 24;
    if (isa<eco::Tuple3ConstructOp>(op)) return 32;
    if (auto recOp = dyn_cast<eco::RecordConstructOp>(op)) {
        int64_t size = HeaderSize + 8 + recOp.getFieldCount() * UnboxableSize;
        return (size + 7) & ~7;
    }
    if (auto customOp = dyn_cast<eco::CustomConstructOp>(op)) {
        int64_t size = HeaderSize + 8 + customOp.getSize() * UnboxableSize;
        return (size + 7) & ~7;
    }
    if (auto boxOp = dyn_cast<eco::BoxOp>(op)) {
        Type inputType = boxOp.getValue().getType();
        if (inputType.isInteger(64) || inputType.isF64() || inputType.isInteger(16))
            return 16;
        return 0;
    }
    return 0;
}

//===----------------------------------------------------------------------===//
// eco.box -> call eco_alloc_* + ptrtoint
//===----------------------------------------------------------------------===//

struct BoxOpLowering : public OpConversionPattern<BoxOp> {
    const EcoRuntime &runtime;

    BoxOpLowering(EcoTypeConverter &typeConverter, MLIRContext *ctx,
                  const EcoRuntime &runtime)
        : OpConversionPattern(typeConverter, ctx), runtime(runtime) {}

    LogicalResult
    matchAndRewrite(BoxOp op, OpAdaptor adaptor,
                    ConversionPatternRewriter &rewriter) const override {
        auto loc = op.getLoc();
        auto *ctx = rewriter.getContext();
        auto i64Ty = IntegerType::get(ctx, 64);

        Value input = adaptor.getValue();
        Type inputType = input.getType();
        Value result;

        auto liveRoots = adaptor.getLiveRoots();

        if (inputType.isInteger(64)) {
            // Box i64 -> eco_alloc_int with safepoint marker
            result = emitAllocWithSafepoint(
                op, rewriter, runtime,
                runtime.getOrCreateAllocInt(rewriter),
                ValueRange{input}, liveRoots);
        } else if (inputType.isF64()) {
            // Box f64 -> eco_alloc_float with safepoint marker
            result = emitAllocWithSafepoint(
                op, rewriter, runtime,
                runtime.getOrCreateAllocFloat(rewriter),
                ValueRange{input}, liveRoots);
        } else if (inputType.isInteger(16)) {
            // Box i16 (char) -> eco_alloc_char with safepoint marker
            result = emitAllocWithSafepoint(
                op, rewriter, runtime,
                runtime.getOrCreateAllocChar(rewriter),
                ValueRange{input}, liveRoots);
        } else if (inputType.isInteger(1)) {
            // Box i1 (bool) -> use embedded constant True/False (no allocation)
            auto hptrTy = getHPtrLLVMType(*ctx);
            Value trueI64 = rewriter.create<LLVM::ConstantOp>(
                loc, i64Ty, value_enc::encodeConstant(value_enc::True));
            Value trueCst = rewriter.create<LLVM::IntToPtrOp>(loc, hptrTy, trueI64);
            Value falseI64 = rewriter.create<LLVM::ConstantOp>(
                loc, i64Ty, value_enc::encodeConstant(value_enc::False));
            Value falseCst = rewriter.create<LLVM::IntToPtrOp>(loc, hptrTy, falseI64);
            result = rewriter.create<LLVM::SelectOp>(loc, input, trueCst, falseCst);
        } else {
            return op.emitError("unsupported type for boxing: ") << inputType;
        }

        rewriter.replaceOp(op, result);
        return success();
    }
};

//===----------------------------------------------------------------------===//
// eco.unbox -> inttoptr + gep + load
//===----------------------------------------------------------------------===//

struct UnboxOpLowering : public OpConversionPattern<UnboxOp> {
    const EcoRuntime &runtime;

    UnboxOpLowering(EcoTypeConverter &typeConverter, MLIRContext *ctx,
                    const EcoRuntime &runtime)
        : OpConversionPattern(typeConverter, ctx), runtime(runtime) {}

    LogicalResult
    matchAndRewrite(UnboxOp op, OpAdaptor adaptor,
                    ConversionPatternRewriter &rewriter) const override {
        auto loc = op.getLoc();
        auto *ctx = rewriter.getContext();
        auto i64Ty = IntegerType::get(ctx, 64);
        auto ptrTy = LLVM::LLVMPointerType::get(ctx);
        auto i8Ty = IntegerType::get(ctx, 8);
        auto i1Ty = IntegerType::get(ctx, 1);

        Value input = adaptor.getValue();
        Type resultType = getTypeConverter()->convertType(op.getResult().getType());

        // Special case for i1 (Bool): boxed bools are embedded constants
        if (resultType == i1Ty) {
            auto hptrTy = getHPtrLLVMType(*ctx);
            Value trueI64 = rewriter.create<LLVM::ConstantOp>(
                loc, i64Ty, value_enc::encodeConstant(value_enc::True));
            Value trueConst = rewriter.create<LLVM::IntToPtrOp>(loc, hptrTy, trueI64);
            Value result = rewriter.create<LLVM::ICmpOp>(
                loc, LLVM::ICmpPredicate::eq, input, trueConst);
            rewriter.replaceOp(op, result);
            return success();
        }

        // Convert HPointer to raw pointer via runtime function
        auto resolveFunc = runtime.getOrCreateResolveHPtr(rewriter);
        auto resolveCall = rewriter.create<LLVM::CallOp>(loc, resolveFunc, ValueRange{input});
        Value ptr = resolveCall.getResult();

        // Offset 8 bytes past the Header to access the value field
        auto offset = rewriter.create<LLVM::ConstantOp>(loc, i64Ty, layout::HeaderSize);
        auto valuePtr = rewriter.create<LLVM::GEPOp>(loc, ptrTy, i8Ty, ptr,
                                                      ValueRange{offset});

        // Load the unboxed value
        Value result = rewriter.create<LLVM::LoadOp>(loc, resultType, valuePtr);
        rewriter.replaceOp(op, result);
        return success();
    }
};

//===----------------------------------------------------------------------===//
// eco.allocate -> call eco_allocate + ptrtoint
//===----------------------------------------------------------------------===//

struct AllocateOpLowering : public OpConversionPattern<AllocateOp> {
    const EcoRuntime &runtime;

    AllocateOpLowering(EcoTypeConverter &typeConverter, MLIRContext *ctx,
                       const EcoRuntime &runtime)
        : OpConversionPattern(typeConverter, ctx), runtime(runtime) {}

    LogicalResult
    matchAndRewrite(AllocateOp op, OpAdaptor adaptor,
                    ConversionPatternRewriter &rewriter) const override {
        auto loc = op.getLoc();
        auto *ctx = rewriter.getContext();
        auto i32Ty = IntegerType::get(ctx, 32);

        auto size = adaptor.getSize();
        auto tag = rewriter.create<LLVM::ConstantOp>(loc, i32Ty, 7);  // Tag_Custom

        Value result = emitAllocWithSafepoint(
            op, rewriter, runtime,
            runtime.getOrCreateAllocate(rewriter),
            ValueRange{size, tag},
            adaptor.getLiveRoots());
        rewriter.replaceOp(op, result);
        return success();
    }
};

//===----------------------------------------------------------------------===//
// eco.allocate_ctor -> call eco_alloc_custom
//===----------------------------------------------------------------------===//

struct AllocateCtorOpLowering : public OpConversionPattern<AllocateCtorOp> {
    const EcoRuntime &runtime;

    AllocateCtorOpLowering(EcoTypeConverter &typeConverter, MLIRContext *ctx,
                           const EcoRuntime &runtime)
        : OpConversionPattern(typeConverter, ctx), runtime(runtime) {}

    LogicalResult
    matchAndRewrite(AllocateCtorOp op, OpAdaptor adaptor,
                    ConversionPatternRewriter &rewriter) const override {
        auto loc = op.getLoc();
        auto *ctx = rewriter.getContext();
        auto i32Ty = IntegerType::get(ctx, 32);

        auto tag = rewriter.create<LLVM::ConstantOp>(
            loc, i32Ty, static_cast<int32_t>(op.getTag()));
        auto size = rewriter.create<LLVM::ConstantOp>(
            loc, i32Ty, static_cast<int32_t>(op.getSize()));
        auto scalarBytes = rewriter.create<LLVM::ConstantOp>(
            loc, i32Ty, static_cast<int32_t>(op.getScalarBytes()));

        Value result = emitAllocWithSafepoint(
            op, rewriter, runtime,
            runtime.getOrCreateAllocCustom(rewriter),
            ValueRange{tag, size, scalarBytes},
            adaptor.getLiveRoots());
        rewriter.replaceOp(op, result);
        return success();
    }
};

//===----------------------------------------------------------------------===//
// eco.allocate_string -> call eco_alloc_string
//===----------------------------------------------------------------------===//

struct AllocateStringOpLowering : public OpConversionPattern<AllocateStringOp> {
    const EcoRuntime &runtime;

    AllocateStringOpLowering(EcoTypeConverter &typeConverter, MLIRContext *ctx,
                             const EcoRuntime &runtime)
        : OpConversionPattern(typeConverter, ctx), runtime(runtime) {}

    LogicalResult
    matchAndRewrite(AllocateStringOp op, OpAdaptor adaptor,
                    ConversionPatternRewriter &rewriter) const override {
        auto loc = op.getLoc();
        auto *ctx = rewriter.getContext();
        auto i32Ty = IntegerType::get(ctx, 32);

        auto length = rewriter.create<LLVM::ConstantOp>(
            loc, i32Ty, static_cast<int32_t>(op.getLength()));

        Value result = emitAllocWithSafepoint(
            op, rewriter, runtime,
            runtime.getOrCreateAllocString(rewriter),
            ValueRange{length},
            adaptor.getLiveRoots());
        rewriter.replaceOp(op, result);
        return success();
    }
};

//===----------------------------------------------------------------------===//
// eco.construct.list -> call eco_alloc_cons
//===----------------------------------------------------------------------===//

struct ListConstructOpLowering : public OpConversionPattern<ListConstructOp> {
    const EcoRuntime &runtime;

    ListConstructOpLowering(EcoTypeConverter &typeConverter, MLIRContext *ctx,
                            const EcoRuntime &runtime)
        : OpConversionPattern(typeConverter, ctx), runtime(runtime) {}

    LogicalResult
    matchAndRewrite(ListConstructOp op, OpAdaptor adaptor,
                    ConversionPatternRewriter &rewriter) const override {
        auto loc = op.getLoc();
        auto *ctx = rewriter.getContext();
        auto i32Ty = IntegerType::get(ctx, 32);
        auto i64Ty = IntegerType::get(ctx, 64);

        Value headVal = adaptor.getHead();
        Value tailVal = adaptor.getTail();
        // Pass the 2-bit head kind (0=boxed, 1=Int, 2=Float, 3=Char) directly.
        uint32_t headKind = static_cast<uint32_t>(op.getHeadKind()) & 0x3;
        auto headUnboxedVal = rewriter.create<LLVM::ConstantOp>(loc, i32Ty, headKind);

        // eco_alloc_cons expects i64 for head, hptr for tail
        headVal = heapStoreValueToI64(rewriter, loc, headVal);
        if (auto intTy = dyn_cast<IntegerType>(headVal.getType())) {
            if (intTy.getWidth() < 64) {
                headVal = rewriter.create<LLVM::ZExtOp>(loc, i64Ty, headVal);
            }
        } else if (headVal.getType().isF64()) {
            headVal = rewriter.create<LLVM::BitcastOp>(loc, i64Ty, headVal);
        }
        // tailVal is already ptr<1> from the adaptor — pass directly

        Value result = emitAllocWithSafepoint(
            op, rewriter, runtime,
            runtime.getOrCreateAllocCons(rewriter),
            ValueRange{headVal, tailVal, headUnboxedVal},
            adaptor.getLiveRoots());
        rewriter.replaceOp(op, result);
        return success();
    }
};

//===----------------------------------------------------------------------===//
// eco.project.list_head -> load from Cons.head (offset 8)
// For primitive result types (i64, f64), uses runtime helpers that handle
// both boxed and unboxed heads transparently.
//===----------------------------------------------------------------------===//

struct ListHeadOpLowering : public OpConversionPattern<ListHeadOp> {
    const EcoRuntime &runtime;

    ListHeadOpLowering(EcoTypeConverter &typeConverter, MLIRContext *ctx,
                       const EcoRuntime &runtime)
        : OpConversionPattern(typeConverter, ctx), runtime(runtime) {}

    LogicalResult
    matchAndRewrite(ListHeadOp op, OpAdaptor adaptor,
                    ConversionPatternRewriter &rewriter) const override {
        auto loc = op.getLoc();
        auto *ctx = rewriter.getContext();
        Value input = adaptor.getList();

        // Check the original ECO result type to decide how to extract the head.
        Type origResultType = op.getResult().getType();

        // For primitive types (i64, f64, i16), use runtime helpers that handle
        // both boxed and unboxed heads correctly.
        if (origResultType.isInteger(64)) {
            auto helperFunc = runtime.getOrCreateConsHeadI64(rewriter);
            auto call = rewriter.create<LLVM::CallOp>(loc, helperFunc, ValueRange{input});
            rewriter.replaceOp(op, call.getResult());
            return success();
        }
        if (origResultType.isF64()) {
            auto helperFunc = runtime.getOrCreateConsHeadF64(rewriter);
            auto call = rewriter.create<LLVM::CallOp>(loc, helperFunc, ValueRange{input});
            rewriter.replaceOp(op, call.getResult());
            return success();
        }
        if (origResultType.isInteger(16)) {
            auto helperFunc = runtime.getOrCreateConsHeadI16(rewriter);
            auto call = rewriter.create<LLVM::CallOp>(loc, helperFunc, ValueRange{input});
            rewriter.replaceOp(op, call.getResult());
            return success();
        }

        // For !eco.value (HPointer), load i64 from Cons.head then convert to ptr<1>.
        auto i64Ty = IntegerType::get(ctx, 64);
        auto i8Ty = IntegerType::get(ctx, 8);
        auto ptrTy = LLVM::LLVMPointerType::get(ctx);

        auto resolveFunc = runtime.getOrCreateResolveHPtr(rewriter);
        auto resolveCall = rewriter.create<LLVM::CallOp>(loc, resolveFunc, ValueRange{input});
        Value ptr = resolveCall.getResult();

        auto offset = rewriter.create<LLVM::ConstantOp>(loc, i64Ty, layout::ConsHeadOffset);
        auto fieldPtr = rewriter.create<LLVM::GEPOp>(loc, ptrTy, i8Ty, ptr,
                                                      ValueRange{offset});

        // Heap slots store i64; load i64 then convert to ptr<1>
        Value loaded = rewriter.create<LLVM::LoadOp>(loc, i64Ty, fieldPtr);
        Value result = heapLoadI64ToValue(rewriter, loc, loaded);
        rewriter.replaceOp(op, result);
        return success();
    }
};

//===----------------------------------------------------------------------===//
// eco.project.list_tail -> load from Cons.tail (offset 16)
//===----------------------------------------------------------------------===//

struct ListTailOpLowering : public OpConversionPattern<ListTailOp> {
    const EcoRuntime &runtime;

    ListTailOpLowering(EcoTypeConverter &typeConverter, MLIRContext *ctx,
                       const EcoRuntime &runtime)
        : OpConversionPattern(typeConverter, ctx), runtime(runtime) {}

    LogicalResult
    matchAndRewrite(ListTailOp op, OpAdaptor adaptor,
                    ConversionPatternRewriter &rewriter) const override {
        auto loc = op.getLoc();
        auto *ctx = rewriter.getContext();
        auto i64Ty = IntegerType::get(ctx, 64);
        auto i8Ty = IntegerType::get(ctx, 8);
        auto ptrTy = LLVM::LLVMPointerType::get(ctx);

        Value input = adaptor.getList();
        auto resolveFunc = runtime.getOrCreateResolveHPtr(rewriter);
        auto resolveCall = rewriter.create<LLVM::CallOp>(loc, resolveFunc, ValueRange{input});
        Value ptr = resolveCall.getResult();

        auto offset = rewriter.create<LLVM::ConstantOp>(loc, i64Ty, layout::ConsTailOffset);
        auto fieldPtr = rewriter.create<LLVM::GEPOp>(loc, ptrTy, i8Ty, ptr,
                                                      ValueRange{offset});

        // Heap slots store i64; load and convert to ptr<1>
        Value loaded = rewriter.create<LLVM::LoadOp>(loc, i64Ty, fieldPtr);
        Value result = i64ToValue(rewriter, loc, loaded);
        rewriter.replaceOp(op, result);
        return success();
    }
};

//===----------------------------------------------------------------------===//
// Helper: widen an SSA field value to i64 for runtime Unboxable slots.
// Only Int (i64), Float (f64), and Char (i16) are unboxed in heap fields.
// i64 and ptr (eco.value → i64) pass through unchanged.
//===----------------------------------------------------------------------===//

/// Widen an SSA field value to i64 for runtime Unboxable slots.
/// Caller must consume the result immediately in a store or gc-leaf call argument.
static Value widenFieldToI64(Value val, Location loc,
                             ConversionPatternRewriter &rewriter) {
    auto i64Ty = IntegerType::get(rewriter.getContext(), 64);
    Type ty = val.getType();
    if (isHPtrLLVMType(ty))
        return heapStoreValueToI64(rewriter, loc, val);
    if (auto intTy = dyn_cast<IntegerType>(ty)) {
        if (intTy.getWidth() < 64)
            return rewriter.create<LLVM::ZExtOp>(loc, i64Ty, val);
    } else if (ty.isF64()) {
        return rewriter.create<LLVM::BitcastOp>(loc, i64Ty, val);
    }
    return val;
}

//===----------------------------------------------------------------------===//
// eco.construct.tuple2 -> call eco_alloc_tuple2
//===----------------------------------------------------------------------===//

struct Tuple2ConstructOpLowering : public OpConversionPattern<Tuple2ConstructOp> {
    const EcoRuntime &runtime;

    Tuple2ConstructOpLowering(EcoTypeConverter &typeConverter, MLIRContext *ctx,
                              const EcoRuntime &runtime)
        : OpConversionPattern(typeConverter, ctx), runtime(runtime) {}

    LogicalResult
    matchAndRewrite(Tuple2ConstructOp op, OpAdaptor adaptor,
                    ConversionPatternRewriter &rewriter) const override {
        auto loc = op.getLoc();
        auto *ctx = rewriter.getContext();
        auto i32Ty = IntegerType::get(ctx, 32);

        auto aVal = widenFieldToI64(adaptor.getA(), loc, rewriter);
        auto bVal = widenFieldToI64(adaptor.getB(), loc, rewriter);
        int64_t unboxedMask = op.getUnboxedBitmap();
        auto unboxedVal = rewriter.create<LLVM::ConstantOp>(loc, i32Ty,
            static_cast<int32_t>(unboxedMask));

        Value result = emitAllocWithSafepoint(
            op, rewriter, runtime,
            runtime.getOrCreateAllocTuple2(rewriter),
            ValueRange{aVal, bVal, unboxedVal},
            adaptor.getLiveRoots());
        rewriter.replaceOp(op, result);
        return success();
    }
};

//===----------------------------------------------------------------------===//
// eco.construct.tuple3 -> call eco_alloc_tuple3
//===----------------------------------------------------------------------===//

struct Tuple3ConstructOpLowering : public OpConversionPattern<Tuple3ConstructOp> {
    const EcoRuntime &runtime;

    Tuple3ConstructOpLowering(EcoTypeConverter &typeConverter, MLIRContext *ctx,
                              const EcoRuntime &runtime)
        : OpConversionPattern(typeConverter, ctx), runtime(runtime) {}

    LogicalResult
    matchAndRewrite(Tuple3ConstructOp op, OpAdaptor adaptor,
                    ConversionPatternRewriter &rewriter) const override {
        auto loc = op.getLoc();
        auto *ctx = rewriter.getContext();
        auto i32Ty = IntegerType::get(ctx, 32);

        auto aVal = widenFieldToI64(adaptor.getA(), loc, rewriter);
        auto bVal = widenFieldToI64(adaptor.getB(), loc, rewriter);
        auto cVal = widenFieldToI64(adaptor.getC(), loc, rewriter);
        int64_t unboxedMask = op.getUnboxedBitmap();
        auto unboxedVal = rewriter.create<LLVM::ConstantOp>(loc, i32Ty,
            static_cast<int32_t>(unboxedMask));

        Value result = emitAllocWithSafepoint(
            op, rewriter, runtime,
            runtime.getOrCreateAllocTuple3(rewriter),
            ValueRange{aVal, bVal, cVal, unboxedVal},
            adaptor.getLiveRoots());
        rewriter.replaceOp(op, result);
        return success();
    }
};

//===----------------------------------------------------------------------===//
// eco.project.tuple2 -> load from Tuple2.a/b
//===----------------------------------------------------------------------===//

struct Tuple2ProjectOpLowering : public OpConversionPattern<Tuple2ProjectOp> {
    const EcoRuntime &runtime;

    Tuple2ProjectOpLowering(EcoTypeConverter &typeConverter, MLIRContext *ctx,
                            const EcoRuntime &runtime)
        : OpConversionPattern(typeConverter, ctx), runtime(runtime) {}

    LogicalResult
    matchAndRewrite(Tuple2ProjectOp op, OpAdaptor adaptor,
                    ConversionPatternRewriter &rewriter) const override {
        auto loc = op.getLoc();
        auto *ctx = rewriter.getContext();
        auto i64Ty = IntegerType::get(ctx, 64);
        auto i8Ty = IntegerType::get(ctx, 8);
        auto ptrTy = LLVM::LLVMPointerType::get(ctx);

        Value input = adaptor.getTuple();
        int64_t field = op.getField();

        auto resolveFunc = runtime.getOrCreateResolveHPtr(rewriter);
        auto resolveCall = rewriter.create<LLVM::CallOp>(loc, resolveFunc, ValueRange{input});
        Value ptr = resolveCall.getResult();

        // Tuple2 layout: Header (8) + a (8) + b (8)
        int64_t offsetBytes = layout::Tuple2FirstOffset + field * layout::PtrSize;
        auto offset = rewriter.create<LLVM::ConstantOp>(loc, i64Ty, offsetBytes);
        auto fieldPtr = rewriter.create<LLVM::GEPOp>(loc, ptrTy, i8Ty, ptr,
                                                      ValueRange{offset});

        Type resultType = getTypeConverter()->convertType(op.getResult().getType());
        if (isHPtrLLVMType(resultType)) {
            // Heap slots store i64; load i64 then convert to ptr<1>
            Value loaded = rewriter.create<LLVM::LoadOp>(loc, i64Ty, fieldPtr);
            rewriter.replaceOp(op, heapLoadI64ToValue(rewriter, loc, loaded));
        } else {
            Value result = rewriter.create<LLVM::LoadOp>(loc, resultType, fieldPtr);
            rewriter.replaceOp(op, result);
        }
        return success();
    }
};

//===----------------------------------------------------------------------===//
// eco.project.tuple3 -> load from Tuple3 fields
//===----------------------------------------------------------------------===//

struct Tuple3ProjectOpLowering : public OpConversionPattern<Tuple3ProjectOp> {
    const EcoRuntime &runtime;

    Tuple3ProjectOpLowering(EcoTypeConverter &typeConverter, MLIRContext *ctx,
                            const EcoRuntime &runtime)
        : OpConversionPattern(typeConverter, ctx), runtime(runtime) {}

    LogicalResult
    matchAndRewrite(Tuple3ProjectOp op, OpAdaptor adaptor,
                    ConversionPatternRewriter &rewriter) const override {
        auto loc = op.getLoc();
        auto *ctx = rewriter.getContext();
        auto i64Ty = IntegerType::get(ctx, 64);
        auto i8Ty = IntegerType::get(ctx, 8);
        auto ptrTy = LLVM::LLVMPointerType::get(ctx);

        Value input = adaptor.getTuple();
        int64_t field = op.getField();

        auto resolveFunc = runtime.getOrCreateResolveHPtr(rewriter);
        auto resolveCall = rewriter.create<LLVM::CallOp>(loc, resolveFunc, ValueRange{input});
        Value ptr = resolveCall.getResult();

        // Tuple3 layout: Header (8) + a (8) + b (8) + c (8)
        int64_t offsetBytes = layout::Tuple3FirstOffset + field * layout::PtrSize;
        auto offset = rewriter.create<LLVM::ConstantOp>(loc, i64Ty, offsetBytes);
        auto fieldPtr = rewriter.create<LLVM::GEPOp>(loc, ptrTy, i8Ty, ptr,
                                                      ValueRange{offset});

        Type resultType = getTypeConverter()->convertType(op.getResult().getType());
        if (isHPtrLLVMType(resultType)) {
            Value loaded = rewriter.create<LLVM::LoadOp>(loc, i64Ty, fieldPtr);
            rewriter.replaceOp(op, heapLoadI64ToValue(rewriter, loc, loaded));
        } else {
            Value result = rewriter.create<LLVM::LoadOp>(loc, resultType, fieldPtr);
            rewriter.replaceOp(op, result);
        }
        return success();
    }
};

//===----------------------------------------------------------------------===//
// eco.construct.record -> call eco_alloc_record, then store fields
//===----------------------------------------------------------------------===//

struct RecordConstructOpLowering : public OpConversionPattern<RecordConstructOp> {
    const EcoRuntime &runtime;

    RecordConstructOpLowering(EcoTypeConverter &typeConverter, MLIRContext *ctx,
                              const EcoRuntime &runtime)
        : OpConversionPattern(typeConverter, ctx), runtime(runtime) {}

    LogicalResult
    matchAndRewrite(RecordConstructOp op, OpAdaptor adaptor,
                    ConversionPatternRewriter &rewriter) const override {
        auto loc = op.getLoc();
        auto *ctx = rewriter.getContext();
        auto i32Ty = IntegerType::get(ctx, 32);
        auto i64Ty = IntegerType::get(ctx, 64);

        auto storeFunc = runtime.getOrCreateStoreRecordField(rewriter);
        auto storeI64Func = runtime.getOrCreateStoreRecordFieldI64(rewriter);
        auto storeF64Func = runtime.getOrCreateStoreRecordFieldF64(rewriter);

        int64_t fieldCount = op.getFieldCount();
        int64_t unboxedBitmap = op.getUnboxedBitmap();

        // The fields operand list may contain GC roots appended after
        // the actual fields by EcoGCPrepare. Split them using fieldCount.
        auto allOperands = adaptor.getFields();
        auto fields = allOperands.take_front(fieldCount);
        auto liveRoots = allOperands.drop_front(fieldCount);

        auto fieldCountVal = rewriter.create<LLVM::ConstantOp>(loc, i32Ty,
            static_cast<int32_t>(fieldCount));
        auto unboxedBitmapVal = rewriter.create<LLVM::ConstantOp>(loc, i64Ty, unboxedBitmap);

        Value objHPtr = emitAllocWithSafepoint(
            op, rewriter, runtime,
            runtime.getOrCreateAllocRecord(rewriter),
            ValueRange{fieldCountVal, unboxedBitmapVal},
            liveRoots);

        // Store each field (rewriter is now in contBlock)
        auto origFields = op.getFields();
        for (int64_t i = 0; i < fieldCount; i++) {
            auto idx = rewriter.create<LLVM::ConstantOp>(loc, i32Ty, static_cast<int32_t>(i));
            Type origType = origFields[i].getType();
            Value fieldVal = fields[i];

            if (origType.isF64()) {
                rewriter.create<LLVM::CallOp>(loc, storeF64Func,
                    ValueRange{objHPtr, idx, fieldVal});
            } else if (origType.isInteger(64)) {
                rewriter.create<LLVM::CallOp>(loc, storeI64Func,
                    ValueRange{objHPtr, idx, fieldVal});
            } else if (origType.isInteger(1) || origType.isInteger(16)) {
                // Bool (i1) or Char (i16): after type conversion, Bool may be
                // ptr<1> (embedded constant). widenFieldToI64 handles all cases.
                Value widened = widenFieldToI64(fieldVal, loc, rewriter);
                rewriter.create<LLVM::CallOp>(loc, storeI64Func,
                    ValueRange{objHPtr, idx, widened});
            } else {
                // eco.value → ptr<1> from adaptor; pass directly (store takes hptr val)
                rewriter.create<LLVM::CallOp>(loc, storeFunc,
                    ValueRange{objHPtr, idx, fieldVal});
            }
        }

        rewriter.replaceOp(op, objHPtr);
        return success();
    }
};

//===----------------------------------------------------------------------===//
// eco.project.record -> load from Record.values[index]
//===----------------------------------------------------------------------===//

struct RecordProjectOpLowering : public OpConversionPattern<RecordProjectOp> {
    const EcoRuntime &runtime;

    RecordProjectOpLowering(EcoTypeConverter &typeConverter, MLIRContext *ctx,
                            const EcoRuntime &runtime)
        : OpConversionPattern(typeConverter, ctx), runtime(runtime) {}

    LogicalResult
    matchAndRewrite(RecordProjectOp op, OpAdaptor adaptor,
                    ConversionPatternRewriter &rewriter) const override {
        auto loc = op.getLoc();
        auto *ctx = rewriter.getContext();
        auto i64Ty = IntegerType::get(ctx, 64);
        auto i8Ty = IntegerType::get(ctx, 8);
        auto ptrTy = LLVM::LLVMPointerType::get(ctx);

        Value input = adaptor.getRecord();
        int64_t index = op.getFieldIndex();

        auto resolveFunc = runtime.getOrCreateResolveHPtr(rewriter);
        auto resolveCall = rewriter.create<LLVM::CallOp>(loc, resolveFunc, ValueRange{input});
        Value ptr = resolveCall.getResult();

        // Record layout: Header (8) + unboxed (8) + values[index * 8]
        int64_t offsetBytes = layout::RecordFieldsOffset + index * layout::PtrSize;
        auto offset = rewriter.create<LLVM::ConstantOp>(loc, i64Ty, offsetBytes);
        auto fieldPtr = rewriter.create<LLVM::GEPOp>(loc, ptrTy, i8Ty, ptr,
                                                      ValueRange{offset});

        Type resultType = getTypeConverter()->convertType(op.getResult().getType());
        if (isHPtrLLVMType(resultType)) {
            Value loaded = rewriter.create<LLVM::LoadOp>(loc, i64Ty, fieldPtr);
            rewriter.replaceOp(op, heapLoadI64ToValue(rewriter, loc, loaded));
        } else {
            Value result = rewriter.create<LLVM::LoadOp>(loc, resultType, fieldPtr);
            rewriter.replaceOp(op, result);
        }
        return success();
    }
};

//===----------------------------------------------------------------------===//
// eco.construct.custom -> call eco_alloc_custom, then store fields
//===----------------------------------------------------------------------===//

struct CustomConstructOpLowering : public OpConversionPattern<CustomConstructOp> {
    const EcoRuntime &runtime;

    CustomConstructOpLowering(EcoTypeConverter &typeConverter, MLIRContext *ctx,
                              const EcoRuntime &runtime)
        : OpConversionPattern(typeConverter, ctx), runtime(runtime) {}

    LogicalResult
    matchAndRewrite(CustomConstructOp op, OpAdaptor adaptor,
                    ConversionPatternRewriter &rewriter) const override {
        auto loc = op.getLoc();
        auto *ctx = rewriter.getContext();
        auto i32Ty = IntegerType::get(ctx, 32);
        auto i64Ty = IntegerType::get(ctx, 64);

        auto storeFunc = runtime.getOrCreateStoreField(rewriter);
        auto storeI64Func = runtime.getOrCreateStoreFieldI64(rewriter);
        auto storeF64Func = runtime.getOrCreateStoreFieldF64(rewriter);
        auto setUnboxedFunc = runtime.getOrCreateSetUnboxed(rewriter);

        int64_t opSize = op.getSize();
        auto tag = rewriter.create<LLVM::ConstantOp>(loc, i32Ty, static_cast<int32_t>(op.getTag()));
        auto size = rewriter.create<LLVM::ConstantOp>(loc, i32Ty, static_cast<int32_t>(opSize));
        auto scalarBytes = rewriter.create<LLVM::ConstantOp>(loc, i32Ty, 0);

        // The fields operand list may contain GC roots appended after
        // the actual fields by EcoGCPrepare. Split them using the size attr.
        auto allOperands = adaptor.getFields();
        auto fields = allOperands.take_front(opSize);
        auto liveRoots = allOperands.drop_front(opSize);

        Value objHPtr = emitAllocWithSafepoint(
            op, rewriter, runtime,
            runtime.getOrCreateAllocCustom(rewriter),
            ValueRange{tag, size, scalarBytes},
            liveRoots);

        // Store each field (rewriter is now in contBlock)
        auto origFields = op.getFields();
        for (int64_t i = 0; i < opSize; i++) {
            auto idx = rewriter.create<LLVM::ConstantOp>(loc, i32Ty, static_cast<int32_t>(i));
            Type origType = origFields[i].getType();
            Value fieldVal = fields[i];

            if (origType.isF64()) {
                rewriter.create<LLVM::CallOp>(loc, storeF64Func,
                    ValueRange{objHPtr, idx, fieldVal});
            } else if (origType.isInteger(64)) {
                rewriter.create<LLVM::CallOp>(loc, storeI64Func,
                    ValueRange{objHPtr, idx, fieldVal});
            } else if (origType.isInteger(1) || origType.isInteger(16)) {
                Value widened = widenFieldToI64(fieldVal, loc, rewriter);
                rewriter.create<LLVM::CallOp>(loc, storeI64Func,
                    ValueRange{objHPtr, idx, widened});
            } else {
                // eco.value → ptr<1> from adaptor; pass directly (store takes hptr val)
                rewriter.create<LLVM::CallOp>(loc, storeFunc,
                    ValueRange{objHPtr, idx, fieldVal});
            }
        }

        // Set unboxed bitmap if non-zero
        int64_t bitmap = op.getUnboxedBitmap();
        if (bitmap != 0) {
            auto bitmapVal = rewriter.create<LLVM::ConstantOp>(loc, i64Ty, bitmap);
            rewriter.create<LLVM::CallOp>(loc, setUnboxedFunc,
                ValueRange{objHPtr, bitmapVal});
        }

        rewriter.replaceOp(op, objHPtr);
        return success();
    }
};

//===----------------------------------------------------------------------===//
// eco.project.custom -> load from Custom.values[index]
//===----------------------------------------------------------------------===//

struct CustomProjectOpLowering : public OpConversionPattern<CustomProjectOp> {
    const EcoRuntime &runtime;

    CustomProjectOpLowering(EcoTypeConverter &typeConverter, MLIRContext *ctx,
                            const EcoRuntime &runtime)
        : OpConversionPattern(typeConverter, ctx), runtime(runtime) {}

    LogicalResult
    matchAndRewrite(CustomProjectOp op, OpAdaptor adaptor,
                    ConversionPatternRewriter &rewriter) const override {
        auto loc = op.getLoc();
        auto *ctx = rewriter.getContext();
        auto i64Ty = IntegerType::get(ctx, 64);
        auto i8Ty = IntegerType::get(ctx, 8);
        auto ptrTy = LLVM::LLVMPointerType::get(ctx);

        Value input = adaptor.getContainer();
        int64_t index = op.getFieldIndex();

        auto resolveFunc = runtime.getOrCreateResolveHPtr(rewriter);
        auto resolveCall = rewriter.create<LLVM::CallOp>(loc, resolveFunc, ValueRange{input});
        Value ptr = resolveCall.getResult();

        // Custom layout: Header (8) + ctor/unboxed (8) + values[index * 8]
        int64_t offsetBytes = layout::CustomFieldsOffset + index * layout::PtrSize;
        auto offset = rewriter.create<LLVM::ConstantOp>(loc, i64Ty, offsetBytes);
        auto fieldPtr = rewriter.create<LLVM::GEPOp>(loc, ptrTy, i8Ty, ptr,
                                                      ValueRange{offset});

        Type resultType = getTypeConverter()->convertType(op.getResult().getType());
        if (isHPtrLLVMType(resultType)) {
            Value loaded = rewriter.create<LLVM::LoadOp>(loc, i64Ty, fieldPtr);
            rewriter.replaceOp(op, heapLoadI64ToValue(rewriter, loc, loaded));
        } else {
            Value result = rewriter.create<LLVM::LoadOp>(loc, resultType, fieldPtr);
            rewriter.replaceOp(op, result);
        }
        return success();
    }
};

//===----------------------------------------------------------------------===//
// eco.array.length -> resolve + GEP + load length field
//===----------------------------------------------------------------------===//

struct ArrayLengthOpLowering : public OpConversionPattern<ArrayLengthOp> {
    const EcoRuntime &runtime;

    ArrayLengthOpLowering(EcoTypeConverter &typeConverter, MLIRContext *ctx,
                          const EcoRuntime &runtime)
        : OpConversionPattern(typeConverter, ctx), runtime(runtime) {}

    LogicalResult
    matchAndRewrite(ArrayLengthOp op, OpAdaptor adaptor,
                    ConversionPatternRewriter &rewriter) const override {
        auto loc = op.getLoc();
        auto *ctx = rewriter.getContext();
        auto i64Ty = IntegerType::get(ctx, 64);
        auto i32Ty = IntegerType::get(ctx, 32);
        auto i8Ty = IntegerType::get(ctx, 8);
        auto ptrTy = LLVM::LLVMPointerType::get(ctx);

        Value input = adaptor.getArray();

        // Resolve HPointer to raw pointer
        auto resolveFunc = runtime.getOrCreateResolveHPtr(rewriter);
        auto resolveCall = rewriter.create<LLVM::CallOp>(loc, resolveFunc, ValueRange{input});
        Value ptr = resolveCall.getResult();

        // GEP to length field at offset 8 (after Header)
        auto offset = rewriter.create<LLVM::ConstantOp>(
            loc, i64Ty, static_cast<int64_t>(layout::ArrayLengthOffset));
        auto fieldPtr = rewriter.create<LLVM::GEPOp>(loc, ptrTy, i8Ty, ptr,
                                                      ValueRange{offset});

        // Load u32 length
        Value len32 = rewriter.create<LLVM::LoadOp>(loc, i32Ty, fieldPtr);

        // Zero-extend to i64 (Elm Int)
        Value len64 = rewriter.create<LLVM::ZExtOp>(loc, i64Ty, len32);

        rewriter.replaceOp(op, len64);
        return success();
    }
};

//===----------------------------------------------------------------------===//
// eco.array.get -> resolve + GEP to elements[index] + load + type conversion
//===----------------------------------------------------------------------===//

struct ArrayGetOpLowering : public OpConversionPattern<ArrayGetOp> {
    const EcoRuntime &runtime;

    ArrayGetOpLowering(EcoTypeConverter &typeConverter, MLIRContext *ctx,
                       const EcoRuntime &runtime)
        : OpConversionPattern(typeConverter, ctx), runtime(runtime) {}

    LogicalResult
    matchAndRewrite(ArrayGetOp op, OpAdaptor adaptor,
                    ConversionPatternRewriter &rewriter) const override {
        auto loc = op.getLoc();
        auto *ctx = rewriter.getContext();
        auto i64Ty = IntegerType::get(ctx, 64);
        auto i8Ty = IntegerType::get(ctx, 8);
        auto ptrTy = LLVM::LLVMPointerType::get(ctx);

        Value arrayVal = adaptor.getArray();
        Value indexVal = adaptor.getIndex();

        // Resolve HPointer to raw pointer
        auto resolveFunc = runtime.getOrCreateResolveHPtr(rewriter);
        auto resolveCall = rewriter.create<LLVM::CallOp>(loc, resolveFunc, ValueRange{arrayVal});
        Value ptr = resolveCall.getResult();

        // Compute element pointer: base + ArrayElementsOffset + index * 8
        auto baseOffset = rewriter.create<LLVM::ConstantOp>(
            loc, i64Ty, static_cast<int64_t>(layout::ArrayElementsOffset));
        auto elemSize = rewriter.create<LLVM::ConstantOp>(
            loc, i64Ty, static_cast<int64_t>(layout::PtrSize));
        auto indexOffset = rewriter.create<LLVM::MulOp>(loc, i64Ty, indexVal, elemSize);
        auto totalOffset = rewriter.create<LLVM::AddOp>(loc, i64Ty, baseOffset, indexOffset);
        auto elemPtr = rewriter.create<LLVM::GEPOp>(loc, ptrTy, i8Ty, ptr,
                                                     ValueRange{totalOffset});

        // Load i64 (Unboxable is always 8 bytes)
        Value raw = rewriter.create<LLVM::LoadOp>(loc, i64Ty, elemPtr);

        // Interpret based on result type
        Type origResultType = op.getResult().getType();
        if (isa<eco::ValueType>(origResultType)) {
            // eco.value: load i64 then convert to ptr<1>
            rewriter.replaceOp(op, heapLoadI64ToValue(rewriter, loc, raw));
        } else if (origResultType.isInteger(64)) {
            // Int: raw i64 is the result directly
            rewriter.replaceOp(op, raw);
        } else if (origResultType.isF64()) {
            // Float: bitcast i64 to f64
            auto f64Ty = Float64Type::get(ctx);
            Value result = rewriter.create<LLVM::BitcastOp>(loc, f64Ty, raw);
            rewriter.replaceOp(op, result);
        } else if (origResultType.isInteger(16)) {
            // Char: truncate i64 to i16
            auto i16Ty = IntegerType::get(ctx, 16);
            Value result = rewriter.create<LLVM::TruncOp>(loc, i16Ty, raw);
            rewriter.replaceOp(op, result);
        } else {
            return op.emitError("unsupported element type for eco.array.get");
        }

        return success();
    }
};

//===----------------------------------------------------------------------===//
// eco.array.set -> clone array + resolve + GEP + store
//===----------------------------------------------------------------------===//

struct ArraySetOpLowering : public OpConversionPattern<ArraySetOp> {
    const EcoRuntime &runtime;

    ArraySetOpLowering(EcoTypeConverter &typeConverter, MLIRContext *ctx,
                       const EcoRuntime &runtime)
        : OpConversionPattern(typeConverter, ctx), runtime(runtime) {}

    LogicalResult
    matchAndRewrite(ArraySetOp op, OpAdaptor adaptor,
                    ConversionPatternRewriter &rewriter) const override {
        auto loc = op.getLoc();
        auto *ctx = rewriter.getContext();
        auto i64Ty = IntegerType::get(ctx, 64);
        auto i8Ty = IntegerType::get(ctx, 8);
        auto ptrTy = LLVM::LLVMPointerType::get(ctx);

        Value arrayVal = adaptor.getArray();
        Value indexVal = adaptor.getIndex();
        Value valueVal = adaptor.getValue();

        // Clone the array via runtime helper (handles GC-safe allocation)
        auto cloneFunc = runtime.getOrCreateCloneArray(rewriter);
        auto cloneCall = rewriter.create<LLVM::CallOp>(loc, cloneFunc, ValueRange{arrayVal});
        Value newArrayHPtr = cloneCall.getResult();

        // Resolve new array HPointer to raw pointer
        auto resolveFunc = runtime.getOrCreateResolveHPtr(rewriter);
        auto resolveCall = rewriter.create<LLVM::CallOp>(loc, resolveFunc, ValueRange{newArrayHPtr});
        Value ptr = resolveCall.getResult();

        // Compute element pointer: base + ArrayElementsOffset + index * 8
        auto baseOffset = rewriter.create<LLVM::ConstantOp>(
            loc, i64Ty, static_cast<int64_t>(layout::ArrayElementsOffset));
        auto elemSize = rewriter.create<LLVM::ConstantOp>(
            loc, i64Ty, static_cast<int64_t>(layout::PtrSize));
        auto indexOffset = rewriter.create<LLVM::MulOp>(loc, i64Ty, indexVal, elemSize);
        auto totalOffset = rewriter.create<LLVM::AddOp>(loc, i64Ty, baseOffset, indexOffset);
        auto elemPtr = rewriter.create<LLVM::GEPOp>(loc, ptrTy, i8Ty, ptr,
                                                     ValueRange{totalOffset});

        // Normalize value to i64 for storage in Unboxable slot
        Type origValueType = op.getValue().getType();
        Value raw;
        if (isa<eco::ValueType>(origValueType)) {
            // eco.value: ptr<1> from adaptor, convert to i64
            raw = heapStoreValueToI64(rewriter, loc, valueVal);
        } else if (origValueType.isInteger(64)) {
            // Int: already i64
            raw = valueVal;
        } else if (origValueType.isF64()) {
            // Float: bitcast f64 to i64
            raw = rewriter.create<LLVM::BitcastOp>(loc, i64Ty, valueVal);
        } else if (origValueType.isInteger(16)) {
            // Char: zero-extend i16 to i64
            raw = rewriter.create<LLVM::ZExtOp>(loc, i64Ty, valueVal);
        } else {
            return op.emitError("unsupported value type for eco.array.set");
        }

        // Store into the element slot
        rewriter.create<LLVM::StoreOp>(loc, raw, elemPtr);

        // Return new array as eco.value (i64 HPointer)
        rewriter.replaceOp(op, newArrayHPtr);
        return success();
    }
};

//===----------------------------------------------------------------------===//
// eco.array.empty / singleton / push / slice / append_n
//
// Each lowers to a call to a typed runtime trampoline that takes unboxed
// primitives directly. The variant of singleton/push is chosen by the
// element operand's MLIR type (mirroring eco.array.set).
//===----------------------------------------------------------------------===//

struct ArrayEmptyOpLowering : public OpConversionPattern<ArrayEmptyOp> {
    const EcoRuntime &runtime;
    ArrayEmptyOpLowering(EcoTypeConverter &typeConverter, MLIRContext *ctx,
                         const EcoRuntime &runtime)
        : OpConversionPattern(typeConverter, ctx), runtime(runtime) {}

    LogicalResult
    matchAndRewrite(ArrayEmptyOp op, OpAdaptor adaptor,
                    ConversionPatternRewriter &rewriter) const override {
        auto fn = runtime.getOrCreateArrayEmpty(rewriter);
        auto call = rewriter.create<LLVM::CallOp>(op.getLoc(), fn, ValueRange{});
        rewriter.replaceOp(op, call.getResult());
        return success();
    }
};

struct ArraySingletonOpLowering : public OpConversionPattern<ArraySingletonOp> {
    const EcoRuntime &runtime;
    ArraySingletonOpLowering(EcoTypeConverter &typeConverter, MLIRContext *ctx,
                             const EcoRuntime &runtime)
        : OpConversionPattern(typeConverter, ctx), runtime(runtime) {}

    LogicalResult
    matchAndRewrite(ArraySingletonOp op, OpAdaptor adaptor,
                    ConversionPatternRewriter &rewriter) const override {
        Type origValueType = op.getValue().getType();
        Value v = adaptor.getValue();
        LLVM::LLVMFuncOp fn;
        if (origValueType.isInteger(64)) {
            fn = runtime.getOrCreateArraySingletonInt(rewriter);
        } else if (origValueType.isF64()) {
            fn = runtime.getOrCreateArraySingletonFloat(rewriter);
        } else if (origValueType.isInteger(16)) {
            fn = runtime.getOrCreateArraySingletonChar(rewriter);
        } else if (isa<eco::ValueType>(origValueType)) {
            fn = runtime.getOrCreateArraySingletonBox(rewriter);
        } else {
            return op.emitError("unsupported element type for eco.array.singleton");
        }
        auto call = rewriter.create<LLVM::CallOp>(op.getLoc(), fn, ValueRange{v});
        rewriter.replaceOp(op, call.getResult());
        return success();
    }
};

struct ArrayPushOpLowering : public OpConversionPattern<ArrayPushOp> {
    const EcoRuntime &runtime;
    ArrayPushOpLowering(EcoTypeConverter &typeConverter, MLIRContext *ctx,
                        const EcoRuntime &runtime)
        : OpConversionPattern(typeConverter, ctx), runtime(runtime) {}

    LogicalResult
    matchAndRewrite(ArrayPushOp op, OpAdaptor adaptor,
                    ConversionPatternRewriter &rewriter) const override {
        Type origValueType = op.getValue().getType();
        Value v = adaptor.getValue();
        Value arr = adaptor.getArray();
        LLVM::LLVMFuncOp fn;
        if (origValueType.isInteger(64)) {
            fn = runtime.getOrCreateArrayPushInt(rewriter);
        } else if (origValueType.isF64()) {
            fn = runtime.getOrCreateArrayPushFloat(rewriter);
        } else if (origValueType.isInteger(16)) {
            fn = runtime.getOrCreateArrayPushChar(rewriter);
        } else if (isa<eco::ValueType>(origValueType)) {
            fn = runtime.getOrCreateArrayPushBox(rewriter);
        } else {
            return op.emitError("unsupported element type for eco.array.push");
        }
        auto call = rewriter.create<LLVM::CallOp>(op.getLoc(), fn,
                                                   ValueRange{v, arr});
        rewriter.replaceOp(op, call.getResult());
        return success();
    }
};

struct ArraySliceOpLowering : public OpConversionPattern<ArraySliceOp> {
    const EcoRuntime &runtime;
    ArraySliceOpLowering(EcoTypeConverter &typeConverter, MLIRContext *ctx,
                         const EcoRuntime &runtime)
        : OpConversionPattern(typeConverter, ctx), runtime(runtime) {}

    LogicalResult
    matchAndRewrite(ArraySliceOp op, OpAdaptor adaptor,
                    ConversionPatternRewriter &rewriter) const override {
        auto fn = runtime.getOrCreateArraySlice(rewriter);
        auto call = rewriter.create<LLVM::CallOp>(
            op.getLoc(), fn,
            ValueRange{adaptor.getStart(), adaptor.getEnd(), adaptor.getArray()});
        rewriter.replaceOp(op, call.getResult());
        return success();
    }
};

struct ArrayAppendNOpLowering : public OpConversionPattern<ArrayAppendNOp> {
    const EcoRuntime &runtime;
    ArrayAppendNOpLowering(EcoTypeConverter &typeConverter, MLIRContext *ctx,
                           const EcoRuntime &runtime)
        : OpConversionPattern(typeConverter, ctx), runtime(runtime) {}

    LogicalResult
    matchAndRewrite(ArrayAppendNOp op, OpAdaptor adaptor,
                    ConversionPatternRewriter &rewriter) const override {
        auto fn = runtime.getOrCreateArrayAppendN(rewriter);
        auto call = rewriter.create<LLVM::CallOp>(
            op.getLoc(), fn,
            ValueRange{adaptor.getN(), adaptor.getDest(), adaptor.getSource()});
        rewriter.replaceOp(op, call.getResult());
        return success();
    }
};

//===----------------------------------------------------------------------===//
// eco.string.from_int / from_float
//===----------------------------------------------------------------------===//

struct StringFromIntOpLowering : public OpConversionPattern<StringFromIntOp> {
    const EcoRuntime &runtime;
    StringFromIntOpLowering(EcoTypeConverter &typeConverter, MLIRContext *ctx,
                            const EcoRuntime &runtime)
        : OpConversionPattern(typeConverter, ctx), runtime(runtime) {}

    LogicalResult
    matchAndRewrite(StringFromIntOp op, OpAdaptor adaptor,
                    ConversionPatternRewriter &rewriter) const override {
        auto fn = runtime.getOrCreateStringFromInt(rewriter);
        auto call = rewriter.create<LLVM::CallOp>(op.getLoc(), fn,
                                                   ValueRange{adaptor.getValue()});
        rewriter.replaceOp(op, call.getResult());
        return success();
    }
};

struct StringFromFloatOpLowering : public OpConversionPattern<StringFromFloatOp> {
    const EcoRuntime &runtime;
    StringFromFloatOpLowering(EcoTypeConverter &typeConverter, MLIRContext *ctx,
                              const EcoRuntime &runtime)
        : OpConversionPattern(typeConverter, ctx), runtime(runtime) {}

    LogicalResult
    matchAndRewrite(StringFromFloatOp op, OpAdaptor adaptor,
                    ConversionPatternRewriter &rewriter) const override {
        auto fn = runtime.getOrCreateStringFromDouble(rewriter);
        auto call = rewriter.create<LLVM::CallOp>(op.getLoc(), fn,
                                                   ValueRange{adaptor.getValue()});
        rewriter.replaceOp(op, call.getResult());
        return success();
    }
};

} // namespace

//===----------------------------------------------------------------------===//
// Allocation Group Lowering
//===----------------------------------------------------------------------===//

/// Convert an !eco.value or ptr<1> SSA value to i64 by inserting the
/// appropriate cast. Returns the value as-is if already i64.
/// For eco.value inputs that are actually unrealized casts from ptr<1>,
/// look through the cast to avoid creating unresolvable cast chains.
static Value castToI64(OpBuilder &builder, Location loc, Value v) {
    if (v.getType().isInteger(64))
        return v;
    if (isHPtrLLVMType(v.getType())) {
        auto i64Ty = IntegerType::get(builder.getContext(), 64);
        return builder.create<LLVM::PtrToIntOp>(loc, i64Ty, v);
    }
    // Check if v is an unrealized_conversion_cast(ptr<1> → eco.value).
    // If so, look through the cast and use PtrToIntOp on the original ptr<1>.
    if (auto castOp = v.getDefiningOp<UnrealizedConversionCastOp>()) {
        if (castOp.getNumOperands() == 1 &&
            isHPtrLLVMType(castOp.getOperand(0).getType())) {
            auto i64Ty = IntegerType::get(builder.getContext(), 64);
            return builder.create<LLVM::PtrToIntOp>(loc, i64Ty,
                                                     castOp.getOperand(0));
        }
    }
    auto i64Ty = IntegerType::get(builder.getContext(), 64);
    return builder.create<UnrealizedConversionCastOp>(loc, i64Ty, v)
        .getResult(0);
}

/// Convert an !eco.value SSA value to ptr<1> for passing to runtime functions
/// that expect HPTR_TY. If already ptr<1>, return as-is.
/// For eco.value inputs from unrealized casts, look through the cast.
static Value castToHPtr(OpBuilder &builder, Location loc, Value v) {
    if (isHPtrLLVMType(v.getType()))
        return v;
    auto hptrTy = LLVM::LLVMPointerType::get(builder.getContext(), /*addressSpace=*/1);
    if (v.getType().isInteger(64))
        return builder.create<LLVM::IntToPtrOp>(loc, hptrTy, v);
    // Check if v is an unrealized_conversion_cast(ptr<1> → eco.value).
    if (auto castOp = v.getDefiningOp<UnrealizedConversionCastOp>()) {
        if (castOp.getNumOperands() == 1 &&
            isHPtrLLVMType(castOp.getOperand(0).getType()))
            return castOp.getOperand(0);
    }
    // Fallback: unrealized cast
    return builder.create<UnrealizedConversionCastOp>(loc, hptrTy, v)
        .getResult(0);
}

/// Widen a primitive SSA value to i64 for Unboxable slot storage.
/// i64 passes through. ptr<1> → ptrtoint. f64 → bitcast. i16/i1 → zext.
/// For eco.value: cast to ptr<1> first (via castToHPtr which looks through
/// materialization casts or creates an unrealized cast), then ptrtoint.
static Value widenToI64ForInit(OpBuilder &builder, Location loc, Value v) {
    auto i64Ty = IntegerType::get(builder.getContext(), 64);
    Type ty = v.getType();
    if (ty.isInteger(64)) return v;
    if (isHPtrLLVMType(ty))
        return builder.create<LLVM::PtrToIntOp>(loc, i64Ty, v);
    if (isa<eco::ValueType>(ty)) {
        // Go through ptr<1> first, then to i64. This avoids creating
        // eco.value→i64 unrealized casts that become unresolvable when
        // the eco.value is later replaced by a ptr<1> materialization.
        Value hptr = castToHPtr(builder, loc, v);
        return builder.create<LLVM::PtrToIntOp>(loc, i64Ty, hptr);
    }
    if (auto intTy = dyn_cast<IntegerType>(ty)) {
        if (intTy.getWidth() < 64)
            return builder.create<LLVM::ZExtOp>(loc, i64Ty, v);
    }
    if (ty.isF64())
        return builder.create<LLVM::BitcastOp>(loc, i64Ty, v);
    return castToI64(builder, loc, v);
}

/// Emit the init-at-pointer call for one group member at the given raw pointer.
/// Returns the HPointer (i64) result.
/// Field stores for record/custom ops are NOT emitted here — they go in the
/// merge block so they don't need to be duplicated across fast/slow paths.
static Value emitInitAtPtr(
    OpBuilder &builder, Location loc,
    Operation *op, Value objPtr,
    const EcoRuntime &runtime) {

    auto *ctx = builder.getContext();
    auto i32Ty = IntegerType::get(ctx, 32);
    auto i64Ty = IntegerType::get(ctx, 64);

    if (auto boxOp = dyn_cast<BoxOp>(op)) {
        Type inputType = boxOp.getValue().getType();
        Value input = boxOp.getValue();
        if (inputType.isInteger(64)) {
            return builder.create<LLVM::CallOp>(
                loc, runtime.getOrCreateInitIntAt(builder),
                ValueRange{objPtr, input}).getResult();
        }
        if (inputType.isF64()) {
            return builder.create<LLVM::CallOp>(
                loc, runtime.getOrCreateInitFloatAt(builder),
                ValueRange{objPtr, input}).getResult();
        }
        if (inputType.isInteger(16)) {
            auto widened = builder.create<LLVM::ZExtOp>(loc, i32Ty, input);
            return builder.create<LLVM::CallOp>(
                loc, runtime.getOrCreateInitCharAt(builder),
                ValueRange{objPtr, widened}).getResult();
        }
        llvm_unreachable("unsupported BoxOp input type in group");
    }

    if (auto allocCtor = dyn_cast<AllocateCtorOp>(op)) {
        auto tag = builder.create<LLVM::ConstantOp>(
            loc, i32Ty, static_cast<int32_t>(allocCtor.getTag()));
        auto size = builder.create<LLVM::ConstantOp>(
            loc, i32Ty, static_cast<int32_t>(allocCtor.getSize()));
        auto scalarBytes = builder.create<LLVM::ConstantOp>(
            loc, i32Ty, static_cast<int32_t>(allocCtor.getScalarBytes()));
        return builder.create<LLVM::CallOp>(
            loc, runtime.getOrCreateInitCustomAt(builder),
            ValueRange{objPtr, tag, size, scalarBytes}).getResult();
    }

    if (auto allocStr = dyn_cast<AllocateStringOp>(op)) {
        auto length = builder.create<LLVM::ConstantOp>(
            loc, i32Ty, static_cast<int32_t>(allocStr.getLength()));
        return builder.create<LLVM::CallOp>(
            loc, runtime.getOrCreateInitStringAt(builder),
            ValueRange{objPtr, length}).getResult();
    }

    if (auto listOp = dyn_cast<ListConstructOp>(op)) {
        Value head = widenToI64ForInit(builder, loc, listOp.getHead());
        Value tail = castToHPtr(builder, loc, listOp.getTail());
        uint32_t headKind = static_cast<uint32_t>(listOp.getHeadKind()) & 0x3;
        auto headUnboxedVal = builder.create<LLVM::ConstantOp>(loc, i32Ty, headKind);
        return builder.create<LLVM::CallOp>(
            loc, runtime.getOrCreateInitConsAt(builder),
            ValueRange{objPtr, head, tail, headUnboxedVal}).getResult();
    }

    if (auto tuple2Op = dyn_cast<Tuple2ConstructOp>(op)) {
        Value a = widenToI64ForInit(builder, loc, tuple2Op.getA());
        Value b = widenToI64ForInit(builder, loc, tuple2Op.getB());
        auto unboxed = builder.create<LLVM::ConstantOp>(
            loc, i32Ty, static_cast<int32_t>(tuple2Op.getUnboxedBitmap()));
        return builder.create<LLVM::CallOp>(
            loc, runtime.getOrCreateInitTuple2At(builder),
            ValueRange{objPtr, a, b, unboxed}).getResult();
    }

    if (auto tuple3Op = dyn_cast<Tuple3ConstructOp>(op)) {
        Value a = widenToI64ForInit(builder, loc, tuple3Op.getA());
        Value b = widenToI64ForInit(builder, loc, tuple3Op.getB());
        Value c = widenToI64ForInit(builder, loc, tuple3Op.getC());
        auto unboxed = builder.create<LLVM::ConstantOp>(
            loc, i32Ty, static_cast<int32_t>(tuple3Op.getUnboxedBitmap()));
        return builder.create<LLVM::CallOp>(
            loc, runtime.getOrCreateInitTuple3At(builder),
            ValueRange{objPtr, a, b, c, unboxed}).getResult();
    }

    if (auto recOp = dyn_cast<RecordConstructOp>(op)) {
        auto fieldCount = builder.create<LLVM::ConstantOp>(
            loc, i32Ty, static_cast<int32_t>(recOp.getFieldCount()));
        auto unboxedBitmap = builder.create<LLVM::ConstantOp>(
            loc, i64Ty, recOp.getUnboxedBitmap());
        return builder.create<LLVM::CallOp>(
            loc, runtime.getOrCreateInitRecordAt(builder),
            ValueRange{objPtr, fieldCount, unboxedBitmap}).getResult();
    }

    if (auto customOp = dyn_cast<CustomConstructOp>(op)) {
        auto tag = builder.create<LLVM::ConstantOp>(
            loc, i32Ty, static_cast<int32_t>(customOp.getTag()));
        auto size = builder.create<LLVM::ConstantOp>(
            loc, i32Ty, static_cast<int32_t>(customOp.getSize()));
        auto scalarBytes = builder.create<LLVM::ConstantOp>(loc, i32Ty, 0);
        return builder.create<LLVM::CallOp>(
            loc, runtime.getOrCreateInitCustomAt(builder),
            ValueRange{objPtr, tag, size, scalarBytes}).getResult();
    }

    llvm_unreachable("unsupported op kind in emitInitAtPtr");
}

/// Emit field stores for a record or custom op in the merge block.
/// hptr is the HPointer (i64) from the merge block arg.
/// memberResultMap maps original op results to their i64 merge-block values.
static void emitFieldStoresForOp(
    OpBuilder &builder, Location loc,
    Operation *op, Value hptr,
    const llvm::DenseMap<Value, Value> &memberResultMap,
    const EcoRuntime &runtime) {

    auto *ctx = builder.getContext();
    auto i32Ty = IntegerType::get(ctx, 32);
    auto i64Ty = IntegerType::get(ctx, 64);

    if (auto recOp = dyn_cast<RecordConstructOp>(op)) {
        auto storeFunc = runtime.getOrCreateStoreRecordField(builder);
        auto storeI64Func = runtime.getOrCreateStoreRecordFieldI64(builder);
        auto storeF64Func = runtime.getOrCreateStoreRecordFieldF64(builder);
        int64_t fieldCount = recOp.getFieldCount();
        auto fields = recOp.getFields();

        for (int64_t i = 0; i < fieldCount; i++) {
            auto idx = builder.create<LLVM::ConstantOp>(loc, i32Ty, static_cast<int32_t>(i));
            Value fieldVal = fields[i];
            Type origType = fieldVal.getType();

            // Check if this field is another group member's result
            auto it = memberResultMap.find(fieldVal);
            if (it != memberResultMap.end()) {
                // Merge-block value is hptr — pass directly (store_field takes hptr val)
                builder.create<LLVM::CallOp>(loc, storeFunc,
                    ValueRange{hptr, idx, it->second});
                continue;
            }

            if (origType.isF64()) {
                builder.create<LLVM::CallOp>(loc, storeF64Func,
                    ValueRange{hptr, idx, fieldVal});
            } else if (origType.isInteger(1) || origType.isInteger(16)) {
                auto extended = builder.create<LLVM::ZExtOp>(loc, i64Ty, fieldVal);
                builder.create<LLVM::CallOp>(loc, storeI64Func,
                    ValueRange{hptr, idx, extended});
            } else if (origType.isInteger(64)) {
                builder.create<LLVM::CallOp>(loc, storeI64Func,
                    ValueRange{hptr, idx, fieldVal});
            } else {
                // eco.value or ptr<1> — cast to hptr for store (avoids unrealized casts)
                Value valHPtr = castToHPtr(builder, loc, fieldVal);
                builder.create<LLVM::CallOp>(loc, storeFunc,
                    ValueRange{hptr, idx, valHPtr});
            }
        }
        return;
    }

    if (auto customOp = dyn_cast<CustomConstructOp>(op)) {
        auto storeFunc = runtime.getOrCreateStoreField(builder);
        auto storeI64Func = runtime.getOrCreateStoreFieldI64(builder);
        auto storeF64Func = runtime.getOrCreateStoreFieldF64(builder);
        auto setUnboxedFunc = runtime.getOrCreateSetUnboxed(builder);
        int64_t opSize = customOp.getSize();
        auto fields = customOp.getFields();

        for (int64_t i = 0; i < opSize; i++) {
            auto idx = builder.create<LLVM::ConstantOp>(loc, i32Ty, static_cast<int32_t>(i));
            Value fieldVal = fields[i];
            Type origType = fieldVal.getType();

            auto it = memberResultMap.find(fieldVal);
            if (it != memberResultMap.end()) {
                // Merge-block value is hptr — pass directly
                builder.create<LLVM::CallOp>(loc, storeFunc,
                    ValueRange{hptr, idx, it->second});
                continue;
            }

            if (origType.isF64()) {
                builder.create<LLVM::CallOp>(loc, storeF64Func,
                    ValueRange{hptr, idx, fieldVal});
            } else if (origType.isInteger(1) || origType.isInteger(16)) {
                auto extended = builder.create<LLVM::ZExtOp>(loc, i64Ty, fieldVal);
                builder.create<LLVM::CallOp>(loc, storeI64Func,
                    ValueRange{hptr, idx, extended});
            } else if (origType.isInteger(64)) {
                builder.create<LLVM::CallOp>(loc, storeI64Func,
                    ValueRange{hptr, idx, fieldVal});
            } else {
                Value valHPtr = castToHPtr(builder, loc, fieldVal);
                builder.create<LLVM::CallOp>(loc, storeFunc,
                    ValueRange{hptr, idx, valHPtr});
            }
        }

        int64_t bitmap = customOp.getUnboxedBitmap();
        if (bitmap != 0) {
            auto bitmapVal = builder.create<LLVM::ConstantOp>(loc, i64Ty, bitmap);
            builder.create<LLVM::CallOp>(loc, setUnboxedFunc,
                ValueRange{hptr, bitmapVal});
        }
        return;
    }
}

/// Lower a single allocation group into fast/slow/merge CFG.
static void lowerOneAllocGroup(
    SmallVectorImpl<Operation*> &group,
    const EcoRuntime &runtime) {

    Operation *leader = group.front();
    auto loc = leader->getLoc();
    auto *ctx = leader->getContext();
    auto i64Ty = IntegerType::get(ctx, 64);
    auto i8Ty = IntegerType::get(ctx, 8);
    auto ptrTy = LLVM::LLVMPointerType::get(ctx);
    size_t groupSize = group.size();

    // Compute totalBytes and offset prefix sums.
    int64_t totalBytes = 0;
    SmallVector<int64_t, 8> offsets;
    for (auto *op : group) {
        offsets.push_back(totalBytes);
        totalBytes += computeAllocSize(op);
    }

    // Get the leader's GC roots for the safepoint marker.
    SmallVector<Value, 4> liveRoots;
    if (auto carrier = dyn_cast<eco::GCRootCarrier>(leader)) {
        for (Value r : carrier.getGCRoots())
            liveRoots.push_back(r);
    }

    // --- CFG surgery ---
    Block *origBlock = leader->getBlock();
    Region *parentRegion = origBlock->getParent();

    // Split just before the leader. Everything from leader onward goes to afterBlock.
    Block *afterBlock = origBlock->splitBlock(leader);

    // Create fast, slow, merge blocks in the same region.
    Block *fastBlock = new Block();
    Block *slowBlock = new Block();
    Block *mergeBlock = new Block();
    parentRegion->getBlocks().insertAfter(Region::iterator(origBlock), fastBlock);
    parentRegion->getBlocks().insertAfter(Region::iterator(fastBlock), slowBlock);
    parentRegion->getBlocks().insertAfter(Region::iterator(slowBlock), mergeBlock);

    // Add merge block args: one hptr per group member (HPointers).
    auto hptrTy = LLVM::LLVMPointerType::get(ctx, /*addressSpace=*/1);
    for (size_t i = 0; i < groupSize; i++)
        mergeBlock->addArgument(hptrTy, loc);

    // Move afterBlock's ops into mergeBlock (merge block IS the continuation).
    mergeBlock->getOperations().splice(
        mergeBlock->end(), afterBlock->getOperations());
    afterBlock->erase();

    OpBuilder builder(ctx);

    // --- Entry block: region fast alloc + null check ---
    builder.setInsertionPointToEnd(origBlock);

    auto totalBytesVal = builder.create<LLVM::ConstantOp>(loc, i64Ty, totalBytes);
    auto baseFastCall = builder.create<LLVM::CallOp>(
        loc, runtime.getOrCreateAllocRegionFast(builder),
        ValueRange{totalBytesVal});
    Value baseFastPtr = baseFastCall.getResult();

    auto nullPtr = builder.create<LLVM::ZeroOp>(loc, ptrTy);
    auto isNull = builder.create<LLVM::ICmpOp>(
        loc, LLVM::ICmpPredicate::eq, baseFastPtr, nullPtr);

    builder.create<cf::CondBranchOp>(
        loc, isNull, slowBlock, ValueRange{},
        fastBlock, ValueRange{});

    // --- Fast block: init each member at offset ---
    builder.setInsertionPointToEnd(fastBlock);
    SmallVector<Value, 8> fastHPtrs;
    for (size_t i = 0; i < groupSize; i++) {
        Value offsetVal = builder.create<LLVM::ConstantOp>(loc, i64Ty, offsets[i]);
        Value objPtr = builder.create<LLVM::GEPOp>(
            loc, ptrTy, i8Ty, baseFastPtr, ValueRange{offsetVal});
        Value hptr = emitInitAtPtr(builder, loc, group[i], objPtr, runtime);
        fastHPtrs.push_back(hptr);
    }
    builder.create<cf::BranchOp>(loc, mergeBlock, fastHPtrs);

    // --- Slow block: safepoint marker + region slow alloc + init ---
    builder.setInsertionPointToEnd(slowBlock);

    // RS4GC handles safepoint insertion around the slow alloc call automatically.

    auto totalBytesValSlow = builder.create<LLVM::ConstantOp>(loc, i64Ty, totalBytes);
    auto baseSlowCall = builder.create<LLVM::CallOp>(
        loc, runtime.getOrCreateAllocRegionSlow(builder),
        ValueRange{totalBytesValSlow});
    Value baseSlowPtr = baseSlowCall.getResult();

    SmallVector<Value, 8> slowHPtrs;
    for (size_t i = 0; i < groupSize; i++) {
        Value offsetVal = builder.create<LLVM::ConstantOp>(loc, i64Ty, offsets[i]);
        Value objPtr = builder.create<LLVM::GEPOp>(
            loc, ptrTy, i8Ty, baseSlowPtr, ValueRange{offsetVal});
        Value hptr = emitInitAtPtr(builder, loc, group[i], objPtr, runtime);
        slowHPtrs.push_back(hptr);
    }
    builder.create<cf::BranchOp>(loc, mergeBlock, slowHPtrs);

    // --- Merge block: field stores + result replacement ---
    builder.setInsertionPointToStart(mergeBlock);

    llvm::DenseMap<Value, Value> memberResultMap;
    auto ecoValueTy = eco::ValueType::get(ctx);
    SmallVector<Value, 8> ecoResults;

    for (size_t i = 0; i < groupSize; i++) {
        Value mergeArg = mergeBlock->getArgument(i);
        memberResultMap[group[i]->getResult(0)] = mergeArg;

        // Unrealized cast from i64 to !eco.value for external uses.
        Value ecoVal = builder.create<UnrealizedConversionCastOp>(
            loc, ecoValueTy, mergeArg).getResult(0);
        ecoResults.push_back(ecoVal);
    }

    // Emit field stores for record/custom members.
    for (size_t i = 0; i < groupSize; i++) {
        Value hptr = mergeBlock->getArgument(i);
        emitFieldStoresForOp(builder, loc, group[i], hptr,
                             memberResultMap, runtime);
    }

    // Replace original op results with the eco.value casts.
    for (size_t i = 0; i < groupSize; i++)
        group[i]->getResult(0).replaceAllUsesWith(ecoResults[i]);

    // Erase all group ops (now in mergeBlock after the splice).
    for (auto it = group.rbegin(); it != group.rend(); ++it)
        (*it)->erase();
}

/// Lower all allocation groups in the module.
void eco::detail::lowerAllocGroups(ModuleOp module, const EcoRuntime &runtime) {
    // Collect all groups across all functions first, then lower.
    SmallVector<SmallVector<Operation*, 4>> allGroups;

    for (auto funcOp : module.getOps<func::FuncOp>()) {
        if (funcOp.isExternal()) continue;

        for (auto &region : funcOp->getRegions()) {
            for (auto &block : region) {
                for (auto &op : block) {
                    auto groupSizeAttr = op.getAttrOfType<IntegerAttr>("eco.gc_group_size");
                    if (!groupSizeAttr || op.hasAttr("eco.gc_group_member"))
                        continue;
                    int64_t groupSize = groupSizeAttr.getInt();
                    if (groupSize <= 1) continue;

                    SmallVector<Operation*, 4> group;
                    group.push_back(&op);
                    Operation *next = op.getNextNode();
                    for (int64_t i = 1; i < groupSize && next; i++) {
                        assert(next->hasAttr("eco.gc_group_member") &&
                               "expected group member after leader");
                        group.push_back(next);
                        next = next->getNextNode();
                    }
                    assert(static_cast<int64_t>(group.size()) == groupSize &&
                           "group size mismatch");
                    allGroups.push_back(std::move(group));
                }
            }
        }
    }

    for (auto &group : allGroups) {
        lowerOneAllocGroup(group, runtime);
    }
}

//===----------------------------------------------------------------------===//
// Pattern Population
//===----------------------------------------------------------------------===//

void eco::detail::populateEcoHeapPatterns(
    EcoTypeConverter &typeConverter,
    RewritePatternSet &patterns,
    const EcoRuntime &runtime) {

    auto *ctx = patterns.getContext();
    patterns.add<BoxOpLowering>(typeConverter, ctx, runtime);
    patterns.add<UnboxOpLowering>(typeConverter, ctx, runtime);
    patterns.add<AllocateOpLowering>(typeConverter, ctx, runtime);
    patterns.add<AllocateCtorOpLowering>(typeConverter, ctx, runtime);
    patterns.add<AllocateStringOpLowering>(typeConverter, ctx, runtime);
    patterns.add<ListConstructOpLowering>(typeConverter, ctx, runtime);
    patterns.add<ListHeadOpLowering>(typeConverter, ctx, runtime);
    patterns.add<ListTailOpLowering>(typeConverter, ctx, runtime);
    patterns.add<Tuple2ConstructOpLowering>(typeConverter, ctx, runtime);
    patterns.add<Tuple3ConstructOpLowering>(typeConverter, ctx, runtime);
    patterns.add<Tuple2ProjectOpLowering>(typeConverter, ctx, runtime);
    patterns.add<Tuple3ProjectOpLowering>(typeConverter, ctx, runtime);
    patterns.add<RecordConstructOpLowering>(typeConverter, ctx, runtime);
    patterns.add<RecordProjectOpLowering>(typeConverter, ctx, runtime);
    patterns.add<CustomConstructOpLowering>(typeConverter, ctx, runtime);
    patterns.add<CustomProjectOpLowering>(typeConverter, ctx, runtime);
    patterns.add<ArrayLengthOpLowering>(typeConverter, ctx, runtime);
    patterns.add<ArrayGetOpLowering>(typeConverter, ctx, runtime);
    patterns.add<ArraySetOpLowering>(typeConverter, ctx, runtime);
    patterns.add<ArrayEmptyOpLowering>(typeConverter, ctx, runtime);
    patterns.add<ArraySingletonOpLowering>(typeConverter, ctx, runtime);
    patterns.add<ArrayPushOpLowering>(typeConverter, ctx, runtime);
    patterns.add<ArraySliceOpLowering>(typeConverter, ctx, runtime);
    patterns.add<ArrayAppendNOpLowering>(typeConverter, ctx, runtime);
    patterns.add<StringFromIntOpLowering>(typeConverter, ctx, runtime);
    patterns.add<StringFromFloatOpLowering>(typeConverter, ctx, runtime);
}
