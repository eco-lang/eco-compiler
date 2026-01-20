//===- EcoToLLVMHeap.cpp - Heap operation lowering patterns ---------------===//
//
// This file implements lowering patterns for ECO heap operations:
// box, unbox, allocate, construct, and project operations.
//
//===----------------------------------------------------------------------===//

#include "EcoToLLVMInternal.h"
#include "../EcoDialect.h"
#include "../EcoOps.h"

using namespace mlir;
using namespace eco;
using namespace eco::detail;

namespace {

//===----------------------------------------------------------------------===//
// eco.box -> call eco_alloc_* + ptrtoint
//===----------------------------------------------------------------------===//

struct BoxOpLowering : public OpConversionPattern<BoxOp> {
    EcoRuntime runtime;

    BoxOpLowering(EcoTypeConverter &typeConverter, MLIRContext *ctx,
                  EcoRuntime runtime)
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

        if (inputType.isInteger(64)) {
            // Box i64 -> eco_alloc_int
            auto func = runtime.getOrCreateAllocInt(rewriter);
            auto call = rewriter.create<LLVM::CallOp>(loc, func, ValueRange{input});
            result = call.getResult();
        } else if (inputType.isF64()) {
            // Box f64 -> eco_alloc_float
            auto func = runtime.getOrCreateAllocFloat(rewriter);
            auto call = rewriter.create<LLVM::CallOp>(loc, func, ValueRange{input});
            result = call.getResult();
        } else if (inputType.isInteger(16)) {
            // Box i16 (char) -> eco_alloc_char
            auto func = runtime.getOrCreateAllocChar(rewriter);
            auto call = rewriter.create<LLVM::CallOp>(loc, func, ValueRange{input});
            result = call.getResult();
        } else if (inputType.isInteger(1)) {
            // Box i1 (bool) -> use embedded constant True/False
            auto trueCst = rewriter.create<LLVM::ConstantOp>(
                loc, i64Ty, value_enc::encodeConstant(value_enc::True));
            auto falseCst = rewriter.create<LLVM::ConstantOp>(
                loc, i64Ty, value_enc::encodeConstant(value_enc::False));
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
    EcoRuntime runtime;

    UnboxOpLowering(EcoTypeConverter &typeConverter, MLIRContext *ctx,
                    EcoRuntime runtime)
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
            auto trueConst = rewriter.create<LLVM::ConstantOp>(
                loc, i64Ty, value_enc::encodeConstant(value_enc::True));
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
    EcoRuntime runtime;

    AllocateOpLowering(EcoTypeConverter &typeConverter, MLIRContext *ctx,
                       EcoRuntime runtime)
        : OpConversionPattern(typeConverter, ctx), runtime(runtime) {}

    LogicalResult
    matchAndRewrite(AllocateOp op, OpAdaptor adaptor,
                    ConversionPatternRewriter &rewriter) const override {
        auto loc = op.getLoc();
        auto *ctx = rewriter.getContext();
        auto i32Ty = IntegerType::get(ctx, 32);

        auto func = runtime.getOrCreateAllocate(rewriter);
        auto size = adaptor.getSize();
        auto tag = rewriter.create<LLVM::ConstantOp>(loc, i32Ty, 7);  // Tag_Custom

        auto call = rewriter.create<LLVM::CallOp>(loc, func, ValueRange{size, tag});
        rewriter.replaceOp(op, call.getResult());
        return success();
    }
};

//===----------------------------------------------------------------------===//
// eco.allocate_ctor -> call eco_alloc_custom
//===----------------------------------------------------------------------===//

struct AllocateCtorOpLowering : public OpConversionPattern<AllocateCtorOp> {
    EcoRuntime runtime;

    AllocateCtorOpLowering(EcoTypeConverter &typeConverter, MLIRContext *ctx,
                           EcoRuntime runtime)
        : OpConversionPattern(typeConverter, ctx), runtime(runtime) {}

    LogicalResult
    matchAndRewrite(AllocateCtorOp op, OpAdaptor adaptor,
                    ConversionPatternRewriter &rewriter) const override {
        auto loc = op.getLoc();
        auto *ctx = rewriter.getContext();
        auto i32Ty = IntegerType::get(ctx, 32);

        auto func = runtime.getOrCreateAllocCustom(rewriter);
        auto tag = rewriter.create<LLVM::ConstantOp>(
            loc, i32Ty, static_cast<int32_t>(op.getTag()));
        auto size = rewriter.create<LLVM::ConstantOp>(
            loc, i32Ty, static_cast<int32_t>(op.getSize()));
        auto scalarBytes = rewriter.create<LLVM::ConstantOp>(
            loc, i32Ty, static_cast<int32_t>(op.getScalarBytes()));

        auto call = rewriter.create<LLVM::CallOp>(
            loc, func, ValueRange{tag, size, scalarBytes});
        rewriter.replaceOp(op, call.getResult());
        return success();
    }
};

//===----------------------------------------------------------------------===//
// eco.allocate_string -> call eco_alloc_string
//===----------------------------------------------------------------------===//

struct AllocateStringOpLowering : public OpConversionPattern<AllocateStringOp> {
    EcoRuntime runtime;

    AllocateStringOpLowering(EcoTypeConverter &typeConverter, MLIRContext *ctx,
                             EcoRuntime runtime)
        : OpConversionPattern(typeConverter, ctx), runtime(runtime) {}

    LogicalResult
    matchAndRewrite(AllocateStringOp op, OpAdaptor adaptor,
                    ConversionPatternRewriter &rewriter) const override {
        auto loc = op.getLoc();
        auto *ctx = rewriter.getContext();
        auto i32Ty = IntegerType::get(ctx, 32);

        auto func = runtime.getOrCreateAllocString(rewriter);
        auto length = rewriter.create<LLVM::ConstantOp>(
            loc, i32Ty, static_cast<int32_t>(op.getLength()));

        auto call = rewriter.create<LLVM::CallOp>(loc, func, ValueRange{length});
        rewriter.replaceOp(op, call.getResult());
        return success();
    }
};

//===----------------------------------------------------------------------===//
// eco.construct.list -> call eco_alloc_cons
//===----------------------------------------------------------------------===//

struct ListConstructOpLowering : public OpConversionPattern<ListConstructOp> {
    EcoRuntime runtime;

    ListConstructOpLowering(EcoTypeConverter &typeConverter, MLIRContext *ctx,
                            EcoRuntime runtime)
        : OpConversionPattern(typeConverter, ctx), runtime(runtime) {}

    LogicalResult
    matchAndRewrite(ListConstructOp op, OpAdaptor adaptor,
                    ConversionPatternRewriter &rewriter) const override {
        auto loc = op.getLoc();
        auto *ctx = rewriter.getContext();
        auto i32Ty = IntegerType::get(ctx, 32);

        auto func = runtime.getOrCreateAllocCons(rewriter);
        auto headVal = adaptor.getHead();
        auto tailVal = adaptor.getTail();
        uint32_t headUnboxed = op.getHeadUnboxed() ? 1 : 0;
        auto headUnboxedVal = rewriter.create<LLVM::ConstantOp>(loc, i32Ty, headUnboxed);

        auto call = rewriter.create<LLVM::CallOp>(
            loc, func, ValueRange{headVal, tailVal, headUnboxedVal});
        rewriter.replaceOp(op, call.getResult());
        return success();
    }
};

//===----------------------------------------------------------------------===//
// eco.project.list_head -> load from Cons.head (offset 8)
// For primitive result types (i64, f64), uses runtime helpers that handle
// both boxed and unboxed heads transparently.
//===----------------------------------------------------------------------===//

struct ListHeadOpLowering : public OpConversionPattern<ListHeadOp> {
    EcoRuntime runtime;

    ListHeadOpLowering(EcoTypeConverter &typeConverter, MLIRContext *ctx,
                       EcoRuntime runtime)
        : OpConversionPattern(typeConverter, ctx), runtime(runtime) {}

    LogicalResult
    matchAndRewrite(ListHeadOp op, OpAdaptor adaptor,
                    ConversionPatternRewriter &rewriter) const override {
        auto loc = op.getLoc();
        auto *ctx = rewriter.getContext();
        Value input = adaptor.getList();

        // Check the original ECO result type to decide how to extract the head.
        Type origResultType = op.getResult().getType();

        // For primitive types (i64, f64), use runtime helpers that handle
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

        // For !eco.value (HPointer), load directly from Cons.head offset.
        // This handles the case where we want the HPointer itself (boxed or unboxed).
        auto i64Ty = IntegerType::get(ctx, 64);
        auto i8Ty = IntegerType::get(ctx, 8);
        auto ptrTy = LLVM::LLVMPointerType::get(ctx);

        auto resolveFunc = runtime.getOrCreateResolveHPtr(rewriter);
        auto resolveCall = rewriter.create<LLVM::CallOp>(loc, resolveFunc, ValueRange{input});
        Value ptr = resolveCall.getResult();

        auto offset = rewriter.create<LLVM::ConstantOp>(loc, i64Ty, layout::ConsHeadOffset);
        auto fieldPtr = rewriter.create<LLVM::GEPOp>(loc, ptrTy, i8Ty, ptr,
                                                      ValueRange{offset});

        Type resultType = getTypeConverter()->convertType(op.getResult().getType());
        Value result = rewriter.create<LLVM::LoadOp>(loc, resultType, fieldPtr);
        rewriter.replaceOp(op, result);
        return success();
    }
};

//===----------------------------------------------------------------------===//
// eco.project.list_tail -> load from Cons.tail (offset 16)
//===----------------------------------------------------------------------===//

struct ListTailOpLowering : public OpConversionPattern<ListTailOp> {
    EcoRuntime runtime;

    ListTailOpLowering(EcoTypeConverter &typeConverter, MLIRContext *ctx,
                       EcoRuntime runtime)
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

        Type resultType = getTypeConverter()->convertType(op.getResult().getType());
        Value result = rewriter.create<LLVM::LoadOp>(loc, resultType, fieldPtr);
        rewriter.replaceOp(op, result);
        return success();
    }
};

//===----------------------------------------------------------------------===//
// eco.construct.tuple2 -> call eco_alloc_tuple2
//===----------------------------------------------------------------------===//

struct Tuple2ConstructOpLowering : public OpConversionPattern<Tuple2ConstructOp> {
    EcoRuntime runtime;

    Tuple2ConstructOpLowering(EcoTypeConverter &typeConverter, MLIRContext *ctx,
                              EcoRuntime runtime)
        : OpConversionPattern(typeConverter, ctx), runtime(runtime) {}

    LogicalResult
    matchAndRewrite(Tuple2ConstructOp op, OpAdaptor adaptor,
                    ConversionPatternRewriter &rewriter) const override {
        auto loc = op.getLoc();
        auto *ctx = rewriter.getContext();
        auto i32Ty = IntegerType::get(ctx, 32);

        auto func = runtime.getOrCreateAllocTuple2(rewriter);
        auto aVal = adaptor.getA();
        auto bVal = adaptor.getB();
        int64_t unboxedMask = op.getUnboxedBitmap();
        auto unboxedVal = rewriter.create<LLVM::ConstantOp>(loc, i32Ty,
            static_cast<int32_t>(unboxedMask));

        auto call = rewriter.create<LLVM::CallOp>(
            loc, func, ValueRange{aVal, bVal, unboxedVal});
        rewriter.replaceOp(op, call.getResult());
        return success();
    }
};

//===----------------------------------------------------------------------===//
// eco.construct.tuple3 -> call eco_alloc_tuple3
//===----------------------------------------------------------------------===//

struct Tuple3ConstructOpLowering : public OpConversionPattern<Tuple3ConstructOp> {
    EcoRuntime runtime;

    Tuple3ConstructOpLowering(EcoTypeConverter &typeConverter, MLIRContext *ctx,
                              EcoRuntime runtime)
        : OpConversionPattern(typeConverter, ctx), runtime(runtime) {}

    LogicalResult
    matchAndRewrite(Tuple3ConstructOp op, OpAdaptor adaptor,
                    ConversionPatternRewriter &rewriter) const override {
        auto loc = op.getLoc();
        auto *ctx = rewriter.getContext();
        auto i32Ty = IntegerType::get(ctx, 32);

        auto func = runtime.getOrCreateAllocTuple3(rewriter);
        auto aVal = adaptor.getA();
        auto bVal = adaptor.getB();
        auto cVal = adaptor.getC();
        int64_t unboxedMask = op.getUnboxedBitmap();
        auto unboxedVal = rewriter.create<LLVM::ConstantOp>(loc, i32Ty,
            static_cast<int32_t>(unboxedMask));

        auto call = rewriter.create<LLVM::CallOp>(
            loc, func, ValueRange{aVal, bVal, cVal, unboxedVal});
        rewriter.replaceOp(op, call.getResult());
        return success();
    }
};

//===----------------------------------------------------------------------===//
// eco.project.tuple2 -> load from Tuple2.a/b
//===----------------------------------------------------------------------===//

struct Tuple2ProjectOpLowering : public OpConversionPattern<Tuple2ProjectOp> {
    EcoRuntime runtime;

    Tuple2ProjectOpLowering(EcoTypeConverter &typeConverter, MLIRContext *ctx,
                            EcoRuntime runtime)
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
        Value result = rewriter.create<LLVM::LoadOp>(loc, resultType, fieldPtr);
        rewriter.replaceOp(op, result);
        return success();
    }
};

//===----------------------------------------------------------------------===//
// eco.project.tuple3 -> load from Tuple3 fields
//===----------------------------------------------------------------------===//

struct Tuple3ProjectOpLowering : public OpConversionPattern<Tuple3ProjectOp> {
    EcoRuntime runtime;

    Tuple3ProjectOpLowering(EcoTypeConverter &typeConverter, MLIRContext *ctx,
                            EcoRuntime runtime)
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
        Value result = rewriter.create<LLVM::LoadOp>(loc, resultType, fieldPtr);
        rewriter.replaceOp(op, result);
        return success();
    }
};

//===----------------------------------------------------------------------===//
// eco.construct.record -> call eco_alloc_record, then store fields
//===----------------------------------------------------------------------===//

struct RecordConstructOpLowering : public OpConversionPattern<RecordConstructOp> {
    EcoRuntime runtime;

    RecordConstructOpLowering(EcoTypeConverter &typeConverter, MLIRContext *ctx,
                              EcoRuntime runtime)
        : OpConversionPattern(typeConverter, ctx), runtime(runtime) {}

    LogicalResult
    matchAndRewrite(RecordConstructOp op, OpAdaptor adaptor,
                    ConversionPatternRewriter &rewriter) const override {
        auto loc = op.getLoc();
        auto *ctx = rewriter.getContext();
        auto i32Ty = IntegerType::get(ctx, 32);
        auto i64Ty = IntegerType::get(ctx, 64);

        auto allocFunc = runtime.getOrCreateAllocRecord(rewriter);
        auto storeFunc = runtime.getOrCreateStoreRecordField(rewriter);
        auto storeI64Func = runtime.getOrCreateStoreRecordFieldI64(rewriter);
        auto storeF64Func = runtime.getOrCreateStoreRecordFieldF64(rewriter);

        int64_t fieldCount = op.getFieldCount();
        int64_t unboxedBitmap = op.getUnboxedBitmap();

        auto fieldCountVal = rewriter.create<LLVM::ConstantOp>(loc, i32Ty,
            static_cast<int32_t>(fieldCount));
        auto unboxedBitmapVal = rewriter.create<LLVM::ConstantOp>(loc, i64Ty, unboxedBitmap);

        auto allocCall = rewriter.create<LLVM::CallOp>(
            loc, allocFunc, ValueRange{fieldCountVal, unboxedBitmapVal});
        Value objHPtr = allocCall.getResult();

        // Store each field
        auto origFields = op.getFields();
        auto fields = adaptor.getFields();
        for (size_t i = 0; i < fields.size(); i++) {
            auto idx = rewriter.create<LLVM::ConstantOp>(loc, i32Ty, static_cast<int32_t>(i));
            Type origType = origFields[i].getType();
            Value fieldVal = fields[i];

            if (origType.isF64()) {
                rewriter.create<LLVM::CallOp>(loc, storeF64Func,
                    ValueRange{objHPtr, idx, fieldVal});
            } else if (origType.isInteger(1) || origType.isInteger(16)) {
                auto extended = rewriter.create<LLVM::ZExtOp>(loc, i64Ty, fieldVal);
                rewriter.create<LLVM::CallOp>(loc, storeI64Func,
                    ValueRange{objHPtr, idx, extended});
            } else if (origType.isInteger(64)) {
                rewriter.create<LLVM::CallOp>(loc, storeI64Func,
                    ValueRange{objHPtr, idx, fieldVal});
            } else {
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
    EcoRuntime runtime;

    RecordProjectOpLowering(EcoTypeConverter &typeConverter, MLIRContext *ctx,
                            EcoRuntime runtime)
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
        Value result = rewriter.create<LLVM::LoadOp>(loc, resultType, fieldPtr);
        rewriter.replaceOp(op, result);
        return success();
    }
};

//===----------------------------------------------------------------------===//
// eco.construct.custom -> call eco_alloc_custom, then store fields
//===----------------------------------------------------------------------===//

struct CustomConstructOpLowering : public OpConversionPattern<CustomConstructOp> {
    EcoRuntime runtime;

    CustomConstructOpLowering(EcoTypeConverter &typeConverter, MLIRContext *ctx,
                              EcoRuntime runtime)
        : OpConversionPattern(typeConverter, ctx), runtime(runtime) {}

    LogicalResult
    matchAndRewrite(CustomConstructOp op, OpAdaptor adaptor,
                    ConversionPatternRewriter &rewriter) const override {
        auto loc = op.getLoc();
        auto *ctx = rewriter.getContext();
        auto i32Ty = IntegerType::get(ctx, 32);
        auto i64Ty = IntegerType::get(ctx, 64);

        auto allocFunc = runtime.getOrCreateAllocCustom(rewriter);
        auto storeFunc = runtime.getOrCreateStoreField(rewriter);
        auto storeI64Func = runtime.getOrCreateStoreFieldI64(rewriter);
        auto storeF64Func = runtime.getOrCreateStoreFieldF64(rewriter);
        auto setUnboxedFunc = runtime.getOrCreateSetUnboxed(rewriter);

        auto tag = rewriter.create<LLVM::ConstantOp>(loc, i32Ty, static_cast<int32_t>(op.getTag()));
        auto size = rewriter.create<LLVM::ConstantOp>(loc, i32Ty, static_cast<int32_t>(op.getSize()));
        auto scalarBytes = rewriter.create<LLVM::ConstantOp>(loc, i32Ty, 0);

        auto allocCall = rewriter.create<LLVM::CallOp>(
            loc, allocFunc, ValueRange{tag, size, scalarBytes});
        Value objHPtr = allocCall.getResult();

        // Store each field
        auto origFields = op.getFields();
        auto fields = adaptor.getFields();
        for (size_t i = 0; i < fields.size(); i++) {
            auto idx = rewriter.create<LLVM::ConstantOp>(loc, i32Ty, static_cast<int32_t>(i));
            Type origType = origFields[i].getType();
            Value fieldVal = fields[i];

            if (origType.isF64()) {
                rewriter.create<LLVM::CallOp>(loc, storeF64Func,
                    ValueRange{objHPtr, idx, fieldVal});
            } else if (origType.isInteger(1) || origType.isInteger(16)) {
                auto extended = rewriter.create<LLVM::ZExtOp>(loc, i64Ty, fieldVal);
                rewriter.create<LLVM::CallOp>(loc, storeI64Func,
                    ValueRange{objHPtr, idx, extended});
            } else if (origType.isInteger(64)) {
                rewriter.create<LLVM::CallOp>(loc, storeI64Func,
                    ValueRange{objHPtr, idx, fieldVal});
            } else {
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
    EcoRuntime runtime;

    CustomProjectOpLowering(EcoTypeConverter &typeConverter, MLIRContext *ctx,
                            EcoRuntime runtime)
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
        Value result = rewriter.create<LLVM::LoadOp>(loc, resultType, fieldPtr);
        rewriter.replaceOp(op, result);
        return success();
    }
};

} // namespace

//===----------------------------------------------------------------------===//
// Pattern Population
//===----------------------------------------------------------------------===//

void eco::detail::populateEcoHeapPatterns(
    EcoTypeConverter &typeConverter,
    RewritePatternSet &patterns,
    EcoRuntime runtime) {

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
}
